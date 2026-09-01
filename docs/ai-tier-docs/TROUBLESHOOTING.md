# Troubleshooting — k0s Installer (`k0s_cluster_with_stack.sh`)

Reference guide for diagnosing and fixing failures in every phase of the
Splunk AI tier k0s installer. Each section maps a concrete error message
or symptom to its root cause and resolution.

---

## Table of Contents

- [First Steps — Always Do This First](#first-steps--always-do-this-first)
- [Preflight Failures](#preflight-failures)
- [OS Compatibility Errors](#os-compatibility-errors)
- [k0s Cluster Bootstrap Failures](#k0s-cluster-bootstrap-failures)
- [Node Labeling and Join Failures](#node-labeling-and-join-failures)
- [NVIDIA Driver Install Failures](#nvidia-driver-install-failures)
- [Helm Chart Install Failures](#helm-chart-install-failures)
- [Model Staging Failures](#model-staging-failures)
- [Object Store / Credentials Failures](#object-store--credentials-failures)
- [MetalLB Failures](#metallb-failures)
- [AIPlatform CR Not Ready](#aiplatform-cr-not-ready)
- [Air-Gap Specific Failures](#air-gap-specific-failures)
- [Config File Errors](#config-file-errors)
- [Delete / Clean-All Failures](#delete--clean-all-failures)
- [General Diagnostic Commands](#general-diagnostic-commands)

---

## First Steps — Always Do This First

**1. Check the session log.** Every run writes a timestamped log:

```bash
ls -lt tools/ai-tier-cluster-setup/logs/k0s-install-*.log | head -5
# Open the most recent one and search for ERROR:
grep "ERROR" tools/ai-tier-cluster-setup/logs/k0s-install-*.log | tail -20
```

**2. Collect a support bundle.**

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh diagnose
```

This SSHs to the cluster (if reachable), collects pod logs, events, node
state, and config (credentials redacted) into a single `.tar.gz` under
`logs/`. Attach it to any support request.

**3. Validate your config before re-running.**

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate
```

Prints a ✔/✖ checklist. Fix every ✖ before re-running `install`.

**4. Re-runs are safe.** The installer is idempotent for most steps. After
fixing a root cause you can re-run `install` — it will not wipe a cluster
that has Ready nodes.

---

## Preflight Failures

### "Required tool not found: \<tool\>"

The install machine is missing a required binary.

| Tool | Install |
|---|---|
| `kubectl` | Follow [Install and Set Up kubectl on Linux](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) on the supported RHEL installer machine. |
| `helm` | Follow [Installing Helm](https://helm.sh/docs/intro/install/) on the supported RHEL installer machine. |
| `yq` | `sudo wget https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq` |
| `jq` | `sudo dnf install -y jq` |
| `ssh` | `sudo dnf install -y openssh-clients` |
| `curl` | `sudo dnf install -y curl` |

---

### "Cannot SSH to \<ip\>"

The installer cannot open an SSH connection to a node.

**Checks:**

```bash
# Test manually with the same key and user from the config
ssh -i <sshKeyPath> <sshUser>@<node-ip> echo ok

# Confirm the key file exists and has correct permissions
ls -l <sshKeyPath>      # must be 0600 or 0400
chmod 600 <sshKeyPath>

# Confirm the node is reachable at all
ping -c 3 <node-ip>

# Confirm port 22 is open
nc -zv <node-ip> 22
```

**Common causes:**

| Symptom | Fix |
|---|---|
| `Permission denied (publickey)` | Wrong SSH key or SSH user. Check `sshKeyPath` and `sshUser` in config. |
| `Connection refused` | SSH service not running on the node, or port 22 blocked by firewall/security group. |
| `Connection timed out` | Node unreachable — check routing, VPC security group (inbound TCP 22), or VPN. |
| `Host key verification failed` | Run with `-o StrictHostKeyChecking=no` manually to accept the host key, or clear `~/.ssh/known_hosts` for the node IP. |
| Works manually but fails in installer | Installer uses `BatchMode=yes` (no password prompts). Ensure key-based auth is set up and the key is not passphrase-protected (or load it into ssh-agent). |

---

### "\<node\>: passwordless sudo required"

The SSH user can log in but cannot `sudo` without a password.

```bash
# Add on the node:
echo "<ssh-user> ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/splunk-ai-install
```

---

### "Preflight failed; please fix the above and rerun"

One or more preflight checks printed `✗`. Read the lines above this message for
the specific failures, fix each one, then re-run `install`. The preflight runs
again at the start of every `install` invocation.

---

## OS Compatibility Errors

### "Unsupported OS on \<role\> \<ip\>: \<pretty-name\>"

The node is not running a supported OS.

**Supported:** RHEL 9.8, RHEL 10.2, and Ubuntu 24.04 for both air-gapped and non-air-gapped installs. Other Linux distributions are not tested or supported for cluster nodes.

**Options:**

1. Re-provision the node with a supported OS.
2. For internal testing only — bypass the check at your own risk:
   ```bash
   FORCE_UNSUPPORTED_OS=1 CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
   ```

### "RHEL 10.2 needs an offline package closure for air-gapped installs on \<role\> \<ip\>"

RHEL 10.2 keeps `xt_conntrack` and the other netfilter modules kube-proxy programs iptables with in `kernel-modules-extra` rather than the base kernel package. A sealed node cannot fetch that package itself, so a node without it joins and then sits NotReady with no way to recover offline.

Staging normally handles this: each node is probed over SSH and, for every kernel missing the module, `kernel-modules-extra` is downloaded into `packages/node-closure/`. This error means the node has neither the module nor a staged closure — usually because the bundle was pre-staged with `--download-only` and no node list, so nothing was probed. Re-stage with the node IPs, e.g.:

```bash
# Simplest: pass the cluster config — every node IP is derived from it
./airgap_install.sh --download-only --config ./my-cluster.yaml

# Configless staging: name the nodes explicitly (controllers included)
./airgap_install.sh --download-only --gpu-os rhel10 \
  --gpu-hosts <gpu-worker-ip> \
  --node-hosts <controller-ip>,<cpu-worker-ip>,<gpu-worker-ip>

# Nodes not reachable from the build host: name the kernels instead
./airgap_install.sh --download-only --gpu-os rhel10 \
  --gpu-kernels 6.12.0-124.8.1.el10_1.x86_64 \
  --node-kernels 6.12.0-124.8.1.el10_1.x86_64
```

`FORCE_UNSUPPORTED_OS=1` bypasses the check, but the install will then stop later at "xt_conntrack still unavailable" unless you have installed `kernel-modules-extra` on every node yourself.

If you are staging a RHEL 10.2 closure on purpose, run the installer itself from a **RHEL 10.2 x86_64** installer machine, not RHEL 9.8 — `dnf`'s `$releasever` comes from the installer host's own OS, so a RHEL 9.8 installer machine resolves RHEL 9 packages even when targeting RHEL 10.2 nodes. RHEL 9.8 and Ubuntu 24.04 targets are unaffected and keep using a RHEL 9.8 installer machine.

### "xt_conntrack still unavailable for kernel \<version\>"

Node preparation could not install `kernel-modules-extra` matching the node's running kernel, so kube-proxy would be unable to program a single iptables rule and every ClusterIP — including the API server's `10.96.0.1` — would be unreachable. The installer stops here rather than letting the node come up broken.

The package must match `uname -r` exactly; a build for any other kernel installs into a directory `modprobe` never searches. Either install `kernel-modules-extra-$(uname -r)` on the node from a repo that carries it, or boot a kernel that has a matching package available, then re-run the installer.

---

## k0s Cluster Bootstrap Failures

### "k0s cluster on \<controller\> has Ready nodes — refusing to wipe"

A live k0s cluster with Ready nodes was detected on the controller. The
installer refuses to overwrite it to prevent data loss.

**If you want to install fresh:**

```bash
# Tear down first — this destroys all cluster data
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh clean-all

# Then re-install
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

**If you want to reuse the existing cluster:**

Set `useExisting: auto` in `k0s-cluster-config.yaml`. The installer will skip
k0s bootstrap and go straight to deploying the AI Platform stack onto the
existing cluster.

---

### Controller API server never becomes ready

Symptom: install hangs at "Waiting for controller API server to be ready…"

```bash
# Check k0s status on the controller
ssh <ssh-user>@<controller-ip> "sudo k0s status"

# Check controller service logs
ssh <ssh-user>@<controller-ip> "sudo journalctl -u k0scontroller -n 100 --no-pager"

# Check the API health endpoint directly
ssh <ssh-user>@<controller-ip> "sudo k0s kubectl get --raw /healthz"
```

**Common causes:**

| Cause | Fix |
|---|---|
| Port 6443 blocked between nodes | Open TCP 6443 in the security group / firewall between all nodes and the controller. |
| Not enough RAM on controller | Minimum 8 GB RAM. `free -h` on the node to check. |
| Stale k0s state from a previous failed run | The installer cleans this automatically. If it persists: `ssh controller "sudo rm -rf /var/lib/k0s /run/k0s /etc/k0s && sudo systemctl daemon-reload"` then re-run. |
| Clock skew between nodes | etcd rejects nodes with >5 min clock drift. Run `chronyc tracking` or `timedatectl` on all nodes and sync NTP. |

---

### "Failed to generate worker token from controller"

The controller is up but the installer cannot get a join token for workers.

```bash
ssh <ssh-user>@<controller-ip> "sudo k0s status"
ssh <ssh-user>@<controller-ip> "sudo k0s token create --role=worker"
```

If `k0s status` shows the controller is running but `token create` fails,
the k0s API may still be initializing. Wait 30 seconds and re-run install.

---

## Node Labeling and Join Failures

### "Some workers failed to install/start"

One or more worker nodes could not install or start k0s.

```bash
# Check worker service on the failing node
ssh <ssh-user>@<worker-ip> "sudo systemctl status k0sworker"
ssh <ssh-user>@<worker-ip> "sudo journalctl -u k0sworker -n 100 --no-pager"
```

**Common causes:**

| Cause | Fix |
|---|---|
| Worker cannot reach controller :6443 | Open TCP 6443 from worker to controller in security group. |
| Stale k0s worker state | `ssh worker "sudo k0s stop; sudo rm -rf /var/lib/k0s /run/k0s"` then re-run. |
| k0s binary not found on worker | Ensure `curl` is available so the installer can download it, or pre-install k0s. |
| Disk full on worker | `df -h /var/lib/k0s` — minimum 200 GB free for CPU workers, 500 GB for GPU workers. |

After fixing, rejoin workers without a full reinstall:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh join-workers
```

---

### "Not all workers joined! Expected N nodes, but only M joined"

The k0s workers started but did not appear in `kubectl get nodes` within the
timeout.

```bash
# From the controller
ssh <ssh-user>@<controller-ip> "sudo k0s kubectl get nodes"

# On a non-joined worker
ssh <ssh-user>@<worker-ip> "sudo systemctl status k0sworker"
ssh <ssh-user>@<worker-ip> "sudo journalctl -u k0sworker -n 50 --no-pager | grep -i error"
```

The install continues after this warning. You can manually add the missing
workers later:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh join-workers
```

---

### "Nodes still unlabeled after recovery pass"

The node registered in the API server but could not be labeled
(`splunk.ai/workload-type=cpu` or `=gpu`).

```bash
kubectl get nodes --show-labels
kubectl label node <node-name> splunk.ai/workload-type=<cpu|gpu> --overwrite
```

---

## NVIDIA Driver Install Failures

### "AIRGAP_MODE=true but NVIDIA driver (nvidia-smi) not found"

In air-gap mode, the installer cannot download GPU packages from the internet.
The normal air-gap flow builds an offline RPM or `.deb` driver closure during
staging and installs it on each GPU node automatically. This error means the
closure was not staged or the node could not install it. Re-run without
`--skip-nvidia-closure` and check the staging log. Pre-install NVIDIA drivers
only when intentionally using the optional `--skip-nvidia-closure` path.

See [K0S_README.md — GPU Nodes in Air-Gapped Environments](K0S_README.md#gpu-nodes-in-air-gapped-environments) for
the closure requirements and the optional pre-installed-driver path.

---

### "N/M GPU node(s) had NVIDIA install failures. Aborting install."

The NVIDIA driver or nvidia-container-toolkit install failed on at least one
GPU node. The installer prints the full per-node log above this message.

**Diagnostic commands to run on the failing GPU node:**

```bash
# DKMS — must show 'installed' for the nvidia module
ssh <ssh-user>@<gpu-ip> "dkms status | grep nvidia"

# Kernel module loaded
ssh <ssh-user>@<gpu-ip> "lsmod | grep nvidia"

# Runtime library
ssh <ssh-user>@<gpu-ip> "ls /usr/lib64/libnvidia-ml.so.1"

# Container toolkit
ssh <ssh-user>@<gpu-ip> "nvidia-ctk --version"

# CDI device list
ssh <ssh-user>@<gpu-ip> "sudo cat /etc/cdi/nvidia.yaml | head -40"

# Kernel messages
ssh <ssh-user>@<gpu-ip> "sudo dmesg | grep -i nvidia | tail -30"

# Package status
ssh <ssh-user>@<gpu-ip> "rpm -q epel-release dkms kernel-devel"
```

**Common causes:**

| Cause | Fix |
|---|---|
| `kernel-devel` version does not match running kernel | The node must be running a kernel that has a matching `kernel-devel` package. Reboot the node to the latest installed kernel (`sudo reboot`) then re-run. |
| EPEL or DKMS did not install | Check `rpm -q epel-release dkms`. If missing, install manually: `sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && sudo dnf install -y dkms` |
| Stale CUDA repo from a prior OS upgrade | Remove old repo files: `sudo rm /etc/yum.repos.d/cuda-rhel*.repo` then re-run. |
| SELinux blocking nvidia-container-toolkit | `sudo getenforce` — if Enforcing, check `sudo ausearch -m avc -ts recent` for denials. |
| GPU not present / not recognized | `lspci | grep -i nvidia` — must show the GPU. Check the hypervisor/instance type. |

---

### "NVIDIA driver install failed on at least one GPU node; aborting install"

Same as above — this is the fatal abort that fires from the Phase 1 parallel
installer. Check per-node logs printed above it and follow the steps in the
section above.

---

### "Device plugin DaemonSet is installed but no GPUs are visible after Ns"

The NVIDIA device plugin is running but Kubernetes cannot allocate any GPU.

```bash
# Check device plugin pods
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds

# Check pod logs
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds --tail=50

# Check node allocatable
kubectl get nodes -o json | jq '.items[].status.allocatable | select(."nvidia.com/gpu")'

# Verify nvidia-smi on the node
ssh <ssh-user>@<gpu-ip> "nvidia-smi"
```

**Common causes:**

| Cause | Fix |
|---|---|
| `NVML: ERROR_LIBRARY_NOT_FOUND` in plugin logs | NVIDIA driver or runtime not installed correctly on the node. Re-run the NVIDIA install section above. |
| `NVML: ERROR_DRIVER_NOT_LOADED` | Reboot the GPU node to load the kernel module: `ssh <gpu-node> "sudo reboot"` |
| Device plugin pod in `CrashLoopBackOff` | Check logs for the specific error. Usually a missing library — re-run NVIDIA driver install. |

---

### GPU workloads do not schedule

Confirm that Kubernetes advertises the GPU, then inspect the target node's
taints and the pending pod's tolerations and events:

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
kubectl describe node <gpu-node> | grep -A3 Taints
kubectl describe pod <pod-name> -n ai-platform
kubectl get pod <pod-name> -n ai-platform -o yaml | grep -A5 tolerations
```

`Insufficient nvidia.com/gpu` means the requested GPU capacity is unavailable.
A taint-related scheduling event means the workload's tolerations or the node's
k0s workload labels do not match the configured GPU scheduling policy.

---

## Helm Chart Install Failures

### "Helm failed after N attempts"

A `helm upgrade --install` command failed after retries.

```bash
# Show what Helm releases are currently deployed
helm list -A

# Show release history for the failing chart
helm history <release-name> -n <namespace>

# Get the last failure reason
helm status <release-name> -n <namespace> --show-desc
```

**Common causes:**

| Cause | Fix |
|---|---|
| Image pull failure | The chart deployed but pods cannot pull images. Check `kubectl describe pod <pod> -n <ns>` for `ErrImagePull`. Verify your registry URL and image pull secret. |
| CRD not yet installed | Some charts require CRDs to exist first. Re-running install usually resolves it (installer applies CRDs before charts). |
| Namespace stuck in Terminating | `kubectl get ns <name>` — if Terminating, manually remove the finalizer: `kubectl patch ns <name> -p '{"spec":{"finalizers":[]}}' --type=merge` |
| Chart not found in local air-gap bundle | Check that `PROMETHEUS_CHART_PATH` / `OTEL_CHART_PATH` / etc. point to existing `.tgz` files. |

---

### Timeout waiting for CRD \<name\>

```bash
kubectl get crd <crd-name>
kubectl describe crd <crd-name>

# Check if the operator that installs this CRD is running
kubectl get pods -A | grep -i <operator-name>
```

If the CRD is missing entirely, the operator pod likely failed to start. Check
its pod logs:

```bash
kubectl logs -n <operator-namespace> deploy/<operator-name> --tail=50
```

---

## Model Staging Failures

### Models are reported MISSING after upload

The configured bucket may not exist, may be empty, may differ from the bucket
used during upload, or may lack the expected completion markers. Use lowercase
bucket names so the configured name and object-store paths remain unambiguous.

```bash
# MinIO
mc ls myminio/<bucket>/staging_state/
mc ls myminio/<bucket>/model_artifacts/

# AWS S3
aws s3api head-bucket --bucket <bucket>
aws s3 ls s3://<bucket>/staging_state/
aws s3 ls s3://<bucket>/model_artifacts/
```

After correcting the bucket or credentials, stage the required artifacts and
completion markers again:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts
```

---

### Switching `defaultAcceleratorType` from L40S to H100 reports models as MISSING

This is expected. L40S selects the unquantized artifact profile, while H100
selects the quantized profile. Gemma uses different artifact IDs and object-store
prefixes in those profiles, and the completion marker must match the selected
artifact URL.

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts
```

---

### `stage-artifacts` fails because `yq` cannot parse the profile

Install the pinned `yq` release used by the installer, confirm it can parse the
selected artifact profile, and then rerun staging:

```bash
sudo wget -qO /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
yq eval '.' ../artifacts_download_upload_scripts/model_artifacts_configs_unquantized.yaml
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts
```

---

### Re-stage one model without restarting every download

Remove only that model's completion marker, then rerun staging. The installer
will retain completed models and process the missing one.

```bash
# MinIO
mc rm myminio/<bucket>/staging_state/<model-id>/.staging_complete

# AWS S3
aws s3 rm s3://<bucket>/staging_state/<model-id>/.staging_complete

CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh stage-artifacts
```

---

### "Hugging Face download failed"

```bash
# Re-run with verbose output
cd tools/artifacts_download_upload_scripts
bash -x ./download_from_huggingface.sh 2>&1 | tee /tmp/hf-download.log
```

> `HF_TOKEN` is not required for the current release. If you see authentication errors on gated models in a future release, set it via `HF_TOKEN=hf_... ./download_from_huggingface.sh`.

**Common causes:**

| Cause | Fix |
|---|---|
| Disk full on staging machine | Minimum 250 GB free. `df -h .` to check. |
| Interrupted download | Set `SKIP_IF_EXISTS=1` to resume without re-downloading completed files. |
| Network timeout on large files | Use a stable wired connection. The script is restartable — re-run with `SKIP_IF_EXISTS=1`. |

To skip model staging entirely (if models are already in the object store):

```yaml
# In k0s-cluster-config.yaml:
storage:
  modelStaging:
    enabled: false
```

---

### "Upload to MinIO/S3/SeaweedFS failed"

```bash
# Verify the object store endpoint is reachable from the staging machine
curl -v <objectStore.endpoint>

# For MinIO — check credentials
mc alias set mystore <endpoint> <rootUser> <rootPassword>
mc ls mystore/<bucket>
```

**Common causes:**

| Cause | Fix |
|---|---|
| Wrong endpoint URL | `storage.objectStore.endpoint` must include scheme and port, e.g. `http://10.0.0.5:9000`. For AWS S3, leave endpoint empty. |
| SeaweedFS uses port 8333, not 9000 | Update endpoint: `http://<host>:8333` |
| Bucket does not exist | Create it: `mc mb mystore/<bucket>` |
| Credentials wrong | Check `objectStore.auth.rootUser` and `rootPassword` in config. |

---

## Object Store / Credentials Failures

### "storage.objectStore.auth contains template placeholders"

The config still has `<CHANGE ME>` placeholders in the object store credentials.

```bash
grep -n "CHANGE\|<" my-cluster.yaml
```

Replace all placeholder values with real credentials before re-running.

---

### "storage.objectStore.type=X requires storage.objectStore.endpoint"

Add the endpoint URL to your config:

```yaml
storage:
  objectStore:
    type: minio       # or seaweedfs
    endpoint: "http://10.0.0.5:9000"
```

For `type: aws`, leave `endpoint` unset — the AWS SDK derives it from
`AWS_REGION`.

---

### "minio-credentials missing and cannot be created"

The Kubernetes Secret `minio-credentials` does not exist and the config still
has placeholder credentials. Fix the credentials in your config YAML and re-run.

```bash
# If you want to create the secret manually instead:
kubectl create secret generic minio-credentials \
  -n ai-platform \
  --from-literal=rootUser=<user> \
  --from-literal=rootPassword=<password>
```

---

### "Unsupported objectStore.type: X"

Valid values for `storage.objectStore.type` are: `aws`, `minio`, `seaweedfs`.
Check for typos in your config.

---

## MetalLB Failures

### "metallb.install=true but metallb.pool.addresses is empty"

```yaml
# Add at least one IP range routable on your LAN:
metallb:
  install: true
  mode: layer2
  pool:
    addresses:
      - "10.20.30.2.0-10.20.30.2.0"   # free IPs on your network
```

---

### "metallb.mode must be 'layer2' or 'bgp'"

Check `metallb.mode` in your config for typos.

---

### MetalLB BGP peer config missing

```yaml
metallb:
  mode: bgp
  bgpPeers:
    - peerAddress: "10.0.0.1"
      peerASN: 65001
      myASN: 65000
```

Every peer must have all three fields: `peerAddress`, `peerASN`, `myASN`.

---

### SAIA / SLIM service has no external address or is unreachable

```bash
SERVICE="<cluster-name>-ai-platform-saia-saia-service"
# In case of SLIM use below
SERVICE="<cluster-name>-ai-platform-slim-slim-service"
kubectl get svc "${SERVICE}" -n ai-platform -o wide
kubectl describe svc "${SERVICE}" -n ai-platform

# Show the configured exposure type, port, NodePort, and LoadBalancer address
kubectl get svc "${SERVICE}" -n ai-platform \
  -o custom-columns='TYPE:.spec.type,PORT:.spec.ports[0].port,NODEPORT:.spec.ports[0].nodePort,ADDRESS:.status.loadBalancer.ingress[0].ip'

# If TYPE is LoadBalancer and ADDRESS is empty, check MetalLB:
kubectl logs -n metallb-system deploy/controller --tail=50
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

**Common causes:**

| Cause | Fix |
|---|---|
| Service not found | Replace `<cluster-name>` with the `cluster.name` value from your config. The expected service is `<cluster-name>-ai-platform-saia-saia-service` (or) `<cluster-name>-ai-platform-slim-slim-service` in namespace `ai-platform`. |
| IP pool exhausted | Add more addresses to `metallb.pool.addresses`. |
| IP range not routable | The addresses must be IPs that your LAN router will route to the node. ARP-based (layer2) requires IPs on the same subnet as the node. |
| MetalLB controller not running | Check `kubectl get pods -n metallb-system`. |
| Service type is `NodePort`, not `LoadBalancer` | No `EXTERNAL-IP` is expected. Use the `NODEPORT` shown above with a worker-node IP, or set `aiPlatform.serviceTemplate.type` to `LoadBalancer` to use MetalLB. |
| Service type is `ClusterIP` | No external address is expected. Use `kubectl port-forward svc/${SERVICE} 8080:8080` and access `http://127.0.0.1:8080`. |

---

## AIPlatform CR Not Ready

### PVC remains Pending

Check the claim, its StorageClass, and the local-path provisioner before
investigating the application pod:

```bash
kubectl get pvc -n ai-platform
kubectl describe pvc <pvc-name> -n ai-platform
kubectl get storageclass
kubectl get pods -n local-path-storage
kubectl logs -n local-path-storage deployment/local-path-provisioner
```

The provisioner must be running, and the PVC must reference an installed
StorageClass. For a non-default CSI driver, confirm that its controller and node
components are healthy.

---

### AIPlatform stuck in `Pending` or `Reconciling`

```bash
kubectl describe aiplatform -n ai-platform
kubectl get events -n ai-platform --sort-by='.lastTimestamp' | tail -30

# Operator logs
kubectl logs -n splunk-ai-operator-system \
  deploy/splunk-ai-operator-controller-manager --tail=100
```

---

### AI services not starting (Ray, SAIA, SLIM service, Weaviate)

```bash
# List all non-Running pods
kubectl get pods -A | grep -v "Running\|Completed"

# Describe a failing pod
kubectl describe pod <pod-name> -n <namespace>

# Check pod logs (and previous container if it crashed)
kubectl logs <pod-name> -n <namespace> --tail=100
kubectl logs <pod-name> -n <namespace> --previous --tail=100
```

**Common causes:**

| Cause | Fix |
|---|---|
| `ImagePullBackOff` / `ErrImagePull` | Image tag wrong or not pushed to registry. Check `images.*` fields in config. Verify `imagePullSecrets` is configured. |
| `Pending` with `Insufficient nvidia.com/gpu` | GPU nodes have no allocatable GPUs. Check [NVIDIA Device Plugin section](#nvidia-driver-install-failures). |
| `Pending` with no GPU nodes scheduled | GPU nodes may not have the `splunk.ai/workload-type=gpu` label. `kubectl get nodes --show-labels` |
| Ray workers stuck in `Init` | Ray head pod not ready. Check Ray head pod logs first. |
| Weaviate `CrashLoopBackOff` | Check object store connectivity. Weaviate uses the object store for persistence. |

---

### "Timed out waiting for AIService \<name\>"

```bash
kubectl get aiservice -n ai-platform
kubectl describe aiservice <name> -n ai-platform
kubectl get pods -n ai-platform -l aiservice=<name>
```

The timeout is 10 minutes per AIService. If the service is still starting,
re-run the installer — it will detect the existing cluster and skip bootstrap.

---

## Air-Gap Specific Failures

### "Checksum verification failed"

A staged artifact was truncated or corrupted mid-download.

```bash
# Re-verify the staged tree against its own manifest
cd ./airgap-bundle/airgap-bundle-<timestamp>
sha256sum --check checksums.sha256 --quiet
```

Delete the staging directory and re-run the install
(`CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install`) — with
`cluster.airgap: true` it re-stages the artifacts automatically.

---

### "Expected chart not found" / wrong chart filename

Helm sometimes uses underscores instead of dashes in filenames.

```bash
ls ./airgap-bundle/airgap-bundle-*/charts/
```

Set the path explicitly:

```bash
export PROMETHEUS_CHART_PATH="./airgap-bundle/airgap-bundle-<date>/charts/kube-prometheus-stack-72.3.0.tgz"
```

---

### "Cannot reach get.k0s.sh" on nodes

In air-gap mode, k0s must already be installed on nodes OR the staged k0s
binary is used. Check that `cluster.airgap: true` is set in your config (or
`AIRGAP_MODE=true` in the environment) — that is what makes `install` stage the
artifacts and set `K0S_INSTALL_URL` automatically. If the install log does not
open with `Air-gap mode — staging artifacts before install`, the mode switch did
not take effect.

---

### python3-pyyaml missing on nodes in air-gap mode

Air-gap staging sets `AIRGAP_PYYAML_WHEEL_PATH` automatically from the staged
`packages/` directory. If you are driving the installer against an
already-staged tree, set it manually:

```bash
export AIRGAP_PYYAML_WHEEL_PATH="./airgap-bundle/airgap-bundle-<date>/packages/PyYAML-6.0.2-cp39-cp39-linux_x86_64.whl"
export AIRGAP_STAGED=true    # already staged — don't re-download
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

---

### GPU driver install fails in air-gap mode

See [K0S_README.md — GPU Nodes in Air-Gapped Environments](K0S_README.md#gpu-nodes-in-air-gapped-environments).
Air-gap staging builds an offline NVIDIA RPM closure and the installer
pushes it to each GPU node. If you would rather manage drivers out of band,
pre-install them on the GPU nodes and stage via
`./airgap_install.sh --skip-nvidia-closure --config <cfg>` — the installer
detects `nvidia-smi` and skips the driver install entirely.

---

## Config File Errors

### "Config file not found: \<path\>"

```bash
export CONFIG_FILE=./my-cluster.yaml
# or pass it inline:
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh install
```

---

### "Config file has YAML syntax errors"

```bash
# Validate YAML syntax
yq eval '.' my-cluster.yaml

# Common issue: unquoted special characters, missing colons, wrong indentation
```

---

### "REQUIRED: images.\<field\> must be specified"

One or more image fields are empty or still show placeholder values.

```bash
# Find all image fields that need filling
grep -n "CHANGE\|<\|image:$\|image: \"\"" my-cluster.yaml
```

Required fields: `images.operator.image`, `images.splunk.image`,
`images.ray.headImage`, `images.ray.workerImage`, `images.weaviate.image`,
`images.saia.apiImage`, `images.saia.apiV2Image`, `images.saia.dataLoaderImage`
`images.slim.apiImage`.

---

### `validate` subcommand shows ✖ items

Run `validate` before every install:

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh validate
```

Fix every ✖ item (errors) before proceeding. ⚠ items (warnings) are
non-blocking but should be reviewed.

---

## Delete / Clean-All Failures

### "useExisting=force but cluster name mismatch"

The cluster name in your config does not match the context name of the cluster
the installer found. This is a safety guard.

Either update `cluster.name` in your config to match, or if you are certain
you want to proceed:

```bash
# Force the operation despite the mismatch
# (only use if you are sure you are targeting the right cluster)
CONFIG_FILE=./my-cluster.yaml \
  ./k0s_cluster_with_stack.sh delete
```

---

### clean-all hangs or leaves nodes in bad state

```bash
# Manually stop k0s on each node
ssh <user>@<controller> "sudo k0s stop; sudo k0s reset"
ssh <user>@<worker1>    "sudo k0s stop; sudo k0s reset"
ssh <user>@<worker2>    "sudo k0s stop; sudo k0s reset"

# Remove k0s data
for node in <controller> <worker1> <worker2>; do
  ssh <user>@${node} "sudo rm -rf /var/lib/k0s /run/k0s /etc/k0s"
done
```

---

## General Diagnostic Commands

### Cluster health

```bash
kubectl get nodes -o wide
kubectl get pods -A --sort-by='.metadata.namespace'
kubectl get events -A --sort-by='.lastTimestamp' | tail -40
kubectl top nodes
```

### AI Platform resources

```bash
kubectl get aiplatform,aiservice -n ai-platform
kubectl describe aiplatform -n ai-platform
kubectl logs -n splunk-ai-operator-system \
  deploy/splunk-ai-operator-controller-manager --tail=100 | grep -E "ERROR|WARN|error"
```

### GPU node state

```bash
# GPU allocatable
kubectl get nodes -l splunk.ai/workload-type=gpu \
  -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

# GPU usage
kubectl exec -n ai-platform <ray-worker-pod> -- nvidia-smi

# Device plugin
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds --tail=30
```

### Installer logs

```bash
# Most recent session log
ls -lt tools/ai-tier-cluster-setup/logs/ | head -5

# Tail live during a run
tail -f tools/ai-tier-cluster-setup/logs/k0s-install-$(date '+%Y-%m-%d')*.log

# Search for errors across all logs
grep -h "ERROR" tools/ai-tier-cluster-setup/logs/k0s-install-*.log | sort | uniq -c | sort -rn
```

### Collect and send a support bundle

```bash
CONFIG_FILE=./my-cluster.yaml ./k0s_cluster_with_stack.sh diagnose
ls -lh tools/ai-tier-cluster-setup/logs/splunk-ai-diagnose-*.tar.gz | tail -1
```
