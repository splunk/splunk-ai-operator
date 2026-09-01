# Reference

## Core custom resources

| Resource | Purpose |
| --- | --- |
| `AIPlatform` | Defines the platform, enabled features, storage, workers, ingress, and scheduling. |
| `AIService` | Operator-generated service resource. Configure supported customer inputs on the owning `AIPlatform`; direct `AIService` changes can be overwritten during reconciliation. |

Inspect the installed schemas with:

```bash
kubectl explain aiplatform.spec
kubectl explain aiservice.spec
```

## Common commands

```bash
kubectl get aiplatform -A
kubectl get aiservice -A
kubectl get pods -A
kubectl get events -A --sort-by='.lastTimestamp'
```

## Common configuration fields

| Field | Description |
| --- | --- |
| `spec.objectStorage` | Existing model and platform artifact bucket. `region` is required. Path prefixes are ignored in this release. Static credentials can be referenced through `secretRef`; supported workload identity can omit it. |
| `spec.storage.vectorDB` | Persistent storage for the vector database. |
| `spec.features` | AI services enabled for the platform. `features[].version` is metadata and does not select an image in this release. |
| `spec.scaleFactor` | Multiplies Ray Serve model replicas and every selected-profile Ray worker-group count, including the zero-GPU group. Minimum and default: `1`. |
| `spec.workerGroupConfig` | Ray worker ServiceAccount and image-registry overrides only. It does not expose replica or resource settings. |
| `spec.defaultAcceleratorType` | Selects the release-supported GPU worker profile: `L40S` or `H100` for k0s; `RTX_PRO_6000_BLACKWELL` for OpenShift. |
| `spec.ingress` | Ray Serve, Ray dashboard, and Weaviate ingress configuration. It does not expose SAIA or SLIM. |
| `spec.serviceTemplate` | Optional Service template used by generated front-door SAIA and SLIM Services. |
| `spec.splunkConfiguration` | Internal Splunk reference or external trusted JWT issuers. |

## Generated AI-tier environment

For SAIA, the operator generates:

| Variable | Purpose |
| --- | --- |
| `SPLUNK_ISSUERS` | Exact trusted Splunk management/JWKS issuer URL list. SAIA and SLIM both receive this value. |
| `SPLUNK_AI_ASSISTANT_SERVICE_CMP` | Enables AI-tier/CMP authorization behavior. |

The operator does not generate `SPLUNK_ISSUER_ENDPOINTS`.

## Important ports

| Port | Purpose |
| --- | --- |
| `8089/TCP` | Splunk management, authentication, and JWKS requests. |
| `8080/TCP` | Front-door SAIA nginx Service, internal SAIA v1 API, and front-door SLIM Service. |
| `8000/TCP` | Internal SAIA v2 API and Ray Serve. |
| `8265/TCP` | Ray dashboard. |

The generated SAIA front-door Service routes both internal API generations on port `8080` and is
`ClusterIP` by default. Customers configure one SAIA base URL; they do not select a separate v1 or
v2 Kubernetes endpoint. Port exposure depends on the Service, ingress, and proxy configuration. Do
not expose internal workload ports directly without the required authentication and network
controls.
