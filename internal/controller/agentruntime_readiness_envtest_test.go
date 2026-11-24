package controller

import (
	"context"
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

func int32Ptr(value int32) *int32    { return &value }
func stringPtr(value string) *string { return &value }

// Called with both production controllers running in the cpuOnly/no-Ray spec.
// Status writes emulate workload controllers and kubelet observations only;
// the local API server does not execute probes or populate workload status.
func verifyRuntimeReadinessWithControllers(ai *aiv1.AIService, platform *aiv1.AIPlatform, scheme *runtime.Scheme) {
	By("keeping runtime and parent unready after object creation")
	ready := func(obj client.Object) metav1.ConditionStatus {
		switch o := obj.(type) {
		case *aiv1.AIService:
			if err := k8sClient.Get(ctx, client.ObjectKeyFromObject(o), o); err != nil {
				return metav1.ConditionUnknown
			}
			if c := meta.FindStatusCondition(o.Status.Conditions, "Ready"); c != nil {
				return c.Status
			}
		case *aiv1.AIPlatform:
			if err := k8sClient.Get(ctx, client.ObjectKeyFromObject(o), o); err != nil {
				return metav1.ConditionUnknown
			}
			if c := meta.FindStatusCondition(o.Status.Conditions, "Ready"); c != nil {
				return c.Status
			}
		}
		return metav1.ConditionUnknown
	}
	Eventually(func() metav1.ConditionStatus { return ready(ai) }, 5*time.Second, 50*time.Millisecond).Should(Equal(metav1.ConditionFalse))
	Eventually(func() metav1.ConditionStatus { return ready(platform) }, 5*time.Second, 50*time.Millisecond).Should(Equal(metav1.ConditionFalse))
	dep := &appsv1.Deployment{}
	Eventually(func() error {
		return k8sClient.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-deployment"}, dep)
	}, 5*time.Second, 50*time.Millisecond).Should(Succeed())
	DeferCleanup(func() { _ = k8sClient.Delete(ctx, dep) })
	rs := &appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-rs", Namespace: ai.Namespace, Labels: dep.Spec.Template.Labels}, Spec: appsv1.ReplicaSetSpec{Replicas: int32Ptr(1), Selector: dep.Spec.Selector.DeepCopy(), Template: *dep.Spec.Template.DeepCopy()}}
	Expect(controllerutil.SetControllerReference(dep, rs, k8sClient.Scheme())).To(Succeed())
	Expect(k8sClient.Create(ctx, rs)).To(Succeed())
	DeferCleanup(func() { _ = k8sClient.Delete(ctx, rs) })
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-pod", Namespace: ai.Namespace, Labels: dep.Spec.Template.Labels}, Spec: *dep.Spec.Template.Spec.DeepCopy()}
	Expect(controllerutil.SetControllerReference(rs, pod, k8sClient.Scheme())).To(Succeed())
	Expect(k8sClient.Create(ctx, pod)).To(Succeed())
	DeferCleanup(func() { _ = k8sClient.Delete(ctx, pod) })
	pod.Status = corev1.PodStatus{Phase: corev1.PodRunning, PodIP: "10.0.0.9", PodIPs: []corev1.PodIP{{IP: "10.0.0.9"}}, Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}, ContainerStatuses: []corev1.ContainerStatus{{Name: agentruntime.WorkloadName(ai.Name), Ready: true, Image: dep.Spec.Template.Spec.Containers[0].Image, State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}}}}}
	Expect(k8sClient.Status().Update(ctx, pod)).To(Succeed())
	dep.Status = appsv1.DeploymentStatus{ObservedGeneration: dep.Generation, Replicas: 1, UpdatedReplicas: 1, ReadyReplicas: 1, AvailableReplicas: 1}
	Expect(k8sClient.Status().Update(ctx, dep)).To(Succeed())
	Eventually(func() string {
		_ = k8sClient.Get(ctx, client.ObjectKeyFromObject(ai), ai)
		if c := meta.FindStatusCondition(ai.Status.Conditions, "AgentRuntimeDeploymentReady"); c != nil {
			return string(c.Status)
		}
		return ""
	}, 3*time.Second, 50*time.Millisecond).Should(Equal("True"))
	Expect(ready(ai)).To(Equal(metav1.ConditionFalse), "ready Pods without endpoints do not make the Service usable")

	svc := &corev1.Service{}
	Expect(k8sClient.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: agentruntime.ServiceName(ai.Name)}, svc)).To(Succeed())
	slice := &discoveryv1.EndpointSlice{ObjectMeta: metav1.ObjectMeta{Name: ai.Name + "-endpoints", Namespace: ai.Namespace, Labels: map[string]string{discoveryv1.LabelServiceName: svc.Name}}, AddressType: discoveryv1.AddressTypeIPv4, Ports: []discoveryv1.EndpointPort{{Name: stringPtr("http"), Port: int32Ptr(8080)}}, Endpoints: []discoveryv1.Endpoint{{Addresses: []string{"10.0.0.9"}, Conditions: discoveryv1.EndpointConditions{Ready: boolPtr(true)}, TargetRef: &corev1.ObjectReference{APIVersion: "v1", Kind: "Pod", Namespace: pod.Namespace, Name: pod.Name, UID: pod.UID}}}}
	Expect(controllerutil.SetControllerReference(svc, slice, k8sClient.Scheme())).To(Succeed())
	Expect(k8sClient.Create(ctx, slice)).To(Succeed())
	DeferCleanup(func() { _ = k8sClient.Delete(ctx, slice) })
	assertReady := func(want metav1.ConditionStatus) {
		Eventually(func() metav1.ConditionStatus { return ready(ai) }, 3*time.Second, 25*time.Millisecond).Should(Equal(want), "runtime event must update readiness before the five-second fallback")
		Eventually(func() metav1.ConditionStatus { return ready(platform) }, 3*time.Second, 25*time.Millisecond).Should(Equal(want), "child readiness must wake the parent")
	}
	By("propagating endpoint-only loss and recovery")
	assertReady(metav1.ConditionTrue)
	endpoints := slice.Endpoints
	slice.Endpoints = nil
	Expect(k8sClient.Update(ctx, slice)).To(Succeed())
	assertReady(metav1.ConditionFalse)
	slice.Endpoints = endpoints
	Expect(k8sClient.Update(ctx, slice)).To(Succeed())
	assertReady(metav1.ConditionTrue)

	By("propagating kubelet readiness observations without a Deployment status change")
	Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(pod), pod)).To(Succeed())
	pod.Status.ContainerStatuses[0].Ready = false
	Expect(k8sClient.Status().Update(ctx, pod)).To(Succeed())
	assertReady(metav1.ConditionFalse)
	pod.Status.ContainerStatuses[0].Ready = true
	Expect(k8sClient.Status().Update(ctx, pod)).To(Succeed())
	assertReady(metav1.ConditionTrue)

	By("propagating EndpointSlice deletion and recreation")
	Expect(k8sClient.Delete(ctx, slice)).To(Succeed())
	assertReady(metav1.ConditionFalse)
	slice.ResourceVersion = ""
	slice.UID = ""
	Expect(k8sClient.Create(ctx, slice)).To(Succeed())
	assertReady(metav1.ConditionTrue)

	By("observing loss and recovery of the current ReplicaSet owner")
	Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(rs), rs)).To(Succeed())
	owners := append([]metav1.OwnerReference(nil), rs.OwnerReferences...)
	rs.OwnerReferences[0].UID = "foreign-deployment"
	Expect(k8sClient.Update(ctx, rs)).To(Succeed())
	assertReady(metav1.ConditionFalse)
	rs.OwnerReferences = owners
	Expect(k8sClient.Update(ctx, rs)).To(Succeed())
	assertReady(metav1.ConditionTrue)

	By("preserving the revision annotation written by the Deployment controller")
	Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(dep), dep)).To(Succeed())
	if dep.Annotations == nil {
		dep.Annotations = map[string]string{}
	}
	dep.Annotations["deployment.kubernetes.io/revision"] = "1"
	Expect(k8sClient.Update(ctx, dep)).To(Succeed())
	dep.Status.ObservedGeneration = dep.Generation
	Expect(k8sClient.Status().Update(ctx, dep)).To(Succeed())
	assertReady(metav1.ConditionTrue)

	By("settling without status, child spec, Pod-template or schema churn")
	// Let the final queued observations settle, then check stability longer than
	// the fallback interval. A nonready retry must stop once health is observed.
	Eventually(func() bool {
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(ai), ai)).To(Succeed())
		return meta.FindStatusCondition(ai.Status.Conditions, "Ready").ObservedGeneration == ai.Generation
	}, 3*time.Second, 50*time.Millisecond).Should(BeTrue())
	aiVersion := ai.ResourceVersion
	Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(platform), platform)).To(Succeed())
	parentVersion := platform.ResourceVersion
	Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(dep), dep)).To(Succeed())
	deploymentVersion := dep.ResourceVersion
	// Trigger another runtime reconcile after health has stabilized. Pod status
	// observation alone must not rewrite the defaulted Deployment or roll Pods.
	Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(pod), pod)).To(Succeed())
	pod.Status.ContainerStatuses[0].RestartCount++
	Expect(k8sClient.Status().Update(ctx, pod)).To(Succeed())
	Consistently(func() []string {
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(ai), ai)).To(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(platform), platform)).To(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(dep), dep)).To(Succeed())
		return []string{ai.ResourceVersion, platform.ResourceVersion, dep.ResourceVersion}
	}, 6*time.Second, 100*time.Millisecond).Should(Equal([]string{aiVersion, parentVersion, deploymentVersion}))
	Expect(dep.Annotations).To(HaveKeyWithValue("deployment.kubernetes.io/revision", "1"))
	Expect(dep.Spec.Template.Annotations).NotTo(HaveKey("deployment.kubernetes.io/revision"))

	By("skipping write requests when the Runtime workload already matches API defaults")
	// The API server can reapply defaults without changing the stored resource
	// version, so also observe the write requests made during a direct reconcile.
	directClient, err := client.NewWithWatch(cfg, client.Options{Scheme: scheme})
	Expect(err).NotTo(HaveOccurred())
	var writes []string
	counted := interceptor.NewClient(directClient, interceptor.Funcs{
		Update: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.UpdateOption) error {
			writes = append(writes, fmt.Sprintf("update %T %s", obj, obj.GetName()))
			return c.Update(ctx, obj, opts...)
		},
		Patch: func(ctx context.Context, c client.WithWatch, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
			data, err := patch.Data(obj)
			if err != nil {
				return err
			}
			writes = append(writes, fmt.Sprintf("patch %T %s: %s", obj, obj.GetName(), data))
			return c.Patch(ctx, obj, patch, opts...)
		},
		SubResourceUpdate: func(ctx context.Context, c client.Client, name string, obj client.Object, opts ...client.SubResourceUpdateOption) error {
			writes = append(writes, fmt.Sprintf("update %T %s/%s", obj, obj.GetName(), name))
			return c.SubResource(name).Update(ctx, obj, opts...)
		},
	})
	reconciler := &AIServiceReconciler{Client: counted, Scheme: counted.Scheme(), Recorder: record.NewFakeRecorder(20)}
	_, err = reconciler.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(ai)})
	Expect(err).NotTo(HaveOccurred())
	Expect(writes).To(BeEmpty())

	By("reconciling Service spec changes even without a generation change")
	Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(svc), svc)).To(Succeed())
	svc.Spec.Selector = map[string]string{"app": "wrong-runtime"}
	Expect(k8sClient.Update(ctx, svc)).To(Succeed())
	Eventually(func() map[string]string {
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(svc), svc)).To(Succeed())
		return svc.Spec.Selector
	}, 3*time.Second, 25*time.Millisecond).Should(Equal(dep.Spec.Template.Labels))
	assertReady(metav1.ConditionTrue)
}
