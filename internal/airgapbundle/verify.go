package airgapbundle

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

// Finding codes. Each finding names the offending artifact, node or model.
const (
	FindingManifestInvalid    = "BUNDLE_MANIFEST_INVALID"   // no readable, checksummed, valid bundle manifest
	FindingFileMissing        = "BUNDLE_FILE_MISSING"       // a listed file is absent
	FindingFileChanged        = "BUNDLE_FILE_CHANGED"       // a listed file has another size or checksum
	FindingFileUnlisted       = "BUNDLE_FILE_UNLISTED"      // the bundle holds a file its manifest does not list
	FindingArtifactMissing    = "REQUIRED_ARTIFACT_MISSING" // the profile needs a binary, chart, manifest, package or archive the bundle lacks
	FindingArchiveImage       = "ARCHIVE_IMAGE_MISSING"     // an image list names an image its archive does not hold
	FindingArchiveUnpinned    = "ARCHIVE_IMAGE_UNPINNED"    // an archive image has no manifest digest
	FindingSnapshotMismatch   = "SNAPSHOT_MISMATCH"         // the snapshot is not the one the bundle was made for
	FindingFactsMissing       = "HOST_FACTS_MISSING"        // the install preflight was given no host facts
	FindingArch               = "NODE_PLATFORM_MISMATCH"    // a node is not linux/amd64, or did not report its platform
	FindingGPUNodeMissing     = "GPU_NODE_MISSING"          // fullfeature, and no GPU node was reported
	FindingGPUDriver          = "GPU_DRIVER_MISSING"        // a GPU node has no NVIDIA driver loaded
	FindingGPURuntime         = "GPU_RUNTIME_MISSING"       // a GPU node has no NVIDIA container runtime
	FindingGPUCapacity        = "GPU_CAPACITY_INSUFFICIENT" // fewer schedulable GPUs than the profile needs
	FindingModelInventory     = "MODEL_INVENTORY_MISSING"   // fullfeature, and the bundle records no model artifacts
	FindingModelMissing       = "MODEL_ARTIFACT_MISSING"    // a required model artifact is not staged
	FindingModelMismatch      = "MODEL_ARTIFACT_MISMATCH"   // a staged model artifact has another source or checksum
	ScopeBundle               = "bundle"                    // verify the bundle alone, as on the staging host
	ScopeInstall              = "install"                   // verify everything an install needs
	defaultGPUsForFullfeature = 1
)

// Finding is one problem the preflight found.
type Finding = imagesnapshot.Finding

// VerifyOptions are the inputs of the preflight besides the bundle directory.
type VerifyOptions struct {
	// Scope is ScopeBundle or ScopeInstall (the default).
	Scope string
	// Profile is cpuOnly or fullfeature (required).
	Profile string
	// Input decides which components the profile installs, and, for the install scope,
	// the image inventory the snapshot is checked against.
	Input imagesnapshot.InventoryInput
	// MetalLB reports the installer's metallb.install setting (MetalLB is installed only
	// when it is set and the metallb component is on).
	MetalLB bool
	// SnapshotPath is the snapshot manifest.json (required for the install scope).
	SnapshotPath string
	// Registry reads the private mirror (required for the install scope).
	Registry imagesnapshot.Registry
	// Facts are the target's host facts (required for the install scope).
	Facts *HostFacts
	// GPUs is the number of schedulable GPUs fullfeature needs; 0 means 1.
	GPUs int
}

// requirement is an artifact a profile needs, and the component that brings it.
type requirement struct {
	role, name string
	gate       string // component switch, "" = always
}

// requirements are the bundle artifacts an install uses, with the installer's gates:
// the cluster binaries, storage and image archives always, and each add-on only when
// its component is installed.
var requirements = []requirement{
	{RoleBinary, "k0s", ""},
	{RoleBinary, "yq", ""},
	{RoleImageArchive, "k0s", ""},
	{RoleImageList, "k0s", ""},
	{RoleImageArchive, "addon", ""},
	{RoleImageList, "addon", ""},
	{RoleManifest, "local-path-storage", ""},
	{RolePackage, "pyyaml", ""},
	{RoleManifest, "cert-manager", "certManager"},
	{RoleChart, "kube-prometheus-stack", "monitoring"},
	{RoleChart, "opentelemetry-operator", "otel"},
	{RoleChart, "kuberay-operator", "kuberay"},
	{RoleChart, "metallb", "metallb"},
	{RoleManifest, "nvidia-device-plugin", "nvidia"},
	{RolePackage, "nvidia-closure", "nvidia"},
}

// Verify checks the bundle in dir for an install of opts.Profile and reports every
// problem it finds. It changes nothing. An empty result means the install may start.
func Verify(ctx context.Context, dir string, opts VerifyOptions) []Finding {
	if opts.Scope == "" {
		opts.Scope = ScopeInstall
	}
	m, _, err := Read(dir)
	if err != nil {
		return []Finding{{Component: ManifestFile, Code: FindingManifestInvalid, Message: imagesnapshot.Sanitize(err.Error())}}
	}
	var out []Finding
	out = append(out, checkFiles(dir, m)...)
	out = append(out, checkRequirements(m, opts)...)
	out = append(out, checkArchives(dir, m)...)
	if opts.Profile == imagesnapshot.ProfileFullFeature && len(m.Spec.Models) == 0 {
		out = append(out, Finding{Component: "models", Code: FindingModelInventory,
			Message: "fullfeature loads model artifacts, and the bundle manifest records none: build it with the model configuration"})
	}
	if opts.Scope == ScopeInstall {
		out = append(out, checkSnapshot(ctx, m, opts)...)
		out = append(out, checkHost(m, opts)...)
	}
	sortFindings(out)
	return out
}

// checkFiles compares the bundle directory with its manifest: every listed file must be
// present with its size and checksum, and no other file may be there.
func checkFiles(dir string, m *Manifest) []Finding {
	var out []Finding
	listed := map[string]bool{}
	for _, f := range m.Spec.Files {
		listed[f.Path] = true
		p := filepath.Join(dir, filepath.FromSlash(f.Path))
		info, err := os.Lstat(p)
		if errors.Is(err, fs.ErrNotExist) {
			out = append(out, Finding{Component: f.Path, Code: FindingFileMissing, Message: fmt.Sprintf("the %s %s is listed but absent", f.Role, f.Name)})
			continue
		}
		if err != nil || !info.Mode().IsRegular() {
			out = append(out, Finding{Component: f.Path, Code: FindingFileChanged, Message: "is not a readable regular file"})
			continue
		}
		if info.Size() != f.Size {
			out = append(out, Finding{Component: f.Path, Code: FindingFileChanged,
				Message: fmt.Sprintf("is %d bytes, the manifest records %d (truncated or replaced)", info.Size(), f.Size)})
			continue
		}
		sum, _, err := fileSHA256(p)
		if err != nil {
			out = append(out, Finding{Component: f.Path, Code: FindingFileChanged, Message: imagesnapshot.Sanitize(err.Error())})
			continue
		}
		if sum != f.SHA256 {
			out = append(out, Finding{Component: f.Path, Code: FindingFileChanged,
				Message: fmt.Sprintf("checksum %s does not match the manifest's %s", short(sum), short(f.SHA256))})
		}
	}
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		rel = filepath.ToSlash(rel)
		if rel == ManifestFile || rel == ChecksumFile || listed[rel] {
			return nil
		}
		out = append(out, Finding{Component: rel, Code: FindingFileUnlisted, Message: "is in the bundle but not in its manifest"})
		return nil
	})
	return out
}

func (o VerifyOptions) componentOn(gate string) bool {
	if gate == "" {
		return true
	}
	on := o.Input.ComponentOn(o.Profile, gate)
	if gate == "metallb" {
		return on && o.MetalLB
	}
	return on
}

// checkRequirements reports each artifact the profile installs that the bundle lacks.
func checkRequirements(m *Manifest, opts VerifyOptions) []Finding {
	have := map[string]bool{}
	for _, f := range m.Spec.Files {
		have[f.Role+"/"+f.Name] = true
	}
	var out []Finding
	for _, r := range requirements {
		if !opts.componentOn(r.gate) || have[r.role+"/"+r.name] {
			continue
		}
		why := "every install uses it"
		if r.gate != "" {
			why = "the " + r.gate + " component is installed for " + opts.Profile
		}
		out = append(out, Finding{Component: r.role + ":" + r.name, Code: FindingArtifactMissing,
			Message: fmt.Sprintf("the bundle has no %s %s, and %s; there is no download fallback in an air-gapped install", r.name, r.role, why)})
	}
	return out
}

// checkArchives checks that every image an image list names is in its archive with a
// manifest digest, so the node import can be checked by digest rather than by tag.
func checkArchives(dir string, m *Manifest) []Finding {
	inArchive := map[string]ArchiveImage{}
	for _, im := range m.Spec.ArchiveImages {
		inArchive[im.Archive+"\x00"+canonical(im.Ref)] = im
	}
	var out []Finding
	for _, im := range m.Spec.ArchiveImages {
		if im.Digest == "" {
			out = append(out, Finding{Component: im.Ref, Code: FindingArchiveUnpinned,
				Message: fmt.Sprintf("%s holds it without a manifest digest; rebuild the archive with an OCI index", im.Archive)})
		}
	}
	for _, f := range m.Spec.Files {
		if f.Role != RoleImageList {
			continue
		}
		archive := "images/" + f.Name + "-images.tar"
		b, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(f.Path)))
		if err != nil {
			continue // reported by checkFiles
		}
		for _, line := range strings.Split(string(b), "\n") {
			ref := strings.TrimSpace(line)
			if ref == "" || strings.HasPrefix(ref, "#") {
				continue
			}
			if _, ok := inArchive[archive+"\x00"+canonical(ref)]; !ok {
				out = append(out, Finding{Component: ref, Code: FindingArchiveImage,
					Message: fmt.Sprintf("%s names it, but %s does not hold it", f.Path, archive)})
			}
		}
	}
	return out
}

// canonical spells a reference the way the registry client does, so that
// "quay.io/x:1" in a list and "quay.io/x:1" in an archive compare equal, as do
// "busybox:1" and "docker.io/library/busybox:1".
func canonical(ref string) string {
	if p, err := imagesnapshot.ParseRef(ref); err == nil {
		return p.String()
	}
	return strings.TrimSpace(ref)
}

// checkSnapshot checks that the snapshot is the bundle's, then runs the image
// snapshot preflight against the private mirror: every image of the profile must be
// there, by digest, for linux/amd64.
func checkSnapshot(ctx context.Context, m *Manifest, opts VerifyOptions) []Finding {
	if opts.SnapshotPath == "" {
		return []Finding{{Component: "snapshot", Code: FindingSnapshotMismatch, Message: "no image snapshot was given: the install pulls every image from its mirror references"}}
	}
	raw, err := os.ReadFile(opts.SnapshotPath)
	if err != nil {
		return []Finding{{Component: "snapshot", Code: FindingSnapshotMismatch, Message: imagesnapshot.Sanitize(err.Error())}}
	}
	if sum := imagesnapshot.Checksum(raw); sum != m.Spec.Snapshot.Checksum {
		return []Finding{{Component: "snapshot", Code: FindingSnapshotMismatch,
			Message: fmt.Sprintf("checksum %s is not that of snapshot %s (%s) the bundle was made for", short(sum), m.Spec.Snapshot.ID, short(m.Spec.Snapshot.Checksum))}}
	}
	snap, err := imagesnapshot.ReadSnapshot(opts.SnapshotPath)
	if err != nil {
		return []Finding{{Component: "snapshot", Code: FindingSnapshotMismatch, Message: imagesnapshot.Sanitize(err.Error())}}
	}
	if opts.Input.Candidate == nil {
		return []Finding{{Component: "snapshot", Code: FindingSnapshotMismatch, Message: "no candidate manifest was given to derive the image inventory from"}}
	}
	inv, err := imagesnapshot.BuildInventory(opts.Input)
	if err != nil {
		return []Finding{{Component: "inventory", Code: FindingSnapshotMismatch, Message: imagesnapshot.Sanitize(err.Error())}}
	}
	reg := opts.Registry
	if reg == nil {
		reg = &imagesnapshot.Remote{}
	}
	return imagesnapshot.Preflight(ctx, reg, snap, inv, opts.Profile)
}

// checkHost checks the target's nodes, GPU capacity and staged model artifacts.
func checkHost(m *Manifest, opts VerifyOptions) []Finding {
	f := opts.Facts
	if f == nil || len(f.Nodes) == 0 {
		return []Finding{{Component: "host", Code: FindingFactsMissing,
			Message: "the install preflight needs the target's node facts (platform, and for fullfeature GPU driver, runtime and capacity)"}}
	}
	var out []Finding
	for _, n := range f.Nodes {
		if n.Platform != m.Spec.Platform {
			got := n.Platform
			if got == "" {
				got = "an unreported platform"
			}
			out = append(out, Finding{Component: "node:" + n.Name, Code: FindingArch,
				Message: fmt.Sprintf("is %s; the bundle's binaries, packages and images are for %s", got, m.Spec.Platform)})
		}
	}
	if opts.Profile != imagesnapshot.ProfileFullFeature {
		return out // cpuOnly has no GPU or model prerequisite
	}
	want := opts.GPUs
	if want <= 0 {
		want = defaultGPUsForFullfeature
	}
	total, gpuNodes := 0, 0
	for _, n := range f.Nodes {
		if n.GPU == nil {
			continue
		}
		gpuNodes++
		usable := true
		if strings.TrimSpace(n.GPU.Driver) == "" {
			out = append(out, Finding{Component: "node:" + n.Name, Code: FindingGPUDriver, Message: "has no NVIDIA driver loaded"})
			usable = false
		}
		if !n.GPU.Runtime {
			out = append(out, Finding{Component: "node:" + n.Name, Code: FindingGPURuntime, Message: "has no NVIDIA container runtime configured"})
			usable = false
		}
		if usable {
			total += n.GPU.Allocatable
		}
	}
	switch {
	case gpuNodes == 0:
		out = append(out, Finding{Component: "host", Code: FindingGPUNodeMissing, Message: "fullfeature runs its hosted models on GPU capacity, and no GPU node was reported"})
	case total < want:
		out = append(out, Finding{Component: "host", Code: FindingGPUCapacity,
			Message: fmt.Sprintf("%d schedulable nvidia.com/gpu on usable GPU nodes; fullfeature needs %d", total, want)})
	}
	staged := map[string]StagedModel{}
	for _, s := range f.StagedModels {
		staged[s.ID] = s
	}
	for _, md := range m.Spec.Models {
		s, ok := staged[md.ID]
		switch {
		case !ok:
			out = append(out, Finding{Component: "model:" + md.ID, Code: FindingModelMissing,
				Message: "is not staged in the object store; stage it from the offline artifacts (there is no download in an air-gapped install)"})
		case s.Source != md.Source:
			out = append(out, Finding{Component: "model:" + md.ID, Code: FindingModelMismatch,
				Message: fmt.Sprintf("the staged artifact came from %s, the bundle needs %s", s.Source, md.Source)})
		case md.SHA256 != "" && s.SHA256 != md.SHA256:
			out = append(out, Finding{Component: "model:" + md.ID, Code: FindingModelMismatch,
				Message: fmt.Sprintf("the staged artifact's checksum %s is not the bundle's %s", short(s.SHA256), short(md.SHA256))})
		}
	}
	return out
}

func sortFindings(f []Finding) {
	sort.SliceStable(f, func(i, j int) bool {
		if f[i].Code != f[j].Code {
			return f[i].Code < f[j].Code
		}
		return f[i].Component < f[j].Component
	})
}

func short(sum string) string {
	s := strings.TrimPrefix(sum, "sha256:")
	if len(s) > 12 {
		s = s[:12]
	}
	if s == "" {
		return "(none)"
	}
	return s
}
