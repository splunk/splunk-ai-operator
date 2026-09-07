# Deploy Splunk AI Platform on k0s in an Air-Gapped Environment

Use this guide to deploy Splunk AI Platform on a new k0s Kubernetes cluster.
Use this air-gapped deployment path when the cluster nodes cannot access the
internet.

This guide is for platform administrators who can manage Linux hosts, network
access, object storage, and a private container registry. For configuration
fields, architecture, and advanced operations, see
[K0S_README.md](K0S_README.md).

You are finished when:

- Every cluster node reports `Ready`.
- The `AIPlatform` resource reports `Ready`.
- The SAIA service is reachable.
- Splunk AI Assistant returns a response to a test prompt.

## In this guide

- [Before you start](#before-you-start)
- [Air-gapped deployment](#air-gapped-deployment)
- [Verify the deployment](#verify-the-deployment)
- [Connect Splunk AI Assistant](#connect-splunk-ai-assistant)
- [If installation fails](#if-installation-fails)
- [After deployment](#after-deployment)

## Before you start

Complete these checks before running an installer command.

### Confirm licenses and installation files

- Confirm that you have valid Splunk Enterprise and Splunk AI Operator
  licenses.
- Confirm that you can access the Splunk images supplied with your build and
  mirror them into the internal registry used by the disconnected cluster.
- Use Splunk Enterprise and Splunk AI Platform images from the same build. Do
  not mix versions.
- Obtain `Splunk_AI_Assistant_Cloud.tgz` from your Splunk account team if you
  plan to connect the Splunk AI Assistant app after deployment. Transfer it
  into the disconnected environment with the other installation files.

### Confirm the supported environment

| Component | Supported version or configuration |
|---|---|
| Cluster node operating system | RHEL 9 |
| k0s | Kubernetes v1.31 or later (validated on v1.36.1 with containerd 2.x) |
| GPU | NVIDIA L40S or H100 |
| NVIDIA driver | `nvidia-driver:latest-dkms` |
| NVIDIA Container Toolkit | Latest stable version |
| Splunk Enterprise | Version supplied with your Splunk AI Platform build |

Set `aiPlatform.defaultAcceleratorType` to `L40S` or `H100` in the cluster
configuration.

### Prepare the working machines

Provide a connected preparation machine and a separate air-gapped install
machine. Install the tools listed in
[Air-gap prerequisites](#air-gap-prerequisites) before building or transferring
the bundle.

### Prepare the cluster nodes

| Node type | Minimum CPU | Minimum RAM | Minimum disk | Count |
|---|---:|---:|---:|---:|
| Controller | 4 cores | 8 GB | 100 GB | 1, or 3 for high availability |
| CPU worker | 8 cores | 32 GB | 200 GB | 1 or more |
| GPU worker | 48 vCPUs | 384 GiB | 500 GB | 2 |

The validated L40S topology uses four NVIDIA L40S GPUs per GPU worker, with
48 GB of GPU memory per device. This gives eight L40S GPUs and 384 GB of GPU
memory across two workers. Each GPU worker requires 100 Gbps networking and is
equivalent to `g6e.12xlarge`.

The minimum production topology is one controller, one CPU worker, and two GPU
workers. The controller and CPU worker can share one machine for lab testing,
but this configuration is not supported for production. One GPU worker is not
enough because AI inference is distributed across both workers.

Every node also needs:

- RHEL 9.
- Python 3.8 or later.
- SSH access from the air-gapped install machine.
- Passwordless `sudo`.

### Open the required network paths

Open these ports between cluster nodes as applicable. Also allow SSH over TCP
port 22 from the air-gapped install machine to every cluster node.

| Port | Protocol | Purpose |
|---:|---|---|
| 22 | TCP | SSH management |
| 6443 | TCP | Kubernetes API server |
| 2380 | TCP | etcd peer communication |
| 10250 | TCP | Kubelet API |
| 8132 | TCP | Konnectivity agent |
| 179 | TCP | Calico BGP |
| 4789 | UDP | Calico VXLAN |
| 30000-32767 | TCP | NodePort services, when used |

### Prepare object storage

Provide an external MinIO, SeaweedFS, AWS S3, or other S3-compatible object
store. The installer does not create object storage inside the cluster. The
endpoint must be reachable from all cluster nodes and from the machine used to
stage model weights.

| Data | Minimum size | Notes |
|---|---:|---|
| Model weights in `model_artifacts/` | 250 GB | Includes more than 120 GB of models and room for restaging |
| Runtime data | 100 GB | Holds conversations, queues, and configuration |
| Recommended total bucket size | 500 GB or more | Allow more space for multiple tenants and growth |

Use a lowercase bucket name. The model staging scripts normalize bucket names
to lowercase.

### Prepare the container registry

The cluster must be able to pull all Splunk AI Platform application images from
your internal registry.

- Use `images.registryInsecure: false` for ECR, Harbor with TLS, and other HTTPS
  registries.
- Use `images.registryInsecure: true` only for a plain HTTP registry.
- Point every image field in the configuration at the correct image for your
  build.

<details>
<summary>What the installer deploys</summary>

The installer creates the k0s cluster and installs the platform components on
the customer-provided nodes.

| Location | Main components |
|---|---|
| Controller nodes | k0s API server, etcd, scheduler, and controller manager |
| CPU workers | Splunk Enterprise, Ray head, Weaviate, SAIA APIs, Data Loader, Prometheus, Grafana, and OpenTelemetry |
| GPU workers | Ray GPU workers and AI inference workloads |
| Customer object storage | Model weights and runtime data |
| Cluster infrastructure | cert-manager, MetalLB, NVIDIA device plugin, and local-path provisioner |

SAIA is the Splunk AI Assistant service. It provides the AI chat and
SPL-generation APIs used by the Splunk app.

The installer also installs the Splunk Operator, KubeRay Operator,
cert-manager, OpenTelemetry Operator, and NVIDIA Device Plugin. See
[Architecture](K0S_README.md#architecture) for component and network details.

</details>

## Air-gapped deployment

Use this path when the cluster nodes cannot access the internet.

Three machines or machine groups take part:

| Machine | Purpose |
|---|---|
| Connected preparation machine | Downloads the bundle, mirrors application images, and stages models |
| Air-gapped install machine | Runs the offline installer and connects to cluster nodes over SSH |
| Cluster nodes | Run k0s and Splunk AI Platform without internet access |

The air-gap bundle contains k0s and infrastructure images. It does not contain
the Splunk AI Platform application images or model weights. Mirror the
application images into your internal registry and upload model weights to your
object store separately.

### Air-gap prerequisites

On the connected preparation machine, install:

- `curl`
- `crane` or another container-image copy tool
- `git`
- `helm`
- `tar`
- `sha256sum` or `shasum`

On the air-gapped install machine, install:

- `curl`
- `git`
- `jq`
- `kubectl`
- `helm`
- `tar`
- `ssh`
- `sha256sum` or `shasum`

The bundle supplies `k0s` and `yq`.

The account that runs the offline wrapper must have local `sudo` or root
access so that the bundled binaries can be installed.

Before installation, confirm that:

- The internal registry is reachable from every cluster node.
- The object store is reachable from every cluster node.
- All GPU nodes have the NVIDIA driver and NVIDIA Container Toolkit installed.
- The bundle, installer scripts, and edited configuration are on the install
  machine.

### 1. Build the bundle

Run on the connected preparation machine:

```bash
git clone https://github.com/splunk/splunk-ai-operator.git
cd splunk-ai-operator/tools/cluster_setup

cp k0s-cluster-config.yaml my-cluster-config.yaml

./prepare_airgap_bundle.sh --output-dir /mnt/transfer
```

To use a specific k0s version:

```bash
./prepare_airgap_bundle.sh \
  --output-dir /mnt/transfer \
  --k0s-version v1.31.2+k0s.0
```

The command creates:

```text
/mnt/transfer/airgap-bundle-<timestamp>.tar.gz
```

The bundle is usually 2 to 4 GB. Record the file name and SHA-256 value printed
by the script.

<details>
<summary>What is in the bundle</summary>

| Directory or file | Contents |
|---|---|
| `binaries/` | k0s and yq |
| `images/k0s-images.tar` | k0s control-plane, Calico, kube-proxy, CoreDNS, and metrics-server images |
| `images/addon-images.tar` | cert-manager, Prometheus, KubeRay, MetalLB, OpenTelemetry, NVIDIA device plugin, and other add-on images |
| `manifests/` | cert-manager, local-path provisioner, and NVIDIA device plugin manifests |
| `charts/` | Prometheus, OpenTelemetry, KubeRay, and MetalLB charts |
| `packages/` | EPEL metadata, NVIDIA repository files, and the PyYAML offline artifact |
| `container-images.txt` | Application images to mirror into the internal registry |
| `bundle-versions.txt` | Versions captured when the bundle was built |
| `checksums.sha256` | Checksums verified before installation |

</details>

<details>
<summary>Why the bundle has two infrastructure image archives</summary>

`k0s-images.tar` contains images that k0s imports when the nodes start.
`addon-images.tar` contains images referenced by the included charts and
manifests. These images normally come from public registries such as
`quay.io`, `ghcr.io`, `registry.k8s.io`, `nvcr.io`, and `docker.io`.

The offline installer copies both archives to `/var/lib/k0s/images/` on each
node before k0s starts. k0s imports them into containerd, so the infrastructure
pods do not try to reach public registries.

The `images.registry` setting applies to the Splunk AI Platform application
images. It does not replace the image references used to start k0s or install
the add-ons. Both image archives and the internal application registry are
required.

</details>

### 2. Mirror the application images

The bundle script removes its temporary staging directory after creating the
archive. Extract the archive on the connected machine to retrieve
`container-images.txt`:

```bash
BUNDLE="/mnt/transfer/airgap-bundle-20260730-120000.tar.gz"
EXTRACT_DIR="$(mktemp -d)"

tar -xzf "$BUNDLE" -C "$EXTRACT_DIR"
cp "$EXTRACT_DIR"/airgap-bundle-*/container-images.txt .
```

Mirror every image in the file. This example uses `crane`:

```bash
INTERNAL_REGISTRY="registry.airgap.local"

while IFS= read -r img; do
  [[ "$img" =~ ^# ]] && continue
  [[ -z "$img" ]] && continue
  dest="${INTERNAL_REGISTRY}/${img##*/}"
  echo "Copying $img to $dest"
  crane copy "$img" "$dest"
done < container-images.txt
```

The list contains public application images. Also copy the access-controlled
Splunk, Ray, and SAIA images supplied with your build into the internal
registry.

Update every image field in `my-cluster-config.yaml`:

```yaml
images:
  registry: "registry.airgap.local"
  registryInsecure: false

  operator:
    image: "registry.airgap.local/splunk-ai-operator:<tag>"

  # Point all remaining image fields at the internal registry.

imagePullSecrets:
  autoCreateECR: false
```

Set `registryInsecure: true` only when the internal registry uses plain HTTP.

Continue when every required application image exists in the internal registry
and each configured tag can be pulled from a cluster node.

### 3. Stage the model weights

Run on a connected machine that can reach both Hugging Face and the target
object store.

| Resource | Minimum |
|---|---:|
| Free disk | 250 GB |
| RAM | 16 GB |
| CPU | 4 cores |
| Internet | Stable connection for a download larger than 120 GB |

Download the models for the target GPU type:

```bash
cd "$(git rev-parse --show-toplevel)/tools/artifacts_download_upload_scripts"

./download_from_huggingface.sh --accelerator l40s
# For H100, use: --accelerator h100
```

Upload the models:

```bash
./upload_to_minio.sh
# Or use upload_to_s3.sh or upload_to_seaweedfs.sh.
```

After the upload completes, disable automatic model staging in the cluster
configuration:

```yaml
storage:
  modelStaging:
    enabled: false
```

Continue when the model files and staging markers are present in the target
bucket.

<details>
<summary>Why model staging is separate from the bundle</summary>

The model set is larger than 120 GB and depends on the target accelerator. The
bundle contains cluster software and infrastructure images, while the model
scripts place accelerator-specific files directly in object storage.

Model staging can be resumed. The scripts skip models that are already present
and valid.

</details>

### 4. Transfer the installation files

Before transferring the configuration, fill in every field marked
`CHANGE THIS`. Confirm that it contains the internal registry values from step
2, `modelStaging.enabled: false`, the correct node IPs, object store
credentials, and MetalLB address pool.

Copy the bundle, installer scripts, and edited configuration to the air-gapped
install machine:

```bash
cd "$(git rev-parse --show-toplevel)"

BUNDLE="/mnt/transfer/airgap-bundle-20260730-120000.tar.gz"

scp "$BUNDLE" admin@install-machine:/opt/splunk-ai/

scp tools/cluster_setup/k0s_cluster_with_stack.sh \
  tools/cluster_setup/install_from_airgap_bundle.sh \
  admin@install-machine:/opt/splunk-ai/

scp tools/cluster_setup/my-cluster-config.yaml \
  admin@install-machine:/opt/splunk-ai/
```

If you plan to connect Splunk AI Assistant after deployment, transfer
`Splunk_AI_Assistant_Cloud.tgz` through the same approved process.

Use an approved physical transfer method instead of `scp` when the connected
and disconnected environments have no network path.

### 5. Prepare the GPU nodes

This step is required before running the air-gapped installer. A fully
disconnected GPU node cannot download the NVIDIA driver, DKMS dependencies, or
NVIDIA Container Toolkit. In air-gap mode, the installer stops if
`nvidia-smi` is missing.

Use the offline RPM procedure in
[GPU nodes in air-gapped environments](K0S_README.md#gpu-nodes-in-air-gapped-environments)
to install:

- `nvidia-driver:latest-dkms`
- NVIDIA Container Toolkit
- The DKMS build dependencies for the GPU node's running kernel

Run these checks on every GPU node:

```bash
dkms status | grep -i nvidia
nvidia-smi
nvidia-ctk --version
```

Continue only when all three commands succeed.

> Warning: The offline DKMS module is built for the node's running kernel. Do
> not boot the node into a different kernel unless the matching NVIDIA module
> has also been built. See the linked RPM procedure for kernel pinning.

<details>
<summary>Other GPU package strategies</summary>

Organizations with many nodes can host a local RPM mirror and point
`EPEL_RPM_URL_OVERRIDE`, `CUDA_REPO_URL_OVERRIDE`, and
`NVIDIA_CTK_REPO_URL_OVERRIDE` at that mirror.

For a partial air gap, GPU nodes can use controlled access to NVIDIA package
servers while the rest of the environment remains disconnected.

See
[GPU nodes in air-gapped environments](K0S_README.md#gpu-nodes-in-air-gapped-environments)
for both options.

</details>

### 6. Configure and run the offline installer

On the air-gapped install machine, set `cluster.airgap` in
`my-cluster-config.yaml`:

```yaml
cluster:
  name: my-cluster
  airgap: true
  sshKeyPath: ~/.ssh/id_rsa
  sshUser: ec2-user
```

Setting `airgap: true` skips connectivity checks to public services. The
wrapper also sets `AIRGAP_MODE=true`.

Run:

```bash
cd /opt/splunk-ai
chmod +x install_from_airgap_bundle.sh k0s_cluster_with_stack.sh

BUNDLE="/opt/splunk-ai/airgap-bundle-20260730-120000.tar.gz"

./install_from_airgap_bundle.sh \
  --bundle "$BUNDLE" \
  --config /opt/splunk-ai/my-cluster-config.yaml
```

Before confirming the plan, check that it reports:

```text
Air-gap mode     : true
```

Earlier in the wrapper output, confirm that it found the preloaded image
directory and listed both archives. During installation, check the session log
for:

```text
Staging image bundle k0s-images.tar on <node-ip> (/var/lib/k0s/images/)...
Staging image bundle addon-images.tar on <node-ip> (/var/lib/k0s/images/)...
```

If the installer reports `No pre-loaded image bundles in air-gap bundle`, stop
and rebuild the bundle with the current `prepare_airgap_bundle.sh`. Without
those archives, infrastructure pods can remain in `ImagePullBackOff` and nodes
can remain `NotReady`.

<details>
<summary>What the offline wrapper does</summary>

`install_from_airgap_bundle.sh`:

1. Extracts the bundle under `/opt/airgap`.
2. Verifies the included SHA-256 checksums.
3. Installs the bundled k0s and yq binaries.
4. Selects the local charts and manifests.
5. Passes the image archive directory to the main installer.
6. Runs `k0s_cluster_with_stack.sh install`.

The main installer then copies both image archives to each node after `k0s
install` creates `/var/lib/k0s`, but before k0s starts.

</details>

### 7. Verify the result

Continue to [Verify the deployment](#verify-the-deployment).

## Verify the deployment

Run from the air-gapped install machine after the installer finishes.

Set the kubeconfig:

```bash
export KUBECONFIG=~/.kube/k0s-my-cluster
```

Check the nodes:

```bash
kubectl get nodes -o wide
```

Every node must report `Ready`.

Check the platform workloads:

```bash
kubectl get pods -A --sort-by=.metadata.namespace
```

Pods should report `Running` or `Completed`. A pod can take several minutes to
start while images are imported and models are loaded.

Check the `AIPlatform` resource:

```bash
kubectl get aiplatform -n ai-platform -o wide
```

The resource must report `Ready`.

Check the SAIA service:

```bash
kubectl get svc -n ai-platform \
  -l app.kubernetes.io/component=saia
```

For a LoadBalancer service, confirm that `EXTERNAL-IP` has a value. For a
NodePort service, record the assigned node port.

Check GPU capacity:

```bash
kubectl get nodes \
  -l splunk.ai/workload-type=gpu \
  -o yaml | grep nvidia.com/gpu
```

Each GPU worker must report GPU capacity under `nvidia.com/gpu`.

If a node remains `NotReady` or the `AIPlatform` resource remains `Pending` for
more than 10 minutes, go to [If installation fails](#if-installation-fails).

<details>
<summary>Example of a healthy cluster</summary>

```text
$ kubectl get nodes
NAME          STATUS   ROLES    AGE   VERSION
controller    Ready    master   12m   v1.31.2+k0s
cpu-worker-1  Ready    <none>   10m   v1.31.2+k0s
gpu-worker-1  Ready    <none>   10m   v1.31.2+k0s
gpu-worker-2  Ready    <none>   10m   v1.31.2+k0s

$ kubectl get aiplatform -n ai-platform
NAME                    STATUS   AGE
my-cluster-ai-platform  Ready    8m
```

</details>

<details>
<summary>Where the platform components run</summary>

| Namespace | Components |
|---|---|
| `ai-platform` | `AIPlatform`, SAIA, Ray, Weaviate, Splunk Enterprise, Data Loader, and Nginx |
| `splunk-ai-operator-system` | Splunk AI Operator |
| `splunk-operator` | Splunk Operator |
| `ray-system` | KubeRay Operator |
| `cert-manager` | cert-manager |
| `kube-prometheus-stack` | Prometheus, Grafana, and Alertmanager |
| `opentelemetry-operator-system` | OpenTelemetry Operator |
| `kube-system` | NVIDIA device plugin, Calico, and local-path provisioner |
| `metallb-system` | MetalLB, when enabled |

</details>

## Connect Splunk AI Assistant

After the cluster is healthy, install `Splunk_AI_Assistant_Cloud.tgz` on the
Splunk Enterprise instance and point it at the SAIA service.

### 1. Find the Splunk Web URL

The default service uses NodePort. Find the assigned port:

```bash
kubectl get svc -n ai-platform \
  -l app.kubernetes.io/name=splunk
```

Open:

```text
http://<worker-node-ip>:<nodePort>
```

Retrieve the Splunk administrator password:

```bash
kubectl get secret splunk-standalone-secret -n ai-platform \
  -o jsonpath='{.data.password}' | base64 --decode && echo
```

> Warning: This command prints the administrator password in the terminal.
> Clear the terminal if required by your security policy. Do not paste the
> password into tickets, chat, or installation logs.

### 2. Install the app

In Splunk Web:

1. Sign in as `admin`.
2. Open `Apps > Manage Apps`.
3. Select `Install app from file`.
4. Select `Splunk_AI_Assistant_Cloud.tgz`.
5. Select `Upgrade app` only when replacing an existing version.
6. Select `Upload`.
7. Restart Splunk if prompted.

### 3. Set the AI tier endpoint

Find the SAIA port:

```bash
kubectl get svc -n ai-platform \
  -l app.kubernetes.io/component=saia
```

For a NodePort service, the `PORT(S)` column shows a value such as
`8080:30080/TCP`. The SAIA endpoint is:

```text
http://<worker-node-ip>:<nodePort>
```

In Splunk Web, open `Splunk AI Assistant > Configuration`, enter the endpoint,
and save.

### 4. Verify the app

Check the Splunk app deployment status:

```bash
kubectl get standalone splunk-standalone -n ai-platform -o json \
  | jq '.status.appContext.appSrcDeployStatus'
```

`deployStatus: 3` means the app is installed.

Open Splunk AI Assistant and send a test prompt. A returned response confirms
the path from Splunk Web to SAIA and Ray inference.

For scripted setup, an app installation without direct browser access, and app
troubleshooting, see
[Splunk AI Assistant App](K0S_README.md#splunk-ai-assistant-app).

## If installation fails

Start with these three checks. Run them from `/opt/splunk-ai` on the air-gapped
install machine.

### 1. Validate the configuration

```bash
CONFIG_FILE=/opt/splunk-ai/my-cluster-config.yaml \
  ./k0s_cluster_with_stack.sh validate
```

### 2. Check the session log

```bash
tail -100 logs/k0s-install-*.log | grep -i error
```

If you are not in the installer directory, use the full path to its `logs`
directory.

### 3. Collect a support bundle

```bash
CONFIG_FILE=/opt/splunk-ai/my-cluster-config.yaml \
  ./k0s_cluster_with_stack.sh diagnose
ls logs/splunk-ai-diagnose-*.tar.gz
```

The archive contains cluster state, Kubernetes events, pod logs, node
descriptions, `AIPlatform` status, and the installation log. Credentials and
secrets are redacted. Transfer the archive out of the disconnected environment
using an approved process before attaching it to a Splunk support case.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for fixes by error message and
symptom.

## After deployment

### Resume a partial installation

The installer can be run again after most partial failures. It skips workers
that are already joined and models that are already staged.

```bash
BUNDLE="/opt/splunk-ai/airgap-bundle-20260730-120000.tar.gz"

./install_from_airgap_bundle.sh \
  --bundle "$BUNDLE" \
  --config /opt/splunk-ai/my-cluster-config.yaml
```

> Warning: `clean-all` permanently removes all k0s state from every configured
> node. It cannot be undone. Do not use it as a routine retry step.

### Find other operations

| Task | Reference |
|---|---|
| Add or rejoin workers | [join-workers command](K0S_README.md#join-workers-command) |
| Restage missing models | [Commands](K0S_README.md#commands) |
| Configure registry credentials | [Image pull secrets](K0S_README.md#image-pull-secrets) |
| Use air-gap overrides | [Environment variable reference](K0S_README.md#environment-variable-reference) |
| Back up or restore etcd | [Backup and restore](K0S_README.md#backup-and-restore) |
| Upgrade k0s | [Upgrading k0s version](K0S_README.md#upgrading-k0s-version) |
| Diagnose a problem | [Troubleshooting](TROUBLESHOOTING.md) |

Last updated: 2026-08-09
