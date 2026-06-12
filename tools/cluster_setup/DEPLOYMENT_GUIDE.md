# Splunk AI Platform — Deployment Guide

End-to-end customer experience guide for deploying the Splunk AI Platform on
k0s Kubernetes. Covers both standard (internet-connected) and air-gapped
(fully disconnected) deployments.

---

## Table of Contents

- [Which Path Is Right for You?](#which-path-is-right-for-you)
- [What Gets Deployed](#what-gets-deployed)
- [Standard Deployment (Internet-Connected)](#standard-deployment-internet-connected)
  - [What You Need Before Starting](#what-you-need-before-starting)
  - [Install Flow](#install-flow)
  - [Step-by-Step](#step-by-step-standard)
- [Air-Gapped Deployment (No Internet on Cluster)](#air-gapped-deployment-no-internet-on-cluster)
  - [Air-Gap Concepts](#air-gap-concepts)
  - [Phase 1 — Prepare the Bundle (Connected Machine)](#phase-1--prepare-the-bundle-connected-machine)
  - [Phase 2 — Mirror Container Images](#phase-2--mirror-container-images)
  - [Phase 3 — Stage Model Weights](#phase-3--stage-model-weights)
  - [Phase 4 — Transfer to Air-Gapped Environment](#phase-4--transfer-to-air-gapped-environment)
  - [Phase 5 — Install from the Bundle](#phase-5--install-from-the-bundle)
  - [GPU Nodes in Air-Gapped Environments](#gpu-nodes-in-air-gapped-environments)
- [Cluster Architecture](#cluster-architecture)
- [Post-Install Verification](#post-install-verification)
- [Common Operations](#common-operations)
- [Troubleshooting](#troubleshooting)

---

## Which Path Is Right for You?

```mermaid
flowchart TD
    START([Start: Deploy Splunk AI Platform]) --> Q1

    Q1{Can your cluster nodes\nreach the internet?}
    Q1 -->|Yes| STANDARD[Standard Deployment\nAll downloads happen automatically]
    Q1 -->|No| Q2

    Q2{Does your install\nmachine have internet?}
    Q2 -->|Yes| AIRGAP[Air-Gapped Deployment\nBundle on connected machine,\ninstall offline]
    Q2 -->|No| FULLAIR[Fully Disconnected\nPrepare bundle on any\nconnected machine,\ntransfer physically]

    STANDARD --> SDOC[📄 See Standard Deployment section]
    AIRGAP --> ADOC[📄 See Air-Gapped Deployment section]
    FULLAIR --> ADOC

    style STANDARD fill:#22543d,color:#fff
    style AIRGAP fill:#744210,color:#fff
    style FULLAIR fill:#63171b,color:#fff
```

| Scenario | Install machine has internet | Cluster nodes have internet | Use |
|---|---|---|---|
| Typical cloud / on-prem | ✅ | ✅ | Standard deployment |
| Install machine online, cluster isolated | ✅ | ❌ | Air-gapped deployment |
| Everything offline | ❌ | ❌ | Air-gapped deployment (prepare bundle on a third machine) |
| Only GPU nodes blocked | ✅ | ✅ (non-GPU) / ❌ (GPU) | Standard + pre-install GPU drivers |

---

## What Gets Deployed

The installer deploys the complete Splunk AI Platform stack onto your k0s cluster.

```mermaid
graph TB
    subgraph CTRL["🖥️  Controller Node"]
        K8S[k0s API Server\netcd · Scheduler\nController Manager]
    end

    subgraph CPU["💻  CPU Worker(s)"]
        SPLUNK[Splunk Enterprise]
        RAY_HEAD[Ray Head Pod]
        WEAVIATE[Weaviate\nVector DB]
        SAIA[SAIA API\nv1 + v2]
        LOADER[Data Loader]
        MONITORING[Prometheus\nGrafana · OTel]
    end

    subgraph GPU["🔥  GPU Worker(s)"]
        RAY_GPU[Ray GPU Workers\nAI Inference]
        MODELS[(Model Weights\ngemma-4-31b-it\ngpt-oss-20b\n+ 8 more)]
    end

    subgraph OBJ["🗄️  Object Storage\n(Customer-managed)"]
        S3[MinIO / SeaweedFS\n/ AWS S3]
    end

    subgraph INFRA["⚙️  Infrastructure (all nodes)"]
        CERT[cert-manager]
        METALLB[MetalLB\nLoad Balancer]
        NV[NVIDIA Device\nPlugin]
        LOCALPATH[local-path\nProvisioner]
    end

    CTRL --- CPU
    CTRL --- GPU
    CPU <--> S3
    GPU <--> S3
    RAY_HEAD <--> RAY_GPU
    SAIA <--> WEAVIATE
```

### Operator Stack

| Operator | Version | Purpose |
|---|---|---|
| Splunk AI Operator | your build | Manages `AIPlatform` CR lifecycle |
| Splunk Operator | 3.0.0 | Manages Splunk Enterprise |
| KubeRay | 1.2.2 | Manages Ray clusters for AI inference |
| cert-manager | v1.13.0 | TLS certificate management |
| OTel Operator | latest | Observability |
| NVIDIA Device Plugin | v0.17.3 | Exposes GPUs to Kubernetes |

---

## Standard Deployment (Internet-Connected)

### What You Need Before Starting

```mermaid
flowchart LR
    subgraph PRE["Prerequisites Checklist"]
        direction TB
        A["✅ Admin workstation\nkubectl · helm · git\njq · yq · ssh"]
        B["✅ SSH key\nprivate key access to\nall cluster nodes"]
        C["✅ Cluster nodes\nController · CPU Worker(s)\nGPU Worker(s)\npasswordless sudo"]
        D["✅ Object storage\nMinIO / SeaweedFS / S3\nprovisioned & reachable"]
        E["✅ Container registry\nImages pushed to ECR\nor your private registry"]
        F["✅ config YAML\nk0s-cluster-config.yaml\nfilled in"]
    end
```

**Node size requirements:**

| Node Type | Min CPU | Min RAM | Min Disk | Count |
|---|---|---|---|---|
| Controller | 4 cores | 8 GB | 100 GB | 1 (or 3 for HA) |
| CPU Worker | 8 cores | 32 GB | 200 GB | 1+ |
| GPU Worker | 48 vCPUs | 384 GiB | 500 GB | 2× required · 4 × NVIDIA L40S per node (48 GB GDDR6 each, 192 GB GPU memory per node, 384 GB total across 2 nodes) · 100 Gbps · equivalent to g6e.12xlarge |

**Ports to open between nodes:** 22 (SSH), 6443 (k8s API), 2380 (etcd), 10250 (kubelet), 8132 (konnectivity), 4789/UDP (VXLAN/Calico), 179 (Calico BGP).

### Install Flow

```mermaid
sequenceDiagram
    actor Admin
    participant WS as Admin Workstation
    participant HF as HuggingFace
    participant OBJ as Object Store
    participant CTRL as Controller Node
    participant WKRS as Worker Nodes

    Admin->>WS: Edit k0s-cluster-config.yaml
    Admin->>WS: ./k0s_cluster_with_stack.sh install

    rect rgb(30, 60, 30)
        note over WS: Phase 0 — Preflight
        WS->>WS: Validate config + tools
        WS->>CTRL: SSH connectivity check
        WS->>WKRS: Disk space preflight
        WS->>OBJ: Object store reachability
    end

    rect rgb(30, 50, 80)
        note over WS,OBJ: Phase 1 — Model Staging (if enabled)
        WS->>HF: Download model weights (~60 GB)
        HF-->>WS: gemma-4-31b-it, gpt-oss-20b, + 8 models
        WS->>OBJ: Upload model_artifacts/
    end

    rect rgb(60, 30, 60)
        note over WS,WKRS: Phase 2 — Cluster Bootstrap
        WS->>CTRL: Install k0s controller
        WS->>WKRS: Install k0s workers
        WS->>WKRS: Label nodes (cpu/gpu roles)
        WS->>WKRS: Install NVIDIA drivers (GPU nodes)
    end

    rect rgb(60, 50, 20)
        note over WS,CTRL: Phase 3 — Platform Stack
        WS->>CTRL: cert-manager + Prometheus (parallel)
        WS->>CTRL: OTel + KubeRay + Splunk operators
        WS->>CTRL: NVIDIA device plugin
        WS->>CTRL: MetalLB (if LoadBalancer)
        WS->>CTRL: Splunk Enterprise CR
        WS->>CTRL: AIPlatform CR
    end

    rect rgb(20, 40, 60)
        note over WS,CTRL: Phase 4 — Verify
        WS->>CTRL: Wait for all pods Ready
        WS->>Admin: Print access URLs + credentials
    end
```

### Step-by-Step (Standard)

**1. Configure your cluster**

```bash
cd tools/cluster_setup
cp k0s-cluster-config.yaml my-cluster.yaml
# Open my-cluster.yaml and fill in ALL fields marked CHANGE THIS
```

The config sections to fill in:

| Section | What to set |
|---|---|
| `cluster` | `name`, `sshKeyPath`, `sshUser` |
| `nodes.existingIPs` | IP addresses of your controller and worker nodes |
| `storage.objectStore` | Your MinIO / SeaweedFS / S3 endpoint + credentials |
| `images` | Your registry URL + all image tags |
| `aiPlatform` | `defaultAcceleratorType` — set to `L40S` |
| `metallb.pool.addresses` | A free IP range on your LAN (for LoadBalancer VIP) |

**2. Validate your config before installing**

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate
```

This runs a read-only config check and prints a ✔/✖ checklist. Fix any ✖ items before proceeding.

**3. Run the installer**

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

The installer shows an install plan and asks for confirmation before making any changes.

**4. Monitor progress**

The installer prints timestamped progress to the terminal and to a log file:

```bash
# In another terminal — follow the live log
tail -f tools/cluster_setup/logs/k0s-install-*.log
```

**5. Verify the result**

```bash
export KUBECONFIG=~/.kube/k0s-<your-cluster-name>
kubectl get nodes                          # all nodes Ready
kubectl get pods -A                        # all pods Running
kubectl get aiplatform -n ai-platform      # AIPlatform Ready
```

---

## Air-Gapped Deployment (No Internet on Cluster)

### Air-Gap Concepts

```mermaid
flowchart LR
    subgraph CONNECTED["🌐 Internet-Connected Zone"]
        BNDMACHINE["Bundle Machine\n(laptop / jump host)"]
        INTERNET[("Internet\nGitHub · NVIDIA\nHuggingFace\nHelm repos\nPyPI")]
    end

    subgraph TRANSFER["📦 Transfer Mechanism"]
        TARBALL["airgap-bundle.tar.gz\n~500 MB\n+\nmodel weights\n~60 GB\n+\ncontainer images"]
    end

    subgraph AIRGAP["🔒 Air-Gapped Zone"]
        INSTALLMACHINE["Install Machine\n(kubectl · helm · ssh)"]
        REGISTRY["Internal\nContainer Registry"]
        OBJSTORE["Internal\nObject Store\n(MinIO / SeaweedFS)"]
        CLUSTER["k0s Cluster"]
    end

    INTERNET -->|prepare_airgap_bundle.sh| BNDMACHINE
    BNDMACHINE -->|scp / USB / courier| TARBALL
    TARBALL --> INSTALLMACHINE
    INSTALLMACHINE -->|install_from_airgap_bundle.sh| CLUSTER
    REGISTRY --> CLUSTER
    OBJSTORE --> CLUSTER
```

**Key principle:** The main installer has no hardcoded download URLs — every internet address is overridable via environment variables. `install_from_airgap_bundle.sh` sets all of them automatically from the bundle.

### Phase 1 — Prepare the Bundle (Connected Machine)

Run this on any machine with internet access. You do not need the cluster nodes reachable from this machine.

```bash
cd tools/cluster_setup

# Build the bundle (RHEL 9 GPU nodes — only supported target)
./prepare_airgap_bundle.sh --output-dir /mnt/transfer

# Pin a specific k0s version
./prepare_airgap_bundle.sh --output-dir /mnt/transfer --k0s-version v1.31.2+k0s.0
```

**What gets downloaded into the bundle:**

```mermaid
graph TD
    SCRIPT["prepare_airgap_bundle.sh"]

    subgraph BIN["📁 binaries/"]
        K0S["k0s binary\nlatest or --k0s-version"]
        YQ["yq v4.44.1\nYAML processor"]
    end

    subgraph MAN["📁 manifests/"]
        CERT["cert-manager v1.13.0"]
        LP["local-path-provisioner v0.0.24"]
        NDP["nvidia-device-plugin v0.17.3"]
    end

    subgraph CHARTS["📁 charts/"]
        PROM["kube-prometheus-stack\n(version resolved at bundle time)"]
        OTEL["opentelemetry-operator\n(version resolved at bundle time)"]
        KUBERAY["kuberay-operator 1.2.2"]
        METALLB["metallb 0.14.8"]
    end

    subgraph PKGS["📁 packages/  (GPU nodes)"]
        EPEL["epel-release-latest-9.noarch.rpm"]
        CUDA["cuda-rhel9.repo"]
        CTK["nvidia-container-toolkit.repo"]
        PYYAML["PyYAML wheel\n(all nodes)"]
    end

    subgraph META["📄 Metadata"]
        ENV["airgap-env.sh\nenv-var overrides"]
        IMGS["container-images.txt\nmirror checklist"]
        VERS["bundle-versions.txt"]
        SUMS["checksums.sha256"]
    end

    SCRIPT --> BIN & MAN & CHARTS & PKGS & META
```

Output: a single timestamped `.tar.gz`:

```
/mnt/transfer/airgap-bundle-20260612-103000.tar.gz   (~500 MB)
```

### Phase 2 — Mirror Container Images

Container images are **not** in the bundle (they would add many GB). Mirror them separately to your internal registry.

```mermaid
flowchart LR
    subgraph CONN["Connected Machine"]
        LIST["container-images.txt\nfrom the bundle"]
        CRANE["crane copy\nor\ndocker pull+tag+push"]
    end
    subgraph NET["Internet"]
        DOCKERHUB["docker.io"]
        QUAY["quay.io"]
        ECR_PUB["Public ECR"]
    end
    subgraph INTERNAL["Air-Gapped Zone"]
        REGISTRY["registry.airgap.local\n(Harbor / ECR / ACR)"]
        CLUSTER["k0s Cluster\nnodes"]
    end

    LIST --> CRANE
    DOCKERHUB & QUAY & ECR_PUB --> CRANE
    CRANE -->|push mirrored images| REGISTRY
    REGISTRY --> CLUSTER
```

```bash
INTERNAL_REGISTRY="registry.airgap.local"

# From the bundle (after extracting or before packing it)
while IFS= read -r img; do
  [[ "$img" =~ ^# ]] && continue
  [[ -z "$img" ]] && continue
  dest="${INTERNAL_REGISTRY}/${img##*/}"
  echo "Copying $img → $dest"
  crane copy "$img" "$dest"
done < container-images.txt
```

After mirroring, update your config:

```yaml
images:
  registry: "registry.airgap.local"
  operator:
    image: "registry.airgap.local/splunk-ai-operator:latest"
  # ... all other images pointing at your internal registry

imagePullSecrets:
  autoCreateECR: false   # disable automatic ECR token refresh
```

### Phase 3 — Stage Model Weights

Model weights (~60 GB) must be staged to your object store. Do this on the connected machine.

**System requirements for the staging machine**

This can be the same machine you use to run the installer, or any machine with internet access and SSH/S3 connectivity to your environment.

| Resource | Minimum | Notes |
|---|---|---|
| Disk (free) | 250 GB | ~60 GB for 10 models + 200 GB working buffer for download staging and upload temp files |
| RAM | 16 GB | Scripts process and stream large files; less RAM causes swapping and slow uploads |
| Internet | Stable broadband | Downloads ~60 GB from HuggingFace; a flaky connection will require re-running with `SKIP_IF_EXISTS=1` |
| CPU | 4 cores | Recommended for parallel upload scripts; not a hard blocker |

> **Same machine as the installer?** The installer machine already runs `kubectl`, `helm`, and `ssh` — it can also run model staging. Just ensure the **disk requirement** is met on that machine. `/tmp` or the working directory must have 250 GB free.

```bash
cd tools/artifacts_download_upload_scripts

# Download from HuggingFace (set HF_TOKEN for gated models)
HF_TOKEN=hf_... ./download_from_huggingface.sh

# Upload to your object store (endpoint must be reachable from this machine)
./upload_to_minio.sh    # or upload_to_s3.sh, upload_to_seaweedfs.sh
```

Then disable auto-staging in your cluster config (models are already there):

```yaml
storage:
  modelStaging:
    enabled: false
```

### Phase 4 — Transfer to Air-Gapped Environment

```mermaid
sequenceDiagram
    actor Admin
    participant CONN as Connected Machine
    participant MEDIA as Transfer Medium
    participant INSTALL as Air-Gapped\nInstall Machine

    Admin->>CONN: ./prepare_airgap_bundle.sh

    Note over CONN: Bundle ready:\nairgap-bundle-<date>.tar.gz

    CONN->>MEDIA: scp / USB drive / secure courier
    MEDIA->>INSTALL: Copy bundle

    Note over INSTALL: Also copy:\ninstall_from_airgap_bundle.sh\nk0s_cluster_with_stack.sh\nmy-cluster-config.yaml
```

```bash
# Copy bundle
scp /mnt/transfer/airgap-bundle-20260612-103000.tar.gz \
    admin@install-machine:/opt/splunk-ai/

# Copy installer scripts (if not already on the machine)
scp tools/cluster_setup/k0s_cluster_with_stack.sh \
    tools/cluster_setup/install_from_airgap_bundle.sh \
    tools/cluster_setup/k0s-cluster-config.yaml \
    admin@install-machine:/opt/splunk-ai/

# Copy your edited cluster config
scp my-cluster-config.yaml admin@install-machine:/opt/splunk-ai/
```

### Phase 5 — Install from the Bundle

**5a. Add `cluster.airgap: true` to your config**

```yaml
cluster:
  name: my-cluster
  airgap: true        # skips internet connectivity checks immediately
  sshKeyPath: ~/.ssh/id_rsa
  sshUser: ec2-user
```

**5b. Run the installer**

```bash
cd /opt/splunk-ai
chmod +x install_from_airgap_bundle.sh k0s_cluster_with_stack.sh

./install_from_airgap_bundle.sh \
  --bundle /opt/splunk-ai/airgap-bundle-20260612-103000.tar.gz \
  --config /opt/splunk-ai/my-cluster-config.yaml
```

**What `install_from_airgap_bundle.sh` does automatically:**

```mermaid
flowchart TD
    A["install_from_airgap_bundle.sh --bundle ..."] --> B

    B["1. Extract bundle\n/opt/airgap/airgap-bundle-<date>/"]
    B --> C["2. Verify SHA-256 checksums\nof every bundled file"]
    C --> D["3. Install k0s binary\nto /usr/local/bin/k0s"]
    D --> E["4. Install yq binary\nto /usr/local/bin/yq"]
    E --> F["5. Register local Helm repo\nfile:///opt/airgap/.../charts/"]
    F --> G["6. Export env-var overrides\nall 13 URL + path variables"]
    G --> H["7. Run k0s_cluster_with_stack.sh install\nwith all overrides in effect"]

    style C fill:#1a3a1a
    style G fill:#1a2a3a
```

The install plan shown before any changes are made will display:

```
Air-gap mode    : true
k0s install URL : file:///opt/airgap/.../binaries/k0s
Helm charts     : local (file:///opt/airgap/.../charts/)
...
```

Confirm to proceed.

### GPU Nodes in Air-Gapped Environments

GPU nodes require OS packages (EPEL, DKMS, CUDA, nvidia-container-toolkit) that normally download from the internet. In air-gap mode the installer detects this and fails clearly rather than timing out.

```mermaid
flowchart TD
    INSTALLER["Installer reaches GPU node\ninstall_nvidia_on_node()"]
    CHECK{"nvidia-smi\nalready present?"}
    SKIP["✅ Skip driver install\nDriver already installed"]
    AIRGAP_CHECK{"AIRGAP_MODE\n= true?"}
    FAIL["❌ Clear error message:\nnvidia-smi not found\nin AIRGAP_MODE\n→ see AIRGAP.md"]
    INSTALL["Install driver\nfrom internet:\nEPEL → DKMS\nCUDA repo → cuda-drivers\nnvidia-container-toolkit"]
    CTK["Install nvidia-container-toolkit"]
    VERIFY["Verify: nvidia-smi returns\ndriver version number"]

    INSTALLER --> CHECK
    CHECK -->|yes| SKIP
    CHECK -->|no| AIRGAP_CHECK
    AIRGAP_CHECK -->|yes| FAIL
    AIRGAP_CHECK -->|no| INSTALL
    INSTALL --> CTK
    CTK --> VERIFY
    SKIP --> CTK
```

**Three strategies for GPU node packages in air-gap:**

```mermaid
flowchart LR
    subgraph S1["Strategy 1\n✅ Recommended"]
        S1A["Pre-install NVIDIA driver\n+ nvidia-container-toolkit\non GPU nodes\nBEFORE running installer"]
        S1B["Installer detects nvidia-smi\nand skips driver install"]
        S1A --> S1B
    end

    subgraph S2["Strategy 2\nLocal RPM mirror"]
        S2A["Set up internal\nRPM mirror\n(reposync)"]
        S2B["Set env vars:\nEPEL_RPM_URL_OVERRIDE\nCUDA_REPO_URL_OVERRIDE\nNVIDIA_CTK_REPO_URL_OVERRIDE"]
        S2A --> S2B
    end

    subgraph S3["Strategy 3\nPartial air-gap"]
        S3A["GPU nodes have\ncontrolled access to\nnvidia.com only"]
        S3B["Set cluster.airgap: true\nInstaller skips HuggingFace\nchecks but GPU driver\ninstall proceeds normally"]
        S3A --> S3B
    end
```

**Using bundled package files (Strategy 1):**

The bundle's `packages/` directory contains the files needed to pre-install drivers:

```bash
# Copy packages from the bundle to each GPU node
GPU_NODE="10.0.0.3"
BUNDLE_PKGS="/opt/airgap/airgap-bundle-<date>/packages"

scp -r "${BUNDLE_PKGS}" "${GPU_NODE}:/tmp/airgap-packages"

# On each GPU node — install the driver before running the main installer
ssh "${GPU_NODE}" bash <<'EOF'
  PKG=/tmp/airgap-packages

  # 1. Install EPEL (provides DKMS)
  sudo dnf install -y "${PKG}/epel-release-latest-9.noarch.rpm"

  # 2. Install DKMS + build toolchain
  sudo dnf install -y dkms gcc make elfutils-libelf-devel "kernel-devel-$(uname -r)"

  # 3. Add CUDA repo and install driver
  sudo cp "${PKG}/cuda-rhel9.repo" /etc/yum.repos.d/
  sudo dnf install -y cuda-drivers

  # 4. Install nvidia-container-toolkit
  sudo cp "${PKG}/nvidia-container-toolkit.repo" /etc/yum.repos.d/
  sudo dnf install -y nvidia-container-toolkit

  # 5. Verify
  nvidia-smi
EOF
```

> After pre-installing drivers, run `install_from_airgap_bundle.sh` normally. The installer will detect `nvidia-smi` and skip driver installation entirely.

---

## Cluster Architecture

```mermaid
graph TB
    subgraph USERS["👥 Users"]
        BROWSER["Browser\nSAIA v2 Chat UI"]
        SPLUNK_UI["Splunk Web\nSPL + AI Assist"]
    end

    subgraph ADMIN["🔧 Admin Workstation"]
        KUBECTL["kubectl"]
        INSTALLER["k0s_cluster_with_stack.sh"]
    end

    subgraph NETWORK["🌐 Network (your LAN)"]
        VIP["MetalLB VIP\n10.20.30.100\n(LoadBalancer)"]
    end

    subgraph CTRL["🖥️  Controller Node(s)"]
        APISERVER["k0s API Server :6443"]
        ETCD["kine/etcd"]
        SCHEDULER["Scheduler\nController Manager"]
    end

    subgraph CPU["💻  CPU Worker(s)"]
        subgraph AI_SVC["AI Services"]
            SAIA_SVC["SAIA API v1/v2\n(nginx reverse proxy)"]
            DATA_LOADER["Data Loader"]
        end
        subgraph RAY_CTRL["Ray Control"]
            RAY_HEAD_POD["Ray Head Pod"]
            RAY_OPERATOR["KubeRay Operator"]
        end
        subgraph DATA_SVC["Data Services"]
            WEAVIATE_POD["Weaviate\nVector DB"]
            SPLUNK_POD["Splunk Enterprise"]
        end
        subgraph OBS["Observability"]
            PROM_POD["Prometheus\nGrafana"]
            OTEL_POD["OTel Collector"]
        end
    end

    subgraph GPU["🔥  GPU Worker(s)"]
        RAY_WORKER["Ray GPU Workers\n(AI Inference)"]
        MODEL_CACHE["Model Cache\n/var/lib/k0s"]
    end

    subgraph STORAGE["🗄️  External Storage (customer-managed)"]
        OBJ_STORE["Object Store\n(MinIO / SeaweedFS / S3)\nmodel_artifacts/ · conversations/\nconfig/ · storage_queue/"]
    end

    BROWSER -->|HTTPS| VIP
    SPLUNK_UI -->|internal| SAIA_SVC
    VIP --> SAIA_SVC

    KUBECTL -->|kubectl| APISERVER
    INSTALLER -->|SSH + k0s API| CTRL

    APISERVER --- ETCD
    APISERVER --> CPU
    APISERVER --> GPU

    SAIA_SVC --> WEAVIATE_POD
    SAIA_SVC --> RAY_HEAD_POD
    RAY_HEAD_POD <-->|Ray protocol| RAY_WORKER
    RAY_WORKER <--> MODEL_CACHE
    DATA_LOADER --> OBJ_STORE
    RAY_WORKER <--> OBJ_STORE
    SPLUNK_POD --> SAIA_SVC
```

### Network Ports

```mermaid
graph LR
    subgraph EXTERNAL["External Access"]
        USER["User browser\nor Splunk"]
    end
    subgraph K8S["k0s Cluster"]
        METALLB_PORT["MetalLB VIP\n:80 / :443"]
        K8S_API[":6443\nkubectl"]
        ETCD_PORT[":2380\netcd peer"]
        KUBELET_PORT[":10250\nkubelet"]
        KONNECT_PORT[":8132\nkonnectivity"]
        CALICO_PORT["4789/UDP\nVXLAN"]
        BGP_PORT[":179\nCalico BGP"]
        SSH_PORT[":22\nSSH"]
    end

    USER --> METALLB_PORT
    USER --> K8S_API
```

---

## Post-Install Verification

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/k0s-<cluster-name>

# All nodes must be Ready
kubectl get nodes -o wide

# All pods must be Running or Completed
kubectl get pods -A --sort-by=.metadata.namespace

# AIPlatform CR must be Ready
kubectl get aiplatform -n ai-platform -o wide

# SAIA service must have an EXTERNAL-IP (if using LoadBalancer)
kubectl get svc -n ai-platform -l app.kubernetes.io/component=saia

# GPU nodes must show available GPUs
kubectl get nodes -l splunk.ai/workload-type=gpu -o yaml | grep nvidia.com/gpu
```

**Expected state after a successful install:**

| Resource | Expected Status |
|---|---|
| All nodes | `Ready` |
| `cert-manager` pods | `Running` |
| `kube-prometheus-stack` pods | `Running` |
| `splunk-operator` pods | `Running` |
| `kuberay-operator` pods | `Running` |
| `splunk-standalone` | `Ready` |
| `aiplatform/<name>` | `Ready` |
| SAIA service | `EXTERNAL-IP` assigned |
| GPU nodes | `nvidia.com/gpu: N` in allocatable |

---

## Common Operations

### Re-run after a partial failure

The installer is idempotent for most steps. If install fails partway:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

The safety gate prevents wiping a cluster with Ready nodes. If you need to start clean:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh clean-all
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

### Add worker nodes

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh join-workers
```

### Re-stage models only

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts

# Skip models already downloaded locally
SKIP_IF_EXISTS=1 CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts
```

### Collect a support bundle

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh diagnose
# Outputs a redacted tar.gz in logs/ with pod logs, events, node state
```

---

## Troubleshooting

### Diagnose first

```bash
# Collect all cluster state into a support bundle
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh diagnose
ls tools/cluster_setup/logs/k0s-diagnose-*.tar.gz
```

### Decision tree

```mermaid
flowchart TD
    FAIL["Install failed or\ncluster not healthy"] --> LOG

    LOG["Check the session log\nlogs/k0s-install-YYYY-MM-DD_HH-MM-SS.log\nSearch for ERROR"]

    LOG --> Q1{Where did it fail?}

    Q1 -->|Preflight| PRE["SSH or disk issue\n→ see Preflight section"]
    Q1 -->|Model staging| MODELS["HuggingFace connectivity\nor S3 credentials\n→ check objectStore config"]
    Q1 -->|k0s install| K0S_FAIL["Node SSH or OS issue\n→ check node state"]
    Q1 -->|Driver install| GPU_FAIL["NVIDIA driver issue\n→ see GPU section"]
    Q1 -->|Helm chart| HELM_FAIL["Chart or image pull issue\n→ check registry config"]
    Q1 -->|AIPlatform not Ready| CR_FAIL["Operator or pod issue\n→ check pod events"]

    PRE --> FIX_PRE["ssh -i key user@node\ndf -h /var/lib/k0s"]
    MODELS --> FIX_MODELS["./k0s_cluster_with_stack.sh validate\ncheck objectStore.endpoint + credentials"]
    K0S_FAIL --> FIX_K0S["ssh user@ctrl 'sudo k0s status'\nssl user@ctrl 'sudo journalctl -u k0scontroller -n 50'"]
    GPU_FAIL --> FIX_GPU["ssh user@gpu-node nvidia-smi\nkubectl get pods -n kube-system | grep nvidia"]
    HELM_FAIL --> FIX_HELM["kubectl get pods -A | grep -v Running\nkubectl describe pod <failing-pod> -n <ns>"]
    CR_FAIL --> FIX_CR["kubectl describe aiplatform -n ai-platform\nkubectl logs -n splunk-ai-operator-system deploy/splunk-ai-operator-controller-manager"]
```

### Quick reference

| Symptom | First check | Fix |
|---|---|---|
| "SSH connection refused" | `ssh -i key user@node-ip hostname` | Check firewall / security groups on port 22 |
| "Refusing to wipe — Ready nodes" | `kubectl get nodes` | Set `useExisting: auto` in config or run `clean-all` first |
| "python3+pyyaml missing" on nodes | `ssh user@node python3 -c 'import yaml'` | Run `dnf install -y python3-pyyaml` on the node (or set `AIRGAP_PYYAML_WHEEL_PATH`) |
| "nvidia-smi not found" in AIRGAP_MODE | `ssh user@gpu-node which nvidia-smi` | Pre-install NVIDIA driver — see [GPU Nodes in Air-Gapped Environments](#gpu-nodes-in-air-gapped-environments) |
| "Checksum verification failed" | Re-transfer the bundle | `sha256sum airgap-bundle-<date>.tar.gz` and compare |
| "Expected chart not found" | `ls /opt/airgap/airgap-bundle-*/charts/` | Set `PROMETHEUS_CHART_PATH` etc. to the actual filename |
| Pod stuck in `ImagePullBackOff` | `kubectl describe pod <pod> -n <ns>` | Check `images.registry` in config and that image pull secret exists |
| SAIA service no `EXTERNAL-IP` | `kubectl get svc -n ai-platform` | Check MetalLB pods: `kubectl get pods -n metallb-system` |
| AIPlatform CR stuck `Pending` | `kubectl describe aiplatform -n ai-platform` | Check operator logs and GPU node availability |

---

*Splunk AI Platform · k0s Deployment Guide · Last updated 2026-06-12*
