#!/bin/bash
set -euo pipefail

# Temp files rendered during a run (e.g. patched manifest copies) are tracked
# here and removed on exit so we never mutate committed manifests.
TMP_FILES=()
cleanup_tmp() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}" 2>/dev/null || true; }
trap cleanup_tmp EXIT

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

# ====== FORCE DELETE NAMESPACE ======
# Deletes a namespace cleanly. Before issuing the delete, force-removes any
# pods stuck Terminating on NotReady nodes — those pod finalizers are what
# cause namespaces to hang. Falls back to clearing namespace finalizers
# directly if the namespace still gets stuck after pod cleanup.
force_delete_namespace() {
  local ns="$1" timeout="${2:-60}"

  # Pre-emptively force-delete any pods stuck on NotReady nodes so the
  # namespace can terminate without waiting for a dead kubelet.
  local not_ready_nodes
  not_ready_nodes=$(oc get nodes --no-headers 2>/dev/null \
    | awk '$2 != "Ready" {print $1}' | tr '\n' '|' | sed 's/|$//')
  if [[ -n "${not_ready_nodes}" ]]; then
    oc get pods -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
      | awk -v nodes="${not_ready_nodes}" '$2 ~ nodes {print $1}' \
      | xargs -r oc delete pod -n "${ns}" --force --grace-period=0 &>/dev/null || true
  fi

  oc delete namespace "${ns}" --timeout="${timeout}s" 2>/dev/null || true

  # If still Terminating, clear namespace finalizers as a last resort.
  if oc get namespace "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Terminating"; then
    log "  Namespace ${ns} stuck Terminating — clearing finalizers..."
    oc get namespace "${ns}" -o json \
      | python3 -c "import json,sys; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" \
      | oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - &>/dev/null || true
    local _w=0
    until ! oc get namespace "${ns}" &>/dev/null || (( _w >= 30 )); do
      sleep 2; (( _w += 2 ))
    done
  fi
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
    if [[ -t 0 ]]; then
      if read -t "${interval}" -r 2>/dev/null; then
        log "  Retrying immediately..."
      fi
    else
      sleep "${interval}"
    fi
    elapsed=$(( elapsed + interval ))
  done

  err "Timed out after ${max_wait}s waiting for: ${description}
  Resolve the issue, then re-run the installer."
}

# ====== RESOLVE MODEL STAGING ======
# Prompts the user interactively whether to download & stage models.
# In silent/airgap mode the prompt is skipped and MODEL_STAGING_ENABLED is unchanged.
resolve_model_staging() {
  # Airgap: models must be pre-staged; staging via this script is not possible.
  if [[ "${AIRGAP_MODE:-false}" == "true" ]]; then
    log "AIRGAP_MODE=true — model staging skipped (models must be pre-staged in object store)."
    MODEL_STAGING_ENABLED="false"
    return 0
  fi

  # Already explicitly set in config or env — honour it and skip the prompt.
  if [[ "${MODEL_STAGING_ENABLED}" == "true" || "${MODEL_STAGING_ENABLED}" == "false" ]]; then
    log "MODEL_STAGING_ENABLED=${MODEL_STAGING_ENABLED} (from config/env)"
    return 0
  fi

  # Silent install: cannot prompt — default to false.
  if [[ "${SILENT_INSTALL:-false}" == "true" ]]; then
    log "SILENT_INSTALL=true — model staging defaulting to false (set storage.modelStaging.enabled=true in config to enable)."
    MODEL_STAGING_ENABLED="false"
    return 0
  fi

  echo -e "\n  \033[1mModel artifact staging:\033[0m" >&2
  echo -e "  Download model weights from HuggingFace and upload them to the object store?" >&2
  echo -e "  (Requires HF_TOKEN and object store credentials. Type 'yes' to enable.)" >&2
  local answer
  read -r -p "  Enable model staging? [yes/no]: " answer
  if [[ "${answer}" == "yes" ]]; then
    MODEL_STAGING_ENABLED="true"
    log "Model staging enabled by user."
  else
    MODEL_STAGING_ENABLED="false"
    log "Model staging skipped by user."
  fi
}

# ====== SUPPORTED ACCELERATOR TYPE ======
readonly OPENSHIFT_ACCELERATOR="RTX_PRO_6000_BLACKWELL"

# ====== RESOLVE ACCELERATOR TYPE ======
# OpenShift deployments are qualified only for RTX Pro 6000 Blackwell. Default
# an omitted value to that accelerator and reject every other configured value.
resolve_accelerator_type() {
  local _raw="${DEFAULT_ACCELERATOR:-}"
  if [[ -z "${_raw}" || "${_raw}" == "null" ]]; then
    DEFAULT_ACCELERATOR="${OPENSHIFT_ACCELERATOR}"
    log "Accelerator type defaulted to: ${DEFAULT_ACCELERATOR}"
    return 0
  fi

  DEFAULT_ACCELERATOR="$(printf '%s' "${_raw}" | tr '[:lower:]' '[:upper:]')"

  if [[ "${DEFAULT_ACCELERATOR}" != "${OPENSHIFT_ACCELERATOR}" ]]; then
    err "OpenShift deployments support only ${OPENSHIFT_ACCELERATOR}; got '${DEFAULT_ACCELERATOR}'"
    return 1
  fi

  log "Accelerator type: ${DEFAULT_ACCELERATOR}"
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
  echo -e "  \033[1mScale factor     :\033[0m ${AI_SCALE_FACTOR:-1}" >&2
  echo -e "  \033[1mNode label strat :\033[0m ${NODE_LABEL_STRATEGY}" >&2
  echo -e "  \033[1mOperator image   :\033[0m ${OPERATOR_IMAGE}" >&2
  echo -e "  \033[1mImage registry   :\033[0m ${IMAGE_REGISTRY:-<none>}" >&2
  echo -e "  \033[1mECR enabled      :\033[0m ${ECR_ENABLED}" >&2
  echo -e "  \033[1mAir-gap mode     :\033[0m ${AIRGAP_MODE:-false}" >&2
  echo "" >&2
  echo -e "  \033[1mObject store     :\033[0m type=${OBJ_STORE_TYPE}  bucket=${OBJ_STORE_BUCKET:-<unset>}" >&2
  echo -e "  \033[1mObject endpoint  :\033[0m ${OBJ_STORE_ENDPOINT:-<default>}" >&2
  echo -e "  \033[1mModel staging    :\033[0m ${MODEL_STAGING_ENABLED}" >&2
  echo "" >&2
  echo -e "  \033[1mSteps that will run:\033[0m" >&2
  echo -e "    0.  Model artifact staging (HuggingFace → object store)" >&2
  if [[ "${MODEL_STAGING_ENABLED}" != "true" ]]; then
    echo -e "        [SKIPPED — modelStaging.enabled=false]" >&2
  elif [[ "${AIRGAP_MODE:-false}" == "true" ]]; then
    echo -e "        [SKIPPED — AIRGAP_MODE=true, models must be pre-staged]" >&2
  fi
  echo -e "    1.  Preflight checks (oc login, tools, manifest files)" >&2
  echo -e "    2.  NFD Operator (OLM)" >&2
  echo -e "    3.  NVIDIA GPU Operator (OLM)" >&2
  echo -e "    4.  Node labeling (splunk.ai/ai-tier-node)" >&2
  echo -e "    5.  local-path-provisioner + SELinux relabeling" >&2
  echo -e "    6.  cert-manager" >&2
  echo -e "    7.  OpenTelemetry Operator (Helm)" >&2
  echo -e "    8.  KubeRay Operator (Helm)" >&2
  echo -e "    9.  Image pull secrets (ECR / DockerHub / GCR / ACR / custom)" >&2
  echo -e "    10. Splunk AI Operator" >&2
  echo -e "    11. Splunk Operator" >&2
  echo -e "    12. Splunk Standalone CR" >&2
  echo -e "    13. AIPlatform CR" >&2
  echo "" >&2

  if [[ "${SILENT_INSTALL:-false}" == "true" ]]; then
    echo -e "  \033[1;33m⚠  SILENT INSTALL — no interactive prompts.\033[0m" >&2
    echo -e "  The config file is assumed to have been reviewed and is correct." >&2
    echo -e "  The steps listed above will run automatically. Press Ctrl-C within 5 s to abort." >&2
    sleep 5
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
  # Set to "true" only for plain-HTTP (no-TLS) registries such as a local mirror.
  # Leave false (default) for ECR, Docker Hub, Harbor, or any HTTPS registry.
  IMAGE_REGISTRY_INSECURE="$(yq eval '.images.registryInsecure // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
  OPERATOR_IMAGE=$(yq eval '.images.operator.image // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  RAY_HEAD_IMAGE=$(yq eval '.images.ray.headImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  RAY_WORKER_IMAGE=$(yq eval '.images.ray.workerImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  WEAVIATE_IMAGE=$(yq eval '.images.weaviate.image // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SAIA_API_IMAGE=$(yq eval '.images.saia.apiImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SAIA_API_V2_IMAGE=$(yq eval '.images.saia.apiV2Image // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SAIA_DATALOADER_IMAGE=$(yq eval '.images.saia.dataLoaderImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SLIM_API_IMAGE=$(yq eval '.images.slim.apiImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SPLUNK_IMAGE=$(yq eval '.images.splunk.image // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  SPLUNK_OPERATOR_IMAGE=$(yq eval '.images.splunk.operatorImage // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  FLUENT_BIT_IMAGE=$(yq eval '.images.fluentBit.image // "fluent/fluent-bit:1.9.6"' "${CONFIG_FILE}" 2>/dev/null || echo "fluent/fluent-bit:1.9.6")
  OTEL_COLLECTOR_IMAGE=$(yq eval '.images.otelCollector.image // "otel/opentelemetry-collector-contrib:0.122.1"' "${CONFIG_FILE}" 2>/dev/null || echo "otel/opentelemetry-collector-contrib:0.122.1")
  NGINX_IMAGE=$(yq eval '.images.nginx.image // "docker.io/library/nginx:1.27-alpine"' "${CONFIG_FILE}" 2>/dev/null || echo "docker.io/library/nginx:1.27-alpine")
  MODEL_VERSION=$(yq eval '.operators.ray.modelVersion // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  RAY_RUNTIME_VERSION=$(yq eval '.operators.ray.rayVersion // "2.44.0"' "${CONFIG_FILE}" 2>/dev/null || echo "2.44.0")
  local _config_dir
  _config_dir="$(cd "$(dirname "${CONFIG_FILE}")" && pwd)"
  _resolve_manifest() {
    local p="$1"
    # Absolute paths are used as-is; relative paths are anchored to the config file's directory.
    [[ "${p}" = /* ]] && echo "${p}" || echo "${_config_dir}/${p#./}"
  }
  SPLUNK_AI_FILE=$(_resolve_manifest "$(yq eval '.files.aiPlatform // "./artifacts.yaml"' "${CONFIG_FILE}" 2>/dev/null || echo "./artifacts.yaml")")
  SPLUNK_OPERATOR_FILE=$(_resolve_manifest "$(yq eval '.files.splunkOperator // "./splunk-operator-cluster.yaml"' "${CONFIG_FILE}" 2>/dev/null || echo "./splunk-operator-cluster.yaml")")

  # OpenShift-specific
  # Whether to grant the operator service account privileged SCC.
  # Required for Ray worker pods that request nvidia.com/gpu resources.
  GRANT_PRIVILEGED_SCC=$(yq eval '.openshift.grantPrivilegedSCC // "true"' "${CONFIG_FILE}" 2>/dev/null || echo "true")

  NODE_LABEL_STRATEGY=$(yq eval '.openshift.nodeLabelStrategy // "auto"' "${CONFIG_FILE}" 2>/dev/null || echo "auto")

  ECR_ENABLED=$(yq eval '.ecr.enabled // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  ECR_ACCOUNT=$(yq eval '.ecr.account // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  ECR_REGION=$(yq eval '.ecr.region // "us-east-2"' "${CONFIG_FILE}" 2>/dev/null || echo "us-east-2")
  # S3 bucket region — may differ from ECR_REGION when ECR and S3 are in different regions.
  # Defaults to ecr.region for backwards compatibility when not explicitly set.
  OBJ_STORE_REGION=$(yq eval ".storage.objectStore.region // \"${ECR_REGION}\"" "${CONFIG_FILE}" 2>/dev/null || echo "${ECR_REGION}")

  AI_PLATFORM_NAME=$(yq eval '.aiPlatform.name // "openshift-ai-platform"' "${CONFIG_FILE}" 2>/dev/null || echo "openshift-ai-platform")
  DEFAULT_ACCELERATOR=$(yq eval '.aiPlatform.defaultAcceleratorType // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  AI_SCALE_FACTOR=$(yq eval '.aiPlatform.scaleFactor // 1' "${CONFIG_FILE}" 2>/dev/null || echo "1")
  WORKER_IMAGE_REGISTRY=$(yq eval '.aiPlatform.workerGroupConfig.imageRegistry // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  STORAGE_CLASS=$(yq eval '.storage.storageClass // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  VECTORDB_SIZE=$(yq eval '.storage.vectorDbSize // "50Gi"' "${CONFIG_FILE}" 2>/dev/null || echo "50Gi")
  OBJ_STORE_TYPE=$(yq eval '.storage.objectStore.type // "minio"' "${CONFIG_FILE}" 2>/dev/null || echo "minio")
  OBJ_STORE_BUCKET=$(yq eval '.storage.objectStore.bucket // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  OBJ_STORE_BUCKET="$(printf '%s' "${OBJ_STORE_BUCKET}" | tr '[:upper:]' '[:lower:]')"
  OBJ_STORE_ENDPOINT=$(yq eval '.storage.objectStore.endpoint // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  MINIO_ROOT_USER=$(yq eval '.storage.objectStore.auth.rootUser // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  MINIO_ROOT_PASSWORD=$(yq eval '.storage.objectStore.auth.rootPassword // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  AI_STANDALONE_NAME=$(yq eval '.splunk.standaloneName // "splunk-standalone"' "${CONFIG_FILE}" 2>/dev/null || echo "splunk-standalone")

  # Air-gap mode: read from YAML (cluster.airgap: true) and allow env var override.
  local _yaml_airgap
  _yaml_airgap=$(yq eval '.cluster.airgap // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  [[ "${_yaml_airgap}" == "null" ]] && _yaml_airgap="false"
  if [[ "${AIRGAP_MODE:-}" == "true" ]]; then
    : # env var wins
  elif [[ "${_yaml_airgap}" == "true" ]]; then
    export AIRGAP_MODE="true"
  else
    export AIRGAP_MODE="false"
  fi

  # Model staging
  MODEL_STAGING_ENABLED="$(yq eval '.storage.modelStaging.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "null")"
  [[ "${MODEL_STAGING_ENABLED}" == "null" || -z "${MODEL_STAGING_ENABLED}" ]] && MODEL_STAGING_ENABLED="false"

  # ImagePullSecrets configuration
  IMAGE_PULL_SECRETS_ECR_ENABLED=$(yq eval '.imagePullSecrets.autoCreateECR // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED=$(yq eval '.imagePullSecrets.dockerHub.enabled // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_GCR_ENABLED=$(yq eval '.imagePullSecrets.gcr.enabled // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_ACR_ENABLED=$(yq eval '.imagePullSecrets.acr.enabled // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_CUSTOM_ENABLED=$(yq eval '.imagePullSecrets.custom.enabled // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")

  NFD_CATALOG_SOURCE=$(yq eval '.operators.nfd.catalogSource // "redhat-operators"' "${CONFIG_FILE}" 2>/dev/null || echo "redhat-operators")
  GPU_CATALOG_SOURCE=$(yq eval '.operators.gpu.catalogSource // "certified-operators"' "${CONFIG_FILE}" 2>/dev/null || echo "certified-operators")

  # Ingress domain: read from config if set, otherwise auto-detect from the cluster.
  # Used to create an OpenShift Route for SAIA so both browsers and in-cluster services
  # can reach it via a stable hostname.
  local cfg_ingress_domain
  cfg_ingress_domain=$(yq eval '.openshift.ingressDomain // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  if [[ -n "$cfg_ingress_domain" ]]; then
    INGRESS_DOMAIN="$cfg_ingress_domain"
  else
    INGRESS_DOMAIN=$(oc get ingresscontroller default -n openshift-ingress-operator \
      -o jsonpath='{.status.domain}' 2>/dev/null || echo "")
  fi

  log "Configuration loaded: namespace=${AI_NS}, accelerator=${DEFAULT_ACCELERATOR}, airgap=${AIRGAP_MODE:-false}, modelStaging=${MODEL_STAGING_ENABLED}"
}

# ====== PLACEHOLDER CREDENTIAL GUARD ======
# True if objectStore.auth values are still obvious template text. Non-empty
# placeholders pass the length check and get applied into minio-credentials,
# causing SAIA to crash at startup with InvalidAccessKeyId.
object_store_auth_looks_like_placeholder() {
  case "${MINIO_ROOT_USER}${MINIO_ROOT_PASSWORD}" in
    *\<*|*\>*) return 0 ;;
    *CHANGEME*|*changeme*) return 0 ;;
  esac
  return 1
}

# ====== IMAGE HELPERS ======
build_image_url() {
  local registry="$1"
  local image_path="$2"
  # Treat as fully-qualified if image starts with a registry host.
  # Recognised forms: domain.tld/... , domain.tld:port/... , IP/... , IP:port/...
  if [[ "$image_path" =~ ^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/.*:.+ ]]; then
    echo "$image_path"
    return 0
  fi
  if [[ -n "$registry" && "$registry" != "null" ]]; then
    echo "${registry}/${image_path}"
  else
    echo "$image_path"
  fi
}

validate_scale_factor_config() {
  local legacy_count present value value_tag

  if ! legacy_count=$(yq eval '[.aiPlatform.features[]? | select(has("scaleFactor"))] | length' "${CONFIG_FILE}" 2>/dev/null); then
    echo "Unable to inspect feature scaleFactor settings in ${CONFIG_FILE}"
    return 1
  fi
  if [[ ! "${legacy_count}" =~ ^[0-9]+$ ]]; then
    echo "Unable to inspect feature scaleFactor settings in ${CONFIG_FILE}"
    return 1
  fi
  if (( legacy_count > 0 )); then
    echo "aiPlatform.features[].scaleFactor is no longer supported; move the capacity multiplier to aiPlatform.scaleFactor"
    return 1
  fi

  if ! present=$(yq eval '(.aiPlatform // {}) | has("scaleFactor")' "${CONFIG_FILE}" 2>/dev/null); then
    echo "Unable to read aiPlatform.scaleFactor from ${CONFIG_FILE}"
    return 1
  fi
  if [[ "${present}" != "true" ]]; then
    return 0
  fi
  if ! value=$(yq eval '.aiPlatform.scaleFactor' "${CONFIG_FILE}" 2>/dev/null) || \
     ! value_tag=$(yq eval '.aiPlatform.scaleFactor | tag' "${CONFIG_FILE}" 2>/dev/null); then
    echo "Unable to read aiPlatform.scaleFactor from ${CONFIG_FILE}"
    return 1
  fi
  if [[ "${value_tag}" != "!!int" ]]; then
    echo "aiPlatform.scaleFactor must be a YAML integer greater than or equal to 1 (got ${value:-null})"
    return 1
  fi
  if [[ ! "${value}" =~ ^-?[0-9]+$ ]] || (( value < 1 )); then
    echo "aiPlatform.scaleFactor must be greater than or equal to 1 (got ${value:-null})"
    return 1
  fi

  return 0
}

# True when the optional SLIM service is requested in aiPlatform.features[].
# Keep image validation feature-gated so existing SAIA-only configurations do
# not need to define an image for a workload they never deploy.
openshift_slim_feature_enabled() {
  local names
  names=$(yq eval '.aiPlatform.features[].name // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  while IFS= read -r name; do
    [[ "${name}" == "slim" ]] && return 0
  done <<< "${names}"
  return 1
}

warn_on_mutable_image_tags() {
  # Workload images use imagePullPolicy: IfNotPresent. Re-running install with
  # an unchanged mutable tag therefore does not guarantee that a newly pushed
  # image is pulled or that a rollout is triggered. Keep this as a warning so
  # first-time development installs can still use mutable tags deliberately.
  local mutable_tag_images=(
    "images.operator.image:${OPERATOR_IMAGE:-}"
    "images.ray.headImage:${RAY_HEAD_IMAGE:-}"
    "images.ray.workerImage:${RAY_WORKER_IMAGE:-}"
    "images.weaviate.image:${WEAVIATE_IMAGE:-}"
    "images.saia.apiImage:${SAIA_API_IMAGE:-}"
    "images.saia.apiV2Image:${SAIA_API_V2_IMAGE:-}"
    "images.saia.dataLoaderImage:${SAIA_DATALOADER_IMAGE:-}"
    "images.slim.apiImage:${SLIM_API_IMAGE:-}"
    "images.splunk.image:${SPLUNK_IMAGE:-}"
    "images.splunk.operatorImage:${SPLUNK_OPERATOR_IMAGE:-}"
    "images.fluentBit.image:${FLUENT_BIT_IMAGE:-}"
    "images.nginx.image:${NGINX_IMAGE:-}"
    "images.otelCollector.image:${OTEL_COLLECTOR_IMAGE:-}"
  )

  local entry key image last_segment tag
  for entry in "${mutable_tag_images[@]}"; do
    key="${entry%%:*}"
    image="${entry#*:}"
    [[ -z "${image}" || "${image}" == "null" ]] && continue

    # Inspect the final path segment so a registry port such as :5000 is not
    # mistaken for an image tag.
    last_segment="${image##*/}"
    if [[ "${last_segment}" == *:* ]]; then
      tag="${last_segment##*:}"
    else
      tag=""
    fi

    if [[ -z "${tag}" ]]; then
      warn "${key} (${image}) has no explicit tag and will not reliably upgrade on a same-tag reinstall (imagePullPolicy: IfNotPresent). Use a distinct immutable tag."
    elif [[ "${tag}" =~ ^(latest|preview|stable.*|dev|nightly)$ ]]; then
      warn "${key} uses mutable tag ':${tag}' and will not reliably upgrade on a same-tag reinstall (imagePullPolicy: IfNotPresent). Use a distinct immutable tag."
    fi
  done
}

validate_image_config() {
  log "Validating image configuration..."
  local scale_factor_error
  if ! scale_factor_error=$(validate_scale_factor_config); then
    err "${scale_factor_error}"
  fi
  [[ -z "$OPERATOR_IMAGE"        || "$OPERATOR_IMAGE"        == "null" ]] && err "REQUIRED: images.operator.image must be set in config"
  [[ -z "$RAY_HEAD_IMAGE"        || "$RAY_HEAD_IMAGE"        == "null" ]] && err "REQUIRED: images.ray.headImage must be set in config"
  [[ -z "$RAY_WORKER_IMAGE"      || "$RAY_WORKER_IMAGE"      == "null" ]] && err "REQUIRED: images.ray.workerImage must be set in config"
  [[ -z "$WEAVIATE_IMAGE"        || "$WEAVIATE_IMAGE"        == "null" ]] && err "REQUIRED: images.weaviate.image must be set in config"
  [[ -z "$SAIA_API_IMAGE"        || "$SAIA_API_IMAGE"        == "null" ]] && err "REQUIRED: images.saia.apiImage must be set in config"
  [[ -z "$SAIA_API_V2_IMAGE"     || "$SAIA_API_V2_IMAGE"     == "null" ]] && err "REQUIRED: images.saia.apiV2Image must be set in config"
  [[ -z "$SAIA_DATALOADER_IMAGE" || "$SAIA_DATALOADER_IMAGE" == "null" ]] && err "REQUIRED: images.saia.dataLoaderImage must be set in config"
  if openshift_slim_feature_enabled; then
    [[ -z "$SLIM_API_IMAGE" || "$SLIM_API_IMAGE" == "null" ]] && \
      err "REQUIRED: images.slim.apiImage must be set in config when the 'slim' feature is enabled"
  fi
  [[ -z "$SPLUNK_IMAGE"          || "$SPLUNK_IMAGE"          == "null" ]] && err "REQUIRED: images.splunk.image must be set in config"
  [[ -z "$MODEL_VERSION"         || "$MODEL_VERSION"         == "null" ]] && { MODEL_VERSION="v0.3.14-36-g1549f5a"; log "Using default MODEL_VERSION: $MODEL_VERSION"; }
  warn_on_mutable_image_tags
  log "✓ Image configuration validated"
}

configure_images() {
  log "Patching image references in manifest files..."

  [[ -f "${SPLUNK_AI_FILE}" ]] || err "Manifest not found: ${SPLUNK_AI_FILE}"

  # Render each manifest into a throwaway temp copy and patch only the copy,
  # leaving the committed manifest untouched. This guarantees every run starts
  # from the current bundled CRD/manifest — no stale ".original" backup can
  # shadow a freshly-pulled schema (e.g. spec.scaleFactor). Temps are removed by
  # the cleanup_tmp EXIT trap. Reassigning the global path vars makes every
  # downstream consumer (sed patch, oc apply, retries) use the temp.
  local ai_rendered operator_rendered
  ai_rendered=$(mktemp) || err "failed to create temp manifest"
  cp "$SPLUNK_AI_FILE" "$ai_rendered"
  TMP_FILES+=("$ai_rendered")
  SPLUNK_AI_FILE="$ai_rendered"

  if [[ -f "${SPLUNK_OPERATOR_FILE}" ]]; then
    operator_rendered=$(mktemp) || err "failed to create temp manifest"
    cp "${SPLUNK_OPERATOR_FILE}" "$operator_rendered"
    TMP_FILES+=("$operator_rendered")
    SPLUNK_OPERATOR_FILE="$operator_rendered"
  fi

  local operator_full ray_head_full ray_worker_full weaviate_full
  local saia_api_full saia_api_v2_full saia_dataloader_full slim_api_full
  local fluent_bit_full otel_collector_full nginx_full

  operator_full=$(build_image_url "$IMAGE_REGISTRY" "$OPERATOR_IMAGE")
  ray_head_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_HEAD_IMAGE")
  ray_worker_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_WORKER_IMAGE")
  weaviate_full=$(build_image_url "$IMAGE_REGISTRY" "$WEAVIATE_IMAGE")
  saia_api_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_IMAGE")
  saia_api_v2_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_V2_IMAGE")
  saia_dataloader_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_DATALOADER_IMAGE")
  slim_api_full=""
  [[ -n "$SLIM_API_IMAGE" && "$SLIM_API_IMAGE" != "null" ]] && \
    slim_api_full=$(build_image_url "$IMAGE_REGISTRY" "$SLIM_API_IMAGE")
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
  local saia_dl_esc slim_api_esc fluent_esc otel_esc nginx_esc operator_esc

  ray_head_esc=$(echo "$ray_head_full"       | sed 's/[\/&]/\\&/g')
  ray_worker_esc=$(echo "$ray_worker_full"   | sed 's/[\/&]/\\&/g')
  weaviate_esc=$(echo "$weaviate_full"       | sed 's/[\/&]/\\&/g')
  saia_api_esc=$(echo "$saia_api_full"       | sed 's/[\/&]/\\&/g')
  saia_api_v2_esc=$(echo "$saia_api_v2_full" | sed 's/[\/&]/\\&/g')
  saia_dl_esc=$(echo "$saia_dataloader_full" | sed 's/[\/&]/\\&/g')
  slim_api_esc=$(echo "$slim_api_full"       | sed 's/[\/&]/\\&/g')
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
  if [[ -n "$slim_api_full" ]]; then
    "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SLIM_API/,/value:/ s|value:.*|value: ${slim_api_esc}|"          "$SPLUNK_AI_FILE"
  fi
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_FLUENT_BIT/,/value:/ s|value:.*|value: ${fluent_esc}|"             "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_OTEL_COLLECTOR/,/value:/ s|value:.*|value: ${otel_esc}|"           "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_NGINX/,/value:/ s|value:.*|value: ${nginx_esc}|"                   "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: MODEL_VERSION/,/value:/ s|value:.*|value: ${MODEL_VERSION}|"                     "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RAY_VERSION/,/value:/ s|value:.*|value: ${RAY_RUNTIME_VERSION}|"                 "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "s|image: .*splunk.*ai.*operator.*|image: ${operator_esc}|I"                             "$SPLUNK_AI_FILE"

  if [[ -f "${SPLUNK_OPERATOR_FILE}" && -n "${SPLUNK_OPERATOR_IMAGE:-}" && "${SPLUNK_OPERATOR_IMAGE}" != "null" ]]; then
    local splunk_op_full splunk_op_esc
    splunk_op_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_OPERATOR_IMAGE")
    splunk_op_esc=$(echo "$splunk_op_full" | sed 's/[\/&]/\\&/g')
    local splunk_ent_full splunk_ent_esc
    splunk_ent_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_IMAGE")
    splunk_ent_esc=$(echo "$splunk_ent_full" | sed 's/[\/&]/\\&/g')
    "${SED_INPLACE[@]}" "s|image: .*splunk.*operator.*|image: ${splunk_op_esc}|I"                             "${SPLUNK_OPERATOR_FILE}"
    "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SPLUNK_ENTERPRISE/,/value:/ s|value:.*|value: ${splunk_ent_esc}|" "${SPLUNK_OPERATOR_FILE}"
    log "  ✓ Splunk Operator image:           $splunk_op_full"
    log "  ✓ RELATED_IMAGE_SPLUNK_ENTERPRISE: $splunk_ent_full"
  fi

  log "  ✓ RELATED_IMAGE_RAY_HEAD:          $ray_head_full"
  log "  ✓ RELATED_IMAGE_RAY_WORKER:        $ray_worker_full"
  log "  ✓ RELATED_IMAGE_WEAVIATE:          $weaviate_full"
  log "  ✓ RELATED_IMAGE_SAIA_API:          $saia_api_full"
  log "  ✓ RELATED_IMAGE_SAIA_API_V2:       $saia_api_v2_full"
  log "  ✓ RELATED_IMAGE_POST_INSTALL_HOOK: $saia_dataloader_full"
  [[ -n "$slim_api_full" ]] && log "  ✓ RELATED_IMAGE_SLIM_API:          $slim_api_full"
  log "  ✓ RELATED_IMAGE_FLUENT_BIT:        $fluent_bit_full"
  log "  ✓ RELATED_IMAGE_OTEL_COLLECTOR:    $otel_collector_full"
  log "  ✓ RELATED_IMAGE_NGINX:             $nginx_full"
  log "  ✓ Operator image:                  $operator_full"
  log "  ✓ MODEL_VERSION:                   $MODEL_VERSION"
  log "  ✓ RAY_VERSION:                     $RAY_RUNTIME_VERSION"

  # Patch splunk-operator-cluster.yaml with images from config.
  # Without this, the Splunk Operator pod and all Splunk Standalone pods use the
  # account-specific ECR URLs baked into the committed manifest file.
  if [[ -f "${SPLUNK_OPERATOR_FILE}" ]]; then
    log "Patching image references in ${SPLUNK_OPERATOR_FILE}..."
    # SPLUNK_OPERATOR_FILE already points at the rendered temp from the first
    # block; patch it in place (no backup/restore needed).

    local splunk_full splunk_esc splunk_op_full splunk_op_esc
    splunk_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_IMAGE")
    splunk_op_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_OPERATOR_IMAGE")
    splunk_esc=$(echo "$splunk_full" | sed 's/[\/&]/\\&/g')
    splunk_op_esc=$(echo "$splunk_op_full" | sed 's/[\/&]/\\&/g')

    "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SPLUNK_ENTERPRISE/,/value:/ s|value:.*|value: ${splunk_esc}|" "$SPLUNK_OPERATOR_FILE"
    "${SED_INPLACE[@]}" "s|image: .*splunk.*operator.*|image: ${splunk_op_esc}|I" "$SPLUNK_OPERATOR_FILE"

    log "  ✓ RELATED_IMAGE_SPLUNK_ENTERPRISE: $splunk_full"
    log "  ✓ Splunk Operator image:           $splunk_op_full"
  else
    warn "Splunk Operator manifest not found at ${SPLUNK_OPERATOR_FILE} — skipping image patch"
  fi
}

# ====== PREFLIGHT HELPER PRINTERS ======
pf_header() { echo -e "\n\033[1;34m  ── $* ──\033[0m" >&2; }
pf_ok()     { echo -e "  \033[1;32m✔\033[0m $*" >&2; }
pf_warn()   { echo -e "  \033[1;33m⚠\033[0m $*" >&2; }
pf_fail()   { echo -e "  \033[1;31m✖\033[0m $*" >&2; PREFLIGHT_FAILURES=$(( ${PREFLIGHT_FAILURES:-0} + 1 )); }

# ====== PREFLIGHT: REGISTRY REACHABILITY CHECK ======
# Verifies the configured image registry is reachable and credentials work
# BEFORE any install work begins, so a bad registry config fails fast with a
# clear message instead of surfacing as ImagePullBackOff minutes later.
#
# Strategy: hit the OCI /v2/ ping endpoint (all standard registries implement it),
# then attempt a manifest HEAD for one representative image to confirm auth works
# end-to-end. Uses only curl — no Docker/crane/skopeo required.
#
# Auth dispatch:
#   ECR        → aws ecr get-login-password  (Bearer token)
#   DockerHub  → imagePullSecrets.dockerHub creds
#   GCR        → imagePullSecrets.gcr.jsonKey (_json_key)
#   ACR        → imagePullSecrets.acr creds
#   Custom     → imagePullSecrets.custom creds (or unauthenticated if none)
#   No registry set → public DockerHub (no auth needed)
preflight_check_registry() {
  pf_header "Image registry reachability"

  # No registry configured → images pull from Docker Hub / public — nothing to check
  if [[ -z "${IMAGE_REGISTRY}" || "${IMAGE_REGISTRY}" == "null" ]]; then
    pf_ok "No private registry configured — images pull from public registries (Docker Hub etc.)"
    return
  fi

  # Determine protocol scheme for the ping URL
  local scheme="https"
  [[ "${IMAGE_REGISTRY_INSECURE:-false}" == "true" ]] && scheme="http"

  local ping_url="${scheme}://${IMAGE_REGISTRY}/v2/"
  # curl_opts: no -f so HTTP 4xx is not treated as a curl error; we read the status code ourselves.
  local curl_opts=(--silent --connect-timeout 10 --max-time 15)
  [[ "${IMAGE_REGISTRY_INSECURE:-false}" == "true" ]] && curl_opts+=(--insecure)

  # ---- Step 1: TCP/TLS reachability ----
  local http_code
  http_code=$(curl "${curl_opts[@]}" -o /dev/null -w "%{http_code}" "${ping_url}" 2>/dev/null)
  case "${http_code}" in
    200|401|403)
      pf_ok "Registry reachable: ${ping_url} (HTTP ${http_code})"
      ;;
    000)
      pf_fail "Registry unreachable: cannot connect to ${ping_url} (connection refused / DNS failure / firewall). Fix images.registry or ensure network path to registry is open."
      return
      ;;
    *)
      pf_warn "Registry ${IMAGE_REGISTRY} answered HTTP ${http_code} on /v2/ ping (not a standard OCI response, but host is reachable). Proceeding to manifest check."
      ;;
  esac

  # ---- Step 2: Auth + manifest pull for one representative image ----
  local _fq_re='^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/'

  _image_targets_registry() {
    local raw="$1"
    [[ -z "${raw}" || "${raw}" == "null" ]] && return 1
    local full
    full=$(build_image_url "${IMAGE_REGISTRY}" "${raw}")
    if [[ "${full}" == ${IMAGE_REGISTRY}/* ]]; then
      echo "${full#${IMAGE_REGISTRY}/}"
      return 0
    fi
    return 1
  }

  local probe_ref=""
  local probe_source=""
  for _candidate_var in SAIA_API_IMAGE RAY_HEAD_IMAGE SAIA_API_V2_IMAGE SAIA_DATALOADER_IMAGE SLIM_API_IMAGE RAY_WORKER_IMAGE WEAVIATE_IMAGE FLUENT_BIT_IMAGE OTEL_COLLECTOR_IMAGE NGINX_IMAGE SPLUNK_IMAGE SPLUNK_OPERATOR_IMAGE OPERATOR_IMAGE; do
    local _val="${!_candidate_var:-}"
    local _ref
    if _ref=$(_image_targets_registry "${_val}"); then
      probe_ref="${_ref}"
      probe_source="${_candidate_var}"
      break
    fi
  done

  if [[ -z "${probe_ref}" ]]; then
    pf_warn "No images in config target IMAGE_REGISTRY (${IMAGE_REGISTRY}) — all images appear to be fully qualified to other registries. Skipping auth check."
    return
  fi

  pf_ok "Probing registry with ${probe_source} image: ${IMAGE_REGISTRY}/${probe_ref}"

  # Split repo and tag/digest
  local probe_repo probe_tag
  if [[ "${probe_ref}" == *"@"* ]]; then
    probe_repo="${probe_ref%%@*}"
    probe_tag="${probe_ref##*@}"
    local manifest_url="${scheme}://${IMAGE_REGISTRY}/v2/${probe_repo}/manifests/${probe_tag}"
  else
    probe_repo="${probe_ref%%:*}"
    probe_tag="${probe_ref##*:}"
    [[ "${probe_tag}" == "${probe_ref}" ]] && probe_tag="latest"
    local manifest_url="${scheme}://${IMAGE_REGISTRY}/v2/${probe_repo}/manifests/${probe_tag}"
  fi

  local auth_header=""

  # Resolve auth credentials by registry type
  if [[ "${IMAGE_REGISTRY}" == *.dkr.ecr.*.amazonaws.com ]]; then
    local _ecr_region="${ECR_REGION:-${REGION:-us-east-2}}"
    if ! command -v aws &>/dev/null; then
      pf_warn "ECR registry configured but aws CLI not found — skipping auth check."
      return
    fi
    local _ecr_token
    if ! _ecr_token=$(aws ecr get-login-password --region "${_ecr_region}" 2>/dev/null); then
      pf_fail "Cannot obtain ECR token (aws ecr get-login-password failed). Check AWS credentials and IAM permissions (ecr:GetAuthorizationToken)."
      return
    fi
    auth_header="Authorization: Basic $(printf 'AWS:%s' "${_ecr_token}" | base64 | tr -d '\n')"

  elif [[ "${IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED}" == "true" && "${IMAGE_REGISTRY}" == *"docker.io"* ]]; then
    local _dh_user _dh_pass
    _dh_user=$(yq eval '.imagePullSecrets.dockerHub.username' "${CONFIG_FILE}" 2>/dev/null)
    _dh_pass=$(yq eval '.imagePullSecrets.dockerHub.password' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -n "${_dh_user}" && -n "${_dh_pass}" && "${_dh_user}" != "null" && "${_dh_pass}" != "null" ]]; then
      auth_header="Authorization: Basic $(printf '%s:%s' "${_dh_user}" "${_dh_pass}" | base64 | tr -d '\n')"
    fi

  elif [[ "${IMAGE_PULL_SECRETS_ACR_ENABLED}" == "true" && "${IMAGE_REGISTRY}" == *".azurecr.io"* ]]; then
    local _acr_user _acr_pass
    _acr_user=$(yq eval '.imagePullSecrets.acr.username' "${CONFIG_FILE}" 2>/dev/null)
    _acr_pass=$(yq eval '.imagePullSecrets.acr.password' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -n "${_acr_user}" && -n "${_acr_pass}" && "${_acr_user}" != "null" && "${_acr_pass}" != "null" ]]; then
      auth_header="Authorization: Basic $(printf '%s:%s' "${_acr_user}" "${_acr_pass}" | base64 | tr -d '\n')"
    fi

  elif [[ "${IMAGE_PULL_SECRETS_CUSTOM_ENABLED}" == "true" ]]; then
    local _custom_user _custom_pass
    _custom_user=$(yq eval '.imagePullSecrets.custom.username' "${CONFIG_FILE}" 2>/dev/null)
    _custom_pass=$(yq eval '.imagePullSecrets.custom.password' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -n "${_custom_user}" && -n "${_custom_pass}" && "${_custom_user}" != "null" && "${_custom_pass}" != "null" ]]; then
      auth_header="Authorization: Basic $(printf '%s:%s' "${_custom_user}" "${_custom_pass}" | base64 | tr -d '\n')"
    fi
  fi

  # Bearer token exchange helper
  _bearer_exchange() {
    local _cur_code="$1" _murl="$2" _ahdr="${3:-}"
    [[ "${_cur_code}" != "401" ]] && { echo "${_cur_code}"; return; }

    local _www_auth _realm _service _scope _tok _tok_code
    local _basic_opts=("${curl_opts[@]}")
    [[ -n "${_ahdr}" ]] && _basic_opts+=(-H "${_ahdr}")

    _www_auth=$(curl "${_basic_opts[@]}" -o /dev/null -D - "${_murl}" 2>/dev/null \
                | grep -i '^Www-Authenticate:' | head -1)
    _realm=$(echo "${_www_auth}"   | grep -oP 'realm="[^"]+"'   | cut -d'"' -f2)
    _service=$(echo "${_www_auth}" | grep -oP 'service="[^"]+"' | cut -d'"' -f2)
    _scope=$(echo "${_www_auth}"   | grep -oP 'scope="[^"]+"'   | cut -d'"' -f2)

    [[ -z "${_realm}" ]] && { echo "401"; return; }

    local _turl="${_realm}?service=${_service}&scope=${_scope}"
    _tok=$(curl "${_basic_opts[@]}" "${_turl}" 2>/dev/null \
           | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token') or d.get('access_token',''))" \
           2>/dev/null || true)

    [[ -z "${_tok}" ]] && { echo "401"; return; }

    _tok_code=$(curl "${curl_opts[@]}" \
      -H "Authorization: Bearer ${_tok}" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
      -o /dev/null -w "%{http_code}" \
      "${_murl}" 2>/dev/null)
    echo "${_tok_code}"
  }

  local manifest_http_code
  if [[ -n "${auth_header}" ]]; then
    manifest_http_code=$(curl "${curl_opts[@]}" \
      -H "${auth_header}" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
      -o /dev/null -w "%{http_code}" \
      "${manifest_url}" 2>/dev/null)

    if [[ "${manifest_http_code}" == "401" ]]; then
      manifest_http_code=$(_bearer_exchange "401" "${manifest_url}" "${auth_header}")
    fi
  else
    manifest_http_code=$(curl "${curl_opts[@]}" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
      -o /dev/null -w "%{http_code}" \
      "${manifest_url}" 2>/dev/null)

    if [[ "${manifest_http_code}" == "401" ]]; then
      manifest_http_code=$(_bearer_exchange "401" "${manifest_url}" "")
    fi
  fi

  case "${manifest_http_code}" in
    200|206)
      pf_ok "Registry auth OK: manifest reachable for ${probe_repo}:${probe_tag}"
      ;;
    401|403)
      pf_fail "Registry credentials rejected (HTTP ${manifest_http_code}) for ${IMAGE_REGISTRY}. Check imagePullSecrets config — images will fail to pull at deploy time."
      ;;
    404)
      pf_fail "Image not found in registry (HTTP 404): ${IMAGE_REGISTRY}/${probe_repo}:${probe_tag}. Check that images.operator.image tag exists in the registry."
      ;;
    000)
      pf_fail "Registry manifest check failed: no response from ${manifest_url}. Check network path and registry health."
      ;;
    *)
      pf_warn "Registry manifest check returned HTTP ${manifest_http_code} for ${probe_repo}:${probe_tag} — verify registry is healthy."
      ;;
  esac
}

# ====== PREFLIGHT CHECKS ======
preflight_checks() {
  log "Running preflight checks..."

  local _aws_needed="false"
  [[ "${ECR_ENABLED:-false}" == "true" ]] && _aws_needed="true"
  [[ "${OBJ_STORE_TYPE:-}" == "aws" ]] && _aws_needed="true"

  for tool in oc yq helm curl jq base64 tar; do
    command -v "$tool" >/dev/null 2>&1 && log "  ✓ $tool found" || err "Missing required tool: $tool"
  done
  if [[ "${_aws_needed}" == "true" ]]; then
    command -v aws >/dev/null 2>&1 && log "  ✓ aws found" || err "Missing required tool: aws (needed for ECR/S3 — install from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)"
  else
    log "  – aws CLI not required (ECR disabled, object store is not AWS)"
  fi

  # python3 is used by preflight_check_registry() to parse Bearer token JSON.
  if command -v python3 >/dev/null 2>&1; then
    log "  ✓ python3 found"
  else
    warn "  python3 not found — image registry auth check will be skipped (install python3 to enable it)."
  fi

  # Object-store CLI tools — used for the model staging pre-check.
  case "${OBJ_STORE_TYPE:-}" in
    aws)
      if command -v aws >/dev/null 2>&1; then
        log "  ✓ aws CLI found"
      else
        warn "  aws CLI not found — model staging pre-check will be skipped. Install aws CLI to enable it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      fi
      ;;
    minio|seaweedfs|s3compat)
      if command -v mc >/dev/null 2>&1; then
        log "  ✓ mc (MinIO client) found"
      else
        warn "  mc (MinIO client) not found — model staging pre-check will be skipped. Install mc to enable it: https://min.io/docs/minio/linux/reference/minio-mc.html"
      fi
      ;;
  esac

  preflight_check_registry

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

  if object_store_auth_looks_like_placeholder; then
    err "objectStore.auth still contains template placeholders (e.g. <...> or CHANGEME). Replace with real credentials in ${CONFIG_FILE}"
  fi
  log "  ✓ Object store credentials look real"

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

  # Step 1: Subscription + OperatorGroup — idempotent, skip creation if already present.
  # Do NOT early-return here: a prior run may have created the Subscription but never
  # the NodeFeatureDiscovery CR below, so we must always fall through to Step 2.
  if oc get subscription nfd -n openshift-nfd &>/dev/null; then
    log "  ✓ NFD subscription already exists, skipping creation"
  else
    oc apply -f - <<EOF
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
  source: ${NFD_CATALOG_SOURCE}
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
  fi

  # Step 2: NodeFeatureDiscovery CR — always ensure it exists, regardless of whether
  # the Subscription was just created or was already present from a prior run.
  # Without this CR the NFD operand never starts and nodes are never labeled with
  # nvidia.com/gpu.present, breaking GPU-node auto-detection.
  if oc get nodefeaturediscovery nfd-instance -n openshift-nfd &>/dev/null; then
    log "  ✓ NodeFeatureDiscovery CR already exists, skipping"
  else
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

  # Step 1: Subscription + OperatorGroup — idempotent, skip creation if already present.
  # Do NOT early-return here: a prior run may have created the Subscription but never
  # the ClusterPolicy below, so we must always fall through to Step 2.
  if oc get subscription gpu-operator-certified -n nvidia-gpu-operator &>/dev/null; then
    log "  ✓ GPU Operator subscription already exists, skipping creation"
  else
    oc apply -f - <<EOF
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
  source: ${GPU_CATALOG_SOURCE}
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
  fi

  # Step 2: ClusterPolicy — always ensure it exists, regardless of whether the
  # Subscription was just created or pre-existing. Without this CR the driver,
  # toolkit, and device-plugin DaemonSets are never deployed, leaving Ray worker
  # pods requesting nvidia.com/gpu unschedulable.
  if oc get clusterpolicy gpu-cluster-policy &>/dev/null; then
    log "  ✓ ClusterPolicy already exists, skipping"
  else
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

  local ai_nodes=() control_nodes=()

  # Always label master/control-plane nodes
  while IFS= read -r node; do
    [[ -n "$node" ]] && control_nodes+=("$node")
  done < <(oc get nodes -l node-role.kubernetes.io/master -o name 2>/dev/null | sed 's|node/||')

  case "${NODE_LABEL_STRATEGY}" in
    auto)
      # AI-tier nodes: all worker nodes. GPU workers are further constrained to
      # GPU-capable nodes by their nvidia.com/gpu resource request, not by a label.
      while IFS= read -r node; do
        [[ -n "$node" ]] && ai_nodes+=("$node")
      done < <(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null | sed 's|node/||')
      ;;

    manual)
      while IFS= read -r node; do
        [[ -n "$node" && "$node" != "null" ]] && ai_nodes+=("$node")
      done < <(yq eval '.openshift.nodes[]' "${CONFIG_FILE}" 2>/dev/null)
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

  # Label AI-tier worker nodes — every node gets splunk.ai/ai-tier-node=true.
  # Both cpuScheduler and gpuScheduler select on this single label; GPU workers are
  # further constrained to GPU-capable nodes by their nvidia.com/gpu resource request,
  # so CPU and GPU workloads share the same node pool without a cpu/gpu label split.
  for node in "${ai_nodes[@]:+${ai_nodes[@]}}"; do
    log "  Labeling AI-tier worker node: ${node}"
    oc label node "${node}" \
      splunk.ai/node-role=worker \
      splunk.ai/ai-tier-node=true \
      --overwrite
    # Remove any lingering nvidia.com/gpu taint — a node that previously ran as a GPU
    # worker retains the taint across in-place reinstalls; without this, CPU workloads
    # selecting ai-tier-node would stay Pending on it.
    oc adm taint node "${node}" nvidia.com/gpu=true:NoSchedule- 2>/dev/null || true
  done

  # Verify labeled nodes have the label — scope check to listed nodes in manual mode
  # (auto mode checks all workers; manual mode only checks what the user explicitly listed)
  local unlabeled=""
  if [[ "${NODE_LABEL_STRATEGY}" == "manual" ]]; then
    for node in "${ai_nodes[@]:+${ai_nodes[@]}}"; do
      local val
      val=$(oc get node "${node}" -o jsonpath='{.metadata.labels.splunk\.ai/ai-tier-node}' 2>/dev/null || echo "")
      [[ -z "${val}" ]] && unlabeled+="${node}"$'\n'
    done
  else
    unlabeled=$(oc get nodes -l node-role.kubernetes.io/worker -o json 2>/dev/null \
      | python3 -c "
import json,sys
data=json.load(sys.stdin)
for n in data['items']:
    if 'splunk.ai/ai-tier-node' not in n['metadata']['labels']:
        print(n['metadata']['name'])
" 2>/dev/null || echo "")
  fi

  if [[ -n "${unlabeled}" ]]; then
    err "Worker node(s) still missing splunk.ai/ai-tier-node after labeling:
$(echo "${unlabeled}" | sed 's/^/  /')

If using nodeLabelStrategy: auto, check that worker nodes exist, or switch to
nodeLabelStrategy: manual and list nodes explicitly under openshift.nodes in the config."
  fi

  log "  ✓ Control-plane nodes: ${#control_nodes[@]}"
  log "  ✓ AI-tier worker nodes: ${#ai_nodes[@]}"
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

  local _cm_url="${CERT_MANAGER_MANIFEST_URL:-https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml}"
  # oc apply -f does not understand file:// — strip it to a bare path
  [[ "${_cm_url}" == file://* ]] && _cm_url="${_cm_url#file://}"
  oc apply -f "${_cm_url}"

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
  # When the config requests a specific storage class, skip only if THAT class already
  # exists — not merely because the cluster has some other default. The AIPlatform CR
  # emits storageClassName: ${STORAGE_CLASS}, so skipping on an unrelated default would
  # leave VectorDB PVCs bound to a class that was never created and stuck Pending.
  if [[ -n "${STORAGE_CLASS}" && "${STORAGE_CLASS}" != "null" ]]; then
    if oc get storageclass "${STORAGE_CLASS}" &>/dev/null; then
      log "  ✓ Requested storage class '${STORAGE_CLASS}' already exists, skipping local-path install"
      oc get storageclass
      return 0
    fi
    if [[ "${STORAGE_CLASS}" != "local-path" ]]; then
      warn "Configured storage.storageClass='${STORAGE_CLASS}' does not exist and is not 'local-path'.
    This installer only provisions local-path; create '${STORAGE_CLASS}' manually or set storage.storageClass: local-path in the config."
      return 0
    fi
    # STORAGE_CLASS is 'local-path' and missing — fall through to install it.
  elif oc get storageclass 2>/dev/null | grep -q "(default)"; then
    # No specific class requested: rely on the cluster default if one already exists.
    log "  ✓ Default storage class already exists, skipping local-path install"
    oc get storageclass
    return 0
  fi

  log "Installing local-path-provisioner..."
  local _lp_url="${LOCAL_PATH_MANIFEST_URL:-https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml}"
  [[ "${_lp_url}" == file://* ]] && _lp_url="${_lp_url#file://}"
  oc apply -f "${_lp_url}"

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
  # busybox lacks chcon; use ubi-minimal which ships selinux-utils so chcon runs.
  # container_file_t allows any container to read/write regardless of MCS categories.
  # Without this, local-path-provisioner creates dirs with var_t which blocks all containers.
  local _patch_file; _patch_file=$(mktemp /tmp/local-path-patch-XXXXXX.json)
  printf '%s' '{"data":{"helperPod.yaml":"apiVersion: v1\nkind: Pod\nmetadata:\n  name: helper-pod\nspec:\n  priorityClassName: system-node-critical\n  tolerations:\n    - key: node.kubernetes.io/disk-pressure\n      operator: Exists\n      effect: NoSchedule\n  containers:\n  - name: helper-pod\n    image: registry.access.redhat.com/ubi8/ubi-minimal\n    imagePullPolicy: IfNotPresent\n    securityContext:\n      privileged: true\n","setup":"#!/bin/sh\nset -eu\nmkdir -m 0777 -p \"$VOL_DIR\"\nif command -v chcon >/dev/null 2>&1; then\n  chcon -Rt container_file_t -l s0 \"$VOL_DIR\" 2>/dev/null || true\nfi\n"}}' \
    > "${_patch_file}"
  oc patch configmap local-path-config -n local-path-storage --type=merge --patch-file="${_patch_file}"
  rm -f "${_patch_file}"

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
  local workers=()
  case "${NODE_LABEL_STRATEGY:-auto}" in
    manual)
      while IFS= read -r node; do
        [[ -n "$node" && "$node" != "null" ]] && workers+=("$node")
      done < <(yq eval '.openshift.nodes[]' "${CONFIG_FILE}" 2>/dev/null)
      ;;
    *)
      while IFS= read -r node; do
        [[ -n "$node" ]] && workers+=("$node")
      done < <(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null | sed 's|node/||')
      ;;
  esac
  for node in "${workers[@]}"; do
    log "  Relabeling node ${node}..."
    timeout 60 oc debug "node/${node}" --request-timeout=60s --image=registry.access.redhat.com/ubi8/ubi-minimal -- \
      sh -c "mkdir -p /host/opt/local-path-provisioner && \
             chcon -Rt container_file_t -l s0 /host/opt/local-path-provisioner/ 2>/dev/null || true; \
             echo relabeled" 2>/dev/null || \
    timeout 60 oc debug "node/${node}" --request-timeout=60s -- \
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

  # If the namespace is stuck Terminating, force-clear its finalizers so helm
  # can recreate it cleanly.
  if oc get namespace opentelemetry-operator-system -o jsonpath='{.status.phase}' 2>/dev/null \
      | grep -q "Terminating"; then
    log "  Namespace opentelemetry-operator-system stuck Terminating — clearing finalizers..."
    oc get namespace opentelemetry-operator-system -o json \
      | python3 -c "import json,sys; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" \
      | oc replace --raw /api/v1/namespaces/opentelemetry-operator-system/finalize -f - &>/dev/null || true
    local _w=0
    until ! oc get namespace opentelemetry-operator-system &>/dev/null || (( _w >= 30 )); do
      sleep 2; (( _w += 2 ))
    done
  fi

  local otel_chart_ref
  if [[ -n "${OTEL_CHART_PATH:-}" && -f "${OTEL_CHART_PATH}" ]]; then
    otel_chart_ref="${OTEL_CHART_PATH}"
    log "  Using local chart: ${otel_chart_ref}"
  else
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
    helm repo update open-telemetry 2>/dev/null || true
    otel_chart_ref="open-telemetry/opentelemetry-operator"
  fi

  local otel_retries=0
  while (( otel_retries < 6 )); do
    local otel_out
    otel_out=$(helm upgrade --install opentelemetry-operator "${otel_chart_ref}" \
      --namespace opentelemetry-operator-system --create-namespace \
      --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib \
      --set admissionWebhooks.certManager.enabled=true \
      --wait=false --timeout=10m 2>&1) || true
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

  local kuberay_chart_ref kuberay_version_flag=()
  if [[ -n "${KUBERAY_CHART_PATH:-}" && -f "${KUBERAY_CHART_PATH}" ]]; then
    kuberay_chart_ref="${KUBERAY_CHART_PATH}"
    log "  Using local chart: ${kuberay_chart_ref}"
  else
    helm repo add kuberay https://ray-project.github.io/kuberay-helm/ 2>/dev/null || true
    helm repo update kuberay
    kuberay_chart_ref="kuberay/kuberay-operator"
    kuberay_version_flag=(--version 1.2.2)
  fi

  helm upgrade --install kuberay-operator "${kuberay_chart_ref}" \
    --namespace ray-system --create-namespace \
    "${kuberay_version_flag[@]+"${kuberay_version_flag[@]}"}" \
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

    # Append the ECR pull secret to the default SA without dropping any it already has
    # (OpenShift auto-injects default-dockercfg-* builder/pull secrets there).
    add_ecr_pull_secret_to_sa default "${ns}"

    log "  ✓ ecr-registry-secret created in ${ns}"
  done

  # Also patch the operator SA specifically
  add_ecr_pull_secret_to_sa splunk-ai-operator-controller-manager splunk-ai-operator-system
}

# Append a pull secret to a service account's imagePullSecrets, preserving
# any existing entries. No-op if the secret is already listed, so reruns are safe.
add_pull_secret_to_sa() {
  local sa="$1" ns="$2" secret="$3"

  # Already present? nothing to do.
  if oc get serviceaccount "${sa}" -n "${ns}" \
      -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null \
      | tr ' ' '\n' | grep -qx "${secret}"; then
    return 0
  fi

  # If the SA has no imagePullSecrets yet, a merge patch is enough. Otherwise use a
  # JSON add patch to append to the existing array without replacing it.
  if oc get serviceaccount "${sa}" -n "${ns}" \
      -o jsonpath='{.imagePullSecrets}' 2>/dev/null | grep -q '\['; then
    oc patch serviceaccount "${sa}" -n "${ns}" --type=json \
      -p "[{\"op\":\"add\",\"path\":\"/imagePullSecrets/-\",\"value\":{\"name\":\"${secret}\"}}]" 2>/dev/null || true
  else
    oc patch serviceaccount "${sa}" -n "${ns}" \
      -p "{\"imagePullSecrets\": [{\"name\": \"${secret}\"}]}" 2>/dev/null || true
  fi
}

# Convenience wrapper kept for callers that predate the generic function.
add_ecr_pull_secret_to_sa() { add_pull_secret_to_sa "$1" "$2" "ecr-registry-secret"; }

# Build a JSON array of {"name": "<secret>"} objects from a newline-separated list
# of secret names, e.g. [{"name":"ecr-registry-secret"},{"name":"docker-hub-secret"}].
pull_secrets_json_array() {
  local names="$1"
  local out="" name
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    [[ -n "${out}" ]] && out="${out},"
    out="${out}{\"name\":\"${name}\"}"
  done <<< "${names}"
  echo "[${out}]"
}

# Return the names of the pull secrets this installer created that actually exist
# in the given namespace. Used to patch deployments and service accounts after the
# namespace's pull secrets have been created. Matches the fixed secret names used
# by create_image_pull_secrets plus the (configurable) custom-registry secret name.
get_pull_secret_names() {
  local ns="$1"
  local custom_name
  custom_name=$(yq eval '.imagePullSecrets.custom.name // "custom-registry-secret"' "${CONFIG_FILE}" 2>/dev/null || echo "custom-registry-secret")
  # Build an exact-match list of candidate secret names, then keep only those
  # that exist in the namespace.
  local candidates=("ecr-registry-secret" "docker-hub-secret" "gcr-secret" "acr-secret" "custom-registry-secret" "${custom_name}")
  local existing
  existing=$(oc get secrets -n "${ns}" --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
  local seen=""
  local c
  for c in "${candidates[@]}"; do
    [[ -z "${c}" ]] && continue
    # Skip duplicates (custom_name may equal the default).
    case " ${seen} " in *" ${c} "*) continue ;; esac
    if grep -qx "${c}" <<< "${existing}"; then
      echo "${c}"
      seen="${seen} ${c}"
    fi
  done
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

  # Patch the operator SA and deployment with all configured pull secrets AFTER the
  # manifest apply (the SA is created by the manifest; patching before apply silently
  # does nothing). Covers ECR and non-ECR (DockerHub/GCR/ACR/custom) registries.
  local _pull_secrets
  _pull_secrets=$(get_pull_secret_names "${ai_operator_ns}")
  if [[ -n "${_pull_secrets}" ]]; then
    # Append each secret to the SA (preserves existing entries).
    while IFS= read -r _secret; do
      [[ -z "${_secret}" ]] && continue
      add_pull_secret_to_sa splunk-ai-operator-controller-manager "${ai_operator_ns}" "${_secret}"
    done <<< "${_pull_secrets}"
    # Set the deployment's imagePullSecrets to the full list in one patch. A merge
    # patch creates the field if absent and replaces it if present (idempotent).
    local _ips_json
    _ips_json=$(pull_secrets_json_array "${_pull_secrets}")
    oc patch deployment splunk-ai-operator-controller-manager \
      -n "${ai_operator_ns}" --type=merge \
      -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":${_ips_json}}}}}" \
      2>/dev/null || true
    log "  ✓ Pull secrets patched into operator SA and deployment: $(echo "${_pull_secrets}" | tr '\n' ' ')"
  fi

  # Rollout restart so the deployment picks up the updated pull secrets.
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

  # Server-side apply: idempotent create-or-update that NEVER deletes existing objects.
  # This bundle includes CRDs and the splunk-operator Namespace; `oc replace --force` is
  # delete-then-recreate, so recreating the CRDs would cascade-delete every Splunk custom
  # resource (Standalones, etc.). Server-side apply patches in place and preserves them.
  oc apply --server-side --force-conflicts -f "${SPLUNK_OPERATOR_FILE}" 2>&1 || true
  log "  Splunk Operator resources applied"

  # Grant privileged SCC to the whole namespace group — this is the pattern OCP SCC admission
  # actually honours. The operator pod adds NET_BIND_SERVICE which anyuid blocks; privileged
  # covers both. group-based grant is namespace-scoped and survives operator manifest updates.
  oc adm policy add-scc-to-group privileged \
    "system:serviceaccounts:${splunk_operator_ns}" 2>/dev/null || true
  # Force pod recreation so it picks up the new SCC grant
  oc delete replicaset -n "${splunk_operator_ns}" --all 2>/dev/null || true

  # Patch all configured pull secrets into the Splunk operator deployment.
  local dep_name _splunk_pull_secrets
  dep_name=$(oc -n "${splunk_operator_ns}" get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  _splunk_pull_secrets=$(get_pull_secret_names "${splunk_operator_ns}")
  if [[ -n "${dep_name}" && -n "${_splunk_pull_secrets}" ]]; then
    # Set imagePullSecrets to the full list in one merge patch (creates the field if
    # absent, replaces it if present). A JSON add to `/imagePullSecrets/-` would fail
    # when the array does not yet exist on the podspec.
    local _splunk_ips_json
    _splunk_ips_json=$(pull_secrets_json_array "${_splunk_pull_secrets}")
    oc -n "${splunk_operator_ns}" patch deployment "${dep_name}" \
      --type=merge \
      -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":${_splunk_ips_json}}}}}" \
      2>/dev/null || true
    oc rollout restart deployment "${dep_name}" -n "${splunk_operator_ns}" 2>/dev/null || true
  fi

  wait_for_crd standalones.enterprise.splunk.com 300
  log "  ✓ Splunk Operator installed"
}

# Keep Splunk's interactive-token issuer and the value propagated to
# SAIA/SLIM byte-identical. The short namespace-local Service name matches the
# issuer emitted by the bundled Splunk configuration and is reachable from all
# consumers in the AI Platform namespace.
internal_splunk_management_url() {
  printf 'https://splunk-%s-standalone-service:8089' \
    "${AI_STANDALONE_NAME}"
}

# HEC is consumed only by the OpenTelemetry exporter. It is not a JWT issuer.
internal_splunk_hec_url() {
  printf 'http://splunk-%s-standalone-service.%s.svc.cluster.local:8088' \
    "${AI_STANDALONE_NAME}" "${AI_NS}"
}

render_splunk_defaults_manifest() {
  local internal_splunk_url
  internal_splunk_url="$(internal_splunk_management_url)"
  cat <<YAML
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
                issuer_uri: ${internal_splunk_url}
                certFile: \$SPLUNK_HOME/etc/auth/server.pem
                sslPassword: password
YAML
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
    minio_endpoint="https://s3.${OBJ_STORE_REGION}.amazonaws.com"
    log "  type=aws: using S3 endpoint ${minio_endpoint}"
  fi
  [[ -z "${minio_endpoint}" ]] && err "storage.objectStore.endpoint must be set for type=${OBJ_STORE_TYPE}"

  # This issuer becomes the JWT "iss" claim and must match
  # AIPlatform.spec.splunkConfiguration.endpoint exactly.
  render_splunk_defaults_manifest | oc -n "${AI_NS}" apply -f -

  oc apply --server-side --force-conflicts -f - <<YAML
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  replicas: 1
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: splunk.ai/ai-tier-node
                operator: In
                values:
                  - "true"
  tolerations:
    - key: "node-role.kubernetes.io/master"
      operator: "Exists"
      effect: "NoSchedule"
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
        region: ${OBJ_STORE_REGION}
        path: ${OBJ_STORE_BUCKET}
        secretRef: minio-credentials
YAML

  log "  ✓ Splunk Standalone CR applied"
}

# render_ai_platform_manifest prints only the AIPlatform resource. Keeping the
# renderer side-effect free makes the exact manifest testable without an
# OpenShift cluster.
render_ai_platform_manifest() {
  local internal_splunk_url internal_splunk_hec_url_value
  internal_splunk_url="$(internal_splunk_management_url)"
  internal_splunk_hec_url_value="$(internal_splunk_hec_url)"
  cat <<YAML
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${AI_PLATFORM_NAME}
spec:
  objectStorage:
    path: ${obj_path}
    region: ${OBJ_STORE_REGION}
    $( [[ -n "${obj_endpoint}" ]] && echo "endpoint: \"${obj_endpoint}\"" )
    secretRef: minio-credentials
${image_pull_secrets}
  defaultAcceleratorType: ${DEFAULT_ACCELERATOR}
  scaleFactor: ${AI_SCALE_FACTOR:-1}
  features:
${features_yaml}
${svc_template_yaml}${storage_yaml}
  workerGroupConfig:
    imageRegistry: "${WORKER_IMAGE_REGISTRY}"
  cpuScheduler:
    nodeSelector:
      splunk.ai/ai-tier-node: "true"
    tolerations: ${cpu_tolerations_inline}
  gpuScheduler:
    nodeSelector:
      splunk.ai/ai-tier-node: "true"
  splunkConfiguration:
    endpoint: ${internal_splunk_url}
    hecEndpoint: ${internal_splunk_hec_url_value}
    secretRef:
      name: ${splunk_ns_secret}
      namespace: ${AI_NS}
${trusted_issuers_yaml:-}
YAML
}

# ====== INSTALL AI PLATFORM CR ======
install_ai_platform_cr() {
  log "Installing AIPlatform CR: ${AI_PLATFORM_NAME}..."

  ensure_namespace "${AI_NS}"

  # Clean up stuck pods from previous runs
  oc delete jobs -n "${AI_NS}" --field-selector status.successful=0 --wait=false 2>/dev/null || true
  oc delete pods -n "${AI_NS}" --field-selector status.phase=Failed --wait=false 2>/dev/null || true

  # Build imagePullSecrets block — include every docker-registry secret that
  # exists in the namespace, covering ECR, DockerHub, GCR, ACR, and custom
  # registries. This avoids hard-coding a fixed list of names.
  local secrets_yaml=""
  while IFS= read -r secret_name; do
    [[ -z "${secret_name}" ]] && continue
    secrets_yaml+="      - name: ${secret_name}"$'\n'
  done < <(oc get secrets -n "${AI_NS}" \
    -o jsonpath='{range .items[?(@.type=="kubernetes.io/dockerconfigjson")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null || true)
  # Emit the whole images: block only when secrets exist. spec.images is an object in
  # the CRD, so a bare "images:" with no children would serialize to null and fail
  # validation. imagePullSecrets are optional, so omit the key entirely when empty.
  local image_pull_secrets=""
  [[ -n "${secrets_yaml}" ]] && image_pull_secrets="  images:"$'\n'"    imagePullSecrets:"$'\n'"${secrets_yaml}"

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
      local fname fver fsa
      fname=$(yq eval ".aiPlatform.features[$i].name" "${CONFIG_FILE}")
      fver=$(yq eval ".aiPlatform.features[$i].version // \"1.0.0\"" "${CONFIG_FILE}")
      fsa=$(yq eval ".aiPlatform.features[$i].serviceAccountName // \"\"" "${CONFIG_FILE}")
      if [[ -n "$fname" && "$fname" != "null" ]]; then
        features_yaml+="    - name: ${fname}"$'\n'
        features_yaml+="      version: \"${fver}\""$'\n'
        [[ -n "$fsa" && "$fsa" != "null" ]] && \
          features_yaml+="      serviceAccountName: ${fsa}"$'\n'
      fi
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

  # Optional additional JWT issuers. The in-cluster issuer remains first via
  # splunkConfiguration.endpoint; configured issuers are appended by the
  # SAIA/SLIM reconcilers. This matches the k0s installer design.
  local trusted_issuers_yaml=""
  local trusted_issuers_count
  trusted_issuers_count=$(yq eval '.splunk.trustedIssuers | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
  if [[ "${trusted_issuers_count}" =~ ^[0-9]+$ ]] && (( trusted_issuers_count > 0 )); then
    trusted_issuers_yaml="    trustedIssuers:"$'\n'
    local trusted_issuer_index=0 trusted_issuer_url
    while (( trusted_issuer_index < trusted_issuers_count )); do
      trusted_issuer_url=$(yq eval ".splunk.trustedIssuers[${trusted_issuer_index}]" "${CONFIG_FILE}" 2>/dev/null || echo "")
      if [[ -n "${trusted_issuer_url}" && "${trusted_issuer_url}" != "null" ]]; then
        trusted_issuers_yaml+="      - \"${trusted_issuer_url}\""$'\n'
      fi
      trusted_issuer_index=$((trusted_issuer_index + 1))
    done
  fi

  local storage_yaml=""
  if [[ -n "${STORAGE_CLASS}" && "${STORAGE_CLASS}" != "null" ]]; then
    storage_yaml="  storage:"$'\n'"    vectorDB:"$'\n'"      size: ${VECTORDB_SIZE}"$'\n'"      storageClassName: ${STORAGE_CLASS}"$'\n'
  fi

  # CPU scheduling tolerations — read from config, default to empty list
  local cpu_tols cpu_tolerations_inline="[]"
  cpu_tols=$(yq eval '.aiPlatform.cpuScheduling.tolerations // []' "${CONFIG_FILE}" 2>/dev/null || echo "[]")
  if [[ "${cpu_tols}" != "[]" && "${cpu_tols}" != "null" && -n "${cpu_tols}" ]]; then
    cpu_tolerations_inline=$'\n'"$(echo "${cpu_tols}" | sed 's/^/      /')"
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
  defaultAcceleratorType: RTX_PRO_6000_BLACKWELL
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

  render_ai_platform_manifest | oc -n "${AI_NS}" apply --server-side --force-conflicts -f -

  log "  ✓ AIPlatform CR applied"

  local timeout=60 elapsed=0
  while ! oc get aiplatform "${AI_PLATFORM_NAME}" -n "${AI_NS}" >/dev/null 2>&1; do
    sleep 5; elapsed=$((elapsed + 5))
    [[ ${elapsed} -ge ${timeout} ]] && { warn "Timeout waiting for AIPlatform CR"; break; }
  done

  oc get aiplatform "${AI_PLATFORM_NAME}" -n "${AI_NS}" -o wide || true
  log "  ✓ AIPlatform CR installed"
}

# ====== CREATE SAIA ROUTE ======
# Creates an OpenShift Route so SAIA is reachable via a stable external hostname.
# The URL must be reachable from both the browser and from within the cluster
# (Splunk's setup page validates connectivity from the server side).
# NodePort alone doesn't work when node IPs are not externally routable.
create_saia_route() {
  # Re-attempt ingress domain detection in case it was unavailable during load_config.
  if [[ -z "${INGRESS_DOMAIN:-}" ]]; then
    INGRESS_DOMAIN=$(oc get ingresscontroller default -n openshift-ingress-operator \
      -o jsonpath='{.status.domain}' 2>/dev/null || echo "")
  fi
  if [[ -z "${INGRESS_DOMAIN:-}" ]]; then
    warn "Could not determine ingress domain — skipping SAIA Route creation"
    warn "Create it manually: oc expose svc/${AI_PLATFORM_NAME}-saia-saia-service -n ${AI_NS}"
    return 0
  fi

  local route_host="saia.${INGRESS_DOMAIN}"
  local svc_name="${AI_PLATFORM_NAME}-saia-saia-service"

  log "Creating SAIA Route: http://${route_host} ..."

  # Create the Route immediately — do NOT wait for the SAIA service to exist.
  # An OpenShift Route does not require its backend Service to be present at
  # creation time: the router resolves the backend dynamically and returns 503
  # until the service's endpoints appear, then serves traffic automatically.
  # The operator can take tens of minutes to create the SAIA service (model
  # download + vector-db posthook + reconcile), so blocking on it here caused
  # the Route to be skipped whenever that exceeded the wait window — leaving the
  # SAIA URL permanently unreachable even though the install reported success.
  if ! oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: saia
  namespace: ${AI_NS}
  annotations:
    haproxy.router.openshift.io/timeout: "600s"
    haproxy.router.openshift.io/response-buffering: "disabled"
spec:
  host: ${route_host}
  to:
    kind: Service
    name: ${svc_name}
  port:
    targetPort: 8080
EOF
  then
    warn "Failed to create SAIA Route. Create it manually once the SAIA service exists:"
    warn "  oc apply -f - <<'ROUTE'"
    warn "  apiVersion: route.openshift.io/v1"
    warn "  kind: Route"
    warn "  metadata: { name: saia, namespace: ${AI_NS} }"
    warn "  spec: { host: ${route_host}, to: { kind: Service, name: ${svc_name} }, port: { targetPort: 8080 } }"
    warn "  ROUTE"
    return 0
  fi

  # Confirm the Route object now exists so a silent apply failure can't pass as success.
  if ! oc get route saia -n "${AI_NS}" >/dev/null 2>&1; then
    warn "SAIA Route apply reported success but the Route is not present — check cluster state."
    return 0
  fi

  log "  ✓ SAIA Route created: http://${route_host}"
  log "    (Returns 503 until the SAIA service endpoints come up — this is expected"
  log "     while the operator finishes reconciling; it self-heals, no rerun needed.)"
  log "    Use this URL in Splunk AI setup: http://${route_host}"
}

# Return the model-artifact profile used by an accelerator. Keep this selection
# in one place so pre-staging and post-upload verification cannot drift apart.
model_artifacts_config_name() {
  local accel
  accel=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "${accel}" in
    rtx_pro_6000_blackwell) echo "model_artifacts_configs_quantized.yaml" ;;
    *)                      return 1 ;;
  esac
}

# ====== ALL MODELS STAGED PRE-CHECK ======
# all_models_staged <staging_dir> <accel>
# Checks whether every artifact already has a staging_complete marker with matching hf_url.
# Returns 0 (all staged) or 1 (one or more missing).
# Fails open: returns 1 if store is unreachable or tool is missing.
all_models_staged() {
  local staging_dir="$1"
  local accel="$2"
  local config_name config_file
  config_name=$(model_artifacts_config_name "${accel}") || {
    warn "all_models_staged: unsupported accelerator '${accel}'"
    return 1
  }
  config_file="${staging_dir}/${config_name}"

  if [[ ! -f "${config_file}" ]]; then
    warn "all_models_staged: config file not found: ${config_file} — skipping pre-check."
    return 1
  fi

  local ids=() hf_urls=()
  local raw_ids raw_urls
  raw_ids=$(yq eval '.artifact-configs[].artifact-id' "${config_file}" 2>/dev/null) || {
    warn "all_models_staged: could not read artifact IDs from ${config_file} — skipping pre-check."
    return 1
  }
  raw_urls=$(yq eval '.artifact-configs[].hf-url' "${config_file}" 2>/dev/null) || {
    warn "all_models_staged: could not read hf-url fields from ${config_file} — skipping pre-check."
    return 1
  }
  while IFS= read -r id; do
    [[ -n "${id}" ]] && ids+=("${id}")
  done <<< "${raw_ids}"
  while IFS= read -r url; do
    hf_urls+=("${url}")
  done <<< "${raw_urls}"

  if [[ ${#ids[@]} -eq 0 ]]; then
    warn "all_models_staged: no artifact IDs found in ${config_file} — skipping pre-check."
    return 1
  fi

  _marker_matches_url() {
    local content="$1" expected_url="$2"
    echo "${content}" | grep -q "^hf_url=${expected_url}$"
  }

  local missing=()

  case "${OBJ_STORE_TYPE}" in
    aws)
      if ! command -v aws &>/dev/null; then
        warn "all_models_staged: aws CLI not found — skipping pre-check."
        return 1
      fi
      for i in "${!ids[@]}"; do
        local id="${ids[$i]}" hf_url="${hf_urls[$i]:-}"
        local marker_path="s3://${OBJ_STORE_BUCKET}/staging_state/${id}/.staging_complete"
        local content
        content=$(AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
                  AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
                  aws s3 cp "${marker_path}" - --region "${REGION:-us-east-2}" 2>/dev/null) || { missing+=("${id}"); continue; }
        _marker_matches_url "${content}" "${hf_url}" || missing+=("${id}")
      done
      ;;
    minio|seaweedfs)
      if ! command -v mc &>/dev/null; then
        warn "all_models_staged: mc not found — skipping pre-check."
        return 1
      fi
      if [[ -z "${OBJ_STORE_ENDPOINT}" ]]; then
        warn "all_models_staged: OBJ_STORE_ENDPOINT not set — skipping pre-check."
        return 1
      fi
      local _alias="installer_precheck"
      mc alias set "${_alias}" "${OBJ_STORE_ENDPOINT}" \
          "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 &>/dev/null || {
        warn "all_models_staged: could not configure mc alias — skipping pre-check."
        return 1
      }
      for i in "${!ids[@]}"; do
        local id="${ids[$i]}" hf_url="${hf_urls[$i]:-}"
        local marker_path="${_alias}/${OBJ_STORE_BUCKET}/staging_state/${id}/.staging_complete"
        local content
        content=$(mc cat "${marker_path}" 2>/dev/null) || { missing+=("${id}"); continue; }
        _marker_matches_url "${content}" "${hf_url}" || missing+=("${id}")
      done
      ;;
    *)
      warn "all_models_staged: unsupported store type '${OBJ_STORE_TYPE}' — skipping pre-check."
      return 1
      ;;
  esac

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "✓ All ${#ids[@]} models already staged in object store (${OBJ_STORE_TYPE}) — skipping download and upload."
    return 0
  fi

  log "Model staging needed: ${#missing[@]}/${#ids[@]} model(s) not yet staged."
  for _m in "${missing[@]}"; do
    log "  MISSING: ${_m}  (${OBJ_STORE_BUCKET}/staging_state/${_m}/.staging_complete not found or hf_url changed)"
  done
  return 1
}

# ====== MODEL ARTIFACT STAGING ======
# Downloads model artifacts from HuggingFace and uploads them to the configured
# object store. Controlled by storage.modelStaging.enabled in config (default: false).
# Skipped when AIRGAP_MODE=true — models must be pre-staged in that case.
stage_model_artifacts() {
  if [[ "${MODEL_STAGING_ENABLED}" != "true" ]]; then
    log "Model staging disabled (storage.modelStaging.enabled=false), skipping"
    return 0
  fi

  if [[ "${AIRGAP_MODE:-false}" == "true" ]]; then
    log "AIRGAP_MODE=true — skipping model staging (models must be pre-staged in object store)"
    return 0
  fi

  if object_store_auth_looks_like_placeholder; then
    err "Refusing to stage artifacts: objectStore.auth still contains template placeholders; fix ${CONFIG_FILE}"
    return 1
  fi

  local staging_dir
  staging_dir="$(cd "$(dirname "$0")/../artifacts_download_upload_scripts" && pwd)" \
    || { err "Cannot locate artifacts_download_upload_scripts directory (expected sibling of cluster_setup/)"; return 1; }

  log "Model staging directory: ${staging_dir}"

  # ---- Resolve accelerator (normalize to lowercase) ----
  local _accel
  _accel=$(printf '%s' "${DEFAULT_ACCELERATOR}" | tr '[:upper:]' '[:lower:]')

  local _skip_staged="${SKIP_IF_STAGED:-1}"

  # ---- Fast-path: skip everything if all models already staged ----
  if [[ "${_skip_staged}" != "0" ]] && all_models_staged "${staging_dir}" "${_accel}"; then
    return 0
  fi

  wait_for_dependency \
    "HuggingFace (huggingface.co) — required for model weight download" \
    "curl -sf --connect-timeout 10 --max-time 15 https://huggingface.co >/dev/null 2>&1" \
    300

  log "Downloading model artifacts from Hugging Face (accelerator: ${_accel}, skip-if-staged: ${_skip_staged})..."
  ( cd "${staging_dir}" && \
      ACCELERATOR="${_accel}" \
      SKIP_IF_EXISTS="${SKIP_IF_EXISTS:-0}" \
      SKIP_IF_STAGED="${_skip_staged}" \
      OBJ_STORE_TYPE="${OBJ_STORE_TYPE}" \
      OBJ_STORE_BUCKET="${OBJ_STORE_BUCKET}" \
      OBJ_STORE_ENDPOINT="${OBJ_STORE_ENDPOINT}" \
      OBJ_STORE_ACCESS_KEY="${MINIO_ROOT_USER}" \
      OBJ_STORE_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
      S3_REGION="${REGION:-us-east-2}" \
      S3_PREFIX="model_artifacts" \
      bash ./download_from_huggingface.sh ) \
    || { err "HuggingFace download failed — see output above"; return 1; }

  log "Uploading model artifacts to object store (type=${OBJ_STORE_TYPE})..."
  if [[ "${OBJ_STORE_TYPE}" == "minio" || "${OBJ_STORE_TYPE}" == "seaweedfs" ]]; then
    [[ -n "${OBJ_STORE_ENDPOINT}" ]] || { err "storage.objectStore.endpoint is required for ${OBJ_STORE_TYPE} model staging"; return 1; }
  fi

  case "${OBJ_STORE_TYPE}" in
    aws)
      ( cd "${staging_dir}" && \
        S3_BUCKET="${OBJ_STORE_BUCKET}" \
        S3_REGION="${OBJ_STORE_REGION:-us-east-2}" \
        AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
        AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
        SKIP_IF_STAGED="${_skip_staged}" \
        bash ./upload_to_s3.sh ) \
        || { err "Upload to S3 failed"; return 1; }
      ;;
    minio)
      ( cd "${staging_dir}" && \
        OBJECT_STORE_ENDPOINT="${OBJ_STORE_ENDPOINT}" \
        OBJECT_STORE_BUCKET="${OBJ_STORE_BUCKET}" \
        OBJECT_STORE_ACCESS_KEY="${MINIO_ROOT_USER}" \
        OBJECT_STORE_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
        SKIP_IF_STAGED="${_skip_staged}" \
        bash ./upload_to_minio.sh ) \
        || { err "Upload to MinIO failed"; return 1; }
      ;;
    seaweedfs)
      ( cd "${staging_dir}" && \
        OBJECT_STORE_ENDPOINT="${OBJ_STORE_ENDPOINT}" \
        OBJECT_STORE_BUCKET="${OBJ_STORE_BUCKET}" \
        OBJECT_STORE_ACCESS_KEY="${MINIO_ROOT_USER}" \
        OBJECT_STORE_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
        SKIP_IF_STAGED="${_skip_staged}" \
        bash ./upload_to_seaweedfs_upload_only.sh ) \
        || { err "Upload to SeaweedFS failed"; return 1; }
      ;;
    *)
      err "Unsupported objectStore.type for model staging: '${OBJ_STORE_TYPE}' (expected: aws | minio | seaweedfs)"
      return 1
      ;;
  esac

  # ---- Post-stage verification ----
  log "Verifying model staging completeness..."
  if all_models_staged "${staging_dir}" "${_accel}"; then
    log "✓ Post-stage verification passed — all models confirmed staged."
  else
    warn "Post-stage verification: some models may not have been staged successfully."
    warn "Check the upload logs above. You can re-run with SKIP_IF_STAGED=0 to force re-upload."
  fi

  log "✓ Model artifact staging complete (type=${OBJ_STORE_TYPE}, bucket=${OBJ_STORE_BUCKET})"
}

# ====== CREATE IMAGE PULL SECRETS ======
# Creates pull secrets for all enabled registries (ECR, DockerHub, GCR, ACR, custom)
# in the given namespace. Uses --dry-run=client | apply so it is idempotent.
create_image_pull_secrets() {
  local ns="$1"
  ensure_namespace "${ns}"

  log "Creating image pull secrets in ${ns}..."
  local secrets_created=()

  # ECR
  if [[ "${IMAGE_PULL_SECRETS_ECR_ENABLED}" == "true" ]]; then
    local ecr_region="${ECR_REGION:-us-east-2}"
    local ecr_account="${ECR_ACCOUNT:-}"
    if ! aws sts get-caller-identity &>/dev/null; then
      warn "AWS credentials not available — skipping ECR secret creation"
    else
      [[ -z "${ecr_account}" ]] && ecr_account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
      local ecr_password
      if ecr_password=$(aws ecr get-login-password --region "${ecr_region}" 2>/dev/null); then
        oc create secret docker-registry ecr-registry-secret \
          --docker-server="${ecr_account}.dkr.ecr.${ecr_region}.amazonaws.com" \
          --docker-username=AWS \
          --docker-password="${ecr_password}" \
          --namespace="${ns}" \
          --dry-run=client -o yaml | oc apply -f -
        log "  ✓ ECR secret created: ecr-registry-secret"
        secrets_created+=("ecr-registry-secret")
      else
        warn "Failed to get ECR token — skipping ECR secret"
      fi
    fi
  fi

  # DockerHub
  if [[ "${IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED}" == "true" ]]; then
    local dh_user dh_pass dh_email
    dh_user=$(yq eval '.imagePullSecrets.dockerHub.username // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    dh_pass=$(yq eval '.imagePullSecrets.dockerHub.password // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    dh_email=$(yq eval '.imagePullSecrets.dockerHub.email // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    if [[ -n "${dh_user}" && -n "${dh_pass}" ]]; then
      local email_arg=""
      [[ -n "${dh_email}" ]] && email_arg="--docker-email=${dh_email}"
      oc create secret docker-registry docker-hub-secret \
        --docker-server=docker.io \
        --docker-username="${dh_user}" \
        --docker-password="${dh_pass}" \
        ${email_arg} \
        --namespace="${ns}" \
        --dry-run=client -o yaml | oc apply -f -
      log "  ✓ DockerHub secret created: docker-hub-secret"
      secrets_created+=("docker-hub-secret")
    else
      warn "DockerHub credentials not configured — skipping"
    fi
  fi

  # GCR
  if [[ "${IMAGE_PULL_SECRETS_GCR_ENABLED}" == "true" ]]; then
    local gcr_key
    gcr_key=$(yq eval '.imagePullSecrets.gcr.jsonKey // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    if [[ -n "${gcr_key}" && "${gcr_key}" != "null" ]]; then
      oc create secret docker-registry gcr-secret \
        --docker-server=gcr.io \
        --docker-username=_json_key \
        --docker-password="${gcr_key}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | oc apply -f -
      log "  ✓ GCR secret created: gcr-secret"
      secrets_created+=("gcr-secret")
    else
      warn "GCR JSON key not configured — skipping"
    fi
  fi

  # ACR
  if [[ "${IMAGE_PULL_SECRETS_ACR_ENABLED}" == "true" ]]; then
    local acr_reg acr_user acr_pass
    acr_reg=$(yq eval '.imagePullSecrets.acr.registry // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    acr_user=$(yq eval '.imagePullSecrets.acr.username // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    acr_pass=$(yq eval '.imagePullSecrets.acr.password // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    if [[ -n "${acr_reg}" && -n "${acr_user}" && -n "${acr_pass}" ]]; then
      oc create secret docker-registry acr-secret \
        --docker-server="${acr_reg}" \
        --docker-username="${acr_user}" \
        --docker-password="${acr_pass}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | oc apply -f -
      log "  ✓ ACR secret created: acr-secret"
      secrets_created+=("acr-secret")
    else
      warn "ACR credentials not configured — skipping"
    fi
  fi

  # Custom registry
  if [[ "${IMAGE_PULL_SECRETS_CUSTOM_ENABLED}" == "true" ]]; then
    local c_name c_server c_user c_pass c_email
    c_name=$(yq eval '.imagePullSecrets.custom.name // "custom-registry-secret"' "${CONFIG_FILE}" 2>/dev/null || echo "custom-registry-secret")
    c_server=$(yq eval '.imagePullSecrets.custom.server // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    c_user=$(yq eval '.imagePullSecrets.custom.username // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    c_pass=$(yq eval '.imagePullSecrets.custom.password // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    c_email=$(yq eval '.imagePullSecrets.custom.email // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    if [[ -n "${c_server}" && -n "${c_user}" && -n "${c_pass}" ]]; then
      local email_arg=""
      [[ -n "${c_email}" ]] && email_arg="--docker-email=${c_email}"
      oc create secret docker-registry "${c_name}" \
        --docker-server="${c_server}" \
        --docker-username="${c_user}" \
        --docker-password="${c_pass}" \
        ${email_arg} \
        --namespace="${ns}" \
        --dry-run=client -o yaml | oc apply -f -
      log "  ✓ Custom registry secret created: ${c_name}"
      secrets_created+=("${c_name}")
    else
      warn "Custom registry credentials not configured — skipping"
    fi
  fi

  if [[ ${#secrets_created[@]} -gt 0 ]]; then
    log "  Pull secrets created in ${ns}: ${secrets_created[*]}"
    # Attach every created secret to the default SA so pods using it can pull images.
    for _s in "${secrets_created[@]}"; do
      add_pull_secret_to_sa default "${ns}" "${_s}"
    done
  else
    log "  No additional pull secrets configured"
  fi
}

# ====== MAIN INSTALL ======
main_install() {
  log "============================================"
  log " Splunk AI Platform — OpenShift Install"
  log "============================================"

  # Sync SILENT_INSTALL ↔ AUTO_APPROVE
  [[ "${AUTO_APPROVE:-false}" == "true" ]] && SILENT_INSTALL=true
  SILENT_INSTALL="${SILENT_INSTALL:-false}"
  [[ "${SILENT_INSTALL}" == "true" ]] && AUTO_APPROVE=true

  load_config
  validate_image_config
  configure_images

  resolve_accelerator_type
  resolve_model_staging

  show_install_plan

  phase_start "Model Staging"
  step_start "Model artifact staging"
  stage_model_artifacts
  step_ok
  phase_end "Model Staging"

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

  step_start "Image pull secrets"
  ensure_ecr_pull_secret
  create_image_pull_secrets "${AI_NS}"
  create_image_pull_secrets "splunk-ai-operator-system"
  create_image_pull_secrets "splunk-operator"
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

  step_start "SAIA Route"
  create_saia_route
  step_ok
  phase_end "AI Platform Stack"

  show_step_summary

  local saia_url=""
  [[ -n "$INGRESS_DOMAIN" ]] && saia_url="http://saia.${INGRESS_DOMAIN}"

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
  if [[ -n "$saia_url" ]]; then
  log ""
  log "  SAIA app URL (use this in Splunk AI setup):"
  log "     ${saia_url}"
  fi
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
  log "Removing SAIA Route..."
  oc delete route saia -n "${AI_NS}" --ignore-not-found=true 2>/dev/null || true

  log "Removing AIPlatform CR and waiting for finalizers..."
  oc delete aiplatform --all -n "${AI_NS}" --timeout=120s 2>/dev/null || true
  oc delete standalone --all -n "${AI_NS}" --timeout=60s 2>/dev/null || true

  # ── 2. AI Platform namespace (cascades all pods, PVCs, services, etc.) ──
  log "Deleting namespace ${AI_NS}..."
  force_delete_namespace "${AI_NS}" 180

  # ── 3. Splunk AI Operator ──
  log "Removing Splunk AI Operator..."
  force_delete_namespace "${ai_operator_ns}" 60
  # Remove cluster-scoped resources (CRDs, ClusterRoles, webhooks) from manifests
  [[ -f "${SPLUNK_AI_FILE}" ]] && \
    oc delete -f "${SPLUNK_AI_FILE}" --ignore-not-found=true 2>/dev/null || true

  # ── 4. Splunk Operator ──
  log "Removing Splunk Operator..."
  force_delete_namespace "${splunk_operator_ns}" 60
  [[ -f "${SPLUNK_OPERATOR_FILE}" ]] && \
    oc delete -f "${SPLUNK_OPERATOR_FILE}" --ignore-not-found=true 2>/dev/null || true

  # ── 5. KubeRay Operator (helm) ──
  log "Removing KubeRay Operator..."
  helm uninstall kuberay-operator -n ray-system 2>/dev/null || true
  force_delete_namespace ray-system 60

  # ── 6. OpenTelemetry Operator (helm) ──
  log "Removing OpenTelemetry Operator..."
  helm uninstall opentelemetry-operator -n opentelemetry-operator-system 2>/dev/null || true
  force_delete_namespace opentelemetry-operator-system 60

  # ── 7. cert-manager (helm) ──
  log "Removing cert-manager..."
  helm uninstall cert-manager -n cert-manager 2>/dev/null || true
  force_delete_namespace cert-manager 60
  # Remove CRDs left by cert-manager (helm uninstall doesn't remove CRDs by default)
  oc get crd -o name 2>/dev/null | grep cert-manager | xargs -r oc delete --ignore-not-found=true 2>/dev/null || true

  # ── 8. local-path-provisioner ──
  log "Removing local-path-provisioner..."
  oc delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml \
    --ignore-not-found=true 2>/dev/null || true
  force_delete_namespace local-path-storage 60
  oc delete storageclass local-path --ignore-not-found=true 2>/dev/null || true

  # ── 9. NVIDIA GPU Operator ──
  log "Removing NVIDIA GPU Operator..."
  oc delete clusterpolicy gpu-cluster-policy --ignore-not-found=true 2>/dev/null || true
  oc delete subscription gpu-operator-certified -n nvidia-gpu-operator --ignore-not-found=true 2>/dev/null || true
  oc delete csv -n nvidia-gpu-operator --all --ignore-not-found=true 2>/dev/null || true
  force_delete_namespace nvidia-gpu-operator 60

  # ── 10. NFD ──
  log "Removing Node Feature Discovery..."
  oc delete nodefeaturediscovery nfd-instance -n openshift-nfd --ignore-not-found=true 2>/dev/null || true
  oc delete subscription nfd -n openshift-nfd --ignore-not-found=true 2>/dev/null || true
  oc delete csv -n openshift-nfd --all --ignore-not-found=true 2>/dev/null || true
  force_delete_namespace openshift-nfd 60

  # ── 11. Node labels and taints added by label_nodes() ──
  # Match both the current ai-tier-node label and the legacy workload-type label so
  # teardown cleans up stacks installed before the single-label refactor. Also strip
  # the nvidia.com/gpu taint older installs applied to GPU worker nodes.
  log "Removing splunk.ai/* node labels and GPU taint..."
  for node in $( { oc get nodes -l 'splunk.ai/ai-tier-node' -o name 2>/dev/null; \
                   oc get nodes -l 'splunk.ai/workload-type' -o name 2>/dev/null; \
                 } | sort -u ); do
    oc label "${node}" splunk.ai/ai-tier-node- splunk.ai/workload-type- 2>/dev/null || true
    oc adm taint "${node}" nvidia.com/gpu=true:NoSchedule- 2>/dev/null || true
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
    oc get deployments --all-namespaces -o wide                  > "${bundle_dir}/deployments.txt"  2>&1 || true
    oc get statefulsets --all-namespaces -o wide                 > "${bundle_dir}/statefulsets.txt" 2>&1 || true
    oc get daemonsets --all-namespaces -o wide                   > "${bundle_dir}/daemonsets.txt"   2>&1 || true
    oc describe deployments --all-namespaces                     > "${bundle_dir}/deployment-details.txt"   2>&1 || true
    oc describe statefulsets --all-namespaces                    > "${bundle_dir}/statefulset-details.txt"  2>&1 || true
    oc describe daemonsets --all-namespaces                      > "${bundle_dir}/daemonset-details.txt"    2>&1 || true

    # Per-pod log collection: ALL pods, with conditional tail size (300 for failing, 100 for running)
    log "Collecting pod logs (all pods)..."
    local ns pod phase
    while IFS= read -r line; do
      ns=$(echo "${line}" | awk '{print $1}')
      pod=$(echo "${line}" | awk '{print $2}')
      phase=$(echo "${line}" | awk '{print $4}')
      mkdir -p "${bundle_dir}/pod-logs/${ns}"
      local tail_lines=100
      if [[ "${phase}" != "Running" && "${phase}" != "Completed" ]]; then
        tail_lines=300
      fi
      oc logs "${pod}" -n "${ns}" --all-containers=true --tail="${tail_lines}" \
        > "${bundle_dir}/pod-logs/${ns}/${pod}.log" 2>&1 || true
      oc logs "${pod}" -n "${ns}" --all-containers=true --previous --tail=100 \
        > "${bundle_dir}/pod-logs/${ns}/${pod}.previous.log" 2>&1 || true
    done < <(oc get pods --all-namespaces --no-headers 2>/dev/null)

    # Describe unhealthy pods
    log "Describing unhealthy pods..."
    while IFS= read -r line; do
      ns=$(echo "${line}" | awk '{print $1}')
      pod=$(echo "${line}" | awk '{print $2}')
      mkdir -p "${bundle_dir}/pod-describe/${ns}"
      oc describe pod "${pod}" -n "${ns}" \
        > "${bundle_dir}/pod-describe/${ns}/${pod}.txt" 2>&1 || true
    done < <(oc get pods --all-namespaces --no-headers 2>/dev/null \
             | awk '$4 != "Running" && $4 != "Completed" {print $1, $2}')

    # AI Platform specific resources
    oc describe aiplatform --all -n "${AI_NS:-ai-platform}" > "${bundle_dir}/aiplatform-cr.txt" 2>&1 || true
    oc describe aiservice  --all -n "${AI_NS:-ai-platform}" > "${bundle_dir}/aiservice-cr.txt"  2>&1 || true
    oc describe raycluster --all-namespaces                  > "${bundle_dir}/raycluster-cr.txt" 2>&1 || true
    oc describe rayservice --all-namespaces                  > "${bundle_dir}/rayservice-cr.txt" 2>&1 || true

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
    sed 's/\(rootUser\|rootPassword\|hf-token\|hf-username\|AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY\|accessKey\|secretKey\|password\):.*/\1: <REDACTED>/g' \
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
  mkdir -p "${LOG_DIR}"
  tar -czf "${bundle_tar}" -C "$(dirname "${bundle_dir}")" "$(basename "${bundle_dir}")" 2>/dev/null
  rm -rf "${bundle_dir}"

  echo -e "\n\033[1;34m╔══════════════════════════════════════════════════════════╗\033[0m" >&2
  echo -e "\033[1;34m║             SUPPORT BUNDLE READY                         ║\033[0m" >&2
  echo -e "\033[1;34m╚══════════════════════════════════════════════════════════╝\033[0m" >&2
  log "  Bundle: ${bundle_tar}"
  log "  Attach this file to your support ticket or share with the team."
}

# ====== USAGE ======
usage() {
  cat <<EOF
Usage: $(basename "$0") [install|delete|diagnose|stage-artifacts|verify] [options]

  install [--silent|-s]
                Deploy the Splunk AI Platform stack onto an existing OpenShift cluster.
                  --silent / -s  Non-interactive: skip all prompts (equivalent to SILENT_INSTALL=true).
  delete        Remove the Splunk AI Platform stack (leaves the cluster intact).
  diagnose      Collect a support bundle (logs, cluster state, config) into a tar.gz.
  stage-artifacts
                Download model weights from HuggingFace and upload to the object store.
  verify        Check that all pods are healthy and the platform is operational.

Config file: ${CONFIG_FILE}
  Override with: CONFIG_FILE=/path/to/config.yaml $(basename "$0")

Environment:
  AUTO_APPROVE=true      Skip confirmation prompts (for CI/CD use)
  SILENT_INSTALL=true    Non-interactive mode: no prompts, 5-second countdown before install.
                         Equivalent to --silent on the install subcommand.
  AUTO_DIAGNOSE=false    Suppress automatic support-bundle collection on verify/install failure.
  SKIP_IF_STAGED=0       Force re-download/re-upload even if models are already staged.

Prerequisites:
  - Logged in to OpenShift: oc login <cluster-url>
  - oc, yq, helm in PATH
  - artifacts.yaml (operator manifests) in the same directory, or set files.aiPlatform in config
EOF
}

# ====== VERIFY ALL PODS HEALTHY ======
verify_all_pods_healthy() {
  load_config 2>/dev/null || true
  log "Verifying all pods are healthy in namespace ${AI_NS:-ai-platform}..."
  local unhealthy
  unhealthy=$(oc get pods --all-namespaces --no-headers 2>/dev/null \
    | awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {print $1, $2, $4}')
  if [[ -z "${unhealthy}" ]]; then
    log "✓ All pods are healthy"
    return 0
  fi
  warn "Unhealthy pods detected:"
  echo "${unhealthy}" | while read -r ns pod status; do
    warn "  ${ns}/${pod} — ${status}"
  done
  return 1
}

# ====== MAIN ======
_CMD="${1:-install}"
shift 2>/dev/null || true
case "${_CMD}" in
  install)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --silent|-s) SILENT_INSTALL=true; shift ;;
        *) echo "Unknown install option: $1" >&2; usage >&2; exit 1 ;;
      esac
    done
    main_install
    ;;
  delete)
    main_delete
    ;;
  diagnose)
    diagnose
    ;;
  stage-artifacts)
    load_config
    # Running this subcommand IS an explicit request to stage, so force staging on
    # regardless of storage.modelStaging.enabled (which only gates install-time staging).
    # The airgap guard inside stage_model_artifacts still applies.
    MODEL_STAGING_ENABLED="true"
    resolve_accelerator_type
    stage_model_artifacts
    ;;
  verify)
    _vpc_rc=0
    verify_all_pods_healthy || _vpc_rc=$?
    if (( _vpc_rc != 0 )) && [[ "${AUTO_DIAGNOSE:-true}" != "false" ]]; then
      log "Auto-collecting support bundle (set AUTO_DIAGNOSE=false to suppress)..."
      diagnose || true
    fi
    exit "${_vpc_rc}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
