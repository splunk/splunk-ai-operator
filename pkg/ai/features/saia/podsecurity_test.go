package saia

import (
	"context"
	"testing"

	"github.com/splunk/splunk-ai-operator/pkg/ai/podsecurity"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// PSB SEC-RUN-ASLR (FR3): every SAIA pod runs with the RuntimeDefault seccomp
// profile, which blocks personality(ADDR_NO_RANDOMIZE) ("setarch -R").
func TestSAIAPodTemplatesUseRuntimeDefaultSeccomp(t *testing.T) {
	t.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "dummy-hook-image:latest")

	scheme := buildFullTestScheme(t)
	require.NoError(t, batchv1.AddToScheme(scheme))
	ai := newTestAIService()
	ai.Spec.VectorDbUrl = "weaviate.ai-platform.svc.cluster.local"
	configMap := &corev1.ConfigMap{}
	configMap.Name, configMap.Namespace = "test-saia-config", "default"
	configMap.Data = map[string]string{"EMBEDDING_MODEL": "bi_encoder"}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, configMap).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(20)}
	ctx := context.Background()

	require.NoError(t, r.reconcileSAIADeployment(ctx, ai))
	require.NoError(t, r.reconcileSAIAv2Deployment(ctx, ai))
	require.NoError(t, r.reconcileSAIAv2Worker(ctx, ai))
	require.NoError(t, r.reconcileNginxConfigMap(ctx, ai))
	require.NoError(t, r.reconcileNginxDeployment(ctx, ai))
	// The first call creates the Job and returns a "waiting" sentinel error.
	_ = r.reconcilePostInstallHook(ctx, ai)

	templates := map[string]corev1.PodSpec{}
	for _, name := range []string{"test-saia-deployment", "test-saia-v2-deployment", "test-saia-v2-worker", "test-saia-nginx"} {
		dep := &appsv1.Deployment{}
		require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Name: name, Namespace: "default"}, dep), name)
		templates[name] = dep.Spec.Template.Spec
	}
	job := &batchv1.Job{}
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Name: "test-vector-db-setup-posthook", Namespace: "default"}, job))
	templates[job.Name] = job.Spec.Template.Spec

	for name, spec := range templates {
		assert.Equal(t, podsecurity.RuntimeDefaultSeccomp(), spec.SecurityContext, name)
		for _, c := range append(spec.InitContainers, spec.Containers...) {
			if c.SecurityContext != nil {
				assert.Nil(t, c.SecurityContext.SeccompProfile, "%s container %s overrides the pod seccomp profile", name, c.Name)
			}
		}
	}
}
