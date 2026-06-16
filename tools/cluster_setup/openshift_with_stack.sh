#!/bin/bash
set -euo pipefail

# =============================================================================
# OpenShift Cluster Setup Script for Splunk AI Platform
# =============================================================================
# Installs/removes the Splunk AI Operator stack onto an existing OpenShift
# cluster. Assumes you are already logged in via `oc login` or have a valid
# KUBECONFIG pointing at the cluster.
#
# Usage:
#   ./openshift_with_stack.sh [install|delete]
#
# The script reads openshift-cluster-config.yaml in the same directory.
# Override with: CONFIG_FILE=/path/to/config.yaml ./openshift_with_stack.sh
# =============================================================================

export PAGER=cat
export LANG=C LC_ALL=C

# ====== CONFIG FILE LOCATION ======
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/openshift-cluster-config.yaml}"

# ====== SESSION LOG ======
LOG_DIR="${LOG_DIR:-$(dirname "$0")/logs}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/openshift-install-$(date '+%Y-%m-%d_%H-%M-%S').log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "[LOG] Session log: ${LOG_FILE}"

# ====== LOG ROTATION (keep last 10 logs) ======
_rotate_logs() {
  local keep=10
  local logs=()
  while IFS= read -r f; do logs+=("$f"); done < <(ls -1t "${LOG_DIR}"/openshift-install-*.log 2>/dev/null)
  local excess=$(( ${#logs[@]} - keep ))
  if (( excess > 0 )); then
    for (( i=${#logs[@]}-1; i>=${#logs[@]}-excess; i-- )); do
      rm -f "${logs[$i]}"
    done
  fi
}
_rotate_logs

# ====== COLORS & LOGGING ======
_ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo -e "\033[1;36m[$(_ts) INFO]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[$(_ts) WARN]\033[0m $*" >&2; }
err()  {
  echo -e "\033[1;31m[$(_ts) ERROR]\033[0m $*" >&2
  echo -e "\033[1;31m[$(_ts) ERROR]\033[0m Log file: ${LOG_FILE}" >&2
  echo -e "\033[1;31m[$(_ts) ERROR]\033[0m Run '$0 diagnose' to collect a full support bundle." >&2
  exit 1
}

# ====== TOOL CHECKER ======
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  local install_hint=""
  case "$1" in
    oc)      install_hint="https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html" ;;
    helm)    install_hint="brew install helm  OR  https://helm.sh/docs/intro/install/" ;;
    yq)      install_hint="brew install yq  OR  wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && chmod +x /usr/local/bin/yq" ;;
    jq)      install_hint="brew install jq  OR  apt-get install jq  OR  dnf install jq" ;;
    curl)    install_hint="apt-get install curl  OR  brew install curl" ;;
    aws)     install_hint="https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
    git)     install_hint="brew install git  OR  apt-get install git" ;;
    *)       install_hint="install '$1' via your system package manager" ;;
  esac
  err "Required tool not found: $1
  Install: ${install_hint}"
}

# ====== STEP PROGRESS TRACKER ======
declare -a _STEP_NAMES=()
declare -a _STEP_STATUS=()
_STEP_CURRENT=""

step_start() {
  _STEP_CURRENT="$1"
  _STEP_NAMES+=("$1")
  _STEP_STATUS+=("running")
  local n=${#_STEP_NAMES[@]}
  echo -e "\n\033[1;34m[$(_ts) ── STEP ${n}: $1 ──]\033[0m" >&2
}

step_ok() {
  local last=$(( ${#_STEP_STATUS[@]} - 1 ))
  _STEP_STATUS[$last]="ok"
}

step_fail() {
  local last=$(( ${#_STEP_STATUS[@]} - 1 ))
  _STEP_STATUS[$last]="fail:${1:-unknown error}"
}

step_skip() {
  local last=$(( ${#_STEP_STATUS[@]} - 1 ))
  _STEP_STATUS[$last]="skip:${1:-}"
}

show_step_summary() {
  echo -e "\n\033[1;34m[$(_ts) ════ INSTALL SUMMARY ════]\033[0m" >&2
  local total=${#_STEP_NAMES[@]} ok=0 fail=0 skip=0
  for i in "${!_STEP_NAMES[@]}"; do
    local s="${_STEP_STATUS[$i]}"
    local icon color label
    case "${s%%:*}" in
      ok)      icon="✔"; color="\033[1;32m"; label="OK";           ok=$((ok+1)) ;;
      fail)    icon="✖"; color="\033[1;31m"; label="${s#fail:}";   fail=$((fail+1)) ;;
      skip)    icon="–"; color="\033[1;33m"; label="${s#skip:}";   skip=$((skip+1)) ;;
      running) icon="?"; color="\033[1;33m"; label="interrupted";  fail=$((fail+1)) ;;
      *)       icon="?"; color="\033[0m";    label="${s}" ;;
    esac
    printf "  ${color}${icon}\033[0m  %-45s %s\n" "${_STEP_NAMES[$i]}" "${label}" >&2
  done
  echo "" >&2
  if (( fail == 0 )); then
    echo -e "  \033[1;32mAll ${total} steps completed successfully.\033[0m" >&2
  else
    echo -e "  \033[1;31m${fail} step(s) failed, ${ok} succeeded, ${skip} skipped.\033[0m" >&2
    echo -e "  \033[1;31mSee log: ${LOG_FILE}\033[0m" >&2
  fi
  echo "" >&2
}

# ====== PHASE SECTION MARKERS ======
phase_start() { echo -e "\n\033[1;35m[$(_ts) ════════ PHASE: $* ════════]\033[0m" >&2; }
phase_end()   { echo -e "\033[1;35m[$(_ts) ════════ END: $* ════════]\033[0m\n" >&2; }

# ====== WAIT FOR DEPENDENCY (interactive pause-and-retry) ======
wait_for_dependency() {
  local description="$1"
  local check_cmd="$2"
  local max_wait="${3:-600}"
  local elapsed=0 interval=30

  log "Waiting for external dependency: ${description}"
  log "  Max wait: ${max_wait}s. Press Enter at any time to retry immediately."

  while (( elapsed < max_wait )); do
    if eval "${check_cmd}" >/dev/null 2>&1; then
      log "  ✔ ${description} — ready"
      return 0
    fi
    local remaining=$(( max_wait - elapsed ))
    warn "  ${description} not ready yet. Retrying in ${interval}s (${remaining}s remaining)."
    warn "  Press Enter to retry now, or wait..."
    if read -t "${interval}" -r 2>/dev/null; then
      log "  Retrying immediately..."
    fi
    elapsed=$(( elapsed + interval ))
  done

  err "Timed out after ${max_wait}s waiting for: ${description}
  Resolve the issue, then re-run the installer."
}

# ====== SHOW INSTALL PLAN ======
show_install_plan() {
  echo -e "\n\033[1;34m╔══════════════════════════════════════════════════════════╗\033[0m" >&2
  echo -e "\033[1;34m║       SPLUNK AI PLATFORM — OPENSHIFT INSTALL PLAN         ║\033[0m" >&2
  echo -e "\033[1;34m╚══════════════════════════════════════════════════════════╝\033[0m" >&2
  echo "" >&2
  echo -e "  \033[1mNamespace        :\033[0m ${AI_NS}" >&2
  echo -e "  \033[1mConfig file      :\033[0m ${CONFIG_FILE}" >&2
  echo -e "  \033[1mLog file         :\033[0m ${LOG_FILE}" >&2
  echo "" >&2
  echo -e "  \033[1mAccelerator type :\033[0m ${DEFAULT_ACCELERATOR:-<none>}" >&2
  echo -e "  \033[1mNode label strat :\033[0m ${NODE_LABEL_STRATEGY}" >&2
  echo -e "  \033[1mOperator image   :\033[0m ${OPERATOR_IMAGE}" >&2
  echo -e "  \033[1mImage registry   :\033[0m ${IMAGE_REGISTRY:-<none>}" >&2
  echo -e "  \033[1mECR enabled      :\033[0m ${ECR_ENABLED}" >&2
  echo "" >&2
  echo -e "  \033[1mObject store     :\033[0m type=${OBJ_STORE_TYPE}  bucket=${OBJ_STORE_BUCKET:-<unset>}" >&2
  echo -e "  \033[1mObject endpoint  :\033[0m ${OBJ_STORE_ENDPOINT:-<default>}" >&2
  echo "" >&2
  echo -e "  \033[1mSteps that will run:\033[0m" >&2
  echo -e "    1.  Preflight checks (oc login, tools, manifest files)" >&2
  echo -e "    2.  NFD Operator (OLM)" >&2
  echo -e "    3.  NVIDIA GPU Operator (OLM)" >&2
  echo -e "    4.  Node labeling (splunk.ai/workload-type)" >&2
  echo -e "    5.  local-path-provisioner + SELinux relabeling" >&2
  echo -e "    6.  cert-manager (Helm)" >&2
  echo -e "    7.  OpenTelemetry Operator (Helm)" >&2
  echo -e "    8.  KubeRay Operator (Helm)" >&2
  echo -e "    9.  ECR pull secrets" >&2
  echo -e "    10. Splunk AI Operator" >&2
  echo -e "    11. Splunk Operator" >&2
  echo -e "    12. Splunk Standalone CR" >&2
  echo -e "    13. AIPlatform CR" >&2
  echo "" >&2

  if [[ "${AUTO_APPROVE:-false}" == "true" ]]; then
    log "AUTO_APPROVE=true — skipping confirmation."
    return 0
  fi

  echo -e "  \033[1mReview the plan above. Type 'yes' to proceed, anything else to abort:\033[0m" >&2
  local answer
  read -r answer
  if [[ "${answer}" != "yes" ]]; then
    echo "Aborted by user." >&2
    exit 0
  fi
}

# ====== LOAD CONFIGURATION ======
load_config() {
  log "Loading configuration from: ${CONFIG_FILE}"
  [[ -f "${CONFIG_FILE}" ]] || err "Config file not found: ${CONFIG_FILE}"

  if command -v yq >/dev/null 2>&1; then
    local yq_err
    if ! yq_err=$(yq eval '.' "${CONFIG_FILE}" 2>&1 >/dev/null); then
      err "Config file ${CONFIG_FILE} has YAML syntax errors:
${yq_err}"
    fi
  fi

  AI_NS=$(yq eval '.kubernetes.namespace // "ai-platform"' "${CONFIG_FILE}" 2>/dev/null || echo "ai-platform")
  IMAGE_REGISTRY=$(yq eval '.images.registry // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  OPERATOR_IMAGE=$(yq eval '.images.operator.image // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  RAY_HEAD_IMAGE=$(yq eval '.images.ray.headImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  RAY_WORKER_IMAGE=$(yq eval '.images.ray.workerImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  WEAVIATE_IMAGE=$(yq eval '.images.weaviate.image // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SAIA_API_IMAGE=$(yq eval '.images.saia.apiImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SAIA_API_V2_IMAGE=$(yq eval '.images.saia.apiV2Image // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SAIA_DATALOADER_IMAGE=$(yq eval '.images.saia.dataLoaderImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SPLUNK_IMAGE=$(yq eval '.images.splunk.image // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SPLUNK_OPERATOR_IMAGE=$(yq eval '.images.splunk.operatorImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  FLUENT_BIT_IMAGE=$(yq eval '.images.fluentBit.image // "fluent/fluent-bit:1.9.6"' "${CONFIG_FILE}" 2>/dev/null || echo "fluent/fluent-bit:1.9.6")
  OTEL_COLLECTOR_IMAGE=$(yq eval '.images.otelCollector.image // "otel/opentelemetry-collector-contrib:0.122.1"' "${CONFIG_FILE}" 2>/dev/null || echo "otel/opentelemetry-collector-contrib:0.122.1")
  NGINX_IMAGE=$(yq eval '.images.nginx.image // "docker.io/library/nginx:1.27-alpine"' "${CONFIG_FILE}" 2>/dev/null || echo "docker.io/library/nginx:1.27-alpine")
  MODEL_VERSION=$(yq eval '.operators.ray.modelVersion // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  RAY_RUNTIME_VERSION=$(yq eval '.operators.ray.rayVersion // "2.44.0"' "${CONFIG_FILE}" 2>/dev/null || echo "2.44.0")
  SPLUNK_AI_FILE=$(yq eval '.files.aiPlatform // "./artifacts.yaml"' "${CONFIG_FILE}" 2>/dev/null || echo "./artifacts.yaml")
  SPLUNK_OPERATOR_FILE=$(yq eval '.files.splunkOperator // "./splunk-operator-cluster.yaml"' "${CONFIG_FILE}" 2>/dev/null || echo "./splunk-operator-cluster.yaml")

  # OpenShift-specific
  # Whether to grant the operator service account privileged SCC.
  # Required for Ray worker pods that request nvidia.com/gpu resources.
  GRANT_PRIVILEGED_SCC=$(yq eval '.openshift.grantPrivilegedSCC // "true"' "${CONFIG_FILE}" 2>/dev/null || echo "true")

  NODE_LABEL_STRATEGY=$(yq eval '.openshift.nodeLabelStrategy // "auto"' "${CONFIG_FILE}" 2>/dev/null || echo "auto")

  ECR_ENABLED=$(yq eval '.ecr.enabled // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  ECR_ACCOUNT=$(yq eval '.ecr.account // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  ECR_REGION=$(yq eval '.ecr.region // "us-east-2"' "${CONFIG_FILE}" 2>/dev/null || echo "us-east-2")

  AI_PLATFORM_NAME=$(yq eval '.aiPlatform.name // "openshift-ai-platform"' "${CONFIG_FILE}" 2>/dev/null || echo "openshift-ai-platform")
  DEFAULT_ACCELERATOR=$(yq eval '.aiPlatform.defaultAcceleratorType // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  WORKER_IMAGE_REGISTRY=$(yq eval '.aiPlatform.workerGroupConfig.imageRegistry // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  STORAGE_CLASS=$(yq eval '.storage.storageClass // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  VECTORDB_SIZE=$(yq eval '.storage.vectorDbSize // "50Gi"' "${CONFIG_FILE}" 2>/dev/null || echo "50Gi")
  OBJ_STORE_TYPE=$(yq eval '.storage.objectStore.type // "minio"' "${CONFIG_FILE}" 2>/dev/null || echo "minio")
  OBJ_STORE_BUCKET=$(yq eval '.storage.objectStore.bucket // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  OBJ_STORE_ENDPOINT=$(yq eval '.storage.objectStore.endpoint // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  MINIO_ROOT_USER=$(yq eval '.storage.objectStore.auth.rootUser // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  MINIO_ROOT_PASSWORD=$(yq eval '.storage.objectStore.auth.rootPassword // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  AI_STANDALONE_NAME=$(yq eval '.splunk.standaloneName // "splunk-standalone"' "${CONFIG_FILE}" 2>/dev/null || echo "splunk-standalone")

  log "Configuration loaded: namespace=${AI_NS}, accelerator=${DEFAULT_ACCELERATOR}"
}

# ====== IMAGE HELPERS ======
build_image_url() {
  local registry="$1"
  local image_path="$2"
  # If the image is already fully qualified (contains a registry host) return as-is
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
  [[ -z "$OPERATOR_IMAGE"        || "$OPERATOR_IMAGE"        == "null" ]] && err "REQUIRED: images.operator.image must be set in config"
  [[ -z "$RAY_HEAD_IMAGE"        || "$RAY_HEAD_IMAGE"        == "null" ]] && err "REQUIRED: images.ray.headImage must be set in config"
  [[ -z "$RAY_WORKER_IMAGE"      || "$RAY_WORKER_IMAGE"      == "null" ]] && err "REQUIRED: images.ray.workerImage must be set in config"
  [[ -z "$WEAVIATE_IMAGE"        || "$WEAVIATE_IMAGE"        == "null" ]] && err "REQUIRED: images.weaviate.image must be set in config"
  [[ -z "$SAIA_API_IMAGE"        || "$SAIA_API_IMAGE"        == "null" ]] && err "REQUIRED: images.saia.apiImage must be set in config"
  [[ -z "$SAIA_API_V2_IMAGE"     || "$SAIA_API_V2_IMAGE"     == "null" ]] && err "REQUIRED: images.saia.apiV2Image must be set in config"
  [[ -z "$SAIA_DATALOADER_IMAGE" || "$SAIA_DATALOADER_IMAGE" == "null" ]] && err "REQUIRED: images.saia.dataLoaderImage must be set in config"
  [[ -z "$SPLUNK_IMAGE"          || "$SPLUNK_IMAGE"          == "null" ]] && err "REQUIRED: images.splunk.image must be set in config"
  [[ -z "$MODEL_VERSION"         || "$MODEL_VERSION"         == "null" ]] && { MODEL_VERSION="v0.3.14-36-g1549f5a"; log "Using default MODEL_VERSION: $MODEL_VERSION"; }
  log "✓ Image configuration validated"
}

configure_images() {
  log "Patching image references in manifest files..."

  [[ -f "${SPLUNK_AI_FILE}" ]] || err "Manifest not found: ${SPLUNK_AI_FILE}"

  if [[ ! -f "${SPLUNK_AI_FILE}.original" ]]; then
    cp "$SPLUNK_AI_FILE" "${SPLUNK_AI_FILE}.original"
  fi
  cp "${SPLUNK_AI_FILE}.original" "$SPLUNK_AI_FILE"

  local operator_full ray_head_full ray_worker_full weaviate_full
  local saia_api_full saia_api_v2_full saia_dataloader_full
  local fluent_bit_full otel_collector_full nginx_full

  operator_full=$(build_image_url "$IMAGE_REGISTRY" "$OPERATOR_IMAGE")
  ray_head_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_HEAD_IMAGE")
  ray_worker_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_WORKER_IMAGE")
  weaviate_full=$(build_image_url "$IMAGE_REGISTRY" "$WEAVIATE_IMAGE")
  saia_api_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_IMAGE")
  saia_api_v2_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_V2_IMAGE")
  saia_dataloader_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_DATALOADER_IMAGE")
  fluent_bit_full=$(build_image_url "$IMAGE_REGISTRY" "$FLUENT_BIT_IMAGE")
  otel_collector_full=$(build_image_url "$IMAGE_REGISTRY" "$OTEL_COLLECTOR_IMAGE")
  nginx_full=$(build_image_url "$IMAGE_REGISTRY" "$NGINX_IMAGE")

  # BSD (macOS) sed requires an explicit backup-suffix arg after -i.
  local SED_INPLACE
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_INPLACE=(sed -i "")
  else
    SED_INPLACE=(sed -i)
  fi

  local ray_head_esc ray_worker_esc weaviate_esc saia_api_esc saia_api_v2_esc
  local saia_dl_esc fluent_esc otel_esc nginx_esc operator_esc

  ray_head_esc=$(echo "$ray_head_full"       | sed 's/[\/&]/\\&/g')
  ray_worker_esc=$(echo "$ray_worker_full"   | sed 's/[\/&]/\\&/g')
  weaviate_esc=$(echo "$weaviate_full"       | sed 's/[\/&]/\\&/g')
  saia_api_esc=$(echo "$saia_api_full"       | sed 's/[\/&]/\\&/g')
  saia_api_v2_esc=$(echo "$saia_api_v2_full" | sed 's/[\/&]/\\&/g')
  saia_dl_esc=$(echo "$saia_dataloader_full" | sed 's/[\/&]/\\&/g')
  fluent_esc=$(echo "$fluent_bit_full"       | sed 's/[\/&]/\\&/g')
  otel_esc=$(echo "$otel_collector_full"     | sed 's/[\/&]/\\&/g')
  nginx_esc=$(echo "$nginx_full"             | sed 's/[\/&]/\\&/g')
  operator_esc=$(echo "$operator_full"       | sed 's/[\/&]/\\&/g')

  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_RAY_HEAD/,/value:/ s|value:.*|value: ${ray_head_esc}|"             "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_RAY_WORKER/,/value:/ s|value:.*|value: ${ray_worker_esc}|"         "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_WEAVIATE/,/value:/ s|value:.*|value: ${weaviate_esc}|"             "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SAIA_API$/,/value:/ s|value:.*|value: ${saia_api_esc}|"            "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SAIA_API_V2/,/value:/ s|value:.*|value: ${saia_api_v2_esc}|"       "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_POST_INSTALL_HOOK/,/value:/ s|value:.*|value: ${saia_dl_esc}|"     "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_FLUENT_BIT/,/value:/ s|value:.*|value: ${fluent_esc}|"             "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_OTEL_COLLECTOR/,/value:/ s|value:.*|value: ${otel_esc}|"           "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_NGINX/,/value:/ s|value:.*|value: ${nginx_esc}|"                   "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: MODEL_VERSION/,/value:/ s|value:.*|value: ${MODEL_VERSION}|"                     "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RAY_VERSION/,/value:/ s|value:.*|value: ${RAY_RUNTIME_VERSION}|"                 "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "s|image: .*splunk.*ai.*operator.*|image: ${operator_esc}|I"                             "$SPLUNK_AI_FILE"

  log "  ✓ RELATED_IMAGE_RAY_HEAD:          $ray_head_full"
  log "  ✓ RELATED_IMAGE_RAY_WORKER:        $ray_worker_full"
  log "  ✓ RELATED_IMAGE_WEAVIATE:          $weaviate_full"
  log "  ✓ RELATED_IMAGE_SAIA_API:          $saia_api_full"
  log "  ✓ RELATED_IMAGE_SAIA_API_V2:       $saia_api_v2_full"
  log "  ✓ RELATED_IMAGE_POST_INSTALL_HOOK: $saia_dataloader_full"
  log "  ✓ RELATED_IMAGE_FLUENT_BIT:        $fluent_bit_full"
  log "  ✓ RELATED_IMAGE_OTEL_COLLECTOR:    $otel_collector_full"
  log "  ✓ RELATED_IMAGE_NGINX:             $nginx_full"
  log "  ✓ Operator image:                  $operator_full"
  log "  ✓ MODEL_VERSION:                   $MODEL_VERSION"
  log "  ✓ RAY_VERSION:                     $RAY_RUNTIME_VERSION"
}

# ====== PREFLIGHT CHECKS ======
preflight_checks() {
  log "Running preflight checks..."

  for tool in oc yq helm aws curl jq base64 tar; do
    command -v "$tool" >/dev/null 2>&1 && log "  ✓ $tool found" || err "Missing required tool: $tool"
  done

  # Verify we are connected to the cluster
  if ! oc whoami &>/dev/null; then
    err "Not logged in to OpenShift. Run: oc login <cluster-url>"
  fi
  log "  ✓ Logged in as: $(oc whoami)"

  # Verify cluster admin access (needed to install CRDs and grant SCCs)
  if ! oc auth can-i create clusterrolebinding --all-namespaces &>/dev/null; then
    warn "  May not have cluster-admin; CRD and SCC operations might fail"
  else
    log "  ✓ Cluster-admin access confirmed"
  fi

  [[ -f "${SPLUNK_AI_FILE}" ]] && log "  ✓ Manifest: ${SPLUNK_AI_FILE}" || err "Manifest not found: ${SPLUNK_AI_FILE}"

  log "Preflight checks passed"
}

# ====== WAIT FOR CRD ======
wait_for_crd() {
  local crd_name="$1"
  local timeout="${2:-300}"
  log "Waiting for CRD ${crd_name} (timeout: ${timeout}s)..."
  local elapsed=0
  while ! oc get crd "${crd_name}" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      err "Timeout waiting for CRD ${crd_name}"
    fi
  done
  log "  ✓ CRD ${crd_name} ready"
}

# ====== ENSURE NAMESPACE ======
ensure_namespace() {
  local ns="$1"
  if ! oc get namespace "${ns}" &>/dev/null; then
    log "Creating namespace ${ns}..."
    oc create namespace "${ns}"
  fi
}

# ====== OPENSHIFT: GRANT PRIVILEGED SCC ======
# Ray worker pods request nvidia.com/gpu resources and run as non-root.
# On OpenShift the default restricted SCC blocks this — privileged SCC is needed.
grant_privileged_scc() {
  if [[ "${GRANT_PRIVILEGED_SCC}" != "true" ]]; then
    log "Skipping privileged SCC grant (openshift.grantPrivilegedSCC=false)"
    return 0
  fi

  local ai_operator_ns="splunk-ai-operator-system"
  log "Granting SCC policies to service account groups in ${ai_operator_ns} and ${AI_NS}..."

  # Use `oc adm policy add-scc-to-group` which modifies the SCC's groups list directly
  # and is honored by OCP SCC admission (unlike ClusterRoleBinding which can be ignored).
  #
  # - privileged: operator namespace (webhook + leader election need elevated perms)
  # - anyuid: AI platform namespace so operator-created SAs (saia-sa, weaviate,
  #   raycluster-*) run as the UID defined in their images, not OCP's random UID range.
  # - privileged: also on AI platform so Splunk Standalone can write to hostPath PVCs.
  oc adm policy add-scc-to-group privileged \
    "system:serviceaccounts:${ai_operator_ns}" 2>/dev/null || true
  oc adm policy add-scc-to-group anyuid \
    "system:serviceaccounts:${AI_NS}" 2>/dev/null || true
  oc adm policy add-scc-to-group privileged \
    "system:serviceaccounts:${AI_NS}" 2>/dev/null || true
  # Splunk Operator pod adds NET_BIND_SERVICE capability which anyuid blocks; needs privileged.
  oc adm policy add-scc-to-group privileged \
    "system:serviceaccounts:splunk-operator" 2>/dev/null || true

  log "  ✓ anyuid + privileged SCC granted to all SAs in ${AI_NS} and splunk-operator"
}

# ====== INSTALL NFD (Node Feature Discovery) via OLM ======
# NFD labels nodes with hardware capabilities including nvidia.com/gpu.present=true.
# The GPU Operator depends on NFD labels to know which nodes to target.
install_nfd() {
  log "Installing Node Feature Discovery Operator (NFD)..."

  if oc get subscription nfd -n openshift-nfd &>/dev/null; then
    log "  ✓ NFD subscription already exists, skipping"
    return 0
  fi

  oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
    - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

  log "Waiting for NFD CSV to succeed..."
  local retries=0
  while (( retries < 36 )); do
    local phase
    phase=$(oc get csv -n openshift-nfd -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "${phase}" == "Succeeded" ]]; then
      log "  ✓ NFD operator ready"
      break
    fi
    sleep 10
    retries=$(( retries + 1 ))
    log "  Waiting for NFD CSV... (${retries}/36, phase=${phase:-pending})"
  done

  # Create the NodeFeatureDiscovery CR to start labeling nodes
  if ! oc get nodefeaturediscovery nfd-instance -n openshift-nfd &>/dev/null; then
    log "Creating NodeFeatureDiscovery CR..."
    oc apply -f - <<'EOF'
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9:v4.21
    imagePullPolicy: Always
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
      sources:
        pci:
          deviceClassWhitelist:
            - "03"
          deviceLabelFields:
            - "vendor"
EOF
  fi

  log "  ✓ NFD installed"
}

# ====== INSTALL NVIDIA GPU OPERATOR via OLM ======
# Installs driver, container toolkit, device plugin, and DCGM on GPU nodes.
# Uses OCP Driver Toolkit (use_ocp_driver_toolkit: true) so no SSH to nodes needed.
install_nvidia_gpu_operator() {
  log "Installing NVIDIA GPU Operator..."

  if oc get subscription gpu-operator-certified -n nvidia-gpu-operator &>/dev/null; then
    log "  ✓ GPU Operator subscription already exists, skipping"
    return 0
  fi

  oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
    - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: v26.3
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

  log "Waiting for GPU Operator CSV to succeed..."
  local retries=0
  while (( retries < 36 )); do
    local phase
    phase=$(oc get csv -n nvidia-gpu-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "${phase}" == "Succeeded" ]]; then
      log "  ✓ GPU Operator CSV ready"
      break
    fi
    sleep 10
    retries=$(( retries + 1 ))
    log "  Waiting for GPU Operator CSV... (${retries}/36, phase=${phase:-pending})"
  done

  # Create ClusterPolicy to trigger driver + toolkit + device-plugin rollout
  if ! oc get clusterpolicy gpu-cluster-policy &>/dev/null; then
    log "Creating ClusterPolicy CR..."
    oc apply -f - <<'EOF'
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator: {}
  daemonsets: {}
  driver:
    enabled: true
    use_ocp_driver_toolkit: true
  toolkit:
    enabled: true
  devicePlugin:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
  gfd:
    enabled: true
  nodeStatusExporter:
    enabled: true
  validator:
    enabled: true
EOF
  fi

  # Wait for nvidia.com/gpu.present=true to appear on at least one worker node.
  # This confirms NFD + GFD have finished their discovery pass.
  log "Waiting for GPU nodes to be labeled by GPU Operator / GFD..."
  local retries=0
  while (( retries < 60 )); do
    local count
    count=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if (( count > 0 )); then
      log "  ✓ ${count} GPU node(s) labeled with nvidia.com/gpu.present=true"
      break
    fi
    sleep 15
    retries=$(( retries + 1 ))
    log "  Waiting for GPU node labels... (${retries}/60)"
  done

  if (( retries >= 60 )); then
    warn "GPU nodes not labeled after 15m — label_nodes will fall back to 0 GPU workers.
    Check: oc get pods -n nvidia-gpu-operator
           oc get clusterpolicy gpu-cluster-policy -o yaml"
  fi

  log "  ✓ NVIDIA GPU Operator installed"
}

# ====== NODE LABELING ======
# Applies splunk.ai/* labels that the operator uses to schedule workloads.
# Without these labels all operator-managed pods (weaviate, ray-head, ray-worker)
# will stay Pending forever because their nodeSelectors won't match any node.
# Runs after install_nvidia_gpu_operator so nvidia.com/gpu.present=true is already set.
label_nodes() {
  log "Applying splunk.ai/* node labels (strategy: ${NODE_LABEL_STRATEGY})..."

  local cpu_nodes=() gpu_nodes=() control_nodes=()

  # Always label master/control-plane nodes
  while IFS= read -r node; do
    [[ -n "$node" ]] && control_nodes+=("$node")
  done < <(oc get nodes -l node-role.kubernetes.io/master -o name 2>/dev/null | sed 's|node/||')

  case "${NODE_LABEL_STRATEGY}" in
    auto)
      # GPU nodes: detected by nvidia.com/gpu.present=true (set by NVIDIA GPU Operator / NFD)
      while IFS= read -r node; do
        [[ -n "$node" ]] && gpu_nodes+=("$node")
      done < <(oc get nodes -l nvidia.com/gpu.present=true,node-role.kubernetes.io/worker -o name 2>/dev/null | sed 's|node/||')

      # CPU nodes: worker nodes without GPU label
      while IFS= read -r node; do
        [[ -n "$node" ]] && cpu_nodes+=("$node")
      done < <(oc get nodes -l '!nvidia.com/gpu.present,node-role.kubernetes.io/worker' -o name 2>/dev/null | sed 's|node/||')
      ;;

    manual)
      local cpu_count gpu_count
      cpu_count=$(yq eval '.openshift.nodes.cpu | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
      gpu_count=$(yq eval '.openshift.nodes.gpu | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
      local i=0
      while [[ $i -lt $cpu_count ]]; do
        local n; n=$(yq eval ".openshift.nodes.cpu[$i]" "${CONFIG_FILE}" 2>/dev/null || echo "")
        [[ -n "$n" && "$n" != "null" ]] && cpu_nodes+=("$n")
        i=$((i+1))
      done
      i=0
      while [[ $i -lt $gpu_count ]]; do
        local n; n=$(yq eval ".openshift.nodes.gpu[$i]" "${CONFIG_FILE}" 2>/dev/null || echo "")
        [[ -n "$n" && "$n" != "null" ]] && gpu_nodes+=("$n")
        i=$((i+1))
      done
      ;;

    *)
      err "Unknown nodeLabelStrategy: ${NODE_LABEL_STRATEGY}. Use 'auto' or 'manual'."
      ;;
  esac

  # Label control-plane nodes
  for node in "${control_nodes[@]}"; do
    log "  Labeling control-plane node: ${node}"
    oc label node "${node}" \
      splunk.ai/node-role=controller \
      splunk.ai/workload-type=control-plane \
      --overwrite
  done

  # Label CPU worker nodes
  for node in "${cpu_nodes[@]}"; do
    log "  Labeling CPU worker node: ${node}"
    oc label node "${node}" \
      splunk.ai/node-role=worker \
      splunk.ai/workload-type=cpu \
      splunk.ai/instance-type=cpu-worker \
      --overwrite
  done

  # Label GPU worker nodes
  for node in "${gpu_nodes[@]}"; do
    log "  Labeling GPU worker node: ${node}"
    oc label node "${node}" \
      splunk.ai/node-role=worker \
      splunk.ai/workload-type=gpu \
      splunk.ai/instance-type=gpu-worker \
      --overwrite
    # Taint GPU nodes so non-GPU workloads don't land on them
    oc adm taint node "${node}" nvidia.com/gpu=true:NoSchedule --overwrite 2>/dev/null || true
  done

  # Verify no worker node is left unlabeled — unlabeled workers cause silent Pending forever
  local unlabeled
  unlabeled=$(oc get nodes -l node-role.kubernetes.io/worker -o json 2>/dev/null \
    | python3 -c "
import json,sys
data=json.load(sys.stdin)
for n in data['items']:
    if 'splunk.ai/workload-type' not in n['metadata']['labels']:
        print(n['metadata']['name'])
" 2>/dev/null || echo "")

  if [[ -n "${unlabeled}" ]]; then
    err "Worker node(s) still missing splunk.ai/workload-type after labeling:
$(echo "${unlabeled}" | sed 's/^/  /')

If using nodeLabelStrategy: auto, check that the NVIDIA GPU Operator is installed
and nodes have nvidia.com/gpu.present=true, or switch to nodeLabelStrategy: manual
and list nodes explicitly under openshift.nodes.cpu / openshift.nodes.gpu in the config."
  fi

  log "  ✓ Control-plane nodes: ${#control_nodes[@]}"
  log "  ✓ CPU worker nodes:    ${#cpu_nodes[@]}"
  log "  ✓ GPU worker nodes:    ${#gpu_nodes[@]}"
  log "Node labeling complete"
}

# ====== INSTALL CERT-MANAGER ======
install_cert_manager() {
  log "Installing cert-manager..."

  if oc get namespace cert-manager &>/dev/null; then
    log "  cert-manager namespace already exists, checking if running..."
    if oc get deployment cert-manager -n cert-manager &>/dev/null; then
      log "  ✓ cert-manager already installed, skipping"
      return 0
    fi
  fi

  oc apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

  log "Waiting for cert-manager to be ready..."
  oc wait --for=condition=ready pod \
    -l app.kubernetes.io/instance=cert-manager \
    -n cert-manager --timeout=300s

  # On OpenShift, cert-manager pods may need anyuid SCC
  oc adm policy add-scc-to-user anyuid \
    -z cert-manager -n cert-manager 2>/dev/null || true
  oc adm policy add-scc-to-user anyuid \
    -z cert-manager-cainjector -n cert-manager 2>/dev/null || true
  oc adm policy add-scc-to-user anyuid \
    -z cert-manager-webhook -n cert-manager 2>/dev/null || true

  log "Waiting for cert-manager webhook to be reachable with a valid TLS certificate..."
  # The webhook endpoint being ready is not enough — the TLS cert has a notBefore
  # timestamp ~30s in the future right after issuance. Probe by applying a test
  # Issuer and retrying until the x509 clock-skew error clears.
  # NOTE: heredoc inside $(...) is unreliable under set -euo pipefail; use a temp file.
  local probe_file
  probe_file=$(mktemp /tmp/cert-manager-probe-XXXXXX.yaml)
  cat > "${probe_file}" <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: cert-manager-webhook-probe
  namespace: cert-manager
spec:
  selfSigned: {}
EOF
  local retries=0
  while (( retries < 60 )); do
    local out
    out=$(oc apply -f "${probe_file}" 2>&1) || true
    if echo "${out}" | grep -q "x509: certificate\|failed to call webhook\|i/o timeout"; then
      sleep 5
      retries=$((retries + 1))
      (( retries % 6 == 0 )) && log "  Still waiting for cert-manager webhook TLS... (${retries}/60)"
      continue
    fi
    oc delete issuer cert-manager-webhook-probe -n cert-manager --ignore-not-found=true 2>/dev/null || true
    rm -f "${probe_file}"
    break
  done
  rm -f "${probe_file}" 2>/dev/null || true
  log "  ✓ cert-manager installed"
}

# ====== INSTALL LOCAL-PATH PROVISIONER ======
# k0s installs this as part of cluster setup. OpenShift has no default storage
# class on bare-metal, so we install local-path-provisioner the same way.
install_local_path_provisioner() {
  if oc get storageclass 2>/dev/null | grep -q "(default)"; then
    log "  ✓ Default storage class already exists, skipping local-path install"
    oc get storageclass
    return 0
  fi

  log "Installing local-path-provisioner (no default storage class found)..."
  oc apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml

  log "Waiting for local-path-provisioner to be ready..."
  oc rollout status deployment local-path-provisioner -n local-path-storage --timeout=120s || true

  log "Setting local-path as default storage class..."
  oc patch storageclass local-path \
    -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  # The main provisioner pod and the helper pod it spawns both need privileged SCC.
  # The main provisioner runs as local-path-provisioner-service-account.
  # The helper pod runs as the namespace's default SA (no serviceAccountName set).
  oc create clusterrolebinding local-path-provisioner-privileged \
    --clusterrole=system:openshift:scc:privileged \
    --serviceaccount=local-path-storage:local-path-provisioner-service-account \
    2>/dev/null || true
  oc create clusterrolebinding local-path-helper-privileged \
    --clusterrole=system:openshift:scc:privileged \
    --serviceaccount=local-path-storage:default \
    2>/dev/null || true

  # Patch the helper pod template to run privileged and relabel the created directory
  # with svirt_sandbox_file_t so containers can read/write it (SELinux on OpenShift).
  # Without the chcon, directories get var_t which containers cannot access.
  oc patch configmap local-path-config -n local-path-storage --type=merge -p "$(cat <<'PATCH'
{
  "data": {
    "helperPod.yaml": "apiVersion: v1\nkind: Pod\nmetadata:\n  name: helper-pod\nspec:\n  priorityClassName: system-node-critical\n  tolerations:\n    - key: node.kubernetes.io/disk-pressure\n      operator: Exists\n      effect: NoSchedule\n  containers:\n  - name: helper-pod\n    image: busybox\n    imagePullPolicy: IfNotPresent\n    securityContext:\n      privileged: true\n",
    "setup": "#!/bin/sh\nset -eu\nmkdir -m 0777 -p \"$VOL_DIR\"\nchcon -Rt container_file_t -l s0 \"$VOL_DIR\" 2>/dev/null || true\n"
  }
}
PATCH
  )"

  # Restart the provisioner so it picks up the new helper pod template
  oc rollout restart deployment local-path-provisioner -n local-path-storage
  oc rollout status deployment local-path-provisioner -n local-path-storage --timeout=60s || true

  log "  ✓ local-path-provisioner installed and set as default storage class"
}

# ====== RELABEL WORKER NODE HOST PATHS FOR SELINUX ======
# On OpenShift with SELinux enforcing, hostPath directories created by root get
# var_t label which containers cannot access. Relabel to container_file_t:s0
# (no MCS categories) so any container can read/write the volume.
relabel_worker_nodes_for_selinux() {
  log "Relabeling /opt/local-path-provisioner on worker nodes for SELinux..."
  local workers
  workers=$(oc get nodes -l '!node-role.kubernetes.io/master,!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  for node in ${workers}; do
    log "  Relabeling node ${node}..."
    oc debug "node/${node}" --image=registry.access.redhat.com/ubi8/ubi-minimal -- \
      sh -c "mkdir -p /host/opt/local-path-provisioner && \
             chcon -Rt container_file_t -l s0 /host/opt/local-path-provisioner/ 2>/dev/null || true; \
             echo relabeled" 2>/dev/null || \
    oc debug "node/${node}" -- \
      chroot /host sh -c "mkdir -p /opt/local-path-provisioner && \
             chcon -Rt container_file_t -l s0 /opt/local-path-provisioner/ 2>/dev/null || true" 2>/dev/null || true
  done
  log "  ✓ SELinux labels set on worker nodes"
}

# ====== INSTALL OPENTELEMETRY OPERATOR ======
install_otel_operator() {
  log "Installing OpenTelemetry Operator..."

  if oc get deployment opentelemetry-operator-controller-manager \
      -n opentelemetry-operator-system &>/dev/null; then
    log "  ✓ OpenTelemetry Operator already installed, skipping"
    return 0
  fi

  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
  helm repo update open-telemetry 2>/dev/null || true

  local otel_retries=0
  while (( otel_retries < 6 )); do
    local otel_out
    otel_out=$(helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
      --namespace opentelemetry-operator-system --create-namespace \
      --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib \
      --set admissionWebhooks.certManager.enabled=true \
      --wait=false --timeout=10m 2>&1)
    if echo "${otel_out}" | grep -q "x509: certificate\|failed to call webhook\|i/o timeout"; then
      warn "cert-manager webhook not ready yet, waiting 10s (${otel_retries}/6)..."
      sleep 10
      otel_retries=$((otel_retries + 1))
      continue
    fi
    echo "${otel_out}"
    break
  done

  # Grant privileged SCC before pods start (runs as UID 65532 which is outside OCP's range)
  oc create clusterrolebinding otel-operator-privileged \
    --clusterrole=system:openshift:scc:privileged \
    --serviceaccount=opentelemetry-operator-system:opentelemetry-operator \
    2>/dev/null || true

  oc rollout status deployment opentelemetry-operator \
    -n opentelemetry-operator-system --timeout=5m || \
    oc rollout restart deployment opentelemetry-operator \
      -n opentelemetry-operator-system

  wait_for_crd opentelemetrycollectors.opentelemetry.io 300
  log "  ✓ OpenTelemetry Operator installed"
}

# ====== INSTALL KUBERAY OPERATOR ======
install_ray_operator() {
  log "Installing KubeRay Operator..."

  if oc get deployment kuberay-operator -n ray-system &>/dev/null; then
    log "  ✓ KubeRay Operator already installed, skipping"
    return 0
  fi

  helm repo add kuberay https://ray-project.github.io/kuberay-helm/ 2>/dev/null || true
  helm repo update kuberay

  helm upgrade --install kuberay-operator kuberay/kuberay-operator \
    --namespace ray-system --create-namespace \
    --version 1.2.2 \
    --set image.repository=quay.io/kuberay/operator \
    --set image.tag=v1.2.2 \
    --wait --timeout=10m

  wait_for_crd rayservices.ray.io 300
  wait_for_crd rayclusters.ray.io 300

  log "  ✓ KubeRay Operator installed"
}

# ====== ECR PULL SECRET ======
# Creates ecr-registry-secret in every namespace that pulls ECR images.
# Uses --dry-run=client | apply so it is idempotent (safe to re-run).
ensure_ecr_pull_secret() {
  if [[ "${ECR_ENABLED}" != "true" ]]; then
    log "ECR pull secret disabled (ecr.enabled=false), skipping"
    return 0
  fi

  log "Creating ECR pull secret (account=${ECR_ACCOUNT}, region=${ECR_REGION})..."

  if ! aws sts get-caller-identity &>/dev/null; then
    warn "AWS credentials not available — skipping ECR secret creation."
    warn "Pods pulling from ECR will fail. Export AWS credentials and re-run install."
    return 0
  fi

  local ecr_password
  if ! ecr_password=$(aws ecr get-login-password --region "${ECR_REGION}" 2>/dev/null); then
    warn "Failed to get ECR token — skipping secret creation"
    return 0
  fi

  local server="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com"
  for ns in splunk-ai-operator-system "${AI_NS}"; do
    ensure_namespace "${ns}"
    oc create secret docker-registry ecr-registry-secret \
      --docker-server="${server}" \
      --docker-username=AWS \
      --docker-password="${ecr_password}" \
      --namespace="${ns}" \
      --dry-run=client -o yaml | oc apply -f -

    # Append ecr-registry-secret to the default SA only if not already present.
    # Using JSON patch add rather than a merge patch to avoid overwriting existing pull secrets.
    if ! oc get serviceaccount default -n "${ns}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null | grep -qw ecr-registry-secret; then
      oc patch serviceaccount default -n "${ns}" --type=json \
        -p='[{"op":"add","path":"/imagePullSecrets","value":[]}]' 2>/dev/null || true
      oc patch serviceaccount default -n "${ns}" --type=json \
        -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ecr-registry-secret"}}]' 2>/dev/null || true
    fi

    log "  ✓ ecr-registry-secret created in ${ns}"
  done

  # Also patch the operator SA specifically
  oc patch serviceaccount splunk-ai-operator-controller-manager \
    -n splunk-ai-operator-system \
    -p '{"imagePullSecrets": [{"name": "ecr-registry-secret"}]}' 2>/dev/null || true
}

# ====== INSTALL SPLUNK AI OPERATOR ======
install_splunk_ai_operator() {
  log "Installing Splunk AI Operator from ${SPLUNK_AI_FILE}..."

  [[ -f "${SPLUNK_AI_FILE}" ]] || { warn "Manifest not found: ${SPLUNK_AI_FILE}"; return 0; }

  local ai_operator_ns="splunk-ai-operator-system"
  ensure_namespace "${ai_operator_ns}"

  # Grant SCCs before applying manifests so pods start on first attempt
  grant_privileged_scc

  log "Applying Splunk AI Operator manifests (server-side apply)..."
  local apply_output
  apply_output=$(oc apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1) || true
  echo "${apply_output}"

  # Retry if cert-manager webhook not ready OR if cert-manager CRD mapping was missing.
  # Certificate/Issuer resources silently fail with "resource mapping not found" when
  # cert-manager pods are up but CRDs haven't been registered in the API server yet.
  if echo "${apply_output}" | grep -qi "webhook.*cert-manager\|failed calling webhook.*cert-manager\|i/o timeout\|resource mapping not found\|no matches for kind.*cert-manager"; then
    warn "cert-manager CRDs not ready, waiting 20s and retrying full apply..."
    sleep 20
    oc apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1 || true
  fi

  # Inject the local instance.yaml so the operator knows about RTX_PRO_6000_BLACKWELL
  # and other accelerators that may not be baked into the operator image.
  local instance_src
  instance_src="$(dirname "${SPLUNK_AI_FILE}")/../../config/configs/instance.yaml"
  if [[ ! -f "${instance_src}" ]]; then
    instance_src="$(cd "$(dirname "$0")/../.." && pwd)/config/configs/instance.yaml"
  fi
  if [[ -f "${instance_src}" ]]; then
    oc create configmap splunk-ai-operator-instance-yaml \
      -n "${ai_operator_ns}" \
      --from-file=instance.yaml="${instance_src}" \
      --dry-run=client -o yaml | oc -n "${ai_operator_ns}" apply -f -
    # Mount the ConfigMap and set INSTANCE_FILE so the operator uses it
    oc patch deployment splunk-ai-operator-controller-manager \
      -n "${ai_operator_ns}" --type=json -p='[
        {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"instance-yaml","configMap":{"name":"splunk-ai-operator-instance-yaml"}}},
        {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"instance-yaml","mountPath":"/etc/instance","readOnly":true}},
        {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"INSTANCE_FILE","value":"/etc/instance/instance.yaml"}}
      ]' 2>/dev/null || true
    log "  ✓ instance.yaml ConfigMap injected into operator"
  else
    warn "instance.yaml not found at ${instance_src} — defaultAcceleratorType may not resolve"
  fi

  # Patch the operator SA and deployment with ECR pull secret AFTER the manifest apply
  # (the SA is created by the manifest; patching before apply silently does nothing).
  if [[ "${ECR_ENABLED}" == "true" ]]; then
    oc patch serviceaccount splunk-ai-operator-controller-manager \
      -n "${ai_operator_ns}" \
      -p '{"imagePullSecrets": [{"name": "ecr-registry-secret"}]}' 2>/dev/null || true
    oc patch deployment splunk-ai-operator-controller-manager \
      -n "${ai_operator_ns}" --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"ecr-registry-secret"}]}]' \
      2>/dev/null || true
    log "  ✓ ECR pull secret patched into operator SA and deployment"
  fi

  # Rollout restart so the deployment picks up pull secrets and instance.yaml.
  oc rollout restart deployment splunk-ai-operator-controller-manager \
    -n "${ai_operator_ns}" 2>/dev/null || true

  # Wait for operator deployment to be ready — use the deployment name directly,
  # not a label selector, to avoid matching stale ReplicaSets.
  # A generous timeout per attempt; the outer loop gives up to 10 minutes total.
  log "Waiting for Splunk AI Operator deployment to be ready..."
  local retries=0
  while (( retries < 40 )); do
    if oc rollout status deployment/splunk-ai-operator-controller-manager \
        -n "${ai_operator_ns}" --timeout=30s 2>/dev/null; then
      break
    fi
    # If the pod is stuck terminating, force-delete it to unblock the rollout
    local terminating
    terminating=$(oc get pods -n "${ai_operator_ns}" \
      --field-selector=status.phase=Running \
      -l control-plane=controller-manager \
      -o jsonpath='{.items[?(@.metadata.deletionTimestamp)].metadata.name}' 2>/dev/null || true)
    if [[ -n "${terminating}" ]]; then
      log "  Force-deleting stuck terminating pod: ${terminating}"
      oc delete pod "${terminating}" -n "${ai_operator_ns}" --grace-period=0 --force 2>/dev/null || true
    fi
    sleep 10
    retries=$((retries + 1))
    (( retries % 3 == 0 )) && log "  Waiting for operator... (${retries}/40)"
  done

  # Wait for the webhook service to have endpoints — the pod being Running is not
  # enough; the API server needs to register the endpoint before we apply CRs.
  log "Waiting for Splunk AI Operator webhook endpoint to be ready..."
  local wh_retries=0
  while (( wh_retries < 60 )); do
    local ep_count
    ep_count=$(oc get endpoints splunk-ai-operator-webhook-service \
      -n "${ai_operator_ns}" -o jsonpath='{.subsets[*].addresses}' 2>/dev/null | wc -w | tr -d ' ')
    if [[ "${ep_count}" -gt 0 ]]; then
      log "  ✓ Webhook endpoint ready"
      break
    fi
    sleep 5
    wh_retries=$((wh_retries + 1))
    (( wh_retries % 6 == 0 )) && log "  Still waiting for webhook endpoint... (${wh_retries}/60)"
  done

  log "  ✓ Splunk AI Operator installed"
}

# ====== INSTALL SPLUNK OPERATOR ======
install_splunk_operator() {
  log "Installing Splunk Operator..."

  [[ -f "${SPLUNK_OPERATOR_FILE}" ]] || { warn "Splunk operator file not found: ${SPLUNK_OPERATOR_FILE}, skipping"; return 0; }

  local splunk_operator_ns="splunk-operator"
  ensure_namespace "${splunk_operator_ns}"

  # Create ECR pull secret in splunk-operator namespace
  if [[ "${ECR_ENABLED}" == "true" ]]; then
    local ecr_password
    if ecr_password=$(aws ecr get-login-password --region "${ECR_REGION}" 2>/dev/null); then
      oc create secret docker-registry ecr-registry-secret \
        --docker-server="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com" \
        --docker-username=AWS \
        --docker-password="${ecr_password}" \
        --namespace="${splunk_operator_ns}" \
        --dry-run=client -o yaml | oc apply -f -
    fi
  fi

  if oc create -f "${SPLUNK_OPERATOR_FILE}" 2>/dev/null; then
    log "  Splunk Operator resources created"
  else
    log "  Resources already exist, updating..."
    oc replace --force -f "${SPLUNK_OPERATOR_FILE}" 2>&1 | grep -v "Warning: --force is deprecated" || true
  fi

  # Grant privileged SCC to the whole namespace group — this is the pattern OCP SCC admission
  # actually honours. The operator pod adds NET_BIND_SERVICE which anyuid blocks; privileged
  # covers both. group-based grant survives replace --force (which recreates the namespace).
  oc adm policy add-scc-to-group privileged \
    "system:serviceaccounts:${splunk_operator_ns}" 2>/dev/null || true
  # Force pod recreation so it picks up the new SCC grant
  oc delete replicaset -n "${splunk_operator_ns}" --all 2>/dev/null || true

  # Patch deployment with pull secret if present
  local dep_name
  dep_name=$(oc -n "${splunk_operator_ns}" get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${dep_name}" ]] && oc get secret ecr-registry-secret -n "${splunk_operator_ns}" &>/dev/null; then
    oc -n "${splunk_operator_ns}" patch deployment "${dep_name}" \
      --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"ecr-registry-secret"}]}]' \
      2>/dev/null || true
    oc rollout restart deployment "${dep_name}" -n "${splunk_operator_ns}" 2>/dev/null || true
  fi

  wait_for_crd standalones.enterprise.splunk.com 300
  log "  ✓ Splunk Operator installed"
}

# ====== INSTALL SPLUNK STANDALONE ======
install_splunk_standalone() {
  log "Installing Splunk Standalone: ${AI_STANDALONE_NAME} in ${AI_NS}..."

  ensure_namespace "${AI_NS}"
  wait_for_crd standalones.enterprise.splunk.com 600

  # Wait for object store endpoint to be reachable before creating credentials secret
  if [[ -n "${OBJ_STORE_ENDPOINT}" ]]; then
    wait_for_dependency \
      "object store (${OBJ_STORE_TYPE}) at ${OBJ_STORE_ENDPOINT}" \
      "curl -sL --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' '${OBJ_STORE_ENDPOINT}' 2>/dev/null | grep -qE '^[0-9]'" \
      300
  fi

  # Object storage credentials secret
  oc -n "${AI_NS}" create secret generic minio-credentials \
    --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
    --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
    --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
    --from-literal=MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" \
    --from-literal=MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
    --dry-run=client -o yaml | oc -n "${AI_NS}" apply -f -

  # Derive S3 endpoint for Splunk appRepo (endpoint is required by the Splunk Operator)
  local minio_endpoint="${OBJ_STORE_ENDPOINT}"
  if [[ -z "${minio_endpoint}" && "${OBJ_STORE_TYPE}" == "aws" ]]; then
    minio_endpoint="https://s3.${ECR_REGION}.amazonaws.com"
    log "  type=aws: using S3 endpoint ${minio_endpoint}"
  fi
  [[ -z "${minio_endpoint}" ]] && err "storage.objectStore.endpoint must be set for type=${OBJ_STORE_TYPE}"

  # Configure Splunk to use the service URL as the token issuer so that JWT
  # tokens have iss=https://splunk-splunk-standalone-standalone-service:8089,
  # matching SAIA's SPLUNK_ISSUERS. Without this, Splunk uses the pod hostname
  # as issuer (e.g. splunk-splunk-standalone-standalone-0) and SAIA rejects
  # tokens with "Issuer not allowed".
  cat <<'YAML' | oc -n "${AI_NS}" apply -f -
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

  oc apply --server-side --force-conflicts -f - <<YAML
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  replicas: 1
  volumes:
    - name: defaults
      configMap:
        name: splunk-defaults
  defaultsUrl: /mnt/defaults/default.yml
  appRepo:
    appSources:
      - name: apps
        scope: local
        location: apps
    defaults:
      scope: local
      volumeName: volume_app_repo
    volumes:
      - name: volume_app_repo
        provider: aws
        storageType: s3
        endpoint: ${minio_endpoint}
        region: ${ECR_REGION}
        path: ${OBJ_STORE_BUCKET}
        secretRef: minio-credentials
YAML

  log "  ✓ Splunk Standalone CR applied"
}

# ====== INSTALL AI PLATFORM CR ======
install_ai_platform_cr() {
  log "Installing AIPlatform CR: ${AI_PLATFORM_NAME}..."

  ensure_namespace "${AI_NS}"

  # Clean up stuck pods from previous runs
  oc delete jobs -n "${AI_NS}" --field-selector status.successful=0 --wait=false 2>/dev/null || true
  oc delete pods -n "${AI_NS}" --field-selector status.phase=Failed --wait=false 2>/dev/null || true

  # Build imagePullSecrets block
  local secrets_yaml=""
  for secret_name in ecr-registry-secret; do
    oc get secret "${secret_name}" -n "${AI_NS}" &>/dev/null && \
      secrets_yaml+="      - name: ${secret_name}"$'\n'
  done
  local image_pull_secrets=""
  [[ -n "${secrets_yaml}" ]] && image_pull_secrets="    imagePullSecrets:"$'\n'"${secrets_yaml}"

  # Object storage path and endpoint
  local obj_path obj_endpoint
  case "${OBJ_STORE_TYPE}" in
    aws)       obj_path="s3://${OBJ_STORE_BUCKET}";       obj_endpoint="" ;;
    s3compat)  obj_path="s3compat://${OBJ_STORE_BUCKET}"; obj_endpoint="${OBJ_STORE_ENDPOINT}" ;;
    minio)     obj_path="minio://${OBJ_STORE_BUCKET}";    obj_endpoint="${OBJ_STORE_ENDPOINT}" ;;
    seaweedfs) obj_path="minio://${OBJ_STORE_BUCKET}";    obj_endpoint="${OBJ_STORE_ENDPOINT}" ;;
    *) err "Unsupported objectStore.type: ${OBJ_STORE_TYPE}" ;;
  esac

  # Features
  local features_yaml=""
  local feature_count
  feature_count=$(yq eval '.aiPlatform.features | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
  if [[ "${feature_count}" -gt 0 ]]; then
    local i=0
    while [[ $i -lt $feature_count ]]; do
      local fname fver
      fname=$(yq eval ".aiPlatform.features[$i].name" "${CONFIG_FILE}")
      fver=$(yq eval ".aiPlatform.features[$i].version // \"1.0.0\"" "${CONFIG_FILE}")
      [[ -n "$fname" && "$fname" != "null" ]] && \
        features_yaml+="    - name: ${fname}"$'\n'"      version: \"${fver}\""$'\n'
      i=$((i + 1))
    done
  else
    features_yaml="    - name: saia"$'\n'"      version: \"1.1.0\""$'\n'
  fi

  # Service template
  local svc_template_yaml=""
  local svc_type
  svc_type=$(yq eval '.aiPlatform.serviceTemplate.type // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  if [[ -n "${svc_type}" && "${svc_type}" != "null" && "${svc_type}" != "ClusterIP" ]]; then
    local svc_node_port
    svc_node_port=$(yq eval '.aiPlatform.serviceTemplate.nodePort // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    svc_template_yaml="  serviceTemplate:"$'\n'"    spec:"$'\n'"      type: ${svc_type}"$'\n'
    if [[ -n "${svc_node_port}" && "${svc_type}" == "NodePort" ]]; then
      svc_template_yaml+="      ports:"$'\n'"      - name: http"$'\n'"        port: 8080"$'\n'"        targetPort: 8080"$'\n'"        nodePort: ${svc_node_port}"$'\n'
    fi
  fi

  # The operator looks up splunk-<namespace>-secret for the HEC token.
  # Extract it from the Splunk standalone secret created by the Splunk Operator.
  local splunk_ns_secret="splunk-${AI_NS}-secret"
  local standalone_secret="splunk-${AI_STANDALONE_NAME}-standalone-secret-v1"
  log "  Waiting for Splunk standalone secret ${standalone_secret}..."
  local retries=0
  while (( retries < 60 )); do
    if oc get secret "${standalone_secret}" -n "${AI_NS}" &>/dev/null; then
      local hec_token
      hec_token=$(oc get secret "${standalone_secret}" -n "${AI_NS}" \
        -o jsonpath='{.data.hec_token}' 2>/dev/null || echo "")
      if [[ -n "${hec_token}" ]]; then
        oc -n "${AI_NS}" create secret generic "${splunk_ns_secret}" \
          --from-literal=hec_token="$(echo "${hec_token}" | base64 -d)" \
          --dry-run=client -o yaml | oc apply -f -
        log "  ✓ ${splunk_ns_secret} created"
        break
      fi
    fi
    sleep 10
    retries=$(( retries + 1 ))
    log "  Waiting for Splunk secret... (${retries}/60)"
  done
  if (( retries >= 60 )); then
    warn "Splunk secret not ready after 10m — AIPlatform reconcile will retry automatically"
  fi

  local storage_yaml=""
  if [[ -n "${STORAGE_CLASS}" && "${STORAGE_CLASS}" != "null" ]]; then
    storage_yaml="  storage:"$'\n'"    vectorDB:"$'\n'"      size: ${VECTORDB_SIZE}"$'\n'"      storageClassName: ${STORAGE_CLASS}"$'\n'
  fi

  # Probe the AIPlatform webhook TLS cert immediately before applying.
  # cert-manager issues certs with notBefore ~30-60s in the future (clock skew);
  # retry until the x509 error clears. Using --dry-run=server hits the exact
  # same webhook (maiplatform-v1.kb.io) without creating anything.
  local ai_operator_ns="splunk-ai-operator-system"
  local tls_probe_file
  tls_probe_file=$(mktemp /tmp/aiplatform-tls-probe-XXXXXX.yaml)
  cat > "${tls_probe_file}" <<'PROBE_EOF'
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: webhook-tls-probe
  namespace: splunk-ai-operator-system
spec:
  defaultAcceleratorType: L40S
  objectStorage:
    path: s3://probe/probe
PROBE_EOF
  local tls_retries=0
  while (( tls_retries < 60 )); do
    local tls_out
    tls_out=$(oc apply --dry-run=server -f "${tls_probe_file}" 2>&1) || true
    if echo "${tls_out}" | grep -q "x509:\|not yet valid\|certificate has expired\|failed to verify certificate\|failed to call webhook"; then
      sleep 5
      tls_retries=$((tls_retries + 1))
      (( tls_retries % 6 == 0 )) && log "  Still waiting for operator webhook TLS cert... (${tls_retries}/60)"
      continue
    fi
    log "  ✓ Operator webhook TLS certificate valid"
    break
  done
  rm -f "${tls_probe_file}" 2>/dev/null || true

  oc -n "${AI_NS}" apply --server-side --force-conflicts -f - <<YAML
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${AI_PLATFORM_NAME}
spec:
  objectStorage:
    path: ${obj_path}
    region: ${ECR_REGION}
    $( [[ -n "${obj_endpoint}" ]] && echo "endpoint: \"${obj_endpoint}\"" )
    secretRef: minio-credentials
  images:
${image_pull_secrets}
  defaultAcceleratorType: ${DEFAULT_ACCELERATOR}
  features:
${features_yaml}
${svc_template_yaml}${storage_yaml}
  workerGroupConfig:
    imageRegistry: "${WORKER_IMAGE_REGISTRY}"
  cpuScheduler:
    nodeSelector:
      splunk.ai/workload-type: cpu
    tolerations: []
  gpuScheduler:
    nodeSelector:
      splunk.ai/workload-type: gpu
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
  splunkConfiguration:
    endpoint: http://${AI_STANDALONE_NAME}-standalone-service.${AI_NS}.svc.cluster.local:8089
    secretRef:
      name: ${splunk_ns_secret}
      namespace: ${AI_NS}
YAML

  log "  ✓ AIPlatform CR applied"

  local timeout=60 elapsed=0
  while ! oc get aiplatform "${AI_PLATFORM_NAME}" -n "${AI_NS}" >/dev/null 2>&1; do
    sleep 5; elapsed=$((elapsed + 5))
    [[ ${elapsed} -ge ${timeout} ]] && { warn "Timeout waiting for AIPlatform CR"; break; }
  done

  oc get aiplatform "${AI_PLATFORM_NAME}" -n "${AI_NS}" -o wide || true
  log "  ✓ AIPlatform CR installed"
}

# ====== MAIN INSTALL ======
main_install() {
  log "============================================"
  log " Splunk AI Platform — OpenShift Install"
  log "============================================"

  load_config
  validate_image_config
  configure_images

  show_install_plan

  phase_start "Preflight"
  step_start "Preflight checks"
  preflight_checks
  step_ok
  phase_end "Preflight"

  phase_start "Infrastructure"
  step_start "NFD Operator"
  install_nfd
  step_ok

  step_start "NVIDIA GPU Operator"
  install_nvidia_gpu_operator
  step_ok

  step_start "Node labeling"
  label_nodes
  step_ok

  step_start "local-path-provisioner + SELinux"
  install_local_path_provisioner
  relabel_worker_nodes_for_selinux
  step_ok
  phase_end "Infrastructure"

  phase_start "Operators"
  step_start "cert-manager"
  install_cert_manager
  step_ok

  step_start "OpenTelemetry Operator"
  install_otel_operator
  step_ok

  step_start "KubeRay Operator"
  install_ray_operator
  step_ok

  step_start "ECR pull secrets"
  ensure_ecr_pull_secret
  step_ok

  step_start "Splunk AI Operator"
  install_splunk_ai_operator
  step_ok

  step_start "Splunk Operator"
  install_splunk_operator
  step_ok
  phase_end "Operators"

  phase_start "AI Platform Stack"
  step_start "Splunk Standalone CR"
  install_splunk_standalone
  step_ok

  step_start "AIPlatform CR"
  install_ai_platform_cr
  step_ok
  phase_end "AI Platform Stack"

  show_step_summary

  log "============================================"
  log " Install complete"
  log "============================================"
  log ""
  log "Next steps:"
  log "  1. Verify resources:"
  log "     oc get aiplatform,aiservice,raycluster,rayservice -n ${AI_NS}"
  log "  2. Check operator logs:"
  log "     oc logs -n splunk-ai-operator-system -l control-plane=controller-manager -f"
  log "  3. Watch Ray cluster:"
  log "     oc get raycluster,rayservice -n ${AI_NS} -w"
  log ""
  log "Log file: ${LOG_FILE}"
}

# ====== MAIN DELETE ======
main_delete() {
  log "============================================"
  log " Splunk AI Platform — OpenShift Delete"
  log "============================================"

  load_config

  if ! oc whoami &>/dev/null; then
    err "Not logged in to OpenShift. Run: oc login <cluster-url>"
  fi

  log "  Namespace   : ${AI_NS}"
  log "  Cluster     : $(oc whoami --show-server 2>/dev/null || echo '<unknown>')"
  log "============================================"
  log ""
  warn "This will DELETE the AI Platform stack from the OpenShift cluster."
  warn "The cluster nodes themselves will remain running."
  warn "This action CANNOT be undone."
  log ""

  if [[ "${AUTO_APPROVE:-false}" != "true" ]]; then
    echo -e "  \033[1;31mType 'yes' to confirm deletion, or Ctrl-C to abort:\033[0m" >&2
    local confirm_input
    read -r confirm_input
    if [[ "${confirm_input}" != "yes" ]]; then
      echo "Aborted — confirmation not given." >&2
      exit 0
    fi
    log "Confirmed. Proceeding with deletion..."
  else
    log "AUTO_APPROVE=true — skipping confirmation prompt."
  fi

  local ai_operator_ns="splunk-ai-operator-system"
  local splunk_operator_ns="splunk-operator"

  # ── 1. AI Platform CRs (trigger operator finalizers before namespace delete) ──
  log "Removing AIPlatform CR and waiting for finalizers..."
  oc delete aiplatform --all -n "${AI_NS}" --timeout=120s 2>/dev/null || true
  oc delete standalone --all -n "${AI_NS}" --timeout=60s 2>/dev/null || true

  # ── 2. AI Platform namespace (cascades all pods, PVCs, services, etc.) ──
  log "Deleting namespace ${AI_NS}..."
  oc delete namespace "${AI_NS}" --timeout=180s 2>/dev/null || true

  # ── 3. Splunk AI Operator ──
  log "Removing Splunk AI Operator..."
  oc delete namespace "${ai_operator_ns}" --timeout=60s 2>/dev/null || true
  # Remove cluster-scoped resources (CRDs, ClusterRoles, webhooks) from manifests
  [[ -f "${SPLUNK_AI_FILE}" ]] && \
    oc delete -f "${SPLUNK_AI_FILE}" --ignore-not-found=true 2>/dev/null || true

  # ── 4. Splunk Operator ──
  log "Removing Splunk Operator..."
  oc delete namespace "${splunk_operator_ns}" --timeout=60s 2>/dev/null || true
  [[ -f "${SPLUNK_OPERATOR_FILE}" ]] && \
    oc delete -f "${SPLUNK_OPERATOR_FILE}" --ignore-not-found=true 2>/dev/null || true

  # ── 5. KubeRay Operator (helm) ──
  log "Removing KubeRay Operator..."
  helm uninstall kuberay-operator -n ray-system 2>/dev/null || true
  oc delete namespace ray-system --timeout=60s 2>/dev/null || true

  # ── 6. OpenTelemetry Operator (helm) ──
  log "Removing OpenTelemetry Operator..."
  helm uninstall opentelemetry-operator -n opentelemetry-operator-system 2>/dev/null || true
  oc delete namespace opentelemetry-operator-system --timeout=60s 2>/dev/null || true

  # ── 7. cert-manager (helm) ──
  log "Removing cert-manager..."
  helm uninstall cert-manager -n cert-manager 2>/dev/null || true
  oc delete namespace cert-manager --timeout=60s 2>/dev/null || true
  # Remove CRDs left by cert-manager (helm uninstall doesn't remove CRDs by default)
  oc get crd -o name 2>/dev/null | grep cert-manager | xargs -r oc delete --ignore-not-found=true 2>/dev/null || true

  # ── 8. local-path-provisioner ──
  log "Removing local-path-provisioner..."
  oc delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml \
    --ignore-not-found=true 2>/dev/null || true
  oc delete namespace local-path-storage --timeout=60s 2>/dev/null || true
  oc delete storageclass local-path --ignore-not-found=true 2>/dev/null || true

  # ── 9. NVIDIA GPU Operator ──
  log "Removing NVIDIA GPU Operator..."
  oc delete clusterpolicy gpu-cluster-policy --ignore-not-found=true 2>/dev/null || true
  oc delete subscription gpu-operator-certified -n nvidia-gpu-operator --ignore-not-found=true 2>/dev/null || true
  oc delete csv -n nvidia-gpu-operator --all --ignore-not-found=true 2>/dev/null || true
  oc delete namespace nvidia-gpu-operator --timeout=60s 2>/dev/null || true

  # ── 10. NFD ──
  log "Removing Node Feature Discovery..."
  oc delete nodefeaturediscovery nfd-instance -n openshift-nfd --ignore-not-found=true 2>/dev/null || true
  oc delete subscription nfd -n openshift-nfd --ignore-not-found=true 2>/dev/null || true
  oc delete csv -n openshift-nfd --all --ignore-not-found=true 2>/dev/null || true
  oc delete namespace openshift-nfd --timeout=60s 2>/dev/null || true

  # ── 11. Node labels and taints added by label_nodes() ──
  log "Removing splunk.ai/* node labels and GPU taint..."
  for node in $(oc get nodes -l 'splunk.ai/workload-type' -o name 2>/dev/null); do
    oc label "${node}" splunk.ai/workload-type- 2>/dev/null || true
    oc taint "${node}" nvidia.com/gpu=true:NoSchedule- 2>/dev/null || true
  done

  # ── 12. SCC grants added during install ──
  if [[ "${GRANT_PRIVILEGED_SCC}" == "true" ]]; then
    log "Removing SCC grants..."
    oc adm policy remove-scc-from-group privileged \
      "system:serviceaccounts:${ai_operator_ns}" 2>/dev/null || true
    oc adm policy remove-scc-from-group anyuid \
      "system:serviceaccounts:${AI_NS}" 2>/dev/null || true
    oc adm policy remove-scc-from-group privileged \
      "system:serviceaccounts:${AI_NS}" 2>/dev/null || true
    oc adm policy remove-scc-from-group privileged \
      "system:serviceaccounts:local-path-storage" 2>/dev/null || true
    oc adm policy remove-scc-from-group privileged \
      "system:serviceaccounts:splunk-operator" 2>/dev/null || true
  fi

  # Remove individual ClusterRoleBindings created during install
  for crb in \
    local-path-provisioner-privileged \
    local-path-helper-privileged \
    splunk-standalone-privileged \
    splunk-operator-privileged \
    splunk-operator-anyuid \
    otel-operator-privileged \
    otel-operator-anyuid \
    scc-privileged-ai-platform-all \
    scc-privileged-splunk-ai-operator-system-default \
    scc-privileged-splunk-ai-operator-system-splunk-ai-operator-controller-manager; do
    oc delete clusterrolebinding "${crb}" --ignore-not-found=true 2>/dev/null || true
  done

  # ── 13. ECR pull secret ClusterRoleBindings ──
  oc delete clusterrolebinding ecr-registry-secret-updater 2>/dev/null || true

  log "============================================"
  log " Delete complete"
  log "============================================"
  log ""
  log "Cluster itself is untouched — only the AI Platform stack was removed."
  log "Log file: ${LOG_FILE}"
}

# ====== DIAGNOSE SUBCOMMAND ======
diagnose() {
  load_config 2>/dev/null || true

  local bundle_dir
  bundle_dir="$(mktemp -d)/splunk-ai-diagnose-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "${bundle_dir}"

  log "=== Collecting support bundle into ${bundle_dir} ==="

  # 1. Installer logs
  log "Collecting installer logs..."
  cp "${LOG_DIR}"/openshift-install-*.log "${bundle_dir}/" 2>/dev/null || true

  # 2. Cluster state (best-effort — cluster may be unreachable)
  if timeout 10 oc cluster-info &>/dev/null 2>&1; then
    log "Collecting cluster state..."
    oc get nodes -o wide                                         > "${bundle_dir}/nodes.txt"        2>&1 || true
    oc get pods --all-namespaces -o wide                         > "${bundle_dir}/pods.txt"         2>&1 || true
    oc get events --all-namespaces --sort-by='.lastTimestamp'    > "${bundle_dir}/events.txt"       2>&1 || true
    oc get pvc --all-namespaces                                  > "${bundle_dir}/pvcs.txt"         2>&1 || true
    oc get svc --all-namespaces                                  > "${bundle_dir}/services.txt"     2>&1 || true
    oc describe nodes                                            > "${bundle_dir}/node-details.txt" 2>&1 || true

    # Per-namespace pod logs for failing pods
    log "Collecting logs from non-Running pods..."
    local ns pod
    while IFS= read -r line; do
      ns=$(echo "${line}" | awk '{print $1}')
      pod=$(echo "${line}" | awk '{print $2}')
      mkdir -p "${bundle_dir}/pod-logs/${ns}"
      oc logs "${pod}" -n "${ns}" --tail=200 \
        > "${bundle_dir}/pod-logs/${ns}/${pod}.log" 2>&1 || true
      oc logs "${pod}" -n "${ns}" --previous --tail=100 \
        > "${bundle_dir}/pod-logs/${ns}/${pod}.previous.log" 2>&1 || true
    done < <(oc get pods --all-namespaces --no-headers 2>/dev/null \
             | awk '$4 != "Running" && $4 != "Completed" {print $1, $2}')

    # AI Platform specific resources
    oc describe aiplatform --all -n "${AI_NS:-ai-platform}" > "${bundle_dir}/aiplatform-cr.txt" 2>&1 || true
    oc describe aiservice  --all -n "${AI_NS:-ai-platform}" > "${bundle_dir}/aiservice-cr.txt"  2>&1 || true

    # Operator logs
    oc logs -n splunk-ai-operator-system -l control-plane=controller-manager --tail=500 \
      > "${bundle_dir}/operator-logs.txt" 2>&1 || true
  else
    warn "Cluster not reachable — skipping oc diagnostics."
    echo "Cluster unreachable at time of diagnose run." > "${bundle_dir}/CLUSTER_UNREACHABLE.txt"
  fi

  # 3. Config file (redact credentials)
  if [[ -f "${CONFIG_FILE}" ]]; then
    log "Including config file (credentials redacted)..."
    sed 's/\(rootUser\|rootPassword\|AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY\|accessKey\|secretKey\):.*/\1: <REDACTED>/g' \
      "${CONFIG_FILE}" > "${bundle_dir}/cluster-config-redacted.yaml"
  fi

  # 4. Tool versions
  {
    echo "=== Tool versions ==="
    oc version 2>/dev/null || true
    helm version 2>/dev/null || true
    yq --version 2>/dev/null || true
    echo "=== OS ==="
    uname -a
  } > "${bundle_dir}/versions.txt" 2>&1

  # 5. Pack into tar.gz
  local bundle_tar="${bundle_dir}.tar.gz"
  tar -czf "${bundle_tar}" -C "$(dirname "${bundle_dir}")" "$(basename "${bundle_dir}")" 2>/dev/null
  rm -rf "${bundle_dir}"

  log "=== Support bundle ready: ${bundle_tar} ==="
  log "Attach this file to your support ticket or share with the team."
}

# ====== USAGE ======
usage() {
  cat <<EOF
Usage: $(basename "$0") [install|delete|diagnose]

  install   Deploy the Splunk AI Platform stack onto an existing OpenShift cluster.
  delete    Remove the Splunk AI Platform stack (leaves the cluster intact).
  diagnose  Collect a support bundle (logs, cluster state, config) into a tar.gz.

Config file: ${CONFIG_FILE}
  Override with: CONFIG_FILE=/path/to/config.yaml $(basename "$0")

Environment:
  AUTO_APPROVE=true  Skip confirmation prompts (for CI/CD use)

Prerequisites:
  - Logged in to OpenShift: oc login <cluster-url>
  - oc, yq, helm in PATH
  - artifacts.yaml (operator manifests) in the same directory, or set files.aiPlatform in config
EOF
}

# ====== MAIN ======
case "${1:-install}" in
  install)
    main_install
    ;;
  delete)
    main_delete
    ;;
  diagnose)
    diagnose
    ;;
  *)
    usage
    exit 1
    ;;
esac
