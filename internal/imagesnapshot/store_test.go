package imagesnapshot

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// completeSnapshot builds a snapshot from real registries.
func completeSnapshot(t *testing.T, src, dst *testRegistry, id string) *Snapshot {
	t.Helper()
	src.pushImage("a/b", "v1", "linux", "amd64", nil)
	snap, err := Create(context.Background(), newCounting(), inventoryOf(imageOf("b", src.ref("a/b", "v1"))), Options{Mirror: dst.Host, ID: id})
	require.NoError(t, err)
	return snap
}

func TestStore_PutWritesTheManifestAndItsChecksum(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	snap := completeSnapshot(t, src, dst, "run-1")
	s := Store{Dir: filepath.Join(t.TempDir(), "snapshots")}

	path, sum, err := s.Put(snap)
	require.NoError(t, err)
	assert.Equal(t, s.Path("run-1"), path)

	b, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, Checksum(b), sum)
	sumFile, err := os.ReadFile(path + ".sha256")
	require.NoError(t, err)
	assert.Equal(t, sum+"  manifest.json\n", string(sumFile))

	got, err := s.Get("run-1")
	require.NoError(t, err)
	assert.Equal(t, snap.Spec.Entries[0].Digest, got.Spec.Entries[0].Digest)

	ids, err := s.List()
	require.NoError(t, err)
	assert.Equal(t, []string{"run-1"}, ids)
}

func TestStore_SerializationIsDeterministic(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	snap := completeSnapshot(t, src, dst, "run-1")
	a, err := Marshal(snap)
	require.NoError(t, err)
	b, err := Marshal(snap)
	require.NoError(t, err)
	assert.Equal(t, a, b)
	assert.True(t, strings.HasSuffix(string(a), "}\n"))
}

// A snapshot is never rewritten, so a moved tag cannot change what an earlier test
// run was based on.
func TestStore_NeverRewritesAnExistingSnapshot(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	snap := completeSnapshot(t, src, dst, "run-1")
	s := Store{Dir: t.TempDir()}
	path, _, err := s.Put(snap)
	require.NoError(t, err)
	before, err := os.ReadFile(path)
	require.NoError(t, err)

	changed := *snap
	changed.Spec.Entries = append([]Entry(nil), snap.Spec.Entries...)
	changed.Spec.Entries[0].Digest = "sha256:" + strings.Repeat("9", 64)
	changed.Spec.Entries[0].MirrorRef = changed.Spec.Mirror + "/x@" + changed.Spec.Entries[0].Digest
	_, _, err = s.Put(&changed)
	require.Error(t, err)
	assert.ErrorContains(t, err, `snapshot "run-1" already exists`)

	after, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, before, after, "the stored snapshot is byte-for-byte unchanged")
}

func TestStore_DetectsAModifiedSnapshot(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	s := Store{Dir: t.TempDir()}
	path, _, err := s.Put(completeSnapshot(t, src, dst, "run-1"))
	require.NoError(t, err)

	b, err := os.ReadFile(path)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(path, []byte(strings.Replace(string(b), `"owner": "unassigned"`, `"owner": "someone"`, 1)), 0o644))
	_, err = s.Get("run-1")
	assert.ErrorContains(t, err, "does not match its checksum file")
}

func TestStore_RefusesAnIncompleteSnapshot(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	s := Store{Dir: t.TempDir()}
	for name, mutate := range map[string]func(*Snapshot){
		"a blocked entry":         func(sn *Snapshot) { sn.Spec.Entries[0].Status = StatusBlocked },
		"a resolved, unmirrored":  func(sn *Snapshot) { sn.Spec.Entries[0].Status = StatusResolved },
		"a mirror ref not pinned": func(sn *Snapshot) { sn.Spec.Entries[0].MirrorRef = "mirror/a/b:v1" },
		"a malformed digest":      func(sn *Snapshot) { sn.Spec.Entries[0].Digest = "latest" },
		"no entries":              func(sn *Snapshot) { sn.Spec.Entries = nil },
		"no inventory checksum":   func(sn *Snapshot) { sn.Spec.InventoryChecksum = "" },
		"an unusable snapshot ID": func(sn *Snapshot) { sn.Metadata.ID = "../escape" },
	} {
		snap := completeSnapshot(t, src, dst, "run-x")
		mutate(snap)
		_, _, err := s.Put(snap)
		assert.Error(t, err, name)
	}
	ids, _ := s.List()
	assert.Empty(t, ids, "nothing was stored")
}

// The artifact excludes credentials. The snapshot is built from references and digests
// only, and Put also refuses content that looks like a credential.
func TestStore_RefusesCredentialLookingContent(t *testing.T) {
	src, dst := newTestRegistry(t), newTestRegistry(t)
	s := Store{Dir: t.TempDir()}
	for name, mutate := range map[string]func(*Snapshot){
		"userinfo in a reference": func(sn *Snapshot) { sn.Spec.Entries[0].Source = "https://user:s3cr3t@registry.example/a/b:v1" },
		"a bearer token in a blocker": func(sn *Snapshot) {
			sn.Spec.Entries[0].Blocker = "Bearer abcdefghijklmnop"
		},
	} {
		snap := completeSnapshot(t, src, dst, "run-"+strings.ReplaceAll(name, " ", "-"))
		mutate(snap)
		_, _, err := s.Put(snap)
		require.Error(t, err, name)
		assert.ErrorContains(t, err, "credential", name)
	}

	// A normal snapshot, however it is built, carries no credential-shaped text.
	snap := completeSnapshot(t, src, dst, "clean")
	b, err := Marshal(snap)
	require.NoError(t, err)
	assert.NoError(t, CheckNoCredentials(b))
	for _, forbidden := range []string{"password", "token", "secret", "authorization"} {
		assert.NotContains(t, strings.ToLower(string(b)), forbidden)
	}
}

func TestStore_ListIgnoresDirectoriesWithoutAManifest(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.MkdirAll(filepath.Join(dir, "junk"), 0o755))
	ids, err := Store{Dir: dir}.List()
	require.NoError(t, err)
	assert.Empty(t, ids)
	ids, err = Store{Dir: filepath.Join(dir, "missing")}.List()
	require.NoError(t, err)
	assert.Empty(t, ids)
}
