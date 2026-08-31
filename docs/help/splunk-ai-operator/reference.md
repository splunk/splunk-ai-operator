# Reference

## Core custom resources

| Resource | Purpose |
| --- | --- |
| `AIPlatform` | Defines the platform, enabled features, storage, workers, ingress, and scheduling. |
| `AIService` | Defines service-specific configuration and service lifecycle inputs. |

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
| `spec.objectStorage` | Model and platform artifact storage. |
| `spec.storage.vectorDB` | Persistent storage for the vector database. |
| `spec.features` | AI services enabled for the platform. |
| `spec.workerGroupConfig` | Ray worker service account and image registry settings. |
| `spec.ingress` | External host, path, and TLS configuration. |
| `spec.splunkConfiguration` | Internal or external Splunk endpoint and credentials. |

## Generated AI-tier environment

For internal Splunk references, the operator generates:

| Variable | Purpose |
| --- | --- |
| `SPLUNK_ISSUERS` | Trusted Splunk management endpoint list. |
| `SPLUNK_ISSUER_ENDPOINTS` | Maps a modern token issuer identity to a trusted management endpoint. |
| `SPLUNK_AI_ASSISTANT_SERVICE_CMP` | Enables AI-tier/CMP authorization behavior. |

## Important ports

| Port | Purpose |
| --- | --- |
| `8089/TCP` | Splunk management, authentication, and JWKS requests. |
| `8000/TCP` | Service port used by selected AI workloads; confirm the generated Service before use. |
| `8080/TCP` | SAIA V1 service port in the standard SAIA deployment; confirm the generated Service before use. |

Port exposure depends on the selected chart, ingress, and service configuration. Do not expose
internal service ports directly without applying the required authentication and network controls.
