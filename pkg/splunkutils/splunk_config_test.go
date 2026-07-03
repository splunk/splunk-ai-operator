package splunkutils

import (
	"context"
	"errors"
	"fmt"
	"testing"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// --- Fake Resolver ---
type fakeResolver struct {
	tokenVal   string
	tokenErr   error
	calledWith *aiApi.SplunkConfigurationSpec
}

func (f *fakeResolver) GetHECToken(ctx context.Context, namespace string, cfg *aiApi.SplunkConfigurationSpec) (string, error) {
	f.calledWith = cfg
	if f.tokenErr != nil {
		return "", f.tokenErr
	}
	return f.tokenVal, nil
}

// --- Patchable ResolveSplunkEndpoint for testing ---
var origResolveSplunkEndpoint = ResolveSplunkEndpoint

func patchResolveSplunkEndpoint(f func(context.Context, client.Client, string, aiApi.SplunkConfigurationSpec, string) (string, error)) {
	ResolveSplunkEndpoint = f
}

func restoreResolveSplunkEndpoint() {
	ResolveSplunkEndpoint = origResolveSplunkEndpoint
}

func TestValidateAndEnrichSplunkConfig(t *testing.T) {
	ctx := context.Background()
	ns := "test-ns"

	// Fake client is empty because we stub endpoint resolution anyway
	fc := fake.NewClientBuilder().Build()

	t.Run("explicit endpoint should just ensure token", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{
			Endpoint: "https://custom-endpoint:8089",
		}

		resolver := &fakeResolver{tokenVal: "fake-token"}

		err := ValidateAndEnrichSplunkConfig(ctx, fc, ns, "", cfg, resolver)

		assert.NoError(t, err)
		// Token must NOT be written back to the spec to prevent exfiltration via etcd.
		assert.Empty(t, cfg.Token)
		assert.Equal(t, "https://custom-endpoint:8089", cfg.Endpoint)
	})

	t.Run("explicit endpoint but resolver fails", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{
			Endpoint: "https://custom-endpoint:8089",
		}
		resolver := &fakeResolver{tokenErr: errors.New("resolver failed")}

		err := ValidateAndEnrichSplunkConfig(ctx, fc, ns, "", cfg, resolver)

		assert.Error(t, err)
		assert.Contains(t, err.Error(), "resolver failed")
	})

	t.Run("missing endpoint but SplunkCustomResourceRef present → resolve endpoint & ensure token", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{
			SplunkCustomResourceRef: corev1.ObjectReference{
				Name:      "foo",
				Kind:      "Standalone",
				Namespace: ns,
			},
		}

		// Patch endpoint resolver to return a fake URL
		patchResolveSplunkEndpoint(func(ctx context.Context, c client.Client, namespace string, cfg aiApi.SplunkConfigurationSpec, clusterDomain string) (string, error) {
			return "https://resolved-endpoint:8089", nil
		})
		defer restoreResolveSplunkEndpoint()

		resolver := &fakeResolver{tokenVal: "resolved-token"}

		err := ValidateAndEnrichSplunkConfig(ctx, fc, ns, "mydomain", cfg, resolver)

		assert.NoError(t, err)
		assert.Equal(t, "https://resolved-endpoint:8089", cfg.Endpoint)
		// Token must NOT be written back to the spec to prevent exfiltration via etcd.
		assert.Empty(t, cfg.Token)
	})

	t.Run("missing endpoint but SplunkCustomResourceRef present → endpoint resolution fails", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{
			SplunkCustomResourceRef: corev1.ObjectReference{
				Name:      "foo",
				Kind:      "Standalone",
				Namespace: ns,
			},
		}

		patchResolveSplunkEndpoint(func(ctx context.Context, c client.Client, namespace string, cfg aiApi.SplunkConfigurationSpec, clusterDomain string) (string, error) {
			return "", fmt.Errorf("endpoint resolution failed")
		})
		defer restoreResolveSplunkEndpoint()

		resolver := &fakeResolver{tokenVal: "resolved-token"}

		err := ValidateAndEnrichSplunkConfig(ctx, fc, ns, "mydomain", cfg, resolver)

		assert.Error(t, err)
		assert.Contains(t, err.Error(), "failed to resolve Splunk endpoint")
	})

	t.Run("missing both endpoint and SplunkCustomResourceRef → should fail", func(t *testing.T) {
		cfg := &aiApi.SplunkConfigurationSpec{} // no endpoint & no ref
		resolver := &fakeResolver{}

		err := ValidateAndEnrichSplunkConfig(ctx, fc, ns, "", cfg, resolver)

		assert.Error(t, err)
		assert.Contains(t, err.Error(), "must have either Endpoint or SplunkCustomResourceRef")
	})
}
