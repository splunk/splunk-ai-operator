package raybuilder

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// writeScaleFixtures lays out model-scale.yaml / worker-scale.yaml under a
// fresh working directory and returns that directory. Sizing now reads these
// two global files (not per-feature files).
func writeScaleFixtures(t *testing.T, modelScale, workerScale string) string {
	t.Helper()
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "model-scale.yaml"), []byte(modelScale), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "worker-scale.yaml"), []byte(workerScale), 0o644))
	return dir
}

const modelScaleFixture = `
applicationScale:
  ModelA: 1
  ModelB: 2
`

const workerScaleFixture = `
instanceScale:
  L40S:
    l40s-1-gpu: 2
`

func int32PtrForTest(v int32) *int32 { return &v }

func newScaleFactorTestPlatform(scaleFactor *int32) *aiv1.AIPlatform {
	return &aiv1.AIPlatform{
		ObjectMeta: metav1.ObjectMeta{Name: "test-platform", Namespace: "default"},
		Spec: aiv1.AIPlatformSpec{
			ServiceAccountName: "test-sa",
			ObjectStorage: aiv1.ObjectStorageSpec{
				Path:   "s3://test-bucket/artifacts",
				Region: "us-west-2",
			},
			SplunkConfiguration: aiv1.SplunkConfigurationSpec{Endpoint: "https://splunk.example.com:8089"},
			CPUSchedulingSpec:   &aiv1.SchedulingSpec{NodeSelector: map[string]string{}, Tolerations: []corev1.Toleration{}},
			GPUSchedulingSpec:   &aiv1.SchedulingSpec{NodeSelector: map[string]string{}, Tolerations: []corev1.Toleration{}},
			WorkerGroupConfig:   &aiv1.WorkerGroupConfig{ServiceAccountName: "worker-sa"},
			Images: aiv1.Images{
				RayHeadGroupImage:   "ray-head:latest",
				RayWorkerGroupImage: "ray-worker:latest",
			},
			ScaleFactor: scaleFactor,
		},
	}
}

// TestReconcileRayService_GlobalScaleFactor asserts the rendered Serve config
// carries each model's base replica count multiplied by the platform-wide
// spec.scaleFactor (not per-feature, not summed across features).
func TestReconcileRayService_GlobalScaleFactor(t *testing.T) {
	os.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")

	// Resolve before t.Chdir, since it's relative to this package's directory.
	instanceFile, err := filepath.Abs("../../../config/configs/instance.yaml")
	require.NoError(t, err)

	dir := writeScaleFixtures(t, modelScaleFixture, workerScaleFixture)
	t.Chdir(dir)

	applicationFile := filepath.Join(dir, "applications.yaml")
	require.NoError(t, os.WriteFile(applicationFile,
		[]byte("modelA_replicas: {{.Replicas.ModelA}}\nmodelB_replicas: {{.Replicas.ModelB}}\n"), 0o644))
	os.Setenv("APPLICATION_FILE", applicationFile)
	os.Setenv("INSTANCE_FILE", instanceFile)
	os.Setenv("MODEL_SCALE_FILE", filepath.Join(dir, "model-scale.yaml"))
	os.Setenv("WORKER_SCALE_FILE", filepath.Join(dir, "worker-scale.yaml"))

	s := scheme.Scheme
	_ = aiv1.AddToScheme(s)
	_ = rayv1.AddToScheme(s)
	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()
	recorder := record.NewFakeRecorder(100)

	platform := newScaleFactorTestPlatform(int32PtrForTest(3))

	ctx := context.Background()
	builder := New(platform, fakeClient, s, recorder)
	require.NoError(t, builder.ReconcileRayService(ctx, platform))

	var cm corev1.ConfigMap
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Namespace: "default", Name: "test-platform-serve-config"}, &cm))
	rendered := cm.Data["serve-config.yaml"]

	// ModelA base 1 * scaleFactor 3 => 3; ModelB base 2 * 3 => 6.
	require.Contains(t, rendered, "modelA_replicas: 3")
	require.Contains(t, rendered, "modelB_replicas: 6")
}

// TestBuildClusterConfig_GlobalScaleFactor asserts each GPU worker tier's
// base pod count is multiplied by the platform-wide spec.scaleFactor.
func TestBuildClusterConfig_GlobalScaleFactor(t *testing.T) {
	os.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")

	// Resolve before t.Chdir, since it's relative to this package's directory.
	instanceFile, err := filepath.Abs("../../../config/configs/instance.yaml")
	require.NoError(t, err)

	dir := writeScaleFixtures(t, modelScaleFixture, workerScaleFixture)
	t.Chdir(dir)
	os.Setenv("INSTANCE_FILE", instanceFile)
	os.Setenv("WORKER_SCALE_FILE", filepath.Join(dir, "worker-scale.yaml"))

	s := scheme.Scheme
	_ = aiv1.AddToScheme(s)
	_ = rayv1.AddToScheme(s)
	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()
	recorder := record.NewFakeRecorder(100)

	// l40s-1-gpu base 2 * scaleFactor 3 => 6.
	platform := newScaleFactorTestPlatform(int32PtrForTest(3))

	ctx := context.Background()
	builder := New(platform, fakeClient, s, recorder)
	spec, err := builder.buildClusterConfig(ctx)
	require.NoError(t, err)

	found := false
	for _, wg := range spec.WorkerGroupSpecs {
		if wg.GroupName == "l40s-1-gpu" {
			found = true
			require.Equal(t, int32(6), *wg.Replicas)
			require.Equal(t, int32(6), *wg.MinReplicas)
			require.Equal(t, int32(6), *wg.MaxReplicas)
		}
	}
	require.True(t, found, "expected l40s-1-gpu worker group to be present")
}

// TestBuildClusterConfig_ZeroScaleFactor asserts that spec.scaleFactor = 0
// scales every GPU worker tier to zero pods (pause the platform).
func TestBuildClusterConfig_ZeroScaleFactor(t *testing.T) {
	os.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")

	// Resolve before t.Chdir, since it's relative to this package's directory.
	instanceFile, err := filepath.Abs("../../../config/configs/instance.yaml")
	require.NoError(t, err)

	dir := writeScaleFixtures(t, modelScaleFixture, workerScaleFixture)
	t.Chdir(dir)
	os.Setenv("INSTANCE_FILE", instanceFile)
	os.Setenv("WORKER_SCALE_FILE", filepath.Join(dir, "worker-scale.yaml"))

	s := scheme.Scheme
	_ = aiv1.AddToScheme(s)
	_ = rayv1.AddToScheme(s)
	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()
	recorder := record.NewFakeRecorder(100)

	// scaleFactor 0 => every tier scales to zero.
	platform := newScaleFactorTestPlatform(int32PtrForTest(0))

	ctx := context.Background()
	builder := New(platform, fakeClient, s, recorder)
	spec, err := builder.buildClusterConfig(ctx)
	require.NoError(t, err)

	for _, wg := range spec.WorkerGroupSpecs {
		require.Equal(t, int32(0), *wg.Replicas, "tier %s replicas", wg.GroupName)
		require.Equal(t, int32(0), *wg.MinReplicas, "tier %s minReplicas", wg.GroupName)
	}
}

// TestScaleFactor_DefaultsToOne_Parity asserts that when spec.scaleFactor is
// unset, replicas and worker counts equal the migrated base values (guarding
// the migration from features/saia.yaml to the two global files).
func TestScaleFactor_DefaultsToOne_Parity(t *testing.T) {
	os.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")

	// Resolve the real config files before t.Chdir.
	instanceFile, err := filepath.Abs("../../../config/configs/instance.yaml")
	require.NoError(t, err)
	modelScaleFile, err := filepath.Abs("../../../config/configs/model-scale.yaml")
	require.NoError(t, err)
	workerScaleFile, err := filepath.Abs("../../../config/configs/worker-scale.yaml")
	require.NoError(t, err)

	dir := t.TempDir()
	t.Chdir(dir)
	os.Setenv("INSTANCE_FILE", instanceFile)
	os.Setenv("MODEL_SCALE_FILE", modelScaleFile)
	os.Setenv("WORKER_SCALE_FILE", workerScaleFile)

	s := scheme.Scheme
	_ = aiv1.AddToScheme(s)
	_ = rayv1.AddToScheme(s)
	fakeClient := fake.NewClientBuilder().WithScheme(s).Build()
	recorder := record.NewFakeRecorder(100)

	// scaleFactor unset => effective 1.
	platform := newScaleFactorTestPlatform(nil)

	ctx := context.Background()
	builder := New(platform, fakeClient, s, recorder)
	spec, err := builder.buildClusterConfig(ctx)
	require.NoError(t, err)

	// worker-scale.yaml L40S base values migrated from features/saia.yaml.
	wantL40S := map[string]int32{
		"l40s-0-gpu": 1,
		"l40s-1-gpu": 2,
		"l40s-2-gpu": 1,
		"l40s-4-gpu": 0,
	}
	for _, wg := range spec.WorkerGroupSpecs {
		if want, ok := wantL40S[wg.GroupName]; ok {
			require.Equal(t, want, *wg.Replicas, "tier %s replicas", wg.GroupName)
		}
	}
}
