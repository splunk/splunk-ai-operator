package agentruntime

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"slices"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/apimachinery/pkg/util/validation/field"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

const (
	schemaComponent          = "agentruntime-schema-setup"
	runtimePolicySuffix      = "network"
	schemaPolicySuffix       = "schema-network"
	legacySchemaPolicySuffix = "schema-network-legacy"
	disruptionBudgetSuffix   = "agentruntime-pdb"
)

// ManagedResourceNames returns the names reserved for the AIService during an upgrade.
func ManagedResourceNames(aiServiceName string) (runtimePolicy, schemaPolicy, budget string) {
	return dnsLabelName(aiServiceName, runtimePolicySuffix), dnsLabelName(aiServiceName, schemaPolicySuffix), dnsLabelName(aiServiceName, disruptionBudgetSuffix)
}

// SchemaSelectorLabels identifies pods from new schema Jobs for this AIService.
func SchemaSelectorLabels(aiServiceName string) map[string]string {
	return map[string]string{"app": agentRuntimeWorkloadName(aiServiceName), "component": schemaComponent}
}

func (r *AgentRuntimeReconciler) reconcileDisruptionBudget(ctx context.Context, ai *aiv1.AIService) error {
	budget := &policyv1.PodDisruptionBudget{ObjectMeta: metav1.ObjectMeta{
		Name: dnsLabelName(ai.Name, disruptionBudgetSuffix), Namespace: ai.Namespace,
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
	schemaSpec := isolatedNetworkSpec(SchemaSelectorLabels(ai.Name))
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
		if config.ManagedRay {
			ray, err := r.managedRayNetworkRules(ctx, ai)
			if err != nil {
				if !errors.As(err, &invalid) {
					return err // A transient read failure must preserve the last reconciled policy.
				}
				configErr = err // Persist baseline isolation while the Ray route is unavailable.
			} else {
				runtimeSpec.Egress = append(runtimeSpec.Egress, ray...)
			}
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
		r.reconcilePolicyWithGuard(ctx, ai, schemaPolicySuffix, schemaSpec),
		r.reconcilePolicyWithGuard(ctx, ai, runtimePolicySuffix, runtimeSpec),
		r.reconcileLegacySchemaPolicy(ctx, ai, schemaSpec),
	)
	if applyErr != nil {
		return applyErr
	}
	return configErr
}

func (r *AgentRuntimeReconciler) resolveNetworkPolicy(ctx context.Context, ai *aiv1.AIService) (*aiv1.AgentRuntimeNetworkPolicy, *aiv1.AgentRuntimeNetworkPeer, error) {
	config := ai.Spec.Feature.NetworkPolicy
	owner := metav1.GetControllerOf(ai)
	managed := owner != nil && owner.APIVersion == aiv1.GroupVersion.String() && owner.Kind == "AIPlatform" &&
		ai.Name == FeatureAIServiceName(owner.Name, ai.Spec.Feature.Provider)
	var platform *aiv1.AIPlatform
	if managed {
		platform = &aiv1.AIPlatform{}
		err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: owner.Name}, platform)
		if err != nil && !apierrors.IsNotFound(err) {
			return nil, nil, fmt.Errorf("read the owning AIPlatform: %w", err)
		}
		if err != nil || platform.UID != owner.UID {
			return nil, nil, schemaState("InvalidNetworkPolicy", "cannot resolve the owning AIPlatform for the AgentRuntime network policy")
		}
		// The staged allowlist on the parent takes effect before the generated
		// AIService is refreshed. Its old copy may grant access since removed.
		config = nil
		for _, feature := range platform.Spec.Features {
			if feature.Name == ai.Spec.Feature.Name && feature.Provider == ai.Spec.Feature.Provider {
				config = feature.NetworkPolicy
				break
			}
		}
	}
	path := field.NewPath("spec", "features", "networkPolicy")
	errs := append(config.Validate(path, !managed), config.ValidateMetrics(path, ai.Spec.Metrics.Enabled || managed)...)
	if len(errs) != 0 {
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

func (r *AgentRuntimeReconciler) reconcileLegacySchemaPolicy(ctx context.Context, ai *aiv1.AIService, spec networkingv1.NetworkPolicySpec) error {
	var jobs batchv1.JobList
	if err := r.List(ctx, &jobs, client.InNamespace(ai.Namespace)); err != nil {
		return fmt.Errorf("read schema Jobs for policy migration: %w", err)
	}
	var legacyUIDs []string
	var incompatibleJob bool
	for i := range jobs.Items {
		job := &jobs.Items[i]
		if !metav1.IsControlledBy(job, ai) || job.Annotations[schemaJobManagedAnnotation] != schemaJobManagedValue {
			continue
		}
		if job.Status.Active == 0 && (schemaJobSucceeded(job) || schemaJobFailed(job)) {
			continue
		}
		labels := job.Spec.Template.Labels
		if labels["app"] == spec.PodSelector.MatchLabels["app"] && labels["component"] == schemaComponent {
			continue
		}
		uid := string(job.UID)
		if uid == "" || job.Spec.Selector == nil || job.Spec.Selector.MatchLabels[batchv1.ControllerUidLabel] != uid || labels[batchv1.ControllerUidLabel] != uid {
			incompatibleJob = true
			continue
		}
		legacyUIDs = append(legacyUIDs, uid)
	}
	if len(legacyUIDs) == 0 && !incompatibleJob {
		return errors.Join(
			r.deleteOwnedObject(ctx, ai, &networkingv1.NetworkPolicy{}, dnsLabelName(ai.Name, legacySchemaPolicySuffix)),
			r.deleteOwnedObject(ctx, ai, &networkingv1.NetworkPolicy{}, policyGuardName(ai, legacySchemaPolicySuffix)),
		)
	}
	var err error
	if len(legacyUIDs) > 0 {
		// Job UIDs select only the verified migrations, including their retry pods.
		// A customer app label may be shared by unrelated workloads.
		slices.Sort(legacyUIDs)
		spec.PodSelector = metav1.LabelSelector{MatchExpressions: []metav1.LabelSelectorRequirement{{
			Key: batchv1.ControllerUidLabel, Operator: metav1.LabelSelectorOpIn, Values: legacyUIDs,
		}}}
		err = r.reconcilePolicyWithGuard(ctx, ai, legacySchemaPolicySuffix, spec)
	}
	if incompatibleJob {
		return errors.Join(err, schemaState("SchemaPolicyMigrationBlocked", "an active schema Job has no verified pod UID selector; wait for it to finish before completing the network policy upgrade"))
	}
	return err
}

func policyGuardName(ai *aiv1.AIService, suffix string) string {
	return dnsLabelName(ai.Name, suffix+"-guard-"+shortHash(string(ai.UID)))
}

func (r *AgentRuntimeReconciler) reconcilePolicyWithGuard(ctx context.Context, ai *aiv1.AIService, suffix string, spec networkingv1.NetworkPolicySpec) error {
	name := dnsLabelName(ai.Name, suffix)
	guardName := policyGuardName(ai, suffix)
	err := r.reconcileNetworkPolicy(ctx, ai, name, spec)
	if err == nil {
		return r.deleteOwnedObject(ctx, ai, &networkingv1.NetworkPolicy{}, guardName)
	}
	var conflict *common.OwnershipConflictError
	if !errors.As(err, &conflict) {
		return err
	}
	// Isolate existing pods even when a foreign object prevents creation of the
	// intended policy. Keep the conflict visible and leave the foreign object alone.
	spec.Ingress = nil
	spec.Egress = nil
	return errors.Join(err, r.reconcileNetworkPolicy(ctx, ai, guardName, spec))
}

func (r *AgentRuntimeReconciler) deleteOwnedObject(ctx context.Context, ai *aiv1.AIService, obj client.Object, name string) error {
	if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: name}, obj); err != nil {
		if apierrors.IsNotFound(err) || meta.IsNoMatchError(err) {
			return nil
		}
		return err
	}
	if !metav1.IsControlledBy(obj, ai) {
		return nil
	}
	uid, version := obj.GetUID(), obj.GetResourceVersion()
	return client.IgnoreNotFound(r.Delete(ctx, obj, client.Preconditions{UID: &uid, ResourceVersion: &version}))
}

func (r *AgentRuntimeReconciler) reconcileNetworkPolicy(ctx context.Context, ai *aiv1.AIService, name string, spec networkingv1.NetworkPolicySpec) error {
	policy := &networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{
		Name: name, Namespace: ai.Namespace,
	}}
	_, err := controllerutil.CreateOrPatch(ctx, r.Client, policy, func() error {
		if err := common.ClaimOrRefuse(ai, policy, r.Scheme); err != nil {
			return err
		}
		policy.Spec = spec
		return nil
	})
	if err != nil {
		return fmt.Errorf("reconcile network policy %s: %w", name, err)
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
