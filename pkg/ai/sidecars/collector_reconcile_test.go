package sidecars

import (
	"context"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func TestReconcileOpenTelemetryCollectorKeepsAPIDefaults(t *testing.T) {
	ctx := context.Background()
	t.Setenv("RELATED_IMAGE_OTEL_COLLECTOR", "")
	platform := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "otel-fixture", Namespace: "default", UID: "test-platform"},
		Spec: aiv1.AIPlatformSpec{
			Sidecars: aiv1.SidecarSpec{Otel: true},
			SplunkConfiguration: aiv1.SplunkConfigurationSpec{
				SecretRef: corev1.SecretReference{Name: "hec-credentials"},
			},
		},
	}
	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: platform.Name + "-otel-config", Namespace: platform.Namespace},
		Data:       map[string]string{"otel-config.yaml": "processors:\n  batch:\n    send_batch_size: 64\n"},
	}

	// The fake tracker alone does not perform the unstructured JSON round trip
	// or the collector webhook's defaulting of fields outside our desired spec.
	applyAPIDefaults := func(collector *unstructured.Unstructured) {
		data, err := collector.MarshalJSON()
		require.NoError(t, err)
		var decoded unstructured.Unstructured
		require.NoError(t, decoded.UnmarshalJSON(data))
		for field, value := range map[string]interface{}{"replicas": int64(1), "upgradeStrategy": "automatic"} {
			_, exists, err := unstructured.NestedFieldNoCopy(decoded.Object, "spec", field)
			require.NoError(t, err)
			if !exists {
				require.NoError(t, unstructured.SetNestedField(decoded.Object, value, "spec", field))
			}
		}
		collector.Object = decoded.Object
	}
	updates := 0
	scheme := setupFakeScheme()
	c := fake.NewClientBuilder().WithScheme(scheme).WithObjects(configMap).WithInterceptorFuncs(interceptor.Funcs{
		Create: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.CreateOption) error {
			if collector, ok := obj.(*unstructured.Unstructured); ok {
				applyAPIDefaults(collector)
			}
			return c.Create(ctx, obj, opts...)
		},
		Update: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.UpdateOption) error {
			if collector, ok := obj.(*unstructured.Unstructured); ok {
				updates++
				applyAPIDefaults(collector)
			}
			return c.Update(ctx, obj, opts...)
		},
	}).Build()
	builder := New(c, scheme, record.NewFakeRecorder(10), platform)
	require.NoError(t, builder.reconcileOpenTelemetryCollector(ctx, platform))
	for range 3 {
		require.NoError(t, builder.reconcileOpenTelemetryCollector(ctx, platform))
	}
	require.Zero(t, updates)

	// Replacing the config still removes entries deleted from the ConfigMap.
	require.NoError(t, c.Get(ctx, client.ObjectKeyFromObject(configMap), configMap))
	configMap.Data["otel-config.yaml"] = "exporters: {}\n"
	require.NoError(t, c.Update(ctx, configMap))
	require.NoError(t, builder.reconcileOpenTelemetryCollector(ctx, platform))
	require.NoError(t, builder.reconcileOpenTelemetryCollector(ctx, platform))
	require.Equal(t, 1, updates)

	collector := &unstructured.Unstructured{}
	collector.SetGroupVersionKind(schema.GroupVersionKind{Group: "opentelemetry.io", Version: "v1beta1", Kind: "OpenTelemetryCollector"})
	require.NoError(t, c.Get(ctx, client.ObjectKey{Namespace: platform.Namespace, Name: platform.Name + "-otel-coll"}, collector))
	_, present, err := unstructured.NestedMap(collector.Object, "spec", "config", "processors")
	require.NoError(t, err)
	require.False(t, present)
	replicas, present, err := unstructured.NestedInt64(collector.Object, "spec", "replicas")
	require.NoError(t, err)
	require.True(t, present)
	require.Equal(t, int64(1), replicas)
}
