/*
File: controllers/validate.go
*/
package ai_platform

import (
	"context"
	"fmt"
	"os"

	corev1 "k8s.io/api/core/v1"
	//"k8s.io/apimachinery/pkg/api/resource"
	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
	splunkutils "github.com/splunk/splunk-ai-operator/pkg/splunkutils"
)

// Validate checks required fields and backfills defaults on the AIPlatform spec.
func (r *AIPlatformReconciler) validate(ctx context.Context, p *aiApi.AIPlatform) error {
	if platformRequiresObjectStorage(p.Spec.Features) && (p.Spec.ObjectStorage == nil || p.Spec.ObjectStorage.Path == "") {
		return fmt.Errorf("object storage is required for the enabled features")
	}
	if p.Spec.CPUSchedulingSpec == nil {
		p.Spec.CPUSchedulingSpec = &aiApi.SchedulingSpec{
			NodeSelector: map[string]string{},
			Tolerations:  []corev1.Toleration{},
			Affinity:     &corev1.Affinity{},
		}
	}
	if p.Spec.GPUSchedulingSpec == nil {
		p.Spec.GPUSchedulingSpec = &aiApi.SchedulingSpec{
			NodeSelector: map[string]string{},
			Tolerations:  []corev1.Toleration{},
			Affinity:     &corev1.Affinity{},
		}
	}
	if err := validateIngressPathsForFeatures(p); err != nil {
		return err
	}

	var resolver splunkutils.SplunkSecretResolver
	if p.Spec.SplunkConfiguration.SecretSource == aiApi.SecretSourceVault {
		resolver = &splunkutils.VaultFileResolver{}
	} else {
		resolver = &splunkutils.KubernetesSecretResolver{Client: r.Client}
	}

	return splunkutils.ValidateAndEnrichSplunkConfig(
		ctx,
		r.Client,
		p.Namespace,
		p.Spec.ClusterDomain,
		&p.Spec.SplunkConfiguration,
		resolver,
	)

}

func SetImageRegistry(key, defaultValue string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultValue
}

func validateIngressPathsForFeatures(p *aiApi.AIPlatform) error {
	if p.Spec.Ingress == nil || !p.Spec.Ingress.Enabled || platformRequiresRay(p.Spec.Features) {
		return nil
	}

	for _, hostSpec := range p.Spec.Ingress.Hosts {
		for _, pathSpec := range hostSpec.Paths {
			switch pathSpec.Path {
			case "/weaviate", "/weaviate/*":
				continue
			default:
				return fmt.Errorf("ingress path %q requires Ray; only /weaviate and /weaviate/* are supported when Ray is disabled", pathSpec.Path)
			}
		}
	}

	return nil
}
