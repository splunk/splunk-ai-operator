#!/usr/bin/env bash
# test_k0s_cluster_with_stack.sh
# Unit tests for pure-logic functions in k0s_cluster_with_stack.sh.
# No cluster, SSH, kubectl, or network access required.
#
# Usage:
#   ./test_k0s_cluster_with_stack.sh          # run all tests
#   ./test_k0s_cluster_with_stack.sh -v        # verbose (show each assertion)
#   ./test_k0s_cluster_with_stack.sh pod       # run only tests matching "pod"

set -euo pipefail

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

# Source only the pure-logic functions we want to test.
# We stub out everything that touches the filesystem, network, or cluster.
_load_functions() {
  # Minimal stubs so sourcing individual functions doesn't blow up
  log()  { :; }
  warn() { :; }
  err()  { echo "ERROR: $*" >&2; exit 1; }
  pf_ok()   { :; }
  pf_warn() { :; }
  pf_fail() { :; }

  # Extract and eval each function by line range
  eval "$(sed -n '569,581p'   "${SCRIPT}")"   # build_image_url
  eval "$(sed -n '739,745p'   "${SCRIPT}")"   # object_store_auth_looks_like_placeholder
  eval "$(sed -n '4385,4421p' "${SCRIPT}")"   # _pod_is_healthy
  eval "$(sed -n '4425,4454p' "${SCRIPT}")"   # _classify_pod_failure

  # _POD_FS and summary helpers
  eval "$(sed -n '4531p'      "${SCRIPT}")"   # _POD_FS=$'\x1f'

  # _print_unhealthy_pod_summary — find its actual end line dynamically
  local start end
  start=$(grep -n '^_print_unhealthy_pod_summary()' "${SCRIPT}" | cut -d: -f1)
  end=$(awk -v s="${start}" 'NR>s && /^}$/{print NR; exit}' "${SCRIPT}")
  eval "$(sed -n "${start},${end}p" "${SCRIPT}")"
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

# ── Tests: object_store_auth_looks_like_placeholder ───────────────────────────

suite "object_store_auth_looks_like_placeholder"
echo "▶ object_store_auth_looks_like_placeholder"

_run_placeholder_check() {
  MINIO_ROOT_USER="$1" MINIO_ROOT_PASSWORD="$2" \
    object_store_auth_looks_like_placeholder
}

assert_rc "detects <CHANGE_ME> angle bracket placeholder" 0 \
  bash -c "$(declare -f object_store_auth_looks_like_placeholder); MINIO_ROOT_USER='<user>' MINIO_ROOT_PASSWORD='secret' object_store_auth_looks_like_placeholder"

assert_rc "detects CHANGEME keyword in password" 0 \
  bash -c "$(declare -f object_store_auth_looks_like_placeholder); MINIO_ROOT_USER='admin' MINIO_ROOT_PASSWORD='CHANGEME' object_store_auth_looks_like_placeholder"

assert_rc "detects changeme (lowercase)" 0 \
  bash -c "$(declare -f object_store_auth_looks_like_placeholder); MINIO_ROOT_USER='admin' MINIO_ROOT_PASSWORD='changeme' object_store_auth_looks_like_placeholder"

assert_rc "accepts real credentials (returns 1)" 1 \
  bash -c "$(declare -f object_store_auth_looks_like_placeholder); MINIO_ROOT_USER='admin' MINIO_ROOT_PASSWORD='s3cr3t!' object_store_auth_looks_like_placeholder"

# ── Tests: _pod_is_healthy ─────────────────────────────────────────────────────

suite "_pod_is_healthy"
echo "▶ _pod_is_healthy"

# args: phase ready waiting terminated reason
assert_rc "Running 2/2 is healthy"              0 _pod_is_healthy Running  "2/2" ""                ""      ""
assert_rc "Running 1/2 is unhealthy"            1 _pod_is_healthy Running  "1/2" ""                ""      ""
assert_rc "Succeeded is healthy"                0 _pod_is_healthy Succeeded "" ""                 ""      ""
assert_rc "Pending is unhealthy"                1 _pod_is_healthy Pending  "0/1" ""                ""      ""
assert_rc "Failed is unhealthy"                 1 _pod_is_healthy Failed   "0/1" ""                ""      ""
assert_rc "Unknown is unhealthy"                1 _pod_is_healthy Unknown  "0/1" ""                ""      ""
assert_rc "CrashLoopBackOff is unhealthy"       1 _pod_is_healthy Running  "0/1" "CrashLoopBackOff" ""     ""
assert_rc "ImagePullBackOff is unhealthy"       1 _pod_is_healthy Running  "0/1" "ImagePullBackOff" ""     ""
assert_rc "ErrImagePull is unhealthy"           1 _pod_is_healthy Running  "0/1" "ErrImagePull"    ""      ""
assert_rc "OOMKilled terminated is unhealthy"   1 _pod_is_healthy Running  "1/1" ""                "OOMKilled" ""
assert_rc "Error terminated is unhealthy"       1 _pod_is_healthy Running  "1/1" ""                "Error" ""
assert_rc "NodeLost reason is unhealthy"        1 _pod_is_healthy Running  "1/1" ""                ""      "NodeLost"
assert_rc "Evicted reason is unhealthy"         1 _pod_is_healthy Running  "1/1" ""                ""      "Evicted"
assert_rc "PodInitializing waiting is unhealthy" 1 _pod_is_healthy Pending "0/1" "PodInitializing"  ""     ""

# ── Tests: _classify_pod_failure ──────────────────────────────────────────────

suite "_classify_pod_failure"
echo "▶ _classify_pod_failure"

# args: phase reason waiting terminated message
assert_eq "ImagePullBackOff → image-pull" \
  "image-pull" "$(  _classify_pod_failure Pending ""       "ImagePullBackOff" ""         "")"
assert_eq "ErrImagePull → image-pull" \
  "image-pull" "$(  _classify_pod_failure Running ""       "ErrImagePull"     ""         "")"
assert_eq "CrashLoopBackOff → crashloop" \
  "crashloop"  "$(  _classify_pod_failure Running ""       "CrashLoopBackOff" ""         "")"
assert_eq "OOMKilled → oom" \
  "oom"        "$(  _classify_pod_failure Running ""       ""                 "OOMKilled" "")"
assert_eq "Evicted → evicted" \
  "evicted"    "$(  _classify_pod_failure Running "Evicted" ""                ""         "")"
assert_eq "Pending with no signal → pending-long" \
  "pending-long" "$(_classify_pod_failure Pending ""       ""                 ""         "")"
assert_eq "Failed with no signal → failed" \
  "failed"     "$( _classify_pod_failure Failed  ""       ""                 ""         "")"

# ── Tests: _print_unhealthy_pod_summary ───────────────────────────────────────

suite "_print_unhealthy_pod_summary pod"
echo "▶ _print_unhealthy_pod_summary"

# Override warn/log to capture output
_captured=""
warn() { _captured+="WARN: $*"$'\n'; }
log()  { _captured+="LOG: $*"$'\n'; }

mk_pod_line() {
  # ns name phase ready waiting
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
  "1" "$(echo "${_captured}" | grep -c "^WARN: 1 root-cause pod")"
assert_eq "scenario 1: shows downstream section" \
  "1" "$(echo "${_captured}" | grep -c "still initializing")"
assert_eq "scenario 1: head pod appears in root-cause output" \
  "1" "$(echo "${_captured}" | grep -c "head-pod")"
assert_eq "scenario 1: tip mentions fixing root cause" \
  "1" "$(echo "${_captured}" | grep -c "fix the root-cause")"
assert_eq "scenario 1: downstream count is 2" \
  "1" "$(echo "${_captured}" | grep -c "^WARN: 2 pod(s) are still initializing")"

# Scenario 2: only PodInitializing — no root cause
_captured=""
POD_LINES=(
  "$(mk_pod_line ai-platform gpu-worker-1 Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-worker-2 Pending "0/1" "PodInitializing")"
)
_print_unhealthy_pod_summary
assert_eq "scenario 2: no root-cause section shown" \
  "0" "$(echo "${_captured}" | grep -c "root-cause pod")"
assert_eq "scenario 2: shows 2 still initializing" \
  "1" "$(echo "${_captured}" | grep -c "^WARN: 2 pod(s) are still initializing")"
assert_eq "scenario 2: tip says re-run verifier" \
  "1" "$(echo "${_captured}" | grep -c "re-run the verifier")"

# Scenario 3: only root causes, no PodInitializing — multi-namespace
_captured=""
POD_LINES=(
  "$(mk_pod_line ai-platform  head-pod     Pending "0/2" "ImagePullBackOff")"
  "$(mk_pod_line kube-system  calico-node  Pending "0/1" "CrashLoopBackOff")"
)
_print_unhealthy_pod_summary
assert_eq "scenario 3: 2 root-cause pods" \
  "1" "$(echo "${_captured}" | grep -c "^WARN: 2 root-cause pod")"
assert_eq "scenario 3: no downstream section" \
  "0" "$(echo "${_captured}" | grep -c "still initializing")"
assert_eq "scenario 3: both namespaces shown" \
  "1" "$(echo "${_captured}" | grep -c "ai-platform")"
assert_eq "scenario 3: kube-system also shown" \
  "1" "$(echo "${_captured}" | grep -c "kube-system")"

# Scenario 4: max_per_ns truncation (>5 pods in one namespace)
_captured=""
POD_LINES=(
  "$(mk_pod_line ai-platform head-pod     Pending "0/2" "ImagePullBackOff")"
  "$(mk_pod_line ai-platform gpu-w-1      Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-2      Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-3      Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-4      Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-5      Pending "0/1" "PodInitializing")"
  "$(mk_pod_line ai-platform gpu-w-6      Pending "0/1" "PodInitializing")"
)
_print_unhealthy_pod_summary
assert_eq "scenario 4: truncation ellipsis shown for downstream" \
  "1" "$(echo "${_captured}" | grep -c "… and")"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo ""
if (( FAIL > 0 )); then
  exit 1
fi
