# Configure AI services

AI services are enabled through the `features` section of the `AIPlatform` resource. The operator
creates the service workloads and the supporting configuration associated with each feature.

## Enable SAIA and SLIM

Enable the release-supported services by name:

```yaml
spec:
  features:
    - name: saia
    - name: slim
```

When `serviceAccountName` is omitted, the SAIA and SLIM reconcilers create an operator-managed
ServiceAccount for each service. An explicit name is an override and must refer to a pre-created
ServiceAccount in the workload namespace.

`features[].version` is metadata in this release. It does not select or upgrade a service image.
Service images are supplied to the operator Deployment by the release-qualified platform
installer and can change only through an approved platform maintenance procedure.

## SAIA V1 and V2

SAIA V1 and V2 are internal API generations with separate workloads and path families. Enabling
the `saia` feature deploys both behind one operator-managed SAIA nginx Service. Customers do not
select a generation or configure separate base endpoints.

| Internal generation | API path family | Routing |
| --- | --- | --- |
| SAIA V1 | `/saia-api/v1alpha1/...` | Routed by the front-door SAIA nginx Service. |
| SAIA V2 | `/saia-api-v2/v2alpha1/...` | Routed by the same front-door SAIA nginx Service. |

The Splunk AI Assistant app uses the appropriate API path. Configure one published SAIA base URL.

## Splunk AI Assistant app

For this release, the qualified Splunk AI Assistant app version is `2.3.0` on Splunk Enterprise
`10.2`. Download that exact version from [Splunkbase](https://splunkbase.splunk.com/app/7245) after
it appears in the page's version history; do not substitute the page's default version. Configure
it only after the published SAIA URL is reachable from every required browser and Splunk-host
network.

## Update service configuration

Update supported service configuration in the `AIPlatform` custom resource and apply it:

```bash
kubectl apply -f ai-platform.yaml
kubectl get pods -n <namespace> --watch
```

Review operator events and service logs during reconciliation. Do not change `features[].version`
to upgrade a service. To update SAIA, SLIM, Ray, Weaviate, or supporting images, follow the
release-specific platform maintenance procedure in
[Operations and lifecycle management](operations.md#maintenance-and-upgrades).
