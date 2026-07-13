#!/usr/bin/env bash
# =============================================================================
# k0s AWS Provisioner
# Creates EC2 instances (with EBS) in a VPC for use by k0s_cluster_with_stack.sh.
# Uses direct AWS CLI calls with required SCP flags:
#   - IMDSv2 (HttpTokens=required)
#   - EBS encryption
#
# Network handling (network.vpcId in config):
#   - Set to an existing VPC ID → uses it as-is (all subnets must pre-exist)
#   - Set to "" or omit        → auto-creates VPC + IGW + public/private subnets + NAT GW
#   - Default for us-west-2   → vpc-09b191e89c83d588e (ai-platform-us-west-2-vpc)
#
# The VPC has private subnets + NAT gateway. All nodes get private IPs.
# One node (installer) also gets an EIP for SSH access from your laptop.
#
# Usage:
#   ./k0s_aws_provision.sh provision [--config FILE]
#   ./k0s_aws_provision.sh output    [--config FILE]
#   ./k0s_aws_provision.sh status    [--config FILE]
#   ./k0s_aws_provision.sh destroy   [--config FILE] [--yes]
#   ./k0s_aws_provision.sh dry-run   [--config FILE]
# =============================================================================
set -euo pipefail
export AWS_PAGER="" AWS_DEFAULT_OUTPUT=json PAGER=cat LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/k0s-aws-provision-config.yaml"
CONFIG_FILE="${DEFAULT_CONFIG}"
MINIO_INSTALL_SCRIPT="${SCRIPT_DIR}/../artifacts_download_upload_scripts/install_minio_ec2.sh"

# -- Logging --
log()  { echo "[k0s-provision] $*" >&2; }
warn() { echo "[k0s-provision] WARN: $*" >&2; }
err()  { echo "[k0s-provision] ERROR: $*" >&2; exit 1; }

# -- Arg parsing --
COMMAND="${1:-}"
[[ -z "$COMMAND" ]] && { echo "Usage: $0 <provision|output|status|destroy|dry-run> [--config FILE]"; exit 1; }
shift
FORCE_DESTROY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --yes|-y) FORCE_DESTROY=true; shift ;;
    *) err "Unknown option: $1" ;;
  esac
done
[[ -f "$CONFIG_FILE" ]] || err "Config file not found: $CONFIG_FILE"

# -- yq helper --
need_yq() { command -v yq &>/dev/null || err "yq is required. Install: brew install yq"; }
cfg()         { yq eval "${1}" "${CONFIG_FILE}"; }
cfg_default() { yq eval "${1} // \"${2}\"" "${CONFIG_FILE}"; }

# -- State file: tracks IDs of all created resources for destroy --
STATE_FILE=""   # set in load_config

save_state() { local key="$1" val="$2"; echo "${key}=${val}" >> "${STATE_FILE}"; }
load_state()  { [[ -f "${STATE_FILE}" ]] && source "${STATE_FILE}" || true; }

# -- Load config --
load_config() {
  need_yq
  STACK_NAME="$(cfg '.stackName')"
  REGION="$(cfg '.region')"
  AZ="$(cfg '.availabilityZone')"
  SSH_CIDR="$(cfg_default '.sshAllowedCidr' '0.0.0.0/0')"

  # Network — VPC, subnets, NAT, IGW.
  # Empty vpcId → auto-create the whole network stack.
  # Non-empty → use existing VPC (subnets auto-selected or explicitly set).
  # Default for us-west-2 is the shared ai-platform VPC so existing deployments are unaffected.
  local _vpc_default=""
  [[ "${REGION}" == "us-west-2" ]] && _vpc_default="vpc-09b191e89c83d588e"
  VPC_ID="$(cfg_default '.network.vpcId' "${_vpc_default}")"
  [[ "$VPC_ID" == "null" ]] && VPC_ID=""

  AUTO_CREATE_NETWORK=false
  [[ -z "$VPC_ID" ]] && AUTO_CREATE_NETWORK=true

  SUBNET_ID="$(cfg_default '.network.subnetId' '')"
  [[ "$SUBNET_ID" == "null" || -z "$SUBNET_ID" ]] && SUBNET_ID=""
  INSTALLER_SUBNET_ID="$(cfg_default '.network.installerSubnetId' '')"
  [[ "$INSTALLER_SUBNET_ID" == "null" || -z "$INSTALLER_SUBNET_ID" ]] && INSTALLER_SUBNET_ID=""

  # CIDR blocks used when auto-creating network (only relevant when AUTO_CREATE_NETWORK=true)
  VPC_CIDR="$(cfg_default '.network.vpcCidr' '10.0.0.0/16')"
  PUBLIC_CIDR="$(cfg_default '.network.publicSubnetCidr' '10.0.1.0/24')"
  PRIVATE_CIDR="$(cfg_default '.network.privateSubnetCidr' '10.0.2.0/24')"

  KEY_NAME="$(cfg_default '.keyPair.name' '')"
  KEY_LOCAL="$(cfg_default '.keyPair.localPath' '')"
  [[ "$KEY_NAME"  == "null" ]] && KEY_NAME=""
  [[ "$KEY_LOCAL" == "null" ]] && KEY_LOCAL=""
  [[ -z "$KEY_LOCAL" ]] && KEY_LOCAL="${HOME}/.ssh/${STACK_NAME}.pem"

  CTRL_COUNT="$(cfg_default '.nodes.controller.count' '1')"
  CTRL_TYPE="$(cfg_default  '.nodes.controller.instanceType' 'm6i.2xlarge')"
  CTRL_DISK="$(cfg_default  '.nodes.controller.diskGb' '100')"

  CPU_COUNT="$(cfg_default '.nodes.cpuWorker.count' '1')"
  CPU_TYPE="$(cfg_default  '.nodes.cpuWorker.instanceType' 'm6i.4xlarge')"
  CPU_DISK="$(cfg_default  '.nodes.cpuWorker.diskGb' '200')"

  GPU_COUNT="$(cfg_default '.nodes.gpuWorker.count' '2')"
  GPU_TYPE="$(cfg_default  '.nodes.gpuWorker.instanceType' 'g6e.12xlarge')"
  GPU_DISK="$(cfg_default  '.nodes.gpuWorker.diskGb' '100')"
  GPU_DATA_DISK="$(cfg_default '.nodes.gpuWorker.dataDiskGb' '500')"

  INST_TYPE="$(cfg_default '.installer.instanceType' 't3.large')"
  INST_DISK="$(cfg_default '.installer.diskGb' '50')"

  MINIO_ENABLED="$(cfg_default '.minio.enabled' 'false')"
  MINIO_DATA_DISK="$(cfg_default '.minio.dataDiskGb' '500')"
  MINIO_BUCKET="$(cfg_default '.minio.bucket' 'ai-platform')"
  MINIO_USER="$(cfg_default '.minio.rootUser' 'minioadmin')"
  MINIO_PASS="$(cfg_default '.minio.rootPassword' '')"
  MINIO_PORT="$(cfg_default '.minio.port' '9000')"
  [[ "$MINIO_PASS" == "null" || -z "$MINIO_PASS" ]] && MINIO_PASS=""

  TAG_KEY="k0s-provision-stack"
  STATE_FILE="${HOME}/.k0s-provision-${STACK_NAME}.state"
}

# -- AWS auth check --
check_aws_auth() {
  local identity
  identity=$(aws sts get-caller-identity --region "${REGION}" --output json 2>/dev/null) \
    || err "AWS credentials not configured or expired.
Run: eval \"\$(okta-aws-login -a splunkcloud-ai-dev --role-arn arn:aws:iam::658391232643:role/splunkcloud_account_admin)\""
  log "AWS identity: $(echo "$identity" | jq -r '.Arn')"
}

# -- Create VPC + IGW + public subnet + private subnet + NAT GW if they don't exist --
# Sets VPC_ID, SUBNET_ID (private), INSTALLER_SUBNET_ID (public).
# All created resources are tagged and saved to state for destroy cleanup.
ensure_network() {
  if [[ "${AUTO_CREATE_NETWORK}" != "true" ]]; then
    return
  fi

  log "AUTO_CREATE_NETWORK=true — creating VPC and network stack..."

  # ---------- VPC ----------
  VPC_ID=$(aws ec2 create-vpc \
    --cidr-block "${VPC_CIDR}" \
    --region "${REGION}" \
    --query 'Vpc.VpcId' --output text)
  aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" \
    --enable-dns-support --region "${REGION}"
  aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" \
    --enable-dns-hostnames --region "${REGION}"
  aws ec2 create-tags --resources "${VPC_ID}" \
    --tags "Key=Name,Value=${STACK_NAME}-vpc" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  save_state "AUTO_VPC_ID" "${VPC_ID}"
  log "Created VPC: ${VPC_ID} (${VPC_CIDR})"

  # ---------- Internet Gateway ----------
  local igw_id
  igw_id=$(aws ec2 create-internet-gateway \
    --region "${REGION}" \
    --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway \
    --internet-gateway-id "${igw_id}" \
    --vpc-id "${VPC_ID}" \
    --region "${REGION}"
  aws ec2 create-tags --resources "${igw_id}" \
    --tags "Key=Name,Value=${STACK_NAME}-igw" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  save_state "AUTO_IGW_ID" "${igw_id}"
  log "Created and attached IGW: ${igw_id}"

  # ---------- Public subnet + route table ----------
  INSTALLER_SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "${PUBLIC_CIDR}" \
    --availability-zone "${AZ}" \
    --region "${REGION}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 modify-subnet-attribute \
    --subnet-id "${INSTALLER_SUBNET_ID}" \
    --map-public-ip-on-launch --region "${REGION}"
  aws ec2 create-tags --resources "${INSTALLER_SUBNET_ID}" \
    --tags "Key=Name,Value=${STACK_NAME}-public-${AZ}" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  save_state "AUTO_PUBLIC_SUBNET_ID" "${INSTALLER_SUBNET_ID}"
  log "Created public subnet: ${INSTALLER_SUBNET_ID} (${PUBLIC_CIDR})"

  local pub_rt_id
  pub_rt_id=$(aws ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --region "${REGION}" \
    --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route \
    --route-table-id "${pub_rt_id}" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "${igw_id}" \
    --region "${REGION}" &>/dev/null
  aws ec2 associate-route-table \
    --route-table-id "${pub_rt_id}" \
    --subnet-id "${INSTALLER_SUBNET_ID}" \
    --region "${REGION}" &>/dev/null
  aws ec2 create-tags --resources "${pub_rt_id}" \
    --tags "Key=Name,Value=${STACK_NAME}-public-rt" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  save_state "AUTO_PUBLIC_RT_ID" "${pub_rt_id}"
  log "Created public route table: ${pub_rt_id} (0.0.0.0/0 → ${igw_id})"

  # ---------- NAT Gateway EIP ----------
  local nat_eip_alloc
  nat_eip_alloc=$(aws ec2 allocate-address \
    --domain vpc \
    --region "${REGION}" \
    --query 'AllocationId' --output text)
  aws ec2 create-tags --resources "${nat_eip_alloc}" \
    --tags "Key=Name,Value=${STACK_NAME}-nat-eip" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  save_state "AUTO_NAT_EIP_ALLOC" "${nat_eip_alloc}"

  # ---------- NAT Gateway (in public subnet) ----------
  local nat_gw_id
  nat_gw_id=$(aws ec2 create-nat-gateway \
    --subnet-id "${INSTALLER_SUBNET_ID}" \
    --allocation-id "${nat_eip_alloc}" \
    --region "${REGION}" \
    --query 'NatGateway.NatGatewayId' --output text)
  aws ec2 create-tags --resources "${nat_gw_id}" \
    --tags "Key=Name,Value=${STACK_NAME}-nat" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  save_state "AUTO_NAT_GW_ID" "${nat_gw_id}"
  log "Creating NAT Gateway: ${nat_gw_id} (this takes ~60s)..."
  aws ec2 wait nat-gateway-available \
    --nat-gateway-ids "${nat_gw_id}" \
    --region "${REGION}"
  log "NAT Gateway ready: ${nat_gw_id}"

  # ---------- Private subnet + route table ----------
  SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id "${VPC_ID}" \
    --cidr-block "${PRIVATE_CIDR}" \
    --availability-zone "${AZ}" \
    --region "${REGION}" \
    --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources "${SUBNET_ID}" \
    --tags "Key=Name,Value=${STACK_NAME}-private-${AZ}" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  save_state "AUTO_PRIVATE_SUBNET_ID" "${SUBNET_ID}"
  log "Created private subnet: ${SUBNET_ID} (${PRIVATE_CIDR})"

  local priv_rt_id
  priv_rt_id=$(aws ec2 create-route-table \
    --vpc-id "${VPC_ID}" \
    --region "${REGION}" \
    --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route \
    --route-table-id "${priv_rt_id}" \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id "${nat_gw_id}" \
    --region "${REGION}" &>/dev/null
  aws ec2 associate-route-table \
    --route-table-id "${priv_rt_id}" \
    --subnet-id "${SUBNET_ID}" \
    --region "${REGION}" &>/dev/null
  aws ec2 create-tags --resources "${priv_rt_id}" \
    --tags "Key=Name,Value=${STACK_NAME}-private-rt" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  save_state "AUTO_PRIVATE_RT_ID" "${priv_rt_id}"
  log "Created private route table: ${priv_rt_id} (0.0.0.0/0 → ${nat_gw_id})"

  log "Network stack ready: VPC=${VPC_ID}  public=${INSTALLER_SUBNET_ID}  private=${SUBNET_ID}"
}

# -- Tear down auto-created network resources (called from cmd_destroy) --
destroy_network() {
  # Only resources tagged AUTO_* in state file are cleaned up here.
  # Executed in reverse creation order (instances already terminated by this point).

  if [[ -n "${AUTO_PRIVATE_RT_ID:-}" ]]; then
    log "Deleting private route table ${AUTO_PRIVATE_RT_ID}..."
    aws ec2 disassociate-route-table \
      --association-id "$(aws ec2 describe-route-tables \
        --route-table-ids "${AUTO_PRIVATE_RT_ID}" --region "${REGION}" \
        --query 'RouteTables[0].Associations[0].RouteTableAssociationId' \
        --output text 2>/dev/null || echo "")" \
      --region "${REGION}" 2>/dev/null || true
    aws ec2 delete-route-table \
      --route-table-id "${AUTO_PRIVATE_RT_ID}" \
      --region "${REGION}" 2>/dev/null || true
  fi

  if [[ -n "${AUTO_PRIVATE_SUBNET_ID:-}" ]]; then
    log "Deleting private subnet ${AUTO_PRIVATE_SUBNET_ID}..."
    aws ec2 delete-subnet \
      --subnet-id "${AUTO_PRIVATE_SUBNET_ID}" \
      --region "${REGION}" 2>/dev/null || true
  fi

  if [[ -n "${AUTO_NAT_GW_ID:-}" ]]; then
    log "Deleting NAT Gateway ${AUTO_NAT_GW_ID} (takes ~60s)..."
    aws ec2 delete-nat-gateway \
      --nat-gateway-id "${AUTO_NAT_GW_ID}" \
      --region "${REGION}" &>/dev/null || true
    aws ec2 wait nat-gateway-deleted \
      --nat-gateway-ids "${AUTO_NAT_GW_ID}" \
      --region "${REGION}" 2>/dev/null || \
      warn "NAT GW deletion still in progress; EIP release may need a retry"
  fi

  if [[ -n "${AUTO_NAT_EIP_ALLOC:-}" ]]; then
    log "Releasing NAT EIP ${AUTO_NAT_EIP_ALLOC}..."
    aws ec2 release-address \
      --allocation-id "${AUTO_NAT_EIP_ALLOC}" \
      --region "${REGION}" 2>/dev/null || true
  fi

  if [[ -n "${AUTO_PUBLIC_RT_ID:-}" ]]; then
    log "Deleting public route table ${AUTO_PUBLIC_RT_ID}..."
    aws ec2 disassociate-route-table \
      --association-id "$(aws ec2 describe-route-tables \
        --route-table-ids "${AUTO_PUBLIC_RT_ID}" --region "${REGION}" \
        --query 'RouteTables[0].Associations[0].RouteTableAssociationId' \
        --output text 2>/dev/null || echo "")" \
      --region "${REGION}" 2>/dev/null || true
    aws ec2 delete-route-table \
      --route-table-id "${AUTO_PUBLIC_RT_ID}" \
      --region "${REGION}" 2>/dev/null || true
  fi

  if [[ -n "${AUTO_PUBLIC_SUBNET_ID:-}" ]]; then
    log "Deleting public subnet ${AUTO_PUBLIC_SUBNET_ID}..."
    aws ec2 delete-subnet \
      --subnet-id "${AUTO_PUBLIC_SUBNET_ID}" \
      --region "${REGION}" 2>/dev/null || true
  fi

  if [[ -n "${AUTO_IGW_ID:-}" ]] && [[ -n "${AUTO_VPC_ID:-}" ]]; then
    log "Detaching and deleting IGW ${AUTO_IGW_ID}..."
    aws ec2 detach-internet-gateway \
      --internet-gateway-id "${AUTO_IGW_ID}" \
      --vpc-id "${AUTO_VPC_ID}" \
      --region "${REGION}" 2>/dev/null || true
    aws ec2 delete-internet-gateway \
      --internet-gateway-id "${AUTO_IGW_ID}" \
      --region "${REGION}" 2>/dev/null || true
  fi

  if [[ -n "${AUTO_VPC_ID:-}" ]]; then
    log "Deleting VPC ${AUTO_VPC_ID}..."
    aws ec2 delete-vpc \
      --vpc-id "${AUTO_VPC_ID}" \
      --region "${REGION}" 2>/dev/null || \
      warn "Could not delete VPC ${AUTO_VPC_ID} — may still have dependent resources"
  fi
}

# -- Pick subnets: k0s nodes in private, installer in public --
pick_subnet() {
  # k0s node subnet
  if [[ -n "$SUBNET_ID" ]]; then
    log "Using configured k0s subnet: ${SUBNET_ID}"
  else
    SUBNET_ID=$(aws ec2 describe-subnets --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
                "Name=availabilityZone,Values=${AZ}" \
      --query 'Subnets[?Tags[?Key==`Name`] | [?contains(Value, `private`)] | [0]] | [0].SubnetId' \
      --output text 2>/dev/null || echo "")
    if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
      SUBNET_ID=$(aws ec2 describe-subnets --region "${REGION}" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
                  "Name=availabilityZone,Values=${AZ}" \
        --query 'Subnets[0].SubnetId' --output text)
    fi
    [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]] && \
      err "No k0s subnet found in VPC ${VPC_ID} / AZ ${AZ}. Set network.subnetId in config."
    log "Auto-selected k0s subnet: ${SUBNET_ID} (${AZ})"
  fi

  # Installer subnet — must be public (has IGW route) for inbound SSH via EIP
  if [[ -n "$INSTALLER_SUBNET_ID" ]]; then
    log "Using configured installer subnet: ${INSTALLER_SUBNET_ID}"
  else
    INSTALLER_SUBNET_ID=$(aws ec2 describe-subnets --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
                "Name=availabilityZone,Values=${AZ}" \
      --query 'Subnets[?Tags[?Key==`Name`] | [?contains(Value, `public`)] | [0]] | [0].SubnetId' \
      --output text 2>/dev/null || echo "")
    if [[ -z "$INSTALLER_SUBNET_ID" || "$INSTALLER_SUBNET_ID" == "None" ]]; then
      # Fallback: use same subnet as k0s nodes and warn
      INSTALLER_SUBNET_ID="$SUBNET_ID"
      warn "No public subnet found in ${AZ}; installer will use the same private subnet as k0s nodes."
      warn "EIP may not be SSH-reachable. Set network.installerSubnetId to the public subnet."
    else
      log "Auto-selected installer subnet (public): ${INSTALLER_SUBNET_ID} (${AZ})"
    fi
  fi
}

# -- RHEL 9 AMI --
get_rhel9_ami() {
  local ami
  ami=$(aws ec2 describe-images \
    --owners 309956199498 \
    --filters "Name=name,Values=RHEL-9.*_HVM-*-x86_64-*" \
              "Name=state,Values=available" \
              "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text --region "${REGION}" 2>/dev/null)
  [[ -z "$ami" || "$ami" == "None" ]] && \
    err "Could not find RHEL 9 AMI in region ${REGION}."
  log "RHEL 9 AMI: ${ami}"
  echo "$ami"
}

# -- Key pair --
ensure_key_pair() {
  if [[ -z "$KEY_NAME" ]]; then
    KEY_NAME="${STACK_NAME}-key"
    if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" \
        --region "${REGION}" &>/dev/null; then
      warn "Key pair '${KEY_NAME}' already exists in AWS — reusing."
      if [[ ! -f "$KEY_LOCAL" ]]; then warn "Local key file not found at ${KEY_LOCAL}. You may need to set keyPair.localPath."; fi
    else
      aws ec2 create-key-pair \
        --key-name "${KEY_NAME}" \
        --query 'KeyMaterial' \
        --output text \
        --region "${REGION}" > "${KEY_LOCAL}"
      chmod 600 "${KEY_LOCAL}"
      log "Key pair created, saved to: ${KEY_LOCAL}"
      local kp_id
      kp_id=$(aws ec2 describe-key-pairs --key-names "${KEY_NAME}" \
        --region "${REGION}" --query 'KeyPairs[0].KeyPairId' --output text 2>/dev/null || echo "")
      if [[ -n "$kp_id" ]]; then
        aws ec2 create-tags \
          --resources "${kp_id}" \
          --tags "Key=${TAG_KEY},Value=${STACK_NAME}" "Key=auto-created,Value=true" \
          --region "${REGION}" 2>/dev/null || true
      fi
    fi
  else
    log "Using existing key pair: ${KEY_NAME}"
    if [[ ! -f "$KEY_LOCAL" ]]; then warn "Key file not found at ${KEY_LOCAL}. Set keyPair.localPath in config."; fi
  fi
}

# -- Create or reuse a security group for this stack --
ensure_security_group() {
  # Check if our SG already exists
  local existing
  existing=$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=group-name,Values=${STACK_NAME}-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
  if [[ -n "$existing" && "$existing" != "None" ]]; then
    SG_ID="$existing"
    log "Reusing existing security group: ${SG_ID}"
    return
  fi

  log "Creating security group..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "${STACK_NAME}-sg" \
    --description "k0s cluster ${STACK_NAME} - all private-IP traffic + SSH" \
    --vpc-id "${VPC_ID}" \
    --region "${REGION}" \
    --query 'GroupId' --output text)

  # Self-referencing: all intra-cluster traffic
  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --ip-permissions "[{\"IpProtocol\":\"-1\",\"UserIdGroupPairs\":[{\"GroupId\":\"${SG_ID}\"}]}]" \
    --region "${REGION}" &>/dev/null

  # SSH from allowed CIDR (for EIP-bound installer)
  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp --port 22 \
    --cidr "${SSH_CIDR}" \
    --region "${REGION}" &>/dev/null

  aws ec2 create-tags --resources "${SG_ID}" \
    --tags "Key=Name,Value=${STACK_NAME}-sg" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"
  log "Security group: ${SG_ID}"
}

# -- UserData builders --
userdata_base() {
  cat <<'UD'
#!/bin/bash
set -e
echo 'ec2-user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ec2-user-nopasswd
chmod 440 /etc/sudoers.d/ec2-user-nopasswd
mkdir -p /home/ec2-user/.ssh
printf 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' \
  >> /home/ec2-user/.ssh/config
chown -R ec2-user:ec2-user /home/ec2-user/.ssh
chmod 700 /home/ec2-user/.ssh
chmod 600 /home/ec2-user/.ssh/config
UD
}

userdata_mount() {
  local mp="$1"
  cat <<MOUNT
mount_data_disk() {
  local dev=""
  for c in /dev/nvme1n1 /dev/xvdb /dev/sdb; do [ -b "\$c" ] && dev="\$c" && break; done
  [ -z "\$dev" ] && { echo "WARNING: data disk not found, skipping ${mp} mount" >&2; return; }
  blkid "\$dev" &>/dev/null || mkfs.xfs -f "\$dev"
  mkdir -p "${mp}"
  grep -q "\$dev" /etc/fstab || echo "\$dev ${mp} xfs defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q "${mp}" || mount "${mp}"
}
mount_data_disk
MOUNT
}

make_userdata() {
  local mp="${1:-}"
  local ud
  ud="$(userdata_base)"
  [[ -n "$mp" ]] && ud+=$'\n'"$(userdata_mount "$mp")"
  printf '%s' "$ud" | base64 | tr -d '\n'
}

# -- Launch one EC2 instance (SCP-compliant: IMDSv2 + encrypted EBS) --
# Usage: launch_instance <label> <type> <diskGb> <userdata_b64> [subnet_id_override]
launch_instance() {
  local label="$1" itype="$2" disk="$3" userdata_b64="$4"
  local subnet="${5:-${SUBNET_ID}}"
  local id
  id=$(aws ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${itype}" \
    --key-name "${KEY_NAME}" \
    --count 1 \
    --subnet-id "${subnet}" \
    --security-group-ids "${SG_ID}" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${disk},\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
    --user-data "${userdata_b64}" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-${label}},{Key=${TAG_KEY},Value=${STACK_NAME}},{Key=k0s-role,Value=${label}},{Key=project,Value=ai-platform},{Key=env,Value=dev}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${STACK_NAME}-${label}-root},{Key=${TAG_KEY},Value=${STACK_NAME}}]" \
    --region "${REGION}" \
    --query 'Instances[0].InstanceId' \
    --output text 2>&1) || err "Failed to launch ${label}: ${id}"
  log "Launched ${label}: ${id}"
  echo "${id}"
}

# -- Wait for instance running --
wait_running() {
  local id="$1" label="$2"
  log "Waiting for ${label} (${id}) to be running..."
  aws ec2 wait instance-running --instance-ids "${id}" --region "${REGION}"
  log "${label} is running."
}

# -- Attach a data EBS volume (encrypted) --
attach_data_volume() {
  local instance_id="$1" label="$2" size_gb="$3"
  log "Creating ${size_gb}GB encrypted data volume for ${label}..."
  local vol_id
  vol_id=$(aws ec2 create-volume \
    --availability-zone "${AZ}" \
    --size "${size_gb}" \
    --volume-type gp3 \
    --encrypted \
    --tag-specifications \
      "ResourceType=volume,Tags=[{Key=Name,Value=${STACK_NAME}-${label}-data},{Key=${TAG_KEY},Value=${STACK_NAME}}]" \
    --region "${REGION}" \
    --query 'VolumeId' --output text)
  log "Volume ${vol_id} created. Waiting for available..."
  aws ec2 wait volume-available --volume-ids "${vol_id}" --region "${REGION}"
  aws ec2 attach-volume \
    --volume-id "${vol_id}" \
    --instance-id "${instance_id}" \
    --device /dev/sdb \
    --region "${REGION}" &>/dev/null
  log "Volume ${vol_id} attached to ${instance_id}."
  echo "${vol_id}"
}

get_private_ip() {
  local id="$1"
  aws ec2 describe-instances --instance-ids "${id}" --region "${REGION}" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
}

# -- Mount data disk via SSH (direct or via jump) after EBS attach --
# Usage: mount_disk_via_ssh <host> <mount_point> [jump_host]
mount_disk_via_ssh() {
  local host="$1" mp="$2" jump="${3:-}"
  local ssh_opts=(-i "${KEY_LOCAL}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)
  if [[ -n "${jump}" ]]; then
    ssh_opts+=(-o "ProxyCommand=ssh -i ${KEY_LOCAL} -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 -W %h:%p ec2-user@${jump}")
  fi
  log "Mounting ${mp} on ${host}..."
  ssh "${ssh_opts[@]}" "ec2-user@${host}" "sudo bash -s" <<MOUNTSCRIPT
set -e
dev=""
for c in /dev/nvme1n1 /dev/xvdb /dev/sdb; do [ -b "\$c" ] && dev="\$c" && break; done
[ -z "\$dev" ] && { echo "ERROR: data disk not found on ${host}" >&2; exit 1; }
blkid "\$dev" &>/dev/null || mkfs.xfs -f "\$dev"
mkdir -p "${mp}"
grep -q "\$dev" /etc/fstab || echo "\$dev ${mp} xfs defaults,nofail 0 2" >> /etc/fstab
mountpoint -q "${mp}" || mount "${mp}"
echo "Mounted \$dev at ${mp}"
MOUNTSCRIPT
  log "${mp} mounted on ${host}"
}

# -- Wait for SSH (via EIP for installer, via jump for k0s nodes) --
wait_for_ssh_direct() {
  local host="$1" label="$2" timeout=600 elapsed=0
  log "Waiting for SSH on ${label} (${host})..."
  while ! ssh -i "${KEY_LOCAL}" \
      -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
      "ec2-user@${host}" 'true' 2>/dev/null; do
    sleep 10; elapsed=$((elapsed+10))
    [[ $elapsed -ge $timeout ]] && err "SSH to ${label} (${host}) timed out after ${timeout}s"
    echo -n "."
  done
  echo ""; log "SSH ready: ${label} (${host})"
}

wait_for_ssh_via_jump() {
  local jump="$1" host="$2" label="$3" timeout=600 elapsed=0
  log "Waiting for SSH on ${label} (${host}) via jump ${jump}..."
  # Use ProxyCommand so the explicit -i key is forwarded to the jump hop
  while ! ssh -i "${KEY_LOCAL}" \
      -o "ProxyCommand=ssh -i ${KEY_LOCAL} -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 -W %h:%p ec2-user@${jump}" \
      -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
      "ec2-user@${host}" 'true' 2>/dev/null; do
    sleep 10; elapsed=$((elapsed+10))
    [[ $elapsed -ge $timeout ]] && err "SSH to ${label} (${host}) via ${jump} timed out after ${timeout}s"
    echo -n "."
  done
  echo ""; log "SSH ready: ${label} (${host})"
}

# -- Setup installer machine --
setup_installer() {
  local eip="$1"
  log "Copying SSH key to installer..."
  scp -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no \
    "${KEY_LOCAL}" "ec2-user@${eip}:~/.ssh/id_rsa"
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    'chmod 600 ~/.ssh/id_rsa'

  log "Installing prerequisites on installer (yq, kubectl, helm, jq)..."
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" 'bash -s' <<'PREREQ'
set -e
export PATH="$PATH:/usr/local/bin"
sudo dnf install -y git jq curl unzip 2>/dev/null || sudo yum install -y git jq curl unzip
command -v yq &>/dev/null || {
  sudo curl -sSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
  sudo chmod +x /usr/local/bin/yq
}
command -v kubectl &>/dev/null || {
  K8S_VER=$(curl -sSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo v1.32.0)
  sudo curl -sSL -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${K8S_VER}/bin/linux/amd64/kubectl"
  sudo chmod +x /usr/local/bin/kubectl
}
command -v helm &>/dev/null || \
  curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo "Prerequisites ready."
PREREQ

  log "Copying k0s cluster scripts to installer..."
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    'mkdir -p ~/cluster_setup'
  scp -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no \
    "${SCRIPT_DIR}/"*.sh "${SCRIPT_DIR}/"*.yaml \
    "ec2-user@${eip}:~/cluster_setup/" 2>/dev/null || true
}

# -- MinIO install --
install_minio() {
  local eip="$1" installer_priv_ip="$2"
  [[ ! -f "$MINIO_INSTALL_SCRIPT" ]] && err "MinIO install script not found: ${MINIO_INSTALL_SCRIPT}"
  [[ -z "$MINIO_PASS" ]] && \
    MINIO_PASS=$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)

  log "Installing MinIO on installer (http://${installer_priv_ip}:${MINIO_PORT})..."
  scp -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no \
    "${MINIO_INSTALL_SCRIPT}" "ec2-user@${eip}:~/install_minio_ec2.sh"

  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    "sudo bash ~/install_minio_ec2.sh \
      --bucket '${MINIO_BUCKET}' \
      --user '${MINIO_USER}' \
      --password '${MINIO_PASS}' \
      --data-dir /data/minio \
      --port ${MINIO_PORT}"
  log "MinIO ready at http://${installer_priv_ip}:${MINIO_PORT}"
}

# -- Push auto-generated k0s config to installer --
push_k0s_config() {
  local eip="$1" installer_priv_ip="$2"
  load_state

  local ctrl_yaml="" worker_yaml=""
  for v in $(compgen -v | grep '^CTRL_IP_' | sort); do
    ctrl_yaml+="      - ${!v}"$'\n'
  done
  for v in $(compgen -v | grep '^CPU_IP_' | sort); do
    worker_yaml+="      - ${!v}  # cpu-worker"$'\n'
  done
  for v in $(compgen -v | grep '^GPU_IP_' | sort); do
    worker_yaml+="      - ${!v}  # gpu-worker"$'\n'
  done

  local minio_block=""
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    minio_block="    endpoint: \"http://${installer_priv_ip}:${MINIO_PORT}\"
    auth:
      rootUser: \"${MINIO_USER}\"
      rootPassword: \"${MINIO_PASS}\""
  fi

  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    "cat > ~/cluster_setup/my-k0s-config.yaml" <<KCEOF
# Auto-generated by k0s_aws_provision.sh -- $(date -Iseconds 2>/dev/null || date)
# Stack: ${STACK_NAME} / Region: ${REGION}
# Run: CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml ~/cluster_setup/k0s_cluster_with_stack.sh install

cluster:
  name: ${STACK_NAME}-cluster
  region: ${REGION}
  sshKeyPath: ~/.ssh/id_rsa
  sshUser: ec2-user

nodes:
  existingIPs:
    controllers:
${ctrl_yaml}    workers:
${worker_yaml}
storage:
  storageClass: local-path
  vectorDbSize: 50Gi
  objectStore:
    type: minio
    bucket: ${MINIO_BUCKET}
${minio_block}

images:
  registry: ""
  registryInsecure: false
  operator:
    image: "docker.io/splunk/splunk-ai-operator:0.2.0"
  splunk:
    image: "docker.io/splunk/splunk:10.2-rhel9"
    operatorImage: "docker.io/splunk/splunk-operator:3.0.0"
  ray:
    headImage: "splunk/ray-head-build-preview:latest"
    workerImage: "splunk/ray-worker-gpu-build-preview:latest"
  weaviate:
    image: "docker.io/semitechnologies/weaviate:stable-v1.28-007846a"
  saia:
    apiImage: "splunk/saia-api-build-preview:latest"
    apiV2Image: "splunk/saia-api-v2-build-preview:latest"
    dataLoaderImage: "splunk/saia-data-loader-build-preview:latest"
  fluentBit:
    image: "docker.io/fluent/fluent-bit:1.9.6"
  otelCollector:
    image: "docker.io/otel/opentelemetry-collector-contrib:0.122.1"
  nginx:
    image: "docker.io/library/nginx:1.27-alpine"

operators:
  ray:
    version: "v1.2.2"
    modelVersion: "v0.3.14-36-g1549f5a"
    rayVersion: "2.53.0"
  certManager:
    installCRDs: true
  nvidia:
    devicePluginVersion: "v0.17.3"

kubernetes:
  namespace: ai-platform

files:
  splunkOperator: "./splunk-operator-cluster.yaml"
  aiPlatform: "./artifacts.yaml"

splunk:
  enabled: false

aiPlatform:
  name: "splunk-ai-stack"
  defaultAcceleratorType: "L40S"
  workerGroupConfig:
    imageRegistry: ""
  serviceTemplate:
    type: NodePort
    nodePort: 30080
  features:
    - name: "saia"
      version: "1.1.0"
  cpuScheduling:
    nodeSelector: {}
    tolerations: []
  gpuScheduling:
    nodeSelector: {}
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"

metallb:
  install: false
  chartVersion: "0.14.8"
  namespace: "metallb-system"
  pool:
    name: "saia-pool"
    addresses:
      - "10.0.34.200-10.0.34.210"

imagePullSecrets:
  secrets:
    - ecr-registry-secret
  autoCreateECR: false

ecr:
  account: ""
  region: ${REGION}
KCEOF
  log "k0s config written to installer: ~/cluster_setup/my-k0s-config.yaml"
}

# ============================================================
# PROVISION
# ============================================================
cmd_provision() {
  load_config
  check_aws_auth

  if [[ -f "${STATE_FILE}" ]]; then
    warn "State file exists: ${STATE_FILE}"
    warn "Stack may already be provisioned. Run 'status' to check, or 'destroy' first."
    if [[ -t 0 ]]; then
      read -r -p "Continue anyway? [y/N]: " cont < /dev/tty
      [[ "$(echo "${cont}" | tr '[:upper:]' '[:lower:]')" != "y" ]] && { log "Aborted."; return 1; }
    else
      err "State file exists and stdin is not a TTY. Remove ${STATE_FILE} manually if you want to re-provision."
    fi
  fi

  : > "${STATE_FILE}"
  log "=== k0s AWS Provisioner ==="
  log "Stack: ${STACK_NAME}  Region: ${REGION}  AZ: ${AZ}"

  AMI_ID=$(get_rhel9_ami)
  ensure_network   # no-op when VPC_ID is already set; creates full stack otherwise
  log "VPC: ${VPC_ID}"
  pick_subnet
  save_state "SUBNET_ID" "${SUBNET_ID}"
  save_state "INSTALLER_SUBNET_ID" "${INSTALLER_SUBNET_ID}"
  ensure_key_pair
  ensure_security_group
  save_state "SG_ID" "${SG_ID}"

  # ---------- Launch instances ----------
  local ud_k0s ud_gpu ud_installer
  ud_k0s=$(make_userdata "")
  ud_gpu=$(make_userdata "/var/lib/k0s")
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    ud_installer=$(make_userdata "/data/minio")
  else
    ud_installer=$(make_userdata "")
  fi

  for ((i=0; i<CTRL_COUNT; i++)); do
    local id; id=$(launch_instance "controller-${i}" "${CTRL_TYPE}" "${CTRL_DISK}" "${ud_k0s}")
    save_state "CTRL_INSTANCE_${i}" "${id}"
  done

  for ((i=0; i<CPU_COUNT; i++)); do
    local id; id=$(launch_instance "cpu-worker-${i}" "${CPU_TYPE}" "${CPU_DISK}" "${ud_k0s}")
    save_state "CPU_INSTANCE_${i}" "${id}"
  done

  for ((i=0; i<GPU_COUNT; i++)); do
    local id; id=$(launch_instance "gpu-worker-${i}" "${GPU_TYPE}" "${GPU_DISK}" "${ud_gpu}")
    save_state "GPU_INSTANCE_${i}" "${id}"
  done

  local inst_id
  inst_id=$(launch_instance "installer" "${INST_TYPE}" "${INST_DISK}" "${ud_installer}" "${INSTALLER_SUBNET_ID}")
  save_state "INSTALLER_INSTANCE" "${inst_id}"

  # ---------- Wait for all running ----------
  load_state
  for v in $(compgen -v | grep '_INSTANCE'); do
    [[ -n "${!v}" ]] && wait_running "${!v}" "${v}"
  done

  # ---------- Attach data volumes ----------
  load_state
  for ((i=0; i<GPU_COUNT; i++)); do
    local inst_var="GPU_INSTANCE_${i}"
    load_state
    local vid; vid=$(attach_data_volume "${!inst_var}" "gpu-worker-${i}" "${GPU_DATA_DISK}")
    save_state "GPU_VOL_${i}" "${vid}"
  done
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    load_state
    local vid; vid=$(attach_data_volume "${INSTALLER_INSTANCE}" "minio" "${MINIO_DATA_DISK}")
    save_state "MINIO_VOL" "${vid}"
  fi

  # ---------- Elastic IP for installer ----------
  log "Allocating Elastic IP for installer..."
  local eip_alloc eip
  eip_alloc=$(aws ec2 allocate-address --domain vpc --region "${REGION}" \
    --query 'AllocationId' --output text)
  aws ec2 create-tags --resources "${eip_alloc}" \
    --tags "Key=Name,Value=${STACK_NAME}-installer-eip" "Key=${TAG_KEY},Value=${STACK_NAME}" \
    --region "${REGION}"

  load_state
  aws ec2 associate-address \
    --allocation-id "${eip_alloc}" \
    --instance-id "${INSTALLER_INSTANCE}" \
    --region "${REGION}" &>/dev/null
  eip=$(aws ec2 describe-addresses --allocation-ids "${eip_alloc}" \
    --region "${REGION}" --query 'Addresses[0].PublicIp' --output text)
  save_state "EIP_ALLOC" "${eip_alloc}"
  save_state "EIP" "${eip}"
  log "Installer EIP: ${eip}"

  # ---------- Collect private IPs ----------
  load_state
  for ((i=0; i<CTRL_COUNT; i++)); do
    local v="CTRL_INSTANCE_${i}"; load_state
    local ip; ip=$(get_private_ip "${!v}")
    save_state "CTRL_IP_${i}" "${ip}"
  done
  for ((i=0; i<CPU_COUNT; i++)); do
    local v="CPU_INSTANCE_${i}"; load_state
    local ip; ip=$(get_private_ip "${!v}")
    save_state "CPU_IP_${i}" "${ip}"
  done
  for ((i=0; i<GPU_COUNT; i++)); do
    local v="GPU_INSTANCE_${i}"; load_state
    local ip; ip=$(get_private_ip "${!v}")
    save_state "GPU_IP_${i}" "${ip}"
  done
  load_state
  local installer_priv_ip; installer_priv_ip=$(get_private_ip "${INSTALLER_INSTANCE}")
  save_state "INSTALLER_PRIV_IP" "${installer_priv_ip}"

  # ---------- Wait for SSH ----------
  load_state
  wait_for_ssh_direct "${EIP}" "installer"

  for v in $(compgen -v | grep '^CTRL_IP_\|^CPU_IP_\|^GPU_IP_'); do
    [[ -z "${!v}" ]] && continue
    wait_for_ssh_via_jump "${EIP}" "${!v}" "${v}"
  done

  # ---------- Mount data disks via SSH (EBS is attached after boot) ----------
  load_state
  for ((i=0; i<GPU_COUNT; i++)); do
    local gpu_ip_var="GPU_IP_${i}"
    [[ -n "${!gpu_ip_var}" ]] && \
      mount_disk_via_ssh "${!gpu_ip_var}" "/var/lib/k0s" "${EIP}"
  done
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    mount_disk_via_ssh "${EIP}" "/data/minio"
  fi

  # ---------- Setup installer ----------
  setup_installer "${EIP}"

  # ---------- MinIO ----------
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    load_state
    install_minio "${EIP}" "${INSTALLER_PRIV_IP}"
    save_state "MINIO_PASS" "${MINIO_PASS}"
  fi

  # ---------- Push k0s config ----------
  load_state
  push_k0s_config "${EIP}" "${INSTALLER_PRIV_IP}"

  cmd_output
}

# ============================================================
# OUTPUT
# ============================================================
cmd_output() {
  load_config
  [[ ! -f "${STATE_FILE}" ]] && err "No state file found. Run 'provision' first."
  load_state

  echo ""
  echo "================================================================"
  echo "  k0s AWS Provision -- Output"
  echo "  Stack: ${STACK_NAME}  Region: ${REGION}"
  echo "================================================================"
  echo ""
  echo "=== Paste into your k0s-cluster-config.yaml ==="
  echo ""
  echo "  cluster:"
  echo "    sshKeyPath: ${KEY_LOCAL}"
  echo "    sshUser: ec2-user"
  echo ""
  echo "  nodes:"
  echo "    existingIPs:"
  echo "      controllers:"
  for v in $(compgen -v | grep '^CTRL_IP_' | sort); do echo "        - ${!v}"; done
  echo "      workers:"
  for v in $(compgen -v | grep '^CPU_IP_'  | sort); do echo "        - ${!v}  # cpu-worker"; done
  for v in $(compgen -v | grep '^GPU_IP_'  | sort); do echo "        - ${!v}  # gpu-worker"; done
  if [[ "${MINIO_ENABLED}" == "true" ]]; then
    echo ""
    echo "  storage:"
    echo "    objectStore:"
    echo "      type: minio"
    echo "      bucket: ${MINIO_BUCKET}"
    echo "      endpoint: \"http://${INSTALLER_PRIV_IP}:${MINIO_PORT}\""
    echo "      auth:"
    echo "        rootUser: ${MINIO_USER}"
    echo "        rootPassword: ${MINIO_PASS:-<check state file>}"
  fi
  echo ""
  echo "================================================================"
  echo "  SSH to installer:"
  echo "    ssh -i ${KEY_LOCAL} ec2-user@${EIP}"
  echo ""
  echo "  Auto-generated k0s config on installer:"
  echo "    ~/cluster_setup/my-k0s-config.yaml"
  echo ""
  echo "  Run install from installer:"
  echo "    CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml \\"
  echo "      ~/cluster_setup/k0s_cluster_with_stack.sh install"
  echo "================================================================"
}

# ============================================================
# STATUS
# ============================================================
cmd_status() {
  load_config
  [[ ! -f "${STATE_FILE}" ]] && { log "No state file for '${STACK_NAME}'."; return; }
  load_state
  echo ""
  echo "Stack: ${STACK_NAME}  Region: ${REGION}  State: ${STATE_FILE}"
  echo ""
  aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=tag:${TAG_KEY},Values=${STACK_NAME}" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],PrivateIpAddress,State.Name,InstanceType]' \
    --output table 2>/dev/null || true
  echo ""
  if [[ "${MINIO_ENABLED:-false}" == "true" && -n "${EIP:-}" ]]; then
    echo -n "MinIO health (${EIP}): "
    local code
    code=$(ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "ec2-user@${EIP}" \
      "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${MINIO_PORT}/minio/health/live" \
      2>/dev/null || echo "unreachable")
    [[ "$code" == "200" ]] && echo "OK" || echo "FAIL (${code})"
  fi
}

# ============================================================
# DESTROY
# ============================================================
cmd_destroy() {
  load_config
  [[ ! -f "${STATE_FILE}" ]] && { log "No state file for '${STACK_NAME}'. Nothing to destroy."; return; }
  load_state

  echo ""
  echo "WARNING: Permanently destroying all resources for stack '${STACK_NAME}' in ${REGION}."
  local confirm=""
  if [[ "${FORCE_DESTROY}" == "true" ]]; then
    confirm="${STACK_NAME}"
  elif [[ -t 0 ]]; then
    read -r -p "Type the stack name to confirm: " confirm < /dev/tty
  else
    err "Destroy requires interactive confirmation. Run from a terminal or use --yes."
  fi
  [[ "$confirm" != "${STACK_NAME}" ]] && { log "Confirmation mismatch -- aborted."; return 1; }

  # Collect all instance IDs
  local instance_ids=()
  for v in $(compgen -v | grep '_INSTANCE'); do
    [[ -n "${!v}" ]] && instance_ids+=("${!v}")
  done
  if [[ ${#instance_ids[@]} -gt 0 ]]; then
    log "Terminating instances: ${instance_ids[*]}"
    aws ec2 terminate-instances --instance-ids "${instance_ids[@]}" \
      --region "${REGION}" &>/dev/null || true
    log "Waiting for termination..."
    aws ec2 wait instance-terminated --instance-ids "${instance_ids[@]}" \
      --region "${REGION}" 2>/dev/null || warn "Wait timed out — instances may still be shutting down"
  fi

  # Release EIP
  if [[ -n "${EIP_ALLOC:-}" ]]; then
    log "Releasing EIP ${EIP_ALLOC}..."
    aws ec2 release-address --allocation-id "${EIP_ALLOC}" \
      --region "${REGION}" 2>/dev/null || true
  fi

  # Delete data volumes
  for v in $(compgen -v | grep '^GPU_VOL_\|^MINIO_VOL$'); do
    [[ -z "${!v}" ]] && continue
    log "Deleting volume ${!v}..."
    aws ec2 wait volume-available --volume-ids "${!v}" --region "${REGION}" 2>/dev/null || true
    aws ec2 delete-volume --volume-id "${!v}" --region "${REGION}" 2>/dev/null || true
  done

  # Delete security group (only if we created it — identified by tag)
  if [[ -n "${SG_ID:-}" ]]; then
    local sg_tag
    sg_tag=$(aws ec2 describe-security-groups --region "${REGION}" \
      --group-ids "${SG_ID}" \
      --query "SecurityGroups[0].Tags[?Key=='${TAG_KEY}'].Value|[0]" \
      --output text 2>/dev/null || echo "")
    if [[ "$sg_tag" == "${STACK_NAME}" ]]; then
      log "Deleting security group ${SG_ID}..."
      aws ec2 delete-security-group --group-id "${SG_ID}" \
        --region "${REGION}" 2>/dev/null || warn "Could not delete SG ${SG_ID} (may still have dependencies)"
    fi
  fi

  # Delete auto-created key pair
  local auto_key="${STACK_NAME}-key"
  local kp_auto
  kp_auto=$(aws ec2 describe-key-pairs --key-names "${auto_key}" --region "${REGION}" \
    --query 'KeyPairs[0].Tags[?Key==`auto-created`].Value|[0]' \
    --output text 2>/dev/null || echo "")
  if [[ "$kp_auto" == "true" ]]; then
    log "Deleting auto-created key pair: ${auto_key}"
    aws ec2 delete-key-pair --key-name "${auto_key}" --region "${REGION}" 2>/dev/null || true
    if [[ -f "${KEY_LOCAL}" ]]; then
      local del_local="n"
      if [[ "${FORCE_DESTROY}" == "true" ]]; then
        del_local="y"
      elif [[ -t 0 ]]; then
        read -r -p "Delete local key file ${KEY_LOCAL}? [y/N]: " del_local < /dev/tty
      fi
      [[ "$(echo "${del_local}" | tr '[:upper:]' '[:lower:]')" == "y" ]] && rm -f "${KEY_LOCAL}" && log "Deleted ${KEY_LOCAL}"
    fi
  fi

  # Tear down auto-created network stack (only if ensure_network created it)
  destroy_network

  rm -f "${STATE_FILE}"
  log "Destroy complete."
}

# ============================================================
# DRY RUN
# ============================================================
cmd_dryrun() {
  load_config
  check_aws_auth
  AMI_ID=$(get_rhel9_ami)
  pick_subnet
  ensure_key_pair
  echo ""
  if [[ "${AUTO_CREATE_NETWORK}" == "true" ]]; then
    echo "=== Dry-run: would create new network stack + instances ==="
    echo "  VPC (new)           : ${VPC_CIDR}"
    echo "  Public subnet (new) : ${PUBLIC_CIDR} (${AZ}) + IGW + NAT GW"
    echo "  Private subnet (new): ${PRIVATE_CIDR} (${AZ})"
  else
    echo "=== Dry-run: would create instances in existing VPC ${VPC_ID} ==="
    echo "  k0s nodes subnet    : ${SUBNET_ID} (${AZ}, private)"
    echo "  Installer subnet    : ${INSTALLER_SUBNET_ID} (${AZ}, public)"
  fi
  echo "  Security Group: new '${STACK_NAME}-sg' (self-ref + SSH from ${SSH_CIDR})"
  echo "  1 Installer    : ${INST_TYPE}, ${INST_DISK}GB root (encrypted) + EIP"
  echo "  ${CTRL_COUNT} Controller(s) : ${CTRL_TYPE}, ${CTRL_DISK}GB root (encrypted)"
  echo "  ${CPU_COUNT} CPU Worker(s)  : ${CPU_TYPE}, ${CPU_DISK}GB root (encrypted)"
  echo "  ${GPU_COUNT} GPU Worker(s)  : ${GPU_TYPE}, ${GPU_DISK}GB root (encrypted) + ${GPU_DATA_DISK}GB /var/lib/k0s"
  [[ "$MINIO_ENABLED" == "true" ]] && \
    echo "  MinIO on installer: ${MINIO_DATA_DISK}GB /data/minio"
  echo "  All instances: IMDSv2 required, EBS encrypted"
  echo "  State file: ${STATE_FILE}"
  echo ""
}

# ============================================================
# DISPATCH
# ============================================================
case "$COMMAND" in
  provision) cmd_provision ;;
  output)    load_config; load_state; cmd_output ;;
  status)    cmd_status ;;
  destroy)   cmd_destroy ;;
  dry-run)   cmd_dryrun ;;
  *) err "Unknown command: ${COMMAND}. Valid: provision output status destroy dry-run" ;;
esac
