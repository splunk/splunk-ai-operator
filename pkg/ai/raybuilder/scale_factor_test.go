package raybuilder

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"text/template"

	rayv1 "github.com/ray-project/kuberay/ray-operator/apis/ray/v1"
	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v2"
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
	require.NotNil(t, builder.reconciledRayService)

	var createdRayService rayv1.RayService
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Namespace: "default", Name: "test-platform"}, &createdRayService))
	require.Equal(t, createdRayService.ResourceVersion, builder.reconciledRayService.ResourceVersion)
	require.Equal(t, createdRayService.Spec.ServeConfigV2, builder.reconciledRayService.Spec.ServeConfigV2)

	var cm corev1.ConfigMap
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Namespace: "default", Name: "test-platform-serve-config"}, &cm))
	rendered := cm.Data["serve-config.yaml"]

	// ModelA base 1 * scaleFactor 3 => 3; ModelB base 2 * 3 => 6.
	require.Contains(t, rendered, "modelA_replicas: 3")
	require.Contains(t, rendered, "modelB_replicas: 6")

	createSnapshot := builder.reconciledRayService
	platform.Spec.ScaleFactor = int32PtrForTest(2)
	require.NoError(t, builder.ReconcileRayService(ctx, platform))
	require.NotNil(t, builder.reconciledRayService)
	require.NotSame(t, createSnapshot, builder.reconciledRayService)

	var updatedRayService rayv1.RayService
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Namespace: "default", Name: "test-platform"}, &updatedRayService))
	require.Equal(t, updatedRayService.ResourceVersion, builder.reconciledRayService.ResourceVersion)
	require.Equal(t, updatedRayService.Spec.ServeConfigV2, builder.reconciledRayService.Spec.ServeConfigV2)
	require.NotEqual(t, createdRayService.Spec, updatedRayService.Spec)
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

// TestApplicationsTemplate_ReferencesEveryModelScaleEntry prevents a model
// from silently falling back to Ray Serve's default replica count. Every key
// in model-scale.yaml must be consumed by the production applications
// template so scaleFactor applies uniformly.
func TestApplicationsTemplate_ReferencesEveryModelScaleEntry(t *testing.T) {
	modelScaleFile, err := filepath.Abs("../../../config/configs/model-scale.yaml")
	require.NoError(t, err)
	applicationsFile, err := filepath.Abs("../../../config/configs/applications.yaml")
	require.NoError(t, err)

	modelScaleData, err := os.ReadFile(modelScaleFile)
	require.NoError(t, err)
	var modelScale ScaleConfig
	require.NoError(t, yaml.UnmarshalStrict(modelScaleData, &modelScale))

	applicationsData, err := os.ReadFile(applicationsFile)
	require.NoError(t, err)
	templateText := string(applicationsData)

	for modelName := range modelScale.ApplicationScale {
		require.True(t,
			strings.Contains(templateText, "{{.Replicas."+modelName+"}}"),
			"applications.yaml must consume the replica count for %s", modelName,
		)
	}

	baseReplicas := make(map[string]int32, len(modelScale.ApplicationScale))
	for modelName := range modelScale.ApplicationScale {
		baseReplicas[modelName] = 1
	}
	tmpl, err := template.New("applications").Parse(templateText)
	require.NoError(t, err)
	var rendered bytes.Buffer
	require.NoError(t, tmpl.Execute(&rendered, ApplicationParams{
		Replicas:        baseReplicas,
		AcceleratorType: "L40S",
	}))

	var applications map[interface{}]interface{}
	require.NoError(t, yaml.Unmarshal(rendered.Bytes(), &applications))
	require.Contains(t, rendered.String(), "min_replicas: 1")
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
