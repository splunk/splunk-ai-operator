# Enabling HTTPS Access (Traefik Ingress) — Customer Setup Guide

> **Supported scope:** The installer currently supports only its cert-manager-generated,
> self-signed CA. ACME and user-provided certificates are not implemented configuration modes.

This guide walks you through turning on HTTPS access to installer-managed Splunk Web and the
Splunk AI Assistant (SAIA) after installing the Splunk AI Platform with the k0s installer. It
replaces the SSH
tunnel + `kubectl port-forward` access pattern with a single stable HTTPS endpoint per worker
node, and removes the browser mixed-content error that otherwise blocks the AI Assistant chat
panel when Splunk Web is accessed over HTTPS.

**This feature is optional.** If you do nothing, your installation keeps its existing
ClusterIP/NodePort/tunnel access and gets no Traefik hostPort endpoint. Everything below is
opt-in.

---

## Table of Contents

- [Who Needs This](#who-needs-this)
- [What This Does](#what-this-does)
- [Prerequisites](#prerequisites)
- [Step 1 — Understand the TLS Certificate Model](#step-1--understand-the-tls-certificate-model)
- [Step 2 — Enable Ingress in Your Cluster Config](#step-2--enable-ingress-in-your-cluster-config)
- [Step 3 — Open Firewall / Network Access to the Ports](#step-3--open-firewall--network-access-to-the-ports)
- [Step 4 — Run the Installer](#step-4--run-the-installer)
- [Step 5 — Trust the Generated CA](#step-5--trust-the-generated-ca)
- [Step 6 — Point the AI Assistant at the New HTTPS URL](#step-6--point-the-ai-assistant-at-the-new-https-url)
- [Step 7 — Verify](#step-7--verify)
- [Multiple Worker Nodes — Which URL Do I Use?](#multiple-worker-nodes--which-url-do-i-use)
- [FIPS / FedRAMP Deployments](#fips--fedramp-deployments)
- [Airgapped Installs](#airgapped-installs)
- [Certificate Renewal Operations](#certificate-renewal-operations)
- [Rolling Back](#rolling-back)
- [Upgrading an Earlier Traefik Prototype](#upgrading-an-earlier-traefik-prototype)
- [Security Boundary](#security-boundary)
- [Troubleshooting](#troubleshooting)

---

## Who Needs This

Turn this on if any of the following apply to you:

- You want a stable `https://` URL for Splunk Web and the AI Assistant instead of maintaining
  SSH tunnels or `kubectl port-forward` sessions.
- You access the installer-configured Splunk Web endpoint over HTTPS and are hitting a browser
  error because the AI Assistant still calls an `http://` SAIA NodePort (mixed-content blocking).
- An external Splunk instance needs a stable, TLS-terminated URL to validate JWTs against the
  AI Assistant's signing endpoint.

If none of that applies, you can skip this entirely — the existing non-Traefik access paths are
unaffected either way.

## What This Does

The installer deploys **Traefik**, an open-source reverse proxy (the same one published at
[hub.docker.com/_/traefik](https://hub.docker.com/_/traefik)), as a small process running on
every worker node in your cluster. It terminates HTTPS and forwards requests to:

| Service | HTTPS Port | What it's for |
|---|---|---|
| SAIA (AI Assistant API) | `:8443` | Fixes the mixed-content chat-panel error |
| Splunk Web | `:8000` | Browser access to installer-managed internal Splunk over HTTPS |
| Splunk management API | `:8089` | Optional and disabled by default — only needed if an external system talks to Splunk's management port directly |

Nothing about your existing access (NodePort, SSH tunnels) is removed or disabled by turning
this on — it's purely additive. You can turn it off again at any time (see
[Rolling Back](#rolling-back)).

In external or disabled Splunk mode, the installer publishes only the SAIA `:8443` route. It does
not bind `:8000` or `:8089`, because there is no installer-managed Splunk Service behind them.

---

## Prerequisites

- The Splunk AI Platform is installed through the current k0s installer. Its compatibility
  baseline is `k0s v1.33.13+k0s.1` (Kubernetes 1.33.13) with cert-manager `v1.21.1`;
  cert-manager's installer gate accepts Kubernetes 1.33–1.36 and reuses an installation only when
  its controller, webhook, and cainjector images are all exactly `v1.21.1`. An explicit Kubernetes
  1.34–1.36 override still requires independent validation of the Splunk Operator and the rest of
  the platform. If this cluster has an
  older or otherwise different cert-manager installation, complete the documented
  [sequential migration](K0S_README.md#migrating-an-existing-cert-manager-installation) before
  enabling Traefik. Partial/unowned cert-manager installations are not adopted automatically.
- Bash 4 or newer is available on the admin workstation (Bash 5 recommended). On macOS, install
  Homebrew Bash and put `$(brew --prefix)/bin` before `/bin` in `PATH`; the installer uses
  `#!/usr/bin/env bash` and rejects Apple's older `/bin/bash`.
- `kubectl` access to the cluster (for verification steps).
- The `saia` entry in `aiPlatform.features` (an omitted/empty feature list defaults to SAIA).
  The installer rejects ingress on an explicit feature list that omits SAIA rather than
  publishing a route to a Service that will never exist.
- Administrative access to whatever sits between your browser/client and the worker nodes, so
  you can open a few ports — see [Step 3](#step-3--open-firewall--network-access-to-the-ports)
  for what that means on your specific infrastructure (cloud security group, on-prem firewall,
  etc.).
- Normal internet or registry-mirror access to pull the default image,
  `docker.io/library/traefik:v3.6.25@sha256:31267173a15b4944e797a76ffd9c419707c8d8b32fe5b610f80cd0cfa05f372d`.
  This is the verified multi-architecture index digest. For an airgapped install, see
  [Airgapped Installs](#airgapped-installs).

---

## Step 1 — Understand the TLS Certificate Model

The installer supports one certificate model: cert-manager creates a private self-signed CA and
uses it to issue the Traefik leaf certificate. The leaf includes every configured worker IP and,
when set, `ingress.hostname`. Import the current generated CA into each client trust store
initially and redistribute it after CA renewal or disable/re-enable (Step 5).

Do not configure `provided` or `acme`: those modes are not implemented. Integrating a corporate
PKI or public CA requires a separate, reviewed enhancement.

## Step 2 — Enable Ingress in Your Cluster Config

Edit your cluster config YAML (e.g. `k0s-cluster-config.yaml`) and add or update the `ingress:`
block:

```yaml
ingress:
  enabled: true                 # turns this feature on
  hostname: ""                  # optional: a DNS name that resolves to a worker node.
                                 # Leave blank to access via worker IP address instead.
  tls:
    mode: selfsigned            # the only currently supported mode
  fips: "off"                   # off | on; see FIPS / FedRAMP Deployments
  entryPoints:
    # These hostPorts must be unique integers from 1024 through 65535. Port
    # 9000 is reserved for Traefik's pod-local health endpoint. They also must
    # not equal aiPlatform.serviceTemplate.nodePort or slimNodePort.
    saia:
      port: 8443
    splunkWeb:
      port: 8000
    splunkMgmt:
      port: 8089
      enabled: false            # set true only in internal Splunk mode when an external client
                                 # needs direct access to the management port (:8089)
```

## Step 3 — Open Firewall / Network Access to the Ports

Traefik listens directly on each worker node for:

- **`8443`** — SAIA / AI Assistant HTTPS
- **`8000`** — Splunk Web HTTPS (internal Splunk mode only)
- **`8089`** — Splunk management API (not bound by default; present only if you enabled
  `splunkMgmt` above)

You need to allow inbound traffic to these ports on your worker nodes, from wherever your
browser or client sits. What this means depends on your infrastructure:

| Infrastructure | Action |
|---|---|
| Cloud VM (AWS EC2, GCP, Azure, etc.) | Add an inbound rule to your cloud firewall/security-group for the worker instances, allowing your client network on port 8443, plus 8000 for internal Splunk and 8089 only if enabled. |
| Bare metal / on-prem | Open the ports on each worker's host firewall (`iptables`/`nftables`/`firewalld`/`ufw`), and on any network switch/perimeter firewall between your client and the workers' network segment. |

This step is **not automated by the installer** — it's your responsibility, since it depends on
infrastructure the installer doesn't control.

## Step 4 — Run the Installer

Re-run the full installer against the updated config file. Use the same configured AI namespace on
later lifecycle runs; a targeted Traefik-only apply cannot perform Splunk's controlled certificate
restart. The installer will:

1. Deploy Traefik to every worker node.
2. Install the complete Traefik v3.6.25 CRD set on a clean cluster, or verify that an existing
   complete set matches it exactly. The installer refuses partial or different shared CRDs
   instead of taking ownership or downgrading another Traefik installation.
3. Issue the self-signed CA and leaf certificate described in Step 1.
4. Configure a default `TLSStore` so IP/no-SNI clients receive that leaf certificate.
5. In internal Splunk mode, route Splunk Web to its HTTPS backend through a CA- and
   hostname-validating `ServersTransport`; the installer does not use `insecureSkipVerify`.
6. Wire up SAIA and, if enabled, Splunk's management port, then print the HTTPS URLs.

With `ingress.enabled: false` (or an omitted block), the installer runs ownership-labelled disable
reconciliation. On a never-enabled cluster with no fixed-name collision this changes nothing. An
unlabelled or foreign `ingress/DaemonSet/traefik` is reported as a blocking collision rather than
being adopted, deleted, or incorrectly reported as disabled. See [Rolling Back](#rolling-back).

## Step 5 — Trust the Generated CA

Your browser will show a certificate warning the first time you visit an HTTPS URL from this
setup. This is expected because the certificate is not signed by a public certificate authority.

The installer identifies the generated CA Secret at the end of install. Export it, then import
the file into your browser's (or OS's) trust store. Commands below use the default `ai-platform`;
replace it with your configured `kubernetes.namespace` when different:

```bash
kubectl -n ai-platform get secret ai-platform-ingress-ca-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > ingress-ca.crt
```

- **Chrome/Edge (macOS):** Keychain Access → System → Certificates → drag in the CA file → set
  "Always Trust."
- **Firefox:** Settings → Privacy & Security → Certificates → View Certificates → Authorities →
  Import.
- **Linux:** typically `sudo cp ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`,
  plus a separate import into your browser if it doesn't use the system store.

The CA certificate is long-lived, but cert-manager renews it before expiry. Monitor
`Certificate/ingress-ca`; after a CA renewal, re-run the installer and redistribute the current
`ca.crt` before the previously imported CA expires. A disable/re-enable always creates a new CA
and requires immediate re-import.

## Step 6 — Point the AI Assistant at the New HTTPS URL

In the Splunk AI Assistant app's setup/onboarding screen, update the SAIA endpoint to:

```
https://<worker-ip-or-hostname>:8443
```

Use the hostname you set in Step 2 if you configured one; otherwise use any one of your worker
nodes' IP addresses (see [Multiple Worker Nodes](#multiple-worker-nodes--which-url-do-i-use)
below — any worker IP works equally well here).

## Step 7 — Verify

```bash
# Use the generated CA file from Step 5; do not use -k for the trust check.
curl --fail --cacert ./ingress-ca.crt \
  https://<worker-ip-or-hostname>:8443/health

# Internal Splunk mode only: Splunk Web should return its normal HTTPS response.
curl --fail --cacert ./ingress-ca.crt \
  https://<worker-ip-or-hostname>:8000

# The verified backend transport and default TLS store should both exist.
kubectl -n ai-platform get serverstransport splunk-web-tls
kubectl -n ai-platform get tlsstore default
```

If you explicitly enabled the `:8089` management passthrough, that listener presents Splunk's
own certificate, not the Traefik frontend certificate. Export and use the separate Splunk CA:

```bash
kubectl -n ai-platform get secret ai-splunk-ca-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > splunk-ca.crt

# A 401 response is expected without Splunk credentials; the important result
# here is a successful CA and hostname/IP verification (curl exit status 0).
curl --cacert ./splunk-ca.crt --output /dev/null --write-out '%{http_code}\n' \
  https://<worker-ip-or-hostname>:8089/services/server/info
```

There is no cleartext HTTP entry point in this design, so no redirect middleware is installed.
Connect directly to the HTTPS ports above; an HTTP-to-HTTPS redirect must not be documented or
created unless a separate HTTP listener and route are added.

Then, in your browser:
1. Load Splunk Web over HTTPS.
2. Open the AI Assistant chat panel.
3. Confirm the chat loads with no errors in the browser console (look specifically for any
   message containing "mixed content" or "blocked" if something doesn't load).

---

## Multiple Worker Nodes — Which URL Do I Use?

If your cluster has more than one worker node, Traefik runs independently on **each** worker —
there is no single shared address. You can use **any one** worker's IP address; they all reach
the same configured backends identically, because the underlying Kubernetes networking routes
between nodes automatically. You do not need to figure out which worker a particular service
"lives on."

If you configured a DNS hostname in Step 2, prefer using that hostname over a raw IP — it keeps
working even if that specific worker is later replaced, as long as your DNS record is updated to
point at a current worker IP.

## FIPS / FedRAMP Deployments

If you require FIPS 140 compliance, set:

```yaml
ingress:
  fips: "on"
```

Only `off` and `on` are supported; `off` is the default. **The upstream Traefik image is not a
compliance assertion.** When you set `fips: "on"`, you must also set
`images.ingress.traefikImage` to an image built with the approved Go cryptographic module and
validated for your operating environment. The runtime flag alone does not establish FIPS or
FedRAMP compliance, and the installer does not inspect attestations or prove that an arbitrary
override is FIPS-capable. Do not use `fips140=only` in production; Go documents it as an
assessment mode rather than the normal production setting.

## Airgapped Installs

Build the bundle with the same cluster config you will use for the offline install:

```bash
./prepare_airgap_bundle.sh \
  --config ./k0s-cluster-config.yaml \
  --output-dir /mnt/transfer
```

Run bundle preparation on a **Linux/amd64** connected host. It executes the downloaded k0s
Linux/amd64 binary while constructing the image archives; macOS/Apple Silicon is not a supported
bundle-build host.

When that config has `ingress.enabled: true`, the script reads the exact
`images.ingress.traefikImage` value and adds it to both `images/addon-images.tar` and
`container-images.txt`. If you build without `--config`, Traefik is not staged; rebuild the
bundle before enabling ingress offline. The generic `images.registry` prefix is not applied to
Traefik. If you mirror it under a different reference, set that exact tag or digest in
`images.ingress.traefikImage` before building the bundle and use the same config for installation.
The bundle wrapper validates its k0s/cert-manager metadata and this exact config/image match before
copying binaries onto the install host. Sourcing the generated `airgap-env.sh` manually exports the
same bundle metadata; the main installer repeats the match check.

## Certificate Renewal Operations

cert-manager renews both the Traefik frontend certificates and the internal Splunk certificates
autonomously, but the consumers do not all reconcile in the same way:

- Traefik watches `Secret/internal-domain-tls` and reloads a renewed frontend leaf. Client trust
  stores are external to Kubernetes, so monitor `Certificate/ingress-ca`, re-run the installer,
  and redistribute the current ingress `ca.crt` before the previously imported CA expires.
- `ConfigMap/ai-splunk-ca-public` is a point-in-time copy of `ca.crt` from
  `Secret/ai-splunk-server-tls`. It is refreshed only when the installer runs; cert-manager does
  not update that ConfigMap.
- Splunk does not hot-reload renewed certificate files, and its StatefulSet uses `OnDelete`.
  Monitor `Certificate/ai-splunk-server` and `Certificate/ai-splunk-ca`. After the Splunk leaf or
  CA renews, re-run the full installer with the original AI namespace. The installer fingerprints
  the current leaf, explicitly deletes the singleton Splunk pod when that leaf changed, waits for
  the replacement to become Ready, and then refreshes `ai-splunk-ca-public` while reconciling
  Traefik.

Do not treat a renewed Secret by itself as completion of the Splunk rotation workflow.

If a certificate expires before these actions are completed, verified clients fail their TLS
handshake and Splunk-dependent operations remain unavailable. Customers must restore a valid
issued Secret, re-run the full installer with the original config and AI namespace so Splunk loads
it, redistribute a renewed CA where applicable, and verify the certificate actually served on the
endpoint. Do not use `-k`, `insecureSkipVerify`, or disabled hostname verification as an expiry
recovery procedure.

## Rolling Back

To turn this off again:

```yaml
ingress:
  enabled: false
```

Re-run the installer using the same `kubernetes.namespace` that was used while enabling ingress.
It removes label-verified installer-owned Traefik routes, transport/TLS-store resources,
the DaemonSet and its hostPort bindings, RBAC/service-account resources, Traefik's cert-manager
resources, and the Traefik CA/leaf Secrets. Delete failures are fatal and are reported instead of being
hidden. It removes labelled pull-Secret copies, but intentionally retains the cluster-scoped
Traefik CRDs and pre-existing/unowned registry credentials in the `ingress` namespace. Remove a
retained credential only after verifying that no workload uses it.
Unlabelled or foreign objects with common names such as `DaemonSet/traefik` or
`TLSStore/default` are left untouched; an active fixed-name DaemonSet makes disable reconciliation
fail so the installer cannot falsely report that hostPorts were closed. Existing NodePort/tunnel
access continues to work.

Re-enabling ingress creates a new self-signed CA. Any clients that trusted the previous CA must
import the new CA again.

## Upgrading an Earlier Traefik Prototype

The earlier branch revision created unlabelled fixed-name objects, only three CRDs, and a broad
`ClusterRoleBinding/traefik-ingress-controller`. The current installer deliberately refuses to
guess that those common names belong to it. Before upgrading:

1. Inspect the old DaemonSet, ServiceAccount, ClusterRoleBinding, routes, certificates, and CRDs;
   use the original AI namespace and confirm that no other Traefik deployment uses them.
2. Remove the verified legacy runtime and broad ClusterRoleBinding explicitly.
3. With cluster-owner approval, apply the repository's pinned complete CRD bundle once:
   `kubectl apply --server-side --force-conflicts -f traefik/traefik-crds.yaml`.
4. Re-run the installer. It creates ownership-labelled, namespace-scoped replacements.

Do not force the CRD migration on a shared cluster. The installer never upgrades, takes ownership
of, or removes an existing complete CRD set automatically; coordinate with the existing CRD owner
instead.

## Security Boundary

The CA-only `ai-splunk-ca-public` ConfigMap prevents the backend transport from directly
referencing a Secret that also contains `tls.key`. It does **not** isolate Secrets at the
Kubernetes API boundary. Traefik's CRD provider must list/watch Secrets in the watched AI
namespace to load route certificates, and Kubernetes RBAC cannot restrict `list`/`watch` by
individual Secret name. Treat the `ingress/traefik` ServiceAccount as trusted within that AI
namespace; use a dedicated cluster/namespace architecture if that trust boundary is unsuitable.
The ConfigMap also does not follow Secret changes automatically; use the renewal procedure above.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Browser can't connect at all | Firewall/port not open (Step 3) | Confirm the port is open from your client's network to the worker, using whatever tool matches your infrastructure (security-group rule, `iptables`, etc.) |
| Certificate warning won't go away after importing the CA | Wrong CA imported, or browser cache | Re-download the CA cert printed at install time; restart the browser |
| Chat panel still spins / mixed-content error in console | AI Assistant still pointed at the old `http://` URL | Re-check Step 6 — the SAIA endpoint setting must use `https://`, not `http://` |
| `curl` to one worker IP works but another doesn't | That worker's IP wasn't included when the certificate was issued | Re-run the installer after confirming all worker IPs are listed in your cluster config; this is handled automatically by the installer today, but worth double-checking if you added workers after the initial install |
| Splunk management port (`:8089`) unreachable | `entryPoints.splunkMgmt.enabled` is `false` (the default), or Splunk is not in internal mode | Enable it only for installer-managed internal Splunk when an external client needs direct access |
| Splunk Web returns 502 after certificate renewal | Splunk still has old files loaded, or `ai-splunk-ca-public` is stale | Re-run the full installer with the original AI namespace; it performs the controlled OnDelete pod recycle when the leaf changed and refreshes the CA-only ConfigMap |
| HTTPS works with `-k` but fails normally | Generated CA is not trusted, or the URL does not match a configured IP/DNS SAN | Import the current generated CA and use a worker IP or `ingress.hostname`; after disable/re-enable, import the newly generated CA |
| Air-gapped Traefik pod is `ImagePullBackOff` | Bundle was built without the ingress-enabled config, or it used a different image reference | Rebuild with `prepare_airgap_bundle.sh --config <the-install-config>` and transfer the new bundle |
