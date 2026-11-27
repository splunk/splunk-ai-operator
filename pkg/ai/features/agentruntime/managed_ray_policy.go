package agentruntime

import (
	"context"
	"fmt"
	"net/url"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	rayoutils "github.com/ray-project/kuberay/ray-operator/controllers/ray/utils"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const rayModelPort int32 = 8000

func (r *AgentRuntimeReconciler) managedRayNetworkRules(ctx context.Context, ai *aiv1.AIService) ([]networkingv1.NetworkPolicyEgressRule, error) {
	ref := ai.Spec.AIPlatformRef
	if ref.Name == "" {
		return nil, schemaState("InvalidNetworkPolicy", "managedRay requires a fullfeature AIPlatform reference")
	}
	if ref.Namespace == "" {
		ref.Namespace = ai.Namespace
	}
	platform, err := r.getAIPlatform(ctx, ref)
	if err != nil {
		return nil, rayDependencyError(err, "referenced AIPlatform")
	}
	if platform.Spec.ResolvedProfile() != aiv1.AIPlatformProfileFullFeature {
		return nil, schemaState("InvalidNetworkPolicy", "managedRay requires a fullfeature AIPlatform reference")
	}
	headName, err := rayoutils.GenerateHeadServiceName(rayoutils.RayServiceCRD, rayv1.RayClusterSpec{}, platform.Name)
	if err != nil {
		return nil, schemaState("InvalidNetworkPolicy", "cannot resolve the RayService head Service name")
	}
	if platform.Status.RayServiceName != headName {
		return nil, schemaState("ManagedRayPolicyPending", "waiting for the AIPlatform to publish its RayService head Service")
	}
	if ai.Spec.AIPlatformUrl != "" {
		domain := ai.Spec.ClusterDomain
		if domain == "" {
			domain = "cluster.local"
		}
		origin, err := url.Parse(ai.Spec.AIPlatformUrl)
		expected := fmt.Sprintf("%s.%s.svc.%s", headName, ref.Namespace, domain)
		if err != nil || origin.Hostname() != expected || origin.Port() != "8000" {
			return nil, schemaState("InvalidNetworkPolicy", "managedRay requires aiPlatformUrl to use the referenced AIPlatform's head Service on port 8000")
		}
	}

	ray := &rayv1.RayService{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ref.Namespace, Name: ref.Name}, ray); err != nil {
		return nil, rayDependencyError(err, "AIPlatform RayService")
	}
	if !rayServiceBelongsToPlatform(ray, platform) {
		return nil, schemaState("InvalidNetworkPolicy", "managedRay requires a RayService owned by the referenced AIPlatform")
	}
	head := &corev1.Service{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ref.Namespace, Name: headName}, head); err != nil {
		return nil, rayDependencyError(err, "RayService head Service")
	}
	selector := head.Spec.Selector
	if !metav1.IsControlledBy(head, ray) || selector[rayoutils.RayClusterLabelKey] == "" || selector[rayoutils.RayNodeTypeLabelKey] != string(rayv1.HeadNode) {
		return nil, schemaState("InvalidNetworkPolicy", "managedRay requires a RayService-owned head Service with a scoped head selector")
	}
	if !hasRayModelPort(head) {
		return nil, schemaState("InvalidNetworkPolicy", "managedRay requires the head Service to forward TCP 8000 to the head pod on TCP 8000")
	}

	rules := []networkingv1.NetworkPolicyEgressRule{rayHeadEgress(ref.Namespace, selector)}
	pending := ray.Status.PendingServiceStatus.RayClusterName
	if pending == "" || pending == selector[rayoutils.RayClusterLabelKey] {
		return rules, nil
	}
	cluster := &rayv1.RayCluster{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ref.Namespace, Name: pending}, cluster); err != nil {
		if apierrors.IsNotFound(err) {
			return rules, nil // RayService can publish the pending name before creating the cluster.
		}
		return nil, rayDependencyError(err, "pending RayCluster")
	}
	if !metav1.IsControlledBy(cluster, ray) {
		return rules, nil
	}
	// Stage the owned pending head before KubeRay switches the stable Service.
	return append(rules, rayHeadEgress(ref.Namespace, pendingRayHeadSelector(cluster.Name))), nil
}

// AIPlatform applies its RayService with a non-controller owner reference.
func rayServiceBelongsToPlatform(ray *rayv1.RayService, platform *aiv1.AIPlatform) bool {
	for _, owner := range ray.OwnerReferences {
		if owner.APIVersion == aiv1.GroupVersion.String() && owner.Kind == "AIPlatform" &&
			owner.Name == platform.Name && owner.UID == platform.UID {
			return true
		}
	}
	return false
}

// KubeRay builds the stable head Service selector from these RayCluster labels.
func pendingRayHeadSelector(clusterName string) map[string]string {
	return map[string]string{
		rayoutils.RayClusterLabelKey:                clusterName,
		rayoutils.RayNodeTypeLabelKey:               string(rayv1.HeadNode),
		rayoutils.RayIDLabelKey:                     rayoutils.CheckLabel(rayoutils.GenerateIdentifier(clusterName, rayv1.HeadNode)),
		rayoutils.KubernetesApplicationNameLabelKey: rayoutils.ApplicationName,
		rayoutils.KubernetesCreatedByLabelKey:       rayoutils.ComponentName,
	}
}

func hasRayModelPort(head *corev1.Service) bool {
	for _, port := range head.Spec.Ports {
		if port.Port == rayModelPort && (port.Protocol == corev1.ProtocolTCP || port.Protocol == "") &&
			(port.TargetPort.Type == intstr.Int && (port.TargetPort.IntVal == rayModelPort || port.TargetPort.IntVal == 0)) {
			return true
		}
	}
	return false
}

func rayHeadEgress(namespace string, selector map[string]string) networkingv1.NetworkPolicyEgressRule {
	return networkEgress(aiv1.AgentRuntimeNetworkDestination{
		Peer: aiv1.AgentRuntimeNetworkPeer{Namespace: namespace, PodSelector: selector}, Port: rayModelPort,
	})
}

func rayDependencyError(err error, resource string) error {
	if apierrors.IsNotFound(err) {
		return schemaState("ManagedRayPolicyPending", "waiting for the "+resource)
	}
	return fmt.Errorf("read %s for managedRay: %w", resource, err)
}
