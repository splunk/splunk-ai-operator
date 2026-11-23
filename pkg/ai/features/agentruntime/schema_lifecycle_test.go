package agentruntime

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

type staleSchemaJobClient struct {
	client.Client
	jobName string
	miss    bool
}

func (c *staleSchemaJobClient) Get(ctx context.Context, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
	if _, isJob := obj.(*batchv1.Job); c.miss && isJob && key.Name == c.jobName {
		c.miss = false
		return apierrors.NewNotFound(schema.GroupResource{Resource: "jobs"}, key.Name)
	}
	return c.Client.Get(ctx, key, obj, opts...)
}

func schemaTestReconciler(t *testing.T) (*AgentRuntimeReconciler, *aiv1.AIService, *batchv1.Job) {
	t.Helper()
	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_BASE", "docker.io/splunk/agent-runtime:test")
	t.Setenv("RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_MLTK", "docker.io/splunk/agent-runtime-provider-mltk:test")
	t.Setenv("RELATED_AGENT_RUNTIME_MODULE_PROVIDER_MLTK", "agentcore_operations.loader:MLTKAgentLoader")
	t.Setenv(schemaSetupImageEnv, testSchemaImage)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "schema-lifecycle", Namespace: "default", UID: types.UID("schema-lifecycle-uid")},
		Spec: aiv1.AIServiceSpec{
			Feature:       aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"},
			AIPlatformUrl: "http://ray.default.svc:8000", CheckpointDbSecretRef: "checkpoint", Replicas: 1,
		},
	}
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "checkpoint", Namespace: "default", ResourceVersion: "1"},
		Type:       corev1.SecretTypeOpaque,
		Data: map[string][]byte{
			"DATABASE_URL": []byte("postgresql://user:secret@db/checkpoint?sslmode=disable"),
			"PG_HOST":      []byte("db"), "PG_PORT": []byte("5432"), "PG_USER": []byte("user"),
			"PG_PASSWORD": []byte("secret"), "PG_DBNAME": []byte("checkpoint"),
		},
	}
	// Match the API server's separate spec and status writes; otherwise a fake
	// status update could also persist an unsubmitted retry or input change.
	client := fake.NewClientBuilder().WithScheme(buildAgentRuntimeTestScheme(t)).WithStatusSubresource(&aiv1.AIService{}).WithObjects(ai, secret).Build()
	r := &AgentRuntimeReconciler{Client: client, Scheme: buildAgentRuntimeTestScheme(t), Recorder: record.NewFakeRecorder(10)}
	require.Error(t, r.Reconcile(context.Background(), ai))
	job := &batchv1.Job{}
	require.NoError(t, client.Get(context.Background(), types.NamespacedName{Name: agentRuntimeSchemaStatus(t, ai).JobName, Namespace: ai.Namespace}, job))
	return r, ai, job
}

func agentRuntimeSchemaStatus(t *testing.T, ai *aiv1.AIService) *aiv1.AgentRuntimeSchemaStatus {
	t.Helper()
	require.NotNil(t, ai.Status.FeatureStatus)
	require.NotNil(t, ai.Status.FeatureStatus.AgentRuntime)
	require.NotNil(t, ai.Status.FeatureStatus.AgentRuntime.Schema)
	return ai.Status.FeatureStatus.AgentRuntime.Schema
}

func schemaCondition(t *testing.T, ai *aiv1.AIService) metav1.Condition {
	t.Helper()
	for _, condition := range ai.Status.Conditions {
		if condition.Type == "PostgresSchemaSetupReady" {
			if condition.Status == metav1.ConditionFalse {
				assertConditionFalse(t, ai.Status.Conditions, "Ready")
			}
			assert.Equal(t, ai.Generation, condition.ObservedGeneration)
			return condition
		}
	}
	t.Fatal("PostgresSchemaSetupReady condition missing")
	return metav1.Condition{}
}

func TestSchemaJobBoundedAndReusableAfterTTL(t *testing.T) {
	r, ai, job := schemaTestReconciler(t)
	assert.EqualValues(t, schemaJobDeadlineSeconds, *job.Spec.ActiveDeadlineSeconds)
	assert.EqualValues(t, schemaJobBackoffLimit, *job.Spec.BackoffLimit)
	assert.EqualValues(t, schemaJobTTLSeconds, *job.Spec.TTLSecondsAfterFinished)
	assert.Equal(t, testSchemaImage, job.Spec.Template.Spec.Containers[0].Image)
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
	require.Len(t, job.OwnerReferences, 1)
	assert.Equal(t, ai.UID, job.OwnerReferences[0].UID)
	assert.LessOrEqual(t, len(job.Name), 63)
	assert.Equal(t, "sha256:"+strings.Repeat("a", 64), job.Annotations["ai.splunk.com/agentruntime-schema-image-digest"])
	evidence, err := json.Marshal(struct {
		Name            string `json:"name"`
		OwnerUID        string `json:"ownerUID"`
		Image           string `json:"image"`
		ImageDigest     string `json:"imageDigest"`
		DeadlineSeconds int64  `json:"deadlineSeconds"`
		BackoffLimit    int32  `json:"backoffLimit"`
		TTLSeconds      int32  `json:"ttlSeconds"`
		Condition       string `json:"condition"`
	}{job.Name, string(job.OwnerReferences[0].UID), job.Spec.Template.Spec.Containers[0].Image, job.Annotations["ai.splunk.com/agentruntime-schema-image-digest"], *job.Spec.ActiveDeadlineSeconds, *job.Spec.BackoffLimit, *job.Spec.TTLSecondsAfterFinished, schemaCondition(t, ai).Reason})
	require.NoError(t, err)
	t.Logf("jobEvidence=%s", evidence)
	require.Error(t, r.Reconcile(context.Background(), ai))
	var pendingJobs batchv1.JobList
	require.NoError(t, r.List(context.Background(), &pendingJobs))
	assert.Len(t, pendingJobs.Items, 1)
	t.Logf("unchanged pending reconciliation: jobCount=%d", len(pendingJobs.Items))

	job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, r.Status().Update(context.Background(), job))
	require.NoError(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Succeeded", schemaCondition(t, ai).Reason)
	t.Logf("completed schema Job: condition=%s", schemaCondition(t, ai).Reason)
	assert.NotEmpty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)
	assert.Equal(t, "sha256:"+strings.Repeat("a", 64), agentRuntimeSchemaStatus(t, ai).ImageDigest)
	require.NoError(t, r.Delete(context.Background(), job)) // TTL cleanup
	require.NoError(t, r.Reconcile(context.Background(), ai))
	assert.Empty(t, agentRuntimeSchemaStatus(t, ai).JobName)
	var jobs batchv1.JobList
	require.NoError(t, r.List(context.Background(), &jobs))
	assert.Empty(t, jobs.Items)
	t.Logf("successful Job after TTL cleanup: condition=%s jobCount=%d", schemaCondition(t, ai).Reason, len(jobs.Items))
}

func TestSchemaImageMustComeFromResolvedDigest(t *testing.T) {
	t.Setenv(schemaSetupImageEnv, "docker.io/splunk/agent-runtime-schema-setup:latest")
	_, err := resolveSchemaSetupImage()
	require.Error(t, err)
	assert.NotContains(t, err.Error(), "latest")
	t.Setenv(schemaSetupImageEnv, testSchemaImage)
	image, err := resolveSchemaSetupImage()
	require.NoError(t, err)
	assert.Equal(t, testSchemaImage, image)
}

func TestSchemaFailurePersistsAndNonceRetries(t *testing.T) {
	r, ai, job := schemaTestReconciler(t)
	job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, Reason: "DeadlineExceeded", Message: "postgresql://user:secret@db/checkpoint?token=secret"}}
	require.NoError(t, r.Status().Update(context.Background(), job))
	require.Error(t, r.Reconcile(context.Background(), ai))
	condition := schemaCondition(t, ai)
	assert.Equal(t, "TimedOut", condition.Reason)
	t.Logf("deadline failure: condition=%s message=%s", condition.Reason, condition.Message)
	assert.NotContains(t, condition.Message, "secret")
	assert.NotContains(t, condition.Message, "postgresql://")
	require.NoError(t, r.Delete(context.Background(), job))
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "TimedOut", schemaCondition(t, ai).Reason)

	ai.Spec.Feature.SchemaRetryNonce = "retry-1"
	require.NoError(t, r.Update(context.Background(), ai))
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
	assert.NotEqual(t, job.Name, agentRuntimeSchemaStatus(t, ai).JobName)
	assert.Contains(t, schemaCondition(t, ai).Message, "previous outcome: TimedOut")
	var jobs batchv1.JobList
	require.NoError(t, r.List(context.Background(), &jobs))
	assert.Len(t, jobs.Items, 1)
	t.Logf("explicit nonce retry: condition=%s jobCount=%d", schemaCondition(t, ai).Reason, len(jobs.Items))
}

func TestSchemaRetryLimitReportsSafeFailure(t *testing.T) {
	r, ai, job := schemaTestReconciler(t)
	job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, Reason: "BackoffLimitExceeded", Message: "postgresql://user:secret@db/checkpoint?token=secret"}}
	require.NoError(t, r.Status().Update(context.Background(), job))
	require.Error(t, r.Reconcile(context.Background(), ai))
	condition := schemaCondition(t, ai)
	assert.Equal(t, "Failed", condition.Reason)
	assert.Contains(t, condition.Message, "exhausted its retry limit")
	assert.NotContains(t, condition.Message, "secret")
	assert.NotContains(t, condition.Message, "postgresql://")
	t.Logf("retry-limit failure: condition=%s message=%s", condition.Reason, condition.Message)
}

func TestSchemaJobLostBeforeOutcomeRequiresExplicitRetry(t *testing.T) {
	r, ai, job := schemaTestReconciler(t)
	require.NoError(t, r.Delete(context.Background(), job))
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Failed", schemaCondition(t, ai).Reason)
	var jobs batchv1.JobList
	require.NoError(t, r.List(context.Background(), &jobs))
	assert.Empty(t, jobs.Items)
	ai.Spec.Feature.SchemaRetryNonce = "after-unknown-outcome"
	require.NoError(t, r.Update(context.Background(), ai))
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
}

func TestSchemaInputChangeStopsActiveJobBeforeReplacement(t *testing.T) {
	r, ai, old := schemaTestReconciler(t)
	ai.Spec.Feature.SchemaRetryNonce = "new-attempt"
	require.NoError(t, r.Update(context.Background(), ai))
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Superseded", schemaCondition(t, ai).Reason)
	t.Logf("input change during active Job: condition=%s", schemaCondition(t, ai).Reason)
	var jobs batchv1.JobList
	require.NoError(t, r.List(context.Background(), &jobs))
	assert.Empty(t, jobs.Items) // fake client completes foreground deletion immediately
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
	assert.NotEqual(t, old.Name, agentRuntimeSchemaStatus(t, ai).JobName)
	require.NoError(t, r.List(context.Background(), &jobs))
	assert.Len(t, jobs.Items, 1)
}

func TestSchemaDigestAndSecretVersionRerunAfterSuccess(t *testing.T) {
	for _, changed := range []string{"digest", "secret version", "postgres config"} {
		t.Run(changed, func(t *testing.T) {
			r, ai, old := schemaTestReconciler(t)
			old.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
			require.NoError(t, r.Status().Update(context.Background(), old))
			require.NoError(t, r.Reconcile(context.Background(), ai))
			switch changed {
			case "digest":
				t.Setenv(schemaSetupImageEnv, "docker.io/splunk/agent-runtime-schema-setup@sha256:"+strings.Repeat("b", 64))
			case "secret version":
				secret := &corev1.Secret{}
				require.NoError(t, r.Get(context.Background(), types.NamespacedName{Name: "checkpoint", Namespace: "default"}, secret))
				secret.Data["unrelated-key"] = []byte("version-change")
				require.NoError(t, r.Update(context.Background(), secret))
			case "postgres config":
				ai.Spec.Feature.Env = map[string]string{"PG_SSLMODE": "require"}
				require.NoError(t, r.Update(context.Background(), ai))
			}
			require.Error(t, r.Reconcile(context.Background(), ai))
			assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
			assert.NotEqual(t, old.Name, agentRuntimeSchemaStatus(t, ai).JobName)
			assert.Empty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash, "a new attempt invalidates the previous success")
			assert.Empty(t, agentRuntimeSchemaStatus(t, ai).ImageDigest)
			var jobs batchv1.JobList
			require.NoError(t, r.List(context.Background(), &jobs))
			assert.Len(t, jobs.Items, 2) // completed history plus exactly one new Job
			t.Logf("input change %s: condition=%s totalJobs=%d newJob=%s", changed, schemaCondition(t, ai).Reason, len(jobs.Items), agentRuntimeSchemaStatus(t, ai).JobName)
		})
	}
}

func TestSchemaDigestRevertRunsAgainBeforeHistoricalJobTTL(t *testing.T) {
	r, ai, first := schemaTestReconciler(t)
	first.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, r.Status().Update(context.Background(), first))
	require.NoError(t, r.Reconcile(context.Background(), ai))
	firstHash := agentRuntimeSchemaStatus(t, ai).AppliedHash

	secondImage := "docker.io/splunk/agent-runtime-schema-setup@sha256:" + strings.Repeat("b", 64)
	t.Setenv(schemaSetupImageEnv, secondImage)
	require.Error(t, r.Reconcile(context.Background(), ai))
	second := &batchv1.Job{}
	require.NoError(t, r.Get(context.Background(), types.NamespacedName{Name: agentRuntimeSchemaStatus(t, ai).JobName, Namespace: ai.Namespace}, second))
	second.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, r.Status().Update(context.Background(), second))
	require.NoError(t, r.Reconcile(context.Background(), ai))
	assert.NotEqual(t, firstHash, agentRuntimeSchemaStatus(t, ai).AppliedHash)
	secondHash := agentRuntimeSchemaStatus(t, ai).AppliedHash

	t.Setenv(schemaSetupImageEnv, testSchemaImage)
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
	assert.Equal(t, secondHash, agentRuntimeSchemaStatus(t, ai).AppliedHash, "the historical success must not become the current result")
	missingFirst := &batchv1.Job{}
	assert.Error(t, r.Get(context.Background(), types.NamespacedName{Name: first.Name, Namespace: first.Namespace}, missingFirst))

	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
	assert.Equal(t, first.Name, agentRuntimeSchemaStatus(t, ai).JobName)
	assert.Empty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)
	replayedFirst := &batchv1.Job{}
	require.NoError(t, r.Get(context.Background(), types.NamespacedName{Name: first.Name, Namespace: first.Namespace}, replayedFirst))
	assert.Empty(t, replayedFirst.Status.Conditions, "the reverted input must get a fresh Job")
	assert.Equal(t, firstHash, replayedFirst.Annotations[schemaJobInputHashAnnotation])
}

func TestSchemaDigestRevertRunsAgainBeforeIntermediateOutcomeObserved(t *testing.T) {
	r, ai, first := schemaTestReconciler(t)
	first.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, r.Status().Update(context.Background(), first))
	require.NoError(t, r.Reconcile(context.Background(), ai))
	assert.NotEmpty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)

	t.Setenv(schemaSetupImageEnv, "docker.io/splunk/agent-runtime-schema-setup@sha256:"+strings.Repeat("b", 64))
	require.Error(t, r.Reconcile(context.Background(), ai))
	second := &batchv1.Job{}
	require.NoError(t, r.Get(context.Background(), types.NamespacedName{Name: agentRuntimeSchemaStatus(t, ai).JobName, Namespace: ai.Namespace}, second))
	second.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, r.Status().Update(context.Background(), second))
	// The SQL ran, but the controller has not observed the B Job's completion.
	assert.Empty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)

	t.Setenv(schemaSetupImageEnv, testSchemaImage)
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
	assert.Empty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)
	assert.Error(t, r.Get(context.Background(), types.NamespacedName{Name: first.Name, Namespace: first.Namespace}, &batchv1.Job{}))
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, first.Name, agentRuntimeSchemaStatus(t, ai).JobName)
	replayedFirst := &batchv1.Job{}
	require.NoError(t, r.Get(context.Background(), types.NamespacedName{Name: first.Name, Namespace: first.Namespace}, replayedFirst))
	assert.Empty(t, replayedFirst.Status.Conditions)
}

func TestSchemaRevertedAttemptCannotReuseHistoricalSuccessAfterTTL(t *testing.T) {
	for _, outcome := range []struct {
		name           string
		observeFailure bool
		expectedReason string
	}{
		{name: "failed replay", observeFailure: true, expectedReason: "TimedOut"},
		{name: "lost replay outcome", expectedReason: "Failed"},
	} {
		t.Run(outcome.name, func(t *testing.T) {
			r, ai, first := schemaTestReconciler(t)
			first.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
			require.NoError(t, r.Status().Update(context.Background(), first))
			require.NoError(t, r.Reconcile(context.Background(), ai))
			assert.NotEmpty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)

			t.Setenv(schemaSetupImageEnv, "docker.io/splunk/agent-runtime-schema-setup@sha256:"+strings.Repeat("b", 64))
			require.Error(t, r.Reconcile(context.Background(), ai))
			second := &batchv1.Job{}
			require.NoError(t, r.Get(context.Background(), types.NamespacedName{Name: agentRuntimeSchemaStatus(t, ai).JobName, Namespace: ai.Namespace}, second))
			second.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, Reason: "BackoffLimitExceeded"}}
			require.NoError(t, r.Status().Update(context.Background(), second))
			require.Error(t, r.Reconcile(context.Background(), ai))
			assert.Equal(t, "Failed", schemaCondition(t, ai).Reason)

			t.Setenv(schemaSetupImageEnv, testSchemaImage)
			require.Error(t, r.Reconcile(context.Background(), ai)) // remove historical A Job
			require.Error(t, r.Reconcile(context.Background(), ai)) // create fresh A Job
			assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
			assert.Empty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)
			assert.Empty(t, agentRuntimeSchemaStatus(t, ai).ImageDigest)
			replay := &batchv1.Job{}
			require.NoError(t, r.Get(context.Background(), types.NamespacedName{Name: first.Name, Namespace: first.Namespace}, replay))
			if outcome.observeFailure {
				replay.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, Reason: "DeadlineExceeded"}}
				require.NoError(t, r.Status().Update(context.Background(), replay))
				require.Error(t, r.Reconcile(context.Background(), ai))
				assert.Equal(t, "TimedOut", schemaCondition(t, ai).Reason)
			}
			require.NoError(t, r.Delete(context.Background(), replay)) // TTL cleanup
			require.Error(t, r.Reconcile(context.Background(), ai))
			assert.Equal(t, outcome.expectedReason, schemaCondition(t, ai).Reason)
			assert.NotEqual(t, "Succeeded", schemaCondition(t, ai).Reason)
			assert.Empty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)
		})
	}
}

func TestSchemaRetainedJobAlreadyExistsIsNotAdopted(t *testing.T) {
	r, ai, first := schemaTestReconciler(t)
	first.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, r.Status().Update(context.Background(), first))
	require.NoError(t, r.Reconcile(context.Background(), ai))

	t.Setenv(schemaSetupImageEnv, "docker.io/splunk/agent-runtime-schema-setup@sha256:"+strings.Repeat("b", 64))
	require.Error(t, r.Reconcile(context.Background(), ai))
	second := &batchv1.Job{}
	require.NoError(t, r.Get(context.Background(), types.NamespacedName{Name: agentRuntimeSchemaStatus(t, ai).JobName, Namespace: ai.Namespace}, second))
	second.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, Reason: "BackoffLimitExceeded"}}
	require.NoError(t, r.Status().Update(context.Background(), second))
	require.Error(t, r.Reconcile(context.Background(), ai))

	t.Setenv(schemaSetupImageEnv, testSchemaImage)
	r.Client = &staleSchemaJobClient{Client: r.Client, jobName: first.Name, miss: true}
	require.Error(t, r.Reconcile(context.Background(), ai))
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
	assert.Equal(t, second.Name, agentRuntimeSchemaStatus(t, ai).JobName, "a retained Job must not become the new attempt")
	assert.Empty(t, agentRuntimeSchemaStatus(t, ai).AppliedHash)

	require.Error(t, r.Reconcile(context.Background(), ai)) // re-read and remove historical A Job
	assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
	assert.Error(t, r.Get(context.Background(), types.NamespacedName{Name: first.Name, Namespace: first.Namespace}, &batchv1.Job{}))
}

func TestSchemaInputFingerprintIgnoresUnrelatedConfig(t *testing.T) {
	ai := &aiv1.AIService{Spec: aiv1.AIServiceSpec{CheckpointDbSecretRef: "db", Feature: aiv1.FeatureSpec{Env: map[string]string{"PG_HOST": "db", "UNRELATED": "one"}}}}
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{ResourceVersion: "1"}}
	initial := agentRuntimeSchemaInputHash(ai, testSchemaImage, secret)
	ai.Spec.Feature.Env["UNRELATED"] = "two"
	assert.Equal(t, initial, agentRuntimeSchemaInputHash(ai, testSchemaImage, secret))
	ai.Spec.Feature.SchemaRetryNonce = "retry"
	assert.NotEqual(t, initial, agentRuntimeSchemaInputHash(ai, testSchemaImage, secret))
	ai.Spec.Feature.SchemaRetryNonce = ""
	secret.ResourceVersion = "2"
	assert.NotEqual(t, initial, agentRuntimeSchemaInputHash(ai, testSchemaImage, secret))
	assert.NotEqual(t, initial, agentRuntimeSchemaInputHash(ai, "registry.example/schema@sha256:"+strings.Repeat("b", 64), &corev1.Secret{ObjectMeta: metav1.ObjectMeta{ResourceVersion: "1"}}))
}

func TestSchemaCommandStopsWaitingWithoutPrintingDatabaseURL(t *testing.T) {
	dir := t.TempDir()
	count := filepath.Join(dir, "count")
	delays := filepath.Join(dir, "delays")
	require.NoError(t, os.WriteFile(filepath.Join(dir, "pg_isready"), []byte("#!/bin/sh\nprintf x >> \"$COUNT_FILE\"\nexit 1\n"), 0700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "sleep"), []byte("#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$DELAY_FILE\"\n"), 0700))
	cmd := exec.Command("sh", "-c", schemaSetupCommand)
	cmd.Env = append(os.Environ(), "PATH="+dir+":"+os.Getenv("PATH"), "COUNT_FILE="+count, "DELAY_FILE="+delays, "DATABASE_URL=postgresql://user:secret@db/checkpoint?token=secret")
	out, err := cmd.CombinedOutput()
	require.Error(t, err)
	assert.NotContains(t, string(out), "secret")
	assert.Contains(t, string(out), "postgres unavailable after bounded wait")
	callCount, err := os.ReadFile(count)
	require.NoError(t, err)
	assert.Len(t, callCount, 12)
	delayData, err := os.ReadFile(delays)
	require.NoError(t, err)
	assert.Equal(t, []string{"1", "2", "4", "8", "8", "8", "8", "8", "8", "8", "8"}, strings.Fields(string(delayData)))
	t.Logf("unreachable database: attempts=%d backoff=%q diagnostic=%q", len(callCount), strings.Fields(string(delayData)), strings.TrimSpace(string(out)))
}
