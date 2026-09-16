# Enterprise Load Balancer Access to the SAIA and SLIM Endpoints

## Problem

The SSH-bastion SOCKS tunnel documented under [k0s-readme.md → Finding the
Splunk Web URL](k0s-readme.md#finding-the-splunk-web-url) is a workable path
for a single engineer doing initial setup or debugging, but it does not hold
up as the access method for an enterprise deployment:

- **Not multi-user.** Every person who needs to reach the SAIA endpoint (or
  onboard Splunk to it) needs their own SSH key, their own tunnel, and their
  own browser profile pointed at a local SOCKS port. There's no shared,
  discoverable URL.
- **No persistent identity.** The endpoint Splunk is onboarded to
  (`http://<worker-node-ip>:<nodePort>`) is a specific node's IP. If that node
  is drained, replaced, or the cluster is rebuilt, the URL changes and
  onboarding has to be redone.
- **Depends on an always-up bastion.** The tunnel requires an SSH-reachable
  installer/bastion host to stay online indefinitely. That host becomes an
  unmanaged single point of failure outside normal infra lifecycle
  (patching, HA, monitoring).
- **Not compatible with normal enterprise network controls.** Security teams
  generally want inbound access via a managed LB/firewall with logging,
  health checks, and cert management — not per-user SSH tunnels punched
  through a bastion.

This doc describes replacing the SOCKS tunnel with a standard **bring-your-own
external load balancer** (an existing enterprise LB — F5, cloud NLB/ALB, or
equivalent) sitting in front of the cluster's worker nodes, so the SAIA
endpoint is reachable at one stable, shared URL. The same pattern extends to
SLIM (see [Extending the pattern to SLIM](#extending-the-pattern-to-slim))
via a second, separate backend pool.

This assumes the enterprise **already operates a load balancer** (hardware
appliance or managed cloud LB). It does not cover deploying MetalLB — see
[k0s-readme.md — Service Template (SAIA & SLIM Public
Exposure)](k0s-readme.md#service-template-saia--slim-public-exposure) and
`metallb` in `k0s-cluster-config.yaml` if there is no existing LB and the
cluster is on true bare-metal L2.

## Architecture

```
Splunk Web users / SAIA onboarding
            │
            ▼
   Enterprise Load Balancer          (stable VIP / DNS name, owned by network team)
            │  backend pool = every k0s worker node, port = nodePort
            ▼
   k0s Worker Node (any)  ──kube-proxy──▶  SAIA Service (NodePort)  ──▶  SAIA Pod
```

The cluster-side configuration does not change from the existing NodePort
setup — the LB simply becomes the fixed front door that used to be played by
the SSH bastion + SOCKS tunnel.

## Prerequisites

- `aiPlatform.serviceTemplate.type: NodePort` in `k0s-cluster-config.yaml`
  (already the default — see
  `tools/ai-tier-cluster-setup/k0s-cluster-config.yaml:272`).
- Network reachability from the enterprise LB to every worker node on the
  configured `nodePort` (default `30080`; `30081` for `slim` if enabled).
  This must be explicit: open firewall/security-group rules from the LB's
  source IP(s) to each worker node on that port — the NodePort is not
  reachable from the LB by default just because both sit on the same
  network.
- An existing LB with the ability to define a backend pool / target group of
  arbitrary IP:port pairs and a TCP or HTTP health check.
- A DNS name or static VIP the LB will expose (e.g.
  `saia.internal.example.com`).

## Steps

### 1. Confirm the NodePort and worker IPs

The public SAIA Service is labeled `app: <AIService name>`, not
`app.kubernetes.io/component` — look it up by its documented name rather than
a label selector (see [Onboarding to the AI
Tier](k0s-readme.md#onboarding-to-the-ai-tier)):

```bash
NAMESPACE=ai-platform
CLUSTER_NAME="<cluster-name>"
AI_PLATFORM_NAME="${CLUSTER_NAME}-ai-platform"
SAIA_SERVICE="${AI_PLATFORM_NAME}-saia-saia-service"

kubectl get svc "${SAIA_SERVICE}" -n "${NAMESPACE}" -o wide
kubectl get svc "${SAIA_SERVICE}" -n "${NAMESPACE}" \
  -o custom-columns='TYPE:.spec.type,PORT:.spec.ports[0].port,NODEPORT:.spec.ports[0].nodePort'
```

For worker IPs, don't assume k0s labels nodes with
`node-role.kubernetes.io/worker` — the k0s installer never applies that
label (it's an OpenShift convention). Instead use the IPs from
`nodes.existingIPs.workers` in `k0s-cluster-config.yaml`, or confirm manually:

```bash
kubectl get nodes -o wide
```

Record the `nodePort` (e.g. `30080`) and the full list of worker node IPs —
these become the LB's backend targets.

### 2. Create the backend pool / target group on the enterprise LB

- **Targets:** every worker node IP from step 1, port = `nodePort`.
- **Protocol:** HTTP. For the supported profile, the LB (e.g. HAProxy)
  terminates HTTPS at the frontend and forwards plain HTTP to the backend —
  SAIA on `30080`, and SLIM on `30081` when the SLIM feature is enabled — per
  the [TLS approach](#tls-termination-at-the-lb-passthrough-is-not-supported-for-k0s)
  below. Do not configure the backend leg as TLS/passthrough — the NodePort
  has no TLS listener to pass through to.
- **Health check:** `GET /nginx_health` on the `nodePort` (e.g. `30080`),
  expecting `200`. This is the same path the SAIA nginx container's own
  Kubernetes readiness/liveness probes use — don't use the CORS `OPTIONS
  .../metadata` request from [step 5](#5-verify-without-the-socks-tunnel) as
  a health check; that's a browser CORS smoke test, not a liveness signal.
  Mark a node unhealthy and drain it from rotation if the check fails — this
  is what gives you node-failure tolerance that the SOCKS tunnel never had.
- **Node membership stays live:** if workers are added/removed (scaling,
  replacement), update the backend pool membership. If your LB or cloud
  provider supports targeting an autoscaling group / instance tag instead of
  static IPs, prefer that so membership updates automatically.

### 3. Create the frontend listener

- **Listener port:** whatever your organization standardizes on (e.g. `443`
  for HTTPS, or a plain `80`/custom port for internal-only HTTP).
- **VIP / DNS name:** assign a stable internal DNS name, e.g.
  `saia.internal.example.com`, pointing at the LB's frontend.

### TLS: termination at the LB (passthrough is not supported for k0s)

**TLS termination at the LB is the supported and validated approach.** The
LB holds the certificate, the listener is HTTPS, and backend traffic to the
NodePort stays plain HTTP — the SAIA nginx container only serves HTTP on the
NodePort. This is fine as long as the LB-to-worker-node hop stays inside a
trusted network.

**TLS passthrough to the default SAIA NodePort is not supported** on the
standard k0s deployment profile. The nginx backend has no TLS listener to
pass through to, and while the AIService CRD has an optional
operator-managed mTLS field (`aiPlatform.mtls`, adding an HTTPS port 8443),
`k0s-cluster-config.yaml` explicitly documents that this k0s installer does
not wire that field up: *"Workload mTLS remains off and unsupported. Do not
add aiPlatform.mtls; the k0s installer does not consume that sample key."*
Don't attempt passthrough here — use termination at the LB instead.

This matches what's already documented for cloud LBs in
`tools/ai-tier-cluster-setup/k0s-cluster-config.yaml:254-257`.

**Customer-validated deployment:** a Splunk AI Assistant deployment
connected through HAProxy HTTPS termination with a corporate wildcard
certificate — this is the exact termination-at-the-LB pattern described
above. The customer setup independently confirms HTTPS termination at
HAProxy and the use of a corporate wildcard certificate; the health-check,
timeout, buffering, and backend-pool details below are the general
requirements for this deployment pattern (per the rest of this doc), not
independently customer-verified.

HAProxy requirements for this deployment pattern:

- DNS name matches the wildcard certificate.
- The Search Head and user browsers trust the corporate CA.
- Backend targets include all worker nodes on the SAIA NodePort.
- Health check: `GET /nginx_health`, expecting `200` (per [step
  2](#2-create-the-backend-pool--target-group-on-the-enterprise-lb) above).
- Streaming enabled: HTTP/1.1, response buffering disabled, timeout at least
  300 seconds (see [Streaming responses](#notes--open-considerations)
  below).
- Confirm the Search Head itself (not just user browsers) can resolve and
  reach the HAProxy DNS name — browser reachability alone is not sufficient,
  since Splunk backend onboarding calls originate from the Search Head. Run
  from the Search Head itself:

  ```bash
  curl -fsS -o /dev/null -w '%{http_code}\n' https://saia.company.example/nginx_health
  ```

  Expect `200`. (Use `/nginx_health`, not `/health` — SAIA's nginx has no
  dedicated `/health` route; it falls through to the main API proxy and
  isn't guaranteed to return `200`. `/nginx_health` is nginx's own
  always-200 check, the same one the backend pool's health check uses.)

Note this validates termination at the LB specifically — it does not
validate TLS passthrough, which remains unsupported per above. HAProxy is
only genuinely load balancing (not just acting as a TLS reverse proxy) when
its backend pool contains multiple healthy worker nodes.

### 4. Point SAIA onboarding at the LB's stable URL

Use the LB's DNS name instead of a worker node IP wherever the SAIA endpoint
is configured — this replaces the `<worker-node-ip>:<nodePort>` value used in
[Onboarding to the AI Tier](k0s-readme.md#onboarding-to-the-ai-tier):

- **Splunk Web:** Splunk AI Assistant → Configuration → SAIA API URL =
  `https://saia.internal.example.com` (or `http://...` if not terminating
  TLS at the LB).
- **Scripted / air-gapped (`splunkaiassistant.conf`):**

  ```bash
  SAIA_URL="https://saia.internal.example.com"
  # ...same kubectl exec flow as in k0s-readme.md#onboarding-to-the-ai-tier,
  # substituting SAIA_URL above for the worker-node-ip:nodePort value.
  ```

Because this URL is now stable, onboarding does not need to be repeated when
individual worker nodes are replaced.

### 5. Verify without the SOCKS tunnel

```bash
curl -i -X OPTIONS \
  'https://saia.internal.example.com/<tenant-id>/saia-api-v2/v2alpha1/metadata' \
  -H 'Access-Control-Request-Headers: authorization,splunk-client,x-requested-with,x-stack-url' \
  -H 'Access-Control-Request-Method: GET' \
  -H 'Origin: https://<your-splunk-web-hostname>'
```

Expect `HTTP/1.1 204 No Content`, the same check used in the SOCKS tunnel
verification step, but hit directly against the LB — no bastion, no SSH key,
no per-user tunnel required.

The Search Head must independently resolve and reach the LB for onboarding
and health checks; user browsers must also independently resolve and reach
the SAIA hostname for interactive AI Assistant requests. Run the CORS
`OPTIONS` check above from a user/browser network; run the `/nginx_health`
check ([TLS section](#tls-termination-at-the-lb-passthrough-is-not-supported-for-k0s)
above) and the SLIM `/health` check ([Extending the pattern to
SLIM](#extending-the-pattern-to-slim) below) from the Search Head.

### 6. Retire the SOCKS tunnel from the standard workflow

Once the LB path is verified end-to-end (Splunk Web → SAIA onboarding →
smoke-test prompt in the app), the SSH-bastion SOCKS tunnel should be treated
as a fallback for ad hoc debugging only — not the access path for onboarding
or day-to-day use. Update any team runbooks that currently point at the SOCKS
tunnel instructions to reference the LB DNS name instead.

## Extending the pattern to SLIM

SLIM (consumed by the **Splunk AI Toolkit** app) is a **separate Kubernetes
Service and NodePort** from SAIA (consumed by the **Splunk AI Assistant**
app) — it needs its own backend pool and its own hostname on the LB, not a
path appended to the SAIA one. Both can share the same HTTPS listener and
wildcard certificate as the SAIA config above:

```
HTTPS :443 (wildcard cert)
  ├── Host saia.company.example → SAIA pool → worker-1:30080, worker-2:30080, ...
  └── Host slim.company.example → SLIM pool → worker-1:30081, worker-2:30081, ...
```

| | SAIA | SLIM |
|---|---|---|
| NodePort | `30080` (`nodePort` in `k0s-cluster-config.yaml`) | `30081` (`slimNodePort` in `k0s-cluster-config.yaml`) |
| Health check | `GET /nginx_health` → `200` | `GET /health` → `200` |
| Onboarded URL | `https://saia.company.example` | `https://slim.company.example/tenant/slim-api/v1alpha1` |
| Consumed by | Splunk AI Assistant app | Splunk AI Toolkit app |

- SLIM's onboarded URL must include the `/tenant/slim-api/v1alpha1` path —
  `tenant` is a required literal path segment SLIM reads only for
  log-anonymization/metric labeling, not a real tenant lookup (see
  `k0s-readme.md#onboarding-to-the-ai-tier-splunk-ai-toolkit`).
- Prefer separate hostnames over path-based routing on one hostname — SAIA
  and SLIM have distinct API paths and authentication flows, so keeping them
  on separate vhosts avoids any risk of the LB's path-matching rules
  misrouting one app's traffic into the other's pool.
- **Never add SLIM's metrics port (`8088`) to the LB backend pool.** The
  operator deliberately serves metrics from a separate ClusterIP-only
  Service (`reconcileSlimMetricsService` in
  `pkg/ai/features/slim/impl.go`) specifically so NodePort/LoadBalancer
  exposure never publishes `/metrics` — don't undo that by manually wiring
  `8088` into the enterprise LB.
- Do not point the SAIA and SLIM hostnames at each other's backend pool —
  each app expects the other's response schema and neither works against
  the wrong endpoint.
- As with SAIA, confirm from the Search Head itself (not just a browser)
  that SLIM is reachable through the LB, when the SLIM feature is enabled:

  ```bash
  curl -fsS -o /dev/null -w '%{http_code}\n' https://slim.company.example/health
  ```

  Expect `200`. Unlike SAIA's `/nginx_health`, SLIM's `/health` runs on the
  same port (`8080`) and route as its main API traffic, so this doubles as
  an end-to-end reachability check, not just a liveness ping.

## Notes / open considerations

- **Splunk Web access** itself (not just the SAIA endpoint) is outside this
  doc's scope. The bundled Splunk standalone Service is **ClusterIP by
  default** (see `k0s-readme.md#finding-the-splunk-web-url`), so it is not
  reachable by an external LB as-is — it would need to be separately exposed
  via its own NodePort, LoadBalancer, or Ingress before an enterprise LB
  could target it. That's a distinct frontend/backend pool from the SAIA one
  described here.
- **Streaming responses:** the SAIA nginx backend uses a `300s`
  `proxy_read_timeout`/`proxy_send_timeout` with `proxy_buffering off` (see
  `pkg/ai/features/saia/impl.go`). Set the enterprise LB's idle/response
  timeout to **at least 300 seconds**, HTTP/1.1, with response buffering
  disabled where the LB supports it — otherwise the LB may cut off a
  streaming AI response before nginx does.
- **Session affinity** should not be required — SAIA API calls are stateless
  per request, so any worker node in the pool can serve any request.
