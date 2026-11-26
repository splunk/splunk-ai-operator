package agentruntime

import (
	"bytes"
	"context"
	"encoding/json"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	autoscalingv2 "k8s.io/api/autoscaling/v2"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func TestCheckpointWiringSurvivesPodReplacement(t *testing.T) {
	for _, profile := range []aiv1.AIPlatformProfile{aiv1.AIPlatformProfileCPUOnly, aiv1.AIPlatformProfileFullFeature} {
		t.Run(string(profile), func(t *testing.T) {
			ctx := context.Background()
			platform := platformWith(profile, profile == aiv1.AIPlatformProfileFullFeature)
			r, ai, job := schemaTestReconcilerWithPlatform(t, platform)
			assert.Equal(t, "Pending", schemaCondition(t, ai).Reason)
			assertConditionFalse(t, ai.Status.Conditions, "Ready")

			job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
			require.NoError(t, r.Status().Update(ctx, job))
			require.NoError(t, r.Reconcile(ctx, ai))
			installHealthyRuntime(t, r, ai)
			require.NoError(t, r.Reconcile(ctx, ai))
			assertConditionTrue(t, ai.Status.Conditions, "Ready")

			dep := &appsv1.Deployment{}
			depKey := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-deployment"}
			require.NoError(t, r.Get(ctx, depKey, dep))
			pod := &corev1.Pod{}
			require.NoError(t, r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-pod"}, pod))
			slice := &discoveryv1.EndpointSlice{}
			require.NoError(t, r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-endpoints"}, slice))
			secret := &corev1.Secret{}
			secretKey := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Spec.CheckpointDbSecretRef}
			require.NoError(t, r.Get(ctx, secretKey, secret))
			before := dep.DeepCopy()
			beforeSchema := *agentRuntimeSchemaStatus(t, ai)
			require.NotEmpty(t, beforeSchema.AppliedHash)

			assertWiring := func(phase string, pod *corev1.Pod) {
				t.Helper()
				require.NoError(t, r.Get(ctx, depKey, dep))
				require.NoError(t, r.Get(ctx, client.ObjectKeyFromObject(pod), pod))
				var jobs batchv1.JobList
				require.NoError(t, r.List(ctx, &jobs, client.InNamespace(ai.Namespace)))
				require.Len(t, jobs.Items, 1)
				currentJob := &jobs.Items[0]
				assert.Equal(t, job.Name, currentJob.Name)
				assert.Equal(t, job.ResourceVersion, currentJob.ResourceVersion)
				assert.Equal(t, before.ResourceVersion, dep.ResourceVersion)
				assert.True(t, equality.Semantic.DeepEqual(before.Spec.Template, dep.Spec.Template), "runtime Pod template changed")
				assert.True(t, equality.Semantic.DeepEqual(job.Spec.Template, currentJob.Spec.Template), "schema Job template changed")
				assert.Equal(t, beforeSchema, *agentRuntimeSchemaStatus(t, ai))
				assert.Equal(t, secret.Namespace, dep.Namespace)
				assert.Equal(t, secret.Namespace, currentJob.Namespace)
				assert.Equal(t, secret.Namespace, pod.Namespace)
				for _, spec := range []corev1.PodSpec{dep.Spec.Template.Spec, currentJob.Spec.Template.Spec, pod.Spec} {
					assertCheckpointReference(t, spec, secret)
				}
				var currentSecret corev1.Secret
				require.NoError(t, r.Get(ctx, secretKey, &currentSecret))
				assert.Equal(t, secret.ResourceVersion, currentSecret.ResourceVersion)
				assert.True(t, equality.Semantic.DeepEqual(secret.Data, currentSecret.Data), "referenced Secret data changed")
				ready := meta.FindStatusCondition(ai.Status.Conditions, "Ready")
				require.NotNil(t, ready)
				assert.Equal(t, ai.Generation, ready.ObservedGeneration)
				t.Logf("checkpoint snapshot phase=%s profile=%s podUID=%s secretRef=%s/%s secretVersion=%s deploymentVersion=%s templateHash=%s schemaJob=%s schemaJobVersion=%s schemaHash=%s ready=%s observedGeneration=%d",
					phase, profile, pod.UID, secret.Namespace, secret.Name, currentSecret.ResourceVersion, dep.ResourceVersion, stableHash(dep.Spec.Template), currentJob.Name, currentJob.ResourceVersion, beforeSchema.AppliedHash, ready.Status, ready.ObservedGeneration)
			}
			assertWiring("before", pod)

			// Simulate the workload controllers replacing the Pod without a Deployment
			// rollout. The stale endpoint must remain unusable until it points at the new Pod.
			require.NoError(t, r.Delete(ctx, pod))
			require.NoError(t, r.Reconcile(ctx, ai))
			assertConditionFalse(t, ai.Status.Conditions, "Ready")
			replacement := &corev1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Name: pod.Name + "-replacement", Namespace: pod.Namespace, UID: "replacement-pod",
					Labels: dep.Spec.Template.Labels, OwnerReferences: pod.OwnerReferences,
				},
				Spec: *dep.Spec.Template.Spec.DeepCopy(), Status: *pod.Status.DeepCopy(),
			}
			require.NotEqual(t, pod.UID, replacement.UID)
			replacement.Status.PodIP = "10.0.0.10"
			require.NoError(t, r.Create(ctx, replacement))
			require.NoError(t, r.Reconcile(ctx, ai))
			assertConditionFalse(t, ai.Status.Conditions, "Ready")
			endpoint := meta.FindStatusCondition(ai.Status.Conditions, endpointReady)
			require.NotNil(t, endpoint)
			assert.Equal(t, "EndpointTargetMismatch", endpoint.Reason)
			slice.Endpoints[0].Addresses = []string{replacement.Status.PodIP}
			slice.Endpoints[0].TargetRef.Name = replacement.Name
			slice.Endpoints[0].TargetRef.UID = replacement.UID
			require.NoError(t, r.Update(ctx, slice))
			require.NoError(t, r.Reconcile(ctx, ai))
			assertConditionTrue(t, ai.Status.Conditions, "Ready")
			assertWiring("replacement", replacement)

			// A new HPA CPU target exercises a real, unrelated reconcile without
			// changing checkpoint inputs or requiring a rollout.
			ai.Spec.TargetCPUUtilization = ptr(int32(75))
			ai.Generation++ // The fake API client does not advance generations.
			require.NoError(t, r.Update(ctx, ai))
			require.NoError(t, r.Reconcile(ctx, ai))
			var hpa autoscalingv2.HorizontalPodAutoscaler
			require.NoError(t, r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-hpa"}, &hpa))
			require.Len(t, hpa.Spec.Metrics, 1)
			require.NotNil(t, hpa.Spec.Metrics[0].Resource)
			assert.Equal(t, ai.Spec.TargetCPUUtilization, hpa.Spec.Metrics[0].Resource.Target.AverageUtilization)
			assertConditionTrue(t, ai.Status.Conditions, "Ready")
			assertWiring("unrelated-reconcile", replacement)
		})
	}
}

func assertCheckpointReference(t *testing.T, spec corev1.PodSpec, secret *corev1.Secret) {
	t.Helper()
	require.Len(t, spec.Containers, 1)
	container := spec.Containers[0]
	assert.Equal(t, []corev1.EnvFromSource{{SecretRef: &corev1.SecretEnvSource{
		LocalObjectReference: corev1.LocalObjectReference{Name: secret.Name},
	}}}, container.EnvFrom)
	for _, env := range container.Env {
		_, overlaps := secret.Data[env.Name]
		assert.False(t, overlaps, "a checkpoint setting must not override the imported Secret")
	}
	// Compare without putting Secret values into failure output or snapshots.
	encoded, err := json.Marshal(spec)
	require.NoError(t, err)
	for _, key := range []string{"DATABASE_URL", "PG_PASSWORD"} {
		assert.False(t, bytes.Contains(encoded, secret.Data[key]), "Pod spec contains a literal %s value", key)
	}
}
