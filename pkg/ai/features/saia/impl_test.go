package saia

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"strings"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/splunk/splunk-ai-operator/pkg/ai/features/common"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func buildTestScheme(t *testing.T) *runtime.Scheme {
	s := runtime.NewScheme()
	err := aiv1.AddToScheme(s)
	assert.NoError(t, err)
	err = corev1.AddToScheme(s)
	assert.NoError(t, err)
	return s
}

func Test_validateAIService_missingEnv(t *testing.T) {
	os.Unsetenv("RELATED_IMAGE_POST_INSTALL_HOOK")
	recorder := record.NewFakeRecorder(10)

	// Fake client not needed here since it fails early
	r := &SaiaReconciler{
		Recorder: recorder,
		Client:   fake.NewClientBuilder().WithScheme(buildTestScheme(t)).Build(),
	}

	ai := &aiv1.AIService{}
	err := r.validateAIService(context.Background(), ai)
	assert.ErrorContains(t, err, "RELATED_IMAGE_POST_INSTALL_HOOK must be set")
}

func Test_validateAIService_missingPlatformRefAndUrl(t *testing.T) {
	os.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_POST_INSTALL_HOOK")

	recorder := record.NewFakeRecorder(10)
	r := &SaiaReconciler{
		Recorder: recorder,
		Client:   fake.NewClientBuilder().WithScheme(buildTestScheme(t)).Build(),
	}

	ai := &aiv1.AIService{}
	err := r.validateAIService(context.Background(), ai)
	assert.ErrorContains(t, err, "either AIPlatformRef.Name or AIPlatformUrl must be set")
}

func Test_validateAIService_defaults(t *testing.T) {
	os.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_POST_INSTALL_HOOK")

	scheme := buildTestScheme(t)

	// Create a fake AIPlatform that is Ready
	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plat",
			Namespace: "ns",
		},
		Status: aiv1.AIPlatformStatus{
			RayServiceName:      "ray",
			VectorDbServiceName: "vec",
			Conditions: []metav1.Condition{
				{Type: "Ready", Status: metav1.ConditionTrue},
				{Type: "WeaviateDatabaseReady", Status: metav1.ConditionTrue},
			},
		},
	}

	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(plat).
		Build()

	recorder := record.NewFakeRecorder(10)
	r := &SaiaReconciler{
		Recorder: recorder,
		Client:   fakeClient,
		Scheme:   scheme,
	}

	// Patch common checks to always succeed
	common.IsConditionTrue = func(conds []metav1.Condition, typ string) bool { return true }
	common.CheckRayHeadService = func(ctx context.Context, endpoint string) error { return nil }
	common.CheckWeaviateService = func(ctx context.Context, endpoint string) error { return nil }

	ai := &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "ai",
			Namespace: "ns",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformRef: corev1.ObjectReference{Name: "plat", Namespace: "ns"},
			TaskVolume:    aiv1.ObjectStorageSpec{Path: "/data"},
			V2:            aiv1.SAIAv2Config{Image: "saia-v2:latest"},
		},
	}

	// Should succeed and fill defaults
	err := r.validateAIService(context.Background(), ai)
	assert.NoError(t, err)
	assert.Equal(t, int32(1), ai.Spec.Replicas)
	assert.Equal(t, resource.MustParse("2"), ai.Spec.Resources.Requests[corev1.ResourceCPU])
	assert.Equal(t, resource.MustParse("4Gi"), ai.Spec.Resources.Requests[corev1.ResourceMemory])
	assert.Equal(t, resource.MustParse("10Gi"), ai.Spec.Resources.Requests[corev1.ResourceEphemeralStorage])
	assert.Equal(t, resource.MustParse("2"), ai.Spec.Resources.Limits[corev1.ResourceCPU])
	assert.Equal(t, resource.MustParse("4Gi"), ai.Spec.Resources.Limits[corev1.ResourceMemory])
	assert.Equal(t, resource.MustParse("10Gi"), ai.Spec.Resources.Limits[corev1.ResourceEphemeralStorage])
	// AIPlatformUrl is built as "<scheme>://<ray-svc>.<ns>.svc.<cluster-domain>:8000".
	// When AIPlatformScheme is unset, the operator defaults to "http" (see
	// validateAIService). This makes the URL usable directly by httpx/openai
	// clients in SAIA v2 without a second string-concat step.
	assert.Equal(t, "http://ray.ns.svc.cluster.local:8000", ai.Spec.AIPlatformUrl)
	assert.Equal(t, "vec.ns.svc.cluster.local", ai.Spec.VectorDbUrl)
	assert.Equal(t, int32(1), ai.Spec.V2.Replicas)
	assert.Equal(t, int32(1), ai.Spec.V2Worker.Replicas)
}

func Test_getAIPlatform_success(t *testing.T) {
	scheme := buildTestScheme(t)

	plat := &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "plat",
			Namespace: "ns",
		},
	}
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(plat).
		Build()

	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme}

	ref := corev1.ObjectReference{Name: "plat", Namespace: "ns"}

	got, err := r.getAIPlatform(context.Background(), ref)
	assert.NoError(t, err)
	assert.NotNil(t, got)
	assert.Equal(t, "plat", got.Name)
}

func Test_getAIPlatform_error(t *testing.T) {
	scheme := buildTestScheme(t)

	// No AIPlatform created → should return error
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		Build()

	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme}

	ref := corev1.ObjectReference{Name: "plat", Namespace: "ns"}
	got, err := r.getAIPlatform(context.Background(), ref)
	assert.Error(t, err)
	assert.Nil(t, got)
}

func Test_validateAIService_missingV2Image(t *testing.T) {
	os.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "dummy")
	defer os.Unsetenv("RELATED_IMAGE_POST_INSTALL_HOOK")

	r := &SaiaReconciler{
		Recorder: record.NewFakeRecorder(10),
		Client:   fake.NewClientBuilder().WithScheme(buildTestScheme(t)).Build(),
	}

	ai := &aiv1.AIService{
		Spec: aiv1.AIServiceSpec{
			AIPlatformUrl: "http://platform:8000",
			VectorDbUrl:   "weaviate:80",
			TaskVolume:    aiv1.ObjectStorageSpec{Path: "s3://bucket"},
		},
	}
	err := r.validateAIService(context.Background(), ai)
	assert.ErrorContains(t, err, "v2.image must be set")
}

// buildFullTestScheme creates a scheme that includes apps/v1 for Deployment testing.
func buildFullTestScheme(t *testing.T) *runtime.Scheme {
	s := buildTestScheme(t)
	require.NoError(t, appsv1.AddToScheme(s))
	return s
}

// newTestAIService returns a minimal AIService for reconciliation tests.
func newTestAIService() *aiv1.AIService {
	return &aiv1.AIService{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test",
			Namespace: "default",
			UID:       "uid-123",
		},
		Spec: aiv1.AIServiceSpec{
			AIPlatformUrl:      "http://platform:8000",
			VectorDbUrl:        "weaviate.ai-platform.svc.cluster.local",
			Replicas:           1,
			ServiceAccountName: "test-sa",
			TaskVolume: aiv1.ObjectStorageSpec{
				Path:      "s3://test-bucket/saia",
				Endpoint:  "http://seaweedfs:8333",
				SecretRef: "s3-creds",
			},
			V2: aiv1.SAIAv2Config{
				Image:    "saia-v2:latest",
				Replicas: 1,
			},
			V2Worker: aiv1.SAIAWorkerConfig{Replicas: 1},
			Resources: corev1.ResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceCPU:              *mustParseQuantity("2"),
					corev1.ResourceMemory:           *mustParseQuantity("4Gi"),
					corev1.ResourceEphemeralStorage: *mustParseQuantity("10Gi"),
				},
				Limits: corev1.ResourceList{
					corev1.ResourceCPU:              *mustParseQuantity("2"),
					corev1.ResourceMemory:           *mustParseQuantity("4Gi"),
					corev1.ResourceEphemeralStorage: *mustParseQuantity("10Gi"),
				},
			},
		},
	}
}

func mustParseQuantity(s string) *resource.Quantity {
	q := resource.MustParse(s)
	return &q
}

func Test_reconcilePostInstallHook_SetsGRPCEnvForV2DataLoader(t *testing.T) {
	// Regression: the saia-data-loader v2 image (>= v2.0.4-13-g3b677604) uses
	// the Weaviate v4 Python client, which performs a gRPC health check on
	// connect. Its url_compat shim defaults VECTOR_DB_GRPC_HOST to
	// "grpc.{host}" and VECTOR_DB_GRPC_PORT to "443" (Splunk production
	// convention). In k0s airgap, Weaviate exposes gRPC on the same Service at
	// :50051. The operator MUST pass these vars explicitly so the shim's
	// setdefault() calls are no-ops.
	t.Setenv("RELATED_IMAGE_POST_INSTALL_HOOK", "dummy-hook-image:latest")

	scheme := buildFullTestScheme(t)
	require.NoError(t, batchv1.AddToScheme(scheme))
	ai := newTestAIService()
	ai.Spec.VectorDbUrl = "weaviate.ai-platform.svc.cluster.local"

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	// First call creates the Job and returns "waiting" as a sentinel error.
	err := r.reconcilePostInstallHook(context.Background(), ai)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "created Job")

	job := &batchv1.Job{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-vector-db-setup-posthook", Namespace: "default"}, job))

	// BackoffLimit must be 1 to avoid error-pod churn.
	require.NotNil(t, job.Spec.BackoffLimit)
	assert.Equal(t, int32(1), *job.Spec.BackoffLimit)

	// InitContainer must poll Weaviate readiness before the main container runs.
	require.Len(t, job.Spec.Template.Spec.InitContainers, 1)
	initC := job.Spec.Template.Spec.InitContainers[0]
	assert.Equal(t, "wait-for-weaviate", initC.Name)
	assert.Equal(t, "dummy-hook-image:latest", initC.Image)
	require.NotEmpty(t, initC.Command)
	assert.Equal(t, "python3", initC.Command[0])
	assert.Contains(t, initC.Command[2], "weaviate.ai-platform.svc.cluster.local")
	assert.Contains(t, initC.Command[2], "/v1/.well-known/ready")

	// Collect env var names/values.
	envMap := envToMap(job.Spec.Template.Spec.Containers[0].Env)

	assert.Equal(t, "http://weaviate.ai-platform.svc.cluster.local:80", envMap["VECTOR_DB_URL"])
	assert.Equal(t, "weaviate.ai-platform.svc.cluster.local", envMap["VECTOR_DB_HOST"])
	assert.Equal(t, "80", envMap["VECTOR_DB_PORT"])
	// Critical: GRPC host must NOT be "grpc.<host>"; it's the same Service.
	assert.Equal(t, "weaviate.ai-platform.svc.cluster.local", envMap["VECTOR_DB_GRPC_HOST"])
	assert.Equal(t, "50051", envMap["VECTOR_DB_GRPC_PORT"])
	assert.Equal(t, "false", envMap["VECTOR_DB_SECURE"])
	assert.Equal(t, "false", envMap["VECTOR_DB_AUTH_ENABLED"])
	assert.Equal(t, "true", envMap["SPLUNK_AI_ASSISTANT_SERVICE_CMP"])
}

func Test_reconcileSAIAConfigMap_EnablesAuthzForCMPBridging(t *testing.T) {
	// Regression: ENABLE_AUTHZ=true is REQUIRED for the SAIAAuthorizer's
	// CMP interactive-token path to run. That path sets request.state.cmp_splunk_url,
	// which AdminCapabilityAuthorizer needs to bridge a Splunk.interactive bearer
	// into an EC-equivalent token. ENABLE_AUTHZ=false early-returns before the
	// attribute is set, and /admin/* requests then fail with:
	//   403 {"detail":"Admin endpoints require an authenticated EC user token."}
	// Even in airgap CMP mode, ENABLE_AUTHZ must be "true" — there's no value
	// that both skips authorization AND preserves the CMP bridge.
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, cm))

	assert.Equal(t, "true", cm.Data["ENABLE_AUTHZ"],
		"ENABLE_AUTHZ must default to 'true' so CMP interactive-token bridging works on /admin/* routes")
	assert.Equal(t, "true", cm.Data["SPLUNK_AI_ASSISTANT_SERVICE_CMP"],
		"CMP mode flag must be set alongside ENABLE_AUTHZ so the authorizer picks the interactive-token branch")
}

func Test_reconcileSAIAConfigMap_PreservesUserOverride(t *testing.T) {
	// If an operator explicitly disables authz on an existing ConfigMap
	// (e.g. for development/debugging), our reconcile must NOT clobber that
	// value back to the "true" default. The merge logic fills in missing or
	// empty keys only.
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	existing := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-saia-config",
			Namespace: "default",
		},
		Data: map[string]string{"ENABLE_AUTHZ": "false"},
	}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, existing).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, cm))

	assert.Equal(t, "false", cm.Data["ENABLE_AUTHZ"],
		"user-set ENABLE_AUTHZ=false must be preserved across reconciles")
}

func Test_reconcileSAIAConfigMap_TrustedIssuers_DisabledMode(t *testing.T) {
	// splunk.enabled=false (no SplunkCustomResourceRef): SPLUNK_ISSUERS must be
	// populated solely from TrustedIssuers — the in-cluster issuer must NOT appear.
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	ai.Spec.SplunkConfiguration.TrustedIssuers = []string{
		"https://43.203.164.228:8089",
		"https://splunk.example.com:8089",
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, cm))

	assert.Equal(t,
		"https://43.203.164.228:8089,https://splunk.example.com:8089",
		cm.Data["SPLUNK_ISSUERS"],
		"disabled mode: SPLUNK_ISSUERS must be exactly the TrustedIssuers list")
	assert.NotContains(t, cm.Data["SPLUNK_ISSUERS"], "splunk-splunk-standalone",
		"disabled mode: in-cluster issuer must not be auto-included")
}

func Test_reconcileSAIAConfigMap_TrustedIssuers_InternalMode(t *testing.T) {
	// splunk.enabled=true (internal): in-cluster issuer is auto-prepended,
	// TrustedIssuers are appended (supports simultaneous internal + external Splunk).
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	ai.Spec.SplunkConfiguration.SplunkCustomResourceRef.Name = "splunk-standalone"
	ai.Spec.SplunkConfiguration.TrustedIssuers = []string{"https://external.splunk:8089"}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, cm))

	assert.Equal(t,
		"https://splunk-splunk-standalone-standalone-service.default.svc.cluster.local:8089,https://external.splunk:8089",
		cm.Data["SPLUNK_ISSUERS"],
		"internal mode: in-cluster issuer must be prepended, TrustedIssuers appended")
}

func Test_reconcileSAIAConfigMap_TrustedIssuers_InternalModeNoExtra(t *testing.T) {
	// internal mode with no TrustedIssuers: only the in-cluster issuer.
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	ai.Spec.SplunkConfiguration.SplunkCustomResourceRef.Name = "splunk-standalone"

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, cm))

	assert.Equal(t,
		"https://splunk-splunk-standalone-standalone-service.default.svc.cluster.local:8089",
		cm.Data["SPLUNK_ISSUERS"],
		"internal mode with no TrustedIssuers: only the in-cluster issuer")
}

func Test_reconcileSAIAConfigMap_TrustedIssuers_AlwaysRecomputed(t *testing.T) {
	// When TrustedIssuers is set, a subsequent reconcile must update SPLUNK_ISSUERS
	// even if the ConfigMap already exists with a stale value (spec-driven, not fill-if-missing).
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	ai.Spec.SplunkConfiguration.TrustedIssuers = []string{"https://new.splunk:8089"}

	existing := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "test-saia-config", Namespace: "default"},
		Data:       map[string]string{"SPLUNK_ISSUERS": "https://old.splunk:8089"},
	}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, existing).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, cm))

	assert.Equal(t, "https://new.splunk:8089", cm.Data["SPLUNK_ISSUERS"],
		"spec-driven SPLUNK_ISSUERS must be recomputed on every reconcile, not preserved from old value")
}

func Test_reconcileSAIAConfigMap_TrustedIssuers_ClearedWhenSpecEmpty(t *testing.T) {
	// When spec has no SplunkConfiguration (CRRef, Endpoint, TrustedIssuers all empty),
	// SPLUNK_ISSUERS must be cleared to empty string so stale issuers from a previous
	// configuration do not persist in the ConfigMap.
	scheme := buildFullTestScheme(t)
	ai := newTestAIService() // no SplunkConfiguration set

	existing := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "test-saia-config", Namespace: "default"},
		Data:       map[string]string{"SPLUNK_ISSUERS": "https://old-stale.splunk:8089"},
	}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, existing).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, cm))

	assert.Equal(t, "", cm.Data["SPLUNK_ISSUERS"],
		"empty spec: stale SPLUNK_ISSUERS must be cleared to prevent orphaned issuer trust")
}

func Test_reconcileSAIAConfigMap_TrustedIssuers_EndpointMode(t *testing.T) {
	// When splunkConfiguration.endpoint is set (no CRRef), the endpoint itself is used
	// as the JWT issuer — this covers in-cluster installs that set the endpoint directly
	// via the cluster installer rather than via SplunkCustomResourceRef.
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	ai.Spec.SplunkConfiguration.Endpoint = "https://splunk-splunk-standalone-standalone-service:8089"

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, cm))

	assert.Equal(t,
		"https://splunk-splunk-standalone-standalone-service:8089",
		cm.Data["SPLUNK_ISSUERS"],
		"endpoint mode: endpoint must be used as the JWT issuer")
}

func Test_reconcileSAIAv2Deployment(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	err := r.reconcileSAIAv2Deployment(context.Background(), ai)
	require.NoError(t, err)

	dep := &appsv1.Deployment{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-saia-v2-deployment", Namespace: "default"}, dep)
	require.NoError(t, err)

	container := dep.Spec.Template.Spec.Containers[0]
	assert.Equal(t, "saia-v2:latest", container.Image)
	assert.Equal(t, "saia-v2-api", container.Name)

	// v2 API listens on 8000
	assert.Equal(t, int32(8000), container.Ports[0].ContainerPort)
	assert.Equal(t, "/health", container.ReadinessProbe.HTTPGet.Path)
	assert.Equal(t, 8000, container.ReadinessProbe.HTTPGet.Port.IntValue())
	assert.NotNil(t, container.StartupProbe)
	assert.Equal(t, "/health", container.StartupProbe.HTTPGet.Path)
	assert.Equal(t, 8000, container.StartupProbe.HTTPGet.Port.IntValue())
	assert.Equal(t, int32(10), container.StartupProbe.InitialDelaySeconds)
	assert.Equal(t, int32(30), container.StartupProbe.PeriodSeconds)
	assert.Equal(t, int32(10), container.StartupProbe.FailureThreshold,
		"SAIA v2 startup must tolerate slow Weaviate initialization")

	envMap := envToMap(container.Env)
	assert.Equal(t, "http://platform:8000", envMap["PLATFORM_URL"])
	assert.Equal(t, "test-bucket", envMap["S3_BUCKET"])
	assert.Equal(t, "true", envMap["VAULT_TEMPLATE_DISABLED"])
	_, v2APIUsesV1QueueFlag := envMap["S3_QUEUE_ENABLED"]
	assert.False(t, v2APIUsesV1QueueFlag,
		"S3_QUEUE_ENABLED is a v1 producer flag and must not leak into the v2 API")

	// SAIA V2 FieldDescription backend is REQUIRED (worker and API both call
	// FieldDescriptionRepositoryFactory.get() which raises ValueError on empty
	// backend). Per Confluence ERD section 3.8.1.2 decision A.3 we use the
	// S3-compatible backend for AI Tier.
	assert.Equal(t, "s3", envMap["FIELD_DESCRIPTION_BACKEND"])
	assert.Equal(t, "field-descriptions/global-field-descriptions.json",
		envMap["FIELD_DESCRIPTION_S3_KEY"])
	// AWS_ENDPOINT_URL is what the v2 S3StorageAdapter reads (vs v1's
	// S3COMPAT_OBJECT_STORE_ENDPOINT_URL). Only set when the AIService has
	// an explicit endpoint — e.g. for SeaweedFS/MinIO.
	assert.Equal(t, "http://seaweedfs:8333", envMap["AWS_ENDPOINT_URL"])
}

func Test_reconcileSAIADeployment_DurablePersonalizationQueueByStorageScheme(t *testing.T) {
	t.Setenv("RELATED_IMAGE_SAIA_API", "saia-v1:latest")

	testCases := []struct {
		name          string
		path          string
		enableS3Queue bool
	}{
		{name: "AWS S3", path: "s3://bucket/tasks", enableS3Queue: true},
		{name: "generic S3 compatible", path: "s3compat://bucket/tasks", enableS3Queue: true},
		{name: "MinIO", path: "minio://bucket/tasks", enableS3Queue: true},
		{name: "SeaweedFS", path: "seaweedfs://bucket/tasks", enableS3Queue: true},
		{name: "GCS", path: "gs://bucket/tasks", enableS3Queue: false},
		{name: "Azure", path: "azure://container/tasks", enableS3Queue: false},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			scheme := buildFullTestScheme(t)
			ai := newTestAIService()
			ai.Spec.TaskVolume.Path = testCase.path

			fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
			r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

			require.NoError(t, r.reconcileSAIADeployment(context.Background(), ai))

			dep := &appsv1.Deployment{}
			require.NoError(t, fakeClient.Get(context.Background(),
				types.NamespacedName{Name: "test-saia-deployment", Namespace: "default"}, dep))

			require.Len(t, dep.Spec.Template.Spec.Containers, 1)
			envMap := envToMap(dep.Spec.Template.Spec.Containers[0].Env)
			queueValue, queueEnabled := envMap[saiaQueueEnvName]
			assert.Equal(t, testCase.enableS3Queue, queueEnabled,
				"the S3-backed queue flag must follow the task-volume scheme")
			if testCase.enableS3Queue {
				assert.Equal(t, "true", queueValue)
			}
			_, runsWorkerInAPI := envMap["WORKER_MODE"]
			assert.False(t, runsWorkerInAPI,
				"the v1 API must remain API-only; the dedicated v2 worker consumes the shared queue")
			assert.Equal(t, saiaQueueEnvContractVersion,
				dep.Spec.Template.Annotations[saiaQueueEnvContractAnnotation])
		})
	}
}

func Test_reconcileSAIAQueueEnvironmentMigration(t *testing.T) {
	t.Setenv("RELATED_IMAGE_SAIA_API", "saia-v1:latest")

	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	legacyConfig := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: "test-saia-config", Namespace: "default"},
		Data: map[string]string{
			saiaQueueEnvName: "true",
			"CUSTOM_KEY":     "preserved",
		},
	}
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, legacyConfig).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIAConfigMap(context.Background(), ai))
	require.NoError(t, r.reconcileSAIADeployment(context.Background(), ai))
	require.NoError(t, r.reconcileSAIAv2Deployment(context.Background(), ai))
	require.NoError(t, r.reconcileSAIAv2Worker(context.Background(), ai))

	config := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-config", Namespace: "default"}, config))
	assert.NotContains(t, config.Data, saiaQueueEnvName,
		"legacy workload-specific queue flag must be removed from shared EnvFrom configuration")
	assert.Equal(t, "preserved", config.Data["CUSTOM_KEY"],
		"unrelated user-managed ConfigMap values must survive the migration")

	testCases := []struct {
		name       string
		deployment string
		wantQueue  bool
	}{
		{name: "v1 API", deployment: "test-saia-deployment", wantQueue: true},
		{name: "v2 API", deployment: "test-saia-v2-deployment", wantQueue: false},
		{name: "v2 worker", deployment: "test-saia-v2-worker", wantQueue: false},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			deployment := &appsv1.Deployment{}
			require.NoError(t, fakeClient.Get(context.Background(),
				types.NamespacedName{Name: testCase.deployment, Namespace: "default"}, deployment))
			require.Len(t, deployment.Spec.Template.Spec.Containers, 1)
			container := deployment.Spec.Template.Spec.Containers[0]
			require.Len(t, container.EnvFrom, 1)
			require.NotNil(t, container.EnvFrom[0].ConfigMapRef)
			assert.Equal(t, config.Name, container.EnvFrom[0].ConfigMapRef.Name)

			effectiveEnv := effectiveEnvMap(config.Data, container.Env)
			queueValue, hasQueue := effectiveEnv[saiaQueueEnvName]
			assert.Equal(t, testCase.wantQueue, hasQueue)
			if testCase.wantQueue {
				assert.Equal(t, "true", queueValue)
			}
			assert.Equal(t, "preserved", effectiveEnv["CUSTOM_KEY"])
			assert.Equal(t, saiaQueueEnvContractVersion,
				deployment.Spec.Template.Annotations[saiaQueueEnvContractAnnotation],
				"environment-contract annotation must force existing pods to reload the cleaned ConfigMap")
		})
	}
}

func Test_reconcileSAIAv2Worker(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	err := r.reconcileSAIAv2Worker(context.Background(), ai)
	require.NoError(t, err)

	dep := &appsv1.Deployment{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-saia-v2-worker", Namespace: "default"}, dep)
	require.NoError(t, err)

	container := dep.Spec.Template.Spec.Containers[0]
	assert.Equal(t, "saia-v2:latest", container.Image)
	assert.Equal(t, "saia-v2-worker", container.Name)
	assert.Equal(t, []string{"/bin/sh", "-c"}, container.Command)
	assert.Contains(t, container.Args[0], "app.workers.ingestion_worker")

	envMap := envToMap(container.Env)
	_, v2WorkerUsesV1QueueFlag := envMap["S3_QUEUE_ENABLED"]
	assert.False(t, v2WorkerUsesV1QueueFlag,
		"the v2 worker natively consumes the storage queue and must not inherit the v1 flag")
	// RUN_TASKS_DELAY_S controls the v2 worker's poll sleep (saia-v2
	// IngestionWorker.run). The value MUST stay well under the liveness probe
	// threshold (1200s) because the heartbeat file is only refreshed at the top
	// of each iteration. 600s matches saia-v2's helm default.
	assert.Equal(t, "600", envMap["RUN_TASKS_DELAY_S"])
	// Heartbeat path must match saia-v2's default (app/core/config.py).
	assert.Equal(t, "/tmp/ingestion_worker_heartbeat", envMap["WORKER_HEARTBEAT_PATH"])
	assert.Equal(t, "true", envMap["VAULT_TEMPLATE_DISABLED"])

	// SAIA V2 FieldDescription backend is REQUIRED — without this, the worker
	// immediately raises ValueError and enters a restart loop. Ref Confluence
	// ERD 3.8.1.2 + A.3: Option B (S3-compatible object store). These three
	// vars are the minimum to make the worker bootstrap cleanly.
	assert.Equal(t, "s3", envMap["FIELD_DESCRIPTION_BACKEND"])
	assert.Equal(t, "field-descriptions/global-field-descriptions.json",
		envMap["FIELD_DESCRIPTION_S3_KEY"])
	assert.Equal(t, "http://seaweedfs:8333", envMap["AWS_ENDPOINT_URL"])

	// Liveness uses exec (heartbeat file check), not HTTP
	assert.NotNil(t, container.LivenessProbe.Exec)
	assert.Nil(t, container.LivenessProbe.HTTPGet)
	// Probe must use python3 (not coreutils) because the saia-v2 base image lacks date/cat/cut.
	assert.Equal(t, "python3", container.LivenessProbe.Exec.Command[0])
	assert.Contains(t, container.LivenessProbe.Exec.Command[2], "WORKER_HEARTBEAT_PATH")

	// Only metrics port, no HTTP API port
	assert.Len(t, container.Ports, 1)
	assert.Equal(t, int32(8088), container.Ports[0].ContainerPort)
}

func Test_reconcileSAIAv2Workloads_RollWhenSplunkIssuersChange(t *testing.T) {
	testCases := []struct {
		name           string
		deploymentName string
		reconcile      func(*SaiaReconciler, context.Context, *aiv1.AIService) error
	}{
		{
			name:           "v2 API",
			deploymentName: "test-saia-v2-deployment",
			reconcile:      (*SaiaReconciler).reconcileSAIAv2Deployment,
		},
		{
			name:           "v2 worker",
			deploymentName: "test-saia-v2-worker",
			reconcile:      (*SaiaReconciler).reconcileSAIAv2Worker,
		},
	}

	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			scheme := buildFullTestScheme(t)
			ai := newTestAIService()
			ai.Spec.SplunkConfiguration.TrustedIssuers = []string{"https://first.splunk:8089"}

			fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
			r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

			require.NoError(t, testCase.reconcile(r, context.Background(), ai))

			deployment := &appsv1.Deployment{}
			deploymentKey := types.NamespacedName{Name: testCase.deploymentName, Namespace: ai.Namespace}
			require.NoError(t, fakeClient.Get(context.Background(), deploymentKey, deployment))

			initialHash := fmt.Sprintf("%x", sha256.Sum256([]byte(buildSplunkIssuersVal(ai))))
			assert.Equal(t, initialHash,
				deployment.Spec.Template.Annotations[splunkIssuersHashAnnotation],
				"initial pod template must snapshot the configured SPLUNK_ISSUERS")

			ai.Spec.SplunkConfiguration.TrustedIssuers = []string{"https://second.splunk:8089"}
			require.NoError(t, testCase.reconcile(r, context.Background(), ai))
			require.NoError(t, fakeClient.Get(context.Background(), deploymentKey, deployment))

			updatedHash := fmt.Sprintf("%x", sha256.Sum256([]byte(buildSplunkIssuersVal(ai))))
			assert.NotEqual(t, initialHash, updatedHash)
			assert.Equal(t, updatedHash,
				deployment.Spec.Template.Annotations[splunkIssuersHashAnnotation],
				"issuer changes must alter the pod template and trigger a rollout")
		})
	}
}

func Test_reconcileSAIAv2Deployments_EmbeddingModelGuard(t *testing.T) {
	tests := []struct {
		name          string
		configMapData map[string]string
		want          string
	}{
		{
			name: "missing config map defaults to UAE",
			want: defaultV2EmbeddingModel,
		},
		{
			name:          "empty value defaults to UAE",
			configMapData: map[string]string{"EMBEDDING_MODEL": ""},
			want:          defaultV2EmbeddingModel,
		},
		{
			name:          "bi encoder defaults to UAE",
			configMapData: map[string]string{"EMBEDDING_MODEL": "bi_encoder"},
			want:          defaultV2EmbeddingModel,
		},
		{
			name:          "bi encoder comparison ignores case and whitespace",
			configMapData: map[string]string{"EMBEDDING_MODEL": "  BI_EnCoDeR  "},
			want:          defaultV2EmbeddingModel,
		},
		{
			name:          "other configured model is preserved",
			configMapData: map[string]string{"EMBEDDING_MODEL": "  custom_encoder  "},
			want:          "  custom_encoder  ",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			scheme := buildFullTestScheme(t)
			ai := newTestAIService()
			builder := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai)
			if tt.configMapData != nil {
				builder = builder.WithObjects(&corev1.ConfigMap{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "test-saia-config",
						Namespace: "default",
					},
					Data: tt.configMapData,
				})
			}

			fakeClient := builder.Build()
			r := &SaiaReconciler{
				Client:   fakeClient,
				Scheme:   scheme,
				Recorder: record.NewFakeRecorder(10),
			}

			require.NoError(t, r.reconcileSAIAv2Deployment(context.Background(), ai))
			require.NoError(t, r.reconcileSAIAv2Worker(context.Background(), ai))

			for _, deploymentName := range []string{
				"test-saia-v2-deployment",
				"test-saia-v2-worker",
			} {
				dep := &appsv1.Deployment{}
				require.NoError(t, fakeClient.Get(context.Background(), types.NamespacedName{
					Name:      deploymentName,
					Namespace: "default",
				}, dep))

				require.Len(t, dep.Spec.Template.Spec.Containers, 1)
				container := dep.Spec.Template.Spec.Containers[0]
				assert.Equal(t, tt.want, envToMap(container.Env)["EMBEDDING_MODEL"],
					"%s must set EMBEDDING_MODEL explicitly", deploymentName)
				require.Len(t, container.EnvFrom, 1)
				require.NotNil(t, container.EnvFrom[0].ConfigMapRef)
				assert.Equal(t, "test-saia-config", container.EnvFrom[0].ConfigMapRef.Name,
					"the explicit env must override the shared ConfigMap imported through envFrom")
			}

			if tt.configMapData != nil {
				cm := &corev1.ConfigMap{}
				require.NoError(t, fakeClient.Get(context.Background(), types.NamespacedName{
					Name:      "test-saia-config",
					Namespace: "default",
				}, cm))
				assert.Equal(t, tt.configMapData, cm.Data,
					"the v2 guard must not rewrite the shared ConfigMap used by SAIA v1")
			}
		})
	}
}

func Test_reconcileSAIAv2Deployments_EmbeddingModelConfigMapLookupError(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	fakeClient := fake.NewClientBuilder().
		WithScheme(scheme).
		WithObjects(ai).
		WithInterceptorFuncs(interceptor.Funcs{
			Get: func(ctx context.Context, intercepted client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
				if key.Name == "test-saia-config" {
					if _, isConfigMap := obj.(*corev1.ConfigMap); isConfigMap {
						return fmt.Errorf("injected ConfigMap read failure")
					}
				}
				return intercepted.Get(ctx, key, obj, opts...)
			},
		}).
		Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	for _, reconcile := range []struct {
		name string
		fn   func(context.Context, *aiv1.AIService) error
	}{
		{name: "v2 API", fn: r.reconcileSAIAv2Deployment},
		{name: "v2 worker", fn: r.reconcileSAIAv2Worker},
	} {
		t.Run(reconcile.name, func(t *testing.T) {
			err := reconcile.fn(context.Background(), ai)
			require.ErrorContains(t, err, "fetching SAIA ConfigMap for v2 embedding model")
			require.ErrorContains(t, err, "injected ConfigMap read failure")
		})
	}
}

func Test_reconcileSAIADeployment_DoesNotInjectV2EmbeddingModelGuard(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-saia-config",
			Namespace: "default",
		},
		Data: map[string]string{"EMBEDDING_MODEL": "bi_encoder"},
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai, configMap).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileSAIADeployment(context.Background(), ai))

	dep := &appsv1.Deployment{}
	require.NoError(t, fakeClient.Get(context.Background(), types.NamespacedName{
		Name:      "test-saia-deployment",
		Namespace: "default",
	}, dep))

	require.Len(t, dep.Spec.Template.Spec.Containers, 1)
	container := dep.Spec.Template.Spec.Containers[0]
	_, hasExplicitEmbeddingModel := envToMap(container.Env)["EMBEDDING_MODEL"]
	assert.False(t, hasExplicitEmbeddingModel,
		"the operator-only v2 guard must not change SAIA v1's explicit environment")
	require.Len(t, container.EnvFrom, 1)
	require.NotNil(t, container.EnvFrom[0].ConfigMapRef)
	assert.Equal(t, "test-saia-config", container.EnvFrom[0].ConfigMapRef.Name)
}

func Test_reconcileNginxConfigMap(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	err := r.reconcileNginxConfigMap(context.Background(), ai)
	require.NoError(t, err)

	cm := &corev1.ConfigMap{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-saia-nginx-config", Namespace: "default"}, cm)
	require.NoError(t, err)

	conf := cm.Data["nginx.conf"]
	assert.NotEmpty(t, conf)

	// v2 routing: ANY path containing "/saia-api-v2/" — with or without a
	// tenant prefix — must be sent to the v2 upstream. The regex must NOT
	// require a path segment before "saia-api-v2" (that would silently route
	// tenant-less probes to v1).
	assert.Contains(t, conf, "location ~ /saia-api-v2/")
	assert.Contains(t, conf, "proxy_pass http://saia_v2")

	// v1 is the default
	assert.Contains(t, conf, "location /")
	assert.Contains(t, conf, "proxy_pass http://saia_v1")

	// Upstream names reference the correct internal service names
	assert.Contains(t, conf, "test-saia-v1-service:8080")
	assert.Contains(t, conf, "test-saia-v2-service:8000")

	// SSE/streaming friendliness
	assert.Contains(t, conf, "proxy_buffering off")
	assert.Contains(t, conf, "proxy_http_version 1.1")

	// Personalization bundles can exceed nginx's 1 MiB default (dashboard
	// metadata was observed at ~6.7 MiB). Keep the production limit bounded.
	assert.Equal(t, 1, strings.Count(conf, "client_max_body_size 100m;"))
	v2LocationStart := strings.Index(conf, "location ~ /saia-api-v2/")
	v1LocationStart := strings.Index(conf, "location / {")
	require.Greater(t, v2LocationStart, -1)
	require.Greater(t, v1LocationStart, v2LocationStart)
	assert.NotContains(t, conf[v2LocationStart:v1LocationStart], "client_max_body_size",
		"the raised request-body limit must not widen v2 routes")
	assert.Contains(t, conf[v1LocationStart:], "client_max_body_size 100m;",
		"the raised request-body limit must apply to v1 personalization uploads")

	// Health and status endpoints — stub_status must be loopback-only.
	assert.Contains(t, conf, "location = /nginx_health")
	assert.Contains(t, conf, "location = /nginx_status")
	assert.Contains(t, conf, "deny all;")
}

func Test_reconcileNginxConfigMap_CORSPreflight(t *testing.T) {
	// Regression: saia-v2's TenantConversationKeyMiddleware rejects
	// unauthenticated CORS preflight OPTIONS requests with 400 before
	// FastAPI's CORSMiddleware can respond, causing browsers to block the
	// subsequent real request with "No Access-Control-Allow-Origin header
	// present". The nginx reverse proxy MUST short-circuit OPTIONS at the
	// proxy layer and respond with permissive CORS headers so the browser
	// accepts the preflight. See:
	//   saia-service/saia-v2/app/middleware/tenant_conversation_key.py
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileNginxConfigMap(context.Background(), ai))

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-nginx-config", Namespace: "default"}, cm))

	conf := cm.Data["nginx.conf"]

	// OPTIONS short-circuit must be present on BOTH v1 (/) and v2
	// (/saia-api-v2/) locations. Without it, v1 admin routes (Pattern B
	// direct browser fetch) would also fail the same way.
	assert.Equal(t, 2, strings.Count(conf, "if ($request_method = OPTIONS)"),
		"OPTIONS short-circuit must exist in both v1 and v2 location blocks")
	assert.Contains(t, conf, "return 204",
		"preflight must return 204 No Content")

	// 'map' directive dynamically reflects Access-Control-Request-Headers
	// so any custom header the client sends is auto-allowed (avoids drift
	// between nginx allowlist and client's evolving header set).
	assert.Contains(t, conf, "map $http_access_control_request_headers $cors_allow_headers",
		"must use 'map' to reflect Access-Control-Request-Headers back to client")
	assert.Contains(t, conf, "add_header Access-Control-Allow-Headers $cors_allow_headers",
		"preflight response must echo the requested headers via $cors_allow_headers")

	// ACAO must be reflected from Origin (not a hardcoded wildcard) so that
	// Access-Control-Allow-Credentials=true is valid (browsers reject
	// Allow-Origin="*" + Allow-Credentials=true).
	assert.Contains(t, conf, "add_header Access-Control-Allow-Origin $http_origin",
		"preflight ACAO must be reflected from Origin to support Allow-Credentials=true")

	// CRITICAL: ACAO must ONLY appear in OPTIONS branches. FastAPI's
	// CORSMiddleware already sets ACAO on real responses; adding it again
	// from nginx produces duplicate "*, http://origin" values that browsers
	// reject ("The 'Access-Control-Allow-Origin' header contains multiple
	// values '*, http://localhost:18000', but only one is allowed").
	assert.Equal(t, 2, strings.Count(conf, "add_header Access-Control-Allow-Origin"),
		"ACAO must appear EXACTLY TWICE (once per OPTIONS branch). Adding it "+
			"on real responses duplicates FastAPI's header and breaks the browser.")
}

func Test_reconcileNginxDeployment(t *testing.T) {
	// Ensure no env override leaks from other tests in the package.
	os.Unsetenv("RELATED_IMAGE_NGINX")

	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileNginxConfigMap(context.Background(), ai))
	err := r.reconcileNginxDeployment(context.Background(), ai)
	require.NoError(t, err)

	dep := &appsv1.Deployment{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-saia-nginx", Namespace: "default"}, dep)
	require.NoError(t, err)

	container := dep.Spec.Template.Spec.Containers[0]
	assert.Equal(t, "nginx:1.27-alpine", container.Image)
	assert.Equal(t, "nginx", container.Name)
	assert.Equal(t, int32(8080), container.Ports[0].ContainerPort)

	// ConfigMap volume mount
	assert.Equal(t, "/etc/nginx/nginx.conf", container.VolumeMounts[0].MountPath)
	assert.Equal(t, "nginx.conf", container.VolumeMounts[0].SubPath)

	// Health probes use nginx_health
	assert.Equal(t, "/nginx_health", container.LivenessProbe.HTTPGet.Path)
	assert.Equal(t, "/nginx_health", container.ReadinessProbe.HTTPGet.Path)

	cm := &corev1.ConfigMap{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-nginx-config", Namespace: "default"}, cm))
	expectedConfigHash := fmt.Sprintf("%x", sha256.Sum256([]byte(cm.Data["nginx.conf"])))
	assert.Equal(t, expectedConfigHash,
		dep.Spec.Template.Annotations["splunk-ai-operator/nginx-config-hash"],
		"subPath-mounted nginx config changes must roll the Deployment")
}

func Test_reconcileNginxDeployment_imageOverride(t *testing.T) {
	os.Setenv("RELATED_IMAGE_NGINX", "private.registry.example.com/nginx:1.29-alpine")
	defer os.Unsetenv("RELATED_IMAGE_NGINX")

	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	ai.Name = "override"

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NoError(t, r.reconcileNginxDeployment(context.Background(), ai))

	dep := &appsv1.Deployment{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "override-saia-nginx", Namespace: "default"}, dep))

	assert.Equal(t, "private.registry.example.com/nginx:1.29-alpine",
		dep.Spec.Template.Spec.Containers[0].Image)
}

func Test_reconcileSAIAService_handlesAnnotationsWithoutPanic(t *testing.T) {
	// Regression: the pre-existing code did not initialize svc.Annotations, so
	// any user-provided annotation on the AIService caused a "assignment to
	// entry in nil map" panic when reconciling the public service.
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	ai.Annotations = map[string]string{
		"operator.splunk.com/example":                      "v1",
		"kubectl.kubernetes.io/restartedAt":                "should-be-skipped",
		"kubectl.kubernetes.io/last-applied-configuration": "should-be-skipped",
		"script-reconcile-ts":                              "should-be-skipped",
	}

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	require.NotPanics(t, func() {
		err := r.reconcileSAIAService(context.Background(), ai)
		require.NoError(t, err)
	})

	svc := &corev1.Service{}
	require.NoError(t, fakeClient.Get(context.Background(),
		types.NamespacedName{Name: "test-saia-service", Namespace: "default"}, svc))

	assert.Equal(t, "v1", svc.Annotations["operator.splunk.com/example"])
	assert.NotContains(t, svc.Annotations, "kubectl.kubernetes.io/restartedAt")
	assert.NotContains(t, svc.Annotations, "kubectl.kubernetes.io/last-applied-configuration")
	assert.NotContains(t, svc.Annotations, "script-reconcile-ts")
}

func Test_reconcileSAIAv1Service(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	err := r.reconcileSAIAv1Service(context.Background(), ai)
	require.NoError(t, err)

	svc := &corev1.Service{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-saia-v1-service", Namespace: "default"}, svc)
	require.NoError(t, err)

	assert.Equal(t, map[string]string{"app": "test", "component": "test"}, svc.Spec.Selector)
	assert.Equal(t, int32(8080), svc.Spec.Ports[0].Port)
}

func Test_reconcileSAIAv2Service(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	err := r.reconcileSAIAv2Service(context.Background(), ai)
	require.NoError(t, err)

	svc := &corev1.Service{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-saia-v2-service", Namespace: "default"}, svc)
	require.NoError(t, err)

	assert.Equal(t, map[string]string{"app": "test", "component": "test-v2-api"}, svc.Spec.Selector)
	assert.Equal(t, int32(8000), svc.Spec.Ports[0].Port)
}

func Test_reconcileSAIAService_pointsToNginx(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()

	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

	err := r.reconcileSAIAService(context.Background(), ai)
	require.NoError(t, err)

	svc := &corev1.Service{}
	err = fakeClient.Get(context.Background(), types.NamespacedName{Name: "test-saia-service", Namespace: "default"}, svc)
	require.NoError(t, err)

	// Public service must target nginx, not v1 directly
	assert.Equal(t, map[string]string{"app": "test", "component": "test-nginx"}, svc.Spec.Selector)
	assert.Equal(t, int32(8080), svc.Spec.Ports[0].Port)
}

func Test_reconcileSAIAService_ServiceTypeVariations(t *testing.T) {
	// Lock in the contract that the customer's k0s-cluster-config.yaml can
	// omit / empty / explicitly-set serviceTemplate and get the expected
	// Service.Type. Without this test, a future refactor could silently break
	// the "just omit the block = ClusterIP" escape hatch documented in
	// tools/cluster_setup/k0s-cluster-config.yaml.
	scheme := buildFullTestScheme(t)

	cases := []struct {
		name         string
		template     corev1.Service
		wantType     corev1.ServiceType
		wantNodePort int32 // 0 = don't check
	}{
		{
			name:     "omitted/empty template → ClusterIP",
			template: corev1.Service{}, // zero value, what yq-absent produces
			wantType: corev1.ServiceTypeClusterIP,
		},
		{
			name: "explicit ClusterIP → ClusterIP",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeClusterIP},
			},
			wantType: corev1.ServiceTypeClusterIP,
		},
		{
			name: "NodePort without explicit port → NodePort auto-allocated",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeNodePort},
			},
			wantType: corev1.ServiceTypeNodePort,
			// wantNodePort == 0 means we don't assert a specific value
		},
		{
			name: "NodePort with explicit 30080 → NodePort 30080",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{
					Type: corev1.ServiceTypeNodePort,
					Ports: []corev1.ServicePort{
						{Name: "http", NodePort: 30080},
					},
				},
			},
			wantType:     corev1.ServiceTypeNodePort,
			wantNodePort: 30080,
		},
		{
			name: "LoadBalancer → LoadBalancer",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeLoadBalancer},
			},
			wantType: corev1.ServiceTypeLoadBalancer,
		},
		{
			name: "Unknown garbage type → ClusterIP (safe default)",
			template: corev1.Service{
				Spec: corev1.ServiceSpec{Type: corev1.ServiceType("Bogus")},
			},
			wantType: corev1.ServiceTypeClusterIP,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			ai := newTestAIService()
			ai.Name = "svctype-" + sanitize(tc.name)
			ai.Spec.ServiceTemplate = tc.template

			fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
			r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}

			require.NoError(t, r.reconcileSAIAService(context.Background(), ai))

			svc := &corev1.Service{}
			require.NoError(t, fakeClient.Get(context.Background(),
				types.NamespacedName{Name: ai.Name + "-saia-service", Namespace: "default"}, svc))

			assert.Equal(t, tc.wantType, svc.Spec.Type)
			if tc.wantNodePort != 0 {
				require.NotEmpty(t, svc.Spec.Ports)
				assert.Equal(t, tc.wantNodePort, svc.Spec.Ports[0].NodePort)
			}
		})
	}
}

func Test_reconcileSAIAService_UpdatesExistingServiceType(t *testing.T) {
	scheme := buildFullTestScheme(t)
	ai := newTestAIService()
	fakeClient := fake.NewClientBuilder().WithScheme(scheme).WithObjects(ai).Build()
	r := &SaiaReconciler{Client: fakeClient, Scheme: scheme, Recorder: record.NewFakeRecorder(10)}
	key := types.NamespacedName{Name: ai.Name + "-saia-service", Namespace: ai.Namespace}

	require.NoError(t, r.reconcileSAIAService(context.Background(), ai))

	ai.Spec.ServiceTemplate = corev1.Service{Spec: corev1.ServiceSpec{
		Type:  corev1.ServiceTypeNodePort,
		Ports: []corev1.ServicePort{{Name: "http", NodePort: 30080}},
	}}
	require.NoError(t, r.reconcileSAIAService(context.Background(), ai))
	svc := &corev1.Service{}
	require.NoError(t, fakeClient.Get(context.Background(), key, svc))
	assert.Equal(t, corev1.ServiceTypeNodePort, svc.Spec.Type)
	assert.Equal(t, int32(30080), svc.Spec.Ports[0].NodePort)

	ai.Spec.ServiceTemplate = corev1.Service{Spec: corev1.ServiceSpec{Type: corev1.ServiceTypeClusterIP}}
	require.NoError(t, r.reconcileSAIAService(context.Background(), ai))
	require.NoError(t, fakeClient.Get(context.Background(), key, svc))
	assert.Equal(t, corev1.ServiceTypeClusterIP, svc.Spec.Type)
	assert.Zero(t, svc.Spec.Ports[0].NodePort)
}

// sanitize turns a free-form subtest name into a valid k8s resource name.
func sanitize(s string) string {
	s = strings.ToLower(s)
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			out = append(out, c)
		default:
			if len(out) > 0 && out[len(out)-1] != '-' {
				out = append(out, '-')
			}
		}
	}
	// Trim trailing hyphen
	for len(out) > 0 && out[len(out)-1] == '-' {
		out = out[:len(out)-1]
	}
	return string(out)
}

func Test_buildV2ExtraEnv_FieldDescriptionBackend(t *testing.T) {
	t.Run("with S3-compatible endpoint", func(t *testing.T) {
		ai := newTestAIService() // already sets TaskVolume.Endpoint = "http://seaweedfs:8333"
		envMap := envToMap(buildV2ExtraEnv(ai))
		baseMap := envToMap(buildSAIABaseEnv(ai))

		assert.Equal(t, "s3", envMap["FIELD_DESCRIPTION_BACKEND"])
		assert.Equal(t, "field-descriptions/global-field-descriptions.json",
			envMap["FIELD_DESCRIPTION_S3_KEY"])
		assert.Equal(t, "http://seaweedfs:8333", baseMap["AWS_ENDPOINT_URL"])
	})

	t.Run("without S3-compatible endpoint", func(t *testing.T) {
		ai := newTestAIService()
		ai.Spec.TaskVolume.Endpoint = ""
		envMap := envToMap(buildV2ExtraEnv(ai))

		assert.Equal(t, "s3", envMap["FIELD_DESCRIPTION_BACKEND"])
		assert.Equal(t, "field-descriptions/global-field-descriptions.json",
			envMap["FIELD_DESCRIPTION_S3_KEY"])
	})
}

// Test_buildV2ExtraEnv_ConversationStore verifies the switch from the
// ephemeral "filesystem" default (which lives on the pod's container overlay
// and loses all chat history on restart) to the "s3" backend introduced in
// saia-service by Tony's commits 3d3756f3 / 8e2a9f40 (merged into
// ai-tier-v2.0 via 9efe1fce on 2026-04-20, shipped in image build-v2-002).
//
// Contract (from saia-v2/app/core/config.py::Settings and
// app/repositories/conversation/store_factory.py):
//   - CONVERSATION_STORE=s3 selects S3ConversationStore
//   - CONVERSATION_S3_BUCKET must be non-empty (validator raises
//     ValueError at startup otherwise, crash-looping the v2 pod)
//   - AWS_ENDPOINT_URL / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are
//     reused from the FieldDescription S3 wiring below
func Test_buildV2ExtraEnv_ConversationStore(t *testing.T) {
	t.Run("enables s3 backend with bucket extracted from TaskVolume.Path", func(t *testing.T) {
		ai := newTestAIService() // TaskVolume.Path = "s3://test-bucket/saia"
		envMap := envToMap(buildV2ExtraEnv(ai))

		assert.Equal(t, "s3", envMap["CONVERSATION_STORE"],
			"CONVERSATION_STORE must be 's3' so S3ConversationStore is selected over the ephemeral filesystem default")
		assert.Equal(t, "test-bucket", envMap["CONVERSATION_S3_BUCKET"],
			"CONVERSATION_S3_BUCKET must be the extracted bucket name so SAIA v2's Settings validator passes at startup")
	})

	t.Run("handles all supported TaskVolume.Path prefixes", func(t *testing.T) {
		cases := []struct {
			path       string
			wantBucket string
		}{
			{"s3://my-bucket/path", "my-bucket"},
			{"s3compat://bucket-name", "bucket-name"},
			{"minio://minio-bucket", "minio-bucket"},
			{"seaweedfs://sw-bucket/prefix", "sw-bucket"},
			{"gs://gcs-bucket", "gcs-bucket"},
		}
		for _, tc := range cases {
			t.Run(tc.path, func(t *testing.T) {
				ai := newTestAIService()
				ai.Spec.TaskVolume.Path = tc.path
				envMap := envToMap(buildV2ExtraEnv(ai))

				assert.Equal(t, "s3", envMap["CONVERSATION_STORE"])
				assert.Equal(t, tc.wantBucket, envMap["CONVERSATION_S3_BUCKET"])
			})
		}
	})

	// An empty TaskVolume.Path indicates a misconfigured CR. We must NOT
	// emit CONVERSATION_STORE=s3 in that case, because CONVERSATION_S3_BUCKET
	// would be empty and the v2 pod would crash-loop on the Pydantic
	// validator. Leaving the defaults in place gives a clearer failure mode
	// (ephemeral filesystem store) than a startup crash.
	t.Run("omits conversation-store envs when TaskVolume.Path is empty", func(t *testing.T) {
		ai := newTestAIService()
		ai.Spec.TaskVolume.Path = ""
		envMap := envToMap(buildV2ExtraEnv(ai))

		_, hasStore := envMap["CONVERSATION_STORE"]
		_, hasBucket := envMap["CONVERSATION_S3_BUCKET"]
		assert.False(t, hasStore,
			"CONVERSATION_STORE must be omitted when no bucket can be derived, to avoid the SAIA v2 startup validator crashing the pod")
		assert.False(t, hasBucket,
			"CONVERSATION_S3_BUCKET must be omitted when no bucket can be derived")
	})
}

func Test_buildSAIABaseEnv(t *testing.T) {
	ai := newTestAIService()
	env := buildSAIABaseEnv(ai)
	envMap := envToMap(env)

	assert.Equal(t, "http://platform:8000", envMap["PLATFORM_URL"])
	assert.Equal(t, "http://weaviate.ai-platform.svc.cluster.local:80", envMap["WEAVIATE_PLATFORM_URL"])
	assert.Equal(t, "weaviate.ai-platform.svc.cluster.local", envMap["VECTOR_DB_URL"])
	assert.Equal(t, "test-bucket", envMap["S3_BUCKET"])
	assert.Equal(t, "http://seaweedfs:8333", envMap["S3COMPAT_OBJECT_STORE_ENDPOINT_URL"])
	assert.Equal(t, "test-bucket", envMap["S3COMPAT_OBJECT_STORE_BUCKET"])
	assert.Equal(t, "http://seaweedfs:8333", envMap["AWS_ENDPOINT_URL"])

	// S3 creds come from secretRef
	found := false
	for _, e := range env {
		if e.Name == "S3COMPAT_OBJECT_STORE_ACCESS_KEY" {
			found = true
			assert.Equal(t, "s3-creds", e.ValueFrom.SecretKeyRef.Name)
			assert.Equal(t, "s3_access_key", e.ValueFrom.SecretKeyRef.Key)
		}
	}
	assert.True(t, found, "S3COMPAT_OBJECT_STORE_ACCESS_KEY should be present")

	t.Run("AWS credentials sourced from SecretRef", func(t *testing.T) {
		var foundID, foundSecret bool
		for _, e := range env {
			if e.Name == "AWS_ACCESS_KEY_ID" {
				foundID = true
				if assert.NotNil(t, e.ValueFrom) && assert.NotNil(t, e.ValueFrom.SecretKeyRef) {
					assert.Equal(t, "s3-creds", e.ValueFrom.SecretKeyRef.Name)
					assert.Equal(t, "s3_access_key", e.ValueFrom.SecretKeyRef.Key)
				}
			}
			if e.Name == "AWS_SECRET_ACCESS_KEY" {
				foundSecret = true
				if assert.NotNil(t, e.ValueFrom) && assert.NotNil(t, e.ValueFrom.SecretKeyRef) {
					assert.Equal(t, "s3-creds", e.ValueFrom.SecretKeyRef.Name)
					assert.Equal(t, "s3_secret_key", e.ValueFrom.SecretKeyRef.Key)
				}
			}
		}
		assert.True(t, foundID, "AWS_ACCESS_KEY_ID must be present for boto3 (v1 and v2)")
		assert.True(t, foundSecret, "AWS_SECRET_ACCESS_KEY must be present for boto3 (v1 and v2)")
	})

	t.Run("AWS region from TaskVolume.Region", func(t *testing.T) {
		ai := newTestAIService()
		ai.Spec.TaskVolume.Region = "ap-southeast-2"
		envMap := envToMap(buildSAIABaseEnv(ai))
		assert.Equal(t, "ap-southeast-2", envMap["AWS_REGION"])
		assert.Equal(t, "ap-southeast-2", envMap["AWS_DEFAULT_REGION"])
	})

	t.Run("without S3-compatible endpoint", func(t *testing.T) {
		ai := newTestAIService()
		ai.Spec.TaskVolume.Endpoint = ""
		envMap := envToMap(buildSAIABaseEnv(ai))
		_, has := envMap["AWS_ENDPOINT_URL"]
		assert.False(t, has,
			"AWS_ENDPOINT_URL must be omitted when TaskVolume.Endpoint is empty (cloud S3 case)")
	})

	t.Run("AWS credentials omitted when SecretRef empty", func(t *testing.T) {
		ai := newTestAIService()
		ai.Spec.TaskVolume.SecretRef = ""
		for _, e := range buildSAIABaseEnv(ai) {
			assert.NotEqual(t, "AWS_ACCESS_KEY_ID", e.Name)
			assert.NotEqual(t, "AWS_SECRET_ACCESS_KEY", e.Name)
		}
	})
}

func Test_extractBucketName(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"s3://my-bucket/path", "my-bucket"},
		{"s3compat://bucket-name", "bucket-name"},
		{"minio://bucket-name", "bucket-name"},
		{"seaweedfs://my-bucket/prefix", "my-bucket"},
		{"gs://my-bucket", "my-bucket"},
		{"plain-bucket", "plain-bucket"},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			assert.Equal(t, tt.want, extractBucketName(tt.input))
		})
	}
}

// envToMap converts a slice of EnvVar to a map for easy assertion.
// Only includes env vars with direct values (not ValueFrom).
func envToMap(envs []corev1.EnvVar) map[string]string {
	m := make(map[string]string)
	for _, e := range envs {
		if e.ValueFrom == nil {
			m[e.Name] = e.Value
		}
	}
	return m
}

// effectiveEnvMap applies Kubernetes' EnvFrom-before-Env precedence for the
// direct-value variables used by these tests.
func effectiveEnvMap(configMapData map[string]string, envs []corev1.EnvVar) map[string]string {
	effective := make(map[string]string, len(configMapData)+len(envs))
	for name, value := range configMapData {
		effective[name] = value
	}
	for name, value := range envToMap(envs) {
		effective[name] = value
	}
	return effective
}

// Suppress unused import warnings
var _ = fmt.Sprintf
var _ = strings.Contains
