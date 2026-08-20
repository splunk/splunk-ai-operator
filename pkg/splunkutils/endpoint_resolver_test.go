package splunkutils

import (
	"context"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	splunkv1 "github.com/splunk/splunk-operator/api/v4"
	corev1 "k8s.io/api/core/v1"

	"github.com/stretchr/testify/assert"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestResolveSplunkEndpoint_DirectEndpoint(t *testing.T) {
	cfg := aiApi.SplunkConfigurationSpec{
		Endpoint: "https://custom-endpoint:8089",
	}

	// fake client not used in this case
	fc := fake.NewClientBuilder().Build()

	got, err := ResolveSplunkEndpoint(context.Background(), fc, "ns", cfg, "")
	assert.NoError(t, err)
	assert.Equal(t, "https://custom-endpoint:8089", got, "should return direct endpoint if provided")
}

func TestResolveSplunkEndpoint_NoEndpointOrRef(t *testing.T) {
	cfg := aiApi.SplunkConfigurationSpec{}

	fc := fake.NewClientBuilder().Build()

	_, err := ResolveSplunkEndpoint(context.Background(), fc, "ns", cfg, "")
	assert.Error(t, err)
	assert.Equal(t, "no Splunk endpoint or reference provided", err.Error())
}

func TestResolveSplunkEndpoint_Standalone(t *testing.T) {
	ns := "ns"
	name := "foo"

	// Create a fake Standalone resource
	standalone := &splunkv1.Standalone{}
	standalone.Name = name
	standalone.Namespace = ns

	scheme := runtime.NewScheme()
	_ = splunkv1.AddToScheme(scheme)

	fc := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(standalone).
		Build()

	cfg := aiApi.SplunkConfigurationSpec{
		SplunkCustomResourceRef: corev1.ObjectReference{
			Name:      name,
			Kind:      "Standalone",
			Namespace: ns,
		},
	}

	got, err := ResolveSplunkEndpoint(context.Background(), fc, ns, cfg, "mydomain")
	assert.NoError(t, err)

	expected := "https://splunk-foo-standalone-service.ns.svc.mydomain:8089"
	assert.Equal(t, expected, got)
}

func TestResolveSplunkEndpoint_IndexerCluster(t *testing.T) {
	ns := "ns"
	name := "bar"

	// Create a fake IndexerCluster resource
	ic := &splunkv1.IndexerCluster{}
	ic.Name = name
	ic.Namespace = ns

	scheme := runtime.NewScheme()
	_ = splunkv1.AddToScheme(scheme)

	fc := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(ic).
		Build()

	cfg := aiApi.SplunkConfigurationSpec{
		SplunkCustomResourceRef: corev1.ObjectReference{
			Name:      name,
			Kind:      "IndexerCluster",
			Namespace: ns,
		},
	}

	got, err := ResolveSplunkEndpoint(context.Background(), fc, ns, cfg, "")
	assert.NoError(t, err)

	expected := "https://splunk-bar-indexer-service.ns.svc.cluster.local:8089"
	assert.Equal(t, expected, got)
}

func TestResolveSplunkEndpoint_UnsupportedKind(t *testing.T) {
	cfg := aiApi.SplunkConfigurationSpec{
		SplunkCustomResourceRef: corev1.ObjectReference{
			Name:      "foo",
			Kind:      "OtherKind",
			Namespace: "ns",
		},
	}

	scheme := runtime.NewScheme()
	_ = splunkv1.AddToScheme(scheme)
	fc := fake.NewClientBuilder().WithScheme(scheme).Build()

	_, err := ResolveSplunkEndpoint(context.Background(), fc, "ns", cfg, "")
	assert.Error(t, err)
	assert.Equal(t, `unsupported Splunk kind "OtherKind" for endpoint resolution`, err.Error())
}

func TestResolveSplunkEndpoint_ResourceNotFound(t *testing.T) {
	ns := "ns"
	name := "foo"

	// Note: we deliberately DON'T add the resource to the fake client
	scheme := runtime.NewScheme()
	_ = splunkv1.AddToScheme(scheme)
	fc := fake.NewClientBuilder().WithScheme(scheme).Build()

	cfg := aiApi.SplunkConfigurationSpec{
		SplunkCustomResourceRef: corev1.ObjectReference{
			Name:      name,
			Kind:      "Standalone",
			Namespace: ns,
		},
	}

	_, err := ResolveSplunkEndpoint(context.Background(), fc, ns, cfg, "")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "not found", "expected missing resource error")
}
