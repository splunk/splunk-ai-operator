# Splunk AI Operator overview

The Splunk AI Operator automates the deployment and lifecycle management of Splunk AI Platform
resources on Kubernetes. It watches AI Platform custom resources and creates the required
Kubernetes workloads, services, storage, ingress, and supporting configuration.

## What the operator manages

| Resource or component | Purpose |
| --- | --- |
| `AIPlatform` | Defines the platform, storage, workers, ingress, and enabled AI features. |
| `AIService` | Defines service-specific configuration and deployment requirements. |
| Ray | Runs model-serving and AI workloads on CPU or GPU workers. |
| Weaviate | Provides vector storage for AI workloads. |
| Object storage | Stores model artifacts, application data, and platform artifacts. |
| SAIA | Provides the Splunk AI Assistant APIs, including V1 and V2 services. |
| SLIM | Provides the Splunk AI service integration used by supported deployments. |
| Ingress | Exposes configured services; ingress TLS can be enabled when the cluster has a suitable certificate and ingress controller. |

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

1. You create or update an `AIPlatform` or `AIService` resource.
2. The operator validates the resource and reconciles the requested state.
3. The operator creates or updates dependent Kubernetes resources.
4. Status conditions and Kubernetes events report progress and failures.
5. Changes to the custom resource are reflected in the managed workloads.

## High-level architecture

```text
Kubernetes cluster
├── Splunk AI Operator
├── AI Platform
│   ├── Ray head and worker workloads
│   ├── Weaviate vector database
│   ├── SAIA V1 service
│   ├── SAIA V2 service
│   └── SLIM service
└── Supporting services
    ├── Object storage
    ├── Ingress and TLS
    └── Optional Splunk deployment or external Splunk endpoint
```

## Next steps

- Review [prerequisites](prerequisites.md).
- Choose an [installation method](install.md).
- Review the detailed [architecture](architecture.md) before planning production capacity.
