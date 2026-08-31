# Configure AI services

AI services are enabled through the `features` section of the `AIPlatform` resource. The operator
creates the service workloads and the supporting configuration associated with each feature.

## Enable SAIA and SLIM

Use the feature names and versions supported by the target release:

```yaml
spec:
  features:
    - name: saia
      version: "<saia-version>"
      serviceAccountName: saia-service-account
    - name: slim
      version: "<slim-version>"
      serviceAccountName: slim-service-account
```

Do not assume that every feature version is compatible with every operator release. Check the
release compatibility matrix.

## SAIA V1 and V2

SAIA V1 and SAIA V2 are separate services with separate API paths and deployment workloads.

| Service | Typical API path | Client pattern |
| --- | --- | --- |
| SAIA V1 | `/saia-api/v1alpha1/...` | Often called through the SAIA App backend on the Search Head. |
| SAIA V2 | `/saia-api-v2/v2alpha1/...` | Can be called directly by a browser or API client when network access is configured. |

The exact host name and ingress path depend on the deployment configuration.

## MLTK app setup

When the AI-Tier workflow requires the Splunk Machine Learning Toolkit (MLTK) app:

1. Install the release-approved MLTK app version on the required Splunk Search Head.
2. Confirm that the app is enabled and that the target users have the required capabilities.
3. Confirm that the Search Head can reach the configured AI Platform and SAIA endpoints.
4. Validate the MLTK workflow using the release-specific MLTK setup procedure.

The final Help publication should link this section to the approved MLTK installation and
configuration pages.

## Update a service

Update the relevant feature version or service configuration in the custom resource and apply it:

```bash
kubectl apply -f ai-platform.yaml
kubectl get pods -n ai-platform --watch
```

Review the operator events and service logs during the rollout. Back up or preserve persistent
data before changing storage or service versions.
