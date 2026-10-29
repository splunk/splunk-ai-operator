#!/usr/bin/env bash

# Disposable-cluster acceptance check for deployment-config credential rotation.
# This performs two full installer runs and a real LAS thread/run/state check.
set -Eeuo pipefail
# Trusted scenarios and installer configs may contain credentials. Never honor
# inherited shell tracing for this process.
set +x

usage() {
  cat <<'EOF'
Usage: scripts/las-credential-rotation-acceptance.sh

Required environment:
  LAS_DISPOSABLE_CLUSTER_CONFIRMED=true
  LAS_INITIAL_CONFIG                 Config with initial test credentials.
  LAS_ROTATED_CONFIG                 Config with rotated test credentials.
  LAS_NAMESPACE                      Namespace containing the LAS release.
  LAS_SECRET_NAMES                   Comma-separated names of the managed LAS
                                     auth, PostgreSQL, and Redis Secrets.
  LAS_API_DEPLOYMENT                 LAS API Deployment name.
  LAS_QUEUE_DEPLOYMENT               LAS queue Deployment name.
  LAS_QUEUE_HPA                      Exact queue HPA name.
  LAS_EXPECTED_KUBE_CONTEXT          Exact kubectl context authorized for mutation.
  LAS_EXPECTED_NAMESPACE_UID         Exact UID of LAS_NAMESPACE.
  LAS_BASE_URL                       Explicit localhost URL used by this script's
                                     managed Service port-forward.
  LAS_API_SERVICE                    Exact LAS API Service name. Required so
                                     protocol evidence is bound to this cluster.
  LAS_OPERATOR_NAMESPACE             Namespace of the operator Deployment.
  LAS_OPERATOR_DEPLOYMENT            Exact operator Deployment name.
  LAS_OPERATOR_IMAGE/DIGEST          Expected operator image identity.
  LAS_AGENT_SERVER_IMAGE/DIGEST      Expected API/queue image identity.
  LAS_CHART_VERSION/SHA256           Operator build-time chart provenance.

Pipe the trusted product protocol scenario to stdin. The scenario is held only
  in memory and is not printed. It is executed before and after rotation to prove
  that the actual graph remains usable; the deterministic sample is not substituted.

Optional:
  LAS_INSTALLER                      Defaults to tools/cluster_setup/
                                     k0s_cluster_with_stack.sh.
  KUBECTL                            Defaults to "kubectl".
  ROLLOUT_TIMEOUT                    Defaults to 300s.
  LAS_API_SERVICE_PORT               Remote Service port (default: 2024).

This changes cluster resources by running the installer twice. Use only with
disposable test credentials and a disposable cluster. Output contains names,
resource versions, and smoke metadata; it does not print credential values.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

required=(
  LAS_DISPOSABLE_CLUSTER_CONFIRMED LAS_INITIAL_CONFIG LAS_ROTATED_CONFIG
  LAS_NAMESPACE LAS_SECRET_NAMES LAS_API_DEPLOYMENT LAS_QUEUE_DEPLOYMENT
  LAS_QUEUE_HPA LAS_EXPECTED_KUBE_CONTEXT LAS_EXPECTED_NAMESPACE_UID LAS_BASE_URL
  LAS_API_SERVICE
  LAS_OPERATOR_NAMESPACE LAS_OPERATOR_DEPLOYMENT LAS_OPERATOR_IMAGE
  LAS_OPERATOR_IMAGE_DIGEST LAS_CHART_VERSION LAS_CHART_SHA256
  LAS_AGENT_SERVER_IMAGE LAS_AGENT_SERVER_DIGEST
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'Missing required environment variable: %s\n' "$name" >&2
    usage >&2
    exit 2
  fi
done
if [[ "$LAS_DISPOSABLE_CLUSTER_CONFIRMED" != "true" ]]; then
  printf 'Set LAS_DISPOSABLE_CLUSTER_CONFIRMED=true only for a disposable cluster.\n' >&2
  exit 2
fi
if [[ ! "$LAS_OPERATOR_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || [[ ! "$LAS_AGENT_SERVER_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || [[ ! "$LAS_CHART_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  printf 'Image and chart identities must use lowercase sha256 values.\n' >&2
  exit 2
fi
if [[ ! "${LAS_REQUEST_TIMEOUT:-180}" =~ ^[0-9]+$ ]] \
  || [[ ! "${LAS_RUN_TIMEOUT:-600}" =~ ^[0-9]+$ ]] \
  || (( ${LAS_REQUEST_TIMEOUT:-180} < 1 || ${LAS_RUN_TIMEOUT:-600} < ${LAS_REQUEST_TIMEOUT:-180} )); then
  printf 'LAS request/run timeouts must be positive integers with run >= request.\n' >&2
  exit 2
fi
if [[ ! "${LAS_API_SERVICE_PORT:-2024}" =~ ^[0-9]+$ ]] \
  || (( ${LAS_API_SERVICE_PORT:-2024} < 1 || ${LAS_API_SERVICE_PORT:-2024} > 65535 )); then
  printf 'LAS_API_SERVICE_PORT must be an integer between 1 and 65535.\n' >&2
  exit 2
fi
if [[ ! -r "$LAS_INITIAL_CONFIG" || ! -r "$LAS_ROTATED_CONFIG" ]]; then
  printf 'Both LAS config files must be readable.\n' >&2
  exit 2
fi

for resource_name in \
  "$LAS_NAMESPACE" "$LAS_API_DEPLOYMENT" "$LAS_QUEUE_DEPLOYMENT" "$LAS_QUEUE_HPA" \
  "$LAS_OPERATOR_NAMESPACE" "$LAS_OPERATOR_DEPLOYMENT" ${LAS_API_SERVICE:+"$LAS_API_SERVICE"}; do
  if [[ ! "$resource_name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
    printf 'Namespace and Kubernetes resource names must be simple DNS names.\n' >&2
    exit 2
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${LAS_INSTALLER:-${REPO_ROOT}/tools/cluster_setup/k0s_cluster_with_stack.sh}"
KUBECTL="${KUBECTL:-kubectl}"
IFS=',' read -r -a SECRET_NAMES <<< "$LAS_SECRET_NAMES"
if (( ${#SECRET_NAMES[@]} != 3 )); then
  printf 'LAS_SECRET_NAMES must list exactly the auth, PostgreSQL, and Redis Secret names.\n' >&2
  exit 2
fi
seen_secret_names=','
for secret in "${SECRET_NAMES[@]}"; do
  if [[ ! "$secret" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
    printf 'Managed Secret names must be exact Kubernetes DNS names.\n' >&2
    exit 2
  fi
  if [[ "$seen_secret_names" == *",${secret},"* ]]; then
    printf 'LAS_SECRET_NAMES must contain three distinct managed Secret names.\n' >&2
    exit 2
  fi
  seen_secret_names+="${secret},"
done

command -v "$KUBECTL" >/dev/null 2>&1 || { printf 'kubectl not found: %s\n' "$KUBECTL" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'python3 is required.\n' >&2; exit 2; }
[[ -x "$INSTALLER" ]] || { printf 'Installer is not executable: %s\n' "$INSTALLER" >&2; exit 2; }
[[ -r "${SCRIPT_DIR}/las-runtime-acceptance.py" ]] || { printf 'LAS runtime acceptance helper is missing.\n' >&2; exit 2; }

scenario="$(cat)"
if [[ -z "$scenario" ]] || ! printf '%s' "$scenario" | python3 -c '
import json, sys
value = json.load(sys.stdin)
raise SystemExit(0 if isinstance(value, dict) and value.get("cases") else 1)
'; then
  printf 'A valid trusted product protocol scenario is required on stdin.\n' >&2
  exit 2
fi

qualification_scenario="$(printf '%s' "$scenario" | python3 -c '
import json, sys
value = json.load(sys.stdin)
value["cleanup_threads"] = True
for case in value.get("cases", []):
    if isinstance(case, dict):
        case["cleanup"] = True
print(json.dumps(value, separators=(",", ":")))
')"
unset scenario

PORT_FORWARD_PID=""
cleanup() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
  unset qualification_scenario
}
trap cleanup EXIT

actual_context="$($KUBECTL config current-context)"
if [[ "$actual_context" != "$LAS_EXPECTED_KUBE_CONTEXT" ]]; then
  printf 'kubectl context does not match LAS_EXPECTED_KUBE_CONTEXT.\n' >&2
  exit 2
fi
actual_namespace_uid="$($KUBECTL get namespace "$LAS_NAMESPACE" -o 'jsonpath={.metadata.uid}')"
if [[ -z "$actual_namespace_uid" || "$actual_namespace_uid" != "$LAS_EXPECTED_NAMESPACE_UID" ]]; then
  printf 'Namespace UID does not match LAS_EXPECTED_NAMESPACE_UID.\n' >&2
  exit 2
fi

wait_las_health() {
  local attempt
  for attempt in $(seq 1 60); do
    if [[ -z "$PORT_FORWARD_PID" ]] || ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      printf 'Managed LAS Service port-forward exited before becoming healthy.\n' >&2
      return 1
    fi
    if LAS_BASE_URL="$LAS_BASE_URL" python3 -c '
import json, os, urllib.request
url = os.environ["LAS_BASE_URL"].rstrip("/") + "/ok"
headers = {}
if os.environ.get("LAS_API_KEY"):
    headers["X-Api-Key"] = os.environ["LAS_API_KEY"]
with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=2) as response:
    value = json.load(response)
    raise SystemExit(0 if response.status == 200 and value.get("ok") is True else 1)
' >/dev/null 2>&1; then
      if kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
        return 0
      fi
      printf 'Managed LAS Service port-forward exited during its health check.\n' >&2
      return 1
    fi
    sleep 1
  done
  printf 'Managed LAS Service port-forward did not become healthy.\n' >&2
  return 1
}

refresh_las_access() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
  fi
  local port_data local_host local_port
  port_data="$(LAS_BASE_URL="$LAS_BASE_URL" python3 -c '
import os, urllib.parse
parsed = urllib.parse.urlsplit(os.environ["LAS_BASE_URL"])
if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost") or not parsed.port:
    raise SystemExit(1)
print(parsed.hostname, parsed.port)
')" || {
    printf 'LAS_BASE_URL must be an explicit HTTP localhost port for the managed Service port-forward.\n' >&2
    return 1
  }
  read -r local_host local_port <<<"$port_data"
  "$KUBECTL" -n "$LAS_NAMESPACE" port-forward \
    --address "$local_host" "service/${LAS_API_SERVICE}" \
    "${local_port}:${LAS_API_SERVICE_PORT:-2024}" \
    >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  wait_las_health
}

resource_version() {
  "$KUBECTL" -n "$LAS_NAMESPACE" get secret "$1" -o 'jsonpath={.metadata.resourceVersion}'
}

secret_data_hash() {
  "$KUBECTL" -n "$LAS_NAMESPACE" get secret "$1" -o json | python3 -c '
import hashlib, json, sys
value = json.load(sys.stdin).get("data", {})
if not isinstance(value, dict) or not value:
    raise SystemExit(1)
encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(encoded).hexdigest())
'
}

hpa_spec_hash() {
  "$KUBECTL" -n "$LAS_NAMESPACE" get hpa "$LAS_QUEUE_HPA" -o json | \
    LAS_QUEUE_DEPLOYMENT="$LAS_QUEUE_DEPLOYMENT" python3 -c '
import hashlib, json, os, sys
value = json.load(sys.stdin)
target = value.get("spec", {}).get("scaleTargetRef", {})
if target.get("kind") != "Deployment" or target.get("name") != os.environ["LAS_QUEUE_DEPLOYMENT"]:
    raise SystemExit(1)
spec = json.dumps(value.get("spec", {}), sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(spec).hexdigest())
'
}

deployment_revision() {
  "$KUBECTL" -n "$LAS_NAMESPACE" get deployment "$1" -o json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("metadata",{}).get("annotations",{}).get("deployment.kubernetes.io/revision", ""))'
}

verify_deployment_identity() {
  local namespace="$1" deployment="$2" expected_image="$3" expected_digest="$4" role="$5"
  local selector
  selector="$("$KUBECTL" -n "$namespace" get deployment "$deployment" -o json | \
    EXPECTED_IMAGE="$expected_image" python3 -c '
import json, os, sys
value = json.load(sys.stdin)
containers = value.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
if os.environ["EXPECTED_IMAGE"] not in [item.get("image") for item in containers]:
    raise SystemExit(1)
labels = value.get("spec", {}).get("selector", {}).get("matchLabels", {})
if not labels:
    raise SystemExit(1)
print(",".join(f"{key}={value}" for key, value in sorted(labels.items())))
')" || return 1
  "$KUBECTL" -n "$namespace" get pods -l "$selector" -o json | \
    EXPECTED_DIGEST="$expected_digest" python3 -c '
import json, os, sys
items = json.load(sys.stdin).get("items", [])
digest = os.environ["EXPECTED_DIGEST"]
if not items or any(
    not any(digest in status.get("imageID", "") for status in item.get("status", {}).get("containerStatuses", []))
    for item in items
):
    raise SystemExit(1)
'
  printf 'configured_and_resolved_image_%s=PASS\n' "$role"
}

install_config() {
  local config="$1"
  if ! AUTO_APPROVE=true CONFIG_FILE="$config" "$INSTALLER" install --silent >/dev/null 2>&1; then
    printf 'Installer failed for a LAS configuration (details withheld to avoid credential leakage).\n' >&2
    return 1
  fi
}

wait_rollout() {
  local deployment="$1"
  "$KUBECTL" -n "$LAS_NAMESPACE" rollout status "deployment/${deployment}" \
    --timeout="${ROLLOUT_TIMEOUT:-300s}" >/dev/null
  printf 'rollout=%s:PASS\n' "$deployment"
}

printf 'phase=install_initial\n'
install_config "$LAS_INITIAL_CONFIG"
refresh_las_access
declare -a initial_versions=()
declare -a initial_hashes=()
for secret in "${SECRET_NAMES[@]}"; do
  version="$(resource_version "$secret")" || { printf 'Could not read managed Secret metadata.\n' >&2; exit 1; }
  [[ -n "$version" ]] || { printf 'Managed Secret has no resource version.\n' >&2; exit 1; }
  initial_versions+=("$version")
  data_hash="$(secret_data_hash "$secret")" || { printf 'Could not hash managed Secret data.\n' >&2; exit 1; }
  initial_hashes+=("$data_hash")
done
initial_api_revision="$(deployment_revision "$LAS_API_DEPLOYMENT")"
initial_queue_revision="$(deployment_revision "$LAS_QUEUE_DEPLOYMENT")"
if [[ -z "$initial_api_revision" || -z "$initial_queue_revision" ]]; then
  printf 'Could not read the initial LAS Deployment revisions.\n' >&2
  exit 1
fi
initial_hpa_hash="$(hpa_spec_hash)" || {
  printf 'Queue HPA does not target the expected Deployment.\n' >&2
  exit 1
}
printf 'phase=product_before_rotation\n'
initial_qualification="$(printf '%s' "$qualification_scenario" | python3 "${SCRIPT_DIR}/las-runtime-acceptance.py" \
  protocol --request-timeout "${LAS_REQUEST_TIMEOUT:-180}" --run-timeout "${LAS_RUN_TIMEOUT:-600}")" || {
  printf 'Actual product qualification failed before Secret rotation.\n' >&2
  exit 1
}
printf 'product_protocol_before_rotation=%s\n' "$initial_qualification"

printf 'phase=install_rotated\n'
install_config "$LAS_ROTATED_CONFIG"
changed=0
for index in "${!SECRET_NAMES[@]}"; do
  version="$(resource_version "${SECRET_NAMES[$index]}")" || { printf 'Could not read managed Secret metadata after rotation.\n' >&2; exit 1; }
  if [[ "$version" == "${initial_versions[$index]}" ]]; then
    printf 'secret_rotation=%s:FAIL (resource version unchanged)\n' "${SECRET_NAMES[$index]}" >&2
    exit 1
  fi
  data_hash="$(secret_data_hash "${SECRET_NAMES[$index]}")" || { printf 'Could not hash managed Secret data after rotation.\n' >&2; exit 1; }
  if [[ "$data_hash" == "${initial_hashes[$index]}" ]]; then
    printf 'secret_rotation=%s:FAIL (Secret data hash unchanged)\n' "${SECRET_NAMES[$index]}" >&2
    exit 1
  fi
  changed=$((changed + 1))
  printf 'secret_rotation=%s:PASS\n' "${SECRET_NAMES[$index]}"
done

wait_rollout "$LAS_API_DEPLOYMENT"
wait_rollout "$LAS_QUEUE_DEPLOYMENT"
post_context="$($KUBECTL config current-context)"
post_namespace_uid="$($KUBECTL get namespace "$LAS_NAMESPACE" -o 'jsonpath={.metadata.uid}')"
if [[ "$post_context" != "$LAS_EXPECTED_KUBE_CONTEXT" \
  || "$post_namespace_uid" != "$LAS_EXPECTED_NAMESPACE_UID" ]]; then
  printf 'Kubernetes context or namespace identity changed during rotation.\n' >&2
  exit 1
fi
refresh_las_access
api_revision="$(deployment_revision "$LAS_API_DEPLOYMENT")"
queue_revision="$(deployment_revision "$LAS_QUEUE_DEPLOYMENT")"
if [[ "$api_revision" == "$initial_api_revision" || "$queue_revision" == "$initial_queue_revision" ]]; then
  printf 'LAS API and queue must each roll to a new Deployment revision after credential rotation.\n' >&2
  exit 1
fi
printf 'pod_template_rotation=api:%s->%s:PASS\n' "$initial_api_revision" "$api_revision"
printf 'pod_template_rotation=queue:%s->%s:PASS\n' "$initial_queue_revision" "$queue_revision"
rotated_hpa_hash="$(hpa_spec_hash)" || {
  printf 'Queue HPA does not target the expected Deployment after rotation.\n' >&2
  exit 1
}
if [[ "$rotated_hpa_hash" != "$initial_hpa_hash" ]]; then
  printf 'Queue HPA spec changed during credential rotation.\n' >&2
  exit 1
fi
printf 'queue_hpa_ownership_preserved=PASS\n'
verify_deployment_identity "$LAS_OPERATOR_NAMESPACE" "$LAS_OPERATOR_DEPLOYMENT" \
  "$LAS_OPERATOR_IMAGE" "$LAS_OPERATOR_IMAGE_DIGEST" operator || {
  printf 'Operator image identity did not match the live Deployment.\n' >&2
  exit 1
}
verify_deployment_identity "$LAS_NAMESPACE" "$LAS_API_DEPLOYMENT" \
  "$LAS_AGENT_SERVER_IMAGE" "$LAS_AGENT_SERVER_DIGEST" api || {
  printf 'API image identity did not match the live Deployment.\n' >&2
  exit 1
}
verify_deployment_identity "$LAS_NAMESPACE" "$LAS_QUEUE_DEPLOYMENT" \
  "$LAS_AGENT_SERVER_IMAGE" "$LAS_AGENT_SERVER_DIGEST" queue || {
  printf 'Queue image identity did not match the live Deployment.\n' >&2
  exit 1
}
printf '%s\n' \
  "chart_version=${LAS_CHART_VERSION}" \
  "chart_sha256=${LAS_CHART_SHA256}" \
  'chart_identity_source=operator_build_provenance'
printf 'phase=product_run_and_persisted_state\n'
qualification_result="$(printf '%s' "$qualification_scenario" | python3 "${SCRIPT_DIR}/las-runtime-acceptance.py" \
  protocol --request-timeout "${LAS_REQUEST_TIMEOUT:-180}" --run-timeout "${LAS_RUN_TIMEOUT:-600}")" || {
  printf 'Actual product qualification failed after Secret rotation.\n' >&2
  exit 1
}
printf 'product_protocol=%s\n' "$qualification_result"
printf 'credential_rotation_acceptance=PASS\n'
