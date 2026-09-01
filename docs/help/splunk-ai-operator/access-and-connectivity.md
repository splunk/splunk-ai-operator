# Access and connectivity

The required routes depend on which system originates each request. Depending on the Splunk app
workflow, the browser, the Splunk host, or both can require access to the published SAIA URL. AITK
and other server-side integrations can also require the Splunk host to reach SLIM.

## Request paths

```text
Browser → Splunk Web
Browser or Splunk host → published SAIA URL → SAIA front-door Service → internal V1/V2 workloads
Splunk host → published SLIM URL → SLIM service
SAIA and SLIM pods → Splunk management/JWKS endpoint :8089
```

SAIA V1 and V2 are internal API generations behind the same front-door SAIA Service. They do not
require separate customer endpoints.

## Ingress access

Use an ingress controller and DNS when services need stable externally addressable host names.
Do not use `AIPlatform.spec.ingress`; external Ray and Weaviate exposure is not supported for
customer use in this release. To expose SAIA or SLIM, create a separate Ingress that targets the
generated front-door Service, as shown in
[Deploy the AI Platform](deploy-platform.md#expose-saia).

Verify the ingress address and TLS status:

```bash
kubectl get ingress -n <namespace>
kubectl describe ingress <ingress-name> -n <namespace>
```

## Port forwarding

Port forwarding is useful for short-lived diagnostics. For a platform named `my-ai-platform`, the
SAIA front-door Service is `my-ai-platform-saia-saia-service` on port `8080`. It is a `ClusterIP`
Service by default. Substitute its namespace in the following commands:

```bash
kubectl port-forward -n <namespace> \
  svc/my-ai-platform-saia-saia-service 18080:8080
```

That one SAIA port-forward carries both internal API generations. SLIM is a different Service and
requires its own port-forward when it is enabled:

```bash
kubectl port-forward -n <namespace> \
  svc/my-ai-platform-slim-slim-service 18081:8080
```

## SOCKS proxy for direct browser access

Use a SOCKS proxy when the browser must access multiple private endpoints or ports through a host
that can reach the cluster. An SSH dynamic tunnel is commonly created with:

```bash
ssh -N -D <local-socks-port> <jump-host>
```

Configure the browser or its operating-system proxy settings to use the local SOCKS endpoint.
Confirm that the jump host can resolve and reach the Search Head and published SAIA or SLIM
addresses.

The SOCKS proxy only provides network routing. It does not replace TLS validation, JWT
authentication, CORS configuration, or SAIA authorization.

## Connectivity checklist

- [ ] The client can resolve the configured host names.
- [ ] The proxy or ingress route reaches the intended service.
- [ ] The Splunk host can reach the published SAIA and SLIM URLs required by its installed apps.
- [ ] The browser can reach the published SAIA URL when the selected app workflow calls it directly.
- [ ] Ingress TLS certificates are trusted by the calling client when HTTPS is enabled.
- [ ] CORS and authorization headers are configured for direct browser calls.
- [ ] SAIA and SLIM pods can reach every configured Splunk issuer on port `8089`.
