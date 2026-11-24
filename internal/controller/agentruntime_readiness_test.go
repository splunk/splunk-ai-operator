package controller

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/yaml"
)

func TestRuntimeReadinessEventPredicates(t *testing.T) {
	for _, object := range []client.Object{&corev1.Pod{}, &discoveryv1.EndpointSlice{}} {
		p := runtimeBackendChangedPredicate()
		assert.True(t, p.Create(event.CreateEvent{Object: object}))
		assert.True(t, p.Delete(event.DeleteEvent{Object: object}))
		assert.False(t, p.Update(event.UpdateEvent{ObjectOld: object, ObjectNew: object.DeepCopyObject().(client.Object)}))
	}
	pod := &corev1.Pod{Status: corev1.PodStatus{Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}}}
	changedPod := pod.DeepCopy()
	changedPod.Status.Conditions[0].Status = corev1.ConditionFalse
	podEvent := event.UpdateEvent{ObjectOld: pod, ObjectNew: changedPod}
	assert.True(t, runtimeBackendChangedPredicate().Update(podEvent))
	assert.True(t, aiServiceGlobalEventFilter().Update(podEvent))
	slice := &discoveryv1.EndpointSlice{Endpoints: []discoveryv1.Endpoint{{Conditions: discoveryv1.EndpointConditions{Ready: boolPtr(true)}}}}
	changedSlice := slice.DeepCopy()
	changedSlice.Endpoints = nil
	sliceEvent := event.UpdateEvent{ObjectOld: slice, ObjectNew: changedSlice}
	assert.True(t, runtimeBackendChangedPredicate().Update(sliceEvent))
	assert.True(t, aiServiceGlobalEventFilter().Update(sliceEvent))
	service := &corev1.Service{Spec: corev1.ServiceSpec{Selector: map[string]string{"app": "runtime"}}}
	changedService := service.DeepCopy()
	changedService.Spec.Selector["app"] = "other"
	serviceEvent := event.UpdateEvent{ObjectOld: service, ObjectNew: changedService}
	assert.True(t, runtimeBackendChangedPredicate().Update(serviceEvent), "Service spec changes need not increment generation")
	assert.True(t, aiServiceGlobalEventFilter().Update(serviceEvent))

	ai := &aiv1.AIService{Spec: aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime"}}, Status: aiv1.AIServiceStatus{Conditions: []metav1.Condition{{Type: "Ready", Status: metav1.ConditionTrue}}}}
	changed := ai.DeepCopy()
	changed.Status.Conditions[0].Status = metav1.ConditionFalse
	changed.Status.Conditions[0].Reason = "Pending"
	readinessEvent := event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}
	assert.True(t, agentRuntimeReadyChangedPredicate().Update(readinessEvent))
	assert.True(t, aiServiceGlobalEventFilter().Update(readinessEvent))
	assert.False(t, aiServiceEventFilter().Update(readinessEvent), "the primary watch should ignore runtime status writes")
	assert.True(t, agentRuntimeReadyChangedPredicate().Create(event.CreateEvent{Object: ai}))
	assert.True(t, agentRuntimeReadyChangedPredicate().Delete(event.DeleteEvent{Object: ai}))
	changed = ai.DeepCopy()
	changed.Status.Conditions[0].LastTransitionTime = metav1.Now()
	assert.False(t, agentRuntimeReadyChangedPredicate().Update(event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}), "timestamp-only writes must not wake route consumers")
	changed = ai.DeepCopy()
	changed.Spec.VectorDbUrl = "unrelated"
	assert.False(t, agentRuntimeReadyChangedPredicate().Update(event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}))
	changed.OwnerReferences = []metav1.OwnerReference{{Controller: boolPtr(true), UID: "new-platform"}}
	ownershipEvent := event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}
	assert.True(t, agentRuntimeReadyChangedPredicate().Update(ownershipEvent))
	assert.True(t, aiServiceEventFilter().Update(ownershipEvent))
	changed = ai.DeepCopy()
	ai.Spec.Feature.Name = "slim"
	assert.True(t, agentRuntimeReadyChangedPredicate().Update(event.UpdateEvent{ObjectOld: changed, ObjectNew: ai}), "a departing Runtime's former sibling must reconcile")
	changed.Spec.Feature.Name = "slim"
	changed.Status.Conditions[0].Status = metav1.ConditionFalse
	assert.False(t, agentRuntimeReadyChangedPredicate().Update(event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}))
	changed = ai.DeepCopy()
	deletingAt := metav1.Now()
	changed.DeletionTimestamp = &deletingAt
	assert.True(t, aiServiceEventFilter().Update(event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}), "starting SLIM deletion must reconcile the primary object")
}

func TestRuntimeReadinessEventsMapToOwnedSlimSibling(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(scheme))
	owner := metav1.OwnerReference{
		APIVersion: aiv1.GroupVersion.String(), Kind: "AIPlatform",
		Name: "test-platform", UID: "test-platform-uid", Controller: boolPtr(true),
	}
	runtime := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "runtime", Namespace: "test", OwnerReferences: []metav1.OwnerReference{owner}},
		Spec:       aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime"}},
	}
	slim := runtime.DeepCopy()
	slim.Name = "slim"
	slim.Spec.Feature.Name = "slim"
	otherNamespace := slim.DeepCopy()
	otherNamespace.Namespace = "other"
	otherPlatform := slim.DeepCopy()
	otherPlatform.Name = "other-slim"
	otherPlatform.OwnerReferences[0].UID = "old-platform-uid"
	standalone := slim.DeepCopy()
	standalone.Name = "standalone-slim"
	standalone.OwnerReferences = nil
	terminating := slim.DeepCopy()
	terminating.Name = "terminating-slim"
	terminating.DeletionTimestamp = &metav1.Time{Time: time.Now()}
	terminating.Finalizers = []string{"test.example.org/hold"}

	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(runtime, slim, otherNamespace, otherPlatform, standalone, terminating).Build()
	r := &AIServiceReconciler{Client: c}
	requests := r.findSlimSiblingsForRuntime(context.Background(), runtime)
	require.Len(t, requests, 1)
	assert.Equal(t, client.ObjectKeyFromObject(slim), requests[0].NamespacedName)

	unownedRuntime := runtime.DeepCopy()
	unownedRuntime.OwnerReferences = nil
	assert.Empty(t, r.findSlimSiblingsForRuntime(context.Background(), unownedRuntime))
	assert.Empty(t, r.findSlimSiblingsForRuntime(context.Background(), slim))
}

func TestReferencedSecretEventsMapToCheckpointAndSlimTrustConsumers(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(scheme))
	secret := &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Namespace: "tenant", Name: "referenced-secret", ResourceVersion: "1"}}
	runtime := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "runtime", Namespace: secret.Namespace},
		Spec:       aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime"}, CheckpointDbSecretRef: secret.Name},
	}
	slim := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "slim", Namespace: secret.Namespace},
		Spec: aiv1.AIServiceSpec{
			Feature:             aiv1.FeatureSpec{Name: "slim"},
			SplunkConfiguration: aiv1.SplunkConfigurationSpec{CACertRef: &corev1.LocalObjectReference{Name: secret.Name}},
		},
	}
	otherNamespace := slim.DeepCopy()
	otherNamespace.Namespace = "other"
	otherSecret := slim.DeepCopy()
	otherSecret.Name = "other-slim"
	otherSecret.Spec.SplunkConfiguration.CACertRef.Name = "unrelated-secret"
	saia := slim.DeepCopy()
	saia.Name = "saia"
	saia.Spec.Feature.Name = "saia"
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(runtime, slim, otherNamespace, otherSecret, saia).Build()
	r := &AIServiceReconciler{Client: c}
	var actual []client.ObjectKey
	for _, request := range r.findAIServicesForReferencedSecret(context.Background(), secret) {
		actual = append(actual, request.NamespacedName)
	}
	assert.ElementsMatch(t, []client.ObjectKey{client.ObjectKeyFromObject(runtime), client.ObjectKeyFromObject(slim)}, actual)
	updatedSecret := secret.DeepCopy()
	updatedSecret.ResourceVersion = "2"
	update := event.UpdateEvent{ObjectOld: secret, ObjectNew: updatedSecret}
	assert.True(t, referencedSecretChangedPredicate().Update(update))
	assert.True(t, aiServiceGlobalEventFilter().Update(update))
	assert.True(t, referencedSecretChangedPredicate().Delete(event.DeleteEvent{Object: updatedSecret}))
}

func TestRuntimeBackendEventsMapWithoutDirectOwner(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(scheme))
	ai := &aiv1.AIService{ObjectMeta: metav1.ObjectMeta{Name: "runtime", Namespace: "test"}, Spec: aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime"}}}
	other := ai.DeepCopy()
	other.Namespace = "other"
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, other).WithIndex(&aiv1.AIService{}, runtimeWorkloadIndex, runtimeWorkloadKeys).Build()
	r := &AIServiceReconciler{Client: c}
	for _, object := range []client.Object{
		&discoveryv1.EndpointSlice{ObjectMeta: metav1.ObjectMeta{Namespace: "test", Labels: map[string]string{discoveryv1.LabelServiceName: agentruntime.ServiceName(ai.Name)}}},
		&corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: "test", Labels: map[string]string{"app": agentruntime.WorkloadName(ai.Name), "component": agentruntime.WorkloadName(ai.Name)}}},
		&appsv1.ReplicaSet{ObjectMeta: metav1.ObjectMeta{Namespace: "test", Labels: map[string]string{"app": agentruntime.WorkloadName(ai.Name), "component": agentruntime.WorkloadName(ai.Name)}}},
	} {
		requests := r.findRuntimeServicesForBackend(context.Background(), object)
		require.Len(t, requests, 1)
		assert.Equal(t, client.ObjectKeyFromObject(ai), requests[0].NamespacedName)
	}
	assert.Empty(t, r.findRuntimeServicesForBackend(context.Background(), &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: "test", Labels: map[string]string{"app": ai.Name, "component": "agentruntime-schema-setup"}}}))
}

func TestRuntimeReadinessRBACMatchesHelm(t *testing.T) {
	load := func(path string) rbacv1.ClusterRole {
		raw, err := os.ReadFile(path)
		require.NoError(t, err)
		// Only the role name is templated. Substitute it so the actual permission
		// rules can be compared without depending on Helm rendering or defaults.
		text := strings.ReplaceAll(string(raw), `{{ include "splunk-ai-operator.fullname" . }}-manager-role`, "manager-role")
		var role rbacv1.ClusterRole
		require.NoError(t, yaml.Unmarshal([]byte(text), &role))
		return role
	}
	source := load("../../config/rbac/role.yaml")
	helm := load("../../helm-chart/splunk-ai-operator/templates/rbac/role.yaml")
	assert.ElementsMatch(t, source.Rules, helm.Rules)
	for _, resource := range []struct{ group, name string }{{"apps", "replicasets"}, {"discovery.k8s.io", "endpointslices"}} {
		found := false
		for _, rule := range source.Rules {
			if len(rule.APIGroups) == 1 && rule.APIGroups[0] == resource.group && len(rule.Resources) == 1 && rule.Resources[0] == resource.name {
				assert.ElementsMatch(t, []string{"get", "list", "watch"}, rule.Verbs)
				found = true
			}
		}
		assert.True(t, found, "missing read-only access for %s/%s", resource.group, resource.name)
	}
}
