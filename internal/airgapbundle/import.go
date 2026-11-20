package airgapbundle

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// ImportResult describes an import.
type ImportResult struct {
	ID   string
	Path string // the imported bundle directory
	// AlreadyImported is set when an intact copy of the same bundle was already in place.
	AlreadyImported bool
	Copied, Reused  int // files copied now, and files a previous, interrupted import had already copied
}

// BlockedError is returned when a bundle cannot be imported; it lists every reason.
type BlockedError struct{ Findings []Finding }

func (e *BlockedError) Error() string {
	var parts []string
	for _, f := range e.Findings {
		parts = append(parts, f.String())
	}
	return "import refused: " + strings.Join(parts, "; ")
}

// partialPrefix names the directory an import is assembled in. It is derived from the
// bundle ID alone, so a retried import resumes the same directory.
const partialPrefix = ".partial-"

// Import copies the bundle in src into <dest>/<bundle id>.
//
// The source is verified first, so nothing is copied from a damaged or altered bundle.
// The copy is assembled in <dest>/.partial-<bundle id>; a file a previous attempt already
// copied intact is reused, a damaged one is copied again. Only when every file matches
// the manifest is the manifest written and the directory renamed into place, so the
// destination never holds a partially accepted bundle. Importing a bundle that is
// already in place and intact changes nothing. A different or damaged bundle under the
// same ID is refused, never overwritten.
func Import(src, dest string) (*ImportResult, error) {
	m, sum, err := Read(src)
	if err != nil {
		return nil, &BlockedError{[]Finding{{Component: ManifestFile, Code: FindingManifestInvalid, Message: err.Error()}}}
	}
	if f := checkFiles(src, m); len(f) > 0 {
		return nil, &BlockedError{f}
	}
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return nil, err
	}
	res := &ImportResult{ID: m.Metadata.ID, Path: filepath.Join(dest, m.Metadata.ID)}

	if _, err := os.Stat(res.Path); err == nil {
		got, gotSum, err := Read(res.Path)
		switch {
		case err != nil:
			return nil, &BlockedError{[]Finding{{Component: res.Path, Code: FindingManifestInvalid,
				Message: "a bundle is already imported under this ID and its manifest is unreadable: " + err.Error() + "; remove it to import again"}}}
		case gotSum != sum || got.Metadata.ID != m.Metadata.ID:
			return nil, &BlockedError{[]Finding{{Component: res.Path, Code: FindingManifestInvalid,
				Message: "a different bundle is already imported under this ID; imported bundles are never overwritten"}}}
		}
		if f := checkFiles(res.Path, got); len(f) > 0 {
			return nil, &BlockedError{f}
		}
		res.AlreadyImported = true
		return res, nil
	}

	partial := filepath.Join(dest, partialPrefix+m.Metadata.ID)
	if err := os.MkdirAll(partial, 0o755); err != nil {
		return nil, err
	}
	listed := map[string]bool{}
	for _, f := range m.Spec.Files {
		listed[f.Path] = true
		target := filepath.Join(partial, filepath.FromSlash(f.Path))
		if matches(target, f) {
			res.Reused++
			continue
		}
		if err := copyVerified(filepath.Join(src, filepath.FromSlash(f.Path)), target, f); err != nil {
			return nil, fmt.Errorf("copy %s: %w", f.Path, err)
		}
		res.Copied++
	}
	// Remove anything a previous attempt left that the manifest does not list, including
	// a manifest it may have written, so the result is exactly this bundle.
	if err := prune(partial, listed); err != nil {
		return nil, err
	}
	for _, name := range []string{ManifestFile, ChecksumFile} {
		b, err := os.ReadFile(filepath.Join(src, name))
		if err != nil {
			return nil, err
		}
		if err := writeAtomic(filepath.Join(partial, name), b); err != nil {
			return nil, err
		}
	}
	if _, _, err := Read(partial); err != nil {
		return nil, err
	}
	if f := checkFiles(partial, m); len(f) > 0 {
		return nil, &BlockedError{f}
	}
	if err := os.Rename(partial, res.Path); err != nil {
		return nil, err
	}
	syncDir(dest)
	return res, nil
}

// matches reports whether p already holds f, by size and checksum.
func matches(p string, f File) bool {
	info, err := os.Lstat(p)
	if err != nil || !info.Mode().IsRegular() || info.Size() != f.Size {
		return false
	}
	sum, _, err := fileSHA256(p)
	return err == nil && sum == f.SHA256
}

// copyVerified copies src to dst through a temporary file, checking the bytes written
// against the manifest before renaming them into place.
func copyVerified(src, dst string, f File) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".tmp-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // a no-op once renamed
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), in)
	if err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if sum := hex.EncodeToString(h.Sum(nil)); n != f.Size || sum != f.SHA256 {
		return fmt.Errorf("the copy does not match the manifest (%d bytes, %s): the source changed during the import", n, short(sum))
	}
	if info, err := os.Stat(src); err == nil {
		_ = os.Chmod(tmp.Name(), info.Mode().Perm())
	}
	return os.Rename(tmp.Name(), dst)
}

func prune(dir string, keep map[string]bool) error {
	var extra []string
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		if !keep[filepath.ToSlash(rel)] {
			extra = append(extra, p)
		}
		return nil
	})
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	for _, p := range extra {
		if err := os.Remove(p); err != nil {
			return err
		}
	}
	return nil
}

func syncDir(dir string) {
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
}
