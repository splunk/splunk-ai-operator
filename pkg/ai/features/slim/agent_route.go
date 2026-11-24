package slim

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	agentRouteAvailable = "AgentRouteAvailable"
	aitkSlimBasePath    = "/tenant/slim-api/v1alpha1"
)

type runtimeRoute struct {
	platform *aiv1.AIPlatform
	provider string
	managed  bool
}

// resolveRuntimeRoute uses the declared provider to derive one Service identity;
// current readiness is evaluated separately so SLIM can keep its startup URL.
func (r *SlimReconciler) resolveRuntimeRoute(ctx context.Context, ai *aiv1.AIService) (runtimeRoute, error) {
	if ai.Spec.AIPlatformRef.Name == "" {
		return runtimeRoute{}, nil
	}
	platform, err := r.getAIPlatform(ctx, ai.Spec.AIPlatformRef)
	if err != nil {
		return runtimeRoute{}, fmt.Errorf("cannot resolve the SLIM AgentRuntime dependency: %w", err)
	}
	profile := platform.Spec.Profile
	managed := (profile == aiv1.AIPlatformProfileCPUOnly || profile == aiv1.AIPlatformProfileFullFeature) &&
		metav1.IsControlledBy(ai, platform)
	route := runtimeRoute{platform: platform, managed: managed}
	found := false
	for _, feature := range platform.Spec.Features {
		if feature.Name != "agentruntime" {
			continue
		}
		if found {
			return route, errors.New("spec.features: multiple agentruntime features cannot resolve AI_TIER_AGENT_RUNTIME_URL")
		}
		found = true
		route.provider = feature.Provider
	}
	if !found {
		return runtimeRoute{}, nil
	}
	return route, nil
}

func (route runtimeRoute) origin() string {
	if route.platform == nil {
		return ""
	}
	return agentruntime.FeatureServiceURL(route.platform.Name, route.provider, route.platform.Namespace, route.platform.Spec.ClusterDomain)
}

func (r *SlimReconciler) reconcileAgentRouteStatus(ctx context.Context, ai *aiv1.AIService, route runtimeRoute) error {
	runtime := &aiv1.AIService{}
	key := client.ObjectKey{Namespace: route.platform.Namespace, Name: agentruntime.FeatureAIServiceName(route.platform.Name, route.provider)}
	if err := r.Get(ctx, key, runtime); err != nil {
		setAgentRouteCondition(ai, metav1.ConditionFalse, "RuntimeUnavailable", "Waiting for the selected AgentRuntime")
		return client.IgnoreNotFound(err)
	}
	if runtime.Spec.Feature.Name != "agentruntime" || runtime.Spec.Feature.Provider != route.provider ||
		!metav1.IsControlledBy(runtime, route.platform) || !common.IsCurrentServiceReady(runtime) {
		setAgentRouteCondition(ai, metav1.ConditionFalse, "RuntimeUnavailable", "Waiting for the owned AgentRuntime to be ready for its current generation")
		return nil
	}

	runtimeService := &corev1.Service{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: runtime.Namespace, Name: agentruntime.ServiceName(runtime.Name)}, runtimeService); err != nil {
		setAgentRouteCondition(ai, metav1.ConditionFalse, "RuntimeUnavailable", "Waiting for the selected AgentRuntime Service")
		return client.IgnoreNotFound(err)
	}
	if reason, message := agentruntime.ApplicationServiceProblem(runtimeService, runtime); reason != "" {
		setAgentRouteCondition(ai, metav1.ConditionFalse, reason, message)
		return nil
	}

	endpoint, err := r.aitkEndpoint(ctx, ai)
	if err != nil {
		setAgentRouteCondition(ai, metav1.ConditionFalse, "SLIMEndpointUnavailable", "Waiting for a valid owned SLIM application Service")
		return err
	}
	if ai.Status.FeatureStatus == nil {
		ai.Status.FeatureStatus = &aiv1.AIServiceFeatureStatus{}
	}
	ai.Status.FeatureStatus.Slim = &aiv1.SlimRouteStatus{AITKEndpoint: endpoint}
	setAgentRouteCondition(ai, metav1.ConditionTrue, "EndpointAvailable", "SLIM endpoint is published for a ready AgentRuntime")
	return nil
}

func setAgentRouteCondition(ai *aiv1.AIService, status metav1.ConditionStatus, reason, message string) {
	meta.SetStatusCondition(&ai.Status.Conditions, metav1.Condition{
		Type: agentRouteAvailable, Status: status, Reason: reason, Message: message, ObservedGeneration: ai.Generation,
	})
}

func validateAITKOrigin(ai *aiv1.AIService) error {
	origin := ai.Spec.SplunkConfiguration.AITKSlimOrigin
	if origin == "" {
		if ai.Spec.MTLS.Enabled {
			return errors.New("spec.splunkConfiguration.aitkSlimOrigin must identify the HTTPS gateway when SLIM TLS is enabled")
		}
		return nil
	}
	origin = strings.TrimSuffix(origin, "/")
	parsed, err := url.Parse(origin)
	if err != nil || !strings.HasPrefix(origin, "https://") || !validIssuerAddress(origin, true) ||
		parsed.Path != "" || parsed.RawPath != "" {
		return errors.New("spec.splunkConfiguration.aitkSlimOrigin must be an HTTPS origin without a path, credentials, query, or fragment")
	}
	return nil
}

func (r *SlimReconciler) aitkEndpoint(ctx context.Context, ai *aiv1.AIService) (string, error) {
	svc := &corev1.Service{}
	if err := r.Get(ctx, client.ObjectKey{Namespace: ai.Namespace, Name: slimServiceName(ai.Name)}, svc); err != nil {
		if apierrors.IsNotFound(err) {
			return "", errors.New("waiting for the SLIM application Service")
		}
		return "", errors.New("cannot read the SLIM application Service")
	}
	if !metav1.IsControlledBy(svc, ai) || svc.DeletionTimestamp != nil || svc.Spec.ClusterIP == "" ||
		svc.Spec.ClusterIP == corev1.ClusterIPNone || svc.Spec.PublishNotReadyAddresses ||
		len(svc.Spec.Selector) != 2 || svc.Spec.Selector["app"] != ai.Name || svc.Spec.Selector["component"] != ai.Name {
		return "", errors.New("SLIM application Service must select the intended SLIM workload")
	}
	for _, port := range svc.Spec.Ports {
		if port.Name != "http" || port.Port != 8080 || port.TargetPort != intstr.FromInt32(8080) ||
			(port.Protocol != "" && port.Protocol != corev1.ProtocolTCP) {
			continue
		}
		if origin := ai.Spec.SplunkConfiguration.AITKSlimOrigin; origin != "" {
			return strings.TrimSuffix(origin, "/") + aitkSlimBasePath, nil
		}
		domain := ai.Spec.ClusterDomain
		if domain == "" {
			domain = "cluster.local"
		}
		return fmt.Sprintf("http://%s.%s.svc.%s:%d%s", svc.Name, svc.Namespace, domain, port.Port, aitkSlimBasePath), nil
	}
	return "", errors.New("SLIM application Service must expose the candidate HTTP port")
}

func slimServiceName(aiServiceName string) string {
	return aiServiceName + "-slim-service"
}
