package agentruntime

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func TestCheckpointSecretFailureAndCorrection(t *testing.T) {
	for _, missing := range []bool{false, true} {
		name := "malformed"
		if missing {
			name = "missing"
		}
		t.Run(name, func(t *testing.T) {
			r, ai, oldJob := schemaTestReconciler(t)
			ctx := context.Background()
			require.NoError(t, r.Delete(ctx, oldJob))
			ai.Status = aiv1.AIServiceStatus{}
			require.NoError(t, r.Status().Update(ctx, ai))
			s := &corev1.Secret{}
			key := client.ObjectKey{Name: "checkpoint", Namespace: "default"}
			require.NoError(t, r.Get(ctx, key, s))
			valid := s.DeepCopy()
			if missing {
				require.NoError(t, r.Delete(ctx, s))
			} else {
				s.Data["DATABASE_URL"] = []byte("postgresql://user:malformed-canary%broken@db/checkpoint")
				require.NoError(t, r.Update(ctx, s))
			}
			err := r.Reconcile(ctx, ai)
			require.Error(t, err)
			assert.NotContains(t, err.Error(), "malformed-canary")
			assertConditionFalse(t, ai.Status.Conditions, "Ready")
			jobs := &batchv1.JobList{}
			require.NoError(t, r.List(ctx, jobs))
			assert.Empty(t, jobs.Items)
			if missing {
				valid.ResourceVersion = ""
				require.NoError(t, r.Create(ctx, valid))
			} else {
				s.Data = valid.Data
				require.NoError(t, r.Update(ctx, s))
			}
			require.ErrorContains(t, r.Reconcile(ctx, ai), "waiting for schema Job completion")
			require.NoError(t, r.List(ctx, jobs))
			require.Len(t, jobs.Items, 1)
			job := &jobs.Items[0]
			job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
			require.NoError(t, r.Status().Update(ctx, job))
			require.NoError(t, r.Reconcile(ctx, ai))
			dep := &appsv1.Deployment{}
			require.NoError(t, r.Get(ctx, client.ObjectKey{Name: ai.Name + "-agentruntime-deployment", Namespace: ai.Namespace}, dep))
			for _, container := range []corev1.Container{job.Spec.Template.Spec.Containers[0], dep.Spec.Template.Spec.Containers[0]} {
				require.Len(t, container.EnvFrom, 1)
				assert.Equal(t, "checkpoint", container.EnvFrom[0].SecretRef.Name)
				raw, err := json.Marshal(container)
				require.NoError(t, err)
				assert.NotContains(t, string(raw), string(valid.Data["DATABASE_URL"]))
				assert.NotContains(t, string(raw), "malformed-canary")
			}
		})
	}
}

func TestBlockedConditionsDoNotCopyLegacyCredentialDiagnostics(t *testing.T) {
	ai := &aiv1.AIService{}
	for _, condition := range []metav1.Condition{
		{Type: deploymentReady, Status: metav1.ConditionFalse, Reason: "legacy-secret-canary", Message: "legacy-secret-canary"},
		{Type: deploymentReady, Status: metav1.ConditionUnknown, Reason: "Blocked", Message: "waiting; previous observation: legacy-secret-canary at generation 1"},
	} {
		ai.Status.Conditions = []metav1.Condition{condition}
		blockRuntimeCondition(ai, deploymentReady, "PostgresSchemaSetup")
		assert.NotContains(t, meta.FindStatusCondition(ai.Status.Conditions, deploymentReady).Message, "legacy-secret-canary")
	}
}

func TestSafeRuntimeErrorPreservesRetryAndCancellationSemantics(t *testing.T) {
	err := safeRuntimeError(apierrors.NewTooManyRequests("credential-canary", 3), "API unavailable")
	assert.True(t, apierrors.IsTooManyRequests(err))
	delay, suggested := apierrors.SuggestsClientDelay(err)
	assert.True(t, suggested)
	assert.Equal(t, 3, delay)
	assert.NotContains(t, err.Error(), "credential-canary")
	assert.True(t, errors.Is(safeRuntimeError(context.Canceled, "API unavailable"), context.Canceled))
	assert.True(t, errors.Is(safeRuntimeError(context.DeadlineExceeded, "API unavailable"), context.DeadlineExceeded))
}
