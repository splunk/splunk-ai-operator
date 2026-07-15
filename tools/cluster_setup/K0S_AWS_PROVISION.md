# k0s AWS Provisioner — Design & Ops Guide

## Purpose

`k0s_aws_provision.sh` creates EC2 infrastructure in an existing VPC for use by
`k0s_cluster_with_stack.sh`. It is a standalone helper: it launches instances,
attaches EBS data volumes, installs MinIO, copies cluster scripts, and
auto-patches `my-k0s-config.yaml` on the installer. No changes to the k0s
installer script itself.

---

## End-to-End Workflow

### Step 1 — Authenticate

```bash
eval "$(okta-aws-login -a splunkcloud-ai-dev \
  --role-arn arn:aws:iam::658391232643:role/splunkcloud_account_admin)"

aws sts get-caller-identity   # verify
```

### Step 2 — Dry-run (free validation)

```bash
./k0s_aws_provision.sh dry-run --config k0s-aws-provision-config-prod.yaml
```

Confirms AMI, subnet selection, instance sizes, and state-file path — no
resources created.

### Step 3 — Provision infrastructure

```bash
./k0s_aws_provision.sh provision --config k0s-aws-provision-config-prod.yaml
```

Takes ~10 min. When it completes, the installer EC2 has:
- SSH key copied to `~/.ssh/id_rsa`
- All cluster scripts in `~/cluster_setup/`
- `~/cluster_setup/my-k0s-config.yaml` pre-patched with node IPs, MinIO
  endpoint/credentials, `storage.modelStaging.enabled: true`, and absolute
  `sshKeyPath`
- MinIO running at `http://<private-ip>:9000`
- `~/artifacts_download_upload_scripts/model_artifacts` → symlinked to
  `/data/minio/model_artifacts` so model downloads land on the 500 GB disk

### Step 4 — Add Docker Hub credentials (required for private images)

The AI Platform uses `splunk/ray-head-build-preview:latest` (private Docker Hub).
Before running install, add your Docker Hub pull secret:

```bash
EIP=<installer-eip>
KEY=~/.ssh/k0s-ai-platform.pem

ssh -i "$KEY" ec2-user@$EIP 'bash -s' <<'EOF'
export KUBECONFIG=/var/lib/k0s/pki/admin.conf   # set after k0s is installed

# Create imagePullSecret in the ai-platform namespace
kubectl create secret docker-registry dockerhub-pull-secret \
  --namespace ai-platform \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<DOCKERHUB_USER> \
  --docker-password=<DOCKERHUB_TOKEN>
EOF
```

Then add to `my-k0s-config.yaml` on the installer before running install:

```yaml
imagePullSecrets:
  - name: dockerhub-pull-secret
```

Or configure credentials in `my-k0s-config.yaml` before provisioning so
`push_k0s_config` picks them up on the next run.

### Step 5 — Run k0s install (from installer)

```bash
ssh -i ~/.ssh/k0s-ai-platform.pem ec2-user@<EIP>

# On the installer:
cd ~/cluster_setup
SILENT_INSTALL=true CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml \
  ./k0s_cluster_with_stack.sh install
```

`SILENT_INSTALL=true` skips all interactive prompts — the config values are
used as-is. Monitor progress:

```bash
tail -f ~/k0s-install.log
```

Install phases (in order):
1. **Preflight** — SSH reachability, disk space, tool checks on all nodes
2. **Model staging** — downloads models from HuggingFace → uploads to MinIO
3. **k0s cluster** — installs k0s on controller + workers
4. **Phase 1 (parallel)** — cert-manager, kube-prometheus-stack, NVIDIA drivers
5. **Phase 2 (parallel)** — OTel, KubeRay, Splunk operator, NVIDIA device plugin
6. **MetalLB** — skipped (NodePort mode); only runs if `metallb.install: true`
7. **Splunk Standalone + AI Platform operator + CR**
8. **Health check** — verifies all pods running

Typical total time: ~2–3 hr (model staging is the longest phase).

### Step 6 — Verify cluster

```bash
# From installer, SSH to controller
ssh -i ~/.ssh/id_rsa ec2-user@<controller-private-ip>

sudo k0s kubectl get nodes
sudo k0s kubectl get pods -A
sudo k0s kubectl get aiplatform,aiservice -n ai-platform
```

The AI Platform service is exposed at:
```
http://<any-worker-ip>:30080
```

### Step 7 — Destroy when done

```bash
./k0s_aws_provision.sh destroy --config k0s-aws-provision-config-prod.yaml --yes
```

---

## Network Modes

The script has two network modes selected automatically from `network.vpcId`:

| `network.vpcId` | Mode | What happens |
|---|---|---|
| Set to an existing VPC ID | **Existing VPC** | Uses that VPC; subnets auto-selected by Name tag or pinned explicitly |
| Empty (`""`) | **Auto-create** *(UNTESTED)* | Creates VPC + IGW + public subnet + NAT GW + private subnet |
| *(omitted, region=us-west-2)* | **Existing VPC** | Defaults to `vpc-09b191e89c83d588e` (ai-platform-us-west-2-vpc) |

**splunkcloud-ai-dev account:** SCP blocks new-VPC creation. Keep the default
VPC or pin an existing one. Auto-create mode will fail in that account.

### Subnet selection in Existing VPC mode

Two subnets are needed:
- **k0s nodes** — private subnet (NAT outbound only)
- **installer** — public subnet (IGW route + EIP for inbound SSH)

These can be auto-selected by Name tag or pinned:

```yaml
network:
  vpcId: vpc-09b191e89c83d588e
  subnetId: subnet-0289f96100d496522        # k0s nodes — private, NAT outbound
  installerSubnetId: subnet-0561d78f4f4744596  # installer — public, IGW + EIP
```

> **Important:** `subnetId` (k0s nodes) and `installerSubnetId` (installer) can
> be in **different AZs**. The provisioner derives each volume's AZ from its
> instance's subnet — this is required when GPU capacity is only available in
> certain AZs while the only public subnet is in us-east-2a.

### GPU capacity — AZ fallback

`g6e.12xlarge` (and other GPU types) are frequently exhausted in specific AZs.
The provisioner automatically tries all private subnets in the VPC in order
until a launch succeeds:

```
Trying gpu-worker-0 in subnet-019bce74ffb1432c1 (us-east-2a) ... no capacity
Trying gpu-worker-0 in subnet-04f0616cd035b0b2d (us-east-2b) ... Launched!
```

No config change needed — just set `subnetId` to your preferred AZ and the
script falls back automatically.

---

## Architecture

```
VPC: vpc-0dff3bdadac92320c  (ai-platform-us-east-2-vpc)
│
├── Public Subnet: subnet-05185a5939b6ebf05  (10.0.39.240/28, us-east-2a)
│     Route: 0.0.0.0/0 → Internet Gateway
│     │
│     └── Installer  (t3.large, 50 GB root, 500 GB /data/minio)
│           └── Elastic IP ← SSH from your laptop
│
└── Private Subnets (all share route: 0.0.0.0/0 → nat-0930d686f6af3f8d2)
      │
      ├── us-east-2a  subnet-019bce74ffb1432c1  (10.0.38.0/25)
      │     ├── k0s Controller   (m6i.2xlarge, 100 GB root)
      │     └── k0s CPU Worker   (m6i.4xlarge, 200 GB root)
      │
      └── us-east-2b  subnet-04f0616cd035b0b2d  (10.0.38.128/25)
            └── k0s GPU Workers  (g6e.12xlarge, 100 GB root + 500 GB /var/lib/k0s)

Security Group  <stackName>-sg
  Inbound:  all traffic from same SG  ← private-IP k0s comms
  Inbound:  TCP 22 from sshAllowedCidr ← laptop → installer EIP
  Outbound: all 0.0.0.0/0
```

**Why two subnets?**
The installer needs inbound SSH via an Elastic IP — requires a public subnet
(IGW route). The k0s nodes only need outbound internet (for k0s + NVIDIA
packages) via NAT — no inbound required. Private placement minimises attack
surface.

**EBS mount timing:**
Data volumes are attached *after* instances boot. The provisioner SSHes to each
instance post-attach to format (XFS) and mount — more reliable than UserData,
which runs before the volume is present. The fstab entry uses UUID (not device
path) so it survives kernel upgrades that renumber NVMe devices.

---

## SCP Compliance (splunkcloud-ai-dev account)

All API calls satisfy SCP `p-m68tib3s` on account `658391232643`:

| Requirement | How it's met |
|---|---|
| IMDSv2 required | All `run-instances` calls include `--metadata-options HttpTokens=required,HttpEndpoint=enabled` |
| EBS encryption | All volumes (root + data) include `Encrypted=true` |
| No new VPCs | Uses existing VPC (us-west-2: `vpc-09b191e89c83d588e`, us-east-2: `vpc-0dff3bdadac92320c`) |

---

## Script Commands

```bash
# Deploy stack
./k0s_aws_provision.sh provision [--config FILE]

# Print copy-paste block for k0s-cluster-config.yaml
./k0s_aws_provision.sh output    [--config FILE]

# Show instance states and MinIO health
./k0s_aws_provision.sh status    [--config FILE]

# Tear down everything (interactive)
./k0s_aws_provision.sh destroy   [--config FILE]

# Non-interactive destroy (CI / automation)
./k0s_aws_provision.sh destroy   [--config FILE] --yes

# Dry-run: print plan without creating resources
./k0s_aws_provision.sh dry-run   [--config FILE]
```

---

## Config File Reference

### Mandatory fields

```yaml
stackName: my-k0s-infra
region: us-east-2
availabilityZone: us-east-2a
```

### Full reference

```yaml
stackName: k0s-ai-platform
region: us-east-2
# AZ for controller, CPU worker, and installer.
# GPU workers use AZ fallback — they try all private subnets until one has capacity.
availabilityZone: us-east-2a
sshAllowedCidr: "0.0.0.0/0"

network:
  vpcId: vpc-0dff3bdadac92320c   # ai-platform-us-east-2-vpc
  subnetId: subnet-019bce74ffb1432c1        # k0s nodes (private)
  installerSubnetId: subnet-05185a5939b6ebf05  # installer (public, IGW + EIP)
  # CIDRs used only in auto-create mode (vpcId: ""):
  vpcCidr: "10.0.0.0/16"
  publicSubnetCidr: "10.0.1.0/24"
  privateSubnetCidr: "10.0.2.0/24"

keyPair:
  name: ""        # empty = auto-create "<stackName>-key"
  localPath: ""   # empty = save to ~/.ssh/<stackName>.pem

nodes:
  controller:
    count: 1
    instanceType: m6i.2xlarge   # 8 vCPU, 32 GB RAM
    diskGb: 100

  cpuWorker:
    count: 1
    instanceType: m6i.4xlarge   # 16 vCPU, 64 GB RAM
    diskGb: 200

  gpuWorker:
    count: 2
    instanceType: g6e.12xlarge  # 4× NVIDIA L40S, 192 GB RAM
    diskGb: 100
    dataDiskGb: 500             # separate EBS, mounted at /var/lib/k0s

installer:
  instanceType: t3.large
  diskGb: 50

minio:
  enabled: true
  dataDiskGb: 500               # separate EBS on installer, mounted at /data/minio
  bucket: ai-platform
  rootUser: minioadmin
  rootPassword: ""              # empty = auto-generate (printed in output)
  port: 9000
```

---

## What `provision` Does Internally

1. Validate AWS credentials (`aws sts get-caller-identity`)
2. Look up RHEL 9 AMI (`describe-images --owners 309956199498`)
3. **If `network.vpcId` empty:** create VPC + IGW + subnets + NAT GW *(UNTESTED)*
4. **If `network.vpcId` set:** use existing VPC; pick subnets by Name tag or config
5. Resolve `INSTALLER_AZ` from `installerSubnetId` (may differ from `availabilityZone`)
6. Create or reuse SSH key pair; save `.pem` to `keyPair.localPath`
7. Create security group (SG-to-SG ingress + SSH from `sshAllowedCidr`)
8. Launch controller + CPU worker instances into `subnetId`
9. Launch GPU workers with AZ fallback (tries all private subnets in VPC until capacity found)
10. Launch installer into `installerSubnetId`
11. Wait for all instances to reach `running`
12. Attach encrypted EBS data volumes:
    - GPU workers: `dataDiskGb` → `/var/lib/k0s` (using per-worker subnet AZ)
    - Installer: `minio.dataDiskGb` → `/data/minio` (using `INSTALLER_AZ`)
13. Allocate and associate Elastic IP to installer
14. Wait for SSH on installer (direct via EIP)
15. Wait for SSH on all k0s nodes (via installer ProxyCommand jump)
16. Check NAT outbound connectivity on each k0s node (3 endpoints)
17. Mount data disks via SSH (detect device, format XFS, add UUID fstab entry, mount)
18. Install prerequisites on installer (yq, kubectl, helm, jq, git)
19. Copy `~/cluster_setup/` scripts and `~/artifacts_download_upload_scripts/` to installer
20. If `minio.enabled`: symlink `artifacts_download_upload_scripts/model_artifacts` →
    `/data/minio/model_artifacts` (prevents root disk fill during large model downloads)
21. If `minio.enabled`: run `install_minio_ec2.sh` on installer
22. Patch `~/cluster_setup/my-k0s-config.yaml` (see below)
23. Print `output` block

---

## `my-k0s-config.yaml` — What Gets Patched

`provision` patches a fixed set of infrastructure fields into
`~/cluster_setup/my-k0s-config.yaml` on the installer using `yq`. It never
overwrites the whole file.

| Situation | What happens |
|---|---|
| `my-k0s-config.yaml` **exists** | Backed up as `*.bak-<timestamp>.yaml`, then patched in-place |
| `my-k0s-config.yaml` **does not exist** | `k0s-cluster-config.yaml` (already copied) used as base, then patched |

### Fields patched automatically

```yaml
cluster:
  name:       <stackName>-cluster
  region:     <region>
  sshKeyPath: /home/ec2-user/.ssh/id_rsa   # absolute path — required for preflight
  sshUser:    ec2-user

nodes:
  existingIPs:
    controllers:
      - <controller private IP>
    workers:
      - <cpu-worker IPs>
      - <gpu-worker IPs>

storage:
  modelStaging:
    enabled: true                            # enables HuggingFace download + MinIO upload
  minimumDiskSpace:
    controller: 90                           # actual available on 100 GB root (~6 GB OS overhead)
    cpuWorker: 190                           # actual available on 200 GB root
  objectStore:                               # only when minio.enabled: true
    type:         minio
    bucket:       <minio.bucket>
    endpoint:     http://<installer-private-ip>:<port>
    auth:
      rootUser:     <minio.rootUser>
      rootPassword: <generated or configured>
```

### Fields you own (preserved)

`images`, `operators`, `aiPlatform`, `metallb`, `imagePullSecrets`, `splunk`,
`kubernetes`, `storage.storageClass`, `storage.vectorDbSize`, tolerations,
node selectors — all untouched.

---

## State File

After `provision`, all created resource IDs are saved to:
```
~/.k0s-provision-<stackName>.state
```
Plain `key=value` bash, sourced by `output`, `status`, and `destroy`. Re-running
`provision` with an existing state file prompts for confirmation.

---

## What `destroy` Does

1. Confirmation: type stack name (interactive) or pass `--yes`
2. Terminate all instances in parallel
3. Wait for `instance-terminated`
4. Release Elastic IP
5. Delete data EBS volumes (GPU + MinIO)
6. Delete security group (auto-created only)
7. Delete AWS key pair (auto-created) + optionally delete local `.pem`
8. **If auto-create network was used:** reverse-teardown VPC stack *(UNTESTED)*
9. Remove state file

---

## Known Issues & Workarounds

### Docker Hub private image pull

**Symptom:** RayCluster pods in `ImagePullBackOff`:
```
Failed to pull image "splunk/ray-head-build-preview:latest":
  pull access denied, repository does not exist or may require authorization
```

**Fix:** Create an `imagePullSecret` with Docker Hub credentials and add it to
`my-k0s-config.yaml` before running install:

```yaml
# In my-k0s-config.yaml
imagePullSecrets:
  - name: dockerhub-pull-secret
```

```bash
kubectl create secret docker-registry dockerhub-pull-secret \
  --namespace ai-platform \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<USER> \
  --docker-password=<TOKEN>
```

---

### NVIDIA DKMS build fails after kernel upgrade

**Symptom:** Install fails with:
```
ERROR: nvidia DKMS module is not installed/built.
NVIDIA driver install failed on <ip>
```

**Root cause:** Running kernel version does not match installed `kernel-devel`.
Common after `dnf update` installs a new kernel but the instance is still booted
on the old one — or if the RHEL AMI ships with a kernel that has no matching
`kernel-devel` in the RHUI repos yet.

**Fix:** Update the kernel to match the available `kernel-devel`, set it as
default, and reboot:

```bash
# Find available kernel-devel version
dnf list available kernel-devel

# Install matching kernel and reboot
sudo dnf install -y kernel-5.14.0-687.25.1.el9_8 kernel-devel-5.14.0-687.25.1.el9_8
sudo grubby --set-default /boot/vmlinuz-5.14.0-687.25.1.el9_8.x86_64
sudo reboot
```

After reboot, re-run `k0s_cluster_with_stack.sh install` — already-staged
models are skipped, and the install resumes from the NVIDIA phase.

---

### GPU capacity exhausted (InsufficientInstanceCapacity)

**Symptom:**
```
InsufficientInstanceCapacity: We currently do not have sufficient g6e.12xlarge
capacity in us-east-2a. Try us-east-2b, us-east-2c.
```

**Behaviour:** The provisioner automatically retries all private subnets in the
VPC in order. No action needed — it will find an AZ with capacity. EBS data
volumes are created in each GPU worker's actual subnet AZ.

If all AZs are exhausted, retry after a few minutes or use a different instance
type.

---

### Root disk fills during model staging

**Symptom:** Model download fails mid-way:
```
write .../model_artifacts/...: no space left on device
```

**Root cause:** The installer root disk is 50 GB; large models (gemma-4-31b-it
~62 GB, gpt-oss-20b ~40 GB) exceed it.

**Fix (automatic since v2):** The provisioner symlinks
`artifacts_download_upload_scripts/model_artifacts` →
`/data/minio/model_artifacts` on the 500 GB MinIO EBS volume. All downloads
land there automatically.

If you hit this on an older provision, run on the installer:
```bash
mkdir -p /data/minio/model_artifacts
rm -rf ~/artifacts_download_upload_scripts/model_artifacts
ln -sfn /data/minio/model_artifacts ~/artifacts_download_upload_scripts/model_artifacts
```
Then re-run install — completed models are skipped via `.staging_complete` markers.

---

### EBS data disk unmounted after reboot

**Symptom:** After rebooting a GPU node (e.g. for kernel update), preflight
reports `<N> GB available — need at least 500 GB on /var/lib/k0s`.

**Root cause (old):** fstab entry used device path (`/dev/nvme1n1`). Kernel
upgrades can renumber NVMe devices (`nvme1n1` → `nvme2n1`).

**Fix (automatic since v2):** fstab entries now use UUID:
```
UUID=<uuid> /var/lib/k0s xfs defaults,nofail 0 2
```

If you have an old entry, fix manually:
```bash
DATA_DEV=$(lsblk -ndo NAME,FSTYPE,MOUNTPOINT | awk '$2=="xfs" && $3=="" {print "/dev/"$1}')
UUID=$(sudo blkid -s UUID -o value "$DATA_DEV")
sudo sed -i '/\/var\/lib\/k0s/d' /etc/fstab
echo "UUID=$UUID /var/lib/k0s xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount /var/lib/k0s
```

---

## AWS Authentication

```bash
eval "$(okta-aws-login -a splunkcloud-ai-dev \
  --role-arn arn:aws:iam::658391232643:role/splunkcloud_account_admin)"

aws sts get-caller-identity   # verify
```

The provisioner calls `aws sts get-caller-identity` at startup and exits with a
clear error if credentials are missing or expired. Sessions expire after ~1 hr —
re-run the `okta-aws-login` command if you see `ExpiredToken`.

---

## Test Plan

### Level 1 — Dry-run (free)

```bash
./k0s_aws_provision.sh dry-run --config k0s-aws-provision-config.yaml
```

### Level 2 — Cheap end-to-end (~$1, ~15 min)

```bash
./k0s_aws_provision.sh provision --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh status    --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh output    --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh destroy   --config k0s-aws-provision-config-test.yaml --yes
```

`k0s-aws-provision-config-test.yaml` uses `t3.medium/small` instances. Validates
all provisioning logic (SCP compliance, EBS attach, MinIO, SSH jump, config
patching) without GPU cost.

### Level 3 — Full GPU integration (~$130, ~4 hr)

```bash
# 1. Provision
./k0s_aws_provision.sh provision --config k0s-aws-provision-config-prod.yaml

# 2. Add Docker Hub pull secret (see Known Issues above)

# 3. SSH to installer (EIP printed in output)
ssh -i ~/.ssh/k0s-ai-platform.pem ec2-user@<EIP>

# 4. Run install
cd ~/cluster_setup
SILENT_INSTALL=true CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml \
  ./k0s_cluster_with_stack.sh install

# 5. Destroy when done
./k0s_aws_provision.sh destroy --config k0s-aws-provision-config-prod.yaml --yes
```

---

## Cost Summary

### Level 2 test (~1 hr)

| Resource | $/hr | 1-hr cost |
|---|---|---|
| 3× t3.medium + 1× t3.small | $0.04–0.05 | ~$0.17 |
| EBS (8–50 GB) | negligible | <$0.01 |
| RHEL 9 subscription | $0.10/instance | ~$0.30 |
| **Total** | | **~$0.50** |

### Level 3 production (~4 hr)

| Resource | $/hr | 4-hr cost |
|---|---|---|
| 2× g6e.12xlarge | ~$16/hr | ~$128 |
| 1× m6i.2xlarge controller | ~$0.38/hr | ~$1.52 |
| 1× m6i.4xlarge CPU worker | ~$0.77/hr | ~$3.08 |
| 1× t3.large installer | ~$0.08/hr | ~$0.32 |
| EBS, RHEL subscription, transfer | | ~$5 |
| **Total** | | **~$138** |

---

## Development History — What Failed and What Fixed It

### 1. CloudFormation blocked by SCP

**What happened:** All `aws cloudformation deploy` stacks failed with `CREATE_FAILED`.

**Root cause:** SCP `p-m68tib3s` (`PreventRunInstanceWithNoIMDSv2AllowModify`)
denies `ec2:RunInstances` unless `ec2:MetadataHttpTokens = required`.
CloudFormation's `AWS::EC2::Instance` resource has no way to pass
`--metadata-options`. Decoded via `aws sts decode-authorization-message`.

**Fix:** Rewrote to use direct `aws ec2 run-instances` with
`--metadata-options HttpTokens=required,HttpEndpoint=enabled`.

---

### 2. VPC not found — must use existing VPC

**Root cause:** SCP also restricts VPC creation in the account. The
`ai-platform-us-west-2-vpc` is the only permitted VPC.

**Fix:** Removed all VPC creation. Added `network.vpcId` config key (defaulting
to the shared VPC).

---

### 3. `set -e` killed on `[[ ! -f ]]` outside `if`

**Root cause:** `[[ ! -f FILE ]] && warn` — the `[[` returns exit 1 when the
file exists (condition is false), which `set -e` treats as a script error.

**Fix:** All such patterns changed to `if [[ ! -f FILE ]]; then warn; fi`.

---

### 4. Installer in private subnet — EIP not reachable

**Fix:** Added `installerSubnetId` config key. Installer goes in the public
subnet (IGW route); k0s nodes stay in private (NAT only).

---

### 5. SSH jump `-J` dropped the key on macOS

**Root cause:** macOS `-J` does not forward `-i KEY` to the jump hop.

**Fix:** Replaced with explicit `ProxyCommand`:
```bash
-o "ProxyCommand=ssh -i KEY -o StrictHostKeyChecking=no -W %h:%p ec2-user@JUMP"
```

---

### 6. EBS data volumes not mounted at boot

**Root cause:** UserData ran before `attach_data_volume` — the disk wasn't
present yet when the mount script executed.

**Fix:** Removed UserData mounts for data disks. Added `mount_disk_via_ssh()`:
format XFS + fstab + mount via SSH after attach completes.

---

### 7. `INSTALLER_INSTANCE` missed by destroy grep

**Root cause:** Pattern `'_INSTANCE$\|_INSTANCE_'` skipped `INSTALLER_INSTANCE`.

**Fix:** Changed to `grep '_INSTANCE'` (substring match).

---

### 8. `destroy` blocked on `read` in non-TTY

**Fix:** Added `--yes` / `-y` flag to skip interactive confirmation.

---

### 9. `${var,,}` not supported on macOS bash 3.2

**Fix:** `$(echo "${var}" | tr '[:upper:]' '[:lower:]')` everywhere.

---

### 10. GPU capacity exhausted (InsufficientInstanceCapacity) across all AZs

**What happened:** `g6e.12xlarge` was unavailable in all us-west-2 AZs
simultaneously. Switched to us-east-2 where capacity was found in us-east-2b.

**Fix:** Added `launch_instance_az_fallback()` — tries all private subnets in
the VPC before giving up. Also added per-instance AZ tracking for EBS volumes
so data disks are always in the same AZ as their target instance.

---

### 11. Installer public subnet only in one AZ; GPU workers needed a different AZ

**What happened:** The only public subnet was in us-east-2a, but GPU workers
needed us-east-2b for capacity. Setting `availabilityZone: us-east-2b` broke the
installer launch.

**Fix:** `INSTALLER_AZ` is derived from `INSTALLER_SUBNET_ID` at runtime,
independently of the global `availabilityZone`. MinIO EBS volume uses
`INSTALLER_AZ`; GPU worker EBS volumes use each worker's actual subnet AZ.

---

### 12. Root disk fills during model staging (gemma-4-31b-it, gpt-oss-20b)

**Root cause:** `download_from_huggingface.sh` hardcodes `DOWNLOAD_DIR=./model_artifacts`
relative to its working directory — inside the installer's 50 GB root disk.
Large models (62 GB + 40 GB) exhausted it.

**Fix:** Provisioner symlinks `artifacts_download_upload_scripts/model_artifacts`
→ `/data/minio/model_artifacts` on the 500 GB MinIO EBS. All downloads land there.

---

### 13. `find "$SOURCE_DIR"` returned 0 for symlinked directory

**Root cause:** `find` without `-L` does not follow symlinks; `artifact_count`
was always 0, causing "No artifacts found" in upload scripts.

**Fix:** Changed to `find -L "$SOURCE_DIR"` in `upload_to_minio.sh`,
`upload_to_s3.sh`, and `upload_to_seaweedfs_upload_only.sh`.

---

### 14. NVIDIA DKMS build failed — kernel-devel version mismatch

**What happened:** AMI booted with kernel `5.14.0-570.123.1.el9_6` but RHUI
only had `kernel-devel-5.14.0-687.25.1.el9_8`. DKMS couldn't build the module.

**Fix:** Install the matching kernel, set as default, reboot:
```bash
sudo dnf install -y kernel-5.14.0-687.25.1.el9_8 kernel-devel-5.14.0-687.25.1.el9_8
sudo grubby --set-default /boot/vmlinuz-5.14.0-687.25.1.el9_8.x86_64
sudo reboot
```

---

### 15. EBS data disk unmounted after kernel upgrade (device renamed)

**What happened:** After rebooting GPU nodes into the new kernel, `nvme1n1`
became `nvme2n1`. fstab had the device path, so the mount silently failed.

**Fix:** `mount_disk_via_ssh()` now scans `nvme1n1..nvme3n1` for the first
unmounted data disk and writes the fstab entry using UUID, not device path.

---

### What worked first time

- RHEL 9 AMI auto-discovery
- Security group with self-referencing SG rule
- EBS volume create / wait / attach
- MinIO install on RHEL 9 (SELinux + firewalld)
- State file idempotency
- `status`, `output`, `dry-run` commands
- `push_k0s_config` backup + yq patch
- NAT connectivity check on all k0s nodes
- k0s cluster install end-to-end (controller + 3 workers)
- cert-manager, Prometheus, KubeRay, Splunk operator — all installed cleanly
- AIPlatform + AIService CRs applied and reconciled
