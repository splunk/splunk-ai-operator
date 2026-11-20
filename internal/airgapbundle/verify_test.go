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
		assert.NotContains(t, got, "package:nvidia-closure", "the GPU node has its driver and toolkit, so it needs no closure")
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
		f := strip(t, "binaries/yq", "binaries/airgap-bundle", "manifests/local-path-storage.yaml", "packages/pyyaml-6.0.2-cp311-manylinux_x86_64.whl")
		got := codes(Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)))
		assert.Equal(t, map[string]string{"binary:yq": FindingArtifactMissing, "binary:airgap-bundle": FindingArtifactMissing,
			"manifest:local-path-storage": FindingArtifactMissing, "package:pyyaml": FindingArtifactMissing}, got)
	})
	t.Run("the bundle must carry its snapshot", func(t *testing.T) {
		f := strip(t, "snapshot")
		o := f.opts(imagesnapshot.ProfileCPUOnly)
		o.Scope, o.Facts, o.SnapshotPath = ScopeBundle, nil, ""
		assert.Equal(t, map[string]string{"snapshot:snapshot": FindingArtifactMissing}, codes(Verify(ctx, f.dir, o)))
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
	assert.Equal(t, map[string]string{"node:gpu-1": FindingGPUDevices, "host": FindingGPUCapacity},
		run(imagesnapshot.ProfileFullFeature, func(h *HostFacts) { h.Nodes[2].GPU.Devices = 0 }), "a GPU node without GPUs")
	// cpuOnly has no GPU prerequisite, whatever the GPU node looks like.
	assert.Empty(t, run(imagesnapshot.ProfileCPUOnly, func(h *HostFacts) { h.Nodes[2].GPU = &GPU{} }))

	o := f.opts(imagesnapshot.ProfileFullFeature)
	o.GPUs = 3
	assert.Equal(t, map[string]string{"host": FindingGPUCapacity}, codes(Verify(ctx, f.dir, o)), "two GPUs are not three")
}

// The fullfeature GPU rule, before any change: a driver and container toolkit that are
// either present or installable offline from the bundle's nvidia-closure for the
// node's exact kernel and package format, and enough NVIDIA GPUs.
func TestVerify_GPUPrerequisitesArePresentOrInstallableFromTheBundle(t *testing.T) {
	fresh := func(h *HostFacts) { h.Nodes[2].GPU.Driver, h.Nodes[2].GPU.Runtime = "", false }
	t.Run("a fresh GPU host the closure covers passes", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		fresh(o.Facts)
		assert.Empty(t, Verify(ctx, f.dir, o), "the installer will install the driver and toolkit offline")
	})
	t.Run("a kernel the closure does not cover fails before any change", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		fresh(o.Facts)
		o.Facts.Nodes[2].Kernel = "5.14.0-570.el9.x86_64"
		got := Verify(ctx, f.dir, o)
		c := codes(got)
		assert.Equal(t, FindingGPUDriver, c["node:gpu-1"])
		assert.Equal(t, FindingGPUCapacity, c["host"], "an uninstallable node offers no usable GPUs")
		for _, g := range got {
			if g.Code == FindingGPUDriver {
				assert.Contains(t, g.Message, "no packages for its kernel 5.14.0-570.el9.x86_64")
				assert.Contains(t, g.Message, "--gpu-kernels 5.14.0-570.el9.x86_64")
			}
		}
	})
	t.Run("a package format that does not fit the node's OS", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		fresh(o.Facts)
		o.Facts.Nodes[2].OS = "ubuntu"
		got := Verify(ctx, f.dir, o)
		require.Equal(t, FindingGPUDriver, codes(got)["node:gpu-1"])
		assert.Contains(t, messageOf(got, "node:gpu-1"), "holds rpm packages and the node runs ubuntu (deb)")
	})
	t.Run("no closure in the bundle: only a pre-installed driver will do", func(t *testing.T) {
		f := newFixture(t)
		require.NoError(t, os.RemoveAll(filepath.Join(f.dir, "packages/nvidia-closure")))
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		got := codes(Verify(ctx, f.dir, o))
		assert.Empty(t, got, "a host whose driver and toolkit are installed needs nothing from the closure (--skip-nvidia-closure)")
		fresh(o.Facts)
		findings := Verify(ctx, f.dir, o)
		require.Equal(t, FindingGPUDriver, codes(findings)["node:gpu-1"])
		assert.Contains(t, messageOf(findings, "node:gpu-1"), "the bundle has no nvidia-closure to install one from")
	})
	t.Run("a closure without the toolkit cannot provide the runtime", func(t *testing.T) {
		f := newFixture(t)
		require.NoError(t, os.Remove(filepath.Join(f.dir, "packages/nvidia-closure/nvidia-container-toolkit-1.17.3-1.x86_64.rpm")))
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		o.Facts.Nodes[2].GPU.Runtime = false
		assert.Equal(t, map[string]string{"node:gpu-1": FindingGPURuntime, "host": FindingGPUCapacity}, codes(Verify(ctx, f.dir, o)))
	})
	t.Run("an unreported kernel cannot be checked against the closure", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		fresh(o.Facts)
		o.Facts.Nodes[2].Kernel = ""
		findings := Verify(ctx, f.dir, o)
		require.Equal(t, FindingGPUDriver, codes(findings)["node:gpu-1"])
		assert.Contains(t, messageOf(findings, "node:gpu-1"), "did not report its kernel")
	})
	t.Run("on an existing cluster the schedulable count is what counts", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		zero := 0
		o.Facts.Nodes[2].GPU.Allocatable = &zero
		assert.Equal(t, map[string]string{"host": FindingGPUCapacity}, codes(Verify(ctx, f.dir, o)),
			"two GPUs on the host, none schedulable")
		two := 2
		o.Facts.Nodes[2].GPU.Allocatable = &two
		assert.Empty(t, Verify(ctx, f.dir, o))
	})
}

func TestVerify_ReportsEveryProblemAtOnceInAStableOrder(t *testing.T) {
	f := newFixture(t)
	f.build()
	require.NoError(t, os.Remove(filepath.Join(f.dir, "binaries/k0s")))
	o := f.opts(imagesnapshot.ProfileFullFeature)
	o.Facts.Nodes[2].GPU.Driver = ""
	o.Facts.Nodes[2].Kernel = "6.0.0-unknown"
	o.Facts.StagedModels = nil
	a, b := Verify(ctx, f.dir, o), Verify(ctx, f.dir, o)
	assert.Equal(t, a, b)
	c := codes(a)
	assert.Equal(t, FindingFileMissing, c["binaries/k0s"])
	assert.Equal(t, FindingGPUDriver, c["node:gpu-1"])
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

// ERD §14.4.4: wrong-digest and wrong-architecture artifacts fail preflight, archives
// included. An archive image must be the snapshot's image: its linux/amd64 manifest or
// the index that holds it.
func TestVerify_ArchiveImagesMustBeTheSnapshotsImages(t *testing.T) {
	entryFor := func(f *fixture, ref string) imagesnapshot.Entry {
		for _, e := range f.snap.Spec.Entries {
			if e.Source == ref {
				return e
			}
		}
		t.Fatalf("no snapshot entry for %s", ref)
		return imagesnapshot.Entry{}
	}
	t.Run("the same image passes", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		assert.Empty(t, Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)))
	})
	t.Run("another build under the same tag is a digest mismatch", func(t *testing.T) {
		f := newFixture(t)
		rebuildArchive(t, f, "images/k0s-images.tar", map[string]string{k0sImages[1]: digestOf("rebuilt pause")})
		f.build()
		got := Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly))
		require.Equal(t, map[string]string{k0sImages[1]: FindingArchiveDigest}, codes(got))
		assert.Contains(t, got[0].Message, "resolved it to "+short(entryFor(f, k0sImages[1]).Digest)+" (linux/amd64)")
	})
	t.Run("the index of a multi-platform image is accepted", func(t *testing.T) {
		f := newFixture(t)
		// The snapshot recorded an index digest that differs from the amd64 manifest;
		// an archive exported by index is the same image.
		for i := range f.snap.Spec.Entries {
			if f.snap.Spec.Entries[i].Source == k0sImages[0] {
				f.snap.Spec.Entries[i].SourceDigest = digestOf("coredns index")
			}
		}
		resave(t, f)
		rebuildArchive(t, f, "images/k0s-images.tar", map[string]string{k0sImages[0]: digestOf("coredns index")})
		f.build()
		assert.Empty(t, Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileCPUOnly)))
	})
	t.Run("an archive image the snapshot does not know is unmapped", func(t *testing.T) {
		f := newFixture(t)
		extra := "docker.io/library/busybox:1.36"
		ociArchive(t, filepath.Join(f.dir, "images/addon-images.tar"), append(append([]string(nil), addonImages...), extra))
		f.build()
		got := Verify(ctx, f.dir, f.opts(imagesnapshot.ProfileFullFeature))
		assert.Equal(t, map[string]string{extra: FindingArchiveUnmapped}, codes(got))
	})
	t.Run("the bundle scope has no snapshot to compare with and does not claim it", func(t *testing.T) {
		f := newFixture(t)
		rebuildArchive(t, f, "images/k0s-images.tar", map[string]string{k0sImages[1]: digestOf("rebuilt pause")})
		f.build()
		o := VerifyOptions{Scope: ScopeBundle, Profile: imagesnapshot.ProfileCPUOnly, Input: f.input}
		assert.Empty(t, Verify(ctx, f.dir, o))
	})
}

// rebuildArchive rewrites an archive, overriding the digest of the named images.
func rebuildArchive(t *testing.T, f *fixture, rel string, digests map[string]string) {
	t.Helper()
	refs := k0sImages
	if strings.Contains(rel, "addon") {
		refs = addonImages
	}
	ociArchiveWithDigests(t, filepath.Join(f.dir, rel), refs, digests)
}

// resave stores the fixture's (edited) snapshot under a new ID so the bundle is built for it.
func resave(t *testing.T, f *fixture) {
	t.Helper()
	f.snap.Metadata.ID = "snap-edited"
	p, _, err := (imagesnapshot.Store{Dir: t.TempDir()}).Put(f.snap)
	require.NoError(t, err)
	f.snapshot = p
	carrySnapshot(t, f.dir, p)
}

// Generate then enforce (MPR-193 criterion 2): the install preflight compares the
// configuration the install uses with the snapshot.
func TestVerify_TheInstallConfigurationMustUseTheMirrorByDigest(t *testing.T) {
	t.Run("a setting left at its source registry", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileCPUOnly)
		o.Input.Installer.Images.Operator.Image = "docker.io/splunk/splunk-ai-operator:candidate-1"
		got := Verify(ctx, f.dir, o)
		assert.Equal(t, map[string]string{"splunk-ai-operator": imagesnapshot.FindingSourceRegistry}, codes(got))
		for _, ref := range f.reg.Describes {
			assert.True(t, strings.HasPrefix(ref, testMirror+"/"), "found without contacting the source registry: %s", ref)
		}
	})
	t.Run("a mutable tag in the mirror", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		ref := o.Input.Installer.Images.Weaviate.Image
		o.Input.Installer.Images.Weaviate.Image = ref[:strings.Index(ref, "@")] + ":stable"
		assert.Equal(t, map[string]string{"weaviate": imagesnapshot.FindingUnaccounted}, codes(Verify(ctx, f.dir, o)))
	})
	t.Run("no install configuration is not a pass", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileCPUOnly)
		o.Input.Installer = imagesnapshot.InstallerConfig{}
		o.Input.NoInstallerDefaults = true
		assert.Equal(t, map[string]string{"install-config": FindingInstallConfig}, codes(Verify(ctx, f.dir, o)))
	})
	t.Run("the candidate changed after the snapshot", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileCPUOnly)
		o.Input.CandidateChecksum = strings.Repeat("e", 64)
		assert.Equal(t, map[string]string{"candidate-manifest": imagesnapshot.FindingCandidate}, codes(Verify(ctx, f.dir, o)))
	})
	t.Run("archive images are not mistaken for install settings", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		o := f.opts(imagesnapshot.ProfileFullFeature)
		require.NotEmpty(t, o.Input.AddonRefs, "the bundle's add-on list names tag references at their source registries")
		assert.Empty(t, Verify(ctx, f.dir, o), "they are checked against the archives, not the mirror settings")
	})
}

func messageOf(findings []Finding, component string) string {
	for _, f := range findings {
		if f.Component == component {
			return f.Message
		}
	}
	return ""
}

// An add-on list may pin an image as name:tag@digest. k0s then records it under three
// names (as given, name:tag, name@digest), all one image; the aliases are not unmapped.
func TestVerify_K0sReferenceAliasesAreTheSameImage(t *testing.T) {
	f := newFixture(t)
	pinned := "registry.k8s.io/ingress-nginx/controller:v1.12.1@" + digestOf("ingress controller")
	refs := append(append([]string(nil), addonImages...), pinned)
	ociArchiveWithDigests(t, filepath.Join(f.dir, "images/addon-images.tar"), refs, map[string]string{pinned: digestOf("ingress controller")})
	write(t, filepath.Join(f.dir, "images/addon-images.list"), strings.Join(refs, "\n")+"\n")
	// The snapshot has the pinned image too (made from the same lists).
	for _, e := range f.snap.Spec.Entries {
		require.NotEqual(t, pinned, e.Source)
	}
	f.snap.Spec.Entries = append(f.snap.Spec.Entries, imagesnapshot.Entry{
		Image:  imagesnapshot.Image{Component: "addon-controller", Source: pinned, Profiles: imagesnapshot.Profiles, Owner: "unassigned", Origin: "addon-list"},
		Digest: digestOf("ingress controller"), SourceDigest: digestOf("ingress controller"), Platforms: []string{imagesnapshot.Platform},
		Status: imagesnapshot.StatusVerified, MirrorRef: testMirror + "/registry.k8s.io/ingress-nginx/controller@" + digestOf("ingress controller")})
	resave(t, f)
	m := f.build()
	n := 0
	for _, im := range m.Spec.ArchiveImages {
		if strings.Contains(im.Ref, "ingress-nginx") {
			n++
		}
	}
	require.Equal(t, 3, n, "k0s records the pinned image under three names")
	o := f.opts(imagesnapshot.ProfileCPUOnly)
	o.Input.AddonRefs = refs
	assert.Empty(t, Verify(ctx, f.dir, o))

	// An alias with another digest is a digest mismatch, every spelling of it, never "unmapped".
	ociArchiveWithDigests(t, filepath.Join(f.dir, "images/addon-images.tar"), refs, map[string]string{pinned: digestOf("someone else's build")})
	require.NoError(t, os.Remove(filepath.Join(f.dir, ManifestFile)))
	require.NoError(t, os.Remove(filepath.Join(f.dir, ChecksumFile)))
	f.build()
	got := Verify(ctx, f.dir, o)
	assert.False(t, hasCode(got, FindingArchiveUnmapped), "%v", got)
	mismatches := 0
	for _, g := range got {
		if g.Code == FindingArchiveDigest {
			mismatches++
		}
	}
	assert.Equal(t, 3, mismatches, "each of the three names is the wrong build")
}

// Two images of one repository: an alias is matched by its digest, not by being first.
func TestVerify_AnAliasIsMatchedByDigestAmongImagesOfOneRepository(t *testing.T) {
	f := newFixture(t)
	older := "registry.k8s.io/ingress-nginx/controller:v1.11.0"
	pinned := "registry.k8s.io/ingress-nginx/controller:v1.12.1@" + digestOf("v1.12.1")
	refs := append(append([]string(nil), addonImages...), older, pinned)
	ociArchiveWithDigests(t, filepath.Join(f.dir, "images/addon-images.tar"), refs, map[string]string{pinned: digestOf("v1.12.1")})
	write(t, filepath.Join(f.dir, "images/addon-images.list"), strings.Join(refs, "\n")+"\n")
	entry := func(source, digest string) imagesnapshot.Entry {
		return imagesnapshot.Entry{Image: imagesnapshot.Image{Component: "addon-controller", Source: source, Profiles: imagesnapshot.Profiles, Owner: "unassigned", Origin: "addon-list"},
			Digest: digest, SourceDigest: digest, Platforms: []string{imagesnapshot.Platform}, Status: imagesnapshot.StatusVerified,
			MirrorRef: testMirror + "/registry.k8s.io/ingress-nginx/controller@" + digest}
	}
	// The older tag comes first, so "the first image of the repository" would be wrong.
	f.snap.Spec.Entries = append(f.snap.Spec.Entries, entry(older, digestOf(older)), entry(pinned, digestOf("v1.12.1")))
	resave(t, f)
	f.build()
	o := f.opts(imagesnapshot.ProfileCPUOnly)
	o.Input.AddonRefs = refs
	assert.Empty(t, Verify(ctx, f.dir, o))
}
