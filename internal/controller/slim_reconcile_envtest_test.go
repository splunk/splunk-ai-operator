package controller

import (
	"context"
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/internal/controller/common"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/event"
)

var _ = Describe("SLIM reconciliation on the Kubernetes API", func() {
	DescribeTable("keeps the Deployment revision and sends no writes for settled status events", func(profile aiv1.AIPlatformProfile) {
		const revision = "deployment.kubernetes.io/revision"
		GinkgoT().Setenv("RELATED_IMAGE_SLIM_API", "example.invalid/slim:test")
		ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{GenerateName: "slim-noop-"}}
		Expect(k8sClient.Create(ctx, ns)).To(Succeed())
		ai := &aiv1.AIService{
			ObjectMeta: metav1.ObjectMeta{Name: "slim", Namespace: ns.Name, Annotations: map[string]string{revision: "parent"}},
			Spec: aiv1.AIServiceSpec{
				Feature:         aiv1.FeatureSpec{Name: "slim"},
				TaskVolume:      aiv1.ObjectStorageSpec{Path: "s3://slim-fixture/tasks", Region: "us-west-2"},
				AIPlatformUrl:   "http://models.example.invalid:8000",
				AgentRuntimeUrl: "http://runtime.example.invalid:8080",
				ServiceTemplate: corev1.Service{Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeNodePort}},
			},
		}
		if profile != "" {
			prepareManagedSLIMStabilityFixture(ai, profile)
		}
		Expect(k8sClient.Create(ctx, ai)).To(Succeed())

		var writes []string
		api, err := client.NewWithWatch(cfg, client.Options{Scheme: k8sClient.Scheme()})
		Expect(err).NotTo(HaveOccurred())
		counted := interceptor.NewClient(api, interceptor.Funcs{
			Update: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.UpdateOption) error {
				writes = append(writes, fmt.Sprintf("%T/%s", obj, obj.GetName()))
				return c.Update(ctx, obj, opts...)
			},
			Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
				writes = append(writes, fmt.Sprintf("%T/%s", obj, obj.GetName()))
				return c.Patch(ctx, obj, patch, opts...)
			},
			SubResourceUpdate: func(ctx context.Context, c client.Client, sub string, obj client.Object, opts ...client.SubResourceUpdateOption) error {
				writes = append(writes, fmt.Sprintf("%T/%s/%s", obj, obj.GetName(), sub))
				return c.SubResource(sub).Update(ctx, obj, opts...)
			},
		})
		r := &AIServiceReconciler{Client: counted, Scheme: k8sClient.Scheme(), Recorder: record.NewFakeRecorder(100)}
		reconcile := func() {
			_, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(ai)})
			Expect(err).NotTo(HaveOccurred())
		}
		reconcile()

		depKey := client.ObjectKey{Namespace: ns.Name, Name: "slim-slim-deployment"}
		dep := &appsv1.Deployment{}
		Expect(k8sClient.Get(ctx, depKey, dep)).To(Succeed())
		Expect(dep.Annotations).NotTo(HaveKey(revision))
		Expect(dep.Spec.Template.Annotations).NotTo(HaveKey(revision))
		dep.Annotations[revision] = "7"
		Expect(k8sClient.Update(ctx, dep)).To(Succeed())
		dep.Status = appsv1.DeploymentStatus{
			ObservedGeneration: dep.Generation, Replicas: 1, ReadyReplicas: 1, UpdatedReplicas: 1, AvailableReplicas: 1,
		}
		Expect(k8sClient.Status().Update(ctx, dep)).To(Succeed())

		svcKey := client.ObjectKey{Namespace: ns.Name, Name: "slim-slim-service"}
		if profile != "" {
			// Envtest has no Deployment controller. Use the readiness status
			// supplied above to open the route before checking settled updates.
			reconcile()
		}
		Expect(k8sClient.Get(ctx, depKey, dep)).To(Succeed())
		settled := dep.DeepCopy()
		svc := &corev1.Service{}
		Expect(k8sClient.Get(ctx, svcKey, svc)).To(Succeed())
		allocated := svc.Spec.Ports[0].NodePort
		Expect(allocated).To(BeNumerically(">", 0))
		for i := range 3 {
			before := dep.DeepCopy()
			dep.Status.Conditions = []appsv1.DeploymentCondition{{
				Type: appsv1.DeploymentAvailable, Status: corev1.ConditionTrue,
				Reason: "FixtureReady", Message: fmt.Sprintf("status event %d", i+1),
			}}
			Expect(k8sClient.Status().Update(ctx, dep)).To(Succeed())
			Expect(dep.ResourceVersion).NotTo(Equal(before.ResourceVersion))
			Expect(common.DeploymentChangedPredicate().Update(event.UpdateEvent{ObjectOld: before, ObjectNew: dep})).To(BeTrue())
			statusVersion := dep.ResourceVersion

			writes = nil
			reconcile()
			Expect(writes).To(BeEmpty(), "API requests count even when the API would restore omitted defaults without persisting a change")
			Expect(k8sClient.Get(ctx, depKey, dep)).To(Succeed())
			Expect(dep.Generation).To(Equal(settled.Generation))
			Expect(dep.ResourceVersion).To(Equal(statusVersion))
			Expect(dep.Annotations).To(HaveKeyWithValue(revision, "7"))
			Expect(dep.Spec.Template.Annotations).NotTo(HaveKey(revision))
			Expect(dep.Spec.Template).To(Equal(settled.Spec.Template))
			Expect(k8sClient.Get(ctx, svcKey, svc)).To(Succeed())
			Expect(svc.Spec.Ports[0].NodePort).To(Equal(allocated))
			if profile != "" {
				Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(ai), ai)).To(Succeed())
				Expect(meta.IsStatusConditionTrue(ai.Status.Conditions, "AgentRouteAvailable")).To(BeTrue())
				Expect(ai.Status.FeatureStatus).NotTo(BeNil())
				Expect(ai.Status.FeatureStatus.Slim).NotTo(BeNil())
				Expect(ai.Status.FeatureStatus.Slim.AITKEndpoint).To(Equal(
					fmt.Sprintf("http://%s.%s.svc.cluster.local:8080/tenant/slim-api/v1alpha1", svc.Name, ns.Name)))
			}
		}

		if profile != "" {
			return
		}

		// Desired changes still apply once. The next reconcile settles again.
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(ai), ai)).To(Succeed())
		ai.Spec.AgentRuntimeUrl = "http://replacement.example.invalid:8080"
		Expect(k8sClient.Update(ctx, ai)).To(Succeed())
		reconcile()
		Expect(k8sClient.Get(ctx, depKey, dep)).To(Succeed())
		Expect(dep.Generation).To(Equal(settled.Generation + 1))
		Expect(dep.Spec.Template.Spec.Containers[0].Env).To(ContainElement(corev1.EnvVar{
			Name: "AI_TIER_AGENT_RUNTIME_URL", Value: ai.Spec.AgentRuntimeUrl,
		}))
		writes = nil
		reconcile()
		Expect(writes).To(BeEmpty())
	},
		Entry("legacy SLIM", aiv1.AIPlatformProfile("")),
		Entry("managed cpuOnly", aiv1.AIPlatformProfileCPUOnly),
		Entry("managed fullfeature", aiv1.AIPlatformProfileFullFeature),
	)
})

func prepareManagedSLIMStabilityFixture(slim *aiv1.AIService, profile aiv1.AIPlatformProfile) {
	runtimeFeature := aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk", NetworkPolicy: agentRuntimePolicyForControllerTest()}
	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "route-fixture", Namespace: slim.Namespace},
		Spec: aiv1.AIPlatformSpec{
			Profile: profile, ObjectStorage: slim.Spec.TaskVolume,
			Features: []aiv1.FeatureSpec{{Name: "slim"}, runtimeFeature},
		},
	}
	Expect(k8sClient.Create(ctx, platform)).To(Succeed())
	if profile == aiv1.AIPlatformProfileFullFeature {
		// Exercise the fullfeature route with the status reported by a ready
		// RayService, without starting Ray in the API-server test.
		platform.Status.RayServiceName = "ready-ray"
		meta.SetStatusCondition(&platform.Status.Conditions, metav1.Condition{
			Type: "RayServiceStatusReady", Status: metav1.ConditionTrue,
			Reason: "FixtureReady", Message: "Ray dependency is ready",
		})
		Expect(k8sClient.Status().Update(ctx, platform)).To(Succeed())
	}

	runtimeName := agentruntime.FeatureAIServiceName(platform.Name, runtimeFeature.Provider)
	runtime := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: runtimeName, Namespace: slim.Namespace},
		Spec: aiv1.AIServiceSpec{
			TaskVolume: slim.Spec.TaskVolume, Feature: runtimeFeature,
			AIPlatformRef: corev1.ObjectReference{Name: platform.Name, Namespace: platform.Namespace},
		},
	}
	Expect(controllerutil.SetControllerReference(platform, runtime, k8sClient.Scheme())).To(Succeed())
	Expect(k8sClient.Create(ctx, runtime)).To(Succeed())
	runtime.Status.ObservedGeneration = runtime.Generation
	meta.SetStatusCondition(&runtime.Status.Conditions, metav1.Condition{
		Type: "Ready", Status: metav1.ConditionTrue, ObservedGeneration: runtime.Generation,
		Reason: "FixtureReady", Message: "Runtime dependency is ready",
	})
	Expect(k8sClient.Status().Update(ctx, runtime)).To(Succeed())
	workload := agentruntime.WorkloadName(runtime.Name)
	runtimeSvc := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: agentruntime.ServiceName(runtime.Name), Namespace: runtime.Namespace},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": workload, "component": workload},
			Ports: []corev1.ServicePort{
				{Name: "http", Port: 8080, TargetPort: intstr.FromInt32(8080)},
				{Name: "metrics", Port: 9090, TargetPort: intstr.FromInt32(9090)},
			},
		},
	}
	Expect(controllerutil.SetControllerReference(runtime, runtimeSvc, k8sClient.Scheme())).To(Succeed())
	Expect(k8sClient.Create(ctx, runtimeSvc)).To(Succeed())

	ca := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "issuer-ca", Namespace: slim.Namespace},
		Data:       map[string][]byte{"ca.crt": slimIssuerCA()},
	}
	Expect(k8sClient.Create(ctx, ca)).To(Succeed())
	Expect(controllerutil.SetControllerReference(platform, slim, k8sClient.Scheme())).To(Succeed())
	slim.Spec.AIPlatformRef = runtime.Spec.AIPlatformRef
	slim.Spec.AIPlatformUrl = ""
	slim.Spec.AgentRuntimeUrl = ""
	slim.Spec.SplunkConfiguration = aiv1.SplunkConfigurationSpec{
		TrustedIssuers: []string{"https://splunk.example.invalid:8089"},
		CACertRef:      &corev1.LocalObjectReference{Name: ca.Name},
	}
}
