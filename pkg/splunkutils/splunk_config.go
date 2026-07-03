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

// ValidateAndEnrichSplunkConfig validates a SplunkConfiguration.
// - If Endpoint is provided, it's valid.
// - If Endpoint is empty but SplunkCustomResourceRef is set → resolve endpoint from Splunk CR.
// - Ensures SecretRef is populated with namespace-scoped secret if missing.
//
// clusterDomain can be empty → defaults to "cluster.local".
var ValidateAndEnrichSplunkConfig = func(
	ctx context.Context,
	c client.Client,
	namespace string,
	clusterDomain string,
	cfg *aiApi.SplunkConfigurationSpec,
	resolver SplunkSecretResolver,
) error {
	// ✅ 1: Check if endpoint explicitly provided
	if cfg.Endpoint != "" {
		return ensureToken(ctx, namespace, cfg, resolver)
	}

	// ✅ 2: Derive endpoint from SplunkCustomResourceRef
	if cfg.SplunkCustomResourceRef.Name != "" {
		endpoint, err := ResolveSplunkEndpoint(ctx, c, namespace, *cfg, clusterDomain)
		if err != nil {
			return fmt.Errorf("failed to resolve Splunk endpoint: %w", err)
		}
		cfg.Endpoint = endpoint

		return ensureToken(ctx, namespace, cfg, resolver)
	}

	// ✅ 3: Neither endpoint nor CR ref → invalid
	return fmt.Errorf("SplunkConfiguration must have either Endpoint or SplunkCustomResourceRef set")
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
