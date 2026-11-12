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
  kubectl() { cat >"${local_secret_capture}"; }
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
  eval "$(_extract_fn internal_splunk_management_url)"
  eval "$(_extract_fn internal_splunk_pod_name)"
  eval "$(_extract_fn _internal_splunk_btool_http_value)"
  eval "$(_extract_fn _detect_internal_splunk_hec_url)"
  eval "$(_extract_fn _read_internal_splunk_state)"
  eval "$(_extract_fn _apply_internal_splunk_standalone_cr)"
  eval "$(_extract_fn install_splunk_standalone)"
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
              ai_platform_profile_feature_problems ai_platform_profile_problems \
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
  assert_eq "${_p}: the AITK image is optional for now (MPR-188)" "" \
    "$(_profile_problems "$(_profile_cfg "${_p}" "${_p}-aitk" 'del(.images.aitk)')")"
  assert_problem "${_p}: missing SLIM image" \
    "$(_profile_cfg "${_p}" "${_p}-slim" 'del(.images.slim)')" "[PROFILE_MISSING_REFERENCE] images.slim.apiImage"
  assert_problem "${_p}: missing runtime base image" \
    "$(_profile_cfg "${_p}" "${_p}-base" 'del(.images.agentRuntime.baseImage)')" "[PROFILE_MISSING_REFERENCE] images.agentRuntime.baseImage"
  assert_problem "${_p}: missing schema image" \
    "$(_profile_cfg "${_p}" "${_p}-schema" 'del(.images.agentRuntime.schemaSetupImage)')" "[PROFILE_MISSING_REFERENCE] images.agentRuntime.schemaSetupImage"
  assert_problem "${_p}: missing provider/carrier image" \
    "$(_profile_cfg "${_p}" "${_p}-provider" 'del(.images.agentRuntime.providerImages)')" "[PROFILE_MISSING_REFERENCE] images.agentRuntime.providerImages.launchpad"
  assert_problem "${_p}: missing checkpoint Secret reference" \
    "$(_profile_cfg "${_p}" "${_p}-ckpt" 'del(.aiPlatform.features[1].checkpointDbSecretRef)')" "[PROFILE_MISSING_REFERENCE] aiPlatform.features[1].checkpointDbSecretRef"
  assert_problem "${_p}: missing provider loader module" \
    "$(_profile_cfg "${_p}" "${_p}-mod" 'del(.images.agentRuntime.providerModules)')" "[PROFILE_MISSING_REFERENCE] images.agentRuntime.providerModules.launchpad"
  assert_problem "${_p}: malformed provider loader module" \
    "$(_profile_cfg "${_p}" "${_p}-badmod" '.images.agentRuntime.providerModules.launchpad = "no_colon_here"')" "[PROFILE_INVALID_VALUE] images.agentRuntime.providerModules.launchpad"
  assert_problem "${_p}: provider loader module with a path is malformed" \
    "$(_profile_cfg "${_p}" "${_p}-pathmod" '.images.agentRuntime.providerModules.launchpad = "a/b:C"')" "[PROFILE_INVALID_VALUE] images.agentRuntime.providerModules.launchpad"
  assert_problem "${_p}: missing provider key" \
    "$(_profile_cfg "${_p}" "${_p}-prov" 'del(.aiPlatform.features[1].provider)')" "[PROFILE_MISSING_REFERENCE] aiPlatform.features[1].provider"
  assert_problem "${_p}: missing slim feature" \
    "$(_profile_cfg "${_p}" "${_p}-noslim" 'del(.aiPlatform.features[0])')" "the 'slim' feature is required"
  assert_problem "${_p}: missing agentruntime feature" \
    "$(_profile_cfg "${_p}" "${_p}-noar" 'del(.aiPlatform.features[1])')" "the 'agentruntime' feature is required"
  assert_problem "${_p}: whitespace in an image reference" \
    "$(_profile_cfg "${_p}" "${_p}-ws" '.images.aitk.image = "bad ref"')" "[PROFILE_INVALID_VALUE] images.aitk.image"
done

# Messages name fields and never echo credentials.
_creds="$(_profile_problems "$(_profile_cfg cpuonly creds '.storage.objectStore.auth.rootPassword = "s3cr3t-value" | .nodes.gpuWorkers = 1')")"
assert_eq "problem messages never echo credentials" "0" "$(printf '%s' "${_creds}" | grep -c 's3cr3t-value')"

# Compatibility rule: an omitted profile keeps pre-profile behaviour; "full"
# is the legacy spelling of fullfeature.
_legacy="$(_profile_cfg fullfeature legacy 'del(.aiPlatform.profile) | del(.images.aitk) | del(.aiPlatform.features)')"
assert_eq "omitted profile: no profile checks apply" "" "$(_profile_problems "${_legacy}")"
assert_eq "omitted profile resolves to fullfeature" "fullfeature" "$(_profile_run "${_legacy}" ai_platform_profile_resolved)"
assert_rc "omitted profile is not explicit" 1 _profile_run "${_legacy}" ai_platform_profile_explicit
assert_eq "legacy 'full' resolves to fullfeature" "fullfeature" \
  "$(_profile_run "$(_profile_cfg fullfeature fullalias '.aiPlatform.profile = "full"')" ai_platform_profile_resolved)"
assert_contains() { assert_eq "$1" "yes" "$([[ "$3" == *"$2"* ]] && echo yes || echo no)"; }
# Legacy "full" is valid but keeps pre-profile behaviour: it does not opt in to
# the Launchpad requirements, so an existing SAIA configuration that spells it
# keeps working.
_full_saia="$(_profile_cfg fullfeature full-saia '.aiPlatform.profile = "full" | del(.images.aitk) | del(.images.slim) | del(.images.agentRuntime) | .aiPlatform.features = [{"name": "saia", "version": "1.1.0"}]')"
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
  "$(_profile_cfg cpuonly dupprov '.aiPlatform.features += [.aiPlatform.features[1]]')" "duplicate feature 'agentruntime/launchpad'"
assert_problem "duplicate slim feature is a conflict" \
  "$(_profile_cfg cpuonly dupslim '.aiPlatform.features += [.aiPlatform.features[0]]')" "duplicate feature 'slim'"
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
  for _k in .images.agentRuntime.base .images.agentRuntime.schemaSetup .images.slim .images.aitk; do
    assert_eq "golden ${_p} values: ${_k} is a registry reference" "yes" \
      "$([[ "$(command yq eval "${_k}" "${_g}")" == registry.example.internal/* ]] && echo yes || echo no)"
  done
  assert_eq "golden ${_p} values: provider image present" "yes" \
    "$([[ "$(command yq eval '.images.agentRuntime.providers.launchpad' "${_g}")" == */ai-agent-runtime-provider-launchpad:* ]] && echo yes || echo no)"
  assert_eq "golden ${_p} values: provider module present" "yes" \
    "$([[ "$(command yq eval '.images.agentRuntime.modules.launchpad' "${_g}")" == *:* ]] && echo yes || echo no)"
  assert_eq "golden ${_p} values: no credential-looking keys" "0" "$(grep -ciE 'password|token|secretkey|apikey' "${_g}" | tr -d ' ')"
  assert_eq "golden ${_p} CR: valid YAML" "0" "$(command yq eval '.' "${_gc}" >/dev/null 2>&1; echo $?)"
  assert_eq "golden ${_p} CR: spec.profile" "${_want_profile}" "$(command yq eval '.spec.profile' "${_gc}")"
  assert_eq "golden ${_p} CR: kind" "AIPlatform" "$(command yq eval '.kind' "${_gc}")"
  assert_eq "golden ${_p} CR: has the slim and agentruntime features" "slim,agentruntime" "$(command yq eval '[.spec.features[].name] | join(",")' "${_gc}")"
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
