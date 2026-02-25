# Object Storage Selection

This document describes how the Splunk AI Operator chooses the object storage backend and how to configure AWS S3, MinIO, SeaweedFS, or any S3-compatible storage.

## How the operator decides the backend

The operator selects the storage backend **only by the path scheme** in `spec.objectStorage.path`:

| Path scheme     | Backend behavior                    | cloudProvider | artifactsProvider |
|-----------------|-------------------------------------|---------------|-------------------|
| `s3://`         | **AWS S3** (region, IRSA, no custom endpoint) | `aws`         | `s3`              |
| `s3compat://`   | **S3-compatible** (generic; requires endpoint + secretRef) | `s3compat`    | `s3`              |
| `minio://`      | **MinIO** (alias for S3-compatible)  | `s3compat`    | `s3`              |
| `seaweedfs://`  | **SeaweedFS** (alias for S3-compatible) | `s3compat`    | `s3`              |
| `gs://` / `gcs://` | **GCP Cloud Storage**            | `gcp`         | `gcs`             |
| `azure://`      | **Azure Blob Storage**               | `azure`       | `azure`           |

- **Path scheme** is the only decision input; there is no separate "provider type" switch in the operator logic.
- For **S3-compatible** backends (MinIO, SeaweedFS, Ceph, or any custom S3 API), use **`s3compat://bucket/prefix`** with `endpoint` and `secretRef` set. You can also use `minio://` or `seaweedfs://` as aliases; all use the same implementation (AWS S3 SDK with custom endpoint and path-style).

## cloudProvider vs artifactsProvider

- **cloudProvider**: Identifies the *platform* (e.g. `aws` for native AWS S3, `s3compat` for MinIO/SeaweedFS/other S3-compatible). Used for telemetry and any logic that needs to distinguish "real AWS" from "custom S3-compatible".
- **artifactsProvider**: The *protocol* used to access artifacts. For all S3 API backends (AWS S3, MinIO, SeaweedFS) the protocol is the S3 API, so `artifactsProvider` is always `s3` for those. Only GCS and Azure use different protocols (`gcs`, `azure`).

## Path schemes and required fields

- **`s3://bucket/prefix`**  
  - Use for **AWS S3** only.  
  - Set `region`. Optionally use `secretRef` for static credentials; otherwise IRSA or default AWS credential chain is used. Do **not** set `endpoint` for native S3.

- **`s3compat://bucket/prefix`**  
  - Use for **any S3-compatible** backend (MinIO, SeaweedFS, Ceph, etc.).  
  - **Required:** `endpoint` (e.g. `http://minio.namespace.svc:9000` or `http://seaweedfs-s3:8333`), `region` (any value), `secretRef` with `s3_access_key` and `s3_secret_key`.

- **`minio://bucket/prefix`**  
  - Alias for S3-compatible; use for **MinIO** (in-cluster or external). Same requirements as `s3compat://`.

- **`seaweedfs://bucket/prefix`**  
  - Alias for S3-compatible; use for **SeaweedFS** (bring your own). Same requirements as `s3compat://`.

## Optional provider field

`spec.objectStorage.provider` is an optional hint for documentation and tooling. Allowed values: `aws`, `minio`, `seaweedfs`, `s3compat`, `gcs`, `azure`. The operator **does not** use this field to select the backend; behavior is derived only from the path scheme (and for `s3://`, absence of endpoint). Use it for clarity in manifests or scripts.

## YAML examples

### AWS S3

```yaml
spec:
  objectStorage:
    path: s3://my-ai-bucket/artifacts
    region: us-east-2
    # secretRef optional when using IRSA
```

### MinIO (in-cluster)

```yaml
spec:
  objectStorage:
    path: minio://ai-platform-bucket/artifacts
    endpoint: http://minio.minio.svc.cluster.local:9000
    region: us-east-1
    secretRef: minio-credentials
```

### MinIO (external, e.g. EC2)

```yaml
spec:
  objectStorage:
    path: minio://ai-platform-bucket/artifacts
    endpoint: http://10.0.1.50:9000
    region: us-east-1
    secretRef: minio-credentials
```

### SeaweedFS

```yaml
spec:
  objectStorage:
    path: seaweedfs://my-bucket/artifacts
    endpoint: http://seaweedfs-s3.my-namespace.svc:8333
    region: us-east-1
    secretRef: minio-credentials
```

### Generic S3-compatible (e.g. Ceph, custom endpoint)

```yaml
spec:
  objectStorage:
    path: s3compat://my-bucket/artifacts
    endpoint: http://s3-gateway.my-namespace.svc:8333
    region: us-east-1
    secretRef: minio-credentials
```

The same Kubernetes secret format is used for all S3-compatible backends: keys `s3_access_key` and `s3_secret_key`. Pods receive these as `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, and `MINIO_ENDPOINT_URL` (when endpoint is set).

## Adding new S3-compatible backends

Any storage that exposes an S3-compatible API (e.g. Ceph, DigitalOcean Spaces) can be used by using **`s3compat://bucket`** with the appropriate `endpoint` and `secretRef`. No new client code or scheme is required; `minio://` and `seaweedfs://` remain as optional aliases for clarity.
