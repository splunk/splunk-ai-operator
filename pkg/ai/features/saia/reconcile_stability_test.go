package saia

import (
	"context"
	"os"
	"testing"
	"time"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

type updateCounter struct {
	client.Client
	updates int
}

func (c *updateCounter) Update(ctx context.Context, obj client.Object, opts ...client.UpdateOption) error {
	c.updates++
	return c.Client.Update(ctx, obj, opts...)
}

func TestSAIAReconcileKeepsAPIDefaultedWorkloadsStable(t *testing.T) {
	assets := os.Getenv("KUBEBUILDER_ASSETS")
	if assets == "" {
		t.Skip("set KUBEBUILDER_ASSETS to run the local API server test")
	}
	env := &envtest.Environment{BinaryAssetsDirectory: assets}
	cfg, err := env.Start()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, env.Stop()) })
	ctx := context.Background()
	scheme := buildFullTestScheme(t)
	api, err := client.New(cfg, client.Options{Scheme: scheme})
	require.NoError(t, err)
	tracked := &updateCounter{Client: api}
	r := &SaiaReconciler{Client: tracked, Scheme: scheme, Recorder: record.NewFakeRecorder(20)}
	t.Setenv("RELATED_IMAGE_SAIA_API", "example.invalid/saia:v1")

	for _, tt := range []struct {
		name      string
		suffix    string
		reconcile func(context.Context, *aiv1.AIService) error
	}{
		{"SAIA v1", "-saia-deployment", r.reconcileSAIADeployment},
		{"SAIA v2", "-saia-v2-deployment", r.reconcileSAIAv2Deployment},
		{"SAIA worker", "-saia-v2-worker", r.reconcileSAIAv2Worker},
		{"nginx", "-saia-nginx", r.reconcileNginxDeployment},
	} {
		t.Run(tt.name, func(t *testing.T) {
			const revision = "deployment.kubernetes.io/revision"
			ai := newTestAIService()
			ai.Annotations = map[string]string{revision: "from-parent"}
			require.NoError(t, tt.reconcile(ctx, ai))
			dep := &appsv1.Deployment{}
			key := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + tt.suffix}
			require.NoError(t, api.Get(ctx, key, dep))
			require.NotContains(t, dep.Annotations, revision)
			// The API server defaults the pod template. Supply the annotation and
			// status event normally produced by the Kubernetes Deployment controller.
			dep.Annotations[revision] = "7"
			require.NoError(t, api.Update(ctx, dep))
			dep.Status.ObservedGeneration = dep.Generation
			dep.Status.Replicas = 1
			dep.Status.ReadyReplicas = 1
			dep.Status.AvailableReplicas = 1
			require.NoError(t, api.Status().Update(ctx, dep))
			initial := dep.DeepCopy()
			tracked.updates = 0
			require.NoError(t, tt.reconcile(ctx, ai))
			require.NoError(t, api.Get(ctx, key, dep))
			require.Zero(t, tracked.updates, "identical desired workload should not call Update")
			require.Equal(t, initial.ResourceVersion, dep.ResourceVersion)
			require.Equal(t, initial.Generation, dep.Generation)
			require.Equal(t, "7", dep.Annotations[revision])
			require.NotContains(t, dep.Spec.Template.Annotations, revision)

			// A real input change still updates the pod template and rolls out.
			ai.Annotations = map[string]string{"example.com/config-revision": "next"}
			require.NoError(t, tt.reconcile(ctx, ai))
			require.NoError(t, api.Get(ctx, key, dep))
			require.Equal(t, 1, tracked.updates)
			require.Greater(t, dep.Generation, initial.Generation)
			require.Equal(t, "7", dep.Annotations[revision])
			require.Equal(t, "next", dep.Spec.Template.Annotations["example.com/config-revision"])
		})
	}

	for _, tt := range []struct {
		name      string
		suffix    string
		typ       corev1.ServiceType
		reconcile func(context.Context, *aiv1.AIService) error
	}{
		{"v1 Service", "-saia-v1-service", corev1.ServiceTypeClusterIP, r.reconcileSAIAv1Service},
		{"v2 Service", "-saia-v2-service", corev1.ServiceTypeClusterIP, r.reconcileSAIAv2Service},
		{"NodePort Service", "-saia-service", corev1.ServiceTypeNodePort, r.reconcileSAIAService},
		{"LoadBalancer Service", "-saia-service", corev1.ServiceTypeLoadBalancer, r.reconcileSAIAService},
	} {
		t.Run(tt.name, func(t *testing.T) {
			ai := newTestAIService()
			ai.Name = sanitize(tt.name)
			ai.Spec.ServiceTemplate.Spec.Type = tt.typ
			require.NoError(t, tt.reconcile(ctx, ai))
			svc := &corev1.Service{}
			key := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + tt.suffix}
			require.NoError(t, api.Get(ctx, key, svc))
			initial := svc.DeepCopy()
			if tt.typ != corev1.ServiceTypeClusterIP {
				require.NotZero(t, initial.Spec.Ports[0].NodePort, "the API server allocates the port")
			}
			tracked.updates = 0
			require.NoError(t, tt.reconcile(ctx, ai))
			require.NoError(t, api.Get(ctx, key, svc))
			require.Zero(t, tracked.updates, "default protocol and allocated ports should not cause another write")
			require.Equal(t, initial.ResourceVersion, svc.ResourceVersion)
			require.Equal(t, initial.Spec.Ports, svc.Spec.Ports)
		})
	}
}

func TestSAIAReconcileLeavesUnchangedStatusAlone(t *testing.T) {
	t.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "")
	ctx := context.Background()
	ai := newTestAIService()
	transitionTime := metav1.NewTime(time.Unix(1234, 0))
	ai.Status.Conditions = []metav1.Condition{{
		Type:               "ValidateReady",
		Status:             metav1.ConditionFalse,
		Reason:             "Error",
		Message:            "RELATED_IMAGE_POST_INSTALL_HOOK must be set",
		LastTransitionTime: transitionTime,
	}}
	scheme := buildFullTestScheme(t)
	writes := 0
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).WithStatusSubresource(ai).
		WithInterceptorFuncs(interceptor.Funcs{SubResourceUpdate: func(ctx context.Context, c client.Client, name string, obj client.Object, opts ...client.SubResourceUpdateOption) error {
			writes++
			return c.SubResource(name).Update(ctx, obj, opts...)
		}}).Build()
	r := &SaiaReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}
	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(ai), ai))
	require.ErrorContains(t, r.Reconcile(ctx, ai), "RELATED_IMAGE_POST_INSTALL_HOOK must be set")
	require.Zero(t, writes)
	require.Equal(t, transitionTime, ai.Status.Conditions[0].LastTransitionTime)
}
