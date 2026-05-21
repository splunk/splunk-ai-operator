package raybuilder

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestClassifyObjectStorage covers the URL-scheme + endpoint mapping that
// determines which storage code path the SAIA / ai-platform SDK takes at
// Serve-replica startup. See classifyObjectStorage doc-comment for full
// rationale; in particular the AWS-regional-endpoint detection covers the
// case where the k0s installer requires a non-empty endpoint even for
// type=aws.
//
// Regression for: "Unsupported CLOUD_PROVIDER: s3compat" panic when an AWS
// regional endpoint was passed through to a real AWS S3 bucket.
func TestClassifyObjectStorage(t *testing.T) {
	tests := []struct {
		name                   string
		scheme                 string
		endpoint               string
		wantCloudProvider      string
		wantArtifactsProvider  string
		wantNeedsS3CompatCreds bool
	}{
		// --- AWS S3 ----------------------------------------------------------
		{
			name:                   "s3 scheme with no endpoint → AWS",
			scheme:                 "s3",
			endpoint:               "",
			wantCloudProvider:      "aws",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "s3 scheme with AWS regional endpoint → AWS (regression: was s3compat)",
			scheme:                 "s3",
			endpoint:               "https://s3.us-east-2.amazonaws.com",
			wantCloudProvider:      "aws",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "s3 scheme with AWS dualstack endpoint → AWS",
			scheme:                 "s3",
			endpoint:               "https://s3.dualstack.us-east-1.amazonaws.com",
			wantCloudProvider:      "aws",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "s3 scheme with AWS FIPS endpoint → AWS",
			scheme:                 "s3",
			endpoint:               "https://s3-fips.us-east-1.amazonaws.com",
			wantCloudProvider:      "aws",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "s3 scheme with virtual-hosted-style AWS endpoint → AWS",
			scheme:                 "s3",
			endpoint:               "https://my-bucket.s3.us-east-2.amazonaws.com",
			wantCloudProvider:      "aws",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "s3 scheme with whitespace-padded AWS endpoint → AWS",
			scheme:                 "s3",
			endpoint:               "  https://s3.us-east-2.amazonaws.com  ",
			wantCloudProvider:      "aws",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},

		// --- S3-compatible behind s3:// scheme ------------------------------
		{
			name:                   "s3 scheme with MinIO endpoint → s3compat",
			scheme:                 "s3",
			endpoint:               "http://minio.minio-system.svc.cluster.local:9000",
			wantCloudProvider:      "s3compat",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "s3 scheme with SeaweedFS endpoint → s3compat",
			scheme:                 "s3",
			endpoint:               "http://seaweed.example.com:8333",
			wantCloudProvider:      "s3compat",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "s3 scheme with plain-IP endpoint → s3compat",
			scheme:                 "s3",
			endpoint:               "http://10.0.0.5:9000",
			wantCloudProvider:      "s3compat",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},

		// --- Explicit s3-compatible schemes ---------------------------------
		{
			name:                   "s3compat scheme → s3compat",
			scheme:                 "s3compat",
			endpoint:               "https://example.com",
			wantCloudProvider:      "s3compat",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "minio scheme → s3compat",
			scheme:                 "minio",
			endpoint:               "http://minio.example.com:9000",
			wantCloudProvider:      "s3compat",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},
		{
			name:                   "seaweedfs scheme → s3compat",
			scheme:                 "seaweedfs",
			endpoint:               "http://seaweed.example.com:8333",
			wantCloudProvider:      "s3compat",
			wantArtifactsProvider:  "s3",
			wantNeedsS3CompatCreds: true,
		},

		// --- Non-S3 backends ------------------------------------------------
		{
			name:                   "gs scheme → gcp",
			scheme:                 "gs",
			endpoint:               "",
			wantCloudProvider:      "gcp",
			wantArtifactsProvider:  "gcs",
			wantNeedsS3CompatCreds: false,
		},
		{
			name:                   "gcs scheme alias → gcp",
			scheme:                 "gcs",
			endpoint:               "",
			wantCloudProvider:      "gcp",
			wantArtifactsProvider:  "gcs",
			wantNeedsS3CompatCreds: false,
		},
		{
			name:                   "azure scheme → azure",
			scheme:                 "azure",
			endpoint:               "",
			wantCloudProvider:      "azure",
			wantArtifactsProvider:  "azure",
			wantNeedsS3CompatCreds: false,
		},
		{
			name:                   "unknown scheme → azure (legacy default; preserves prior behaviour)",
			scheme:                 "wasb",
			endpoint:               "",
			wantCloudProvider:      "azure",
			wantArtifactsProvider:  "azure",
			wantNeedsS3CompatCreds: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cp, ap, needsCreds := classifyObjectStorage(tt.scheme, tt.endpoint)
			assert.Equal(t, tt.wantCloudProvider, cp, "CLOUD_PROVIDER mismatch")
			assert.Equal(t, tt.wantArtifactsProvider, ap, "ARTIFACTS_PROVIDER mismatch")
			assert.Equal(t, tt.wantNeedsS3CompatCreds, needsCreds, "needsS3CompatCreds mismatch")

			// SDK contract: CLOUD_PROVIDER must be one of aws/gcp/azure/s3compat.
			// Anything else triggers `RuntimeError: Unsupported CLOUD_PROVIDER`
			// inside the Serve replica. Catch any future drift.
			assert.Contains(t, []string{"aws", "gcp", "azure", "s3compat"}, cp,
				"classifier returned a CLOUD_PROVIDER value the SDK does not accept")
		})
	}
}

// TestIsAWSRegionalEndpoint covers the host-pattern recogniser used to tell
// real AWS S3 endpoints apart from MinIO / SeaweedFS / Wasabi etc. when the
// scheme is s3://. False negatives here would mis-classify real AWS as
// s3compat (the original bug); false positives would mis-classify an
// S3-compatible store as AWS (and silently strip the custom endpoint, leading
// to "NoSuchBucket" or wrong-region errors).
func TestIsAWSRegionalEndpoint(t *testing.T) {
	tests := []struct {
		name     string
		endpoint string
		want     bool
	}{
		// Real AWS — should return true
		{"path-style", "https://s3.us-east-2.amazonaws.com", true},
		{"path-style us-west-1", "https://s3.us-west-1.amazonaws.com", true},
		{"FIPS", "https://s3-fips.us-east-1.amazonaws.com", true},
		{"dualstack", "https://s3.dualstack.us-east-1.amazonaws.com", true},
		{"virtual-hosted bucket subdomain", "https://my-bucket.s3.us-east-2.amazonaws.com", true},
		{"case-insensitive host", "https://S3.US-EAST-2.AMAZONAWS.COM", true},
		{"china s3 (still amazonaws.com)", "https://s3.cn-north-1.amazonaws.com.cn", false}, // .cn TLD, intentionally not matched; users in China get s3compat path which still works
		{"http (non-tls) AWS — rare but legal", "http://s3.us-east-2.amazonaws.com", true},

		// Other AWS services — must return false
		{"lambda endpoint", "https://lambda.us-east-1.amazonaws.com", false},
		{"ec2 endpoint", "https://ec2.us-east-1.amazonaws.com", false},
		{"sts endpoint", "https://sts.amazonaws.com", false},

		// Third-party / S3-compatible — must return false
		{"MinIO by IP", "http://10.0.0.5:9000", false},
		{"MinIO with cluster.local host", "http://minio.minio-system.svc.cluster.local:9000", false},
		{"SeaweedFS", "http://seaweed.example.com:8333", false},
		{"Wasabi", "https://s3.wasabisys.com", false},
		{"DigitalOcean Spaces", "https://nyc3.digitaloceanspaces.com", false},

		// Edge cases — must return false (caller treats empty endpoint as AWS separately)
		{"empty string", "", false},
		{"only scheme, no host", "https://", false},
		{"malformed url", "not a url", false},
		{"no scheme just host", "s3.us-east-2.amazonaws.com", false}, // url.Parse keeps this in Path, not Host
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isAWSRegionalEndpoint(tt.endpoint)
			assert.Equal(t, tt.want, got, "isAWSRegionalEndpoint(%q)", tt.endpoint)
		})
	}
}
