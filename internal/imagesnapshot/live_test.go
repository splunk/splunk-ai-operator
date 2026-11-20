package imagesnapshot

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/go-containerregistry/pkg/registry"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// liveImages are public images the installer and the existing air-gap bundle already
// name, so resolving them checks real multi-platform images on real registries.
var liveImages = []struct{ component, ref string }{
	{"nginx", "docker.io/library/nginx:1.27-alpine"},
	{"fluent-bit", "docker.io/fluent/fluent-bit:1.9.6"},
	{"otel-collector", "docker.io/otel/opentelemetry-collector-contrib:0.122.1"},
	{"ray", "docker.io/rayproject/ray:2.44.0"},
	{"weaviate", "docker.io/semitechnologies/weaviate:stable-v1.28-007846a"},
	{"kuberay-operator", "quay.io/kuberay/operator:v1.2.2"},
	{"cert-manager", "quay.io/jetstack/cert-manager-controller:v1.13.0"},
	{"nvidia-device-plugin", "nvcr.io/nvidia/k8s-device-plugin:v0.17.3"},
	{"pause", "registry.k8s.io/pause:3.9"},
}

func liveOnly(t *testing.T) {
	t.Helper()
	if os.Getenv("IMAGE_SNAPSHOT_LIVE") != "1" {
		t.Skip("set IMAGE_SNAPSHOT_LIVE=1 to run against real public registries")
	}
	// Anonymous on purpose: no credential from the developer's Docker configuration is used.
	t.Setenv("DOCKER_CONFIG", t.TempDir())
}

// Resolution against real registries: each image has a linux/amd64 manifest, and a
// multi-platform image's index digest differs from the digest that is pinned.
func TestLive_ResolvesRealPublicImages(t *testing.T) {
	liveOnly(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	var images []Image
	for _, i := range liveImages {
		images = append(images, imageOf(i.component, i.ref))
	}
	snap, err := Create(ctx, &Remote{}, inventoryOf(images...), Options{Mirror: "mirror.invalid", ResolveOnly: true})
	for _, e := range snap.Spec.Entries {
		t.Logf("%-22s %-60s index %.19s  amd64 %.19s  platforms=%d  build=%q  %s", e.Component, e.Source, e.SourceDigest, e.Digest, len(e.Platforms), e.BuildID, e.Blocker)
	}
	require.NoError(t, err)
	multi := 0
	for _, e := range snap.Spec.Entries {
		assert.Regexp(t, `^sha256:[0-9a-f]{64}$`, e.Digest, e.Component)
		assert.Contains(t, e.Platforms, Platform, e.Component)
		if e.SourceDigest != e.Digest {
			multi++
		}
	}
	assert.GreaterOrEqual(t, multi, 5, "most of these are multi-platform images, so the index and amd64 digests differ")
}

// A real copy: a real image's manifest, config and layers are copied to a local mirror
// and pulled back in full, with every blob checked against its digest.
func TestLive_MirrorsARealImageIntact(t *testing.T) {
	liveOnly(t)
	dst := newTestRegistry(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	snap, err := Create(ctx, &Remote{}, inventoryOf(imageOf("pause", "registry.k8s.io/pause:3.9")), Options{Mirror: dst.Host + "/ai-tier"})
	require.NoError(t, err)
	e := snap.Spec.Entries[0]
	t.Logf("mirrored %s -> %s", e.Source, strings.Replace(e.MirrorRef, dst.Host, "mirror.local", 1))
	assert.Equal(t, StatusVerified, e.Status)

	srcConfig, srcLayers := pullFully(t, "registry.k8s.io/pause@"+e.Digest)
	dstConfig, dstLayers := pullFully(t, e.MirrorRef)
	assert.NotEmpty(t, dstLayers)
	assert.Equal(t, srcConfig, dstConfig)
	assert.Equal(t, srcLayers, dstLayers)
	assert.Empty(t, Preflight(ctx, &Remote{}, snap, nil, ProfileCPUOnly), "the preflight passes on what was just mirrored")
}

// TestLive_MirrorsTheCandidatesFromECR copies the four real candidate images from
// ECR into a throwaway local registry, then pulls every one back with each blob checked
// against its digest. It needs registry credentials for the candidates in the Docker
// configuration (for ECR: log in with `aws ecr get-login-password`), downloads about 2 GB,
// and keeps the mirror on disk in a temporary directory that is removed afterwards.
//
//	IMAGE_SNAPSHOT_LIVE_CANDIDATES=1 go test -run TestLive_MirrorsTheCandidates -v -timeout 60m ./internal/imagesnapshot
func TestLive_MirrorsTheCandidatesFromECR(t *testing.T) {
	if os.Getenv("IMAGE_SNAPSHOT_LIVE_CANDIDATES") != "1" {
		t.Skip("set IMAGE_SNAPSHOT_LIVE_CANDIDATES=1 (and log in to the candidate registry) to mirror the real candidate images")
	}
	m, sum := loadCandidate(t)
	inv, err := BuildInventory(InventoryInput{Candidate: m, CandidateChecksum: sum})
	require.NoError(t, err)
	require.Len(t, inv.Images, 4, "the four candidate images")

	// A registry that keeps its blobs on disk, so gigabytes never sit in memory.
	blobs := t.TempDir()
	dst := serve(t, registry.New(registry.WithBlobHandler(registry.NewDiskBlobHandler(blobs))))

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Minute)
	defer cancel()
	start := time.Now()
	snap, err := Create(ctx, &Remote{}, inv, Options{Mirror: dst.Host + "/ai-tier", ID: "live-candidates"})
	for _, e := range snap.Spec.Entries {
		t.Logf("%-30s %-9s %s  mirror %s", e.Component, e.Status, e.Digest, strings.Replace(e.MirrorRef, dst.Host, "mirror.local", 1))
	}
	require.NoError(t, err)
	t.Logf("mirrored 4 images in %s", time.Since(start).Round(time.Second))

	// Pull every mirrored image back in full. Reading a layer verifies it against its
	// digest, so this proves the mirror holds intact copies of everything.
	for _, e := range snap.Spec.Entries {
		cfg, layers := pullFully(t, e.MirrorRef)
		assert.NotEmpty(t, layers, e.Component)
		t.Logf("pulled back %-28s config %.19s  %d layers, every blob verified", e.Component, cfg, len(layers))
	}

	assert.Empty(t, Preflight(ctx, &Remote{}, snap, inv, ProfileCPUOnly), "preflight passes for cpuOnly")
	assert.Empty(t, Preflight(ctx, &Remote{}, snap, inv, ProfileFullFeature), "and for fullfeature")
	path, _, err := (Store{Dir: t.TempDir()}).Put(snap)
	require.NoError(t, err)
	t.Logf("snapshot stored and checksummed: %s", filepath.Base(filepath.Dir(path)))
}
