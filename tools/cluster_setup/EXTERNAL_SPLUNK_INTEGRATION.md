# External Splunk Integration with Splunk AI Platform

Runbook for connecting an **externally-hosted Splunk Enterprise instance** (outside the
k0s cluster) to the Splunk AI Platform backend (SAIA). What the customer should do,
which files to edit, and what values to provide are covered first. Failure modes
encountered in practice are covered at the end.

Use this when:
- Splunk Enterprise runs on a separate host (bare-metal, EC2, VM) — not the bundled
  in-cluster Splunk standalone deployed by the installer.
- The SAIA backend (`AIService`) must validate JWT tokens issued by that external Splunk.

### Architecture Overview

```
Browser (Splunk AI Assistant)
  │
  ├─── HTTP/HTTPS :8000 ──────────────────────────────────────────────────────►
  │                                                                Splunk Enterprise
  │                                                          (external host, e.g. 43.203.164.228)
  │◄── JWT token (issuer = https://<issuer_uri>:8089) ─────────────────────────
  │
  │  XHR / EventSource — SAIA API calls with Bearer token
  │  (browser calls SAIA directly — NOT through Splunk)
  ▼
SAIA Backend (k0s cluster, e.g. 15.164.171.171)
  │  1. Validates JWT: issuer must be in SPLUNK_ISSUERS (ConfigMap <name>-saia-config)
  │  2. Fetches JWKS from https://<issuer_uri>:8089/.well-known/oauth2_keys
  │     → port 8089 must be reachable from k0s cluster nodes
  ▼
Ray inference / LLM
```

**Important:** The browser calls SAIA directly using the URL in `saia_sok_url`. Splunk
only issues the JWT token — it is not a proxy for SAIA requests. Firewall/SG rules must
allow access from the **browser's network** (not just from the Splunk host) to the SAIA
endpoint.

Key constraint: the SAIA backend fetches the public signing keys from
`<issuer_uri>/.well-known/oauth2_keys` at JWT validation time. The `issuer_uri`
in the token must exactly match an entry in the SAIA backend's `SPLUNK_ISSUERS`
ConfigMap key — patched directly as described in
[SAIA ConfigMap Values](#saia-configmap-values).

---

## Table of Contents

- [1. What the Customer Should Do](#1-what-the-customer-should-do)
- [2. Files and Resources to Edit](#2-files-and-resources-to-edit)
- [3. Values to Provide](#3-values-to-provide)
- [4. If Testing Fails](#4-if-testing-fails)

---

## 1. What the Customer Should Do

### Prerequisites

- SSH access to the external Splunk host
- `kubectl` access to the k0s cluster running SAIA
- The external Splunk host's public IP or FQDN (used as `issuer_uri`)
- Port **8089** (Splunk management) open from the k0s cluster nodes to the Splunk host

Complete the integration in this order:

1. SSH into the Splunk host.
2. Configure JWT signing in `authentication.conf` with a routable issuer.
3. Restart Splunk as the user that owns the installation.
4. Verify that the k0s cluster can reach the Splunk management port.
5. Place a TLS-terminating load balancer or ingress in front of SAIA.
6. Update the SAIA URL in Splunk AI Assistant.
7. Add the exact issuer to the SAIA `SPLUNK_ISSUERS` ConfigMap value.
8. Restart the SAIA pods and complete the end-to-end test.

### Restart Splunk Correctly

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

5. Verify the key is now loaded:

    ```bash
    grep -E "oauth2|JWT|signing" $SPLUNK_HOME/var/log/splunk/splunkd.log | tail -10
    ```

### Verify the Fix

1. **Verify issuer reachability.** Confirm port 8089 is reachable **from the
   k0s cluster** (this is the path that actually performs JWT validation — a
   check from your laptop can pass while SAIA pods are still blocked by a
   security group or firewall):

    ```bash
    # Run from any k0s cluster node (e.g. the installer or controller)
    nc -zv <public-ip> 8089
    # or
    curl -sk https://<public-ip>:8089/services/server/info | grep -c "<title>"
    ```

2. **Confirm a fresh token uses the correct issuer:**

    ```bash
    # Grab a fresh token from Splunk AI Assistant log
    grep "Successfully retrieved interactive token" \
      $SPLUNK_HOME/var/log/splunk/splunk_ai_assistant.log | tail -3
    ```

3. **Get a fresh browser token.** Old tokens signed before the real restart
   still carry the stale issuer and will fail even after the fix. Log out and
   back in to the Splunk AI Assistant to force a new token.

4. **Test end-to-end:**

    ```bash
    # From the browser, send a prompt in Splunk AI Assistant
    # Expected: response returned without error
    ```

5. **Confirm SAIA accepted the token** (check SAIA v1 pod logs):

    ```bash
    kubectl logs -n <namespace> <saia-v1-pod> --tail=20 | grep -E "200|401|issuer|token"
    ```

---

## 2. Files and Resources to Edit

| File or resource | Customer change |
|---|---|
| `$SPLUNK_HOME/etc/system/local/authentication.conf` | Add or update `[oauth2_settings]` |
| `server.conf` `[sslConfig]` | Read the encrypted certificate passphrase; do not edit it for this procedure |
| Load balancer, ingress, firewall, security-group, DNS, and certificate resources | Publish SAIA over HTTPS and allow the required network paths |
| Splunk AI Assistant app-local `splunkaiassistant.conf` | Set the SAIA URL used by Splunk AI Assistant; the app-local path depends on the installed app version |
| SAIA ConfigMap `<name>-saia-config` | Set `data.SPLUNK_ISSUERS` |
| `$SPLUNK_HOME/etc/system/local/web.conf` | Edit only for the temporary mixed-content workaround under [If Testing Fails](#browser-mixed-content-block) |

---

## 3. Values to Provide

### Splunk JWT Values

Edit `$SPLUNK_HOME/etc/system/local/authentication.conf` and add:

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

Restart Splunk (see [Restart Splunk Correctly](#restart-splunk-correctly) for the correct procedure).

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

### SAIA ConfigMap Values

The following details explain why this resource is edited:

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

2. Patch `SPLUNK_ISSUERS` with the **exact** `issuer_uri` value from
   `authentication.conf` — this must be a character-for-character match (IP or
   FQDN, same scheme and port) because SAIA compares it literally against the
   `iss` claim in each JWT:

    ```bash
    # Use the exact issuer_uri value from authentication.conf, e.g.:
    #   https://43.203.164.228:8089   (if configured as IP)
    #   https://splunk.example.com:8089  (if configured as FQDN)
    kubectl patch configmap <name>-saia-config -n <namespace> --type merge \
      -p '{"data":{"SPLUNK_ISSUERS":"<EXACT_ISSUER_URI>"}}'
    ```

    To allow **both** the in-cluster Splunk and the external Splunk simultaneously,
    separate the URLs with a space:

    ```bash
    kubectl patch configmap <name>-saia-config -n <namespace> --type merge \
      -p '{"data":{"SPLUNK_ISSUERS":"https://splunk-splunk-standalone-standalone-service:8089 <EXACT_ISSUER_URI>"}}'
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

**Check for side-effects on the k0s cluster:**

If the k0s cluster previously had its own bundled Splunk standalone, the
ConfigMap patch above may have replaced the in-cluster issuer with the
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
the external one, patch `SPLUNK_ISSUERS` with both URLs as shown above:

```bash
kubectl patch configmap <name>-saia-config -n <namespace> --type merge \
  -p '{"data":{"SPLUNK_ISSUERS":"https://splunk-splunk-standalone-standalone-service:8089 https://<PUBLIC_IP>:8089"}}'
```

Otherwise, decommission whichever Splunk instance is no longer the source of
truth and leave only its issuer in `SPLUNK_ISSUERS`.

---

## 4. If Testing Fails

### JWT Signing Key Error

**Symptom:** Splunk log shows:

```
Unable to load keys for signing interactive JWT
```

**Root cause:** The `[oauth2_settings]` stanza in `authentication.conf` is missing
or empty — `AuthenticationRSAKeysManager` has no certificate to sign tokens with.

Confirm the error:

```bash
grep "Unable to load keys for signing interactive JWT" \
  $SPLUNK_HOME/var/log/splunk/splunkd.log | tail -5
```

Apply the values in [Splunk JWT Values](#splunk-jwt-values), restart Splunk, and repeat the JWT signing test.

### 401 Unauthorized from SAIA Backend

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

2. If the reachability check passes from your laptop but fails from the cluster,
   update the Splunk host's security-group inbound rules to allow port 8089 from
   the cluster nodes' IP range.

3. Restart Splunk (see [Restart Splunk Correctly](#restart-splunk-correctly)).

Confirm the issuer and network values in [Splunk JWT Values](#splunk-jwt-values), then repeat the issuer reachability test.

### Browser Mixed-Content Block

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

#### Option A — Disable Splunk Web SSL (temporary workaround)

1. Edit `$SPLUNK_HOME/etc/system/local/web.conf`:

```ini
[settings]
enableSplunkWebSSL = 0
```

2. Restart Splunk (see [Restart Splunk Correctly](#restart-splunk-correctly)).

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

#### Cleanup

After testing is complete, revert the temporary workaround above:

1. Edit `$SPLUNK_HOME/etc/system/local/web.conf`:

    ```ini
    [settings]
    enableSplunkWebSSL = 1
    ```

2. Restart Splunk as the owning user (see [Restart Splunk Correctly](#restart-splunk-correctly)).

3. Update the SAIA URL in the Splunk AI Assistant app config to use `https://`
   once Splunk Web is back on HTTPS.

### Issuer Not Allowed from SAIA Backend

**Symptom:** SAIA returns:

```json
{"detail": "Issuer 'https://127.0.0.1:8089' is not allowed"}
```

(or whatever the old issuer was)

**Root cause:** `SPLUNK_ISSUERS` is a key in the SAIA config `ConfigMap`. The
operator sets it to the hardcoded default (`https://splunk-splunk-standalone-standalone-service:8089`)
when the key is absent or empty.

Apply the exact issuer value in [SAIA ConfigMap Values](#saia-configmap-values), restart the SAIA pods, and re-test.

### Splunk Restart Did Not Apply

**Symptom:** `sudo /opt/splunk/bin/splunk restart` appears to succeed (or
silently exits 1) but the old config is still active — new tokens still carry
the stale `issuer_uri`, and `splunkd` keeps the same PID.

**Root cause:** Splunk is owned by a non-root user (e.g. `ec2-user`). Running
`sudo splunk restart` switches to root, which cannot stop/start the process
owned by another user. The command exits without touching the running process.

Follow [Restart Splunk Correctly](#restart-splunk-correctly), then repeat the restart and effective-configuration checks.

### Fresh Fix Works but Old Browser Session Still Fails

**Symptom:** The values above are all correct and verified, but the browser
still gets a `401` or an "issuer not allowed" error.

**Root cause:** A stale JWT issued before the fix (or before the real restart)
is still cached in the browser session.

Log out and back in to the Splunk AI Assistant to force a new token, then
repeat [Verify the Fix](#verify-the-fix).

### Troubleshooting Quick Reference

| Symptom | Most likely cause | Section |
|---------|-------------------|---------|
| `Unable to load keys for signing interactive JWT` | Missing `[oauth2_settings]` in `authentication.conf` | [JWT signing error](#jwt-signing-key-error) |
| `401 Unauthorized` from SAIA, JWKS fetch fails | `issuer_uri = https://127.0.0.1:8089` | [401 / JWKS failure](#401-unauthorized-from-saia-backend) |
| Browser `blocked:mixed-content`, request never sent | Splunk HTTPS + SAIA HTTP | [Mixed content](#browser-mixed-content-block) |
| `{"detail":"Issuer '...' is not allowed"}` | External issuer not in `SPLUNK_ISSUERS` allowlist | [Issuer not allowed](#issuer-not-allowed-from-saia-backend) |
| Config change has no effect after restart | Restarted with `sudo` but Splunk owned by another user | [Restart did not apply](#splunk-restart-did-not-apply) |
| Fresh fix works but old browser session still fails | Stale JWT from before the restart — log out and back in | [Stale browser session](#fresh-fix-works-but-old-browser-session-still-fails) |
| Patching `AIPlatform.splunkConfiguration.endpoint` doesn't fix issuer | That field is the HEC endpoint, not the issuer — patch `SPLUNK_ISSUERS` in the ConfigMap directly | [Issuer not allowed](#issuer-not-allowed-from-saia-backend) |
