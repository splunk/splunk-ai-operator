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
          ├── SAIA V1 and V2 deployments
          ├── SLIM deployment
          ├── Services and ingress
          └── Configuration and secrets
```

## Request paths

SAIA V1 and SAIA V2 are separate services and can have different client request paths:

```text
SAIA V1:
Browser or client → Search Head / SAIA App backend → SAIA V1 service

SAIA V2:
Browser or client → SAIA V2 service
```

In a private or air-gapped environment, the browser may require an approved proxy or tunnel to
reach the Search Head and the SAIA V2 service. See [Access and connectivity](access-and-connectivity.md).

## Storage

- **Object storage** holds model and application artifacts.
- **Vector database storage** is configured through `spec.storage.vectorDB`.
- An existing persistent volume can be referenced when storage lifecycle is managed separately.
- Supported remote object storage in this guide is AWS S3 or an S3-compatible service such as
  MinIO or SeaweedFS.

## Control-plane and data-plane responsibilities

The operator is responsible for reconciliation, configuration, and lifecycle management. The
managed workloads are responsible for serving AI requests, executing model workloads, storing
vectors, and communicating with configured Splunk endpoints.
