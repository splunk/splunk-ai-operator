package agentruntime

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
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
		SLIM: &aiv1.AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "slim"}},
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
	require.False(t, selector.Matches(labels.Set(schemaSelectorLabels(ai))))
	selector, err = metav1.LabelSelectorAsSelector(&schemaPolicy.Spec.PodSelector)
	require.NoError(t, err)
	require.True(t, selector.Matches(labels.Set(schemaSelectorLabels(ai))))
	require.False(t, selector.Matches(labels.Set(schemaSelectorLabels(&aiv1.AIService{ObjectMeta: metav1.ObjectMeta{Name: "another-runtime"}}))))
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
		Spec: aiv1.AIServiceSpec{Feature: aiv1.FeatureSpec{Name: "agentruntime", Provider: "mltk"}},
	}
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, platform).Build()
	r := &AgentRuntimeReconciler{Client: c, Scheme: scheme}
	require.NoError(t, r.reconcileNetworkPolicies(ctx, ai))
	np := &networkingv1.NetworkPolicy{}
	key := client.ObjectKey{Namespace: ai.Namespace, Name: ai.Name + "-network"}
	require.NoError(t, c.Get(ctx, key, np))
	require.Equal(t, map[string]string{"app": "stack-slim", "component": "stack-slim"}, np.Spec.Ingress[0].From[0].PodSelector.MatchLabels)

	// A same-named customer policy must not be edited or adopted.
	require.NoError(t, c.Delete(ctx, np))
	customer := &networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}, Spec: isolatedNetworkSpec(map[string]string{"app": "customer"})}
	require.NoError(t, c.Create(ctx, customer))
	require.ErrorContains(t, r.reconcileNetworkPolicies(ctx, ai), "is not managed by this AIService")
	require.NoError(t, c.Get(ctx, key, np))
	require.Equal(t, customer.Spec, np.Spec)
	require.Empty(t, np.OwnerReferences)
}
