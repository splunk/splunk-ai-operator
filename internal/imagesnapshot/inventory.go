package imagesnapshot

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"

	"sigs.k8s.io/yaml"

	"github.com/splunk/splunk-ai-operator/internal/candidatecontract"
)

// InstallerConfig is the part of the installer's configuration file that names
// images. The key names are the ones k0s_cluster_with_stack.sh reads.
type InstallerConfig struct {
	// Components are the installer's own component switches (`components.*`). The
	// installer treats an omitted switch as on. Rendered values, when supplied, win.
	Components map[string]any `json:"components"`
	// Splunk decides the installer's Splunk mode: the in-cluster Splunk Operator and
	// Standalone are installed only when splunk.enabled is true and no external
	// endpoint is set ("internal" mode).
	Splunk struct {
		Enabled  any `json:"enabled"`
		External struct {
			Endpoint string `json:"endpoint"`
		} `json:"external"`
	} `json:"splunk"`
	Images struct {
		// Registry is `images.registry`: the installer puts it in front of every image
		// path that does not start with a registry host (see buildImageURL).
		Registry string `json:"registry"`
		Operator struct {
			Image string `json:"image"`
		} `json:"operator"`
		Ray struct {
			HeadImage   string `json:"headImage"`
			WorkerImage string `json:"workerImage"`
		} `json:"ray"`
		Weaviate struct {
			Image string `json:"image"`
		} `json:"weaviate"`
		Saia struct {
			APIImage        string `json:"apiImage"`
			APIV2Image      string `json:"apiV2Image"`
			DataLoaderImage string `json:"dataLoaderImage"`
		} `json:"saia"`
		FluentBit struct {
			Image string `json:"image"`
		} `json:"fluentBit"`
		Nginx struct {
			Image string `json:"image"`
		} `json:"nginx"`
		OtelCollector struct {
			Image string `json:"image"`
		} `json:"otelCollector"`
		Splunk struct {
			Image         string `json:"image"`
			OperatorImage string `json:"operatorImage"`
		} `json:"splunk"`
		// The agent-runtime images below are also named by the candidate manifest,
		// which is authoritative for the selected revision. The default base, schema
		// setup, SLIM and the candidate's own provider are read only to be compared with
		// it by Compare. BaseImages (versioned base pins, RELATED_IMAGE_AGENT_RUNTIME_BASE_<V>)
		// and providers the candidate does not name are images the installer hands the
		// operator, so they are inventoried too.
		Slim struct {
			APIImage string `json:"apiImage"`
		} `json:"slim"`
		AgentRuntime struct {
			BaseImage        string            `json:"baseImage"`
			BaseImages       map[string]string `json:"baseImages"`
			SchemaSetupImage string            `json:"schemaSetupImage"`
			ProviderImages   map[string]string `json:"providerImages"`
		} `json:"agentRuntime"`
	} `json:"images"`
}

// RenderedValues is the part of `k0s_cluster_with_stack.sh render-profile` output
// that decides which images a profile installs: the effective component set.
type RenderedValues struct {
	Profile struct {
		Effective string `json:"effective"`
	} `json:"profile"`
	Images struct {
		Operator     string `json:"operator"`
		Slim         string `json:"slim"`
		AgentRuntime struct {
			Base        string            `json:"base"`
			SchemaSetup string            `json:"schemaSetup"`
			Providers   map[string]string `json:"providers"`
		} `json:"agentRuntime"`
	} `json:"images"`
	Components map[string]bool `json:"components"`
}

// InventoryInput gathers everything an inventory is derived from.
type InventoryInput struct {
	// Candidate is the selected MPR-188 candidate record and the checksum of its file.
	Candidate         *candidatecontract.Manifest
	CandidateChecksum string
	// Installer is the installer configuration naming the images outside the
	// candidate set (operator, Ray, Weaviate, SAIA, Fluent Bit, ...).
	Installer InstallerConfig
	// NoInstallerDefaults leaves the images the installer would default (Splunk
	// Operator, Fluent Bit, OpenTelemetry, nginx) out when the configuration omits
	// them. It is for a run given no installer configuration at all.
	NoInstallerDefaults bool
	// Values holds the rendered values per profile. The effective component set in
	// them switches add-ons and optional images on and off. A profile without
	// rendered values falls back to the profile's defaults.
	Values map[string]*RenderedValues
	// AddonRefs are the add-on images enumerated by the existing air-gap bundle
	// mechanism (addon-images.list), and K0sRefs the k0s system images
	// (`k0s airgap list-images`). Both are optional.
	AddonRefs []string
	K0sRefs   []string
	// Owners maps a component name to its owner. Optional.
	Owners map[string]string
}

// rule describes one image from the installer configuration.
type rule struct {
	component string
	role      string
	category  string
	profiles  []string
	gate      string // rendered component flag that switches it on, "" = always
}

var bothProfiles = []string{ProfileCPUOnly, ProfileFullFeature}
var fullOnly = []string{ProfileFullFeature}

// ReadFile parses a YAML or JSON file into out.
func ReadFile(filename string, out any) error {
	b, err := os.ReadFile(filename)
	if err != nil {
		return err
	}
	if err := yaml.UnmarshalStrict(b, out); err != nil {
		// Installer configs carry many keys this package does not read.
		return yaml.Unmarshal(b, out)
	}
	return nil
}

// Checksum returns the hex sha256 of b.
func Checksum(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// BuildInventory derives the complete image inventory for both profiles.
func BuildInventory(in InventoryInput) (*Inventory, error) {
	if in.Candidate == nil {
		return nil, fmt.Errorf("a candidate manifest is required")
	}
	owners := in.Owners
	if owners == nil {
		owners = map[string]string{}
	}
	var images []Image
	add := func(i Image) {
		if strings.TrimSpace(i.Source) == "" {
			return
		}
		if o := owners[i.Component]; o != "" {
			i.Owner = o
		}
		if i.Owner == "" {
			i.Owner = "unassigned"
		}
		images = append(images, i)
	}
	enabled := func(profile, gate string) bool {
		return gate == "" || in.componentOn(profile, gate)
	}
	profilesFor := func(candidates []string, gate string) []string {
		var out []string
		for _, p := range candidates {
			if enabled(p, gate) {
				out = append(out, p)
			}
		}
		return out
	}

	// 1. The candidate set selected by MPR-188 is authoritative for its four images.
	// AITK is a Splunk app, not an image, so it is not part of the inventory.
	for _, key := range sortedKeys(in.Candidate.Spec.Components) {
		c := in.Candidate.Spec.Components[key]
		if strings.TrimSpace(c.Image) == "" {
			continue
		}
		img := Image{Category: CategoryAgentRuntime, Profiles: bothProfiles, Source: c.Image,
			Origin: "candidate-manifest:components." + key, Owner: sourceOwner(c.Source.Repository)}
		switch key {
		case "runtimeBase":
			img.Component, img.Role = "agent-runtime-base", "Agent Runtime base image"
		case "launchpadCarrier":
			provider := c.Provider
			if provider == "" {
				provider = "provider"
			}
			img.Component, img.Role = "agent-runtime-provider-"+provider, "Agent Launchpad carrier and "+provider+" provider image"
		case "schemaSetup":
			img.Component, img.Role = "agent-runtime-schema-setup", "Agent Runtime schema setup image"
		case "slim":
			img.Component, img.Role, img.Category = "slim", "SLIM API image", CategorySLIM
		default:
			return nil, fmt.Errorf("candidate manifest: component %q has an image but is not a known candidate image", key)
		}
		add(img)
	}

	// 2. Images the installer configuration names outside the candidate set.
	for _, img := range installerConfigImages(in) {
		add(img)
	}

	// 2b. Agent-runtime images the installer configures beyond the candidate set: the
	// versioned base pins and providers the candidate does not name. A pin for the
	// candidate's own runtimeVersion is the candidate base (the candidate is
	// authoritative), so it adds nothing here; Compare holds it to that image.
	for _, img := range agentRuntimeConfigImages(in) {
		add(img)
	}

	// 3. Add-on images (cert-manager, Prometheus, KubeRay, NVIDIA, ...) and k0s system
	// images, as enumerated by the existing air-gap bundle mechanism.
	for _, ref := range in.AddonRefs {
		ref = strings.TrimSpace(ref)
		if ref == "" || strings.HasPrefix(ref, "#") {
			continue
		}
		component, profiles, gate := classifyAddon(ref)
		if profiles = profilesFor(profiles, gate); len(profiles) == 0 {
			continue
		}
		add(Image{Component: component, Role: "Platform add-on image", Category: CategoryAddon,
			Profiles: profiles, Source: ref, Origin: "addon-list"})
	}
	for _, ref := range in.K0sRefs {
		ref = strings.TrimSpace(ref)
		if ref == "" || strings.HasPrefix(ref, "#") {
			continue
		}
		add(Image{Component: "k0s-" + imageBaseName(ref), Role: "Kubernetes (k0s) system image",
			Category: CategoryKubernetes, Profiles: bothProfiles, Source: ref, Origin: "k0s-list"})
	}

	sort.SliceStable(images, func(i, j int) bool {
		a, b := images[i], images[j]
		if a.Component != b.Component {
			return a.Component < b.Component
		}
		if a.Source != b.Source {
			return a.Source < b.Source
		}
		return a.Origin < b.Origin
	})
	images = dedupe(images)

	inv := &Inventory{
		Candidate: CandidateRef{Name: in.Candidate.Metadata.Name, Revision: in.Candidate.Spec.Revision, Checksum: in.CandidateChecksum},
		Images:    images,
	}
	sum, err := inv.computeChecksum()
	if err != nil {
		return nil, err
	}
	inv.Checksum = sum
	return inv, nil
}

// installerConfigImages returns the images the installer configuration names outside
// the candidate set, with the profiles that install each. An image whose gating
// component is off for a profile does not apply to that profile.
//
// It applies what the installer applies: an omitted Splunk Operator, Fluent Bit,
// OpenTelemetry or nginx image takes the installer's default, and `images.registry` is
// put in front of a path with no registry host, exactly as build_image_url does. The
// returned sources are therefore the references the installer pulls from.
func installerConfigImages(in InventoryInput) []Image {
	profilesFor := func(candidates []string, gate string) []string {
		var out []string
		for _, p := range candidates {
			if gate == "" || in.componentOn(p, gate) {
				out = append(out, p)
			}
		}
		return out
	}
	cfg := in.Installer.Images
	orDefault := func(ref, def string) string {
		if ref = strings.TrimSpace(ref); ref == "" || ref == "null" {
			if in.NoInstallerDefaults {
				return ""
			}
			return def
		}
		return ref
	}
	var images []Image
	for _, r := range []struct {
		rule
		ref, key string
	}{
		{rule{"splunk-ai-operator", "Splunk AI operator image", CategoryOperator, bothProfiles, "aiOperator"}, cfg.Operator.Image, "images.operator.image"},
		{rule{"ray-head", "Ray head image", CategoryModelServing, fullOnly, "kuberay"}, cfg.Ray.HeadImage, "images.ray.headImage"},
		{rule{"ray-worker", "Ray worker image", CategoryModelServing, fullOnly, "kuberay"}, cfg.Ray.WorkerImage, "images.ray.workerImage"},
		{rule{"weaviate", "Weaviate vector database image", CategoryModelServing, fullOnly, ""}, cfg.Weaviate.Image, "images.weaviate.image"},
		{rule{"saia-api", "SAIA API image", CategoryModelServing, fullOnly, ""}, cfg.Saia.APIImage, "images.saia.apiImage"},
		{rule{"saia-api-v2", "SAIA API v2 image", CategoryModelServing, fullOnly, ""}, cfg.Saia.APIV2Image, "images.saia.apiV2Image"},
		{rule{"saia-data-loader", "SAIA data loader image", CategoryModelServing, fullOnly, ""}, cfg.Saia.DataLoaderImage, "images.saia.dataLoaderImage"},
		{rule{"nginx", "Nginx image (SAIA front end)", CategoryPlatform, fullOnly, ""}, orDefault(cfg.Nginx.Image, DefaultNginxImage), "images.nginx.image"},
		{rule{"fluent-bit", "Fluent Bit image", CategoryPlatform, bothProfiles, ""}, orDefault(cfg.FluentBit.Image, DefaultFluentBitImage), "images.fluentBit.image"},
		{rule{"otel-collector", "OpenTelemetry collector image", CategoryPlatform, bothProfiles, "otel"}, orDefault(cfg.OtelCollector.Image, DefaultOtelCollectorImage), "images.otelCollector.image"},
		{rule{"splunk-standalone", "Splunk Enterprise image", CategoryPlatform, bothProfiles, "splunkStandalone"}, cfg.Splunk.Image, "images.splunk.image"},
		{rule{"splunk-operator", "Splunk operator image", CategoryPlatform, bothProfiles, "splunkOperator"}, orDefault(cfg.Splunk.OperatorImage, DefaultSplunkOperatorImage), "images.splunk.operatorImage"},
	} {
		profiles := profilesFor(r.profiles, r.gate)
		if len(profiles) == 0 || strings.TrimSpace(r.ref) == "" || r.ref == "null" {
			continue
		}
		images = append(images, Image{Component: r.component, Role: r.role, Category: r.category, Profiles: profiles,
			Source: buildImageURL(cfg.Registry, strings.TrimSpace(r.ref)), Origin: "installer-config:" + r.key})
	}
	return images
}

// The images the installer uses when the configuration omits them
// (k0s_cluster_with_stack.sh, "Using default ... image").
const (
	DefaultSplunkOperatorImage = "docker.io/splunk/splunk-operator:3.0.0"
	DefaultFluentBitImage      = "fluent/fluent-bit:1.9.6"
	DefaultOtelCollectorImage  = "otel/opentelemetry-collector-contrib:0.122.1"
	DefaultNginxImage          = "docker.io/library/nginx:1.27-alpine"
)

// qualifiedImage is the test build_image_url uses for "already names a registry host":
// a dotted host or an IPv4 address, an optional port, a slash, and a tag or digest
// somewhere after it. Notably a host without a dot (localhost:5000) and a reference
// with no tag are NOT treated as qualified, so the installer prefixes them.
var qualifiedImage = regexp.MustCompile(`^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/.*:.+`)

// buildImageURL mirrors build_image_url in k0s_cluster_with_stack.sh: a qualified
// reference is used as it is, anything else is placed under images.registry when one is set.
func buildImageURL(registry, image string) string {
	if qualifiedImage.MatchString(image) {
		return image
	}
	if registry = strings.TrimSpace(registry); registry != "" && registry != "null" {
		return registry + "/" + image
	}
	return image
}

// componentOn reports whether a component is installed for a profile: the rendered
// switch, else the installer configuration's own switch, else the profile's default.
// splunkInternal mirrors the installer's SPLUNK_MODE == internal: splunk.enabled is
// exactly true and there is no external endpoint. With no installer configuration there
// is no Splunk mode, so only an explicit configuration turns it on.
func (in InventoryInput) splunkInternal() bool {
	enabled := false
	switch x := in.Installer.Splunk.Enabled.(type) {
	case bool:
		enabled = x
	case string:
		enabled = x == "true"
	}
	ep := strings.TrimSpace(in.Installer.Splunk.External.Endpoint)
	return enabled && (ep == "" || ep == "null")
}

func (in InventoryInput) componentOn(profile, name string) bool {
	// The in-cluster Splunk components exist only in "internal" Splunk mode, whatever
	// the component switches say (component_enabled in the installer).
	if (name == "splunkOperator" || name == "splunkStandalone") && !in.splunkInternal() {
		return false
	}
	if v := in.Values[profile]; v != nil && v.Components != nil {
		if on, ok := v.Components[name]; ok {
			return on
		}
	}
	if raw, ok := in.Installer.Components[name]; ok && raw != nil {
		switch x := raw.(type) {
		case bool:
			return x
		case string:
			return x == "true" // config_bool: anything but "true" is false
		default:
			return false
		}
	}
	return componentEnabled(nil, profile, name)
}

// agentRuntimeConfigImages returns the configured agent-runtime images outside the
// candidate set. The installer sets every configured pin and provider on the operator
// (RELATED_IMAGE_AGENT_RUNTIME_BASE_<V>, RELATED_IMAGE_AGENT_RUNTIME_PROVIDER_<P>)
// whatever the features, so each one is an image the operator may pull, in either profile.
func agentRuntimeConfigImages(in InventoryInput) []Image {
	cfg := in.Installer.Images
	var out []Image
	if !in.componentOn(ProfileCPUOnly, "aiOperator") && !in.componentOn(ProfileFullFeature, "aiOperator") {
		return nil
	}
	profiles := func() []string {
		var ps []string
		for _, p := range bothProfiles {
			if in.componentOn(p, "aiOperator") {
				ps = append(ps, p)
			}
		}
		return ps
	}()
	for _, v := range sortedKeys(cfg.AgentRuntime.BaseImages) {
		ref := configuredRef(cfg.Registry, cfg.AgentRuntime.BaseImages[v])
		if ref == "" || in.isCandidateRuntimeVersion(v) {
			continue
		}
		out = append(out, Image{Component: baseVersionComponent(v), Role: "Agent Runtime base image pinned for runtimeVersion " + v,
			Category: CategoryAgentRuntime, Profiles: profiles, Source: ref,
			Origin: "installer-config:images.agentRuntime.baseImages." + v})
	}
	for _, p := range sortedKeys(cfg.AgentRuntime.ProviderImages) {
		ref := configuredRef(cfg.Registry, cfg.AgentRuntime.ProviderImages[p])
		if ref == "" || in.isCandidateProvider(p) {
			continue
		}
		out = append(out, Image{Component: "agent-runtime-provider-" + p, Role: "Agent Runtime " + p + " provider image (not in the candidate set)",
			Category: CategoryAgentRuntime, Profiles: profiles, Source: ref,
			Origin: "installer-config:images.agentRuntime.providerImages." + p})
	}
	return out
}

// configuredRef is a configured image as the installer resolves it, or "" when unset.
func configuredRef(registry, ref string) string {
	if ref = strings.TrimSpace(ref); ref == "" || ref == "null" {
		return ""
	}
	return buildImageURL(registry, ref)
}

// envSegment is the operator's normalizeEnvKeySegment: the version or provider part of
// a RELATED_IMAGE_* name. Two keys with the same segment select the same variable.
func envSegment(v string) string {
	var b strings.Builder
	last := false
	for _, r := range strings.ToUpper(v) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			last = false
		} else if !last {
			b.WriteByte('_')
			last = true
		}
	}
	return strings.Trim(b.String(), "_")
}

// baseVersionComponent names the component of a pinned base: agent-runtime-base-v2-0-0.
func baseVersionComponent(version string) string {
	return "agent-runtime-base-" + strings.ToLower(strings.ReplaceAll(envSegment(version), "_", "-"))
}

func (in InventoryInput) isCandidateRuntimeVersion(v string) bool {
	return in.Candidate != nil && in.Candidate.Spec.RuntimeVersion != "" && envSegment(v) == envSegment(in.Candidate.Spec.RuntimeVersion)
}

func (in InventoryInput) isCandidateProvider(p string) bool {
	if in.Candidate == nil {
		return false
	}
	c, ok := in.Candidate.Spec.Components["launchpadCarrier"]
	return ok && strings.TrimSpace(c.Image) != "" && envSegment(c.Provider) == envSegment(p)
}

func (inv *Inventory) computeChecksum() (string, error) {
	b, err := json.Marshal(struct {
		Candidate CandidateRef `json:"candidate"`
		Images    []Image      `json:"images"`
	}{inv.Candidate, inv.Images})
	if err != nil {
		return "", err
	}
	return Checksum(b), nil
}

// ForProfile returns the images a profile installs.
func (inv *Inventory) ForProfile(profile string) []Image {
	var out []Image
	for _, i := range inv.Images {
		for _, p := range i.Profiles {
			if p == profile {
				out = append(out, i)
				break
			}
		}
	}
	return out
}

// componentEnabled reads a rendered component flag, falling back to the profile's
// own defaults when no rendered values were supplied: the model-serving components
// are off for cpuOnly and everything else is on.
func componentEnabled(v *RenderedValues, profile, name string) bool {
	if v != nil && v.Components != nil {
		if on, ok := v.Components[name]; ok {
			return on
		}
	}
	if profile == ProfileCPUOnly && (name == "kuberay" || name == "nvidia") {
		return false
	}
	return true
}

type addonRule struct {
	re        *regexp.Regexp
	component string
	profiles  []string
	gate      string
}

// addonRules attribute an add-on image to the component that brings it and to the
// profiles that run that component. The first matching rule wins.
var addonRules = []addonRule{
	{regexp.MustCompile(`(^|/)cert-manager`), "cert-manager", bothProfiles, "certManager"},
	{regexp.MustCompile(`(^|/)jetstack/`), "cert-manager", bothProfiles, "certManager"},
	{regexp.MustCompile(`(^|/)kuberay/`), "kuberay-operator", fullOnly, "kuberay"},
	{regexp.MustCompile(`(^|/)nvidia/`), "nvidia-device-plugin", fullOnly, "nvidia"},
	{regexp.MustCompile(`(^|/)metallb/|frrouting/`), "metallb", bothProfiles, "metallb"},
	{regexp.MustCompile(`opentelemetry-collector`), "otel-collector", bothProfiles, "otel"},
	{regexp.MustCompile(`local-path-provisioner|(^|/)busybox(:|$)`), "local-path-provisioner", bothProfiles, ""},
	{regexp.MustCompile(`prometheus|alertmanager|grafana|kube-state-metrics|node-exporter|kube-webhook-certgen|configmap-reload|thanos|k8s-sidecar`), "monitoring-stack", bothProfiles, "monitoring"},
}

func classifyAddon(ref string) (component string, profiles []string, gate string) {
	for _, r := range addonRules {
		if r.re.MatchString(ref) {
			return r.component, r.profiles, r.gate
		}
	}
	return "addon-" + imageBaseName(ref), bothProfiles, ""
}

var nonName = regexp.MustCompile(`[^a-z0-9]+`)

// imageBaseName returns a component-safe name for a reference: its last path
// element without the tag or digest.
func imageBaseName(ref string) string {
	ref = strings.SplitN(ref, "@", 2)[0]
	base := path.Base(ref)
	base = strings.SplitN(base, ":", 2)[0]
	return strings.Trim(nonName.ReplaceAllString(strings.ToLower(base), "-"), "-")
}

// sourceOwner turns a candidate manifest source repository URL into an owner name.
func sourceOwner(repository string) string {
	repository = strings.TrimSpace(repository)
	if repository == "" {
		return ""
	}
	repository = strings.TrimSuffix(strings.TrimSuffix(repository, "/"), ".git")
	if i := strings.Index(repository, "://"); i >= 0 {
		repository = repository[i+3:]
	}
	if i := strings.Index(repository, "/"); i >= 0 {
		return repository[i+1:] // drop the host: "ai/ai-agent-runtime"
	}
	return repository
}

// dedupe merges repeated entries for the same component and source, keeping the union
// of their profiles: the same image listed twice, or listed by two sources with different
// gating, is needed by every profile that either one names.
func dedupe(images []Image) []Image {
	var out []Image
	for i, im := range images {
		if i > 0 && im.Component == images[i-1].Component && im.Source == images[i-1].Source {
			last := &out[len(out)-1]
			last.Profiles = unionProfiles(last.Profiles, im.Profiles)
			continue
		}
		out = append(out, im)
	}
	return out
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
