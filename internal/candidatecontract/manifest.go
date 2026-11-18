// Package candidatecontract validates development candidates and renders them
// through the operator handlers without contacting a cluster or registry.
package candidatecontract

import (
	"fmt"
	"os"
	"reflect"
	"regexp"
	"strings"

	"k8s.io/apimachinery/pkg/util/validation"
	"sigs.k8s.io/yaml"
)

type Manifest struct {
	RecordType      string `json:"recordType"`
	ManifestVersion int    `json:"manifestVersion"`
	Metadata        struct {
		Name string `json:"name"`
	} `json:"metadata"`
	Spec struct {
		Revision          int                  `json:"revision"`
		RuntimeVersion    string               `json:"runtimeVersion"`
		ContractVersion   string               `json:"contractVersion"`
		CompatibilityPair string               `json:"compatibilityPair"`
		Qualification     string               `json:"qualification"`
		Components        map[string]Component `json:"components"`
		Contract          Contract             `json:"contract"`
		History           []Change             `json:"history"`
	} `json:"spec"`
}

type Component struct {
	Image       string `json:"image,omitempty"`
	Provider    string `json:"provider,omitempty"`
	AgentModule string `json:"agentModule,omitempty"`
	AppID       string `json:"appId,omitempty"`
	AppVersion  string `json:"appVersion,omitempty"`
	Build       string `json:"build,omitempty"`
	Source      struct {
		Repository string `json:"repository"`
		Branch     string `json:"branch,omitempty"`
		Commit     string `json:"commit"`
	} `json:"source,omitempty"`
	RequiredEnvironment []EnvironmentBinding `json:"requiredEnvironment,omitempty"`
	EndpointContract    struct {
		SettingsPath string `json:"settingsPath"`
		BasePath     string `json:"basePath"`
		AgentPath    string `json:"agentPath"`
	} `json:"endpointContract,omitempty"`
}

type EnvironmentBinding struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type API struct {
	Prefix      string `json:"prefix,omitempty"`
	BasePath    string `json:"basePath,omitempty"`
	AgentPath   string `json:"agentPath,omitempty"`
	HTTPPort    int32  `json:"httpPort"`
	MetricsPort int32  `json:"metricsPort"`
}

type Contract struct {
	RuntimeAPI      API `json:"runtimeAPI"`
	SlimAPI         API `json:"slimAPI"`
	LoaderSelection struct {
		EnvironmentVariable string `json:"environmentVariable"`
		Value               string `json:"value"`
	} `json:"loaderSelection"`
	SchemaEntryPoint struct {
		SQLPath              string   `json:"sqlPath"`
		OperatorCommand      string   `json:"operatorCommand"`
		OperatorSQLArguments []string `json:"operatorSqlArguments"`
	} `json:"schemaEntryPoint"`
	ReadinessAndHealth struct {
		Method string   `json:"method"`
		Path   string   `json:"path"`
		Probes []string `json:"probes"`
	} `json:"readinessAndHealth"`
	SecretKeys struct {
		ReferenceField string   `json:"referenceField"`
		Name           string   `json:"name"`
		Type           string   `json:"type"`
		Required       []string `json:"required"`
	} `json:"secretKeys"`
}

type Change struct {
	Revision       int               `json:"revision"`
	Change         string            `json:"change"`
	Source         string            `json:"source"`
	PreviousImages map[string]string `json:"previousImages,omitempty"`
}

type Matrix struct {
	Spec struct {
		Policy struct {
			Enforcement string `json:"enforcement"`
		} `json:"policy"`
		ContractVersions map[string]struct {
			Status string `json:"status"`
		} `json:"contractVersions"`
		Bases    []struct{ ID, Image, ContractVersion string }                       `json:"bases"`
		Carriers []struct{ ID, Image, Provider, Loader string }                      `json:"carriers"`
		Pairs    []struct{ ID, BaseRef, CarrierRef, ContractVersion, Status string } `json:"pairs"`
	} `json:"spec"`
}

// Read omits parser details because malformed input may contain credential text.
func Read(filename string, into any) error {
	data, err := os.ReadFile(filename)
	if err != nil {
		return fmt.Errorf("input: cannot read file")
	}
	if yaml.Unmarshal(data, into) != nil {
		return fmt.Errorf("input: invalid YAML")
	}
	return nil
}

var imagePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9.:-]*/[a-z0-9_./-]+(:[A-Za-z0-9_][A-Za-z0-9_.-]*|@sha256:[a-f0-9]{64})$`)
var loaderPattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*:[A-Za-z_][A-Za-z0-9_]*$`)
var providerPattern = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
var versionPattern = regexp.MustCompile(`^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$`)
var envSeparatorPattern = regexp.MustCompile(`[^A-Z0-9]+`)

var imageComponents = []string{"runtimeBase", "launchpadCarrier", "schemaSetup", "slim"}
var requiredSecretKeys = []string{"DATABASE_URL", "PG_HOST", "PG_PORT", "PG_USER", "PG_PASSWORD", "PG_DBNAME"}

func fieldError(path string) error {
	return fmt.Errorf("%s: missing or incompatible required field", path)
}
func present(s string) bool {
	return strings.TrimSpace(s) != "" && !strings.HasPrefix(strings.ToLower(s), "pending")
}

// Validate checks the implemented operator interface, independently of image
// provenance, architectures, registry availability, or release certification.
func (m *Manifest) Validate() error {
	if m.RecordType != "launchpad-candidate-set" {
		return fieldError("recordType")
	}
	if m.ManifestVersion != 1 {
		return fieldError("manifestVersion")
	}
	if !present(m.Metadata.Name) {
		return fieldError("metadata.name")
	}
	if m.Spec.Revision < 1 {
		return fieldError("spec.revision")
	}
	if m.Spec.Qualification != "pending" {
		return fieldError("spec.qualification")
	}
	if !versionPattern.MatchString(m.Spec.RuntimeVersion) {
		return fieldError("spec.runtimeVersion")
	}
	for _, name := range imageComponents {
		image := m.Spec.Components[name].Image
		registry, _, _ := strings.Cut(image, "/")
		if !imagePattern.MatchString(image) || strings.Contains(image, "://") || strings.Contains(image, "//") || (!strings.ContainsAny(registry, ".:") && registry != "localhost") {
			return fieldError("spec.components." + name + ".image")
		}
	}
	carrier := m.Spec.Components["launchpadCarrier"]
	if !providerPattern.MatchString(carrier.Provider) || len(validation.IsDNS1123Label(carrier.Provider)) != 0 {
		return fieldError("spec.components.launchpadCarrier.provider")
	}
	if !loaderPattern.MatchString(carrier.AgentModule) {
		return fieldError("spec.components.launchpadCarrier.agentModule")
	}
	c := m.Spec.Contract
	if c.LoaderSelection.EnvironmentVariable != "AGENT_MODULE" || c.LoaderSelection.Value != carrier.AgentModule {
		return fieldError("spec.contract.loaderSelection")
	}
	if c.RuntimeAPI.Prefix != "/system/ai-agent-runtime/v1" {
		return fieldError("spec.contract.runtimeAPI.prefix")
	}
	if c.RuntimeAPI.HTTPPort != 8080 || c.RuntimeAPI.MetricsPort != 9090 {
		return fieldError("spec.contract.runtimeAPI")
	}
	if c.SlimAPI.BasePath != "/tenant/slim-api/v1alpha1" || c.SlimAPI.AgentPath != "/agent/agent_runtime" {
		return fieldError("spec.contract.slimAPI")
	}
	if c.SlimAPI.HTTPPort != 8080 || c.SlimAPI.MetricsPort != 8088 {
		return fieldError("spec.contract.slimAPI")
	}
	if c.ReadinessAndHealth.Method != "GET" || c.ReadinessAndHealth.Path != "/health" || !sameSet(c.ReadinessAndHealth.Probes, []string{"startup", "liveness", "readiness"}) {
		return fieldError("spec.contract.readinessAndHealth")
	}
	if c.SchemaEntryPoint.SQLPath != "/schema.sql" || c.SchemaEntryPoint.OperatorCommand != "sh -c" || !reflect.DeepEqual(c.SchemaEntryPoint.OperatorSQLArguments, []string{"-v", "ON_ERROR_STOP=1", "-f", "/schema.sql"}) {
		return fieldError("spec.contract.schemaEntryPoint")
	}
	if c.SecretKeys.ReferenceField != "checkpointDbSecretRef" || c.SecretKeys.Type != "Opaque" || len(validation.IsDNS1123Subdomain(c.SecretKeys.Name)) != 0 || !sameSet(c.SecretKeys.Required, requiredSecretKeys) {
		return fieldError("spec.contract.secretKeys")
	}
	bindings := m.Spec.Components["slim"].RequiredEnvironment
	if len(bindings) != 2 || bindings[0].Name != "PLATFORM_URL" || bindings[0].Value != "platform-url-origin" || bindings[1].Name != "AI_TIER_AGENT_RUNTIME_URL" || bindings[1].Value != "agentruntime-service-origin" {
		return fieldError("spec.components.slim.requiredEnvironment")
	}
	app := m.Spec.Components["aitk"]
	for name, value := range map[string]string{"appId": app.AppID, "appVersion": app.AppVersion, "build": app.Build} {
		if !present(value) {
			return fieldError("spec.components.aitk." + name)
		}
	}
	if app.EndpointContract.SettingsPath != "/services/mltk/ai_tier_settings" || app.EndpointContract.BasePath != c.SlimAPI.BasePath || app.EndpointContract.AgentPath != c.SlimAPI.AgentPath {
		return fieldError("spec.components.aitk.endpointContract")
	}
	if len(m.Spec.History) == 0 || m.Spec.History[len(m.Spec.History)-1].Revision != m.Spec.Revision {
		return fieldError("spec.history")
	}
	for i, h := range m.Spec.History {
		if h.Revision != i+1 || !present(h.Change) || !present(h.Source) {
			return fieldError("spec.history")
		}
	}
	return nil
}

func sameSet(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	seen := map[string]bool{}
	for _, s := range got {
		if seen[s] {
			return false
		}
		seen[s] = true
	}
	for _, s := range want {
		if !seen[s] {
			return false
		}
	}
	return true
}

// OperatorEnvironment is a projection of the selected record, with no fallback
// to a default image or registry. These are the operator's existing image inputs.
func (m *Manifest) OperatorEnvironment() map[string]string {
	carrier := m.Spec.Components["launchpadCarrier"]
	return map[string]string{
		"RELATED_IMAGE_AGENT_RUNTIME_BASE":                                      m.Spec.Components["runtimeBase"].Image,
		"RELATED_IMAGE_AGENT_RUNTIME_BASE_" + envSegment(m.Spec.RuntimeVersion): m.Spec.Components["runtimeBase"].Image,
		"RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_" + envSegment(carrier.Provider):  carrier.Image,
		"RELATED_AGENT_RUNTIME_MODULE_PROVIDER_" + envSegment(carrier.Provider): carrier.AgentModule,
		"RELATED_IMAGE_AGENT_RUNTIME_SCHEMA_SETUP":                              m.Spec.Components["schemaSetup"].Image,
		"RELATED_IMAGE_SLIM_API":                                                m.Spec.Components["slim"].Image,
	}
}

func envSegment(s string) string {
	return strings.Trim(envSeparatorPattern.ReplaceAllString(strings.ToUpper(s), "_"), "_")
}

func (m *Manifest) MatrixStatus(matrix *Matrix) (string, error) {
	if matrix.Spec.ContractVersions[m.Spec.ContractVersion].Status != "supported" {
		return "", fieldError("spec.contractVersion")
	}
	if matrix.Spec.Policy.Enforcement != "documentation-only" {
		return "", fieldError("matrix.spec.policy.enforcement")
	}
	if !present(m.Spec.CompatibilityPair) {
		return "", fieldError("spec.compatibilityPair")
	}
	for _, pair := range matrix.Spec.Pairs {
		if pair.ID != m.Spec.CompatibilityPair {
			continue
		}
		if (pair.Status != "pending" && pair.Status != "untested" && pair.Status != "certified") || pair.ContractVersion != m.Spec.ContractVersion {
			return "", fieldError("spec.compatibilityPair")
		}
		baseOK, carrierOK := false, false
		for _, b := range matrix.Spec.Bases {
			if b.ID == pair.BaseRef && b.Image == m.Spec.Components["runtimeBase"].Image && b.ContractVersion == m.Spec.ContractVersion {
				baseOK = true
			}
		}
		for _, c := range matrix.Spec.Carriers {
			if c.ID == pair.CarrierRef && c.Image == m.Spec.Components["launchpadCarrier"].Image && c.Provider == m.Spec.Components["launchpadCarrier"].Provider && c.Loader == m.Spec.Components["launchpadCarrier"].AgentModule {
				carrierOK = true
			}
		}
		if !baseOK || !carrierOK {
			return "", fieldError("spec.compatibilityPair")
		}
		return pair.Status, nil
	}
	// Documentation-only policy permits an unlisted candidate; local checks do
	// not turn it into a certified pair or silently select a different image.
	return "unlisted", nil
}

type ImageChange struct{ Component, Previous, Current string }

func ValidateRefresh(previous, next *Manifest) ([]ImageChange, error) {
	if err := previous.Validate(); err != nil {
		return nil, err
	}
	if err := next.Validate(); err != nil {
		return nil, err
	}
	if next.Spec.Revision <= previous.Spec.Revision {
		return nil, fieldError("spec.revision")
	}
	if len(next.Spec.History) <= len(previous.Spec.History) || !reflect.DeepEqual(next.Spec.History[:len(previous.Spec.History)], previous.Spec.History) {
		return nil, fieldError("spec.history")
	}
	changes := []ImageChange{}
	for _, name := range imageComponents {
		oldImage, newImage := previous.Spec.Components[name].Image, next.Spec.Components[name].Image
		if oldImage == newImage {
			continue
		}
		retained := false
		for _, h := range next.Spec.History[len(previous.Spec.History):] {
			if h.PreviousImages[name] == oldImage {
				retained = true
			}
		}
		if !retained {
			return nil, fieldError("spec.history.previousImages." + name)
		}
		changes = append(changes, ImageChange{name, oldImage, newImage})
	}
	return changes, nil
}
