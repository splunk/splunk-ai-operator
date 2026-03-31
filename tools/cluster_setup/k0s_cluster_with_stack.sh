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

# --- Unset conflicting AWS credentials ---
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE 2>/dev/null || true

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
    if grep -qiE 'timed out|operation timed out|i/o timeout|connection reset|TLS handshake timeout|could not get information about the resource' <<<"$out"; then
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

  # MinIO configuration: prefer environment variables (secure); fall back to config
  _minio_ak=$(yq eval '.minio.accessKey' "${CONFIG_FILE}" 2>/dev/null || echo "minioadmin")
  _minio_sk=$(yq eval '.minio.secretKey' "${CONFIG_FILE}" 2>/dev/null || echo "minioadmin123")
  MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-$_minio_ak}"
  MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-$_minio_sk}"
  MINIO_BUCKET=$(yq eval '.minio.bucket' "${CONFIG_FILE}" 2>/dev/null || echo "ai-platform-data")

  # Kubernetes namespace
  AI_NS=$(yq eval '.kubernetes.namespace' "${CONFIG_FILE}" 2>/dev/null || echo "ai-platform")

  # Splunk configuration
  AI_STANDALONE_NAME=$(yq eval '.splunk.standaloneName' "${CONFIG_FILE}" 2>/dev/null || echo "splunk-standalone")

  # ECR configuration (for private image repositories)
  ECR_ACCOUNT=$(yq eval '.ecr.account' "${CONFIG_FILE}" 2>/dev/null || echo "")

  # Get AWS account if using EC2
  if [[ -z "${EXISTING_CONTROLLER_IPS}" ]]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  fi

  # Auto-detect ECR account from AWS if not specified
  if [[ -z "${ECR_ACCOUNT}" ]] && aws sts get-caller-identity &>/dev/null; then
    ECR_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  fi

  # ImagePullSecrets configuration - read which registries are enabled
  IMAGE_PULL_SECRETS_ECR_ENABLED=$(yq eval '.imagePullSecrets.autoCreateECR' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED=$(yq eval '.imagePullSecrets.dockerHub.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_GCR_ENABLED=$(yq eval '.imagePullSecrets.gcr.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_ACR_ENABLED=$(yq eval '.imagePullSecrets.acr.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_CUSTOM_ENABLED=$(yq eval '.imagePullSecrets.custom.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")

  # File paths
  SPLUNK_OPERATOR_FILE=$(yq eval '.files.splunkOperator' "${CONFIG_FILE}" 2>/dev/null || echo "./splunk-operator-cluster.yaml")
  SPLUNK_AI_FILE=$(yq eval '.files.aiPlatform' "${CONFIG_FILE}" 2>/dev/null || echo "./artifacts.yaml")

  # Default accelerator type (must match a key in instance.yaml: L40S | H100 | H100_NVL)
  DEFAULT_ACCELERATOR=$(yq eval '.aiPlatform.defaultAcceleratorType' "${CONFIG_FILE}" 2>/dev/null || echo "")
  [[ "$DEFAULT_ACCELERATOR" == "null" || -z "$DEFAULT_ACCELERATOR" ]] && DEFAULT_ACCELERATOR="L40S"

  log "Configuration loaded: cluster=${CLUSTER_NAME}, namespace=${AI_NS}, accelerator=${DEFAULT_ACCELERATOR}"
  if [[ -n "${ECR_ACCOUNT}" ]]; then
    log "ECR Account: ${ECR_ACCOUNT}"
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
  for tool in ssh kubectl helm git jq yq; do
    if command -v "$tool" >/dev/null 2>&1; then
      pf_ok "$tool found"
    else
      pf_fail "$tool not found in PATH"
    fi
  done

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

# ====== K0S CLUSTER INSTALLATION ======
install_k0s_cluster() {
  log "Installing k0s cluster..."

  # Parse existing IPs if provided
  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
    IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
  fi

  local controller_ip="${CONTROLLER_IPS[0]}"  # Public IP for SSH
  local controller_private_ip="${CONTROLLER_PRIVATE_IPS[0]}"  # Private IP for k0s
  local controller_public_ip="${CONTROLLER_PUBLIC_IPS[0]}"  # Public IP for kubectl access

  log "Primary controller - Public IP: ${controller_public_ip}, Private IP: ${controller_private_ip}"

  # Generate k0s config
  log "Generating k0s configuration..."
  ssh_exec "${controller_ip}" "k0s config create > /tmp/k0s.yaml"

  # Configure k0s to use private IP for internal communication, add public IP to SANs for external access
  log "Configuring k0s: Private IP ${controller_private_ip} for internal, Public IP ${controller_public_ip} for external access..."
  ssh_exec "${controller_ip}" "cat > /tmp/k0s-config-update.py <<'PYSCRIPT'
import yaml

# Read the k0s config
with open('/tmp/k0s.yaml', 'r') as f:
    config = yaml.safe_load(f)

# Add SANs to API section - include BOTH private and public IPs
if 'spec' not in config:
    config['spec'] = {}
if 'api' not in config['spec']:
    config['spec']['api'] = {}
if 'sans' not in config['spec']['api']:
    config['spec']['api']['sans'] = []

# Add private IP (for internal cluster communication)
config['spec']['api']['sans'].append('${controller_private_ip}')
# Add public IP (for kubectl access from outside)
config['spec']['api']['sans'].append('${controller_public_ip}')

# CRITICAL: Use public IP for externalAddress so konnectivity-agents can connect
# konnectivity-agents run in pods and need to reach API server via routable address
config['spec']['api']['externalAddress'] = '${controller_public_ip}'

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

  log "Verifying k0s configuration includes public IP..."
  ssh_exec "${controller_ip}" "grep -A3 'api:' /tmp/k0s.yaml | head -5"

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
    # Write token to temp file first (stdin pipe doesn't work reliably over SSH)
    # Note: Token file must remain until worker bootstraps, so we don't delete it here
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

  # Update server address to use public IP for kubectl access from local machine
  log "Configuring kubeconfig to use public IP for external access..."
  sed -i.bak "s|server: .*|server: https://${controller_public_ip}:6443|" "${HOME}/.kube/k0s-${CLUSTER_NAME}"

  export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"

  log "k0s cluster installed successfully!"
  kubectl get nodes

  # Label nodes for proper workload scheduling
  label_nodes
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

  # Get all nodes
  local all_nodes
  all_nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

  # Label controller nodes
  for controller_ip in "${CONTROLLER_IPS[@]}"; do
    # Find node by IP
    local node_name
    node_name=$(kubectl get nodes -o json | jq -r ".items[] | select(.status.addresses[]? | select(.type==\"InternalIP\" and .address==\"${controller_ip}\")) | .metadata.name" | head -1)

    if [[ -n "${node_name}" ]]; then
      log "Labeling controller node: ${node_name}"
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
    fi
  done

  # Label worker nodes based on their configuration
  local worker_index=0
  for worker_ip in "${WORKER_IPS[@]}"; do
    # Find node by IP
    local node_name
    node_name=$(kubectl get nodes -o json | jq -r ".items[] | select(.status.addresses[]? | select(.type==\"InternalIP\" and .address==\"${worker_ip}\")) | .metadata.name" | head -1)

    if [[ -n "${node_name}" ]]; then
      # Determine if this is a GPU or CPU worker based on index
      # First CPU_WORKER_COUNT workers are CPU, rest are GPU
      if [[ ${worker_index} -lt ${CPU_WORKER_COUNT} ]]; then
        log "Labeling CPU worker node: ${node_name}"
        kubectl label nodes "${node_name}" \
          splunk.ai/node-role=worker \
          splunk.ai/workload-type=cpu \
          node.kubernetes.io/workload=ai-cpu \
          splunk.ai/instance-type=cpu-worker \
          --overwrite
      else
        log "Labeling GPU worker node: ${node_name}"
        kubectl label nodes "${node_name}" \
          splunk.ai/node-role=worker \
          splunk.ai/workload-type=gpu \
          node.kubernetes.io/workload=ai-gpu \
          splunk.ai/instance-type=gpu-worker \
          nvidia.com/gpu=true \
          --overwrite
      fi
      worker_index=$((worker_index + 1))
    fi
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
install_minio() {
  log "Installing MinIO..."

  ensure_namespace "minio-system"

  # Create MinIO secret
  kubectl create secret generic minio-creds \
    --namespace=minio-system \
    --from-literal=accesskey="${MINIO_ACCESS_KEY}" \
    --from-literal=secretkey="${MINIO_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Deploy MinIO
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio-system
spec:
  storageClassName: local-path
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 200Gi
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio-system
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
  namespace: minio-system
spec:
  replicas: 1
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
  kubectl wait --for=condition=ready pod -l app=minio -n minio-system --timeout=300s

  # Create bucket and directories using a job
  log "Verifying MinIO bucket: ${MINIO_BUCKET}..."

  # Delete existing job if it exists (Jobs are immutable, can't be updated)
  kubectl delete job minio-create-bucket -n minio-system --ignore-not-found=true 2>/dev/null || true
  sleep 2

  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-create-bucket
  namespace: minio-system
spec:
  backoffLimit: 3
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
          mc alias set myminio http://minio.minio-system.svc.cluster.local:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY}

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
  if kubectl wait --for=condition=complete job/minio-create-bucket -n minio-system --timeout=120s; then
    log "✓ MinIO bucket structure verified"

    # Show job logs for verification
    kubectl logs -n minio-system job/minio-create-bucket --tail=20 2>/dev/null || true
  else
    warn "Bucket verification job did not complete in time, checking status..."
    kubectl describe job/minio-create-bucket -n minio-system || true
    kubectl logs -n minio-system job/minio-create-bucket --tail=50 || true
  fi
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

# ====== INSTALL NVIDIA GPU OPERATOR ======
install_nvidia_device_plugin() {
  if [[ ${GPU_WORKER_COUNT} -eq 0 ]]; then
    log "Skipping NVIDIA GPU operator (no GPU workers)"
    return 0
  fi

  log "Installing NVIDIA GPU Operator..."

  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
  helm repo update

  helm_retry 3 upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator --create-namespace \
    --set driver.enabled=true \
    --set toolkit.enabled=true \
    --wait --timeout=10m

  log "NVIDIA GPU Operator installed successfully"
}

# ====== INSTALL PROMETHEUS OPERATOR ======
install_kube_prometheus() {
  log "Installing kube-prometheus-stack..."

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo update

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

  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true
  helm repo update

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
  helm repo update

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

  wait_for_crd standalones.enterprise.splunk.com 300

  log "Splunk Operator installed successfully"
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

  # Apply the artifacts.yaml file (contains CRDs and operator deployment)
  log "Applying Splunk AI Operator manifests..."

  # First try to apply normally
  if kubectl apply -f "${SPLUNK_AI_FILE}" 2>&1 | grep -q "field is immutable\|too long"; then
    log "Standard apply failed, using server-side apply with force..."
    kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}"
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
    --from-literal=accessKey="${MINIO_ACCESS_KEY}" \
    --from-literal=secretKey="${MINIO_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "MinIO credentials secret created"
  echo "minio-credentials"
}

# ====== SETUP ECR REPOSITORY PERMISSIONS ======
setup_ecr_permissions() {
  local repo_prefix="${1:-ml-platform}"

  log "Checking ECR repository permissions for: ${repo_prefix}..."

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
  repos=$(aws ecr describe-repositories --region "${REGION}" 2>/dev/null | \
    jq -r ".repositories[] | select(.repositoryName | startswith(\"${repo_prefix}\")) | .repositoryName" || echo "")

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
    policy=$(aws ecr get-repository-policy --repository-name "${repo}" --region "${REGION}" 2>/dev/null | jq -r '.policyText' || echo "")

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
        --region "${REGION}" \
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
    local ecr_region="${REGION:-us-west-2}"
    local ecr_account="${ECR_ACCOUNT:-}"

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
  local region="${REGION:-us-west-2}"
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

  # Create MinIO secret for Splunk (S3-compatible credentials)
  log "Creating S3-compatible secret for Splunk App Framework..."
  kubectl -n "${AI_NS}" create secret generic s3-secret \
    --from-literal=s3_access_key="${MINIO_ACCESS_KEY}" \
    --from-literal=s3_secret_key="${MINIO_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -

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

  # Create Splunk Standalone with App Framework (not SmartStore)
  cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  replicas: 1

  # Storage configuration for etc and var volumes
  etcVolumeStorageConfig:
    storageClassName: local-path
  varVolumeStorageConfig:
    storageClassName: local-path

  # Mount defaults ConfigMap
  volumes:
    - name: defaults
      configMap:
        name: splunk-defaults
  defaultsUrl: /mnt/defaults/default.yml

  # App Framework configuration (uses MinIO as S3-compatible storage)
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
        endpoint: http://minio.minio-system.svc.cluster.local:9000
        region: us-east-1
        path: ${MINIO_BUCKET}
        secretRef: s3-secret
YAML

  log "Waiting for Splunk Standalone to be ready..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=${AI_STANDALONE_NAME} -n ${AI_NS} --timeout=600s || true

  log "Splunk Standalone installed successfully"
}

# ====== INSTALL AI PLATFORM CR ======
install_ai_platform_cr() {
  log "============================================"
  log "Creating AIPlatform Custom Resource"
  log "============================================"

  # Get Splunk secret name (for HEC endpoint)
  local splunk_secret="splunk-${AI_STANDALONE_NAME}-standalone-secret-v1"
  log "Using Splunk secret: ${splunk_secret}"

  # Ensure s3-secret exists in AI namespace (for MinIO credentials)
  log "Creating/updating MinIO credentials secret (s3-secret) in ${AI_NS}..."
  kubectl -n "${AI_NS}" create secret generic s3-secret \
    --from-literal=s3_access_key="${MINIO_ACCESS_KEY}" \
    --from-literal=s3_secret_key="${MINIO_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "✓ MinIO credentials secret ready"

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

  # Apply AIPlatform CR (matching EKS script pattern)
  log "Applying AIPlatform CR: ${CLUSTER_NAME}-ai-platform"
  cat <<YAML | kubectl -n "${AI_NS}" apply --server-side --force-conflicts -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${CLUSTER_NAME}-ai-platform
spec:
  # MinIO object storage (S3-compatible with credentials)
  objectStorage:
    path: s3://${MINIO_BUCKET}
    region: us-east-1
    endpoint: http://minio.minio-system.svc.cluster.local:9000
    secretRef: s3-secret

  # Image configuration (including pull secrets for private registries)
  images:
${image_pull_secrets}

  # Features configuration
  features:
    - name: saia
      version: "1.1.0"

  # Storage configuration
  storage:
    vectorDB:
      size: "50Gi"
      storageClassName: local-path

  # Worker configuration
  workerGroupConfig:
    imageRegistry: "rayproject/ray:2.9.0"

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

  ensure_namespace "${AI_NS}"

  # Install infrastructure components
  install_minio
  install_cert_manager
  install_kube_prometheus
  install_otel_operator_and_contrib_collector
  install_nvidia_device_plugin
  install_ray_operator

  # Install Splunk components
  install_splunk_operator
  install_splunk_standalone

  # Install AI Platform operator
  install_splunk_ai_operator

  # Create image pull secrets from configuration
  create_image_pull_secrets "${AI_NS}"

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
  if kubectl get pod -n minio-system -l app=minio 2>/dev/null | grep -q "Running"; then
    log "✅ MinIO is running"
  else
    warn "MinIO pod not in Running state"
    kubectl get pods -n minio-system
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
  log "     kubectl port-forward svc/minio -n minio-system 9001:9001"
  log "     Open: http://localhost:9001"
  log "  "
  log "  🔑 Credentials:"
  log "     Username: ${MINIO_ACCESS_KEY}"
  log "     Password: ${MINIO_SECRET_KEY}"
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
    * Removes k0s binaries and data directories
    * Cleans kubelet, CNI, and Calico files
    * Flushes iptables rules
  - For EC2 mode, 'delete' terminates all instances and cleans AWS resources
  - For on-prem mode, machines remain running but k0s is stopped and reset
  - All commands are idempotent and safe to run multiple times
EOF
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

  # Check which workers are already joined
  log "Checking current cluster nodes..."
  kubectl get nodes -o wide || true

  local already_joined_ips=()
  for worker_ip in "${WORKER_IPS[@]}"; do
    # Check if node with this IP already exists in cluster
    local node_exists
    node_exists=$(kubectl get nodes -o json | jq -r ".items[] | select(.status.addresses[]? | select(.type==\"InternalIP\" and .address==\"${worker_ip}\")) | .metadata.name" 2>/dev/null || echo "")

    if [[ -n "${node_exists}" ]]; then
      log "  ✓ Worker ${worker_ip} already joined as ${node_exists}"
      already_joined_ips+=("${worker_ip}")
    else
      log "  ✗ Worker ${worker_ip} not joined yet"
    fi
  done

  # Generate worker token from controller
  log "Generating worker join token..."
  local worker_token
  worker_token=$(ssh_exec "${controller_ip}" "sudo k0s token create --role=worker" 2>/dev/null)

  if [[ -z "${worker_token}" ]]; then
    err "Failed to generate worker token from controller"
  fi

  log "Worker token generated successfully"

  # Install and join workers that aren't already joined
  local workers_joined=0
  for worker_ip in "${WORKER_IPS[@]}"; do
    # Skip if already joined
    local skip_worker=false
    if [[ ${#already_joined_ips[@]} -gt 0 ]]; then
      for joined_ip in "${already_joined_ips[@]}"; do
        if [[ "${joined_ip}" == "${worker_ip}" ]]; then
          skip_worker=true
          break
        fi
      done
    fi

    if [[ "${skip_worker}" == "true" ]]; then
      continue
    fi

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

    # Stop k0s if it's running (to rejoin cleanly)
    log "  Stopping any existing k0s worker process..."
    ssh_exec "${worker_ip}" "sudo k0s stop 2>/dev/null || true"
    ssh_exec "${worker_ip}" "sudo k0s reset 2>/dev/null || true"

    # Install worker
    log "  Installing k0s worker configuration..."
    # Write token to temp file first (stdin pipe doesn't work reliably over SSH)
    # Note: Token file must remain until worker bootstraps, so we don't delete it here
    if ssh_exec "${worker_ip}" "echo '${worker_token}' | sudo tee /tmp/k0s-token >/dev/null && sudo k0s install worker --token-file=/tmp/k0s-token"; then
      log "  ✓ Worker configuration installed"
    else
      warn "  Failed to install worker configuration on ${worker_ip}"
      continue
    fi

    # Start worker
    log "  Starting k0s worker..."
    if ssh_exec "${worker_ip}" "sudo k0s start"; then
      log "  ✓ Worker started successfully"
      workers_joined=$((workers_joined + 1))
    else
      warn "  Failed to start k0s worker on ${worker_ip}"
      continue
    fi
  done

  if [[ ${workers_joined} -gt 0 ]]; then
    log ""
    log "Waiting for workers to join cluster (60s)..."
    sleep 60

    log "Current cluster nodes:"
    kubectl get nodes -o wide

    # Label the newly joined nodes
    log ""
    log "Labeling worker nodes..."
    label_nodes

    log ""
    log "============================================"
    log "✓ Successfully joined ${workers_joined} worker(s)"
    log "============================================"
  else
    log ""
    log "All workers already joined or no new workers to join"
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
    join_workers
    ;;
  *)
    usage
    exit 1
    ;;
esac
