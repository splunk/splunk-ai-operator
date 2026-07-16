# External Splunk Integration with Splunk AI Platform

Runbook for connecting an **externally-hosted Splunk Enterprise instance** (outside the
k0s cluster) to the Splunk AI Platform backend (SAIA). Covers every failure mode
encountered in practice, in the order you are likely to hit them.

Use this when:
- Splunk Enterprise runs on a separate host (bare-metal, EC2, VM) — not the bundled
  in-cluster Splunk standalone deployed by the installer.
- The SAIA backend (`AIService`) must validate JWT tokens issued by that external Splunk.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Step 1 — Fix JWT Signing Key Error](#step-1--fix-jwt-signing-key-error)
- [Step 2 — Fix 401 Unauthorized from SAIA Backend](#step-2--fix-401-unauthorized-from-saia-backend)
- [Step 3 — Fix Browser Mixed-Content Block](#step-3--fix-browser-mixed-content-block)
  - [Option A — Disable Splunk Web SSL (temporary workaround)](#option-a--disable-splunk-web-ssl-temporary-workaround)
  - [Option B — TLS Termination via Load Balancer or Ingress (production fix)](#option-b--tls-termination-via-load-balancer-or-ingress-production-fix)
- [Step 4 — Fix "Issuer Not Allowed" from SAIA Backend](#step-4--fix-issuer-not-allowed-from-saia-backend)
- [Step 5 — Restart Splunk Correctly](#step-5--restart-splunk-correctly)
- [Step 6 — Final Verification](#step-6--final-verification)
- [Cleanup](#cleanup)
- [Troubleshooting Quick Reference](#troubleshooting-quick-reference)

---

## Architecture Overview

```
Browser
  │
  │  HTTP/HTTPS :8000
  ▼
Splunk Enterprise (external host, e.g. 43.203.164.228)
  │  Issues JWT tokens (issuer = https://<public-ip>:8089)
  │  Port 8089 must be reachable from the SAIA backend cluster
  │
  │  Bearer token in request
  ▼
SAIA Backend (k0s cluster, e.g. 15.164.171.171)
  │  Validates JWT: checks issuer, fetches JWKS from Splunk :8089
  │  Allowed issuers controlled by AIPlatform CR → AIService → ConfigMap → pod env
  ▼
Ray inference / LLM
```

Key constraint: the SAIA backend fetches the public signing keys from
`<issuer_uri>/.well-known/oauth2_keys` at JWT validation time. The `issuer_uri`
in the token must exactly match an entry in the SAIA backend's `SPLUNK_ISSUERS`
allowlist, and it must be reachable from the k0s cluster nodes.

---

## Prerequisites

- SSH access to the external Splunk host
- `kubectl` access to the k0s cluster running SAIA
- The external Splunk host's public IP or FQDN (used as `issuer_uri`)
- Port **8089** (Splunk management) open from the k0s cluster nodes to the Splunk host

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
    issuer_uri = https://<PUBLIC_IP_OR_FQDN>:8089
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

1. Change `issuer_uri` in `authentication.conf` to the public IP or FQDN:

    ```ini
    [oauth2_settings]
    issuer_uri = https://<YOUR_PUBLIC_IP>:8089
    certFile = $SPLUNK_HOME/etc/auth/server.pem
    sslPassword = <passphrase>
    ```

2. Verify port 8089 is reachable **from the k0s cluster** (this is the path that
   actually performs JWT validation — a check from your laptop can pass while
   SAIA pods are still blocked by a security group or firewall):

    ```bash
    # Run from any k0s cluster node (e.g. the installer or controller)
    nc -zv <public-ip> 8089
    # or
    curl -sk https://<public-ip>:8089/services/server/info | grep -c "<title>"
    ```

    If the check passes from your laptop but fails from the cluster, update the
    Splunk host's security-group inbound rules to allow port 8089 from the
    cluster nodes' IP range.

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

**Root cause:** `SPLUNK_ISSUERS` is a key in the SAIA config `ConfigMap`. The
operator sets it to the hardcoded default (`https://splunk-splunk-standalone-standalone-service:8089`)
when the key is absent or empty. Importantly:

- `AIService.spec.splunkConfiguration.endpoint` is the **HEC telemetry endpoint**
  (used by the log-forwarding sidecar as `<endpoint>/services/collector`) — it is
  **not** used to populate `SPLUNK_ISSUERS`. Patching `AIPlatform.spec.splunkConfiguration`
  will not update the issuer allowlist and will redirect telemetry to the wrong endpoint.
- The reconciler only fills **missing or empty** ConfigMap keys — once `SPLUNK_ISSUERS`
  is set, the operator will not overwrite it. Editing the ConfigMap directly is safe
  and is the correct fix.

**Fix — edit the SAIA ConfigMap directly:**

1. Find the SAIA config ConfigMap:

    ```bash
    kubectl get configmap -n <namespace> | grep saia-config
    ```

2. Patch `SPLUNK_ISSUERS` with the external Splunk's public issuer URL:

    ```bash
    kubectl patch configmap <name>-saia-config -n <namespace> --type merge \
      -p '{"data":{"SPLUNK_ISSUERS":"https://<PUBLIC_IP>:8089"}}'
    ```

    To allow **both** the in-cluster Splunk and the external Splunk simultaneously,
    separate the URLs with a space:

    ```bash
    kubectl patch configmap <name>-saia-config -n <namespace> --type merge \
      -p '{"data":{"SPLUNK_ISSUERS":"https://splunk-splunk-standalone-standalone-service:8089 https://<PUBLIC_IP>:8089"}}'
    ```

3. Confirm the value is set:

    ```bash
    kubectl get configmap <name>-saia-config -n <namespace> \
      -o jsonpath='{.data.SPLUNK_ISSUERS}'
    ```

4. Force SAIA pods to restart so they pick up the updated `ConfigMap`.

    > **Why not `kubectl rollout restart`?** The operator's reconcile loop can
    > race with a rollout restart. Deleting pods directly is more reliable — the
    > operator recreates them with the current ConfigMap value.

    ```bash
    # Find the SAIA v1 and v2 pods
    kubectl get pods -n <namespace> | grep saia

    # Delete them — operator recreates with updated env
    kubectl delete pod <saia-v1-pod> <saia-v2-pod> -n <namespace>
    ```

5. Wait for pods to reach `1/1 Running`, then re-test.

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
    # issuer_uri must show your public IP, not 127.0.0.1
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

3. **Confirm SAIA accepted the token** (check SAIA v1 pod logs):

    ```bash
    kubectl logs -n <namespace> <saia-v1-pod> --tail=20 | grep -E "200|401|issuer|token"
    ```

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

**Check for side-effects on the k0s cluster:**

If the k0s cluster previously had its own bundled Splunk standalone, the
ConfigMap patch in Step 4 may have replaced the in-cluster issuer with the
external one. Verify nothing else on the cluster depended on the bundled
instance:

```bash
# Check if the in-cluster Splunk standalone still exists and is healthy
kubectl get standalone -n ai-platform
kubectl get pods -n ai-platform | grep splunk

# Check current SPLUNK_ISSUERS value in the ConfigMap
kubectl get configmap -n ai-platform -o json | jq -r '.items[].data | select(has("SPLUNK_ISSUERS")) | .SPLUNK_ISSUERS'
```

If the in-cluster Splunk is still deployed and needs to be trusted alongside
the external one, patch `SPLUNK_ISSUERS` with both URLs as shown in Step 4:

```bash
kubectl patch configmap <name>-saia-config -n <namespace> --type merge \
  -p '{"data":{"SPLUNK_ISSUERS":"https://splunk-splunk-standalone-standalone-service:8089 https://<PUBLIC_IP>:8089"}}'
```

Otherwise, decommission whichever Splunk instance is no longer the source of
truth and leave only its issuer in `SPLUNK_ISSUERS`.

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
| Patching `AIPlatform.splunkConfiguration.endpoint` doesn't fix issuer | That field is the HEC endpoint, not the issuer — patch `SPLUNK_ISSUERS` in the ConfigMap directly | [Step 4](#step-4--fix-issuer-not-allowed-from-saia-backend) |
