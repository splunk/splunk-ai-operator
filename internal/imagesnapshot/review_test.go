package imagesnapshot

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/go-containerregistry/pkg/name"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Tests for problems found by an independent review of the first version.

// Several images share one component name (the images of one add-on). A refresh must pair
// each image with its own predecessor.
func TestRefresh_ImagesThatShareAComponentAreTrackedIndividually(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("mon/prometheus", "v1", "linux", "amd64", nil)
	alert1 := src.pushImage("mon/alertmanager", "v1", "linux", "amd64", nil)
	src.pushImage("mon/grafana", "v1", "linux", "amd64", nil)
	inv := func(alert string, withGrafana bool) *Inventory {
		images := []Image{
			imageOf("monitoring-stack", src.ref("mon/prometheus", "v1")),
			imageOf("monitoring-stack", src.ref("mon/alertmanager", alert)),
		}
		if withGrafana {
			images = append(images, imageOf("monitoring-stack", src.ref("mon/grafana", "v1")))
		}
		return inventoryOf(images...)
	}
	prev, err := Create(context.Background(), newCounting(), inv("v1", true), Options{Mirror: dst.Host, ID: "run-1"})
	require.NoError(t, err)
	require.Len(t, prev.Spec.Entries, 3)

	t.Run("nothing changed is nothing changed", func(t *testing.T) {
		for _, recheck := range []bool{false, true} {
			_, err := Refresh(context.Background(), newCounting(), prev, inv("v1", true), RefreshOptions{ID: "run-2", RecheckTags: recheck})
			assert.ErrorIs(t, err, ErrNoChange, "recheck=%v: no spurious changes from the shared name", recheck)
		}
	})

	t.Run("replacing one of them reports exactly that image with its own old digest", func(t *testing.T) {
		alert2 := src.pushImage("mon/alertmanager", "v2", "linux", "amd64", nil)
		reg := newCounting()
		res, err := Refresh(context.Background(), reg, prev, inv("v2", true), RefreshOptions{ID: "run-2"})
		require.NoError(t, err)
		require.Len(t, res.Changes, 1)
		c := res.Changes[0]
		assert.Equal(t, ChangeSource, c.Reason)
		assert.Equal(t, src.ref("mon/alertmanager", "v1"), c.PreviousSource)
		assert.Equal(t, alert1, c.PreviousDigest, "the digest of the alertmanager image, not of a sibling")
		assert.Equal(t, alert2, c.Digest)
		assert.Len(t, reg.Copies, 1, "only the replaced image is mirrored")
		assert.Len(t, res.Snapshot.Spec.Entries, 3)
	})

	t.Run("dropping one of them removes only that image", func(t *testing.T) {
		res, err := Refresh(context.Background(), newCounting(), prev, inv("v1", false), RefreshOptions{ID: "run-3"})
		require.NoError(t, err)
		require.Len(t, res.Changes, 1)
		assert.Equal(t, ChangeRemoved, res.Changes[0].Reason)
		assert.Equal(t, src.ref("mon/grafana", "v1"), res.Changes[0].PreviousSource)
		assert.Len(t, res.Snapshot.Spec.Entries, 2)
	})
}

// A profile change is reported, and a stale "previous digest" is dropped, whether or not
// the tags are rechecked.
func TestRefresh_ProfileChangesAndStalePreviousDigestsWithRecheckTags(t *testing.T) {
	f := newRefreshFixture(t)
	f.src.pushImage("tier/slim", "v2", "linux", "amd64", nil)
	step1, err := Refresh(context.Background(), newCounting(), f.prev, f.with("slim", f.src.ref("tier/slim", "v2")), RefreshOptions{ID: "run-2"})
	require.NoError(t, err)
	require.NotEmpty(t, entryOf(step1.Snapshot, "slim").PreviousDigest, "the replaced entry records what it replaced")

	// The next refresh changes only the profiles of another image.
	images := append([]Image(nil), step1.Snapshot.Spec.Entries[0].Image)
	images = nil
	for _, e := range step1.Snapshot.Spec.Entries {
		img := e.Image
		if img.Component == "ray-head" {
			img.Profiles = Profiles
		}
		images = append(images, img)
	}
	next := inventoryOf(images...)
	for _, recheck := range []bool{false, true} {
		res, err := Refresh(context.Background(), newCounting(), step1.Snapshot, next, RefreshOptions{ID: "run-3", RecheckTags: recheck})
		require.NoError(t, err, "recheck=%v", recheck)
		require.Len(t, res.Changes, 1, "recheck=%v", recheck)
		assert.Equal(t, ChangeProfiles, res.Changes[0].Reason, "recheck=%v", recheck)
		assert.Contains(t, res.Rerun, "cpuOnly install job", "recheck=%v: cpuOnly now depends on it", recheck)
		assert.Empty(t, entryOf(res.Snapshot, "slim").PreviousDigest, "recheck=%v: an unchanged entry does not keep an old previousDigest", recheck)
	}
}

func TestDedupe_KeepsTheUnionOfProfiles(t *testing.T) {
	got := dedupe([]Image{
		{Component: "x", Source: "a/b:1", Profiles: []string{ProfileCPUOnly}},
		{Component: "x", Source: "a/b:1", Profiles: []string{ProfileFullFeature}},
		{Component: "y", Source: "a/c:1", Profiles: []string{ProfileFullFeature}},
	})
	require.Len(t, got, 2)
	assert.Equal(t, []string{ProfileCPUOnly, ProfileFullFeature}, got[0].Profiles, "needed by either, so needed by both")
	assert.Equal(t, []string{ProfileFullFeature}, got[1].Profiles)
}

func TestSanitize_RemovesTheCredentialAfterTheSchemeAndInURLsAndJSON(t *testing.T) {
	for in, leaks := range map[string][]string{
		"authorization: Basic dXNlcjpwYXNz":                              {"dXNlcjpwYXNz"},
		"Authorization: Bearer abc.def":                                  {"abc.def"},
		"Proxy-Authorization: Basic Zm9vOmJhcg==":                        {"Zm9vOmJhcg"},
		"GET https://u:p4ss@reg.io/v2/ failed":                           {"p4ss", "u:p4ss"},
		`unexpected response {"auth": "dXNlcjpwYXNzd29yZA=="}`:           {"dXNlcjpwYXNzd29yZA"},
		`{"identitytoken": "eyJhbGciOi.abc.def"}`:                        {"eyJhbGciOi"},
		"registrytoken=abcdef1234567890 invalid":                         {"abcdef1234567890"},
		"denied: Bearer eyJhbGciOiJSUzI1NiJ9.payload.sig for repository": {"eyJhbGciOi", "payload"},
	} {
		out := Sanitize(in)
		for _, leak := range leaks {
			assert.NotContains(t, out, leak, "input %q gave %q", in, out)
		}
		assert.Contains(t, out, "[redacted]", in)
	}
	// Ordinary text is left alone.
	assert.Equal(t, "GET http://registry:5000/v2/a/manifests/v1: MANIFEST_UNKNOWN", Sanitize("GET http://registry:5000/v2/a/manifests/v1: MANIFEST_UNKNOWN"))
}

func TestStore_ACrashWhileWritingNeverBurnsTheID(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	snap := completeSnapshot(t, src, dst, "run-1")
	dir := t.TempDir()
	s := Store{Dir: dir}

	// What a crash leaves behind under the old scheme, or an interrupted write today: a
	// temporary directory. It is not a snapshot and does not block the ID.
	require.NoError(t, os.MkdirAll(filepath.Join(dir, ".tmp-run-1-leftover"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, ".tmp-run-1-leftover", "manifest.json"), []byte("{partial"), 0o644))
	ids, err := s.List()
	require.NoError(t, err)
	assert.Empty(t, ids, "an unfinished write is not listed")
	assert.False(t, s.Exists("run-1"))

	_, _, err = s.Put(snap)
	require.NoError(t, err, "the ID is still available")
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	assert.ElementsMatch(t, []string{".tmp-run-1-leftover", "run-1"}, names, "Put leaves no temporary directory of its own")
	got, err := s.Get("run-1")
	require.NoError(t, err)
	assert.NoError(t, Validate(got))
}

func TestStore_AFailedWriteLeavesNothingAndTheIDUsable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("a read-only directory does not stop root")
	}
	src, dst := newTestRegistry(t), newTestRegistry(t)
	snap := completeSnapshot(t, src, dst, "run-1")
	dir := t.TempDir()
	require.NoError(t, os.Chmod(dir, 0o555))
	_, _, err := (Store{Dir: dir}).Put(snap)
	require.Error(t, err)
	require.NoError(t, os.Chmod(dir, 0o755))
	entries, _ := os.ReadDir(dir)
	assert.Empty(t, entries, "a failed write leaves nothing behind")
	_, _, err = (Store{Dir: dir}).Put(snap)
	assert.NoError(t, err, "and the same ID can be used again")
}

func TestStore_RequiresTheChecksumFileAndAValidID(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	s := Store{Dir: t.TempDir()}
	path, _, err := s.Put(completeSnapshot(t, src, dst, "run-1"))
	require.NoError(t, err)

	require.NoError(t, os.Remove(path+".sha256"))
	_, err = s.Get("run-1")
	assert.ErrorContains(t, err, "has no checksum file", "deleting the checksum must not switch verification off")
	_, err = ReadSnapshot(path)
	assert.ErrorContains(t, err, "has no checksum file")
	ids, _ := s.List()
	assert.Empty(t, ids, "a snapshot without its checksum is not listed")

	for _, bad := range []string{"../../etc", "a/b", ".hidden", "", "x y", strings.Repeat("a", 200)} {
		_, err := s.Get(bad)
		assert.Error(t, err, "%q", bad)
		assert.False(t, s.Exists(bad), "%q", bad)
	}
}

func TestValidate_ChecksTheMirrorReferenceIsUnderTheSnapshotsMirror(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	snap := completeSnapshot(t, src, dst, "run-1")
	require.NoError(t, Validate(snap))
	snap.Spec.Entries[0].MirrorRef = "elsewhere.example/a/b@" + snap.Spec.Entries[0].Digest
	assert.ErrorContains(t, Validate(snap), "not under the snapshot's mirror")
}

// A platform variant is its own platform: linux/amd64/v3 is not linux/amd64, and arm
// variants do not hide an arm64 image.
func TestDescribe_KeepsPlatformVariantsDistinct(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	push := func(repo string, platforms ...v1.Platform) {
		var idx v1.ImageIndex = empty.Index
		for _, p := range platforms {
			p := p
			idx = mutate.AppendManifests(idx, mutate.IndexAddendum{Add: platformImage(t, p.OS, p.Architecture, nil), Descriptor: v1.Descriptor{Platform: &p}})
		}
		ref, _ := name.NewTag(src.ref(repo, "v1"))
		require.NoError(t, remote.WriteIndex(ref, idx))
	}
	push("tier/variants",
		v1.Platform{OS: "linux", Architecture: "arm", Variant: "v7"},
		v1.Platform{OS: "linux", Architecture: "arm64"},
		v1.Platform{OS: "linux", Architecture: "amd64"})
	push("tier/amd64v3only", v1.Platform{OS: "linux", Architecture: "amd64", Variant: "v3"})

	d, err := (&Remote{}).Describe(context.Background(), src.ref("tier/variants", "v1"))
	require.NoError(t, err)
	assert.Equal(t, []string{"linux/amd64", "linux/arm/v7", "linux/arm64"}, d.Platforms())

	_, err = Create(context.Background(), newCounting(), inventoryOf(imageOf("v3", src.ref("tier/amd64v3only", "v1"))), Options{Mirror: dst.Host})
	var blocked *BlockedError
	require.ErrorAs(t, err, &blocked)
	assert.Contains(t, blocked.Blockers[0].Reason, "incompatible: no linux/amd64 image (available: linux/amd64/v3)")
}

// If the mirror serves a multi-platform index where the snapshot pins one manifest, the
// preflight says so instead of claiming the architecture is wrong.
func TestPreflight_ReportsAnIndexInTheMirrorPrecisely(t *testing.T) {
	f := newFixture(t)
	indexDigest, byPlatform := f.dst.pushIndex("ai-tier/index", "v1", []string{"linux/amd64", "linux/arm64"}, nil)
	e := f.entry("common")
	e.Digest = byPlatform["linux/amd64"]
	e.MirrorRef = f.dst.Host + "/ai-tier/index@" + indexDigest // the index, not the amd64 manifest
	got := Preflight(context.Background(), &Remote{}, f.snap, f.inv, ProfileCPUOnly)
	var arch *Finding
	for i := range got {
		if got[i].Code == FindingArch {
			arch = &got[i]
		}
	}
	require.NotNil(t, arch, "%v", got)
	assert.Contains(t, arch.Message, "multi-platform index")
}
