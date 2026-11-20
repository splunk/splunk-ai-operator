package airgapbundle

import (
	"archive/tar"
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

// BuildOptions are the inputs of a bundle manifest besides the bundle directory.
type BuildOptions struct {
	// ID names the bundle. Empty means <snapshot id>-<first 12 hex of the content checksum>.
	ID string
	// SnapshotPath is the snapshot manifest.json the install pulls from (required).
	SnapshotPath string
	// Models are the model artifacts the fullfeature profile needs (see ReadModelConfig).
	Models []Model
}

// Build describes the bundle in dir. It reads every file once to checksum it and the
// image archives to record the digest of each image; it writes nothing.
func Build(dir string, opts BuildOptions) (*Manifest, error) {
	if opts.SnapshotPath == "" {
		return nil, errors.New("an image snapshot is required: the install pulls every image from its mirror references")
	}
	snap, err := imagesnapshot.ReadSnapshot(opts.SnapshotPath)
	if err != nil {
		return nil, fmt.Errorf("image snapshot: %w", err)
	}
	raw, err := os.ReadFile(opts.SnapshotPath)
	if err != nil {
		return nil, err
	}
	m := &Manifest{SchemaVersion: SchemaVersion, Kind: Kind, Spec: Spec{
		Platform: Platform,
		Snapshot: SnapshotRef{ID: snap.Metadata.ID, Checksum: imagesnapshot.Checksum(raw), Mirror: snap.Spec.Mirror},
	}}
	files, err := walk(dir)
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("%s holds no bundle files", dir)
	}
	m.Spec.Files = files
	for _, f := range files {
		if f.Role != RoleImageArchive {
			continue
		}
		images, err := ReadArchiveImages(filepath.Join(dir, filepath.FromSlash(f.Path)))
		if err != nil {
			return nil, fmt.Errorf("image archive %s: %w", f.Path, err)
		}
		for _, im := range images {
			im.Archive = f.Path
			m.Spec.ArchiveImages = append(m.Spec.ArchiveImages, im)
		}
	}
	sort.Slice(m.Spec.ArchiveImages, func(i, j int) bool {
		a, b := m.Spec.ArchiveImages[i], m.Spec.ArchiveImages[j]
		if a.Archive != b.Archive {
			return a.Archive < b.Archive
		}
		return a.Ref < b.Ref
	})
	if v, err := readVersions(filepath.Join(dir, "bundle-versions.txt")); err != nil {
		return nil, err
	} else if len(v) > 0 {
		m.Spec.Versions = v
	}
	m.Spec.Models = append([]Model(nil), opts.Models...)
	sort.Slice(m.Spec.Models, func(i, j int) bool { return m.Spec.Models[i].ID < m.Spec.Models[j].ID })

	m.Metadata.ID = opts.ID
	if m.Metadata.ID == "" {
		b, err := json.Marshal(m.Spec)
		if err != nil {
			return nil, err
		}
		m.Metadata.ID = snap.Metadata.ID + "-" + imagesnapshot.Checksum(b)[:12]
	}
	if err := Validate(m); err != nil {
		return nil, err
	}
	return m, nil
}

// walk lists and checksums every regular file under dir, except the bundle manifest
// and its checksum file. A symbolic link is refused: a bundle must carry its content.
func walk(dir string) ([]File, error) {
	var files []File
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return fmt.Errorf("%s is a symbolic link: a bundle must contain the file itself", rel)
		}
		if !d.Type().IsRegular() {
			return fmt.Errorf("%s is not a regular file", rel)
		}
		if rel == ManifestFile || rel == ChecksumFile {
			return nil
		}
		sum, size, err := fileSHA256(p)
		if err != nil {
			return err
		}
		role, name := Classify(rel)
		files = append(files, File{Path: rel, Role: role, Name: name, Size: size, SHA256: sum})
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	return files, nil
}

var chartFile = regexp.MustCompile(`^(.+?)-v?\d[\w.+-]*\.tgz$`)

// Classify gives the role of a bundle file and the artifact it belongs to, from its
// place in the layout airgap_install.sh writes.
func Classify(rel string) (role, name string) {
	parts := strings.Split(rel, "/")
	base := parts[len(parts)-1]
	switch {
	case len(parts) == 2 && parts[0] == "binaries":
		if strings.HasSuffix(base, ".version") {
			return RoleMetadata, strings.TrimSuffix(base, ".version")
		}
		return RoleBinary, base
	case len(parts) == 2 && parts[0] == "charts":
		if strings.HasSuffix(base, ".version") {
			return RoleMetadata, strings.TrimSuffix(base, ".version")
		}
		if m := chartFile.FindStringSubmatch(base); m != nil {
			return RoleChart, m[1]
		}
		return RoleChart, strings.TrimSuffix(base, ".tgz")
	case len(parts) == 2 && parts[0] == "manifests":
		return RoleManifest, strings.TrimSuffix(strings.TrimSuffix(base, path.Ext(base)), ".yaml")
	case len(parts) == 2 && parts[0] == "images" && strings.HasSuffix(base, "-images.tar"):
		return RoleImageArchive, strings.TrimSuffix(base, "-images.tar")
	case len(parts) == 2 && parts[0] == "images" && strings.HasSuffix(base, "-images.list"):
		return RoleImageList, strings.TrimSuffix(base, "-images.list")
	case len(parts) >= 3 && parts[0] == "packages":
		return RolePackage, parts[1] // packages/nvidia-closure/...
	case len(parts) == 2 && parts[0] == "packages":
		if strings.HasSuffix(base, ".manifest") || strings.HasSuffix(base, ".filename") {
			return RoleMetadata, strings.TrimSuffix(strings.TrimSuffix(base, ".manifest"), ".filename")
		}
		if i := strings.IndexAny(base, "-_"); i > 0 {
			return RolePackage, strings.ToLower(base[:i]) // pyyaml-6.0.2-...whl
		}
		return RolePackage, base
	case len(parts) == 1:
		return RoleMetadata, base
	}
	return RoleOther, rel
}

func fileSHA256(p string) (string, int64, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// readVersions parses bundle-versions.txt (key=value lines); a missing file is no versions.
func readVersions(p string) (map[string]string, error) {
	f, err := os.Open(p)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok {
			out[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	return out, sc.Err()
}

// ReadArchiveImages lists the images in an image archive with their manifest digests.
// It reads the OCI index (index.json) that `k0s airgap bundle-artifacts` and
// `ctr images export` write. An archive with only a Docker manifest.json names its
// images without a manifest digest; those are returned with an empty Digest so that
// Verify reports them instead of trusting a tag.
func ReadArchiveImages(p string) ([]ArchiveImage, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var index, docker []byte
	tr := tar.NewReader(f)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("not a readable tar archive: %w", err)
		}
		switch strings.TrimPrefix(h.Name, "./") {
		case "index.json":
			if index, err = io.ReadAll(io.LimitReader(tr, 64<<20)); err != nil {
				return nil, err
			}
		case "manifest.json":
			if docker, err = io.ReadAll(io.LimitReader(tr, 64<<20)); err != nil {
				return nil, err
			}
		}
	}
	if index != nil {
		var idx struct {
			Manifests []struct {
				Digest      string            `json:"digest"`
				Annotations map[string]string `json:"annotations"`
			} `json:"manifests"`
		}
		if err := json.Unmarshal(index, &idx); err != nil {
			return nil, fmt.Errorf("index.json: %w", err)
		}
		var out []ArchiveImage
		for _, d := range idx.Manifests {
			ref := d.Annotations["io.containerd.image.name"]
			if ref == "" {
				ref = d.Annotations["org.opencontainers.image.ref.name"]
			}
			if ref == "" {
				continue // an unnamed manifest is not an image anything refers to
			}
			out = append(out, ArchiveImage{Ref: ref, Digest: d.Digest})
		}
		return out, nil
	}
	if docker != nil {
		var entries []struct {
			RepoTags []string `json:"RepoTags"`
		}
		if err := json.Unmarshal(docker, &entries); err != nil {
			return nil, fmt.Errorf("manifest.json: %w", err)
		}
		var out []ArchiveImage
		for _, e := range entries {
			for _, t := range e.RepoTags {
				out = append(out, ArchiveImage{Ref: t})
			}
		}
		return out, nil
	}
	return nil, errors.New("no index.json or manifest.json: not an image archive")
}

// ReadModelConfig reads a model artifact configuration (the artifact-configs list of
// tools/artifacts_download_upload_scripts/model_artifacts_configs_*.yaml).
func ReadModelConfig(p string) ([]Model, error) {
	var cfg struct {
		ArtifactConfigs []struct {
			ID  string `json:"artifact-id"`
			URL string `json:"hf-url"`
		} `json:"artifact-configs"`
	}
	if err := imagesnapshot.ReadFile(p, &cfg); err != nil {
		return nil, fmt.Errorf("model config %s: %w", p, err)
	}
	var out []Model
	seen := map[string]bool{}
	for _, a := range cfg.ArtifactConfigs {
		id, src := strings.TrimSpace(a.ID), strings.TrimSpace(a.URL)
		if id == "" || src == "" {
			return nil, fmt.Errorf("model config %s: every artifact needs an artifact-id and an hf-url", p)
		}
		if seen[id] {
			return nil, fmt.Errorf("model config %s: artifact %q is listed twice", p, id)
		}
		seen[id] = true
		out = append(out, Model{ID: id, Source: src})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("model config %s lists no artifacts", p)
	}
	return out, nil
}

// Marshal is the canonical encoding of a manifest: the same manifest is always the same bytes.
func Marshal(m *Manifest) ([]byte, error) {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

var (
	idPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	hexSHA256  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	digestForm = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
)

// Validate checks that a manifest is complete and self-consistent.
func Validate(m *Manifest) error {
	var problems []string
	bad := func(format string, a ...any) { problems = append(problems, fmt.Sprintf(format, a...)) }
	if m.SchemaVersion != SchemaVersion {
		bad("schema version %d is not %d", m.SchemaVersion, SchemaVersion)
	}
	if m.Kind != Kind {
		bad("kind %q is not %q", m.Kind, Kind)
	}
	if !idPattern.MatchString(m.Metadata.ID) {
		bad("bundle ID %q may contain only letters, digits, '.', '-' and '_'", m.Metadata.ID)
	}
	if m.Spec.Platform != Platform {
		bad("platform %q is not %s", m.Spec.Platform, Platform)
	}
	if m.Spec.Snapshot.ID == "" || !hexSHA256.MatchString(m.Spec.Snapshot.Checksum) || m.Spec.Snapshot.Mirror == "" {
		bad("the snapshot reference needs an ID, a sha256 checksum and a mirror")
	}
	if len(m.Spec.Files) == 0 {
		bad("the bundle lists no files")
	}
	seen := map[string]bool{}
	for _, f := range m.Spec.Files {
		clean := path.Clean(f.Path)
		if f.Path == "" || clean != f.Path || strings.HasPrefix(clean, "../") || clean == ".." || path.IsAbs(clean) {
			bad("file path %q is not a clean path inside the bundle", f.Path)
		}
		if seen[f.Path] {
			bad("file %s is listed twice", f.Path)
		}
		seen[f.Path] = true
		if !hexSHA256.MatchString(f.SHA256) || f.Size < 0 {
			bad("file %s needs a sha256 and a size", f.Path)
		}
	}
	for _, im := range m.Spec.ArchiveImages {
		if !seen[im.Archive] {
			bad("archive image %s is in %s, which the bundle does not list", im.Ref, im.Archive)
		}
		if im.Digest != "" && !digestForm.MatchString(im.Digest) {
			bad("archive image %s has a malformed digest", im.Ref)
		}
	}
	for _, md := range m.Spec.Models {
		if md.ID == "" || md.Source == "" || (md.SHA256 != "" && !hexSHA256.MatchString(md.SHA256)) {
			bad("model %q needs an ID and a source, and a well-formed sha256 if one is given", md.ID)
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("invalid bundle manifest: %s", strings.Join(problems, "; "))
	}
	return nil
}

// Write stores a manifest and its checksum file at the top of the bundle directory,
// each written to a temporary file and renamed into place. An existing manifest is
// never replaced by a different one; writing the same manifest again is a no-op.
func Write(dir string, m *Manifest) (checksum string, err error) {
	if err := Validate(m); err != nil {
		return "", err
	}
	b, err := Marshal(m)
	if err != nil {
		return "", err
	}
	if err := imagesnapshot.CheckNoCredentials(b); err != nil {
		return "", err
	}
	sum := imagesnapshot.Checksum(b)
	final := filepath.Join(dir, ManifestFile)
	if existing, err := os.ReadFile(final); err == nil {
		if bytes.Equal(existing, b) {
			return sum, writeAtomic(filepath.Join(dir, ChecksumFile), []byte(sum+"  "+ManifestFile+"\n"))
		}
		return "", fmt.Errorf("%s already describes a different bundle: a bundle manifest is never rewritten", final)
	}
	if err := writeAtomic(final, b); err != nil {
		return "", err
	}
	return sum, writeAtomic(filepath.Join(dir, ChecksumFile), []byte(sum+"  "+ManifestFile+"\n"))
}

func writeAtomic(p string, b []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(p), "."+filepath.Base(p)+".tmp-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // a no-op once renamed
	if _, err := tmp.Write(b); err != nil {
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
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), p)
}

// Read loads the manifest of the bundle in dir. The checksum file is required and must
// match, unknown fields are rejected, and the manifest is validated.
func Read(dir string) (*Manifest, string, error) {
	b, err := os.ReadFile(filepath.Join(dir, ManifestFile))
	if err != nil {
		return nil, "", fmt.Errorf("bundle manifest: %w", err)
	}
	want, err := os.ReadFile(filepath.Join(dir, ChecksumFile))
	if err != nil {
		return nil, "", fmt.Errorf("bundle manifest checksum file: %w", err)
	}
	sum := imagesnapshot.Checksum(b)
	if fields := strings.Fields(string(want)); len(fields) == 0 || fields[0] != sum {
		return nil, "", fmt.Errorf("%s does not match its checksum file: the manifest was altered or truncated", ManifestFile)
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var m Manifest
	if err := dec.Decode(&m); err != nil {
		return nil, "", fmt.Errorf("bundle manifest: %w", err)
	}
	if err := Validate(&m); err != nil {
		return nil, "", err
	}
	return &m, sum, nil
}
