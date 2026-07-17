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
	// Required volume paths
	if p.Spec.ObjectStorage.Path == "" {
		return fmt.Errorf("object storage is required")
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

	sc := p.Spec.SplunkConfiguration
	if sc.Endpoint == "" &&
		sc.SplunkCustomResourceRef.Name == "" &&
		sc.SecretRef.Name == "" &&
		sc.VaultFilePath == "" {
		r.Recorder.Event(p, corev1.EventTypeWarning, "SplunkConfigMissing",
			"Splunk configuration is missing; assuming no telemetry")
		return nil
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
