package splunkutils

import (
	"context"
	"fmt"

	//corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
)

type SplunkSecretResolver interface {
	GetHECToken(ctx context.Context, namespace string, cfg *aiApi.SplunkConfigurationSpec) (string, error)
}

func validateAndEnrichSplunkEndpoint(
	ctx context.Context,
	c client.Client,
	namespace string,
	clusterDomain string,
	cfg *aiApi.SplunkConfigurationSpec,
) error {
	if cfg.Endpoint != "" {
		return nil
	}

	if cfg.SplunkCustomResourceRef.Name != "" {
		endpoint, err := ResolveSplunkEndpoint(ctx, c, namespace, *cfg, clusterDomain)
		if err != nil {
			return fmt.Errorf("failed to resolve Splunk endpoint: %w", err)
		}
		cfg.Endpoint = endpoint
		return nil
	}

	return fmt.Errorf("SplunkConfiguration must have either Endpoint or SplunkCustomResourceRef set")
}

// ValidateAndEnrichSplunkIssuer validates and resolves the management/JWKS
// endpoint used for JWT issuer discovery. It deliberately does not require a
// HEC token because issuer validation and telemetry export are independent.
//
// clusterDomain can be empty and defaults to "cluster.local" during endpoint
// resolution.
var ValidateAndEnrichSplunkIssuer = validateAndEnrichSplunkEndpoint

// ValidateAndEnrichSplunkConfig validates a telemetry-enabled Splunk
// configuration. In addition to resolving the management endpoint, it verifies
// that the configured secret source can supply a HEC token.
var ValidateAndEnrichSplunkConfig = func(
	ctx context.Context,
	c client.Client,
	namespace string,
	clusterDomain string,
	cfg *aiApi.SplunkConfigurationSpec,
	resolver SplunkSecretResolver,
) error {
	if err := validateAndEnrichSplunkEndpoint(ctx, c, namespace, clusterDomain, cfg); err != nil {
		return err
	}
	return ensureToken(ctx, namespace, cfg, resolver)
}

func ensureToken(ctx context.Context, namespace string, cfg *aiApi.SplunkConfigurationSpec, resolver SplunkSecretResolver) error {
	_, err := resolver.GetHECToken(ctx, namespace, cfg)
	if err != nil {
		return err
	}
	// Intentionally not writing the resolved token back to cfg.Token:
	// persisting secret material to the tenant-readable spec field in etcd
	// would allow any holder of *-editor-role to exfiltrate the token.
	return nil
}
