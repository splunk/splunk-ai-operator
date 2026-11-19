package imagesnapshot

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	"github.com/google/go-containerregistry/pkg/registry"
	v1 "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/mutate"
	"github.com/google/go-containerregistry/pkg/v1/random"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/types"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// These tests cover what real registries do that a plain in-memory registry does not
// by default: attestation entries in an index, Docker manifest lists, authentication,
// a mirror that refuses writes, cancellation, multi-layer images and unreachable hosts.

func serve(t *testing.T, h http.Handler) *testRegistry {
	t.Helper()
	s := httptest.NewServer(h)
	t.Cleanup(s.Close)
	return &testRegistry{t: t, server: s, Host: strings.TrimPrefix(s.URL, "http://")}
}

// basicAuth wraps a registry so every request needs the given credentials.
func basicAuth(next http.Handler, user, pass string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if u, p, ok := r.BasicAuth(); !ok || u != user || p != pass {
			w.Header().Set("WWW-Authenticate", `Basic realm="registry"`)
			http.Error(w, `{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}`, http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// readOnly makes a registry refuse every write, as a mirror with no push permission does.
func readOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPut, http.MethodPost, http.MethodPatch, http.MethodDelete:
			http.Error(w, `{"errors":[{"code":"DENIED","message":"requested access to the resource is denied"}]}`, http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func useDockerConfig(t *testing.T, host, user, pass string) {
	t.Helper()
	dir := t.TempDir()
	auth := base64.StdEncoding.EncodeToString([]byte(user + ":" + pass))
	cfg, _ := json.Marshal(map[string]any{"auths": map[string]any{host: map[string]string{"auth": auth}}})
	require.NoError(t, os.WriteFile(filepath.Join(dir, "config.json"), cfg, 0o600))
	t.Setenv("DOCKER_CONFIG", dir)
}

// pullFully reads every layer of an image from a registry, which verifies each blob's
// digest as it is read, and returns the config digest and the layer digests.
func pullFully(t *testing.T, ref string) (config string, layers []string) {
	t.Helper()
	d, err := name.NewDigest(ref)
	require.NoError(t, err)
	img, err := remote.Image(d)
	require.NoError(t, err)
	cfg, err := img.ConfigName()
	require.NoError(t, err)
	ls, err := img.Layers()
	require.NoError(t, err)
	for _, l := range ls {
		rc, err := l.Compressed()
		require.NoError(t, err)
		_, err = io.Copy(io.Discard, rc) // the library checks the digest as the blob is read
		require.NoError(t, err)
		require.NoError(t, rc.Close())
		dg, err := l.Digest()
		require.NoError(t, err)
		layers = append(layers, dg.String())
	}
	return cfg.String(), layers
}

func TestDescribe_AnIndexWithAnAttestationEntryStillYieldsTheAmd64Image(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	amd, arm, attest := platformImage(t, "linux", "amd64", nil), platformImage(t, "linux", "arm64", nil), platformImage(t, "linux", "amd64", nil)
	var idx v1.ImageIndex = empty.Index
	idx = mutate.AppendManifests(idx,
		mutate.IndexAddendum{Add: amd, Descriptor: v1.Descriptor{Platform: &v1.Platform{OS: "linux", Architecture: "amd64"}}},
		mutate.IndexAddendum{Add: arm, Descriptor: v1.Descriptor{Platform: &v1.Platform{OS: "linux", Architecture: "arm64"}}},
		// BuildKit attaches provenance as an extra entry whose platform is unknown/unknown.
		mutate.IndexAddendum{Add: attest, Descriptor: v1.Descriptor{Platform: &v1.Platform{OS: "unknown", Architecture: "unknown"}}},
	)
	ref, _ := name.NewTag(src.ref("tier/app", "v1"))
	require.NoError(t, remote.WriteIndex(ref, idx))
	wantDigest, _ := amd.Digest()

	snap, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("app", src.ref("tier/app", "v1"))), Options{Mirror: dst.Host})
	require.NoError(t, err)
	e := snap.Spec.Entries[0]
	assert.Equal(t, wantDigest.String(), e.Digest)
	assert.Equal(t, []string{"linux/amd64", "linux/arm64"}, e.Platforms, "the attestation entry is not a platform")
}

func TestDescribe_ADockerManifestListIsHandledLikeAnOCIIndex(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	amd := platformImage(t, "linux", "amd64", nil)
	idx := mutate.IndexMediaType(mutate.AppendManifests(empty.Index,
		mutate.IndexAddendum{Add: amd, Descriptor: v1.Descriptor{Platform: &v1.Platform{OS: "linux", Architecture: "amd64"}}},
		mutate.IndexAddendum{Add: platformImage(t, "linux", "s390x", nil), Descriptor: v1.Descriptor{Platform: &v1.Platform{OS: "linux", Architecture: "s390x"}}},
	), types.DockerManifestList)
	ref, _ := name.NewTag(src.ref("tier/legacy", "v1"))
	require.NoError(t, remote.WriteIndex(ref, idx))
	want, _ := amd.Digest()

	d, err := (&Remote{}).Describe(context.Background(), src.ref("tier/legacy", "v1"))
	require.NoError(t, err)
	assert.Equal(t, want.String(), d.PlatformDigests["linux/amd64"])

	snap, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("legacy", src.ref("tier/legacy", "v1"))), Options{Mirror: dst.Host})
	require.NoError(t, err)
	assert.Equal(t, want.String(), snap.Spec.Entries[0].Digest)
}

// Mirroring must copy every blob, not just the manifest: the mirrored image is pulled
// in full and each layer is checked against its digest.
func TestCreate_MirrorsEveryLayerOfAMultiLayerImageIntact(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	img, err := random.Image(4096, 6)
	require.NoError(t, err)
	cfg, _ := img.ConfigFile()
	cfg = cfg.DeepCopy()
	cfg.OS, cfg.Architecture = "linux", "amd64"
	img, err = mutate.ConfigFile(img, cfg)
	require.NoError(t, err)
	ref, _ := name.NewTag(src.ref("tier/big", "v1"))
	require.NoError(t, remote.Write(ref, img))

	snap, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("big", src.ref("tier/big", "v1"))), Options{Mirror: dst.Host})
	require.NoError(t, err)
	e := snap.Spec.Entries[0]

	srcConfig, srcLayers := pullFully(t, src.Host+"/tier/big@"+e.Digest)
	dstConfig, dstLayers := pullFully(t, e.MirrorRef)
	assert.Len(t, dstLayers, 6)
	assert.Equal(t, srcConfig, dstConfig, "the config blob is copied unchanged")
	assert.Equal(t, srcLayers, dstLayers, "every layer is copied unchanged")
}

func TestCreate_SourcesPinnedByDigestAreResolvedAsGiven(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	d := src.pushImage("tier/pinned", "v1", "linux", "amd64", nil)
	pinned := src.Host + "/tier/pinned@" + d
	tagAndDigest := src.ref("tier/pinned", "v1") + "@" + d

	for _, source := range []string{pinned, tagAndDigest} {
		snap, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("pinned", source)), Options{Mirror: dst.Host})
		require.NoError(t, err, source)
		e := snap.Spec.Entries[0]
		assert.Equal(t, d, e.Digest, source)
		assert.Equal(t, source, e.Source, "recorded exactly as supplied")
		assert.True(t, strings.HasSuffix(e.MirrorRef, "/tier/pinned@"+d), e.MirrorRef)
	}
}

func TestCreate_ACancelledContextBlocksEverythingAndCopiesNothing(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("a/b", "v1", "linux", "amd64", nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	reg := newCounting()
	_, err := Create(ctx, reg, inventoryOf(imageOf("b", src.ref("a/b", "v1"))), Options{Mirror: dst.Host})
	var blocked *BlockedError
	require.ErrorAs(t, err, &blocked)
	assert.Contains(t, blocked.Blockers[0].Reason, "context canceled")
	assert.Empty(t, reg.Copies)
}

func TestCreate_AnUnreachableSourceIsAnExternalBlockerNotAHang(t *testing.T) {
	_, dst := newTestRegistry(t), newTestRegistry(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	start := time.Now()
	_, err := Create(ctx, newCounting(), inventoryOf(imageOf("gone", "127.0.0.1:1/never/there:v1")), Options{Mirror: dst.Host})
	var blocked *BlockedError
	require.ErrorAs(t, err, &blocked)
	assert.Contains(t, blocked.Blockers[0].Reason, "unresolved")
	assert.Less(t, time.Since(start), 15*time.Second)
}

// A mirror the account may read but not write to fails the snapshot as a blocker; no
// entry is marked verified.
func TestCreate_AMirrorThatRefusesWritesBlocksTheSnapshot(t *testing.T) {
	src := newTestRegistry(t)
	dst := serve(t, readOnly(registry.New()))
	src.pushImage("a/b", "v1", "linux", "amd64", nil)
	snap, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("b", src.ref("a/b", "v1"))), Options{Mirror: dst.Host})
	var blocked *BlockedError
	require.ErrorAs(t, err, &blocked)
	assert.Contains(t, blocked.Blockers[0].Reason, "mirror failed")
	assert.Equal(t, StatusBlocked, snap.Spec.Entries[0].Status)
	assert.Empty(t, snap.Spec.Entries[0].MirrorRef)
}

// Registry credentials come from the local Docker configuration and nowhere else, and
// never appear in the snapshot, the log lines or recorded errors.
func TestAuthentication_UsesTheDockerConfigAndNeverRecordsTheCredential(t *testing.T) {
	const user, pass = "mirror-bot", "s3cr3t-Passw0rd-xyz"
	src := serve(t, basicAuth(registry.New(), "reader", "reader-pw-123"))
	dst := serve(t, basicAuth(registry.New(), user, pass))

	// Seed the source with credentials of its own.
	seedCfg := t.TempDir()
	auth := func(h, u, p string) map[string]string {
		return map[string]string{h: base64.StdEncoding.EncodeToString([]byte(u + ":" + p))}
	}
	cfgJSON, _ := json.Marshal(map[string]any{"auths": map[string]any{
		src.Host: map[string]string{"auth": auth(src.Host, "reader", "reader-pw-123")[src.Host]},
		dst.Host: map[string]string{"auth": auth(dst.Host, user, pass)[dst.Host]},
	}})
	require.NoError(t, os.WriteFile(filepath.Join(seedCfg, "config.json"), cfgJSON, 0o600))
	t.Setenv("DOCKER_CONFIG", seedCfg)
	seedRef, err := name.NewTag(src.ref("tier/secure", "v1"))
	require.NoError(t, err)
	require.NoError(t, remote.Write(seedRef, platformImage(t, "linux", "amd64", nil),
		remote.WithAuth(&authn.Basic{Username: "reader", Password: "reader-pw-123"}))) // the protected source needs credentials to seed

	t.Run("with credentials the snapshot is created", func(t *testing.T) {
		snap, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("secure", src.ref("tier/secure", "v1"))), Options{Mirror: dst.Host, ID: "auth-ok"})
		require.NoError(t, err)
		require.Equal(t, StatusVerified, snap.Spec.Entries[0].Status)
		b, err := Marshal(snap)
		require.NoError(t, err)
		for _, secret := range []string{pass, "reader-pw-123", base64.StdEncoding.EncodeToString([]byte(user + ":" + pass)), "Authorization", "Basic "} {
			assert.NotContains(t, string(b), secret, "the snapshot must not contain %q", secret)
		}
		_, _, err = (Store{Dir: t.TempDir()}).Put(snap)
		assert.NoError(t, err)
	})

	t.Run("without credentials it is an external blocker and nothing leaks", func(t *testing.T) {
		t.Setenv("DOCKER_CONFIG", t.TempDir()) // an empty configuration
		snap, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("secure", src.ref("tier/secure", "v1"))), Options{Mirror: dst.Host})
		var blocked *BlockedError
		require.ErrorAs(t, err, &blocked)
		assert.Contains(t, strings.ToLower(blocked.Blockers[0].Reason), "unresolved")
		b, _ := Marshal(snap)
		assert.NotContains(t, string(b), pass)
		assert.NotContains(t, blocked.Error(), pass)
	})

	t.Run("wrong credentials fail without echoing them", func(t *testing.T) {
		useDockerConfig(t, src.Host, "reader", "WRONG-password-999")
		_, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("secure", src.ref("tier/secure", "v1"))), Options{Mirror: dst.Host})
		require.Error(t, err)
		assert.NotContains(t, err.Error(), "WRONG-password-999")
	})
}

func TestCreate_RepeatedRunsAreIdempotentAndByteIdentical(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	src.pushImage("a/b", "v1", "linux", "amd64", nil)
	inv := inventoryOf(imageOf("b", src.ref("a/b", "v1")))

	first, err := Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host, ID: "same"})
	require.NoError(t, err)
	// The image is already in the mirror: mirroring again succeeds and changes nothing.
	second, err := Create(context.Background(), newCounting(), inv, Options{Mirror: dst.Host, ID: "same"})
	require.NoError(t, err)

	a, err := Marshal(first)
	require.NoError(t, err)
	b, err := Marshal(second)
	require.NoError(t, err)
	assert.Equal(t, string(a), string(b), "the same inputs produce the same snapshot bytes")
}

func TestReadSnapshot_RejectsUnknownFieldsAndOtherSchemaVersions(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	snap := completeSnapshot(t, src, dst, "run-1")
	good, err := Marshal(snap)
	require.NoError(t, err)

	dir := t.TempDir()
	write := func(body string) string {
		p := filepath.Join(dir, "m.json")
		require.NoError(t, os.WriteFile(p, []byte(body), 0o644))
		return p
	}
	_, err = ReadSnapshot(write(strings.Replace(string(good), `"schemaVersion": 1`, `"schemaVersion": 1, "surprise": true`, 1)))
	assert.Error(t, err, "an unknown field is rejected, not silently dropped")

	other := *snap
	other.SchemaVersion = 2
	assert.ErrorContains(t, Validate(&other), "schema version")
	_, err = ReadSnapshot(write("not json"))
	assert.Error(t, err)
	_, err = ReadSnapshot(filepath.Join(dir, "missing.json"))
	assert.Error(t, err)
}

func TestParseRef_NeverPanicsAndRejectsGarbage(t *testing.T) {
	for _, bad := range []string{"", " ", "UPPER/Case:tag", "a b", "@sha256:abc", "host:99999999/x:y", "//", ":::", strings.Repeat("a", 400) + "/x:1"} {
		assert.NotPanics(t, func() { _, _ = ParseRef(bad) }, bad)
	}
	for _, bad := range []string{"", "UPPER/Case:tag", "a b", "@sha256:abc"} {
		_, err := ParseRef(bad)
		assert.Error(t, err, "%q", bad)
	}
	p, err := ParseRef("  quay.io/a/b:1  ")
	require.NoError(t, err)
	assert.Equal(t, "quay.io/a/b:1", p.String(), "surrounding whitespace is tolerated")
}

func TestBuildInventory_IgnoresNullAndBlankConfiguredImages(t *testing.T) {
	in := fullInput(t)
	in.Installer = InstallerConfig{}
	in.Installer.Images.Weaviate.Image = "null" // what yq prints for an absent key
	in.Installer.Images.Nginx.Image = "   "
	in.Installer.Images.Ray.HeadImage = "docker.io/rayproject/ray:2.44.0"
	inv, err := BuildInventory(in)
	require.NoError(t, err)
	c := components(inv.Images)
	assert.NotContains(t, c, "weaviate")
	assert.NotContains(t, c, "nginx")
	assert.Contains(t, c, "ray-head")
}
