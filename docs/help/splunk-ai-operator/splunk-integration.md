# Configure Splunk integration

Splunk integration allows SAIA and SLIM to validate tokens against trusted Splunk management/JWKS
issuers. Every configured issuer must be reachable from the relevant workload network.

## Internal Splunk

The current Kubernetes Secret resolver requires a namespace-scoped Secret named
`splunk-<AIPlatform-namespace>-secret`. Create it in the workload namespace. Do not put a real
token in a `--from-literal` command, because shell history and process inspection can expose it.

For a Splunk Operator `Standalone` named `splunk-standalone` in namespace `splunk`, copy the
base64-encoded `hec_token` field from its generated Secret to the required Secret in namespace
`ai-platform` without decoding or printing it:

```bash
kubectl get secret splunk-splunk-standalone-standalone-secret-v1 \
  --namespace splunk --output json | \
jq -e 'if (.data.hec_token // "") == "" then error("source Secret has no hec_token")
       else {apiVersion:"v1",kind:"Secret",type:.type,
             metadata:{name:"splunk-ai-platform-secret",namespace:"ai-platform"},
             data:{hec_token:.data.hec_token}} end' | \
kubectl apply -f -
```

Change the source Secret name when the `Standalone` has a different name. Alternatively, use an
approved secret manager to create `ai-platform/splunk-ai-platform-secret` with the real
`hec_token`. The key is required by the current resolver even when OpenTelemetry is disabled. Do
not point `secretRef` at a Secret in the Splunk namespace; cross-namespace Secret references are
not consumed by the generated workloads.

Reference an in-cluster Splunk deployment with `splunkCustomResourceRef` and the workload-local
Secret:

```yaml
spec:
  sidecars:
    otel: false
  splunkConfiguration:
    splunkCustomResourceRef:
      apiVersion: enterprise.splunk.com/v4
      kind: Standalone
      name: splunk-standalone
      namespace: splunk
    secretRef:
      name: splunk-ai-platform-secret
```

The operator derives the in-cluster management service endpoint and supplies it to the managed
SAIA and SLIM issuer allowlists. For this example with the default cluster domain, the derived
issuer is:

```text
https://splunk-splunk-standalone-standalone-service.splunk.svc.cluster.local:8089
```

Configure Splunk's `oauth2_settings.issuer_uri` to that exact value. The JWT `iss`, generated
`SPLUNK_ISSUERS` entry, and reachable Service URL must agree character-for-character. The HTTPS
certificate must cover the Service URL's hostname and chain to a certificate authority trusted by
the workloads.

This manual reference requires a customer-provisioned Splunk management certificate and workload
trust that satisfy those conditions. The standard Splunk Operator built-in certificate does not
cover this derived Service name, and this release does not expose a custom issuer CA-bundle mount.
Use the release-qualified installer for the bundled internal-Splunk compatibility path; that path
does not claim verified end-to-end workload TLS. Do not disable verification globally to work
around a certificate failure.

## External Splunk

This release supports external Splunk JWT validation through an explicit issuer allowlist. It does
not support external HEC/OTel telemetry, so keep OpenTelemetry disabled:

```yaml
spec:
  sidecars:
    otel: false
  splunkConfiguration:
    trustedIssuers:
      - https://splunk.example.com:8089
```

Use the exact value of Splunk's `oauth2_settings.issuer_uri`, including scheme, host, and port. It
must match the JWT `iss` claim. Each additional entry expands the set of hosts that SAIA and SLIM
trust and contact for validation, so add only controlled Splunk management endpoints.

The operator writes the configured values to the generated SAIA and SLIM `SPLUNK_ISSUERS`
allowlists. It does not generate `SPLUNK_ISSUER_ENDPOINTS` or map a different token identity to a
management URL. Do not patch generated ConfigMaps; update `AIPlatform.spec.splunkConfiguration`
and let the operator reconcile them.

## Management port and connectivity

Port `8089` is the Splunk management/JWKS port. Test the exact issuer from the SAIA or SLIM
workload network, not only from the installer laptop. For example:

```bash
kubectl exec -n <namespace> \
  deployment/<aiservice-name>-saia-v2-deployment \
  -c saia-v2-api -- \
  python3 -c 'import json, urllib.request; response = urllib.request.urlopen(
    "https://<routable-splunk-host>:8089/services/authorization/tokens-keys?output_mode=json",
    timeout=10); print(response.status, type(json.load(response)).__name__)'
```

Run the Python argument on one line if your shell does not preserve the formatting. HTTP `200`
with a parsed JSON response demonstrates pod routing, strict certificate verification, and a JSON
response from the endpoint. Inspect the returned token-key data separately when authentication
still fails. A successful laptop test does not prove pod connectivity.

For external deployments, validate all applicable directions:

| Source | Destination | Purpose |
| --- | --- | --- |
| Browser | Splunk Web and the published SAIA URL | Load the app and make browser-originated SAIA requests. |
| External Splunk host | Published SAIA URL | Run server-side onboarding and health checks required by the installed Splunk AI Assistant app. |
| External Splunk host | Published SLIM URL | Run AITK discovery and inference calls when required by the installed app. |
| SAIA and SLIM pods | Exact Splunk issuer on `8089` | Retrieve signing keys and validate tokens. |

A laptop VPN, port-forward, or SOCKS tunnel supplies connectivity only for that laptop. It does not
create persistent routing between the cluster and Splunk host.

## TLS and certificates

When a Splunk issuer uses HTTPS, its certificate subject alternative name must cover the configured
host name or IP address, and its certificate chain must already be trusted by the SAIA and SLIM
workload images. This release does not expose a custom external-issuer CA-bundle field.

Disabling certificate verification can help diagnose connectivity, but it is not a production
TLS solution. Ingress TLS uses a separate namespace-local Kubernetes TLS Secret and does not add
trust for workload-to-Splunk connections.

## Validate an issued token

Obtain a new token after changing Splunk's issuer configuration. Decode it without sharing the
token and verify that its `iss` claim exactly matches an entry in the generated allowlists:

```bash
kubectl get configmap <aiservice-name>-saia-config -n <namespace> \
  -o jsonpath='{.data.SPLUNK_ISSUERS}{"\n"}'
kubectl get configmap <aiservice-name>-slim-config -n <namespace> \
  -o jsonpath='{.data.SPLUNK_ISSUERS}{"\n"}'
```

Use the token format supported by the installed Splunk and app release. Do not include tokens in
logs, screenshots, or support bundles.
