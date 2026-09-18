# Deploy Splunk AI Platform on k0s in an Internet-Connected Environment

Use this guide to deploy Splunk AI Platform on a new k0s Kubernetes cluster.
Use this non-air-gapped deployment path when the admin workstation and every
cluster node can access the required internet services.

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
- [Internet-connected deployment](#internet-connected-deployment)
- [Verify the deployment](#verify-the-deployment)
- [Connect Splunk AI Assistant](#connect-splunk-ai-assistant)
- [If installation fails](#if-installation-fails)
- [After deployment](#after-deployment)

## Before you start

Complete these checks before running an installer command.

### Confirm licenses and installation files

- Confirm that you have valid Splunk Enterprise and Splunk AI Operator
  licenses.
- Confirm that you can pull the Splunk images supplied with your build from
  the required private registry.
- Use Splunk Enterprise and Splunk AI Platform images from the same build. Do
  not mix versions.
- Obtain `Splunk_AI_Assistant_Cloud.tgz` from your Splunk account team if you
  plan to connect the Splunk AI Assistant app after deployment.

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

### Prepare the admin workstation

Install these tools on the machine that will run the installer:

- `kubectl`
- `helm`
- `git`
- `jq`
- `yq`
- `ssh`

Check the installed versions:

```bash
kubectl version --client
helm version
git --version
jq --version
yq --version
ssh -V
```

See [Required tools](K0S_README.md#required-tools-on-admin-workstation) for
installation commands.

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
- SSH access from the admin workstation.
- Passwordless `sudo`.

### Open the required network paths

Open these ports between cluster nodes as applicable. Also allow SSH over TCP
port 22 from the admin workstation to every cluster node.

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

The admin workstation and cluster nodes must also be able to reach the
repository, package, container-image, and model sources used by the installer.

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
your registry.

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

## Internet-connected deployment

Use this path when every cluster node can access the internet.

### Expected duration

| Phase | Typical duration | Notes |
|---|---:|---|
| Preflight | 1 to 2 minutes | Validates the configuration and SSH access |
| Model staging | 2 to 6 hours | Downloads more than 120 GB from Hugging Face |
| Cluster bootstrap | 10 to 20 minutes | Installs k0s and prepares GPU nodes |
| Platform installation | 15 to 30 minutes | Installs charts and creates platform resources |
| First installation with model staging | About 3 to 7 hours | Most of the time is model download |
| Installation with models already staged | About 30 to 60 minutes | Set `modelStaging.enabled: false` |

### 1. Get the repository

Run on the admin workstation:

```bash
git clone https://github.com/splunk/splunk-ai-operator.git
cd splunk-ai-operator/tools/cluster_setup
```

Continue when the current directory contains
`k0s_cluster_with_stack.sh` and `k0s-cluster-config.yaml`.

### 2. Create the cluster configuration

Copy the template:

```bash
cp k0s-cluster-config.yaml my-cluster.yaml
vi my-cluster.yaml
```

Fill in every field marked `CHANGE THIS`.

| Section | What to set |
|---|---|
| `cluster` | Cluster name, SSH private key path, and SSH user |
| `cluster.airgap` | Set to `false` |
| `nodes.existingIPs` | Controller and worker IP addresses |
| `storage.objectStore` | Storage type, endpoint, bucket, and credentials |
| `images.registry` | Registry hostname |
| `images.registryInsecure` | `true` only for a plain HTTP registry |
| `images` | Image names and tags supplied with your build |
| `aiPlatform.defaultAcceleratorType` | `L40S` or `H100` |
| `metallb.pool.addresses` | Unused LAN address range for LoadBalancer services |

Do not commit `my-cluster.yaml`. It contains storage and registry credentials.

See [Configuration reference](K0S_README.md#configuration-reference) for every
field and example.

<details>
<summary>Why the configuration asks for node roles</summary>

The installer labels each worker for CPU or GPU workloads. Splunk Enterprise,
the Ray head, Weaviate, SAIA, and the Data Loader run on CPU workers. Ray
inference workloads run on GPU workers. The labels keep these workloads on the
correct hardware.

</details>

### 3. Validate the configuration

Run from `tools/cluster_setup`:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate
```

Validation is read-only. It checks the configuration, required tools, SSH
access, node operating systems, disk space, registry access, and object storage
settings.

Continue only when validation reports no failures.

### 4. Run the installer

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

The installer displays its plan before making changes. Review the node IPs,
roles, cluster name, object store, and registry. Confirm that the plan reports
air-gap mode as `false`, then continue only when all values are correct.

<details>
<summary>What happens during installation</summary>

The installer:

1. Runs preflight checks on the admin workstation and every node.
2. Downloads and uploads model weights when model staging is enabled.
3. Installs k0s on the controller and workers.
4. Labels the worker nodes.
5. Installs the NVIDIA driver and Container Toolkit on GPU workers when needed.
6. Installs the cluster operators and supporting services.
7. Creates the Splunk Enterprise and `AIPlatform` resources.
8. Waits for the platform workloads and prints access information.

Model staging can be resumed. A later run skips models that are already in
object storage.

</details>

### 5. Monitor installation

The installer writes progress to the terminal and a session log. From a second
terminal in `tools/cluster_setup`, run:

```bash
tail -f logs/k0s-install-*.log
```

The model download can run for several hours. Do not interrupt the installer
while it is configuring k0s or joining workers.

### 6. Verify the result

Continue to [Verify the deployment](#verify-the-deployment).

## Verify the deployment

Run from the admin workstation after the installer finishes.

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
start while images are pulled and models are loaded.

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

Start with these three checks. Run them from `tools/cluster_setup` on the admin
workstation.

### 1. Validate the configuration

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate
```

### 2. Check the session log

```bash
tail -100 logs/k0s-install-*.log | grep -i error
```

If you are not in the installer directory, use the full path to its `logs`
directory.

### 3. Collect a support bundle

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh diagnose
ls logs/splunk-ai-diagnose-*.tar.gz
```

The archive contains cluster state, Kubernetes events, pod logs, node
descriptions, `AIPlatform` status, and the installation log. Credentials and
secrets are redacted. Attach the archive when opening a Splunk support case.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for fixes by error message and
symptom.

## After deployment

### Resume a partial installation

The installer can be run again after most partial failures. It skips workers
that are already joined and models that are already staged.

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

> Warning: `clean-all` permanently removes all k0s state from every configured
> node. It cannot be undone. Do not use it as a routine retry step.

### Find other operations

| Task | Reference |
|---|---|
| Add or rejoin workers | [join-workers command](K0S_README.md#join-workers-command) |
| Restage missing models | [Commands](K0S_README.md#commands) |
| Configure registry credentials | [Image pull secrets](K0S_README.md#image-pull-secrets) |
| Back up or restore etcd | [Backup and restore](K0S_README.md#backup-and-restore) |
| Upgrade k0s | [Upgrading k0s version](K0S_README.md#upgrading-k0s-version) |
| Diagnose a problem | [Troubleshooting](TROUBLESHOOTING.md) |

Last updated: 2026-08-09
