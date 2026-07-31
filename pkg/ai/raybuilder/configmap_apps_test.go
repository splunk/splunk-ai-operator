package raybuilder

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
)

// readApplicationsYAMLFromRepo locates the repo's
// config/configs/applications.yaml relative to the raybuilder test file.
// Keeping this a standalone helper (rather than using os.Getenv("APPLICATION_FILE"))
// lets the test run under `go test ./pkg/ai/raybuilder/...` without setting env.
func readApplicationsYAMLFromRepo(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	require.NoError(t, err)
	// pkg/ai/raybuilder is three levels below the repo root.
	repoRoot := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	path := filepath.Join(repoRoot, "config", "configs", "applications.yaml")
	raw, err := os.ReadFile(path)
	require.NoError(t, err, "unable to read %s", path)
	return string(raw)
}

// maskGoTemplates replaces `{{ ... }}` tokens with a plain string so the
// result parses as valid YAML. applications.yaml interpolates Go template
// variables at runtime (see Builder.ReconcileApplicationsConfigMap) — during
// unit testing we never render them, so a syntactic mask is sufficient.
func maskGoTemplates(s string) string {
	return regexp.MustCompile(`\{\{[^}]+\}\}`).ReplaceAllString(s, "PLACEHOLDER")
}

// Test_ApplicationsYAML_DisableResponsesRedis is a regression test for the
// airgap k0s /query failure. Each vLLM TextGen Ray Serve deployment constructs
// a RedisOpenAIServingResponses on the first /v1/responses request; that
// class's __init__ raises RuntimeError if neither RESPONSES_REDIS_URL nor
// RESPONSES_REDIS_ADDRESS is configured, and the resulting empty SSE stream
// bubbles up to SAIA v2's search pipeline as "No generations found in stream"
// → SearchStreamError → "An error occurred processing your request" to the
// end user. See ai-platform-models commits c1f9aef3, da7628ea, b6ff101e.
//
// The fix (set DISABLE_RESPONSES_API_REDIS=True) switches vLLM to the new
// NoOpOpenAIServingResponses class that skips Redis entirely. It MUST be set
// on every app whose deployment_type is text_gen_model_deployment — that's
// the only Ray Serve deployment type that instantiates the Responses API
// serving class. Other deployment types (embedding_model_deployment,
// scoring_model_deployment, classification_model_deployment, custom_deployment)
// do not call /v1/responses and do not need this flag.
func Test_ApplicationsYAML_DisableResponsesRedis(t *testing.T) {
	masked := maskGoTemplates(readApplicationsYAMLFromRepo(t))

	// Parse just enough structure to traverse apps; keep the rest loose so
	// unrelated config churn doesn't break this test.
	type envVars = map[string]string
	type runtimeEnv struct {
		EnvVars envVars `yaml:"env_vars"`
	}
	type args struct {
		DeploymentType string `yaml:"deployment_type"`
	}
	type app struct {
		Name       string     `yaml:"name"`
		Args       args       `yaml:"args"`
		RuntimeEnv runtimeEnv `yaml:"runtime_env"`
	}
	var doc struct {
		Applications []app `yaml:"applications"`
	}
	require.NoError(t, yaml.Unmarshal([]byte(masked), &doc))
	require.NotEmpty(t, doc.Applications, "applications.yaml parsed as empty")

	// Collect the set of text-gen apps (must-set) and everything else (must-not-set).
	var textGenApps []app
	var otherApps []app
	for _, a := range doc.Applications {
		if a.Args.DeploymentType == "text_gen_model_deployment" {
			textGenApps = append(textGenApps, a)
		} else {
			otherApps = append(otherApps, a)
		}
	}

	expectedTextGenApps := []string{"Gemma431bIt", "GptOss20b"}

	// We expect exactly two text-gen apps today (Gemma431bIt, GptOss20b).
	// If this count changes, someone added a new text-gen model; they MUST
	// also add DISABLE_RESPONSES_API_REDIS to the new app.
	require.Len(t, textGenApps, len(expectedTextGenApps),
		"expected exactly %d text_gen_model_deployment app(s) (%s); "+
			"found %d. New text-gen apps MUST set DISABLE_RESPONSES_API_REDIS.",
		len(expectedTextGenApps), strings.Join(expectedTextGenApps, ", "),
		len(textGenApps))

	for _, a := range textGenApps {
		assert.Equal(t, "True", a.RuntimeEnv.EnvVars["DISABLE_RESPONSES_API_REDIS"],
			"app %q (deployment_type=text_gen_model_deployment) must set "+
				"DISABLE_RESPONSES_API_REDIS=\"True\" in runtime_env.env_vars. Without this, "+
				"vLLM's RedisOpenAIServingResponses constructor raises "+
				"RuntimeError('Responses Redis URL not set') and /v1/responses calls fail "+
				"(surfaces to SAIA v2 /query as \"An error occurred processing your request\").",
			a.Name)
	}

	// Sanity: assert the two canonical app names we expect. Keeps the test
	// readable if someone renames an app and forgets to re-check this.
	var names []string
	for _, a := range textGenApps {
		names = append(names, a.Name)
	}
	assert.ElementsMatch(t, expectedTextGenApps, names,
		"unexpected set of text_gen_model_deployment apps: %v", names)

	// Hygiene check: non-text-gen apps should NOT carry this env (it's a
	// no-op for them and misleading if present).
	for _, a := range otherApps {
		if _, ok := a.RuntimeEnv.EnvVars["DISABLE_RESPONSES_API_REDIS"]; ok {
			t.Errorf("app %q (deployment_type=%q) should NOT set "+
				"DISABLE_RESPONSES_API_REDIS — it's only read by "+
				"vllm_text_gen_model.VLLMTextGenModel.", a.Name, a.Args.DeploymentType)
		}
	}
}

// Test_ApplicationsYAML_IsWellFormed is a tiny smoke test that the bundled
// applications.yaml parses correctly after Go-template masking. Catches
// accidental structural breakage (e.g. un-indented env_vars, stray tabs).
func Test_ApplicationsYAML_IsWellFormed(t *testing.T) {
	masked := maskGoTemplates(readApplicationsYAMLFromRepo(t))
	var raw map[string]any
	require.NoError(t, yaml.Unmarshal([]byte(masked), &raw),
		"applications.yaml does not parse as YAML (after masking Go templates)")
	apps, ok := raw["applications"].([]any)
	require.True(t, ok, "applications.yaml missing top-level 'applications' list")
	require.NotEmpty(t, apps, "applications list is empty")

	// Spot-check: every app entry must have a 'name' key. 'args' is optional
	// — the Entrypoint router app omits it, model apps carry deployment config
	// there.
	for i, a := range apps {
		m, ok := a.(map[string]any)
		require.True(t, ok, "app at index %d is not a mapping", i)
		_, hasName := m["name"]
		require.True(t, hasName,
			"app at index %d missing 'name': keys=%v", i, keys(m))
	}
}

// Test_ApplicationsYAML_BiEncoderRTXMemoryMatchesRayAllocation prevents Ray's
// fractional GPU reservation from drifting below the model server's actual
// memory allocation for RTX Pro 6000 Blackwell.
func Test_ApplicationsYAML_BiEncoderRTXMemoryMatchesRayAllocation(t *testing.T) {
	type rayActorOptions struct {
		NumGPUs float64 `yaml:"num_gpus"`
	}
	type gpuTypeOptions struct {
		RayActorOptions rayActorOptions `yaml:"ray_actor_options"`
	}
	type deploymentConfig struct {
		GPUTypeOptionsOverride map[string]gpuTypeOptions `yaml:"gpu_type_options_override"`
	}
	type engineArgs struct {
		GPUMemoryUtilization float64 `yaml:"gpu_memory_utilization"`
	}
	type modelConfigOverride struct {
		EngineArgs engineArgs `yaml:"engine_args"`
	}
	type app struct {
		Name string `yaml:"name"`
		Args struct {
			DeploymentConfigs map[string]deploymentConfig `yaml:"deployment_configs"`
			ModelDefinition   struct {
				GPUTypeModelConfigOverride map[string]modelConfigOverride `yaml:"gpu_type_model_config_override"`
			} `yaml:"model_definition"`
		} `yaml:"args"`
	}
	var doc struct {
		Applications []app `yaml:"applications"`
	}
	require.NoError(t, yaml.Unmarshal([]byte(maskGoTemplates(readApplicationsYAMLFromRepo(t))), &doc))

	const accelerator = "RTX_PRO_6000_BLACKWELL"
	for _, application := range doc.Applications {
		if application.Name != "BiEncoder" {
			continue
		}
		deployment, ok := application.Args.DeploymentConfigs["EmbeddingModelDeployment"]
		require.True(t, ok, "BiEncoder is missing EmbeddingModelDeployment")
		rayOptions, ok := deployment.GPUTypeOptionsOverride[accelerator]
		require.True(t, ok, "BiEncoder is missing the %s Ray allocation", accelerator)
		modelOverride, ok := application.Args.ModelDefinition.GPUTypeModelConfigOverride[accelerator]
		require.True(t, ok, "BiEncoder is missing the %s model memory override", accelerator)

		require.InDelta(t, 0.004, rayOptions.RayActorOptions.NumGPUs, 0.000001)
		require.InDelta(t, rayOptions.RayActorOptions.NumGPUs,
			modelOverride.EngineArgs.GPUMemoryUtilization, 0.000001,
			"BiEncoder's RTX model memory utilization must match its Ray GPU reservation")
		return
	}
	t.Fatal("BiEncoder application not found")
}

func keys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	// Stable-ish for readability in failure messages.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && strings.Compare(out[j], out[j-1]) < 0; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}
