package sidecars

import (
	"context"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
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

// TestReconcileOpenTelemetryCollector is skipped because it requires OpenTelemetry CRD to be registered
func TestReconcileOpenTelemetryCollector(t *testing.T) {
	t.Skip("Skipping reconcileOpenTelemetryCollector test - requires OpenTelemetry Operator CRDs")
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

	conf, err := builder.renderOtelConf(ctx, platform)

	assert.NoError(t, err)
	assert.NotNil(t, conf)

	// Verify structure
	exporters, ok := conf["exporters"].(map[string]interface{})
	require.True(t, ok, "exporters should be present")

	splunkHec, ok := exporters["splunk_hec"].(map[string]interface{})
	require.True(t, ok, "splunk_hec exporter should be present")

	// Token should now be an environment variable reference, not the actual token
	assert.Equal(t, "${SPLUNK_ACCESS_TOKEN}", splunkHec["token"])
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

	conf, err := builder.renderOtelConf(ctx, platform)

	assert.Error(t, err)
	assert.Nil(t, conf)
	assert.Contains(t, err.Error(), "failed to validate secret")
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

	conf, err := builder.renderOtelConf(ctx, platform)

	assert.Error(t, err)
	assert.Nil(t, conf)
	assert.Contains(t, err.Error(), "hec_token")
}
