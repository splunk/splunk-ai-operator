# Access and connectivity

The access path depends on whether the client uses SAIA V1 through the Search Head or calls SAIA
V2 directly.

## Request paths

```text
SAIA V1:
Browser → network proxy or tunnel → Splunk Search Head
        → SAIA App backend → SAIA V1 service

SAIA V2:
Browser → network proxy or tunnel → SAIA V2 service
```

SAIA V1 and SAIA V2 are separate services. A request to the Search Head does not automatically
provide browser access to the SAIA V2 endpoint.

## Ingress access

Use an ingress controller and DNS when the services need stable externally addressable host names.
Verify the ingress address and TLS status:

```bash
kubectl get ingress -n <namespace>
kubectl describe ingress <ingress-name> -n <namespace>
```

## Port forwarding

Port forwarding is useful for a single endpoint or short-lived diagnostics:

```bash
kubectl port-forward -n <namespace> svc/<service-name> <local-port>:<service-port>
```

Separate port-forwards are required for separate service ports. A single port-forward does not
provide general browser access to multiple private endpoints.

## SOCKS proxy for direct browser access

Use a SOCKS proxy when the browser must access multiple private endpoints or ports through a host
that can reach the cluster. An SSH dynamic tunnel is commonly created with:

```bash
ssh -N -D <local-socks-port> <jump-host>
```

Configure the browser or its operating-system proxy settings to use the local SOCKS endpoint.
Confirm that the jump host can resolve and reach the Search Head and SAIA V2 service addresses.

The SOCKS proxy only provides network routing. It does not replace TLS validation, JWT
authentication, CORS configuration, or SAIA authorization.

## Connectivity checklist

- [ ] The client can resolve the configured host names.
- [ ] The proxy or ingress route reaches the intended service.
- [ ] The Search Head can reach SAIA V1 when using the V1 path.
- [ ] The browser can reach SAIA V2 directly when using Agent mode.
- [ ] Ingress TLS certificates are trusted by the calling client when HTTPS is enabled.
- [ ] CORS and authorization headers are configured for direct browser calls.
