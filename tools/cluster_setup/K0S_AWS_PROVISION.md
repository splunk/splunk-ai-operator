# k0s AWS Provisioner — Design & Ops Guide

## Purpose

`k0s_aws_provision.sh` creates EC2 infrastructure in an existing VPC for use by
`k0s_cluster_with_stack.sh`. It is a standalone helper: it launches instances,
attaches EBS data volumes, installs MinIO, and prints a ready-to-paste block for
`k0s-cluster-config.yaml`. No changes to the k0s installer itself.

---

## SCP Compliance (splunkcloud-ai-dev account)

All API calls are structured to satisfy the SCP on account `658391232643`:

| Requirement | How it's met |
|---|---|
| IMDSv2 required | All `run-instances` calls include `--metadata-options HttpTokens=required,HttpEndpoint=enabled` |
| EBS encryption | All volumes (root + data) include `Encrypted=true` |
| No new VPCs | Uses existing VPC `vpc-09b191e89c83d588e` (ai-platform-us-west-2-vpc) |

---

## Architecture

```
Existing VPC: vpc-09b191e89c83d588e  (ai-platform-us-west-2-vpc)
│
├── Public Subnet: subnet-0561d78f4f4744596  (10.0.35.240/28, us-west-2a)
│     Route: 0.0.0.0/0 → igw-03df5bf57f887baf1
│     │
│     └── Installer  (t3.small–large, 10–50 GB root, optional EBS /data/minio)
│           └── Elastic IP ← SSH from your laptop
│
└── Private Subnet: subnet-0f10872b190a44521  (10.0.34.0/26, us-west-2a)
      Route: 0.0.0.0/0 → nat-0930d686f6af3f8d2
      │
      ├── k0s Controller(s)   (root EBS)
      ├── k0s CPU Worker(s)   (root EBS)
      └── k0s GPU Worker(s)   (root EBS + data EBS at /var/lib/k0s)

Security Group  <stackName>-sg
  Inbound:  all traffic from same SG  ← private-IP k0s comms
  Inbound:  TCP 22 from sshAllowedCidr ← laptop → installer
  Outbound: all 0.0.0.0/0
```

**Why two subnets?**  
The installer needs inbound SSH via an Elastic IP, which requires a public subnet
(route table has an IGW entry). The k0s nodes only need outbound internet access
(for downloading k0s + NVIDIA packages) via the NAT gateway — no inbound required.
Placing k0s nodes in the private subnet minimises attack surface.

**EBS mount timing:**  
Data volumes are attached by the provisioner *after* instances boot. The provisioner
SSHes to each instance post-attach to format (XFS) and mount the disk — this is
more reliable than UserData, which runs before the volume is present.

---

## Script Commands

```bash
# Deploy stack (provision all infrastructure)
./k0s_aws_provision.sh provision [--config FILE]

# Print copy-paste block for k0s-cluster-config.yaml
./k0s_aws_provision.sh output    [--config FILE]

# Show instance states and MinIO health
./k0s_aws_provision.sh status    [--config FILE]

# Tear down everything (interactive — type stack name to confirm)
./k0s_aws_provision.sh destroy   [--config FILE]

# Non-interactive destroy (for automation / CI)
./k0s_aws_provision.sh destroy   [--config FILE] --yes

# Dry-run: print what would be created without deploying
./k0s_aws_provision.sh dry-run   [--config FILE]
```

---

## Config File: `k0s-aws-provision-config.yaml`

```yaml
stackName: my-k0s-infra
region: us-west-2
availabilityZone: us-west-2a

# Your CIDR for SSH access to the installer. Use x.x.x.x/32 to lock down.
sshAllowedCidr: "0.0.0.0/0"

# Existing VPC and subnets (required by SCP — no new VPC creation allowed).
# k0s nodes go in the private subnet (NAT outbound).
# Installer goes in the public subnet (EIP inbound SSH).
# Leave subnetId/installerSubnetId empty to auto-select by Name tag.
network:
  vpcId: vpc-09b191e89c83d588e
  subnetId: ""           # k0s nodes; auto-selects subnet tagged *private* in given AZ
  installerSubnetId: ""  # installer; auto-selects subnet tagged *public* in given AZ

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
  enabled: false
  dataDiskGb: 500               # separate EBS on installer, mounted at /data/minio
  bucket: ai-platform
  rootUser: minioadmin
  rootPassword: ""              # empty = auto-generate (printed in output)
  port: 9000
```

---

## State File

After `provision`, all created resource IDs are saved to:
```
~/.k0s-provision-<stackName>.state
```

This file is a plain `key=value` bash script, sourced by `output`, `status`, and
`destroy`. It is idempotent: re-running `provision` with the same config and an
existing state file prompts for confirmation before overwriting.

---

## Output Block

`output` prints a ready-to-paste block for `k0s-cluster-config.yaml`:

```
================================================================
  k0s AWS Provision -- Output
  Stack: my-k0s-infra  Region: us-west-2
================================================================

=== Paste into your k0s-cluster-config.yaml ===

  cluster:
    sshKeyPath: /Users/you/.ssh/my-k0s-infra.pem
    sshUser: ec2-user

  nodes:
    existingIPs:
      controllers:
        - 10.0.34.19
      workers:
        - 10.0.34.16  # cpu-worker
        - 10.0.34.22  # gpu-worker

  storage:
    objectStore:
      type: minio
      bucket: ai-platform
      endpoint: "http://10.0.35.xxx:9000"
      auth:
        rootUser: minioadmin
        rootPassword: <generated>

================================================================
  SSH to installer:
    ssh -i /Users/you/.ssh/my-k0s-infra.pem ec2-user@<EIP>

  Auto-generated k0s config on installer:
    ~/cluster_setup/my-k0s-config.yaml

  Run install from installer:
    CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml \
      ~/cluster_setup/k0s_cluster_with_stack.sh install
================================================================
```

---

## What `provision` Does Internally

1. Validate AWS credentials (`aws sts get-caller-identity`)
2. Look up RHEL 9 AMI (`describe-images --owners 309956199498`)
3. Select subnets: private for k0s nodes, public for installer
4. Create or reuse SSH key pair; save `.pem` to `keyPair.localPath`
5. Create security group (SG-to-SG ingress + SSH from `sshAllowedCidr`)
6. Launch all instances with IMDSv2 + encrypted root EBS
7. Wait for all instances to reach `running` state
8. Attach encrypted data EBS volumes (GPU workers + MinIO)
9. Allocate and associate Elastic IP to installer
10. Wait for SSH on installer (direct via EIP)
11. Wait for SSH on k0s nodes (via installer as ProxyCommand jump host)
12. Mount data disks via SSH: format XFS + add to `/etc/fstab` + mount
13. Install prerequisites on installer (yq, kubectl, helm, jq, git)
14. Copy cluster scripts (`*.sh`, `*.yaml`) to installer `~/cluster_setup/`
15. If `minio.enabled`: run `install_minio_ec2.sh` on installer
16. Generate and push `my-k0s-config.yaml` to installer `~/cluster_setup/`
17. Print `output` block

---

## What `destroy` Does

1. Confirmation: type the stack name (interactive) or pass `--yes` (non-interactive)
2. Terminate all instances (controller, workers, installer) in parallel
3. Wait for `instance-terminated` state
4. Release Elastic IP
5. Delete data EBS volumes (GPU + MinIO)
6. Delete security group (only if tagged as auto-created by this stack)
7. Delete AWS key pair (only if auto-created) + optionally delete local `.pem`
8. Remove state file

---

## Integrating with `k0s_cluster_with_stack.sh`

### Option A — Run from installer (recommended)

The provisioner copies scripts and auto-generates `my-k0s-config.yaml` to the
installer. After `provision` completes:

```bash
# 1. SSH to installer (exact command printed by 'output')
ssh -i ~/.ssh/<stackName>.pem ec2-user@<EIP>

# 2. On the installer — run the k0s install
CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml \
  ~/cluster_setup/k0s_cluster_with_stack.sh install
```

`my-k0s-config.yaml` is pre-filled with:
- Private IPs for all controllers and workers
- SSH key path (`~/.ssh/id_rsa`, copied there by the provisioner)
- MinIO endpoint and credentials (if `minio.enabled: true`)

Edit it before running install only if you need to change images, registry, or
operator versions.

### Option B — Run from your laptop

Copy the paste block from `output` into your own `k0s-cluster-config.yaml`:

```bash
# 1. Copy the output block
./k0s_aws_provision.sh output --config k0s-aws-provision-config.yaml

# 2. Edit k0s-cluster-config.yaml with the printed values
#    (cluster.sshKeyPath, nodes.existingIPs, storage.objectStore)

# 3. Run the installer from your laptop
#    (requires direct SSH access to the k0s nodes — they are in a private subnet,
#     so you must either be on VPN or configure ProxyJump via the installer EIP)
CONFIG_FILE=./my-k0s-config.yaml ./k0s_cluster_with_stack.sh install
```

**Note:** k0s nodes are in a private subnet. Without VPN or a ProxyJump config,
your laptop cannot reach them directly. Option A (run from installer) is simpler.

### ProxyJump config for Option B (laptop → installer → k0s nodes)

Add to `~/.ssh/config`:

```
Host 10.0.34.*
  User ec2-user
  IdentityFile ~/.ssh/<stackName>.pem
  StrictHostKeyChecking no
  ProxyCommand ssh -i ~/.ssh/<stackName>.pem -o StrictHostKeyChecking=no -W %h:%p ec2-user@<EIP>
```

Then `k0s_cluster_with_stack.sh` can SSH to the private IPs transparently.

---

## OS: RHEL 9

- AMI owner: `309956199498` (Red Hat official marketplace)
- Default user: `ec2-user`
- RHUI subscription included (~$0.10/hr/instance for Red Hat support)
- `install_minio_ec2.sh` handles RHEL 9 (SELinux `restorecon`, `firewall-cmd`)
- `k0s_cluster_with_stack.sh` supports RHEL/CentOS/Amazon Linux via `dnf`

---

## AWS Authentication

```bash
eval "$(okta-aws-login -a splunkcloud-ai-dev \
  --role-arn arn:aws:iam::658391232643:role/splunkcloud_account_admin)"

aws sts get-caller-identity  # verify
```

The provisioner calls `aws sts get-caller-identity` at startup and exits with a
clear error if credentials are missing or expired.

---

## Test Plan

### Level 1 — Dry-run (free, local)

```bash
./k0s_aws_provision.sh dry-run --config k0s-aws-provision-config.yaml
```

Validates config parsing, AMI lookup, subnet selection, and key pair checks
without creating any resources.

### Level 2 — Cheap end-to-end (~$1–2, ~15 min)

Use `k0s-aws-provision-config-test.yaml` (committed alongside the main config).
It uses `t3.medium/small` instances instead of production sizes:

```bash
./k0s_aws_provision.sh provision --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh status    --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh output    --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh destroy   --config k0s-aws-provision-config-test.yaml --yes
```

Validates:
- SCP compliance (IMDSv2, EBS encryption, existing VPC)
- RHEL 9 AMI lookup
- Key pair auto-create + `.pem` save
- Instances in correct subnets (public for installer, private for k0s nodes)
- EIP allocation and SSH via EIP
- EBS attach + XFS format + mount via SSH (not UserData)
- SSH via ProxyCommand jump to private k0s nodes
- MinIO install + health check on RHEL 9
- `output` prints correct private IPs and MinIO endpoint
- `status` shows all running instances
- `destroy` tears down all resources cleanly

### Level 3 — Full GPU integration (~$130, ~4 hr)

```bash
# 1. Provision
./k0s_aws_provision.sh provision --config k0s-aws-provision-config.yaml

# 2. SSH to installer (printed by output)
ssh -i ~/.ssh/<stackName>.pem ec2-user@<EIP>

# 3. On installer: run k0s install
CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml \
  ~/cluster_setup/k0s_cluster_with_stack.sh install
```

---

## Development History — What Failed and What Fixed It

This script was rewritten from a CloudFormation-based provisioner. Here is a
summary of every significant failure encountered during development and testing,
plus the fix applied in each case.

### 1. CloudFormation blocked by SCP

**What happened:** The original script used `aws cloudformation deploy`. All
stack creates failed with `CREATE_FAILED` / `InsufficientCapacity` or an access
denial, even for the simplest template with one VPC.

**Root cause:** SCP `p-m68tib3s` on account `658391232643` contains policy
`PreventRunInstanceWithNoIMDSv2AllowModify`, which denies `ec2:RunInstances`
unless `ec2:MetadataHttpTokens = required`. CloudFormation calls
`ec2:RunInstances` on behalf of `cloudformation.amazonaws.com`. There is no
way to pass `--metadata-options` through a CloudFormation resource — the CFN
resource model does not expose it for `AWS::EC2::Instance`.

Decoded error via:
```bash
aws sts decode-authorization-message --encoded-message <token>
```
The decoded JSON showed `statementId: "PreventRunInstanceWithNoIMDSv2AllowModify"`.

**Fix:** Rewrote the provisioner to use direct `aws ec2 run-instances` calls
with `--metadata-options HttpTokens=required,HttpEndpoint=enabled`. All EBS
volumes also have `Encrypted=true` (also required by the same SCP group).

---

### 2. VPC not found — needed to use an existing VPC

**What happened:** After switching to direct CLI calls, attempts to create a new
VPC + subnet before launching instances failed with `AuthFailure` / access
denied from a separate VPC-related SCP, or timed out due to dependency ordering.

**Root cause:** The account has all production workloads in
`vpc-09b191e89c83d588e` (ai-platform-us-west-2-vpc). A survey of ~100 existing
instances confirmed every instance uses this VPC. An additional SCP likely
blocks creating new VPCs or limits `ec2:RunInstances` to this VPC.

**Fix:** Removed all VPC/subnet/IGW/route table creation from the script.
The script now requires an existing VPC ID (`network.vpcId` config key,
defaulting to `vpc-09b191e89c83d588e`). All instances are launched into
pre-existing subnets.

---

### 3. `set -e` killed the script on a false-negative `[[ ! -f ]]` check

**What happened:** Script died silently immediately after the key-pair warning,
with no error message.

**Root cause:** `[[ ! -f "$KEY_LOCAL" ]]` returns exit code **1** when the file
**exists** (condition is false). With `set -euo pipefail`, this non-zero exit
code immediately terminates the script. The pattern `[[ ! -f FILE ]] && warn ...`
used outside an `if` block is therefore unsafe.

**Fix:** Changed all such patterns to:
```bash
if [[ ! -f "$KEY_LOCAL" ]]; then warn "..."; fi
```

---

### 4. Installer in private subnet — EIP not reachable via SSH

**What happened:** After the first successful `run-instances` run, an Elastic IP
was allocated and associated to the installer, but `ssh ec2-user@<EIP>` timed out.

**Root cause:** The installer was launched into `subnet-0f10872b190a44521` (the
private subnet, `10.0.34.0/26`). Its route table has `0.0.0.0/0 → NAT gateway`
— NAT only handles *outbound* traffic. Inbound connections to the EIP were
dropped because the subnet has no Internet Gateway route.

**Fix:** Added `INSTALLER_SUBNET_ID` as a separate config parameter. The
installer is now launched into `subnet-0561d78f4f4744596` (public subnet,
`10.0.35.240/28`) which routes `0.0.0.0/0 → igw-03df5bf57f887baf1`. k0s nodes
remain in the private subnet.

---

### 5. SSH jump `-J` did not forward the private key on macOS

**What happened:** After fixing the subnet, SSH to the installer worked, but
SSH to k0s nodes via jump (`ssh -i KEY -J ec2-user@EIP ec2-user@PRIVATE_IP`)
returned `Permission denied (publickey)` on the jump hop.

**Root cause:** On macOS, the `-J` flag does not forward the `-i KEY` option to
the jump hop. The jump connection is made with the default key
(`~/.ssh/id_rsa`), which is not the provisioner key.

**Fix:** Replaced `-J` with an explicit `ProxyCommand`:
```bash
-o "ProxyCommand=ssh -i KEY -o StrictHostKeyChecking=no -o BatchMode=yes \
  -o ConnectTimeout=5 -W %h:%p ec2-user@JUMP"
```
This guarantees the same key is used on both the jump and the target hop.

---

### 6. EBS data volumes not mounted at boot

**What happened:** The provisioner timed out waiting for `/data/minio` to be
mounted on the installer. On the GPU worker, `/var/lib/k0s` was also not
mounted. Manually running `lsblk` on the instance showed the disk
(`/dev/nvme1n1`) was present but not mounted.

**Root cause:** The original design used UserData to call a `mount_data_disk()`
function. However, UserData runs at first boot — before the provisioner calls
`attach_data_volume`. When `mount_data_disk()` ran, the disk wasn't attached yet,
so it logged "data disk not found" and exited silently. By the time the
provisioner had finished the attach, UserData had already completed — the mount
function never ran again.

**Fix:** Removed reliance on UserData for data disk mounts. Added
`mount_disk_via_ssh()`: after SSH is confirmed reachable, the provisioner
connects to each instance and runs the format + mount commands directly. The
function detects the device (`/dev/nvme1n1`, `/dev/xvdb`, or `/dev/sdb`),
formats with XFS if blank, adds an `/etc/fstab` entry (`nofail`), and mounts.

---

### 7. `_INSTANCE` grep pattern missed the installer

**What happened:** During the first `destroy` run, only 3 of 4 instances
appeared in the terminate list. The installer (`i-02319a40931e00a95`) survived
and had to be terminated manually.

**Root cause:** The grep pattern `'_INSTANCE$\|_INSTANCE_'` matched variable
names ending in `_INSTANCE_<digit>` (e.g. `CTRL_INSTANCE_0`) and those ending
exactly in `_INSTANCE` — but `INSTALLER_INSTANCE` ends in `_INSTANCE` and was
*also* being skipped because of how bash `compgen -v` + grep interacted with
the alternation.

**Fix:** Changed the pattern to simply `'_INSTANCE'` — matches every variable
whose name contains that substring, including `INSTALLER_INSTANCE`.

---

### 8. `destroy` blocked on `read` when stdin is not a TTY

**What happened:** Running `destroy` from a non-interactive context (e.g. piped
input, background job) exited with code 1 and the message
`"Destroy requires interactive confirmation. Run from a terminal."`

**Root cause:** The confirmation `read` was guarded by `[[ -t 0 ]]` (stdin is
a TTY), but there was no way to bypass it for automation.

**Fix:** Added `--yes` / `-y` flag. When set, the confirmation is automatically
approved without a TTY. The usage line now reads:
```
./k0s_aws_provision.sh destroy [--config FILE] [--yes]
```

---

### 9. `${var,,}` not supported on macOS bash 3.2

**What happened:** `destroy --yes` exited with:
```
./k0s_aws_provision.sh: line 917: ${del_local,,}: bad substitution
```

**Root cause:** `${var,,}` (lowercase expansion) requires bash 4+. macOS ships
bash 3.2 (`/bin/bash`), and even `#!/usr/bin/env bash` resolves to bash 3.2
unless Homebrew bash is installed and first in `$PATH`.

**Fix:** Replaced all `${var,,}` with `$(echo "${var}" | tr '[:upper:]' '[:lower:]')`.

---

### What worked first time

- RHEL 9 AMI auto-discovery (owner `309956199498`, `RHEL-9.*_HVM-*-x86_64-*`)
- Security group creation with self-referencing SG rule
- EBS volume creation, `wait volume-available`, and attach
- MinIO install via `install_minio_ec2.sh` on RHEL 9 (SELinux + firewalld handled)
- State file idempotency (`save_state` + `load_state`)
- `status` command (AWS describe + MinIO HTTP health check)
- `output` command (YAML block formatted for paste into `k0s-cluster-config.yaml`)
- `push_k0s_config` (auto-generated config pushed to installer `~/cluster_setup/`)

---

## Cost Summary

### Level 2 test (t3 instances, ~1 hr)

| Resource | $/hr | 1-hr test |
|---|---|---|
| 3× t3.medium + 1× t3.small | $0.04–0.05 | ~$0.17 |
| 4× EBS gp3 8–10 GB | negligible | <$0.01 |
| 1× EIP (associated) | free | free |
| 3× RHEL 9 subscription | $0.10/instance | ~$0.30 |
| **Total** | | **~$0.50** |

### Level 3 production (GPU workers, ~4 hr)

| Resource | $/hr | 4-hr run |
|---|---|---|
| 2× g6e.12xlarge | ~$16/hr | ~$128 |
| 1× m6i.2xlarge controller | ~$0.38/hr | ~$1.52 |
| 1× m6i.4xlarge CPU worker | ~$0.77/hr | ~$3.08 |
| 1× t3.large installer | ~$0.08/hr | ~$0.32 |
| EBS, RHEL subscription, data transfer | | ~$5 |
| **Total** | | **~$138** |
