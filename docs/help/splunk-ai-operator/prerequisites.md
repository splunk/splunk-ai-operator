# Prerequisites

Review the support statement published for the exact release before installing. Do not use a
compatibility file from a different operator release.

## Supported release combination

Use the following qualified versions together for this release:

| Component | Version |
| --- | --- |
| Splunk Enterprise | 10.2 |
| [Splunk AI Assistant app](https://splunkbase.splunk.com/app/7245) | 2.3.0 |
| AI Tier / Splunk AI Operator release | v1.0 |
| SAIA API V1 image | `docker.io/splunk/ai-tier-saia-api:v1.0` |
| SAIA API V2 image | `docker.io/splunk/ai-tier-saia-api-v2:v1.0` |
| SAIA data-loader image | `docker.io/splunk/ai-tier-saia-data-loader:v1.0` |
| SLIM service image | `docker.io/splunk/ai-tier-slim-service:v1.0` |
| Ray runtime | 2.56.0 |
| Ray head image | `docker.io/splunk/ai-tier-ray-head:v1.0` |
| Ray worker image | `docker.io/splunk/ai-tier-ray-worker:v1.0` |

SAIA image version `v1.0` is the container release tag, not an API-generation selection.

## Cluster requirements

The following deployment paths are qualified for this release:

| Deployment path | Qualified platform | Accelerator | Detailed requirements |
| --- | --- | --- | --- |
| k0s | k0s v1.31 or later on amd64; validated on v1.36.1. Installer and node operating systems must follow the standard or air-gapped matrix. | NVIDIA L40S or H100 | [k0s supported-platform matrix](../../../tools/cluster_setup/DEPLOYMENT_GUIDE.md#supported-platforms) |
| OpenShift | OpenShift Container Platform 4.21.x on RHCOS amd64 nodes. | NVIDIA RTX Pro 6000 Blackwell | [OpenShift prerequisites](../../../tools/cluster_setup/OPENSHIFT_README.md#prerequisites) |

Do not infer support for another Kubernetes distribution, version, node operating system, or
accelerator from the generic Kubernetes API examples in this guide.

- A cluster that matches one of the qualified deployment paths above.
- `kubectl` configured to use the target cluster.
- Cluster-admin access for installing CRDs, RBAC, webhooks, and operator resources.
- Sufficient CPU, memory, persistent storage, and GPU capacity for the selected workloads.
- A supported ingress controller when external HTTP or HTTPS access is required.
- DNS that resolves the configured service and ingress host names.

`AIPlatform.spec.ingress` publishes Ray and Weaviate routes only. Plan a separate supported
Service, ingress, or proxy path for SAIA and SLIM clients.

## Operator dependencies

The release-qualified platform installer installs, verifies, or reuses these dependencies. If an
existing dependency is reused, its CRDs and controller version must satisfy the target release
requirements.

| Dependency | When required |
| --- | --- |
| cert-manager | Required for the operator admission-webhook certificate. |
| KubeRay Operator | Required for Ray services and clusters. |
| Prometheus Operator | Required by the monitoring resources installed and reconciled in this release. |
| OpenTelemetry Operator | The platform installer can deploy this dependency, but HEC/OTel telemetry is not a supported feature in this release. Keep the workload sidecar disabled. |
| Splunk Operator | Required only for operator-managed, in-cluster Splunk resources. |

## Installer requirements

Install the tools required by the selected deployment method:

- `kubectl` for k0s and Kubernetes resource inspection
- `oc` for OpenShift installation and administration
- Helm 3 as required by the selected platform installer
- `git` when staging an air-gapped deployment from the release repository
- `jq`, `yq`, and the other command-line tools listed by the selected platform guide
- `crane` or an equivalent image-copy tool for private-registry mirroring

## Storage requirements

Provide object storage for model and platform artifacts. The documented storage options are:

- Amazon S3
- MinIO, SeaweedFS, or another supported S3-compatible service

Provide a persistent storage class for Weaviate, or create a persistent volume claim in advance.
The operator-created claim requests `ReadWriteOnce`. Use a storage class that supports that access
mode and, where required, volume expansion.

## GPU requirements

GPU workloads require:

- Compatible GPU nodes.
- The NVIDIA device plugin or the device-management component required by the target platform.
- Node labels, taints, tolerations, and affinity that allow workloads to schedule on GPU nodes.
- Capacity for the number and type of GPUs requested by the worker configuration.

## Network requirements

Ensure that:

- Cluster nodes can communicate with the Kubernetes API and each other as required by the
  selected Kubernetes distribution.
- Workloads can reach object storage, the private registry, and configured Splunk endpoints.
- The browser or client has a supported route to the Search Head and SAIA service endpoints.
- Air-gapped environments have a process for transferring images, charts, and model artifacts.

## Security and access requirements

- A registry credential for private images, when required.
- Kubernetes Secrets for static object-storage credentials and, only when the selected Splunk
  integration requires them, Splunk credentials. External JWT-only `trustedIssuers` configuration
  does not require a Splunk credential Secret.
- For external Splunk, an HTTPS certificate chain already trusted by the SAIA and SLIM workload
  images. This release does not expose a custom external-issuer CA-bundle field. The bundled
  internal-Splunk path has the separate TLS compatibility boundary documented in
  [Configure Splunk integration](splunk-integration.md#internal-splunk).
- Approved RBAC permissions for the operator and managed service accounts.

## Pre-installation checklist

- [ ] Release compatibility has been reviewed.
- [ ] Kubernetes and Helm versions are supported.
- [ ] Object storage is available; static credentials or workload identity are ready as required.
- [ ] Persistent storage is available for Weaviate.
- [ ] GPU capacity and scheduling rules are ready, if required.
- [ ] Required images are available in the target registry.
- [ ] Splunk endpoints and certificates are available; credentials are ready when required by the
      selected integration.
- [ ] Ingress, DNS, and client connectivity requirements are understood.
- [ ] Every enabled dependency CRD and controller is installed and ready.
