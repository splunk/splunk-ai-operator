package imagesnapshot

import (
	"context"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/registry"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/random"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/stretchr/testify/require"
)

// testRegistry is a real OCI registry served over HTTP from memory, so resolution,
// copying and digest checks run against the actual registry protocol.
type testRegistry struct {
	t      *testing.T
	server *httptest.Server
	Host   string
}

func newTestRegistry(t *testing.T) *testRegistry {
	t.Helper()
	s := httptest.NewServer(registry.New())
	t.Cleanup(s.Close)
	return &testRegistry{t: t, server: s, Host: strings.TrimPrefix(s.URL, "http://")}
}

func (r *testRegistry) ref(repo, tag string) string { return r.Host + "/" + repo + ":" + tag }

func platformImage(t *testing.T, os, arch string, labels map[string]string) v1.Image {
	t.Helper()
	img, err := random.Image(256, 2)
	require.NoError(t, err)
	cfg, err := img.ConfigFile()
	require.NoError(t, err)
	cfg = cfg.DeepCopy()
	cfg.OS, cfg.Architecture = os, arch
	cfg.Config.Labels = labels
	img, err = mutate.ConfigFile(img, cfg)
	require.NoError(t, err)
	return img
}

// pushImage pushes a single-platform image and returns its manifest digest.
func (r *testRegistry) pushImage(repo, tag, os, arch string, labels map[string]string) string {
	r.t.Helper()
	img := platformImage(r.t, os, arch, labels)
	ref, err := name.NewTag(r.ref(repo, tag))
	require.NoError(r.t, err)
	require.NoError(r.t, remote.Write(ref, img))
	d, err := img.Digest()
	require.NoError(r.t, err)
	return d.String()
}

// pushIndex pushes a multi-platform image and returns the index digest and the digest
// of each platform's manifest, keyed by "os/arch".
func (r *testRegistry) pushIndex(repo, tag string, platforms []string, labels map[string]string) (indexDigest string, byPlatform map[string]string) {
	r.t.Helper()
	byPlatform = map[string]string{}
	var idx v1.ImageIndex = empty.Index
	for _, p := range platforms {
		parts := strings.SplitN(p, "/", 2)
		img := platformImage(r.t, parts[0], parts[1], labels)
		idx = mutate.AppendManifests(idx, mutate.IndexAddendum{
			Add:        img,
			Descriptor: v1.Descriptor{Platform: &v1.Platform{OS: parts[0], Architecture: parts[1]}},
		})
		d, err := img.Digest()
		require.NoError(r.t, err)
		byPlatform[p] = d.String()
	}
	ref, err := name.NewTag(r.ref(repo, tag))
	require.NoError(r.t, err)
	require.NoError(r.t, remote.WriteIndex(ref, idx))
	d, err := idx.Digest()
	require.NoError(r.t, err)
	return d.String(), byPlatform
}

// has reports whether the registry serves repo@digest.
func (r *testRegistry) has(repo, digest string) bool {
	ref, err := name.NewDigest(r.Host + "/" + repo + "@" + digest)
	require.NoError(r.t, err)
	_, err = remote.Head(ref)
	return err == nil
}

// countingRegistry wraps a Registry and counts calls, and can inject faults.
type countingRegistry struct {
	inner Registry
	mu    sync.Mutex

	Describes []string
	Copies    []string

	// describeOverride, when set, may replace the result of a Describe call.
	describeOverride func(ref string, d *Described, err error) (*Described, error)
}

func (c *countingRegistry) Describe(ctx context.Context, ref string) (*Described, error) {
	c.mu.Lock()
	c.Describes = append(c.Describes, ref)
	c.mu.Unlock()
	d, err := c.inner.Describe(ctx, ref)
	if c.describeOverride != nil {
		return c.describeOverride(ref, d, err)
	}
	return d, err
}

func (c *countingRegistry) Copy(ctx context.Context, srcRef, dstRef string) error {
	c.mu.Lock()
	c.Copies = append(c.Copies, srcRef+" -> "+dstRef)
	c.mu.Unlock()
	return c.inner.Copy(ctx, srcRef, dstRef)
}

func newCounting() *countingRegistry { return &countingRegistry{inner: &Remote{}} }

// inventoryOf builds a minimal inventory from images, for tests that do not need the
// derivation logic.
func inventoryOf(images ...Image) *Inventory {
	inv := &Inventory{
		Candidate: CandidateRef{Name: "test-candidate", Revision: 7, Checksum: strings.Repeat("c", 64)},
		Images:    images,
	}
	sum, _ := inv.computeChecksum()
	inv.Checksum = sum
	return inv
}

func imageOf(component, source string, profiles ...string) Image {
	if len(profiles) == 0 {
		profiles = Profiles
	}
	return Image{Component: component, Role: component, Category: CategoryPlatform, Profiles: profiles,
		Source: source, Origin: "test", Owner: "unassigned"}
}
