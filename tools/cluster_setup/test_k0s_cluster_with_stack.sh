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
# everywhere — config generation, yq update, install command, and verification.

suite "k0s config path"

assert_eq "config create writes to /etc/k0s/k0s.yaml" \
  "0" "$(grep -c '/tmp/k0s\.yaml' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "k0s install controller uses /etc/k0s/k0s.yaml" \
  "1" "$(grep -c 'k0s install controller.*--config /etc/k0s/k0s.yaml' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "generated config is installed atomically at /etc/k0s/k0s.yaml" \
  "1" "$(grep -c 'mv -f.*remote_staged_config.*etc/k0s/k0s.yaml' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "remote config generation no longer depends on PyYAML" \
  "0" "$(grep -cE 'import yaml|python3-pyyaml|k0s-config-update.py' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "verify step uses /etc/k0s/k0s.yaml" \
  "1" "$(grep -c 'grep.*api.*etc/k0s/k0s.yaml' "${SCRIPT}" | tr -d '[:space:]')"

# ── Tests: k0s advertised API address ────────────────────────────────────────

suite "k0s advertised API address"

assert_eq "optional external API address is loaded from config" \
  "1" "$(grep -c 'K0S_API_EXTERNAL_ADDRESS=.*cluster.apiExternalAddress' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "configured external API address is included in certificate SANs" \
  "2" "$(grep -c 'strenv(K0S_EFFECTIVE_EXTERNAL_ADDRESS)' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "configured external API address takes precedence over the private address" \
  "1" "$(grep -c 'effective_external_address=.*K0S_API_EXTERNAL_ADDRESS:-.*internal_address' "${SCRIPT}" | tr -d '[:space:]')"

# ── Tests: kine compaction ─────────────────────────────────────────────────────
# Verify that the generated k0s config passes --compact-interval to kine via
# extraArgs (the only valid path — KineConfig has no compactInterval field).

suite "kine compaction"

assert_eq "kine compact-interval passed via extraArgs" \
  "1" "$(grep -c "extraArgs.*compact-interval\|compact-interval.*5m" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "yq writes compact-interval through the kine extraArgs map" \
  "1" "$(grep -c 'storage.kine.extraArgs."compact-interval" = "5m"' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "network provider is still set to calico" \
  "1" "$(grep -c 'spec.network.provider = "calico"' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "storage type is still set to kine" \
  "1" "$(grep -c 'spec.storage.type = "kine"' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "no bare compactInterval field (would be silently ignored by k0s)" \
  "0" "$(grep -c 'compactInterval' "${SCRIPT}" | tr -d '[:space:]')"

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

# ── Tests: AIP-4614 Splunk TLS cert provisioning (provision_splunk_cert) ──────
# Covers the cert-manager selfSigned→CA→CA-Issuer→leaf chain that provisions a
# hostname-correct Splunk server cert, and the caCertRef wiring that lets SAIA
# trust it instead of skipping TLS verification.

suite "provision_splunk_cert"

assert_eq "gated on SPLUNK_MODE != internal (early return)" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -A2 'SPLUNK_MODE.*!= .internal.' | grep -c 'return 0')"

assert_eq "waits for cert-manager webhook before applying the chain" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c 'wait_for_cert_manager_webhook')"

assert_eq "derives the Standalone service name from AI_STANDALONE_NAME (operator's GetSplunkServiceName)" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c 'svc="splunk-\${AI_STANDALONE_NAME}-standalone-service"')"

assert_eq "derives the headless service name from AI_STANDALONE_NAME" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c 'headless="splunk-\${AI_STANDALONE_NAME}-standalone-headless"')"

assert_eq "selfSigned root Issuer is defined and referenced by the CA cert's issuerRef" \
  "2" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c 'name: ai-splunk-selfsigned')"

assert_eq "CA Certificate is isCA and stored in ai-splunk-ca-tls" \
  "1" "$(awk '/name: ai-splunk-ca$/{f=1} f && /secretName: ai-splunk-ca-tls/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-ca-tls')"

assert_eq "root CA has a conservative ten-year duration and one-year renewal window" \
  "2" "$(awk '/name: ai-splunk-ca$/{f=1} f && /^---/{exit} f' "${SCRIPT}" | grep -cE 'duration: 87600h|renewBefore: 8760h')"

assert_eq "root CA keeps its ECDSA key across renewal" \
  "1" "$(awk '/name: ai-splunk-ca$/{f=1} f && /^---/{exit} f' "${SCRIPT}" | grep -c 'rotationPolicy: Never')"

assert_eq "CA Issuer chains off the ai-splunk-ca-tls secret" \
  "1" "$(awk '/name: ai-splunk-ca-issuer/{f=1} f && /secretName: ai-splunk-ca-tls/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-ca-tls')"

assert_eq "leaf Certificate ai-splunk-server writes to ai-splunk-server-tls" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /secretName: ai-splunk-server-tls/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-server-tls')"

assert_eq "leaf cert issued by the CA issuer (not the selfsigned root)" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /issuerRef:/{g=1} f && g && /name: ai-splunk-ca-issuer/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-ca-issuer')"

assert_eq "leaf cert SANs cover both the standalone service and headless service (short/ns/svc/cluster.local forms)" \
  "8" "$(awk '/name: ai-splunk-server$/{f=1} f && /^---/{exit} f' "${SCRIPT}" | grep -cE '\$\{svc\}|\$\{headless\}')"

assert_eq "leaf cert uses only cert-manager's standard Secret outputs" \
  "0" "$(awk '/name: ai-splunk-server$/{f=1} f && /^YAML$/{exit} f' "${SCRIPT}" | grep -c 'additionalOutputFormats:')"

assert_eq "leaf cert has an explicit 90d duration / 30d renewBefore (Part G.1)" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /^---/{exit} f' "${SCRIPT}" | grep -c 'duration: 2160h')"

assert_eq "leaf uses a rotating Splunk-compatible RSA-2048 key" \
  "3" "$(awk '/name: ai-splunk-server$/{f=1} f && /^YAML$/{exit} f' "${SCRIPT}" | grep -cE 'algorithm: RSA|size: 2048|rotationPolicy: Always')"

assert_eq "leaf supports Splunk management and KV Store server/client roles" \
  "4" "$(awk '/name: ai-splunk-server$/{f=1} f && /^YAML$/{exit} f' "${SCRIPT}" | grep -cE '^    - (digital signature|key encipherment|server auth|client auth)$')"

assert_eq "installer warns that splunkd needs a controlled restart after renewal" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c 'rerun the installer after ai-splunk-server renews')"

_WAIT_SPLUNK_BODY() { awk '/^wait_for_splunk_standalone\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }

assert_eq "Splunk readiness waits for the operator's exact singleton pod name" \
  "1" "$(_WAIT_SPLUNK_BODY | grep -c 'splunk-${AI_STANDALONE_NAME}-standalone-0')"

assert_eq "Splunk readiness timeout is fatal rather than swallowed" \
  "1" "$(_WAIT_SPLUNK_BODY | grep -A2 'condition=Ready' | grep -c 'err ' )"

assert_eq "loaded TLS fingerprint is recorded only after the real readiness gate" \
  "ready-before-hash" "$(_WAIT_SPLUNK_BODY | awk '
    /condition=Ready/{ready=NR}
    /loaded-tls-sha256/{hash=NR}
    END {print (ready > 0 && hash > ready) ? "ready-before-hash" : "wrong-order"}
  ')"

assert_eq "waits for the leaf cert to reach Ready before returning" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c -e 'kubectl wait --for=condition=Ready certificate/ai-splunk-server')"

assert_eq "orchestrator provisions the cert before the Standalone CR is applied (cert must exist first)" \
  "1" "$(awk '/provision_splunk_cert$/{p=NR} /install_splunk_standalone$/{s=NR} END{print(p > 0 && s > 0 && p < s)}' "${SCRIPT}")"

assert_eq "orchestrator provisions the cert after image pull secrets exist (SA needs ECR creds first)" \
  "1" "$(awk '/create_image_pull_secrets "\$\{AI_NS\}"/{c=NR} /provision_splunk_cert$/{p=NR} END{print(c > 0 && p > 0 && c < p)}' "${SCRIPT}")"

# ── Tests: Splunk certificate-first PEM and HTTPS listeners ───────────────────

suite "Splunk Standalone TLS defaults"

_SPLUNK_STANDALONE_BODY() { awk '/^install_splunk_standalone\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }

assert_eq "registers the supported Splunk-Ansible PEM assembly pre-task" \
  "1" "$(_SPLUNK_STANDALONE_BODY | grep -c 'file:///mnt/defaults/prepare-server-pem.yml')"

assert_eq "assembles server.pem in certificate-then-private-key order" \
  "1" "$(_SPLUNK_STANDALONE_BODY | grep -c 'cat /mnt/splunk-cert-source/tls.crt /mnt/splunk-cert-source/tls.key > /mnt/splunk-certs/server.pem.tmp')"

assert_eq "atomically installs server.pem with restrictive permissions" \
  "2" "$(_SPLUNK_STANDALONE_BODY | grep -cE 'chmod 0600 .*server.pem.tmp|mv -f .*server.pem.tmp .*server.pem')"

assert_eq "suppresses private PEM task output" \
  "1" "$(_SPLUNK_STANDALONE_BODY | grep -c 'no_log: true')"

assert_eq "splunkd, HEC explicit config, and OAuth use the prepared certificate-first PEM" \
  "3" "$(_SPLUNK_STANDALONE_BODY | grep -cE '(serverCert|certFile): /mnt/splunk-certs/server.pem')"

assert_eq "Splunk Web uses separate projected certificate and key files" \
  "2" "$(_SPLUNK_STANDALONE_BODY | grep -cE '(serverCert: /mnt/splunk-cert-source/tls.crt|privKeyPath: /mnt/splunk-cert-source/tls.key)')"

assert_eq "Splunk and Web trust the projected CA" \
  "2" "$(_SPLUNK_STANDALONE_BODY | grep -cE '(sslRootCAPath|caCertPath): /mnt/splunk-cert-source/ca.crt')"

assert_eq "Splunk-Ansible management TLS fields preserve the prepared PEM and CA" \
  $'      ssl:\n        enable: true\n        cert: /mnt/splunk-certs/server.pem\n        password: ""\n        ca: /mnt/splunk-cert-source/ca.crt' \
  "$(_SPLUNK_STANDALONE_BODY | sed -n '/^      ssl:$/,/^      hec:$/p' | sed '$d')"

assert_eq "Splunk-Ansible HEC fields preserve HTTPS and the prepared PEM" \
  $'      hec:\n        enable: true\n        ssl: true\n        port: 8088\n        cert: /mnt/splunk-certs/server.pem\n        password: ""' \
  "$(_SPLUNK_STANDALONE_BODY | sed -n '/^      hec:$/,/^      http_enableSSL:/p' | sed '$d')"

assert_eq "does not mix in the deprecated HEC TLS input" \
  "0" "$(_SPLUNK_STANDALONE_BODY | grep -c 'hec_enableSSL:')"

assert_eq "Splunk-Ansible Web fields preserve the separate certificate and key" \
  "4" "$(_SPLUNK_STANDALONE_BODY | grep -cE '^      http_enableSSL(:|_cert:|_privKey:|_privKey_password:)')"

assert_eq "HEC uses the same prepared server certificate" \
  "1" "$(_SPLUNK_STANDALONE_BODY | awk '/key: inputs/{f=1} f && /key: authentication/{exit} f' | grep -c 'serverCert: /mnt/splunk-certs/server.pem')"

assert_eq "explicit HEC inputs config also enables TLS" \
  "1" "$(_SPLUNK_STANDALONE_BODY | awk '/key: inputs/{f=1} f && /key: authentication/{exit} f' | grep -c 'enableSSL: 1')"

assert_eq "projects exactly tls.crt, tls.key, and ca.crt from the leaf Secret" \
  "3" "$(_SPLUNK_STANDALONE_BODY | awk '/^    - name: splunk-cert-source$/{f=1; next} f && /^    - name: splunk-certs$/{exit} f' | grep -c '^          - key:')"

assert_eq "prepared PEM is written to a bounded, memory-backed emptyDir" \
  "2" "$(_SPLUNK_STANDALONE_BODY | grep -A3 '^    - name: splunk-certs$' | grep -cE 'medium: Memory|sizeLimit: 1Mi')"

# ── Tests: caCertRef wiring into the AIPlatform CR (internal Splunk mode) ────
# So SAIA/SLIM trust the cert-manager-issued CA instead of skipping TLS
# verification against Splunk's HEC/management endpoints (AIP-4614 Part C).

suite "caCertRef wiring (install_ai_platform_cr, internal mode)"

# Scope to install_ai_platform_cr's body — "internal)"/"external)" also appear
# as case labels in validate_image_config() earlier in the file.
_AIPC_BODY() { awk '/^install_ai_platform_cr\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }

assert_eq "internal-mode splunkConfiguration includes a caCertRef" \
  "1" "$(_AIPC_BODY | awk '/^ *internal\)$/{f=1} f && /;;/{exit} f' | grep -c 'caCertRef:')"

assert_eq "caCertRef points at the cert provisioned by provision_splunk_cert (ai-splunk-server-tls)" \
  "1" "$(_AIPC_BODY | awk '/^ *internal\)$/{f=1} f && /;;/{exit} f' | grep -c 'name: ai-splunk-server-tls')"

assert_eq "caCertRef key matches the leaf Certificate's default CA output key (ca.crt)" \
  "1" "$(_AIPC_BODY | awk '/^ *internal\)$/{f=1} f && /;;/{exit} f' | grep -c 'key: ca.crt')"

assert_eq "disabled mode does not set caCertRef (no Splunk to trust at all)" \
  "0" "$(_AIPC_BODY | awk '/^ *\*\)$/{f=1} /;;/{f=0} f' | grep -c 'caCertRef:')"

# ── Tests: caCertRef wiring into the AIPlatform CR (external Splunk mode) ────
# Part E — a customer-supplied CA for a private/internal external Splunk, only
# emitted when splunk.external.caCertSecretName is set. Left unset, SAIA falls
# back to its image's system trust store (correct for publicly-trusted certs).

suite "caCertRef wiring (install_ai_platform_cr, external mode)"

_AIPC_EXTERNAL_BODY() { _AIPC_BODY | awk '/^ *external\)$/{f=1} f && /;;/{exit} f'; }

assert_eq "config parser reads splunk.external.caCertSecretName via yq" \
  "1" "$(grep -c 'yq eval .\.splunk\.external\.caCertSecretName' "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "external-mode caCertRef emission is gated on SPLUNK_EXTERNAL_CA_SECRET_NAME being set" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'if \[\[ -n \"\${SPLUNK_EXTERNAL_CA_SECRET_NAME}\" \]\]')"

assert_eq "external-mode caCertRef uses the customer-supplied secret name (not a hardcoded one)" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'name: \${SPLUNK_EXTERNAL_CA_SECRET_NAME}')"

assert_eq "external-mode caCertRef key matches the documented convention (ca.crt)" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'key: ca.crt')"

assert_eq "external-mode caCertRef fragment is interpolated into splunk_config_yaml (not dropped)" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'external_ca_cert_yaml}\${trusted_issuers_yaml}')"

# ── Tests: cert-manager installation/readiness ───────────────────────────────

suite "cert-manager installation readiness"

_CM_INSTALL_BODY() { awk '/^install_cert_manager\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }
_CM_WEBHOOK_BODY() { awk '/^wait_for_cert_manager_webhook\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }

assert_eq "installs the pinned cert-manager manifest" \
  "1" "$(_CM_INSTALL_BODY | grep -c 'releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml')"

assert_eq "cert-manager is pinned to a supported patch release" \
  "1" "$(grep -c '^CERT_MANAGER_VERSION="v1.21.1"$' "${SCRIPT}")"

assert_eq "k0s is pinned instead of floating to latest" \
  "1" "$(grep -c '^DEFAULT_K0S_VERSION="v1.33.13+k0s.1"$' "${SCRIPT}")"

assert_eq "cert-manager install gates the supported Kubernetes minor range" \
  "1" "$(_CM_INSTALL_BODY | grep -c 'kubernetes_minor} < 33.*kubernetes_minor} > 36')"

assert_eq "cert-manager refuses automatic takeover or multi-minor upgrades" \
  "1" "$(_CM_INSTALL_BODY | grep -c 'automatic takeover is disabled')"

assert_eq "waits for the Certificate CRD" \
  "1" "$(_CM_INSTALL_BODY | grep -c 'wait_for_crd certificates.cert-manager.io 300')"

assert_eq "waits for all three cert-manager Deployment rollouts" \
  "3" "$(_CM_INSTALL_BODY | grep -c 'kubectl rollout status deployment/cert-manager')"

assert_eq "waits for cert-manager and webhook pods to become ready" \
  "2" "$(_CM_INSTALL_BODY | grep -c 'kubectl wait --for=condition=ready pod')"

assert_eq "does not mutate cert-manager Deployment arguments" \
  "0" "$(_CM_INSTALL_BODY | grep -c 'kubectl patch deployment')"

assert_eq "webhook readiness uses a server-side Certificate admission check" \
  "1" "$(_CM_WEBHOOK_BODY | grep -c 'kubectl apply --dry-run=server')"

assert_eq "webhook admission check uses the standard Certificate fields" \
  "0" "$(_CM_WEBHOOK_BODY | grep -c 'additionalOutputFormats:')"

assert_eq "phase 1 treats cert-manager failure as fatal" \
  "1" "$(grep -c 'phase1_names\[\$i\].*cert-manager' "${SCRIPT}" | tr -d '[:space:]')"

_cert_manager_install_case() {
  local mode="$1" mock_kubernetes_minor="$2" existing_version="${3:-}"
  (
    mock_cm_applied="false"
    log() { :; }
    warn() { :; }
    err() { exit 97; }
    wait_for_crd() { :; }
    kubectl() {
      local args="$*"
      case "${args}" in
        "version -o json")
          printf '{"serverVersion":{"major":"1","minor":"%s"}}\n' "${mock_kubernetes_minor}"
          ;;
        "-n cert-manager get deployment "*" --ignore-not-found -o json")
          if [[ "${mode}" == "existing" || "${mode}" == "mixed" || \
                "${mock_cm_applied}" == "true" ]]; then
            local deployment container component_version="${existing_version:-${CERT_MANAGER_VERSION}}"
            deployment="${args#-n cert-manager get deployment }"
            deployment="${deployment% --ignore-not-found -o json}"
            case "${deployment}" in
              cert-manager) container=cert-manager-controller ;;
              cert-manager-webhook) container=cert-manager-webhook ;;
              cert-manager-cainjector)
                container=cert-manager-cainjector
                [[ "${mode}" == "mixed" ]] && component_version=v1.20.0
                ;;
            esac
            [[ "${mode}" == "manifest-old" ]] && component_version=v1.13.0
            printf '{"spec":{"template":{"spec":{"containers":[{"name":"%s","image":"quay.io/jetstack/%s:%s"}]}}}}\n' \
              "${container}" "${container}" "${component_version}"
          fi
          ;;
        create\ --dry-run=client\ --validate=false\ -f\ *\ -o\ json)
          local manifest_version="${CERT_MANAGER_VERSION}"
          [[ "${mode}" == "manifest-old" ]] && manifest_version=v1.13.0
          printf '{"kind":"List","items":['
          printf '{"kind":"Deployment","metadata":{"name":"cert-manager","namespace":"cert-manager"},"spec":{"template":{"spec":{"containers":[{"name":"cert-manager-controller","image":"quay.io/jetstack/cert-manager-controller:%s"}]}}}},' "${manifest_version}"
          printf '{"kind":"Deployment","metadata":{"name":"cert-manager-webhook","namespace":"cert-manager"},"spec":{"template":{"spec":{"containers":[{"name":"cert-manager-webhook","image":"quay.io/jetstack/cert-manager-webhook:%s"}]}}}},' "${manifest_version}"
          printf '{"kind":"Deployment","metadata":{"name":"cert-manager-cainjector","namespace":"cert-manager"},"spec":{"template":{"spec":{"containers":[{"name":"cert-manager-cainjector","image":"quay.io/jetstack/cert-manager-cainjector:%s"}]}}}},' "${manifest_version}"
          printf '{"kind":"CustomResourceDefinition","metadata":{"name":"certificates.cert-manager.io"}},'
          printf '{"kind":"ValidatingWebhookConfiguration","metadata":{"name":"cert-manager-webhook"}}]}'
          ;;
        "get CustomResourceDefinition certificates.cert-manager.io --ignore-not-found -o name")
          [[ "${mode}" == "partial" ]] && \
            printf '%s\n' 'customresourcedefinition.apiextensions.k8s.io/certificates.cert-manager.io'
          ;;
        "get ValidatingWebhookConfiguration cert-manager-webhook --ignore-not-found -o name")
          [[ "${mode}" == "partial-other" ]] && \
            printf '%s\n' 'validatingwebhookconfiguration.admissionregistration.k8s.io/cert-manager-webhook'
          ;;
        apply\ -f\ *)
          mock_cm_applied="true"
          printf '%s\n' APPLY
          ;;
        "-n cert-manager get endpoints cert-manager-webhook -o jsonpath={.subsets[0].addresses[0].ip}")
          printf '%s\n' 10.0.0.2
          ;;
      esac
      return 0
    }
    CERT_MANAGER_VERSION="v1.21.1"
    eval "$(_extract_fn install_cert_manager)"
    install_cert_manager
  )
}

assert_eq "fresh supported clusters apply the pinned cert-manager manifest" \
  "1" "$(_cert_manager_install_case fresh 33 | grep -c '^APPLY$')"

assert_rc "fresh supported cert-manager install completes successfully" \
  0 _cert_manager_install_case fresh 33

assert_eq "an exact existing cert-manager is reused without takeover" \
  "0" "$(_cert_manager_install_case existing 33 v1.21.1 | grep -c '^APPLY$')"

assert_rc "an exact existing cert-manager reuse completes successfully" \
  0 _cert_manager_install_case existing 33 v1.21.1

assert_rc "unsupported Kubernetes versions are rejected before cert-manager apply" \
  97 _cert_manager_install_case fresh 32

assert_rc "old cert-manager installations require an explicit sequential upgrade" \
  97 _cert_manager_install_case existing 33 v1.13.0

assert_rc "mixed-version cert-manager components are rejected" \
  97 _cert_manager_install_case mixed 33 v1.21.1

assert_rc "a stale supplied cert-manager manifest cannot bypass the live-image gate" \
  97 _cert_manager_install_case manifest-old 33

assert_eq "a stale supplied cert-manager manifest is rejected before apply" \
  "0" "$(_cert_manager_install_case manifest-old 33 | grep -c '^APPLY$')"

assert_rc "partial cert-manager installations are not adopted" \
  97 _cert_manager_install_case partial 33

assert_rc "partial cert-manager webhook/RBAC-era objects are not adopted" \
  97 _cert_manager_install_case partial-other 33

# ── Tests: air-gap bundle contract ───────────────────────────────────────────

suite "air-gap bundle compatibility contract"

AIRGAP_WRAPPER="${SCRIPT_DIR}/install_from_airgap_bundle.sh"
AIRGAP_BUILDER="${SCRIPT_DIR}/prepare_airgap_bundle.sh"
airgap_config_guard_line="$(grep -n '^EFFECTIVE_CONFIG_FILE=' "${AIRGAP_WRAPPER}" | head -1 | cut -d: -f1)"
airgap_host_mutation_line="$(grep -n '^# No bundle/config incompatibility remains' "${AIRGAP_WRAPPER}" | head -1 | cut -d: -f1)"

assert_eq "air-gap config/image rejection runs before host binary mutation" \
  "true" "$([[ -n "${airgap_config_guard_line}" && -n "${airgap_host_mutation_line}" && \
    ${airgap_config_guard_line} -lt ${airgap_host_mutation_line} ]] && echo true || echo false)"
assert_eq "wrapper requires the exact cert-manager compatibility pin" \
  "1" "$(grep -c '^EXPECTED_CERT_MANAGER_VERSION="v1.21.1"$' "${AIRGAP_WRAPPER}")"
assert_eq "generated manual environment enables air-gap image staging" \
  "2" "$(grep -Ec 'export (AIRGAP_MODE="true"|AIRGAP_K0S_IMAGE_DIR=)' "${AIRGAP_BUILDER}")"
assert_eq "generated manual environment exports verified ingress image metadata" \
  "2" "$(grep -Ec 'export BUNDLE_(INGRESS_ENABLED|TRAEFIK_IMAGE)=' "${AIRGAP_BUILDER}")"
assert_eq "main installer rechecks a sourced bundle contract" \
  "1" "$(awk '/^load_config\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c 'AIRGAP_MODE.*AIRGAP_BUNDLE_VERSION_FILE')"

assert_eq "Splunk certificate readiness failure is fatal instead of warning-only" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -A3 'condition=Ready certificate/ai-splunk-server' | grep -c 'err ' )"

assert_eq "Splunk TLS Secret readiness checks exactly the three source keys" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c '\["tls.crt", "tls.key", "ca.crt"\]')"

assert_eq "Splunk TLS restart recovers when its OnDelete pod is already absent" \
  "1" "$(awk '/^install_splunk_standalone\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep 'delete "pod/\${splunk_pod}"' | grep -c -- '--ignore-not-found')"

# ── Tests: external Splunk management/HEC endpoint split ───────────────────────

suite "external Splunk endpoint split"

assert_eq "config parser reads explicit external management endpoint" \
  "1" "$(grep -c "yq eval '.splunk.external.managementEndpoint" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "config parser reads explicit external HEC endpoint" \
  "1" "$(grep -c "yq eval '.splunk.external.hecEndpoint" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "legacy external.endpoint is retained only as a deprecated parser alias" \
  "1" "$(grep -c "yq eval '.splunk.external.endpoint" "${SCRIPT}" | tr -d '[:space:]')"

assert_eq "external CR endpoint is management/JWKS URL" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c '^    endpoint: ${SPLUNK_EXTERNAL_MANAGEMENT_ENDPOINT}')"

assert_eq "external CR hecEndpoint is distinct HEC URL" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'hecEndpoint: ${SPLUNK_EXTERNAL_HEC_ENDPOINT}')"

assert_eq "external rendering fails if either required endpoint is absent" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'requires both splunk.external.managementEndpoint and splunk.external.hecEndpoint')"


# ── Tests: Traefik HTTPS ingress (rendered contract) ──────────────────────────
# TRAEFIK_HTTPS_DESIGN.md / TRAEFIK_HTTPS_SETUP.md — additive, opt-in HTTPS
# access to SAIA/Splunk Web via a Traefik v3 DaemonSet.

suite "Traefik rendered contract"

TRAEFIK_TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TRAEFIK_TEST_TMP}"' EXIT

_traefik_parse_mgmt_flag() {
  local raw_value="$1" value_tag="${2:-!!bool}" parser_body
  parser_body="$(awk '
    /^  INGRESS_SPLUNKMGMT_ENABLED=/ { capture=1 }
    capture {
      done = ($0 == "  fi")
      sub(/^  /, "")
      print
      if (done) exit
    }
  ' "${SCRIPT}")"

  (
    yq() {
      if [[ "$*" == *"| tag"* ]]; then
        printf '%s\n' "${value_tag}"
      else
        printf '%s\n' "${raw_value}"
      fi
    }
    err() { exit 97; }
    CONFIG_FILE="unused-by-yq-stub"
    INGRESS_ENABLED="true"
    eval "${parser_body}"
    printf '%s\n' "${INGRESS_SPLUNKMGMT_ENABLED}"
  )
}

_traefik_validate_port_fragment() {
  local saia_port="$1" splunkweb_port="$2" splunkmgmt_port="$3"
  local splunk_mode="${4:-internal}" mgmt_enabled="${5:-false}"

  (
    err() { exit 97; }
    eval "$(_extract_fn validate_ingress_entrypoint_ports_k0s)"
    INGRESS_SAIA_PORT="${saia_port}"
    INGRESS_SPLUNKWEB_PORT="${splunkweb_port}"
    INGRESS_SPLUNKMGMT_PORT="${splunkmgmt_port}"
    SPLUNK_MODE="${splunk_mode}"
    INGRESS_SPLUNKMGMT_ENABLED="${mgmt_enabled}"
    validate_ingress_entrypoint_ports_k0s
  )
}

assert_eq "explicit splunkMgmt.enabled=false remains false" \
  "false" "$(_traefik_parse_mgmt_flag false)"

assert_eq "missing splunkMgmt.enabled defaults to false" \
  "false" "$(_traefik_parse_mgmt_flag null '!!null')"

assert_rc "config parser rejects Traefik's reserved health port 9000" \
  97 _traefik_validate_port_fragment 9443 9000 9089

assert_rc "disabled management listener ignores an inert reserved port" \
  0 _traefik_validate_port_fragment 9443 9001 9000 internal false

assert_rc "external Splunk mode ignores inert Splunk listener ports" \
  0 _traefik_validate_port_fragment 9443 9000 9000 external false

assert_rc "active listener ports must remain unique" \
  97 _traefik_validate_port_fragment 9443 9443 9089 internal false

assert_rc "management listener cannot be enabled without internal Splunk" \
  97 _traefik_validate_port_fragment 9443 9001 9089 external true

_traefik_validate_ip_literal() {
  (
    eval "$(_extract_fn ingress_ip_literal_k0s)"
    ingress_ip_literal_k0s "$1"
  )
}

assert_rc "IPv4 ingress targets are accepted" 0 \
  _traefik_validate_ip_literal 10.0.0.11
assert_rc "IPv6 ingress targets are accepted" 0 \
  _traefik_validate_ip_literal 2001:db8::11
assert_rc "hostname values cannot be interpolated as Certificate IP SANs" 1 \
  _traefik_validate_ip_literal worker.example.test
assert_rc "YAML-like node values cannot reach Certificate interpolation" 1 \
  _traefik_validate_ip_literal $'10.0.0.11\n  dnsNames: [attacker.test]'

_traefik_render_case() {
  local output_dir="$1" ingress_enabled="$2" splunk_mode="$3"
  local mgmt_enabled="$4" failure="${5:-none}"
  mkdir -p "${output_dir}"

  (
    log() { :; }
    warn() { :; }
    err() { exit 97; }
    ensure_namespace() { :; }
    wait_for_cert_manager_webhook() { [[ "${failure}" != "webhook" ]]; }
    wait_for_crd() { :; }
    create_image_pull_secrets() { :; }
    wait_rollout() { [[ "${failure}" != "rollout" ]]; }
    resolve_node_name() { printf 'node-%s\n' "${1//./-}"; }
    yq() {
      if [[ "$*" == *'.imagePullSecrets.secrets[]'* ]]; then
        [[ "${failure}" == "pull-secret" ]] && printf '%s\n' private-registry
        return 0
      fi
      if [[ "$*" == *'.imagePullSecrets.custom.name'* ]]; then
        printf '%s\n' custom-registry-secret
        return 0
      fi
      printf '%s\n' null
    }
    kubectl() {
      local args="$*" capture_file
      printf '%s\n' "${args}" >> "${output_dir}/kubectl.calls"
      if [[ "${failure}" == "ownership" && \
            "${args}" == "-n ingress get serviceaccount traefik --ignore-not-found -o json" ]]; then
        printf '%s\n' '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"someone-else"}}}'
        return 0
      fi
      if [[ "${failure}" == "provider" && "${args}" == logs\ -n\ ingress\ * ]]; then
        printf '%s\n' 'failed to list *v1.Secret: forbidden'
        return 0
      fi
      if [[ "${failure}" == "cleanup-delete" && \
            "${args}" == *"delete daemonset -l app.kubernetes.io/managed-by=splunk-ai-platform-installer"* ]]; then
        return 1
      fi
      if [[ "${args}" == "-n ai-platform get certificate internal-domain-tls -o json" ]]; then
        printf '%s\n' '{"metadata":{"generation":1},"status":{"conditions":[{"type":"Ready","status":"True","observedGeneration":1}]}}'
        return 0
      fi
      if [[ "${args}" == "get secret ai-splunk-server-tls -n ai-platform -o json" ]]; then
        printf '%s\n' '{"data":{"ca.crt":"Q0E="}}'
        return 0
      fi
      if [[ "${args}" == get\ node\ node-*" --ignore-not-found -o json" ]]; then
        printf '%s\n' '{"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
        return 0
      fi
      if [[ "${args}" == "get nodes -l splunk.ai/ingress-node=true -o json" ]]; then
        printf '%s\n' '{"items":[]}'
        return 0
      fi
      if [[ "${args}" == "-n ingress get daemonset traefik -o json" ]]; then
        if [[ "${failure}" == "schedule-zero" ]]; then
          printf '%s\n' '{"status":{"desiredNumberScheduled":0,"updatedNumberScheduled":0,"numberReady":0}}'
        elif [[ "${failure}" == "schedule-partial" ]]; then
          printf '%s\n' '{"status":{"desiredNumberScheduled":2,"updatedNumberScheduled":2,"numberReady":1}}'
        else
          printf '%s\n' '{"status":{"desiredNumberScheduled":2,"updatedNumberScheduled":2,"numberReady":2}}'
        fi
        return 0
      fi
      if [[ "${failure}" == "pull-secret" && \
            "${args}" == "-n ai-platform get secret private-registry --ignore-not-found -o json" ]]; then
        printf '%s\n' '{"metadata":{"name":"private-registry"},"type":"kubernetes.io/dockerconfigjson","data":{".dockerconfigjson":"e30="}}'
        return 0
      fi
      if [[ "${args}" == get\ crd\ *" --ignore-not-found -o name" ]]; then
        printf 'customresourcedefinition.apiextensions.k8s.io/%s\n' "${args#get crd }" | sed 's/ --ignore-not-found -o name$//'
        return 0
      fi
      if [[ "${args}" == get\ secret\ * ]]; then
        return 1
      fi
      if [[ "${args}" == "get clusterrolebinding traefik-ingress-controller -o json" ]]; then
        printf '%s\n' '{"subjects":[]}'
        return 0
      fi
      if [[ " ${args} " == *" -f - "* ]]; then
        capture_file="$(mktemp "${output_dir}/apply.XXXXXX")"
        printf '# kubectl %s\n' "${args}" > "${capture_file}"
        command cat >> "${capture_file}"
      fi
      if [[ "${failure}" == "certificate" && "${args}" == *"wait --for=condition=Ready certificate/internal-domain-tls"* ]]; then
        return 1
      fi
      if [[ "${failure}" == "rollout" && "${args}" == *"rollout status daemonset/traefik"* ]]; then
        return 1
      fi
      return 0
    }

    eval "$(_extract_fn ingress_enabled_k0s)"
    eval "$(_extract_fn ingress_ip_literal_k0s)"
    eval "$(_extract_fn ingress_node_ips_k0s)"
    eval "$(_extract_fn reconcile_traefik_ingress_nodes_k0s)"
    eval "$(_extract_fn wait_for_certificate_current_generation)"
    eval "$(_extract_fn traefik_assert_owned_or_absent)"
    if grep -q '^remove_traefik_ingress()' "${SCRIPT}"; then
      eval "$(_extract_fn remove_traefik_ingress)"
    fi
    eval "$(_extract_fn install_traefik_ingress)"

    INGRESS_ENABLED="${ingress_enabled}"
    INGRESS_HOSTNAME="ai.example.test"
    INGRESS_FIPS="off"
    INGRESS_TLS_MODE="selfsigned"
    INGRESS_SAIA_PORT="9443"
    INGRESS_SPLUNKWEB_PORT="9001"
    INGRESS_SPLUNKMGMT_PORT="9089"
    INGRESS_SPLUNKMGMT_ENABLED="${mgmt_enabled}"
    TRAEFIK_IMAGE="docker.io/library/traefik:test"
    TRAEFIK_MANIFEST_DIR="${SCRIPT_DIR}/traefik"
    CONFIG_FILE="unused-by-yq-stub"
    AI_NS="ai-platform"
    CLUSTER_NAME="test"
    AI_STANDALONE_NAME="standalone"
    CLUSTER_DOMAIN="cluster.local"
    SPLUNK_MODE="${splunk_mode}"
    SPLUNK_ENABLED="true"
    EXISTING_CONTROLLER_IPS="10.0.0.10"
    EXISTING_WORKER_IPS="10.0.0.11 10.0.0.12"
    CONTROLLER_IPS=("10.0.0.10")
    WORKER_IPS=("10.0.0.11" "10.0.0.12")
    TRAEFIK_EXPECTED_NODE_COUNT=0

    install_traefik_ingress
  )
}

_traefik_capture_file() {
  local output_dir="$1" needle="$2" file
  for file in "${output_dir}"/apply.*; do
    [[ -f "${file}" ]] || continue
    if grep -Fq -- "${needle}" "${file}"; then
      printf '%s\n' "${file}"
      return 0
    fi
  done
  return 1
}

_traefik_capture_text() {
  local file
  file="$(_traefik_capture_file "$1" "$2")" || return 0
  command cat "${file}"
}

_traefik_all_capture_text() {
  local output_dir="$1" file
  for file in "${output_dir}"/apply.*; do
    [[ -f "${file}" ]] && command cat "${file}"
  done
}

_traefik_all_yaml_valid() {
  local output_dir="$1" file found=0
  for file in "${output_dir}"/apply.*; do
    [[ -f "${file}" ]] || continue
    found=1
    command yq eval-all '.' "${file}" >/dev/null 2>&1 || return 1
  done
  [[ ${found} -eq 1 ]]
}

_traefik_object_count() {
  local output_dir="$1" kind="$2" name="$3" file count=0 match
  for file in "${output_dir}"/apply.*; do
    [[ -f "${file}" ]] || continue
    while IFS= read -r match; do
      [[ "${match}" == "${name}" ]] && count=$((count + 1))
    done < <(command yq eval-all \
      "select(.kind == \"${kind}\" and .metadata.name == \"${name}\") | .metadata.name" \
      "${file}" 2>/dev/null)
  done
  printf '%s\n' "${count}"
}

_traefik_daemonset_value() {
  local manifest="$1" expression="$2"
  [[ -n "${manifest}" ]] || { printf 'missing\n'; return 0; }
  printf '%s\n' "${manifest}" | command yq eval "${expression}" - 2>/dev/null
}

internal_dir="${TRAEFIK_TEST_TMP}/internal"
mgmt_off_dir="${TRAEFIK_TEST_TMP}/mgmt-off"
external_dir="${TRAEFIK_TEST_TMP}/external"
splunk_disabled_dir="${TRAEFIK_TEST_TMP}/splunk-disabled"
ingress_disabled_dir="${TRAEFIK_TEST_TMP}/ingress-disabled"

internal_rc=0
_traefik_render_case "${internal_dir}" true internal true || internal_rc=$?
mgmt_off_rc=0
_traefik_render_case "${mgmt_off_dir}" true internal false || mgmt_off_rc=$?
external_rc=0
_traefik_render_case "${external_dir}" true external false || external_rc=$?
splunk_disabled_rc=0
_traefik_render_case "${splunk_disabled_dir}" true disabled false || splunk_disabled_rc=$?
pull_secret_dir="${TRAEFIK_TEST_TMP}/pull-secret"
pull_secret_rc=0
_traefik_render_case "${pull_secret_dir}" true internal false pull-secret || pull_secret_rc=$?
ingress_disabled_rc=0
_traefik_render_case "${ingress_disabled_dir}" false internal false || ingress_disabled_rc=$?

assert_eq "internal Traefik manifests render successfully" "0" "${internal_rc}"
assert_eq "management-disabled Traefik manifests render successfully" "0" "${mgmt_off_rc}"
assert_eq "external-Splunk Traefik manifests render successfully" "0" "${external_rc}"
assert_eq "Splunk-disabled Traefik manifests render successfully" "0" "${splunk_disabled_rc}"
assert_eq "configured Traefik pull Secret copy renders successfully" "0" "${pull_secret_rc}"
assert_eq "ingress-disabled cleanup runs successfully" "0" "${ingress_disabled_rc}"

assert_rc "internal rendered resources are valid YAML" 0 _traefik_all_yaml_valid "${internal_dir}"
assert_rc "management-disabled rendered resources are valid YAML" 0 _traefik_all_yaml_valid "${mgmt_off_dir}"
assert_rc "external-Splunk rendered resources are valid YAML" 0 _traefik_all_yaml_valid "${external_dir}"
assert_rc "Splunk-disabled rendered resources are valid YAML" 0 _traefik_all_yaml_valid "${splunk_disabled_dir}"

internal_daemonset="$(_traefik_capture_text "${internal_dir}" 'kind: DaemonSet')"
internal_certificates="$(_traefik_capture_text "${internal_dir}" 'name: internal-domain-tls')"
internal_saia_route="$(_traefik_capture_text "${internal_dir}" 'name: saia-websecure')"
internal_splunk_route="$(_traefik_capture_text "${internal_dir}" 'name: splunkweb-splunkweb')"
internal_transport="$(_traefik_capture_text "${internal_dir}" 'name: splunk-web-tls')"
mgmt_off_daemonset="$(_traefik_capture_text "${mgmt_off_dir}" 'kind: DaemonSet')"
mgmt_off_all="$(_traefik_all_capture_text "${mgmt_off_dir}")"
external_all="$(_traefik_all_capture_text "${external_dir}")"
splunk_disabled_all="$(_traefik_all_capture_text "${splunk_disabled_dir}")"
pull_secret_daemonset="$(_traefik_capture_text "${pull_secret_dir}" 'kind: DaemonSet')"
pull_secret_manifest="$(_traefik_capture_text "${pull_secret_dir}" '"type": "kubernetes.io/dockerconfigjson"')"

assert_eq "configured SAIA port drives the entryPoint address" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c -- '--entrypoints.websecure.address=:9443')"
assert_eq "configured SAIA port drives hostPort" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c 'hostPort: 9443')"
assert_eq "configured Splunk Web port drives the entryPoint address" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c -- '--entrypoints.splunkweb.address=:9001')"
assert_eq "configured Splunk Web port drives hostPort" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c 'hostPort: 9001')"
assert_eq "configured management port drives the enabled entryPoint address" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c -- '--entrypoints.splunkmgmt.address=:9089')"
assert_eq "configured management port drives enabled hostPort" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c 'hostPort: 9089')"

assert_eq "certificate chain is applied in the AI namespace" \
  "1" "$(printf '%s\n' "${internal_certificates}" | grep -c '^# kubectl -n ai-platform .*apply')"
assert_eq "SAIA route is rendered in the AI namespace" \
  "ai-platform" "$(printf '%s\n' "${internal_saia_route}" | command yq eval-all \
    'select(.kind == "IngressRoute" and .metadata.name == "saia-websecure") | .metadata.namespace' -)"
assert_eq "Splunk Web route is rendered in the AI namespace" \
  "ai-platform" "$(printf '%s\n' "${internal_splunk_route}" | command yq eval-all \
    'select(.kind == "IngressRoute" and .metadata.name == "splunkweb-splunkweb") | .metadata.namespace' -)"
assert_eq "all dynamic TLS resources avoid the ingress namespace" \
  "0" "$(printf '%s\n' "${internal_certificates}${internal_saia_route}${internal_splunk_route}${internal_transport}" | grep -c 'namespace: ingress')"

traefik_crd_file="${SCRIPT_DIR}/traefik/traefik-crds.yaml"
traefik_rbac_file="${SCRIPT_DIR}/traefik/traefik-rbac.yaml"
traefik_resource_kinds=(
  ingressroutes ingressroutetcps ingressrouteudps middlewares middlewaretcps
  traefikservices tlsoptions tlsstores serverstransports serverstransporttcps
)
missing_crds=0
missing_rbac_resources=0
for resource in "${traefik_resource_kinds[@]}"; do
  grep -q "name: ${resource}.traefik.io" "${traefik_crd_file}" || missing_crds=$((missing_crds + 1))
  grep -q "\"${resource}\"" "${traefik_rbac_file}" || missing_rbac_resources=$((missing_rbac_resources + 1))
done
assert_eq "vendored CRDs cover every Traefik v3.6 informer resource" "0" "${missing_crds}"
assert_eq "RBAC covers every Traefik v3.6 CRD informer resource" "0" "${missing_rbac_resources}"
assert_eq "RBAC permits the ConfigMap informer" \
  "1" "$(grep -c 'resources: \["services", "secrets", "configmaps"\]' "${traefik_rbac_file}")"
assert_eq "cluster-scoped node discovery is explicitly disabled" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c -- '--providers.kubernetescrd.disableClusterScopeResources=true')"
assert_eq "Traefik release is pinned by tag and digest in the config parser" \
  "1" "$(grep -c 'default_traefik_image="docker.io/library/traefik:v3.6.25@sha256:31267173a15b4944e797a76ffd9c419707c8d8b32fe5b610f80cd0cfa05f372d"' "${SCRIPT}")"
assert_eq "Traefik update and anonymous-usage checks are disabled" \
  "2" "$(printf '%s\n' "${internal_daemonset}" | grep -Ec -- '--global\.(checknewversion|sendanonymoususage)=false')"
assert_eq "Traefik pod is selected only onto installer-labelled ingress nodes" \
  'true' "$(_traefik_daemonset_value "${internal_daemonset}" \
    '.spec.template.spec.nodeSelector."splunk.ai/ingress-node" == "true"')"
assert_eq "every configured ingress target is reconciled to a live node label" \
  "2" "$(grep -c '^label node node-10-0-0-1[12] splunk.ai/ingress-node=true --overwrite$' "${internal_dir}/kubectl.calls")"
assert_eq "successful install verifies live DaemonSet scheduler counts" \
  "1" "$(grep -c '^-n ingress get daemonset traefik -o json$' "${internal_dir}/kubectl.calls")"
assert_eq "Traefik container cannot escalate and has a read-only root filesystem" \
  'true' "$(_traefik_daemonset_value "${internal_daemonset}" \
    '[.spec.template.spec.containers[] | select(.name == "traefik") | .securityContext | ((.allowPrivilegeEscalation == false) and (.readOnlyRootFilesystem == true))] | all')"
assert_eq "Traefik container drops every Linux capability" \
  'true' "$(_traefik_daemonset_value "${internal_daemonset}" \
    '.spec.template.spec.containers[] | select(.name == "traefik") | .securityContext.capabilities.drop | ((length == 1) and (.[0] == "ALL"))')"
assert_eq "Traefik DaemonSet declares resource requests and limits" \
  'true' "$(_traefik_daemonset_value "${internal_daemonset}" \
    '.spec.template.spec.containers[] | select(.name == "traefik") | (.resources.requests.cpu != null and .resources.requests.memory != null and .resources.limits.cpu != null and .resources.limits.memory != null)')"

assert_eq "Splunk Web backend explicitly uses HTTPS" \
  "1" "$(printf '%s\n' "${internal_splunk_route}" | grep -c 'scheme: https')"
assert_eq "Splunk Web backend attaches its validating ServersTransport" \
  "1" "$(printf '%s\n' "${internal_splunk_route}" | grep -c 'serversTransport: splunk-web-tls')"
assert_eq "Splunk Web ServersTransport is rendered" \
  "1" "$(printf '%s\n' "${internal_transport}" | grep -c 'kind: ServersTransport')"
assert_eq "ServersTransport trusts a CA-only ConfigMap projection" \
  "1" "$(printf '%s\n' "${internal_transport}" | grep -A2 'rootCAs:' | grep -c 'configMap: ai-splunk-ca-public')"
assert_eq "ServersTransport never references Splunk's private-key-bearing Secret" \
  "0" "$(printf '%s\n' "${internal_transport}" | grep -A2 'rootCAs:' | grep -c 'secret: ai-splunk-server-tls')"

assert_eq "external Splunk mode omits internal Splunk Web resources" \
  "0" "$(printf '%s\n' "${external_all}" | grep -Ec 'name: (splunkweb-splunkweb|splunk-web-tls|splunkmgmt-passthrough)')"
assert_eq "disabled Splunk mode omits internal Splunk Web resources" \
  "0" "$(printf '%s\n' "${splunk_disabled_all}" | grep -Ec 'name: (splunkweb-splunkweb|splunk-web-tls|splunkmgmt-passthrough)')"
assert_eq "external Splunk mode omits the Splunk Web listener" \
  "0" "$(printf '%s\n' "${external_all}" | grep -c 'entrypoints.splunkweb')"
assert_eq "disabled Splunk mode omits the Splunk Web listener" \
  "0" "$(printf '%s\n' "${splunk_disabled_all}" | grep -c 'entrypoints.splunkweb')"

assert_eq "Traefik never invokes the generic fixed-name Secret creator in ingress" \
  "0" "$(awk '/^install_traefik_ingress\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c 'create_image_pull_secrets.*ingress_ns')"
assert_eq "configured pull credentials are copied with installer ownership labels" \
  "2" "$(printf '%s\n' "${pull_secret_manifest}" | grep -Ec 'app.kubernetes.io/(instance|managed-by)')"
assert_eq "copied pull credentials are attached to the Traefik pod" \
  "1" "$(printf '%s\n' "${pull_secret_daemonset}" | grep -A2 'imagePullSecrets:' | grep -c 'name: private-registry')"

assert_eq "management=false omits its parsed DaemonSet entryPoint" \
  "0" "$(_traefik_daemonset_value "${mgmt_off_daemonset}" \
    '[.spec.template.spec.containers[] | select(.name == "traefik") | .args[]? | select(test("entrypoints\\.splunkmgmt"))] | length')"
assert_eq "management=false omits its parsed DaemonSet hostPort" \
  "0" "$(_traefik_daemonset_value "${mgmt_off_daemonset}" \
    '[.spec.template.spec.containers[] | select(.name == "traefik") | .ports[]?.hostPort | select(. == 9089)] | length')"
assert_eq "management=false omits its parsed TCP route" \
  "0" "$(_traefik_object_count "${mgmt_off_dir}" IngressRouteTCP splunkmgmt-passthrough)"
assert_eq "management=false removes a stale TCP route" \
  "1" "$(grep -c 'delete ingressroutetcp splunkmgmt-passthrough' "${mgmt_off_dir}/kubectl.calls")"

assert_eq "Traefik DaemonSet exposes the ping endpoint" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c -- '--ping=true')"
assert_eq "Traefik DaemonSet has a readiness probe" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c 'readinessProbe:')"
assert_eq "Traefik DaemonSet has a liveness probe" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | grep -c 'livenessProbe:')"
assert_eq "Traefik DaemonSet liveness probe has exactly one port key" \
  "1" "$(printf '%s\n' "${internal_daemonset}" | awk '/livenessProbe:/{f=1} f && /resources:/{exit} f' | grep -c '^              port: traefik$')"

certificate_failure_rc=0
_traefik_render_case "${TRAEFIK_TEST_TMP}/certificate-failure" true internal false certificate >/dev/null 2>&1 || certificate_failure_rc=$?
rollout_failure_rc=0
_traefik_render_case "${TRAEFIK_TEST_TMP}/rollout-failure" true internal false rollout >/dev/null 2>&1 || rollout_failure_rc=$?
ownership_failure_rc=0
_traefik_render_case "${TRAEFIK_TEST_TMP}/ownership-failure" true internal false ownership >/dev/null 2>&1 || ownership_failure_rc=$?
provider_failure_rc=0
_traefik_render_case "${TRAEFIK_TEST_TMP}/provider-failure" true internal false provider >/dev/null 2>&1 || provider_failure_rc=$?
schedule_zero_rc=0
_traefik_render_case "${TRAEFIK_TEST_TMP}/schedule-zero" true internal false schedule-zero >/dev/null 2>&1 || schedule_zero_rc=$?
schedule_partial_rc=0
_traefik_render_case "${TRAEFIK_TEST_TMP}/schedule-partial" true internal false schedule-partial >/dev/null 2>&1 || schedule_partial_rc=$?
cleanup_failure_rc=0
_traefik_render_case "${TRAEFIK_TEST_TMP}/cleanup-failure" false internal false cleanup-delete >/dev/null 2>&1 || cleanup_failure_rc=$?
assert_eq "certificate readiness failure aborts installation" \
  "nonzero" "$([[ ${certificate_failure_rc} -ne 0 ]] && echo nonzero || echo zero)"
assert_eq "DaemonSet rollout failure aborts installation" \
  "nonzero" "$([[ ${rollout_failure_rc} -ne 0 ]] && echo nonzero || echo zero)"
assert_eq "fixed-name ownership collisions abort installation" \
  "nonzero" "$([[ ${ownership_failure_rc} -ne 0 ]] && echo nonzero || echo zero)"
assert_eq "provider informer or RBAC errors abort installation" \
  "nonzero" "$([[ ${provider_failure_rc} -ne 0 ]] && echo nonzero || echo zero)"
assert_eq "a zero-target DaemonSet cannot report ingress success" \
  "nonzero" "$([[ ${schedule_zero_rc} -ne 0 ]] && echo nonzero || echo zero)"
assert_eq "a partially Ready Traefik target set cannot report success" \
  "nonzero" "$([[ ${schedule_partial_rc} -ne 0 ]] && echo nonzero || echo zero)"
assert_eq "cleanup deletion failures cannot report ingress disabled" \
  "nonzero" "$([[ ${cleanup_failure_rc} -ne 0 ]] && echo nonzero || echo zero)"

assert_eq "ingress-disabled cleanup removes only labelled Traefik DaemonSets" \
  "1" "$(grep -c 'delete daemonset -l app.kubernetes.io/managed-by=splunk-ai-platform-installer,app.kubernetes.io/instance=splunk-ai-ingress' "${ingress_disabled_dir}/kubectl.calls")"
assert_eq "ingress-disabled cleanup removes labelled dynamic routes" \
  "1" "$(grep -c 'delete ingressroutes.traefik.io -l app.kubernetes.io/managed-by=splunk-ai-platform-installer,app.kubernetes.io/instance=splunk-ai-ingress' "${ingress_disabled_dir}/kubectl.calls")"
assert_eq "ingress-disabled cleanup removes labelled leaf and CA Certificates" \
  "1" "$(grep -c 'delete certificates.cert-manager.io -l app.kubernetes.io/managed-by=splunk-ai-platform-installer,app.kubernetes.io/instance=splunk-ai-ingress' "${ingress_disabled_dir}/kubectl.calls")"
assert_eq "ingress-disabled cleanup removes installer-owned pull Secret copies" \
  "1" "$(grep -c -- '-n ingress delete secrets -l app.kubernetes.io/managed-by=splunk-ai-platform-installer,app.kubernetes.io/instance=splunk-ai-ingress' "${ingress_disabled_dir}/kubectl.calls")"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo ""
if (( FAIL > 0 )); then
  exit 1
fi
