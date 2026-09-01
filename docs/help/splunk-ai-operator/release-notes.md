# Splunk AI Operator v1.0 release information

This is the first release of the Splunk AI Operator for the documented self-hosted AI Tier
deployment.

## Supported component combination

| Component | Version |
| --- | --- |
| Splunk Enterprise | 10.2 |
| [Splunk AI Assistant app](https://splunkbase.splunk.com/app/7245) | 2.3.0 |
| AI Tier / Splunk AI Operator release | v1.0 |
| SAIA API v1 image | `docker.io/splunk/ai-tier-saia-api:v1.0` |
| SAIA API v2 image | `docker.io/splunk/ai-tier-saia-api-v2:v1.0` |
| SAIA data-loader image | `docker.io/splunk/ai-tier-saia-data-loader:v1.0` |
| SLIM service image | `docker.io/splunk/ai-tier-slim-service:v1.0` |
| Ray runtime | 2.56.0 |
| Ray head image | `docker.io/splunk/ai-tier-ray-head:v1.0` |
| Ray worker image | `docker.io/splunk/ai-tier-ray-worker:v1.0` |

SAIA v1 and v2 are internal API generations deployed together by the `saia` feature. Their names
do not represent separate customer-selectable releases or base endpoints.

## Release boundaries

- Install with the release-qualified k0s or OpenShift platform installer. Direct installation from
  the published `1.0.0` chart or standalone Kubernetes manifest is not supported for this release.
- The operator is cluster-scoped and uses cluster-wide RBAC.
- External Splunk integration supports JWT issuer validation. HEC/OpenTelemetry export is outside
  the scope of this release and must remain disabled.
- External Ray and Weaviate exposure through `AIPlatform.spec.ingress` is not supported. Leave it
  disabled and publish SAIA or SLIM separately when required.
- `features[].version` is metadata and does not select or upgrade workload images. Use only the
  selected platform installer's approved maintenance procedure.
- External Splunk certificates must already chain to a certificate authority trusted by the SAIA
  and SLIM workload images; no custom external-issuer CA-bundle field is available.
- Static Ray object-storage credentials are copied from the referenced Secret into generated Ray
  configuration objects. Restrict those objects as sensitive or use a release-supported workload
  identity.

Review [Prerequisites](prerequisites.md), [Installation](install.md), and
[Operations and lifecycle management](operations.md#maintenance-and-upgrades) before installation
or an approved platform maintenance operation.
