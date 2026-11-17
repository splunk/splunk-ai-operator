package v1

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func serviceForPlatform(vectorDbURL string) *aiv1.AIService {
	return &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{Name: "lp-slim", Namespace: "ns1"},
		Spec: aiv1.AIServiceSpec{
			Feature:       aiv1.FeatureSpec{Name: "slim"},
			AIPlatformRef: corev1.ObjectReference{Name: "lp", Namespace: "ns1"},
			VectorDbUrl:   vectorDbURL,
			TaskVolume:    aiv1.ObjectStorageSpec{Path: "s3://bucket", Region: "us-west-2"},
			Port:          8080,
			Replicas:      1,
		},
	}
}

func aiServiceValidator(t *testing.T, profile aiv1.AIPlatformProfile, withPlatform bool) *AIServiceCustomValidator {
	t.Helper()
	scheme := runtime.NewScheme()
	require.NoError(t, aiv1.AddToScheme(scheme))
	b := fake.NewClientBuilder().WithScheme(scheme)
	if withPlatform {
		b = b.WithObjects(&aiv1.AIPlatform{ObjectMeta: metav1.ObjectMeta{Name: "lp", Namespace: "ns1"}, Spec: aiv1.AIPlatformSpec{Profile: profile}})
	}
	return &AIServiceCustomValidator{Client: b.Build()}
}

// cpuOnly runs no vector database, so its services have no vectorDbUrl to give.
func TestAIServiceWebhook_VectorDbURLIsOptionalOnlyForCPUOnlyPlatforms(t *testing.T) {
	_, err := aiServiceValidator(t, aiv1.AIPlatformProfileCPUOnly, true).ValidateCreate(context.Background(), serviceForPlatform(""))
	assert.NoError(t, err, "a cpuOnly platform's service needs no vectorDbUrl")

	for _, profile := range []aiv1.AIPlatformProfile{"", "full", "fullfeature"} {
		_, err := aiServiceValidator(t, profile, true).ValidateCreate(context.Background(), serviceForPlatform(""))
		require.Error(t, err, "profile %q keeps the existing requirement", profile)
		assert.Contains(t, err.Error(), "spec.vectorDbUrl")
	}

	// When the platform cannot be found, or there is no client, the strict rule stays.
	_, err = aiServiceValidator(t, aiv1.AIPlatformProfileCPUOnly, false).ValidateCreate(context.Background(), serviceForPlatform(""))
	require.Error(t, err)
	_, err = (&AIServiceCustomValidator{}).ValidateCreate(context.Background(), serviceForPlatform(""))
	require.Error(t, err)

	// A value is still accepted for every profile.
	_, err = aiServiceValidator(t, aiv1.AIPlatformProfileFullFeature, true).ValidateCreate(context.Background(), serviceForPlatform("weaviate"))
	assert.NoError(t, err)
}
