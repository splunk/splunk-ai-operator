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

**Admin workstation tools:**

```bash
# macOS
brew install kubectl helm git jq yq

# Ubuntu/Debian
sudo apt-get update && sudo apt-get install -y kubectl helm git jq
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# Verify
kubectl version --client && helm version && git --version && jq --version && yq --version
```

**Access and services checklist:**

- [ ] SSH private key with access to every cluster node
- [ ] Object storage reachable from all nodes: MinIO / SeaweedFS / S3 (500 GB+ recommended)
- [ ] Container registry with platform images pushed (or plan to mirror for air-gap)
- [ ] Splunk account team has provided image entitlements / registry access
- [ ] Decide your path now: [Standard Deployment](#4-standard-deployment) (cluster nodes have internet access) or [Air-Gapped Deployment](#5-air-gapped-deployment) (sealed nodes, no outbound internet)

---

## 2. Hardware Requirements

| Node Type | Min CPU | Min RAM | Min Disk | Count | Notes |
|---|---|---|---|---|---|
| Controller | 4 cores | 8 GB | 100 GB | 1 (3 for HA) | API server, etcd, scheduler |
| CPU Worker | 8 cores | 32 GB | 200 GB | 1+ | Weaviate, Ray head, Splunk, SAIA API, Data Loader |
| GPU Worker (L40S) | 48 vCPU | 384 GiB | 500 GB | **2 minimum** | 4× NVIDIA L40S/node, 48 GB VRAM/GPU (192 GB/node, 384 GB total across 2 nodes) · equivalent to AWS EC2 `g6e.12xlarge` (48 vCPUs, 384 GiB RAM, 4× L40S) |
| GPU Worker (H100) | 16 vCPU | 256 GiB | 500 GB | **2 minimum** | 1× NVIDIA H100/node, 80 GB HBM3/GPU (160 GB total across 2 nodes) · equivalent to AWS EC2 `p5.4xlarge` (16 vCPUs, 256 GiB RAM, 1× H100) |

Both `L40S` and `H100` are supported via `aiPlatform.defaultAcceleratorType` — pick one accelerator type per cluster, sized per the matching row above.

> A single GPU worker is not sufficient — inference is distributed across both nodes. 2× `p5.4xlarge` is a valid minimum for H100. Controller + CPU worker can share a machine for lab/test only, not production.

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
cd tools/cluster_setup
cp k0s-cluster-config.yaml my-cluster.yaml
vi my-cluster.yaml
```

| Field | Set to |
|---|---|
| `cluster.sshKeyPath` | Path to your SSH private key |
| `cluster.sshUser` | SSH user for remote nodes |
| `cluster.region` | Your region — required only if `storage.objectStore.type: aws` |
| `nodes.existingIPs.controllers` | Controller node IP(s) |
| `nodes.existingIPs.workers` | CPU + GPU worker node IPs |
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

Prepare every node (controller, CPU worker, GPU worker) before running the installer:

```bash
# On each node — confirm OS, passwordless sudo, and Python
cat /etc/os-release               # must be RHEL 9 or Ubuntu 24.04
sudo -n true && echo "passwordless sudo OK"
python3 --version                 # 3.8+

# From admin workstation — confirm SSH access to each node
ssh -i <key> <user>@<node-ip> hostname
```

> RHEL 9 and Ubuntu 24.04 are the only supported node OSes — mix and match
> freely across controllers/workers, the installer detects each node's OS
> over SSH. Any other OS is rejected at preflight (`FORCE_UNSUPPORTED_OS=1`
> bypasses this at your own risk).

**GPU worker nodes** — no manual steps needed. The installer installs the
driver automatically on internet-connected nodes — RHEL: EPEL →
`nvidia-driver:latest-dkms` (DKMS) → `nvidia-container-toolkit`; Ubuntu: CUDA
repo → `cuda-drivers` (DKMS) → `nvidia-container-toolkit` — and verifies with
`nvidia-smi` as part of `install`.

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

**Staging requirements:** 250 GB free disk, 16 GB RAM, 4 cores, stable broadband on the installer machine.

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

**Staging machine requirements:** 250 GB free disk, 16 GB RAM, 4 cores, stable broadband. Can be the same machine that runs the installer.

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
#    (container-images.txt comes from a staging run — see Model Setup above,
#    or pre-stage with --download-only first to get the list)
while IFS= read -r img; do
  [[ "$img" =~ ^# || -z "$img" ]] && continue
  crane copy "$img" "registry.airgap.local/${img##*/}"
done < container-images.txt

# 2. In your config, on top of the mandatory fields in Config Setup, set:
#    storage.modelStaging.enabled: false     (models already staged — see Model Setup above)
#    cluster.airgap: true
#    imagePullSecrets.autoCreateECR: false
#    images.registry: "registry.airgap.local"   (+ point every image at it)

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

---

## 7. Common Operations

Applies to both deployment paths — same commands for standard and air-gapped clusters.

| Task | Command |
|---|---|
| Re-run after partial failure | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install` |
| Add worker nodes | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh join-workers` |
| Re-stage models only | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts` |
| Upgrade platform | bump image tags in config, then re-run `install` (Helm upgrades in place; same command works for air-gap) |
| Collect support bundle | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh diagnose` |
| Wipe and start clean (destructive) | `./k0s_cluster_with_stack.sh clean-all` then `install` |

---

## 8. Troubleshooting

Quick hits — full symptom list: [TROUBLESHOOTING.md](../../tools/cluster_setup/TROUBLESHOOTING.md)

| Symptom | Fix |
|---|---|
| SSH connection refused | Check firewall/security group on port 22 |
| "Refusing to wipe — Ready nodes" | Set `useExisting: auto` or run `clean-all` first |
| `python3+pyyaml missing` on nodes | `dnf install -y python3-pyyaml` or set `AIRGAP_PYYAML_WHEEL_PATH` |
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
