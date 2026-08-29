# k0s Deployment — Quick Reference

Quick reference for installing the Splunk AI Platform on k0s. For full
explanations, diagrams, and edge cases, see
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
     - [Air-Gapped Step 1: Confirm Prerequisites](#air-gapped-step-1-confirm-prerequisites)
     - [Air-Gapped Step 2: Prepare the Configuration](#air-gapped-step-2-prepare-the-configuration)
     - [Air-Gapped Step 3: Configure the Private Registry](#air-gapped-step-3-configure-the-private-registry)
     - [Air-Gapped Step 4: Mirror Application Images](#air-gapped-step-4-mirror-application-images)
     - [Air-Gapped Step 5: Stage Model Artifacts](#air-gapped-step-5-stage-model-artifacts)
     - [Air-Gapped Step 6: Validate the Configuration](#air-gapped-step-6-validate-the-configuration)
     - [Air-Gapped Step 7: Install the Platform](#air-gapped-step-7-install-the-platform)
     - [Air-Gapped Step 8: Monitor and Verify](#air-gapped-step-8-monitor-and-verify)
5. [Step 5: Splunk Integration](#step-5-splunk-integration)
6. [Step 6: Common Operations](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#common-operations)
7. [Step 7: Troubleshooting](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#troubleshooting)

---

## Step 1: Prerequisites

**Installer machine** — Ubuntu 24.04, RHEL 9.8, or RHEL 10.2, x86_64/amd64, with SSH
access to every cluster node and the CLI tools below. Run commands locally or
SSH into the machine first if it is remote; it is separate from the cluster
nodes.

If it also stages models from Hugging Face to MinIO/SeaweedFS/S3, it additionally
needs:

| Resource | Minimum | Why |
|---|---|---|
| Disk (free) | 250 GB | >120 GB for 10 models + buffer for download staging and upload temp files |
| RAM | 16 GB | Scripts stream large files; less RAM causes swapping and slow uploads |
| CPU | 4 cores | Parallel upload to MinIO/SeaweedFS/S3 |
| Internet | Stable broadband | Downloads >120 GB from HuggingFace; safe to re-run — already-staged models are skipped |

**Installer machine tools:**

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
<summary>RHEL 9.8 / 10.2</summary>

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

Success: each command prints version information and exits successfully.

**Access and services checklist:**

- [ ] SSH private key with access to every cluster node
- [ ] Object storage reachable from all nodes: MinIO / SeaweedFS / S3 (500 GB+ recommended)
- [ ] If air-gapped, private registry available for the platform images (standard deployments pull directly from Docker Hub)
- [ ] Decide your path now: [Standard Deployment](#standard-deployment) (cluster nodes have internet access) or [Air-Gapped Deployment](#air-gapped-deployment) (sealed nodes, no outbound internet)

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

**Installer machine OS:** for standard deployments, use Ubuntu 24.04 or RHEL
9.8/10.2. For air-gapped deployments, use an x86_64 RHEL 9.8 installer machine
for RHEL 9.8 or Ubuntu 24.04 clusters, and an x86_64 RHEL 10.2 installer
machine for RHEL 10.2 clusters.

| OS | Version |
| :--- | :--- |
| **RHEL** | 9.8, 10.2 |
| **Ubuntu** | 24.04 |

---

## Step 3: Configure the Cluster

Download the scripts with the configuration files on the installer machine.

<details>
<summary><strong>Option 1: Setup via Git (Recommended)</strong></summary>

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
     # Standard deployment
     cp k0s-cluster-config.yaml my-cluster.yaml
     # For air-gapped deployment, use this instead:
     # cp k0s-airgapped-config.yaml my-cluster.yaml
     ```

4. **Edit Your Infrastructure Layout**
   * Open the config file in your preferred text editor to make targeted additions:
     ```bash
     vi my-cluster.yaml
     chmod 600 /path/to/private-key     
     ```

</details>

<details>
<summary><strong>Option 2: Setup via Browser ZIP Download</strong></summary>

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
     # Standard deployment
     cp k0s-cluster-config.yaml my-cluster.yaml
     # For air-gapped deployment, use this instead:
     # cp k0s-airgapped-config.yaml my-cluster.yaml
     ```

4. **Edit Your Infrastructure Layout**
   * Launch your file inside a terminal editor to change values:
     ```bash
     vi my-cluster.yaml
     chmod 600 /path/to/private-key
     ```

</details>

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

The air-gapped template already enables air-gap mode and defines relative image
paths for the private registry.

### Required: Validate the Configuration

This step is required. Validate the configuration you will install before
choosing a deployment path. Validation checks the configuration without
modifying any cluster node.

```bash
# Validate the selected deployment config.
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

- **[Standard](#standard-deployment)** — every cluster node has outbound
  internet access and pulls the configured public images directly from Docker
  Hub; no private registry is required.
- **[Air-gapped](#air-gapped-deployment)** — cluster nodes have no outbound
  internet access; the installer machine stages the required artifacts and uses
  a private registry for the platform images.

<details>
<summary>Standard Deployment</summary>

### Standard Deployment

#### Hardware Setup (Standard Path)

For a tested deployment, use RHEL 9.8, RHEL 10.2, or Ubuntu 24.04 on
every cluster node and confirm that each node has
passwordless sudo and Python 3.8+. Confirm SSH access from the installer
machine before running the installer. GPU driver installation is fully
automatic; no manual driver steps are needed.

#### Model Setup (Standard Path)

Model weights (>120 GB, 10 models) must land in your object store before the
AI platform can serve inference.

**Installer machine requirements:** see [Step 1: Prerequisites](#step-1-prerequisites) — use the installer machine for model staging.

- **Full (interactive) install** — the installer prompts whether to download
  models. Answer yes to stage them from the installer machine, or no if they
  are already present in the object store.

#### Install (Standard Path)

```bash
cd tools/cluster_setup

# Required: validation must succeed before install
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate

# Run only after validate completes successfully
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install    # ~3-7h first run (model download), ~30-60min if pre-staged

# Check the status of pods and inference endpoints
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh verify-pods

# Follow progress in another terminal
tail -f logs/k0s-install-*.log
```

Continue to [Step 5: Splunk Integration](#step-5-splunk-integration).

---

</details>

<details>
<summary>Air-Gapped Deployment</summary>

### Air-Gapped Deployment

For sealed cluster nodes with no outbound internet. Everything is staged and
pushed from a single internet-connected installer machine that also has SSH
reach to the cluster nodes — there is no separate transfer/bundle step.

#### Air-Gapped Step 1: Confirm Prerequisites

Use the requirements in [Step 1: Prerequisites](#step-1-prerequisites) and
[Step 2: Hardware Requirements](#step-2-hardware-requirements). For air-gapped
staging, use a RHEL 9.8 installer machine for RHEL 9.8 or Ubuntu 24.04
clusters, and a RHEL 10.2 installer machine for RHEL 10.2 clusters. The
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

Verify the air-gap dependencies:

```bash
curl --version && helm version && kubectl version --client \
  && tar --version && ssh -V && sha256sum --version

# Run the applicable closure-tool check:
createrepo_c --version   # if any GPU node uses RHEL
podman --version         # if any GPU node uses Ubuntu 24.04

df -h /   # confirm ~5 GB free
```

#### Air-Gapped Step 2: Prepare the Configuration

Use `k0s-airgapped-config.yaml` as the template. If you have not already
created the working configuration in Step 3, copy it now:

```bash
cp k0s-airgapped-config.yaml my-cluster.yaml
```

Edit `my-cluster.yaml`, keep `cluster.airgap: true`, and complete the cluster,
node, object-store, and SSH settings. Leave the relative image paths unchanged;
the installer prefixes them with `images.registry`.

#### Air-Gapped Step 3: Configure the Private Registry

Set only your private registry in `my-cluster.yaml` before mirroring images:

```yaml
images:
  registry: registry.example.com  # replace with your private registry
  registryInsecure: true         # false only for HTTPS/TLS
```

If the registry requires authentication, also configure
`imagePullSecrets.custom.*` in `my-cluster.yaml`. The registry value used by
the mirroring commands must match `images.registry`.

#### Air-Gapped Step 4: Mirror Application Images

Run one of the following methods from the installer machine. The commands use
release `v1.0` images and the configured supporting-image tags. Replace
`registry.example.com` with the same private registry set above.

<details>
<summary>Mirror with crane (no Docker daemon required)</summary>

```bash
REGISTRY="registry.example.com" # Must match images.registry in the config

for image in \
  docker.io/splunk/ai-tier-saia-data-loader:v1.0 \
  docker.io/splunk/ai-tier-saia-api-v2:v1.0 \
  docker.io/splunk/ai-tier-saia-api:v1.0 \
  docker.io/splunk/ai-tier-ray-head:v1.0 \
  docker.io/splunk/ai-tier-ray-worker:v1.0 \
  docker.io/splunk/splunk-ai-operator:v1.0 \
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

</details>

<details>
<summary>Mirror with Docker</summary>

```bash
REGISTRY="registry.example.com" # Must match images.registry in the config

for image in \
  docker.io/splunk/ai-tier-saia-data-loader:v1.0 \
  docker.io/splunk/ai-tier-saia-api-v2:v1.0 \
  docker.io/splunk/ai-tier-saia-api:v1.0 \
  docker.io/splunk/ai-tier-ray-head:v1.0 \
  docker.io/splunk/ai-tier-ray-worker:v1.0 \
  docker.io/splunk/splunk-ai-operator:v1.0 \
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

</details>

#### Air-Gapped Step 5: Stage Model Artifacts

Model weights (>120 GB, 10 models) must land in your object store before the
AI platform can serve inference. During the full interactive install, answer
yes when prompted to stage models from the installer machine, or no if they are
already present in the object store.

#### Air-Gapped Step 6: Validate the Configuration

Run validation from the setup directory and fix any reported errors before
continuing:

```bash
cd tools/cluster_setup
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate
```

#### Air-Gapped Step 7: Install the Platform

The install command stages the required offline k0s and GPU-driver artifacts
from the installer machine, then installs the platform on the sealed nodes:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

#### Air-Gapped Step 8: Monitor and Verify

Optional: Follow the installation log from another terminal while the install runs:

```bash
tail -f logs/k0s-install-*.log
```

After the install completes, check the pods and inference endpoints:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh verify-pods
```

Continue to [Step 5: Splunk Integration](#step-5-splunk-integration).

---

</details>

## Step 5: Splunk Integration

Splunk Enterprise **10.2** is the tested version for both internal/bundled and
external Splunk. The bundled deployment uses
`docker.io/splunk/splunk:10.2-rhel9`; use the corresponding private-registry
path for air-gapped deployments.

<details>
<summary>Internal Splunk</summary>

For the bundled in-cluster Splunk instance, use NodePort, LoadBalancer, or
`kubectl port-forward` as described in [K0S_README.md — Finding the Splunk Web
URL](../../tools/cluster_setup/K0S_README.md#finding-the-splunk-web-url). If
your browser cannot reach the cluster network directly, use the [SSH bastion
SOCKS tunnel](../../tools/cluster_setup/K0S_README.md#finding-the-splunk-web-url).
Then follow [DEPLOYMENT_GUIDE.md — Install the Splunk AI Assistant
App](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#install-the-splunk-ai-assistant-app).

</details>

<details>
<summary>External Splunk</summary>

For a self-managed Splunk Enterprise instance outside the cluster, configure
JWT authentication as described in
[EXTERNAL_SPLUNK_INTEGRATION.md](../../tools/cluster_setup/EXTERNAL_SPLUNK_INTEGRATION.md).

</details>

---

## Step 6: Common Operations

See [Deployment Guide — Common Operations](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#common-operations)
for re-runs, worker management, model staging, image refreshes, support
bundles, and cleanup commands.

---

## Step 7: Troubleshooting

See [Deployment Guide — Troubleshooting](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#troubleshooting)
for diagnosis steps, decision trees, and the complete symptom reference.

---

*Quick reference — see [DEPLOYMENT_GUIDE.md](../../tools/cluster_setup/DEPLOYMENT_GUIDE.md) for the full walkthrough.*
