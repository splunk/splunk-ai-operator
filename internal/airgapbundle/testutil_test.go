package airgapbundle

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

const (
	candidatePath = "../../config/agent-runtime/candidate-manifest.yaml"
	testMirror    = "mirror.airgap.local:5000/ai-tier"
)

// k0sImages and addonImages are what the fixture's image archives hold.
var (
	k0sImages   = []string{"quay.io/k0sproject/coredns:1.11.3", "registry.k8s.io/pause:3.9"}
	addonImages = []string{"quay.io/jetstack/cert-manager-controller:v1.13.0", "quay.io/kuberay/operator:v1.2.2"}
)

func digestOf(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "sha256:" + hex.EncodeToString(sum[:])
}

// fakeRegistry answers every lookup deterministically, as a registry that holds every
// image would, and records each reference it was asked about. Images listed in
// missing are absent from the mirror.
type fakeRegistry struct {
	mu        sync.Mutex
	Describes []string
	missing   map[string]bool // digest -> absent from the mirror
}

func (f *fakeRegistry) Describe(_ context.Context, ref string) (*imagesnapshot.Described, error) {
	f.mu.Lock()
	f.Describes = append(f.Describes, ref)
	f.mu.Unlock()
	d := digestOf(ref)
	if i := strings.Index(ref, "@"); i >= 0 {
		d = ref[i+1:]
		if f.missing[d] {
			return nil, fmt.Errorf("MANIFEST_UNKNOWN: manifest unknown")
		}
	}
	return &imagesnapshot.Described{Digest: d, PlatformDigests: map[string]string{imagesnapshot.Platform: d}}, nil
}

func (f *fakeRegistry) Copy(context.Context, string, string) error { return nil }

// fixture is a complete staged bundle for both profiles, the snapshot made from the
// same inventory, and the inputs that inventory is derived from.
type fixture struct {
	t        *testing.T
	dir      string // the staged bundle
	snapshot string // the snapshot's manifest.json
	snap     *imagesnapshot.Snapshot
	input    imagesnapshot.InventoryInput
	models   []Model
	reg      *fakeRegistry
}

func write(t *testing.T, p, body string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
	require.NoError(t, os.WriteFile(p, []byte(body), 0o644))
}

// ociArchive writes a tar holding an OCI layout whose index names each image, as
// `k0s airgap bundle-artifacts` does.
func ociArchive(t *testing.T, p string, refs []string) {
	t.Helper()
	type desc struct {
		MediaType   string            `json:"mediaType"`
		Digest      string            `json:"digest"`
		Size        int               `json:"size"`
		Annotations map[string]string `json:"annotations"`
	}
	var idx struct {
		SchemaVersion int    `json:"schemaVersion"`
		Manifests     []desc `json:"manifests"`
	}
	idx.SchemaVersion = 2
	for _, r := range refs {
		idx.Manifests = append(idx.Manifests, desc{MediaType: "application/vnd.oci.image.manifest.v1+json", Digest: digestOf("archive:" + r), Size: 100,
			Annotations: map[string]string{"io.containerd.image.name": r, "org.opencontainers.image.ref.name": r[strings.LastIndex(r, ":")+1:]}})
	}
	b, err := json.Marshal(idx)
	require.NoError(t, err)
	writeTar(t, p, map[string][]byte{"oci-layout": []byte(`{"imageLayoutVersion":"1.0.0"}`), "index.json": b})
}

func writeTar(t *testing.T, p string, entries map[string][]byte) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(p), 0o755))
	f, err := os.Create(p)
	require.NoError(t, err)
	defer f.Close()
	tw := tar.NewWriter(f)
	for _, name := range sortedNames(entries) {
		require.NoError(t, tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(entries[name])), Typeflag: tar.TypeReg}))
		_, err := tw.Write(entries[name])
		require.NoError(t, err)
	}
	require.NoError(t, tw.Close())
}

func sortedNames(m map[string][]byte) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	for i := range out {
		for j := i + 1; j < len(out); j++ {
			if out[j] < out[i] {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}

// stageBundle lays out a bundle exactly as airgap_install.sh does.
func stageBundle(t *testing.T, dir string) {
	t.Helper()
	write(t, filepath.Join(dir, "binaries/k0s"), "k0s binary")
	write(t, filepath.Join(dir, "binaries/k0s.version"), "v1.36.1+k0s.0\n")
	write(t, filepath.Join(dir, "binaries/yq"), "yq binary")
	ociArchive(t, filepath.Join(dir, "images/k0s-images.tar"), k0sImages)
	write(t, filepath.Join(dir, "images/k0s-images.list"), strings.Join(k0sImages, "\n")+"\n")
	ociArchive(t, filepath.Join(dir, "images/addon-images.tar"), addonImages)
	write(t, filepath.Join(dir, "images/addon-images.list"), strings.Join(addonImages, "\n")+"\n")
	write(t, filepath.Join(dir, "manifests/cert-manager.yaml"), "kind: List\n")
	write(t, filepath.Join(dir, "manifests/local-path-storage.yaml"), "kind: List\n")
	write(t, filepath.Join(dir, "manifests/nvidia-device-plugin.yml"), "kind: DaemonSet\n")
	write(t, filepath.Join(dir, "charts/kube-prometheus-stack-65.1.0.tgz"), "chart")
	write(t, filepath.Join(dir, "charts/kube-prometheus-stack.version"), "65.1.0\n")
	write(t, filepath.Join(dir, "charts/opentelemetry-operator-0.70.0.tgz"), "chart")
	write(t, filepath.Join(dir, "charts/kuberay-operator-1.2.2.tgz"), "chart")
	write(t, filepath.Join(dir, "charts/metallb-0.14.8.tgz"), "chart")
	write(t, filepath.Join(dir, "packages/nvidia-closure/repodata/repomd.xml"), "<repomd/>")
	write(t, filepath.Join(dir, "packages/nvidia-closure/nvidia-driver-550.rpm"), "rpm")
	write(t, filepath.Join(dir, "packages/nvidia-closure.manifest"), "kernels=5.14\n")
	write(t, filepath.Join(dir, "packages/pyyaml-6.0.2-cp311-manylinux_x86_64.whl"), "wheel")
	write(t, filepath.Join(dir, "packages/pyyaml.filename"), "pyyaml-6.0.2-cp311-manylinux_x86_64.whl\n")
	write(t, filepath.Join(dir, "bundle-versions.txt"), "k0s_version=v1.36.1+k0s.0\nkuberay_chart_version=1.2.2\n")
	write(t, filepath.Join(dir, "container-images.txt"), "# images to mirror\n")
	write(t, filepath.Join(dir, "checksums.sha256"), "deadbeef  binaries/k0s\n")
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	f := &fixture{t: t, dir: filepath.Join(root, "airgap-bundle-20261120-101500"), reg: &fakeRegistry{missing: map[string]bool{}}}
	stageBundle(t, f.dir)
	var err error
	f.input, err = imagesnapshot.LoadInput(imagesnapshot.InputFiles{Candidate: candidatePath,
		AddonList: filepath.Join(f.dir, "images/addon-images.list"), K0sList: filepath.Join(f.dir, "images/k0s-images.list")})
	require.NoError(t, err)
	inv, err := imagesnapshot.BuildInventory(f.input)
	require.NoError(t, err)
	f.snap, err = imagesnapshot.Create(context.Background(), f.reg, inv, imagesnapshot.Options{Mirror: testMirror, ID: "snap-1"})
	require.NoError(t, err)
	f.snapshot, _, err = (imagesnapshot.Store{Dir: filepath.Join(root, "snapshots")}).Put(f.snap)
	require.NoError(t, err)
	f.models = []Model{
		{ID: "all-minilm-l6-v2", Source: "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2"},
		{ID: "cross-encoder", Source: "https://huggingface.co/cross-encoder/ms-marco-MiniLM-L-6-v2", SHA256: strings.Repeat("c", 64)},
	}
	f.reg.Describes = nil
	return f
}

// build writes the bundle manifest and returns it.
func (f *fixture) build() *Manifest {
	f.t.Helper()
	m, err := Build(f.dir, BuildOptions{SnapshotPath: f.snapshot, Models: f.models})
	require.NoError(f.t, err)
	_, err = Write(f.dir, m)
	require.NoError(f.t, err)
	return m
}

// facts are the host facts of a healthy target: two CPU nodes and one GPU node, with
// every model staged.
func (f *fixture) facts() *HostFacts {
	h := &HostFacts{Nodes: []Node{
		{Name: "controller", Platform: "linux/amd64"},
		{Name: "cpu-1", Platform: "linux/amd64"},
		{Name: "gpu-1", Platform: "linux/amd64", GPU: &GPU{Driver: "550.54.15", Runtime: true, Allocatable: 2}},
	}}
	for _, m := range f.models {
		h.StagedModels = append(h.StagedModels, StagedModel{ID: m.ID, Source: m.Source, SHA256: m.SHA256})
	}
	return h
}

func (f *fixture) opts(profile string) VerifyOptions {
	return VerifyOptions{Profile: profile, Input: f.input, SnapshotPath: f.snapshot, Registry: f.reg, Facts: f.facts()}
}

func codes(findings []Finding) map[string]string { // component -> code
	out := map[string]string{}
	for _, f := range findings {
		out[f.Component] = f.Code
	}
	return out
}

func hasCode(findings []Finding, code string) bool {
	for _, f := range findings {
		if f.Code == code {
			return true
		}
	}
	return false
}
