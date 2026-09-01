# Splunk AI Operator overview

The Splunk AI Operator automates the deployment and lifecycle management of Splunk AI Platform
resources on Kubernetes. It watches AI Platform custom resources and creates the required
Kubernetes workloads, services, vector storage, and supporting configuration. Object storage and,
for static-credential deployments, credential Secrets are prerequisites that the operator
consumes; it does not provision them.

## What the operator manages

| Resource or component | Purpose |
| --- | --- |
| `AIPlatform` | Defines the platform, storage, workers, and enabled AI features. |
| `AIService` | Operator-generated resource that carries service-specific deployment requirements. |
| Ray | Runs model-serving and AI workloads on CPU or GPU workers. |
| Weaviate | Provides vector storage for AI workloads. |
| Object storage | External prerequisite that stores model and application artifacts. |
| SAIA | Provides the Splunk AI Assistant APIs. One SAIA feature creates both internal API generations. |
| SLIM | Provides the Splunk AI service integration used by supported deployments. |

SAIA V1 and V2 identify internal API generations and workloads. Customers enable the `saia`
feature once and configure one published SAIA base URL; no separate feature or endpoint selection
is required for the two generations.

## Deployment models

The operator supports the following deployment patterns:

- **Standard deployment**: cluster nodes can pull required images and access configured
  dependencies.
- **Air-gapped deployment**: images and model artifacts are staged in an approved private
  registry and object store before installation.
- **Internal Splunk integration**: Splunk is deployed in the Kubernetes environment and is
  referenced by the AI Platform configuration.
- **External Splunk integration**: Splunk is reached through a configured management endpoint.

## How reconciliation works

1. You create or update an `AIPlatform` resource.
2. The operator validates the resource and creates or updates the generated `AIService` resources.
3. The operator reconciles the dependent Kubernetes resources.
4. Status conditions and Kubernetes events report reconciliation progress and failures.
5. Supported `AIPlatform` changes are reflected in the managed workloads.

Treat generated `AIService`, Deployment, ConfigMap, Ray, and other child resources as
operator-owned. Direct changes can be overwritten during reconciliation.

## High-level architecture

```text
Kubernetes cluster
├── Splunk AI Operator
├── AI Platform
│   ├── Ray head and worker workloads
│   ├── Weaviate vector database
│   ├── SAIA front-door Service and internal V1/V2 workloads
│   └── SLIM service
└── External prerequisites
    ├── Object storage
    └── Optional Splunk deployment or external Splunk issuer
```

## Next steps

- Review [prerequisites](prerequisites.md).
- Choose an [installation method](install.md).
- Review the detailed [architecture](architecture.md) before planning production capacity.
