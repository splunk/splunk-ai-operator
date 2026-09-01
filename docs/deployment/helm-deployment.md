# Splunk AI Operator Helm Deployment Guide

This guide covers deploying the Splunk AI Operator and AI Platform using Helm charts.

## Table of Contents

- [Overview](#overview)
- [Chart Architecture](#chart-architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation Methods](#installation-methods)
- [Deploying the Operator Only](#deploying-the-operator-only)
- [Deploying Complete AI Platform](#deploying-complete-ai-platform)
- [Configuration Examples](#configuration-examples)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [Building Charts from Source](#building-charts-from-source)

## Overview

The Splunk AI Operator provides two Helm charts:

1. **`splunk-ai-operator`**: Deploys the operator controller that manages AIPlatform and AIService custom resources
2. **`splunk-ai-platform`**: Umbrella chart that deploys both the operator AND creates an AIPlatform custom resource

### Chart Distribution

Charts are distributed via:
- **OCI Registry (GHCR)**: `oci://ghcr.io/splunk/charts/` (recommended for Helm 3.8+)
- **GitHub Releases**: Available as `.tgz` files for compatibility with older Helm versions

## Chart Architecture

### Operator Chart (`splunk-ai-operator`)

Deploys the core operator components:
- Operator deployment with admission webhooks
- RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
- Webhook certificates (via cert-manager)
- Mutating and Validating webhook configurations
- CRDs for AIPlatform and AIService

### Platform Chart (`splunk-ai-platform`)

Umbrella chart that includes:
- `splunk-ai-operator` (subchart) - Optional, can be disabled
- `kuberay-operator` (optional dependency)
- `cert-manager` (optional dependency)
- `kube-prometheus-stack` (optional dependency)
- `opentelemetry-operator` (optional dependency)
- AIPlatform custom resource creation

## Prerequisites

- **Kubernetes**: v1.29+ cluster
- **Helm**: v3.8+ (for OCI registry support)
- **cert-manager**: v1.17+ (for webhook certificates, can be installed via dependency)
- **Storage**: S3-compatible object storage (AWS S3, MinIO, GCS, Azure)
- **GPU**: Optional, for AI workloads (NVIDIA GPUs with device plugin)

## Quick Start

### Deploy Operator + AIPlatform (All-in-One)

```bash
# Create a values file
cat > my-platform-values.yaml <<EOF
# Object storage configuration
objectStorage:
  path: "s3://my-bucket/artifacts"
  region: "us-west-2"
  secretRef: "s3-credentials"

# Enable AI features
features:
  - name: "saia"
    version: "1.1.0"
    serviceAccountName: "default"

# Worker configuration
workerGroupConfig:
  serviceAccountName: "default"
EOF

# Install the complete platform
helm install my-ai-platform \
  oci://ghcr.io/splunk/charts/splunk-ai-platform \
  --version 0.2.0 \
  --namespace ai-platform \
  --create-namespace \
  --values my-platform-values.yaml
```

### Deploy Operator Only

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace
```

## Installation Methods

### Method 1: OCI Registry (Recommended)

Requires Helm 3.8+:

```bash
# Install operator
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace

# Install platform
helm install my-ai-platform \
  oci://ghcr.io/splunk/charts/splunk-ai-platform \
  --version 0.2.0 \
  --namespace ai-platform \
  --create-namespace \
  --values values.yaml
```

### Method 2: GitHub Releases

Compatible with Helm 3.0+:

```bash
# Install operator
helm install splunk-ai-operator \
  https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/splunk-ai-operator-0.2.0.tgz \
  --namespace splunk-ai-operator-system \
  --create-namespace

# Install platform
helm install my-ai-platform \
  https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/splunk-ai-platform-0.2.0.tgz \
  --namespace ai-platform \
  --create-namespace \
  --values values.yaml
```

### Method 3: kubectl (Manifests)

For environments where Helm is not available:

```bash
kubectl apply -f https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/install-v0.2.0.yaml
```

## Deploying the Operator Only

Use this when you want to manually create AIPlatform resources via kubectl.

### Basic Installation

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace
```

### Custom Configuration

Create `operator-values.yaml`:

```yaml
# Operator image configuration
image:
  repository: ghcr.io/splunk/splunk-ai-operator
  tag: "v0.2.0"
  pullPolicy: IfNotPresent

# Container images used by the operator
splunkEnterpriseImage: "docker.io/splunk/splunk:10.2.0"
rayHeadImage: "myregistry.com/ray/ray-head:v2.44.0"
rayWorkerImage: "myregistry.com/ray/ray-worker-gpu:v2.44.0"
weaviateImage: "docker.io/semitechnologies/weaviate:stable-v1.28-007846a"
saiaApiImage: "myregistry.com/saia/api:v1.1.0"
saiaSchemaImage: "myregistry.com/saia/data-loader:v1.1.0"

# Webhook configuration
webhook:
  enabled: true
  port: 9443

# Resource limits
resources:
  limits:
    cpu: 500m
    memory: 128Mi
  requests:
    cpu: 10m
    memory: 64Mi

# Watch specific namespaces (empty = all)
watchNamespace: ""

# Tolerations for dedicated nodes
tolerations:
  - key: dedicated
    operator: Equal
    value: cpu
    effect: NoSchedule
```

Install with custom values:

```bash
helm install splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --create-namespace \
  --values operator-values.yaml
```

### View Operator Configuration Options

```bash
# Show all configurable values
helm show values oci://ghcr.io/splunk/charts/splunk-ai-operator --version 0.2.0

# Show chart information
helm show chart oci://ghcr.io/splunk/charts/splunk-ai-operator --version 0.2.0

# Show complete details
helm show all oci://ghcr.io/splunk/charts/splunk-ai-operator --version 0.2.0
```

## Deploying Complete AI Platform

The `splunk-ai-platform` chart is an umbrella chart that deploys everything needed for a complete AI platform.

### Understanding Dependencies

The platform chart includes these optional dependencies:

```yaml
dependencies:
  - splunk-ai-operator    # Can be disabled if already installed
  - kuberay-operator      # Ray cluster orchestration
  - cert-manager          # Certificate management
  - kube-prometheus-stack # Monitoring and observability
  - opentelemetry-operator # Distributed tracing
```

Each can be enabled/disabled independently.

### Minimal Configuration

Create `platform-values.yaml`:

```yaml
# Required: Object storage
objectStorage:
  path: "s3://my-bucket/artifacts"
  region: "us-west-2"
  secretRef: ""  # Or provide secret name

# Required: At least one feature
features:
  - name: "saia"
    version: "1.1.0"
    serviceAccountName: "default"

# Required: Worker configuration
workerGroupConfig:
  serviceAccountName: "default"
```

Install:

```bash
helm install my-platform \
  oci://ghcr.io/splunk/charts/splunk-ai-platform \
  --version 0.2.0 \
  --namespace ai-platform \
  --create-namespace \
  --values platform-values.yaml
```

### Complete Configuration Example

Create `complete-platform-values.yaml`:

```yaml
# ============================================
# Dependency Chart Configuration
# ============================================

# Splunk AI Operator (can disable if already installed)
splunk-ai-operator:
  enabled: true
  image:
    repository: ghcr.io/splunk/splunk-ai-operator
    tag: "v0.2.0"

# KubeRay Operator
kuberay-operator:
  enabled: true

# Cert-Manager (for certificates)
cert-manager:
  enabled: true
  installCRDs: true

# Prometheus Stack (for monitoring)
prometheus:
  enabled: false  # Enable if you want observability

# OpenTelemetry Operator (for tracing)
opentelemetry-operator:
  enabled: false

# ============================================
# AIPlatform Configuration
# ============================================

# Override release namespace
namespaceOverride: "ai-platform"

# Object storage (REQUIRED)
objectStorage:
  path: "s3://my-ai-bucket/artifacts"
  region: "us-west-2"
  secretRef: "s3-credentials"
  endpoint: ""  # Optional for S3-compatible (MinIO, etc.)

# Service account for platform components
serviceAccountName: "ray-worker-sa"

# GPU configuration
gpuInstanceType: "g6e.12xlarge"
defaultAcceleratorType: "L40S"
scaleFactor: 1  # Platform-wide model and worker capacity

# AI Features (REQUIRED)
features:
  - name: "saia"
    serviceAccountName: "saia-service-sa"
    version: "1.1.0"

# Worker group configuration
workerGroupConfig:
  serviceAccountName: "ray-worker-sa"
  imageRegistry: ""
  gpuConfigs:
    # CPU-only workers
    - tier: "cpu-only"
      minReplicas: 1
      maxReplicas: 5
      gpusPerPod: 0
      resources:
        requests:
          cpu: "4"
          memory: "16Gi"
        limits:
          cpu: "16"
          memory: "32Gi"

    # Single GPU workers
    - tier: "single-gpu"
      minReplicas: 0
      maxReplicas: 10
      gpusPerPod: 1
      resources:
        requests:
          cpu: "4"
          memory: "16Gi"
        limits:
          cpu: "16"
          memory: "32Gi"
          nvidia.com/gpu: "1"

    # Quad GPU workers
    - tier: "quad-gpu"
      minReplicas: 0
      maxReplicas: 5
      gpusPerPod: 4
      resources:
        requests:
          cpu: "8"
          memory: "64Gi"
        limits:
          cpu: "32"
          memory: "128Gi"
          nvidia.com/gpu: "4"

# Sidecar injection
sidecars:
  envoy: false
  otel: false
  prometheusOperator: false

# Custom container images (override operator defaults)
images:
  saiaImage: ""  # Empty uses operator default
  weaviateImage: ""
  rayHeadGroupImage: ""
  rayWorkerGroupImage: ""
  imagePullSecrets:
    - name: ecr-registry-secret
    - name: dockerhub-secret

# Splunk configuration (for observability)
splunkConfiguration:
  endpoint: "https://splunk.splunk.svc.cluster.local:8089"
  secretRef:
    name: "splunk-secret"
    namespace: "splunk"
  secretSource: "kubernetes"

# Storage configuration
storage:
  vectorDB:
    size: "50Gi"
    storageClassName: "gp3"
    pvcName: ""  # Optional existing PVC

# GPU scheduling
gpuScheduler:
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node.kubernetes.io/instance-type
                operator: In
                values:
                  - g6e.12xlarge

# CPU scheduling
cpuScheduler:
  tolerations:
    - key: dedicated
      operator: Equal
      value: cpu
      effect: NoSchedule

# mTLS configuration (optional)
mtls:
  enabled: false
  issuerRef:
    name: "platform-issuer"
    kind: "Issuer"
    group: "cert-manager.io"
  secretName: "mtls-cert"
```

Install with complete configuration:

```bash
helm install my-platform \
  oci://ghcr.io/splunk/charts/splunk-ai-platform \
  --version 0.2.0 \
  --namespace ai-platform \
  --create-namespace \
  --values complete-platform-values.yaml
```

### Install with Existing Operator

If the operator is already installed, disable it in the platform chart:

```yaml
splunk-ai-operator:
  enabled: false  # Operator already installed

# Rest of platform configuration...
```

Or via command line:

```bash
helm install my-platform \
  oci://ghcr.io/splunk/charts/splunk-ai-platform \
  --version 0.2.0 \
  --namespace ai-platform \
  --create-namespace \
  --set splunk-ai-operator.enabled=false \
  --values platform-values.yaml
```

## Configuration Examples

### Example 1: Private Registry Configuration

```yaml
# Use images from AWS ECR
splunk-ai-operator:
  image:
    repository: "123456789012.dkr.ecr.us-west-2.amazonaws.com/splunk-ai-operator"
    tag: "v0.2.0"

  rayHeadImage: "123456789012.dkr.ecr.us-west-2.amazonaws.com/ray/ray-head:v2.44.0"
  rayWorkerImage: "123456789012.dkr.ecr.us-west-2.amazonaws.com/ray/ray-worker-gpu:v2.44.0"
  saiaApiImage: "123456789012.dkr.ecr.us-west-2.amazonaws.com/saia/api:v1.1.0"
  saiaSchemaImage: "123456789012.dkr.ecr.us-west-2.amazonaws.com/saia/data-loader:v1.1.0"

images:
  imagePullSecrets:
    - name: ecr-registry-secret
```

Create the image pull secret:

```bash
kubectl create secret docker-registry ecr-registry-secret \
  --docker-server=123456789012.dkr.ecr.us-west-2.amazonaws.com \
  --docker-username=AWS \
  --docker-password=$(aws ecr get-login-password --region us-west-2) \
  --namespace ai-platform
```

### Example 2: Development/Testing Setup

```yaml
# Minimal configuration for testing
objectStorage:
  path: "s3://test-bucket"
  region: "us-west-2"

features:
  - name: "saia"
    version: "1.1.0"
    serviceAccountName: "default"

workerGroupConfig:
  serviceAccountName: "default"
  gpuConfigs:
    - tier: "cpu-only"
      minReplicas: 1
      maxReplicas: 2
      gpusPerPod: 0
      resources:
        limits:
          cpu: "2"
          memory: "4Gi"

storage:
  vectorDB:
    size: "10Gi"

# Disable optional dependencies
kuberay-operator:
  enabled: false  # Already installed

cert-manager:
  enabled: false  # Already installed

prometheus:
  enabled: false

opentelemetry-operator:
  enabled: false
```

### Example 3: Production Setup with HA

```yaml
objectStorage:
  path: "s3://prod-ai-bucket/artifacts"
  region: "us-west-2"
  secretRef: "s3-credentials"

serviceAccountName: "ray-worker-prod-sa"
scaleFactor: 3  # Three times the base model and worker capacity

features:
  - name: "saia"
    version: "1.1.0"
    serviceAccountName: "saia-prod-sa"

workerGroupConfig:
  serviceAccountName: "ray-worker-prod-sa"
  gpuConfigs:
    - tier: "ha-cpu"
      minReplicas: 3
      maxReplicas: 10
      gpusPerPod: 0
      resources:
        requests:
          cpu: "8"
        limits:
          cpu: "16"
          memory: "64Gi"

storage:
  vectorDB:
    size: "500Gi"
    storageClassName: "fast-ssd"

gpuScheduler:
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node.kubernetes.io/instance-type
                operator: In
                values:
                  - g6e.12xlarge
                  - p4d.24xlarge

# Enable monitoring
prometheus:
  enabled: true

sidecars:
  otel: true
  prometheusOperator: true
```

## Upgrading

### Upgrade Operator

```bash
# OCI Registry
helm upgrade splunk-ai-operator \
  oci://ghcr.io/splunk/charts/splunk-ai-operator \
  --version 0.2.0 \
  --namespace splunk-ai-operator-system \
  --reuse-values

# Or from GitHub Release
helm upgrade splunk-ai-operator \
  https://github.com/splunk/splunk-ai-operator/releases/download/v0.2.0/splunk-ai-operator-0.2.0.tgz \
  --namespace splunk-ai-operator-system \
  --reuse-values
```

### Upgrade Platform

```bash
helm upgrade my-platform \
  oci://ghcr.io/splunk/charts/splunk-ai-platform \
  --version 0.2.0 \
  --namespace ai-platform \
  --values platform-values.yaml
```

### Modify Configuration

```bash
# Update platform-wide model and worker capacity
helm upgrade my-platform \
  oci://ghcr.io/splunk/charts/splunk-ai-platform \
  --namespace ai-platform \
  --set scaleFactor=5 \
  --reuse-values
```

`scaleFactor` must be an integer greater than or equal to `1`. If omitted, it defaults to `1`.

## Uninstalling

### Uninstall Platform

```bash
# Remove platform (keeps operator)
helm uninstall my-platform -n ai-platform

# Optionally delete namespace
kubectl delete namespace ai-platform
```

### Uninstall Operator

```bash
helm uninstall splunk-ai-operator -n splunk-ai-operator-system

# Optionally remove CRDs (WARNING: deletes all resources!)
kubectl delete crd aiplatforms.ai.splunk.com
kubectl delete crd aiservices.ai.splunk.com
```

## Troubleshooting

### Check Helm Release Status

```bash
# List releases
helm list -n ai-platform

# Show release values
helm get values my-platform -n ai-platform

# Show all release information
helm get all my-platform -n ai-platform
```

### Check Operator Logs

```bash
kubectl logs -n ai-platform -l control-plane=controller-manager -f
```

### Check AIPlatform Status

```bash
kubectl get aiplatform -n ai-platform
kubectl describe aiplatform my-platform-splunk-ai-platform -n ai-platform
```

### Common Issues

**Issue: ImagePullBackOff**
```bash
# Check image pull secrets
kubectl get secrets -n ai-platform
kubectl describe pod <pod-name> -n ai-platform

# Verify image exists
docker pull <image-name>
```

**Issue: Webhook Certificate Errors**
```bash
# Check certificates
kubectl get certificates -n ai-platform
kubectl describe certificate splunk-ai-operator-serving-cert -n ai-platform

# Verify cert-manager is running
kubectl get pods -n cert-manager
```

**Issue: Missing Splunk Secret**
```bash
# Create Splunk credentials secret
kubectl create secret generic splunk-secret \
  -n ai-platform \
  --from-literal=password='your-password'
```

### Debug Template Rendering

```bash
# Render templates without installing
helm template test-release \
  oci://ghcr.io/splunk/charts/splunk-ai-platform \
  --version 0.2.0 \
  --values platform-values.yaml \
  --debug
```

## Building Charts from Source

### Prerequisites

- `helm` CLI (v3.8+)
- `make`
- Git repository cloned

### Build Commands

```bash
# Lint charts
helm lint helm-chart/splunk-ai-operator
helm lint helm-chart/splunk-ai-platform

# Package operator chart
helm package helm-chart/splunk-ai-operator --destination dist/

# Package platform chart (after updating operator dependency)
cd helm-chart/splunk-ai-operator
helm package . --destination ../splunk-ai-platform/charts/
cd ../splunk-ai-platform
helm package . --destination ../../dist/

# Test local installation
helm install test-operator ./helm-chart/splunk-ai-operator \
  --namespace test \
  --create-namespace \
  --values test-values.yaml

# Dry-run to check templates
helm install test-platform ./helm-chart/splunk-ai-platform \
  --namespace test \
  --create-namespace \
  --values test-values.yaml \
  --dry-run --debug
```

### Update Dependencies

```bash
cd helm-chart/splunk-ai-platform

# Update dependencies from Chart.yaml
helm dependency update

# Or build locally
helm dependency build
```

## Additional Resources

- **Helm Chart README**: [helm-chart/splunk-ai-operator/README.md](../../helm-chart/splunk-ai-operator/README.md)
- **Platform Chart README**: [helm-chart/splunk-ai-platform/README.md](../../helm-chart/splunk-ai-platform/README.md)
- **Example Values**: [helm-chart/splunk-ai-platform/values-example.yaml](../../helm-chart/splunk-ai-platform/values-example.yaml)
- **API Reference**: [../api-reference.md](../api-reference.md)
- **Troubleshooting**: [../troubleshooting.md](../troubleshooting.md)

## Learn More

- [Helm Documentation](https://helm.sh/docs/)
- [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)
- [Splunk AI Operator GitHub](https://github.com/splunk/splunk-ai-operator)
- [Artifact Hub](https://artifacthub.io) (after first release)
