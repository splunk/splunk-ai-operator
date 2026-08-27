# k0s Deployment — Quick Reference

One-page cheat sheet for installing the Splunk AI Platform on k0s. For full
explanations, diagrams, and edge cases see
[DEPLOYMENT_GUIDE.md](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md) and
[K0S_README.md](../../tools/cluster_setup/K0S_README.md).

## Table of Contents

1. [Step 1: Prerequisites](#step-1-prerequisites)
2. [Step 2: Hardware Requirements](#step-2-hardware-requirements)
3. [Step 3: Configure the Cluster](#step-3-configure-the-cluster)
4. [Step 4: Choose and Install a Deployment](#step-4-choose-and-install-a-deployment)
   - [Standard Deployment](#standard-deployment)
     - [Hardware Setup (Standard Path)](#hardware-setup-standard-path)
     - [Model Setup (Standard Path)](#model-setup-standard-path)
     - [Install (Standard Path)](#install-standard-path)
   - [Air-Gapped Deployment](#air-gapped-deployment)
     - [Hardware Setup (Air-Gapped Path)](#hardware-setup-air-gapped-path)
     - [Model Setup (Air-Gapped Path)](#model-setup-air-gapped-path)
     - [Install (Air-Gapped Path)](#install-air-gapped-path)
5. [Step 5: Verify](#step-5-verify)
6. [Step 6: Common Operations](#step-6-common-operations)
7. [Step 7: Troubleshooting](#step-7-troubleshooting)

---

## Step 1: Prerequisites

**Admin workstation** — the Ubuntu 24.04 or RHEL 9/10 machine you run
`k0s_cluster_with_stack.sh` from (a bastion host or the installer machine). It
needs SSH reach to every cluster node plus the CLI tools below; it is not itself
a cluster node. The binary download commands below target x86_64/amd64.

If this machine also handles model staging (downloading from HuggingFace and
uploading to MinIO/SeaweedFS/S3 — automatic during `install`, or run
standalone via `stage-artifacts`), it additionally needs:

| Resource | Minimum | Why |
|---|---|---|
| Disk (free) | 250 GB | >120 GB for 10 models + buffer for download staging and upload temp files |
| RAM | 16 GB | Scripts stream large files; less RAM causes swapping and slow uploads |
| CPU | 4 cores | Parallel upload to MinIO/SeaweedFS/S3 |
| Internet | Stable broadband | Downloads >120 GB from HuggingFace; safe to re-run — already-staged models are skipped |

**Admin workstation tools:**

Steps for setting up the tools:

<details>
<summary>Ubuntu 24.04</summary>

```bash
# Install base dependencies
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git jq openssh-client tar wget

# kubectl pinned to the same Kubernetes version as the k0s binary
curl -fsSLO https://dl.k8s.io/release/v1.36.1/bin/linux/amd64/kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# pinned to match the version this repo already relies on
sudo wget https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

# crane — used by the image-mirroring commands in Step 4; no Docker daemon,
# root, or group setup required
curl -fsSL https://github.com/google/go-containerregistry/releases/download/v0.21.9/go-containerregistry_Linux_x86_64.tar.gz -o /tmp/crane.tar.gz
tar -xzf /tmp/crane.tar.gz -C /tmp crane
sudo install -o root -g root -m 0755 /tmp/crane /usr/local/bin/crane
rm -f /tmp/crane.tar.gz /tmp/crane
```

</details>

<details>
<summary>RHEL 9/10</summary>

```bash
sudo dnf install -y ca-certificates curl git jq openssh-clients tar wget

# kubectl — official binary download (https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
# pinned to match the k0s version this repo installs by default (v1.36.1+k0s.0)
curl -fsSLO "https://dl.k8s.io/release/v1.36.1/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# helm — install script (https://helm.sh/docs/intro/install/)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# yq — pinned to match the version this repo relies on
sudo curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 -o /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

# crane — used by the image-mirroring commands below; no Docker daemon is required
curl -fsSL https://github.com/google/go-containerregistry/releases/download/v0.21.9/go-containerregistry_Linux_x86_64.tar.gz -o /tmp/crane.tar.gz
tar -xzf /tmp/crane.tar.gz -C /tmp crane
sudo install -o root -g root -m 0755 /tmp/crane /usr/local/bin/crane
rm -f /tmp/crane.tar.gz /tmp/crane

# Docker is optional; use this only if you prefer docker pull/tag/push over
# crane copy for image mirroring. Docker CE repository for RHEL:
# https://docs.docker.com/engine/install/rhel/
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"   # log out/in (or newgrp docker) to apply
```

</details>

Verify the tools once after completing the applicable Ubuntu or RHEL setup:

```bash
kubectl version --client
helm version
git --version
jq --version
yq --version
crane version
```

### Verification Matrix

| Tool | Version / Status |
| :--- | :--- |
| **`kubectl` Client** | v1.36.1 |
| **`Kustomize`** | Bundled with kubectl |
| **`helm`** | Helm 3, current stable release from the install script |
| **`git`** | Distribution-provided supported version |
| **`jq`** | Distribution-provided supported version |
| **`yq`** | v4.44.1 |
| **`crane`** | v0.21.9 |

### Pinned k0s Component Versions

| Component | Version |
|---|---|
| k0s | `v1.36.1+k0s.0` |
| kubectl | `v1.36.1` |
| yq | `v4.44.1` |
| crane | `v0.21.9` |
| cert-manager | `v1.13.0` |
| local-path-provisioner | `v0.0.24` |
| NVIDIA device plugin | `v0.17.3` |
| MetalLB chart | `0.14.8` |
| KubeRay chart | `1.2.2` |

**Access and services checklist:**

- [ ] SSH private key with access to every cluster node
- [ ] Object storage reachable from all nodes: MinIO / SeaweedFS / S3 (500 GB+ recommended)
- [ ] If air-gapped, private registry available for the platform images (standard deployments pull directly from Docker Hub)
- [ ] Decide your path now: [Standard Deployment](#standard-deployment) (cluster nodes have internet access) or [Air-Gapped Deployment](#air-gapped-deployment) (sealed nodes, no outbound internet)

Standard deployments do not require a private registry: they pull the configured
public image references directly from Docker Hub. A private registry and image
mirroring are required only when the cluster is air-gapped; the mirroring steps
are in [Step 4: Choose and Install a Deployment](#step-4-choose-and-install-a-deployment).

---

## Step 2: Hardware Requirements

Pick **one** GPU accelerator type for the cluster — `L40S` or `H100`, set via
`aiPlatform.defaultAcceleratorType` in config — and provision only the matching GPU
worker row below. The two GPU rows are alternatives, not additive; do not
provision both.

Min CPU/RAM/Disk below are **per node** — for GPU workers, multiply by the
node count to get the cluster total.

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
| Model weights | 250 GB | >120 GB for 10 models + re-staging headroom |
| Runtime data | 100 GB | Grows with usage |
| **Total bucket** | **500 GB+** | Sufficient for now |

**Supported cluster-node OS:** use one supported OS family and version across
all nodes in a cluster.

**Installer-machine OS:** for standard deployments, use Ubuntu 24.04 or RHEL
9/10. For air-gapped deployments, use an x86_64 RHEL 9 installer for RHEL 9 or
Ubuntu 24.04 clusters, and an x86_64 RHEL 10 installer for RHEL 10 clusters.

| OS | Version |
| :--- | :--- |
| **RHEL** | 9.x, 10.x |
| **Ubuntu** | 24.04 |

---

## Step 3: Configure the Cluster

Download the scripts with the configuration files on the installer machine.
### **Option 1: Setup via Git (Recommended)**

1. **Clone the Specific Branch**
   * Clone only the required branch by replacing `<branch-name>` with your given target branch:
     ```bash
     git clone -b <branch-name> --single-branch https://github.com/splunk/splunk-ai-operator.git
     ```

2. **Navigate to the Setup Directory**
   * Change into the standard repository directory structure:
     ```bash
     cd splunk-ai-operator/tools/cluster_setup
     ```

3. **Initialize Configuration File**
   * Duplicate the base template to create your working configuration:
     ```bash
     cp k0s-cluster-config.yaml my-cluster.yaml
     ```

4. **Edit Your Infrastructure Layout**
   * Open the config file in your preferred text editor to make targeted additions:
     ```bash
     vi my-cluster.yaml
     ```

---

### **Option 2: Setup via Browser ZIP Download**

1. **Grab the Specific Archive**
   * Download the ZIP archive directly using the target branch path:
     ```text
     https://github.com/splunk/splunk-ai-operator/archive/refs/heads/<branch-name>.zip
     ```
   * *Alternative via GitHub UI:* Click the **branch dropdown menu** (located top-left of the repo page next to the branch icon) and swap `main` to your targeted `<branch-name>` *before* selecting **Code → Download ZIP**.

2. **Navigate with Branch Suffix**
   * Move into the extracted folder. GitHub includes the branch name in the root folder structure (for example, `splunk-ai-operator-<branch-name>` instead of `splunk-ai-operator`):
     ```bash
     cd splunk-ai-operator-<branch-name>/tools/cluster_setup
     ```

3. **Initialize Configuration File**
   * Duplicate the template file to begin making cluster edits:
     ```bash
     cp k0s-cluster-config.yaml my-cluster.yaml
     ```

4. **Edit Your Infrastructure Layout**
   * Launch your file inside a terminal editor to change values:
     ```bash
     vi my-cluster.yaml
     ```

Review and set the following fields as applicable; all other fields have a
working default.

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
| `images.registry` | Private registry host — required only for air-gapped deployments; leave empty for standard Docker Hub pulls |
| `images.registryInsecure` | Set to `true` only for a plain-HTTP private registry; set to `false` for a secure HTTPS/TLS registry |
| `aiPlatform.defaultAcceleratorType` | `L40S` or `H100` |
| `imagePullSecrets.custom.*` | Registry credentials when the private registry requires authentication |

Validate before installing — catches most config mistakes without touching any node:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate
```

> **Air-gapped clusters need a few additional fields** (`cluster.airgap: true`,
> a private `images.registry`) — see [Air-Gapped Deployment](#air-gapped-deployment).
> Everything above still applies to air-gapped installs; pick your path below
> once this base config is filled in.

> Full field-by-field reference:
[K0S_README.md — Configuration Reference](../../tools/cluster_setup/K0S_README.md#configuration-reference).

---

## Step 4: Choose and Install a Deployment

Choose one deployment path:

- **Standard** — every cluster node has outbound internet access and pulls the
  configured public images directly from Docker Hub; no private registry is
  required.
- **Air-gapped** — cluster nodes have no outbound internet access; the installer
  machine stages the required artifacts and uses a private registry for the
  platform images.

### Standard Deployment

#### Hardware Setup (Standard Path)

Confirm every cluster node uses RHEL 9, RHEL 10, or Ubuntu 24.04 and has
passwordless sudo and Python 3.8+. Confirm SSH access from the installer
machine before running the installer. GPU driver installation is fully
automatic; no manual driver steps are needed.

#### Model Setup (Standard Path)

Model weights (>120 GB, 10 models) must land in your object store before the
AI platform can serve inference.

**Staging machine requirements:** see [Step 1: Prerequisites](#step-1-prerequisites) — same machine as the admin workstation, sized for model staging.

- **Full (interactive) install** — the installer prompts whether to download
  models. Answer yes to stage them from the installer machine, or no if they
  are already present in the object store.

#### Install (Standard Path)

```bash
cd tools/cluster_setup

CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate   # config check, run first
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install    # ~3-7h first run (model download), ~30-60min if pre-staged

# Follow progress in another terminal
tail -f logs/k0s-install-*.log
```

Continue to [Step 5: Verify](#step-5-verify).

---

### Air-Gapped Deployment

For sealed cluster nodes with no outbound internet. Everything is staged and
pushed from a single internet-connected installer machine that also has SSH
reach to the cluster nodes — there is no separate transfer/bundle step.

#### Hardware Setup (Air-Gapped Path)

**Cluster nodes** must use RHEL 9, RHEL 10, or Ubuntu 24.04. For air-gapped
staging, use a RHEL 9 x86_64 installer machine for RHEL 9 or Ubuntu 24.04
clusters, and a RHEL 10 x86_64 installer machine for RHEL 10 clusters. The
installer machine needs internet access and SSH access to every sealed node.

Install the air-gap staging dependencies on the installer machine. Install
`createrepo_c` when the GPU nodes use RHEL. Install `podman` or Docker when any
GPU node uses Ubuntu 24.04:

```bash
# RHEL installer machine
sudo dnf install -y curl createrepo_c

# Required when any GPU node uses Ubuntu 24.04; the .deb closure is built
# inside an ubuntu:24.04 container. Docker may be used instead.
sudo dnf install -y podman

# helm (if not already installed above)
curl -fsSLo /tmp/get_helm.sh \
  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 /tmp/get_helm.sh
sudo /tmp/get_helm.sh

# kubectl (if not already installed above)
curl -fsSLo /tmp/kubectl \
  "https://dl.k8s.io/release/v1.36.1/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
```

Verify everything is in place:

```bash
curl --version && helm version && kubectl version --client \
  && tar --version && ssh -V && sha256sum --version

# Run the applicable closure-tool check:
createrepo_c --version   # if any GPU node uses RHEL
podman --version         # if any GPU node uses Ubuntu 24.04

df -h /   # confirm ~5 GB free
```

Success: All required command-line dependencies (curl, helm, kubectl, tar, ssh, sha256sum, and the applicable closure tool—`createrepo_c` for RHEL GPU nodes or `podman` for Ubuntu GPU nodes) are installed and accessible. The command completes successfully (exit code 0) and prints version information for each tool.

Failure: Because the commands are chained using &&, execution stops immediately when any command is missing, inaccessible, or returns a non-zero exit code. Subsequent dependency checks will not be executed, and the overall command returns a failure status.

#### Model Setup (Air-Gapped Path)

Model weights (>120 GB, 10 models) must land in your object store before the
AI platform can serve inference.

**Staging machine requirements:** see [Step 1: Prerequisites](#step-1-prerequisites) — same machine as the admin workstation, sized for model staging.

- **Full (interactive) install** — the installer prompts whether to download
  models. Answer yes to stage them from the installer machine, or no if they
  are already present in the object store.

#### Install (Air-Gapped Path)

One entry point, same install command as the standard path — the config's
`cluster.airgap: true` (or `AIRGAP_MODE=true`) is what switches the mode.

Before running install, mirror the platform application images to your private
registry.

Mirror every application image used by the deployment. The release images below
use the common tag `v1.0`; supporting images retain the versions from the
configuration file. Set every applicable `images.*` field to its mirrored path.

With `crane` (no Docker daemon required):

```bash
REGISTRY="my-custom-registry.io"

for image in \
  docker.io/splunk/ai-tier-saia-data-loader:v1.0 \
  docker.io/splunk/ai-tier-saia-api-v2:v1.0 \
  docker.io/splunk/ai-tier-saia-api:v1.0 \
  docker.io/splunk/ai-tier-ray-head:v1.0 \
  docker.io/splunk/ai-tier-ray-worker:v1.0 \
  docker.io/kpratyush775/splunk-ai-operator:v1.0 \
  docker.io/splunk/ai-tier-slim-service:v1.0 \
  docker.io/splunk/splunk:10.2-rhel9 \
  docker.io/splunk/splunk-operator:3.0.0 \
  docker.io/semitechnologies/weaviate:stable-v1.28-007846a \
  docker.io/otel/opentelemetry-collector-contrib:0.122.1 \
  docker.io/fluent/fluent-bit:1.9.6 \
  docker.io/library/nginx:1.27-alpine; do
    relative_image="${image#docker.io/}"
    crane copy "${image}" "${REGISTRY}/${relative_image}"
done
```

With Docker instead:

```bash
REGISTRY="my-custom-registry.io"

for image in \
  docker.io/splunk/ai-tier-saia-data-loader:v1.0 \
  docker.io/splunk/ai-tier-saia-api-v2:v1.0 \
  docker.io/splunk/ai-tier-saia-api:v1.0 \
  docker.io/splunk/ai-tier-ray-head:v1.0 \
  docker.io/splunk/ai-tier-ray-worker:v1.0 \
  docker.io/kpratyush775/splunk-ai-operator:v1.0 \
  docker.io/splunk/ai-tier-slim-service:v1.0 \
  docker.io/splunk/splunk:10.2-rhel9 \
  docker.io/splunk/splunk-operator:3.0.0 \
  docker.io/semitechnologies/weaviate:stable-v1.28-007846a \
  docker.io/otel/opentelemetry-collector-contrib:0.122.1 \
  docker.io/fluent/fluent-bit:1.9.6 \
  docker.io/library/nginx:1.27-alpine; do
    relative_image="${image#docker.io/}"
    docker pull "${image}"
    docker tag "${image}" "${REGISTRY}/${relative_image}"
    docker push "${REGISTRY}/${relative_image}"
done
```

After mirroring, replace every applicable `images.*` field, including the
Splunk, Splunk Operator, Weaviate, Fluent Bit, OpenTelemetry Collector, and
nginx image fields, with the corresponding private-registry paths. The
release-image paths use `v1.0`; preserve the configured tags for supporting
images.

For a plain-HTTP private registry, such as the sample address `192.0.2.10:5000`, configure:

```yaml
images:
  registry: "192.0.2.10:5000"
  registryInsecure: true
```

Set `registryInsecure: false` for a secure HTTPS/TLS private registry. The
setting tells the installer whether to configure containerd for HTTP or HTTPS.

```bash
cd tools/cluster_setup

# 1. In your config, on top of the fields in Config Setup, set:
#    cluster.airgap: true
#    images.registry: "registry.airgap.local"   (+ point every image at it)
#    images.registryInsecure: true                # plain HTTP only; use false for HTTPS/TLS
#
#    If registry.airgap.local requires authentication (Harbor, etc.), also set:
#    imagePullSecrets.custom.enabled: true
#    imagePullSecrets.custom.name: "custom-registry-secret"
#    imagePullSecrets.custom.server: "registry.airgap.local"
#    imagePullSecrets.custom.username / .password: your registry credentials

# 2. Run the install — stages ~2.2 GB of artifacts (~15 min, plus model
#    staging time if storage.modelStaging.enabled: true) then installs
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

Continue to [Step 5: Verify](#step-5-verify).

---

## Step 5: Verify

Applies to both standard and air-gapped deployment paths.

```bash
# For getting the status of the pods and inference endpoints
cd tools/cluster_setup
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh verify-pods

# Run kubectl commands directly from the installer machine
export KUBECONFIG=~/.kube/k0s-<cluster-name>

kubectl get nodes -o wide                                          # all Ready
kubectl get pods -A --sort-by=.metadata.namespace                  # all Running/Completed
kubectl get aiplatform -n ai-platform -o wide                      # Ready
kubectl get svc -n ai-platform -l app.kubernetes.io/component=saia # NodePort: use worker-ip:30080
kubectl get nodes -l splunk.ai/workload-type=gpu -o yaml | grep nvidia.com/gpu
# → nvidia.com/gpu: "<count>" under both capacity and allocatable, per GPU node
```

**Access the in-cluster Splunk instance and set up the SAIA app:**
[K0S_README.md — Finding the Splunk Web URL](../../tools/cluster_setup/K0S_README.md#finding-the-splunk-web-url).
Use NodePort, LoadBalancer, or `kubectl port-forward` as described there. If
your browser cannot reach the cluster network directly, use
[Remote workstation via SSH bastion (SOCKS tunnel)](../../tools/cluster_setup/K0S_README.md#finding-the-splunk-web-url).
Then follow [DEPLOYMENT_GUIDE.md — Install the Splunk AI Assistant App](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#install-the-splunk-ai-assistant-app).

> **Using an external, self-managed Splunk Enterprise instance for JWT authentication?**
> See
> [EXTERNAL_SPLUNK_INTEGRATION.md](../../tools/cluster_setup/EXTERNAL_SPLUNK_INTEGRATION.md).

---

## Step 6: Common Operations

Applies to both deployment paths — same commands for standard and air-gapped clusters.

| Task | Command |
|---|---|
| Re-run after partial failure | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install` |
| Add worker nodes | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh join-workers` |
| Re-stage models only | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts` |
| Refresh platform image tags (engineering-validated behavior) | bump image tags in config, then re-run `install`; existing Helm releases are refreshed in place |
| Refresh image tags (air-gapped engineering validation) | **first** mirror each changed image at its new tag to your internal registry (`install` never does this for you), **then** bump the tag in config and re-run `install` — otherwise sealed nodes hit `ImagePullBackOff` on the new tag |
| Collect support bundle | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh diagnose` |
| Wipe and start clean (destructive) | `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh clean-all` then `CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install` |

---

## Step 7: Troubleshooting

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
| SAIA service is unreachable | For the default NodePort, use `<worker-ip>:30080`; for LoadBalancer, check MetalLB: `kubectl get pods -n metallb-system` |
| AIPlatform CR stuck `Pending` | `kubectl describe aiplatform -n ai-platform`; check operator logs + GPU availability |

---

*Quick reference — see [DEPLOYMENT_GUIDE.md](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md) for the full walkthrough.*
