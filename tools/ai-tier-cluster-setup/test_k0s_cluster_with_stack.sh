#!/usr/bin/env bash
# test_k0s_cluster_with_stack.sh
# Unit tests for pure-logic functions in k0s_cluster_with_stack.sh.
# No cluster, SSH, kubectl, or network access required.
#
# Usage:
#   ./test_k0s_cluster_with_stack.sh          # run all tests
#   ./test_k0s_cluster_with_stack.sh -v        # verbose (show each assertion)
#   ./test_k0s_cluster_with_stack.sh pod       # run only tests matching "pod"

# Intentionally no set -e: grep -c returns exit code 1 on zero matches, which
# would cause the harness to exit early on legitimate "0 occurrences" assertions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/k0s_cluster_with_stack.sh"
AIRGAP_SCRIPT="${SCRIPT_DIR}/airgap_install.sh"
YQ_BIN="$(command -v yq || true)"

VERBOSE=0
FILTER="${1:-}"
if [[ "${FILTER}" == "-v" ]]; then VERBOSE=1; FILTER="${2:-}"; fi

# ── Test framework ─────────────────────────────────────────────────────────────

PASS=0; FAIL=0; SKIP=0
_current_suite=""

suite() { _current_suite="$1"; }

# Define shared assertions before the profile cases that invoke them.
assert_contains() { assert_eq "$1" "yes" "$([[ "$3" == *"$2"* ]] && echo yes || echo no)"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ -n "${FILTER}" && "${_current_suite} ${desc}" != *"${FILTER}"* ]]; then
    SKIP=$(( SKIP + 1 )); return
  fi
  if [[ "${expected}" == "${actual}" ]]; then
    PASS=$(( PASS + 1 ))
    [[ "${VERBOSE}" == "1" ]] && echo "  ✅ ${desc}"
  else
    FAIL=$(( FAIL + 1 ))
    echo "  ❌ ${desc}"
    echo "       expected: $(printf '%q' "${expected}")"
    echo "       actual  : $(printf '%q' "${actual}")"
  fi
}

assert_rc() {
  local desc="$1" expected_rc="$2"
  shift 2
  if [[ -n "${FILTER}" && "${_current_suite} ${desc}" != *"${FILTER}"* ]]; then
    SKIP=$(( SKIP + 1 )); return
  fi
  local actual_rc=0
  "$@" >/dev/null 2>&1 || actual_rc=$?
  if [[ "${expected_rc}" == "${actual_rc}" ]]; then
    PASS=$(( PASS + 1 ))
    [[ "${VERBOSE}" == "1" ]] && echo "  ✅ ${desc}"
  else
    FAIL=$(( FAIL + 1 ))
    echo "  ❌ ${desc} (expected rc=${expected_rc}, got rc=${actual_rc})"
  fi
}

# ── Function loader ────────────────────────────────────────────────────────────
# Extract a named bash function (and its closing brace) from the script by
# name — robust to line-number shifts caused by unrelated edits.

_extract_fn() {
  local name="$1"
  local start end
  start=$(grep -n "^${name}()" "${SCRIPT}" | cut -d: -f1)
  if [[ -z "${start}" ]]; then
    echo "ERROR: function '${name}' not found in ${SCRIPT}" >&2
    return 1
  fi
  end=$(awk -v s="${start}" 'NR>s && /^}$/{print NR; exit}' "${SCRIPT}")
  sed -n "${start},${end}p" "${SCRIPT}"
}

_extract_airgap_fn() {
  local name="$1"
  local start end
  start=$(grep -n "^${name}()" "${AIRGAP_SCRIPT}" | cut -d: -f1)
  if [[ -z "${start}" ]]; then
    echo "ERROR: function '${name}' not found in ${AIRGAP_SCRIPT}" >&2
    return 1
  fi
  end=$(awk -v s="${start}" 'NR>s && /^}$/{print NR; exit}' "${AIRGAP_SCRIPT}")
  sed -n "${start},${end}p" "${AIRGAP_SCRIPT}"
}

_load_functions() {
  log()  { :; }
  warn() { :; }
  err()  { echo "ERROR: $*" >&2; exit 1; }
  pf_ok()   { :; }
  pf_warn() { :; }
  pf_fail() { :; }

  # Extract _POD_FS assignment (single line, not a function)
  eval "$(grep '^_POD_FS=' "${SCRIPT}")"

  eval "$(_extract_fn model_artifacts_config_name)"
  eval "$(_extract_fn render_agentruntime_checkpoint_secret_manifest)"
  eval "$(_extract_fn validate_agentruntime_checkpoint_config)"
  eval "$(_extract_fn agentruntime_network_policy_problems)"
  eval "$(_extract_fn validate_agentruntime_network_policy_config)"
  eval "$(_extract_fn preflight_agentruntime_policy_upgrade)"
  eval "$(_extract_fn build_image_url)"
  eval "$(_extract_fn ai_platform_profile_resolved)"
  eval "$(_extract_fn ai_platform_profile_explicit)"
  eval "$(_extract_fn ai_platform_profile_set)"
  eval "$(_extract_fn _profile_value_unsafe)"
  eval "$(_extract_fn _profile_q)"
  eval "$(_extract_fn _profile_ref_missing)"
  eval "$(_extract_fn _profile_ref_check)"
  eval "$(_extract_fn _profile_is_dns_subdomain)"
  eval "$(_extract_fn _profile_feature_subdomain_check)"
  eval "$(_extract_fn _profile_feature_field_check)"
  eval "$(_extract_fn ai_platform_profile_feature_problems)"
  eval "$(_extract_fn ai_platform_profile_cr_input_problems)"
  eval "$(_extract_fn render_slim_route_config)"
  eval "$(_extract_fn ai_platform_profile_problems)"
  eval "$(_extract_fn validate_ai_platform_profile_config)"
  eval "$(_extract_fn config_bool)"
  eval "$(_extract_fn validate_image_config)"
  eval "$(_extract_fn configure_images)"
  eval "$(_extract_fn validate_scale_factor_config)"
  eval "$(_extract_fn object_store_auth_looks_like_placeholder)"
  eval "$(_extract_fn validate_single_controller_topology)"
  eval "$(_extract_fn _pod_is_healthy)"
  eval "$(_extract_fn _classify_pod_failure)"
  eval "$(_extract_fn _print_pod_section)"
  eval "$(_extract_fn _print_unhealthy_pod_summary)"
}

_load_functions

# ── Tests: Agent Runtime checkpoint Secret ──────────────────────────────────

suite "Agent Runtime checkpoint Secret"
echo "▶ Agent Runtime checkpoint Secret"

_checkpoint_url='postgresql://alice%40example:p%40ss%3Aword@db.example:5440/check%2Fpoints?sslmode=require'
_checkpoint_manifest=$(printf '%s' "${_checkpoint_url}" | render_agentruntime_checkpoint_secret_manifest "mltk-postgres" "ai-platform")
assert_eq "manifest targets the requested Secret" "mltk-postgres" \
  "$(printf '%s' "${_checkpoint_manifest}" | jq -r '.metadata.name')"
assert_eq "encoded username is decoded for the runtime" "alice@example" \
  "$(printf '%s' "${_checkpoint_manifest}" | jq -r '.data.PG_USER | @base64d')"
assert_eq "encoded password is decoded for the runtime" "p@ss:word" \
  "$(printf '%s' "${_checkpoint_manifest}" | jq -r '.data.PG_PASSWORD | @base64d')"
assert_eq "database name and port are passed to the runtime" $'check/points\n5440' \
  "$(printf '%s' "${_checkpoint_manifest}" | jq -r '(.data.PG_DBNAME | @base64d), (.data.PG_PORT | @base64d)')"
assert_eq "URL sslmode is passed to the runtime" "require" \
  "$(printf '%s' "${_checkpoint_manifest}" | jq -r '.data.PG_SSLMODE | @base64d')"
_checkpoint_override_manifest=$(printf '%s' "${_checkpoint_url}" | \
  render_agentruntime_checkpoint_secret_manifest "mltk-postgres" "ai-platform" "disable")
assert_eq "profile SSL mode overrides the URL mode for the dev database" "disable" \
  "$(printf '%s' "${_checkpoint_override_manifest}" | jq -r '.data.PG_SSLMODE | @base64d')"
assert_eq "Agent Runtime dev profile selects the non-SSL database mode" "disable" \
  "$("${YQ_BIN}" eval '.aiPlatform.agentRuntime.checkpointSecrets[0].pgSslMode' "${SCRIPT_DIR}/k0s-cluster-config-agentruntime.yaml")"
_checkpoint_profile_manifest=$(
  eval "$(_extract_fn create_agentruntime_checkpoint_secrets)"
  k0s_agentruntime_feature_enabled() { return 0; }
  need() { :; }
  yq() { "${YQ_BIN}" "$@"; }
  local_secret_capture="$(mktemp)"
  kubectl() {
    # A missing Secret is an empty successful read with --ignore-not-found.
    [[ " $* " == *" get secret "* ]] && return 0
    cat >"${local_secret_capture}"
  }
  CONFIG_FILE="${SCRIPT_DIR}/k0s-cluster-config-agentruntime.yaml"
  AI_NS="ai-platform"
  AGENT_RUNTIME_CHECKPOINT_DB_URL='postgresql://user:password@db.example/checkpoints'
  create_agentruntime_checkpoint_secrets
  cat "${local_secret_capture}"
  rm -f "${local_secret_capture}"
)
assert_eq "installer applies the dev profile SSL mode to its Secret" "disable" \
  "$(printf '%s' "${_checkpoint_profile_manifest}" | jq -r '.data.PG_SSLMODE | @base64d')"
assert_eq "schema setup retains the original URL" "${_checkpoint_url}" \
  "$(printf '%s' "${_checkpoint_manifest}" | jq -r '.data.DATABASE_URL | @base64d')"

_checkpoint_default_manifest=$(printf '%s' 'postgres://user:password@db.example/checkpoints' | \
  render_agentruntime_checkpoint_secret_manifest "mltk-postgres" "ai-platform")
assert_eq "omitted port defaults to 5432" "5432" \
  "$(printf '%s' "${_checkpoint_default_manifest}" | jq -r '.data.PG_PORT | @base64d')"
assert_eq "omitted SSL mode remains absent" "false" \
  "$(printf '%s' "${_checkpoint_default_manifest}" | jq -r '.data | has("PG_SSLMODE")')"
assert_rc "malformed URL is rejected before Secret creation" 1 \
  bash -c "$(declare -f render_agentruntime_checkpoint_secret_manifest); printf '%s' 'postgresql://user@db.example/checkpoints' | render_agentruntime_checkpoint_secret_manifest mltk-postgres ai-platform"
assert_rc "invalid SSL mode is rejected before Secret creation" 1 \
  bash -c "$(declare -f render_agentruntime_checkpoint_secret_manifest); printf '%s' 'postgresql://user:password@db.example/checkpoints' | render_agentruntime_checkpoint_secret_manifest mltk-postgres ai-platform insecure"

# ── Tests: build_image_url ─────────────────────────────────────────────────────

suite "build_image_url"
echo "▶ build_image_url"

assert_eq "prepends registry to bare path" \
  "my.registry.io/splunk/operator:1.0" \
  "$(build_image_url "my.registry.io" "splunk/operator:1.0")"

assert_eq "skips registry when image already has a host" \
  "ghcr.io/splunk/operator:1.0" \
  "$(build_image_url "my.registry.io" "ghcr.io/splunk/operator:1.0")"

assert_eq "skips registry when image has IP host" \
  "10.0.0.1:5000/operator:1.0" \
  "$(build_image_url "my.registry.io" "10.0.0.1:5000/operator:1.0")"

assert_eq "returns bare path when registry is empty" \
  "splunk/operator:1.0" \
  "$(build_image_url "" "splunk/operator:1.0")"

assert_eq "returns bare path when registry is null" \
  "splunk/operator:1.0" \
  "$(build_image_url "null" "splunk/operator:1.0")"

# ── Tests: shipped image defaults ─────────────────────────────────────────────

suite "shipped image defaults"
echo "▶ shipped image defaults"

_expected_k0s_release_tuple=$'docker.io/splunk/splunk-ai-operator:v1.0\ndocker.io/splunk/ai-tier-ray-head:v1.0\ndocker.io/splunk/ai-tier-ray-worker:v1.0\ndocker.io/splunk/ai-tier-slim-service:v1.0\n2.56.0'
_actual_k0s_release_tuple=$("${YQ_BIN}" eval '
  .images.operator.image,
  .images.ray.headImage,
  .images.ray.workerImage,
  .images.slim.apiImage,
  .operators.ray.rayVersion
' "${SCRIPT_DIR}/k0s-cluster-config.yaml")
assert_eq "k0s config uses the requested operator, Ray, Slim, and Ray runtime defaults" \
  "${_expected_k0s_release_tuple}" "${_actual_k0s_release_tuple}"

# ── Tests: single-controller topology guard ──────────────────────────────────

suite "single-controller topology"
echo "▶ single-controller topology"

CONTROLLER_COUNT=1
CONTROLLER_IP_COUNT=1
assert_rc "accepts the supported one-controller configuration" 0 \
  validate_single_controller_topology

CONTROLLER_COUNT=3
CONTROLLER_IP_COUNT=1
assert_rc "rejects a declared multi-controller configuration" 1 \
  validate_single_controller_topology

CONTROLLER_COUNT=1
CONTROLLER_IP_COUNT=3
assert_rc "rejects multiple controller IPs" 1 \
  validate_single_controller_topology

CONTROLLER_COUNT=1
CONTROLLER_IP_COUNT=0
assert_rc "rejects a missing controller IP" 1 \
  validate_single_controller_topology

_expected_eks_platform_images=$'docker.io/splunk/ai-tier-ray-head:preview\ndocker.io/splunk/ai-tier-ray-worker:preview\ndocker.io/splunk/ai-tier-saia-api:preview\ndocker.io/splunk/ai-tier-saia-api-v2:preview\ndocker.io/splunk/ai-tier-saia-data-loader:preview'
_actual_eks_platform_images=$("${YQ_BIN}" eval '
  .images.ray.headImage,
  .images.ray.workerImage,
  .images.saia.apiImage,
  .images.saia.apiV2Image,
  .images.saia.dataLoaderImage
' "${SCRIPT_DIR}/cluster-config.yaml")
assert_eq "EKS config keeps its existing published preview image defaults" \
  "${_expected_eks_platform_images}" "${_actual_eks_platform_images}"

for _profile in \
  model_artifacts_configs_unquantized.yaml \
  model_artifacts_configs_quantized.yaml; do
  _profile_path="${SCRIPT_DIR}/../artifacts_download_upload_scripts/${_profile}"
  assert_eq "${_profile} contains exactly 10 model artifacts" \
    "10" "$("${YQ_BIN}" eval '.artifact-configs | length' "${_profile_path}")"
  assert_eq "${_profile} excludes the disabled BiEncoder model" \
    "0" "$("${YQ_BIN}" eval '[.artifact-configs[] | select(.artifact-id == "bi-encoder" or .hf-url == "https://huggingface.co/BAAI/bge-small-en-v1.5")] | length' "${_profile_path}")"
  assert_eq "${_profile} retains the supported UAE embedding model" \
    "1" "$("${YQ_BIN}" eval '[.artifact-configs[] | select(.artifact-id == "uae-large")] | length' "${_profile_path}")"
done

# ── Tests: validate_scale_factor_config ──────────────────────────────────────

suite "validate_scale_factor_config"
echo "▶ validate_scale_factor_config"

# Stub yq so these tests stay local and exercise the validation branches
# without depending on a particular yq installation.
_scale_factor_present="false"
_scale_factor_value="null"
_scale_factor_tag="!!null"
yq() {
  if [[ "$*" == *"has(\"scaleFactor\")"* ]]; then
    echo "${_scale_factor_present}"
  elif [[ "$*" == *"| tag"* ]]; then
    echo "${_scale_factor_tag}"
  else
    echo "${_scale_factor_value}"
  fi
}
CONFIG_FILE="unused-by-yq-stub"

assert_rc "accepts an omitted value (defaults to 1)" 0 validate_scale_factor_config

_scale_factor_present="true"
_scale_factor_value="1"; _scale_factor_tag="!!int"
assert_rc "accepts integer 1" 0 validate_scale_factor_config

_scale_factor_value="3"; _scale_factor_tag="!!int"
assert_rc "accepts an integer greater than 1" 0 validate_scale_factor_config

_scale_factor_value="0"; _scale_factor_tag="!!int"
assert_rc "rejects zero" 1 validate_scale_factor_config

_scale_factor_value="-1"; _scale_factor_tag="!!int"
assert_rc "rejects negative integers" 1 validate_scale_factor_config

_scale_factor_value="1.5"; _scale_factor_tag="!!float"
assert_rc "rejects decimals" 1 validate_scale_factor_config

_scale_factor_value="2"; _scale_factor_tag="!!str"
assert_rc "rejects quoted integers" 1 validate_scale_factor_config

_scale_factor_value="null"; _scale_factor_tag="!!null"
assert_rc "rejects an explicitly null value" 1 validate_scale_factor_config

# ── Tests: object_store_auth_looks_like_placeholder ───────────────────────────

suite "object_store_auth_looks_like_placeholder"
echo "▶ object_store_auth_looks_like_placeholder"

assert_rc "detects <CHANGE_ME> angle bracket placeholder" 0 \
  bash -c "$(declare -f object_store_auth_looks_like_placeholder); MINIO_ROOT_USER='<user>' MINIO_ROOT_PASSWORD='secret' object_store_auth_looks_like_placeholder"

assert_rc "detects CHANGEME keyword in password" 0 \
  bash -c "$(declare -f object_store_auth_looks_like_placeholder); MINIO_ROOT_USER='admin' MINIO_ROOT_PASSWORD='CHANGEME' object_store_auth_looks_like_placeholder"

assert_rc "detects changeme (lowercase)" 0 \
  bash -c "$(declare -f object_store_auth_looks_like_placeholder); MINIO_ROOT_USER='admin' MINIO_ROOT_PASSWORD='changeme' object_store_auth_looks_like_placeholder"

assert_rc "accepts real credentials (returns 1)" 1 \
  bash -c "$(declare -f object_store_auth_looks_like_placeholder); MINIO_ROOT_USER='admin' MINIO_ROOT_PASSWORD='s3cr3t!' object_store_auth_looks_like_placeholder"

# ── Tests: model artifact config selection ───────────────────────────────────

suite "model artifact config selection"
echo "▶ model_artifacts_config_name"

assert_eq "L40S uses the unquantized artifact manifest" \
  "model_artifacts_configs_unquantized.yaml" "$(model_artifacts_config_name l40s)"

assert_eq "H100 uses the quantized artifact manifest" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name h100)"

assert_eq "RTX Pro 6000 uses the quantized artifact manifest" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name rtx_pro_6000_blackwell)"

assert_eq "defaultAcceleratorType values are normalized" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name RTX_PRO_6000_BLACKWELL)"

assert_eq "pre-staging check uses the shared artifact-manifest selector" \
  "1" "$(grep -c 'config_file=.*model_artifacts_config_name.*accel' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "post-upload verification uses the shared artifact-manifest selector" \
  "1" "$(grep -c '_config_for_verify=.*model_artifacts_config_name.*_accel' "${SCRIPT}" | tr -d '[:space:]')"

# ── Tests: _pod_is_healthy ─────────────────────────────────────────────────────

suite "_pod_is_healthy"
echo "▶ _pod_is_healthy"

# args: phase ready waiting terminated reason
assert_rc "Running 2/2 is healthy"               0 _pod_is_healthy Running   "2/2" ""                 ""          ""
assert_rc "Running 1/2 is unhealthy"             1 _pod_is_healthy Running   "1/2" ""                 ""          ""
assert_rc "Succeeded is healthy"                 0 _pod_is_healthy Succeeded ""    ""                 ""          ""
assert_rc "Pending is unhealthy"                 1 _pod_is_healthy Pending   "0/1" ""                 ""          ""
assert_rc "Failed is unhealthy"                  1 _pod_is_healthy Failed    "0/1" ""                 ""          ""
assert_rc "Unknown is unhealthy"                 1 _pod_is_healthy Unknown   "0/1" ""                 ""          ""
assert_rc "CrashLoopBackOff is unhealthy"        1 _pod_is_healthy Running   "0/1" "CrashLoopBackOff" ""          ""
assert_rc "ImagePullBackOff is unhealthy"        1 _pod_is_healthy Running   "0/1" "ImagePullBackOff" ""          ""
assert_rc "ErrImagePull is unhealthy"            1 _pod_is_healthy Running   "0/1" "ErrImagePull"     ""          ""
assert_rc "OOMKilled terminated is unhealthy"    1 _pod_is_healthy Running   "1/1" ""                 "OOMKilled" ""
assert_rc "Error terminated is unhealthy"        1 _pod_is_healthy Running   "1/1" ""                 "Error"     ""
assert_rc "NodeLost reason is unhealthy"         1 _pod_is_healthy Running   "1/1" ""                 ""          "NodeLost"
assert_rc "Evicted reason is unhealthy"          1 _pod_is_healthy Running   "1/1" ""                 ""          "Evicted"
assert_rc "PodInitializing waiting is unhealthy" 1 _pod_is_healthy Pending   "0/1" "PodInitializing"  ""          ""

# ── Tests: _classify_pod_failure ──────────────────────────────────────────────

suite "_classify_pod_failure"
echo "▶ _classify_pod_failure"

# args: phase reason waiting terminated message
assert_eq "ImagePullBackOff → image-pull" \
  "image-pull"   "$(_classify_pod_failure Pending ""        "ImagePullBackOff" ""          "")"
assert_eq "ErrImagePull → image-pull" \
  "image-pull"   "$(_classify_pod_failure Running ""        "ErrImagePull"     ""          "")"
assert_eq "CrashLoopBackOff → crashloop" \
  "crashloop"    "$(_classify_pod_failure Running ""        "CrashLoopBackOff" ""          "")"
assert_eq "OOMKilled → oom" \
  "oom"          "$(_classify_pod_failure Running ""        ""                 "OOMKilled" "")"
assert_eq "Evicted → evicted" \
  "evicted"      "$(_classify_pod_failure Running "Evicted" ""                ""           "")"
assert_eq "Pending with no signal → pending-long" \
  "pending-long" "$(_classify_pod_failure Pending ""        ""                 ""          "")"
assert_eq "Failed with no signal → failed" \
  "failed"       "$(_classify_pod_failure Failed  ""        ""                 ""          "")"

# ── Tests: _print_unhealthy_pod_summary ───────────────────────────────────────

suite "_print_unhealthy_pod_summary pod"
echo "▶ _print_unhealthy_pod_summary"

_captured=""
warn() { _captured+="WARN: $*"$'\n'; }
log()  { _captured+="LOG: $*"$'\n'; }

mk_pod_line() {
  local ns=$1 name=$2 phase=$3 ready=$4 waiting=$5
  printf "%s" "${ns}${_POD_FS}${name}${_POD_FS}${phase}${_POD_FS}${ready}${_POD_FS}${_POD_FS}${_POD_FS}RS${_POD_FS}owner${_POD_FS}${waiting}${_POD_FS}${_POD_FS}0${_POD_FS}2026-06-16"
}

# Scenario 1: mixed ImagePullBackOff (root cause) + PodInitializing (downstream)
_captured=""
declare -a POD_LINES=(
  "$(mk_pod_line ai-platform head-pod      Pending "0/2" "ImagePullBackOff")"
  "$(mk_pod_line ai-platform gpu-worker-1  Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-worker-2  Pending "0/1" "PodInitializing")"
)
_print_unhealthy_pod_summary
assert_eq "scenario 1: shows root-cause section header" \
  "1" "$(echo "${_captured}" | grep -c "^WARN: 1 root-cause pod" || true)"
assert_eq "scenario 1: shows downstream section" \
  "1" "$(echo "${_captured}" | grep -c "still initializing" || true)"
assert_eq "scenario 1: head pod appears in root-cause output" \
  "1" "$(echo "${_captured}" | grep -c "head-pod" || true)"
assert_eq "scenario 1: tip mentions fixing root cause" \
  "1" "$(echo "${_captured}" | grep -c "fix the root-cause" || true)"
assert_eq "scenario 1: downstream count is 2" \
  "1" "$(echo "${_captured}" | grep -c "^WARN: 2 pod(s) are still initializing" || true)"

# Scenario 2: only PodInitializing — no root cause
_captured=""
POD_LINES=(
  "$(mk_pod_line ai-platform gpu-worker-1 Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-worker-2 Pending "0/1" "PodInitializing")"
)
_print_unhealthy_pod_summary
assert_eq "scenario 2: no root-cause section shown" \
  "0" "$(echo "${_captured}" | grep -c "root-cause pod" || true)"
assert_eq "scenario 2: shows 2 still initializing" \
  "1" "$(echo "${_captured}" | grep -c "^WARN: 2 pod(s) are still initializing" || true)"
assert_eq "scenario 2: tip says re-run verifier" \
  "1" "$(echo "${_captured}" | grep -c "re-run the verifier" || true)"

# Scenario 3: only root causes, no PodInitializing — multi-namespace
_captured=""
POD_LINES=(
  "$(mk_pod_line ai-platform  head-pod     Pending "0/2" "ImagePullBackOff")"
  "$(mk_pod_line kube-system  calico-node  Pending "0/1" "CrashLoopBackOff")"
)
_print_unhealthy_pod_summary
assert_eq "scenario 3: 2 root-cause pods" \
  "1" "$(echo "${_captured}" | grep -c "^WARN: 2 root-cause pod" || true)"
assert_eq "scenario 3: no downstream section" \
  "0" "$(echo "${_captured}" | grep -c "still initializing" || true)"
assert_eq "scenario 3: ai-platform namespace shown" \
  "1" "$(echo "${_captured}" | grep -c "ai-platform" || true)"
assert_eq "scenario 3: kube-system namespace shown" \
  "1" "$(echo "${_captured}" | grep -c "kube-system" || true)"

# Scenario 4: max_per_ns truncation (>5 pods in one namespace)
_captured=""
POD_LINES=(
  "$(mk_pod_line ai-platform head-pod  Pending "0/2" "ImagePullBackOff")"
  "$(mk_pod_line ai-platform gpu-w-1   Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-2   Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-3   Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-4   Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-5   Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-6   Pending "0/1" "PodInitializing")"
)
_print_unhealthy_pod_summary
assert_eq "scenario 4: truncation ellipsis shown for downstream" \
  "1" "$(echo "${_captured}" | grep -c "… and" || true)"

# ── Tests: configure_images upgrade idempotency ───────────────────────────────
# Regression test for the bug fixed in b07745c: image: substitutions must be
# anchored on a unique preceding field, not on the image string's own content,
# so a second run with a new custom (non-"splunk*ai*operator") image actually
# overwrites the first run's image instead of leaving it stale.

suite "configure_images upgrade idempotency"
echo "▶ configure_images upgrade idempotency"

_CI_TMPDIR="$(mktemp -d)"
trap '[[ -n "${_CI_TMPDIR:-}" ]] && rm -rf "${_CI_TMPDIR}"' EXIT

# Minimal fixtures mirroring the real manifests' anchor structure: the
# RELATED_IMAGE_* env/value pairs, the RAY_VERSION entry immediately
# preceding the AI operator's image: line, and (for the Splunk Operator
# manifest) the POD_NAME entry immediately preceding its image: line.
cat > "${_CI_TMPDIR}/artifacts.yaml" <<'EOF'
      containers:
      - name: manager
        env:
        - name: RELATED_IMAGE_RAY_HEAD
          value: placeholder
        - name: RELATED_IMAGE_RAY_WORKER
          value: placeholder
        - name: RELATED_IMAGE_WEAVIATE
          value: placeholder
        - name: RELATED_IMAGE_SAIA_API
          value: placeholder
        - name: RELATED_IMAGE_SAIA_API_V2
          value: placeholder
        - name: RELATED_IMAGE_POST_INSTALL_HOOK
          value: placeholder
        - name: RELATED_IMAGE_FLUENT_BIT
          value: placeholder
        - name: RELATED_IMAGE_OTEL_COLLECTOR
          value: placeholder
        - name: RELATED_IMAGE_NGINX
          value: placeholder
        - name: MODEL_VERSION
          value: placeholder
        - name: RAY_VERSION
          value: placeholder
        image: ghcr.io/splunk/splunk-ai-operator:v0.1.0
EOF

cat > "${_CI_TMPDIR}/splunk-operator-cluster.yaml" <<'EOF'
      containers:
      - name: manager
        env:
        - name: RELATED_IMAGE_SPLUNK_ENTERPRISE
          value: placeholder
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        image: docker.io/splunk/splunk-operator:3.0.0
EOF

_run_configure_images() {
  local op_image="$1" splunk_op_image="$2"
  OPERATOR_IMAGE="${op_image}" \
  RAY_HEAD_IMAGE=ray-head:v1 RAY_WORKER_IMAGE=ray-worker:v1 \
  WEAVIATE_IMAGE=weaviate:v1 SAIA_API_IMAGE=saia-api:v1 \
  SAIA_API_V2_IMAGE=saia-api-v2:v1 SAIA_DATALOADER_IMAGE=saia-loader:v1 \
  FLUENT_BIT_IMAGE=fluent-bit:v1 OTEL_COLLECTOR_IMAGE=otel:v1 NGINX_IMAGE=nginx:v1 \
  MODEL_VERSION=v1 RAY_RUNTIME_VERSION=2.44.0 IMAGE_REGISTRY="" \
  SPLUNK_MODE=internal SPLUNK_IMAGE=splunk:v1 SPLUNK_OPERATOR_IMAGE="${splunk_op_image}" \
  SPLUNK_AI_FILE="${_CI_TMPDIR}/artifacts.yaml" \
  SPLUNK_OPERATOR_FILE="${_CI_TMPDIR}/splunk-operator-cluster.yaml" \
  bash -c "
    $(declare -f build_image_url)
    $(declare -f configure_images)
    log() { :; }
    err() { echo \"ERROR: \$*\" >&2; exit 1; }
    configure_images
    cp \"\$SPLUNK_AI_FILE\" \"${_CI_TMPDIR}/rendered-artifacts.yaml\"
    cp \"\$SPLUNK_OPERATOR_FILE\" \"${_CI_TMPDIR}/rendered-splunk-operator.yaml\"
  "
}

# A custom private-registry image containing none of "splunk"/"ai"/"operator"
# as substrings — the exact case that broke the old content-based sed match.
_run_configure_images "registry.example.com/team/platform:v1" "registry.example.com/team/splunk-op:v1" >/dev/null 2>&1

assert_eq "first run: AI operator image set to v1" \
  "1" "$(grep -c 'image: registry.example.com/team/platform:v1$' "${_CI_TMPDIR}/rendered-artifacts.yaml")"
assert_eq "first run: Splunk Operator image set to v1" \
  "1" "$(grep -c 'image: registry.example.com/team/splunk-op:v1$' "${_CI_TMPDIR}/rendered-splunk-operator.yaml")"

# Second run ("upgrade"): same private-registry path, new tag. This is the
# regression case — a content-based match never re-matches here because the
# image string still contains no "splunk"/"ai"/"operator" substring.
_run_configure_images "registry.example.com/team/platform:v2" "registry.example.com/team/splunk-op:v2" >/dev/null 2>&1

assert_eq "upgrade run: AI operator image advances to v2 (not stale v1)" \
  "1" "$(grep -c 'image: registry.example.com/team/platform:v2$' "${_CI_TMPDIR}/rendered-artifacts.yaml")"
assert_eq "upgrade run: no stale v1 AI operator image remains" \
  "0" "$(grep -c 'image: registry.example.com/team/platform:v1$' "${_CI_TMPDIR}/rendered-artifacts.yaml")"
assert_eq "upgrade run: Splunk Operator image advances to v2 (not stale v1)" \
  "1" "$(grep -c 'image: registry.example.com/team/splunk-op:v2$' "${_CI_TMPDIR}/rendered-splunk-operator.yaml")"
assert_eq "upgrade run: no stale v1 Splunk Operator image remains" \
  "0" "$(grep -c 'image: registry.example.com/team/splunk-op:v1$' "${_CI_TMPDIR}/rendered-splunk-operator.yaml")"
assert_eq "upgrade run: RELATED_IMAGE_RAY_HEAD still updates on every run" \
  "1" "$(grep -A1 'RELATED_IMAGE_RAY_HEAD' "${_CI_TMPDIR}/rendered-artifacts.yaml" | grep -c 'value: ray-head:v1')"

cat > "${_CI_TMPDIR}/artifacts.yaml" <<'EOF'
      containers:
      - name: manager
        env:
        - name: RELATED_IMAGE_RAY_HEAD
          value: placeholder
        - name: RELATED_IMAGE_RAY_WORKER
          value: placeholder
        - name: RELATED_IMAGE_WEAVIATE
          value: placeholder
        - name: RELATED_IMAGE_SAIA_API
          value: placeholder
        - name: RELATED_IMAGE_SAIA_API_V2
          value: placeholder
        - name: RELATED_IMAGE_POST_INSTALL_HOOK
          value: placeholder
        - name: RELATED_IMAGE_FLUENT_BIT
          value: placeholder
        - name: RELATED_IMAGE_OTEL_COLLECTOR
          value: placeholder
        - name: MODEL_VERSION
          value: placeholder
        - name: RAY_VERSION
          value: placeholder
        image: ghcr.io/splunk/splunk-ai-operator:v0.1.0
EOF

_run_configure_images "registry.example.com/team/platform:v3" "registry.example.com/team/splunk-op:v3" >/dev/null 2>&1

assert_eq "missing RELATED_IMAGE_NGINX is inserted before MODEL_VERSION" \
  "1" "$(awk '
    /name: RELATED_IMAGE_NGINX$/ { nginx = NR }
    /name: MODEL_VERSION$/ { model = NR }
    END { print (nginx > 0 && model > 0 && nginx < model) ? 1 : 0 }
  ' "${_CI_TMPDIR}/rendered-artifacts.yaml")"
assert_eq "inserted RELATED_IMAGE_NGINX gets configured value" \
  "1" "$(grep -A1 'RELATED_IMAGE_NGINX' "${_CI_TMPDIR}/rendered-artifacts.yaml" | grep -c 'value: nginx:v1')"

rm -rf "${_CI_TMPDIR}"
trap - EXIT

# ── Tests: validate_image_config mutable-tag warnings ─────────────────────────
# Covers the tag-parsing fix (registry ports must not be mistaken for tags)
# and the full set of RELATED_IMAGE_* fields configure_images patches, since
# every patched field needs a corresponding mutable-tag check to be useful.

suite "validate_image_config mutable-tag warnings"
echo "▶ validate_image_config mutable-tag warnings"

_run_validate_image_config() {
  # All required fields default to a safe, tagged value; only the fields the
  # caller overrides (as VAR=value args) are exercised for warnings.
  # SPLUNK_MODE=internal so the Splunk-guarded fields are always in scope.
  # `env` (not a bare assignment prefix) is required here because the
  # overrides arrive as already-expanded "$@" positional args, and bash only
  # treats a literal VAR=value token as an assignment prefix — not one that
  # came from a parameter expansion.
  env \
  OPERATOR_IMAGE="op:v1" RAY_HEAD_IMAGE="rh:v1" RAY_WORKER_IMAGE="rw:v1" \
  WEAVIATE_IMAGE="wv:v1" SAIA_API_IMAGE="sa:v1" SAIA_API_V2_IMAGE="sa2:v1" \
  SAIA_DATALOADER_IMAGE="sd:v1" SPLUNK_MODE="internal" SPLUNK_IMAGE="sp:v1" \
  SPLUNK_OPERATOR_IMAGE="spo:v1" FLUENT_BIT_IMAGE="fb:v1" \
  OTEL_COLLECTOR_IMAGE="otel:v1" NGINX_IMAGE="nginx:v1" MODEL_VERSION="v1" \
  RAY_RUNTIME_VERSION="2.44.0" \
  "$@" \
  bash -c "
    $(declare -f build_image_url)
    $(declare -f validate_image_config)
    log()  { :; }
    err()  { echo \"ERR: \$*\"; exit 1; }
    warn() { echo \"WARN: \$*\"; }
    validate_scale_factor_config() { return 0; }
    component_enabled() { return 0; }
    k0s_saia_feature_enabled() { return 0; }
    k0s_slim_feature_enabled() { return 1; }
    k0s_agentruntime_feature_enabled() { return 0; }
    validate_image_config
  "
}

_out="$(_run_validate_image_config OTEL_COLLECTOR_IMAGE="otel:latest")"
assert_eq "otelCollector mutable tag ':latest' is checked (Codex follow-up)" \
  "1" "$(echo "${_out}" | grep -c 'images.otelCollector.image.*mutable tag')"

_out="$(_run_validate_image_config NGINX_IMAGE="nginx" 2>&1)"
assert_eq "nginx untagged image is checked" \
  "1" "$(echo "${_out}" | grep -c 'images.nginx.image.*no explicit tag')"

_out="$(_run_validate_image_config FLUENT_BIT_IMAGE="fb:preview" 2>&1)"
assert_eq "fluentBit mutable tag ':preview' is checked" \
  "1" "$(echo "${_out}" | grep -c 'images.fluentBit.image.*mutable tag')"

_out="$(_run_validate_image_config SPLUNK_IMAGE="sp:latest" 2>&1)"
assert_eq "splunk.image (internal mode) mutable tag is checked" \
  "1" "$(echo "${_out}" | grep -c 'images.splunk.image.*mutable tag')"

_out="$(_run_validate_image_config SPLUNK_OPERATOR_IMAGE="spo:dev" 2>&1)"
assert_eq "splunk.operatorImage (internal mode) mutable tag is checked" \
  "1" "$(echo "${_out}" | grep -c 'images.splunk.operatorImage.*mutable tag')"

_out="$(_run_validate_image_config SAIA_API_IMAGE="localhost:5000/team/saia-api" 2>&1)"
assert_eq "untagged image behind a registry port is NOT mistaken for tagged" \
  "1" "$(echo "${_out}" | grep -c 'images.saia.apiImage.*no explicit tag')"

_out="$(_run_validate_image_config SAIA_API_IMAGE="localhost:5000/team/saia-api:v3" 2>&1)"
assert_eq "tagged image behind a registry port parses the real tag, no false warning" \
  "0" "$(echo "${_out}" | grep -c 'images.saia.apiImage')"

_out="$(_run_validate_image_config RAY_HEAD_IMAGE="rh:stable-2024" 2>&1)"
assert_eq "ray.headImage mutable 'stable*' tag is checked" \
  "1" "$(echo "${_out}" | grep -c 'images.ray.headImage.*mutable tag')"

_out="$(_run_validate_image_config OPERATOR_IMAGE="op:v1.2.3" 2>&1)"
assert_eq "immutable semver-style tag produces no warning" \
  "0" "$(echo "${_out}" | grep -c 'images.operator.image')"

# ── Tests: k0s config path ────────────────────────────────────────────────────
# Verify that the install script uses /etc/k0s/k0s.yaml (not /tmp/k0s.yaml)
# everywhere — config generation, python update script, install command, verify.

suite "k0s config path"

assert_eq "config create writes to /etc/k0s/k0s.yaml" \
  "0" "$(grep -c '/tmp/k0s\.yaml' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "k0s install controller uses /etc/k0s/k0s.yaml" \
  "1" "$(grep -c 'k0s install controller.*--config /etc/k0s/k0s.yaml' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "python update script reads /etc/k0s/k0s.yaml" \
  "1" "$(grep -c "open('/etc/k0s/k0s.yaml', 'r')" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "python update script writes /etc/k0s/k0s.yaml" \
  "1" "$(grep -c "open('/etc/k0s/k0s.yaml', 'w')" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "verify step uses /etc/k0s/k0s.yaml" \
  "1" "$(grep -c 'grep.*api.*etc/k0s/k0s.yaml' "${SCRIPT}" | tr -d '[:space:]')"

# ── Tests: k0s advertised API address ────────────────────────────────────────

suite "k0s advertised API address"

assert_eq "optional external API address is loaded from config" \
  "1" "$(grep -c 'K0S_API_EXTERNAL_ADDRESS=.*cluster.apiExternalAddress' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "configured external API address is included in certificate SANs" \
  "1" "$(grep -c '_configured_external_addr not in.*sans' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "configured external API address takes precedence over the private address" \
  "1" "$(grep -c '_external_addr = _configured_external_addr or _internal_addr' "${SCRIPT}" | tr -d '[:space:]')"

# ── Tests: kine compaction ─────────────────────────────────────────────────────
# Verify that the generated k0s config passes --compact-interval to kine via
# extraArgs (the only valid path — KineConfig has no compactInterval field).

suite "kine compaction"

assert_eq "kine compact-interval passed via extraArgs" \
  "1" "$(grep -c "extraArgs.*compact-interval\|compact-interval.*5m" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "extraArgs dict is initialised before setting compact-interval" \
  "1" "$(grep -c "'extraArgs' not in config\['spec'\]\['storage'\]\['kine'\]" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "kine dict is initialised before setting extraArgs" \
  "1" "$(grep -c "'kine' not in config\['spec'\]\['storage'\]" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "storage type is still set to kine" \
  "1" "$(grep -c "config\['spec'\]\['storage'\]\['type'\] = 'kine'" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "no bare compactInterval field (would be silently ignored by k0s)" \
  "0" "$(grep -c "kine\]\['compactInterval'\]" "${SCRIPT}" | tr -d '[:space:]')"

# ── Tests: configure_insecure_registry_on_node ────────────────────────────────
# Verify the function exists, is gated behind IMAGE_REGISTRY_INSECURE, uses
# IMAGE_REGISTRY (not a hardcoded IP), writes the config_path drop-in for v2,
# and is called AFTER the API server wait.

suite "configure_insecure_registry_on_node"

assert_eq "function is defined" \
  "1" "$(grep -c '^configure_insecure_registry_on_node()' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "uses IMAGE_REGISTRY variable not hardcoded IP" \
  "0" "$(grep -A50 '^configure_insecure_registry_on_node()' "${SCRIPT}" | grep -c '172\.[0-9]' | tr -d '[:space:]')"

assert_eq "gated behind IMAGE_REGISTRY_INSECURE flag" \
  "1" "$(grep -A8 '^configure_insecure_registry_on_node()' "${SCRIPT}" | grep -c 'IMAGE_REGISTRY_INSECURE' | tr -d '[:space:]')"

assert_eq "IMAGE_REGISTRY_INSECURE loaded from config" \
  "1" "$(grep -c 'IMAGE_REGISTRY_INSECURE.*registryInsecure' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "waits for containerd.toml before detecting version (no silent v1 fallback)" \
  "1" "$(grep -A40 '^configure_insecure_registry_on_node()' "${SCRIPT}" | grep -c 'until sudo test -f /etc/k0s/containerd\.toml' | tr -d '[:space:]')"

assert_eq "times out and exits non-zero if containerd.toml never appears" \
  "1" "$(grep -A40 '^configure_insecure_registry_on_node()' "${SCRIPT}" | grep -c 'exit 1' | tr -d '[:space:]')"

assert_eq "detects containerd version from containerd.toml (not binary — avoids race/fallback bug)" \
  "1" "$(grep -A40 '^configure_insecure_registry_on_node()' "${SCRIPT}" | grep -c 'grep.*containerd.*cri.*v1.*containerd\.toml' | tr -d '[:space:]')"

assert_eq "v2 path writes config_path drop-in (required for certs.d to be read)" \
  "1" "$(grep -c 'registry-config-path\.toml' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "v2 path writes hosts.toml (functional line in function body)" \
  "1" "$(grep 'hosts\.toml' "${SCRIPT}" | grep -c 'tee\|mkdir' | tr -d '[:space:]')"

assert_eq "v2 path uses /etc/k0s/containerd/certs.d (functional line in function body)" \
  "1" "$(grep 'etc/k0s/containerd/certs\.d' "${SCRIPT}" | grep -c 'mkdir' | tr -d '[:space:]')"

assert_eq "v2 path removes stale v1 drop-in and v1 path writes it (2 references in function)" \
  "2" "$(grep -A80 '^configure_insecure_registry_on_node()' "${SCRIPT}" | grep -c 'insecure-registry\.toml' | tr -d '[:space:]')"

assert_eq "stale v1 drop-in removed before controller k0s start" \
  "1" "$(awk '/stage_k0s_image_bundle.*controller_ip/{found=1} found && /rm -f.*insecure-registry\.toml/{print; exit}' "${SCRIPT}" | grep -c 'insecure-registry' | tr -d '[:space:]')"

assert_eq "stale v1 drop-in removed before worker k0s start" \
  "1" "$(awk '/Starting k0s worker on/{found=1} found && /rm -f.*insecure-registry\.toml/{print; exit}' "${SCRIPT}" | grep -c 'insecure-registry' | tr -d '[:space:]')"

assert_eq "controller registry config called after API server wait loop" \
  "1" "$(awk '/ctrl_retries < 60/{found=1} found && /configure_insecure_registry_on_node.*controller_ip/{print; exit}' "${SCRIPT}" | grep -c 'configure_insecure_registry_on_node' | tr -d '[:space:]')"

assert_eq "worker registry config called after k0s start succeeds" \
  "1" "$(awk '/sudo k0s start/{found=1} found && /configure_insecure_registry_on_node.*worker_ip/{print; exit}' "${SCRIPT}" | grep -c 'configure_insecure_registry_on_node' | tr -d '[:space:]')"

assert_eq "returns early when IMAGE_REGISTRY is empty" \
  "1" "$(grep -A8 '^configure_insecure_registry_on_node()' "${SCRIPT}" | grep -c '\[\[ -z.*registry.*\]\] && return 0' | tr -d '[:space:]')"

# ── Tests: air-gap OCI import sequencing ─────────────────────────────────────
# The first k0s start imports image bundles while containerd is still coming up.
# Registry drop-ins must not be written until that import completes because the
# config watcher restarts containerd. After the drop-in is written, the script
# deliberately restarts k0s and verifies every image before installing add-ons.

suite "air-gap OCI import sequencing"

assert_eq "bundle import waiter is defined" \
  "1" "$(grep -c '^wait_for_k0s_image_bundles()' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "bundle waiter covers every staged tar archive" \
  "1" "$(grep -A18 '^wait_for_k0s_image_bundles()' "${SCRIPT}" | grep -c 'AIRGAP_K0S_IMAGE_DIR.*\.tar' | tr -d '[:space:]')"

assert_eq "bundle waiter recognizes successful OCIBundleReconciler completion" \
  "1" "$(grep -A45 '^wait_for_k0s_image_bundles()' "${SCRIPT}" | grep -c 'OCI bundle /var/lib/k0s/images/.* loaded' | tr -d '[:space:]')"

assert_eq "bundle waiter fails on explicit OCI import failure" \
  "1" "$(grep -A45 '^wait_for_k0s_image_bundles()' "${SCRIPT}" | grep -c 'Failed to load OCI bundle /var/lib/k0s/images/' | tr -d '[:space:]')"

assert_eq "image verifier checks bundle lists against k8s.io containerd namespace" \
  "1" "$(grep -A25 '^verify_airgap_bundle_images_on_node()' "${SCRIPT}" | grep -c 'k0s ctr -n k8s.io images list -q' | tr -d '[:space:]')"

assert_eq "registry configuration is followed by explicit k0s service restart" \
  "1" "$(grep -A18 '^restart_k0s_after_registry_configuration()' "${SCRIPT}" | grep -c 'systemctl restart.*service_name' | tr -d '[:space:]')"

assert_eq "controller waits for initial bundle import before registry configuration" \
  "1" "$(awk '
    /wait_for_k0s_image_bundles.*controller_ip.*k0scontroller.*controller_start_epoch/ { waited=1 }
    waited && /configure_insecure_registry_on_node.*controller_ip/ { print 1; exit }
  ' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "worker waits for initial bundle import before registry configuration" \
  "1" "$(awk '
    /wait_for_k0s_image_bundles.*worker_ip.*k0sworker.*worker_start_epoch/ { waited=1 }
    waited && /configure_insecure_registry_on_node.*worker_ip/ { print 1; exit }
  ' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "all-node image verification runs before AI Platform stack installation" \
  "1" "$(awk '
    /^[[:space:]]+verify_airgap_bundle_images_on_all_nodes$/ { verified=1 }
    verified && /phase_start "AI Platform Stack"/ { print 1; exit }
  ' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "existing-cluster reruns refresh changed bundles before all-node verification" \
  "1" "$(awk '
    /refresh_airgap_image_bundles_on_existing_nodes/ { refreshed=1 }
    refreshed && /^[[:space:]]+verify_airgap_bundle_images_on_all_nodes$/ { print 1; exit }
  ' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "existing-cluster refresh compares local and remote archive checksums" \
  "2" "$(grep -A35 '^refresh_airgap_image_bundles_on_running_node()' "${SCRIPT}" | grep -c 'sha256sum' | tr -d '[:space:]')"

assert_eq "existing-cluster refresh stops k0s before replacing archives" \
  "1" "$(awk '
    /^refresh_airgap_image_bundles_on_running_node\(\)/ { in_fn=1 }
    in_fn && /systemctl stop.*service_name/ { stopped=1 }
    stopped && /sudo mv -f.*staged_paths/ { print 1; exit }
    in_fn && /^}/ { exit }
  ' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "existing-cluster refresh waits for import after restarting k0s" \
  "1" "$(awk '
    /^refresh_airgap_image_bundles_on_running_node\(\)/ { in_fn=1 }
    in_fn && /systemctl start.*service_name/ { started=1 }
    started && /wait_for_k0s_image_bundles/ { print 1; exit }
    in_fn && /^}/ { exit }
  ' "${SCRIPT}" | tr -d '[:space:]')"

_exercise_existing_bundle_refresh() (
  local mode="$1" fixture_dir trace_file fixture_sha
  fixture_dir=$(mktemp -d)
  trace_file="${fixture_dir}/trace"
  trap 'rm -rf "${fixture_dir}"' EXIT

  printf 'archive-content\n' > "${fixture_dir}/k0s-images.tar"
  printf '%s\n' 'quay.io/k0sproject/pause:3.10' > "${fixture_dir}/k0s-images.list"
  fixture_sha=$(sha256sum "${fixture_dir}/k0s-images.tar" | awk '{print $1}')

  eval "$(_extract_fn airgap_k0s_image_bundles_enabled)"
  eval "$(_extract_fn wait_for_k0s_image_bundles)"
  eval "$(_extract_fn verify_airgap_bundle_images_on_node)"
  eval "$(_extract_fn refresh_airgap_image_bundles_on_running_node)"

  AIRGAP_K0S_IMAGE_DIR="${fixture_dir}"
  AIRGAP_IMAGE_IMPORT_TIMEOUT=10
  log() { :; }
  warn() { :; }
  scp_file() { echo scp >> "${trace_file}"; }
  ssh_exec() {
    local args="$*"
    case "${args}" in
      *'sha256sum /var/lib/k0s/images/'*)
        [[ "${mode}" == "current" ]] && echo "${fixture_sha}"
        ;;
      *'systemctl stop'*) echo stop >> "${trace_file}" ;;
      *'sudo mv -f'*) echo move >> "${trace_file}" ;;
      *'date +%s'*) echo 100 ;;
      *'systemctl start'*) echo start >> "${trace_file}" ;;
      *'systemctl is-active'*) return 0 ;;
      *'systemctl show'*) echo 4242 ;;
      *'journalctl'*) echo 'OCI bundle /var/lib/k0s/images/k0s-images.tar loaded' ;;
      *'images list -q'*) echo 'quay.io/k0sproject/pause:3.10' ;;
      *) return 0 ;;
    esac
  }

  refresh_airgap_image_bundles_on_running_node 192.0.2.10 k0sworker || return
  if [[ "${mode}" == "changed" ]]; then
    [[ "$(cat "${trace_file}")" == $'scp\nstop\nmove\nstart' ]]
  else
    [[ ! -s "${trace_file}" ]]
  fi
)

assert_rc "existing-cluster refresh atomically replaces a changed archive and restarts once" 0 \
  _exercise_existing_bundle_refresh changed

assert_rc "existing-cluster refresh skips copying and restarting a matching archive" 0 \
  _exercise_existing_bundle_refresh current

assert_eq "reruns recycle cert-manager pods stuck in image pull backoff" \
  "1" "$(_extract_fn install_cert_manager | grep -c 'cert_manager_image_pull_backoff_pods' | tr -d '[:space:]')"

_exercise_cert_manager_backoff_selector() (
  eval "$(_extract_fn cert_manager_image_pull_backoff_pods)"
  kubectl() {
    printf '%s\n' '{
      "items": [
        {
          "metadata": {"name": "cert-manager-cainjector-stale"},
          "status": {"containerStatuses": [
            {"state": {"waiting": {"reason": "ImagePullBackOff"}}}
          ]}
        },
        {
          "metadata": {"name": "cert-manager-healthy"},
          "status": {"containerStatuses": [
            {"state": {"running": {"startedAt": "2026-08-12T00:00:00Z"}}}
          ]}
        },
        {
          "metadata": {"name": "cert-manager-init-stale"},
          "status": {"initContainerStatuses": [
            {"state": {"waiting": {"reason": "ErrImagePull"}}}
          ]}
        }
      ]
    }'
  }
  cert_manager_image_pull_backoff_pods
)

assert_eq "cert-manager selector handles status arrays and returns only pull failures" \
  $'cert-manager-cainjector-stale\ncert-manager-init-stale' \
  "$(_exercise_cert_manager_backoff_selector)"

assert_eq "cert-manager install requires a functional admission request" \
  "1" "$(_extract_fn install_cert_manager | grep -c 'wait_for_cert_manager_webhook 30 10' | tr -d '[:space:]')"

assert_eq "cert-manager recovery waits on deployments instead of obsolete pod UIDs" \
  "1" "$(_extract_fn install_cert_manager | grep -c 'kubectl rollout status.*deployment/' | tr -d '[:space:]')"

assert_eq "cert-manager admission probe is a non-persistent server dry run" \
  "1" "$(_extract_fn wait_for_cert_manager_webhook | grep -c 'kubectl create --dry-run=server' | tr -d '[:space:]')"

assert_eq "cert-manager phase-one failure is fatal" \
  "1" "$(grep -A50 'Track required phase-1 tasks' "${SCRIPT}" | grep -c 'cert-manager|nvidia-drivers' | tr -d '[:space:]')"

# ── Tests: air-gap model staging contract ─────────────────────────────────────

suite "air-gap model staging contract"

_exercise_airgap_model_staging_resolution() (
  eval "$(_extract_fn resolve_model_staging)"
  SILENT_INSTALL=false
  AIRGAP_MODE=true
  MODEL_STAGING_ENABLED=true
  resolve_model_staging <<< "y"
  printf '%s' "${MODEL_STAGING_ENABLED}"
)

assert_eq "air-gap mode honours enabled model staging on the connected installer" \
  "true" "$(_exercise_airgap_model_staging_resolution)"

assert_eq "air-gap staging checks installer-host HuggingFace reachability" \
  "1" "$(_extract_fn stage_model_artifacts | grep -c 'wait_for_dependency' | tr -d '[:space:]')"

assert_eq "air-gap install verifies markers when automatic model staging is disabled" \
  "1" "$(grep -A25 'phase_start "Model Staging"' "${SCRIPT}" | grep -c 'verify_pre_staged_model_artifacts' | tr -d '[:space:]')"

assert_eq "pre-staged model verification uses the selected accelerator profile" \
  "1" "$(_extract_fn verify_pre_staged_model_artifacts | grep -c 'all_models_staged.*staging_dir.*_accel' | tr -d '[:space:]')"

assert_eq "air-gap OCI builder retries transient registry failures" \
  "1" "$(grep -A45 '^build_k0s_airgap_bundle()' "${AIRGAP_SCRIPT}" | grep -c 'attempt < max_attempts' | tr -d '[:space:]')"

assert_eq "air-gap OCI builder writes an atomic partial archive" \
  "1" "$(grep -A45 '^build_k0s_airgap_bundle()' "${AIRGAP_SCRIPT}" | grep -c 'partial_tar=.*\.partial\.tar' | tr -d '[:space:]')"

assert_eq "k0s system image bundle uses retry helper" \
  "1" "$(grep -A15 'k0s system images to bundle:' "${AIRGAP_SCRIPT}" | grep -c 'build_k0s_airgap_bundle' | tr -d '[:space:]')"

assert_eq "add-on image bundle uses retry helper" \
  "1" "$(grep -A12 'Building add-on image bundle (pulls' "${AIRGAP_SCRIPT}" | grep -c 'build_k0s_airgap_bundle' | tr -d '[:space:]')"

# ── MPR-193: the bundle carries its tool, snapshot and manifest ───────────────
suite "air-gap bundle staging (MPR-193)"

# _ab_has <description> <haystack> <needle>
_ab_has() { assert_eq "$1" "yes" "$([[ "$2" == *"$3"* ]] && echo yes || echo no)"; }

# Runs one staging helper from airgap_install.sh in a subshell, with err() exiting as it does
# there. Prints the helper's output, then "rc=<status>".
_airgap_stage_helper() (
  local fn="$1"; shift
  log() { :; }; warn() { :; }; err() { echo "ERR: $*"; exit 1; }
  # Earlier suites stub yq with a function; these helpers read real config files.
  yq() { "${YQ_BIN}" "$@"; }
  REPO_ROOT="${AIRGAP_TEST_REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
  AIRGAP_BUNDLE_BINARY="${AIRGAP_BUNDLE_BINARY:-}"
  AIRGAP_SNAPSHOT_MANIFEST="${AIRGAP_SNAPSHOT_MANIFEST:-}"
  eval "$(_extract_airgap_fn "${fn}")"
  "${fn}" "$@"
  echo "rc=$?"
)

_ab_dir="$(mktemp -d)"
mkdir -p "${_ab_dir}/cfg/snapshots/run-1"
printf '{}' > "${_ab_dir}/cfg/snapshots/run-1/manifest.json"
printf 'x  manifest.json\n' > "${_ab_dir}/cfg/snapshots/run-1/manifest.json.sha256"
printf 'images:\n  snapshotManifest: snapshots/run-1/manifest.json\naiPlatform:\n  profile: cpuOnly\n' > "${_ab_dir}/cfg/cpu.yaml"
printf 'aiPlatform:\n  defaultAcceleratorType: H100\n' > "${_ab_dir}/cfg/full.yaml"

assert_eq "snapshot: images.snapshotManifest is resolved relative to the config file" \
  "${_ab_dir}/cfg/snapshots/run-1/manifest.json" \
  "$(CONFIG_FILE="${_ab_dir}/cfg/cpu.yaml" _airgap_stage_helper resolve_snapshot_manifest | head -1)"
assert_eq "snapshot: AIRGAP_SNAPSHOT_MANIFEST wins over the config" \
  "${_ab_dir}/cfg/snapshots/run-1/manifest.json" \
  "$(CONFIG_FILE="${_ab_dir}/cfg/full.yaml" AIRGAP_SNAPSHOT_MANIFEST="${_ab_dir}/cfg/snapshots/run-1/manifest.json" _airgap_stage_helper resolve_snapshot_manifest | head -1)"
_out="$(CONFIG_FILE="${_ab_dir}/cfg/full.yaml" _airgap_stage_helper resolve_snapshot_manifest)"
_ab_has "snapshot: none configured fails closed" "${_out}" "ERR: An image snapshot is required"
rm "${_ab_dir}/cfg/snapshots/run-1/manifest.json.sha256"
_out="$(CONFIG_FILE="${_ab_dir}/cfg/cpu.yaml" _airgap_stage_helper resolve_snapshot_manifest)"
_ab_has "snapshot: a missing checksum file fails closed" "${_out}" "its checksum file"

assert_eq "profile: cpuOnly is read from the config" "cpuOnly" "$(CONFIG_FILE="${_ab_dir}/cfg/cpu.yaml" _airgap_stage_helper bundle_profile | head -1)"
assert_eq "profile: omitted is fullfeature" "fullfeature" "$(CONFIG_FILE="${_ab_dir}/cfg/full.yaml" _airgap_stage_helper bundle_profile | head -1)"
_ab_has "models: H100 uses the quantized configuration" \
  "$(CONFIG_FILE="${_ab_dir}/cfg/full.yaml" _airgap_stage_helper bundle_model_config | head -1)" "model_artifacts_configs_quantized.yaml"
_ab_has "models: no accelerator uses the unquantized configuration (as the installer does)" \
  "$(CONFIG_FILE="${_ab_dir}/cfg/cpu.yaml" _airgap_stage_helper bundle_model_config | head -1)" "model_artifacts_configs_unquantized.yaml"
printf 'aiPlatform:\n  defaultAcceleratorType: tpu\n' > "${_ab_dir}/cfg/tpu.yaml"
_ab_has "models: an unknown accelerator fails" \
  "$(CONFIG_FILE="${_ab_dir}/cfg/tpu.yaml" _airgap_stage_helper bundle_model_config)" "ERR: Unsupported aiPlatform.defaultAcceleratorType 'tpu'"

printf '#!/usr/bin/env bash\nexit 0\n' > "${_ab_dir}/prebuilt"; chmod +x "${_ab_dir}/prebuilt"
_ab_has "tool: a prebuilt AIRGAP_BUNDLE_BINARY is staged" \
  "$(AIRGAP_BUNDLE_BINARY="${_ab_dir}/prebuilt" _airgap_stage_helper stage_airgap_bundle_tool "${_ab_dir}/staged")" "rc=0"
assert_eq "tool: the staged copy is executable" "yes" "$([[ -x "${_ab_dir}/staged" ]] && echo yes || echo no)"
printf 'not executable' > "${_ab_dir}/noexec"
_ab_has "tool: a non-executable AIRGAP_BUNDLE_BINARY is refused" \
  "$(AIRGAP_BUNDLE_BINARY="${_ab_dir}/noexec" _airgap_stage_helper stage_airgap_bundle_tool "${_ab_dir}/x")" "is not an executable file"
printf '#!/usr/bin/env bash\nexit 3\n' > "${_ab_dir}/broken"; chmod +x "${_ab_dir}/broken"
_ab_has "tool: a binary that does not run here is refused" \
  "$(AIRGAP_BUNDLE_BINARY="${_ab_dir}/broken" _airgap_stage_helper stage_airgap_bundle_tool "${_ab_dir}/y")" "does not run on this host"
_ab_has "tool: without Go or a prebuilt binary staging fails closed" \
  "$(AIRGAP_TEST_REPO_ROOT="${_ab_dir}/no-repo" _airgap_stage_helper stage_airgap_bundle_tool "${_ab_dir}/z")" "Cannot stage the airgap-bundle tool"
rm -rf "${_ab_dir}"

# The order matters: the snapshot is staged before the checksums, the manifest after them,
# and the bundle is checked before anything is transferred or installed.
_line() { grep -n "$1" "${AIRGAP_SCRIPT}" | head -1 | cut -d: -f1; }
assert_eq "order: snapshot before checksums" "yes" "$([[ $(_line '^# ── 8b. Image snapshot') -lt $(_line '^# ── 9. Checksums') ]] && echo yes || echo no)"
assert_eq "order: manifest after checksums" "yes" "$([[ $(_line '^# ── 9. Checksums') -lt $(_line '^# ── 9b. Bundle manifest') ]] && echo yes || echo no)"
assert_eq "order: bundle check before the installer runs" "yes" "$([[ $(_line '^# ── 9c. Check the bundle') -lt $(_line '^# ── 12. Run the installer') ]] && echo yes || echo no)"
assert_eq "the bundle check fails closed" "1" "$(grep -A6 '^# ── 9c. Check the bundle' "${AIRGAP_SCRIPT}" | grep -c 'nothing was transferred or installed' | tr -d '[:space:]')"

# ── MPR-193: the install-side air-gap preflight ────────────────────────────────
suite "air-gap install preflight (MPR-193)"

_ip_has() { assert_eq "$1" "yes" "$([[ "$2" == *"$3"* ]] && echo yes || echo no)"; }

# A bundle with a checksummed manifest that lists the tool with its checksum.
_ip_bundle() {
  local d="$1" tool_body="$2" sum
  mkdir -p "${d}/binaries"
  printf '%s' "${tool_body}" > "${d}/binaries/airgap-bundle"; chmod +x "${d}/binaries/airgap-bundle"
  sum="$(shasum -a 256 "${d}/binaries/airgap-bundle" 2>/dev/null | awk '{print $1}')"
  [[ -n "${sum}" ]] || sum="$(sha256sum "${d}/binaries/airgap-bundle" | awk '{print $1}')"
  printf '{"metadata":{"id":"bundle-1"},"spec":{"snapshot":{"id":"snap-1"},"files":[{"path":"binaries/airgap-bundle","sha256":"%s"}]}}' "${sum}" > "${d}/bundle-manifest.json"
  sum="$(shasum -a 256 "${d}/bundle-manifest.json" 2>/dev/null | awk '{print $1}')"
  [[ -n "${sum}" ]] || sum="$(sha256sum "${d}/bundle-manifest.json" | awk '{print $1}')"
  printf '%s  bundle-manifest.json\n' "${sum}" > "${d}/bundle-manifest.json.sha256"
}

_ip_run() ( eval "$(_extract_fn _sha256_of)"; eval "$(_extract_fn airgap_bundle_tool)"; airgap_bundle_tool "$1"; echo "rc=$?" )
_ip_dir="$(mktemp -d)"
_ip_bundle "${_ip_dir}/ok" $'#!/usr/bin/env bash\nexit 0\n'
_ip_has "tool: a tool matching the manifest is trusted" "$(_ip_run "${_ip_dir}/ok")" "${_ip_dir}/ok/binaries/airgap-bundle"
_ip_bundle "${_ip_dir}/swapped" $'#!/usr/bin/env bash\nexit 0\n'
printf '#!/usr/bin/env bash\necho pwned\n' > "${_ip_dir}/swapped/binaries/airgap-bundle"
_ip_has "tool: a replaced tool is refused" "$(_ip_run "${_ip_dir}/swapped")" "does not match the bundle manifest"
_ip_bundle "${_ip_dir}/edited" $'#!/usr/bin/env bash\nexit 0\n'
printf ' ' >> "${_ip_dir}/edited/bundle-manifest.json"
_ip_has "tool: an edited manifest is refused" "$(_ip_run "${_ip_dir}/edited")" "does not match its checksum file"
mkdir -p "${_ip_dir}/empty"
_ip_has "tool: a bundle without a manifest is refused" "$(_ip_run "${_ip_dir}/empty")" "no checksummed bundle-manifest.json"
rm -rf "${_ip_dir}"

eval "$(_extract_fn _node_platform)"
assert_eq "platform: x86_64 is linux/amd64" "linux/amd64" "$(_node_platform x86_64)"
assert_eq "platform: aarch64 is linux/arm64" "linux/arm64" "$(_node_platform aarch64)"
assert_eq "platform: an unreported architecture stays empty" "" "$(_node_platform "")"

# The facts collector, against stubbed SSH and kubectl: a controller, a CPU worker, and a
# GPU worker on an existing cluster.
_ip_facts() (
  eval "$(_extract_fn _node_platform)"; eval "$(_extract_fn _read_model_marker)"
  eval "$(_extract_fn model_artifacts_config_name)"; eval "$(_extract_fn collect_airgap_host_facts)"
  yq() { "${YQ_BIN}" "$@"; }
  ssh_exec() {
    if [[ "$2" == *"uname -m"* ]]; then printf 'x86_64\nrhel\n5.14.0-503.40.1.el9_5.x86_64\n'; return 0; fi
    if [[ "$2" == *lspci* ]]; then printf '%s\n%s\n%s\n' "${_IP_DEVICES:-2}" "${_IP_DRIVER-550.54.15}" "${_IP_RUNTIME:-true}"; return 0; fi
  }
  # The target cluster (see resolve_target_cluster), here an existing one.
  target_kubectl() { [[ "$*" == "get nodes -o json" ]] && echo '{"items":[{"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.3"}],"allocatable":{"nvidia.com/gpu":"2"}}}]}'; }
  EXISTING_CONTROLLER_IPS="10.0.0.1"; EXISTING_WORKER_IPS="10.0.0.2 10.0.0.3"; CPU_WORKER_COUNT=1; GPU_WORKER_COUNT=1
  OBJ_STORE_TYPE=""; DEFAULT_ACCELERATOR="l40s"
  local out; out="$(mktemp)"
  collect_airgap_host_facts "${out}" "$1" >/dev/null 2>&1
  cat "${out}"; rm -f "${out}"
)
if [[ -n "${YQ_BIN}" ]] && command -v jq >/dev/null 2>&1; then
  _f="$(_ip_facts fullfeature)"
  assert_eq "facts: every node is reported" "3" "$(jq '.nodes | length' <<< "${_f}")"
  assert_eq "facts: platform, OS and kernel" "linux/amd64 rhel 5.14.0-503.40.1.el9_5.x86_64" "$(jq -r '.nodes[0] | "\(.platform) \(.os) \(.kernel)"' <<< "${_f}")"
  assert_eq "facts: only the workers after the CPU workers are GPU nodes" "10.0.0.3" "$(jq -r '[.nodes[] | select(.gpu) | .name] | join(",")' <<< "${_f}")"
  assert_eq "facts: GPU devices, driver and toolkit" "2 550.54.15 true" "$(jq -r '.nodes[2].gpu | "\(.devices) \(.driver) \(.runtime)"' <<< "${_f}")"
  assert_eq "facts: schedulable GPUs come from the existing cluster by node IP" "2" "$(jq -r '.nodes[2].gpu.allocatable' <<< "${_f}")"
  assert_eq "facts: without an object store no model is claimed staged" "0" "$(jq '.stagedModels | length' <<< "${_f}")"
  _f="$(_IP_DRIVER="" _IP_RUNTIME=false _IP_DEVICES=garbage _ip_facts fullfeature)"
  assert_eq "facts: a fresh GPU host reports no driver and no toolkit" " false" "$(jq -r '.nodes[2].gpu | "\(.driver) \(.runtime)"' <<< "${_f}")"
  assert_eq "facts: an unparsable device count is zero, not a guess" "0" "$(jq -r '.nodes[2].gpu.devices' <<< "${_f}")"
fi

# The preflight's wiring: the call site, and how the tool's outcome becomes the result.
assert_eq "preflight: the bundle check runs in air-gap mode, before the summary" "1" \
  "$(_extract_fn preflight_checks | grep -A2 'AIRGAP_MODE:-false}" == "true"' | grep -c 'preflight_check_airgap_bundle' | tr -d '[:space:]')"
assert_eq "preflight: it comes after the SSH dependency checks" "yes" \
  "$(_extract_fn preflight_checks | awk '/preflight_check_remote_deps/{a=NR} /preflight_check_airgap_bundle/{b=NR} END{print (a && b && a<b) ? "yes" : "no"}')"
_ip_pre() (
  PF_FAILS=0; PF_WARN=0
  pf_header() { :; }; pf_ok() { echo "OK: $*"; }; pf_fail() { echo "FAIL: $*"; PF_FAILS=$((PF_FAILS+1)); }
  eval "$(_extract_fn _sha256_of)"; eval "$(_extract_fn airgap_bundle_tool)"; eval "$(_extract_fn preflight_check_airgap_bundle)"
  ai_platform_profile_resolved() { echo cpuOnly; }
  collect_airgap_host_facts() { echo '{"nodes":[]}' > "$1"; }
  render_ai_platform_profile_values() { echo "profile: {effective: cpuOnly}"; }
  airgap_registry_config_dir() { :; }
  CONFIG_FILE=/dev/null; LOG_DIR="$(mktemp -d)"
  preflight_check_airgap_bundle
  echo "fails=${PF_FAILS}"
)
_ip_dir="$(mktemp -d)"
_ip_bundle "${_ip_dir}/pass" $'#!/usr/bin/env bash\necho "OK: complete"; exit 0\n'
_out="$(AIRGAP_BUNDLE_DIR="${_ip_dir}/pass" _ip_pre)"
_ip_has "preflight: a passing bundle is reported with its bundle and snapshot IDs" "${_out}" "OK: bundle bundle-1, snapshot snap-1: complete for cpuOnly"
_ip_has "preflight: and nothing fails" "${_out}" "fails=0"
_ip_bundle "${_ip_dir}/findings" $'#!/usr/bin/env bash\necho "[MIRROR_MISSING_IMAGE] slim: gone" >&2; echo "[BUNDLE_FILE_MISSING] binaries/k0s: absent" >&2; echo "FAILED: 2 problem(s)" >&2; exit 1\n'
_out="$(AIRGAP_BUNDLE_DIR="${_ip_dir}/findings" _ip_pre)"
_ip_has "preflight: each finding fails by name" "${_out}" "FAIL: [MIRROR_MISSING_IMAGE] slim: gone"
_ip_has "preflight: every finding is reported" "${_out}" "FAIL: [BUNDLE_FILE_MISSING] binaries/k0s: absent"
_ip_has "preflight: and the install stops with nothing changed" "${_out}" "nothing was changed"
_ip_has "preflight: three failures (two findings and the verdict)" "${_out}" "fails=3"
_ip_bundle "${_ip_dir}/broken" $'#!/usr/bin/env bash\necho "error: --profile must be cpuOnly or fullfeature" >&2; exit 2\n'
_ip_has "preflight: a tool that cannot run fails, never passes" "$(AIRGAP_BUNDLE_DIR="${_ip_dir}/broken" _ip_pre)" "could not run (exit 2)"
_ip_has "preflight: no bundle directory fails" "$(AIRGAP_BUNDLE_DIR="" _ip_pre)" "AIRGAP_BUNDLE_DIR is not set to a staged bundle"
rm -rf "${_ip_dir}"

# ── MPR-193: no download fallback in an air-gapped install ────────────────────
suite "air-gap no download fallback (MPR-193)"

_nd() ( err() { echo "ERR: $*"; exit 1; }; eval "$(_extract_fn airgap_no_download)"; airgap_no_download "the kuberay-operator chart" "KUBERAY_CHART_PATH=<unset>"; echo "rc=$?" )
_out="$(AIRGAP_MODE=true _nd)"
assert_eq "no-download: an air-gapped install fails by name" "yes" "$([[ "${_out}" == *"ERR: Air-gap install: the kuberay-operator chart is not available from the bundle (KUBERAY_CHART_PATH=<unset>)"* && "${_out}" != *"rc=0"* ]] && echo yes || echo no)"
assert_eq "no-download: a connected install is unaffected" "rc=0" "$(AIRGAP_MODE=false _nd)"

# Every public fallback in the installer is guarded.
assert_eq "no-download: every helm repo add fallback is guarded" "$(grep -c 'helm repo add' "${SCRIPT}" | tr -d ' ')" \
  "$(grep -B1 'helm repo add' "${SCRIPT}" | grep -c 'airgap_no_download' | tr -d ' ')"
for _v in CERT_MANAGER_MANIFEST_URL LOCAL_PATH_MANIFEST_URL NVIDIA_DEVICE_PLUGIN_MANIFEST_URL YQ_DOWNLOAD_URL; do
  assert_eq "no-download: the ${_v} default is guarded" "1" \
    "$(grep -A1 "\${${_v}:-https" "${SCRIPT}" | grep -c 'airgap_no_download' | tr -d ' ')"
done

# ── MPR-193: registry pull Secrets by reference ────────────────────────────────
suite "registry pull Secrets by reference (MPR-193)"

_ps_has() { assert_eq "$1" "yes" "$([[ "$2" == *"$3"* ]] && echo yes || echo no)"; }
_ps_dir="$(mktemp -d)"
printf '{"auths":{"mirror.airgap.local:5000":{"auth":"bWlycm9yOnMzY3IzdA=="}}}' > "${_ps_dir}/mirror.json"
printf 'not json' > "${_ps_dir}/bad.json"

_ps() ( # _ps <config body> <function> [args]: run a pull-secret helper against a config
  local body="$1"; shift
  printf '%s' "${body}" > "${_ps_dir}/cfg.yaml"
  CONFIG_FILE="${_ps_dir}/cfg.yaml"
  yq() { "${YQ_BIN}" "$@"; }
  log() { echo "LOG: $*"; }; err() { echo "ERR: $*"; exit 1; }
  ensure_namespace() { :; }
  # kubectl stub: Secrets listed in _PS_EXISTING exist with type _PS_TYPE; record calls.
  kubectl() {
    echo "KUBECTL $*" >> "${_ps_dir}/calls"
    case "$*" in
      "get secret "*" -o jsonpath={.type}") echo "${_PS_TYPE:-kubernetes.io/dockerconfigjson}"; return 0 ;;
      "get secret "*) local n="$3"; [[ " ${_PS_EXISTING:-} " == *" ${n} "* ]]; return $? ;;
      "apply -f -") cat > "${_ps_dir}/applied.yaml"; return 0 ;;
      create*) echo "kind: Secret"; return 0 ;;
    esac
  }
  for f in configured_pull_secret_names _pull_secret_file validate_pull_secret_config ensure_configured_pull_secrets image_pull_secret_names; do
    eval "$(_extract_fn "${f}")"
  done
  "$@"
  echo "rc=$?"
)
if [[ -n "${YQ_BIN}" ]] && command -v jq >/dev/null 2>&1; then
  _good=$'images:\n  imagePullSecrets:\n    - name: mirror-pull\n      dockerConfigFile: mirror.json\n'
  cp "${_ps_dir}/mirror.json" "${_ps_dir}/mirror.json.keep"
  assert_eq "validate: a name and a Docker configuration relative to the config are valid" "rc=0" "$(_ps "${_good}" validate_pull_secret_config)"
  _ps_has "validate: an invalid Secret name" "$(_ps $'images:\n  imagePullSecrets:\n    - name: Mirror_Pull\n' validate_pull_secret_config)" "must be a Kubernetes Secret name"
  _ps_has "validate: a name listed twice" "$(_ps $'images:\n  imagePullSecrets:\n    - name: a\n    - name: a\n' validate_pull_secret_config)" "a is listed twice"
  _ps_has "validate: an unreadable Docker configuration" "$(_ps $'images:\n  imagePullSecrets:\n    - name: a\n      dockerConfigFile: nowhere.json\n' validate_pull_secret_config)" "is not a readable file"
  _ps_has "validate: a file that is not a Docker configuration" "$(_ps $'images:\n  imagePullSecrets:\n    - name: a\n      dockerConfigFile: bad.json\n' validate_pull_secret_config)" "is not a Docker configuration"
  assert_eq "validate: no setting is valid" "rc=0" "$(_ps $'images: {}\n' validate_pull_secret_config)"

  rm -f "${_ps_dir}/calls" "${_ps_dir}/applied.yaml"
  _out="$(_ps "${_good}" ensure_configured_pull_secrets ai-platform)"
  _ps_has "ensure: a missing Secret is created from its Docker configuration" "${_out}" "pull Secret ai-platform/mirror-pull created"
  _ps_has "ensure: as a dockerconfigjson Secret from that file" "$(cat "${_ps_dir}/calls")" "create secret generic mirror-pull --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=${_ps_dir}/mirror.json -n ai-platform"
  assert_eq "ensure: the credentials never reach the output" "no" "$([[ "${_out}" == *bWlycm9y* ]] && echo yes || echo no)"
  _ps_has "ensure: an existing dockerconfigjson Secret is used" "$(_PS_EXISTING=mirror-pull _ps "${_good}" ensure_configured_pull_secrets ai-platform)" "pull Secret ai-platform/mirror-pull present"
  _ps_has "ensure: an existing Secret of another type fails closed" \
    "$(_PS_EXISTING=mirror-pull _PS_TYPE=Opaque _ps "${_good}" ensure_configured_pull_secrets ai-platform)" "is of type 'Opaque', not kubernetes.io/dockerconfigjson"
  _ps_has "ensure: a missing Secret without a Docker configuration fails closed" \
    "$(_ps $'images:\n  imagePullSecrets:\n    - name: mirror-pull\n' ensure_configured_pull_secrets ai-platform)" "does not exist and images.imagePullSecrets[0].dockerConfigFile is not set"

  _names="$(_PS_EXISTING="ecr-registry-secret mirror-pull" _ps $'images:\n  imagePullSecrets:\n    - name: mirror-pull\n    - name: ecr-registry-secret\n' image_pull_secret_names ai-platform)"
  assert_eq "names: present Secrets, installer-created and configured, without duplicates" $'ecr-registry-secret\nmirror-pull\nrc=0' "${_names}"
fi
rm -rf "${_ps_dir}"

# Every place that lists pull Secrets uses the same names.
assert_eq "names: the CR and both operator Deployments use image_pull_secret_names" "3" \
  "$(grep -c 'for secret_name in \$(image_pull_secret_names' "${SCRIPT}" | tr -d ' ')"
assert_eq "names: no fixed list remains" "0" \
  "$(grep -c 'for secret_name in ecr-registry-secret docker-hub-secret' "${SCRIPT}" | tr -d ' ')"
assert_eq "ensure: configured Secrets are ensured in all three namespaces, failures not swallowed" "3" \
  "$(grep -c '^  ensure_configured_pull_secrets "' "${SCRIPT}" | tr -d ' ')"

# ── MPR-193: node images by digest; the install record ─────────────────────────
suite "air-gap node digests and install record (MPR-193)"

_nr_has() { assert_eq "$1" "yes" "$([[ "$2" == *"$3"* ]] && echo yes || echo no)"; }
_nr_dir="$(mktemp -d)"
mkdir -p "${_nr_dir}/bundle/images"
printf 'quay.io/k0sproject/coredns:1.11.3\n' > "${_nr_dir}/bundle/images/k0s-images.list"
cat > "${_nr_dir}/bundle/bundle-manifest.json" <<'JSON'
{"metadata":{"id":"bundle-7"},"spec":{"snapshot":{"id":"snap-7","checksum":"abc","mirror":"mirror.airgap.local:5000/ai-tier"},
 "archiveImages":[{"ref":"quay.io/k0sproject/coredns:1.11.3","digest":"sha256:1111","archive":"images/k0s-images.tar"},
                  {"ref":"quay.io/k0sproject/coredns@sha256:1111","digest":"sha256:1111","archive":"images/k0s-images.tar"}]}}
JSON
_nr_node() ( # _nr_node <digest the node reports>
  warn() { echo "WARN: $*"; }; log() { echo "LOG: $*"; }
  airgap_k0s_image_bundles_enabled() { return 0; }
  ssh_exec() {
    if [[ "$2" == *"list -q"* ]]; then echo "quay.io/k0sproject/coredns:1.11.3"; return 0; fi
    printf 'REF TYPE DIGEST SIZE\nquay.io/k0sproject/coredns:1.11.3 application/vnd.oci.image.index.v1+json %s 10MiB\n' "${_nr_digest}"
  }
  local _nr_digest="$1"
  AIRGAP_K0S_IMAGE_DIR="${_nr_dir}/bundle/images"; AIRGAP_BUNDLE_DIR="${_nr_dir}/bundle"
  eval "$(_extract_fn verify_airgap_bundle_images_on_node)"
  verify_airgap_bundle_images_on_node 10.0.0.1
  echo "rc=$?"
)
if command -v jq >/dev/null 2>&1; then
  _nr_has "node digests: the bundle's image passes" "$(_nr_node sha256:1111)" "rc=0"
  _out="$(_nr_node sha256:9999)"
  _nr_has "node digests: another build under the same tag fails" "${_out}" "rc=1"
  _nr_has "node digests: and names both digests" "${_out}" "quay.io/k0sproject/coredns:1.11.3: node has sha256:9999, bundle has sha256:1111"
fi

_nr_rec() (
  log() { :; }; ai_platform_profile_resolved() { echo fullfeature; }
  AIRGAP_MODE=true; AIRGAP_BUNDLE_DIR="${_nr_dir}/bundle"; LOG_DIR="${_nr_dir}/logs"
  eval "$(_extract_fn write_airgap_install_record)"
  write_airgap_install_record "$1"
  cat "${LOG_DIR}/airgap-install-record.json"
)
if command -v jq >/dev/null 2>&1; then
  _rec="$(_nr_rec started)"
  assert_eq "record: the bundle, snapshot, profile and status" "bundle-7 snap-7 abc fullfeature started" \
    "$(jq -r '"\(.bundleId) \(.snapshotId) \(.snapshotChecksum) \(.profile) \(.status)"' <<< "${_rec}")"
  assert_eq "record: no credential-looking field" "0" "$(grep -ciE 'password|token|auth' <<< "${_rec}" | tr -d ' ')"
  assert_eq "record: written only in air-gap mode" "no" \
    "$( (log() { :; }; AIRGAP_MODE=false; AIRGAP_BUNDLE_DIR="${_nr_dir}/bundle"; LOG_DIR="${_nr_dir}/logs2"; eval "$(_extract_fn write_airgap_install_record)"; write_airgap_install_record started); [[ -f "${_nr_dir}/logs2/airgap-install-record.json" ]] && echo yes || echo no)"
fi
rm -rf "${_nr_dir}"
assert_eq "record: written once the preflight passes and again at the end" "3" \
  "$(_extract_fn main_install | grep -c 'write_airgap_install_record "' | tr -d ' ')"

# ── MPR-193 review fixes (PR #286) ─────────────────────────────────────────────
suite "air-gap review fixes (MPR-193)"

_rf_has() { assert_eq "$1" "yes" "$([[ "$2" == *"$3"* ]] && echo yes || echo no)"; }

# 1. GPU facts from the real SSH payload, run against fake host tools.
_rf_gpu() ( # _rf_gpu <fake bin dir>: the GPU worker's facts as the collector reports them
  local bin="$1"
  eval "$(_extract_fn _node_platform)"; eval "$(_extract_fn _read_model_marker)"
  eval "$(_extract_fn model_artifacts_config_name)"; eval "$(_extract_fn collect_airgap_host_facts)"
  yq() { "${YQ_BIN}" "$@"; }
  ssh_exec() {
    if [[ "$2" == *"uname -m"* ]]; then printf 'x86_64\nrhel\n5.14.0-503.40.1.el9_5.x86_64\n'; return 0; fi
    env -i PATH="${bin}:/usr/bin:/bin" bash -c "$2"
  }
  target_kubectl() { return 1; }   # a fresh install: no cluster yet
  EXISTING_CONTROLLER_IPS=""; EXISTING_WORKER_IPS="10.0.0.3"; CPU_WORKER_COUNT=0; GPU_WORKER_COUNT=1
  OBJ_STORE_TYPE=""; DEFAULT_ACCELERATOR="l40s"
  local out; out="$(mktemp)"
  collect_airgap_host_facts "${out}" cpuOnly >/dev/null 2>&1
  jq -r '.nodes[0].gpu | "\(.devices)|\(.driver)|\(.runtime)"' "${out}"; rm -f "${out}"
)
if [[ -n "${YQ_BIN}" ]] && command -v jq >/dev/null 2>&1; then
  _rf_bin="$(mktemp -d)"
  printf '#!/bin/sh\necho "01:00.0 3D controller [0302]: NVIDIA Corporation GA102 [10de:2236]"\necho "02:00.0 3D controller [0302]: NVIDIA Corporation GA102 [10de:2236]"\n' > "${_rf_bin}/lspci"
  chmod +x "${_rf_bin}/lspci"
  assert_eq "GPU facts: a fresh host without nvidia-smi or the toolkit has no driver and no runtime" "2||false" "$(_rf_gpu "${_rf_bin}")"
  printf '#!/bin/sh\necho "NVIDIA-SMI has failed because it couldn'"'"'t communicate with the NVIDIA driver."\nexit 9\n' > "${_rf_bin}/nvidia-smi"
  chmod +x "${_rf_bin}/nvidia-smi"
  assert_eq "GPU facts: a failing nvidia-smi is no driver, not its error text" "2||false" "$(_rf_gpu "${_rf_bin}")"
  printf '#!/bin/sh\ncase "$1" in -L) echo "GPU 0: NVIDIA L40S (UUID: GPU-a)"; echo "GPU 1: NVIDIA L40S (UUID: GPU-b)";; *) echo "550.54.15";; esac\n' > "${_rf_bin}/nvidia-smi"
  printf '#!/bin/sh\nexit 0\n' > "${_rf_bin}/nvidia-ctk"; chmod +x "${_rf_bin}/nvidia-smi" "${_rf_bin}/nvidia-ctk"
  assert_eq "GPU facts: a provisioned host reports its driver and toolkit" "2|550.54.15|true" "$(_rf_gpu "${_rf_bin}")"
  rm -rf "${_rf_bin}"
fi

# 3. The default ServiceAccount (the Splunk Standalone pod's) gets every pull Secret present.
_rf_sa() ( # prints the patch kubectl was given
  log() { :; }; warn() { echo "WARN: $*"; }
  yq() { "${YQ_BIN}" "$@"; }
  local cfg; cfg="$(mktemp)"; printf 'images:\n  imagePullSecrets:\n    - name: mirror-pull\n' > "${cfg}"; CONFIG_FILE="${cfg}"
  kubectl() {
    case "$*" in
      "get secret "*) [[ " ${_RF_PRESENT} " == *" $3 "* ]]; return $? ;;
      "get serviceaccount default "*) echo "${_RF_SA:-{\}}"; return 0 ;;
      "patch serviceaccount default "*) echo "PATCH ${*: -1}" >> "${_RF_PATCHES}"; return 0 ;;
    esac
  }
  for f in configured_pull_secret_names image_pull_secret_names patch_default_sa_pull_secrets; do eval "$(_extract_fn "${f}")"; done
  _RF_PATCHES="$(mktemp)"
  patch_default_sa_pull_secrets ai-platform
  cat "${_RF_PATCHES}"
  rm -f "${cfg}" "${_RF_PATCHES}"
)
if [[ -n "${YQ_BIN}" ]] && command -v jq >/dev/null 2>&1; then
  assert_eq "Standalone SA: the configured Secret is attached along with the installer-created ones" \
    'PATCH {"imagePullSecrets": [{"name":"ecr-registry-secret"},{"name":"mirror-pull"}]}' "$(_RF_PRESENT="ecr-registry-secret mirror-pull" _rf_sa)"
  assert_eq "Standalone SA: a configured Secret alone is attached" \
    'PATCH {"imagePullSecrets": [{"name":"mirror-pull"}]}' "$(_RF_PRESENT="mirror-pull" _rf_sa)"
  assert_eq "Standalone SA: nothing present, nothing patched" "" "$(_RF_PRESENT="" _rf_sa)"
  assert_eq "Standalone SA: entries the ServiceAccount already has are kept" \
    'PATCH {"imagePullSecrets": [{"name":"site-registry"},{"name":"mirror-pull"}]}' \
    "$(_RF_PRESENT="mirror-pull" _RF_SA='{"imagePullSecrets":[{"name":"site-registry"}]}' _rf_sa)"
fi
assert_eq "Standalone SA: install_splunk_standalone uses the helper, not a hard-coded Secret" "1" \
  "$(_extract_fn install_splunk_standalone | grep -c 'patch_default_sa_pull_secrets "${AI_NS}"' | tr -d ' ')"
assert_eq "Standalone SA: no hard-coded ecr-registry-secret patch remains" "0" \
  "$(grep -c "imagePullSecrets\": \[{\"name\": \"ecr-registry-secret\"}\]" "${SCRIPT}" | tr -d ' ')"

# 4. Name-only Secret references are checked in preflight, before any change.
_rf_refs() ( # _rf_refs <config body>: the problems validate_pull_secret_refs reports
  local cfg; cfg="$(mktemp)"; printf '%s' "$1" > "${cfg}"; CONFIG_FILE="${cfg}"
  yq() { "${YQ_BIN}" "$@"; }
  AI_NS=ai-platform
  component_enabled() { [[ " ${_RF_COMPONENTS:-ai-operator} " == *" $1 "* ]]; }
  # The target cluster (see resolve_target_cluster), read as the install will read it.
  target_kubectl() {
    case "$*" in
      "get namespaces") [[ "${_RF_CLUSTER:-yes}" == yes ]]; return $? ;;
      "get secret "*" -o jsonpath={.type}") echo "${_RF_TYPE:-kubernetes.io/dockerconfigjson}"; return 0 ;;
      "get secret "*) [[ " ${_RF_HAVE:-} " == *" $5/$3 "* ]]; return $? ;;
    esac
  }
  for f in _pull_secret_file pull_secret_namespaces validate_pull_secret_refs; do eval "$(_extract_fn "${f}")"; done
  validate_pull_secret_refs
  rm -f "${cfg}"
)
if [[ -n "${YQ_BIN}" ]]; then
  _ref=$'images:\n  imagePullSecrets:\n    - name: mirror-pull\n'
  _rf_has "refs: on a fresh install a name-only reference fails in preflight" "$(_RF_CLUSTER=no _rf_refs "${_ref}")" "has no dockerConfigFile, and no cluster exists yet for this install"
  _out="$(_RF_HAVE="ai-platform/mirror-pull" _rf_refs "${_ref}")"
  _rf_has "refs: a Secret missing in one namespace that uses it is named" "${_out}" "Secret splunk-ai-operator-system/mirror-pull does not exist"
  assert_eq "refs: and only that namespace" "1" "$(grep -c . <<< "${_out}" | tr -d ' ')"
  assert_eq "refs: present everywhere with the right type is fine" "" "$(_RF_HAVE="ai-platform/mirror-pull splunk-ai-operator-system/mirror-pull" _rf_refs "${_ref}")"
  _rf_has "refs: a Secret of another type fails in preflight" \
    "$(_RF_HAVE="ai-platform/mirror-pull splunk-ai-operator-system/mirror-pull" _RF_TYPE=Opaque _rf_refs "${_ref}")" "is of type 'Opaque'"
  _rf_has "refs: the Splunk Operator namespace counts when it is installed" \
    "$(_RF_COMPONENTS="ai-operator splunk-operator" _RF_HAVE="ai-platform/mirror-pull splunk-ai-operator-system/mirror-pull" _rf_refs "${_ref}")" "Secret splunk-operator/mirror-pull does not exist"
  assert_eq "refs: a reference with a dockerConfigFile is created during install, not checked here" "" \
    "$(_RF_CLUSTER=no _rf_refs $'images:\n  imagePullSecrets:\n    - name: mirror-pull\n      dockerConfigFile: /tmp/x.json\n')"
fi
assert_eq "refs: the preflight reports them with the setting's own problems" "1" \
  "$(_extract_fn preflight_checks | grep -c 'validate_pull_secret_config; validate_pull_secret_refs' | tr -d ' ')"

suite "air-gap review fixes, round 2 (MPR-193)"

# Shared fakes. A remote controller whose `sudo k0s kubectl` is _r2_remote_kubectl: the SSH
# command is re-parsed by a shell, as the controller's would, so quoting is exercised too.
_r2_fakes() {
  yq() { "${YQ_BIN}" "$@"; }
  timeout() { shift; "$@"; }
  ssh_exec() {
    local host="$1" cmd="$2"
    echo "${host}: ${cmd}" >> "${_R2_SSH_LOG:-/dev/null}"
    case "${cmd}" in
      *"sudo k0s status"*) [[ "${_R2_K0S:-no}" == yes && "${host}" == "${_R2_K0S_HOST:-10.0.0.1}" ]]; return $? ;;
      "sudo k0s kubectl "*) eval "_r2_remote_kubectl ${cmd#sudo k0s kubectl }"; return $? ;;
    esac
    return 1
  }
  # The target cluster as either route sees it: namespaces, Secrets (ns/name=type[:data]) and nodes.
  _r2_remote_kubectl() {
    case "$1 $2" in
      "get namespaces") return 0 ;;
      "get nodes") echo '{"items":[{"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.3"}],"allocatable":{"nvidia.com/gpu":"2"}}}]}'; return 0 ;;
      "get secret")
        local name="$3" ns="$5" e
        for e in ${_R2_SECRETS:-}; do
          if [[ "${e%%=*}" == "${ns}/${name}" ]]; then
            local v="${e#*=}" type data
            type="${v%%:*}"; data=""; [[ "${v}" == *:* ]] && data="${v#*:}"
            case "${*:6}" in
              "-o jsonpath={.type}") echo "${type}" ;;
              "-o json") jq -n --arg t "${type}" --arg d "${data}" '{type: $t, data: (if $d == "" then {} else {".dockerconfigjson": $d} end)}' ;;
            esac
            return 0
          fi
        done
        return 1 ;;
    esac
    return 1
  }
  # The installer host's own kubectl: its kubeconfig reaches _R2_LOCAL (target, other, or none).
  kubectl() {
    case "$*" in
      "cluster-info") [[ "${_R2_LOCAL:-none}" != none ]]; return $? ;;
      "config current-context") echo "${_R2_CONTEXT:-k0s-ai-tier}"; return 0 ;;
    esac
    # An unrelated cluster ("other") answers as readily as the target would.
    [[ "${_R2_LOCAL:-none}" != none ]] || return 1
    _r2_remote_kubectl "$@"
  }
  USE_EXISTING="${_R2_USE_EXISTING:-auto}"; CLUSTER_NAME=ai-tier
  EXISTING_CONTROLLER_IPS="${_R2_CTRL-10.0.0.1}"; EXISTING_WORKER_IPS="10.0.0.2 10.0.0.3"
  [[ "${_R2_LOCAL:-none}" == none ]] && unset KUBECONFIG || KUBECONFIG=/tmp/fake-kubeconfig
  AI_NS=ai-platform; TARGET_CLUSTER_ACCESS=""; TARGET_CLUSTER_CONTROLLER=""
  component_enabled() { [[ " ${_R2_COMPONENTS:-ai-operator} " == *" $1 "* ]]; }
  local f
  for f in resolve_target_cluster target_kubectl _pull_secret_file pull_secret_namespaces validate_pull_secret_refs \
           pull_secret_docker_config docker_config_registry_auth airgap_registry_config_dir; do
    eval "$(_extract_fn "${f}" 2>/dev/null)"
  done
}

# B. The target cluster is the one main_install will use, resolved read-only before it.
_r2_resolve() ( _r2_fakes; resolve_target_cluster >/dev/null 2>&1; echo "${TARGET_CLUSTER_ACCESS}${TARGET_CLUSTER_CONTROLLER:+@${TARGET_CLUSTER_CONTROLLER}}" )
if [[ -n "${YQ_BIN}" ]] && command -v jq >/dev/null 2>&1; then
  assert_eq "target: an existing cluster reached over SSH (no local kubeconfig) is read on its controller" "ssh@10.0.0.1" "$(_R2_K0S=yes _r2_resolve)"
  assert_eq "target: KUBECONFIG naming the cluster is used, as main_install uses it" "local" "$(_R2_LOCAL=target _R2_K0S=yes _r2_resolve)"
  assert_eq "target: a KUBECONFIG for another context is not the target; the controller is" "ssh@10.0.0.1" "$(_R2_LOCAL=other _R2_CONTEXT=prod-east _R2_K0S=yes _r2_resolve)"
  assert_eq "target: useExisting force takes KUBECONFIG whatever its context" "local" "$(_R2_LOCAL=other _R2_CONTEXT=prod-east _R2_USE_EXISTING=force _r2_resolve)"
  assert_eq "target: useExisting never ignores KUBECONFIG, but k0s on the controller is still reused" "ssh@10.0.0.1" "$(_R2_LOCAL=target _R2_USE_EXISTING=never _R2_K0S=yes _r2_resolve)"
  assert_eq "target: a fresh install has no cluster" "none" "$(_r2_resolve)"
  assert_eq "target: and neither has an install whose ambient kubeconfig is some other cluster" "none" "$(_R2_LOCAL=other _R2_CONTEXT=prod-east _r2_resolve)"
  assert_eq "target: no controllers configured, no cluster" "none" "$(_R2_CTRL="" _R2_K0S=yes _r2_resolve)"

  _r2_tk() ( _r2_fakes; local log; log="$(mktemp)"; _R2_SSH_LOG="${log}"; target_kubectl "$@" >/dev/null 2>&1; echo "rc=$?"; grep 'k0s kubectl' "${log}"; rm -f "${log}" )
  _out="$(_R2_K0S=yes _R2_SECRETS="ai-platform/mirror-pull=kubernetes.io/dockerconfigjson" _r2_tk get secret mirror-pull -n ai-platform -o 'jsonpath={.type}')"
  _rf_has "target: over SSH it runs k0s kubectl on the first controller" "${_out}" "10.0.0.1: sudo k0s kubectl get secret mirror-pull -n ai-platform -o jsonpath=\\{.type\\}"
  _rf_has "target: and the arguments survive the remote shell" "${_out}" "rc=0"
  assert_eq "target: it only reads (a write verb is refused)" "rc=2" "$(_R2_K0S=yes _r2_tk delete secret mirror-pull -n ai-platform | head -1)"
  assert_eq "target: and nothing is sent for it" "1" "$(_R2_K0S=yes _r2_tk delete secret mirror-pull -n ai-platform | grep -c . | tr -d ' ')"
  assert_eq "target: with no cluster it fails without contacting one" "rc=1" "$(_r2_tk get namespaces)"

  _r2_refs() ( _r2_fakes; local cfg; cfg="$(mktemp)"; printf '%s' "$1" > "${cfg}"; CONFIG_FILE="${cfg}"; validate_pull_secret_refs; rm -f "${cfg}" )
  _ref=$'images:\n  imagePullSecrets:\n    - name: mirror-pull\n'
  _both="ai-platform/mirror-pull=kubernetes.io/dockerconfigjson splunk-ai-operator-system/mirror-pull=kubernetes.io/dockerconfigjson"
  assert_eq "refs: Secrets present on an SSH-discovered existing cluster satisfy name-only references" "" \
    "$(_R2_K0S=yes _R2_SECRETS="${_both}" _r2_refs "${_ref}")"
  _rf_has "refs: and one missing there is still named" "$(_R2_K0S=yes _R2_SECRETS="ai-platform/mirror-pull=kubernetes.io/dockerconfigjson" _r2_refs "${_ref}")" \
    "Secret splunk-ai-operator-system/mirror-pull does not exist"
  _rf_has "refs: as is one of the wrong type" "$(_R2_K0S=yes _R2_SECRETS="ai-platform/mirror-pull=Opaque splunk-ai-operator-system/mirror-pull=kubernetes.io/dockerconfigjson" _r2_refs "${_ref}")" \
    "is of type 'Opaque'"
  _rf_has "refs: an unrelated cluster in the ambient kubeconfig is not consulted" "$(_R2_LOCAL=other _R2_CONTEXT=prod-east _R2_SECRETS="${_both}" _r2_refs "${_ref}")" \
    "has no dockerConfigFile, and no cluster exists yet"
  assert_eq "refs: KUBECONFIG naming the target is read directly" "" "$(_R2_LOCAL=target _R2_SECRETS="${_both}" _r2_refs "${_ref}")"

  _r2_alloc() (
    _r2_fakes
    eval "$(_extract_fn _node_platform)"; eval "$(_extract_fn _read_model_marker)"
    eval "$(_extract_fn model_artifacts_config_name)"; eval "$(_extract_fn collect_airgap_host_facts)"
    ssh_exec_orig="$(declare -f ssh_exec)"
    eval "${ssh_exec_orig/ssh_exec/_r2_ssh}"
    ssh_exec() {
      if [[ "$2" == *"uname -m"* ]]; then printf 'x86_64\nrhel\n5.14.0\n'; return 0; fi
      if [[ "$2" == *lspci* ]]; then printf '2\n550.54.15\ntrue\n'; return 0; fi
      _r2_ssh "$@"
    }
    CPU_WORKER_COUNT=1; GPU_WORKER_COUNT=1; OBJ_STORE_TYPE=""; DEFAULT_ACCELERATOR="l40s"
    local out; out="$(mktemp)"; collect_airgap_host_facts "${out}" cpuOnly >/dev/null 2>&1
    jq -r '.nodes[2].gpu.allocatable // "none"' "${out}"; rm -f "${out}"
  )
  assert_eq "facts: schedulable GPUs of an SSH-discovered existing cluster come from its controller" "2" "$(_R2_K0S=yes _r2_alloc)"
  assert_eq "facts: none claimed on a fresh install" "none" "$(_r2_alloc)"
  assert_eq "facts: nor from an unrelated cluster in the ambient kubeconfig" "none" "$(_R2_LOCAL=other _R2_CONTEXT=prod-east _r2_alloc)"
fi
assert_eq "target: the preflight resolves it once, before the first check that reads it" "yes" \
  "$(_extract_fn preflight_checks | awk '/^  resolve_target_cluster$/{a=NR} /^  preflight_check_registry$/{b=NR} END{print (a && b && a<b) ? "yes" : "no"}')"
if [[ -n "${YQ_BIN}" ]] && command -v jq >/dev/null 2>&1; then
  _r2_once() ( _r2_fakes; local log; log="$(mktemp)"; _R2_SSH_LOG="${log}"; resolve_target_cluster
    local i; for i in 1 2 3; do _x="$(target_kubectl get namespaces)"; done
    grep -c 'k0s status' "${log}" | tr -d ' '; rm -f "${log}" )
  assert_eq "target: once resolved, later reads (in subshells) do not probe the controller again" "1" "$(_R2_K0S=yes _r2_once)"
fi
assert_eq "target: validate_pull_secret_refs reads only through target_kubectl" "0" \
  "$(_extract_fn validate_pull_secret_refs | grep -vE '^\s*#' | grep -cE '(^|[^_])kubectl ' | tr -d ' ')"
assert_eq "target: and so does the facts collector" "0" \
  "$(_extract_fn collect_airgap_host_facts | grep -vE '^\s*#' | grep -cE '(^|[^_])kubectl ' | tr -d ' ')"

# A. The registry preflight authenticates with the images.imagePullSecrets credentials.
_R2_PASS='s3cr3t-Pa55'
_R2_AUTH="$(printf 'mirror-user:%s' "${_R2_PASS}" | base64 | tr -d '\n')"
_r2_auth() ( _r2_fakes; docker_config_registry_auth "$1" "$2" )
if [[ -n "${YQ_BIN}" ]] && command -v jq >/dev/null 2>&1; then
  _r2_dir="$(mktemp -d)"
  for key in "10.0.39.38:5099" "https://10.0.39.38:5099" "http://10.0.39.38:5099/" "https://10.0.39.38:5099/v2/"; do
    jq -n --arg k "${key}" --arg a "${_R2_AUTH}" '{auths: {($k): {auth: $a}}}' > "${_r2_dir}/c.json"
    assert_eq "auth: a Docker configuration key spelled ${key} matches the registry" "${_R2_AUTH}" "$(_r2_auth "${_r2_dir}/c.json" 10.0.39.38:5099)"
  done
  jq -n --arg p "${_R2_PASS}" '{auths: {"10.0.39.38:5099": {username: "mirror-user", password: $p}}}' > "${_r2_dir}/c.json"
  assert_eq "auth: username and password are used when there is no auth field" "${_R2_AUTH}" "$(_r2_auth "${_r2_dir}/c.json" 10.0.39.38:5099)"
  assert_eq "auth: a registry with a path is matched by its host" "${_R2_AUTH}" "$(_r2_auth "${_r2_dir}/c.json" 10.0.39.38:5099/ai-tier)"
  assert_eq "auth: another registry's credentials are not used" "" "$(_r2_auth "${_r2_dir}/c.json" 10.0.39.38:5100)"
  jq -n --arg a "${_R2_AUTH}" '{auths: {"https://index.docker.io/v1/": {auth: $a}}}' > "${_r2_dir}/c.json"
  assert_eq "auth: Docker Hub's legacy key is docker.io" "${_R2_AUTH}" "$(_r2_auth "${_r2_dir}/c.json" docker.io)"
  rm -rf "${_r2_dir}"

  # A fake registry: /v2/ answers 401; a manifest answers 200 only with the expected Basic credentials.
  _r2_registry() ( # _r2_registry <config body> [dockerConfigFile json]: the preflight's results
    _r2_fakes
    local d; d="$(mktemp -d)"
    printf '%s' "$1" > "${d}/cluster.yaml"; CONFIG_FILE="${d}/cluster.yaml"
    [[ -n "${2:-}" ]] && printf '%s' "$2" > "${d}/mirror-auth.json"
    [[ -n "${_R2_STALE:-}" ]] && printf '%s' "${_R2_STALE}" > "${d}/stale.json"
    pf_header() { :; }; pf_ok() { echo "OK: $*"; }; pf_warn() { echo "WARN: $*"; }; pf_fail() { echo "FAIL: $*"; }
    curl() {
      local a url="${*: -1}" hdr=""
      for a in "$@"; do [[ "${a}" == "Authorization: Basic "* ]] && hdr="${a#Authorization: Basic }"; done
      [[ " $* " == *" -D - "* ]] && return 0
      case "${url}" in
        */v2/) echo 401 ;;
        */manifests/*) [[ "${hdr}" == "${_R2_AUTH}" ]] && echo 200 || echo 401 ;;
        *) echo 000 ;;
      esac
    }
    eval "$(_extract_fn build_image_url)"; eval "$(_extract_fn preflight_check_registry)"
    IMAGE_REGISTRY=10.0.39.38:5099; IMAGE_REGISTRY_INSECURE=true
    SLIM_API_IMAGE="10.0.39.38:5099/ai-tier/ml-platform/slim-api@sha256:$(printf 'a%.0s' {1..64})"
    IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED=false IMAGE_PULL_SECRETS_ACR_ENABLED=false IMAGE_PULL_SECRETS_CUSTOM_ENABLED=false
    preflight_check_registry 2>&1
    rm -rf "${d}"
  )
  _cfg=$'images:\n  imagePullSecrets:\n    - name: mirror-pull\n      dockerConfigFile: mirror-auth.json\n'
  _json="$(jq -n --arg a "${_R2_AUTH}" '{auths: {"10.0.39.38:5099": {auth: $a}}}')"
  _out="$(_r2_registry "${_cfg}" "${_json}")"
  _rf_has "registry: credentials given only as a dockerConfigFile reference authenticate the mirror check" "${_out}" "OK: Registry auth OK"
  assert_eq "registry: and the preflight records no failure" "0" "$(grep -c '^FAIL' <<< "${_out}" | tr -d ' ')"
  assert_eq "registry: the credentials are never printed" "0" "$(grep -cE "${_R2_PASS}|${_R2_AUTH}" <<< "${_out}" | tr -d ' ')"
  _out="$(_R2_K0S=yes _R2_SECRETS="ai-platform/mirror-pull=kubernetes.io/dockerconfigjson:$(printf '%s' "${_json}" | base64 | tr -d '\n')" \
          _r2_registry $'images:\n  imagePullSecrets:\n    - name: mirror-pull\n')"
  _rf_has "registry: a name-only reference's existing Secret authenticates it too (read-only, from the target cluster)" "${_out}" "OK: Registry auth OK"
  assert_eq "registry: still never printed" "0" "$(grep -cE "${_R2_PASS}|${_R2_AUTH}" <<< "${_out}" | tr -d ' ')"
  _out="$(_r2_registry "${_cfg}" "$(jq -n --arg a "$(printf 'mirror-user:wrong' | base64)" '{auths: {"10.0.39.38:5099": {auth: $a}}}')")"
  _rf_has "registry: wrong referenced credentials still fail by name" "${_out}" "FAIL: Registry credentials rejected (HTTP 401)"
  _rf_has "registry: and the message names the setting to fix" "${_out}" "images.imagePullSecrets"
  _out="$(_r2_registry "${_cfg}" "$(jq -n --arg a "${_R2_AUTH}" '{auths: {"other.example.com": {auth: $a}}}')")"
  _rf_has "registry: credentials for another registry do not apply" "${_out}" "FAIL: Registry credentials rejected (HTTP 401)"
  _cfg2=$'images:\n  imagePullSecrets:\n    - name: other-pull\n      dockerConfigFile: other.json\n    - name: mirror-pull\n      dockerConfigFile: mirror-auth.json\n'
  _out="$(_r2_registry "${_cfg2}" "${_json}")"
  _rf_has "registry: the matching reference is found even when it is not the first" "${_out}" "OK: Registry auth OK"

  _out="$(_R2_K0S=yes _R2_SECRETS="ai-platform/mirror-pull=Opaque:$(printf '%s' "${_json}" | base64 | tr -d '\n')" \
          _r2_registry $'images:\n  imagePullSecrets:\n    - name: mirror-pull\n')"
  _rf_has "registry: a Secret that is not kubernetes.io/dockerconfigjson is not used for credentials" "${_out}" "FAIL: Registry credentials rejected (HTTP 401)"
  _cfg3=$'images:\n  imagePullSecrets:\n    - name: mirror-pull\n      dockerConfigFile: mirror-auth.json\n    - name: stale-pull\n      dockerConfigFile: stale.json\n'
  _out="$(_R2_STALE="$(jq -n --arg a "$(printf 'mirror-user:stale' | base64)" '{auths: {"10.0.39.38:5099": {auth: $a}}}')" _r2_registry "${_cfg3}" "${_json}")"
  _rf_has "registry: when two references name the mirror, the first one's credentials are used" "${_out}" "OK: Registry auth OK"
  _cfg4=$'images:\n  imagePullSecrets:\n    - name: stale-pull\n      dockerConfigFile: stale.json\n    - name: mirror-pull\n      dockerConfigFile: mirror-auth.json\n'
  _out="$(_R2_STALE="$(jq -n --arg a "$(printf 'mirror-user:stale' | base64)" '{auths: {"10.0.39.38:5099": {auth: $a}}}')" _r2_registry "${_cfg4}" "${_json}")"
  _rf_has "registry: and that is the order given (a stale first entry is the one tried)" "${_out}" "FAIL: Registry credentials rejected"

  # The bundle check's mirror access uses the same credentials.
  _r2_cfgdir() ( _r2_fakes; local d; d="$(mktemp -d)"; printf '%s' "$1" > "${d}/cluster.yaml"; CONFIG_FILE="${d}/cluster.yaml"
    [[ -n "${2:-}" ]] && printf '%s' "$2" > "${d}/mirror-auth.json"
    local out; out="$(airgap_registry_config_dir)"
    if [[ -n "${out}" ]]; then echo "mode=$(stat -f %Lp "${out}/config.json" 2>/dev/null || stat -c %a "${out}/config.json")"; jq -r --arg h 10.0.39.38:5099 '.auths[$h].auth == env.R2A' "${out}/config.json"; rm -rf "${out}"; else echo none; fi
    rm -rf "${d}" )
  export R2A="${_R2_AUTH}"
  assert_eq "bundle check: a later reference's dockerConfigFile reaches the tool" $'mode=600\ntrue' "$(_r2_cfgdir "${_cfg2}" "${_json}")"
  assert_eq "bundle check: so does a name-only reference's existing Secret" $'mode=600\ntrue' \
    "$(_R2_K0S=yes _R2_SECRETS="ai-platform/mirror-pull=kubernetes.io/dockerconfigjson:$(printf '%s' "${_json}" | base64 | tr -d '\n')" _r2_cfgdir $'images:\n  imagePullSecrets:\n    - name: mirror-pull\n')"
  assert_eq "bundle check: no reference, the host's own configuration" "none" "$(_r2_cfgdir 'images: {}')"
  unset R2A
fi

_exercise_airgap_bundle_helpers() (
  local mode="$1" fixture_dir
  fixture_dir=$(mktemp -d)
  trap 'rm -rf "${fixture_dir}"' EXIT

  : > "${fixture_dir}/addon-images.tar"
  : > "${fixture_dir}/k0s-images.tar"
  printf '%s\n' \
    'quay.io/jetstack/cert-manager-cainjector:v1.13.0' \
    'busybox:latest' \
    > "${fixture_dir}/addon-images.list"
  printf '%s\n' 'quay.io/k0sproject/pause:3.10' > "${fixture_dir}/k0s-images.list"

  eval "$(_extract_fn airgap_k0s_image_bundles_enabled)"
  eval "$(_extract_fn wait_for_k0s_image_bundles)"
  eval "$(_extract_fn verify_airgap_bundle_images_on_node)"

  AIRGAP_K0S_IMAGE_DIR="${fixture_dir}"
  AIRGAP_IMAGE_IMPORT_TIMEOUT=10
  ssh_exec() {
    local args="$*"
    if [[ "${args}" == *'systemctl show'* ]]; then
      echo 4242
    elif [[ "${args}" == *'journalctl'* ]]; then
      if [[ "${mode}" == "import-failure" ]]; then
        echo 'Failed to load OCI bundle /var/lib/k0s/images/addon-images.tar'
      else
        echo 'OCI bundle /var/lib/k0s/images/addon-images.tar loaded'
        echo 'OCI bundle /var/lib/k0s/images/k0s-images.tar loaded'
      fi
    elif [[ "${args}" == *'images list -q'* ]]; then
      echo 'quay.io/k0sproject/pause:3.10'
      echo 'docker.io/library/busybox:latest'
      [[ "${mode}" == "missing-image" ]] || \
        echo 'quay.io/jetstack/cert-manager-cainjector:v1.13.0'
    fi
  }

  case "${mode}" in
    import-success) wait_for_k0s_image_bundles 192.0.2.10 k0sworker 100 ;;
    import-failure) wait_for_k0s_image_bundles 192.0.2.10 k0sworker 100 ;;
    verify-success|missing-image) verify_airgap_bundle_images_on_node 192.0.2.10 ;;
  esac
)

assert_rc "bundle waiter accepts both successful imports from current service PID" 0 \
  _exercise_airgap_bundle_helpers import-success

assert_rc "bundle waiter rejects an explicit importer EOF/failure" 1 \
  _exercise_airgap_bundle_helpers import-failure

assert_rc "image verifier accepts exact and Docker-normalized references" 0 \
  _exercise_airgap_bundle_helpers verify-success

assert_rc "image verifier rejects a partially imported bundle" 1 \
  _exercise_airgap_bundle_helpers missing-image

# ── Codex review fixes ────────────────────────────────────────────────────────
# Tests verifying the five logic bugs fixed in the Codex P1/P2 review pass.

PROVISION="${SCRIPT_DIR}/k0s_aws_provision.sh"

suite "fix: NVIDIA exit-42 capture (k0s_cluster_with_stack.sh)"

assert_eq "ssh_exec result captured via || _nvidia_rc=\$? not if ! ssh_exec" \
  "1" "$(grep -c '|| _nvidia_rc=\$?' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "_nvidia_rc declared local before the ssh_exec call" \
  "1" "$(grep -c 'local _nvidia_rc=0' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "exit-42 branch checks _nvidia_rc not a dead \$? after negation" \
  "1" "$(grep -c '"${_nvidia_rc}" -eq 42' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "no remaining if ! ssh_exec for the Phase B NVIDIA install block (code, not comment)" \
  "0" "$(grep -A5 'Phase B: install driver' "${SCRIPT}" | grep 'if ! ssh_exec' | grep -cv '^\s*#' | tr -d '[:space:]')"

suite "fix: idempotent NVIDIA runtime setup (k0s_cluster_with_stack.sh)"

NVIDIA_HEALTH_FN="$(_extract_fn _nvidia_runtime_is_healthy)"
NVIDIA_INSTALL_FN="$(_extract_fn _install_nvidia_on_node)"

assert_eq "health check validates runtime config, resolvable indexed CDI devices, and k0sworker" \
  "6" "$(printf '%s\n' "${NVIDIA_HEALTH_FN}" | grep -Ec 'default_runtime_name|nvidia-ctk cdi list|query-gpu=index|systemctl is-active.*k0sworker')"

assert_eq "health check does not assume generated CDI specs contain physical GPU UUIDs" \
  "0" "$(printf '%s\n' "${NVIDIA_HEALTH_FN}" | grep -c 'query-gpu=uuid' | tr -d '[:space:]')"

assert_eq "healthy runtime skips reconfiguration and worker restart" \
  "2" "$(printf '%s\n' "${NVIDIA_INSTALL_FN}" | grep -Ec '_nvidia_runtime_is_healthy|skipping reconfiguration and k0sworker restart')"

assert_eq "runtime repair does not kill container shims or remove the containerd socket" \
  "0" "$(printf '%s\n' "${NVIDIA_INSTALL_FN}" | grep -Ec 'pkill.*containerd-shim|rm -f /run/k0s/containerd\\.sock')"

assert_eq "unhealthy runtime uses a checked k0sworker restart" \
  "3" "$(printf '%s\n' "${NVIDIA_INSTALL_FN}" | grep -Ec 'systemctl restart k0sworker|systemctl is-active --quiet k0sworker')"

suite "fix: LAST_LAUNCHED_SUBNET subshell (k0s_aws_provision.sh)"

assert_eq "launch_instance_az_fallback NOT called inside \$() for GPU launch" \
  "0" "$(grep 'id=\$(launch_instance_az_fallback' "${PROVISION}" | grep -c 'gpu-worker' | tr -d '[:space:]')"

assert_eq "GPU instance ID captured via tempfile pattern" \
  "1" "$(grep -c '_id_file.*mktemp' "${PROVISION}" | tr -d '[:space:]')"

assert_eq "LAST_LAUNCHED_SUBNET reset before each GPU launch" \
  "1" "$(grep -c 'LAST_LAUNCHED_SUBNET=""' "${PROVISION}" | tr -d '[:space:]')"

suite "fix: ECR hosts.toml correct k0s path (k0s_aws_provision.sh)"

assert_eq "hosts.toml written to /etc/k0s/containerd/certs.d not /etc/containerd/certs.d (code, not comment)" \
  "0" "$(grep 'etc/containerd/certs\.d' "${PROVISION}" | grep -cv '^\s*#' | tr -d '[:space:]')"

assert_eq "config_path drop-in written under /etc/k0s/containerd.d/" \
  "1" "$(grep -c 'etc/k0s/containerd\.d/ecr-registry-config-path\.toml' "${PROVISION}" | tr -d '[:space:]')"

assert_eq "config_path points at /etc/k0s/containerd/certs.d" \
  "1" "$(grep -c 'config_path.*=.*\"/etc/k0s/containerd/certs\.d\"' "${PROVISION}" | tr -d '[:space:]')"

suite "fix: /data/minio ownership (k0s_aws_provision.sh)"

assert_eq "sudo mkdir used for /data/minio/model_artifacts" \
  "1" "$(grep -c 'sudo mkdir -p /data/minio/model_artifacts' "${PROVISION}" | tr -d '[:space:]')"

assert_eq "chown ec2-user applied to /data/minio after mkdir" \
  "1" "$(grep -c 'sudo chown -R ec2-user:ec2-user /data/minio' "${PROVISION}" | tr -d '[:space:]')"

suite "fix: modify-vpc-attribute boolean values (k0s_aws_provision.sh)"

assert_eq "enable-dns-support passes {\"Value\":true}" \
  "1" "$(grep 'enable-dns-support' "${PROVISION}" | grep -c '{"Value":true}' | tr -d '[:space:]')"

assert_eq "enable-dns-hostnames passes {\"Value\":true}" \
  "1" "$(grep 'enable-dns-hostnames' "${PROVISION}" | grep -c '{"Value":true}' | tr -d '[:space:]')"

suite "fix: no real credentials in prod config (k0s-aws-provision-config-prod.yaml)"

PROD_CFG="${SCRIPT_DIR}/k0s-aws-provision-config-prod.yaml"

assert_eq "seaweedfs endpoint is empty (no real IP)" \
  "1" "$(grep -c '^  endpoint: ""' "${PROD_CFG}" | tr -d '[:space:]')"

assert_eq "seaweedfs rootUser is empty (no default credential)" \
  "1" "$(grep -c '^  rootUser: ""' "${PROD_CFG}" | tr -d '[:space:]')"

assert_eq "seaweedfs rootPassword is empty (no default credential)" \
  "1" "$(grep -c '^  rootPassword: ""' "${PROD_CFG}" | tr -d '[:space:]')"

assert_eq "minioadmin not present in prod config" \
  "0" "$(grep -c 'minioadmin' "${PROD_CFG}" | tr -d '[:space:]')"

suite "fix: clean-all reset and kubeconfig cleanup"

DELETE_FN="$(_extract_fn main_delete)"
CLEAN_ALL_FN="$(_extract_fn clean_all)"

assert_eq "k0s reset does not use the unsupported --force flag" \
  "0" "$(grep -c 'k0s reset --force' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "kubeconfig counter avoids post-increment under set -e" \
  "0" "$(grep -c '((kubeconfig_count++))' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "clean-all delegates configuration loading to main_delete" \
  "0" "$(printf '%s\n' "${CLEAN_ALL_FN}" | grep -c 'load_config' | tr -d '[:space:]')"

assert_eq "aggressive cleanup quietly handles leftover k0s services" \
  "2" "$(printf '%s\n' "${CLEAN_ALL_FN}" | grep -Ec 'systemctl (stop|disable) k0s.*>/dev/null 2>&1 \|\| true' | tr -d '[:space:]')"

assert_eq "mounted k0s data volume is emptied without removing its mount point" \
  "2" "$(printf '%s\n' "${CLEAN_ALL_FN}" | grep -Ec 'mountpoint -q /var/lib/k0s|find /var/lib/k0s -mindepth 1' | tr -d '[:space:]')"

assert_eq "aggressive cleanup does not stop after the first failed step" \
  "0" "$(printf '%s\n' "${CLEAN_ALL_FN}" | grep -c 'set -e' | tr -d '[:space:]')"

assert_eq "aggressive cleanup returns its accumulated failure status" \
  "1" "$(printf '%s\n' "${CLEAN_ALL_FN}" | grep -c 'exit \\${cleanup_failed}' | tr -d '[:space:]')"

assert_eq "aggressive cleanup skips iptables when the binary is absent" \
  "1" "$(printf '%s\n' "${CLEAN_ALL_FN}" | grep -c 'if command -v iptables >/dev/null 2>&1' | tr -d '[:space:]')"

assert_eq "node cleanup reports separate reset and aggressive results" \
  "2" "$(printf '%s\n%s\n' "${DELETE_FN}" "${CLEAN_ALL_FN}" | grep -Ec 'reset results:|Aggressive cleanup results:' | tr -d '[:space:]')"

assert_eq "main delete exposes reset failures to clean-all" \
  "1" "$(printf '%s\n' "${DELETE_FN}" | grep -c 'K0S_RESET_FAILED="${reset_failed}"' | tr -d '[:space:]')"

_clean_all_propagates_reset_failure() (
  eval "${CLEAN_ALL_FN}"
  log() { :; }
  warn() { :; }
  main_delete() {
    EXISTING_CONTROLLER_IPS="10.0.0.1"
    EXISTING_WORKER_IPS="10.0.0.2"
    K0S_RESET_FAILED=1
  }
  ssh_exec() { return 0; }
  clean_all
)

assert_rc "clean-all returns failure when the k0s reset phase failed" \
  "1" _clean_all_propagates_reset_failure

_clean_all_propagates_aggressive_failure() (
  eval "${CLEAN_ALL_FN}"
  log() { :; }
  warn() { :; }
  main_delete() {
    EXISTING_CONTROLLER_IPS="10.0.0.1"
    EXISTING_WORKER_IPS="10.0.0.2"
    K0S_RESET_FAILED=0
  }
  ssh_exec() { return 1; }
  clean_all
)

assert_rc "clean-all returns failure when aggressive node cleanup failed" \
  "1" _clean_all_propagates_aggressive_failure

# ── Tests: RHEL 9 air-gap NVIDIA module stream ───────────────────────────────
# NVIDIA's RHEL 9 repository defaults to open-dkms, so the established
# kmod-nvidia-latest-dkms package is hidden by modular filtering until its stream
# is selected. RHEL 10 has no DNF modularity, and Ubuntu uses apt; neither path
# may run a RHEL 9 module command.

suite "RHEL 9 air-gap NVIDIA module stream"
echo "▶ RHEL 9 air-gap NVIDIA module stream"

_simulate_airgap_nvidia_stream() (
  local target_os="$1" initially_visible="$2"
  local trace_file
  trace_file=$(mktemp /tmp/airgap-nvidia-stream.XXXXXX)
  trap 'rm -f "${trace_file}"' EXIT

  eval "$(_extract_airgap_fn _rhel9_nvidia_driver_rpm_visible)"
  eval "$(_extract_airgap_fn ensure_rhel9_nvidia_driver_stream)"

  GPU_NODE_OS="${target_os}"
  _test_nvidia_rpm_visible="${initially_visible}"
  log() { :; }
  err() { printf 'err %s\n' "$*" >>"${trace_file}"; return 1; }
  sudo() {
    printf '%s\n' "$*" >>"${trace_file}"
    if [[ "$*" == *"repoquery"* ]]; then
      [[ "${_test_nvidia_rpm_visible}" == "true" ]] \
        && printf '%s\n' 'kmod-nvidia-latest-dkms'
      return 0
    fi
    if [[ "$*" == *"module enable nvidia-driver:latest-dkms"* ]]; then
      _test_nvidia_rpm_visible="true"
    fi
    return 0
  }

  ensure_rhel9_nvidia_driver_stream || true
  cat "${trace_file}"
)

_rhel9_hidden_trace="$(_simulate_airgap_nvidia_stream rhel9 false)"
assert_eq "RHEL 9 checks package visibility before and after stream selection" \
  "2" "$(grep -c 'repoquery.*kmod-nvidia-latest-dkms' <<<"${_rhel9_hidden_trace}" | tr -d '[:space:]')"
assert_eq "RHEL 9 resets a conflicting/default NVIDIA stream" \
  "1" "$(grep -c 'module reset nvidia-driver' <<<"${_rhel9_hidden_trace}" | tr -d '[:space:]')"
assert_eq "RHEL 9 enables latest-dkms when its RPM is hidden" \
  "1" "$(grep -c 'module enable nvidia-driver:latest-dkms' <<<"${_rhel9_hidden_trace}" | tr -d '[:space:]')"

_rhel9_visible_trace="$(_simulate_airgap_nvidia_stream rhel9 true)"
assert_eq "RHEL 9 preserves an already-selected compatible stream" \
  "0" "$(grep -c 'module reset\|module enable' <<<"${_rhel9_visible_trace}" | tr -d '[:space:]')"

_rhel10_trace="$(_simulate_airgap_nvidia_stream rhel10 false)"
assert_eq "RHEL 10 never runs RHEL 9 module commands" "" "${_rhel10_trace}"

_ubuntu24_trace="$(_simulate_airgap_nvidia_stream ubuntu24 false)"
assert_eq "Ubuntu 24.04 never runs RHEL 9 module commands" "" "${_ubuntu24_trace}"

assert_eq "the non-air-gap installer does not call the air-gap stream helper" \
  "0" "$(grep -c 'ensure_rhel9_nvidia_driver_stream' "${SCRIPT}" | tr -d '[:space:]')"

# ── Tests: Blackwell NVIDIA open-module switch ───────────────────────────────
# A package change alone does not replace a proprietary NVIDIA module already
# loaded in the running kernel. Verify the installer selects the RHEL 9 open
# stream and explicitly replaces/validates the resident module on reruns.

suite "Blackwell NVIDIA open-module switch"

assert_eq "RHEL 9 enables the open-dkms module stream" \
  "1" "$(grep -c 'module enable nvidia-driver:open-dkms' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "does not directly install the open-dkms stream" \
  "0" "$(grep -c 'dnf module install -y nvidia-driver:open-dkms' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "marks Blackwell as requiring the open module" \
  "1" "$(grep -c 'REQUIRE_OPEN_MODULE=1' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "refreshes module metadata before checking the installed license" \
  "1" "$(awk '/depmod -a.*KREL/{depmod=NR} /ON_DISK_LICENSE=.*modinfo/{license=NR; exit} END{print(depmod > 0 && depmod < license)}' "${SCRIPT}")"

assert_eq "stops k0sworker before replacing a loaded GPU module" \
  "1" "$(awk '/Replacing the currently loaded NVIDIA module/{found=1} found && /systemctl stop k0sworker/{count++} found && /sudo modprobe nvidia \|\|/{print count; exit}' "${SCRIPT}")"

assert_eq "unloads the NVIDIA dependency stack in order" \
  "1" "$(grep -c 'for _mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "removes each loaded NVIDIA module" \
  "1" "$(grep -c 'modprobe -r.*_mod' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "validates the running open-module banner after modprobe" \
  "1" "$(grep -c 'cat /proc/driver/nvidia/version' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "does not rely on the optional sysfs module-license file" \
  "0" "$(grep -c 'cat /sys/module/nvidia/license' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "gives a reboot-and-rerun recovery when the old module is busy" \
  "1" "$(grep -c 'Reboot this GPU node once, then re-run the same install command' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "DKMS version parsing cannot abort its fallback under pipefail" \
  "2" "$(grep -c '_nv_ver=.*head -1 || true' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "recovers DKMS entries stuck in added state (reused from ai-tier-ga)" \
  "1" "$(grep -c 'DKMS_OUT.*grep -qE.*added' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "rechecks DKMS after the explicit added-state build" \
  "1" "$(grep -c 'DKMS (after explicit build)' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "recognizes the Blackwell GSP WPR2 reset signature" \
  "1" "$(grep -c 'grep -qiE.*unexpected WPR2 already up' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "allows only one automatic NVIDIA recovery reboot" \
  "1" "$(grep -c 'recovery_reboots < 1' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "waits for the node to return after the recovery reboot" \
  "1" "$(grep -c 'did not return after the NVIDIA recovery reboot' "${SCRIPT}" | tr -d '[:space:]')"

# ── Tests: AIP-4614 native-HTTPS internal Splunk ──────────────────────
# Execute the production installer functions with kubectl/yq mocked and inspect
# the YAML they actually render. The internal issuer follows main's short
# namespace-local HTTPS Service URL, while HEC remains a distinct OTel endpoint.

suite "AIP-4614 native-HTTPS internal Splunk"
echo "▶ AIP-4614 native-HTTPS internal Splunk"

_render_internal_splunk_https_manifests() (
  local capture_dir="$1"
  # This fixture contains no AgentRuntime feature or checkpoint credentials.
  create_agentruntime_checkpoint_secrets() { :; }
  eval "$(_extract_fn internal_splunk_management_url)"
  eval "$(_extract_fn internal_splunk_pod_name)"
  eval "$(_extract_fn _internal_splunk_btool_http_value)"
  eval "$(_extract_fn _detect_internal_splunk_hec_url)"
  eval "$(_extract_fn _read_internal_splunk_state)"
  eval "$(_extract_fn _apply_internal_splunk_standalone_cr)"
  eval "$(_extract_fn install_splunk_standalone)"
  eval "$(_extract_fn render_slim_route_config)"
  eval "$(_extract_fn install_ai_platform_cr)"

  log() { :; }
  warn() { :; }
  err() { echo "ERROR: $*" >&2; exit 1; }
  ensure_namespace() { :; }
  wait_for_crd() { :; }
  _wait_for_splunk_telemetry_bootstrap() { :; }
  _wait_for_internal_splunk_https() { :; }
  object_store_auth_looks_like_placeholder() { return 0; }
  sleep() { :; }

  yq() {
    case "$*" in
      *'.splunk.trustedIssuers | length'*|*'.aiPlatform.features | length'*) echo 0 ;;
      *) echo '' ;;
    esac
  }

  kubectl() {
    local args=" $* " body
    if [[ "${args}" == *' btool inputs list http '* ]]; then
      cat <<'EOF'
[http]
disabled = 0
enableSSL = 0
port = 8088
EOF
      return 0
    fi
    if [[ "${args}" == *'/services/collector/health'* ]]; then
      return 0
    fi
    if [[ "${args}" == *' get standalone '* && "${args}" == *' -o json '* ]]; then
      echo '{"status":{"telAppInstalled":true,"phase":"Ready","message":""},"spec":{"extraEnv":[{"name":"KEEP_ME","value":"kept"}]}}'
      return 0
    fi
    if [[ "${args}" == *' get pods '* && "${args}" == *' -o json '* ]]; then
      echo '{"items":[]}'
      return 0
    fi
    if [[ "${args}" == *' get secret minio-credentials '* ]]; then
      return 0
    fi
    if [[ "${args}" == *' get secret '* ]]; then
      return 1
    fi
    if [[ "${args}" == *' get aiplatform '* ]]; then
      return 0
    fi
    if [[ "${args}" == *' apply '* && "${args}" == *' -f - '* ]]; then
      body="$(cat)"
      printf '%s\n---\n' "${body}" >>"${capture_dir}/all-applies.yaml"
      case "${body}" in
        *'kind: ConfigMap'*'name: splunk-defaults'*)
          printf '%s\n' "${body}" >"${capture_dir}/splunk-defaults.yaml"
          ;;
        *'kind: Standalone'*)
          printf '%s\n' "${body}" >"${capture_dir}/standalone.yaml"
          ;;
        *'kind: AIPlatform'*)
          printf '%s\n' "${body}" >"${capture_dir}/aiplatform.yaml"
          ;;
      esac
      return 0
    fi
    return 0
  }

  SPLUNK_MODE=internal
  AI_STANDALONE_NAME=fixture-splunk
  AI_NS=fixture-ns
  CLUSTER_NAME=fixture
  CONFIG_FILE=unused
  STORAGE_CLASS=local-path
  MINIO_ROOT_USER=fixture-user
  MINIO_ROOT_PASSWORD=fixture-password
  OBJ_STORE_TYPE=minio
  MINIO_ENDPOINT=http://minio.fixture:9000
  OBJ_STORE_ENDPOINT="${MINIO_ENDPOINT}"
  MINIO_BUCKET=fixture-bucket
  OBJ_STORE_BUCKET=fixture-bucket
  REGION=us-east-2
  ECR_REGION=us-east-2
  DEFAULT_ACCELERATOR=L40S
  VECTORDB_SIZE=50Gi
  WORKER_IMAGE_REGISTRY=''
  AI_SIDECAR_ENVOY=false
  AI_SIDECAR_OTEL=false
  AI_SIDECAR_PROMETHEUS=false

  install_splunk_standalone
  install_ai_platform_cr
)

_render_splunk_bootstrap_manifest() (
  local output_file="$1"
  eval "$(_extract_fn _apply_internal_splunk_standalone_cr)"
  log() { :; }
  err() { echo "ERROR: $*" >&2; exit 1; }
  kubectl() { cat >"${output_file}"; }
  AI_STANDALONE_NAME=fixture-splunk
  AI_NS=fixture-ns
  STORAGE_CLASS=local-path
  MINIO_BUCKET=fixture-bucket
  _apply_internal_splunk_standalone_cr \
    http://minio.fixture:9000 bootstrap \
    '[{"name":"KEEP_ME","value":"kept"},{"name":"SPLUNKD_SSL_ENABLE","value":"false"}]'
)

_AIP4614_TMPDIR="$(mktemp -d)"
if _render_internal_splunk_https_manifests "${_AIP4614_TMPDIR}"; then
  _aip4614_render_rc=0
else
  _aip4614_render_rc=$?
fi
assert_eq "production installer functions render successfully" "0" "${_aip4614_render_rc}"

for _manifest in splunk-defaults standalone aiplatform; do
  assert_eq "rendered ${_manifest} manifest is non-empty" "1" \
    "$([[ -s "${_AIP4614_TMPDIR}/${_manifest}.yaml" ]] && echo 1 || echo 0)"
  assert_rc "rendered ${_manifest} manifest is valid YAML" 0 \
    "${YQ_BIN}" eval-all '.' "${_AIP4614_TMPDIR}/${_manifest}.yaml"
done

_expected_internal_url='https://splunk-fixture-splunk-standalone-service:8089'
_expected_internal_hec_url='http://splunk-fixture-splunk-standalone-service.fixture-ns.svc.cluster.local:8088'
_rendered_issuer=$(awk -F'issuer_uri: ' '/issuer_uri:/{print $2; exit}' \
  "${_AIP4614_TMPDIR}/splunk-defaults.yaml")
_rendered_endpoint=$(awk '
  /^[[:space:]]*splunkConfiguration:/ { in_splunk=1; next }
  in_splunk && /^[[:space:]]*endpoint:/ {
    sub(/^[[:space:]]*endpoint:[[:space:]]*/, ""); print; exit
  }
' "${_AIP4614_TMPDIR}/aiplatform.yaml")
_rendered_hec_endpoint=$(awk '
  /^[[:space:]]*splunkConfiguration:/ { in_splunk=1; next }
  in_splunk && /^[[:space:]]*hecEndpoint:/ {
    sub(/^[[:space:]]*hecEndpoint:[[:space:]]*/, ""); print; exit
  }
' "${_AIP4614_TMPDIR}/aiplatform.yaml")

assert_eq "oauth issuer renders main's short internal HTTPS Service URL" \
  "${_expected_internal_url}" "${_rendered_issuer}"
assert_eq "AIPlatform endpoint renders the same internal HTTPS Service URL" \
  "${_expected_internal_url}" "${_rendered_endpoint}"
assert_eq "oauth issuer and AIPlatform endpoint are byte-identical" \
  "${_rendered_issuer}" "${_rendered_endpoint}"
assert_eq "OTel HEC endpoint follows the effective HTTP listener on port 8088" \
  "${_expected_internal_hec_url}" "${_rendered_hec_endpoint}"
assert_eq "HEC endpoint is never used as a JWT issuer" "0" \
  "$(grep -c "issuer_uri: ${_expected_internal_hec_url}" \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "installer renders no JWKS proxy resource" "0" \
  "$(grep -c 'jwks-proxy' "${_AIP4614_TMPDIR}/all-applies.yaml" || true)"
assert_eq "Standalone final manifest enables splunkd management TLS exactly once" "1" \
  "$(grep 'extraEnv:' "${_AIP4614_TMPDIR}/standalone.yaml" \
    | grep -c '"name":"SPLUNKD_SSL_ENABLE","value":"true"')"
assert_eq "Standalone final manifest preserves unrelated extraEnv entries" "1" \
  "$(grep 'extraEnv:' "${_AIP4614_TMPDIR}/standalone.yaml" \
    | grep -c '"name":"KEEP_ME","value":"kept"')"
assert_eq "OAuth signing certificate remains configured independently of transport TLS" "1" \
  "$(grep -c 'certFile: \$SPLUNK_HOME/etc/auth/server.pem' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "native-HTTPS mode adds no global splunk-ansible retry override" "0" \
  "$(grep -c '^[[:space:]]*retry_num:' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "defaults register the idempotent stale-TLS migration pre-task" "1" \
  "$(grep -c 'file:///mnt/defaults/remove-stale-installer-tls.yml' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "migration restores built-in Splunk management TLS" "1" \
  "$(grep -c 'section: sslConfig, option: enableSplunkdSSL, value: "true"' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "migration keeps Splunk Web on HTTP when preview paths are present" "1" \
  "$(grep -c 'section: settings, option: enableSplunkWebSSL, value: "false"' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "migration does not change the independent HEC TLS switch" "0" \
  "$(grep -c 'section: http, option: enableSSL' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"

_exercise_internal_splunk_hec_detection() (
  local scenario="$1"
  eval "$(_extract_fn internal_splunk_pod_name)"
  eval "$(_extract_fn _internal_splunk_btool_http_value)"
  eval "$(_extract_fn _detect_internal_splunk_hec_url)"

  log() { :; }
  err() { return 1; }
  kubectl() {
    local args=" $* "
    if [[ "${args}" == *' btool inputs list http '* ]]; then
      case "${scenario}" in
        http|health-failure)
          printf '[http]\ndisabled = 0\nenableSSL = 0\nport = 8088\n'
          ;;
        https)
          printf '[http]\ndisabled = 0\nenableSSL = 1\nport = 8088\n'
          ;;
        disabled)
          printf '[http]\ndisabled = 1\nenableSSL = 0\nport = 8088\n'
          ;;
        missing-scheme)
          printf '[http]\ndisabled = 0\nport = 8088\n'
          ;;
        ambiguous-scheme)
          printf '[http]\ndisabled = 0\nenableSSL = 0\nenableSSL = 1\nport = 8088\n'
          ;;
        bad-port)
          printf '[http]\ndisabled = 0\nenableSSL = 0\nport = 18088\n'
          ;;
        exec-failure)
          return 1
          ;;
      esac
      return 0
    fi
    if [[ "${args}" == *'/services/collector/health'* ]]; then
      [[ "${scenario}" != "health-failure" ]]
      return
    fi
    return 1
  }

  AI_STANDALONE_NAME=fixture-splunk
  AI_NS=fixture-ns
  _detect_internal_splunk_hec_url || return 1
  printf '%s\n' "${_INTERNAL_SPLUNK_HEC_URL}"
)

assert_eq "effective HEC enableSSL=0 selects HTTP for OTel" \
  'http://splunk-fixture-splunk-standalone-service.fixture-ns.svc.cluster.local:8088' \
  "$(_exercise_internal_splunk_hec_detection http)"
assert_eq "effective HEC enableSSL=1 selects HTTPS for OTel" \
  'https://splunk-fixture-splunk-standalone-service.fixture-ns.svc.cluster.local:8088' \
  "$(_exercise_internal_splunk_hec_detection https)"

for _hec_failure in disabled missing-scheme ambiguous-scheme bad-port exec-failure health-failure; do
  if _exercise_internal_splunk_hec_detection "${_hec_failure}" >/dev/null 2>&1; then
    _hec_failure_rc=0
  else
    _hec_failure_rc=$?
  fi
  assert_eq "HEC detection fails closed for ${_hec_failure}" "1" "${_hec_failure_rc}"
done

_render_splunk_bootstrap_manifest "${_AIP4614_TMPDIR}/bootstrap-standalone.yaml"
assert_eq "fresh-install bootstrap keeps the operator's default startup probe" "0" \
  "$(grep -c '^[[:space:]]*failureThreshold: 40$' \
    "${_AIP4614_TMPDIR}/bootstrap-standalone.yaml")"
assert_eq "fresh-install bootstrap preserves unrelated extraEnv entries" "1" \
  "$(grep 'extraEnv:' "${_AIP4614_TMPDIR}/bootstrap-standalone.yaml" \
    | grep -c '"name":"KEEP_ME","value":"kept"')"
assert_eq "fresh-install bootstrap replaces a stale HTTP override with HTTPS" "1" \
  "$(grep 'extraEnv:' "${_AIP4614_TMPDIR}/bootstrap-standalone.yaml" \
    | grep -c '"name":"SPLUNKD_SSL_ENABLE","value":"true"')"
assert_eq "telemetry bootstrap wait precedes the explicit final HTTPS apply" "1" \
  "$(awk '
    /_wait_for_splunk_telemetry_bootstrap 600/ { waited=NR }
    /_apply_internal_splunk_standalone_cr.*https/ { applied=NR }
    END { print (waited > 0 && applied > waited) ? 1 : 0 }
  ' "${SCRIPT}")"

_exercise_internal_splunk_runtime_state() (
  local scenario="$1"
  eval "$(_extract_fn internal_splunk_management_url)"
  eval "$(_extract_fn internal_splunk_pod_name)"
  eval "$(_extract_fn _internal_splunk_runtime_matches_desired)"

  kubectl() {
    local args=" $* "
    [[ "${scenario}" != "exec-failure" ]] || return 1
    if [[ "${args}" == *' btool server list sslConfig --debug '* ]]; then
      if [[ "${scenario}" == "stale-server-path" ]]; then
        printf '/opt/splunk/etc/system/local/server.conf serverCert = /mnt/splunk-cert/server.pem\n'
      else
        printf '/opt/splunk/etc/system/local/server.conf enableSplunkdSSL = true\n'
      fi
      return 0
    fi
    if [[ "${args}" == *' btool web list settings --debug '* ]]; then
      if [[ "${scenario}" == "stale-web-path" ]]; then
        printf '/opt/splunk/etc/system/local/web.conf privKeyPath = /mnt/splunk-cert/tls.key\n'
      else
        printf '/opt/splunk/etc/system/local/web.conf enableSplunkWebSSL = false\n'
      fi
      return 0
    fi
    if [[ "${args}" == *' btool inputs list http --debug '* ]]; then
      if [[ "${scenario}" == "stale-hec-path" ]]; then
        printf '/opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf serverCert = /mnt/splunk-cert/server.pem\n'
      else
        printf '/opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf enableSSL = true\n'
      fi
      return 0
    fi
    if [[ "${args}" == *' btool server list sslConfig '* ]]; then
      case "${scenario}" in
        tls-false) printf '[sslConfig]\nenableSplunkdSSL = false\n' ;;
        ambiguous-tls) printf '[sslConfig]\nenableSplunkdSSL = true\nenableSplunkdSSL = true\n' ;;
        *) printf '[sslConfig]\nenableSplunkdSSL = true\n' ;;
      esac
      return 0
    fi
    if [[ "${args}" == *' btool authentication list oauth2_settings '* ]]; then
      case "${scenario}" in
        wrong-issuer) printf '[oauth2_settings]\nissuer_uri = https://old.example:8089\n' ;;
        ambiguous-issuer) printf '[oauth2_settings]\nissuer_uri = https://splunk-fixture-standalone-service:8089\nissuer_uri = https://old.example:8089\n' ;;
        *) printf '[oauth2_settings]\nissuer_uri = https://splunk-fixture-standalone-service:8089\n' ;;
      esac
      return 0
    fi
    return 1
  }

  AI_STANDALONE_NAME=fixture
  AI_NS=fixture-ns
  _internal_splunk_runtime_matches_desired splunk-fixture-standalone-0
)

assert_rc "effective native-HTTPS runtime state is accepted" 0 \
  _exercise_internal_splunk_runtime_state desired
for _runtime_failure in tls-false ambiguous-tls wrong-issuer ambiguous-issuer \
    stale-server-path stale-web-path stale-hec-path exec-failure; do
  assert_rc "runtime readiness rejects ${_runtime_failure}" 1 \
    _exercise_internal_splunk_runtime_state "${_runtime_failure}"
done
assert_eq "installer wait gates success on the full effective runtime state" "1" \
  "$(awk '
    /_wait_for_internal_splunk_https\(\)/ { in_wait=1 }
    in_wait && /_internal_splunk_runtime_matches_desired/ { found=1 }
    in_wait && /^}/ { print found + 0; exit }
  ' "${SCRIPT}")"

_exercise_internal_splunk_install_flow() (
  local scenario="$1"
  local event_file="$2"
  local state="${scenario}"
  : >"${event_file}"

  eval "$(_extract_fn internal_splunk_management_url)"
  eval "$(_extract_fn internal_splunk_pod_name)"
  eval "$(_extract_fn _read_internal_splunk_state)"
  eval "$(_extract_fn _apply_internal_splunk_standalone_cr)"
  eval "$(_extract_fn install_splunk_standalone)"

  log() { :; }
  warn() { :; }
  err() { exit 1; }
  ensure_namespace() { :; }
  wait_for_crd() { :; }
  _wait_for_splunk_telemetry_bootstrap() {
    printf 'wait-telemetry\n' >>"${event_file}"
    state="existing"
  }
  _wait_for_internal_splunk_https() {
    printf 'wait-https\n' >>"${event_file}"
  }
  _detect_internal_splunk_hec_url() { :; }

  kubectl() {
    local args=" $* " body
    if [[ "${args}" == *' get secret minio-credentials '* ]]; then return 0; fi
    if [[ "${args}" == *' get secret '* ]]; then return 1; fi
    if [[ "${args}" == *' get standalone '* && "${args}" == *' -o json '* ]]; then
      case "${state}" in
        fresh)
          echo 'Error from server (NotFound): standalones.enterprise.splunk.com "fixture" not found' >&2
          return 1
          ;;
        forbidden)
          echo 'Error from server (Forbidden): standalones.enterprise.splunk.com is forbidden' >&2
          return 1
          ;;
        idempotent)
          echo '{"status":{"telAppInstalled":true},"spec":{"extraEnv":[{"name":"SPLUNKD_SSL_ENABLE","value":"true"}]}}'
          return 0
          ;;
        *)
          echo '{"status":{"telAppInstalled":true},"spec":{"extraEnv":[{"name":"KEEP_ME","value":"kept"}]}}'
          return 0
          ;;
      esac
    fi
    if [[ "${args}" == *' apply '* && "${args}" == *' -f - '* ]]; then
      body="$(cat)"
      if [[ "${body}" == *'kind: Standalone'* ]]; then
        if [[ "${state}" == "fresh" ]]; then
          printf 'bootstrap\n' >>"${event_file}"
        else
          printf 'https\n' >>"${event_file}"
        fi
      fi
      return 0
    fi
    return 0
  }

  SPLUNK_MODE=internal
  AI_STANDALONE_NAME=fixture
  AI_NS=fixture-ns
  STORAGE_CLASS=local-path
  MINIO_ROOT_USER=user
  MINIO_ROOT_PASSWORD=password
  OBJ_STORE_TYPE=minio
  MINIO_ENDPOINT=http://minio:9000
  OBJ_STORE_ENDPOINT="${MINIO_ENDPOINT}"
  MINIO_BUCKET=bucket

  install_splunk_standalone
)

_fresh_events="${_AIP4614_TMPDIR}/fresh.events"
assert_rc "fresh install executes bootstrap then final HTTPS state" 0 \
  _exercise_internal_splunk_install_flow fresh "${_fresh_events}"
assert_eq "fresh install ordering is bootstrap, telemetry wait, HTTPS, readiness" \
  $'bootstrap\nwait-telemetry\nhttps\nwait-https' \
  "$(cat "${_fresh_events}")"

_upgrade_events="${_AIP4614_TMPDIR}/upgrade.events"
assert_rc "existing installation reconciles directly to native HTTPS" 0 \
  _exercise_internal_splunk_install_flow existing "${_upgrade_events}"
assert_eq "existing installation waits for native HTTPS" \
  $'https\nwait-https' "$(cat "${_upgrade_events}")"

_idempotent_events="${_AIP4614_TMPDIR}/idempotent.events"
assert_rc "already-HTTPS rerun remains idempotent" 0 \
  _exercise_internal_splunk_install_flow idempotent "${_idempotent_events}"
assert_eq "already-HTTPS rerun revalidates native HTTPS" \
  $'https\nwait-https' "$(cat "${_idempotent_events}")"

_forbidden_events="${_AIP4614_TMPDIR}/forbidden.events"
assert_rc "Standalone API/RBAC read failure aborts the installer" 1 \
  _exercise_internal_splunk_install_flow forbidden "${_forbidden_events}"
assert_eq "read failure never applies a Standalone manifest" "" \
  "$(cat "${_forbidden_events}")"

rm -rf "${_AIP4614_TMPDIR}"

# ── Tests: Deployment profile (MPR-184) ────────────────────────────────────────
# aiPlatform.profile: cpuOnly | fullfeature (legacy "full", or omitted, resolves
# to fullfeature). Pure logic: no cluster, SSH, kubectl or network.

suite "deployment profile"

# Earlier suites leave stubbed yq/kubectl/sleep functions behind. This suite never
# unsets them globally (so nothing appended after it loses its stubs): it calls
# the real binary with `command yq` and strips the stubs only inside the
# subshell that _profile_run opens.
if ! type -P yq >/dev/null 2>&1; then
  echo "  ⚠️  yq not installed; deployment profile tests skipped" >&2
  SKIP=$(( SKIP + 1 ))
  FILTER="__no_profile_tests__"
fi

_PROFILE_DIR="${SCRIPT_DIR}/examples"
_PROFILE_GOLDEN="${SCRIPT_DIR}/testdata/profile"
_PROFILE_TMP="$(mktemp -d)"

# Runs <fn...> in a subshell against config file $1 with load_config's real
# parsing, so the tests exercise the same variables the installer uses.
_profile_run() {
  local cfg="$1"; shift
  (
    unset -f yq kubectl sleep jq 2>/dev/null || true
    SCRIPT="${SCRIPT}"
    CONFIG_FILE="${cfg}"
    log() { :; }; warn() { :; }; err() { echo "ERR: $*" >&2; exit 1; }
    ensure_yq() { :; }; ensure_namespace() { :; }
    for _f in load_config config_bool normalize_env_key_segment build_image_url \
              component_enabled validate_scale_factor_config _profile_value_unsafe _profile_q \
              ai_platform_profile_resolved ai_platform_profile_explicit ai_platform_profile_set \
              _profile_ref_missing _profile_ref_check _profile_is_dns_subdomain \
              _profile_feature_subdomain_check _profile_feature_field_check \
              ai_platform_profile_feature_problems ai_platform_profile_cr_input_problems \
              render_slim_route_config ai_platform_profile_problems \
              agentruntime_network_policy_problems validate_agentruntime_network_policy_config \
              validate_ai_platform_profile_config _profile_image_url \
              render_ai_platform_profile_values; do
      eval "$(_extract_fn "${_f}")"
    done
    load_config >/dev/null 2>"${_PROFILE_TMP}/load.err" || { cat "${_PROFILE_TMP}/load.err" >&2; exit 97; }
    "$@"
  )
}

# _profile_cfg <example> <name> [yq expr...]: copy an example to a temp file
# after applying yq edits; prints the path.
_profile_cfg() {
  local example="$1" name="$2" out expr; shift 2
  out="${_PROFILE_TMP}/${name}.yaml"
  cp "${_PROFILE_DIR}/profile-${example}.yaml" "${out}"
  for expr in "$@"; do
    # A failed or no-op edit would leave the valid example in place and make a
    # positive assertion pass without testing anything, so record it. (This runs
    # in a command substitution, hence a marker file instead of a counter.)
    if ! command yq -i "${expr}" "${out}" >/dev/null 2>"${out}.err"; then
      echo "${name}: yq edit failed: ${expr}: $(head -c 200 "${out}.err")" >> "${_PROFILE_TMP}/setup-failures"
    fi
  done
  # Compare yq-normalised documents: yq -i also rewrites comment spacing, so a
  # byte comparison would call a no-op edit a change.
  if [[ $# -gt 0 ]] && [[ "$(command yq eval '.' "${_PROFILE_DIR}/profile-${example}.yaml")" == "$(command yq eval '.' "${out}")" ]]; then
    echo "${name}: edit changed nothing: $*" >> "${_PROFILE_TMP}/setup-failures"
  fi
  echo "${out}"
}

_profile_problems() { _profile_run "$1" ai_platform_profile_problems 2>&1; }

# Asserts that the problem list for a config contains the given text.
assert_problem() {
  local desc="$1" cfg="$2" want="$3" out
  out="$(_profile_problems "${cfg}")"
  if [[ "${out}" == *"${want}"* ]]; then
    assert_eq "${desc}" "ok" "ok"
  else
    assert_eq "${desc}" "contains: ${want}" "${out:-<no problems>}"
  fi
}

# Valid inputs for both profiles produce no problems.
for _p in cpuonly fullfeature; do
  assert_eq "valid ${_p} example has no problems" "" "$(_profile_problems "${_PROFILE_DIR}/profile-${_p}.yaml")"
  assert_rc "valid ${_p} example passes validate_ai_platform_profile_config" 0 \
    _profile_run "${_PROFILE_DIR}/profile-${_p}.yaml" validate_ai_platform_profile_config
done

# A configured peer must stay narrow before any controller rollout.
assert_rc "runtime network policy requires an allowlist" 1 _profile_run \
  "$(_profile_cfg cpuonly no-network-policy 'del(.aiPlatform.features[1].networkPolicy)')" \
  validate_agentruntime_network_policy_config
assert_rc "runtime network policy rejects a public CIDR" 1 _profile_run \
  "$(_profile_cfg cpuonly public-network-policy '.aiPlatform.features[1].networkPolicy.runtimeEgress[0].peer.cidr = "0.0.0.0/0"')" \
  validate_agentruntime_network_policy_config
assert_rc "runtime network policy rejects a namespace with no pod selector" 1 _profile_run \
  "$(_profile_cfg cpuonly broad-network-policy 'del(.aiPlatform.features[1].networkPolicy.dns.podSelector)')" \
  validate_agentruntime_network_policy_config

_network_policy_upgrade() (
  local case="$1" policy
  policy='{"dns":{"podSelector":{"app":"dns"}},"postgresql":{"peer":{"cidr":"10.0.0.1/32"},"port":5432},"slim":{"podSelector":{"app":"slim"}}}'
  kubectl() {
    case "$2" in
      crd)
        [[ "${case}" != unavailable ]] || return 1
        [[ "${case}" != new-install ]] || return 0
        printf '%s\n' customresourcedefinition.apiextensions.k8s.io/aiplatforms.ai.splunk.com \
          customresourcedefinition.apiextensions.k8s.io/aiservices.ai.splunk.com
        ;;
      aiplatforms.ai.splunk.com)
        if [[ "${case}" == old-platform ]]; then
          printf '%s\n' '{"items":[{"metadata":{"namespace":"test","name":"platform","uid":"platform-1"},"spec":{"features":[{"name":"agentruntime"}]}}]}'
        else
          printf '{"items":[{"metadata":{"namespace":"test","name":"platform","uid":"platform-1"},"spec":{"features":[{"name":"agentruntime","networkPolicy":%s}]}}]}\n' "${policy}"
        fi
        ;;
      aiservices.ai.splunk.com)
        local owner_uid=platform-1
        [[ "${case}" == stale-owner ]] && owner_uid=platform-0
        if [[ "${case}" == standalone ]]; then
          printf '{"items":[{"metadata":{"namespace":"test","name":"runtime"},"spec":{"features":{"name":"agentruntime","networkPolicy":%s}}}]}\n' "${policy}"
        else
          printf '{"items":[{"metadata":{"namespace":"test","name":"runtime","ownerReferences":[{"controller":true,"kind":"AIPlatform","apiVersion":"ai.splunk.com/v1","name":"platform","uid":"%s"}]},"spec":{"features":{"name":"agentruntime"}}}]}\n' "${owner_uid}"
        fi
        ;;
      *) return 1 ;;
    esac
  }
  preflight_agentruntime_policy_upgrade
)
assert_rc "runtime network policy upgrade reads a managed allowlist from the current platform" 0 _network_policy_upgrade managed
assert_rc "runtime network policy upgrade accepts a staged standalone allowlist" 0 _network_policy_upgrade standalone
assert_rc "runtime network policy checks allow a new install without existing CRDs" 0 _network_policy_upgrade new-install
assert_rc "runtime network policy upgrade blocks an unstaged platform" 1 _network_policy_upgrade old-platform
assert_rc "runtime network policy upgrade blocks an unstaged service with a stale owner UID" 1 _network_policy_upgrade stale-owner
assert_rc "runtime network policy upgrade fails if cluster inspection is unavailable" 1 _network_policy_upgrade unavailable
assert_eq "runtime network policy preflight precedes bundled CRD and Deployment changes" yes \
  "$(_extract_fn install_splunk_ai_operator | awk '/preflight_agentruntime_policy_upgrade/{a=NR} /kubectl apply/{if (!b) b=NR} END{print (a && b && a<b) ? "yes" : "no"}')"

# cpuOnly contradictions: each is reported with a stable code and field name.
assert_problem "cpuOnly rejects nodes.gpuWorkers > 0" \
  "$(_profile_cfg cpuonly gpu '.nodes.gpuWorkers = 1')" "[PROFILE_CONFLICT] nodes.gpuWorkers"
assert_problem "cpuOnly rejects an accelerator type" \
  "$(_profile_cfg cpuonly accel '.aiPlatform.defaultAcceleratorType = "L40S"')" "[PROFILE_CONFLICT] aiPlatform.defaultAcceleratorType"
assert_problem "cpuOnly rejects scaleFactor above 1" \
  "$(_profile_cfg cpuonly scale '.aiPlatform.scaleFactor = 2')" "[PROFILE_CONFLICT] aiPlatform.scaleFactor"
assert_problem "cpuOnly rejects components.nvidia: true" \
  "$(_profile_cfg cpuonly nvidia '.components.nvidia = true')" "[PROFILE_CONFLICT] components.nvidia"
assert_problem "cpuOnly rejects components.kuberay: true" \
  "$(_profile_cfg cpuonly kuberay '.components.kuberay = true')" "[PROFILE_CONFLICT] components.kuberay"
assert_problem "cpuOnly rejects an omitted components.kuberay (defaults to true)" \
  "$(_profile_cfg cpuonly kuberay-omit 'del(.components.kuberay)')" "[PROFILE_CONFLICT] components.kuberay"
assert_problem "cpuOnly rejects an omitted storage.modelStaging.enabled" \
  "$(_profile_cfg cpuonly staging 'del(.storage.modelStaging)')" "[PROFILE_CONFLICT] storage.modelStaging.enabled"
assert_problem "cpuOnly rejects an enabled sidecar" \
  "$(_profile_cfg cpuonly sidecar '.aiPlatform.sidecars.otel = true')" "[PROFILE_CONFLICT] aiPlatform.sidecars.otel"
assert_problem "cpuOnly rejects the saia feature" \
  "$(_profile_cfg cpuonly saia '.aiPlatform.features += [{"name": "saia", "version": "1.1.0"}]')" "[PROFILE_CONFLICT] aiPlatform.features[2].name"
assert_problem "cpuOnly rejects the seca feature" \
  "$(_profile_cfg cpuonly seca '.aiPlatform.features += [{"name": "seca"}]')" "'seca' is not supported by cpuOnly"
assert_problem "fullfeature rejects components.kuberay: false" \
  "$(_profile_cfg fullfeature noray '.components.kuberay = false')" "[PROFILE_CONFLICT] components.kuberay"

# All conflicts are reported together, never just the first.
_multi="$(_profile_problems "$(_profile_cfg cpuonly multi '.nodes.gpuWorkers = 2 | .components.nvidia = true | .aiPlatform.sidecars.envoy = true')")"
assert_eq "all cpuOnly conflicts are reported together" "3" "$(printf '%s\n' "${_multi}" | grep -c 'PROFILE_CONFLICT')"

# Unsupported and malformed profile values.
for _bad in gpu cpuonly CPUOnly FullFeature; do
  assert_problem "unsupported profile '${_bad}' is rejected" \
    "$(_profile_cfg cpuonly "bad-${_bad:-empty}" ".aiPlatform.profile = \"${_bad}\"")" "[PROFILE_UNSUPPORTED] aiPlatform.profile"
done
# A rejected profile value is never allowed to forge extra problem lines.
_forge="$(_profile_problems "$(_profile_cfg cpuonly forge '.aiPlatform.profile = "x\n[PROFILE_CONFLICT] fake.field: injected"')")"
assert_eq "a multi-line profile value yields exactly one problem line" "1" "$(printf '%s\n' "${_forge}" | grep -c '^\[PROFILE_')"
assert_eq "the rejected multi-line profile value is not echoed" "0" "$(printf '%s' "${_forge}" | grep -c 'fake.field')"
assert_contains "the multi-line profile value is reported as not shown" "(value not shown)" "${_forge}"
_esc="$(_profile_problems "$(_profile_cfg cpuonly escseq '.aiPlatform.profile = "\u001b[31mred"')")"
assert_eq "a profile value with an escape sequence is not echoed" "0" "$(printf '%s' "${_esc}" | grep -c $'\033')"
assert_contains "a short plain unsupported profile is still echoed" "unsupported value 'gpu'" \
  "$(_profile_problems "$(_profile_cfg cpuonly gpuprofile '.aiPlatform.profile = "gpu"')")"
assert_problem "non-string profile (list) is an invalid value" \
  "$(_profile_cfg cpuonly list '.aiPlatform.profile = ["cpuOnly"]')" "[PROFILE_INVALID_VALUE] aiPlatform.profile"
assert_problem "non-string profile (number) is an invalid value" \
  "$(_profile_cfg cpuonly num '.aiPlatform.profile = 1')" "[PROFILE_INVALID_VALUE] aiPlatform.profile"

# Missing required references, for both profiles.
for _p in cpuonly fullfeature; do
  assert_problem "${_p}: missing SLIM image" \
    "$(_profile_cfg "${_p}" "${_p}-slim" 'del(.images.slim)')" "[PROFILE_MISSING_REFERENCE] images.slim.apiImage"
  assert_problem "${_p}: missing runtime base image" \
    "$(_profile_cfg "${_p}" "${_p}-base" 'del(.images.agentRuntime.baseImage)')" "[PROFILE_MISSING_REFERENCE] images.agentRuntime.baseImage"
  assert_problem "${_p}: missing schema image" \
    "$(_profile_cfg "${_p}" "${_p}-schema" 'del(.images.agentRuntime.schemaSetupImage)')" "[PROFILE_MISSING_REFERENCE] images.agentRuntime.schemaSetupImage"
  assert_problem "${_p}: missing provider/carrier image" \
    "$(_profile_cfg "${_p}" "${_p}-provider" 'del(.images.agentRuntime.providerImages)')" "[PROFILE_MISSING_REFERENCE] images.agentRuntime.providerImages.mltk"
  assert_problem "${_p}: missing checkpoint Secret reference" \
    "$(_profile_cfg "${_p}" "${_p}-ckpt" 'del(.aiPlatform.features[1].checkpointDbSecretRef)')" "[PROFILE_MISSING_REFERENCE] aiPlatform.features[1].checkpointDbSecretRef"
  assert_problem "${_p}: missing provider loader module" \
    "$(_profile_cfg "${_p}" "${_p}-mod" 'del(.images.agentRuntime.providerModules)')" "[PROFILE_MISSING_REFERENCE] images.agentRuntime.providerModules.mltk"
  assert_problem "${_p}: malformed provider loader module" \
    "$(_profile_cfg "${_p}" "${_p}-badmod" '.images.agentRuntime.providerModules.mltk = "no_colon_here"')" "[PROFILE_INVALID_VALUE] images.agentRuntime.providerModules.mltk"
  assert_problem "${_p}: provider loader module with a path is malformed" \
    "$(_profile_cfg "${_p}" "${_p}-pathmod" '.images.agentRuntime.providerModules.mltk = "a/b:C"')" "[PROFILE_INVALID_VALUE] images.agentRuntime.providerModules.mltk"
  assert_problem "${_p}: missing provider key" \
    "$(_profile_cfg "${_p}" "${_p}-prov" 'del(.aiPlatform.features[1].provider)')" "[PROFILE_MISSING_REFERENCE] aiPlatform.features[1].provider"
  assert_problem "${_p}: missing slim feature" \
    "$(_profile_cfg "${_p}" "${_p}-noslim" 'del(.aiPlatform.features[0])')" "the 'slim' feature is required"
  assert_problem "${_p}: missing agentruntime feature" \
    "$(_profile_cfg "${_p}" "${_p}-noar" 'del(.aiPlatform.features[1])')" "the 'agentruntime' feature is required"
  assert_problem "${_p}: whitespace in an image reference" \
    "$(_profile_cfg "${_p}" "${_p}-ws" '.images.slim.apiImage = "bad ref"')" "[PROFILE_INVALID_VALUE] images.slim.apiImage"
done

# Messages name fields and never echo credentials.
_creds="$(_profile_problems "$(_profile_cfg cpuonly creds '.storage.objectStore.auth.rootPassword = "s3cr3t-value" | .nodes.gpuWorkers = 1')")"
assert_eq "problem messages never echo credentials" "0" "$(printf '%s' "${_creds}" | grep -c 's3cr3t-value')"

# Compatibility rule: an omitted profile keeps pre-profile behaviour; "full"
# is the legacy spelling of fullfeature.
_legacy="$(_profile_cfg fullfeature legacy 'del(.aiPlatform.profile) | del(.aiPlatform.features)')"
assert_eq "omitted profile: no profile checks apply" "" "$(_profile_problems "${_legacy}")"
assert_eq "omitted profile resolves to fullfeature" "fullfeature" "$(_profile_run "${_legacy}" ai_platform_profile_resolved)"
assert_rc "omitted profile is not explicit" 1 _profile_run "${_legacy}" ai_platform_profile_explicit
assert_eq "legacy 'full' resolves to fullfeature" "fullfeature" \
  "$(_profile_run "$(_profile_cfg fullfeature fullalias '.aiPlatform.profile = "full"')" ai_platform_profile_resolved)"
# Legacy "full" is valid but keeps pre-profile behaviour: it does not opt in to
# the Launchpad requirements, so an existing SAIA configuration that spells it
# keeps working.
_full_saia="$(_profile_cfg fullfeature full-saia '.aiPlatform.profile = "full" | del(.images.slim) | del(.images.agentRuntime) | .aiPlatform.features = [{"name": "saia", "version": "1.1.0"}]')"
assert_eq "legacy 'full' with an existing SAIA config has no problems" "" "$(_profile_problems "${_full_saia}")"
assert_rc "legacy 'full' is set" 0 _profile_run "${_full_saia}" ai_platform_profile_set
assert_rc "legacy 'full' is not an opt-in (not explicit)" 1 _profile_run "${_full_saia}" ai_platform_profile_explicit
assert_contains "legacy 'full' records the configured spelling" 'configured: "full"' \
  "$(_profile_run "${_full_saia}" render_ai_platform_profile_values)"
assert_contains "legacy 'full' leaves the CR field omitted" 'profile: ""   # omitted in the CR' \
  "$(_profile_run "${_full_saia}" render_ai_platform_profile_values)"
assert_contains "omitted profile renders an empty CR field" 'profile: ""   # omitted in the CR' \
  "$(_profile_run "${_legacy}" render_ai_platform_profile_values)"
# An unknown value is still rejected even though "full" is lenient.
assert_problem "legacy-looking typo 'Full' is rejected" \
  "$(_profile_cfg fullfeature fulltypo '.aiPlatform.profile = "Full"')" "[PROFILE_UNSUPPORTED]"
# An empty string is "omitted", exactly as for the operator.
_empty="$(_profile_cfg cpuonly emptyprofile '.aiPlatform.profile = ""')"
assert_eq "empty-string profile is treated as omitted" "" "$(_profile_problems "${_empty}")"
assert_rc "empty-string profile is not set" 1 _profile_run "${_empty}" ai_platform_profile_set
assert_eq "empty-string profile resolves to fullfeature" "fullfeature" "$(_profile_run "${_empty}" ai_platform_profile_resolved)"

# Review fixes: scale factor, gpuWorkers, duplicates, unsafe values.
for _sf in '0' '2.0' '0x2' '["a"]' '"two"'; do
  assert_problem "scaleFactor ${_sf} is rejected for an opted-in profile" \
    "$(_profile_cfg cpuonly "sf-${#_sf}-${_sf//[^a-z0-9]/}" ".aiPlatform.scaleFactor = ${_sf}")" "[PROFILE_INVALID_VALUE] aiPlatform.scaleFactor"
done
assert_eq "omitted nodes.gpuWorkers counts as 0 for cpuOnly" "" \
  "$(_profile_problems "$(_profile_cfg cpuonly nogpukey 'del(.nodes.gpuWorkers)')")"
assert_problem "duplicate agentruntime provider is a conflict" \
  "$(_profile_cfg cpuonly dupprov '.aiPlatform.features += [.aiPlatform.features[1]]')" "[PROFILE_CONFLICT] aiPlatform.features[2].name: duplicate feature entry"
assert_problem "duplicate slim feature is a conflict" \
  "$(_profile_cfg cpuonly dupslim '.aiPlatform.features += [.aiPlatform.features[0]]')" "[PROFILE_CONFLICT] aiPlatform.features[2].name: duplicate feature entry"
assert_eq "two different agentruntime providers are not duplicates" "" \
  "$(_profile_problems "$(_profile_cfg cpuonly twoprov '.aiPlatform.features += [{"name": "agentruntime", "provider": "other", "checkpointDbSecretRef": "x"}] | .images.agentRuntime.providerImages.other = "splunk/other:1" | .images.agentRuntime.providerModules.other = "other.loader:Loader"')")"
for _prov in 'Bad_Name' 'a.b' 'a"b' '-lead' "$(printf 'a%.0s' $(seq 1 64))"; do
  assert_problem "provider '${_prov:0:12}' must be a DNS-1123 label" \
    "$(_profile_cfg cpuonly "prov-${#_prov}-${_prov//[^a-zA-Z0-9]/}" ".aiPlatform.features[1].provider = \"${_prov//\"/\\\"}\"")" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].provider"
done
assert_problem "a quote in the snapshot manifest is rejected" \
  "$(_profile_cfg cpuonly snapquote '.images.snapshotManifest = "a\"b"')" "[PROFILE_INVALID_VALUE] images.snapshotManifest"
assert_problem "a backslash in an image reference is rejected" \
  "$(_profile_cfg cpuonly imgbs '.images.slim.apiImage = "a\\b"')" "[PROFILE_INVALID_VALUE] images.slim.apiImage"

# Generic installer inputs that end up in the CR are validated for the canonical
# profiles too (the CRD or webhook would otherwise reject them after the cluster
# has already been changed).
_cr_input_cases() { # <profile> : "<yq edit>|<expected field>"
  cat <<'CASES'
.cluster.name = "Bad_Name" => cluster.name
.cluster.name = "a-very-long-cluster-name-that-exceeds-the-fifty-one-character-limit" => cluster.name
.storage.objectStore.type = "gcs" => storage.objectStore.type
.storage.objectStore.bucket = "a#b" => storage.objectStore.bucket
.storage.objectStore.bucket = "bad!bucket" => storage.objectStore.bucket
.storage.objectStore.endpoint = "host:9000" => storage.objectStore.endpoint
.storage.objectStore.endpoint = "http://a\"b" => storage.objectStore.endpoint
.storage.objectStore.endpoint = "http://a b" => storage.objectStore.endpoint
.cluster.region = "no yes" => cluster.region
.cluster.region = "eu/west" => cluster.region
.kubernetes.namespace = "Bad_NS" => kubernetes.namespace
.aiPlatform.serviceTemplate.type = "Bogus" => aiPlatform.serviceTemplate.type
.aiPlatform.serviceTemplate.type = "true" => aiPlatform.serviceTemplate.type
.aiPlatform.serviceTemplate.nodePort = "abc" => aiPlatform.serviceTemplate.nodePort
.aiPlatform.serviceTemplate.nodePort = 99999 => aiPlatform.serviceTemplate.nodePort
.aiPlatform.serviceTemplate.nodePort = 80 => aiPlatform.serviceTemplate.nodePort
.aiPlatform.serviceTemplate.slimNodePort = 40000 => aiPlatform.serviceTemplate.slimNodePort
.splunk.enabled = true | .splunk.external.endpoint = "yes" => splunk.external.endpoint
.splunk.enabled = true | .splunk.external.endpoint = "https://splunk.example:8088" | .splunk.external.secretName = "Bad_Secret" => splunk.external.secretName
.splunk.trustedIssuers = ["https://a\"b"] => splunk.trustedIssuers[0]
.splunk.trustedIssuers = ["not-a-url"] => splunk.trustedIssuers[0]
CASES
}
_cr_input_i=0
while IFS= read -r _case_line; do
  [[ -z "${_case_line}" ]] && continue
  _edit="${_case_line%% => *}"; _field="${_case_line##* => }"
  for _p in cpuonly fullfeature; do
    _cr_input_i=$((_cr_input_i + 1))
    assert_problem "${_p}: ${_field} is validated up front (${_edit:0:48})" \
      "$(_profile_cfg "${_p}" "crin-${_cr_input_i}" "${_edit}")" "[PROFILE_INVALID_VALUE] ${_field}"
  done
done < <(_cr_input_cases)
assert_problem "fullfeature: storage.vectorDbSize must be a quantity" \
  "$(_profile_cfg fullfeature vdb-size '.storage.vectorDbSize = "50 Gi"')" "[PROFILE_INVALID_VALUE] storage.vectorDbSize"
assert_problem "fullfeature: storage.storageClass must be a Kubernetes name" \
  "$(_profile_cfg fullfeature vdb-sc '.storage.storageClass = "Bad Class"')" "[PROFILE_INVALID_VALUE] storage.storageClass"
assert_eq "cpuOnly does not validate the vector DB settings it never renders" "" \
  "$(_profile_problems "$(_profile_cfg cpuonly vdb-ignored '.storage.vectorDbSize = "50 Gi" | .storage.storageClass = "Bad Class"')")"
assert_problem "a missing cluster.name is reported" \
  "$(_profile_cfg cpuonly noclustername 'del(.cluster.name)')" "[PROFILE_MISSING_REFERENCE] cluster.name"
assert_eq "valid generic inputs are accepted (NodePort, Splunk external, trusted issuer)" "" \
  "$(_profile_problems "$(_profile_cfg cpuonly genericok '.aiPlatform.serviceTemplate.type = "NodePort" | .aiPlatform.serviceTemplate.nodePort = 30080 | .aiPlatform.serviceTemplate.slimNodePort = 30081 | .splunk.enabled = true | .splunk.external.endpoint = "https://splunk.example:8088" | .splunk.external.secretName = "splunk-hec.external" | .splunk.trustedIssuers = ["https://issuer.example/oauth2"] | .cluster.region = "eu-west-1" | .storage.objectStore.type = "aws"')")"
assert_eq "an aws object store does not require an endpoint to be valid" "" \
  "$(_profile_problems "$(_profile_cfg cpuonly awsnoendpoint '.storage.objectStore.type = "aws" | .storage.objectStore.endpoint = "not a url"')")"
assert_eq "the generic-input rules do not apply to legacy full" "" \
  "$(_profile_problems "$(_profile_cfg fullfeature legacygeneric '.aiPlatform.profile = "full" | .cluster.name = "Bad_Name" | .cluster.region = "no yes"')")"

# The installer renders only validated route references and omits them for
# deployments whose configuration does not opt in.
_slim_route_bad_name="$(_profile_cfg cpuonly badcaname '.splunk.caCertRef.name = "BAD-PRIVATE-CANARY"')"
_slim_route_bad_url="$(_profile_cfg fullfeature badorigin '.splunk.aitkSlimOrigin = "https://PRIVATE-CANARY@splunk.example/"')"
assert_problem "a malformed Splunk issuer CA reference is rejected" \
  "${_slim_route_bad_name}" "[PROFILE_INVALID_VALUE] splunk.caCertRef.name"
assert_problem "an AITK endpoint cannot contain URL user-info" \
  "${_slim_route_bad_url}" "[PROFILE_INVALID_VALUE] splunk.aitkSlimOrigin"
assert_eq "issuer CA diagnostics omit the rejected reference value" "no" \
  "$(if [[ "$(_profile_problems "${_slim_route_bad_name}")" == *PRIVATE-CANARY* ]]; then echo yes; else echo no; fi)"
assert_eq "AITK endpoint diagnostics omit the rejected URL" "no" \
  "$(if [[ "$(_profile_problems "${_slim_route_bad_url}")" == *PRIVATE-CANARY* ]]; then echo yes; else echo no; fi)"

# Rejected values are not echoed back, and sidecar flags must be real booleans.
for _sf in '"2x"' '0' '"<script>"'; do
  _sf_out="$(_profile_problems "$(_profile_cfg cpuonly "sfecho-${_sf//[^a-z0-9]/}" ".aiPlatform.scaleFactor = ${_sf}")")"
  assert_eq "scaleFactor ${_sf} is reported without echoing the value" "0" \
    "$(printf '%s' "${_sf_out}" | grep -c -e '(got ' -e '2x' -e 'script')"
done
for _sc in '"ture"' '"yes"' '1' '"on"'; do
  assert_problem "a non-boolean sidecar flag ${_sc} is rejected" \
    "$(_profile_cfg cpuonly "sidecar-${_sc//[^a-z0-9]/}" ".aiPlatform.sidecars.otel = ${_sc}")" "[PROFILE_INVALID_VALUE] aiPlatform.sidecars.otel: must be true or false"
done
assert_eq "real boolean sidecar flags are accepted for fullfeature" "" \
  "$(_profile_problems "$(_profile_cfg fullfeature sidecar-ok '.aiPlatform.sidecars.otel = true | .aiPlatform.sidecars.envoy = false')")"
# An unwritable --output gives a clear message, not a raw shell redirect error.
_bad_dest_out="$(CONFIG_FILE="${_PROFILE_DIR}/profile-cpuonly.yaml" LOG_DIR="${_PROFILE_TMP}/dlogs" bash "${SCRIPT}" render-profile --output /nonexistent-dir-mpr184/out.yaml 2>&1)"; _bad_dest_rc=$?
assert_eq "an unwritable --output exits nonzero" "1" "${_bad_dest_rc}"
assert_contains "an unwritable --output explains itself" "cannot write the profile values to /nonexistent-dir-mpr184/out.yaml" "${_bad_dest_out}"
assert_eq "an unwritable --output shows no raw shell error" "0" "$(printf '%s' "${_bad_dest_out}" | grep -c 'No such file or directory')"
assert_eq "a failed render leaves no temp file behind" "0" "$(ls "${_PROFILE_TMP}" | grep -c '\.tmp\.')"

# Feature fields are spliced into the CR, so they must be safe scalars.
_inj_name="$(_profile_cfg cpuonly injname '.aiPlatform.features += [{"name": "x\n    - name: saia\n      version: \"1\""}]')"
assert_problem "newline-injected feature name is rejected" "${_inj_name}" "[PROFILE_INVALID_VALUE] aiPlatform.features[2].name"
assert_eq "injected feature name is never echoed" "0" "$(_profile_problems "${_inj_name}" | grep -c -e '- name: saia' -e 'version: ')"
assert_problem "newline-injected version is rejected" \
  "$(_profile_cfg cpuonly injver '.aiPlatform.features[1].version = "1\"\n  x: y"')" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].version"
assert_problem "newline-injected minReplicas is rejected" \
  "$(_profile_cfg cpuonly injmin '.aiPlatform.features[1].minReplicas = "1\n  injected: true"')" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].minReplicas"
assert_problem "non-integer maxReplicas is rejected" \
  "$(_profile_cfg cpuonly maxstr '.aiPlatform.features[1].maxReplicas = "four"')" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].maxReplicas"
assert_problem "zero minReplicas is rejected" \
  "$(_profile_cfg cpuonly min0 '.aiPlatform.features[1].minReplicas = 0')" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].minReplicas"
assert_problem "minReplicas above maxReplicas is rejected" \
  "$(_profile_cfg cpuonly minmax '.aiPlatform.features[1].minReplicas = 5 | .aiPlatform.features[1].maxReplicas = 2')" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].maxReplicas"
assert_problem "minReplicas above the default maxReplicas is rejected" \
  "$(_profile_cfg cpuonly minaboveimplicitmax '.aiPlatform.features[1].minReplicas = 5 | del(.aiPlatform.features[1].maxReplicas)')" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].maxReplicas"
assert_problem "targetCPUUtilization above 100 is rejected" \
  "$(_profile_cfg cpuonly cpu101 '.aiPlatform.features[1].targetCPUUtilization = 101')" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].targetCPUUtilization"
assert_problem "a feature entry without a name is rejected" \
  "$(_profile_cfg cpuonly noname '.aiPlatform.features += [{"version": "1.0.0"}]')" "[PROFILE_INVALID_VALUE] aiPlatform.features[2].name"
# The feature name is a CRD enum; the Kubernetes name rules are applied exactly.
for _fname in unknown Saia agentruntime2 ''; do
  assert_problem "feature name '${_fname}' outside the CRD enum is rejected" \
    "$(_profile_cfg cpuonly "fname-${_fname:-empty}" ".aiPlatform.features += [{\"name\": \"${_fname}\"}]")" "[PROFILE_INVALID_VALUE] aiPlatform.features[2].name: must be one of saia, seca, slim, agentruntime"
done
_long_label="$(printf 'a%.0s' $(seq 1 64))"
for _bad_sub in 'a..b' 'a.-b' 'a.b.' '.a' 'A.b' "${_long_label}" "x.${_long_label}" 'a_b'; do
  assert_problem "checkpointDbSecretRef '${_bad_sub:0:14}' is not a Kubernetes name" \
    "$(_profile_cfg cpuonly "sub-ck-${#_bad_sub}-${_bad_sub//[^a-zA-Z0-9]/_}" ".aiPlatform.features[1].checkpointDbSecretRef = \"${_bad_sub}\"")" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].checkpointDbSecretRef"
  assert_problem "serviceAccountName '${_bad_sub:0:14}' is not a Kubernetes name" \
    "$(_profile_cfg cpuonly "sub-sa-${#_bad_sub}-${_bad_sub//[^a-zA-Z0-9]/_}" ".aiPlatform.features[1].serviceAccountName = \"${_bad_sub}\"")" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].serviceAccountName"
done
_good_label63="$(printf 'a%.0s' $(seq 1 63))"
assert_eq "valid dotted and 63-character-label names are accepted" "" \
  "$(_profile_problems "$(_profile_cfg cpuonly goodsubs ".aiPlatform.features[1].checkpointDbSecretRef = \"${_good_label63}.b-c.d\" | .aiPlatform.features[1].serviceAccountName = \"my.sa-1\"")")"
assert_problem "serviceAccountName must be a DNS label" \
  "$(_profile_cfg cpuonly badsa '.aiPlatform.features[1].serviceAccountName = "Bad_SA"')" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].serviceAccountName"
for _secret in 'Bad_Secret:1' 'UPPER' '-lead' 'a b'; do
  assert_problem "checkpointDbSecretRef '${_secret}' must be a Secret name" \
    "$(_profile_cfg cpuonly "secret-${_secret//[^a-zA-Z0-9]/_}" ".aiPlatform.features[1].checkpointDbSecretRef = \"${_secret}\"")" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].checkpointDbSecretRef"
done
assert_eq "valid feature fields are accepted (incl. a dotted Secret name)" "" \
  "$(_profile_problems "$(_profile_cfg cpuonly goodfields '.aiPlatform.features[1].checkpointDbSecretRef = "pg.conn-1" | .aiPlatform.features[1].version = "0.2.0-rc.1+build" | .aiPlatform.features[1].serviceAccountName = "launchpad-sa" | .aiPlatform.features[1].minReplicas = 2 | .aiPlatform.features[1].maxReplicas = 8 | .aiPlatform.features[1].targetCPUUtilization = 100')")"
# Rules the webhook or the CRD enforce, which must not wait for kubectl apply
# (that happens after the installer has already changed the cluster).
assert_problem "a provider on a non-agentruntime feature is rejected" \
  "$(_profile_cfg cpuonly slimprov '.aiPlatform.features[0].provider = "x"')" "[PROFILE_CONFLICT] aiPlatform.features[0].provider: only supported for the agentruntime feature"
_extra_features() { # <n>: n additional unique agentruntime providers
  local expr='' k
  for ((k=1; k<=$1; k++)); do
    expr+=".aiPlatform.features += [{\"name\": \"agentruntime\", \"provider\": \"p${k}\", \"checkpointDbSecretRef\": \"s\"}] | .images.agentRuntime.providerImages.p${k} = \"splunk/p:1\" | .images.agentRuntime.providerModules.p${k} = \"m.x:C\" | "
  done
  printf '%s' "${expr% | }"
}
assert_problem "more than 10 features exceeds the CRD limit" \
  "$(_profile_cfg cpuonly feat11 "$(_extra_features 9)")" "[PROFILE_INVALID_VALUE] aiPlatform.features: at most 10 features are allowed (got 11)"
assert_eq "exactly 10 features is accepted" "" "$(_profile_problems "$(_profile_cfg cpuonly feat10 "$(_extra_features 8)")")"
for _env in '{"PORT": 8080}' '{"DEBUG": true}' '{"RATIO": 1.5}' '{"NOTHING": null}' '["a"]' '"text"'; do
  assert_problem "features[].env ${_env} is rejected (CRD: map of strings)" \
    "$(_profile_cfg cpuonly "env-${_env//[^a-zA-Z0-9]/_}" ".aiPlatform.features[1].env = ${_env}")" "[PROFILE_INVALID_VALUE] aiPlatform.features[1].env"
done
assert_eq "features[].env with quoted string values is accepted" "" \
  "$(_profile_problems "$(_profile_cfg cpuonly envok '.aiPlatform.features[1].env = {"PORT": "8080", "DEBUG": "true"}')")"
# Control characters other than whitespace are rejected, and never reach a rendered
# YAML scalar. The values are passed as real bytes through the environment (a yq
# expression does not interpret \u escapes, so it would only store a literal backslash).
_ctrl_img_cfg="$(CTRLV=$'a\033b' _profile_cfg cpuonly ctrl-img '.images.slim.apiImage = strenv(CTRLV)')"
assert_eq "the test config really holds an ESC byte (not a literal backslash)" \
  "$(printf '"a\\u001bb"')" "$(command yq eval -o=json '.images.slim.apiImage' "${_ctrl_img_cfg}")"
assert_problem "an escape character in an image reference is rejected" "${_ctrl_img_cfg}" "[PROFILE_INVALID_VALUE] images.slim.apiImage: must not contain whitespace, control characters"
_ctrl_del_cfg="$(CTRLV=$'a\177b' _profile_cfg cpuonly ctrl-del '.images.snapshotManifest = strenv(CTRLV)')"
assert_problem "a DEL character in the snapshot manifest is rejected" "${_ctrl_del_cfg}" "[PROFILE_INVALID_VALUE] images.snapshotManifest"
_ctrl_out="${_PROFILE_TMP}/ctrl.yaml"
_ctrl_legacy_cfg="$(CTRLV=$'a\033b\177c' _profile_cfg fullfeature ctrl-legacy '.aiPlatform.profile = "full" | .images.slim.apiImage = strenv(CTRLV)')"
_profile_run "${_ctrl_legacy_cfg}" render_ai_platform_profile_values > "${_ctrl_out}"
assert_rc "a control character in a legacy-profile reference still renders valid YAML" 0 command yq eval '.' "${_ctrl_out}"
assert_eq "the control characters round-trip through the rendered YAML" \
  "$(printf '"registry.example.internal/a\\u001bb\177c"')" "$(command yq eval -o=json '.images.slim' "${_ctrl_out}")"
# Legacy (not opted in) configs keep their own field handling: nothing is imposed.
assert_eq "legacy 'full' does not validate feature fields" "" \
  "$(_profile_problems "$(_profile_cfg fullfeature legacyfields '.aiPlatform.profile = "full" | .aiPlatform.features[1].minReplicas = "x"')")"

# Effective components follow component_enabled, not the raw flags.
_nv_omit="$(_profile_cfg cpuonly nvomit 'del(.components.nvidia)')"
assert_contains "cpuOnly with nvidia omitted renders nvidia: false" "  nvidia: false" "$(_profile_run "${_nv_omit}" render_ai_platform_profile_values)"
_nv_on="$(_profile_cfg fullfeature nvon 'del(.components.nvidia)')"
assert_contains "fullfeature with GPU workers and nvidia omitted renders nvidia: true (default)" "  nvidia: true" "$(_profile_run "${_nv_on}" render_ai_platform_profile_values)"
_nv_nogpu="$(_profile_cfg fullfeature nvnogpu '.nodes.gpuWorkers = 0')"
assert_contains "nvidia flag is ignored when there are no GPU workers" "  nvidia: false" "$(_profile_run "${_nv_nogpu}" render_ai_platform_profile_values)"

# Rendered YAML escapes values, so a quote can never produce invalid YAML.
_esc_out="${_PROFILE_TMP}/esc.yaml"
_profile_run "$(_profile_cfg fullfeature escq '.aiPlatform.profile = "full" | .images.snapshotManifest = "a\"b\\c"')" render_ai_platform_profile_values > "${_esc_out}"
assert_rc "rendered values with quotes and backslashes are valid YAML" 0 command yq eval '.' "${_esc_out}"
assert_eq "escaped snapshot manifest round-trips" 'a"b\c' "$(command yq eval '.images.snapshotManifest' "${_esc_out}")"

# Rendered output: deterministic and equal to the checked-in golden files.
for _p in cpuonly fullfeature; do
  _r1="$(_profile_run "${_PROFILE_DIR}/profile-${_p}.yaml" render_ai_platform_profile_values)"
  _r2="$(_profile_run "${_PROFILE_DIR}/profile-${_p}.yaml" render_ai_platform_profile_values)"
  assert_eq "${_p}: same input renders the same output" "${_r1}" "${_r2}"
  [[ "${UPDATE_GOLDEN:-}" == "1" ]] && printf '%s\n' "${_r1}" > "${_PROFILE_GOLDEN}/profile-values-${_p}.expected.yaml"
  assert_eq "${_p}: rendered values match the golden file" \
    "$(cat "${_PROFILE_GOLDEN}/profile-values-${_p}.expected.yaml" 2>/dev/null)" "${_r1}"
done
_changed_keys() {
  diff <(command yq eval -o=props '.' "$1") <(command yq eval -o=props '.' "$2") \
    | grep '^[<>]' | sed 's/^[<>] //; s/ = .*//' | sort -u | tr '\n' ' '
}
assert_eq "cpuOnly and fullfeature values differ exactly where the profiles differ" \
  "aiPlatformSpec.profile components.kuberay components.nvidia nodes.gpuWorkers profile.configured profile.effective " \
  "$(_changed_keys "${_PROFILE_GOLDEN}/profile-values-cpuonly.expected.yaml" "${_PROFILE_GOLDEN}/profile-values-fullfeature.expected.yaml")"

# Exercise the manifest the installer applies as well as the profile values.
# Private registry references should come from the test configuration only.
_configure_profile_manifest() {
  local output="$1"
  local -a TMP_FILES=()
  SPLUNK_AI_FILE="${SCRIPT_DIR}/artifacts.yaml"
  configure_images || return 1
  cp "${SPLUNK_AI_FILE}" "${output}"
  rm -f "${TMP_FILES[@]}"
}

suite "account-neutral installer manifest"
assert_eq "the embedded bundle has no account-specific ECR references" "no" \
  "$(if grep -Eq '[0-9]{12}\.dkr\.ecr\.' "${SCRIPT_DIR}/artifacts.yaml"; then echo yes; else echo no; fi)"
for _profile in cpuonly fullfeature; do
  _image_cfg="$(_profile_cfg "${_profile}" "image-overrides-${_profile}" \
    '.images.registry = "registry.example.invalid:5000" |
     .images.slim.apiImage = "ai/slim:candidate" |
     .images.agentRuntime.baseImages."v2.0.0" = "ai/runtime:v2" |
     .images.agentRuntime.schemaSetupImage = "mirror.example.invalid:5001/ai/schema@sha256:1111111111111111111111111111111111111111111111111111111111111111"')"
  if [[ "${_profile}" == "fullfeature" ]]; then
    command yq -i '
      .aiPlatform.features += [{"name": "saia"}] |
      .images.saia = {"apiImage": "ai/saia:v1", "apiV2Image": "ai/saia-v2:v1", "dataLoaderImage": "ai/data-loader:v1"}
    ' "${_image_cfg}"
  fi
  _manifest="${_PROFILE_TMP}/image-overrides-${_profile}-artifacts.yaml"
  assert_rc "${_profile}: configure images in the generated bundle" 0 \
    _profile_run "${_image_cfg}" _configure_profile_manifest "${_manifest}"
  _manager_env="$(command yq -o=json '
    select(.kind == "Deployment" and .metadata.name == "splunk-ai-operator-controller-manager") |
    .spec.template.spec.containers[] | select(.name == "manager") | .env
  ' "${_manifest}" 2>/dev/null | command jq -r '
    map(select(has("value"))) | map({key: .name, value: .value}) | from_entries
  ')"
  assert_eq "${_profile}: SLIM image is qualified using the configured registry" \
    "registry.example.invalid:5000/ai/slim:candidate" \
    "$(printf '%s' "${_manager_env}" | command jq -r .RELATED_IMAGE_SLIM_API)"
  assert_eq "${_profile}: versioned Runtime base comes from installer config" \
    "registry.example.invalid:5000/ai/runtime:v2" \
    "$(printf '%s' "${_manager_env}" | command jq -r .RELATED_IMAGE_AGENT_RUNTIME_BASE_V2_0_0)"
  assert_eq "${_profile}: fully qualified schema image keeps its registry and digest" \
    "mirror.example.invalid:5001/ai/schema@sha256:1111111111111111111111111111111111111111111111111111111111111111" \
    "$(printf '%s' "${_manager_env}" | command jq -r .RELATED_IMAGE_AGENT_RUNTIME_SCHEMA_SETUP)"
  if [[ "${_profile}" == "cpuonly" ]]; then
    _ray_head="docker.io/splunk/ai-tier-ray-head:v1.0"
    _ray_worker="docker.io/splunk/ai-tier-ray-worker:v1.0"
    _saia_api="docker.io/splunk/ai-tier-saia-api:v1.0"
    _saia_loader="docker.io/splunk/ai-tier-saia-data-loader:v1.0"
  else
    _ray_head="registry.example.invalid:5000/rayproject/ray:2.44.0"
    _ray_worker="${_ray_head}"
    _saia_api="registry.example.invalid:5000/ai/saia:v1"
    _saia_loader="registry.example.invalid:5000/ai/data-loader:v1"
  fi
  assert_eq "${_profile}: Ray head uses the effective profile image" "${_ray_head}" \
    "$(printf '%s' "${_manager_env}" | command jq -r .RELATED_IMAGE_RAY_HEAD)"
  assert_eq "${_profile}: Ray worker uses the effective profile image" "${_ray_worker}" \
    "$(printf '%s' "${_manager_env}" | command jq -r .RELATED_IMAGE_RAY_WORKER)"
  assert_eq "${_profile}: SAIA API uses the effective profile image" "${_saia_api}" \
    "$(printf '%s' "${_manager_env}" | command jq -r .RELATED_IMAGE_SAIA_API)"
  assert_eq "${_profile}: post-install hook uses the effective profile image" "${_saia_loader}" \
    "$(printf '%s' "${_manager_env}" | command jq -r .RELATED_IMAGE_POST_INSTALL_HOOK)"
done
suite "deployment profile"

# cpuOnly must not carry Ray, Weaviate or SAIA images: install would inject them
# into the operator Deployment although nothing deploys them.
for _leak in 'ray.headImage:rayproject/ray:2.44.0' 'ray.workerImage:rayproject/ray:2.44.0' 'weaviate.image:weaviate:1' 'saia.apiImage:s/a:1' 'saia.apiV2Image:s/a2:1' 'saia.dataLoaderImage:s/dl:1'; do
  assert_problem "cpuOnly rejects images.${_leak%%:*}" \
    "$(_profile_cfg cpuonly "leak-${_leak%%:*}" ".images.${_leak%%:*} = \"${_leak#*:}\"")" "[PROFILE_CONFLICT] images.${_leak%%:*}"
done
# fullfeature: validate/render-profile must agree with install about Ray and Weaviate images.
assert_problem "fullfeature without a Ray head image is reported (as install does)" \
  "$(_profile_cfg fullfeature noheadimg 'del(.images.ray.headImage)')" "[PROFILE_MISSING_REFERENCE] images.ray.headImage"
assert_problem "fullfeature without a Ray worker image is reported" \
  "$(_profile_cfg fullfeature noworkerimg 'del(.images.ray.workerImage)')" "[PROFILE_MISSING_REFERENCE] images.ray.workerImage"
assert_problem "fullfeature without a Weaviate image is reported" \
  "$(_profile_cfg fullfeature noweaviate 'del(.images.weaviate)')" "[PROFILE_MISSING_REFERENCE] images.weaviate.image"

# Air-gap model verification does not apply to cpuOnly (it hosts no model).
_verify_applies() { # <profile> <airgap>
  ( eval "$(_extract_fn ai_platform_profile_resolved)"; eval "$(_extract_fn model_artifacts_verification_applies)"
    AI_PLATFORM_PROFILE="$1"; AIRGAP_MODE="$2"; model_artifacts_verification_applies )
}
assert_rc "air-gap verification does not apply to cpuOnly" 1 _verify_applies cpuOnly true
assert_rc "air-gap verification applies to fullfeature" 0 _verify_applies fullfeature true
assert_rc "air-gap verification applies to an omitted profile" 0 _verify_applies "" true
assert_rc "air-gap verification applies to legacy full" 0 _verify_applies full true
assert_rc "verification never applies outside air-gap mode" 1 _verify_applies fullfeature false

# validate_image_config, the staging/accelerator bypasses and the validate command
# with a profile set. These are the install-path entry points the pure-function
# tests above do not reach.
_vic() {
  _profile_run "$1" _vic_inner
}
_vic_inner() {
  for _f in validate_image_config k0s_feature_enabled k0s_saia_feature_enabled k0s_slim_feature_enabled k0s_agentruntime_feature_enabled; do
    eval "$(_extract_fn "${_f}")"
  done
  validate_image_config
}
assert_rc "validate_image_config accepts the cpuOnly example (no Weaviate or Ray image)" 0 _vic "${_PROFILE_DIR}/profile-cpuonly.yaml"
assert_rc "validate_image_config accepts the fullfeature example" 0 _vic "${_PROFILE_DIR}/profile-fullfeature.yaml"
assert_rc "validate_image_config rejects a cpuOnly profile conflict" 1 \
  _vic "$(_profile_cfg cpuonly vic-conflict '.nodes.gpuWorkers = 2')"
assert_contains "validate_image_config names the profile problem" "[PROFILE_CONFLICT] nodes.gpuWorkers" \
  "$(_vic "$(_profile_cfg cpuonly vic-conflict2 '.nodes.gpuWorkers = 2')" 2>&1)"
assert_rc "validate_image_config rejects a fullfeature config without Ray images" 1 \
  _vic "$(_profile_cfg fullfeature vic-noray 'del(.images.ray)')"

_resolve_inner() {
  for _f in resolve_model_staging resolve_accelerator_type; do eval "$(_extract_fn "${_f}")"; done
  SILENT_INSTALL=false
  resolve_model_staging </dev/null && resolve_accelerator_type </dev/null && echo "staging=${MODEL_STAGING_ENABLED} accelerator=[${DEFAULT_ACCELERATOR}]"
}
assert_eq "cpuOnly never prompts for model staging or an accelerator" "staging=false accelerator=[]" \
  "$(_profile_run "${_PROFILE_DIR}/profile-cpuonly.yaml" _resolve_inner 2>&1)"
assert_rc "fullfeature without an accelerator still errors (the bypass is cpuOnly-only)" 1 \
  _profile_run "$(_profile_cfg fullfeature noaccel 'del(.aiPlatform.defaultAcceleratorType)')" _resolve_inner

_validate_cmd() { CONFIG_FILE="$1" LOG_DIR="${_PROFILE_TMP}/vlogs" bash "${SCRIPT}" validate 2>&1; }
_vout="$(_validate_cmd "$(_profile_cfg cpuonly vcmd-bad '.nodes.gpuWorkers = 2')")"; _vrc=$?
assert_contains "validate command reports the profile conflict" "[PROFILE_CONFLICT] nodes.gpuWorkers" "${_vout}"
assert_rc "validate command fails on a profile conflict" 1 bash -c 'CONFIG_FILE="$1" LOG_DIR="$2" bash "$3" validate' _ \
  "$(_profile_cfg cpuonly vcmd-bad2 '.nodes.gpuWorkers = 2')" "${_PROFILE_TMP}/vlogs" "${SCRIPT}"
assert_rc "validate command passes the cpuOnly example" 0 bash -c 'CONFIG_FILE="$1" LOG_DIR="$2" bash "$3" validate' _ \
  "${_PROFILE_DIR}/profile-cpuonly.yaml" "${_PROFILE_TMP}/vlogs" "${SCRIPT}"

# Golden files are regenerated by UPDATE_GOLDEN=1, so a bad regeneration would
# otherwise pass. These invariants read the golden files directly and do not
# depend on the render under test.
for _p in cpuonly fullfeature; do
  _g="${_PROFILE_GOLDEN}/profile-values-${_p}.expected.yaml"
  _gc="${_PROFILE_GOLDEN}/aiplatform-cr-${_p}.expected.yaml"
  _want_profile="cpuOnly"; _want_gpu="0"; _want_ray="false"
  [[ "${_p}" == "fullfeature" ]] && { _want_profile="fullfeature"; _want_gpu="1"; _want_ray="true"; }
  assert_eq "golden ${_p} values: valid YAML" "0" "$(command yq eval '.' "${_g}" >/dev/null 2>&1; echo $?)"
  assert_eq "golden ${_p} values: effective profile" "${_want_profile}" "$(command yq eval '.profile.effective' "${_g}")"
  assert_eq "golden ${_p} values: explicit" "true" "$(command yq eval '.profile.explicit' "${_g}")"
  assert_eq "golden ${_p} values: CR field" "${_want_profile}" "$(command yq eval '.aiPlatformSpec.profile' "${_g}")"
  assert_eq "golden ${_p} values: GPU workers" "${_want_gpu}" "$(command yq eval '.nodes.gpuWorkers' "${_g}")"
  assert_eq "golden ${_p} values: kuberay" "${_want_ray}" "$(command yq eval '.components.kuberay' "${_g}")"
  assert_eq "golden ${_p} values: nvidia follows GPU workers" "${_want_ray}" "$(command yq eval '.components.nvidia' "${_g}")"
  assert_eq "golden ${_p} values: no null or empty reference" "0" "$(grep -cE ': "(null)?"$' "${_g}" | tr -d ' ')" 
  for _k in .images.agentRuntime.base .images.agentRuntime.schemaSetup .images.slim; do
    assert_eq "golden ${_p} values: ${_k} is a registry reference" "yes" \
      "$([[ "$(command yq eval "${_k}" "${_g}")" == registry.example.internal/* ]] && echo yes || echo no)"
  done
  assert_eq "golden ${_p} values: provider image present" "yes" \
    "$([[ "$(command yq eval '.images.agentRuntime.providers.mltk' "${_g}")" == */ai-agent-runtime-provider-mltk:* ]] && echo yes || echo no)"
  assert_eq "golden ${_p} values: provider module present" "yes" \
    "$([[ "$(command yq eval '.images.agentRuntime.modules.mltk' "${_g}")" == *:* ]] && echo yes || echo no)"
  # AITK is a Splunk app, not an image: nothing in cluster setup renders or depends on it.
  assert_eq "golden ${_p} values: no AITK setting" "null" "$(command yq eval '.images.aitk' "${_g}")"
  assert_eq "golden ${_p} values: no credential-looking keys" "0" "$(grep -ciE 'password|token|secretkey|apikey' "${_g}" | tr -d ' ')"
  assert_eq "golden ${_p} CR: valid YAML" "0" "$(command yq eval '.' "${_gc}" >/dev/null 2>&1; echo $?)"
  assert_eq "golden ${_p} CR: spec.profile" "${_want_profile}" "$(command yq eval '.spec.profile' "${_gc}")"
  assert_eq "golden ${_p} CR: kind" "AIPlatform" "$(command yq eval '.kind' "${_gc}")"
  assert_eq "golden ${_p} CR: has the slim and agentruntime features" "slim,agentruntime" "$(command yq eval '[.spec.features[].name] | join(",")' "${_gc}")"
  # The examples must agree with the merged MPR-188 candidate contract (the
  # authority for the provider, its loader module and the checkpoint Secret), so
  # they cannot drift from it unnoticed.
  _cm="${SCRIPT_DIR}/../../config/agent-runtime/candidate-manifest.yaml"
  assert_eq "golden ${_p} CR: provider is the contract's provider" \
    "$(command yq eval '.spec.components.launchpadCarrier.provider' "${_cm}")" \
    "$(command yq eval '.spec.features[] | select(.name == "agentruntime") | .provider' "${_gc}")"
  assert_eq "golden ${_p} CR: checkpoint Secret is the contract's Secret" \
    "$(command yq eval '.spec.contract.secretKeys.name' "${_cm}")" \
    "$(command yq eval '.spec.features[] | select(.name == "agentruntime") | .checkpointDbSecretRef' "${_gc}")"
  assert_eq "golden ${_p} CR: preserves the configured network policy" \
    "$(command yq eval '.aiPlatform.features[] | select(.name == "agentruntime") | .networkPolicy' "${_PROFILE_DIR}/profile-${_p}.yaml")" \
    "$(command yq eval '.spec.features[] | select(.name == "agentruntime") | .networkPolicy' "${_gc}")"
  assert_eq "golden ${_p} values: provider module is the contract's AGENT_MODULE" \
    "$(command yq eval '.spec.components.launchpadCarrier.agentModule' "${_cm}")" \
    "$(command yq eval '.images.agentRuntime.modules.mltk' "${_g}")"
done
for _k in .spec.defaultAcceleratorType .spec.gpuScheduler .spec.workerGroupConfig .spec.storage; do
  assert_eq "golden cpuOnly CR: ${_k} is absent" "null" "$(command yq eval "${_k}" "${_PROFILE_GOLDEN}/aiplatform-cr-cpuonly.expected.yaml")"
done
assert_eq "golden fullfeature CR: keeps accelerator and storage" "L40S,50Gi" \
  "$(command yq eval '[.spec.defaultAcceleratorType, .spec.storage.vectorDB.size] | join(",")' "${_PROFILE_GOLDEN}/aiplatform-cr-fullfeature.expected.yaml")"
[[ "${UPDATE_GOLDEN:-}" == "1" ]] && echo "  ⚠️  UPDATE_GOLDEN=1: golden files were rewritten; review 'git diff tools/ai-tier-cluster-setup/testdata' before committing." >&2

# The AIPlatform CR the installer applies: render install_ai_platform_cr with a
# stubbed kubectl and compare to the golden CR (also validated by the Go
# tests against the operator's profile rules).
_render_cr() {
  _profile_run "$1" _render_cr_inner
}
_render_cr_inner() {
  eval "$(_extract_fn install_ai_platform_cr)"
  # install_ai_platform_cr lists pull Secrets through these (MPR-193).
  for _f in configured_pull_secret_names _pull_secret_file ensure_configured_pull_secrets image_pull_secret_names; do
    eval "$(_extract_fn "${_f}")"
  done
  eval "$(_extract_fn create_agentruntime_checkpoint_secrets)"
  eval "$(_extract_fn k0s_feature_enabled)"
  k0s_agentruntime_feature_enabled() { k0s_feature_enabled agentruntime; }
  need() { :; }
  AGENT_RUNTIME_CHECKPOINT_DB_URL='postgresql://fixture-user:fixture-password@fixture-db:5432/checkpoints'
  sleep() { :; }
  jq() { :; }
  kubectl() { if [[ " $* " == *" apply "* && " $* " == *" -f - "* ]]; then cat; fi; return 0; }
  SPLUNK_MODE=disabled
  install_ai_platform_cr 2>&1 | sed -n '/^apiVersion: ai.splunk.com/,$p' | grep -v '^[[:space:]]*$'
}
for _p in cpuonly fullfeature; do
  _cr="$(_render_cr "${_PROFILE_DIR}/profile-${_p}.yaml")"
  [[ "${UPDATE_GOLDEN:-}" == "1" ]] && printf '%s\n' "${_cr}" > "${_PROFILE_GOLDEN}/aiplatform-cr-${_p}.expected.yaml"
  assert_eq "${_p}: rendered AIPlatform CR matches the golden file" \
    "$(cat "${_PROFILE_GOLDEN}/aiplatform-cr-${_p}.expected.yaml" 2>/dev/null)" "${_cr}"
done
for _p in cpuonly fullfeature; do
  _slim_route_cfg="$(_profile_cfg "${_p}" "${_p}-slim-route" '.splunk.caCertRef.name = "issuer-ca" | .splunk.aitkSlimOrigin = "https://slim.example:8443"')"
  assert_eq "${_p}: profile values preserve the CA reference and AITK origin" \
    "issuer-ca,https://slim.example:8443" \
    "$(_profile_run "${_slim_route_cfg}" render_ai_platform_profile_values | command yq eval '[.aiPlatformSpec.splunkConfiguration.caCertRef.name, .aiPlatformSpec.splunkConfiguration.aitkSlimOrigin] | join(",")' -)"
  assert_eq "${_p}: installed CR preserves route references with bundled Splunk disabled" \
    "issuer-ca,https://slim.example:8443" \
    "$(_render_cr "${_slim_route_cfg}" | command yq eval '[.spec.splunkConfiguration.caCertRef.name, .spec.splunkConfiguration.aitkSlimOrigin] | join(",")' -)"
done
# A numeric-only ServiceAccount name is a valid DNS name but must stay a YAML string in the CR.
_num_sa="$(_profile_cfg cpuonly numsa '.aiPlatform.features[1].serviceAccountName = "123"')"
assert_eq "a numeric-only serviceAccountName passes validation" "" "$(_profile_problems "${_num_sa}")"
_num_cr="${_PROFILE_TMP}/numsa-cr.yaml"
_render_cr "${_num_sa}" > "${_num_cr}"
assert_eq "a numeric-only serviceAccountName is rendered as a YAML string" "!!str" "$(command yq eval '.spec.features[1].serviceAccountName | tag' "${_num_cr}")"
# "no" / "yes" must stay YAML strings in the CR for the canonical profiles.
_bool_region="$(_profile_cfg cpuonly boolregion '.cluster.region = "no"')"
_render_cr "${_bool_region}" > "${_PROFILE_TMP}/boolregion-cr.yaml"
assert_eq "region \"no\" is rendered as a YAML string for cpuOnly" "!!str" "$(command yq eval '.spec.objectStorage.region | tag' "${_PROFILE_TMP}/boolregion-cr.yaml")"
_bool_sc="$(_profile_cfg fullfeature boolsc '.storage.storageClass = "yes"')"
_render_cr "${_bool_sc}" > "${_PROFILE_TMP}/boolsc-cr.yaml"
assert_eq "storageClass \"yes\" is rendered as a YAML string for fullfeature" "!!str" "$(command yq eval '.spec.storage.vectorDB.storageClassName | tag' "${_PROFILE_TMP}/boolsc-cr.yaml")"
_legacy_region="$(_profile_cfg fullfeature legacyregion '.aiPlatform.profile = "full"')"
assert_contains "legacy configs keep the unquoted region (output unchanged)" "    region: us-east-1" "$(_render_cr "${_legacy_region}")"
_cpu_cr="$(_render_cr "${_PROFILE_DIR}/profile-cpuonly.yaml")"
assert_contains "cpuOnly CR carries spec.profile: cpuOnly" "  profile: cpuOnly" "${_cpu_cr}"
for _forbidden in defaultAcceleratorType scaleFactor vectorDB workerGroupConfig gpuScheduler; do
  assert_eq "cpuOnly CR omits ${_forbidden}" "0" "$(printf '%s\n' "${_cpu_cr}" | grep -c "${_forbidden}:")"
done
_full_cr="$(_render_cr "${_PROFILE_DIR}/profile-fullfeature.yaml")"
assert_contains "fullfeature CR carries spec.profile: fullfeature" "  profile: fullfeature" "${_full_cr}"
assert_contains "fullfeature CR keeps the GPU scheduler" "gpuScheduler:" "${_full_cr}"
assert_eq "omitted profile leaves spec.profile out of the CR" "0" \
  "$(_render_cr "${_legacy}" | grep -c '^  profile:')"
assert_eq "legacy 'full' leaves spec.profile out of the CR" "0" \
  "$(_render_cr "${_full_saia}" | grep -c '^  profile:')"
assert_eq "cpuOnly CR has no orphaned GPU/scale comments" "0" \
  "$(printf '%s\n' "${_cpu_cr}" | grep -c 'GPU accelerator type\|Platform-wide capacity')"
assert_contains "fullfeature CR keeps the accelerator comment" "GPU accelerator type" "${_full_cr}"

# The command-line contract: a bad profile fails before any output, nonzero,
# and is never converted into the other profile.
_bad_cfg="$(_profile_cfg cpuonly cli-bad '.nodes.gpuWorkers = 1')"
_bad_file="${_PROFILE_TMP}/bad-values.yaml"
_bad_out="$(CONFIG_FILE="${_bad_cfg}" bash "${SCRIPT}" render-profile --output "${_bad_file}" 2>&1)"; _bad_rc=$?
assert_eq "render-profile exits nonzero on a conflicting profile" "1" "${_bad_rc}"
assert_eq "render-profile writes no file for an invalid profile" "no" "$([[ -e "${_bad_file}" ]] && echo yes || echo no)"
assert_contains "render-profile names the failing field and code" "[PROFILE_CONFLICT] nodes.gpuWorkers" "${_bad_out}"
assert_contains "render-profile does not convert the profile" "cpuOnly" "${_bad_out}"
_ok_file="${_PROFILE_TMP}/ok-values.yaml"
assert_rc "render-profile succeeds for the cpuOnly example" 0 \
  env CONFIG_FILE="${_PROFILE_DIR}/profile-cpuonly.yaml" bash "${SCRIPT}" render-profile --output "${_ok_file}"
assert_eq "render-profile --output equals the golden file" \
  "$(cat "${_PROFILE_GOLDEN}/profile-values-cpuonly.expected.yaml")" "$(cat "${_ok_file}" 2>/dev/null)"
_unsupported="$(_profile_cfg cpuonly cli-unsupported '.aiPlatform.profile = "gpu"')"
_unsupported_out="$(CONFIG_FILE="${_unsupported}" bash "${SCRIPT}" render-profile --output "${_PROFILE_TMP}/u.yaml" 2>&1)"; _unsupported_rc=$?
assert_eq "render-profile rejects an unsupported profile" "1" "${_unsupported_rc}"
assert_contains "unsupported profile reports PROFILE_UNSUPPORTED" "[PROFILE_UNSUPPORTED] aiPlatform.profile" "${_unsupported_out}"

# Air-gap: an invalid profile must fail BEFORE the staging step (which would
# otherwise download for ~15 minutes). The install command is run against a bad
# profile with cluster.airgap: true; it must stop at once and say nothing was staged.
_ag_cfg="$(_profile_cfg cpuonly airgap-bad '.cluster.airgap = true | .nodes.gpuWorkers = 2')"
_ag_out="$(CONFIG_FILE="${_ag_cfg}" LOG_DIR="${_PROFILE_TMP}/aglogs" bash "${SCRIPT}" install 2>&1)"; _ag_rc=$?
assert_eq "air-gapped install with an invalid profile exits nonzero" "1" "${_ag_rc}"
assert_contains "air-gapped install names the failing field before staging" "[PROFILE_CONFLICT] nodes.gpuWorkers" "${_ag_out}"
assert_contains "air-gapped install reports that nothing was staged" "nothing was staged" "${_ag_out}"
assert_eq "air-gapped install never starts staging" "0" "$(printf '%s' "${_ag_out}" | grep -c 'staging artifacts before')"
assert_eq "air-gapped preflight prints one Session log line" "1" "$(printf '%s' "${_ag_out}" | grep -c 'Session log:')"
_ag2_cfg="$(_profile_cfg cpuonly airgap-noip '.cluster.airgap = true | del(.nodes.existingIPs)')"
_ag2_out="$(CONFIG_FILE="${_ag2_cfg}" LOG_DIR="${_PROFILE_TMP}/aglogs2" bash "${SCRIPT}" install 2>&1)"; _ag2_rc=$?
assert_eq "an unrelated config error also stops before staging" "1" "${_ag2_rc}"
assert_contains "unrelated config error is reported as such" "could not be loaded for the pre-staging check" "${_ag2_out}"
assert_eq "unrelated config error is not blamed on the profile" "0" "$(printf '%s' "${_ag2_out}" | grep -c 'aiPlatform.profile is invalid')"

assert_eq "every deployment-profile test edit applied and changed its config" "" \
  "$(cat "${_PROFILE_TMP}/setup-failures" 2>/dev/null)"
rm -rf "${_PROFILE_TMP}"
# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo ""
if (( FAIL > 0 )); then
  exit 1
fi
