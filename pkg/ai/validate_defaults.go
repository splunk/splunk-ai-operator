/*
File: controllers/validate.go
*/
package ai_platform

import (
	"context"
	"fmt"
	"os"

	// corev1 "k8s.io/api/core/v1"
	// "k8s.io/apimachinery/pkg/api/resource"

	aiApi "github.com/splunk/splunk-ai-operator/api/v1"
)

// Validate checks required fields and backfills defaults on the AIPlatform spec.
func (r *AIPlatformReconciler) validate(ctx context.Context, p *aiApi.AIPlatform) error {
	// Required volume paths
	if p.Spec.Volume.Path == "" {
		return fmt.Errorf("Object storage is required")
	}

	return nil
}

func SetImageRegistry(key, defaultValue string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultValue
}
