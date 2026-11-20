package imagesnapshot

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const (
	manifestFile = "manifest.json"
	checksumFile = "manifest.json.sha256"
)

// Marshal returns the canonical bytes of a snapshot: indented JSON in a fixed field
// order, with a trailing newline. The same snapshot always produces the same bytes.
func Marshal(snap *Snapshot) ([]byte, error) {
	b, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// Store keeps snapshots as <dir>/<id>/manifest.json. A snapshot, once written, is
// never rewritten or deleted by this package, so a moved tag cannot change what an
// earlier test run was based on.
type Store struct{ Dir string }

// Path returns where the snapshot with the given ID lives. The ID must already be valid.
func (s Store) Path(id string) string { return filepath.Join(s.Dir, id, manifestFile) }

var validID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// ValidateID reports whether id can name a snapshot: letters, digits, dot, dash and
// underscore, starting with a letter or digit, so it can never leave the store directory.
func ValidateID(id string) error {
	if !validID.MatchString(id) || strings.Contains(id, "..") {
		return fmt.Errorf("snapshot ID %q is not usable as a directory name (letters, digits, '.', '-' and '_' only)", id)
	}
	return nil
}

// Exists reports whether a snapshot with the given ID is already stored.
func (s Store) Exists(id string) bool {
	if ValidateID(id) != nil {
		return false
	}
	_, err := os.Stat(filepath.Join(s.Dir, id))
	return err == nil
}

// DefaultID is the ID a snapshot of inv gets when none is given.
func DefaultID(inv *Inventory) string { return defaultID(inv) }

// Put writes a complete snapshot and its checksum file. It refuses an ID that already
// exists, a snapshot that is not complete, and any content that looks like a credential.
//
// The snapshot is written into a temporary directory inside the store and then moved into
// place, so a crash or a write error never leaves a half-written snapshot that would also
// use up the ID.
func (s Store) Put(snap *Snapshot) (path, checksum string, err error) {
	if err := ValidateID(snap.Metadata.ID); err != nil {
		return "", "", err
	}
	if err := Validate(snap); err != nil {
		return "", "", err
	}
	b, err := Marshal(snap)
	if err != nil {
		return "", "", err
	}
	if err := CheckNoCredentials(b); err != nil {
		return "", "", err
	}
	if err := os.MkdirAll(s.Dir, 0o755); err != nil {
		return "", "", err
	}
	final := filepath.Join(s.Dir, snap.Metadata.ID)
	if _, err := os.Stat(final); err == nil {
		return "", "", fmt.Errorf("snapshot %q already exists: snapshots are never rewritten, choose a new ID", snap.Metadata.ID)
	}
	tmp, err := os.MkdirTemp(s.Dir, ".tmp-"+snap.Metadata.ID+"-")
	if err != nil {
		return "", "", err
	}
	defer os.RemoveAll(tmp) // a no-op once the directory has been moved into place
	sum := Checksum(b)
	if err := os.WriteFile(filepath.Join(tmp, manifestFile), b, 0o644); err != nil {
		return "", "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, checksumFile), []byte(sum+"  "+manifestFile+"\n"), 0o644); err != nil {
		return "", "", err
	}
	if err := os.Rename(tmp, final); err != nil {
		if _, statErr := os.Stat(final); statErr == nil {
			return "", "", fmt.Errorf("snapshot %q already exists: snapshots are never rewritten, choose a new ID", snap.Metadata.ID)
		}
		return "", "", err
	}
	return filepath.Join(final, manifestFile), sum, nil
}

// Get reads a stored snapshot and checks it against its checksum file.
func (s Store) Get(id string) (*Snapshot, error) {
	if err := ValidateID(id); err != nil {
		return nil, err
	}
	return ReadSnapshot(s.Path(id))
}

// ReadSnapshot reads the snapshot at path and verifies it against <path>.sha256. A
// snapshot without its checksum file is refused: without it there is no way to tell that
// the file is the one that was written.
func ReadSnapshot(path string) (*Snapshot, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	want, err := os.ReadFile(path + ".sha256")
	if err != nil {
		return nil, fmt.Errorf("%s has no checksum file (%s.sha256): it cannot be trusted", path, filepath.Base(path))
	}
	fields := strings.Fields(string(want))
	if len(fields) == 0 || fields[0] != Checksum(b) {
		return nil, fmt.Errorf("%s does not match its checksum file: the snapshot was modified after it was written", path)
	}
	var snap Snapshot
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&snap); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &snap, nil
}

// List returns the IDs of the stored snapshots, oldest name first.
func (s Store) List() ([]string, error) {
	entries, err := os.ReadDir(s.Dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			continue // a snapshot being written
		}
		if _, err := os.Stat(filepath.Join(s.Dir, e.Name(), checksumFile)); err == nil {
			ids = append(ids, e.Name())
		}
	}
	sort.Strings(ids)
	return ids, nil
}

var digestRe = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// Validate checks that a snapshot is complete and internally consistent: every entry
// is verified, has a sha256 digest, and its mirror reference is pinned to that digest.
func Validate(snap *Snapshot) error {
	if snap.RecordType != RecordType || snap.SchemaVersion != SchemaVersion {
		return fmt.Errorf("not a %s record of schema version %d", RecordType, SchemaVersion)
	}
	if snap.Spec.Mirror == "" || snap.Spec.InventoryChecksum == "" || snap.Spec.Candidate.Checksum == "" {
		return fmt.Errorf("snapshot is missing its mirror, inventory checksum or candidate checksum")
	}
	if len(snap.Spec.Entries) == 0 {
		return fmt.Errorf("snapshot has no entries")
	}
	var problems []string
	for _, e := range snap.Spec.Entries {
		switch {
		case e.Status != StatusVerified:
			problems = append(problems, fmt.Sprintf("%s: status is %q, not verified", e.Component, e.Status))
		case !digestRe.MatchString(e.Digest):
			problems = append(problems, fmt.Sprintf("%s: digest is not a sha256 digest", e.Component))
		case !strings.HasSuffix(e.MirrorRef, "@"+e.Digest):
			problems = append(problems, fmt.Sprintf("%s: mirror reference is not pinned to the entry's digest", e.Component))
		case !strings.HasPrefix(e.MirrorRef, strings.TrimSuffix(snap.Spec.Mirror, "/")+"/"):
			problems = append(problems, fmt.Sprintf("%s: mirror reference is not under the snapshot's mirror", e.Component))
		case e.Source == "" || e.Owner == "" || len(e.Profiles) == 0:
			problems = append(problems, fmt.Sprintf("%s: missing source, owner or profiles", e.Component))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("snapshot is not complete: %s", strings.Join(problems, "; "))
	}
	return nil
}

var credentialShapes = []*regexp.Regexp{
	regexp.MustCompile(`://[^/\s"@]+:[^/\s"@]+@`), // user:password@host
	regexp.MustCompile(`(?i)"(password|passwd|token|secret|authorization|auth|credentials?)"\s*:`),
	regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}`),
}

// CheckNoCredentials fails closed if the serialized snapshot looks like it carries a
// registry password, token or userinfo. The snapshot is built only from references
// and digests, so this is a guard against a future change, not a filter.
func CheckNoCredentials(b []byte) error {
	for _, re := range credentialShapes {
		if re.Match(b) {
			return fmt.Errorf("refusing to write a snapshot that contains credential-like content")
		}
	}
	return nil
}
