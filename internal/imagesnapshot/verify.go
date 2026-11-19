package imagesnapshot

import (
	"context"
	"fmt"
	"sort"
	"strings"
)

// Finding codes. The preflight names the offending component with each one.
const (
	FindingInventoryChanged = "INVENTORY_CHANGED"         // the snapshot was made from a different inventory
	FindingOmitted          = "OMITTED_FROM_SNAPSHOT"     // an image the profile needs has no snapshot entry
	FindingBlocked          = "SNAPSHOT_ENTRY_BLOCKED"    // the snapshot records an unresolved or unmirrored image
	FindingNoMirror         = "MISSING_MIRROR_MAPPING"    // an entry has no mirror reference
	FindingMissingImage     = "MIRROR_MISSING_IMAGE"      // the mirror does not hold the image
	FindingDigest           = "DIGEST_MISMATCH"           // the digest differs from the snapshot's
	FindingArch             = "WRONG_ARCHITECTURE"        // the mirrored image is not linux/amd64
	FindingUnaccounted      = "UNACCOUNTED_REFERENCE"     // an install reference is not in the snapshot
	FindingCandidate        = "CANDIDATE_REVISION_DIFF"   // the snapshot is for another candidate revision
	FindingSourceRegistry   = "SOURCE_REGISTRY_REFERENCE" // an install would pull from the source registry, not the mirror
)

// Finding is one problem the preflight or comparison found.
type Finding struct {
	Component string `json:"component"`
	Code      string `json:"code"`
	Message   string `json:"message"`
}

func (f Finding) String() string { return fmt.Sprintf("[%s] %s: %s", f.Code, f.Component, f.Message) }

// InstallRef is an image reference an install will use, with the component it is for.
type InstallRef struct {
	Component string
	Ref       string
}

// InstallRefs lists the image references an install of profile will use: the rendered
// values for the operator, SLIM and agent-runtime images when they are supplied, the
// installer configuration for the rest, and the add-on and k0s lists. After mirroring,
// these are the references that point at the mirror.
func InstallRefs(profile string, in InventoryInput) []InstallRef {
	var refs []InstallRef
	add := func(component, ref string) {
		if ref = strings.TrimSpace(ref); ref != "" && ref != "null" {
			refs = append(refs, InstallRef{component, ref})
		}
	}
	// The operator image is an install reference only where the AI operator is installed.
	operatorOn := in.componentOn(profile, "aiOperator")
	if v := in.Values[profile]; v != nil {
		if operatorOn {
			add("splunk-ai-operator", v.Images.Operator)
		}
		add("slim", v.Images.Slim)
		add("agent-runtime-base", v.Images.AgentRuntime.Base)
		add("agent-runtime-schema-setup", v.Images.AgentRuntime.SchemaSetup)
		for _, p := range sortedKeys(v.Images.AgentRuntime.Providers) {
			add("agent-runtime-provider-"+p, v.Images.AgentRuntime.Providers[p])
		}
		// The installer also sets every configured provider on the operator, with or
		// without a feature for it; the rendered values list only the featured ones. Such
		// a configuration-only provider exists only as operator environment, so it is a
		// reference only where the operator is installed (as in the inventory).
		for _, p := range sortedKeys(in.Installer.Images.AgentRuntime.ProviderImages) {
			if _, rendered := v.Images.AgentRuntime.Providers[p]; !rendered && operatorOn {
				add("agent-runtime-provider-"+p, configuredRef(in.Installer.Images.Registry, in.Installer.Images.AgentRuntime.ProviderImages[p]))
			}
		}
	} else {
		// No rendered values: take the configured references the way the installer does.
		cfg := in.Installer.Images
		url := func(ref string) string {
			if ref = strings.TrimSpace(ref); ref == "" || ref == "null" {
				return ""
			}
			return buildImageURL(cfg.Registry, ref)
		}
		add("slim", url(cfg.Slim.APIImage))
		add("agent-runtime-base", url(cfg.AgentRuntime.BaseImage))
		add("agent-runtime-schema-setup", url(cfg.AgentRuntime.SchemaSetupImage))
		for _, p := range sortedKeys(cfg.AgentRuntime.ProviderImages) {
			// The candidate's own provider is a candidate image; any other is
			// configuration-only and follows the operator, as in the inventory.
			if in.isCandidateProvider(p) || operatorOn {
				add("agent-runtime-provider-"+p, url(cfg.AgentRuntime.ProviderImages[p]))
			}
		}
	}
	// The versioned base pins are not in the rendered values: the installer reads them
	// from the configuration. The pin for the candidate's runtimeVersion is the
	// candidate base, so it must be that image's mirror reference.
	cfg := in.Installer.Images
	for _, v := range sortedKeys(cfg.AgentRuntime.BaseImages) {
		component := baseVersionComponent(v)
		if in.isCandidateRuntimeVersion(v) {
			component = "agent-runtime-base"
		}
		if operatorOn {
			add(component, configuredRef(cfg.Registry, cfg.AgentRuntime.BaseImages[v]))
		}
	}
	for _, img := range installerConfigImages(in) {
		// With rendered values the operator reference came from them, above.
		if (img.Component == "splunk-ai-operator" && in.Values[profile] != nil) || !hasProfile(img.Profiles, profile) {
			continue
		}
		add(img.Component, img.Source)
	}
	for _, ref := range in.AddonRefs {
		if ref = strings.TrimSpace(ref); ref == "" || strings.HasPrefix(ref, "#") {
			continue
		}
		component, profiles, gate := classifyAddon(ref)
		if hasProfile(profiles, profile) && (gate == "" || in.componentOn(profile, gate)) {
			add(component, ref)
		}
	}
	for _, ref := range in.K0sRefs {
		if ref = strings.TrimSpace(ref); ref != "" && !strings.HasPrefix(ref, "#") {
			add("k0s-"+imageBaseName(ref), ref)
		}
	}
	return refs
}

func hasProfile(profiles []string, p string) bool {
	for _, q := range profiles {
		if q == p {
			return true
		}
	}
	return false
}

// Compare checks every reference an install of profile will use against the snapshot.
// An install must use the mirror: a reference is accounted for only when it is the
// component's own mirror reference, or a digest reference to that entry's digest in the
// mirror repository. Everything else is a finding:
//
//   - SOURCE_REGISTRY_REFERENCE: it points at the registry the image was copied from,
//     so the install would depend on an external registry;
//   - DIGEST_MISMATCH: it pins a different digest in the mirror repository;
//   - UNACCOUNTED_REFERENCE: it is not in the snapshot, uses a mutable tag in the
//     mirror, or is the image of a different component.
func Compare(snap *Snapshot, profile string, refs []InstallRef) []Finding {
	var findings []Finding
	for _, r := range refs {
		p, err := ParseRef(r.Ref)
		if err != nil {
			findings = append(findings, Finding{r.Component, FindingUnaccounted, "install reference is not a valid image reference"})
			continue
		}
		var (
			accounted      bool
			otherComponent string
			sourceEntry    *Entry
			sameRepoDigest string
		)
		for i := range snap.Spec.Entries {
			e := snap.Spec.Entries[i]
			if !hasProfile(e.Profiles, profile) {
				continue
			}
			switch matchEntry(e, snap.Spec.Mirror, p) {
			case matchExact:
				if e.Component == r.Component {
					accounted = true
				} else if otherComponent == "" {
					otherComponent = e.Component
				}
			case matchSource:
				if e.Component == r.Component && sourceEntry == nil {
					sourceEntry = &snap.Spec.Entries[i]
				}
			case matchRepoOnly:
				sameRepoDigest = e.Digest
			}
			if accounted {
				break
			}
		}
		switch {
		case accounted:
		case otherComponent != "":
			findings = append(findings, Finding{r.Component, FindingUnaccounted,
				fmt.Sprintf("%s is the image of component %s, not of %s", r.Ref, otherComponent, r.Component)})
		case sourceEntry != nil:
			findings = append(findings, Finding{r.Component, FindingSourceRegistry,
				fmt.Sprintf("%s pulls from the source registry; install from the mirror reference %s", r.Ref, sourceEntry.MirrorRef)})
		case sameRepoDigest != "" && p.Digest != "":
			findings = append(findings, Finding{r.Component, FindingDigest,
				fmt.Sprintf("%s pins %s but the snapshot records %s", r.Ref, p.Digest, sameRepoDigest)})
		default:
			findings = append(findings, Finding{r.Component, FindingUnaccounted,
				fmt.Sprintf("%s is not an image of this snapshot (profile %s)", r.Ref, profile)})
		}
	}
	sortFindings(findings)
	return findings
}

type matchKind int

const (
	matchNone     matchKind = iota
	matchSource             // the entry's source repository
	matchRepoOnly           // the entry's mirror repository, but not by its digest
	matchExact              // the entry's mirror repository, pinned to its digest
)

func matchEntry(e Entry, mirror string, ref ParsedRef) matchKind {
	src, err := ParseRef(e.Source)
	if err != nil {
		return matchNone
	}
	refRepo := ref.Registry + "/" + ref.Repository
	switch {
	case refRepo == MirrorRepository(mirror, src):
		if ref.Digest != "" && ref.Digest == e.Digest {
			return matchExact
		}
		return matchRepoOnly
	case refRepo == src.Registry+"/"+src.Repository:
		return matchSource
	}
	return matchNone
}

// Preflight checks that an install of profile can start from the mirror: the snapshot
// belongs to the inventory it is checked against, covers every image the profile needs,
// and each of those images is in the mirror with the recorded digest and linux/amd64.
// It names the offending component in every finding; no finding means it can start.
func Preflight(ctx context.Context, reg Registry, snap *Snapshot, inv *Inventory, profile string) []Finding {
	var findings []Finding
	if inv != nil {
		if inv.Checksum != snap.Spec.InventoryChecksum {
			findings = append(findings, Finding{"inventory", FindingInventoryChanged,
				"the snapshot was made from a different inventory than the one now derived; create a new snapshot"})
		}
		if inv.Candidate.Checksum != snap.Spec.Candidate.Checksum {
			findings = append(findings, Finding{"candidate-manifest", FindingCandidate,
				fmt.Sprintf("the snapshot is for candidate revision %d (checksum %s), the record is now revision %d (checksum %s)",
					snap.Spec.Candidate.Revision, short(snap.Spec.Candidate.Checksum), inv.Candidate.Revision, short(inv.Candidate.Checksum))})
		}
		// An entry covers a profile only when it lists that profile: an image the snapshot
		// recorded for another profile does not make this one ready.
		byKey := map[string]bool{}
		for _, e := range snap.Spec.Entries {
			if hasProfile(e.Profiles, profile) {
				byKey[e.Component+"\x00"+e.Source] = true
			}
		}
		for _, img := range inv.ForProfile(profile) {
			if !byKey[img.Component+"\x00"+img.Source] {
				findings = append(findings, Finding{img.Component, FindingOmitted,
					fmt.Sprintf("%s is needed by profile %s but has no entry in the snapshot", img.Source, profile)})
			}
		}
	}
	for _, e := range snap.Spec.Entries {
		if !hasProfile(e.Profiles, profile) {
			continue
		}
		findings = append(findings, checkEntry(ctx, reg, e)...)
	}
	sortFindings(findings)
	return findings
}

func checkEntry(ctx context.Context, reg Registry, e Entry) []Finding {
	switch {
	case e.Status == StatusBlocked:
		return []Finding{{e.Component, FindingBlocked, "recorded as an external blocker: " + e.Blocker}}
	case e.MirrorRef == "":
		return []Finding{{e.Component, FindingNoMirror, "the entry has no mirror reference"}}
	}
	d, err := reg.Describe(ctx, e.MirrorRef)
	if err != nil {
		return []Finding{{e.Component, FindingMissingImage, fmt.Sprintf("%s is not available in the mirror: %s", e.MirrorRef, Sanitize(err.Error()))}}
	}
	var out []Finding
	if d.Digest != e.Digest {
		out = append(out, Finding{e.Component, FindingDigest, fmt.Sprintf("the mirror serves %s, the snapshot records %s", d.Digest, e.Digest)})
	}
	switch plat, ok := d.PlatformDigests[Platform]; {
	case !ok:
		out = append(out, Finding{e.Component, FindingArch,
			fmt.Sprintf("the mirrored image is not %s (platforms: %s)", Platform, strings.Join(d.Platforms(), ", "))})
	case plat != d.Digest:
		out = append(out, Finding{e.Component, FindingArch,
			fmt.Sprintf("the mirror serves a multi-platform index, not the %s manifest the snapshot pins", Platform)})
	}
	return out
}

func sortFindings(f []Finding) {
	sort.SliceStable(f, func(i, j int) bool {
		if f[i].Component != f[j].Component {
			return f[i].Component < f[j].Component
		}
		return f[i].Code < f[j].Code
	})
}

func short(sum string) string {
	if len(sum) > 12 {
		return sum[:12]
	}
	return sum
}
