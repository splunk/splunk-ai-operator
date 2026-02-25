#!/bin/bash
set -euo pipefail

# =============================================================================
# k0s Cluster Setup Script for Splunk AI Platform
# =============================================================================
# Mirrors eks_cluster_with_stack.sh functionality but for k0s clusters
# Supports:
#   1. On-prem/baremetal: Use customer-provided IP addresses
#   2. AWS EC2: Automatically create EC2 instances for testing
# =============================================================================

# --- AWS credentials handling ---
# Don't unset AWS credentials - they may be needed for ECR access in on-prem/air-gapped scenarios
# The original unset was to prevent conflicts, but it breaks SSO/assumed-role credentials
# If you need to clear credentials, do it explicitly before running the script
# unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE 2>/dev/null || true

# --- Non-interactive setup ---
export AWS_PAGER=""
export AWS_DEFAULT_OUTPUT=json
export PAGER=cat
export GIT_PAGER=cat
export LESS=FRX
export EDITOR=cat
export KUBE_EDITOR=cat
export LANG=C LC_ALL=C

# ====== CONFIG FILE LOCATION ======
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/k0s-cluster-config.yaml}"

# ====== COLORS & LOGGING ======
log()   { echo -e "\033[1;36m[INFO]\033[0m $*" >&2; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || err "Missing $1 in PATH"; }

# ====== HELM RETRY LOGIC ======
# Retries helm commands with exponential backoff on transient errors
# Usage: helm_retry <max_tries> <helm_command_and_args>
# Example: helm_retry 3 upgrade --install my-release chart/name
helm_retry() {
  local tries="${1}"; shift
  local i=1 backoff=5 out rc
  while (( i <= tries )); do
    set +e
    out=$(helm "$@" 2>&1); rc=$?
    set -e
    if (( rc == 0 )); then printf "%s\n" "$out"; return 0; fi
    # Check for transient errors that should be retried
    if grep -qiE 'timed out|operation timed out|i/o timeout|connection reset|TLS handshake timeout|could not get information about the resource|context deadline exceeded|not ready' <<<"$out"; then
      warn "Helm transient error (attempt $i/$tries). Retrying in ${backoff}s…"
      warn "$out"
      sleep "$backoff"; backoff=$(( backoff*2 )); (( i++ ))
    else
      # Non-transient error, fail immediately
      echo "$out" >&2; return "$rc"
    fi
  done
  err "Helm failed after ${tries} attempts."
}

# ====== WAIT FOR RESOURCE HELPERS ======
# Wait for a specific resource to exist
wait_resource_exists() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-300}"
  log "Waiting for ${kind}/${name} to exist in ${ns} (timeout: ${timeout}s)..."
  kubectl wait --for=condition=Established --timeout="${timeout}s" "crd/${name}" 2>/dev/null || \
  timeout "${timeout}s" bash -c "until kubectl get ${kind} ${name} -n ${ns} >/dev/null 2>&1; do sleep 2; done" || \
  warn "Timeout waiting for ${kind}/${name} in ${ns}"
}

# Wait for a deployment rollout
wait_rollout() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-300}"
  log "Waiting for ${kind}/${name} rollout in ${ns} (timeout: ${timeout}s)..."
  kubectl rollout status "${kind}/${name}" -n "${ns}" --timeout="${timeout}s" || \
  warn "Timeout waiting for ${kind}/${name} rollout in ${ns}"
}

# ====== PREFLIGHT CHECKS ======
PF_FAILS=0; PF_WARN=0
pf_header(){ echo -e "\n\033[1;34m[CHECK]\033[0m $*" >&2; }
pf_ok()   { echo -e "  \033[1;32m✔\033[0m $*" >&2; }
pf_warn() { echo -e "  \033[1;33m!\033[0m $*" >&2; PF_WARN=$((PF_WARN+1)); }
pf_fail() { echo -e "  \033[1;31m✖\033[0m $*" >&2; PF_FAILS=$((PF_FAILS+1)); }
pf_summary(){
  echo -e "\n\033[1;34m[SUMMARY]\033[0m Preflight complete: \033[1;32m${PF_FAILS} error(s)\033[0m, \033[1;33m${PF_WARN} warning(s)\033[0m." >&2
  (( PF_FAILS == 0 )) || err "Preflight failed; please fix the above and rerun."
}

# ====== TEMP FILES ======
TMP_FILES=()
cleanup_tmp() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}" 2>/dev/null || true; }
trap cleanup_tmp EXIT

# ====== LOAD CONFIGURATION ======
load_config() {
  log "Loading configuration from: ${CONFIG_FILE}"
  [[ -f "${CONFIG_FILE}" ]] || err "Config file not found: ${CONFIG_FILE}"

  # Parse YAML configuration
  CLUSTER_NAME=$(yq eval '.cluster.name' "${CONFIG_FILE}" 2>/dev/null || grep '^  name:' "${CONFIG_FILE}" | awk '{print $2}')
  USE_EXISTING=$(yq eval '.cluster.useExisting' "${CONFIG_FILE}" 2>/dev/null || echo "never")
  REGION=$(yq eval '.cluster.region' "${CONFIG_FILE}" 2>/dev/null || grep '^  region:' "${CONFIG_FILE}" | awk '{print $2}')

  # Node IPs (for existing infrastructure)
  EXISTING_CONTROLLER_IPS=$(yq eval '.nodes.existingIPs.controllers[]' "${CONFIG_FILE}" 2>/dev/null | tr '\n' ' ' || echo "")
  EXISTING_WORKER_IPS=$(yq eval '.nodes.existingIPs.workers[]' "${CONFIG_FILE}" 2>/dev/null | tr '\n' ' ' || echo "")
  SSH_USER=$(yq eval '.cluster.sshUser' "${CONFIG_FILE}" 2>/dev/null || echo "ubuntu")
  SSH_KEY_PATH=$(yq eval '.cluster.sshKeyPath' "${CONFIG_FILE}" 2>/dev/null || echo "")

  # EC2 configuration (if creating instances)
  VPC_ID=$(yq eval '.ec2.vpcId' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SUBNET_ID=$(yq eval '.ec2.subnetId' "${CONFIG_FILE}" 2>/dev/null || echo "")
  KEY_NAME=$(yq eval '.ec2.keyName' "${CONFIG_FILE}" 2>/dev/null || echo "")

  CONTROLLER_COUNT=$(yq eval '.nodes.controllers' "${CONFIG_FILE}" 2>/dev/null || echo "1")
  CPU_WORKER_COUNT=$(yq eval '.nodes.cpuWorkers' "${CONFIG_FILE}" 2>/dev/null || echo "2")
  GPU_WORKER_COUNT=$(yq eval '.nodes.gpuWorkers' "${CONFIG_FILE}" 2>/dev/null || echo "1")

  CONTROLLER_INSTANCE_TYPE=$(yq eval '.instanceTypes.controller' "${CONFIG_FILE}" 2>/dev/null || echo "t3.xlarge")
  CPU_WORKER_INSTANCE_TYPE=$(yq eval '.instanceTypes.cpuWorker' "${CONFIG_FILE}" 2>/dev/null || echo "m5.4xlarge")
  GPU_WORKER_INSTANCE_TYPE=$(yq eval '.instanceTypes.gpuWorker' "${CONFIG_FILE}" 2>/dev/null || echo "g5.2xlarge")

  # MinIO configuration (optional S3-compatible object storage)
  MINIO_ENABLED=$(yq eval '.minio.enabled // true' "${CONFIG_FILE}" 2>/dev/null || echo "true")
  MINIO_EXTERNAL=$(yq eval '.minio.external // false' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  MINIO_ENDPOINT=$(yq eval '.minio.endpoint // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  MINIO_NS=$(yq eval '.minio.namespace // "minio-system"' "${CONFIG_FILE}" 2>/dev/null || echo "minio-system")
  MINIO_BUCKET=$(yq eval '.minio.bucket' "${CONFIG_FILE}" 2>/dev/null || echo "ai-platform-data")
  MINIO_REPLICAS=$(yq eval '.minio.replicas // 1' "${CONFIG_FILE}" 2>/dev/null || echo "1")
  MINIO_PVC_SIZE=$(yq eval '.minio.persistence.size // "200Gi"' "${CONFIG_FILE}" 2>/dev/null || echo "200Gi")
  MINIO_PVC_STORAGE_CLASS=$(yq eval '.minio.persistence.storageClass // "local-path"' "${CONFIG_FILE}" 2>/dev/null || echo "local-path")
  MINIO_ROOT_USER=$(yq eval '.minio.accessKey // .minio.auth.rootUser // "minioadmin"' "${CONFIG_FILE}" 2>/dev/null || echo "minioadmin")
  MINIO_ROOT_PASSWORD=$(yq eval '.minio.secretKey // .minio.auth.rootPassword // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")

  # Kubernetes namespace
  AI_NS=$(yq eval '.kubernetes.namespace' "${CONFIG_FILE}" 2>/dev/null || echo "ai-platform")

  # Splunk configuration
  AI_STANDALONE_NAME=$(yq eval '.splunk.standaloneName' "${CONFIG_FILE}" 2>/dev/null || echo "splunk-standalone")

  # AI Platform CR configuration (accelerator type, worker image registry, storage)
  DEFAULT_ACCELERATOR=$(yq eval '.aiPlatform.defaultAcceleratorType // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  WORKER_IMAGE_REGISTRY=$(yq eval '.aiPlatform.workerGroupConfig.imageRegistry // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  VECTORDB_SIZE=$(yq eval '.aiPlatform.storage.vectorDbSize // "50Gi"' "${CONFIG_FILE}" 2>/dev/null || echo "50Gi")
  STORAGE_CLASS=$(yq eval '.aiPlatform.storage.storageClassName // "local-path"' "${CONFIG_FILE}" 2>/dev/null || echo "local-path")

  # NVIDIA device plugin version (matches EKS script: operators.nvidia.devicePluginVersion)
  NVIDIA_VERSION=$(yq eval '.operators.nvidia.devicePluginVersion // "v0.17.3"' "${CONFIG_FILE}" 2>/dev/null || echo "v0.17.3")

  # ECR configuration (for private image repositories)
  ECR_ACCOUNT=$(yq eval '.ecr.account' "${CONFIG_FILE}" 2>/dev/null || echo "")
  ECR_REGION=$(yq eval '.ecr.region' "${CONFIG_FILE}" 2>/dev/null || echo "")

  # Get AWS account if using EC2
  if [[ -z "${EXISTING_CONTROLLER_IPS}" ]]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  fi

  # Auto-detect ECR account from AWS if not specified
  if [[ -z "${ECR_ACCOUNT}" ]] && aws sts get-caller-identity &>/dev/null; then
    ECR_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  fi

  # ImagePullSecrets configuration - read which registries are enabled
  # TODO add the below definitions to the readme file
  IMAGE_PULL_SECRETS_ECR_ENABLED=$(yq eval '.imagePullSecrets.autoCreateECR' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED=$(yq eval '.imagePullSecrets.dockerHub.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_GCR_ENABLED=$(yq eval '.imagePullSecrets.gcr.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_ACR_ENABLED=$(yq eval '.imagePullSecrets.acr.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_CUSTOM_ENABLED=$(yq eval '.imagePullSecrets.custom.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")

  # File paths
  SPLUNK_OPERATOR_FILE=$(yq eval '.files.splunkOperator' "${CONFIG_FILE}" 2>/dev/null || echo "./splunk-operator-cluster.yaml")
  SPLUNK_AI_FILE=$(yq eval '.files.aiPlatform' "${CONFIG_FILE}" 2>/dev/null || echo "./artifacts.yaml")

  log "Configuration loaded: cluster=${CLUSTER_NAME}, namespace=${AI_NS}"
  if [[ "${MINIO_ENABLED}" == "true" ]]; then
    if [[ "${MINIO_EXTERNAL}" == "true" ]]; then
      log "MinIO: external (endpoint=${MINIO_ENDPOINT:-not set}, bucket=${MINIO_BUCKET})"
    else
      log "MinIO: in-cluster (namespace=${MINIO_NS}, bucket=${MINIO_BUCKET})"
    fi
  else
    log "MinIO: disabled (using S3 for object storage)"
  fi
  if [[ -n "${ECR_ACCOUNT}" ]]; then
    log "ECR Account: ${ECR_ACCOUNT}, ECR Region: ${ECR_REGION:-not set}"
  fi

  # Log which image pull secrets are enabled
  local enabled_registries=()
  [[ "${IMAGE_PULL_SECRETS_ECR_ENABLED}" == "true" ]] && enabled_registries+=("ECR")
  [[ "${IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED}" == "true" ]] && enabled_registries+=("DockerHub")
  [[ "${IMAGE_PULL_SECRETS_GCR_ENABLED}" == "true" ]] && enabled_registries+=("GCR")
  [[ "${IMAGE_PULL_SECRETS_ACR_ENABLED}" == "true" ]] && enabled_registries+=("ACR")
  [[ "${IMAGE_PULL_SECRETS_CUSTOM_ENABLED}" == "true" ]] && enabled_registries+=("Custom")

  if [[ ${#enabled_registries[@]} -gt 0 ]]; then
    log "ImagePullSecrets enabled for: ${enabled_registries[*]}"
  fi
}

# ====== PREFLIGHT CHECKS ======
preflight_checks() {
  pf_header "Required tools"
  for tool in ssh kubectl helm git jq; do
    if command -v "$tool" >/dev/null 2>&1; then
      pf_ok "$tool found"
    else
      pf_fail "$tool not found in PATH"
    fi
  done

  # Check for yq
  if command -v yq >/dev/null 2>&1; then
    pf_ok "yq found"
  else
    pf_warn "yq not found - using fallback parsing (install yq for better results)"
  fi

  pf_header "Configuration"
  [[ -n "${CLUSTER_NAME}" ]] && pf_ok "Cluster name: ${CLUSTER_NAME}" || pf_fail "Cluster name not set"
  [[ -f "${SPLUNK_OPERATOR_FILE}" ]] && pf_ok "Splunk operator file: ${SPLUNK_OPERATOR_FILE}" || pf_warn "Splunk operator file not found: ${SPLUNK_OPERATOR_FILE}"
  [[ -f "${SPLUNK_AI_FILE}" ]] && pf_ok "AI platform file: ${SPLUNK_AI_FILE}" || pf_warn "AI platform file not found: ${SPLUNK_AI_FILE}"

  pf_header "Infrastructure mode"
  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    pf_ok "Using existing infrastructure (on-prem/baremetal)"
    pf_ok "Controller IPs: ${EXISTING_CONTROLLER_IPS}"
    pf_ok "Worker IPs: ${EXISTING_WORKER_IPS}"
    [[ -n "${SSH_KEY_PATH}" && -f "${SSH_KEY_PATH}" ]] && pf_ok "SSH key: ${SSH_KEY_PATH}" || pf_fail "SSH key not found: ${SSH_KEY_PATH}"
  else
    pf_ok "Creating EC2 instances"
    if command -v aws >/dev/null 2>&1; then
      pf_ok "AWS CLI found"
      [[ -n "${ACCOUNT_ID}" ]] && pf_ok "AWS Account: ${ACCOUNT_ID}" || pf_fail "Cannot get AWS account ID"
      [[ -n "${VPC_ID}" ]] && pf_ok "VPC ID: ${VPC_ID}" || pf_fail "VPC ID not set"
      [[ -n "${KEY_NAME}" ]] && pf_ok "EC2 Key name: ${KEY_NAME}" || pf_fail "EC2 key name not set"
    else
      pf_fail "AWS CLI not found - required for EC2 instance creation"
    fi
  fi

  pf_summary
}

# ====== SSH HELPER ======
ssh_exec() {
  local host="$1"
  shift
  local cmd="$*"

  if [[ -n "${SSH_KEY_PATH}" ]]; then
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY_PATH}" "${SSH_USER}@${host}" "${cmd}"
  else
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${host}" "${cmd}"
  fi
}

scp_file() {
  local file="$1"
  local host="$2"
  local dest="$3"

  if [[ -n "${SSH_KEY_PATH}" ]]; then
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY_PATH}" "${file}" "${SSH_USER}@${host}:${dest}"
  else
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${file}" "${SSH_USER}@${host}:${dest}"
  fi
}

# ====== EC2 INSTANCE CREATION ======
create_security_group() {
  log "Creating security group for k0s cluster..."

  local sg_name="${CLUSTER_NAME}-k0s-sg"
  local sg_id

  sg_id=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=group-name,Values=${sg_name}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

  if [[ "${sg_id}" != "None" && -n "${sg_id}" ]]; then
    log "Security group already exists: ${sg_id}"
    echo "${sg_id}"
    return 0
  fi

  sg_id=$(aws ec2 create-security-group \
    --region "${REGION}" \
    --group-name "${sg_name}" \
    --description "Security group for ${CLUSTER_NAME} k0s cluster" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' --output text)

  # Tag the security group
  aws ec2 create-tags --region "${REGION}" --resources "${sg_id}" \
    --tags "Key=Cluster,Value=${CLUSTER_NAME}" "Key=ManagedBy,Value=k0s-script" "Key=Name,Value=${sg_name}"

  log "Created security group: ${sg_id}"

  # Add ingress rules (redirect output to avoid pollution)
  log "Configuring security group rules (restricted to your IP)..."

  # Detect current public IP address
  MY_IP="${ALLOWED_CIDR:-}"
  if [[ -z "$MY_IP" ]]; then
    log "Auto-detecting your public IP address..."
    MY_IP=$(curl -s https://checkip.amazonaws.com || curl -s https://ipinfo.io/ip || curl -s https://api.ipify.org)
    if [[ -z "$MY_IP" ]]; then
      warn "Could not auto-detect IP. Set ALLOWED_CIDR environment variable."
      warn "Example: export ALLOWED_CIDR=\"1.2.3.4/32\""
      err "Failed to determine your IP address"
    fi
    # Add /32 for single IP
    MY_IP="${MY_IP}/32"
    log "  Detected IP: ${MY_IP}"
  else
    log "  Using provided CIDR: ${MY_IP}"
  fi

  # === EXTERNAL ACCESS (restricted to your IP) ===
  # API server - allow ONLY from your IP for kubectl access
  aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${sg_id}" \
    --protocol tcp --port 6443 --cidr "${MY_IP}" >/dev/null 2>&1 || true
  log "  ✓ Port 6443 (Kubernetes API): RESTRICTED to ${MY_IP}"

  # SSH - allow ONLY from your IP for management
  aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${sg_id}" \
    --protocol tcp --port 22 --cidr "${MY_IP}" >/dev/null 2>&1 || true
  log "  ✓ Port 22 (SSH): RESTRICTED to ${MY_IP}"

  # NodePort services - allow ONLY from your IP for accessing deployed services
  aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${sg_id}" \
    --protocol tcp --port 30000-32767 --cidr "${MY_IP}" >/dev/null 2>&1 || true
  log "  ✓ Ports 30000-32767 (NodePort): RESTRICTED to ${MY_IP}"

  # Konnectivity agent port - allow ONLY from your IP
  aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${sg_id}" \
    --protocol tcp --port 8132 --cidr "${MY_IP}" >/dev/null 2>&1 || true
  log "  ✓ Port 8132 (Konnectivity): RESTRICTED to ${MY_IP}"

  # === INTERNAL CLUSTER COMMUNICATION (within security group only) ===
  # All internal traffic - etcd (2380), kubelet (10250), CNI, pod networking, etc.
  aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${sg_id}" \
    --protocol -1 --source-group "${sg_id}" >/dev/null 2>&1 || true
  log "  ✓ All ports: INTERNAL ONLY - for cluster communication via private IPs"

  log "Security group rules configured"
  echo "${sg_id}"
}

find_existing_instances() {
  local role="$1"
  aws ec2 describe-instances \
    --region "${REGION}" \
    --filters \
      "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
      "Name=tag:Role,Values=${role}" \
      "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text
}

create_ec2_instances() {
  log "Creating EC2 instances for k0s cluster..."

  # Check for existing instances
  local existing_controllers existing_cpu_workers existing_gpu_workers
  existing_controllers=$(find_existing_instances "controller")
  existing_cpu_workers=$(find_existing_instances "cpu-worker")
  existing_gpu_workers=$(find_existing_instances "gpu-worker")

  local existing_controller_count=$(echo "${existing_controllers}" | wc -w)
  local existing_cpu_worker_count=$(echo "${existing_cpu_workers}" | wc -w)
  local existing_gpu_worker_count=$(echo "${existing_gpu_workers}" | wc -w)

  log "Found existing instances: ${existing_controller_count} controllers, ${existing_cpu_worker_count} CPU workers, ${existing_gpu_worker_count} GPU workers"

  local sg_id
  sg_id=$(create_security_group)

  # Get subnet if not provided
  if [[ -z "${SUBNET_ID}" ]]; then
    SUBNET_ID=$(aws ec2 describe-subnets \
      --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" \
      --query 'Subnets[0].SubnetId' --output text)
  fi

  [[ -n "${SUBNET_ID}" && "${SUBNET_ID}" != "None" ]] || err "No subnets found in VPC ${VPC_ID}"

  # Get latest Ubuntu 22.04 AMI
  local ami_id
  ami_id=$(aws ec2 describe-images \
    --region "${REGION}" \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

  log "Using AMI: ${ami_id}"

  # User data for k0s installation - write to temp file
  local user_data_file="/tmp/k0s-userdata-$$.sh"
  cat > "${user_data_file}" <<'EOF'
#!/bin/bash
set -ex
apt-get update
apt-get install -y curl wget jq
curl -sSLf https://get.k0s.sh | sh
EOF
  TMP_FILES+=("${user_data_file}")

  # Create instances (arrays already declared globally at top of script)
  CONTROLLER_IPS=()
  CONTROLLER_PRIVATE_IPS=()
  CONTROLLER_PUBLIC_IPS=()
  WORKER_IPS=()
  WORKER_PRIVATE_IPS=()
  ALL_INSTANCE_IDS=()

  # Add existing instances to tracking arrays
  if [[ -n "${existing_controllers}" ]]; then
    for id in ${existing_controllers}; do
      ALL_INSTANCE_IDS+=("${id}")
    done
  fi
  if [[ -n "${existing_cpu_workers}" ]]; then
    for id in ${existing_cpu_workers}; do
      ALL_INSTANCE_IDS+=("${id}")
    done
  fi
  if [[ -n "${existing_gpu_workers}" ]]; then
    for id in ${existing_gpu_workers}; do
      ALL_INSTANCE_IDS+=("${id}")
    done
  fi

  # Controllers - only create if needed
  local controllers_to_create=$((CONTROLLER_COUNT - existing_controller_count))
  if [[ ${controllers_to_create} -gt 0 ]]; then
    log "Creating ${controllers_to_create} additional controller(s)..."
    for ((i=existing_controller_count; i<CONTROLLER_COUNT; i++)); do
      local instance_id
      instance_id=$(aws ec2 run-instances \
        --region "${REGION}" \
        --image-id "${ami_id}" \
        --instance-type "${CONTROLLER_INSTANCE_TYPE}" \
        --key-name "${KEY_NAME}" \
        --security-group-ids "${sg_id}" \
        --subnet-id "${SUBNET_ID}" \
        --associate-public-ip-address \
        --user-data "file://${user_data_file}" \
        --tag-specifications \
          "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-controller-${i}},{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=controller},{Key=ManagedBy,Value=k0s-script}]" \
          "ResourceType=volume,Tags=[{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=controller},{Key=ManagedBy,Value=k0s-script}]" \
          "ResourceType=network-interface,Tags=[{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=controller},{Key=ManagedBy,Value=k0s-script}]" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
        --query 'Instances[0].InstanceId' \
        --output text)

      ALL_INSTANCE_IDS+=("${instance_id}")
      log "Created controller: ${instance_id}"
    done
  else
    log "All ${CONTROLLER_COUNT} controller(s) already exist, skipping creation"
  fi

  # CPU Workers - only create if needed
  local cpu_workers_to_create=$((CPU_WORKER_COUNT - existing_cpu_worker_count))
  if [[ ${cpu_workers_to_create} -gt 0 ]]; then
    log "Creating ${cpu_workers_to_create} additional CPU worker(s)..."
    for ((i=existing_cpu_worker_count; i<CPU_WORKER_COUNT; i++)); do
      local instance_id
      instance_id=$(aws ec2 run-instances \
        --region "${REGION}" \
        --image-id "${ami_id}" \
        --instance-type "${CPU_WORKER_INSTANCE_TYPE}" \
        --key-name "${KEY_NAME}" \
        --security-group-ids "${sg_id}" \
        --subnet-id "${SUBNET_ID}" \
        --associate-public-ip-address \
        --user-data "file://${user_data_file}" \
        --tag-specifications \
          "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-cpu-worker-${i}},{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=cpu-worker},{Key=ManagedBy,Value=k0s-script}]" \
          "ResourceType=volume,Tags=[{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=cpu-worker},{Key=ManagedBy,Value=k0s-script}]" \
          "ResourceType=network-interface,Tags=[{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=cpu-worker},{Key=ManagedBy,Value=k0s-script}]" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":200,"VolumeType":"gp3"}}]' \
        --query 'Instances[0].InstanceId' \
        --output text)

      ALL_INSTANCE_IDS+=("${instance_id}")
      log "Created CPU worker: ${instance_id}"
    done
  else
    log "All ${CPU_WORKER_COUNT} CPU worker(s) already exist, skipping creation"
  fi

  # GPU Workers - only create if needed
  if [[ ${GPU_WORKER_COUNT} -gt 0 ]]; then
    local gpu_workers_to_create=$((GPU_WORKER_COUNT - existing_gpu_worker_count))
    if [[ ${gpu_workers_to_create} -gt 0 ]]; then
      log "Creating ${gpu_workers_to_create} additional GPU worker(s)..."
      for ((i=existing_gpu_worker_count; i<GPU_WORKER_COUNT; i++)); do
        local instance_id
        instance_id=$(aws ec2 run-instances \
          --region "${REGION}" \
          --image-id "${ami_id}" \
          --instance-type "${GPU_WORKER_INSTANCE_TYPE}" \
          --key-name "${KEY_NAME}" \
          --security-group-ids "${sg_id}" \
          --subnet-id "${SUBNET_ID}" \
          --associate-public-ip-address \
          --user-data "file://${user_data_file}" \
          --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=${CLUSTER_NAME}-gpu-worker-${i}},{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=gpu-worker},{Key=ManagedBy,Value=k0s-script}]" \
            "ResourceType=volume,Tags=[{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=gpu-worker},{Key=ManagedBy,Value=k0s-script}]" \
            "ResourceType=network-interface,Tags=[{Key=Cluster,Value=${CLUSTER_NAME}},{Key=Role,Value=gpu-worker},{Key=ManagedBy,Value=k0s-script}]" \
          --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":300,"VolumeType":"gp3"}}]' \
          --query 'Instances[0].InstanceId' \
          --output text)

        ALL_INSTANCE_IDS+=("${instance_id}")
        log "Created GPU worker: ${instance_id}"
      done
    else
      log "All ${GPU_WORKER_COUNT} GPU worker(s) already exist, skipping creation"
    fi
  fi

  log "Waiting for instances to be running..."
  aws ec2 wait instance-running --region "${REGION}" --instance-ids "${ALL_INSTANCE_IDS[@]}"

  log "Waiting for instance status checks (this may take 3-5 minutes)..."
  aws ec2 wait instance-status-ok --region "${REGION}" --instance-ids "${ALL_INSTANCE_IDS[@]}" || true

  log "Waiting additional time for SSH to be fully ready..."
  sleep 60

  # Get IPs - collect BOTH public and private IPs
  # Use public IPs for SSH from local machine, private IPs for k0s internal communication
  for id in "${ALL_INSTANCE_IDS[@]}"; do
    local role
    role=$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${id}" \
      --query 'Reservations[0].Instances[0].Tags[?Key==`Role`].Value' --output text)

    # Get public IP for SSH access from local machine
    local public_ip
    public_ip=$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${id}" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

    # Get private IP for k0s internal communication
    local private_ip
    private_ip=$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${id}" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

    # Use public IP for SSH, but store private IP for k0s config
    if [[ "${role}" == "controller" ]]; then
      CONTROLLER_IPS+=("${public_ip}")  # For SSH from local machine
      CONTROLLER_PRIVATE_IPS+=("${private_ip}")  # For k0s internal communication
      CONTROLLER_PUBLIC_IPS+=("${public_ip}")  # For kubectl access and certificates
      log "Controller - Public IP: ${public_ip}, Private IP: ${private_ip}"
    else
      WORKER_IPS+=("${public_ip}")  # For SSH from local machine
      WORKER_PRIVATE_IPS+=("${private_ip}")  # For k0s internal communication
      log "Worker - Public IP: ${public_ip}, Private IP: ${private_ip} (${role})"
    fi
  done

  # Set SSH key path from EC2 key
  SSH_KEY_PATH="${HOME}/.ssh/${KEY_NAME}.pem"
}

# ====== PREPARE NODES (RHEL/Fedora compatibility + k0s binary) ======
prepare_nodes_for_k0s() {
  local node_ips=("$@")
  log "Preparing ${#node_ips[@]} node(s) for k0s (OS compatibility + binary)..."
  for node_ip in "${node_ips[@]}"; do
    log "  Preparing node ${node_ip}..."
    ssh_exec "${node_ip}" "
      # Disable firewalld if active (blocks k0s ports: 6443, 10250, 8472, etc.)
      if systemctl is-active firewalld >/dev/null 2>&1; then
        echo 'Disabling firewalld...'
        sudo systemctl stop firewalld
        sudo systemctl disable firewalld
      fi

      # Ensure iptables is available (RHEL 10+ ships only nftables)
      if ! command -v iptables >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1 && dnf list available iptables-nft 2>/dev/null | grep -q iptables-nft; then
          echo 'Installing iptables-nft...'
          sudo dnf install -y iptables-nft >/dev/null 2>&1
        fi
      fi

      # Ensure python3 + PyYAML are available (used for k0s config generation)
      if ! python3 -c 'import yaml' 2>/dev/null; then
        if command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y python3-pyyaml 2>/dev/null || sudo pip3 install pyyaml 2>/dev/null || true
        elif command -v apt-get >/dev/null 2>&1; then
          sudo apt-get install -y python3-yaml 2>/dev/null || true
        fi
      fi

      # Install k0s binary if not present
      if ! command -v k0s >/dev/null 2>&1; then
        echo 'Installing k0s binary...'
        curl -sSLf https://get.k0s.sh | sudo sh
      fi

      # Ensure k0s is in sudo secure_path
      if [ -f /usr/local/bin/k0s ] && [ ! -f /usr/bin/k0s ]; then
        sudo ln -sf /usr/local/bin/k0s /usr/bin/k0s
      fi
    " || warn "  Preparation had issues on ${node_ip}"
  done
}

# ====== MOUNT NVMe INSTANCE STORE FOR EPHEMERAL STORAGE ======
# GPU instance types (g5, g6, p4, p5) typically come with large NVMe instance
# store drives but tiny 10 GB EBS root volumes. Kubernetes counts ephemeral
# storage from the filesystem backing /var/lib/k0s/kubelet, so we mount an
# unused NVMe drive there to prevent "Insufficient ephemeral-storage" errors.
mount_nvme_instance_store() {
  if [[ ${GPU_WORKER_COUNT} -eq 0 ]]; then
    return 0
  fi

  # Ensure WORKER_IPS is populated
  if [[ -z "${WORKER_IPS+x}" || ${#WORKER_IPS[@]} -eq 0 ]]; then
    if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
      IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
    else
      return 0
    fi
  fi

  local gpu_ips=()
  local idx=0
  for ip in "${WORKER_IPS[@]}"; do
    if [[ ${idx} -ge ${CPU_WORKER_COUNT} ]]; then
      gpu_ips+=("${ip}")
    fi
    idx=$((idx + 1))
  done

  if [[ ${#gpu_ips[@]} -eq 0 ]]; then
    return 0
  fi

  log "Checking NVMe instance store volumes on GPU workers..."

  for gpu_ip in "${gpu_ips[@]}"; do
    ssh_exec "${gpu_ip}" "
      # Skip if /var/lib/k0s is already on a large filesystem (>50 GB)
      k0s_avail_gb=\$(df --output=avail /var/lib/k0s 2>/dev/null | tail -1 | awk '{print int(\$1/1048576)}')
      if [ \"\${k0s_avail_gb:-0}\" -ge 50 ]; then
        echo 'NVMe mount: /var/lib/k0s already has >=50 GB, skipping'
        exit 0
      fi

      # Find the first NVMe device that is NOT the root disk and has no partitions
      ROOT_DEV=\$(lsblk -no PKNAME \$(findmnt -n -o SOURCE /) 2>/dev/null | head -1)
      NVME_DEV=''
      for dev in /dev/nvme*n1; do
        [ -b \"\$dev\" ] || continue
        dev_name=\$(basename \"\$dev\")
        # Skip the root device
        [ \"\$dev_name\" = \"\$ROOT_DEV\" ] && continue
        # Skip devices that already have partitions (they are in use)
        if lsblk -n \"\$dev\" 2>/dev/null | grep -q part; then continue; fi
        # Skip devices already mounted
        if mount | grep -q \"\$dev\"; then continue; fi
        NVME_DEV=\"\$dev\"
        break
      done

      if [ -z \"\$NVME_DEV\" ]; then
        echo 'NVMe mount: no unused NVMe instance store found, skipping'
        exit 0
      fi

      echo \"NVMe mount: formatting \$NVME_DEV and mounting to /var/lib/k0s\"

      # Format
      sudo mkfs.xfs -f \"\$NVME_DEV\" >/dev/null 2>&1

      # If k0s is running, stop it and preserve existing data
      if systemctl is-active k0sworker >/dev/null 2>&1; then
        sudo systemctl stop k0sworker 2>/dev/null || true
        sleep 3
        sudo pkill -9 k0s 2>/dev/null || true
        sudo pkill -9 containerd 2>/dev/null || true
        sudo pkill -9 containerd-shim 2>/dev/null || true
        sleep 2
      fi

      # Lazy unmount anything stuck under /var/lib/k0s
      for mp in \$(mount | grep '/var/lib/k0s' | awk '{print \$3}' | sort -r); do
        sudo umount -l \"\$mp\" 2>/dev/null || true
      done

      # Copy existing data if present
      if [ -d /var/lib/k0s ] && [ \"\$(ls -A /var/lib/k0s 2>/dev/null)\" ]; then
        sudo mkdir -p /mnt/nvme-staging
        sudo mount \"\$NVME_DEV\" /mnt/nvme-staging
        sudo cp -a /var/lib/k0s/. /mnt/nvme-staging/ 2>/dev/null || true
        sudo umount /mnt/nvme-staging
        sudo rmdir /mnt/nvme-staging
      fi

      # Mount
      sudo rm -rf /var/lib/k0s 2>/dev/null || true
      sudo mkdir -p /var/lib/k0s
      sudo mount \"\$NVME_DEV\" /var/lib/k0s

      # Persist in fstab
      NVME_UUID=\$(sudo blkid -s UUID -o value \"\$NVME_DEV\")
      if ! grep -q \"\$NVME_UUID\" /etc/fstab 2>/dev/null; then
        echo \"UUID=\$NVME_UUID /var/lib/k0s xfs defaults,nofail 0 2\" | sudo tee -a /etc/fstab >/dev/null
      fi

      # Restart k0s if it was running
      if systemctl is-enabled k0sworker >/dev/null 2>&1; then
        sudo systemctl start k0sworker 2>/dev/null || true
      fi

      echo \"NVMe mount: done — \$(df -h \$NVME_DEV | tail -1 | awk '{print \$2}') available on /var/lib/k0s\"
    " 2>/dev/null || warn "  NVMe mount on ${gpu_ip} had issues — may need manual setup"
  done
}

# ====== K0S CLUSTER INSTALLATION ======
install_k0s_cluster() {
  log "Installing k0s cluster..."

  # Parse existing IPs if provided
  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
    IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
    log "Using existing infrastructure - IPs from config"
  fi

  local controller_ip="${CONTROLLER_IPS[0]}"

  log "Primary controller IP: ${controller_ip}"

  # Prepare all nodes (firewalld, iptables, python3)
  local all_ips=("${CONTROLLER_IPS[@]}")
  if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
    all_ips+=("${WORKER_IPS[@]}")
  fi
  prepare_nodes_for_k0s "${all_ips[@]}"

  # Generate k0s config
  log "Generating k0s configuration..."
  ssh_exec "${controller_ip}" "k0s config create > /tmp/k0s.yaml"

  # Configure k0s API with the controller IP for SANs and externalAddress
  log "Configuring k0s with controller IP ${controller_ip}..."
  ssh_exec "${controller_ip}" "cat > /tmp/k0s-config-update.py <<'PYSCRIPT'
import yaml

# Read the k0s config
with open('/tmp/k0s.yaml', 'r') as f:
    config = yaml.safe_load(f)

# Add the controller IP to SANs (for kubectl access and cluster communication)
if 'spec' not in config:
    config['spec'] = {}
if 'api' not in config['spec']:
    config['spec']['api'] = {}
if 'sans' not in config['spec']['api']:
    config['spec']['api']['sans'] = []

config['spec']['api']['sans'].append('${controller_ip}')

# Use the same IP for externalAddress so konnectivity-agents can connect
config['spec']['api']['externalAddress'] = '${controller_ip}'

# Set Calico as network provider
if 'network' not in config['spec']:
    config['spec']['network'] = {}
config['spec']['network']['provider'] = 'calico'
if 'calico' not in config['spec']['network']:
    config['spec']['network']['calico'] = {}
config['spec']['network']['calico']['mode'] = 'vxlan'

# Set kine for storage
if 'storage' not in config['spec']:
    config['spec']['storage'] = {}
config['spec']['storage']['type'] = 'kine'

# Write back
with open('/tmp/k0s.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
PYSCRIPT"

  ssh_exec "${controller_ip}" "python3 /tmp/k0s-config-update.py"

  log "Verifying k0s configuration includes controller IP..."
  ssh_exec "${controller_ip}" "grep -A3 'api:' /tmp/k0s.yaml | head -5"

  # Ensure k0s is in sudo's secure_path (some distros exclude /usr/local/bin)
  ssh_exec "${controller_ip}" "if [ -f /usr/local/bin/k0s ] && [ ! -f /usr/bin/k0s ]; then sudo ln -sf /usr/local/bin/k0s /usr/bin/k0s; fi" || true

  # Clean stale k0s state from any previous run
  ssh_exec "${controller_ip}" "
    sudo systemctl stop k0scontroller 2>/dev/null || true
    sudo systemctl reset-failed k0scontroller 2>/dev/null || true
    sudo rm -f /etc/systemd/system/k0scontroller.service 2>/dev/null || true
    sudo systemctl stop k0sworker 2>/dev/null || true
    sudo systemctl reset-failed k0sworker 2>/dev/null || true
    sudo rm -f /etc/systemd/system/k0sworker.service 2>/dev/null || true
    sudo pkill -9 containerd-shim 2>/dev/null || true
    sudo rm -rf /var/lib/k0s /run/k0s /etc/k0s 2>/dev/null || true
    sudo rm -f /run/k0s/containerd.sock 2>/dev/null || true
    sudo systemctl daemon-reload
  " 2>/dev/null || true

  # Install k0s controller
  log "Installing k0s controller on ${controller_ip}..."
  ssh_exec "${controller_ip}" "sudo k0s install controller --config /tmp/k0s.yaml --enable-worker"
  ssh_exec "${controller_ip}" "sudo k0s start"

  log "Waiting for controller to be ready (60s)..."
  sleep 60

  # Generate worker token
  log "Generating worker join token..."
  local worker_token
  worker_token=$(ssh_exec "${controller_ip}" "sudo k0s token create --role=worker")

  # Install workers (with error checking)
  log "Installing k0s on ${#WORKER_IPS[@]} worker nodes..."
  local failed_workers=()

  for worker_ip in "${WORKER_IPS[@]}"; do
    log "  Installing k0s worker on ${worker_ip}..."
    # Ensure k0s is in sudo's secure_path (some distros exclude /usr/local/bin)
    ssh_exec "${worker_ip}" "if [ -f /usr/local/bin/k0s ] && [ ! -f /usr/bin/k0s ]; then sudo ln -sf /usr/local/bin/k0s /usr/bin/k0s; fi" || true

    # Clean stale k0sworker state from any previous run (service file, data dirs, systemd failed state)
    ssh_exec "${worker_ip}" "
      sudo systemctl stop k0sworker 2>/dev/null || true
      sudo systemctl reset-failed k0sworker 2>/dev/null || true
      sudo rm -f /etc/systemd/system/k0sworker.service 2>/dev/null || true
      sudo rm -rf /var/lib/k0s /run/k0s /etc/k0s /tmp/k0s-token 2>/dev/null || true
      sudo systemctl daemon-reload
    " 2>/dev/null || true

    # Write token to temp file first (stdin pipe doesn't work reliably over SSH)
    if ssh_exec "${worker_ip}" "echo '${worker_token}' | sudo tee /tmp/k0s-token >/dev/null && sudo k0s install worker --token-file=/tmp/k0s-token"; then
      log "  ✓ k0s installed on ${worker_ip}"
    else
      warn "  ✗ Failed to install k0s on ${worker_ip}"
      failed_workers+=("${worker_ip}")
    fi
  done

  # Start workers
  log "Starting k0s workers..."
  for worker_ip in "${WORKER_IPS[@]}"; do
    # Skip workers that failed installation
    local skip=false
    if [[ ${#failed_workers[@]} -gt 0 ]]; then
      for failed_ip in "${failed_workers[@]}"; do
        if [[ "${failed_ip}" == "${worker_ip}" ]]; then
          skip=true
          break
        fi
      done
    fi
    if [[ "${skip}" == "true" ]]; then
      continue
    fi

    log "  Starting k0s worker on ${worker_ip}..."
    if ssh_exec "${worker_ip}" "sudo k0s start"; then
      log "  ✓ k0s started on ${worker_ip}"
    else
      warn "  ✗ Failed to start k0s on ${worker_ip}"
      failed_workers+=("${worker_ip}")
    fi
  done

  if [[ ${#failed_workers[@]} -gt 0 ]]; then
    warn "Some workers failed to install/start: ${failed_workers[*]}"
  fi

  log "Waiting for workers to join (60s)..."
  sleep 60

  # Verify workers actually joined
  log "Verifying worker nodes joined the cluster..."
  local expected_nodes=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))
  local actual_nodes
  actual_nodes=$(ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes --no-headers | wc -l")

  log "Expected nodes: ${expected_nodes}, Actual nodes: ${actual_nodes}"

  if [[ ${actual_nodes} -lt ${expected_nodes} ]]; then
    warn "Not all workers joined! Expected ${expected_nodes} nodes, but only ${actual_nodes} joined."
    log "Current nodes:"
    ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes -o wide"

    log ""
    warn "Possible issues:"
    warn "  1. Workers cannot reach controller's API server"
    warn "  2. Network connectivity issues between nodes"
    warn "  3. k0s worker process failed to start"
    warn ""
    warn "Checking worker logs..."

    # Check first worker's k0s logs
    if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
      local first_worker="${WORKER_IPS[0]}"
      log "Checking k0s status on worker ${first_worker}..."
      ssh_exec "${first_worker}" "sudo k0s status || sudo journalctl -u k0sworker -n 20 --no-pager" || true
    fi

    warn ""
    warn "Continuing installation with ${actual_nodes} nodes..."
    warn "You can manually join workers later using: ./k0s_cluster_with_stack.sh join-workers"
    warn ""
  else
    log "✓ All ${expected_nodes} nodes joined successfully!"
  fi

  # Install local-path storage provisioner for persistent volumes
  log "Installing local-path storage provisioner..."
  ssh_exec "${controller_ip}" "sudo k0s kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml"

  log "Waiting for storage provisioner to be ready..."
  sleep 10

  # Set local-path as default storage class
  log "Setting local-path as default storage class..."
  ssh_exec "${controller_ip}" "sudo k0s kubectl patch storageclass local-path -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"

  log "Storage provisioner installed successfully"

  # Remove control-plane taint from controller node if --enable-worker was used
  # This allows pods to be scheduled on the controller node
  log "Removing control-plane taint from controller node (controller has --enable-worker)..."
  ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes -o name | xargs -I {} sudo k0s kubectl taint node {} node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true"
  log "Controller node can now schedule workload pods"

  # Get kubeconfig
  log "Retrieving kubeconfig..."
  mkdir -p "${HOME}/.kube"
  ssh_exec "${controller_ip}" "sudo cat /var/lib/k0s/pki/admin.conf" > "${HOME}/.kube/k0s-${CLUSTER_NAME}"

  # Update server address to use the controller IP for kubectl access from local machine
  log "Configuring kubeconfig to use controller IP for external access..."
  sed -i.bak "s|server: .*|server: https://${controller_ip}:6443|" "${HOME}/.kube/k0s-${CLUSTER_NAME}"

  export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"

  log "k0s cluster installed successfully!"
  kubectl get nodes

  # Label nodes for proper workload scheduling
  label_nodes
}

# ====== RESOLVE NODE NAME ======
# Maps a config IP to its Kubernetes node name by SSHing to the node
# and reading its hostname (which is what k0s uses as the node name).
# Usage: node_name=$(resolve_node_name "1.2.3.4")
resolve_node_name() {
  local ip="$1"
  # SSH to the node and get the hostname that k0s registered it with
  local node_name
  node_name=$(ssh_exec "${ip}" "hostname -f 2>/dev/null || hostname" 2>/dev/null || echo "")
  echo "${node_name}"
}

# ====== LABEL NODES FOR WORKLOAD SCHEDULING ======
label_nodes() {
  log "Labeling nodes for AI workload scheduling..."

  # Wait for all nodes to be ready
  local node_count=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))
  log "Waiting for ${node_count} nodes to be ready..."

  local timeout=300
  local elapsed=0
  while [[ $(kubectl get nodes --no-headers | grep -c "Ready") -lt ${node_count} ]]; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      warn "Timeout waiting for all nodes to be ready, proceeding anyway..."
      break
    fi
  done

  # Label controller nodes
  for controller_ip in "${CONTROLLER_IPS[@]}"; do
    local node_name
    node_name=$(resolve_node_name "${controller_ip}")

    if [[ -z "${node_name}" ]]; then
      warn "  Could not resolve hostname for controller ${controller_ip}, skipping..."
      continue
    fi

    # Verify this node exists in the cluster
    if ! kubectl get node "${node_name}" &>/dev/null; then
      warn "  Node '${node_name}' (from ${controller_ip}) not found in cluster, skipping..."
      continue
    fi

    log "Labeling controller node: ${node_name} (${controller_ip})"
    kubectl label nodes "${node_name}" \
      splunk.ai/node-role=controller \
      splunk.ai/workload-type=control-plane \
      node.kubernetes.io/role=controller \
      --overwrite

    # For single-node clusters (controller with --enable-worker), also add CPU workload labels
    if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
      log "  → Single-node cluster detected, adding CPU workload labels to controller..."
      kubectl label nodes "${node_name}" \
        splunk.ai/workload-type=cpu \
        node.kubernetes.io/workload=ai-cpu \
        splunk.ai/instance-type=cpu-worker \
        --overwrite
      log "  ✓ CPU workload labels added to controller node"
    fi
  done

  # Label worker nodes based on their configuration
  local worker_index=0
  for worker_ip in "${WORKER_IPS[@]}"; do
    local node_name
    node_name=$(resolve_node_name "${worker_ip}")

    if [[ -z "${node_name}" ]]; then
      warn "  Could not resolve hostname for worker ${worker_ip}, skipping..."
      worker_index=$((worker_index + 1))
      continue
    fi

    if ! kubectl get node "${node_name}" &>/dev/null; then
      warn "  Node '${node_name}' (from ${worker_ip}) not found in cluster, skipping..."
      worker_index=$((worker_index + 1))
      continue
    fi

    # Determine if this is a GPU or CPU worker based on index
    # First CPU_WORKER_COUNT workers are CPU, rest are GPU
    if [[ ${worker_index} -lt ${CPU_WORKER_COUNT} ]]; then
      log "Labeling CPU worker node: ${node_name} (${worker_ip})"
      kubectl label nodes "${node_name}" \
        splunk.ai/node-role=worker \
        splunk.ai/workload-type=cpu \
        node.kubernetes.io/workload=ai-cpu \
        splunk.ai/instance-type=cpu-worker \
        --overwrite
    else
      log "Labeling GPU worker node: ${node_name} (${worker_ip})"
      kubectl label nodes "${node_name}" \
        splunk.ai/node-role=worker \
        splunk.ai/workload-type=gpu \
        node.kubernetes.io/workload=ai-gpu \
        splunk.ai/instance-type=gpu-worker \
        nvidia.com/gpu=true \
        --overwrite
    fi
    worker_index=$((worker_index + 1))
  done

  # Add taints to GPU nodes to prevent non-GPU workloads from scheduling there
  log "Adding taints to GPU nodes..."
  kubectl get nodes -l splunk.ai/workload-type=gpu -o name | while read -r node; do
    kubectl taint nodes "${node#node/}" nvidia.com/gpu=true:NoSchedule --overwrite || true
  done

  log "Node labeling complete!"
  log "Nodes with labels:"
  kubectl get nodes --show-labels
}

# ====== WAIT FOR CRD ======
wait_for_crd() {
  local crd_name="$1"
  local timeout="${2:-300}"
  log "Waiting for CRD ${crd_name} (timeout: ${timeout}s)..."

  local elapsed=0
  while ! kubectl get crd "${crd_name}" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      err "Timeout waiting for CRD ${crd_name}"
    fi
  done
  log "CRD ${crd_name} is ready"
}

# ====== ENSURE NAMESPACE ======
ensure_namespace() {
  local ns="$1"
  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "Creating namespace ${ns}..."
    kubectl create namespace "${ns}"
  fi
}

# ====== INSTALL MINIO ======
# TODO remove
install_minio() {
  if [[ "${MINIO_ENABLED}" != "true" ]]; then
    log "MinIO is disabled (minio.enabled != true); skipping."
    return 0
  fi

  # Auto-generate root password if not set
  if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
    MINIO_ROOT_PASSWORD="$(openssl rand -base64 24 2>/dev/null || head -c 32 /dev/urandom | base64)"
    log "Generated MinIO root password (saved for secret creation)"
  fi

  # External MinIO (e.g. on EC2): only create credentials secret; no in-cluster install
  if [[ "${MINIO_EXTERNAL}" == "true" ]]; then
    log "Using external MinIO (minio.external=true); skipping in-cluster install."
    if [[ -z "${MINIO_ENDPOINT}" ]]; then
      warn "minio.endpoint is empty; set it to the MinIO URL (e.g. http://<ip>:9000) for AIPlatform to use external MinIO."
    fi
    ensure_namespace "${AI_NS}"
    local secret_name="minio-credentials"
    kubectl -n "${AI_NS}" create secret generic "${secret_name}" \
      --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
      --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
      --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
      --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
      --from-literal=MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" \
      --from-literal=MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
      --dry-run=client -o yaml | kubectl -n "${AI_NS}" apply -f -
    log "✓ External MinIO credentials secret ${AI_NS}/${secret_name} ready"
    return 0
  fi

  # In-cluster MinIO installation
  log "Installing MinIO in ${MINIO_NS}..."
  ensure_namespace "${MINIO_NS}"

  # Create MinIO secret
  kubectl create secret generic minio-creds \
    --namespace="${MINIO_NS}" \
    --from-literal=accesskey="${MINIO_ROOT_USER}" \
    --from-literal=secretkey="${MINIO_ROOT_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Deploy MinIO
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: ${MINIO_NS}
spec:
  storageClassName: ${MINIO_PVC_STORAGE_CLASS}
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${MINIO_PVC_SIZE}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ${MINIO_NS}
spec:
  type: ClusterIP
  ports:
    - port: 9000
      targetPort: 9000
      name: api
    - port: 9001
      targetPort: 9001
      name: console
  selector:
    app: minio
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${MINIO_NS}
spec:
  replicas: ${MINIO_REPLICAS}
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: minio-creds
              key: accesskey
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: minio-creds
              key: secretkey
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: data
          mountPath: /data
        resources:
          requests:
            cpu: "500m"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minio-pvc
EOF

  log "Waiting for MinIO to be ready..."
  kubectl wait --for=condition=ready pod -l app=minio -n "${MINIO_NS}" --timeout=300s

  # Create credentials secret in AI platform namespace
  # SAIA and pkg/storage expect s3_access_key/s3_secret_key; models/SAIA expect MINIO_ACCESS_KEY/MINIO_SECRET_KEY.
  ensure_namespace "${AI_NS}"
  local secret_name="minio-credentials"
  kubectl -n "${AI_NS}" create secret generic "${secret_name}" \
    --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
    --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
    --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
    --from-literal=MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" \
    --from-literal=MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
    --dry-run=client -o yaml | kubectl -n "${AI_NS}" apply -f -

  # Create bucket and directories using a job
  log "Verifying MinIO bucket: ${MINIO_BUCKET}..."

  # Delete existing job if it exists (Jobs are immutable, can't be updated)
  kubectl delete job minio-create-bucket -n "${MINIO_NS}" --ignore-not-found=true 2>/dev/null || true
  sleep 2

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-bucket
  namespace: ${MINIO_NS}
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: mc
        image: minio/mc:latest
        command:
        - /bin/sh
        - -c
        - |
          set -e
          echo "Configuring MinIO client..."
          mc alias set myminio http://minio.${MINIO_NS}.svc.cluster.local:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

          echo ""
          echo "Checking if bucket exists..."
          if mc ls myminio/${MINIO_BUCKET} >/dev/null 2>&1; then
            echo "✓ Bucket '${MINIO_BUCKET}' already exists"
          else
            echo "Creating bucket: ${MINIO_BUCKET}"
            mc mb myminio/${MINIO_BUCKET}
            echo "Setting anonymous read policy for bucket..."
            mc anonymous set download myminio/${MINIO_BUCKET} || true
          fi

          echo ""
          echo "Verifying required directories..."
          DIRS_TO_CREATE=""

          # Check each directory
          for dir in apps artifacts model_artifacts tasks; do
            if mc ls myminio/${MINIO_BUCKET}/\$dir/ >/dev/null 2>&1; then
              echo "  ✓ \$dir/ exists"
            else
              echo "  → \$dir/ missing, will create"
              DIRS_TO_CREATE="\$DIRS_TO_CREATE \$dir"
            fi
          done

          # Create missing directories only
          if [ -n "\$DIRS_TO_CREATE" ]; then
            echo ""
            echo "Creating missing directories..."
            for dir in \$DIRS_TO_CREATE; do
              case \$dir in
                apps)
                  echo "  - apps/ (for Splunk apps and add-ons)"
                  echo "placeholder" | mc pipe myminio/${MINIO_BUCKET}/apps/.keep
                  ;;
                artifacts)
                  echo "  - artifacts/ (for AI Platform artifacts)"
                  echo "placeholder" | mc pipe myminio/${MINIO_BUCKET}/artifacts/.keep
                  ;;
                model_artifacts)
                  echo "  - model_artifacts/ (for AI model artifacts)"
                  echo "placeholder" | mc pipe myminio/${MINIO_BUCKET}/model_artifacts/.keep
                  ;;
                tasks)
                  echo "  - tasks/ (for AI Platform tasks)"
                  echo "placeholder" | mc pipe myminio/${MINIO_BUCKET}/tasks/.keep
                  ;;
              esac
            done
          else
            echo ""
            echo "✓ All directories already exist, nothing to create"
          fi

          echo ""
          echo "Final verification:"
          ALL_OK=true
          for dir in apps artifacts model_artifacts tasks; do
            if mc ls myminio/${MINIO_BUCKET}/\$dir/ >/dev/null 2>&1; then
              echo "  ✓ \$dir/ verified"
            else
              echo "  ✗ \$dir/ missing"
              ALL_OK=false
            fi
          done

          if [ "\$ALL_OK" = "true" ]; then
            echo ""
            echo "✓ Bucket structure ready!"
            echo ""
            echo "Bucket contents:"
            mc ls myminio/${MINIO_BUCKET}/
          else
            echo ""
            echo "✗ Some directories are missing"
            exit 1
          fi
EOF

  log "Waiting for bucket verification job to complete..."
  if kubectl wait --for=condition=complete job/minio-create-bucket -n "${MINIO_NS}" --timeout=120s; then
    log "✓ MinIO bucket structure verified"

    # Show job logs for verification
    kubectl logs -n "${MINIO_NS}" job/minio-create-bucket --tail=20 2>/dev/null || true
  else
    warn "Bucket verification job did not complete in time, checking status..."
    kubectl describe job/minio-create-bucket -n "${MINIO_NS}" || true
    kubectl logs -n "${MINIO_NS}" job/minio-create-bucket --tail=50 || true
  fi

  log "✓ MinIO installed; bucket=${MINIO_BUCKET}; credentials secret ${AI_NS}/${secret_name}"
}

# ====== INSTALL CERT-MANAGER ======
install_cert_manager() {
  log "Installing cert-manager..."

  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

  wait_for_crd certificates.cert-manager.io 300
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s

  # Wait for webhook to be fully operational
  log "Waiting for cert-manager webhooks to be ready..."

  # First, ensure webhook pods are running
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=webhook -n cert-manager --timeout=120s || warn "Webhook pods may not be ready"

  # Wait for webhook endpoint to have addresses
  local retries=0
  local max_retries=60
  while (( retries < max_retries )); do
    local webhook_ip
    webhook_ip=$(kubectl -n cert-manager get endpoints cert-manager-webhook -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${webhook_ip}" ]]; then
      log "cert-manager webhook endpoint found: ${webhook_ip}"
      break
    fi
    sleep 2
    retries=$((retries + 1))
  done

  if (( retries >= max_retries )); then
    warn "cert-manager webhook endpoint not found after ${max_retries} retries"
  fi

  # Give webhooks extra time to stabilize and register with API server
  log "Waiting for webhooks to stabilize (30s)..."
  sleep 30

  # Test webhook by creating a test Certificate resource
  log "Testing cert-manager webhook functionality..."
  cat <<EOF | kubectl apply -f - || warn "Webhook test failed, but continuing..."
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: test-selfsigned
  namespace: cert-manager
spec:
  selfSigned: {}
EOF

  # Clean up test issuer
  kubectl delete issuer test-selfsigned -n cert-manager --ignore-not-found=true 2>/dev/null || true

  log "cert-manager installed successfully"
}

# ====== INSTALL NVIDIA DRIVERS ON GPU NODES (bare-metal / EC2) ======
# EKS GPU AMIs ship with NVIDIA drivers pre-installed.
# For k0s on generic AMIs (e.g. Amazon Linux 2023), we must install them
# on the host before the Kubernetes device-plugin can expose GPUs.
install_nvidia_host_drivers() {
  if [[ ${GPU_WORKER_COUNT} -eq 0 ]]; then
    log "Skipping NVIDIA host driver install (no GPU workers)"
    return 0
  fi

  log "Installing NVIDIA drivers & container toolkit on GPU worker nodes..."

  # Ensure WORKER_IPS is populated (it may not be if install_k0s_cluster was skipped)
  if [[ -z "${WORKER_IPS+x}" || ${#WORKER_IPS[@]} -eq 0 ]]; then
    if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
      IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
      log "  Loaded ${#WORKER_IPS[@]} worker IP(s) from config: ${WORKER_IPS[*]}"
    else
      warn "No worker IPs available; skipping host driver install"
      return 0
    fi
  fi

  # Identify GPU worker IPs (workers after the first CPU_WORKER_COUNT)
  local gpu_ips=()
  local idx=0
  for ip in "${WORKER_IPS[@]}"; do
    if [[ ${idx} -ge ${CPU_WORKER_COUNT} ]]; then
      gpu_ips+=("${ip}")
    fi
    idx=$((idx + 1))
  done

  if [[ ${#gpu_ips[@]} -eq 0 ]]; then
    warn "No GPU worker IPs found; skipping host driver install"
    return 0
  fi

  for gpu_ip in "${gpu_ips[@]}"; do
    log "Checking NVIDIA driver on ${gpu_ip}..."

    # Check if driver is already installed
    if ssh_exec "${gpu_ip}" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null" &>/dev/null; then
      local driver_ver
      driver_ver=$(ssh_exec "${gpu_ip}" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null" || echo "unknown")
      log "  ✓ NVIDIA driver already installed on ${gpu_ip} (version: ${driver_ver})"
    else
      log "  Installing NVIDIA driver on ${gpu_ip}..."
      ssh_exec "${gpu_ip}" "
        set -e
        # Install kernel headers (needed for DKMS driver build)
        sudo dnf install -y kernel-devel-\$(uname -r) kernel-headers-\$(uname -r) 2>/dev/null || \
          sudo yum install -y kernel-devel-\$(uname -r) kernel-headers-\$(uname -r) 2>/dev/null || \
          sudo apt-get install -y linux-headers-\$(uname -r) 2>/dev/null || true

        # Detect OS and add appropriate NVIDIA repo
        if [ -f /etc/amzn-release ] || grep -qi 'amzn' /etc/os-release 2>/dev/null; then
          sudo dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo 2>/dev/null || true
          sudo dnf install -y nvidia-driver nvidia-driver-cuda nvidia-driver-libs 2>/dev/null || \
            sudo dnf module install -y nvidia-driver:latest-dkms 2>/dev/null || true
        elif [ -f /etc/redhat-release ]; then
          RHEL_MAJOR=\$(rpm -E %{rhel} 2>/dev/null || echo 9)
          if [ \"\${RHEL_MAJOR}\" -ge 10 ]; then
            # Add RHEL 10 CUDA repo only; remove any stale rhel9 repo to prevent GPG conflicts
            sudo rm -f /etc/yum.repos.d/cuda-rhel9.repo 2>/dev/null || true
            sudo dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel10/x86_64/cuda-rhel10.repo 2>/dev/null || true

            # RHEL 10 removed DNF modularity; DKMS kmod requires EPEL
            if ! rpm -q epel-release >/dev/null 2>&1; then
              echo 'Installing EPEL for dkms...'
              sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm 2>/dev/null || true
            fi
            sudo dnf install -y dkms 2>/dev/null || true

            sudo dnf install -y nvidia-driver nvidia-driver-cuda nvidia-driver-libs 2>/dev/null || \
              sudo dnf install -y --nobest nvidia-driver nvidia-driver-cuda nvidia-driver-libs 2>/dev/null || \
              sudo dnf install -y --nobest nvidia-open 2>/dev/null || true
          else
            sudo dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo 2>/dev/null || true
            sudo dnf module install -y nvidia-driver:latest-dkms 2>/dev/null || \
              sudo dnf install -y --nobest nvidia-driver nvidia-driver-cuda nvidia-driver-libs 2>/dev/null || true
          fi
        elif [ -f /etc/debian_version ]; then
          curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/cuda-keyring.deb
          sudo dpkg -i /tmp/cuda-keyring.deb
          sudo apt-get update && sudo apt-get install -y nvidia-driver-550 2>/dev/null || true
        fi

        # Load nvidia kernel module immediately (avoids needing a reboot)
        sudo modprobe nvidia 2>/dev/null || true
      " || warn "Driver install on ${gpu_ip} had issues — check manually"

      # Verify
      if ssh_exec "${gpu_ip}" "nvidia-smi 2>/dev/null" &>/dev/null; then
        log "  ✓ NVIDIA driver installed successfully on ${gpu_ip}"
      else
        warn "  NVIDIA driver may need a reboot on ${gpu_ip} to take effect"
      fi
    fi

    # Install NVIDIA Container Toolkit (needed for GPU containers in k0s)
    log "  Ensuring NVIDIA Container Toolkit on ${gpu_ip}..."
    ssh_exec "${gpu_ip}" "
      if command -v nvidia-ctk &>/dev/null; then
        echo 'nvidia-ctk already installed'
      else
        # Add NVIDIA Container Toolkit repo
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
          sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null 2>/dev/null || true
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
          sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true

        # Install
        sudo dnf install -y nvidia-container-toolkit 2>/dev/null || \
          sudo yum install -y nvidia-container-toolkit 2>/dev/null || \
          sudo apt-get install -y nvidia-container-toolkit 2>/dev/null || true
      fi

      # Configure for k0s containerd (k0s uses /run/k0s/containerd.sock)
      if [ -d /etc/k0s/containerd.d ]; then
        # nvidia-ctk writes to /etc/containerd/conf.d/ by default, not the
        # k0s drop-in dir. Generate it first, then copy with fixups.
        sudo nvidia-ctk runtime configure --runtime=containerd 2>/dev/null || true

        # Copy the generated config to k0s drop-in location
        if [ -f /etc/containerd/conf.d/99-nvidia.toml ]; then
          sudo cp /etc/containerd/conf.d/99-nvidia.toml /etc/k0s/containerd.d/nvidia.toml
          sudo rm -f /etc/containerd/conf.d/99-nvidia.toml
        elif [ ! -s /etc/k0s/containerd.d/nvidia.toml ]; then
          # Fallback: nvidia-ctk may have written directly; try explicit config path
          sudo nvidia-ctk runtime configure --runtime=containerd \
            --config=/etc/k0s/containerd.d/nvidia.toml 2>/dev/null || true
        fi

        # Strip version/imports lines so the file is treated as a drop-in
        # snippet, not a full containerd config (prevents node NotReady).
        sudo sed -i '/^version/d; /^imports/d; /^disabled_plugins/d; /^required_plugins/d' \
          /etc/k0s/containerd.d/nvidia.toml 2>/dev/null || true
      elif [ -f /etc/containerd/config.toml ]; then
        sudo nvidia-ctk runtime configure --runtime=containerd 2>/dev/null || true
      fi

      # Generate CDI (Container Device Interface) specs so the device
      # plugin can discover GPUs via CDI when using the nvidia RuntimeClass.
      sudo mkdir -p /etc/cdi
      sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>/dev/null || true

      # Kill any leftover containerd-shim processes from previous runs
      # before restarting the worker. Stale shims keep the old containerd
      # socket busy and cause ping-containerd-timeout errors on restart.
      sudo systemctl stop k0sworker 2>/dev/null || true
      sleep 3
      sudo pkill -9 containerd-shim 2>/dev/null || true
      sudo rm -f /run/k0s/containerd.sock 2>/dev/null || true

      # Restart k0s worker to pick up containerd config changes
      sudo systemctl start k0sworker 2>/dev/null || true
    " || warn "  Container toolkit setup on ${gpu_ip} had issues — check manually"

    log "  ✓ GPU node ${gpu_ip} setup complete"
  done

  # Wait for GPU workers to rejoin and verify they are Ready
  log "Waiting for GPU worker nodes to rejoin cluster and become Ready..."
  local gpu_wait_timeout=180
  local gpu_wait_elapsed=0
  local all_gpu_ready=false

  while [[ ${gpu_wait_elapsed} -lt ${gpu_wait_timeout} ]]; do
    all_gpu_ready=true
    for gpu_ip in "${gpu_ips[@]}"; do
      # Resolve GPU node name via SSH hostname lookup
      local gpu_node
      gpu_node=$(resolve_node_name "${gpu_ip}")

      if [[ -z "${gpu_node}" ]] || ! kubectl get node "${gpu_node}" &>/dev/null; then
        all_gpu_ready=false
        break
      fi

      local ready_status
      ready_status=$(kubectl get node "${gpu_node}" -o json 2>/dev/null | \
        jq -r '.status.conditions[] | select(.type=="Ready") | .status' 2>/dev/null || echo "")
      if [[ "${ready_status}" != "True" ]]; then
        all_gpu_ready=false
        break
      fi
    done

    if [[ "${all_gpu_ready}" == "true" ]]; then
      log "✓ All GPU worker nodes are Ready"
      break
    fi

    sleep 10
    gpu_wait_elapsed=$((gpu_wait_elapsed + 10))
    log "  Waiting for GPU nodes to be Ready... ${gpu_wait_elapsed}/${gpu_wait_timeout}s"
  done

  if [[ "${all_gpu_ready}" != "true" ]]; then
    warn "Some GPU nodes may not be Ready yet. Check with: kubectl get nodes"
    warn "GPU nodes may need a reboot if NVIDIA drivers were freshly installed."
  fi

  # Verify GPUs are visible to Kubernetes
  log "Checking if GPUs are visible to Kubernetes..."
  local gpu_capacity
  gpu_capacity=$(kubectl get nodes -l splunk.ai/workload-type=gpu -o json 2>/dev/null | \
    jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add' 2>/dev/null || echo "0")
  if [[ "${gpu_capacity}" -gt 0 ]]; then
    log "✓ Total GPUs visible to Kubernetes: ${gpu_capacity}"
  else
    warn "No GPUs visible to Kubernetes yet — the NVIDIA device plugin may still be starting"
    warn "Check with: kubectl get nodes -o json | jq '.items[].status.capacity'"
  fi

  log "NVIDIA host driver installation complete"
}

# ====== INSTALL NVIDIA DEVICE PLUGIN (matches EKS approach) ======
# Ref: eks_cluster_with_stack.sh — uses the simple DaemonSet, NOT the GPU Operator.
# The GPU Operator's driver container images don't exist for Amazon Linux 2023.
install_nvidia_device_plugin() {
  if [[ ${GPU_WORKER_COUNT} -eq 0 ]]; then
    log "Skipping NVIDIA device plugin (no GPU workers)"
    return 0
  fi

  local ver="${NVIDIA_VERSION:-v0.17.3}"
  log "Installing NVIDIA device plugin DaemonSet (${ver})..."

  # Create the nvidia RuntimeClass so pods (including the device plugin
  # itself) can use the NVIDIA container runtime for GPU access.
  log "  Creating nvidia RuntimeClass..."
  cat <<'RTEOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
RTEOF

  kubectl apply -n kube-system \
    -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${ver}/deployments/static/nvidia-device-plugin.yml"

  # Patch the device plugin DaemonSet:
  #  1) runtimeClassName: nvidia — so the plugin container can access NVML/CDI
  #     (without this it reports "Incompatible strategy detected auto" / "No devices found")
  #  2) nodeSelector for GPU nodes — the nvidia runtime handler only exists on
  #     GPU workers; non-GPU nodes would fail to start pods with this RuntimeClass
  log "  Patching device plugin: nvidia RuntimeClass + GPU nodeSelector..."
  kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type='json' \
    -p='[
      {"op": "add", "path": "/spec/template/spec/runtimeClassName", "value": "nvidia"},
      {"op": "add", "path": "/spec/template/spec/nodeSelector", "value": {"splunk.ai/workload-type": "gpu"}}
    ]' 2>/dev/null || true

  kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=3m || true

  log "NVIDIA device plugin installed successfully"
}

# ====== INSTALL PROMETHEUS OPERATOR ======
install_kube_prometheus() {
  log "Installing kube-prometheus-stack..."

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  # TODO uncomment
  # helm repo update prometheus-community  # Only update the specific repo we need

  helm_retry 3 upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --wait --timeout=10m

  log "kube-prometheus-stack installed successfully"
}

# ====== INSTALL OTEL OPERATOR ======
install_otel_operator_and_contrib_collector() {
  log "Installing OpenTelemetry Operator..."

  # OTEL operator uses cert-manager for webhook certs — ensure webhook is ready
  wait_for_cert_manager_webhook 30 10

  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true
  # TODO uncomment
  # helm repo update open-telemetry  # Only update the specific repo we need

  # Use cert-manager for webhook certificates (now that konnectivity is fixed)
  helm_retry 3 upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --namespace opentelemetry-operator-system --create-namespace \
    --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib \
    --set admissionWebhooks.certManager.enabled=true \
    --wait --timeout=10m

  wait_for_crd opentelemetrycollectors.opentelemetry.io 300

  log "OpenTelemetry Operator installed successfully"
}

# ====== INSTALL RAY OPERATOR ======
install_ray_operator() {
  log "Installing KubeRay Operator..."

  helm repo add kuberay https://ray-project.github.io/kuberay-helm/ || true
  # TODO uncomment
  # helm repo update kuberay  # Only update the specific repo we need

  helm_retry 3 upgrade --install kuberay-operator kuberay/kuberay-operator \
    --namespace ray-system --create-namespace \
    --version 1.0.0 \
    --wait --timeout=10m

  wait_for_crd rayservices.ray.io 300
  wait_for_crd rayclusters.ray.io 300

  log "KubeRay Operator installed successfully"
}

# ====== INSTALL SPLUNK OPERATOR ======
install_splunk_operator() {
  log "Installing Splunk Operator..."

  if [[ ! -f "${SPLUNK_OPERATOR_FILE}" ]]; then
    warn "Splunk operator file not found: ${SPLUNK_OPERATOR_FILE}"
    return 0
  fi

  # Determine the namespace from the YAML file or use default
  local splunk_operator_ns="splunk-operator"
  ensure_namespace "${splunk_operator_ns}"

  # Create image pull secrets in splunk-operator namespace BEFORE applying manifests
  log "Creating image pull secrets in ${splunk_operator_ns} namespace..."
  create_image_pull_secrets "${splunk_operator_ns}" >/dev/null 2>&1 || true

  # Use kubectl replace --force for CRDs to avoid annotation size limits
  # This deletes and recreates the resource, avoiding the annotation issue
  log "Installing/updating Splunk Operator CRDs and resources..."

  # First, try to create (for fresh install)
  if kubectl create -f "${SPLUNK_OPERATOR_FILE}" 2>/dev/null; then
    log "Splunk Operator resources created successfully"
  else
    # Resources likely already exist, use replace --force
    log "Resources already exist, updating with replace..."
    kubectl replace --force -f "${SPLUNK_OPERATOR_FILE}" 2>&1 | grep -v "Warning: --force is deprecated" || true
  fi

  # Patch splunk-operator deployment with imagePullSecrets if any exist
  log "Checking for imagePullSecrets to add to Splunk Operator deployment..."
  local secrets_patch=""
  for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
    if kubectl get secret "${secret_name}" -n "${splunk_operator_ns}" &>/dev/null 2>&1; then
      secrets_patch+='{"name":"'"${secret_name}"'"},'
      log "  Found secret: ${secret_name}"
    fi
  done

  if [[ -n "${secrets_patch}" ]]; then
    secrets_patch="${secrets_patch%,}"
    local dep_name
    dep_name=$(kubectl -n "${splunk_operator_ns}" get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${dep_name}" ]]; then
      log "Patching Splunk Operator deployment (${dep_name}) with imagePullSecrets..."
      kubectl -n "${splunk_operator_ns}" patch deployment "${dep_name}" \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":['"${secrets_patch}"']}]' \
        2>/dev/null || log "  imagePullSecrets may already exist"

      # Restart to apply changes
      kubectl rollout restart deployment "${dep_name}" -n "${splunk_operator_ns}" 2>/dev/null || true
    fi
  fi

  wait_for_crd standalones.enterprise.splunk.com 300

  log "Splunk Operator installed successfully"
}

# ====== WAIT FOR CERT-MANAGER WEBHOOK ======
# Ensures cert-manager webhook is responsive before applying resources that
# contain Certificate/Issuer CRs (e.g. artifacts.yaml).
wait_for_cert_manager_webhook() {
  local max_attempts="${1:-30}"
  local sleep_interval="${2:-10}"

  log "Verifying cert-manager webhook is responsive..."

  # 1. Ensure webhook pod is running
  if ! kubectl get namespace cert-manager &>/dev/null; then
    warn "cert-manager namespace not found, skipping webhook check"
    return 0
  fi

  kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/component=webhook \
    -n cert-manager --timeout=120s 2>/dev/null \
    || warn "cert-manager webhook pod may not be fully ready"

  # 2. Ensure webhook endpoint has addresses
  local attempt=0
  while (( attempt < max_attempts )); do
    local webhook_ip
    webhook_ip=$(kubectl -n cert-manager get endpoints cert-manager-webhook \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")

    if [[ -n "${webhook_ip}" ]]; then
      log "cert-manager webhook endpoint: ${webhook_ip}"
      break
    fi

    log "  Waiting for cert-manager webhook endpoint... (${attempt}/${max_attempts})"
    sleep "${sleep_interval}"
    attempt=$((attempt + 1))
  done

  if (( attempt >= max_attempts )); then
    warn "cert-manager webhook endpoint not found after ${max_attempts} attempts"
    return 1
  fi

  # 3. Functional test: create and delete a test Issuer
  local test_ok=false
  for i in $(seq 1 "${max_attempts}"); do
    if kubectl apply -f - <<'TESTEOF' 2>/dev/null
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: cert-manager-webhook-test
  namespace: cert-manager
spec:
  selfSigned: {}
TESTEOF
    then
      kubectl delete issuer cert-manager-webhook-test -n cert-manager \
        --ignore-not-found=true 2>/dev/null || true
      test_ok=true
      log "✓ cert-manager webhook is responsive"
      break
    fi
    log "  cert-manager webhook not yet accepting requests... (${i}/${max_attempts})"
    sleep "${sleep_interval}"
  done

  if [[ "${test_ok}" != "true" ]]; then
    warn "cert-manager webhook did not become responsive after ${max_attempts} attempts"
    return 1
  fi

  return 0
}

# ====== INSTALL SPLUNK AI OPERATOR ======
install_splunk_ai_operator() {
  log "Installing Splunk AI Operator from ${SPLUNK_AI_FILE}..."

  if [[ ! -f "${SPLUNK_AI_FILE}" ]]; then
    warn "Splunk AI Operator file not found: ${SPLUNK_AI_FILE}"
    warn "Please ensure artifacts.yaml exists in the cluster_setup directory"
    return 0
  fi

  # Create namespace for AI Operator
  local ai_operator_ns="splunk-ai-operator-system"
  ensure_namespace "${ai_operator_ns}"

  # Create image pull secrets in operator namespace BEFORE applying manifests
  log "Creating image pull secrets in ${ai_operator_ns} namespace..."
  create_image_pull_secrets "${ai_operator_ns}" >/dev/null 2>&1 || true

  # Ensure cert-manager webhook is ready before applying (artifacts.yaml contains
  # Certificate and Issuer resources that require the webhook to be responsive)
  wait_for_cert_manager_webhook 30 10

  # Apply the artifacts.yaml file (contains CRDs and operator deployment)
  log "Applying Splunk AI Operator manifests..."

  # Use server-side apply with force to ensure all fields are updated including images
  log "Using server-side apply to ensure image URLs are updated..."
  local apply_output
  apply_output=$(kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1) || true
  echo "${apply_output}"

  # Check if any cert-manager resources (Certificate/Issuer) failed due to webhook errors
  if echo "${apply_output}" | grep -qi "webhook.*cert-manager\|failed calling webhook.*cert-manager\|i/o timeout"; then
    warn "Some cert-manager resources failed on first attempt, retrying..."

    # Wait for webhook to stabilize and retry
    sleep 15
    wait_for_cert_manager_webhook 15 10

    log "Retrying full apply for cert-manager resources..."
    kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1 | \
      grep -iE "certificate|issuer|error|warning" || true
  fi

  # Verify that the critical Certificate and Issuer resources exist
  log "Verifying cert-manager resources were created..."
  local cm_retries=0
  local cm_max=12
  while (( cm_retries < cm_max )); do
    local serving_cert
    serving_cert=$(kubectl get certificate splunk-ai-operator-serving-cert \
      -n "${ai_operator_ns}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${serving_cert}" ]]; then
      log "✓ Certificate 'splunk-ai-operator-serving-cert' exists"
      break
    fi

    log "  Waiting for cert-manager resources to be created... (${cm_retries}/${cm_max})"
    sleep 10
    # Re-apply on each retry to ensure cert-manager resources are processed
    kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1 | \
      grep -iE "certificate|issuer" || true
    cm_retries=$((cm_retries + 1))
  done

  if (( cm_retries >= cm_max )); then
    warn "Certificate resources may not have been created — the AI operator webhook may not work"
  fi

  # Specifically ensure ClusterRole is updated (common RBAC update issue)
  log "Verifying ClusterRole RBAC permissions..."
  kubectl apply -f "${SPLUNK_AI_FILE}" --server-side --force-conflicts 2>&1 | grep -i "clusterrole" || true

  # Find the operator deployment
  log "Waiting for Splunk AI Operator deployment..."
  local dep
  dep=$(kubectl -n "${ai_operator_ns}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 -E 'splunk-ai-operator|ai-operator' || echo "")

  if [[ -z "$dep" ]]; then
    warn "Could not detect Splunk AI Operator deployment, checking all deployments..."
    kubectl -n "${ai_operator_ns}" get deploy,po -o wide || true
    # Try to find any deployment with controller-manager in the name
    dep=$(kubectl -n "${ai_operator_ns}" get deploy -o name | grep -i controller || echo "")
  fi

  if [[ -n "$dep" ]]; then
    # Remove 'deployment.apps/' prefix if present
    dep="${dep#deployment.apps/}"
    log "Found deployment: ${dep}"

    # Patch deployment with imagePullSecrets if any exist
    log "Checking for imagePullSecrets to add to operator deployment..."
    local secrets_patch=""
    for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
      if kubectl get secret "${secret_name}" -n "${ai_operator_ns}" &>/dev/null 2>&1; then
        secrets_patch+='{"name":"'"${secret_name}"'"},'
        log "  Found secret: ${secret_name}"
      fi
    done

    if [[ -n "${secrets_patch}" ]]; then
      # Remove trailing comma
      secrets_patch="${secrets_patch%,}"
      log "Patching operator deployment with imagePullSecrets..."
      kubectl -n "${ai_operator_ns}" patch deployment "${dep}" \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":['"${secrets_patch}"']}]' \
        2>/dev/null || log "  imagePullSecrets may already exist or path differs"
    fi

    # Force restart the deployment to pick up new environment variables (image URLs)
    log "Restarting operator deployment to apply updated image configuration..."
    kubectl rollout restart deployment "${dep}" -n "${ai_operator_ns}"

    wait_rollout "${ai_operator_ns}" deploy "${dep}"
  else
    warn "Could not find operator deployment, will wait for CRDs instead"
  fi

  # Wait for CRDs to be available
  log "Waiting for AI Platform CRDs..."
  wait_for_crd aiplatforms.ai.splunk.com 600
  wait_for_crd aiservices.ai.splunk.com 600

  log "Splunk AI Operator ready (ns=${ai_operator_ns}, deploy=${dep:-unknown})"
}

# ====== CREATE MINIO SECRET FOR AI PLATFORM ======
create_minio_secret() {
  local ns="$1"
  ensure_namespace "${ns}"

  log "Creating MinIO credentials secret in ${ns}..."

  kubectl create secret generic minio-credentials \
    --namespace="${ns}" \
    --from-literal=accessKey="${MINIO_ROOT_USER}" \
    --from-literal=secretKey="${MINIO_ROOT_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "MinIO credentials secret created"
  echo "minio-credentials"
}

# ====== SETUP ECR REPOSITORY PERMISSIONS ======
setup_ecr_permissions() {
  local repo_prefix="${1:-ml-platform}"
  # Use ECR_REGION from config, fallback to REGION, then us-east-2
  local ecr_region="${ECR_REGION:-${REGION:-us-east-2}}"

  log "Checking ECR repository permissions for: ${repo_prefix} in region ${ecr_region}..."

  # Check if AWS credentials are available
  if ! aws sts get-caller-identity &>/dev/null; then
    warn "AWS credentials not available - skipping ECR setup"
    return 0
  fi

  local current_account
  current_account=$(aws sts get-caller-identity --query Account --output text)
  log "Current AWS Account: ${current_account}"

  # List repositories matching prefix
  local repos
  repos=$(aws ecr describe-repositories --region "${ecr_region}" 2>/dev/null | \
    jq -r --arg prefix "${repo_prefix}" '.repositories[] | select(.repositoryName | startswith($prefix)) | .repositoryName' || echo "")

  if [[ -z "${repos}" ]]; then
    warn "No ECR repositories found with prefix: ${repo_prefix}"
    log "You may need to:"
    log "  1. Create ECR repositories for AI Platform images"
    log "  2. Push images to ECR"
    log "  3. Grant pull permissions to this account (${current_account})"
    return 0
  fi

  log "Found ECR repositories:"
  echo "${repos}" | sed 's/^/  - /'

  # For each repository, ensure pull permissions are granted
  for repo in ${repos}; do
    log "Checking permissions for repository: ${repo}"

    # Get current policy
    local policy
    policy=$(aws ecr get-repository-policy --repository-name "${repo}" --region "${ecr_region}" 2>/dev/null | jq -r '.policyText' || echo "")

    if [[ -z "${policy}" ]]; then
      log "  No policy found, creating one to allow pull access..."

      # Create policy allowing pull from this account
      cat > "/tmp/ecr-policy-${repo//\//-}.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPull",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${current_account}:root"
      },
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ]
    }
  ]
}
EOF

      if aws ecr set-repository-policy \
        --repository-name "${repo}" \
        --region "${ecr_region}" \
        --policy-text "file:///tmp/ecr-policy-${repo//\//-}.json" &>/dev/null; then
        log "  ✓ Pull permissions granted for repository: ${repo}"
      else
        warn "  Could not set policy for repository: ${repo}"
      fi

      rm -f "/tmp/ecr-policy-${repo//\//-}.json"
    else
      log "  ✓ Repository policy already exists"
    fi
  done

  log "ECR repository permissions configured"
}

# ====== CREATE IMAGE PULL SECRETS FROM CONFIG ======
create_image_pull_secrets() {
  local ns="$1"
  ensure_namespace "${ns}"

  log "============================================"
  log "Creating Image Pull Secrets from Config"
  log "============================================"

  local secrets_created=()

  # 1. Create ECR secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_ECR_ENABLED}" == "true" ]]; then
    log "Creating ECR secret..."
    # Use ECR_REGION from config, fallback to REGION, then us-east-2
    local ecr_region="${ECR_REGION:-${REGION:-us-east-2}}"
    local ecr_account="${ECR_ACCOUNT:-}"
    log "  ECR Region: ${ecr_region}, ECR Account: ${ecr_account}"

    # Check if AWS credentials are available
    if ! aws sts get-caller-identity &>/dev/null; then
      warn "AWS credentials not available - skipping ECR secret creation"
    else
      # Auto-detect ECR account if not provided
      if [[ -z "${ecr_account}" ]]; then
        ecr_account=$(aws sts get-caller-identity --query Account --output text)
        log "Auto-detected ECR account: ${ecr_account}"
      fi

      # Get ECR authorization token
      local ecr_password
      if ecr_password=$(aws ecr get-login-password --region "${ecr_region}" 2>/dev/null); then
        # Create docker-registry secret
        kubectl create secret docker-registry ecr-registry-secret \
          --docker-server="${ecr_account}.dkr.ecr.${ecr_region}.amazonaws.com" \
          --docker-username=AWS \
          --docker-password="${ecr_password}" \
          --namespace="${ns}" \
          --dry-run=client -o yaml | kubectl apply -f -

        log "✓ ECR secret created: ecr-registry-secret"
        secrets_created+=("ecr-registry-secret")
      else
        warn "Failed to get ECR token - skipping ECR secret"
      fi
    fi
  fi

  # 2. Create Docker Hub secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED}" == "true" ]]; then
    log "Creating Docker Hub secret..."
    local dh_username=$(yq eval '.imagePullSecrets.dockerHub.username' "${CONFIG_FILE}" 2>/dev/null)
    local dh_password=$(yq eval '.imagePullSecrets.dockerHub.password' "${CONFIG_FILE}" 2>/dev/null)
    local dh_email=$(yq eval '.imagePullSecrets.dockerHub.email' "${CONFIG_FILE}" 2>/dev/null)

    if [[ -n "${dh_username}" && -n "${dh_password}" ]]; then
      local email_arg=""
      [[ -n "${dh_email}" ]] && email_arg="--docker-email=${dh_email}"

      kubectl create secret docker-registry docker-hub-secret \
        --docker-server=docker.io \
        --docker-username="${dh_username}" \
        --docker-password="${dh_password}" \
        ${email_arg} \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -

      log "✓ Docker Hub secret created: docker-hub-secret"
      secrets_created+=("docker-hub-secret")
    else
      warn "Docker Hub credentials not configured - skipping Docker Hub secret"
    fi
  fi

  # 3. Create GCR secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_GCR_ENABLED}" == "true" ]]; then
    log "Creating GCR secret..."
    local gcr_json_key=$(yq eval '.imagePullSecrets.gcr.jsonKey' "${CONFIG_FILE}" 2>/dev/null)

    if [[ -n "${gcr_json_key}" && "${gcr_json_key}" != "null" ]]; then
      kubectl create secret docker-registry gcr-secret \
        --docker-server=gcr.io \
        --docker-username=_json_key \
        --docker-password="${gcr_json_key}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -

      log "✓ GCR secret created: gcr-secret"
      secrets_created+=("gcr-secret")
    else
      warn "GCR JSON key not configured - skipping GCR secret"
    fi
  fi

  # 4. Create ACR secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_ACR_ENABLED}" == "true" ]]; then
    log "Creating ACR secret..."
    local acr_registry=$(yq eval '.imagePullSecrets.acr.registry' "${CONFIG_FILE}" 2>/dev/null)
    local acr_username=$(yq eval '.imagePullSecrets.acr.username' "${CONFIG_FILE}" 2>/dev/null)
    local acr_password=$(yq eval '.imagePullSecrets.acr.password' "${CONFIG_FILE}" 2>/dev/null)

    if [[ -n "${acr_registry}" && -n "${acr_username}" && -n "${acr_password}" ]]; then
      kubectl create secret docker-registry acr-secret \
        --docker-server="${acr_registry}" \
        --docker-username="${acr_username}" \
        --docker-password="${acr_password}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -

      log "✓ ACR secret created: acr-secret"
      secrets_created+=("acr-secret")
    else
      warn "ACR credentials not configured - skipping ACR secret"
    fi
  fi

  # 5. Create custom registry secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_CUSTOM_ENABLED}" == "true" ]]; then
    log "Creating custom registry secret..."
    local custom_name=$(yq eval '.imagePullSecrets.custom.name' "${CONFIG_FILE}" 2>/dev/null)
    local custom_server=$(yq eval '.imagePullSecrets.custom.server' "${CONFIG_FILE}" 2>/dev/null)
    local custom_username=$(yq eval '.imagePullSecrets.custom.username' "${CONFIG_FILE}" 2>/dev/null)
    local custom_password=$(yq eval '.imagePullSecrets.custom.password' "${CONFIG_FILE}" 2>/dev/null)
    local custom_email=$(yq eval '.imagePullSecrets.custom.email' "${CONFIG_FILE}" 2>/dev/null)

    if [[ -n "${custom_server}" && -n "${custom_username}" && -n "${custom_password}" ]]; then
      local email_arg=""
      [[ -n "${custom_email}" ]] && email_arg="--docker-email=${custom_email}"

      kubectl create secret docker-registry "${custom_name}" \
        --docker-server="${custom_server}" \
        --docker-username="${custom_username}" \
        --docker-password="${custom_password}" \
        ${email_arg} \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -

      log "✓ Custom registry secret created: ${custom_name}"
      secrets_created+=("${custom_name}")
    else
      warn "Custom registry credentials not configured - skipping custom secret"
    fi
  fi

  # Return created secrets as space-separated string
  if [[ ${#secrets_created[@]} -gt 0 ]]; then
    echo "${secrets_created[@]}"
  fi
}

# ====== CREATE ECR IMAGE PULL SECRET (Legacy - kept for compatibility) ======
create_ecr_secret() {
  local ns="$1"
  # Use ECR_REGION from config, fallback to REGION, then us-east-2
  local region="${ECR_REGION:-${REGION:-us-east-2}}"
  local ecr_account="${ECR_ACCOUNT:-}"

  ensure_namespace "${ns}"

  log "Creating ECR image pull secret in ${ns}..."

  # Check if AWS credentials are available
  if ! aws sts get-caller-identity &>/dev/null; then
    warn "=========================================="
    warn "AWS credentials not available!"
    warn "=========================================="
    warn "Skipping ECR secret creation."
    warn "If AI Platform uses private ECR images, pods will fail to pull images."
    warn ""
    warn "To fix:"
    warn "  1. Configure AWS credentials: aws configure"
    warn "  2. Ensure ECR repository permissions are granted (run setup_ecr_permissions.sh)"
    warn "  3. Re-run the installation"
    warn "=========================================="
    return 0
  fi

  # Auto-detect ECR account if not provided
  if [[ -z "${ecr_account}" ]]; then
    ecr_account=$(aws sts get-caller-identity --query Account --output text)
    log "Auto-detected ECR account: ${ecr_account}"
  fi

  log "Prerequisite: ECR repository permissions must be configured beforehand"
  log "  Run: ./setup_ecr_permissions.sh to set up ECR access"

  # Get ECR authorization token
  log "Getting ECR authorization token for region ${region}..."
  local ecr_password
  if ! ecr_password=$(aws ecr get-login-password --region "${region}" 2>/dev/null); then
    warn "Failed to get ECR token - skipping secret creation"
    warn "Check AWS credentials and permissions"
    return 0
  fi

  # Create docker-registry secret
  kubectl create secret docker-registry ecr-registry-secret \
    --docker-server="${ecr_account}.dkr.ecr.${region}.amazonaws.com" \
    --docker-username=AWS \
    --docker-password="${ecr_password}" \
    --namespace="${ns}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "✓ ECR secret created: ecr-registry-secret"
  log "✓ Secret will be referenced in AIPlatform CR spec.imagePullSecrets"
  log "Note: ECR tokens expire after 12 hours. Re-run installation to refresh."
}

# ====== INSTALL SPLUNK STANDALONE ======
install_splunk_standalone() {
  log "Installing Splunk Standalone: ${AI_STANDALONE_NAME} in ${AI_NS}..."

  ensure_namespace "${AI_NS}"
  wait_for_crd standalones.enterprise.splunk.com 600

  # Create credentials secret for Splunk App Framework
  if [[ "${MINIO_ENABLED}" == "true" ]]; then
    # MinIO mode: ensure minio-credentials secret exists (created by install_minio)
    log "Using MinIO credentials for Splunk App Framework..."
    if ! kubectl get secret minio-credentials -n "${AI_NS}" &>/dev/null; then
      log "Creating minio-credentials secret in ${AI_NS}..."
      kubectl -n "${AI_NS}" create secret generic minio-credentials \
        --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
        --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
        --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
        --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
        --from-literal=MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" \
        --from-literal=MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
        --dry-run=client -o yaml | kubectl -n "${AI_NS}" apply -f -
    fi
  else
    # S3 mode: create s3-secret with AWS credentials
    log "Creating S3-compatible secret for Splunk App Framework..."
    kubectl -n "${AI_NS}" create secret generic s3-secret \
      --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
      --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  # Create splunk-defaults ConfigMap (optional but recommended)
  cat <<'YAML' | kubectl -n "${AI_NS}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: splunk-defaults
data:
  default.yml: |
    splunk:
      conf:
        - key: authentication
          value:
            directory: /opt/splunk/etc/system/local
            content:
              oauth2_settings:
                issuer_uri: https://splunk-splunk-standalone-standalone-service:8089
                certFile: $SPLUNK_HOME/etc/auth/server.pem
                sslPassword: password
YAML

  # Ensure default ServiceAccount has imagePullSecrets for ECR
  if kubectl get secret ecr-registry-secret -n "${AI_NS}" &>/dev/null; then
    log "Patching default ServiceAccount with ecr-registry-secret..."
    kubectl patch serviceaccount default -n "${AI_NS}" \
      -p '{"imagePullSecrets": [{"name": "ecr-registry-secret"}]}' 2>/dev/null || \
      warn "Could not patch default ServiceAccount"
  fi

  # Create Splunk Standalone with App Framework
  # Standalone app repo: MinIO (S3-compatible) when minio.enabled=true, else S3
  if [[ "${MINIO_ENABLED}" == "true" ]]; then
    local minio_endpoint="${MINIO_ENDPOINT}"
    [[ -z "$minio_endpoint" ]] && minio_endpoint="http://minio.${MINIO_NS}.svc.cluster.local:9000"
    cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  replicas: 1
  etcVolumeStorageConfig:
    storageClassName: local-path
  varVolumeStorageConfig:
    storageClassName: local-path
  volumes:
    - name: defaults
      configMap:
        name: splunk-defaults
  defaultsUrl: /mnt/defaults/default.yml
  appRepo:
    appInstallPeriodSeconds: 90
    appSources:
      - name: apps
        scope: local
        location: apps
    appsRepoPollIntervalSeconds: 60
    defaults:
      scope: local
      volumeName: volume_app_repo
    installMaxRetries: 2
    volumes:
      - name: volume_app_repo
        provider: aws
        storageType: s3
        endpoint: ${minio_endpoint}
        path: ${MINIO_BUCKET}
        secretRef: minio-credentials
YAML
  else
    cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  replicas: 1
  etcVolumeStorageConfig:
    storageClassName: local-path
  varVolumeStorageConfig:
    storageClassName: local-path
  volumes:
    - name: defaults
      configMap:
        name: splunk-defaults
  defaultsUrl: /mnt/defaults/default.yml
  appRepo:
    appInstallPeriodSeconds: 90
    appSources:
      - name: apps
        scope: local
        location: apps
    appsRepoPollIntervalSeconds: 60
    defaults:
      scope: local
      volumeName: volume_app_repo
    installMaxRetries: 2
    volumes:
      - name: volume_app_repo
        provider: aws
        storageType: s3
        endpoint: http://minio.${MINIO_NS}.svc.cluster.local:9000
        region: us-east-1
        path: ${MINIO_BUCKET}
        secretRef: s3-secret
YAML
  fi

  log "Waiting for Splunk Standalone to be ready..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=${AI_STANDALONE_NAME} -n ${AI_NS} --timeout=600s || true

  log "Splunk Standalone installed successfully"
}

# ====== INSTALL AI PLATFORM CR ======
install_ai_platform_cr() {
  log "============================================"
  log "Creating AIPlatform Custom Resource"
  log "============================================"

  # Clean up any failed jobs/pods from previous runs (they may have wrong image references)
  # Use --wait=false to avoid hanging on deletions
  log "Cleaning up failed jobs and ImagePullBackOff pods from previous runs..."
  kubectl delete jobs -n "${AI_NS}" --field-selector status.successful=0 --wait=false 2>/dev/null || true
  kubectl delete pods -n "${AI_NS}" --field-selector status.phase=Failed --wait=false 2>/dev/null || true
  # Delete pods stuck in ImagePullBackOff or ErrImagePull (use jq to avoid bash 3.x jsonpath parsing issues)
  kubectl get pods -n "${AI_NS}" -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.containerStatuses[]? | .state.waiting?.reason? == "ImagePullBackOff") | .metadata.name' 2>/dev/null | \
    xargs -r -I {} kubectl delete pod {} -n "${AI_NS}" --wait=false --grace-period=0 --force 2>/dev/null || true
  kubectl get pods -n "${AI_NS}" -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.containerStatuses[]? | .state.waiting?.reason? == "ErrImagePull") | .metadata.name' 2>/dev/null | \
    xargs -r -I {} kubectl delete pod {} -n "${AI_NS}" --wait=false --grace-period=0 --force 2>/dev/null || true
  log "✓ Cleanup complete"

  # Get Splunk secret name (for HEC endpoint)
  local splunk_secret="splunk-${AI_STANDALONE_NAME}-standalone-secret-v1"
  log "Using Splunk secret: ${splunk_secret}"

  # Ensure object storage credentials secret exists in AI namespace
  if [[ "${MINIO_ENABLED}" == "true" ]]; then
    log "Creating/updating MinIO credentials secret (minio-credentials) in ${AI_NS}..."
    kubectl -n "${AI_NS}" create secret generic minio-credentials \
      --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
      --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
      --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
      --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
      --from-literal=MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" \
      --from-literal=MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
      --dry-run=client -o yaml | kubectl -n "${AI_NS}" apply -f -
    log "✓ MinIO credentials secret ready"
  else
    log "Creating/updating S3 credentials secret (s3-secret) in ${AI_NS}..."
    kubectl -n "${AI_NS}" create secret generic s3-secret \
      --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
      --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
      --dry-run=client -o yaml | kubectl apply -f -
    log "✓ S3 credentials secret ready"
  fi

  # Build imagePullSecrets YAML from created secrets
  local image_pull_secrets=""
  local secrets_yaml=""

  # Check for all possible secrets and add to YAML if they exist
  for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
    if kubectl get secret "${secret_name}" -n "${AI_NS}" &>/dev/null 2>&1; then
      secrets_yaml+="      - name: ${secret_name}"$'\n'
    fi
  done

  if [[ -n "${secrets_yaml}" ]]; then
    log "ImagePullSecrets found, adding to AIPlatform CR"
    image_pull_secrets=$(cat <<EOF
    imagePullSecrets:
${secrets_yaml}
EOF
)
  else
    log "No imagePullSecrets found, using public images only"
  fi

  # objectStorage: use MinIO when enabled (in-cluster or external), otherwise S3
  local obj_path obj_endpoint obj_secret
  if [[ "${MINIO_ENABLED}" == "true" ]]; then
    obj_path="minio://${MINIO_BUCKET}"
    if [[ "${MINIO_EXTERNAL}" == "true" && -n "${MINIO_ENDPOINT}" ]]; then
      obj_endpoint="${MINIO_ENDPOINT}"
    else
      obj_endpoint="http://minio.${MINIO_NS}.svc.cluster.local:9000"
    fi
    obj_secret="minio-credentials"
  else
    obj_path="s3://${MINIO_BUCKET}"
    obj_endpoint="http://minio.${MINIO_NS}.svc.cluster.local:9000"
    obj_secret="s3-secret"
  fi

  # Apply AIPlatform CR (matching EKS script pattern)
  log "Applying AIPlatform CR: ${CLUSTER_NAME}-ai-platform"
  cat <<YAML | kubectl -n "${AI_NS}" apply --server-side --force-conflicts -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${CLUSTER_NAME}-ai-platform
spec:
  objectStorage:
    path: ${obj_path}
    region: us-east-1
    endpoint: ${obj_endpoint}
    secretRef: ${obj_secret}

  # Image configuration (including pull secrets for private registries)
  images:
${image_pull_secrets}

  # GPU accelerator type (determines Ray worker tiers: L40S, H100_NVL, or empty for no workers)
  defaultAcceleratorType: ${DEFAULT_ACCELERATOR}

  # Features configuration
  features:
    - name: saia
      version: "1.1.0"

  # Storage configuration
  storage:
    vectorDB:
      size: ${VECTORDB_SIZE}
      storageClassName: ${STORAGE_CLASS}

  # Worker configuration
  workerGroupConfig:
    imageRegistry: "${WORKER_IMAGE_REGISTRY}"

  # CPU scheduler
  cpuScheduler:
    nodeSelector:
      splunk.ai/workload-type: cpu
    tolerations: []

  # GPU scheduler
  gpuScheduler:
    nodeSelector:
      splunk.ai/workload-type: gpu
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"

  # Splunk configuration
  splunkConfiguration:
    endpoint: http://${AI_STANDALONE_NAME}-standalone-service.${AI_NS}.svc.cluster.local:8089
    secretRef:
      name: ${splunk_secret}
      namespace: ${AI_NS}
YAML

  log "AIPlatform CR created successfully"
  log "Waiting for AIPlatform to be ready..."

  # Wait for AIPlatform resource to exist
  local timeout=60 elapsed=0
  while ! kubectl get aiplatform ${CLUSTER_NAME}-ai-platform -n ${AI_NS} >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      warn "Timeout waiting for AIPlatform resource to be created"
      break
    fi
  done

  # Show AIPlatform status
  log "AIPlatform status:"
  kubectl get aiplatform ${CLUSTER_NAME}-ai-platform -n ${AI_NS} -o wide || true

  log "AIPlatform CR installed successfully"
}

# ====== INSTALL FULL STACK ======
install_ai_platform_stack() {
  log "Installing complete AI Platform stack..."

  # ensure_namespace "${AI_NS}"

  # # Install infrastructure components
  # install_minio
  # install_cert_manager
  # install_kube_prometheus
  # install_otel_operator_and_contrib_collector
  # mount_nvme_instance_store         # Step 0: Mount NVMe instance store for ephemeral storage on GPU workers
  # install_nvidia_host_drivers       # Step 1: Install drivers on GPU hosts via SSH (bare-metal only)
  # install_nvidia_device_plugin      # Step 2: Deploy device plugin DaemonSet (same as EKS)
  # install_ray_operator

  # Install Splunk components
  install_splunk_operator

  # Create image pull secrets before Splunk Standalone (it uses the default SA which needs ECR creds)
  create_image_pull_secrets "${AI_NS}"

  install_splunk_standalone

  # Install AI Platform operator
  install_splunk_ai_operator

  # Install AI Platform CR
  install_ai_platform_cr

  log "AI Platform stack installation complete!"
}

# ====== ADVANCED HEALTH CHECKS ======
check_platform_health() {
  log "============================================"
  log "🏥 Running Platform Health Checks..."
  log "============================================"
  log ""

  local health_issues=0

  # Check 1: Cluster nodes
  log "Checking cluster nodes..."
  local not_ready
  not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " | wc -l || echo "0")
  if [[ "${not_ready}" -gt 0 ]]; then
    warn "Found ${not_ready} node(s) not in Ready state"
    kubectl get nodes
    ((health_issues++))
  else
    log "✅ All nodes are Ready"
  fi
  log ""

  # Check 2: Storage class
  log "Checking storage class..."
  if kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
    log "✅ Default storage class configured"
  else
    warn "No default storage class found"
    kubectl get storageclass
    ((health_issues++))
  fi
  log ""

  # Check 3: MinIO
  log "Checking MinIO..."
  if [[ "${MINIO_ENABLED}" != "true" ]]; then
    log "⏭️  MinIO disabled; skipping check"
  elif [[ "${MINIO_EXTERNAL}" == "true" ]]; then
    log "⏭️  External MinIO; skipping in-cluster check"
  elif kubectl get pod -n "${MINIO_NS}" -l app=minio 2>/dev/null | grep -q "Running"; then
    log "✅ MinIO is running"
  else
    warn "MinIO pod not in Running state"
    kubectl get pods -n "${MINIO_NS}"
    ((health_issues++))
  fi
  log ""

  # Check 4: cert-manager
  log "Checking cert-manager..."
  local cert_manager_ready
  cert_manager_ready=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [[ "${cert_manager_ready}" -ge 3 ]]; then
    log "✅ cert-manager is running (${cert_manager_ready} pods)"
  else
    warn "cert-manager not fully ready (${cert_manager_ready}/3 pods)"
    kubectl get pods -n cert-manager
    ((health_issues++))
  fi
  log ""

  # Check 5: Prometheus stack
  log "Checking kube-prometheus-stack..."
  if kubectl get pods -n monitoring 2>/dev/null | grep -q "Running"; then
    local prom_pods
    prom_pods=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    log "✅ Prometheus stack is running (${prom_pods} pods)"
  else
    warn "Prometheus stack not fully ready"
    kubectl get pods -n monitoring
    ((health_issues++))
  fi
  log ""

  # Check 6: OpenTelemetry Operator
  log "Checking OpenTelemetry Operator..."
  if kubectl get pods -n opentelemetry-operator-system 2>/dev/null | grep -q "Running"; then
    log "✅ OpenTelemetry Operator is running"
  else
    warn "OpenTelemetry Operator not ready"
    kubectl get pods -n opentelemetry-operator-system
    ((health_issues++))
  fi
  log ""

  # Check 7: Ray Operator
  log "Checking KubeRay Operator..."
  if kubectl get pods -n ray-system 2>/dev/null | grep -q "Running"; then
    log "✅ KubeRay Operator is running"
  else
    warn "KubeRay Operator not ready"
    kubectl get pods -n ray-system
    ((health_issues++))
  fi
  log ""

  # Check 8: Splunk AI Operator
  log "Checking Splunk AI Operator..."
  if kubectl get pods -n splunk-ai-operator-system 2>/dev/null | grep -q "Running"; then
    log "✅ Splunk AI Operator is running"
  else
    warn "Splunk AI Operator not ready"
    kubectl get pods -n splunk-ai-operator-system
    ((health_issues++))
  fi
  log ""

  # Check 9: AI Platform namespace
  log "Checking AI Platform namespace (${AI_NS})..."
  if kubectl get namespace "${AI_NS}" >/dev/null 2>&1; then
    local ai_pods
    ai_pods=$(kubectl get pods -n "${AI_NS}" --no-headers 2>/dev/null | wc -l || echo "0")
    log "✅ AI Platform namespace exists (${ai_pods} pods)"
    if [[ "${ai_pods}" -gt 0 ]]; then
      kubectl get pods -n "${AI_NS}"
    fi
  else
    warn "AI Platform namespace not found"
    ((health_issues++))
  fi
  log ""

  # Check 10: AIPlatform CRDs
  log "Checking AI Platform CRDs..."
  if kubectl get crd aiplatforms.ai.splunk.com >/dev/null 2>&1; then
    log "✅ AIPlatform CRD installed"
  else
    warn "AIPlatform CRD not found"
    ((health_issues++))
  fi
  if kubectl get crd aiservices.ai.splunk.com >/dev/null 2>&1; then
    log "✅ AIService CRD installed"
  else
    warn "AIService CRD not found"
    ((health_issues++))
  fi
  log ""

  # Summary
  log "============================================"
  if [[ "${health_issues}" -eq 0 ]]; then
    log "✅ Health Check Summary: All systems operational!"
  else
    warn "⚠️  Health Check Summary: Found ${health_issues} issue(s)"
    warn "Some components may still be starting up. Check logs for details."
  fi
  log "============================================"
  log ""

  return "${health_issues}"
}

# ====== SHOW PLATFORM ACCESS INFORMATION ======
show_platform_access_info() {
  log "============================================"
  log "🎉 Installation Complete!"
  log "============================================"
  log ""

  log "📋 Cluster Information:"
  log "  Cluster Name: ${CLUSTER_NAME}"
  log "  Namespace: ${AI_NS}"
  log "  Kubeconfig: ${HOME}/.kube/k0s-${CLUSTER_NAME}"
  log ""
  log "  💡 Set kubeconfig:"
  log "     export KUBECONFIG=${HOME}/.kube/k0s-${CLUSTER_NAME}"
  log ""

  # Show node information
  log "📦 Cluster Nodes:"
  kubectl get nodes -o wide 2>/dev/null || warn "Could not retrieve node information"
  log ""

  # MinIO information
  log "🗄️  MinIO (Object Storage):"
  log "  Console URL: http://localhost:9001"
  log "  API URL: http://localhost:9000"
  log "  "
  log "  💡 Access MinIO Console:"
  log "     kubectl port-forward svc/minio -n ${MINIO_NS} 9001:9001"
  log "     Open: http://localhost:9001"
  log "  "
  log "  🔑 Credentials:"
  log "     Username: ${MINIO_ROOT_USER}"
  log "     Password: ${MINIO_ROOT_PASSWORD}"
  log ""

  # AI Platform information
  log "🤖 AI Platform:"
  log "  Check Status:"
  log "     kubectl get aiplatform -n ${AI_NS}"
  log "     kubectl describe aiplatform -n ${AI_NS}"
  log "  "
  log "  Check AIServices:"
  log "     kubectl get aiservice -n ${AI_NS}"
  log ""

  # Splunk information
  log "📊 Splunk Enterprise:"
  log "  Check Status:"
  log "     kubectl get standalone -n ${AI_NS}"
  log "     kubectl get pods -n ${AI_NS} -l app.kubernetes.io/instance=splunk-standalone"
  log "  "
  log "  💡 Access Splunk Web (once ready):"
  log "     kubectl port-forward -n ${AI_NS} svc/splunk-standalone-standalone-service 8000:8000"
  log "     Open: http://localhost:8000"
  log ""

  # Monitoring information
  log "📈 Monitoring & Observability:"
  log "  Prometheus:"
  log "     kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
  log "     Open: http://localhost:9090"
  log "  "
  log "  Grafana:"
  log "     kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
  log "     Open: http://localhost:3000"
  log "     Username: admin"
  log "     Password: (run) kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
  log ""

  # Ray information
  log "🚀 Ray Clusters:"
  log "  Check Ray Services:"
  log "     kubectl get rayservice -n ${AI_NS}"
  log "     kubectl get raycluster -n ${AI_NS}"
  log "  "
  log "  Ray Dashboard (once Ray is running):"
  log "     kubectl port-forward -n ${AI_NS} svc/<ray-head-svc> 8265:8265"
  log "     Open: http://localhost:8265"
  log ""

  # Quick checks
  log "🔍 Quick Health Checks:"
  log "  All Pods:"
  log "     kubectl get pods -A"
  log "  "
  log "  AI Platform Pods:"
  log "     kubectl get pods -n ${AI_NS}"
  log "  "
  log "  System Pods:"
  log "     kubectl get pods -n kube-system"
  log ""

  # Troubleshooting
  log "🛠️  Troubleshooting:"
  log "  View Operator Logs:"
  log "     kubectl logs -n splunk-ai-operator-system -l control-plane=controller-manager -f"
  log "  "
  log "  View AI Platform Events:"
  log "     kubectl get events -n ${AI_NS} --sort-by='.lastTimestamp'"
  log "  "
  log "  Describe Resources:"
  log "     kubectl describe aiplatform -n ${AI_NS}"
  log "     kubectl describe aiservice -n ${AI_NS}"
  log ""

  log "============================================"
  log "📚 Documentation:"
  log "  Setup Guide: ./tools/cluster_setup/README.md"
  log "  Custom Resources: ./docs/CustomResources.md"
  log "  Troubleshooting: Check operator logs and events above"
  log "============================================"
  log ""
  log "✅ Your AI Platform is ready to use!"
  log ""
}

# ====== MAIN INSTALL FLOW ======
main_install() {
  load_config
  preflight_checks

  # Check if existing Kubernetes cluster should be used
  local use_existing_cluster=false

  # Respect the useExisting config setting
  if [[ "${USE_EXISTING}" == "never" ]]; then
    log "Config setting 'useExisting=never' - will always create new k0s cluster"
  else
    log "Checking for existing Kubernetes cluster (useExisting=${USE_EXISTING})..."

    # Option 1: Check if KUBECONFIG is set and points to an accessible cluster
    if [[ "${USE_EXISTING}" == "auto" || "${USE_EXISTING}" == "force" ]] && [[ -n "${KUBECONFIG:-}" ]] && timeout 5 kubectl cluster-info &>/dev/null; then

      # Verify the cluster name matches or contains our cluster name
      local current_context
      current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")

      log "Found accessible cluster with context: ${current_context}"

      # Check if context name contains our cluster name (case-insensitive)
      if [[ "${current_context}" == *"${CLUSTER_NAME}"* ]] || [[ "${USE_EXISTING}" == "force" ]]; then
        log "============================================"
        log "✓ Existing Kubernetes cluster detected via KUBECONFIG!"
        log "============================================"
        log "Cluster context: ${current_context}"
        log "Configured cluster name: ${CLUSTER_NAME}"
        log ""
        log "Cluster info:"
        kubectl cluster-info 2>/dev/null | head -5 || true
        log ""
        log "Nodes:"
        kubectl get nodes || true
        log ""
        log "Skipping k0s installation, will use existing cluster"
        use_existing_cluster=true
      else
        warn "Found cluster with context '${current_context}' but it doesn't match configured name '${CLUSTER_NAME}'"
        warn "Set useExisting=force in config to use it anyway, or set KUBECONFIG to the correct cluster"
        if [[ "${USE_EXISTING}" == "force" ]]; then
          err "useExisting=force but cluster name mismatch - aborting for safety"
        fi
      fi

    # Option 2: Check if k0s is already running on provided nodes
    elif [[ "${USE_EXISTING}" == "auto" || "${USE_EXISTING}" == "force" ]] && [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
      IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
      local controller_ip="${CONTROLLER_IPS[0]}"

      log "Checking if k0s is already installed on ${controller_ip}..."
      if ssh_exec "${controller_ip}" "command -v k0s >/dev/null 2>&1 && sudo k0s status >/dev/null 2>&1"; then
        log "============================================"
        log "✓ k0s cluster already running on provided nodes!"
        log "============================================"
        log "Retrieving kubeconfig from existing k0s cluster..."
        mkdir -p "${HOME}/.kube"
        ssh_exec "${controller_ip}" "sudo cat /var/lib/k0s/pki/admin.conf" > "${HOME}/.kube/k0s-${CLUSTER_NAME}"
        sed -i.bak "s|server: .*|server: https://${controller_ip}:6443|" "${HOME}/.kube/k0s-${CLUSTER_NAME}"
        export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"
        log "Cluster nodes:"
        kubectl get nodes || true
        log ""
        log "Skipping k0s installation, using existing cluster"
        use_existing_cluster=true

        # Prepare all nodes for OS compatibility (iptables, firewalld, etc.)
        local all_node_ips=("${CONTROLLER_IPS[@]}")
        if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
          IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
          all_node_ips+=("${WORKER_IPS[@]}")
        fi
        prepare_nodes_for_k0s "${all_node_ips[@]}"

        # Ensure all expected workers are joined
        if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
          local current_node_count
          current_node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
          local expected_total=$(( ${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]} ))
          if [[ "${current_node_count}" -lt "${expected_total}" ]]; then
            log "Cluster has ${current_node_count} nodes but ${expected_total} expected — joining missing workers..."
            join_workers
          fi
        fi
      elif [[ "${USE_EXISTING}" == "force" ]]; then
        err "useExisting=force but no k0s cluster found on provided nodes"
      fi
    fi

    # If force mode and no cluster found, error out
    if [[ "${USE_EXISTING}" == "force" ]] && [[ "${use_existing_cluster}" == "false" ]]; then
      err "useExisting=force but no existing cluster found - aborting"
    fi
  fi

  # Install k0s if no existing cluster found
  if [[ "${use_existing_cluster}" == "false" ]]; then
    log "No existing cluster found, starting k0s cluster installation..."

    # Setup infrastructure
    if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
      log "Using existing infrastructure..."
    else
      log "Creating EC2 instances..."
      create_ec2_instances
    fi

    # After getting IPs (from config or EC2), check if k0s is already installed
    # Parse IPs if from config
    if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
      IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
    fi

    # Check if k0s is already running on the controller node
    if [[ "${#CONTROLLER_IPS[@]}" -gt 0 ]]; then
      local controller_ip="${CONTROLLER_IPS[0]}"
      log "Checking if k0s is already installed on ${controller_ip}..."

      if ssh_exec "${controller_ip}" "command -v k0s >/dev/null 2>&1 && sudo k0s status >/dev/null 2>&1"; then
        log "============================================"
        log "✓ k0s cluster already running on EC2 instances!"
        log "============================================"
        log "Retrieving kubeconfig from existing k0s cluster..."
        mkdir -p "${HOME}/.kube"
        ssh_exec "${controller_ip}" "sudo cat /var/lib/k0s/pki/admin.conf" > "${HOME}/.kube/k0s-${CLUSTER_NAME}"
        sed -i.bak "s|server: .*|server: https://${controller_ip}:6443|" "${HOME}/.kube/k0s-${CLUSTER_NAME}"
        export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"
        log "Cluster nodes:"
        kubectl get nodes || true
        log ""
        log "Skipping k0s installation, using existing cluster"
        use_existing_cluster=true

        # Prepare all nodes for OS compatibility (iptables, firewalld, etc.)
        local all_node_ips2=("${CONTROLLER_IPS[@]}")
        if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
          IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
          all_node_ips2+=("${WORKER_IPS[@]}")
        fi
        prepare_nodes_for_k0s "${all_node_ips2[@]}"

        # Ensure all expected workers are joined
        if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
          local current_node_count
          current_node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
          local expected_total=$(( ${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]} ))
          if [[ "${current_node_count}" -lt "${expected_total}" ]]; then
            log "Cluster has ${current_node_count} nodes but ${expected_total} expected — joining missing workers..."
            join_workers
          fi
        fi
      fi
    fi

    # Install k0s cluster only if not already installed
    if [[ "${use_existing_cluster}" == "false" ]]; then
      install_k0s_cluster
    fi
  else
    log ""
    log "⚠️  Using existing cluster - please ensure:"
    log "  ✓ Storage class is configured (for MinIO and persistent volumes)"
    log "  ✓ At least 1 node with available CPU/memory resources"
    log "  ✓ GPU nodes labeled with 'nvidia.com/gpu=true' (if running GPU workloads)"
    log "  ✓ If using on-prem/private cluster, ensure ports 6443, 8080, 30000-32767 are accessible"
    log ""
  fi

  # Install AI Platform stack
  install_ai_platform_stack

  # Run health checks
  check_platform_health || warn "Some components may still be initializing"

  # Show platform access information
  show_platform_access_info
}

# ====== MAIN DELETE FLOW ======
main_delete() {
  load_config

  log "============================================"
  log "Starting cleanup of k0s cluster: ${CLUSTER_NAME}"
  log "============================================"

  # For EC2 mode: Just delete AWS resources (instances, security groups)
  # Kubernetes resources will be destroyed when instances are terminated
  # This is much faster and avoids stuck namespace deletion issues

  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    # On-prem mode: Need to clean Kubernetes resources gracefully
    log "On-prem mode detected - performing graceful Kubernetes cleanup..."

    export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"

    if [[ -f "${KUBECONFIG}" ]] && timeout 10 kubectl cluster-info &>/dev/null; then
      log "Deleting Kubernetes resources..."
      kubectl delete aiplatform --all -n "${AI_NS}" --timeout=60s || true
      kubectl delete namespace "${AI_NS}" --timeout=120s || true
      kubectl delete namespace splunk-ai-operator-system --timeout=60s || true
      kubectl delete namespace monitoring --timeout=60s || true
    fi
    # On-prem: Stop k0s on existing infrastructure
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
    IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"

    log "Stopping k0s on controller nodes..."
    for ip in "${CONTROLLER_IPS[@]}"; do
      log "  Stopping k0s on controller: ${ip}..."
      ssh_exec "${ip}" "sudo k0s stop || true; sudo k0s reset --force || true" || warn "Failed to stop k0s on ${ip}"
    done

    log "Stopping k0s on worker nodes..."
    for ip in "${WORKER_IPS[@]}"; do
      log "  Stopping k0s on worker: ${ip}..."
      ssh_exec "${ip}" "sudo k0s stop || true; sudo k0s reset --force || true" || warn "Failed to stop k0s on ${ip}"
    done

    log "k0s stopped on all on-prem nodes"
    log "NOTE: Node machines are still running. To clean up completely:"
    log "  - Remove k0s binaries: sudo rm -f /usr/local/bin/k0s"
    log "  - Clean up data: sudo rm -rf /var/lib/k0s /etc/k0s"

  else
    # EC2: Terminate instances
    log "============================================"
    log "Scanning for resources to delete..."
    log "============================================"

    # First, preview what will be deleted
    local instance_ids instance_count=0
    instance_ids=$(aws ec2 describe-instances \
      --region "${REGION}" \
      --filters \
        "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
        "Name=tag:ManagedBy,Values=k0s-script" \
        "Name=instance-state-name,Values=running,stopped,stopping" \
      --query 'Reservations[].Instances[].InstanceId' --output text)

    if [[ -n "${instance_ids}" ]]; then
      instance_count=$(echo "${instance_ids}" | wc -w)
      log "EC2 Instances to terminate: ${instance_count}"
      # Show instance details
      aws ec2 describe-instances --region "${REGION}" --instance-ids ${instance_ids} \
        --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],InstanceType,State.Name]' \
        --output table 2>/dev/null || echo "  ${instance_ids}"
    else
      log "EC2 Instances: None found"
    fi

    # Check other resources
    local enis=$(aws ec2 describe-network-interfaces --region "${REGION}" \
      --filters "Name=tag:Cluster,Values=${CLUSTER_NAME}" "Name=tag:ManagedBy,Values=k0s-script" \
      --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null || echo "")
    local eni_count=$(echo "${enis}" | wc -w)
    log "Network Interfaces: ${eni_count:-0}"

    local sg_id=$(aws ec2 describe-security-groups --region "${REGION}" \
      --filters "Name=group-name,Values=${CLUSTER_NAME}-k0s-sg" "Name=tag:ManagedBy,Values=k0s-script" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
    if [[ -n "${sg_id}" && "${sg_id}" != "None" ]]; then
      log "Security Groups: 1 (${sg_id})"
    else
      log "Security Groups: 0"
    fi

    local volumes=$(aws ec2 describe-volumes --region "${REGION}" \
      --filters "Name=tag:Cluster,Values=${CLUSTER_NAME}" "Name=tag:ManagedBy,Values=k0s-script" "Name=status,Values=available" \
      --query 'Volumes[].VolumeId' --output text 2>/dev/null || echo "")
    local vol_count=$(echo "${volumes}" | wc -w)
    log "EBS Volumes: ${vol_count:-0}"

    log ""
    log "All resources are tagged with:"
    log "  - Cluster: ${CLUSTER_NAME}"
    log "  - ManagedBy: k0s-script"
    log ""

    # Confirmation prompt (skip if AUTO_APPROVE is set)
    if [[ "${AUTO_APPROVE:-false}" != "true" ]]; then
      warn "This will permanently delete the above AWS resources!"
      read -p "Type 'yes' to confirm deletion: " -r
      if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
        log "Deletion cancelled by user"
        exit 0
      fi
    fi

    log ""
    log "============================================"
    log "Starting resource deletion..."
    log "============================================"
    log ""

    # Now proceed with deletion
    if [[ -n "${instance_ids}" ]]; then
      log "Terminating ${instance_count} EC2 instance(s)..."
      aws ec2 terminate-instances --region "${REGION}" --instance-ids ${instance_ids}

      log "Waiting for instances to terminate..."
      aws ec2 wait instance-terminated --region "${REGION}" --instance-ids ${instance_ids} || warn "Timeout waiting for instances to terminate"

      log "EC2 instances terminated successfully"
    else
      log "No EC2 instances to terminate"
    fi

    # Clean up network interfaces that may be stuck
    log "Checking for orphaned network interfaces..."
    local enis eni_count=0
    enis=$(aws ec2 describe-network-interfaces \
      --region "${REGION}" \
      --filters \
        "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
        "Name=tag:ManagedBy,Values=k0s-script" \
      --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null || echo "")

    if [[ -n "${enis}" ]]; then
      eni_count=$(echo "${enis}" | wc -w)
      log "Found ${eni_count} orphaned network interface(s), deleting..."
      for eni in ${enis}; do
        log "  Deleting network interface: ${eni}"
        aws ec2 delete-network-interface --region "${REGION}" --network-interface-id "${eni}" 2>/dev/null || warn "Could not delete ENI ${eni}"
      done
    else
      log "No orphaned network interfaces found"
    fi

    # Delete security group (with retries for ENI detachment)
    log "Deleting security group..."
    local sg_id sg_deleted=false
    sg_id=$(aws ec2 describe-security-groups \
      --region "${REGION}" \
      --filters \
        "Name=group-name,Values=${CLUSTER_NAME}-k0s-sg" \
        "Name=tag:ManagedBy,Values=k0s-script" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

    if [[ -n "${sg_id}" && "${sg_id}" != "None" ]]; then
      log "Found security group: ${sg_id}"

      # Try multiple times with increasing wait periods
      for attempt in 1 2 3 4 5; do
        log "  Attempt ${attempt}/5 to delete security group..."
        if aws ec2 delete-security-group --region "${REGION}" --group-id "${sg_id}" 2>/dev/null; then
          log "Security group deleted successfully"
          sg_deleted=true
          break
        else
          if [[ ${attempt} -lt 5 ]]; then
            local wait_time=$((attempt * 15))
            log "  Security group still has dependencies, waiting ${wait_time}s for ENIs to detach..."
            sleep ${wait_time}
          fi
        fi
      done

      if [[ "${sg_deleted}" == "false" ]]; then
        warn "Could not delete security group after 5 attempts (may have dependencies)"
        warn "AWS will auto-clean it when dependencies are removed"
      fi
    else
      log "Security group not found or already deleted"
    fi

    # Delete any EBS volumes that were created
    log "Checking for orphaned EBS volumes..."
    local volumes vol_count=0
    volumes=$(aws ec2 describe-volumes \
      --region "${REGION}" \
      --filters \
        "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
        "Name=tag:ManagedBy,Values=k0s-script" \
        "Name=status,Values=available" \
      --query 'Volumes[].VolumeId' --output text)

    if [[ -n "${volumes}" ]]; then
      vol_count=$(echo "${volumes}" | wc -w)
      log "Found ${vol_count} orphaned EBS volume(s), deleting..."
      for vol in ${volumes}; do
        log "  Deleting volume: ${vol}"
        aws ec2 delete-volume --region "${REGION}" --volume-id "${vol}" && log "    Volume ${vol} deleted" || warn "    Could not delete volume ${vol}"
      done
    else
      log "No orphaned EBS volumes found"
    fi
  fi

  # Clean up local files
  log "Cleaning up local files..."
  local kubeconfig_count=0
  for kc in "${HOME}/.kube/k0s-${CLUSTER_NAME}" "${HOME}/.kube/k0s-${CLUSTER_NAME}.bak"; do
    if [[ -f "${kc}" ]]; then
      rm -f "${kc}"
      ((kubeconfig_count++))
    fi
  done
  rm -rf "/tmp/splunk-ai-operator" || true

  log "============================================"
  log "Cleanup Summary"
  log "============================================"

  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    log "Infrastructure: On-premises"
    log "  - k0s stopped and reset on all nodes"
    log "  - NOTE: Nodes are still running, k0s binaries remain"
  else
    log "Infrastructure: AWS EC2"
    log "  - EC2 Instances: ${instance_count:-0} terminated"
    log "  - Network Interfaces: ${eni_count:-0} cleaned up"
    log "  - Security Groups: $([ "${sg_deleted}" == "true" ] && echo "1 deleted" || echo "pending cleanup")"
    log "  - EBS Volumes: ${vol_count:-0} deleted"
  fi

  log ""
  log "Kubernetes Resources:"
  log "  - AI Platform resources deleted"
  log "  - Splunk Standalone deleted"
  log "  - Ray services/clusters deleted"
  log "  - All operators uninstalled"
  log "  - All namespaces deleted"
  log ""
  log "Local Files:"
  log "  - Kubeconfig files: ${kubeconfig_count} cleaned up"

  log ""
  log "============================================"
  log "Cleanup complete!"
  log "============================================"
  log ""
  log "Cluster '${CLUSTER_NAME}' has been deleted."

  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    log ""
    log "On-prem nodes are still running with k0s stopped."
    log "To fully clean up each node, run:"
    log "  sudo rm -f /usr/local/bin/k0s"
    log "  sudo rm -rf /var/lib/k0s /etc/k0s"
  else
    # Check if any resources failed to delete
    if [[ "${sg_deleted}" == "false" ]]; then
      log ""
      warn "Some resources may require manual cleanup:"
      warn "  - Security group ${sg_id} may have lingering dependencies"
      warn "  - Check AWS console for any remaining resources tagged with Cluster=${CLUSTER_NAME}"
    fi
  fi
}

# ====== CLEAN ALL (AGGRESSIVE CLEANUP) ======
clean_all() {
  log "============================================"
  log "AGGRESSIVE CLEANUP MODE"
  log "============================================"
  warn "This will forcefully remove all resources and data!"

  load_config

  # Run normal delete first
  main_delete

  # Additional aggressive cleanup for on-prem
  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
    IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"

    log "Performing aggressive cleanup on nodes..."
    for ip in "${CONTROLLER_IPS[@]}" "${WORKER_IPS[@]}"; do
      log "  Deep cleaning node: ${ip}..."
      ssh_exec "${ip}" "
        sudo systemctl stop k0scontroller k0sworker || true
        sudo systemctl disable k0scontroller k0sworker || true
        sudo rm -rf /var/lib/k0s /etc/k0s
        sudo rm -f /usr/local/bin/k0s
        sudo rm -rf /var/lib/kubelet /etc/cni /opt/cni
        sudo rm -rf /var/lib/calico /etc/calico
        sudo iptables -F || true
        sudo iptables -X || true
        sudo iptables -t nat -F || true
        sudo iptables -t nat -X || true
        sudo iptables -t mangle -F || true
        sudo iptables -t mangle -X || true
      " || warn "Failed aggressive cleanup on ${ip}"
    done
  fi

  log "Aggressive cleanup complete!"
}

# ====== USAGE ======
usage() {
  cat <<EOF
Usage: $0 [install|delete|clean-all|join-workers]

Deploys Splunk AI Platform on k0s cluster (on-prem or EC2)

Commands:
  install       - Install k0s cluster and AI Platform stack
  join-workers  - Join/rejoin worker nodes to existing cluster (resume after failure)
  delete        - Delete cluster and all resources (graceful)
  clean-all     - Aggressive cleanup including node-level cleanup (on-prem)

Environment:
  CONFIG_FILE  - Path to k0s config YAML (default: ./k0s-cluster-config.yaml)
  AUTO_APPROVE - Skip confirmation prompt for delete (default: false)

Examples:
  # On-prem with existing IPs
  CONFIG_FILE=./on-prem-config.yaml $0 install

  # EC2 simulation
  CONFIG_FILE=./ec2-config.yaml $0 install

  # Join worker nodes (if install failed or was interrupted)
  CONFIG_FILE=./ec2-config.yaml $0 join-workers

  # Delete cluster (with confirmation prompt)
  CONFIG_FILE=./config.yaml $0 delete

  # Delete cluster (auto-approve, no prompt)
  AUTO_APPROVE=true CONFIG_FILE=./config.yaml $0 delete

  # Deep cleanup (aggressive, on-prem only)
  CONFIG_FILE=./config.yaml $0 clean-all

Notes:
  - 'install' performs full cluster setup including worker joins
  - 'join-workers' is useful for:
    * Resuming after installation was interrupted
    * Retrying failed worker joins
    * Adding workers to existing cluster
    * Fixing missing node labels
  - 'delete' performs comprehensive cleanup:
    * Shows preview of all resources to be deleted
    * Requires confirmation (type 'yes') unless AUTO_APPROVE=true
    * Only deletes resources tagged with ManagedBy=k0s-script
    * All Kubernetes resources (CRs, operators, namespaces)
    * All AWS resources (EC2, ENIs, security groups, EBS volumes)
    * Includes retry logic for ENI detachment
    * Provides detailed cleanup summary
  - 'clean-all' adds aggressive node-level cleanup (on-prem only):
    * Removes k0s data directories (preserves k0s binary)
    * Cleans kubelet, CNI, and Calico files
    * Flushes iptables rules
  - For EC2 mode, 'delete' terminates all instances and cleans AWS resources
  - For on-prem mode, machines remain running but k0s is stopped and reset
  - All commands are idempotent and safe to run multiple times
EOF
}

# ====== VERIFY WORKER STATUS ======
# Check if a worker is properly connected to the cluster
verify_worker_status() {
  local worker_ip="$1"
  local controller_ip="$2"

  log "  Verifying worker ${worker_ip} status..."

  # Check 1: Is k0s running on the worker?
  local k0s_status
  k0s_status=$(ssh_exec "${worker_ip}" "sudo k0s status 2>&1" || echo "not running")

  if echo "${k0s_status}" | grep -q "Kube-api probing successful: true"; then
    log "    ✓ k0s running and API reachable"
    return 0
  elif echo "${k0s_status}" | grep -q "Role: worker"; then
    # k0s is running but API not reachable yet
    log "    ⏳ k0s running but API not yet reachable"
    return 1
  else
    log "    ✗ k0s not running"
    return 2
  fi
}

# ====== THOROUGH WORKER CLEANUP ======
# Completely clean up k0s on a worker node (for fresh rejoin)
cleanup_worker_k0s() {
  local worker_ip="$1"

  log "  Performing thorough k0s cleanup on ${worker_ip}..."

  ssh_exec "${worker_ip}" "
    sudo systemctl stop k0sworker 2>/dev/null || true
    sudo systemctl disable k0sworker 2>/dev/null || true
    sudo systemctl reset-failed k0sworker 2>/dev/null || true
    sudo pkill -9 k0s 2>/dev/null || true
    sudo pkill -9 kubelet 2>/dev/null || true
    sudo pkill -9 containerd-shim 2>/dev/null || true
    sudo rm -f /etc/systemd/system/k0sworker.service
    sudo rm -rf /var/lib/k0s /run/k0s /etc/k0s /tmp/k0s-token
    sudo rm -f /run/k0s/containerd.sock 2>/dev/null || true
    sudo systemctl daemon-reload
  " 2>/dev/null || true

  log "    ✓ Cleanup complete"
}

# ====== JOIN WORKERS (Resume/Retry Worker Joins) ======
join_workers() {
  log "============================================"
  log "Joining Worker Nodes to k0s Cluster"
  log "============================================"

  load_config

  # Set proper kubeconfig
  export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"

  if [[ ! -f "${KUBECONFIG}" ]]; then
    err "Kubeconfig not found at ${KUBECONFIG}. Please run 'install' first."
  fi

  # Get controller IP from existing cluster
  log "Detecting cluster configuration..."

  # Option 1: Get from EC2 instances
  if [[ -z "${EXISTING_CONTROLLER_IPS}" ]]; then
    log "Discovering EC2 instances for cluster: ${CLUSTER_NAME}..."

    # Get controller IPs
    local controller_ips
    controller_ips=$(aws ec2 describe-instances --region "${REGION}" \
      --filters "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
                "Name=tag:Role,Values=controller" \
                "Name=instance-state-name,Values=running" \
      --query 'Reservations[*].Instances[*].PublicIpAddress' \
      --output text)

    if [[ -z "${controller_ips}" ]]; then
      err "No running controller instances found for cluster ${CLUSTER_NAME}"
    fi

    # Convert newlines and tabs to spaces, then split into array
    controller_ips=$(echo "${controller_ips}" | tr '\n\t' ' ')
    IFS=' ' read -ra CONTROLLER_IPS <<< "${controller_ips}"

    # Get worker IPs
    local worker_ips
    worker_ips=$(aws ec2 describe-instances --region "${REGION}" \
      --filters "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
                "Name=tag:Role,Values=cpu-worker,gpu-worker" \
                "Name=instance-state-name,Values=running" \
      --query 'Reservations[*].Instances[*].PublicIpAddress' \
      --output text)

    if [[ -z "${worker_ips}" ]]; then
      warn "No worker instances found for cluster ${CLUSTER_NAME}"
      log "Nothing to join, exiting."
      return 0
    fi

    # Convert newlines and tabs to spaces, then split into array
    worker_ips=$(echo "${worker_ips}" | tr '\n\t' ' ')
    IFS=' ' read -ra WORKER_IPS <<< "${worker_ips}"
    SSH_KEY_PATH="${HOME}/.ssh/${KEY_NAME}.pem"
  else
    # Option 2: Use existing IPs from config
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
    IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
  fi

  local controller_ip="${CONTROLLER_IPS[0]}"
  log "Controller IP: ${controller_ip}"
  log "Worker IPs: ${WORKER_IPS[*]}"

  # Check which workers are already joined AND healthy
  log "Checking current cluster nodes..."
  kubectl get nodes -o wide || true

  local already_joined_ips=()
  local needs_rejoin_ips=()

  # Get all cluster nodes once for matching
  local cluster_nodes_json
  cluster_nodes_json=$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')

  for worker_ip in "${WORKER_IPS[@]}"; do
    # Resolve the Kubernetes node name by SSHing to the worker and getting its hostname
    local node_exists=""
    node_exists=$(resolve_node_name "${worker_ip}")

    # Verify this node actually exists in the cluster
    if [[ -n "${node_exists}" ]]; then
      local found_in_cluster
      found_in_cluster=$(echo "${cluster_nodes_json}" | jq -r --arg name "${node_exists}" \
        '.items[] | select(.metadata.name==$name) | .metadata.name' 2>/dev/null | head -1 || echo "")
      if [[ -z "${found_in_cluster}" ]]; then
        node_exists=""
      fi
    fi

    if [[ -n "${node_exists}" ]]; then
      # Node exists in cluster, check if it's Ready
      local node_ready
      node_ready=$(echo "${cluster_nodes_json}" | jq -r --arg name "${node_exists}" \
        '.items[] | select(.metadata.name==$name) | .status.conditions[] | select(.type=="Ready") | .status' 2>/dev/null || echo "Unknown")

      if [[ "${node_ready}" == "True" ]]; then
        log "  ✓ Worker ${worker_ip} joined and Ready as ${node_exists}"
        already_joined_ips+=("${worker_ip}")
      else
        log "  ⚠ Worker ${worker_ip} exists as ${node_exists} but not Ready (${node_ready})"
        needs_rejoin_ips+=("${worker_ip}")
      fi
    else
      # Node doesn't exist in cluster, check k0s status on worker
      log "  Checking k0s status on ${worker_ip}..."
      if verify_worker_status "${worker_ip}" "${controller_ip}"; then
        log "  ⏳ Worker ${worker_ip} k0s running, waiting for cluster sync..."
        # Give it more time to appear in cluster
      else
        log "  ✗ Worker ${worker_ip} not properly connected"
        needs_rejoin_ips+=("${worker_ip}")
      fi
    fi
  done

  # If all workers are joined, nothing to do
  if [[ ${#already_joined_ips[@]} -eq ${#WORKER_IPS[@]} ]]; then
    log ""
    log "✓ All ${#WORKER_IPS[@]} workers are already joined and healthy!"
    kubectl get nodes -o wide
    return 0
  fi

  # Generate worker token from controller
  log ""
  log "Generating worker join token..."
  local worker_token
  worker_token=$(ssh_exec "${controller_ip}" "sudo k0s token create --role=worker" 2>/dev/null)

  if [[ -z "${worker_token}" ]]; then
    err "Failed to generate worker token from controller"
  fi

  log "Worker token generated successfully (${#worker_token} chars)"

  # Join workers that need to be joined/rejoined
  local workers_joined=0
  local workers_to_process=()

  # Build list of workers to process (use ${arr[@]+...} to avoid unbound-variable on empty arrays)
  for worker_ip in "${WORKER_IPS[@]}"; do
    local skip=false
    if [[ ${#already_joined_ips[@]} -gt 0 ]]; then
      for joined_ip in "${already_joined_ips[@]}"; do
        if [[ "${joined_ip}" == "${worker_ip}" ]]; then
          skip=true
          break
        fi
      done
    fi
    if [[ "${skip}" == "false" ]]; then
      workers_to_process+=("${worker_ip}")
    fi
  done

  log ""
  log "Workers to join/rejoin: ${workers_to_process[*]:-none}"

  if [[ ${#workers_to_process[@]} -eq 0 ]]; then
    log "No workers need joining"
    return 0
  fi

  for worker_ip in "${workers_to_process[@]}"; do
    log ""
    log "============================================"
    log "Joining worker: ${worker_ip}"
    log "============================================"

    # Check if k0s is installed
    log "  Checking if k0s is installed..."
    if ! ssh_exec "${worker_ip}" "command -v k0s >/dev/null 2>&1"; then
      log "  Installing k0s..."
      if ! ssh_exec "${worker_ip}" "curl -sSLf https://get.k0s.sh | sudo sh"; then
        warn "  Failed to install k0s on ${worker_ip}, skipping..."
        continue
      fi
    else
      log "  ✓ k0s already installed"
    fi

    # Ensure k0s is in sudo's secure_path (some distros exclude /usr/local/bin)
    ssh_exec "${worker_ip}" "if [ -f /usr/local/bin/k0s ] && [ ! -f /usr/bin/k0s ]; then sudo ln -sf /usr/local/bin/k0s /usr/bin/k0s; fi" || true

    # Thorough cleanup before rejoining (handles stale configurations)
    cleanup_worker_k0s "${worker_ip}"

    # RHEL/Fedora compatibility (firewalld, iptables-nft, python3-pyyaml, k0s binary)
    prepare_nodes_for_k0s "${worker_ip}"

    # Install worker with fresh token
    log "  Installing k0s worker configuration..."
    if ssh_exec "${worker_ip}" "echo '${worker_token}' | sudo tee /tmp/k0s-token >/dev/null && sudo k0s install worker --token-file=/tmp/k0s-token"; then
      log "  ✓ Worker configuration installed"
    else
      warn "  Failed to install worker configuration on ${worker_ip}"
      continue
    fi

    # Start worker using systemctl (more reliable than k0s start)
    log "  Starting k0s worker..."
    if ssh_exec "${worker_ip}" "sudo systemctl start k0sworker"; then
      log "  ✓ Worker service started"
    else
      warn "  Failed to start k0s worker on ${worker_ip}"
      # Try fallback
      ssh_exec "${worker_ip}" "sudo k0s start" || continue
    fi

    # Wait briefly and verify
    log "  Waiting for worker to initialize (15s)..."
    sleep 15

    # Verify worker status
    if verify_worker_status "${worker_ip}" "${controller_ip}"; then
      log "  ✓ Worker ${worker_ip} connected successfully!"
      workers_joined=$((workers_joined + 1))
    else
      warn "  Worker ${worker_ip} may still be connecting..."
      workers_joined=$((workers_joined + 1))  # Count as attempted
    fi
  done

  if [[ ${workers_joined} -gt 0 ]]; then
    log ""
    log "Waiting for workers to appear in cluster (45s)..."
    sleep 45

    log ""
    log "Current cluster nodes:"
    kubectl get nodes -o wide

    # Label the newly joined nodes
    log ""
    log "Labeling worker nodes..."
    label_nodes

    log ""
    log "============================================"
    log "✓ Processed ${workers_joined} worker(s)"
    log "============================================"

    # Final verification
    local final_count
    final_count=$(kubectl get nodes --no-headers | wc -l)
    local expected_count=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))

    if [[ ${final_count} -ge ${expected_count} ]]; then
      log "✓ All ${expected_count} nodes are now in the cluster!"
    else
      warn "Only ${final_count}/${expected_count} nodes in cluster. Some workers may need more time."
      warn "Run '$0 join-workers' again if workers don't appear within a few minutes."
    fi
  else
    log ""
    log "No workers needed to be joined"
  fi
}

# ====== MAIN ======
case "${1:-install}" in
  install)
    main_install
    ;;
  delete)
    main_delete
    ;;
  clean-all)
    clean_all
    ;;
  join-workers)
  # TODO fix this flow
    join_workers
    ;;
  *)
    usage
    exit 1
    ;;
esac
