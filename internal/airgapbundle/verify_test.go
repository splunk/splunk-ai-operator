package airgapbundle

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

var ctx = context.Background()

func TestVerify_ACompleteBundlePassesForBothProfilesInBothScopes(t *testing.T) {
	f := newFixture(t)
	f.build()
	for _, profile := range imagesnapshot.Profiles {
		o := f.opts(profile)
		assert.Empty(t, Verify(ctx, f.dir, o), "%s install", profile)
		o.Scope = ScopeBundle
		o.Facts, o.SnapshotPath = nil, ""
		assert.Empty(t, Verify(ctx, f.dir, o), "%s bundle", profile)
	}
}

// The preflight never reaches outside the private mirror: every registry lookup it
// makes is a digest reference in the mirror.
func TestVerify_LooksOnlyAtTheMirrorAndOnlyByDigest(t *testing.T) {
	f := newFixture(t)
	f.build()
	require.Empty(t, Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileFullFeature)))
	require.NotEmpty(t, f.reg.Describes)
	for _, ref := range f.reg.Describes {
		assert.True(t, strings.HasPrefix(ref, testMirror+"/"), "looked up %s outside the mirror", ref)
		assert.Contains(t, ref, "@sha256:", "looked up %s by tag", ref)
	}
}

// ---- the three negative checks the story names: one image, one binary or chart, one model ----

func TestVerify_AnImageMissingFromTheMirrorFailsBeforeInstallWithNoPublicPull(t *testing.T) {
	f := newFixture(t)
	f.build()
	var slim imagesnapshot.Entry
	for _, e := range f.snap.Spec.Entries {
		if e.Component == "slim" {
			slim = e
		}
	}
	f.reg.missing[slim.Digest] = true

	got := Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly))
	assert.Equal(t, map[string]string{"slim": imagesnapshot.FindingMissingImage}, codes(got))
	for _, ref := range f.reg.Describes {
		assert.True(t, strings.HasPrefix(ref, testMirror+"/"), "no lookup outside the mirror, not even for the missing image: %s", ref)
	}
}

func TestVerify_AnImageMissingFromItsArchiveIsNamed(t *testing.T) {
	f := newFixture(t)
	// The archive lost the KubeRay operator image; its list still names it.
	ociArchive(t, filepath.Join(f.dir, "images/addon-images.tar"), addonImages[:1])
	f.build()
	got := Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileFullFeature))
	assert.Equal(t, map[string]string{"quay.io/kuberay/operator:v1.2.2": FindingArchiveImage}, codes(got))
	assert.Contains(t, got[0].Message, "images/addon-images.tar does not hold it")
}

func TestVerify_AMissingBinaryOrChartFailsWithItsName(t *testing.T) {
	t.Run("a binary removed after the manifest was made", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		require.NoError(t, os.Remove(filepath.Join(f.dir, "binaries/k0s")))
		got := Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly))
		assert.Equal(t, map[string]string{"binaries/k0s": FindingFileMissing}, codes(got))
		assert.Contains(t, got[0].Message, "the binary k0s is listed but absent")
	})
	t.Run("a chart the bundle never had", func(t *testing.T) {
		f := newFixture(t)
		require.NoError(t, os.Remove(filepath.Join(f.dir, "charts/kuberay-operator-1.2.2.tgz")))
		f.build()
		got := Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileFullFeature))
		assert.Equal(t, map[string]string{"chart:kuberay-operator": FindingArtifactMissing}, codes(got))
		assert.Contains(t, got[0].Message, "the kuberay component is installed for fullfeature")
		assert.Contains(t, got[0].Message, "no download fallback")
		// cpuOnly never installs KubeRay, so it does not need the chart.
		assert.Empty(t, Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)))
	})
}

func TestVerify_AMissingModelArtifactFailsFullfeatureOnly(t *testing.T) {
	t.Run("not staged", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		o.Facts.StagedModels = o.Facts.StagedModels[1:]
		assert.Equal(t, map[string]string{"model:all-minilm-l6-v2": FindingModelMissing}, codes(Verify(ctx, f.dir, o)))
		o.Profile = imagesnapshot.ProfileCPUOnly
		assert.Empty(t, Verify(ctx, f.dir, o), "cpuOnly loads no models")
	})
	t.Run("the reference is absent from the bundle", func(t *testing.T) {
		f := newFixture(t)
		f.models = nil
		f.build()
		got := Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileFullFeature))
		assert.Equal(t, map[string]string{"models": FindingModelInventory}, codes(got))
		assert.Empty(t, Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)))
	})
	t.Run("staged from another source or with another checksum", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		o.Facts.StagedModels[0].Source = "https://huggingface.co/someone/else"
		o.Facts.StagedModels[1].SHA256 = strings.Repeat("d", 64)
		assert.Equal(t, map[string]string{"model:all-minilm-l6-v2": FindingModelMismatch, "model:cross-encoder": FindingModelMismatch}, codes(Verify(ctx, f.dir, o)))
	})
}

// ---- bundle integrity ----

func TestVerify_DetectsAlteredTruncatedAndUnlistedFiles(t *testing.T) {
	f := newFixture(t)
	f.build()
	write(t, filepath.Join(f.dir, "binaries/yq"), "yq binarX")               // same size, other content
	write(t, filepath.Join(f.dir, "manifests/cert-manager.yaml"), "kind: L") // truncated
	write(t, filepath.Join(f.dir, "charts/rogue-1.0.0.tgz"), "x")            // not in the manifest
	got := codes(Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)))
	assert.Equal(t, map[string]string{
		"binaries/yq":                 FindingFileChanged,
		"manifests/cert-manager.yaml": FindingFileChanged,
		"charts/rogue-1.0.0.tgz":      FindingFileUnlisted,
	}, got)
	for _, f := range Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)) {
		if f.Component == "manifests/cert-manager.yaml" {
			assert.Contains(t, f.Message, "truncated or replaced", "a size change is reported as such")
		}
	}
}

func TestVerify_ABundleWithoutAValidManifestIsOneFinding(t *testing.T) {
	f := newFixture(t)
	got := Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly))
	require.Len(t, got, 1)
	assert.Equal(t, FindingManifestInvalid, got[0].Code)
}

func TestVerify_AnArchiveImageWithoutADigestIsNotTrusted(t *testing.T) {
	f := newFixture(t)
	writeTar(t, filepath.Join(f.dir, "images/addon-images.tar"), map[string][]byte{
		"manifest.json": []byte(`[{"RepoTags":["quay.io/jetstack/cert-manager-controller:v1.13.0","quay.io/kuberay/operator:v1.2.2"]}]`)})
	f.build()
	got := codes(Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileFullFeature)))
	assert.Equal(t, FindingArchiveUnpinned, got["quay.io/kuberay/operator:v1.2.2"])
	assert.Equal(t, FindingArchiveUnpinned, got["quay.io/jetstack/cert-manager-controller:v1.13.0"])
}

// ---- what each profile requires, with the installer's gates ----

func TestVerify_RequirementsFollowTheProfileAndComponents(t *testing.T) {
	strip := func(t *testing.T, paths ...string) *fixture {
		f := newFixture(t)
		for _, p := range paths {
			require.NoError(t, os.RemoveAll(filepath.Join(f.dir, p)))
		}
		f.build()
		return f
	}
	t.Run("cpuOnly needs no GPU artifacts", func(t *testing.T) {
		f := strip(t, "manifests/nvidia-device-plugin.yml", "packages/nvidia-closure", "packages/nvidia-closure.manifest", "charts/kuberay-operator-1.2.2.tgz")
		assert.Empty(t, Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)))
		got := codes(Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileFullFeature)))
		assert.Equal(t, FindingArtifactMissing, got["manifest:nvidia-device-plugin"])
		assert.Equal(t, FindingArtifactMissing, got["package:nvidia-closure"])
		assert.Equal(t, FindingArtifactMissing, got["chart:kuberay-operator"])
	})
	t.Run("an add-on that is switched off is not required", func(t *testing.T) {
		f := strip(t, "charts/kube-prometheus-stack-65.1.0.tgz", "charts/kube-prometheus-stack.version")
		o := f.opts(imagesnapshot.ProfileCPUOnly)
		assert.Equal(t, map[string]string{"chart:kube-prometheus-stack": FindingArtifactMissing}, codes(Verify(ctx, f.dir, o)))
		o.Input.Installer.Components = map[string]any{"monitoring": false}
		assert.Empty(t, Verify(ctx, f.dir, o))
	})
	t.Run("MetalLB only when metallb.install is set", func(t *testing.T) {
		f := strip(t, "charts/metallb-0.14.8.tgz")
		o := f.opts(imagesnapshot.ProfileCPUOnly)
		assert.Empty(t, Verify(ctx, f.dir, o))
		o.MetalLB = true
		assert.Equal(t, map[string]string{"chart:metallb": FindingArtifactMissing}, codes(Verify(ctx, f.dir, o)))
	})
	t.Run("the always-required artifacts", func(t *testing.T) {
		f := strip(t, "binaries/yq", "manifests/local-path-storage.yaml", "packages/pyyaml-6.0.2-cp311-manylinux_x86_64.whl")
		got := codes(Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)))
		assert.Equal(t, map[string]string{"binary:yq": FindingArtifactMissing, "manifest:local-path-storage": FindingArtifactMissing, "package:pyyaml": FindingArtifactMissing}, got)
	})
}

// ---- the snapshot and the target ----

func TestVerify_TheSnapshotMustBeTheBundles(t *testing.T) {
	f := newFixture(t)
	f.build()
	o := f.opts(imagesnapshot.ProfileCPUOnly)
	// A valid, intact snapshot of the same images, but not the one the bundle was made for.
	second := *f.snap
	second.Metadata.ID = "snap-2"
	other, _, err := (imagesnapshot.Store{Dir: t.TempDir()}).Put(&second)
	require.NoError(t, err)
	_, err = imagesnapshot.ReadSnapshot(other)
	require.NoError(t, err, "the other snapshot is itself valid")
	o.SnapshotPath = other
	got := Verify(ctx, f.dir, o)
	assert.Equal(t, map[string]string{"snapshot": FindingSnapshotMismatch}, codes(got))
	assert.Contains(t, got[0].Message, "is not that of snapshot snap-1")
	o.SnapshotPath = ""
	assert.Equal(t, map[string]string{"snapshot": FindingSnapshotMismatch}, codes(Verify(ctx, f.dir, o)), "no snapshot is not a pass")
}

func TestVerify_HostPrerequisites(t *testing.T) {
	f := newFixture(t)
	f.build()
	run := func(profile string, edit func(*HostFacts)) map[string]string {
		o := f.opts(profile)
		edit(o.Facts)
		return codes(Verify(ctx, f.dir, o))
	}
	assert.Equal(t, map[string]string{"host": FindingFactsMissing}, run(imagesnapshot.ProfileCPUOnly, func(h *HostFacts) { h.Nodes = nil }))
	noFacts := f.opts(imagesnapshot.ProfileCPUOnly)
	noFacts.Facts = nil
	assert.Equal(t, map[string]string{"host": FindingFactsMissing}, codes(Verify(ctx, f.dir, noFacts)), "no facts at all is not a pass")
	assert.Equal(t, map[string]string{"node:cpu-1": FindingArch}, run(imagesnapshot.ProfileCPUOnly, func(h *HostFacts) { h.Nodes[1].Platform = "linux/arm64" }))
	assert.Equal(t, map[string]string{"node:cpu-1": FindingArch}, run(imagesnapshot.ProfileCPUOnly, func(h *HostFacts) { h.Nodes[1].Platform = "" }))

	assert.Equal(t, map[string]string{"host": FindingGPUNodeMissing}, run(imagesnapshot.ProfileFullFeature, func(h *HostFacts) { h.Nodes[2].GPU = nil }))
	assert.Equal(t, map[string]string{"node:gpu-1": FindingGPUDriver, "host": FindingGPUCapacity},
		run(imagesnapshot.ProfileFullFeature, func(h *HostFacts) { h.Nodes[2].GPU.Driver = "" }), "a node without a driver offers no usable GPUs")
	assert.Equal(t, map[string]string{"node:gpu-1": FindingGPURuntime, "host": FindingGPUCapacity},
		run(imagesnapshot.ProfileFullFeature, func(h *HostFacts) { h.Nodes[2].GPU.Runtime = false }))
	assert.Equal(t, map[string]string{"host": FindingGPUCapacity}, run(imagesnapshot.ProfileFullFeature, func(h *HostFacts) { h.Nodes[2].GPU.Allocatable = 0 }))

	// cpuOnly has no GPU prerequisite, whatever the GPU node looks like.
	assert.Empty(t, run(imagesnapshot.ProfileCPUOnly, func(h *HostFacts) { h.Nodes[2].GPU = &GPU{} }))

	o := f.opts(imagesnapshot.ProfileFullFeature)
	o.GPUs = 3
	assert.Equal(t, map[string]string{"host": FindingGPUCapacity}, codes(Verify(ctx, f.dir, o)), "two GPUs are not three")
}

func TestVerify_ReportsEveryProblemAtOnceInAStableOrder(t *testing.T) {
	f := newFixture(t)
	f.build()
	require.NoError(t, os.Remove(filepath.Join(f.dir, "binaries/k0s")))
	o := f.opts(imagesnapshot.ProfileFullFeature)
	o.Facts.Nodes[2].GPU.Runtime = false
	o.Facts.StagedModels = nil
	a, b := Verify(ctx, f.dir, o), Verify(ctx, f.dir, o)
	assert.Equal(t, a, b)
	c := codes(a)
	assert.Equal(t, FindingFileMissing, c["binaries/k0s"])
	assert.Equal(t, FindingGPURuntime, c["node:gpu-1"])
	assert.Equal(t, FindingModelMissing, c["model:cross-encoder"])
	assert.True(t, hasCode(a, FindingGPUCapacity))
}

// A list may spell an image the short way; the archive holds the full name. Both are the same image.
func TestVerify_ArchiveListsMatchHowEverTheReferenceIsSpelled(t *testing.T) {
	f := newFixture(t)
	ociArchive(t, filepath.Join(f.dir, "images/addon-images.tar"), []string{"docker.io/library/busybox:1.36", "quay.io/kuberay/operator:v1.2.2"})
	write(t, filepath.Join(f.dir, "images/addon-images.list"), "busybox:1.36\nquay.io/kuberay/operator:v1.2.2\n")
	f.build()
	got := Verify(ctx, f.dir, VerifyOptions{Scope: ScopeBundle, Profile: imagesnapshot.ProfileFullFeature, Input: f.input})
	assert.Empty(t, got)
}

func TestValidate_NamesEveryInconsistency(t *testing.T) {
	f := newFixture(t)
	m := f.build()
	bad := *m
	bad.Spec.Files = append(append([]File(nil), m.Spec.Files...), m.Spec.Files[0])
	bad.Spec.ArchiveImages = append(append([]ArchiveImage(nil), m.Spec.ArchiveImages...),
		ArchiveImage{Ref: "x:1", Digest: "sha256:nothex", Archive: "images/gone-images.tar"})
	bad.Spec.Models = []Model{{ID: "m", Source: "s", SHA256: "short"}}
	bad.Spec.Snapshot.Checksum = "nope"
	err := Validate(&bad)
	require.Error(t, err)
	for _, want := range []string{"is listed twice", "which the bundle does not list", "malformed digest", "well-formed sha256", "snapshot reference"} {
		assert.Contains(t, err.Error(), want)
	}
	blocked := &BlockedError{[]Finding{{Component: "a", Code: "C", Message: "m"}}}
	assert.Equal(t, "import refused: [C] a: m", blocked.Error())
}
