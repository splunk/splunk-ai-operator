# Custom Resource Guide

The Splunk AI Operator provides a collection of
[custom resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
you can use to manage Splunk AI Platform deployments in your Kubernetes cluster.

- [Custom Resource Guide](#custom-resource-guide)
  - [Metadata Parameters](#metadata-parameters)
  - [AI Platform Spec Parameters](#ai-platform-spec-parameters)
  - [AI Service Spec Parameters](#ai-service-spec-parameters)
  - [Examples of Guaranteed and Burstable QoS](#examples-of-guaranteed-and-burstable-qos)
    - [A Guaranteed QoS Class example:](#a-guaranteed-qos-class-example)
    - [A Burstable QoS Class example:](#a-burstable-qos-class-example)
    - [A BestEffort QoS Class example:](#a-besteffort-qos-class-example)
    - [Pod Resources Management](#pod-resources-management)
  - [Troubleshooting](#troubleshooting)
    - [CR Status Message](#cr-status-message)

For examples on how to use these custom resources, please see
[Configuring Splunk Enterprise Deployments](Examples.md).


## Metadata Parameters
All resources in Kubernetes include a `metadata` section. You can use this
to define a name for a specific instance of the resource, and which namespace
you would like the resource to reside within:

| Key       | Type   | Description                                                                                                 |
| --------- | ------ | ----------------------------------------------------------------------------------------------------------- |
| name      | string | Each instance of your resource is distinguished using this name.                                            |
| namespace | string | Your instance will be created within this namespace. You must ensure that this namespace exists beforehand. |

If you do not provide a `namespace`, you current context will be used.

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: example
  namespace: test
```

## AI Platform Spec Parameters

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: example
  labels:
    app.kubernetes.io/name: splunk-ai-platform-example
    app.kubernetes.io/instance: example
    app.kubernetes.io/version: 0.2.0
spec:
  objectStorage:
    path: "s3://my-ai-bucket"
    region: "us-west-2"
    secretRef: s3-secret
  serviceAccountName: "ai-platform-sa"
  features:
    - name: "saia"
      serviceAccountName: "saia-sa"
      version: "0.2.0"
  workerGroupConfig:
    serviceAccountName: "ray-worker-sa"
    imageRegistry: "123456789012.dkr.ecr.us-west-2.amazonaws.com/ray/ray-worker-gpu"  
  sidecars:
    envoy: true
    otel: true
    prometheusOperator: true
  certificateRef: "platform-issuer"
  clusterDomain: "cluster.local"
  images:
    saiaImage: "splunkai/saia:latest"
    weaviateImage: "docker.io/weaviate:latest"
    rayHeadGroupImage: "rayproject/ray-head:latest"
    rayWorkerGroupImage: "rayproject/ray-worker:latest"
  defaultAcceleratorType: "L40S"
  splunkConfiguration:
    crName: "splunk-standalone"
    crNamespace: "default"
    secretRef:
        name: "splunk-secret"
        namespace: "default"
    endpoint: "https://splunk.default.svc.cluster.local:8089" # management/JWKS
    # Required with sidecars.otel; endpoint is never used as a HEC fallback.
    hecEndpoint: "https://splunk.default.svc.cluster.local:8088"
    # Optional, if not using secretRef
    # token: "splunk-token"
  # Persistent storage for Weaviate vector database
  storage:
    vectorDB:
      # Option 1: Use existing PVC
      # pvcName: "my-existing-pvc"

      # Option 2: Create dynamic PVC (recommended)
      size: "100Gi"
      storageClassName: "gp3"  # Use appropriate StorageClass

  # Scheduling for GPU workloads (Ray workers)
  gpuScheduler:
    nodeSelector:
      node.kubernetes.io/instance-type: "g5.2xlarge"
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"

  # Scheduling for CPU workloads (Ray head, Weaviate)
  cpuScheduler:
    nodeSelector:
      workload-type: "cpu"
    tolerations: []

  # External access via Ingress (optional)
  ingress:
    enabled: true
    className: "nginx"  # or "alb", "traefik", etc.
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
    hosts:
      - host: "ai.example.com"
        paths:
          - path: "/"
            pathType: "Prefix"
    tls:
      - hosts:
          - "ai.example.com"
        secretName: "ai-platform-tls"

  # One-way server TLS (optional; `mtls` is the legacy API field name)
  mtls:
    enabled: true
    termination: "operator"  # Operator manages certificates
    secretName: "ai-platform-mtls"
    issuerRef:
      name: "ca-issuer"
      kind: "ClusterIssuer"
    dnsNames:
      - "saia.default.svc.cluster.local"
```

The `AIPlatform` resource provides the following `Spec` configuration parameters:

| Key        | Type    | Description                                       |
| ---------- | ------- | ------------------------------------------------- |
| objectStorage   | object | **Required.** S3/GCS/Azure storage configuration for model artifacts. See [Service Artifacts Storage](storage-artifacts.md) |
| serviceAccountName   | string | Kubernetes [Service Account](https://kubernetes.io/docs/concepts/security/service-accounts/) name. Used for IAM roles (IRSA on AWS) to access cloud resources |
| features   | array | List of AI features to enable (e.g., `saia` for Splunk AI Assistant) |
| defaultAcceleratorType   | string | GPU type for AI workloads (e.g., `nvidia-tesla-t4`, `nvidia-a100`, `L40S`) |
| gpuInstanceType   | string | GPU instance type for Ray worker groups (e.g., `g6.24xlarge`, `p4d.24xlarge`) |
| workerGroupConfig   | object | Ray worker node configuration (service account, image registry) |
| sidecars   | object | Enable/disable sidecars: `envoy`, `otel`, `prometheusOperator` |
| clusterDomain   | string | Kubernetes cluster domain suffix. Default: `cluster.local` |
| images   | object | Container image overrides for Ray head/worker, SAIA, Weaviate |
| certificateRef   | string | References the cert-manager issuer used to provision the legacy `mtls` field's server TLS certificate |
| splunkConfiguration   | object | Connection details for Splunk Enterprise instance |
| **storage**   | object | **Persistent storage** for Weaviate vector database. See [Storage Configuration](storage-configuration.md) |
| gpuScheduler   | object | Node selectors, affinity, tolerations for GPU workloads |
| cpuScheduler   | object | Node selectors, affinity, tolerations for CPU workloads (head, Weaviate) |
| **ingress**   | object | **External access** configuration. Exposes AI services via HTTP/HTTPS. See [Ingress Usage](ingress-configuration.md) |
| **mtls**   | object | Legacy field for **one-way, server-authentication TLS** managed by cert-manager. It does not request or validate client certificates |
| serviceTemplate   | object | Template used to create Kubernetes services for platform components |

## AI Service Spec Parameters

The AIService CR is created automatically by the AIPlatform CR, so there are no additional spec values to deploy an AIService CR on its own.

## Monitoring Your AI Platform

### Check Status

View the overall status of your AI Platform:

```bash
# View status conditions
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.conditions}' | jq .

# Check if platform is ready
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'
```

**Key Status Conditions:**
- `Ready` - Overall platform health
- `RayServiceReady` - Ray cluster status
- `RayClusterReady` - Ray pods readiness
- `RayServeRouteReady` - AI inference endpoint availability
- `WeaviateDatabaseReady` - Vector database status
- `IngressReady` - External access (if enabled)

### View Events

See what's happening with your deployment:

```bash
# Watch all events
kubectl get events -n <namespace> --watch --field-selector involvedObject.name=<name>

# See recent events
kubectl describe aiplatform <name> -n <namespace> | grep -A 20 Events:

# Filter specific event types
kubectl get events -n <namespace> --field-selector reason=RayServiceReady
kubectl get events -n <namespace> --field-selector reason=PlatformDegraded
```

For more details on events and troubleshooting, see [Error Handling and Events](troubleshooting.md).

### Quick Health Check

```bash
# One-liner to check if platform is ready
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Output: True (ready) or False (not ready)

# Get Ray service name for accessing inference API
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.rayServiceName}'

# Get Weaviate service name
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.vectorDbServiceName}'

# Get Ingress address (if enabled)
kubectl get aiplatform <name> -n <namespace> -o jsonpath='{.status.conditions[?(@.type=="IngressReady")].message}'
```
