package weaviateservice

import (
	"context"
	"os"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	splunkv1 "github.com/splunk/splunk-operator/api/v4"
	"github.com/stretchr/testify/assert"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func buildTestScheme(t *testing.T) *runtime.Scheme {
	s := runtime.NewScheme()
	err := aiv1.AddToScheme(s)
	assert.NoError(t, err)
	err = splunkv1.AddToScheme(s)
	assert.NoError(t, err)
	return s
}

func TestNormalizeWeaviateURL(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{
			name:     "full URL unchanged",
			input:    "http://weaviate-upstream.ai-platform.svc.cluster.local:8080",
			expected: "http://weaviate-upstream.ai-platform.svc.cluster.local:8080",
		},
		{
			name:     "host port gets http",
			input:    "weaviate-upstream:8080",
			expected: "http://weaviate-upstream:8080",
		},
		{
			name:     "service name expands to in-cluster DNS",
			input:    "splunk-ai-stack-weaviate",
			expected: "http://splunk-ai-stack-weaviate.ai-platform.svc.cluster.local:80",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			actual := normalizeWeaviateURL(tt.input, "ai-platform", "cluster.local")
			assert.Equal(t, tt.expected, actual)
		})
	}
}

func TestBuildEnv_AllowsOverrideFromSpecEnv(t *testing.T) {
	r := &WeaviateServiceReconciler{}
	ai := &aiv1.AIService{}
	ai.Namespace = "ai-platform"
	ai.Spec.VectorDbUrl = "splunk-ai-stack-weaviate"
	ai.Spec.Env = map[string]string{
		"SERVICE_NAME":   "custom_service_name",
		"SPLUNK_ISSUERS": "https://custom-splunk:8089",
	}

	env := r.buildEnv(ai)
	actual := map[string]string{}
	for _, e := range env {
		actual[e.Name] = e.Value
	}

	assert.Equal(t, "custom_service_name", actual["SERVICE_NAME"])
	assert.Equal(t, "WEAVIATE_SERVICE", actual["SERVICE_INTERNAL_NAME"])
	assert.Equal(t, "https://custom-splunk:8089", actual["SPLUNK_ISSUERS"])
	assert.Equal(t, "http://splunk-ai-stack-weaviate.ai-platform.svc.cluster.local:80", actual["WEAVIATE_URL"])
}

func TestBuildEnv_DefaultsSplunkIssuersFromSplunkConfigurationEndpoint(t *testing.T) {
	r := &WeaviateServiceReconciler{}
	ai := &aiv1.AIService{}
	ai.Namespace = "ai-platform"
	ai.Spec.VectorDbUrl = "splunk-ai-stack-weaviate"
	ai.Spec.SplunkConfiguration.Endpoint = "https://external-splunk.example.com:8089"

	env := r.buildEnv(ai)
	actual := map[string]string{}
	for _, e := range env {
		actual[e.Name] = e.Value
	}

	assert.Equal(t, "https://external-splunk.example.com:8089", actual["SPLUNK_ISSUERS"])
}

func TestValidateAIService_DefaultsVectorDbURLFromAIPlatformRef(t *testing.T) {
	os.Setenv("RELATED_IMAGE_WEAVIATE_SERVICE", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_WEAVIATE_SERVICE")

	scheme := buildTestScheme(t)
	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plat",
			Namespace: "ns",
		},
		Status: aiv1.AIPlatformStatus{
			VectorDbServiceName: "weaviate-upstream",
		},
	}

	r := &WeaviateServiceReconciler{
		Client: fake.NewClientBuilder().
			WithScheme(scheme).
			WithObjects(platform).
			Build(),
		Scheme: scheme,
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "weaviate-service",
			Namespace: "ns",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat"},
		},
	}

	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, "weaviate-upstream.ns.svc.cluster.local", ai.Spec.VectorDbUrl)
	assert.Equal(t, int32(1), ai.Spec.Replicas)
	assert.NotNil(t, ai.Spec.Resources.Requests)
	assert.NotNil(t, ai.Spec.Resources.Limits)
}

func TestValidateAIService_ExplicitVectorDbURLWins(t *testing.T) {
	os.Setenv("RELATED_IMAGE_WEAVIATE_SERVICE", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_WEAVIATE_SERVICE")

	scheme := buildTestScheme(t)
	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plat",
			Namespace: "ns",
		},
		Status: aiv1.AIPlatformStatus{
			VectorDbServiceName: "weaviate-upstream",
		},
	}

	r := &WeaviateServiceReconciler{
		Client: fake.NewClientBuilder().
			WithScheme(scheme).
			WithObjects(platform).
			Build(),
		Scheme: scheme,
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "weaviate-service",
			Namespace: "ns",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat"},
			VectorDbUrl:   "custom-vector-db.ns.svc.cluster.local",
		},
	}

	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, "custom-vector-db.ns.svc.cluster.local", ai.Spec.VectorDbUrl)
}

func TestValidateAIService_FailsWhenVectorDbServiceNameMissing(t *testing.T) {
	os.Setenv("RELATED_IMAGE_WEAVIATE_SERVICE", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_WEAVIATE_SERVICE")

	scheme := buildTestScheme(t)
	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plat",
			Namespace: "ns",
		},
	}

	r := &WeaviateServiceReconciler{
		Client: fake.NewClientBuilder().
			WithScheme(scheme).
			WithObjects(platform).
			Build(),
		Scheme: scheme,
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "weaviate-service",
			Namespace: "ns",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat"},
		},
	}

	err := r.validateAIService(context.Background(), ai)
	assert.ErrorContains(t, err, "VectorDbServiceName not populated in AIPlatform status")
}

func TestValidateAIService_ResolvesSplunkEndpointFromCustomResourceRef(t *testing.T) {
	os.Setenv("RELATED_IMAGE_WEAVIATE_SERVICE", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_WEAVIATE_SERVICE")

	scheme := buildTestScheme(t)
	standalone := &splunkv1.Standalone{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "example",
			Namespace: "ns",
		},
	}

	r := &WeaviateServiceReconciler{
		Client: fake.NewClientBuilder().
			WithScheme(scheme).
			WithObjects(standalone).
			Build(),
		Scheme: scheme,
	}

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "weaviate-service",
			Namespace: "ns",
		},
		Spec: aiv1.AIServiceSpec{
			VectorDbUrl: "custom-vector-db.ns.svc.cluster.local",
			SplunkConfiguration: aiv1.SplunkConfigurationSpec{
				SplunkCustomResourceRef: corev1.ObjectReference{
					Kind: "Standalone",
					Name: "example",
				},
			},
		},
	}

	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, "https://splunk-example-standalone-service.ns.svc.cluster.local:8089", ai.Spec.SplunkConfiguration.Endpoint)
}
