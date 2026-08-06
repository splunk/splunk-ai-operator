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

### k0s ownership guard and legacy upgrades

The k0s installer does not infer ownership from a common resource name. After cert-manager Phase 1
and before Phase 2 installs or can reconcile the Splunk Operator, it transaction-preflights the
fixed-name footprint. If the `Standalone` CRD exists, the configured `Standalone` is checked; if
the CRD is absent, no such object can exist and only that lookup is safely skipped. Discovery
errors remain fatal. The full preflight repeats after Phase 2 and before AI-namespace image-pull
Secret reconciliation or any internal Splunk certificate/workload mutation. Both passes verify
the installer labels and installation ID:

```yaml
metadata:
  labels:
    app.kubernetes.io/managed-by: splunk-ai-platform-installer
    app.kubernetes.io/instance: splunk-ai-internal
  annotations:
    ai.splunk.com/owner-id: <cluster.name>/<splunk.standaloneName>
```

This check covers `Issuer/ai-splunk-selfsigned`, `Certificate/ai-splunk-ca`,
`Secret/ai-splunk-ca-tls`, `Issuer/ai-splunk-ca-issuer`,
`Certificate/ai-splunk-server`, and `Secret/ai-splunk-server-tls` as one chain. The same guard
includes `ConfigMap/splunk-defaults` and, whenever its CRD exists, the configured `Standalone`, so
a pre-existing workload cannot be reconciled by a newly installed operator before ownership is
verified and the complete footprint passes before any internal Splunk mutation.
Certificate `secretTemplate` metadata preserves the labels and owner ID on generated Secrets.
Normal reconciliation does not force server-side field conflicts, and narrower checks are repeated
at the certificate/workload boundaries as defense in depth.

Consequently, an older installer-created object without the metadata causes a deliberate failure,
as does an object owned by another cluster/Standalone. First inspect the exact resource printed in
the error and verify its certificate contents, namespace, SANs, and consumers. Only for a proven
legacy object from this exact installation, apply both ownership operations shown by the error:

```bash
kubectl -n <namespace> get <resource> <name> -o yaml

kubectl -n <namespace> label <resource> <name> \
  app.kubernetes.io/managed-by=splunk-ai-platform-installer \
  app.kubernetes.io/instance=splunk-ai-internal --overwrite
kubectl -n <namespace> annotate <resource> <name> \
  'ai.splunk.com/owner-id=<cluster.name>/<splunk.standaloneName>' --overwrite
```

Adopt only the object named by the error, then rerun the installer and repeat if another verified
legacy object is reported. Never label or annotate a foreign or uncertain resource simply to pass
the preflight; reconcile it through its current owner or use another namespace.

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

## Certificate renewal, expiry, and customer responsibilities

Do not wait for a certificate to expire. When `caCertRef` is configured, an
expired Splunk leaf certificate, an expired issuing CA, or a hostname mismatch
causes TLS verification to fail and Splunk-dependent requests stop. The
operator does not fall back to unverified TLS when configured trust material is
invalid. The workloads normally remain running, but management/JWKS calls and
OTel HEC delivery fail until Splunk presents a valid certificate chain again.

| Deployment | What is automated | What the customer must do |
|---|---|---|
| Installer-managed internal Splunk | cert-manager renews the 90-day leaf Secret 30 days before expiry. The installer-owned root CA has a ten-year lifetime and stable private key. | Monitor both Certificates. After leaf renewal, make Splunk load the renewed Secret before the old in-memory certificate expires. For k0s, re-run the full installer with the original config and AI namespace; it performs the controlled `OnDelete` pod recycle when the certificate fingerprint changes. For EKS and OpenShift, perform a supported controlled Splunk Standalone restart; those installers do not currently automate the restart. |
| External Splunk with a publicly trusted certificate | Nothing in the AI Platform renews or reloads the external certificate. | Renew the certificate on the external Splunk deployment, install the complete leaf and intermediate chain, and reload or restart Splunk before expiry. `caCertRef` remains unset. |
| External Splunk with a private CA | The operator watches an updated `caCertRef` Secret and rolls affected SAIA, SLIM, and OTel-enabled Ray pod templates. | Renew and reload the Splunk server certificate. If the issuing CA changes, update the Kubernetes CA bundle using the overlap procedure below. The AI Platform never renews an external certificate or CA. |

Monitor the installer-managed Certificates and inspect the currently issued
leaf without exposing its private key:

```bash
kubectl get certificate ai-splunk-server ai-splunk-ca -n <namespace>

kubectl get secret ai-splunk-server-tls -n <namespace> \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode | \
  openssl x509 -noout -subject -issuer -dates
```

For external Splunk, inspect the certificate that clients actually receive:

```bash
openssl s_client -connect <splunk-host>:8089 -servername <splunk-host> \
  </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

### Rotating an external private CA

Avoid a trust gap by overlapping the old and new CAs:

1. Before changing Splunk's server certificate, create a PEM bundle containing
   the old CA followed by the new CA.
2. Update the existing `caCertRef` Secret in place:
   ```bash
   kubectl create secret generic <ca-secret-name> \
     --from-file=ca.crt=<old-and-new-ca-bundle.pem> \
     -n <namespace> --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Wait for the affected workloads to reconcile and restart with the overlap
   bundle.
4. Install the new server certificate and complete chain on external Splunk,
   then perform the Splunk-supported reload or restart.
5. Verify management/JWKS and HEC connectivity. After every client has moved
   to the new chain, remove the old CA from the bundle in a later maintenance
   window.

### If the certificate has already expired

- **Internal k0s:** first confirm cert-manager has written a renewed
  `ai-splunk-server-tls` Secret, then re-run the full installer with the
  original config and namespace so Splunk is recycled onto the renewed
  certificate. If the Certificate is not `Ready`, repair cert-manager issuance
  first.
- **Internal EKS/OpenShift:** confirm the renewed Secret exists, then perform a
  supported controlled Splunk Standalone restart so its pre-task rebuilds
  `server.pem` from the current Secret.
- **External Splunk:** renew and install the server certificate and full chain,
  update the `caCertRef` Secret first if the CA changed, and reload or restart
  Splunk. The customer owns recovery of the external endpoint.

Expect verified calls to remain unavailable until the serving Splunk process
has loaded the valid certificate. Do not work around expiry by disabling
certificate or hostname verification.

**Adding CA trust for the first time:** create the Secret, set `caCertRef` (or
`caCertSecretName` in the k0s installer config), and re-apply or re-run the
installer. This is idempotent and safe to repeat.
