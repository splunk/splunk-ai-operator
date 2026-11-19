package controller

import (
	"context"
	"os"
	"strings"
	"testing"

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
	assert.True(t, agentRuntimeReadyChangedPredicate().Update(event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}))
	changed = ai.DeepCopy()
	changed.Status.Conditions[0].LastTransitionTime = metav1.Now()
	assert.False(t, agentRuntimeReadyChangedPredicate().Update(event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}), "timestamp-only child writes must not wake the parent")
	changed = ai.DeepCopy()
	changed.Spec.VectorDbUrl = "unrelated"
	assert.False(t, agentRuntimeReadyChangedPredicate().Update(event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}))
	ai.Spec.Feature.Name = "slim"
	changed.Spec.Feature.Name = "slim"
	changed.Status.Conditions[0].Status = metav1.ConditionFalse
	assert.False(t, agentRuntimeReadyChangedPredicate().Update(event.UpdateEvent{ObjectOld: ai, ObjectNew: changed}))
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
