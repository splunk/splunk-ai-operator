package v1

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

func TestAgentRuntimeNetworkPolicyValidation(t *testing.T) {
	path := field.NewPath("spec", "features", "networkPolicy")
	var missing *AgentRuntimeNetworkPolicy
	require.ErrorContains(t, missing.Validate(path, true).ToAggregate(), "spec.features.networkPolicy")

	valid := AgentRuntimeNetworkPolicy{
		DNS: AgentRuntimeNetworkPeer{Namespace: "kube-system", PodSelector: map[string]string{"k8s-app": "kube-dns"}},
		PostgreSQL: AgentRuntimeNetworkDestination{
			Peer: AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "postgres"}},
			Port: 5432,
		},
		SLIM:    &AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "slim"}},
		Metrics: &AgentRuntimeNetworkPeer{Namespace: "monitoring", PodSelector: map[string]string{"app": "prometheus"}},
		RuntimeEgress: []AgentRuntimeNetworkDestination{
			{Peer: AgentRuntimeNetworkPeer{CIDR: "192.168.17.32/27"}, Port: 443},
			{Peer: AgentRuntimeNetworkPeer{CIDR: "fd00:1234::/64"}, Port: 443},
		},
	}
	require.Empty(t, valid.Validate(path, true))
	valid.SLIM = nil
	require.Empty(t, valid.Validate(path, false))
	require.ErrorContains(t, valid.Validate(path, true).ToAggregate(), "networkPolicy.slim")

	valid.DNS = AgentRuntimeNetworkPeer{Namespace: "kube-system"}
	valid.PostgreSQL.Peer.CIDR = "10.0.0.0/8"
	valid.PostgreSQL.Port = 0
	valid.Metrics = &AgentRuntimeNetworkPeer{CIDR: "10.11.12.13/32"}
	valid.RuntimeEgress[0].Peer.CIDR = "192.168.0.0/15"
	err := valid.Validate(path, false).ToAggregate()
	require.Error(t, err)
	for _, fieldName := range []string{
		"dns.podSelector", "postgresql.peer.cidr", "postgresql.port", "metrics.cidr", "runtimeEgress[0].peer.cidr",
	} {
		assert.ErrorContains(t, err, "networkPolicy."+fieldName)
	}
}

func TestAgentRuntimeMetricsPolicyValidation(t *testing.T) {
	path := field.NewPath("spec", "features", "networkPolicy")
	policy := &AgentRuntimeNetworkPolicy{
		DNS:        AgentRuntimeNetworkPeer{PodSelector: map[string]string{"k8s-app": "kube-dns"}},
		PostgreSQL: AgentRuntimeNetworkDestination{Peer: AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "postgres"}}, Port: 5432},
	}
	require.ErrorContains(t, policy.ValidateMetrics(path, true).ToAggregate(), "networkPolicy.metrics")
	require.Empty(t, policy.ValidateMetrics(path, false))

	policy.MetricsDisabled = true
	require.Empty(t, policy.Validate(path, false))
	require.Empty(t, policy.ValidateMetrics(path, true))

	policy.Metrics = &AgentRuntimeNetworkPeer{PodSelector: map[string]string{"app": "prometheus"}}
	require.ErrorContains(t, policy.Validate(path, false).ToAggregate(), "cannot be combined with metricsDisabled")
	policy.MetricsDisabled = false
	require.Empty(t, policy.Validate(path, false))
	require.Empty(t, policy.ValidateMetrics(path, true))
}

func TestIsPrivateNetworkPrefix(t *testing.T) {
	for _, prefix := range []string{"10.0.0.0/8", "172.16.1.5/32", "192.168.0.0/16", "fd00:abcd::/64"} {
		assert.True(t, isPrivateNetworkPrefix(prefix), prefix)
	}
	for _, prefix := range []string{
		"0.0.0.0/0", "::/0", "10.0.0.0/7", "172.16.0.0/11", "192.168.0.0/15",
		"10.1.2.3/24", "fd00:abcd::1/64", "fc00::/6", "8.8.8.8/32", "fe80::/64", "bad",
	} {
		assert.False(t, isPrivateNetworkPrefix(prefix), prefix)
	}
}
