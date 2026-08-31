# Prerequisites

Review the release-specific compatibility matrix before installing. The compatibility matrix is
the authoritative source for Kubernetes, Helm, container image, Splunk, and dependency versions.

## Cluster requirements

- A supported Kubernetes distribution and version.
- `kubectl` configured to use the target cluster.
- Cluster-admin access for installing CRDs, RBAC, webhooks, and operator resources.
- Sufficient CPU, memory, persistent storage, and GPU capacity for the selected workloads.
- A supported ingress controller when external HTTP or HTTPS access is required.
- DNS that resolves the configured service and ingress host names.

## Installer requirements

Install the tools required by the selected deployment method:

- `kubectl`
- Helm 3.8 or later for OCI chart installation
- `git` when installing from source or staging an air-gapped deployment
- `jq`, `yq`, or other tools required by the deployment scripts
- `crane` or an equivalent image-copy tool for private-registry mirroring

## Storage requirements

Provide object storage for model and platform artifacts. The documented storage options are:

- Amazon S3
- MinIO, SeaweedFS, or another supported S3-compatible service

Provide a persistent storage class for Weaviate, or create a persistent volume claim in advance.
Use a storage class that supports the required access mode and, where required, volume expansion.

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
- Kubernetes secrets for object storage and Splunk credentials.
- The required Splunk endpoint certificate chain when using HTTPS.
- Approved RBAC permissions for the operator and managed service accounts.

## Pre-installation checklist

- [ ] Release compatibility has been reviewed.
- [ ] Kubernetes and Helm versions are supported.
- [ ] Object storage is available and credentials are ready.
- [ ] Persistent storage is available for Weaviate.
- [ ] GPU capacity and scheduling rules are ready, if required.
- [ ] Required images are available in the target registry.
- [ ] Splunk endpoints, certificates, and credentials are available.
- [ ] Ingress, DNS, and client connectivity requirements are understood.
