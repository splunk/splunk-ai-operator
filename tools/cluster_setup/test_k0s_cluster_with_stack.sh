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
  # load_config tries to install yq and to discover an AWS account; neither may
  # touch the host or the network from a unit test.
  ensure_yq() { :; }
  aws() { return 1; }

  # Extract _POD_FS assignment (single line, not a function)
  eval "$(grep '^_POD_FS=' "${SCRIPT}")"

  eval "$(_extract_fn model_artifacts_config_name)"
  eval "$(_extract_fn build_image_url)"
  eval "$(_extract_fn validate_image_config)"
  eval "$(_extract_fn configure_images)"
  eval "$(_extract_fn validate_scale_factor_config)"
  eval "$(_extract_fn yaml_single_quote)"
  eval "$(_extract_fn resolve_airgap_mode)"
  eval "$(_extract_fn config_bool)"
  eval "$(_extract_fn load_config)"
  eval "$(_extract_fn validate_cpu_profile_consistency)"
  eval "$(_extract_fn render_las_feature_yaml)"
  eval "$(_extract_fn render_las_secret_refs)"
  eval "$(_extract_fn check_las_metrics_prerequisite)"
  eval "$(_extract_fn object_store_auth_looks_like_placeholder)"
  eval "$(_extract_fn _pod_is_healthy)"
  eval "$(_extract_fn _classify_pod_failure)"
  eval "$(_extract_fn _print_pod_section)"
  eval "$(_extract_fn _print_unhealthy_pod_summary)"
}

_load_functions

# ── Tests: effective network mode is independent of platform profile ────────
suite "resolve_airgap_mode"
echo "▶ resolve_airgap_mode"
_mode_tmpdir=$(mktemp -d)
for _profile in full cpuOnly; do
  for _airgap in false true; do
    _mode_config="${_mode_tmpdir}/${_profile}-${_airgap}.yaml"
    cat > "${_mode_config}" <<YAML
cluster:
  airgap: ${_airgap}
aiPlatform:
  profile: ${_profile}
  features:
    - name: agentruntime
      las:
        image:
          repository: registry.example/las
          tag: v1
        assistantId: sample
YAML
    _expected_network_mode="connected"
    [[ "${_airgap}" == "true" ]] && _expected_network_mode="airgapped"
    _resolved_airgap=$(resolve_airgap_mode "${_mode_config}" "")
    assert_eq "${_profile} with cluster.airgap=${_airgap} resolves independently" "${_airgap}" "${_resolved_airgap}"
    _effective_network_mode="connected"
    [[ "${_resolved_airgap}" == "true" ]] && _effective_network_mode="airgapped"
    _rendered_mode=$(render_las_feature_yaml "${_mode_config}" 0 "${_effective_network_mode}")
    assert_eq "${_profile} with cluster.airgap=${_airgap} renders ${_expected_network_mode}" \
      "1" "$(grep -c "networkMode: ${_expected_network_mode}" <<<"${_rendered_mode}" || true)"
  done
done
cat > "${_mode_tmpdir}/omitted.yaml" <<'YAML'
cluster: {}
YAML
assert_eq "omitted cluster.airgap defaults to connected" "false" \
  "$(resolve_airgap_mode "${_mode_tmpdir}/omitted.yaml" "")"
assert_eq "air-gap bundle override enables air-gapped mode" "true" \
  "$(resolve_airgap_mode "${_mode_tmpdir}/full-false.yaml" true)"
assert_eq "false override does not disable cluster.airgap=true" "true" \
  "$(resolve_airgap_mode "${_mode_tmpdir}/full-true.yaml" false)"
cat > "${_mode_tmpdir}/invalid.yaml" <<'YAML'
cluster:
  airgap: maybe
YAML
assert_rc "rejects unsupported cluster.airgap value" 1 \
  resolve_airgap_mode "${_mode_tmpdir}/invalid.yaml" ""
cat > "${_mode_tmpdir}/quoted.yaml" <<'YAML'
cluster:
  airgap: "true"
YAML
assert_rc "rejects quoted cluster.airgap instead of treating it as a boolean" 1 \
  resolve_airgap_mode "${_mode_tmpdir}/quoted.yaml" ""
assert_rc "rejects unsupported AIRGAP_MODE override" 1 \
  resolve_airgap_mode "${_mode_tmpdir}/full-false.yaml" maybe
rm -rf "${_mode_tmpdir}"

# ── Tests: LAS AIPlatform rendering allow-list and effective network mode ────
suite "render_las_feature_yaml"
echo "▶ render_las_feature_yaml"
_las_tmpdir=$(mktemp -d)
cat > "${_las_tmpdir}/config.yaml" <<'YAML'
aiPlatform:
  features:
    - name: agentruntime
      las:
        image:
          repository: registry.example/las
          tag: v1
        assistantId: sample
        tracing:
          enabled: false
        queue:
          resources:
            requests:
              cpu: "1"
          autoscaling:
            enabled: true
            minReplicas: 1
            maxReplicas: 3
            targetCPUUtilizationPercentage: 80
        credentials:
          postgresConnectionUrl: DO_NOT_RENDER_POSTGRES_URL
          langsmithApiKey: DO_NOT_RENDER_LANGSMITH_KEY
YAML
_las_rendered=$(render_las_feature_yaml "${_las_tmpdir}/config.yaml" 0 connected)
assert_eq "effective connected mode is rendered" "1" "$(grep -c 'networkMode: connected' <<<"${_las_rendered}" || true)"
assert_eq "queue CPU and autoscaling settings are rendered" "1" "$(grep -c 'targetCPUUtilizationPercentage: 80' <<<"${_las_rendered}" || true)"
assert_eq "raw PostgreSQL credential is excluded" "0" "$(grep -c 'DO_NOT_RENDER_POSTGRES_URL' <<<"${_las_rendered}" || true)"
assert_eq "raw LangSmith key is excluded" "0" "$(grep -c 'DO_NOT_RENDER_LANGSMITH_KEY' <<<"${_las_rendered}" || true)"
assert_eq "tracing is explicitly disabled" "1" "$(grep -c 'enabled: false' <<<"${_las_rendered}" || true)"
{
  printf 'spec:\n  features:\n    - name: agentruntime\n'
  # Match the installer concatenation: command substitution strips the renderer's
  # final newline, so the caller must restore it before a following feature field.
  printf '%s' "${_las_rendered}"$'\n'
  printf '      serviceAccountName: fixture-sa\n'
} > "${_las_tmpdir}/rendered.yaml"
assert_eq "rendered LAS feature is valid YAML" "connected" "$(yq eval -r '.spec.features[0].las.networkMode' "${_las_tmpdir}/rendered.yaml")"
assert_eq "following feature field remains valid YAML" "fixture-sa" "$(yq eval -r '.spec.features[0].serviceAccountName' "${_las_tmpdir}/rendered.yaml")"
_las_refs=$(render_las_secret_refs "${_las_tmpdir}/config.yaml" 0 true '{"managed":true,"licenseSecretRef":"las-auth-generated","postgresSecretRef":"las-postgres-generated","redisSecretRef":"las-redis-generated"}')
assert_eq "managed license Secret reference replaces legacy ref" "1" "$(grep -c 'licenseSecretRef: \"las-auth-generated\"' <<<"${_las_refs}" || true)"
assert_eq "managed dependency Secret references are rendered" "2" "$(grep -Ec 'SecretRef: \"las-(postgres|redis)-generated\"' <<<"${_las_refs}" || true)"
assert_eq "managed Secret references never render credential values" "0" "$(grep -c 'DO_NOT_RENDER_POSTGRES_URL' <<<"${_las_refs}" || true)"
{
  printf 'spec:\n  features:\n    - name: agentruntime\n'
  printf '%s' "${_las_refs}"$'\n'
  printf '%s' "${_las_rendered}"$'\n'
  printf '      serviceAccountName: fixture-sa\n'
} > "${_las_tmpdir}/managed-rendered.yaml"
assert_eq "managed credentials render as references in valid CR YAML" "las-postgres-generated" "$(yq eval -r '.spec.features[0].postgresSecretRef' "${_las_tmpdir}/managed-rendered.yaml")"
_airgapped_key_rc=0
_airgapped_key_stdout=$(render_las_feature_yaml "${_las_tmpdir}/config.yaml" 0 airgapped 2>"${_las_tmpdir}/airgapped-key-error.txt") || _airgapped_key_rc=$?
assert_eq "air-gapped mode rejects a LangSmith API key" "1" "${_airgapped_key_rc}"
assert_eq "air-gapped key rejection emits no partial LAS YAML" "" "${_airgapped_key_stdout}"
assert_eq "rejected air-gapped key is absent from output" "0" \
  "$(grep -c 'DO_NOT_RENDER_LANGSMITH_KEY' <<<"${_airgapped_key_stdout}" || true)"
assert_eq "rejected air-gapped key is absent from diagnostics" "0" \
  "$(grep -c 'DO_NOT_RENDER_LANGSMITH_KEY' "${_las_tmpdir}/airgapped-key-error.txt" || true)"
cat > "${_las_tmpdir}/newline-key.yaml" <<'YAML'
aiPlatform:
  features:
    - name: agentruntime
      las:
        credentials:
          langsmithApiKey: "\n\n"
YAML
_newline_key_rc=0
_newline_key_stdout=$(render_las_feature_yaml "${_las_tmpdir}/newline-key.yaml" 0 airgapped 2>"${_las_tmpdir}/newline-key-error.txt") || _newline_key_rc=$?
assert_eq "air-gapped mode rejects a newline-only LangSmith API key" "1" "${_newline_key_rc}"
assert_eq "newline-only key rejection emits no partial LAS YAML" "" "${_newline_key_stdout}"
cat > "${_las_tmpdir}/disabled-endpoint.yaml" <<'YAML'
aiPlatform:
  features:
    - name: agentruntime
      las:
        tracing:
          enabled: false
          endpoint: https://public-tracing.example.com
YAML
_disabled_rendered=$(render_las_feature_yaml "${_las_tmpdir}/disabled-endpoint.yaml" 0 airgapped)
assert_eq "disabled tracing does not render a stale endpoint" "0" \
  "$(grep -c 'endpoint:' <<<"${_disabled_rendered}" || true)"
cat > "${_las_tmpdir}/enabled-tracing.yaml" <<'YAML'
aiPlatform:
  features:
    - name: agentruntime
      las:
        tracing:
          enabled: true
          endpoint: https://internal-tracing.example.test
YAML
assert_rc "air-gapped mode rejects enabled tracing with any endpoint" 1 \
  render_las_feature_yaml "${_las_tmpdir}/enabled-tracing.yaml" 0 airgapped
assert_rc "connected mode permits enabled tracing" 0 \
  render_las_feature_yaml "${_las_tmpdir}/enabled-tracing.yaml" 0 connected
cat > "${_las_tmpdir}/invalid-tracing.yaml" <<'YAML'
aiPlatform:
  features:
    - name: agentruntime
      las:
        tracing:
          enabled: maybe
YAML
assert_rc "renderer rejects a nonboolean tracing.enabled value" 1 \
  render_las_feature_yaml "${_las_tmpdir}/invalid-tracing.yaml" 0 connected
cat > "${_las_tmpdir}/omitted-tracing.yaml" <<'YAML'
aiPlatform:
  features:
    - name: agentruntime
      las: {}
YAML
_omitted_rendered=$(render_las_feature_yaml "${_las_tmpdir}/omitted-tracing.yaml" 0 airgapped)
assert_eq "omitted tracing renders disabled" "1" \
  "$(grep -c '^          enabled: false$' <<<"${_omitted_rendered}" || true)"
_metric_config="${_las_tmpdir}/metrics.yaml"
cat > "${_metric_config}" <<'YAML'
aiPlatform:
  features:
    - name: agentruntime
      las:
        queue:
          autoscaling:
            enabled: true
YAML
_metric_warning=""
warn() { _metric_warning="$*"; }
kubectl() { return 1; }
check_las_metrics_prerequisite "${_metric_config}"
assert_eq "missing metrics API produces actionable queue autoscaling warning" "1" "$(grep -c 'Install/configure metrics-server' <<<"${_metric_warning}" || true)"
rm -rf "${_las_tmpdir}"

# ── Tests: aiPlatform.profile selection and cpuOnly consistency (MPR-3) ─────
# Each case writes a real config, runs the real load_config, then the validator,
# so omitted-field defaults behave as they do during an install.
suite "validate_cpu_profile_consistency"
echo "▶ validate_cpu_profile_consistency"
_profile_tmpdir=$(mktemp -d)

# Valid cpuOnly baseline. Extra arguments are yq expressions that mutate it.
# The credential-shaped values must never appear in validator output.
_write_cpu_profile_config() {
  local path="$1" expr
  shift
  cat > "${path}" <<'YAML'
cluster:
  name: profile-test
nodes:
  gpuWorkers: 0
  existingIPs:
    controllers: ["10.0.0.1"]
storage:
  modelStaging:
    enabled: false
  objectStore:
    auth:
      rootPassword: DO_NOT_PRINT_STORAGE_CANARY
components:
  nvidia: false
  kuberay: false
aiPlatform:
  profile: cpuOnly
  sidecars:
    envoy: false
    otel: false
    prometheusOperator: false
  features:
    - name: slim
    - name: agentruntime
      provider: mltk
      las:
        credentials:
          postgresUri: DO_NOT_PRINT_POSTGRES_CANARY
YAML
  for expr in "$@"; do
    yq eval -i "${expr}" "${path}"
  done
}

# Runs in a subshell because the real err() exits; prints stdout and stderr.
_profile_check() {
  ( CONFIG_FILE="$1"; load_config; validate_cpu_profile_consistency ) 2>&1
}

_expect_profile_ok() {
  local desc="$1" file="$2" out rc=0
  out=$(_profile_check "${file}") || rc=$?
  assert_eq "${desc} is accepted" "0" "${rc}"
  assert_eq "${desc} reports no profile conflict" "0" "$(grep -c 'conflicts with the configuration' <<<"${out}" || true)"
}

_expect_profile_conflict() {
  local desc="$1" file="$2" expected="$3" out rc=0
  out=$(_profile_check "${file}") || rc=$?
  assert_eq "${desc} is rejected" "1" "${rc}"
  assert_eq "${desc} names '${expected}'" "1" "$(grep -c -F -- "${expected}" <<<"${out}" || true)"
}

# Accepted configurations.
_write_cpu_profile_config "${_profile_tmpdir}/valid-connected.yaml"
_expect_profile_ok "cpuOnly with a consistent connected configuration" "${_profile_tmpdir}/valid-connected.yaml"
_write_cpu_profile_config "${_profile_tmpdir}/valid-airgap.yaml" '.cluster.airgap = true'
_expect_profile_ok "cpuOnly with a consistent air-gapped configuration" "${_profile_tmpdir}/valid-airgap.yaml"
_write_cpu_profile_config "${_profile_tmpdir}/omitted-components.yaml" 'del(.components)'
_expect_profile_ok "cpuOnly that omits components.nvidia and components.kuberay" "${_profile_tmpdir}/omitted-components.yaml"

# Full-feature selection is untouched: GPU, SAIA, staging, and sidecar settings
# that cpuOnly forbids must still pass when the profile is omitted or full.
_full_overrides=(
  '.nodes.gpuWorkers = 2'
  '.aiPlatform.defaultAcceleratorType = "L40S"'
  '.components.nvidia = true'
  '.components.kuberay = true'
  'del(.storage.modelStaging)'
  '.aiPlatform.sidecars.otel = true'
  '.aiPlatform.features = [{"name":"saia"},{"name":"slim"}]'
)
_write_cpu_profile_config "${_profile_tmpdir}/omitted-profile.yaml" 'del(.aiPlatform.profile)' "${_full_overrides[@]}"
_expect_profile_ok "full-feature configuration with the profile omitted" "${_profile_tmpdir}/omitted-profile.yaml"
_write_cpu_profile_config "${_profile_tmpdir}/explicit-full.yaml" '.aiPlatform.profile = "full"' "${_full_overrides[@]}"
_expect_profile_ok "full-feature configuration with profile: full" "${_profile_tmpdir}/explicit-full.yaml"
_omitted_profile_value=$( ( CONFIG_FILE="${_profile_tmpdir}/omitted-profile.yaml"; load_config; printf '%s' "${AI_PLATFORM_PROFILE-unset}" ) 2>&1 )
assert_eq "omitted aiPlatform.profile resolves to the empty full-feature default" "" "${_omitted_profile_value}"

# Unknown profile: load_config names the field and the allowed values.
_write_cpu_profile_config "${_profile_tmpdir}/unknown-profile.yaml" '.aiPlatform.profile = "gpuOnly"'
_unknown_rc=0
_unknown_out=$(_profile_check "${_profile_tmpdir}/unknown-profile.yaml") || _unknown_rc=$?
assert_eq "unknown aiPlatform.profile is rejected" "1" "${_unknown_rc}"
assert_eq "unknown aiPlatform.profile names the field and allowed values" "1" \
  "$(grep -c -F 'aiPlatform.profile must be full or cpuOnly' <<<"${_unknown_out}" || true)"

# Conflicting cpuOnly selections fail, in connected and air-gapped modes.
for _airgap_expr in 'del(.cluster.airgap)' '.cluster.airgap = true'; do
  _mode="connected"; [[ "${_airgap_expr}" == *"= true" ]] && _mode="air-gapped"
  _write_cpu_profile_config "${_profile_tmpdir}/saia-${_mode}.yaml" "${_airgap_expr}" '.aiPlatform.features += [{"name":"saia"}]'
  _expect_profile_conflict "${_mode} cpuOnly with SAIA" "${_profile_tmpdir}/saia-${_mode}.yaml" "'saia' is not supported by cpuOnly"
done
_write_cpu_profile_config "${_profile_tmpdir}/seca.yaml" '.aiPlatform.features += [{"name":"seca"}]'
_expect_profile_conflict "cpuOnly with SECA" "${_profile_tmpdir}/seca.yaml" "'seca' is not supported by cpuOnly"
_write_cpu_profile_config "${_profile_tmpdir}/no-features.yaml" '.aiPlatform.features = []'
_expect_profile_conflict "cpuOnly with no features (installer would default to saia)" "${_profile_tmpdir}/no-features.yaml" "aiPlatform.features is empty"
_write_cpu_profile_config "${_profile_tmpdir}/gpu-workers.yaml" '.nodes.gpuWorkers = 1'
_expect_profile_conflict "cpuOnly with a GPU worker" "${_profile_tmpdir}/gpu-workers.yaml" "nodes.gpuWorkers must be 0 for cpuOnly (got 1)"
_write_cpu_profile_config "${_profile_tmpdir}/gpu-workers-omitted.yaml" 'del(.nodes.gpuWorkers)'
_expect_profile_conflict "cpuOnly without nodes.gpuWorkers" "${_profile_tmpdir}/gpu-workers-omitted.yaml" "nodes.gpuWorkers must be 0 for cpuOnly (got unset or not a number)"
_write_cpu_profile_config "${_profile_tmpdir}/gpu-workers-text.yaml" '.nodes.gpuWorkers = "two"'
_expect_profile_conflict "cpuOnly with a non-numeric nodes.gpuWorkers" "${_profile_tmpdir}/gpu-workers-text.yaml" "(got unset or not a number)"
_write_cpu_profile_config "${_profile_tmpdir}/accelerator.yaml" '.aiPlatform.defaultAcceleratorType = "L40S"'
_expect_profile_conflict "cpuOnly with an accelerator type" "${_profile_tmpdir}/accelerator.yaml" "aiPlatform.defaultAcceleratorType must be empty"
_write_cpu_profile_config "${_profile_tmpdir}/nvidia.yaml" '.components.nvidia = true'
_expect_profile_conflict "cpuOnly with components.nvidia: true" "${_profile_tmpdir}/nvidia.yaml" "components.nvidia: true"
_write_cpu_profile_config "${_profile_tmpdir}/kuberay.yaml" '.components.kuberay = true'
_expect_profile_conflict "cpuOnly with components.kuberay: true" "${_profile_tmpdir}/kuberay.yaml" "components.kuberay: true"
_write_cpu_profile_config "${_profile_tmpdir}/staging-true.yaml" '.storage.modelStaging.enabled = true'
_expect_profile_conflict "cpuOnly with model staging enabled" "${_profile_tmpdir}/staging-true.yaml" "storage.modelStaging.enabled must be false"
_write_cpu_profile_config "${_profile_tmpdir}/staging-omitted.yaml" 'del(.storage.modelStaging)'
_expect_profile_conflict "cpuOnly with model staging omitted (defaults to true)" "${_profile_tmpdir}/staging-omitted.yaml" "storage.modelStaging.enabled must be false"
_write_cpu_profile_config "${_profile_tmpdir}/sidecar-otel.yaml" '.aiPlatform.sidecars.otel = true'
_expect_profile_conflict "cpuOnly with the OTel sidecar enabled" "${_profile_tmpdir}/sidecar-otel.yaml" "cpuOnly does not support sidecars"
_write_cpu_profile_config "${_profile_tmpdir}/sidecar-default.yaml" 'del(.aiPlatform.sidecars)'
_expect_profile_conflict "cpuOnly with sidecar flags left to their component defaults" "${_profile_tmpdir}/sidecar-default.yaml" "cpuOnly does not support sidecars"

# All conflicts are reported together, and no configuration value is echoed.
_write_cpu_profile_config "${_profile_tmpdir}/many.yaml" \
  '.aiPlatform.features += [{"name":"saia"}]' '.nodes.gpuWorkers = 3' '.aiPlatform.defaultAcceleratorType = "H100"'
_many_rc=0
_many_out=$(_profile_check "${_profile_tmpdir}/many.yaml") || _many_rc=$?
assert_eq "multiple cpuOnly conflicts are rejected" "1" "${_many_rc}"
assert_eq "multiple conflicts are listed in one error" "3" \
  "$(grep -c -E "is not supported by cpuOnly|nodes.gpuWorkers must be 0|defaultAcceleratorType must be empty" <<<"${_many_out}" || true)"
assert_eq "conflict output does not echo the accelerator value" "0" "$(grep -c 'H100' <<<"${_many_out}" || true)"
assert_eq "conflict output excludes the object-store credential" "0" "$(grep -c 'DO_NOT_PRINT_STORAGE_CANARY' <<<"${_many_out}" || true)"
assert_eq "conflict output excludes the LAS credential" "0" "$(grep -c 'DO_NOT_PRINT_POSTGRES_CANARY' <<<"${_many_out}" || true)"

# The check runs before any cluster change in both entry points.
_install_body=$(_extract_fn main_install)
_validate_body=$(_extract_fn validate_config)
_line_of() { grep -n -m1 -E "$2" <<<"$1" | cut -d: -f1; }
_check_line=$(_line_of "${_install_body}" '^  validate_cpu_profile_consistency$')
_preflight_line=$(_line_of "${_install_body}" '^  preflight_checks$')
_staging_line=$(_line_of "${_install_body}" 'stage_model_artifacts$')
assert_eq "main_install runs the cpuOnly consistency check" "1" "$([[ -n "${_check_line}" ]] && echo 1 || echo 0)"
assert_eq "main_install checks cpuOnly consistency before preflight" "1" \
  "$([[ -n "${_check_line}" && -n "${_preflight_line}" ]] && (( _check_line < _preflight_line )) && echo 1 || echo 0)"
assert_eq "main_install checks cpuOnly consistency before model staging" "1" \
  "$([[ -n "${_check_line}" && -n "${_staging_line}" ]] && (( _check_line < _staging_line )) && echo 1 || echo 0)"
assert_eq "validate runs the cpuOnly consistency check" "1" \
  "$(grep -c -E '^  validate_cpu_profile_consistency$' <<<"${_validate_body}" || true)"
rm -rf "${_profile_tmpdir}"

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

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo ""
if (( FAIL > 0 )); then
  exit 1
fi
