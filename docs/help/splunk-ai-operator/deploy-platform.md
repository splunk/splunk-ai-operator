# Deploy the AI Platform

Create an `AIPlatform` custom resource after the operator is running. The resource describes
object storage, vector storage, AI features, workers, scheduling, and external access.

## Minimal platform example

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: my-ai-platform
  namespace: ai-platform
spec:
  objectStorage:
    path: s3://my-ai-bucket/artifacts
    region: us-west-2
    secretRef: object-storage-credentials

  features:
    - name: saia
      version: "<saia-version>"
      serviceAccountName: saia-service-account

  storage:
    vectorDB:
      size: 100Gi
      storageClassName: <storage-class>

  workerGroupConfig:
    serviceAccountName: ray-worker-service-account
```

Apply the resource:

```bash
kubectl apply -f ai-platform.yaml
```

## Configure object storage

Set `spec.objectStorage.path` to an AWS S3 or S3-compatible artifact location. For S3-compatible
storage, also provide the endpoint and credentials required by that service. Keep credentials in
Kubernetes Secrets or the approved secret-management system.

## Configure vector storage

Use `spec.storage.vectorDB` to either:

- request a dynamically provisioned volume with `size` and `storageClassName`, or
- reference an existing persistent volume claim with `pvcName`.

Use durable storage for production deployments. Without it, vector data can be lost when the
Weaviate workload is recreated.

## Configure workers

Platform capacity is controlled by the GPU instance and worker settings, `scaleFactor`, and the
CPU/GPU scheduler fields on `AIPlatform`. Ensure that the requested resources match the actual
node capacity and installed device plugins.

## Configure ingress

Enable ingress when clients need a stable external host name:

```yaml
spec:
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: ai.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - ai.example.com
        secretName: ai-platform-tls
```

The ingress controller and DNS record must be available in the target cluster. The `tls` block
configures client-to-ingress TLS; it does not enable TLS between operator-managed pods or
services.

## Check platform status

```bash
kubectl get aiplatform my-ai-platform -n ai-platform
kubectl describe aiplatform my-ai-platform -n ai-platform
kubectl get events -n ai-platform \
  --field-selector involvedObject.name=my-ai-platform \
  --sort-by='.lastTimestamp'
```

Wait for the platform and required component conditions to report ready before configuring
customer access.
