# Deploy the AI Platform

Create an `AIPlatform` custom resource after the operator is running. The resource describes
object storage, vector storage, AI features, workers, scheduling, and external access.

## Minimal k0s platform example

The following `AIPlatform` example is for the release-qualified k0s path. For OpenShift, use the
[OpenShift deployment procedure](../../../tools/cluster_setup/OPENSHIFT_README.md), including its
accelerator, storage, security-context, and Route settings.

Create the workload namespace before creating any namespaced prerequisites or the `AIPlatform`
resource:

```bash
kubectl create namespace ai-platform
```

The following example uses static S3 credentials. Create the referenced Secret in the same
namespace as the `AIPlatform`:

```bash
kubectl create secret generic object-storage-credentials \
  --namespace ai-platform \
  --from-file=s3_access_key=<protected-access-key-file> \
  --from-file=s3_secret_key=<protected-secret-key-file>
```

Protect the credential files and remove them according to your organization's secret-handling
policy after the Secret is created. Do not put credential values directly in shell arguments.
The Secret is not the only object that holds these values in this release: Ray reconciliation
copies them into generated configuration. Review [Configure object storage](#configure-object-storage)
before using static credentials.

If the cluster uses an approved workload-identity mechanism instead, omit `secretRef`, pre-create
the required ServiceAccounts in the workload namespace, and attach them with the fields described
in [Use workload identity](#use-workload-identity). The operator does not create a custom
ServiceAccount when an explicit name is supplied.

```yaml
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: my-ai-platform
  namespace: ai-platform
spec:
  objectStorage:
    path: s3://my-ai-bucket
    region: us-west-2
    secretRef: object-storage-credentials

  features:
    - name: saia

  storage:
    vectorDB:
      size: 100Gi
      storageClassName: <storage-class>

  # Keep this object present. With no override, Ray workers use the namespace's
  # default ServiceAccount.
  workerGroupConfig: {}

  # L40S and H100 are the supported k0s accelerator values for this release.
  defaultAcceleratorType: L40S

  # HEC/OTel telemetry is not supported in this release.
  sidecars:
    otel: false
```

Replace the bucket, region, storage class, and credentials with release-supported values. The
bucket and storage class must already exist. `objectStorage.region` is required by the current CRD
for every object-storage provider.

Apply the resource:

```bash
kubectl apply -f ai-platform.yaml
```

## Configure object storage

Set `spec.objectStorage.path` to an AWS S3 or S3-compatible bucket URI. In this release, active Ray
and SAIA paths use only the bucket name and ignore a prefix after it. Use `s3://<bucket-name>` and
place artifacts in the release-defined root-relative layout; do not use a path suffix to isolate a
deployment. For S3-compatible storage, also provide the endpoint and credentials required by that
service.

When static credentials are used, the operator reads the referenced Secret and snapshots the
values into the generated `RayService` configuration and the `<AIPlatform-name>-serve-config`
ConfigMap. Restrict access to those resources as sensitive data. Prefer a release-supported
workload-identity mechanism where available. This release does not provide Secret-only handling
for static Ray object-storage credentials.

## Use workload identity

For a supported workload-identity integration, pre-create all named ServiceAccounts in the same
namespace as the `AIPlatform` and attach them independently:

```yaml
spec:
  # Ray head
  serviceAccountName: ray-head-service-account
  workerGroupConfig:
    # Ray worker groups
    serviceAccountName: ray-worker-service-account
  features:
    - name: saia
      # SAIA workloads
      serviceAccountName: saia-service-account
    - name: slim
      # SLIM workloads
      serviceAccountName: slim-service-account
```

When these fields are omitted, Ray uses the namespace's default ServiceAccount and the SAIA and
SLIM reconcilers create per-service accounts. Merely creating a ServiceAccount does not attach it
to a workload.

## Configure vector storage

Use `spec.storage.vectorDB` to either:

- request a dynamically provisioned volume with `size` and `storageClassName`, or
- reference an existing persistent volume claim with `pvcName`.

The operator-created volume claim requests `ReadWriteOnce`. Use durable storage for production
deployments. Without it, vector data can be lost when the Weaviate workload is recreated.

## Configure workers

Use `spec.scaleFactor` to multiply both the base Ray Serve model-replica counts and every Ray
worker-group count in the selected accelerator profile, including its zero-GPU group. The default
and minimum value is `1`. CPU and GPU scheduler fields control placement; they do not change
per-pod resources. Ensure that node labels, taints, GPUs, CPU, memory, storage, and object-store
capacity can accommodate the requested scale.

## Expose SAIA

The `saia` feature creates a front-door Service named
`<AIPlatform-name>-saia-saia-service` on port `8080`. Its nginx proxy routes both internal SAIA API
generations. The Service type is `ClusterIP` by default and is not externally reachable until you
publish it. To use ingress, create a separate Kubernetes `Ingress` that targets that Service after
it exists. For the minimal example:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ai-platform-saia
  namespace: ai-platform
spec:
  ingressClassName: nginx
  rules:
    - host: saia.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-ai-platform-saia-saia-service
                port:
                  number: 8080
  tls:
    - hosts:
        - saia.example.com
      secretName: saia-tls
```

Create `saia-tls` in `ai-platform` or configure a certificate controller to issue it. This example
terminates client TLS at the Ingress and forwards HTTP to the SAIA Service; it does not enable TLS
between workloads inside the cluster. Apply the required authentication, CORS, DNS, and network
controls before allowing browser access.

## Check platform status

```bash
kubectl get aiplatform my-ai-platform -n ai-platform
kubectl describe aiplatform my-ai-platform -n ai-platform
kubectl get pods,services,endpoints -n ai-platform
kubectl get events -n ai-platform --sort-by='.lastTimestamp'
```

Conditions primarily report reconciliation progress. Before configuring customer access, also
verify that every required pod is ready and that the generated Services have endpoints.
