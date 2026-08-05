# Enabling HTTPS Access (Traefik Ingress) — Customer Setup Guide

> **Status:** This guide documents the feature described in `TRAEFIK_HTTPS_DESIGN.md`, being
> implemented on the `feature/traefik-https-ingress-k0s` branch. Config keys, defaults, and
> exact behavior below match the approved design as of this writing but may shift slightly
> before the feature ships — check the installer's own `--help`/config comments at install time
> if anything here looks out of date.

This guide walks you through turning on HTTPS access to Splunk Web and the Splunk AI Assistant
(SAIA) after installing the Splunk AI Platform with the k0s installer. It replaces the SSH
tunnel + `kubectl port-forward` access pattern with a single stable HTTPS endpoint per worker
node, and removes the browser mixed-content error that otherwise blocks the AI Assistant chat
panel once Splunk Web is served over HTTPS.

**This feature is optional.** If you do nothing, your installation behaves exactly as it does
today — plain HTTP, NodePort/tunnel access. Everything below is opt-in.

---

## Table of Contents

- [Who Needs This](#who-needs-this)
- [What This Does](#what-this-does)
- [Prerequisites](#prerequisites)
- [Step 1 — Decide Your TLS Certificate Strategy](#step-1--decide-your-tls-certificate-strategy)
- [Step 2 — Enable Ingress in Your Cluster Config](#step-2--enable-ingress-in-your-cluster-config)
- [Step 3 — Open Firewall / Network Access to the Ports](#step-3--open-firewall--network-access-to-the-ports)
- [Step 4 — Run the Installer](#step-4--run-the-installer)
- [Step 5 — Trust the Certificate (Self-Signed Mode Only)](#step-5--trust-the-certificate-self-signed-mode-only)
- [Step 6 — Point the AI Assistant at the New HTTPS URL](#step-6--point-the-ai-assistant-at-the-new-https-url)
- [Step 7 — Verify](#step-7--verify)
- [Multiple Worker Nodes — Which URL Do I Use?](#multiple-worker-nodes--which-url-do-i-use)
- [FIPS / FedRAMP Deployments](#fips--fedramp-deployments)
- [Airgapped Installs](#airgapped-installs)
- [Rolling Back](#rolling-back)
- [Troubleshooting](#troubleshooting)

---

## Who Needs This

Turn this on if any of the following apply to you:

- You want a stable `https://` URL for Splunk Web and the AI Assistant instead of maintaining
  SSH tunnels or `kubectl port-forward` sessions.
- You've enabled (or plan to enable) HTTPS on Splunk Web and are now hitting a browser error
  where the AI Assistant chat panel spins forever and never loads (mixed-content blocking).
- An external Splunk instance needs a stable, TLS-terminated URL to validate JWTs against the
  AI Assistant's signing endpoint.

If none of that applies, you can skip this entirely — the installer's default plain-HTTP setup
is unaffected either way.

## What This Does

The installer deploys **Traefik**, an open-source reverse proxy (the same one published at
[hub.docker.com/_/traefik](https://hub.docker.com/_/traefik)), as a small process running on
every worker node in your cluster. It terminates HTTPS and forwards requests to:

| Service | HTTPS Port | What it's for |
|---|---|---|
| SAIA (AI Assistant API) | `:8443` | Fixes the mixed-content chat-panel error |
| Splunk Web | `:8000` | Browser access to Splunk over HTTPS |
| Splunk management API | `:8089` | Optional — only needed if an external system talks to Splunk's management port directly |

Nothing about your existing access (NodePort, SSH tunnels) is removed or disabled by turning
this on — it's purely additive. You can turn it off again at any time (see
[Rolling Back](#rolling-back)).

---

## Prerequisites

- The Splunk AI Platform is already installed via the k0s installer (`cert-manager` is
  installed automatically as part of that process — nothing extra to do here).
- `kubectl` access to the cluster (for verification steps).
- Administrative access to whatever sits between your browser/client and the worker nodes, so
  you can open a few ports — see [Step 3](#step-3--open-firewall--network-access-to-the-ports)
  for what that means on your specific infrastructure (cloud security group, on-prem firewall,
  etc.).
- Normal internet or registry-mirror access to pull `docker.io/library/traefik:v3.6.14` (the
  same access model as every other image this installer already pulls) — unless you're doing an
  airgapped install, see [Airgapped Installs](#airgapped-installs).

---

## Step 1 — Decide Your TLS Certificate Strategy

| Mode | Best for | What you need to provide |
|---|---|---|
| **Self-signed (default)** | Most deployments — internal/private networks, labs, evaluation | Nothing extra. You'll import one CA certificate into your browser once (Step 5). |
| **BYO certificate** | You already have an internally-issued cert (corporate PKI, wildcard cert) | A `tls.crt` + `tls.key` pair. |
| **Public CA (ACME/Let's Encrypt)** | Cluster has a public DNS name and is internet-reachable on port 80/443 | A public DNS name pointing at your cluster. Not viable for private networks. |

If you're not sure, **use self-signed** — it's the default and requires no additional input.

## Step 2 — Enable Ingress in Your Cluster Config

Edit your cluster config YAML (e.g. `k0s-cluster-config.yaml`) and add or update the `ingress:`
block:

```yaml
ingress:
  enabled: true                 # turns this feature on
  hostname: ""                  # optional: a DNS name that resolves to a worker node.
                                 # Leave blank to access via worker IP address instead.
  tls:
    mode: selfsigned            # selfsigned | provided | acme — see Step 1
  entryPoints:
    splunkMgmt:
      enabled: false            # set true only if an external system needs direct access
                                 # to Splunk's management port (:8089)
```

If you chose **BYO certificate** in Step 1, also set:

```yaml
  tls:
    mode: provided
    certFile: "/path/to/tls.crt"
    keyFile: "/path/to/tls.key"
```

If you chose **public CA (ACME)**:

```yaml
  tls:
    mode: acme
    acmeEmail: "you@example.com"
```

## Step 3 — Open Firewall / Network Access to the Ports

Traefik listens directly on each worker node for:

- **`8443`** — SAIA / AI Assistant HTTPS
- **`8000`** — Splunk Web HTTPS
- **`8089`** — Splunk management API (only if you enabled `splunkMgmt` above)

You need to allow inbound traffic to these ports on your worker nodes, from wherever your
browser or client sits. What this means depends on your infrastructure:

| Infrastructure | Action |
|---|---|
| Cloud VM (AWS EC2, GCP, Azure, etc.) | Add an inbound rule to your cloud firewall/security-group for the worker instances, allowing your client network on ports 8443/8000 (and 8089 if enabled). |
| Bare metal / on-prem | Open the ports on each worker's host firewall (`iptables`/`nftables`/`firewalld`/`ufw`), and on any network switch/perimeter firewall between your client and the workers' network segment. |

This step is **not automated by the installer** — it's your responsibility, since it depends on
infrastructure the installer doesn't control.

## Step 4 — Run the Installer

Re-run the installer (or the specific ingress install step, if your workflow supports targeted
re-runs) against the updated config file. The installer will:

1. Deploy Traefik to every worker node.
2. Issue the TLS certificate you configured in Step 1.
3. Wire up routing to SAIA, Splunk Web, and (if enabled) Splunk's management port.
4. Print the HTTPS URLs you can now use, at the end of the install.

If you leave `ingress.enabled: false` (or omit the block entirely), none of this runs — your
install proceeds exactly as before.

## Step 5 — Trust the Certificate (Self-Signed Mode Only)

If you used the default self-signed mode, your browser will show a certificate warning the
first time you visit an HTTPS URL from this setup — this is expected, since the certificate
isn't signed by a public certificate authority.

The installer prints a CA certificate at the end of install. Import it into your browser's (or
OS's) trust store once:

- **Chrome/Edge (macOS):** Keychain Access → System → Certificates → drag in the CA file → set
  "Always Trust."
- **Firefox:** Settings → Privacy & Security → Certificates → View Certificates → Authorities →
  Import.
- **Linux:** typically `sudo cp ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`,
  plus a separate import into your browser if it doesn't use the system store.

If you used BYO certificate or a public CA (ACME), skip this step — your certificate is already
trusted.

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
# SAIA should respond (200 OK)
curl -vk https://<worker-ip-or-hostname>:8443/health

# Splunk Web should respond (redirect or 200)
curl -vk https://<worker-ip-or-hostname>:8000
```

Then, in your browser:
1. Load Splunk Web over HTTPS.
2. Open the AI Assistant chat panel.
3. Confirm the chat loads with no errors in the browser console (look specifically for any
   message containing "mixed content" or "blocked" if something doesn't load).

---

## Multiple Worker Nodes — Which URL Do I Use?

If your cluster has more than one worker node, Traefik runs independently on **each** worker —
there is no single shared address. You can use **any one** worker's IP address; they all reach
the same SAIA and Splunk Web backends identically, because the underlying Kubernetes networking
routes between nodes automatically. You do not need to figure out which worker a particular
service "lives on."

If you configured a DNS hostname in Step 2, prefer using that hostname over a raw IP — it keeps
working even if that specific worker is later replaced, as long as your DNS record is updated to
point at a current worker IP.

## FIPS / FedRAMP Deployments

If you require FIPS 140 compliance, set:

```yaml
ingress:
  fips: "only"
```

**Important:** the default Traefik image is not FIPS-certified. When you set `fips: "only"`,
you must also provide your own FIPS-capable Traefik image (e.g. from your organization's
internal registry) via the `images.ingress.traefikImage` config key. Reach out to your Splunk
contact if you need guidance sourcing one.

## Airgapped Installs

If you're installing in an airgapped/offline environment, the Traefik image and manifests need
to be pre-staged into your airgap bundle before running the installer — this happens
automatically when you build the bundle with `ingress.enabled: true` set in your config. No
manual image-list editing should be required.

## Rolling Back

To turn this off again:

```yaml
ingress:
  enabled: false
```

Re-run the installer. Traefik is removed; your existing NodePort/tunnel access continues to work
exactly as it did before you enabled this feature — nothing else is affected.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Browser can't connect at all | Firewall/port not open (Step 3) | Confirm the port is open from your client's network to the worker, using whatever tool matches your infrastructure (security-group rule, `iptables`, etc.) |
| Certificate warning won't go away after importing the CA | Wrong CA imported, or browser cache | Re-download the CA cert printed at install time; restart the browser |
| Chat panel still spins / mixed-content error in console | AI Assistant still pointed at the old `http://` URL | Re-check Step 6 — the SAIA endpoint setting must use `https://`, not `http://` |
| `curl` to one worker IP works but another doesn't | That worker's IP wasn't included when the certificate was issued | Re-run the installer after confirming all worker IPs are listed in your cluster config; this is handled automatically by the installer today, but worth double-checking if you added workers after the initial install |
| Splunk management port (`:8089`) unreachable | `entryPoints.splunkMgmt.enabled` is `false` (the default) | Set it to `true` in your config if an external system needs direct access to that port |
