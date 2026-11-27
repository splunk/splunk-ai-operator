package agentruntime

import (
	"context"
	"testing"

	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func testNetworkPolicy() *aiv1.AgentRuntimeNetworkPolicy {
	return &aiv1.AgentRuntimeNetworkPolicy{
		DNS: aiv1.AgentRuntimeNetworkPeer{Namespace: "kube-system", PodSelector: map[string]string{"k8s-app": "kube-dns"}},
		PostgreSQL: aiv1.AgentRuntimeNetworkDestination{
			Peer: aiv1.AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "postgres"}}, Port: 5432,
		},
		SLIM:    &aiv1.AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "slim"}},
		Metrics: &aiv1.AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "prometheus"}},
	}
}

func TestAgentRuntimeNetworkAndDisruptionResources(t *testing.T) {
	ctx := context.Background()
	scheme := buildAgentRuntimeTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "example-agentruntime-mltk", Namespace: "default", UID: "runtime-uid"},
		Spec: aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk", NetworkPolicy: testNetworkPolicy()},
			Metrics: aiv1.MetricsConfig{Enabled: true}},
	}
	ai.Spec.Feature.NetworkPolicy.Metrics = &aiv1.AgentRuntimeNetworkPeer{Namespace: "monitoring", PodSelector: map[string]string{"app": "prometheus"}}
	ai.Spec.Feature.NetworkPolicy.RuntimeEgress = []aiv1.AgentRuntimeNetworkDestination{
		{Peer: aiv1.AgentRuntimeNetworkPeer{Namespace: "models", PodSelector: map[string]string{"app": "model"}}, Port: 8000},
		{Peer: aiv1.AgentRuntimeNetworkPeer{CIDR: "10.25.32.0/24"}, Port: 443},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(ai).WithObjects(ai).Build()
	r := &AgentRuntimeReconciler{Client: c, Scheme: scheme, Recorder: record.NewFakeRecorder(20)}
	get := func(suffix string, obj client.Object) {
		t.Helper()
		require.NoError(t, c.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-" + suffix}, obj))
		require.True(t, metav1.IsControlledBy(obj, ai), "%s should be controlled by the AIService", suffix)
	}
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	require.NoError(t, r.reconcileDisruptionBudget(ctx, ai))

	runtimePolicy, schemaPolicy := &networkingv1.NetworkPolicy{}, &networkingv1.NetworkPolicy{}
	get("network", runtimePolicy)
	get("schema-network", schemaPolicy)
	budget := &policyv1.PodDisruptionBudget{}
	get("agentruntime-pdb", budget)
	require.Equal(t, intstr.FromInt32(1), *budget.Spec.MaxUnavailable)
	require.Nil(t, budget.Spec.MinAvailable)
	require.Equal(t, runtimePolicy.Spec.PodSelector, *budget.Spec.Selector)
	for _, obj := range []*networkingv1.NetworkPolicy{runtimePolicy, schemaPolicy} {
		require.Equal(t, []networkingv1.PolicyType{networkingv1.PolicyTypeIngress, networkingv1.PolicyTypeEgress}, obj.Spec.PolicyTypes)
	}
	selector, err := metav1.LabelSelectorAsSelector(&runtimePolicy.Spec.PodSelector)
	require.NoError(t, err)
	require.True(t, selector.Matches(labels.Set(agentRuntimeSelectorLabels(ai))))
	require.False(t, selector.Matches(labels.Set(SchemaSelectorLabels(ai.Name))))
	selector, err = metav1.LabelSelectorAsSelector(&schemaPolicy.Spec.PodSelector)
	require.NoError(t, err)
	require.True(t, selector.Matches(labels.Set(SchemaSelectorLabels(ai.Name))))
	require.False(t, selector.Matches(labels.Set(SchemaSelectorLabels("another-runtime"))))
	require.Empty(t, schemaPolicy.Spec.Ingress)
	require.Len(t, runtimePolicy.Spec.Ingress, 2)
	require.Equal(t, int32(8080), runtimePolicy.Spec.Ingress[0].Ports[0].Port.IntVal)
	require.Equal(t, int32(9090), runtimePolicy.Spec.Ingress[1].Ports[0].Port.IntVal)
	require.Equal(t, "monitoring", runtimePolicy.Spec.Ingress[1].From[0].NamespaceSelector.MatchLabels[corev1.LabelMetadataName])
	require.Contains(t, runtimePolicy.Spec.Ingress[1].From[0].PodSelector.MatchLabels, "app")
	require.Len(t, runtimePolicy.Spec.Egress, 4)
	require.Equal(t, runtimePolicy.Spec.Egress[:2], schemaPolicy.Spec.Egress)
	require.Equal(t, "kube-system", schemaPolicy.Spec.Egress[0].To[0].NamespaceSelector.MatchLabels[corev1.LabelMetadataName])
	require.Equal(t, []networkingv1.NetworkPolicyPort{networkPort(corev1.ProtocolUDP, 53), networkPort(corev1.ProtocolTCP, 53)}, schemaPolicy.Spec.Egress[0].Ports)
	require.Equal(t, int32(5432), schemaPolicy.Spec.Egress[1].Ports[0].Port.IntVal)
	require.Equal(t, "10.25.32.0/24", runtimePolicy.Spec.Egress[3].To[0].IPBlock.CIDR)

	ai.Spec.Feature.NetworkPolicy.RuntimeEgress = nil
	ai.Spec.Metrics.Enabled = false
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	get("network", runtimePolicy)
	require.Len(t, runtimePolicy.Spec.Egress, 2)
	require.Len(t, runtimePolicy.Spec.Ingress, 1)
	before := runtimePolicy.ResourceVersion
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	get("network", runtimePolicy)
	require.Equal(t, before, runtimePolicy.ResourceVersion)

	ai.Spec.Feature.NetworkPolicy = nil
	require.ErrorContains(t, r.Reconcile(ctx, ai), "spec.features.networkPolicy")
	get("network", runtimePolicy)
	get("schema-network", schemaPolicy)
	require.Empty(t, runtimePolicy.Spec.Ingress)
	require.Empty(t, runtimePolicy.Spec.Egress)
	require.Empty(t, schemaPolicy.Spec.Egress)
	require.Equal(t, "InvalidNetworkPolicy", meta.FindStatusCondition(ai.Status.Conditions, "Ready").Reason)
}

func TestAgentRuntimePolicyUsesStagedParentAllowlist(t *testing.T) {
	ctx := context.Background()
	scheme := buildAgentRuntimeTestScheme(t)
	config := testNetworkPolicy()
	config.SLIM = nil
	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "stack", Namespace: "default", UID: "platform-uid"},
		Spec: aiv1.AIPlatformSpec{Features: []aiv1.FeatureSpec{
			{Name: "agentruntime", Provider: "mltk", NetworkPolicy: config}, {Name: "slim"},
		}},
	}
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "stack-agentruntime-mltk", Namespace: "default", UID: "runtime-uid",
			OwnerReferences: []metav1.OwnerReference{*metav1.NewControllerRef(platform, aiv1.GroupVersion.WithKind("AIPlatform"))}},
		Spec: aiv1.AIServiceSpec{
			Feature: aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk", NetworkPolicy: testNetworkPolicy()},
			Metrics: aiv1.MetricsConfig{Enabled: true},
		},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, platform).Build()
	r := &AgentRuntimeReconciler{Client: c, Scheme: scheme}
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	np := &networkingv1.NetworkPolicy{}
	key := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-network"}
	require.NoError(t, c.Get(ctx, key, np))
	// A valid stale child copy selects a different SLIM, which must never be used.
	require.Equal(t, map[string]string{"app": "stack-slim", "component": "stack-slim"}, np.Spec.Ingress[0].From[0].PodSelector.MatchLabels)
	require.Len(t, np.Spec.Ingress, 2)
	require.NoError(t, r.reconcileServiceMonitor(ctx, ai))
	monitorKey := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-metrics"}
	require.NoError(t, c.Get(ctx, monitorKey, &monitoringv1.ServiceMonitor{}))

	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(platform), platform))
	platform.Spec.Features[0].NetworkPolicy.Metrics = nil
	platform.Spec.Features[0].NetworkPolicy.MetricsDisabled = true
	require.NoError(t, c.Update(ctx, platform))
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	require.NoError(t, c.Get(ctx, key, np))
	require.Len(t, np.Spec.Ingress, 1)
	require.NoError(t, r.reconcileServiceMonitor(ctx, ai))
	require.True(t, apierrors.IsNotFound(c.Get(ctx, monitorKey, &monitoringv1.ServiceMonitor{})))

	// A same-named customer policy must not be edited or adopted.
	require.NoError(t, c.Delete(ctx, np))
	customer := &networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}, Spec: isolatedNetworkSpec(map[string]string{"app": "customer"})}
	require.NoError(t, c.Create(ctx, customer))
	require.ErrorContains(t, r.reconcileNetworkPolicies(ctx, ai), "is not managed by this AIService")
	require.NoError(t, c.Get(ctx, key, np))
	require.Equal(t, customer.Spec, np.Spec)
	require.Empty(t, np.OwnerReferences)
	guardKey := client.ObjectKey{Namespace: ai.Namespace, Name: policyGuardName(ai, runtimePolicySuffix)}
	guard := &networkingv1.NetworkPolicy{}
	require.NoError(t, c.Get(ctx, guardKey, guard))
	require.True(t, metav1.IsControlledBy(guard, ai))
	require.Equal(t, isolatedNetworkSpec(agentRuntimeSelectorLabels(ai)), guard.Spec)

	require.NoError(t, c.Delete(ctx, customer))
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	require.True(t, apierrors.IsNotFound(c.Get(ctx, guardKey, guard)))
	require.NoError(t, c.Get(ctx, key, np))
	require.True(t, metav1.IsControlledBy(np, ai))
	require.Len(t, np.Spec.Ingress, 1)
}

func TestAgentRuntimeMetricsOptOutRemovesOnlyOwnedMonitor(t *testing.T) {
	ctx := context.Background()
	scheme := buildAgentRuntimeTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "runtime", Namespace: "default", UID: "runtime-uid"},
		Spec: aiv1.AIServiceSpec{
			Feature: aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk", NetworkPolicy: testNetworkPolicy()},
			Metrics: aiv1.MetricsConfig{Enabled: true, Path: "/metrics"},
		},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &AgentRuntimeReconciler{Client: c, Scheme: scheme}
	monitorKey := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-agentruntime-metrics"}
	monitor := &monitoringv1.ServiceMonitor{}
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	require.NoError(t, r.reconcileServiceMonitor(ctx, ai))
	require.NoError(t, c.Get(ctx, monitorKey, monitor))
	require.True(t, metav1.IsControlledBy(monitor, ai))

	config := ai.Spec.Feature.NetworkPolicy
	config.Metrics = nil
	require.ErrorContains(t, r.reconcileNetworkPolicies(ctx, ai), "must select an approved scraper")
	config.MetricsDisabled = true
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	require.NoError(t, r.reconcileServiceMonitor(ctx, ai))
	require.True(t, apierrors.IsNotFound(c.Get(ctx, monitorKey, monitor)))
	policy := &networkingv1.NetworkPolicy{}
	require.NoError(t, c.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: dnsLabelName(ai.Name, runtimePolicySuffix)}, policy))
	require.Len(t, policy.Spec.Ingress, 1)
	require.Equal(t, int32(8080), policy.Spec.Ingress[0].Ports[0].Port.IntVal)
	require.Len(t, policy.Spec.Egress, 2)

	foreign := &monitoringv1.ServiceMonitor{ObjectMeta: metav1.ObjectMeta{Name: monitorKey.Name, Namespace: monitorKey.Namespace}}
	require.NoError(t, c.Create(ctx, foreign))
	require.NoError(t, r.reconcileServiceMonitor(ctx, ai))
	require.NoError(t, c.Get(ctx, monitorKey, monitor))
	require.Equal(t, foreign.ResourceVersion, monitor.ResourceVersion)
}

func TestAgentRuntimeIsolatesLegacySchemaJobByUID(t *testing.T) {
	ctx := context.Background()
	scheme := buildAgentRuntimeTestScheme(t)
	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "runtime", Namespace: "default", UID: "runtime-uid"},
		Spec:       aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk", NetworkPolicy: testNetworkPolicy()}},
	}
	legacy := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name: "schema-legacy", Namespace: ai.Namespace, UID: types.UID("legacy-uid"),
			Annotations:     map[string]string{schemaJobManagedAnnotation: schemaJobManagedValue},
			OwnerReferences: []metav1.OwnerReference{*metav1.NewControllerRef(ai, aiv1.GroupVersion.WithKind("AIService"))},
		},
		Spec: batchv1.JobSpec{
			Selector: &metav1.LabelSelector{MatchLabels: map[string]string{batchv1.ControllerUidLabel: "legacy-uid"}},
			Template: corev1.PodTemplateSpec{ObjectMeta: metav1.ObjectMeta{Labels: map[string]string{
				"app": "customer-app", "component": schemaComponent, batchv1.ControllerUidLabel: "legacy-uid",
			}}},
		},
		Status: batchv1.JobStatus{Active: 1},
	}
	unrelated := legacy.DeepCopy()
	unrelated.Name = "other-job"
	unrelated.UID = "other-uid"
	unrelated.OwnerReferences = nil
	unrelated.Spec.Selector.MatchLabels[batchv1.ControllerUidLabel] = "other-uid"
	unrelated.Spec.Template.Labels[batchv1.ControllerUidLabel] = "other-uid"
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, legacy, unrelated).WithStatusSubresource(legacy).Build()
	r := &AgentRuntimeReconciler{Client: c, Scheme: scheme}
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))

	key := client.ObjectKey{Namespace: ai.Namespace, Name: dnsLabelName(ai.Name, legacySchemaPolicySuffix)}
	policy := &networkingv1.NetworkPolicy{}
	require.NoError(t, c.Get(ctx, key, policy))
	require.True(t, metav1.IsControlledBy(policy, ai))
	selector, err := metav1.LabelSelectorAsSelector(&policy.Spec.PodSelector)
	require.NoError(t, err)
	require.True(t, selector.Matches(labels.Set(legacy.Spec.Template.Labels)))
	require.False(t, selector.Matches(labels.Set(unrelated.Spec.Template.Labels)))
	require.Empty(t, policy.Spec.Ingress)
	require.Len(t, policy.Spec.Egress, 2)
	require.Equal(t, int32(5432), policy.Spec.Egress[1].Ports[0].Port.IntVal)
	state := &batchv1.Job{}
	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(legacy), state))
	require.Equal(t, legacy.Spec, state.Spec)
	state.Status.Active = 0
	state.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}
	require.NoError(t, c.Status().Update(ctx, state))
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	require.True(t, apierrors.IsNotFound(c.Get(ctx, key, policy)))
	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(legacy), state))
}
