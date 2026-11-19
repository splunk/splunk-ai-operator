package imagesnapshot

import (
	"context"
	"errors"
	"fmt"
	"sort"
)

// Cell is one OS and profile combination that is qualified on its own, and the story
// that tracks it. A changed image means every cell of a profile that uses it reruns.
type Cell struct{ Profile, OS, Story string }

// Cells are the six qualification cells and Jobs the two install jobs that consume a
// snapshot (MPR-190, MPR-192). They change only when the story map changes.
var Cells = []Cell{
	{ProfileCPUOnly, "RHEL 9.8", "MPR-207"},
	{ProfileFullFeature, "RHEL 9.8", "MPR-209"},
	{ProfileCPUOnly, "RHEL 10.2", "MPR-210"},
	{ProfileFullFeature, "RHEL 10.2", "MPR-211"},
	{ProfileCPUOnly, "Ubuntu 24.04", "MPR-212"},
	{ProfileFullFeature, "Ubuntu 24.04", "MPR-213"},
}

// Jobs maps a profile to the install job that consumes the snapshot.
var Jobs = map[string]string{
	ProfileCPUOnly:     "MPR-190 cpuOnly install job",
	ProfileFullFeature: "MPR-192 fullfeature install job",
}

// RerunTargets lists the jobs and cells that must rerun when images used by the given
// profiles change, without duplicates.
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
				add(fmt.Sprintf("%s %s on %s", c.Story, c.Profile, c.OS))
			}
		}
	}
	sort.Strings(out)
	return out
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

	// An entry is identified by its component. Where several images share a component
	// name (the images of one add-on, for example) the source repository tells them apart,
	// so a refresh matches each image with its own predecessor.
	prevCount, newCount := map[string]int{}, map[string]int{}
	for _, e := range prev.Spec.Entries {
		prevCount[e.Component]++
	}
	for _, img := range inv.Images {
		newCount[img.Component]++
	}
	key := func(component, source string) string {
		if prevCount[component] <= 1 && newCount[component] <= 1 {
			return component
		}
		return component + "\x00" + repositoryOf(source)
	}
	prevBy := map[string]Entry{}
	for _, e := range prev.Spec.Entries {
		prevBy[key(e.Component, e.Source)] = e
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

	for _, img := range inv.Images {
		k := key(img.Component, img.Source)
		old, existed := prevBy[k]
		delete(prevBy, k)
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
	for _, old := range prevBy {
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
