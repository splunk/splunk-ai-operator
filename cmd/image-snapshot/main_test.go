package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/registry"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/random"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

type reg struct {
	t    *testing.T
	Host string
}

func newReg(t *testing.T) *reg {
	s := httptest.NewServer(registry.New())
	t.Cleanup(s.Close)
	return &reg{t, strings.TrimPrefix(s.URL, "http://")}
}

func (r *reg) push(repo, tag, arch string) string {
	img, err := random.Image(128, 1)
	require.NoError(r.t, err)
	cfg, _ := img.ConfigFile()
	cfg = cfg.DeepCopy()
	cfg.OS, cfg.Architecture = "linux", arch
	img, err = mutate.ConfigFile(img, cfg)
	require.NoError(r.t, err)
	ref, err := name.NewTag(r.Host + "/" + repo + ":" + tag)
	require.NoError(r.t, err)
	require.NoError(r.t, remote.Write(ref, img))
	d, _ := img.Digest()
	return d.String()
}

var _ v1.Image

// env is a candidate manifest whose four images live in a local source registry, an
// installer configuration, rendered values, and a mirror.
type env struct {
	t         *testing.T
	src, dst  *reg
	dir       string
	candidate string
	config    string
	cpuValues string
	fullValue string
	store     string
}

func newEnv(t *testing.T) *env {
	e := &env{t: t, src: newReg(t), dst: newReg(t), dir: t.TempDir()}
	e.store = filepath.Join(e.dir, "snapshots")

	// The real MPR-188 manifest, with its four image references repointed locally.
	raw, err := os.ReadFile("../../config/agent-runtime/candidate-manifest.yaml")
	require.NoError(t, err)
	local := []string{
		e.src.Host + "/ml-platform/agent-runtime:build-1",
		e.src.Host + "/ml-platform/agent-runtime-provider-mltk:build-1",
		e.src.Host + "/ml-platform/agent-runtime-schema-setup:build-1",
		e.src.Host + "/ml-platform/slim-api:v1",
	}
	i := 0
	manifest := regexp.MustCompile(`(?m)^(      image: ).*$`).ReplaceAllStringFunc(string(raw), func(m string) string {
		defer func() { i++ }()
		if i < len(local) {
			return "      image: " + local[i]
		}
		return m
	})
	require.Equal(t, len(local), i, "the manifest has four component images")
	e.candidate = filepath.Join(e.dir, "candidate-manifest.yaml")
	require.NoError(t, os.WriteFile(e.candidate, []byte(manifest), 0o644))
	for _, ref := range local {
		repo, tag, _ := strings.Cut(strings.TrimPrefix(ref, e.src.Host+"/"), ":")
		e.src.push(repo, tag, "amd64")
	}

	// Images outside the candidate set.
	e.src.push("splunk/splunk-ai-operator", "candidate-1", "amd64")
	e.src.push("rayproject/ray", "2.44.0", "amd64")
	e.src.push("semitechnologies/weaviate", "stable", "amd64")
	e.config = e.write("config.yaml", fmt.Sprintf(`
images:
  operator: {image: %[1]s/splunk/splunk-ai-operator:candidate-1}
  ray: {headImage: %[1]s/rayproject/ray:2.44.0, workerImage: %[1]s/rayproject/ray:2.44.0}
  weaviate: {image: %[1]s/semitechnologies/weaviate:stable}
`, e.src.Host))
	e.cpuValues = e.write("values-cpuonly.yaml", "profile: {effective: cpuOnly}\ncomponents: {aiOperator: true, kuberay: false, nvidia: false}\n")
	e.fullValue = e.write("values-fullfeature.yaml", "profile: {effective: fullfeature}\ncomponents: {aiOperator: true, kuberay: true, nvidia: true}\n")
	return e
}

// writeSnapshot writes a snapshot and its checksum file, as a stored one has, so a test can
// hand an edited copy to a command that insists on a checksum.
func (e *env) writeSnapshot(name string, snap *imagesnapshot.Snapshot) string {
	b, err := imagesnapshot.Marshal(snap)
	require.NoError(e.t, err)
	p := e.write(name, string(b))
	require.NoError(e.t, os.WriteFile(p+".sha256", []byte(imagesnapshot.Checksum(b)+"  "+name+"\n"), 0o644))
	return p
}

func (e *env) write(name, body string) string {
	p := filepath.Join(e.dir, name)
	require.NoError(e.t, os.WriteFile(p, []byte(body), 0o644))
	return p
}

func (e *env) inputs() []string {
	return []string{"--candidate", e.candidate, "--config", e.config, "--values-cpuonly", e.cpuValues, "--values-fullfeature", e.fullValue}
}

func (e *env) run(args ...string) (code int, stdout, stderr string) {
	var out, errb bytes.Buffer
	code = run(args, &out, &errb, func(insecure bool) imagesnapshot.Registry { return &imagesnapshot.Remote{Insecure: insecure} })
	e.record(args, code, out.String(), errb.String())
	return code, out.String(), errb.String()
}

// scrub replaces this environment's throwaway registry addresses with placeholders.
func (e *env) scrub(s string) string {
	return strings.NewReplacer(e.src.Host, "source.example:5000", e.dst.Host, "mirror.example:5000").Replace(s)
}

// record appends a command and its output to the file named by IMAGE_SNAPSHOT_EVIDENCE,
// with the throwaway registry addresses and paths replaced by placeholders. It is how
// the evidence in docs/agent-runtime/mpr-187-validation.md was captured; it does nothing
// unless the variable is set.
func (e *env) record(args []string, code int, stdout, stderr string) {
	path := os.Getenv("IMAGE_SNAPSHOT_EVIDENCE")
	if path == "" {
		return
	}
	scrub := strings.NewReplacer(e.src.Host, "source.example:5000", strings.ReplaceAll(e.src.Host, ":", "-"), "source.example-5000",
		e.dst.Host, "mirror.example:5000", strings.ReplaceAll(e.dst.Host, ":", "-"), "mirror.example-5000", e.dir, "<work>")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	require.NoError(e.t, err)
	defer f.Close()
	var inputs []string
	for _, a := range args {
		inputs = append(inputs, scrub.Replace(a))
	}
	fmt.Fprintf(f, "$ image-snapshot %s\n", strings.Join(inputs, " "))
	if stdout != "" {
		fmt.Fprint(f, scrub.Replace(stdout))
	}
	if stderr != "" {
		fmt.Fprint(f, scrub.Replace(stderr))
	}
	fmt.Fprintf(f, "(exit %d)\n\n", code)
}

func TestInventory_ListsTheImagesPerProfile(t *testing.T) {
	e := newEnv(t)
	code, out, errs := e.run(append([]string{"inventory", "--profile", "cpuOnly"}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	var inv imagesnapshot.Inventory
	require.NoError(t, json.Unmarshal([]byte(out), &inv))
	got := map[string]bool{}
	for _, i := range inv.Images {
		got[i.Component] = true
	}
	for _, want := range []string{"agent-runtime-base", "agent-runtime-provider-mltk", "agent-runtime-schema-setup", "slim", "splunk-ai-operator"} {
		assert.True(t, got[want], want)
	}
	assert.False(t, got["ray-head"], "cpuOnly has no Ray")
	assert.False(t, got["weaviate"])

	code, out, _ = e.run(append([]string{"inventory"}, e.inputs()...)...)
	require.Equal(t, 0, code)
	assert.Contains(t, out, `"ray-head"`, "without --profile both profiles are listed")
}

// The whole flow: create, preflight, compare, refresh, and the negative cases, with
// real exit codes.
func TestEndToEnd_CreateVerifyCompareAndRefresh(t *testing.T) {
	e := newEnv(t)
	mirror := e.dst.Host + "/ai-tier"

	// create
	code, out, errs := e.run(append([]string{"create", "--mirror", mirror, "--store", e.store, "--id", "run-1"}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	assert.Contains(t, out, "verified")
	assert.Regexp(t, `digest\s+sha256:[0-9a-f]{64}`, out, "the log shows the pinned digest of each image")
	assert.Contains(t, out, "platforms linux/amd64")
	assert.Regexp(t, `mirror\s+mirror\.example`, e.scrub(out), "and where it was mirrored")
	assert.Contains(t, out, "snapshot run-1:")
	assert.NotContains(t, out+errs, "password")
	manifest := filepath.Join(e.store, "run-1", "manifest.json")
	require.FileExists(t, manifest)
	require.FileExists(t, manifest+".sha256")

	// The same ID is refused: snapshots are never rewritten.
	code, _, errs = e.run(append([]string{"create", "--mirror", mirror, "--store", e.store, "--id", "run-1"}, e.inputs()...)...)
	assert.Equal(t, 2, code)
	assert.Contains(t, errs, "already exists")

	// verify: ok for both profiles
	for _, p := range []string{"cpuOnly", "fullfeature"} {
		code, out, errs = e.run(append([]string{"verify", "--store", e.store, "--id", "run-1", "--profile", p}, e.inputs()...)...)
		require.Equal(t, 0, code, errs)
		assert.Contains(t, out, "OK:")
	}

	// verify fails and names the component when the mirror is missing an image: point
	// a copy of the snapshot at a digest the mirror never received.
	snap, err := imagesnapshot.ReadSnapshot(manifest)
	require.NoError(t, err)
	for i := range snap.Spec.Entries {
		if snap.Spec.Entries[i].Component == "slim" {
			snap.Spec.Entries[i].MirrorRef = e.dst.Host + "/ai-tier/never/pushed@" + snap.Spec.Entries[i].Digest
		}
	}
	broken := e.writeSnapshot("broken.json", snap)
	code, _, errs = e.run(append([]string{"verify", "--snapshot", broken, "--profile", "cpuOnly"}, e.inputs()...)...)
	assert.Equal(t, 1, code)
	assert.Contains(t, errs, "[MIRROR_MISSING_IMAGE] slim")
	assert.Contains(t, errs, "FAILED:")

	// compare: an install that uses the mirror references is accounted for...
	var s imagesnapshot.Snapshot
	require.NoError(t, json.Unmarshal(mustRead(t, manifest), &s))
	slimMirror := entry(&s, "slim").MirrorRef
	values := e.write("values-mirrored.yaml", "profile: {effective: cpuOnly}\ncomponents: {aiOperator: true, kuberay: false, nvidia: false}\nimages:\n  slim: \""+slimMirror+"\"\n")
	code, out, errs = e.run("compare", "--store", e.store, "--id", "run-1", "--profile", "cpuOnly",
		"--candidate", e.candidate, "--config", e.config, "--values-cpuonly", values)
	require.Equal(t, 0, code, errs)
	assert.Contains(t, out, "OK:")
	// ...and one that uses an unknown image is named.
	rogue := e.write("values-rogue.yaml", "profile: {effective: cpuOnly}\ncomponents: {aiOperator: true, kuberay: false, nvidia: false}\nimages:\n  slim: \"docker.io/library/busybox:latest\"\n")
	code, _, errs = e.run("compare", "--store", e.store, "--id", "run-1", "--profile", "cpuOnly",
		"--candidate", e.candidate, "--config", e.config, "--values-cpuonly", rogue)
	assert.Equal(t, 1, code)
	assert.Contains(t, errs, "[UNACCOUNTED_REFERENCE] slim")

	// refresh: replace SLIM's candidate tag with a new build.
	e.src.push("ml-platform/slim-api", "v2", "amd64")
	raw := string(mustRead(t, e.candidate))
	next := e.write("candidate-2.yaml", strings.Replace(raw, "/ml-platform/slim-api:v1", "/ml-platform/slim-api:v2", 1))
	args := []string{"refresh", "--store", e.store, "--previous", "run-1", "--id", "run-2", "--candidate", next,
		"--config", e.config, "--values-cpuonly", e.cpuValues, "--values-fullfeature", e.fullValue}
	code, out, errs = e.run(args...)
	require.Equal(t, 0, code, errs)
	assert.Regexp(t, `changed\s+slim\s+candidate reference replaced\s+sha256:[0-9a-f]+ -> sha256:[0-9a-f]+`, out)
	assert.Contains(t, out, "MPR-190 cpuOnly install job")
	assert.Contains(t, out, "MPR-213 fullfeature on Ubuntu 24.04")
	assert.NotContains(t, out, "changed   agent-runtime-base", "only the replaced image changed")
	require.FileExists(t, filepath.Join(e.store, "run-2", "manifest.json"))

	// the earlier snapshot is untouched, and the new one names it
	again, err := imagesnapshot.ReadSnapshot(manifest)
	require.NoError(t, err, "run-1 still matches its checksum")
	assert.Equal(t, s.Spec.Entries, again.Spec.Entries)
	refreshed, err := (imagesnapshot.Store{Dir: e.store}).Get("run-2")
	require.NoError(t, err)
	assert.Equal(t, "run-1", refreshed.Metadata.Predecessor)

	// refreshing an unchanged candidate changes nothing
	code, out, _ = e.run("refresh", "--store", e.store, "--previous", "run-2", "--id", "run-3", "--candidate", next,
		"--config", e.config, "--values-cpuonly", e.cpuValues, "--values-fullfeature", e.fullValue)
	assert.Equal(t, 0, code)
	assert.Contains(t, out, "no change")
	assert.NoFileExists(t, filepath.Join(e.store, "run-3", "manifest.json"))

	// an unavailable replacement is an external blocker: exit 1, nothing stored
	missing := e.write("candidate-3.yaml", strings.Replace(raw, "/ml-platform/slim-api:v1", "/ml-platform/slim-api:not-built", 1))
	report := filepath.Join(e.dir, "blockers.json")
	code, _, errs = e.run("refresh", "--store", e.store, "--previous", "run-2", "--id", "run-4", "--candidate", missing,
		"--config", e.config, "--values-cpuonly", e.cpuValues, "--values-fullfeature", e.fullValue, "--report", report)
	assert.Equal(t, 1, code)
	assert.Contains(t, errs, "external blockers")
	assert.Contains(t, errs, "slim")
	assert.NoFileExists(t, filepath.Join(e.store, "run-4", "manifest.json"))
	assert.Contains(t, string(mustRead(t, report)), `"component": "slim"`)
}

func TestCreate_ABlockedImageStoresNothingAndCopiesNothing(t *testing.T) {
	e := newEnv(t)
	e.src.push("splunk/arm-only", "v1", "arm64")
	cfg := e.write("config-arm.yaml", fmt.Sprintf("images:\n  operator: {image: %s/splunk/arm-only:v1}\n  weaviate: {image: %s/not/there:v1}\n", e.src.Host, e.src.Host))
	report := filepath.Join(e.dir, "report.json")
	code, _, errs := e.run("create", "--mirror", e.dst.Host, "--store", e.store, "--candidate", e.candidate, "--config", cfg,
		"--values-fullfeature", e.fullValue, "--report", report)
	assert.Equal(t, 1, code)
	assert.Contains(t, errs, "splunk-ai-operator")
	assert.Contains(t, errs, "incompatible: no linux/amd64 image")
	assert.Contains(t, errs, "weaviate")
	assert.Contains(t, errs, "unresolved")
	assert.NoDirExists(t, e.store)
	assert.FileExists(t, report)
}

func TestCreate_ResolveOnlyStoresNothing(t *testing.T) {
	e := newEnv(t)
	code, out, errs := e.run(append([]string{"create", "--resolve-only", "--mirror", e.dst.Host, "--store", e.store}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	assert.Contains(t, out, "nothing copied, nothing stored")
	assert.NoDirExists(t, e.store)
}

func TestUsageErrorsExitTwo(t *testing.T) {
	e := newEnv(t)
	for name, args := range map[string][]string{
		"no command":                   {},
		"unknown command":              {"frobnicate"},
		"create without mirror":        append([]string{"create", "--store", e.store}, e.inputs()...),
		"verify without profile":       append([]string{"verify", "--store", e.store, "--id", "x"}, e.inputs()...),
		"verify bad profile":           append([]string{"verify", "--store", e.store, "--id", "x", "--profile", "full"}, e.inputs()...),
		"verify no snapshot":           append([]string{"verify", "--profile", "cpuOnly"}, e.inputs()...),
		"missing candidate file":       {"inventory", "--candidate", filepath.Join(e.dir, "nope.yaml")},
		"values for the wrong profile": {"inventory", "--candidate", e.candidate, "--values-cpuonly", e.fullValue},
	} {
		code, _, _ := e.run(args...)
		assert.Equal(t, 2, code, name)
	}
	code, out, _ := e.run("help")
	assert.Equal(t, 0, code)
	assert.Contains(t, out, "usage: image-snapshot")
}

func mustRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	require.NoError(t, err)
	return b
}

func entry(s *imagesnapshot.Snapshot, component string) imagesnapshot.Entry {
	for _, e := range s.Spec.Entries {
		if e.Component == component {
			return e
		}
	}
	panic("no entry " + component)
}

// Owners and the add-on and k0s lists are read from files; comments and blank lines in
// the lists are ignored.
func TestInventory_ReadsOwnersAndTheAddonAndK0sLists(t *testing.T) {
	e := newEnv(t)
	e.src.push("jetstack/cert-manager-controller", "v1.13.0", "amd64")
	addons := e.write("addon-images.list", "# add-ons\n\n"+e.src.Host+"/jetstack/cert-manager-controller:v1.13.0\n")
	k0s := e.write("k0s-images.list", e.src.Host+"/k0sproject/pause:3.9\n\n")
	owners := e.write("owners.yaml", "slim: slim-team\nweaviate: data-team\n")

	code, out, errs := e.run(append([]string{"inventory", "--addon-list", addons, "--k0s-list", k0s, "--owners", owners}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	var inv imagesnapshot.Inventory
	require.NoError(t, json.Unmarshal([]byte(out), &inv))
	byComponent := map[string]imagesnapshot.Image{}
	for _, i := range inv.Images {
		byComponent[i.Component] = i
	}
	assert.Equal(t, "slim-team", byComponent["slim"].Owner)
	assert.Equal(t, "data-team", byComponent["weaviate"].Owner)
	assert.Contains(t, byComponent, "cert-manager")
	assert.Equal(t, "addon-list", byComponent["cert-manager"].Origin)
	assert.Contains(t, byComponent, "k0s-pause")
	assert.Equal(t, imagesnapshot.CategoryKubernetes, byComponent["k0s-pause"].Category)
	assert.Len(t, inv.Images, 8+2, "no entry is made from a comment or a blank line")
}

// Add-on and k0s images are resolved, mirrored and verified like every other image.
func TestCreate_MirrorsAddonAndK0sImagesToo(t *testing.T) {
	e := newEnv(t)
	e.src.push("jetstack/cert-manager-controller", "v1.13.0", "amd64")
	e.src.push("k0sproject/pause", "3.9", "amd64")
	addons := e.write("addon-images.list", e.src.Host+"/jetstack/cert-manager-controller:v1.13.0\n")
	k0s := e.write("k0s-images.list", e.src.Host+"/k0sproject/pause:3.9\n")

	code, out, errs := e.run(append([]string{"create", "--mirror", e.dst.Host, "--store", e.store, "--id", "full",
		"--addon-list", addons, "--k0s-list", k0s}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	assert.Contains(t, out, "cert-manager")
	assert.Contains(t, out, "k0s-pause")
	snap, err := (imagesnapshot.Store{Dir: e.store}).Get("full")
	require.NoError(t, err)
	assert.Len(t, snap.Spec.Entries, 10)
	for _, en := range snap.Spec.Entries {
		assert.Equal(t, imagesnapshot.StatusVerified, en.Status, en.Component)
	}
}

// A snapshot that was edited after it was written is refused by every command that
// reads it, before anything else runs.
func TestACommandRefusesATamperedSnapshot(t *testing.T) {
	e := newEnv(t)
	code, _, errs := e.run(append([]string{"create", "--mirror", e.dst.Host, "--store", e.store, "--id", "run-1"}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	manifest := filepath.Join(e.store, "run-1", "manifest.json")
	require.NoError(t, os.WriteFile(manifest, []byte(strings.Replace(string(mustRead(t, manifest)), `"owner": "unassigned"`, `"owner": "mallory"`, 1)), 0o644))

	for _, args := range [][]string{
		{"verify", "--store", e.store, "--id", "run-1", "--profile", "cpuOnly"},
		{"compare", "--store", e.store, "--id", "run-1", "--profile", "cpuOnly"},
		{"refresh", "--store", e.store, "--previous", "run-1", "--id", "run-2"},
	} {
		code, _, errs := e.run(append(args, e.inputs()...)...)
		assert.Equal(t, 2, code, args[0])
		assert.Contains(t, errs, "does not match its checksum file", args[0])
	}
}

// The CLI path for a moved tag: nothing changes until --recheck-tags is given.
func TestRefresh_RecheckTagsThroughTheCLI(t *testing.T) {
	e := newEnv(t)
	code, _, errs := e.run(append([]string{"create", "--mirror", e.dst.Host, "--store", e.store, "--id", "run-1"}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	moved := e.src.push("ml-platform/slim-api", "v1", "amd64") // the same tag now points at a new image

	refresh := func(id string, extra ...string) (int, string, string) {
		return e.run(append(append([]string{"refresh", "--store", e.store, "--previous", "run-1", "--id", id}, e.inputs()...), extra...)...)
	}
	code, out, _ := refresh("run-2")
	assert.Equal(t, 0, code)
	assert.Contains(t, out, "no change", "without --recheck-tags a moved tag is not noticed")

	code, out, errs = refresh("run-3", "--recheck-tags")
	require.Equal(t, 0, code, errs)
	assert.Regexp(t, `changed\s+slim\s+tag moved to a different digest`, out)
	snap, err := (imagesnapshot.Store{Dir: e.store}).Get("run-3")
	require.NoError(t, err)
	for _, en := range snap.Spec.Entries {
		if en.Component == "slim" {
			assert.Equal(t, moved, en.Digest)
			assert.NotEmpty(t, en.PreviousDigest)
		}
	}
}

// A snapshot ID that already exists is refused before any image is copied, so it cannot
// waste a long mirror run; the same goes for an unusable ID.
func TestCreate_AnExistingOrUnusableIDIsRefusedBeforeAnythingIsCopied(t *testing.T) {
	e := newEnv(t)
	code, _, errs := e.run(append([]string{"create", "--mirror", e.dst.Host, "--store", e.store, "--id", "run-1"}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)

	fresh := newReg(t) // a second, empty mirror: it must stay empty
	code, _, errs = e.run(append([]string{"create", "--mirror", fresh.Host, "--store", e.store, "--id", "run-1"}, e.inputs()...)...)
	assert.Equal(t, 2, code)
	assert.Contains(t, errs, "already exists")
	assert.Equal(t, 0, catalogSize(t, fresh), "nothing was copied to the new mirror")

	for _, bad := range []string{"../escape", "a/b", ".hidden", "with space"} {
		code, _, errs = e.run(append([]string{"create", "--mirror", fresh.Host, "--store", e.store, "--id", bad}, e.inputs()...)...)
		assert.Equal(t, 2, code, bad)
		assert.Contains(t, errs, "not usable as a directory name", bad)
	}
	assert.Equal(t, 0, catalogSize(t, fresh))
}

func catalogSize(t *testing.T, r *reg) int {
	t.Helper()
	resp, err := http.Get("http://" + r.Host + "/v2/_catalog")
	require.NoError(t, err)
	defer resp.Body.Close()
	var body struct {
		Repositories []string `json:"repositories"`
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&body))
	return len(body.Repositories)
}

// A comparison that has nothing to compare is not a pass.
func TestCompare_WithNoInstallReferencesIsNotAPass(t *testing.T) {
	e := newEnv(t)
	code, _, errs := e.run(append([]string{"create", "--mirror", e.dst.Host, "--store", e.store, "--id", "run-1"}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	code, out, errs := e.run("compare", "--store", e.store, "--id", "run-1", "--profile", "cpuOnly", "--candidate", e.candidate)
	assert.Equal(t, 2, code)
	assert.NotContains(t, out, "OK:")
	assert.Contains(t, errs, "no install references to check for cpuOnly")
}

// A snapshot without its checksum file cannot be trusted by any command.
func TestACommandRefusesASnapshotWithoutItsChecksumFile(t *testing.T) {
	e := newEnv(t)
	code, _, errs := e.run(append([]string{"create", "--mirror", e.dst.Host, "--store", e.store, "--id", "run-1"}, e.inputs()...)...)
	require.Equal(t, 0, code, errs)
	manifest := filepath.Join(e.store, "run-1", "manifest.json")
	require.NoError(t, os.Remove(manifest+".sha256"))

	code, _, errs = e.run(append([]string{"verify", "--store", e.store, "--id", "run-1", "--profile", "cpuOnly"}, e.inputs()...)...)
	assert.Equal(t, 2, code)
	assert.Contains(t, errs, "has no checksum file")
	code, _, errs = e.run(append([]string{"verify", "--snapshot", manifest, "--profile", "cpuOnly"}, e.inputs()...)...)
	assert.Equal(t, 2, code)
	assert.Contains(t, errs, "has no checksum file")
	code, _, errs = e.run(append([]string{"verify", "--store", e.store, "--id", "../../etc", "--profile", "cpuOnly"}, e.inputs()...)...)
	assert.Equal(t, 2, code)
	assert.Contains(t, errs, "not usable as a directory name", "an ID cannot reach outside the store")
}

// A report that cannot be written is a warning, never the exit code of the command.
func TestCreate_AReportThatCannotBeWrittenDoesNotChangeTheExitCode(t *testing.T) {
	e := newEnv(t)
	e.src.push("splunk/arm-only", "v1", "arm64")
	cfg := e.write("config-arm.yaml", fmt.Sprintf("images:\n  operator: {image: %s/splunk/arm-only:v1}\n", e.src.Host))
	code, _, errs := e.run("create", "--mirror", e.dst.Host, "--store", e.store, "--candidate", e.candidate, "--config", cfg,
		"--values-fullfeature", e.fullValue, "--report", filepath.Join(e.dir, "no", "such", "dir", "report.json"))
	assert.Equal(t, 1, code, "still the blocked-snapshot status, not a file error")
	assert.Contains(t, errs, "warning: could not write the report")
	assert.Contains(t, errs, "incompatible: no linux/amd64 image")
}
