package agentruntime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv1 "k8s.io/api/autoscaling/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

func TestAgentRuntimeReconcilePreservesHPAScale(t *testing.T) {
	root := filepath.Join("..", "..", "..", "..")
	testEnv := &envtest.Environment{
		CRDDirectoryPaths:     []string{filepath.Join(root, "config", "crd", "bases")},
		ErrorIfCRDPathMissing: true,
	}
	if os.Getenv("KUBEBUILDER_ASSETS") == "" {
		matches, err := filepath.Glob(filepath.Join(root, "bin", "k8s", "*", "kube-apiserver"))
		require.NoError(t, err)
		if len(matches) == 0 {
			t.Skip("envtest binaries are required")
		}
		testEnv.BinaryAssetsDirectory = filepath.Dir(matches[0])
	}
	cfg, err := testEnv.Start()
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, testEnv.Stop()) })

	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_BASE", "docker.io/splunk/agent-runtime:test")
	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_MLTK", "docker.io/splunk/agent-runtime-provider-mltk:test")
	t.Setenv("RELATED_AGENT_RUNTIME_MODULE_PROVIDER_MLTK", "agentcore_operations.loader:MLTKAgentLoader")
	t.Setenv(schemaSetupImageEnv, testSchemaImage)
	scheme := buildAgentRuntimeTestScheme(t)
	c, err := client.New(cfg, client.Options{Scheme: scheme})
	require.NoError(t, err)
	r := &AgentRuntimeReconciler{Client: client.WithFieldOwner(c, "runtime-test"), Scheme: scheme, Recorder: record.NewFakeRecorder(100)}
	ctx := context.Background()
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "hpa-runtime", Namespace: "default"},
		Spec: aiv1.AIServiceSpec{
			Feature:               aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"},
			AIPlatformUrl:         "http://ray.default.svc:8000",
			CheckpointDbSecretRef: "checkpoint",
			Replicas:              2,
			TaskVolume:            aiv1.ObjectStorageSpec{Path: "s3://hpa-fixture", Region: "us-west-2"},
		},
	}
	require.NoError(t, c.Create(ctx, ai))
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: ai.Spec.CheckpointDbSecretRef, Namespace: ai.Namespace},
		StringData: map[string]string{
			"DATABASE_URL": "postgresql://user:fixture@db/checkpoint?sslmode=disable",
			"PG_HOST":      "db", "PG_PORT": "5432", "PG_USER": "user",
			"PG_PASSWORD": "fixture", "PG_DBNAME": "checkpoint",
		},
	}
	require.NoError(t, c.Create(ctx, secret))
	reconcile := func() error {
		t.Helper()
		require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(ai), ai))
		return r.Reconcile(ctx, ai)
	}
	finishSchema := func() {
		t.Helper()
		job := &batchv1.Job{}
		key := client.ObjectKey{Namespace: ai.Namespace, Name: agentRuntimeSchemaStatus(t, ai).JobName}
		require.NoError(t, c.Get(ctx, key, job))
		// Envtest runs the API server without Job controllers or application Pods.
		now := metav1.Now()
		job.Status.StartTime, job.Status.CompletionTime = &now, &now
		job.Status.Conditions = []batchv1.JobCondition{
			{Type: batchv1.JobSuccessCriteriaMet, Status: corev1.ConditionTrue, LastTransitionTime: now},
			{Type: batchv1.JobComplete, Status: corev1.ConditionTrue, LastTransitionTime: now},
		}
		require.NoError(t, c.Status().Update(ctx, job))
		require.NoError(t, reconcile())
	}
	require.Error(t, reconcile())
	finishSchema()

	dep := &appsv1.Deployment{}
	depKey := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-deployment"}
	assertScale := func(want int32) {
		t.Helper()
		require.NoError(t, c.Get(ctx, depKey, dep))
		require.NotNil(t, dep.Spec.Replicas)
		require.Equal(t, want, *dep.Spec.Replicas)
	}
	assertScale(2) // Standalone override is honored on creation.
	scale := func(want int32) {
		t.Helper()
		scaler := client.WithFieldOwner(c, "hpa-test")
		current := &autoscalingv1.Scale{}
		require.NoError(t, scaler.SubResource("scale").Get(ctx, dep, current))
		current.Spec.Replicas = want
		require.NoError(t, scaler.SubResource("scale").Update(ctx, dep, client.WithSubResourceBody(current)))
	}
	for _, count := range []int32{4, 1} {
		scale(count)
		for range 2 {
			require.NoError(t, reconcile())
			assertScale(count)
		}
	}

	scale(3)
	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(ai), ai))
	ai.Spec.Feature.Env = map[string]string{"RUNTIME_TEST_INPUT": "changed"}
	ai.Spec.Replicas = 4
	require.NoError(t, c.Update(ctx, ai))
	require.NoError(t, reconcile())
	assertScale(3)
	require.Contains(t, dep.Spec.Template.Spec.Containers[0].Env, corev1.EnvVar{Name: "RUNTIME_TEST_INPUT", Value: "changed"})
	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(secret), secret))
	secret.Annotations = map[string]string{"test-checkpoint-change": "changed"}
	require.NoError(t, c.Update(ctx, secret))
	require.Error(t, reconcile())
	assertScale(3)
	finishSchema()
	assertScale(3)

	hpa := &autoscalingv2.HorizontalPodAutoscaler{}
	hpaKey := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-hpa"}
	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(ai), ai))
	ai.Spec.MinReplicas, ai.Spec.MaxReplicas, ai.Spec.TargetCPUUtilization = ptr(int32(1)), ptr(int32(2)), ptr(int32(75))
	require.NoError(t, c.Update(ctx, ai))
	require.NoError(t, reconcile())
	assertScale(3) // The updated HPA, not the operator, converges to the new bounds.
	require.NoError(t, c.Get(ctx, hpaKey, hpa))
	require.Equal(t, dep.Name, hpa.Spec.ScaleTargetRef.Name)
	require.Equal(t, int32(2), hpa.Spec.MaxReplicas)
	require.Equal(t, ptr(int32(75)), hpa.Spec.Metrics[0].Resource.Target.AverageUtilization)
	scale(2)
	require.NoError(t, reconcile())
	assertScale(2)

	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(ai), ai))
	ai.Spec.MinReplicas, ai.Spec.MaxReplicas = ptr(int32(5)), nil
	require.NoError(t, c.Update(ctx, ai)) // The test server runs without admission.
	require.ErrorContains(t, reconcile(), "maxReplicas")
	assertScale(2)
	require.NoError(t, c.Get(ctx, hpaKey, hpa))
	require.Equal(t, int32(2), hpa.Spec.MaxReplicas)
	require.Equal(t, "InvalidConfiguration", meta.FindStatusCondition(ai.Status.Conditions, "ValidateReady").Reason)
}
