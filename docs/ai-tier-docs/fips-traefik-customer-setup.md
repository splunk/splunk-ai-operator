# On-prem customer setup: FIPS-mode Traefik ingress for AI-Tier

**Status:** This guide records the setup and paths exercised in the in-house test through 2026-11-05: browser ingress to SAIA and Slim, AITK connection/model-list and inference through Slim, and token-validation callbacks from SAIA and Slim to external Splunk through Traefik. Search API routes were verified individually at the routing layer. The test did not establish FIPS certification for the exact Traefik image or cryptographic module.

## In this guide

- [Deployment model and traffic boundary](#deployment-model-and-traffic-boundary)
- [SAIA browser ingress and Splunk callback sequence](#saia-browser-ingress-and-splunk-callback-sequence)
- [Validated setup procedure](#validated-setup-procedure)
- [Prepare external Splunk](#1-prepare-external-splunk)
- [Restrict network paths](#2-restrict-network-paths)
- [Configure Traefik](#3-configure-traefik)
- [Configure the trusted issuer](#4-configure-ai-tiers-trusted-issuer)
- [Verify the path](#5-verify-the-path)
- [Validated test evidence](#validation-evidence)

## Deployment model and traffic boundary

This reference uses a **standalone Traefik gateway outside the k0s cluster**, configured with static and file providers. It is the network entry point for AI-Tier APIs and reaches SAIA and Slim through private NodePorts.

For the Splunk token-validation callbacks, SAIA and Slim connect to the gateway's private listener. The file-provider service points directly to `https://<SPLUNK_PRIVATE_IP>:8089`, and Traefik's `serversTransport` verifies the configured CA and server identity. This gateway is outside k0s and uses Traefik's file provider. The 2026-11-05 AITK inference test correlated with successful JWKS and current-context responses through this route from the node hosting Slim. The access log records the node address, and that node also hosted SAIA, so this is time-correlated evidence rather than a pod-identity log entry.

For the tested ingress, client-facing TLS ends at the Traefik listener. Traefik forwards requests to SAIA and Slim over HTTP; no TLS is used on these Traefik-to-service backend hops.

SAIA and Slim retrieved Splunk signing keys and validated interactive tokens through the private HTTP listener on the Traefik gateway at port 8080 (`jwks`). The tested Splunk management and search API routes, including search-job result retrieval, use this listener. Traefik then connects to the external Splunk management endpoint over verified HTTPS. That separate gateway-to-Splunk TLS session terminates at Splunk. The public HTTPS listener on port 443 (`websecure`) is for client traffic to SAIA/Slim; unmatched paths there fall through to the SAIA catch-all and are not the Splunk management route.

This tested profile covers the same browser-facing ingress pattern to SAIA and Slim, plus SAIA and Slim token-validation callbacks and the Splunk management/search routes listed below.

~~~mermaid
flowchart LR
  C[Customer browser or Splunk app]
  T[Traefik FIPS-mode gateway]
  A[SAIA]
  L[Slim]
  S[External Splunk Enterprise]

  C -->|HTTPS 443; TLS ends at Traefik| T
  T -->|HTTP NodePort <SAIA_NODEPORT>| A
  T -->|HTTP NodePort <SLIM_NODEPORT>| L
  A -->|SAIA callback: HTTP private 8080| T
  L -->|Slim/AITK callback: HTTP private 8080| T
  T -->|Verified HTTPS 8089 for both callbacks| S
~~~

### SAIA browser ingress and Splunk callback sequence

The browser-facing ingress pattern shown here is the same for SAIA and Slim: HTTPS terminates at public Traefik, which forwards HTTP to the corresponding private NodePort. The sequence below details the SAIA token-validation flow. The AITK/Slim inference test also exercised the same private callback listener and verified HTTPS upstream to Splunk. These are separate connections: each workload uses a private, plain-HTTP listener on Traefik, and Traefik creates a new, certificate-verified HTTPS session to Splunk.

~~~mermaid
sequenceDiagram
  participant B as Browser / Splunk app
  participant T as Traefik public listener :443
  participant A as SAIA service
  participant P as Traefik private listener :8080
  participant S as External Splunk :8089
  B->>T: HTTPS request to SAIA API path
  Note over B,T: TLS terminates at Traefik
  T->>A: HTTP to SAIA NodePort :<SAIA_NODEPORT>
  A->>P: HTTP GET /services/authorization/tokens-keys
  P->>S: Verified HTTPS GET /services/authorization/tokens-keys
  Note over P,S: Validate Splunk CA chain and certificate SAN / server name
  S-->>P: JWKS response
  P-->>A: HTTP response
  A->>P: HTTP GET /services/authentication/current-context
  P->>S: Verified HTTPS GET /services/authentication/current-context
  S-->>P: Current token context
  P-->>A: HTTP response
  A-->>T: HTTP SAIA API response
  T-->>B: HTTPS response
~~~

| Leg | Initiator and destination | Protocol | TLS behavior |
|---|---|---|---|
| Browser ingress | Browser → Traefik `:443` → SAIA NodePort `:<SAIA_NODEPORT>` | HTTPS to Traefik; HTTP to SAIA | Browser-to-Traefik TLS terminates at Traefik. Traefik-to-SAIA is HTTP inside the private network. |
| Browser ingress | Browser/Splunk app → Traefik `:443` → Slim NodePort `:<SLIM_NODEPORT>` | HTTPS to Traefik; HTTP to Slim | Same TLS boundary. AITK connection/model-list and inference were verified through this route. |
| Token/JWKS callback | SAIA and Slim (AITK) → private Traefik `:8080` → Splunk `:8089`, `GET /services/authorization/tokens-keys` | HTTP to Traefik; HTTPS to Splunk | Both paths returned HTTP 200 in the SAIA check and in the time-correlated AITK/Slim run; Traefik uses the configured test CA and Splunk certificate SAN. |
| Current-context callback | SAIA and Slim (AITK) → private Traefik `:8080` → Splunk `:8089`, `GET /services/authentication/current-context` | HTTP to Traefik; HTTPS to Splunk | Both paths returned HTTP 200 during authenticated token validation. An unauthenticated Slim pod probe returned the expected HTTP 401. |

Here, “callback” means a server-side SAIA or Slim request to Splunk's REST API for token validation; the search operations tested here were initiated by SAIA. It is a request/response flow initiated by the workload, not an unsolicited webhook. The two token-validation paths above and the search paths below use the private listener in the tested configuration. Do not send these Splunk management paths through the public `:443` SAIA catch-all.

The following method/path pairs were configured on the private HTTP listener on port 8080 to reach Splunk's verified HTTPS management endpoint on port 8089:

| Method | Path |
|---|---|
| GET | `/services/authorization/tokens-keys` |
| GET | `/services/authentication/current-context` |
| GET | `/services/server/info` |
| GET | `/services/data/indexes` |
| GET | `/servicesNS/-/-/saved/searches` |
| GET | `/servicesNS/-/-/data/ui/views` |
| POST | `/services/search/jobs/export` |
| POST | `/servicesNS/nobody/system/search/v2/parser` |
| POST | `/servicesNS/nobody/system/search/v2/jobs/` |
| GET | `/servicesNS/nobody/system/search/v2/jobs/{numeric-sid}/` |
| POST | `/servicesNS/nobody/system/search/v2/jobs/{numeric-sid}/results` |
| POST | `/servicesNS/nobody/system/search/v2/jobs/{numeric-sid}/results_preview` |
| POST | `/servicesNS/nobody/system/search/v2/jobs/{numeric-sid}/control` |

Do not add a catch-all `/services/*` router. Add a new method/path pair only after confirming the exact request in SAIA logs and a matching Traefik route miss; each route must keep the verified upstream CA and server-name checks.

For the v2 search-job `results` endpoint, the live Traefik rule matches `POST` and a numeric SID with a dot (for example, `123.0`), and routes it through `jwks` on port 8080 to the existing verified Splunk service. Verify the route without credentials using a dummy SID; an HTTP 401 from Splunk shows that Traefik matched and forwarded the request. A Traefik 404 means the route did not match. Do not test this management path on the public port 443.

~~~sh
curl -sS -o /dev/null -w '%{http_code}' -X POST 'http://<TRAEFIK_PRIVATE_IP>:8080/servicesNS/nobody/system/search/v2/jobs/123.0/results'
~~~

Do not expose the private listener to the internet. The Traefik security group allows port 8080 only from the k0s node security group; Splunk port 8089 allows only the Traefik security group.

## Validated setup procedure

The steps in this section describe the reference procedure exercised in the in-house test. Replace every placeholder with customer-owned values. The successful test evidence is in the separate [validation evidence](#validation-evidence) section below; incident analysis is kept in the [troubleshooting guide](fips-traefik-troubleshooting.md).

### Tested component versions

| Component | In-house test value |
|---|---|
| k0s | 1.37.1 |
| Traefik | 3.6.14; Go 1.26.4; linux/amd64 |
| Traefik test image | Local tag `mpr70/traefik-fips:test-amd64`; image ID `sha256:4f28c10d658239fc0ec335394e552ab77ce8d67d2680133d0ddb90f4c3302dac`; Docker reported no repository digest |
| Traefik runtime mode | GODEBUG=fips140=only |
| Splunk Enterprise | 10.2.8; image splunk/splunk:10.2-rhel9, digest sha256:43f460e8a542619c26672e5a4f3d92a91875aceaaa8c2269df28ad70a9c30441 |
| Splunk AI Assistant | 2.3.6 |
| Splunk AI Toolkit | 6.2.0 |
| Python for Scientific Computing | 4.3.5 |
| SAIA API image | splunk/ai-tier-saia-api@sha256:13c85fca60498de8458e057c9c5c7e5a345d89943fc87ba0e0c2f16b79d09faf |
| SAIA v2 API and worker | `10.0.39.248:5000/splunk/ai-tier-saia-api-v2@sha256:b16c758beac8a203961fe34bc60b71f017cca2c00da48202aeea1e0cd93f01d5` (source build `v2.3.16-2-g09d78c9`) |
| Slim image | splunk/ai-tier-slim-service@sha256:8fdb46e72445dba726d64cd7396ce1f6855fcf493381f7ae1add43640728f04d |

The test Traefik image was a local tag with no registry digest. The in-house test record is limited to that image; it does not validate a published/customer image or establish registry provenance. The binary reported `Built: 2012-04-19_13:30:00`.

### Prerequisites

- Existing, healthy k0s AI-Tier stack with SAIA and Slim installed.
- External Splunk Enterprise host reachable from the gateway on management port 8089.
- For the in-house test, the Splunk upstream and gateway callback issuer used private IP addresses covered by the certificates' IP SANs.
- Customer-provided TLS certificates and CA chains:
  - Traefik listener certificate covering the client-facing FQDN.
  - Splunk management certificate covering the private upstream FQDN or IP.
  - The CA for the Splunk management certificate installed in Traefik's rootCAs.
- Current valid Splunk entitlement and administrator access.
- Security groups or firewall rules that can restrict traffic by source group or CIDR.

### 1. Prepare external Splunk

Run Splunk outside the k0s cluster. The in-house test used Docker and `splunk/splunk:10.2-rhel9@sha256:43f460e8a542619c26672e5a4f3d92a91875aceaaa8c2269df28ad70a9c30441`.

The test host used the following Docker setup shape (the private address is environment-specific):

~~~bash
docker pull splunk/splunk:10.2-rhel9@sha256:43f460e8a542619c26672e5a4f3d92a91875aceaaa8c2269df28ad70a9c30441
docker image inspect --format '{{index .RepoDigests 0}}' splunk/splunk:10.2-rhel9

sudo install -d -m 700 /opt/splunk
sudo install -m 600 /dev/null /opt/splunk/splunk.env
sudoedit /opt/splunk/splunk.env
~~~

In the protected environment file, set `SPLUNK_PASSWORD` to a unique administrator password. After the authorized administrator has reviewed and accepted the current Splunk General Terms for the applicable entity, include `SPLUNK_START_ARGS=--accept-license` and `SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com`. Do not put the password in shell history, source control, or this document.

Create the persistent Docker volumes and start the tested image. Bind both ports to the host's private interface; network security groups control access from the laptop and Traefik:

~~~bash
docker volume create splunk-etc
docker volume create splunk-var
docker run -d --name splunk --hostname splunk --restart unless-stopped \\
  --publish <SPLUNK_PRIVATE_IP>:8000:8000 \\
  --publish <SPLUNK_PRIVATE_IP>:8089:8089 \\
  --env-file /opt/splunk/splunk.env \\
  --volume splunk-etc:/opt/splunk/etc \\
  --volume splunk-var:/opt/splunk/var \\
  splunk/splunk:10.2-rhel9@sha256:43f460e8a542619c26672e5a4f3d92a91875aceaaa8c2269df28ad70a9c30441
~~~

Allow TCP 8000 from the administrator's public source CIDR so Splunk Web is reachable, and allow TCP 8089 only from the Traefik gateway security group. Do not rely on the Docker port binding as the access control. Confirm the container has finished initializing before installing apps. The 10.x startup flags above indicate acceptance each time the container starts; don't use them until the applicable terms have been reviewed and accepted. See the [Splunk Docker setup guide](https://github.com/splunk/docker-splunk/blob/develop/docs/SETUP.md).

Install the apps one at a time through Splunk Web or the approved app deployment process:

1. Python for Scientific Computing.
2. Splunk AI Toolkit.
3. Splunk AI Assistant.

For the account used to exercise AITK endpoints, grant the required AITK role, role_mltk_admin, using the customer's identity and role-management process. Do not share the Splunk admin password with the AI-Tier cluster.

Restrict Splunk Web port 8000 to the administrator/customer source CIDR. Restrict management port 8089 to the Traefik gateway security group only.

#### Configure Splunk management TLS

The in-house test installed a PEM server certificate and private key on Splunk. Its IP SAN matched the private IP used by Traefik; keep the key readable only by the Splunk service account.

Example server.conf:

~~~ini
[sslConfig]
enableSplunkdSSL = true
serverCert = /opt/splunk/etc/auth/customer-splunk-server.pem
sslPassword = <certificate-passphrase>
sslRootCAPath = /opt/splunk/etc/auth/customer-root-bundle.pem
~~~

Keep management TLS enabled. Splunk documents enableSplunkdSSL as controlling TLS on the management port and warns against running it without TLS. See [Splunk server.conf TLS settings](https://help.splunk.com/en/data-management/splunk-enterprise-admin-manual/10.2/configuration-file-reference/10.2.0-configuration-file-reference/server.conf) and [configuring certificates for the management port](https://help.splunk.com/en/splunk-enterprise/administer/manage-users-and-security/9.0/secure-splunk-platform-communications-with-transport-layer-security-certificates/configure-tls-certificates-for-inter-splunk-communication).

#### Set the token issuer to the private proxy URL

Splunk's OAuth issuer must exactly match AI-Tier's trusted issuer. In the validated SAIA path, SAIA uses the private HTTP listener on Traefik for both JWKS and current-context validation:

~~~ini
[oauth2_settings]
issuer_uri = http://<TRAEFIK_PRIVATE_IP>:8080
certFile = $SPLUNK_HOME/etc/auth/server.pem
sslPassword = <token-signing-certificate-passphrase>
~~~

The certFile in this stanza is used by Splunk's authentication system to sign OAuth tokens. It is separate from server.conf's management listener certificate. Protect both private keys. See [Splunk authentication.conf](https://help.splunk.com/en/splunk-enterprise/administer/admin-manual/10.2/configuration-file-reference/10.2.4-configuration-file-reference/authentication.conf).

Restart Splunk after changing server.conf or authentication.conf. Verify the management endpoint presents a valid chain and SAN from the Traefik host:

~~~bash
curl --cacert <SPLUNK_CA_BUNDLE> \
  'https://<SPLUNK_PRIVATE_IP>:8089/services/authorization/tokens-keys?output_mode=json'
~~~

Expected result: HTTP 200 with certificate verification enabled.

### 2. Restrict network paths

Before writing firewall rules or Traefik upstreams, read the NodePorts from the deployed Services; do not assume the defaults because an existing installation can override them:

~~~bash
kubectl get svc -n ai-platform
kubectl get svc <SAIA_SERVICE_NAME> <SLIM_SERVICE_NAME> -n ai-platform \
  -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,PORTS:.spec.ports[*].port,NODEPORTS:.spec.ports[*].nodePort'
~~~

Use the reported NodePorts as `<SAIA_NODEPORT>` and `<SLIM_NODEPORT>` below. Apply these rules using the customer's actual security groups or CIDRs:

| Destination | Port | Allowed source |
|---|---:|---|
| Traefik gateway | 443/TCP | Customer browser/app client CIDRs and external Splunk host if it calls the API |
| Traefik gateway private address | 8080/TCP | k0s node security group only |
| k0s SAIA NodePort | `<SAIA_NODEPORT>`/TCP | Traefik gateway security group only |
| k0s Slim NodePort | `<SLIM_NODEPORT>`/TCP | Traefik gateway security group only |
| External Splunk management | 8089/TCP | Traefik gateway security group only |
| Splunk Web | 8000/TCP | Administrator/customer CIDR only |
| SSH administration | 22/TCP | Administrator CIDR or approved access path only |

Remove any direct k0s-to-Splunk 8089 rule after the proxy path is verified. Do not open port 8080 to the internet.

### 3. Configure Traefik

The in-house test ran Traefik image `mpr70/traefik-fips:test-amd64` on the gateway. Preserve the tested runtime environment and least-privilege settings when reproducing the test. The image was local and had no registry digest, so this test does not validate a published/customer image.

**Test-mode qualification:** This procedure uses `GODEBUG=fips140=only` for strict test/assessment. Go describes `fips140=only` as a best-effort mode for testing, assessment, and debugging, and says it is not intended for production. Before production use, the build/Security owner must identify the exact Go Cryptographic Module version, build setting, applicable validation status, and approved operating environment for the pinned image. The runtime flag and successful TLS handshake alone do not establish that evidence. See [Go FIPS 140-3 documentation](https://go.dev/doc/security/fips140).

Docker launch command used for the test (replace only host-specific config/certificate paths and the supplemental group ID):

~~~bash
docker run -d --name traefik \
  --restart unless-stopped \
  --user appuser \
  --group-add <CONFIG_FILE_GROUP_ID> \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true \
  --env GODEBUG=fips140=only \
  --publish 443:443/tcp \
  --publish <TRAEFIK_PRIVATE_IP>:8080:8080/tcp \
  --volume /etc/traefik/traefik.yml:/etc/traefik/traefik.yml:ro \
  --volume /etc/traefik/dynamic/routes.yml:/etc/traefik/dynamic/routes.yml:ro \
  --volume /etc/traefik/certs:/etc/traefik/certs:ro \
  mpr70/traefik-fips:test-amd64 \
  --configFile=/etc/traefik/traefik.yml
~~~

The group ID must grant the container user read access to mounted config and key files. In this test, files were owned by root:3001, so the container needed supplemental group 3001. Preserve that access when recreating the container.

Static configuration declares the listeners and file provider. The listener certificate and TLS options belong in the dynamic file-provider configuration, alongside the routers. This keeps the public 443 entrypoint and private non-TLS 8080 entrypoint separate:

~~~yaml
entryPoints:
  websecure:
    address: ":443"
  jwks:
    address: ":8080"
providers:
  file:
    filename: /etc/traefik/dynamic/routes.yml
    watch: true
~~~

In `/etc/traefik/dynamic/routes.yml`, define the customer listener certificate and minimum TLS version with the dynamic configuration. The `jwks` entrypoint intentionally has no TLS configuration:

~~~yaml
tls:
  certificates:
    - certFile: /etc/traefik/certs/traefik.crt
      keyFile: /etc/traefik/certs/traefik.key
  options:
    default:
      minVersion: VersionTLS12
~~~

See Traefik's official [file-provider](https://doc.traefik.io/traefik/reference/routing-configuration/other-providers/file/), [TLS certificate](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/tls-certificates/), and [TLS option](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/tls-options/) references for the static/dynamic configuration split.

Add the application routers to the file provider. SAIA and Slim services use HTTP backends. Set `<SPLUNK_WEB_ORIGIN>` to the exact browser origin of the customer's Splunk Web, including scheme, hostname, and non-default port (for example, `https://splunk.example.com` or `http://splunk.example.com:8000`). Do not use the in-house test address as a customer value, and do not use a wildcard origin when credentials are enabled.

The Traefik CORS middleware answers browser `OPTIONS` preflights directly instead of forwarding them to SAIA or Slim. Its allow-header list below includes the fallback headers supported by the current SAIA Nginx configuration and `request_id` used by the tested AITK flow. Before deployment, compare it with the browser's `Access-Control-Request-Headers` for the installed app versions and add any additional requested names, including app-specific headers such as `X-CSRF-Token` or `X-Splunk-*` if they appear. Traefik's list is static and must be kept in sync. The Slim router uses the same middleware so Traefik can answer the AITK preflight. See Traefik's [Headers middleware CORS behavior](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/headers/). The private routers expose the tested Splunk routes and share a verified HTTPS service transport:

~~~yaml
http:
  middlewares:
    saia-browser-cors:
      headers:
        accessControlAllowOriginList:
          - <SPLUNK_WEB_ORIGIN>
        accessControlAllowMethods:
          - GET
          - POST
          - PUT
          - PATCH
          - DELETE
          - OPTIONS
        accessControlAllowHeaders:
          - Authorization
          - Content-Type
          - X-EC-Token
          - X-ES-Tenant-Bearer
          - X-Conversation-Key
          - X-Request-ID
          - X-Stack-URL-Legacy
          - Splunk-Client
          - X-Stack-URL
          - X-Requested-With
          - X-Admin-Preferences-Filename
          - request_id
        accessControlAllowCredentials: true
        addVaryHeader: true
  routers:
    saia-api-cors:
      rule: Host(`<TRAEFIK_FQDN>`) && PathPrefix(`/tenant-id-sok/saia-api-v2`)
      priority: 110
      entryPoints: [websecure]
      middlewares: [saia-browser-cors]
      service: saia
      tls: {}
    slim:
      rule: Host(`<TRAEFIK_FQDN>`) && PathPrefix(`/tenant/slim-api`)
      priority: 100
      entryPoints: [websecure]
      middlewares: [saia-browser-cors]
      service: slim
      tls: {}
    saia-fallback:
      rule: Host(`<TRAEFIK_FQDN>`) && PathPrefix(`/`)
      priority: 1
      entryPoints: [websecure]
      middlewares: [saia-browser-cors]
      service: saia
      tls: {}
    splunk-jwks:
      rule: Method("GET") && Path("/services/authorization/tokens-keys")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-current-context:
      rule: Method("GET") && Path("/services/authentication/current-context")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-server-info:
      rule: Method("GET") && Path("/services/server/info")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-data-indexes:
      rule: Method("GET") && Path("/services/data/indexes")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-saved-searches:
      rule: Method("GET") && Path("/servicesNS/-/-/saved/searches")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-data-views:
      rule: Method("GET") && Path("/servicesNS/-/-/data/ui/views")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-search-export:
      rule: Method("POST") && Path("/services/search/jobs/export")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-search-parser:
      rule: Method("POST") && Path("/servicesNS/nobody/system/search/v2/parser")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-search-jobs-create:
      rule: Method("POST") && Path("/servicesNS/nobody/system/search/v2/jobs/")
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-search-job-status:
      rule: Method("GET") && PathRegexp(`^/servicesNS/nobody/system/search/v2/jobs/[0-9]+\.[0-9]+/$`)
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-search-job-results:
      rule: Method("POST") && PathRegexp(`^/servicesNS/nobody/system/search/v2/jobs/[0-9]+\.[0-9]+/results$`)
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-search-job-results-preview:
      rule: Method("POST") && PathRegexp(`^/servicesNS/nobody/system/search/v2/jobs/[0-9]+\.[0-9]+/results_preview$`)
      entryPoints: [jwks]
      service: splunk-jwks
    splunk-search-job-control:
      rule: Method("POST") && PathRegexp(`^/servicesNS/nobody/system/search/v2/jobs/[0-9]+\.[0-9]+/control$`)
      entryPoints: [jwks]
      service: splunk-jwks
  services:
    saia:
      loadBalancer:
        servers:
          - url: http://<K0S_NODE_OR_LB>:<SAIA_NODEPORT>
    slim:
      loadBalancer:
        servers:
          - url: http://<K0S_NODE_OR_LB>:<SLIM_NODEPORT>
    splunk-jwks:
      loadBalancer:
        serversTransport: splunk-mgmt
        passHostHeader: false
        servers:
          - url: https://<SPLUNK_PRIVATE_IP>:8089
  serversTransports:
    splunk-mgmt:
      rootCAs:
        - /etc/traefik/certs/splunk-ca.crt
      serverName: <SPLUNK_PRIVATE_IP>
~~~

The callback service uses the URL scheme and port to open a new HTTPS connection to Splunk; `rootCAs` and `serverName` make certificate verification explicit. Keep `insecureSkipVerify` disabled (the default). The route forwards the original path and query string, and the service is constrained by exact method/path routers. Do not add a generic `ExternalName`, `/services/*` catch-all, or a Host-rewrite middleware without a separately reviewed requirement.

In the test, the upstream identity was Splunk private IP `10.0.39.253`, covered by its certificate IP SAN and the configured test CA. The `serverName` value is the identity only; it has no URL scheme or path.

The public routers use the tested SAIA path prefix `/tenant-id-sok/saia-api-v2` and Slim path prefix `/tenant/slim-api` on the TLS entrypoint. The higher-priority SAIA v2 and Slim routers take precedence; the lower-priority SAIA fallback sends `/health` and other otherwise-unmatched paths on this host to SAIA. Keep the Host match so requests for unrelated hostnames do not enter these services. The browser-facing test used the certificate-covered gateway hostname and the browser trusted the test CA. The private-IP browser request from the HTTP Splunk Web origin was blocked by Chrome before it reached Traefik, even when CORS was configured.

### 4. Configure AI-Tier's trusted issuer

Add the same private proxy URL to AIPlatform spec.splunkConfiguration.trustedIssuers:

~~~yaml
spec:
  splunkConfiguration:
    trustedIssuers:
      - http://<TRAEFIK_PRIVATE_IP>:8080
~~~

Do not add the direct external Splunk `:8089` URL to the validated SAIA proxy path. Reconcile the AIPlatform and confirm the SAIA pod has the configured `SPLUNK_ISSUERS` value.

### 5. Verify the path

1. Confirm the Traefik process has `GODEBUG=fips140=only`; record the tested image ID and version.
2. From a client that trusts the Traefik CA, request https://<TRAEFIK_FQDN>/health. Expected result: HTTP 200 with TLS certificate validation enabled.
3. From SAIA and Slim pods, request the private HTTP JWKS URL. Expected result: HTTP 200. An unauthenticated `current-context` probe may return HTTP 401; the authenticated application flow should return HTTP 200. Both workloads use HTTP to the private gateway listener.
4. From the Traefik host, verify the Splunk upstream with the configured CA and hostname/IP checks. Expected result: HTTP 200.
5. Mint a fresh Splunk interactive JWT without printing or saving it. Confirm its `iss` matches `http://<TRAEFIK_PRIVATE_IP>:8080`.
6. From Splunk Web, perform the authenticated app checks through the public Traefik URL, one at a time:
   - **SAIA:** Open **Splunk AI Assistant → Configuration**, set the SAIA API URL to `https://<TRAEFIK_FQDN>` with no trailing slash and save. The SAIA 2.3.6 setup check appends `/health`; the tested gateway health request returned HTTP 200 with certificate validation enabled.
   - **Slim:** In **Splunk AI Toolkit → Connections**, set the Splunk AI tier endpoint to `https://<TRAEFIK_FQDN>/tenant/slim-api/v1alpha1`. Create or test a **Splunk AI tier LLM** connection and select a model. This exercises the authenticated `chat/models` request. Expected result: the models load and the connection succeeds. Use an account with the AITK role required by customer policy.
   - **AITK inference and Slim callback:** In Splunk AI Toolkit Search, run `| makeresults | ai prompt="Reply exactly: Slim callback check" connection="gemma"`. Confirm the answer returns and correlate the run time with Traefik access-log `200` responses for `/services/authorization/tokens-keys` and `/services/authentication/current-context` from the k0s node hosting Slim.
   The apps mint and send their own interactive tokens; do not copy tokens into a terminal or share them.
   **Check the browser path separately from the Splunk-side connection test.** The browser requests were tested with `https://saia-test.mpr70.test`: the laptop resolved it to the public Traefik address, and the Splunk host resolved it to the private Traefik address. The browser trusted the test CA. A request to the private IP from the HTTP Splunk Web origin was blocked by Chrome before reaching Traefik; CORS headers did not change that result.
7. Confirm direct connection from an SAIA pod to Splunk port 8089 is blocked.
8. Verify the configured search API paths against Traefik access logs. In the test, the unauthenticated `/results` probe returned Splunk HTTP 401, confirming that Traefik matched and forwarded it. The checks recorded here establish routing only.
9. Record TLS versions/ciphers, tested image ID, component versions, and test results.

## Validation evidence

This section contains only checks that were run in the in-house setup. The troubleshooting guide keeps the separate symptom analysis and recovery history.

### Confirmed setup and network checks

The 2026-11-02 test passed the following:

- Traefik ran with GODEBUG=fips140=only; version 3.6.14, Go 1.26.4.
- Ingress TLS certificate validation succeeded for TLS 1.2 (ECDHE-RSA-AES128-GCM-SHA256) and TLS 1.3 (TLS_AES_128_GCM_SHA256).
- From the customer's laptop, the public gateway IP health request validated the test CA and IP SAN, negotiated TLS 1.3, and returned HTTP 200 over HTTP/2.
- Gateway-to-Splunk management TLS verification succeeded with the test CA and IP SAN; JWKS returned HTTP 200.
- SAIA's JWKS and current-context token checks passed through the private Traefik listener to Splunk.
- The user confirmed the AITK connection/model-list check succeeded through the public Traefik route to Slim.
- Direct SAIA-pod access to Splunk port 8089 was blocked after security-group tightening.

On 2026-11-04, an AITK inference call was verified end to end from Splunk through Traefik to Slim: the same request ID appeared in Splunk's `mlspl.log` and Slim's log, `POST /tenant/slim-api/v1alpha1/chat/completions` returned HTTP 200, and AITK recorded `execution_status=success`.

On 2026-11-05, the user ran the minimal AITK inference SPL above and received a result. At `07:54:07 UTC`, Traefik logged HTTP 200 responses for both `/services/authorization/tokens-keys` and `/services/authentication/current-context` from node `10.0.38.66`, which hosted the Slim pod. The Slim pod's unauthenticated probe to the same private listener returned HTTP 200 for JWKS and HTTP 401 for current-context, as expected without a token. The live Traefik route points to `https://10.0.39.253:8089` and uses the configured CA and `serverName`. Together these checks validate the callback path for the AITK/Slim run. Traefik's access log identifies the source node rather than the pod, and SAIA also ran on that node; the log is therefore correlated with the isolated AITK run but is not a pod-identity record.

### Search-route checks

On 2026-11-03 UTC / 2026-11-04 local, exact search API routes were exercised: parser returned HTTP 200, job creation returned HTTP 201, and result-preview/control requests returned HTTP 200. On 2026-11-04, the missing `/results` route was added and a request with a dummy search SID returned Splunk HTTP 401 through the configured HTTPS upstream, confirming the route matched and forwarded. These are route-level checks; they do not constitute an authenticated SAIA search result.

### Test boundary

The test used temporary certificates and a local Traefik image with no registry digest. The observed TLS handshakes and `GODEBUG=fips140=only` runtime setting do not validate the image or cryptographic module. No production FIPS certification claim is made here.
