#!/bin/bash
set -euo pipefail

# =============================================================================
# EKS Weaviate-Service Stack Script
# =============================================================================
# Installs and deletes the Kubernetes resources required for the
# `weaviate-service` feature on an existing EKS cluster.
# =============================================================================

export AWS_PAGER=""
export AWS_DEFAULT_OUTPUT=json

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/cluster-config.yaml}"

log()  { echo -e "\033[1;36m[INFO]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "Missing $1 in PATH"; }
need_file() { [[ -f "$1" ]] || err "Missing file: $1"; }

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

resolve_path() {
  local path="$1"
  local base_dir="$2"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "${base_dir}/${path}"
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
  kubectl rollout status "${kind}/${name}" -n "${ns}" --timeout="${timeout}s" || \
    warn "Timeout waiting for ${kind}/${name} rollout in ${ns}"
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

ensure_namespace() {
  local ns="$1"
  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "Creating namespace ${ns}..."
    kubectl create namespace "${ns}"
  fi
}

load_config() {
  log "Loading configuration from: ${CONFIG_FILE}"
  [[ -f "${CONFIG_FILE}" ]] || err "Config file not found: ${CONFIG_FILE}"
  need yq

  local config_dir
  config_dir="$(cd -- "$(dirname -- "${CONFIG_FILE}")" && pwd)"

  CLUSTER_NAME="$(yq eval '.cluster.name // ""' "${CONFIG_FILE}")"
  REGION="$(yq eval '.cluster.region // ""' "${CONFIG_FILE}")"

  STORAGE_CLASS="$(yq eval '.storage.storageClass // "gp3"' "${CONFIG_FILE}")"
  VECTORDB_SIZE="$(yq eval '.storage.vectorDbSize // "50Gi"' "${CONFIG_FILE}")"
  S3_BUCKET="$(yq eval '.storage.s3Bucket // ""' "${CONFIG_FILE}")"

  AI_NS="$(yq eval '.aiPlatform.namespace // "ai-platform"' "${CONFIG_FILE}")"
  AI_PLATFORM_NAME="$(yq eval '.aiPlatform.name // ""' "${CONFIG_FILE}")"
  AI_FEATURE_NAME="$(yq eval '.aiPlatform.features[0].name // ""' "${CONFIG_FILE}")"
  AI_FEATURE_VERSION="$(yq eval '.aiPlatform.features[0].version // "1.0.0"' "${CONFIG_FILE}")"
  AI_FEATURE_SA="$(yq eval '.aiPlatform.features[0].serviceAccountName // .aiPlatform.features[0].serviceAccount // ""' "${CONFIG_FILE}")"

  AI_STANDALONE_NAME="$(yq eval '.splunkStandalone.name // "splunk-standalone"' "${CONFIG_FILE}")"
  SPLUNK_APP_LOCAL_PATH="$(yq eval '.splunkStandalone.localAppPath // ""' "${CONFIG_FILE}")"
  SPLUNK_SERVICE_NAME="splunk-${AI_STANDALONE_NAME}-standalone-service"

  IMAGE_REGISTRY="$(yq eval '.images.registry // ""' "${CONFIG_FILE}")"
  OPERATOR_IMAGE="$(yq eval '.images.operator.image // ""' "${CONFIG_FILE}")"
  SPLUNK_IMAGE="$(yq eval '.images.splunk.image // ""' "${CONFIG_FILE}")"
  SPLUNK_OPERATOR_IMAGE="$(yq eval '.images.splunk.operatorImage // ""' "${CONFIG_FILE}")"
  WEAVIATE_IMAGE="$(yq eval '.images.weaviate.image // ""' "${CONFIG_FILE}")"
  WEAVIATE_PROXY_IMAGE="$(yq eval '.images.weaviate.proxyImage // ""' "${CONFIG_FILE}")"

  SPLUNK_OPERATOR_FILE="$(resolve_path "$(yq eval '.files.splunkOperatorManifest // "splunk-operator-cluster.yaml"' "${CONFIG_FILE}")" "${config_dir}")"
  SPLUNK_AI_FILE="$(resolve_path "$(yq eval '.files.splunkAiOperatorManifest // "artifacts.yaml"' "${CONFIG_FILE}")" "${config_dir}")"

  if [[ -z "${AI_PLATFORM_NAME}" || "${AI_PLATFORM_NAME}" == "null" ]]; then
    AI_PLATFORM_NAME="${CLUSTER_NAME}-ai-platform"
  fi

  AI_FEATURE_NAME="$(echo "${AI_FEATURE_NAME}" | tr '[:upper:]' '[:lower:]')"
  [[ "${AI_FEATURE_NAME}" == "weaviate-service" ]] || \
    err "This script only supports aiPlatform.features[0].name=weaviate-service"

  S3_PREFIXES=("artifacts/" "apps/" "tasks/")
  SPLUNK_AI_NS="splunk-ai-operator-system"

  log "Configuration loaded: cluster=${CLUSTER_NAME}, region=${REGION}, namespace=${AI_NS}, feature=${AI_FEATURE_NAME}@${AI_FEATURE_VERSION}"
}

validate_image_config() {
  log "Validating image configuration..."

  is_nonempty_value "${CLUSTER_NAME}" || err "REQUIRED: cluster.name"
  is_nonempty_value "${REGION}" || err "REQUIRED: cluster.region"
  is_nonempty_value "${S3_BUCKET}" || err "REQUIRED: storage.s3Bucket"
  is_nonempty_value "${OPERATOR_IMAGE}" || err "REQUIRED: images.operator.image"
  is_nonempty_value "${SPLUNK_IMAGE}" || err "REQUIRED: images.splunk.image"
  is_nonempty_value "${WEAVIATE_IMAGE}" || err "REQUIRED: images.weaviate.image"
  is_nonempty_value "${AI_FEATURE_SA}" || err "REQUIRED: aiPlatform.features[0].serviceAccountName"

  if ! is_nonempty_value "${WEAVIATE_PROXY_IMAGE}"; then
    WEAVIATE_PROXY_IMAGE="docker.io/kbhos698/weaviate-proxy:v1.0.28-6-g2cbe7b7"
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

  need_file "${SPLUNK_AI_FILE}"
  need_file "${SPLUNK_OPERATOR_FILE}"

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
  sed_in_place "/name:[[:space:]]*RELATED_IMAGE_WEAVIATE_PROXY$/,/value:/ s|value:.*|value: ${weaviate_proxy_escaped}|" "${SPLUNK_AI_FILE}"
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
  for tool in aws kubectl helm yq openssl; do
    need "${tool}"
  done

  need_file "${SPLUNK_OPERATOR_FILE}"
  need_file "${SPLUNK_AI_FILE}"

  aws sts get-caller-identity >/dev/null 2>&1 || \
    err "Unable to access AWS credentials. Configure AWS auth and retry."
}

activate_cluster() {
  log "Setting kubeconfig context for ${CLUSTER_NAME} in ${REGION}..."
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null
  kubectl cluster-info >/dev/null 2>&1 || err "kubectl cannot reach cluster ${CLUSTER_NAME}"

  if ! kubectl get csidriver ebs.csi.aws.com >/dev/null 2>&1; then
    warn "EBS CSI driver not detected. PVC provisioning may fail until aws-ebs-csi-driver is installed."
  fi
}

create_gp3_storageclass() {
  log "Ensuring StorageClass ${STORAGE_CLASS}..."
  if [[ "${STORAGE_CLASS}" != "gp3" ]]; then
    log "Skipping gp3 StorageClass creation because storage.storageClass=${STORAGE_CLASS}"
    return 0
  fi

  cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
EOF
}

install_cert_manager() {
  log "Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null

  local helm_extra_args=()
  if helm upgrade --help 2>/dev/null | grep -q -- '--take-ownership'; then
    helm_extra_args+=(--take-ownership)
  fi

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set installCRDs=true \
    "${helm_extra_args[@]}" \
    --wait \
    --timeout 15m

  kubectl rollout status deployment/cert-manager -n cert-manager --timeout=10m
  kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=10m
  kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=10m
  wait_for_crd certificates.cert-manager.io 300
  wait_for_crd issuers.cert-manager.io 300
}

install_splunk_operator() {
  log "Installing Splunk Operator..."
  kubectl apply -f "${SPLUNK_OPERATOR_FILE}" --server-side --force-conflicts

  local splunk_full
  splunk_full="$(build_image_url "${IMAGE_REGISTRY}" "${SPLUNK_IMAGE}")"
  kubectl set env deployment/splunk-operator-controller-manager -n splunk-operator RELATED_IMAGE_SPLUNK_ENTERPRISE="${splunk_full}" >/dev/null
  kubectl set env deployment/splunk-operator-controller-manager -n splunk-operator SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com >/dev/null
  wait_rollout splunk-operator deployment splunk-operator-controller-manager 600
  wait_for_crd standalones.enterprise.splunk.com 600
}

install_splunk_ai_operator() {
  log "Installing Splunk AI Operator..."
  ensure_namespace "${SPLUNK_AI_NS}"
  kubectl apply -f "${SPLUNK_AI_FILE}" --server-side --force-conflicts

  local dep
  dep="$(kubectl -n "${SPLUNK_AI_NS}" get deploy -l app.kubernetes.io/name=splunk-ai-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${dep}" ]]; then
    dep="$(kubectl -n "${SPLUNK_AI_NS}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 -E 'splunk-ai-operator|ai-operator' || true)"
  fi
  [[ -n "${dep}" ]] || err "Could not detect Splunk AI Operator deployment in ${SPLUNK_AI_NS}"

  wait_rollout "${SPLUNK_AI_NS}" deployment "${dep}" 600
  wait_for_crd aiplatforms.ai.splunk.com 600
  wait_for_crd aiservices.ai.splunk.com 600
}

ensure_s3_bucket_and_prefixes() {
  log "Ensuring S3 bucket s3://${S3_BUCKET} in ${REGION}"
  if ! aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
    log "Creating bucket ${S3_BUCKET}"
    aws s3api create-bucket \
      --bucket "${S3_BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
    aws s3api put-bucket-versioning --bucket "${S3_BUCKET}" --versioning-configuration Status=Enabled >/dev/null
  fi

  local key
  for key in "${S3_PREFIXES[@]}"; do
    aws s3api put-object --bucket "${S3_BUCKET}" --key "${key}" >/dev/null
  done
}

ensure_s3_upload_splunk_app() {
  if [[ -z "${SPLUNK_APP_LOCAL_PATH}" || "${SPLUNK_APP_LOCAL_PATH}" == "null" ]]; then
    return 0
  fi
  if [[ ! -f "${SPLUNK_APP_LOCAL_PATH}" ]]; then
    warn "splunkStandalone.localAppPath not found: ${SPLUNK_APP_LOCAL_PATH}"
    return 0
  fi

  local base key
  base="$(basename "${SPLUNK_APP_LOCAL_PATH}")"
  key="apps/${base}"
  log "Uploading ${base} to s3://${S3_BUCKET}/${key}"
  aws s3 cp "${SPLUNK_APP_LOCAL_PATH}" "s3://${S3_BUCKET}/${key}" >/dev/null
}

resolve_aws_creds_for_secret() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${AWS_PROFILE:-}" ]]; then
    local tmpf
    tmpf="$(mktemp)"
    if aws configure export-credentials --profile "${AWS_PROFILE}" --format env > "${tmpf}" 2>/dev/null; then
      # shellcheck disable=SC1090
      source "${tmpf}"
      rm -f "${tmpf}"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      return 0
    fi
    rm -f "${tmpf}"
  fi

  err "AWS credentials not set. Export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or use AWS_PROFILE with a logged-in profile."
}

install_splunk_standalone() {
  log "Installing Splunk Standalone: ${AI_STANDALONE_NAME} in ${AI_NS}..."

  ensure_namespace "${AI_NS}"
  wait_for_crd standalones.enterprise.splunk.com 600

  resolve_aws_creds_for_secret

  local ak="${AWS_ACCESS_KEY_ID:-}" sk="${AWS_SECRET_ACCESS_KEY:-}" st="${AWS_SESSION_TOKEN:-}"
  local -a secret_args=(
    --from-literal=s3_access_key="${ak}"
    --from-literal=s3_secret_key="${sk}"
  )
  if [[ -n "${st}" ]]; then
    secret_args+=(--from-literal=s3_session_token="${st}")
  fi
  kubectl -n "${AI_NS}" create secret generic s3-secret \
    "${secret_args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -

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
        endpoint: https://s3.${REGION}.amazonaws.com
        region: ${REGION}
        path: ${S3_BUCKET}
        secretRef: s3-secret
YAML

  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance="${AI_STANDALONE_NAME}" -n "${AI_NS}" --timeout=600s || true
  log "Splunk Standalone installed successfully"
}

find_splunk_standalone_secret_name() {
  local ns="$1"
  local owner="$2"
  local timeout="${3:-600}"
  local waited=0
  local name=""

  while true; do
    name="$(kubectl -n "$ns" get secret \
      -l app.kubernetes.io/component=versionedSecrets,app.kubernetes.io/managed-by=splunk-operator \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null | awk -F'|' -v o="$owner" '$2==o {print $1; exit}')"
    if [[ -n "$name" ]]; then
      printf "%s" "$name"
      return 0
    fi
    if [[ $waited -ge $timeout ]]; then
      err "Timed out waiting for Splunk versioned secret for ${owner} in ${ns}"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

install_ai_platform_cr() {
  log "Creating AIPlatform custom resource..."

  kubectl delete jobs -n "${AI_NS}" --field-selector status.successful=0 --wait=false >/dev/null 2>&1 || true
  kubectl delete pods -n "${AI_NS}" --field-selector status.phase=Failed --wait=false >/dev/null 2>&1 || true

  local splunk_secret feature_env_block image_pull_secrets secrets_yaml
  splunk_secret="$(find_splunk_standalone_secret_name "${AI_NS}" "${AI_STANDALONE_NAME}")"
  feature_env_block="$(render_feature_env_block_from_config)"
  image_pull_secrets=""
  secrets_yaml=""

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
  fi

  cat <<YAML | kubectl -n "${AI_NS}" apply --server-side --force-conflicts -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${AI_PLATFORM_NAME}
spec:
  objectStorage:
    path: s3://${S3_BUCKET}
    region: ${REGION}
    secretRef: s3-secret

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
    nodeSelector: {}
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
  create_gp3_storageclass
  ensure_s3_bucket_and_prefixes
  ensure_s3_upload_splunk_app
  install_cert_manager
  install_splunk_operator
  install_splunk_standalone
  install_splunk_ai_operator
  install_ai_platform_cr
}

check_platform_health() {
  log "Running weaviate-service stack health checks..."
  kubectl get nodes -o wide || true
  kubectl get sc || true
  kubectl get pods -n "${AI_NS}" || true
  kubectl get aiplatform -n "${AI_NS}" || true
  kubectl get aiservice -n "${AI_NS}" || true
  kubectl get pods -n cert-manager || true
  kubectl get pods -n splunk-operator || true
  kubectl get pods -n "${SPLUNK_AI_NS}" || true
}

show_platform_access_info() {
  local proxy_service="${AI_PLATFORM_NAME}-weaviate-service-weaviate-service"

  log "Installation complete"
  log "Namespace: ${AI_NS}"
  log "AIPlatform: ${AI_PLATFORM_NAME}"
  log "Splunk service: ${SPLUNK_SERVICE_NAME}"
  log "Weaviate service: ${proxy_service}"
  log ""
  log "Useful checks:"
  log "  kubectl get pods -n ${AI_NS}"
  log "  kubectl get aiplatform,aiservice -n ${AI_NS}"
  log "  kubectl get svc -n ${AI_NS}"
  log ""
  log "In-cluster endpoints:"
  log "  Splunk: https://${SPLUNK_SERVICE_NAME}.${AI_NS}.svc.cluster.local:8089"
  log "  Weaviate service: http://${proxy_service}.${AI_NS}.svc.cluster.local"
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
    warn "This will remove the weaviate-service stack resources from the current EKS cluster."
    read -r -p "Type 'yes' to confirm deletion: " reply
    [[ "${reply}" == "yes" ]] || err "Deletion cancelled"
  fi

  log "Deleting AIPlatform and Splunk resources..."
  kubectl delete aiplatform "${AI_PLATFORM_NAME}" -n "${AI_NS}" --ignore-not-found=true --timeout=120s || true
  kubectl delete standalone "${AI_STANDALONE_NAME}" -n "${AI_NS}" --ignore-not-found=true --timeout=120s || true

  if [[ -f "${SPLUNK_AI_FILE}" ]]; then
    kubectl delete -f "${SPLUNK_AI_FILE}" --ignore-not-found=true >/dev/null 2>&1 || true
  fi
  if [[ -f "${SPLUNK_OPERATOR_FILE}" ]]; then
    kubectl delete -f "${SPLUNK_OPERATOR_FILE}" --ignore-not-found=true >/dev/null 2>&1 || true
  fi

  kubectl delete namespace "${AI_NS}" --ignore-not-found=true --timeout=180s || true
  kubectl delete namespace "${SPLUNK_AI_NS}" --ignore-not-found=true --timeout=180s || true
  kubectl delete namespace splunk-operator --ignore-not-found=true --timeout=180s || true

  log "Weaviate-service stack cleanup complete"
}

usage() {
  cat <<EOF
Usage: $0 [install|delete]

Deploys the weaviate-service stack on an existing EKS cluster.

Commands:
  install  - Install the weaviate-service stack
  delete   - Delete the weaviate-service stack

Environment:
  CONFIG_FILE   - Path to config YAML (default: ./cluster-config.yaml)
  KUBECONFIG    - kubeconfig used after aws eks update-kubeconfig
  AUTO_APPROVE  - Skip delete confirmation prompt

Notes:
  - This script only supports aiPlatform.features[0].name=weaviate-service
  - It assumes an EKS cluster already exists
  - It no longer creates EKS clusters or Ray-related components
  - It uses AWS credentials to create s3-secret for Splunk app storage
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
