# Splunk AI Platform architecture

The Splunk AI Operator is the control plane for AI Platform resources. It does not run the
AI workload itself; it creates and maintains the Kubernetes resources that run the workload.

## Component relationships

```text
AIPlatform custom resource
          │
          ▼
Splunk AI Operator
          │
          ├── Ray service and worker groups
          ├── Weaviate StatefulSet and persistent storage
          ├── SAIA front-door Service and internal V1/V2 deployments
          ├── SLIM deployment
          ├── Ray and Weaviate ingress
          └── Configuration and customer-managed credential inputs
```

## Request paths

SAIA V1 and V2 are internal API generations deployed together by the `saia` feature. The
operator-managed SAIA service uses an nginx proxy to route both API path families behind one base
URL. Customers do not select a generation or configure separate SAIA endpoints.

```text
Splunk AI Assistant app or browser
        → separately published SAIA URL
        → SAIA nginx proxy
        ├── internal V1 workload
        └── internal V2 workload
```

Depending on the app workflow, the browser, the Splunk host, or both might need network access to
the published SAIA URL. In a private or air-gapped environment, use an approved routed connection,
proxy, or tunnel. See [Access and connectivity](access-and-connectivity.md).

`AIPlatform.spec.ingress` does not publish SAIA or SLIM. It routes `/dashboard` to the Ray
dashboard, `/weaviate` to Weaviate, and other configured paths to Ray Serve. Publish the generated
SAIA or SLIM Service separately when clients outside the cluster require access.

## Storage

- **Object storage** is an external prerequisite that holds model and application artifacts.
- **Vector database storage** is configured through `spec.storage.vectorDB`.
- An existing same-namespace persistent volume claim can be referenced when storage lifecycle is
  managed separately.
- Supported remote object storage in this guide is AWS S3 or an S3-compatible service such as
  MinIO or SeaweedFS.

Static Ray object-storage credentials are read from the referenced Secret and copied into
operator-generated Ray configuration objects in this release. Treat those objects as sensitive;
see [Security and networking](security.md#credentials-and-secrets).

## Control-plane and data-plane responsibilities

The operator is responsible for reconciliation, generated configuration, and lifecycle management
of its Kubernetes resources. Managed workloads serve AI requests, execute model workloads, store
vectors, and communicate with configured object-storage and Splunk endpoints.
