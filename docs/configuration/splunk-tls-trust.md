# Enabling TLS Trust Between AI Platform and Splunk

This guide covers the steps required for SAIA, SLIM, and the OpenTelemetry
(OTel) sidecar to trust the TLS certificate presented by your Splunk stack —
whether Splunk runs **inside** the same cluster (in-cluster/internal mode) or
**outside** it (external mode).

## Why this is needed

SAIA and SLIM make outbound HTTPS calls to Splunk for management/JWKS and
token validation, while the OTel sidecar sends telemetry to Splunk HEC. If
Splunk's certificate is signed by a publicly trusted CA, no action is needed —
the pods' default system trust store already verifies it. If Splunk's
certificate is self-signed or signed by a private/internal CA — which is the
default for an in-cluster Splunk deployment, and common for on-premises
enterprise Splunk — those outbound calls fail with an error like:

```
ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed
```

To fix this, give the AI workloads the CA certificate that signed Splunk's cert.
The mechanism is the same regardless of where Splunk runs: a Kubernetes
Secret containing the CA bundle, referenced from the `AIPlatform`/`AIService`
CR's `splunkConfiguration.caCertRef` field.

```yaml
splunkConfiguration:
  endpoint: https://<splunk-host>:8089     # management/JWKS
  hecEndpoint: https://<splunk-host>:8088  # required when sidecars.otel is enabled
  secretRef:
    name: <hec-or-auth-secret>
    namespace: <namespace>
  caCertRef:              # <-- this is what wires up TLS trust
    name: <ca-secret-name>
    namespace: <namespace> # must be the same namespace as the AIPlatform/AIService
    key: ca.crt            # defaults to "ca.crt" if omitted
```

When `caCertRef` is set, the operator mounts the referenced Secret into the
SAIA and SLIM pods at `/etc/splunk-ca/<key>`. An init container combines that
private CA with the image's system trust store, and `REQUESTS_CA_BUNDLE` and
`SSL_CERT_FILE` point at `/etc/splunk-ca-combined/ca-certificates.crt`, so
Splunk and publicly trusted outbound HTTPS calls both continue to verify.
When OTel is enabled, the operator also projects only that Secret key into the
collector and configures its exporter `ca_file`. When `caCertRef` is left
unset, these workloads use their image's system trust store (correct behavior
for publicly trusted certificates); verification is never disabled implicitly.

The Secret referenced by `caCertRef` **must live in the same namespace** as
the `AIPlatform`/`AIService` resource — Kubernetes Secret volume mounts
cannot cross namespaces.

---

## Option A: In-cluster Splunk (internal mode)

If you're deploying Splunk inside the same cluster as the AI Platform, the
k0s, EKS, and OpenShift stack installers automate the initial certificate and
trust setup below. This section explains the resulting resources and gives you
the manual steps if you're deploying by hand.

### What the stack installers do automatically

1. **Provisions a TLS certificate for Splunk via cert-manager**, with the
   correct Kubernetes service DNS names in its Subject Alternative Names
   (SANs) — `splunk-<standaloneName>-standalone-service`,
   `splunk-<standaloneName>-standalone-headless`, and their FQDN variants.
   The source certificate, key, and issuing CA are stored in a Secret named
   `ai-splunk-server-tls`. Before Splunk starts, its supported Ansible pre-task
   writes a certificate-first combined `server.pem` into a private `emptyDir`;
   AI workloads receive only the public `ca.crt` key.
2. **Configures Splunk's `server.conf`/`web.conf` and HEC settings** to use TLS
   for splunkd (:8089), HEC (:8088), Splunk Web (:8000), and the KV Store, so
   every advertised HTTPS endpoint uses the same certificate and CA.
3. **Sets `caCertRef` on the `AIPlatform` CR automatically**, pointing at the
   CA secret from step 1:
   ```yaml
   splunkConfiguration:
     endpoint: https://splunk-<standaloneName>-standalone-service.<namespace>.svc.cluster.local:8089
     hecEndpoint: https://splunk-<standaloneName>-standalone-service.<namespace>.svc.cluster.local:8088
     secretRef:
       name: splunk-<standaloneName>-standalone-secret-v1
       namespace: <namespace>
     caCertRef:
       name: ai-splunk-server-tls
       namespace: <namespace>
       key: ca.crt
   ```

**Initial installation:** no manual certificate action is required. Set
`splunk.enabled: true` and, for k0s, leave `splunk.external` unset. Certificate
renewal still requires the controlled restart described below; automatic
splunkd reload/restart is not implemented.

### Manual steps (if not using a stack installer)

If you're standing up in-cluster Splunk yourself (a different installer, or
a hand-built manifest), reproduce the same shape:

1. Issue (or otherwise obtain) a TLS certificate for Splunk whose SANs
   include the Kubernetes Service DNS name(s) your Splunk Standalone/Service
   actually exposes (e.g. `splunk-<name>-standalone-service.<ns>.svc.cluster.local`).
   Store the cert + key + CA in a Kubernetes Secret. If using cert-manager,
   prepare Splunk's `serverCert` file in certificate-then-private-key order.
   cert-manager's `CombinedPEM` output uses the reverse order, so do not point
   Splunk directly at `tls-combined.pem`.
2. Point Splunk's `server.conf` `[sslConfig]` (`serverCert`, `sslRootCAPath`),
   `web.conf` `[settings]` (`enableSplunkWebSSL`, `serverCert`, `privKeyPath`),
   and HEC TLS settings at the mounted cert/key/CA files.
3. Create/confirm the Secret holding the CA bundle is readable at key
   `ca.crt` (or note whatever key you used).
4. Set `splunkConfiguration.caCertRef` on your `AIPlatform` (or `AIService`)
   CR to reference that Secret, as shown in the YAML snippet above.

---

## Option B: External Splunk (customer-managed, outside the cluster)

Use this when the AI workloads point at a Splunk instance you manage outside
the AI Platform's cluster. The AI Platform never touches or reissues your
external Splunk's certificate — you own that certificate's lifecycle
entirely. The steps below only concern configuring outbound trust.

### If your Splunk certificate is publicly trusted

No action needed. Leave `caCertRef` unset — SAIA, SLIM, and OTel use their
image's system trust store for publicly trusted CAs.

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
     hecEndpoint: https://<your-external-splunk-host>:8088
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
    managementEndpoint: https://splunk.example.com:8089
    hecEndpoint: https://splunk.example.com:8088
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
kubectl exec -n <namespace> deployment/<ai-platform-name>-saia-v2-deployment -- env | grep -E 'SSL_CERT_FILE|REQUESTS_CA_BUNDLE'

# Confirm the merged system + private CA bundle is mounted
kubectl exec -n <namespace> deployment/<ai-platform-name>-saia-v2-deployment -- \
  sh -c 'test -s /etc/splunk-ca-combined/ca-certificates.crt'

# Check SAIA logs for a successful JWKS fetch (no CERTIFICATE_VERIFY_FAILED)
kubectl logs -n <namespace> deployment/<ai-platform-name>-saia-v2-deployment | grep -i jwks
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

- **In-cluster Splunk (k0s, EKS, and OpenShift installers):** cert-manager
  renews the leaf Secret automatically (90-day lifetime, renewed 30 days out),
  but splunkd does not hot-reload it and the installers do not implement an
  automatic restart trigger. After renewal, perform a supported, controlled
  Splunk Standalone restart. The new pod's pre-task rebuilds `server.pem` from
  the latest Secret before Splunk starts. The installer-owned root CA uses a
  stable key and a ten-year lifetime to avoid frequent trust-anchor churn.
- **External Splunk:** if your organization rotates its CA, update the same
  Secret in place (`kubectl create secret generic <name> --from-file=ca.crt=<new-path> --dry-run=client -o yaml | kubectl apply -f -`).
  Kubernetes propagates the new file into the mounted volume automatically;
  the Secret data change triggers reconciliation and rolls SAIA, SLIM, and
  OTel-enabled Ray pod templates so each process starts with the new CA.
- **Adding CA trust for the first time** (you skipped `caCertRef` at initial
  install): create the Secret, set `caCertRef` (or `caCertSecretName` in the
  k0s installer config), and re-apply/re-run the installer. This is
  idempotent and safe to repeat.
