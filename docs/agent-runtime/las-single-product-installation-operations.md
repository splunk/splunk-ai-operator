# LAS single-product installation and operations

This guide is the customer and operator entry point for deploying LangGraph
Agent Server (LAS) with SLIM as the Splunk AI Tier. It covers connected and
air-gapped k0s installations, the `full` and `cpuOnly` product profiles, and
routine operations after installation.

Use only image tags or digests, chart archives, and license material approved
for the release being installed. Never commit a populated deployment config,
registry credential, license key, PostgreSQL URI, Redis URI, LLM credential, or
MCP credential to this repository.

## Choose a deployment profile

`aiPlatform.profile` is independent of `cluster.airgap`. Choose one profile and
one network mode:

| Profile | Workloads and prerequisites | Typical use |
| --- | --- | --- |
| `full` (also the default when omitted) | LAS, SLIM, SAIA, KubeRay, model serving, GPU workers, model artifacts, and their telemetry dependencies | Splunk-hosted models and the complete AI Platform |
| `cpuOnly` | LAS and SLIM on CPU nodes; no SAIA, KubeRay, hosted models, model staging, or GPU requirement | Bring-your-own LLM, MCP tools, and knowledge bases |

A `cpuOnly` configuration must explicitly disable model and GPU components.
The installer and admission webhook reject mixed-profile settings. Converting a
running deployment between profiles is not supported; install a new
`AIPlatform` with the other profile.

Minimal connected `cpuOnly` shape:

```yaml
cluster:
  airgap: false
nodes:
  gpuWorkers: 0
storage:
  modelStaging:
    enabled: false
components:
  kuberay: false
  nvidia: false
aiPlatform:
  name: product-ai-tier
  profile: cpuOnly
  sidecars:
    envoy: false
    otel: false
    prometheusOperator: false
  features:
    - name: slim
    - name: agentruntime
      provider: mltk
      las:
        image:
          repository: registry.example.com/approved/agent-server
          tag: RELEASE_TAG
        assistantId: APPROVED_GRAPH_ID
        credentials:
          licenseKey: REPLACE_IN_PRIVATE_CONFIG
          postgresUri: postgresql://REPLACE_IN_PRIVATE_CONFIG
          redisUri: redis://REPLACE_IN_PRIVATE_CONFIG
        tracing:
          enabled: false
        queue:
          autoscaling:
            enabled: true
            minReplicas: 1
            maxReplicas: 3
            targetCPUUtilizationPercentage: 80
```

For `full`, omit `profile` or set it to `full`, configure GPU workers and model
staging, and enable the full-profile components described in
[the k0s deployment guide](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md).

## Responsibilities and prerequisites

Splunk supplies the operator, its embedded LAS chart, supported schema,
installer tooling, and release qualification evidence. The customer/operator
supplies and operates:

- supported controller, CPU, and (for `full`) GPU nodes;
- a reachable container registry and immutable approved image identities;
- PostgreSQL and Redis endpoints with capacity, backup, availability, and TLS
  appropriate for the environment;
- the LAS license and any approved LLM, MCP, knowledge-base, or tracing service;
- DNS, certificates, trust roots, firewalls, proxies, routes, Kubernetes network
  enforcement, and Splunk-side ingress controls;
- secure storage and rotation of all deployment and per-run credentials; and
- retention, backup, restore, and deletion policy for application data.

Before installation, verify SSH access to every node, required disk space,
registry access, endpoint connectivity, and a supported Kubernetes/network
plugin. Queue autoscaling requires the Kubernetes resource metrics API. The
installer can deploy LAS without it, but the queue HPA cannot scale until
metrics-server is available.

## Prepare the deployment configuration

Copy a shipped sample outside the repository and restrict its filesystem
permissions before adding credentials. Use
[`k0s-cluster-config-airgap-slim-las.yaml`](../../tools/cluster_setup/k0s-cluster-config-airgap-slim-las.yaml)
for an air-gapped `cpuOnly` starting point. Validate before changing the
cluster:

```bash
chmod 600 /secure/path/product-ai-tier.yaml
CONFIG_FILE=/secure/path/product-ai-tier.yaml \
  tools/cluster_setup/k0s_cluster_with_stack.sh validate
```

The installer reads `las.credentials`, validates the three required values,
and creates or updates owned Kubernetes Secrets. The resulting `AIPlatform`
contains only `licenseSecretRef`, `postgresSecretRef`, and `redisSecretRef`.
Do not manually copy credentials into the `AIPlatform` or edit the generated
Secret objects. To rotate a value, change the protected source configuration
and rerun `install`; unchanged Secrets are left untouched and changed values
are reconciled before the `AIPlatform` is applied. The installer refuses to
take over a same-named Secret that it does not own.

The generated Secrets use these keys:

- `langgraph_cloud_license_key`
- `postgres_connection_url`
- `redis_connection_url`

An optional connected-mode `langsmithApiKey` is managed the same way. Removing
it from the protected config removes that optional Secret key. Air-gapped mode
does not use a public LangSmith API key and rejects enabled tracing unless an
approved internal endpoint is supported by the release.

## Configure network paths

### LAS egress

`cluster.airgap: true` selects LAS `networkMode: airgapped`; it does not create
an egress deny policy by itself. `cluster.egress.allowedIPs` controls the
installer-managed policy for LAS API and queue Pods:

```yaml
cluster:
  airgap: true
  egress:
    allowedIPs:
      - 10.20.30.40       # external PostgreSQL host
      - 10.20.30.41/32    # external Redis host
      - 10.20.31.0/24     # approved MCP or BYOLLM destination range
```

Entries must be literal IP addresses or CIDRs; DNS names and catch-all routes
are rejected. A plain IP is normalized to a host CIDR. An empty list permits
only the in-cluster baseline and cluster DNS. Omitting `allowedIPs` removes the
policy managed by this deployment and preserves unrestricted legacy behavior.
List every off-cluster PostgreSQL, Redis, MCP, BYOLLM, knowledge-base, or
internal tracing destination. Kubernetes Service/Pod traffic and cluster DNS
are handled by the internal baseline; customer firewalls and external network
policies remain the customer's responsibility.

### Splunk-stack MCP ingress

For an MCP listener hosted with the Splunk stack, determine the effective AI
Tier source IP or CIDR after routing and NAT. Permit that source only on the
approved listener address and port, and configure the product-approved TLS and
authentication mechanism. Do not expose the listener broadly merely because
LAS and Splunk share a cluster.

Verify the route from an LAS Pod or an equivalent Pod subject to the same
policy. First prove DNS and TCP/TLS connectivity, then make a minimally
privileged MCP request. A TCP timeout normally indicates routing, firewall, or
NetworkPolicy enforcement; a TLS failure indicates certificates, hostname, or
trust roots; HTTP `401`/`403` indicates authentication or authorization. Do not
print tokens in diagnostic output.

## Connected installation

Run from the installer machine after validation:

```bash
CONFIG_FILE=/secure/path/product-ai-tier.yaml \
  tools/cluster_setup/k0s_cluster_with_stack.sh install
```

The operator reconciles the `AIPlatform`, creates the per-feature `AIService`,
and the LAS controller owns the Helm release for the API, queue worker,
Service, ConfigMaps, ServiceAccount, schema Job, HPA, and monitoring resources.
A change to typed LAS configuration causes reconciliation and, when rendered
values change, a Helm upgrade.

## Air-gapped installation

Build the bundle on a connected machine from the exact `cpuOnly` air-gap
configuration. `--config` selects the profile-specific bundle; there is no
`--platform` option. Pin k0s and PyYAML so the artifact set is reproducible:

```bash
PYYAML_VERSION=6.0.2 \
  tools/cluster_setup/prepare_airgap_bundle.sh \
    --config /secure/path/product-ai-tier.yaml \
    --k0s-version v1.31.2+k0s.0 \
    --mirror-registry registry.internal.example.com \
    --output-dir /mnt/transfer
```

The bundle records image manifests/digests, the embedded LAS chart archive,
installer sources, and SHA-256 checksums. Registry authentication is read from
the build machine and is not copied into the bundle. Mirror every inventory
entry to the approved internal registry, transfer the tarball through the
approved channel, and verify its external checksum before installation.

On the disconnected installer machine:

```bash
tools/cluster_setup/install_from_airgap_bundle.sh \
  --bundle /opt/splunk-ai/airgap-bundle-TIMESTAMP.tar.gz \
  --config /secure/path/product-ai-tier.yaml
```

The installer verifies the bundle checksum, image closure, inventory, archive
mapping, and embedded chart hash before cluster work. A profile-specific
`cpuOnly` bundle uses staged artifacts and provides no public image/chart
fallback. Configure internal registry CA trust on the installer and every node;
use `images.registryInsecure: true` only for an explicitly approved plain-HTTP
test registry. For a `full` air-gapped deployment, also stage the model
artifacts and the supported GPU driver/toolkit RPM closure described in
[K0S_README](../../tools/cluster_setup/K0S_README.md#air-gapped-deployment).

Offline license renewal is a credential rotation: obtain approved replacement
license material through the supported offline process, update the protected
deployment config, rerun the same bundle installer, and verify both API and
queue Pods become ready without public access. A license qualification applies
only to the release image it names; requalify a different runtime image.

## Verify the installation

```bash
export KUBECONFIG=~/.kube/k0s-CLUSTER_NAME

kubectl get nodes
kubectl get aiplatform,aiservice -A
kubectl get pods,svc,job,hpa -n ai-platform
kubectl get networkpolicy -n ai-platform
kubectl get events -n ai-platform --sort-by=.lastTimestamp
```

All selected nodes must be `Ready`; the `AIPlatform`, SLIM `AIService`, and
AgentRuntime `AIService` must report `Ready=True`; LAS API and queue Pods must
be ready; and the schema Job must have completed. If queue autoscaling is
enabled, confirm the HPA has current CPU metrics and respects its configured
bounds. Run the approved caller-route canary for LLM, MCP, and knowledge-base
configuration without logging secrets. In an air-gapped environment, repeat a
cold start or replacement-Pod pull with public egress disabled and record the
observed immutable image digest.

The qualification procedures and evidence format are documented in
[`launchpad-product-qualification.md`](launchpad-product-qualification.md).
Passing a synthetic canary does not qualify an untested external dependency or
prove that a firewall enforces the intended policy.

## Lifecycle operations

### Upgrade or change configuration

Back up PostgreSQL and any customer-managed state, update the protected config
with approved immutable artifact identities, validate it, and rerun `install`.
For an air-gapped upgrade, prepare and transfer a new complete bundle and run:

```bash
tools/cluster_setup/install_from_airgap_bundle.sh \
  --bundle /opt/splunk-ai/airgap-bundle-NEW.tar.gz \
  --config /secure/path/product-ai-tier.yaml \
  --subcommand upgrade
```

Observe the operator, Helm release, schema Job, rollout, caller-route canary,
and persisted-thread check. Do not use `clean-all` for an upgrade; it is a
destructive cluster reset.

### Queue scaling

The LAS API remains a fixed single replica in this release. Queue autoscaling
defaults to enabled with one to three replicas and an 80% CPU target. Set CPU
requests because HPA utilization is calculated relative to the request. During
a load test, observe `kubectl get hpa -n ai-platform -w`, queued run completion,
scale-up, and return to `minReplicas`. Disabling autoscaling produces one fixed
queue worker.

### Data retention, backup, and deletion

PostgreSQL holds durable LAS thread/checkpoint/run state; Redis is transient
queue coordination and is not the system of record. Deleting a Pod, Deployment,
or Helm release does not by itself delete PostgreSQL data or installer-managed
credential Secrets. Deleting a thread through the supported API may remove its
application-visible state, but customer database backup and retention can keep
older copies. Align API deletion, database backup expiry, audit retention, and
external LLM/MCP provider retention with customer policy.

Back up and test restore of PostgreSQL independently of the Kubernetes
workloads. Preserve the protected deployment config and immutable artifact
inventory in an approved secrets/configuration system. Do not include Secret
values or caller context in support bundles.

### Telemetry

Enable only approved internal telemetry destinations. `cpuOnly` configurations
must keep the full-profile OTel and Prometheus sidecars disabled. LAS tracing is
off by default; air-gapped deployments must keep it off unless the selected
release explicitly supports an internal endpoint. Network policy and firewall
rules must include any enabled internal telemetry endpoint. Inspect telemetry
for credential or caller-context leakage before production use.

## Troubleshooting and support boundaries

Start with configuration validation and resource conditions rather than Secret
contents:

```bash
CONFIG_FILE=/secure/path/product-ai-tier.yaml \
  tools/cluster_setup/k0s_cluster_with_stack.sh validate

kubectl describe aiplatform -n ai-platform PLATFORM_NAME
kubectl get aiservice -n ai-platform -o wide
kubectl get pods -n ai-platform -o wide
kubectl describe hpa -n ai-platform
kubectl logs -n splunk-ai-operator-system \
  deploy/splunk-ai-operator-controller-manager --since=15m

CONFIG_FILE=/secure/path/product-ai-tier.yaml \
  tools/cluster_setup/k0s_cluster_with_stack.sh diagnose
```

The diagnostic bundle redacts known deployment credentials, but review it
under customer policy before sharing. Do not run commands that decode Secrets
for routine diagnosis.

Common ownership boundaries:

- `ImagePullBackOff`: verify the approved image exists, node trust, registry
  credentials, mirror closure, and the digest recorded during preparation.
- LAS cannot reach PostgreSQL/Redis/MCP/BYOLLM: verify destination IP/CIDR,
  DNS, route, firewall, NetworkPolicy, listener, TLS trust, and authorization.
- HPA shows unknown metrics: restore metrics-server/resource metrics and check
  queue CPU requests.
- `AIService` is blocked: read its named dependency condition; SLIM waits for
  AgentRuntime in both profiles and for model serving only in `full`.
- Air-gapped Pod tries a public pull: the bundle/mirror closure or configured
  image reference is incomplete; do not temporarily open public egress and
  claim offline qualification.

The operator does not operate customer PostgreSQL, Redis, registry, LLM, MCP,
knowledge-base, firewall, or backup infrastructure. Evidence from a particular
release, graph, dependency set, and network mode does not automatically qualify
a different combination.

## Related references

- [Installation guide](../installation.md)
- [k0s deployment guide](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md)
- [k0s air-gapped reference](../../tools/cluster_setup/K0S_README.md#air-gapped-deployment)
- [CPU-only offline artifact bundle](../../tools/cluster_setup/AI_TIER_AIRGAP.md)
- [Launchpad qualification runbook](launchpad-product-qualification.md)
- [LAS runtime qualification](las-runtime-qualification.md)

