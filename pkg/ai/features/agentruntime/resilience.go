package agentruntime

import (
	"context"
	"errors"
	"fmt"
	"maps"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/validation/field"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

const schemaComponent = "agentruntime-schema-setup"

func schemaSelectorLabels(ai *aiv1.AIService) map[string]string {
	return map[string]string{"app": agentRuntimeWorkloadName(ai.Name), "component": schemaComponent}
}

func (r *AgentRuntimeReconciler) reconcileDisruptionBudget(ctx context.Context, ai *aiv1.AIService) error {
	budget := &policyv1.PodDisruptionBudget{ObjectMeta: metav1.ObjectMeta{
		Name: dnsLabelName(ai.Name, "agentruntime-pdb"), Namespace: ai.Namespace,
	}}
	_, err := controllerutil.CreateOrPatch(ctx, r.Client, budget, func() error {
		if err := common.ClaimOrRefuse(ai, budget, r.Scheme); err != nil {
			return err
		}
		// Kubernetes computes the budget from the scale target as HPA changes it.
		// One voluntary eviction is allowed even at the singleton floor.
		budget.Spec = policyv1.PodDisruptionBudgetSpec{
			MaxUnavailable: ptr(intstr.FromInt32(1)),
			Selector:       &metav1.LabelSelector{MatchLabels: agentRuntimeSelectorLabels(ai)},
		}
		return nil
	})
	return err
}

func (r *AgentRuntimeReconciler) reconcileNetworkPolicies(ctx context.Context, ai *aiv1.AIService) error {
	runtimeSpec := isolatedNetworkSpec(agentRuntimeSelectorLabels(ai))
	schemaSpec := isolatedNetworkSpec(schemaSelectorLabels(ai))
	config, slim, configErr := r.resolveNetworkPolicy(ctx, ai)
	var invalid *schemaStageError
	if configErr != nil && !errors.As(configErr, &invalid) {
		// A temporary API failure says nothing about the last applied allowlist.
		return configErr
	}
	if configErr == nil {
		dns := networkingv1.NetworkPolicyEgressRule{
			To: []networkingv1.NetworkPolicyPeer{networkPeer(config.DNS)},
			Ports: []networkingv1.NetworkPolicyPort{
				networkPort(corev1.ProtocolUDP, 53),
				networkPort(corev1.ProtocolTCP, 53),
			},
		}
		postgres := networkEgress(config.PostgreSQL)
		runtimeSpec.Egress = []networkingv1.NetworkPolicyEgressRule{dns, postgres}
		schemaSpec.Egress = []networkingv1.NetworkPolicyEgressRule{dns, postgres}
		for _, destination := range config.RuntimeEgress {
			runtimeSpec.Egress = append(runtimeSpec.Egress, networkEgress(destination))
		}
		if slim != nil {
			runtimeSpec.Ingress = append(runtimeSpec.Ingress, networkIngress(*slim, defaultAgentRuntimeHTTPPort))
		}
		if ai.Spec.Metrics.Enabled && config.Metrics != nil {
			runtimeSpec.Ingress = append(runtimeSpec.Ingress, networkIngress(*config.Metrics, defaultAgentRuntimeMetrics))
		}
	}

	// Older CRs can predate admission for this field. Install deny-only rules
	// on invalid inputs so pre-existing workloads do not keep open access.
	// Try both policies even if one name conflicts with an existing object.
	applyErr := errors.Join(
		r.reconcileNetworkPolicy(ctx, ai, "schema-network", schemaSpec),
		r.reconcileNetworkPolicy(ctx, ai, "network", runtimeSpec),
	)
	if applyErr != nil {
		return applyErr
	}
	return configErr
}

func (r *AgentRuntimeReconciler) resolveNetworkPolicy(ctx context.Context, ai *aiv1.AIService) (*aiv1.AgentRuntimeNetworkPolicy, *aiv1.AgentRuntimeNetworkPeer, error) {
	config := ai.Spec.Feature.NetworkPolicy
	owner := metav1.GetControllerOf(ai)
	managed := owner != nil && owner.APIVersion == aiv1.GroupVersion.String() && owner.Kind == "AIPlatform"
	var platform *aiv1.AIPlatform
	if managed && (config == nil || config.SLIM == nil) {
		platform = &aiv1.AIPlatform{}
		err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: owner.Name}, platform)
		if err != nil && !apierrors.IsNotFound(err) {
			return nil, nil, fmt.Errorf("read the owning AIPlatform: %w", err)
		}
		if err != nil || platform.UID != owner.UID {
			return nil, nil, schemaState("InvalidNetworkPolicy", "cannot resolve the owning AIPlatform for the AgentRuntime network policy")
		}
		if config == nil {
			// Upgrade preflight saves the allowlist on the parent first. An older
			// controller may not have copied it to the generated AIService yet.
			for _, feature := range platform.Spec.Features {
				if feature.Name == ai.Spec.Feature.Name && feature.Provider == ai.Spec.Feature.Provider {
					config = feature.NetworkPolicy
					break
				}
			}
		}
	}
	if errs := config.Validate(field.NewPath("spec", "features", "networkPolicy"), !managed); len(errs) != 0 {
		return nil, nil, schemaState("InvalidNetworkPolicy", errs.ToAggregate().Error())
	}
	if config.SLIM != nil || platform == nil {
		return config, config.SLIM, nil
	}
	for _, feature := range platform.Spec.Features {
		if feature.Name == "slim" {
			return config, &aiv1.AgentRuntimeNetworkPeer{PodSelector: common.SLIMPodSelector(owner.Name + "-slim")}, nil
		}
	}
	return config, nil, nil
}

func isolatedNetworkSpec(labels map[string]string) networkingv1.NetworkPolicySpec {
	return networkingv1.NetworkPolicySpec{
		PodSelector: metav1.LabelSelector{MatchLabels: labels},
		PolicyTypes: []networkingv1.PolicyType{networkingv1.PolicyTypeIngress, networkingv1.PolicyTypeEgress},
	}
}

func (r *AgentRuntimeReconciler) reconcileNetworkPolicy(ctx context.Context, ai *aiv1.AIService, suffix string, spec networkingv1.NetworkPolicySpec) error {
	policy := &networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{
		Name: dnsLabelName(ai.Name, suffix), Namespace: ai.Namespace,
	}}
	_, err := controllerutil.CreateOrPatch(ctx, r.Client, policy, func() error {
		if err := common.ClaimOrRefuse(ai, policy, r.Scheme); err != nil {
			return err
		}
		policy.Spec = spec
		return nil
	})
	if err != nil {
		return fmt.Errorf("reconcile %s: %w", suffix, err)
	}
	return nil
}

func networkPeer(peer aiv1.AgentRuntimeNetworkPeer) networkingv1.NetworkPolicyPeer {
	if peer.CIDR != "" {
		return networkingv1.NetworkPolicyPeer{IPBlock: &networkingv1.IPBlock{CIDR: peer.CIDR}}
	}
	target := networkingv1.NetworkPolicyPeer{PodSelector: &metav1.LabelSelector{MatchLabels: maps.Clone(peer.PodSelector)}}
	if peer.Namespace != "" {
		// A pod and namespace selector in the same peer must both match.
		target.NamespaceSelector = &metav1.LabelSelector{MatchLabels: map[string]string{
			corev1.LabelMetadataName: peer.Namespace,
		}}
	}
	return target
}

func networkPort(protocol corev1.Protocol, port int32) networkingv1.NetworkPolicyPort {
	return networkingv1.NetworkPolicyPort{Protocol: &protocol, Port: ptr(intstr.FromInt32(port))}
}

func networkIngress(peer aiv1.AgentRuntimeNetworkPeer, port int32) networkingv1.NetworkPolicyIngressRule {
	return networkingv1.NetworkPolicyIngressRule{
		From:  []networkingv1.NetworkPolicyPeer{networkPeer(peer)},
		Ports: []networkingv1.NetworkPolicyPort{networkPort(corev1.ProtocolTCP, port)},
	}
}

func networkEgress(destination aiv1.AgentRuntimeNetworkDestination) networkingv1.NetworkPolicyEgressRule {
	return networkingv1.NetworkPolicyEgressRule{
		To:    []networkingv1.NetworkPolicyPeer{networkPeer(destination.Peer)},
		Ports: []networkingv1.NetworkPolicyPort{networkPort(corev1.ProtocolTCP, destination.Port)},
	}
}
