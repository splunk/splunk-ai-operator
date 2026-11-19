package imagesnapshot

import (
	"context"
	"fmt"
	"regexp"
	"strings"
)

// Options controls one snapshot run.
type Options struct {
	// ID names the snapshot. Empty derives "rev<N>-<inventory checksum prefix>".
	ID string
	// Mirror is the private registry, optionally with a path prefix, that images are
	// copied to: "mirror.example.internal:5000/ai-tier". Required.
	Mirror string
	// ResolveOnly resolves digests and platforms without copying anything.
	ResolveOnly bool
}

// Blocker is one image that could not be resolved, was incompatible, or could not be
// mirrored. It is an external blocker for the snapshot: the image is never replaced
// by a public one.
type Blocker struct {
	Component string `json:"component"`
	Source    string `json:"source"`
	Reason    string `json:"reason"`
}

// BlockedError fails a snapshot because of one or more blockers.
type BlockedError struct{ Blockers []Blocker }

func (e *BlockedError) Error() string {
	parts := make([]string, 0, len(e.Blockers))
	for _, b := range e.Blockers {
		parts = append(parts, fmt.Sprintf("%s (%s): %s", b.Component, b.Source, b.Reason))
	}
	return fmt.Sprintf("snapshot blocked by %d image(s): %s", len(e.Blockers), strings.Join(parts, "; "))
}

// Create resolves every image of the inventory, then mirrors and verifies each one.
//
// An image that cannot be resolved, or has no linux/amd64 platform, fails the
// snapshot before anything is copied: nothing is mirrored for a snapshot that
// cannot be complete. The returned snapshot carries the blocked entries so the
// failure can be reported; callers must not store or use it.
func Create(ctx context.Context, reg Registry, inv *Inventory, opts Options) (*Snapshot, error) {
	if strings.TrimSpace(opts.Mirror) == "" {
		return nil, fmt.Errorf("a mirror registry is required")
	}
	snap := newSnapshot(inv, opts)
	cache := map[string]resolution{}
	for _, img := range inv.Images {
		snap.Spec.Entries = append(snap.Spec.Entries, resolveEntry(ctx, reg, img, cache))
	}
	if err := blockedError(snap); err != nil {
		return snap, err
	}
	if opts.ResolveOnly {
		return snap, nil
	}
	entries := make([]*Entry, len(snap.Spec.Entries))
	for i := range snap.Spec.Entries {
		entries[i] = &snap.Spec.Entries[i]
	}
	mirrorEntries(ctx, reg, entries, opts.Mirror)
	if err := blockedError(snap); err != nil {
		return snap, err
	}
	return snap, nil
}

func newSnapshot(inv *Inventory, opts Options) *Snapshot {
	snap := &Snapshot{RecordType: RecordType, SchemaVersion: SchemaVersion}
	snap.Metadata.ID = opts.ID
	if snap.Metadata.ID == "" {
		snap.Metadata.ID = defaultID(inv)
	}
	snap.Spec.Candidate = inv.Candidate
	snap.Spec.Platform = Platform
	snap.Spec.Mirror = strings.TrimSuffix(opts.Mirror, "/")
	snap.Spec.InventoryChecksum = inv.Checksum
	return snap
}

func defaultID(inv *Inventory) string {
	sum := inv.Checksum
	if len(sum) > 12 {
		sum = sum[:12]
	}
	return fmt.Sprintf("rev%d-%s", inv.Candidate.Revision, sum)
}

type resolution struct {
	d   *Described
	err error
}

// resolveEntry resolves one image. The cache keeps one registry lookup per distinct
// reference even when several components share it (Ray head and worker, for example).
func resolveEntry(ctx context.Context, reg Registry, img Image, cache map[string]resolution) Entry {
	e := Entry{Image: img, Status: StatusBlocked}
	r, ok := cache[img.Source]
	if !ok {
		d, err := reg.Describe(ctx, img.Source)
		r = resolution{d, err}
		cache[img.Source] = r
	}
	if r.err != nil {
		e.Blocker = "unresolved: " + Sanitize(r.err.Error())
		return e
	}
	e.SourceDigest = r.d.Digest
	e.Platforms = r.d.Platforms()
	digest, ok := r.d.PlatformDigests[Platform]
	if !ok {
		e.Blocker = fmt.Sprintf("incompatible: no %s image (available: %s)", Platform, strings.Join(e.Platforms, ", "))
		return e
	}
	e.Digest = digest
	if p, err := ParseRef(img.Source); err == nil {
		e.BuildID = buildID(r.d.Labels, p)
	}
	e.Status = StatusResolved
	return e
}

var buildStamp = regexp.MustCompile(`^\d{10,14}-[0-9a-f]{7,40}$`)

// placeholderLabel reports a label value that only says "nothing here": build systems
// that cannot find a revision often write "unknown" into the label instead of leaving
// it out (the real MPR-188 carrier image does).
func placeholderLabel(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "", "unknown", "none", "null", "nil", "n/a", "na", "-", "undefined", "<none>":
		return true
	}
	return false
}

// buildID prefers the image's own OCI revision label, then its created label, and
// finally a tag that is itself a build stamp such as 202609221052-eae3b33005a5. A
// placeholder label value such as "unknown" is not a build ID.
func buildID(labels map[string]string, p ParsedRef) string {
	for _, k := range []string{"org.opencontainers.image.revision", "org.opencontainers.image.created"} {
		if v := labels[k]; !placeholderLabel(v) {
			return Sanitize(strings.TrimSpace(v))
		}
	}
	if buildStamp.MatchString(p.Tag) {
		return p.Tag
	}
	return ""
}

func blockedError(snap *Snapshot) error {
	var blockers []Blocker
	for _, e := range snap.Spec.Entries {
		if e.Status == StatusBlocked {
			blockers = append(blockers, Blocker{Component: e.Component, Source: e.Source, Reason: e.Blocker})
		}
	}
	if len(blockers) == 0 {
		return nil
	}
	return &BlockedError{Blockers: blockers}
}

// mirrorEntries copies the given resolved entries to the mirror by digest and verifies
// the result. A repeated source and digest is copied once.
func mirrorEntries(ctx context.Context, reg Registry, entries []*Entry, mirror string) {
	done := map[string]error{}
	for _, e := range entries {
		src, err := ParseRef(e.Source)
		if err != nil {
			block(e, "invalid reference: "+Sanitize(err.Error()))
			continue
		}
		srcRef := ParsedRef{Registry: src.Registry, Repository: src.Repository, Digest: e.Digest}.String()
		dstRef := MirrorRepository(mirror, src) + "@" + e.Digest
		copyErr, seen := done[dstRef]
		if !seen {
			copyErr = mirrorOne(ctx, reg, srcRef, dstRef, e.Digest)
			done[dstRef] = copyErr
		}
		if copyErr != nil {
			block(e, "mirror failed: "+Sanitize(copyErr.Error()))
			continue
		}
		e.MirrorRef = dstRef
		e.Status = StatusVerified
	}
}

// mirrorOne copies one image and re-reads it from the mirror: the digest there must
// equal the one that was requested, and the image must be linux/amd64.
func mirrorOne(ctx context.Context, reg Registry, srcRef, dstRef, digest string) error {
	if err := reg.Copy(ctx, srcRef, dstRef); err != nil {
		return err
	}
	d, err := reg.Describe(ctx, dstRef)
	if err != nil {
		return fmt.Errorf("verify after copy: %w", err)
	}
	if d.Digest != digest {
		return fmt.Errorf("verify after copy: mirror reports digest %s, expected %s", d.Digest, digest)
	}
	if got := d.PlatformDigests[Platform]; got != digest {
		return fmt.Errorf("verify after copy: mirrored image is not %s (platforms: %s)", Platform, strings.Join(d.Platforms(), ", "))
	}
	return nil
}

func block(e *Entry, reason string) {
	e.Status = StatusBlocked
	e.Blocker = reason
	e.MirrorRef = ""
}
