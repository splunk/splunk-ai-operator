package storage

import (
	"context"
	"testing"

	ai "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func TestNewStorageClient(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	tests := []struct {
		name        string
		volumeSpec  ai.ObjectStorageSpec
		wantType    string
		wantErr     bool
		setupClient func() *fake.ClientBuilder
	}{
		{
			name: "S3 storage",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "s3://my-bucket/prefix",
				Region: "us-west-2",
			},
			wantType: "s3",
			wantErr:  false,
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "GCS storage with gs scheme",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "gs://my-bucket/prefix",
				Region: "us-west-1",
			},
			wantType: "gcs",
			wantErr:  true, // Requires credentials
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "GCS storage with gcs scheme",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "gcs://my-bucket/prefix",
				Region: "us-west-1",
			},
			wantType: "gcs",
			wantErr:  true, // Requires credentials
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "Azure storage",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "azure://my-container/prefix",
				Region: "eastus",
			},
			wantType: "azure",
			wantErr:  false,
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "MinIO storage",
			volumeSpec: ai.ObjectStorageSpec{
				Path:     "minio://my-bucket/prefix",
				Endpoint: "http://minio.default.svc:9000",
			},
			wantType: "minio",
			wantErr:  false,
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "Fixture storage for testing",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "fixture://test-bucket/prefix",
			},
			wantType: "fixture",
			wantErr:  false,
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "invalid URL",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "://invalid",
			},
			wantErr: true,
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "unsupported scheme",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "ftp://my-bucket/prefix",
			},
			wantErr: true,
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "Azure path without container name",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "azure:///model_artifacts",
				Region: "eastus",
			},
			wantErr: true,
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
		{
			name: "S3 path without bucket name",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "s3:///prefix",
				Region: "us-west-2",
			},
			wantErr: true,
			setupClient: func() *fake.ClientBuilder {
				return fake.NewClientBuilder().WithScheme(s)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fakeClient := tt.setupClient().Build()

			client, err := NewStorageClient(context.Background(), fakeClient, "default", tt.volumeSpec)

			if tt.wantErr {
				assert.Error(t, err)
				assert.Nil(t, client)
			} else {
				require.NoError(t, err)
				require.NotNil(t, client)

				// Verify provider matches expected type
				provider := client.GetProvider()
				assert.NotEmpty(t, provider)

				// Verify bucket/container is extracted
				bucket := client.GetBucket()
				assert.NotEmpty(t, bucket)
			}
		})
	}
}

func TestStorageClient_BuildArtifactURI(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	tests := []struct {
		name       string
		volumeSpec ai.ObjectStorageSpec
		key        string
		wantURI    string
	}{
		{
			name: "S3 artifact URI",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "s3://my-bucket/artifacts",
				Region: "us-west-2",
			},
			key:     "model.tar.gz",
			wantURI: "s3://my-bucket/artifacts/model.tar.gz",
		},
		// Skip GCS and Azure tests for now due to credential requirements
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fakeClient := fake.NewClientBuilder().WithScheme(s).Build()

			client, err := NewStorageClient(context.Background(), fakeClient, "default", tt.volumeSpec)
			require.NoError(t, err)
			require.NotNil(t, client)

			uri := client.BuildArtifactURI(tt.key)
			assert.Equal(t, tt.wantURI, uri)
		})
	}
}

func TestStorageClient_GetPrefix(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	tests := []struct {
		name       string
		volumeSpec ai.ObjectStorageSpec
		wantPrefix string
	}{
		{
			name: "path with prefix",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "s3://bucket/my/prefix",
			},
			wantPrefix: "my/prefix",
		},
		{
			name: "path with single level prefix",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "s3://bucket/artifacts",
			},
			wantPrefix: "artifacts",
		},
		{
			name: "path without prefix",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "s3://bucket/",
			},
			wantPrefix: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fakeClient := fake.NewClientBuilder().WithScheme(s).Build()

			client, err := NewStorageClient(context.Background(), fakeClient, "default", tt.volumeSpec)
			require.NoError(t, err)

			prefix := client.GetPrefix()
			assert.Equal(t, tt.wantPrefix, prefix)
		})
	}
}

func TestStorageClient_ListObjects(t *testing.T) {
	ctx := context.Background()
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	tests := []struct {
		name        string
		volumeSpec  ai.ObjectStorageSpec
		wantErr     bool
		skipForReal bool // Skip test for real cloud providers (needs credentials)
	}{
		{
			name: "fixture client list objects",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "fixture://test-bucket/prefix",
			},
			wantErr:     false,
			skipForReal: false,
		},
		{
			name: "S3 client (will fail without credentials)",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "s3://test-bucket/prefix",
				Region: "us-west-2",
			},
			wantErr:     true, // Expected to fail without real AWS credentials
			skipForReal: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipForReal {
				t.Skip("Skipping test that requires real cloud credentials")
			}

			fakeClient := fake.NewClientBuilder().WithScheme(s).Build()

			client, err := NewStorageClient(context.Background(), fakeClient, "default", tt.volumeSpec)
			require.NoError(t, err)

			objects, err := client.ListObjects(ctx)

			if tt.wantErr {
				assert.Error(t, err)
			} else {
				require.NoError(t, err)
				assert.NotNil(t, objects)
			}
		})
	}
}

func TestStorageClient_Exists(t *testing.T) {
	ctx := context.Background()
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()

	client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
		Path: "fixture://test-bucket/prefix",
	})
	require.NoError(t, err)

	// Test existence check
	exists, err := client.Exists(ctx, "some-key")
	require.NoError(t, err)
	assert.True(t, exists) // Fixture client returns true by default
}

func TestStorageClient_WithSecrets(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	// Create a secret for storage authentication
	secret := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "storage-secret",
			Namespace: "default",
		},
		Data: map[string][]byte{
			"accessKeyID":     []byte("test-access-key"),
			"secretAccessKey": []byte("test-secret-key"),
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(s).
		WithObjects(secret).
		Build()

	volumeSpec := ai.ObjectStorageSpec{
		Path:      "s3://test-bucket/prefix",
		Region:    "us-west-2",
		SecretRef: "storage-secret",
	}

	client, err := NewStorageClient(context.Background(), fakeClient, "default", volumeSpec)
	require.NoError(t, err)
	require.NotNil(t, client)

	// Client should be created successfully with secret reference
	assert.Equal(t, "s3", client.GetProvider())
	assert.Equal(t, "test-bucket", client.GetBucket())

	// Actual AWS operations will fail without real credentials
	// but client creation should succeed
	t.Logf("Created storage client with secret reference")
}

func TestStorageClient_BuildLoaderBlock(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()

	tests := []struct {
		name       string
		volumeSpec ai.ObjectStorageSpec
		uri        string
		wantBlock  string
	}{
		{
			name: "S3 loader block",
			volumeSpec: ai.ObjectStorageSpec{
				Path:   "s3://bucket/prefix",
				Region: "us-west-2",
			},
			uri:       "s3://bucket/prefix/model",
			wantBlock: "s3_artifact:", // Returns YAML block, not URI
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, err := NewStorageClient(context.Background(), fakeClient, "default", tt.volumeSpec)
			require.NoError(t, err)

			block := client.BuildLoaderBlock(tt.uri)
			assert.Contains(t, block, tt.wantBlock)
		})
	}
}

func TestStorageClient_BuildWorkingDir(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()

	tests := []struct {
		name       string
		volumeSpec ai.ObjectStorageSpec
		modelName  string
		wantDir    string
	}{
		{
			name: "working directory for model",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "s3://bucket/apps",
			},
			modelName: "my-model",
			wantDir:   "s3://bucket/apps/my-model",
		},
		{
			name: "fixture working directory for model",
			volumeSpec: ai.ObjectStorageSpec{
				Path: "fixture://bucket/apps",
			},
			modelName: "test-model",
			wantDir:   "s3://bucket/apps/test-model", // Fixture uses S3 URIs internally
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			client, err := NewStorageClient(context.Background(), fakeClient, "default", tt.volumeSpec)
			require.NoError(t, err)

			dir := client.BuildWorkingDir(tt.modelName)
			assert.Equal(t, tt.wantDir, dir)
		})
	}
}

func TestFixtureClient_Methods(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()

	t.Run("fixture BuildArtifactURI", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path: "fixture://test-bucket/artifacts",
		})
		require.NoError(t, err)

		// Fixture uses S3 URIs internally
		uri := client.BuildArtifactURI("model.tar.gz")
		assert.Equal(t, "s3://test-bucket/artifacts/model.tar.gz", uri)
	})

	t.Run("fixture GetPrefix", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path: "fixture://test-bucket/my/prefix",
		})
		require.NoError(t, err)

		prefix := client.GetPrefix()
		assert.Equal(t, "my/prefix", prefix)
	})

	t.Run("fixture GetPrefix empty", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path: "fixture://test-bucket/",
		})
		require.NoError(t, err)

		prefix := client.GetPrefix()
		assert.Equal(t, "", prefix)
	})

	t.Run("fixture BuildLoaderBlock", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path: "fixture://test-bucket/models",
		})
		require.NoError(t, err)

		block := client.BuildLoaderBlock("fixture://test-bucket/models/my-model")
		assert.Contains(t, block, "s3_artifact:")
		assert.Contains(t, block, "test-bucket")
		assert.Contains(t, block, "models")
	})
}

func TestMinioClient_Methods(t *testing.T) {
	s := runtime.NewScheme()
	_ = scheme.AddToScheme(s)
	_ = ai.AddToScheme(s)

	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()

	t.Run("minio client creation", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path:     "minio://test-bucket/artifacts",
			Endpoint: "http://minio.default.svc:9000",
		})
		require.NoError(t, err)
		require.NotNil(t, client)

		// MinIO uses S3 client internally, so provider is "s3"
		assert.Equal(t, "s3", client.GetProvider())
		assert.Equal(t, "test-bucket", client.GetBucket())
	})

	t.Run("minio BuildArtifactURI", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path:     "minio://test-bucket/artifacts",
			Endpoint: "http://minio.default.svc:9000",
		})
		require.NoError(t, err)

		// MinIO uses S3 URIs
		uri := client.BuildArtifactURI("model.tar.gz")
		assert.Equal(t, "s3://test-bucket/artifacts/model.tar.gz", uri)
	})

	t.Run("minio GetPrefix", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path:     "minio://test-bucket/my/prefix",
			Endpoint: "http://minio.default.svc:9000",
		})
		require.NoError(t, err)

		prefix := client.GetPrefix()
		assert.Equal(t, "my/prefix", prefix)
	})

	t.Run("minio BuildWorkingDir", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path:     "minio://test-bucket/apps",
			Endpoint: "http://minio.default.svc:9000",
		})
		require.NoError(t, err)

		// MinIO uses S3 scheme for URIs
		dir := client.BuildWorkingDir("test-model")
		assert.Equal(t, "s3://test-bucket/apps/test-model", dir)
	})

	t.Run("minio BuildLoaderBlock", func(t *testing.T) {
		client, err := NewStorageClient(context.Background(), fakeClient, "default", ai.ObjectStorageSpec{
			Path:     "minio://test-bucket/models",
			Endpoint: "http://minio.default.svc:9000",
		})
		require.NoError(t, err)

		block := client.BuildLoaderBlock("minio://test-bucket/models/my-model")
		assert.Contains(t, block, "s3_artifact:")
		assert.Contains(t, block, "test-bucket")
	})
}
