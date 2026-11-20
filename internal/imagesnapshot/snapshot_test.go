package imagesnapshot

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCreate_ResolvesTheAmd64DigestMirrorsItAndVerifiesTheTarget(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	labels := map[string]string{"org.opencontainers.image.revision": "eae3b33005a5"}
	indexDigest, platforms := src.pushIndex("ml-platform/agent-runtime", "202609221052-eae3b33005a5", []string{"linux/amd64", "linux/arm64"}, labels)
	single := src.pushImage("splunk/slim", "v1", "linux", "amd64", nil)

	inv := inventoryOf(
		imageOf("agent-runtime-base", src.ref("ml-platform/agent-runtime", "202609221052-eae3b33005a5")),
		imageOf("slim", src.ref("splunk/slim", "v1")),
	)
	snap, err := Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host + "/ai-tier"})
	require.NoError(t, err)

	base, slim := snap.Spec.Entries[0], snap.Spec.Entries[1]
	require.Equal(t, "agent-runtime-base", base.Component)

	// A multi-platform source: the index digest is recorded, the amd64 manifest is pinned.
	assert.Equal(t, indexDigest, base.SourceDigest)
	assert.Equal(t, platforms["linux/amd64"], base.Digest)
	assert.NotEqual(t, base.SourceDigest, base.Digest)
	assert.Equal(t, []string{"linux/amd64", "linux/arm64"}, base.Platforms)
	assert.Equal(t, "eae3b33005a5", base.BuildID, "the build ID is the image's own revision label")
	assert.Equal(t, StatusVerified, base.Status)

	// A single-platform source: the two digests coincide.
	assert.Equal(t, single, slim.Digest)
	assert.Equal(t, slim.SourceDigest, slim.Digest)
	assert.Empty(t, slim.BuildID, "no label and no build-stamp tag: no build ID is invented")

	// The mirror reference is digest-pinned, under the source registry's own path, and
	// the mirror really serves exactly that digest.
	wantRepo := dst.Host + "/ai-tier/" + strings.ReplaceAll(src.Host, ":", "-") + "/ml-platform/agent-runtime"
	assert.Equal(t, wantRepo+"@"+base.Digest, base.MirrorRef)
	assert.True(t, dst.has("ai-tier/"+strings.ReplaceAll(src.Host, ":", "-")+"/ml-platform/agent-runtime", base.Digest))
	assert.False(t, dst.has("ai-tier/"+strings.ReplaceAll(src.Host, ":", "-")+"/ml-platform/agent-runtime", platforms["linux/arm64"]),
		"only the supported platform is mirrored")

	assert.Equal(t, inv.Checksum, snap.Spec.InventoryChecksum)
	assert.Equal(t, inv.Candidate, snap.Spec.Candidate)
	assert.Equal(t, Platform, snap.Spec.Platform)
	assert.NoError(t, Validate(snap))
}

func TestCreate_AnIncompatibleOrUnresolvedImageFailsTheSnapshotBeforeAnythingIsCopied(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	good := src.pushImage("good/image", "v1", "linux", "amd64", nil)
	src.pushImage("arm/only", "v1", "linux", "arm64", nil)
	src.pushIndex("arm/index", "v1", []string{"linux/arm64", "windows/amd64"}, nil)

	inv := inventoryOf(
		imageOf("good", src.ref("good/image", "v1")),
		imageOf("arm-only", src.ref("arm/only", "v1")),
		imageOf("arm-index", src.ref("arm/index", "v1")),
		imageOf("missing", src.ref("does/not-exist", "v1")),
	)
	reg := newCounting()
	snap, err := Create(context.Background(), reg, inv, Options{Mirror: dst.Host})

	var blocked *BlockedError
	require.True(t, errors.As(err, &blocked), "got %v", err)
	byComponent := map[string]Blocker{}
	for _, b := range blocked.Blockers {
		byComponent[b.Component] = b
	}
	require.Len(t, byComponent, 3, "the three bad images are all named, the good one is not")
	assert.Contains(t, byComponent["arm-only"].Reason, "incompatible: no linux/amd64 image (available: linux/arm64)")
	assert.Contains(t, byComponent["arm-index"].Reason, "available: linux/arm64, windows/amd64")
	assert.Contains(t, byComponent["missing"].Reason, "unresolved")
	assert.NotContains(t, byComponent, "good")

	assert.Empty(t, reg.Copies, "nothing is mirrored for a snapshot that cannot be complete")
	assert.False(t, dst.has("good/image", good))
	require.NotNil(t, snap, "the blocked entries are returned so the failure can be reported")
	assert.Error(t, Validate(snap), "a snapshot with blocked entries is not storable")
}

func TestCreate_SharedSourceIsResolvedAndCopiedOnce(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("rayproject/ray", "2.44.0", "linux", "amd64", nil)
	ray := src.ref("rayproject/ray", "2.44.0")

	reg := newCounting()
	snap, err := Create(context.Background(), reg, inventoryOf(imageOf("ray-head", ray), imageOf("ray-worker", ray)), Options{Mirror: dst.Host})
	require.NoError(t, err)
	require.Len(t, snap.Spec.Entries, 2, "each component keeps its own entry")
	assert.Equal(t, snap.Spec.Entries[0].Digest, snap.Spec.Entries[1].Digest)

	describedSource := 0
	for _, d := range reg.Describes {
		if d == ray {
			describedSource++
		}
	}
	assert.Equal(t, 1, describedSource, "the source is looked up once")
	assert.Len(t, reg.Copies, 1, "and copied once")
}

func TestCreate_ResolveOnlyCopiesNothing(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	d := src.pushImage("a/b", "v1", "linux", "amd64", nil)
	reg := newCounting()
	snap, err := Create(context.Background(), reg, inventoryOf(imageOf("b", src.ref("a/b", "v1"))), Options{Mirror: dst.Host, ResolveOnly: true})
	require.NoError(t, err)
	assert.Empty(t, reg.Copies)
	assert.Equal(t, d, snap.Spec.Entries[0].Digest)
	assert.Equal(t, StatusResolved, snap.Spec.Entries[0].Status)
	assert.Empty(t, snap.Spec.Entries[0].MirrorRef)
}

// A transfer that reports success is not trusted: the target is read back and must
// serve the requested digest as a linux/amd64 image.
func TestCreate_VerifiesTheTargetAfterTransfer(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("a/b", "v1", "linux", "amd64", nil)
	other := src.pushImage("a/other", "v1", "linux", "amd64", nil)
	inv := inventoryOf(imageOf("b", src.ref("a/b", "v1")))

	t.Run("target serves a different digest", func(t *testing.T) {
		reg := newCounting()
		reg.describeOverride = func(ref string, d *Described, err error) (*Described, error) {
			if strings.HasPrefix(ref, dst.Host) && err == nil {
				d.Digest = other
			}
			return d, err
		}
		_, err := Create(context.Background(), reg, inv, Options{Mirror: dst.Host})
		var blocked *BlockedError
		require.ErrorAs(t, err, &blocked)
		assert.Contains(t, blocked.Blockers[0].Reason, "verify after copy: mirror reports digest "+other)
	})
	t.Run("target image is not linux/amd64", func(t *testing.T) {
		reg := newCounting()
		reg.describeOverride = func(ref string, d *Described, err error) (*Described, error) {
			if strings.HasPrefix(ref, dst.Host) && err == nil {
				d.PlatformDigests = map[string]string{"linux/arm64": d.Digest}
			}
			return d, err
		}
		_, err := Create(context.Background(), reg, inv, Options{Mirror: dst.Host})
		var blocked *BlockedError
		require.ErrorAs(t, err, &blocked)
		assert.Contains(t, blocked.Blockers[0].Reason, "mirrored image is not linux/amd64")
	})
	t.Run("copy fails", func(t *testing.T) {
		_, err := Create(context.Background(), failingCopy{newCounting()}, inv, Options{Mirror: dst.Host})
		var blocked *BlockedError
		require.ErrorAs(t, err, &blocked)
		assert.Contains(t, blocked.Blockers[0].Reason, "mirror failed")
	})
}

type failingCopy struct{ *countingRegistry }

func (failingCopy) Copy(context.Context, string, string) error { return fmt.Errorf("denied") }

func TestCreate_RequiresAMirror(t *testing.T) {
	_, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("a", "x/y:1")), Options{})
	assert.ErrorContains(t, err, "mirror registry is required")
}

func TestCreate_IDDefaultsToTheRevisionAndInventoryChecksum(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("a/b", "v1", "linux", "amd64", nil)
	inv := inventoryOf(imageOf("b", src.ref("a/b", "v1")))
	snap, err := Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host})
	require.NoError(t, err)
	assert.Equal(t, "rev7-"+inv.Checksum[:12], snap.Metadata.ID)

	snap, err = Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host, ID: "run-42"})
	require.NoError(t, err)
	assert.Equal(t, "run-42", snap.Metadata.ID)
}

func TestBuildID(t *testing.T) {
	stamp := ParsedRef{Tag: "202609221052-eae3b33005a5"}
	assert.Equal(t, "abc123", buildID(map[string]string{"org.opencontainers.image.revision": "abc123", "org.opencontainers.image.created": "2026"}, stamp), "revision label wins")
	assert.Equal(t, "2026-11-16T00:00:00Z", buildID(map[string]string{"org.opencontainers.image.created": "2026-11-16T00:00:00Z"}, stamp), "then the created label")
	assert.Equal(t, "202609221052-eae3b33005a5", buildID(nil, stamp), "then a build-stamp tag")
	// Found on the real candidate carrier image: its revision label is the string "unknown".
	for _, placeholder := range []string{"unknown", "Unknown", " none ", "N/A", "-", "<none>", ""} {
		assert.Equal(t, "202609221517-f4466f2ccd",
			buildID(map[string]string{"org.opencontainers.image.revision": placeholder}, ParsedRef{Tag: "202609221517-f4466f2ccd"}),
			"label %q is a placeholder, so the build-stamp tag is used", placeholder)
	}
	assert.Equal(t, "2026-11-16T00:00:00Z", buildID(map[string]string{"org.opencontainers.image.revision": "unknown", "org.opencontainers.image.created": "2026-11-16T00:00:00Z"}, ParsedRef{Tag: "v1"}),
		"a placeholder revision falls through to a real created label")
	assert.Empty(t, buildID(map[string]string{"org.opencontainers.image.revision": "unknown"}, ParsedRef{Tag: "v1"}), "and with nothing else there is no build ID")
	assert.Empty(t, buildID(nil, ParsedRef{Tag: "latest"}), "an ordinary tag is not a build ID")
	assert.Empty(t, buildID(nil, ParsedRef{Tag: "v1.0"}))
}

func TestSanitizeRemovesCredentialShapedText(t *testing.T) {
	for _, in := range []string{
		"GET https://r/v2/: unauthorized: Bearer eyJhbGciOiJSUzI1NiJ9.abc.def",
		"auth failed: Basic dXNlcjpwYXNzd29yZA==",
		`config {"password":"hunter2"}`,
		"token=abc123secretvalue rejected",
	} {
		out := Sanitize(in)
		for _, leak := range []string{"eyJhbGci", "dXNlcjpw", "hunter2", "abc123secretvalue"} {
			assert.NotContains(t, out, leak, in)
		}
		assert.Contains(t, out, "[redacted]", in)
	}
	assert.LessOrEqual(t, len(Sanitize(strings.Repeat("x ", 500))), 303)
}
