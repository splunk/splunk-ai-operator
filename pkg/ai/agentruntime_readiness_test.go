package ai_platform

import (
	"context"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

func TestPlatformRequiresCurrentAgentRuntimeReady(t *testing.T) {
	for _, tc := range []struct {
		name           string
		mutate         func(*aiApi.AIService)
		missing, ready bool
	}{
		{name: "healthy", ready: true},
		{name: "missing child", missing: true},
		{name: "missing condition", mutate: func(ai *aiApi.AIService) { ai.Status.Conditions = nil }},
		{name: "pending reason", mutate: func(ai *aiApi.AIService) {
			ai.Status.Conditions[0].Status = metav1.ConditionFalse
			ai.Status.Conditions[0].Reason = "Pending"
		}},
		{name: "unknown", mutate: func(ai *aiApi.AIService) { ai.Status.Conditions[0].Status = metav1.ConditionUnknown }},
		{name: "stale condition", mutate: func(ai *aiApi.AIService) { ai.Status.Conditions[0].ObservedGeneration-- }},
		{name: "stale status", mutate: func(ai *aiApi.AIService) { ai.Status.ObservedGeneration-- }},
		{name: "wrong owner uid", mutate: func(ai *aiApi.AIService) { ai.OwnerReferences[0].UID = "previous-platform" }},
		{name: "terminating child", mutate: func(ai *aiApi.AIService) {
			now := metav1.Now()
			ai.DeletionTimestamp = &now
			ai.Finalizers = []string{"test"}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			scheme := runtime.NewScheme()
			require.NoError(t, aiApi.AddToScheme(scheme))
			p := buildCPUOnlyPlatform()
			p.UID = "platform-uid"
			p.Spec.Features = []aiApi.FeatureSpec{{Name: "agentruntime", Provider: "mltk"}}
			ai := &aiApi.AIService{ObjectMeta: metav1.ObjectMeta{Name: featureServiceName(p.Name, p.Spec.Features[0]), Namespace: p.Namespace, Generation: 3}, Spec: aiApi.AIServiceSpec{Feature: p.Spec.Features[0]}, Status: aiApi.AIServiceStatus{ObservedGeneration: 3, Conditions: []metav1.Condition{{Type: "Ready", Status: metav1.ConditionTrue, Reason: "Available", ObservedGeneration: 3}}}}
			require.NoError(t, controllerutil.SetControllerReference(p, ai, scheme))
			if tc.mutate != nil {
				tc.mutate(ai)
			}
			builder := fake.NewClientBuilder().WithScheme(scheme).WithIndex(&aiApi.AIService{}, ownerKey, func(obj client.Object) []string {
				if o := metav1.GetControllerOf(obj); o != nil {
					return []string{o.Name}
				}
				return nil
			})
			if !tc.missing {
				builder = builder.WithObjects(ai)
			}
			r := &AIPlatformReconciler{Client: builder.Build()}
			err := r.CheckAIServiceStatus(context.Background(), p)
			if tc.ready {
				require.NoError(t, err)
			} else {
				require.Error(t, err)
				assert.Contains(t, err.Error(), "current generation")
			}
		})
	}
}

func TestPlatformRuntimeReadinessTransitionsDoNotChurn(t *testing.T) {
	scheme := runtime.NewScheme()
	require.NoError(t, aiApi.AddToScheme(scheme))
	p := buildCPUOnlyPlatform()
	p.UID = "platform-uid"
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(p).WithStatusSubresource(&aiApi.AIPlatform{}, &aiApi.AIService{}).WithIndex(&aiApi.AIService{}, ownerKey, func(obj client.Object) []string {
		if o := metav1.GetControllerOf(obj); o != nil {
			return []string{o.Name}
		}
		return nil
	}).Build()
	r := New(p, c, scheme, record.NewFakeRecorder(20))
	reconcile := func() *aiApi.AIPlatform {
		latest := &aiApi.AIPlatform{}
		require.NoError(t, c.Get(context.Background(), client.ObjectKeyFromObject(p), latest))
		_, err := r.Reconcile(context.Background(), latest)
		require.NoError(t, err)
		return latest
	}
	got := reconcile()
	assert.Equal(t, metav1.ConditionFalse, meta.FindStatusCondition(got.Status.Conditions, "Ready").Status)
	var children aiApi.AIServiceList
	require.NoError(t, c.List(context.Background(), &children))
	var child *aiApi.AIService
	for i := range children.Items {
		if children.Items[i].Spec.Feature.Name == "agentruntime" {
			child = &children.Items[i]
		}
	}
	require.NotNil(t, child)
	child.Status.ObservedGeneration = child.Generation
	child.Status.Conditions = []metav1.Condition{{Type: "Ready", Status: metav1.ConditionTrue, ObservedGeneration: child.Generation}}
	require.NoError(t, c.Status().Update(context.Background(), child))
	got = reconcile()
	assert.Equal(t, metav1.ConditionTrue, meta.FindStatusCondition(got.Status.Conditions, "Ready").Status)
	before := got.DeepCopy()
	got = reconcile()
	assert.Equal(t, before.ResourceVersion, got.ResourceVersion)
	assert.Equal(t, before.Status, got.Status)
	child.Status.Conditions[0].Status = metav1.ConditionFalse
	child.Status.Conditions[0].Reason = "EndpointsPending"
	require.NoError(t, c.Status().Update(context.Background(), child))
	got = reconcile()
	assert.Equal(t, metav1.ConditionFalse, meta.FindStatusCondition(got.Status.Conditions, "Ready").Status)
}
