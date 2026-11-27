package upgrade

import (
	"context"
	"fmt"
	"strings"
	"testing"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	rayoutils "github.com/ray-project/kuberay/ray-operator/controllers/ray/utils"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/agentruntime"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	policyv1 "k8s.io/api/policy/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestUpgradePreflight(t *testing.T) {
	tests := []struct {
		name   string
		change func(*aiv1.AIPlatform, *aiv1.AIService, []*apiextensionsv1.CustomResourceDefinition) []client.Object
		error  string
	}{
		{name: "accepts a staged parent with a legacy child"},
		{
			name: "requires both staged CRDs",
			change: func(_ *aiv1.AIPlatform, _ *aiv1.AIService, crds []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				crds[1].Spec.Versions[0].Schema = nil
				return nil
			},
			error: "stage the updated AIPlatform and AIService CRDs",
		},
		{
			name: "requires the saved parent allowlist",
			change: func(platform *aiv1.AIPlatform, _ *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				platform.Spec.Features[0].NetworkPolicy = nil
				return nil
			},
			error: "save the AgentRuntime allowlist before upgrading the operator",
		},
		{
			name: "follows the staged parent when a child has a stale allowlist",
			change: func(_ *aiv1.AIPlatform, service *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				service.Spec.Feature.NetworkPolicy = &aiv1.AgentRuntimeNetworkPolicy{
					RuntimeEgress: []aiv1.AgentRuntimeNetworkDestination{{Peer: aiv1.AgentRuntimeNetworkPeer{CIDR: "0.0.0.0/0"}, Port: 443}},
				}
				return nil
			},
		},
		{
			name: "requires an explicit metrics decision for managed runtimes",
			change: func(platform *aiv1.AIPlatform, _ *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				platform.Spec.Features[0].NetworkPolicy.MetricsDisabled = false
				return nil
			},
			error: "must select an approved scraper or set metricsDisabled to true",
		},
		{
			name: "requires the fullfeature profile for managed Ray",
			change: func(platform *aiv1.AIPlatform, _ *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				platform.Spec.Profile = aiv1.AIPlatformProfileCPUOnly
				platform.Spec.Features[0].NetworkPolicy.ManagedRay = true
				return nil
			},
			error: "requires a fullfeature AIPlatform",
		},
		{
			name: "blocks a child with a stale owner UID",
			change: func(_ *aiv1.AIPlatform, service *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				service.OwnerReferences[0].UID = "previous-platform"
				return nil
			},
			error: "conflicts with the AgentRuntime managed by AIPlatform",
		},
		{
			name: "blocks a non-runtime reserved child",
			change: func(_ *aiv1.AIPlatform, service *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				service.Spec.Feature.Name = "slim"
				return nil
			},
			error: "conflicts with the AgentRuntime managed by AIPlatform",
		},
		{
			name: "blocks a reserved policy before the child exists",
			change: func(_ *aiv1.AIPlatform, service *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				reserved, _, _ := agentruntime.ManagedResourceNames(service.Name)
				service.Name = "other-runtime"
				service.Spec.Feature.Name = "slim"
				return []client.Object{&networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{Namespace: service.Namespace, Name: reserved}}}
			},
			error: "is not controlled by AIService",
		},
		{
			name: "blocks a customer PDB with the exact reserved long name",
			change: func(_ *aiv1.AIPlatform, service *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				_, _, budget := agentruntime.ManagedResourceNames(service.Name)
				requireOwner := *metav1.NewControllerRef(service, aiv1.GroupVersion.WithKind("AIService"))
				requireOwner.UID = "previous-runtime"
				return []client.Object{&policyv1.PodDisruptionBudget{ObjectMeta: metav1.ObjectMeta{
					Namespace: service.Namespace, Name: budget, OwnerReferences: []metav1.OwnerReference{requireOwner},
				}}}
			},
			error: "PodDisruptionBudget",
		},
		{
			name: "accepts a retry with an already owned schema policy",
			change: func(_ *aiv1.AIPlatform, service *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				_, schema, _ := agentruntime.ManagedResourceNames(service.Name)
				return []client.Object{&networkingv1.NetworkPolicy{ObjectMeta: metav1.ObjectMeta{
					Namespace: service.Namespace, Name: schema,
					OwnerReferences: []metav1.OwnerReference{*metav1.NewControllerRef(service, aiv1.GroupVersion.WithKind("AIService"))},
				}}}
			},
		},
		{
			name: "requires a standalone runtime to declare a caller",
			change: func(platform *aiv1.AIPlatform, service *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				service.OwnerReferences = nil
				service.Spec.Feature.NetworkPolicy = platform.Spec.Features[0].NetworkPolicy
				platform.Spec.Features = nil
				return nil
			},
			error: "must select the SLIM caller for a standalone AgentRuntime",
		},
		{
			name: "accepts a standalone runtime without metrics enabled",
			change: func(platform *aiv1.AIPlatform, service *aiv1.AIService, _ []*apiextensionsv1.CustomResourceDefinition) []client.Object {
				policy := platform.Spec.Features[0].NetworkPolicy
				policy.SLIM = &aiv1.AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "slim"}}
				policy.MetricsDisabled = false
				service.OwnerReferences = nil
				service.Spec.Feature.NetworkPolicy = policy
				platform.Spec.Features = nil
				return nil
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			platform, service := savedRuntime()
			crds := []*apiextensionsv1.CustomResourceDefinition{stagedCRD(platformCRDName, true), stagedCRD(serviceCRDName, false)}
			objects := []client.Object{platform, service, crds[0], crds[1]}
			if tt.change != nil {
				objects = append(objects, tt.change(platform, service, crds)...)
			}
			err := check(context.Background(), upgradeTestClient(t, objects...))
			if tt.error == "" {
				require.NoError(t, err)
			} else {
				require.ErrorContains(t, err, tt.error)
			}
		})
	}
}

func TestUpgradePreflightRejectsNonmatchingControllerReferences(t *testing.T) {
	for _, field := range []string{"apiVersion", "kind", "name"} {
		t.Run(field, func(t *testing.T) {
			platform, service := savedRuntime()
			switch field {
			case "apiVersion":
				service.OwnerReferences[0].APIVersion = "ai.splunk.com/v2"
			case "kind":
				service.OwnerReferences[0].Kind = "AIScheduler"
			case "name":
				service.OwnerReferences[0].Name = "other"
			}
			reader := upgradeTestClient(t, platform, service, stagedCRD(platformCRDName, true), stagedCRD(serviceCRDName, false))
			require.ErrorContains(t, check(context.Background(), reader), "conflicts with the AgentRuntime managed by AIPlatform")
		})
	}
}

func TestUpgradePreflightStandaloneManagedRayURL(t *testing.T) {
	platform, service := savedRuntime()
	platform.Spec.Profile = aiv1.AIPlatformProfileFullFeature
	service.OwnerReferences = nil
	service.Spec.Feature.NetworkPolicy = platform.Spec.Features[0].NetworkPolicy
	platform.Spec.Features = nil
	service.Spec.Feature.NetworkPolicy.ManagedRay = true
	service.Spec.Feature.NetworkPolicy.SLIM = &aiv1.AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "slim"}}
	service.Spec.ClusterDomain = "fixture.local"
	headName, err := rayoutils.GenerateHeadServiceName(rayoutils.RayServiceCRD, rayv1.RayClusterSpec{}, platform.Name)
	require.NoError(t, err)
	origin := fmt.Sprintf("https://%s.%s.svc.%s", headName, platform.Namespace, service.Spec.ClusterDomain)
	for _, test := range []struct {
		name string
		url  string
		pass bool
	}{
		{name: "uses the referenced stable head and configured domain", url: origin + ":8000", pass: true},
		{name: "permits an omitted explicit origin", pass: true},
		{name: "rejects another port", url: origin + ":443"},
		{name: "rejects another host", url: "https://unapproved.example:8000"},
		{name: "redacts an invalid URL", url: "https://fixture-secret%zz"},
	} {
		t.Run(test.name, func(t *testing.T) {
			input := service.DeepCopy()
			input.Spec.AIPlatformUrl = test.url
			reader := upgradeTestClient(t, platform, input, stagedCRD(platformCRDName, true), stagedCRD(serviceCRDName, false))
			err := check(context.Background(), reader)
			if test.pass {
				require.NoError(t, err)
			} else {
				require.ErrorContains(t, err, "requires spec.aiPlatformUrl to use the referenced AIPlatform's head Service on port 8000")
				require.NotContains(t, err.Error(), "fixture-secret")
			}
		})
	}
}

func TestUpgradePreflightAllowsClusterWithoutAgentRuntime(t *testing.T) {
	require.NoError(t, check(context.Background(), upgradeTestClient(t)))
}

func upgradeTestClient(t *testing.T, objects ...client.Object) client.Client {
	t.Helper()
	scheme := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(scheme))
	require.NoError(t, apiextensionsv1.AddToScheme(scheme))
	require.NoError(t, networkingv1.AddToScheme(scheme))
	require.NoError(t, policyv1.AddToScheme(scheme))
	return fake.NewClientBuilder().WithScheme(scheme).WithObjects(objects...).Build()
}

func savedRuntime() (*aiv1.AIPlatform, *aiv1.AIService) {
	platform := &aiv1.AIPlatform{ObjectMeta: metav1.ObjectMeta{Namespace: "ai", Name: strings.Repeat("a", 55), UID: "current-platform"}}
	platform.Spec.Features = []aiv1.FeatureSpec{{
		Name:     "agentruntime",
		Provider: "a-provider",
		NetworkPolicy: &aiv1.AgentRuntimeNetworkPolicy{
			DNS:             aiv1.AgentRuntimeNetworkPeer{Namespace: "kube-system", PodSelector: map[string]string{"app": "dns"}},
			PostgreSQL:      aiv1.AgentRuntimeNetworkDestination{Peer: aiv1.AgentRuntimeNetworkPeer{CIDR: "10.0.1.0/24"}, Port: 5432},
			MetricsDisabled: true,
		},
	}}
	service := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: platform.Namespace, Name: agentruntime.FeatureAIServiceName(platform.Name, "a-provider"), UID: "current-runtime",
			OwnerReferences: []metav1.OwnerReference{*metav1.NewControllerRef(platform, aiv1.GroupVersion.WithKind("AIPlatform"))},
		},
		Spec: aiv1.AIServiceSpec{
			Feature:       aiv1.FeatureSpec{Name: "agentruntime", Provider: "a-provider"},
			AIPlatformRef: corev1.ObjectReference{Name: platform.Name, Namespace: platform.Namespace},
		},
	}
	return platform, service
}

func stagedCRD(name string, platform bool) *apiextensionsv1.CustomResourceDefinition {
	feature := apiextensionsv1.JSONSchemaProps{Properties: map[string]apiextensionsv1.JSONSchemaProps{
		"networkPolicy": {Type: "object", Properties: map[string]apiextensionsv1.JSONSchemaProps{
			"dns": {Type: "object"}, "postgresql": {Type: "object"}, "slim": {Type: "object"}, "metrics": {Type: "object"},
			"runtimeEgress": {Type: "array"}, "metricsDisabled": {Type: "boolean"}, "managedRay": {Type: "boolean"},
		}},
	}}
	if platform {
		item := feature
		feature = apiextensionsv1.JSONSchemaProps{Items: &apiextensionsv1.JSONSchemaPropsOrArray{Schema: &item}}
	}
	return &apiextensionsv1.CustomResourceDefinition{
		ObjectMeta: metav1.ObjectMeta{Name: name},
		Spec: apiextensionsv1.CustomResourceDefinitionSpec{Versions: []apiextensionsv1.CustomResourceDefinitionVersion{{
			Name: aiv1.GroupVersion.Version, Served: true, Schema: &apiextensionsv1.CustomResourceValidation{
				OpenAPIV3Schema: &apiextensionsv1.JSONSchemaProps{Properties: map[string]apiextensionsv1.JSONSchemaProps{
					"spec": {Properties: map[string]apiextensionsv1.JSONSchemaProps{"features": feature}},
				}},
			},
		}}},
	}
}
