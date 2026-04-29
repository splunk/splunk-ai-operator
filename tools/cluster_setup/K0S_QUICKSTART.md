# k0s Cluster Setup — Quickstart

Deploys the complete Splunk AI Platform stack on k0s Kubernetes using pre-provisioned bare-metal or VM nodes.

> **Requires:** `existingIPs` in config YAML, external S3-compatible object storage, SSH access to all nodes.

## 1. Prerequisites

**Admin workstation:** `kubectl`, `helm`, `git`, `jq`, `yq`

**Nodes (all):** RHEL 9/10, AL2023, or Debian/Ubuntu · passwordless SSH + sudo · Python 3.8+

| Node Type | Min CPU | Min RAM | Min Disk | Notes |
|-----------|---------|---------|----------|-------|
| Controller | 4 | 8 GB | 100 GB | API server, etcd, scheduler |
| CPU Worker | 8 | 32 GB | 200 GB | Weaviate, Ray head, Splunk |
| GPU Worker | 8 | 32 GB | 500 GB | NVIDIA GPU required |

**Ports between nodes:** 22 (SSH), 6443 (API), 2380 (etcd), 10250 (kubelet), 8132 (konnectivity), 4789/UDP (VXLAN), 179 (Calico BGP)

**External storage:** Any S3-compatible endpoint (SeaweedFS, MinIO, AWS S3). Not deployed by the script.

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

| Command | Description |
|---------|-------------|
| `install` | Create k0s cluster + deploy full AI Platform stack |
| `delete` | Stop k0s, remove services |
| `clean-all` | Stop + reset + wipe all k0s state from every node |
| `join-workers` | Add or rejoin worker nodes to an existing cluster |

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh <command>
```

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `CONFIG_FILE` | `./k0s-cluster-config.yaml` | Config file path |
| `AUTO_APPROVE` | `false` | Skip confirmation prompts |
| `USE_EXISTING` | from config | Override `cluster.useExisting` |
| `LOG_DIR` | `./logs` | Session log directory |

## 4. What `install` Does

```
1. Load config → validate images → patch RELATED_IMAGE_* in manifests
2. Preflight checks (tools, SSH, disk space)
3. Install k0s cluster (safety gate → clean state → controller → workers → labels)
4. Phase 1 (parallel): cert-manager, kube-prometheus, NVIDIA host drivers
5. Ensure S3 credentials secret
6. Phase 2 (parallel): OTel operator, Ray operator, Splunk operator, NVIDIA device plugin
7. Sequential: image pull secrets → Splunk standalone → AI operator → AIPlatform CR
8. Health checks → access info
```

**Safety gate:** If the controller already has Ready nodes, `install` refuses to wipe. Use `useExisting: auto` or run `delete` first.

**Session logging:** All output → `logs/k0s-install-YYYY-MM-DD_HH-MM-SS.log`

## 5. Configuration Reference

The config template is `k0s-cluster-config.yaml`. Copy it and edit. Key sections:

### cluster

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | — | Cluster name (kubeconfig, labels) |
| `useExisting` | No | `never` | `auto` / `force` / `never` |
| `sshUser` | Yes | `ubuntu` | SSH user for all nodes |
| `sshKeyPath` | Yes | — | SSH private key path |

### nodes

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `controllers` | No | `1` | Controller count (1 or 3 for HA) |
| `cpuWorkers` | No | `2` | First N workers labeled CPU |
| `gpuWorkers` | No | `1` | Remaining workers labeled GPU |
| `existingIPs.controllers` | **Yes** | — | Controller IP list |
| `existingIPs.workers` | **Yes** | — | Worker IP list |

### storage

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `storageClass` | No | `local-path` | StorageClass for PVCs |
| `vectorDbSize` | No | `50Gi` | Weaviate PV size |
| `minimumDiskSpace.controller` | No | `100` | Preflight disk check (GB) |
| `minimumDiskSpace.cpuWorker` | No | `200` | Preflight disk check (GB) |
| `minimumDiskSpace.gpuWorker` | No | `500` | Preflight disk check (GB) |
| `objectStore.type` | No | `minio` | `aws` / `s3compat` / `minio` / `seaweedfs` |
| `objectStore.bucket` | No | `ai-platform-data` | Bucket name |
| `objectStore.endpoint` | **Yes*** | — | S3 endpoint (*required for non-AWS) |
| `objectStore.auth.rootUser` | Yes | — | Access key |
| `objectStore.auth.rootPassword` | Yes | — | Secret key |

### images

Short paths auto-prefixed with `images.registry`. All marked **Yes** are required; others have defaults.

| Field | Req | Default |
|-------|-----|---------|
| `registry` | No | `""` |
| `operator.image` | **Yes** | — |
| `splunk.image` | **Yes** | — |
| `splunk.operatorImage` | No | `docker.io/splunk/splunk-operator:3.0.0` |
| `ray.headImage` | **Yes** | — |
| `ray.workerImage` | **Yes** | — |
| `weaviate.image` | **Yes** | — |
| `saia.apiImage` | **Yes** | — |
| `saia.apiV2Image` | **Yes** | — |
| `saia.dataLoaderImage` | **Yes** | — |
| `nginx.image` | No | `docker.io/library/nginx:1.27-alpine` |
| `fluentBit.image` | No | `fluent/fluent-bit:1.9.6` |
| `otelCollector.image` | No | `otel/opentelemetry-collector-contrib:0.122.1` |

### aiPlatform

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | No | `${CLUSTER_NAME}-ai-platform` | CR name |
| `defaultAcceleratorType` | No | `""` | `L40S` / `H100` / empty |
| `workerGroupConfig.imageRegistry` | No | `""` | Ray worker image override |
| `features[].name` | Yes | — | Feature name (e.g., `saia`) |
| `features[].version` | Yes | — | Feature version |
| `cpuScheduling` | No | auto | `nodeSelector` + `tolerations` for CPU pods |
| `gpuScheduling` | No | auto | `nodeSelector` + `tolerations` for GPU pods |
| `serviceTemplate.type` | No | — | `NodePort` / `LoadBalancer` for SAIA exposure |
| `serviceTemplate.nodePort` | No | — | Port number (NodePort only) |

### imagePullSecrets

The `secrets[]` list is **not consumed**. The script auto-detects secrets by checking hardcoded names (`ecr-registry-secret`, `docker-hub-secret`, `gcr-secret`, `acr-secret`, `custom-registry-secret`).

| Field | Description |
|-------|-------------|
| `autoCreateECR` | Create ECR secret from AWS creds |
| `dockerHub.enabled` | Create Docker Hub secret |
| `gcr.enabled` | Create GCR secret |
| `acr.enabled` | Create ACR secret |
| `custom.enabled` | Create custom registry secret |

ECR tokens expire after 12 hours. Re-run install or set up a CronJob to refresh.

### ecr

| Field | Description |
|-------|-------------|
| `account` | AWS account ID |
| `region` | ECR region |

## 6. Node Labels & GPU

The script auto-labels nodes:

| Node type | Key labels |
|-----------|------------|
| Controller | `splunk.ai/workload-type: control-plane` |
| CPU Worker | `splunk.ai/workload-type: cpu`, `splunk.ai/instance-type: cpu-worker` |
| GPU Worker | `splunk.ai/workload-type: gpu`, `nvidia.com/gpu: "true"`, taint `nvidia.com/gpu=true:NoSchedule` |

**NVIDIA drivers** are installed directly on GPU nodes (not GPU Operator). Supported: RHEL 9/10, AL2023, Debian/Ubuntu. The script installs kernel headers, CUDA repo, `cuda-drivers`, NVIDIA Container Toolkit, then verifies with `nvidia-smi`.

## 7. Troubleshooting

**SSH failures:**
```bash
ssh -i ~/.ssh/key.pem user@node-ip hostname   # test connectivity
chmod 600 ~/.ssh/key.pem                       # fix permissions
```

**Safety gate ("refusing to wipe"):**
Set `useExisting: auto` in config, or run `delete` then `install`.

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

| What | Source |
|------|--------|
| k0s binary | `https://get.k0s.sh` |
| cert-manager v1.13.0 | `github.com/cert-manager/cert-manager` |
| kube-prometheus-stack | `prometheus-community` Helm repo |
| opentelemetry-operator | `open-telemetry` Helm repo |
| kuberay-operator v1.2.2 | `ray-project` Helm repo |
| NVIDIA device plugin | `github.com/NVIDIA/k8s-device-plugin` |
| local-path-provisioner | `github.com/rancher/local-path-provisioner` |

**Container images pulled at runtime:**

| Image | Default Source |
|-------|---------------|
| Splunk AI Operator, Ray Head/Worker, SAIA API v1/v2, Data Loader, Splunk Enterprise | ECR or configured registry |
| Weaviate | `docker.io/semitechnologies/weaviate` |
| Nginx | `docker.io/library/nginx:1.27-alpine` |
| Fluent Bit | `docker.io/fluent/fluent-bit:1.9.6` |
| OTel Collector | `docker.io/otel/opentelemetry-collector-contrib:0.122.1` |
| Splunk Operator | `docker.io/splunk/splunk-operator:3.0.0` |
| KubeRay Operator | `quay.io/kuberay/operator:v1.2.2` |
| Prometheus, Grafana, cert-manager, NVIDIA plugin, local-path | Pulled by their respective Helm charts/manifests |

**NVIDIA packages on GPU nodes (RHEL/AL2023/Ubuntu):**

| Package | Source |
|---------|--------|
| CUDA drivers | `developer.download.nvidia.com/compute/cuda/repos/` |
| Container Toolkit | `nvidia.github.io/libnvidia-container/` |
| EPEL (RHEL 10 only) | `dl.fedoraproject.org/pub/epel/` |

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
