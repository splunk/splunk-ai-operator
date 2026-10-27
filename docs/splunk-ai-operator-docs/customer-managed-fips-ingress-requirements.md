# On-Prem Customer-Managed Ingress Investigation

This investigation records the repository-backed ingress paths for on-prem
customer-managed deployments of AI-Tier and Splunk AI POD. It identifies what
the operator and deployment docs establish and separates those facts from
deployment-specific details that require runtime inspection. The customer
operates the ingress gateway and supplies valid certificates. The approved
transport model is TLS from callers to the gateway, with HTTP from the gateway
to the SAIA and SLIM services. There is no TLS between workloads inside the
cluster.

This investigation is controller-agnostic. It does not deploy, test, or qualify
an ingress controller and does not make a FIPS qualification claim. Its findings
stand on their own and do not depend on another Jira issue.

## Supported customer access paths

Expose only the application endpoints required by the customer's users and
Splunk Enterprise instance. The customer chooses DNS names and the gateway
address; examples below are placeholders.

| Client | Endpoint on the customer gateway | Backend | Required path behavior |
|---|---|---|---|
| User browser using Splunk AI Assistant | `https://<saia-fqdn>/` | SAIA Service, HTTP port `8080` | Route the SAIA API paths without path rewriting. The browser must resolve and reach the gateway hostname. |
| On-prem Splunk Enterprise process running Splunk AI Toolkit (AITK), when Splunk is outside the cluster | `https://<slim-fqdn>/tenant/slim-api/v1alpha1` | SLIM Service, HTTP port `8080` | Preserve `/tenant/slim-api/v1alpha1` and the remaining request path, query, and headers. The Splunk Enterprise host must resolve and reach the gateway hostname; browser reachability alone is insufficient. |

### API routes, health checks, and streaming

**SAIA** is exposed through its Nginx-backed Service. The gateway sends HTTP to
the SAIA Service on port `8080`; Nginx then selects the API backend by path:

| Request path on `https://<saia-fqdn>` | Nginx destination | Notes |
|---|---|---|
| `/<tenant>/saia-api/v1alpha1/...` | SAIA v1 Service, HTTP `8080` | Default route. Repository examples include `/api/metadata` and `/saia/search`. |
| `/<tenant>/saia-api-v2/v2alpha1/...` | SAIA v2 Service, HTTP `8000` | Any path containing the `/saia-api-v2/` segment selects v2, with or without a tenant prefix. Repository example: `/v2alpha1/metadata`. |
| `/health` | SAIA v1 Service, HTTP `8080` | Application health path; it is proxied by Nginx. |
| `/nginx_health` | Nginx itself | Returns `200 ok`; intended for Nginx health checks. |
| `/nginx_status` | Nginx itself | Loopback-only. Do not expose through the customer gateway. |

Preserve the complete incoming SAIA path and query string. Do not prepend,
strip, or rewrite the tenant or API-version segments. Nginx answers browser
`OPTIONS` preflight requests with `204`; normal API requests are proxied to the
selected SAIA backend. The examples above identify route families and sample
operations, not an exhaustive API catalog: the exact operation paths depend on
the deployed SAIA v1/v2 images and are not defined in this operator repository.

SAIA Nginx uses HTTP/1.1 and disables response buffering for both API backends;
its configured proxy read/send timeouts are 300 seconds. The v2 route enables
chunked transfer. The generated AI POD OpenShift Routes use a 600-second router
timeout and disable response buffering. A customer gateway must pass streaming
responses through without buffering or truncation and must not impose a shorter
timeout than the supported request requires. The repository does not identify
a distinct `/stream` API path or enumerate the streaming operation; determine it
from the API specification or runtime trace for the deployed image. This source
investigation records proxy settings, not successful streaming behavior through
a live gateway.

**AITK** calls SLIM directly; it does not traverse SAIA's Nginx. Configure the
saved AITK base endpoint as
`https://<slim-fqdn>/tenant/slim-api/v1alpha1`; append the operation path, for
example `/chat/models`. Every operation below that prefix requires a
`request_id` header and a Splunk-minted bearer token. Preserve the API prefix,
remaining path, query string, and request headers.

SLIM also serves `/health` and
`/service/info/specs/v1alpha1/openapi.json` at the service root, outside the
tenant API prefix. The OpenAPI document is the source for the deployed SLIM
operation list. The separate SLIM metrics Service on port `8088` is internal;
it is not an AITK endpoint and must not be published by the customer gateway.

When Splunk Enterprise and AITK run inside the same cluster, use the
deployment-supported SLIM `ClusterIP` endpoint over HTTP on port `8080`. That
east-west path does not traverse the ingress gateway and does not use TLS. It
is not evidence for the inbound gateway TLS leg. When testing gateway TLS for
SLIM, make the request from an on-prem caller outside the cluster.

Keep the Ray dashboard, Weaviate, metrics, and other internal endpoints off the
customer ingress unless a separate approved requirement calls for them.

SAIA and SLIM service names, actual Service types, and assigned ports vary by
deployment. Read the deployed values before configuring the gateway; do not
assume a fixed NodePort.

### Deployment-specific backend references

| Deployment | SAIA backend | SLIM backend | What to inspect |
|---|---|---|---|
| AI-Tier on k0s | `<AIPlatform-name>-saia-saia-service:8080` | `<AIPlatform-name>-slim-slim-service:8080` | The `AIPlatform` Service type and the current Service port/NodePort. The installer supports `ClusterIP`, `NodePort`, and `LoadBalancer` exposure depending on configuration. In-cluster Splunk can use `ClusterIP`; an external gateway needs a reachable Service path. |
| Splunk AI POD on OpenShift | Route `saia` targets `<AIPlatform-name>-saia-saia-service:8080` | Route `slim` targets `<AIPlatform-name>-slim-slim-service:8080` | `oc get route saia slim -n <namespace>` and the backing Service targets. The installer-generated Routes use HTTP and do not terminate TLS. In-cluster Splunk can use the SLIM `ClusterIP`; an external caller may use the HTTP Route as the gateway's backend path. |

The default OpenShift Route hostnames are `saia.<ingress-domain>` and
`slim.<ingress-domain>`. These are the deployment's current Route names, not a
requirement for the customer's gateway FQDN. The k0s endpoints depend on the
configured Service exposure. See the [k0s endpoint guidance](../ai-tier-docs/k0s-readme.md)
and [OpenShift Route guidance](../ai-pod-docs/openshift-readme.md) for the
current deployment details.

The operator's generic `AIPlatform.spec.ingress` is not the SAIA/SLIM gateway
configuration. In the current operator implementation it routes AIPlatform
Ingress paths to Ray Serve, the Ray dashboard, or Weaviate. Configure the
customer-managed gateway against the actual SAIA/SLIM Services or the
deployment-specific Route/Service handoff instead.

## DNS, routing, and firewall prerequisites

1. Assign customer-controlled FQDNs for the gateway endpoints. DNS answers must
   resolve to the customer ingress gateway's reachable VIP or load-balancer
   address from each intended caller network.
2. Allow the intended browsers and Splunk Enterprise hosts to reach the
   gateway on TCP `443`. Restrict access to the customer-approved source
   networks; public internet exposure is not assumed.
3. Allow the gateway to reach the SAIA and SLIM backend Services on TCP `8080`
   over the customer's cluster network or explicitly configured Service
   exposure. Keep direct caller access to backend Services disabled where the
   deployment supports that restriction.
4. If Splunk Enterprise is outside the cluster, verify DNS and routing from
   that host to the SLIM gateway FQDN. A successful check from an administrator
   laptop does not prove that AITK can reach SLIM. If Splunk Enterprise is
   inside the cluster, verify its direct HTTP `ClusterIP` path separately; do
   not treat it as gateway TLS evidence.
5. Preserve the incoming host, authorization/request headers, query string,
   and streaming response body. Do not rewrite the SLIM API prefix.
6. Keep inbound gateway traffic separate from AI-Tier outbound Splunk
   management/JWKS connections. This investigation covers the inbound caller
   path; it does not establish the route or TLS behavior for outbound
   connections.

If a customer proxy or load balancer sits before the gateway, record its
source/destination, DNS view, allowed `CONNECT` or TCP destination, and whether
it terminates or re-encrypts TLS. The approved ingress TLS leg terminates at the
gateway. Any additional TLS-termination hop is a separate TLS leg and must be
recorded for the customer's security assessment; do not assume that a proxy is
transparent.

## TLS, certificates, and boundary

- Terminate TLS on the customer-managed ingress gateway. This is the only TLS
  leg covered by the approved FIPS ingress boundary.
- Forward from the gateway to SAIA and SLIM over HTTP on backend port `8080`.
  Do not configure TLS or mTLS between in-cluster workloads for this design.
- The customer supplies and maintains the gateway certificate and private key.
  Each certificate must be valid for its configured gateway FQDN, include the
  matching DNS name in its SAN, chain to a CA trusted by intended callers, and
  have a customer-owned renewal and rotation process.
- Configure the selected gateway's TLS protocol, cipher, and cryptographic
  module according to the customer's approved FIPS policy. Record the effective
  runtime configuration and handshake evidence; HTTPS by itself is not proof
  of FIPS operation.
- Store certificate private keys in the customer's approved secret/PKI system.
  Do not place private keys in the repository, Jira, or support evidence.
- The customer installs, configures, updates, and operates the ingress
  controller. AI-Tier installation scripts do not install or manage it.

## Streaming and long-running requests

The gateway must support streaming responses without buffering or truncating
them and must use timeouts appropriate for long-running inference. The current
AI POD OpenShift Routes use a 600-second timeout and disable response buffering;
preserve equivalent behavior when the customer gateway is in the request path.
This source review records current proxy settings and platform route defaults.
It does not establish which customer gateway settings pass SAIA or SLIM streams
successfully in a live deployment.

## Findings and evidence limits

- No ingress controller's FIPS qualification is established by this
  investigation. A controller's image, configuration, crypto provider, and
  live TLS behavior require deployment-specific evidence before anyone claims
  that controller is qualified.
- The customer selects, deploys, and operates the gateway and assesses it
  against the customer's security policy. This investigation makes no
  validation claim for customer-selected controllers.
- Record the deployment platform/version, controller image and immutable
  digest, gateway FQDNs, DNS answers, caller-to-gateway and gateway-to-Service
  routes, firewall/proxy rules, certificate chain/SAN/expiry, effective TLS
  policy, and SAIA/SLIM API and streaming results when those deployment facts
  are collected.
- Keep inbound gateway TLS separate from outbound Splunk issuer TLS and
  plaintext in-cluster traffic. The repository review does not prove a live
  network path, certificate handshake, API response, or streaming result.

This document is the investigation deliverable. It can be used independently
as input to customer instructions or later implementation and test work.
