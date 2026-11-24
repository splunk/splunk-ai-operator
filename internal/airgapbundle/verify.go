package airgapbundle

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/splunk/splunk-ai-operator/internal/imagesnapshot"
)

// Finding codes. Each finding names the offending artifact, node or model.
const (
	FindingManifestInvalid    = "BUNDLE_MANIFEST_INVALID"       // no readable, checksummed, valid bundle manifest
	FindingFileMissing        = "BUNDLE_FILE_MISSING"           // a listed file is absent
	FindingFileChanged        = "BUNDLE_FILE_CHANGED"           // a listed file has another size or checksum
	FindingFileUnlisted       = "BUNDLE_FILE_UNLISTED"          // the bundle holds a file its manifest does not list
	FindingArtifactMissing    = "REQUIRED_ARTIFACT_MISSING"     // the profile needs a binary, chart, manifest, package or archive the bundle lacks
	FindingArchiveImage       = "ARCHIVE_IMAGE_MISSING"         // an image list names an image its archive does not hold
	FindingArchiveUnpinned    = "ARCHIVE_IMAGE_UNPINNED"        // an archive image has no manifest digest
	FindingArchiveDigest      = "ARCHIVE_IMAGE_DIGEST_MISMATCH" // an archive image is not the snapshot's image (another digest or architecture)
	FindingArchiveUnmapped    = "ARCHIVE_IMAGE_UNMAPPED"        // an archive image the snapshot has no entry for
	FindingSnapshotMismatch   = "SNAPSHOT_MISMATCH"             // the snapshot is not the one the bundle was made for
	FindingInstallConfig      = "INSTALL_CONFIG_MISSING"        // the install preflight has no install references to compare with the snapshot
	FindingInstallRegistry    = "INSTALL_REGISTRY_MISMATCH"     // images.registry is not the mirror host, so the nodes are not configured for the mirror
	FindingFactsMissing       = "HOST_FACTS_MISSING"            // the install preflight was given no host facts
	FindingArch               = "NODE_PLATFORM_MISMATCH"        // a node is not linux/amd64, or did not report its platform
	FindingGPUDevices         = "GPU_DEVICES_MISSING"           // a GPU node reports no NVIDIA GPU
	FindingGPUNodeMissing     = "GPU_NODE_MISSING"              // fullfeature, and no GPU node was reported
	FindingGPUDriver          = "GPU_DRIVER_MISSING"            // a GPU node has no NVIDIA driver loaded
	FindingGPURuntime         = "GPU_RUNTIME_MISSING"           // a GPU node has no NVIDIA container runtime
	FindingGPUCapacity        = "GPU_CAPACITY_INSUFFICIENT"     // fewer schedulable GPUs than the profile needs
	FindingModelInventory     = "MODEL_INVENTORY_MISSING"       // fullfeature, and the bundle records no model artifacts
	FindingModelMissing       = "MODEL_ARTIFACT_MISSING"        // a required model artifact is not staged
	FindingModelMismatch      = "MODEL_ARTIFACT_MISMATCH"       // a staged model artifact has another source or checksum
	ScopeBundle               = "bundle"                        // verify the bundle alone, as on the staging host
	ScopeInstall              = "install"                       // verify everything an install needs
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
	{RoleSnapshot, "snapshot", ""},
	{RoleBinary, "airgap-bundle", ""},
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
	// The NVIDIA closure is not required as such: a GPU node with its driver and toolkit
	// already installed needs nothing from it (airgap_install.sh --skip-nvidia-closure).
	// checkHost requires it exactly for the nodes that need a driver or toolkit installed.
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
		out = append(out, checkHost(dir, m, opts)...)
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
	out := checkArchivesAgainstSnapshot(m, snap)
	// The candidate record at install time must be the one the snapshot was made from.
	if opts.Input.Candidate != nil && opts.Input.CandidateChecksum != snap.Spec.Candidate.Checksum {
		out = append(out, Finding{Component: "candidate-manifest", Code: imagesnapshot.FindingCandidate,
			Message: fmt.Sprintf("the candidate manifest is not the record snapshot %s was made from (revision %d)", snap.Metadata.ID, snap.Spec.Candidate.Revision)})
	}
	// Every entry the profile needs is in the mirror, by digest, for linux/amd64. The
	// install's own configuration names the mirror, so the snapshot is the inventory.
	reg := opts.Registry
	if reg == nil {
		reg = &imagesnapshot.Remote{}
	}
	out = append(out, imagesnapshot.Preflight(ctx, reg, snap, imagesnapshot.SnapshotInventory(snap), opts.Profile)...)
	// The installer configures the nodes' access to a registry (plain HTTP when
	// images.registryInsecure is true) only for images.registry, so it must name the mirror.
	got := strings.TrimSuffix(strings.TrimSpace(opts.Input.Installer.Images.Registry), "/")
	if want := imagesnapshot.MirrorHost(snap.Spec.Mirror); got != want {
		if got == "" {
			got = "unset"
		}
		out = append(out, Finding{Component: "images.registry", Code: FindingInstallRegistry,
			Message: fmt.Sprintf("is %s, not the mirror host %s: the installer configures the nodes for images.registry only, so they could not pull from the mirror (image-snapshot install-config sets it)", got, want)})
	}
	// Every image the install configures is its component's mirror reference, pinned to
	// the snapshot's digest. Images delivered in the bundle's archives are checked
	// against the archives instead (checkArchivesAgainstSnapshot).
	refs := installRefs(opts)
	if len(refs) == 0 {
		return append(out, Finding{Component: "install-config", Code: FindingInstallConfig,
			Message: "no install references to check: give the installer configuration the install uses (its images: settings, from image-snapshot install-config)"})
	}
	return append(out, imagesnapshot.Compare(snap, opts.Profile, refs)...)
}

// installRefs are the references the install configures for the profile, without the
// images that reach the nodes in the bundle's image archives.
func installRefs(opts VerifyOptions) []imagesnapshot.InstallRef {
	archived := map[string]bool{}
	for _, list := range [][]string{opts.Input.AddonRefs, opts.Input.K0sRefs} {
		for _, r := range list {
			if r = strings.TrimSpace(r); r != "" && !strings.HasPrefix(r, "#") {
				archived[canonical(r)] = true
			}
		}
	}
	var out []imagesnapshot.InstallRef
	for _, r := range imagesnapshot.InstallRefs(opts.Profile, opts.Input) {
		if !archived[canonical(r.Ref)] {
			out = append(out, r)
		}
	}
	return out
}

// checkArchivesAgainstSnapshot checks that every image in the bundle's archives is the
// image the snapshot resolved for that reference: its linux/amd64 manifest, or the index
// that holds it. The snapshot proved that digest is linux/amd64, so a match settles both
// the digest and the architecture (ERD §14.4.4). An image without a digest is reported
// by checkArchives.
func checkArchivesAgainstSnapshot(m *Manifest, snap *imagesnapshot.Snapshot) []Finding {
	bySource := map[string]imagesnapshot.Entry{}
	byRepo := map[string][]imagesnapshot.Entry{}
	for _, e := range snap.Spec.Entries {
		bySource[canonical(e.Source)] = e
		byRepo[repository(e.Source)] = append(byRepo[repository(e.Source)], e)
	}
	var out []Finding
	for _, im := range m.Spec.ArchiveImages {
		if im.Digest == "" {
			continue
		}
		e, ok := bySource[canonical(im.Ref)]
		if !ok {
			// k0s records a name:tag@digest reference under every spelling (as given,
			// name:tag and name@digest). An alias is the snapshot's image when it is in
			// the same repository with that image's digest.
			for _, cand := range byRepo[repository(im.Ref)] {
				if im.Digest == cand.Digest || im.Digest == cand.SourceDigest {
					e, ok = cand, true
					break
				}
			}
			if !ok && len(byRepo[repository(im.Ref)]) > 0 {
				e, ok = byRepo[repository(im.Ref)][0], true // same repository, other build: a mismatch below
			}
		}
		switch {
		case !ok:
			out = append(out, Finding{Component: im.Ref, Code: FindingArchiveUnmapped,
				Message: fmt.Sprintf("%s holds it, but snapshot %s has no entry for it, so its digest and architecture are unverified", im.Archive, snap.Metadata.ID)})
		case im.Digest != e.Digest && im.Digest != e.SourceDigest:
			out = append(out, Finding{Component: im.Ref, Code: FindingArchiveDigest,
				Message: fmt.Sprintf("%s holds %s; snapshot %s resolved it to %s (linux/amd64)", im.Archive, short(im.Digest), snap.Metadata.ID, short(e.Digest)) +
					" — a different build or platform than the one mirrored and verified"})
		}
	}
	return out
}

// checkHost checks the target's nodes, GPU capacity and staged model artifacts.
func checkHost(dir string, m *Manifest, opts VerifyOptions) []Finding {
	f := opts.Facts
	if f == nil || len(f.Nodes) == 0 {
		return []Finding{{Component: "host", Code: FindingFactsMissing,
			Message: "the install preflight needs the target's node facts (platform, and for fullfeature the GPU devices, driver, runtime, OS and kernel)"}}
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
	closure := readNVIDIAClosure(dir, m)
	total, gpuNodes := 0, 0
	for _, n := range f.Nodes {
		if n.GPU == nil {
			continue
		}
		gpuNodes++
		g := n.GPU
		capacity := g.Devices
		if g.Allocatable != nil {
			capacity = *g.Allocatable // the node is in a cluster: what it can schedule
		}
		if g.Devices <= 0 && capacity <= 0 {
			out = append(out, Finding{Component: "node:" + n.Name, Code: FindingGPUDevices, Message: "reports no NVIDIA GPU"})
			continue
		}
		// The driver is loaded, or the bundle can install it offline for this exact kernel.
		driverOK := strings.TrimSpace(g.Driver) != ""
		if !driverOK {
			if why := closure.cannotInstallDriver(n); why != "" {
				out = append(out, Finding{Component: "node:" + n.Name, Code: FindingGPUDriver, Message: "has no NVIDIA driver loaded, and " + why})
			} else {
				driverOK = true
			}
		}
		// The container toolkit is installed, or the bundle's closure carries it. A node
		// whose driver cannot be provided is reported for the driver alone: the toolkit
		// is installed from the same closure, after it.
		runtimeOK := g.Runtime || (driverOK && closure.toolkit)
		if !runtimeOK && driverOK {
			out = append(out, Finding{Component: "node:" + n.Name, Code: FindingGPURuntime,
				Message: "has no NVIDIA container toolkit, and the bundle's nvidia-closure does not carry it"})
		}
		if driverOK && runtimeOK {
			total += capacity
		}
	}
	switch {
	case gpuNodes == 0:
		out = append(out, Finding{Component: "host", Code: FindingGPUNodeMissing, Message: "fullfeature runs its hosted models on GPU capacity, and no GPU node was reported"})
	case total < want:
		out = append(out, Finding{Component: "host", Code: FindingGPUCapacity,
			Message: fmt.Sprintf("%d NVIDIA GPU(s) on GPU nodes whose driver and runtime are present or installable; fullfeature needs %d", total, want)})
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

// nvidiaClosure is what the bundle's offline NVIDIA package closure can install.
type nvidiaClosure struct {
	present   bool
	kernels   map[string]bool // the kernels it carries headers for (.target-kernels)
	pkgFormat string          // rpm or deb (.pkg-format)
	toolkit   bool            // it carries the NVIDIA container toolkit
}

// readNVIDIAClosure reads the closure metadata airgap_install.sh writes. Only files the
// manifest lists are read; their integrity is checked by checkFiles.
func readNVIDIAClosure(dir string, m *Manifest) nvidiaClosure {
	c := nvidiaClosure{kernels: map[string]bool{}}
	for _, f := range m.Spec.Files {
		if f.Role != RolePackage || f.Name != "nvidia-closure" {
			continue
		}
		c.present = true
		base := path.Base(f.Path)
		switch {
		case base == ".target-kernels":
			if b, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(f.Path))); err == nil {
				for _, k := range strings.FieldsFunc(string(b), func(r rune) bool { return r == ',' || r == '\n' || r == ' ' || r == '\t' }) {
					c.kernels[k] = true
				}
			}
		case base == ".pkg-format":
			if b, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(f.Path))); err == nil {
				c.pkgFormat = strings.TrimSpace(string(b))
			}
		case strings.HasPrefix(base, "nvidia-container-toolkit"):
			c.toolkit = true
		}
	}
	if c.present && c.pkgFormat == "" {
		c.pkgFormat = "rpm" // airgap_install.sh's default, as the installer reads it
	}
	return c
}

// cannotInstallDriver says why the closure cannot install a driver on the node, or "".
func (c nvidiaClosure) cannotInstallDriver(n Node) string {
	switch {
	case !c.present:
		return "the bundle has no nvidia-closure to install one from"
	case n.Kernel == "":
		return "the node did not report its kernel, so the closure's coverage cannot be checked"
	case !c.kernels[n.Kernel]:
		var have []string
		for k := range c.kernels {
			have = append(have, k)
		}
		sort.Strings(have)
		return fmt.Sprintf("the bundle's nvidia-closure has no packages for its kernel %s (it covers %s); re-stage with --gpu-kernels %s",
			n.Kernel, strings.Join(have, ", "), n.Kernel)
	}
	if want := packageFormat(n.OS); want != "" && want != c.pkgFormat {
		return fmt.Sprintf("the bundle's nvidia-closure holds %s packages and the node runs %s (%s)", c.pkgFormat, n.OS, want)
	}
	return ""
}

// packageFormat is the package format of an os-release ID, "" when unknown.
func packageFormat(osID string) string {
	switch strings.ToLower(strings.TrimSpace(osID)) {
	case "rhel", "centos", "rocky", "almalinux", "ol", "fedora", "amzn":
		return "rpm"
	case "ubuntu", "debian":
		return "deb"
	}
	return ""
}

// repository is registry/repository of a reference, without its tag or digest.
func repository(ref string) string {
	p, err := imagesnapshot.ParseRef(ref)
	if err != nil {
		return strings.TrimSpace(ref)
	}
	return p.Registry + "/" + p.Repository
}
