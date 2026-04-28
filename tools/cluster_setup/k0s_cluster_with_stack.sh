#!/bin/bash
set -euo pipefail

# =============================================================================
# k0s Cluster Setup Script for Splunk AI Platform
# =============================================================================
# Deploys a k0s cluster on customer-provided (on-prem / baremetal) nodes.
# Requires existingIPs in the config YAML (controller + worker IPs).
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

  # Validate existingIPs are provided (mandatory for on-prem)
  if [[ -z "${EXISTING_CONTROLLER_IPS}" ]]; then
    err "nodes.existingIPs.controllers must be set in config YAML — this script requires pre-provisioned nodes"
  fi

  CONTROLLER_COUNT=$(yq eval '.nodes.controllers' "${CONFIG_FILE}" 2>/dev/null || echo "1")
  CPU_WORKER_COUNT=$(yq eval '.nodes.cpuWorkers' "${CONFIG_FILE}" 2>/dev/null || echo "2")
  GPU_WORKER_COUNT=$(yq eval '.nodes.gpuWorkers' "${CONFIG_FILE}" 2>/dev/null || echo "1")

  # Storage configuration
  STORAGE_CLASS=$(yq eval '.storage.storageClass // "local-path"' "${CONFIG_FILE}" 2>/dev/null || echo "local-path")
  VECTORDB_SIZE=$(yq eval '.storage.vectorDbSize // "50Gi"' "${CONFIG_FILE}" 2>/dev/null || echo "50Gi")

  # Minimum disk space thresholds (GB) for preflight validation.
  # Customers must ensure /var/lib/k0s has at least this much space before install.
  MIN_DISK_CONTROLLER=$(yq eval '.storage.minimumDiskSpace.controller // "100"' "${CONFIG_FILE}" 2>/dev/null || echo "100")
  MIN_DISK_CPU_WORKER=$(yq eval '.storage.minimumDiskSpace.cpuWorker // "200"' "${CONFIG_FILE}" 2>/dev/null || echo "200")
  MIN_DISK_GPU_WORKER=$(yq eval '.storage.minimumDiskSpace.gpuWorker // "500"' "${CONFIG_FILE}" 2>/dev/null || echo "500")
  # Strip non-numeric suffixes (e.g. "30Gi" -> "30") so arithmetic comparisons work
  MIN_DISK_CONTROLLER="${MIN_DISK_CONTROLLER//[!0-9]/}"
  MIN_DISK_CPU_WORKER="${MIN_DISK_CPU_WORKER//[!0-9]/}"
  MIN_DISK_GPU_WORKER="${MIN_DISK_GPU_WORKER//[!0-9]/}"

  # Object storage: objectStore.type (aws | s3compat | minio | seaweedfs); default minio when unset
  OBJ_STORE_TYPE="$(yq eval '.storage.objectStore.type // "minio"' "$CONFIG_FILE" 2>/dev/null || echo "minio")"
  OBJ_STORE_BUCKET="$(yq eval '.storage.objectStore.bucket // "ai-platform-data"' "$CONFIG_FILE" 2>/dev/null || echo "ai-platform-data")"
  OBJ_STORE_ENDPOINT="$(yq eval '.storage.objectStore.endpoint // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  _obj_user="$(yq eval '.storage.objectStore.auth.rootUser // "minioadmin"' "$CONFIG_FILE" 2>/dev/null || echo "minioadmin")"
  _obj_pw="$(yq eval '.storage.objectStore.auth.rootPassword // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  MINIO_ENDPOINT="${OBJ_STORE_ENDPOINT}"
  MINIO_BUCKET="${OBJ_STORE_BUCKET}"
  MINIO_ROOT_USER="${MINIO_ROOT_USER:-$_obj_user}"
  MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$_obj_pw}"

  # Kubernetes namespace
  AI_NS=$(yq eval '.kubernetes.namespace' "${CONFIG_FILE}" 2>/dev/null || echo "ai-platform")

  # Splunk configuration
  AI_STANDALONE_NAME=$(yq eval '.splunk.standaloneName' "${CONFIG_FILE}" 2>/dev/null || echo "splunk-standalone")

  # Container images
  IMAGE_REGISTRY="$(yq eval '.images.registry // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  OPERATOR_IMAGE="$(yq eval '.images.operator.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SPLUNK_IMAGE="$(yq eval '.images.splunk.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SPLUNK_OPERATOR_IMAGE="$(yq eval '.images.splunk.operatorImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  RAY_HEAD_IMAGE="$(yq eval '.images.ray.headImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  RAY_WORKER_IMAGE="$(yq eval '.images.ray.workerImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  WEAVIATE_IMAGE="$(yq eval '.images.weaviate.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SAIA_API_IMAGE="$(yq eval '.images.saia.apiImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SAIA_API_V2_IMAGE="$(yq eval '.images.saia.apiV2Image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SAIA_DATALOADER_IMAGE="$(yq eval '.images.saia.dataLoaderImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  FLUENT_BIT_IMAGE="$(yq eval '.images.fluentBit.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  OTEL_COLLECTOR_IMAGE="$(yq eval '.images.otelCollector.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  NGINX_IMAGE="$(yq eval '.images.nginx.image' "$CONFIG_FILE" 2>/dev/null || echo "")"

  # Operator versions
  MODEL_VERSION="$(yq eval '.operators.ray.modelVersion // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  RAY_RUNTIME_VERSION="$(yq eval '.operators.ray.rayVersion // "2.44.0"' "$CONFIG_FILE" 2>/dev/null || echo "2.44.0")"

  # AI Platform CR configuration
  DEFAULT_ACCELERATOR=$(yq eval '.aiPlatform.defaultAcceleratorType // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  WORKER_IMAGE_REGISTRY=$(yq eval '.aiPlatform.workerGroupConfig.imageRegistry // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")

  # NVIDIA device plugin version
  NVIDIA_VERSION=$(yq eval '.operators.nvidia.devicePluginVersion // "v0.17.3"' "${CONFIG_FILE}" 2>/dev/null || echo "v0.17.3")

  # ECR configuration (for private image repositories)
  ECR_ACCOUNT=$(yq eval '.ecr.account' "${CONFIG_FILE}" 2>/dev/null || echo "")
  ECR_REGION=$(yq eval '.ecr.region // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")

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

  log "Configuration loaded: cluster=${CLUSTER_NAME}, namespace=${AI_NS}"
  log "Object storage: ${OBJ_STORE_TYPE}, endpoint=${OBJ_STORE_ENDPOINT:-not set}, bucket=${OBJ_STORE_BUCKET}"
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

# ====== IMAGE HELPERS ======
build_image_url() {
  local registry="$1"
  local image_path="$2"
  if [[ "$image_path" =~ ^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/.*:.+ ]]; then
    echo "$image_path"
    return 0
  fi
  if [[ -n "$registry" && "$registry" != "null" ]]; then
    echo "${registry}/${image_path}"
  else
    echo "$image_path"
  fi
}

validate_image_config() {
  log "Validating image configuration..."

  if [[ -z "$OPERATOR_IMAGE" || "$OPERATOR_IMAGE" == "null" ]]; then
    err "REQUIRED: images.operator.image must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$SPLUNK_IMAGE" || "$SPLUNK_IMAGE" == "null" ]]; then
    err "REQUIRED: images.splunk.image must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$RAY_HEAD_IMAGE" || "$RAY_HEAD_IMAGE" == "null" ]]; then
    err "REQUIRED: images.ray.headImage must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$RAY_WORKER_IMAGE" || "$RAY_WORKER_IMAGE" == "null" ]]; then
    err "REQUIRED: images.ray.workerImage must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$WEAVIATE_IMAGE" || "$WEAVIATE_IMAGE" == "null" ]]; then
    err "REQUIRED: images.weaviate.image must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$SAIA_API_IMAGE" || "$SAIA_API_IMAGE" == "null" ]]; then
    err "REQUIRED: images.saia.apiImage must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$SAIA_API_V2_IMAGE" || "$SAIA_API_V2_IMAGE" == "null" ]]; then
    err "REQUIRED: images.saia.apiV2Image must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$SAIA_DATALOADER_IMAGE" || "$SAIA_DATALOADER_IMAGE" == "null" ]]; then
    err "REQUIRED: images.saia.dataLoaderImage must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$SPLUNK_OPERATOR_IMAGE" || "$SPLUNK_OPERATOR_IMAGE" == "null" ]]; then
    SPLUNK_OPERATOR_IMAGE="docker.io/splunk/splunk-operator:3.0.0"
    log "Using default Splunk Operator image: $SPLUNK_OPERATOR_IMAGE"
  fi
  if [[ -z "$FLUENT_BIT_IMAGE" || "$FLUENT_BIT_IMAGE" == "null" ]]; then
    FLUENT_BIT_IMAGE="fluent/fluent-bit:1.9.6"
    log "Using default Fluent Bit image: $FLUENT_BIT_IMAGE"
  fi
  if [[ -z "$OTEL_COLLECTOR_IMAGE" || "$OTEL_COLLECTOR_IMAGE" == "null" ]]; then
    OTEL_COLLECTOR_IMAGE="otel/opentelemetry-collector-contrib:0.122.1"
    log "Using default OpenTelemetry Collector image: $OTEL_COLLECTOR_IMAGE"
  fi
  if [[ -z "$NGINX_IMAGE" || "$NGINX_IMAGE" == "null" ]]; then
    NGINX_IMAGE="docker.io/library/nginx:1.27-alpine"
    log "Using default Nginx image: $NGINX_IMAGE"
  fi
  if [[ -z "$MODEL_VERSION" || "$MODEL_VERSION" == "null" ]]; then
    MODEL_VERSION="v0.3.14-36-g1549f5a"
    log "Using default Model version: $MODEL_VERSION"
  fi
  if [[ -z "$RAY_RUNTIME_VERSION" || "$RAY_RUNTIME_VERSION" == "null" ]]; then
    RAY_RUNTIME_VERSION="2.44.0"
    log "Using default Ray runtime version: $RAY_RUNTIME_VERSION"
  fi

  log "✓ Image configuration validated successfully"
}

configure_images() {
  log "Configuring container images in manifest files..."

  if [[ ! -f "${SPLUNK_AI_FILE}.original" ]]; then
    log "Creating backup: ${SPLUNK_AI_FILE}.original"
    cp "$SPLUNK_AI_FILE" "${SPLUNK_AI_FILE}.original"
  fi
  if [[ ! -f "${SPLUNK_OPERATOR_FILE}.original" ]]; then
    log "Creating backup: ${SPLUNK_OPERATOR_FILE}.original"
    cp "$SPLUNK_OPERATOR_FILE" "${SPLUNK_OPERATOR_FILE}.original"
  fi

  log "Restoring from clean originals to ensure idempotent updates..."
  cp "${SPLUNK_AI_FILE}.original" "$SPLUNK_AI_FILE"
  cp "${SPLUNK_OPERATOR_FILE}.original" "$SPLUNK_OPERATOR_FILE"

  log "Updating $SPLUNK_AI_FILE..."

  local operator_full=$(build_image_url "$IMAGE_REGISTRY" "$OPERATOR_IMAGE")
  local ray_head_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_HEAD_IMAGE")
  local ray_worker_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_WORKER_IMAGE")
  local weaviate_full=$(build_image_url "$IMAGE_REGISTRY" "$WEAVIATE_IMAGE")
  local saia_api_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_IMAGE")
  local saia_api_v2_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_V2_IMAGE")
  local saia_dataloader_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_DATALOADER_IMAGE")
  local fluent_bit_full=$(build_image_url "$IMAGE_REGISTRY" "$FLUENT_BIT_IMAGE")
  local otel_collector_full=$(build_image_url "$IMAGE_REGISTRY" "$OTEL_COLLECTOR_IMAGE")
  # Nginx is an upstream image; don't rewrite it to the ECR registry unless the
  # user explicitly put it under their registry. build_image_url already
  # preserves a fully-qualified image path, so `docker.io/library/nginx:...`
  # stays intact and `nginx:1.27-alpine` gets prefixed with $IMAGE_REGISTRY.
  local nginx_full=$(build_image_url "$IMAGE_REGISTRY" "$NGINX_IMAGE")

  local ray_head_escaped=$(echo "$ray_head_full" | sed 's/[\/&]/\\&/g')
  local ray_worker_escaped=$(echo "$ray_worker_full" | sed 's/[\/&]/\\&/g')
  local weaviate_escaped=$(echo "$weaviate_full" | sed 's/[\/&]/\\&/g')
  local saia_api_escaped=$(echo "$saia_api_full" | sed 's/[\/&]/\\&/g')
  local saia_api_v2_escaped=$(echo "$saia_api_v2_full" | sed 's/[\/&]/\\&/g')
  local saia_dataloader_escaped=$(echo "$saia_dataloader_full" | sed 's/[\/&]/\\&/g')
  local fluent_bit_escaped=$(echo "$fluent_bit_full" | sed 's/[\/&]/\\&/g')
  local otel_collector_escaped=$(echo "$otel_collector_full" | sed 's/[\/&]/\\&/g')
  local nginx_escaped=$(echo "$nginx_full" | sed 's/[\/&]/\\&/g')
  local operator_escaped=$(echo "$operator_full" | sed 's/[\/&]/\\&/g')

  # BSD (macOS) sed requires an explicit backup-suffix arg after -i.
  # GNU (Linux) sed accepts -i without the suffix arg.
  # Use a bash array so the empty-string "" is preserved as a distinct argv entry
  # on macOS; without this, unquoted $SEDOPTION word-splitting created stray
  # "filename''" backup files next to each artifact.
  local SED_INPLACE
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_INPLACE=(sed -i "")
  else
    SED_INPLACE=(sed -i)
  fi

  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_RAY_HEAD/,/value:/ s|value:.*|value: ${ray_head_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_RAY_WORKER/,/value:/ s|value:.*|value: ${ray_worker_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_WEAVIATE/,/value:/ s|value:.*|value: ${weaviate_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SAIA_API$/,/value:/ s|value:.*|value: ${saia_api_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SAIA_API_V2/,/value:/ s|value:.*|value: ${saia_api_v2_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_POST_INSTALL_HOOK/,/value:/ s|value:.*|value: ${saia_dataloader_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_FLUENT_BIT/,/value:/ s|value:.*|value: ${fluent_bit_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_OTEL_COLLECTOR/,/value:/ s|value:.*|value: ${otel_collector_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_NGINX/,/value:/ s|value:.*|value: ${nginx_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: MODEL_VERSION/,/value:/ s|value:.*|value: ${MODEL_VERSION}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RAY_VERSION/,/value:/ s|value:.*|value: ${RAY_RUNTIME_VERSION}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "s|image: .*splunk.*ai.*operator.*|image: ${operator_escaped}|I" "$SPLUNK_AI_FILE"

  log "  ✓ Updated RELATED_IMAGE_RAY_HEAD: $ray_head_full"
  log "  ✓ Updated RELATED_IMAGE_RAY_WORKER: $ray_worker_full"
  log "  ✓ Updated RELATED_IMAGE_WEAVIATE: $weaviate_full"
  log "  ✓ Updated RELATED_IMAGE_SAIA_API: $saia_api_full"
  log "  ✓ Updated RELATED_IMAGE_SAIA_API_V2: $saia_api_v2_full"
  log "  ✓ Updated RELATED_IMAGE_POST_INSTALL_HOOK: $saia_dataloader_full"
  log "  ✓ Updated RELATED_IMAGE_FLUENT_BIT: $fluent_bit_full"
  log "  ✓ Updated RELATED_IMAGE_OTEL_COLLECTOR: $otel_collector_full"
  log "  ✓ Updated RELATED_IMAGE_NGINX: $nginx_full"
  log "  ✓ Updated operator image: $operator_full"
  log "  ✓ Updated MODEL_VERSION: $MODEL_VERSION"
  log "  ✓ Updated RAY_VERSION: $RAY_RUNTIME_VERSION"

  log "Updating $SPLUNK_OPERATOR_FILE..."

  local splunk_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_IMAGE")
  local splunk_operator_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_OPERATOR_IMAGE")

  local splunk_escaped=$(echo "$splunk_full" | sed 's/[\/&]/\\&/g')
  local splunk_op_escaped=$(echo "$splunk_operator_full" | sed 's/[\/&]/\\&/g')

  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SPLUNK_ENTERPRISE/,/value:/ s|value:.*|value: ${splunk_escaped}|" "$SPLUNK_OPERATOR_FILE"
  "${SED_INPLACE[@]}" "s|image: .*splunk.*operator.*|image: ${splunk_op_escaped}|I" "$SPLUNK_OPERATOR_FILE"

  log "  ✓ Updated Splunk Enterprise image: $splunk_full"
  log "  ✓ Updated Splunk Operator image: $splunk_operator_full"
  log "✓ All images configured successfully"
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

  pf_header "Object storage (customer-managed)"
  pf_ok "Object storage type: ${OBJ_STORE_TYPE} (bucket=${OBJ_STORE_BUCKET})"
  if [[ "${OBJ_STORE_TYPE}" == "seaweedfs" ]]; then
    if echo "${OBJ_STORE_ENDPOINT}" | grep -q ':9000'; then
      pf_warn "SeaweedFS uses port 8333 (not 9000). Endpoint has :9000 (MinIO); use http://host:8333 for SeaweedFS."
    else
      [[ -n "${OBJ_STORE_ENDPOINT}" ]] && pf_ok "SeaweedFS endpoint: ${OBJ_STORE_ENDPOINT}" || pf_fail "objectStore.endpoint is required"
    fi
  else
    [[ -n "${OBJ_STORE_ENDPOINT}" ]] && pf_ok "Endpoint: ${OBJ_STORE_ENDPOINT}" || pf_fail "objectStore.endpoint is required"
  fi
  [[ -n "${MINIO_ROOT_PASSWORD}" ]] && pf_ok "Credentials configured" || pf_fail "Object store credentials required (objectStore.auth.rootPassword)"

  pf_header "Infrastructure mode"
  pf_ok "Using existing infrastructure (on-prem/baremetal)"
  pf_ok "Controller IPs: ${EXISTING_CONTROLLER_IPS}"
  pf_ok "Worker IPs: ${EXISTING_WORKER_IPS}"
  [[ -n "${SSH_KEY_PATH}" && -f "${SSH_KEY_PATH}" ]] && pf_ok "SSH key: ${SSH_KEY_PATH}" || pf_fail "SSH key not found: ${SSH_KEY_PATH}"

  # Validate disk space on every node (requires SSH access)
  preflight_check_node_storage

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

# ====== PREPARE NODES (RHEL/Fedora compatibility + k0s binary) ======
prepare_nodes_for_k0s() {
  local node_ips=("$@")
  log "Preparing ${#node_ips[@]} node(s) for k0s (OS compatibility + binary)..."
  for node_ip in "${node_ips[@]}"; do
    log "  Preparing node ${node_ip}..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      ${SSH_KEY_PATH:+-i "${SSH_KEY_PATH}"} "${SSH_USER}@${node_ip}" \
      bash -s <<'REMOTE_SCRIPT' || warn "  Preparation had issues on ${node_ip}"
      # Disable firewalld if active (blocks k0s ports: 6443, 10250, 8472, etc.)
      if systemctl is-active firewalld >/dev/null 2>&1; then
        echo 'Disabling firewalld...'
        sudo systemctl stop firewalld
        sudo systemctl disable firewalld
      fi

      # Load kernel modules required by Calico and kube-proxy
      for mod in br_netfilter overlay nf_conntrack; do
        if ! lsmod | grep -q "^${mod} "; then
          sudo modprobe "${mod}" 2>/dev/null || echo "WARN: could not load kernel module ${mod}"
        fi
      done
      # Persist across reboots
      sudo mkdir -p /etc/modules-load.d
      printf 'br_netfilter\noverlay\nnf_conntrack\n' | sudo tee /etc/modules-load.d/k0s.conf >/dev/null

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
REMOTE_SCRIPT
  done
}

# ====== PREFLIGHT: NODE STORAGE VALIDATION ======
# On-prem / baremetal nodes must have sufficient disk space BEFORE running the
# installer. This function SSHs to every node and verifies the filesystem
# backing /var/lib/k0s (or / on first install) meets the minimum threshold.
#
# Thresholds (configurable via storage.minimumDiskSpace in config YAML):
#   Controller : 100 GB (k0s control plane, kine/etcd, container images)
#   CPU worker : 200 GB (weaviate, saia-api, data-loader, fluent-bit, etc.)
#   GPU worker : 500 GB (model weights 60-240 GB each, ray-worker-gpu image ~30 GB)
#
# If a dedicated disk is available, the customer should mount it at
# /var/lib/k0s before running this script.
preflight_check_node_storage() {
  pf_header "Node storage"

  IFS=' ' read -ra _ctrl_ips <<< "${EXISTING_CONTROLLER_IPS}"
  IFS=' ' read -ra _worker_ips <<< "${EXISTING_WORKER_IPS}"

  # Helper: SSH to a node and return available GB on the filesystem backing
  # /var/lib/k0s (falls back to / if k0s hasn't been installed yet).
  _get_avail_gb() {
    local ip="$1"
    ssh_exec "${ip}" "
      avail_kb=\$(df --output=avail /var/lib/k0s 2>/dev/null | tail -1 | tr -d ' ')
      if [ -z \"\${avail_kb}\" ] || [ \"\${avail_kb}\" = \"Avail\" ]; then
        avail_kb=\$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ')
      fi
      echo \$(( \${avail_kb:-0} / 1048576 ))
    " 2>/dev/null || echo "0"
  }

  # Check controller nodes
  for ip in "${_ctrl_ips[@]}"; do
    local avail
    avail=$(_get_avail_gb "${ip}")
    avail=$(echo "${avail}" | tr -d '[:space:]')
    if [[ "${avail}" -ge "${MIN_DISK_CONTROLLER}" ]]; then
      pf_ok "Controller ${ip}: ${avail} GB available (minimum: ${MIN_DISK_CONTROLLER} GB)"
    else
      pf_fail "Controller ${ip}: ${avail} GB available — need at least ${MIN_DISK_CONTROLLER} GB on /var/lib/k0s"
    fi
  done

  # Check worker nodes (distinguish CPU vs GPU by index)
  local widx=0
  for ip in "${_worker_ips[@]}"; do
    local avail role min_required
    avail=$(_get_avail_gb "${ip}")
    avail=$(echo "${avail}" | tr -d '[:space:]')

    if [[ ${widx} -lt ${CPU_WORKER_COUNT} ]]; then
      role="CPU worker"
      min_required="${MIN_DISK_CPU_WORKER}"
    else
      role="GPU worker"
      min_required="${MIN_DISK_GPU_WORKER}"
    fi

    if [[ "${avail}" -ge "${min_required}" ]]; then
      pf_ok "${role} ${ip}: ${avail} GB available (minimum: ${min_required} GB)"
    else
      pf_fail "${role} ${ip}: ${avail} GB available — need at least ${min_required} GB on /var/lib/k0s"
    fi
    widx=$((widx + 1))
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

  log "Waiting for controller API server to be ready..."
  local ctrl_retries=0
  while (( ctrl_retries < 60 )); do
    if ssh_exec "${controller_ip}" "sudo k0s kubectl get --raw /healthz 2>/dev/null" &>/dev/null; then
      log "  ✓ Controller API server is ready (${ctrl_retries}s)"
      break
    fi
    sleep 5
    ctrl_retries=$((ctrl_retries + 5))
    log "  Waiting... ${ctrl_retries}/300s"
  done

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

  log "Waiting for workers to join the cluster..."
  local expected_join=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))
  local join_retries=0
  while (( join_retries < 120 )); do
    local current_nodes
    current_nodes=$(ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    current_nodes=$(echo "${current_nodes}" | tr -d '[:space:]')
    if [[ "${current_nodes}" -ge "${expected_join}" ]]; then
      log "  ✓ All ${current_nodes} node(s) joined (${join_retries}s)"
      break
    fi
    sleep 10
    join_retries=$((join_retries + 10))
    log "  Waiting... ${current_nodes}/${expected_join} nodes joined (${join_retries}/120s)"
  done

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

  # Wait for all nodes to be ready.
  #
  # NOTE: we count nodes whose "Ready" condition is exactly "True" via a
  # structured JSON query — NOT by grepping for the string "Ready" in the
  # plain-text `kubectl get nodes` output. That string match is a trap
  # because the STATUS column of a not-yet-ready node prints the substring
  # "NotReady" which ALSO matches a naive `grep -c Ready`, causing the loop
  # to exit prematurely. Downstream labeling then silently skips any worker
  # that joined the API server late with "Node not found in cluster".
  local node_count=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))
  log "Waiting for ${node_count} node(s) to be Ready..."

  local timeout=300
  local elapsed=0
  local ready_count
  while :; do
    ready_count=$(kubectl get nodes -o json 2>/dev/null \
      | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null \
      || echo 0)
    if [[ "${ready_count}" -ge "${node_count}" ]]; then
      log "  ✓ All ${ready_count}/${node_count} nodes Ready"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      warn "Timeout (${timeout}s) waiting for all nodes to be Ready (have ${ready_count}/${node_count}); proceeding anyway..."
      break
    fi
    if (( elapsed % 30 == 0 )); then
      log "  ${ready_count}/${node_count} nodes Ready (${elapsed}/${timeout}s)"
    fi
  done

  # Helper: wait up to 60s for a given node name to appear in the API server.
  # This guards against the race where a worker joined the cluster just after
  # the top-of-function readiness check returned but its Node object is still
  # propagating to the API server we're talking to.
  _wait_for_node_visible() {
    local node_name="$1"
    local ip="$2"
    local tries=0
    local max_tries=12  # 12 * 5s = 60s
    while (( tries < max_tries )); do
      if kubectl get node "${node_name}" &>/dev/null; then
        return 0
      fi
      sleep 5
      tries=$((tries + 1))
    done
    warn "  Node '${node_name}' (from ${ip}) did not become visible in API server after 60s"
    return 1
  }

  # Track labeling outcomes so we can fail loud if any node ends up unlabeled.
  local labeling_failures=()

  # Label controller nodes
  for controller_ip in "${CONTROLLER_IPS[@]}"; do
    local node_name
    node_name=$(resolve_node_name "${controller_ip}")

    if [[ -z "${node_name}" ]]; then
      warn "  Could not resolve hostname for controller ${controller_ip}, skipping..."
      labeling_failures+=("${controller_ip} (hostname unresolved)")
      continue
    fi

    if ! _wait_for_node_visible "${node_name}" "${controller_ip}"; then
      labeling_failures+=("${controller_ip} / ${node_name} (never visible)")
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
      labeling_failures+=("${worker_ip} (hostname unresolved)")
      worker_index=$((worker_index + 1))
      continue
    fi

    if ! _wait_for_node_visible "${node_name}" "${worker_ip}"; then
      labeling_failures+=("${worker_ip} / ${node_name} (never visible)")
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

  # --- Final verification: every node must have splunk.ai/workload-type set ---
  # Without this, downstream scheduling silently breaks: weaviate / ray-head /
  # many operator-created workloads use nodeSelector: splunk.ai/workload-type=cpu
  # and will sit in Pending forever on a node that only has default labels.
  log "Verifying every node has splunk.ai/workload-type set..."
  local unlabeled
  unlabeled=$(kubectl get nodes -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.labels["splunk.ai/workload-type"] == null) | .metadata.name' 2>/dev/null \
    || echo "")
  if [[ -n "${unlabeled}" ]]; then
    # Last-chance recovery: re-iterate config IPs and label whichever matches.
    # This catches the case where resolve_node_name raced earlier in the run.
    warn "Found unlabeled node(s), attempting recovery:"
    echo "${unlabeled}" | while IFS= read -r nn; do
      warn "  - ${nn}"
    done
    for ip in "${CONTROLLER_IPS[@]}" "${WORKER_IPS[@]}"; do
      local nn
      nn=$(resolve_node_name "${ip}")
      [[ -z "${nn}" ]] && continue
      if echo "${unlabeled}" | grep -qx "${nn}"; then
        # Best-effort: apply CPU labels to the controller, CPU labels to
        # any worker whose index is < CPU_WORKER_COUNT, else GPU labels.
        # This duplicates a small amount of logic but keeps the recovery
        # path fully self-contained.
        local is_controller=false
        for cip in "${CONTROLLER_IPS[@]}"; do
          [[ "${cip}" == "${ip}" ]] && is_controller=true && break
        done
        if ${is_controller}; then
          log "  Recovery: labeling controller ${nn} (${ip})"
          kubectl label nodes "${nn}" \
            splunk.ai/node-role=controller \
            splunk.ai/workload-type=control-plane \
            node.kubernetes.io/role=controller \
            --overwrite || true
        else
          local wi=0
          for wip in "${WORKER_IPS[@]}"; do
            [[ "${wip}" == "${ip}" ]] && break
            wi=$((wi + 1))
          done
          if [[ ${wi} -lt ${CPU_WORKER_COUNT} ]]; then
            log "  Recovery: labeling CPU worker ${nn} (${ip})"
            kubectl label nodes "${nn}" \
              splunk.ai/node-role=worker \
              splunk.ai/workload-type=cpu \
              node.kubernetes.io/workload=ai-cpu \
              splunk.ai/instance-type=cpu-worker \
              --overwrite || true
          else
            log "  Recovery: labeling GPU worker ${nn} (${ip})"
            kubectl label nodes "${nn}" \
              splunk.ai/node-role=worker \
              splunk.ai/workload-type=gpu \
              node.kubernetes.io/workload=ai-gpu \
              splunk.ai/instance-type=gpu-worker \
              nvidia.com/gpu=true \
              --overwrite || true
          fi
        fi
      fi
    done

    # Re-check after recovery attempt.
    unlabeled=$(kubectl get nodes -o json 2>/dev/null \
      | jq -r '.items[] | select(.metadata.labels["splunk.ai/workload-type"] == null) | .metadata.name' 2>/dev/null \
      || echo "")
    if [[ -n "${unlabeled}" ]]; then
      err "Nodes still unlabeled after recovery pass:
$(echo "${unlabeled}" | sed 's/^/  /')

Workloads that select splunk.ai/workload-type=cpu (weaviate, ray-head,
most operator-managed pods) will stay Pending. Aborting."
    fi
    log "  ✓ Recovery successful — all nodes now have workload-type set"
  else
    log "  ✓ All nodes have splunk.ai/workload-type set"
  fi

  if [[ ${#labeling_failures[@]} -gt 0 ]]; then
    warn "label_nodes encountered ${#labeling_failures[@]} non-fatal issue(s):"
    for f in "${labeling_failures[@]}"; do warn "  - ${f}"; done
  fi

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

# ====== S3-COMPATIBLE OBJECT STORAGE CREDENTIALS ======
# Object storage is always customer-managed (external). This function creates
# the Kubernetes credentials secret so the operator and workloads can auth.
ensure_s3compat_credentials() {
  log "Creating credentials secret for S3-compatible object storage (${OBJ_STORE_TYPE})..."
  if [[ -z "${OBJ_STORE_ENDPOINT}" && -z "${MINIO_ENDPOINT}" ]]; then
    err "storage.objectStore.type=${OBJ_STORE_TYPE} requires storage.objectStore.endpoint"
    return 1
  fi
  if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
    err "S3-compatible storage requires credentials (objectStore.auth.rootPassword or MINIO_ROOT_PASSWORD)"
    return 1
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
  log "✓ S3-compatible credentials secret ${AI_NS}/${secret_name} ready"
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

  # Brief pause for webhook registration with API server
  log "Waiting for webhooks to stabilize (10s)..."
  sleep 10

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
# Per-node NVIDIA driver + container toolkit install (called in parallel).
#
# Error handling philosophy:
#   - `set -euo pipefail` inside every remote block so the first real failure
#     aborts the node install immediately.
#   - NO blanket `|| true` / `2>/dev/null` on installer commands — failures
#     are loud and caught.
#   - After install, strict verification gates hard-fail if the artifacts
#     aren't where they should be (nvidia-smi works, libnvidia-ml.so exists,
#     nvidia-ctk present, CDI spec populated).
#   - RHEL 9 and RHEL 10 paths are deliberately symmetric: both install EPEL,
#     both install DKMS, both clean stale cross-major CUDA repos.
#
# Returns 0 on fully-successful install, non-zero on any verification failure.
_install_nvidia_on_node() {
  local gpu_ip="$1"

  # ---- Phase A: detect if driver is already installed ---------------------
  local driver_ver=""
  if ssh_exec "${gpu_ip}" "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=driver_version --format=csv,noheader" 2>/dev/null; then
    driver_ver=$(ssh_exec "${gpu_ip}" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1") || driver_ver=""
  fi

  if [[ -n "${driver_ver}" ]]; then
    echo "✓ NVIDIA driver already installed on ${gpu_ip} (version: ${driver_ver})"
  else
    echo "Installing NVIDIA driver on ${gpu_ip}..."

    # ---- Phase B: install driver + supporting packages --------------------
    # `set -euo pipefail` means ANY failure aborts the block. Each step below
    # must either succeed or have an explicit fallback branch that succeeds.
    if ! ssh_exec "${gpu_ip}" "
      set -euo pipefail

      # --- OS detection (RHEL 9, RHEL 10, Amazon Linux 2023, Debian/Ubuntu) ---
      # OS_VERSION holds the numeric major we use to build the CUDA+EPEL URLs.
      # For RHEL we read %{rhel}; for Amazon Linux 2023 we hardcode 9 because
      # AL2023 is binary-compatible with RHEL/Fedora 9's nvidia-driver RPMs
      # and the Fedora EPEL9 repo is the standard 3rd-party source.
      echo '--- OS detection ---'
      OS_FAMILY=
      OS_VERSION=
      if grep -qiE '^ID=\"?amzn\"?' /etc/os-release 2>/dev/null; then
        OS_FAMILY=amzn
        OS_VERSION=\$(. /etc/os-release; echo \"\${VERSION_ID%%.*}\")
      elif [ -f /etc/redhat-release ]; then
        OS_FAMILY=rhel
        OS_VERSION=\$(rpm -E %{rhel})
      elif [ -f /etc/debian_version ]; then
        OS_FAMILY=debian
      fi
      if [ -z \"\${OS_FAMILY}\" ]; then
        echo 'ERROR: unsupported OS (not amzn/rhel/debian)' >&2
        cat /etc/os-release >&2 || true
        exit 1
      fi
      echo \"OS_FAMILY=\${OS_FAMILY}  OS_VERSION=\${OS_VERSION:-n/a}\"

      # --- Step 1: kernel headers (required for DKMS to build nvidia kmod) ---
      KREL=\$(uname -r)
      echo \"--- Installing kernel headers for kernel \${KREL} ---\"
      if [ \"\${OS_FAMILY}\" = 'debian' ]; then
        sudo apt-get update -qq
        sudo apt-get install -y \"linux-headers-\${KREL}\"
      else
        # Exact-match: every historical kernel-devel is usually in RHUI for
        # RHEL 9/10. Fall back to the latest only when absent (rare).
        if ! sudo dnf install -y \"kernel-devel-\${KREL}\" \"kernel-headers-\${KREL}\"; then
          echo \"WARN: Exact kernel-devel-\${KREL} not found; installing latest kernel-devel/headers.\"
          echo \"      DKMS will build against the latest headers — if they don't match the running kernel,\"
          echo \"      modprobe will fail below and you'll need to reboot into the updated kernel.\"
          sudo dnf install -y kernel-devel kernel-headers
        fi
      fi

      # --- Step 2: EPEL + DKMS + build toolchain ----------------------------
      # DKMS builds the nvidia kernel module from source on every kernel
      # update. It needs: dkms (from EPEL), gcc, make, elfutils-libelf-devel.
      # On a BARE RHEL minimal install, NONE of these are pre-installed.
      # On AWS AMIs they may be partially pre-installed but we should not
      # rely on that — be explicit.
      if [ \"\${OS_FAMILY}\" = 'rhel' ] || [ \"\${OS_FAMILY}\" = 'amzn' ]; then
        # EPEL: AL2023 = EPEL9 (binary-compat). RHEL: matching major.
        if [ \"\${OS_FAMILY}\" = 'amzn' ]; then
          EPEL_MAJOR=9
        else
          EPEL_MAJOR=\${OS_VERSION}
        fi

        # dnf-plugins-core provides 'dnf config-manager'. Pre-installed on
        # most AMIs; install explicitly for minimal images.
        sudo dnf install -y dnf-plugins-core

        # EPEL: provides DKMS on RHEL (RHEL's own repos don't ship DKMS).
        if ! rpm -q epel-release >/dev/null 2>&1; then
          echo \"--- Installing EPEL for DKMS (major \${EPEL_MAJOR}) ---\"
          sudo dnf install -y \"https://dl.fedoraproject.org/pub/epel/epel-release-latest-\${EPEL_MAJOR}.noarch.rpm\"
        fi
        # CRB (formerly PowerTools on RHEL 8) hosts a few EPEL build deps on
        # RHEL. AL2023 doesn't have a CRB repo (its core packages are in
        # 'amazonlinux' directly), so this whole chain is best-effort — the
        # trailing '|| true' only runs when ALL three names fail to match
        # any known repo, which is the expected state on AL2023.
        sudo dnf config-manager --set-enabled crb 2>/dev/null \\
          || sudo dnf config-manager --set-enabled PowerTools 2>/dev/null \\
          || sudo dnf config-manager --set-enabled powertools 2>/dev/null \\
          || true

        # DKMS + the build toolchain. Being explicit means a minimal / bare
        # RHEL install works out-of-the-box and future driver versions
        # with different weak-deps don't silently miss a needed package.
        echo '--- Installing DKMS + build toolchain (gcc, make, elfutils-libelf-devel) ---'
        sudo dnf install -y dkms gcc make elfutils-libelf-devel
      fi

      # --- Step 3: CUDA repo for the right OS family + version --------------
      # Clean cross-major repos so dnf doesn't try to install from the wrong
      # CUDA metadata (common failure mode on in-place RHEL 9 → 10 upgrades,
      # and on re-runs of this script where the target OS may have changed).
      if [ \"\${OS_FAMILY}\" = 'amzn' ]; then
        sudo rm -f /etc/yum.repos.d/cuda-amzn*.repo
        sudo dnf config-manager --add-repo \\
          \"https://developer.download.nvidia.com/compute/cuda/repos/amzn\${OS_VERSION:-2023}/x86_64/cuda-amzn\${OS_VERSION:-2023}.repo\"
      elif [ \"\${OS_FAMILY}\" = 'rhel' ]; then
        sudo rm -f /etc/yum.repos.d/cuda-rhel*.repo
        sudo dnf config-manager --add-repo \\
          \"https://developer.download.nvidia.com/compute/cuda/repos/rhel\${OS_VERSION}/x86_64/cuda-rhel\${OS_VERSION}.repo\"
      elif [ \"\${OS_FAMILY}\" = 'debian' ]; then
        curl -fsSL \\
          https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \\
          -o /tmp/cuda-keyring.deb
        sudo dpkg -i /tmp/cuda-keyring.deb
        sudo apt-get update -qq
      fi

      # --- Step 4: install the driver -------------------------------------
      # Follows NVIDIA's official RHEL install guidance:
      # https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/
      #
      # Package names in the CUDA repo (rhel9/rhel10/amzn2023):
      #   - cuda-drivers                -> meta-pkg for proprietary driver
      #                                    (pulls nvidia-driver, kmod-nvidia-latest-dkms,
      #                                    nvidia-driver-cuda, nvidia-driver-libs,
      #                                    libnvidia-ml, etc.)
      #   - nvidia-open                 -> meta-pkg for open-source kernel driver
      #   - nvidia-driver:latest-dkms   -> RHEL 9 only (dnf modular stream).
      #                                    Removed in RHEL 10 (modularity deprecated).
      #
      # There is NO package called 'nvidia-driver-dkms' in either repo —
      # previous attempts at it failed on every fresh install.
      # 
      # Strategy: single meta-package install. RHEL 10 requires --allowerasing
      # because it has to remove conflicting nouveau packages. The flag is
      # a no-op on RHEL 9/AL2023 where there's nothing to erase.
      echo '--- Installing NVIDIA driver (meta package: cuda-drivers) ---'
      if [ \"\${OS_FAMILY}\" = 'debian' ]; then
        sudo apt-get install -y nvidia-driver-550
      else
        # Blacklist nouveau so the new nvidia driver can load without fighting it.
        # Harmless if nouveau isn't loaded (grep returns nothing).
        if lsmod | grep -q '^nouveau'; then
          echo '--- Blacklisting nouveau + unloading ---'
          echo -e 'blacklist nouveau\\noptions nouveau modeset=0' \\
            | sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null
          sudo rmmod nouveau 2>/dev/null || true
          # Regenerate initramfs so nouveau doesn't come back on reboot.
          sudo dracut --force 2>/dev/null || true
        fi

        # Primary strategy: cuda-drivers meta-package (works on RHEL 9, RHEL 10,
        # AL2023 — the CUDA repo ships the same package name everywhere).
        if sudo dnf install -y --allowerasing cuda-drivers; then
          echo '✓ Installed cuda-drivers meta-package'
        elif [ \"\${OS_VERSION}\" = '9' ] && sudo dnf module install -y nvidia-driver:latest-dkms; then
          # RHEL 9 fallback: classic dnf module stream (RHEL 10 dropped modularity).
          # Kept as a safety net — cuda-drivers should always work above.
          echo '✓ Installed nvidia-driver:latest-dkms via dnf module (RHEL 9 legacy path)'
        elif sudo dnf install -y --allowerasing nvidia-open; then
          # Last-resort fallback: open-source kernel driver.
          echo '✓ Installed nvidia-open (open-kernel fallback)'
        else
          echo 'ERROR: all NVIDIA driver install strategies failed' >&2
          echo '  Tried: cuda-drivers, nvidia-driver:latest-dkms (module), nvidia-open' >&2
          echo '  Possible causes:' >&2
          echo '    - CUDA repo URL incorrect for OS version \${OS_VERSION}' >&2
          echo '    - EPEL/DKMS not available' >&2
          echo '    - Network blocked to developer.download.nvidia.com' >&2
          exit 1
        fi
      fi

      # --- Step 5: verify DKMS built + load kmod ---------------------------
      # Before modprobe: check dkms status so we catch kernel-mismatch cases
      # early with a clear error instead of the cryptic 'Module not found'.
      echo '--- Verifying DKMS status + loading nvidia kmod ---'
      if [ \"\${OS_FAMILY}\" != 'debian' ]; then
        DKMS_OUT=\$(sudo dkms status 2>&1 | grep nvidia || true)
        if [ -z \"\${DKMS_OUT}\" ]; then
          echo 'ERROR: dkms status shows no nvidia entry — driver install did not register with DKMS' >&2
          exit 1
        fi
        echo \"DKMS: \${DKMS_OUT}\"
        if ! echo \"\${DKMS_OUT}\" | grep -qE 'installed|built'; then
          echo 'ERROR: nvidia DKMS module is not installed/built. See: sudo dkms status; dmesg | grep nvidia' >&2
          exit 1
        fi
        # Check the built-for kernel matches the running kernel. If not,
        # a reboot into the newer installed kernel is required — DO NOT pretend
        # modprobe will work. This is exactly what prevents false-positive
        # 'install succeeded' on nodes that had a pending kernel update.
        if ! echo \"\${DKMS_OUT}\" | grep -qF \"\${KREL}\"; then
          echo \"ERROR: DKMS built nvidia module for a different kernel than \${KREL}.\" >&2
          echo \"       'sudo dkms status' shows: \${DKMS_OUT}\" >&2
          echo \"       Action: reboot the node into the kernel DKMS built for, then re-run.\" >&2
          exit 1
        fi
      fi
      sudo modprobe nvidia || {
        echo 'ERROR: modprobe nvidia failed after DKMS build succeeded.' >&2
        echo 'Diagnose with: sudo dmesg | grep -i nvidia | tail -30' >&2
        exit 1
      }
    "; then
      echo "❌ NVIDIA driver install failed on ${gpu_ip}" >&2
      return 1
    fi

    # ---- Phase C: hard-verify driver actually works -----------------------
    local ver_check
    ver_check=$(ssh_exec "${gpu_ip}" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1 | head -1" || echo "")
    if [[ -z "${ver_check}" ]] || ! [[ "${ver_check}" =~ ^[0-9]+\.[0-9]+ ]]; then
      echo "❌ nvidia-smi verification failed on ${gpu_ip} (got: '${ver_check}')" >&2
      return 1
    fi
    echo "✓ NVIDIA driver v${ver_check} running on ${gpu_ip}"
  fi

  # ---- Phase D: NVIDIA Container Toolkit install ------------------------
  echo "Installing NVIDIA Container Toolkit on ${gpu_ip}..."
  if ! ssh_exec "${gpu_ip}" "
    set -euo pipefail
    if command -v nvidia-ctk >/dev/null 2>&1; then
      echo '✓ nvidia-ctk already installed (version: '\"\$(nvidia-ctk --version 2>/dev/null | head -1)\"')'
    else
      echo '--- Adding NVIDIA container-toolkit repo ---'
      if [ -f /etc/debian_version ]; then
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
          sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
          sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
          sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y nvidia-container-toolkit
      else
        # RHEL 9 and 10 both use the same libnvidia-container stable RPM repo.
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
          sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
        sudo dnf install -y nvidia-container-toolkit
      fi
    fi

    # --- Configure k0s containerd (k0s uses /run/k0s/containerd.sock) ----
    # Strategy (compatible with nvidia-ctk >= 1.14, validated against 1.19):
    #
    #   1. Run \`nvidia-ctk runtime configure --runtime=containerd
    #      --nvidia-set-as-default\` with NO --config= flag. This makes
    #      nvidia-ctk emit a complete, correct drop-in at its known-good
    #      default path /etc/containerd/conf.d/99-nvidia.toml, containing:
    #
    #        - version = 2
    #        - plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia
    #        - default_runtime_name = \"nvidia\"
    #
    #   2. On k0s nodes, we cannot leave that file at its default path
    #      because k0s's managed /etc/k0s/containerd.toml only imports
    #      /etc/k0s/containerd.d/*.toml — anything under
    #      /etc/containerd/conf.d/ is ignored. So we move it.
    #
    # We deliberately avoid passing --config= pointing at the k0s drop-in,
    # because nvidia-ctk 1.19 treats the --config target as a \"main\"
    # containerd config and only writes a two-line stub (imports + version)
    # into it, emitting the actual runtime config to /etc/containerd/conf.d/
    # regardless. That silent behavior caused the 'containerd-nvidia-runtime:
    # FAIL' verification error that reaching here used to surface.
    echo '--- Configuring containerd runtime for nvidia ---'
    if [ -d /etc/k0s/containerd.d ]; then
      sudo mkdir -p /etc/k0s/containerd.d

      # Preserve any existing drop-in so idempotent re-runs don't lose
      # hand-tuned configuration.
      if [ -s /etc/k0s/containerd.d/nvidia.toml ]; then
        sudo cp -a /etc/k0s/containerd.d/nvidia.toml /etc/k0s/containerd.d/nvidia.toml.bak
      fi

      # Wipe any previous output so we can tell whether this invocation
      # actually produced a file.
      sudo rm -f /etc/containerd/conf.d/99-nvidia.toml

      # Generate the canonical drop-in at nvidia-ctk's default path. We
      # rely on --nvidia-set-as-default to inject default_runtime_name.
      sudo nvidia-ctk runtime configure \\
        --runtime=containerd \\
        --nvidia-set-as-default

      # Hard-fail if the file is missing or empty.
      if [ ! -s /etc/containerd/conf.d/99-nvidia.toml ]; then
        echo 'ERROR: nvidia-ctk did not produce /etc/containerd/conf.d/99-nvidia.toml' >&2
        echo 'nvidia-ctk --version:' >&2
        nvidia-ctk --version 2>&1 | head -3 >&2
        exit 1
      fi

      # Verify the generated drop-in actually names nvidia as the default
      # runtime. Earlier nvidia-ctk versions (< 1.14) ignored
      # --nvidia-set-as-default silently.
      if ! sudo grep -q 'default_runtime_name = \"nvidia\"' /etc/containerd/conf.d/99-nvidia.toml; then
        echo 'ERROR: nvidia-ctk drop-in does not set default_runtime_name = \"nvidia\".' >&2
        echo 'nvidia-ctk --version:' >&2
        nvidia-ctk --version 2>&1 | head -3 >&2
        echo '--- generated drop-in (first 30 lines) ---' >&2
        sudo head -30 /etc/containerd/conf.d/99-nvidia.toml >&2
        exit 1
      fi

      # Relocate the drop-in from nvidia-ctk's default path to the path
      # that k0s's managed containerd.toml imports. We strip keys that
      # would duplicate declarations already made by k0s's top-level
      # config (version / imports / disabled_plugins / required_plugins);
      # leaving them in place causes containerd to refuse to start with
      # duplicate top-level-key errors.
      sudo mv /etc/containerd/conf.d/99-nvidia.toml /etc/k0s/containerd.d/nvidia.toml
      sudo sed -i '/^version/d; /^imports/d; /^disabled_plugins/d; /^required_plugins/d' \\
        /etc/k0s/containerd.d/nvidia.toml

      # Final sanity: the k0s drop-in must still carry default_runtime_name
      # after the key-strip above (it lives under a nested table, not at
      # top level, so the sed above never touches it — but verify anyway
      # so failure is loud instead of silently broken).
      if ! sudo grep -q 'default_runtime_name = \"nvidia\"' /etc/k0s/containerd.d/nvidia.toml; then
        echo 'ERROR: /etc/k0s/containerd.d/nvidia.toml lost default_runtime_name after relocation.' >&2
        echo '--- file contents ---' >&2
        sudo cat /etc/k0s/containerd.d/nvidia.toml >&2
        exit 1
      fi
    elif [ -f /etc/containerd/config.toml ]; then
      # Non-k0s containerd (standalone) — safe to let nvidia-ctk edit in place.
      sudo nvidia-ctk runtime configure --runtime=containerd --nvidia-set-as-default
    else
      echo 'ERROR: no containerd config dir found at /etc/k0s/containerd.d or /etc/containerd/config.toml' >&2
      exit 1
    fi

    # --- Generate the CDI spec so k8s device plugin can find the GPUs ---
    echo '--- Generating CDI spec ---'
    sudo mkdir -p /etc/cdi
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    if [ ! -s /etc/cdi/nvidia.yaml ]; then
      echo 'ERROR: /etc/cdi/nvidia.yaml empty after generation' >&2
      exit 1
    fi
    # Sanity-check that NVML could enumerate at least one device (without
    # this, the spec contains no devices and the device plugin crash-loops).
    if ! grep -q 'name: ' /etc/cdi/nvidia.yaml; then
      echo 'ERROR: /etc/cdi/nvidia.yaml contains no device entries' >&2
      cat /etc/cdi/nvidia.yaml | head -40 >&2
      exit 1
    fi

    # --- Restart k0sworker to pick up new runtime + CDI spec -----------
    echo '--- Restarting k0sworker to pick up runtime changes ---'
    sudo systemctl stop k0sworker || true
    sleep 3
    sudo pkill -9 containerd-shim || true
    sudo rm -f /run/k0s/containerd.sock || true
    sudo systemctl start k0sworker

    # Quick sanity: confirm nvidia-ctk + libnvidia-ml.so exist where expected.
    # Search all known paths (distributions differ): RHEL/Fedora use
    # /usr/lib64, Debian/Ubuntu use /usr/lib/x86_64-linux-gnu, and
    # some distros also expose it via ldconfig.
    echo '--- Post-install sanity ---'
    nvidia-ctk --version | head -1
    LIBNVML_PATH=\$(ldconfig -p 2>/dev/null | awk '/libnvidia-ml\\.so\\.1/ {print \$NF; exit}')
    if [ -z \"\${LIBNVML_PATH}\" ]; then
      for so in /usr/lib64/libnvidia-ml.so.1 \\
                /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 \\
                /usr/lib/libnvidia-ml.so.1; do
        if [ -e \"\${so}\" ]; then LIBNVML_PATH=\"\${so}\"; break; fi
      done
    fi
    if [ -n \"\${LIBNVML_PATH}\" ]; then
      echo \"✓ libnvidia-ml.so.1 found: \${LIBNVML_PATH}\"
    else
      echo 'ERROR: libnvidia-ml.so.1 not found on any standard path.' >&2
      exit 1
    fi
  "; then
    echo "❌ Container toolkit setup failed on ${gpu_ip}" >&2
    return 1
  fi

  # ---- Phase E: post-install strict verification -----------------------
  # These checks are what the device plugin will actually need at runtime.
  local checks_out
  checks_out=$(ssh_exec "${gpu_ip}" "
    set +e
    echo -n 'nvidia-smi: '
    nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1 && echo OK || echo FAIL
    echo -n 'libnvidia-ml.so: '
    # Check ldconfig cache first (most reliable), then fall back to the
    # common per-distribution install paths.
    if ldconfig -p 2>/dev/null | grep -q 'libnvidia-ml\.so\.1'; then
      echo OK
    elif ls /usr/lib64/libnvidia-ml.so.1 \\
           /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 \\
           /usr/lib/libnvidia-ml.so.1 2>/dev/null | head -1 | grep -q .; then
      echo OK
    else
      echo FAIL
    fi
    echo -n 'nvidia-ctk: '
    command -v nvidia-ctk >/dev/null 2>&1 && echo OK || echo FAIL
    echo -n 'cdi-spec: '
    [ -s /etc/cdi/nvidia.yaml ] && grep -q 'name: ' /etc/cdi/nvidia.yaml && echo OK || echo FAIL
    echo -n 'nvidia-kmod: '
    lsmod | grep -q '^nvidia ' && echo OK || echo FAIL
    echo -n 'containerd-nvidia-runtime: '
    grep -q 'default_runtime_name = \"nvidia\"' /etc/k0s/containerd.d/nvidia.toml 2>/dev/null && echo OK || echo FAIL
  ")

  echo "Strict verification on ${gpu_ip}:"
  echo "${checks_out}" | sed 's/^/    /'
  if echo "${checks_out}" | grep -q FAIL; then
    echo "❌ Strict verification failed on ${gpu_ip} — device plugin will crash-loop with ERROR_LIBRARY_NOT_FOUND" >&2
    return 1
  fi
  echo "✓ Strict verification passed on ${gpu_ip}"
  return 0
}

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

  # Run driver + toolkit install on all GPU nodes in parallel
  log "Installing NVIDIA drivers on ${#gpu_ips[@]} GPU node(s) in parallel..."
  local pids=()
  local logdir
  logdir=$(mktemp -d)

  for gpu_ip in "${gpu_ips[@]}"; do
    (
      _install_nvidia_on_node "${gpu_ip}" > "${logdir}/${gpu_ip}.log" 2>&1
      echo $? > "${logdir}/${gpu_ip}.rc"
    ) &
    pids+=($!)
    log "  Started NVIDIA install on ${gpu_ip} (pid $!)"
  done

  # Wait for all background installs to finish
  local failed=0
  for i in "${!pids[@]}"; do
    local pid=${pids[$i]}
    local gpu_ip=${gpu_ips[$i]}
    if wait "${pid}"; then
      log "  ✓ NVIDIA setup completed on ${gpu_ip}"
    else
      warn "  NVIDIA setup on ${gpu_ip} had issues"
      failed=$((failed + 1))
    fi
    # Stream the per-node log so output is visible
    while IFS= read -r line; do
      log "    [${gpu_ip}] ${line}"
    done < "${logdir}/${gpu_ip}.log"
  done

  rm -rf "${logdir}"

  if [[ ${failed} -gt 0 ]]; then
    err "${failed}/${#gpu_ips[@]} GPU node(s) had NVIDIA install failures. Aborting install.
    
    What to check on a failing node:
      ssh <node> 'dkms status | grep nvidia'             # must show 'installed'
      ssh <node> 'lsmod | grep nvidia'                   # must list nvidia kmod
      ssh <node> 'ls /usr/lib64/libnvidia-ml.so.1'       # must exist
      ssh <node> 'nvidia-ctk --version'                  # must work
      ssh <node> 'cat /etc/cdi/nvidia.yaml | head -40'   # must list GPU devices
      ssh <node> 'sudo dmesg | grep -i nvidia | tail -30'# kernel-level errors
    
    Common causes:
      - kernel-devel for running kernel not available (exact match too new);
        reboot to match a released kernel, then re-run
      - EPEL/DKMS didn't install (check 'rpm -q epel-release dkms')
      - Stale /etc/yum.repos.d/cuda-rhel*.repo from a prior OS upgrade"
  else
    log "NVIDIA drivers installed successfully on all ${#gpu_ips[@]} GPU node(s)"
  fi

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
    err "Some GPU nodes did not become Ready within ${gpu_wait_timeout}s. Check: kubectl get nodes"
  fi

  # Verify GPUs are visible to Kubernetes. If the device-plugin DaemonSet
  # isn't installed yet (expected during the initial install — it's created
  # by install_nvidia_device_plugin() in Phase 2), short-circuit immediately
  # instead of waiting a fruitless 120s. For idempotent re-runs where the
  # DS is already present we poll up to 120s.
  if ! kubectl -n kube-system get ds nvidia-device-plugin-daemonset &>/dev/null; then
    log "  (device plugin DaemonSet not yet installed; capacity will appear after install_nvidia_device_plugin runs)"
    log "NVIDIA host driver installation complete"
    return 0
  fi

  log "Checking if GPUs are visible to Kubernetes..."
  local gpu_capacity="0"
  local cap_wait=0
  local cap_timeout=120
  while [[ ${cap_wait} -lt ${cap_timeout} ]]; do
    gpu_capacity=$(kubectl get nodes -l splunk.ai/workload-type=gpu -o json 2>/dev/null | \
      jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add' 2>/dev/null || echo "0")
    if [[ "${gpu_capacity}" -gt 0 ]]; then
      log "✓ Total GPUs visible to Kubernetes: ${gpu_capacity}"
      break
    fi
    sleep 10
    cap_wait=$((cap_wait + 10))
    log "  Waiting for GPU capacity to be reported... ${cap_wait}/${cap_timeout}s"
  done

  if [[ "${gpu_capacity}" -le 0 ]]; then
    err "Device plugin DaemonSet is installed but no GPUs are visible after ${cap_timeout}s.
    Investigate with:
      kubectl -n kube-system logs ds/nvidia-device-plugin-daemonset --tail 40
      kubectl -n kube-system describe pod -l name=nvidia-device-plugin-ds"
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

  # Create the nvidia RuntimeClass FIRST. The device-plugin DaemonSet we
  # apply below references this RuntimeClass via runtimeClassName=nvidia, so
  # it must exist before any DS pod is scheduled — otherwise kubelet will
  # reject the pod with 'RuntimeClass "nvidia" not found'.
  log "  Creating nvidia RuntimeClass..."
  cat <<'RTEOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
RTEOF

  # Fetch the upstream manifest into a temp file, inject our required
  # pod-spec fields (nodeSelector + runtimeClassName) BEFORE applying.
  # Doing this in one shot — instead of apply-then-patch — avoids the
  # race where the initial DS pods start under the default runtime
  # (runc), hit 'ERROR_LIBRARY_NOT_FOUND' because they have no access to
  # libnvidia-ml.so or /dev/nvidia*, and land in CrashLoopBackOff before
  # the patch ever reaches them.
  local manifest
  manifest=$(mktemp)
  if ! curl -fsSL \
      "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${ver}/deployments/static/nvidia-device-plugin.yml" \
      -o "${manifest}"; then
    rm -f "${manifest}"
    err "Failed to fetch NVIDIA device-plugin manifest from GitHub (version ${ver}).
    Check network connectivity and that version ${ver} exists upstream."
  fi

  log "  Patching manifest in place: GPU nodeSelector + nvidia runtimeClassName..."
  # Use yq when available (cleanest, structure-aware); fall back to kubectl
  # patch --local on stdout — both produce the same patched manifest on
  # stdout which we then `apply -f -`.
  local patched
  patched=$(mktemp)
  if command -v yq >/dev/null 2>&1; then
    yq eval '
      (select(.kind == "DaemonSet") | .spec.template.spec.nodeSelector."splunk.ai/workload-type") = "gpu"
      | (select(.kind == "DaemonSet") | .spec.template.spec.runtimeClassName) = "nvidia"
    ' "${manifest}" > "${patched}"
  else
    # Fallback: use kubectl patch --local. This requires reading from the
    # manifest and piping through patch; multi-document files complicate
    # things, but this upstream manifest is a single DaemonSet.
    kubectl patch -f "${manifest}" --local -o yaml \
      --type='json' \
      -p='[
        {"op": "add", "path": "/spec/template/spec/nodeSelector", "value": {"splunk.ai/workload-type": "gpu"}},
        {"op": "add", "path": "/spec/template/spec/runtimeClassName", "value": "nvidia"}
      ]' > "${patched}"
  fi

  if ! kubectl apply -n kube-system -f "${patched}"; then
    rm -f "${manifest}" "${patched}"
    err "Failed to apply patched NVIDIA device-plugin manifest. Check kubectl connectivity."
  fi
  rm -f "${manifest}" "${patched}"

  # Wait for the DS to roll out so the caller observes GPU capacity as
  # soon as possible. Non-fatal: we verify capacity explicitly upstream
  # via the strict-verification loop.
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
    --version 1.2.2 \
    --set image.repository=quay.io/kuberay/operator \
    --set image.tag=v1.2.2 \
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
}

# ====== ECR CREDENTIAL REFRESHER CRONJOB ======
# ECR tokens expire every 12 hours. This CronJob refreshes the ecr-registry-secret
# in all relevant namespaces every 6 hours so image pulls never break.
install_ecr_credential_refresher() {
  if [[ "${IMAGE_PULL_SECRETS_ECR_ENABLED}" != "true" ]]; then
    log "ECR not enabled — skipping credential refresher"
    return 0
  fi

  local ecr_region="${ECR_REGION:-${REGION:-us-east-2}}"
  local ecr_account="${ECR_ACCOUNT}"

  if [[ -z "${ecr_account}" ]]; then
    warn "ECR account not configured — skipping credential refresher"
    return 0
  fi

  local ecr_server="${ecr_account}.dkr.ecr.${ecr_region}.amazonaws.com"
  local refresher_ns="${AI_NS}"
  local target_namespaces="${AI_NS} splunk-ai-operator-system"

  # Resolve AWS credentials (env > aws configure)
  local aws_key="${AWS_ACCESS_KEY_ID:-}"
  local aws_secret="${AWS_SECRET_ACCESS_KEY:-}"
  local aws_session="${AWS_SESSION_TOKEN:-}"

  if [[ -z "$aws_key" ]]; then
    aws_key=$(aws configure get aws_access_key_id 2>/dev/null || echo "")
  fi
  if [[ -z "$aws_secret" ]]; then
    aws_secret=$(aws configure get aws_secret_access_key 2>/dev/null || echo "")
  fi

  if [[ -z "$aws_key" ]] || [[ -z "$aws_secret" ]]; then
    warn "AWS credentials not available — skipping ECR credential refresher CronJob"
    warn "ECR tokens will expire after 12 hours. Refresh ecr-registry-secret manually."
    return 0
  fi

  if [[ -n "$aws_session" ]]; then
    warn "Detected temporary AWS credentials (session token present)"
    warn "ECR refresher CronJob will work until these session credentials expire"
    warn "For long-term use, configure an IAM user with ecr:GetAuthorizationToken permission"
  fi

  log "Installing ECR credential refresher CronJob..."

  # Store AWS credentials in a secret for the CronJob to use
  local secret_args=(
    --from-literal=AWS_ACCESS_KEY_ID="${aws_key}"
    --from-literal=AWS_SECRET_ACCESS_KEY="${aws_secret}"
  )
  [[ -n "$aws_session" ]] && secret_args+=(--from-literal=AWS_SESSION_TOKEN="${aws_session}")

  kubectl -n "${refresher_ns}" create secret generic aws-ecr-credentials \
    "${secret_args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Pre-build the optional SESSION_TOKEN env block
  local session_token_env=""
  if [[ -n "$aws_session" ]]; then
    session_token_env="
            - name: AWS_SESSION_TOKEN
              valueFrom:
                secretKeyRef:
                  name: aws-ecr-credentials
                  key: AWS_SESSION_TOKEN
                  optional: true"
  fi

  # Deploy ServiceAccount, RBAC, and CronJob
  cat <<CRONEOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ecr-credential-refresher
  namespace: ${refresher_ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ecr-credential-refresher
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ecr-credential-refresher
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ecr-credential-refresher
subjects:
- kind: ServiceAccount
  name: ecr-credential-refresher
  namespace: ${refresher_ns}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ecr-credential-refresher
  namespace: ${refresher_ns}
spec:
  schedule: "0 */6 * * *"
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Replace
  jobTemplate:
    spec:
      backoffLimit: 3
      template:
        spec:
          serviceAccountName: ecr-credential-refresher
          restartPolicy: OnFailure
          containers:
          - name: refresher
            image: amazon/aws-cli:latest
            command:
            - /bin/bash
            - -ec
            - |
              echo "Refreshing ECR credentials..."
              ECR_TOKEN=\$(aws ecr get-login-password --region "\${ECR_REGION}")
              AUTH=\$(echo -n "AWS:\${ECR_TOKEN}" | base64 -w0)
              DOCKERCFG=\$(printf '{"auths":{"%s":{"username":"AWS","password":"%s","auth":"%s"}}}' "\${ECR_SERVER}" "\${ECR_TOKEN}" "\${AUTH}" | base64 -w0)

              K8S_TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              K8S_CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              K8S_API="https://kubernetes.default.svc"

              for NS in \${TARGET_NAMESPACES}; do
                echo "  Updating ecr-registry-secret in \${NS}..."
                SECRET_JSON=\$(printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"ecr-registry-secret","namespace":"%s"},"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":"%s"}}' "\${NS}" "\${DOCKERCFG}")

                HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" \
                  -H "Authorization: Bearer \${K8S_TOKEN}" \
                  --cacert \${K8S_CA} \
                  "\${K8S_API}/api/v1/namespaces/\${NS}/secrets/ecr-registry-secret")

                if [ "\${HTTP_CODE}" = "200" ]; then
                  curl -sf -X PUT \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer \${K8S_TOKEN}" \
                    --cacert \${K8S_CA} \
                    "\${K8S_API}/api/v1/namespaces/\${NS}/secrets/ecr-registry-secret" \
                    -d "\${SECRET_JSON}" > /dev/null
                  echo "    Updated existing secret"
                else
                  curl -sf -X POST \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer \${K8S_TOKEN}" \
                    --cacert \${K8S_CA} \
                    "\${K8S_API}/api/v1/namespaces/\${NS}/secrets" \
                    -d "\${SECRET_JSON}" > /dev/null
                  echo "    Created new secret"
                fi
              done
              echo "ECR credential refresh complete"
            env:
            - name: ECR_REGION
              value: "${ecr_region}"
            - name: ECR_SERVER
              value: "${ecr_server}"
            - name: TARGET_NAMESPACES
              value: "${target_namespaces}"
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: aws-ecr-credentials
                  key: AWS_ACCESS_KEY_ID
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: aws-ecr-credentials
                  key: AWS_SECRET_ACCESS_KEY${session_token_env}
CRONEOF

  log "✓ ECR credential refresher CronJob installed (schedule: every 6 hours)"

  # Trigger an immediate run to ensure fresh credentials right now
  log "Running initial credential refresh..."
  kubectl -n "${refresher_ns}" delete job ecr-initial-refresh --ignore-not-found=true 2>/dev/null || true
  kubectl -n "${refresher_ns}" create job --from=cronjob/ecr-credential-refresher ecr-initial-refresh 2>/dev/null || true

  # Wait for the initial job to complete (up to 2 minutes)
  if kubectl -n "${refresher_ns}" wait --for=condition=complete job/ecr-initial-refresh --timeout=120s 2>/dev/null; then
    log "✓ Initial ECR credential refresh completed successfully"
  else
    warn "Initial ECR refresh may still be running — pods should recover once it completes"
  fi
}

# ====== INSTALL SPLUNK STANDALONE ======
install_splunk_standalone() {
  log "Installing Splunk Standalone: ${AI_STANDALONE_NAME} in ${AI_NS}..."

  ensure_namespace "${AI_NS}"
  wait_for_crd standalones.enterprise.splunk.com 600

  # Ensure credentials secret exists for Splunk App Framework
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

  # Standalone app repo: uses customer-managed S3-compatible object storage
  local minio_endpoint="${MINIO_ENDPOINT:-${OBJ_STORE_ENDPOINT}}"
  cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  replicas: 1
  etcVolumeStorageConfig:
    storageClassName: ${STORAGE_CLASS}
  varVolumeStorageConfig:
    storageClassName: ${STORAGE_CLASS}
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

  log "Splunk Standalone CR applied (pod starts in background)"
}

# Blocks until Splunk Standalone pod is ready. Called at the end of the
# install flow so the operator and CR can deploy while Splunk boots.
wait_for_splunk_standalone() {
  log "Waiting for Splunk Standalone to be ready..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=${AI_STANDALONE_NAME} -n ${AI_NS} --timeout=600s || true
  log "Splunk Standalone is ready"
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
  log "Creating/updating S3-compatible credentials secret (minio-credentials) in ${AI_NS}..."
  kubectl -n "${AI_NS}" create secret generic minio-credentials \
    --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
    --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
    --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
    --from-literal=MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" \
    --from-literal=MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
    --dry-run=client -o yaml | kubectl -n "${AI_NS}" apply -f -
  log "✓ Object storage credentials secret ready"

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

  # objectStorage: path/endpoint/secret by object store type (aws | s3compat | minio | seaweedfs)
  local obj_path obj_endpoint obj_secret
  obj_secret="minio-credentials"
  case "${OBJ_STORE_TYPE}" in
    s3compat)
      obj_path="s3compat://${OBJ_STORE_BUCKET}"
      obj_endpoint="${OBJ_STORE_ENDPOINT}"
      ;;
    minio)
      obj_path="minio://${MINIO_BUCKET}"
      obj_endpoint="${MINIO_ENDPOINT:-${OBJ_STORE_ENDPOINT}}"
      ;;
    seaweedfs)
      obj_path="seaweedfs://${OBJ_STORE_BUCKET}"
      obj_endpoint="${OBJ_STORE_ENDPOINT}"
      ;;
    aws)
      obj_path="s3://${OBJ_STORE_BUCKET}"
      obj_endpoint="${OBJ_STORE_ENDPOINT}"
      ;;
    *)
      err "Unsupported objectStore.type: ${OBJ_STORE_TYPE}. Supported: aws, s3compat, minio, seaweedfs"
      ;;
  esac

  # Build SAIA public-Service exposure block.
  # The AIPlatform reconciler copies AIPlatform.spec.serviceTemplate down to
  # each AIService; the SAIA feature reconciler uses it as the spec for the
  # public saia-service.  For on-prem / airgap customers, NodePort is the
  # recommended default (no cloud LB, no cert-manager, browser on VPN can
  # reach any node IP for Pattern-B v2 APIs like /query streaming).
  local svc_template_yaml=""
  local svc_type
  svc_type=$(yq eval '.aiPlatform.serviceTemplate.type // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  if [[ -n "${svc_type}" && "${svc_type}" != "null" && "${svc_type}" != "ClusterIP" ]]; then
    local svc_node_port
    svc_node_port=$(yq eval '.aiPlatform.serviceTemplate.nodePort // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    svc_template_yaml="  serviceTemplate:"$'\n'"    spec:"$'\n'"      type: ${svc_type}"$'\n'
    if [[ -n "${svc_node_port}" && "${svc_node_port}" != "null" && "${svc_type}" == "NodePort" ]]; then
      svc_template_yaml+="      ports:"$'\n'"      - name: http"$'\n'"        port: 8080"$'\n'"        targetPort: 8080"$'\n'"        nodePort: ${svc_node_port}"$'\n'
    fi
    log "SAIA public exposure: ${svc_type}${svc_node_port:+ (nodePort=${svc_node_port})}"
  fi

  # Build features YAML from config file (reads aiPlatform.features[] array)
  local features_yaml=""
  local feature_count
  feature_count=$(yq eval '.aiPlatform.features | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")

  if [[ "${feature_count}" -gt 0 ]]; then
    log "Reading ${feature_count} feature(s) from config..."
    local i=0
    while [[ $i -lt $feature_count ]]; do
      local fname fver fsa
      fname=$(yq eval ".aiPlatform.features[$i].name" "${CONFIG_FILE}" 2>/dev/null || echo "")
      fver=$(yq eval ".aiPlatform.features[$i].version // \"1.0.0\"" "${CONFIG_FILE}" 2>/dev/null || echo "1.0.0")
      fsa=$(yq eval ".aiPlatform.features[$i].serviceAccountName // \"\"" "${CONFIG_FILE}" 2>/dev/null || echo "")
      if [[ -n "$fname" && "$fname" != "null" ]]; then
        features_yaml+="    - name: ${fname}"$'\n'
        features_yaml+="      version: \"${fver}\""$'\n'
        [[ -n "$fsa" && "$fsa" != "null" ]] && features_yaml+="      serviceAccountName: ${fsa}"$'\n'
        log "  Feature: ${fname} v${fver}"
      fi
      i=$((i + 1))
    done
  else
    log "No features in config — defaulting to saia"
    features_yaml="    - name: saia"$'\n'"      version: \"1.1.0\""$'\n'
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
    $( [[ -n "$obj_endpoint" ]] && echo "endpoint: \"${obj_endpoint}\"" )
    $( [[ -n "$obj_secret" ]] && echo "secretRef: ${obj_secret}" )

  # Image configuration (including pull secrets for private registries)
  images:
${image_pull_secrets}

  # GPU accelerator type (determines Ray worker tiers: L40S, H100_NVL, or empty for no workers)
  defaultAcceleratorType: ${DEFAULT_ACCELERATOR}

  # Features from config (aiPlatform.features)
  features:
${features_yaml}
${svc_template_yaml}
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

  ensure_namespace "${AI_NS}"

  # --- Phase 1: Independent infrastructure (parallel) ---
  log "Phase 1: Installing independent infrastructure components in parallel..."
  local phase1_pids=() phase1_names=() phase1_logdir
  phase1_logdir=$(mktemp -d)

  install_cert_manager > "${phase1_logdir}/cert-manager.log" 2>&1 &
  phase1_pids+=($!); phase1_names+=("cert-manager")

  install_kube_prometheus > "${phase1_logdir}/kube-prometheus.log" 2>&1 &
  phase1_pids+=($!); phase1_names+=("kube-prometheus")

  install_nvidia_host_drivers > "${phase1_logdir}/nvidia-drivers.log" 2>&1 &
  phase1_pids+=($!); phase1_names+=("nvidia-drivers")

  # Track which phase-1 tasks failed. nvidia-drivers failures are fatal:
  # without them the device-plugin crash-loops and the whole GPU stack
  # silently fails. Every other phase-1 task is merely warned on failure.
  local phase1_fatal_failures=0
  for i in "${!phase1_pids[@]}"; do
    if wait "${phase1_pids[$i]}"; then
      log "  ✓ ${phase1_names[$i]} completed"
    else
      warn "  ✗ ${phase1_names[$i]} had issues"
      if [[ "${phase1_names[$i]}" == "nvidia-drivers" ]]; then
        phase1_fatal_failures=$((phase1_fatal_failures + 1))
      fi
    fi
    while IFS= read -r line; do
      log "    [${phase1_names[$i]}] ${line}"
    done < "${phase1_logdir}/${phase1_names[$i]}.log"
  done
  rm -rf "${phase1_logdir}"

  if [[ ${phase1_fatal_failures} -gt 0 ]]; then
    err "NVIDIA driver install failed on at least one GPU node; aborting install.
    Device-plugin pods would otherwise crash-loop with NVML: ERROR_LIBRARY_NOT_FOUND
    and model pods would stay Pending forever. Fix the errors above and re-run."
  fi

  ensure_s3compat_credentials

  # --- Phase 2: cert-manager-dependent components (parallel) ---
  log "Phase 2: Installing cert-manager-dependent components in parallel..."
  local phase2_pids=() phase2_names=() phase2_logdir
  phase2_logdir=$(mktemp -d)

  install_otel_operator_and_contrib_collector > "${phase2_logdir}/otel.log" 2>&1 &
  phase2_pids+=($!); phase2_names+=("otel-operator")

  install_ray_operator > "${phase2_logdir}/ray.log" 2>&1 &
  phase2_pids+=($!); phase2_names+=("ray-operator")

  install_splunk_operator > "${phase2_logdir}/splunk-operator.log" 2>&1 &
  phase2_pids+=($!); phase2_names+=("splunk-operator")

  install_nvidia_device_plugin > "${phase2_logdir}/nvidia-plugin.log" 2>&1 &
  phase2_pids+=($!); phase2_names+=("nvidia-device-plugin")

  for i in "${!phase2_pids[@]}"; do
    if wait "${phase2_pids[$i]}"; then
      log "  ✓ ${phase2_names[$i]} completed"
    else
      warn "  ✗ ${phase2_names[$i]} had issues"
    fi
    while IFS= read -r line; do
      log "    [${phase2_names[$i]}] ${line}"
    done < "${phase2_logdir}/${phase2_names[$i]}.log"
  done
  rm -rf "${phase2_logdir}"

  # Create image pull secrets before Splunk Standalone (it uses the default SA which needs ECR creds)
  create_image_pull_secrets "${AI_NS}"

  # Deploy CronJob that auto-refreshes ECR credentials every 6 hours (tokens expire at 12h)
  install_ecr_credential_refresher

  # Apply Splunk Standalone CR (non-blocking — pod boots in background)
  install_splunk_standalone

  # Install AI Platform operator and CR while Splunk Standalone boots
  install_splunk_ai_operator
  install_ai_platform_cr

  # Now wait for Splunk Standalone to be ready (likely already done by now)
  wait_for_splunk_standalone

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

  # Check 3: Object Storage
  log "Checking object storage configuration..."
  if [[ -n "${OBJ_STORE_ENDPOINT}" ]]; then
    log "✅ Object storage configured: ${OBJ_STORE_TYPE} at ${OBJ_STORE_ENDPOINT} (customer-managed)"
  else
    warn "Object storage endpoint not configured"
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

  # Object storage information
  log "🗄️  Object Storage (customer-managed):"
  log "  Type: ${OBJ_STORE_TYPE}"
  log "  Endpoint: ${OBJ_STORE_ENDPOINT}"
  log "  Bucket: ${OBJ_STORE_BUCKET}"
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

  validate_image_config
  configure_images

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

    # Parse IPs from config
    log "Using existing infrastructure..."
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"

    # Check if k0s is already running on the controller node
    if [[ "${#CONTROLLER_IPS[@]}" -gt 0 ]]; then
      local controller_ip="${CONTROLLER_IPS[0]}"
      log "Checking if k0s is already installed on ${controller_ip}..."

      if ssh_exec "${controller_ip}" "command -v k0s >/dev/null 2>&1 && sudo k0s status >/dev/null 2>&1"; then
        log "============================================"
        log "✓ k0s cluster already running on existing nodes!"
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

  # Graceful Kubernetes cleanup, then stop k0s on all nodes
  log "Performing graceful Kubernetes cleanup..."

  export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"

  if [[ -f "${KUBECONFIG}" ]] && timeout 10 kubectl cluster-info &>/dev/null; then
    log "Deleting Kubernetes resources..."
    kubectl delete aiplatform --all -n "${AI_NS}" --timeout=60s || true
    kubectl delete namespace "${AI_NS}" --timeout=120s || true
    kubectl delete namespace splunk-ai-operator-system --timeout=60s || true
    kubectl delete namespace monitoring --timeout=60s || true
  fi

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

  log "k0s stopped on all nodes"
  log "NOTE: Node machines are still running. To clean up completely:"
  log "  - Remove k0s binaries: sudo rm -f /usr/local/bin/k0s"
  log "  - Clean up data: sudo rm -rf /var/lib/k0s /etc/k0s"

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

  log "Infrastructure: On-premises"
  log "  - k0s stopped and reset on all nodes"
  log "  - NOTE: Nodes are still running, k0s binaries remain"

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

  log ""
  log "Nodes are still running with k0s stopped."
  log "To fully clean up each node, run:"
  log "  sudo rm -f /usr/local/bin/k0s"
  log "  sudo rm -rf /var/lib/k0s /etc/k0s"
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

Deploys Splunk AI Platform on k0s cluster using pre-provisioned nodes.
Requires nodes.existingIPs in the config YAML.

Commands:
  install       - Install k0s cluster and AI Platform stack
  join-workers  - Join/rejoin worker nodes to existing cluster (resume after failure)
  delete        - Delete cluster and all resources (graceful)
  clean-all     - Aggressive cleanup including node-level cleanup

Environment:
  CONFIG_FILE  - Path to k0s config YAML (default: ./k0s-cluster-config.yaml)
  AUTO_APPROVE - Skip confirmation prompt for delete (default: false)

Examples:
  # Install with existing IPs
  CONFIG_FILE=./my-config.yaml $0 install

  # Join worker nodes (if install failed or was interrupted)
  CONFIG_FILE=./my-config.yaml $0 join-workers

  # Delete cluster (with confirmation prompt)
  CONFIG_FILE=./my-config.yaml $0 delete

  # Delete cluster (auto-approve, no prompt)
  AUTO_APPROVE=true CONFIG_FILE=./my-config.yaml $0 delete

  # Deep cleanup (aggressive)
  CONFIG_FILE=./my-config.yaml $0 clean-all

Notes:
  - 'install' performs full cluster setup including worker joins
  - 'join-workers' is useful for:
    * Resuming after installation was interrupted
    * Retrying failed worker joins
    * Adding workers to existing cluster
    * Fixing missing node labels
  - 'delete' performs comprehensive cleanup:
    * All Kubernetes resources (CRs, operators, namespaces)
    * Stops and resets k0s on all nodes
    * Machines remain running but k0s is stopped and reset
    * Provides detailed cleanup summary
  - 'clean-all' adds aggressive node-level cleanup:
    * Removes k0s data directories (preserves k0s binary)
    * Cleans kubelet, CNI, and Calico files
    * Flushes iptables rules
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

  # Get IPs from config
  log "Detecting cluster configuration..."
  IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
  IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"

  if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
    warn "No worker IPs found in config"
    log "Nothing to join, exiting."
    return 0
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

    # RHEL/Fedora compatibility (firewalld, kernel modules, python3-pyyaml, k0s binary)
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
