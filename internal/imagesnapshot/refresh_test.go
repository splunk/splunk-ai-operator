package imagesnapshot

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// refreshFixture is a stored snapshot of three images and the registries behind it.
type refreshFixture struct {
	src, dst *testRegistry
	inv      *Inventory
	prev     *Snapshot
}

func newRefreshFixture(t *testing.T) *refreshFixture {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("tier/slim", "v1", "linux", "amd64", nil)
	src.pushImage("tier/runtime", "v1", "linux", "amd64", nil)
	src.pushImage("tier/ray", "v1", "linux", "amd64", nil)
	inv := inventoryOf(
		imageOf("agent-runtime-base", src.ref("tier/runtime", "v1")),
		imageOf("ray-head", src.ref("tier/ray", "v1"), ProfileFullFeature),
		imageOf("slim", src.ref("tier/slim", "v1")),
	)
	prev, err := Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host, ID: "run-1"})
	require.NoError(t, err)
	return &refreshFixture{src, dst, inv, prev}
}

// with returns the inventory with one component's source replaced.
func (f *refreshFixture) with(component, source string) *Inventory {
	images := append([]Image(nil), f.inv.Images...)
	for i := range images {
		if images[i].Component == component {
			images[i].Source = source
		}
	}
	next := inventoryOf(images...)
	next.Candidate.Revision = f.inv.Candidate.Revision + 1
	next.Candidate.Checksum = strings.Repeat("e", 64)
	sum, _ := next.computeChecksum()
	next.Checksum = sum
	return next
}

func entryOf(s *Snapshot, component string) Entry {
	for _, e := range s.Spec.Entries {
		if e.Component == component {
			return e
		}
	}
	panic("no entry " + component)
}

func TestRefresh_OnlyTheReplacedImageIsResolvedMirroredAndVerified(t *testing.T) {
	f := newRefreshFixture(t)
	newSlim := f.src.pushImage("tier/slim", "v2", "linux", "amd64", nil)
	prevBytes, err := Marshal(f.prev)
	require.NoError(t, err)

	reg := newCounting()
	res, err := Refresh(context.Background(), reg, f.prev, f.with("slim", f.src.ref("tier/slim", "v2")), RefreshOptions{ID: "run-2"})
	require.NoError(t, err)

	// Only SLIM touched the registries: one lookup of the new reference, one copy.
	assert.Equal(t, []string{f.src.ref("tier/slim", "v2")}, filterPrefix(reg.Describes, f.src.Host), "only the new source is looked up")
	require.Len(t, reg.Copies, 1)
	assert.Contains(t, reg.Copies[0], newSlim)

	// The unchanged entries are carried forward exactly.
	for _, c := range []string{"agent-runtime-base", "ray-head"} {
		assert.Equal(t, entryOf(f.prev, c), entryOf(res.Snapshot, c), c)
	}

	// The replaced entry records the digest it replaces.
	slim := entryOf(res.Snapshot, "slim")
	assert.Equal(t, newSlim, slim.Digest)
	assert.Equal(t, entryOf(f.prev, "slim").Digest, slim.PreviousDigest)
	assert.Equal(t, StatusVerified, slim.Status)
	assert.Contains(t, slim.MirrorRef, "@"+newSlim)

	require.Len(t, res.Changes, 1)
	ch := res.Changes[0]
	assert.Equal(t, Change{Component: "slim", Reason: ChangeSource, PreviousSource: f.src.ref("tier/slim", "v1"),
		Source: f.src.ref("tier/slim", "v2"), PreviousDigest: entryOf(f.prev, "slim").Digest, Digest: newSlim, Profiles: Profiles}, ch)

	// A new snapshot that points back at the one it refreshes; the old one is untouched.
	assert.Equal(t, "run-2", res.Snapshot.Metadata.ID)
	assert.Equal(t, "run-1", res.Snapshot.Metadata.Predecessor)
	assert.NoError(t, Validate(res.Snapshot))
	after, err := Marshal(f.prev)
	require.NoError(t, err)
	assert.Equal(t, prevBytes, after, "the previous snapshot is not modified")
	assert.True(t, f.dst.has(strings.SplitN(strings.TrimPrefix(slim.MirrorRef, f.dst.Host+"/"), "@", 2)[0], newSlim))
}

func filterPrefix(in []string, prefix string) []string {
	var out []string
	for _, s := range in {
		if strings.HasPrefix(s, prefix) {
			out = append(out, s)
		}
	}
	return out
}

// A change to an image only fullfeature uses reruns only fullfeature's job and cells.
func TestRefresh_NamesTheDownstreamJobsAndCellsToRerun(t *testing.T) {
	f := newRefreshFixture(t)
	f.src.pushImage("tier/ray", "v2", "linux", "amd64", nil)
	f.src.pushImage("tier/slim", "v2", "linux", "amd64", nil)

	res, err := Refresh(context.Background(), newCounting(), f.prev, f.with("ray-head", f.src.ref("tier/ray", "v2")), RefreshOptions{ID: "run-2"})
	require.NoError(t, err)
	assert.Equal(t, []string{
		"MPR-192 fullfeature install job",
		"MPR-209 fullfeature on RHEL 9.8",
		"MPR-211 fullfeature on RHEL 10.2",
		"MPR-213 fullfeature on Ubuntu 24.04",
	}, res.Rerun)

	// An image both profiles use reruns all six cells and both jobs.
	res, err = Refresh(context.Background(), newCounting(), f.prev, f.with("slim", f.src.ref("tier/slim", "v2")), RefreshOptions{ID: "run-3"})
	require.NoError(t, err)
	assert.Len(t, res.Rerun, 8, "two jobs and six cells: %v", res.Rerun)
	assert.Contains(t, res.Rerun, "MPR-190 cpuOnly install job")
	assert.Contains(t, res.Rerun, "MPR-207 cpuOnly on RHEL 9.8")
}

// A moved tag is only noticed when the sources are re-resolved.
func TestRefresh_RecheckTagsCatchesAMovedTag(t *testing.T) {
	f := newRefreshFixture(t)
	moved := f.src.pushImage("tier/runtime", "v1", "linux", "amd64", nil) // v1 now points elsewhere
	require.NotEqual(t, entryOf(f.prev, "agent-runtime-base").Digest, moved)

	_, err := Refresh(context.Background(), newCounting(), f.prev, f.inv, RefreshOptions{ID: "run-2"})
	assert.ErrorIs(t, err, ErrNoChange, "without a recheck nothing is looked up and nothing changed")

	reg := newCounting()
	res, err := Refresh(context.Background(), reg, f.prev, f.inv, RefreshOptions{ID: "run-2", RecheckTags: true})
	require.NoError(t, err)
	require.Len(t, res.Changes, 1)
	assert.Equal(t, ChangeMovedTag, res.Changes[0].Reason)
	assert.Equal(t, "agent-runtime-base", res.Changes[0].Component)
	assert.Equal(t, entryOf(f.prev, "agent-runtime-base").Digest, res.Changes[0].PreviousDigest)
	assert.Equal(t, moved, res.Changes[0].Digest)
	assert.Len(t, reg.Copies, 1, "only the image whose tag moved is mirrored again")
	assert.Equal(t, entryOf(f.prev, "slim"), entryOf(res.Snapshot, "slim"), "unchanged images are carried over")
}

// An unavailable replacement is an external blocker for the snapshot: the old image
// is not silently kept, nothing public is substituted, and nothing is stored.
func TestRefresh_AnUnavailableReplacementIsAnExternalBlocker(t *testing.T) {
	f := newRefreshFixture(t)
	reg := newCounting()
	res, err := Refresh(context.Background(), reg, f.prev, f.with("slim", f.src.ref("tier/slim", "not-built-yet")), RefreshOptions{ID: "run-2"})

	var blocked *BlockedError
	require.ErrorAs(t, err, &blocked)
	require.Len(t, blocked.Blockers, 1)
	assert.Equal(t, "slim", blocked.Blockers[0].Component)
	assert.Contains(t, blocked.Blockers[0].Reason, "unresolved")
	assert.Empty(t, reg.Copies, "nothing is mirrored")

	slim := entryOf(res.Snapshot, "slim")
	assert.Equal(t, StatusBlocked, slim.Status)
	assert.Empty(t, slim.MirrorRef, "no mirror reference, and certainly no public fallback")
	assert.NotContains(t, slim.MirrorRef, "docker.io")
	assert.Error(t, Validate(res.Snapshot), "a snapshot with a blocker cannot be stored")
}

func TestRefresh_NewAndRemovedComponents(t *testing.T) {
	f := newRefreshFixture(t)
	f.src.pushImage("tier/weaviate", "v1", "linux", "amd64", nil)
	images := []Image{
		imageOf("agent-runtime-base", f.src.ref("tier/runtime", "v1")),
		imageOf("slim", f.src.ref("tier/slim", "v1")),
		imageOf("weaviate", f.src.ref("tier/weaviate", "v1"), ProfileFullFeature),
	} // ray-head dropped, weaviate added
	next := inventoryOf(images...)

	res, err := Refresh(context.Background(), newCounting(), f.prev, next, RefreshOptions{ID: "run-2"})
	require.NoError(t, err)
	got := map[string]string{}
	for _, c := range res.Changes {
		got[c.Component] = c.Reason
	}
	assert.Equal(t, map[string]string{"weaviate": ChangeNew, "ray-head": ChangeRemoved}, got)
	components := []string{}
	for _, e := range res.Snapshot.Spec.Entries {
		components = append(components, e.Component)
	}
	assert.Equal(t, []string{"agent-runtime-base", "slim", "weaviate"}, components)
}

func TestRefresh_ChangedProfileApplicabilityIsAChange(t *testing.T) {
	f := newRefreshFixture(t)
	images := append([]Image(nil), f.inv.Images...)
	for i := range images {
		if images[i].Component == "ray-head" {
			images[i].Profiles = Profiles // now needed by cpuOnly too
		}
	}
	res, err := Refresh(context.Background(), newCounting(), f.prev, inventoryOf(images...), RefreshOptions{ID: "run-2"})
	require.NoError(t, err)
	require.Len(t, res.Changes, 1)
	assert.Equal(t, ChangeProfiles, res.Changes[0].Reason)
	assert.Contains(t, res.Rerun, "MPR-190 cpuOnly install job", "cpuOnly now depends on it")
}

func TestRefresh_Refusals(t *testing.T) {
	f := newRefreshFixture(t)
	_, err := Refresh(context.Background(), newCounting(), f.prev, f.inv, RefreshOptions{ID: "run-1"})
	assert.ErrorContains(t, err, "needs its own ID")

	bad := *f.prev
	bad.Spec.Entries = append([]Entry(nil), f.prev.Spec.Entries...)
	bad.Spec.Entries[0].Status = StatusBlocked
	_, err = Refresh(context.Background(), newCounting(), &bad, f.inv, RefreshOptions{ID: "run-2"})
	assert.ErrorContains(t, err, "previous snapshot")
}

func TestRerunTargets(t *testing.T) {
	assert.Empty(t, RerunTargets(nil))
	assert.Len(t, RerunTargets([]string{ProfileCPUOnly}), 4, "one job and three cells")
	assert.Len(t, RerunTargets(Profiles), 8)
	assert.Equal(t, RerunTargets([]string{ProfileCPUOnly, ProfileCPUOnly}), RerunTargets([]string{ProfileCPUOnly}), "duplicates collapse")
}
