# Adding a Custom GPU Accelerator

This guide covers adding support for a new GPU type (e.g., H200, A100, B200) without rebuilding the operator image and without changes to `ai-platform-models`.

`<aiplatform-name>` throughout this guide refers to the `metadata.name` of your `AIPlatform` CR — set via `aiPlatform.name` in `cluster-config.yaml` (e.g., `splunk-ai-stack`).

---

## Overview

GPU support spans three Kubernetes ConfigMaps created automatically by the operator on first deploy:

| ConfigMap | Controls |
|---|---|
| `<aiplatform-name>-instances` | Worker pod CPU/memory/GPU resource specs per tier |
| `<aiplatform-name>-feature-saia` | Replica counts per tier (`instanceScale`) |
| `<aiplatform-name>-applications` | Per-model `num_gpus`, `gpu_memory_utilization`, `tensor_parallel_size` |

Adding a new GPU type requires updating all three. There are two paths depending on whether you are doing a fresh install or updating an existing cluster.

---

## Path 1: New GPU from the beginning (fresh install)

Configure everything in `cluster-config.yaml` before running the install script. The operator seeds the ConfigMaps from the spec on first deploy — no `kubectl edit` needed.

### 1a. Add GPU infrastructure config to `cluster-config.yaml`

```yaml
aiPlatform:
  defaultAcceleratorType: "H200"

  gpuWorkerConfig:
    instanceTypes:
      H200:
        - tier: h200-0-gpu
          gpusPerPod: 0
          env:
            NVIDIA_VISIBLE_DEVICES: void
          resources:
            limits:
              cpu: "16"
              memory: "32Gi"
              ephemeral-storage: "10Gi"
              nvidia.com/gpu: "0"
            requests:
              cpu: "4"
        - tier: h200-1-gpu
          gpusPerPod: 1
          resources:
            requests:
              cpu: "4"
            limits:
              cpu: "16"
              memory: "96Gi"
              ephemeral-storage: "100Gi"
              nvidia.com/gpu: "1"
    instanceScale:
      H200:
        h200-0-gpu: 1
        h200-1-gpu: 2
```

The cluster setup script passes this to the `AIPlatform` CR. The operator merges `instanceTypes` into the `<name>-instances` ConfigMap and `instanceScale` into `<name>-feature-saia` at reconcile time. **Existing GPU type keys are never overwritten.**

### 1b. Set the GPU node group instance type

```yaml
nodeGroups:
  gpu:
    instanceType: "p5en.48xlarge"   # H200 — see instance type table below
    desiredCapacity: 2
    minSize: 2
    maxSize: 2
```

### 1c. Install

```bash
CONFIG_FILE=./my-cluster-config.yaml ./eks_cluster_with_stack.sh install
```

### 1d. Add per-model config to the applications ConfigMap

The `gpuWorkerConfig` field handles pod infrastructure (tiers, replicas) but **not** per-model vLLM settings. After install, edit the applications ConfigMap to add `num_gpus`, `gpu_memory_utilization`, and `tensor_parallel_size` for the new GPU type:

```bash
kubectl edit configmap <aiplatform-name>-applications -n <namespace>
# Example:
kubectl edit configmap splunk-ai-stack-applications -n ai-platform
```

For each model in `data["applications.yaml"]`, add your GPU type under `gpu_type_options_override` and `gpu_type_model_config_override`:

```yaml
- args:
    application_name: GptOss20b
    deployment_configs:
      LLMDeployment:
        gpu_type_options_override:
          H200:                         # add this block
            ray_actor_options:
              num_gpus: 0.5             # 70 GB model / 141 GB H200 VRAM
          H100:
            ray_actor_options:
              num_gpus: 0.5
          L40S:
            ray_actor_options:
              num_gpus: 1
    gpu_types: '["{{.AcceleratorType}}"]'
    model_definition:
      gpu_type_model_config_override:
        H200:                           # add this block
          engine_args:
            gpu_memory_utilization: 0.90
            tensor_parallel_size: 1
        H100:
          engine_args:
            gpu_memory_utilization: 0.90
            tensor_parallel_size: 1
        L40S:
          engine_args:
            gpu_memory_utilization: 0.90
            tensor_parallel_size: 1
```

Repeat for every model that runs on GPU (`GptOss20b`, `GptOss120b`, `UaeLarge`, `MbartTranslator`, etc.).

> **Note:** `gpu_types: '["{{.AcceleratorType}}"]'` is a Go template populated automatically by the operator from `defaultAcceleratorType`. Do not hardcode a GPU type string here.

---

## Path 2: Update GPU on an existing cluster

Use this path when adding a new GPU type to a cluster already running another GPU type (e.g., migrating from L40S to H200, or adding H200 alongside L40S).

### 2a. Add `gpuWorkerConfig` to `cluster-config.yaml` and reconcile

```yaml
aiPlatform:
  defaultAcceleratorType: "H200"   # switch to the new GPU type

  gpuWorkerConfig:
    instanceTypes:
      H200:
        - tier: h200-0-gpu
          gpusPerPod: 0
          env:
            NVIDIA_VISIBLE_DEVICES: void
          resources:
            limits:
              cpu: "16"
              memory: "32Gi"
              ephemeral-storage: "10Gi"
              nvidia.com/gpu: "0"
            requests:
              cpu: "4"
        - tier: h200-1-gpu
          gpusPerPod: 1
          resources:
            requests:
              cpu: "4"
            limits:
              cpu: "16"
              memory: "96Gi"
              ephemeral-storage: "100Gi"
              nvidia.com/gpu: "1"
    instanceScale:
      H200:
        h200-0-gpu: 1
        h200-1-gpu: 2
```

```bash
CONFIG_FILE=./my-cluster-config.yaml ./eks_cluster_with_stack.sh reconcile
```

The operator detects the new GPU type keys and merges them into the existing ConfigMaps.

### 2b. Add per-model config to the applications ConfigMap

Same as Path 1d above — edit `<aiplatform-name>-applications` and add the new GPU type entries per model.

### 2c. Provision new GPU nodes

Update `nodeGroups.gpu.instanceType` in `cluster-config.yaml` and rerun `reconcile`, or manually add the new node group via `eksctl`/cloud console.

---

## GPU instance type reference

| GPU type key | AWS Instance | GPUs | VRAM/GPU | Notes |
|---|---|---|---|---|
| `L40S` | `g6e.12xlarge` | 4 | 48 GB | Default, pre-configured in image |
| `H100` | `p5.4xlarge` | 8 | 80 GB | Pre-configured; requires capacity reservation |
| `H100_NVL` | `p4de.24xlarge` | 8 | 94 GB | Pre-configured |
| `H200` | `p5en.48xlarge` | 8 | 141 GB | Add via `gpuWorkerConfig` |
| `A100_80G` | `p4d.24xlarge` | 8 | 80 GB | Add via `gpuWorkerConfig` |

### Calculating `num_gpus` for applications.yaml

`num_gpus` is a Ray scheduling hint — fraction of a GPU's capacity allocated to one model replica:

```
num_gpus = model_vram_requirement_GB / GPU_VRAM_GB
```

Examples for H200 (141 GB VRAM):
- 120B quantized model (~80 GB) → `num_gpus = 80 / 141 ≈ 0.57` → round to `1.0` (use full GPU)
- 20B model (~40 GB) → `num_gpus = 40 / 141 ≈ 0.28` → use `0.5` (safe margin)
- Embedding model (~1 GB) → `num_gpus = 1 / 141 ≈ 0.007`

---

## Validation

After deploy or reconcile:

```bash
# Check AIPlatform status
kubectl get aiplatform -n ai-platform

# Verify worker groups include the new GPU tiers
kubectl get raycluster -n ai-platform \
  -o jsonpath='{.items[0].spec.workerGroupSpecs[*].groupName}'
# Expected: h200-0-gpu h200-1-gpu

# Verify ConfigMap was updated with new GPU type
kubectl get configmap splunk-ai-stack-instances -n ai-platform \
  -o jsonpath='{.data.instance\.yaml}' | grep -A1 "H200:"

# Check GPU nodes are ready
kubectl get nodes -l node.kubernetes.io/instance-type=p5en.48xlarge

# Check operator logs for errors
kubectl logs -n splunk-ai-operator-system \
  deployment/splunk-ai-operator-controller-manager \
  | grep -i "accelerator\|gpu\|instance"
```

If `defaultAcceleratorType` doesn't match any key in the instances ConfigMap, reconcile will fail with:

```
instance.yaml has no worker tiers for defaultAcceleratorType "H200"; keys must match exactly (e.g. L40S, H100_NVL)
```
