#!/bin/bash
set -Eeuo pipefail

# =============================================================================
# k0s Weaviate-Service Stack Script
# =============================================================================
# Installs and deletes the Kubernetes resources required for the
# `weaviate-service` feature on an existing k0s cluster.
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/k0s-cluster-config.yaml}"

log()  { echo -e "\033[1;36m[INFO]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "Missing $1 in PATH"; }

on_error() {
  local exit_code="$1"
  local line_no="$2"
  local cmd="$3"
  echo -e "\033[1;31m[ERROR]\033[0m Command failed with exit code ${exit_code} at line ${line_no}: ${cmd}" >&2
}
trap 'on_error $? ${LINENO} "${BASH_COMMAND}"' ERR

is_nonempty_value() {
  local v="${1:-}"
  [[ -n "$v" && "$v" != "null" ]]
}

sed_in_place() {
  local expr="$1"
  local file="$2"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$expr" "$file"
  else
    sed -i "$expr" "$file"
  fi
}

build_image_url() {
  local registry="$1"
  local image_path="$2"

  if [[ "$image_path" =~ ^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/.*:.+ ]]; then
    echo "$image_path"
    return 0
  fi
  if is_nonempty_value "$registry"; then
    echo "${registry}/${image_path}"
  else
    echo "$image_path"
  fi
}

render_feature_env_block_from_config() {
  local feature_env_yaml=""

  printf '      env:\n'
  printf '        ENABLE_INTERACTIVE_TOKEN_AUTH: "true"\n'

  feature_env_yaml="$(yq eval '(.aiPlatform.features[0].env // {}) | del(.ENABLE_INTERACTIVE_TOKEN_AUTH) | del(.RAY_REQUIRED)' "${CONFIG_FILE}" 2>/dev/null || true)"
  if [[ -n "${feature_env_yaml}" && "${feature_env_yaml}" != "null" && "${feature_env_yaml}" != "{}" ]]; then
    printf '%s\n' "${feature_env_yaml}" | sed 's/^/        /'
  fi
}

wait_rollout() {
  local ns="$1"
  local kind="$2"
  local name="$3"
  local timeout="${4:-300}"

  log "Waiting for ${kind}/${name} rollout in ${ns} (timeout: ${timeout}s)..."
  if ! kubectl rollout status "${kind}/${name}" -n "${ns}" --timeout="${timeout}s"; then
    kubectl get "${kind}" "${name}" -n "${ns}" -o wide || true
    err "Timed out waiting for ${kind}/${name} rollout in ${ns}"
  fi
}

wait_for_crd() {
  local crd_name="$1"
  local timeout="${2:-300}"
  local elapsed=0

  log "Waiting for CRD ${crd_name} (timeout: ${timeout}s)..."
  while ! kubectl get crd "${crd_name}" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      err "Timeout waiting for CRD ${crd_name}"
    fi
  done
  log "CRD ${crd_name} is ready"
}

wait_for_pods_ready() {
  local ns="$1"
  local selector="$2"
  local timeout="${3:-300}"
  local description="${4:-pods matching ${selector}}"
  local elapsed=0
  local interval=5

  log "Waiting for ${description} in ${ns} (timeout: ${timeout}s)..."
  while (( elapsed < timeout )); do
    if kubectl get pods -n "${ns}" -l "${selector}" --no-headers 2>/dev/null | grep -q .; then
      if kubectl wait --for=condition=ready pod -l "${selector}" -n "${ns}" --timeout="${interval}s" >/dev/null 2>&1; then
        log "Ready: ${description} in ${ns}"
        return 0
      fi
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  kubectl get pods -n "${ns}" -l "${selector}" -o wide || true
  err "$(date '+%Y-%m-%d %H:%M:%S %Z') Timed out waiting for ${description} in ${ns} after ${timeout}s"
}

wait_for_splunk_standalone_ready() {
  local ns="$1"
  local name="$2"
  local timeout="${3:-600}"
  local elapsed=0
  local interval=5

  log "Waiting for Splunk Standalone ${name} in ${ns} (timeout: ${timeout}s)..."
  while (( elapsed < timeout )); do
    if kubectl get standalone "${name}" -n "${ns}" >/dev/null 2>&1; then
      local desired ready phase
      desired="$(kubectl get standalone "${name}" -n "${ns}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
      ready="$(kubectl get standalone "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
      phase="$(kubectl get standalone "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"

      if [[ -n "${desired}" && "${ready:-0}" == "${desired}" && "${phase}" == "Ready" ]]; then
        log "Ready: Splunk Standalone ${name} in ${ns}"
        return 0
      fi
    fi

    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  kubectl get standalone "${name}" -n "${ns}" -o yaml | sed -n '1,220p' || true
  local selector
  selector="$(kubectl get standalone "${name}" -n "${ns}" -o jsonpath='{.status.selector}' 2>/dev/null || true)"
  if [[ -n "${selector}" ]]; then
    kubectl get pods -n "${ns}" -l "${selector}" -o wide || true
  else
    kubectl get pods -n "${ns}" -o wide || true
  fi
  err "$(date '+%Y-%m-%d %H:%M:%S %Z') Timed out waiting for Splunk Standalone ${name} in ${ns} after ${timeout}s"
}

wait_for_resource_deletion() {
  local kind="$1"
  local name="$2"
  local ns="$3"
  local timeout="${4:-180}"
  local elapsed=0

  log "Waiting for ${kind}/${name} deletion in ${ns} (timeout: ${timeout}s)..."
  while kubectl get "${kind}" "${name}" -n "${ns}" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      warn "${kind}/${name} is still present in ${ns}"
      kubectl get "${kind}" "${name}" -n "${ns}" -o jsonpath='{.metadata.deletionTimestamp}{" finalizers="}{.metadata.finalizers}{"\n"}' 2>/dev/null || true
      err "Timed out waiting for ${kind}/${name} deletion in ${ns}"
    fi
  done
  log "${kind}/${name} deleted from ${ns}"
}

delete_named_resource() {
  local kind="$1"
  local name="$2"
  local ns="$3"
  local timeout="${4:-180}"

  if ! kubectl get "${kind}" "${name}" -n "${ns}" >/dev/null 2>&1; then
    log "${kind}/${name} not found in ${ns}, skipping delete"
    return 0
  fi

  log "Deleting ${kind}/${name} in ${ns}..."
  kubectl delete "${kind}" "${name}" -n "${ns}" --ignore-not-found=true --wait=false >/dev/null
  wait_for_resource_deletion "${kind}" "${name}" "${ns}" "${timeout}"
}

report_namespace_blockers() {
  local ns="$1"

  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    return 0
  fi

  warn "Namespace ${ns} is still present. Current phase and finalizers:"
  kubectl get namespace "${ns}" -o jsonpath='{.status.phase}{" finalizers="}{.spec.finalizers}{"\n"}' 2>/dev/null || true
  warn "Remaining common resources in ${ns}:"
  kubectl get all,cm,secret,pvc,sa,role,rolebinding -n "${ns}" 2>/dev/null || true
}

wait_for_namespace_deletion() {
  local ns="$1"
  local timeout="${2:-180}"
  local elapsed=0

  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "Namespace ${ns} is already absent"
    return 0
  fi

  log "Waiting for namespace ${ns} deletion (timeout: ${timeout}s)..."
  while kubectl get namespace "${ns}" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      report_namespace_blockers "${ns}"
      err "Timed out waiting for namespace ${ns} deletion"
    fi
  done
  log "Namespace ${ns} deleted"
}

ensure_namespace() {
  local ns="$1"
  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "Creating namespace ${ns}..."
    kubectl create namespace "${ns}"
  fi
}

ssh_exec() {
  local host="$1"
  shift
  local cmd="$*"

  if [[ -n "${SSH_KEY_PATH:-}" ]]; then
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY_PATH}" "${SSH_USER}@${host}" "${cmd}"
  else
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${host}" "${cmd}"
  fi
}

load_config() {
  log "Loading configuration from: ${CONFIG_FILE}"
  [[ -f "${CONFIG_FILE}" ]] || err "Config file not found: ${CONFIG_FILE}"
  need yq

  local config_dir
  config_dir="$(cd -- "$(dirname -- "${CONFIG_FILE}")" && pwd)"

  CLUSTER_NAME="$(yq eval '.cluster.name // ""' "${CONFIG_FILE}")"
  SSH_USER="$(yq eval '.cluster.sshUser // "ubuntu"' "${CONFIG_FILE}")"
  SSH_KEY_PATH="$(yq eval '.cluster.sshKeyPath // ""' "${CONFIG_FILE}")"
  EXISTING_CONTROLLER_IPS="$(yq eval '.nodes.existingIPs.controllers[]?' "${CONFIG_FILE}" 2>/dev/null | tr '\n' ' ' | xargs 2>/dev/null || true)"

  STORAGE_CLASS="$(yq eval '.storage.storageClass // "local-path"' "${CONFIG_FILE}")"
  VECTORDB_SIZE="$(yq eval '.storage.vectorDbSize // "50Gi"' "${CONFIG_FILE}")"

  AI_NS="$(yq eval '.kubernetes.namespace // "ai-platform"' "${CONFIG_FILE}")"
  AI_PLATFORM_NAME="$(yq eval '.aiPlatform.name // ""' "${CONFIG_FILE}")"
  AI_FEATURE_NAME="$(yq eval '.aiPlatform.features[0].name // ""' "${CONFIG_FILE}")"
  AI_FEATURE_VERSION="$(yq eval '.aiPlatform.features[0].version // "1.0.0"' "${CONFIG_FILE}")"
  AI_FEATURE_SA="$(yq eval '.aiPlatform.features[0].serviceAccountName // .aiPlatform.features[0].serviceAccount // ""' "${CONFIG_FILE}")"

  AI_STANDALONE_NAME="$(yq eval '.splunk.standaloneName // "splunk-standalone"' "${CONFIG_FILE}")"
  SPLUNK_SERVICE_NAME="splunk-${AI_STANDALONE_NAME}-standalone-service"

  IMAGE_REGISTRY="$(yq eval '.images.registry // ""' "${CONFIG_FILE}")"
  OPERATOR_IMAGE="$(yq eval '.images.operator.image // ""' "${CONFIG_FILE}")"
  SPLUNK_IMAGE="$(yq eval '.images.splunk.image // ""' "${CONFIG_FILE}")"
  SPLUNK_OPERATOR_IMAGE="$(yq eval '.images.splunk.operatorImage // ""' "${CONFIG_FILE}")"
  WEAVIATE_IMAGE="$(yq eval '.images.weaviate.image // ""' "${CONFIG_FILE}")"
  WEAVIATE_PROXY_IMAGE="$(yq eval '.images.weaviate.proxyImage // ""' "${CONFIG_FILE}")"

  ECR_ACCOUNT="$(yq eval '.ecr.account // ""' "${CONFIG_FILE}")"
  ECR_REGION="$(yq eval '.ecr.region // ""' "${CONFIG_FILE}")"
  REGION="$(yq eval '.cluster.region // ""' "${CONFIG_FILE}")"

  IMAGE_PULL_SECRETS_ECR_ENABLED="$(yq eval '.imagePullSecrets.autoCreateECR // "false"' "${CONFIG_FILE}")"
  IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED="$(yq eval '.imagePullSecrets.dockerHub.enabled // "false"' "${CONFIG_FILE}")"
  IMAGE_PULL_SECRETS_GCR_ENABLED="$(yq eval '.imagePullSecrets.gcr.enabled // "false"' "${CONFIG_FILE}")"
  IMAGE_PULL_SECRETS_ACR_ENABLED="$(yq eval '.imagePullSecrets.acr.enabled // "false"' "${CONFIG_FILE}")"
  IMAGE_PULL_SECRETS_CUSTOM_ENABLED="$(yq eval '.imagePullSecrets.custom.enabled // "false"' "${CONFIG_FILE}")"

  SPLUNK_OPERATOR_FILE="$(yq eval '.files.splunkOperator // "./splunk-operator-cluster.yaml"' "${CONFIG_FILE}")"
  SPLUNK_AI_FILE="$(yq eval '.files.aiPlatform // "./artifacts.yaml"' "${CONFIG_FILE}")"

  if [[ -z "${AI_PLATFORM_NAME}" || "${AI_PLATFORM_NAME}" == "null" ]]; then
    AI_PLATFORM_NAME="${CLUSTER_NAME}-ai-platform"
  fi

  AI_FEATURE_NAME="$(echo "${AI_FEATURE_NAME}" | tr '[:upper:]' '[:lower:]')"
  [[ "${AI_FEATURE_NAME}" == "weaviate-service" ]] || \
    err "This script only supports aiPlatform.features[0].name=weaviate-service"

  log "Configuration loaded: cluster=${CLUSTER_NAME}, namespace=${AI_NS}, feature=${AI_FEATURE_NAME}@${AI_FEATURE_VERSION}"
}

validate_image_config() {
  log "Validating image configuration..."

  is_nonempty_value "${OPERATOR_IMAGE}" || err "REQUIRED: images.operator.image"
  is_nonempty_value "${SPLUNK_IMAGE}" || err "REQUIRED: images.splunk.image"
  is_nonempty_value "${WEAVIATE_IMAGE}" || err "REQUIRED: images.weaviate.image"
  is_nonempty_value "${AI_FEATURE_SA}" || err "REQUIRED: aiPlatform.features[0].serviceAccountName"

  if ! is_nonempty_value "${WEAVIATE_PROXY_IMAGE}"; then
    WEAVIATE_PROXY_IMAGE="docker.io/kbhos698/weaviate-service:v1.0.1"
    log "Using default Weaviate proxy image: ${WEAVIATE_PROXY_IMAGE}"
  fi
  if ! is_nonempty_value "${SPLUNK_OPERATOR_IMAGE}"; then
    SPLUNK_OPERATOR_IMAGE="docker.io/splunk/splunk-operator:3.0.0"
    log "Using default Splunk Operator image: ${SPLUNK_OPERATOR_IMAGE}"
  fi

  log "Image configuration validated successfully"
}

configure_images() {
  log "Configuring manifest images..."

  [[ -f "${SPLUNK_AI_FILE}" ]] || err "Splunk AI Operator manifest not found: ${SPLUNK_AI_FILE}"
  [[ -f "${SPLUNK_OPERATOR_FILE}" ]] || err "Splunk operator manifest not found: ${SPLUNK_OPERATOR_FILE}"

  if [[ ! -f "${SPLUNK_AI_FILE}.original" ]]; then
    cp "${SPLUNK_AI_FILE}" "${SPLUNK_AI_FILE}.original"
  fi
  if [[ ! -f "${SPLUNK_OPERATOR_FILE}.original" ]]; then
    cp "${SPLUNK_OPERATOR_FILE}" "${SPLUNK_OPERATOR_FILE}.original"
  fi

  cp "${SPLUNK_AI_FILE}.original" "${SPLUNK_AI_FILE}"
  cp "${SPLUNK_OPERATOR_FILE}.original" "${SPLUNK_OPERATOR_FILE}"

  local operator_full splunk_full splunk_operator_full
  local weaviate_full weaviate_proxy_full
  local operator_escaped splunk_escaped splunk_operator_escaped
  local weaviate_escaped weaviate_proxy_escaped

  operator_full="$(build_image_url "${IMAGE_REGISTRY}" "${OPERATOR_IMAGE}")"
  splunk_full="$(build_image_url "${IMAGE_REGISTRY}" "${SPLUNK_IMAGE}")"
  splunk_operator_full="$(build_image_url "${IMAGE_REGISTRY}" "${SPLUNK_OPERATOR_IMAGE}")"
  weaviate_full="$(build_image_url "${IMAGE_REGISTRY}" "${WEAVIATE_IMAGE}")"
  weaviate_proxy_full="$(build_image_url "${IMAGE_REGISTRY}" "${WEAVIATE_PROXY_IMAGE}")"

  operator_escaped="$(echo "${operator_full}" | sed 's/[\/&]/\\&/g')"
  splunk_escaped="$(echo "${splunk_full}" | sed 's/[\/&]/\\&/g')"
  splunk_operator_escaped="$(echo "${splunk_operator_full}" | sed 's/[\/&]/\\&/g')"
  weaviate_escaped="$(echo "${weaviate_full}" | sed 's/[\/&]/\\&/g')"
  weaviate_proxy_escaped="$(echo "${weaviate_proxy_full}" | sed 's/[\/&]/\\&/g')"

  sed_in_place "/name: RELATED_IMAGE_WEAVIATE/,/value:/ s|value:.*|value: ${weaviate_escaped}|" "${SPLUNK_AI_FILE}"
  sed_in_place "/name:[[:space:]]*RELATED_IMAGE_WEAVIATE_SERVICE$/,/value:/ s|value:.*|value: ${weaviate_proxy_escaped}|" "${SPLUNK_AI_FILE}"
  sed_in_place "s|image: .*splunk.*ai.*operator.*|image: ${operator_escaped}|I" "${SPLUNK_AI_FILE}"

  sed_in_place "/name: RELATED_IMAGE_SPLUNK_ENTERPRISE/,/value:/ s|value:.*|value: ${splunk_escaped}|" "${SPLUNK_OPERATOR_FILE}"
  sed_in_place "s|image: .*splunk.*operator.*|image: ${splunk_operator_escaped}|I" "${SPLUNK_OPERATOR_FILE}"

  log "  Updated operator image: ${operator_full}"
  log "  Updated Splunk Enterprise image: ${splunk_full}"
  log "  Updated Splunk Operator image: ${splunk_operator_full}"
  log "  Updated Weaviate image: ${weaviate_full}"
  log "  Updated Weaviate proxy image: ${weaviate_proxy_full}"
}

preflight_checks() {
  need kubectl
  need yq

  [[ -f "${SPLUNK_OPERATOR_FILE}" ]] || err "Splunk operator manifest not found: ${SPLUNK_OPERATOR_FILE}"
  [[ -f "${SPLUNK_AI_FILE}" ]] || err "Splunk AI Operator manifest not found: ${SPLUNK_AI_FILE}"

  if [[ "${IMAGE_PULL_SECRETS_ECR_ENABLED}" == "true" ]]; then
    need aws
  fi

  if [[ -n "${KUBECONFIG:-}" ]]; then
    log "Using KUBECONFIG=${KUBECONFIG}"
  elif [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    need ssh
    [[ -n "${SSH_KEY_PATH}" && -f "${SSH_KEY_PATH}" ]] || err "SSH key not found: ${SSH_KEY_PATH}"
    log "Will retrieve kubeconfig from controller ${EXISTING_CONTROLLER_IPS%% *}"
  elif [[ -f "${HOME}/.kube/k0s-${CLUSTER_NAME}" ]]; then
    log "Will use kubeconfig ${HOME}/.kube/k0s-${CLUSTER_NAME}"
  else
    err "Set KUBECONFIG or configure nodes.existingIPs.controllers + cluster.sshKeyPath"
  fi
}

activate_cluster() {
  if [[ -n "${KUBECONFIG:-}" ]] && kubectl cluster-info >/dev/null 2>&1; then
    log "Using current cluster from KUBECONFIG"
  elif [[ -f "${HOME}/.kube/k0s-${CLUSTER_NAME}" ]]; then
    export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"
    kubectl cluster-info >/dev/null 2>&1 || err "Cached kubeconfig exists but cluster is not reachable: ${KUBECONFIG}"
    log "Using cached kubeconfig ${KUBECONFIG}"
  elif [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    local controller_ip="${EXISTING_CONTROLLER_IPS%% *}"
    mkdir -p "${HOME}/.kube"
    ssh_exec "${controller_ip}" "sudo cat /var/lib/k0s/pki/admin.conf" > "${HOME}/.kube/k0s-${CLUSTER_NAME}"
    sed_in_place "s|server: .*|server: https://${controller_ip}:6443|" "${HOME}/.kube/k0s-${CLUSTER_NAME}"
    export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"
    kubectl cluster-info >/dev/null 2>&1 || err "Failed to activate kubeconfig from controller ${controller_ip}"
    log "Retrieved kubeconfig from controller ${controller_ip}"
  else
    err "No reachable cluster found"
  fi

  log "Connected to cluster:"
  kubectl get nodes -o wide
}

ensure_cpu_node_labels() {
  local cpu_nodes
  cpu_nodes="$(kubectl get nodes -l splunk.ai/workload-type=cpu --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${cpu_nodes}" -gt 0 ]]; then
    log "CPU workload labels already present on ${cpu_nodes} node(s)"
    return 0
  fi

  log "Applying default cpu workload label to cluster nodes..."
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read -r node; do
    [[ -n "${node}" ]] || continue
    kubectl label node "${node}" splunk.ai/workload-type=cpu --overwrite >/dev/null
    log "  Labeled ${node} with splunk.ai/workload-type=cpu"
  done
}


install_cert_manager() {
  log "Installing cert-manager..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

  wait_for_crd certificates.cert-manager.io 300
  wait_for_pods_ready cert-manager "app.kubernetes.io/instance=cert-manager" 300 "cert-manager pods"
  wait_for_pods_ready cert-manager "app.kubernetes.io/component=webhook" 120 "cert-manager webhook pods"
  wait_for_cert_manager_webhook 30 10 || err "cert-manager webhook did not become responsive"
}

wait_for_cert_manager_webhook() {
  local max_attempts="${1:-30}"
  local sleep_interval="${2:-10}"
  local attempt=0

  kubectl get namespace cert-manager >/dev/null 2>&1 || return 0

  while (( attempt < max_attempts )); do
    if kubectl apply -f - <<'EOF' >/dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: cert-manager-webhook-test
  namespace: cert-manager
spec:
  selfSigned: {}
EOF
    then
      kubectl delete issuer cert-manager-webhook-test -n cert-manager --ignore-not-found=true >/dev/null 2>&1 || true
      log "cert-manager webhook is responsive"
      return 0
    fi
    sleep "${sleep_interval}"
    attempt=$((attempt + 1))
  done

  warn "cert-manager webhook did not become responsive after ${max_attempts} attempts"
  return 1
}

create_image_pull_secrets() {
  local ns="$1"
  local secrets_created=()

  ensure_namespace "${ns}"
  log "Creating image pull secrets in ${ns}..."

  if [[ "${IMAGE_PULL_SECRETS_ECR_ENABLED}" == "true" ]]; then
    local ecr_region="${ECR_REGION:-${REGION:-us-east-2}}"
    local ecr_account="${ECR_ACCOUNT:-}"
    if aws sts get-caller-identity >/dev/null 2>&1; then
      if [[ -z "${ecr_account}" ]]; then
        ecr_account="$(aws sts get-caller-identity --query Account --output text)"
      fi
      local ecr_password
      ecr_password="$(aws ecr get-login-password --region "${ecr_region}")"
      kubectl create secret docker-registry ecr-registry-secret \
        --docker-server="${ecr_account}.dkr.ecr.${ecr_region}.amazonaws.com" \
        --docker-username=AWS \
        --docker-password="${ecr_password}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -
      secrets_created+=("ecr-registry-secret")
    else
      warn "AWS credentials unavailable; skipping ECR secret creation"
    fi
  fi

  if [[ "${IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED}" == "true" ]]; then
    local dh_username dh_password dh_email
    dh_username="$(yq eval '.imagePullSecrets.dockerHub.username // ""' "${CONFIG_FILE}")"
    dh_password="$(yq eval '.imagePullSecrets.dockerHub.password // ""' "${CONFIG_FILE}")"
    dh_email="$(yq eval '.imagePullSecrets.dockerHub.email // ""' "${CONFIG_FILE}")"
    if is_nonempty_value "${dh_username}" && is_nonempty_value "${dh_password}"; then
      local email_arg=()
      [[ -n "${dh_email}" ]] && email_arg=(--docker-email="${dh_email}")
      kubectl create secret docker-registry docker-hub-secret \
        --docker-server=docker.io \
        --docker-username="${dh_username}" \
        --docker-password="${dh_password}" \
        "${email_arg[@]}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -
      secrets_created+=("docker-hub-secret")
    fi
  fi

  if [[ "${IMAGE_PULL_SECRETS_GCR_ENABLED}" == "true" ]]; then
    local gcr_json_key
    gcr_json_key="$(yq eval '.imagePullSecrets.gcr.jsonKey // ""' "${CONFIG_FILE}")"
    if is_nonempty_value "${gcr_json_key}"; then
      kubectl create secret docker-registry gcr-secret \
        --docker-server=gcr.io \
        --docker-username=_json_key \
        --docker-password="${gcr_json_key}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -
      secrets_created+=("gcr-secret")
    fi
  fi

  if [[ "${IMAGE_PULL_SECRETS_ACR_ENABLED}" == "true" ]]; then
    local acr_registry acr_username acr_password
    acr_registry="$(yq eval '.imagePullSecrets.acr.registry // ""' "${CONFIG_FILE}")"
    acr_username="$(yq eval '.imagePullSecrets.acr.username // ""' "${CONFIG_FILE}")"
    acr_password="$(yq eval '.imagePullSecrets.acr.password // ""' "${CONFIG_FILE}")"
    if is_nonempty_value "${acr_registry}" && is_nonempty_value "${acr_username}" && is_nonempty_value "${acr_password}"; then
      kubectl create secret docker-registry acr-secret \
        --docker-server="${acr_registry}" \
        --docker-username="${acr_username}" \
        --docker-password="${acr_password}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -
      secrets_created+=("acr-secret")
    fi
  fi

  if [[ "${IMAGE_PULL_SECRETS_CUSTOM_ENABLED}" == "true" ]]; then
    local custom_name custom_server custom_username custom_password custom_email
    custom_name="$(yq eval '.imagePullSecrets.custom.name // "custom-registry-secret"' "${CONFIG_FILE}")"
    custom_server="$(yq eval '.imagePullSecrets.custom.server // ""' "${CONFIG_FILE}")"
    custom_username="$(yq eval '.imagePullSecrets.custom.username // ""' "${CONFIG_FILE}")"
    custom_password="$(yq eval '.imagePullSecrets.custom.password // ""' "${CONFIG_FILE}")"
    custom_email="$(yq eval '.imagePullSecrets.custom.email // ""' "${CONFIG_FILE}")"
    if is_nonempty_value "${custom_server}" && is_nonempty_value "${custom_username}" && is_nonempty_value "${custom_password}"; then
      local email_arg=()
      [[ -n "${custom_email}" ]] && email_arg=(--docker-email="${custom_email}")
      kubectl create secret docker-registry "${custom_name}" \
        --docker-server="${custom_server}" \
        --docker-username="${custom_username}" \
        --docker-password="${custom_password}" \
        "${email_arg[@]}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -
      secrets_created+=("${custom_name}")
    fi
  fi

  if [[ ${#secrets_created[@]} -gt 0 ]]; then
    printf '%s\n' "${secrets_created[@]}"
  fi
}

install_splunk_operator() {
  local ns="splunk-operator"
  log "Installing Splunk Operator..."

  ensure_namespace "${ns}"
  create_image_pull_secrets "${ns}" >/dev/null
  kubectl apply -f "${SPLUNK_OPERATOR_FILE}" --server-side --force-conflicts

  local secrets_patch=""
  local dep_name=""
  for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
    if kubectl get secret "${secret_name}" -n "${ns}" >/dev/null 2>&1; then
      secrets_patch+='{"name":"'"${secret_name}"'"},'
    fi
  done
  dep_name="$(kubectl -n "${ns}" get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${secrets_patch}" ]]; then
    if [[ -n "${dep_name}" ]]; then
      kubectl -n "${ns}" patch deployment "${dep_name}" \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":['"${secrets_patch%,}"']}]' \
        >/dev/null 2>&1 || true
      kubectl rollout restart deployment "${dep_name}" -n "${ns}" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "${dep_name}" ]]; then
    wait_rollout "${ns}" deploy "${dep_name}" 600
  fi

  wait_for_crd standalones.enterprise.splunk.com 300
  log "Splunk Operator installed successfully"
}

install_splunk_ai_operator() {
  local ns="splunk-ai-operator-system"
  log "Installing Splunk AI Operator from ${SPLUNK_AI_FILE}..."

  ensure_namespace "${ns}"
  create_image_pull_secrets "${ns}" >/dev/null
  wait_for_cert_manager_webhook 30 10 || err "cert-manager webhook did not become responsive"

  local apply_output=""
  local apply_status=0
  apply_output="$(kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1)" || apply_status=$?
  echo "${apply_output}"

  if (( apply_status != 0 )) && echo "${apply_output}" | grep -qi "webhook.*cert-manager\|failed calling webhook.*cert-manager\|i/o timeout"; then
    sleep 15
    wait_for_cert_manager_webhook 15 10 || err "cert-manager webhook retry did not become responsive"
    apply_status=0
    apply_output="$(kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1)" || apply_status=$?
    echo "${apply_output}"
  fi
  (( apply_status == 0 )) || err "Failed to apply Splunk AI Operator manifest"

  local dep
  dep="$(kubectl -n "${ns}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 -E 'splunk-ai-operator|ai-operator|controller-manager' || true)"
  if [[ -n "${dep}" ]]; then
    local secrets_patch=""
    for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
      if kubectl get secret "${secret_name}" -n "${ns}" >/dev/null 2>&1; then
        secrets_patch+='{"name":"'"${secret_name}"'"},'
      fi
    done
    if [[ -n "${secrets_patch}" ]]; then
      kubectl -n "${ns}" patch deployment "${dep}" \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":['"${secrets_patch%,}"']}]' \
        >/dev/null 2>&1 || true
    fi
    kubectl rollout restart deployment "${dep}" -n "${ns}" >/dev/null 2>&1 || true
    wait_rollout "${ns}" deploy "${dep}" 600
  fi

  wait_for_crd aiplatforms.ai.splunk.com 600
  wait_for_crd aiservices.ai.splunk.com 600
  log "Splunk AI Operator installed successfully"
}

install_splunk_standalone() {
  log "Installing Splunk Standalone: ${AI_STANDALONE_NAME} in ${AI_NS}..."

  ensure_namespace "${AI_NS}"
  wait_for_crd standalones.enterprise.splunk.com 600

  cat <<YAML | kubectl -n "${AI_NS}" apply -f -
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
                issuer_uri: https://${SPLUNK_SERVICE_NAME}:8089
                certFile: \$SPLUNK_HOME/etc/auth/server.pem
                sslPassword: password
YAML

  if kubectl get secret ecr-registry-secret -n "${AI_NS}" >/dev/null 2>&1; then
    kubectl patch serviceaccount default -n "${AI_NS}" \
      -p '{"imagePullSecrets":[{"name":"ecr-registry-secret"}]}' >/dev/null 2>&1 || true
  fi

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
YAML

  wait_for_splunk_standalone_ready "${AI_NS}" "${AI_STANDALONE_NAME}" 600
  log "Splunk Standalone installed successfully"
}

install_ai_platform_cr() {
  log "Creating AIPlatform custom resource..."

  kubectl delete jobs -n "${AI_NS}" --field-selector status.successful=0 --wait=false >/dev/null 2>&1 || true
  kubectl delete pods -n "${AI_NS}" --field-selector status.phase=Failed --wait=false >/dev/null 2>&1 || true

  local splunk_secret="splunk-${AI_STANDALONE_NAME}-standalone-secret-v1"
  local feature_env_block image_pull_secrets
  local secrets_yaml=""

  for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
    if kubectl get secret "${secret_name}" -n "${AI_NS}" >/dev/null 2>&1; then
      secrets_yaml+="      - name: ${secret_name}"$'\n'
    fi
  done
  if [[ -n "${secrets_yaml}" ]]; then
    image_pull_secrets=$(cat <<EOF
    imagePullSecrets:
${secrets_yaml}
EOF
)
  else
    image_pull_secrets=""
  fi

  feature_env_block="$(render_feature_env_block_from_config)"


  cat <<YAML | kubectl -n "${AI_NS}" apply --server-side --force-conflicts -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${AI_PLATFORM_NAME}
spec:
  images:
${image_pull_secrets}
  serviceAccountName: ${AI_FEATURE_SA}

  sidecars:
    envoy: false
    otel: false
    prometheusOperator: false

  features:
    - name: ${AI_FEATURE_NAME}
      version: "${AI_FEATURE_VERSION}"
      serviceAccountName: ${AI_FEATURE_SA}
${feature_env_block}

  storage:
    vectorDB:
      size: ${VECTORDB_SIZE}
      storageClassName: ${STORAGE_CLASS}

  cpuScheduler:
    nodeSelector:
      splunk.ai/workload-type: cpu
    tolerations: []

  splunkConfiguration:
    endpoint: http://${SPLUNK_SERVICE_NAME}.${AI_NS}.svc.cluster.local:8089
    secretRef:
      name: ${splunk_secret}
      namespace: ${AI_NS}
YAML

  kubectl get aiplatform "${AI_PLATFORM_NAME}" -n "${AI_NS}" >/dev/null 2>&1 || \
    err "AIPlatform resource was not created"
  log "AIPlatform custom resource applied"
}

install_ai_platform_stack() {
  ensure_namespace "${AI_NS}"
  ensure_cpu_node_labels

  install_cert_manager
  install_splunk_operator
  create_image_pull_secrets "${AI_NS}" >/dev/null
  install_splunk_standalone
  install_splunk_ai_operator
  install_ai_platform_cr
}

check_platform_health() {
  log "Running weaviate-service stack health checks..."
  kubectl get nodes -o wide || true
  kubectl get pods -n "${AI_NS}" || true
  kubectl get aiplatform -n "${AI_NS}" || true
  kubectl get aiservice -n "${AI_NS}" || true
  kubectl get pods -n splunk-operator || true
  kubectl get pods -n splunk-ai-operator-system || true
}

show_platform_access_info() {
  local proxy_service="${AI_PLATFORM_NAME}-weaviate-service-weaviate-service"

  log "Installation complete"
  log "Namespace: ${AI_NS}"
  log "AIPlatform: ${AI_PLATFORM_NAME}"
  log "Splunk service: ${SPLUNK_SERVICE_NAME}"
  log "Weaviate proxy service: ${proxy_service}"
  log ""
  log "Useful checks:"
  log "  kubectl get pods -n ${AI_NS}"
  log "  kubectl get aiplatform,aiservice -n ${AI_NS}"
  log "  kubectl get svc -n ${AI_NS}"
  log ""
  log "Splunk web:"
  log "  kubectl port-forward -n ${AI_NS} svc/${SPLUNK_SERVICE_NAME} 8000:8000"
  log ""
  log "Weaviate proxy:"
  log "  kubectl port-forward -n ${AI_NS} svc/${proxy_service} 8080:80"
}

main_install() {
  load_config
  validate_image_config
  configure_images
  preflight_checks
  activate_cluster
  install_ai_platform_stack
  check_platform_health
  show_platform_access_info
}

main_delete() {
  load_config
  preflight_checks
  activate_cluster

  if [[ "${AUTO_APPROVE:-false}" != "true" ]]; then
    warn "This will remove the weaviate-service stack resources from the current cluster."
    read -r -p "Type 'yes' to confirm deletion: " reply
    [[ "${reply}" == "yes" ]] || err "Deletion cancelled"
  fi

  log "Deleting AIPlatform and Splunk resources..."
  delete_named_resource aiplatform "${AI_PLATFORM_NAME}" "${AI_NS}" 180
  delete_named_resource standalone "${AI_STANDALONE_NAME}" "${AI_NS}" 180

  if [[ -f "${SPLUNK_AI_FILE}" ]]; then
    kubectl delete -f "${SPLUNK_AI_FILE}" --ignore-not-found=true >/dev/null 2>&1 || true
  fi
  if [[ -f "${SPLUNK_OPERATOR_FILE}" ]]; then
    kubectl delete -f "${SPLUNK_OPERATOR_FILE}" --ignore-not-found=true >/dev/null 2>&1 || true
  fi

  kubectl delete namespace "${AI_NS}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace splunk-ai-operator-system --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace splunk-operator --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  wait_for_namespace_deletion "${AI_NS}" 300
  wait_for_namespace_deletion splunk-ai-operator-system 300
  wait_for_namespace_deletion splunk-operator 300
  log "Weaviate-service stack cleanup complete"
}

usage() {
  cat <<EOF
Usage: $0 [install|delete]

Deploys the weaviate-service stack on an existing k0s cluster.

Commands:
  install  - Install the weaviate-service stack
  delete   - Delete the weaviate-service stack

Environment:
  CONFIG_FILE   - Path to config YAML (default: ./k0s-cluster-config.yaml)
  KUBECONFIG    - Existing kubeconfig to use
  AUTO_APPROVE  - Skip delete confirmation prompt

Notes:
  - This script only supports aiPlatform.features[0].name=weaviate-service
  - It assumes a k0s cluster already exists
  - If KUBECONFIG is not set, it can fetch admin.conf from nodes.existingIPs.controllers[0]
  - install manages only the resources needed for the weaviate-service stack
EOF
}

case "${1:-install}" in
  install)
    main_install
    ;;
  delete)
    main_delete
    ;;
  *)
    usage
    exit 1
    ;;
esac
