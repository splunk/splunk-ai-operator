package storage

import (
	"context"
	"fmt"
	"net/url"
	"strings"

	ai "github.com/splunk/splunk-ai-operator/api/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// StorageClient abstracts listing objects and building loader/workingDir snippets.
type StorageClient interface {
	// ListObjects returns all object keys under the volume’s prefix.
	ListObjects(ctx context.Context) ([]string, error)
	// BuildLoaderBlock returns the YAML snippet for model_loader based on the URI.
	BuildLoaderBlock(uri string) string
	// BuildWorkingDir returns the working_dir URI for an application package.
	BuildWorkingDir(modelName string) string
	// BuildArtifactURI builds the full URI (e.g. "s3://bucket/prefix/key") for an arbitrary object key.
	BuildArtifactURI(key string) string
	Exists(ctx context.Context, key string) (bool, error)
	GetProvider() string
	GetBucket() string
	GetPrefix() string
}

func NewStorageClient(
	ctx context.Context,
	k8sClient client.Client,
	namespace string,
	vs ai.ObjectStorageSpec,
) (StorageClient, error) {
	u, err := url.Parse(vs.Path)
	if err != nil {
		return nil, fmt.Errorf("invalid volume URI %q: %w", vs.Path, err)
	}

	// strip leading slash from path
	// e.g. u.Path="/prefix/..." → "prefix/..."
	prefix := strings.TrimPrefix(u.Path, "/")

	switch u.Scheme {
	case "s3":
		if u.Host == "" {
			return nil, fmt.Errorf("invalid volume URI %q: S3 path must include bucket name (e.g. s3://bucket-name/prefix)", vs.Path)
		}
		return NewS3Client(ctx, k8sClient, namespace, u.Host, prefix, vs)
	case "gs", "gcs":
		if u.Host == "" {
			return nil, fmt.Errorf("invalid volume URI %q: GCS path must include bucket name (e.g. gs://bucket-name/prefix)", vs.Path)
		}
		return NewGCSClient(ctx, k8sClient, namespace, u.Host, prefix, vs)
	case "azure":
		if u.Host == "" {
			return nil, fmt.Errorf("invalid volume URI %q: Azure path must include container name (e.g. azure://container-name/prefix). Without it, model deployments fail with 'Please specify a container name'", vs.Path)
		}
		return NewAzureClient(ctx, k8sClient, namespace, u.Host, prefix, vs)
	case "minio":
		if u.Host == "" {
			return nil, fmt.Errorf("invalid volume URI %q: MinIO path must include bucket name (e.g. minio://bucket-name/prefix)", vs.Path)
		}
		// everything after "//" is host (bucket) and path.  We treat u.Host as bucket,
		// vs.Endpoint *must* be set to our MinIO URL for this case.
		return NewMinioClient(ctx, k8sClient, namespace, u.Host, prefix, vs)
	case "fixture":
		// fixture:// is a special scheme for testing purposes, using a fake client.
		// It does not require any credentials or endpoint.
		return NewFixtureClient(k8sClient, namespace, u.Host, prefix, vs)
	default:
		return nil, fmt.Errorf("unsupported storage scheme %q", u.Scheme)
	}
}
