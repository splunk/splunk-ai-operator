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

# ====== CONFIG ======
CLUSTER_NAME="conf-gpu-cpu-5"
REGION="us-west-2"
K8S_VERSION="1.31"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Pod Identity for EBS CSI (addon)
EBS_PI_ROLE_NAME="EBSCSIDriverPodIdentityRole-${CLUSTER_NAME}"
EBS_SA="ebs-csi-controller-sa"
EBS_NS="kube-system"

# Cluster Autoscaler (IRSA)
AUTOSCALER_RELEASE="cluster-autoscaler"
AUTOSCALER_ROLE_NAME="ClusterAutoscalerRole-${CLUSTER_NAME}"
AUTOSCALER_SA="cluster-autoscaler"
AUTOSCALER_NS="kube-system"
CA_IMAGE_TAG_DEFAULT="v${K8S_VERSION}.2"
AUTOSCALER_IMAGE_TAG="${AUTOSCALER_IMAGE_TAG:-$CA_IMAGE_TAG_DEFAULT}"

# OpenTelemetry (operator + contrib collector)
OTEL_NS="observability"
OTEL_OPERATOR_RELEASE="otel-operator"
OTEL_COLLECTOR_CR="otel-collector"

# Splunk operators
SPLUNK_AI_NS="splunk-ai-operator-system"
SPLUNK_AI_FILE="./artifacts.yaml"   # local bundle for Splunk AI Operator

# AI Platform app namespace + S3 bucket & prefixes
AI_NS="ai-platform"
S3_BUCKET_RAW="${CLUSTER_NAME}"
S3_BUCKET="$(echo "${S3_BUCKET_RAW}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9.-')"
S3_BUCKET="ai-platform-bucket-us-west-2"
S3_PREFIXES=("artifacts/" "apps/" "tasks/")
AI_STANDALONE_NAME="splunk-standalone"
AI_PLATFORM_NAME="splunk-ai-stack"
AI_BUCKET_POLICY_NAME="S3Access-${CLUSTER_NAME}-ai-platform"

# Optional app upload
SPLUNK_APP_LOCAL_PATH="${SPLUNK_APP_LOCAL_PATH:-}"

# Nodegroups
ENABLE_CPU=true
ENABLE_GPU=true

# VPC subnets
PRIVATE_2A="subnet-073c013016df5c3eb"
PRIVATE_2B="subnet-0d009b9d42a1a0db2"
PRIVATE_2D="subnet-0ed6f0842d28992fc"
PUBLIC_2A="subnet-00b88b41317f0762a"
PUBLIC_2B="subnet-0cfb9b590fe21e071"
PUBLIC_2D="subnet-02034918dee3a7d69"

# ---- logging ----
log()   { echo -e "\033[1;32m[INFO]\033[0m $*" >&2; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || err "Missing $1 in PATH"; }
need_file(){ [[ -f "$1" ]] || err "Missing file: $1"; }
all_ok(){ return 0; }

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
  local ver="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.17.3}"
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
  if $ENABLE_CPU; then
    nodes+="
  - name: cpu-nodes
    instanceType: m5.xlarge
    desiredCapacity: 4
    minSize: 2
    maxSize: 8
    volumeSize: 500
    volumeType: gp3
    tags:
      Name: ${CLUSTER_NAME}-cpu
      Environment: prod
      kubernetes.io/cluster/${CLUSTER_NAME}: owned
      k8s.io/cluster-autoscaler/enabled: \"true\"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: owned"
  fi
  if $ENABLE_GPU; then
    nodes+="
  - name: gpu-nodes
    instanceType: g6e.12xlarge
    desiredCapacity: 2
    minSize: 2
    maxSize: 4
    volumeSize: 1000
    volumeType: gp3
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
  cat <<EOF > eks-cluster-config.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "${K8S_VERSION}"
iam:
  withOIDC: true
addons:
  - name: vpc-cni
  - name: kube-proxy
  - name: coredns
  - name: eks-pod-identity-agent
vpc:
  subnets:
    private:
      us-west-2a: { id: ${PRIVATE_2A} }
      us-west-2b: { id: ${PRIVATE_2B} }
      us-west-2d: { id: ${PRIVATE_2D} }
    public:
      us-west-2a: { id: ${PUBLIC_2A} }
      us-west-2b: { id: ${PUBLIC_2B} }
      us-west-2d: { id: ${PUBLIC_2D} }
managedNodeGroups:
$(generate_node_groups)
EOF
}

create_cluster() { log "Creating EKS cluster..."; eksctl create cluster -f eks-cluster-config.yaml; ensure_kubeconfig; }

ensure_oidc() {
  log "Ensuring IAM OIDC provider is associated..."
  local issuer; issuer=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)
  if [[ -z "$issuer" || "$issuer" == "None" ]]; then
    eksctl utils associate-iam-oidc-provider --region "${REGION}" --cluster "${CLUSTER_NAME}" --approve
  fi
}

# ---------- EBS CSI via Pod Identity ----------
install_ebs_csi_addon() {
  log "Installing aws-ebs-csi-driver add-on (Pod Identity path)..."
  eksctl create addon --cluster "${CLUSTER_NAME}" --name eks-pod-identity-agent --force || true
  eksctl create addon --cluster "${CLUSTER_NAME}" --name aws-ebs-csi-driver --force || true
  wait_pod_identity_agent_best_effort 180
}

ensure_ebs_pod_identity_role() {
  local policy_file; policy_file="$(render_pi_trust_policy)"
  if aws iam get-role --role-name "${EBS_PI_ROLE_NAME}" >/dev/null 2>&1; then
    log "Pod Identity role exists: ${EBS_PI_ROLE_NAME} (updating trust policy if needed)"
  else
    log "Creating Pod Identity IAM role: ${EBS_PI_ROLE_NAME}"
    aws iam create-role --role-name "${EBS_PI_ROLE_NAME}" --assume-role-policy-document "file://${policy_file}"
  fi
  aws iam update-assume-role-policy --role-name "${EBS_PI_ROLE_NAME}" --policy-document "file://${policy_file}"
  if ! aws iam list-attached-role-policies --role-name "${EBS_PI_ROLE_NAME}" \
      --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy'] | length(@)" \
      --output text | grep -q '^1$'; then
    aws iam attach-role-policy --role-name "${EBS_PI_ROLE_NAME}" --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  fi
}

ensure_ebs_pod_identity_association() {
  local assoc_id
  assoc_id="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" \
    --query "associations[?namespace=='${EBS_NS}' && serviceAccount=='${EBS_SA}'].associationId" \
    --output text 2>/dev/null || true)"
  if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
    log "Pod Identity association exists: $assoc_id"; return 0
  fi
  log "Creating Pod Identity association for ${EBS_NS}/${EBS_SA}"
  local role_arn="arn:aws:iam::${ACCOUNT_ID}:role/${EBS_PI_ROLE_NAME}"
  local i; for i in {1..6}; do
    if aws eks create-pod-identity-association \
      --cluster-name "${CLUSTER_NAME}" \
      --namespace "${EBS_NS}" \
      --service-account "${EBS_SA}" \
      --role-arn "${role_arn}" >/dev/null 2>&1; then
      log "Pod Identity association created."; return 0
    fi
    warn "Association not ready yet (attempt $i/6). Waiting 5s..."; sleep 5
  done
  aws eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" --namespace "${EBS_NS}" --service-account "${EBS_SA}" --role-arn "${role_arn}"
}

verify_ebs_csi_ready() { wait_rollout kube-system deploy ebs-csi-controller; wait_rollout kube-system ds ebs-csi-node; }

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
install_cluster_autoscaler() {
  log "Installing Cluster Autoscaler with IRSA..."
  eksctl create iamserviceaccount \
    --cluster "${CLUSTER_NAME}" \
    --name "${AUTOSCALER_SA}" \
    --namespace "${AUTOSCALER_NS}" \
    --role-name "${AUTOSCALER_ROLE_NAME}" \
    --attach-policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess \
    --approve \
    --override-existing-serviceaccounts

  helm repo add autoscaler https://kubernetes.github.io/autoscaler
  helm repo update

  helm_retry 5 upgrade --install "${AUTOSCALER_RELEASE}" autoscaler/cluster-autoscaler \
    --namespace "${AUTOSCALER_NS}" \
    --set autoDiscovery.clusterName="${CLUSTER_NAME}" \
    --set awsRegion="${REGION}" \
    --set rbac.serviceAccount.create=false \
    --set rbac.serviceAccount.name="${AUTOSCALER_SA}" \
    --set image.repository=registry.k8s.io/autoscaling/cluster-autoscaler \
    --set image.tag="${AUTOSCALER_IMAGE_TAG}" \
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
  log "Installing Ray Operator v1.2.2..."
  kubectl apply -k "github.com/ray-project/kuberay/ray-operator/config/default?ref=v1.2.2" --server-side --force-conflicts
  wait_rollout ray-system deploy kuberay-operator
}

# ---------- Splunk Operator(s) ----------
install_splunk_operator() {
  log "Installing Splunk Operator (cluster-scope manifest in CWD)..."
  need_file ./splunk-operator-cluster.yaml
  kubectl apply -f ./splunk-operator-cluster.yaml --server-side --force-conflicts
  kubectl set env deployment/splunk-operator-controller-manager  -n splunk-operator RELATED_IMAGE_SPLUNK_ENTERPRISE=vivekrsplunk/splunk:ef65e8205e4d-6d943f7-28228924
  kubectl set env deployment/splunk-operator-controller-manager  -n splunk-operator SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com
#  check_ready splunk-operator "name=splunk-operator"
#  wait_for_crd standalones.enterprise.splunk.com 600
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

  resolve_aws_creds_for_secret
  local ak="${AWS_ACCESS_KEY_ID:-}"; local sk="${AWS_SECRET_ACCESS_KEY:-}"; local st="${AWS_SESSION_TOKEN:-}"
  [[ -z "$ak" || -z "$sk" ]] && err "Missing AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY after resolution."
  kubectl -n "${AI_NS}" create secret generic s3-secret \
    --from-literal=s3_access_key="${ak}" \
    --from-literal=s3_secret_key="${sk}" \
    $( [[ -n "$st" ]] && printf -- "--from-literal=s3_session_token=%s" "$st" ) \
    --dry-run=client -o yaml | kubectl apply -f -

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

  cat <<YAML | kubectl apply --server-side --force-conflicts -f -
apiVersion: enterprise.splunk.com/v4
kind: Standalone
metadata:
  name: ${AI_STANDALONE_NAME}
  namespace: ${AI_NS}
spec:
  serviceAccount: saia-service-sa
  etcVolumeStorageConfig:
    storageClassName: gp3
  varVolumeStorageConfig:
    storageClassName: gp3
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
        endpoint: https://s3.amazonaws.com
        region: ${REGION}
        path: ${S3_BUCKET}
        secretRef: s3-secret
YAML

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
  local waited=0 max_wait=1800
  log "Waiting for AIPlatform/${AI_PLATFORM_NAME} Ready condition (up to $((max_wait/60))m)..."
  while true; do
    local cond; cond=$(kubectl -n "${AI_NS}" get aiplatforms.ai.splunk.com "${AI_PLATFORM_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "$cond" == "True" ]]; then log "AIPlatform is Ready"; return 0; fi
    [[ $waited -ge $max_wait ]] && { warn "Timed out waiting for AIPlatform Ready (continuing)."; return 0; }
    sleep 10; waited=$((waited+10))
  done
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

  cat <<YAML | kubectl -n "${AI_NS}" apply --server-side --force-conflicts -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${AI_PLATFORM_NAME}
spec:
  objectStorage:
    path: s3://${S3_BUCKET}
    region: ${REGION}
  serviceAccountName: ray-head-sa
  defaultAcceleratorType: L40S
  features:
    - name: saia
      version: "1.1.0"
      serviceAccountName: saia-service-sa
      scaleFactor: 1
  sidecars:
    otel: true
  storage:
    vectorDB:
      size: 50Gi
      storageClassName: gp3
  workerGroupConfig:
    serviceAccountName: ray-worker-sa
  cpuScheduler: {}
  gpuScheduler:
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
  ingress:
    className: nginx
    hosts:
      - host: ai.example.com
        paths: [ { path: "/", pathType: Prefix } ]
    tls:
      - hosts: [ ai.example.com ]
        secretName: ai-platform-tls
  splunkConfiguration:
    endpoint: ${AI_STANDALONE_NAME}-standalone-service
    secretRef: { name: ${secret_name} }
  certificateRef: platform-issuer
YAML

  wait_aiplatform_ready
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
  mapfile -t roles < <(aws iam list-roles --query 'Roles[].RoleName' --output text | tr '\t' '\n')
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
    mapfile -t lines < <(aws s3api list-object-versions --bucket "$bucket" --query 'Versions[].join(`\t`, [Key, VersionId])' --output text 2>/dev/null || true)
    [[ "${#lines[@]}" -eq 0 ]] && break
    for l in "${lines[@]}"; do
      local key="${l%%$'\t'*}"
      local ver="${l##*$'\t'}"
      aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$ver" >/dev/null || true
    done
  done
  while true; do
    mapfile -t lines < <(aws s3api list-object-versions --bucket "$bucket" --query 'DeleteMarkers[].join(`\t`, [Key, VersionId])' --output text 2>/dev/null || true)
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

# ---------- Minimal delete with comprehensive AWS cleanup ----------
delete_cluster_minimal() {
  log "Starting comprehensive cleanup for cluster ${CLUSTER_NAME} (${REGION})"
  local OIDC_ARN=""; OIDC_ARN="$(get_oidc_provider_arn || true)"
  delete_iamserviceaccount_if_exists "${AUTOSCALER_NS}" "${AUTOSCALER_SA}"
  delete_iamserviceaccount_if_exists "${AI_NS}" "ray-head-sa"
  delete_iamserviceaccount_if_exists "${AI_NS}" "ray-worker-sa"
  delete_iamserviceaccount_if_exists "${AI_NS}" "saia-service-sa"
  delete_role_if_exists "${AUTOSCALER_ROLE_NAME}"
  delete_role_if_exists "IRSA-${CLUSTER_NAME}-ray-head-sa"
  delete_role_if_exists "IRSA-${CLUSTER_NAME}-ray-worker-sa"
  delete_role_if_exists "IRSA-${CLUSTER_NAME}-saia-service-sa"
  local assoc_id
  assoc_id="$(aws eks list-pod-identity-associations \
    --cluster-name "${CLUSTER_NAME}" \
    --query "associations[?namespace=='${EBS_NS}' && serviceAccount=='${EBS_SA}'].associationId" \
    --output text 2>/dev/null || true)"
  if [[ -n "$assoc_id" && "$assoc_id" != "None" ]]; then
    log "Deleting EBS Pod Identity association $assoc_id"
    aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" --association-id "$assoc_id" || true
  fi
  delete_role_if_exists "${EBS_PI_ROLE_NAME}"
  eksctl delete addon --cluster "${CLUSTER_NAME}" --name aws-ebs-csi-driver --region "${REGION}" || true
  eksctl delete addon --cluster "${CLUSTER_NAME}" --name eks-pod-identity-agent --region "${REGION}" || true
  log "Deleting EKS cluster ${CLUSTER_NAME} ..."
  eksctl delete cluster --name "${CLUSTER_NAME}" --region "${REGION}" --wait || true
  aws cloudformation wait stack-delete-complete --stack-name "eksctl-${CLUSTER_NAME}-cluster" || true
  for s in $(aws cloudformation list-stacks \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED DELETE_IN_PROGRESS \
      --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}-nodegroup-')].StackName" \
      --output text 2>/dev/null || true); do
    log "Deleting lingering nodegroup stack: $s"
    aws cloudformation delete-stack --stack-name "$s" || true
    aws cloudformation wait stack-delete-complete --stack-name "$s" || true
  done
  for s in $(aws cloudformation list-stacks \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED DELETE_IN_PROGRESS \
      --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-')].StackName" \
      --output text 2>/dev/null || true); do
    log "Deleting lingering IAMServiceAccount stack: $s"
    aws cloudformation delete-stack --stack-name "$s" || true
    aws cloudformation wait stack-delete-complete --stack-name "$s" || true
  done
  delete_policy_if_exists "${AI_BUCKET_POLICY_NAME}"
  purge_irsa_roles_by_oidc
  delete_oidc_provider_if_exists "${OIDC_ARN}"
  log "Comprehensive cleanup complete."
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
  pf_header "Environment & inputs"
  [[ -n "$REGION" ]] && pf_ok "REGION=${REGION}" || pf_fail "REGION is empty"
  [[ -n "$CLUSTER_NAME" ]] && pf_ok "CLUSTER_NAME=${CLUSTER_NAME}" || pf_fail "CLUSTER_NAME is empty"
  dns1123_ok "$CLUSTER_NAME" || pf_fail "CLUSTER_NAME must be DNS-1123 compliant"
  [[ "$K8S_VERSION" =~ ^1\.[0-9]+$ ]] && pf_ok "K8S_VERSION=${K8S_VERSION}" || pf_fail "K8S_VERSION format invalid"
  s3_name_ok "$S3_BUCKET" && pf_ok "S3 bucket name valid: ${S3_BUCKET}" || pf_fail "S3 bucket name invalid: ${S3_BUCKET}"

  pf_header "Required files"
  [[ -f ./splunk-operator-cluster.yaml ]] && pf_ok "splunk-operator-cluster.yaml present" || pf_fail "splunk-operator-cluster.yaml missing"
  [[ -f "${SPLUNK_AI_FILE}" ]] && pf_ok "SPLUNK_AI_FILE present: ${SPLUNK_AI_FILE}" || pf_fail "SPLUNK_AI_FILE missing: ${SPLUNK_AI_FILE}"
  if [[ -n "${SPLUNK_APP_LOCAL_PATH}" ]]; then
    [[ -f "${SPLUNK_APP_LOCAL_PATH}" ]] && pf_ok "Splunk app: ${SPLUNK_APP_LOCAL_PATH}" || pf_fail "SPLUNK_APP_LOCAL_PATH missing: ${SPLUNK_APP_LOCAL_PATH}"
  else
    pf_warn "SPLUNK_APP_LOCAL_PATH not set; app upload to S3 will be skipped"
  fi

  pf_header "Tools"
  for t in aws eksctl kubectl helm git jq; do
    if command -v "$t" >/dev/null 2>&1; then pf_ok "$t found ($(command -v $t))"; else pf_fail "$t not found in PATH"; fi
  done

  pf_header "AWS identity & region"
  local acct region_id
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  region_id="$(aws configure get region 2>/dev/null || true)"
  [[ -n "$acct" && "$acct" != "None" ]] && pf_ok "STS Account: $acct" || pf_fail "Cannot obtain STS identity"
  [[ -n "$region_id" ]] && pf_ok "CLI default region: ${region_id}" || pf_warn "No CLI default region; script uses REGION=${REGION}"

  pf_header "Subnets exist"
  local subs=("$PRIVATE_2A" "$PRIVATE_2B" "$PRIVATE_2D" "$PUBLIC_2A" "$PUBLIC_2B" "$PUBLIC_2D")
  for s in "${subs[@]}"; do
    if aws ec2 describe-subnets --subnet-ids "$s" --region "${REGION}" >/dev/null 2>&1; then
      pf_ok "Subnet ${s} exists"
    else
      pf_fail "Subnet ${s} not found in ${REGION}"
    fi
  done

  pf_header "AWS credentials available"
  if resolve_aws_creds_for_secret; then
    if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then pf_ok "Env creds OK (with session token)"; else pf_ok "Env creds OK"; fi
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

# ---------- Orchestrator for AI Platform setup ----------
install_ai_platform_stack() {
  log "=== Setting up Splunk AI Platform stack ==="
  ensure_s3_bucket_and_prefixes
  ensure_s3_upload_splunk_app
  ensure_namespace "${AI_NS}"

  local policy_arn; policy_arn="$(ensure_bucket_policy "${AI_BUCKET_POLICY_NAME}" "${S3_BUCKET}")"

  ensure_irsa_for_sa ray-head-sa      "${AI_NS}" "${policy_arn}"
  ensure_irsa_for_sa ray-worker-sa    "${AI_NS}" "${policy_arn}"
  ensure_irsa_for_sa saia-service-sa  "${AI_NS}" "${policy_arn}"

  install_splunk_standalone

  local splunk_secret
  splunk_secret="$(find_splunk_standalone_secret_name "${AI_NS}" "${AI_STANDALONE_NAME}")"
  splunk_secret="${splunk_secret//$'\r'/}"; splunk_secret="${splunk_secret//$'\n'/}"

  # update_splunk_secret_password_only "${AI_NS}" "${splunk_secret}"

  install_ai_platform_cr "${splunk_secret}"

  log "=== Splunk AI Platform setup completed ==="
}

# ---------- CREATE / RECONCILE / DELETE FLOWS ----------
create_cluster_flow() { create_cluster_config; create_cluster; }

reconcile_flow() {
  ensure_oidc
  install_ebs_csi_addon
  ensure_ebs_pod_identity_role
  ensure_ebs_pod_identity_association
  verify_ebs_csi_ready
  create_gp3_storageclass
  install_cluster_autoscaler
  install_nvidia_device_plugin
  uncordon_ready_nodes
  install_kube_prometheus
  install_cert_manager
  install_otel_operator_and_contrib_collector
  install_ray_operator
  install_splunk_operator
  install_splunk_ai_operator
  install_ai_platform_stack
  wait_splunk_ai_assistant_installed "Splunk_AI_Assistant_Cloud.tgz" 1200
  push_saia_conf_into_pod
}

# ---------- MAIN ----------
main_install() {
  for t in aws eksctl kubectl helm git jq; do need "$t"; done
  log "Region: ${REGION}, Account: ${ACCOUNT_ID}, Cluster: ${CLUSTER_NAME}"

  preflight_env
  pf_summary

  if cluster_exists; then
    ensure_kubeconfig
    preflight_api_connectivity
    pf_summary
  fi

  if ! cluster_exists; then
    create_cluster_flow
    ensure_kubeconfig
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
  install)      main_install ;;
  delete)       delete_cluster_minimal ;;
  delete-full)  delete_everything ;;
  *) usage; exit 1 ;;
esac
