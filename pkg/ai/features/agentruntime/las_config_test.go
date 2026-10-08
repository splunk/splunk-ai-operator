package agentruntime

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	aiv1 "github.com/splunk/splunk-ai-operator/api/v1"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/chartutil"
	"helm.sh/helm/v3/pkg/engine"
)

func TestLASValuesSelectImageAndKeepRunContextOut(t *testing.T) {
	ai := &aiv1.AIService{}
	ai.Name = "fixture"
	ai.Spec.Feature = aiv1.FeatureSpec{
		Name:              "agentruntime",
		LicenseSecretRef:  "offline-license",
		PostgresSecretRef: "fixture-postgres",
		RedisSecretRef:    "fixture-redis",
		LAS: &aiv1.LASFeatureSpec{
			Image:       aiv1.LASImageSpec{Repository: "registry.example/fixture", Tag: "candidate-123"},
			AssistantID: "contract_fixture",
		},
	}
	values := lasValues(ai)
	images := values["images"].(map[string]interface{})
	image := images["apiServerImage"].(map[string]interface{})
	if image["repository"] != "registry.example/fixture" || image["tag"] != "candidate-123" {
		t.Fatalf("selected image not rendered: %#v", image)
	}
	if _, found := values["llm_config"]; found {
		t.Fatal("per-run context rendered into Helm values")
	}
	if _, found := values["mcp_configs"]; found {
		t.Fatal("per-run context rendered into Helm values")
	}
	if got := values["config"].(map[string]interface{})["existingSecretName"]; got != "offline-license" {
		t.Fatalf("license Secret reference = %v", got)
	}
	if got := values["postgres"].(map[string]interface{})["external"].(map[string]interface{})["existingSecretName"]; got != "fixture-postgres" {
		t.Fatalf("PostgreSQL Secret reference = %v", got)
	}
	if got := values["redis"].(map[string]interface{})["external"].(map[string]interface{})["existingSecretName"]; got != "fixture-redis" {
		t.Fatalf("Redis Secret reference = %v", got)
	}
	serialized, err := json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"llm_config", "mcp_configs", "kb_configs", "assistantId", "api_key", "Authorization"} {
		if bytes.Contains(serialized, []byte(forbidden)) {
			t.Errorf("Helm values contain per-invocation field %q", forbidden)
		}
	}
}

func TestLASChartRendersSelectedCandidateForBothWorkloads(t *testing.T) {
	ai := &aiv1.AIService{}
	ai.Name = "fixture"
	ai.Spec.Feature = aiv1.FeatureSpec{
		Name:              "agentruntime",
		LicenseSecretRef:  "offline-license",
		PostgresSecretRef: "fixture-postgres",
		RedisSecretRef:    "fixture-redis",
		LAS: &aiv1.LASFeatureSpec{
			Image:       aiv1.LASImageSpec{Repository: "registry.example/fixture", Tag: "candidate-123"},
			AssistantID: "contract_fixture",
		},
	}
	chart, err := loader.LoadArchive(bytes.NewReader(lasChartArchive))
	if err != nil {
		t.Fatal(err)
	}
	renderValues, err := chartutil.ToRenderValues(chart, lasValues(ai), chartutil.ReleaseOptions{Name: "las-fixture", Namespace: "default"}, chartutil.DefaultCapabilities)
	if err != nil {
		t.Fatal(err)
	}
	rendered, err := engine.Render(chart, renderValues)
	if err != nil {
		t.Fatal(err)
	}
	for _, template := range []string{
		"langgraph-cloud/templates/api-server/deployment.yaml",
		"langgraph-cloud/templates/queue/deployment.yaml",
	} {
		manifest := rendered[template]
		if !strings.Contains(manifest, `image: "registry.example/fixture:candidate-123"`) {
			t.Errorf("%s does not use the selected candidate image", template)
		}
		for _, forbidden := range []string{"llm_config", "mcp_configs", "kb_configs"} {
			if strings.Contains(manifest, forbidden) {
				t.Errorf("%s contains per-invocation field %q", template, forbidden)
			}
		}
	}
}
