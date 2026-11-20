package imagesnapshot

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/splunk/splunk-ai-operator/internal/candidatecontract"
)

const candidatePath = "../../config/agent-runtime/candidate-manifest.yaml"

func loadCandidate(t *testing.T) (*candidatecontract.Manifest, string) {
	t.Helper()
	var m candidatecontract.Manifest
	require.NoError(t, candidatecontract.Read(candidatePath, &m))
	b, err := os.ReadFile(candidatePath)
	require.NoError(t, err)
	return &m, Checksum(b)
}

func installerConfig() InstallerConfig {
	var c InstallerConfig
	c.Images.Operator.Image = "docker.io/splunk/splunk-ai-operator:candidate-1"
	c.Images.Ray.HeadImage = "docker.io/rayproject/ray:2.44.0"
	c.Images.Ray.WorkerImage = "docker.io/rayproject/ray:2.44.0"
	c.Images.Weaviate.Image = "docker.io/semitechnologies/weaviate:stable-v1.28-007846a"
	c.Images.Saia.APIImage = "docker.io/splunk/ai-tier-saia-api:v1.0"
	c.Images.Saia.APIV2Image = "docker.io/splunk/ai-tier-saia-api-v2:v1.0"
	c.Images.Saia.DataLoaderImage = "docker.io/splunk/ai-tier-saia-data-loader:v1.0"
	c.Images.Nginx.Image = "docker.io/library/nginx:1.27-alpine"
	c.Images.FluentBit.Image = "docker.io/fluent/fluent-bit:1.9.6"
	c.Images.OtelCollector.Image = "docker.io/otel/opentelemetry-collector-contrib:0.122.1"
	return c
}

func renderedValues(profile string, components map[string]bool) *RenderedValues {
	v := &RenderedValues{Components: components}
	v.Profile.Effective = profile
	return v
}

func baseComponents() map[string]bool {
	return map[string]bool{"certManager": true, "monitoring": true, "otel": true, "aiOperator": true, "metallb": false}
}

func fullInput(t *testing.T) InventoryInput {
	m, sum := loadCandidate(t)
	cpu := baseComponents()
	cpu["kuberay"], cpu["nvidia"] = false, false
	full := baseComponents()
	full["kuberay"], full["nvidia"] = true, true
	return InventoryInput{
		Candidate: m, CandidateChecksum: sum, Installer: installerConfig(),
		Values: map[string]*RenderedValues{ProfileCPUOnly: renderedValues(ProfileCPUOnly, cpu), ProfileFullFeature: renderedValues(ProfileFullFeature, full)},
		AddonRefs: []string{
			"quay.io/jetstack/cert-manager-controller:v1.13.0",
			"quay.io/kuberay/operator:v1.2.2",
			"nvcr.io/nvidia/k8s-device-plugin:v0.17.3",
			"quay.io/prometheus/prometheus:v2.53.0",
			"docker.io/rancher/local-path-provisioner:v0.0.24",
			"quay.io/metallb/controller:v0.14.8",
			"example.com/team/custom-addon:1.0",
		},
		K0sRefs: []string{"registry.k8s.io/pause:3.9", "quay.io/k0sproject/coredns:1.11.3"},
	}
}

func components(images []Image) map[string]Image {
	out := map[string]Image{}
	for _, i := range images {
		out[i.Component] = i
	}
	return out
}

func TestBuildInventory_CandidateImagesComeFromTheCandidateManifest(t *testing.T) {
	inv, err := BuildInventory(fullInput(t))
	require.NoError(t, err)
	c := components(inv.Images)

	// The four candidate images, each for both profiles, with their category.
	for component, wantCategory := range map[string]string{
		"agent-runtime-base":          CategoryAgentRuntime,
		"agent-runtime-provider-mltk": CategoryAgentRuntime,
		"agent-runtime-schema-setup":  CategoryAgentRuntime,
		"slim":                        CategorySLIM,
	} {
		got, ok := c[component]
		require.True(t, ok, component)
		assert.Equal(t, wantCategory, got.Category, component)
		assert.Equal(t, Profiles, got.Profiles, component)
		assert.Contains(t, got.Origin, "candidate-manifest:components.", component)
	}
	assert.Equal(t, "658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/slim-api:es-runtime-sync-create-ready-21d4bf15f-20261116-amd64", c["slim"].Source)

	// AITK is a Splunk app, not a container image: it is not in the inventory.
	for _, i := range inv.Images {
		assert.NotContains(t, i.Component, "aitk")
		assert.NotContains(t, i.Source, "ai-tier-aitk")
	}

	// The inventory is tied to the candidate record it came from.
	m, sum := loadCandidate(t)
	assert.Equal(t, CandidateRef{Name: m.Metadata.Name, Revision: m.Spec.Revision, Checksum: sum}, inv.Candidate)
	assert.NotEmpty(t, inv.Checksum)
}

func TestBuildInventory_ProfileApplicability(t *testing.T) {
	inv, err := BuildInventory(fullInput(t))
	require.NoError(t, err)
	cpu := components(inv.ForProfile(ProfileCPUOnly))
	full := components(inv.ForProfile(ProfileFullFeature))

	// Only fullfeature runs model-serving workloads and their platform.
	for _, c := range []string{"ray-head", "ray-worker", "weaviate", "saia-api", "saia-api-v2", "saia-data-loader", "nginx", "kuberay-operator", "nvidia-device-plugin"} {
		assert.Contains(t, full, c, "fullfeature needs "+c)
		assert.NotContains(t, cpu, c, "cpuOnly must not need "+c)
	}
	// Both need the runtime, the operator and the common platform components.
	for _, c := range []string{"agent-runtime-base", "agent-runtime-schema-setup", "agent-runtime-provider-mltk", "slim",
		"splunk-ai-operator", "fluent-bit", "otel-collector", "cert-manager", "monitoring-stack", "local-path-provisioner",
		"k0s-pause", "k0s-coredns", "addon-custom-addon"} {
		assert.Contains(t, cpu, c, "cpuOnly needs "+c)
		assert.Contains(t, full, c, "fullfeature needs "+c)
	}
	// An add-on whose component is switched off in the rendered values is not needed.
	assert.NotContains(t, cpu, "metallb")
	assert.NotContains(t, full, "metallb")
}

func TestBuildInventory_EffectiveComponentsSwitchImagesOff(t *testing.T) {
	in := fullInput(t)
	in.Values[ProfileCPUOnly].Components["otel"] = false
	in.Values[ProfileCPUOnly].Components["certManager"] = false
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	cpu := components(inv.ForProfile(ProfileCPUOnly))
	full := components(inv.ForProfile(ProfileFullFeature))
	assert.NotContains(t, cpu, "otel-collector")
	assert.NotContains(t, cpu, "cert-manager")
	assert.Contains(t, full, "otel-collector", "the other profile is not affected")
	assert.Contains(t, full, "cert-manager")
}

func TestBuildInventory_WithoutRenderedValuesCPUOnlyStillSkipsModelServing(t *testing.T) {
	in := fullInput(t)
	in.Values = nil
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	cpu := components(inv.ForProfile(ProfileCPUOnly))
	assert.NotContains(t, cpu, "kuberay-operator")
	assert.NotContains(t, cpu, "nvidia-device-plugin")
	assert.NotContains(t, cpu, "ray-head")
	assert.Contains(t, components(inv.ForProfile(ProfileFullFeature)), "kuberay-operator")
}

func TestBuildInventory_Owners(t *testing.T) {
	in := fullInput(t)
	in.Owners = map[string]string{"slim": "slim-team", "ray-head": "ml-platform"}
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	c := components(inv.Images)
	assert.Equal(t, "slim-team", c["slim"].Owner, "an owners file wins")
	assert.Equal(t, "ml-platform", c["ray-head"].Owner)
	assert.Equal(t, "ai/ai-agent-runtime", c["agent-runtime-schema-setup"].Owner, "the candidate manifest's source repository names the owner")
	assert.Equal(t, "unassigned", c["weaviate"].Owner, "no owner is invented")
	for _, i := range inv.Images {
		assert.NotEmpty(t, i.Owner, i.Component)
	}
}

func TestBuildInventory_IsDeterministic(t *testing.T) {
	a, err := BuildInventory(fullInput(t))
	require.NoError(t, err)

	// The same inputs in a different order give the same inventory and checksum.
	in := fullInput(t)
	in.AddonRefs = []string{in.AddonRefs[6], in.AddonRefs[5], in.AddonRefs[4], in.AddonRefs[3], in.AddonRefs[2], in.AddonRefs[1], in.AddonRefs[0], in.AddonRefs[0]}
	in.K0sRefs = []string{in.K0sRefs[1], in.K0sRefs[0], in.K0sRefs[0]}
	b, err := BuildInventory(in)
	require.NoError(t, err)
	assert.Equal(t, a.Checksum, b.Checksum)
	assert.Equal(t, a.Images, b.Images)

	// A different reference changes the checksum.
	in.Installer.Images.Weaviate.Image = "docker.io/semitechnologies/weaviate:other"
	c, err := BuildInventory(in)
	require.NoError(t, err)
	assert.NotEqual(t, a.Checksum, c.Checksum)

	// So does a different candidate record, even with the same images.
	d := fullInput(t)
	d.CandidateChecksum = "0000"
	e, err := BuildInventory(d)
	require.NoError(t, err)
	assert.NotEqual(t, a.Checksum, e.Checksum)
}

func TestBuildInventory_SharedReferencesKeepOneEntryPerComponent(t *testing.T) {
	inv, err := BuildInventory(fullInput(t))
	require.NoError(t, err)
	c := components(inv.Images)
	assert.Equal(t, c["ray-head"].Source, c["ray-worker"].Source)
	assert.Contains(t, c, "ray-head")
	assert.Contains(t, c, "ray-worker")
}

func TestBuildInventory_ComponentsThatAreNotConfiguredAreSkipped(t *testing.T) {
	in := fullInput(t)
	in.Installer = InstallerConfig{} // nothing configured outside the candidate set
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	c := components(inv.Images)
	assert.NotContains(t, c, "weaviate")
	assert.NotContains(t, c, "ray-head")
	assert.Contains(t, c, "slim")
}

func TestBuildInventory_Rejections(t *testing.T) {
	_, err := BuildInventory(InventoryInput{})
	assert.ErrorContains(t, err, "candidate manifest is required")

	in := fullInput(t)
	c := in.Candidate.Spec.Components["slim"]
	in.Candidate.Spec.Components["mystery"] = c
	_, err = BuildInventory(in)
	assert.ErrorContains(t, err, `component "mystery"`)
}

func TestInstallRefs_AreWhatAnInstallOfTheProfileWillUse(t *testing.T) {
	in := fullInput(t)
	in.Values[ProfileCPUOnly].Images.Operator = "mirror.example/splunk-ai-operator@sha256:" + "a"
	in.Values[ProfileCPUOnly].Images.Slim = "mirror.example/slim@sha256:" + "b"
	in.Values[ProfileCPUOnly].Images.AgentRuntime.Base = "mirror.example/base@sha256:" + "c"
	in.Values[ProfileCPUOnly].Images.AgentRuntime.Providers = map[string]string{"mltk": "mirror.example/mltk@sha256:" + "d"}

	cpu := map[string]string{}
	for _, r := range InstallRefs(ProfileCPUOnly, in) {
		cpu[r.Component] = r.Ref
	}
	assert.Equal(t, "mirror.example/slim@sha256:b", cpu["slim"], "rendered values win for the runtime images")
	assert.Equal(t, "mirror.example/mltk@sha256:d", cpu["agent-runtime-provider-mltk"])
	assert.NotContains(t, cpu, "ray-head")
	assert.NotContains(t, cpu, "nvidia-device-plugin")
	assert.Contains(t, cpu, "fluent-bit")
	assert.Contains(t, cpu, "k0s-pause")

	full := map[string]string{}
	for _, r := range InstallRefs(ProfileFullFeature, in) {
		full[r.Component] = r.Ref
	}
	assert.Contains(t, full, "ray-head")
	assert.Contains(t, full, "nvidia-device-plugin")
}

func TestReadFile_ParsesAnInstallerConfigIgnoringKeysItDoesNotKnow(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(p, []byte(`
cluster: {name: x}
components: {kuberay: true}
images:
  registry: registry.example.internal
  operator: {image: "splunk/splunk-ai-operator:1"}
  ray: {headImage: "rayproject/ray:2.44.0"}
  agentRuntime:
    providerImages: {mltk: "splunk/provider-mltk:1"}
`), 0o644))
	var cfg InstallerConfig
	require.NoError(t, ReadFile(p, &cfg))
	assert.Equal(t, "splunk/splunk-ai-operator:1", cfg.Images.Operator.Image)
	assert.Equal(t, "rayproject/ray:2.44.0", cfg.Images.Ray.HeadImage)
	assert.Equal(t, "splunk/provider-mltk:1", cfg.Images.AgentRuntime.ProviderImages["mltk"])
}

func TestParseRef(t *testing.T) {
	cases := []struct {
		in   string
		want ParsedRef
	}{
		{"nginx:1.27", ParsedRef{"docker.io", "library/nginx", "1.27", ""}},
		{"docker.io/library/nginx:1.27-alpine", ParsedRef{"docker.io", "library/nginx", "1.27-alpine", ""}},
		{"splunk/ai-tier-slim-service:v1.0", ParsedRef{"docker.io", "splunk/ai-tier-slim-service", "v1.0", ""}},
		{"quay.io/kuberay/operator:v1.2.2", ParsedRef{"quay.io", "kuberay/operator", "v1.2.2", ""}},
		{"127.0.0.1:5000/a/b@sha256:" + hex64("1"), ParsedRef{"127.0.0.1:5000", "a/b", "", "sha256:" + hex64("1")}},
		{"658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/agent-runtime:202609221052-eae3b33005a5",
			ParsedRef{"658391232643.dkr.ecr.us-west-2.amazonaws.com", "ml-platform/agent-runtime", "202609221052-eae3b33005a5", ""}},
	}
	for _, c := range cases {
		got, err := ParseRef(c.in)
		require.NoError(t, err, c.in)
		assert.Equal(t, c.want, got, c.in)
	}
	_, err := ParseRef("not a reference!")
	assert.Error(t, err)
}

func hex64(c string) string {
	out := ""
	for i := 0; i < 64; i++ {
		out += c
	}
	return out
}

func TestMirrorRepository_KeepsTheSourceRegistryToAvoidCollisions(t *testing.T) {
	dockerHub, _ := ParseRef("docker.io/splunk/slim:1")
	quay, _ := ParseRef("quay.io/splunk/slim:1")
	assert.Equal(t, "mirror.example:5000/ai-tier/docker.io/splunk/slim", MirrorRepository("mirror.example:5000/ai-tier", dockerHub))
	assert.Equal(t, "mirror.example:5000/ai-tier/quay.io/splunk/slim", MirrorRepository("mirror.example:5000/ai-tier/", quay))
	assert.NotEqual(t, MirrorRepository("m", dockerHub), MirrorRepository("m", quay))

	local, _ := ParseRef("127.0.0.1:5000/a/b:1")
	assert.Equal(t, "m/127.0.0.1-5000/a/b", MirrorRepository("m", local), "a port's colon cannot appear in a repository name")
}
