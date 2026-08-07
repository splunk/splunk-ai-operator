# On-Premises Splunk Enterprise Integration with Splunk AI Platform

This runbook connects an on-premises Splunk Enterprise search head to the Splunk
AI Platform backend (SAIA). It covers a single search head running outside the
k0s cluster. Search-head clusters require a separate deployer and configuration
bundle procedure.

The request flow is:

```text
Browser -> Splunk Web -> issues JWT
Browser -> SAIA API -> validates JWT
SAIA API -> Splunk management port 8089 -> downloads JWKS signing keys
```

## Before you begin

The customer needs:

- Administrator and shell access to the Splunk Enterprise host.
- `kubectl` access to the namespace containing the SAIA `AIService`.
- Splunk Enterprise and Splunk AI Assistant versions validated to issue
  interactive JWTs and expose `/.well-known/oauth2_keys`. Static or ephemeral
  token support alone is not sufficient.
- A Splunk management FQDN that resolves from the SAIA pods and has a certificate
  trusted by those pods.
- Port `8089` open from the SAIA cluster to the Splunk host.
- An HTTPS URL for SAIA that is reachable from the customer's browser.

Use the following values throughout the procedure:

| Value | Description | Example |
|---|---|---|
| `ISSUER_URI` | Splunk management URL used as the JWT issuer | `https://splunk.example.com:8089` |
| `NS` | Namespace containing SAIA | `ai-platform` |
| `AISERVICE` | SAIA `AIService` name | `production-ai-platform-saia` |
| `SAIA_URL` | Browser-reachable SAIA URL | `https://saia.example.com` |
| `SPLUNK_WEB_ORIGIN` | Scheme, host, and port used for Splunk Web | `https://splunk.example.com:8000` |
| `SPLUNK_HOME` | Splunk Enterprise installation directory | `/opt/splunk` |
| `SPLUNK_RUN_USER` | Actual operating-system account that runs `splunkd` | `splunk` |

Set them once in each administration shell:

Use the service unit or live `splunkd` process to identify `SPLUNK_RUN_USER`; do
not assume that the example account is correct.

```bash
NS=ai-platform
AISERVICE=production-ai-platform-saia
ISSUER_URI=https://splunk.example.com:8089
SAIA_URL=https://saia.example.com
SPLUNK_WEB_ORIGIN=https://splunk.example.com:8000
SPLUNK_HOME=/opt/splunk
SPLUNK_RUN_USER=splunk
```

Find the SAIA `AIService` name if it is not already known:

```bash
kubectl get aiservice -n "$NS" -l feature=saia
```

## Step 1 - Configure JWT signing in Splunk Enterprise

### What the customer should do

Configure Splunk Enterprise to issue JWTs with a routable issuer URI and signing
certificate. Restart Splunk as the operating-system user that runs `splunkd`.

### File to edit

```text
$SPLUNK_HOME/etc/system/local/authentication.conf
```

Back up the file and preserve unrelated stanzas.

### Values to provide

```ini
[oauth2_settings]
issuer_uri = https://splunk.example.com:8089
certFile = /opt/splunk/etc/auth/server.pem
sslPassword = <certificate-private-key-password>
```

- `issuer_uri` must be the exact `ISSUER_URI`; do not use `127.0.0.1` or
  `localhost`.
- `certFile` must be an absolute path to a supported PEM containing the signing
  certificate and accessible private-key material.
- `sslPassword` must be the actual PEM password. Do not store it in source
  control or shell history.

If the management certificate uses a private CA, add that CA to the SAIA pod's
trust store before testing.

Use the configured service manager when one exists. For a CLI-managed install,
apply and verify the change as follows:

```bash
sudo -H -u "$SPLUNK_RUN_USER" \
  "$SPLUNK_HOME/bin/splunk" btool authentication list oauth2_settings --debug

BEFORE_PID="$(pgrep -u "$SPLUNK_RUN_USER" -x splunkd || true)"
sudo -H -u "$SPLUNK_RUN_USER" "$SPLUNK_HOME/bin/splunk" restart
AFTER_PID="$(pgrep -u "$SPLUNK_RUN_USER" -x splunkd || true)"
printf 'before=%s after=%s\n' "$BEFORE_PID" "$AFTER_PID"
```

The restart must succeed, and the before/after PIDs must differ.

From the SAIA runtime, confirm that the JWKS endpoint is reachable and contains
at least one key:

```bash
kubectl exec -n "$NS" deployment/"${AISERVICE}-saia-deployment" -- \
  python -c 'import json,sys,urllib.request; print(len(json.load(urllib.request.urlopen(sys.argv[1]))["keys"]))' \
  "${ISSUER_URI%/}/.well-known/oauth2_keys"
```

The command must return a number greater than zero.

## Step 2 - Configure SAIA to trust the issuer

### What the customer should do

Set `SPLUNK_ISSUERS` to the same value used for `issuer_uri`, then recreate the
SAIA pods so they load the updated value.

### Resource to edit

```text
ConfigMap/${AISERVICE}-saia-config
data.SPLUNK_ISSUERS
```

Do not change `AIPlatform.spec.splunkConfiguration.endpoint`; that field is the
HEC telemetry endpoint, not the JWT issuer.

### Value to provide

The value must match the JWT `iss` claim exactly, including scheme, hostname,
port, case, and any trailing slash.

This sets one on-premises issuer. If another issuer must remain trusted, use the
multi-issuer format supported by the deployed SAIA version.

```bash
kubectl patch configmap "${AISERVICE}-saia-config" -n "$NS" --type merge \
  -p "{\"data\":{\"SPLUNK_ISSUERS\":\"${ISSUER_URI}\"}}"

kubectl get configmap "${AISERVICE}-saia-config" -n "$NS" \
  -o jsonpath='{.data.SPLUNK_ISSUERS}{"\n"}'
```

Recreate the SAIA pods and wait for their replacements to become ready:

```bash
kubectl delete pod -n "$NS" -l "app=$AISERVICE"
kubectl wait -n "$NS" --for=condition=Ready pod \
  -l "app=$AISERVICE" --timeout=10m
```

Record this ConfigMap override. Reapply it if the `AIService` or ConfigMap is
deleted and recreated.

## Step 3 - Publish SAIA over HTTPS

### What the customer should do

Place a TLS-terminating load balancer, ingress, or reverse proxy in front of the
SAIA service. The certificate must be trusted by customer browsers. Preserve
streaming responses and allow the exact `SPLUNK_WEB_ORIGIN` when CORS
configuration is required.

### File or resource to edit

- For a k0s installer deployment, edit
  [`k0s-cluster-config.yaml`](k0s-cluster-config.yaml).
- Edit the customer's load-balancer, ingress, reverse-proxy, DNS, certificate,
  firewall, and CORS configuration as required.

To expose SAIA through a NodePort, use:

```yaml
aiPlatform:
  serviceTemplate:
    type: NodePort
    nodePort: 30080
```

Apply the configuration through the normal installer workflow, for example:

```bash
CONFIG_FILE=./k0s-cluster-config.yaml ./k0s_cluster_with_stack.sh install
```

### Values to provide

| Value | Requirement |
|---|---|
| SAIA service | `${AISERVICE}-saia-service`, normally port `8080` |
| HTTPS URL | Stable `SAIA_URL`, normally on port `443` |
| Certificate | Covers the SAIA hostname and is trusted by the browser |
| Allowed origin | Exact `SPLUNK_WEB_ORIGIN` |

Verify the service and HTTPS endpoint:

```bash
kubectl get service "${AISERVICE}-saia-service" -n "$NS" -o wide
curl --fail --show-error "${SAIA_URL%/}/health"
```

## Step 4 - Configure Splunk AI Assistant

### What the customer should do

Open **Splunk AI Assistant > Configuration**, enter the SAIA URL, and save it.

### File or resource to edit

Use the Splunk AI Assistant setup page. No application file is edited directly.

### Value to provide

```text
https://saia.example.com
```

If Splunk Web uses HTTPS, the SAIA URL must also use HTTPS.

## Step 5 - Test the integration

1. Sign out of Splunk Web and sign back in to obtain a fresh JWT.
2. Open `${SAIA_URL}/health` from the same browser and network used for Splunk
   Web. It must load without a certificate warning.
3. Open Splunk AI Assistant and submit a test prompt.
4. Confirm that the request returns successfully and that the browser shows no
   mixed-content or CORS error.
5. Check the SAIA logs for authentication errors:

    ```bash
    kubectl logs -n "$NS" -l "app=$AISERVICE" \
      --all-containers --prefix --tail=100
    ```

## If testing fails

| Error | Likely cause | What the customer should check |
|---|---|---|
| `Unable to load keys for signing interactive JWT` | Missing stanza, unreadable PEM, or wrong password | Check `authentication.conf`, PEM permissions, and the effective settings with `btool --debug`; then restart Splunk |
| JWKS request times out or is refused | DNS, routing, firewall, or port `8089` is blocked | Test from the SAIA pod and allow the cluster to reach the Splunk management endpoint |
| JWKS certificate verification fails | Untrusted CA, expired certificate, or hostname mismatch | Install the correct certificate chain and use a matching FQDN |
| `Issuer '...' is not allowed` | `SPLUNK_ISSUERS` differs from the JWT `iss` claim | Make `authentication.conf` and the SAIA ConfigMap match exactly, then recreate the SAIA pods |
| `401 Unauthorized` | Issuer/JWKS failure, stale token, clock skew, or old pod environment | Check SAIA logs and system clocks, then sign out and back in |
| Config change has no effect | Splunk was restarted as the wrong OS user | Restart with the account that runs `splunkd` and confirm the process restarted |
| Browser reports `blocked:mixed-content` | Splunk Web is HTTPS but SAIA is HTTP | Publish SAIA over HTTPS and update the app URL |
| Browser reports a CORS error | The proxy does not allow `SPLUNK_WEB_ORIGIN` | Allow the exact Splunk Web origin and preserve CORS headers |
| Proxy returns `502` or `504` | Wrong backend service/port, unhealthy SAIA, or short proxy timeouts | Route to `${AISERVICE}-saia-service:8080` and enable suitable streaming timeouts |

Useful diagnostic commands:

```bash
sudo -H -u "$SPLUNK_RUN_USER" \
  "$SPLUNK_HOME/bin/splunk" btool authentication list oauth2_settings --debug

grep -E "Unable to load keys|oauth2|JWT|signing" \
  $SPLUNK_HOME/var/log/splunk/splunkd.log | tail -50

kubectl get configmap,pod,service -n "$NS" | grep "$AISERVICE"
kubectl describe pods -n "$NS" -l "app=$AISERVICE"
```
