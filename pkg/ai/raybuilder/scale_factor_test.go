package raybuilder

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"regexp"
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

// TestReconcileRayService_NoOpWhenUnchanged asserts that reconciling the same
// AIPlatform spec twice in a row does not issue a second Update() against the
// RayService object. KubeRay's own controller already rewrites .status on this
// object every ~2-4s; if ReconcileRayService also wrote unconditionally on
// every AIPlatform pass, it would compound onto that churn with a second,
// redundant full-object (spec) rewrite. ResourceVersion is unchanged by a
// fake-client Get unless a write actually occurred, so an unchanged
// ResourceVersion across two reconciles proves the second reconcile issued no
// write.
func TestReconcileRayService_NoOpWhenUnchanged(t *testing.T) {
	os.Setenv("RELATED_IMAGE_RAY_HEAD", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_RAY_WORKER", "rayproject/ray:latest")
	os.Setenv("RELATED_IMAGE_FLUENT_BIT", "fluent/fluent-bit:latest")

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

	var afterCreate rayv1.RayService
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Namespace: "default", Name: "test-platform"}, &afterCreate))
	rvAfterCreate := afterCreate.ResourceVersion

	// Reconcile again with an identical platform spec - nothing this
	// controller owns has changed.
	require.NoError(t, builder.ReconcileRayService(ctx, platform))
	require.NotNil(t, builder.reconciledRayService)

	var afterSecondReconcile rayv1.RayService
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Namespace: "default", Name: "test-platform"}, &afterSecondReconcile))

	require.Equal(t, rvAfterCreate, afterSecondReconcile.ResourceVersion,
		"second reconcile with unchanged desired state must not write to the RayService object")
	require.Equal(t, rvAfterCreate, builder.reconciledRayService.ResourceVersion)

	// A genuine change (scaleFactor bump) must still produce a write.
	platform.Spec.ScaleFactor = int32PtrForTest(5)
	require.NoError(t, builder.ReconcileRayService(ctx, platform))

	var afterRealChange rayv1.RayService
	require.NoError(t, fakeClient.Get(ctx, types.NamespacedName{Namespace: "default", Name: "test-platform"}, &afterRealChange))
	require.NotEqual(t, rvAfterCreate, afterRealChange.ResourceVersion,
		"a genuine spec change must still produce a write")
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

// TestApplicationsTemplate_ReferencesEveryModelScaleEntry keeps the global
// model catalog and production applications template in sync in both
// directions so scaleFactor applies uniformly to every rendered model.
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
	replicaReference := regexp.MustCompile(`\.Replicas\.([A-Za-z0-9_]+)`)
	for _, match := range replicaReference.FindAllStringSubmatch(templateText, -1) {
		modelName := match[1]
		require.Contains(t, modelScale.ApplicationScale, modelName,
			"applications.yaml references %s, which is missing from model-scale.yaml", modelName)
	}

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

type renderedServeDeployment struct {
	Name              string           `yaml:"name"`
	AutoscalingConfig map[string]int32 `yaml:"autoscaling_config"`
}

type renderedServeApplication struct {
	Name        string                      `yaml:"name"`
	ImportPath  string                      `yaml:"import_path"`
	RoutePrefix string                      `yaml:"route_prefix"`
	RuntimeEnv  map[interface{}]interface{} `yaml:"runtime_env"`
	Args        map[interface{}]interface{} `yaml:"args"`
	Deployments []renderedServeDeployment   `yaml:"deployments"`
}

func renderProductionApplications(t *testing.T, scaleFactor int32, acceleratorType string) []renderedServeApplication {
	t.Helper()

	modelScaleData, err := os.ReadFile("../../../config/configs/model-scale.yaml")
	require.NoError(t, err)
	var modelScale ScaleConfig
	require.NoError(t, yaml.UnmarshalStrict(modelScaleData, &modelScale))

	replicas := make(map[string]int32, len(modelScale.ApplicationScale))
	for name, base := range modelScale.ApplicationScale {
		replicas[name] = base * scaleFactor
	}

	templateData, err := os.ReadFile("../../../config/configs/applications.yaml")
	require.NoError(t, err)
	tmpl, err := template.New("applications").Parse(string(templateData))
	require.NoError(t, err)

	var rendered bytes.Buffer
	require.NoError(t, tmpl.Execute(&rendered, ApplicationParams{
		Replicas:        replicas,
		AcceleratorType: acceleratorType,
	}))

	var doc struct {
		Applications []renderedServeApplication `yaml:"applications"`
	}
	require.NoError(t, yaml.Unmarshal(rendered.Bytes(), &doc))
	return doc.Applications
}

func indexRenderedApplications(apps []renderedServeApplication) map[string]renderedServeApplication {
	indexed := make(map[string]renderedServeApplication, len(apps))
	for _, app := range apps {
		indexed[app.Name] = app
	}
	return indexed
}

func indexRenderedDeployments(deployments []renderedServeDeployment) map[string]renderedServeDeployment {
	indexed := make(map[string]renderedServeDeployment, len(deployments))
	for _, deployment := range deployments {
		indexed[deployment.Name] = deployment
	}
	return indexed
}

// TestApplicationsTemplate_ProductionDefaultsDisableOnlyBiEncoder keeps the
// BiEncoder application template available for a controlled rollback while
// ensuring the production scale config does not deploy it. Every other
// configured application must remain enabled at its existing base scale.
func TestApplicationsTemplate_ProductionDefaultsDisableOnlyBiEncoder(t *testing.T) {
	modelScaleData, err := os.ReadFile("../../../config/configs/model-scale.yaml")
	require.NoError(t, err)
	var modelScale ScaleConfig
	require.NoError(t, yaml.UnmarshalStrict(modelScaleData, &modelScale))

	require.Equal(t, int32(0), modelScale.ApplicationScale["BiEncoder"],
		"BiEncoder must stay disabled in the production scale config")

	productionApps := indexRenderedApplications(renderProductionApplications(t, 1, "L40S"))
	require.NotContains(t, productionApps, "BiEncoder")
	require.Len(t, productionApps, len(modelScale.ApplicationScale)-1,
		"disabling BiEncoder must be the only production application removal")

	for name, baseReplicas := range modelScale.ApplicationScale {
		if name == "BiEncoder" {
			continue
		}
		require.Greater(t, baseReplicas, int32(0), "%s must remain enabled", name)
		require.Contains(t, productionApps, name, "%s disappeared with BiEncoder disabled", name)
	}

	// Keep the conditional template for rollback. Because fresh installs no
	// longer stage the BGE artifact, its weights must be staged before restoring
	// the scale entry to a positive value.
	applicationsData, err := os.ReadFile("../../../config/configs/applications.yaml")
	require.NoError(t, err)
	require.Contains(t, string(applicationsData), "{{- if .Replicas.BiEncoder }}")
	require.Contains(t, string(applicationsData), "route_prefix: /bi_encoder")
}

// TestApplicationsTemplate_ScaleFactorUsesLightweightDeploymentOverrides
// protects the Ray Serve in-place scaling contract. Ray includes application
// args in its code-version hash, so changing replica counts there rebuilds the
// application and replaces healthy replicas. Only top-level deployment
// autoscaling replica overrides may vary across a scaleFactor transition.
func TestApplicationsTemplate_ScaleFactorUsesLightweightDeploymentOverrides(t *testing.T) {
	atOne := indexRenderedApplications(renderProductionApplications(t, 1, "L40S"))
	atTwo := indexRenderedApplications(renderProductionApplications(t, 2, "L40S"))
	require.Equal(t, len(atOne), len(atTwo))
	require.NotContains(t, atOne, "BiEncoder")
	require.NotContains(t, atTwo, "BiEncoder")

	for name, one := range atOne {
		two, ok := atTwo[name]
		require.True(t, ok, "application %s disappeared at scaleFactor 2", name)
		require.Equal(t, one.ImportPath, two.ImportPath, "%s import_path changed", name)
		require.Equal(t, one.RoutePrefix, two.RoutePrefix, "%s route_prefix changed", name)
		require.Equal(t, one.RuntimeEnv, two.RuntimeEnv, "%s runtime_env changed", name)
		require.Equal(t, one.Args, two.Args, "%s args changed and would force a Ray Serve rebuild", name)
	}

	expectedScaledDeployment := map[string]string{
		"Entrypoint":                   "Entrypoint",
		"FmTimeseries":                 "FMTimeseriesDeployment",
		"Gemma431bIt":                  "LLMDeploymentL40S",
		"GptOss20b":                    "LLMDeploymentL40S",
		"UaeLarge":                     "EmbeddingModelDeployment",
		"AllMinilmL6V2":                "EmbeddingModelDeployment",
		"MbartTranslator":              "MbartTranslatorDeployment",
		"XlmRobertaLanguageClassifier": "ClassificationModelDeployment",
		"PromptInjectionTfidf":         "PromptInjectionTfidfDeployment",
		"CrossEncoder":                 "ScoringModelDeployment",
		"E5LanguageClassifier":         "ClassificationModelDeployment",
		"PromptInjectionCrossEncoder":  "ScoringModelDeployment",
		"PromptInjectionClassifier":    "ClassificationModelDeployment",
	}

	for appName, deploymentName := range expectedScaledDeployment {
		one := indexRenderedDeployments(atOne[appName].Deployments)[deploymentName]
		two := indexRenderedDeployments(atTwo[appName].Deployments)[deploymentName]
		require.NotNil(t, one.AutoscalingConfig, "%s missing autoscaling override", appName)
		require.NotNil(t, two.AutoscalingConfig, "%s missing autoscaling override", appName)
		require.Equal(t, int32(1), one.AutoscalingConfig["min_replicas"], "%s min replicas at factor 1", appName)
		require.Equal(t, int32(1), one.AutoscalingConfig["max_replicas"], "%s max replicas at factor 1", appName)
		require.Equal(t, int32(2), two.AutoscalingConfig["min_replicas"], "%s min replicas at factor 2", appName)
		require.Equal(t, int32(2), two.AutoscalingConfig["max_replicas"], "%s max replicas at factor 2", appName)
	}

	require.NotContains(t, indexRenderedDeployments(atOne["Gemma431bIt"].Deployments), "TextGenModelDeployment")
	require.NotContains(t, indexRenderedDeployments(atTwo["Gemma431bIt"].Deployments), "TextGenModelDeployment")
	require.NotContains(t, indexRenderedDeployments(atOne["GptOss20b"].Deployments), "TextGenModelDeployment")
	require.NotContains(t, indexRenderedDeployments(atTwo["GptOss20b"].Deployments), "TextGenModelDeployment")

	for accelerator, want := range map[string]struct {
		gemma int32
		gpt   int32
	}{
		"H100":                   {gemma: 6, gpt: 20},
		"L40S":                   {gemma: 4, gpt: 20},
		"RTX_PRO_6000_BLACKWELL": {gemma: 4, gpt: 4},
	} {
		apps := indexRenderedApplications(renderProductionApplications(t, 1, accelerator))
		gemma := indexRenderedDeployments(apps["Gemma431bIt"].Deployments)["LLMDeployment"+accelerator]
		gpt := indexRenderedDeployments(apps["GptOss20b"].Deployments)["LLMDeployment"+accelerator]
		require.Equal(t, want.gemma, gemma.AutoscalingConfig["target_ongoing_requests"], "Gemma target for %s", accelerator)
		require.Equal(t, want.gpt, gpt.AutoscalingConfig["target_ongoing_requests"], "GPT-OSS target for %s", accelerator)
	}
}

// TestScaleFactor_DefaultsToOne_Parity asserts that when spec.scaleFactor is
// unset, replicas and worker counts equal the global base values.
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
