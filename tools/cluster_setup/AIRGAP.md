# Air-Gap Installation Guide

Complete guide for deploying the Splunk AI Platform in environments with no
outbound internet access from the cluster nodes or the install machine.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Step 1 — Build the Bundle (internet-connected machine)](#step-1--build-the-bundle-internet-connected-machine)
- [Step 2 — Mirror Container Images](#step-2--mirror-container-images)
- [Step 3 — Stage Model Weights](#step-3--stage-model-weights)
- [Step 4 — Transfer Files to the Air-Gapped Environment](#step-4--transfer-files-to-the-air-gapped-environment)
- [Step 5 — Install from the Bundle](#step-5--install-from-the-bundle)
- [GPU Node OS Packages](#gpu-node-os-packages)
- [Environment Variable Reference](#environment-variable-reference)
- [Partial Air-Gap (Mirror One Component)](#partial-air-gap-mirror-one-component)
- [Troubleshooting](#troubleshooting)

---

## Overview

The standard installer (`k0s_cluster_with_stack.sh`) downloads binaries, Helm
charts, and Kubernetes manifests from the internet at install time. In an
air-gapped environment none of that is reachable.

Two helper scripts bridge the gap:

| Script | Where to run | What it does |
|---|---|---|
| `prepare_airgap_bundle.sh` | Internet-connected machine | Downloads every binary, chart, and manifest into a versioned `.tar.gz` bundle |
| `install_from_airgap_bundle.sh` | Air-gapped install machine | Extracts the bundle, sets env-var overrides, invokes the main installer |

The main installer itself has no hardcoded download logic — every URL is
overridable via environment variables. `install_from_airgap_bundle.sh` sets
all of them automatically.

---

## Prerequisites

### Internet-connected machine (bundle preparation)

| Tool | Install |
|---|---|
| `curl` | `brew install curl` / `apt install curl` |
| `helm` | https://helm.sh/docs/intro/install/ |
| `tar` | pre-installed on most systems |
| `sha256sum` or `shasum` | pre-installed (Linux / macOS) |

### Air-gapped install machine

| Tool | How to get it |
|---|---|
| `kubectl` | Pre-install or copy from a connected machine |
| `helm` | Pre-install or copy from a connected machine |
| `tar` | Pre-installed on most systems |
| `ssh` | Pre-installed on most systems |
| `k0s` | Bundled — the install script copies it automatically |
| `yq` | Bundled — the install script copies it automatically |

### Cluster nodes

The same prerequisites as a normal k0s install apply (passwordless sudo, SSH
access, 500 GB free on GPU workers). The nodes need no internet access — k0s
and any required OS packages must be handled before or separately from this
flow.

> **NVIDIA drivers**: The installer detects and skips driver installation if
> `nvidia-smi` is already present. For air-gapped GPU nodes, pre-install NVIDIA
> drivers (and `nvidia-container-toolkit`) using a local package mirror or RPM/DEB
> files before running this script. See the [GPU section of K0S_README.md](K0S_README.md#nvidia-gpu-support).

---

## Step 1 — Build the Bundle (internet-connected machine)

```bash
cd tools/cluster_setup
./prepare_airgap_bundle.sh --output-dir /mnt/transfer
```

The script downloads and packages:

| Category | Contents |
|---|---|
| Binaries | `k0s` (latest stable or `--k0s-version`), `yq v4.44.1` |
| Manifests | `cert-manager v1.13.0`, `local-path-provisioner v0.0.24`, `nvidia-device-plugin v0.17.3` |
| Helm charts | `kube-prometheus-stack` (latest, version captured at bundle time), `opentelemetry-operator` (latest, captured), `kuberay-operator 1.2.2`, `metallb 0.14.8` |
| Metadata | `bundle-versions.txt`, `container-images.txt`, `airgap-env.sh`, `checksums.sha256` |

Output: `/mnt/transfer/airgap-bundle-<timestamp>.tar.gz`

### Options

```
--output-dir DIR       Where to write the bundle  (env: OUTPUT_DIR)
--k0s-version VER      Specific k0s version        (env: K0S_VERSION)
```

Run `./prepare_airgap_bundle.sh --help` for full details.

### Why chart versions are captured at bundle time

`kube-prometheus-stack` and `opentelemetry-operator` are not pinned in the
installer — they install the latest available chart. The bundle script resolves
and records those versions at download time so the air-gapped install uses
exactly the charts that were tested.

---

## Step 2 — Mirror Container Images

The bundle does **not** contain container images (they would add many GB).
You must mirror them into an internal registry that the cluster nodes can reach.

The bundle includes a ready-made image list:

```bash
# After extracting the bundle (or before packing it)
cat /mnt/transfer/airgap-bundle-*/container-images.txt
```

### Mirror with `crane` (recommended)

```bash
INTERNAL_REGISTRY="registry.airgap.local"

while IFS= read -r img; do
  [[ "$img" =~ ^# ]] && continue
  [[ -z "$img" ]] && continue
  dest="${INTERNAL_REGISTRY}/${img##*/}"
  echo "Copying $img → $dest"
  crane copy "$img" "$dest"
done < container-images.txt
```

### Mirror with Docker

```bash
INTERNAL_REGISTRY="registry.airgap.local"
IMAGE="docker.io/semitechnologies/weaviate:stable-v1.28-007846a"

docker pull "$IMAGE"
docker tag "$IMAGE" "${INTERNAL_REGISTRY}/weaviate:stable-v1.28-007846a"
docker push "${INTERNAL_REGISTRY}/weaviate:stable-v1.28-007846a"
```

### Configure the installer to use your registry

In your `k0s-cluster-config.yaml`:

```yaml
images:
  registry: "registry.airgap.local"   # prefix applied to all images

  operator:
    image: "registry.airgap.local/splunk-ai-operator:latest"
  splunk:
    image: "registry.airgap.local/splunk:10.2.0"
    operatorImage: "registry.airgap.local/splunk-operator:3.0.0"
  # ... all other image fields pointing at your internal registry

imagePullSecrets:
  secrets:
    - internal-registry-secret
  autoCreateECR: false   # disable automatic ECR token refresh
```

---

## Step 3 — Stage Model Weights

Model weights (~60 GB total) are not included in the binary bundle. They must
be staged separately into your object store.

**System requirements for the staging machine:**

| Resource | Minimum | Notes |
|---|---|---|
| Disk (free) | 250 GB | ~60 GB for 10 model weight files + 200 GB working buffer |
| RAM | 16 GB | Needed to stream and process large files without swapping |
| Internet | Stable broadband | Downloads ~60 GB from HuggingFace; resume with `SKIP_IF_EXISTS=1` |

This can be the same machine used to build the airgap bundle.

On the internet-connected machine:

```bash
cd tools/artifacts_download_upload_scripts
# Edit download_from_huggingface.sh to set HF_TOKEN and target bucket
./download_from_huggingface.sh
./upload_to_s3.sh
```

See [artifacts/README.md](../artifacts_download_upload_scripts/README.md) for full instructions.

For air-gapped object stores, upload directly to your MinIO or S3-compatible
endpoint — the upload scripts respect the endpoint configured in your cluster
config.

Disable automatic model staging in `k0s-cluster-config.yaml` if you have
already staged the models:

```yaml
storage:
  modelStaging:
    enabled: false
```

---

## Step 4 — Transfer Files to the Air-Gapped Environment

```bash
# Copy bundle
scp /mnt/transfer/airgap-bundle-<timestamp>.tar.gz admin@install-machine:/opt/

# Copy installer scripts (if not already on the machine)
scp tools/cluster_setup/k0s_cluster_with_stack.sh \
    tools/cluster_setup/install_from_airgap_bundle.sh \
    tools/cluster_setup/k0s-cluster-config.yaml \
    admin@install-machine:/opt/splunk-ai/

# Copy your edited cluster config
scp my-cluster-config.yaml admin@install-machine:/opt/splunk-ai/
```

---

## Step 5 — Install from the Bundle

### Configure air-gap mode in your cluster config

Add `cluster.airgap: true` to your `k0s-cluster-config.yaml`. This is the recommended way to configure air-gap mode — it is version-controlled alongside your cluster config and requires no additional env vars each run.

```yaml
cluster:
  name: my-cluster
  airgap: true        # tells the installer this environment has no outbound internet
  sshKeyPath: ~/.ssh/id_rsa
  sshUser: ec2-user
```

> **Why this matters:** without `airgap: true`, the installer will attempt connectivity checks to HuggingFace and NVIDIA package repos before skipping them. Those checks will pause for up to 5 minutes waiting for unreachable hosts before timing out. Setting `airgap: true` skips them immediately.

> **`install_from_airgap_bundle.sh` sets `AIRGAP_MODE=true` automatically** via environment variable. You only need `cluster.airgap: true` in your YAML if you ever run `k0s_cluster_with_stack.sh` directly (without going through the bundle installer).

### Run the installer

On the air-gapped install machine:

```bash
cd /opt/splunk-ai
chmod +x install_from_airgap_bundle.sh k0s_cluster_with_stack.sh

./install_from_airgap_bundle.sh \
  --bundle /opt/airgap-bundle-<timestamp>.tar.gz \
  --config /opt/splunk-ai/my-cluster-config.yaml
```

The script:
1. Extracts the bundle to `/opt/airgap` (override with `--extract-dir`)
2. Verifies SHA-256 checksums
3. Installs `k0s` and `yq` from the bundle
4. Registers a local Helm repository from the bundled `.tgz` files
5. Sets all env-var overrides including `AIRGAP_MODE=true` (see [Environment Variable Reference](#environment-variable-reference))
6. Runs `k0s_cluster_with_stack.sh install`

The install plan displayed before install starts will show `Air-gap mode: true` — confirm this before proceeding.

Run `./install_from_airgap_bundle.sh --help` for full flag reference.

### Running an upgrade

```bash
./install_from_airgap_bundle.sh \
  --bundle /opt/airgap-bundle-<new-timestamp>.tar.gz \
  --config /opt/splunk-ai/my-cluster-config.yaml \
  --subcommand upgrade
```

---

---

## GPU Node OS Packages

The main installer SSHes into cluster nodes and installs OS packages at runtime.
In an air-gapped environment those package downloads will fail unless the nodes
have internet access, a local package mirror is configured, or the packages are
pre-installed.

### Which packages are internet-dependent

| Package | Node type | Repo source |
|---|---|---|
| `python3-pyyaml` / `python3-yaml` | All nodes | Default OS repo (dnf/apt) |
| `kernel-devel`, `kernel-headers` | GPU workers | Default OS repo / RHUI |
| `dnf-plugins-core` | GPU workers (RHEL/AL2023) | Default OS repo |
| `epel-release` RPM | GPU workers (RHEL/AL2023) | `dl.fedoraproject.org/pub/epel/` |
| `dkms`, `gcc`, `make`, `elfutils-libelf-devel` | GPU workers | EPEL repo |
| CUDA repo `.repo` file | GPU workers | `developer.download.nvidia.com` |
| `cuda-drivers` / `nvidia-open` | GPU workers | CUDA repo |
| `nvidia-container-toolkit` | GPU workers | `nvidia.github.io/libnvidia-container` |

### Strategies

**Strategy 1 — Pre-install before running the installer (simplest)**

Pre-install NVIDIA drivers and nvidia-container-toolkit on GPU nodes before
running `install_from_airgap_bundle.sh`. The installer detects `nvidia-smi` at
runtime and skips the driver installation entirely.

The bundle includes package files to assist:

```bash
# On each GPU node (copy from the bundle machine first):
BUNDLE_PKGS=/opt/airgap/airgap-bundle-<date>/packages

# 1. Install EPEL (RHEL/AL2023 only — provides DKMS)
sudo dnf install -y "${BUNDLE_PKGS}/epel-release-latest-9.noarch.rpm"

# 2. Enable EPEL and install the build toolchain + DKMS
sudo dnf install -y dkms gcc make elfutils-libelf-devel kernel-devel-$(uname -r)

# 3. Add the CUDA repo (repo file only — still fetches RPMs from NVIDIA CDN
#    unless you set up a local mirror; see Strategy 2 below)
sudo cp "${BUNDLE_PKGS}/cuda-rhel9.repo" /etc/yum.repos.d/
sudo dnf install -y cuda-drivers

# 4. Add the nvidia-container-toolkit repo and install
sudo cp "${BUNDLE_PKGS}/nvidia-container-toolkit.repo" /etc/yum.repos.d/
sudo dnf install -y nvidia-container-toolkit
```

After this, run the installer normally — it will detect `nvidia-smi` and skip
driver installation:

```bash
./install_from_airgap_bundle.sh \
  --bundle /opt/airgap-bundle-<date>.tar.gz \
  --config my-cluster-config.yaml
```

> **For python3-pyyaml on all nodes:** The bundle includes a `packages/PyYAML-*.whl`
> file. `install_from_airgap_bundle.sh` sets `AIRGAP_PYYAML_WHEEL_PATH` automatically
> so the installer uses it instead of calling `dnf install python3-pyyaml`.

**Strategy 2 — Local RPM/DEB mirror (for organizations with many nodes)**

Set up an internal mirror of the OS repos and redirect the installer to it via
environment variables. This is the most robust option for large fleets.

```bash
# Example: reposync CUDA repo to an internal HTTP server
reposync --repoid cuda-rhel9-x86_64 --download-path /var/www/html/cuda/

# Then export before running the installer:
export CUDA_REPO_URL_OVERRIDE="http://mirror.internal/cuda/cuda-rhel9.repo"
export EPEL_RPM_URL_OVERRIDE="http://mirror.internal/epel/epel-release-latest-9.noarch.rpm"
export NVIDIA_CTK_REPO_URL_OVERRIDE="http://mirror.internal/nvidia-ctk/nvidia-container-toolkit.repo"

./install_from_airgap_bundle.sh --bundle ... --config ...
```

For Debian/Ubuntu GPU nodes the CUDA and CTK overrides accept a URL to the `.list`
file or keyring `.deb` used during apt setup (same `${VAR:-default}` pattern).

**Strategy 3 — Partial air-gap: GPU nodes have controlled internet access**

If the GPU nodes can reach NVIDIA's package servers but the control plane /
install machine cannot, set `AIRGAP_MODE=true` in your config (to skip
HuggingFace checks) while leaving the GPU node driver install unblocked. The
`wait_for_dependency()` check in the installer will pause for you to confirm
connectivity before each GPU node install.

### Environment variables for package URL overrides

| Variable | Default URL | What it controls |
|---|---|---|
| `EPEL_RPM_URL_OVERRIDE` | `dl.fedoraproject.org/pub/epel/epel-release-latest-N.noarch.rpm` | EPEL release RPM for DKMS |
| `CUDA_REPO_URL_OVERRIDE` | NVIDIA CUDA repo URL for the detected OS | CUDA package repo definition |
| `NVIDIA_CTK_REPO_URL_OVERRIDE` | `nvidia.github.io/.../nvidia-container-toolkit.repo` | nvidia-container-toolkit repo |
| `AIRGAP_PYYAML_WHEEL_PATH` | _(not set)_ | Path to PyYAML `.whl` for offline pip3 install |

---

## Environment Variable Reference

These variables are set automatically by `install_from_airgap_bundle.sh`.
You only need to set them manually if you extracted the bundle yourself or want
to override a single component without using the full bundle workflow.

### Binary URLs

| Variable | Default (online) | Air-gap usage |
|---|---|---|
| `K0S_INSTALL_URL` | `https://get.k0s.sh` | `file:///opt/airgap/bundle/binaries/k0s` |
| `YQ_DOWNLOAD_URL` | GitHub releases URL | `file:///opt/airgap/bundle/binaries/yq` |

### Manifest URLs

| Variable | Default (online) | Air-gap usage |
|---|---|---|
| `CERT_MANAGER_MANIFEST_URL` | GitHub cert-manager release URL | `file:///opt/airgap/bundle/manifests/cert-manager.yaml` |
| `LOCAL_PATH_MANIFEST_URL` | GitHub rancher/local-path-provisioner URL | `file:///opt/airgap/bundle/manifests/local-path-storage.yaml` |
| `NVIDIA_DEVICE_PLUGIN_MANIFEST_URL` | GitHub NVIDIA/k8s-device-plugin URL | `file:///opt/airgap/bundle/manifests/nvidia-device-plugin.yml` |

### Helm Chart Paths

When set to a local `.tgz` path, the installer skips `helm repo add` /
`helm repo update` entirely and installs directly from the file.

| Variable | Default (online) | Air-gap usage |
|---|---|---|
| `PROMETHEUS_CHART_PATH` | _(not set — uses remote repo)_ | `/opt/airgap/bundle/charts/kube-prometheus-stack-<ver>.tgz` |
| `OTEL_CHART_PATH` | _(not set — uses remote repo)_ | `/opt/airgap/bundle/charts/opentelemetry-operator-<ver>.tgz` |
| `KUBERAY_CHART_PATH` | _(not set — uses remote repo)_ | `/opt/airgap/bundle/charts/kuberay-operator-1.2.2.tgz` |
| `METALLB_CHART_PATH` | _(not set — uses remote repo)_ | `/opt/airgap/bundle/charts/metallb-0.14.8.tgz` |

### GPU Node OS Package URLs

These override the internet URLs used when the installer installs OS packages
on GPU worker nodes. Set them to point at a local HTTP mirror or a `file://` path.

| Variable | Default URL | Package |
|---|---|---|
| `EPEL_RPM_URL_OVERRIDE` | `dl.fedoraproject.org/pub/epel/epel-release-latest-N.noarch.rpm` | EPEL RPM (provides DKMS) |
| `CUDA_REPO_URL_OVERRIDE` | NVIDIA CUDA repo for detected OS | CUDA repository definition |
| `NVIDIA_CTK_REPO_URL_OVERRIDE` | `nvidia.github.io/.../nvidia-container-toolkit.repo` | nvidia-container-toolkit repo |
| `AIRGAP_PYYAML_WHEEL_PATH` | _(not set)_ | Path to PyYAML `.whl` for offline pip3 (all nodes) |

### Other

| Variable | Default | Description |
|---|---|---|
| `AIRGAP_BUNDLE_DIR` | _(not set)_ | Set to the extracted bundle directory. Used by `airgap-env.sh` for manual installs. |
| `AIRGAP_MODE` | `false` | Set to `true` by `install_from_airgap_bundle.sh`, or loaded from `cluster.airgap` in the config YAML. Skips HuggingFace and NVIDIA repo connectivity checks; object store check is preserved. Env var takes precedence over YAML. |

### Manual override example

If you only need to redirect a single component (for example, you have your own
cert-manager mirror but everything else is reachable):

```bash
export CERT_MANAGER_MANIFEST_URL="https://registry.internal/manifests/cert-manager-v1.13.0.yaml"
CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install
```

---

## Partial Air-Gap (Mirror One Component)

You do not need the full bundle workflow to override a single URL. Set only the
variables you need:

```bash
# Use an internal Helm chart mirror for metallb only
export METALLB_CHART_PATH="/shared/charts/metallb-0.14.8.tgz"

# Use an internal mirror for NVIDIA device plugin manifest only
export NVIDIA_DEVICE_PLUGIN_MANIFEST_URL="https://manifests.internal/nvidia-device-plugin-v0.17.3.yml"

CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install
```

Unset variables fall back to the default public URLs automatically.

---

## Troubleshooting

### "Checksum verification failed"

The bundle was corrupted in transit. Re-transfer the `.tar.gz` and check the
SHA-256 of the file before extracting:

```bash
sha256sum airgap-bundle-<timestamp>.tar.gz
```

Compare against the value printed by `prepare_airgap_bundle.sh` when the bundle
was created.

### "Expected chart not found"

Helm sometimes uses underscores instead of dashes in filenames
(e.g. `kube_prometheus_stack` vs `kube-prometheus-stack`). Check what was
actually downloaded:

```bash
ls /opt/airgap/airgap-bundle-*/charts/
```

Set `PROMETHEUS_CHART_PATH` (or the relevant variable) explicitly to the
correct filename:

```bash
export PROMETHEUS_CHART_PATH="/opt/airgap/airgap-bundle-20260612-103000/charts/kube-prometheus-stack-72.3.0.tgz"
```

### k0s not found on remote nodes

The installer copies k0s via SSH to each node. Ensure:
1. `K0S_INSTALL_URL` is set to the bundled binary (`file://...`)
2. The file path exists on the install machine (not on the remote node)
3. The SSH user has sudo access on all nodes

### NVIDIA drivers not found on GPU workers

The installer skips driver installation if `nvidia-smi` is already present.
Pre-install NVIDIA drivers using a local RPM/DEB mirror or offline installer
package before running this script. The installer will detect and use them.

### Images failing to pull on cluster nodes

1. Confirm all images from `container-images.txt` were mirrored
2. Confirm `images.registry` in your config points to the internal registry
3. Confirm the image pull secret exists:
   ```bash
   kubectl get secret -n ai-platform
   ```
4. Check pod events for the exact image name that failed:
   ```bash
   kubectl describe pod -n ai-platform <pod-name>
   ```
