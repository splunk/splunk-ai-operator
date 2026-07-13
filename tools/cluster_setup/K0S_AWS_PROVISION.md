# k0s AWS Provisioner — Design & Test Plan

## Purpose

`k0s_aws_provision.sh` creates the EC2 infrastructure consumed by
`k0s_cluster_with_stack.sh`. It is a standalone helper: it creates machines,
wires them into a single security group (all traffic on private IPs), optionally
installs MinIO, and prints a ready-to-paste block for `k0s-cluster-config.yaml`.
No changes to the k0s installer itself.

---

## Architecture

```
VPC (10.10.0.0/16)
└── Public Subnet (10.10.0.0/24)  +  Internet Gateway
    │
    ├── Installer  (t3.large, 50 GB root, optional 500 GB /data/minio)
    │     └── Elastic IP ← SSH from your laptop
    │
    ├── k0s Controller(s)  (100 GB root)
    ├── k0s CPU Worker(s)  (200 GB root)
    └── k0s GPU Worker(s)  (100 GB root + 500 GB /var/lib/k0s, separate EBS)

Security Group  k0s-<stackName>-sg
  Inbound:  all traffic from same SG (self-referencing)  ← private-IP k0s comms
  Inbound:  TCP 22 from sshAllowedCidr                   ← your laptop → installer
  Outbound: all 0.0.0.0/0

airgap: false → k0s nodes get public IPs (internet for k0s binary, NVIDIA, images)
airgap: true  → k0s nodes get no public IP (pre-provisioned; script SSHes via private IP)
```

All inter-node communication uses private IPs. The k0s installer is run **on
the installer machine** (not from your laptop), so no public IP is needed for
k0s nodes.

---

## Script Commands

```bash
# Deploy stack
./k0s_aws_provision.sh provision [--config k0s-aws-provision-config.yaml]

# Print copy-paste block for k0s-cluster-config.yaml
./k0s_aws_provision.sh output    [--config ...]

# Show instance states and MinIO health
./k0s_aws_provision.sh status    [--config ...]

# Tear down everything
./k0s_aws_provision.sh destroy   [--config ...]

# Validate CFN template locally without deploying
./k0s_aws_provision.sh validate  [--config ...]

# Dry-run: generate + validate template, print what would be created
./k0s_aws_provision.sh dry-run   [--config ...]
```

---

## Config File: `k0s-aws-provision-config.yaml`

```yaml
stackName: my-k0s-infra            # CloudFormation stack name; must be unique per region
region: us-east-2
availabilityZone: us-east-2a       # all nodes in same AZ (avoids cross-AZ data transfer cost)
airgap: false                      # true = k0s nodes get no public IP

# Your IP for SSH access to the installer machine. Use x.x.x.x/32 to lock down.
sshAllowedCidr: "0.0.0.0/0"

keyPair:
  name: ""        # existing AWS keypair name; empty = auto-create "<stackName>-key"
  localPath: ""   # local .pem path; empty = save to ~/.ssh/<stackName>.pem

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
    instanceType: g6e.12xlarge  # 4× NVIDIA L40S (48 GB each), 192 GB RAM
    diskGb: 100                 # root volume
    dataDiskGb: 500             # separate EBS, mounted at /var/lib/k0s
    # capacityReservationId: cr-xxxx   # optional, for pre-reserved capacity

installer:
  instanceType: t3.large        # 2 vCPU, 8 GB RAM
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

## Output Block (copy-paste into k0s-cluster-config.yaml)

```
=== Paste into your k0s-cluster-config.yaml ===

  existingIPs:
    controllers:
      - 10.10.0.12
    workers:
      - 10.10.0.45    # cpu-worker-0
      - 10.10.0.67    # gpu-worker-0
      - 10.10.0.89    # gpu-worker-1

  cluster:
    sshKeyPath: ~/.ssh/my-k0s-infra.pem
    sshUser: ec2-user

  storage:
    objectStore:
      endpoint: "http://10.10.0.100:9000"
      auth:
        rootUser: minioadmin
        rootPassword: <generated>

SSH to installer:
  ssh -i ~/.ssh/my-k0s-infra.pem ec2-user@<EIP>
```

---

## What `provision` Does Internally

1. Validate AWS credentials (`aws sts get-caller-identity`)
2. Key pair: create if `keyPair.name` empty, save .pem to `keyPair.localPath`
3. Auto-discover RHEL 9 AMI (`describe-images --owners 309956199498`)
4. Generate CloudFormation template in `/tmp/<stackName>-cfn.yaml`
5. `aws cloudformation deploy` — idempotent; deletes ROLLBACK stacks first
6. Wait for `CREATE_COMPLETE`; surface `InsufficientInstanceCapacity` clearly
7. Allocate EIP + associate to installer instance
8. Wait for all instances SSH-reachable (port 22, up to 10 min)
9. SCP private key to installer at `~/.ssh/id_rsa` + set `chmod 600`
10. If `minio.enabled`: SCP `install_minio_ec2.sh`, SSH + run it with `--data-dir /data/minio`
11. Wait for MinIO health check on installer
12. Print output block (private IPs, EIP, MinIO endpoint)

---

## What `destroy` Does

1. Confirmation prompt: type stack name to confirm
2. `aws cloudformation delete-stack` → wait for completion
3. Release EIP
4. Delete orphan EBS volumes tagged with stack name
5. Delete AWS key pair if it was auto-created by this script
6. Offer to delete local `.pem` file

---

## OS: RHEL 9

- AMI owner: `309956199498` (Red Hat official marketplace)
- Default user: `ec2-user`
- Includes RHUI subscription (Red Hat Update Infrastructure) — ~$0.10/hr/instance
- `install_minio_ec2.sh` already handles RHEL 9 (SELinux `restorecon`, `firewall-cmd`)
- k0s installer already supports RHEL/CentOS/Amazon Linux via `dnf`

---

## Test Plan

### Level 1 — Free, local (run before any deployment)

```bash
# CloudFormation template syntax
aws cloudformation validate-template --template-body file:///tmp/<stackName>-cfn.yaml

# Deep lint (install once: pip install cfn-lint)
cfn-lint /tmp/<stackName>-cfn.yaml
```

Use `./k0s_aws_provision.sh dry-run` to generate the template without deploying.

### Level 2 — Cheap end-to-end (~$2–4, ~20 min)

Use `k0s-aws-provision-config-test.yaml` (committed alongside the main config):

```yaml
stackName: k0s-infra-test
nodes:
  controller:
    instanceType: t3.medium   # $0.04/hr — same provisioning flow, no GPU
    diskGb: 8
  cpuWorker:
    instanceType: t3.medium
    diskGb: 8
  gpuWorker:
    count: 1
    instanceType: t3.medium
    diskGb: 8
    dataDiskGb: 8             # tests EBS attach + mount logic
installer:
  instanceType: t3.small
  diskGb: 8
minio:
  enabled: true
  dataDiskGb: 8
```

Validates:
- VPC / subnet / SG / IGW / route table creation
- RHEL 9 AMI lookup per region
- Key pair auto-create + .pem download
- All instances boot, SSH reachable via EIP
- EBS attach + XFS format + `/var/lib/k0s` mount (UserData)
- MinIO install + health check on RHEL 9
- `output` prints correct private IPs
- `status` shows all running
- `destroy` tears down everything cleanly

Run:
```bash
./k0s_aws_provision.sh provision --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh status    --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh output    --config k0s-aws-provision-config-test.yaml
./k0s_aws_provision.sh destroy   --config k0s-aws-provision-config-test.yaml
```

### Level 3 — Real GPU integration (~$50–100, ~4 hr)

Full config with `g6e.12xlarge` GPU workers. After provision:

```bash
# 1. Provision
./k0s_aws_provision.sh provision --config k0s-aws-provision-config.yaml

# 2. SSH to installer (script prints exact command)
ssh -i ~/.ssh/<stackName>.pem ec2-user@<EIP>

# 3. On installer: run k0s install with auto-generated config
CONFIG_FILE=./my-k0s-config.yaml ./k0s_cluster_with_stack.sh install
```

`my-k0s-config.yaml` is auto-generated by `output` with private IPs pre-filled
and SCP'd to the installer. No manual IP copying needed.

---

## AWS Authentication

Login before running any command:
```bash
eval "$(okta-aws-login -a splunkcloud-ai-dev \
  --role-arn arn:aws:iam::658391232643:role/splunkcloud_account_admin)"
```

Verify:
```bash
aws sts get-caller-identity
```

The provision script runs `aws sts get-caller-identity` at startup and exits
with a clear message if credentials are not configured.

---

## Cost Summary (Level 2 test)

| Resource | $/hr | 2-hr test |
|----------|------|-----------|
| 4× t3.medium/small | $0.04–0.05 | ~$0.40 |
| 4× EBS gp3 8 GB | negligible | <$0.01 |
| 1× EIP (associated) | free | free |
| RHEL 9 subscription | $0.10/instance | ~$0.80 |
| Data transfer | negligible | <$0.10 |
| **Total** | | **~$1.30** |

Level 3 with `g6e.12xlarge` (4 hr):
- 2× g6e.12xlarge: ~$16/hr × 2 × 4 hr = ~$128
- Other instances: ~$2
- **Total: ~$130**
