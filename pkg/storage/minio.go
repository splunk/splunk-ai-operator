package storage

import (
	"context"

	ai "github.com/splunk/splunk-ai-operator/api/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// NewMinioClient creates a StorageClient for MinIO (S3-compatible). It delegates to NewS3CompatibleClient.
// Deprecated: Prefer NewS3CompatibleClient for MinIO, SeaweedFS, or any S3-compatible backend.
func NewMinioClient(
	ctx context.Context,
	k8sClient client.Client,
	namespace, bucket, prefix string,
	vs ai.ObjectStorageSpec,
) (StorageClient, error) {
	return NewS3CompatibleClient(ctx, k8sClient, namespace, bucket, prefix, vs)
}
