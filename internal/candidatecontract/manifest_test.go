package candidatecontract

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	batchv1 "k8s.io/api/batch/v1"
	"sigs.k8s.io/yaml"
)

func initial(t *testing.T) (*Manifest, *Matrix) {
	t.Helper()
	var m Manifest
	var matrix Matrix
	require.NoError(t, Read(filepath.Join("..", "..", "config", "agent-runtime", "candidate-manifest.yaml"), &m))
	require.NoError(t, Read(filepath.Join("..", "..", "config", "agent-runtime", "compatibility-matrix.yaml"), &matrix))
	return &m, &matrix
}

func clone(t *testing.T, m *Manifest) *Manifest {
	t.Helper()
	data, err := json.Marshal(m)
	require.NoError(t, err)
	var result Manifest
	require.NoError(t, json.Unmarshal(data, &result))
	return &result
}

func TestInitialCandidateBothProfiles(t *testing.T) {
	m, matrix := initial(t)
	for _, profile := range []string{"cpuOnly", "fullfeature"} {
		t.Run(profile, func(t *testing.T) {
			// A hostile ambient value cannot replace the selected image.
			t.Setenv("RELATED_IMAGE_SLIM_API", "docker.io/unselected/fallback:latest")
			snapshot, err := Render(m, profile, matrix)
			require.NoError(t, err)
			require.Equal(t, m.Spec.Revision, snapshot.Revision)
			require.Equal(t, "pending", snapshot.Qualification)
			require.Equal(t, "pending", snapshot.MatrixPairStatus)
			require.Contains(t, snapshot.Scope, "synthetic schema image digest")
			require.Len(t, snapshot.Resources, 5)
			for _, resource := range snapshot.Resources {
				if job, ok := resource.Object.(*batchv1.Job); ok {
					require.Equal(t, syntheticSchemaImageForRender(m.Spec.Components["schemaSetup"].Image), job.Spec.Template.Spec.Containers[0].Image)
				}
			}
			data, err := yaml.Marshal(snapshot)
			require.NoError(t, err)
			require.NotContains(t, string(data), "offline-placeholder")
			require.NotContains(t, string(data), "docker.io/unselected/fallback")
			for _, name := range imageComponents {
				require.Contains(t, string(data), m.Spec.Components[name].Image)
			}
			require.Equal(t, "docker.io/unselected/fallback:latest", os.Getenv("RELATED_IMAGE_SLIM_API"), "render restores process environment")
		})
	}
}

func TestEveryImageRefreshBothProfiles(t *testing.T) {
	m, matrix := initial(t)
	for _, name := range imageComponents {
		t.Run(name, func(t *testing.T) {
			next := clone(t, m)
			next.Spec.Revision++
			entry := next.Spec.Components[name]
			entry.Image = "registry.example.invalid/" + strings.ToLower(name) + ":synthetic-fixed"
			next.Spec.Components[name] = entry
			if name == "runtimeBase" || name == "launchpadCarrier" {
				next.Spec.CompatibilityPair = "synthetic-unlisted"
			}
			next.Spec.History = append(next.Spec.History, Change{Revision: next.Spec.Revision, Change: "Synthetic fixed candidate", Source: "local contract test", PreviousImages: map[string]string{name: m.Spec.Components[name].Image}})
			changes, err := ValidateRefresh(m, next)
			require.NoError(t, err)
			require.Equal(t, []ImageChange{{name, m.Spec.Components[name].Image, entry.Image}}, changes)
			for _, profile := range []string{"cpuOnly", "fullfeature"} {
				snapshot, err := Render(next, profile, matrix)
				require.NoError(t, err)
				require.NoError(t, snapshot.Check(next))
				require.Equal(t, next.Spec.Revision, snapshot.Revision)
				require.Equal(t, "pending", snapshot.Qualification)
			}
		})
	}
}

func TestCPUOnlyPreservesSuppliedPlatformURL(t *testing.T) {
	m, matrix := initial(t)
	const input = "http://future-platform.example.invalid:8000/ai-platform-models/v1/"
	snapshot, err := renderWithPlatformURL(m, "cpuOnly", matrix, input)
	require.NoError(t, err)
	require.Equal(t, input, snapshot.PlatformURLInput, "validation must preserve a supplied CPU-only URL")
	require.NoError(t, snapshot.Check(m))
}

func TestSavedSyntheticRefreshFixture(t *testing.T) {
	m, matrix := initial(t)
	var next Manifest
	require.NoError(t, Read(filepath.Join("..", "..", "config", "agent-runtime", "testdata", "candidate-refresh.yaml"), &next))
	changes, err := ValidateRefresh(m, &next)
	require.NoError(t, err)
	require.Len(t, changes, 1)
	require.Equal(t, "slim", changes[0].Component)
	for _, profile := range []string{"cpuOnly", "fullfeature"} {
		_, err = Render(&next, profile, matrix)
		require.NoError(t, err)
	}
}

func TestInvalidContractsFailBeforeRenderingWithoutValues(t *testing.T) {
	cases := []struct {
		name, path string
		mutate     func(*Manifest)
	}{
		{"missing image", "spec.components.slim.image", func(m *Manifest) { e := m.Spec.Components["slim"]; e.Image = ""; m.Spec.Components["slim"] = e }},
		{"image is URL", "spec.components.slim.image", func(m *Manifest) {
			e := m.Spec.Components["slim"]
			e.Image = "https://registry.example.invalid/slim:bad"
			m.Spec.Components["slim"] = e
		}},
		{"implicit registry", "spec.components.slim.image", func(m *Manifest) {
			e := m.Spec.Components["slim"]
			e.Image = "slim:candidate"
			m.Spec.Components["slim"] = e
		}},
		{"image canary", "spec.components.slim.image", func(m *Manifest) {
			e := m.Spec.Components["slim"]
			e.Image = "CANARY-PASSWORD invalid image"
			m.Spec.Components["slim"] = e
		}},
		{"loader canary", "spec.components.launchpadCarrier.agentModule", func(m *Manifest) {
			e := m.Spec.Components["launchpadCarrier"]
			e.AgentModule = "CANARY-PASSWORD!"
			m.Spec.Components["launchpadCarrier"] = e
		}},
		{"loader conflict", "spec.contract.loaderSelection", func(m *Manifest) { m.Spec.Contract.LoaderSelection.Value = "different.loader:Class" }},
		{"wrong prefix", "spec.contract.runtimeAPI.prefix", func(m *Manifest) { m.Spec.Contract.RuntimeAPI.Prefix = "/v1" }},
		{"wrong port", "spec.contract.runtimeAPI", func(m *Manifest) { m.Spec.Contract.RuntimeAPI.HTTPPort = 8888 }},
		{"wrong health API", "spec.contract.readinessAndHealth", func(m *Manifest) { m.Spec.Contract.ReadinessAndHealth.Path = "/service/ready" }},
		{"schema entry point", "spec.contract.schemaEntryPoint", func(m *Manifest) { m.Spec.Contract.SchemaEntryPoint.SQLPath = "/other.sql" }},
		{"missing Secret key", "spec.contract.secretKeys", func(m *Manifest) { m.Spec.Contract.SecretKeys.Required = m.Spec.Contract.SecretKeys.Required[:5] }},
		{"wrong SLIM binding", "spec.components.slim.requiredEnvironment", func(m *Manifest) {
			e := m.Spec.Components["slim"]
			e.RequiredEnvironment[0].Name = "UNSUPPORTED_PLATFORM_URL"
			m.Spec.Components["slim"] = e
		}},
		{"missing SLIM binding", "spec.components.slim.requiredEnvironment", func(m *Manifest) {
			e := m.Spec.Components["slim"]
			e.RequiredEnvironment = e.RequiredEnvironment[:1]
			m.Spec.Components["slim"] = e
		}},
		{"AITK version", "spec.components.aitk.appVersion", func(m *Manifest) {
			e := m.Spec.Components["aitk"]
			e.AppVersion = "pending"
			m.Spec.Components["aitk"] = e
		}},
		{"AITK route", "spec.components.aitk.endpointContract", func(m *Manifest) {
			e := m.Spec.Components["aitk"]
			e.EndpointContract.BasePath = "/wrong"
			m.Spec.Components["aitk"] = e
		}},
		{"false qualification", "spec.qualification", func(m *Manifest) { m.Spec.Qualification = "certified" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m, matrix := initial(t)
			tc.mutate(m)
			snapshot, err := Render(m, "cpuOnly", matrix)
			require.Nil(t, snapshot)
			require.ErrorContains(t, err, tc.path)
			require.NotContains(t, err.Error(), "CANARY-PASSWORD")
		})
	}
}

func TestMatrixAndRefreshRejections(t *testing.T) {
	m, matrix := initial(t)
	matrix.Spec.ContractVersions[m.Spec.ContractVersion] = struct {
		Status string `json:"status"`
	}{Status: "unsupported"}
	_, err := Render(m, "cpuOnly", matrix)
	require.ErrorContains(t, err, "spec.contractVersion")
	m, matrix = initial(t)
	matrix.Spec.Pairs[0].Status = "blocked"
	_, err = Render(m, "cpuOnly", matrix)
	require.ErrorContains(t, err, "spec.compatibilityPair")
	m, matrix = initial(t)
	e := m.Spec.Components["runtimeBase"]
	e.Image = "registry.example.invalid/base:new"
	m.Spec.Components["runtimeBase"] = e
	_, err = Render(m, "cpuOnly", matrix)
	require.ErrorContains(t, err, "spec.compatibilityPair")
	m, _ = initial(t)
	next := clone(t, m)
	_, err = ValidateRefresh(m, next)
	require.ErrorContains(t, err, "spec.revision")
	next.Spec.Revision++
	e = next.Spec.Components["slim"]
	e.Image = "registry.example.invalid/slim:new"
	next.Spec.Components["slim"] = e
	next.Spec.History = append(next.Spec.History, Change{Revision: next.Spec.Revision, Change: "changed image", Source: "test"})
	_, err = ValidateRefresh(m, next)
	require.ErrorContains(t, err, "spec.history.previousImages.slim")
}

func TestMalformedYAMLDoesNotEchoSecret(t *testing.T) {
	filename := filepath.Join(t.TempDir(), "malformed.yaml")
	require.NoError(t, os.WriteFile(filename, []byte("secret: [CANARY-PASSWORD\n"), 0600))
	var m Manifest
	err := Read(filename, &m)
	require.EqualError(t, err, "input: invalid YAML")
}
