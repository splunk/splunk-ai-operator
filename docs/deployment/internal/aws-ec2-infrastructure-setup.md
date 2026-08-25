# Internal AWS EC2 Infrastructure and MinIO Setup for Splunk AI Platform

> **Internal use only.**
>
> This runbook guides internal testers through creating the AWS EC2 machines
> required for a Splunk AI Platform test environment, installing MinIO, and
> setting up a local container-image mirror registry for air-gapped testing. It
> stops at the infrastructure handoff and does not cover k0s configuration,
> installation, workload verification, or Splunk AI Assistant testing.

## Deployment layout overview

This setup requires the following five EC2 instances. This table is a reference
for the required machine roles and sizes; **do not launch the instances yet**.
First [create and configure the security group](#1-create-and-configure-the-security-group),
then follow [Step 2](#2-launch-the-ec2-machines) to launch the machines.

| Role | Instance type | Root disk | Count | Notes |
|---|---:|---:|---:|---|
| k0s controller | `m5.4xlarge` | 100 GB | 1 | Kubernetes control plane |
| MinIO and installer | `m5.4xlarge` | 500 GB | 1 | Runs MinIO and the installation script |
| CPU worker | `m5.4xlarge` | 200 GB | 1 | Runs CPU platform workloads |
| GPU worker | `g6e.12xlarge` | 500 GB | 2 | Launch both from the approved Capacity Reservation |

All machines must:

- Be in the same VPC.
- Use the same security group.
- Use the same newly created EC2 key pair.
- Assign a public IPv4 address to the MinIO/installer machine for testing-team
  SSH access.
- Allow the MinIO/installer machine to SSH to the controller and every worker.
- Have internet access for packages, images, k0s, NVIDIA software, and model downloads.
- Use private IP addresses for communication between the machines.

The GPU instances must match the Capacity Reservation's instance type, platform,
Availability Zone, and tenancy. In the EC2 launch wizard, expand **Advanced
details**, choose **Specify Capacity Reservation**, and select the approved
reservation. See the [AWS Capacity Reservation launch
documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-reservations-launch.html).

## 1. Create and configure the security group

**Impact: Mutating** — creates an AWS security group and configures its network
rules.

The following rules are intended for an **internet-connected test system**.
They keep node-to-node services private by allowing them only from machines
attached to the same security group, while allowing outbound internet access
for downloads. This configuration prioritizes ease of use for the testing team;
it is not a hardened production baseline.

Create the security group before launching the EC2 instances:

1. In the AWS console, select the `us-east-2` region. Then open EC2,
   **Security Groups**, and choose **Create security group**.
2. Enter a name and description that identify the test deployment.
3. Select the VPC that will contain all five EC2 instances.
4. Create the security group and record its security-group ID for later.
5. Configure the following inbound and outbound rules.

### Inbound rules

For every internal rule, select **Custom** as the source type and select this
same security group as the source. AWS displays a security-group ID such as
`sg-0123456789abcdef0` in the Source column.

| Type | Protocol | Port range | Source | Description |
|---|---|---:|---|---|
| Custom UDP | UDP | 4789 | Same security group | Calico VXLAN |
| Custom TCP | TCP | 6443 | Same security group | Kubernetes API server |
| Custom TCP | TCP | 2380 | Same security group | etcd peer communication |
| SSH | TCP | 22 | Same security group | SSH between internal nodes |
| Custom TCP | TCP | 8132 | Same security group | Konnectivity |
| SSH | TCP | 22 | `<tester-public-ip>/32` | SSH from the tester's machine |
| Custom TCP | TCP | 10250 | Same security group | Kubelet API |
| Custom TCP | TCP | 30000-32767 | Same security group | NodePort services, optional |
| Custom TCP | TCP | 179 | Same security group | Calico BGP |
| Custom TCP | TCP | 9000 | Same security group | MinIO server |
| Custom TCP | TCP | 5000 | Same security group | Mirror registry, air-gapped testing only |

The tester SSH rule must contain the tester's current public IPv4 address with a
`/32` suffix—for example, `203.0.113.10/32`. Add a separate SSH rule for each
approved tester IP if multiple people need direct access. Do not enter multiple
comma-separated IP addresses in one Source value.

The source on the internal rules is a **security-group reference**, not an IP
address. It allows traffic when both the source and destination network
interfaces have this security group attached. It does not expose those ports to
the public internet.

### Outbound rules

Use the default unrestricted IPv4 outbound rule for this internet-connected
test environment:

| Type | Protocol | Port range | Destination | Description |
|---|---|---|---|---|
| All traffic | All | All | `0.0.0.0/0` | Internet access for packages, images, drivers, and models |

This outbound rule permits connections to any IPv4 destination. A production
deployment should replace it with organization-approved egress controls and
private mirrors or endpoints where applicable.

### Security-group verification

Before continuing, confirm that:

- The security group belongs to the intended VPC.
- Only approved `/32` public IPs can reach SSH from outside the security group.
- No internal Kubernetes or MinIO rule uses `0.0.0.0/0` as its inbound source.
- The TCP port 9000 rule uses the same security group as its source.
- The TCP port 5000 rule uses the same security group as its source, if you plan
  to test the air-gapped flow with the mirror registry in
  [Step 6](#6-set-up-the-test-mirror-registry-air-gapped-testing-only).
- The outbound rule is **All traffic** to `0.0.0.0/0` for this
  internet-connected test deployment.

## 2. Launch the EC2 machines

Confirm that the AWS console is still set to the `us-east-2` region.

Use the AWS EC2 console to create the five machines listed in
[Deployment layout overview](#deployment-layout-overview).

For each instance:

1. Add a clear Name tag containing the machine's role.
   1. Use the name convention `<team>-<purpose>-<owner>-<expiry>`.
   2. For example: `aitier-e2etesting-myusername-13082026`.
2. Select Ubuntu Server 24.04 LTS, x86-64.
3. Select the required instance type and disk size.
4. Select the same VPC used when creating the security group. Every cluster node must have outbound internet connectivity, through an assigned public IPv4
   address.
5. Enable a public IPv4 address on the MinIO/installer machine. It is the only
   public IP required by this runbook.
6. Select the security group created in Step 1. Use the recorded security-group
   ID to confirm that the correct group is selected.
7. When launching the first instance, create a new EC2 key pair and securely
   save the downloaded PEM file. Select that same key pair for the other four
   instances; do not create a different key for each machine.

**Note:** For each GPU worker, also open **Advanced details**, target the approved
Capacity Reservation, and confirm that the selected subnet is in the same
Availability Zone as that reservation.

After all instances are running and have passed their EC2 status checks:

- Confirm that all five instances show the security-group ID created in Step 1.
- Capture the private IP address of every machine and the public IP address of
  the MinIO/installer machine.

### Record the deployment values

After the machines have been created, record the deployment-specific values in
this table. Do not add passwords or private keys to this document.

| Value | Deployment value |
|---|---|
| AWS region | `us-east-2` |
| Security group ID | `<security-group-id>` |
| EC2 key-pair name | `<key-pair-name>` |
| EC2 key file on the local machine | `<absolute-path-to-key.pem>` |
| SSH user | `ubuntu` |
| Controller private IP | `<controller-private-ip>` |
| MinIO public IP | `<minio-public-ip>` |
| MinIO private IP | `<minio-private-ip>` |
| CPU worker private IP | `<cpu-worker-private-ip>` |
| GPU worker 1 private IP | `<gpu-worker-1-private-ip>` |
| GPU worker 2 private IP | `<gpu-worker-2-private-ip>` |
| Mirror registry endpoint, air-gapped testing only | `<installer-private-ip>:5000` |

The MinIO public IP is used only to SSH and copy files from the local machine.
The deployment configuration must use the MinIO **private** IP. It also uses
the private IPs of the controller and all workers. This same machine runs the
installation script, so `<installer-private-ip>` in later steps refers to that
private IP.

## 3. Download the repository locally

After completing the AWS console setup, return to the local machine.

**Impact: Local mutation** — creates a local repository copy or updates an
existing Git checkout.

Use either of the following options on the local machine.

### Option A: Clone with Git

If Git is installed, run:

```bash
git clone --branch ai-tier-ga --single-branch \
  https://github.com/splunk/splunk-ai-operator.git

cd splunk-ai-operator
git branch --show-current
```

The last command must print:

```text
ai-tier-ga
```

If the repository already exists locally:

```bash
cd /path/to/splunk-ai-operator
git fetch origin ai-tier-ga
git switch ai-tier-ga
git pull --ff-only origin ai-tier-ga
```

### Option B: Download the branch as a ZIP

If Git is not installed:

1. [Download the `ai-tier-ga` branch ZIP directly](https://github.com/splunk/splunk-ai-operator/archive/refs/heads/ai-tier-ga.zip).
   Alternatively, open the [`ai-tier-ga` branch on GitHub](https://github.com/splunk/splunk-ai-operator/tree/ai-tier-ga),
   select **Code**, and then select **Download ZIP**.
2. Save the ZIP on the local machine.
3. Extract the downloaded ZIP on the local machine. The extracted directory is
   normally named `splunk-ai-operator-ai-tier-ga`.

Use the absolute path of either the cloned repository or the extracted ZIP
directory as `LOCAL_REPO` in Step 4.

## 4. Copy the tools directory to the installer machine

**Impact: Mutating** — copies repository files to the installer machine.

Run on the local machine. Replace the three placeholders first:

These are shell variables. Set each value once and the commands below reuse it.
The quotes around the placeholder values prevent the shell from treating angle
brackets as input redirection.

```bash
LOCAL_REPO="/absolute/path/to/splunk-ai-operator"
SSH_KEY="/absolute/path/to/aitier-key.pem"
INSTALLER_PUBLIC_IP="<minio-public-ip>"

chmod 600 "${SSH_KEY}"

scp -rp \
  -i "${SSH_KEY}" \
  "${LOCAL_REPO}/tools" \
  "ubuntu@${INSTALLER_PUBLIC_IP}:~/"
```

Confirm that the source directory exists before running `scp`:

```bash
test -d "${LOCAL_REPO}/tools" && echo "tools directory found"
```

Connect to the MinIO/installer machine:

```bash
ssh -i "${SSH_KEY}" "ubuntu@${INSTALLER_PUBLIC_IP}"
```

## 5. Install and verify MinIO

**Impact: Mutating** for installation; the subsequent health and bucket checks
are **environment/read-only**.

Run on the MinIO/installer machine:

```bash
cd ~/tools/artifacts_download_upload_scripts

sudo ./install_minio_ec2.sh \
  --bucket ai-platform-bucket \
  --user minioadmin \
  --password '<minio-password>'
```

Replace `<minio-password>` before running the command. The literal value remains
in shell history, so follow the internal credential-handling policy.

Check the service:

```bash
systemctl is-active minio
curl --fail --silent --show-error http://127.0.0.1:9000/minio/health/live
```

Verify the username, password, and bucket together. This command prompts for the
credentials instead of printing them:

```bash
read -rp "Username: " u && \
read -rsp "Password: " p && \
echo && \
MC_HOST_check="http://${u}:${p}@127.0.0.1:9000" \
  mc stat check/ai-platform-bucket
unset u p MC_HOST_check
```

Expected output resembles:

```text
Name      : ai-platform-bucket
Date      : <creation-time>
Size      : N/A
Type      : folder
```

## 6. Set up the test mirror registry (air-gapped testing only)

**Impact: Mutating** — installs podman on the installer machine, runs a registry
container, and copies container images into it.

Complete this step only when testing the **air-gapped** installation flow, where
the cluster nodes have no route to Docker Hub. The registry gives those nodes an
in-VPC copy of every platform container image, served from the installer machine.
Skip this step entirely for an internet-connected test, where every node pulls
from Docker Hub directly.

Run every command in this step on the installer machine. `<installer-private-ip>`
is that machine's private IP, which is the address the cluster nodes use to reach
the registry.

The registry serves **plain HTTP** on port 5000, which pairs with
`images.registryInsecure: true` in the cluster configuration. That is a
deliberate choice for a test environment: the installer has no mechanism for
distributing a private CA to the nodes, so a TLS registry would require a manual
trust-store update on every freshly created batch of machines.

### Prerequisites

Confirm the security group allows TCP port 5000 from itself, as listed in
[Inbound rules](#inbound-rules). Without that rule the nodes cannot pull.

Install podman. The helper script installs it with `dnf`, which is absent on
Ubuntu, so install it with `apt` first:

```bash
sudo apt-get update && sudo apt-get install -y podman
podman --version
```

### Run the helper script

Pass the installer machine's **private** IP. A loopback or public address does
not work, because the nodes must reach the registry over the VPC:

```bash
cd ~/tools/cluster_setup
./setup_test_mirror_registry.sh <installer-private-ip>
```

Run it with no argument to print the usage line and this machine's private IP.

The script starts a `registry:2` container named `k0s-registry` with
`--restart=always`, confirms the registry answers on `/v2/` before mirroring
anything, copies each image, and prints the registry catalog at the end. It
writes registry data to `/data/registry` and podman's storage to
`/data/containers`, both on the installer machine's 500 GB root volume. Override
the location with `DATA_DIR`, which also moves podman storage alongside it:

```bash
DATA_DIR=/mnt/registry ./setup_test_mirror_registry.sh <installer-private-ip>
```

If any image fails to mirror, the script lists it and exits non-zero. Those
images stay in local podman storage, so re-running the script retries them
without downloading again.

### Verify the registry

Confirm the container is running and the catalog is populated. The `--root` value
must match the podman storage path, which is the `containers` directory next to
`DATA_DIR`:

```bash
sudo podman --root /data/containers ps --filter name=k0s-registry
curl --silent http://<installer-private-ip>:5000/v2/_catalog
```

From the controller and every worker, confirm the registry is reachable:

```bash
curl --silent --fail http://<installer-private-ip>:5000/v2/ && echo "registry reachable"
```

### Point the cluster configuration at the registry

Set these keys in the cluster configuration used by the installation workflow:

| Key | Value |
|---|---|
| `images.registry` | `<installer-private-ip>:5000` |
| `images.registryInsecure` | `true` |
| `imagePullSecrets.autoCreateECR` | `false` |
| `imagePullSecrets.secrets` | `[]` |

Leave `imagePullSecrets.secrets` empty rather than listing a secret name. An
entry there refers to a Kubernetes Secret that nothing creates once ECR is
disabled.

Then rewrite every fully qualified image reference in the configuration to the
mirror. The installer prefixes `images.registry` onto **bare** image names only,
and leaves any reference that already carries a registry host untouched — so a
`docker.io/...` reference is still pulled from Docker Hub even with
`images.registry` set. The mirror preserves the path after `docker.io/`:

```text
docker.io/splunk/splunk:10.2-rhel9  ->  <installer-private-ip>:5000/splunk/splunk:10.2-rhel9
```

## Infrastructure handoff

At this point, the AWS machines and MinIO object store are ready for the
separately documented k0s installation workflow. Record the private IP addresses,
MinIO private endpoint, bucket name, mirror registry endpoint if you created one,
and approved credential reference for that handoff. Do not add passwords or
private-key contents to this document.

## Completion checklist

- [ ] The shared security group has the required inbound and outbound rules.
- [ ] All five EC2 instances are running and have passed their status checks.
- [ ] Both GPU workers use the approved Capacity Reservation.
- [ ] All instances use the intended VPC, security group, and EC2 key pair.
- [ ] The required private IPs and MinIO public IP are recorded.
- [ ] The `tools` directory exists at `/home/ubuntu/tools` on the MinIO machine.
- [ ] MinIO is active and the configured bucket is accessible with the configured credentials.

If you are testing the air-gapped flow and set up the mirror registry in Step 6:

- [ ] The `k0s-registry` container is running on the installer machine.
- [ ] `/v2/_catalog` lists all 12 mirrored repositories.
- [ ] The controller and every worker can reach port 5000 on the installer machine.
- [ ] The cluster configuration sets `images.registry`, `images.registryInsecure`,
      and the `imagePullSecrets` keys, and every image reference points at the mirror.
