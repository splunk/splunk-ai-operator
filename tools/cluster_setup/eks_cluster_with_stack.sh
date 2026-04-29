#!/bin/bash
set -euo pipefail

# --- make EVERYTHING non-interactive / no pagers / stable locale ---
export AWS_PAGER=""
export AWS_DEFAULT_OUTPUT=json
export PAGER=cat
export GIT_PAGER=cat
export LESS=FRX
export EDITOR=cat
export KUBE_EDITOR=cat
export LANG=C LC_ALL=C

# Force all aws invocations in this script to skip the pager
aws() { command /usr/bin/env aws "$@"; }

# ====== CONFIG FILE LOCATION ======
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/cluster-config.yaml}"

# ====== LOAD CONFIGURATION FROM YAML ======
load_config() {
  local cfg="$CONFIG_FILE"
  [[ -f "$cfg" ]] || err "Config file not found: $cfg"

  log "Loading configuration from: $cfg"

  # Read configuration using yq (if available) or fallback to basic parsing
  if command -v yq >/dev/null 2>&1; then
    CLUSTER_NAME="$(yq eval '.cluster.name' "$cfg")"
    REGION="$(yq eval '.cluster.region' "$cfg")"
    K8S_VERSION="$(yq eval '.cluster.k8sVersion' "$cfg")"
    USE_EXISTING_CLUSTER="$(yq eval '.cluster.useExisting // false' "$cfg")"

    # Node groups
    ENABLE_CPU="$(yq eval '.nodeGroups.cpu.enabled' "$cfg")"
    CPU_INSTANCE_TYPE="$(yq eval '.nodeGroups.cpu.instanceType' "$cfg")"
    CPU_DESIRED="$(yq eval '.nodeGroups.cpu.desiredCapacity' "$cfg")"
    CPU_MIN="$(yq eval '.nodeGroups.cpu.minSize' "$cfg")"
    CPU_MAX="$(yq eval '.nodeGroups.cpu.maxSize' "$cfg")"
    CPU_VOLUME_SIZE="$(yq eval '.nodeGroups.cpu.volumeSize' "$cfg")"
    CPU_VOLUME_TYPE="$(yq eval '.nodeGroups.cpu.volumeType' "$cfg")"

    ENABLE_GPU="$(yq eval '.nodeGroups.gpu.enabled' "$cfg")"
    GPU_INSTANCE_TYPE="$(yq eval '.nodeGroups.gpu.instanceType' "$cfg")"
    GPU_DESIRED="$(yq eval '.nodeGroups.gpu.desiredCapacity' "$cfg")"
    GPU_MIN="$(yq eval '.nodeGroups.gpu.minSize' "$cfg")"
    GPU_MAX="$(yq eval '.nodeGroups.gpu.maxSize' "$cfg")"
    GPU_VOLUME_SIZE="$(yq eval '.nodeGroups.gpu.volumeSize' "$cfg")"
    GPU_VOLUME_TYPE="$(yq eval '.nodeGroups.gpu.volumeType' "$cfg")"

    # GPU Availability Zones (optional - for capacity-constrained instance types like P5/H100)
    GPU_AVAILABILITY_ZONES=()
    while IFS= read -r az; do
      [[ -n "$az" ]] && GPU_AVAILABILITY_ZONES+=("$az")
    done < <(yq eval '.nodeGroups.gpu.availabilityZones[]' "$cfg" 2>/dev/null)

    # Capacity Reservation (optional - for H100/P5 instances)
    GPU_CAPACITY_RESERVATION_ID="$(yq eval '.nodeGroups.gpu.capacityReservation.id' "$cfg" 2>/dev/null)"
    GPU_CAPACITY_RESERVATION_AZ="$(yq eval '.nodeGroups.gpu.capacityReservation.az' "$cfg" 2>/dev/null)"
    [[ "$GPU_CAPACITY_RESERVATION_ID" == "null" ]] && GPU_CAPACITY_RESERVATION_ID=""
    [[ "$GPU_CAPACITY_RESERVATION_AZ" == "null" ]] && GPU_CAPACITY_RESERVATION_AZ=""

    # Cluster options
    PRESERVE_VPC_ON_DELETE="$(yq eval '.cluster.preserveVpcOnDelete // false' "$cfg")"

    # Storage
    S3_BUCKET="$(yq eval '.storage.s3Bucket' "$cfg")"
    STORAGE_CLASS="$(yq eval '.storage.storageClass' "$cfg")"
    VECTORDB_SIZE="$(yq eval '.storage.vectorDbSize' "$cfg")"
    # Object storage: objectStore.type (aws | s3compat | minio | seaweedfs); default aws when unset
    OBJ_STORE_TYPE="$(yq eval '.storage.objectStore.type // "aws"' "$cfg")"
    OBJ_STORE_BUCKET="$(yq eval '.storage.objectStore.bucket // .storage.s3Bucket // "ai-platform"' "$cfg")"
    OBJ_STORE_ENDPOINT="$(yq eval '.storage.objectStore.endpoint // ""' "$cfg")"
    OBJ_STORE_NS="$(yq eval '.storage.objectStore.namespace // "minio"' "$cfg")"
    _obj_user="$(yq eval '.storage.objectStore.auth.rootUser // "minioadmin"' "$cfg")"
    _obj_pw="$(yq eval '.storage.objectStore.auth.rootPassword // ""' "$cfg")"
    # External S3-compatible only (no in-cluster MinIO install). True when type is s3compat, minio, or seaweedfs.
    USE_EXTERNAL_OBJ_STORE="false"
    case "${OBJ_STORE_TYPE}" in s3compat|minio|seaweedfs) USE_EXTERNAL_OBJ_STORE="true"; esac
    MINIO_ENDPOINT="${OBJ_STORE_ENDPOINT}"
    MINIO_NS="${OBJ_STORE_NS}"
    MINIO_BUCKET="${OBJ_STORE_BUCKET}"
    MINIO_ROOT_USER="${MINIO_ROOT_USER:-$_obj_user}"
    MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$_obj_pw}"

    # AI Platform
    AI_NS="$(yq eval '.aiPlatform.namespace' "$cfg")"
    AI_PLATFORM_NAME="$(yq eval '.aiPlatform.name' "$cfg")"
    RAY_HEAD_SA="$(yq eval '.aiPlatform.serviceAccounts.rayHead' "$cfg")"
    RAY_WORKER_SA="$(yq eval '.aiPlatform.serviceAccounts.rayWorker' "$cfg")"
    SAIA_SERVICE_SA="$(yq eval '.aiPlatform.serviceAccounts.saiaService' "$cfg")"
    DEFAULT_ACCELERATOR="$(yq eval '.aiPlatform.defaultAcceleratorType' "$cfg")"
    WORKER_IMAGE_REGISTRY="$(yq eval '.aiPlatform.workerGroupConfig.imageRegistry' "$cfg")"
    SAIA_SERVICE_TYPE="$(yq eval '.aiPlatform.serviceTemplate.type // ""' "$cfg")"
    SAIA_SERVICE_NODE_PORT="$(yq eval '.aiPlatform.serviceTemplate.nodePort // ""' "$cfg")"
    # AWS Load Balancer Controller (LBC) install toggle. Required for both
    # operator-managed NLB provisioning (Mode 1) and customer-owned LB
    # registration via TargetGroupBinding (Mode 2). Off-AWS users (k0s) leave
    # this false.
    INSTALL_LBC="$(yq eval '.aiPlatform.awsLoadBalancerController.install // false' "$cfg")"
    # Bring-your-own AWS target group (Mode 2). When enabled the script keeps
    # the public Service as ClusterIP and applies a TargetGroupBinding so LBC
    # registers nginx pod IPs into the customer's pre-existing target group.
    # Requires INSTALL_LBC=true.
    BYO_TG_ENABLED="$(yq eval '.aiPlatform.byoTargetGroup.enabled // false' "$cfg")"
    BYO_TG_ARN="$(yq eval '.aiPlatform.byoTargetGroup.targetGroupArn // ""' "$cfg")"
    BYO_TG_SG_ID="$(yq eval '.aiPlatform.byoTargetGroup.securityGroupId // ""' "$cfg")"
    INGRESS_HOST="$(yq eval '.aiPlatform.ingress.host' "$cfg")"
    INGRESS_CLASS="$(yq eval '.aiPlatform.ingress.className' "$cfg")"
    INGRESS_TLS_SECRET="$(yq eval '.aiPlatform.ingress.tlsSecretName' "$cfg")"
    CERT_ISSUER="$(yq eval '.aiPlatform.certificate.issuerName' "$cfg")"

    # Splunk Standalone
    AI_STANDALONE_NAME="$(yq eval '.splunkStandalone.name' "$cfg")"
    STANDALONE_SA="$(yq eval '.splunkStandalone.serviceAccount' "$cfg")"
    SPLUNK_APP_LOCAL_PATH="$(yq eval '.splunkStandalone.localAppPath' "$cfg")"

    # Files
    SPLUNK_OPERATOR_FILE="$(yq eval '.files.splunkOperatorManifest' "$cfg")"
    SPLUNK_AI_FILE="$(yq eval '.files.splunkAiOperatorManifest' "$cfg")"

    # Operators
    RAY_VERSION="$(yq eval '.operators.ray.version' "$cfg")"
    MODEL_VERSION="$(yq eval '.operators.ray.modelVersion' "$cfg")"
    RAY_RUNTIME_VERSION="$(yq eval '.operators.ray.rayVersion' "$cfg")"
    NVIDIA_VERSION="$(yq eval '.operators.nvidia.devicePluginVersion' "$cfg")"

    # Container Images
    IMAGE_REGISTRY="$(yq eval '.images.registry' "$cfg")"
    OPERATOR_IMAGE="$(yq eval '.images.operator.image' "$cfg")"
    SPLUNK_IMAGE="$(yq eval '.images.splunk.image' "$cfg")"
    SPLUNK_OPERATOR_IMAGE="$(yq eval '.images.splunk.operatorImage' "$cfg")"
    RAY_HEAD_IMAGE="$(yq eval '.images.ray.headImage' "$cfg")"
    RAY_WORKER_IMAGE="$(yq eval '.images.ray.workerImage' "$cfg")"
    WEAVIATE_IMAGE="$(yq eval '.images.weaviate.image' "$cfg")"
    SAIA_API_IMAGE="$(yq eval '.images.saia.apiImage' "$cfg")"
    SAIA_API_V2_IMAGE="$(yq eval '.images.saia.apiV2Image // ""' "$cfg")"
    SAIA_DATALOADER_IMAGE="$(yq eval '.images.saia.dataLoaderImage' "$cfg")"
    FLUENT_BIT_IMAGE="$(yq eval '.images.fluentBit.image' "$cfg")"
    OTEL_COLLECTOR_IMAGE="$(yq eval '.images.otelCollector.image' "$cfg")"
    NGINX_IMAGE="$(yq eval '.images.nginx.image // "docker.io/library/nginx:1.27-alpine"' "$cfg")"

    # Subnets - read as arrays (support both cluster.subnets and top-level subnets)
    PRIVATE_SUBNETS=()
    while IFS= read -r subnet; do
      [[ -n "$subnet" ]] && PRIVATE_SUBNETS+=("$subnet")
    done < <(yq eval '.cluster.subnets.private[].id // .subnets.private[].id' "$cfg")

    PRIVATE_SUBNETS_AZ=()
    while IFS= read -r az; do
      [[ -n "$az" ]] && PRIVATE_SUBNETS_AZ+=("$az")
    done < <(yq eval '.cluster.subnets.private[].az // .subnets.private[].az' "$cfg")

    PUBLIC_SUBNETS=()
    while IFS= read -r subnet; do
      [[ -n "$subnet" ]] && PUBLIC_SUBNETS+=("$subnet")
    done < <(yq eval '.cluster.subnets.public[].id // .subnets.public[].id' "$cfg")

    PUBLIC_SUBNETS_AZ=()
    while IFS= read -r az; do
      [[ -n "$az" ]] && PUBLIC_SUBNETS_AZ+=("$az")
    done < <(yq eval '.cluster.subnets.public[].az // .subnets.public[].az' "$cfg")
  else
    # Fallback: simple grep-based parsing (less robust but works without yq)
    CLUSTER_NAME="$(grep 'name:' "$cfg" | head -1 | sed 's/.*name: *"\(.*\)".*/\1/')"
    REGION="$(grep 'region:' "$cfg" | head -1 | sed 's/.*region: *"\(.*\)".*/\1/')"
    K8S_VERSION="$(grep 'k8sVersion:' "$cfg" | sed 's/.*k8sVersion: *"\(.*\)".*/\1/')"
    USE_EXISTING_CLUSTER="false"
    PRESERVE_VPC_ON_DELETE="false"
    S3_BUCKET="$(grep 's3Bucket:' "$cfg" | sed 's/.*s3Bucket: *"\(.*\)".*/\1/')"
    OBJ_STORE_TYPE=""
    OBJ_STORE_BUCKET="${S3_BUCKET}"
    OBJ_STORE_ENDPOINT=""
    OBJ_STORE_NS="minio"
    USE_EXTERNAL_OBJ_STORE="false"
    MINIO_ENDPOINT=""
    MINIO_NS="minio"
    MINIO_BUCKET="ai-platform"
    MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
    MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
    AI_NS="$(grep 'namespace:' "$cfg" | grep -A2 'aiPlatform:' | tail -1 | sed 's/.*namespace: *"\(.*\)".*/\1/')"
    AI_PLATFORM_NAME="splunk-ai-stack"
    AI_STANDALONE_NAME="splunk-standalone"
    STORAGE_CLASS="gp3"
    VECTORDB_SIZE="50Gi"
    RAY_HEAD_SA="ray-head-sa"
    RAY_WORKER_SA="ray-worker-sa"
    SAIA_SERVICE_SA="saia-service-sa"
    DEFAULT_ACCELERATOR="L40S"
    WORKER_IMAGE_REGISTRY=""
    SAIA_SERVICE_TYPE=""
    SAIA_SERVICE_NODE_PORT=""
    INSTALL_LBC="false"
    BYO_TG_ENABLED="false"
    BYO_TG_ARN=""
    BYO_TG_SG_ID=""
    INGRESS_HOST="ai.example.com"
    INGRESS_CLASS="nginx"
    INGRESS_TLS_SECRET="ai-platform-tls"
    CERT_ISSUER="platform-issuer"
    SPLUNK_OPERATOR_FILE="./splunk-operator-cluster.yaml"
    SPLUNK_AI_FILE="./artifacts.yaml"
    SPLUNK_IMAGE="splunk/splunk:10.2.0-dev1"
    SAIA_API_V2_IMAGE=""
    NGINX_IMAGE="docker.io/library/nginx:1.27-alpine"
    RAY_VERSION="v1.2.2"
    NVIDIA_VERSION="v0.17.3"
    ENABLE_CPU=true
    ENABLE_GPU=true
    CPU_INSTANCE_TYPE="m5.xlarge"
    CPU_DESIRED=4
    CPU_MIN=2
    CPU_MAX=8
    CPU_VOLUME_SIZE=500
    CPU_VOLUME_TYPE="gp3"
    GPU_INSTANCE_TYPE="g6e.12xlarge"
    GPU_DESIRED=2
    GPU_MIN=2
    GPU_MAX=4
    GPU_VOLUME_SIZE=1000
    GPU_VOLUME_TYPE="gp3"
    GPU_AVAILABILITY_ZONES=()
    GPU_CAPACITY_RESERVATION_ID=""
    GPU_CAPACITY_RESERVATION_AZ=""
    SPLUNK_APP_LOCAL_PATH=""

    # Hardcoded subnets for fallback
    PRIVATE_SUBNETS=("subnet-0f4af6d2f36fbe73f" "subnet-024d4edaabe647586")
    PUBLIC_SUBNETS=("subnet-0439b4f08a984ae52" "subnet-06aef8e454c0e5542" "subnet-0a183703673334cb4")
  fi

  # Derived values
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  S3_PREFIXES=("artifacts/" "apps/" "tasks/")
  AI_BUCKET_POLICY_NAME="S3Access-${CLUSTER_NAME}-ai-platform"
  AI_ECR_ONLY_POLICY_NAME="ECRAccess-${CLUSTER_NAME}-ai-platform"

  # IRSA for EBS CSI
  EBS_IRSA_ROLE_NAME="EBSCSIDriverRole-${CLUSTER_NAME}"
  EBS_SA="ebs-csi-controller-sa"
  EBS_NS="kube-system"

  # Cluster Autoscaler (IRSA)
  AUTOSCALER_RELEASE="cluster-autoscaler"
  AUTOSCALER_ROLE_NAME="ClusterAutoscalerRole-${CLUSTER_NAME}"
  AUTOSCALER_SA="cluster-autoscaler"
  AUTOSCALER_NS="kube-system"

  # OpenTelemetry
  OTEL_NS="observability"
  OTEL_OPERATOR_RELEASE="otel-operator"
  OTEL_COLLECTOR_CR="otel-collector"

  # Splunk operators
  SPLUNK_AI_NS="splunk-ai-operator-system"

  # AWS Load Balancer Controller (LBC) — required when a Service of type=LoadBalancer
  # uses the "service.beta.kubernetes.io/aws-load-balancer-type: external" annotation
  # (the in-tree EKS cloud controller intentionally skips those Services). Pinned
  # chart and policy versions keep installs reproducible against a vetted upstream
  # release (supply-chain hygiene: codeguard-0-supply-chain-security).
  LBC_NS="kube-system"
  LBC_SA="aws-load-balancer-controller"
  LBC_RELEASE="aws-load-balancer-controller"
  LBC_ROLE_NAME="AWSLoadBalancerControllerRole-${CLUSTER_NAME}"
  LBC_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy-${CLUSTER_NAME}"
  LBC_CHART_VERSION="1.8.2"   # helm chart version (appVersion v2.8.2)
  LBC_POLICY_VERSION="v2.8.2" # upstream tag used to fetch iam_policy.json

  log "Configuration loaded: cluster=${CLUSTER_NAME}, region=${REGION}, namespace=${AI_NS}"
}

# ---- logging ----
log()   { echo -e "\033[1;32m[INFO]\033[0m $*" >&2; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || err "Missing $1 in PATH"; }
need_file(){ [[ -f "$1" ]] || err "Missing file: $1"; }
all_ok(){ return 0; }

# ---- Image configuration validation ----
validate_image_config() {
  log "Validating image configuration..."

  local errors=0

  # Required fields
  if [[ -z "$IMAGE_REGISTRY" || "$IMAGE_REGISTRY" == "null" ]]; then
    err "REQUIRED: images.registry must be specified in cluster-config.yaml"
  fi

  if [[ -z "$OPERATOR_IMAGE" || "$OPERATOR_IMAGE" == "null" ]]; then
    err "REQUIRED: images.operator.image must be specified in cluster-config.yaml"
  fi

  if [[ -z "$SPLUNK_IMAGE" || "$SPLUNK_IMAGE" == "null" ]]; then
    err "REQUIRED: images.splunk.image must be specified in cluster-config.yaml"
  fi

  if [[ -z "$RAY_HEAD_IMAGE" || "$RAY_HEAD_IMAGE" == "null" ]]; then
    err "REQUIRED: images.ray.headImage must be specified in cluster-config.yaml"
  fi

  if [[ -z "$RAY_WORKER_IMAGE" || "$RAY_WORKER_IMAGE" == "null" ]]; then
    err "REQUIRED: images.ray.workerImage must be specified in cluster-config.yaml"
  fi

  if [[ -z "$WEAVIATE_IMAGE" || "$WEAVIATE_IMAGE" == "null" ]]; then
    err "REQUIRED: images.weaviate.image must be specified in cluster-config.yaml"
  fi

  if [[ -z "$SAIA_API_IMAGE" || "$SAIA_API_IMAGE" == "null" ]]; then
    err "REQUIRED: images.saia.apiImage must be specified in cluster-config.yaml"
  fi

  if [[ -z "$SAIA_DATALOADER_IMAGE" || "$SAIA_DATALOADER_IMAGE" == "null" ]]; then
    err "REQUIRED: images.saia.dataLoaderImage must be specified in cluster-config.yaml"
  fi

  # Optional with defaults
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

# ---- Image replacement helper functions ----
# Build full image URL by combining registry with image path
# Logic:
#   1. If image has a registry (domain.com/path:tag) → use as-is (full URL provided)
#   2. If registry is provided and image is relative → prepend registry
#   3. If no registry and image is relative → use Docker Hub default
build_image_url() {
  local registry="$1"
  local image_path="$2"

  # Check if image already has a registry (contains domain pattern like docker.io, ghcr.io, *.ecr.*.amazonaws.com)
  # Pattern: domain.tld/... or IP:port/...
  if [[ "$image_path" =~ ^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/.*:.+ ]]; then
    # Image has full registry path, use as-is
    echo "$image_path"
    return 0
  fi

  # If registry is provided and not empty, prepend it
  if [[ -n "$registry" && "$registry" != "null" ]]; then
    echo "${registry}/${image_path}"
  else
    # No registry specified, assume Docker Hub
    # Docker Hub format: org/image:tag or image:tag
    echo "$image_path"
  fi
}

# Replace image in YAML manifest
replace_image_in_manifest() {
  local file="$1"
  local old_image="$2"
  local new_image="$3"

  if [[ ! -f "$file" ]]; then
    warn "File not found: $file, skipping image replacement"
    return
  fi

  # Escape special characters for sed
  local old_escaped=$(echo "$old_image" | sed 's/[\/&]/\\&/g')
  local new_escaped=$(echo "$new_image" | sed 's/[\/&]/\\&/g')

  # Replace in file
  sed -i.bak "s|${old_escaped}|${new_escaped}|g" "$file"
  log "  Replaced: $old_image → $new_image"
}

# Configure all images in artifacts.yaml and splunk-operator-cluster.yaml
configure_images() {
  log "Configuring container images in manifest files..."

  # Make backups only if they don't exist (preserve original clean versions)
  if [[ ! -f "${SPLUNK_AI_FILE}.original" ]]; then
    log "Creating backup: ${SPLUNK_AI_FILE}.original"
    cp "$SPLUNK_AI_FILE" "${SPLUNK_AI_FILE}.original"
  fi
  if [[ ! -f "${SPLUNK_OPERATOR_FILE}.original" ]]; then
    log "Creating backup: ${SPLUNK_OPERATOR_FILE}.original"
    cp "$SPLUNK_OPERATOR_FILE" "${SPLUNK_OPERATOR_FILE}.original"
  fi

  # Always restore from clean original before applying changes
  # This ensures idempotent behavior - script can be run multiple times safely
  log "Restoring from clean originals to ensure idempotent updates..."
  cp "${SPLUNK_AI_FILE}.original" "$SPLUNK_AI_FILE"
  cp "${SPLUNK_OPERATOR_FILE}.original" "$SPLUNK_OPERATOR_FILE"

  # artifacts.yaml - RELATED_IMAGE_* environment variables
  log "Updating $SPLUNK_AI_FILE..."

  # Build full image URLs using registry prefix (or use full path if already has registry)
  local operator_full=$(build_image_url "$IMAGE_REGISTRY" "$OPERATOR_IMAGE")
  local ray_head_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_HEAD_IMAGE")
  local ray_worker_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_WORKER_IMAGE")
  local weaviate_full=$(build_image_url "$IMAGE_REGISTRY" "$WEAVIATE_IMAGE")
  local saia_api_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_IMAGE")
  local saia_api_v2_full=""
  local saia_dataloader_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_DATALOADER_IMAGE")
  local fluent_bit_full=$(build_image_url "$IMAGE_REGISTRY" "$FLUENT_BIT_IMAGE")
  local otel_collector_full=$(build_image_url "$IMAGE_REGISTRY" "$OTEL_COLLECTOR_IMAGE")
  local nginx_full=$(build_image_url "$IMAGE_REGISTRY" "$NGINX_IMAGE")
  if [[ -n "${SAIA_API_V2_IMAGE}" && "${SAIA_API_V2_IMAGE}" != "null" ]]; then
    saia_api_v2_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_V2_IMAGE")
  fi

  # Escape special characters for sed
  local ray_head_escaped=$(echo "$ray_head_full" | sed 's/[\/&]/\\&/g')
  local ray_worker_escaped=$(echo "$ray_worker_full" | sed 's/[\/&]/\\&/g')
  local weaviate_escaped=$(echo "$weaviate_full" | sed 's/[\/&]/\\&/g')
  local saia_api_escaped=$(echo "$saia_api_full" | sed 's/[\/&]/\\&/g')
  local saia_api_v2_escaped=""
  local saia_dataloader_escaped=$(echo "$saia_dataloader_full" | sed 's/[\/&]/\\&/g')
  local fluent_bit_escaped=$(echo "$fluent_bit_full" | sed 's/[\/&]/\\&/g')
  local otel_collector_escaped=$(echo "$otel_collector_full" | sed 's/[\/&]/\\&/g')
  local nginx_escaped=$(echo "$nginx_full" | sed 's/[\/&]/\\&/g')
  local operator_escaped=$(echo "$operator_full" | sed 's/[\/&]/\\&/g')
  if [[ -n "${saia_api_v2_full}" ]]; then
    saia_api_v2_escaped=$(echo "$saia_api_v2_full" | sed 's/[\/&]/\\&/g')
  fi

  local SED_INPLACE
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_INPLACE=(sed -i "")
  else
    SED_INPLACE=(sed -i)
  fi
  # Replace RELATED_IMAGE_ env vars by matching the env var name (not the value pattern)
  # This works regardless of what registry/image was there before
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_RAY_HEAD/,/value:/ s|value:.*|value: ${ray_head_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_RAY_WORKER/,/value:/ s|value:.*|value: ${ray_worker_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_WEAVIATE/,/value:/ s|value:.*|value: ${weaviate_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SAIA_API$/,/value:/ s|value:.*|value: ${saia_api_escaped}|" "$SPLUNK_AI_FILE"
  if [[ -n "${saia_api_v2_escaped}" ]]; then
    "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SAIA_API_V2/,/value:/ s|value:.*|value: ${saia_api_v2_escaped}|" "$SPLUNK_AI_FILE"
  fi
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_POST_INSTALL_HOOK/,/value:/ s|value:.*|value: ${saia_dataloader_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_FLUENT_BIT/,/value:/ s|value:.*|value: ${fluent_bit_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_OTEL_COLLECTOR/,/value:/ s|value:.*|value: ${otel_collector_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_NGINX/,/value:/ s|value:.*|value: ${nginx_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: MODEL_VERSION/,/value:/ s|value:.*|value: ${MODEL_VERSION}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RAY_VERSION/,/value:/ s|value:.*|value: ${RAY_RUNTIME_VERSION}|" "$SPLUNK_AI_FILE"

  # Replace operator image (the container image itself, not env var)
  # Find the line with "image:" that's near "splunk-ai-operator" and replace it
  "${SED_INPLACE[@]}" "s|image: .*splunk.*ai.*operator.*|image: ${operator_escaped}|I" "$SPLUNK_AI_FILE"

  log "  ✓ Updated RELATED_IMAGE_RAY_HEAD: $ray_head_full"
  log "  ✓ Updated RELATED_IMAGE_RAY_WORKER: $ray_worker_full"
  log "  ✓ Updated RELATED_IMAGE_WEAVIATE: $weaviate_full"
  log "  ✓ Updated RELATED_IMAGE_SAIA_API: $saia_api_full"
  if [[ -n "${saia_api_v2_full}" ]]; then
    log "  ✓ Updated RELATED_IMAGE_SAIA_API_V2: $saia_api_v2_full"
  fi
  log "  ✓ Updated RELATED_IMAGE_POST_INSTALL_HOOK: $saia_dataloader_full"
  log "  ✓ Updated RELATED_IMAGE_FLUENT_BIT: $fluent_bit_full"
  log "  ✓ Updated RELATED_IMAGE_OTEL_COLLECTOR: $otel_collector_full"
  log "  ✓ Updated RELATED_IMAGE_NGINX: $nginx_full"
  log "  ✓ Updated operator image: $operator_full"
  log "  ✓ Updated MODEL_VERSION: $MODEL_VERSION"
  log "  ✓ Updated RAY_VERSION: $RAY_RUNTIME_VERSION"

  # splunk-operator-cluster.yaml - Splunk images
  log "Updating $SPLUNK_OPERATOR_FILE..."

  local splunk_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_IMAGE")
  local splunk_operator_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_OPERATOR_IMAGE")

  local splunk_escaped=$(echo "$splunk_full" | sed 's/[\/&]/\\&/g')
  local splunk_op_escaped=$(echo "$splunk_operator_full" | sed 's/[\/&]/\\&/g')

  # Replace RELATED_IMAGE_SPLUNK_ENTERPRISE env var
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SPLUNK_ENTERPRISE/,/value:/ s|value:.*|value: ${splunk_escaped}|" "$SPLUNK_OPERATOR_FILE"

  # Replace splunk-operator image (the container image itself)
  "${SED_INPLACE[@]}" "s|image: .*splunk.*operator.*|image: ${splunk_op_escaped}|I" "$SPLUNK_OPERATOR_FILE"

  log "  ✓ Updated Splunk Enterprise image: $splunk_full"
  log "  ✓ Updated Splunk Operator image: $splunk_operator_full"

  log "✓ All images configured successfully"
}

# ---- Image existence validation ----
# Check if an image exists in the registry
check_image_exists() {
  local image="$1"
  local image_name=$(echo "$image" | sed 's|.*/||' | cut -d: -f1)

  log "  Checking: $image"

  # Detect timeout command (GNU timeout on Linux, gtimeout on macOS via coreutils, or none)
  local TIMEOUT_CMD=""
  if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout 30"
  elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout 30"
  else
    # No timeout command available (common on macOS without coreutils)
    # Commands will run without timeout
    TIMEOUT_CMD=""
  fi

  # Try docker manifest inspect with timeout (fastest, works if Docker daemon is running)
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if $TIMEOUT_CMD docker manifest inspect "$image" >/dev/null 2>&1; then
      log "    ✓ Found (via docker)"
      return 0
    else
      log "    ⚠ Docker check timed out or failed, trying other methods..."
    fi
  fi

  # Try crane with timeout (works without Docker daemon, supports multiple registries)
  if command -v crane >/dev/null 2>&1; then
    if $TIMEOUT_CMD crane manifest "$image" >/dev/null 2>&1; then
      log "    ✓ Found (via crane)"
      return 0
    fi
  fi

  # Try skopeo with timeout (alternative tool, good for registries)
  # Note: Force linux/amd64 platform since we're checking for EKS deployment images
  if command -v skopeo >/dev/null 2>&1; then
    if $TIMEOUT_CMD skopeo inspect --override-os linux --override-arch amd64 "docker://$image" >/dev/null 2>&1; then
      log "    ✓ Found (via skopeo)"
      return 0
    fi
  fi

  # For ECR images, try AWS CLI
  if [[ "$image" =~ ^[0-9]+\.dkr\.ecr\.[^.]+\.amazonaws\.com ]]; then
    local registry=$(echo "$image" | cut -d/ -f1)
    local region=$(echo "$registry" | cut -d. -f4)
    local repo=$(echo "$image" | cut -d/ -f2- | cut -d: -f1)
    local tag=$(echo "$image" | cut -d: -f2)

    if aws ecr describe-images \
      --registry-id "$(echo $registry | cut -d. -f1)" \
      --repository-name "$repo" \
      --image-ids imageTag="$tag" \
      --region "$region" >/dev/null 2>&1; then
      log "    ✓ Found (via AWS ECR)"
      return 0
    fi
  fi

  return 1
}

# Validate all configured images exist
validate_images_exist() {
  # Allow skipping validation with environment variable
  if [[ "${SKIP_IMAGE_VALIDATION:-false}" == "true" ]]; then
    warn "Skipping image validation (SKIP_IMAGE_VALIDATION=true)"
    return 0
  fi

  log "Validating image availability in registries..."
  log "This may take a few moments as we check each image..."
  log "Tip: To skip validation, set SKIP_IMAGE_VALIDATION=true"

  local failed_images=()
  local images_to_check=()

  # Build list of all images to check (apply registry logic consistently)
  local operator_full=$(build_image_url "$IMAGE_REGISTRY" "$OPERATOR_IMAGE")
  local splunk_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_IMAGE")
  local splunk_operator_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_OPERATOR_IMAGE")
  local ray_head_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_HEAD_IMAGE")
  local ray_worker_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_WORKER_IMAGE")
  local weaviate_full=$(build_image_url "$IMAGE_REGISTRY" "$WEAVIATE_IMAGE")
  local saia_api_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_IMAGE")
  local saia_dataloader_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_DATALOADER_IMAGE")
  local fluent_bit_full=$(build_image_url "$IMAGE_REGISTRY" "$FLUENT_BIT_IMAGE")
  local otel_collector_full=$(build_image_url "$IMAGE_REGISTRY" "$OTEL_COLLECTOR_IMAGE")

  images_to_check=(
    "$operator_full"
    "$splunk_full"
    "$splunk_operator_full"
    "$ray_head_full"
    "$ray_worker_full"
    "$weaviate_full"
    "$saia_api_full"
    "$saia_dataloader_full"
    "$fluent_bit_full"
    "$otel_collector_full"
  )

  # Check each image
  for image in "${images_to_check[@]}"; do
    if ! check_image_exists "$image"; then
      failed_images+=("$image")
      warn "    ✗ NOT FOUND: $image"
    fi
  done

  # Report results
  if [ ${#failed_images[@]} -gt 0 ]; then
    echo ""
    err "❌ Image validation FAILED! The following images were not found in their registries:

$(printf '  - %s\n' "${failed_images[@]}")

Please verify:
1. Image names and tags are correct in cluster-config.yaml
2. You have access to the registries (ECR login, Docker Hub auth, etc.)
3. Images have been pushed to the registries

For ECR images, ensure you're logged in:
  aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${IMAGE_REGISTRY}

To skip image validation (NOT RECOMMENDED), set:
  export SKIP_IMAGE_VALIDATION=true"
  fi

  log "✓ All images validated successfully - ready for deployment!"
}

# ---- temp files ----
TMP_FILES=()
cleanup_tmp() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}" 2>/dev/null || true; }
trap cleanup_tmp EXIT

render_pi_trust_policy() {
  local tpl out
  tpl="$(mktemp)"; TMP_FILES+=("$tpl")
  out="$(mktemp)"; TMP_FILES+=("$out")
  cat >"$tpl" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSPodIdentityTrust",
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": [ "sts:AssumeRole", "sts:TagSession" ],
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "__ACCOUNT_ID__" },
        "StringLike":   { "aws:SourceArn": "arn:aws:eks:__REGION____COLON____ACCOUNT_ID__:podidentityassociation/*" }
      }
    }
  ]
}
JSON
  sed -e "s/__ACCOUNT_ID__/${ACCOUNT_ID}/g" \
      -e "s/__REGION__/${REGION}/g" \
      -e "s/__COLON__/:/g" "$tpl" > "$out"
  printf "%s" "$out"
}

# ====== Helpers ======
normalize_arn() {
  local x="${1:-}"
  # strip CR, newlines, and surrounding whitespace
  x="${x//$'\r'/}"
  x="$(printf "%s" "$x" | tr -d '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # portable downcase for comparison
  local lower
  lower="$(printf "%s" "$x" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *none*|*null*|"" ) x="";;
  esac
  printf "%s" "$x"
}


get_policy_arn_by_name() {
  local name="$1"
  local arn
  arn="$(aws iam list-policies --scope Local \
           --query "Policies[?PolicyName=='${name}'].Arn | [0]" \
           --output text 2>/dev/null || true)"
  normalize_arn "$arn"
}


ensure_role_has_policy() {
  local role="$1" policy_arn="$2"
  local attached
  attached="$(aws iam list-attached-role-policies --role-name "$role" \
    --query "AttachedPolicies[?PolicyArn=='${policy_arn}'] | length(@)" --output text 2>/dev/null || echo 0)"
  if [[ "$attached" != "1" ]]; then
    log "Attaching policy ${policy_arn} to role ${role}"
    aws iam attach-role-policy --role-name "$role" --policy-arn "$policy_arn"
  fi
}

cluster_exists() { aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; }

ensure_kubeconfig() {
  log "Setting kubeconfig context for ${CLUSTER_NAME} in ${REGION}"
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"
  export K8S_PATCH_VERSION=$(kubectl version --output=json | jq -r '.serverVersion.gitVersion' | cut -d'-' -f1)
}

endpoint_host() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
    --query 'cluster.endpoint' --output text | sed -e 's|https://||' -e 's|:443||'
}

get_oidc_provider_arn() {
  local issuer; issuer="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
  [[ -z "$issuer" || "$issuer" == "None" ]] && return 1
  local hostpath="${issuer#https://}"
  printf "arn:aws:iam::%s:oidc-provider/%s" "${ACCOUNT_ID}" "${hostpath}"
}

get_oidc_hostpath() {
  local issuer; issuer="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
  [[ -z "$issuer" || "$issuer" == "None" ]] && return 1
  printf "%s" "${issuer#https://}"
}

# ---------- Wait helpers ----------
check_ready() {
  local ns="$1" label="$2" waited=0 max_wait=900
  log "Waiting for pods in '$ns' with label '$label'..."
  while true; do
    local total ready
    total=$(kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | wc -l || true)
    ready=$(kubectl get pods -n "$ns" -l "$label" 2>/dev/null | awk 'NR>1{split($2,a,"/"); if(a[1]==a[2]) c++} END{print c+0}')
    if [[ "$total" -ge 1 && "$ready" -eq "$total" ]]; then
      log "Ready: $ready/$total in $ns"; break
    fi
    [[ "$waited" -ge "$max_wait" ]] && err "Timeout waiting for pods in '$ns' with '$label' - ready $ready of $total"
    sleep 5; waited=$((waited+5))
  done
}

wait_resource_exists() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-300}"
  log "Waiting for $kind/$name to exist in $ns..."
  local waited=0
  until kubectl -n "$ns" get "$kind/$name" >/dev/null 2>&1; do
    [[ $waited -ge $timeout ]] && err "$kind/$name did not appear in $ns"
    sleep 5; waited=$((waited+5))
  done
}

wait_rollout() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-15m}"
  wait_resource_exists "$ns" "$kind" "$name"
  log "Waiting for rollout of $kind/$name in $ns..."
  kubectl -n "$ns" rollout status "$kind/$name" --timeout="$timeout"
  log "Rollout complete for $kind/$name"
}

wait_pod_identity_agent_best_effort() {
  local ns="kube-system" ds="eks-pod-identity-agent" timeout="${1:-180}"
  log "Best-effort wait for $ds (proceed if not 100% within ${timeout}s)..."
  if ! kubectl -n "$ns" rollout status "ds/$ds" --timeout="${timeout}s"; then
    local desired available
    desired=$(kubectl -n "$ns" get ds "$ds" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    available=$(kubectl -n "$ns" get ds "$ds" -o jsonpath='{.status.numberAvailable}' 2>/dev/null || echo 0)
    warn "DaemonSet $ds availability ${available}/${desired}; proceeding anyway."
  fi
}

find_deploy_by_selector() {
  local ns="$1" selector="$2"
  kubectl -n "$ns" get deploy -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# ---------- Autoscaler ----------
wait_autoscaler_rollout() {
  local rel="${AUTOSCALER_RELEASE}" ns="${AUTOSCALER_NS}"
  local selector="app.kubernetes.io/instance=${rel},app.kubernetes.io/name=aws-cluster-autoscaler"
  local deploy; deploy="$(find_deploy_by_selector "$ns" "$selector")"
  [[ -z "$deploy" ]] && deploy="$(find_deploy_by_selector "$ns" "app.kubernetes.io/instance=${rel}")"
  [[ -z "$deploy" ]] && err "Could not find Cluster Autoscaler deployment via labels (instance=${rel})"
  wait_rollout "$ns" deploy "$deploy"
}

install_nvidia_device_plugin() {
  local ver="${NVIDIA_VERSION:-v0.17.3}"
  log "Ensuring NVIDIA device plugin ($ver)..."
  kubectl apply -n kube-system -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${ver}/deployments/static/nvidia-device-plugin.yml"
  kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=10m || true
}

uncordon_ready_nodes() {
  log "Uncordoning any Ready but cordoned nodes..."
  for n in $(kubectl get nodes --no-headers | awk '/SchedulingDisabled/ {print $1}'); do
    if kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
      kubectl uncordon "$n" || true
    fi
  done
}

# ---------- OTEL Operator ----------
wait_otel_operator_rollout() {
  local ns="${OTEL_NS}" rel="${OTEL_OPERATOR_RELEASE}"
  local dep="${rel}-opentelemetry-operator"
  if kubectl -n "$ns" get deploy "$dep" >/dev/null 2>&1; then wait_rollout "$ns" deploy "$dep"; return; fi
  local found; found="$(find_deploy_by_selector "$ns" "app.kubernetes.io/instance=${rel},app.kubernetes.io/name=opentelemetry-operator")"
  if [[ -n "$found" ]]; then wait_rollout "$ns" deploy "$found"; return; fi
  if kubectl -n "$ns" get deploy otel-operator-opentelemetry-operator >/dev/null 2>&1; then
    wait_rollout "$ns" deploy otel-operator-opentelemetry-operator; return
  fi
  warn "Could not locate OTEL Operator deployment; diagnostics:"; kubectl -n "$ns" get deploy,po -o wide || true; helm -n "$ns" status "$rel" || true
  err "OpenTelemetry Operator deployment not found in $ns."
}

wait_otel_collector_rollout() { wait_rollout "${OTEL_NS}" deploy "${OTEL_COLLECTOR_CR}-collector"; }

wait_for_crd() {
  local crd="$1" timeout="${2:-300}" waited=0
  log "Waiting for CRD $crd to be established..."
  until kubectl get crd "$crd" >/dev/null 2>&1; do
    [[ $waited -ge $timeout ]] && err "CRD $crd not found after ${timeout}s"
    sleep 5; waited=$((waited+5))
  done
}

detect_otel_api_version() {
  local versions; versions=$(kubectl get crd opentelemetrycollectors.opentelemetry.io -o jsonpath='{range .spec.versions[*]}{.name}{" "}{end}' 2>/dev/null || true)
  if [[ "$versions" == *"v1beta1"* ]]; then echo "opentelemetry.io/v1beta1"; else echo "opentelemetry.io/v1alpha1"; fi
}

# ---------- Nodegroups ----------
generate_node_groups() {
  local nodes=""
  if [[ "$ENABLE_CPU" == "true" ]]; then
    nodes+="
  - name: cpu-nodes
    instanceType: ${CPU_INSTANCE_TYPE}
    desiredCapacity: ${CPU_DESIRED}
    minSize: ${CPU_MIN}
    maxSize: ${CPU_MAX}
    volumeSize: ${CPU_VOLUME_SIZE}
    volumeType: ${CPU_VOLUME_TYPE}
    tags:
      Name: ${CLUSTER_NAME}-cpu
      Environment: prod
      kubernetes.io/cluster/${CLUSTER_NAME}: owned
      k8s.io/cluster-autoscaler/enabled: \"true\"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: owned"
  fi
  # H100 with capacity reservation: node group created separately via CloudFormation
  # All other GPU types (L40S, H100_NVL): standard eksctl managed node group
  if [[ "$ENABLE_GPU" == "true" && "$DEFAULT_ACCELERATOR" == "H100" && -n "$GPU_CAPACITY_RESERVATION_ID" ]]; then
    log "GPU nodes will be created separately with capacity reservation ${GPU_CAPACITY_RESERVATION_ID}"
  elif [[ "$ENABLE_GPU" == "true" ]]; then
    nodes+="
  - name: gpu-nodes
    instanceType: ${GPU_INSTANCE_TYPE}
    desiredCapacity: ${GPU_DESIRED}
    minSize: ${GPU_MIN}
    maxSize: ${GPU_MAX}
    volumeSize: ${GPU_VOLUME_SIZE}
    volumeType: ${GPU_VOLUME_TYPE}"
    # Lock to specific AZ when availabilityZones are specified (e.g. for H100_NVL)
    if [[ ${#GPU_AVAILABILITY_ZONES[@]} -gt 0 ]]; then
      nodes+="
    availabilityZones:"
      for az in "${GPU_AVAILABILITY_ZONES[@]}"; do
        nodes+="
      - ${az}"
      done
    fi
    nodes+="
    tags:
      Name: ${CLUSTER_NAME}-gpu
      Environment: prod
      kubernetes.io/cluster/${CLUSTER_NAME}: owned
      k8s.io/cluster-autoscaler/enabled: \"true\"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: owned
    taints:
      - key: \"nvidia.com/gpu\"
        value: \"true\"
        effect: \"NoSchedule\""
  fi
  echo "$nodes"
}

# ---------- Cluster config / create ----------
create_cluster_config() {
  log "Generating cluster config..."

  # Build subnet configuration dynamically using AZ information from config
  local private_subnets="" public_subnets="" vpc_config=""

  # Check if subnets are provided
  if [[ ${#PRIVATE_SUBNETS[@]} -gt 0 || ${#PUBLIC_SUBNETS[@]} -gt 0 ]]; then
    # Private subnets - use actual AZ from config
    if [[ ${#PRIVATE_SUBNETS[@]} -gt 0 ]]; then
      local idx=0
      for subnet in "${PRIVATE_SUBNETS[@]}"; do
        local az="${PRIVATE_SUBNETS_AZ[$idx]}"
        private_subnets+="      ${az}: { id: ${subnet} }"$'\n'
        ((idx++))
      done
    fi

    # Public subnets - use actual AZ from config
    if [[ ${#PUBLIC_SUBNETS[@]} -gt 0 ]]; then
      local idx=0
      for subnet in "${PUBLIC_SUBNETS[@]}"; do
        local az="${PUBLIC_SUBNETS_AZ[$idx]}"
        public_subnets+="      ${az}: { id: ${subnet} }"$'\n'
        ((idx++))
      done
    fi

    # Build VPC config with subnets
    vpc_config="vpc:
  subnets:"
    if [[ -n "$private_subnets" ]]; then
      vpc_config+="
    private:
${private_subnets}"
    fi
    if [[ -n "$public_subnets" ]]; then
      vpc_config+="
    public:
${public_subnets}"
    fi
  else
    log "No subnets specified - eksctl will create new subnets automatically"
    # One NAT gateway => one Elastic IP. HighlyAvailable uses one NAT per AZ
    # (often 3 EIPs) and commonly trips the default regional EIP quota (5).
    vpc_config="vpc:
  nat:
    gateway: Single"
  fi

  cat <<EOF > eks-cluster-config.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "${K8S_VERSION}"
autoModeConfig:
  enabled: false
iam:
  withOIDC: true
addons:
  - name: vpc-cni
  - name: kube-proxy
  - name: coredns
  - name: eks-pod-identity-agent
${vpc_config}
managedNodeGroups:
$(generate_node_groups)
EOF
}

create_cluster() { log "Creating EKS cluster..."; eksctl create cluster -f eks-cluster-config.yaml; ensure_kubeconfig; }

# Create GPU node group with Capacity Block using CloudFormation.
# Only called when DEFAULT_ACCELERATOR=H100 and GPU_CAPACITY_RESERVATION_ID is set.
create_gpu_nodegroup_with_capacity_block() {
  if [[ "$DEFAULT_ACCELERATOR" != "H100" || -z "$GPU_CAPACITY_RESERVATION_ID" ]]; then
    return 0
  fi

  log "Creating GPU node group with Capacity Block (H100)..."
  log "  Reservation: ${GPU_CAPACITY_RESERVATION_ID} in ${GPU_CAPACITY_RESERVATION_AZ}"

  local stack_name="${CLUSTER_NAME}-gpu-capacity-block"
  local cfn_template_file="/tmp/${stack_name}-template.yaml"

  # Get cluster info
  local cluster_info vpc_id cluster_sg
  cluster_info=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --query 'cluster')
  vpc_id=$(echo "$cluster_info" | jq -r '.resourcesVpcConfig.vpcId')
  cluster_sg=$(echo "$cluster_info" | jq -r '.resourcesVpcConfig.clusterSecurityGroupId')
  log "  VPC: ${vpc_id}, Security Group: ${cluster_sg}"

  # Get EKS GPU AMI
  local ami_id
  ami_id=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2-gpu/recommended/image_id" \
    --region "${REGION}" --query 'Parameter.Value' --output text)
  log "  AMI: ${ami_id}"

  # Get node IAM role created by eksctl for the CPU node group
  local node_role_arn
  node_role_arn=$(aws iam list-roles \
    --query "Roles[?contains(RoleName, '${CLUSTER_NAME}') && contains(RoleName, 'NodeInstanceRole')].Arn" \
    --output text | head -1)
  log "  Node Role: ${node_role_arn}"

  if [[ -z "$node_role_arn" || "$node_role_arn" == "None" ]]; then
    err "Node role not found — ensure CPU node group was created first."
  fi

  # Find subnet in the capacity reservation AZ
  local subnet_id
  subnet_id=$(aws ec2 describe-subnets --region "${REGION}" \
    --filters "Name=availability-zone,Values=${GPU_CAPACITY_RESERVATION_AZ}" \
              "Name=vpc-id,Values=${vpc_id}" \
              "Name=tag:Name,Values=*eksctl-${CLUSTER_NAME}*Private*" \
    --query 'Subnets[0].SubnetId' --output text)
  if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
    subnet_id=$(aws ec2 describe-subnets --region "${REGION}" \
      --filters "Name=availability-zone,Values=${GPU_CAPACITY_RESERVATION_AZ}" \
                "Name=vpc-id,Values=${vpc_id}" \
      --query 'Subnets[0].SubnetId' --output text)
  fi
  if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
    err "Subnet not found in ${GPU_CAPACITY_RESERVATION_AZ} for VPC ${vpc_id}"
  fi
  log "  Subnet: ${subnet_id}"

  # Generate CloudFormation template
  cat > "${cfn_template_file}" <<CFEOF
AWSTemplateFormatVersion: '2010-09-09'
Description: 'EKS GPU Node Group with Capacity Block for H100'
Parameters:
  ClusterName:    { Type: String }
  ReservationId:  { Type: String }
  SubnetId:       { Type: String }
  NodeRoleArn:    { Type: String }
  SecurityGroupId:{ Type: String }
  AmiId:          { Type: String }
  InstanceType:   { Type: String }
  VolumeSize:     { Type: Number }
  DesiredCapacity:{ Type: Number }
Resources:
  GPULaunchTemplate:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateName: !Sub '\${ClusterName}-capacity-block-gpu'
      LaunchTemplateData:
        InstanceType: !Ref InstanceType
        ImageId: !Ref AmiId
        InstanceMarketOptions:
          MarketType: capacity-block
        CapacityReservationSpecification:
          CapacityReservationTarget:
            CapacityReservationId: !Ref ReservationId
        SecurityGroupIds:
          - !Ref SecurityGroupId
        BlockDeviceMappings:
          - DeviceName: /dev/xvda
            Ebs:
              VolumeSize: !Ref VolumeSize
              VolumeType: gp3
              DeleteOnTermination: true
        UserData:
          Fn::Base64: !Sub |
            #!/bin/bash
            set -ex
            /etc/eks/bootstrap.sh \${ClusterName} --kubelet-extra-args '--node-labels=eks.amazonaws.com/nodegroup=gpu-nodes,nvidia.com/gpu=true --register-with-taints=nvidia.com/gpu=true:NoSchedule'
        TagSpecifications:
          - ResourceType: instance
            Tags:
              - { Key: Name, Value: !Sub '\${ClusterName}-gpu-node' }
  GPUNodeGroup:
    Type: AWS::EKS::Nodegroup
    Properties:
      ClusterName: !Ref ClusterName
      NodegroupName: gpu-nodes
      NodeRole: !Ref NodeRoleArn
      Subnets:
        - !Ref SubnetId
      CapacityType: CAPACITY_BLOCK
      ScalingConfig:
        MinSize: !Ref DesiredCapacity
        MaxSize: !Ref DesiredCapacity
        DesiredSize: !Ref DesiredCapacity
      Labels:
        nvidia.com/gpu: "true"
      Taints:
        - { Key: nvidia.com/gpu, Value: "true", Effect: NO_SCHEDULE }
      LaunchTemplate:
        Id: !Ref GPULaunchTemplate
        Version: !GetAtt GPULaunchTemplate.LatestVersionNumber
CFEOF

  # Delete failed/rolled-back stack if present
  local stack_status
  stack_status=$(aws cloudformation describe-stacks --stack-name "${stack_name}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_EXISTS")

  if [[ "$stack_status" == "CREATE_COMPLETE" || "$stack_status" == "UPDATE_COMPLETE" ]]; then
    log "GPU node group already exists and is healthy — skipping."
    rm -f "${cfn_template_file}"; return 0
  elif [[ "$stack_status" != "NOT_EXISTS" ]]; then
    log "Deleting ${stack_status} stack before retry..."
    aws cloudformation delete-stack --stack-name "${stack_name}" --region "${REGION}"
    aws cloudformation wait stack-delete-complete --stack-name "${stack_name}" --region "${REGION}" || true
  fi

  aws cloudformation deploy \
    --template-file "${cfn_template_file}" \
    --stack-name "${stack_name}" \
    --region "${REGION}" \
    --parameter-overrides \
      ClusterName="${CLUSTER_NAME}" \
      ReservationId="${GPU_CAPACITY_RESERVATION_ID}" \
      SubnetId="${subnet_id}" \
      NodeRoleArn="${node_role_arn}" \
      SecurityGroupId="${cluster_sg}" \
      AmiId="${ami_id}" \
      InstanceType="${GPU_INSTANCE_TYPE}" \
      VolumeSize="${GPU_VOLUME_SIZE}" \
      DesiredCapacity="${GPU_DESIRED}" \
    --capabilities CAPABILITY_IAM \
    --no-fail-on-empty-changeset

  rm -f "${cfn_template_file}"

  local final_status
  final_status=$(aws cloudformation describe-stacks --stack-name "${stack_name}" --region "${REGION}" \
    --query 'Stacks[0].StackStatus' --output text)
  if [[ "$final_status" != "CREATE_COMPLETE" && "$final_status" != "UPDATE_COMPLETE" ]]; then
    err "CloudFormation stack failed: ${final_status}. Check: aws cloudformation describe-stack-events --stack-name ${stack_name} --region ${REGION}"
  fi

  log "GPU node group with Capacity Block created successfully."
  log "Waiting for nodes to join cluster..."
  sleep 30
  kubectl get nodes -l nvidia.com/gpu=true 2>/dev/null || log "(Nodes may still be joining...)"
}

ensure_oidc() {
  log "Ensuring IAM OIDC provider is associated..."

  # First check if cluster has OIDC issuer configured
  local issuer; issuer=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)
  if [[ -z "$issuer" || "$issuer" == "None" ]]; then
    log "Cluster does not have OIDC issuer configured. Associating OIDC provider..."
    if ! eksctl utils associate-iam-oidc-provider --region "${REGION}" --cluster "${CLUSTER_NAME}" --approve; then
      err "Failed to associate OIDC provider with cluster"
    fi
    # Re-fetch issuer after association
    issuer=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)
  fi

  log "Cluster OIDC issuer: ${issuer}"

  # Check if IAM OIDC provider actually exists
  log "Checking if IAM OIDC provider exists..."
  local oidc_arn; oidc_arn="$(get_oidc_provider_arn || true)"

  if [[ -z "$oidc_arn" ]]; then
    log "OIDC provider ARN not found. Creating IAM OIDC provider..."
    if ! eksctl utils associate-iam-oidc-provider --region "${REGION}" --cluster "${CLUSTER_NAME}" --approve; then
      err "Failed to create IAM OIDC provider"
    fi
    # Re-fetch ARN after creation
    oidc_arn="$(get_oidc_provider_arn || true)"
  fi

  # Verify OIDC provider exists in IAM
  log "Verifying IAM OIDC provider exists: ${oidc_arn}"
  if [[ -z "$oidc_arn" ]]; then
    err "OIDC provider ARN still not found after association. Cannot proceed with IRSA creation."
  fi

  if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" >/dev/null 2>&1; then
    log "IAM OIDC provider not found in IAM. Creating it now..."
    if ! eksctl utils associate-iam-oidc-provider --region "${REGION}" --cluster "${CLUSTER_NAME}" --approve; then
      err "Failed to create IAM OIDC provider even after retry"
    fi

    # Final verification
    sleep 5  # Give IAM a moment to propagate
    if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" >/dev/null 2>&1; then
      err "OIDC provider ARN $oidc_arn not found in IAM after creation. IAM propagation may be delayed."
    fi
  fi

  log "✓ OIDC provider is ready: $oidc_arn"
  log "✓ IAM OIDC provider verified in IAM"
}

# ---------- EBS CSI via IRSA ----------
install_ebs_csi_addon() {
  log "Installing aws-ebs-csi-driver add-on with IRSA..."

  # Verify IAM role exists before creating addon
  log "Verifying EBS CSI IAM role exists..."
  if ! aws iam get-role --role-name "${EBS_IRSA_ROLE_NAME}" >/dev/null 2>&1; then
    err "IAM role ${EBS_IRSA_ROLE_NAME} does not exist. Cannot create addon."
  fi
  log "✓ IAM role ${EBS_IRSA_ROLE_NAME} exists"

  # Use eksctl to create addon with IRSA
  log "Creating aws-ebs-csi-driver addon..."
  if ! eksctl create addon \
    --cluster "${CLUSTER_NAME}" \
    --name aws-ebs-csi-driver \
    --service-account-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${EBS_IRSA_ROLE_NAME}" \
    --force; then
    warn "Addon creation command failed. Checking if addon already exists..."
    # Check if addon exists (idempotent behavior)
    if aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
      log "Addon already exists, continuing..."
    else
      err "Failed to create EBS CSI addon. Check: aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name aws-ebs-csi-driver"
    fi
  fi

  # Wait for addon to become ACTIVE and pods to be ready
  log "Waiting for EBS CSI addon to become ACTIVE (max 10 minutes)..."
  local waited=0
  local max_wait=600  # 10 minutes
  while [[ $waited -lt $max_wait ]]; do
    local addon_status; addon_status="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver --query 'addon.status' --output text 2>/dev/null || echo "UNKNOWN")"

    if [[ "$addon_status" == "ACTIVE" ]]; then
      log "✓ EBS CSI addon is ACTIVE"
      break
    elif [[ "$addon_status" == "CREATE_FAILED" ]]; then
      err "Addon creation failed! Check: aws eks describe-addon --cluster-name ${CLUSTER_NAME} --addon-name aws-ebs-csi-driver"
    elif [[ "$addon_status" == "CREATING" ]]; then
      # Check if pods are running even if addon status is still CREATING
      local controller_ready
      controller_ready=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')

      if [[ $controller_ready -ge 2 ]]; then
        log "✓ EBS CSI controller pods are running (${controller_ready} replicas), addon status: ${addon_status}"
        log "Continuing with installation (addon may still be finalizing)"
        break
      fi

      log "EBS CSI addon status: ${addon_status}, waiting for pods to be ready (${controller_ready} running)..."
    fi

    sleep 10; waited=$((waited+10))
  done

  # Check if we timed out
  if [[ $waited -ge $max_wait ]]; then
    local final_status; final_status="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name aws-ebs-csi-driver --query 'addon.status' --output text 2>/dev/null || echo "UNKNOWN")"
    warn "Timeout waiting for EBS CSI addon to become ACTIVE. Current status: ${final_status}"

    # Check if pods are healthy despite addon status
    local controller_ready
    controller_ready=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')

    if [[ $controller_ready -ge 2 ]]; then
      log "✓ EBS CSI controller pods are running (${controller_ready} replicas), continuing despite addon status"
      warn "Addon status may take longer to update, but functionality should work"
    else
      err "EBS CSI addon timeout and pods not ready. Check: kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver"
    fi
  fi

  # Final verification - check pods are actually ready
  log "Verifying EBS CSI controller pods are ready..."
  local retries=0
  while [[ $retries -lt 30 ]]; do
    local ready_count
    ready_count=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -o "True" | wc -l | tr -d ' ')

    if [[ $ready_count -ge 2 ]]; then
      log "✓ EBS CSI controller has ${ready_count} ready pods"
      break
    fi

    log "Waiting for EBS CSI pods to become ready (${ready_count}/2)..."
    sleep 5
    ((retries++))
  done
}

ensure_ebs_irsa_role() {
  log "Ensuring EBS CSI IRSA role and service account..."

  # Create IRSA for EBS CSI using eksctl (handles role creation, trust policy, and SA annotation)
  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --namespace "${EBS_NS}" \
    --name "${EBS_SA}" \
    --role-name "${EBS_IRSA_ROLE_NAME}" \
    --attach-policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" \
    --approve \
    --override-existing-serviceaccounts

  log "✓ EBS CSI IRSA role and service account configured"
}

verify_ebs_csi_ready() {
  log "Verifying EBS CSI controller is ready..."

  # Wait for deployment to exist
  local waited=0
  while [[ $waited -lt 120 ]]; do
    if kubectl get deployment -n kube-system ebs-csi-controller >/dev/null 2>&1; then
      log "✓ EBS CSI controller deployment exists"; break
    fi
    sleep 5; waited=$((waited+5))
  done

  # Wait for rollout to complete
  log "Waiting for EBS CSI controller rollout (max 5 minutes)..."
  kubectl rollout status deployment -n kube-system ebs-csi-controller --timeout=5m || {
    warn "Rollout timeout - checking pod status..."
    kubectl get pods -n kube-system -l app=ebs-csi-controller
  }

  # Also ensure daemonset is ready
  log "Checking EBS CSI node daemonset..."
  kubectl rollout status ds -n kube-system ebs-csi-node --timeout=3m || true
}

create_gp3_storageclass() {
  log "Creating gp3 StorageClass and setting default..."
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
  for sc in $(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}'); do
    if [[ "$sc" != "gp3" ]]; then kubectl patch sc "$sc" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null || true; fi
  done
}

# ---------- Autoscaler ----------
get_autoscaler_version() {
  local k8s_version="$1"
  # Extract major.minor (e.g., "v1.31" from "v1.31.13")
  local k8s_minor=$(echo "$k8s_version" | cut -d'.' -f1-2)

  # Map K8s version to EKS-compatible cluster-autoscaler versions
  # EKS supports 1.31+ (1.31 will move to extended support soon, recommending 1.32+)
  # EKS K8s patch versions (e.g., 1.31.13) are higher than autoscaler patch versions
  # Use the latest available autoscaler for each K8s minor version
  # To verify: skopeo list-tags docker://registry.k8s.io/autoscaling/cluster-autoscaler | grep "v1.34"
  case "$k8s_minor" in
    v1.34) echo "v1.34.1" ;;  # Latest for EKS 1.34.x
    v1.33) echo "v1.33.2" ;;  # Latest for EKS 1.33.x
    v1.32) echo "v1.32.4" ;;  # Latest for EKS 1.32.x
    v1.31) echo "v1.31.5" ;;  # Latest for EKS 1.31.x (moving to extended support)
    *)
      # For future versions or unknown versions, try .0 and warn
      warn "K8s version ${k8s_minor} not explicitly mapped. Using ${k8s_minor}.0"
      warn "If this fails, update get_autoscaler_version() with the correct autoscaler version"
      echo "${k8s_minor}.0"
      ;;
  esac
}

install_cluster_autoscaler() {
  log "Installing Cluster Autoscaler with IRSA..."
  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --name "${AUTOSCALER_SA}" \
    --namespace "${AUTOSCALER_NS}" \
    --role-name "${AUTOSCALER_ROLE_NAME}" \
    --attach-policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess \
    --approve \
    --override-existing-serviceaccounts

  helm repo add autoscaler https://kubernetes.github.io/autoscaler
  helm repo update

  # Get appropriate autoscaler version for the K8s version
  local autoscaler_version=$(get_autoscaler_version "${K8S_PATCH_VERSION}")
  log "Using cluster-autoscaler image tag: ${autoscaler_version} (K8s version: ${K8S_PATCH_VERSION})"

  helm_retry 5 upgrade --install "${AUTOSCALER_RELEASE}" autoscaler/cluster-autoscaler \
    --namespace "${AUTOSCALER_NS}" \
    --set autoDiscovery.clusterName="${CLUSTER_NAME}" \
    --set awsRegion="${REGION}" \
    --set rbac.serviceAccount.create=false \
    --set rbac.serviceAccount.name="${AUTOSCALER_SA}" \
    --set image.repository=registry.k8s.io/autoscaling/cluster-autoscaler \
    --set image.tag="${autoscaler_version}" \
    --set extraArgs.balance-similar-node-groups=true \
    --set extraArgs.skip-nodes-with-system-pods=false \
    --set extraArgs.expander=least-waste \
    --wait --timeout 15m

  wait_autoscaler_rollout
}

install_kube_prometheus() {
  log "Installing kube-prometheus-stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts; helm repo update
  helm_retry 5 upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --wait --timeout 15m
  check_ready monitoring "app.kubernetes.io/instance=kube-prometheus"
}

install_cert_manager() {
  log "Installing cert-manager..."
  helm repo add jetstack https://charts.jetstack.io; helm repo update
  helm_retry 5 upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace --set installCRDs=true \
    --wait --timeout 15m
  check_ready cert-manager "app.kubernetes.io/instance=cert-manager,app.kubernetes.io/component=controller"
}

# ---------- AWS Load Balancer Controller (LBC) ----------
# LBC watches Services with the "aws-load-balancer-type: external" annotation
# (the in-tree cloud controller skips those Services on purpose) and drives
# NLB/ALB provisioning through the AWS ELBv2 API. Without LBC installed, such
# Services stay in EXTERNAL-IP=<pending> forever. LBC also gives us IP-mode
# targeting, ACM-backed TLS termination, and modern NLB attributes — all
# features the in-tree controller does not support.

# Fetches the upstream-recommended IAM policy for LBC from a pinned git tag and
# creates a customer-managed policy in the account (idempotent). Emits the ARN
# on stdout so the caller can attach it via eksctl. Uses a cluster-scoped name
# so teardown of one cluster won't remove a policy shared with other clusters.
ensure_lbc_iam_policy() {
  # Resolve the caller's account ID; construct the canonical policy ARN
  # deterministically (IAM policy names are unique per account). This avoids
  # parsing AWS CLI text output -- some CLI/JMESPath combinations have been
  # observed to emit multi-line "None\nNone" for `Policies[?...].Arn | [0]`
  # when no match exists, which would otherwise slip past a "!= None" guard.
  local acct policy_arn
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$acct" || ! "$acct" =~ ^[0-9]{12}$ ]]; then
    err "Could not resolve a valid AWS account ID via STS (got: '${acct}')"
  fi
  policy_arn="arn:aws:iam::${acct}:policy/${LBC_POLICY_NAME}"

  if aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
    log "✓ LBC IAM policy already exists: ${policy_arn}" >&2
    printf "%s" "$policy_arn"
    return 0
  fi

  local tmp; tmp="$(mktemp)"; TMP_FILES+=("$tmp")
  local url="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_POLICY_VERSION}/docs/install/iam_policy.json"
  log "Fetching LBC IAM policy ${LBC_POLICY_VERSION} from ${url}" >&2
  if ! curl -fsSL --max-time 60 "$url" -o "$tmp"; then
    err "Failed to download AWS LBC IAM policy from ${url}. Check network access or bump LBC_POLICY_VERSION."
  fi
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    err "Downloaded LBC IAM policy is not valid JSON. Refusing to proceed."
  fi

  local created
  created="$(aws iam create-policy \
    --policy-name "${LBC_POLICY_NAME}" \
    --policy-document "file://${tmp}" \
    --description "AWS Load Balancer Controller policy for ${CLUSTER_NAME} (${LBC_POLICY_VERSION})" \
    --query 'Policy.Arn' --output text 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "$created" || "$created" != arn:aws:iam::* ]]; then
    err "create-policy did not return a valid ARN for ${LBC_POLICY_NAME} (got: '${created}')"
  fi
  log "✓ Created LBC IAM policy ${LBC_POLICY_NAME}: ${created}" >&2
  printf "%s" "$created"
}

# Creates the IRSA-bound ServiceAccount used by the LBC deployment. Uses eksctl
# so the trust policy is pinned to this cluster's OIDC provider and SA subject.
ensure_lbc_irsa() {
  log "Ensuring IRSA for AWS Load Balancer Controller (${LBC_NS}/${LBC_SA})..."
  local policy_arn; policy_arn="$(ensure_lbc_iam_policy)"
  if [[ -z "$policy_arn" || "$policy_arn" != arn:aws:iam::* ]]; then
    err "LBC IAM policy ARN is empty/invalid ('${policy_arn}'); cannot configure IRSA"
  fi

  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --namespace "${LBC_NS}" \
    --name "${LBC_SA}" \
    --role-name "${LBC_ROLE_NAME}" \
    --attach-policy-arn "${policy_arn}" \
    --approve \
    --override-existing-serviceaccounts

  wait_resource_exists "${LBC_NS}" sa "${LBC_SA}" 180
  log "✓ LBC IRSA role and service account configured"
}

# Tags user-provided subnets so LBC can auto-discover where to place LBs.
# eksctl already tags subnets it creates, so this is a no-op when the cluster
# was created without explicit cluster.subnets.
tag_lbc_subnets() {
  if [[ ${#PUBLIC_SUBNETS[@]} -eq 0 && ${#PRIVATE_SUBNETS[@]} -eq 0 ]]; then
    log "No user-provided subnets; eksctl-created subnets are already tagged for LBC discovery."
    return 0
  fi
  log "Tagging user-provided subnets for AWS Load Balancer Controller discovery..."
  if [[ ${#PUBLIC_SUBNETS[@]} -gt 0 ]]; then
    log "  Public subnets (${#PUBLIC_SUBNETS[@]}): kubernetes.io/role/elb=1"
    aws ec2 create-tags --region "${REGION}" \
      --resources "${PUBLIC_SUBNETS[@]}" \
      --tags Key=kubernetes.io/role/elb,Value=1 \
             "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared"
  fi
  if [[ ${#PRIVATE_SUBNETS[@]} -gt 0 ]]; then
    log "  Private subnets (${#PRIVATE_SUBNETS[@]}): kubernetes.io/role/internal-elb=1"
    aws ec2 create-tags --region "${REGION}" \
      --resources "${PRIVATE_SUBNETS[@]}" \
      --tags Key=kubernetes.io/role/internal-elb,Value=1 \
             "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared"
  fi
  log "✓ Subnets tagged for LBC auto-discovery"
}

install_aws_load_balancer_controller() {
  log "Installing AWS Load Balancer Controller (helm chart ${LBC_CHART_VERSION})..."

  local vpc_id
  vpc_id="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    err "Could not determine VPC ID for cluster ${CLUSTER_NAME}. LBC install requires vpcId."
  fi

  if ! aws iam get-role --role-name "${LBC_ROLE_NAME}" >/dev/null 2>&1; then
    err "IRSA role ${LBC_ROLE_NAME} not found. ensure_lbc_irsa must run first."
  fi

  helm repo add eks https://aws.github.io/eks-charts >/dev/null
  helm repo update >/dev/null
  helm_retry 5 upgrade --install "${LBC_RELEASE}" eks/aws-load-balancer-controller \
    --namespace "${LBC_NS}" \
    --version "${LBC_CHART_VERSION}" \
    --set clusterName="${CLUSTER_NAME}" \
    --set region="${REGION}" \
    --set vpcId="${vpc_id}" \
    --set serviceAccount.create=false \
    --set serviceAccount.name="${LBC_SA}" \
    --wait --timeout 10m

  check_ready "${LBC_NS}" "app.kubernetes.io/name=aws-load-balancer-controller"
  log "✓ AWS Load Balancer Controller ${LBC_CHART_VERSION} installed and ready"
}

# ---------- External S3-compatible object storage (credentials only; no in-cluster install) ----------
ensure_s3compat_credentials() {
  # Only create credentials secret when using external S3-compatible storage (s3compat, minio, seaweedfs).
  if [[ "${USE_EXTERNAL_OBJ_STORE}" != "true" ]]; then
    return 0
  fi

  log "Object store type is ${OBJ_STORE_TYPE}; creating credentials secret for external S3-compatible storage."
  if [[ -z "${OBJ_STORE_ENDPOINT}" && -z "${MINIO_ENDPOINT}" ]]; then
    err "storage.objectStore.type=${OBJ_STORE_TYPE} requires storage.objectStore.endpoint"
    return 1
  fi
  if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
    err "External S3-compatible storage requires credentials (objectStore.auth.rootPassword or MINIO_ROOT_PASSWORD)"
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
  log "✓ External S3-compatible credentials secret ${AI_NS}/${secret_name} ready"
}

# ---------- OTEL Operator + contrib collector (idempotent) ----------
install_otel_operator_and_contrib_collector() {
  log "Installing OpenTelemetry Operator (Helm)..."
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts; helm repo update
  helm_retry 5 upgrade --install "${OTEL_OPERATOR_RELEASE}" open-telemetry/opentelemetry-operator \
    --namespace "${OTEL_NS}" --create-namespace --set admissionWebhooks.certManager.enabled=true \
    --wait --timeout 15m
  wait_otel_operator_rollout
  wait_for_crd opentelemetrycollectors.opentelemetry.io 300

  local apiversion; apiversion="$(detect_otel_api_version)"; log "Using OpenTelemetryCollector apiVersion: ${apiversion}"
  if [[ "$apiversion" == "opentelemetry.io/v1beta1" ]]; then
    cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: ${apiversion}
kind: OpenTelemetryCollector
metadata:
  name: ${OTEL_COLLECTOR_CR}
  namespace: ${OTEL_NS}
spec:
  image: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest
  mode: deployment
  replicas: 1
  config:
    receivers:
      otlp:
        protocols: { grpc: {}, http: {} }
    processors: { batch: {} }
    exporters: { debug: {} }
    service:
      pipelines:
        traces:  { receivers: [otlp], processors: [batch], exporters: [debug] }
        metrics: { receivers: [otlp], processors: [batch], exporters: [debug] }
        logs:    { receivers: [otlp], processors: [batch], exporters: [debug] }
YAML
  else
    cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: ${OTEL_COLLECTOR_CR}
  namespace: ${OTEL_NS}
spec:
  image: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest
  mode: deployment
  replicas: 1
  config: |
    receivers:
      otlp:
        protocols:
          grpc: {}
          http: {}
    processors:
      batch: {}
    exporters:
      debug: {}
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
        logs:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
YAML
  fi
  wait_otel_collector_rollout
}

# ---------- Ray Operator ----------
install_ray_operator() {
  log "Installing Ray Operator ${RAY_VERSION}..."
  kubectl apply -k "github.com/ray-project/kuberay/ray-operator/config/default?ref=${RAY_VERSION}" --server-side --force-conflicts
  wait_rollout ray-system deploy kuberay-operator
}

# ---------- Splunk Operator(s) ----------
install_splunk_operator() {
  log "Installing Splunk Operator (cluster-scope manifest in CWD)..."
  need_file "${SPLUNK_OPERATOR_FILE}"
  kubectl apply -f "${SPLUNK_OPERATOR_FILE}" --server-side --force-conflicts
  local splunk_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_IMAGE")
  kubectl set env deployment/splunk-operator-controller-manager -n splunk-operator RELATED_IMAGE_SPLUNK_ENTERPRISE="${splunk_full}"
  kubectl set env deployment/splunk-operator-controller-manager -n splunk-operator SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
  check_ready splunk-operator "name=splunk-operator"
  wait_for_crd standalones.enterprise.splunk.com 600
}

install_splunk_ai_operator() {
  log "Installing Splunk AI Operator from ${SPLUNK_AI_FILE}..."
  need_file "${SPLUNK_AI_FILE}"
  kubectl get ns "${SPLUNK_AI_NS}" >/dev/null 2>&1 || kubectl create ns "${SPLUNK_AI_NS}"
  kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}"
  local dep; dep="$(find_deploy_by_selector "${SPLUNK_AI_NS}" "app.kubernetes.io/name=splunk-ai-operator")"
  if [[ -z "$dep" ]]; then dep="$(kubectl -n "${SPLUNK_AI_NS}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 -E 'splunk-ai-operator|ai-operator')"; fi
  [[ -z "$dep" ]] && { kubectl -n "${SPLUNK_AI_NS}" get deploy,po -o wide || true; err "Could not detect Splunk AI Operator deployment in ${SPLUNK_AI_NS}."; }
  wait_rollout "${SPLUNK_AI_NS}" deploy "${dep}"
  wait_for_crd aiplatforms.ai.splunk.com 600
  log "Splunk AI Operator ready (ns=${SPLUNK_AI_NS}, deploy=${dep})"
}

# ---------- S3 bucket + AI namespace + IRSA SAs ----------
ensure_s3_bucket_and_prefixes() {
  log "Ensuring S3 bucket s3://${S3_BUCKET} in ${REGION}"
  if ! aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
    log "Creating bucket ${S3_BUCKET}"
    aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${REGION}" --create-bucket-configuration LocationConstraint="${REGION}"
    aws s3api put-bucket-versioning --bucket "${S3_BUCKET}" --versioning-configuration Status=Enabled
  else
    log "Bucket ${S3_BUCKET} exists"
  fi
  for key in "${S3_PREFIXES[@]}"; do
    log "Ensuring prefix ${key}"; aws s3api put-object --bucket "${S3_BUCKET}" --key "${key}" >/dev/null
  done
}

ensure_s3_upload_splunk_app() {
  if [[ -z "${SPLUNK_APP_LOCAL_PATH}" ]]; then
    log "SPLUNK_APP_LOCAL_PATH not set; skipping app upload to s3://${S3_BUCKET}/apps/"
    return 0
  fi
  if [[ ! -f "${SPLUNK_APP_LOCAL_PATH}" ]]; then
    warn "SPLUNK_APP_LOCAL_PATH='${SPLUNK_APP_LOCAL_PATH}' not found; skipping upload"
    return 0
  fi
  local base key
  base="$(basename "${SPLUNK_APP_LOCAL_PATH}")"
  key="apps/${base}"
  log "Ensuring Splunk app '${base}' exists at s3://${S3_BUCKET}/${key}"
  if aws s3api head-object --bucket "${S3_BUCKET}" --key "${key}" >/dev/null 2>&1; then
    log "App already present at s3://${S3_BUCKET}/${key}; skipping upload"
  else
    aws s3 cp "${SPLUNK_APP_LOCAL_PATH}" "s3://${S3_BUCKET}/${key}"
    log "Uploaded ${base} to s3://${S3_BUCKET}/${key}"
  fi
}

ensure_external_objstore_upload_splunk_app() {
  if [[ -z "${SPLUNK_APP_LOCAL_PATH}" ]]; then
    log "SPLUNK_APP_LOCAL_PATH not set; skipping app upload to ${OBJ_STORE_TYPE}://${OBJ_STORE_BUCKET}/apps/"
    return 0
  fi
  if [[ ! -f "${SPLUNK_APP_LOCAL_PATH}" ]]; then
    warn "SPLUNK_APP_LOCAL_PATH='${SPLUNK_APP_LOCAL_PATH}' not found; skipping upload"
    return 0
  fi
  if [[ -z "${OBJ_STORE_ENDPOINT}" ]]; then
    warn "OBJ_STORE_ENDPOINT not set; cannot upload Splunk app to external object store"
    return 0
  fi

  local base key
  base="$(basename "${SPLUNK_APP_LOCAL_PATH}")"
  key="apps/${base}"
  log "Ensuring Splunk app '${base}' exists at ${OBJ_STORE_TYPE}://${OBJ_STORE_BUCKET}/${key}"

  if AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
    aws --endpoint-url "${OBJ_STORE_ENDPOINT}" s3api head-object --bucket "${OBJ_STORE_BUCKET}" --key "${key}" >/dev/null 2>&1; then
    log "App already present at ${OBJ_STORE_TYPE}://${OBJ_STORE_BUCKET}/${key}; skipping upload"
  else
    AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
      aws --endpoint-url "${OBJ_STORE_ENDPOINT}" s3 cp "${SPLUNK_APP_LOCAL_PATH}" "s3://${OBJ_STORE_BUCKET}/${key}"
    log "Uploaded ${base} to ${OBJ_STORE_TYPE}://${OBJ_STORE_BUCKET}/${key}"
  fi
}

should_wait_for_splunk_app_install() {
  [[ -n "${SPLUNK_APP_LOCAL_PATH:-}" && -f "${SPLUNK_APP_LOCAL_PATH}" ]]
}

ensure_namespace() { kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1"; }

ensure_bucket_policy() {
  local name="$1" bucket="$2"

  # Fast path – expected ARN already exists
  local expected_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${name}"
  if aws iam get-policy --policy-arn "$expected_arn" >/dev/null 2>&1; then
    printf "%s" "$expected_arn"
    return 0
  fi

  # Try to find an existing policy by name
  local arn
  arn="$(get_policy_arn_by_name "$name")"
  if [[ -z "$arn" ]]; then
    log "Creating IAM policy ${name} for bucket ${bucket}"
    local pd; pd="$(mktemp)"; TMP_FILES+=("$pd")
    cat > "$pd" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid":"ListBucket","Effect":"Allow","Action":["s3:ListBucket"],"Resource":"arn:aws:s3:::${bucket}" },
    { "Sid":"ObjectRW","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts","s3:ListBucketMultipartUploads"],"Resource":"arn:aws:s3:::${bucket}/*" }
  ]
}
EOF
    # Create, but gracefully handle "EntityAlreadyExists"
    local create_out rc
    set +e
    create_out="$(aws iam create-policy \
                    --policy-name "${name}" \
                    --policy-document "file://${pd}" \
                    --query 'Policy.Arn' --output text 2>&1)"
    rc=$?
    set -e
    if (( rc == 0 )); then
      arn="$(normalize_arn "$create_out")"
    else
      if grep -qi 'EntityAlreadyExists' <<<"$create_out"; then
        arn="$(get_policy_arn_by_name "$name")"
      else
        err "Failed to create IAM policy ${name}: $create_out"
      fi
    fi
  fi

  arn="$(normalize_arn "$arn")"
  [[ -z "$arn" ]] && err "Failed to resolve ARN for policy ${name}"
  printf "%s" "$arn"
}

# ECR-only policy for IRSA when using MinIO (no S3) - allows pulling images from ECR
ensure_ecr_only_policy() {
  local name="${AI_ECR_ONLY_POLICY_NAME}"
  local expected_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${name}"
  if aws iam get-policy --policy-arn "$expected_arn" >/dev/null 2>&1; then
    printf "%s" "$expected_arn"
    return 0
  fi
  local arn
  arn="$(get_policy_arn_by_name "$name")"
  if [[ -z "$arn" ]]; then
    log "Creating IAM policy ${name} (ECR read-only, for MinIO-only mode)"
    local pd; pd="$(mktemp)"; TMP_FILES+=("$pd")
    cat > "$pd" <<'ECRPOL'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:*:*:repository/*"
    }
  ]
}
ECRPOL
    local create_out rc
    set +e
    create_out="$(aws iam create-policy --policy-name "${name}" --policy-document "file://${pd}" --query 'Policy.Arn' --output text 2>&1)"
    rc=$?
    set -e
    if (( rc == 0 )); then
      arn="$(normalize_arn "$create_out")"
    else
      if grep -qi 'EntityAlreadyExists' <<<"$create_out"; then
        arn="$(get_policy_arn_by_name "$name")"
      else
        err "Failed to create IAM policy ${name}: $create_out"
      fi
    fi
  fi
  arn="$(normalize_arn "$arn")"
  [[ -z "$arn" ]] && err "Failed to resolve ARN for policy ${name}"
  printf "%s" "$arn"
}

# ------- IRSA helpers: ensure & validate -------
generate_irsa_trust_policy() {
  local ns="$1" sa="$2"
  local oidc_arn; oidc_arn="$(get_oidc_provider_arn)" || err "No OIDC provider for cluster"
  local host; host="$(get_oidc_hostpath)" || err "No OIDC issuer hostpath"
  local f; f="$(mktemp)"; TMP_FILES+=("$f")
  cat >"$f" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${oidc_arn}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${host}:aud": "sts.amazonaws.com",
          "${host}:sub": "system:serviceaccount:${ns}:${sa}"
        }
      }
    }
  ]
}
EOF
  printf "%s" "$f"
}

validate_irsa_for_sa() {
  local ns="$1" sa="$2"
  local sa_role_arn role_name trust doc host oidc_arn sub_ok aud_ok prov_ok
  sa_role_arn="$(kubectl -n "$ns" get sa "$sa" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)"
  if [[ -z "$sa_role_arn" ]]; then
    warn "SA ${ns}/${sa} has no eks.amazonaws.com/role-arn annotation"; return 1
  fi
  role_name="${sa_role_arn##*/}"
  if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    warn "IAM role ${role_name} (from SA annotation) does not exist"; return 2
  fi
  oidc_arn="$(get_oidc_provider_arn)" || { warn "Cannot compute OIDC provider ARN"; return 3; }
  host="$(get_oidc_hostpath)" || { warn "Cannot compute OIDC hostpath"; return 3; }

  doc="$(aws iam get-role --role-name "$role_name" --query 'Role.AssumeRolePolicyDocument' --output json)"
  prov_ok="$(grep -F "\"${oidc_arn}\"" <<<"$doc" >/dev/null && echo yes || echo no)"
  sub_ok="$(grep -F "\"${host}:sub\": \"system:serviceaccount:${ns}:${sa}\"" <<<"$doc" >/dev/null && echo yes || echo no)"
  aud_ok="$(grep -F "\"${host}:aud\": \"sts.amazonaws.com\"" <<<"$doc" >/dev/null && echo yes || echo no)"

  if [[ "$prov_ok" == yes && "$sub_ok" == yes && "$aud_ok" == yes ]]; then
    log "IRSA OK for ${ns}/${sa} (role ${role_name})"
    return 0
  fi
  warn "IRSA trust mismatch for ${ns}/${sa} (role ${role_name}); provider:${prov_ok} sub:${sub_ok} aud:${aud_ok}"
  return 4
}

ensure_irsa_for_sa() {
  local sa="$1" ns="$2" policy_arn_raw="${3:-}"
  local role="IRSA-${CLUSTER_NAME}-${sa}"

  # Fail fast if kubectl cannot reach the cluster (e.g. wrong KUBECONFIG or context)
  local kerr
  kerr="$(kubectl get ns "${ns}" 2>&1)" || true
  if echo "${kerr}" | grep -q "connection refused\|localhost:8080\|dial tcp.*8080"; then
    err "kubectl cannot reach the cluster (API server connection refused). \
Fix: run 'aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}' and ensure KUBECONFIG (if set) points to that file. \
Then re-run this script."
  fi
  if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
    err "Cannot access namespace ${ns} (kubectl get ns failed). Ensure the cluster is reachable and the namespace exists."
  fi

  # Resolve/repair policy ARN if invalid
  local policy_arn; policy_arn="$(normalize_arn "$policy_arn_raw")"
  if [[ -z "$policy_arn" || $policy_arn != arn:aws:iam::* ]]; then
    warn "Policy ARN provided for ${ns}/${sa} is empty/invalid ('${policy_arn_raw}'). Re-resolving via policy name ${AI_BUCKET_POLICY_NAME}…"
    policy_arn="$(ensure_bucket_policy "${AI_BUCKET_POLICY_NAME}" "${S3_BUCKET}")"
  fi

  if ! aws iam get-policy --policy-arn "$policy_arn" >/dev/null 2>&1; then
    err "IAM policy ARN not found after re-resolve: ${policy_arn} (needed for ${ns}/${sa})."
  fi

  # Ensure SA+Role via eksctl (idempotent)
  log "Ensuring IRSA (role ${role}) for ${ns}/${sa} with policy ${policy_arn}"
  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --region "${REGION}" \
    --namespace "${ns}" \
    --name "${sa}" \
    --role-name "${role}" \
    --attach-policy-arn "${policy_arn}" \
    --approve \
    --override-existing-serviceaccounts

  wait_resource_exists "${ns}" sa "${sa}" 180

  # Extra safety: ensure policy attached (covers legacy/external roles)
  ensure_role_has_policy "${role}" "${policy_arn}"

  # Ensure trust policy matches this cluster/SA (fix if drifted)
  local trust_file; trust_file="$(generate_irsa_trust_policy "${ns}" "${sa}")"
  aws iam update-assume-role-policy --role-name "${role}" --policy-document "file://${trust_file}"

  # Ensure SA annotation is correct
  local role_arn; role_arn="$(aws iam get-role --role-name "${role}" --query 'Role.Arn' --output text)"
  local sa_ann; sa_ann="$(kubectl -n "$ns" get sa "$sa" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)"
  if [[ "$sa_ann" != "$role_arn" ]]; then
    log "Patching SA ${ns}/${sa} annotation to ${role_arn}"
    kubectl -n "$ns" patch sa "$sa" --type=merge -p "{\"metadata\":{\"annotations\":{\"eks.amazonaws.com/role-arn\":\"${role_arn}\"}}}"
  fi

  # Validate
  if ! validate_irsa_for_sa "${ns}" "${sa}"; then
    err "IRSA validation failed for ${ns}/${sa}"
  fi
}

# ---------- Splunk Standalone in ai-platform ----------
resolve_aws_creds_for_secret() {
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then return 0; fi
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    local tmpf; tmpf="$(mktemp)"; TMP_FILES+=("$tmpf")
    if aws configure export-credentials --profile "${AWS_PROFILE}" --format env > "$tmpf" 2>/dev/null; then
      # shellcheck disable=SC1090
      source "$tmpf"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      log "Exported temporary env credentials from profile '${AWS_PROFILE}' for S3 secret."
      return 0
    else
      warn "Tried to export credentials from AWS_PROFILE='${AWS_PROFILE}' but failed. Are you logged in? (aws sso login --profile ${AWS_PROFILE})"
    fi
  fi
  err "AWS credentials not set. Either set env vars or use AWS_PROFILE with a logged-in profile."
}

install_splunk_standalone() {
  log "Creating/ensuring Splunk Standalone (${AI_STANDALONE_NAME}) in ${AI_NS}"
  ensure_namespace "${AI_NS}"
  wait_for_crd standalones.enterprise.splunk.com 600

  # IRSA for Splunk Standalone: S3 bucket policy when using AWS S3, ECR-only when using external S3-compatible
  log "Setting up IRSA for Splunk Standalone service account..."
  local policy_arn
  if [[ "${USE_EXTERNAL_OBJ_STORE}" == "true" ]]; then
    policy_arn="$(ensure_ecr_only_policy)"
  else
    policy_arn="$(ensure_bucket_policy "${AI_BUCKET_POLICY_NAME}" "${S3_BUCKET}")"
  fi
  ensure_irsa_for_sa "${STANDALONE_SA}" "${AI_NS}" "${policy_arn}"

  if [[ "${USE_EXTERNAL_OBJ_STORE}" != "true" ]]; then
    # Create s3-secret for Standalone when using S3 (fallback if IRSA not fully supported)
    log "Creating s3-secret for Splunk Standalone (S3 mode)..."
    if resolve_aws_creds_for_secret 2>/dev/null; then
      local ak="${AWS_ACCESS_KEY_ID:-}"; local sk="${AWS_SECRET_ACCESS_KEY:-}"; local st="${AWS_SESSION_TOKEN:-}"
      if [[ -n "$ak" && -n "$sk" ]]; then
        kubectl -n "${AI_NS}" create secret generic s3-secret \
          --from-literal=s3_access_key="${ak}" \
          --from-literal=s3_secret_key="${sk}" \
          $( [[ -n "$st" ]] && printf -- "--from-literal=s3_session_token=%s" "$st" ) \
          --dry-run=client -o yaml | kubectl apply -f -
        log "✓ Created s3-secret with explicit credentials"
      else
        warn "No AWS credentials available - s3-secret not created. Splunk Standalone will use IRSA."
      fi
    else
      warn "AWS credentials not available - s3-secret not created. Splunk Standalone will use IRSA via ${STANDALONE_SA}."
    fi
  fi

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

  # Standalone app repo: external S3-compatible when objectStore.type is s3compat/minio/seaweedfs, else S3
  if [[ "${USE_EXTERNAL_OBJ_STORE}" == "true" ]]; then
    local minio_endpoint="${MINIO_ENDPOINT:-${OBJ_STORE_ENDPOINT}}"
    cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  serviceAccount: ${STANDALONE_SA}
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
  else
    cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  serviceAccount: ${STANDALONE_SA}
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
  fi

  local sts="splunk-${AI_STANDALONE_NAME}-standalone"
  wait_resource_exists "${AI_NS}" statefulset "${sts}" 600
}

find_splunk_standalone_secret_name() {
  local ns="$1" owner="$2" timeout="${3:-600}" waited=0 name=""
  log "Discovering Splunk versioned secret for Standalone '${owner}' in namespace '${ns}'..."
  while true; do
    name="$(kubectl -n "$ns" get secret \
      -l app.kubernetes.io/component=versionedSecrets,app.kubernetes.io/managed-by=splunk-operator \
      -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null | awk -F'|' -v o="$owner" '$2==o {print $1; exit}')"
    if [[ -n "$name" ]]; then printf "%s" "$name"; return 0; fi
    [[ $waited -ge $timeout ]] && err "Timed out waiting for Splunk versioned secret for ${owner} in ${ns}"
    sleep 5; waited=$((waited+5))
  done
}

update_splunk_secret_password_only() {
  local ns="$1" secret="$2"
  local pw; pw="Ch@ngeme"
  local b; b="$(echo -n "$pw" | base64)"
  local op="replace"
  if ! kubectl -n "$ns" get secret "$secret" -o jsonpath='{.data.password}' >/dev/null 2>&1; then op="add"; fi
  kubectl -n "$ns" patch secret "$secret" --type='json' \
    -p "[{\"op\":\"${op}\",\"path\":\"/data/password\",\"value\":\"${b}\"}]"
  log "Updated only the 'password' field in secret ${ns}/${secret}"
}

# ---------- AIPlatform CR ----------
wait_aiplatform_ready() {
  local waited=0 max_wait=2400 check_interval=15
  local last_status="" shown_events=0

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "Monitoring AIPlatform/${AI_PLATFORM_NAME} deployment status..."
  log "This may take 10-15 minutes for AI models to download and initialize"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  while true; do
    # Get all status conditions as JSON
    local conditions
    conditions=$(kubectl -n "${AI_NS}" get aiplatforms.ai.splunk.com "${AI_PLATFORM_NAME}" \
      -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")

    # Parse individual condition statuses
    local ready_status ray_service_status ray_cluster_status ray_serve_status weaviate_status ingress_status
    ready_status=$(echo "$conditions" | jq -r '.[] | select(.type=="Ready") | .status' 2>/dev/null || echo "Unknown")
    ray_service_status=$(echo "$conditions" | jq -r '.[] | select(.type=="RayServiceReady") | .status' 2>/dev/null || echo "Unknown")
    ray_cluster_status=$(echo "$conditions" | jq -r '.[] | select(.type=="RayClusterReady") | .status' 2>/dev/null || echo "Unknown")
    ray_serve_status=$(echo "$conditions" | jq -r '.[] | select(.type=="RayServeRouteReady") | .status' 2>/dev/null || echo "Unknown")
    weaviate_status=$(echo "$conditions" | jq -r '.[] | select(.type=="WeaviateDatabaseReady") | .status' 2>/dev/null || echo "Unknown")
    ingress_status=$(echo "$conditions" | jq -r '.[] | select(.type=="IngressReady") | .status' 2>/dev/null || echo "Unknown")

    # Build status summary
    local current_status="Ready:$ready_status Ray:$ray_service_status RayCluster:$ray_cluster_status RayServe:$ray_serve_status Weaviate:$weaviate_status"
    [[ "$ingress_status" != "Unknown" ]] && current_status="$current_status Ingress:$ingress_status"

    # Only show status update if it changed
    if [[ "$current_status" != "$last_status" ]]; then
      echo ""
      log "📊 Component Status:"
      log "  ├─ Platform Ready:     $(format_status "$ready_status")"
      log "  ├─ Ray Service:        $(format_status "$ray_service_status")"
      log "  ├─ Ray Cluster:        $(format_status "$ray_cluster_status")"
      log "  ├─ Ray Serve (AI API): $(format_status "$ray_serve_status")"
      log "  ├─ Weaviate Database:  $(format_status "$weaviate_status")"
      [[ "$ingress_status" != "Unknown" ]] && log "  └─ Ingress:            $(format_status "$ingress_status")"

      # Show recent events since last check
      log ""
      log "📝 Recent Events:"
      local events
      events=$(kubectl get events -n "${AI_NS}" \
        --field-selector involvedObject.name="${AI_PLATFORM_NAME}" \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -n +2 | tail -5)

      if [[ -n "$events" ]]; then
        while IFS= read -r event_line; do
          local event_type event_reason event_message
          event_type=$(echo "$event_line" | awk '{print $2}')
          event_reason=$(echo "$event_line" | awk '{print $4}')
          event_message=$(echo "$event_line" | cut -d' ' -f5-)

          if [[ "$event_type" == "Warning" ]]; then
            log "  ⚠️  $event_reason: $event_message"
          else
            log "  ✓  $event_reason: $event_message"
          fi
        done <<< "$events"
      else
        log "  (No events yet)"
      fi

      # Show any failure messages
      local failure_msgs
      failure_msgs=$(echo "$conditions" | jq -r '.[] | select(.status=="False") | "  ❌ \(.type): \(.message)"' 2>/dev/null || true)
      if [[ -n "$failure_msgs" ]]; then
        echo ""
        log "⚠️  Components Not Ready:"
        echo "$failure_msgs"
      fi

      last_status="$current_status"
      shown_events=$((shown_events+1))
    fi

    # Check if platform is ready
    if [[ "$ready_status" == "True" ]]; then
      echo ""
      log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      log "✅ AIPlatform is Ready!"
      log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      # Show final access information
      show_platform_access_info
      return 0
    fi

    # Check timeout
    if [[ $waited -ge $max_wait ]]; then
      echo ""
      warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      warn "⏱️  Timeout waiting for AIPlatform Ready after $((max_wait/60)) minutes"
      warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      warn "Current status: $current_status"
      warn ""
      warn "To check status manually:"
      warn "  kubectl get aiplatform ${AI_PLATFORM_NAME} -n ${AI_NS}"
      warn "  kubectl get events -n ${AI_NS} --field-selector involvedObject.name=${AI_PLATFORM_NAME}"
      warn "  kubectl logs -n splunk-ai-operator-system deployment/splunk-ai-operator-controller-manager"
      return 1
    fi

    # Wait before next check
    echo -n "."
    sleep "$check_interval"
    waited=$((waited + check_interval))
  done
}

# Helper function to format status with colors/symbols
format_status() {
  local status="$1"
  case "$status" in
    "True")  echo "✅ Ready" ;;
    "False") echo "❌ Not Ready" ;;
    "Unknown") echo "⏳ Starting..." ;;
    *) echo "❓ $status" ;;
  esac
}

# Show access information after platform is ready
show_platform_access_info() {
  log ""
  log "📍 Access Information:"

  # Get service names
  local ray_svc weaviate_svc
  ray_svc=$(kubectl -n "${AI_NS}" get svc -l ray.io/cluster="${AI_PLATFORM_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  weaviate_svc=$(kubectl -n "${AI_NS}" get svc -l app="${AI_PLATFORM_NAME}-weaviate" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  # Ray Serve (AI API)
  if [[ -n "$ray_svc" ]]; then
    log "  🤖 AI Inference API (Ray Serve):"
    log "     Internal: http://${ray_svc}.${AI_NS}.svc.cluster.local:8000"
    log "     Port-forward: kubectl port-forward -n ${AI_NS} svc/${ray_svc} 8000:8000"
    log "     Test: curl http://localhost:8000/v1/chat/completions"
  fi

  # Weaviate
  if [[ -n "$weaviate_svc" ]]; then
    log ""
    log "  🗄️  Vector Database (Weaviate):"
    log "     Internal: http://${weaviate_svc}.${AI_NS}.svc.cluster.local:80"
    log "     Port-forward: kubectl port-forward -n ${AI_NS} svc/${weaviate_svc} 8080:80"
  fi

  # Ingress info
  local ingress_host ingress_ip
  ingress_host=$(kubectl -n "${AI_NS}" get ingress "${AI_PLATFORM_NAME}" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
  ingress_ip=$(kubectl -n "${AI_NS}" get ingress "${AI_PLATFORM_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -z "$ingress_ip" ]] && ingress_ip=$(kubectl -n "${AI_NS}" get ingress "${AI_PLATFORM_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

  if [[ -n "$ingress_host" ]]; then
    log ""
    log "  🌐 External Access (Ingress):"
    log "     Host: ${ingress_host}"
    [[ -n "$ingress_ip" ]] && log "     LoadBalancer: ${ingress_ip}"
    log "     Update DNS: ${ingress_host} → ${ingress_ip}"
    log "     Test: curl https://${ingress_host}/v1/chat/completions"
  fi

  log ""
  log "📊 Monitoring Commands:"
  log "  kubectl get aiplatform ${AI_PLATFORM_NAME} -n ${AI_NS}"
  log "  kubectl get events -n ${AI_NS} --watch --field-selector involvedObject.name=${AI_PLATFORM_NAME}"
  log "  kubectl get pods -n ${AI_NS} -l ai.splunk.com/platform=${AI_PLATFORM_NAME}"
  log ""
}

saia_service_template_enabled() {
  [[ -n "${SAIA_SERVICE_TYPE:-}" && "${SAIA_SERVICE_TYPE}" != "null" && "${SAIA_SERVICE_TYPE}" != "ClusterIP" ]]
}

saia_aiservice_name() {
  local platform_name="${1:-${AI_PLATFORM_NAME}}"
  printf "%s-saia" "${platform_name}"
}

wait_for_aiservice_exists() {
  local name="$1" timeout="${2:-600}" waited=0
  while ! kubectl -n "${AI_NS}" get aiservice "${name}" >/dev/null 2>&1; do
    [[ $waited -ge $timeout ]] && err "Timed out waiting for AIService ${AI_NS}/${name}"
    sleep 5
    waited=$((waited + 5))
  done
}

apply_saia_service_annotations() {
  local aiservice_name="$1"
  local annotation_keys key value

  annotation_keys="$(yq eval '.aiPlatform.serviceTemplate.annotations // {} | keys | .[]' "${CONFIG_FILE}" 2>/dev/null || true)"
  [[ -z "${annotation_keys}" ]] && return 0

  local annotate_args=()
  while IFS= read -r key; do
    [[ -z "${key}" || "${key}" == "null" ]] && continue
    value="$(yq eval ".aiPlatform.serviceTemplate.annotations.\"${key}\"" "${CONFIG_FILE}" 2>/dev/null || echo "")"
    [[ -z "${value}" || "${value}" == "null" ]] && continue
    annotate_args+=("${key}=${value}")
  done <<< "${annotation_keys}"

  if [[ ${#annotate_args[@]} -gt 0 ]]; then
    log "Applying SAIA Service annotations to AIService/${aiservice_name}..."
    kubectl -n "${AI_NS}" annotate aiservice "${aiservice_name}" "${annotate_args[@]}" --overwrite
  fi
}

byo_target_group_enabled() {
  [[ "${BYO_TG_ENABLED:-false}" == "true" ]]
}

# Validates BYO target-group configuration and warns about misconfigurations
# before any kubectl/aws calls are issued. Caller decides whether to err or
# return on warnings — we treat missing required fields as fatal because the
# rest of the install would silently misroute traffic.
validate_byo_target_group_config() {
  byo_target_group_enabled || return 0

  if [[ "${INSTALL_LBC:-false}" != "true" ]]; then
    err "byoTargetGroup.enabled=true requires awsLoadBalancerController.install=true (LBC manages the TargetGroupBinding)."
  fi
  if [[ -z "${BYO_TG_ARN:-}" || "${BYO_TG_ARN}" == "null" ]]; then
    err "byoTargetGroup.enabled=true requires byoTargetGroup.targetGroupArn to be set."
  fi
  if [[ "${BYO_TG_ARN}" != arn:aws:elasticloadbalancing:* ]]; then
    err "byoTargetGroup.targetGroupArn must look like 'arn:aws:elasticloadbalancing:<region>:<account>:targetgroup/<name>/<id>' (got: ${BYO_TG_ARN})."
  fi
  if [[ -z "${BYO_TG_SG_ID:-}" || "${BYO_TG_SG_ID}" == "null" ]]; then
    err "byoTargetGroup.enabled=true requires byoTargetGroup.securityGroupId (the customer LB's SG) so LBC opens pod-SG ingress correctly."
  fi
  if [[ "${SAIA_SERVICE_TYPE:-}" == "LoadBalancer" ]]; then
    log "WARNING: byoTargetGroup.enabled=true with serviceTemplate.type=LoadBalancer creates BOTH an operator-managed LB AND a TargetGroupBinding. Set serviceTemplate.type=ClusterIP for pure BYO." >&2
  fi
}

# Apply a TargetGroupBinding CR pointing at the customer's pre-provisioned
# target group. AWS LBC reads this CR and registers the SAIA Service's pod
# IPs (targetType: ip) into the customer's TG, then deregisters them on pod
# rotation. The networking.ingress block has LBC open the pod SG to the LB's
# SG only — never 0.0.0.0/0 (codeguard-0-iac-security).
apply_byo_target_group_binding() {
  local platform_name="${1:-${AI_PLATFORM_NAME}}"
  local svc_name
  svc_name="$(saia_aiservice_name "${platform_name}")-saia-service"

  byo_target_group_enabled || return 0

  log "Applying TargetGroupBinding for BYO target group ${BYO_TG_ARN}..."
  cat <<YAML | kubectl -n "${AI_NS}" apply -f -
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: ${svc_name}-tgb
  namespace: ${AI_NS}
spec:
  serviceRef:
    name: ${svc_name}
    port: 8080
  targetGroupARN: ${BYO_TG_ARN}
  targetType: ip
  networking:
    ingress:
      - from:
          - securityGroup:
              groupID: ${BYO_TG_SG_ID}
        ports:
          - protocol: TCP
            port: 8080
YAML
  log "✓ TargetGroupBinding ${AI_NS}/${svc_name}-tgb applied"
}

# Disable kube-proxy NodePort allocation on the rendered SAIA Service. The
# operator's reconcileSAIAService only touches Selector/Ports on existing
# Services (pkg/ai/features/saia/impl.go), so this patch survives subsequent
# reconciles. externalTrafficPolicy=Local preserves real client IP for
# MetalLB-style providers; for AWS NLB ip-target mode it is a no-op since
# LBC bypasses kube-proxy entirely.
patch_saia_service_disable_nodeport() {
  local platform_name="${1:-${AI_PLATFORM_NAME}}"
  local svc_name
  svc_name="$(saia_aiservice_name "${platform_name}")-saia-service"

  # Only meaningful when the Service is type=LoadBalancer; ClusterIP services
  # don't allocate NodePorts.
  local svc_type
  svc_type="$(kubectl -n "${AI_NS}" get svc "${svc_name}" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  [[ "${svc_type}" != "LoadBalancer" ]] && return 0

  log "Patching Service ${AI_NS}/${svc_name} to disable NodePort allocation..."
  kubectl -n "${AI_NS}" patch svc "${svc_name}" --type=merge -p '{
  "spec": {
    "allocateLoadBalancerNodePorts": false,
    "externalTrafficPolicy": "Local"
  }
}' >/dev/null
  log "✓ Service ${AI_NS}/${svc_name}: allocateLoadBalancerNodePorts=false, externalTrafficPolicy=Local"
}

patch_saia_public_service_workaround() {
  local platform_name="${1:-${AI_PLATFORM_NAME}}"
  local aiservice_name public_svc_name effective_type

  aiservice_name="$(saia_aiservice_name "${platform_name}")"
  public_svc_name="${aiservice_name}-saia-service"

  wait_for_aiservice_exists "${aiservice_name}"

  # In BYO mode the customer owns the LB; force the SAIA Service to ClusterIP
  # regardless of what serviceTemplate.type says — TargetGroupBinding wires
  # everything else.
  if byo_target_group_enabled; then
    effective_type="ClusterIP"
  else
    effective_type="${SAIA_SERVICE_TYPE}"
  fi

  if [[ -n "${effective_type:-}" && "${effective_type}" != "null" ]]; then
    log "Patching AIService/${aiservice_name} with SAIA public exposure settings (type=${effective_type})..."
    if [[ "${effective_type}" == "NodePort" && -n "${SAIA_SERVICE_NODE_PORT:-}" && "${SAIA_SERVICE_NODE_PORT}" != "null" ]]; then
      log "WARNING: NodePort exposure is discouraged; consider Mode 1 (LoadBalancer + LBC) or Mode 2 (BYO target group) instead." >&2
      kubectl -n "${AI_NS}" patch aiservice "${aiservice_name}" --type merge -p "{
  \"spec\": {
    \"serviceTemplate\": {
      \"spec\": {
        \"type\": \"NodePort\",
        \"ports\": [
          {
            \"name\": \"http\",
            \"port\": 8080,
            \"targetPort\": 8080,
            \"nodePort\": ${SAIA_SERVICE_NODE_PORT}
          }
        ]
      }
    }
  }
}"
    else
      kubectl -n "${AI_NS}" patch aiservice "${aiservice_name}" --type merge -p "{
  \"spec\": {
    \"serviceTemplate\": {
      \"spec\": {
        \"type\": \"${effective_type}\"
      }
    }
  }
}"
    fi
  fi

  apply_saia_service_annotations "${aiservice_name}"

  kubectl -n "${AI_NS}" annotate aiservice "${aiservice_name}" script-reconcile-ts="$(date +%s)" --overwrite >/dev/null

  if [[ -n "${effective_type:-}" && "${effective_type}" != "null" && "${effective_type}" != "ClusterIP" ]]; then
    log "Recreating SAIA public Service to ensure patched settings take effect..."
    kubectl -n "${AI_NS}" delete svc "${public_svc_name}" --ignore-not-found >/dev/null 2>&1 || true
    wait_resource_exists "${AI_NS}" service "${public_svc_name}" 300
  fi

  # NodePort-free hardening: disable kube-proxy NodePort allocation on
  # LoadBalancer Services and apply BYO TargetGroupBinding if configured.
  patch_saia_service_disable_nodeport "${platform_name}"
  apply_byo_target_group_binding "${platform_name}"
}

wait_for_saia_load_balancer() {
  local platform_name="${1:-${AI_PLATFORM_NAME}}" timeout="${2:-1200}" waited=0
  local svc_name hostname=""
  svc_name="$(saia_aiservice_name "${platform_name}")-saia-service"

  # In BYO mode the Service is ClusterIP and the customer's LB DNS is not
  # surfaced via .status.loadBalancer; skip the wait. Mode 1 (operator-
  # managed NLB) still gates on SAIA_SERVICE_TYPE=LoadBalancer.
  if byo_target_group_enabled; then
    log "byoTargetGroup.enabled=true — skipping wait for operator-managed LB hostname (LB is customer-managed)."
    return 0
  fi
  [[ "${SAIA_SERVICE_TYPE:-}" == "LoadBalancer" ]] || return 0

  log "Waiting for SAIA LoadBalancer Service ${AI_NS}/${svc_name} to receive an external hostname..."
  while true; do
    hostname="$(kubectl -n "${AI_NS}" get svc "${svc_name}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -z "${hostname}" ]] && hostname="$(kubectl -n "${AI_NS}" get svc "${svc_name}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${hostname}" ]]; then
      log "✓ SAIA external endpoint: ${hostname}"
      return 0
    fi
    [[ $waited -ge $timeout ]] && err "Timed out waiting for SAIA LoadBalancer Service ${AI_NS}/${svc_name}"
    sleep 5
    waited=$((waited + 5))
  done
}

# Quick status check function - can be called standalone
check_aiplatform_status() {
  local platform_name="${1:-${AI_PLATFORM_NAME}}"
  local namespace="${2:-${AI_NS}}"

  need jq

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "AIPlatform Status Check: ${namespace}/${platform_name}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Check if resource exists
  if ! kubectl -n "${namespace}" get aiplatforms.ai.splunk.com "${platform_name}" >/dev/null 2>&1; then
    err "AIPlatform ${namespace}/${platform_name} not found"
  fi

  # Get all status conditions
  local conditions
  conditions=$(kubectl -n "${namespace}" get aiplatforms.ai.splunk.com "${platform_name}" \
    -o jsonpath='{.status.conditions}' 2>/dev/null || echo "[]")

  # Parse conditions
  local ready_status ray_service_status ray_cluster_status ray_serve_status weaviate_status ingress_status
  ready_status=$(echo "$conditions" | jq -r '.[] | select(.type=="Ready") | .status' 2>/dev/null || echo "Unknown")
  ray_service_status=$(echo "$conditions" | jq -r '.[] | select(.type=="RayServiceReady") | .status' 2>/dev/null || echo "Unknown")
  ray_cluster_status=$(echo "$conditions" | jq -r '.[] | select(.type=="RayClusterReady") | .status' 2>/dev/null || echo "Unknown")
  ray_serve_status=$(echo "$conditions" | jq -r '.[] | select(.type=="RayServeRouteReady") | .status' 2>/dev/null || echo "Unknown")
  weaviate_status=$(echo "$conditions" | jq -r '.[] | select(.type=="WeaviateDatabaseReady") | .status' 2>/dev/null || echo "Unknown")
  ingress_status=$(echo "$conditions" | jq -r '.[] | select(.type=="IngressReady") | .status' 2>/dev/null || echo "Unknown")

  echo ""
  log "📊 Component Status:"
  log "  ├─ Platform Ready:     $(format_status "$ready_status")"
  log "  ├─ Ray Service:        $(format_status "$ray_service_status")"
  log "  ├─ Ray Cluster:        $(format_status "$ray_cluster_status")"
  log "  ├─ Ray Serve (AI API): $(format_status "$ray_serve_status")"
  log "  ├─ Weaviate Database:  $(format_status "$weaviate_status")"
  [[ "$ingress_status" != "Unknown" ]] && log "  └─ Ingress:            $(format_status "$ingress_status")"

  # Show detailed messages for non-ready components
  local not_ready
  not_ready=$(echo "$conditions" | jq -r '.[] | select(.status=="False") | "  • \(.type): \(.message)"' 2>/dev/null || true)
  if [[ -n "$not_ready" ]]; then
    echo ""
    log "⚠️  Components Not Ready:"
    echo "$not_ready"
  fi

  # Show last 10 events
  echo ""
  log "📝 Recent Events (last 10):"
  local events
  events=$(kubectl get events -n "${namespace}" \
    --field-selector involvedObject.name="${platform_name}" \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -n +2 | tail -10)

  if [[ -n "$events" ]]; then
    while IFS= read -r event_line; do
      local event_type event_reason
      event_type=$(echo "$event_line" | awk '{print $2}')
      event_reason=$(echo "$event_line" | awk '{print $4}')

      if [[ "$event_type" == "Warning" ]]; then
        log "  ⚠️  $event_line"
      else
        log "  ✓  $event_line"
      fi
    done <<< "$events"
  else
    log "  (No events found)"
  fi

  # Show pod status
  echo ""
  log "📦 Pod Status:"
  kubectl get pods -n "${namespace}" -l "ai.splunk.com/platform=${platform_name}" 2>/dev/null || \
    log "  (No pods found with label ai.splunk.com/platform=${platform_name})"

  # Show access info if ready
  if [[ "$ready_status" == "True" ]]; then
    AI_PLATFORM_NAME="$platform_name" AI_NS="$namespace" show_platform_access_info
  else
    echo ""
    log "💡 Platform is not ready yet. Use this command to monitor:"
    log "   kubectl get events -n ${namespace} --watch --field-selector involvedObject.name=${platform_name}"
  fi

  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

install_ai_platform_cr() {
  local secret_name="${1:-}"
  if [[ -z "$secret_name" ]]; then
    secret_name="$(find_splunk_standalone_secret_name "${AI_NS}" "${AI_STANDALONE_NAME}")"
  fi
  log "Installing AIPlatform CR (${AI_PLATFORM_NAME}) in ${AI_NS} using secretRef.name=${secret_name}"
  ensure_namespace "${AI_NS}"

  cat <<YAML | kubectl -n "${AI_NS}" apply --server-side --force-conflicts -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: platform-issuer
spec:
  isCA: true
  commonName: my-selfsigned-ca
  secretName: root-secret
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: selfsigned-issuer, kind: Issuer, group: cert-manager.io }
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: my-ca-issuer
spec:
  ca: { secretName: root-secret }
YAML

  # objectStorage: path/endpoint/secret by object store type (aws | s3compat | minio | seaweedfs)
  local obj_path obj_endpoint obj_secret
  case "${OBJ_STORE_TYPE}" in
    s3compat)
      obj_path="s3compat://${OBJ_STORE_BUCKET}"
      obj_endpoint="${OBJ_STORE_ENDPOINT}"
      obj_secret="minio-credentials"
      ;;
    minio)
      obj_path="minio://${MINIO_BUCKET}"
      obj_endpoint="${MINIO_ENDPOINT:-${OBJ_STORE_ENDPOINT}}"
      obj_secret="minio-credentials"
      ;;
    seaweedfs)
      obj_path="seaweedfs://${OBJ_STORE_BUCKET}"
      obj_endpoint="${OBJ_STORE_ENDPOINT}"
      obj_secret="minio-credentials"
      ;;
    aws|*)
      obj_path="s3://${S3_BUCKET}"
      obj_endpoint=""
      obj_secret=""
      ;;
  esac

  local svc_template_yaml=""
  if saia_service_template_enabled; then
    svc_template_yaml="  serviceTemplate:"$'\n'"    spec:"$'\n'"      type: ${SAIA_SERVICE_TYPE}"$'\n'
    if [[ "${SAIA_SERVICE_TYPE}" == "NodePort" && -n "${SAIA_SERVICE_NODE_PORT:-}" && "${SAIA_SERVICE_NODE_PORT}" != "null" ]]; then
      svc_template_yaml+="      ports:"$'\n'"      - name: http"$'\n'"        port: 8080"$'\n'"        targetPort: 8080"$'\n'"        nodePort: ${SAIA_SERVICE_NODE_PORT}"$'\n'
    fi
  fi

  cat <<YAML | kubectl -n "${AI_NS}" apply --server-side --force-conflicts -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${AI_PLATFORM_NAME}
spec:
  objectStorage:
    path: ${obj_path}
    region: ${REGION}
    $( [[ -n "$obj_endpoint" ]] && echo "endpoint: \"${obj_endpoint}\"" )
    $( [[ -n "$obj_secret" ]] && echo "secretRef: ${obj_secret}" )
  serviceAccountName: ${RAY_HEAD_SA}
  defaultAcceleratorType: ${DEFAULT_ACCELERATOR}
  features:
    - name: saia
      version: "1.1.0"
      serviceAccountName: ${SAIA_SERVICE_SA}
${svc_template_yaml}
  storage:
    vectorDB:
      size: ${VECTORDB_SIZE}
      storageClassName: ${STORAGE_CLASS}
  workerGroupConfig:
    serviceAccountName: ${RAY_WORKER_SA}
    imageRegistry: "${WORKER_IMAGE_REGISTRY}"
  cpuScheduler:
    nodeSelector: {}
    tolerations: []
  gpuScheduler:
    nodeSelector: {}
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
  ingress:
    enabled: false
    className: ${INGRESS_CLASS}
    hosts:
      - host: ${INGRESS_HOST}
        paths: [ { path: "/", pathType: Prefix } ]
    tls:
      - hosts: [ ${INGRESS_HOST} ]
        secretName: ${INGRESS_TLS_SECRET}
  splunkConfiguration:
    endpoint: https://splunk-${AI_STANDALONE_NAME}-standalone-service.${AI_NS}.svc.cluster.local:8088
    secretRef:
      name: ${secret_name}
      namespace: ${AI_NS}
  certificateRef: ${CERT_ISSUER}
YAML

  wait_aiplatform_ready
  patch_saia_public_service_workaround "${AI_PLATFORM_NAME}"
  wait_for_saia_load_balancer "${AI_PLATFORM_NAME}" 1200
}

# Wait until Splunk AI Assistant app shows as installed in Standalone status
wait_splunk_ai_assistant_installed() {
  local ns="${AI_NS}" name="${AI_STANDALONE_NAME}" app_tgz="${1:-Splunk_AI_Assistant_Cloud.tgz}" timeout="${2:-1200}"
  local waited=0 deploy="" inprog="" found=""
  need jq
  log "Waiting for Splunk app '${app_tgz}' to be installed on Standalone ${ns}/${name} (timeout ${timeout}s)..."
  while true; do
    local js
    js="$(kubectl -n "${ns}" get standalone "${name}" -o json 2>/dev/null || true)"
    if [[ -n "$js" ]]; then
      read -r deploy inprog found <<<"$(jq -r \
        --arg APP "$app_tgz" '
          .status as $s |
          ($s.appContext.isDeploymentInProgress // false) as $inprog |
          (($s.appContext.appSrcDeployStatus.apps.appDeploymentInfo // [])
            | map(select(.appName==$APP)) | .[0]) as $ai
          |
          if ($ai|type) == "null" then
            "none " + ($inprog|tostring) + " false"
          else
            ((($ai.deployStatus // -1)|tostring) + " " + ($inprog|tostring) + " true")
          end
        ' <<<"$js")"
    fi
    if [[ "$found" == "true" && "$deploy" == "3" && "$inprog" == "false" ]]; then
      log "Splunk app '${app_tgz}' is installed (deployStatus=${deploy}, inProgress=${inprog})."
      return 0
    fi
    [[ $waited -ge $timeout ]] && err "Timed out waiting for '${app_tgz}' to be installed on ${ns}/${name}"
    sleep 5; waited=$((waited+5))
  done
}

# Push splunkaiassistant.conf into the Standalone pod after the app is installed
push_saia_conf_into_pod() {
  local ns="${AI_NS}" name="${AI_STANDALONE_NAME}"
  local sts="splunk-${name}-standalone"
  local pod="${sts}-0"
  local dest_dir="/opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud/default"
  local dest_file="${dest_dir}/splunkaiassistant.conf"

  wait_resource_exists "${ns}" statefulset "${sts}" 600
  wait_resource_exists "${ns}" pod "${pod}" 600

  local tmpf; tmpf="$(mktemp)"; TMP_FILES+=("$tmpf")
  cat >"$tmpf" <<'CONF'
[splunk_ai_assistant]
feedback_enabled=true

[cloud_connected_configurations]

[cloud_connected_configurations:proxy_settings]

[saia_sok_configurations]
saia_sok_enabled=true
saia_sok_url=http://splunk-ai-stack-saia-saia-service:8080
CONF

  log "Copying splunkaiassistant.conf to ${ns}/${pod}:${dest_file}"
  kubectl -n "${ns}" exec "${pod}" -- sh -c "mkdir -p '${dest_dir}'"
  kubectl -n "${ns}" cp "${tmpf}" "${pod}:${dest_file}"
  kubectl -n "${ns}" exec "${pod}" -- sh -c "ls -l '${dest_file}' && head -n 5 '${dest_file}'" || true
  log "splunkaiassistant.conf successfully applied."
}

# ---------- IAM cleanup helpers ----------
role_exists() { aws iam get-role --role-name "$1" >/dev/null 2>&1; }

delete_role_if_exists() {
  local role="$1"
  if role_exists "$role"; then
    log "Detaching policies & deleting IAM role $role"
    for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$p" || true
    done
    for ip in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
      aws iam delete-role-policy --role-name "$role" --policy-name "$ip" || true
    done
    aws iam delete-role --role-name "$role" || true
  fi
}

delete_policy_if_exists() {
  local name="$1"
  local arn; arn="$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${name}'].Arn" --output text 2>/dev/null || true)"
  arn="$(normalize_arn "$arn")"
  if [[ -n "$arn" ]]; then
    log "Deleting IAM policy ${name}"
    for role in $(aws iam list-entities-for-policy --policy-arn "$arn" --query 'PolicyRoles[].RoleName' --output text 2>/dev/null || true); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" || true
    done
    aws iam delete-policy --policy-arn "$arn" || true
  fi
}

delete_iamserviceaccount_if_exists() {
  local ns="$1" sa="$2"
  log "Deleting iamserviceaccount stack for ${ns}/${sa} (if any)"
  eksctl delete iamserviceaccount --region "${REGION}" --cluster "${CLUSTER_NAME}" --namespace "${ns}" --name "${sa}" || true
}

delete_oidc_provider_if_exists() {
  local arn="$1"
  [[ -z "${arn:-}" ]] && return 0
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1; then
    log "Deleting IAM OIDC provider: $arn"
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" || true
  fi
}

purge_irsa_roles_by_oidc() {
  local oidc_arn
  oidc_arn="$(get_oidc_provider_arn || true)"
  if [[ -z "$oidc_arn" ]]; then
    warn "No OIDC provider ARN detected; skipping IRSA role purge"
    return 0
  fi
  log "Scanning IAM roles that trust OIDC provider: $oidc_arn"
  local roles=()
  while IFS= read -r role; do
    [[ -n "$role" ]] && roles+=("$role")
  done < <(aws iam list-roles --query 'Roles[].RoleName' --output text | tr '\t' '\n')
  local to_delete=()
  for r in "${roles[@]}"; do
    [[ -z "$r" ]] && continue
    local doc
    doc="$(aws iam get-role --role-name "$r" --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null || true)"
    [[ -z "$doc" ]] && continue
    if [[ "$doc" == *"$oidc_arn"* && "$doc" == *"AssumeRoleWithWebIdentity"* ]]; then
      to_delete+=("$r")
    fi
  done
  if [[ ${#to_delete[@]} -eq 0 ]]; then
    log "No leftover IRSA roles referencing ${oidc_arn} found."; return 0
  fi
  log "Deleting ${#to_delete[@]} IRSA role(s) bound to this cluster's OIDC provider..."
  for r in "${to_delete[@]}"; do
    log " Detaching policies & deleting role: ${r}"
    for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
      aws iam detach-role-policy --role-name "$r" --policy-arn "$p" || true
    done
    for ip in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
      aws iam delete-role-policy --role-name "$r" --policy-name "$ip" || true
    done
    aws iam delete-role --role-name "$r" || true
  done
}

empty_and_delete_bucket() {
  local bucket="$1"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    log "Bucket $bucket does not exist; nothing to delete"; return 0
  fi
  log "Emptying versioned objects in s3://$bucket ..."
  while true; do
    local lines=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && lines+=("$line")
    done < <(aws s3api list-object-versions --bucket "$bucket" --query 'Versions[].join(`\t`, [Key, VersionId])' --output text 2>/dev/null || true)
    [[ "${#lines[@]}" -eq 0 ]] && break
    for l in "${lines[@]}"; do
      local key="${l%%$'\t'*}"
      local ver="${l##*$'\t'}"
      aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$ver" >/dev/null || true
    done
  done
  while true; do
    local lines=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && lines+=("$line")
    done < <(aws s3api list-object-versions --bucket "$bucket" --query 'DeleteMarkers[].join(`\t`, [Key, VersionId])' --output text 2>/dev/null || true)
    [[ "${#lines[@]}" -eq 0 ]] && break
    for l in "${lines[@]}"; do
      local key="${l%%$'\t'*}"
      local ver="${l##*$'\t'}"
      aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$ver" >/dev/null || true
    done
  done
  log "Deleting bucket s3://$bucket ..."
  aws s3api delete-bucket --bucket "$bucket" --region "${REGION}" || true
}

delete_cluster_ebs_volumes() {
  log "Finding and deleting EBS volumes associated with cluster ${CLUSTER_NAME}..."
  
  # Find volumes tagged with the cluster name
  local volume_ids=()
  while IFS= read -r vol_id; do
    [[ -n "$vol_id" ]] && volume_ids+=("$vol_id")
  done < <(aws ec2 describe-volumes --region "${REGION}" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n')
  
  # Also find volumes tagged with KubernetesCluster tag
  while IFS= read -r vol_id; do
    [[ -n "$vol_id" ]] && volume_ids+=("$vol_id")
  done < <(aws ec2 describe-volumes --region "${REGION}" \
    --filters "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n')
  
  # Also find volumes created by the EBS CSI driver for this cluster
  while IFS= read -r vol_id; do
    [[ -n "$vol_id" ]] && volume_ids+=("$vol_id")
  done < <(aws ec2 describe-volumes --region "${REGION}" \
    --filters "Name=tag:ebs.csi.aws.com/cluster,Values=true" \
              "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query "Volumes[?Tags[?Key=='kubernetes.io/created-for/pvc/namespace']].VolumeId" \
    --output text 2>/dev/null | tr '\t' '\n')
  
  # Remove duplicates
  local unique_volumes=($(printf "%s\n" "${volume_ids[@]}" | sort -u))
  
  if [[ ${#unique_volumes[@]} -eq 0 ]]; then
    log "No EBS volumes found associated with cluster ${CLUSTER_NAME}"
    return 0
  fi
  
  log "Found ${#unique_volumes[@]} EBS volume(s) to delete..."
  
  for vol_id in "${unique_volumes[@]}"; do
    [[ -z "$vol_id" ]] && continue
    
    # Get volume info for logging
    local vol_info
    vol_info=$(aws ec2 describe-volumes --region "${REGION}" \
      --volume-ids "$vol_id" \
      --query 'Volumes[0].[VolumeId,State,Size,Tags[?Key==`Name`].Value|[0]]' \
      --output text 2>/dev/null || true)
    
    local state=$(echo "$vol_info" | awk '{print $2}')
    local size=$(echo "$vol_info" | awk '{print $3}')
    local name=$(echo "$vol_info" | awk '{print $4}')
    
    log "  Deleting volume ${vol_id} (${size}GB, state: ${state}, name: ${name:-N/A})"
    
    # If volume is attached, try to detach it first
    if [[ "$state" == "in-use" ]]; then
      log "    Volume is attached, attempting to detach..."
      local attachment_info
      attachment_info=$(aws ec2 describe-volumes --region "${REGION}" \
        --volume-ids "$vol_id" \
        --query 'Volumes[0].Attachments[0].[InstanceId,Device]' \
        --output text 2>/dev/null || true)
      
      if [[ -n "$attachment_info" ]]; then
        local instance_id=$(echo "$attachment_info" | awk '{print $1}')
        aws ec2 detach-volume --region "${REGION}" --volume-id "$vol_id" --force 2>/dev/null || true
        log "    Detached from instance ${instance_id}, waiting for volume to be available..."
        
        # Wait for volume to become available (max 60 seconds)
        local waited=0
        while [[ $waited -lt 60 ]]; do
          local current_state
          current_state=$(aws ec2 describe-volumes --region "${REGION}" \
            --volume-ids "$vol_id" \
            --query 'Volumes[0].State' --output text 2>/dev/null || echo "deleted")
          
          if [[ "$current_state" == "available" ]]; then
            break
          elif [[ "$current_state" == "deleted" ]]; then
            log "    Volume already deleted"
            continue 2
          fi
          
          sleep 2
          waited=$((waited + 2))
        done
      fi
    fi
    
    # Delete the volume
    if aws ec2 delete-volume --region "${REGION}" --volume-id "$vol_id" 2>/dev/null; then
      log "    ✓ Deleted volume ${vol_id}"
    else
      warn "    Failed to delete volume ${vol_id} (may already be deleted or in use)"
    fi
  done
  
  log "✓ EBS volume cleanup complete"
}

# ---------- Minimal delete with comprehensive AWS cleanup ----------
delete_cluster_minimal() {
  log "===================================================================="
  log "  Starting comprehensive cleanup for cluster ${CLUSTER_NAME}"
  log "===================================================================="
  if [[ "${PRESERVE_VPC_ON_DELETE}" == "true" && ( ${#PRIVATE_SUBNETS[@]} -gt 0 || ${#PUBLIC_SUBNETS[@]} -gt 0 ) ]]; then
    log "  (VPC preserved: cluster was created in existing VPC; only EKS and related resources will be deleted)"
  fi
  echo ""

  # Store OIDC ARN before deleting cluster
  local OIDC_ARN=""; OIDC_ARN="$(get_oidc_provider_arn || true)"

  log "Step 1: Deleting IRSA Service Accounts and their CloudFormation stacks..."
  delete_iamserviceaccount_if_exists "${AUTOSCALER_NS}" "${AUTOSCALER_SA}"
  delete_iamserviceaccount_if_exists "${AI_NS}" "${RAY_HEAD_SA}"
  delete_iamserviceaccount_if_exists "${AI_NS}" "${RAY_WORKER_SA}"
  delete_iamserviceaccount_if_exists "${AI_NS}" "${SAIA_SERVICE_SA}"
  delete_iamserviceaccount_if_exists "${EBS_NS}" "${EBS_SA}"
  delete_iamserviceaccount_if_exists "${LBC_NS}" "${LBC_SA}"
  echo ""

  log "Step 2: Deleting IAM roles..."
  delete_role_if_exists "${AUTOSCALER_ROLE_NAME}"
  delete_role_if_exists "IRSA-${CLUSTER_NAME}-${RAY_HEAD_SA}"
  delete_role_if_exists "IRSA-${CLUSTER_NAME}-${RAY_WORKER_SA}"
  delete_role_if_exists "IRSA-${CLUSTER_NAME}-${SAIA_SERVICE_SA}"
  delete_role_if_exists "${EBS_IRSA_ROLE_NAME}"
  delete_role_if_exists "${LBC_ROLE_NAME}"
  echo ""

  log "Step 3: Cleaning up any eksctl-created EBS CSI addon roles..."
  local ebs_addon_roles=()
  while IFS= read -r role; do
    [[ -n "$role" ]] && ebs_addon_roles+=("$role")
  done < <(aws iam list-roles --query "Roles[?contains(RoleName, 'eksctl-${CLUSTER_NAME}-addon-aws-ebs-csi-driver')].RoleName" --output text | tr '\t' '\n')

  if [[ ${#ebs_addon_roles[@]} -gt 0 ]]; then
    log "Found ${#ebs_addon_roles[@]} eksctl-created EBS CSI addon role(s) to delete..."
    for role in "${ebs_addon_roles[@]}"; do
      delete_role_if_exists "$role"
    done
  else
    log "No eksctl-created EBS CSI addon roles found"
  fi
  echo ""

  log "Step 4: Deleting EKS addons..."
  eksctl delete addon --cluster "${CLUSTER_NAME}" --name aws-ebs-csi-driver --region "${REGION}" || true
  echo ""

  log "Step 5: Deleting EKS cluster ${CLUSTER_NAME}..."
  eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}" --wait || true
  log "Waiting for cluster CloudFormation stack to delete..."
  aws cloudformation wait stack-delete-complete --stack-name "eksctl-${CLUSTER_NAME}-cluster" --region "${REGION}" || true
  echo ""

  log "Step 6: Cleaning up lingering CloudFormation stacks..."
  # Delete nodegroup stacks
  local ng_stacks=()
  while IFS= read -r stack; do
    [[ -n "$stack" ]] && ng_stacks+=("$stack")
  done < <(aws cloudformation list-stacks --region "${REGION}" \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED DELETE_IN_PROGRESS \
      --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}-nodegroup-')].StackName" \
      --output text 2>/dev/null | tr '\t' '\n')

  if [[ ${#ng_stacks[@]} -gt 0 ]]; then
    log "Found ${#ng_stacks[@]} nodegroup stack(s) to delete..."
    for s in "${ng_stacks[@]}"; do
      log "Deleting nodegroup stack: $s"
      aws cloudformation delete-stack --stack-name "$s" --region "${REGION}" || true
      aws cloudformation wait stack-delete-complete --stack-name "$s" --region "${REGION}" || true
    done
  else
    log "No lingering nodegroup stacks found"
  fi

  # Delete IAMServiceAccount stacks
  local isa_stacks=()
  while IFS= read -r stack; do
    [[ -n "$stack" ]] && isa_stacks+=("$stack")
  done < <(aws cloudformation list-stacks --region "${REGION}" \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED DELETE_IN_PROGRESS \
      --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-')].StackName" \
      --output text 2>/dev/null | tr '\t' '\n')

  if [[ ${#isa_stacks[@]} -gt 0 ]]; then
    log "Found ${#isa_stacks[@]} IAMServiceAccount stack(s) to delete..."
    for s in "${isa_stacks[@]}"; do
      log "Deleting IAMServiceAccount stack: $s"
      aws cloudformation delete-stack --stack-name "$s" --region "${REGION}" || true
      aws cloudformation wait stack-delete-complete --stack-name "$s" --region "${REGION}" || true
    done
  else
    log "No lingering IAMServiceAccount stacks found"
  fi

  # Delete addon stacks
  local addon_stacks=()
  while IFS= read -r stack; do
    [[ -n "$stack" ]] && addon_stacks+=("$stack")
  done < <(aws cloudformation list-stacks --region "${REGION}" \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED DELETE_IN_PROGRESS \
      --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}-addon-')].StackName" \
      --output text 2>/dev/null | tr '\t' '\n')

  if [[ ${#addon_stacks[@]} -gt 0 ]]; then
    log "Found ${#addon_stacks[@]} addon stack(s) to delete..."
    for s in "${addon_stacks[@]}"; do
      log "Deleting addon stack: $s"
      aws cloudformation delete-stack --stack-name "$s" --region "${REGION}" || true
      aws cloudformation wait stack-delete-complete --stack-name "$s" --region "${REGION}" || true
    done
  else
    log "No lingering addon stacks found"
  fi
  echo ""

  log "Step 7: Deleting IAM policies..."
  if [[ "${USE_EXTERNAL_OBJ_STORE}" == "true" ]]; then
    delete_policy_if_exists "${AI_ECR_ONLY_POLICY_NAME}"
  else
    delete_policy_if_exists "${AI_BUCKET_POLICY_NAME}"
  fi
  delete_policy_if_exists "${LBC_POLICY_NAME}"
  echo ""

  log "Step 8: Purging all IRSA roles associated with this cluster's OIDC provider..."
  purge_irsa_roles_by_oidc
  echo ""

  log "Step 9: Deleting IAM OIDC provider..."
  delete_oidc_provider_if_exists "${OIDC_ARN}"
  echo ""

  log "Step 10: Deleting EBS volumes..."
  delete_cluster_ebs_volumes
  echo ""

  log "===================================================================="
  log "  Comprehensive cleanup complete for ${CLUSTER_NAME}"
  log "===================================================================="
  echo ""
  log "Summary of deleted resources:"
  log "  ✓ IAM Roles: Cluster Autoscaler, Ray (head/worker), SAIA, EBS Pod Identity"
  if [[ "${USE_EXTERNAL_OBJ_STORE}" == "true" ]]; then
    log "  ✓ IAM Policies: ECR-only policy for AI platform (external S3-compatible mode)"
  else
    log "  ✓ IAM Policies: S3 access policy for AI platform"
  fi
  log "  ✓ Pod Identity: EBS CSI driver association"
  log "  ✓ EKS Addons: EBS CSI driver, Pod Identity agent"
  log "  ✓ CloudFormation Stacks: All eksctl-created stacks"
  log "  ✓ OIDC Provider: IAM OIDC provider"
  log "  ✓ EKS Cluster: ${CLUSTER_NAME}"
  log "  ✓ EBS Volumes: All cluster-associated volumes"
  echo ""
  log "Verification commands:"
  echo "  # Check for remaining IAM roles:"
  echo "  aws iam list-roles --query \"Roles[?contains(RoleName, '${CLUSTER_NAME}')].RoleName\""
  echo ""
  echo "  # Check for remaining policies:"
  echo "  aws iam list-policies --scope Local --query \"Policies[?contains(PolicyName, '${CLUSTER_NAME}')].PolicyName\""
  echo ""
  echo "  # Check for remaining CloudFormation stacks:"
  echo "  aws cloudformation list-stacks --query \"StackSummaries[?contains(StackName, 'eksctl-${CLUSTER_NAME}')].StackName\""
  echo ""
  echo "  # Check for remaining EBS volumes:"
  echo "  aws ec2 describe-volumes --region ${REGION} --filters \"Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned\" --query 'Volumes[].VolumeId'"
  echo ""
}

# ---------- Optional full teardown ----------
delete_everything() {
  log "Full teardown starting (CRs/operators/uninstalls + AWS cleanup)"
  set +e
  kubectl -n "${AI_NS}" delete aiplatform "${AI_PLATFORM_NAME}" --ignore-not-found
  kubectl -n "${AI_NS}" delete standalones.enterprise.splunk.com "${AI_STANDALONE_NAME}" --ignore-not-found
  if [[ -f "${SPLUNK_AI_FILE}" ]]; then kubectl delete -f "${SPLUNK_AI_FILE}" --ignore-not-found; fi
  kubectl delete opentelemetrycollector "${OTEL_COLLECTOR_CR}" -n "${OTEL_NS}" --ignore-not-found
  helm uninstall "${OTEL_OPERATOR_RELEASE}" -n "${OTEL_NS}" || true
  helm uninstall "${AUTOSCALER_RELEASE}" -n "${AUTOSCALER_NS}" || true
  kubectl delete -f https://github.com/splunk/splunk-operator/releases/download/2.8.1/splunk-operator-cluster.yaml --ignore-not-found
  kubectl delete -k "github.com/ray-project/kuberay/ray-operator/config/default?ref=v1.2.2" --ignore-not-found
  helm uninstall "${LBC_RELEASE}" -n "${LBC_NS}" || true
  helm uninstall kube-prometheus -n monitoring || true
  helm uninstall cert-manager -n cert-manager || true
  kubectl delete storageclass gp3 --ignore-not-found
  set -e
  delete_cluster_minimal
}

# ---------- Helm retry wrapper ----------
helm_retry() {
  local tries="${1}"; shift
  local i=1 backoff=5 out rc
  while (( i <= tries )); do
    set +e
    out=$(helm "$@" 2>&1); rc=$?
    set -e
    if (( rc == 0 )); then printf "%s\n" "$out"; return 0; fi
    if grep -qiE 'timed out|operation timed out|i/o timeout|connection reset|TLS handshake timeout|could not get information about the resource' <<<"$out"; then
      warn "Helm transient error (attempt $i/$tries). Retrying in ${backoff}s…
$out"
      sleep "$backoff"; backoff=$(( backoff*2 )); (( i++ ))
    else
      echo "$out" >&2; return "$rc"
    fi
  done
  err "Helm failed after ${tries} attempts."
}

# ---------- PREFLIGHT ----------
PF_FAILS=0; PF_WARN=0
pf_header(){ echo -e "\n\033[1;34m[CHECK]\033[0m $*"; }
pf_ok(){ echo -e "  \033[1;32m✔\033[0m $*"; }
pf_warn(){ echo -e "  \033[1;33m!\033[0m $*"; PF_WARN=$((PF_WARN+1)); }
pf_fail(){ echo -e "  \033[1;31m✖\033[0m $*"; PF_FAILS=$((PF_FAILS+1)); }
pf_summary(){
  echo -e "\n\033[1;34m[SUMMARY]\033[0m Preflight complete: \033[1;32m${PF_FAILS} error(s)\033[0m, \033[1;33m${PF_WARN} warning(s)\033[0m."
  (( PF_FAILS == 0 )) || err "Preflight failed; please fix the above and rerun."
}
dns1123_ok(){ [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; }
s3_name_ok(){
  local n="$1"
  [[ ${#n} -ge 3 && ${#n} -le 63 ]] || return 1
  [[ "$n" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || return 1
  [[ "$n" != *".."* && "$n" != *".-"* && "$n" != *"-."* ]] || return 1
}

preflight_env() {
  pf_header "Configuration file"
  [[ -f "${CONFIG_FILE}" ]] && pf_ok "Config file present: ${CONFIG_FILE}" || pf_fail "Config file missing: ${CONFIG_FILE}"

  pf_header "Environment & inputs"
  [[ -n "$REGION" ]] && pf_ok "REGION=${REGION}" || pf_fail "REGION is empty"
  [[ -n "$CLUSTER_NAME" ]] && pf_ok "CLUSTER_NAME=${CLUSTER_NAME}" || pf_fail "CLUSTER_NAME is empty"
  dns1123_ok "$CLUSTER_NAME" || pf_fail "CLUSTER_NAME must be DNS-1123 compliant"
  [[ "$K8S_VERSION" =~ ^1\.[0-9]+$ ]] && pf_ok "K8S_VERSION=${K8S_VERSION}" || pf_fail "K8S_VERSION format invalid"
  if [[ "${USE_EXTERNAL_OBJ_STORE}" == "true" ]]; then
    pf_ok "Object storage: external S3-compatible (${OBJ_STORE_TYPE}); endpoint required"
    if [[ "${OBJ_STORE_TYPE}" == "seaweedfs" ]]; then
      if echo "${OBJ_STORE_ENDPOINT}" | grep -q ':9000'; then
        pf_warn "SeaweedFS uses port 8333 (not 9000). Endpoint has :9000 (MinIO); use http://host:8333 for SeaweedFS."
      else
        pf_ok "SeaweedFS endpoint: ${OBJ_STORE_ENDPOINT}"
      fi
    fi
  else
    s3_name_ok "$S3_BUCKET" && pf_ok "S3 bucket name valid: ${S3_BUCKET}" || pf_fail "S3 bucket name invalid: ${S3_BUCKET}"
  fi

  pf_header "Required files"
  [[ -f "${SPLUNK_OPERATOR_FILE}" ]] && pf_ok "SPLUNK_OPERATOR_FILE present: ${SPLUNK_OPERATOR_FILE}" || pf_fail "SPLUNK_OPERATOR_FILE missing: ${SPLUNK_OPERATOR_FILE}"
  [[ -f "${SPLUNK_AI_FILE}" ]] && pf_ok "SPLUNK_AI_FILE present: ${SPLUNK_AI_FILE}" || pf_fail "SPLUNK_AI_FILE missing: ${SPLUNK_AI_FILE}"
  if [[ -n "${SPLUNK_APP_LOCAL_PATH}" ]]; then
    [[ -f "${SPLUNK_APP_LOCAL_PATH}" ]] && pf_ok "Splunk app: ${SPLUNK_APP_LOCAL_PATH}" || pf_fail "SPLUNK_APP_LOCAL_PATH missing: ${SPLUNK_APP_LOCAL_PATH}"
  else
    pf_warn "SPLUNK_APP_LOCAL_PATH not set; app upload to S3 will be skipped"
  fi

  pf_header "Tools"
  for t in aws eksctl kubectl helm git jq yq curl; do
    if command -v "$t" >/dev/null 2>&1; then pf_ok "$t found ($(command -v $t))"; else pf_fail "$t not found in PATH"; fi
  done

  pf_header "AWS identity & region"
  local acct region_id
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  region_id="$(aws configure get region 2>/dev/null || true)"
  [[ -n "$acct" && "$acct" != "None" ]] && pf_ok "STS Account: $acct" || pf_fail "Cannot obtain STS identity"
  [[ -n "$region_id" ]] && pf_ok "CLI default region: ${region_id}" || pf_warn "No CLI default region; script uses REGION=${REGION}"

  pf_header "Subnets exist"
  # Check if subnets are provided (arrays may be empty)
  local subnet_count=$((${#PRIVATE_SUBNETS[@]} + ${#PUBLIC_SUBNETS[@]}))
  if [[ "${PRESERVE_VPC_ON_DELETE}" == "true" ]]; then
    if [[ ${#PRIVATE_SUBNETS[@]} -lt 2 ]]; then
      pf_fail "cluster.preserveVpcOnDelete is true: you must specify at least 2 private subnets under cluster.subnets.private so the cluster uses an existing VPC (VPC will not be deleted on 'delete')."
    else
      pf_ok "Preserve VPC on delete: using existing VPC (subnets specified); VPC will not be deleted when you run delete."
    fi
  fi
  if [[ $subnet_count -eq 0 ]]; then
    pf_ok "No subnets specified - eksctl will create new VPC and subnets automatically (NAT mode: Single = 1 Elastic IP)"
    pf_header "Elastic IP headroom (new VPC)"
    local eip_cnt
    eip_cnt="$(aws ec2 describe-addresses --region "${REGION}" --query 'length(Addresses)' --output text 2>/dev/null || true)"
    if [[ -n "${eip_cnt}" && "${eip_cnt}" =~ ^[0-9]+$ ]]; then
      pf_ok "Allocated Elastic IPs in ${REGION}: ${eip_cnt}"
      if (( eip_cnt >= 5 )); then
        pf_warn "Typical default EIP quota is 5 per region. At ${eip_cnt}+ addresses, NAT gateway EIP allocation may fail (you saw: maximum number of addresses). Release unused EIPs in EC2 → Elastic IPs or request a quota increase before create cluster."
      fi
    else
      pf_warn "Could not list Elastic IPs (aws ec2 describe-addresses). If create fails on NAT/EIP, check quotas and unused addresses."
    fi
  else
    local all_subnets=("${PRIVATE_SUBNETS[@]}" "${PUBLIC_SUBNETS[@]}")
    local vpc_id=""
    for s in "${all_subnets[@]}"; do
      if aws ec2 describe-subnets --subnet-ids "$s" --region "${REGION}" >/dev/null 2>&1; then
        pf_ok "Subnet ${s} exists"
        # Get VPC ID from first subnet
        if [[ -z "$vpc_id" ]]; then
          vpc_id=$(aws ec2 describe-subnets --subnet-ids "$s" --region "${REGION}" --query 'Subnets[0].VpcId' --output text)
        fi
      else
        pf_fail "Subnet ${s} not found in ${REGION}"
      fi
    done

    # Validate VPC networking if subnets are provided
    if [[ -n "$vpc_id" ]]; then
      pf_header "VPC networking validation"
      pf_ok "VPC ID: ${vpc_id}"

      # Check for NAT Gateway(s) in the VPC
      local nat_gateways
      nat_gateways=$(aws ec2 describe-nat-gateways --region "${REGION}" \
        --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available" \
        --query 'NatGateways[*].[NatGatewayId,State,SubnetId]' --output text)

      if [[ -z "$nat_gateways" ]]; then
        pf_fail "No available NAT Gateway found in VPC ${vpc_id}"
        pf_fail "Private subnets need NAT Gateway to reach internet for node bootstrapping"
        pf_fail "To fix: Create a NAT Gateway in a public subnet of this VPC"
      else
        local nat_count=$(echo "$nat_gateways" | wc -l | tr -d ' ')
        pf_ok "Found ${nat_count} NAT Gateway(s) in available state"
        echo "$nat_gateways" | while read -r nat_id state subnet_id; do
          pf_ok "  NAT Gateway ${nat_id} in subnet ${subnet_id}"
        done
      fi

      # Check Internet Gateway
      local igw_id
      igw_id=$(aws ec2 describe-internet-gateways --region "${REGION}" \
        --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
        --query 'InternetGateways[0].InternetGatewayId' --output text)

      if [[ -z "$igw_id" || "$igw_id" == "None" ]]; then
        pf_fail "No Internet Gateway attached to VPC ${vpc_id}"
        pf_fail "Public subnets need Internet Gateway for external connectivity"
      else
        pf_ok "Internet Gateway ${igw_id} attached to VPC"
      fi

      # Validate private subnet routes to NAT Gateway
      if [[ ${#PRIVATE_SUBNETS[@]} -gt 0 ]]; then
        pf_header "Private subnet routing"
        for subnet in "${PRIVATE_SUBNETS[@]}"; do
          local route_table_id
          route_table_id=$(aws ec2 describe-route-tables --region "${REGION}" \
            --filters "Name=association.subnet-id,Values=${subnet}" \
            --query 'RouteTables[0].RouteTableId' --output text)

          if [[ -z "$route_table_id" || "$route_table_id" == "None" ]]; then
            # Check if using main route table
            route_table_id=$(aws ec2 describe-route-tables --region "${REGION}" \
              --filters "Name=vpc-id,Values=${vpc_id}" "Name=association.main,Values=true" \
              --query 'RouteTables[0].RouteTableId' --output text)
            pf_warn "Subnet ${subnet} using main route table ${route_table_id}"
          fi

          # Check for NAT Gateway route
          local has_nat_route
          has_nat_route=$(aws ec2 describe-route-tables --region "${REGION}" \
            --route-table-ids "${route_table_id}" \
            --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && starts_with(NatGatewayId, `nat-`)].NatGatewayId' \
            --output text)

          if [[ -z "$has_nat_route" || "$has_nat_route" == "None" ]]; then
            pf_fail "Private subnet ${subnet} (RT: ${route_table_id}) has no route to NAT Gateway"
            pf_fail "Nodes in this subnet won't be able to download kubelet/images or join cluster"
          else
            pf_ok "Private subnet ${subnet} has route to NAT Gateway ${has_nat_route}"
          fi
        done
      fi

      # Validate public subnet routes to Internet Gateway
      if [[ ${#PUBLIC_SUBNETS[@]} -gt 0 ]]; then
        pf_header "Public subnet routing"
        for subnet in "${PUBLIC_SUBNETS[@]}"; do
          local route_table_id
          route_table_id=$(aws ec2 describe-route-tables --region "${REGION}" \
            --filters "Name=association.subnet-id,Values=${subnet}" \
            --query 'RouteTables[0].RouteTableId' --output text)

          if [[ -z "$route_table_id" || "$route_table_id" == "None" ]]; then
            route_table_id=$(aws ec2 describe-route-tables --region "${REGION}" \
              --filters "Name=vpc-id,Values=${vpc_id}" "Name=association.main,Values=true" \
              --query 'RouteTables[0].RouteTableId' --output text)
            pf_warn "Public subnet ${subnet} using main route table ${route_table_id}"
          fi

          # Check for Internet Gateway route
          local has_igw_route
          has_igw_route=$(aws ec2 describe-route-tables --region "${REGION}" \
            --route-table-ids "${route_table_id}" \
            --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && starts_with(GatewayId, `igw-`)].GatewayId' \
            --output text)

          if [[ -z "$has_igw_route" || "$has_igw_route" == "None" ]]; then
            pf_fail "Public subnet ${subnet} (RT: ${route_table_id}) has no route to Internet Gateway"
          else
            pf_ok "Public subnet ${subnet} has route to Internet Gateway ${has_igw_route}"
          fi
        done
      fi

      # Check subnet requirements
      pf_header "Subnet requirements"
      if [[ ${#PRIVATE_SUBNETS[@]} -lt 2 ]]; then
        pf_fail "Need at least 2 private subnets in different AZs (found ${#PRIVATE_SUBNETS[@]})"
      else
        pf_ok "Found ${#PRIVATE_SUBNETS[@]} private subnet(s)"
      fi

      if [[ ${#PUBLIC_SUBNETS[@]} -lt 2 ]]; then
        pf_warn "Need at least 2 public subnets for HA (found ${#PUBLIC_SUBNETS[@]})"
      else
        pf_ok "Found ${#PUBLIC_SUBNETS[@]} public subnet(s)"
      fi
    fi
  fi

  pf_header "AWS credentials available"
  pf_warn "AWS credentials check: Only needed for Splunk Standalone's S3 secret (not for AI platform - uses IRSA)"
  if resolve_aws_creds_for_secret 2>/dev/null; then
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
      pf_ok "Env creds OK (with session token) - will create s3-secret for Splunk Standalone"
    else
      pf_ok "Env creds OK - will create s3-secret for Splunk Standalone"
    fi
  else
    pf_warn "AWS credentials not available. Splunk Standalone deployment will fail if attempted."
    pf_warn "To fix: export AWS_PROFILE=<your-profile> && aws sso login --profile <your-profile>"
    pf_warn "Or set: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
  fi
}

preflight_api_connectivity() {
  pf_header "Kubernetes API reachability"
  local host; host="$(endpoint_host)"
  if [[ -z "$host" ]]; then
    pf_warn "Cluster endpoint not resolvable yet (cluster may not exist). Skipping API checks."
    return 0
  fi
  pf_ok "API endpoint: ${host}:443"

  if [[ -n "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" ]]; then
    if [[ "${NO_PROXY:-}${no_proxy:-}" != *"$host"* ]]; then
      pf_warn "Proxy detected but NO_PROXY missing ${host}. Recommend:
  export NO_PROXY=\"${NO_PROXY:-}${NO_PROXY:+,}${host}\"
  export no_proxy=\"${no_proxy:-}${no_proxy:+,}${host}\""
    else
      pf_ok "NO_PROXY includes ${host}"
    fi
  else
    pf_ok "No HTTP(S) proxy detected."
  fi

  if command -v nc >/dev/null 2>&1; then
    if nc -z -w 5 "${host}" 443; then pf_ok "TCP 443 reachable"; else pf_fail "Cannot reach ${host}:443 (TCP test failed)"; fi
  else
    if bash -lc "cat < /dev/null > /dev/tcp/${host}/443" timeout 10 2>/dev/null; then pf_ok "TCP 443 reachable"; else pf_fail "Cannot reach ${host}:443"; fi
  fi

  if kubectl --request-timeout=10s get --raw='/livez' >/dev/null 2>&1; then
    pf_ok "kubectl /livez OK"
  else
    pf_fail "kubectl /livez failed. Try: aws eks update-kubeconfig; aws sso login; fix NO_PROXY."
  fi
}

# ---------- ECR Access for AI Platform ----------
add_ecr_permissions_to_role() {
  local role="$1"
  log "Adding ECR read permissions to IAM role: ${role}"

  # Check if inline policy already exists
  local policy_exists
  policy_exists="$(aws iam list-role-policies --role-name "${role}" \
    --query "PolicyNames[?@=='ECRReadAccess'] | length(@)" --output text 2>/dev/null || echo 0)"

  if [[ "$policy_exists" == "1" ]]; then
    log "ECR policy already attached to ${role}"
    return 0
  fi

  # Add inline policy for ECR read access
  aws iam put-role-policy \
    --role-name "${role}" \
    --policy-name "ECRReadAccess" \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "ecr:GetAuthorizationToken",
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage"
          ],
          "Resource": "*"
        }
      ]
    }'

  log "✓ ECR permissions added to ${role}"
}

# ---------- Orchestrator for AI Platform setup ----------
install_ai_platform_stack() {
  log "=== Setting up Splunk AI Platform stack ==="
  if [[ "${USE_EXTERNAL_OBJ_STORE}" == "true" ]]; then
    log "Using external S3-compatible object storage (${OBJ_STORE_TYPE}); skipping S3 bucket creation; using ECR-only policy for IRSA."
    ensure_external_objstore_upload_splunk_app
  else
    ensure_s3_bucket_and_prefixes
    ensure_s3_upload_splunk_app
  fi
  ensure_namespace "${AI_NS}"

  local policy_arn
  if [[ "${USE_EXTERNAL_OBJ_STORE}" == "true" ]]; then
    policy_arn="$(ensure_ecr_only_policy)"
  else
    policy_arn="$(ensure_bucket_policy "${AI_BUCKET_POLICY_NAME}" "${S3_BUCKET}")"
  fi

  ensure_irsa_for_sa "${RAY_HEAD_SA}"      "${AI_NS}" "${policy_arn}"
  ensure_irsa_for_sa "${RAY_WORKER_SA}"    "${AI_NS}" "${policy_arn}"
  ensure_irsa_for_sa "${SAIA_SERVICE_SA}"  "${AI_NS}" "${policy_arn}"

  # Add ECR permissions for pulling container images from private ECR repos
  log "Adding ECR permissions to AI platform service account roles..."
  add_ecr_permissions_to_role "IRSA-${CLUSTER_NAME}-${RAY_HEAD_SA}"
  add_ecr_permissions_to_role "IRSA-${CLUSTER_NAME}-${RAY_WORKER_SA}"
  add_ecr_permissions_to_role "IRSA-${CLUSTER_NAME}-${SAIA_SERVICE_SA}"

  install_splunk_standalone

  local splunk_secret
  splunk_secret="$(find_splunk_standalone_secret_name "${AI_NS}" "${AI_STANDALONE_NAME}")"
  splunk_secret="${splunk_secret//$'\r'/}"; splunk_secret="${splunk_secret//$'\n'/}"

  # update_splunk_secret_password_only "${AI_NS}" "${splunk_secret}"

  install_ai_platform_cr "${splunk_secret}"

  log "=== Splunk AI Platform setup completed ==="
}

# ---------- CREATE / RECONCILE / DELETE FLOWS ----------
create_cluster_flow() {
  create_cluster_config
  create_cluster
  # H100 with capacity reservation: eksctl cannot manage these nodes — create via CloudFormation
  if [[ "$DEFAULT_ACCELERATOR" == "H100" && -n "$GPU_CAPACITY_RESERVATION_ID" ]]; then
    create_gpu_nodegroup_with_capacity_block
  fi
}

reconcile_flow() {
  ensure_oidc
  ensure_ebs_irsa_role
  install_ebs_csi_addon
  verify_ebs_csi_ready
  create_gp3_storageclass
  install_cluster_autoscaler
  install_nvidia_device_plugin
  uncordon_ready_nodes
  # H100 with capacity reservation: create GPU node group if not already present
  if [[ "$DEFAULT_ACCELERATOR" == "H100" && -n "$GPU_CAPACITY_RESERVATION_ID" ]]; then
    local gpu_node_count
    gpu_node_count=$(kubectl get nodes -l nvidia.com/gpu=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$gpu_node_count" -lt 1 ]]; then
      create_gpu_nodegroup_with_capacity_block
    else
      log "Found ${gpu_node_count} H100 GPU node(s) — skipping capacity block creation."
    fi
  fi
  install_kube_prometheus
  install_cert_manager
  # Validate BYO target-group config before any side-effecting calls. Fail
  # fast if the customer set byoTargetGroup.enabled=true without LBC or
  # required ARN/SG fields — better an early error than a silently-broken
  # data path.
  validate_byo_target_group_config
  # AWS Load Balancer Controller (LBC) — required when the operator provisions
  # NLBs/ALBs (Mode 1: Service type=LoadBalancer + `aws-load-balancer-type:
  # external` annotation) or when binding the SAIA Service to a customer-
  # managed target group via TargetGroupBinding (Mode 2: byoTargetGroup
  # enabled). Off-AWS deployments leave this false.
  if [[ "${INSTALL_LBC}" == "true" ]]; then
    log "aiPlatform.awsLoadBalancerController.install=true — installing AWS Load Balancer Controller"
    tag_lbc_subnets
    ensure_lbc_irsa
    install_aws_load_balancer_controller
  else
    log "aiPlatform.awsLoadBalancerController.install=false — skipping LBC install"
  fi
  ensure_s3compat_credentials
  install_otel_operator_and_contrib_collector
  install_ray_operator
  install_splunk_operator
  install_splunk_ai_operator
  install_ai_platform_stack
  if should_wait_for_splunk_app_install; then
    wait_splunk_ai_assistant_installed "Splunk_AI_Assistant_Cloud.tgz" 1200
  else
    log "Skipping Splunk AI Assistant app wait because no local app archive is configured"
  fi
  # push_saia_conf_into_pod
}

# ---------- MAIN ----------
main_install() {
  for t in aws eksctl kubectl helm git jq yq curl; do need "$t"; done

  # Load configuration from YAML file
  load_config

  # Force region for all AWS CLI and eksctl commands
  export AWS_DEFAULT_REGION="${REGION}"
  export AWS_REGION="${REGION}"
  log "Using AWS Region: ${REGION}"

  # Validate and configure container images
  validate_image_config
  configure_images

  # Validate images exist in registries (unless explicitly skipped)
  if [[ "${SKIP_IMAGE_VALIDATION:-false}" != "true" ]]; then
    validate_images_exist
  else
    warn "⚠️  SKIPPING image validation (SKIP_IMAGE_VALIDATION=true)"
    warn "⚠️  Deployment may fail if images don't exist!"
  fi

  log "Region: ${REGION}, Account: ${ACCOUNT_ID}, Cluster: ${CLUSTER_NAME}"

  preflight_env
  pf_summary

  if cluster_exists; then
    ensure_kubeconfig
    preflight_api_connectivity
    pf_summary
  fi

  # Idempotent: create cluster only if it does not exist. When cluster.useExisting is true, fail if cluster is missing.
  if ! cluster_exists; then
    if [[ "${USE_EXISTING_CLUSTER}" == "true" ]]; then
      err "cluster.useExisting is true but cluster '${CLUSTER_NAME}' was not found in ${REGION}. Create the cluster first or set useExisting: false."
      exit 1
    fi
    create_cluster_flow
    ensure_kubeconfig
  else
    log "Cluster ${CLUSTER_NAME} already exists; skipping cluster creation (idempotent)."
  fi

  preflight_api_connectivity
  pf_summary

  reconcile_flow
  log "Install complete"
}

usage() {
  echo "Usage: $0 {install|delete|delete-full}"
  echo "  install      preflight + create/reconcile cluster and components (idempotent)"
  echo "  delete       delete cluster and ALL AWS resources/roles/policies created by this script"
  echo "  delete-full  uninstall CRs/operators then run comprehensive AWS cleanup"
}

case "${1:-install}" in
  install)
    main_install
    ;;
  delete)
    load_config
    delete_cluster_minimal
    ;;
  delete-full)
    load_config
    delete_everything
    ;;
  *) usage; exit 1 ;;
esac
