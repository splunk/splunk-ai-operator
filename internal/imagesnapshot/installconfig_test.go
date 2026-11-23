package imagesnapshot

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"sigs.k8s.io/yaml"
)

const fakeMirror = "mirror.airgap.local:5000/ai-tier"

// verifiedSnapshot turns an inventory into a stored-quality snapshot without a registry:
// every image resolved to a digest of its own and mirrored under fakeMirror.
func verifiedSnapshot(t *testing.T, inv *Inventory, mirror string) *Snapshot {
	t.Helper()
	snap := newSnapshot(inv, Options{ID: "snap-cfg", Mirror: mirror})
	for _, img := range inv.Images {
		p, err := ParseRef(img.Source)
		require.NoError(t, err, img.Source)
		d := "sha256:" + Checksum([]byte(img.Source))
		snap.Spec.Entries = append(snap.Spec.Entries, Entry{Image: img, SourceDigest: d, Digest: d,
			Platforms: []string{Platform}, Status: StatusVerified,
			MirrorRef: MirrorRepository(mirror, p) + "@" + d})
	}
	require.NoError(t, Validate(snap))
	return snap
}

func get(m map[string]any, path ...string) any {
	var cur any = m
	for _, k := range path {
		mm, ok := cur.(map[string]any)
		if !ok {
			return nil
		}
		cur = mm[k]
	}
	return cur
}

func TestInstallConfig_SetsEverySettingAnEntryCameFromToItsMirrorReference(t *testing.T) {
	in := pinsInput(t, true)
	in.Installer.Splunk.Enabled = true
	in.Installer.Images.Operator.Image = "docker.io/splunk/splunk-ai-operator:c1"
	in.Installer.Images.Ray.HeadImage = "docker.io/rayproject/ray:2.44.0"
	in.Installer.Images.Ray.WorkerImage = "docker.io/rayproject/ray-worker:2.44.0"
	in.Installer.Images.Weaviate.Image = "docker.io/semitechnologies/weaviate:1"
	in.Installer.Images.Saia.APIImage = "docker.io/splunk/saia-api:1"
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	snap := verifiedSnapshot(t, inv, fakeMirror)
	cfg, err := InstallConfig(snap, in.Candidate.Spec.RuntimeVersion)
	require.NoError(t, err)

	ref := func(component string) string {
		for _, e := range snap.Spec.Entries {
			if e.Component == component {
				return e.MirrorRef
			}
		}
		t.Fatalf("no entry %s", component)
		return ""
	}
	for path, component := range map[string]string{
		"images.operator.image":                   "splunk-ai-operator",
		"images.ray.headImage":                    "ray-head",
		"images.ray.workerImage":                  "ray-worker",
		"images.weaviate.image":                   "weaviate",
		"images.saia.apiImage":                    "saia-api",
		"images.nginx.image":                      "nginx",
		"images.fluentBit.image":                  "fluent-bit",
		"images.otelCollector.image":              "otel-collector",
		"images.splunk.operatorImage":             "splunk-operator",
		"images.slim.apiImage":                    "slim",
		"images.agentRuntime.baseImage":           "agent-runtime-base",
		"images.agentRuntime.schemaSetupImage":    "agent-runtime-schema-setup",
		"images.agentRuntime.providerImages.mltk": "agent-runtime-provider-mltk",
		"images.agentRuntime.providerImages.seca": "agent-runtime-provider-seca",
		"images.agentRuntime.baseImages.v1.9.0":   "agent-runtime-base-v1-9-0",
		"images.agentRuntime.baseImages.v2.0.0":   "agent-runtime-base", // the candidate's own version
	} {
		assert.Equal(t, ref(component), get(cfg, splitSetting(path)...), path)
	}
	for _, v := range []any{get(cfg, "images", "operator", "image"), get(cfg, "images", "agentRuntime", "baseImages", "v1.9.0")} {
		assert.Contains(t, v, "@sha256:", "every setting is digest-pinned")
		assert.True(t, strings.HasPrefix(v.(string), fakeMirror+"/"), "and in the mirror")
	}
	assert.Equal(t, "mirror.airgap.local:5000", get(cfg, "images", "registry"),
		"images.registry names the mirror host, so the installer configures the nodes for it")
}

// Generate then enforce: an installer configuration with the generated settings is
// accounted for by compare in both profiles, read the way the installer reads it.
func TestInstallConfig_RoundTripsThroughCompareForBothProfiles(t *testing.T) {
	in := pinsInput(t, false)
	in.Installer.Splunk.Enabled = true
	in.Installer.Images.Operator.Image = "docker.io/splunk/splunk-ai-operator:c1"
	in.Installer.Images.Ray.HeadImage = "docker.io/rayproject/ray:2.44.0"
	in.Installer.Images.Weaviate.Image = "docker.io/semitechnologies/weaviate:1"
	in.AddonRefs, in.K0sRefs = nil, nil
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	snap := verifiedSnapshot(t, inv, fakeMirror)
	cfg, err := InstallConfig(snap, in.Candidate.Spec.RuntimeVersion)
	require.NoError(t, err)

	cfg["splunk"] = map[string]any{"enabled": true}
	b, err := yaml.Marshal(cfg)
	require.NoError(t, err)
	p := filepath.Join(t.TempDir(), "install.yaml")
	require.NoError(t, os.WriteFile(p, b, 0o644))
	installIn, err := LoadInput(InputFiles{Candidate: candidatePath, Config: p})
	require.NoError(t, err)
	for _, profile := range Profiles {
		refs := InstallRefs(profile, installIn)
		require.NotEmpty(t, refs, profile)
		assert.Empty(t, Compare(snap, profile, refs), "%s: every reference is the component's mirror digest", profile)
	}
}

func TestInstallConfig_Refusals(t *testing.T) {
	in := pinsInput(t, true)
	inv, err := BuildInventory(in)
	require.NoError(t, err)

	t.Run("a mirror host the installer would prefix", func(t *testing.T) {
		snap := verifiedSnapshot(t, inv, "localhost:5000/ai-tier")
		_, err := InstallConfig(snap, "v2.0.0")
		assert.ErrorContains(t, err, "would be prefixed with images.registry")
	})
	t.Run("an incomplete snapshot", func(t *testing.T) {
		snap := verifiedSnapshot(t, inv, fakeMirror)
		snap.Spec.Entries[0].Status = StatusBlocked
		_, err := InstallConfig(snap, "v2.0.0")
		assert.Error(t, err)
	})
	t.Run("only archive images", func(t *testing.T) {
		snap := verifiedSnapshot(t, inventoryOf(Image{Component: "k0s-pause", Source: "registry.k8s.io/pause:3.9", Origin: "k0s-list", Profiles: Profiles, Owner: "unassigned"}), fakeMirror)
		_, err := InstallConfig(snap, "")
		assert.ErrorContains(t, err, "has no image the installer configures")
	})
	t.Run("two images for one setting", func(t *testing.T) {
		snap := verifiedSnapshot(t, inv, fakeMirror)
		for i := range snap.Spec.Entries {
			if snap.Spec.Entries[i].Component == "agent-runtime-base-v1-9-0" {
				snap.Spec.Entries[i].Origin = "installer-config:images.agentRuntime.baseImages.v2.0.0"
			}
		}
		_, err := InstallConfig(snap, "v2.0.0")
		assert.ErrorContains(t, err, "images.agentRuntime.baseImages.v2.0.0 would be both")
	})
}

func TestSplitSetting_KeepsDottedVersionsWhole(t *testing.T) {
	assert.Equal(t, []string{"images", "agentRuntime", "baseImages", "v1.9.0-rc.1"}, splitSetting("images.agentRuntime.baseImages.v1.9.0-rc.1"))
	assert.Equal(t, []string{"images", "agentRuntime", "providerImages", "mltk"}, splitSetting("images.agentRuntime.providerImages.mltk"))
	assert.Equal(t, []string{"images", "ray", "headImage"}, splitSetting("images.ray.headImage"))
}

func TestMirrorHost(t *testing.T) {
	assert.Equal(t, "10.0.39.38:5099", MirrorHost("10.0.39.38:5099/ai-tier"))
	assert.Equal(t, "mirror.example.com", MirrorHost("mirror.example.com"))
	assert.Equal(t, "mirror.example.com:443", MirrorHost(" mirror.example.com:443/a/b "))
}
