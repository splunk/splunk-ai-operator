package airgapbundle

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

func importedTree(t *testing.T, dir string) map[string]string { // path -> sha256
	t.Helper()
	out := map[string]string{}
	require.NoError(t, filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		sum, _, err := fileSHA256(p)
		out[filepath.ToSlash(rel)] = sum
		return err
	}))
	return out
}

func TestImport_CopiesAVerifiedBundleIntoPlaceAndTheResultVerifies(t *testing.T) {
	f := newFixture(t)
	m := f.build()
	dest := t.TempDir()
	res, err := Import(f.dir, dest)
	require.NoError(t, err)
	assert.False(t, res.AlreadyImported)
	assert.Equal(t, len(m.Spec.Files), res.Copied)
	assert.Equal(t, filepath.Join(dest, m.Metadata.ID), res.Path)
	assert.Equal(t, importedTree(t, f.dir), importedTree(t, res.Path), "an exact copy")
	assert.Empty(t, Verify(ctx, res.Path, f.opts(imagesnapshot.ProfileFullFeature)), "the imported bundle passes the preflight")
	assert.NoDirExists(t, filepath.Join(dest, partialPrefix+m.Metadata.ID), "no partial directory is left")
}

func TestImport_IsANoOpWhenTheBundleIsAlreadyImported(t *testing.T) {
	f := newFixture(t)
	f.build()
	dest := t.TempDir()
	first, err := Import(f.dir, dest)
	require.NoError(t, err)
	info, _ := os.Stat(filepath.Join(first.Path, "binaries/k0s"))

	second, err := Import(f.dir, dest)
	require.NoError(t, err)
	assert.True(t, second.AlreadyImported)
	assert.Zero(t, second.Copied)
	after, _ := os.Stat(filepath.Join(first.Path, "binaries/k0s"))
	assert.Equal(t, info.ModTime(), after.ModTime(), "nothing was rewritten")
}

// An interrupted transfer leaves a partial directory with some files copied, one cut
// off mid-copy, a stray file and maybe a manifest. A retry keeps the intact files,
// copies the rest, removes what does not belong and only then accepts the bundle.
func TestImport_ResumesAnInterruptedImportWithoutTrustingWhatItLeft(t *testing.T) {
	f := newFixture(t)
	m := f.build()
	dest := t.TempDir()
	partial := filepath.Join(dest, partialPrefix+m.Metadata.ID)
	src := func(p string) []byte { b, _ := os.ReadFile(filepath.Join(f.dir, p)); return b }

	write(t, filepath.Join(partial, "binaries/k0s"), string(src("binaries/k0s")))                        // intact
	write(t, filepath.Join(partial, "images/k0s-images.tar"), string(src("images/k0s-images.tar")[:20])) // cut off
	write(t, filepath.Join(partial, "binaries/yq"), "tampered!")                                         // same size, wrong bytes
	write(t, filepath.Join(partial, "stray.tmp"), "left over")                                           // not in the bundle
	write(t, filepath.Join(partial, ManifestFile), "{}")                                                 // a stale manifest
	assert.NoDirExists(t, filepath.Join(dest, m.Metadata.ID), "not accepted while partial")

	res, err := Import(f.dir, dest)
	require.NoError(t, err)
	assert.Equal(t, 1, res.Reused, "only the intact file is reused")
	assert.Equal(t, len(m.Spec.Files)-1, res.Copied)
	assert.Equal(t, importedTree(t, f.dir), importedTree(t, res.Path))
	assert.NoFileExists(t, filepath.Join(res.Path, "stray.tmp"))
	assert.NoDirExists(t, partial)
}

func TestImport_RefusesADamagedSourceAndCopiesNothing(t *testing.T) {
	f := newFixture(t)
	m := f.build()
	write(t, filepath.Join(f.dir, "charts/kuberay-operator-1.2.2.tgz"), "chart but different")
	dest := t.TempDir()
	_, err := Import(f.dir, dest)
	var blocked *BlockedError
	require.True(t, errors.As(err, &blocked), "%v", err)
	assert.Equal(t, map[string]string{"charts/kuberay-operator-1.2.2.tgz": FindingFileChanged}, codes(blocked.Findings))
	assert.NoDirExists(t, filepath.Join(dest, m.Metadata.ID))
	assert.NoDirExists(t, filepath.Join(dest, partialPrefix+m.Metadata.ID))

	require.NoError(t, os.Remove(filepath.Join(f.dir, ChecksumFile)))
	_, err = Import(f.dir, dest)
	require.True(t, errors.As(err, &blocked))
	assert.Equal(t, FindingManifestInvalid, blocked.Findings[0].Code)
}

func TestImport_NeverOverwritesAnImportedBundle(t *testing.T) {
	t.Run("damaged in place", func(t *testing.T) {
		f := newFixture(t)
		f.build()
		dest := t.TempDir()
		res, err := Import(f.dir, dest)
		require.NoError(t, err)
		write(t, filepath.Join(res.Path, "binaries/yq"), "corrupted")
		_, err = Import(f.dir, dest)
		var blocked *BlockedError
		require.True(t, errors.As(err, &blocked))
		assert.Equal(t, FindingFileChanged, codes(blocked.Findings)["binaries/yq"])
		b, _ := os.ReadFile(filepath.Join(res.Path, "binaries/yq"))
		assert.Equal(t, "corrupted", string(b), "reported, not silently repaired or replaced")
	})
	t.Run("a different bundle under the same ID", func(t *testing.T) {
		f := newFixture(t)
		m := f.build()
		dest := t.TempDir()
		_, err := Import(f.dir, dest)
		require.NoError(t, err)

		g := newFixture(t)
		g.models = nil
		other, err := Build(g.dir, BuildOptions{ID: m.Metadata.ID, SnapshotPath: g.snapshot})
		require.NoError(t, err)
		_, err = Write(g.dir, other)
		require.NoError(t, err)
		_, err = Import(g.dir, dest)
		var blocked *BlockedError
		require.True(t, errors.As(err, &blocked))
		assert.Contains(t, blocked.Findings[0].Message, "a different bundle is already imported under this ID")
	})
}

// A copy is checked against the manifest before it is renamed into place: a source that
// changed after it was verified is never accepted.
func TestCopyVerified_ACopyThatDoesNotMatchTheManifestIsNotPutInPlace(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	write(t, src, "the bytes that were verified... then changed")
	dst := filepath.Join(dir, "out", "dst")
	err := copyVerified(src, dst, File{Path: "dst", Size: 5, SHA256: strings.Repeat("0", 64)})
	assert.ErrorContains(t, err, "the source changed during the import")
	assert.NoFileExists(t, dst)
	entries, _ := os.ReadDir(filepath.Dir(dst))
	assert.Empty(t, entries, "no temporary file is left behind")
}

// Files a previous attempt left that the bundle does not have are removed, nested ones too.
func TestPrune_RemovesEverythingTheManifestDoesNotList(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "keep"), "k")
	write(t, filepath.Join(dir, "a/b/stray"), "s")
	require.NoError(t, prune(dir, map[string]bool{"keep": true}))
	assert.FileExists(t, filepath.Join(dir, "keep"))
	assert.NoFileExists(t, filepath.Join(dir, "a/b/stray"))
}
