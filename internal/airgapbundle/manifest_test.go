package airgapbundle

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/go-containerregistry/pkg/v1/empty"
	"github.com/google/go-containerregistry/pkg/v1/layout"
	"github.com/google/go-containerregistry/pkg/v1/random"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBuild_RecordsEveryFileWithItsRoleSizeAndChecksum(t *testing.T) {
	f := newFixture(t)
	m := f.build()

	byPath := map[string]File{}
	for _, file := range m.Spec.Files {
		byPath[file.Path] = file
	}
	for path, want := range map[string][2]string{
		"binaries/k0s":                                     {RoleBinary, "k0s"},
		"binaries/k0s.version":                             {RoleMetadata, "k0s"},
		"binaries/yq":                                      {RoleBinary, "yq"},
		"images/k0s-images.tar":                            {RoleImageArchive, "k0s"},
		"images/addon-images.list":                         {RoleImageList, "addon"},
		"manifests/nvidia-device-plugin.yml":               {RoleManifest, "nvidia-device-plugin"},
		"manifests/cert-manager.yaml":                      {RoleManifest, "cert-manager"},
		"charts/kube-prometheus-stack-65.1.0.tgz":          {RoleChart, "kube-prometheus-stack"},
		"charts/kuberay-operator-1.2.2.tgz":                {RoleChart, "kuberay-operator"},
		"charts/kube-prometheus-stack.version":             {RoleMetadata, "kube-prometheus-stack"},
		"packages/nvidia-closure/nvidia-driver-550.rpm":    {RolePackage, "nvidia-closure"},
		"packages/nvidia-closure.manifest":                 {RoleMetadata, "nvidia-closure"},
		"packages/pyyaml-6.0.2-cp311-manylinux_x86_64.whl": {RolePackage, "pyyaml"},
		"bundle-versions.txt":                              {RoleMetadata, "bundle-versions.txt"},
		"checksums.sha256":                                 {RoleMetadata, "checksums.sha256"},
	} {
		got, ok := byPath[path]
		require.True(t, ok, "missing %s", path)
		assert.Equal(t, want[0], got.Role, path)
		assert.Equal(t, want[1], got.Name, path)
		info, err := os.Stat(filepath.Join(f.dir, path))
		require.NoError(t, err)
		assert.Equal(t, info.Size(), got.Size, path)
		sum, _, err := fileSHA256(filepath.Join(f.dir, path))
		require.NoError(t, err)
		assert.Equal(t, sum, got.SHA256, path)
	}
	assert.NotContains(t, byPath, ManifestFile, "the manifest does not list itself")

	assert.Len(t, m.Spec.ArchiveImages, len(k0sImages)+len(addonImages))
	for _, im := range m.Spec.ArchiveImages {
		assert.Equal(t, digestOf("archive:"+im.Ref), im.Digest, im.Ref)
	}
	assert.Equal(t, "v1.36.1+k0s.0", m.Spec.Versions["k0s_version"])
	assert.Equal(t, []string{"all-minilm-l6-v2", "cross-encoder"}, []string{m.Spec.Models[0].ID, m.Spec.Models[1].ID})
	assert.Equal(t, "snap-1", m.Spec.Snapshot.ID)
	assert.Equal(t, testMirror, m.Spec.Snapshot.Mirror)
	assert.Regexp(t, `^snap-1-[0-9a-f]{12}$`, m.Metadata.ID)
}

func TestBuild_IsDeterministic(t *testing.T) {
	f := newFixture(t)
	a, err := Build(f.dir, BuildOptions{SnapshotPath: f.snapshot, Models: f.models})
	require.NoError(t, err)
	b, err := Build(f.dir, BuildOptions{SnapshotPath: f.snapshot, Models: []Model{f.models[1], f.models[0]}})
	require.NoError(t, err)
	ab, _ := Marshal(a)
	bb, _ := Marshal(b)
	assert.Equal(t, string(ab), string(bb), "same bundle, same bytes, whatever the model order")
}

func TestBuild_Refusals(t *testing.T) {
	f := newFixture(t)
	_, err := Build(f.dir, BuildOptions{})
	assert.ErrorContains(t, err, "an image snapshot is required")

	require.NoError(t, os.Symlink(filepath.Join(f.dir, "binaries/k0s"), filepath.Join(f.dir, "binaries/k0s-link")))
	_, err = Build(f.dir, BuildOptions{SnapshotPath: f.snapshot})
	assert.ErrorContains(t, err, "symbolic link")
	require.NoError(t, os.Remove(filepath.Join(f.dir, "binaries/k0s-link")))

	write(t, filepath.Join(f.dir, "images/broken-images.tar"), "not a tar")
	_, err = Build(f.dir, BuildOptions{SnapshotPath: f.snapshot})
	assert.ErrorContains(t, err, "images/broken-images.tar")

	_, err = Build(t.TempDir(), BuildOptions{SnapshotPath: f.snapshot})
	assert.ErrorContains(t, err, "holds no bundle files")
}

func TestWrite_IsWriteOnceAndReadRequiresTheChecksum(t *testing.T) {
	f := newFixture(t)
	m := f.build()

	again := *m
	_, err := Write(f.dir, &again)
	assert.NoError(t, err, "writing the same manifest again is a no-op")

	other := *m
	other.Metadata.ID = "other-bundle"
	_, err = Write(f.dir, &other)
	assert.ErrorContains(t, err, "never rewritten")

	got, _, err := Read(f.dir)
	require.NoError(t, err)
	assert.Equal(t, m.Metadata.ID, got.Metadata.ID)

	// The checksum file is required, and must match.
	sumFile := filepath.Join(f.dir, ChecksumFile)
	saved, _ := os.ReadFile(sumFile)
	require.NoError(t, os.Remove(sumFile))
	_, _, err = Read(f.dir)
	assert.ErrorContains(t, err, "checksum file")
	require.NoError(t, os.WriteFile(sumFile, saved, 0o644))

	body, _ := os.ReadFile(filepath.Join(f.dir, ManifestFile))
	require.NoError(t, os.WriteFile(filepath.Join(f.dir, ManifestFile), []byte(strings.Replace(string(body), `"size": 9`, `"size": 10`, 1)), 0o644))
	_, _, err = Read(f.dir)
	assert.ErrorContains(t, err, "does not match its checksum file")
}

func TestRead_RejectsUnknownFieldsAndInvalidContent(t *testing.T) {
	f := newFixture(t)
	m := f.build()
	rewrite := func(body string) {
		require.NoError(t, os.WriteFile(filepath.Join(f.dir, ManifestFile), []byte(body), 0o644))
		require.NoError(t, os.WriteFile(filepath.Join(f.dir, ChecksumFile), []byte(checksumOf(body)+"  "+ManifestFile+"\n"), 0o644))
	}
	b, _ := Marshal(m)
	rewrite(strings.Replace(string(b), `"schemaVersion": 1`, `"schemaVersion": 1, "extra": true`, 1))
	_, _, err := Read(f.dir)
	assert.Error(t, err, "an unknown field is rejected")

	rewrite(strings.Replace(string(b), `"path": "binaries/k0s"`, `"path": "../outside"`, 1))
	_, _, err = Read(f.dir)
	assert.ErrorContains(t, err, "not a clean path inside the bundle")

	rewrite(strings.Replace(string(b), `"platform": "linux/amd64"`, `"platform": "linux/arm64"`, 1))
	_, _, err = Read(f.dir)
	assert.ErrorContains(t, err, "platform")
}

func checksumOf(s string) string {
	d := digestOf(s)
	return strings.TrimPrefix(d, "sha256:")
}

// A real OCI image layout, as containerd and go-containerregistry write it, packed
// into a tar: every image is found with its manifest digest.
func TestReadArchiveImages_ReadsARealOCILayout(t *testing.T) {
	dir := t.TempDir()
	p, err := layout.Write(dir, empty.Index)
	require.NoError(t, err)
	want := map[string]string{}
	for _, ref := range []string{"docker.io/library/busybox:1.36", "quay.io/k0sproject/coredns:1.11.3"} {
		img, err := random.Image(128, 1)
		require.NoError(t, err)
		require.NoError(t, p.AppendImage(img, layout.WithAnnotations(map[string]string{"io.containerd.image.name": ref})))
		d, _ := img.Digest()
		want[ref] = d.String()
	}
	// An index entry without a name is not an image anything refers to.
	unnamed, _ := random.Image(64, 1)
	require.NoError(t, p.AppendImage(unnamed))

	entries := map[string][]byte{}
	require.NoError(t, filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(dir, path)
		b, err := os.ReadFile(path)
		entries[filepath.ToSlash(rel)] = b
		return err
	}))
	archive := filepath.Join(t.TempDir(), "x-images.tar")
	writeTar(t, archive, entries)

	images, err := ReadArchiveImages(archive)
	require.NoError(t, err)
	got := map[string]string{}
	for _, im := range images {
		got[im.Ref] = im.Digest
	}
	assert.Equal(t, want, got)
}

func TestReadArchiveImages_ADockerArchiveHasNoDigestAndGarbageIsRefused(t *testing.T) {
	p := filepath.Join(t.TempDir(), "d-images.tar")
	writeTar(t, p, map[string][]byte{"manifest.json": []byte(`[{"Config":"c.json","RepoTags":["docker.io/library/nginx:1.27"],"Layers":[]}]`)})
	images, err := ReadArchiveImages(p)
	require.NoError(t, err)
	assert.Equal(t, []ArchiveImage{{Ref: "docker.io/library/nginx:1.27"}}, images, "named, but without a digest")

	empty := filepath.Join(t.TempDir(), "e-images.tar")
	writeTar(t, empty, map[string][]byte{"README": []byte("x")})
	_, err = ReadArchiveImages(empty)
	assert.ErrorContains(t, err, "not an image archive")
}

func TestReadModelConfig_ReadsTheRepositoryConfigurations(t *testing.T) {
	for _, name := range []string{"model_artifacts_configs_quantized.yaml", "model_artifacts_configs_unquantized.yaml"} {
		models, err := ReadModelConfig(filepath.Join("../../tools/artifacts_download_upload_scripts", name))
		require.NoError(t, err, name)
		assert.NotEmpty(t, models, name)
		for _, m := range models {
			assert.NotEmpty(t, m.ID, name)
			assert.True(t, strings.HasPrefix(m.Source, "https://huggingface.co/"), "%s: %s", name, m.Source)
		}
	}
	dup := filepath.Join(t.TempDir(), "dup.yaml")
	write(t, dup, "artifact-configs:\n  - artifact-id: a\n    hf-url: u\n  - artifact-id: a\n    hf-url: v\n")
	_, err := ReadModelConfig(dup)
	assert.ErrorContains(t, err, "listed twice")
	none := filepath.Join(t.TempDir(), "none.yaml")
	write(t, none, "artifact-configs: []\n")
	_, err = ReadModelConfig(none)
	assert.ErrorContains(t, err, "lists no artifacts")
}

func TestClassify(t *testing.T) {
	for path, want := range map[string][2]string{
		"charts/metallb-0.14.8.tgz":                {RoleChart, "metallb"},
		"charts/opentelemetry-operator-0.70.0.tgz": {RoleChart, "opentelemetry-operator"},
		"charts/kube-prometheus-stack-v65.1.0.tgz": {RoleChart, "kube-prometheus-stack"},
		"packages/node-closure/kernel-modules.rpm": {RolePackage, "node-closure"},
		"airgap-env.sh":                            {RoleMetadata, "airgap-env.sh"},
		"images/k0s-images.partial.tar":            {RoleOther, "images/k0s-images.partial.tar"},
		"somewhere/deep/file":                      {RoleOther, "somewhere/deep/file"},
	} {
		role, name := Classify(path)
		assert.Equal(t, want, [2]string{role, name}, path)
	}
}
