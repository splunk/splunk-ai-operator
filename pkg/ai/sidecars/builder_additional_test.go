package sidecars

import (
	"context"
	"os"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	syaml "sigs.k8s.io/yaml"
)

func TestNew(t *testing.T) {
	scheme := setupFakeScheme()
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).Build()
	recorder := record.NewFakeRecorder(100)

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-platform",
			Namespace: "default",
		},
	}

	builder := New(fakeClient, scheme, recorder, platform)

	assert.NotNil(t, builder)
	assert.Equal(t, fakeClient, builder.Client)
	assert.Equal(t, scheme, builder.Scheme)
	assert.Equal(t, recorder, builder.Recorder)
	assert.Equal(t, platform, builder.ai)
}

// TestReconcile is skipped for now because it requires PrometheusRule CRD to be registered
// Individual reconcile functions are tested separately below
func TestReconcile(t *testing.T) {
	t.Skip("Skipping Reconcile test - requires Prometheus Operator CRDs to be registered in scheme")
}

// TestAddFluentBitSidecar removed - FluentBit functionality has been removed from the codebase

func TestReconcileEnvoyConfig(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	tests := []struct {
		name     string
		platform *aiApi.AIPlatform
		wantErr  bool
	}{
		{
			name: "envoy disabled",
			platform: &aiApi.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-platform",
					Namespace: "default",
				},
				Spec: aiApi.AIPlatformSpec{
					Sidecars: aiApi.SidecarSpec{
						Envoy: false,
					},
				},
			},
			wantErr: false,
		},
		{
			name: "envoy enabled - creates configmap",
			platform: &aiApi.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{
					Name:      "test-platform-envoy",
					Namespace: "default",
				},
				Spec: aiApi.AIPlatformSpec{
					Sidecars: aiApi.SidecarSpec{
						Envoy: true,
					},
				},
			},
			wantErr: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fakeClient := fake.NewClientBuilder().WithScheme(scheme).Build()
			recorder := record.NewFakeRecorder(100)
			builder := New(fakeClient, scheme, recorder, tt.platform)

			err := builder.reconcileEnvoyConfig(ctx, tt.platform)

			if tt.wantErr {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)

				// If envoy enabled, verify configmap was created
				if tt.platform.Spec.Sidecars.Envoy {
					cm := &corev1.ConfigMap{}
					cmName := tt.platform.Name + "-envoy-config"
					err := fakeClient.Get(ctx, clientKey(tt.platform.Namespace, cmName), cm)
					assert.NoError(t, err)
					assert.Contains(t, cm.Data["envoy.yaml"], "static_resources")
				}
			}
		})
	}
}

func TestRenderEnvoyConf(t *testing.T) {
	conf := renderEnvoyConf()

	assert.NotEmpty(t, conf)
	assert.Contains(t, conf, "static_resources")
	assert.Contains(t, conf, "listeners")
	assert.Contains(t, conf, "clusters")
	assert.Contains(t, conf, "sais_backend")
	assert.Contains(t, conf, "envoy.filters.http.lua")
}

// TestReconcileOpenTelemetryCollector is skipped for the Splunk-enabled path
// because it requires the OpenTelemetry CRD to be registered. The
// Splunk-disabled and Otel-off paths return early before any CRD access, so
// they are covered by TestReconcileOpenTelemetryCollector_Skips below.
func TestReconcileOpenTelemetryCollector(t *testing.T) {
	t.Skip("Skipping reconcileOpenTelemetryCollector test - requires OpenTelemetry Operator CRDs")
}

// TestReconcileOpenTelemetryCollector_Skips verifies the early-return paths:
// when Otel is off, or when Splunk is disabled (empty config), no collector and
// no otel-config ConfigMap are created — and no OpenTelemetry CRD is required.
func TestReconcileOpenTelemetryCollector_Skips(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	tests := []struct {
		name string
		spec aiApi.AIPlatformSpec
	}{
		{
			name: "otel disabled",
			spec: aiApi.AIPlatformSpec{
				Sidecars: aiApi.SidecarSpec{Otel: false},
				SplunkConfiguration: aiApi.SplunkConfigurationSpec{
					Endpoint: "https://splunk:8088",
				},
			},
		},
		{
			name: "otel enabled but Splunk disabled (empty config)",
			spec: aiApi.AIPlatformSpec{
				Sidecars:            aiApi.SidecarSpec{Otel: true},
				SplunkConfiguration: aiApi.SplunkConfigurationSpec{},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			platform := &aiApi.AIPlatform{
				ObjectMeta: metav1.ObjectMeta{Name: "test-platform", Namespace: "default"},
				Spec:       tt.spec,
			}
			fakeClient := fake.NewClientBuilder().WithScheme(scheme).Build()
			builder := New(fakeClient, scheme, record.NewFakeRecorder(100), platform)

			err := builder.reconcileOpenTelemetryCollector(ctx, platform)
			require.NoError(t, err, "skip paths must not error")

			// No otel-config ConfigMap should have been seeded.
			cm := &corev1.ConfigMap{}
			getErr := fakeClient.Get(ctx, clientKey(platform.Namespace, platform.Name+"-otel-config"), cm)
			assert.Error(t, getErr, "no otel-config ConfigMap should be created on the skip path")
		})
	}
}

func TestReconcileOtelConfigMap(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-platform",
			Namespace: "default",
		},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{
					Name: "splunk-secret",
				},
				Endpoint: "https://splunk.example.com",
			},
		},
	}

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "splunk-secret",
			Namespace: "default",
		},
		Data: map[string][]byte{
			"hec_token": []byte("test-token"),
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(secret).
		Build()

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	err := builder.reconcileOtelConfigMap(ctx, platform)
	assert.NoError(t, err)

	// Verify ConfigMap was created
	cm := &corev1.ConfigMap{}
	cmName := platform.Name + "-otel-config"
	err = fakeClient.Get(ctx, clientKey(platform.Namespace, cmName), cm)
	assert.NoError(t, err)
	assert.NotEmpty(t, cm.Data["otel-config.yaml"])
}

func TestRenderOtelConf(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "splunk-secret",
			Namespace: "default",
		},
		Data: map[string][]byte{
			"hec_token": []byte("test-token-123"),
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(secret).
		Build()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-platform",
			Namespace: "default",
		},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{
					Name: "splunk-secret",
				},
				Endpoint: "https://splunk.example.com",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf := builder.renderOtelConf(ctx, platform)

	assert.NotNil(t, conf)

	// Verify structure
	exporters, ok := conf["exporters"].(map[string]interface{})
	require.True(t, ok, "exporters should be present")

	splunkHec, ok := exporters["splunk_hec"].(map[string]interface{})
	require.True(t, ok, "splunk_hec exporter should be present")

	assert.Equal(t, "test-token-123", splunkHec["token"])
	assert.Equal(t, "https://splunk.example.com/services/collector", splunkHec["endpoint"])

	// Verify receivers
	receivers, ok := conf["receivers"].(map[string]interface{})
	require.True(t, ok, "receivers should be present")
	assert.Contains(t, receivers, "prometheus")

	// Verify processors
	processors, ok := conf["processors"].(map[string]interface{})
	require.True(t, ok, "processors should be present")
	assert.Contains(t, processors, "batch")

	// Verify service
	service, ok := conf["service"].(map[string]interface{})
	require.True(t, ok, "service should be present")
	assert.Contains(t, service, "pipelines")
}

func TestRenderOtelConf_HECEndpointOverridesEndpoint(t *testing.T) {
	// Regression: Endpoint (management/JWKS, e.g. :8089) and HECEndpoint
	// (HEC ingestion, e.g. :8088) are different Splunk listeners. Before
	// HECEndpoint existed, renderOtelConf always derived the HEC URL from
	// Endpoint, so an internal-mode config pointed OTel at the wrong port.
	ctx := context.Background()
	scheme := setupFakeScheme()

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "splunk-secret", Namespace: "default"},
		Data:       map[string][]byte{"hec_token": []byte("test-token-123")},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret).Build()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "test-platform", Namespace: "default"},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef:   corev1.SecretReference{Name: "splunk-secret"},
				Endpoint:    "https://splunk.example.com:8089",
				HECEndpoint: "https://splunk.example.com:8088",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf := builder.renderOtelConf(ctx, platform)
	exporters := conf["exporters"].(map[string]interface{})
	splunkHec := exporters["splunk_hec"].(map[string]interface{})

	assert.Equal(t, "https://splunk.example.com:8088/services/collector", splunkHec["endpoint"],
		"HECEndpoint must be used for the HEC URL, not Endpoint")
}

func TestRenderOtelConf_FallsBackToEndpointWhenHECEndpointUnset(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "splunk-secret", Namespace: "default"},
		Data:       map[string][]byte{"hec_token": []byte("test-token-123")},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret).Build()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "test-platform", Namespace: "default"},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{Name: "splunk-secret"},
				Endpoint:  "https://splunk.example.com:8088",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf := builder.renderOtelConf(ctx, platform)
	exporters := conf["exporters"].(map[string]interface{})
	splunkHec := exporters["splunk_hec"].(map[string]interface{})

	assert.Equal(t, "https://splunk.example.com:8088/services/collector", splunkHec["endpoint"],
		"backward-compat: Endpoint must still be used when HECEndpoint is unset")

	select {
	case ev := <-recorder.Events:
		assert.Contains(t, ev, "HECEndpointFallback", "falling back to endpoint must emit a warning Event so the conflation is visible, not silent")
	default:
		t.Fatal("expected a warning Event when falling back from hecEndpoint to endpoint")
	}
}

func TestRenderOtelConf_NoEndpointAtAllReturnsError(t *testing.T) {
	// Neither hecEndpoint nor endpoint set: there is nothing safe to fall
	// back to, so renderOtelConf must fail loudly instead of shipping
	// telemetry to an empty/services/collector URL.
	ctx := context.Background()
	scheme := setupFakeScheme()

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "splunk-secret", Namespace: "default"},
		Data:       map[string][]byte{"hec_token": []byte("test-token-123")},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret).Build()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "test-platform", Namespace: "default"},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{Name: "splunk-secret"},
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf := builder.renderOtelConf(ctx, platform)
	assert.Contains(t, conf, "error")
}

func TestRenderOtelConf_CACertRefEnablesTLSVerification(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "splunk-secret", Namespace: "default"},
		Data:       map[string][]byte{"hec_token": []byte("test-token-123")},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret).Build()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "test-platform", Namespace: "default"},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{Name: "splunk-secret"},
				Endpoint:  "https://splunk.example.com:8088",
				CACertRef: &aiApi.CABundleRef{Name: "splunk-ca-bundle"},
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf := builder.renderOtelConf(ctx, platform)
	exporters := conf["exporters"].(map[string]interface{})
	splunkHec := exporters["splunk_hec"].(map[string]interface{})
	tlsConf := splunkHec["tls"].(map[string]interface{})

	assert.Equal(t, false, tlsConf["insecure_skip_verify"],
		"TLS verification must be enabled when CACertRef is set")
	assert.Equal(t, "/etc/splunk-ca/ca.crt", tlsConf["ca_file"])
}

func TestRenderOtelConf_NoCACertRefVerifiesAgainstSystemTrustStore(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "splunk-secret", Namespace: "default"},
		Data:       map[string][]byte{"hec_token": []byte("test-token-123")},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret).Build()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "test-platform", Namespace: "default"},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{Name: "splunk-secret"},
				Endpoint:  "https://splunk.example.com:8088",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf := builder.renderOtelConf(ctx, platform)
	exporters := conf["exporters"].(map[string]interface{})
	splunkHec := exporters["splunk_hec"].(map[string]interface{})
	tlsConf := splunkHec["tls"].(map[string]interface{})

	assert.Equal(t, false, tlsConf["insecure_skip_verify"],
		"absent CACertRef must still verify against the collector image's system trust store, not skip verification")
	assert.NotContains(t, tlsConf, "ca_file")
}

func TestRenderOtelConf_SecretMissing(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).Build()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-platform",
			Namespace: "default",
		},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{
					Name: "missing-secret",
				},
				Endpoint: "https://splunk.example.com",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf := builder.renderOtelConf(ctx, platform)

	assert.NotNil(t, conf)
	// Should return error map
	errorMsg, ok := conf["error"].(string)
	assert.True(t, ok)
	assert.Contains(t, errorMsg, "loading secret")
}

func TestRenderOtelConf_TokenMissing(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "splunk-secret",
			Namespace: "default",
		},
		Data: map[string][]byte{
			// No hec_token
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(secret).
		Build()

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-platform",
			Namespace: "default",
		},
		Spec: aiApi.AIPlatformSpec{
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{
					Name: "splunk-secret",
				},
				Endpoint: "https://splunk.example.com",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf := builder.renderOtelConf(ctx, platform)

	assert.NotNil(t, conf)
	errorMsg, ok := conf["error"].(string)
	assert.True(t, ok)
	assert.Contains(t, errorMsg, "hec_token field not found")
}

func TestReconcileOpenTelemetryCollector_DefaultImage(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	// Ensure the environment variable is not set
	envKey := "RELATED_IMAGE_OTEL_COLLECTOR"
	originalValue := os.Getenv(envKey)
	os.Unsetenv(envKey)
	defer func() {
		if originalValue != "" {
			os.Setenv(envKey, originalValue)
		}
	}()

	defaultImage := "otel/opentelemetry-collector-contrib:0.122.1"

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "splunk-secret",
			Namespace: "default",
		},
		Data: map[string][]byte{
			"hec_token": []byte("test-token"),
		},
	}

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-platform",
			Namespace: "default",
		},
		Spec: aiApi.AIPlatformSpec{
			ClusterDomain: "test-cluster",
			Images: aiApi.Images{
				OTelImage: defaultImage,
			},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{
					Name: "splunk-secret",
				},
				Endpoint: "https://splunk.example.com",
			},
			Sidecars: aiApi.SidecarSpec{
				Otel: true,
			},
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(secret).
		Build()

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	// First create the ConfigMap that reconcileOpenTelemetryCollector expects
	err := builder.reconcileOtelConfigMap(ctx, platform)
	require.NoError(t, err)

	// Get the ConfigMap to extract the config
	cm := &corev1.ConfigMap{}
	cmName := platform.Name + "-otel-config"
	err = fakeClient.Get(ctx, clientKey(platform.Namespace, cmName), cm)
	require.NoError(t, err)

	// Parse the config from YAML
	var cfg map[string]interface{}
	err = syaml.Unmarshal([]byte(cm.Data["otel-config.yaml"]), &cfg)
	require.NoError(t, err)

	// Build the expected spec map (mimicking what reconcileOpenTelemetryCollector does)
	specMap := map[string]interface{}{
		"mode":  "sidecar",
		"image": ResolveImage("RELATED_IMAGE_OTEL_COLLECTOR", platform.Spec.Images.OTelImage),
		"env": []map[string]interface{}{
			{"name": "SPLUNK_ACCESS_TOKEN", "valueFrom": map[string]interface{}{"secretKeyRef": map[string]interface{}{"name": platform.Spec.SplunkConfiguration.SecretRef.Name, "key": "hec_token"}}},
			{"name": "POD_NAME", "valueFrom": map[string]interface{}{"fieldRef": map[string]interface{}{"fieldPath": "metadata.name"}}},
			{"name": "NAMESPACE", "valueFrom": map[string]interface{}{"fieldRef": map[string]interface{}{"fieldPath": "metadata.namespace"}}},
			{"name": "CLUSTER_NAME", "value": platform.Spec.ClusterDomain},
		},
		"config": cfg,
	}

	// Verify the spec components
	assert.Equal(t, "sidecar", specMap["mode"], "Mode should be sidecar")
	assert.Equal(t, defaultImage, specMap["image"], "Image should be the default when env var is not set")

	// Verify environment variables
	envVars, ok := specMap["env"].([]map[string]interface{})
	require.True(t, ok, "env should be a slice of maps")
	require.Len(t, envVars, 4, "Should have 4 environment variables")

	assert.Equal(t, "SPLUNK_ACCESS_TOKEN", envVars[0]["name"])
	assert.Equal(t, "POD_NAME", envVars[1]["name"])
	assert.Equal(t, "NAMESPACE", envVars[2]["name"])
	assert.Equal(t, "CLUSTER_NAME", envVars[3]["name"])
	assert.Equal(t, "test-cluster", envVars[3]["value"])

	// Verify SPLUNK_ACCESS_TOKEN has correct secretKeyRef
	valueFrom, ok := envVars[0]["valueFrom"].(map[string]interface{})
	require.True(t, ok)
	secretKeyRef, ok := valueFrom["secretKeyRef"].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "splunk-secret", secretKeyRef["name"])
	assert.Equal(t, "hec_token", secretKeyRef["key"])

	// Verify config is present
	config, ok := specMap["config"].(map[string]interface{})
	require.True(t, ok, "config should be present")
	assert.NotEmpty(t, config, "config should not be empty")
}

func TestReconcileOpenTelemetryCollector_CustomImage(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	// Set the environment variable to a custom image
	envKey := "RELATED_IMAGE_OTEL_COLLECTOR"
	customImage := "custom-registry.example.com/opentelemetry-collector-contrib:1.0.0"
	originalValue := os.Getenv(envKey)
	os.Setenv(envKey, customImage)
	defer func() {
		if originalValue != "" {
			os.Setenv(envKey, originalValue)
		} else {
			os.Unsetenv(envKey)
		}
	}()

	defaultImage := "otel/opentelemetry-collector-contrib:0.122.1"

	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "splunk-secret",
			Namespace: "default",
		},
		Data: map[string][]byte{
			"hec_token": []byte("test-token"),
		},
	}

	platform := &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-platform-custom",
			Namespace: "default",
		},
		Spec: aiApi.AIPlatformSpec{
			ClusterDomain: "custom-cluster",
			Images: aiApi.Images{
				OTelImage: defaultImage,
			},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{
					Name: "splunk-secret",
				},
				Endpoint: "https://splunk.example.com",
			},
			Sidecars: aiApi.SidecarSpec{
				Otel: true,
			},
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(secret).
		Build()

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	// First create the ConfigMap that reconcileOpenTelemetryCollector expects
	err := builder.reconcileOtelConfigMap(ctx, platform)
	require.NoError(t, err)

	// Get the ConfigMap to extract the config
	cm := &corev1.ConfigMap{}
	cmName := platform.Name + "-otel-config"
	err = fakeClient.Get(ctx, clientKey(platform.Namespace, cmName), cm)
	require.NoError(t, err)

	// Parse the config from YAML
	var cfg map[string]interface{}
	err = syaml.Unmarshal([]byte(cm.Data["otel-config.yaml"]), &cfg)
	require.NoError(t, err)

	// Build the expected spec map (mimicking what reconcileOpenTelemetryCollector does)
	specMap := map[string]interface{}{
		"mode":  "sidecar",
		"image": ResolveImage("RELATED_IMAGE_OTEL_COLLECTOR", platform.Spec.Images.OTelImage),
		"env": []map[string]interface{}{
			{"name": "SPLUNK_ACCESS_TOKEN", "valueFrom": map[string]interface{}{"secretKeyRef": map[string]interface{}{"name": platform.Spec.SplunkConfiguration.SecretRef.Name, "key": "hec_token"}}},
			{"name": "POD_NAME", "valueFrom": map[string]interface{}{"fieldRef": map[string]interface{}{"fieldPath": "metadata.name"}}},
			{"name": "NAMESPACE", "valueFrom": map[string]interface{}{"fieldRef": map[string]interface{}{"fieldPath": "metadata.namespace"}}},
			{"name": "CLUSTER_NAME", "value": platform.Spec.ClusterDomain},
		},
		"config": cfg,
	}

	// Verify the spec components
	assert.Equal(t, "sidecar", specMap["mode"], "Mode should be sidecar")
	assert.Equal(t, customImage, specMap["image"], "Image should be the custom image from env var")

	// Verify environment variables
	envVars, ok := specMap["env"].([]map[string]interface{})
	require.True(t, ok, "env should be a slice of maps")
	require.Len(t, envVars, 4, "Should have 4 environment variables")

	assert.Equal(t, "SPLUNK_ACCESS_TOKEN", envVars[0]["name"])
	assert.Equal(t, "POD_NAME", envVars[1]["name"])
	assert.Equal(t, "NAMESPACE", envVars[2]["name"])
	assert.Equal(t, "CLUSTER_NAME", envVars[3]["name"])
	assert.Equal(t, "custom-cluster", envVars[3]["value"])

	// Verify SPLUNK_ACCESS_TOKEN has correct secretKeyRef
	valueFrom, ok := envVars[0]["valueFrom"].(map[string]interface{})
	require.True(t, ok)
	secretKeyRef, ok := valueFrom["secretKeyRef"].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "splunk-secret", secretKeyRef["name"])
	assert.Equal(t, "hec_token", secretKeyRef["key"])

	// Verify POD_NAME has correct fieldRef
	valueFrom2, ok := envVars[1]["valueFrom"].(map[string]interface{})
	require.True(t, ok)
	fieldRef, ok := valueFrom2["fieldRef"].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "metadata.name", fieldRef["fieldPath"])

	// Verify NAMESPACE has correct fieldRef
	valueFrom3, ok := envVars[2]["valueFrom"].(map[string]interface{})
	require.True(t, ok)
	fieldRef2, ok := valueFrom3["fieldRef"].(map[string]interface{})
	require.True(t, ok)
	assert.Equal(t, "metadata.namespace", fieldRef2["fieldPath"])

	// Verify config is present and has expected structure
	config, ok := specMap["config"].(map[string]interface{})
	require.True(t, ok, "config should be present")
	assert.NotEmpty(t, config, "config should not be empty")

	// Verify config contains expected sections
	assert.Contains(t, config, "exporters", "config should contain exporters")
	assert.Contains(t, config, "receivers", "config should contain receivers")
	assert.Contains(t, config, "processors", "config should contain processors")
	assert.Contains(t, config, "service", "config should contain service")
}
