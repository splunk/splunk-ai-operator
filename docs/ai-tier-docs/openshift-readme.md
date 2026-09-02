# Splunk AI tier on OpenShift (AI POD)

This guide installs Splunk AI tier (AI POD) on an **existing** OpenShift
cluster. The installer does not create, upgrade, or remove the OpenShift
cluster itself.

For a k0s deployment, use [`K0S_README.md`](./K0S_README.md).

## Contents

1. [What the installer deploys](#what-the-installer-deploys)
2. [Requirements](#requirements)
3. [Prepare the configuration](#prepare-the-configuration)
4. [Connected installation](#connected-installation)
5. [Air-gapped installation](#air-gapped-installation)
6. [Verify and access the deployment](#verify-and-access-the-deployment)
7. [Configuration reference](#configuration-reference)
8. [OpenShift behavior](#openshift-behavior)
9. [Model staging](#model-staging)
10. [Troubleshooting](#troubleshooting)
11. [Uninstall](#uninstall)

## What the installer deploys

`openshift_with_stack.sh install` deploys the following components:

| Component | Namespace | Method |
|---|---|---|
| Node Feature Discovery Operator | `openshift-nfd` | Operator Lifecycle Manager |
| NVIDIA GPU Operator | `nvidia-gpu-operator` | Operator Lifecycle Manager |
| Local Path Provisioner | `local-path-storage` | Manifest |
| cert-manager | `cert-manager` | Manifest |
| OpenTelemetry Operator | `opentelemetry-operator-system` | Helm |
| KubeRay Operator | `ray-system` | Helm |
| Splunk AI Operator | `splunk-ai-operator-system` | Manifest |
| Splunk Operator | `splunk-operator` | Manifest |
| Splunk Standalone, Ray, Weaviate, SAIA, and SLIM | `ai-platform` | Operators and custom resources |
| SAIA and SLIM Routes | `ai-platform` | OpenShift Routes |

The workload namespace is configurable and defaults to `ai-platform`.

## Requirements

### OpenShift cluster

- OpenShift Container Platform **4.21.x**.
- Red Hat Enterprise Linux CoreOS (RHCOS) **amd64** control-plane and worker
  nodes. The installer rejects other node operating systems and architectures.
- At least one OpenShift worker node.
- A production cluster should use the standard three-node, highly available
  control plane.
- `cluster-admin` access. The installer creates cluster-scoped resources,
  installs operators, labels nodes, and grants Security Context Constraints.
- Network connectivity from the installer machine to the OpenShift API,
  configured image registry, and object store.

The installer is qualified for OpenShift 4.21. Setting another value in the
configuration does not add support for another OpenShift release.

### AI-tier worker capacity

The current topology uses one shared AI-tier node pool for CPU and GPU
workloads.

| `scaleFactor` | System RAM | Available workload disk | GPU memory | CPU |
|---:|---:|---:|---:|---:|
| `1` | 256 GiB | 1 TiB (1024 GiB) | 2 × 96 GB VRAM | 64 allocatable vCPU |
| `2` | 512 GiB | 2 TiB (2048 GiB) | 4 × 96 GB VRAM | 128 allocatable vCPU |

The disk requirement is usable capacity available immediately before install,
not the drive's advertised size. A 1 TB drive provides about 931 GiB before
formatting and does not meet the 1024 GiB scale-1 check. The storage must cover
`/var/lib/containers` and `/opt/local-path-provisioner` or provide equivalent
capacity for both.

`scaleFactor` does not add hardware. Add the required CPU, memory, GPU, and
storage capacity before increasing it.

### Reference hardware for `scaleFactor: 1`

Shared AI-tier worker — one Cisco UCS C845A M8 AI Server:

- Memory: 8 × `CAI-MRX64G2RE5` — 512 GB installed
- CPU: 2 × `CAI-CPU-A9375F` — 64 physical cores / 128 threads
- GPU: 2 × `CAI-GPU-RTXP6000` — 192 GB total VRAM
- Boot: 2 × `CAI-M2-960G` with `CAI-M2-HWRAID`, RAID 1 — 1.92 TB raw /
  960 GB usable
- Workload storage: dedicated enterprise NVMe providing at least 1 TiB
  available for scale 1

OpenShift control plane — three Cisco UCS C225 M8 SFF servers, each with:

- Memory: 8 × `UCS-MRX32G1RE3` — 256 GB installed
- CPU: 1 × `UCS-CPU-A9224` — 24 physical cores / 48 threads with SMT
- Boot: 2 × `UCS-M2-480G`, RAID 1 — 960 GB raw / 480 GB usable

The AI worker's boot pair does not satisfy the workload-disk requirement.
Provide separate workload storage.

### Installer machine

| Installation type | Supported installer host |
|---|---|
| Connected | macOS or Linux with the required tools |
| Air-gapped cluster | Linux host; `oc-mirror` is Linux-only |

RHEL 9, RHEL 10, and Ubuntu 24 can be used as installer hosts when all tools
are available. They are installer machines, not supported OpenShift node
operating systems for this deployment.

Required tools:

- OpenShift CLI (`oc`), logged in to the target cluster
- Mike Farah `yq` v4
- Helm v3+
- `curl`, `jq`, `base64`, GNU `timeout`, `python3`, and `tar`
- MinIO client (`mc`) for MinIO, SeaweedFS, or generic S3-compatible storage
- AWS CLI only when using AWS S3 or automatic Amazon ECR authentication
- `oc-mirror` v2 for an air-gapped installation

Exact client patch versions are not pinned. The installer pins these platform
dependencies:

| Dependency | Installer contract |
|---|---|
| OpenShift | 4.21.x |
| Node Feature Discovery Operator | `stable` channel |
| NVIDIA GPU Operator | `v26.3` channel |
| cert-manager | 1.13.0 |
| Local Path Provisioner | 0.0.26 |
| KubeRay Operator | 1.2.2 |
| OpenTelemetry Operator chart | 0.121.0 |
| Ray runtime | 2.56.0 |

### External services

Before installation, provide:

- A registry containing every image configured under `images.*`.
- An AWS S3, MinIO, SeaweedFS, or generic S3-compatible object store for model
  artifacts.
- Credentials for private registries and the object store.
- Access from the installer machine to Hugging Face when model staging is
  enabled and any required model is missing.

OpenShift nodes do not need direct internet access when all images are
available through registries reachable by the cluster and all models are in the
configured object store.

## Prepare the configuration

Work from `tools/ai-tier-cluster-setup` and create an environment-specific copy of the
template:

```bash
cd <path-to-clone>/splunk-ai-operator/tools/ai-tier-cluster-setup
cp openshift-cluster-config.yaml my-openshift-cluster-config.yaml
export CONFIG_FILE="$PWD/my-openshift-cluster-config.yaml"
```

Edit the copy and set, at minimum:

- `openshift.nodes` to the AI-tier worker node names when using the `manual`
  labeling strategy
- every `images.*` reference and its registry authentication method
- `storage.objectStore` endpoint, bucket, type, and credentials
- `storage.modelStaging.enabled` for the intended model workflow
- `ecr.enabled: false` when the image registry is not Amazon ECR

Do not commit credentials. Relative paths under `files` are resolved relative
to the configuration file, so keep the copied file in
`tools/ai-tier-cluster-setup` or use absolute manifest paths.

Validate cluster access before installation:

```bash
export KUBECONFIG="$HOME/.kube/openshift"  # omit if oc is already configured
oc whoami
oc whoami --show-server
oc auth can-i '*' '*' --all-namespaces     # must print yes
```

## Connected installation

Set `cluster.airgap: false`, then run:

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh install
```

The install command performs preflight checks, stages missing models when
enabled, installs the platform, waits for readiness, and prints the SAIA and
SLIM URLs. A separate `stage-artifacts` run is not required.

For unattended installation:

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh install --silent
```

## Air-gapped installation

This mode supports an OpenShift cluster without public internet access. Set:

```yaml
cluster:
  airgap: true
```

Run the same command from a Linux installer machine:

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh install
```

The installer uses `oc-mirror` to mirror its OpenShift-specific dependencies
into `images.registry`, applies the generated mirror policies and catalog
sources, and continues the installation. It mirrors:

- Node Feature Discovery and NVIDIA GPU Operator catalogs and operand images
- the OpenShift Driver Toolkit image when it is not already in the cluster's
  release mirror
- cert-manager, Local Path Provisioner, KubeRay, and OpenTelemetry images
- installer helper images

The customer must provide separately:

- every application image configured under `images.*` in the internal registry
- object-store and registry credentials
- model weights, unless the installer machine can download missing models

The installer host must be Linux, have `oc-mirror` v2, and have about **100 GiB
of free disk space** for mirror content and working files. During preparation it
must reach the target OpenShift API, public source registries, the internal
registry, and the object store. If model staging is enabled, it must also reach
Hugging Face when a model is missing.

The cluster nodes do not need public internet access. They must reach the
internal registry and object store.

`images.registryInsecure: true` enables a plain-HTTP registry for a controlled
lab network. It does not disable certificate verification for an HTTPS
registry. Leave it `false` for production.

## Verify and access the deployment

Check the custom resources and pods:

```bash
oc get aiplatform,aiservice,raycluster,rayservice -n ai-platform
oc get pods -n ai-platform
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh verify
```

The default external endpoints are:

```text
SAIA: http://saia.<ingress-domain>
SLIM: http://slim.<ingress-domain>/tenant/slim-api/v1alpha1
```

Use the SAIA URL in the Splunk AI Assistant app and the full SLIM URL in Splunk
AI Toolkit. An existing external Splunk Enterprise deployment can use these
URLs when its network can resolve and reach the OpenShift Routes.

When Splunk runs inside the same cluster, AITK can use the internal SLIM
endpoint instead:

```text
http://<aiPlatform.name>-slim-slim-service.<namespace>.svc.cluster.local:8080/tenant/slim-api/v1alpha1
```

List the Routes:

```bash
oc get route saia slim -n ai-platform
```

The installer creates HTTP Routes. Production HTTPS requires Route TLS and a
certificate trusted by the client; that certificate configuration is outside
the current installer.

To open the Ray dashboard locally:

```bash
oc port-forward -n ai-platform svc/openshift-ai-platform-head-svc 8265:8265
```

Then open `http://localhost:8265`. Replace `openshift-ai-platform` if
`aiPlatform.name` was changed.

## Configuration reference

### Cluster and OpenShift

| Setting | Meaning |
|---|---|
| `cluster.airgap` | `false` for connected; `true` for an air-gapped cluster |
| `kubernetes.namespace` | Workload namespace; default `ai-platform` |
| `openshift.requiredVersion` | Qualified OpenShift minor; must be `4.21` |
| `openshift.grantPrivilegedSCC` | Grant required SCC access; disable only when equivalent policy exists |
| `openshift.nodeLabelStrategy` | `manual` labels listed nodes; `auto` labels all workers |
| `openshift.nodes` | AI-tier nodes used by the `manual` strategy |
| `openshift.ingressDomain` | Optional ingress-domain override |
| `openshift.routes.<feature>.enabled` | Create the SAIA or SLIM Route |
| `openshift.routes.<feature>.host` | Optional Route hostname override |

CPU and GPU workloads share the AI-tier pool. GPU workers are selected by their
`nvidia.com/gpu` resource request; there is no separate CPU/GPU scheduling mode
in this installer.

### Images and registry credentials

`images.registry` is prepended only to image names that are not fully
qualified. Fully qualified references are used as written.

For Amazon ECR, enable:

```yaml
ecr:
  enabled: true
  account: "<aws-account-id>"
  region: "<aws-region>"
```

The installer runs `aws ecr get-login-password` and creates pull secrets in
the required namespaces. Amazon ECR tokens expire after 12 hours; long-running
clusters need an external refresh process.

For another private registry, disable ECR and configure the matching
`imagePullSecrets` block. Example:

```yaml
ecr:
  enabled: false

imagePullSecrets:
  custom:
    enabled: true
    server: "registry.example.com"
    username: "<username>"
    password: "<access-token>"
```

Supported blocks are `dockerHub`, `gcr`, `acr`, and `custom`. A public
registry that does not require authentication needs no pull-secret block.

### Object store

```yaml
storage:
  objectStore:
    type: "minio"       # aws | minio | seaweedfs | s3compat
    bucket: "ai-platform-bucket"
    endpoint: "http://object-store.example.com:9000"
    auth:
      rootUser: "<access-key>"
      rootPassword: "<secret-key>"
```

`endpoint` is required for MinIO, SeaweedFS, and `s3compat`. AWS S3 uses
`storage.objectStore.region`; AWS CLI is required. Temporary AWS STS access
keys are not supported because the generated secret has no session-token
field.

### Splunk issuers and HEC

The installer adds the primary short Splunk management service URL to
`SPLUNK_ISSUERS`. Values under `splunk.trustedIssuers` are additional accepted
management/JWT issuer URLs; use them when a client token contains a different,
valid service URL such as the namespace-qualified service name.

The JWT issuer endpoint and `hecEndpoint` serve different purposes:

- the issuer endpoint validates Splunk JWTs on port 8089
- `hecEndpoint` sends telemetry to Splunk HTTP Event Collector on port 8088

### AI Platform

| Setting | Meaning |
|---|---|
| `aiPlatform.name` | AIPlatform custom-resource name |
| `aiPlatform.defaultAcceleratorType` | Must be `RTX_PRO_6000_BLACKWELL` |
| `aiPlatform.scaleFactor` | Integer capacity multiplier, minimum 1 |
| `aiPlatform.features` | Enabled feature services: SAIA and SLIM |
| `aiPlatform.serviceTemplate.type` | Backing Service type; normally `ClusterIP` on OpenShift |

Keep the feature Services as `ClusterIP` when Routes provide external access.
`NodePort` and `LoadBalancer` remain explicit alternatives, but they are not
needed for the standard OpenShift design.

Reducing `scaleFactor` resizes workloads and causes temporary service downtime.
Downscale during a maintenance window.

### Manifest paths

```yaml
files:
  aiPlatform: "./artifacts.yaml"
  splunkOperator: "./splunk-operator-cluster.yaml"
```

Relative paths are resolved from the directory containing `CONFIG_FILE`.

## OpenShift behavior

### Security Context Constraints

When `openshift.grantPrivilegedSCC` is `"true"`, the installer grants the
`anyuid` and `privileged` constraints required by the operators and workloads.
It records the grants it owns and removes them during `delete`.

Use the same configuration for install and delete. If SCC management is turned
off before delete, the installer cannot remove grants created by the earlier
run.

### Operators and GPU drivers

Node Feature Discovery and the NVIDIA GPU Operator are installed through
Operator Lifecycle Manager. The GPU Operator uses the OpenShift Driver Toolkit;
the installer does not SSH to nodes or install host drivers manually.

For a disconnected cluster, the relevant catalogs, operand images, GPU driver
images, and Driver Toolkit image must be available through the configured
mirror. The air-gapped workflow handles this content.

### Storage and SELinux

The installer can deploy the Local Path Provisioner when `storageClass` is
`local-path`. It labels the host directory for container use through
`oc debug node`, which is why cluster-admin access is required.

Local persistent volumes have node affinity. Changing `openshift.nodes` after
volumes are created can leave replacement pods pending if the original node is
no longer eligible.

### Routes

SAIA and SLIM have separate Routes backed by `ClusterIP` Services. The Routes
use a 600-second timeout and disabled response buffering for long-running and
streaming responses. A Route may return HTTP 503 until its backing Service has
ready endpoints.

## Model staging

The RTX Pro 6000 Blackwell profile uses
`model_artifacts_configs_quantized.yaml`, including the quantized Gemma model.

`storage.modelStaging.enabled` controls the workflow:

- `true`: check completion markers and download/upload only missing or changed
  models from the installer machine
- `false`: do not download models; verify that every required completion marker
  already exists before changing the cluster

The cluster nodes do not download models from Hugging Face. Ray workers read
the staged artifacts from the object store.

AWS S3, MinIO, SeaweedFS, and generic S3-compatible stores are supported. Run
staging separately only when needed:

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh stage-artifacts
```

Set `SKIP_IF_STAGED=0` to force a fresh download and upload.

## Troubleshooting

### Collect a support bundle

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh diagnose
```

`verify` automatically collects diagnostics on failure unless
`AUTO_DIAGNOSE=false`.

### `ImagePullBackOff`

Confirm the image reference is correct and that its pull secret exists in the
pod namespace and is attached to the service account. Refresh expired Amazon
ECR credentials when applicable.

### Route returns HTTP 503

Check the backing pods and endpoints:

```bash
oc get pods,endpoints,route -n ai-platform
```

Routes are created before all model services are ready, so a temporary 503
during deployment is expected.

### Pod remains `Pending`

Check node capacity, taints, persistent-volume node affinity, and the configured
AI-tier nodes:

```bash
oc describe pod <pod-name> -n ai-platform
oc get pv -o wide
```

### Webhook has no endpoints

Wait for the Splunk AI Operator rollout, then rerun install:

```bash
oc get pods,endpoints -n splunk-ai-operator-system
```

### Certificate is not yet valid

Confirm that every cluster node uses a common Network Time Protocol source.
The installer retries transient cert-manager clock-skew errors, but incorrect
node time must be fixed at the infrastructure level.

### Operator-owned resources

Do not patch generated StatefulSets or Deployments as a permanent fix. The
operator reconciles them from the AIPlatform and AIService custom resources.

## Uninstall

```bash
CONFIG_FILE="$CONFIG_FILE" ./openshift_with_stack.sh delete
```

This removes resources owned by the installer and leaves the OpenShift cluster
running.
