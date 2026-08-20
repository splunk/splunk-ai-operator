package splunkutils

import (
	"context"
	"fmt"

	splunkv1 "github.com/splunk/splunk-operator/api/v4" // adjust import path
	//corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
)

const (
	SplunkMgmtPort       = 8089
	defaultClusterDomain = "cluster.local"
)

// buildSplunkServiceName returns the DNS service name
func buildSplunkServiceName(identifier string, instanceType string) string {
	return fmt.Sprintf("splunk-%s-%s-service", identifier, instanceType)
}

// buildFQDN builds fully qualified service DNS name
func buildFQDN(svc, ns, clusterDomain string) string {
	if clusterDomain == "" {
		clusterDomain = defaultClusterDomain
	}
	return fmt.Sprintf("%s.%s.svc.%s", svc, ns, clusterDomain)
}

// ResolveSplunkEndpoint resolves a Splunk endpoint from SplunkConfiguration.
//  1. If Endpoint is explicitly set, return it
//  2. Otherwise, use SplunkCustomResourceRef (Standalone / IndexerCluster)
//     → derive the service FQDN: splunk-<id>-<type>-service.<ns>.svc.<clusterDomain>:8089
var ResolveSplunkEndpoint = func(ctx context.Context, c client.Client, namespace string, cfg aiApi.SplunkConfigurationSpec, clusterDomain string) (string, error) {
	// ✅ Case 1: Direct endpoint provided
	if cfg.Endpoint != "" {
		return cfg.Endpoint, nil
	}

	// ✅ Case 2: Must resolve from SplunkCustomResourceRef
	if cfg.SplunkCustomResourceRef.Name == "" {
		return "", fmt.Errorf("no Splunk endpoint or reference provided")
	}

	refNS := cfg.SplunkCustomResourceRef.Namespace
	if refNS == "" {
		refNS = namespace
	}

	switch cfg.SplunkCustomResourceRef.Kind {
	case "Standalone":
		var standalone splunkv1.Standalone
		key := types.NamespacedName{Name: cfg.SplunkCustomResourceRef.Name, Namespace: refNS}
		if err := c.Get(ctx, key, &standalone); err != nil {
			return "", fmt.Errorf("failed to fetch Splunk Standalone %q: %w", key, err)
		}

		// Service name: splunk-<name>-standalone-service
		svc := buildSplunkServiceName(standalone.Name, string(SplunkStandalone))
		fqdn := buildFQDN(svc, standalone.Namespace, clusterDomain)
		return fmt.Sprintf("https://%s:%d", fqdn, SplunkMgmtPort), nil

	case "IndexerCluster":
		var idxCluster splunkv1.IndexerCluster
		key := types.NamespacedName{Name: cfg.SplunkCustomResourceRef.Name, Namespace: refNS}
		if err := c.Get(ctx, key, &idxCluster); err != nil {
			return "", fmt.Errorf("failed to fetch Splunk IndexerCluster %q: %w", key, err)
		}

		// Service name: splunk-<name>-indexer-service
		svc := buildSplunkServiceName(idxCluster.Name, string(SplunkIndexer))
		fqdn := buildFQDN(svc, idxCluster.Namespace, clusterDomain)
		return fmt.Sprintf("https://%s:%d", fqdn, SplunkMgmtPort), nil

	default:
		return "", fmt.Errorf("unsupported Splunk kind %q for endpoint resolution", cfg.SplunkCustomResourceRef.Kind)
	}
}
