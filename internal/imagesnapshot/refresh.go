package imagesnapshot

import (
	"context"
	"errors"
	"fmt"
	"sort"
)

// Cell is one OS and profile combination that is qualified on its own. A changed image
// means every cell of a profile that uses it reruns.
type Cell struct{ Profile, OS string }

// Cells are the six supported OS and profile combinations that are qualified, and Jobs
// the install job of each profile, which consumes a snapshot. They change only when the
// set of supported operating systems or profiles changes.
var Cells = []Cell{
	{ProfileCPUOnly, "RHEL 9.8"},
	{ProfileFullFeature, "RHEL 9.8"},
	{ProfileCPUOnly, "RHEL 10.2"},
	{ProfileFullFeature, "RHEL 10.2"},
	{ProfileCPUOnly, "Ubuntu 24.04"},
	{ProfileFullFeature, "Ubuntu 24.04"},
}

// Jobs maps a profile to the install job that consumes the snapshot.
var Jobs = map[string]string{
	ProfileCPUOnly:     "cpuOnly install job",
	ProfileFullFeature: "fullfeature install job",
}

// RerunTargets lists the jobs and cells that must rerun when images used by the given
// profiles change, without duplicates: for each affected profile, its install job and
// then its cells in the order of Cells.
func RerunTargets(profiles []string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	for _, p := range Profiles {
		if !hasProfile(profiles, p) {
			continue
		}
		add(Jobs[p])
		for _, c := range Cells {
			if c.Profile == p {
				add(fmt.Sprintf("%s on %s", c.Profile, c.OS))
			}
		}
	}
	return out // in the fixed order of Profiles, then Cells
}

// Reasons a snapshot entry changed in a refresh.
const (
	ChangeNew      = "new component"
	ChangeSource   = "candidate reference replaced"
	ChangeMovedTag = "tag moved to a different digest"
	ChangeRemoved  = "component removed"
	ChangeProfiles = "profile applicability changed"
)

// Change is one entry that differs between a snapshot and its refresh.
type Change struct {
	Component      string   `json:"component"`
	Reason         string   `json:"reason"`
	PreviousSource string   `json:"previousSource,omitempty"`
	Source         string   `json:"source,omitempty"`
	PreviousDigest string   `json:"previousDigest,omitempty"`
	Digest         string   `json:"digest,omitempty"`
	Profiles       []string `json:"profiles"`
}

// RefreshOptions controls a refresh.
type RefreshOptions struct {
	// ID names the new snapshot. Empty derives "rev<N>-<inventory checksum prefix>".
	ID string
	// RecheckTags re-resolves every source, not only the changed ones, to catch a tag
	// that now points at a different digest.
	RecheckTags bool
}

// RefreshResult is a new snapshot plus what changed and what must rerun.
type RefreshResult struct {
	Snapshot *Snapshot `json:"-"`
	Changes  []Change  `json:"changes"`
	// Rerun lists the install jobs and qualification cells affected by the changes.
	Rerun []string `json:"rerun"`
}

// ErrNoChange means a refresh would produce a snapshot identical to its predecessor.
var ErrNoChange = errors.New("nothing changed: the inventory and every digest match the previous snapshot")

// Refresh derives a new snapshot from prev for a changed inventory. Entries whose
// source is unchanged are carried forward as they are, with no registry calls; only
// new or replaced entries are resolved, mirrored and verified (and, with RecheckTags,
// every source is re-resolved to catch a moved tag). The previous snapshot is never
// modified, and each changed entry records the digest it replaces.
func Refresh(ctx context.Context, reg Registry, prev *Snapshot, inv *Inventory, opts RefreshOptions) (*RefreshResult, error) {
	if err := Validate(prev); err != nil {
		return nil, fmt.Errorf("previous snapshot: %w", err)
	}
	snap := newSnapshot(inv, Options{ID: opts.ID, Mirror: prev.Spec.Mirror})
	snap.Metadata.Predecessor = prev.Metadata.ID
	if snap.Metadata.ID == prev.Metadata.ID {
		return nil, fmt.Errorf("the new snapshot needs its own ID: %q is the previous snapshot", prev.Metadata.ID)
	}

	// Pair each new image with its predecessor. Several images can share one component
	// name (the images of one add-on, or two tags of one repository), so the pairing is
	// done in three passes, each using only what is still unpaired: the same component and
	// source; then the same component and repository (a tag change), when exactly one
	// remains on each side; then the only image left of a component (a source change).
	pairs := pairEntries(prev.Spec.Entries, inv.Images)
	paired := map[int]bool{}
	for _, pi := range pairs {
		if pi >= 0 {
			paired[pi] = true
		}
	}

	cache := map[string]resolution{}
	res := &RefreshResult{Snapshot: snap}
	var affected []*Entry

	// carry keeps a verified entry as it was, with the freshly derived role, profiles and
	// owner, and records a change when the profiles it applies to changed.
	carry := func(old Entry, img Image) Entry {
		e := old
		e.Image = img
		e.PreviousDigest = ""
		if !equalStrings(old.Profiles, img.Profiles) {
			res.Changes = append(res.Changes, Change{Component: img.Component, Reason: ChangeProfiles, Source: img.Source,
				Digest: old.Digest, Profiles: unionProfiles(old.Profiles, img.Profiles)})
		}
		return e
	}

	for n, img := range inv.Images {
		existed := pairs[n] >= 0
		var old Entry
		if existed {
			old = prev.Spec.Entries[pairs[n]]
		}
		if existed && old.Source == img.Source && !opts.RecheckTags {
			snap.Spec.Entries = append(snap.Spec.Entries, carry(old, img))
			continue
		}
		e := resolveEntry(ctx, reg, img, cache)
		switch {
		case !existed:
			res.Changes = append(res.Changes, Change{Component: img.Component, Reason: ChangeNew, Source: img.Source, Digest: e.Digest, Profiles: img.Profiles})
		case old.Source != img.Source:
			e.PreviousDigest = old.Digest
			res.Changes = append(res.Changes, Change{Component: img.Component, Reason: ChangeSource, PreviousSource: old.Source,
				Source: img.Source, PreviousDigest: old.Digest, Digest: e.Digest, Profiles: unionProfiles(old.Profiles, img.Profiles)})
		case e.Status != StatusBlocked && e.Digest != old.Digest:
			e.PreviousDigest = old.Digest
			res.Changes = append(res.Changes, Change{Component: img.Component, Reason: ChangeMovedTag, PreviousSource: old.Source,
				Source: img.Source, PreviousDigest: old.Digest, Digest: e.Digest, Profiles: unionProfiles(old.Profiles, img.Profiles)})
		case e.Status != StatusBlocked:
			// Re-resolved and identical: carry the verified entry forward.
			snap.Spec.Entries = append(snap.Spec.Entries, carry(old, img))
			continue
		}
		snap.Spec.Entries = append(snap.Spec.Entries, e)
	}
	for i, old := range prev.Spec.Entries {
		if paired[i] {
			continue
		}
		res.Changes = append(res.Changes, Change{Component: old.Component, Reason: ChangeRemoved, PreviousSource: old.Source,
			PreviousDigest: old.Digest, Profiles: old.Profiles})
	}
	sort.SliceStable(snap.Spec.Entries, func(i, j int) bool {
		a, b := snap.Spec.Entries[i], snap.Spec.Entries[j]
		if a.Component != b.Component {
			return a.Component < b.Component
		}
		return a.Source < b.Source
	})
	sort.SliceStable(res.Changes, func(i, j int) bool {
		a, b := res.Changes[i], res.Changes[j]
		if a.Component != b.Component {
			return a.Component < b.Component
		}
		return a.Source+a.PreviousSource < b.Source+b.PreviousSource
	})

	if err := blockedError(snap); err != nil {
		return res, err
	}
	if len(res.Changes) == 0 && inv.Checksum == prev.Spec.InventoryChecksum {
		return nil, ErrNoChange
	}
	for i := range snap.Spec.Entries {
		if e := &snap.Spec.Entries[i]; e.Status == StatusResolved {
			affected = append(affected, e)
		}
	}
	mirrorEntries(ctx, reg, affected, snap.Spec.Mirror)
	if err := blockedError(snap); err != nil {
		return res, err
	}

	var profiles []string
	for _, c := range res.Changes {
		profiles = append(profiles, c.Profiles...)
	}
	res.Rerun = RerunTargets(profiles)
	return res, nil
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func unionProfiles(a, b []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, p := range append(append([]string{}, a...), b...) {
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

// repositoryOf returns registry/repository for a reference, without its tag or digest.
func repositoryOf(source string) string {
	p, err := ParseRef(source)
	if err != nil {
		return source
	}
	return p.Registry + "/" + p.Repository
}

// pairEntries returns, for each image, the index of the previous entry it replaces or
// continues, or -1. See Refresh for the order of the passes.
func pairEntries(prev []Entry, images []Image) []int {
	pairs := make([]int, len(images))
	for i := range pairs {
		pairs[i] = -1
	}
	taken := make([]bool, len(prev))
	prevTotal, newTotal := map[string]int{}, map[string]int{}
	for _, e := range prev {
		prevTotal[e.Component]++
	}
	for _, img := range images {
		newTotal[img.Component]++
	}
	pass := func(same func(e Entry, img Image) bool, needUnique bool) {
		for n, img := range images {
			if pairs[n] >= 0 {
				continue
			}
			candidate, count := -1, 0
			for i, e := range prev {
				if !taken[i] && e.Component == img.Component && same(e, img) {
					candidate, count = i, count+1
				}
			}
			if count == 0 || (needUnique && count != 1) {
				continue
			}
			if needUnique {
				// The reverse must be unique too: no other unpaired image claims it.
				others := 0
				for m, o := range images {
					if pairs[m] < 0 && o.Component == img.Component && same(prev[candidate], o) {
						others++
					}
				}
				if others != 1 {
					continue
				}
			}
			pairs[n], taken[candidate] = candidate, true
		}
	}
	pass(func(e Entry, img Image) bool { return e.Source == img.Source }, false)
	pass(func(e Entry, img Image) bool { return repositoryOf(e.Source) == repositoryOf(img.Source) }, true)
	// A component with exactly one image on each side is one image whose source changed.
	pass(func(e Entry, img Image) bool { return prevTotal[e.Component] == 1 && newTotal[img.Component] == 1 }, true)
	return pairs
}
