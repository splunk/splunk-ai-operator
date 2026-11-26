package controller

import (
	"context"
	"fmt"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

var _ = Describe("SLIM reconciliation on the Kubernetes API", func() {
	It("keeps the Deployment revision and sends no writes for a settled status event", func() {
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
		Expect(k8sClient.Create(ctx, ai)).To(Succeed())

		var writes []string
		api, err := client.NewWithWatch(cfg, client.Options{Scheme: k8sClient.Scheme()})
		Expect(err).NotTo(HaveOccurred())
		counted := interceptor.NewClient(api, interceptor.Funcs{
			Update: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.UpdateOption) error {
				writes = append(writes, fmt.Sprintf("%T/%s", obj, obj.GetName()))
				return c.Update(ctx, obj, opts...)
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
		dep.Status = appsv1.DeploymentStatus{ObservedGeneration: dep.Generation, Replicas: 1, ReadyReplicas: 1}
		Expect(k8sClient.Status().Update(ctx, dep)).To(Succeed())
		settledGeneration, settledVersion := dep.Generation, dep.ResourceVersion

		svcKey := client.ObjectKey{Namespace: ns.Name, Name: "slim-slim-service"}
		svc := &corev1.Service{}
		Expect(k8sClient.Get(ctx, svcKey, svc)).To(Succeed())
		allocated := svc.Spec.Ports[0].NodePort
		Expect(allocated).To(BeNumerically(">", 0))
		writes = nil
		reconcile()
		reconcile()
		Expect(writes).To(BeEmpty(), "API requests count even when the API would restore omitted defaults without persisting a change")
		Expect(k8sClient.Get(ctx, depKey, dep)).To(Succeed())
		Expect(dep.Generation).To(Equal(settledGeneration))
		Expect(dep.ResourceVersion).To(Equal(settledVersion))
		Expect(dep.Annotations).To(HaveKeyWithValue(revision, "7"))
		Expect(dep.Spec.Template.Annotations).NotTo(HaveKey(revision))
		Expect(k8sClient.Get(ctx, svcKey, svc)).To(Succeed())
		Expect(svc.Spec.Ports[0].NodePort).To(Equal(allocated))

		// Desired changes still apply once. The next reconcile settles again.
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(ai), ai)).To(Succeed())
		ai.Spec.AgentRuntimeUrl = "http://replacement.example.invalid:8080"
		Expect(k8sClient.Update(ctx, ai)).To(Succeed())
		reconcile()
		Expect(k8sClient.Get(ctx, depKey, dep)).To(Succeed())
		Expect(dep.Generation).To(Equal(settledGeneration + 1))
		Expect(dep.Spec.Template.Spec.Containers[0].Env).To(ContainElement(corev1.EnvVar{
			Name: "AI_TIER_AGENT_RUNTIME_URL", Value: ai.Spec.AgentRuntimeUrl,
		}))
		writes = nil
		reconcile()
		Expect(writes).To(BeEmpty())
	})
})
