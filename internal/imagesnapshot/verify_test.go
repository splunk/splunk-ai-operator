package imagesnapshot

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func codes(findings []Finding) map[string]string { // component -> code
	out := map[string]string{}
	for _, f := range findings {
		out[f.Component] = f.Code
	}
	return out
}

// fixture builds a verified snapshot of three images: one for both profiles, one only
// for fullfeature, and one only for cpuOnly.
type fixture struct {
	src, dst *testRegistry
	inv      *Inventory
	snap     *Snapshot
}

func newFixture(t *testing.T) *fixture {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("common/img", "v1", "linux", "amd64", nil)
	src.pushImage("full/ray", "v1", "linux", "amd64", nil)
	src.pushImage("cpu/only", "v1", "linux", "amd64", nil)
	inv := inventoryOf(
		imageOf("common", src.ref("common/img", "v1")),
		imageOf("ray", src.ref("full/ray", "v1"), ProfileFullFeature),
		imageOf("cpu-only", src.ref("cpu/only", "v1"), ProfileCPUOnly),
	)
	snap, err := Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host, ID: "run-1"})
	require.NoError(t, err)
	return &fixture{src, dst, inv, snap}
}

func (f *fixture) entry(component string) *Entry {
	for i := range f.snap.Spec.Entries {
		if f.snap.Spec.Entries[i].Component == component {
			return &f.snap.Spec.Entries[i]
		}
	}
	panic("no entry " + component)
}

func TestPreflight_PassesWhenTheMirrorHoldsEverythingTheProfileNeeds(t *testing.T) {
	f := newFixture(t)
	for _, profile := range Profiles {
		assert.Empty(t, Preflight(context.Background(), &Remote{}, f.snap, f.inv, profile), profile)
	}
}

func TestPreflight_ChecksOnlyTheImagesOfTheProfile(t *testing.T) {
	f := newFixture(t)
	// Break an image only fullfeature uses: cpuOnly must not care.
	f.entry("ray").MirrorRef = f.dst.Host + "/ai-tier/missing@" + f.entry("ray").Digest
	assert.Empty(t, Preflight(context.Background(), &Remote{}, f.snap, f.inv, ProfileCPUOnly))
	assert.Equal(t, map[string]string{"ray": FindingMissingImage}, codes(Preflight(context.Background(), &Remote{}, f.snap, f.inv, ProfileFullFeature)))
}

// Each negative case the story names fails with the offending component and a code.
func TestPreflight_NamesTheComponentForEachFailureTheStoryListsAndMore(t *testing.T) {
	ctx := context.Background()

	t.Run("a missing image", func(t *testing.T) {
		f := newFixture(t)
		f.entry("common").MirrorRef = f.dst.Host + "/never/pushed@" + f.entry("common").Digest
		got := Preflight(ctx, &Remote{}, f.snap, f.inv, ProfileCPUOnly)
		assert.Equal(t, map[string]string{"common": FindingMissingImage}, codes(got))
		assert.Contains(t, got[0].String(), "common")
	})

	t.Run("a wrong digest", func(t *testing.T) {
		f := newFixture(t)
		// The snapshot says digest X but the mirror reference it points to serves Y.
		other := f.dst.pushImage("other/img", "v1", "linux", "amd64", nil)
		e := f.entry("common")
		e.MirrorRef = f.dst.Host + "/other/img@" + other
		got := Preflight(ctx, &Remote{}, f.snap, f.inv, ProfileCPUOnly)
		assert.Equal(t, map[string]string{"common": FindingDigest}, codes(got))
		assert.Contains(t, got[0].Message, other)
		assert.Contains(t, got[0].Message, e.Digest)
	})

	t.Run("a wrong architecture", func(t *testing.T) {
		f := newFixture(t)
		arm := f.dst.pushImage("arm/img", "v1", "linux", "arm64", nil)
		e := f.entry("common")
		e.Digest = arm
		e.MirrorRef = f.dst.Host + "/arm/img@" + arm
		got := Preflight(ctx, &Remote{}, f.snap, f.inv, ProfileCPUOnly)
		assert.Equal(t, map[string]string{"common": FindingArch}, codes(got))
		assert.Contains(t, got[0].Message, "linux/arm64")
	})

	t.Run("a missing mirror mapping", func(t *testing.T) {
		f := newFixture(t)
		f.entry("common").MirrorRef = ""
		assert.Equal(t, map[string]string{"common": FindingNoMirror}, codes(Preflight(ctx, &Remote{}, f.snap, f.inv, ProfileCPUOnly)))
	})

	t.Run("a profile-specific image omitted from the snapshot", func(t *testing.T) {
		f := newFixture(t)
		f.src.pushImage("full/weaviate", "v1", "linux", "amd64", nil)
		bigger := inventoryOf(append(append([]Image(nil), f.inv.Images...), imageOf("weaviate", f.src.ref("full/weaviate", "v1"), ProfileFullFeature))...)
		got := Preflight(ctx, &Remote{}, f.snap, bigger, ProfileFullFeature)
		c := codes(got)
		assert.Equal(t, FindingOmitted, c["weaviate"], "named")
		assert.Equal(t, FindingInventoryChanged, c["inventory"])
		// cpuOnly does not use it: only the inventory change is reported.
		assert.NotContains(t, codes(Preflight(ctx, &Remote{}, f.snap, bigger, ProfileCPUOnly)), "weaviate")
	})

	t.Run("an image recorded only for another profile does not cover this one (review finding)", func(t *testing.T) {
		f := newFixture(t)
		// The inventory says fullfeature needs ray; the snapshot lists ray for cpuOnly only.
		f.entry("ray").Profiles = []string{ProfileCPUOnly}
		sameChecksums := *f.inv // the snapshot and inventory checksums still match
		got := codes(Preflight(ctx, &Remote{}, f.snap, &sameChecksums, ProfileFullFeature))
		assert.Equal(t, map[string]string{"ray": FindingOmitted}, got, "named, even though the checksums match and the entry exists")
	})

	t.Run("an entry recorded as an external blocker", func(t *testing.T) {
		f := newFixture(t)
		e := f.entry("common")
		e.Status, e.Blocker = StatusBlocked, "unresolved: not found"
		got := Preflight(ctx, &Remote{}, f.snap, f.inv, ProfileCPUOnly)
		assert.Equal(t, map[string]string{"common": FindingBlocked}, codes(got))
		assert.Contains(t, got[0].Message, "not found")
	})

	t.Run("the candidate record changed after the snapshot", func(t *testing.T) {
		f := newFixture(t)
		moved := *f.inv
		moved.Candidate.Checksum = strings.Repeat("d", 64)
		assert.Equal(t, FindingCandidate, codes(Preflight(ctx, &Remote{}, f.snap, &moved, ProfileCPUOnly))["candidate-manifest"])
	})

	t.Run("several problems are all reported", func(t *testing.T) {
		f := newFixture(t)
		f.entry("common").MirrorRef = ""
		f.entry("ray").Status = StatusBlocked
		got := codes(Preflight(ctx, &Remote{}, f.snap, f.inv, ProfileFullFeature))
		assert.Equal(t, map[string]string{"common": FindingNoMirror, "ray": FindingBlocked}, got)
	})
}

func TestPreflight_ErrorsDoNotLeakCredentials(t *testing.T) {
	f := newFixture(t)
	reg := newCounting()
	reg.describeOverride = func(ref string, d *Described, err error) (*Described, error) {
		return nil, errString("denied: Bearer eyJsecrettokenvalue1234 password=hunter2")
	}
	got := Preflight(context.Background(), reg, f.snap, f.inv, ProfileCPUOnly)
	require.NotEmpty(t, got)
	for _, g := range got {
		assert.NotContains(t, g.String(), "eyJsecret")
		assert.NotContains(t, g.String(), "hunter2")
	}
}

type errString string

func (e errString) Error() string { return string(e) }

func TestCompare_AccountsForEveryReferenceAnInstallWillUse(t *testing.T) {
	f := newFixture(t)
	common := f.entry("common")
	srcRef := common.Source
	mirrorRef := common.MirrorRef
	mirrorRepoOnlyDigest := strings.SplitN(mirrorRef, "@", 2)[0] + "@" + common.Digest

	t.Run("only the mirror reference, pinned to the digest, is accounted for", func(t *testing.T) {
		assert.Empty(t, Compare(f.snap, ProfileCPUOnly, []InstallRef{{"common", mirrorRef}}))
		assert.Empty(t, Compare(f.snap, ProfileCPUOnly, []InstallRef{{"common", mirrorRepoOnlyDigest}}))
	})

	// The install must not depend on an external registry: a reference to the registry the
	// image was copied from is a finding, whether it uses the candidate tag or the digest.
	t.Run("a reference to the source registry is not accepted", func(t *testing.T) {
		parsed, err := ParseRef(srcRef)
		require.NoError(t, err)
		sourceByDigest := ParsedRef{Registry: parsed.Registry, Repository: parsed.Repository, Digest: common.Digest}.String()
		for _, ref := range []string{srcRef, sourceByDigest, "docker.io/x/y:1.0"} {
			got := Compare(f.snap, ProfileCPUOnly, []InstallRef{{"common", ref}})
			require.Len(t, got, 1, ref)
			if ref == "docker.io/x/y:1.0" {
				assert.Equal(t, FindingUnaccounted, got[0].Code, "an unrelated public image is unaccounted")
				continue
			}
			assert.Equal(t, FindingSourceRegistry, got[0].Code, ref)
			assert.Contains(t, got[0].Message, "install from the mirror reference "+mirrorRef)
		}
	})

	t.Run("a reference that is not in the snapshot is unaccounted", func(t *testing.T) {
		got := Compare(f.snap, ProfileCPUOnly, []InstallRef{
			{"common", mirrorRef},
			{"rogue", "docker.io/library/busybox:latest"},
		})
		assert.Equal(t, map[string]string{"rogue": FindingUnaccounted}, codes(got))
	})

	t.Run("the image of another component does not account for this one", func(t *testing.T) {
		got := Compare(f.snap, ProfileFullFeature, []InstallRef{{"common", f.entry("ray").MirrorRef}})
		require.Len(t, got, 1)
		assert.Equal(t, FindingUnaccounted, got[0].Code)
		assert.Contains(t, got[0].Message, "is the image of component ray, not of common")
	})

	t.Run("a pinned digest that differs from the snapshot is a digest mismatch", func(t *testing.T) {
		wrong := strings.SplitN(mirrorRef, "@", 2)[0] + "@sha256:" + strings.Repeat("a", 64)
		got := Compare(f.snap, ProfileCPUOnly, []InstallRef{{"common", wrong}})
		assert.Equal(t, map[string]string{"common": FindingDigest}, codes(got))
	})

	t.Run("a mutable tag in the mirror is not accounted for", func(t *testing.T) {
		tagged := strings.SplitN(mirrorRef, "@", 2)[0] + ":latest"
		assert.Equal(t, map[string]string{"common": FindingUnaccounted}, codes(Compare(f.snap, ProfileCPUOnly, []InstallRef{{"common", tagged}})))
	})

	t.Run("an image of the other profile does not account for this profile", func(t *testing.T) {
		got := Compare(f.snap, ProfileCPUOnly, []InstallRef{{"ray", f.entry("ray").MirrorRef}})
		assert.Equal(t, map[string]string{"ray": FindingUnaccounted}, codes(got))
		assert.Empty(t, Compare(f.snap, ProfileFullFeature, []InstallRef{{"ray", f.entry("ray").MirrorRef}}))
	})

	t.Run("an invalid reference is reported, not skipped", func(t *testing.T) {
		got := Compare(f.snap, ProfileCPUOnly, []InstallRef{{"bad", "not a reference"}})
		assert.Equal(t, map[string]string{"bad": FindingUnaccounted}, codes(got))
	})
}
