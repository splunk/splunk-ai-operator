# External Splunk Integration with Splunk AI Platform

Runbook for connecting an **externally hosted Splunk Enterprise instance** to
Splunk AI Platform for JWT-authenticated SAIA and AI Toolkit (AITK) requests.
The Splunk instance may run in a different VPC or network from the k0s cluster;
what matters is routable, firewall-approved connectivity for each flow described
below.

> **Tested Splunk version:** Splunk Enterprise **10.2** is the tested version for
> both bundled/internal and external Splunk integration. For bundled Splunk, the
> tested container image is `docker.io/splunk/splunk:10.2-rhel9`.

Use this when:
- Splunk Enterprise runs on a separate host (bare-metal, EC2, VM) — not the bundled
  in-cluster Splunk standalone deployed by the installer.
- The SAIA backend (`AIService`) must validate JWT tokens issued by that external Splunk.

> **Release scope:** external Splunk integration is JWT authentication only,
> using the management/JWKS issuer on port **8089**. HEC ingestion on port
> **8088** and OTel export to external Splunk are unsupported and were not
> release-qualified. The installer still contains the legacy external HEC path;
> when `splunk.enabled: true`, setting `splunk.external.endpoint` selects it and
> may create or update a HEC-token Secret. That path is unsupported, so do not
> configure it or `SPLUNK_HEC_TOKEN`. This boundary does not change the existing
> bundled/internal Splunk HEC and OTel behavior.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Network Requirements](#network-requirements)
- [Prerequisites](#prerequisites)
- [Step 1 — Fix JWT Signing Key Error](#step-1--fix-jwt-signing-key-error)
- [Step 2 — Fix 401 Unauthorized from SAIA Backend](#step-2--fix-401-unauthorized-from-saia-backend)
- [Step 3 — Fix Browser Mixed-Content Block](#step-3--fix-browser-mixed-content-block)
  - [Option A — Disable Splunk Web SSL (temporary workaround)](#option-a--disable-splunk-web-ssl-temporary-workaround)
  - [Option B — TLS Termination via Load Balancer or Ingress (production fix)](#option-b--tls-termination-via-load-balancer-or-ingress-production-fix)
- [Step 4 — Fix "Issuer Not Allowed" from SAIA Backend](#step-4--fix-issuer-not-allowed-from-saia-backend)
- [Step 5 — Restart Splunk Correctly](#step-5--restart-splunk-correctly)
- [Step 6 — Final Verification](#step-6--final-verification)
- [Fresh Install and Issuer Updates](#fresh-install-and-issuer-updates)
- [Cleanup](#cleanup)
- [Troubleshooting Quick Reference](#troubleshooting-quick-reference)

---

## Architecture Overview

```text
Browser
  ├── HTTP/HTTPS :8000 ───────────────► External Splunk Enterprise
  │                                      └── issues JWT with
  │                                          iss=https://<issuer-host>:8089
  │
  └── HTTPS/HTTP SAIA URL ─────────────► SAIA ingress/NodePort
                                         └── Ray inference / LLM

External Splunk server
  └── HTTPS/HTTP Slim/SAIA URL ────────► AI Toolkit and server-side setup calls

SAIA and Slim workloads
  └── HTTPS :8089 ─────────────────────► External Splunk management/JWKS
```

**Important:** The browser calls SAIA directly using the URL in `saia_sok_url`.
Splunk issues the JWT; it is not a proxy for those browser requests. Firewall or
security-group rules must therefore allow the **browser's network**, not only the
external Splunk host, to reach the published SAIA endpoint. AITK requests run by
Splunk are server-side, so the external Splunk host must separately be able to
reach the published Slim endpoint.

Key constraint: the SAIA backend fetches public signing keys from the issuer at
JWT validation time. The current in-cluster SAIA and Slim images use Splunk's
native `<issuer_uri>/services/authorization/tokens-keys` route. Other client
versions or a customer-managed identity proxy may use a standard
`/.well-known/oauth2_keys` alias instead, so verify the route required by the
deployed image. In every case, the token's `issuer_uri` must exactly match an
entry derived from `spec.splunkConfiguration.trustedIssuers` in the managed
SAIA and Slim `SPLUNK_ISSUERS` ConfigMaps. Do not patch those ConfigMaps
directly.

## Network Requirements

External Splunk and the k0s cluster do **not** have to be in the same VPC. They
can be connected through routed VPCs, peering, a VPN, a private network, or
appropriately secured public endpoints. Validate each direction independently:

| Source | Destination | Purpose |
|---|---|---|
| User's browser | External Splunk Web `:8000` | Load and use the Splunk apps |
| User's browser | Published SAIA URL (NodePort `30080` in the tested k0s setup) | Splunk AI Assistant requests |
| External Splunk host | Published SAIA URL (NodePort `30080` in the tested k0s setup) | App onboarding and health checks |
| External Splunk host | Published Slim URL (NodePort `30081` in the tested k0s setup) | AITK model discovery and inference, including CDTSM |
| SAIA and Slim workloads | Exact external issuer `https://<host>:8089` | Fetch signing keys and validate JWTs |

A laptop VPN proves only that the laptop can reach a destination; it does not
provide a route for the cluster or external Splunk host. An SSH SOCKS tunnel is
useful for browser testing when the browser cannot directly reach a private
SAIA address, but it does not solve persistent workload-to-workload
connectivity. For production, publish the required services through a routed
private path or a secured ingress/load balancer. For the tested browser setup,
follow [K0S_README.md — Remote workstation via SSH bastion (SOCKS tunnel)](K0S_README.md#finding-the-splunk-web-url).

Opening a security-group rule permits traffic only when a route already exists.
It cannot create routing between unrelated VPCs. If the networks are separate,
establish the route or expose a secured public endpoint before adjusting the
security groups.

---

## Prerequisites

- SSH access to the external Splunk host
- `kubectl` access to the k0s cluster running SAIA
- A DNS name or IP that the cluster can reach, used in the exact management
  issuer `https://<host>:8089`
- Port **8089** (Splunk management/JWKS) open from SAIA and Slim to the Splunk host
- A published SAIA URL reachable from the user's browser
- For AITK, a published Slim URL reachable from the external Splunk host

---

## Step 1 — Fix JWT Signing Key Error

**Symptom:** Splunk log shows:

```
Unable to load keys for signing interactive JWT
```

**Root cause:** The `[oauth2_settings]` stanza in `authentication.conf` is missing
or empty — `AuthenticationRSAKeysManager` has no certificate to sign tokens with.

**Fix:**

1. SSH into the Splunk host.

2. Confirm the error:

    ```bash
    grep "Unable to load keys for signing interactive JWT" \
      $SPLUNK_HOME/var/log/splunk/splunkd.log | tail -5
    ```

3. Edit `$SPLUNK_HOME/etc/system/local/authentication.conf` and add:

    ```ini
    [oauth2_settings]
    issuer_uri = https://<ROUTABLE_IP_OR_FQDN>:8089
    certFile = $SPLUNK_HOME/etc/auth/server.pem
    sslPassword = <passphrase>
    ```

    To find the passphrase, check `server.conf`'s `[sslConfig]` stanza, or decrypt it:

    ```bash
    $SPLUNK_HOME/bin/splunk show-decrypted --value '<encrypted value from server.conf>'
    ```

    A typical default passphrase for a fresh Splunk install is `password`.

4. Restart Splunk (see [Step 5](#step-5--restart-splunk-correctly) for the correct procedure).

5. Verify the key is now loaded:

    ```bash
    grep -E "oauth2|JWT|signing" $SPLUNK_HOME/var/log/splunk/splunkd.log | tail -10
    ```

---

## Step 2 — Fix 401 Unauthorized from SAIA Backend

**Symptom:** SAIA returns `401 Unauthorized`. Splunk AI Assistant log shows
token fetch succeeds but SAIA rejects it.

**Root cause:** `issuer_uri` is set to `https://127.0.0.1:8089`. The SAIA
backend can't reach `127.0.0.1` on the Splunk host — it resolves to its own
loopback. The JWT validation (JWKS fetch) fails.

**Fix:**

1. Change `issuer_uri` in `authentication.conf` to a DNS name or IP that SAIA
   and Slim can reach:

    ```ini
    [oauth2_settings]
    issuer_uri = https://<ROUTABLE_HOST>:8089
    certFile = $SPLUNK_HOME/etc/auth/server.pem
    sslPassword = <passphrase>
    ```

2. Verify port 8089 is reachable **from the k0s cluster** (this is the path that
   actually performs JWT validation — a check from your laptop can pass while
   SAIA pods are still blocked by a security group or firewall):

    ```bash
    # Run from any k0s cluster node (e.g. the installer or controller)
    nc -zv <routable-host> 8089
    # or
    curl -skS -o /dev/null -w '%{http_code}\n' \
      'https://<routable-host>:8089/services/authorization/tokens-keys?output_mode=json'
    # Expected: 200
    ```

    If the check passes from your laptop but fails from the cluster, first
    confirm there is a route between the networks. Then update the Splunk
    host's security-group inbound rules to allow port 8089 from the cluster's
    source CIDR or security group.

3. Restart Splunk (see [Step 5](#step-5--restart-splunk-correctly)).

4. Confirm a new token carries the correct issuer:

    ```bash
    # Grab a fresh token from Splunk AI Assistant log
    grep "Successfully retrieved interactive token" \
      $SPLUNK_HOME/var/log/splunk/splunk_ai_assistant.log | tail -3
    ```

---

## Step 3 — Fix Browser Mixed-Content Block

**Symptom:** Browser dev tools → Network tab shows `blocked:mixed-content`.
The SAIA API call is blocked before it even leaves the browser.

**Root cause:** Splunk Web is served over **HTTPS** (port 8000), but the SAIA
backend URL configured in the AI Assistant app uses plain **HTTP**
(e.g. `http://15.164.171.171:30080`). Browsers enforce mixed-content policy
and block HTTPS pages from making HTTP sub-requests.

**Options (choose one):**

| Option | When to use |
|--------|-------------|
| [Option A — Disable Splunk Web SSL](#option-a--disable-splunk-web-ssl-temporary-workaround) | Testing / short-term debugging only |
| [Option B — TLS Termination via Load Balancer or Ingress](#option-b--tls-termination-via-load-balancer-or-ingress-production-fix) | Production — eliminates root cause |

---

### Option A — Disable Splunk Web SSL (temporary workaround)

1. Edit `$SPLUNK_HOME/etc/system/local/web.conf`:

    ```ini
    [settings]
    enableSplunkWebSSL = 0
    ```

2. Restart Splunk (see [Step 5](#step-5--restart-splunk-correctly)).

3. Verify Splunk Web is now HTTP:

    ```bash
    curl -sv http://<public-ip>:8000 2>&1 | grep -E "< HTTP|Location"
    # Expected: HTTP/1.1 303 or 200

    # Confirm HTTPS is no longer serving (port 8000 still open but speaks HTTP,
    # so TLS negotiation fails — not "connection refused"):
    curl -sv https://<public-ip>:8000 2>&1 | grep -E "SSL|TLS|handshake|wrong version|unknown protocol"
    # Expected: one of the above TLS error strings
    ```

> **Remember to revert this** once the SAIA backend is served over HTTPS or
> you are done testing. See [Cleanup](#cleanup).

---

### Option B — TLS Termination via Load Balancer or Ingress (production fix)

The correct long-term fix is to front the SAIA backend with a TLS-terminating
load balancer or ingress controller, so both Splunk Web and SAIA are served
over HTTPS. Mixed-content is then eliminated at the root — no browser config
changes needed.

#### How it resolves the mixed-content problem

```
External Splunk Web (HTTPS :8000)
  │   issues HTTPS page
  │
  │  XHR/EventSource to https://<host>:<port>   ← same scheme ✓
  ▼
Load balancer / ingress controller
  │   TLS terminated here; presents a trusted or imported certificate
  ▼
SAIA service (in-cluster HTTP)
```

#### What to configure

1. **Place a TLS terminator in front of SAIA.** This can be any of:
   - A cloud load balancer (ALB, NLB, GCP HTTPS LB) with an ACM/managed cert
   - An ingress controller (nginx, HAProxy, or similar) with a cert-manager certificate
   - An API gateway or reverse proxy (nginx, Envoy) on the same host

   The terminator listens on HTTPS (e.g. `:8443`) and proxies to the SAIA service
   on its internal HTTP port.

2. **Ensure the certificate is trusted by the browser.** Options:
   - Use a publicly-trusted cert (ACM, Let's Encrypt, corporate PKI)
   - Use a self-signed CA cert and import it once into the OS/browser trust store

3. **Open firewall / security-group rules** from the client/VPN CIDR to the HTTPS port
   on the load balancer or node.

4. **Update the SAIA URL** in Splunk AI Assistant onboarding to the HTTPS address:

    ```ini
    # splunkaiassistant.conf
    [saia_sok_configurations]
    saia_sok_enabled = true
    saia_sok_url = https://<host>:<port>
    ```

5. **If the SAIA backend's TLS cert is self-signed**, the load balancer's backend
   health check and the SAIA service itself may need to be configured to accept
   that cert (e.g. `proxy_ssl_verify off` in nginx, or importing the backend CA
   into the terminator's trust store).

#### Access pattern after TLS termination

| Before | After |
|---|---|
| `http://<host>:30080` (plain HTTP NodePort) | `https://<host>:<port>` |
| Browser blocks XHR from HTTPS Splunk page | Same scheme — no block |
| Requires keeping Splunk Web on HTTP | Splunk Web can stay on HTTPS |

---

## Step 4 — Fix "Issuer Not Allowed" from SAIA Backend

**Symptom:** SAIA returns:

```json
{"detail": "Issuer 'https://127.0.0.1:8089' is not allowed"}
```

(or whatever the old issuer was)

**Root cause:** the JWT `iss` claim must match an allowed management/JWKS
endpoint character-for-character. For the JWT-only external integration, the
k0s installer reads `splunk.trustedIssuers` and writes those values to the
AIPlatform custom resource. The operator then derives SAIA and Slim's
`SPLUNK_ISSUERS` values from that field.

Do not patch the generated SAIA or Slim ConfigMaps directly. The operator
recomputes `SPLUNK_ISSUERS` from the custom resource and will overwrite such a
manual edit.

**Fix — update the k0s config and rerun the installer:**

1. Choose the applicable configuration pattern.

   For **external Splunk only**, disable the bundled Splunk deployment and use
   the exact external management issuer:

    ```yaml
    splunk:
      enabled: false
      trustedIssuers:
        - https://<EXACT_MANAGEMENT_HOST>:8089
    ```

   To retain the **bundled Splunk and also trust an external Splunk**, keep
   internal mode enabled and add the external issuer:

    ```yaml
    splunk:
      enabled: true
      trustedIssuers:
        - https://<EXACT_EXTERNAL_MANAGEMENT_HOST>:8089
    ```

   In this release, do **not** set `splunk.external.endpoint` for JWT-only
   integration. That setting selects the installer's legacy external HEC mode,
   which requires a HEC token and is unsupported and not release-qualified.
   Port `8088` is not a JWT issuer.

2. Rerun the supported installer flow. Do not patch the generated AIPlatform,
   AIService, SAIA ConfigMap, or Slim ConfigMap as the installation method:

    ```bash
    cd tools/cluster_setup
    CONFIG_FILE=./k0s-cluster-config.yaml \
      ./k0s_cluster_with_stack.sh install
    ```

3. Confirm the installer rendered the configured issuer on AIPlatform:

    ```bash
    kubectl get aiplatform -n <namespace> <platform-name> \
      -o jsonpath='{.spec.splunkConfiguration.trustedIssuers}{"\n"}'
    ```

4. Confirm the operator propagated the exact management URL to both SAIA
   and Slim. Issuers are comma-separated when more than one is configured:

    ```bash
    kubectl get configmap -n <namespace> -o json \
      | jq -r '.items[] | select(.data.SPLUNK_ISSUERS != null) |
          [.metadata.name, .data.SPLUNK_ISSUERS] | @tsv'
    ```

5. Wait for the AIService to return to Ready and both v2 SAIA Deployments to
   finish rolling out, then obtain a fresh interactive token and retest:

    ```bash
    kubectl rollout status deployment/<aiservice-name>-saia-v2-deployment \
      -n <namespace> --timeout=10m
    kubectl rollout status deployment/<aiservice-name>-saia-v2-worker \
      -n <namespace> --timeout=10m

    kubectl exec -n <namespace> \
      deployment/<aiservice-name>-saia-v2-deployment -c saia-v2-api -- \
      python3 -c 'import os; print(os.environ.get("SPLUNK_ISSUERS", ""))'
    kubectl exec -n <namespace> \
      deployment/<aiservice-name>-saia-v2-worker -c saia-v2-worker -- \
      python3 -c 'import os; print(os.environ.get("SPLUNK_ISSUERS", ""))'
    ```

Both commands must print the newly configured issuer. No SAIA-service image or
source-code change is needed for this configuration.

---

## Step 5 — Restart Splunk Correctly

**Symptom:** `sudo /opt/splunk/bin/splunk restart` appears to succeed (or
silently exits 1) but the old config is still active — new tokens still carry
the stale `issuer_uri`, and `splunkd` keeps the same PID.

**Root cause:** Splunk is owned by a non-root user (e.g. `ec2-user`). Running
`sudo splunk restart` switches to root, which cannot stop/start the process
owned by another user. The command exits without touching the running process.

**Correct procedure:**

1. Check who owns the Splunk install:

    ```bash
    stat -c '%U' $SPLUNK_HOME      # Linux
    ```

2. Run as the owning user. If you are already logged in as the owner:

    ```bash
    $SPLUNK_HOME/bin/splunk stop
    $SPLUNK_HOME/bin/splunk start --answer-yes --accept-license
    ```

    If the SSH user is different from the owner (e.g. logged in as `ec2-user`
    but Splunk is owned by `splunk`), use `sudo -H -u`:

    ```bash
    SPLUNK_OWNER=$(stat -c '%U' $SPLUNK_HOME)
    sudo -H -u "${SPLUNK_OWNER}" $SPLUNK_HOME/bin/splunk stop
    sudo -H -u "${SPLUNK_OWNER}" $SPLUNK_HOME/bin/splunk start --answer-yes --accept-license
    ```

3. Confirm the PID actually changed (a matching old/new PID means it didn't restart):

    ```bash
    $SPLUNK_HOME/bin/splunk status
    ```

4. Confirm the config took effect:

    ```bash
    $SPLUNK_HOME/bin/splunk btool authentication list oauth2_settings
    # issuer_uri must show the routable host, not 127.0.0.1
    ```

---

## Step 6 — Final Verification

1. **Get a fresh token.** Old tokens signed before the real restart still carry
   the stale issuer and will fail even after the fix. Log out and back in to
   the Splunk AI Assistant to force a new token.

2. **Test end-to-end:**

    ```bash
    # From the browser, send a prompt in Splunk AI Assistant
    # Expected: response returned without error
    ```

3. **Confirm SAIA accepted the token** (check the API Deployment handling the
   request):

    ```bash
    kubectl logs -n <namespace> deployment/<aiservice-name>-saia-v2-deployment \
      --tail=50 | grep -E "200|401|issuer|token"
    ```

---

## Fresh Install and Issuer Updates

On a fresh installation, configuration is sufficient: the installer renders
`trustedIssuers` into AIPlatform before SAIA and Slim start, so their first pods
receive the correct allowlist.

For an existing installation, edit the same k0s config and rerun the installer.
A reliable post-install update also requires an operator version that
hashes the desired spec-derived `SPLUNK_ISSUERS` value into both v2 Deployment
pod templates during AIService reconciliation. Without that operator behavior,
the ConfigMap may be correct while the running v2 API and worker processes
retain the old value until an unrelated rollout occurs.

During engineering image-refresh testing, moving an existing installation to
the fixed operator added this annotation to both v2 pod templates and caused
one controlled rollout of the v2 API and v2 worker.

The functional fix belongs in the operator, not SAIA-service. Extra installer
verification is optional hardening: installer success confirms that resources
were applied, but operators should still run the ConfigMap and rollout checks
in Step 4 to prove that the live workloads adopted the issuer.

These lifecycle statements apply only to JWT issuers. External HEC ingestion
and OTel export to external Splunk are unsupported and not release-qualified.

---

## Cleanup

After testing is complete, revert the temporary workaround from Step 3:

1. Edit `$SPLUNK_HOME/etc/system/local/web.conf`:

    ```ini
    [settings]
    enableSplunkWebSSL = 1
    ```

2. Restart Splunk as the owning user (see [Step 5](#step-5--restart-splunk-correctly)).

3. Update the SAIA URL in the Splunk AI Assistant app config to use `https://`
   once Splunk Web is back on HTTPS.

**Remove an issuer when it is no longer trusted:**

Delete it from `splunk.trustedIssuers` in the k0s config and rerun the installer.
Do not remove it only from the generated ConfigMap. Verify the resulting
allowlist:

```bash
cd tools/cluster_setup
CONFIG_FILE=./k0s-cluster-config.yaml \
  ./k0s_cluster_with_stack.sh install

kubectl get configmap -n <namespace> -o json \
  | jq -r '.items[] | select(.data.SPLUNK_ISSUERS != null) |
      [.metadata.name, .data.SPLUNK_ISSUERS] | @tsv'
```

When bundled Splunk remains enabled, its internally derived issuer remains in
the allowlist; `trustedIssuers` contains only the additional external issuers.

---

## Troubleshooting Quick Reference

| Symptom | Most likely cause | Section |
|---------|-------------------|---------|
| `Unable to load keys for signing interactive JWT` | Missing `[oauth2_settings]` in `authentication.conf` | [Step 1](#step-1--fix-jwt-signing-key-error) |
| `401 Unauthorized` from SAIA, JWKS fetch fails | `issuer_uri = https://127.0.0.1:8089` | [Step 2](#step-2--fix-401-unauthorized-from-saia-backend) |
| Browser `blocked:mixed-content`, request never sent | Splunk HTTPS + SAIA HTTP | [Step 3](#step-3--fix-browser-mixed-content-block) |
| `{"detail":"Issuer '...' is not allowed"}` | External issuer not in `SPLUNK_ISSUERS` allowlist | [Step 4](#step-4--fix-issuer-not-allowed-from-saia-backend) |
| Config change has no effect after restart | Restarted with `sudo` but Splunk owned by another user | [Step 5](#step-5--restart-splunk-correctly) |
| Fresh fix works but old browser session still fails | Stale JWT from before the restart — log out and back in | [Step 6](#step-6--final-verification) |
| Request works from laptop but times out from cluster or Splunk host | Missing route or firewall/SG rule for that specific network path | [Network Requirements](#network-requirements) |
| External JWT issuer and HEC destination are conflated | Put the exact management/JWKS `:8089` URL in `splunk.trustedIssuers`; external HEC/OTel is unsupported, so do not use the legacy external HEC mode | [Step 4](#step-4--fix-issuer-not-allowed-from-saia-backend) |
| AIPlatform issuer configuration changed but v2 pods use the old issuer | Operator version does not roll both v2 Deployments for spec-derived `SPLUNK_ISSUERS` changes | [Fresh Install and Issuer Updates](#fresh-install-and-issuer-updates) |
