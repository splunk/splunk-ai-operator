# Splunk AI Assistant App — Installation Guide

The Splunk AI Assistant (SAIA) app is a Splunk application that provides the
AI chat UI and integrates with the AI Platform backend running on the k0s
cluster. It must be installed on the Splunk Enterprise instance that is
deployed as part of the platform.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Find Your Splunk Web URL](#find-your-splunk-web-url)
- [Install the App from Splunk UI](#install-the-app-from-splunk-ui)
- [Install the App in an Air-Gapped Environment](#install-the-app-in-an-air-gapped-environment)
- [Verify the Installation](#verify-the-installation)
- [Configure the App](#configure-the-app)
- [Troubleshooting](#troubleshooting)

---

## Overview

```
Customer browser
      │
      ▼
Splunk Web (port 8000)
      │  Splunk AI Assistant app
      │  (installed in Splunk Enterprise)
      ▼
SAIA API service (NodePort / LoadBalancer)
      │
      ▼
Ray GPU workers → AI models
```

The app is the front-end piece. The AI Platform backend (Ray, SAIA API, Weaviate,
model weights) must already be running before the app is useful — verify cluster
health first with `kubectl get aiplatform -n ai-platform`.

---

## Prerequisites

- The k0s cluster and AI Platform stack are fully installed and all pods are Running.
- You have the `Splunk_AI_Assistant_Cloud.tgz` app archive. Obtain it from your
  Splunk account team or the internal app distribution channel.
- You have admin credentials for the Splunk Enterprise instance.
- The Splunk Enterprise instance is reachable from your browser (see
  [Find Your Splunk Web URL](#find-your-splunk-web-url)).

---

## Find Your Splunk Web URL

Splunk Enterprise is exposed on port **8000**. How you reach it depends on
how the SAIA service is configured.

### Option A — NodePort (default)

The installer configures a NodePort service by default. Splunk Web is reachable
at any worker node IP on the configured port.

```bash
# Get the NodePort assigned to Splunk Web
kubectl get svc -n ai-platform -l app.kubernetes.io/name=splunk

# Or check the Standalone resource
kubectl get standalone -n ai-platform -o wide
```

Access URL:

```
http://<any-worker-node-ip>:<nodePort>
```

Example: `http://10.0.1.12:30080`

### Option B — LoadBalancer (MetalLB)

If you configured `aiPlatform.serviceTemplate.type: LoadBalancer` in your
cluster config, the service gets an `EXTERNAL-IP` from MetalLB:

```bash
kubectl get svc -n ai-platform -l app.kubernetes.io/component=saia
```

Access URL:

```
http://<EXTERNAL-IP>
```

### Option C — kubectl port-forward (quick access without external exposure)

```bash
kubectl port-forward -n ai-platform svc/splunk-standalone-service 8000:8000
```

Then open `http://localhost:8000` in your browser.

---

## Install the App from Splunk UI

> **Note:** This method requires the Splunk instance to have access to the
> `Splunk_AI_Assistant_Cloud.tgz` file. For air-gapped environments where
> the browser machine cannot reach the cluster, see
> [Install the App in an Air-Gapped Environment](#install-the-app-in-an-air-gapped-environment).

**1. Log in to Splunk Web**

Open the Splunk Web URL in your browser and log in with admin credentials.

Default credentials (change these immediately in production):

| Field | Default |
|---|---|
| Username | `admin` |
| Password | Set during install — check the `splunk-standalone-secret` Kubernetes secret |

```bash
# Retrieve the auto-generated admin password
kubectl get secret splunk-standalone-secret -n ai-platform \
  -o jsonpath='{.data.password}' | base64 --decode
```

---

**2. Open the App Manager**

From the Splunk Web home page:

1. Click the **Apps** menu in the top navigation bar
2. Select **Manage Apps**

Or navigate directly to:

```
http://<splunk-url>/en-US/manager/launcher/apps/local
```

---

**3. Install from file**

1. Click **Install app from file**
2. Click **Choose File** and select `Splunk_AI_Assistant_Cloud.tgz`
3. Check **Upgrade app** if a previous version is already installed
4. Click **Upload**

Splunk will install the app and prompt you to restart if required.

---

**4. Restart Splunk (if prompted)**

If Splunk displays a restart prompt:

1. Click **Restart Splunk**
2. Wait for the instance to come back up (~60 seconds)
3. Log in again

To restart from the command line if needed:

```bash
kubectl exec -n ai-platform splunk-standalone-0 -- \
  sudo /opt/splunk/bin/splunk restart
```

---

**5. Launch the app**

After installation the **Splunk AI Assistant** app appears in the Apps list.
Click it to open the AI chat interface.

---

## Install the App in an Air-Gapped Environment

In a fully air-gapped environment the Splunk Web UI is not reachable from a
machine that has the `.tgz` file. Use `kubectl cp` to copy the app into the
Splunk pod directly.

**1. Copy the app archive into the Splunk pod**

```bash
APP_TGZ="Splunk_AI_Assistant_Cloud.tgz"
POD="splunk-standalone-0"
NAMESPACE="ai-platform"

kubectl cp "${APP_TGZ}" "${NAMESPACE}/${POD}:/tmp/${APP_TGZ}"
```

**2. Extract the app inside the pod**

```bash
kubectl exec -n "${NAMESPACE}" "${POD}" -- bash -c "
  cd /opt/splunk/etc/apps
  tar -xzf /tmp/${APP_TGZ}
  rm /tmp/${APP_TGZ}
  echo 'App extracted to /opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud'
"
```

**3. Reload Splunk to pick up the new app**

```bash
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  /opt/splunk/bin/splunk restart
```

Wait ~60 seconds for Splunk to come back up, then verify the app is listed:

```bash
kubectl exec -n "${NAMESPACE}" "${POD}" -- \
  /opt/splunk/bin/splunk search \
  '| rest /services/apps/local | search title="Splunk_AI_Assistant_Cloud"' \
  -auth admin:"$(kubectl get secret splunk-standalone-secret -n ai-platform \
    -o jsonpath='{.data.password}' | base64 --decode)"
```

---

## Verify the Installation

### Check the app is installed

```bash
# Via kubectl
kubectl exec -n ai-platform splunk-standalone-0 -- \
  ls /opt/splunk/etc/apps/ | grep -i saia

# Via Splunk REST API (from inside the pod)
kubectl exec -n ai-platform splunk-standalone-0 -- \
  curl -sku admin:"<password>" \
  https://localhost:8089/services/apps/local/Splunk_AI_Assistant_Cloud \
  | grep -E "<title>|disabled|version"
```

### Check via Kubernetes Standalone status

```bash
kubectl get standalone splunk-standalone -n ai-platform -o json \
  | jq '.status.appContext.appSrcDeployStatus'
```

Expected: `deployStatus: 3` (Installed) for `Splunk_AI_Assistant_Cloud.tgz`
with `isDeploymentInProgress: false`.

### End-to-end smoke test

1. Open Splunk Web and navigate to the **Splunk AI Assistant** app
2. Type a test prompt in the chat interface
3. Confirm a response is returned from the AI backend

If the prompt hangs or returns an error, check
[Troubleshooting](#troubleshooting).

---

## Configure the App

After installation the app needs to know the SAIA API endpoint so it can
route requests to the AI backend.

### Find the SAIA API endpoint

```bash
# NodePort
kubectl get svc -n ai-platform -l app.kubernetes.io/component=saia \
  -o jsonpath='{.items[0].spec.ports[0].nodePort}'
# → e.g. 30080
# URL: http://<any-worker-ip>:<nodePort>

# LoadBalancer
kubectl get svc -n ai-platform -l app.kubernetes.io/component=saia \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'
# URL: http://<EXTERNAL-IP>
```

### Set the SAIA API URL in the app

1. In Splunk Web, go to **Settings → Splunk AI Assistant → Configuration**
   (or the app's Setup page, usually at `/en-US/app/Splunk_AI_Assistant_Cloud/setup`)
2. Enter the SAIA API URL:
   - NodePort: `http://<worker-node-ip>:<nodePort>`
   - LoadBalancer: `http://<EXTERNAL-IP>`
3. Save the configuration

### `splunkaiassistant.conf` (manual config)

For scripted or air-gapped configuration, write the conf file directly:

```bash
kubectl exec -n ai-platform splunk-standalone-0 -- bash -c "
  mkdir -p /opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud/local
  cat > /opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud/local/splunkaiassistant.conf <<'EOF'
[splunk_ai_assistant]
feedback_enabled = true

[saia_sok_configurations]
saia_endpoint = http://<worker-node-ip>:<nodePort>
EOF
"
```

Then reload the app configuration:

```bash
kubectl exec -n ai-platform splunk-standalone-0 -- \
  /opt/splunk/bin/splunk _internal call /apps/local/Splunk_AI_Assistant_Cloud/_reload \
  -auth admin:"<password>"
```

---

## Troubleshooting

### App does not appear in the Apps list after upload

- Confirm the upload completed without errors. The Splunk UI shows a green
  success banner; if it shows an error, check the file is a valid `.tgz`.
- Check Splunk internal logs:
  ```bash
  kubectl exec -n ai-platform splunk-standalone-0 -- \
    tail -50 /opt/splunk/var/log/splunk/splunkd.log | grep -i "install\|app\|error"
  ```

### "App installed but chat returns no response"

The app is installed but cannot reach the SAIA API.

```bash
# Confirm the SAIA service is running
kubectl get pods -n ai-platform | grep saia
kubectl get svc  -n ai-platform | grep saia

# Test the API endpoint from inside the Splunk pod
kubectl exec -n ai-platform splunk-standalone-0 -- \
  curl -sv http://<worker-ip>:<nodePort>/health
```

Expected: HTTP 200. If not reachable, check network policy and service
configuration (`kubectl describe svc -n ai-platform <saia-service>`).

### "deployStatus not 3" in Standalone status

The Splunk Operator tracks app deployment status. If `deployStatus` is not `3`:

| `deployStatus` value | Meaning |
|---|---|
| `0` | Pending |
| `1` | Downloading |
| `2` | Deploying |
| `3` | Installed |
| `-1` | Error |

For `-1` check the Splunk Operator logs:

```bash
kubectl logs -n splunk-operator deploy/splunk-operator-controller-manager \
  --tail=100 | grep -i "app\|error"
```

### Restart loop after app install

```bash
kubectl logs -n ai-platform splunk-standalone-0 --tail=100
kubectl exec -n ai-platform splunk-standalone-0 -- \
  tail -30 /opt/splunk/var/log/splunk/splunkd.log
```

Look for configuration or Python errors. A common cause is a missing or
malformed `splunkaiassistant.conf`. Remove the file and restart to fall back
to defaults:

```bash
kubectl exec -n ai-platform splunk-standalone-0 -- \
  rm -f /opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud/local/splunkaiassistant.conf
kubectl exec -n ai-platform splunk-standalone-0 -- \
  /opt/splunk/bin/splunk restart
```

### Retrieve the admin password

```bash
kubectl get secret splunk-standalone-secret -n ai-platform \
  -o jsonpath='{.data.password}' | base64 --decode && echo
```
