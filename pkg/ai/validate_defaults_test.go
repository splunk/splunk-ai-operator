package ai_platform

import (
	"context"
	"os"
	"testing"

	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	splunkutils "github.com/splunk/splunk-ai-operator/pkg/splunkutils"
)

//
// --- Utility: Fake Client + Patch Mechanism ---
//

// Save original for restoration after test
var originalValidateAndEnrichSplunkConfig = splunkutils.ValidateAndEnrichSplunkConfig

// Helper to temporarily replace ValidateAndEnrichSplunkConfig in tests
func patchValidateAndEnrich(f func(
	ctx context.Context,
	c client.Client,
	namespace, clusterDomain string,
	config *aiApi.SplunkConfigurationSpec,
	resolver splunkutils.SplunkSecretResolver,
) error) {
	splunkutils.ValidateAndEnrichSplunkConfig = f
}

// Restore original ValidateAndEnrichSplunkConfig after test
func restoreValidateAndEnrich() {
	splunkutils.ValidateAndEnrichSplunkConfig = originalValidateAndEnrichSplunkConfig
}

// Create a reconciler with a controller-runtime fake client
func newFakeReconciler() *AIPlatformReconciler {
	fakeClient := fake.NewClientBuilder().Build()
	return &AIPlatformReconciler{Client: fakeClient}
}

//
// --- Tests for validate() ---
//

// 1️⃣ Test required field validation
func TestValidate_ObjectStoragePathRequiredForStorageBackedFeatures(t *testing.T) {
	r := newFakeReconciler()
	p := &aiApi.AIPlatform{
		Spec: aiApi.AIPlatformSpec{
			Features: []aiApi.FeatureSpec{
				{Name: "saia"},
			},
			ObjectStorage:       &aiApi.ObjectStorageSpec{Path: ""}, // missing path
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{},
		},
	}

	err := r.validate(context.Background(), p)

	assert.Error(t, err, "expected error when ObjectStorage.Path is missing")
	assert.Contains(t, err.Error(), "object storage is required")
}

func TestValidate_AllowsWeaviateServiceWithoutObjectStorage(t *testing.T) {
	r := newFakeReconciler()
	p := &aiApi.AIPlatform{
		Spec: aiApi.AIPlatformSpec{
			Features: []aiApi.FeatureSpec{
				{Name: "weaviate-service"},
			},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{},
		},
	}

	patchValidateAndEnrich(func(
		ctx context.Context,
		c client.Client,
		namespace, clusterDomain string,
		config *aiApi.SplunkConfigurationSpec,
		resolver splunkutils.SplunkSecretResolver,
	) error {
		return nil
	})
	defer restoreValidateAndEnrich()

	err := r.validate(context.Background(), p)
	assert.NoError(t, err)
}

// 2️⃣ Test defaulting behavior for nil SchedulingSpecs
func TestValidate_DefaultsSchedulingSpecs(t *testing.T) {
	r := newFakeReconciler()
	p := &aiApi.AIPlatform{
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: &aiApi.ObjectStorageSpec{Path: "/data"},
			// CPUSchedulingSpec and GPUSchedulingSpec are nil → should be defaulted
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{},
		},
	}

	// Patch ValidateAndEnrichSplunkConfig → no-op (pretend success)
	patchValidateAndEnrich(func(
		ctx context.Context,
		c client.Client,
		namespace, clusterDomain string,
		config *aiApi.SplunkConfigurationSpec,
		resolver splunkutils.SplunkSecretResolver,
	) error {
		return nil
	})
	defer restoreValidateAndEnrich()

	err := r.validate(context.Background(), p)
	require.NoError(t, err)

	// ✅ Defaults should be backfilled
	require.NotNil(t, p.Spec.CPUSchedulingSpec, "CPUSchedulingSpec should be populated")
	require.NotNil(t, p.Spec.GPUSchedulingSpec, "GPUSchedulingSpec should be populated")

	assert.Empty(t, p.Spec.CPUSchedulingSpec.NodeSelector, "NodeSelector should be empty by default")
	assert.Empty(t, p.Spec.GPUSchedulingSpec.NodeSelector, "NodeSelector should be empty by default")

	assert.NotNil(t, p.Spec.CPUSchedulingSpec.Affinity, "Affinity should default to a non-nil struct")
	assert.NotNil(t, p.Spec.GPUSchedulingSpec.Affinity, "Affinity should default to a non-nil struct")
}

// 3️⃣ Table-driven test for resolver selection (Vault/K8s/Default)
func TestValidate_ResolverSelection(t *testing.T) {
	r := newFakeReconciler()

	tests := []struct {
		name         string
		secretSource aiApi.SecretSourceType
		expectVault  bool
		expectK8s    bool
	}{
		{"Vault resolver", aiApi.SecretSourceVault, true, false},
		{"Kubernetes resolver", aiApi.SecretSourceKubernetes, false, true},
		{"Default empty → Kubernetes resolver", "", false, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := &aiApi.AIPlatform{
				Spec: aiApi.AIPlatformSpec{
					ObjectStorage: &aiApi.ObjectStorageSpec{Path: "/data"},
					SplunkConfiguration: aiApi.SplunkConfigurationSpec{
						SecretSource: tt.secretSource,
					},
				},
			}

			patchValidateAndEnrich(func(
				ctx context.Context,
				c client.Client,
				namespace, clusterDomain string,
				config *aiApi.SplunkConfigurationSpec,
				resolver splunkutils.SplunkSecretResolver,
			) error {
				_, isVault := resolver.(*splunkutils.VaultFileResolver)
				_, isK8s := resolver.(*splunkutils.KubernetesSecretResolver)

				if tt.expectVault {
					assert.True(t, isVault, "expected Vault resolver for SecretSource=%s", tt.secretSource)
				}
				if tt.expectK8s {
					assert.True(t, isK8s, "expected Kubernetes resolver for SecretSource=%s", tt.secretSource)
				}
				return nil
			})
			defer restoreValidateAndEnrich()

			err := r.validate(context.Background(), p)
			assert.NoError(t, err)
		})
	}
}

// 4️⃣ Test error propagation from ValidateAndEnrichSplunkConfig
func TestValidate_PropagatesErrorFromValidateAndEnrich(t *testing.T) {
	r := newFakeReconciler()
	p := &aiApi.AIPlatform{
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage:       &aiApi.ObjectStorageSpec{Path: "/data"},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{},
		},
	}

	expectedErr := assert.AnError
	patchValidateAndEnrich(func(
		ctx context.Context,
		c client.Client,
		namespace, clusterDomain string,
		config *aiApi.SplunkConfigurationSpec,
		resolver splunkutils.SplunkSecretResolver,
	) error {
		return expectedErr
	})
	defer restoreValidateAndEnrich()

	err := r.validate(context.Background(), p)
	assert.Error(t, err)
	assert.Equal(t, expectedErr, err, "should propagate the error from ValidateAndEnrichSplunkConfig")
}

func TestValidate_RaylessIngressRejectsNonWeaviatePaths(t *testing.T) {
	r := newFakeReconciler()
	p := &aiApi.AIPlatform{
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: &aiApi.ObjectStorageSpec{Path: "/data"},
			Features: []aiApi.FeatureSpec{
				{Name: "weaviate-service"},
			},
			Ingress: &aiApi.IngressSpec{
				Enabled: true,
				Hosts: []aiApi.IngressHost{
					{
						Host: "ai.example.com",
						Paths: []aiApi.IngressPath{
							{Path: "/", PathType: "Prefix"},
						},
					},
				},
			},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{},
		},
	}

	err := r.validate(context.Background(), p)

	assert.Error(t, err)
	assert.Contains(t, err.Error(), "requires Ray")
}

func TestValidate_RaylessIngressAllowsWeaviatePath(t *testing.T) {
	r := newFakeReconciler()
	p := &aiApi.AIPlatform{
		Spec: aiApi.AIPlatformSpec{
			ObjectStorage: &aiApi.ObjectStorageSpec{Path: "/data"},
			Features: []aiApi.FeatureSpec{
				{Name: "weaviate-service"},
			},
			Ingress: &aiApi.IngressSpec{
				Enabled: true,
				Hosts: []aiApi.IngressHost{
					{
						Host: "ai.example.com",
						Paths: []aiApi.IngressPath{
							{Path: "/weaviate", PathType: "Prefix"},
						},
					},
				},
			},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{},
		},
	}

	patchValidateAndEnrich(func(
		ctx context.Context,
		c client.Client,
		namespace, clusterDomain string,
		config *aiApi.SplunkConfigurationSpec,
		resolver splunkutils.SplunkSecretResolver,
	) error {
		return nil
	})
	defer restoreValidateAndEnrich()

	err := r.validate(context.Background(), p)
	assert.NoError(t, err)
}

//
// --- Tests for SetImageRegistry() ---
//

func TestSetImageRegistry_ReturnsEnvValue(t *testing.T) {
	const key = "TEST_IMAGE_REGISTRY"
	const envVal = "my.registry.io"
	const defaultVal = "default.registry.io"

	// Set env var for this test
	require.NoError(t, os.Setenv(key, envVal))
	defer os.Unsetenv(key)

	val := SetImageRegistry(key, defaultVal)
	assert.Equal(t, envVal, val, "should return env var value if set")
}

func TestSetImageRegistry_ReturnsDefaultValue(t *testing.T) {
	const key = "TEST_IMAGE_REGISTRY"
	const defaultVal = "default.registry.io"

	// Ensure env var is unset
	os.Unsetenv(key)

	val := SetImageRegistry(key, defaultVal)
	assert.Equal(t, defaultVal, val, "should return default value if env var not set")
}
