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
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
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
		if !strings.Contains(manifest, "timeoutSeconds: 5") {
			t.Errorf("%s does not use the documented five-second probe timeout", template)
		}
	}
	if !strings.Contains(rendered["langgraph-cloud/templates/api-server/deployment.yaml"], "cpu: 250m") {
		t.Error("API workload does not use the documented 250m default CPU request")
	}
}

func TestLASChartMapsWorkloadDefaultsOverridesSchedulingAndReferences(t *testing.T) {
	ai := &aiv1.AIService{}
	ai.Name = "fixture"
	ai.Spec.ImagePullSecrets = []corev1.LocalObjectReference{{Name: "registry-auth"}}
	ai.Spec.Feature = aiv1.FeatureSpec{
		Name:              "agentruntime",
		LicenseSecretRef:  "offline-license",
		PostgresSecretRef: "fixture-postgres",
		RedisSecretRef:    "fixture-redis",
		LAS: &aiv1.LASFeatureSpec{
			Image:       aiv1.LASImageSpec{Repository: "registry.example/fixture", Tag: "candidate-123"},
			AssistantID: "contract_fixture",
			API: aiv1.LASWorkloadSpec{
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("500m")},
				},
				SchedulingSpec: aiv1.SchedulingSpec{
					NodeSelector: map[string]string{"node-role": "api"},
					Tolerations:  []corev1.Toleration{{Key: "las", Operator: corev1.TolerationOpEqual, Value: "api", Effect: corev1.TaintEffectNoSchedule}},
				},
				StartupProbe: &corev1.Probe{
					ProbeHandler:   corev1.ProbeHandler{Exec: &corev1.ExecAction{Command: []string{"/bin/sh", "-c", "echo api"}}},
					TimeoutSeconds: 7,
				},
			},
			Queue: aiv1.LASWorkloadSpec{
				SchedulingSpec: aiv1.SchedulingSpec{
					NodeSelector: map[string]string{"node-role": "queue"},
					Tolerations:  []corev1.Toleration{{Key: "las", Operator: corev1.TolerationOpEqual, Value: "queue", Effect: corev1.TaintEffectNoSchedule}},
					Affinity: &corev1.Affinity{NodeAffinity: &corev1.NodeAffinity{
						RequiredDuringSchedulingIgnoredDuringExecution: &corev1.NodeSelector{
							NodeSelectorTerms: []corev1.NodeSelectorTerm{{MatchExpressions: []corev1.NodeSelectorRequirement{{Key: "kubernetes.io/os", Operator: corev1.NodeSelectorOpIn, Values: []string{"linux"}}}}},
						},
					}},
				},
			},
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
	api := rendered["langgraph-cloud/templates/api-server/deployment.yaml"]
	queue := rendered["langgraph-cloud/templates/queue/deployment.yaml"]
	for name, manifest := range map[string]string{"API": api, "queue": queue} {
		for _, expected := range []string{
			"name: registry-auth",
			"name: offline-license",
			"key: langgraph_cloud_license_key",
			"name: LANGSMITH_API_KEY",
			"key: api_key",
			"name: fixture-postgres",
			"key: postgres_connection_url",
			"name: fixture-redis",
			"key: redis_connection_url",
			"timeoutSeconds: 5",
			"memory: 2Gi",
			"memory: 4Gi",
			`cpu: "2"`,
		} {
			if !strings.Contains(manifest, expected) {
				t.Errorf("%s workload missing %q", name, expected)
			}
		}
		for _, forbidden := range []string{"llm_config", "mcp_configs", "kb_configs", "postgresUri", "redisUri", "licenseKey"} {
			if strings.Contains(manifest, forbidden) {
				t.Errorf("%s workload contains forbidden configuration %q", name, forbidden)
			}
		}
	}
	for _, expected := range []string{"cpu: 500m", "node-role: api", "value: api", "timeoutSeconds: 7", "exec:", "echo api"} {
		if !strings.Contains(api, expected) {
			t.Errorf("API workload missing configured override %q", expected)
		}
	}
	for _, expected := range []string{`cpu: "1"`, "node-role: queue", "value: queue", "kubernetes.io/os", "operator: In", "linux", "httpGet:", "path: /ok"} {
		if !strings.Contains(queue, expected) {
			t.Errorf("queue workload missing configured/default value %q", expected)
		}
	}

	manifests := make([]string, 0, len(rendered))
	for _, manifest := range rendered {
		manifests = append(manifests, manifest)
	}
	allManifests := strings.Join(manifests, "\n")
	for _, forbidden := range []string{
		"kind: StatefulSet", "kind: Secret", "kind: PersistentVolumeClaim",
		"las-fixture-langgraph-cloud-postgres", "las-fixture-langgraph-cloud-redis", "las-fixture-langgraph-cloud-mongo",
	} {
		if strings.Contains(allManifests, forbidden) {
			t.Errorf("rendered chart unexpectedly contains %q", forbidden)
		}
	}
}
