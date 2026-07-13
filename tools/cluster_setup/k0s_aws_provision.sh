#!/usr/bin/env bash
# =============================================================================
# k0s AWS Provisioner
# Creates EC2 infrastructure (VPC, instances, EBS, MinIO) consumed by
# k0s_cluster_with_stack.sh. See K0S_AWS_PROVISION.md for full docs.
#
# Usage:
#   ./k0s_aws_provision.sh provision [--config FILE]
#   ./k0s_aws_provision.sh output    [--config FILE]
#   ./k0s_aws_provision.sh status    [--config FILE]
#   ./k0s_aws_provision.sh destroy   [--config FILE]
#   ./k0s_aws_provision.sh validate  [--config FILE]   # template only, no deploy
#   ./k0s_aws_provision.sh dry-run   [--config FILE]   # generate + validate, no deploy
# =============================================================================
set -euo pipefail
export AWS_PAGER="" AWS_DEFAULT_OUTPUT=json PAGER=cat LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/k0s-aws-provision-config.yaml"
CONFIG_FILE="${DEFAULT_CONFIG}"
MINIO_INSTALL_SCRIPT="${SCRIPT_DIR}/../artifacts_download_upload_scripts/install_minio_ec2.sh"

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { echo "[k0s-provision] $*" >&2; }
warn() { echo "[k0s-provision] WARN: $*" >&2; }
err()  { echo "[k0s-provision] ERROR: $*" >&2; exit 1; }

# ── Arg parsing ──────────────────────────────────────────────────────────────
COMMAND="${1:-}"
[[ -z "$COMMAND" ]] && { echo "Usage: $0 <provision|output|status|destroy|validate|dry-run> [--config FILE]"; exit 1; }
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) err "Unknown option: $1" ;;
  esac
done
[[ -f "$CONFIG_FILE" ]] || err "Config file not found: $CONFIG_FILE"

# ── yq helper ────────────────────────────────────────────────────────────────
need_yq() { command -v yq &>/dev/null || err "yq is required. Install: brew install yq  OR  wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x /usr/local/bin/yq"; }
cfg() { yq eval "${1}" "${CONFIG_FILE}"; }
cfg_default() { yq eval "${1} // \"${2}\"" "${CONFIG_FILE}"; }

# ── Load config ───────────────────────────────────────────────────────────────
load_config() {
  need_yq
  STACK_NAME="$(cfg '.stackName')"
  REGION="$(cfg '.region')"
  AZ="$(cfg '.availabilityZone')"
  AIRGAP="$(cfg_default '.airgap' 'false')"
  SSH_CIDR="$(cfg_default '.sshAllowedCidr' '0.0.0.0/0')"

  KEY_NAME="$(cfg_default '.keyPair.name' '')"
  KEY_LOCAL="$(cfg_default '.keyPair.localPath' '')"
  [[ "$KEY_NAME"  == "null" ]] && KEY_NAME=""
  [[ "$KEY_LOCAL" == "null" ]] && KEY_LOCAL=""
  [[ -z "$KEY_LOCAL" ]] && KEY_LOCAL="${HOME}/.ssh/${STACK_NAME}.pem"

  # Nodes
  CTRL_COUNT="$(cfg_default '.nodes.controller.count' '1')"
  CTRL_TYPE="$(cfg_default '.nodes.controller.instanceType' 'm6i.2xlarge')"
  CTRL_DISK="$(cfg_default '.nodes.controller.diskGb' '100')"

  CPU_COUNT="$(cfg_default '.nodes.cpuWorker.count' '1')"
  CPU_TYPE="$(cfg_default '.nodes.cpuWorker.instanceType' 'm6i.4xlarge')"
  CPU_DISK="$(cfg_default '.nodes.cpuWorker.diskGb' '200')"

  GPU_COUNT="$(cfg_default '.nodes.gpuWorker.count' '2')"
  GPU_TYPE="$(cfg_default '.nodes.gpuWorker.instanceType' 'g6e.12xlarge')"
  GPU_DISK="$(cfg_default '.nodes.gpuWorker.diskGb' '100')"
  GPU_DATA_DISK="$(cfg_default '.nodes.gpuWorker.dataDiskGb' '500')"
  GPU_CAP_RES="$(cfg_default '.nodes.gpuWorker.capacityReservationId' '')"
  [[ "$GPU_CAP_RES" == "null" ]] && GPU_CAP_RES=""

  INST_TYPE="$(cfg_default '.installer.instanceType' 't3.large')"
  INST_DISK="$(cfg_default '.installer.diskGb' '50')"

  MINIO_ENABLED="$(cfg_default '.minio.enabled' 'false')"
  MINIO_DATA_DISK="$(cfg_default '.minio.dataDiskGb' '500')"
  MINIO_BUCKET="$(cfg_default '.minio.bucket' 'ai-platform')"
  MINIO_USER="$(cfg_default '.minio.rootUser' 'minioadmin')"
  MINIO_PASS="$(cfg_default '.minio.rootPassword' '')"
  MINIO_PORT="$(cfg_default '.minio.port' '9000')"
  [[ "$MINIO_PASS" == "null" || -z "$MINIO_PASS" ]] && MINIO_PASS=""

  # Derived
  CFN_TEMPLATE="/tmp/${STACK_NAME}-cfn.yaml"
  TAG_KEY="k0s-provision-stack"
}

# ── AWS auth check ────────────────────────────────────────────────────────────
check_aws_auth() {
  if ! aws sts get-caller-identity --region "${REGION}" &>/dev/null; then
    err "AWS credentials not configured or expired.
Run: eval \"\$(okta-aws-login -a splunkcloud-ai-dev --role-arn arn:aws:iam::658391232643:role/splunkcloud_account_admin)\""
  fi
  local identity
  identity=$(aws sts get-caller-identity --region "${REGION}" --output json)
  log "AWS identity: $(echo "$identity" | jq -r '.Arn')"
}

# ── AMI lookup: RHEL 9 ────────────────────────────────────────────────────────
get_rhel9_ami() {
  local ami
  # Red Hat official marketplace AMIs (owner 309956199498), RHEL 9, x86_64, latest
  ami=$(aws ec2 describe-images \
    --owners 309956199498 \
    --filters \
      "Name=name,Values=RHEL-9.*_HVM-*-x86_64-*" \
      "Name=state,Values=available" \
      "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text \
    --region "${REGION}" 2>/dev/null)
  [[ -z "$ami" || "$ami" == "None" ]] && err "Could not find RHEL 9 AMI in region ${REGION}. Check your region or AWS account marketplace access."
  log "RHEL 9 AMI: ${ami}"
  echo "$ami"
}

# ── Key pair management ───────────────────────────────────────────────────────
ensure_key_pair() {
  if [[ -z "$KEY_NAME" ]]; then
    KEY_NAME="${STACK_NAME}-key"
    log "No key pair specified — auto-creating: ${KEY_NAME}"
    if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${REGION}" &>/dev/null; then
      warn "Key pair '${KEY_NAME}' already exists in AWS. If you don't have the .pem, delete it first or set keyPair.name in config."
    else
      aws ec2 create-key-pair \
        --key-name "${KEY_NAME}" \
        --query 'KeyMaterial' \
        --output text \
        --region "${REGION}" > "${KEY_LOCAL}"
      chmod 600 "${KEY_LOCAL}"
      log "Key pair created, saved to: ${KEY_LOCAL}"
      # Tag for cleanup tracking
      local kp_id
      kp_id=$(aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${REGION}" \
        --query 'KeyPairs[0].KeyPairId' --output text)
      aws ec2 create-tags --resources "${kp_id}" \
        --tags "Key=${TAG_KEY},Value=${STACK_NAME}" "Key=auto-created,Value=true" \
        --region "${REGION}" 2>/dev/null || true
    fi
  else
    log "Using existing key pair: ${KEY_NAME}"
    if [[ ! -f "$KEY_LOCAL" ]]; then
      warn "Key file not found at ${KEY_LOCAL}. Set keyPair.localPath in config if it is elsewhere."
    fi
  fi
}

# ── CloudFormation template generation ───────────────────────────────────────
generate_cfn_template() {
  local ami_id="$1"
  log "Generating CloudFormation template: ${CFN_TEMPLATE}"

  # Build GPU capacity reservation snippet
  local cap_res_snippet=""
  if [[ -n "$GPU_CAP_RES" ]]; then
    cap_res_snippet="          CapacityReservationSpecification:
            CapacityReservationTarget:
              CapacityReservationId: ${GPU_CAP_RES}"
  fi

  # Build node public IP setting (no public IP if airgap=true for k0s nodes)
  local k0s_node_public_ip="true"
  [[ "$AIRGAP" == "true" ]] && k0s_node_public_ip="false"

  # UserData: common setup for all RHEL9 nodes
  # - passwordless sudo for ec2-user (required by k0s installer)
  # - disable host key checking for inter-node SSH
  local userdata_common
  userdata_common=$(cat <<'UDEOF'
#!/bin/bash
set -e
# Passwordless sudo for ec2-user (required by k0s_cluster_with_stack.sh)
echo 'ec2-user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ec2-user-nopasswd
chmod 440 /etc/sudoers.d/ec2-user-nopasswd
# Disable strict host key checking for inter-node SSH (k0s installer uses ssh -o StrictHostKeyChecking=no)
mkdir -p /home/ec2-user/.ssh
printf 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' \
  >> /home/ec2-user/.ssh/config
chown -R ec2-user:ec2-user /home/ec2-user/.ssh
chmod 700 /home/ec2-user/.ssh
chmod 600 /home/ec2-user/.ssh/config
UDEOF
)

  # UserData: mount data disk at a given mount point
  # $1 = mount point (e.g. /var/lib/k0s)
  # Device name for second disk on Nitro instances is /dev/nvme1n1
  userdata_mount_disk() {
    local mp="$1"
    cat <<MDEOF

# Mount secondary EBS volume at ${mp}
mount_data_disk() {
  local dev=""
  # On Nitro instances the attached volume appears as nvme1n1
  for candidate in /dev/nvme1n1 /dev/xvdb /dev/sdb; do
    if [ -b "\$candidate" ]; then dev="\$candidate"; break; fi
  done
  if [ -z "\$dev" ]; then
    echo "WARNING: secondary EBS device not found; skipping ${mp} mount" >&2
    return
  fi
  # Format only if no filesystem
  if ! blkid "\$dev" &>/dev/null; then
    mkfs.xfs -f "\$dev"
  fi
  mkdir -p "${mp}"
  grep -q "\$dev" /etc/fstab || echo "\$dev ${mp} xfs defaults,nofail 0 2" >> /etc/fstab
  mountpoint -q "${mp}" || mount "${mp}"
  echo "Mounted \$dev at ${mp}"
}
mount_data_disk
MDEOF
  }

  # Base64-encode a heredoc for CFN UserData
  encode_userdata() {
    printf '%s' "$1" | base64 | tr -d '\n'
  }

  # k0s node UserData (controller + workers)
  local ud_k0s_node
  ud_k0s_node="${userdata_common}"

  # GPU worker UserData (adds /var/lib/k0s mount)
  local ud_gpu_worker
  ud_gpu_worker="${userdata_common}$(userdata_mount_disk '/var/lib/k0s')"

  # Installer UserData (adds /data/minio mount if minio enabled)
  local ud_installer
  ud_installer="${userdata_common}"
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    ud_installer="${userdata_common}$(userdata_mount_disk '/data/minio')"
  fi

  # Generate GPU worker resources
  local gpu_instances="" gpu_data_volumes="" gpu_vol_attachments=""
  local i
  for ((i=0; i<GPU_COUNT; i++)); do
    local dev_idx=$((i + 1))  # /dev/nvme1n1 (second disk)
    gpu_instances+="
  GpuWorker${i}:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: ${GPU_TYPE}
      ImageId: ${ami_id}
      KeyName: ${KEY_NAME}
      SubnetId: !Ref PublicSubnet
      SecurityGroupIds: [!Ref ClusterSG]
      AssociatePublicIpAddress: ${k0s_node_public_ip}
      BlockDeviceMappings:
        - DeviceName: /dev/sda1
          Ebs: { VolumeSize: ${GPU_DISK}, VolumeType: gp3, DeleteOnTermination: true }
      UserData:
        Fn::Base64: |
$(echo "${ud_gpu_worker}" | sed 's/^/          /')
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-gpu-worker-${i}' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }
        - { Key: k0s-role, Value: gpu-worker }
"
    gpu_data_volumes+="
  GpuWorker${i}DataVol:
    Type: AWS::EC2::Volume
    DeletionPolicy: Delete
    Properties:
      AvailabilityZone: ${AZ}
      Size: ${GPU_DATA_DISK}
      VolumeType: gp3
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-gpu-worker-${i}-data' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }
"
    gpu_vol_attachments+="
  GpuWorker${i}DataVolAttach:
    Type: AWS::EC2::VolumeAttachment
    Properties:
      InstanceId: !Ref GpuWorker${i}
      VolumeId: !Ref GpuWorker${i}DataVol
      Device: /dev/sdb
"
  done

  # Generate CPU worker resources
  local cpu_instances=""
  for ((i=0; i<CPU_COUNT; i++)); do
    cpu_instances+="
  CpuWorker${i}:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: ${CPU_TYPE}
      ImageId: ${ami_id}
      KeyName: ${KEY_NAME}
      SubnetId: !Ref PublicSubnet
      SecurityGroupIds: [!Ref ClusterSG]
      AssociatePublicIpAddress: ${k0s_node_public_ip}
      BlockDeviceMappings:
        - DeviceName: /dev/sda1
          Ebs: { VolumeSize: ${CPU_DISK}, VolumeType: gp3, DeleteOnTermination: true }
      UserData:
        Fn::Base64: |
$(echo "${ud_k0s_node}" | sed 's/^/          /')
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-cpu-worker-${i}' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }
        - { Key: k0s-role, Value: cpu-worker }
"
  done

  # Generate controller resources
  local ctrl_instances=""
  for ((i=0; i<CTRL_COUNT; i++)); do
    ctrl_instances+="
  Controller${i}:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: ${CTRL_TYPE}
      ImageId: ${ami_id}
      KeyName: ${KEY_NAME}
      SubnetId: !Ref PublicSubnet
      SecurityGroupIds: [!Ref ClusterSG]
      AssociatePublicIpAddress: ${k0s_node_public_ip}
      BlockDeviceMappings:
        - DeviceName: /dev/sda1
          Ebs: { VolumeSize: ${CTRL_DISK}, VolumeType: gp3, DeleteOnTermination: true }
      UserData:
        Fn::Base64: |
$(echo "${ud_k0s_node}" | sed 's/^/          /')
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-controller-${i}' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }
        - { Key: k0s-role, Value: controller }
"
  done

  # MinIO EBS volume
  local minio_vol_resource=""
  local minio_vol_attach=""
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    minio_vol_resource="
  MinioDataVol:
    Type: AWS::EC2::Volume
    DeletionPolicy: Delete
    Properties:
      AvailabilityZone: ${AZ}
      Size: ${MINIO_DATA_DISK}
      VolumeType: gp3
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-minio-data' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }
"
    minio_vol_attach="
  MinioDataVolAttach:
    Type: AWS::EC2::VolumeAttachment
    Properties:
      InstanceId: !Ref InstallerInstance
      VolumeId: !Ref MinioDataVol
      Device: /dev/sdb
"
  fi

  cat > "${CFN_TEMPLATE}" <<CFEOF
AWSTemplateFormatVersion: '2010-09-09'
Description: 'k0s cluster EC2 infrastructure — stack ${STACK_NAME}'

Resources:
  # ── Network ──────────────────────────────────────────────────────────────────
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.10.0.0/16
      EnableDnsSupport: true
      EnableDnsHostnames: true
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-vpc' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }

  IGW:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-igw' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }

  IGWAttach:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref IGW

  PublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: 10.10.0.0/24
      AvailabilityZone: ${AZ}
      MapPublicIpOnLaunch: false
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-subnet' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }

  RouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-rt' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }

  DefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: IGWAttach
    Properties:
      RouteTableId: !Ref RouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref IGW

  SubnetRouteAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref RouteTable

  # ── Security Group ────────────────────────────────────────────────────────────
  ClusterSG:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: k0s cluster nodes — all private-IP traffic + SSH to installer
      VpcId: !Ref VPC
      # Outbound: unrestricted
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-sg' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }

  # Allow all traffic within the security group (private-IP k0s inter-node comms)
  SGSelfIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref ClusterSG
      IpProtocol: -1
      SourceSecurityGroupId: !Ref ClusterSG
      Description: All intra-cluster traffic on private IPs

  # SSH from allowed CIDR to installer machine
  SGSSHIngress:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref ClusterSG
      IpProtocol: tcp
      FromPort: 22
      ToPort: 22
      CidrIp: ${SSH_CIDR}
      Description: SSH from sshAllowedCidr to installer

  # ── Installer Machine ─────────────────────────────────────────────────────────
  InstallerInstance:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: ${INST_TYPE}
      ImageId: ${ami_id}
      KeyName: ${KEY_NAME}
      SubnetId: !Ref PublicSubnet
      SecurityGroupIds: [!Ref ClusterSG]
      AssociatePublicIpAddress: false
      BlockDeviceMappings:
        - DeviceName: /dev/sda1
          Ebs: { VolumeSize: ${INST_DISK}, VolumeType: gp3, DeleteOnTermination: true }
      UserData:
        Fn::Base64: |
$(echo "${ud_installer}" | sed 's/^/          /')
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-installer' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }
        - { Key: k0s-role, Value: installer }

  InstallerEIP:
    Type: AWS::EC2::EIP
    Properties:
      Domain: vpc
      Tags:
        - { Key: Name, Value: !Sub '\${AWS::StackName}-installer-eip' }
        - { Key: ${TAG_KEY}, Value: !Ref AWS::StackName }

  InstallerEIPAssoc:
    Type: AWS::EC2::EIPAssociation
    Properties:
      InstanceId: !Ref InstallerInstance
      EIP: !Ref InstallerEIP

  # ── k0s Controllers ───────────────────────────────────────────────────────────
${ctrl_instances}
  # ── k0s CPU Workers ───────────────────────────────────────────────────────────
${cpu_instances}
  # ── k0s GPU Workers + Data Volumes ────────────────────────────────────────────
${gpu_instances}
${gpu_data_volumes}
${gpu_vol_attachments}
${minio_vol_resource}
${minio_vol_attach}

Outputs:
  InstallerPublicIP:
    Value: !Ref InstallerEIP
    Description: Elastic IP of the installer machine (SSH from your laptop)
  InstallerPrivateIP:
    Value: !GetAtt InstallerInstance.PrivateIp
    Description: Private IP of the installer machine
  StackName:
    Value: !Ref AWS::StackName
CFEOF
  log "Template written: ${CFN_TEMPLATE}"
}

# ── Deploy stack ──────────────────────────────────────────────────────────────
deploy_stack() {
  log "Deploying CloudFormation stack: ${STACK_NAME} in ${REGION}..."

  # Check for failed/rolled-back stacks and clean up
  local existing_status
  existing_status=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXISTS")

  if [[ "$existing_status" == "CREATE_COMPLETE" || "$existing_status" == "UPDATE_COMPLETE" ]]; then
    log "Stack already exists and is healthy (${existing_status})."
    log "To reprovision, run 'destroy' first."
    return 0
  elif [[ "$existing_status" != "NOT_EXISTS" ]]; then
    log "Existing stack in state ${existing_status} — deleting before retry..."
    aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${REGION}"
    aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${REGION}" \
      || warn "Wait for stack delete timed out; proceeding anyway"
  fi

  aws cloudformation deploy \
    --template-file "${CFN_TEMPLATE}" \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --no-fail-on-empty-changeset \
    --capabilities CAPABILITY_IAM \
    2>&1 | grep -v "^$" | while IFS= read -r line; do log "$line"; done || true

  local final_status
  final_status=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "UNKNOWN")

  if [[ "$final_status" != "CREATE_COMPLETE" && "$final_status" != "UPDATE_COMPLETE" ]]; then
    log "Stack events (last 10):"
    aws cloudformation describe-stack-events \
      --stack-name "${STACK_NAME}" --region "${REGION}" \
      --query 'StackEvents[0:10].[ResourceStatus,ResourceType,ResourceStatusReason]' \
      --output table 2>/dev/null || true
    err "CloudFormation stack failed: ${final_status}"
  fi
  log "Stack deployed successfully (${final_status})"
}

# ── Get instance private IPs by tag ──────────────────────────────────────────
get_private_ips_by_role() {
  local role="$1"
  aws ec2 describe-instances \
    --region "${REGION}" \
    --filters \
      "Name=tag:${TAG_KEY},Values=${STACK_NAME}" \
      "Name=tag:k0s-role,Values=${role}" \
      "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].PrivateIpAddress' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | sort
}

get_installer_eip() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='InstallerPublicIP'].OutputValue" \
    --output text 2>/dev/null || echo ""
}

get_installer_private_ip() {
  aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='InstallerPrivateIP'].OutputValue" \
    --output text 2>/dev/null || echo ""
}

# ── Wait for SSH ──────────────────────────────────────────────────────────────
wait_for_ssh() {
  local host="$1" label="$2" timeout=600 elapsed=0
  log "Waiting for SSH on ${label} (${host})..."
  while ! ssh -i "${KEY_LOCAL}" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=5 \
      -o BatchMode=yes \
      "ec2-user@${host}" 'true' 2>/dev/null; do
    sleep 10; elapsed=$((elapsed+10))
    [[ $elapsed -ge $timeout ]] && err "SSH to ${label} (${host}) timed out after ${timeout}s"
    echo -n "."
  done
  echo ""
  log "SSH ready: ${label} (${host})"
}

# ── Wait for all nodes ────────────────────────────────────────────────────────
wait_all_nodes_ssh() {
  local eip; eip=$(get_installer_eip)
  [[ -z "$eip" || "$eip" == "None" ]] && err "Could not get installer EIP from stack outputs"
  wait_for_ssh "${eip}" "installer"

  local ctrl_ips; readarray -t ctrl_ips < <(get_private_ips_by_role controller)
  local cpu_ips;  readarray -t cpu_ips  < <(get_private_ips_by_role cpu-worker)
  local gpu_ips;  readarray -t gpu_ips  < <(get_private_ips_by_role gpu-worker)

  # SSH to k0s nodes via installer (jump host)
  local all_ips=("${ctrl_ips[@]:-}" "${cpu_ips[@]:-}" "${gpu_ips[@]:-}")
  for ip in "${all_ips[@]:-}"; do
    [[ -z "$ip" ]] && continue
    log "Waiting for SSH on k0s node ${ip} (via installer jump host)..."
    local elapsed=0
    while ! ssh -i "${KEY_LOCAL}" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -J "ec2-user@${eip}" \
        "ec2-user@${ip}" 'true' 2>/dev/null; do
      sleep 10; elapsed=$((elapsed+10))
      [[ $elapsed -ge 600 ]] && err "SSH to ${ip} timed out"
      echo -n "."
    done
    echo ""
    log "SSH ready: ${ip}"
  done
}

# ── Setup installer machine ───────────────────────────────────────────────────
setup_installer() {
  local eip; eip=$(get_installer_eip)

  log "Copying SSH key to installer machine..."
  scp -i "${KEY_LOCAL}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    "${KEY_LOCAL}" "ec2-user@${eip}:~/.ssh/id_rsa"
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    'chmod 600 ~/.ssh/id_rsa'

  log "Copying k0s cluster scripts to installer..."
  scp -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no -r \
    "${SCRIPT_DIR}/"* "ec2-user@${eip}:~/cluster_setup/"

  # Install prerequisites on installer (yq, kubectl, helm, jq)
  log "Installing prerequisites on installer machine..."
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" 'bash -s' <<'PREREQ'
set -e
export PATH="$PATH:/usr/local/bin"
sudo dnf install -y git jq curl unzip 2>/dev/null || sudo yum install -y git jq curl unzip

# yq
if ! command -v yq &>/dev/null; then
  sudo curl -sSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
  sudo chmod +x /usr/local/bin/yq
fi

# kubectl
if ! command -v kubectl &>/dev/null; then
  K8S_VER=$(curl -sSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo v1.32.0)
  sudo curl -sSL -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${K8S_VER}/bin/linux/amd64/kubectl"
  sudo chmod +x /usr/local/bin/kubectl
fi

# helm
if ! command -v helm &>/dev/null; then
  curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "Prerequisites ready: yq=$(yq --version 2>/dev/null) kubectl=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || echo unknown)"
PREREQ
}

# ── MinIO install ─────────────────────────────────────────────────────────────
install_minio() {
  local eip; eip=$(get_installer_eip)
  local installer_priv_ip; installer_priv_ip=$(get_installer_private_ip)

  [[ ! -f "$MINIO_INSTALL_SCRIPT" ]] && err "MinIO install script not found: ${MINIO_INSTALL_SCRIPT}"

  # Generate password if not set
  if [[ -z "$MINIO_PASS" ]]; then
    MINIO_PASS=$(openssl rand -base64 18 2>/dev/null | tr -d '=+/' | head -c 24)
    log "Auto-generated MinIO password (save it): ${MINIO_PASS}"
  fi

  log "Copying MinIO install script to installer..."
  scp -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no \
    "${MINIO_INSTALL_SCRIPT}" "ec2-user@${eip}:~/install_minio_ec2.sh"

  log "Running MinIO install on installer machine..."
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    "sudo bash ~/install_minio_ec2.sh \
      --bucket '${MINIO_BUCKET}' \
      --user '${MINIO_USER}' \
      --password '${MINIO_PASS}' \
      --data-dir /data/minio \
      --port ${MINIO_PORT}"

  log "MinIO install complete at http://${installer_priv_ip}:${MINIO_PORT}"
}

# ── Generate my-k0s-config.yaml on installer ─────────────────────────────────
push_k0s_config() {
  local eip; eip=$(get_installer_eip)
  local installer_priv_ip; installer_priv_ip=$(get_installer_private_ip)

  readarray -t ctrl_ips  < <(get_private_ips_by_role controller)
  readarray -t cpu_ips   < <(get_private_ips_by_role cpu-worker)
  readarray -t gpu_ips   < <(get_private_ips_by_role gpu-worker)

  # Build existingIPs YAML
  local ctrl_yaml=""; for ip in "${ctrl_ips[@]:-}"; do [[ -n "$ip" ]] && ctrl_yaml+="      - ${ip}"$'\n'; done
  local worker_yaml=""
  for ip in "${cpu_ips[@]:-}"; do  [[ -n "$ip" ]] && worker_yaml+="      - ${ip}  # cpu-worker"$'\n'; done
  for ip in "${gpu_ips[@]:-}"; do  [[ -n "$ip" ]] && worker_yaml+="      - ${ip}  # gpu-worker"$'\n'; done

  local minio_endpoint=""; local minio_block=""
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    minio_endpoint="http://${installer_priv_ip}:${MINIO_PORT}"
    minio_block="    endpoint: \"${minio_endpoint}\"
    auth:
      rootUser: \"${MINIO_USER}\"
      rootPassword: \"${MINIO_PASS}\""
  fi

  # Write config to installer
  ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
    "cat > ~/cluster_setup/my-k0s-config.yaml" <<KCEOF
# Auto-generated by k0s_aws_provision.sh — $(date -Iseconds 2>/dev/null || date)
# Stack: ${STACK_NAME} / Region: ${REGION}
# Run on installer: CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml ~/cluster_setup/k0s_cluster_with_stack.sh install

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
      - "10.10.0.200-10.10.0.210"

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

# ── Output command ────────────────────────────────────────────────────────────
cmd_output() {
  load_config

  local stack_status
  stack_status=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXISTS")
  [[ "$stack_status" == "NOT_EXISTS" ]] && err "Stack '${STACK_NAME}' not found. Run 'provision' first."

  local eip; eip=$(get_installer_eip)
  local installer_priv_ip; installer_priv_ip=$(get_installer_private_ip)

  readarray -t ctrl_ips  < <(get_private_ips_by_role controller)
  readarray -t cpu_ips   < <(get_private_ips_by_role cpu-worker)
  readarray -t gpu_ips   < <(get_private_ips_by_role gpu-worker)

  echo ""
  echo "================================================================"
  echo "  k0s AWS Provision — Output"
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
  for ip in "${ctrl_ips[@]:-}"; do [[ -n "$ip" ]] && echo "        - ${ip}"; done
  echo "      workers:"
  for ip in "${cpu_ips[@]:-}";  do [[ -n "$ip" ]] && echo "        - ${ip}  # cpu-worker"; done
  for ip in "${gpu_ips[@]:-}";  do [[ -n "$ip" ]] && echo "        - ${ip}  # gpu-worker"; done
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    echo ""
    echo "  storage:"
    echo "    objectStore:"
    echo "      type: minio"
    echo "      bucket: ${MINIO_BUCKET}"
    echo "      endpoint: \"http://${installer_priv_ip}:${MINIO_PORT}\""
    echo "      auth:"
    echo "        rootUser: ${MINIO_USER}"
    echo "        rootPassword: ${MINIO_PASS}"
  fi
  echo ""
  echo "================================================================"
  echo "  SSH to installer (run k0s install from here):"
  echo "    ssh -i ${KEY_LOCAL} ec2-user@${eip}"
  echo ""
  echo "  Auto-generated k0s config on installer:"
  echo "    ~/cluster_setup/my-k0s-config.yaml"
  echo ""
  echo "  Run install:"
  echo "    CONFIG_FILE=~/cluster_setup/my-k0s-config.yaml \\"
  echo "      ~/cluster_setup/k0s_cluster_with_stack.sh install"
  echo "================================================================"
  echo ""
}

# ── Status command ────────────────────────────────────────────────────────────
cmd_status() {
  load_config

  local stack_status
  stack_status=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXISTS")

  echo ""
  echo "Stack: ${STACK_NAME}  Status: ${stack_status}  Region: ${REGION}"
  echo ""

  if [[ "$stack_status" == "NOT_EXISTS" ]]; then
    echo "  (stack not found)"; return
  fi

  echo "Instances:"
  aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=tag:${TAG_KEY},Values=${STACK_NAME}" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0], PrivateIpAddress, PublicIpAddress, State.Name, InstanceType]' \
    --output table 2>/dev/null || true

  if [[ "$MINIO_ENABLED" == "true" ]]; then
    local eip; eip=$(get_installer_eip)
    local installer_priv_ip; installer_priv_ip=$(get_installer_private_ip)
    echo ""
    echo -n "MinIO health (http://${installer_priv_ip}:${MINIO_PORT}): "
    local code
    code=$(ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "ec2-user@${eip}" \
      "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${MINIO_PORT}/minio/health/live" 2>/dev/null || echo "unreachable")
    if [[ "$code" == "200" ]]; then echo "OK"; else echo "FAIL (${code})"; fi
  fi
  echo ""
}

# ── Destroy command ───────────────────────────────────────────────────────────
cmd_destroy() {
  load_config

  local stack_status
  stack_status=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXISTS")

  if [[ "$stack_status" == "NOT_EXISTS" ]]; then
    log "Stack '${STACK_NAME}' does not exist — nothing to destroy."; return 0
  fi

  echo ""
  echo "WARNING: This will permanently destroy all resources in stack '${STACK_NAME}':"
  echo "  Region: ${REGION}"
  echo "  Instances: controllers(${CTRL_COUNT}), cpu-workers(${CPU_COUNT}), gpu-workers(${GPU_COUNT}), installer"
  echo "  Volumes, EIPs, VPC, and all data will be deleted."
  echo ""
  read -r -p "Type the stack name to confirm destruction: " confirm
  [[ "$confirm" != "${STACK_NAME}" ]] && { log "Confirmation mismatch — aborting."; return 1; }

  # EBS volumes tagged with stack name (orphan-safe delete)
  log "Finding and deleting EBS data volumes..."
  local vol_ids
  readarray -t vol_ids < <(aws ec2 describe-volumes \
    --region "${REGION}" \
    --filters "Name=tag:${TAG_KEY},Values=${STACK_NAME}" "Name=status,Values=available,in-use" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$')

  log "Deleting CloudFormation stack: ${STACK_NAME}..."
  aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${REGION}"
  log "Waiting for stack deletion (this can take 5-10 minutes)..."
  aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${REGION}" \
    || warn "Stack delete wait timed out; check AWS console for stragglers"

  # Delete any volumes that survived (e.g. if attach was stuck)
  for vol_id in "${vol_ids[@]:-}"; do
    [[ -z "$vol_id" ]] && continue
    log "Deleting orphan volume: ${vol_id}"
    aws ec2 delete-volume --volume-id "${vol_id}" --region "${REGION}" 2>/dev/null || true
  done

  # Delete auto-created key pair
  if [[ -z "$(cfg_default '.keyPair.name' '')" || "$(cfg_default '.keyPair.name' '')" == "null" ]]; then
    local auto_key="${STACK_NAME}-key"
    local kp_auto_created
    kp_auto_created=$(aws ec2 describe-key-pairs \
      --key-names "${auto_key}" --region "${REGION}" \
      --query 'KeyPairs[0].Tags[?Key==`auto-created`].Value|[0]' \
      --output text 2>/dev/null || echo "")
    if [[ "$kp_auto_created" == "true" ]]; then
      log "Deleting auto-created key pair: ${auto_key}"
      aws ec2 delete-key-pair --key-name "${auto_key}" --region "${REGION}" 2>/dev/null || true
      if [[ -f "${KEY_LOCAL}" ]]; then
        read -r -p "Delete local key file ${KEY_LOCAL}? [y/N]: " del_local
        [[ "${del_local,,}" == "y" ]] && rm -f "${KEY_LOCAL}" && log "Deleted ${KEY_LOCAL}"
      fi
    fi
  fi

  log "Destroy complete."
}

# ── Validate / dry-run ────────────────────────────────────────────────────────
cmd_validate() {
  load_config
  local ami_id; ami_id=$(get_rhel9_ami)
  ensure_key_pair
  generate_cfn_template "${ami_id}"
  log "Validating template with AWS..."
  aws cloudformation validate-template \
    --template-body "file://${CFN_TEMPLATE}" \
    --region "${REGION}" && log "Template is valid."
  if command -v cfn-lint &>/dev/null; then
    log "Running cfn-lint..."
    cfn-lint "${CFN_TEMPLATE}" && log "cfn-lint: no issues."
  else
    warn "cfn-lint not installed (pip install cfn-lint) — skipping deep lint."
  fi
}

cmd_dryrun() {
  cmd_validate
  echo ""
  echo "=== Dry-run complete. Template at: ${CFN_TEMPLATE} ==="
  echo "Would create:"
  echo "  1 VPC, 1 Subnet, 1 IGW, 1 Security Group"
  echo "  1 Installer (${INST_TYPE}, ${INST_DISK}GB) + EIP"
  echo "  ${CTRL_COUNT} Controller(s) (${CTRL_TYPE}, ${CTRL_DISK}GB)"
  echo "  ${CPU_COUNT} CPU Worker(s) (${CPU_TYPE}, ${CPU_DISK}GB)"
  echo "  ${GPU_COUNT} GPU Worker(s) (${GPU_TYPE}, ${GPU_DISK}GB root + ${GPU_DATA_DISK}GB /var/lib/k0s)"
  if [[ "$MINIO_ENABLED" == "true" ]]; then
    echo "  MinIO on installer (${MINIO_DATA_DISK}GB /data/minio)"
  fi
  echo "  Region: ${REGION}  AZ: ${AZ}"
}

# ── Provision command ─────────────────────────────────────────────────────────
cmd_provision() {
  load_config
  check_aws_auth

  log "=== k0s AWS Provisioner ==="
  log "Stack: ${STACK_NAME}  Region: ${REGION}  AZ: ${AZ}"

  local ami_id; ami_id=$(get_rhel9_ami)
  ensure_key_pair
  generate_cfn_template "${ami_id}"

  # Validate before deploying
  log "Validating template..."
  aws cloudformation validate-template \
    --template-body "file://${CFN_TEMPLATE}" \
    --region "${REGION}" &>/dev/null || err "Template validation failed. Run 'validate' for details."

  deploy_stack

  log "Waiting for all nodes to be SSH-reachable..."
  wait_all_nodes_ssh

  setup_installer

  if [[ "$MINIO_ENABLED" == "true" ]]; then
    # Wait for /data/minio mount to complete (UserData runs async on RHEL 9)
    local eip; eip=$(get_installer_eip)
    log "Waiting for /data/minio mount on installer..."
    local elapsed=0
    while ! ssh -i "${KEY_LOCAL}" -o StrictHostKeyChecking=no "ec2-user@${eip}" \
        'mountpoint -q /data/minio' 2>/dev/null; do
      sleep 10; elapsed=$((elapsed+10))
      [[ $elapsed -ge 300 ]] && err "/data/minio not mounted after 5 minutes. Check UserData logs: sudo cat /var/log/cloud-init-output.log"
      echo -n "."
    done; echo ""
    install_minio
  fi

  push_k0s_config
  cmd_output
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$COMMAND" in
  provision) cmd_provision ;;
  output)    load_config; cmd_output ;;
  status)    cmd_status ;;
  destroy)   cmd_destroy ;;
  validate)  cmd_validate ;;
  dry-run)   load_config; cmd_dryrun ;;
  *) err "Unknown command: ${COMMAND}. Valid: provision output status destroy validate dry-run" ;;
esac
