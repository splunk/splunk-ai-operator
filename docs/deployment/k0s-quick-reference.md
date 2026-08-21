# k0s Deployment — Quick Reference

One-page cheat sheet for installing the Splunk AI Platform on k0s. For full
explanations, diagrams, and edge cases see
[DEPLOYMENT_GUIDE.md](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md) and
[K0S_README.md](../../tools/cluster_setup/K0S_README.md).

All commands run from `tools/cluster_setup/` unless noted otherwise.

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Hardware Requirements](#2-hardware-requirements)
3. [Config Setup](#3-config-setup)
4. [Standard Deployment](#4-standard-deployment)
   - [Hardware Setup (Standard Path)](#hardware-setup-standard-path)
   - [Model Setup (Standard Path)](#model-setup-standard-path)
   - [Install (Standard Path)](#install-standard-path)
5. [Air-Gapped Deployment](#5-air-gapped-deployment)
   - [Hardware Setup (Air-Gapped Path)](#hardware-setup-air-gapped-path)
   - [Model Setup (Air-Gapped Path)](#model-setup-air-gapped-path)
   - [Install (Air-Gapped Path)](#install-air-gapped-path)
6. [Verify](#6-verify)
7. [Common Operations](#7-common-operations)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Prerequisites

**Admin workstation** — the machine you run `k0s_cluster_with_stack.sh` from
(your laptop, a bastion host, or the installer machine described in
[Air-Gapped Deployment](#5-air-gapped-deployment)). It needs SSH reach to every
cluster node plus the CLI tools below; it is not itself a cluster node.

If this machine also handles model staging (downloading from HuggingFace and
uploading to MinIO/SeaweedFS/S3 — automatic during `install`, or run
standalone via `stage-artifacts`), it additionally needs:

| Resource | Minimum | Why |
|---|---|---|
| Disk (free) | 250 GB | >120 GB for 11 models + buffer for download staging and upload temp files |
| RAM | 16 GB | Scripts stream large files; less RAM causes swapping and slow uploads |
| CPU | 4 cores | Parallel upload to MinIO/SeaweedFS/S3 |
| Internet | Stable broadband | Downloads >120 GB from HuggingFace; safe to re-run — already-staged models are skipped |

**Admin workstation tools:**

**macOS / Ubuntu** — `brew install kubectl helm git jq yq` or the `apt-get`
equivalent; see
[K0S_README.md — Required Tools](../../tools/cluster_setup/K0S_README.md#required-tools-on-admin-workstation)
for exact commands.

**RHEL 9** — none of `kubectl`, `helm`, `docker`, or `yq` are in the default
`dnf` repos; `git` and `jq` are. Install each via its own supported method
(standalone binary, install script, or vendor repo, per each tool's docs)
rather than a single `dnf install`:

- `kubectl` — [official binary download](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
- `helm` — [install script or binary release](https://helm.sh/docs/intro/install/)
- `yq` — [binary release](https://github.com/mikefarah/yq#install)
- `git`, `jq` — `sudo dnf install -y git jq`
- `docker` — [Docker CE repo for RHEL](https://docs.docker.com/engine/install/rhel/) (needed for the image-mirroring commands below)

Verify:

```bash
kubectl version --client && helm version && git --version && jq --version && yq --version && docker version
```

The image-mirroring commands below use `docker pull`/`tag`/`push` — no
extra tool needed beyond Docker. (If you already have `crane` installed,
`crane copy SRC DST` is a drop-in replacement for the
`docker pull SRC && docker tag SRC DST && docker push DST` sequence.)

**Access and services checklist:**

- [ ] SSH private key with access to every cluster node
- [ ] Object storage reachable from all nodes: MinIO / SeaweedFS / S3 (500 GB+ recommended)
- [ ] Container registry with platform images pushed (or plan to mirror for air-gap)
- [ ] Splunk account team has provided image entitlements / registry access
- [ ] Decide your path now: [Standard Deployment](#4-standard-deployment) (cluster nodes have internet access) or [Air-Gapped Deployment](#5-air-gapped-deployment) (sealed nodes, no outbound internet)

**Mirror platform images to your internal registry.** Pull each image from
Docker Hub, push it to your mirror, and then set the corresponding image fields
in the cluster config to those mirrored paths (required for both paths —
air-gap additionally needs every node to resolve that registry with no outbound
internet):

The default Ray and SAIA images currently use the `preview` tag:

```bash
for repo in \
  splunk/ai-tier-saia-data-loader \
  splunk/ai-tier-saia-api-v2 \
  splunk/ai-tier-saia-api \
  splunk/ai-tier-ray-head \
  splunk/ai-tier-ray-worker; do
  docker pull "docker.io/${repo}:preview"
  docker tag "docker.io/${repo}:preview" "<your-registry>/${repo}:preview"
  docker push "<your-registry>/${repo}:preview"
done
```

After mirroring, replace the five fully qualified `images.ray.*` and
`images.saia.*` values in the cluster config with the corresponding
`<your-registry>/splunk/...:preview` paths. Mirror the Slim and operator images
separately when those components are enabled, using the tags configured for
your release. `crane copy` (see [Air-Gapped Deployment](#5-air-gapped-deployment))
is an alternative to `docker pull`/`tag`/`push` for bulk mirroring.

> `preview` is a mutable tag and the workloads use `imagePullPolicy:
> IfNotPresent`. Use a new immutable tag or digest for controlled upgrades;
> rerunning the installer with the same tag may keep the cached image.

---

## 2. Hardware Requirements

Pick **one** GPU accelerator type for the cluster — `L40S` or `H100`, set via
`aiPlatform.defaultAcceleratorType` — and provision only the matching GPU
worker row below. The two GPU rows are alternatives, not additive; do not
provision both.

Min CPU/RAM/Disk below are **per node** — for GPU workers, multiply by the
node count (2 minimum) to get the cluster total.

| Node Type | Min CPU (per node) | Min RAM (per node) | Min Disk (per node) | Count | Notes |
|---|---|---|---|---|---|
| Controller | 4 cores | 8 GB | 100 GB | 1 | API server, etcd, scheduler — the installer joins only the first controller IP; additional controller IPs are not joined and are not HA |
| CPU Worker | 8 cores | 32 GB | 200 GB | 1+ | Weaviate, Ray head, Splunk, SAIA API, Data Loader |
| GPU Worker — choose **either** L40S **or** H100, not both: | | | | | |
| ↳ L40S (`g6e.12xlarge`) | 48 vCPU | 384 GiB | 500 GB | **2 nodes minimum** | 4× NVIDIA L40S/node, 48 GB VRAM/GPU (192 GB/node, 384 GB total across 2 nodes) · equivalent to AWS EC2 `g6e.12xlarge` (48 vCPUs, 384 GiB RAM, 4× L40S) **per node** |
| ↳ H100 (`p5.4xlarge`) | 16 vCPU | 256 GiB | 500 GB | **2 nodes minimum** | 1× NVIDIA H100/node, 80 GB HBM3/GPU (160 GB total across 2 nodes) · equivalent to AWS EC2 `p5.4xlarge` (16 vCPUs, 256 GiB RAM, 1× H100) **per node** |

**Ports to open between nodes:**

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 6443 | TCP | Kubernetes API server |
| 2380 | TCP | etcd peer |
| 10250 | TCP | Kubelet API |
| 8132 | TCP | Konnectivity |
| 179 | TCP | Calico BGP |
| 4789 | UDP | Calico VXLAN |
| 30000-32767 | TCP | NodePort services (optional) |

**Object storage sizing:**

| Data | Minimum | Notes |
|---|---|---|
| Model weights | 250 GB | >120 GB for 11 models + re-staging headroom |
| Runtime data | 100 GB | Grows with usage |
| **Total bucket** | **500 GB+** | Sufficient for now |

---

## 3. Config Setup

Copy the template and fill in only the **mandatory** fields below — everything
else has a working default. Full field-by-field reference:
[K0S_README.md — Configuration Reference](../../tools/cluster_setup/K0S_README.md#configuration-reference).

```bash
git clone https://github.com/splunk/splunk-ai-operator.git
cd splunk-ai-operator/tools/cluster_setup

cp k0s-cluster-config.yaml my-cluster.yaml
vi my-cluster.yaml
```

| Field | Set to |
|---|---|
| `cluster.sshKeyPath` | Path to your SSH private key |
| `cluster.sshUser` | SSH user for remote nodes |
| `cluster.region` | Your region — required only if `storage.objectStore.type: aws` |
| `nodes.existingIPs.controllers` | Controller node IP (only 1 is supported — see Hardware Requirements) |
| `nodes.existingIPs.workers` | CPU + GPU worker node IPs, **CPU workers first**: the installer treats the first `nodes.cpuWorkers` entries as CPU nodes and every remaining entry as GPU — set `nodes.cpuWorkers` to match, or the wrong machines get GPU driver/workload setup |
| `storage.objectStore.type` | `aws` \| `minio` \| `seaweedfs` |
| `storage.objectStore.endpoint` | Object store API endpoint (not needed for `type: aws`) |
| `storage.objectStore.auth.rootUser` / `rootPassword` | Access key / secret (never commit real values) |
| `images.registry` | Your registry host, e.g. `123456789012.dkr.ecr.us-east-2.amazonaws.com` |
| `aiPlatform.defaultAcceleratorType` | `L40S` or `H100` |
| `ecr.account` / `ecr.region` | Your AWS account ID / region — **only if** `imagePullSecrets.autoCreateECR: true` (default) |

Validate before installing — catches most config mistakes without touching any node:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate
```

> **Air-gapped clusters need a few additional fields** (`cluster.airgap: true`,
> `storage.modelStaging.enabled: false`, `imagePullSecrets.autoCreateECR: false`,
> an internal `images.registry`) — see [Air-Gapped Deployment](#5-air-gapped-deployment).
> Everything above still applies to air-gapped installs; pick your path below
> once this base config is filled in.

---

## 4. Standard Deployment

For clusters where every node has outbound internet access.

### Hardware Setup (Standard Path)

Confirm every node's OS (RHEL 9 or Ubuntu 24.04), passwordless sudo, Python
3.8+, and SSH access before running the installer — GPU driver install is
fully automatic, no manual steps needed. Full commands and details:
[DEPLOYMENT_GUIDE.md — Step-by-Step (Standard)](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#step-by-step-standard).

### Model Setup (Standard Path)

Model weights (>120 GB, 11 models) must land in your object store before the
AI platform can serve inference.

- **Full (interactive) install** — the installer always prompts whether to
  download models; your answer at the prompt overrides
  `storage.modelStaging.enabled`.
- **Silent install** (`--silent` / `AUTO_APPROVE=true`) — set
  `storage.modelStaging.enabled: true` in your config (the shipped template
  defaults to `false`). The installer then downloads from HuggingFace and
  uploads to your object store as part of `install`. Safe to re-run;
  already-staged models are skipped.

```bash
# Re-run staging only, without a full install
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts
```

**Staging machine requirements:** see [Prerequisites](#1-prerequisites) — same machine as the admin workstation, sized for model staging.

> Switching `aiPlatform.defaultAcceleratorType` between `L40S`/`H100` after staging invalidates the staged marker — re-run `stage-artifacts` to re-stage for the new accelerator.

### Install (Standard Path)

```bash
cd tools/cluster_setup

CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate   # config check, run first
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install    # ~3-7h first run (model download), ~30-60min if pre-staged

# Follow progress in another terminal
tail -f logs/k0s-install-*.log
```

Continue to [Verify](#6-verify).

---

## 5. Air-Gapped Deployment

For sealed cluster nodes with no outbound internet. Everything is staged and
pushed from a single internet-connected installer machine that also has SSH
reach to the cluster nodes — there is no separate transfer/bundle step.

### Hardware Setup (Air-Gapped Path)

Same node checks as the standard path (OS, sudo, Python, SSH — see
[Hardware Setup (Standard Path)](#hardware-setup-standard-path)) apply to the
**cluster nodes** (controllers, CPU workers, GPU workers) — those can be RHEL 9
or Ubuntu 24.04. The **installer machine itself must be RHEL 9 x86_64** — it
builds the offline RPM/.deb NVIDIA driver closures using its own `dnf`, and
that only works from RHEL.

**GPU worker nodes** — no manual driver install needed.
`k0s_cluster_with_stack.sh install` derives each GPU node's kernel and OS over
SSH and builds/pushes a complete offline NVIDIA driver closure automatically
as part of the same run — an RPM closure for RHEL 9 GPU nodes, a .deb closure
for Ubuntu 24.04 GPU nodes. You can still pre-install the driver yourself (same
commands as the standard path) if you prefer, but it isn't required. See
[K0S_README.md — GPU Nodes in Air-Gapped Environments](../../tools/cluster_setup/K0S_README.md#gpu-nodes-in-air-gapped-environments)
for the closure mechanics and manual overrides.

**Installer machine requirements:** RHEL 9 x86_64, curl, helm, kubectl,
tar/ssh/rpm/dnf/sha256sum, `createrepo_c`, sudo, ~5 GB free disk. Building a
.deb closure for Ubuntu 24.04 GPU nodes additionally requires `podman` or
`docker` on the installer machine.

### Model Setup (Air-Gapped Path)

Air-gapped clusters cannot reach HuggingFace from the cluster nodes, so model
staging is always done from the installer machine. No manual steps needed —
`k0s_cluster_with_stack.sh install` downloads models from HuggingFace and
uploads them to your object store automatically as part of the same run
(models + images + NVIDIA driver closure, all in one pass). Safe to re-run;
already-staged artifacts are skipped.

**Staging machine requirements** (downloading from HuggingFace + uploading to MinIO/SeaweedFS/S3) — can be the same machine that runs the installer:

| Resource | Minimum | Why |
|---|---|---|
| Disk (free) | 250 GB | >120 GB for 11 models + buffer for download staging and upload temp files |
| RAM | 16 GB | Scripts stream large files; less RAM causes swapping and slow uploads |
| CPU | 4 cores | Parallel upload to MinIO/SeaweedFS/S3 |
| Internet | Stable broadband | Downloads >120 GB from HuggingFace; safe to re-run — already-staged models are skipped |

> Switching `aiPlatform.defaultAcceleratorType` between `L40S`/`H100` after staging invalidates the staged marker — re-run `stage-artifacts` to re-stage for the new accelerator.

> To pre-stage manually ahead of install instead — e.g. to inspect artifacts
> or size them before the install window — see
> [K0S_README.md — Step 3: Stage Model Weights](../../tools/cluster_setup/K0S_README.md#step-3--stage-model-weights)
> and [DEPLOYMENT_GUIDE.md](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md) for
> the manual `download_from_huggingface.sh` / `upload_to_*.sh` and
> `airgap_install.sh --download-only` workflows.

### Install (Air-Gapped Path)

One entry point, same install command as the standard path — the config's
`cluster.airgap: true` (or `AIRGAP_MODE=true`) is what switches the mode.

```bash
cd tools/cluster_setup

# 1. Mirror platform application images to your internal registry
#    (the list is generated during staging at
#    ./airgap-bundle/airgap-bundle-<timestamp>/container-images.txt —
#    pre-stage with --download-only first, or use the path printed at the
#    end of a staging run, to get the exact file)
IMAGE_LIST=$(ls ./airgap-bundle/airgap-bundle-*/container-images.txt | tail -1)
while IFS= read -r img; do
  [[ "$img" =~ ^# || -z "$img" ]] && continue
  crane copy "$img" "registry.airgap.local/${img##*/}"
done < "${IMAGE_LIST}"

# 2. In your config, on top of the mandatory fields in Config Setup, set:
#    storage.modelStaging.enabled: false     (models already staged — see Model Setup above)
#    cluster.airgap: true
#    imagePullSecrets.autoCreateECR: false
#    images.registry: "registry.airgap.local"   (+ point every image at it)
#
#    registry.airgap.local requires authentication (Harbor, etc.)? autoCreateECR: false
#    alone creates no pull secret — also set:
#    imagePullSecrets.custom.enabled: true
#    imagePullSecrets.custom.name: "custom-registry-secret"
#    imagePullSecrets.custom.server: "registry.airgap.local"
#    imagePullSecrets.custom.username / .password: your registry credentials

# 3. Run the install — stages ~2.2 GB of artifacts (~15 min) then installs
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

`airgap_install.sh` is the lower-level staging step the unified command calls
for you — reach for it directly only for non-default flags (`--k0s-version`,
`--gpu-hosts`, `--gpu-kernels`, `--driver-version`, `--skip-nvidia-closure`, …).
GPU node IPs, SSH user/key, and each node's kernel are all derived from your
config automatically, so no GPU flags are normally needed — the NVIDIA driver
closure is built and pushed to GPU nodes as part of the same run.

Continue to [Verify](#6-verify).

---

## 6. Verify

Applies to both deployment paths.

```bash
export KUBECONFIG=~/.kube/k0s-<cluster-name>

kubectl get nodes -o wide                                          # all Ready
kubectl get pods -A --sort-by=.metadata.namespace                  # all Running/Completed
kubectl get aiplatform -n ai-platform -o wide                      # Ready
kubectl get svc -n ai-platform -l app.kubernetes.io/component=saia # EXTERNAL-IP assigned
kubectl get nodes -l splunk.ai/workload-type=gpu -o yaml | grep nvidia.com/gpu
# → nvidia.com/gpu: "<count>" under both capacity and allocatable, per GPU node
```

**Reach the in-cluster Splunk instance** via NodePort (default), LoadBalancer
(MetalLB), or `kubectl port-forward` for quick access with no external
exposure: [DEPLOYMENT_GUIDE.md — Internal Splunk Access](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#internal-splunk-access).

Once the cluster is healthy, install and onboard the **Splunk AI Assistant**
app: [DEPLOYMENT_GUIDE.md — Install the Splunk AI Assistant App](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#install-the-splunk-ai-assistant-app).

> **Using an external Splunk Enterprise/Cloud instance instead of the
> in-cluster one?** See
> [EXTERNAL_SPLUNK_INTEGRATION.md](../../tools/cluster_setup/EXTERNAL_SPLUNK_INTEGRATION.md).

---

## 7. Common Operations

Applies to both deployment paths — same commands for standard and air-gapped clusters.

| Task | Command |
|---|---|
| Re-run after partial failure | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install` |
| Add worker nodes | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh join-workers` |
| Re-stage models only | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts` |
| Upgrade platform | bump image tags in config, then re-run `install` (Helm upgrades in place; same command works for air-gap) |
| Upgrade platform (air-gapped) | **first** mirror each changed image at its new tag to your internal registry (`install` never does this for you), **then** bump the tag in config and re-run `install` — otherwise sealed nodes hit `ImagePullBackOff` on the new tag |
| Collect support bundle | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh diagnose` |
| Wipe and start clean (destructive) | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh clean-all` then `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install` |

---

## 8. Troubleshooting

Quick hits — full symptom list: [TROUBLESHOOTING.md](../../tools/cluster_setup/TROUBLESHOOTING.md)

| Symptom | Fix |
|---|---|
| SSH connection refused | Check firewall/security group on port 22 |
| "Refusing to wipe — Ready nodes" (rare — a plain re-run normally detects the already-running k0s and resumes into stack deploy without hitting this) | Set `cluster.useExisting: auto` or run `clean-all` first |
| `python3+pyyaml missing` on nodes | RHEL: `dnf install -y python3-pyyaml`; Ubuntu: `apt-get install -y python3-yaml`; or set `AIRGAP_PYYAML_WHEEL_PATH` for air-gap |
| `nvidia-smi not found` in AIRGAP_MODE, no closure staged | Re-run without `--skip-nvidia-closure`, or pre-install the driver manually (see [Hardware Setup (Air-Gapped Path)](#hardware-setup-air-gapped-path)) |
| Closure doesn't cover a GPU node's kernel | Re-run `airgap_install.sh` with `--gpu-kernels` including that node's `uname -r` |
| Checksum verification failed during staging | Re-run staging; check disk space and network stability |
| Pod `ImagePullBackOff` (platform images) | Check `images.registry` + pull secret exist |
| `ImagePullBackOff`: HTTP response to HTTPS client | Set `images.registryInsecure: true` for plain-HTTP registries |
| All models MISSING after upload | Bucket name has uppercase letters — use lowercase `storage.objectStore.bucket` |
| Air-gap: infra pods `ImagePullBackOff` / nodes NotReady | Confirm `images/*.tar` were staged and pushed to `/var/lib/k0s/images/`; re-run install with current scripts |
| SAIA service has no `EXTERNAL-IP` | Check MetalLB: `kubectl get pods -n metallb-system` |
| AIPlatform CR stuck `Pending` | `kubectl describe aiplatform -n ai-platform`; check operator logs + GPU availability |

---

*Quick reference — see [DEPLOYMENT_GUIDE.md](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md) for the full walkthrough.*
