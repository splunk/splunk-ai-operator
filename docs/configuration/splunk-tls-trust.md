# Enabling TLS Trust Between AI Platform and Splunk

This guide covers the steps required for SAIA (and SLIM) to trust the TLS
certificate presented by your Splunk stack — whether Splunk runs **inside**
the same cluster (in-cluster/internal mode) or **outside** it (external mode).

## Why this is needed

SAIA and SLIM make outbound HTTPS calls to Splunk (JWKS fetch, interactive
token validation, HEC delivery). If Splunk's certificate is signed by a
publicly trusted CA, no action is needed — the pods' default system trust
store already verifies it. If Splunk's certificate is self-signed or signed
by a private/internal CA — which is the default for an in-cluster Splunk
deployment, and common for on-premises enterprise Splunk — SAIA/SLIM will
fail outbound calls with an error like:

```
ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed
```

To fix this, give SAIA/SLIM the CA certificate that signed Splunk's cert.
The mechanism is the same regardless of where Splunk runs: a Kubernetes
Secret containing the CA bundle, referenced from the `AIPlatform`/`AIService`
CR's `splunkConfiguration.caCertRef` field.

```yaml
splunkConfiguration:
  endpoint: https://<splunk-host>:8089
  secretRef:
    name: <hec-or-auth-secret>
    namespace: <namespace>
  caCertRef:              # <-- this is what wires up TLS trust
    name: <ca-secret-name>
    namespace: <namespace> # must be the same namespace as the AIPlatform/AIService
    key: ca.crt            # defaults to "ca.crt" if omitted
```

When `caCertRef` is set, the operator mounts the referenced Secret into the
SAIA and SLIM pods at `/etc/splunk-ca/<key>` and sets `REQUESTS_CA_BUNDLE`
and `SSL_CERT_FILE` to that path, so outbound HTTPS calls verify against it.
When `caCertRef` is left unset, SAIA/SLIM fall back to the pod image's
default system trust store (correct behavior for publicly trusted certs).

The Secret referenced by `caCertRef` **must live in the same namespace** as
the `AIPlatform`/`AIService` resource — Kubernetes Secret volume mounts
cannot cross namespaces.

---

## Option A: In-cluster Splunk (internal mode)

If you're deploying Splunk inside the same cluster as the AI Platform, the
`k0s_cluster_with_stack.sh` installer automates all of the steps below —
you do not need to do anything manually. This section explains what it does
so you understand the resulting setup, and gives you the manual steps if
you're deploying by hand or with a different installer.

### What the k0s installer does automatically

1. **Provisions a TLS certificate for Splunk via cert-manager**, with the
   correct Kubernetes service DNS names in its Subject Alternative Names
   (SANs) — `splunk-<standaloneName>-standalone-service`,
   `splunk-<standaloneName>-standalone-headless`, and their FQDN variants.
   This is stored in a Secret named `ai-splunk-server-tls`, and the CA that
   signed it is stored alongside it (also readable via key `ca.crt`).
2. **Configures Splunk's `server.conf`/`web.conf`** to use that certificate
   for splunkd (:8089), Splunk Web (:8000), and the KV Store, so all three
   consistently trust the same CA.
3. **Sets `caCertRef` on the `AIPlatform` CR automatically**, pointing at the
   CA secret from step 1:
   ```yaml
   splunkConfiguration:
     endpoint: https://splunk-<standaloneName>-standalone-service.<namespace>.svc.cluster.local:8089
     secretRef:
       name: splunk-<standaloneName>-standalone-secret-v1
       namespace: <namespace>
     caCertRef:
       name: ai-splunk-server-tls
       namespace: <namespace>
       key: ca.crt
   ```

**Customer action required:** none. This mode is fully automatic — just set
`splunk.enabled: true` in your installer config and leave `splunk.external`
unset. See `tools/cluster_setup/k0s-cluster-config.yaml` for the full
`splunk:` block reference.

### Manual steps (if not using the k0s installer)

If you're standing up in-cluster Splunk yourself (a different installer, or
a hand-built manifest), reproduce the same shape:

1. Issue (or otherwise obtain) a TLS certificate for Splunk whose SANs
   include the Kubernetes Service DNS name(s) your Splunk Standalone/Service
   actually exposes (e.g. `splunk-<name>-standalone-service.<ns>.svc.cluster.local`).
   Store the cert + key + CA in a Kubernetes Secret. If using cert-manager,
   request `additionalOutputFormats: [{ type: CombinedPEM }]` so the Secret
   also contains a combined cert+key PEM, which Splunk's `serverCert`
   setting expects.
2. Point Splunk's `server.conf` `[sslConfig]` (`serverCert`, `sslRootCAPath`)
   and `web.conf` `[settings]` (`enableSplunkWebSSL`, `serverCert`) at the
   mounted cert/CA files.
3. Create/confirm the Secret holding the CA bundle is readable at key
   `ca.crt` (or note whatever key you used).
4. Set `splunkConfiguration.caCertRef` on your `AIPlatform` (or `AIService`)
   CR to reference that Secret, as shown in the YAML snippet above.

---

## Option B: External Splunk (customer-managed, outside the cluster)

Use this when SAIA/SLIM point at a Splunk instance you manage outside the
AI Platform's cluster. The AI Platform never touches or reissues your
external Splunk's certificate — you own that certificate's lifecycle
entirely. The steps below only concern telling SAIA/SLIM to trust it.

### If your Splunk certificate is publicly trusted

No action needed. Leave `caCertRef` unset — SAIA/SLIM's default system
trust store already verifies publicly trusted CAs.

### If your Splunk certificate is self-signed or signed by a private/internal CA

1. **Obtain your Splunk CA bundle** (PEM-encoded), from whoever manages
   your Splunk deployment's TLS certificates.

2. **Create a Kubernetes Secret** containing it, in the **same namespace**
   as your `AIPlatform`/`AIService` CR:
   ```bash
   kubectl create secret generic splunk-external-ca \
     --from-file=ca.crt=<path-to-your-ca-bundle.pem> \
     -n <ai-platform-namespace>
   ```

3. **Set `caCertRef` on your `AIPlatform`/`AIService` CR:**
   ```yaml
   splunkConfiguration:
     endpoint: https://<your-external-splunk-host>:8089
     secretRef:
       name: <your-hec-or-auth-secret>
       namespace: <ai-platform-namespace>
     caCertRef:
       name: splunk-external-ca
       namespace: <ai-platform-namespace>
       key: ca.crt
   ```

If you're using the `k0s_cluster_with_stack.sh` installer, steps 2 and 3
are automated for you via the config file — set:
```yaml
splunk:
  enabled: true
  external:
    endpoint: https://splunk.example.com:8088   # base HEC URL
    secretName: splunk-hec-external              # optional
    caCertSecretName: splunk-external-ca         # pre-create this Secret yourself (step 2 above)
```
and export `SPLUNK_HEC_TOKEN` before running the installer. The installer
creates the HEC token Secret and emits `caCertRef` into the `AIPlatform` CR
automatically, but it does **not** create the CA Secret for you in external
mode — you must pre-create it (step 2), since it holds your own
organization's CA material.

> **Note:** the OpenShift and EKS installer scripts do not yet support
> external Splunk mode or automated `caCertRef` wiring. If you're deploying
> to OpenShift or EKS with an external Splunk, apply your `AIPlatform` CR
> manually with the `caCertRef` block shown above (the underlying operator
> support works regardless of which installer created the CR).

---

## Verifying TLS trust is working

After applying the configuration:

```bash
# Confirm the CA Secret exists and has the expected key
kubectl get secret <ca-secret-name> -n <namespace> -o jsonpath='{.data.ca\.crt}' | base64 -d | head -5

# Confirm SAIA picked up the CA bundle env vars
kubectl exec -n <namespace> deployment/<ai-platform-name>-saia-v2 -- env | grep -E 'SSL_CERT_FILE|REQUESTS_CA_BUNDLE'

# Confirm the CA file is actually mounted
kubectl exec -n <namespace> deployment/<ai-platform-name>-saia-v2 -- cat /etc/splunk-ca/ca.crt | head -5

# Check SAIA logs for a successful JWKS fetch (no CERTIFICATE_VERIFY_FAILED)
kubectl logs -n <namespace> deployment/<ai-platform-name>-saia-v2 | grep -i jwks
```

If you still see `CERTIFICATE_VERIFY_FAILED`, confirm:
- The Secret named in `caCertRef.name` exists in the **same namespace** as
  the `AIPlatform`/`AIService` CR.
- The `key` in `caCertRef` matches the actual key in the Secret's `data`
  (default: `ca.crt`).
- The CA bundle you provided is the **issuing CA** for Splunk's server
  certificate, not the leaf certificate itself.

---

## Rotating or updating the CA later

- **In-cluster Splunk (k0s installer):** cert-manager renews the leaf
  certificate automatically before expiry (90-day lifetime, renewed 30 days
  out). No customer action is required for routine renewal.
- **External Splunk:** if your organization rotates its CA, update the same
  Secret in place (`kubectl create secret generic <name> --from-file=ca.crt=<new-path> --dry-run=client -o yaml | kubectl apply -f -`).
  Kubernetes propagates the new file into the mounted volume automatically;
  SAIA/SLIM pick it up on their next reconcile-triggered restart.
- **Adding CA trust for the first time** (you skipped `caCertRef` at initial
  install): create the Secret, set `caCertRef` (or `caCertSecretName` in the
  k0s installer config), and re-apply/re-run the installer. This is
  idempotent and safe to repeat.
