# Configure Splunk integration

Splunk integration connects AI services to the Splunk management and authentication endpoints.
The endpoint must be reachable from the relevant SAIA, SLIM, and supporting workloads.

## Internal Splunk

Reference an in-cluster Splunk deployment with `splunkCustomResourceRef`:

```yaml
spec:
  splunkConfiguration:
    splunkCustomResourceRef:
      apiVersion: enterprise.splunk.com/v4
      kind: Standalone
      name: splunk-standalone
      namespace: splunk
    secretRef:
      name: splunk-credentials
      namespace: splunk
```

The operator derives the in-cluster management service endpoint and supplies it to the managed
SAIA configuration.

## External Splunk

For an external Splunk deployment, configure the management endpoint and credentials:

```yaml
spec:
  splunkConfiguration:
    endpoint: https://splunk.example.com:8089
    secretRef:
      name: splunk-credentials
      namespace: ai-platform
```

Add trusted issuer URLs when the deployment uses more than the primary configured endpoint:

```yaml
spec:
  splunkConfiguration:
    endpoint: https://splunk.example.com:8089
    trustedIssuers:
      - https://splunk.example.com:8089
```

## Management port and connectivity

Port `8089` is the Splunk management port used for authentication and API calls. Test from a
cluster node or an appropriate workload network namespace, not only from the installer laptop:

```bash
nc -zv <routable-splunk-host> 8089
curl -skS -o /dev/null -w '%{http_code}\n' \
  'https://<routable-splunk-host>:8089/services/authorization/tokens-keys?output_mode=json'
```

The JWKS request should return HTTP `200`. A successful laptop test does not prove that SAIA pods
can reach the endpoint.

## AI-tier issuer-to-endpoint mapping

Some modern Splunk token formats use a pod or instance identity in the JWT `iss` claim while the
JWKS and current-context endpoints are exposed through the Splunk management service URL. For
internal Splunk, the operator generates the following configuration for SAIA:

```text
SPLUNK_ISSUERS=https://splunk-splunk-standalone-standalone-service:8089
SPLUNK_ISSUER_ENDPOINTS={"splunk-splunk-standalone-standalone-0":"https://splunk-splunk-standalone-standalone-service:8089"}
```

`SPLUNK_ISSUERS` remains the trusted endpoint allowlist. `SPLUNK_ISSUER_ENDPOINTS` maps the token
identity to an allowlisted endpoint and is used only by AI-tier/CMP authorization.

## TLS and certificates

When the configured Splunk endpoint uses HTTPS, confirm that its certificate hostname matches the
endpoint used by SAIA and that the certificate chain is trusted by the calling workload.

Disabling certificate verification can help diagnose connectivity, but it is not a production
TLS solution. Use the certificate trust configuration supported by the selected AI-tier release
for production.

## Token formats

AI-tier SAIA authorization supports:

- legacy `type=Splunk.interactive` tokens, and
- modern `typ=at+jwt` tokens with `token_type=splunk.cmp`.

The token must still pass signature verification, issuer resolution, JWKS retrieval, and Splunk
current-context validation.
