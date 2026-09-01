#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# MinIO on EC2 for Splunk AI tier (EKS)
#
# Mode 1 - Install on this machine (run ON the EC2 instance after SSH, as root):
#   sudo ./install_minio_ec2.sh [--bucket NAME] [--user USER] [--password PASSWORD]
#
# Mode 2 - Launch EC2 in same VPC as EKS, then install MinIO (run from laptop):
#   CONFIG_FILE=./cluster-config.yaml ./install_minio_ec2.sh --launch-ec2
#   Then SSH to the instance and run: ./install_minio_ec2.sh (with same bucket/user/password)
#
# Prerequisites: aws CLI, same VPC as EKS (or provide VPC/subnet). For --launch-ec2: jq, yq (optional).
# -----------------------------------------------------------------------------
set -euo pipefail

MINIO_BUCKET="${MINIO_BUCKET:-ai-platform}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/data/minio}"
MINIO_PORT="${MINIO_PORT:-9000}"

# Launch-EC2 options (when --launch-ec2)
MINIO_EC2_INSTANCE_TYPE="${MINIO_EC2_INSTANCE_TYPE:-t3.xlarge}"
MINIO_EC2_AMI_QUERY="${MINIO_EC2_AMI_QUERY:-Amazon Linux 2023}"
MINIO_EC2_KEY_NAME="${MINIO_EC2_KEY_NAME:-}"
MINIO_EC2_VOLUME_SIZE="${MINIO_EC2_VOLUME_SIZE:-150}"

log() { echo "[minio-ec2] $*"; }
err() { echo "[minio-ec2] ERROR: $*" >&2; }

# ---------- Parse args ----------
LAUNCH_EC2=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch-ec2)   LAUNCH_EC2=true; shift ;;
    --bucket)       MINIO_BUCKET="$2"; shift 2 ;;
    --user)         MINIO_ROOT_USER="$2"; shift 2 ;;
    --password)     MINIO_ROOT_PASSWORD="$2"; shift 2 ;;
    --data-dir)     MINIO_DATA_DIR="$2"; shift 2 ;;
    --port)         MINIO_PORT="$2"; shift 2 ;;
    *)              echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------- Mode 2: Launch EC2 in EKS VPC ----------
launch_ec2_in_eks_vpc() {
  need_file "${CONFIG_FILE:-}"
  local cfg="${CONFIG_FILE}"
  local cluster_name region vpc_id subnet_id sg_id instance_id private_ip

  if command -v yq &>/dev/null; then
    cluster_name="$(yq eval '.cluster.name' "$cfg")"
    region="$(yq eval '.cluster.region' "$cfg")"
  else
    cluster_name="$(grep -A1 'cluster:' "$cfg" | grep 'name:' | head -1 | sed 's/.*name: *"\(.*\)".*/\1/')"
    region="$(grep 'region:' "$cfg" | head -1 | sed 's/.*region: *"\(.*\)".*/\1/')"
  fi
  [[ -z "$cluster_name" || -z "$region" ]] && { err "Could not read cluster.name and cluster.region from $cfg"; exit 1; }

  log "Cluster: $cluster_name, Region: $region"
  if ! aws eks describe-cluster --name "$cluster_name" --region "$region" &>/dev/null; then
    err "EKS cluster '$cluster_name' not found. Create the cluster first or provide VPC/subnet via MINIO_EC2_VPC_ID and MINIO_EC2_SUBNET_ID."
    exit 1
  fi

  vpc_id="$(aws eks describe-cluster --name "$cluster_name" --region "$region" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
  # Prefer private subnet for MinIO
  subnet_id="$(aws eks describe-cluster --name "$cluster_name" --region "$region" --query 'cluster.resourcesVpcConfig.subnetIds[0]' --output text)"
  [[ -z "$vpc_id" || "$vpc_id" == "None" ]] && { err "No VPC from cluster"; exit 1; }
  [[ -z "$subnet_id" || "$subnet_id" == "None" ]] && { err "No subnet from cluster"; exit 1; }

  local vpc_cidr
  vpc_cidr="$(aws ec2 describe-vpcs --vpc-ids "$vpc_id" --region "$region" --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null || echo "10.0.0.0/8")"

  log "VPC: $vpc_id, Subnet: $subnet_id, CIDR: $vpc_cidr"

  # Security group: SSH (22) from anywhere; MinIO (9000) from VPC (reuse if exists)
  local sg_name="minio-ec2-${cluster_name}"
  sg_id="$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$sg_name" "Name=vpc-id,Values=$vpc_id" --region "$region" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id="$(aws ec2 create-security-group --group-name "$sg_name" --description "MinIO EC2 for EKS" --vpc-id "$vpc_id" --region "$region" --query 'GroupId' --output text)"
  fi
  aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$region" 2>/dev/null || true
  aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol tcp --port "$MINIO_PORT" --cidr "$vpc_cidr" --region "$region" 2>/dev/null || true
  log "Security group: $sg_id (22 from 0.0.0.0/0, ${MINIO_PORT} from $vpc_cidr)"

  # Key pair: use existing or create (idempotent: reuse same key name per cluster)
  local key_name="$MINIO_EC2_KEY_NAME"
  local key_file=""
  if [[ -z "$key_name" ]]; then
    key_name="minio-ec2-${cluster_name}"
    key_file="/tmp/minio-ec2-${cluster_name}.pem"
    if aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" &>/dev/null; then
      log "Using existing key pair: $key_name (if you lost the .pem, set MINIO_EC2_KEY_NAME to another key)"
    elif aws ec2 create-key-pair --key-name "$key_name" --query 'KeyMaterial' --output text --region "$region" > "$key_file" 2>/dev/null; then
      chmod 600 "$key_file"
      log "Key pair created: $key_name (saved to $key_file)"
    else
      err "Create key pair failed. Set MINIO_EC2_KEY_NAME to an existing key name in this region."
      exit 1
    fi
  fi

  # AMI: Amazon Linux 2023
  local ami_id
  ami_id="$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-*-x86_64" "Name=state,Values=available" --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text --region "$region")"
  [[ -z "$ami_id" || "$ami_id" == "None" ]] && ami_id="$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" "Name=state,Values=available" --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text --region "$region")"

  instance_id="$(aws ec2 run-instances \
    --image-id "$ami_id" \
    --instance-type "$MINIO_EC2_INSTANCE_TYPE" \
    --subnet-id "$subnet_id" \
    --security-group-ids "$sg_id" \
    --key-name "$key_name" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${MINIO_EC2_VOLUME_SIZE},\"VolumeType\":\"gp3\"}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=minio-ec2-${cluster_name}},{Key=Cluster,Value=${cluster_name}}]" \
    --region "$region" \
    --query 'Instances[0].InstanceId' --output text)"
  log "Launched instance: $instance_id (key: $key_name)"

  log "Waiting for instance to get private IP..."
  aws ec2 wait instance-running --instance-ids "$instance_id" --region "$region"
  private_ip="$(aws ec2 describe-instances --instance-ids "$instance_id" --region "$region" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
  [[ -z "$private_ip" || "$private_ip" == "None" ]] && private_ip="(check console)"

  echo ""
  log "=== MinIO EC2 instance ready ==="
  echo "  Instance ID: $instance_id"
  echo "  Private IP:   $private_ip"
  echo "  Region:       $region"
  echo "  Key name:     $key_name"
  [[ -n "$key_file" && -f "$key_file" ]] && echo "  Key file:     $key_file"
  echo ""
  echo "Next steps:"
  echo "  1. SSH to the instance: ssh -i ${key_file:-/path/to/$key_name.pem} ec2-user@${private_ip}"
  echo "  2. On the instance, copy and run this script (install-only mode, requires sudo):"
  echo "     sudo ./install_minio_ec2.sh --bucket ${MINIO_BUCKET} --user ${MINIO_ROOT_USER} --password '<your-password>'"
  echo "  3. Add to cluster-config.yaml (storage.minio):"
  echo "     enabled: true"
  echo "     external: true"
  echo "     endpoint: \"http://${private_ip}:${MINIO_PORT}\""
  echo "     bucket: \"${MINIO_BUCKET}\""
  echo "     auth: { rootUser: \"${MINIO_ROOT_USER}\", rootPassword: \"<same-as-install>\" }"
  echo ""
}

need_file() { [[ -n "${1:-}" && -f "${1}" ]] || { err "File required: $1"; exit 1; }; }

# ---------- Entry ----------
if [[ "$LAUNCH_EC2" == "true" ]]; then
  launch_ec2_in_eks_vpc
  exit 0
fi

# ---------- Mode 1: Install MinIO on this machine ----------
# Require root (for /usr/local/bin, /etc/default/minio, systemd)
if [[ "$(id -u)" -ne 0 ]]; then
  err "This script must be run as root (or with sudo)."
  err "Run: sudo $0 ${*:-}"
  exit 1
fi

# Generate password if not set
if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
  MINIO_ROOT_PASSWORD="$(openssl rand -base64 24 2>/dev/null || head -c 32 /dev/urandom | base64)"
  log "Generated MINIO_ROOT_PASSWORD (save it for cluster-config.yaml)"
fi

# Install MinIO binary (use stable "latest" URL; archive URLs can 404 and return HTML)
install_minio_binary() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) err "Unsupported arch: $arch"; exit 1 ;;
  esac
  local url="https://dl.min.io/server/minio/release/linux-${arch}/minio"
  local tmp="/tmp/minio.$$"
  log "Downloading MinIO (linux-${arch})..."
  if ! curl -sSL -o "$tmp" "$url"; then
    err "Download failed. Check network or try: curl -sSL -o /tmp/minio '$url'"
    rm -f "$tmp"
    exit 1
  fi
  # Reject HTML/error pages (e.g. 404); binary should not start with < or "Not"
  if head -c 4 "$tmp" | grep -q '^<\|^Not'; then
    err "Download returned HTML/error instead of binary. URL may be wrong or blocked."
    head -1 "$tmp"
    rm -f "$tmp"
    exit 1
  fi
  chmod +x "$tmp"
  mv "$tmp" /usr/local/bin/minio
  # Restore SELinux context — binary moved from /tmp inherits user_tmp_t which systemd cannot exec.
  command -v restorecon &>/dev/null && restorecon /usr/local/bin/minio || true
  /usr/local/bin/minio --version
}

install_mc() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) arch=amd64 ;;
  esac
  local tmp="/tmp/mc.$$"
  log "Downloading MinIO Client (mc)..."
  if ! curl -sSL -o "$tmp" "https://dl.min.io/client/mc/release/linux-${arch}/mc"; then
    err "Download failed for mc."
    rm -f "$tmp"
    exit 1
  fi
  if head -c 4 "$tmp" | grep -q '^<\|^Not'; then
    err "mc download returned HTML/error instead of binary."
    rm -f "$tmp"
    exit 1
  fi
  chmod +x "$tmp"
  mv "$tmp" /usr/local/bin/mc
  command -v restorecon &>/dev/null && restorecon /usr/local/bin/mc || true
  /usr/local/bin/mc --version
}

# Stop MinIO so we can replace the binary without restart loop (e.g. after wrong-arch fix).
systemctl stop minio 2>/dev/null || true
# Always (re)install MinIO binary so we get the correct architecture for this host.
# A wrong-arch binary (e.g. amd64 on arm64 EC2) causes "Exec format error" and crash-loop.
install_minio_binary
export PATH="$PATH:/usr/local/bin"
if ! command -v mc &>/dev/null; then
  install_mc
else
  log "mc already present: $(mc --version 2>/dev/null || true)"
fi

mkdir -p "$MINIO_DATA_DIR"
chmod 755 "$MINIO_DATA_DIR"
ENV_FILE="/etc/default/minio"
cat > "$ENV_FILE" <<ENV
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_VOLUMES=${MINIO_DATA_DIR}
ENV
chmod 600 "$ENV_FILE"
log "Wrote ${ENV_FILE}"

cat > /etc/systemd/system/minio.service <<UNIT
[Unit]
Description=MinIO Object Storage
After=network.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/minio
ExecStart=/usr/local/bin/minio server --address :${MINIO_PORT} \$MINIO_VOLUMES
Restart=always
RestartSec=5
LimitNOFILE=65536
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable minio
systemctl restart minio
log "MinIO service started (port ${MINIO_PORT})"

# Wait for MinIO to listen and respond; fail if not up after 60s
minio_ok=false
for i in {1..30}; do
  if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${MINIO_PORT}/minio/health/live" 2>/dev/null | grep -q 200; then
    minio_ok=true
    break
  fi
  sleep 2
done
if [[ "$minio_ok" != "true" ]]; then
  err "MinIO did not respond on port ${MINIO_PORT} within 60s. Service may be failing or crash-looping."
  echo "" >&2
  systemctl status minio --no-pager 2>&1 || true
  echo "" >&2
  journalctl -u minio -n 30 --no-pager 2>&1 || true
  exit 1
fi
# Verify port is actually listening
if ! ( ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null ) | grep -qE "[.:]${MINIO_PORT}([^0-9]|$)"; then
  err "MinIO health passed but port ${MINIO_PORT} is not listening. Showing service status:"
  systemctl status minio --no-pager 2>&1 || true
  exit 1
fi
sleep 2

export MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@127.0.0.1:${MINIO_PORT}"
mc mb "local/${MINIO_BUCKET}" --ignore-existing 2>/dev/null || true
for prefix in apps artifacts config job_groups model_artifacts tasks; do
  echo -n | mc pipe "local/${MINIO_BUCKET}/${prefix}/.keep" 2>/dev/null || true
done
log "Bucket '${MINIO_BUCKET}' and prefixes apps/, artifacts/, config/, job_groups/, model_artifacts/, tasks/ ready"

if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-port="${MINIO_PORT}/tcp" 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${MINIO_PORT}/tcp" 2>/dev/null || true
  ufw reload 2>/dev/null || true
fi

PRIVATE_IP=""
if command -v hostname &>/dev/null; then
  PRIVATE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[[ -z "$PRIVATE_IP" ]] && PRIVATE_IP="$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo 'MINIO_EC2_PRIVATE_IP')"
ENDPOINT="http://${PRIVATE_IP}:${MINIO_PORT}"

echo ""
log "=== MinIO on EC2 is ready ==="
echo "  Endpoint:  ${ENDPOINT}"
echo "  Bucket:    ${MINIO_BUCKET}"
echo "  Root user: ${MINIO_ROOT_USER}"
echo "  Root pass: ${MINIO_ROOT_PASSWORD}"
echo ""
echo "Add to cluster-config.yaml (storage.minio):"
echo "  minio:"
echo "    enabled: true"
echo "    external: true"
echo "    endpoint: \"${ENDPOINT}\""
echo "    bucket: \"${MINIO_BUCKET}\""
echo "    auth:"
echo "      rootUser: \"${MINIO_ROOT_USER}\""
echo "      rootPassword: \"${MINIO_ROOT_PASSWORD}\""
echo ""
echo "Ensure EC2 security group allows inbound TCP ${MINIO_PORT} from your EKS node security group or VPC CIDR."
echo ""
echo "If MinIO is not reachable, check: systemctl status minio && ss -tlnp | grep ${MINIO_PORT}"
echo ""
