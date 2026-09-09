# OpenShift Deployment — Quick Reference

Quick reference for installing Splunk AI Tier (AI POD) on an existing
OpenShift cluster. For requirements, configuration details, and architecture,
see [openshift-readme.md](openshift-readme.md). For diagnosis and recovery,
see [openshift-troubleshooting.md](openshift-troubleshooting.md).

## Table of Contents

1. [Step 1: Confirm prerequisites](#step-1-confirm-prerequisites)
2. [Step 2: Confirm minimum worker capacity](#step-2-confirm-minimum-worker-capacity)
3. [Step 3: Prepare the configuration](#step-3-prepare-the-configuration)
4. [Step 4: Install the platform](#step-4-install-the-platform)
   - [Standard deployment](#standard-deployment)
   - [Air-gapped deployment](#air-gapped-deployment)
5. [Step 5: Verify and access the platform](#step-5-verify-and-access-the-platform)
6. [Step 6: Connect the Splunk apps](#step-6-connect-the-splunk-apps)
7. [Step 7: Operate and troubleshoot](#step-7-operate-and-troubleshoot)

---

## Step 1: Confirm prerequisites

The installer deploys AI POD onto an existing cluster. It does not create,
upgrade, or remove OpenShift.

**OpenShift cluster:**

- At least one worker that meets the AI-tier capacity requirements
- Cluster-admin access
- A reachable image registry and supported object store

**Qualified compatibility matrix:**

| Installer machine OS | Installation type | Qualified OpenShift node OS | OpenShift version |
|---|---|---|---|
| macOS 26.5.2 | Standard only | Red Hat Enterprise Linux CoreOS 9.6.20260407-0 (Plow) `amd64` | 4.21.x |
| RHEL 9.8 `amd64` | Standard and air-gapped | Red Hat Enterprise Linux CoreOS 9.6.20260407-0 (Plow) `amd64` | 4.21.x |
| RHEL 10.2 `amd64` | Standard and air-gapped | Red Hat Enterprise Linux CoreOS 9.6.20260407-0 (Plow) `amd64` | 4.21.x |

Air-gapped installation requires Linux because Red Hat `oc-mirror` v2 is
Linux-only. The installer machine also requires:

- Network access to the OpenShift API, image registry, and object store
- Access to Hugging Face when model staging is enabled and a model is missing
- Hugging Face credentials when model staging must download a missing gated
  model

**Required tools:**

- OpenShift CLI (`oc`)
- Mike Farah `yq` v4.48.1
- Helm v3+
- `curl`, `jq`, `base64`, GNU `timeout`, Python 3.8 or later, and `tar`
- MinIO client (`mc`) for MinIO, SeaweedFS, or generic S3-compatible storage
- AWS CLI only for AWS S3 or automatic Amazon ECR authentication
- `oc-mirror` v2 only for an air-gapped deployment

Run the examples in a Bash-compatible shell. Verify the common tools:

```bash
for tool in oc yq helm curl jq base64 tar timeout python3; do
  command -v "$tool" >/dev/null || echo "MISSING: $tool"
done

oc version --client
yq --version
helm version
jq --version
```

For an air-gapped deployment, verify that `oc-mirror` is installed and supports
v2. Use a build compatible with OpenShift 4.21:

```bash
oc-mirror --v2 version --output=yaml
```

Set the kubeconfig and confirm the exact permission checked by the installer:

```bash
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/openshift}"
test -f "$KUBECONFIG"
oc whoami
# Expected: the authenticated OpenShift user, for example system:admin

oc whoami --show-server
# Expected: the intended cluster API URL, for example
# https://api.<cluster-domain>:6443

oc auth can-i create clusterrolebinding --all-namespaces
```

The final command must print `yes`.

---

## Step 2: Confirm minimum worker capacity

The qualified minimum deployment uses one shared AI-tier worker node for CPU
and GPU workloads. That node requires at least:

| Resource | Minimum requirement |
|---|---:|
| System RAM | 256 GiB |
| Available workload disk | 1 TiB (1024 GiB) |
| GPU | 2 × NVIDIA RTX PRO 6000 Blackwell, 96 GB VRAM each |
| CPU | 64 allocatable vCPU |

The supported accelerator profile is `RTX_PRO_6000_BLACKWELL`; other GPU models
or equivalent aggregate VRAM configurations are not qualified for this
workflow. When more than one AI-tier node is selected, CPU and GPU workloads
still share one node pool. The 1 TiB disk requirement applies separately to
every selected AI-tier node and means usable capacity available immediately
before installation, including the filesystems backing `/var/lib/containers`
and `/opt/local-path-provisioner`. A nominal 1-TB drive provides less than
1024 GiB and does not meet this requirement. GPU capacity cannot be combined
across nodes to satisfy one pod; a Ray worker requesting two GPUs must fit on
one node with two GPUs available.

Installer preflight verifies available space on the filesystem containing
`/var/lib/containers`, or `/` when that directory is absent, on every selected
AI-tier node. It does not separately measure `/opt/local-path-provisioner` when
that path uses another filesystem. It also does not verify the required CPU,
system RAM, physical GPU model, GPU count, or GPU memory; the customer must
confirm those capacities before installation.

The object store is separate from worker storage and must be provisioned
independently.

---

## Step 3: Prepare the configuration

Download the installer files on the installer machine using one of these
methods.

<details>
<summary><strong>Option 1: Setup via Git (Recommended)</strong></summary>

Clone the supplied release branch or tag:

```bash
git clone --branch <release-branch-or-tag> --single-branch \
  https://github.com/splunk/splunk-ai-operator.git
cd splunk-ai-operator/tools/ai-tier-cluster-setup
```

</details>

<details>
<summary><strong>Option 2: Setup via Browser ZIP Download</strong></summary>

For a branch, download:

```text
https://github.com/splunk/splunk-ai-operator/archive/refs/heads/<release-branch>.zip
```

For a tag, download:

```text
https://github.com/splunk/splunk-ai-operator/archive/refs/tags/<release-tag>.zip
```

Alternatively, select the supplied branch or tag on GitHub, then choose
**Code > Download ZIP**. Extract the archive and open the setup directory:

```bash
cd <extracted-directory>/tools/ai-tier-cluster-setup
```

</details>

From `tools/ai-tier-cluster-setup`, create an environment-specific
configuration:

```bash
cp openshift-cluster-config.yaml my-openshift-cluster-config.yaml
export CONFIG_FILE="$PWD/my-openshift-cluster-config.yaml"
chmod 600 "$CONFIG_FILE"
```

Replace `<release-branch-or-tag>` with the version supplied for the deployment.
If the repository already exists, check out and update that version before
copying the template.

Edit the copy and confirm these settings:

| Setting | Required decision |
|---|---|
| `cluster.airgap` | `false` for standard; `true` for air-gapped |
| `kubernetes.namespace` | Dedicated AI POD workload namespace; default `ai-platform` |
| `openshift.nodeLabelStrategy` | `manual` for listed nodes or `auto` for all workers |
| `openshift.nodes` | Exact AI-tier worker names when strategy is `manual` |
| `openshift.routes.saia.enabled` | Create the HTTP SAIA Route |
| `openshift.routes.slim.enabled` | Create the HTTP SLIM Route |
| `images.*` | Tagged application and supporting images available to the cluster; use the [release-default image table](openshift-readme.md#image-pull-secrets-and-registry-access) |
| `images.registryInsecure` | Defaults to `true` for a plain-HTTP registry; set `false` for Amazon ECR, Docker Hub, Harbor, or another trusted HTTPS registry |
| `storage.storageClass` | Existing class, or `local-path` managed by the installer |
| `storage.objectStore.*` | Type, bucket, endpoint where required, and credentials |
| `storage.modelStaging.enabled` | Stage missing models from the installer when `true` |
| `splunk.trustedIssuers` | Additional legitimate JWT issuer URLs, when required |
| `aiPlatform.scaleFactor` | Global workload scale; keep `1` for the minimum deployment |
| `ecr.enabled` | Enable only when the workload registry is Amazon ECR |

See the [full configuration reference](openshift-readme.md#configuration-reference)
for field behavior and supported values.

The only supported accelerator profile for this OpenShift workflow is:

```yaml
aiPlatform:
  defaultAcceleratorType: "RTX_PRO_6000_BLACKWELL"
```

Validate the configuration before installation:

```bash
./openshift_with_stack.sh validate
```

`validate` checks the configuration without changing the cluster. `install`
also runs runtime preflight checks and stops before platform installation when
they fail.

---

## Step 4: Install the platform

Choose the section that matches the target environment.

### Standard deployment

Use this path when the installer can reach the external manifest and Helm
sources and the OpenShift cluster can reach the configured catalogs and
registries.

Set:

```yaml
cluster:
  airgap: false
```

Install:

```bash
./openshift_with_stack.sh install
```

The installer runs preflight, stages missing models when enabled, installs the
operators and platform, waits for readiness, and prints the SAIA and SLIM URLs.

### Air-gapped deployment

Use this path when OpenShift nodes have no public internet access. The Linux
installer machine must still reach the public content sources, the OpenShift
API, the internal registry, and the object store while preparing the install.

Before starting:

- Provide sufficient installer-machine disk space for the generated air-gap
  content and `oc-mirror` working files. This local staging space is separate
  from the destination registry, which retains the mirrored images. Generated
  local files remain until they are removed manually. Required capacity depends
  on the selected catalog content and versions; see the
  [air-gap installer host requirements](openshift-readme.md#installer-host-requirements).
- Put every application image configured under `images.*` in the internal
  registry and use those internal image references in the configuration.
- Configure credentials that let `oc-mirror` pull source content and push to
  `images.registry`.
- Ensure all required models are already in the object store, or enable model
  staging and allow the installer machine to reach Hugging Face.

Set:

```yaml
cluster:
  airgap: true
```

Run:

```bash
./openshift_with_stack.sh install
```

The installer uses `oc-mirror` to copy the OpenShift installation dependencies
into `images.registry`. These dependencies include the selected Node Feature
Discovery and NVIDIA GPU Operator packages and their related images, plus the
cert-manager, Local Path Provisioner, KubeRay Operator, OpenTelemetry Operator,
UBI helper, and OpenShift Driver Toolkit images. The installer then applies the
generated mirror policies and internal CatalogSources and continues the normal
installation. Application images configured under `images.*` and model
artifacts remain separate customer-provided content. Do not run a separate
manual bundle workflow.

---

## Step 5: Verify and access the platform

Read the configured names and verify the workload resources:

```bash
export AI_NAMESPACE="$(yq eval '.kubernetes.namespace // "ai-platform"' "$CONFIG_FILE")"
export AI_PLATFORM_NAME="$(yq eval '.aiPlatform.name // "openshift-ai-platform"' "$CONFIG_FILE")"

oc get aiplatform,aiservice,raycluster,rayservice -n "$AI_NAMESPACE"
oc get pods -n "$AI_NAMESPACE" -o wide
./openshift_with_stack.sh verify-pods
```

Print the default external endpoints:

The commands below require both `openshift.routes.saia.enabled: true` and
`openshift.routes.slim.enabled: true` in the configuration.

```bash
SAIA_HOST="$(oc get route saia -n "$AI_NAMESPACE" -o jsonpath='{.spec.host}')"
SLIM_HOST="$(oc get route slim -n "$AI_NAMESPACE" -o jsonpath='{.spec.host}')"
printf 'SAIA: http://%s\n' "$SAIA_HOST"
printf 'SLIM: http://%s/tenant/slim-api/v1alpha1\n' "$SLIM_HOST"
```

The supported Routes use HTTP. HTTPS Route TLS and workload mutual TLS are not
configured by this installer. Ray dashboard diagnostics are documented in
[openshift-troubleshooting.md](openshift-troubleshooting.md#raycluster-or-rayservice-does-not-become-ready).

If the SAIA Route is disabled, the documented browser-based Splunk AI Assistant
connection is unavailable. If the SLIM Route is disabled, Splunk AI Toolkit
cannot use the documented SLIM endpoint.

---

## Step 6: Connect the Splunk apps

Use the following versions for this release:

| Component | Version |
|---|---|
| Splunk Enterprise | 10.2 |
| Splunk AI Assistant | 2.3.2 |
| Splunk AI Toolkit | 6.1.0 |

These are the Splunk-side versions documented for this AI POD release. They are
separate from the platform container-image versions listed in the
[release-default image table](openshift-readme.md#image-pull-secrets-and-registry-access).

AI POD supports two Splunk integration choices: a bundled Splunk Standalone or
an existing externally managed Splunk Enterprise deployment. Use the procedure
for the selected choice and ensure its network access and JWT issuer are
configured correctly.

### Open installer-deployed Splunk Web

Run these commands on the machine where Splunk Web will be opened. This can be
the installer machine or another administrative workstation with `oc`, the
same kubeconfig and configuration file, and access to the OpenShift API. Set
`KUBECONFIG`, `CONFIG_FILE`, and `AI_NAMESPACE` in that shell. The port-forward
listens on that machine's localhost.

Use this section when the bundled Splunk Standalone option is deployed. The
port-forward provides local access to its Splunk Web interface.

Retrieve the generated password:

```bash
STANDALONE_NAME="$(yq eval '.splunk.standaloneName // "splunk-standalone"' "$CONFIG_FILE")"
SPLUNK_SECRET="splunk-${STANDALONE_NAME}-standalone-secret-v1"
oc get secret "$SPLUNK_SECRET" -n "$AI_NAMESPACE" \
  -o jsonpath='{.data.password}' \
  | python3 -c 'import base64, sys; print(base64.b64decode(sys.stdin.buffer.read()).decode())'
```

Forward Splunk Web:

```bash
SPLUNK_SERVICE="splunk-${STANDALONE_NAME}-standalone-service"
oc port-forward -n "$AI_NAMESPACE" "svc/$SPLUNK_SERVICE" 18001:8000
```

Open `http://localhost:18001` and log in as `admin`.

### Splunk AI Assistant

1. Install [Splunk AI Assistant](https://splunkbase.splunk.com/app/7245)
   version 2.3.2.
2. Open **Splunk AI Assistant** to start the onboarding wizard. On **Getting
   started**, select **AI tier** and click **Next**.
3. On **Configure SOK and Splunk AI Assistant**, enter the full Splunk AI
   Assistant Route printed in [Step 5](#step-5-verify-and-access-the-platform)
   in **Splunk AI Assistant Service URL**, then click **Complete Setup**.
4. Send a prompt and confirm a model response. A successful response verifies
   that the browser can reach the Route and that SAIA is responding.

### Splunk AI Toolkit

1. Install the
   [platform-appropriate Python for Scientific Computing app](https://splunkbase.splunk.com/collections/machine_learning).
2. Install [Splunk AI Toolkit](https://splunkbase.splunk.com/app/2890)
   version 6.1.0.
3. Create a **Splunk AI tier** endpoint connection as described in the
   [full setup procedure](openshift-readme.md#install-and-configure-splunk-ai-toolkit).
4. For both installer-deployed and external Splunk, use the SLIM Route printed
   in [Step 5](#step-5-verify-and-access-the-platform).
5. Confirm that models appear, create a named Splunk AI tier LLM connection,
   and run the post-install `ai` and `apply CDTSM` verification searches in
   [openshift-readme.md](openshift-readme.md#install-and-configure-splunk-ai-toolkit).

---

## Step 7: Operate and troubleshoot

For symptom-based diagnosis and recovery procedures, see the
[OpenShift Troubleshooting Guide](openshift-troubleshooting.md).

### Scale the deployment

`aiPlatform.scaleFactor` increases model replica counts and corresponding GPU
worker groups. It does not provision hardware. Ensure sufficient CPU, memory,
GPU, and storage capacity before increasing it.

| `scaleFactor` | System RAM | Available workload disk per selected AI-tier node | GPU | CPU |
|---:|---:|---:|---:|---:|
| `1` | 256 GiB | 1 TiB | 2 × NVIDIA RTX PRO 6000 Blackwell, 96 GB each | 64 allocatable vCPU |
| `2` | 512 GiB | 2 TiB | 4 × NVIDIA RTX PRO 6000 Blackwell, 96 GB each | 128 allocatable vCPU |

Run commands from `tools/ai-tier-cluster-setup` with the `CONFIG_FILE` exported
in Step 3:

| Operation | Command |
|---|---|
| Validate the configuration | `./openshift_with_stack.sh validate` |
| Reconcile the installation | `./openshift_with_stack.sh install` |
| Verify platform readiness | `./openshift_with_stack.sh verify-pods` |
| Create a support bundle | `./openshift_with_stack.sh diagnose` |
| Stage missing or changed models | `./openshift_with_stack.sh stage-artifacts` |
| Remove installer-owned AI POD resources | `./openshift_with_stack.sh clean-all` |

> [!IMPORTANT]
> Use a dedicated namespace for AI POD. If the installer created the namespace,
> `clean-all` deletes the namespace and everything later added to it. If the
> namespace existed before installation, `clean-all` preserves the namespace
> but removes the configured AIPlatform, Splunk Standalone, SAIA and SLIM
> Routes, and installer-created configuration. The OpenShift cluster and its
> nodes are not removed.

Start with:

```bash
oc get aiplatform,aiservice,raycluster,rayservice -n "$AI_NAMESPACE"
oc get pods -n "$AI_NAMESPACE" -o wide
./openshift_with_stack.sh diagnose
```

The `diagnose` command prints the exact support-bundle path. Review the bundle
for operationally sensitive content before sharing it.

---

*Quick reference — see [openshift-readme.md](openshift-readme.md) for the full
deployment guide.*
