// Package imagesnapshot builds the image inventory of an AI Tier install, resolves
// every image to an immutable digest, mirrors it to a private registry, and keeps a
// versioned, machine-readable snapshot of the result (MPR-187).
//
// It owns the source-to-mirror process only. Bundling and importing the images onto
// nodes, installing from them, and wiring the inputs into CI belong to other stories
// (MPR-193, MPR-183). Nothing here builds or modifies an image, and nothing written
// to disk carries a credential.
package imagesnapshot

// Profile names, as in the AIPlatform spec and the installer.
const (
	ProfileCPUOnly     = "cpuOnly"
	ProfileFullFeature = "fullfeature"
)

// Profiles lists the supported profiles in a fixed order.
var Profiles = []string{ProfileCPUOnly, ProfileFullFeature}

// Platform is the only platform a snapshot supports: the AI Tier runs on linux/amd64
// nodes. An image without it is incompatible.
const Platform = "linux/amd64"

// Categories group inventory entries.
const (
	CategoryOperator     = "operator"
	CategoryAgentRuntime = "agent-runtime"
	CategorySLIM         = "slim"
	CategoryModelServing = "model-serving"
	CategoryPlatform     = "platform-dependency"
	CategoryAddon        = "platform-addon"
	CategoryKubernetes   = "kubernetes"
)

// Image is one image the install needs, before resolution.
type Image struct {
	// Component is the stable name of what the image is for, for example
	// "agent-runtime-base" or "ray-head". One image reference may serve several
	// components; each gets its own entry.
	Component string `json:"component"`
	Role      string `json:"role"`
	Category  string `json:"category"`
	// Profiles lists the profiles that need this image.
	Profiles []string `json:"profiles"`
	// Source is the reference exactly as supplied: a tag or a digest reference.
	Source string `json:"source"`
	// Origin says where the reference came from, so a reviewer can find it:
	// "candidate-manifest:components.runtimeBase", "installer-config:images.ray.headImage",
	// "addon-list" or "k0s-list".
	Origin string `json:"origin"`
	// Owner is who produces the image. It comes from the candidate manifest's source
	// repository or an owners file, and is "unassigned" when neither names one.
	Owner string `json:"owner"`
}

// CandidateRef links an inventory or snapshot to the MPR-188 candidate record it
// was derived from.
type CandidateRef struct {
	Name     string `json:"name"`
	Revision int    `json:"revision"`
	// Checksum is the sha256 of the candidate manifest file, so a later edit of the
	// record cannot silently change what a snapshot claims to be derived from.
	Checksum string `json:"checksum"`
}

// Inventory is the complete, deterministic list of images for both profiles.
type Inventory struct {
	Candidate CandidateRef `json:"candidate"`
	Images    []Image      `json:"images"`
	// Checksum is the sha256 of the canonical JSON of Candidate and Images.
	Checksum string `json:"checksum"`
}

// Entry is one resolved (and, once mirrored, verified) image in a snapshot.
type Entry struct {
	Image
	// SourceDigest is the digest the source reference pointed at when resolved: the
	// image index for a multi-platform image, the manifest otherwise.
	SourceDigest string `json:"sourceDigest"`
	// Digest is the digest of the linux/amd64 manifest. It is what is mirrored and
	// what installs must use.
	Digest string `json:"digest"`
	// Platforms lists every os/arch the source offers.
	Platforms []string `json:"platforms"`
	// BuildID comes from the image's OCI labels (revision, then created), or is
	// empty when the image carries none.
	BuildID string `json:"buildId,omitempty"`
	// MirrorRef is the digest-pinned reference in the private mirror. Empty until
	// mirrored.
	MirrorRef string `json:"mirrorRef,omitempty"`
	// Status is one of the Status* values.
	Status string `json:"status"`
	// Blocker is a sanitized reason when Status is blocked: an external blocker, never
	// a reason to fall back to a public registry.
	Blocker string `json:"blocker,omitempty"`
	// PreviousDigest is set only by a refresh when the digest changed.
	PreviousDigest string `json:"previousDigest,omitempty"`
}

// Entry statuses.
const (
	StatusResolved = "resolved" // digest and platform known, not mirrored
	StatusVerified = "verified" // mirrored and the target digest re-checked
	StatusBlocked  = "blocked"  // could not be resolved or mirrored: an external blocker
)

// Snapshot is the versioned record of one source-to-mirror run for a candidate
// revision.
type Snapshot struct {
	RecordType    string `json:"recordType"`
	SchemaVersion int    `json:"schemaVersion"`
	Metadata      struct {
		ID string `json:"id"`
		// Predecessor is the ID of the snapshot this one refreshed, if any. Earlier
		// snapshots are never rewritten, so a moved tag cannot change old evidence.
		Predecessor string `json:"predecessor,omitempty"`
	} `json:"metadata"`
	Spec struct {
		Candidate CandidateRef `json:"candidate"`
		Platform  string       `json:"platform"`
		// Mirror is the private registry host (and optional path prefix) the images
		// were copied to. It never includes credentials.
		Mirror            string  `json:"mirror"`
		InventoryChecksum string  `json:"inventoryChecksum"`
		Entries           []Entry `json:"entries"`
	} `json:"spec"`
}

// RecordType and SchemaVersion identify the snapshot format.
const (
	RecordType    = "image-snapshot"
	SchemaVersion = 1
)
