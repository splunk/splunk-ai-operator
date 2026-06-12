# k0s Cluster Setup — Quickstart

Deploys the complete Splunk AI Platform stack on k0s Kubernetes using pre-provisioned bare-metal or VM nodes.

> **Requires:** `existingIPs` in config YAML, external S3-compatible object storage, SSH access to all nodes.

## 1. Prerequisites

**Admin workstation:** `kubectl`, `helm`, `git`, `jq`, `yq`

**Nodes (all):** RHEL 9 (or compatible: Rocky 9, AlmaLinux 9, CentOS Stream 9) · passwordless SSH + sudo · Python 3.8+

| Node Type  | Min CPU | Min RAM (per node) | Min Disk | Notes                                                    |
| ---------- | ------- | ------------------ | -------- | -------------------------------------------------------- |
| Controller | 4       | 8 GB               | 100 GB   | API server, etcd, scheduler                              |
| CPU Worker | 8       | 32 GB              | 200 GB   | Weaviate, Ray head, Splunk, SAIA API/v2, Data Loader     |
| GPU Worker | 16      | 384 GB             | 500 GB   | NVIDIA GPU required (6 × L40S 48GB)                       |


**Ports between nodes:** 22 (SSH), 6443 (API), 2380 (etcd), 10250 (kubelet), 8132 (konnectivity), 4789/UDP (VXLAN), 179 (Calico BGP). Best practice is to allow all ports between nodes.

**External S3-compatible storage:** Any S3-compatible endpoint (SeaweedFS, MinIO, AWS S3). Must be provisioned **before** running the installer. Customer managed.

The S3 bucket must contain the following directory before AI inference services start. The installer populates it automatically when `storage.modelStaging.enabled: true` (the default). If you manage staging separately, ensure it is in place before running `install` with staging disabled:

| Directory          | Required | Description                                                                                                                                                   |
| ------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model_artifacts/` | **Yes**  | Pre-trained model weights. Ray workers download models from here at startup. Without these, AI inference services will fail. Auto-populated by `install` when `storage.modelStaging.enabled: true`. |


**Required models in `model_artifacts/`:**


| Model                             | Purpose                                         |
| --------------------------------- | ----------------------------------------------- |
| `gemma-4-31b-it`                  | Primary LLM for chat, SPL generation, reasoning |
| `gpt-oss-20b`                     | Field descriptions, conversation titles         |
| `all-minilm-l6-v2`                | Sentence embeddings (data loader, SAIA)         |
| `bi-encoder`                      | Semantic search ranking                         |
| `cross-encoder`                   | Re-ranking search results                       |
| `uae-large`                       | Embedding model                                 |
| `e5-language-classifier`          | Language detection                              |
| `xlm-roberta-language-classifier` | Multilingual language classification            |
| `pii-classifier`                  | PII detection                                   |
| `mbart-translator`                | Translation                                     |


### Downloading and Uploading Model Artifacts

The installer handles this automatically when `storage.modelStaging.enabled: true` (the default). It downloads models from Hugging Face and uploads them to your configured object store as part of the `install` flow, before the k0s cluster is created.

**System requirements for the staging machine** (the machine running the installer or staging scripts):

| Resource | Minimum | Notes |
|---|---|---|
| Disk (free) | 250 GB | ~60 GB for 10 model weight files + 200 GB buffer for download staging and upload temp files |
| RAM | 16 GB | Needed to stream large files without swapping |
| Internet | Stable broadband | Downloads ~60 GB from HuggingFace; re-run with `SKIP_IF_EXISTS=1` to resume interrupted downloads |

This can be the same machine used to run the installer script.

**To run staging standalone** (without a cluster install):

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts
```

**To skip re-downloading models already present locally:**

```bash
SKIP_IF_EXISTS=1 CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts
```

**To skip staging entirely** (models already in object store — set in YAML):

```yaml
storage:
  modelStaging:
    enabled: false
```

The staging step reads HF credentials and model list from `tools/artifacts_download_upload_scripts/model_artifacts_configs.yaml`. Edit that file to add/remove models or set `hf-token` / `hf-username` for gated models.

**Manual staging** (running the scripts directly):

Helper scripts in `tools/artifacts_download_upload_scripts/` can also be run independently:

```bash
cd tools/artifacts_download_upload_scripts
./download_from_huggingface.sh   # downloads into ./model_artifacts/
```

Then upload:

| Storage Type          | Script                   | Key Environment Variables                                                                                                                |
| --------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| MinIO / S3-compatible | `upload_to_minio.sh`     | `OBJECT_STORE_ENDPOINT`, `OBJECT_STORE_BUCKET`, `OBJECT_STORE_ACCESS_KEY`, `OBJECT_STORE_SECRET_KEY`                                     |
| SeaweedFS             | `upload_to_seaweedfs.sh` | `S3COMPAT_OBJECT_STORE_ENDPOINT`, `S3COMPAT_OBJECT_STORE_BUCKET`, `S3COMPAT_OBJECT_STORE_ACCESS_KEY`, `S3COMPAT_OBJECT_STORE_SECRET_KEY` |
| AWS S3                | `upload_to_s3.sh`        | `S3_BUCKET`, `S3_REGION` (requires AWS CLI credentials)                                                                                  |
| MinIO via AWS CLI     | `upload_to_minio_aws.sh` | `S3COMPAT_OBJECT_STORE_ENDPOINT`, `S3COMPAT_OBJECT_STORE_BUCKET`, `S3COMPAT_OBJECT_STORE_ACCESS_KEY`, `S3COMPAT_OBJECT_STORE_SECRET_KEY` |

**Additional utilities:**

| Script                         | Purpose                                      |
| ------------------------------ | -------------------------------------------- |
| `test_minio_connection.sh`     | Diagnose S3-compatible endpoint connectivity |
| `create_seaweedfs_folders.sh`  | Create standard bucket folder structure      |
| `install_seaweedfs_systemd.sh` | Install SeaweedFS as a systemd service       |
| `install_minio_ec2.sh`         | Install MinIO on an EC2 instance             |

> See `tools/artifacts_download_upload_scripts/README.md` for full usage details.

## 2. Quick Start

```bash
cd tools/cluster_setup
cp k0s-cluster-config.yaml my-cluster.yaml
# Edit my-cluster.yaml — set IPs, SSH key, images, storage endpoint
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

Verify:
```bash
export KUBECONFIG=~/.kube/k0s-<cluster-name>
kubectl get nodes
kubectl get aiplatform -n ai-platform
```

## 3. Commands

| Command           | Description                                                                          |
| ----------------- | ------------------------------------------------------------------------------------ |
| `install`         | Create k0s cluster + deploy full AI Platform stack (auto-stages models if enabled)  |
| `stage-artifacts` | Download models from Hugging Face and upload to object store (standalone, no cluster required) |
| `clean-all`       | Stop + reset + wipe all k0s state from every node                                   |
| `join-workers`    | Add or rejoin worker nodes to an existing cluster                                    |

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh <command>

# Stage models without re-downloading ones already present locally
SKIP_IF_EXISTS=1 CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts

# Install but skip model staging (models already in object store)
# Set storage.modelStaging.enabled: false in your config, then:
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

**Environment variables:**


| Variable         | Default                     | Description                                                                          |
| ---------------- | --------------------------- | ------------------------------------------------------------------------------------ |
| `CONFIG_FILE`    | `./k0s-cluster-config.yaml` | Config file path                                                                     |
| `USE_EXISTING`   | from config                 | Override `cluster.useExisting`                                                       |
| `LOG_DIR`        | `./logs`                    | Session log directory                                                                |
| `SKIP_IF_EXISTS` | `0`                         | Set to `1` to skip re-downloading models already present in `model_artifacts/`      |


## 4. What `install` Does

```
1. Load config → validate images → patch RELATED_IMAGE_* in manifests
2. Preflight checks (tools, SSH, disk space)
3. Model staging (when storage.modelStaging.enabled: true):
   - Download models from Hugging Face → upload to object store
   - Set SKIP_IF_EXISTS=1 to skip models already downloaded locally
   - Set storage.modelStaging.enabled: false to skip entirely
4. Install k0s cluster (safety gate → clean state → controller → workers → labels)
5. Phase 1 (parallel): cert-manager, kube-prometheus, NVIDIA host drivers
6. Ensure S3 credentials secret
7. Phase 2 (parallel): OTel operator, Ray operator, Splunk operator, NVIDIA device plugin
8. Sequential: image pull secrets → Splunk standalone → AI operator → AIPlatform CR
9. Health checks → access info
```

**Safety gate:** If the controller already has Ready nodes, `install` refuses to wipe. Use `useExisting: auto` or run `clean-all` first.

**Session logging:** All output → `logs/k0s-install-YYYY-MM-DD_HH-MM-SS.log`

## 5. Configuration Reference

The config template is `k0s-cluster-config.yaml`. Copy it and edit. Key sections:

### cluster


| Field         | Required | Default | Description                       |
| ------------- | -------- | ------- | --------------------------------- |
| `name`        | Yes      | —       | Cluster name (kubeconfig, labels) |
| `useExisting` | No       | `never` | `auto` / `force` / `never`        |
| `sshUser`     | Yes      | `root`  | SSH user for all nodes            |
| `sshKeyPath`  | Yes      | —       | SSH private key path              |


### nodes


| Field                     | Required | Default | Description                      |
| ------------------------- | -------- | ------- | -------------------------------- |
| `controllers`             | **Yes**  | —       | Controller count (1 or 3 for HA) |
| `cpuWorkers`              | **Yes**  | —       | First N workers labeled CPU      |
| `gpuWorkers`              | **Yes**  | —       | Remaining workers labeled GPU    |
| `existingIPs.controllers` | **Yes**  | —       | Controller IP list               |
| `existingIPs.workers`     | **Yes**  | —       | Worker IP list                   |


### storage


| Field                           | Required | Default            | Description                                |
| ------------------------------- | -------- | ------------------ | ------------------------------------------ |
| `storageClass`                  | **Yes**  | `local-path`       | StorageClass for PVCs                      |
| `vectorDbSize`                  | **Yes**  | `50Gi`             | Weaviate PV size                           |
| `minimumDiskSpace.controller`   | No       | `100`              | Preflight disk check (GB)                  |
| `minimumDiskSpace.cpuWorker`    | No       | `200`              | Preflight disk check (GB)                  |
| `minimumDiskSpace.gpuWorker`    | No       | `500`              | Preflight disk check (GB)                  |
| `objectStore.type`              | **Yes**  | `minio`            | `aws` / `s3compat` / `minio` / `seaweedfs` |
| `objectStore.bucket`            | **Yes**  | `ai-platform-data` | Bucket name                                |
| `objectStore.endpoint`          | **Yes**  | —                  | S3 endpoint (*required for non-AWS)        |
| `objectStore.auth.rootUser`     | Yes      | —                  | Access key                                 |
| `objectStore.auth.rootPassword` | Yes      | —                  | Secret key                                 |
| `modelStaging.enabled`          | No       | `true`             | Download models from HF + upload to object store before install. Set `false` to skip. |


#### S3 Bucket Directory Layout

The S3 bucket serves as the shared storage layer for both pre-staged artifacts and runtime data. The following directories are created and managed automatically by the platform:

**Pre-staged (must exist before install):**


| Directory          | Owner              | Description                                                |
| ------------------ | ------------------ | ---------------------------------------------------------- |
| `model_artifacts/` | Admin (pre-staged) | Pre-trained model weights loaded by Ray workers at startup |


**Created at runtime by SAIA services:**


| Directory                | Owner                | Description                                                              |
| ------------------------ | -------------------- | ------------------------------------------------------------------------ |
| `conversations/`         | SAIA v2 API          | Conversation history per tenant                                          |
| `config/`                | SAIA v2 API / Worker | Tenant data configuration (`config/tenant_data_config/{tenant}.yaml`)    |
| `storage_queue/`         | SAIA v2 Worker       | S3-backed task queue for async ingestion (`urgent/`, `batch/`, `locks/`) |
| `ingestion/tenant_data/` | SAIA v2 Worker       | Temporary ingestion payload storage during processing                    |
| `field_counts/`          | SAIA v2 Worker       | Cached field count statistics per tenant/index/sourcetype                |
| `admin/preferences/`     | SAIA v2 API          | Admin-curated markdown preferences per tenant                            |
| `job_groups/`            | SAIA v1 API          | Background job group state for data upload tasks                         |


**Created at runtime by other platform components:**


| Directory    | Owner             | Description          |
| ------------ | ----------------- | -------------------- |
| `artifacts/` | AI Operator       | Deployment artifacts |
| `tasks/`     | AI Operator / Ray | Task execution state |


> **Note:** Do not manually delete runtime directories (`conversations/`, `config/`, `storage_queue/`) as they contain active state. Deleting `storage_queue/locks/` may be necessary to clear stale distributed locks after a non-graceful pod restart.

### images

Short paths auto-prefixed with `images.registry`. All marked **Yes** are required; others have defaults.

**Image sources:**


| Source | Images |
| ----------- | -------------------------------------------------------------------------------------------------------------------------- |
| Your registry | `operator`, `ray.headImage`, `ray.workerImage`, `saia.apiImage`, `saia.apiV2Image`, `saia.dataLoaderImage`, `splunk.image` |
| `docker.io` | `splunk.operatorImage`, `weaviate.image`, `nginx.image`, `fluentBit.image`, `otelCollector.image`                          |
| `quay.io`   | KubeRay Operator (deployed via Helm, not in this config)                                                                   |


> **Note:** Internal images must be pushed to a registry accessible by the cluster (e.g., ECR, ACR, GCR, or a private registry). Set `images.registry` to that registry; short paths like `ml-platform/ray/ray-head:tag` are auto-prefixed with it.


| Field                  | Req     | Default                                        |
| ---------------------- | ------- | ---------------------------------------------- |
| `registry`             | **Yes** | `""`                                           |
| `operator.image`       | **Yes** | —                                              |
| `splunk.image`         | **Yes** | —                                              |
| `splunk.operatorImage` | No      | `docker.io/splunk/splunk-operator:3.0.0`       |
| `ray.headImage`        | **Yes** | —                                              |
| `ray.workerImage`      | **Yes** | —                                              |
| `weaviate.image`       | **Yes** | —                                              |
| `saia.apiImage`        | **Yes** | —                                              |
| `saia.apiV2Image`      | **Yes** | —                                              |
| `saia.dataLoaderImage` | **Yes** | —                                              |
| `nginx.image`          | No      | `docker.io/library/nginx:1.27-alpine`          |
| `fluentBit.image`      | No      | `fluent/fluent-bit:1.9.6`                      |
| `otelCollector.image`  | No      | `otel/opentelemetry-collector-contrib:0.122.1` |


### aiPlatform


| Field                             | Required | Default                       | Description                                   |
| --------------------------------- | -------- | ----------------------------- | --------------------------------------------- |
| `name`                            | **Yes**  | `${CLUSTER_NAME}-ai-platform` | CR name                                       |
| `defaultAcceleratorType`          | **Yes**  | `""`                          | Set to `L40S`                                 |
| `workerGroupConfig.imageRegistry` | No       | `""`                          | Ray worker image override                     |
| `features[].name`                 | Yes      | —                             | Feature name (e.g., `saia`)                   |
| `features[].version`              | Yes      | —                             | Feature version                               |
| `cpuScheduling`                   | No       | auto                          | `nodeSelector` + `tolerations` for CPU pods   |
| `gpuScheduling`                   | No       | auto                          | `nodeSelector` + `tolerations` for GPU pods   |
| `serviceTemplate.type`            | **Yes**  | —                             | `NodePort` / `LoadBalancer` for SAIA exposure |
| `serviceTemplate.nodePort`        | No       | —                             | Port number (when serviceTemplate.type as NodePort only)                   |


### imagePullSecrets

The `secrets[]` list is **not consumed**. The script auto-detects secrets by checking hardcoded names (`ecr-registry-secret`, `docker-hub-secret`, `gcr-secret`, `acr-secret`, `custom-registry-secret`).


| Field               | Description                      |
| ------------------- | -------------------------------- |
| `autoCreateECR`     | Create ECR secret from AWS creds |
| `dockerHub.enabled` | Create Docker Hub secret         |
| `gcr.enabled`       | Create GCR secret                |
| `acr.enabled`       | Create ACR secret                |
| `custom.enabled`    | Create custom registry secret    |


ECR tokens usually expire after 12 hours. Re-run install or set up a CronJob to refresh.

### ecr


| Field     | Description    |
| --------- | -------------- |
| `account` | AWS account ID |
| `region`  | ECR region     |


### metallb

k0s has no built-in `LoadBalancer` provider. When `aiPlatform.serviceTemplate.type=LoadBalancer` (the recommended SAIA exposure path), the installer deploys MetalLB to allocate a VIP from a pool you provide. Skipped automatically when `type=NodePort`.


| Field            | Required                | Default          | Description                                              |
| ---------------- | ----------------------- | ---------------- | -------------------------------------------------------- |
| `install`        | **Yes**                 | `false`          | Set `true` to install MetalLB                            |
| `chartVersion`   | No                      | `0.14.8`         | `metallb/metallb` Helm chart version                     |
| `namespace`      | No                      | `metallb-system` | MetalLB install namespace                                |
| `pool.name`      | No                      | `saia-pool`      | Name of the `IPAddressPool`                              |
| `pool.addresses` | **Yes**                 | —                | Free, routable IP range(s) on your LAN                   |
| `mode`           | No                      | `layer2`         | `layer2` (most LANs) or `bgp` (data-center fabric)       |
| `bgpPeers`       | **Yes when `mode=bgp`** | `[]`             | List of `{peerAddress, peerASN, myASN}` for BGP upstream |


**Minimal config (Layer-2):**

```yaml
metallb:
  install: true
  pool:
    addresses:
      - "10.20.30.100-10.20.30.110"   # free range on the worker LAN
  mode: "layer2"
```

**Verify MetalLB after install:**

```bash
# MetalLB controller and speakers
kubectl -n metallb-system get deploy,ds

# Address pool and advertisement
kubectl -n metallb-system get ipaddresspool,l2advertisement,bgppeer,bgpadvertisement

# SAIA service should have an EXTERNAL-IP from the pool
kubectl -n ai-platform get svc -l app.kubernetes.io/component=saia
```


## 6. Node Labels & GPU

The script auto-labels nodes:


| Node type  | Key labels                                                                                       |
| ---------- | ------------------------------------------------------------------------------------------------ |
| Controller | `splunk.ai/workload-type: control-plane`                                                         |
| CPU Worker | `splunk.ai/workload-type: cpu`, `splunk.ai/instance-type: cpu-worker`                            |
| GPU Worker | `splunk.ai/workload-type: gpu`, `nvidia.com/gpu: "true"`, taint `nvidia.com/gpu=true:NoSchedule` |


**NVIDIA drivers** are installed directly on GPU nodes (not GPU Operator). Supported: RHEL 9 currently. The script installs kernel headers, CUDA repo, `cuda-drivers`, NVIDIA Container Toolkit, then verifies with `nvidia-smi`.

## 7. Troubleshooting

**SSH failures:**

```bash
ssh -i ~/.ssh/key.pem user@node-ip hostname   # test connectivity
chmod 600 ~/.ssh/key.pem                       # fix permissions
```

**Safety gate ("refusing to wipe"):**
Set `useExisting: auto` in config, or run `clean-all` then `install`.

**k0s issues:**

```bash
ssh user@controller-ip "sudo k0s status"
ssh user@controller-ip "sudo journalctl -u k0scontroller -f"
```

**Worker join failures:**

```bash
CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh join-workers
```

**GPU not detected:**

```bash
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds
ssh user@gpu-node nvidia-smi
```

**AIPlatform not ready:**

```bash
kubectl describe aiplatform -n ai-platform
kubectl logs -n splunk-ai-operator-system deployment/splunk-ai-operator-controller-manager
```

**Session logs:**

```bash
ls -lt tools/cluster_setup/logs/
tail -f tools/cluster_setup/logs/k0s-install-*.log
```

## 8. Air-Gapped Deployment

1. On a connected machine: download k0s binary, pull all container images (see table below), download Helm charts
2. Transfer to air-gapped nodes: copy k0s binary, load images into local registry, copy manifests
3. Set `images.registry` to your local registry, `autoCreateECR: false`
4. Run `install`

### Internet Dependencies (for pre-staging)

**Binaries/charts downloaded by the script:**


| What                    | Source                                      |
| ----------------------- | ------------------------------------------- |
| k0s binary              | `https://get.k0s.sh`                        |
| cert-manager v1.13.0    | `github.com/cert-manager/cert-manager`      |
| kube-prometheus-stack   | `prometheus-community` Helm repo            |
| opentelemetry-operator  | `open-telemetry` Helm repo                  |
| kuberay-operator v1.2.2 | `ray-project` Helm repo                     |
| NVIDIA device plugin    | `github.com/NVIDIA/k8s-device-plugin`       |
| local-path-provisioner  | `github.com/rancher/local-path-provisioner` |


**Container images pulled at runtime:**


| Image                                                                               | Default Source                                           |
| ----------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Splunk AI Operator, Ray Head/Worker, SAIA API v1/v2, Data Loader, Splunk Enterprise | ECR or configured registry                               |
| Weaviate                                                                            | `docker.io/semitechnologies/weaviate`                    |
| Nginx                                                                               | `docker.io/library/nginx:1.27-alpine`                    |
| Fluent Bit                                                                          | `docker.io/fluent/fluent-bit:1.9.6`                      |
| OTel Collector                                                                      | `docker.io/otel/opentelemetry-collector-contrib:0.122.1` |
| Splunk Operator                                                                     | `docker.io/splunk/splunk-operator:3.0.0`                 |
| KubeRay Operator                                                                    | `quay.io/kuberay/operator:v1.2.2`                        |
| Prometheus, Grafana, cert-manager, NVIDIA plugin, local-path                        | Pulled by their respective Helm charts/manifests         |


**NVIDIA packages on GPU nodes (RHEL 9):**


| Package           | Source                                                      |
| ----------------- | ----------------------------------------------------------- |
| CUDA drivers      | `developer.download.nvidia.com/compute/cuda/repos/rhel9/`  |
| EPEL (for DKMS)   | `dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm` |
| Container Toolkit | `nvidia.github.io/libnvidia-container/`                     |


## 9. Architecture

```
┌──────────────────────────────────────────────────┐
│            k0s Controller Node(s)                │
│   API Server :6443 · etcd :2380 · Konnectivity  │
└────────────────────┬─────────────────────────────┘
                     │ Calico VXLAN (10.244.0.0/16)
       ┌─────────────┼─────────────┐
┌──────▼───────┐ ┌───▼──────────┐ ┌▼──────────────┐
│ CPU Worker   │ │ CPU Worker   │ │ GPU Worker     │
│ Ray Head     │ │ Weaviate     │ │ Ray GPU Pods   │
│ Splunk       │ │ Ray CPU Pods │ │ AI Inference   │
│ Monitoring   │ │ AI Services  │ │                │
└──────────────┘ └──────────────┘ └────────────────┘
                     │
        ┌────────────▼─────────────┐
        │ External Object Storage  │
        │ (SeaweedFS / MinIO / S3) │
        └──────────────────────────┘
```

**Operators deployed:** Splunk AI Operator, Splunk Operator, KubeRay v1.2.2, cert-manager v1.13.0, OTel Operator, NVIDIA device plugin

**Resource hierarchy:** `AIPlatform CR → AIService → RayService → RayCluster → Ray Pods`

**Secret propagation:** `AIPlatform CR → AIService → RayCluster/Jobs → Pods`

---

*Version 3.0 · April 2026 · Splunk AI Platform Team*
