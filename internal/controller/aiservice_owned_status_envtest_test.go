package controller

import (
	"context"
	"fmt"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/internal/controller/common"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlconfig "sigs.k8s.io/controller-runtime/pkg/config"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

// A successful reconcile returns no retry. These checks therefore require the
// owned-resource status event itself to enqueue the AIService.
var _ = Describe("AIService owned status watches", func() {
	It("enqueues immediately for schema Job and Deployment status changes", func() {
		scheme := runtime.NewScheme()
		Expect(clientgoscheme.AddToScheme(scheme)).To(Succeed())
		Expect(aiv1.AddToScheme(scheme)).To(Succeed())

		name := fmt.Sprintf("owned-status-%d", time.Now().UnixNano()%1000000000)
		ai := &aiv1.AIService{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default"},
			Spec:       aiv1.AIServiceSpec{TaskVolume: aiv1.ObjectStorageSpec{Path: "s3://test-bucket", Region: "us-east-2"}},
		}
		Expect(k8sClient.Create(ctx, ai)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, ai) })

		job := &batchv1.Job{
			ObjectMeta: metav1.ObjectMeta{Name: name + "-job", Namespace: "default"},
			Spec: batchv1.JobSpec{Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{
				RestartPolicy: corev1.RestartPolicyNever,
				Containers:    []corev1.Container{{Name: "schema", Image: "example.invalid/schema:test"}},
			}}},
		}
		Expect(controllerutil.SetControllerReference(ai, job, scheme)).To(Succeed())
		failedJob := job.DeepCopy()
		failedJob.Name = name + "-failed-job"
		Expect(k8sClient.Create(ctx, job)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, job) })
		Expect(k8sClient.Create(ctx, failedJob)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, failedJob) })

		dep := &appsv1.Deployment{
			ObjectMeta: metav1.ObjectMeta{Name: name + "-deployment", Namespace: "default"},
			Spec: appsv1.DeploymentSpec{
				Selector: &metav1.LabelSelector{MatchLabels: map[string]string{"app": name}},
				Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{"app": name}},
					Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "runtime", Image: "example.invalid/runtime:test"}}}},
			},
		}
		Expect(controllerutil.SetControllerReference(ai, dep, scheme)).To(Succeed())
		Expect(k8sClient.Create(ctx, dep)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, dep) })

		mgr, err := ctrl.NewManager(cfg, ctrl.Options{
			Scheme: scheme, Metrics: metricsserver.Options{BindAddress: "0"},
			Controller: ctrlconfig.Controller{SkipNameValidation: boolPtr(true)},
		})
		Expect(err).NotTo(HaveOccurred())
		hits := make(chan reconcile.Request, 16)
		Expect(ctrl.NewControllerManagedBy(mgr).
			For(&aiv1.AIService{}).
			Owns(&batchv1.Job{}, builder.WithPredicates(common.JobChangedPredicate())).
			Owns(&appsv1.Deployment{}, builder.WithPredicates(common.DeploymentChangedPredicate())).
			WithEventFilter(aiServiceGlobalEventFilter()).
			Complete(reconcile.Func(func(_ context.Context, req reconcile.Request) (ctrl.Result, error) {
				hits <- req
				return ctrl.Result{}, nil
			}))).To(Succeed())
		managerCtx, cancelManager := context.WithCancel(ctx)
		DeferCleanup(cancelManager)
		go func() { defer GinkgoRecover(); _ = mgr.Start(managerCtx) }()
		Eventually(hits, 5*time.Second).Should(Receive(Equal(reconcile.Request{NamespacedName: client.ObjectKeyFromObject(ai)})))
		Expect(mgr.GetCache().WaitForCacheSync(managerCtx)).To(BeTrue())
		// The initial AIService and child creates may be coalesced into a
		// variable number of requests. Wait for that burst to settle before
		// asserting that each later status update produces its own request.
		drainInitialRequests := func() {
			timer := time.NewTimer(300 * time.Millisecond)
			defer timer.Stop()
			for {
				select {
				case <-hits:
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
					timer.Reset(300 * time.Millisecond)
				case <-timer.C:
					return
				}
			}
		}
		drainInitialRequests()

		finishedAt := metav1.Now()
		job.Status.StartTime = &finishedAt
		job.Status.CompletionTime = &finishedAt
		job.Status.Succeeded = 1
		job.Status.Conditions = []batchv1.JobCondition{
			{Type: batchv1.JobSuccessCriteriaMet, Status: corev1.ConditionTrue, LastTransitionTime: finishedAt},
			{Type: batchv1.JobComplete, Status: corev1.ConditionTrue, LastTransitionTime: finishedAt},
		}
		Expect(k8sClient.Status().Update(ctx, job)).To(Succeed())
		Eventually(hits, 2*time.Second).Should(Receive(Equal(reconcile.Request{NamespacedName: client.ObjectKeyFromObject(ai)})), "Job completion must wake AIService without error backoff")
		drainInitialRequests()
		failedJob.Status.StartTime = &finishedAt
		failedJob.Status.Failed = 1
		failedJob.Status.Conditions = []batchv1.JobCondition{
			{Type: batchv1.JobFailureTarget, Status: corev1.ConditionTrue, LastTransitionTime: finishedAt},
			{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, LastTransitionTime: finishedAt},
		}
		Expect(k8sClient.Status().Update(ctx, failedJob)).To(Succeed())
		Eventually(hits, 2*time.Second).Should(Receive(Equal(reconcile.Request{NamespacedName: client.ObjectKeyFromObject(ai)})), "Job failure must wake AIService without error backoff")
		drainInitialRequests()

		dep.Status.Replicas = 1
		dep.Status.AvailableReplicas = 1
		dep.Status.ReadyReplicas = 1
		Expect(k8sClient.Status().Update(ctx, dep)).To(Succeed())
		Eventually(hits, 2*time.Second).Should(Receive(Equal(reconcile.Request{NamespacedName: client.ObjectKeyFromObject(ai)})), "Deployment readiness must wake AIService without error backoff")
	})
})
