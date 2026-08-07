package sidecars

import (
	"context"
	"os"
	"strings"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
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
				Endpoint:    "https://splunk.example.com:8089",
				HECEndpoint: "https://splunk.example.com:8088",
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
	configYAML := cm.Data[otelConfigDataKey]
	assert.NotEmpty(t, configYAML)
	assert.Equal(t, otelConfigManaged, cm.Annotations[otelConfigManagementAnnotation])
	assert.Equal(t, otelConfigVersion, cm.Annotations[otelConfigVersionAnnotation])
	assert.Equal(t, otelConfigHash(configYAML), cm.Annotations[otelConfigHashAnnotation])

	var config map[string]interface{}
	require.NoError(t, syaml.Unmarshal([]byte(configYAML), &config))
	exporter := config["exporters"].(map[string]interface{})["splunk_hec"].(map[string]interface{})
	tls := exporter["tls"].(map[string]interface{})
	assert.Equal(t, "https://splunk.example.com:8088/services/collector", exporter["endpoint"])
	assert.Equal(t, false, tls["insecure_skip_verify"], "a new ConfigMap must verify HEC TLS")
}

func TestReconcileOtelConfigMap_MigratesLegacyGeneratedConfig(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	tests := []struct {
		name              string
		id                string
		withCA            bool
		legacyEndpoint    bool
		legacyInsecureTLS bool
	}{
		{name: "insecure TLS only", id: "insecure", legacyInsecureTLS: true},
		{name: "management endpoint only", id: "endpoint", withCA: true, legacyEndpoint: true},
		{name: "management endpoint and insecure TLS", id: "combined", legacyEndpoint: true, legacyInsecureTLS: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			platform := otelTestPlatform("legacy-platform-" + tt.id)
			if tt.withCA {
				platform.Spec.SplunkConfiguration.CACertRef = &aiApi.CABundleRef{Name: "splunk-ca"}
			}
			secret := otelTestSecret(platform.Namespace)

			seedClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret.DeepCopy()).Build()
			seedBuilder := New(seedClient, scheme, record.NewFakeRecorder(10), platform)
			desired, err := seedBuilder.renderOtelConf(ctx, platform)
			require.NoError(t, err)
			legacy, err := cloneOtelConfig(desired)
			require.NoError(t, err)
			if tt.legacyEndpoint {
				require.NoError(t, setOtelExporterField(legacy, "endpoint", "https://splunk.example.com:8089/services/collector"))
			}
			if tt.legacyInsecureTLS {
				require.NoError(t, setOtelExporterField(legacy, "tls", map[string]interface{}{"insecure_skip_verify": true}))
			}
			legacyYAML, err := syaml.Marshal(legacy)
			require.NoError(t, err)

			cm := &corev1.ConfigMap{
				ObjectMeta: metav1.ObjectMeta{Name: platform.Name + "-otel-config", Namespace: platform.Namespace},
				Data:       map[string]string{otelConfigDataKey: string(legacyYAML)},
			}
			require.NoError(t, controllerutil.SetOwnerReference(platform, cm, scheme), "legacy operator ConfigMaps have an AIPlatform owner reference")
			fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret, cm).Build()
			builder := New(fakeClient, scheme, record.NewFakeRecorder(10), platform)

			require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))
			require.NoError(t, fakeClient.Get(ctx, clientKey(platform.Namespace, cm.Name), cm))

			var migrated map[string]interface{}
			require.NoError(t, syaml.Unmarshal([]byte(cm.Data[otelConfigDataKey]), &migrated))
			exporter := migrated["exporters"].(map[string]interface{})["splunk_hec"].(map[string]interface{})
			tls := exporter["tls"].(map[string]interface{})
			assert.Equal(t, "https://splunk.example.com:8088/services/collector", exporter["endpoint"])
			assert.Equal(t, false, tls["insecure_skip_verify"])
			assert.Equal(t, otelConfigManaged, cm.Annotations[otelConfigManagementAnnotation])
			assert.Equal(t, otelConfigVersion, cm.Annotations[otelConfigVersionAnnotation])
			assert.Equal(t, otelConfigHash(cm.Data[otelConfigDataKey]), cm.Annotations[otelConfigHashAnnotation])
		})
	}
}

func TestReconcileOtelConfigMap_MigratesLegacyGeneratedConfigAcrossDynamicDrift(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()
	t.Setenv("SPLUNK_METRICS_INDEX_NAME", "current-index")
	platform := otelTestPlatform("legacy-dynamic-drift")
	platform.Spec.SplunkConfiguration.Endpoint = "https://current-management.example.com:8089"
	platform.Spec.SplunkConfiguration.HECEndpoint = "https://current-hec.example.com:8088"
	secret := otelTestSecret(platform.Namespace)
	secret.Data["hec_token"] = []byte("current-token")

	legacy := buildOtelConfig(
		platform.Name,
		"old-token",
		"https://old-endpoint.example.com:8088/services/collector",
		"old-index",
		map[string]interface{}{"insecure_skip_verify": true},
	)
	legacyYAML, err := syaml.Marshal(legacy)
	require.NoError(t, err)
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: platform.Name + "-otel-config", Namespace: platform.Namespace},
		Data:       map[string]string{otelConfigDataKey: string(legacyYAML)},
	}
	require.NoError(t, controllerutil.SetOwnerReference(platform, cm, scheme))
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret, cm).Build()
	builder := New(fakeClient, scheme, record.NewFakeRecorder(10), platform)

	require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))
	require.NoError(t, fakeClient.Get(ctx, clientKey(platform.Namespace, cm.Name), cm))
	var migrated map[string]interface{}
	require.NoError(t, syaml.Unmarshal([]byte(cm.Data[otelConfigDataKey]), &migrated))
	exporter := migrated["exporters"].(map[string]interface{})["splunk_hec"].(map[string]interface{})
	assert.Equal(t, "current-token", exporter["token"])
	assert.Equal(t, "https://current-hec.example.com:8088/services/collector", exporter["endpoint"])
	assert.Equal(t, "current-index", exporter["index"])
	assert.Equal(t, map[string]interface{}{"insecure_skip_verify": false}, exporter["tls"])
	assert.Equal(t, otelConfigManaged, cm.Annotations[otelConfigManagementAnnotation])
}

func TestReconcileOtelConfigMap_DoesNotAdoptLegacyLookalikes(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	tests := []struct {
		name   string
		mutate func(*corev1.ConfigMap, map[string]interface{}, *aiApi.AIPlatform)
	}{
		{
			name: "static config field edited",
			mutate: func(_ *corev1.ConfigMap, config map[string]interface{}, _ *aiApi.AIPlatform) {
				exporter := config["exporters"].(map[string]interface{})["splunk_hec"].(map[string]interface{})
				exporter["timeout"] = "99s"
			},
		},
		{
			name: "extra label",
			mutate: func(cm *corev1.ConfigMap, _ map[string]interface{}, _ *aiApi.AIPlatform) {
				cm.Labels = map[string]string{"user.example/managed": "true"}
			},
		},
		{
			name: "stale owner UID",
			mutate: func(cm *corev1.ConfigMap, _ map[string]interface{}, platform *aiApi.AIPlatform) {
				cm.OwnerReferences[0].UID = types.UID(string(platform.UID) + "-old")
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			platform := otelTestPlatform("legacy-lookalike-" + strings.ReplaceAll(tt.name, " ", "-"))
			secret := otelTestSecret(platform.Namespace)
			legacy := buildOtelConfig(
				platform.Name,
				"old-token",
				"https://old.example.com:8088/services/collector",
				"old-index",
				map[string]interface{}{"insecure_skip_verify": true},
			)
			cm := &corev1.ConfigMap{
				ObjectMeta: metav1.ObjectMeta{Name: platform.Name + "-otel-config", Namespace: platform.Namespace},
				Data:       map[string]string{},
			}
			require.NoError(t, controllerutil.SetOwnerReference(platform, cm, scheme))
			tt.mutate(cm, legacy, platform)
			legacyYAML, err := syaml.Marshal(legacy)
			require.NoError(t, err)
			cm.Data[otelConfigDataKey] = string(legacyYAML)
			originalYAML := cm.Data[otelConfigDataKey]

			fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret, cm).Build()
			builder := New(fakeClient, scheme, record.NewFakeRecorder(10), platform)
			require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))
			require.NoError(t, fakeClient.Get(ctx, clientKey(platform.Namespace, cm.Name), cm))
			assert.Equal(t, originalYAML, cm.Data[otelConfigDataKey])
			assert.Equal(t, otelConfigUserManaged, cm.Annotations[otelConfigManagementAnnotation])
		})
	}
}

func TestReconcileOpenTelemetryCollector_FailClosesLegacyEndpointOnlyConfig(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()
	collectorGVK := schema.GroupVersionKind{Group: "opentelemetry.io", Version: "v1beta1", Kind: "OpenTelemetryCollector"}
	scheme.AddKnownTypeWithName(collectorGVK, &unstructured.Unstructured{})
	scheme.AddKnownTypeWithName(collectorGVK.GroupVersion().WithKind("OpenTelemetryCollectorList"), &unstructured.UnstructuredList{})

	platform := otelTestPlatform("legacy-endpoint-only")
	platform.Spec.SplunkConfiguration.HECEndpoint = ""
	secret := otelTestSecret(platform.Namespace)
	legacyEndpoint := platform.Spec.SplunkConfiguration.Endpoint + "/services/collector"
	legacy := buildOtelConfig(
		platform.Name,
		"old-token",
		legacyEndpoint,
		"_metrics",
		map[string]interface{}{"insecure_skip_verify": true},
	)
	legacyYAML, err := syaml.Marshal(legacy)
	require.NoError(t, err)
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: platform.Name + "-otel-config", Namespace: platform.Namespace},
		Data:       map[string]string{otelConfigDataKey: string(legacyYAML)},
	}
	require.NoError(t, controllerutil.SetOwnerReference(platform, cm, scheme))

	collector := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "opentelemetry.io/v1beta1",
		"kind":       "OpenTelemetryCollector",
		"metadata": map[string]interface{}{
			"name":      platform.Name + "-otel-coll",
			"namespace": platform.Namespace,
		},
		"spec": map[string]interface{}{"mode": "sidecar", "config": legacy},
	}}
	collector.SetGroupVersionKind(collectorGVK)
	recorder := record.NewFakeRecorder(10)
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret, cm, collector).Build()
	builder := New(fakeClient, scheme, recorder, platform)

	require.NoError(t, builder.reconcileOpenTelemetryCollector(ctx, platform), "a grandfathered config must not block unrelated AIPlatform stages")
	require.NoError(t, fakeClient.Get(ctx, clientKey(platform.Namespace, collector.GetName()), collector))
	verificationDisabled, found, err := unstructured.NestedBool(
		collector.Object,
		"spec", "config", "exporters", "splunk_hec", "tls", "insecure_skip_verify",
	)
	require.NoError(t, err)
	require.True(t, found)
	assert.False(t, verificationDisabled, "the live Collector spec must be fail-closed, not just the staging ConfigMap")
	liveEndpoint, found, err := unstructured.NestedString(collector.Object, "spec", "config", "exporters", "splunk_hec", "endpoint")
	require.NoError(t, err)
	require.True(t, found)
	assert.Equal(t, legacyEndpoint, liveEndpoint, "legacy endpoint is preserved until the CR supplies hecEndpoint")
	select {
	case event := <-recorder.Events:
		assert.Contains(t, event, "LegacyHECEndpointRequired")
	default:
		t.Fatal("expected a warning Event for the grandfathered endpoint-only configuration")
	}
}

func TestReconcileOtelConfigMap_PreservesCustomConfig(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()
	platform := otelTestPlatform("custom-platform")
	secret := otelTestSecret(platform.Namespace)
	customYAML := "receivers:\n  otlp:\n    protocols:\n      grpc: {}\nservice:\n  pipelines: {}\n"
	cm := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: platform.Name + "-otel-config", Namespace: platform.Namespace},
		Data:       map[string]string{otelConfigDataKey: customYAML},
	}
	// Old releases added this owner reference even when preserving a ConfigMap
	// initially supplied by a user, so ownership alone must not authorize an
	// overwrite.
	require.NoError(t, controllerutil.SetOwnerReference(platform, cm, scheme))
	unrelatedOwner := metav1.OwnerReference{APIVersion: "v1", Kind: "ConfigMap", Name: "unrelated-owner", UID: "unrelated-owner-uid"}
	cm.OwnerReferences = append(cm.OwnerReferences, unrelatedOwner)
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret, cm).Build()
	builder := New(fakeClient, scheme, record.NewFakeRecorder(10), platform)

	require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))
	require.NoError(t, fakeClient.Get(ctx, clientKey(platform.Namespace, cm.Name), cm))
	assert.Equal(t, customYAML, cm.Data[otelConfigDataKey])
	assert.Equal(t, otelConfigUserManaged, cm.Annotations[otelConfigManagementAnnotation])
	assert.NotContains(t, cm.Annotations, otelConfigVersionAnnotation)
	assert.NotContains(t, cm.Annotations, otelConfigHashAnnotation)
	assert.Equal(t, []metav1.OwnerReference{unrelatedOwner}, cm.OwnerReferences, "user-managed content must relinquish only AIPlatform ownership")
}

func TestReconcileOtelConfigMap_DoesNotClaimUserManagedConfigMaps(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()
	customYAML := "receivers:\n  otlp:\n    protocols:\n      grpc: {}\nservice:\n  pipelines: {}\n"

	tests := []struct {
		name        string
		annotations map[string]string
	}{
		{name: "explicit user management", annotations: map[string]string{otelConfigManagementAnnotation: otelConfigUserManaged}},
		{name: "unknown management value", annotations: map[string]string{otelConfigManagementAnnotation: "future-mode"}},
		{name: "unannotated custom config"},
		{
			name: "drifted previously managed config",
			annotations: map[string]string{
				otelConfigManagementAnnotation: otelConfigManaged,
				otelConfigHashAnnotation:       "stale-last-applied-hash",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			platform := otelTestPlatform("user-owned-" + strings.ReplaceAll(tt.name, " ", "-"))
			cm := &corev1.ConfigMap{
				ObjectMeta: metav1.ObjectMeta{
					Name:        platform.Name + "-otel-config",
					Namespace:   platform.Namespace,
					Annotations: tt.annotations,
				},
				Data: map[string]string{otelConfigDataKey: customYAML},
			}
			fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(otelTestSecret(platform.Namespace), cm).Build()
			builder := New(fakeClient, scheme, record.NewFakeRecorder(10), platform)

			require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))
			require.NoError(t, fakeClient.Get(ctx, clientKey(platform.Namespace, cm.Name), cm))
			assert.Equal(t, customYAML, cm.Data[otelConfigDataKey])
			assert.Equal(t, otelConfigUserManaged, cm.Annotations[otelConfigManagementAnnotation])
			assert.Empty(t, cm.OwnerReferences, "user-managed ConfigMap must not become garbage-collection-owned by AIPlatform")
		})
	}
}

func TestReconcileOtelConfigMap_PreservesDriftFromLastAppliedHash(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()
	platform := otelTestPlatform("edited-platform")
	secret := otelTestSecret(platform.Namespace)
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret).Build()
	builder := New(fakeClient, scheme, record.NewFakeRecorder(10), platform)

	require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))
	cm := &corev1.ConfigMap{}
	key := clientKey(platform.Namespace, platform.Name+"-otel-config")
	require.NoError(t, fakeClient.Get(ctx, key, cm))
	require.Len(t, cm.OwnerReferences, 1, "new operator-managed ConfigMap starts lifecycle-owned")
	userEdit := cm.Data[otelConfigDataKey] + "# intentionally managed by the user\n"
	cm.Data[otelConfigDataKey] = userEdit
	require.NoError(t, fakeClient.Update(ctx, cm))

	platform.Spec.SplunkConfiguration.HECEndpoint = "https://new-hec.example.com:8088"
	require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))
	require.NoError(t, fakeClient.Get(ctx, key, cm))
	assert.Equal(t, userEdit, cm.Data[otelConfigDataKey], "content drift must not be overwritten")
	assert.Equal(t, otelConfigUserManaged, cm.Annotations[otelConfigManagementAnnotation])
	assert.Empty(t, cm.OwnerReferences, "ownership must be relinquished when managed content becomes user-managed")
}

func TestReconcileOtelConfigMap_UpdatesUntouchedManagedConfig(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()
	platform := otelTestPlatform("managed-platform")
	secret := otelTestSecret(platform.Namespace)
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret).Build()
	builder := New(fakeClient, scheme, record.NewFakeRecorder(10), platform)

	require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))
	platform.Spec.SplunkConfiguration.HECEndpoint = "https://new-hec.example.com:8088"
	require.NoError(t, builder.reconcileOtelConfigMap(ctx, platform))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(ctx, clientKey(platform.Namespace, platform.Name+"-otel-config"), cm))
	var config map[string]interface{}
	require.NoError(t, syaml.Unmarshal([]byte(cm.Data[otelConfigDataKey]), &config))
	exporter := config["exporters"].(map[string]interface{})["splunk_hec"].(map[string]interface{})
	assert.Equal(t, "https://new-hec.example.com:8088/services/collector", exporter["endpoint"])
	assert.Equal(t, otelConfigHash(cm.Data[otelConfigDataKey]), cm.Annotations[otelConfigHashAnnotation])
	require.Len(t, cm.OwnerReferences, 1, "operator-managed ConfigMap should remain lifecycle-owned")
	assert.Equal(t, platform.UID, cm.OwnerReferences[0].UID)
}

func TestReconcileOtelConfigMap_RenderErrorsArePropagated(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()

	tests := []struct {
		name       string
		platform   *aiApi.AIPlatform
		withSecret bool
		wantErrSub string
	}{
		{
			name:       "missing secret",
			platform:   otelTestPlatform("missing-secret"),
			wantErrSub: "loading secret",
		},
		{
			name: "HEC endpoint without secretRef",
			platform: func() *aiApi.AIPlatform {
				p := otelTestPlatform("hec-without-secret")
				p.Spec.SplunkConfiguration.Endpoint = ""
				p.Spec.SplunkConfiguration.SecretRef = corev1.SecretReference{}
				return p
			}(),
			wantErrSub: "requires a Kubernetes secretRef",
		},
		{
			name: "missing endpoint",
			platform: func() *aiApi.AIPlatform {
				p := otelTestPlatform("missing-endpoint")
				p.Spec.SplunkConfiguration.Endpoint = ""
				p.Spec.SplunkConfiguration.HECEndpoint = ""
				return p
			}(),
			withSecret: true,
			wantErrSub: "hecEndpoint",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fakeBuilder := fake.NewClientBuilder().WithScheme(scheme)
			if tt.withSecret {
				fakeBuilder = fakeBuilder.WithObjects(otelTestSecret(tt.platform.Namespace))
			}
			fakeClient := fakeBuilder.Build()
			builder := New(fakeClient, scheme, record.NewFakeRecorder(10), tt.platform)

			err := builder.reconcileOpenTelemetryCollector(ctx, tt.platform)
			require.Error(t, err)
			assert.Contains(t, err.Error(), tt.wantErrSub)
			cm := &corev1.ConfigMap{}
			getErr := fakeClient.Get(ctx, clientKey(tt.platform.Namespace, tt.platform.Name+"-otel-config"), cm)
			assert.Error(t, getErr, "a render error must not create an error-shaped ConfigMap")
		})
	}
}

func TestReconcileOpenTelemetryCollector_ProjectsOnlyCAKey(t *testing.T) {
	ctx := context.Background()
	scheme := setupFakeScheme()
	collectorGVK := schema.GroupVersionKind{Group: "opentelemetry.io", Version: "v1beta1", Kind: "OpenTelemetryCollector"}
	scheme.AddKnownTypeWithName(collectorGVK, &unstructured.Unstructured{})
	scheme.AddKnownTypeWithName(collectorGVK.GroupVersion().WithKind("OpenTelemetryCollectorList"), &unstructured.UnstructuredList{})
	platform := otelTestPlatform("projected-ca")
	platform.Spec.SplunkConfiguration.CACertRef = &aiApi.CABundleRef{Name: "leaf-tls-secret", Key: "chain.pem"}
	secret := otelTestSecret(platform.Namespace)
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(secret).Build()
	builder := New(fakeClient, scheme, record.NewFakeRecorder(10), platform)

	require.NoError(t, builder.reconcileOpenTelemetryCollector(ctx, platform))
	collector := &unstructured.Unstructured{}
	collector.SetGroupVersionKind(collectorGVK)
	require.NoError(t, fakeClient.Get(ctx, clientKey(platform.Namespace, platform.Name+"-otel-coll"), collector))
	volumes, found, err := unstructured.NestedSlice(collector.Object, "spec", "volumes")
	require.NoError(t, err)
	require.True(t, found)
	require.Len(t, volumes, 1)
	volume := volumes[0].(map[string]interface{})
	secretProjection := volume["secret"].(map[string]interface{})
	assert.Equal(t, "leaf-tls-secret", secretProjection["secretName"])
	items := secretProjection["items"].([]interface{})
	require.Len(t, items, 1)
	assert.Equal(t, map[string]interface{}{"key": "chain.pem", "path": "chain.pem"}, items[0])
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
				HECEndpoint: "https://splunk.example.com",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf, err := builder.renderOtelConf(ctx, platform)
	require.NoError(t, err)

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

	conf, err := builder.renderOtelConf(ctx, platform)
	require.NoError(t, err)
	exporters := conf["exporters"].(map[string]interface{})
	splunkHec := exporters["splunk_hec"].(map[string]interface{})

	assert.Equal(t, "https://splunk.example.com:8088/services/collector", splunkHec["endpoint"],
		"HECEndpoint must be used for the HEC URL, not Endpoint")
}

func TestRenderOtelConf_DoesNotFallBackToManagementEndpoint(t *testing.T) {
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

	conf, err := builder.renderOtelConf(ctx, platform)
	assert.Nil(t, conf)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "hecEndpoint")
}

func TestRenderOtelConf_NoHECEndpointReturnsError(t *testing.T) {
	// No hecEndpoint is set, so renderOtelConf must fail loudly instead of shipping
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

	conf, err := builder.renderOtelConf(ctx, platform)
	assert.Nil(t, conf)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "hecEndpoint")
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
				SecretRef:   corev1.SecretReference{Name: "splunk-secret"},
				HECEndpoint: "https://splunk.example.com:8088",
				CACertRef:   &aiApi.CABundleRef{Name: "splunk-ca-bundle"},
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf, err := builder.renderOtelConf(ctx, platform)
	require.NoError(t, err)
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
				SecretRef:   corev1.SecretReference{Name: "splunk-secret"},
				HECEndpoint: "https://splunk.example.com:8088",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf, err := builder.renderOtelConf(ctx, platform)
	require.NoError(t, err)
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

	conf, err := builder.renderOtelConf(ctx, platform)

	assert.Nil(t, conf)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "loading secret")
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
				HECEndpoint: "https://splunk.example.com",
			},
		},
	}

	recorder := record.NewFakeRecorder(100)
	builder := New(fakeClient, scheme, recorder, platform)

	conf, err := builder.renderOtelConf(ctx, platform)

	assert.Nil(t, conf)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "hec_token field not found")
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
				HECEndpoint: "https://splunk.example.com",
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
				HECEndpoint: "https://splunk.example.com",
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

func otelTestPlatform(name string) *aiApi.AIPlatform {
	return &aiApi.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: "default", UID: types.UID(name + "-uid")},
		Spec: aiApi.AIPlatformSpec{
			Sidecars: aiApi.SidecarSpec{Otel: true},
			SplunkConfiguration: aiApi.SplunkConfigurationSpec{
				SecretRef:   corev1.SecretReference{Name: "splunk-secret"},
				Endpoint:    "https://splunk.example.com:8089",
				HECEndpoint: "https://splunk.example.com:8088",
			},
		},
	}
}

func otelTestSecret(namespace string) *corev1.Secret {
	return &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "splunk-secret", Namespace: namespace},
		Data:       map[string][]byte{"hec_token": []byte("test-token")},
	}
}
