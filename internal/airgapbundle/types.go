// Package airgapbundle describes, verifies and imports the offline bundle an
// air-gapped AI Tier install is made from.
//
// The bundle is the directory airgap_install.sh stages: binaries, Helm charts, static
// manifests, node packages and the k0s and add-on image archives. This package adds a
// machine-readable bundle manifest that records every file with its role, size and
// sha256, the digest of every image in the archives, the model artifacts the
// fullfeature profile needs, and the image snapshot (see internal/imagesnapshot) whose
// digest-pinned mirror references the install uses.
//
// Verify is the preflight: it changes nothing and reports every missing, altered or
// incompatible artifact and host prerequisite by name, so an install can stop before
// it changes cluster state. Import copies a verified bundle into place so that an
// interrupted transfer can be retried and a bundle already imported is left alone.
package airgapbundle

import "github.com/splunk/splunk-ai-operator/internal/imagesnapshot"

// Schema identity of a bundle manifest.
const (
	SchemaVersion = 1
	Kind          = "AirgapBundleManifest"
	// ManifestFile and ChecksumFile are written at the top of the bundle directory.
	ManifestFile = "bundle-manifest.json"
	ChecksumFile = ManifestFile + ".sha256"
	// Platform is the only platform the AI Tier supports.
	Platform = imagesnapshot.Platform
)

// Roles of bundle files. The role of a file follows from its place in the bundle
// layout that airgap_install.sh produces.
const (
	RoleBinary       = "binary"        // binaries/<name>
	RoleChart        = "chart"         // charts/<name>-<version>.tgz
	RoleManifest     = "manifest"      // manifests/<name>.yaml
	RoleImageArchive = "image-archive" // images/<name>-images.tar
	RoleImageList    = "image-list"    // images/<name>-images.list
	RolePackage      = "package"       // packages/<name>/... or packages/<name>-*
	RoleMetadata     = "metadata"      // top-level text files that describe the bundle
	RoleOther        = "other"         // anything else; recorded and checksummed like the rest
)

// Manifest is the bundle manifest.
type Manifest struct {
	SchemaVersion int      `json:"schemaVersion"`
	Kind          string   `json:"kind"`
	Metadata      Metadata `json:"metadata"`
	Spec          Spec     `json:"spec"`
}

// Metadata identifies a bundle.
type Metadata struct {
	// ID names the bundle and the directory it is imported into.
	ID string `json:"id"`
}

// Spec is the content of a bundle.
type Spec struct {
	// Platform is the platform every binary, package and image in the bundle is for.
	Platform string `json:"platform"`
	// Snapshot is the image snapshot the install pulls from the private mirror.
	Snapshot SnapshotRef `json:"snapshot"`
	// Versions are the component versions airgap_install.sh records in bundle-versions.txt.
	Versions map[string]string `json:"versions,omitempty"`
	// Files lists every file of the bundle except the manifest and its checksum file.
	Files []File `json:"files"`
	// ArchiveImages are the images inside the image archives, with their digests.
	ArchiveImages []ArchiveImage `json:"archiveImages,omitempty"`
	// Models are the model artifacts the fullfeature profile needs.
	Models []Model `json:"models,omitempty"`
}

// SnapshotRef links a bundle to the image snapshot it was made for.
type SnapshotRef struct {
	ID string `json:"id"`
	// Checksum is the sha256 of the snapshot's manifest.json.
	Checksum string `json:"checksum"`
	// Mirror is the private registry the snapshot's images are mirrored to.
	Mirror string `json:"mirror"`
}

// File is one file of the bundle.
type File struct {
	Path   string `json:"path"` // slash-separated, relative to the bundle directory
	Role   string `json:"role"`
	Name   string `json:"name"` // the artifact the file is part of: k0s, kuberay-operator, nvidia-closure, ...
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// ArchiveImage is an image inside an image archive.
type ArchiveImage struct {
	Ref     string `json:"ref"`
	Digest  string `json:"digest"`
	Archive string `json:"archive"` // the bundle path of the archive
}

// Model is a model artifact the fullfeature profile loads from the object store.
type Model struct {
	ID string `json:"id"`
	// Source is where the artifact was obtained, for example its Hugging Face URL. A
	// staged artifact is the same artifact only when its recorded source matches.
	Source string `json:"source"`
	// SHA256 is the checksum of the staged artifact, when the staging step records one.
	SHA256 string `json:"sha256,omitempty"`
}

// HostFacts are what the installer observes about the target before an install,
// read-only: the nodes, their GPUs and the model artifacts already staged. Verify
// compares them with what the profile needs; it never collects them itself.
type HostFacts struct {
	Nodes        []Node        `json:"nodes"`
	StagedModels []StagedModel `json:"stagedModels,omitempty"`
}

// Node is one cluster node.
type Node struct {
	Name string `json:"name"`
	// Platform is os/architecture as the node reports it, for example linux/amd64.
	Platform string `json:"platform"`
	// OS is the ID from the node's /etc/os-release (rhel, rocky, ubuntu, ...).
	OS string `json:"os,omitempty"`
	// Kernel is the node's running kernel (uname -r).
	Kernel string `json:"kernel,omitempty"`
	// GPU is set for a node that is meant to run GPU workloads.
	GPU *GPU `json:"gpu,omitempty"`
}

// GPU is what a GPU node offers, observed read-only before an install changes anything.
type GPU struct {
	// Devices is the number of NVIDIA GPUs the host has (from lspci, or nvidia-smi -L
	// when a driver is loaded).
	Devices int `json:"devices"`
	// Driver is the loaded NVIDIA driver version, empty when none is loaded.
	Driver string `json:"driver"`
	// Runtime reports whether the NVIDIA container toolkit is installed.
	Runtime bool `json:"runtime"`
	// Allocatable is the node's schedulable nvidia.com/gpu count. It is known only when
	// the node is already part of a cluster (an install with cluster.useExisting).
	Allocatable *int `json:"allocatable,omitempty"`
}

// StagedModel is a model artifact the object store holds, with its staging marker.
type StagedModel struct {
	ID     string `json:"id"`
	Source string `json:"source"`
	SHA256 string `json:"sha256,omitempty"`
}
