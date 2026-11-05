# FIPS Traefik validation plan for Splunk AI POD

**Status: Plan only.** No Splunk AI POD/OpenShift environment has been tested for
this document. The successful Traefik checks in the AI-Tier k0s environment are
not evidence that the same configuration works or is qualified on AI POD.

## Purpose and scope

This plan covers a separate Splunk AI POD deployment, using the OpenShift AI
POD deployment described by [`openshift-readme.md`](./openshift-readme.md). It
defines the checks needed to validate the same network boundary used in the
k0s test:

- TLS terminates at a customer-managed, FIPS-configured Traefik gateway outside
  the OpenShift cluster.
- Traefik forwards SAIA and Slim requests to the existing OpenShift HTTP Routes
  over plain HTTP.
- SAIA and Slim use a private HTTP listener on Traefik for Splunk token
  validation. Traefik opens a separate, certificate-verified HTTPS connection
  to external Splunk on port 8089.
- No TLS is introduced on the Traefik-to-OpenShift-router, router-to-service,
  or workload-to-private-Traefik legs.

The plan is for an external Splunk integration. The AI POD documentation says
external Splunk integration is limited to JWT validation on port 8089; external
HEC/OTel is not a supported or qualified path in that deployment workflow. Do
not add HEC validation to this plan unless product support is confirmed.

## AI POD facts to preserve

The repository describes AI POD as an installer deployed onto an existing
OpenShift cluster. Its generated SAIA and Slim Routes are HTTP Routes backed by
ClusterIP Services, target service port 8080, and do not set `spec.tls`. The
installation workflow does not configure or qualify HTTPS Routes or workload
mTLS. This plan keeps those routes HTTP and places the customer-managed Traefik
gateway in front of the OpenShift router.

Because Traefik is outside the cluster, it cannot route directly to a
ClusterIP. The proposed inbound handoff is therefore HTTP from Traefik to the
OpenShift router on TCP 80, with the original Route host and request path
preserved. The OpenShift router then forwards HTTP to the Route's service. This
handoff is a design assumption to validate in the target cluster before
changing DNS or production traffic.

## Proposed traffic flow

~~~mermaid
flowchart LR
  B[Browser] -->|HTTPS 443; TLS terminates here| T[External FIPS Traefik]
  E[External Splunk / AITK] -->|HTTPS 443; TLS terminates here| T
  T -->|HTTP 80; preserve Route host and path| R[OpenShift router]
  R -->|HTTP Route to service port 8080| A[SAIA Service]
  R -->|HTTP Route to service port 8080| L[Slim Service]
  A -->|HTTP to private Traefik listener :8080| T
  L -->|HTTP to private Traefik listener :8080| T
  T -->|Verified HTTPS :8089| S[External Splunk]
~~~

The callback is a workload-initiated request/response, not a webhook. The
private Traefik listener must not be internet-facing. The callback targets to
test first are:

| Method | Path | Unauthenticated probe expectation |
|---|---|---|
| GET | `/services/authorization/tokens-keys` | HTTP 200 from Splunk |
| GET | `/services/authentication/current-context` | HTTP 401 without a token; HTTP 200 in an authenticated application flow |

SAIA search operations require their own exact method/path routes. Add those
only after observing the requests from the deployed SAIA version. Do not make
Traefik a catch-all proxy for `/services/*`.

## Test prerequisites and access needed

Before testing, identify the target AI POD environment and collect:

1. A read-only `oc` context for the OpenShift cluster, its version, the AI POD
   namespace, and the deployed AIPlatform and Splunk integration mode.
2. The actual SAIA and Slim Route hosts, backing Services, and the OpenShift
   router's reachable HTTP address. Confirm that the external gateway can
   reach that router on TCP 80.
3. A customer-controlled Traefik gateway location, FQDNs, test certificate and
   CA, and approval to make a reversible DNS/firewall change during a test
   window.
4. The external Splunk management address, certificate SAN, issuing CA, and a
   test account that can perform the required token and search operations.
   Splunk Enterprise must also trust the Traefik certificate for AITK HTTPS
   calls; if using a private test CA, confirm the effective `SSL_CERT_FILE`
   used by the AITK HTTPX client points to a readable bundle with public roots
   and the test CA.
5. The OpenShift pod egress/NAT addresses seen by Traefik. Allow only those
   required sources to the private Traefik listener on TCP 8080.
6. The exact approved Traefik image digest, FIPS-mode configuration, and the
   customer's applicable crypto policy. A runtime flag or successful TLS
   handshake alone is not a FIPS certification claim.

Do not collect bearer tokens, cookies, private keys, or full environment dumps
as evidence. Use a dedicated test window and a rollback contact for DNS and
firewall changes.

## Execution plan

### 1. Capture the baseline without changing the cluster

Record the OpenShift version and current workload health. Capture only resource
metadata and non-secret configuration:

~~~sh
oc version
oc get clusteroperators
oc get routes -n "$AI_POD_NAMESPACE" -o wide
oc get services -n "$AI_POD_NAMESPACE" -o wide
oc get endpoints -n "$AI_POD_NAMESPACE"
oc get pods -n "$AI_POD_NAMESPACE" -o wide
oc get networkpolicy -n "$AI_POD_NAMESPACE"
~~~

Confirm that the SAIA and Slim Routes are HTTP, that each has ready service
endpoints on port 8080, and that the existing applications work before the
gateway change. Record route hosts and router address; do not infer these from
the k0s NodePort configuration.

### 2. Prepare Traefik and the network boundary

Use a dedicated external gateway and a pinned image. Configure a public HTTPS
entry point on TCP 443 and a separate private HTTP callback entry point on TCP
8080. Keep callback access restricted to the observed OpenShift egress sources.

For the public routes, target the OpenShift router over HTTP on TCP 80. Preserve
the Route host, path, query string, authorization/request headers, and streaming
response. Use the existing Route hostnames as the public FQDNs if the customer
DNS/certificate design permits; otherwise, configure a matching OpenShift Route
host only after confirming the AI POD deployment supports that change. If the
public FQDN differs from the generated Route host, first decide and test the
host-routing behavior. Do not silently rewrite a host or API prefix to make a
route appear to pass.

For callback routes, configure exact GET routes for the two token-validation
paths above. The service must target
`https://<SPLUNK_PRIVATE_FQDN_OR_IP>:8089` using a `serversTransport` with
certificate verification enabled, the correct trusted root CA, and a
`serverName` that matches the Splunk certificate SAN. Do not use
`insecureSkipVerify`, `curl -k`, or a TLS downgrade.

Network rules should allow:

- Intended browser and Splunk Enterprise clients to Traefik TCP 443.
- Traefik to the OpenShift router TCP 80.
- OpenShift workload egress to Traefik's private TCP 8080 listener.
- Traefik to external Splunk TCP 8089.

Block direct workload access to external Splunk TCP 8089 and do not expose the
private Traefik listener publicly. Confirm actual source NAT before tightening
the source allowlist; OpenShift node/pod addressing is environment-specific.

### 3. Validate the public SAIA and Slim ingress

From a client that trusts the test CA, verify DNS, certificate chain/SAN, and
TLS without disabling certificate validation. During pre-DNS testing, use
`curl --resolve` so the URL hostname and certificate verification remain
correct:

~~~sh
curl --cacert "$TRAEFIK_CA" \
  --resolve "$SAIA_FQDN:443:$TRAEFIK_PUBLIC_IP" \
  "https://$SAIA_FQDN/health"

curl --cacert "$TRAEFIK_CA" \
  --resolve "$SLIM_FQDN:443:$TRAEFIK_PUBLIC_IP" \
  "https://$SLIM_FQDN/health"
~~~

Expected result: the deployed health endpoints return their documented success
status, and Traefik logs show the correct router and HTTP OpenShift-router
upstream. Confirm the upstream request reaches the generated Route by preserving
its host. A Traefik 404, OpenShift router 404, or OpenShift Route 503 must be
diagnosed at the layer that produced it.

Then test the actual clients:

- **SAIA/browser:** Configure the Splunk AI Assistant URL as
  `https://<SAIA_FQDN>`. Open the assistant and exercise a simple request. If
  Splunk Web and SAIA have different origins, capture the exact browser preflight
  path, requested headers, response status, and CORS response headers. Do not
  include cookies or tokens in evidence.
- **Slim/AITK:** Configure the **Splunk AI tier** connection as
  `https://<SLIM_FQDN>/tenant/slim-api/v1alpha1`. Test the connection and load
  the model list from Splunk Enterprise. This must be tested from the Splunk
  host, not only from an administrator laptop.

### 4. Validate AITK inference through Slim

After the connection test succeeds, run a minimal inference from Splunk AI
Toolkit Search using a configured test connection:

~~~spl
| makeresults
| ai prompt="Reply exactly: AI POD Slim path passed" connection="<AITK_CONNECTION_NAME>"
~~~

Expected result: the prompt returns successfully, Splunk's `mlspl.log` shows a
successful request, Slim records the corresponding chat-completions request,
and public Traefik access logs show the request routed to the Slim OpenShift
Route. Record the request ID and timestamps, but redact tokens and cookies.
If the Traefik certificate uses a private CA, verify AITK's effective
`SSL_CERT_FILE` and CA bundle before running the inference. Keep certificate
verification enabled and preserve the normal public roots in the bundle.

### 5. Validate the SAIA/Slim callbacks to external Splunk

Set the AIPlatform trusted issuer to the private HTTP Traefik issuer URL, for
example `http://<TRAEFIK_PRIVATE_FQDN_OR_IP>:8080`, and ensure it matches the
issuer used by the Splunk-minted interactive token. Treat `SPLUNK_ISSUERS` as a
JWT issuer allowlist, not as a CA bundle or TLS setting. Do not print or save
the token while checking its issuer claim.

From both a SAIA pod and a Slim pod, probe the two exact paths through the
private Traefik listener. Expected unauthenticated results are JWKS HTTP 200
and current-context HTTP 401. The authenticated SAIA and AITK application
flows must produce successful current-context checks. Correlate each test's
timestamp with Traefik access logs showing the callback path, selected router,
upstream service, response status, and the OpenShift node/pod source as
available. Verify the configured upstream is the verified HTTPS Splunk
service, not a direct pod-to-Splunk connection.

For SAIA search-tool validation, exercise a simple, deterministic search and
confirm the exact observed parser, job, export/result, or control API paths are
routed through the private listener to Splunk. A successful JWKS check does
not prove that the SAIA search API route set is complete. Do not claim the
search-tool flow is validated unless the response contains actual search
results and the matching route/upstream records are available.

### 6. Run negative and resilience checks

- Confirm the private callback listener is unreachable from an unapproved
  client network.
- Confirm SAIA and Slim pods cannot connect directly to external Splunk TCP
  8089, while their requests through private Traefik succeed.
- Confirm an invalid CA/SAN is rejected in an isolated test; never disable
  verification to make the test pass.
- Confirm `OPTIONS` preflight, streaming inference responses, long-running
  requests, timeouts, and response buffering using the deployed app versions.
- Confirm a restart or route reload does not remove the configured routers or
  CA trust. Do not restart production workloads solely to complete a test.

### 7. Record evidence and close out

Capture an evidence table with actual values and statuses:

| Validation | Evidence to record | Status |
|---|---|---|
| OpenShift baseline | Version, namespace, Route hosts, Services, endpoints | Not run |
| Traefik FIPS setup | Image digest, runtime mode, policy evidence | Not run |
| Public TLS | FQDN, SAN/chain, negotiated TLS, HTTP status | Not run |
| Host/path routing | SAIA and Slim Route, path preserved, upstream/status | Not run |
| Browser CORS | Exact preflight request and response headers | Not run |
| AITK connection/model list | Splunk-host result and request path | Not run |
| AITK inference | Request ID, Splunk log, Slim log, success status | Not run |
| SAIA/Slim callbacks | JWKS/current-context logs and verified upstream | Not run |
| SAIA search tools | Successful search results and matching route logs | Not run |
| Isolation | Direct 8089 blocked; private 8080 restricted | Not run |
| Streaming/timeouts | Request duration and unbuffered response evidence | Not run |

Keep the test CA, client IP, certificate/key material, bearer token, and browser
cookies out of this document. The final validated guide should replace `Not run`
only with test evidence and should preserve any limitations, including source
NAT ambiguity or lack of pod-level identity in access logs.

## Rollback

Before testing, save the current DNS, firewall, gateway, AIPlatform, and app
endpoint values. If a check fails or is stopped:

1. Restore DNS to the previous OpenShift ingress address.
2. Remove the temporary gateway-to-router and workload-to-private-listener
   firewall allowances.
3. Restore the prior SAIA and AITK endpoint and trusted-issuer values.
4. Remove only the test Traefik routes/certificates created for this exercise.
5. Verify the original HTTP OpenShift Routes and application health are
   restored.

Do not run the AI POD installer cleanup command as a rollback; it can remove
installer-owned AI POD resources and is outside this test's scope.

## Inputs required to execute this plan

The plan can be converted into a tested customer procedure once the target
OpenShift AI POD cluster is identified and access is available, along with the
router address, external Splunk endpoint/certificate, DNS/firewall change
window, and an authorized test account for SAIA and AITK.
