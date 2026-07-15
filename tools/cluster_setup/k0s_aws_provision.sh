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

  # ECR configuration
  ECR_ACCOUNT="$(cfg_default '.ecr.account' '')"
  ECR_REGION="$(cfg_default  '.ecr.region'  "${REGION:-us-east-2}")"
  [[ "$ECR_ACCOUNT" == "null" ]] && ECR_ACCOUNT=""
  [[ "$ECR_REGION"  == "null" ]] && ECR_REGION="${REGION:-us-east-2}"

  # External SeaweedFS (or any S3-compatible store) — used when minio.enabled=false
  SEAWEED_ENDPOINT="$(cfg_default '.seaweedfs.endpoint' '')"
  SEAWEED_BUCKET="$(cfg_default   '.seaweedfs.bucket'   'ai-platform-bucket')"
  SEAWEED_USER="$(cfg_default     '.seaweedfs.rootUser'  'minioadmin')"
  SEAWEED_PASS="$(cfg_default     '.seaweedfs.rootPassword' 'minioadmin')"
  [[ "$SEAWEED_ENDPOINT" == "null" ]] && SEAWEED_ENDPOINT=""

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
#
# WARNING: auto-create network path (AUTO_CREATE_NETWORK=true) is UNTESTED.
# It has not been run against a real AWS account. Validate in a sandbox account
# before using in production. The existing-VPC path is fully tested.
ensure_network() {
  if [[ "${AUTO_CREATE_NETWORK}" != "true" ]]; then
    return
  fi

  warn "AUTO_CREATE_NETWORK=true — this code path is UNTESTED. Validate in a sandbox account first."
  log "Creating VPC and network stack..."

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
# WARNING: UNTESTED — see ensure_network warning above.
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

# -- Launch instance with AZ fallback (for GPU workers with scarce capacity) --
# Tries each subnet in FALLBACK_SUBNETS (space-separated) until one succeeds.
# Sets LAST_LAUNCHED_SUBNET to the subnet that worked (for EBS placement).
# Usage: launch_instance_az_fallback <label> <type> <diskGb> <userdata_b64> <subnet1> [subnet2 ...]
launch_instance_az_fallback() {
  local label="$1" itype="$2" disk="$3" userdata_b64="$4"
  shift 4
  local subnets=("$@")
  local id subnet
  for subnet in "${subnets[@]}"; do
    local az
    az=$(aws ec2 describe-subnets --subnet-ids "${subnet}" \
      --region "${REGION}" --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null)
    log "Trying ${label} in subnet ${subnet} (${az})..."
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
      --output text 2>&1) && {
        log "Launched ${label}: ${id} (${az})"
        LAST_LAUNCHED_SUBNET="${subnet}"
        echo "${id}"
        return 0
    }
    warn "No capacity for ${itype} in ${az} (${subnet}): ${id}"
  done
  err "Failed to launch ${label} (${itype}) — no capacity in any fallback AZ. Tried: ${subnets[*]}"
}

# -- Wait for instance running --
wait_running() {
  local id="$1" label="$2"
  log "Waiting for ${label} (${id}) to be running..."
  aws ec2 wait instance-running --instance-ids "${id}" --region "${REGION}"
  log "${label} is running."
}

# -- Attach a data EBS volume (encrypted) --
# Optional 4th arg: az_override — use when the instance is in a different AZ than $AZ
attach_data_volume() {
  local instance_id="$1" label="$2" size_gb="$3" vol_az="${4:-${AZ}}"
  log "Creating ${size_gb}GB encrypted data volume for ${label} in ${vol_az}..."
  local vol_id
  vol_id=$(aws ec2 create-volume \
    --availability-zone "${vol_az}" \
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
# Find the data disk: any block device not currently mounted and not the root disk.
# Checks nvme*n1 devices in order; skips nvme0n1 (root on AWS RHEL AMIs).
# Falls back to xvdb/sdb for non-NVMe instances.
dev=""
for c in /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/xvdb /dev/sdb; do
  [ -b "\$c" ] || continue
  mountpoint -q "\$(lsblk -no MOUNTPOINT \$c 2>/dev/null | head -1)" 2>/dev/null && continue
  lsblk -no MOUNTPOINT "\$c" 2>/dev/null | grep -q '/' && continue
  dev="\$c" && break
done
[ -z "\$dev" ] && { echo "ERROR: data disk not found on ${host} (tried nvme1n1..3n1, xvdb, sdb)" >&2; exit 1; }
blkid "\$dev" &>/dev/null || mkfs.xfs -f "\$dev"
mkdir -p "${mp}"
# Use UUID in fstab so entry survives kernel upgrades that rename nvme devices
DEV_UUID=\$(blkid -s UUID -o value "\$dev")
if ! grep -q "UUID=\${DEV_UUID}" /etc/fstab; then
  sed -i '\|${mp}|d' /etc/fstab
  echo "UUID=\${DEV_UUID} ${mp} xfs defaults,nofail 0 2" >> /etc/fstab
fi
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

# -- Verify outbound internet access from a private node via NAT --
# Usage: check_nat_connectivity <private_ip> <label> <jump_eip>
# Checks three endpoints that k0s install actually needs:
#   get.k0s.sh  — k0s binary download
#   developer.download.nvidia.com — NVIDIA driver repo
#   registry-1.docker.io — container image pulls
check_nat_connectivity() {
  local host="$1" label="$2" jump="$3"
  local proxy_opt="ProxyCommand=ssh -i ${KEY_LOCAL} -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 -W %h:%p ec2-user@${jump}"
  local ssh_base=(-i "${KEY_LOCAL}" -o "${proxy_opt}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "ec2-user@${host}")

  log "Checking NAT outbound connectivity on ${label} (${host})..."
  local failed=0
  local endpoints=("https://get.k0s.sh" "https://developer.download.nvidia.com" "https://registry-1.docker.io")
  for url in "${endpoints[@]}"; do
    local result
    result=$(ssh "${ssh_base[@]}" \
      "curl -sSf --max-time 10 -o /dev/null -w '%{http_code}' '${url}' 2>/dev/null || echo FAIL" \
      2>/dev/null || echo "FAIL")
    if [[ "$result" == "FAIL" || "$result" == "000" ]]; then
      warn "  ${label}: UNREACHABLE — ${url}"
      failed=1
    else
      log "  ${label}: OK (HTTP ${result}) — ${url}"
    fi
  done

  if [[ $failed -eq 1 ]]; then
    err "NAT connectivity check failed on ${label} (${host}). k0s install will fail without internet access.
Check: NAT Gateway exists and private subnet route table has 0.0.0.0/0 → NAT GW."
  fi
  log "NAT connectivity OK on ${label}"
}

# -- Setup installer machine --
setup_installer() {
  local eip="$1"
  log "Copying SSH key to installer..."
  scp -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no \
    "${KEY_LOCAL}" "ec2-user@${eip}:~/.ssh/id_rsa"
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    'chmod 600 ~/.ssh/id_rsa'

  # Forward AWS credentials to installer so ECR auth works during k0s install.
  # Priority: 1) long-lived keys from config (ecr.accessKeyId/secretAccessKey)
  #            2) current environment / dev-login resolved credentials
  # STS tokens from dev-login expire in ~1hr — use permanent IAM keys for
  # installs longer than that (model staging alone takes 2+ hrs).
  log "Forwarding AWS credentials to installer..."
  local ecr_key ecr_secret ecr_token ecr_region
  ecr_key=$(yq eval '.ecr.accessKeyId // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  ecr_secret=$(yq eval '.ecr.secretAccessKey // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  ecr_region=$(yq eval '.ecr.region // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  [[ -z "${ecr_region}" ]] && ecr_region="${REGION:-us-east-2}"

  if [[ -n "${ecr_key}" && "${ecr_key}" != "null" && \
        -n "${ecr_secret}" && "${ecr_secret}" != "null" ]]; then
    log "  Using long-lived ECR credentials from config (account: ${ECR_ACCOUNT})"
  else
    # Fall back to current environment — resolve via credential_process if needed
    ecr_key=$(AWS_PROFILE="${AWS_PROFILE:-}" aws configure get aws_access_key_id 2>/dev/null || echo "")
    ecr_secret=$(AWS_PROFILE="${AWS_PROFILE:-}" aws configure get aws_secret_access_key 2>/dev/null || echo "")
    ecr_token=$(AWS_PROFILE="${AWS_PROFILE:-}" aws configure get aws_session_token 2>/dev/null || echo "")
    # If configure get returns nothing, try env vars directly
    [[ -z "${ecr_key}" ]]    && ecr_key="${AWS_ACCESS_KEY_ID:-}"
    [[ -z "${ecr_secret}" ]] && ecr_secret="${AWS_SECRET_ACCESS_KEY:-}"
    [[ -z "${ecr_token}" ]]  && ecr_token="${AWS_SESSION_TOKEN:-}"
    if [[ -n "${ecr_key}" && -n "${ecr_secret}" ]]; then
      log "  Using environment AWS credentials (may be STS — expiry risk for long installs)"
      [[ "${ecr_key}" == ASIA* ]] && \
        warn "  STS credentials detected (ASIA*). ECR token expires in ~1hr. For installs >1hr set ecr.accessKeyId/secretAccessKey (permanent IAM key) in your config."
    else
      warn "  No AWS credentials found — ECR secret creation will be skipped on installer."
      warn "  To fix: run with AWS_PROFILE=splunkcloud-ai-dev or set ecr.accessKeyId in config."
    fi
  fi

  if [[ -n "${ecr_key}" && -n "${ecr_secret}" ]]; then
    ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
      "bash -s ${ecr_key} ${ecr_secret} $(printf '%q' "${ecr_token}") ${ecr_region}" <<'CREDSCRIPT'
set -e
AWS_KEY="$1"; AWS_SECRET="$2"; AWS_TOKEN="$3"; AWS_REGION="$4"
mkdir -p ~/.aws
# Write credentials — omit session_token line if empty (permanent IAM key)
{
  echo "[default]"
  echo "aws_access_key_id     = ${AWS_KEY}"
  echo "aws_secret_access_key = ${AWS_SECRET}"
  [[ -n "${AWS_TOKEN}" ]] && echo "aws_session_token     = ${AWS_TOKEN}"
} > ~/.aws/credentials
cat > ~/.aws/config <<EOF
[default]
region = ${AWS_REGION}
output = json
EOF
chmod 600 ~/.aws/credentials ~/.aws/config
echo "AWS credentials written to ~/.aws/ on installer."
CREDSCRIPT
    log "AWS credentials forwarded to installer"

    # Install AWS CLI on installer if not present (needed for ECR token refresh)
    ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" 'bash -s' <<'AWSCLI'
set -e
if ! command -v aws &>/dev/null; then
  echo "Installing AWS CLI v2..."
  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/
  sudo /tmp/aws/install --update
  rm -rf /tmp/awscliv2.zip /tmp/aws/
  echo "AWS CLI installed: $(aws --version)"
else
  echo "AWS CLI already present: $(aws --version)"
fi
AWSCLI
    log "AWS CLI ready on installer"
  fi

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
  # Copy artifacts_download_upload_scripts (sibling of cluster_setup) — required by model staging step
  local artifacts_dir="${SCRIPT_DIR}/../artifacts_download_upload_scripts"
  if [[ -d "${artifacts_dir}" ]]; then
    scp -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no -r \
      "${artifacts_dir}" "ec2-user@${eip}:~/" 2>/dev/null || true
    log "Copied artifacts_download_upload_scripts to installer"
    # Redirect model downloads to the MinIO data disk (/data/minio) to avoid filling the root disk.
    # download_from_huggingface.sh hardcodes DOWNLOAD_DIR=./model_artifacts (relative to its dir),
    # so we symlink that path to /data/minio/model_artifacts on the big EBS volume.
    if [[ "$MINIO_ENABLED" == "true" ]]; then
      ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" 'bash -s' <<'SYMLINKSCRIPT'
mkdir -p /data/minio/model_artifacts
rm -rf ~/artifacts_download_upload_scripts/model_artifacts
ln -sfn /data/minio/model_artifacts ~/artifacts_download_upload_scripts/model_artifacts
SYMLINKSCRIPT
      log "Symlinked artifacts_download_upload_scripts/model_artifacts → /data/minio/model_artifacts"
    fi
  else
    warn "artifacts_download_upload_scripts not found at ${artifacts_dir} — model staging will fail"
  fi
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

# -- Pre-configure containerd ECR auth on all k0s nodes via the installer --
# k0s uses containerd v2 which reads auth from /etc/containerd/certs.d/<reg>/hosts.toml.
# Without this, all pods pull from ECR and get ImagePullBackOff on first boot.
# Called after setup_installer (AWS creds already on installer) and after push_k0s_config
# (node IPs already written into my-k0s-config.yaml so we can read them back).
# The ECR token is valid 12 hours — long enough for the entire install.
setup_ecr_containerd_auth() {
  local eip="$1"
  [[ -z "${ECR_ACCOUNT}" ]] && { log "No ECR account configured — skipping containerd auth setup"; return 0; }

  log "Pre-configuring containerd ECR auth on all k0s nodes..."
  local ecr_registry="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com"

  # Collect all node IPs from state
  local all_ips=()
  for v in $(compgen -v | grep -E '^(CTRL_IP_|CPU_IP_|GPU_IP_)' | sort); do
    [[ -n "${!v}" ]] && all_ips+=("${!v}")
  done

  if [[ ${#all_ips[@]} -eq 0 ]]; then
    warn "No node IPs in state — skipping containerd auth setup"
    return 0
  fi

  local nodes_str
  nodes_str=$(printf '%s ' "${all_ips[@]}")

  # Run on installer: get ECR token, push hosts.toml to every node
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    "bash -s '${ecr_registry}' '${nodes_str}'" <<'AUTHSCRIPT'
set -e
ECR_REGISTRY="$1"
shift
NODE_IPS=($@)

echo "[ecr-auth] Getting ECR token..."
ECR_TOKEN=$(aws ecr get-login-password --region "${AWS_DEFAULT_REGION:-us-east-2}" 2>/dev/null) || {
  echo "[ecr-auth] WARN: could not get ECR token — containerd auth will not be pre-configured" >&2
  exit 0
}
B64_TOKEN=$(echo -n "AWS:${ECR_TOKEN}" | base64 -w0)

HOSTS_TOML=$(cat <<EOF
server = "https://${ECR_REGISTRY}"

[host."https://${ECR_REGISTRY}"]
  capabilities = ["pull", "resolve"]
  [host."https://${ECR_REGISTRY}".header]
    Authorization = ["Basic ${B64_TOKEN}"]
EOF
)

for NODE_IP in "${NODE_IPS[@]}"; do
  echo "[ecr-auth] Configuring ${NODE_IP}..."
  ssh -o StrictHostKeyChecking=no "ec2-user@${NODE_IP}" \
    "sudo mkdir -p /etc/containerd/certs.d/${ECR_REGISTRY} && \
     echo '${HOSTS_TOML}' | sudo tee /etc/containerd/certs.d/${ECR_REGISTRY}/hosts.toml > /dev/null && \
     echo '[ecr-auth] hosts.toml written on ${NODE_IP}'"
done

echo "[ecr-auth] Containerd ECR auth configured on ${#NODE_IPS[@]} node(s)."
AUTHSCRIPT
  log "ECR containerd auth pre-configured on all nodes"
}

# -- Patch infra fields into my-k0s-config.yaml on the installer --
# Behaviour:
#   1. If ~/cluster_setup/my-k0s-config.yaml exists  → back it up, then patch in-place.
#   2. If it doesn't exist                            → copy k0s-cluster-config.yaml as
#                                                        the base (already in ~/cluster_setup/
#                                                        via setup_installer), then patch.
# Only infrastructure fields are written — everything else in the file is preserved.
push_k0s_config() {
  local eip="$1" installer_priv_ip="$2"
  load_state

  # Build controller and worker IP arrays (newline-separated for yq)
  local ctrl_ips=() worker_ips=()
  for v in $(compgen -v | grep '^CTRL_IP_' | sort); do ctrl_ips+=("${!v}"); done
  for v in $(compgen -v | grep '^CPU_IP_'  | sort); do worker_ips+=("${!v}"); done
  for v in $(compgen -v | grep '^GPU_IP_'  | sort); do worker_ips+=("${!v}"); done

  # Serialize as JSON arrays for safe yq injection
  local ctrl_json worker_json
  ctrl_json=$(printf '%s\n' "${ctrl_ips[@]}" | jq -Rsc 'split("\n") | map(select(length>0))')
  worker_json=$(printf '%s\n' "${worker_ips[@]}" | jq -Rsc 'split("\n") | map(select(length>0))')

  local ts; ts=$(date -Iseconds 2>/dev/null || date)

  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" "bash -s" <<PATCHSCRIPT
set -e
TARGET="\$HOME/cluster_setup/my-k0s-config.yaml"
BASE="\$HOME/cluster_setup/k0s-cluster-config.yaml"

# Step 1 — ensure the file exists (use template as base if not)
if [[ -f "\$TARGET" ]]; then
  BACKUP="\${TARGET%.yaml}.bak-${ts}.yaml"
  cp "\$TARGET" "\$BACKUP"
  echo "[k0s-provision] Backed up existing my-k0s-config.yaml → \$(basename \$BACKUP)"
else
  if [[ ! -f "\$BASE" ]]; then
    echo "[k0s-provision] ERROR: neither my-k0s-config.yaml nor k0s-cluster-config.yaml found in ~/cluster_setup/" >&2
    exit 1
  fi
  cp "\$BASE" "\$TARGET"
  echo "[k0s-provision] Created my-k0s-config.yaml from k0s-cluster-config.yaml template"
fi

# Step 2 — patch infrastructure fields only
# cluster.name is set to STACK_NAME directly (not STACK_NAME-cluster) to keep
# Kubernetes object names within the 63-byte label limit. The AIPlatform CR and
# its child Jobs are named "<cluster.name>-ai-platform[-<suffix>]" — adding
# "-cluster" pushes the longest job name (saia-vector-db-setup-posthook) to 65
# chars. minimumDiskSpace thresholds are set conservatively below real usage on
# g6e.12xlarge (controller ~81 GB, CPU worker ~185 GB on 100/200 GB volumes).
yq eval -i '
  .cluster.name         = "${STACK_NAME}" |
  .cluster.region       = "${REGION}" |
  .cluster.sshKeyPath   = "/home/ec2-user/.ssh/id_rsa" |
  .cluster.sshUser      = "ec2-user" |
  .nodes.existingIPs.controllers = ${ctrl_json} |
  .nodes.existingIPs.workers     = ${worker_json} |
  .storage.modelStaging.enabled  = true |
  .storage.minimumDiskSpace.controller = 75 |
  .storage.minimumDiskSpace.cpuWorker  = 175
' "\$TARGET"

# Step 2b — patch ECR registry + images if ECR account is configured
if [[ -n "${ECR_ACCOUNT}" ]]; then
  ECR_REGISTRY="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com"
  yq eval -i '
    .images.registry                    = "'"${ECR_REGISTRY}"'" |
    .images.operator.image              = "docker.io/splunk/splunk-ai-operator:0.2.0" |
    .images.splunk.image                = "'"${ECR_REGISTRY}"'/splunk/splunk:10-2-ai-custom" |
    .images.ray.headImage               = "'"${ECR_REGISTRY}"'/ml-platform/ray/ray-head:build-953" |
    .images.ray.workerImage             = "'"${ECR_REGISTRY}"'/ml-platform/ray/ray-worker-gpu:build-953" |
    .images.saia.apiImage               = "'"${ECR_REGISTRY}"'/ml-platform/saia/saia-api:build-v2-main-c3b489d" |
    .images.saia.apiV2Image             = "'"${ECR_REGISTRY}"'/ml-platform/saia/saia-api-v2:build-v2-main-c3b489d" |
    .images.saia.dataLoaderImage        = "'"${ECR_REGISTRY}"'/ml-platform/saia/saia-data-loader:build-v2-main-c3b489d" |
    .ecr.account                        = "'"${ECR_ACCOUNT}"'" |
    .ecr.region                         = "'"${ECR_REGION}"'" |
    .imagePullSecrets.autoCreateECR     = true
  ' "\$TARGET"
  echo "[k0s-provision] Patched ECR registry: ${ECR_REGISTRY}"
fi

# Step 3 — patch object store fields
if [[ "${MINIO_ENABLED}" == "true" ]]; then
  yq eval -i '
    .storage.objectStore.type                  = "minio" |
    .storage.objectStore.bucket                = "${MINIO_BUCKET}" |
    .storage.objectStore.endpoint              = "http://${installer_priv_ip}:${MINIO_PORT}" |
    .storage.objectStore.auth.rootUser         = "${MINIO_USER}" |
    .storage.objectStore.auth.rootPassword     = "${MINIO_PASS}"
  ' "\$TARGET"
elif [[ -n "${SEAWEED_ENDPOINT}" ]]; then
  yq eval -i '
    .storage.objectStore.type                  = "seaweedfs" |
    .storage.objectStore.bucket                = "${SEAWEED_BUCKET}" |
    .storage.objectStore.endpoint              = "${SEAWEED_ENDPOINT}" |
    .storage.objectStore.auth.rootUser         = "${SEAWEED_USER}" |
    .storage.objectStore.auth.rootPassword     = "${SEAWEED_PASS}" |
    .storage.modelStaging.enabled              = false
  ' "\$TARGET"
  echo "[k0s-provision] Object store: seaweedfs at ${SEAWEED_ENDPOINT} (modelStaging disabled — models already staged)"
fi

echo "[k0s-provision] Patched infra fields into my-k0s-config.yaml"
echo "[k0s-provision] Run: CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml ~/cluster_setup/k0s_cluster_with_stack.sh install"
PATCHSCRIPT
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
  local _PROVISION_START_TS=${SECONDS}
  local _PROVISION_START_WALL; _PROVISION_START_WALL=$(date '+%Y-%m-%d %H:%M:%S')
  log "=== k0s AWS Provisioner ==="
  log "Stack: ${STACK_NAME}  Region: ${REGION}  AZ: ${AZ}"
  log "Provision started at: ${_PROVISION_START_WALL}"

  AMI_ID=$(get_rhel9_ami)
  ensure_network   # no-op when VPC_ID is already set; creates full stack otherwise
  log "VPC: ${VPC_ID}"
  pick_subnet
  save_state "SUBNET_ID" "${SUBNET_ID}"
  save_state "INSTALLER_SUBNET_ID" "${INSTALLER_SUBNET_ID}"
  # Resolve installer AZ (may differ from $AZ when subnetId and installerSubnetId are in different AZs)
  INSTALLER_AZ=$(aws ec2 describe-subnets --subnet-ids "${INSTALLER_SUBNET_ID}" \
    --region "${REGION}" --query 'Subnets[0].AvailabilityZone' --output text)
  save_state "INSTALLER_AZ" "${INSTALLER_AZ}"
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

  # Build fallback subnet list for GPU workers: configured subnet first, then all other
  # private subnets in the VPC (so we try every AZ before failing on capacity issues).
  local all_private_subnets gpu_fallback_subnets=()
  all_private_subnets=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --region "${REGION}" \
    --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' \
    --output text | tr '\t' ' ')
  gpu_fallback_subnets=("${SUBNET_ID}")
  for s in ${all_private_subnets}; do
    [[ "${s}" != "${SUBNET_ID}" ]] && gpu_fallback_subnets+=("${s}")
  done

  for ((i=0; i<GPU_COUNT; i++)); do
    local id; LAST_LAUNCHED_SUBNET=""
    id=$(launch_instance_az_fallback "gpu-worker-${i}" "${GPU_TYPE}" "${GPU_DISK}" "${ud_gpu}" \
      "${gpu_fallback_subnets[@]}")
    save_state "GPU_INSTANCE_${i}" "${id}"
    save_state "GPU_SUBNET_${i}" "${LAST_LAUNCHED_SUBNET}"
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
    local inst_var="GPU_INSTANCE_${i}" subnet_var="GPU_SUBNET_${i}"
    load_state
    # EBS volume must be in same AZ as the instance — use per-worker subnet to derive AZ
    local gpu_az
    if [[ -n "${!subnet_var:-}" ]]; then
      gpu_az=$(aws ec2 describe-subnets --subnet-ids "${!subnet_var}" \
        --region "${REGION}" --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null || echo "${AZ}")
    else
      gpu_az="${AZ}"
    fi
    local vid; vid=$(attach_data_volume "${!inst_var}" "gpu-worker-${i}" "${GPU_DATA_DISK}" "${gpu_az}")
    save_state "GPU_VOL_${i}" "${vid}"
  done
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    load_state
    local vid; vid=$(attach_data_volume "${INSTALLER_INSTANCE}" "minio" "${MINIO_DATA_DISK}" "${INSTALLER_AZ}")
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

  # ---------- NAT connectivity check (all private nodes need internet for k0s install) ----------
  load_state
  for v in $(compgen -v | grep '^CTRL_IP_\|^CPU_IP_\|^GPU_IP_'); do
    [[ -z "${!v}" ]] && continue
    check_nat_connectivity "${!v}" "${v}" "${EIP}"
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

  # ---------- Pre-configure containerd ECR auth on all nodes ----------
  load_state
  setup_ecr_containerd_auth "${EIP}"

  local _provision_elapsed=$(( SECONDS - _PROVISION_START_TS ))
  local _provision_dur
  if (( _provision_elapsed >= 3600 )); then
    _provision_dur=$(printf '%dh%02dm%02ds' $((_provision_elapsed/3600)) $(((_provision_elapsed%3600)/60)) $((_provision_elapsed%60)))
  else
    _provision_dur=$(printf '%dm%02ds' $((_provision_elapsed/60)) $((_provision_elapsed%60)))
  fi
  log "================================================================"
  log "  PROVISION COMPLETE"
  log "  Started:  ${_PROVISION_START_WALL}"
  log "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
  log "  Elapsed:  ${_provision_dur}"
  log "  Installer EIP: ${EIP}"
  log "  SSH: ssh -i ${KEY_LOCAL} ec2-user@${EIP}"
  log "  Run SILENT_INSTALL on installer to bring up k0s + stack"
  log "================================================================"

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
  # In auto-create mode there is no VPC yet, so skip subnet lookup
  [[ "${AUTO_CREATE_NETWORK}" != "true" ]] && pick_subnet
  local inst_az="${AZ}"
  if [[ "${AUTO_CREATE_NETWORK}" != "true" && -n "${INSTALLER_SUBNET_ID}" ]]; then
    inst_az=$(aws ec2 describe-subnets --subnet-ids "${INSTALLER_SUBNET_ID}" \
      --region "${REGION}" --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null || echo "${AZ}")
  fi
  echo ""
  if [[ "${AUTO_CREATE_NETWORK}" == "true" ]]; then
    echo "=== Dry-run: would create new network stack + instances ==="
    echo "  VPC (new)           : ${VPC_CIDR}"
    echo "  Public subnet (new) : ${PUBLIC_CIDR} (${AZ}) + IGW + NAT GW"
    echo "  Private subnet (new): ${PRIVATE_CIDR} (${AZ})"
  else
    echo "=== Dry-run: would create instances in existing VPC ${VPC_ID} ==="
    echo "  k0s nodes subnet    : ${SUBNET_ID} (${AZ}, private)"
    echo "  Installer subnet    : ${INSTALLER_SUBNET_ID} (${inst_az}, public)"
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
