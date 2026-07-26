#!/bin/bash
set -euo pipefail

# =============================================================================
# k0s Cluster Setup Script for Splunk AI Platform
# =============================================================================
# Deploys a k0s cluster on customer-provided (on-prem / baremetal) nodes.
# Requires existingIPs in the config YAML (controller + worker IPs).
# =============================================================================

# --- AWS credentials handling ---
# Don't unset AWS credentials - they may be needed for ECR access in on-prem/air-gapped scenarios
# The original unset was to prevent conflicts, but it breaks SSO/assumed-role credentials
# If you need to clear credentials, do it explicitly before running the script
# unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE 2>/dev/null || true

# --- Non-interactive setup ---
export AWS_PAGER=""
export AWS_DEFAULT_OUTPUT=json
export PAGER=cat
export GIT_PAGER=cat
export LESS=FRX
export EDITOR=cat
export KUBE_EDITOR=cat
export LANG=C LC_ALL=C

# --- Cross-function shared state ---
# We run under `set -euo pipefail`, where ${#ARR[@]} on a never-set array
# aborts with "unbound variable". The verifier helpers (_collect_pod_summary,
# _check_workload_readiness) and the post-install banner
# (_print_unhealthy_pod_summary, show_platform_access_info) all share state
# through these globals — declare them up-front so the script is safe to
# source and to invoke any helper out-of-order.
#
# - POD_LINES               populated by _collect_pod_summary; one delimited
#                            row per pod (see field layout in that helper).
# - WORKLOAD_PENDING_REASON  populated by _check_workload_readiness; multiline
#                            human-readable list of CRs that aren't Ready.
# - VERIFY_RC                set by main_install from verify_all_pods_healthy;
#                            read by show_platform_access_info to choose
#                            between success / partial-readiness banners.
declare -a POD_LINES=()
WORKLOAD_PENDING_REASON=""
VERIFY_RC=0

# ====== CONFIG FILE LOCATION ======
CONFIG_FILE="${CONFIG_FILE:-$(dirname "$0")/k0s-cluster-config.yaml}"

# ====== SESSION LOG ======
LOG_DIR="${LOG_DIR:-$(dirname "$0")/logs}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/k0s-install-$(date '+%Y-%m-%d_%H-%M-%S').log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "[LOG] Session log: ${LOG_FILE}"

# ====== LOG ROTATION (keep last 10 logs) ======
_rotate_logs() {
  local keep=10
  local logs
  # Newest-first; tail of the array is the oldest — delete those.
  mapfile -t logs < <(ls -1t "${LOG_DIR}"/k0s-install-*.log 2>/dev/null)
  local excess=$(( ${#logs[@]} - keep ))
  if (( excess > 0 )); then
    for (( i=${#logs[@]}-1; i>=${#logs[@]}-excess; i-- )); do
      rm -f "${logs[$i]}"
    done
  fi
}
_rotate_logs

# ====== COLORS & LOGGING ======
_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()   { echo -e "\033[1;36m[$(_ts) INFO]\033[0m $*" >&2; }
warn()  { echo -e "\033[1;33m[$(_ts) WARN]\033[0m $*" >&2; }
err()   {
  echo -e "\033[1;31m[$(_ts) ERROR]\033[0m $*" >&2
  echo -e "\033[1;31m[$(_ts) ERROR]\033[0m Log file: ${LOG_FILE}" >&2
  echo -e "\033[1;31m[$(_ts) ERROR]\033[0m Run '$0 diagnose' to collect a full support bundle." >&2
  exit 1
}

# ====== TOOL CHECKER ======
# Provides install instructions instead of a bare "missing in PATH" message.
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  local install_hint=""
  case "$1" in
    kubectl) install_hint="brew install kubectl  OR  https://kubernetes.io/docs/tasks/tools/" ;;
    helm)    install_hint="brew install helm  OR  https://helm.sh/docs/intro/install/" ;;
    yq)      install_hint="brew install yq  OR  wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && chmod +x /usr/local/bin/yq" ;;
    jq)      install_hint="brew install jq  OR  apt-get install jq  OR  dnf install jq" ;;
    ssh)     install_hint="apt-get install openssh-client  OR  brew install openssh" ;;
    curl)    install_hint="apt-get install curl  OR  brew install curl" ;;
    aws)     install_hint="https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" ;;
    git)     install_hint="brew install git  OR  apt-get install git" ;;
    *)       install_hint="install '$1' via your system package manager" ;;
  esac
  err "Required tool not found: $1
  Install: ${install_hint}"
}

# ====== HELM RETRY LOGIC ======
# Retries helm commands with exponential backoff on transient errors
# Usage: helm_retry <max_tries> <helm_command_and_args>
# Example: helm_retry 3 upgrade --install my-release chart/name
helm_retry() {
  local tries="${1}"; shift
  local i=1 backoff=5 out rc
  while (( i <= tries )); do
    set +e
    out=$(helm "$@" 2>&1); rc=$?
    set -e
    if (( rc == 0 )); then printf "%s\n" "$out"; return 0; fi
    # Check for transient errors that should be retried
    if grep -qiE 'timed out|operation timed out|i/o timeout|connection reset|TLS handshake timeout|could not get information about the resource|context deadline exceeded|not ready' <<<"$out"; then
      warn "Helm transient error (attempt $i/$tries). Retrying in ${backoff}s…"
      warn "$out"
      sleep "$backoff"; backoff=$(( backoff*2 )); (( i++ ))
    else
      # Non-transient error, fail immediately
      echo "$out" >&2; return "$rc"
    fi
  done
  err "Helm failed after ${tries} attempts."
}

# ====== WAIT FOR RESOURCE HELPERS ======
# Wait for a specific resource to exist
wait_resource_exists() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-300}"
  log "Waiting for ${kind}/${name} to exist in ${ns} (timeout: ${timeout}s)..."
  kubectl wait --for=condition=Established --timeout="${timeout}s" "crd/${name}" 2>/dev/null || \
  timeout "${timeout}s" bash -c "until kubectl get ${kind} ${name} -n ${ns} >/dev/null 2>&1; do sleep 2; done" || \
  warn "Timeout waiting for ${kind}/${name} in ${ns}"
}

# Wait for a deployment rollout
wait_rollout() {
  local ns="$1" kind="$2" name="$3" timeout="${4:-300}"
  log "Waiting for ${kind}/${name} rollout in ${ns} (timeout: ${timeout}s)..."
  kubectl rollout status "${kind}/${name}" -n "${ns}" --timeout="${timeout}s" || \
  warn "Timeout waiting for ${kind}/${name} rollout in ${ns}"
}

# ====== PREFLIGHT CHECKS ======
PF_FAILS=0; PF_WARN=0
pf_header(){ echo -e "\n\033[1;34m[CHECK]\033[0m $*" >&2; }
pf_ok()   { echo -e "  \033[1;32m✔\033[0m $*" >&2; }
pf_warn() { echo -e "  \033[1;33m!\033[0m $*" >&2; PF_WARN=$((PF_WARN+1)); }
pf_fail() { echo -e "  \033[1;31m✖\033[0m $*" >&2; PF_FAILS=$((PF_FAILS+1)); }
pf_summary(){
  echo -e "\n\033[1;34m[SUMMARY]\033[0m Preflight complete: \033[1;32m${PF_FAILS} error(s)\033[0m, \033[1;33m${PF_WARN} warning(s)\033[0m." >&2
  (( PF_FAILS == 0 )) || err "Preflight failed; please fix the above and rerun."
}

# ====== TEMP FILES ======
TMP_FILES=()
cleanup_tmp() { [[ ${#TMP_FILES[@]} -gt 0 ]] && rm -f "${TMP_FILES[@]}" 2>/dev/null || true; }
trap cleanup_tmp EXIT

# ====== STEP PROGRESS TRACKER ======
# Usage: step_start "Install cert-manager"   → prints [STEP N/TOTAL] banner
#        step_ok                             → marks it done
#        step_fail "reason"                  → marks it failed (does not exit)
# show_step_summary                          → final table printed at end of install
declare -a _STEP_NAMES=()
declare -a _STEP_STATUS=()   # "ok" | "fail" | "skip"
declare -a _STEP_START_TS=() # epoch seconds at step_start
declare -a _STEP_ELAPSED=()  # seconds taken, set by step_ok/fail/skip
_STEP_CURRENT=""
_INSTALL_START_TS=${SECONDS}

step_start() {
  _STEP_CURRENT="$1"
  _STEP_NAMES+=("$1")
  _STEP_STATUS+=("running")
  _STEP_START_TS+=("${SECONDS}")
  _STEP_ELAPSED+=(0)
  local n=${#_STEP_NAMES[@]}
  echo -e "\n\033[1;34m[$(_ts) ── STEP ${n}: $1 ──]\033[0m" >&2
}

_step_record_elapsed() {
  local last=$(( ${#_STEP_START_TS[@]} - 1 ))
  _STEP_ELAPSED[$last]=$(( SECONDS - _STEP_START_TS[$last] ))
}

step_ok() {
  _step_record_elapsed
  local last=$(( ${#_STEP_STATUS[@]} - 1 ))
  _STEP_STATUS[$last]="ok"
  local elapsed="${_STEP_ELAPSED[$last]}"
  echo -e "\033[1;32m[$(_ts) ✔ ${_STEP_NAMES[$last]} — $(printf '%dm%02ds' $((elapsed/60)) $((elapsed%60)))]\033[0m" >&2
}

step_fail() {
  _step_record_elapsed
  local last=$(( ${#_STEP_STATUS[@]} - 1 ))
  _STEP_STATUS[$last]="fail:${1:-unknown error}"
}

step_skip() {
  _step_record_elapsed
  local last=$(( ${#_STEP_STATUS[@]} - 1 ))
  _STEP_STATUS[$last]="skip:${1:-}"
}

show_step_summary() {
  local total_elapsed=$(( SECONDS - _INSTALL_START_TS ))
  echo -e "\n\033[1;34m[$(_ts) ════ INSTALL SUMMARY ════]\033[0m" >&2
  local total=${#_STEP_NAMES[@]} ok=0 fail=0 skip=0
  for i in "${!_STEP_NAMES[@]}"; do
    local s="${_STEP_STATUS[$i]}"
    local elapsed="${_STEP_ELAPSED[$i]:-0}"
    local duration
    if (( elapsed >= 60 )); then
      duration=$(printf '%dm%02ds' $((elapsed/60)) $((elapsed%60)))
    else
      duration="${elapsed}s"
    fi
    local icon color label
    case "${s%%:*}" in
      ok)      icon="✔"; color="\033[1;32m"; label="OK";           ok=$((ok+1)) ;;
      fail)    icon="✖"; color="\033[1;31m"; label="${s#fail:}";   fail=$((fail+1)) ;;
      skip)    icon="–"; color="\033[1;33m"; label="${s#skip:}";   skip=$((skip+1)) ;;
      running) icon="?"; color="\033[1;33m"; label="interrupted";  fail=$((fail+1)) ;;
      *)       icon="?"; color="\033[0m";    label="${s}" ;;
    esac
    printf "  ${color}${icon}\033[0m  %-45s %-8s %s\n" "${_STEP_NAMES[$i]}" "${duration}" "${label}" >&2
  done
  echo "" >&2
  local total_dur
  if (( total_elapsed >= 3600 )); then
    total_dur=$(printf '%dh%02dm%02ds' $((total_elapsed/3600)) $(((total_elapsed%3600)/60)) $((total_elapsed%60)))
  else
    total_dur=$(printf '%dm%02ds' $((total_elapsed/60)) $((total_elapsed%60)))
  fi
  if (( fail == 0 )); then
    echo -e "  \033[1;32mAll ${total} steps completed successfully in ${total_dur}.\033[0m" >&2
  else
    echo -e "  \033[1;31m${fail} step(s) failed, ${ok} succeeded, ${skip} skipped. Total: ${total_dur}\033[0m" >&2
    echo -e "  \033[1;31mSee log: ${LOG_FILE}\033[0m" >&2
  fi
  echo "" >&2
}

# ====== PHASE SECTION MARKERS ======
# Emit a grep-friendly section header so production support can isolate phases.
phase_start() { echo -e "\n\033[1;35m[$(_ts) ════════ PHASE: $* ════════]\033[0m" >&2; }
phase_end()   { echo -e "\033[1;35m[$(_ts) ════════ END: $* ════════]\033[0m\n" >&2; }

# ====== WAIT FOR DEPENDENCY (interactive pause-and-retry) ======
# Usage: wait_for_dependency "check description" CHECK_COMMAND [max_wait_seconds]
# The check command is re-run every 30 s. On each failure the customer is
# prompted to press Enter to retry immediately, or the loop continues after
# 30 s automatically. The function returns 0 once the check passes, or
# exits with a clear message after max_wait_seconds.
wait_for_dependency() {
  local description="$1"
  local check_cmd="$2"
  local max_wait="${3:-600}"
  local elapsed=0 interval=30

  log "Waiting for external dependency: ${description}"
  log "  Max wait: ${max_wait}s. Press Enter at any time to retry immediately."

  while (( elapsed < max_wait )); do
    if eval "${check_cmd}" >/dev/null 2>&1; then
      log "  ✔ ${description} — ready"
      return 0
    fi
    local remaining=$(( max_wait - elapsed ))
    warn "  ${description} not ready yet. Retrying in ${interval}s (${remaining}s remaining)."
    warn "  Press Enter to retry now, or wait..."
    # Wait up to interval seconds for a keypress; non-interactive shells skip.
    if read -t "${interval}" -r 2>/dev/null; then
      log "  Retrying immediately..."
    fi
    elapsed=$(( elapsed + interval ))
  done

  err "Timed out after ${max_wait}s waiting for: ${description}
  Resolve the issue, then re-run the installer."
}

# ====== NODE OS GATE ======
# Only RHEL 9 is tested and supported. All other OS families (RHEL 10,
# Amazon Linux, Debian/Ubuntu) stop the script with a clear error.
# Set FORCE_UNSUPPORTED_OS=1 to downgrade the error to a warning and
# continue at your own risk (useful for internal testing).
_check_node_os() {
  local node_ip="$1" role="${2:-node}"
  local os_id="" os_version_id="" os_pretty=""

  os_id=$(ssh_exec "${node_ip}" \
    ". /etc/os-release 2>/dev/null && echo \"\${ID}\"" 2>/dev/null || echo "")
  os_version_id=$(ssh_exec "${node_ip}" \
    ". /etc/os-release 2>/dev/null && echo \"\${VERSION_ID%%.*}\"" 2>/dev/null || echo "")
  os_pretty=$(ssh_exec "${node_ip}" \
    ". /etc/os-release 2>/dev/null && echo \"\${PRETTY_NAME}\"" 2>/dev/null || echo "unknown")

  # Supported: RHEL 9 only. Other family members kept for internal testing.
  if [[ "${os_id}" =~ ^(rhel|centos|rocky|almalinux)$ ]] && [[ "${os_version_id}" == "9" ]]; then
    log "  OS check passed on ${role} ${node_ip}: ${os_pretty}"
    return 0
  fi

  local msg="Unsupported OS on ${role} ${node_ip}: ${os_pretty}
  Only RHEL 9 is tested and supported. Installation on other OS versions
  is not validated and may fail in unexpected ways.
  To skip this check and continue at your own risk, set:
    FORCE_UNSUPPORTED_OS=1"

  if [[ "${FORCE_UNSUPPORTED_OS:-0}" == "1" ]]; then
    warn "${msg}"
    warn "  FORCE_UNSUPPORTED_OS=1 — continuing anyway (unsupported, use for testing only)"
  else
    err "${msg}"
  fi
}

# ====== RESOLVE MODEL STAGING DECISION ======
# Called after load_config, before show_install_plan.
# In Full (interactive) mode: always prompts; answer overrides storage.modelStaging.enabled.
# In Silent mode: honours the config value with no prompt.
resolve_model_staging() {
  if [[ "${SILENT_INSTALL:-false}" == "true" ]]; then
    log "Silent install: using storage.modelStaging.enabled=${MODEL_STAGING_ENABLED} from config (no prompt)."
    return 0
  fi
  if [[ "${AIRGAP_MODE:-false}" == "true" ]]; then
    log "Air-gap mode: model staging skipped (models must be pre-staged in object store); no prompt."
    MODEL_STAGING_ENABLED=false
    return 0
  fi
  # Full/interactive: prompt always overrides config value
  echo "" >&2
  echo -e "  \033[1mModel Download\033[0m" >&2
  echo "  Do you want to download and stage model artifacts from HuggingFace now?" >&2
  echo "  (Required for a first install unless models are already in your object store.)" >&2
  local ans
  read -rp "  Download & stage models? [y/N]: " ans
  case "${ans}" in
    [Yy]|[Yy][Ee][Ss]) MODEL_STAGING_ENABLED=true ;;
    *)                  MODEL_STAGING_ENABLED=false ;;
  esac
  echo "" >&2
  log "Model staging set to '${MODEL_STAGING_ENABLED}' by interactive prompt (overrides config value)."
}

# Supported GPU accelerator types. Add new types here — the interactive prompt
# and validate_config both derive their lists from this constant.
readonly SUPPORTED_ACCELERATORS=("L40S" "H100")

# ====== RESOLVE ACCELERATOR TYPE ======
# Called after load_config, before show_install_plan.
# Prompts when defaultAcceleratorType is missing OR set to an unsupported value,
# since the CR always requires this field and stage_model_artifacts needs a valid type.
resolve_accelerator_type() {
  # Return early only if already set to a valid supported type (case-insensitive).
  # Normalize to the canonical casing from SUPPORTED_ACCELERATORS so the CR value
  # matches the Ray builder's instanceMap keys exactly (e.g. L40S, H100).
  local _cur
  _cur=$(printf '%s' "${DEFAULT_ACCELERATOR:-}" | tr '[:upper:]' '[:lower:]')
  for _t in "${SUPPORTED_ACCELERATORS[@]}"; do
    if [[ "${_cur}" == "${_t,,}" ]]; then
      DEFAULT_ACCELERATOR="${_t}"
      return 0
    fi
  done

  local _supported_list="${SUPPORTED_ACCELERATORS[*]}"
  if [[ "${SILENT_INSTALL:-false}" == "true" ]]; then
    err "aiPlatform.defaultAcceleratorType${DEFAULT_ACCELERATOR:+ ('${DEFAULT_ACCELERATOR}') is not supported} — must be one of: ${_supported_list}. Set it in your config."
  fi
  if [[ ! -t 0 ]]; then
    err "aiPlatform.defaultAcceleratorType${DEFAULT_ACCELERATOR:+ ('${DEFAULT_ACCELERATOR}') is not supported} — set it in your config to one of: ${_supported_list}."
  fi
  echo "" >&2
  echo "  Select GPU accelerator type:" >&2
  for i in "${!SUPPORTED_ACCELERATORS[@]}"; do
    echo "    $((i+1))) ${SUPPORTED_ACCELERATORS[$i]}" >&2
  done
  local _choice
  read -rp "  Enter 1-${#SUPPORTED_ACCELERATORS[@]}: " _choice
  if [[ "${_choice}" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#SUPPORTED_ACCELERATORS[@]} )); then
    DEFAULT_ACCELERATOR="${SUPPORTED_ACCELERATORS[$((_choice-1))]}"
  else
    err "Invalid choice '${_choice}'. Please enter a number between 1 and ${#SUPPORTED_ACCELERATORS[@]}."
  fi
  echo "" >&2
  log "Accelerator type set to '${DEFAULT_ACCELERATOR}' by interactive prompt."
}

# ====== SHOW INSTALL PLAN ======
# Called before install starts; prints what will be done so customers can
# validate the config before a 40-minute run.
show_install_plan() {
  echo -e "\n\033[1;34m╔══════════════════════════════════════════════════════════╗\033[0m" >&2
  echo -e "\033[1;34m║           SPLUNK AI PLATFORM — INSTALL PLAN               ║\033[0m" >&2
  echo -e "\033[1;34m╚══════════════════════════════════════════════════════════╝\033[0m" >&2
  echo "" >&2
  echo -e "  \033[1mCluster name     :\033[0m ${CLUSTER_NAME}" >&2
  echo -e "  \033[1mNamespace        :\033[0m ${AI_NS}" >&2
  echo -e "  \033[1mConfig file      :\033[0m ${CONFIG_FILE}" >&2
  echo -e "  \033[1mLog file         :\033[0m ${LOG_FILE}" >&2
  echo "" >&2
  echo -e "  \033[1mController nodes :\033[0m ${EXISTING_CONTROLLER_IPS}" >&2
  echo -e "  \033[1mWorker nodes     :\033[0m ${EXISTING_WORKER_IPS:-none configured}" >&2
  echo -e "  \033[1mAccelerator type :\033[0m ${DEFAULT_ACCELERATOR:-<none — CPU only>}" >&2
  echo "" >&2
  echo -e "  \033[1mObject store     :\033[0m type=$(yq eval '.storage.objectStore.type // "?"' "${CONFIG_FILE}" 2>/dev/null)  bucket=$(yq eval '.storage.objectStore.bucket // "?"' "${CONFIG_FILE}" 2>/dev/null)" >&2
  echo -e "  \033[1mObject endpoint  :\033[0m $(yq eval '.storage.objectStore.endpoint // "<default>"' "${CONFIG_FILE}" 2>/dev/null)" >&2
  echo -e "  \033[1mModel staging    :\033[0m ${MODEL_STAGING_ENABLED}" >&2
  if [[ "${SPLUNK_MODE}" == "external" ]]; then
    echo -e "  \033[1mSplunk telemetry :\033[0m external → ${SPLUNK_EXTERNAL_ENDPOINT} (secret=${SPLUNK_EXTERNAL_SECRET_NAME})" >&2
  else
    echo -e "  \033[1mSplunk telemetry :\033[0m ${SPLUNK_MODE} (splunk.enabled=${SPLUNK_ENABLED})" >&2
  fi
  echo -e "  \033[1mImage registry   :\033[0m $(yq eval '.images.registry // "<public>"' "${CONFIG_FILE}" 2>/dev/null)" >&2
  echo -e "  \033[1mAir-gap mode     :\033[0m ${AIRGAP_MODE:-false}" >&2
  echo "" >&2
  echo -e "  \033[1mSteps that will run:\033[0m" >&2
  echo -e "    1. Preflight checks (SSH, disk, tools)" >&2
  if [[ "${MODEL_STAGING_ENABLED}" == "true" ]]; then
    if [[ "${AIRGAP_MODE:-false}" == "true" ]]; then
      echo -e "    2. Model artifact staging  [SKIPPED — AIRGAP_MODE=true, models must be pre-staged]" >&2
    else
      echo -e "    2. Model artifact staging (HuggingFace → object store)" >&2
    fi
  else
    echo -e "    2. Model artifact staging  [SKIPPED — modelStaging.enabled=false]" >&2
  fi
  echo -e "    3. k0s cluster installation" >&2
  echo -e "    4. Phase 1 (parallel): cert-manager, prometheus, NVIDIA drivers" >&2
  if [[ "${SPLUNK_MODE}" == "internal" ]]; then
    echo -e "    5. Phase 2 (parallel): OTel, KubeRay, Splunk operator, NVIDIA device-plugin" >&2
  else
    echo -e "    5. Phase 2 (parallel): OTel, KubeRay, NVIDIA device-plugin  [Splunk operator SKIPPED — mode=${SPLUNK_MODE}]" >&2
  fi
  echo -e "    6. MetalLB load-balancer" >&2
  if [[ "${SPLUNK_MODE}" == "internal" ]]; then
    echo -e "    7. Splunk Standalone + AI Platform operator + CR" >&2
  elif [[ "${SPLUNK_MODE}" == "external" ]]; then
    echo -e "    7. AI Platform operator + CR (external Splunk HEC)  [Splunk Standalone SKIPPED — external mode]" >&2
  else
    echo -e "    7. AI Platform operator + CR  [Splunk Standalone SKIPPED — mode=disabled]" >&2
  fi
  echo -e "    8. Health check + pod verification" >&2
  echo "" >&2

  if [[ "${SILENT_INSTALL:-false}" == "true" ]]; then
    echo -e "  \033[1;33m⚠  SILENT INSTALL — no interactive prompts.\033[0m" >&2
    echo -e "  The config file is assumed to have been reviewed and is correct." >&2
    echo -e "  The steps listed above will run automatically. Press Ctrl-C within 5 s to abort." >&2
    sleep 5
    return 0
  fi

  echo -e "  \033[1mReview the plan above. Type 'yes' to proceed, anything else to abort:\033[0m" >&2
  local answer
  read -r answer
  if [[ "${answer}" != "yes" ]]; then
    echo "Aborted by user." >&2
    exit 0
  fi
}

# ====== LOAD CONFIGURATION ======

ensure_yq() {
  command -v yq >/dev/null 2>&1 && return 0
  local os arch url
  # Pinned version — matches download_from_huggingface.sh; update both together.
  local YQ_VERSION="v4.44.1"
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64)   arch="amd64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *) warn "yq auto-install: unsupported arch ${arch}, skipping"; return 1 ;;
  esac
  case "${os}" in
    Linux)
      url="${YQ_DOWNLOAD_URL:-https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}}"
      log "Installing yq ${YQ_VERSION} (linux-${arch})..."
      if curl -fsSL -o /tmp/yq "${url}"; then
        chmod +x /tmp/yq
        if [[ "$(id -u)" -eq 0 ]]; then
          mv /tmp/yq /usr/local/bin/yq
        else
          sudo mv /tmp/yq /usr/local/bin/yq 2>/dev/null || { mkdir -p ~/.local/bin; mv /tmp/yq ~/.local/bin/yq; export PATH="$PATH:$HOME/.local/bin"; }
        fi
      else
        warn "yq download failed — config parsing may be unreliable"; return 1
      fi
      ;;
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        log "Installing yq via brew..."
        brew install yq
      else
        url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_darwin_${arch}"
        log "Installing yq ${YQ_VERSION} (darwin-${arch})..."
        if curl -fsSL -o /tmp/yq "${url}"; then
          chmod +x /tmp/yq
          sudo mv /tmp/yq /usr/local/bin/yq 2>/dev/null || { mkdir -p ~/.local/bin; mv /tmp/yq ~/.local/bin/yq; export PATH="$PATH:$HOME/.local/bin"; }
        else
          warn "yq download failed — config parsing may be unreliable"; return 1
        fi
      fi
      ;;
    *) warn "yq auto-install: unsupported OS ${os}, skipping"; return 1 ;;
  esac
  command -v yq >/dev/null 2>&1 && log "yq installed: $(yq --version 2>/dev/null)" || warn "yq install succeeded but binary not found in PATH"
}

load_config() {
  ensure_yq || true
  command -v yq >/dev/null 2>&1 || err "yq is required to parse ${CONFIG_FILE}. Install it (brew install yq / snap install yq) and retry."
  log "Loading configuration from: ${CONFIG_FILE}"
  [[ -f "${CONFIG_FILE}" ]] || err "Config file not found: ${CONFIG_FILE}"

  # Validate the WHOLE file parses cleanly before pulling individual fields.
  # Every yq lookup below uses `2>/dev/null` to fall through to a default, which
  # silently swallows YAML syntax errors and makes them look like missing
  # fields downstream (e.g. "nodes.existingIPs.controllers must be set" when
  # the real problem is a corrupted comment 90 lines later in the file).
  # Surface parse errors with their actual line number and content instead.
  if command -v yq >/dev/null 2>&1; then
    local yq_err
    if ! yq_err=$(yq eval '.' "${CONFIG_FILE}" 2>&1 >/dev/null); then
      err "Config file ${CONFIG_FILE} has YAML syntax errors:
${yq_err}
Run 'yq eval . ${CONFIG_FILE}' for details, then fix the line and retry."
    fi
  fi

  # Parse YAML configuration
  # NOTE: `yq eval '.foo'` on a missing key prints the literal string "null"
  # (not empty), which silently breaks any `${VAR:-fallback}` defaulting later
  # in the script (the var is "set" to the 4-character string "null"). Use
  # `// ""` in the jq-style yq expression so missing/null values become empty
  # strings, then `${VAR:-fallback}` works as intended.
  CLUSTER_NAME=$(yq eval '.cluster.name // ""' "${CONFIG_FILE}" 2>/dev/null || grep '^  name:' "${CONFIG_FILE}" | awk '{print $2}')
  [[ "${CLUSTER_NAME}" == "null" ]] && CLUSTER_NAME=""
  USE_EXISTING=$(yq eval '.cluster.useExisting // "never"' "${CONFIG_FILE}" 2>/dev/null || echo "never")
  [[ "${USE_EXISTING}" == "null" ]] && USE_EXISTING="never"
  REGION=$(yq eval '.cluster.region // ""' "${CONFIG_FILE}" 2>/dev/null || grep '^  region:' "${CONFIG_FILE}" | awk '{print $2}')
  [[ "${REGION}" == "null" ]] && REGION=""

  # Air-gap mode: read from YAML (cluster.airgap: true) and allow env var override.
  # install_from_airgap_bundle.sh sets AIRGAP_MODE=true automatically; customers
  # running the installer directly should set cluster.airgap: true in their config.
  local _yaml_airgap
  _yaml_airgap=$(yq eval '.cluster.airgap // "false"' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  [[ "${_yaml_airgap}" == "null" ]] && _yaml_airgap="false"
  # Env var takes precedence over YAML (allows override without editing the file).
  if [[ "${AIRGAP_MODE:-}" == "true" ]]; then
    : # already set — env var wins
  elif [[ "${_yaml_airgap}" == "true" ]]; then
    export AIRGAP_MODE="true"
  else
    export AIRGAP_MODE="false"
  fi

  # Node IPs (for existing infrastructure)
  EXISTING_CONTROLLER_IPS=$(yq eval '.nodes.existingIPs.controllers[]' "${CONFIG_FILE}" 2>/dev/null | tr '\n' ' ' || echo "")
  EXISTING_WORKER_IPS=$(yq eval '.nodes.existingIPs.workers[]' "${CONFIG_FILE}" 2>/dev/null | tr '\n' ' ' || echo "")
  SSH_USER=$(yq eval '.cluster.sshUser' "${CONFIG_FILE}" 2>/dev/null || echo "root")
  SSH_KEY_PATH=$(yq eval '.cluster.sshKeyPath' "${CONFIG_FILE}" 2>/dev/null || echo "")

  # Validate existingIPs are provided (mandatory for on-prem)
  if [[ -z "${EXISTING_CONTROLLER_IPS}" ]]; then
    err "nodes.existingIPs.controllers must be set in config YAML — this script requires pre-provisioned nodes"
  fi

  CONTROLLER_COUNT=$(yq eval '.nodes.controllers' "${CONFIG_FILE}" 2>/dev/null || echo "1")
  CPU_WORKER_COUNT=$(yq eval '.nodes.cpuWorkers' "${CONFIG_FILE}" 2>/dev/null || echo "2")
  GPU_WORKER_COUNT=$(yq eval '.nodes.gpuWorkers' "${CONFIG_FILE}" 2>/dev/null || echo "1")

  # Storage configuration
  STORAGE_CLASS=$(yq eval '.storage.storageClass // "local-path"' "${CONFIG_FILE}" 2>/dev/null || echo "local-path")
  VECTORDB_SIZE=$(yq eval '.storage.vectorDbSize // "50Gi"' "${CONFIG_FILE}" 2>/dev/null || echo "50Gi")

  # Minimum disk space thresholds (GB) for preflight validation.
  # Customers must ensure /var/lib/k0s has at least this much space before install.
  MIN_DISK_CONTROLLER=$(yq eval '.storage.minimumDiskSpace.controller // "100"' "${CONFIG_FILE}" 2>/dev/null || echo "100")
  MIN_DISK_CPU_WORKER=$(yq eval '.storage.minimumDiskSpace.cpuWorker // "200"' "${CONFIG_FILE}" 2>/dev/null || echo "200")
  MIN_DISK_GPU_WORKER=$(yq eval '.storage.minimumDiskSpace.gpuWorker // "500"' "${CONFIG_FILE}" 2>/dev/null || echo "500")
  # Strip non-numeric suffixes (e.g. "30Gi" -> "30") so arithmetic comparisons work
  MIN_DISK_CONTROLLER="${MIN_DISK_CONTROLLER//[!0-9]/}"
  MIN_DISK_CPU_WORKER="${MIN_DISK_CPU_WORKER//[!0-9]/}"
  MIN_DISK_GPU_WORKER="${MIN_DISK_GPU_WORKER//[!0-9]/}"

  # Object storage: objectStore.type (aws | minio | seaweedfs); s3compat accepted as a legacy alias for minio.
  OBJ_STORE_TYPE="$(yq eval '.storage.objectStore.type // "minio"' "$CONFIG_FILE" 2>/dev/null || echo "minio")"
  # Normalise s3compat → minio so all downstream logic only sees aws | minio | seaweedfs.
  [[ "${OBJ_STORE_TYPE}" == "s3compat" ]] && OBJ_STORE_TYPE="minio"
  OBJ_STORE_BUCKET="$(yq eval '.storage.objectStore.bucket // "ai-platform-data"' "$CONFIG_FILE" 2>/dev/null || echo "ai-platform-data")"
  # Normalize to lowercase — upload scripts apply the same normalization; pre-check and verifier must use the same value.
  OBJ_STORE_BUCKET="$(printf '%s' "${OBJ_STORE_BUCKET}" | tr '[:upper:]' '[:lower:]')"
  OBJ_STORE_ENDPOINT="$(yq eval '.storage.objectStore.endpoint // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  _obj_user="$(yq eval '.storage.objectStore.auth.rootUser // "minioadmin"' "$CONFIG_FILE" 2>/dev/null || echo "minioadmin")"
  _obj_pw="$(yq eval '.storage.objectStore.auth.rootPassword // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  MINIO_ENDPOINT="${OBJ_STORE_ENDPOINT}"
  MINIO_BUCKET="${OBJ_STORE_BUCKET}"
  MINIO_ROOT_USER="${MINIO_ROOT_USER:-$_obj_user}"
  MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$_obj_pw}"

  # Model staging: download from HF + upload to object store before cluster install.
  # Read the raw value without a `// default` — the `// "true"` fallback treats
  # boolean false as falsy and incorrectly returns "true" when enabled: false.
  # Default to "true" only when the key is absent (yq returns "null").
  MODEL_STAGING_ENABLED="$(yq eval '.storage.modelStaging.enabled' "$CONFIG_FILE" 2>/dev/null || echo "null")"
  [[ "${MODEL_STAGING_ENABLED}" == "null" || -z "${MODEL_STAGING_ENABLED}" ]] && MODEL_STAGING_ENABLED="true"

  # Kubernetes namespace
  AI_NS=$(yq eval '.kubernetes.namespace' "${CONFIG_FILE}" 2>/dev/null || echo "ai-platform")

  # Splunk configuration
  AI_STANDALONE_NAME=$(yq eval '.splunk.standaloneName' "${CONFIG_FILE}" 2>/dev/null || echo "splunk-standalone")

  # Splunk telemetry is OPT-IN and defaults to DISABLED. It only turns on when
  # splunk.enabled: true is explicitly set AND the required Splunk images are
  # present (enforced in validate_image_config). When disabled the script skips
  # the Splunk Operator, the Standalone CR, and omits splunkConfiguration from
  # the AIPlatform CR — the operator treats an empty config as "no telemetry".
  # yq returns "null" for an absent key, which we treat as false. yq also mishandles
  # boolean false, so we normalise explicitly.
  SPLUNK_ENABLED="$(yq eval '.splunk.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "null")"
  [[ "${SPLUNK_ENABLED}" != "true" ]] && SPLUNK_ENABLED="false"

  # External Splunk: point telemetry at a Splunk running OUTSIDE the cluster.
  # When splunk.external.endpoint is set (and splunk.enabled is true), the
  # script does NOT install the in-cluster Splunk Operator/Standalone — it only
  # wires the AIPlatform CR at the external HEC endpoint + a Secret holding the
  # HEC token. The token is supplied via the SPLUNK_HEC_TOKEN env var (never the
  # config file), mirroring how MINIO_ROOT_PASSWORD works; the script creates
  # the Secret post-cluster-bootstrap so there is no chicken-and-egg ordering.
  SPLUNK_EXTERNAL_ENDPOINT="$(yq eval '.splunk.external.endpoint // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")"
  [[ "${SPLUNK_EXTERNAL_ENDPOINT}" == "null" ]] && SPLUNK_EXTERNAL_ENDPOINT=""
  SPLUNK_EXTERNAL_SECRET_NAME="$(yq eval '.splunk.external.secretName // "splunk-hec-external"' "${CONFIG_FILE}" 2>/dev/null || echo "splunk-hec-external")"
  [[ -z "${SPLUNK_EXTERNAL_SECRET_NAME}" || "${SPLUNK_EXTERNAL_SECRET_NAME}" == "null" ]] && SPLUNK_EXTERNAL_SECRET_NAME="splunk-hec-external"
  # HEC token: env var only (keep it out of the config file and logs).
  SPLUNK_HEC_TOKEN="${SPLUNK_HEC_TOKEN:-}"

  # Derive a single mode so downstream logic is unambiguous:
  #   disabled  — splunk.enabled=false: no Splunk, no telemetry
  #   external  — splunk.enabled=true + splunk.external.endpoint set: skip
  #               in-cluster Splunk, use customer's external HEC
  #   internal  — splunk.enabled=true, no external endpoint: install SOK +
  #               Standalone in-cluster (legacy behavior)
  if [[ "${SPLUNK_ENABLED}" != "true" ]]; then
    SPLUNK_MODE="disabled"
  elif [[ -n "${SPLUNK_EXTERNAL_ENDPOINT}" ]]; then
    SPLUNK_MODE="external"
  else
    SPLUNK_MODE="internal"
  fi

  # Container images
  IMAGE_REGISTRY="$(yq eval '.images.registry // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  # Set to "true" only for plain-HTTP (no-TLS) registries such as a local mirror.
  # Leave false (default) for ECR, Docker Hub, Harbor, or any HTTPS registry.
  IMAGE_REGISTRY_INSECURE="$(yq eval '.images.registryInsecure // "false"' "$CONFIG_FILE" 2>/dev/null || echo "false")"
  OPERATOR_IMAGE="$(yq eval '.images.operator.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SPLUNK_IMAGE="$(yq eval '.images.splunk.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SPLUNK_OPERATOR_IMAGE="$(yq eval '.images.splunk.operatorImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  RAY_HEAD_IMAGE="$(yq eval '.images.ray.headImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  RAY_WORKER_IMAGE="$(yq eval '.images.ray.workerImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  WEAVIATE_IMAGE="$(yq eval '.images.weaviate.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SAIA_API_IMAGE="$(yq eval '.images.saia.apiImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SAIA_API_V2_IMAGE="$(yq eval '.images.saia.apiV2Image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SAIA_DATALOADER_IMAGE="$(yq eval '.images.saia.dataLoaderImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  SLIM_API_IMAGE="$(yq eval '.images.slim.apiImage' "$CONFIG_FILE" 2>/dev/null || echo "")"
  FLUENT_BIT_IMAGE="$(yq eval '.images.fluentBit.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  OTEL_COLLECTOR_IMAGE="$(yq eval '.images.otelCollector.image' "$CONFIG_FILE" 2>/dev/null || echo "")"
  NGINX_IMAGE="$(yq eval '.images.nginx.image' "$CONFIG_FILE" 2>/dev/null || echo "")"

  # Operator versions
  MODEL_VERSION="$(yq eval '.operators.ray.modelVersion // ""' "$CONFIG_FILE" 2>/dev/null || echo "")"
  RAY_RUNTIME_VERSION="$(yq eval '.operators.ray.rayVersion // "2.44.0"' "$CONFIG_FILE" 2>/dev/null || echo "2.44.0")"

  # AI Platform CR configuration
  DEFAULT_ACCELERATOR=$(yq eval '.aiPlatform.defaultAcceleratorType // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  WORKER_IMAGE_REGISTRY=$(yq eval '.aiPlatform.workerGroupConfig.imageRegistry // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")

  # NVIDIA device plugin version
  NVIDIA_VERSION=$(yq eval '.operators.nvidia.devicePluginVersion // "v0.17.3"' "${CONFIG_FILE}" 2>/dev/null || echo "v0.17.3")

  # ECR configuration (for private image repositories)
  ECR_ACCOUNT=$(yq eval '.ecr.account' "${CONFIG_FILE}" 2>/dev/null || echo "")
  ECR_REGION=$(yq eval '.ecr.region // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")

  # Auto-detect ECR account from AWS if not specified
  if [[ -z "${ECR_ACCOUNT}" ]] && aws sts get-caller-identity &>/dev/null; then
    ECR_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
  fi

  # ImagePullSecrets configuration - read which registries are enabled
  IMAGE_PULL_SECRETS_ECR_ENABLED=$(yq eval '.imagePullSecrets.autoCreateECR' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED=$(yq eval '.imagePullSecrets.dockerHub.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_GCR_ENABLED=$(yq eval '.imagePullSecrets.gcr.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_ACR_ENABLED=$(yq eval '.imagePullSecrets.acr.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")
  IMAGE_PULL_SECRETS_CUSTOM_ENABLED=$(yq eval '.imagePullSecrets.custom.enabled' "${CONFIG_FILE}" 2>/dev/null || echo "false")

  # File paths
  SPLUNK_OPERATOR_FILE=$(yq eval '.files.splunkOperator' "${CONFIG_FILE}" 2>/dev/null || echo "./splunk-operator-cluster.yaml")
  SPLUNK_AI_FILE=$(yq eval '.files.aiPlatform' "${CONFIG_FILE}" 2>/dev/null || echo "./artifacts.yaml")

  log "Configuration loaded: cluster=${CLUSTER_NAME}, namespace=${AI_NS}"
  log "Object storage: ${OBJ_STORE_TYPE}, endpoint=${OBJ_STORE_ENDPOINT:-not set}, bucket=${OBJ_STORE_BUCKET}"
  log "Model staging: ${MODEL_STAGING_ENABLED} (storage.modelStaging.enabled)"
  log "Splunk telemetry: mode=${SPLUNK_MODE} (splunk.enabled=${SPLUNK_ENABLED}${SPLUNK_EXTERNAL_ENDPOINT:+, external endpoint set})"
  if [[ -n "${ECR_ACCOUNT}" ]]; then
    log "ECR Account: ${ECR_ACCOUNT}"
  fi

  # Log which image pull secrets are enabled
  local enabled_registries=()
  [[ "${IMAGE_PULL_SECRETS_ECR_ENABLED}" == "true" ]] && enabled_registries+=("ECR")
  [[ "${IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED}" == "true" ]] && enabled_registries+=("DockerHub")
  [[ "${IMAGE_PULL_SECRETS_GCR_ENABLED}" == "true" ]] && enabled_registries+=("GCR")
  [[ "${IMAGE_PULL_SECRETS_ACR_ENABLED}" == "true" ]] && enabled_registries+=("ACR")
  [[ "${IMAGE_PULL_SECRETS_CUSTOM_ENABLED}" == "true" ]] && enabled_registries+=("Custom")

  if [[ ${#enabled_registries[@]} -gt 0 ]]; then
    log "ImagePullSecrets enabled for: ${enabled_registries[*]}"
  fi
}

# ====== IMAGE HELPERS ======
build_image_url() {
  local registry="$1"
  local image_path="$2"
  # Treat as fully-qualified if image starts with a registry host.
  # Recognised forms: domain.tld/... , domain.tld:port/... , IP/... , IP:port/...
  if [[ "$image_path" =~ ^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/.*:.+ ]]; then
    echo "$image_path"
    return 0
  fi
  if [[ -n "$registry" && "$registry" != "null" ]]; then
    echo "${registry}/${image_path}"
  else
    echo "$image_path"
  fi
}

validate_image_config() {
  log "Validating image configuration..."

  if [[ -z "$OPERATOR_IMAGE" || "$OPERATOR_IMAGE" == "null" ]]; then
    err "REQUIRED: images.operator.image must be specified in k0s-cluster-config.yaml"
  fi
  # Splunk images are only required for INTERNAL mode (in-cluster SOK +
  # Standalone). Disabled and external modes never install those workloads, so a
  # missing images.splunk.image must not fail the whole install.
  if [[ "${SPLUNK_MODE}" == "internal" ]]; then
    if [[ -z "$SPLUNK_IMAGE" || "$SPLUNK_IMAGE" == "null" ]]; then
      err "REQUIRED: images.splunk.image must be specified in k0s-cluster-config.yaml when splunk.enabled is true (internal mode)"
    fi
  fi
  if [[ -z "$RAY_HEAD_IMAGE" || "$RAY_HEAD_IMAGE" == "null" ]]; then
    err "REQUIRED: images.ray.headImage must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$RAY_WORKER_IMAGE" || "$RAY_WORKER_IMAGE" == "null" ]]; then
    err "REQUIRED: images.ray.workerImage must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$WEAVIATE_IMAGE" || "$WEAVIATE_IMAGE" == "null" ]]; then
    err "REQUIRED: images.weaviate.image must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$SAIA_API_IMAGE" || "$SAIA_API_IMAGE" == "null" ]]; then
    err "REQUIRED: images.saia.apiImage must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$SAIA_API_V2_IMAGE" || "$SAIA_API_V2_IMAGE" == "null" ]]; then
    err "REQUIRED: images.saia.apiV2Image must be specified in k0s-cluster-config.yaml"
  fi
  if [[ -z "$SAIA_DATALOADER_IMAGE" || "$SAIA_DATALOADER_IMAGE" == "null" ]]; then
    err "REQUIRED: images.saia.dataLoaderImage must be specified in k0s-cluster-config.yaml"
  fi
  # slim-api is only deployed when the "slim" feature is enabled, so require its
  # image only in that case (mirrors the feature-gated Splunk image handling).
  if k0s_slim_feature_enabled; then
    if [[ -z "$SLIM_API_IMAGE" || "$SLIM_API_IMAGE" == "null" ]]; then
      err "REQUIRED: images.slim.apiImage must be specified in k0s-cluster-config.yaml when the 'slim' feature is enabled"
    fi
  fi
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
  if [[ -z "$NGINX_IMAGE" || "$NGINX_IMAGE" == "null" ]]; then
    NGINX_IMAGE="docker.io/library/nginx:1.27-alpine"
    log "Using default Nginx image: $NGINX_IMAGE"
  fi
  if [[ -z "$MODEL_VERSION" || "$MODEL_VERSION" == "null" ]]; then
    MODEL_VERSION="v0.3.14-36-g1549f5a"
    log "Using default Model version: $MODEL_VERSION"
  fi
  if [[ -z "$RAY_RUNTIME_VERSION" || "$RAY_RUNTIME_VERSION" == "null" ]]; then
    RAY_RUNTIME_VERSION="2.44.0"
    log "Using default Ray runtime version: $RAY_RUNTIME_VERSION"
  fi

  # Every workload container runs imagePullPolicy: IfNotPresent, so re-running
  # install with an unchanged mutable tag (:latest, :preview, :stable-*) will
  # NOT pick up a newer build pushed under that same tag — the kubelet serves
  # the cached layer and the operator's CreateOrUpdate sees no template diff,
  # so no rollout even happens. Upgrades require a new, distinct tag. This is
  # a config-hygiene warning, not an error: mutable tags are still valid for
  # first-time installs.
  local mutable_tag_images=(
    "images.operator.image:${OPERATOR_IMAGE}"
    "images.ray.headImage:${RAY_HEAD_IMAGE}"
    "images.ray.workerImage:${RAY_WORKER_IMAGE}"
    "images.weaviate.image:${WEAVIATE_IMAGE}"
    "images.saia.apiImage:${SAIA_API_IMAGE}"
    "images.saia.apiV2Image:${SAIA_API_V2_IMAGE}"
    "images.saia.dataLoaderImage:${SAIA_DATALOADER_IMAGE}"
    "images.fluentBit.image:${FLUENT_BIT_IMAGE}"
    "images.nginx.image:${NGINX_IMAGE}"
    "images.otelCollector.image:${OTEL_COLLECTOR_IMAGE}"
  )
  # images.splunk.image and images.splunk.operatorImage are only patched into
  # the manifest (and only actually deployed) in internal mode — disabled/
  # external modes never run them.
  if [[ "${SPLUNK_MODE}" == "internal" ]]; then
    mutable_tag_images+=(
      "images.splunk.image:${SPLUNK_IMAGE}"
      "images.splunk.operatorImage:${SPLUNK_OPERATOR_IMAGE}"
    )
  fi
  local entry key image last_segment tag
  for entry in "${mutable_tag_images[@]}"; do
    key="${entry%%:*}"
    image="${entry#*:}"
    if [[ -z "$image" || "$image" == "null" ]]; then
      continue
    fi
    # Parse the tag from the last path segment only, so a registry port
    # (e.g. localhost:5000/team/saia-api) is never mistaken for a tag.
    last_segment="${image##*/}"
    if [[ "$last_segment" == *:* ]]; then
      tag="${last_segment##*:}"
    else
      tag=""
    fi
    if [[ -z "$tag" ]]; then
      warn "${key} (${image}) has no explicit tag — defaults to :latest, which will NOT be re-pulled on a same-tag re-run of install (imagePullPolicy: IfNotPresent). Use a distinct, immutable tag for upgrades to take effect."
    elif [[ "$tag" =~ ^(latest|preview|stable.*|dev|nightly)$ ]]; then
      warn "${key} uses mutable tag ':${tag}' — re-running install without changing this tag will NOT upgrade the running image (imagePullPolicy: IfNotPresent). Use a distinct, immutable tag for upgrades to take effect."
    fi
  done

  log "✓ Image configuration validated successfully"
}

configure_images() {
  log "Configuring container images in manifest files..."

  # Note: this rewrites artifacts.yaml / splunk-operator-cluster.yaml in place
  # on every run via the sed substitutions below. There is no backup/restore
  # from a pristine snapshot — a prior ".original" model silently reverted any
  # legitimate change to these manifests (new operator release, new env var,
  # new sidecar) on every re-run after the first, since the snapshot was never
  # refreshed. The sed patterns below only ever touch their own named
  # RELATED_IMAGE_*/image: fields, so re-running against an already-updated
  # file is idempotent and safe.
  log "Updating $SPLUNK_AI_FILE..."

  local operator_full=$(build_image_url "$IMAGE_REGISTRY" "$OPERATOR_IMAGE")
  local ray_head_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_HEAD_IMAGE")
  local ray_worker_full=$(build_image_url "$IMAGE_REGISTRY" "$RAY_WORKER_IMAGE")
  local weaviate_full=$(build_image_url "$IMAGE_REGISTRY" "$WEAVIATE_IMAGE")
  local saia_api_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_IMAGE")
  local saia_api_v2_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_API_V2_IMAGE")
  local saia_dataloader_full=$(build_image_url "$IMAGE_REGISTRY" "$SAIA_DATALOADER_IMAGE")
  # slim-api is optional (feature-gated); only build a URL when configured.
  local slim_api_full=""
  [[ -n "$SLIM_API_IMAGE" && "$SLIM_API_IMAGE" != "null" ]] && \
    slim_api_full=$(build_image_url "$IMAGE_REGISTRY" "$SLIM_API_IMAGE")
  local fluent_bit_full=$(build_image_url "$IMAGE_REGISTRY" "$FLUENT_BIT_IMAGE")
  local otel_collector_full=$(build_image_url "$IMAGE_REGISTRY" "$OTEL_COLLECTOR_IMAGE")
  # Nginx is an upstream image; don't rewrite it to the ECR registry unless the
  # user explicitly put it under their registry. build_image_url already
  # preserves a fully-qualified image path, so `docker.io/library/nginx:...`
  # stays intact and `nginx:1.27-alpine` gets prefixed with $IMAGE_REGISTRY.
  local nginx_full=$(build_image_url "$IMAGE_REGISTRY" "$NGINX_IMAGE")

  local ray_head_escaped=$(echo "$ray_head_full" | sed 's/[\/&]/\\&/g')
  local ray_worker_escaped=$(echo "$ray_worker_full" | sed 's/[\/&]/\\&/g')
  local weaviate_escaped=$(echo "$weaviate_full" | sed 's/[\/&]/\\&/g')
  local saia_api_escaped=$(echo "$saia_api_full" | sed 's/[\/&]/\\&/g')
  local saia_api_v2_escaped=$(echo "$saia_api_v2_full" | sed 's/[\/&]/\\&/g')
  local saia_dataloader_escaped=$(echo "$saia_dataloader_full" | sed 's/[\/&]/\\&/g')
  local slim_api_escaped=$(echo "$slim_api_full" | sed 's/[\/&]/\\&/g')
  local fluent_bit_escaped=$(echo "$fluent_bit_full" | sed 's/[\/&]/\\&/g')
  local otel_collector_escaped=$(echo "$otel_collector_full" | sed 's/[\/&]/\\&/g')
  local nginx_escaped=$(echo "$nginx_full" | sed 's/[\/&]/\\&/g')
  local operator_escaped=$(echo "$operator_full" | sed 's/[\/&]/\\&/g')

  # BSD (macOS) sed requires an explicit backup-suffix arg after -i.
  # GNU (Linux) sed accepts -i without the suffix arg.
  # Use a bash array so the empty-string "" is preserved as a distinct argv entry
  # on macOS; without this, unquoted $SEDOPTION word-splitting created stray
  # "filename''" backup files next to each artifact.
  local SED_INPLACE
  if [[ "$OSTYPE" == "darwin"* ]]; then
    SED_INPLACE=(sed -i "")
  else
    SED_INPLACE=(sed -i)
  fi

  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_RAY_HEAD/,/value:/ s|value:.*|value: ${ray_head_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_RAY_WORKER/,/value:/ s|value:.*|value: ${ray_worker_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_WEAVIATE/,/value:/ s|value:.*|value: ${weaviate_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SAIA_API$/,/value:/ s|value:.*|value: ${saia_api_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SAIA_API_V2/,/value:/ s|value:.*|value: ${saia_api_v2_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_POST_INSTALL_HOOK/,/value:/ s|value:.*|value: ${saia_dataloader_escaped}|" "$SPLUNK_AI_FILE"
  # slim-api is feature-gated; only rewrite when an image was configured so the
  # manifest's default value survives untouched on saia-only installs.
  if [[ -n "$slim_api_full" ]]; then
    "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SLIM_API/,/value:/ s|value:.*|value: ${slim_api_escaped}|" "$SPLUNK_AI_FILE"
  fi
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_FLUENT_BIT/,/value:/ s|value:.*|value: ${fluent_bit_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_OTEL_COLLECTOR/,/value:/ s|value:.*|value: ${otel_collector_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_NGINX/,/value:/ s|value:.*|value: ${nginx_escaped}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: MODEL_VERSION/,/value:/ s|value:.*|value: ${MODEL_VERSION}|" "$SPLUNK_AI_FILE"
  "${SED_INPLACE[@]}" "/name: RAY_VERSION/,/value:/ s|value:.*|value: ${RAY_RUNTIME_VERSION}|" "$SPLUNK_AI_FILE"
  # Anchor on the RAY_VERSION env entry (unique, always immediately precedes
  # the operator container's image: line) rather than matching the image
  # string's content. A content-based match like *splunk*ai*operator* only
  # matches the pristine manifest's default image; once a custom
  # image (e.g. a private registry with no such substring) has been written
  # here, re-running install with a new tag would silently fail to match and
  # leave the stale image in place.
  "${SED_INPLACE[@]}" "/name: RAY_VERSION/,/^        image:/ s|^        image:.*|        image: ${operator_escaped}|" "$SPLUNK_AI_FILE"

  log "  ✓ Updated RELATED_IMAGE_RAY_HEAD: $ray_head_full"
  log "  ✓ Updated RELATED_IMAGE_RAY_WORKER: $ray_worker_full"
  log "  ✓ Updated RELATED_IMAGE_WEAVIATE: $weaviate_full"
  log "  ✓ Updated RELATED_IMAGE_SAIA_API: $saia_api_full"
  log "  ✓ Updated RELATED_IMAGE_SAIA_API_V2: $saia_api_v2_full"
  log "  ✓ Updated RELATED_IMAGE_POST_INSTALL_HOOK: $saia_dataloader_full"
  [[ -n "$slim_api_full" ]] && log "  ✓ Updated RELATED_IMAGE_SLIM_API: $slim_api_full"
  log "  ✓ Updated RELATED_IMAGE_FLUENT_BIT: $fluent_bit_full"
  log "  ✓ Updated RELATED_IMAGE_OTEL_COLLECTOR: $otel_collector_full"
  log "  ✓ Updated RELATED_IMAGE_NGINX: $nginx_full"
  log "  ✓ Updated operator image: $operator_full"
  log "  ✓ Updated MODEL_VERSION: $MODEL_VERSION"
  log "  ✓ Updated RAY_VERSION: $RAY_RUNTIME_VERSION"

  if [[ "${SPLUNK_MODE}" == "internal" ]]; then
    log "Updating $SPLUNK_OPERATOR_FILE..."

    local splunk_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_IMAGE")
    local splunk_operator_full=$(build_image_url "$IMAGE_REGISTRY" "$SPLUNK_OPERATOR_IMAGE")

    local splunk_escaped=$(echo "$splunk_full" | sed 's/[\/&]/\\&/g')
    local splunk_op_escaped=$(echo "$splunk_operator_full" | sed 's/[\/&]/\\&/g')

    "${SED_INPLACE[@]}" "/name: RELATED_IMAGE_SPLUNK_ENTERPRISE/,/value:/ s|value:.*|value: ${splunk_escaped}|" "$SPLUNK_OPERATOR_FILE"
    # Same rationale as the AI operator image above: anchor on the unique
    # POD_NAME env entry that always immediately precedes this container's
    # image: line, instead of content-matching *splunk*operator* in the
    # image string itself.
    "${SED_INPLACE[@]}" "/name: POD_NAME/,/^        image:/ s|^        image:.*|        image: ${splunk_op_escaped}|" "$SPLUNK_OPERATOR_FILE"

    log "  ✓ Updated Splunk Enterprise image: $splunk_full"
    log "  ✓ Updated Splunk Operator image: $splunk_operator_full"
  else
    log "Splunk mode=${SPLUNK_MODE} — skipping Splunk Operator manifest rewrite (no in-cluster Splunk)"
  fi
  log "✓ All images configured successfully"
}

# True if objectStore.auth values are still obvious template text. Non-empty
# placeholders otherwise pass the length preflight and get applied into
# minio-credentials, which makes SAIA fail at startup with InvalidAccessKeyId.
object_store_auth_looks_like_placeholder() {
  case "${MINIO_ROOT_USER}${MINIO_ROOT_PASSWORD}" in
    *\<*|*\>*) return 0 ;;
    *CHANGEME*|*changeme*) return 0 ;;
  esac
  return 1
}

# ====== PREFLIGHT CHECKS ======
preflight_checks() {
  pf_header "Required tools"
  for tool in ssh curl kubectl helm git jq; do
    if command -v "$tool" >/dev/null 2>&1; then
      pf_ok "$tool found"
    else
      pf_fail "$tool not found in PATH"
    fi
  done

  # yq is strongly recommended — without it, config parsing falls back to
  # grep/awk which cannot handle arrays or nested structures reliably.
  if command -v yq >/dev/null 2>&1; then
    pf_ok "yq found"
  else
    pf_warn "yq not found — install it for reliable config parsing (brew install yq / snap install yq). Falling back to grep/awk which may miss complex config values."
  fi

  # python3 is used by preflight_check_registry() to parse Bearer token JSON.
  # Without it the auth check degrades gracefully (skips manifest probe) but
  # it is good to surface the gap early.
  if command -v python3 >/dev/null 2>&1; then
    pf_ok "python3 found"
  else
    pf_warn "python3 not found — image registry auth check will be skipped (install python3 to enable it)."
  fi

  # Object-store CLI tools — used for the model staging pre-check.
  # If absent, the pre-check is skipped and staging proceeds unconditionally
  # (fail-open); install will still succeed but staged-model validation is bypassed.
  case "${OBJ_STORE_TYPE:-}" in
    aws)
      if command -v aws >/dev/null 2>&1; then
        pf_ok "aws CLI found"
      else
        pf_warn "aws CLI not found — model staging pre-check will be skipped. Install aws CLI to enable it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      fi
      ;;
    minio|seaweedfs|s3compat)
      if command -v mc >/dev/null 2>&1; then
        pf_ok "mc (MinIO client) found"
      else
        pf_warn "mc (MinIO client) not found — model staging pre-check will be skipped. Install mc to enable it: https://min.io/docs/minio/linux/reference/minio-mc.html"
      fi
      ;;
  esac

  pf_header "Configuration"
  [[ -n "${CLUSTER_NAME}" ]] && pf_ok "Cluster name: ${CLUSTER_NAME}" || pf_fail "Cluster name not set"
  case "${SPLUNK_MODE}" in
    internal)
      [[ -f "${SPLUNK_OPERATOR_FILE}" ]] && pf_ok "Splunk operator file: ${SPLUNK_OPERATOR_FILE}" || pf_warn "Splunk operator file not found: ${SPLUNK_OPERATOR_FILE}"
      ;;
    external)
      pf_ok "Splunk telemetry: external → ${SPLUNK_EXTERNAL_ENDPOINT} (secret=${SPLUNK_EXTERNAL_SECRET_NAME}, in-cluster Splunk skipped)"
      # The HEC token must be supplied via env; fail fast here rather than
      # discovering it at CR-apply time after the cluster is already up.
      [[ -n "${SPLUNK_HEC_TOKEN}" ]] && pf_ok "SPLUNK_HEC_TOKEN is set (external HEC token)" || pf_fail "Splunk external mode requires the HEC token: export SPLUNK_HEC_TOKEN before running the installer."
      # Endpoint should be a base HEC URL; the operator appends /services/collector.
      [[ "${SPLUNK_EXTERNAL_ENDPOINT}" =~ ^https?:// ]] && pf_ok "External HEC endpoint scheme OK" || pf_warn "splunk.external.endpoint should start with http:// or https:// (got: ${SPLUNK_EXTERNAL_ENDPOINT})"
      ;;
    *)
      pf_ok "Splunk telemetry disabled (splunk.enabled=false) — Splunk Operator/Standalone will be skipped"
      ;;
  esac
  [[ -f "${SPLUNK_AI_FILE}" ]] && pf_ok "AI platform file: ${SPLUNK_AI_FILE}" || pf_warn "AI platform file not found: ${SPLUNK_AI_FILE}"

  pf_header "Object storage (customer-managed)"
  pf_ok "Object storage type: ${OBJ_STORE_TYPE} (bucket=${OBJ_STORE_BUCKET})"
  case "${OBJ_STORE_TYPE}" in
    seaweedfs)
      if echo "${OBJ_STORE_ENDPOINT}" | grep -q ':9000'; then
        pf_warn "SeaweedFS uses port 8333 (not 9000). Endpoint has :9000 (MinIO); use http://host:8333 for SeaweedFS."
      else
        [[ -n "${OBJ_STORE_ENDPOINT}" ]] && pf_ok "SeaweedFS endpoint: ${OBJ_STORE_ENDPOINT}" || pf_fail "objectStore.endpoint is required"
      fi
      ;;
    minio)
      [[ -n "${OBJ_STORE_ENDPOINT}" ]] && pf_ok "Endpoint: ${OBJ_STORE_ENDPOINT}" || pf_fail "objectStore.endpoint is required"
      ;;
    aws)
      # type=aws does NOT require endpoint — boto3 derives the regional URL
      # from AWS_REGION. If a user does pass one (e.g. for VPC endpoint pinning
      # or testing), warn that the installer will ignore it for the AIPlatform
      # CR. Only AWS regional hosts are sane here; anything else means the
      # user likely meant type=s3compat.
      if [[ -n "${OBJ_STORE_ENDPOINT}" ]]; then
        case "${OBJ_STORE_ENDPOINT}" in
          *.amazonaws.com|*amazonaws.com*) pf_warn "type=aws: ignoring objectStore.endpoint='${OBJ_STORE_ENDPOINT}' (boto3 will derive the regional URL from AWS_REGION)." ;;
          *) pf_warn "type=aws but endpoint '${OBJ_STORE_ENDPOINT}' is not an AWS host. If you meant to point at MinIO/SeaweedFS, change objectStore.type to s3compat. The endpoint will be dropped for type=aws." ;;
        esac
      else
        pf_ok "Endpoint: (using default AWS S3 regional URL from AWS_REGION)"
      fi
      ;;
    *)
      pf_fail "Unsupported objectStore.type: ${OBJ_STORE_TYPE}. Supported: aws, minio, seaweedfs (s3compat is accepted as a legacy alias for minio)"
      ;;
  esac
  [[ -n "${MINIO_ROOT_PASSWORD}" ]] && pf_ok "Credentials configured" || pf_fail "Object store credentials required (objectStore.auth.rootPassword)"
  if object_store_auth_looks_like_placeholder; then
    pf_fail "objectStore.auth still contains template placeholders (e.g. <...> or CHANGEME). Replace with a real access key and secret in your config (keep secrets in a Git-ignored file such as tools/cluster_setup/k0s-config.local.yaml)."
  fi
  # Reject STS temporary credentials early — the minio-credentials Secret schema
  # has no AWS_SESSION_TOKEN field, so ASIA* keys silently fail at SAIA startup
  # with InvalidToken. Permanent IAM keys (AKIA*) are required. See
  # codeguard-1-hardcoded-credentials for IAM user setup guidance.
  case "${MINIO_ROOT_USER}" in
    ASIA*) pf_fail "objectStore.auth.rootUser '${MINIO_ROOT_USER}' is an STS temporary key (ASIA…). The k0s installer does not propagate AWS_SESSION_TOKEN; use a permanent IAM access key (AKIA…) instead. To mint one: aws iam create-access-key --user-name <iam-user>." ;;
  esac

  # Verify the image registry is reachable and credentials work before committing
  # to a multi-minute install that would fail at ImagePullBackOff otherwise.
  preflight_check_registry

  pf_header "Infrastructure mode"
  pf_ok "Using existing infrastructure (on-prem/baremetal)"
  pf_ok "Controller IPs: ${EXISTING_CONTROLLER_IPS}"
  pf_ok "Worker IPs: ${EXISTING_WORKER_IPS}"
  [[ -n "${SSH_KEY_PATH}" && -f "${SSH_KEY_PATH}" ]] && pf_ok "SSH key: ${SSH_KEY_PATH}" || pf_fail "SSH key not found: ${SSH_KEY_PATH}"

  # Validate SSH reachability for all nodes before any install begins
  pf_header "Remote node SSH access"
  local _all_ips=()
  IFS=' ' read -ra _all_ips <<< "${EXISTING_CONTROLLER_IPS} ${EXISTING_WORKER_IPS}"
  for ip in "${_all_ips[@]}"; do
    [[ -z "$ip" ]] && continue
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        ${SSH_KEY_PATH:+-i "${SSH_KEY_PATH}"} "${SSH_USER}@${ip}" "echo ok" >/dev/null 2>&1; then
      pf_ok "SSH reachable: ${ip}"
    else
      pf_fail "Cannot SSH to ${ip} — check SSH key (${SSH_KEY_PATH}), user (${SSH_USER}), and network"
    fi
  done

  # Validate disk space on every node (requires SSH access)
  preflight_check_node_storage

  # Validate remote node software prerequisites
  preflight_check_remote_deps

  pf_summary
}

# ====== SSH HELPER ======
ssh_exec() {
  local host="$1"
  shift
  local cmd="$*"

  if [[ -n "${SSH_KEY_PATH}" ]]; then
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        -i "${SSH_KEY_PATH}" "${SSH_USER}@${host}" "${cmd}"
  else
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        "${SSH_USER}@${host}" "${cmd}"
  fi
}

scp_file() {
  local file="$1"
  local host="$2"
  local dest="$3"

  if [[ -n "${SSH_KEY_PATH}" ]]; then
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${SSH_KEY_PATH}" "${file}" "${SSH_USER}@${host}:${dest}"
  else
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${file}" "${SSH_USER}@${host}:${dest}"
  fi
}

# Stage pre-loaded container-image bundles onto a node so k0s auto-imports them
# from disk at startup instead of pulling over a (blocked) internet link. Copies
# EVERY *.tar from the bundle's images/ dir into the node's /var/lib/k0s/images/,
# covering both k0s control-plane images (k0s-images.tar: pause/calico/kube-proxy/
# coredns/…) and add-on component images (addon-images.tar: cert-manager/
# prometheus/metallb/…). k0s imports all tarballs in that directory at startup.
#
# MUST be called AFTER `k0s install` (which, together with the stale-state cleanup,
# recreates /var/lib/k0s) and BEFORE `k0s start` (k0s scans /var/lib/k0s/images/
# only at kubelet startup). No-op unless AIRGAP_K0S_IMAGE_DIR points at a dir with
# at least one *.tar (set only by install_from_airgap_bundle.sh).
stage_k0s_image_bundle() {
  local node_ip="$1"
  [[ -n "${AIRGAP_K0S_IMAGE_DIR:-}" && -d "${AIRGAP_K0S_IMAGE_DIR}" ]] || return 0
  local _tars=( "${AIRGAP_K0S_IMAGE_DIR}"/*.tar )
  [[ -f "${_tars[0]}" ]] || return 0
  ssh_exec "${node_ip}" "sudo mkdir -p /var/lib/k0s/images" \
    || { warn "    Could not create /var/lib/k0s/images on ${node_ip} — images may fail to pull"; return 0; }
  local _tar _name
  for _tar in "${_tars[@]}"; do
    _name="$(basename "${_tar}")"
    log "    Staging image bundle ${_name} on ${node_ip} (/var/lib/k0s/images/)..."
    if scp_file "${_tar}" "${node_ip}" "/tmp/${_name}"; then
      ssh_exec "${node_ip}" "sudo mv -f /tmp/${_name} /var/lib/k0s/images/${_name}" \
        || warn "    Failed to place ${_name} on ${node_ip} — some images may fail to pull"
    else
      warn "    Failed to copy ${_name} to ${node_ip} — some images may fail to pull"
    fi
  done
}

# ====== PREFLIGHT: REGISTRY REACHABILITY CHECK ======
# Verifies the configured image registry is reachable and credentials work
# BEFORE any install work begins, so a bad registry config fails fast with a
# clear message instead of surfacing as ImagePullBackOff minutes later.
#
# Strategy: hit the OCI /v2/ ping endpoint (all standard registries implement it),
# then attempt a manifest HEAD for one representative image to confirm auth works
# end-to-end. Uses only curl — no Docker/crane/skopeo required.
#
# Auth dispatch:
#   ECR        → aws ecr get-login-password  (Bearer token)
#   DockerHub  → imagePullSecrets.dockerHub creds
#   GCR        → imagePullSecrets.gcr.jsonKey (_json_key)
#   ACR        → imagePullSecrets.acr creds
#   Custom     → imagePullSecrets.custom creds (or unauthenticated if none)
#   No registry set → public DockerHub (no auth needed)
preflight_check_registry() {
  pf_header "Image registry reachability"

  # No registry configured → images pull from Docker Hub / public — nothing to check
  if [[ -z "${IMAGE_REGISTRY}" || "${IMAGE_REGISTRY}" == "null" ]]; then
    pf_ok "No private registry configured — images pull from public registries (Docker Hub etc.)"
    return
  fi

  # Determine protocol scheme for the ping URL
  local scheme="https"
  [[ "${IMAGE_REGISTRY_INSECURE:-false}" == "true" ]] && scheme="http"

  local ping_url="${scheme}://${IMAGE_REGISTRY}/v2/"
  # curl_opts: no -f so HTTP 4xx is not treated as a curl error; we read the status code ourselves.
  local curl_opts=(--silent --connect-timeout 10 --max-time 15)
  [[ "${IMAGE_REGISTRY_INSECURE:-false}" == "true" ]] && curl_opts+=(--insecure)

  # ---- Step 1: TCP/TLS reachability ----
  # 200 → open registry; 401/403 → reachable but needs auth (expected); anything else → problem.
  # Note: %{http_code} already outputs "000" on connection failure, so no || echo needed.
  local http_code
  http_code=$(curl "${curl_opts[@]}" -o /dev/null -w "%{http_code}" "${ping_url}" 2>/dev/null)
  case "${http_code}" in
    200|401|403)
      pf_ok "Registry reachable: ${ping_url} (HTTP ${http_code})"
      ;;
    000)
      pf_fail "Registry unreachable: cannot connect to ${ping_url} (connection refused / DNS failure / firewall). Fix images.registry or ensure network path to registry is open."
      return
      ;;
    *)
      # Any other HTTP code (400, 404, 500…) means TCP + TLS succeeded — the host
      # is reachable even if it is not an OCI-compliant registry endpoint.
      pf_warn "Registry ${IMAGE_REGISTRY} answered HTTP ${http_code} on /v2/ ping (not a standard OCI response, but host is reachable). Proceeding to manifest check."
      ;;
  esac

  # ---- Step 2: Auth + manifest pull for one representative image ----
  # Pick the first image that actually resolves to IMAGE_REGISTRY after applying
  # build_image_url. The operator image is often fully-qualified to docker.io while
  # Ray/SAIA images are short refs that build_image_url prefixes with IMAGE_REGISTRY —
  # probing only the operator image would miss auth/tag problems in the private registry.
  # Regex: fully-qualified = starts with domain[:port]/ or IP[:port]/
  local _fq_re='^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/'

  # _image_targets_registry <raw_config_value>
  # Returns 0 and prints the repo:tag portion if the image (after build_image_url)
  # targets IMAGE_REGISTRY; returns 1 otherwise.
  _image_targets_registry() {
    local raw="$1"
    [[ -z "${raw}" || "${raw}" == "null" ]] && return 1
    local full
    full=$(build_image_url "${IMAGE_REGISTRY}" "${raw}")
    # After build_image_url, fully-qualified refs that didn't match IMAGE_REGISTRY
    # are returned unchanged; strip IMAGE_REGISTRY/ prefix to get repo:tag.
    if [[ "${full}" == ${IMAGE_REGISTRY}/* ]]; then
      echo "${full#${IMAGE_REGISTRY}/}"
      return 0
    fi
    return 1
  }

  local probe_ref=""
  local probe_source=""
  for _candidate_var in SAIA_API_IMAGE RAY_HEAD_IMAGE SAIA_API_V2_IMAGE SAIA_DATALOADER_IMAGE SLIM_API_IMAGE RAY_WORKER_IMAGE WEAVIATE_IMAGE FLUENT_BIT_IMAGE OTEL_COLLECTOR_IMAGE NGINX_IMAGE SPLUNK_IMAGE SPLUNK_OPERATOR_IMAGE OPERATOR_IMAGE; do
    local _val="${!_candidate_var:-}"
    local _ref
    if _ref=$(_image_targets_registry "${_val}"); then
      probe_ref="${_ref}"
      probe_source="${_candidate_var}"
      break
    fi
  done

  if [[ -z "${probe_ref}" ]]; then
    pf_warn "No images in config target IMAGE_REGISTRY (${IMAGE_REGISTRY}) — all images appear to be fully qualified to other registries. Skipping auth check."
    return
  fi

  pf_ok "Probing registry with ${probe_source} image: ${IMAGE_REGISTRY}/${probe_ref}"

  # Split repo and tag/digest
  local probe_repo probe_tag
  if [[ "${probe_ref}" == *"@"* ]]; then
    probe_repo="${probe_ref%%@*}"
    probe_tag="${probe_ref##*@}"
    local manifest_url="${scheme}://${IMAGE_REGISTRY}/v2/${probe_repo}/manifests/${probe_tag}"
  else
    probe_repo="${probe_ref%%:*}"
    probe_tag="${probe_ref##*:}"
    [[ "${probe_tag}" == "${probe_ref}" ]] && probe_tag="latest"
    local manifest_url="${scheme}://${IMAGE_REGISTRY}/v2/${probe_repo}/manifests/${probe_tag}"
  fi

  local auth_header=""

  # Resolve auth credentials by registry type
  if [[ "${IMAGE_REGISTRY}" == *.dkr.ecr.*.amazonaws.com ]]; then
    # ECR: exchange AWS credentials for a short-lived token
    local _ecr_region="${ECR_REGION:-${REGION:-us-east-2}}"
    if ! command -v aws &>/dev/null; then
      pf_warn "ECR registry configured but aws CLI not found — skipping auth check."
      return
    fi
    local _ecr_token
    if ! _ecr_token=$(aws ecr get-login-password --region "${_ecr_region}" 2>/dev/null); then
      pf_fail "Cannot obtain ECR token (aws ecr get-login-password failed). Check AWS credentials and IAM permissions (ecr:GetAuthorizationToken)."
      return
    fi
    auth_header="Authorization: Basic $(printf 'AWS:%s' "${_ecr_token}" | base64 | tr -d '\n')"

  elif [[ "${IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED}" == "true" && "${IMAGE_REGISTRY}" == *"docker.io"* ]]; then
    local _dh_user _dh_pass
    _dh_user=$(yq eval '.imagePullSecrets.dockerHub.username' "${CONFIG_FILE}" 2>/dev/null)
    _dh_pass=$(yq eval '.imagePullSecrets.dockerHub.password' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -n "${_dh_user}" && -n "${_dh_pass}" && "${_dh_user}" != "null" && "${_dh_pass}" != "null" ]]; then
      auth_header="Authorization: Basic $(printf '%s:%s' "${_dh_user}" "${_dh_pass}" | base64 | tr -d '\n')"
    fi

  elif [[ "${IMAGE_PULL_SECRETS_ACR_ENABLED}" == "true" && "${IMAGE_REGISTRY}" == *".azurecr.io"* ]]; then
    local _acr_user _acr_pass
    _acr_user=$(yq eval '.imagePullSecrets.acr.username' "${CONFIG_FILE}" 2>/dev/null)
    _acr_pass=$(yq eval '.imagePullSecrets.acr.password' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -n "${_acr_user}" && -n "${_acr_pass}" && "${_acr_user}" != "null" && "${_acr_pass}" != "null" ]]; then
      auth_header="Authorization: Basic $(printf '%s:%s' "${_acr_user}" "${_acr_pass}" | base64 | tr -d '\n')"
    fi

  elif [[ "${IMAGE_PULL_SECRETS_CUSTOM_ENABLED}" == "true" ]]; then
    local _custom_user _custom_pass
    _custom_user=$(yq eval '.imagePullSecrets.custom.username' "${CONFIG_FILE}" 2>/dev/null)
    _custom_pass=$(yq eval '.imagePullSecrets.custom.password' "${CONFIG_FILE}" 2>/dev/null)
    if [[ -n "${_custom_user}" && -n "${_custom_pass}" && "${_custom_user}" != "null" && "${_custom_pass}" != "null" ]]; then
      auth_header="Authorization: Basic $(printf '%s:%s' "${_custom_user}" "${_custom_pass}" | base64 | tr -d '\n')"
    fi
  fi
  # GCR uses a JSON key which is awkward with curl Basic auth and is typically
  # handled by Workload Identity in production — just check TCP reachability for GCR.

  # Many registries (Harbor, ECR, JFrog) use Bearer token auth: they return a
  # 401 with Www-Authenticate on the manifest endpoint and expect us to exchange
  # the basic creds for a Bearer token. Handle both flows.
  # _bearer_exchange: given a manifest URL and optional Basic auth header, tries
  # to fetch a Bearer token from the Www-Authenticate challenge and return the
  # final manifest HTTP code after the Bearer retry.
  # $1 = current http_code (must be "401"), $2 = manifest_url, $3 = auth_header (may be empty)
  _bearer_exchange() {
    local _cur_code="$1" _murl="$2" _ahdr="${3:-}"
    [[ "${_cur_code}" != "401" ]] && { echo "${_cur_code}"; return; }

    local _www_auth _realm _service _scope _tok _tok_code
    local _basic_opts=("${curl_opts[@]}")
    [[ -n "${_ahdr}" ]] && _basic_opts+=(-H "${_ahdr}")

    _www_auth=$(curl "${_basic_opts[@]}" -o /dev/null -D - "${_murl}" 2>/dev/null \
                | grep -i '^Www-Authenticate:' | head -1)
    _realm=$(echo "${_www_auth}"   | grep -oP 'realm="[^"]+"'   | cut -d'"' -f2)
    _service=$(echo "${_www_auth}" | grep -oP 'service="[^"]+"' | cut -d'"' -f2)
    _scope=$(echo "${_www_auth}"   | grep -oP 'scope="[^"]+"'   | cut -d'"' -f2)

    [[ -z "${_realm}" ]] && { echo "401"; return; }

    local _turl="${_realm}?service=${_service}&scope=${_scope}"
    _tok=$(curl "${_basic_opts[@]}" "${_turl}" 2>/dev/null \
           | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token') or d.get('access_token',''))" \
           2>/dev/null || true)

    [[ -z "${_tok}" ]] && { echo "401"; return; }

    _tok_code=$(curl "${curl_opts[@]}" \
      -H "Authorization: Bearer ${_tok}" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
      -o /dev/null -w "%{http_code}" \
      "${_murl}" 2>/dev/null)
    echo "${_tok_code}"
  }

  local manifest_http_code
  if [[ -n "${auth_header}" ]]; then
    manifest_http_code=$(curl "${curl_opts[@]}" \
      -H "${auth_header}" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
      -o /dev/null -w "%{http_code}" \
      "${manifest_url}" 2>/dev/null)

    # If we got 401, the registry wants Bearer auth — exchange basic creds for a token
    if [[ "${manifest_http_code}" == "401" ]]; then
      manifest_http_code=$(_bearer_exchange "401" "${manifest_url}" "${auth_header}")
    fi
  else
    # Unauthenticated probe (public registry or no matching pull-secret config).
    # Public registries like Docker Hub still return 401 + Www-Authenticate to trigger
    # anonymous Bearer token exchange — attempt that before reporting auth failure.
    manifest_http_code=$(curl "${curl_opts[@]}" \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
      -o /dev/null -w "%{http_code}" \
      "${manifest_url}" 2>/dev/null)

    if [[ "${manifest_http_code}" == "401" ]]; then
      manifest_http_code=$(_bearer_exchange "401" "${manifest_url}" "")
    fi
  fi

  case "${manifest_http_code}" in
    200|206)
      pf_ok "Registry auth OK: manifest reachable for ${probe_repo}:${probe_tag}"
      ;;
    401|403)
      pf_fail "Registry credentials rejected (HTTP ${manifest_http_code}) for ${IMAGE_REGISTRY}. Check imagePullSecrets config — images will fail to pull at deploy time."
      ;;
    404)
      # 404 on the manifest means registry is reachable + auth works, but this specific
      # tag is not present. That is a config error, not a connectivity error.
      pf_fail "Image not found in registry (HTTP 404): ${IMAGE_REGISTRY}/${probe_repo}:${probe_tag}. Check that images.operator.image tag exists in the registry."
      ;;
    000)
      pf_fail "Registry manifest check failed: no response from ${manifest_url}. Check network path and registry health."
      ;;
    *)
      pf_warn "Registry manifest check returned HTTP ${manifest_http_code} for ${probe_repo}:${probe_tag} — verify registry is healthy."
      ;;
  esac
}

# ====== PREFLIGHT: REMOTE NODE DEPENDENCY CHECK ======
# SSHs to every node and reports what is present vs missing BEFORE install.
# Does not install anything — surfaces gaps so the operator can fix them
# upfront rather than hitting a silent failure mid-run.
preflight_check_remote_deps() {
  pf_header "Remote node dependencies"
  local _all_ips=()
  IFS=' ' read -ra _all_ips <<< "${EXISTING_CONTROLLER_IPS} ${EXISTING_WORKER_IPS}"
  for ip in "${_all_ips[@]}"; do
    [[ -z "$ip" ]] && continue

    # python3
    if ssh_exec "${ip}" "command -v python3 >/dev/null 2>&1"; then
      pf_ok "${ip}: python3 found"
    else
      pf_warn "${ip}: python3 not found — installer will attempt install via dnf/apt"
    fi

    # passwordless sudo
    if ssh_exec "${ip}" "sudo -n true 2>/dev/null"; then
      pf_ok "${ip}: passwordless sudo available"
    else
      pf_fail "${ip}: passwordless sudo required — add '${SSH_USER} ALL=(ALL) NOPASSWD:ALL' to /etc/sudoers"
    fi

    # curl (needed to download k0s binary if not pre-installed)
    if ssh_exec "${ip}" "command -v curl >/dev/null 2>&1"; then
      pf_ok "${ip}: curl found"
    else
      pf_warn "${ip}: curl not found — k0s binary download will fail (pre-install k0s or install curl)"
    fi

    # internet access to k0s install endpoint — only meaningful if curl is present
    if ! ssh_exec "${ip}" "command -v curl >/dev/null 2>&1"; then
      pf_warn "${ip}: skipping get.k0s.sh reachability check — curl is not installed"
    elif ssh_exec "${ip}" "curl -sf --connect-timeout 5 https://get.k0s.sh >/dev/null 2>&1"; then
      pf_ok "${ip}: internet access OK (get.k0s.sh reachable)"
    else
      pf_warn "${ip}: cannot reach get.k0s.sh — airgapped cluster requires k0s pre-installed on nodes"
    fi
  done
}

# ====== PREPARE NODES (RHEL/Fedora compatibility + k0s binary) ======
prepare_nodes_for_k0s() {
  local node_ips=("$@")
  log "Preparing ${#node_ips[@]} node(s) for k0s (OS compatibility + binary)..."
  for node_ip in "${node_ips[@]}"; do
    log "  Preparing node ${node_ip}..."
    _check_node_os "${node_ip}" "node"

    # Air-gap: push the bundled k0s binary from THIS host (the installer machine)
    # to the node. K0S_INSTALL_URL=file://... points at a path on the installer
    # host, NOT the node, and the env var does not cross the SSH boundary into the
    # heredoc below — so the node can neither read that path nor reach the internet
    # to curl get.k0s.sh. We copy the binary to /tmp/k0s-airgap (writable by the
    # SSH user) and the remote script installs it from there.
    if [[ "${AIRGAP_MODE}" == "true" && -n "${K0S_INSTALL_URL:-}" && "${K0S_INSTALL_URL}" == file://* ]]; then
      local _k0s_src="${K0S_INSTALL_URL#file://}"
      if [[ -f "${_k0s_src}" ]]; then
        log "    Copying bundled k0s binary to ${node_ip}:/tmp/k0s-airgap ..."
        scp_file "${_k0s_src}" "${node_ip}" "/tmp/k0s-airgap" \
          || warn "    Failed to copy k0s binary to ${node_ip} — node install may fail"
      else
        warn "    Bundled k0s binary not found at ${_k0s_src} — node will fall back to other install paths"
      fi
    fi

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      ${SSH_KEY_PATH:+-i "${SSH_KEY_PATH}"} "${SSH_USER}@${node_ip}" \
      bash -s <<'REMOTE_SCRIPT' || warn "  Preparation had issues on ${node_ip}"
      # Disable firewalld if active (blocks k0s ports: 6443, 10250, 8472, etc.)
      if systemctl is-active firewalld >/dev/null 2>&1; then
        echo 'Disabling firewalld...'
        sudo systemctl stop firewalld
        sudo systemctl disable firewalld
      fi

      # Load kernel modules required by Calico and kube-proxy
      for mod in br_netfilter overlay nf_conntrack; do
        if ! lsmod | grep -q "^${mod} "; then
          sudo modprobe "${mod}" 2>/dev/null || echo "WARN: could not load kernel module ${mod}"
        fi
      done
      # Persist across reboots
      sudo mkdir -p /etc/modules-load.d
      printf 'br_netfilter\noverlay\nnf_conntrack\n' | sudo tee /etc/modules-load.d/k0s.conf >/dev/null

      # Ensure python3 + PyYAML are available (used for k0s config generation)
      if python3 -c 'import yaml' 2>/dev/null; then
        echo "python3+pyyaml already present"
      else
        echo "Installing python3-pyyaml..."
        # In air-gap mode: prefer a pre-downloaded wheel if provided, then fall
        # back to the OS package manager (which will succeed if a local repo
        # mirror is configured on the node).  Internet-only paths are guarded
        # by the AIRGAP_PYYAML_WHEEL_PATH check so we never silently skip them.
        if [[ -n "${AIRGAP_PYYAML_WHEEL_PATH:-}" && -f "${AIRGAP_PYYAML_WHEEL_PATH}" ]]; then
          echo "Installing pyyaml from bundled wheel ${AIRGAP_PYYAML_WHEEL_PATH}..."
          sudo pip3 install --no-index --find-links="$(dirname "${AIRGAP_PYYAML_WHEEL_PATH}")" pyyaml 2>/dev/null \
            || sudo pip3 install "${AIRGAP_PYYAML_WHEEL_PATH}" 2>/dev/null \
            || echo "WARN: pip3 wheel install failed — python3-pyyaml may be missing"
        elif command -v dnf >/dev/null 2>&1; then
          sudo dnf install -y python3-pyyaml 2>/dev/null || sudo pip3 install pyyaml 2>/dev/null || true
        elif command -v apt-get >/dev/null 2>&1; then
          sudo apt-get install -y python3-yaml 2>/dev/null || true
        else
          echo "WARN: no supported package manager (dnf/apt) found — python3-pyyaml may be missing"
        fi
      fi

      # Install k0s binary if not present
      if command -v k0s >/dev/null 2>&1; then
        echo "k0s binary already present ($(k0s version 2>/dev/null || echo unknown))"
      elif [ -f /tmp/k0s-airgap ]; then
        # Air-gap: the installer host scp'd the bundled binary here before this
        # heredoc ran. Prefer it over any network path so an air-gapped node
        # never tries to reach the internet.
        echo "Installing k0s binary from air-gap bundle (/tmp/k0s-airgap)..."
        sudo cp /tmp/k0s-airgap /usr/local/bin/k0s && sudo chmod +x /usr/local/bin/k0s
        rm -f /tmp/k0s-airgap
      else
        echo "Installing k0s binary..."
        if [[ -n "${K0S_INSTALL_URL:-}" && "${K0S_INSTALL_URL}" == file://* ]]; then
          sudo cp "${K0S_INSTALL_URL#file://}" /usr/local/bin/k0s && sudo chmod +x /usr/local/bin/k0s
        else
          curl -sSLf "${K0S_INSTALL_URL:-https://get.k0s.sh}" | sudo sh
        fi
      fi

      # Ensure k0s is in sudo secure_path
      if [ -f /usr/local/bin/k0s ] && [ ! -f /usr/bin/k0s ]; then
        sudo ln -sf /usr/local/bin/k0s /usr/bin/k0s
      fi
REMOTE_SCRIPT
  done
}

# ====== PREFLIGHT: NODE STORAGE VALIDATION ======
# On-prem / baremetal nodes must have sufficient disk space BEFORE running the
# installer. This function SSHs to every node and verifies the filesystem
# backing /var/lib/k0s (or / on first install) meets the minimum threshold.
#
# Thresholds (configurable via storage.minimumDiskSpace in config YAML):
#   Controller : 100 GB (k0s control plane, kine/etcd, container images)
#   CPU worker : 200 GB (weaviate, saia-api, data-loader, fluent-bit, etc.)
#   GPU worker : 500 GB (model weights 60-240 GB each, ray-worker-gpu image ~30 GB)
#
# If a dedicated disk is available, the customer should mount it at
# /var/lib/k0s before running this script.
preflight_check_node_storage() {
  pf_header "Node storage"

  IFS=' ' read -ra _ctrl_ips <<< "${EXISTING_CONTROLLER_IPS}"
  IFS=' ' read -ra _worker_ips <<< "${EXISTING_WORKER_IPS}"

  # Helper: SSH to a node and return available GB on the filesystem backing
  # /var/lib/k0s (falls back to / if k0s hasn't been installed yet).
  #
  # Resilience notes:
  #   - Uses POSIX `df -Pk` instead of `df --output=avail` so it works on
  #     BusyBox / non-GNU coreutils. The 4th awk column (`$4`) is the avail
  #     count in 1024-byte blocks across POSIX-compliant df implementations.
  #   - Distinguishes SSH failure (rc=255) from "df returned no data" so the
  #     caller can show a helpful error instead of a misleading "0 GB" that
  #     looks like an actual disk-pressure problem.
  #   - 10s SSH timeout so a bad host doesn't stall the whole preflight.
  _get_avail_gb() {
    local ip="$1" out rc
    local -a ssh_cmd=(
      ssh
      -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=10
      -o BatchMode=yes
    )
    if [ -n "${SSH_KEY_PATH:-}" ]; then
      ssh_cmd+=(-i "$SSH_KEY_PATH")
    fi
    out=$(
      "${ssh_cmd[@]}" "${SSH_USER}@${ip}" \
        "avail_kb=\$(df -Pk /var/lib/k0s 2>/dev/null | awk 'NR==2 {print \$4}')
         [ -z \"\$avail_kb\" ] && avail_kb=\$(df -Pk / 2>/dev/null | awk 'NR==2 {print \$4}')
         echo \"\${avail_kb:-0}\"" 2>/dev/null
    )
    rc=$?
    if [ $rc -ne 0 ]; then
      # SSH itself failed (wrong user, host unreachable, key rejected, etc.).
      # Return a sentinel value the caller can recognise — preserve old "0"
      # behaviour for back-compat but stamp the SSH error so pf_fail messages
      # are actionable.
      echo "SSH_ERROR_RC=${rc}" >&2
      echo "0"
      return
    fi
    out=$(echo "${out}" | tr -d '[:space:]')
    # KB → GB (integer truncation; close enough for a preflight threshold)
    echo "$(( ${out:-0} / 1048576 ))"
  }

  # Helper that runs _get_avail_gb and turns its sentinel stderr (SSH_ERROR_RC=...)
  # into a human-readable failure message. SSH errors look very different from
  # genuine disk-pressure problems and should not be reported as "0 GB available".
  _check_node_disk() {
    local ip="$1" role="$2" min_required="$3"
    local stdout stderr_file stderr avail ssh_err
    # Capture stdout and stderr separately via a temp file (avoids the fd-3
    # redirection trick that leaked stdout "0" lines to the terminal).
    stderr_file=$(mktemp)
    stdout=$(_get_avail_gb "${ip}" 2>"${stderr_file}")
    stderr=$(cat "${stderr_file}"); rm -f "${stderr_file}"

    if printf '%s' "${stderr}" | grep -q 'SSH_ERROR_RC='; then
      ssh_err=$(printf '%s' "${stderr}" | sed -n 's/.*SSH_ERROR_RC=\([0-9]*\).*/\1/p')
      local hint
      case "${ssh_err}" in
        255)
          # Most common rc=255 cause on a fresh Mac+EC2 setup is a too-permissive
          # key file; SSH then silently refuses to use it. Probe perms first so
          # users don't waste time on SG/user rotations.
          if [[ -f "${SSH_KEY_PATH}" ]]; then
            local perms
            perms=$(stat -f '%Lp' "${SSH_KEY_PATH}" 2>/dev/null || stat -c '%a' "${SSH_KEY_PATH}" 2>/dev/null)
            if [[ "${perms}" != "400" && "${perms}" != "600" ]]; then
              hint=" — SSH key ${SSH_KEY_PATH} has permissions ${perms} (must be 400 or 600). Run: chmod 400 ${SSH_KEY_PATH}"
            fi
          fi
          ;;
      esac
      pf_fail "${role} ${ip}: SSH failed (rc=${ssh_err:-?})${hint:-}. Verify cluster.sshUser='${SSH_USER}' matches the AMI default (ec2-user/ubuntu/rocky/admin), the security group allows port 22 from your IP, and the SSH key at ${SSH_KEY_PATH:-default} is authorised on the node."
      return
    fi

    avail=$(printf '%s' "${stdout}" | tr -d '[:space:]')
    if [[ "${avail:-0}" -ge "${min_required}" ]]; then
      pf_ok "${role} ${ip}: ${avail} GB available (minimum: ${min_required} GB)"
    else
      pf_fail "${role} ${ip}: ${avail:-0} GB available — need at least ${min_required} GB on /var/lib/k0s"
    fi
  }

  # Check controller nodes
  for ip in "${_ctrl_ips[@]}"; do
    _check_node_disk "${ip}" "Controller" "${MIN_DISK_CONTROLLER}"
  done

  # Check worker nodes (distinguish CPU vs GPU by index)
  local widx=0
  for ip in "${_worker_ips[@]}"; do
    local role min_required
    if [[ ${widx} -lt ${CPU_WORKER_COUNT} ]]; then
      role="CPU worker"
      min_required="${MIN_DISK_CPU_WORKER}"
    else
      role="GPU worker"
      min_required="${MIN_DISK_GPU_WORKER}"
    fi
    _check_node_disk "${ip}" "${role}" "${min_required}"
    widx=$((widx + 1))
  done
}

# ====== INSECURE REGISTRY CONFIGURATION ======
# Configures the IMAGE_REGISTRY (read from config) as an insecure (plain-HTTP)
# registry on a node. Must be called AFTER k0s start so containerd has written
# /etc/k0s/containerd.toml and the v1/v2 detection is reliable.
#
# containerd v2 (k0s >= 1.33, containerd >= 2.x) uses per-registry hosts.toml
# under /etc/k0s/containerd/certs.d/<registry>/. The legacy v1 drop-in TOML
# (io.containerd.grpc.v1.cri) is silently ignored by containerd 2.x.
#
# Detection: check the containerd binary version directly — more reliable than
# inspecting the toml file, which may not exist at call time on first install.
configure_insecure_registry_on_node() {
  local node_ip="$1"
  local registry="${IMAGE_REGISTRY:-}"

  # Only configure plain-HTTP (insecure) access when explicitly opted in.
  # TLS registries (ECR, Docker Hub, Harbor) must not be redirected to HTTP.
  [[ -z "${registry}" ]] && return 0
  [[ "${IMAGE_REGISTRY_INSECURE:-false}" != "true" ]] && return 0

  log "  Configuring insecure registry ${registry} on ${node_ip}..."
  ssh_exec "${node_ip}" "
    # k0s writes /etc/k0s/containerd.toml asynchronously after start; wait for
    # it rather than defaulting to v1 on a failed probe (which would recreate
    # the crash loop this function is meant to prevent).
    toml_wait=0
    until sudo test -f /etc/k0s/containerd.toml 2>/dev/null; do
      if (( toml_wait >= 60 )); then
        echo 'ERROR: /etc/k0s/containerd.toml not written after 60s — aborting registry config' >&2
        exit 1
      fi
      sleep 2
      toml_wait=\$((toml_wait + 2))
    done

    # Detect containerd version by inspecting the managed containerd.toml that k0s
    # writes on startup. containerd v2 uses the io.containerd.cri.v1 plugin key;
    # v1 uses io.containerd.grpc.v1.cri. Grepping the toml is more reliable than
    # parsing the binary version and avoids a wrong fallback if the binary path changes.
    if sudo grep -q 'io\\.containerd\\.cri\\.v1' /etc/k0s/containerd.toml 2>/dev/null; then
      containerd_major=2
    else
      containerd_major=1
    fi
    echo \"--- containerd major version: \${containerd_major} ---\"

    if [[ \"\${containerd_major}\" -ge 2 ]]; then
      echo '--- containerd v2: writing config_path drop-in + hosts.toml ---'
      # Remove stale v1 drop-in — containerd 2.x rejects the grpc.v1.cri plugin key
      # at preflight, crashing k0sworker if this file is left over from a prior run.
      sudo rm -f /etc/k0s/containerd.d/insecure-registry.toml
      # Drop-in that sets config_path so containerd reads the certs.d directory.
      # Without this, the per-registry hosts.toml is silently ignored by containerd 2.x.
      sudo mkdir -p /etc/k0s/containerd.d
      printf '[plugins.\"io.containerd.cri.v1.images\".registry]\n  config_path = \"/etc/k0s/containerd/certs.d\"\n' \
        | sudo tee /etc/k0s/containerd.d/registry-config-path.toml >/dev/null
      # Per-registry hosts.toml for plain-HTTP access
      sudo mkdir -p \"/etc/k0s/containerd/certs.d/${registry}\"
      printf 'server = \"http://${registry}\"\n\n[host.\"http://${registry}\"]\n  capabilities = [\"pull\", \"resolve\", \"push\"]\n  skip_verify = true\n' \
        | sudo tee \"/etc/k0s/containerd/certs.d/${registry}/hosts.toml\" >/dev/null
    else
      echo '--- containerd v1: writing drop-in TOML ---'
      sudo mkdir -p /etc/k0s/containerd.d
      printf '[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors]\n    [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"${registry}\"]\n      endpoint = [\"http://${registry}\"]\n  [plugins.\"io.containerd.grpc.v1.cri\".registry.configs]\n    [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${registry}\".tls]\n      insecure_skip_verify = true\n' \
        | sudo tee /etc/k0s/containerd.d/insecure-registry.toml >/dev/null
    fi
  "
  log "  ✓ Insecure registry configured on ${node_ip}"
}

# ====== K0S CLUSTER INSTALLATION ======
install_k0s_cluster() {
  log "Installing k0s cluster..."

  # Parse existing IPs if provided
  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
    IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
    log "Using existing infrastructure - IPs from config"
  fi

  local controller_ip="${CONTROLLER_IPS[0]}"

  log "Primary controller IP: ${controller_ip}"

  # Prepare all nodes (firewalld, iptables, python3)
  local all_ips=("${CONTROLLER_IPS[@]}")
  if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
    all_ips+=("${WORKER_IPS[@]}")
  fi
  prepare_nodes_for_k0s "${all_ips[@]}"

  # Ensure k0s is in sudo's secure_path (some distros exclude /usr/local/bin)
  ssh_exec "${controller_ip}" "if [ -f /usr/local/bin/k0s ] && [ ! -f /usr/bin/k0s ]; then sudo ln -sf /usr/local/bin/k0s /usr/bin/k0s; fi" || true

  # Safety gate: refuse to wipe if a live cluster with Ready nodes exists.
  # This prevents accidental data loss when the existing-cluster detection
  # (useExisting) flakes due to an SSH timeout or transient k0s status error.
  if ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes --no-headers 2>/dev/null" 2>/dev/null | grep -q ' Ready'; then
    err "k0s cluster on ${controller_ip} has Ready nodes — refusing to wipe.
    Use 'delete' or 'clean-all' to tear down first, or set useExisting=auto in config."
  fi

  # Clean stale k0s state from any previous run.
  # Must run BEFORE config generation: rm -rf /etc/k0s would otherwise delete
  # the /etc/k0s/k0s.yaml we are about to write, causing k0s install to fail.
  ssh_exec "${controller_ip}" "
    sudo systemctl stop k0scontroller 2>/dev/null || true
    sudo systemctl reset-failed k0scontroller 2>/dev/null || true
    sudo rm -f /etc/systemd/system/k0scontroller.service 2>/dev/null || true
    sudo systemctl stop k0sworker 2>/dev/null || true
    sudo systemctl reset-failed k0sworker 2>/dev/null || true
    sudo rm -f /etc/systemd/system/k0sworker.service 2>/dev/null || true
    sudo pkill -9 containerd-shim 2>/dev/null || true
    sudo rm -rf /var/lib/k0s /run/k0s /etc/k0s 2>/dev/null || true
    sudo rm -f /run/k0s/containerd.sock 2>/dev/null || true
    sudo systemctl daemon-reload
  " 2>/dev/null || true

  # Generate k0s config into a persistent location so it survives reboots.
  # /tmp is cleared on reboot which caused k0s to fall back to defaults
  # (including --compact-interval=0) after a node restart.
  log "Generating k0s configuration..."
  ssh_exec "${controller_ip}" "sudo mkdir -p /etc/k0s && k0s config create | sudo tee /etc/k0s/k0s.yaml >/dev/null"

  # Configure k0s API with the controller IP for SANs and externalAddress
  log "Configuring k0s with controller IP ${controller_ip}..."
  ssh_exec "${controller_ip}" "cat > /tmp/k0s-config-update.py <<'PYSCRIPT'
import yaml

# Read the k0s config
with open('/etc/k0s/k0s.yaml', 'r') as f:
    config = yaml.safe_load(f)

# Add the controller IP to SANs (for kubectl access and cluster communication)
if 'spec' not in config:
    config['spec'] = {}
if 'api' not in config['spec']:
    config['spec']['api'] = {}
if 'sans' not in config['spec']['api']:
    config['spec']['api']['sans'] = []

config['spec']['api']['sans'].append('${controller_ip}')

# Use the same IP for externalAddress so konnectivity-agents can connect
config['spec']['api']['externalAddress'] = '${controller_ip}'

# Set Calico as network provider
if 'network' not in config['spec']:
    config['spec']['network'] = {}
config['spec']['network']['provider'] = 'calico'
if 'calico' not in config['spec']['network']:
    config['spec']['network']['calico'] = {}
config['spec']['network']['calico']['mode'] = 'vxlan'

# Set kine for storage with compaction enabled to prevent unbounded DB growth.
# k0s KineConfig exposes extraArgs (map) and rawArgs (slice) — there is no
# compactInterval field; the flag must be passed via extraArgs.
if 'storage' not in config['spec']:
    config['spec']['storage'] = {}
config['spec']['storage']['type'] = 'kine'
if 'kine' not in config['spec']['storage']:
    config['spec']['storage']['kine'] = {}
if 'extraArgs' not in config['spec']['storage']['kine']:
    config['spec']['storage']['kine']['extraArgs'] = {}
config['spec']['storage']['kine']['extraArgs']['compact-interval'] = '5m'

# Write back
with open('/etc/k0s/k0s.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)
PYSCRIPT"

  ssh_exec "${controller_ip}" "sudo python3 /tmp/k0s-config-update.py"

  log "Verifying k0s configuration includes controller IP..."
  ssh_exec "${controller_ip}" "sudo grep -A3 'api:' /etc/k0s/k0s.yaml | head -5"

  # Install k0s controller
  log "Installing k0s controller on ${controller_ip}..."
  ssh_exec "${controller_ip}" "sudo k0s install controller --config /etc/k0s/k0s.yaml --enable-worker"
  # Air-gap: stage k0s system images AFTER install (recreates /var/lib/k0s) and
  # BEFORE start (k0s imports /var/lib/k0s/images/ only at kubelet startup).
  stage_k0s_image_bundle "${controller_ip}"
  # Remove stale v1 drop-in before start — containerd 2.x rejects the grpc.v1.cri
  # plugin key at preflight, crashing k0s before configure_insecure_registry_on_node
  # can execute its own cleanup.
  ssh_exec "${controller_ip}" "sudo rm -f /etc/k0s/containerd.d/insecure-registry.toml" || true
  ssh_exec "${controller_ip}" "sudo k0s start"

  log "Waiting for controller API server to be ready..."
  local ctrl_retries=0
  while (( ctrl_retries < 60 )); do
    if ssh_exec "${controller_ip}" "sudo k0s kubectl get --raw /healthz 2>/dev/null" &>/dev/null; then
      log "  ✓ Controller API server is ready (${ctrl_retries}s)"
      break
    fi
    sleep 5
    ctrl_retries=$((ctrl_retries + 5))
    log "  Waiting... ${ctrl_retries}/300s"
  done

  # Configure insecure registry after k0s start so that containerd has written
  # /etc/k0s/containerd.toml — required for correct containerd v1/v2 detection.
  configure_insecure_registry_on_node "${controller_ip}"

  # Generate worker token
  log "Generating worker join token..."
  local worker_token
  worker_token=$(ssh_exec "${controller_ip}" "sudo k0s token create --role=worker")

  # Install workers (with error checking)
  log "Installing k0s on ${#WORKER_IPS[@]} worker nodes..."
  local failed_workers=()

  for worker_ip in "${WORKER_IPS[@]}"; do
    log "  Installing k0s worker on ${worker_ip}..."
    # Ensure k0s is in sudo's secure_path (some distros exclude /usr/local/bin)
    ssh_exec "${worker_ip}" "if [ -f /usr/local/bin/k0s ] && [ ! -f /usr/bin/k0s ]; then sudo ln -sf /usr/local/bin/k0s /usr/bin/k0s; fi" || true

    # Clean stale k0sworker state from any previous run (service file, data dirs, systemd failed state)
    ssh_exec "${worker_ip}" "
      sudo systemctl stop k0sworker 2>/dev/null || true
      sudo systemctl reset-failed k0sworker 2>/dev/null || true
      sudo rm -f /etc/systemd/system/k0sworker.service 2>/dev/null || true
      sudo rm -rf /var/lib/k0s /run/k0s /etc/k0s /tmp/k0s-token 2>/dev/null || true
      sudo systemctl daemon-reload
    " 2>/dev/null || true

    # Write token to temp file first (stdin pipe doesn't work reliably over SSH)
    if ssh_exec "${worker_ip}" "echo '${worker_token}' | sudo tee /tmp/k0s-token >/dev/null && sudo k0s install worker --token-file=/tmp/k0s-token"; then
      log "  ✓ k0s installed on ${worker_ip}"
      # Air-gap: stage k0s system images now — after install (recreated
      # /var/lib/k0s), before this worker is started in the loop below.
      stage_k0s_image_bundle "${worker_ip}"
    else
      warn "  ✗ Failed to install k0s on ${worker_ip}"
      failed_workers+=("${worker_ip}")
    fi
  done

  # Start workers
  log "Starting k0s workers..."
  for worker_ip in "${WORKER_IPS[@]}"; do
    # Skip workers that failed installation
    local skip=false
    if [[ ${#failed_workers[@]} -gt 0 ]]; then
      for failed_ip in "${failed_workers[@]}"; do
        if [[ "${failed_ip}" == "${worker_ip}" ]]; then
          skip=true
          break
        fi
      done
    fi
    if [[ "${skip}" == "true" ]]; then
      continue
    fi

    log "  Starting k0s worker on ${worker_ip}..."
    # Remove stale v1 drop-in before start — containerd 2.x rejects the grpc.v1.cri
    # plugin key at preflight, crashing k0sworker before configure_insecure_registry_on_node
    # can execute its own cleanup.
    ssh_exec "${worker_ip}" "sudo rm -f /etc/k0s/containerd.d/insecure-registry.toml" || true
    if ssh_exec "${worker_ip}" "sudo k0s start"; then
      log "  ✓ k0s started on ${worker_ip}"
      # Configure insecure registry after k0s start so containerd is running
      # and the v1/v2 detection against the containerd binary is reliable.
      configure_insecure_registry_on_node "${worker_ip}"
    else
      warn "  ✗ Failed to start k0s on ${worker_ip}"
      failed_workers+=("${worker_ip}")
    fi
  done

  if [[ ${#failed_workers[@]} -gt 0 ]]; then
    warn "Some workers failed to install/start: ${failed_workers[*]}"
  fi

  log "Waiting for workers to join the cluster..."
  local expected_join=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))
  local join_retries=0
  while (( join_retries < 120 )); do
    local current_nodes
    current_nodes=$(ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    current_nodes=$(echo "${current_nodes}" | tr -d '[:space:]')
    if [[ "${current_nodes}" -ge "${expected_join}" ]]; then
      log "  ✓ All ${current_nodes} node(s) joined (${join_retries}s)"
      break
    fi
    sleep 10
    join_retries=$((join_retries + 10))
    log "  Waiting... ${current_nodes}/${expected_join} nodes joined (${join_retries}/120s)"
  done

  # Verify workers actually joined
  log "Verifying worker nodes joined the cluster..."
  local expected_nodes=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))
  local actual_nodes
  actual_nodes=$(ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes --no-headers | wc -l")

  log "Expected nodes: ${expected_nodes}, Actual nodes: ${actual_nodes}"

  if [[ ${actual_nodes} -lt ${expected_nodes} ]]; then
    warn "Not all workers joined! Expected ${expected_nodes} nodes, but only ${actual_nodes} joined."
    log "Current nodes:"
    ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes -o wide"

    log ""
    warn "Possible issues:"
    warn "  1. Workers cannot reach controller's API server"
    warn "  2. Network connectivity issues between nodes"
    warn "  3. k0s worker process failed to start"
    warn ""
    warn "Checking worker logs..."

    # Check first worker's k0s logs
    if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
      local first_worker="${WORKER_IPS[0]}"
      log "Checking k0s status on worker ${first_worker}..."
      ssh_exec "${first_worker}" "sudo k0s status || sudo journalctl -u k0sworker -n 20 --no-pager" || true
    fi

    warn ""
    warn "Continuing installation with ${actual_nodes} nodes..."
    warn "You can manually join workers later using: ./k0s_cluster_with_stack.sh join-workers"
    warn ""
  else
    log "✓ All ${expected_nodes} nodes joined successfully!"
  fi

  # Install local-path storage provisioner for persistent volumes.
  # NOTE: kubectl runs on the CONTROLLER here (M2's local kubeconfig is not
  # retrieved until a few lines below). kubectl's `apply -f` does not understand
  # the file:// scheme, and an air-gap bundle path is local to M2 (the installer
  # host), not the controller. So in air-gap mode we stream the manifest's bytes
  # from M2 into the controller's kubectl over ssh stdin (`apply -f -`).
  log "Installing local-path storage provisioner..."
  local _lp_url="${LOCAL_PATH_MANIFEST_URL:-https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml}"
  if [[ "${_lp_url}" == file://* ]]; then
    ssh_exec "${controller_ip}" "sudo k0s kubectl apply -f -" < "${_lp_url#file://}"
  else
    ssh_exec "${controller_ip}" "sudo k0s kubectl apply -f '${_lp_url}'"
  fi

  log "Waiting for storage provisioner to be ready..."
  sleep 10

  # Set local-path as default storage class
  log "Setting local-path as default storage class..."
  ssh_exec "${controller_ip}" "sudo k0s kubectl patch storageclass local-path -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"

  log "Storage provisioner installed successfully"

  # Remove control-plane taint from controller node if --enable-worker was used
  # This allows pods to be scheduled on the controller node
  log "Removing control-plane taint from controller node (controller has --enable-worker)..."
  ssh_exec "${controller_ip}" "sudo k0s kubectl get nodes -o name | xargs -I {} sudo k0s kubectl taint node {} node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true"
  log "Controller node can now schedule workload pods"

  # Get kubeconfig
  log "Retrieving kubeconfig..."
  mkdir -p "${HOME}/.kube"
  ssh_exec "${controller_ip}" "sudo cat /var/lib/k0s/pki/admin.conf" > "${HOME}/.kube/k0s-${CLUSTER_NAME}"

  # Update server address to use the controller IP for kubectl access from local machine
  log "Configuring kubeconfig to use controller IP for external access..."
  sed -i.bak "s|server: .*|server: https://${controller_ip}:6443|" "${HOME}/.kube/k0s-${CLUSTER_NAME}"

  export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"

  log "k0s cluster installed successfully!"
  kubectl get nodes

  # Label nodes for proper workload scheduling
  label_nodes
}

# ====== RESOLVE NODE NAME ======
# Maps a config IP to its Kubernetes node name by SSHing to the node
# and reading its hostname (which is what k0s uses as the node name).
# Usage: node_name=$(resolve_node_name "1.2.3.4")
resolve_node_name() {
  local ip="$1"
  # SSH to the node and get the hostname that k0s registered it with
  local node_name
  node_name=$(ssh_exec "${ip}" "hostname -f 2>/dev/null || hostname" 2>/dev/null || echo "")
  echo "${node_name}"
}

# ====== LABEL NODES FOR WORKLOAD SCHEDULING ======
label_nodes() {
  log "Labeling nodes for AI workload scheduling..."

  # Wait for all nodes to be ready.
  #
  # NOTE: we count nodes whose "Ready" condition is exactly "True" via a
  # structured JSON query — NOT by grepping for the string "Ready" in the
  # plain-text `kubectl get nodes` output. That string match is a trap
  # because the STATUS column of a not-yet-ready node prints the substring
  # "NotReady" which ALSO matches a naive `grep -c Ready`, causing the loop
  # to exit prematurely. Downstream labeling then silently skips any worker
  # that joined the API server late with "Node not found in cluster".
  local node_count=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))
  log "Waiting for ${node_count} node(s) to be Ready..."

  local timeout=300
  local elapsed=0
  local ready_count
  while :; do
    ready_count=$(kubectl get nodes -o json 2>/dev/null \
      | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null \
      || echo 0)
    if [[ "${ready_count}" -ge "${node_count}" ]]; then
      log "  ✓ All ${ready_count}/${node_count} nodes Ready"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      warn "Timeout (${timeout}s) waiting for all nodes to be Ready (have ${ready_count}/${node_count}); proceeding anyway..."
      break
    fi
    if (( elapsed % 30 == 0 )); then
      log "  ${ready_count}/${node_count} nodes Ready (${elapsed}/${timeout}s)"
    fi
  done

  # Helper: wait up to 60s for a given node name to appear in the API server.
  # This guards against the race where a worker joined the cluster just after
  # the top-of-function readiness check returned but its Node object is still
  # propagating to the API server we're talking to.
  _wait_for_node_visible() {
    local node_name="$1"
    local ip="$2"
    local tries=0
    local max_tries=12  # 12 * 5s = 60s
    while (( tries < max_tries )); do
      if kubectl get node "${node_name}" &>/dev/null; then
        return 0
      fi
      sleep 5
      tries=$((tries + 1))
    done
    warn "  Node '${node_name}' (from ${ip}) did not become visible in API server after 60s"
    return 1
  }

  # Track labeling outcomes so we can fail loud if any node ends up unlabeled.
  local labeling_failures=()

  # Label controller nodes
  for controller_ip in "${CONTROLLER_IPS[@]}"; do
    local node_name
    node_name=$(resolve_node_name "${controller_ip}")

    if [[ -z "${node_name}" ]]; then
      warn "  Could not resolve hostname for controller ${controller_ip}, skipping..."
      labeling_failures+=("${controller_ip} (hostname unresolved)")
      continue
    fi

    if ! _wait_for_node_visible "${node_name}" "${controller_ip}"; then
      labeling_failures+=("${controller_ip} / ${node_name} (never visible)")
      continue
    fi

    log "Labeling controller node: ${node_name} (${controller_ip})"
    kubectl label nodes "${node_name}" \
      splunk.ai/node-role=controller \
      splunk.ai/workload-type=control-plane \
      node.kubernetes.io/role=controller \
      --overwrite

    # For single-node clusters (controller with --enable-worker), also add CPU workload labels
    if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
      log "  → Single-node cluster detected, adding CPU workload labels to controller..."
      kubectl label nodes "${node_name}" \
        splunk.ai/workload-type=cpu \
        node.kubernetes.io/workload=ai-cpu \
        splunk.ai/instance-type=cpu-worker \
        --overwrite
      log "  ✓ CPU workload labels added to controller node"
    fi
  done

  # Label worker nodes based on their configuration
  local worker_index=0
  for worker_ip in "${WORKER_IPS[@]}"; do
    local node_name
    node_name=$(resolve_node_name "${worker_ip}")

    if [[ -z "${node_name}" ]]; then
      warn "  Could not resolve hostname for worker ${worker_ip}, skipping..."
      labeling_failures+=("${worker_ip} (hostname unresolved)")
      worker_index=$((worker_index + 1))
      continue
    fi

    if ! _wait_for_node_visible "${node_name}" "${worker_ip}"; then
      labeling_failures+=("${worker_ip} / ${node_name} (never visible)")
      worker_index=$((worker_index + 1))
      continue
    fi

    # Determine if this is a GPU or CPU worker based on index
    # First CPU_WORKER_COUNT workers are CPU, rest are GPU
    if [[ ${worker_index} -lt ${CPU_WORKER_COUNT} ]]; then
      log "Labeling CPU worker node: ${node_name} (${worker_ip})"
      kubectl label nodes "${node_name}" \
        splunk.ai/node-role=worker \
        splunk.ai/workload-type=cpu \
        node.kubernetes.io/workload=ai-cpu \
        splunk.ai/instance-type=cpu-worker \
        --overwrite
    else
      log "Labeling GPU worker node: ${node_name} (${worker_ip})"
      kubectl label nodes "${node_name}" \
        splunk.ai/node-role=worker \
        splunk.ai/workload-type=gpu \
        node.kubernetes.io/workload=ai-gpu \
        splunk.ai/instance-type=gpu-worker \
        nvidia.com/gpu=true \
        --overwrite
    fi
    worker_index=$((worker_index + 1))
  done

  # Add taints to GPU nodes to prevent non-GPU workloads from scheduling there
  log "Adding taints to GPU nodes..."
  kubectl get nodes -l splunk.ai/workload-type=gpu -o name | while read -r node; do
    kubectl taint nodes "${node#node/}" nvidia.com/gpu=true:NoSchedule --overwrite || true
  done

  # --- Final verification: every node must have splunk.ai/workload-type set ---
  # Without this, downstream scheduling silently breaks: weaviate / ray-head /
  # many operator-created workloads use nodeSelector: splunk.ai/workload-type=cpu
  # and will sit in Pending forever on a node that only has default labels.
  log "Verifying every node has splunk.ai/workload-type set..."
  local unlabeled
  unlabeled=$(kubectl get nodes -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.labels["splunk.ai/workload-type"] == null) | .metadata.name' 2>/dev/null \
    || echo "")
  if [[ -n "${unlabeled}" ]]; then
    # Last-chance recovery: re-iterate config IPs and label whichever matches.
    # This catches the case where resolve_node_name raced earlier in the run.
    warn "Found unlabeled node(s), attempting recovery:"
    echo "${unlabeled}" | while IFS= read -r nn; do
      warn "  - ${nn}"
    done
    for ip in "${CONTROLLER_IPS[@]}" "${WORKER_IPS[@]}"; do
      local nn
      nn=$(resolve_node_name "${ip}")
      [[ -z "${nn}" ]] && continue
      if echo "${unlabeled}" | grep -qx "${nn}"; then
        # Best-effort: apply CPU labels to the controller, CPU labels to
        # any worker whose index is < CPU_WORKER_COUNT, else GPU labels.
        # This duplicates a small amount of logic but keeps the recovery
        # path fully self-contained.
        local is_controller=false
        for cip in "${CONTROLLER_IPS[@]}"; do
          [[ "${cip}" == "${ip}" ]] && is_controller=true && break
        done
        if ${is_controller}; then
          log "  Recovery: labeling controller ${nn} (${ip})"
          kubectl label nodes "${nn}" \
            splunk.ai/node-role=controller \
            splunk.ai/workload-type=control-plane \
            node.kubernetes.io/role=controller \
            --overwrite || true
        else
          local wi=0
          for wip in "${WORKER_IPS[@]}"; do
            [[ "${wip}" == "${ip}" ]] && break
            wi=$((wi + 1))
          done
          if [[ ${wi} -lt ${CPU_WORKER_COUNT} ]]; then
            log "  Recovery: labeling CPU worker ${nn} (${ip})"
            kubectl label nodes "${nn}" \
              splunk.ai/node-role=worker \
              splunk.ai/workload-type=cpu \
              node.kubernetes.io/workload=ai-cpu \
              splunk.ai/instance-type=cpu-worker \
              --overwrite || true
          else
            log "  Recovery: labeling GPU worker ${nn} (${ip})"
            kubectl label nodes "${nn}" \
              splunk.ai/node-role=worker \
              splunk.ai/workload-type=gpu \
              node.kubernetes.io/workload=ai-gpu \
              splunk.ai/instance-type=gpu-worker \
              nvidia.com/gpu=true \
              --overwrite || true
          fi
        fi
      fi
    done

    # Re-check after recovery attempt.
    unlabeled=$(kubectl get nodes -o json 2>/dev/null \
      | jq -r '.items[] | select(.metadata.labels["splunk.ai/workload-type"] == null) | .metadata.name' 2>/dev/null \
      || echo "")
    if [[ -n "${unlabeled}" ]]; then
      err "Nodes still unlabeled after recovery pass:
$(echo "${unlabeled}" | sed 's/^/  /')

Workloads that select splunk.ai/workload-type=cpu (weaviate, ray-head,
most operator-managed pods) will stay Pending. Aborting."
    fi
    log "  ✓ Recovery successful — all nodes now have workload-type set"
  else
    log "  ✓ All nodes have splunk.ai/workload-type set"
  fi

  if [[ ${#labeling_failures[@]} -gt 0 ]]; then
    warn "label_nodes encountered ${#labeling_failures[@]} non-fatal issue(s):"
    for f in "${labeling_failures[@]}"; do warn "  - ${f}"; done
  fi

  log "Node labeling complete!"
  log "Nodes with labels:"
  kubectl get nodes --show-labels
}

# ====== WAIT FOR CRD ======
wait_for_crd() {
  local crd_name="$1"
  local timeout="${2:-300}"
  log "Waiting for CRD ${crd_name} (timeout: ${timeout}s)..."

  local elapsed=0
  while ! kubectl get crd "${crd_name}" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      err "Timeout waiting for CRD ${crd_name}"
    fi
  done
  log "CRD ${crd_name} is ready"
}

# ====== ENSURE NAMESPACE ======
ensure_namespace() {
  local ns="$1"
  if ! kubectl get namespace "${ns}" >/dev/null 2>&1; then
    log "Creating namespace ${ns}..."
    kubectl create namespace "${ns}"
  fi
}

# ====== S3-COMPATIBLE OBJECT STORAGE CREDENTIALS ======
# Object storage is always customer-managed (external). This function creates
# the Kubernetes credentials secret so the operator and workloads can auth.
ensure_s3compat_credentials() {
  log "Creating credentials secret for object storage (type=${OBJ_STORE_TYPE})..."
  if object_store_auth_looks_like_placeholder; then
    err "Refusing to create minio-credentials: objectStore.auth contains template placeholders; fix ${CONFIG_FILE}"
    return 1
  fi

  # Wait for the object store endpoint to be reachable before creating the
  # Kubernetes secret. In air-gapped environments the store (MinIO/SeaweedFS)
  # may still be starting up, or its VIP may not be routable yet.
  local _endpoint=""
  case "${OBJ_STORE_TYPE}" in
    minio|seaweedfs)
      _endpoint="${OBJ_STORE_ENDPOINT:-${MINIO_ENDPOINT:-}}"
      ;;
    aws)
      # For AWS S3, validate connectivity to the regional endpoint.
      _endpoint="https://s3.${REGION:-us-east-2}.amazonaws.com"
      ;;
  esac

  if [[ -n "${_endpoint}" ]]; then
    wait_for_dependency \
      "object store (${OBJ_STORE_TYPE}) at ${_endpoint}" \
      "curl -sL --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' '${_endpoint}' 2>/dev/null | grep -qE '^[0-9]'" \
      300
  fi
  # Endpoint is only required for S3-compatible backends (MinIO/SeaweedFS/
  # generic s3compat). For type=aws boto3 derives the regional URL from
  # AWS_REGION on the consuming pods, and the installer intentionally renders
  # the AIPlatform CR without an endpoint field (see setup_ai_platform case
  # "aws" — endpoint dropped to mirror the EKS installer's behaviour and to
  # match the operator's classifyObjectStorage() helper).
  case "${OBJ_STORE_TYPE}" in
    minio|seaweedfs)
      if [[ -z "${OBJ_STORE_ENDPOINT}" && -z "${MINIO_ENDPOINT}" ]]; then
        err "storage.objectStore.type=${OBJ_STORE_TYPE} requires storage.objectStore.endpoint"
        return 1
      fi
      ;;
  esac
  if [[ -z "${MINIO_ROOT_PASSWORD}" ]]; then
    err "Object storage requires credentials (objectStore.auth.rootPassword or MINIO_ROOT_PASSWORD)"
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
  log "✓ S3-compatible credentials secret ${AI_NS}/${secret_name} ready"
}

# ====== MODEL ARTIFACT STAGING ======

# all_models_staged <staging_dir> <accel>
# Checks whether every artifact in the GPU-specific model config already has a
# staging_state/<id>/.staging_complete marker in the object store AND that the
# marker's accel= field matches the requested accelerator. A marker with a
# mismatched accel (e.g. l40s marker found when h100 is requested) is treated as
# missing so the correct model weights are downloaded and uploaded.
# Returns 0 (all staged) or 1 (one or more missing / check unavailable).
# Fails open: if the store is unreachable or a required tool is missing, returns 1
# so staging proceeds normally.
all_models_staged() {
  local staging_dir="$1"
  local accel="$2"
  local config_file

  case "${accel}" in
    h100) config_file="${staging_dir}/model_artifacts_configs_h100.yaml" ;;
    *)    config_file="${staging_dir}/model_artifacts_configs.yaml" ;;
  esac

  if [[ ! -f "${config_file}" ]]; then
    warn "all_models_staged: config file not found: ${config_file} — skipping pre-check."
    return 1
  fi

  # Read artifact IDs and their HF URLs — skip decision is based on URL match,
  # not GPU type, so a model staged for any accelerator is reused as long as
  # the source URL hasn't changed.
  local ids=() hf_urls=()
  local raw_ids raw_urls
  raw_ids=$(yq eval '.artifact-configs[].artifact-id' "${config_file}" 2>/dev/null) || {
    warn "all_models_staged: could not read artifact IDs from ${config_file} — skipping pre-check."
    return 1
  }
  raw_urls=$(yq eval '.artifact-configs[].hf-url' "${config_file}" 2>/dev/null) || {
    warn "all_models_staged: could not read hf-url fields from ${config_file} — skipping pre-check."
    return 1
  }
  while IFS= read -r id; do
    [[ -n "${id}" ]] && ids+=("${id}")
  done <<< "${raw_ids}"
  while IFS= read -r url; do
    hf_urls+=("${url}")
  done <<< "${raw_urls}"

  if [[ ${#ids[@]} -eq 0 ]]; then
    warn "all_models_staged: no artifact IDs found in ${config_file} — skipping pre-check."
    return 1
  fi

  # _marker_matches_url: returns 0 if the marker's hf_url= matches the expected URL.
  _marker_matches_url() {
    local content="$1" expected_url="$2"
    echo "${content}" | grep -q "^hf_url=${expected_url}$"
  }

  local missing=()

  case "${OBJ_STORE_TYPE}" in
    aws)
      if ! command -v aws &>/dev/null; then
        warn "all_models_staged: aws CLI not found — skipping pre-check."
        return 1
      fi
      for i in "${!ids[@]}"; do
        local id="${ids[$i]}" hf_url="${hf_urls[$i]:-}"
        local marker_path="s3://${OBJ_STORE_BUCKET}/staging_state/${id}/.staging_complete"
        local content
        content=$(AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
                  AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
                  aws s3 cp "${marker_path}" - --region "${REGION:-us-east-2}" 2>/dev/null) || { missing+=("${id}"); continue; }
        _marker_matches_url "${content}" "${hf_url}" || missing+=("${id}")
      done
      ;;
    minio|seaweedfs)
      if ! command -v mc &>/dev/null; then
        warn "all_models_staged: mc not found — skipping pre-check."
        return 1
      fi
      if [[ -z "${OBJ_STORE_ENDPOINT}" ]]; then
        warn "all_models_staged: OBJ_STORE_ENDPOINT not set — skipping pre-check."
        return 1
      fi
      local _alias="installer_precheck"
      mc alias set "${_alias}" "${OBJ_STORE_ENDPOINT}" \
          "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 &>/dev/null || {
        warn "all_models_staged: could not configure mc alias — skipping pre-check."
        return 1
      }
      for i in "${!ids[@]}"; do
        local id="${ids[$i]}" hf_url="${hf_urls[$i]:-}"
        local marker_path="${_alias}/${OBJ_STORE_BUCKET}/staging_state/${id}/.staging_complete"
        local content=""
        content=$(mc cat "${marker_path}" 2>/dev/null) || content=""
        _marker_matches_url "${content}" "${hf_url}" || missing+=("${id}")
      done
      ;;
    *)
      warn "all_models_staged: unsupported store type '${OBJ_STORE_TYPE}' — skipping pre-check."
      return 1
      ;;
  esac

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "✓ All ${#ids[@]} models already staged in object store (${OBJ_STORE_TYPE}) — skipping download and upload."
    return 0
  fi

  log "Model staging needed: ${#missing[@]}/${#ids[@]} model(s) not yet staged."
  for _m in "${missing[@]}"; do
    log "  MISSING: ${_m}  (${OBJ_STORE_BUCKET}/staging_state/${_m}/.staging_complete not found or hf_url changed)"
  done
  return 1
}

# Downloads model artifacts from Hugging Face and uploads them to the configured
# object store. Runs before k0s cluster work so models are available when Ray
# workers start. Reads HF credentials from model_artifacts_configs.yaml (in the
# same directory as the upload/download scripts — no extra env vars needed for HF).
stage_model_artifacts() {
  local staging_dir
  staging_dir="$(cd "$(dirname "$0")/../artifacts_download_upload_scripts" && pwd)" \
    || { err "Cannot locate artifacts_download_upload_scripts directory (expected sibling of cluster_setup/)"; return 1; }

  log "Model staging directory: ${staging_dir}"

  if object_store_auth_looks_like_placeholder; then
    err "Refusing to stage artifacts: objectStore.auth still contains template placeholders; fix ${CONFIG_FILE}"
    return 1
  fi

  # ---- Resolve accelerator (normalize to lowercase) ----
  # DEFAULT_ACCELERATOR is guaranteed to be set by resolve_accelerator_type()
  # before main_install reaches this point.
  local _accel
  _accel=$(printf '%s' "${DEFAULT_ACCELERATOR}" | tr '[:upper:]' '[:lower:]')

  # SKIP_IF_STAGED=1 by default: pre-check the object store before downloading so
  # re-runs skip models that are already fully staged (no re-download, no re-upload).
  # Set SKIP_IF_STAGED=0 to force a full re-download/re-upload regardless of store state.
  local _skip_staged="${SKIP_IF_STAGED:-1}"

  # ---- Fast-path: skip everything if all models already staged ----
  # Guarded by _skip_staged so SKIP_IF_STAGED=0 can force a full re-stage.
  if [[ "${_skip_staged}" != "0" ]] && all_models_staged "${staging_dir}" "${_accel}"; then
    return 0
  fi

  # ---- Check HuggingFace reachability (skip in air-gap mode) ----
  if [[ "${AIRGAP_MODE:-false}" != "true" ]]; then
    wait_for_dependency \
      "HuggingFace (huggingface.co) — required for model weight download" \
      "curl -sf --connect-timeout 10 --max-time 15 https://huggingface.co >/dev/null 2>&1" \
      300
  else
    log "AIRGAP_MODE=true — skipping HuggingFace connectivity check (models must be pre-staged in object store)"
  fi

  # ---- Download from Hugging Face ----
  log "Downloading model artifacts from Hugging Face (accelerator: ${_accel}, skip-if-staged: ${_skip_staged})..."
  ( cd "${staging_dir}" && \
      ACCELERATOR="${_accel}" \
      SKIP_IF_EXISTS="${SKIP_IF_EXISTS:-0}" \
      SKIP_IF_STAGED="${_skip_staged}" \
      OBJ_STORE_TYPE="${OBJ_STORE_TYPE}" \
      OBJ_STORE_BUCKET="${OBJ_STORE_BUCKET}" \
      OBJ_STORE_ENDPOINT="${OBJ_STORE_ENDPOINT}" \
      OBJ_STORE_ACCESS_KEY="${MINIO_ROOT_USER}" \
      OBJ_STORE_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
      S3_REGION="${REGION:-us-east-2}" \
      S3_PREFIX="model_artifacts" \
      bash ./download_from_huggingface.sh ) \
    || { err "Hugging Face download failed — see output above"; return 1; }

  # ---- Upload to object store (dispatch by type) ----
  log "Uploading model artifacts to object store (type=${OBJ_STORE_TYPE})..."
  if [[ "${OBJ_STORE_TYPE}" == "minio" || "${OBJ_STORE_TYPE}" == "seaweedfs" ]]; then
    [[ -n "${OBJ_STORE_ENDPOINT}" ]] || { err "storage.objectStore.endpoint is required for ${OBJ_STORE_TYPE} model staging"; return 1; }
  fi
  case "${OBJ_STORE_TYPE}" in
    aws)
      ( cd "${staging_dir}" && \
        S3_BUCKET="${OBJ_STORE_BUCKET}" \
        S3_REGION="${REGION:-us-east-2}" \
        AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
        AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
        SKIP_IF_STAGED="${_skip_staged}" \
        bash ./upload_to_s3.sh ) \
        || { err "Upload to S3 failed"; return 1; }
      ;;
    minio)
      ( cd "${staging_dir}" && \
        OBJECT_STORE_ENDPOINT="${OBJ_STORE_ENDPOINT}" \
        OBJECT_STORE_BUCKET="${OBJ_STORE_BUCKET}" \
        OBJECT_STORE_ACCESS_KEY="${MINIO_ROOT_USER}" \
        OBJECT_STORE_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
        SKIP_IF_STAGED="${_skip_staged}" \
        bash ./upload_to_minio.sh ) \
        || { err "Upload to MinIO failed"; return 1; }
      ;;
    seaweedfs)
      ( cd "${staging_dir}" && \
        OBJECT_STORE_ENDPOINT="${OBJ_STORE_ENDPOINT}" \
        OBJECT_STORE_BUCKET="${OBJ_STORE_BUCKET}" \
        OBJECT_STORE_ACCESS_KEY="${MINIO_ROOT_USER}" \
        OBJECT_STORE_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
        SKIP_IF_STAGED="${_skip_staged}" \
        bash ./upload_to_seaweedfs_upload_only.sh ) \
        || { err "Upload to SeaweedFS failed"; return 1; }
      ;;
    *)
      err "Unsupported objectStore.type for model staging: '${OBJ_STORE_TYPE}' (expected: aws | minio | seaweedfs)"
      return 1
      ;;
  esac

  # ---- Verify all models are now staged (fail early with clear list if any missing) ----
  # Validates marker hf_url= field: if the URL changed, the staged artifact is stale.
  log "Verifying all models are present in object store after staging..."
  local _missing_ids=()
  local _verify_alias="installer_verify"
  local _verify_ok=1
  local _config_for_verify
  _config_for_verify="${staging_dir}/$( [[ "${_accel}" == "h100" ]] && echo model_artifacts_configs_h100.yaml || echo model_artifacts_configs.yaml)"

  case "${OBJ_STORE_TYPE}" in
    aws)
      if command -v aws &>/dev/null; then
        while IFS= read -r _entry; do
          [[ -z "${_entry}" ]] && continue
          local _id="${_entry%%|*}" _hf_url="${_entry##*|}"
          local _marker_path="s3://${OBJ_STORE_BUCKET}/staging_state/${_id}/.staging_complete"
          local _content
          _content=$(AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
                     AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
                     aws s3 cp "${_marker_path}" - --region "${REGION:-us-east-2}" 2>/dev/null) || { _missing_ids+=("${_id}"); continue; }
          echo "${_content}" | grep -q "^hf_url=${_hf_url}$" || _missing_ids+=("${_id}")
        done < <(yq eval '.artifact-configs[] | .artifact-id + "|" + .hf-url' "${_config_for_verify}" 2>/dev/null)
      else
        warn "aws CLI not available — skipping post-stage verification."
        _verify_ok=0
      fi
      ;;
    minio|seaweedfs)
      if command -v mc &>/dev/null && [[ -n "${OBJ_STORE_ENDPOINT}" ]]; then
        mc alias set "${_verify_alias}" "${OBJ_STORE_ENDPOINT}" \
            "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api S3v4 &>/dev/null
        while IFS= read -r _entry; do
          [[ -z "${_entry}" ]] && continue
          local _id="${_entry%%|*}" _hf_url="${_entry##*|}"
          local _marker_path="${_verify_alias}/${OBJ_STORE_BUCKET}/staging_state/${_id}/.staging_complete"
          local _content
          _content=$(mc cat "${_marker_path}" 2>/dev/null) || { _missing_ids+=("${_id}"); continue; }
          echo "${_content}" | grep -q "^hf_url=${_hf_url}$" || _missing_ids+=("${_id}")
        done < <(yq eval '.artifact-configs[] | .artifact-id + "|" + .hf-url' "${_config_for_verify}" 2>/dev/null)
      else
        warn "mc / OBJ_STORE_ENDPOINT not available — skipping post-stage verification."
        _verify_ok=0
      fi
      ;;
  esac

  if [[ "${_verify_ok}" == "1" && ${#_missing_ids[@]} -gt 0 ]]; then
    err "Model staging incomplete — the following model(s) are missing or have a changed hf_url:"
    for _id in "${_missing_ids[@]}"; do
      err "  ✗ ${_id}  (expected: ${OBJ_STORE_BUCKET}/staging_state/${_id}/.staging_complete with matching hf_url)"
    done
    err "Re-run '$0 stage-artifacts' to retry the missing models, then run '$0 install' again."
    return 1
  fi

  log "✓ Model artifact staging complete (type=${OBJ_STORE_TYPE}, bucket=${OBJ_STORE_BUCKET})"
}

# ====== INSTALL CERT-MANAGER ======
install_cert_manager() {
  log "Installing cert-manager..."

  # kubectl runs locally on this (installer) host here, with KUBECONFIG already
  # set. `apply -f` accepts a local path or an http(s) URL but NOT the file://
  # scheme, so strip it to a bare path for air-gap bundle manifests.
  local _cm_url="${CERT_MANAGER_MANIFEST_URL:-https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml}"
  [[ "${_cm_url}" == file://* ]] && _cm_url="${_cm_url#file://}"
  kubectl apply -f "${_cm_url}"

  wait_for_crd certificates.cert-manager.io 300
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s

  # Wait for webhook to be fully operational
  log "Waiting for cert-manager webhooks to be ready..."

  # First, ensure webhook pods are running
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=webhook -n cert-manager --timeout=120s || warn "Webhook pods may not be ready"

  # Wait for webhook endpoint to have addresses
  local retries=0
  local max_retries=60
  while (( retries < max_retries )); do
    local webhook_ip
    webhook_ip=$(kubectl -n cert-manager get endpoints cert-manager-webhook -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    if [[ -n "${webhook_ip}" ]]; then
      log "cert-manager webhook endpoint found: ${webhook_ip}"
      break
    fi
    sleep 2
    retries=$((retries + 1))
  done

  if (( retries >= max_retries )); then
    warn "cert-manager webhook endpoint not found after ${max_retries} retries"
  fi

  # Brief pause for webhook registration with API server
  log "Waiting for webhooks to stabilize (10s)..."
  sleep 10

  # Test webhook by creating a test Certificate resource
  log "Testing cert-manager webhook functionality..."
  cat <<EOF | kubectl apply -f - || warn "Webhook test failed, but continuing..."
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: test-selfsigned
  namespace: cert-manager
spec:
  selfSigned: {}
EOF

  # Clean up test issuer
  kubectl delete issuer test-selfsigned -n cert-manager --ignore-not-found=true 2>/dev/null || true

  log "cert-manager installed successfully"
}

# ====== INSTALL NVIDIA DRIVERS ON GPU NODES (bare-metal / EC2) ======
# Per-node NVIDIA driver + container toolkit install (called in parallel).
#
# Error handling philosophy:
#   - `set -euo pipefail` inside every remote block so the first real failure
#     aborts the node install immediately.
#   - NO blanket `|| true` / `2>/dev/null` on installer commands — failures
#     are loud and caught.
#   - After install, strict verification gates hard-fail if the artifacts
#     aren't where they should be (nvidia-smi works, libnvidia-ml.so exists,
#     nvidia-ctk present, CDI spec populated).
#   - Tested on RHEL 9 only. Code paths for other OS families are kept for
#     internal testing but are not supported (blocked by _check_node_os).
#
# Returns 0 on fully-successful install, non-zero on any verification failure.
_install_nvidia_on_node() {
  local gpu_ip="$1"

  # ---- OS gate: only RHEL 9 is supported for GPU driver install -----------
  _check_node_os "${gpu_ip}" "GPU worker"

  # ---- Phase A: detect if driver is already installed ---------------------
  local driver_ver=""
  if ssh_exec "${gpu_ip}" "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=driver_version --format=csv,noheader" 2>/dev/null; then
    driver_ver=$(ssh_exec "${gpu_ip}" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1") || driver_ver=""
  fi

  if [[ -n "${driver_ver}" ]]; then
    echo "✓ NVIDIA driver already installed on ${gpu_ip} (version: ${driver_ver})"
  elif [[ "${AIRGAP_MODE:-false}" == "true" ]]; then
    # In air-gap mode the node must have NVIDIA drivers pre-installed.
    # The Phase A check above already looked for nvidia-smi; if we reach
    # here it wasn't found.  Fail clearly rather than attempting internet
    # package downloads that will time out or silently fail.
    echo "ERROR: AIRGAP_MODE=true but NVIDIA driver (nvidia-smi) not found on ${gpu_ip}." >&2
    echo "  Pre-install the NVIDIA driver on this node using a local RPM/DEB mirror" >&2
    echo "  or the bundled package directory, then re-run the installer." >&2
    echo "  See AIRGAP.md → 'GPU Node OS Packages' for step-by-step instructions." >&2
    return 1
  else
    echo "Installing NVIDIA driver on ${gpu_ip}..."

    # ---- Phase B: install driver + supporting packages --------------------
    # `set -euo pipefail` means ANY failure aborts the block. Each step below
    # must either succeed or have an explicit fallback branch that succeeds.
    # Capture exit code explicitly — `if ! ssh_exec ...; then` loses it because
    # bash sets $? to 0 after the ! negation regardless of the real exit code.
    local _nvidia_rc=0
    ssh_exec "${gpu_ip}" "
      set -euo pipefail

      # --- OS detection (RHEL 9 is the only supported path) ---
      # Code paths for other OS families are kept for internal testing.
      # _check_node_os() already gated unsupported OS before this block runs.
      # OS_VERSION holds the numeric major used to build CUDA/EPEL URLs.
      echo '--- OS detection ---'
      OS_FAMILY=
      OS_VERSION=
      if grep -qiE '^ID=\"?amzn\"?' /etc/os-release 2>/dev/null; then
        OS_FAMILY=amzn
        OS_VERSION=\$(. /etc/os-release; echo \"\${VERSION_ID%%.*}\")
      elif [ -f /etc/redhat-release ]; then
        OS_FAMILY=rhel
        OS_VERSION=\$(rpm -E %{rhel})
      elif [ -f /etc/debian_version ]; then
        OS_FAMILY=debian
      fi
      if [ -z \"\${OS_FAMILY}\" ]; then
        echo 'ERROR: unsupported OS (not amzn/rhel/debian)' >&2
        cat /etc/os-release >&2 || true
        exit 1
      fi
      echo \"OS_FAMILY=\${OS_FAMILY}  OS_VERSION=\${OS_VERSION:-n/a}\"

      # --- Step 1: kernel headers (required for DKMS to build nvidia kmod) ---
      KREL=\$(uname -r)
      echo \"--- Installing kernel headers for kernel \${KREL} ---\"
      if [ \"\${OS_FAMILY}\" = 'debian' ]; then
        sudo apt-get update -qq
        sudo apt-get install -y \"linux-headers-\${KREL}\"
      else
        # Exact-match: every historical kernel-devel is usually in RHUI for
        # RHEL 9/10. When absent (e.g. AMI has an older kernel than current
        # RHUI), install the latest kernel+kernel-devel and reboot into it so
        # DKMS builds for the running kernel. The node rejoins k0s after reboot;
        # the installer retries SSH so the install continues automatically.
        if ! sudo dnf install -y \"kernel-devel-\${KREL}\" \"kernel-headers-\${KREL}\"; then
          echo \"WARN: Exact kernel-devel-\${KREL} not found in repos.\"
          # Get the latest available kernel version from the repo
          LATEST_KVER=\$(sudo dnf list available kernel --quiet 2>/dev/null | awk '/^kernel/{print \$2\".x86_64\"}' | tail -1)
          if [ -n \"\${LATEST_KVER}\" ] && [ \"\${KREL}\" != \"\${LATEST_KVER}\" ]; then
            echo \"Installing latest kernel (\${LATEST_KVER}) + matching kernel-devel so DKMS can build.\"
            sudo dnf install -y \"kernel-\${LATEST_KVER%.*}\" \"kernel-devel-\${LATEST_KVER%.*}\" \"kernel-headers-\${LATEST_KVER%.*}\" 2>/dev/null || \
              sudo dnf install -y kernel kernel-devel kernel-headers
            echo \"REBOOT_REQUIRED: kernel upgraded from \${KREL} to \${LATEST_KVER%.*} — rebooting now\"
            # Signal the outer SSH call to detect the reboot and wait
            sudo reboot &
            sleep 5
            exit 42
          else
            echo \"WARN: No newer kernel in repos; installing latest kernel-devel/headers (may mismatch).\"
            sudo dnf install -y kernel-devel kernel-headers
          fi
        fi
      fi

      # --- Step 2: EPEL + DKMS + build toolchain ----------------------------
      # DKMS builds the nvidia kernel module from source on every kernel
      # update. It needs: dkms (from EPEL), gcc, make, elfutils-libelf-devel.
      # On a BARE RHEL minimal install, NONE of these are pre-installed.
      # On AWS AMIs they may be partially pre-installed but we should not
      # rely on that — be explicit.
      if [ \"\${OS_FAMILY}\" = 'rhel' ] || [ \"\${OS_FAMILY}\" = 'amzn' ]; then
        # EPEL: AL2023 = EPEL9 (binary-compat). RHEL: matching major.
        if [ \"\${OS_FAMILY}\" = 'amzn' ]; then
          EPEL_MAJOR=9
        else
          EPEL_MAJOR=\${OS_VERSION}
        fi

        # dnf-plugins-core provides 'dnf config-manager'. Pre-installed on
        # most AMIs; install explicitly for minimal images.
        sudo dnf install -y dnf-plugins-core

        # EPEL: provides DKMS on RHEL (RHEL's own repos don't ship DKMS).
        # EPEL_RPM_URL_OVERRIDE lets air-gap customers redirect to a local mirror:
        #   export EPEL_RPM_URL_OVERRIDE="http://mirror.internal/epel/epel-release-latest-9.noarch.rpm"
        if ! rpm -q epel-release >/dev/null 2>&1; then
          echo \"--- Installing EPEL for DKMS (major \${EPEL_MAJOR}) ---\"
          _EPEL_URL=\"\${EPEL_RPM_URL_OVERRIDE:-https://dl.fedoraproject.org/pub/epel/epel-release-latest-\${EPEL_MAJOR}.noarch.rpm}\"
          sudo dnf install -y \"\${_EPEL_URL}\"
        fi
        # CRB (formerly PowerTools on RHEL 8) hosts a few EPEL build deps on
        # RHEL. AL2023 doesn't have a CRB repo (its core packages are in
        # 'amazonlinux' directly), so this whole chain is best-effort — the
        # trailing '|| true' only runs when ALL three names fail to match
        # any known repo, which is the expected state on AL2023.
        sudo dnf config-manager --set-enabled crb 2>/dev/null \\
          || sudo dnf config-manager --set-enabled PowerTools 2>/dev/null \\
          || sudo dnf config-manager --set-enabled powertools 2>/dev/null \\
          || true

        # DKMS + the build toolchain. Being explicit means a minimal / bare
        # RHEL install works out-of-the-box and future driver versions
        # with different weak-deps don't silently miss a needed package.
        echo '--- Installing DKMS + build toolchain (gcc, make, elfutils-libelf-devel) ---'
        sudo dnf install -y dkms gcc make elfutils-libelf-devel
      fi

      # --- Step 3: CUDA repo for the right OS family + version --------------
      # Clean cross-major repos so dnf doesn't try to install from the wrong
      # CUDA metadata (common failure mode on in-place RHEL 9 → 10 upgrades,
      # and on re-runs of this script where the target OS may have changed).
      #
      # CUDA_REPO_URL_OVERRIDE: set to a local mirror .repo/.deb URL to redirect
      # away from developer.download.nvidia.com:
      #   export CUDA_REPO_URL_OVERRIDE="http://mirror.internal/cuda/cuda-rhel9.repo"
      if [ \"\${OS_FAMILY}\" = 'amzn' ]; then
        sudo rm -f /etc/yum.repos.d/cuda-amzn*.repo
        _CUDA_REPO=\"\${CUDA_REPO_URL_OVERRIDE:-https://developer.download.nvidia.com/compute/cuda/repos/amzn\${OS_VERSION:-2023}/x86_64/cuda-amzn\${OS_VERSION:-2023}.repo}\"
        sudo dnf config-manager --add-repo \"\${_CUDA_REPO}\"
      elif [ \"\${OS_FAMILY}\" = 'rhel' ]; then
        sudo rm -f /etc/yum.repos.d/cuda-rhel*.repo
        _CUDA_REPO=\"\${CUDA_REPO_URL_OVERRIDE:-https://developer.download.nvidia.com/compute/cuda/repos/rhel\${OS_VERSION}/x86_64/cuda-rhel\${OS_VERSION}.repo}\"
        sudo dnf config-manager --add-repo \"\${_CUDA_REPO}\"
      elif [ \"\${OS_FAMILY}\" = 'debian' ]; then
        _CUDA_DEB=\"\${CUDA_REPO_URL_OVERRIDE:-https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb}\"
        curl -fsSL \"\${_CUDA_DEB}\" -o /tmp/cuda-keyring.deb
        sudo dpkg -i /tmp/cuda-keyring.deb
        sudo apt-get update -qq
      fi

      # --- Step 4: install the driver -------------------------------------
      # Follows NVIDIA's official RHEL install guidance:
      # https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/
      #
      # Package names in the CUDA repo (rhel9/rhel10/amzn2023):
      #   - cuda-drivers                -> meta-pkg for proprietary driver
      #                                    (pulls nvidia-driver, kmod-nvidia-latest-dkms,
      #                                    nvidia-driver-cuda, nvidia-driver-libs,
      #                                    libnvidia-ml, etc.)
      #   - nvidia-open                 -> meta-pkg for open-source kernel driver
      #   - nvidia-driver:latest-dkms   -> RHEL 9 only (dnf modular stream).
      #                                    Removed in RHEL 10 (modularity deprecated).
      #
      # There is NO package called 'nvidia-driver-dkms' in either repo —
      # previous attempts at it failed on every fresh install.
      # 
      # Strategy: single meta-package install. RHEL 10 requires --allowerasing
      # because it has to remove conflicting nouveau packages. The flag is
      # a no-op on RHEL 9/AL2023 where there's nothing to erase.
      echo '--- Installing NVIDIA driver (meta package: cuda-drivers) ---'
      if [ \"\${OS_FAMILY}\" = 'debian' ]; then
        sudo apt-get install -y nvidia-driver-550
      else
        # Blacklist nouveau so the new nvidia driver can load without fighting it.
        # Harmless if nouveau isn't loaded (grep returns nothing).
        if lsmod | grep -q '^nouveau'; then
          echo '--- Blacklisting nouveau + unloading ---'
          echo -e 'blacklist nouveau\\noptions nouveau modeset=0' \\
            | sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null
          sudo rmmod nouveau 2>/dev/null || true
          # Regenerate initramfs so nouveau doesn't come back on reboot.
          sudo dracut --force 2>/dev/null || true
        fi

        # Primary strategy: cuda-drivers meta-package (works on RHEL 9, RHEL 10,
        # AL2023 — the CUDA repo ships the same package name everywhere).
        if sudo dnf install -y --allowerasing cuda-drivers; then
          echo '✓ Installed cuda-drivers meta-package'
        elif [ \"\${OS_VERSION}\" = '9' ] && sudo dnf module install -y nvidia-driver:latest-dkms; then
          # RHEL 9 fallback: classic dnf module stream (RHEL 10 dropped modularity).
          # Kept as a safety net — cuda-drivers should always work above.
          echo '✓ Installed nvidia-driver:latest-dkms via dnf module (RHEL 9 legacy path)'
        elif sudo dnf install -y --allowerasing nvidia-open; then
          # Last-resort fallback: open-source kernel driver.
          echo '✓ Installed nvidia-open (open-kernel fallback)'
        else
          echo 'ERROR: all NVIDIA driver install strategies failed' >&2
          echo '  Tried: cuda-drivers, nvidia-driver:latest-dkms (module), nvidia-open' >&2
          echo '  Possible causes:' >&2
          echo '    - CUDA repo URL incorrect for OS version \${OS_VERSION}' >&2
          echo '    - EPEL/DKMS not available' >&2
          echo '    - Network blocked to developer.download.nvidia.com' >&2
          exit 1
        fi
      fi

      # --- Step 5: verify DKMS built + load kmod ---------------------------
      # Before modprobe: check dkms status so we catch kernel-mismatch cases
      # early with a clear error instead of the cryptic 'Module not found'.
      echo '--- Verifying DKMS status + loading nvidia kmod ---'
      if [ \"\${OS_FAMILY}\" != 'debian' ]; then
        DKMS_OUT=\$(sudo dkms status 2>&1 | grep nvidia || true)
        if [ -z \"\${DKMS_OUT}\" ]; then
          echo 'ERROR: dkms status shows no nvidia entry — driver install did not register with DKMS' >&2
          exit 1
        fi
        echo \"DKMS: \${DKMS_OUT}\"
        # If DKMS is in 'added' state (registered but not yet built), build it
        # explicitly. This happens when the package installs DKMS source but the
        # automatic build was skipped (e.g. kernel was just upgraded + rebooted).
        if echo \"\${DKMS_OUT}\" | grep -qE '^nvidia.*: added$'; then
          echo 'DKMS module in added state — triggering explicit build+install...'
          sudo dkms build -m nvidia -v \$(sudo dkms status | grep '^nvidia' | awk -F/ '{print \$2}' | awk '{print \$1}') -k \"\${KREL}\" 2>&1 || true
          sudo dkms install -m nvidia -v \$(sudo dkms status | grep '^nvidia' | awk -F/ '{print \$2}' | awk '{print \$1}') -k \"\${KREL}\" 2>&1 || true
          DKMS_OUT=\$(sudo dkms status 2>&1 | grep nvidia || true)
          echo \"DKMS after explicit build: \${DKMS_OUT}\"
        fi
        if ! echo \"\${DKMS_OUT}\" | grep -qE 'installed|built'; then
          echo 'ERROR: nvidia DKMS module is not installed/built. See: sudo dkms status; dmesg | grep nvidia' >&2
          exit 1
        fi
        # Check the built-for kernel matches the running kernel. If not,
        # a reboot into the newer installed kernel is required — DO NOT pretend
        # modprobe will work. This is exactly what prevents false-positive
        # 'install succeeded' on nodes that had a pending kernel update.
        if ! echo \"\${DKMS_OUT}\" | grep -qF \"\${KREL}\"; then
          echo \"ERROR: DKMS built nvidia module for a different kernel than \${KREL}.\" >&2
          echo \"       'sudo dkms status' shows: \${DKMS_OUT}\" >&2
          echo \"       Action: reboot the node into the kernel DKMS built for, then re-run.\" >&2
          exit 1
        fi
      fi
      sudo modprobe nvidia || {
        echo 'ERROR: modprobe nvidia failed after DKMS build succeeded.' >&2
        echo 'Diagnose with: sudo dmesg | grep -i nvidia | tail -30' >&2
        exit 1
      }
    " || _nvidia_rc=$?
    if [[ "${_nvidia_rc:-0}" -ne 0 ]]; then
      if [[ "${_nvidia_rc}" -eq 42 ]]; then
        # exit 42 = kernel upgrade triggered a reboot; wait for node and retry
        echo "Kernel upgraded on ${gpu_ip} — waiting for reboot (up to 5 min)..."
        local _wait=0
        while ! ssh_exec "${gpu_ip}" "echo ok" &>/dev/null; do
          sleep 15; _wait=$(( _wait + 15 ))
          [[ "${_wait}" -ge 300 ]] && { echo "❌ ${gpu_ip} did not come back after kernel reboot" >&2; return 1; }
        done
        echo "Node ${gpu_ip} is back (kernel: $(ssh_exec "${gpu_ip}" "uname -r" 2>/dev/null)). Retrying NVIDIA install..."
        _install_nvidia_on_node "${gpu_ip}"
        return $?
      fi
      echo "❌ NVIDIA driver install failed on ${gpu_ip}" >&2
      return 1
    fi

    # ---- Phase C: hard-verify driver actually works -----------------------
    local ver_check
    ver_check=$(ssh_exec "${gpu_ip}" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1 | head -1" || echo "")
    if [[ -z "${ver_check}" ]] || ! [[ "${ver_check}" =~ ^[0-9]+\.[0-9]+ ]]; then
      echo "❌ nvidia-smi verification failed on ${gpu_ip} (got: '${ver_check}')" >&2
      return 1
    fi
    echo "✓ NVIDIA driver v${ver_check} running on ${gpu_ip}"
  fi

  # ---- Phase D: NVIDIA Container Toolkit install ------------------------
  # Short-circuit the repo reachability check if nvidia-ctk is already present.
  # Only check reachability (and only in non-air-gap mode) when we actually need
  # to download the CTK. Use the repo file URL — the bare nvidia.github.io root
  # times out from some regions despite the repo itself being reachable.
  local _ctk_present
  _ctk_present=$(ssh_exec "${gpu_ip}" "command -v nvidia-ctk >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo no)
  if [[ "${_ctk_present}" != "yes" ]] && [[ "${AIRGAP_MODE:-false}" != "true" ]]; then
    wait_for_dependency \
      "NVIDIA package repo (nvidia.github.io) — required for container-toolkit install on ${gpu_ip}" \
      "ssh_exec '${gpu_ip}' 'curl -sf --connect-timeout 10 --max-time 15 https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo >/dev/null 2>&1'" \
      180
  elif [[ "${_ctk_present}" == "yes" ]]; then
    log "nvidia-ctk already installed on ${gpu_ip} — skipping repo check"
  else
    log "AIRGAP_MODE=true — skipping NVIDIA repo check for ${gpu_ip}; drivers must be pre-installed on the node"
  fi

  echo "Installing NVIDIA Container Toolkit on ${gpu_ip}..."
  if ! ssh_exec "${gpu_ip}" "
    set -euo pipefail
    if command -v nvidia-ctk >/dev/null 2>&1; then
      echo '✓ nvidia-ctk already installed (version: '\"\$(nvidia-ctk --version 2>/dev/null | head -1)\"')'
    else
      echo '--- Adding NVIDIA container-toolkit repo ---'
      # NVIDIA_CTK_REPO_URL_OVERRIDE: set to a local mirror repo URL to redirect
      # away from nvidia.github.io (partial air-gap or local mirror scenario):
      #   export NVIDIA_CTK_REPO_URL_OVERRIDE="http://mirror.internal/nvidia-ctk/nvidia-container-toolkit.repo"
      if [ -f /etc/debian_version ]; then
        _CTK_BASE=\"\${NVIDIA_CTK_REPO_URL_OVERRIDE:-https://nvidia.github.io/libnvidia-container}\"
        curl -fsSL \"\${_CTK_BASE}/gpgkey\" | \
          sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL \"\${_CTK_BASE}/stable/deb/nvidia-container-toolkit.list\" | \
          sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
          sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y nvidia-container-toolkit
      else
        # RHEL 9 and 10 both use the same libnvidia-container stable RPM repo.
        _CTK_REPO=\"\${NVIDIA_CTK_REPO_URL_OVERRIDE:-https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo}\"
        curl -fsSL \"\${_CTK_REPO}\" | \
          sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo >/dev/null
        sudo dnf install -y nvidia-container-toolkit
      fi
    fi

    # --- Configure k0s containerd (k0s uses /run/k0s/containerd.sock) ----
    # Strategy (compatible with nvidia-ctk >= 1.14, validated against 1.19):
    #
    #   1. Run \`nvidia-ctk runtime configure --runtime=containerd
    #      --nvidia-set-as-default\` with NO --config= flag. This makes
    #      nvidia-ctk emit a complete, correct drop-in at its known-good
    #      default path /etc/containerd/conf.d/99-nvidia.toml, containing:
    #
    #        - version = 2
    #        - plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia
    #        - default_runtime_name = \"nvidia\"
    #
    #   2. On k0s nodes, we cannot leave that file at its default path
    #      because k0s's managed /etc/k0s/containerd.toml only imports
    #      /etc/k0s/containerd.d/*.toml — anything under
    #      /etc/containerd/conf.d/ is ignored. So we move it.
    #
    # We deliberately avoid passing --config= pointing at the k0s drop-in,
    # because nvidia-ctk 1.19 treats the --config target as a \"main\"
    # containerd config and only writes a two-line stub (imports + version)
    # into it, emitting the actual runtime config to /etc/containerd/conf.d/
    # regardless. That silent behavior caused the 'containerd-nvidia-runtime:
    # FAIL' verification error that reaching here used to surface.
    echo '--- Configuring containerd runtime for nvidia ---'
    if [ -d /etc/k0s/containerd.d ]; then
      sudo mkdir -p /etc/k0s/containerd.d

      # Preserve any existing drop-in so idempotent re-runs don't lose
      # hand-tuned configuration.
      if [ -s /etc/k0s/containerd.d/nvidia.toml ]; then
        sudo cp -a /etc/k0s/containerd.d/nvidia.toml /etc/k0s/containerd.d/nvidia.toml.bak
      fi

      # Wipe any previous output so we can tell whether this invocation
      # actually produced a file.
      sudo rm -f /etc/containerd/conf.d/99-nvidia.toml

      # Generate the canonical drop-in at nvidia-ctk's default path. We
      # rely on --nvidia-set-as-default to inject default_runtime_name.
      sudo nvidia-ctk runtime configure \\
        --runtime=containerd \\
        --nvidia-set-as-default

      # Hard-fail if the file is missing or empty.
      if [ ! -s /etc/containerd/conf.d/99-nvidia.toml ]; then
        echo 'ERROR: nvidia-ctk did not produce /etc/containerd/conf.d/99-nvidia.toml' >&2
        echo 'nvidia-ctk --version:' >&2
        nvidia-ctk --version 2>&1 | head -3 >&2
        exit 1
      fi

      # Verify the generated drop-in actually names nvidia as the default
      # runtime. Earlier nvidia-ctk versions (< 1.14) ignored
      # --nvidia-set-as-default silently.
      if ! sudo grep -q 'default_runtime_name = \"nvidia\"' /etc/containerd/conf.d/99-nvidia.toml; then
        echo 'ERROR: nvidia-ctk drop-in does not set default_runtime_name = \"nvidia\".' >&2
        echo 'nvidia-ctk --version:' >&2
        nvidia-ctk --version 2>&1 | head -3 >&2
        echo '--- generated drop-in (first 30 lines) ---' >&2
        sudo head -30 /etc/containerd/conf.d/99-nvidia.toml >&2
        exit 1
      fi

      # Relocate the drop-in from nvidia-ctk's default path to the path
      # that k0s's managed containerd.toml imports. We strip keys that
      # would duplicate declarations already made by k0s's top-level
      # config (version / imports / disabled_plugins / required_plugins);
      # leaving them in place causes containerd to refuse to start with
      # duplicate top-level-key errors.
      sudo mv /etc/containerd/conf.d/99-nvidia.toml /etc/k0s/containerd.d/nvidia.toml
      sudo sed -i '/^version/d; /^imports/d; /^disabled_plugins/d; /^required_plugins/d' \\
        /etc/k0s/containerd.d/nvidia.toml

      # containerd 2.x (shipped by k0s >= 1.33) renamed the CRI plugin: the
      # legacy v1 table plugins.io.containerd.grpc.v1.cri was split into
      # plugins.io.containerd.cri.v1.runtime (runtime config) and
      # plugins.io.containerd.cri.v1.images (image config), and the config
      # loader now REJECTS the legacy key in a pre-flight check, crash-looping
      # k0sworker (so the GPU node never becomes Ready and the install aborts).
      # nvidia-ctk (through at least 1.19) still emits the legacy key, so when
      # this k0s's own managed base config uses the new runtime plugin name we
      # rewrite the drop-in plugin key to match. On older containerd-1.x k0s the
      # base config still uses the legacy key, the grep fails, and the drop-in
      # is left untouched.
      if sudo grep -q 'io\\.containerd\\.cri\\.v1\\.runtime' /etc/k0s/containerd.toml 2>/dev/null; then
        echo '--- Rewriting nvidia drop-in to containerd 2.x CRI plugin key (io.containerd.cri.v1.runtime) ---'
        sudo sed -i 's/io\\.containerd\\.grpc\\.v1\\.cri/io.containerd.cri.v1.runtime/g' \\
          /etc/k0s/containerd.d/nvidia.toml
      fi

      # Final sanity: the k0s drop-in must still carry default_runtime_name
      # after the key-strip above (it lives under a nested table, not at
      # top level, so the sed above never touches it — but verify anyway
      # so failure is loud instead of silently broken).
      if ! sudo grep -q 'default_runtime_name = \"nvidia\"' /etc/k0s/containerd.d/nvidia.toml; then
        echo 'ERROR: /etc/k0s/containerd.d/nvidia.toml lost default_runtime_name after relocation.' >&2
        echo '--- file contents ---' >&2
        sudo cat /etc/k0s/containerd.d/nvidia.toml >&2
        exit 1
      fi
    elif [ -f /etc/containerd/config.toml ]; then
      # Non-k0s containerd (standalone) — safe to let nvidia-ctk edit in place.
      sudo nvidia-ctk runtime configure --runtime=containerd --nvidia-set-as-default
    else
      echo 'ERROR: no containerd config dir found at /etc/k0s/containerd.d or /etc/containerd/config.toml' >&2
      exit 1
    fi

    # --- Generate the CDI spec so k8s device plugin can find the GPUs ---
    echo '--- Generating CDI spec ---'
    sudo mkdir -p /etc/cdi
    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    if [ ! -s /etc/cdi/nvidia.yaml ]; then
      echo 'ERROR: /etc/cdi/nvidia.yaml empty after generation' >&2
      exit 1
    fi
    # Sanity-check that NVML could enumerate at least one device (without
    # this, the spec contains no devices and the device plugin crash-loops).
    if ! grep -q 'name: ' /etc/cdi/nvidia.yaml; then
      echo 'ERROR: /etc/cdi/nvidia.yaml contains no device entries' >&2
      cat /etc/cdi/nvidia.yaml | head -40 >&2
      exit 1
    fi

    # --- Restart k0sworker to pick up new runtime + CDI spec -----------
    echo '--- Restarting k0sworker to pick up runtime changes ---'
    sudo systemctl stop k0sworker || true
    sleep 3
    sudo pkill -9 containerd-shim || true
    sudo rm -f /run/k0s/containerd.sock || true
    sudo systemctl start k0sworker

    # Quick sanity: confirm nvidia-ctk + libnvidia-ml.so exist where expected.
    # Search all known paths (distributions differ): RHEL/Fedora use
    # /usr/lib64, Debian/Ubuntu use /usr/lib/x86_64-linux-gnu, and
    # some distros also expose it via ldconfig.
    echo '--- Post-install sanity ---'
    nvidia-ctk --version | head -1
    LIBNVML_PATH=\$(ldconfig -p 2>/dev/null | awk '/libnvidia-ml\\.so\\.1/ {print \$NF; exit}')
    if [ -z \"\${LIBNVML_PATH}\" ]; then
      for so in /usr/lib64/libnvidia-ml.so.1 \\
                /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 \\
                /usr/lib/libnvidia-ml.so.1; do
        if [ -e \"\${so}\" ]; then LIBNVML_PATH=\"\${so}\"; break; fi
      done
    fi
    if [ -n \"\${LIBNVML_PATH}\" ]; then
      echo \"✓ libnvidia-ml.so.1 found: \${LIBNVML_PATH}\"
    else
      echo 'ERROR: libnvidia-ml.so.1 not found on any standard path.' >&2
      exit 1
    fi
  "; then
    echo "❌ Container toolkit setup failed on ${gpu_ip}" >&2
    return 1
  fi

  # ---- Phase E: post-install strict verification -----------------------
  # These checks are what the device plugin will actually need at runtime.
  local checks_out
  checks_out=$(ssh_exec "${gpu_ip}" "
    set +e
    echo -n 'nvidia-smi: '
    nvidia-smi --query-gpu=name --format=csv,noheader >/dev/null 2>&1 && echo OK || echo FAIL
    echo -n 'libnvidia-ml.so: '
    # Check ldconfig cache first (most reliable), then fall back to the
    # common per-distribution install paths.
    if ldconfig -p 2>/dev/null | grep -q 'libnvidia-ml\.so\.1'; then
      echo OK
    elif ls /usr/lib64/libnvidia-ml.so.1 \\
           /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 \\
           /usr/lib/libnvidia-ml.so.1 2>/dev/null | head -1 | grep -q .; then
      echo OK
    else
      echo FAIL
    fi
    echo -n 'nvidia-ctk: '
    command -v nvidia-ctk >/dev/null 2>&1 && echo OK || echo FAIL
    echo -n 'cdi-spec: '
    [ -s /etc/cdi/nvidia.yaml ] && grep -q 'name: ' /etc/cdi/nvidia.yaml && echo OK || echo FAIL
    echo -n 'nvidia-kmod: '
    lsmod | grep -q '^nvidia ' && echo OK || echo FAIL
    echo -n 'containerd-nvidia-runtime: '
    grep -q 'default_runtime_name = \"nvidia\"' /etc/k0s/containerd.d/nvidia.toml 2>/dev/null && echo OK || echo FAIL
  ")

  echo "Strict verification on ${gpu_ip}:"
  echo "${checks_out}" | sed 's/^/    /'
  if echo "${checks_out}" | grep -q FAIL; then
    echo "❌ Strict verification failed on ${gpu_ip} — device plugin will crash-loop with ERROR_LIBRARY_NOT_FOUND" >&2
    return 1
  fi
  echo "✓ Strict verification passed on ${gpu_ip}"
  return 0
}

# EKS GPU AMIs ship with NVIDIA drivers pre-installed.
# For k0s on generic AMIs (e.g. Amazon Linux 2023), we must install them
# on the host before the Kubernetes device-plugin can expose GPUs.
install_nvidia_host_drivers() {
  if [[ ${GPU_WORKER_COUNT} -eq 0 ]]; then
    log "Skipping NVIDIA host driver install (no GPU workers)"
    return 0
  fi

  log "Installing NVIDIA drivers & container toolkit on GPU worker nodes..."

  # Ensure WORKER_IPS is populated (it may not be if install_k0s_cluster was skipped)
  if [[ -z "${WORKER_IPS+x}" || ${#WORKER_IPS[@]} -eq 0 ]]; then
    if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
      IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
      log "  Loaded ${#WORKER_IPS[@]} worker IP(s) from config: ${WORKER_IPS[*]}"
    else
      warn "No worker IPs available; skipping host driver install"
      return 0
    fi
  fi

  # Identify GPU worker IPs (workers after the first CPU_WORKER_COUNT)
  local gpu_ips=()
  local idx=0
  for ip in "${WORKER_IPS[@]}"; do
    if [[ ${idx} -ge ${CPU_WORKER_COUNT} ]]; then
      gpu_ips+=("${ip}")
    fi
    idx=$((idx + 1))
  done

  if [[ ${#gpu_ips[@]} -eq 0 ]]; then
    warn "No GPU worker IPs found; skipping host driver install"
    return 0
  fi

  # Run driver + toolkit install on all GPU nodes in parallel
  log "Installing NVIDIA drivers on ${#gpu_ips[@]} GPU node(s) in parallel..."
  local pids=()
  local logdir
  logdir=$(mktemp -d)

  for gpu_ip in "${gpu_ips[@]}"; do
    (
      _install_nvidia_on_node "${gpu_ip}" > "${logdir}/${gpu_ip}.log" 2>&1
      echo $? > "${logdir}/${gpu_ip}.rc"
    ) &
    pids+=($!)
    log "  Started NVIDIA install on ${gpu_ip} (pid $!)"
  done

  # Wait for all background installs to finish
  local failed=0
  for i in "${!pids[@]}"; do
    local pid=${pids[$i]}
    local gpu_ip=${gpu_ips[$i]}
    if wait "${pid}"; then
      log "  ✓ NVIDIA setup completed on ${gpu_ip}"
    else
      warn "  NVIDIA setup on ${gpu_ip} had issues"
      failed=$((failed + 1))
    fi
    # Stream the per-node log so output is visible
    while IFS= read -r line; do
      log "    [${gpu_ip}] ${line}"
    done < "${logdir}/${gpu_ip}.log"
  done

  rm -rf "${logdir}"

  if [[ ${failed} -gt 0 ]]; then
    err "${failed}/${#gpu_ips[@]} GPU node(s) had NVIDIA install failures. Aborting install.
    
    What to check on a failing node:
      ssh <node> 'dkms status | grep nvidia'             # must show 'installed'
      ssh <node> 'lsmod | grep nvidia'                   # must list nvidia kmod
      ssh <node> 'ls /usr/lib64/libnvidia-ml.so.1'       # must exist
      ssh <node> 'nvidia-ctk --version'                  # must work
      ssh <node> 'cat /etc/cdi/nvidia.yaml | head -40'   # must list GPU devices
      ssh <node> 'sudo dmesg | grep -i nvidia | tail -30'# kernel-level errors
    
    Common causes:
      - kernel-devel for running kernel not available (exact match too new);
        reboot to match a released kernel, then re-run
      - EPEL/DKMS didn't install (check 'rpm -q epel-release dkms')
      - Stale /etc/yum.repos.d/cuda-rhel*.repo from a prior OS upgrade"
  else
    log "NVIDIA drivers installed successfully on all ${#gpu_ips[@]} GPU node(s)"
  fi

  # Wait for GPU workers to rejoin and verify they are Ready.
  # Timeout is 600s: driver install may trigger a kernel module reload or reboot
  # which can take several minutes before the node rejoins the cluster.
  log "Waiting for GPU worker nodes to rejoin cluster and become Ready..."
  local gpu_wait_timeout=600
  local gpu_wait_elapsed=0
  local all_gpu_ready=false

  while [[ ${gpu_wait_elapsed} -lt ${gpu_wait_timeout} ]]; do
    all_gpu_ready=true
    for gpu_ip in "${gpu_ips[@]}"; do
      # Resolve GPU node name via SSH hostname lookup
      local gpu_node
      gpu_node=$(resolve_node_name "${gpu_ip}")

      if [[ -z "${gpu_node}" ]] || ! kubectl get node "${gpu_node}" &>/dev/null; then
        all_gpu_ready=false
        break
      fi

      local ready_status
      ready_status=$(kubectl get node "${gpu_node}" -o json 2>/dev/null | \
        jq -r '.status.conditions[] | select(.type=="Ready") | .status' 2>/dev/null || echo "")
      if [[ "${ready_status}" != "True" ]]; then
        all_gpu_ready=false
        break
      fi
    done

    if [[ "${all_gpu_ready}" == "true" ]]; then
      log "✓ All GPU worker nodes are Ready"
      break
    fi

    sleep 10
    gpu_wait_elapsed=$((gpu_wait_elapsed + 10))
    log "  Waiting for GPU nodes to be Ready... ${gpu_wait_elapsed}/${gpu_wait_timeout}s"
  done

  if [[ "${all_gpu_ready}" != "true" ]]; then
    err "Some GPU nodes did not become Ready within ${gpu_wait_timeout}s. \
Check 'kubectl get nodes' and reboot any NotReady GPU node, then re-run the installer."
  fi

  # Verify GPUs are visible to Kubernetes. If the device-plugin DaemonSet
  # isn't installed yet (expected during the initial install — it's created
  # by install_nvidia_device_plugin() in Phase 2), short-circuit immediately
  # instead of waiting a fruitless 120s. For idempotent re-runs where the
  # DS is already present we poll up to 120s.
  if ! kubectl -n kube-system get ds nvidia-device-plugin-daemonset &>/dev/null; then
    log "  (device plugin DaemonSet not yet installed; capacity will appear after install_nvidia_device_plugin runs)"
    log "NVIDIA host driver installation complete"
    return 0
  fi

  log "Checking if GPUs are visible to Kubernetes..."
  local gpu_capacity="0"
  local cap_wait=0
  local cap_timeout=120
  while [[ ${cap_wait} -lt ${cap_timeout} ]]; do
    gpu_capacity=$(kubectl get nodes -l splunk.ai/workload-type=gpu -o json 2>/dev/null | \
      jq '[.items[].status.capacity["nvidia.com/gpu"] // "0" | tonumber] | add' 2>/dev/null || echo "0")
    if [[ "${gpu_capacity}" -gt 0 ]]; then
      log "✓ Total GPUs visible to Kubernetes: ${gpu_capacity}"
      break
    fi
    sleep 10
    cap_wait=$((cap_wait + 10))
    log "  Waiting for GPU capacity to be reported... ${cap_wait}/${cap_timeout}s"
  done

  if [[ "${gpu_capacity}" -le 0 ]]; then
    err "Device plugin DaemonSet is installed but no GPUs are visible after ${cap_timeout}s.
    Investigate with:
      kubectl -n kube-system logs ds/nvidia-device-plugin-daemonset --tail 40
      kubectl -n kube-system describe pod -l name=nvidia-device-plugin-ds"
  fi

  log "NVIDIA host driver installation complete"
}

# ====== INSTALL NVIDIA DEVICE PLUGIN (matches EKS approach) ======
# Ref: eks_cluster_with_stack.sh — uses the simple DaemonSet, NOT the GPU Operator.
# The GPU Operator's driver container images don't exist for Amazon Linux 2023.
install_nvidia_device_plugin() {
  if [[ ${GPU_WORKER_COUNT} -eq 0 ]]; then
    log "Skipping NVIDIA device plugin (no GPU workers)"
    return 0
  fi

  local ver="${NVIDIA_VERSION:-v0.17.3}"
  log "Installing NVIDIA device plugin DaemonSet (${ver})..."

  # Create the nvidia RuntimeClass FIRST. The device-plugin DaemonSet we
  # apply below references this RuntimeClass via runtimeClassName=nvidia, so
  # it must exist before any DS pod is scheduled — otherwise kubelet will
  # reject the pod with 'RuntimeClass "nvidia" not found'.
  log "  Creating nvidia RuntimeClass..."
  cat <<'RTEOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
RTEOF

  # Fetch the upstream manifest into a temp file, inject our required
  # pod-spec fields (nodeSelector + runtimeClassName) BEFORE applying.
  # Doing this in one shot — instead of apply-then-patch — avoids the
  # race where the initial DS pods start under the default runtime
  # (runc), hit 'ERROR_LIBRARY_NOT_FOUND' because they have no access to
  # libnvidia-ml.so or /dev/nvidia*, and land in CrashLoopBackOff before
  # the patch ever reaches them.
  local manifest
  manifest=$(mktemp)
  local nvidia_manifest_url="${NVIDIA_DEVICE_PLUGIN_MANIFEST_URL:-https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${ver}/deployments/static/nvidia-device-plugin.yml}"
  if ! curl -fsSL "${nvidia_manifest_url}" -o "${manifest}"; then
    rm -f "${manifest}"
    err "Failed to fetch NVIDIA device-plugin manifest (version ${ver}).
    URL: ${nvidia_manifest_url}
    For air-gapped installs set NVIDIA_DEVICE_PLUGIN_MANIFEST_URL=file:///path/to/nvidia-device-plugin.yml"
  fi

  log "  Patching manifest in place: GPU nodeSelector + nvidia runtimeClassName..."
  # Use yq when available (cleanest, structure-aware); fall back to kubectl
  # patch --local on stdout — both produce the same patched manifest on
  # stdout which we then `apply -f -`.
  local patched
  patched=$(mktemp)
  if command -v yq >/dev/null 2>&1; then
    yq eval '
      (select(.kind == "DaemonSet") | .spec.template.spec.nodeSelector."splunk.ai/workload-type") = "gpu"
      | (select(.kind == "DaemonSet") | .spec.template.spec.runtimeClassName) = "nvidia"
    ' "${manifest}" > "${patched}"
  else
    # Fallback: use kubectl patch --local. This requires reading from the
    # manifest and piping through patch; multi-document files complicate
    # things, but this upstream manifest is a single DaemonSet.
    kubectl patch -f "${manifest}" --local -o yaml \
      --type='json' \
      -p='[
        {"op": "add", "path": "/spec/template/spec/nodeSelector", "value": {"splunk.ai/workload-type": "gpu"}},
        {"op": "add", "path": "/spec/template/spec/runtimeClassName", "value": "nvidia"}
      ]' > "${patched}"
  fi

  if ! kubectl apply -n kube-system -f "${patched}"; then
    rm -f "${manifest}" "${patched}"
    err "Failed to apply patched NVIDIA device-plugin manifest. Check kubectl connectivity."
  fi
  rm -f "${manifest}" "${patched}"

  # Wait for the DS to roll out so the caller observes GPU capacity as
  # soon as possible. Non-fatal: we verify capacity explicitly upstream
  # via the strict-verification loop.
  kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=3m || true

  log "NVIDIA device plugin installed successfully"
}

# ====== INSTALL PROMETHEUS OPERATOR ======
install_kube_prometheus() {
  log "Installing kube-prometheus-stack..."

  local chart_ref
  if [[ -n "${PROMETHEUS_CHART_PATH:-}" && -f "${PROMETHEUS_CHART_PATH}" ]]; then
    chart_ref="${PROMETHEUS_CHART_PATH}"
    log "  Using local chart: ${chart_ref}"
  else
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
    helm repo update prometheus-community
    chart_ref="prometheus-community/kube-prometheus-stack"
  fi

  helm_retry 3 upgrade --install kube-prometheus-stack "${chart_ref}" \
    --namespace monitoring --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --wait --timeout=10m

  log "kube-prometheus-stack installed successfully"
}

# ====== INSTALL OTEL OPERATOR ======
install_otel_operator_and_contrib_collector() {
  log "Installing OpenTelemetry Operator..."

  # OTEL operator uses cert-manager for webhook certs — ensure webhook is ready
  wait_for_cert_manager_webhook 30 10

  local chart_ref
  if [[ -n "${OTEL_CHART_PATH:-}" && -f "${OTEL_CHART_PATH}" ]]; then
    chart_ref="${OTEL_CHART_PATH}"
    log "  Using local chart: ${chart_ref}"
  else
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true
    helm repo update open-telemetry
    chart_ref="open-telemetry/opentelemetry-operator"
  fi

  # Use cert-manager for webhook certificates (now that konnectivity is fixed)
  helm_retry 3 upgrade --install opentelemetry-operator "${chart_ref}" \
    --namespace opentelemetry-operator-system --create-namespace \
    --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib \
    --set admissionWebhooks.certManager.enabled=true \
    --wait --timeout=10m

  wait_for_crd opentelemetrycollectors.opentelemetry.io 300

  log "OpenTelemetry Operator installed successfully"
}

# ====== INSTALL RAY OPERATOR ======
install_ray_operator() {
  log "Installing KubeRay Operator..."

  local chart_ref version_flag=()
  if [[ -n "${KUBERAY_CHART_PATH:-}" && -f "${KUBERAY_CHART_PATH}" ]]; then
    chart_ref="${KUBERAY_CHART_PATH}"
    log "  Using local chart: ${chart_ref}"
  else
    helm repo add kuberay https://ray-project.github.io/kuberay-helm/ || true
    helm repo update kuberay
    chart_ref="kuberay/kuberay-operator"
    version_flag=(--version 1.2.2)
  fi

  helm_retry 3 upgrade --install kuberay-operator "${chart_ref}" \
    --namespace ray-system --create-namespace \
    "${version_flag[@]+"${version_flag[@]}"}" \
    --set image.repository=quay.io/kuberay/operator \
    --set image.tag=v1.2.2 \
    --wait --timeout=10m

  wait_for_crd rayservices.ray.io 300
  wait_for_crd rayclusters.ray.io 300

  log "KubeRay Operator installed successfully"
}

# ====== INSTALL SPLUNK OPERATOR ======
install_splunk_operator() {
  if [[ "${SPLUNK_MODE}" != "internal" ]]; then
    log "Splunk mode=${SPLUNK_MODE} — skipping Splunk Operator install (no in-cluster Splunk)"
    return 0
  fi

  log "Installing Splunk Operator..."

  if [[ ! -f "${SPLUNK_OPERATOR_FILE}" ]]; then
    warn "Splunk operator file not found: ${SPLUNK_OPERATOR_FILE}"
    return 0
  fi

  # Determine the namespace from the YAML file or use default
  local splunk_operator_ns="splunk-operator"
  ensure_namespace "${splunk_operator_ns}"

  # Create image pull secrets in splunk-operator namespace BEFORE applying manifests
  log "Creating image pull secrets in ${splunk_operator_ns} namespace..."
  create_image_pull_secrets "${splunk_operator_ns}" >/dev/null 2>&1 || true

  # Use server-side apply: idempotent, handles CRDs without annotation size
  # limits, and never deletes resources (unlike replace --force).
  log "Installing/updating Splunk Operator CRDs and resources..."
  kubectl apply --server-side --force-conflicts -f "${SPLUNK_OPERATOR_FILE}" \
    2>&1 | grep -v "^Warning:" || true

  # Patch splunk-operator deployment with imagePullSecrets if any exist
  log "Checking for imagePullSecrets to add to Splunk Operator deployment..."
  local secrets_patch=""
  for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
    if kubectl get secret "${secret_name}" -n "${splunk_operator_ns}" &>/dev/null 2>&1; then
      secrets_patch+='{"name":"'"${secret_name}"'"},'
      log "  Found secret: ${secret_name}"
    fi
  done

  if [[ -n "${secrets_patch}" ]]; then
    secrets_patch="${secrets_patch%,}"
    local dep_name
    dep_name=$(kubectl -n "${splunk_operator_ns}" get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${dep_name}" ]]; then
      log "Patching Splunk Operator deployment (${dep_name}) with imagePullSecrets..."
      kubectl -n "${splunk_operator_ns}" patch deployment "${dep_name}" \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":['"${secrets_patch}"']}]' \
        2>/dev/null || log "  imagePullSecrets may already exist"

      # Restart to apply changes
      kubectl rollout restart deployment "${dep_name}" -n "${splunk_operator_ns}" 2>/dev/null || true
    fi
  fi

  wait_for_crd standalones.enterprise.splunk.com 300

  log "Splunk Operator installed successfully"
}

# ====== WAIT FOR CERT-MANAGER WEBHOOK ======
# Ensures cert-manager webhook is responsive before applying resources that
# contain Certificate/Issuer CRs (e.g. artifacts.yaml).
wait_for_cert_manager_webhook() {
  local max_attempts="${1:-30}"
  local sleep_interval="${2:-10}"

  log "Verifying cert-manager webhook is responsive..."

  # 1. Ensure webhook pod is running
  if ! kubectl get namespace cert-manager &>/dev/null; then
    warn "cert-manager namespace not found, skipping webhook check"
    return 0
  fi

  kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/component=webhook \
    -n cert-manager --timeout=120s 2>/dev/null \
    || warn "cert-manager webhook pod may not be fully ready"

  # 2. Ensure webhook endpoint has addresses
  local attempt=0
  while (( attempt < max_attempts )); do
    local webhook_ip
    webhook_ip=$(kubectl -n cert-manager get endpoints cert-manager-webhook \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")

    if [[ -n "${webhook_ip}" ]]; then
      log "cert-manager webhook endpoint: ${webhook_ip}"
      break
    fi

    log "  Waiting for cert-manager webhook endpoint... (${attempt}/${max_attempts})"
    sleep "${sleep_interval}"
    attempt=$((attempt + 1))
  done

  if (( attempt >= max_attempts )); then
    warn "cert-manager webhook endpoint not found after ${max_attempts} attempts"
    return 1
  fi

  # 3. Functional test: create and delete a test Issuer
  local test_ok=false
  for i in $(seq 1 "${max_attempts}"); do
    if kubectl apply -f - <<'TESTEOF' 2>/dev/null
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: cert-manager-webhook-test
  namespace: cert-manager
spec:
  selfSigned: {}
TESTEOF
    then
      kubectl delete issuer cert-manager-webhook-test -n cert-manager \
        --ignore-not-found=true 2>/dev/null || true
      test_ok=true
      log "✓ cert-manager webhook is responsive"
      break
    fi
    log "  cert-manager webhook not yet accepting requests... (${i}/${max_attempts})"
    sleep "${sleep_interval}"
  done

  if [[ "${test_ok}" != "true" ]]; then
    warn "cert-manager webhook did not become responsive after ${max_attempts} attempts"
    return 1
  fi

  return 0
}

# ====== INSTALL SPLUNK AI OPERATOR ======
install_splunk_ai_operator() {
  log "Installing Splunk AI Operator from ${SPLUNK_AI_FILE}..."

  if [[ ! -f "${SPLUNK_AI_FILE}" ]]; then
    warn "Splunk AI Operator file not found: ${SPLUNK_AI_FILE}"
    warn "Please ensure artifacts.yaml exists in the cluster_setup directory"
    return 0
  fi

  # Create namespace for AI Operator
  local ai_operator_ns="splunk-ai-operator-system"
  ensure_namespace "${ai_operator_ns}"

  # Create image pull secrets in operator namespace BEFORE applying manifests
  log "Creating image pull secrets in ${ai_operator_ns} namespace..."
  create_image_pull_secrets "${ai_operator_ns}" >/dev/null 2>&1 || true

  # Ensure cert-manager webhook is ready before applying (artifacts.yaml contains
  # Certificate and Issuer resources that require the webhook to be responsive)
  wait_for_cert_manager_webhook 30 10

  # Apply the artifacts.yaml file (contains CRDs and operator deployment)
  log "Applying Splunk AI Operator manifests..."

  # Use server-side apply with force to ensure all fields are updated including images
  log "Using server-side apply to ensure image URLs are updated..."
  local apply_output
  apply_output=$(kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1) || true
  echo "${apply_output}"

  # Check if any cert-manager resources (Certificate/Issuer) failed due to webhook errors
  if echo "${apply_output}" | grep -qi "webhook.*cert-manager\|failed calling webhook.*cert-manager\|i/o timeout"; then
    warn "Some cert-manager resources failed on first attempt, retrying..."

    # Wait for webhook to stabilize and retry
    sleep 15
    wait_for_cert_manager_webhook 15 10

    log "Retrying full apply for cert-manager resources..."
    kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1 | \
      grep -iE "certificate|issuer|error|warning" || true
  fi

  # Verify that the critical Certificate and Issuer resources exist
  log "Verifying cert-manager resources were created..."
  local cm_retries=0
  local cm_max=12
  while (( cm_retries < cm_max )); do
    local serving_cert
    serving_cert=$(kubectl get certificate splunk-ai-operator-serving-cert \
      -n "${ai_operator_ns}" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

    if [[ -n "${serving_cert}" ]]; then
      log "✓ Certificate 'splunk-ai-operator-serving-cert' exists"
      break
    fi

    log "  Waiting for cert-manager resources to be created... (${cm_retries}/${cm_max})"
    sleep 10
    # Re-apply on each retry to ensure cert-manager resources are processed
    kubectl apply --server-side --force-conflicts -f "${SPLUNK_AI_FILE}" 2>&1 | \
      grep -iE "certificate|issuer" || true
    cm_retries=$((cm_retries + 1))
  done

  if (( cm_retries >= cm_max )); then
    warn "Certificate resources may not have been created — the AI operator webhook may not work"
  fi

  # Specifically ensure ClusterRole is updated (common RBAC update issue).
  # Capture output so we can filter the log but preserve the apply exit code.
  log "Verifying ClusterRole RBAC permissions..."
  local clusterrole_output
  clusterrole_output=$(kubectl apply -f "${SPLUNK_AI_FILE}" --server-side --force-conflicts 2>&1)
  echo "${clusterrole_output}" | grep -i "clusterrole" || true

  # Find the operator deployment
  log "Waiting for Splunk AI Operator deployment..."
  local dep
  dep=$(kubectl -n "${ai_operator_ns}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 -E 'splunk-ai-operator|ai-operator' || echo "")

  if [[ -z "$dep" ]]; then
    warn "Could not detect Splunk AI Operator deployment, checking all deployments..."
    kubectl -n "${ai_operator_ns}" get deploy,po -o wide || true
    # Try to find any deployment with controller-manager in the name
    dep=$(kubectl -n "${ai_operator_ns}" get deploy -o name | grep -i controller || echo "")
  fi

  if [[ -n "$dep" ]]; then
    # Remove 'deployment.apps/' prefix if present
    dep="${dep#deployment.apps/}"
    log "Found deployment: ${dep}"

    # Patch deployment with imagePullSecrets if any exist
    log "Checking for imagePullSecrets to add to operator deployment..."
    local secrets_patch=""
    for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
      if kubectl get secret "${secret_name}" -n "${ai_operator_ns}" &>/dev/null 2>&1; then
        secrets_patch+='{"name":"'"${secret_name}"'"},'
        log "  Found secret: ${secret_name}"
      fi
    done

    if [[ -n "${secrets_patch}" ]]; then
      # Remove trailing comma
      secrets_patch="${secrets_patch%,}"
      log "Patching operator deployment with imagePullSecrets..."
      kubectl -n "${ai_operator_ns}" patch deployment "${dep}" \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":['"${secrets_patch}"']}]' \
        2>/dev/null || log "  imagePullSecrets may already exist or path differs"
    fi

    # Force restart the deployment to pick up new environment variables (image URLs)
    log "Restarting operator deployment to apply updated image configuration..."
    kubectl rollout restart deployment "${dep}" -n "${ai_operator_ns}"

    wait_rollout "${ai_operator_ns}" deploy "${dep}"
  else
    warn "Could not find operator deployment, will wait for CRDs instead"
  fi

  # Wait for CRDs to be available
  log "Waiting for AI Platform CRDs..."
  wait_for_crd aiplatforms.ai.splunk.com 600
  wait_for_crd aiservices.ai.splunk.com 600

  log "Splunk AI Operator ready (ns=${ai_operator_ns}, deploy=${dep:-unknown})"
}

# ====== CREATE MINIO SECRET FOR AI PLATFORM ======
create_minio_secret() {
  local ns="$1"
  ensure_namespace "${ns}"

  log "Creating MinIO credentials secret in ${ns}..."

  kubectl create secret generic minio-credentials \
    --namespace="${ns}" \
    --from-literal=accessKey="${MINIO_ROOT_USER}" \
    --from-literal=secretKey="${MINIO_ROOT_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "MinIO credentials secret created"
  echo "minio-credentials"
}

# ====== SETUP ECR REPOSITORY PERMISSIONS ======
setup_ecr_permissions() {
  local repo_prefix="${1:-ml-platform}"
  # Use ECR_REGION from config, fallback to REGION, then us-east-2
  local ecr_region="${ECR_REGION:-${REGION:-us-east-2}}"

  log "Checking ECR repository permissions for: ${repo_prefix} in region ${ecr_region}..."

  # Check if AWS credentials are available
  if ! aws sts get-caller-identity &>/dev/null; then
    warn "AWS credentials not available - skipping ECR setup"
    return 0
  fi

  local current_account
  current_account=$(aws sts get-caller-identity --query Account --output text)
  log "Current AWS Account: ${current_account}"

  # List repositories matching prefix
  local repos
  repos=$(aws ecr describe-repositories --region "${ecr_region}" 2>/dev/null | \
    jq -r --arg prefix "${repo_prefix}" '.repositories[] | select(.repositoryName | startswith($prefix)) | .repositoryName' || echo "")

  if [[ -z "${repos}" ]]; then
    warn "No ECR repositories found with prefix: ${repo_prefix}"
    log "You may need to:"
    log "  1. Create ECR repositories for AI Platform images"
    log "  2. Push images to ECR"
    log "  3. Grant pull permissions to this account (${current_account})"
    return 0
  fi

  log "Found ECR repositories:"
  echo "${repos}" | sed 's/^/  - /'

  # For each repository, ensure pull permissions are granted
  for repo in ${repos}; do
    log "Checking permissions for repository: ${repo}"

    # Get current policy
    local policy
    policy=$(aws ecr get-repository-policy --repository-name "${repo}" --region "${ecr_region}" 2>/dev/null | jq -r '.policyText' || echo "")

    if [[ -z "${policy}" ]]; then
      log "  No policy found, creating one to allow pull access..."

      # Create policy allowing pull from this account
      cat > "/tmp/ecr-policy-${repo//\//-}.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPull",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${current_account}:root"
      },
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ]
    }
  ]
}
EOF

      if aws ecr set-repository-policy \
        --repository-name "${repo}" \
        --region "${ecr_region}" \
        --policy-text "file:///tmp/ecr-policy-${repo//\//-}.json" &>/dev/null; then
        log "  ✓ Pull permissions granted for repository: ${repo}"
      else
        warn "  Could not set policy for repository: ${repo}"
      fi

      rm -f "/tmp/ecr-policy-${repo//\//-}.json"
    else
      log "  ✓ Repository policy already exists"
    fi
  done

  log "ECR repository permissions configured"
}

# ====== CREATE IMAGE PULL SECRETS FROM CONFIG ======
create_image_pull_secrets() {
  local ns="$1"
  ensure_namespace "${ns}"

  log "============================================"
  log "Creating Image Pull Secrets from Config"
  log "============================================"

  local secrets_created=()

  # 1. Create ECR secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_ECR_ENABLED}" == "true" ]]; then
    log "Creating ECR secret..."
    # Use ECR_REGION from config, fallback to REGION, then us-east-2
    local ecr_region="${ECR_REGION:-${REGION:-us-east-2}}"
    local ecr_account="${ECR_ACCOUNT:-}"
    log "  ECR Region: ${ecr_region}, ECR Account: ${ecr_account}"

    # Check if AWS credentials are available
    if ! aws sts get-caller-identity &>/dev/null; then
      warn "AWS credentials not available - skipping ECR secret creation"
    else
      # Auto-detect ECR account if not provided
      if [[ -z "${ecr_account}" ]]; then
        ecr_account=$(aws sts get-caller-identity --query Account --output text)
        log "Auto-detected ECR account: ${ecr_account}"
      fi

      # Get ECR authorization token
      local ecr_password
      if ecr_password=$(aws ecr get-login-password --region "${ecr_region}" 2>/dev/null); then
        # Create docker-registry secret
        kubectl create secret docker-registry ecr-registry-secret \
          --docker-server="${ecr_account}.dkr.ecr.${ecr_region}.amazonaws.com" \
          --docker-username=AWS \
          --docker-password="${ecr_password}" \
          --namespace="${ns}" \
          --dry-run=client -o yaml | kubectl apply -f -

        log "✓ ECR secret created: ecr-registry-secret"
        secrets_created+=("ecr-registry-secret")
      else
        warn "Failed to get ECR token - skipping ECR secret"
      fi
    fi
  fi

  # 2. Create Docker Hub secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED}" == "true" ]]; then
    log "Creating Docker Hub secret..."
    local dh_username=$(yq eval '.imagePullSecrets.dockerHub.username' "${CONFIG_FILE}" 2>/dev/null)
    local dh_password=$(yq eval '.imagePullSecrets.dockerHub.password' "${CONFIG_FILE}" 2>/dev/null)
    local dh_email=$(yq eval '.imagePullSecrets.dockerHub.email' "${CONFIG_FILE}" 2>/dev/null)

    if [[ -n "${dh_username}" && -n "${dh_password}" ]]; then
      local email_arg=""
      [[ -n "${dh_email}" ]] && email_arg="--docker-email=${dh_email}"

      kubectl create secret docker-registry docker-hub-secret \
        --docker-server=docker.io \
        --docker-username="${dh_username}" \
        --docker-password="${dh_password}" \
        ${email_arg} \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -

      log "✓ Docker Hub secret created: docker-hub-secret"
      secrets_created+=("docker-hub-secret")
    else
      warn "Docker Hub credentials not configured - skipping Docker Hub secret"
    fi
  fi

  # 3. Create GCR secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_GCR_ENABLED}" == "true" ]]; then
    log "Creating GCR secret..."
    local gcr_json_key=$(yq eval '.imagePullSecrets.gcr.jsonKey' "${CONFIG_FILE}" 2>/dev/null)

    if [[ -n "${gcr_json_key}" && "${gcr_json_key}" != "null" ]]; then
      kubectl create secret docker-registry gcr-secret \
        --docker-server=gcr.io \
        --docker-username=_json_key \
        --docker-password="${gcr_json_key}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -

      log "✓ GCR secret created: gcr-secret"
      secrets_created+=("gcr-secret")
    else
      warn "GCR JSON key not configured - skipping GCR secret"
    fi
  fi

  # 4. Create ACR secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_ACR_ENABLED}" == "true" ]]; then
    log "Creating ACR secret..."
    local acr_registry=$(yq eval '.imagePullSecrets.acr.registry' "${CONFIG_FILE}" 2>/dev/null)
    local acr_username=$(yq eval '.imagePullSecrets.acr.username' "${CONFIG_FILE}" 2>/dev/null)
    local acr_password=$(yq eval '.imagePullSecrets.acr.password' "${CONFIG_FILE}" 2>/dev/null)

    if [[ -n "${acr_registry}" && -n "${acr_username}" && -n "${acr_password}" ]]; then
      kubectl create secret docker-registry acr-secret \
        --docker-server="${acr_registry}" \
        --docker-username="${acr_username}" \
        --docker-password="${acr_password}" \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -

      log "✓ ACR secret created: acr-secret"
      secrets_created+=("acr-secret")
    else
      warn "ACR credentials not configured - skipping ACR secret"
    fi
  fi

  # 5. Create custom registry secret if enabled
  if [[ "${IMAGE_PULL_SECRETS_CUSTOM_ENABLED}" == "true" ]]; then
    log "Creating custom registry secret..."
    local custom_name=$(yq eval '.imagePullSecrets.custom.name' "${CONFIG_FILE}" 2>/dev/null)
    local custom_server=$(yq eval '.imagePullSecrets.custom.server' "${CONFIG_FILE}" 2>/dev/null)
    local custom_username=$(yq eval '.imagePullSecrets.custom.username' "${CONFIG_FILE}" 2>/dev/null)
    local custom_password=$(yq eval '.imagePullSecrets.custom.password' "${CONFIG_FILE}" 2>/dev/null)
    local custom_email=$(yq eval '.imagePullSecrets.custom.email' "${CONFIG_FILE}" 2>/dev/null)

    if [[ -n "${custom_server}" && -n "${custom_username}" && -n "${custom_password}" ]]; then
      local email_arg=""
      [[ -n "${custom_email}" ]] && email_arg="--docker-email=${custom_email}"

      kubectl create secret docker-registry "${custom_name}" \
        --docker-server="${custom_server}" \
        --docker-username="${custom_username}" \
        --docker-password="${custom_password}" \
        ${email_arg} \
        --namespace="${ns}" \
        --dry-run=client -o yaml | kubectl apply -f -

      log "✓ Custom registry secret created: ${custom_name}"
      secrets_created+=("${custom_name}")
    else
      warn "Custom registry credentials not configured - skipping custom secret"
    fi
  fi

  # Return created secrets as space-separated string
  if [[ ${#secrets_created[@]} -gt 0 ]]; then
    echo "${secrets_created[@]}"
  fi
}

# ====== CREATE ECR IMAGE PULL SECRET (Legacy - kept for compatibility) ======
create_ecr_secret() {
  local ns="$1"
  # Use ECR_REGION from config, fallback to REGION, then us-east-2
  local region="${ECR_REGION:-${REGION:-us-east-2}}"
  local ecr_account="${ECR_ACCOUNT:-}"

  ensure_namespace "${ns}"

  log "Creating ECR image pull secret in ${ns}..."

  # Check if AWS credentials are available
  if ! aws sts get-caller-identity &>/dev/null; then
    warn "=========================================="
    warn "AWS credentials not available!"
    warn "=========================================="
    warn "Skipping ECR secret creation."
    warn "If AI Platform uses private ECR images, pods will fail to pull images."
    warn ""
    warn "To fix:"
    warn "  1. Configure AWS credentials: aws configure"
    warn "  2. Ensure ECR repository permissions are granted (run setup_ecr_permissions.sh)"
    warn "  3. Re-run the installation"
    warn "=========================================="
    return 0
  fi

  # Auto-detect ECR account if not provided
  if [[ -z "${ecr_account}" ]]; then
    ecr_account=$(aws sts get-caller-identity --query Account --output text)
    log "Auto-detected ECR account: ${ecr_account}"
  fi

  log "Prerequisite: ECR repository permissions must be configured beforehand"
  log "  Run: ./setup_ecr_permissions.sh to set up ECR access"

  # Get ECR authorization token
  log "Getting ECR authorization token for region ${region}..."
  local ecr_password
  if ! ecr_password=$(aws ecr get-login-password --region "${region}" 2>/dev/null); then
    warn "Failed to get ECR token - skipping secret creation"
    warn "Check AWS credentials and permissions"
    return 0
  fi

  # Create docker-registry secret
  kubectl create secret docker-registry ecr-registry-secret \
    --docker-server="${ecr_account}.dkr.ecr.${region}.amazonaws.com" \
    --docker-username=AWS \
    --docker-password="${ecr_password}" \
    --namespace="${ns}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "✓ ECR secret created: ecr-registry-secret"
  log "✓ Secret will be referenced in AIPlatform CR spec.imagePullSecrets"
}

# ====== INSTALL SPLUNK STANDALONE ======
install_splunk_standalone() {
  if [[ "${SPLUNK_MODE}" != "internal" ]]; then
    log "Splunk mode=${SPLUNK_MODE} — skipping Splunk Standalone install (no in-cluster Splunk)"
    return 0
  fi

  log "Installing Splunk Standalone: ${AI_STANDALONE_NAME} in ${AI_NS}..."

  ensure_namespace "${AI_NS}"
  wait_for_crd standalones.enterprise.splunk.com 600

  # Ensure credentials secret exists for Splunk App Framework
  if ! kubectl get secret minio-credentials -n "${AI_NS}" &>/dev/null; then
    log "Creating minio-credentials secret in ${AI_NS}..."
    kubectl -n "${AI_NS}" create secret generic minio-credentials \
      --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
      --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
      --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
      --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
      --from-literal=MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" \
      --from-literal=MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
      --dry-run=client -o yaml | kubectl -n "${AI_NS}" apply -f -
  fi

  # Create splunk-defaults ConfigMap (optional but recommended)
  #
  # issuer_uri becomes the "iss" claim on every interactive JWT Splunk mints.
  # It MUST byte-for-byte match splunkConfiguration.endpoint below (which feeds
  # SPLUNK_ISSUERS on saia/slim) or CMP auth rejects every token with
  # "Issuer '<iss>' is not allowed". Keep both in the
  # https://splunk-<name>-standalone-service.<ns>.svc.<domain>:8089 form used by
  # the operator's own SplunkCustomResourceRef path (buildSplunkIssuersVal).
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
                issuer_uri: https://splunk-${AI_STANDALONE_NAME}-standalone-service.${AI_NS}.svc.cluster.local:8089
                certFile: \$SPLUNK_HOME/etc/auth/server.pem
                sslPassword: password
YAML

  # Ensure default ServiceAccount has imagePullSecrets for ECR
  if kubectl get secret ecr-registry-secret -n "${AI_NS}" &>/dev/null; then
    log "Patching default ServiceAccount with ecr-registry-secret..."
    kubectl patch serviceaccount default -n "${AI_NS}" \
      -p '{"imagePullSecrets": [{"name": "ecr-registry-secret"}]}' 2>/dev/null || \
      warn "Could not patch default ServiceAccount"
  fi

  # Standalone app repo: uses customer-managed S3-compatible object storage.
  #
  # IMPORTANT — unlike the AIPlatform CR (which lets boto3 derive the AWS
  # regional URL from AWS_REGION when endpoint is empty), the Splunk Operator's
  # validateStandaloneSpec hard-requires `endpoint` on every appRepo volume.
  # An empty/missing value yields:
  #     Error  validateStandaloneSpec  validate standalone spec failed
  #            volume Endpoint URI is missing
  # ...and the Standalone goes into PHASE=Error indefinitely (the operator's
  # secret never gets created, breaking the downstream AIPlatform reconcile).
  #
  # For type=aws we therefore synthesise https://s3.<region>.amazonaws.com
  # from cluster.region (which boto3 inside SAIA would have computed anyway).
  # For s3compat/minio/seaweedfs we use the user-provided endpoint as-is —
  # preflight already enforces it's non-empty for those types.
  #
  # NOTE on `provider: aws` vs `storageType: s3`:
  #   These are the Splunk Operator CRD field names; both apply for any
  #   S3-compatible store (MinIO/SeaweedFS/CVFS/real AWS S3) — `aws` is the
  #   provider taxonomy in the Splunk Operator's bucket abstraction, not the
  #   cloud provider. Do not change this even when objectStore.type != aws.
  local minio_endpoint="${MINIO_ENDPOINT:-${OBJ_STORE_ENDPOINT}}"
  if [[ -z "${minio_endpoint}" && "${OBJ_STORE_TYPE}" == "aws" ]]; then
    local aws_region="${REGION:-${ECR_REGION:-us-east-1}}"
    minio_endpoint="https://s3.${aws_region}.amazonaws.com"
    log "type=aws: synthesised Splunk Standalone S3 endpoint = ${minio_endpoint}"
  fi
  if [[ -z "${minio_endpoint}" ]]; then
    err "Splunk Standalone needs a non-empty S3 endpoint; check storage.objectStore.endpoint (or storage.objectStore.type)."
    return 1
  fi
  local endpoint_line="        endpoint: ${minio_endpoint}"

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
${endpoint_line}
        path: ${MINIO_BUCKET}
        secretRef: minio-credentials
YAML

  log "Splunk Standalone CR applied (pod starts in background)"
}

# Blocks until Splunk Standalone pod is ready. Called at the end of the
# install flow so the operator and CR can deploy while Splunk boots.
wait_for_splunk_standalone() {
  if [[ "${SPLUNK_MODE}" != "internal" ]]; then
    return 0
  fi

  log "Waiting for Splunk Standalone to be ready..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=${AI_STANDALONE_NAME} -n ${AI_NS} --timeout=600s || true
  log "Splunk Standalone is ready"
}

# ====== INSTALL AI PLATFORM CR ======
install_ai_platform_cr() {
  log "============================================"
  log "Creating AIPlatform Custom Resource"
  log "============================================"

  # Clean up any failed jobs/pods from previous runs (they may have wrong image references)
  # Use --wait=false to avoid hanging on deletions
  log "Cleaning up failed jobs and ImagePullBackOff pods from previous runs..."
  kubectl delete jobs -n "${AI_NS}" --field-selector status.successful=0 --wait=false 2>/dev/null || true
  kubectl delete pods -n "${AI_NS}" --field-selector status.phase=Failed --wait=false 2>/dev/null || true
  # Delete pods stuck in ImagePullBackOff or ErrImagePull (use jq to avoid bash 3.x jsonpath parsing issues)
  kubectl get pods -n "${AI_NS}" -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.containerStatuses[]? | .state.waiting?.reason? == "ImagePullBackOff") | .metadata.name' 2>/dev/null | \
    xargs -r -I {} kubectl delete pod {} -n "${AI_NS}" --wait=false --grace-period=0 --force 2>/dev/null || true
  kubectl get pods -n "${AI_NS}" -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.containerStatuses[]? | .state.waiting?.reason? == "ErrImagePull") | .metadata.name' 2>/dev/null | \
    xargs -r -I {} kubectl delete pod {} -n "${AI_NS}" --wait=false --grace-period=0 --force 2>/dev/null || true
  log "✓ Cleanup complete"

  # Build trustedIssuers YAML fragment from config (splunk.trustedIssuers[]).
  # Used in all modes: appended to in-cluster issuer (internal) or sole source (external/disabled).
  local trusted_issuers_yaml=""
  local trusted_issuers_count
  trusted_issuers_count=$(yq eval '.splunk.trustedIssuers | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")
  if [[ "${trusted_issuers_count}" -gt 0 ]]; then
    trusted_issuers_yaml="    trustedIssuers:"$'\n'
    local _ti=0
    while [[ $_ti -lt $trusted_issuers_count ]]; do
      local _url
      _url=$(yq eval ".splunk.trustedIssuers[$_ti]" "${CONFIG_FILE}" 2>/dev/null || echo "")
      [[ -n "${_url}" && "${_url}" != "null" ]] && trusted_issuers_yaml+="      - \"${_url}\""$'\n'
      _ti=$((_ti + 1))
    done
  fi

  # Splunk telemetry block for the AIPlatform CR. Rendered by mode:
  #   disabled — omits telemetry fields; trustedIssuers still written if set.
  #   internal — point at the in-cluster Standalone HEC + operator-managed secret.
  #   external — create a Secret (key hec_token) from the SPLUNK_HEC_TOKEN env
  #              var and point at the customer's external HEC endpoint.
  local splunk_config_yaml=""
  case "${SPLUNK_MODE}" in
    internal)
      local splunk_secret="splunk-${AI_STANDALONE_NAME}-standalone-secret-v1"
      log "Using Splunk secret: ${splunk_secret}"
      splunk_config_yaml=$(cat <<EOF

  # Splunk configuration (internal — in-cluster Standalone)
  # Scheme+host here MUST byte-for-byte match the oauth2_settings.issuer_uri
  # set in the splunk-defaults ConfigMap above (install_splunk_standalone) —
  # it becomes the JWT "iss" claim that CMP auth whitelists via SPLUNK_ISSUERS.
  splunkConfiguration:
    endpoint: https://splunk-${AI_STANDALONE_NAME}-standalone-service.${AI_NS}.svc.cluster.local:8089
    secretRef:
      name: ${splunk_secret}
      namespace: ${AI_NS}
${trusted_issuers_yaml}
EOF
)
      ;;
    external)
      # The HEC token comes from the env var only (never the config file). The
      # namespace is guaranteed here (internal mode created it via the Standalone
      # install; external mode skips that, so ensure it now before the Secret).
      ensure_namespace "${AI_NS}"
      if [[ -z "${SPLUNK_HEC_TOKEN}" ]]; then
        err "Splunk external mode requires the HEC token: export SPLUNK_HEC_TOKEN before running the installer."
      fi
      log "Creating external Splunk HEC secret '${SPLUNK_EXTERNAL_SECRET_NAME}' in ${AI_NS} (token from SPLUNK_HEC_TOKEN env)..."
      # --dry-run|apply keeps this idempotent across re-runs. The token value is
      # never echoed; only the secret name is logged.
      kubectl -n "${AI_NS}" create secret generic "${SPLUNK_EXTERNAL_SECRET_NAME}" \
        --from-literal=hec_token="${SPLUNK_HEC_TOKEN}" \
        --dry-run=client -o yaml | kubectl -n "${AI_NS}" apply -f - >/dev/null
      log "✓ External Splunk HEC secret ready: ${SPLUNK_EXTERNAL_SECRET_NAME}"
      log "Using external Splunk HEC endpoint: ${SPLUNK_EXTERNAL_ENDPOINT}"
      splunk_config_yaml=$(cat <<EOF

  # Splunk configuration (external — customer-managed Splunk)
  splunkConfiguration:
    endpoint: ${SPLUNK_EXTERNAL_ENDPOINT}
    secretRef:
      name: ${SPLUNK_EXTERNAL_SECRET_NAME}
      namespace: ${AI_NS}
${trusted_issuers_yaml}
EOF
)
      ;;
    *)
      if [[ -n "${trusted_issuers_yaml}" ]]; then
        log "Splunk telemetry disabled — writing trustedIssuers only (${trusted_issuers_count} issuer(s))"
        splunk_config_yaml=$(cat <<EOF

  # Splunk configuration (disabled — trustedIssuers only for JWT validation)
  splunkConfiguration:
${trusted_issuers_yaml}
EOF
)
      else
        log "Splunk telemetry disabled (splunk.enabled=false) — omitting splunkConfiguration from AIPlatform CR"
      fi
      ;;
  esac

  # Ensure object storage credentials secret exists in AI namespace
  log "Creating/updating S3-compatible credentials secret (minio-credentials) in ${AI_NS}..."
  if object_store_auth_looks_like_placeholder; then
    if kubectl get secret minio-credentials -n "${AI_NS}" &>/dev/null; then
      warn "Skipping minio-credentials apply: auth in ${CONFIG_FILE} still looks like a template (e.g. contains '<'). Preserving existing secret."
    else
      err "minio-credentials missing and cannot be created: fix objectStore.auth in ${CONFIG_FILE} (remove <...> placeholders)."
    fi
  else
    kubectl -n "${AI_NS}" create secret generic minio-credentials \
      --from-literal=AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
      --from-literal=AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
      --from-literal=s3_access_key="${MINIO_ROOT_USER}" \
      --from-literal=s3_secret_key="${MINIO_ROOT_PASSWORD}" \
      --from-literal=MINIO_ACCESS_KEY="${MINIO_ROOT_USER}" \
      --from-literal=MINIO_SECRET_KEY="${MINIO_ROOT_PASSWORD}" \
      --dry-run=client -o yaml | kubectl -n "${AI_NS}" apply -f -
    log "✓ Object storage credentials secret ready"
  fi

  # Build imagePullSecrets YAML from created secrets
  local image_pull_secrets=""
  local secrets_yaml=""

  # Check for all possible secrets and add to YAML if they exist
  for secret_name in ecr-registry-secret docker-hub-secret gcr-secret acr-secret custom-registry-secret; do
    if kubectl get secret "${secret_name}" -n "${AI_NS}" &>/dev/null 2>&1; then
      secrets_yaml+="      - name: ${secret_name}"$'\n'
    fi
  done

  if [[ -n "${secrets_yaml}" ]]; then
    log "ImagePullSecrets found, adding to AIPlatform CR"
    image_pull_secrets=$(cat <<EOF
    imagePullSecrets:
${secrets_yaml}
EOF
)
  else
    log "No imagePullSecrets found, using public images only"
  fi

  # objectStorage: path/endpoint/secret by object store type (aws | minio | seaweedfs).
  # minio and seaweedfs both render as s3compat:// in the CR — classifyObjectStorage()
  # in the operator maps s3compat/minio/seaweedfs schemes identically to cloudProvider=s3compat,
  # and storageclient.go routes all three to NewS3CompatibleClient. Using s3compat:// here
  # keeps the CR uniform regardless of which S3-compatible backend is behind the endpoint.
  local obj_path obj_endpoint obj_secret
  obj_secret="minio-credentials"
  case "${OBJ_STORE_TYPE}" in
    minio|seaweedfs)
      obj_path="minio://${OBJ_STORE_BUCKET}"
      obj_endpoint="${MINIO_ENDPOINT:-${OBJ_STORE_ENDPOINT}}"
      ;;
    aws)
      obj_path="s3://${OBJ_STORE_BUCKET}"
      # Intentionally leave obj_endpoint empty for real AWS S3 — boto3 derives
      # the regional URL (s3.<region>.amazonaws.com) from AWS_REGION. Passing
      # the endpoint through into the AIPlatform CR would (a) duplicate the
      # default and risk region drift, (b) trigger the operator's legacy
      # "endpoint non-empty ⇒ s3compat" classification on older operator
      # builds, and (c) prevent later migration to IRSA / EC2 instance-profile
      # credentials (which fail when an explicit endpoint is set without
      # matching AWS_ENDPOINT_URL plumbing). Matches the EKS installer
      # behaviour in eks_cluster_with_stack.sh:2715-2719.
      obj_endpoint=""
      ;;
    *)
      err "Unsupported objectStore.type: ${OBJ_STORE_TYPE}. Supported: aws, minio, seaweedfs"
      ;;
  esac

  # Build SAIA public-Service exposure block.
  # The AIPlatform reconciler copies AIPlatform.spec.serviceTemplate down to
  # each AIService; the SAIA feature reconciler uses it as the spec for the
  # public saia-service.  For on-prem / airgap customers, NodePort is the
  # recommended default (no cloud LB, no cert-manager, browser on VPN can
  # reach any node IP for Pattern-B v2 APIs like /query streaming).
  local svc_template_yaml=""
  local svc_type
  svc_type=$(yq eval '.aiPlatform.serviceTemplate.type // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  if [[ -n "${svc_type}" && "${svc_type}" != "null" && "${svc_type}" != "ClusterIP" ]]; then
    local svc_node_port
    svc_node_port=$(yq eval '.aiPlatform.serviceTemplate.nodePort // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
    svc_template_yaml="  serviceTemplate:"$'\n'"    spec:"$'\n'"      type: ${svc_type}"$'\n'
    if [[ -n "${svc_node_port}" && "${svc_node_port}" != "null" && "${svc_type}" == "NodePort" ]]; then
      svc_template_yaml+="      ports:"$'\n'"      - name: http"$'\n'"        port: 8080"$'\n'"        targetPort: 8080"$'\n'"        nodePort: ${svc_node_port}"$'\n'
    fi
    log "SAIA public exposure: ${svc_type}${svc_node_port:+ (nodePort=${svc_node_port})}"
  fi

  # Build features YAML from config file (reads aiPlatform.features[] array)
  local features_yaml=""
  local feature_count
  feature_count=$(yq eval '.aiPlatform.features | length' "${CONFIG_FILE}" 2>/dev/null || echo "0")

  if [[ "${feature_count}" -gt 0 ]]; then
    log "Reading ${feature_count} feature(s) from config..."
    local i=0
    while [[ $i -lt $feature_count ]]; do
      local fname fver fsa
      fname=$(yq eval ".aiPlatform.features[$i].name" "${CONFIG_FILE}" 2>/dev/null || echo "")
      fver=$(yq eval ".aiPlatform.features[$i].version // \"1.0.0\"" "${CONFIG_FILE}" 2>/dev/null || echo "1.0.0")
      fsa=$(yq eval ".aiPlatform.features[$i].serviceAccountName // \"\"" "${CONFIG_FILE}" 2>/dev/null || echo "")
      if [[ -n "$fname" && "$fname" != "null" ]]; then
        features_yaml+="    - name: ${fname}"$'\n'
        features_yaml+="      version: \"${fver}\""$'\n'
        [[ -n "$fsa" && "$fsa" != "null" ]] && features_yaml+="      serviceAccountName: ${fsa}"$'\n'
        log "  Feature: ${fname} v${fver}"
      fi
      i=$((i + 1))
    done
  else
    log "No features in config — defaulting to saia"
    features_yaml="    - name: saia"$'\n'"      version: \"1.1.0\""$'\n'
  fi

  # Apply AIPlatform CR (matching EKS script pattern)
  log "Applying AIPlatform CR: ${CLUSTER_NAME}-ai-platform"
  cat <<YAML | kubectl -n "${AI_NS}" apply --server-side --force-conflicts -f -
apiVersion: ai.splunk.com/v1
kind: AIPlatform
metadata:
  name: ${CLUSTER_NAME}-ai-platform
spec:
  objectStorage:
    path: ${obj_path}
    region: ${REGION:-${ECR_REGION:-us-east-1}}
    $( [[ -n "$obj_endpoint" ]] && echo "endpoint: \"${obj_endpoint}\"" )
    $( [[ -n "$obj_secret" ]] && echo "secretRef: ${obj_secret}" )

  # Image configuration (including pull secrets for private registries)
  images:
${image_pull_secrets}

  # GPU accelerator type (determines Ray worker tiers: L40S or empty for no workers)
  defaultAcceleratorType: ${DEFAULT_ACCELERATOR}

  # Features from config (aiPlatform.features)
  features:
${features_yaml}
${svc_template_yaml}
  # Storage configuration
  storage:
    vectorDB:
      size: ${VECTORDB_SIZE}
      storageClassName: ${STORAGE_CLASS}

  # Worker configuration
  workerGroupConfig:
    imageRegistry: "${WORKER_IMAGE_REGISTRY}"

  # CPU scheduler
  cpuScheduler:
    nodeSelector:
      splunk.ai/workload-type: cpu
    tolerations: []

  # GPU scheduler
  gpuScheduler:
    nodeSelector:
      splunk.ai/workload-type: gpu
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "true"
        effect: "NoSchedule"
${splunk_config_yaml}
YAML

  log "AIPlatform CR created successfully"
  log "Waiting for AIPlatform to be ready..."

  # Wait for AIPlatform resource to exist
  local timeout=60 elapsed=0
  while ! kubectl get aiplatform ${CLUSTER_NAME}-ai-platform -n ${AI_NS} >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${timeout} ]]; then
      warn "Timeout waiting for AIPlatform resource to be created"
      break
    fi
  done

  # Show AIPlatform status
  log "AIPlatform status:"
  kubectl get aiplatform ${CLUSTER_NAME}-ai-platform -n ${AI_NS} -o wide || true

  log "AIPlatform CR installed successfully"
}

saia_service_template_enabled_k0s() {
  local svc_type
  svc_type=$(yq eval '.aiPlatform.serviceTemplate.type // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  [[ -n "${svc_type}" && "${svc_type}" != "null" && "${svc_type}" != "ClusterIP" ]]
}

# True when SAIA public Service is explicitly NodePort. MetalLB is not used in
# that mode, so install_metallb skips the Helm install even if metallb.install=true.
k0s_saia_service_template_is_nodeport() {
  local svc_type
  svc_type=$(yq eval '.aiPlatform.serviceTemplate.type // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  [[ "${svc_type}" == "NodePort" ]]
}

wait_for_k0s_aiservice_exists() {
  local name="$1" timeout="${2:-600}" waited=0
  while ! kubectl -n "${AI_NS}" get aiservice "${name}" >/dev/null 2>&1; do
    [[ $waited -ge $timeout ]] && err "Timed out waiting for AIService ${AI_NS}/${name}"
    sleep 5
    waited=$((waited + 5))
  done
}

apply_k0s_saia_service_annotations() {
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

# ---------- MetalLB (k0s LoadBalancer provider) ----------
# k0s ships without a Service.type=LoadBalancer provider. MetalLB fills that
# gap by allocating a VIP from a customer-provided pool and announcing it via
# Layer-2 (ARP/NDP) or BGP. We pin the chart version for supply-chain
# reproducibility (codeguard-0-supply-chain-security).

metallb_enabled_k0s() {
  local v
  v="$(yq eval '.metallb.install // false' "${CONFIG_FILE}" 2>/dev/null || echo false)"
  [[ "${v}" == "true" ]]
}

install_metallb() {
  metallb_enabled_k0s || { log "metallb.install != true — skipping MetalLB install"; return 0; }

  if k0s_saia_service_template_is_nodeport; then
    log "Skipping MetalLB install: aiPlatform.serviceTemplate.type=NodePort (LoadBalancer provider not used for SAIA)."
    log "NOTE: metallb.install=true has no effect while SAIA uses NodePort. Set metallb.install=false to match config, or use type=LoadBalancer to install MetalLB."
    return 0
  fi

  local ns chart_version pool_name addr_count mode
  ns="$(yq eval '.metallb.namespace // "metallb-system"' "${CONFIG_FILE}" 2>/dev/null)"
  chart_version="$(yq eval '.metallb.chartVersion // "0.14.8"' "${CONFIG_FILE}" 2>/dev/null)"
  pool_name="$(yq eval '.metallb.pool.name // "saia-pool"' "${CONFIG_FILE}" 2>/dev/null)"
  addr_count="$(yq eval '.metallb.pool.addresses // [] | length' "${CONFIG_FILE}" 2>/dev/null || echo 0)"
  mode="$(yq eval '.metallb.mode // "layer2"' "${CONFIG_FILE}" 2>/dev/null)"

  if [[ "${addr_count}" == "0" ]]; then
    err "metallb.install=true but metallb.pool.addresses is empty. Provide at least one IP range routable on your network."
  fi
  if [[ "${mode}" != "layer2" && "${mode}" != "bgp" ]]; then
    err "metallb.mode must be 'layer2' or 'bgp' (got: ${mode})."
  fi

  log "Installing MetalLB ${chart_version} into namespace ${ns}..."
  local metallb_chart_ref
  if [[ -n "${METALLB_CHART_PATH:-}" && -f "${METALLB_CHART_PATH}" ]]; then
    metallb_chart_ref="${METALLB_CHART_PATH}"
    log "  Using local chart: ${metallb_chart_ref}"
  else
    helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true
    metallb_chart_ref="metallb/metallb"
  fi

  kubectl get ns "${ns}" >/dev/null 2>&1 || kubectl create ns "${ns}"

  helm upgrade --install metallb "${metallb_chart_ref}" \
    --namespace "${ns}" \
    --version "${chart_version}" \
    --wait --timeout 5m

  # Wait for the controller webhook to be Ready before applying CRs, otherwise
  # the IPAddressPool / L2Advertisement applies race the validating webhook.
  log "Waiting for MetalLB controller to be ready..."
  kubectl -n "${ns}" rollout status deploy/metallb-controller --timeout=180s

  # Render IPAddressPool with the configured address ranges.
  local addresses_yaml=""
  local i
  local pool_count
  pool_count="$(yq eval '.metallb.pool.addresses | length' "${CONFIG_FILE}" 2>/dev/null || echo 0)"
  for ((i=0; i<pool_count; i++)); do
    local addr
    addr="$(yq eval ".metallb.pool.addresses[${i}]" "${CONFIG_FILE}" 2>/dev/null)"
    [[ -z "${addr}" || "${addr}" == "null" ]] && continue
    addresses_yaml+="    - ${addr}"$'\n'
  done

  log "Applying MetalLB IPAddressPool '${pool_name}' (${addr_count} range(s))..."
  cat <<YAML | kubectl -n "${ns}" apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${pool_name}
  namespace: ${ns}
spec:
  addresses:
${addresses_yaml}
YAML

  if [[ "${mode}" == "layer2" ]]; then
    log "Applying MetalLB L2Advertisement for pool '${pool_name}'..."
    cat <<YAML | kubectl -n "${ns}" apply -f -
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${pool_name}-l2
  namespace: ${ns}
spec:
  ipAddressPools:
    - ${pool_name}
YAML
  else
    # BGP mode — render BGPPeers from config and attach a BGPAdvertisement.
    local peer_count
    peer_count="$(yq eval '.metallb.bgpPeers // [] | length' "${CONFIG_FILE}" 2>/dev/null || echo 0)"
    if [[ "${peer_count}" == "0" ]]; then
      err "metallb.mode=bgp requires metallb.bgpPeers to be non-empty (peerAddress, peerASN, myASN per peer)."
    fi
    local p
    for ((p=0; p<peer_count; p++)); do
      local peer_addr peer_asn my_asn
      peer_addr="$(yq eval ".metallb.bgpPeers[${p}].peerAddress" "${CONFIG_FILE}" 2>/dev/null)"
      peer_asn="$(yq eval ".metallb.bgpPeers[${p}].peerASN" "${CONFIG_FILE}" 2>/dev/null)"
      my_asn="$(yq eval ".metallb.bgpPeers[${p}].myASN" "${CONFIG_FILE}" 2>/dev/null)"
      [[ -z "${peer_addr}" || -z "${peer_asn}" || -z "${my_asn}" ]] && \
        err "metallb.bgpPeers[${p}] missing peerAddress / peerASN / myASN."
      cat <<YAML | kubectl -n "${ns}" apply -f -
apiVersion: metallb.io/v1beta1
kind: BGPPeer
metadata:
  name: bgp-peer-${p}
  namespace: ${ns}
spec:
  peerAddress: ${peer_addr}
  peerASN: ${peer_asn}
  myASN: ${my_asn}
YAML
    done
    cat <<YAML | kubectl -n "${ns}" apply -f -
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: ${pool_name}-bgp
  namespace: ${ns}
spec:
  ipAddressPools:
    - ${pool_name}
YAML
  fi

  log "✓ MetalLB ${chart_version} installed (${mode}, pool=${pool_name})"
}

# Disable kube-proxy NodePort allocation on the rendered SAIA Service so
# kube-proxy never opens 30000-32767 on workers. The operator's
# reconcileSAIAService only mutates Selector/Ports on existing Services
# (pkg/ai/features/saia/impl.go), so this patch survives subsequent
# reconciles. externalTrafficPolicy=Local preserves the real client IP for
# MetalLB-style L4 providers (the announcing node forwards directly to a
# local pod with no SNAT).
patch_k0s_saia_service_disable_nodeport() {
  local platform_name="${CLUSTER_NAME}-ai-platform"
  local aiservice_name="${platform_name}-saia"
  local svc_name="${aiservice_name}-saia-service"

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

patch_k0s_saia_public_service_workaround() {
  local platform_name="${CLUSTER_NAME}-ai-platform"
  local aiservice_name="${platform_name}-saia"
  local public_svc_name="${aiservice_name}-saia-service"
  local svc_type svc_node_port

  svc_type=$(yq eval '.aiPlatform.serviceTemplate.type // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  svc_node_port=$(yq eval '.aiPlatform.serviceTemplate.nodePort // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")

  wait_for_k0s_aiservice_exists "${aiservice_name}"

  if saia_service_template_enabled_k0s; then
    log "Patching AIService/${aiservice_name} with SAIA public exposure settings (type=${svc_type})..."
    if [[ "${svc_type}" == "NodePort" && -n "${svc_node_port}" && "${svc_node_port}" != "null" ]]; then
      log "SAIA exposed via NodePort ${svc_node_port} — reach it at http://<worker-ip>:${svc_node_port} (front with a cloud LB on cloud VMs). For bare-metal L2 LANs you may alternatively use type=LoadBalancer with metallb.install=true; MetalLB is skipped automatically under NodePort." >&2
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
            \"nodePort\": ${svc_node_port}
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
        \"type\": \"${svc_type}\"
      }
    }
  }
}"
    fi
  fi

  apply_k0s_saia_service_annotations "${aiservice_name}"

  kubectl -n "${AI_NS}" annotate aiservice "${aiservice_name}" script-reconcile-ts="$(date +%s)" --overwrite >/dev/null

  if saia_service_template_enabled_k0s; then
    log "Recreating SAIA public Service to ensure patched settings take effect..."
    kubectl -n "${AI_NS}" delete svc "${public_svc_name}" --ignore-not-found >/dev/null 2>&1 || true
    # Wait briefly for the operator to recreate it before patching NodePort
    # allocation off; if it doesn't come back the patch will be a no-op.
    local waited=0
    while ! kubectl -n "${AI_NS}" get svc "${public_svc_name}" >/dev/null 2>&1; do
      [[ ${waited} -ge 300 ]] && break
      sleep 5
      waited=$((waited + 5))
    done
  fi

  patch_k0s_saia_service_disable_nodeport
}

# True when the "slim" feature is present in aiPlatform.features[]. slim has no
# v1/v2/nginx split, so its public Service is just <platform>-slim-slim-service.
k0s_slim_feature_enabled() {
  local names
  names=$(yq eval '.aiPlatform.features[].name // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  while IFS= read -r n; do
    [[ "${n}" == "slim" ]] && return 0
  done <<< "${names}"
  return 1
}

# Expose the slim public Service the same way SAIA is exposed, but on a DISTINCT
# NodePort (aiPlatform.serviceTemplate.slimNodePort, default 30081). This is
# required because the AIPlatform reconciler copies AIPlatform.spec.serviceTemplate
# down to EVERY feature's AIService verbatim, so slim would otherwise inherit
# SAIA's nodePort (30080) and collide — a single NodePort can back only one
# Service. We patch slim's own AIService.spec.serviceTemplate after it exists;
# reconcileSlimService only mutates Selector/Ports on the existing Service and
# the AIPlatform reconciler preserves an admin-patched serviceTemplate
# (pkg/ai/reconciler.go), so this patch survives subsequent reconciles.
patch_k0s_slim_public_service_workaround() {
  k0s_slim_feature_enabled || return 0

  local platform_name="${CLUSTER_NAME}-ai-platform"
  local aiservice_name="${platform_name}-slim"
  local public_svc_name="${aiservice_name}-slim-service"
  local svc_type svc_node_port slim_node_port

  svc_type=$(yq eval '.aiPlatform.serviceTemplate.type // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  svc_node_port=$(yq eval '.aiPlatform.serviceTemplate.nodePort // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  # slimNodePort keeps slim off SAIA's port; fall back to nodePort+1 if unset so
  # a config that only sets one shared nodePort still avoids a hard collision.
  slim_node_port=$(yq eval '.aiPlatform.serviceTemplate.slimNodePort // ""' "${CONFIG_FILE}" 2>/dev/null || echo "")
  if [[ ( -z "${slim_node_port}" || "${slim_node_port}" == "null" ) && -n "${svc_node_port}" && "${svc_node_port}" != "null" ]]; then
    slim_node_port=$((svc_node_port + 1))
  fi

  wait_for_k0s_aiservice_exists "${aiservice_name}"

  if saia_service_template_enabled_k0s; then
    log "Patching AIService/${aiservice_name} with slim public exposure settings (type=${svc_type})..."
    if [[ "${svc_type}" == "NodePort" && -n "${slim_node_port}" && "${slim_node_port}" != "null" ]]; then
      log "slim exposed via NodePort ${slim_node_port} — reach it at http://<worker-ip>:${slim_node_port} (front with a cloud LB on cloud VMs). Distinct from SAIA's ${svc_node_port} to avoid a NodePort collision." >&2
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
            \"nodePort\": ${slim_node_port}
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
        \"type\": \"${svc_type}\"
      }
    }
  }
}"
    fi
  fi

  apply_k0s_saia_service_annotations "${aiservice_name}"

  kubectl -n "${AI_NS}" annotate aiservice "${aiservice_name}" script-reconcile-ts="$(date +%s)" --overwrite >/dev/null

  if saia_service_template_enabled_k0s; then
    log "Recreating slim public Service to ensure patched settings take effect..."
    kubectl -n "${AI_NS}" delete svc "${public_svc_name}" --ignore-not-found >/dev/null 2>&1 || true
    # Wait briefly for the operator to recreate it before moving on; if it
    # doesn't come back in time the next reconcile will render it anyway.
    local waited=0
    while ! kubectl -n "${AI_NS}" get svc "${public_svc_name}" >/dev/null 2>&1; do
      [[ ${waited} -ge 300 ]] && break
      sleep 5
      waited=$((waited + 5))
    done
  fi
}

# ====== INSTALL FULL STACK ======
install_ai_platform_stack() {
  log "Installing complete AI Platform stack..."

  ensure_namespace "${AI_NS}"

  # --- Phase 1: Independent infrastructure (parallel) ---
  log "Phase 1: Installing independent infrastructure components in parallel..."
  local phase1_pids=() phase1_names=() phase1_logdir
  phase1_logdir=$(mktemp -d)

  install_cert_manager > "${phase1_logdir}/cert-manager.log" 2>&1 &
  phase1_pids+=($!); phase1_names+=("cert-manager")

  install_kube_prometheus > "${phase1_logdir}/kube-prometheus.log" 2>&1 &
  phase1_pids+=($!); phase1_names+=("kube-prometheus")

  install_nvidia_host_drivers > "${phase1_logdir}/nvidia-drivers.log" 2>&1 &
  phase1_pids+=($!); phase1_names+=("nvidia-drivers")

  # Track which phase-1 tasks failed. nvidia-drivers failures are fatal:
  # without them the device-plugin crash-loops and the whole GPU stack
  # silently fails. Every other phase-1 task is merely warned on failure.
  local phase1_fatal_failures=0
  for i in "${!phase1_pids[@]}"; do
    if wait "${phase1_pids[$i]}"; then
      log "  ✓ ${phase1_names[$i]} completed"
    else
      warn "  ✗ ${phase1_names[$i]} had issues"
      if [[ "${phase1_names[$i]}" == "nvidia-drivers" ]]; then
        phase1_fatal_failures=$((phase1_fatal_failures + 1))
      fi
    fi
    while IFS= read -r line; do
      log "    [${phase1_names[$i]}] ${line}"
    done < "${phase1_logdir}/${phase1_names[$i]}.log"
  done
  rm -rf "${phase1_logdir}"

  if [[ ${phase1_fatal_failures} -gt 0 ]]; then
    err "NVIDIA driver install failed on at least one GPU node; aborting install.
    Device-plugin pods would otherwise crash-loop with NVML: ERROR_LIBRARY_NOT_FOUND
    and model pods would stay Pending forever. Fix the errors above and re-run."
  fi

  ensure_s3compat_credentials

  # --- Phase 2: cert-manager-dependent components (parallel) ---
  log "Phase 2: Installing cert-manager-dependent components in parallel..."
  local phase2_pids=() phase2_names=() phase2_logdir
  phase2_logdir=$(mktemp -d)

  install_otel_operator_and_contrib_collector > "${phase2_logdir}/otel-operator.log" 2>&1 &
  phase2_pids+=($!); phase2_names+=("otel-operator")

  install_ray_operator > "${phase2_logdir}/ray-operator.log" 2>&1 &
  phase2_pids+=($!); phase2_names+=("ray-operator")

  install_splunk_operator > "${phase2_logdir}/splunk-operator.log" 2>&1 &
  phase2_pids+=($!); phase2_names+=("splunk-operator")

  install_nvidia_device_plugin > "${phase2_logdir}/nvidia-device-plugin.log" 2>&1 &
  phase2_pids+=($!); phase2_names+=("nvidia-device-plugin")

  for i in "${!phase2_pids[@]}"; do
    if wait "${phase2_pids[$i]}"; then
      log "  ✓ ${phase2_names[$i]} completed"
    else
      warn "  ✗ ${phase2_names[$i]} had issues"
    fi
    while IFS= read -r line; do
      log "    [${phase2_names[$i]}] ${line}"
    done < "${phase2_logdir}/${phase2_names[$i]}.log"
  done
  rm -rf "${phase2_logdir}"

  # Create image pull secrets before Splunk Standalone (it uses the default SA which needs ECR creds)
  create_image_pull_secrets "${AI_NS}"

  # Apply Splunk Standalone CR (non-blocking — pod boots in background)
  install_splunk_standalone

  # MetalLB must be installed BEFORE the AIPlatform CR is reconciled — the
  # operator renders a Service.type=LoadBalancer for SAIA and we need a
  # provider in the cluster to allocate a VIP, otherwise the Service is
  # stuck in EXTERNAL-IP=<pending> indefinitely. No-op when
  # metallb.install=false (e.g., user is bringing their own MetalLB or wants
  # ClusterIP only).
  install_metallb

  # Install AI Platform operator and CR while Splunk Standalone boots
  install_splunk_ai_operator
  install_ai_platform_cr
  patch_k0s_saia_public_service_workaround
  # Expose slim on its own NodePort when the feature is enabled (no-op otherwise).
  patch_k0s_slim_public_service_workaround

  # Now wait for Splunk Standalone to be ready (likely already done by now)
  wait_for_splunk_standalone

  log "AI Platform stack installation complete!"
}

# ====== ADVANCED HEALTH CHECKS ======
check_platform_health() {
  log "============================================"
  log "🏥 Running Platform Health Checks..."
  log "============================================"
  log ""

  local health_issues=0

  # Check 1: Cluster nodes
  log "Checking cluster nodes..."
  local not_ready
  # Count nodes whose status is not Ready without relying on grep exit codes.
  # This avoids `set -euo pipefail` aborting the script when all nodes are
  # Ready, while still producing a whitespace-free numeric result.
  not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk 'index($0, " Ready ") == 0 { count++ } END { print count+0 }')
  if [[ "${not_ready}" -gt 0 ]]; then
    warn "Found ${not_ready} node(s) not in Ready state"
    kubectl get nodes
    ((health_issues++))
  else
    log "✅ All nodes are Ready"
  fi
  log ""

  # Check 2: Storage class
  log "Checking storage class..."
  if kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
    log "✅ Default storage class configured"
  else
    warn "No default storage class found"
    kubectl get storageclass
    ((health_issues++))
  fi
  log ""

  # Check 3: Object Storage
  log "Checking object storage configuration..."
  if [[ -n "${OBJ_STORE_ENDPOINT}" ]]; then
    log "✅ Object storage configured: ${OBJ_STORE_TYPE} at ${OBJ_STORE_ENDPOINT} (customer-managed)"
  else
    warn "Object storage endpoint not configured"
    ((health_issues++))
  fi
  log ""

  # Check 4: cert-manager
  log "Checking cert-manager..."
  local cert_manager_ready
  cert_manager_ready=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [[ "${cert_manager_ready}" -ge 3 ]]; then
    log "✅ cert-manager is running (${cert_manager_ready} pods)"
  else
    warn "cert-manager not fully ready (${cert_manager_ready}/3 pods)"
    kubectl get pods -n cert-manager
    ((health_issues++))
  fi
  log ""

  # Check 5: Prometheus stack
  log "Checking kube-prometheus-stack..."
  if kubectl get pods -n monitoring 2>/dev/null | grep -q "Running"; then
    local prom_pods
    prom_pods=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    log "✅ Prometheus stack is running (${prom_pods} pods)"
  else
    warn "Prometheus stack not fully ready"
    kubectl get pods -n monitoring
    ((health_issues++))
  fi
  log ""

  # Check 6: OpenTelemetry Operator
  log "Checking OpenTelemetry Operator..."
  if kubectl get pods -n opentelemetry-operator-system 2>/dev/null | grep -q "Running"; then
    log "✅ OpenTelemetry Operator is running"
  else
    warn "OpenTelemetry Operator not ready"
    kubectl get pods -n opentelemetry-operator-system
    ((health_issues++))
  fi
  log ""

  # Check 7: Ray Operator
  log "Checking KubeRay Operator..."
  if kubectl get pods -n ray-system 2>/dev/null | grep -q "Running"; then
    log "✅ KubeRay Operator is running"
  else
    warn "KubeRay Operator not ready"
    kubectl get pods -n ray-system
    ((health_issues++))
  fi
  log ""

  # Check 8: Splunk AI Operator
  log "Checking Splunk AI Operator..."
  if kubectl get pods -n splunk-ai-operator-system 2>/dev/null | grep -q "Running"; then
    log "✅ Splunk AI Operator is running"
  else
    warn "Splunk AI Operator not ready"
    kubectl get pods -n splunk-ai-operator-system
    ((health_issues++))
  fi
  log ""

  # Check 9: AI Platform namespace
  log "Checking AI Platform namespace (${AI_NS})..."
  if kubectl get namespace "${AI_NS}" >/dev/null 2>&1; then
    local ai_pods
    ai_pods=$(kubectl get pods -n "${AI_NS}" --no-headers 2>/dev/null | wc -l || echo "0")
    log "✅ AI Platform namespace exists (${ai_pods} pods)"
    if [[ "${ai_pods}" -gt 0 ]]; then
      kubectl get pods -n "${AI_NS}"
    fi
  else
    warn "AI Platform namespace not found"
    ((health_issues++))
  fi
  log ""

  # Check 10: AIPlatform CRDs
  log "Checking AI Platform CRDs..."
  if kubectl get crd aiplatforms.ai.splunk.com >/dev/null 2>&1; then
    log "✅ AIPlatform CRD installed"
  else
    warn "AIPlatform CRD not found"
    ((health_issues++))
  fi
  if kubectl get crd aiservices.ai.splunk.com >/dev/null 2>&1; then
    log "✅ AIService CRD installed"
  else
    warn "AIService CRD not found"
    ((health_issues++))
  fi
  log ""

  # Summary
  log "============================================"
  if [[ "${health_issues}" -eq 0 ]]; then
    log "✅ Health Check Summary: All systems operational!"
  else
    warn "⚠️  Health Check Summary: Found ${health_issues} issue(s)"
    warn "Some components may still be starting up. Check logs for details."
  fi
  log "============================================"
  log ""

  return "${health_issues}"
}

# ====== VERIFY ALL PODS ARE HEALTHY ======
# Walks every pod in every namespace AND every workload CR (RayCluster,
# RayService, Splunk Standalone, AIPlatform, AIService) and waits until both
# levels are healthy or the budget expires. For unhealthy pods it captures the
# most recent logs (current and previous container) and emits a tailored
# remediation hint based on the failure mode.
#
# Why CR-level checks: KubeRay creates worker pods only AFTER the head pod
# becomes Running+Ready. Looking only at "current pods" can return success
# in the gap between "head Ready" and "workers created/pulled". The workload
# readiness gate ensures we keep waiting until RayCluster reports
# readyWorkerReplicas >= desiredWorkerReplicas (or RayClusterProvisioned=True
# with all workers up).
#
# Special cases handled:
#   - saia-vector-db-setup-posthook-* pods: ignored if there is at least one
#     newest pod for that owner (Job) in Succeeded/Completed state. These are
#     one-shot setup Jobs that frequently leave older Errored attempts behind
#     after Job-level retries succeed.
#
# Tunables (env vars):
#   POD_HEALTH_STABLE_WAIT    Total settle budget in seconds (default 600).
#   POD_HEALTH_PENDING_GRACE  How long Pending pods are tolerated (default 300).
#   POD_HEALTH_POLL_INTERVAL  Re-check interval while waiting (default 15).
#
# Returns:
#   0 if all pods AND all workload CRs are healthy/Ready; non-zero count of
#   unhealthy pods otherwise.
verify_all_pods_healthy() {
  log "============================================"
  log "🩺 Verifying pod health across all namespaces..."
  log "============================================"
  log ""

  # The default budget (10 minutes) is sized for the typical case: KubeRay
  # creates worker pods only AFTER the head pod becomes Running+Ready, and
  # each worker then has to pull a multi-GB image and register with the
  # head. Splunk Standalone has a similar 2–5 min init.
  # On slow networks or fresh clusters where Ray Serve has lots to download,
  # bump this with POD_HEALTH_STABLE_WAIT (e.g. 1200 for 20 minutes).
  local stable_wait_secs="${POD_HEALTH_STABLE_WAIT:-600}"
  local pending_grace_secs="${POD_HEALTH_PENDING_GRACE:-300}"
  local poll_interval="${POD_HEALTH_POLL_INTERVAL:-15}"
  # Clamp grace ≤ wait. Without this, configuring a short STABLE_WAIT (e.g.
  # 120s for fast feedback during script iteration) while leaving the default
  # 300s grace would silently skip Pending pods at the post-budget walk —
  # producing a false "0 unhealthy" return after the loop timed out. Cap
  # grace so any Pending pod still around when the budget expires is always
  # counted and diagnosed.
  if (( pending_grace_secs > stable_wait_secs )); then
    pending_grace_secs="${stable_wait_secs}"
  fi
  local elapsed=0
  local unhealthy_count=0

  # Globals populated by the pod-summary / workload-readiness helpers below
  # (bash 3.2 has no `local -n`, so we use convention-named globals instead).
  POD_LINES=()
  WORKLOAD_PENDING_REASON=""

  # Allow the platform a stabilisation window before we start failing on pods
  # that are still mid-rollout. The loop exits early on success and only
  # reports failures once the budget is exhausted. We wait for BOTH:
  #   1. No pod is in an unhealthy state, AND
  #   2. CR-level workloads (RayCluster, RayService, Splunk Standalone) report
  #      themselves Ready and have all their expected children present.
  # This is what catches the "head Ray pod is up but workers have not been
  # created/pulled yet" case.
  while (( elapsed <= stable_wait_secs )); do
    if ! _collect_pod_summary; then
      warn "Failed to list pods from cluster"
      return 1
    fi

    local has_unhealthy=0
    local first_unhealthy=""
    local line ns name phase ready reason message owner_kind owner_name waiting terminated restarts created
    for line in "${POD_LINES[@]}"; do
      [[ -z "${line}" ]] && continue
      IFS="${_POD_FS}" read -r ns name phase ready reason message owner_kind owner_name waiting terminated restarts created <<<"${line}"
      if ! _pod_is_healthy "${phase}" "${ready}" "${waiting}" "${terminated}" "${reason}"; then
        if [[ -z "${first_unhealthy}" ]]; then
          first_unhealthy="${ns}/${name} (phase=${phase} ready=${ready} reason=${reason}${waiting:+ waiting=${waiting}}${terminated:+ terminated=${terminated}})"
        fi
        has_unhealthy=1
      fi
    done

    # CR readiness check: returns 0 if every workload CR is Ready and has all
    # expected children, non-zero with a human-readable reason otherwise. The
    # human-readable reason is written to the global WORKLOAD_PENDING_REASON.
    WORKLOAD_PENDING_REASON=""
    local cr_ready=0
    _check_workload_readiness || cr_ready=$?
    local pending_reason="${WORKLOAD_PENDING_REASON}"

    if (( has_unhealthy == 0 )) && (( cr_ready == 0 )); then
      log "✅ All pods are in a healthy state and all workloads (Ray, Splunk, AI Platform) are Ready."
      log "============================================"
      log ""
      return 0
    fi

    if (( elapsed < stable_wait_secs )); then
      local status_msg=""
      if (( has_unhealthy != 0 )); then
        status_msg="${first_unhealthy}"
      fi
      if [[ -n "${pending_reason}" ]]; then
        status_msg="${status_msg:+${status_msg}; }${pending_reason}"
      fi
      log "Still settling (elapsed=${elapsed}s/${stable_wait_secs}s): ${status_msg:-pods/CRs not yet Ready}"
      log "  Re-checking in ${poll_interval}s..."
      sleep "${poll_interval}"
      elapsed=$(( elapsed + poll_interval ))
      continue
    fi
    break
  done

  # Budget exhausted — surface CR-level pending reason once before listing
  # individual pod failures so operators see "RayCluster X has 1/3 workers
  # ready" before the per-pod error dump.
  if [[ -n "${pending_reason}" ]]; then
    warn "⚠️  Workload readiness still incomplete after ${stable_wait_secs}s:"
    while IFS= read -r _r; do
      [[ -z "${_r}" ]] && continue
      warn "    • ${_r}"
    done <<<"${pending_reason}"
    warn ""
  fi

  # ---- Identify "newest Completed posthook" so we can ignore stale errors ----
  # A vector-db setup posthook owner is considered healthy if its newest pod
  # is in Succeeded/Completed phase, even if older retry attempts errored.
  local healthy_posthook_owners=()
  local owner_key
  for line in "${POD_LINES[@]}"; do
    [[ -z "${line}" ]] && continue
    IFS="${_POD_FS}" read -r ns name phase ready reason message owner_kind owner_name waiting terminated restarts created <<<"${line}"
    if [[ "${name}" == saia-vector-db-setup-posthook-* && "${phase}" == "Succeeded" ]]; then
      owner_key="${ns}|${owner_kind}|${owner_name}"
      # Confirm this is the newest pod for this owner. We only need the
      # namespace, name, owner identity, and creation timestamp here — the
      # remaining fields are deliberately read into a single discard variable
      # to keep `read -r` aligned without unused locals.
      local is_newest=1
      local other_line other_ns other_name other_ok other_on other_c _discard
      for other_line in "${POD_LINES[@]}"; do
        [[ -z "${other_line}" ]] && continue
        # Field order matches the jq projection earlier:
        # ns | name | phase | ready | reason | message | owner_kind | owner_name | waiting | terminated | restarts | created
        IFS="${_POD_FS}" read -r other_ns other_name _discard _discard _discard _discard other_ok other_on _discard _discard _discard other_c <<<"${other_line}"
        if [[ "${other_ns}" == "${ns}" && "${other_ok}" == "${owner_kind}" && "${other_on}" == "${owner_name}" && "${other_name}" != "${name}" ]]; then
          if [[ "${other_c}" > "${created}" ]]; then
            is_newest=0
            break
          fi
        fi
      done
      if (( is_newest == 1 )); then
        healthy_posthook_owners+=("${owner_key}")
      fi
    fi
  done

  # ---- Walk unhealthy pods, capture diagnostics, and emit recommendations ----
  for line in "${POD_LINES[@]}"; do
    [[ -z "${line}" ]] && continue
    IFS="${_POD_FS}" read -r ns name phase ready reason message owner_kind owner_name waiting terminated restarts created <<<"${line}"

    if _pod_is_healthy "${phase}" "${ready}" "${waiting}" "${terminated}" "${reason}"; then
      continue
    fi

    # Skip vector-db posthook errors when the newest pod for the same owner
    # already completed successfully (the Job retried and won).
    if [[ "${name}" == saia-vector-db-setup-posthook-* ]]; then
      owner_key="${ns}|${owner_kind}|${owner_name}"
      local is_ignored=0
      local healthy
      for healthy in "${healthy_posthook_owners[@]}"; do
        if [[ "${healthy}" == "${owner_key}" ]]; then
          is_ignored=1
          break
        fi
      done
      if (( is_ignored == 1 )); then
        log "↪︎ Ignoring stale failure on ${ns}/${name} — newest posthook pod for ${owner_kind}/${owner_name} succeeded."
        continue
      fi
    fi

    # Pending pods get a grace window before we emit the verbose
    # diagnostics block (events + logs + recommendation). We DO still count
    # them in unhealthy_count so the return code stays honest — earlier
    # versions of this code skipped both, which under a short STABLE_WAIT
    # could mask genuinely-stuck Pending pods as "0 unhealthy" and produce
    # a false-success return.
    local now_unix created_unix age_secs
    now_unix=$(date -u +%s)
    if [[ -n "${created}" ]]; then
      created_unix=$(_iso_to_unix "${created}")
      age_secs=$(( now_unix - created_unix ))
    else
      age_secs=0
    fi
    local in_pending_grace=0
    if [[ "${phase}" == "Pending" && ${age_secs} -lt ${pending_grace_secs} ]]; then
      in_pending_grace=1
    fi

    unhealthy_count=$((unhealthy_count + 1))

    if (( in_pending_grace == 1 )); then
      # Quiet path: count it, log a one-liner, but skip events/logs/recommendation
      # so the operator isn't drowned in transient "ContainerCreating" noise
      # for pods that just started.
      warn "❌ Unhealthy pod (in grace window): ${ns}/${name} — phase=${phase} age=${age_secs}s (< grace ${pending_grace_secs}s)"
      warn ""
      continue
    fi

    local classification
    classification=$(_classify_pod_failure "${phase}" "${reason}" "${waiting}" "${terminated}" "${message}")

    warn "❌ Unhealthy pod: ${ns}/${name}"
    warn "   Phase=${phase} Ready=${ready} Restarts=${restarts}"
    [[ -n "${reason}" ]]     && warn "   Reason: ${reason}"
    [[ -n "${waiting}" ]]    && warn "   Waiting: ${waiting}"
    [[ -n "${terminated}" ]] && warn "   Terminated: ${terminated}"
    if [[ -n "${message}" ]]; then
      # Keep messages bounded
      warn "   Message: ${message:0:500}"
    fi

    # Recent events for this pod (most actionable signal for scheduling/image issues)
    local events
    events=$(kubectl get events -n "${ns}" --field-selector "involvedObject.name=${name}" \
              --sort-by='.lastTimestamp' -o jsonpath='{range .items[-5:]}{.lastTimestamp} {.type} {.reason}: {.message}{"\n"}{end}' 2>/dev/null || true)
    if [[ -n "${events}" ]]; then
      warn "   Recent events:"
      while IFS= read -r ev_line; do
        [[ -z "${ev_line}" ]] && continue
        warn "     • ${ev_line}"
      done <<<"${events}"
    fi

    # Recent logs — try previous instance first (post-crash), then current
    local logs
    if [[ "${phase}" == "Pending" ]]; then
      logs=""  # No containers started yet
    else
      logs=$(kubectl logs -n "${ns}" "${name}" --all-containers=true --previous --tail=40 2>/dev/null || true)
      if [[ -z "${logs}" ]]; then
        logs=$(kubectl logs -n "${ns}" "${name}" --all-containers=true --tail=40 2>/dev/null || true)
      fi
    fi
    if [[ -n "${logs}" ]]; then
      warn "   Recent logs (tail):"
      while IFS= read -r log_line; do
        [[ -z "${log_line}" ]] && continue
        warn "     | ${log_line}"
      done <<<"${logs}"
    fi

    # Tailored recommendation
    warn "   💡 Recommendation: $(_recommend_for_classification "${classification}" "${ns}" "${name}")"
    warn ""
  done

  log "============================================"
  if (( unhealthy_count == 0 )) && [[ -z "${pending_reason}" ]]; then
    log "✅ Pod Verification Summary: All pods are healthy."
  elif (( unhealthy_count == 0 )); then
    warn "⚠️  Pod Verification Summary: All pods look healthy, but workload CRs above did not report Ready within ${stable_wait_secs}s."
  else
    warn "⚠️  Pod Verification Summary: ${unhealthy_count} pod(s) are unhealthy. See details above."
  fi
  log "============================================"
  log ""

  # Return code rules:
  #   0  → Everything healthy AND every CR Ready.
  #   N  → N unhealthy pods (clamped to 1..254).
  #   255 → Pods look fine but workload CRs (RayCluster/RayService/Splunk/AI)
  #         never reached Ready within the budget — this catches the "Ray head
  #         is up but workers never materialised" case the user asked about.
  if (( unhealthy_count == 0 )) && [[ -z "${pending_reason}" ]]; then
    return 0
  fi
  if (( unhealthy_count == 0 )); then
    return 255  # CR-level not Ready
  fi
  if (( unhealthy_count >= 255 )); then
    return 254  # leave 255 reserved for the CR-only case
  fi
  return "${unhealthy_count}"
}

# Helper: returns 0 if a pod is in a healthy state, 1 otherwise.
_pod_is_healthy() {
  local phase="$1" ready="$2" waiting="$3" terminated="$4" reason="$5"

  # Succeeded Jobs are healthy
  [[ "${phase}" == "Succeeded" ]] && return 0

  # Pending and Failed/Unknown are unhealthy
  case "${phase}" in
    Failed|Unknown|Pending) return 1 ;;
  esac

  # Running but containers stuck waiting/terminated abnormally
  if [[ -n "${waiting}" ]]; then
    case "${waiting}" in
      *CrashLoopBackOff*|*ImagePullBackOff*|*ErrImagePull*|*CreateContainerConfigError*|*CreateContainerError*|*InvalidImageName*|*RegistryUnavailable*|*ErrImageNeverPull*) return 1 ;;
    esac
  fi
  if [[ -n "${terminated}" ]]; then
    case "${terminated}" in
      *Error*|*OOMKilled*|*ContainerCannotRun*|*DeadlineExceeded*) return 1 ;;
    esac
  fi
  if [[ "${reason}" == "NodeLost" || "${reason}" == "Evicted" ]]; then
    return 1
  fi

  # Running with not-all-containers ready
  if [[ "${phase}" == "Running" ]]; then
    local r1="${ready%%/*}"
    local r2="${ready##*/}"
    if [[ -n "${r1}" && -n "${r2}" && "${r1}" != "${r2}" ]]; then
      return 1
    fi
  fi

  return 0
}

# Helper: classifies a pod failure into a small set of buckets that map to
# remediation hints. Output is a single token consumed by _recommend_for_classification.
_classify_pod_failure() {
  local phase="$1" reason="$2" waiting="$3" terminated="$4" message="$5"
  local haystack="${reason} ${waiting} ${terminated} ${message}"

  # Most-specific container-state signals win. Check these first so e.g. a
  # Pending pod with ImagePullBackOff is classified as "image-pull", not the
  # generic "pending-long" bucket below.
  case "${haystack}" in
    *ImagePullBackOff*|*ErrImagePull*|*InvalidImageName*|*ErrImageNeverPull*|*RegistryUnavailable*) echo "image-pull"; return ;;
    *CrashLoopBackOff*)                                                                              echo "crashloop"; return ;;
    *CreateContainerConfigError*|*CreateContainerError*)                                             echo "config-error"; return ;;
    *OOMKilled*)                                                                                     echo "oom"; return ;;
    *Evicted*)                                                                                       echo "evicted"; return ;;
    *NodeLost*)                                                                                      echo "node-lost"; return ;;
    *DeadlineExceeded*)                                                                              echo "deadline"; return ;;
  esac

  # Phase-specific buckets for cases the container-state signal didn't catch.
  case "${phase}:${reason}" in
    Pending:*Unschedulable*|Pending:*FailedScheduling*) echo "unschedulable"; return ;;
  esac

  if [[ "${phase}" == "Pending" ]]; then
    echo "pending-long"; return
  fi
  if [[ "${phase}" == "Failed" ]]; then
    echo "failed"; return
  fi
  echo "not-ready"
}

# Helper: emits a remediation hint for a classification bucket.
_recommend_for_classification() {
  local cls="$1" ns="$2" name="$3"
  case "${cls}" in
    image-pull)
      echo "Image pull failed. Verify the image tag exists and the cluster can reach the registry. \
Check pull secrets ('kubectl get sa default -n ${ns} -o yaml' and 'imagePullSecrets'); for ECR re-run \
the registry login + secret refresh; for air-gapped clusters confirm the image is mirrored. \
Then: kubectl describe pod -n ${ns} ${name}"
      ;;
    crashloop)
      echo "Container is crashing on startup. Inspect the previous-instance logs above for the \
real exception, then check ConfigMap/Secret values, env vars, command/args, missing dependencies, \
or unreachable dependencies (DB, MinIO, Splunk). Run: kubectl logs -n ${ns} ${name} --previous"
      ;;
    config-error)
      echo "Container config is invalid. Most often a missing/renamed Secret or ConfigMap, or a \
key referenced in env/volumeMounts that doesn't exist. Run: kubectl describe pod -n ${ns} ${name} \
and reconcile referenced Secrets/ConfigMaps."
      ;;
    oom)
      echo "Container was OOMKilled. Increase 'resources.limits.memory' on the workload, check for \
memory leaks, and verify node has sufficient capacity. Run: kubectl top pod -n ${ns} ${name}"
      ;;
    evicted)
      echo "Pod was Evicted (node pressure). Free disk/memory on the node, raise pod resource \
requests so it lands on a less-loaded node, and inspect: kubectl describe node <node>"
      ;;
    node-lost)
      echo "Node hosting this pod went away. Check kubelet/k0sworker on that node and re-join if \
needed. Run: kubectl get nodes; sudo systemctl status k0sworker (on the affected host)"
      ;;
    deadline)
      echo "Job/Pod deadline exceeded. Increase 'activeDeadlineSeconds' or fix the underlying \
slow-startup cause; check downstream dependency readiness and retries."
      ;;
    unschedulable)
      echo "Pod cannot be scheduled. Common causes: missing node labels (e.g. nvidia.com/gpu=true), \
taints without matching tolerations, insufficient CPU/memory/GPU, or PVC binding failure. Run: \
kubectl describe pod -n ${ns} ${name} and review the Events at the bottom."
      ;;
    pending-long)
      echo "Pod has been Pending for a long time. Likely PVC not bound (check 'kubectl get pvc -n \
${ns}'), no available node matches scheduling constraints, or image is still pulling. Run: \
kubectl describe pod -n ${ns} ${name}"
      ;;
    failed)
      echo "Pod terminated as Failed. Inspect logs and exit code; for Jobs, raise backoffLimit only \
after fixing the root cause. Run: kubectl logs -n ${ns} ${name} --previous"
      ;;
    not-ready|*)
      echo "Pod is Running but not all containers are Ready. Check readiness probe configuration \
and dependency health. Run: kubectl describe pod -n ${ns} ${name}"
      ;;
  esac
}

# Helper: convert RFC3339/ISO timestamp to unix epoch (Linux + macOS portable).
_iso_to_unix() {
  local ts="$1"
  local out
  if out=$(date -u -d "${ts}" +%s 2>/dev/null); then
    printf '%s' "${out}"; return 0
  fi
  if out=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${ts}" +%s 2>/dev/null); then
    printf '%s' "${out}"; return 0
  fi
  printf '0'
}

# Field separator used between columns in the per-pod summary line. We use
# the ASCII Unit Separator (0x1f) because bash's `read -r` collapses
# consecutive empty fields when IFS is whitespace (including tab), which
# would shift columns whenever a pod has e.g. an empty reason+message.
# Unit Separator is non-whitespace, so empties are preserved.
_POD_FS=$'\x1f'

# Helper: check that every workload-level Custom Resource (RayCluster,
# RayService, Splunk Standalone, AIPlatform, AIService) is Ready and has all
# its expected child pods present.
#
# This catches the case where verify_all_pods_healthy would otherwise return
# success too early — for example, the Ray head pod is Running+Ready but the
# Ray operator has not yet created (or the cluster has not yet pulled images
# for) the worker pods. In that window there are no unhealthy pods, but the
# cluster is decidedly not ready.
#
# Output: writes a newline-separated list of human-readable "still pending"
# reasons to the global `WORKLOAD_PENDING_REASON`. Returns 0 iff the list is
# empty.
#
# Why a global instead of a nameref? bash 3.2 (still shipped on macOS as
# /bin/bash) doesn't support `local -n`, and this script's shebang is
# `#!/bin/bash`. Using a fixed global name avoids both the nameref dependency
# AND the subshell scoping issue that would arise from `var=$(_helper ...)`.
_check_workload_readiness() {
  WORKLOAD_PENDING_REASON=""
  local missing=()

  # Project CR rows for one CRD into a delimited string via jq. On kubectl or
  # jq failure, append a "Could not query …" entry to `missing` so we never
  # silently treat a transient API error as "all good".
  #
  # NOTE: We deliberately avoid `var=$(_helper ...)` style here because that
  # spawns a subshell — the inner function's modifications to the parent's
  # `missing` array would be invisible back in the parent. Instead, helper
  # writes to two outer locals: `_wl_rows` (delimited rows for the caller to
  # parse) and `_wl_err` (set to non-empty if the query failed; appended into
  # `missing` directly).
  _wl_query_crd() {
    local crd="$1" resource="$2" jq_proj="$3"
    _wl_rows=""
    if ! kubectl get crd "${crd}" >/dev/null 2>&1; then
      return 0  # CRD not installed → nothing to check.
    fi
    local raw json_rc jq_rc out
    set +e
    raw=$(kubectl get "${resource}" --all-namespaces -o json 2>&1); json_rc=$?
    set -e
    if (( json_rc != 0 )); then
      missing+=("Could not query ${resource} (kubectl rc=${json_rc}): ${raw:0:200}")
      return 0
    fi
    set +e
    out=$(printf '%s' "${raw}" | jq -r --arg FS "${_POD_FS}" "${jq_proj}" 2>&1); jq_rc=$?
    set -e
    if (( jq_rc != 0 )); then
      missing+=("Could not parse ${resource} status (jq rc=${jq_rc}): ${out:0:200}")
      return 0
    fi
    _wl_rows="${out}"
  }

  # Scrub a string to a non-negative integer for safe arithmetic under
  # `set -euo pipefail`. Anything non-numeric becomes 0.
  _wl_int() {
    local v="${1:-0}"
    [[ "${v}" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "${v}"
  }

  local _wl_rows=""

  # ---- KubeRay: RayClusters ---------------------------------------------------
  # Each RayCluster is considered ready when:
  #   - It exposes a 'ready' state OR a 'RayClusterProvisioned'=True condition.
  #   - readyWorkerReplicas >= desiredWorkerReplicas (so all workers are up).
  # We use jq to project the relevant fields with `// 0` for back-compat with
  # older KubeRay versions that don't surface every field.
  _wl_query_crd rayclusters.ray.io rayclusters '
      .items[]
      | [
          .metadata.namespace,
          .metadata.name,
          (.status.state // ""),
          (.status.desiredWorkerReplicas // 0 | tostring),
          (.status.readyWorkerReplicas // 0 | tostring),
          ([(.status.conditions // [])[] | select(.type=="RayClusterProvisioned") | .status] | first // ""),
          ([(.status.conditions // [])[] | select(.type=="HeadPodReady") | .status] | first // "")
        ]
      | join($FS)
    '
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local rc_ns rc_name rc_state rc_desired rc_ready rc_provisioned rc_head_ready
    IFS="${_POD_FS}" read -r rc_ns rc_name rc_state rc_desired rc_ready rc_provisioned rc_head_ready <<<"${line}"
    rc_desired=$(_wl_int "${rc_desired}")
    rc_ready=$(_wl_int "${rc_ready}")
    local is_ready=0
    if [[ "${rc_state}" == "ready" || "${rc_provisioned}" == "True" ]]; then
      is_ready=1
    fi
    if (( is_ready == 1 )) && (( rc_desired > 0 )) && (( rc_ready >= rc_desired )); then
      :  # Fully Ready.
    elif (( is_ready == 1 )) && (( rc_desired == 0 )); then
      :  # Head-only cluster, no workers expected.
    else
      local why="RayCluster ${rc_ns}/${rc_name}: state=${rc_state:-unknown}"
      [[ -n "${rc_head_ready}" ]] && why+=" headReady=${rc_head_ready}"
      why+=" workers=${rc_ready}/${rc_desired}"
      missing+=("${why}")
    fi
  done <<<"${_wl_rows}"

  # ---- KubeRay: RayServices ---------------------------------------------------
  # A RayService is Ready when its 'Ready' condition is True. KubeRay also
  # reports 'numServeEndpoints' once the serve apps are reachable.
  _wl_query_crd rayservices.ray.io rayservices '
      .items[]
      | [
          .metadata.namespace,
          .metadata.name,
          ([(.status.conditions // [])[] | select(.type=="Ready") | .status] | first // ""),
          ([(.status.conditions // [])[] | select(.type=="UpgradeInProgress") | .status] | first // ""),
          (.status.numServeEndpoints // 0 | tostring)
        ]
      | join($FS)
    '
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local rs_ns rs_name rs_ready rs_upgrading rs_endpoints
    IFS="${_POD_FS}" read -r rs_ns rs_name rs_ready rs_upgrading rs_endpoints <<<"${line}"
    if [[ "${rs_ready}" != "True" ]]; then
      local why="RayService ${rs_ns}/${rs_name}: Ready=${rs_ready:-Unknown}"
      [[ "${rs_upgrading}" == "True" ]] && why+=" (upgrade in progress)"
      why+=" serveEndpoints=${rs_endpoints}"
      missing+=("${why}")
    fi
  done <<<"${_wl_rows}"

  # ---- Splunk Operator: Standalone -------------------------------------------
  # Splunk Operator surfaces .status.phase = "Ready" once the StatefulSet pod
  # has finished its Splunk init container chain. Other phases include
  # 'Pending', 'Updating', 'ScalingUp'.
  _wl_query_crd standalones.enterprise.splunk.com standalones '
      .items[]
      | [
          .metadata.namespace,
          .metadata.name,
          (.status.phase // ""),
          (.spec.replicas // 1 | tostring),
          (.status.readyReplicas // 0 | tostring)
        ]
      | join($FS)
    '
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local sp_ns sp_name sp_phase sp_desired sp_ready
    IFS="${_POD_FS}" read -r sp_ns sp_name sp_phase sp_desired sp_ready <<<"${line}"
    sp_desired=$(_wl_int "${sp_desired}")
    sp_ready=$(_wl_int "${sp_ready}")
    if [[ "${sp_phase}" != "Ready" ]] || (( sp_ready < sp_desired )); then
      missing+=("Splunk Standalone ${sp_ns}/${sp_name}: phase=${sp_phase:-unknown} replicas=${sp_ready}/${sp_desired}")
    fi
  done <<<"${_wl_rows}"

  # ---- AI Platform: AIPlatform / AIService ------------------------------------
  # The Splunk AI Operator surfaces .status.phase = "Ready" or a structured
  # conditions list. We accept either.
  local crd_kind ai_resource
  for crd_kind in aiplatforms.ai.splunk.com aiservices.ai.splunk.com; do
    ai_resource="${crd_kind%%.*}"
    _wl_query_crd "${crd_kind}" "${ai_resource}" '
        .items[]
        | [
            .metadata.namespace,
            .metadata.name,
            (.status.phase // ""),
            ([(.status.conditions // [])[] | select(.type=="Ready") | .status] | first // "")
          ]
        | join($FS)
      '
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      local ai_ns ai_name ai_phase ai_ready
      IFS="${_POD_FS}" read -r ai_ns ai_name ai_phase ai_ready <<<"${line}"
      # If neither phase nor a Ready condition surfaces success, treat as pending.
      if [[ "${ai_phase}" != "Ready" && "${ai_ready}" != "True" ]]; then
        missing+=("${ai_resource} ${ai_ns}/${ai_name}: phase=${ai_phase:-unknown} Ready=${ai_ready:-Unknown}")
      fi
    done <<<"${_wl_rows}"
  done

  if (( ${#missing[@]} > 0 )); then
    # local-scoped IFS so the join doesn't leak out of this function.
    local IFS=$'\n'
    WORKLOAD_PENDING_REASON="${missing[*]}"
    return 1
  fi
  return 0
}

# Helper: populate the global POD_LINES array with one delimited line per pod.
# Layout (matches readers in verify_all_pods_healthy):
#   ns, name, phase, ready/total, reason, message,
#   owner_kind, owner_name, waiting_reasons, terminated_reasons, restarts, created
#
# We use kubectl's JSON output piped through jq (already required by the
# script's preflight) rather than kubectl's go-template engine because:
#   - kubectl's text/template lacks `add`/`replace` helpers we need for
#     restart-count summation and message scrubbing.
#   - jq lets us emit a single, well-formed delimited line per pod.
#
# We write to the global POD_LINES (rather than using `local -n`) because the
# script's shebang is `#!/bin/bash` and macOS still ships bash 3.2 (no
# nameref). Using a fixed global keeps the helper bash-3.2 safe.
_collect_pod_summary() {
  local raw rc

  # We run under `set -euo pipefail`, where a failed command substitution
  # aborts BEFORE the next statement (`rc=$?`) can run. Disable `errexit`
  # for just the kubectl/jq pipeline so we can capture and report the error
  # instead of dying mid-loop. Embedded newlines/tabs/separators in
  # status.message are scrubbed to spaces so each pod stays on one line and
  # never injects our chosen field separator.
  set +e
  raw=$(kubectl get pods --all-namespaces -o json 2>&1 \
        | jq -r --arg FS "${_POD_FS}" '
            .items[]
            | (.status.containerStatuses // []) as $cs
            | [
                .metadata.namespace,
                .metadata.name,
                (.status.phase // "Unknown"),
                (
                  (([$cs[] | select(.ready == true)] | length) | tostring)
                  + "/"
                  + (($cs | length) | tostring)
                ),
                (.status.reason // ""),
                ((.status.message // "") | gsub("[\\n\\t\\u001f]"; " ")),
                ((.metadata.ownerReferences // [])[0].kind // ""),
                ((.metadata.ownerReferences // [])[0].name // ""),
                ([$cs[] | .state.waiting.reason // empty] | join(",")),
                ([$cs[] | .state.terminated.reason // empty] | join(",")),
                ([$cs[] | .restartCount // 0] | add // 0 | tostring),
                (.metadata.creationTimestamp // "")
              ]
            | join($FS)
          ' 2>&1); rc=$?
  set -e
  if (( rc != 0 )); then
    warn "kubectl/jq pod summary failed (rc=${rc}): ${raw:0:300}"
    return 1
  fi

  # Reset and populate the global. Bash 3.2 lacks `local -n`, so we use a
  # fixed global name (POD_LINES) by convention.
  POD_LINES=()
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    POD_LINES+=("${_line}")
  done <<<"${raw}"
  return 0
}

# Print a short, human-friendly summary of unhealthy pods. Designed to be
# called from the post-install banner so the user gets actionable context
# without scrolling back through the full diagnostic output. Reads from the
# global POD_LINES populated during verify_all_pods_healthy; if it's empty
# (e.g. verify ran a long time ago, or kubectl was unavailable) we fall back
# to a single-line `kubectl get pods -A` query so the banner is never silent.
#
# Output format (root-cause pods listed first, transient PodInitializing second):
#   1 root-cause pod(s) need attention:
#     • ai-platform (1):
#         - head-pod [Pending 0/2, ImagePullBackOff]
#
#   5 pod(s) are still initializing (will recover once root-cause pod(s) above are healthy):
#     • ai-platform (5):
#         - gpu-worker-1 [Pending 0/1, PodInitializing]
#         … and 4 more in ai-platform (run: kubectl get pods -n ai-platform)
#
# We deliberately do NOT re-run kubectl by default: the diagnostics above
# the banner already exhausted the freshest information; re-querying here
# would add latency and risk a different snapshot, confusing the operator.

# Helper: print a namespace-bucketed pod list from a delimited-line array.
# Called by _print_unhealthy_pod_summary for both root-cause and downstream sections.
_print_pod_section() {
  local -a lines=("$@")
  local -a ns_keys=() ns_counts=()
  local i found_idx line ns _name _suffix pn _pname _psuffix
  for line in "${lines[@]}"; do
    IFS="${_POD_FS}" read -r ns _name _suffix <<<"${line}"
    found_idx=-1
    for (( i=0; i < ${#ns_keys[@]}; i++ )); do
      [[ "${ns_keys[$i]}" == "${ns}" ]] && { found_idx=$i; break; }
    done
    if (( found_idx == -1 )); then
      ns_keys+=("${ns}"); ns_counts+=(1)
    else
      ns_counts[$found_idx]=$(( ns_counts[found_idx] + 1 ))
    fi
  done
  for (( i=0; i < ${#ns_keys[@]}; i++ )); do
    warn "  • ${ns_keys[$i]} (${ns_counts[$i]}):"
    local printed=0
    local max_per_ns=5  # avoid 200-line banners on truly broken clusters
    for line in "${lines[@]}"; do
      IFS="${_POD_FS}" read -r pn _pname _psuffix <<<"${line}"
      [[ "${pn}" != "${ns_keys[$i]}" ]] && continue
      warn "      - ${_pname} ${_psuffix}"
      printed=$(( printed + 1 ))
      if (( printed >= max_per_ns )); then
        local remaining=$(( ns_counts[i] - printed ))
        (( remaining > 0 )) && warn "      … and ${remaining} more in ${ns_keys[$i]} (run: kubectl get pods -n ${ns_keys[$i]})"
        break
      fi
    done
  done
}

_print_unhealthy_pod_summary() {
  local total=0
  local line ns name phase ready reason message owner_kind owner_name waiting terminated restarts created

  # Use cached POD_LINES if available; otherwise refresh once.
  if (( ${#POD_LINES[@]} == 0 )); then
    _collect_pod_summary || {
      warn "Unable to summarise unhealthy pods: pod listing failed."
      return 0
    }
  fi

  local -a root_cause_lines=() downstream_lines=()
  for line in "${POD_LINES[@]}"; do
    [[ -z "${line}" ]] && continue
    IFS="${_POD_FS}" read -r ns name phase ready reason message owner_kind owner_name waiting terminated restarts created <<<"${line}"
    if ! _pod_is_healthy "${phase}" "${ready}" "${waiting}" "${terminated}" "${reason}"; then
      local suffix="[${phase} ${ready}"
      if [[ -n "${reason}" ]]; then
        suffix+=", ${reason}"
      elif [[ -n "${waiting}" ]]; then
        suffix+=", ${waiting}"
      elif [[ -n "${terminated}" ]]; then
        suffix+=", ${terminated}"
      fi
      suffix+="]"
      # PodInitializing is a transient downstream effect — another pod's failure
      # is blocking this one. Separate it so the operator focuses on root causes.
      if [[ "${waiting}" == "PodInitializing" || "${reason}" == "PodInitializing" ]]; then
        downstream_lines+=("${ns}${_POD_FS}${name}${_POD_FS}${suffix}")
      else
        root_cause_lines+=("${ns}${_POD_FS}${name}${_POD_FS}${suffix}")
        total=$((total + 1))
      fi
    fi
  done

  local downstream_count=${#downstream_lines[@]}

  if (( total == 0 && downstream_count == 0 )); then
    log "✅ All pods are healthy at banner time."
    return 0
  fi

  if (( total > 0 )); then
    warn "${total} root-cause pod(s) need attention:"
    _print_pod_section "${root_cause_lines[@]}"
    warn ""
  fi

  if (( downstream_count > 0 )); then
    if (( total > 0 )); then
      warn "${downstream_count} pod(s) are still initializing (will recover once root-cause pod(s) above are healthy):"
    else
      warn "${downstream_count} pod(s) are still initializing:"
    fi
    _print_pod_section "${downstream_lines[@]}"
    warn ""
  fi

  if (( total > 0 )); then
    warn "Tip: fix the root-cause pod(s) first — initializing pods will recover automatically."
  else
    warn "Tip: pods are still starting up — re-run the verifier in a few minutes."
  fi
  warn "     Scroll up to see per-pod logs, events, and recommended fixes."
}

# ====== SHOW PLATFORM ACCESS INFORMATION ======
show_platform_access_info() {
  # Read VERIFY_RC set by main_install (contract documented there). Use a safe
  # default so this function still works when invoked from contexts that did
  # not run verify_all_pods_healthy (e.g. someone calling
  # `show_platform_access_info` directly from a debug shell).
  local verify_rc="${VERIFY_RC:-0}"
  local banner_status banner_emoji
  if (( verify_rc == 0 )); then
    banner_emoji="🎉"
    banner_status="Installation Complete!"
  elif (( verify_rc == 255 )); then
    banner_emoji="⚠️"
    banner_status="Installation Complete — Workloads Still Initializing"
  else
    banner_emoji="⚠️"
    banner_status="Installation Complete — ${verify_rc} Pod(s) Unhealthy"
  fi

  log "============================================"
  log "${banner_emoji} ${banner_status}"
  log "============================================"
  log ""

  log "📋 Cluster Information:"
  log "  Cluster Name: ${CLUSTER_NAME}"
  log "  Namespace: ${AI_NS}"
  log "  Kubeconfig: ${HOME}/.kube/k0s-${CLUSTER_NAME}"
  log ""
  log "  💡 Set kubeconfig:"
  log "     export KUBECONFIG=${HOME}/.kube/k0s-${CLUSTER_NAME}"
  log ""

  # Show node information
  log "📦 Cluster Nodes:"
  kubectl get nodes -o wide 2>/dev/null || warn "Could not retrieve node information"
  log ""

  # Object storage information
  log "🗄️  Object Storage (customer-managed):"
  log "  Type: ${OBJ_STORE_TYPE}"
  log "  Endpoint: ${OBJ_STORE_ENDPOINT}"
  log "  Bucket: ${OBJ_STORE_BUCKET}"
  log ""

  # AI Platform information
  log "🤖 AI Platform:"
  log "  Check Status:"
  log "     kubectl get aiplatform -n ${AI_NS}"
  log "     kubectl describe aiplatform -n ${AI_NS}"
  log "  "
  log "  Check AIServices:"
  log "     kubectl get aiservice -n ${AI_NS}"
  log ""

  # Splunk information
  log "📊 Splunk Enterprise:"
  log "  Check Status:"
  log "     kubectl get standalone -n ${AI_NS}"
  log "     kubectl get pods -n ${AI_NS} -l app.kubernetes.io/instance=splunk-standalone"
  log "  "
  log "  💡 Access Splunk Web (once ready):"
  log "     kubectl port-forward -n ${AI_NS} svc/splunk-${AI_STANDALONE_NAME}-standalone-service 8000:8000"
  log "     Open: http://localhost:8000"
  log ""

  # Monitoring information
  log "📈 Monitoring & Observability:"
  log "  Prometheus:"
  log "     kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
  log "     Open: http://localhost:9090"
  log "  "
  log "  Grafana:"
  log "     kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
  log "     Open: http://localhost:3000"
  log "     Username: admin"
  log "     Password: (run) kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d"
  log ""

  # Ray information
  log "🚀 Ray Clusters:"
  log "  Check Ray Services:"
  log "     kubectl get rayservice -n ${AI_NS}"
  log "     kubectl get raycluster -n ${AI_NS}"
  log "  "
  log "  Ray Dashboard (once Ray is running):"
  log "     kubectl port-forward -n ${AI_NS} svc/<ray-head-svc> 8265:8265"
  log "     Open: http://localhost:8265"
  log ""

  # Quick checks
  log "🔍 Quick Health Checks:"
  log "  All Pods:"
  log "     kubectl get pods -A"
  log "  "
  log "  AI Platform Pods:"
  log "     kubectl get pods -n ${AI_NS}"
  log "  "
  log "  System Pods:"
  log "     kubectl get pods -n kube-system"
  log ""

  # Troubleshooting
  log "🛠️  Troubleshooting:"
  log "  View Operator Logs:"
  log "     kubectl logs -n splunk-ai-operator-system -l control-plane=controller-manager -f"
  log "  "
  log "  View AI Platform Events:"
  log "     kubectl get events -n ${AI_NS} --sort-by='.lastTimestamp'"
  log "  "
  log "  Describe Resources:"
  log "     kubectl describe aiplatform -n ${AI_NS}"
  log "     kubectl describe aiservice -n ${AI_NS}"
  log ""

  log "============================================"
  log "📚 Documentation:"
  log "  Setup Guide: ./tools/cluster_setup/K0S_README.md"
  log "  Deployment Guide: ./tools/cluster_setup/DEPLOYMENT_GUIDE.md"
  log "  Troubleshooting: ./tools/cluster_setup/TROUBLESHOOTING.md"
  log "  Custom Resources: ./docs/CustomResources.md"
  log "============================================"
  log ""

  # Final status line. We tell the truth: "ready to use" only when every pod
  # AND every workload CR reports healthy. Anything else gets an explicit
  # warning banner with a per-namespace summary so the operator immediately
  # sees what failed without scrolling back through tens of pages of
  # diagnostics.
  if (( verify_rc == 0 )); then
    log "✅ Your AI Platform is ready to use!"
  elif (( verify_rc == 255 )); then
    warn "⚠️  Your AI Platform is partially ready: pods look healthy but one or"
    warn "    more workload-level Custom Resources (RayCluster/RayService/"
    warn "    Splunk Standalone/AIPlatform/AIService) have not yet reported"
    warn "    Ready. This usually clears within a few minutes — re-check with:"
    warn "       kubectl get aiplatform,aiservice,raycluster,rayservice -n ${AI_NS}"
    warn "       kubectl get standalone -n ${AI_NS}"
    warn "    Or re-run just the verifier (no install steps):"
    warn "       CONFIG_FILE=${CONFIG_FILE:-<your-config>} ${0} verify-pods"
  else
    warn "⚠️  Your AI Platform is NOT ready to use yet. Summary:"
    log ""
    _print_unhealthy_pod_summary
    warn "    Re-run the verifier after fixing the issues above:"
    warn "       CONFIG_FILE=${CONFIG_FILE:-<your-config>} ${0} verify-pods"
  fi
  log ""

  # Propagate the verifier's status to callers (sourced contexts) without
  # changing the function-call style. main_install ignores this return; CI
  # wrappers that source the script can read it. We deliberately use 0 vs
  # non-zero here rather than re-encoding the count — the count is already
  # in the banner.
  if (( verify_rc == 0 )); then
    return 0
  else
    return 1
  fi
}

# ====== MAIN INSTALL FLOW ======
main_install() {
  # Sync SILENT_INSTALL ↔ AUTO_APPROVE so both paths are consistent.
  # AUTO_APPROVE=true (legacy CI env var) implies silent; --silent flag sets AUTO_APPROVE
  # so the existing delete/clean-all confirmation gates keep working unchanged.
  [[ "${AUTO_APPROVE:-false}" == "true" ]] && SILENT_INSTALL=true
  SILENT_INSTALL="${SILENT_INSTALL:-false}"
  [[ "${SILENT_INSTALL}" == "true" ]] && AUTO_APPROVE=true

  load_config

  validate_image_config
  resolve_accelerator_type
  configure_images

  resolve_model_staging

  show_install_plan

  phase_start "Preflight"
  step_start "Preflight checks"
  preflight_checks
  step_ok
  phase_end "Preflight"

  phase_start "Model Staging"
  if [[ "${MODEL_STAGING_ENABLED}" == "true" ]]; then
    step_start "Model artifact staging (HuggingFace → object store)"
    log "Model staging enabled — downloading from Hugging Face and uploading to object store…"
    stage_model_artifacts
    step_ok
  else
    step_start "Model artifact staging"
    log "Model staging disabled (storage.modelStaging.enabled=false) — skipping HF download + upload"
    step_skip "modelStaging.enabled=false"
  fi
  phase_end "Model Staging"

  # Check if existing Kubernetes cluster should be used
  local use_existing_cluster=false

  # Respect the useExisting config setting
  if [[ "${USE_EXISTING}" == "never" ]]; then
    log "Config setting 'useExisting=never' - will always create new k0s cluster"
  else
    log "Checking for existing Kubernetes cluster (useExisting=${USE_EXISTING})..."

    # Option 1: Check if KUBECONFIG is set and points to an accessible cluster
    if [[ "${USE_EXISTING}" == "auto" || "${USE_EXISTING}" == "force" ]] && [[ -n "${KUBECONFIG:-}" ]] && timeout 5 kubectl cluster-info &>/dev/null; then

      # Verify the cluster name matches or contains our cluster name
      local current_context
      current_context=$(kubectl config current-context 2>/dev/null || echo "unknown")

      log "Found accessible cluster with context: ${current_context}"

      # Check if context name contains our cluster name (case-insensitive)
      if [[ "${current_context}" == *"${CLUSTER_NAME}"* ]] || [[ "${USE_EXISTING}" == "force" ]]; then
        log "============================================"
        log "✓ Existing Kubernetes cluster detected via KUBECONFIG!"
        log "============================================"
        log "Cluster context: ${current_context}"
        log "Configured cluster name: ${CLUSTER_NAME}"
        log ""
        log "Cluster info:"
        kubectl cluster-info 2>/dev/null | head -5 || true
        log ""
        log "Nodes:"
        kubectl get nodes || true
        log ""
        log "Skipping k0s installation, will use existing cluster"
        use_existing_cluster=true
      else
        warn "Found cluster with context '${current_context}' but it doesn't match configured name '${CLUSTER_NAME}'"
        warn "Set useExisting=force in config to use it anyway, or set KUBECONFIG to the correct cluster"
        if [[ "${USE_EXISTING}" == "force" ]]; then
          err "useExisting=force but cluster name mismatch - aborting for safety"
        fi
      fi

    # Option 2: Check if k0s is already running on provided nodes
    elif [[ "${USE_EXISTING}" == "auto" || "${USE_EXISTING}" == "force" ]] && [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
      IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
      local controller_ip="${CONTROLLER_IPS[0]}"

      log "Checking if k0s is already installed on ${controller_ip}..."
      if ssh_exec "${controller_ip}" "command -v k0s >/dev/null 2>&1 && sudo k0s status >/dev/null 2>&1"; then
        log "============================================"
        log "✓ k0s cluster already running on provided nodes!"
        log "============================================"
        log "Retrieving kubeconfig from existing k0s cluster..."
        mkdir -p "${HOME}/.kube"
        ssh_exec "${controller_ip}" "sudo cat /var/lib/k0s/pki/admin.conf" > "${HOME}/.kube/k0s-${CLUSTER_NAME}"
        sed -i.bak "s|server: .*|server: https://${controller_ip}:6443|" "${HOME}/.kube/k0s-${CLUSTER_NAME}"
        export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"
        log "Cluster nodes:"
        kubectl get nodes || true
        log ""
        log "Skipping k0s installation, using existing cluster"
        use_existing_cluster=true

        # Prepare all nodes for OS compatibility (iptables, firewalld, etc.)
        local all_node_ips=("${CONTROLLER_IPS[@]}")
        if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
          IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
          all_node_ips+=("${WORKER_IPS[@]}")
        fi
        prepare_nodes_for_k0s "${all_node_ips[@]}"

        # Ensure all expected workers are joined
        if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
          local current_node_count
          current_node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
          local expected_total=$(( ${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]} ))
          if [[ "${current_node_count}" -lt "${expected_total}" ]]; then
            log "Cluster has ${current_node_count} nodes but ${expected_total} expected — joining missing workers..."
            join_workers
          fi
        fi
      elif [[ "${USE_EXISTING}" == "force" ]]; then
        err "useExisting=force but no k0s cluster found on provided nodes"
      fi
    fi

    # If force mode and no cluster found, error out
    if [[ "${USE_EXISTING}" == "force" ]] && [[ "${use_existing_cluster}" == "false" ]]; then
      err "useExisting=force but no existing cluster found - aborting"
    fi
  fi

  # Install k0s if no existing cluster found
  if [[ "${use_existing_cluster}" == "false" ]]; then
    log "No existing cluster found, starting k0s cluster installation..."

    # Parse IPs from config
    log "Using existing infrastructure..."
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"

    # Check if k0s is already running on the controller node
    if [[ "${#CONTROLLER_IPS[@]}" -gt 0 ]]; then
      local controller_ip="${CONTROLLER_IPS[0]}"
      log "Checking if k0s is already installed on ${controller_ip}..."

      if ssh_exec "${controller_ip}" "command -v k0s >/dev/null 2>&1 && sudo k0s status >/dev/null 2>&1"; then
        log "============================================"
        log "✓ k0s cluster already running on existing nodes!"
        log "============================================"
        log "Retrieving kubeconfig from existing k0s cluster..."
        mkdir -p "${HOME}/.kube"
        ssh_exec "${controller_ip}" "sudo cat /var/lib/k0s/pki/admin.conf" > "${HOME}/.kube/k0s-${CLUSTER_NAME}"
        sed -i.bak "s|server: .*|server: https://${controller_ip}:6443|" "${HOME}/.kube/k0s-${CLUSTER_NAME}"
        export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"
        log "Cluster nodes:"
        kubectl get nodes || true
        log ""
        log "Skipping k0s installation, using existing cluster"
        use_existing_cluster=true

        # Prepare all nodes for OS compatibility (iptables, firewalld, etc.)
        local all_node_ips2=("${CONTROLLER_IPS[@]}")
        if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
          IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"
          all_node_ips2+=("${WORKER_IPS[@]}")
        fi
        prepare_nodes_for_k0s "${all_node_ips2[@]}"

        # Ensure all expected workers are joined
        if [[ -n "${EXISTING_WORKER_IPS}" ]]; then
          local current_node_count
          current_node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
          local expected_total=$(( ${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]} ))
          if [[ "${current_node_count}" -lt "${expected_total}" ]]; then
            log "Cluster has ${current_node_count} nodes but ${expected_total} expected — joining missing workers..."
            join_workers
          fi
        fi
      fi
    fi

    # Install k0s cluster only if not already installed
    if [[ "${use_existing_cluster}" == "false" ]]; then
      install_k0s_cluster
    fi
  else
    log ""
    log "⚠️  Using existing cluster - please ensure:"
    log "  ✓ Storage class is configured (for MinIO and persistent volumes)"
    log "  ✓ At least 1 node with available CPU/memory resources"
    log "  ✓ GPU nodes labeled with 'nvidia.com/gpu=true' (if running GPU workloads)"
    log "  ✓ If using on-prem/private cluster, ensure ports 6443, 8080, 30000-32767 are accessible"
    log ""
  fi

  # Install AI Platform stack
  phase_start "AI Platform Stack"
  step_start "Install AI Platform stack"
  install_ai_platform_stack
  step_ok
  phase_end "AI Platform Stack"

  # Run health checks
  phase_start "Health Verification"
  step_start "Platform health checks"
  if check_platform_health; then
    step_ok
  else
    step_fail "some components still initializing"
    warn "Some components may still be initializing"
  fi

  # Verify every pod across every namespace, capture diagnostics for failures,
  # and emit targeted recommendations. Treats stale saia-vector-db-setup-posthook
  # errors as ignorable when the newest posthook pod has Succeeded.
  #
  # The exit code conveys structured information that the post-install banner
  # consumes via VERIFY_RC (see show_platform_access_info):
  #   0       all pods healthy AND all workload CRs Ready
  #   1..254  N pods unhealthy (count is clamped to this range)
  #   255     pods healthy but workload CRs not Ready (e.g. RayService still
  #           initialising). Distinct from "0 unhealthy" so the banner can
  #           remain honest even when no individual pod is failing.
  step_start "Pod health verification"
  VERIFY_RC=0
  verify_all_pods_healthy || VERIFY_RC=$?
  if (( VERIFY_RC != 0 )); then
    step_fail "${VERIFY_RC} pod(s)/CR(s) not ready — see diagnostics above"
    warn "Some components are not fully ready — see diagnostics above for remediation steps."
    # Auto-collect a support bundle so customers have everything in one file.
    # Set AUTO_DIAGNOSE=false to suppress (e.g. in CI where disk space is tight).
    if [[ "${AUTO_DIAGNOSE:-true}" != "false" ]]; then
      log "Auto-collecting support bundle (set AUTO_DIAGNOSE=false to suppress)..."
      diagnose || true
    fi
  else
    step_ok
  fi
  phase_end "Health Verification"

  show_step_summary

  # Show platform access information. Reads VERIFY_RC to choose between a
  # success banner and a "partially ready" banner with an inline summary.
  #
  # show_platform_access_info itself returns nonzero when VERIFY_RC != 0,
  # which is useful for sourced contexts (CI wrappers can branch on the
  # function's return). But for the install CLI command we deliberately
  # swallow that return — install completing with an actionable warning
  # banner should NOT cause callers chaining via `&&` to silently abort.
  # The banner already tells the operator what's wrong; failing the exit
  # code on top of that just breaks automation.
  show_platform_access_info || true
}

# ====== MAIN DELETE FLOW ======
main_delete() {
  load_config

  log "============================================"
  log "Starting cleanup of k0s cluster: ${CLUSTER_NAME}"
  log "============================================"
  log "  Controllers : ${EXISTING_CONTROLLER_IPS}"
  log "  Workers     : ${EXISTING_WORKER_IPS:-none}"
  log "  Namespace   : ${AI_NS}"
  log "============================================"
  log ""
  warn "This will DELETE the AI Platform stack and stop k0s on all nodes."
  warn "Node machines will remain running but all Kubernetes data will be removed."
  warn "This action CANNOT be undone."
  log ""

  if [[ "${AUTO_APPROVE:-false}" != "true" ]]; then
    echo -e "  \033[1;31mType the cluster name '${CLUSTER_NAME}' to confirm deletion, or Ctrl-C to abort:\033[0m" >&2
    local confirm_input
    read -r confirm_input
    if [[ "${confirm_input}" != "${CLUSTER_NAME}" ]]; then
      echo "Aborted — input did not match cluster name." >&2
      exit 0
    fi
    log "Confirmed. Proceeding with deletion..."
  else
    log "AUTO_APPROVE=true — skipping confirmation prompt."
  fi

  # Graceful Kubernetes cleanup, then stop k0s on all nodes
  log "Performing graceful Kubernetes cleanup..."

  export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"

  if [[ -f "${KUBECONFIG}" ]] && timeout 10 kubectl cluster-info &>/dev/null; then
    log "Deleting Kubernetes resources..."
    kubectl delete aiplatform --all -n "${AI_NS}" --timeout=60s || true
    kubectl delete namespace "${AI_NS}" --timeout=120s || true
    kubectl delete namespace splunk-ai-operator-system --timeout=60s || true
    kubectl delete namespace monitoring --timeout=60s || true
  fi

  IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
  IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"

  log "Stopping k0s on controller nodes..."
  for ip in "${CONTROLLER_IPS[@]}"; do
    log "  Stopping k0s on controller: ${ip}..."
    ssh_exec "${ip}" "sudo k0s stop || true; sudo k0s reset --force || true" || warn "Failed to stop k0s on ${ip}"
  done

  log "Stopping k0s on worker nodes..."
  for ip in "${WORKER_IPS[@]}"; do
    log "  Stopping k0s on worker: ${ip}..."
    ssh_exec "${ip}" "sudo k0s stop || true; sudo k0s reset --force || true" || warn "Failed to stop k0s on ${ip}"
  done

  log "k0s stopped on all nodes"
  log "NOTE: Node machines are still running. To clean up completely:"
  log "  - Remove k0s binaries: sudo rm -f /usr/local/bin/k0s"
  log "  - Clean up data: sudo rm -rf /var/lib/k0s /etc/k0s"

  # Clean up local files
  log "Cleaning up local files..."
  local kubeconfig_count=0
  for kc in "${HOME}/.kube/k0s-${CLUSTER_NAME}" "${HOME}/.kube/k0s-${CLUSTER_NAME}.bak"; do
    if [[ -f "${kc}" ]]; then
      rm -f "${kc}"
      ((kubeconfig_count++))
    fi
  done
  rm -rf "/tmp/splunk-ai-operator" || true

  log "============================================"
  log "Cleanup Summary"
  log "============================================"

  log "Infrastructure: On-premises"
  log "  - k0s stopped and reset on all nodes"
  log "  - NOTE: Nodes are still running, k0s binaries remain"

  log ""
  log "Kubernetes Resources:"
  log "  - AI Platform resources deleted"
  log "  - Splunk Standalone deleted"
  log "  - Ray services/clusters deleted"
  log "  - All operators uninstalled"
  log "  - All namespaces deleted"
  log ""
  log "Local Files:"
  log "  - Kubeconfig files: ${kubeconfig_count} cleaned up"

  log ""
  log "============================================"
  log "Cleanup complete!"
  log "============================================"
  log ""
  log "Cluster '${CLUSTER_NAME}' has been deleted."

  log ""
  log "Nodes are still running with k0s stopped."
  log "To fully clean up each node, run:"
  log "  sudo rm -f /usr/local/bin/k0s"
  log "  sudo rm -rf /var/lib/k0s /etc/k0s"
}

# ====== CLEAN ALL (AGGRESSIVE CLEANUP) ======
clean_all() {
  log "============================================"
  log "AGGRESSIVE CLEANUP MODE"
  log "============================================"
  warn "This will forcefully remove all resources and data!"

  load_config

  # Run normal delete first
  main_delete

  # Additional aggressive cleanup for on-prem
  if [[ -n "${EXISTING_CONTROLLER_IPS}" ]]; then
    IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
    IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"

    log "Performing aggressive cleanup on nodes..."
    for ip in "${CONTROLLER_IPS[@]}" "${WORKER_IPS[@]}"; do
      log "  Deep cleaning node: ${ip}..."
      ssh_exec "${ip}" "
        sudo systemctl stop k0scontroller k0sworker || true
        sudo systemctl disable k0scontroller k0sworker || true
        sudo rm -rf /var/lib/k0s /etc/k0s
        sudo rm -f /usr/local/bin/k0s
        sudo rm -rf /var/lib/kubelet /etc/cni /opt/cni
        sudo rm -rf /var/lib/calico /etc/calico
        sudo iptables -F || true
        sudo iptables -X || true
        sudo iptables -t nat -F || true
        sudo iptables -t nat -X || true
        sudo iptables -t mangle -F || true
        sudo iptables -t mangle -X || true
      " || warn "Failed aggressive cleanup on ${ip}"
    done
  fi

  log "Aggressive cleanup complete!"
}

# ====== DIAGNOSE SUBCOMMAND ======
# Collects a support bundle: cluster state, pod logs, events, installer logs.
# Produces a single tar.gz that can be attached to a support ticket.
diagnose() {
  load_config 2>/dev/null || true

  local bundle_dir
  bundle_dir="$(mktemp -d)/splunk-ai-diagnose-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "${bundle_dir}"

  log "=== Collecting support bundle into ${bundle_dir} ==="

  # 1. Installer logs
  log "Collecting installer logs..."
  cp "${LOG_DIR}"/k0s-install-*.log "${bundle_dir}/" 2>/dev/null || true

  # 2. Cluster state (best-effort — cluster may be unreachable)
  if timeout 10 kubectl cluster-info &>/dev/null 2>&1; then
    log "Collecting cluster state..."
    kubectl get nodes -o wide                                           > "${bundle_dir}/nodes.txt"        2>&1 || true
    kubectl get pods --all-namespaces -o wide                           > "${bundle_dir}/pods.txt"         2>&1 || true
    kubectl get events --all-namespaces --sort-by='.lastTimestamp'      > "${bundle_dir}/events.txt"       2>&1 || true
    kubectl get pvc --all-namespaces                                    > "${bundle_dir}/pvcs.txt"         2>&1 || true
    kubectl get svc --all-namespaces                                    > "${bundle_dir}/services.txt"     2>&1 || true
    kubectl get deployment --all-namespaces -o wide                     > "${bundle_dir}/deployments.txt"  2>&1 || true
    kubectl get statefulset --all-namespaces -o wide                    > "${bundle_dir}/statefulsets.txt" 2>&1 || true
    kubectl get daemonset --all-namespaces -o wide                      > "${bundle_dir}/daemonsets.txt"   2>&1 || true
    kubectl describe nodes                                              > "${bundle_dir}/node-details.txt" 2>&1 || true
    kubectl describe deployment  --all-namespaces                       > "${bundle_dir}/deployment-details.txt"  2>&1 || true
    kubectl describe statefulset --all-namespaces                       > "${bundle_dir}/statefulset-details.txt" 2>&1 || true
    kubectl describe daemonset   --all-namespaces                       > "${bundle_dir}/daemonset-details.txt"   2>&1 || true

    # Pod logs — all pods (current + previous crash container)
    # Failing pods get deeper tails; Running pods get a shorter tail for
    # context without blowing up the bundle size.
    log "Collecting pod logs (all pods)..."
    local _diag_ns _diag_pod _diag_phase
    while IFS= read -r _diag_line; do
      _diag_ns=$(echo "${_diag_line}"    | awk '{print $1}')
      _diag_pod=$(echo "${_diag_line}"   | awk '{print $2}')
      _diag_phase=$(echo "${_diag_line}" | awk '{print $4}')
      mkdir -p "${bundle_dir}/pod-logs/${_diag_ns}"
      local _tail=100
      [[ "${_diag_phase}" != "Running" && "${_diag_phase}" != "Completed" ]] && _tail=300
      kubectl logs "${_diag_pod}" -n "${_diag_ns}" --all-containers=true --tail="${_tail}" \
        > "${bundle_dir}/pod-logs/${_diag_ns}/${_diag_pod}.log"          2>&1 || true
      kubectl logs "${_diag_pod}" -n "${_diag_ns}" --all-containers=true --previous --tail=150 \
        > "${bundle_dir}/pod-logs/${_diag_ns}/${_diag_pod}.previous.log" 2>&1 || true
      # Full describe for every unhealthy pod (captures init containers, volumes, resource limits)
      if [[ "${_diag_phase}" != "Running" && "${_diag_phase}" != "Completed" ]]; then
        kubectl describe pod "${_diag_pod}" -n "${_diag_ns}" \
          > "${bundle_dir}/pod-logs/${_diag_ns}/${_diag_pod}.describe.txt" 2>&1 || true
      fi
    done < <(kubectl get pods --all-namespaces --no-headers 2>/dev/null)

    # AI Platform specific resources
    kubectl describe aiplatform --all -n "${AI_NS}" > "${bundle_dir}/aiplatform-cr.txt" 2>&1 || true
    kubectl describe aiservice  --all -n "${AI_NS}" > "${bundle_dir}/aiservice-cr.txt"  2>&1 || true
    kubectl describe raycluster --all-namespaces    > "${bundle_dir}/raycluster-cr.txt" 2>&1 || true
    kubectl describe rayservice --all-namespaces    > "${bundle_dir}/rayservice-cr.txt" 2>&1 || true
  else
    warn "Cluster not reachable — skipping kubectl diagnostics."
    echo "Cluster unreachable at time of diagnose run." > "${bundle_dir}/CLUSTER_UNREACHABLE.txt"
  fi

  # 3. Config file (redact credentials)
  if [[ -f "${CONFIG_FILE}" ]]; then
    log "Including config file (credentials redacted)..."
    sed 's/\(rootUser\|rootPassword\|hf-token\|hf-username\|AWS_ACCESS_KEY_ID\|AWS_SECRET_ACCESS_KEY\|password\):.*/\1: <REDACTED>/g' \
      "${CONFIG_FILE}" > "${bundle_dir}/cluster-config-redacted.yaml"
  fi

  # 4. Tool versions
  {
    echo "=== Tool versions ==="
    kubectl version --client 2>/dev/null || true
    helm version 2>/dev/null || true
    yq --version 2>/dev/null || true
    ssh -V 2>&1 || true
    echo "=== OS ==="
    uname -a
  } > "${bundle_dir}/tool-versions.txt"

  # 5. Pack bundle
  mkdir -p "${LOG_DIR}"
  local bundle_tar="${LOG_DIR}/splunk-ai-diagnose-$(date '+%Y%m%d-%H%M%S').tar.gz"
  tar -czf "${bundle_tar}" -C "$(dirname "${bundle_dir}")" "$(basename "${bundle_dir}")"
  rm -rf "${bundle_dir}"

  log ""
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  Support bundle ready                                        ║"
  log "╠══════════════════════════════════════════════════════════════╣"
  log "║  File : ${bundle_tar}"
  log "║"
  log "║  Share this file with Splunk Support or attach it to your   ║"
  log "║  support ticket. It contains no plaintext credentials.      ║"
  log "╚══════════════════════════════════════════════════════════════╝"
}

# ====== VALIDATE SUBCOMMAND ======
# Config completeness check — catches problems before a 40-min install run.
validate_config() {
  load_config

  echo -e "\n\033[1;34m[VALIDATE]\033[0m Checking configuration completeness...\n" >&2
  local errors=0 warnings=0

  _vcheck() {
    local label="$1" val="$2" severity="${3:-error}" hint="${4:-}"
    if [[ -z "${val}" || "${val}" == "null" || "${val}" == "<paste"* ]]; then
      if [[ "${severity}" == "warn" ]]; then
        echo -e "  \033[1;33m!\033[0m ${label} is not set${hint:+  →  ${hint}}" >&2
        warnings=$(( warnings + 1 ))
      else
        echo -e "  \033[1;31m✖\033[0m ${label} is not set${hint:+  →  ${hint}}" >&2
        errors=$(( errors + 1 ))
      fi
    else
      echo -e "  \033[1;32m✔\033[0m ${label}" >&2
    fi
  }

  _vcheck "cluster.name"                "${CLUSTER_NAME}"
  _vcheck "cluster.sshKeyPath"          "$(yq eval '.cluster.sshKeyPath' "${CONFIG_FILE}" 2>/dev/null)" "" "set path to your SSH private key"
  _vcheck "cluster.sshUser"             "$(yq eval '.cluster.sshUser'    "${CONFIG_FILE}" 2>/dev/null)" "" "set SSH login user on nodes"
  _vcheck "nodes.existingIPs.controllers[0]" "$(yq eval '.nodes.existingIPs.controllers[0]' "${CONFIG_FILE}" 2>/dev/null)"  "" "at least one controller IP required"

  local obj_type obj_bucket obj_user obj_pass
  obj_type=$(yq eval '.storage.objectStore.type    // ""' "${CONFIG_FILE}" 2>/dev/null)
  obj_bucket=$(yq eval '.storage.objectStore.bucket  // ""' "${CONFIG_FILE}" 2>/dev/null)
  obj_user=$(yq eval '.storage.objectStore.auth.rootUser     // ""' "${CONFIG_FILE}" 2>/dev/null)
  obj_pass=$(yq eval '.storage.objectStore.auth.rootPassword // ""' "${CONFIG_FILE}" 2>/dev/null)
  _vcheck "storage.objectStore.type"   "${obj_type}"   "" "aws | s3compat | minio | seaweedfs"
  _vcheck "storage.objectStore.bucket" "${obj_bucket}" "" "name of the bucket"
  _vcheck "storage.objectStore.auth.rootUser"     "${obj_user}"  "" "AWS_ACCESS_KEY_ID or MinIO root user"
  _vcheck "storage.objectStore.auth.rootPassword" "${obj_pass}"  "" "AWS secret or MinIO root password"

  local img_reg img_op
  img_reg=$(yq eval '.images.registry // ""' "${CONFIG_FILE}" 2>/dev/null)
  img_op=$(yq eval  '.images.operator.image // ""' "${CONFIG_FILE}" 2>/dev/null)
  _vcheck "images.operator.image" "${img_op}" "" "your splunk-ai-operator image"
  _vcheck "aiPlatform.defaultAcceleratorType" \
    "$(yq eval '.aiPlatform.defaultAcceleratorType // ""' "${CONFIG_FILE}" 2>/dev/null)" \
    "" "$(IFS=\|; echo "${SUPPORTED_ACCELERATORS[*]}")"
  local _accel_val
  _accel_val=$(yq eval '.aiPlatform.defaultAcceleratorType // ""' "${CONFIG_FILE}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ -n "${_accel_val}" ]]; then
    local _valid=false
    for _t in "${SUPPORTED_ACCELERATORS[@]}"; do
      [[ "${_accel_val}" == "${_t,,}" ]] && _valid=true && break
    done
    if ! ${_valid}; then
      echo -e "  \033[1;31m✖\033[0m aiPlatform.defaultAcceleratorType: unsupported value '${_accel_val}' — must be one of: ${SUPPORTED_ACCELERATORS[*]}" >&2
      errors=$(( errors + 1 ))
    fi
  fi
  if [[ -z "${img_reg}" ]]; then
    echo -e "  \033[1;33m!\033[0m images.registry is empty — using public registries. Set for air-gap/private deployments." >&2
    warnings=$(( warnings + 1 ))
  else
    echo -e "  \033[1;32m✔\033[0m images.registry = ${img_reg}" >&2
  fi

  local splunk_file ai_file
  splunk_file=$(yq eval '.files.splunkOperator // ""' "${CONFIG_FILE}" 2>/dev/null)
  ai_file=$(yq eval     '.files.aiPlatform     // ""' "${CONFIG_FILE}" 2>/dev/null)
  [[ -f "${splunk_file}" ]] && echo -e "  \033[1;32m✔\033[0m files.splunkOperator exists: ${splunk_file}" >&2 \
    || { echo -e "  \033[1;31m✖\033[0m files.splunkOperator not found: ${splunk_file}" >&2; errors=$(( errors+1 )); }
  [[ -f "${ai_file}" ]]     && echo -e "  \033[1;32m✔\033[0m files.aiPlatform exists: ${ai_file}" >&2 \
    || { echo -e "  \033[1;31m✖\033[0m files.aiPlatform not found: ${ai_file}" >&2; errors=$(( errors+1 )); }

  echo "" >&2
  if (( errors == 0 && warnings == 0 )); then
    echo -e "  \033[1;32mConfiguration looks complete. Ready to run install.\033[0m" >&2
  elif (( errors == 0 )); then
    echo -e "  \033[1;33m${warnings} warning(s). Configuration is usable but review the items above.\033[0m" >&2
  else
    echo -e "  \033[1;31m${errors} error(s), ${warnings} warning(s). Fix the errors above before running install.\033[0m" >&2
    exit 1
  fi
}

# ====== USAGE ======
usage() {
  cat <<EOF
Usage: $0 [install|validate|stage-artifacts|delete|clean-all|join-workers|verify-pods|diagnose]

Deploys Splunk AI Platform on k0s cluster using pre-provisioned nodes.
Requires nodes.existingIPs in the config YAML.

Commands:
  install [--silent|-s]
                   - Install k0s cluster and AI Platform stack.
                     Two flows are supported:

                     Full install (default, no flag):
                       Interactive. Prompts whether to download & stage model
                       artifacts — the answer overrides storage.modelStaging.enabled.
                       Displays the install plan and asks for 'yes' before starting.

                     Silent install (--silent / -s / AUTO_APPROVE=true):
                       Non-interactive. Uses config values as-is. Assumes the config
                       has been reviewed. Displays the install plan, waits 5 s, then
                       proceeds automatically without any prompts.
  validate         - Check config file completeness before a full install.
                     Catches missing IPs, unset credentials, missing manifest files.
                     Safe to run any time — makes no changes.
  stage-artifacts  - Download model artifacts from Hugging Face and upload them to
                     the configured object store. Useful to re-stage or to
                     pre-load before install. Requires nodes.existingIPs in the
                     config (same as install). Always runs regardless of
                     storage.modelStaging.enabled.
  join-workers     - Join/rejoin worker nodes to existing cluster (resume after failure)
  delete           - Delete cluster and all resources (graceful).
                     Prompts for cluster name confirmation unless AUTO_APPROVE=true.
  clean-all        - Aggressive cleanup including node-level cleanup.
                     Prompts for cluster name confirmation unless AUTO_APPROVE=true.
  verify-pods      - Verify every pod across every namespace AND every workload CR
                     (RayCluster/RayService, Splunk Standalone, AIPlatform/AIService).
                     Waits for Ray workers to be created/pulled by the head, captures
                     diagnostics (events + recent logs) for unhealthy pods, and emits
                     targeted remediation recommendations. Stale
                     'saia-vector-db-setup-posthook' errors are ignored when the newest
                     posthook pod has Succeeded.
  diagnose         - Collect a support bundle (cluster state, pod logs, events,
                     installer logs) into a tar.gz file. Attach to support tickets.

Environment:
  CONFIG_FILE              - Path to k0s config YAML (default: ./k0s-cluster-config.yaml)
  SILENT_INSTALL           - Set to true to run install non-interactively (same as --silent).
  AUTO_APPROVE             - Set to true to skip all confirmation prompts (implies SILENT_INSTALL
                             for install; also skips delete/clean-all confirmations).
  POD_HEALTH_STABLE_WAIT   - Seconds to wait for pods AND workload CRs (RayCluster,
                             RayService, Splunk Standalone, AIPlatform/AIService) to
                             reach Ready during verify (default: 600 = 10 minutes).
                             Bump to 1200 (20 min) on slow networks or fresh clusters
                             where Ray Serve has lots of model artifacts to download.
  POD_HEALTH_PENDING_GRACE - Seconds to ignore Pending pods younger than this
                             (default: 300)
  POD_HEALTH_POLL_INTERVAL - Seconds between checks while waiting (default: 15)

Examples:
  # Full install (interactive): prompts for model download, then asks 'yes' to proceed
  CONFIG_FILE=./my-config.yaml $0 install

  # Silent install (non-interactive, CI/CD): uses config values, no prompts, 5-second abort window
  CONFIG_FILE=./my-config.yaml $0 install --silent
  # Equivalent:
  AUTO_APPROVE=true CONFIG_FILE=./my-config.yaml $0 install

  # Stage model artifacts only (no cluster install; always runs regardless of config)
  CONFIG_FILE=./my-config.yaml $0 stage-artifacts

  # Join worker nodes (if install failed or was interrupted)
  CONFIG_FILE=./my-config.yaml $0 join-workers

  # Delete cluster (with confirmation prompt)
  CONFIG_FILE=./my-config.yaml $0 delete

  # Delete cluster (auto-approve, no prompt)
  AUTO_APPROVE=true CONFIG_FILE=./my-config.yaml $0 delete

  # Deep cleanup (aggressive)
  CONFIG_FILE=./my-config.yaml $0 clean-all

  # Verify all pods are healthy (re-runs diagnostics any time)
  CONFIG_FILE=./my-config.yaml $0 verify-pods

Notes:
  - 'install' performs full cluster setup including worker joins
  - 'join-workers' is useful for:
    * Resuming after installation was interrupted
    * Retrying failed worker joins
    * Adding workers to existing cluster
    * Fixing missing node labels
  - 'delete' performs comprehensive cleanup:
    * All Kubernetes resources (CRs, operators, namespaces)
    * Stops and resets k0s on all nodes
    * Machines remain running but k0s is stopped and reset
    * Provides detailed cleanup summary
  - 'clean-all' adds aggressive node-level cleanup:
    * Removes k0s data directories (preserves k0s binary)
    * Cleans kubelet, CNI, and Calico files
    * Flushes iptables rules
  - 'stage-artifacts' runs independently of the YAML gate; set
    storage.modelStaging.enabled: false to skip auto-staging during 'install'
    while still being able to run it manually via this subcommand.
    HF credentials (hf-token, hf-username) are read from
    ../artifacts_download_upload_scripts/model_artifacts_configs.yaml.
  - 'verify-pods' runs the same pod-health audit that 'install' triggers at
    the end. Useful for re-checking a cluster, gathering remediation hints
    after a partial failure, or verifying a manual fix.
  - All commands are idempotent and safe to run multiple times
EOF
}

# ====== VERIFY WORKER STATUS ======
# Check if a worker is properly connected to the cluster
verify_worker_status() {
  local worker_ip="$1"
  local controller_ip="$2"

  log "  Verifying worker ${worker_ip} status..."

  # Check 1: Is k0s running on the worker?
  local k0s_status
  k0s_status=$(ssh_exec "${worker_ip}" "sudo k0s status 2>&1" || echo "not running")

  if echo "${k0s_status}" | grep -q "Kube-api probing successful: true"; then
    log "    ✓ k0s running and API reachable"
    return 0
  elif echo "${k0s_status}" | grep -q "Role: worker"; then
    # k0s is running but API not reachable yet
    log "    ⏳ k0s running but API not yet reachable"
    return 1
  else
    log "    ✗ k0s not running"
    return 2
  fi
}

# ====== THOROUGH WORKER CLEANUP ======
# Completely clean up k0s on a worker node (for fresh rejoin)
cleanup_worker_k0s() {
  local worker_ip="$1"

  log "  Performing thorough k0s cleanup on ${worker_ip}..."

  ssh_exec "${worker_ip}" "
    sudo systemctl stop k0sworker 2>/dev/null || true
    sudo systemctl disable k0sworker 2>/dev/null || true
    sudo systemctl reset-failed k0sworker 2>/dev/null || true
    sudo pkill -9 k0s 2>/dev/null || true
    sudo pkill -9 kubelet 2>/dev/null || true
    sudo pkill -9 containerd-shim 2>/dev/null || true
    sudo rm -f /etc/systemd/system/k0sworker.service
    sudo rm -rf /var/lib/k0s /run/k0s /etc/k0s /tmp/k0s-token
    sudo rm -f /run/k0s/containerd.sock 2>/dev/null || true
    sudo systemctl daemon-reload
  " 2>/dev/null || true

  log "    ✓ Cleanup complete"
}

# ====== JOIN WORKERS (Resume/Retry Worker Joins) ======
join_workers() {
  log "============================================"
  log "Joining Worker Nodes to k0s Cluster"
  log "============================================"

  load_config

  # Set proper kubeconfig
  export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"

  if [[ ! -f "${KUBECONFIG}" ]]; then
    err "Kubeconfig not found at ${KUBECONFIG}. Please run 'install' first."
  fi

  # Get IPs from config
  log "Detecting cluster configuration..."
  IFS=' ' read -ra CONTROLLER_IPS <<< "${EXISTING_CONTROLLER_IPS}"
  IFS=' ' read -ra WORKER_IPS <<< "${EXISTING_WORKER_IPS}"

  if [[ ${#WORKER_IPS[@]} -eq 0 ]]; then
    warn "No worker IPs found in config"
    log "Nothing to join, exiting."
    return 0
  fi

  local controller_ip="${CONTROLLER_IPS[0]}"
  log "Controller IP: ${controller_ip}"
  log "Worker IPs: ${WORKER_IPS[*]}"

  # Check which workers are already joined AND healthy
  log "Checking current cluster nodes..."
  kubectl get nodes -o wide || true

  local already_joined_ips=()
  local needs_rejoin_ips=()

  # Get all cluster nodes once for matching
  local cluster_nodes_json
  cluster_nodes_json=$(kubectl get nodes -o json 2>/dev/null || echo '{"items":[]}')

  for worker_ip in "${WORKER_IPS[@]}"; do
    # Resolve the Kubernetes node name by SSHing to the worker and getting its hostname
    local node_exists=""
    node_exists=$(resolve_node_name "${worker_ip}")

    # Verify this node actually exists in the cluster
    if [[ -n "${node_exists}" ]]; then
      local found_in_cluster
      found_in_cluster=$(echo "${cluster_nodes_json}" | jq -r --arg name "${node_exists}" \
        '.items[] | select(.metadata.name==$name) | .metadata.name' 2>/dev/null | head -1 || echo "")
      if [[ -z "${found_in_cluster}" ]]; then
        node_exists=""
      fi
    fi

    if [[ -n "${node_exists}" ]]; then
      # Node exists in cluster, check if it's Ready
      local node_ready
      node_ready=$(echo "${cluster_nodes_json}" | jq -r --arg name "${node_exists}" \
        '.items[] | select(.metadata.name==$name) | .status.conditions[] | select(.type=="Ready") | .status' 2>/dev/null || echo "Unknown")

      if [[ "${node_ready}" == "True" ]]; then
        log "  ✓ Worker ${worker_ip} joined and Ready as ${node_exists}"
        already_joined_ips+=("${worker_ip}")
      else
        log "  ⚠ Worker ${worker_ip} exists as ${node_exists} but not Ready (${node_ready})"
        needs_rejoin_ips+=("${worker_ip}")
      fi
    else
      # Node doesn't exist in cluster, check k0s status on worker
      log "  Checking k0s status on ${worker_ip}..."
      if verify_worker_status "${worker_ip}" "${controller_ip}"; then
        log "  ⏳ Worker ${worker_ip} k0s running, waiting for cluster sync..."
        # Give it more time to appear in cluster
      else
        log "  ✗ Worker ${worker_ip} not properly connected"
        needs_rejoin_ips+=("${worker_ip}")
      fi
    fi
  done

  # If all workers are joined, nothing to do
  if [[ ${#already_joined_ips[@]} -eq ${#WORKER_IPS[@]} ]]; then
    log ""
    log "✓ All ${#WORKER_IPS[@]} workers are already joined and healthy!"
    kubectl get nodes -o wide
    return 0
  fi

  # Generate worker token from controller
  log ""
  log "Generating worker join token..."
  local worker_token
  worker_token=$(ssh_exec "${controller_ip}" "sudo k0s token create --role=worker" 2>/dev/null)

  if [[ -z "${worker_token}" ]]; then
    err "Failed to generate worker token from controller"
  fi

  log "Worker token generated successfully (${#worker_token} chars)"

  # Join workers that need to be joined/rejoined
  local workers_joined=0
  local workers_to_process=()

  # Build list of workers to process (use ${arr[@]+...} to avoid unbound-variable on empty arrays)
  for worker_ip in "${WORKER_IPS[@]}"; do
    local skip=false
    if [[ ${#already_joined_ips[@]} -gt 0 ]]; then
      for joined_ip in "${already_joined_ips[@]}"; do
        if [[ "${joined_ip}" == "${worker_ip}" ]]; then
          skip=true
          break
        fi
      done
    fi
    if [[ "${skip}" == "false" ]]; then
      workers_to_process+=("${worker_ip}")
    fi
  done

  log ""
  log "Workers to join/rejoin: ${workers_to_process[*]:-none}"

  if [[ ${#workers_to_process[@]} -eq 0 ]]; then
    log "No workers need joining"
    return 0
  fi

  for worker_ip in "${workers_to_process[@]}"; do
    log ""
    log "============================================"
    log "Joining worker: ${worker_ip}"
    log "============================================"

    # Thorough cleanup before rejoining (handles stale configurations)
    cleanup_worker_k0s "${worker_ip}"

    # RHEL/Fedora compatibility (firewalld, kernel modules, python3-pyyaml, k0s binary).
    # Handles both online (curl get.k0s.sh) and air-gap (file:// scp) install paths.
    prepare_nodes_for_k0s "${worker_ip}"

    # Install worker with fresh token
    log "  Installing k0s worker configuration..."
    if ssh_exec "${worker_ip}" "echo '${worker_token}' | sudo tee /tmp/k0s-token >/dev/null && sudo k0s install worker --token-file=/tmp/k0s-token"; then
      log "  ✓ Worker configuration installed"
    else
      warn "  Failed to install worker configuration on ${worker_ip}"
      continue
    fi

    # Air-gap: stage k0s system + add-on images now — after `k0s install`
    # (which recreated /var/lib/k0s) and BEFORE the worker is started below.
    # Without this a worker joined via this subcommand starts with an empty
    # /var/lib/k0s/images/, so its calico/kube-proxy pods try to pull from the
    # (blocked) internet and the node never becomes Ready. No-op when
    # AIRGAP_K0S_IMAGE_DIR is unset (i.e. not an air-gap install).
    stage_k0s_image_bundle "${worker_ip}"

    # Start worker using systemctl (more reliable than k0s start)
    log "  Starting k0s worker..."
    if ssh_exec "${worker_ip}" "sudo systemctl start k0sworker"; then
      log "  ✓ Worker service started"
    else
      warn "  Failed to start k0s worker on ${worker_ip}"
      # Try fallback
      ssh_exec "${worker_ip}" "sudo k0s start" || continue
    fi

    # Wait briefly and verify
    log "  Waiting for worker to initialize (15s)..."
    sleep 15

    # Verify worker status
    if verify_worker_status "${worker_ip}" "${controller_ip}"; then
      log "  ✓ Worker ${worker_ip} connected successfully!"
      workers_joined=$((workers_joined + 1))
    else
      warn "  Worker ${worker_ip} may still be connecting..."
      workers_joined=$((workers_joined + 1))  # Count as attempted
    fi
  done

  if [[ ${workers_joined} -gt 0 ]]; then
    log ""
    log "Waiting for workers to appear in cluster (45s)..."
    sleep 45

    log ""
    log "Current cluster nodes:"
    kubectl get nodes -o wide

    # Label the newly joined nodes
    log ""
    log "Labeling worker nodes..."
    label_nodes

    log ""
    log "============================================"
    log "✓ Processed ${workers_joined} worker(s)"
    log "============================================"

    # Final verification
    local final_count
    final_count=$(kubectl get nodes --no-headers | wc -l)
    local expected_count=$((${#CONTROLLER_IPS[@]} + ${#WORKER_IPS[@]}))

    if [[ ${final_count} -ge ${expected_count} ]]; then
      log "✓ All ${expected_count} nodes are now in the cluster!"
    else
      warn "Only ${final_count}/${expected_count} nodes in cluster. Some workers may need more time."
      warn "Run '$0 join-workers' again if workers don't appear within a few minutes."
    fi
  else
    log ""
    log "No workers needed to be joined"
  fi
}

# ====== MAIN ======
# Parse install-specific flags before handing off to subcommands.
_CMD="${1:-install}"
shift 2>/dev/null || true
case "${_CMD}" in
  install)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --silent|-s) SILENT_INSTALL=true; shift ;;
        *) echo "Unknown install option: $1" >&2; usage >&2; exit 1 ;;
      esac
    done
    main_install
    ;;
  validate)
    validate_config
    ;;
  stage-artifacts)
    load_config
    resolve_accelerator_type
    stage_model_artifacts
    ;;
  delete)
    main_delete
    ;;
  clean-all)
    clean_all
    ;;
  join-workers)
    join_workers
    ;;
  verify-pods)
    load_config
    # Reuse the same kubeconfig path the install path writes to, when present
    if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${HOME}/.kube/k0s-${CLUSTER_NAME}" ]]; then
      export KUBECONFIG="${HOME}/.kube/k0s-${CLUSTER_NAME}"
    fi
    _vpc_rc=0
    verify_all_pods_healthy || _vpc_rc=$?
    if (( _vpc_rc != 0 )) && [[ "${AUTO_DIAGNOSE:-true}" != "false" ]]; then
      log "Auto-collecting support bundle (set AUTO_DIAGNOSE=false to suppress)..."
      diagnose || true
    fi
    exit "${_vpc_rc}"
    ;;
  diagnose)
    diagnose
    ;;
  *)
    usage
    exit 1
    ;;
esac
