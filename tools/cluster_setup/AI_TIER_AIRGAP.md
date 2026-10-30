# AI Tier CPU-only air-gap bundle and qualification

This runbook builds the exact CPU-only AI Tier artifact set on a connected
staging host, installs it with public egress unavailable, and captures the
sanitized runtime evidence required to qualify LAS. A successful local build or
unit test is not air-gap evidence; the final steps must run against a fresh,
isolated cluster.

Keep the completed deployment config, licenses, dependency connection material,
registry authentication, SSH keys, private topology, and raw diagnostic output
outside Git and Jira. Use placeholders in committed examples.

## 1. Prepare a reviewed source and config

Use a clean checkout or `git archive` export of the reviewed
`agent-runtime/ai-tier` commit. Record the 40-character commit, but do not build
a release bundle from an unrelated or dirty worktree. The builder rejects all
tracked and untracked changes when Git metadata is available. A clean export is
useful for containerized builds where linked-worktree Git paths are unavailable;
pass its externally verified commit through `SOURCE_COMMIT`.

Create the completed config in a protected location outside the repository. It
must select:

- `cluster.airgap: true`;
- `aiPlatform.profile: cpuOnly`;
- at least one controller and CPU worker, with zero GPU workers;
- disabled model staging, KubeRay, and NVIDIA components;
- exactly the intended product and LAS image references;
- Kubernetes Secret references rather than inline credentials;
- private object-store and dependency endpoints.

`tools/cluster_setup/k0s-cluster-config-airgap-slim-las.yaml` is a nonsecret
template. Do not commit its populated copy.

## 2. Build and pin the bundle on a connected host

The staging host needs authenticated access to every selected registry and the
tools listed by `prepare_airgap_bundle.sh --help`. Skopeo reads its normal local
auth store; registry auth files are not copied into the bundle.

```sh
SOURCE_COMMIT="$(git rev-parse HEAD)" \
PYYAML_VERSION=6.0.2 \
tools/cluster_setup/prepare_airgap_bundle.sh \
  --config /protected/path/completed-cpu-airgap-config.yaml \
  --k0s-version <approved-k0s-version> \
  --output-dir /protected/path/transfer
```

Add `--mirror-registry <approved-private-registry>` only when that mirror has
already been populated and independently verified. The option records mapping
metadata; it does not copy images into the mirror.

The builder creates a timestamped tarball containing:

- k0s system, installer add-on, and configured workload OCI archives;
- `image-inventory.json`, with source references, immutable manifest digests,
  platforms, archive mappings, and optional internal mirror references;
- the exact LAS chart embedded by this operator revision and its SHA-256;
- `source-commit.txt`, containing the reviewed source commit;
- the version-matched installer and manifests;
- `checksums.sha256`, covering the staged files.

Record these nonsecret identities before transfer:

```sh
git rev-parse HEAD
sha256sum /protected/path/transfer/airgap-bundle-*.tar.gz
```

Retain the builder's sanitized output, tarball SHA-256, bundle inventory, and
chart digest. An inventory `mirrorReference` alone does not prove that a mirror
contains the image; record the OCI archive actually imported or separately
verify the approved private mirror.

## 3. Establish and record isolation

Use a fresh or explicitly approved shared qualification environment. Before the
install, capture read-only evidence that:

- cluster and installer instances have private addresses only;
- their subnets have no Internet-gateway or NAT default route;
- security-group egress is limited to approved private CIDRs/endpoints;
- required private registry, object-store, PostgreSQL, Redis, DNS, and SSH paths
  remain reachable;
- the topology contains no GPU worker.

The existing CPU air-gap environment enforces isolation at VPC route and
security-group boundaries. Do not claim Kubernetes NetworkPolicy enforcement
when no effective policy is installed. Public DNS resolution is not proof of
public TCP reachability.

Store account, VPC, subnet, instance, endpoint, and address details only in the
protected cluster record. Give the runtime validator a sanitized network
evidence JSON file with this shape:

```json
{
  "schemaVersion": 1,
  "capturedAt": "<RFC3339 timestamp>",
  "source": "<opaque-capture-id-with-no-environment-identifiers>",
  "instances": [
    {"role": "installer", "privateAddress": true, "publicAddress": false},
    {"role": "controller", "privateAddress": true, "publicAddress": false},
    {"role": "cpu-worker", "privateAddress": true, "publicAddress": false}
  ],
  "routes": [
    {"destination": "<bounded private CIDR>", "targetType": "local", "public": false},
    {"destination": "<private prefix list>", "targetType": "vpc-endpoint", "public": false}
  ],
  "securityGroupEgress": [
    {"destination": "<bounded private CIDR or prefix list>", "public": false}
  ],
  "internetGatewayDefaultRoute": false,
  "natGatewayDefaultRoute": false,
  "privateDependencyReachability": {
    "registry": true,
    "objectStore": true,
    "postgres": true,
    "redis": true,
    "dns": true,
    "ssh": true
  },
  "publicTcpReachable": false
}
```

Do not include private identifiers or credentials. Capture this input within the
validator's default age window and retain the raw AWS commands only in the
protected record. The shareable output retains route/egress classes rather than
CIDRs or prefix-list identifiers. The validator rejects public
addresses, cluster-subnet routes through Internet/NAT gateways, and unbounded
`0.0.0.0/0` or `::/0` security-group destinations. An Internet or NAT gateway
existing elsewhere in the VPC is not itself a failure when the qualification
subnet has no route to it.

Access the installer through the approved private transport with a
developer-owned authorized SSH key and strict host-key checking. Use its
cluster-specific kubeconfig. A tunnel establishes a network path; it does not
replace SSH authorization or host verification.

## 4. Transfer and validate without installing

Transfer the tarball and protected config through the approved boundary. Verify
the tarball SHA-256 again on the isolated installer.

Run the wrapper's validation-only mode first. Use a protected extraction
directory; validation extracts files but exits before installing host binaries,
registering Helm repositories, or invoking Kubernetes/SSH installer actions.

```sh
tools/cluster_setup/install_from_airgap_bundle.sh \
  --bundle /protected/path/airgap-bundle-<timestamp>.tar.gz \
  --expected-bundle-sha256 <sha256-recorded-before-transfer> \
  --config /protected/path/completed-cpu-airgap-config.yaml \
  --extract-dir /protected/path/preflight \
  --validate-only
```

Validation checks the checksum manifest, CPU profile and config, exact workload
closure, source commit, external tarball identity, OCI archives and references,
version-matched installer, image
inventory, and embedded LAS chart digest. It does not add a public fallback.

## 5. Capture the starting baseline

Before a fresh install or an approved shared-cluster maintenance operation,
record bounded reads only:

```sh
kubectl get nodes -o wide
kubectl -n <namespace> get aiplatform,aiservice
kubectl -n <namespace> get deployments,statefulsets,daemonsets,pods,hpa,services -o wide
kubectl -n <namespace> get networkpolicies
kubectl -n <namespace> get deployments \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image'
kubectl -n <namespace> get secret <las-license> <las-postgres> <las-redis> \
  -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,RV:.metadata.resourceVersion'
```

Never request or decode Secret data for evidence. Record Secret names, UIDs,
and resource versions only. Verify the current live image references before
attributing results to a source commit.

## 6. Perform the fresh offline install

Only proceed in an approved maintenance window with rollback and cleanup owners
identified. Keep public routes denied throughout the install.

```sh
AUTO_DIAGNOSE=false \
tools/cluster_setup/install_from_airgap_bundle.sh \
  --bundle /protected/path/airgap-bundle-<timestamp>.tar.gz \
  --expected-bundle-sha256 <sha256-recorded-before-transfer> \
  --config /protected/path/completed-cpu-airgap-config.yaml \
  --extract-dir /protected/path/install
```

`AUTO_DIAGNOSE=false` prevents a failed verification step from automatically
collecting broader diagnostics. Use direct, bounded `kubectl` reads for routine
evidence. Review any logs locally before sharing because configuration or
dependency errors can include sensitive fields.

After installation, require current-generation Ready conditions for AIPlatform
and the Agent Runtime AIService. Require LAS API, LAS queue, SLIM, operator, and
other selected supporting controllers to have all desired replicas Ready. Also
confirm the LAS compatibility Service has ready endpoints and that PostgreSQL,
Redis, and object storage are reachable only over approved private paths.

## 7. Collect runtime and digest evidence

Run the validator read-only first:

```sh
python3 tools/cluster_setup/validate_cpu_airgap_runtime.py \
  --namespace <namespace> \
  --aiplatform <aiplatform-name> \
  --aiservice <agentruntime-aiservice-name> \
  --bundle-dir /protected/path/install/airgap-bundle-<timestamp> \
  --bundle-tarball /protected/path/airgap-bundle-<timestamp>.tar.gz \
  --expected-bundle-sha256 <sha256-recorded-before-transfer> \
  --expected-source-commit <reviewed-40-character-commit> \
  --deployment-config /protected/path/completed-cpu-airgap-config.yaml \
  --network-evidence /protected/path/sanitized-network-evidence.json \
  --operator-namespace <operator-namespace> \
  --splunk-namespace <splunk-namespace> \
  --output-dir /protected/path/mpr-129-evidence
```

The validator checks CPU-only topology, API/queue/operator/SLIM/Splunk readiness,
absence of GPU/NVIDIA/Ray/model-staging workloads, and each configured runtime
`imageID` against the approved top-level or matching platform digest in the
inventory. Its result is `RUNTIME_PASS`, not final MPR-129 acceptance: the dated
evidence template must also record the fresh install, invalid-artifact check,
cleanup, and owner approvals. Review `mpr-129-evidence.json` and
`mpr-129-evidence.md` before sharing them.

## 8. Prove replacement from the approved artifact

This step deletes exactly one LAS Pod. Run it only in the approved qualification
window. Both flags are required to opt in:

```sh
python3 tools/cluster_setup/validate_cpu_airgap_runtime.py \
  --namespace <namespace> \
  --aiplatform <aiplatform-name> \
  --aiservice <agentruntime-aiservice-name> \
  --bundle-dir /protected/path/install/airgap-bundle-<timestamp> \
  --bundle-tarball /protected/path/airgap-bundle-<timestamp>.tar.gz \
  --expected-bundle-sha256 <sha256-recorded-before-transfer> \
  --expected-source-commit <reviewed-40-character-commit> \
  --deployment-config /protected/path/completed-cpu-airgap-config.yaml \
  --network-evidence /protected/path/sanitized-network-evidence.json \
  --operator-namespace <operator-namespace> \
  --splunk-namespace <splunk-namespace> \
  --output-dir /protected/path/mpr-129-replacement-evidence \
  --replace-component queue \
  --confirm-disposable-cluster
```

Use `--timeout-seconds` and `--poll-seconds` only when the approved environment
needs values other than their 300-second and 5-second defaults.

Require a new Pod UID, Ready state, and exactly the same approved normalized
image digest. If an API port-forward was open, close and recreate it after Pod
replacement; a forward tied to the old Pod is not reusable evidence.

## 9. Prove invalid staged artifacts fail closed

Use only a scratch copy. Move or corrupt one staged LAS archive or chart inside
the scratch bundle, repack it, and keep the original untouched. Then run the
scratch tarball through `--validate-only` with stub/sentinel monitoring for the
installer and network clients.

Require all of the following:

- nonzero exit with a checksum, required-artifact, OCI-reference, inventory, or
  chart-digest error;
- no bundled installer invocation;
- no host binary installation or Helm repository change;
- no `kubectl`, SSH, registry, or public download fallback.

The repository test `tools/cluster_setup/test_install_from_airgap_bundle.sh`
exercises these fail-closed paths without a live cluster. The live acceptance
record must still retain the isolated environment's bounded negative result.

## 10. Review, clean up, and retain evidence

Restore or remove disposable test resources, close port-forwards, and rerun the
bounded health checks. Do not tear down shared infrastructure without its
owner's explicit approval.

Before attaching evidence:

- remove private topology identifiers and local paths;
- confirm that no Secret values, database URLs, license keys, registry auth,
  request payloads, or raw environment dumps are present;
- retain source commit, bundle SHA, inventory/chart digests, import or mirror
  source, network-isolation assertions, readiness, original/replacement Pod UIDs
  and image IDs, negative-test result, and cleanup status;
- complete `docs/agent-runtime/mpr-129-cpu-airgap-evidence-template.md` with the
  reviewed live results. Do not mark it complete from local unit tests alone.
