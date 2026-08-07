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
  eval "$(_extract_fn build_image_url)"
  eval "$(_extract_fn validate_image_config)"
  eval "$(_extract_fn configure_images)"
  eval "$(_extract_fn validate_scale_factor_config)"
  eval "$(_extract_fn object_store_auth_looks_like_placeholder)"
  eval "$(_extract_fn _pod_is_healthy)"
  eval "$(_extract_fn _classify_pod_failure)"
  eval "$(_extract_fn _print_pod_section)"
  eval "$(_extract_fn _print_unhealthy_pod_summary)"
}

_load_functions

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

assert_eq "L40S uses the default artifact manifest" \
  "model_artifacts_configs.yaml" "$(model_artifacts_config_name l40s)"

assert_eq "H100 uses the H100 artifact manifest" \
  "model_artifacts_configs_h100.yaml" "$(model_artifacts_config_name h100)"

assert_eq "RTX Pro 6000 uses the H100 artifact manifest" \
  "model_artifacts_configs_h100.yaml" "$(model_artifacts_config_name rtx_pro_6000_blackwell)"

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
    k0s_slim_feature_enabled() { return 1; }
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

# ── Tests: AIP-4614 internal Splunk HTTP compatibility ───────────────────────
# Execute the production installer functions with kubectl/yq mocked and inspect
# the YAML they actually render. This catches scheme, service-name, and YAML
# placement regressions that source-grep-only tests miss.

suite "AIP-4614 internal Splunk HTTP compatibility"
echo "▶ AIP-4614 internal Splunk HTTP compatibility"

_render_internal_splunk_http_manifests() (
  local capture_dir="$1"
  eval "$(_extract_fn internal_splunk_management_url)"
  eval "$(_extract_fn internal_splunk_hec_url)"
  eval "$(_extract_fn internal_splunk_pod_name)"
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
  _wait_for_internal_splunk_http() { :; }
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
    if [[ "${args}" == *' get standalone '* && "${args}" == *' -o json '* ]]; then
      echo '{"status":{"telAppInstalled":true,"phase":"Ready","message":""},"spec":{"extraEnv":[{"name":"KEEP_ME","value":"kept"}]}}'
      return 0
    fi
    if [[ "${args}" == *' get pods '* && "${args}" == *' -o json '* ]]; then
      echo '{"items":[]}'
      return 0
    fi
    if [[ "${args}" == *' get pod '* && "${args}" == *'metadata.uid'* ]]; then
      echo old-pod-uid
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
if _render_internal_splunk_http_manifests "${_AIP4614_TMPDIR}"; then
  _aip4614_render_rc=0
else
  _aip4614_render_rc=$?
fi
assert_eq "production installer functions render successfully" "0" "${_aip4614_render_rc}"

for _manifest in splunk-defaults standalone aiplatform; do
  assert_eq "rendered ${_manifest} manifest is non-empty" "1" \
    "$([[ -s "${_AIP4614_TMPDIR}/${_manifest}.yaml" ]] && echo 1 || echo 0)"
done

_expected_internal_url='http://splunk-fixture-splunk-standalone-service.fixture-ns.svc.cluster.local:8089'
_expected_internal_hec_url='https://splunk-fixture-splunk-standalone-service.fixture-ns.svc.cluster.local:8088'
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

assert_eq "oauth issuer renders the canonical HTTP service URL" \
  "${_expected_internal_url}" "${_rendered_issuer}"
assert_eq "AIPlatform endpoint renders the canonical HTTP service URL" \
  "${_expected_internal_url}" "${_rendered_endpoint}"
assert_eq "oauth issuer and AIPlatform endpoint are byte-identical" \
  "${_rendered_issuer}" "${_rendered_endpoint}"
assert_eq "OTel HEC endpoint renders separately on HTTPS port 8088" \
  "${_expected_internal_hec_url}" "${_rendered_hec_endpoint}"
assert_eq "Splunk OAuth issuer contains no HTTPS form" "0" \
  "$(grep -c 'issuer_uri: https://' "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "Standalone final manifest disables splunkd management TLS exactly once" "1" \
  "$(grep 'extraEnv:' "${_AIP4614_TMPDIR}/standalone.yaml" \
    | grep -c '"name":"SPLUNKD_SSL_ENABLE","value":"false"')"
assert_eq "Standalone final manifest preserves unrelated extraEnv entries" "1" \
  "$(grep 'extraEnv:' "${_AIP4614_TMPDIR}/standalone.yaml" \
    | grep -c '"name":"KEEP_ME","value":"kept"')"
assert_eq "OAuth signing certificate remains configured independently of transport TLS" "1" \
  "$(grep -c 'certFile: \$SPLUNK_HOME/etc/auth/server.pem' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "defaults register the idempotent stale-TLS migration pre-task" "1" \
  "$(grep -c 'file:///mnt/defaults/remove-stale-installer-tls.yml' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "migration disables persisted Splunk management TLS" "1" \
  "$(grep -c 'section: sslConfig, option: enableSplunkdSSL, value: "false"' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "migration restores Splunk Web HTTP when preview TLS paths are present" "1" \
  "$(grep -c 'section: settings, option: enableSplunkWebSSL, value: "false"' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "migration does not change the independent HEC TLS switch" "0" \
  "$(grep -c 'section: http, option: enableSSL' \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"
assert_eq "migration is limited to the installer-owned legacy mount prefix" "2" \
  "$(grep -c "lookup('file', item.path, errors='ignore') | default('', true)" \
    "${_AIP4614_TMPDIR}/splunk-defaults.yaml")"

_render_splunk_bootstrap_manifest "${_AIP4614_TMPDIR}/bootstrap-standalone.yaml"
assert_eq "fresh-install bootstrap preserves unrelated extraEnv entries" "1" \
  "$(grep 'extraEnv:' "${_AIP4614_TMPDIR}/bootstrap-standalone.yaml" \
    | grep -c '"name":"KEEP_ME","value":"kept"')"
assert_eq "fresh-install bootstrap temporarily removes only the splunkd HTTP override" "0" \
  "$(grep 'extraEnv:' "${_AIP4614_TMPDIR}/bootstrap-standalone.yaml" \
    | grep -c 'SPLUNKD_SSL_ENABLE')"
assert_eq "telemetry bootstrap wait precedes the final HTTP apply" "1" \
  "$(awk '
    /_wait_for_splunk_telemetry_bootstrap 600/ { waited=NR }
    /_apply_internal_splunk_standalone_cr.*http/ { applied=NR }
    END { print (waited > 0 && applied > waited) ? 1 : 0 }
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
  _wait_for_internal_splunk_http() {
    printf 'wait-http:%s\n' "$1" >>"${event_file}"
  }

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
          echo '{"status":{"telAppInstalled":true},"spec":{"extraEnv":[{"name":"SPLUNKD_SSL_ENABLE","value":"false"}]}}'
          return 0
          ;;
        *)
          echo '{"status":{"telAppInstalled":true},"spec":{"extraEnv":[{"name":"KEEP_ME","value":"kept"}]}}'
          return 0
          ;;
      esac
    fi
    if [[ "${args}" == *' get pod '* && "${args}" == *'metadata.uid'* ]]; then
      echo old-pod-uid
      return 0
    fi
    if [[ "${args}" == *' apply '* && "${args}" == *' -f - '* ]]; then
      body="$(cat)"
      if [[ "${body}" == *'kind: Standalone'* ]]; then
        if [[ "${body}" == *'"name":"SPLUNKD_SSL_ENABLE","value":"false"'* ]]; then
          printf 'http\n' >>"${event_file}"
        else
          printf 'bootstrap\n' >>"${event_file}"
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
assert_rc "fresh install executes bootstrap then final HTTP state" 0 \
  _exercise_internal_splunk_install_flow fresh "${_fresh_events}"
assert_eq "fresh install ordering is bootstrap, telemetry wait, HTTP, rollout wait" \
  $'bootstrap\nwait-telemetry\nhttp\nwait-http:old-pod-uid' \
  "$(cat "${_fresh_events}")"

_upgrade_events="${_AIP4614_TMPDIR}/upgrade.events"
assert_rc "existing TLS upgrade goes directly to final HTTP state" 0 \
  _exercise_internal_splunk_install_flow existing "${_upgrade_events}"
assert_eq "existing TLS upgrade requires replacement pod UID" \
  $'http\nwait-http:old-pod-uid' "$(cat "${_upgrade_events}")"

_idempotent_events="${_AIP4614_TMPDIR}/idempotent.events"
assert_rc "already-HTTP rerun remains idempotent" 0 \
  _exercise_internal_splunk_install_flow idempotent "${_idempotent_events}"
assert_eq "already-HTTP rerun does not require a pod UID change" \
  $'http\nwait-http:' "$(cat "${_idempotent_events}")"

_forbidden_events="${_AIP4614_TMPDIR}/forbidden.events"
assert_rc "Standalone API/RBAC read failure aborts the installer" 1 \
  _exercise_internal_splunk_install_flow forbidden "${_forbidden_events}"
assert_eq "read failure never applies a Standalone manifest" "" \
  "$(cat "${_forbidden_events}")"

rm -rf "${_AIP4614_TMPDIR}"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo ""
if (( FAIL > 0 )); then
  exit 1
fi
