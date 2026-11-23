package imagesnapshot

import (
	"fmt"
	"sort"
	"strings"
)

// candidateKeys maps a candidate component to the installer setting that carries it.
var candidateKeys = map[string]string{
	"runtimeBase": "images.agentRuntime.baseImage",
	"schemaSetup": "images.agentRuntime.schemaSetupImage",
	"slim":        "images.slim.apiImage",
	// launchpadCarrier is images.agentRuntime.providerImages.<provider>, set below.
}

// mapSettings are the installer settings whose last key is a free-form name (a version
// or a provider) that may itself contain dots.
var mapSettings = []string{"images.agentRuntime.baseImages.", "images.agentRuntime.providerImages."}

// InstallConfig returns the installer `images:` settings that make an install use the
// snapshot's images: every setting an entry came from, set to that entry's
// digest-pinned mirror reference. runtimeVersion is the candidate's runtimeVersion;
// the operator resolves the candidate's base through the versioned pin
// images.agentRuntime.baseImages.<runtimeVersion>, so that pin is set to the candidate
// base too.
//
// images.registry is set to the mirror's host: the installer configures the nodes' access
// to a registry (plain HTTP when images.registryInsecure is true) only for images.registry.
// It does not prefix these references, which already name a registry host.
//
// Images that reach the nodes in the bundle's image archives (the add-on and k0s lists)
// have no installer setting and are not included. A mirror reference the installer
// would not use as it is (build_image_url prefixes images.registry to a reference
// whose host has no dot and is not an IP address) is an error, not a silent rewrite.
func InstallConfig(snap *Snapshot, runtimeVersion string) (map[string]any, error) {
	if err := Validate(snap); err != nil {
		return nil, err
	}
	settings := map[string]string{} // dotted path -> mirror reference
	set := func(path, ref string) error {
		if !qualifiedImage.MatchString(ref) {
			return fmt.Errorf("mirror reference %s would be prefixed with images.registry by the installer (its host needs a dot or an IP address)", ref)
		}
		if old, ok := settings[path]; ok && old != ref {
			return fmt.Errorf("%s would be both %s and %s", path, old, ref)
		}
		settings[path] = ref
		return nil
	}
	for _, e := range snap.Spec.Entries {
		var err error
		switch origin := e.Origin; {
		case strings.HasPrefix(origin, "installer-config:"):
			err = set(strings.TrimPrefix(origin, "installer-config:"), e.MirrorRef)
		case strings.HasPrefix(origin, "candidate-manifest:components."):
			key := strings.TrimPrefix(origin, "candidate-manifest:components.")
			switch {
			case key == "launchpadCarrier":
				err = set("images.agentRuntime.providerImages."+strings.TrimPrefix(e.Component, "agent-runtime-provider-"), e.MirrorRef)
			case candidateKeys[key] != "":
				err = set(candidateKeys[key], e.MirrorRef)
				if err == nil && key == "runtimeBase" && runtimeVersion != "" {
					err = set("images.agentRuntime.baseImages."+runtimeVersion, e.MirrorRef)
				}
			}
		}
		if err != nil {
			return nil, fmt.Errorf("component %s: %w", e.Component, err)
		}
	}
	if len(settings) == 0 {
		return nil, fmt.Errorf("snapshot %s has no image the installer configures", snap.Metadata.ID)
	}
	settings["images.registry"] = MirrorHost(snap.Spec.Mirror)
	out := map[string]any{}
	paths := make([]string, 0, len(settings))
	for p := range settings {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		putPath(out, splitSetting(p), settings[p])
	}
	return out, nil
}

// MirrorHost is the registry host (and port) of a mirror: "10.0.39.38:5099/ai-tier" -> "10.0.39.38:5099".
func MirrorHost(mirror string) string {
	host, _, _ := strings.Cut(strings.TrimSpace(mirror), "/")
	return host
}

// splitSetting splits a dotted setting path into keys, keeping the free-form last key of
// a map setting whole: images.agentRuntime.baseImages.v1.9.0 -> [images agentRuntime baseImages v1.9.0].
func splitSetting(path string) []string {
	for _, prefix := range mapSettings {
		if strings.HasPrefix(path, prefix) {
			return append(strings.Split(strings.TrimSuffix(prefix, "."), "."), strings.TrimPrefix(path, prefix))
		}
	}
	return strings.Split(path, ".")
}

func putPath(m map[string]any, keys []string, value string) {
	for _, k := range keys[:len(keys)-1] {
		next, ok := m[k].(map[string]any)
		if !ok {
			next = map[string]any{}
			m[k] = next
		}
		m = next
	}
	m[keys[len(keys)-1]] = value
}

// SnapshotInventory is the inventory a snapshot records, for checking a mirror against
// the snapshot alone. An air-gapped install has the snapshot but not the source
// configuration the snapshot was made from: its own configuration names the mirror
// references, so an inventory derived from it would never match. Use it with Preflight
// to check every entry against the mirror, and Compare to check the install's references.
func SnapshotInventory(snap *Snapshot) *Inventory {
	inv := &Inventory{Candidate: snap.Spec.Candidate, Checksum: snap.Spec.InventoryChecksum}
	for _, e := range snap.Spec.Entries {
		inv.Images = append(inv.Images, e.Image)
	}
	return inv
}
