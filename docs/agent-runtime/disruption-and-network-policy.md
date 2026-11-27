# AgentRuntime disruption and network policy

Each AgentRuntime AIService owns a `policy/v1` PodDisruptionBudget and two
`networking.k8s.io/v1` NetworkPolicies. The policy selects only its runtime pods
or its schema Job pods. Kubernetes garbage collection removes these resources
with the AIService. Read [resource ownership](ownership-and-deletion.md) for
same-name conflict behavior.

## Voluntary disruptions

The budget allows one unavailable runtime replica. Kubernetes calculates the
budget from the Deployment's current scale, including HPA changes. At one Ready
replica, eviction can briefly interrupt service. At two or more Ready replicas,
one eviction is permitted. A further eviction can be refused until capacity is
restored. Use the Eviction API for maintenance that should honor the budget.

## Allowed flows

| Source | Destination | Port | Condition |
| --- | --- | --- | --- |
| Managed sibling SLIM or pods selected by `slim` | Runtime pods | TCP 8080 | The internal route uses the existing Runtime Service and transport contract. A standalone runtime declares its SLIM source explicitly. |
| Pods selected by `metrics` | Runtime pods | TCP 9090 | Applies when metrics are enabled and a scraper is declared. |
| Node kubelet | Runtime pod `/health` | TCP 8080 | The probes use the node-to-local-pod path allowed by Kubernetes. |
| Runtime and schema Job pods | Pods selected by `dns` | UDP and TCP 53 | Select the cluster's actual DNS pods. |
| Runtime and schema Job pods | Peer selected by `postgresql` | TCP, configured port | Match the checkpoint database endpoint and port in the existing Secret. TLS continues to use the database client's configured trust. |
| Runtime pods | Peers listed under `runtimeEgress` | TCP, configured ports | Declare model, MCP, vector or other endpoints used by this runtime. The application clients still verify TLS and certificates where configured. |

Other pod traffic is denied by these policies. Kubernetes combines all policies
that select a pod, so review overlapping rules in the workload namespaces to
establish effective isolation. The cluster network plugin must enforce
NetworkPolicy. Each cross-namespace pod peer combines an exact namespace name
with pod labels. Keep labels specific to the approved workload. A private
CIDR can identify a peer for PostgreSQL or `runtimeEgress`. Use a canonical CIDR
in RFC 1918 or IPv6 unique-local space, with the narrowest stable prefix. A
hostname in application configuration does not add an allow rule.

## Configure and upgrade

Supply `networkPolicy` on the AgentRuntime entry in `AIPlatform.spec.features` or
on `AIService.spec.features` for a standalone runtime. The k0s installer and the
AIPlatform Helm chart carry the feature setting into the API object. This
example shows the required fields plus two optional peers. Replace its labels,
namespace and addresses with those of the approved endpoints.

```yaml
networkPolicy:
  dns:
    namespace: kube-system
    podSelector:
      k8s-app: kube-dns
  postgresql:
    peer:
      namespace: checkpoint-system
      podSelector:
        app: agent-checkpoint-postgres
    port: 5432
  metrics:
    namespace: monitoring
    podSelector:
      app: prometheus
  runtimeEgress:
    - peer:
        cidr: 10.40.12.17/32
      port: 443
```

1. With the prior operator running, apply only the two updated CRD schemas from
   `config/crd/bases` or the matching Helm `crds` directory. Wait for the API to
   serve the fields so Kubernetes can persist them.
2. Save and read back valid allowlists on every existing AgentRuntime feature
   in its AIPlatform and on every standalone AgentRuntime AIService. Use the
   AIPlatform as the source for its generated children. Include matching values
   in the installer or Helm configuration that manages those resources.
3. Upgrade the operator and its permissions. The k0s installer checks the stored
   allowlists before applying the operator upgrade. For a direct Helm or
   manifest upgrade, complete the same check before rolling the operator.
4. Verify the two managed policies and budget, completed schema setup, runtime
   readiness, and the expected connections. A missing or invalid allowlist on
   an older resource yields `InvalidNetworkPolicy` and deny-only managed rules
   until valid input is supplied. A temporary read failure leaves the current
   rules applied while reconciliation retries.

Apply updates to the feature configuration to add or remove permitted flows.
The operator replaces the owned policy specifications with the declared rules.
Existing connections can behave differently between network plugins after a
rule changes, so verify the change with a fresh connection.
