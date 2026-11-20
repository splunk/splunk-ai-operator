package main

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"sigs.k8s.io/yaml"

	"github.com/splunk/splunk-ai-operator/internal/airgapbundle"
	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

const (
	candidate = "../../config/agent-runtime/candidate-manifest.yaml"
	mirror    = "mirror.airgap.local:5000/ai-tier"
)

func digestOf(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// mirrorRegistry stands in for the private mirror: it holds every image, except the
// digests in missing, and records every lookup.
type mirrorRegistry struct {
	missing   map[string]bool
	describes []string
}

func (r *mirrorRegistry) Describe(_ context.Context, ref string) (*imagesnapshot.Described, error) {
	r.describes = append(r.describes, ref)
	d := digestOf(ref)
	if i := strings.Index(ref, "@"); i >= 0 {
		d = ref[i+1:]
		if r.missing[d] {
			return nil, fmt.Errorf("MANIFEST_UNKNOWN: Bearer eyJsecret-token-value password=hunter2")
		}
	}
	return &imagesnapshot.Described{Digest: d, PlatformDigests: map[string]string{imagesnapshot.Platform: d}}, nil
}

func (r *mirrorRegistry) Copy(context.Context, string, string) error { return nil }

type env struct {
	t                  *testing.T
	dir, bundle, store string
	snapshot           string
	installConfig      string
	snap               *imagesnapshot.Snapshot
	reg                *mirrorRegistry
}

func (e *env) write(rel, body string) string {
	p := filepath.Join(e.dir, rel)
	require.NoError(e.t, os.MkdirAll(filepath.Dir(p), 0o755))
	require.NoError(e.t, os.WriteFile(p, []byte(body), 0o644))
	return p
}

func (e *env) archive(rel string, refs []string) {
	var idx struct {
		SchemaVersion int              `json:"schemaVersion"`
		Manifests     []map[string]any `json:"manifests"`
	}
	idx.SchemaVersion = 2
	for _, r := range refs {
		idx.Manifests = append(idx.Manifests, map[string]any{"mediaType": "application/vnd.oci.image.manifest.v1+json",
			"digest": digestOf(r), "size": 1, "annotations": map[string]string{"io.containerd.image.name": r}})
	}
	b, _ := json.Marshal(idx)
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	require.NoError(e.t, tw.WriteHeader(&tar.Header{Name: "index.json", Mode: 0o644, Size: int64(len(b)), Typeflag: tar.TypeReg}))
	_, _ = tw.Write(b)
	require.NoError(e.t, tw.Close())
	e.write(rel, buf.String())
}

func newEnv(t *testing.T) *env {
	e := &env{t: t, dir: t.TempDir(), reg: &mirrorRegistry{missing: map[string]bool{}}}
	e.bundle = filepath.Join(e.dir, "bundle")
	k0s := []string{"registry.k8s.io/pause:3.9"}
	addon := []string{"quay.io/kuberay/operator:v1.2.2"}
	for rel, body := range map[string]string{
		"bundle/binaries/k0s": "k0s", "bundle/binaries/yq": "yq", "bundle/binaries/airgap-bundle": "tool",
		"bundle/images/k0s-images.list": strings.Join(k0s, "\n") + "\n", "bundle/images/addon-images.list": strings.Join(addon, "\n") + "\n",
		"bundle/manifests/cert-manager.yaml": "x", "bundle/manifests/local-path-storage.yaml": "x", "bundle/manifests/nvidia-device-plugin.yml": "x",
		"bundle/charts/kube-prometheus-stack-65.1.0.tgz": "c", "bundle/charts/opentelemetry-operator-0.70.0.tgz": "c",
		"bundle/charts/kuberay-operator-1.2.2.tgz": "c", "bundle/charts/metallb-0.14.8.tgz": "c",
		"bundle/packages/nvidia-closure/a.rpm": "r", "bundle/packages/pyyaml-6.0.2.whl": "w",
	} {
		e.write(rel, body)
	}
	e.archive("bundle/images/k0s-images.tar", k0s)
	e.archive("bundle/images/addon-images.tar", addon)

	// The snapshot is made from the source installer configuration, which brings in the
	// installer's default images (Fluent Bit, OpenTelemetry, nginx) as an install would.
	in, err := imagesnapshot.LoadInput(imagesnapshot.InputFiles{Candidate: candidate, Config: e.write("source-config.yaml", "{}\n"),
		K0sList: filepath.Join(e.bundle, "images/k0s-images.list"), AddonList: filepath.Join(e.bundle, "images/addon-images.list")})
	require.NoError(t, err)
	inv, err := imagesnapshot.BuildInventory(in)
	require.NoError(t, err)
	e.snap, err = imagesnapshot.Create(context.Background(), e.reg, inv, imagesnapshot.Options{Mirror: mirror, ID: "snap-1"})
	require.NoError(t, err)
	e.snapshot, _, err = (imagesnapshot.Store{Dir: filepath.Join(e.dir, "snapshots")}).Put(e.snap)
	require.NoError(t, err)
	for _, name := range []string{"manifest.json", "manifest.json.sha256"} {
		b, err := os.ReadFile(filepath.Join(filepath.Dir(e.snapshot), name))
		require.NoError(t, err)
		e.write(filepath.Join("bundle/snapshot", name), string(b))
	}
	// The install configuration names every configured image by its mirror digest.
	cfg, err := imagesnapshot.InstallConfig(e.snap, in.Candidate.Spec.RuntimeVersion)
	require.NoError(t, err)
	b, err := yaml.Marshal(cfg)
	require.NoError(t, err)
	e.installConfig = e.write("install-config.yaml", string(b))
	e.write("models.yaml", "artifact-configs:\n  - artifact-id: all-minilm-l6-v2\n    hf-url: https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2\n")
	return e
}

func (e *env) run(args ...string) (int, string, string) {
	var out, errb bytes.Buffer
	code := run(args, &out, &errb, func(bool) imagesnapshot.Registry { return e.reg })
	return code, out.String(), errb.String()
}

func (e *env) facts(gpu bool, staged bool) string {
	f := airgapbundle.HostFacts{Nodes: []airgapbundle.Node{{Name: "cpu-1", Platform: "linux/amd64"}}}
	if gpu {
		f.Nodes = append(f.Nodes, airgapbundle.Node{Name: "gpu-1", Platform: "linux/amd64", GPU: &airgapbundle.GPU{Devices: 1, Driver: "550", Runtime: true}})
	}
	if staged {
		f.StagedModels = []airgapbundle.StagedModel{{ID: "all-minilm-l6-v2", Source: "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2"}}
	}
	b, _ := json.Marshal(f)
	return e.write(fmt.Sprintf("facts-%v-%v.json", gpu, staged), string(b))
}

func (e *env) verify(profile, facts string, extra ...string) (int, string, string) {
	return e.run(append([]string{"verify", "--bundle", e.bundle, "--profile", profile, "--snapshot", e.snapshot,
		"--candidate", candidate, "--config", e.installConfig, "--facts", facts}, extra...)...)
}

func TestEndToEnd_ManifestVerifyImport(t *testing.T) {
	e := newEnv(t)
	code, out, errs := e.run("manifest", "--bundle", e.bundle, "--snapshot", e.snapshot, "--model-config", filepath.Join(e.dir, "models.yaml"))
	require.Equal(t, 0, code, errs)
	assert.Regexp(t, `bundle snap-1-[0-9a-f]{12}: 18 files, 2 archive images, 1 model artifacts, snapshot snap-1`, out)
	require.FileExists(t, filepath.Join(e.bundle, airgapbundle.ManifestFile))

	// The staging-host check needs only the bundle.
	code, out, errs = e.run("verify", "--bundle", e.bundle, "--profile", "fullfeature", "--scope", "bundle")
	require.Equal(t, 0, code, errs)
	assert.Contains(t, out, "OK: bundle")

	// The install preflight, for each profile.
	code, _, errs = e.verify("cpuOnly", e.facts(false, false))
	require.Equal(t, 0, code, errs)
	code, _, errs = e.verify("fullfeature", e.facts(true, true))
	require.Equal(t, 0, code, errs)
	for _, ref := range e.reg.describes[len(e.reg.describes)-6:] {
		assert.True(t, strings.HasPrefix(ref, mirror+"/"), "the preflight looks only at the mirror: %s", ref)
	}

	// Import twice: the second is a no-op.
	dest := filepath.Join(e.dir, "imported")
	code, out, errs = e.run("import", "--from", e.bundle, "--to", dest)
	require.Equal(t, 0, code, errs)
	assert.Regexp(t, `imported at .* \(18 files copied, 0 reused`, out)
	code, out, _ = e.run("import", "--from", e.bundle, "--to", dest)
	require.Equal(t, 0, code)
	assert.Contains(t, out, "is already imported")
}

func TestVerify_FailuresAreNamedExitOneAndAreSanitized(t *testing.T) {
	e := newEnv(t)
	code, _, errs := e.run("manifest", "--bundle", e.bundle, "--snapshot", e.snapshot, "--model-config", filepath.Join(e.dir, "models.yaml"))
	require.Equal(t, 0, code, errs)
	for _, en := range e.snap.Spec.Entries {
		if en.Component == "slim" {
			e.reg.missing[en.Digest] = true
		}
	}
	require.NoError(t, os.Remove(filepath.Join(e.bundle, "charts/kuberay-operator-1.2.2.tgz")))
	report := filepath.Join(e.dir, "report.json")

	code, out, errs := e.verify("fullfeature", e.facts(false, false), "--report", report)
	assert.Equal(t, 1, code)
	assert.NotContains(t, out, "OK:")
	for _, want := range []string{
		"[BUNDLE_FILE_MISSING] charts/kuberay-operator-1.2.2.tgz",
		"[MIRROR_MISSING_IMAGE] slim",
		"[GPU_NODE_MISSING] host",
		"[MODEL_ARTIFACT_MISSING] model:all-minilm-l6-v2",
		"FAILED:", "nothing was changed",
	} {
		assert.Contains(t, errs, want)
	}
	assert.NotContains(t, errs, "eyJsecret")
	assert.NotContains(t, errs, "hunter2")

	var r struct{ Findings []airgapbundle.Finding }
	b, err := os.ReadFile(report)
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(b, &r))
	assert.Len(t, r.Findings, 4)
	assert.NotContains(t, string(b), "hunter2")
}

func TestImport_ARefusedImportExitsOne(t *testing.T) {
	e := newEnv(t)
	code, _, errs := e.run("manifest", "--bundle", e.bundle, "--snapshot", e.snapshot)
	require.Equal(t, 0, code, errs)
	e.write("bundle/binaries/yq", "tampered")
	code, _, errs = e.run("import", "--from", e.bundle, "--to", filepath.Join(e.dir, "imported"))
	assert.Equal(t, 1, code)
	assert.Contains(t, errs, "[BUNDLE_FILE_CHANGED] binaries/yq")
	assert.Contains(t, errs, "nothing was accepted")
	assert.NoDirExists(t, filepath.Join(e.dir, "imported", "snap-1"))
}

func TestUsageErrorsExitTwo(t *testing.T) {
	e := newEnv(t)
	for _, args := range [][]string{
		{},
		{"bogus"},
		{"manifest"},
		{"manifest", "--bundle", t.TempDir()}, // no --snapshot, and the bundle carries none
		{"verify", "--bundle", e.bundle},
		{"verify", "--bundle", e.bundle, "--profile", "gpuOnly"},
		{"verify", "--bundle", e.bundle, "--profile", "cpuOnly", "--scope", "everything"},
		{"verify", "--bundle", e.bundle, "--profile", "cpuOnly", "--facts", "/does/not/exist"},
		{"import", "--from", e.bundle},
		{"verify", "--bundle", e.bundle, "--profile", "cpuOnly", "stray-argument"},
	} {
		code, _, _ := e.run(args...)
		assert.Equal(t, 2, code, "%v", args)
	}
	// Facts with an unknown field are an input error, not silently ignored.
	bad := e.write("bad-facts.json", `{"nodes":[{"name":"a","platform":"linux/amd64","gpus":4}]}`)
	code, _, errs := e.run("verify", "--bundle", e.bundle, "--profile", "cpuOnly", "--facts", bad)
	assert.Equal(t, 2, code)
	assert.Contains(t, errs, "unknown field")
	code, out, _ := e.run("--help")
	assert.Equal(t, 0, code)
	assert.Contains(t, out, "commands:")
}

// MetalLB is required only when the installer configuration installs it.
func TestVerify_ReadsMetalLBInstallFromTheConfiguration(t *testing.T) {
	e := newEnv(t)
	require.NoError(t, os.Remove(filepath.Join(e.bundle, "charts/metallb-0.14.8.tgz")))
	code, _, errs := e.run("manifest", "--bundle", e.bundle, "--snapshot", e.snapshot)
	require.Equal(t, 0, code, errs)
	off := e.write("config-off.yaml", "metallb:\n  install: false\n")
	on := e.write("config-on.yaml", "metallb:\n  install: true\n")
	code, _, errs = e.run("verify", "--bundle", e.bundle, "--profile", "cpuOnly", "--scope", "bundle", "--config", off)
	assert.Equal(t, 0, code, errs)
	code, _, errs = e.run("verify", "--bundle", e.bundle, "--profile", "cpuOnly", "--scope", "bundle", "--config", on)
	assert.Equal(t, 1, code)
	assert.Contains(t, errs, "[REQUIRED_ARTIFACT_MISSING] chart:metallb")
}

// The install preflight refuses a configuration that does not name the mirror.
func TestVerify_WithoutTheInstallConfigurationFails(t *testing.T) {
	e := newEnv(t)
	code, _, errs := e.run("manifest", "--bundle", e.bundle, "--snapshot", e.snapshot)
	require.Equal(t, 0, code, errs)
	code, _, errs = e.run("verify", "--bundle", e.bundle, "--profile", "cpuOnly", "--snapshot", e.snapshot, "--candidate", candidate, "--facts", e.facts(false, false))
	assert.Equal(t, 1, code)
	assert.Contains(t, errs, "[INSTALL_CONFIG_MISSING] install-config")
}

// The bundle carries its snapshot, so manifest and verify need no --snapshot.
func TestTheBundlesOwnSnapshotIsTheDefault(t *testing.T) {
	e := newEnv(t)
	code, out, errs := e.run("manifest", "--bundle", e.bundle)
	require.Equal(t, 0, code, errs)
	assert.Contains(t, out, "snapshot snap-1")
	code, _, errs = e.run("verify", "--bundle", e.bundle, "--profile", "cpuOnly", "--candidate", candidate,
		"--config", e.installConfig, "--facts", e.facts(false, false))
	assert.Equal(t, 0, code, errs)
}
