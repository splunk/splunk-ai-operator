package agentruntime

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestLASConditionReplacesLegacyConditions(t *testing.T) {
	scheme := buildAgentRuntimeTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "las-service", Namespace: "default", Generation: 2},
		Status: aiv1.AIServiceStatus{Conditions: []metav1.Condition{
			{Type: "PostgresSchemaSetupReady", Status: metav1.ConditionFalse, Reason: "Error", Message: "legacy job is still running"},
			{Type: "Ready", Status: metav1.ConditionUnknown, Reason: "Installing", Message: "installing LAS"},
		}},
	}
	client := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&aiv1.AIService{}).WithObjects(ai).Build()
	las := &LASReconciler{Client: client, Scheme: scheme}

	require.NoError(t, las.setCondition(context.Background(), ai, metav1.ConditionTrue, "LASReady", "LAS is ready"))
	updated := &aiv1.AIService{}
	require.NoError(t, client.Get(context.Background(), types.NamespacedName{Name: ai.Name, Namespace: ai.Namespace}, updated))
	require.Len(t, updated.Status.Conditions, 1)
	assert.Equal(t, "Ready", updated.Status.Conditions[0].Type)
	assert.Equal(t, metav1.ConditionTrue, updated.Status.Conditions[0].Status)
	assert.Equal(t, "LASReady", updated.Status.Conditions[0].Reason)
}

func TestLASLegacyCleanupPreservesCompatibilityServiceAndOtherOwners(t *testing.T) {
	scheme := buildAgentRuntimeTestScheme(t)
	controller := true
	ai := &aiv1.AIService{ObjectMeta: metav1.ObjectMeta{Name: "las-service", Namespace: "default", UID: types.UID("las-uid")}}
	owner := metav1.OwnerReference{APIVersion: "ai.splunk.com/v1", Kind: "AIService", Name: ai.Name, UID: ai.UID, Controller: &controller}
	legacy := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "legacy-runtime", Namespace: ai.Namespace, OwnerReferences: []metav1.OwnerReference{owner}}}
	compatibility := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: agentRuntimeServiceName(ai.Name), Namespace: ai.Namespace, OwnerReferences: []metav1.OwnerReference{owner}}}
	unrelated := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "external-config", Namespace: ai.Namespace}}
	client := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, legacy, compatibility, unrelated).Build()
	las := &LASReconciler{Client: client, Scheme: scheme}

	require.NoError(t, las.removeLegacyResources(context.Background(), ai))
	require.Error(t, client.Get(context.Background(), types.NamespacedName{Name: legacy.Name, Namespace: ai.Namespace}, &appsv1.Deployment{}))
	require.NoError(t, client.Get(context.Background(), types.NamespacedName{Name: compatibility.Name, Namespace: ai.Namespace}, &corev1.Service{}))
	require.NoError(t, client.Get(context.Background(), types.NamespacedName{Name: unrelated.Name, Namespace: ai.Namespace}, &corev1.ConfigMap{}))
}
