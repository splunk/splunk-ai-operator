#!/usr/bin/env bash
# refresh_ecr_credentials.sh - Refresh ECR image pull secrets using an ECR token
#
# Usage (run on controller node):
#   ./refresh_ecr_credentials.sh                                              # auto-fetches token via aws cli
#   ./refresh_ecr_credentials.sh "$(aws ecr get-login-password --region us-east-2)"  # pass token
#   ECR_TOKEN=xxxx ./refresh_ecr_credentials.sh                               # pass via env
set -euo pipefail

ECR_ACCOUNT="${ECR_ACCOUNT:-658391232643}"
ECR_REGION="${ECR_REGION:-us-east-2}"
ECR_SERVER="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com"
NAMESPACES="${TARGET_NAMESPACES:-ai-platform splunk-ai-operator-system}"
KUBECTL="${KUBECTL:-k0s kubectl}"

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; }

# --- Get ECR token: argument > env > auto-fetch ---
TOKEN="${1:-${ECR_TOKEN:-}}"

if [[ -z "$TOKEN" ]]; then
  info "No token provided, fetching via: aws ecr get-login-password --region ${ECR_REGION}"
  TOKEN=$(aws ecr get-login-password --region "${ECR_REGION}" 2>/dev/null || true)
fi

if [[ -z "$TOKEN" ]]; then
  error "Failed to get ECR token."
  error "Usage: $0 \"\$(aws ecr get-login-password --region ${ECR_REGION})\""
  exit 1
fi
info "ECR token obtained (${#TOKEN} chars)"

# --- Step 1: Update ecr-registry-secret in all namespaces ---
for ns in ${NAMESPACES}; do
  info "Updating ecr-registry-secret in ${ns}..."
  $KUBECTL -n "${ns}" delete secret ecr-registry-secret 2>/dev/null || true
  $KUBECTL -n "${ns}" create secret docker-registry ecr-registry-secret \
    --docker-server="${ECR_SERVER}" \
    --docker-username=AWS \
    --docker-password="${TOKEN}" && \
    info "  ✓ ecr-registry-secret refreshed in ${ns}" || \
    error "  Failed to create ecr-registry-secret in ${ns}"
done

# --- Step 2: Delete pods stuck in ImagePullBackOff ---
info "Cleaning up ImagePullBackOff pods..."
for ns in ${NAMESPACES}; do
  backoff_pods=$($KUBECTL -n "${ns}" get pods 2>/dev/null \
    | grep -i "ImagePullBackOff\|ErrImagePull" \
    | awk '{print $1}' || true)

  if [[ -n "$backoff_pods" ]]; then
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      $KUBECTL -n "${ns}" delete pod "${pod}" --grace-period=0 --force 2>/dev/null && \
        info "  Deleted: ${pod}" || true
    done <<< "$backoff_pods"
  else
    info "  No stuck pods in ${ns}"
  fi
done

# --- Step 3: Restart deployments that use ECR images ---
info "Restarting ECR-based deployments..."
for ns in ${NAMESPACES}; do
  for dep in $($KUBECTL -n "${ns}" get deployments -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    [[ -z "$dep" ]] && continue
    images=$($KUBECTL -n "${ns}" get deployment "${dep}" -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null || true)
    if echo "$images" | grep -q "${ECR_ACCOUNT}" 2>/dev/null; then
      $KUBECTL -n "${ns}" rollout restart deployment "${dep}" 2>/dev/null && \
        info "  Restarted: ${dep}" || true
    fi
  done
done

echo ""
info "=========================================="
info "ECR credentials refreshed!"
info "  Server: ${ECR_SERVER}"
info "  Namespaces: ${NAMESPACES}"
info ""
info "  Token expires in ~12 hours. Re-run this script to refresh."
info "=========================================="
