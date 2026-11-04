# Troubleshooting: FIPS-mode Traefik and external Splunk test

This guide records issues encountered while validating the on-prem reference setup on 2026-11-02. It applies to the same flow as [the customer setup guide](fips-traefik-customer-setup.md).

## 1. SAIA returns 401: interactive token rejected by Splunk

**Observed:** A fresh JWT had the expected issuer, and SAIA verified its signature, but SAIA returned HTTP 401 with “Interactive token rejected by Splunk.”

**Cause:** SAIA validates an interactive token in two steps after checking the issuer allowlist:

1. Fetch signing keys from ISSUER/services/authorization/tokens-keys.
2. Call ISSUER/services/authentication/current-context to confirm the token is active.

The initial proxy routed JWKS but omitted current-context. Signature verification succeeded, but Splunk could not confirm the token.

**Fix:** Route both GET paths through the private Traefik HTTP listener. Keep the routes exact; do not proxy the whole Splunk management API.

~~~yaml
splunk-jwks:
  rule: Method("GET") && Path("/services/authorization/tokens-keys")
  entryPoints: [jwks]
  service: splunk-jwks

splunk-current-context:
  rule: Method("GET") && Path("/services/authentication/current-context")
  entryPoints: [jwks]
  service: splunk-jwks
~~~

Confirm the external Splunk issuer in authentication.conf and AIPlatform trustedIssuers match exactly, including scheme, host, and port.

## 2. SAIA/Slim cannot fetch signing keys

**Symptoms:** Connection timeout, “Failed to fetch JWKS from issuer,” or HTTP 401.

Check:

- Splunk management port 8089 accepts traffic from the Traefik security group.
- Traefik private port 8080 accepts traffic from the k0s node security group.
- The AIPlatform trusted issuer is the private proxy URL, not the Splunk host URL.
- The router forwards the exact JWKS path and query string to Splunk.
- The Splunk upstream uses HTTPS, a trusted CA bundle, and a SAN matching the configured hostname/IP.
- No direct k0s-to-Splunk 8089 rule remains.

After the proxy passed, the direct k0s security-group rule to 8089 was removed and direct socket access from SAIA was confirmed blocked.

## 3. TLS verification fails for Splunk upstream

**Observed:** TLS verification failed against the default Splunk certificate.

**Cause:** The default test certificate was signed by a private Splunk CA and had no Subject Alternative Name. Trusting the CA alone does not fix a missing or mismatched SAN.

**Fix:** Install a customer-issued Splunk management certificate with the private DNS name or IP in its SAN. Configure the CA in Traefik's serversTransport rootCAs and set serverName to the certificate name. Keep verification enabled.

Do not use curl -k, insecureSkipVerify, or a host-only certificate as the customer solution. The in-house test used a temporary CA-signed certificate with the Splunk private IP in its SAN.

## 4. Token issuer is not allowed or JWT issuer does not match

Check the exact values in:

- Splunk authentication.conf, stanza oauth2_settings, setting issuer_uri.
- AIPlatform spec.splunkConfiguration.trustedIssuers.
- SAIA and Slim SPLUNK_ISSUERS ConfigMaps and effective pod environment.

For the proxy topology, the tested value was the private HTTP URL on Traefik port 8080. Updating AIPlatform should trigger operator reconciliation and a pod rollout. Do not edit only the owned ConfigMaps; the operator recomputes SPLUNK_ISSUERS.

## 5. Traefik container repeatedly restarts with “permission denied”

**Observed:** After recreating the test container, Traefik could not read /etc/traefik/traefik.yml.

**Cause:** The read-only config and key files were owned by root:3001. The recreated container ran as appuser but omitted the supplemental group.

**Fix:** Preserve owner/group access when recreating the container. In this test, adding --group-add 3001 restored access. Confirm the actual group ID and file modes on the customer host; do not make private keys world-readable.

Keep the existing least-privilege settings:

- --cap-drop ALL
- --cap-add NET_BIND_SERVICE
- --security-opt no-new-privileges:true
- --user appuser

## 6. Private JWKS listener does not respond

Check:

- Traefik's static configuration defines the jwks entrypoint on port 8080.
- Docker publishes it bound to the gateway's private IP, not all public interfaces.
- The gateway security group allows 8080 only from the k0s node security group.
- The dynamic file provider has loaded both GET routers.
- The Splunk service has a verified HTTPS transport and reaches port 8089.
- From an SAIA pod, request http://<TRAEFIK_PRIVATE_FQDN>:8080/services/authorization/tokens-keys?output_mode=json. Expected status is 200.

A 200 from the Traefik host alone does not prove the pod path. Test from an SAIA/Slim pod too.

## 7. Public ingress endpoint cannot be reached

Check:

1. Traefik container is running and publishes port 443.
2. The gateway security group includes the current client source CIDR.
3. The FQDN resolves to the gateway public address and the certificate SAN covers that FQDN.
4. Host firewall and upstream network ACLs allow TCP 443.
5. Test from the customer's workstation with the customer CA bundle.

The automation runner could not connect to the public gateway IP, but the customer's laptop subsequently connected successfully. Its test CA and IP SAN verified, TLS 1.3 negotiated, and `/health` returned HTTP 200 over HTTP/2. This confirms reachability from that client network; repeat the check from each customer network and use customer-issued certificates outside the test.

## 8. Splunk reports “Unable to load keys for signing interactive JWT”

Check [oauth2_settings] in authentication.conf, including issuer_uri, certFile, and sslPassword. The token-signing certificate configured there is distinct from the Splunk management TLS certificate in server.conf. Restart Splunk after changes and confirm the JWKS endpoint returns HTTP 200.

Do not disable Splunk management TLS to work around certificate problems. Splunk documents management TLS as enabled by default and warns against running the management port without TLS.

## 9. Splunk container restarts after an HEC-token 401 or remains unhealthy

Separate a Splunk bootstrap failure from a Docker health-check failure; they can happen together but have different causes.

- If container logs show the Ansible task **Get existing HEC token** failing with HTTP 401 Unauthorized, the `SPLUNK_PASSWORD` configured for container startup does not match the current Splunk admin password. Confirm the current password with an interactive HTTPS request to the management API, then update the startup secret to that same value. Do not print the secret, put it in shell history, or paste it into a ticket. Recreate the container only if needed to change its environment; preserve the exact image digest, port bindings, bind mounts, and named volumes. Keep the old container and volumes until the replacement passes startup and login checks.
- If the health-check log says it cannot read `splunk-launch.conf` or write Splunk logs as user `ansible`, inspect the file owner/group/mode and the effective UID/GIDs. The image may restore files to the `splunk` UID/GID on startup. Give the health-check user the Splunk group as a supplementary container group, using the GID verified inside that image, rather than recursively changing ownership or making the files world-writable. In the in-house test the verified Splunk GID was `41812`.
- After recovery, verify the Ansible play recap has `failed=0`, the HEC-token task completes without 401, `splunk status` reports running, and Docker health reaches `healthy`. An immediate `health=starting` during the configured start period is expected; repeated restarts or an unhealthy state after initialization are not.

Do not delete or recreate named data volumes to resolve authentication or health-check issues. For TLS validation, verify CA and SAN explicitly; a `curl -k` response is not certificate validation.

## 10. SAIA service connection test fails

For Splunk AI Assistant 2.3.6, enter the service base URL without a trailing slash. Its setup test appends `/health` directly to the configured value. For example, enter `https://<TRAEFIK_FQDN>` so the request is `https://<TRAEFIK_FQDN>/health`; a trailing slash can produce `//health`.

The test runs from the Splunk instance and validates TLS using the Splunk runtime's trust store. A successful laptop `curl --cacert ...` proves only that the laptop trusts the certificate. If the slash is corrected and the test still fails, check the SAIA app logs for the HTTP/TLS exception and install the appropriate CA in the Splunk runtime trust configuration; do not disable certificate verification.

## 11. AITK endpoint returns 403

Check the test user's assigned Splunk roles. The in-house test required role_mltk_admin for AITK endpoints. Grant only the role and capabilities required by the customer's authorization policy.

## 12. SAIA settings page fails because Splunk KV Store is unavailable

**Symptoms:** The SAIA page does not load. Its app configuration endpoint returns HTTP 500 and the `saia_settings_v2` collection endpoint returns HTTP 503. `splunk show kvstore-status --verbose` reports `failed` or `ReplicaSetNoPrimary`, and the local KV Store port 8191 refuses connections.

**Cause:** In the in-house Splunk 10.2.8 setup, KV Store's MongoDB process used the custom Splunk management certificate for its TLS client connection as well as its server connection. The management certificate was valid for server authentication but not client authentication (`SSL client: No`). MongoDB rejected the peer certificate with `unsuitable certificate purpose`. The Splunkd log then reported that KV Store did not become ready before its approximately five-minute startup timeout and stopped MongoDB. The management certificate SAN also named the Splunk private IP, while the local KV Store connection targeted `127.0.0.1`; this caused a hostname mismatch warning.

**Fix used in the test:** Keep the Splunk management certificate and its global `[sslConfig]` setting unchanged. Configure a separate KV Store client PEM containing the test CA-signed certificate and encrypted private key. The certificate has both `clientAuth` and `serverAuth` EKUs. In `server.conf`, use the dedicated client stanza:

~~~ini
[kvstoreSslClientConfig]
clientCert = $SPLUNK_HOME/etc/auth/kvstore-client.pem
sslPassword = <Splunk-encrypted value of the PEM key passphrase>
sslVerifyServerCert = true
sslVerifyServerName = false
~~~

The test kept CA-chain verification enabled. `sslVerifyServerName = false` was needed because the existing management certificate did not name the loopback address used by local KV Store. For customer deployments, prefer a KV Store server certificate whose SAN matches the KV Store connection name and keep hostname verification enabled. The test setting does not disable TLS, but it does skip hostname matching for this local KV Store connection. Splunk documents the separate `[kvstoreSslClientConfig]` stanza in the [Splunk 10.2.8 server.conf reference](https://help.splunk.com/en/data-management/splunk-enterprise-admin-manual/10.2/configuration-file-reference/10.2.8-configuration-file-reference/server.conf) and the KV Store certificate purpose requirements in [Preparing custom certificates for use with KV store](https://help.splunk.com/en/splunk-enterprise/administer/admin-manual/10.4/administer-the-app-key-value-store/preparing-custom-certificates-for-use-with-kv-store).

**Diagnosis and recovery:**

1. Check the effective KV Store client settings without printing `sslPassword`:

   ~~~bash
   $SPLUNK_HOME/bin/splunk btool server list kvstoreSslClientConfig | \
     grep -E 'clientCert|sslVerifyServerCert|sslVerifyServerName'
   ~~~

2. Check the configured certificate's EKUs and CA chain. The client certificate must be accepted for client authentication, and the CA bundle must contain its issuer chain:

   ~~~bash
   $SPLUNK_HOME/bin/splunk cmd openssl x509 -noout -purpose -in <KVSTORE_CLIENT_CERT>
   $SPLUNK_HOME/bin/splunk cmd openssl verify -verbose -x509_strict \
     -CAfile <SSL_ROOT_CA_BUNDLE> <KVSTORE_CLIENT_CERT>
   ~~~

3. Review `splunkd.log` for `KVStoreConfigurationProvider`, startup timeout, and `KVStore changed status to failed` messages. Review `mongod.log` for `unsuitable certificate purpose`, TLS handshake errors, or certificate-name mismatches. Do not infer that a healthy Splunk container means KV Store is ready.

4. After updating the KV Store client certificate and stanza, restart Splunk and wait for initialization to finish. Check `splunk show kvstore-status --verbose`; the expected status is `ready` and replication status is `KV store captain` for a standalone instance.

5. Verify the SAIA app configuration and collection endpoints. Include the app source header when calling the config endpoint directly; without it, the endpoint returns HTTP 400 `Missing required source-app-id header`.

   ~~~bash
   curl --cacert <SPLUNK_CA_BUNDLE> -u admin \
     -H 'Source-App-ID: Splunk_AI_Assistant_Cloud' \
     'https://<SPLUNK_HOST>:8089/servicesNS/-/Splunk_AI_Assistant_Cloud/config?output_mode=json'

   curl --cacert <SPLUNK_CA_BUNDLE> -u admin \
     'https://<SPLUNK_HOST>:8089/servicesNS/nobody/Splunk_AI_Assistant_Cloud/storage/collections/data/saia_settings_v2?output_mode=json'
   ~~~

   Both returned HTTP 200 after recovery in the in-house test. `curl -u admin` prompts for the password; do not place credentials in command arguments or paste them into logs.

Do not run `splunk clean kvstore`, delete KV Store data, or remove Docker volumes to address this certificate failure. Keep TLS and CA-chain verification enabled. A KV Store certificate/hostname issue is separate from the AI-Tier in-cluster HTTP paths and from TLS termination at the Traefik ingress.

## 13. SAIA chat history requests fail in Chrome with CORS or network errors

**Observed:** Splunk AI Assistant displayed “Failed to load the chat history.” Chrome 156 reported `Cross-Origin Resource Sharing error: InsecureLocalNetwork` for calls from `http://3.16.83.158:8000` to `https://10.0.39.247/tenant-id-sok/saia-api-v2/...`. Traefik access logs contained no matching browser requests, so Chrome blocked them before they reached the gateway. The SAIA service connection test from Splunk succeeded, but that test runs on the Splunk host and does not prove that the user's browser can reach the service.

**CORS route fix:** Add a higher-priority Traefik router for `/tenant-id-sok/saia-api-v2` and attach a headers middleware with the exact Splunk Web origin, required API methods and request headers, credentials enabled, and `Vary: Origin`. Do not use `*` with credentials. The in-house test returned HTTP 200 to the OPTIONS preflight with the expected `Access-Control-Allow-Origin`, methods, headers, and credentials. An unauthenticated metadata GET returned HTTP 403 but included the expected CORS headers; this confirmed CORS routing, not authenticated SAIA behavior.

The test route file was bind-mounted as a single file. Replacing the host file atomically did not update the inode already mounted in the running container, so the old catch-all router continued serving requests. Recreate the container to load the replacement file and preserve the original runtime settings, including `--group-add 3001`; the root-owned config and private key files are group-readable, not world-readable. Confirm the access log reports `saia-api-cors@file` for both OPTIONS and API requests.

**TLS trust:** The current gateway certificate was issued by `MPR70 Splunk Test CA`. The file `/etc/traefik/certs/ca.crt` contained a different, older test CA and failed chain verification. `/etc/traefik/certs/splunk-test-ca.crt` validated the current gateway certificate. Use the CA that actually issued the listener certificate; keep certificate and hostname/IP validation enabled. The customer's browser must also trust the listener CA.

**Fix for the in-house test:** Keep the CORS middleware and use the certificate-covered URL `https://saia-test.mpr70.test` in the SAIA setup. Split name resolution: the laptop must resolve this name to the public Traefik address `3.137.217.99`; the Splunk container must resolve it to the private address `10.0.39.247`. The Splunk container was configured for the private mapping, and its Requests CA bundle was updated with the issuer `MPR70 Splunk Test CA`; an HTTPS `/health` request from Splunk then returned HTTP 200. The laptop still needs the public mapping and must trust this test CA in its browser keychain. For customer deployments, use customer DNS and certificates rather than the temporary `.test` hostname and CA.

Chrome's Local Network Access rules distinguish requests to private-network addresses from public endpoints. CORS headers cannot override a browser `InsecureLocalNetwork` block. For direct browser access to a private address, use a secure initiating context and follow Chrome's local-network permission prompt. For this test, the split-horizon hostname lets the browser connect to the public gateway while Splunk uses its private route. See [Chrome's Local Network Access guide](https://developer.chrome.google.cn/docs/modern-web-guidance/guides/security/local-network-access?hl=en). Do not rely on deprecated Private Network Access preflight headers as a workaround.

**Fix and verification:** The SAIA URL was changed to `https://saia-test.mpr70.test`. Split name resolution maps that hostname to public gateway `3.137.217.99` on the laptop and private gateway `10.0.39.247` in the Splunk container. The laptop's `/etc/hosts` mapping and test CA trust were completed by the user after local authorization was needed. From the laptop, `curl https://saia-test.mpr70.test/health` validated the certificate name and CA, negotiated TLS 1.3, and returned HTTP 200. In Chrome 156, both preflight OPTIONS and actual GET requests to `/tenant-id-sok/saia-api-v2/v2alpha1/conversations/` and `/metadata?version=2.3.6` returned HTTP 200; the chat-history list loaded and the warning disappeared. This confirms the browser CORS path for those endpoints.

**Separate API result:** The preflight for `/tenant-id-sok/saia-api-v2/v2alpha1/memory/settings` returned HTTP 200, but the actual GET returned HTTP 404. This is not a CORS rejection; investigate it separately only if the memory settings feature is required. Do not reopen the CORS fix based on this 404.

**Conversation ID lookup failure:** Follow-up browser captures on 2026-11-03 show history requests are not being blocked by CORS. Chrome received HTTP 404 for conversation IDs `7caf07453bfc483783ce789e3a00177a` and `62fc0336538642eca75ad34270f9fad1`; the response included `Access-Control-Allow-Origin: http://3.16.83.158:8000` and JSON content from the gateway. SAIA API logs show `/items` returned `Conversation <id> not found`, while other conversation IDs returned HTTP 200. For the `62fc...` query, the API created canonical ID `62fc...` from draft ID `draft:3d1065e6-097b-487c-a5b2-cffff32006f0`, then raised tool-approval interrupts. The live API pod's `persist_turn_result()` deletes the empty placeholder when `pending_action_response` is set. The resumed request still uses the deleted ID; persistence later creates a replacement ID, while the browser requests history using the old ID and gets 404. This is an SAIA backend persistence lifecycle bug, independent of CORS, Traefik, S3 bucket selection, and external Splunk.

**Fix deployed:** The SAIA service source already contains the correction: keep the placeholder when a tool approval is pending. Regression test `test_pending_tool_approval_retains_preflight_conversation_for_resume` is present in source commit `09d78c9273ea7b954256b529873163146758077e`. Successful pipeline `43133518` published SAIA v2 image `docker.repo.splunkdev.net/ml-platform/saia/saia-api-v2:v2.3.16-2-g09d78c9`, source digest `sha256:de01cbf7cfa5e6abf0009d03ed7d43aa49856a7e8becc2b0c6c61411d8b2c1e2`. The image was mirrored to the cluster-local registry as `10.0.39.248:5000/splunk/ai-tier-saia-api-v2@sha256:b16c758beac8a203961fe34bc60b71f017cca2c00da48202aeea1e0cd93f01d5`; its config digest remains `sha256:cc8d4ecfff8b2cac0e1c61c3a735cd2b06a9af568c57a79787fd1658294b44e8` and platform is `linux/amd64`. The operator's `RELATED_IMAGE_SAIA_API_V2` setting was updated and the parent AIPlatform reconciliation was triggered because it owns and regenerates the AIService. The AIService now pins the mirrored digest; both v2 API and worker pods are Ready with zero restarts, and runtime inspection confirms the pending-approval branch retains its placeholder. The prior digest `sha256:f18fbbf8d2b338508c8d863c6d74031da69c24ef14eed9da41faeee24172ac8b` remains the rollback image. The affected old conversation ID was already deleted and cannot be restored by this fix; validate with a new chat and an approval-resume. Do not downgrade Splunk AI Assistant app 2.3.6 or delete S3 records.

**Search tool HTTP 404 — confirmed route mismatch:** SAIA API logs for query request `0c52ec98-7c80-4968-a322-1bc910330518` show that the API received the query and resolved its Splunk REST target to `http://10.0.39.247:8080`, the gateway's private HTTP listener. Calls to `/services/data/indexes`, `/servicesNS/-/-/saved/searches`, and `/servicesNS/-/-/data/ui/views` returned `HTTP 404 Not Found -- 404 page not found`; the search guardrail then denied the query. These are gateway route misses, not failures at Splunk's own REST service.

The live Traefik dynamic configuration confirms that the private `jwks` entrypoint on port 8080 has only two routes: GET `/services/authorization/tokens-keys` and GET `/services/authentication/current-context`. Both use an upstream service at `https://10.0.39.253:8089`, with the test CA and `serverName: 10.0.39.253` configured for certificate verification. The gateway security group permits port 8080 only from the k0s worker security group. Keep this private listener and verified HTTPS upstream; do not disable TLS or expose the management API publicly.

**Fix for the current read-only `splunk_search` path (applied 2026-11-03):** Added method- and path-constrained routers on the private `jwks` entrypoint, using the existing verified HTTPS Splunk management service, for GET `/services/data/indexes`, GET `/servicesNS/-/-/saved/searches`, GET `/servicesNS/-/-/data/ui/views`, and POST `/services/search/jobs/export`. The route file was backed up outside the watched directory and edited in place to preserve its bind-mounted inode. After the SAIA image rollout, an unauthenticated GET from the live API pod to `/services/data/indexes` returned HTTP 401 with `Server: Splunkd`, not Traefik's 404; this confirms the path reaches Splunk but does not verify an authenticated search. The existing Authorization header and query string are forwarded. No generic `/services/*` proxy was added. The Traefik container was not restarted; `GODEBUG=fips140=only`, the HTTPS upstream with CA/name verification, and the private port-8080 security-group boundary were unchanged. An authenticated `splunk_search` request still needs the user to approve the pending tool action in Splunk AI Assistant. Other enabled tools need their own path/method review before adding routes (for example, asynchronous search job status/results/cancel and saved-search creation).

**Follow-up search 404 fix (applied 2026-11-03):** The later `splunk_search` failure was correlated with Traefik access logs at 12:58:09 UTC: the API's Splunk client requested GET `/services/server/info`, which returned Traefik's 404 because the exact route had not been allowlisted. Added a method- and path-constrained GET `/services/server/info` router to the same private `jwks` entrypoint and existing `splunk-jwks` service. The route file was backed up to `/var/tmp/mpr70-routes.yml.pre-server-info-20261103T132210Z` and edited in place so the file provider could reload it. An unauthenticated request now returns Splunk's XML HTTP 401; Traefik access logs identify `splunk-server-info@file` and upstream `https://10.0.39.253:8089`. A POST probe to `/services/search/jobs/export` also returns Splunk's XML HTTP 401 through `splunk-search-export@file`. These results verify that both paths reach the verified TLS upstream and no longer hit Traefik's 404 handler. The authenticated SAIA search has not yet been rerun after this correction; keep the pending tool approval enabled and verify with a new chat.

**Internal-versus-external Splunk comparison:** On this same k0s stack, SAIA had previously connected directly to internal Splunk. `index=* | stats count by host` returned no external events over seven days, but internal-index metadata was available. With external Splunk behind Traefik, the live API logs showed the target resolving to `http://10.0.39.247:8080`; before the route change, required metadata paths received Traefik's plain 404 because the private listener only had JWKS and current-context routes. The constrained routes now reach the verified HTTPS Splunk management service, isolating the former search failure to the external proxy allowlist, not a cluster or FIPS-mode change. The assistant response also displayed internal tool-debugging narration; track that separately as an application output defect, not a CORS or routing symptom. Keep bearer tokens and cookies redacted in future evidence.

## 14. SAIA remains on “Running Write SPL” and emits no search callback

**Observed:** On 2026-11-03, Chrome showed the UF question stuck at `Thinking...` / `Running Write SPL`, with malformed activity text. The browser's OPTIONS preflight to `/tenant-id-sok/saia-api-v2/v2alpha1/query` returned HTTP 200 with `Access-Control-Allow-Origin: http://3.16.83.158:8000`, credentials enabled, and the required headers and methods allowed. This verifies the preflight only; it does not prove that the POST or server-side writer completed.

**Live configuration and callback flags (verified 2026-11-03):** Ran `splunk btool splunkaiassistant list --debug` on the external Splunk EC2 host (not the K0s node). The effective app config is `saia_sok_enabled = true` and `saia_sok_url = https://saia-test.mpr70.test`. Recent SAIA API logs for requests `5b8e919f-3997-4f39-b99e-8b902b384c93` and `5212ae74-3cbf-498c-956f-2297b6004bb1` show `execution_tools_enabled: true` and `auto_execute_tools: false`. The earlier hypothesis that disabled Agent Mode/SOK settings caused these missing callbacks is disproven for these requests. Keep auto-execution disabled and preserve the approval flow.

**Backend change behind the behavior difference:** Deployed SAIA source commit [`09d78c92`](https://cd.splunkdev.net/sparta/aie/saia-service/-/commit/09d78c9273ea7b954256b529873163146758077e), dated 2026-10-29, changed `SplunkTransport.RELAY` to honor `execution_tools_enabled`. Before that change, relay requests always made execution tools available, even when the app sent false. The deployed `resolve_execution_tools_available()` now returns false for this request, so `splunk_search` is not offered. This is consistent with the observed missing callback. It does not explain the malformed writer text by itself.

**Eligibility checks confirmed from the 2.3.6 app bundle:** Agent Mode requires Splunk `10.1` or later; this test's configured Splunk `10.2-rhel9` image meets that version check, so an older Splunk version is not the likely cause. The effective toggle also requires a ready tenant context and a supported SAIA metadata endpoint. The packaged `default/splunkaiassistant.conf` has `saia_sok_enabled=false`; therefore confirm the live app configuration actually enables SOK and supplies the intended SAIA URL before treating this as an AI-Tier/SOK deployment. A request path containing `tenant-id-sok` confirms the tenant route used by that request, but by itself does not prove the SOK-enabled configuration flag or metadata capability check succeeded.

**Cause of the current no-callback/junk responses:** Requests `5b8e919f-3997-4f39-b99e-8b902b384c93` and `5212ae74-3cbf-498c-956f-2297b6004bb1` reached SAIA (HTTP 200), enabled execution tools, and started `write_spl`. In both, model `gemma4_31b_it` raised `LengthFinishReasonError`; the traces then show `write_spl` failed and no `splunk_search` call followed. Retrieval tools later completed, but they do not replace the failed SPL generation. The deployed source at commit [`09d78c92`](https://cd.splunkdev.net/sparta/aie/saia-service/-/commit/09d78c9273ea7b954256b529873163146758077e) confirms that `invoke_write_spl_agent()` replays only recognized transient HTTP 500 failures, not model output-length failures. This is the direct explanation for those stuck/junk responses. The logs do not include the model token ceiling or response usage, so they do not establish whether the remedy is a larger generation limit, a shorter writer context, or a model/provider change; do not change a limit blindly.

**Separate search-route failure:** Request `763c435e-88c4-4dbc-a173-c94958c040a1` reached `splunk_search` but logged `splunk_search_guardrail_denied` with `Validation error: HTTP 404 Not Found` and `failure_reason: export_error`. This request predates the constrained `/services/search/jobs/export` route correction recorded above. The route was subsequently verified to reach Splunk and return Splunk's HTTP 401 when unauthenticated, but an authenticated search has not yet been confirmed after that correction. Treat the 404 as the cause for that older failed search only; a fresh request is needed to validate the corrected route.

**Additional search API route gaps (2026-11-04 local / 2026-11-03 UTC):** Live Traefik access logs showed POST `/servicesNS/nobody/system/search/v2/parser` returning Traefik's 19-byte HTTP 404 with no router and no upstream. SAIA request `84f3c308-09ca-4609-ae49-4067c12a603f` logged `splunk_search` failure (`failure_reason: export_error`) at the same time. A narrow POST router for this exact path was added to the private `jwks` entrypoint, using the existing `splunk-jwks` service and its verified HTTPS upstream. The next SAIA request reached the parser (HTTP 200 from Splunk), then exposed a second gap: POST `/servicesNS/nobody/system/search/v2/jobs/` also returned Traefik's immediate 404 with no router or upstream. That coincided with `splunk_search` failure `export_error` for request `385e6598-0f97-4b91-a531-eac1cd18f1cc`. A second exact POST router was added for this job-creation path. Backups are `/var/tmp/mpr70-routes.yml.pre-search-parser-20261103T183135Z` and `/var/tmp/mpr70-routes.yml.pre-search-jobs-create-20261103T183829Z`. The file provider reloaded the changes without restarting Traefik. Afterward, the parser returned HTTP 200 through router `splunk-search-parser@file`; an unauthenticated POST to the job-creation route returned HTTP 401 with `Server: Splunkd`, confirming the request reached Splunk instead of Traefik. Both routes remain method- and path-constrained on the private listener; upstream TLS verification, `GODEBUG=fips140=only`, and the security-group boundary were unchanged. An authenticated end-to-end search after the second route addition is still needed; inspect the next exact request path if it fails rather than broadening the proxy.

**Log collection pitfall (2026-11-03):** The first `kubectl logs` filter included generic `request_id` and `exception` fields, which appear on routine health-check records (including `exception: null`). `tail -n 100` then retained health checks and startup messages rather than the older SAIA request trace. Filter by exact request ID and extract only event names, levels, model/error type, and approved scalar metadata; avoid printing prompts, tool arguments, bearer tokens, or cookies. The pasted `docker: command not found` occurred because `docker exec` was run on the K0s VM. The same `btool` check was run successfully on the external Splunk EC2 host and confirmed SOK enabled with the intended URL.

**Fresh request after route correction (2026-11-03):** Request `881da2c5-4d20-4352-8287-934655dd781c` was received by SAIA with `execution_tools_enabled: true` and `auto_execute_tools: false`; Splunk token-key and current-context checks returned HTTP 200. The query endpoint accepted it (HTTP 200), and the API logged `write_spl` starting. The Gemma chat-completions calls returned HTTP 200, but the trace currently has no terminal `write_spl` event and no `splunk_search` event. Therefore this attempt still does not verify the export route or a completed answer. A separate Weaviate HEAD check for `SAIAAdminKnowledge/tenants/tenant-id-sok` returned 404; its relationship to the writer failure is unproven. Do not infer success from the initial HTTP 200.

**Current status and next action:** The private Splunk route misses observed earlier have narrow method/path routers and route-level evidence that they reach Splunk through the verified HTTPS upstream. However, an authenticated end-to-end search and result callback after the final route addition have not been verified. One browser attempt failed with `ERR_NETWORK_CHANGED` / `ERR_INTERNET_DISCONNECTED`; after the user confirmed network stability, callbacks resumed but the assistant streamed troubleshooting narration and search results remained incomplete or errored. The next diagnostic is to match the exact 404 from the search tool output to a Traefik access-log path/router/upstream; do not add another route until that match exists. Earlier `write_spl` `LengthFinishReasonError` and `unknown_tool` events are separate writer-stage failures, not evidence of a Traefik route miss. Keep `auto_execute_tools=false`, do not change SAIA service code, and preserve the verified TLS/CORS configuration.
**Search v2 result-preview and control routes (applied 2026-11-04 local / 2026-11-03 UTC):** The next `splunk_search` attempt reached parser and job creation, but POST `/servicesNS/nobody/system/search/v2/jobs/{sid}/results_preview` and POST `/servicesNS/nobody/system/search/v2/jobs/{sid}/control` returned Traefik's 19-byte 404 with no router or upstream. Added two exact `PathRegexp` POST routers for numeric Splunk search IDs on the existing private `jwks` entrypoint, forwarding to the existing `splunk-jwks` service (`https://10.0.39.253:8089`). Backup: `/var/tmp/mpr70-routes.yml.pre-v2-job-results-control-20261103T191619Z`. The file provider reloaded the config without restarting Traefik. Unauthenticated probes to both paths through `10.0.39.247:8080` returned HTTP 401 from Splunk; access logs identify `splunk-search-v2-job-results-preview@file` and `splunk-search-v2-job-control@file`, with the verified HTTPS upstream. This proves the routes no longer terminate at Traefik's 404 handler. A fresh chat request `7cdf5b81-70b4-4a93-96d1-b43c4f04b8f4` reached `write_spl` after the route update but had not reached `splunk_search` by 2026-11-03 19:20 UTC, so an authenticated end-to-end search is still unverified. Do not broaden the proxy; inspect the next exact path if a later request produces another route miss.

**Search v2 job-status route (applied 2026-11-04 local / 2026-11-03 UTC):** The first fresh query after adding the result-preview/control routers exposed one more narrow miss: GET `/servicesNS/nobody/system/search/v2/jobs/{sid}/` returned Traefik's 19-byte 404 with no router or upstream. Added a numeric-SID GET `PathRegexp` router on the same private `jwks` entrypoint; backup: `/var/tmp/mpr70-routes.yml.pre-v2-job-status-20261103T192530Z`. The file provider reloaded the route without a Traefik restart. An unauthenticated GET probe returned HTTP 401 through router `splunk-search-v2-job-status@file` from upstream `https://10.0.39.253:8089`, confirming the route now reaches Splunk. In the same fresh request, parser returned 200, job creation 201, results preview 200, and control 200; only the job-status GET was still a Traefik route miss. The query trace's `write_spl` stage took about 128 seconds and failed with `unknown_tool` before search execution; this delay is separate from Traefik, whose matched upstream calls completed in 3–5 ms. A post-status-route authenticated end-to-end search is still pending.

## 15. Browser query is stuck after the workstation network changes

**Observed in Chrome on 2026-11-04:** The Splunk AI Assistant page remained at `Thinking...` / `Running Write SPL` for “Which UFs are sending data to Splunk.” DevTools showed a fetch to `https://saia-test.mpr70.test/tenant-id-sok/saia-api-v2/v2alpha1/query` failing with `net::ERR_NETWORK_CHANGED`, followed by `net::ERR_INTERNET_DISCONNECTED` and `TypeError: network error`. The request was unavailable in the Network panel and no HTTP response status was shown. Chrome also displayed React prop/deprecation warnings; those are separate from the network error. This attempt is not the same symptom as a Traefik-generated HTTP 404, and does not establish an authenticated Splunk search result.

**Diagnosis:** The browser reports that its network changed or was disconnected while fetching the SAIA query endpoint. That points to a workstation/browser network-path interruption (for example, a VPN or interface route change), but the browser evidence alone does not identify which local network component changed. Do not label this as another Traefik route miss without a matching access-log entry and router/status.

**Recovery and evidence:** Once the workstation's network and VPN state are stable, confirm `saia-test.mpr70.test` resolves to the intended public Traefik address on the laptop, then check the HTTPS health endpoint with the test CA and hostname validation enabled. Retry one new assistant query and capture the browser request's HTTP status. Correlate its timestamp with the Traefik access log: no matching access entry plus the same browser network error indicates the fetch failed before the gateway; a Traefik 404 must include the exact method/path and no matching router; an upstream HTTP response indicates the request passed Traefik. Keep TLS verification enabled and do not change routes or SAIA service code based on this network error alone.

## 16. Assistant returns internal narration instead of a host/forwarder answer

**Observed after the workstation network was reported stable (2026-11-04):** The browser showed retrieval callbacks and repeated `splunk_search` calls, but the response consisted of internal troubleshooting narration and repeated query proposals. The user-provided tool summary reports that `write_spl` failed on its length limit and then the tool-call limit; `index=_internal | head 1` returned one event with host `6edb664e838d`; `index=_internal sourcetype=splunkd source=*splunkforwarder* | stats count by host` and `index=_internal group=tcpin_connections | stats count by hostname` returned zero results; `| metadata type=hosts` and `| tstats count where index=* by host` returned zero results with HTTP 404 errors.

**What this establishes:** The earlier browser network interruption is no longer sufficient to explain the current behavior because tool callbacks resumed after the user confirmed network stability. The current run did not produce a validated UF/host list. One event from `head 1` proves only that the search tool returned at least one `_internal` event; it does not identify all hosts. Zero-result forwarder searches do not prove that no forwarders are sending data, especially while the search tool reports 404 errors.

**Baseline reported by the user:** The same natural-language prompt, “Which hosts are sending data to Splunk,” previously returned a correct response when the same k0s cluster used internal Splunk without the external Traefik path. This makes the prompt wording an unlikely cause. The current comparison changes the Splunk target path: SAIA's Splunk REST/search traffic now goes through the private Traefik listener to external Splunk. The older successful conversation's exact SPL and tool outputs have not yet been independently extracted, so use this as a user-reported baseline and compare the two traces before attributing the regression to one route.

**Root cause found (2026-11-04):** Traefik access logs at 05:59:55, 06:00:13, and 06:02:11 UTC show `POST /servicesNS/nobody/system/search/v2/jobs/{numeric-sid}/results_preview` succeeding through `splunk-search-v2-job-results-preview@file` to `https://10.0.39.253:8089`, followed by `POST /servicesNS/nobody/system/search/v2/jobs/{numeric-sid}/results` returning 404 with router `-`, upstream `-`, and 0 ms duration. Splunk's access log had no corresponding 404 for those requests. This establishes a Traefik route miss before the request reached Splunk. The missing route was the final search-job result fetch; the existing preview route did not cover `/results`.

**Fix applied and route-level verification:** Added the exact `POST` rule for `/servicesNS/nobody/system/search/v2/jobs/[0-9]+\.[0-9]+/results` to the live `/etc/traefik/dynamic/routes.yml`, with priority 120, the existing `jwks` entrypoint, and the existing `splunk-jwks` service. A backup was saved as `/etc/traefik/dynamic/routes.yml.bak-20261104T071102Z`. The private listener is `jwks` on HTTP port 8080; the gateway-to-Splunk leg remains verified HTTPS on port 8089. An unauthenticated probe with dummy SID `123.0` returned HTTP 401 and Traefik logged router `splunk-search-v2-job-results@file`, upstream `https://10.0.39.253:8089`, 3 ms. This is the expected result for a request with no credentials and proves the rule forwarded to Splunk. A probe of the same management path on public HTTPS port 443 returned 404 through the `saia@file` catch-all; use the private port 8080 for these management/search routes.

**Latest browser trace after the route fix (2026-11-04, 07:39–07:48 UTC):** The browser remained at `Thinking… / Running Write SPL`. SAIA accepted the `/query` request with HTTP 200, validated the interactive token through the private Traefik listener, and completed `retrieve_spl_knowledge_base`. It then raised `tool_approval_required` for `splunk_search` with `index=_internal sourcetype=splunkd | stats count by host` (`earliest_time=-7d`, `latest_time=now`). The trace records `write_spl_attempted=false` and `splunk_search_count=0`; the Splunk search was never executed. The browser showed no approval control. The malformed text reported by the user is therefore not a search result and cannot identify hosts. A React warning naming `ToolApprovalModal` is present, but that warning alone does not establish the cause of the missing approval UI.

**2.3.6 client package inspection (2026-11-04):** The downloaded Splunk AI Assistant app package declares version `2.3.6`, build `abd0ce0`. Its JavaScript accepts `tool_approval_required` in either `payload.metadata` or `payload.data.metadata` and requires a nonempty `interrupt_id` or `interruptId`. The in-chat modal is wired only when Agent Mode is enabled, and opens only when a pending approval is parsed. The package's `default/splunkaiassistant.conf` contains no approval/modal setting. The recorded request had `execution_tools_enabled=true` and `auto_execute_tools=false`, so the manual-approval path should have been enabled. The package JavaScript hash matches the browser-captured bundle for that trace, but does not prove which bundle a later active tab has cached. This points to checking the exact `/query` event frame and UI state; it does not indicate a CORS or route miss.

**Current status and next check:** The specific Traefik 404 for the v2 search-job `/results` path is fixed at the routing layer. The latest run reached SAIA successfully but stopped at the `splunk_search` approval interrupt before any search request reached Splunk; that run does not exercise `/results`. Hard-reload Splunk Web, start one fresh chat, and inspect the `/query` SSE `data:` frame for the event name and nonempty interrupt ID (redact tokens and cookies). If the frame matches the 2.3.6 parser but the modal does not open, the unresolved issue is in client UI/state handling; if the event or ID is absent/malformed, the response serialization needs investigation. Do not make more Traefik changes based on the malformed text, and do not change SAIA service code without evidence and explicit scope. Do not treat diagnostic narration or failed/empty queries as evidence that no UFs are sending data.

## 17. Slim/AITK CORS preflight fails while SAIA preflight passes

**Observed before the fix (2026-11-04):** With the test CA and hostname verification enabled, the public health check returned HTTP 200 (`tls_verify=0`). An OPTIONS request to the SAIA conversation route using Origin `http://3.16.83.158:8000` returned HTTP 200 with that exact origin allowed. An OPTIONS request to `https://saia-test.mpr70.test/tenant/slim-api/v1alpha1/chat/models` returned HTTP 400 from Uvicorn: `Request ID not present in header`, with no CORS response headers. Traefik access logs showed the OPTIONS request forwarded through `slim@file` to `http://10.0.38.66:30081`.

**Root cause and live fix (2026-11-04):** The existing `saia-browser-cors` middleware was attached to the SAIA router but not the Slim router. The preflight therefore reached Slim, whose API requires a `request_id` header on every request. The test CORS policy was attached to the Slim router and its allowed-header list was extended with the documented `request_id` header. It continues to allow only the configured Splunk Web origin `http://3.16.83.158:8000`, credentials, and the listed methods/headers. No SAIA or Slim service code, backend TLS settings, certificates, security groups, or k0s workloads were changed. A backup was saved as `/etc/traefik/dynamic/routes.yml.bak-slim-cors-20261104T115039Z`.

The Traefik file provider had `watch: true`, but the dynamic file update did not become active until the test `mpr70-traefik` container was restarted at 11:59 UTC. This briefly interrupted ingress; the container returned to `running` and the public health check returned HTTP 200 with `tls_verify=0` afterward. The deployed test image reports ID `sha256:4f28c10d658239fc0ec335394e552ab77ce8d67d2680133d0ddb90f4c3302dac`, Traefik 3.6.14, Go 1.26.4, Linux/amd64, and `GODEBUG=fips140=only`. A fresh Docker inspection on 2026-11-04 confirmed the local tag `mpr70/traefik-fips:test-amd64` and an empty `RepoDigests` list. `traefik version` reported `Built: 2012-04-19_13:30:00`; the build owner must explain this timestamp and connect the running image to its source/build record. This runtime evidence does not substitute for registry digest/provenance or vendor FIPS validation evidence.

**Post-fix verification (2026-11-04 12:00 UTC):** An OPTIONS request to the Slim `chat/models` path with Origin `http://3.16.83.158:8000`, method GET, and requested headers `authorization,content-type,request_id,x-requested-with` returned HTTP 200. The response included the exact `Access-Control-Allow-Origin`, credentials enabled, the listed methods, and `Access-Control-Allow-Headers` including `request_id`; it did not reach Uvicorn. A GET to the same path with a valid `request_id` but no Authorization header returned HTTP 401 `Missing Bearer token` from Uvicorn, with the expected CORS response headers. That confirms routing to Slim and the browser CORS response, but it is not an authenticated AITK connection or model-list test.

**Authenticated AITK check (2026-11-04):** The user confirmed the Splunk AI Toolkit connection/model-list check succeeds after the Traefik CORS change. The exact UI action and DevTools response were not captured, so this is recorded as user-reported validation. Together with the preflight response, it closes the in-house Slim/AITK CORS connectivity issue for this test setup. If the issue recurs, capture `Access-Control-Request-Headers`, response status, and Traefik router/upstream from the same attempt; do not include tokens or cookies.

**Retained browser log caveat:** DevTools had Keep log enabled and showed 1,716 retained requests. Some SAIA `/v2alpha1/query` fetches returned HTTP 200 in 11–17 seconds (one in 3.86 seconds), while two Splunk Web `/services/messages` polls failed with `ERR_NETWORK_CHANGED` and `ERR_CONNECTION_TIMED_OUT`. A separate Splunk configuration GET for `conf-limits/structured_data_service` returned HTTP 404. The selected chat was an older “Which UFs are sending data to Splunk” conversation, so these retained requests cannot be correlated to the later `| metadata type=hosts` prompt or its reported search-tool 404. The direct Skynet Splunk metadata connector also remained unauthorized and did not execute a request. Do not use this retained log alone to claim that the metadata search succeeded or that its 404 was fixed.

## 18. AITK `ai` SPL fails TLS although the connection test succeeds

**Observed (2026-11-04):** The AITK connection/model-list check succeeded, but this inference search failed:

~~~spl
| makeresults
| ai prompt="Reply with exactly: AITK inference test passed" connection="gemma"
~~~

For SID `1793797801.622`, `mlspl.log` showed provider `AI Tier`, model `Gemma 4 31B`, and a POST to `/tenant/slim-api/v1alpha1/chat/completions`, followed by `httpcore.ConnectError: [SSL: CERTIFICATE_VERIFY_FAILED] ... unable to get local issuer certificate`. Slim's log for that minute had health and metrics traffic but no inference POST, so the TLS handshake failed on the Splunk host before Slim received an HTTP request. A later run, SID `1793800718.7`, exposed the cause: AITK logged that `SSL_CERT_FILE=/opt/splunk/openssl/cert.pem` pointed to a nonexistent file and removed the variable before its HTTPX call.

**Cause:** The existing `REQUESTS_CA_BUNDLE` setting was not sufficient for AITK's inference client. This AITK path uses HTTPX, which reads `SSL_CERT_FILE` by default; the two variables are not interchangeable. The image's effective `SSL_CERT_FILE` path was stale. See the [HTTPX environment-variable reference](https://www.python-httpx.org/environment_variables/) and [HTTPX SSL guide](https://www.python-httpx.org/advanced/ssl/).

**Fix applied in the in-house test:** Keep certificate verification enabled and make the effective `SSL_CERT_FILE` path point to a readable bundle containing both the normal public roots and the private test CA. In this image, the inherited path was `/opt/splunk/openssl/cert.pem`; the test copied the already verified combined bundle from `/opt/splunk/etc/auth/requests-ca-bundle.pem` to that path, owned by `splunk:splunk` and mode `0644`. An `SSL_CERT_FILE` line added to `splunk-launch.conf` did not override the value actually inherited by AITK, so that ineffective line was removed. Splunk was restarted; the container returned to `healthy`, and an HTTPX TLS-verified GET to the Slim `/health` endpoint returned HTTP 200.

**Diagnosis and recovery:**

1. Inspect `mlspl.log` for the real exception; the message displayed in the search UI is generic:

   ~~~bash
   grep -E 'SSL_CERT_FILE|CERTIFICATE_VERIFY_FAILED|Error in LLM post call' \
     "$SPLUNK_HOME/var/log/splunk/mlspl.log" | tail -40
   ~~~

2. Read the effective `SSL_CERT_FILE` path from the AITK log or the search-process environment. Confirm the file exists, is readable by the Splunk search user, and contains the required CA chain. Preserve public roots when adding a private CA; a bundle containing only the private CA can break other HTTPS integrations.

3. Install or mount the combined CA bundle at the effective path. Do not rely only on `REQUESTS_CA_BUNDLE` for HTTPX, and do not disable TLS verification (`verify=False`, `curl -k`, or `insecureSkipVerify`).

4. Restart Splunk so new search processes inherit the corrected trust path. Confirm the startup health check reaches `healthy`.

5. Run the minimal `ai` SPL above. Confirm `mlspl.log` no longer reports a removed/nonexistent `SSL_CERT_FILE` or certificate verification error, and confirm Slim logs the corresponding chat-completions request. A successful `/health` GET proves TLS reachability and CA trust but does not by itself prove inference succeeded.

**End-to-end verification (2026-11-04 14:13 UTC):** After the bundle was installed at the effective path, the user reran the minimal `ai` SPL and confirmed it worked. Splunk's `mlspl.log` recorded request ID `54fac1b3-2055-4e60-980f-b50b67c43c7b`, provider `AI Tier`, model `Gemma 4 31B`, `execution_status=success`, and a 0.528-second completion. Slim logged the same request ID at `14:13:04 UTC`; `POST /tenant/slim-api/v1alpha1/chat/completions` returned HTTP 200, and the LLM call completed in 0.485 seconds. This confirms the inference request reached Slim and returned successfully after the CA-path correction. The Splunk-to-Traefik hop remains verified HTTPS; the existing Traefik-to-Slim upstream remains HTTP on port 30081, so this fix did not add TLS inside the cluster.

**Separate Slim warning observed during the successful request:** Slim logged that no Splunk CA bundle was configured and that certificate verification for outbound Splunk TLS was disabled. This is separate from the AITK inference trust failure fixed above. The warning alone does not prove that Slim bypassed Traefik or identify the endpoint it used. In the proxy design, a workload whose effective `SPLUNK_ISSUERS` points at the private Traefik listener should send JWKS/current-context checks through Traefik; Traefik then uses its verified HTTPS upstream to Splunk. Confirm Slim's effective issuer and correlate the request with Traefik access logs before concluding it connected directly. If the effective Slim path uses HTTPS to Splunk, configure the CA reference on the AIService (`spec.splunkConfiguration.caCertRef`) and verify the resulting pod environment. The successful inference request confirms Splunk-to-Traefik TLS was verified; it does not by itself identify Slim's separate issuer-check route.

## Recorded test limitations

- The live Traefik image was a local tag with an image ID, not a registry digest. Pin the customer-published image by immutable digest and attach its build/security evidence.
- GODEBUG=fips140=only and successful TLS handshakes are runtime checks; they do not establish certification of the exact image/module.
- The test listener certificates were temporary and must be replaced with customer-issued certificates.
- Public ingress health was verified from the customer's laptop with the temporary test CA and IP certificate. The user reports the authenticated AITK connection/model-list check succeeds after the Slim CORS change; no browser trace was captured. The v2 search-job results route has route-level evidence of reaching Splunk, but an authenticated end-to-end search and result callback after the latest change are still pending. The network-change/disconnect symptom was followed by resumed callbacks; the earlier search-results router miss and its fix are recorded in section 16.
