package v1

import (
	"maps"
	"net/netip"
	"slices"

	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

// AgentRuntimeNetworkPolicy declares the peers needed by the runtime and its schema Job.
type AgentRuntimeNetworkPolicy struct {
	// DNS selects the pods handling DNS on UDP and TCP port 53.
	DNS AgentRuntimeNetworkPeer `json:"dns"`
	// PostgreSQL is the checkpoint database used by the runtime and schema Job.
	PostgreSQL AgentRuntimeNetworkDestination `json:"postgresql"`
	// SLIM selects the caller on the runtime application port. A platform-managed
	// runtime can omit this field to allow its sibling SLIM feature.
	SLIM *AgentRuntimeNetworkPeer `json:"slim,omitempty"`
	// Metrics selects the scraper on the runtime metrics port.
	Metrics *AgentRuntimeNetworkPeer `json:"metrics,omitempty"`
	// RuntimeEgress lists additional TCP destinations, such as model and MCP backends.
	RuntimeEgress []AgentRuntimeNetworkDestination `json:"runtimeEgress,omitempty"`
}

// AgentRuntimeNetworkPeer selects pods by exact labels or an explicit private CIDR.
type AgentRuntimeNetworkPeer struct {
	// Namespace selects one named namespace. If omitted, pod labels select within
	// the runtime namespace.
	Namespace string `json:"namespace,omitempty"`
	// PodSelector contains the labels a peer pod must match.
	PodSelector map[string]string `json:"podSelector,omitempty"`
	// CIDR is a canonical IPv4 private-use or IPv6 unique-local prefix.
	CIDR string `json:"cidr,omitempty"`
}

// AgentRuntimeNetworkDestination allows one TCP port on the specified peer.
type AgentRuntimeNetworkDestination struct {
	Peer AgentRuntimeNetworkPeer `json:"peer"`
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=65535
	Port int32 `json:"port"`
}

// Validate rejects rules that would grant access without a specific peer or port.
func (p *AgentRuntimeNetworkPolicy) Validate(path *field.Path, requireSLIM bool) field.ErrorList {
	if p == nil {
		return field.ErrorList{field.Required(path, "must declare the AgentRuntime network peers")}
	}

	errs := p.DNS.validate(path.Child("dns"), false)
	errs = append(errs, p.PostgreSQL.validate(path.Child("postgresql"))...)
	if p.SLIM != nil {
		errs = append(errs, p.SLIM.validate(path.Child("slim"), false)...)
	} else if requireSLIM {
		errs = append(errs, field.Required(path.Child("slim"), "must select the SLIM caller for a standalone AgentRuntime"))
	}
	if p.Metrics != nil {
		errs = append(errs, p.Metrics.validate(path.Child("metrics"), false)...)
	}
	for i, dest := range p.RuntimeEgress {
		errs = append(errs, dest.validate(path.Child("runtimeEgress").Index(i))...)
	}
	return errs
}

func (d AgentRuntimeNetworkDestination) validate(path *field.Path) field.ErrorList {
	errs := d.Peer.validate(path.Child("peer"), true)
	if d.Port < 1 || d.Port > 65535 {
		errs = append(errs, field.Invalid(path.Child("port"), d.Port, "must be between 1 and 65535"))
	}
	return errs
}

func (p AgentRuntimeNetworkPeer) validate(path *field.Path, allowCIDR bool) field.ErrorList {
	var errs field.ErrorList
	if p.CIDR != "" {
		if !allowCIDR {
			errs = append(errs, field.Forbidden(path.Child("cidr"), "must select pods by label"))
		} else if !isPrivateNetworkPrefix(p.CIDR) {
			errs = append(errs, field.Invalid(path.Child("cidr"), p.CIDR, "must be a canonical CIDR wholly within an IPv4 private-use or IPv6 unique-local range"))
		}
		if p.Namespace != "" || len(p.PodSelector) > 0 {
			errs = append(errs, field.Forbidden(path.Child("cidr"), "cannot be combined with a pod selector or namespace"))
		}
		return errs
	}

	if len(p.PodSelector) == 0 {
		errs = append(errs, field.Required(path.Child("podSelector"), "must select pods by at least one label"))
	}
	if p.Namespace != "" {
		for _, msg := range validation.IsDNS1123Label(p.Namespace) {
			errs = append(errs, field.Invalid(path.Child("namespace"), p.Namespace, msg))
		}
	}
	for _, key := range slices.Sorted(maps.Keys(p.PodSelector)) {
		value := p.PodSelector[key]
		for _, msg := range validation.IsQualifiedName(key) {
			errs = append(errs, field.Invalid(path.Child("podSelector"), key, msg))
		}
		for _, msg := range validation.IsValidLabelValue(value) {
			errs = append(errs, field.Invalid(path.Child("podSelector").Key(key), value, msg))
		}
	}
	return errs
}

var privateNetworkRanges = [...]netip.Prefix{
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("fc00::/7"),
}

func isPrivateNetworkPrefix(value string) bool {
	prefix, err := netip.ParsePrefix(value)
	if err != nil || prefix != prefix.Masked() {
		return false
	}
	// The prefix length must also fit inside the private range. Checking only
	// the address would accept a network that includes public addresses.
	for _, private := range privateNetworkRanges {
		if prefix.Bits() >= private.Bits() && private.Contains(prefix.Addr()) {
			return true
		}
	}
	return false
}
