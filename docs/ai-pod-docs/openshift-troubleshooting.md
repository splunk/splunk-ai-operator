# Troubleshooting Splunk AI Tier on OpenShift (AI POD)

This guide diagnoses failures produced by `openshift_with_stack.sh` and the AI
POD components it deploys on an existing OpenShift cluster. It applies to the
OpenShift workflow only. Do not use the k0s-specific SSH, MetalLB, cluster
bootstrap, or host-driver procedures from
[`troubleshooting.md`](../ai-tier-docs/troubleshooting.md).

For installation requirements and configuration, see
[`openshift-readme.md`](./openshift-readme.md). For AIPlatform conditions,
events, Ray, and Weaviate runtime details that are common across Kubernetes
platforms, also see the
[operator troubleshooting guide](../splunk-ai-operator-docs/troubleshooting.md).

## Contents

- [Start here](#start-here)
- [Installer and preflight failures](#installer-and-preflight-failures)
- [Standard-deployment content failures](#standard-deployment-content-failures)
- [Air-gapped deployment failures](#air-gapped-deployment-failures)
- [Operator Lifecycle Manager failures](#operator-lifecycle-manager-failures)
- [Node Feature Discovery and GPU failures](#node-feature-discovery-and-gpu-failures)
- [Storage failures](#storage-failures)
- [Object-store and model-staging failures](#object-store-and-model-staging-failures)
- [AIPlatform, Ray, and Weaviate failures](#aiplatform-ray-and-weaviate-failures)
- [SAIA and SLIM Route failures](#saia-and-slim-route-failures)
- [Splunk AI Assistant and AI Toolkit failures](#splunk-ai-assistant-and-ai-toolkit-failures)
- [Delete and reinstall failures](#delete-and-reinstall-failures)
- [Diagnostic command reference](#diagnostic-command-reference)

## Start here

Run diagnostics before patching or deleting resources.
Run installer commands from `tools/ai-tier-cluster-setup` unless a command says
otherwise.

The command examples use Bash-compatible syntax. Start `bash` first when the
installer machine's interactive shell is Fish.

### 1. Use the same configuration

Set the kubeconfig and configuration used for installation:

```bash
export KUBECONFIG="$HOME/.kube/openshift"
export CONFIG_FILE="/absolute/path/to/openshift-cluster-config.yaml"

oc whoami
oc whoami --show-server
oc auth can-i create clusterrolebinding --all-namespaces
```

The last command must print `yes`. If it does not, use an identity with the
cluster-admin permissions required by the installer.

Read the configured workload names for later commands:

```bash
export AI_NAMESPACE="$(yq eval '.kubernetes.namespace // "ai-platform"' "$CONFIG_FILE")"
export AI_PLATFORM_NAME="$(yq eval '.aiPlatform.name // "openshift-ai-platform"' "$CONFIG_FILE")"
```

### 2. Check the installer log

Each invocation creates a timestamped log under the installer's `logs/`
directory by default:

```bash
find logs -maxdepth 1 -type f -name 'openshift-install-*.log' -print \
  | sort -r | head -5

LATEST_LOG="$(find logs -maxdepth 1 -type f \
  -name 'openshift-install-*.log' -print | sort -r | head -1)"
if [ -n "$LATEST_LOG" ]; then
  grep -E 'ERROR|WARN|✖' "$LATEST_LOG" || true
else
  echo "No installer logs found"
fi
```

Fix the first concrete failure. Later readiness messages are often
consequences of the same problem.

### 3. Check platform readiness

```bash
oc get aiplatform,aiservice,raycluster,rayservice -n "$AI_NAMESPACE"
oc get pods -n "$AI_NAMESPACE" -o wide
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh verify-pods
```

`verify-pods` waits up to 30 minutes by default. It checks pods, AIPlatform,
AIServices, RayCluster, RayService, and Ray Serve readiness. If verification
fails, the installer automatically runs `diagnose` unless
`AUTO_DIAGNOSE=false` is set.

### 4. Collect a support bundle

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh diagnose
```

The command prints the exact generated bundle path. The bundle includes
installer logs, cluster inventory, events, workload
descriptions, pod logs, operator logs, tool versions, and a redacted copy of
the configuration. Review it before sharing because cluster and application
logs can still contain operationally sensitive information.

### 5. Re-run safely

After correcting the root cause, run the same install command again:

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh install
```

The installer reconciles its resources. Do not permanently patch generated
Deployments, StatefulSets, Services, Ray resources, or Jobs; their owning
operators can overwrite those changes.

## Installer and preflight failures

### `Required tool not found`

The installer always requires `oc`, Mike Farah `yq` v4, Helm v3, `curl`, `jq`,
`base64`, `tar`, GNU `timeout`, and `python3`.

It additionally requires:

- `mc` for MinIO, SeaweedFS, or generic S3-compatible model checks
- AWS CLI for AWS S3 or automatic Amazon ECR pull-secret creation
- a Linux installer machine for air-gapped installation because Red Hat
  `oc-mirror` is Linux-only

Confirm the executable and version:

```bash
for tool in oc yq helm curl jq base64 tar timeout python3; do
  command -v "$tool" || echo "MISSING: $tool"
done
yq --version
helm version
```

Use the dependency installation instructions in
[`openshift-readme.md`](./openshift-readme.md#installer-machine). Do not use the
Python-based `yq`; the installer requires Mike Farah `yq` v4 syntax.

### `Config file not found` or YAML syntax errors

Use an absolute path and parse it before retrying:

```bash
test -f "$CONFIG_FILE"
yq eval '.' "$CONFIG_FILE" >/dev/null
```

Paths below `files.*` are resolved relative to the directory containing the
configuration file, not necessarily the shell's current directory.

### `Not logged in to OpenShift`

Confirm that `KUBECONFIG` points to a real file and that its API endpoint is
reachable:

```bash
test -f "$KUBECONFIG"
oc config current-context
oc whoami --show-server
oc whoami
```

An error that refers to `localhost:8080` normally means the kubeconfig was not
loaded. Authentication errors can also mean that the token in the kubeconfig
has expired. Network timeouts require routing, firewall, Domain Name System,
or VPN access to the OpenShift API; changing the kubeconfig does not create
that network path.

### Cluster-admin check fails

The installer creates cluster-scoped resources, Operator Lifecycle Manager
subscriptions, node labels, Security Context Constraint grants, and OpenShift
image configuration. Check the exact permission used by preflight:

```bash
oc auth can-i create clusterrolebinding --all-namespaces
```

Do not work around this by manually granting only one failed permission; the
later installation phases require additional cluster-scoped operations.

### OpenShift version, node operating system, or architecture is rejected

The current deployment is qualified for OpenShift 4.21.x with Red Hat
Enterprise Linux CoreOS `amd64` nodes. Confirm the detected values:

```bash
oc get clusterversion version
oc get nodes \
  -o custom-columns=NAME:.metadata.name,OS:.status.nodeInfo.osImage,ARCH:.status.nodeInfo.architecture
```

Changing `openshift.requiredVersion` does not add support for another release.
OpenShift may support other worker operating systems, but this installer and
GPU deployment path reject configurations outside the qualified contract.

### Configured AI-tier node does not exist

With `openshift.nodeLabelStrategy: manual`, every entry under
`openshift.nodes` must match an OpenShift node name exactly:

```bash
yq eval '.openshift.nodeLabelStrategy, .openshift.nodes[]' "$CONFIG_FILE"
oc get nodes
```

Correct the configuration rather than renaming a live OpenShift node.

### AI-tier node has insufficient container storage

The check measures available space below `/var/lib/containers`, falling back
to `/`, on every selected AI-tier node. The minimum is 1024 GiB multiplied by
`aiPlatform.scaleFactor` unless the configured minimum is higher.

Inspect the same path through OpenShift:

```bash
oc get nodes
read -r -p "Node name: " NODE_NAME
oc debug node/"$NODE_NAME" --quiet -- chroot /host sh -c \
  'path=/var/lib/containers; [ -d "$path" ] || path=/; df -h "$path"'
```

Freeing model data from the object store does not increase node container
storage. Add or expand node storage, clean only confirmed-unused container
content through supported OpenShift procedures, or select nodes that satisfy
the requirement. Do not lower the minimum merely to bypass preflight.

### StorageClass check fails

```bash
oc get storageclass
yq eval '.storage.storageClass' "$CONFIG_FILE"
```

The installer can create `local-path`; any other configured StorageClass must
already exist. If no class is configured and no default exists, the installer
uses `local-path`.

### Object-store configuration fails preflight

Supported values for `storage.objectStore.type` are `aws`, `minio`,
`seaweedfs`, and `s3compat`. `endpoint` is required for all except AWS S3.
Permanent access and secret keys are required; temporary AWS STS keys beginning
with `ASIA` are unsupported because the generated secret has no session-token
field.

Check only the non-secret values:

```bash
yq eval '{
  "type": .storage.objectStore.type,
  "bucket": .storage.objectStore.bucket,
  "endpoint": .storage.objectStore.endpoint,
  "region": .storage.objectStore.region
}' "$CONFIG_FILE"
```

Replace template values such as `<...>` or `CHANGEME`. Keep credentials out of
shell history and source control.

### Registry preflight reports redirects or an unexpected status

The installer first probes the registry `/v2/` endpoint, then checks the
manifest for the configured Splunk AI Operator image. A successful registry
ping normally returns HTTP 200, 401, or 403. Redirects are reported as warnings
because they are not the standard Open Container Initiative registry response.

Verify the registry hostname, repository path, tag, and authentication:

```bash
yq eval '.images.registry, .images.operator.image, .images.registryInsecure' "$CONFIG_FILE"
```

For a private registry, configure the matching `imagePullSecrets` block.
`images.registryInsecure` defaults to `true` for a registry intentionally using
plain HTTP. Set it to `false` for a registry using HTTPS with a certificate
trusted by the installer and OpenShift nodes.

## Standard-deployment content failures

### Manifest or Helm download fails

A standard deployment downloads cert-manager and Local Path Provisioner
manifests and the OpenTelemetry and KubeRay charts. Confirm the installer
machine can reach the sources listed under
[External content dependencies](./openshift-readme.md#external-content-dependencies).

The OpenShift nodes separately need access to the Operator catalogs and every
registry referenced by Operator and workload images. Internet access on the
installer machine does not imply that the cluster nodes have registry access.

### Workloads fail with `ImagePullBackOff`

Identify the exact image and event first:

```bash
oc get pods --all-namespaces | grep -E 'ImagePullBackOff|ErrImagePull' || true
read -r -p "Pod namespace: " POD_NAMESPACE
read -r -p "Pod name: " POD_NAME
oc describe pod "$POD_NAME" -n "$POD_NAMESPACE"
```

Then confirm:

1. The image and tag exist at the rendered registry path.
2. The appropriate pull secret exists in the pod namespace.
3. The pod's service account references that secret.
4. OpenShift nodes can resolve and reach the registry.
5. The registry certificate is trusted, unless the registry is deliberately
   configured as insecure.

```bash
SERVICE_ACCOUNT="$(oc get pod "$POD_NAME" -n "$POD_NAMESPACE" \
  -o jsonpath='{.spec.serviceAccountName}')"
oc get secret -n "$POD_NAMESPACE"
oc get serviceaccount "$SERVICE_ACCOUNT" -n "$POD_NAMESPACE" -o yaml
oc get image.config.openshift.io/cluster -o yaml
```

Amazon ECR authorization tokens expire after 12 hours. Refresh the credentials
and rerun install to recreate the installer-managed pull secrets, then restart
only the affected workload through its owning resource or operator.

## Air-gapped deployment failures

### Air-gapped install is rejected on macOS

Air-gapped OpenShift installation requires Linux because `oc-mirror` is
Linux-only. A macOS laptop remains supported for a standard deployment but
must run the air-gapped workflow through a Linux installer host or Linux
container with sufficient storage and network access.

### Bundle preparation consumes excessive disk space

The unified installer stores prepared content below
`airgap-bundle-openshift/` in the working directory by default and reuses the
prepared directory directly. It does not need a second transfer archive for a
same-host installation.

Check space and existing prepared directories:

```bash
df -h .
du -sh airgap-bundle-openshift 2>/dev/null || true
```

Set `OPENSHIFT_AIRGAP_OUTPUT_DIR` to a filesystem with sufficient temporary
capacity. Remove a prepared directory only after confirming that no current or
future installation will reuse it.

### Registry authentication fails during `oc-mirror` import

The mirror import occurs before normal workload pull secrets are created. The
installer combines the cluster pull secret with
`imagePullSecrets.custom`, or uses an explicit `REGISTRY_AUTH_FILE` or
`AIRGAP_REGISTRY_AUTH_FILE`.

Confirm that the auth file covers both source registries and the internal
destination. For Amazon ECR, `ecr.enabled: true` alone is not sufficient for
this earlier import phase; provide a current destination token through one of
the documented mirror-authentication methods.

Do not print or attach the decoded registry auth file to a support ticket.

### `oc-mirror import failed after 3 attempts`

Check the preceding `oc-mirror` output for the exact repository, registry, or
certificate failure. Common causes are:

- unreachable source or destination registry
- insufficient destination-registry storage
- missing push permission
- expired authentication
- certificate trust failure
- an installer host architecture that cannot execute the bundled `oc-mirror`

Correct the cause and rerun the normal install command. The preparation and
import workflow is designed to reuse completed content.

### Checksum verification fails

The prepared bundle is incomplete or was modified. Do not bypass the checksum
check. Recreate or recopy the bundle and retry.

### Mirrored CatalogSource is missing or not ready

```bash
oc get catalogsource -n openshift-marketplace
read -r -p "CatalogSource name: " CATALOG_SOURCE
oc describe catalogsource "$CATALOG_SOURCE" -n openshift-marketplace
oc get pods -n openshift-marketplace
```

The air-gapped wrapper creates separate mirrored CatalogSources rather than
overwriting OpenShift's default `redhat-operators` and `certified-operators`
sources. Confirm that the catalog image points to the internal registry and
that the Marketplace namespace can pull it.

### Image mirror policy is missing

```bash
oc get imagedigestmirrorset,imagetagmirrorset
oc get imagecontentsourcepolicy 2>/dev/null || true
```

The installer requires mirror coverage for its infrastructure images, Node
Feature Discovery, the NVIDIA GPU Operator and operands, and the OpenShift
Driver Toolkit. Application images under `images.*` are customer-provided and
must already exist in the configured internal registry.

### MachineConfigPool does not finish updating

Mirror policies and insecure-registry configuration can update node container
runtime configuration. The installer waits for all MachineConfigPools to
report `Updated=True` before installing dependent operators.

```bash
oc get machineconfigpool
read -r -p "MachineConfigPool name: " MACHINE_CONFIG_POOL
oc describe machineconfigpool "$MACHINE_CONFIG_POOL"
oc get nodes
```

Investigate degraded nodes and follow the cluster administrator's supported
MachineConfig recovery procedure. Do not start Operator subscriptions while
the affected pool is still updating or degraded.

## Operator Lifecycle Manager failures

### Subscription does not produce a successful ClusterServiceVersion

Inspect the Subscription, InstallPlan, ClusterServiceVersion, CatalogSource,
and namespace events:

```bash
oc get subscription,installplan,csv -n openshift-nfd
oc get subscription,installplan,csv -n nvidia-gpu-operator
oc get catalogsource -n openshift-marketplace
oc get events -n openshift-nfd --sort-by='.lastTimestamp'
oc get events -n nvidia-gpu-operator --sort-by='.lastTimestamp'
```

The configured channels are `stable` for Node Feature Discovery and `v26.3`
for the NVIDIA GPU Operator. Operator Lifecycle Manager selects the compatible
patch release within each channel. A copied subscription from another
OpenShift release or a catalog without that package/channel will not satisfy
the installer.

### Operator deployment is not ready

```bash
oc get pods -n openshift-nfd -o wide
oc get pods -n nvidia-gpu-operator -o wide
oc get pods -n cert-manager -o wide
oc get pods -n opentelemetry-operator-system -o wide
oc get pods -n ray-system -o wide
oc get pods -n splunk-ai-operator-system -o wide
oc get pods -n splunk-operator -o wide
```

Describe the failing pod and read both current and previous container logs:

```bash
read -r -p "Pod namespace: " POD_NAMESPACE
read -r -p "Pod name: " POD_NAME
oc describe pod "$POD_NAME" -n "$POD_NAMESPACE"
oc logs "$POD_NAME" -n "$POD_NAMESPACE" --all-containers=true --tail=300
oc logs "$POD_NAME" -n "$POD_NAMESPACE" --all-containers=true \
  --previous --tail=100 2>/dev/null || echo "No previous container logs"
```

### Webhook has no endpoints

Wait for the owning operator to become ready and confirm its Service endpoints:

```bash
oc get deployment,pods,svc,endpointslice -n splunk-ai-operator-system
oc logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=300
```

After the webhook is ready, rerun install. Do not disable webhook validation as
a workaround.

### Certificate is not yet valid

This normally indicates clock skew between cluster nodes or between the
installer and API server. Confirm node time synchronization through the
customer's OpenShift infrastructure management. The installer retries
transient cert-manager webhook errors, but it cannot repair the underlying
time source.

## Node Feature Discovery and GPU failures

### Node Feature Discovery is not ready

```bash
oc get nodefeaturediscovery nfd-instance -n openshift-nfd
oc get pods -n openshift-nfd -o wide
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
```

If no NVIDIA hardware labels appear, inspect the Node Feature Discovery worker
pods on the expected GPU nodes and the namespace events. In an air-gapped
cluster, also confirm that the Node Feature Discovery operand image is covered
by mirror policy.

### NVIDIA GPU Operator ClusterPolicy is not ready

```bash
oc get clusterpolicy gpu-cluster-policy
oc describe clusterpolicy gpu-cluster-policy
oc get pods -n nvidia-gpu-operator -o wide
oc get events -n nvidia-gpu-operator --sort-by='.lastTimestamp'
```

The installer enables the OpenShift Driver Toolkit through the generated
ClusterPolicy. It does not SSH to nodes or install host drivers manually. For
air-gapped clusters, the Operator catalog, operands, driver images, and the
matching OpenShift Driver Toolkit image must all resolve through the mirror.

### GPU is not allocatable

```bash
oc get nodes -l nvidia.com/gpu.present=true
oc get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```

If the GPU label exists but allocatable capacity is empty, inspect the NVIDIA
driver, toolkit, device-plugin, and validator pods scheduled to that node:

```bash
oc get nodes -l nvidia.com/gpu.present=true
read -r -p "GPU node name: " NODE_NAME
oc get pods -n nvidia-gpu-operator -o wide \
  --field-selector "spec.nodeName=$NODE_NAME"
```

Resolve the first failing GPU Operator operand. Do not manually install a host
driver alongside the Operator-managed OpenShift Driver Toolkit path.

### GPU workload remains `Pending`

```bash
RAY_WORKER_POD="$(oc get pods -n "$AI_NAMESPACE" \
  -l ray.io/node-type=worker --field-selector=status.phase=Pending \
  -o json | jq -r '.items[0].metadata.name // empty')"
if [ -n "$RAY_WORKER_POD" ]; then
  oc describe pod "$RAY_WORKER_POD" -n "$AI_NAMESPACE"
else
  echo "No Pending Ray worker pod found"
fi
oc get nodes -L splunk.ai/ai-tier-node,nvidia.com/gpu.present
```

Check the scheduling event for insufficient `nvidia.com/gpu`, node affinity,
taints, or insufficient CPU and memory. GPU workloads request the GPU resource;
CPU and GPU workloads otherwise share the selected AI-tier node pool.

## Storage failures

### PersistentVolumeClaim remains `Pending`

```bash
oc get pvc,pv -n "$AI_NAMESPACE" -o wide
PENDING_PVC="$(oc get pvc -n "$AI_NAMESPACE" \
  -o json | jq -r \
  '.items[] | select(.status.phase == "Pending") | .metadata.name' | head -1)"
if [ -n "$PENDING_PVC" ]; then
  oc describe pvc "$PENDING_PVC" -n "$AI_NAMESPACE"
else
  echo "No Pending PersistentVolumeClaim found"
fi
oc get storageclass
```

For `local-path`, also inspect the provisioner:

```bash
oc get pods -n local-path-storage -o wide
oc logs -n local-path-storage -l app=local-path-provisioner --tail=300
```

Local persistent volumes have node affinity. If the selected AI-tier nodes
changed after volume creation, a replacement pod may be unable to use the
existing volume. Restore an eligible node or follow an approved data-migration
procedure; do not delete a persistent volume containing required data without
a backup.

### Local Path Provisioner reports permission or SELinux errors

The installer labels the host path for container use through
`oc debug node`, which requires cluster-admin access. Inspect provisioner and
pod events, then confirm the affected node completed the relabel operation.
Do not disable SELinux.

### Node reports disk pressure

```bash
oc get nodes
read -r -p "Node name: " NODE_NAME
oc describe node "$NODE_NAME"
oc debug node/"$NODE_NAME" --quiet -- chroot /host df -h
```

Container storage, local persistent volumes, logs, and temporary model staging
can consume different filesystems. Identify the full filesystem before
cleaning data. The object-store copy of model artifacts is separate from local
container storage.

## Object-store and model-staging failures

### Object store is unreachable

The installer machine and AI workloads must reach the configured endpoint.
For MinIO, SeaweedFS, and generic S3-compatible storage, test from both
locations because successful access from a laptop does not prove cluster
egress:

```bash
export OBJECT_STORE_ENDPOINT="$(yq eval '.storage.objectStore.endpoint' "$CONFIG_FILE")"
curl -sS --connect-timeout 10 --max-time 20 \
  -o /dev/null -w 'HTTP %{http_code}\n' "$OBJECT_STORE_ENDPOINT"

NGINX_POD="$(oc get pod -n "$AI_NAMESPACE" \
  -l "component=${AI_PLATFORM_NAME}-saia-nginx" \
  -o jsonpath='{.items[0].metadata.name}')"
oc exec "$NGINX_POD" -n "$AI_NAMESPACE" -- \
  curl -sS --connect-timeout 10 --max-time 20 \
  -o /dev/null -w 'HTTP %{http_code}\n' "$OBJECT_STORE_ENDPOINT"
```

The cluster-side command uses `curl` already present in the deployed SAIA
nginx container, so it does not pull a public diagnostic image. An HTTP 403 can
still prove network reachability, but it does not prove that the configured
credentials or bucket permissions are correct. For AWS S3, validate access
with the customer's approved AWS credential and network-diagnostic workflow.

### Required models are reported missing

The installer checks one
`staging_state/<artifact-id>/.staging_complete` marker per required model and
also compares its recorded Hugging Face source. List the current profile and
rerun staging:

```bash
yq eval '.aiPlatform.defaultAcceleratorType, .storage.modelStaging.enabled' "$CONFIG_FILE"
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh stage-artifacts
```

The RTX Pro 6000 Blackwell profile uses the quantized artifact manifest,
including the quantized Gemma model. Do not substitute a similarly named
unquantized model.

### Hugging Face download returns 401 or 403

Confirm that `HF_TOKEN` is available to the installer process and is authorized
for every gated model. For gated repositories, the token owner must accept the
repository's access terms. Do not place the token in the cluster configuration
or commit it to Git.

### Upload to AWS S3, MinIO, SeaweedFS, or S3-compatible storage fails

Check:

- endpoint and port
- bucket existence and write permission
- access and secret keys
- region for AWS S3
- certificate trust or the intended HTTP scheme
- available object-store capacity

Use `aws` for AWS S3 and `mc` for MinIO, SeaweedFS, or `s3compat`. The installer
does not deploy the object store or create its underlying storage service.

### Force a fresh model stage

Normally, valid completion markers make staging skip existing artifacts. After
repairing a corrupted or incomplete object-store upload, force a fresh pass:

```bash
SKIP_IF_STAGED=0 CONFIG_FILE="$CONFIG_FILE" \
  ./openshift_with_stack.sh stage-artifacts
```

Use this only when a fresh upload is required; it can download and transfer
large model artifacts again.

## AIPlatform, Ray, and Weaviate failures

### AIPlatform or AIService remains unready

```bash
oc get aiplatform,aiservice -n "$AI_NAMESPACE" -o wide
oc describe aiplatform "$AI_PLATFORM_NAME" -n "$AI_NAMESPACE"
oc describe aiservice -n "$AI_NAMESPACE"
oc get events -n "$AI_NAMESPACE" --sort-by='.lastTimestamp' | tail -100
oc logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=500
```

Read the current-generation conditions and the first warning event. A stale
condition from a previous generation is not proof that the current spec is
ready.

### Pod remains `Pending`

```bash
PENDING_POD="$(oc get pods -n "$AI_NAMESPACE" \
  --field-selector=status.phase=Pending \
  -o json | jq -r '.items[0].metadata.name // empty')"
if [ -n "$PENDING_POD" ]; then
  oc describe pod "$PENDING_POD" -n "$AI_NAMESPACE"
else
  echo "No Pending pod found"
fi
oc get pvc,pv -n "$AI_NAMESPACE" -o wide
oc get nodes -L splunk.ai/ai-tier-node,nvidia.com/gpu.present
```

Typical causes are insufficient CPU, memory, or GPUs; a taint without a
toleration; node affinity; or persistent-volume node affinity. Fix capacity or
placement rather than editing the generated pod.

### Pod is in `CrashLoopBackOff`

```bash
oc get pods -n "$AI_NAMESPACE"
read -r -p "CrashLoopBackOff pod name: " POD_NAME
oc logs "$POD_NAME" -n "$AI_NAMESPACE" --all-containers=true --tail=300
oc logs "$POD_NAME" -n "$AI_NAMESPACE" --all-containers=true \
  --previous --tail=300 2>/dev/null || echo "No previous container logs"
oc describe pod "$POD_NAME" -n "$AI_NAMESPACE"
```

The previous log is usually the most useful after a restart. Check the event
for out-of-memory termination, failed mounts, invalid environment values,
object-store access, or image errors.

### RayCluster or RayService does not become ready

```bash
oc get raycluster,rayservice -n "$AI_NAMESPACE" -o wide
oc describe raycluster -n "$AI_NAMESPACE"
oc describe rayservice -n "$AI_NAMESPACE"
oc get pods -n "$AI_NAMESPACE" -l ray.io/node-type=head -o wide
oc logs -n "$AI_NAMESPACE" -l ray.io/node-type=head \
  --all-containers=true --tail=500
```

Also inspect Ray worker pods and the Ray dashboard:

```bash
oc get pods -n "$AI_NAMESPACE" -l ray.io/node-type=worker -o wide
oc port-forward -n "$AI_NAMESPACE" \
  "svc/${AI_PLATFORM_NAME}-head-svc" 8265:8265
```

Open `http://localhost:8265` and inspect the Serve deployment and replica
state. A model can spend significant time downloading from the object store or
initializing on GPU, but repeated replica restarts, allocation failures, or
unchanged error states require investigation.

### Model replica fails or restarts

Check the Ray head and worker logs for the exact model. Common causes include:

- missing or mismatched object-store artifacts
- insufficient GPU memory
- unsupported GPU or runtime/image mismatch
- insufficient shared memory or node memory
- model initialization exceptions

Confirm that `operators.ray.rayVersion` matches the Ray head and worker images
and that the accelerator profile matches the installed GPU. Do not change model
resource requests directly on generated Ray resources.

### Weaviate is not ready

```bash
oc get pods,pvc -n "$AI_NAMESPACE" | grep -i weaviate
read -r -p "Weaviate pod name: " WEAVIATE_POD
oc describe pod "$WEAVIATE_POD" -n "$AI_NAMESPACE"
oc logs "$WEAVIATE_POD" -n "$AI_NAMESPACE" \
  --all-containers=true --tail=300
```

Check persistent-volume binding, permissions, node affinity, and available
disk. Weaviate persistent data is distinct from model artifacts in the object
store.

### Re-run the vector database setup Job

The setup Job is owned by the AIService and cannot be rerun in place. Find the
completed or failed setup Job, inspect its logs, then delete only that Job so
the operator can recreate it:

```bash
oc get jobs -n "$AI_NAMESPACE"
read -r -p "Vector database setup Job name: " JOB_NAME
oc logs job/"$JOB_NAME" -n "$AI_NAMESPACE" --all-containers=true
oc delete job "$JOB_NAME" -n "$AI_NAMESPACE"
```

Do not delete unrelated Jobs.

## SAIA and SLIM Route failures

### Route returns HTTP 503

Routes are created before their backing Services have ready endpoints, so a
temporary 503 during reconciliation is expected.

```bash
oc get route saia slim -n "$AI_NAMESPACE"
oc get svc,endpointslice -n "$AI_NAMESPACE" | grep -E 'saia|slim'
oc get pods -n "$AI_NAMESPACE" -o wide
```

If the Service has no endpoints, troubleshoot the backing SAIA or SLIM pods.
Rerunning the installer is not required merely because the Route was created
before the Service.

### Route hostname cannot be resolved or reached

```bash
oc get route saia slim -n "$AI_NAMESPACE" -o wide
oc get ingresscontroller default -n openshift-ingress-operator \
  -o jsonpath='{.status.domain}{"\n"}'
curl -v "http://$(oc get route saia -n "$AI_NAMESPACE" -o jsonpath='{.spec.host}')"
```

The user browser and any external Splunk server each need independent Domain
Name System and network access to the OpenShift router. A route that works on
the installer laptop may still be unreachable from the Splunk host.

The installer creates HTTP Routes only. Do not change the application URL to
HTTPS; Route TLS and workload mutual TLS are not configured or qualified by
this workflow.

### Long request or streaming response is interrupted

The installer sets a 600-second router timeout and disables response buffering
on the SAIA and SLIM Routes. Confirm that those annotations are present:

```bash
oc get route saia slim -n "$AI_NAMESPACE" -o yaml
```

Also inspect any customer proxy, firewall, or load balancer in front of the
OpenShift router; it can impose a shorter timeout that the Route annotation
does not control.

## Splunk AI Assistant and AI Toolkit failures

### Splunk AI Assistant shows a generic processing error

The user's browser calls the SAIA Route directly. Check the browser network
request, then test the same Route from the browser's network location. An HTTP
200 connection establishment does not guarantee that the server-sent event
stream contains a successful model response.

Check SAIA, RayService, and model replica logs in the cluster. If the response
is 401 or 403, continue with JWT validation checks below.

### JWT validation fails

SAIA and SLIM validate Splunk-issued JWTs against the configured management
issuer on port 8089. Confirm:

1. The token issuer exactly matches a value in the effective
   `SPLUNK_ISSUERS` list.
2. The SAIA or SLIM pod can resolve and reach that issuer.
3. All cluster nodes and Splunk use synchronized time.
4. The issuer's signing keys are available.

The installer adds the primary short service URL. Add only legitimate
alternate URLs under `splunk.trustedIssuers`, such as the namespace-qualified
service URL when Splunk produces that issuer. Do not add arbitrary trusted
issuers to suppress an authentication error.

### SAIA v2 works differently from SAIA v1

Splunk AI Assistant browser traffic must reach the published SAIA Route
directly. nginx sends `/saia-api-v2/` paths to SAIA v2 and other SAIA paths to
v1. Confirm the browser is not attempting to send v2 traffic through a
Splunk-server-only network path.

### AI Toolkit endpoint saves but no models appear

AI Toolkit uses SLIM, not SAIA. The endpoint must include the full path:

```text
http://<slim-host>/tenant/slim-api/v1alpha1
```

For the bundled Splunk deployment, use the internal ClusterIP service shown in
[`openshift-readme.md`](./openshift-readme.md#install-and-configure-splunk-ai-toolkit).
For an external Splunk deployment, use the SLIM Route and confirm that the
Splunk host—not only the user's browser—can resolve and reach it.

Saving a connection validates its format but is not a complete model and
inference test. Confirm that models appear when creating an LLM connection,
then run the documented `ai` and `apply CDTSM` smoke tests.

### Bundled Splunk is not ready

```bash
oc get standalone,pods,svc -n "$AI_NAMESPACE" | grep -i splunk
oc describe standalone -n "$AI_NAMESPACE"
oc get events -n "$AI_NAMESPACE" --sort-by='.lastTimestamp' | tail -100
```

The installer also requires Splunk HTTP Event Collector to be enabled on the
configured internal endpoint because OpenTelemetry sends platform telemetry to
it. JWT issuer traffic uses Splunk management port 8089; `hecEndpoint` is a
different endpoint on port 8088.

## Cleanup and reinstall failures

### Cleanup leaves the OpenShift cluster running

This is expected. `clean-all` removes the installer-owned AI POD stack and shared
components recorded as installer-owned; it does not delete the OpenShift
cluster.

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh clean-all
```

Use the same namespace and resource names used for install. Ownership is
recorded in an installer state ConfigMap in `openshift-config`, and deletion
preserves pre-existing shared components that were not owned by the installer.

### A custom resource is stuck terminating

Check finalizers and the owning operator before taking action:

```bash
oc get aiplatform,aiservice -n "$AI_NAMESPACE" -o yaml
oc logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=500
```

Do not remove finalizers manually unless Splunk Support has confirmed that the
owning controller cannot complete cleanup and has provided a recovery plan.

### Reinstall does not redownload models or images

This is normally correct:

- valid model completion markers make staging skip unchanged object-store
  artifacts
- OpenShift nodes reuse cached images according to the workload image pull
  policy
- a prepared air-gap directory can be reused for subsequent installs

Use a new immutable image tag or digest to deploy a changed image. Use
`SKIP_IF_STAGED=0` only when model artifacts genuinely need a fresh upload.

## Diagnostic command reference

### Cluster and node state

```bash
oc get clusterversion version
oc get clusteroperators
oc get machineconfigpool
oc get nodes -o wide
oc describe nodes
```

### Operator Lifecycle Manager

```bash
oc get catalogsource -n openshift-marketplace
oc get subscription,installplan,csv -A
```

### AI POD resources

```bash
oc get aiplatform,aiservice,raycluster,rayservice -n "$AI_NAMESPACE" -o wide
oc get pods,deployments,statefulsets,daemonsets,jobs -n "$AI_NAMESPACE" -o wide
oc get pvc,svc,endpointslice,route -n "$AI_NAMESPACE"
oc get events -n "$AI_NAMESPACE" --sort-by='.lastTimestamp' | tail -100
```

### Splunk AI Operator logs

```bash
oc logs -n splunk-ai-operator-system \
  -l control-plane=controller-manager --tail=500
```

### One failing pod

```bash
read -r -p "Pod namespace: " POD_NAMESPACE
read -r -p "Pod name: " POD_NAME
oc describe pod "$POD_NAME" -n "$POD_NAMESPACE"
oc logs "$POD_NAME" -n "$POD_NAMESPACE" --all-containers=true --tail=300
oc logs "$POD_NAME" -n "$POD_NAMESPACE" --all-containers=true \
  --previous --tail=100 2>/dev/null || echo "No previous container logs"
```

### Installer support bundle

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh diagnose
```

Attach the bundle at the path printed by `diagnose` only after reviewing it
for operationally sensitive content.
