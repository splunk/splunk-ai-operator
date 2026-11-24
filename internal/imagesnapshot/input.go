package imagesnapshot

import (
	"fmt"
	"os"
	"strings"

	"github.com/splunk/splunk-ai-operator/internal/candidatecontract"
)

// InputFiles names the files an inventory is derived from. An inventory needs the
// Candidate; the component switches alone (InventoryInput.ComponentOn) do not.
type InputFiles struct {
	Candidate         string // the agent-runtime candidate manifest; "" reads no candidate
	Config            string // the installer configuration
	CPUOnlyValues     string // render-profile output for cpuOnly
	FullFeatureValues string // render-profile output for fullfeature
	AddonList         string // addon-images.list from the air-gap bundle
	K0sList           string // k0s airgap list-images output
	Owners            string // YAML map of component to owner
}

// LoadInput reads and validates the files an inventory is derived from. Every tool that
// builds or checks an inventory uses it, so they all read their inputs the same way.
func LoadInput(f InputFiles) (InventoryInput, error) {
	var in InventoryInput
	var err error
	if f.Candidate != "" {
		var m candidatecontract.Manifest
		if err := candidatecontract.Read(f.Candidate, &m); err != nil {
			return in, fmt.Errorf("candidate manifest: %w", err)
		}
		if err := m.Validate(); err != nil {
			return in, fmt.Errorf("candidate manifest %s is not a valid candidate record: %w", f.Candidate, err)
		}
		raw, err := os.ReadFile(f.Candidate)
		if err != nil {
			return in, err
		}
		in.Candidate, in.CandidateChecksum = &m, Checksum(raw)
	}

	if f.Config != "" {
		if err := ReadFile(f.Config, &in.Installer); err != nil {
			return in, fmt.Errorf("installer config: %w", err)
		}
	} else {
		// With no installer configuration there is no installer whose defaults apply.
		in.NoInstallerDefaults = true
	}
	in.Values = map[string]*RenderedValues{}
	for profile, path := range map[string]string{ProfileCPUOnly: f.CPUOnlyValues, ProfileFullFeature: f.FullFeatureValues} {
		if path == "" {
			continue
		}
		var v RenderedValues
		if err := ReadFile(path, &v); err != nil {
			return in, fmt.Errorf("rendered values for %s: %w", profile, err)
		}
		if v.Profile.Effective != "" && v.Profile.Effective != profile {
			return in, fmt.Errorf("%s is the rendered profile %q, not %q", path, v.Profile.Effective, profile)
		}
		in.Values[profile] = &v
	}
	if in.AddonRefs, err = readLines(f.AddonList); err != nil {
		return in, err
	}
	if in.K0sRefs, err = readLines(f.K0sList); err != nil {
		return in, err
	}
	if f.Owners != "" {
		if err := ReadFile(f.Owners, &in.Owners); err != nil {
			return in, fmt.Errorf("owners: %w", err)
		}
	}
	return in, nil
}

// ComponentOn reports whether a component is installed for a profile, exactly as the
// inventory decides it: the rendered switch, else the installer configuration's own
// switch, else the profile's default, with the installer's extra gates applied.
func (in InventoryInput) ComponentOn(profile, name string) bool { return in.componentOn(profile, name) }

func readLines(path string) ([]string, error) {
	if path == "" {
		return nil, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return strings.Split(string(b), "\n"), nil
}
