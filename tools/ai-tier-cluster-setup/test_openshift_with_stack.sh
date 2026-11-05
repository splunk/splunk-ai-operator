#!/usr/bin/env bash
# Local unit, contract, and render-smoke tests for the OpenShift installer.
# No OpenShift cluster, oc login, or network access is required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/openshift_with_stack.sh"
AIRGAP_PREPARE_SCRIPT="${SCRIPT_DIR}/prepare_airgap_bundle_openshift.sh"
AIRGAP_INSTALL_SCRIPT="${SCRIPT_DIR}/install_from_airgap_bundle_openshift.sh"
OPENSHIFT_README="${SCRIPT_DIR}/../../docs/ai-pod-docs/openshift-readme.md"
REAL_YQ=$(command -v yq 2>/dev/null || true)

PASS=0
FAIL=0

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: ${description}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${description}"
    echo "        expected: $(printf '%q' "${expected}")"
    echo "        actual:   $(printf '%q' "${actual}")"
  fi
}

assert_rc() {
  local description="$1" expected="$2"
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  assert_eq "${description}" "${expected}" "${actual}"
}

extract_function() {
  local name="$1" source_file="${2:-${SCRIPT}}" start end
  start=$(grep -n "^${name}()" "${source_file}" | cut -d: -f1)
  [[ -n "${start}" ]] || return 1
  end=$(awk -v start="${start}" 'NR > start && /^}$/ { print NR; exit }' "${source_file}")
  sed -n "${start},${end}p" "${source_file}"
}

eval "$(extract_function validate_scale_factor_config)"
eval "$(extract_function load_splunk_config)"
eval "$(extract_function bundled_splunk_enabled)"
eval "$(extract_function splunk_standalone_component)"
eval "$(extract_function load_config)"
eval "$(extract_function required_ai_tier_disk_gib)"
eval "$(extract_function openshift_feature_enabled)"
eval "$(extract_function openshift_slim_feature_enabled)"
eval "$(extract_function warn_on_mutable_image_tags)"
eval "$(extract_function validate_image_config)"
eval "$(extract_function build_image_url)"
eval "$(extract_function configure_images)"
eval "$(extract_function internal_splunk_management_url)"
eval "$(extract_function internal_splunk_hec_url)"
eval "$(extract_function _internal_splunk_btool_http_value)"
eval "$(extract_function render_splunk_defaults_manifest)"
eval "$(extract_function render_splunk_configuration)"
eval "$(extract_function render_ai_platform_manifest)"
eval "$(extract_function install_ai_platform_cr)"
eval "$(extract_function install_splunk_operator)"
eval "$(extract_function install_splunk_standalone)"
eval "$(extract_function main_install)"
eval "$(extract_function main_delete)"
eval "$(extract_function retain_splunk_ownership_records)"
eval "$(extract_function load_install_state_snapshot)"
eval "$(extract_function component_is_owned)"
eval "$(extract_function splunk_resource_may_exist)"
eval "$(extract_function preflight_check_registry)"
eval "$(extract_function normalize_openshift_clusterip_feature_services)"
eval "$(extract_function patch_openshift_slim_public_service_workaround)"
eval "$(extract_function openshift_route_enabled)"
eval "$(extract_function openshift_route_host)"
eval "$(extract_function create_openshift_feature_route)"
eval "$(extract_function platform_readiness_snapshot)"
eval "$(extract_function model_artifacts_config_name)"
eval "$(extract_function resolve_model_staging)"
eval "$(extract_function image_repository_from_ref)"
eval "$(extract_function mirror_sources_cover_repository)"
eval "$(extract_function operator_package_repositories)"
eval "$(extract_function wait_for_subscription_csv)"
eval "$(extract_function manifest_has_existing_resources)"
eval "$(extract_function resolve_accelerator_type)"
eval "$(extract_function delegate_airgap_install_if_needed)"
eval "$(extract_function openshift_endpoint_host)"
eval "$(extract_function openshift_decode_base64)"
eval "$(extract_function openshift_configured_ai_nodes)"
eval "$(extract_function openshift_allow_http_route)"
eval "$(extract_function openshift_wait_for_insecure_registry)"
eval "$(extract_function configure_openshift_insecure_endpoints)"
eval "$(extract_function preflight_check_insecure_registry_policy)"
eval "$(extract_function prepare_airgap_registry_auth_file)"
eval "$(extract_function validate_config)"
eval "$(extract_function clean_all)"
eval "$(extract_function run_verify_pods)"
eval "$(sed -n '/^qualified_additional_image()/,/^}/p' "${AIRGAP_PREPARE_SCRIPT}")"
eval "$(extract_function load_airgap_splunk_config "${AIRGAP_PREPARE_SCRIPT}")"
eval "$(extract_function append_customer_application_images "${AIRGAP_PREPARE_SCRIPT}")"
eval "$(extract_function resolved_application_image "${AIRGAP_PREPARE_SCRIPT}")"
eval "$(grep '^readonly OPENSHIFT_ACCELERATOR=' "${SCRIPT}")"

log() { :; }
warn() { :; }
err() { return 1; }

scale_present="false"
scale_value="null"
scale_tag="!!null"
legacy_scale_count="0"
feature_names=""
yq() {
  local expression="${2:-}"
  if [[ "${expression}" == '.aiPlatform.features[].name // ""' ]]; then
    printf '%s\n' "${feature_names}"
  elif [[ "${expression}" == *features* ]]; then
    echo "${legacy_scale_count}"
  elif [[ "${expression}" == *'has("scaleFactor")'* ]]; then
    echo "${scale_present}"
  elif [[ "${expression}" == *'| tag'* ]]; then
    echo "${scale_tag}"
  else
    echo "${scale_value}"
  fi
}
CONFIG_FILE="test-config.yaml"

echo "OpenShift command parity"
_run_validate_config() (
  local strategy="$1" node_count="$2" airgap="$3" registry="$4"
  local operator_manifest="${6:-${SCRIPT}}"
  SPLUNK_ENABLED="${5:-true}"
  need() { :; }
  load_config() {
    AI_NS="ai-platform"
    OBJ_STORE_TYPE="minio"
    OBJ_STORE_BUCKET="models"
    OBJ_STORE_ENDPOINT="http://minio.example:9000"
    OBJ_STORE_REGION=""
    MINIO_ROOT_USER="access-key"
    MINIO_ROOT_PASSWORD="secret-key"
    NODE_LABEL_STRATEGY="${strategy}"
    SPLUNK_AI_FILE="${SCRIPT}"
    SPLUNK_OPERATOR_FILE="${operator_manifest}"
    AIRGAP_MODE="${airgap}"
    IMAGE_REGISTRY="${registry}"
  }
  validate_image_config() { :; }
  resolve_accelerator_type() { :; }
  yq() {
    case "${2:-}" in
      *'.openshift.nodes'*) echo "${node_count}" ;;
      *) echo "" ;;
    esac
  }
  validate_config
)
assert_rc "validate accepts a complete manual-node configuration" 0 \
  _run_validate_config manual 1 false registry.example.com
assert_rc "validate rejects manual selection without nodes" 1 \
  _run_validate_config manual 0 false registry.example.com
assert_rc "validate rejects an unsupported node-label strategy" 1 \
  _run_validate_config unsupported 0 false registry.example.com
assert_rc "validate requires a registry for air-gapped installation" 1 \
  _run_validate_config auto 0 true ""

clean_output=$(
  warn() { printf 'warning:%s\n' "$*"; }
  main_delete() { echo "main-delete"; }
  clean_all
)
assert_eq "clean-all delegates to the ownership-aware OpenShift delete" "1" \
  "$(grep -c '^main-delete$' <<<"${clean_output}" || true)"
assert_eq "clean-all explains that OpenShift nodes are preserved" "1" \
  "$(grep -c 'cluster and its nodes are preserved' <<<"${clean_output}" || true)"

_run_verify_pods() (
  local desired_rc="$1" auto_diagnose="$2"
  AUTO_DIAGNOSE="${auto_diagnose}"
  verify_all_pods_healthy() { return "${desired_rc}"; }
  diagnose() { echo "diagnose"; }
  log() { :; }
  run_verify_pods
)
assert_rc "verify-pods returns success for a ready platform" 0 _run_verify_pods 0 true
verify_failure_output=$(_run_verify_pods 1 true 2>&1 || true)
assert_eq "verify-pods diagnoses a readiness failure" "1" \
  "$(grep -c '^diagnose$' <<<"${verify_failure_output}" || true)"
verify_no_diagnose_output=$(_run_verify_pods 1 false 2>&1 || true)
assert_eq "verify-pods honors AUTO_DIAGNOSE=false" "0" \
  "$(grep -c '^diagnose$' <<<"${verify_no_diagnose_output}" || true)"

echo "OpenShift SLIM feature detection"
feature_names=$'saia\nslim'
assert_rc "detects enabled SLIM feature" 0 openshift_slim_feature_enabled
assert_rc "detects enabled SAIA feature" 0 openshift_feature_enabled saia
feature_names="saia"
assert_rc "does not enable SLIM for a SAIA-only config" 1 openshift_slim_feature_enabled

_run_validate_image_config() (
  local slim_enabled="$1" slim_image="$2"
  SPLUNK_ENABLED="${3:-true}"
  OPERATOR_IMAGE="operator:v1"
  RAY_HEAD_IMAGE="ray-head:v1"
  RAY_WORKER_IMAGE="ray-worker:v1"
  WEAVIATE_IMAGE="weaviate:v1"
  SAIA_API_IMAGE="saia:v1"
  SAIA_API_V2_IMAGE="saia-v2:v1"
  SAIA_DATALOADER_IMAGE="loader:v1"
  SLIM_API_IMAGE="${slim_image}"
  SPLUNK_IMAGE="${4-splunk:v1}"
  SPLUNK_OPERATOR_IMAGE="${5-splunk-operator:v1}"
  MODEL_VERSION="model-v1"
  validate_scale_factor_config() { return 0; }
  openshift_slim_feature_enabled() { [[ "${slim_enabled}" == "true" ]]; }
  log() { :; }
  warn() { :; }
  err() { exit 1; }
  validate_image_config
)

echo "OpenShift SLIM image validation"
assert_rc "SAIA-only config does not require a SLIM image" 0 _run_validate_image_config false ""
assert_rc "SLIM-enabled config requires images.slim.apiImage" 1 _run_validate_image_config true ""
assert_rc "SLIM-enabled config accepts its configured image" 0 _run_validate_image_config true "slim-api:v1"


echo "OpenShift optional bundled Splunk validation"
assert_rc "disabled bundled Splunk does not require either Splunk image" 0 \
  _run_validate_image_config false "" false "" ""
assert_rc "enabled bundled Splunk requires its Enterprise image" 1 \
  _run_validate_image_config false "" true "" "splunk-operator:v1"
assert_rc "enabled bundled Splunk requires its Operator image" 1 \
  _run_validate_image_config false "" true "splunk:v1" ""
assert_rc "disabled bundled Splunk does not require its Operator manifest" 0 \
  _run_validate_config auto 0 false registry.example.com false /missing/splunk-operator.yaml
assert_rc "enabled bundled Splunk requires its Operator manifest" 1 \
  _run_validate_config auto 0 false registry.example.com true /missing/splunk-operator.yaml

_disabled_splunk_install_calls() (
  SPLUNK_ENABLED=false
  err() { exit 1; }
  oc() { printf 'unexpected API call: %s\n' "$*"; return 1; }
  ensure_namespace() { printf 'unexpected namespace: %s\n' "$*"; return 1; }
  install_splunk_operator || return
  install_splunk_standalone
)
assert_eq "disabled Splunk installers return without cluster or namespace operations" "" \
  "$(_disabled_splunk_install_calls)"

_optional_splunk_install_flow() (
  local enabled="$1" helper
  for helper in load_config validate_image_config configure_images resolve_accelerator_type \
    resolve_model_staging show_install_plan configure_openshift_insecure_endpoints \
    phase_start phase_end step_start step_ok step_skip preflight_checks \
    initialize_install_state install_nfd install_nvidia_gpu_operator label_nodes \
    install_local_path_provisioner relabel_worker_nodes_for_selinux install_cert_manager \
    install_otel_operator install_ray_operator ensure_ecr_pull_secret \
    apply_openshift_service_annotations normalize_openshift_clusterip_feature_services \
    patch_openshift_slim_public_service_workaround show_step_summary; do
    eval "${helper}() { :; }"
  done
  install_splunk_ai_operator() { echo ai-operator; }
  install_splunk_operator() { echo splunk-operator; }
  install_splunk_standalone() { echo splunk-standalone; }
  install_ai_platform_cr() { echo aiplatform; }
  create_image_pull_secrets() {
    [[ "$1" != splunk-operator ]] || echo splunk-operator-pull-secrets
    return 0
  }
  openshift_route_enabled() { return 1; }
  verify_all_pods_healthy() { return 0; }
  AUTO_APPROVE=true
  MODEL_STAGING_ENABLED=false
  AIRGAP_MODE=false
  AI_NS=ai-platform
  LOG_FILE=test.log
  SPLUNK_ENABLED="${enabled}"
  main_install
)
assert_eq "disabled install still deploys the AI Operator and AIPlatform" \
  $'ai-operator\naiplatform' "$(_optional_splunk_install_flow false)"
assert_eq "enabled install retains bundled Splunk and its pull-secret setup" \
  $'splunk-operator-pull-secrets\nai-operator\nsplunk-operator\nsplunk-standalone\naiplatform' \
  "$(_optional_splunk_install_flow true)"


# CLEANUP_SPLUNK_ENABLED sets the delete-time config. CLEANUP_STATE_READ makes
# the ownership state read succeed (ok), fail (error) or return bad JSON
# (invalid); CLEANUP_STATE_JSON replaces the state it returns. CLEANUP_PROBE=error
# makes the Splunk existence probes fail. CLEANUP_SHOW=state prints what happened
# to the installer state ConfigMap, with the record keys sent to oc replace.
_optional_splunk_cleanup() (
  local owned="$1" namespace_owned="$2" dependencies_owned="${4:-false}" tmp
  # Not named state_json: the real loader's local of that name would hide it.
  local show="${CLEANUP_SHOW:-deletes}" mock_state='{"data":{"aiNamespace":"ai-platform"}}'
  [[ -z "${CLEANUP_STATE_JSON:-}" ]] || mock_state="${CLEANUP_STATE_JSON}"
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' EXIT
  SPLUNK_ENABLED="${CLEANUP_SPLUNK_ENABLED:-false}"
  AUTO_APPROVE=true
  AI_NS=ai-platform
  AI_PLATFORM_NAME=test-platform
  AI_STANDALONE_NAME="${3:-splunk}"
  SPLUNK_OPERATOR_FILE="${SCRIPT}"
  LOG_FILE=test.log
  load_config() { :; }
  verify_install_state_cluster() { :; }
  restore_installer_node_labels() { :; }
  installer_state_name() { echo test-state; }
  manifest_without_namespaces() { echo mocked-splunk-operator-manifest; }
  err() { exit 1; }
  component_is_owned() {
    case "$1" in
      namespace_ai-platform) [[ "${namespace_owned}" == true ]] ;;
      splunk_standalone_splunk|splunk_defaults|splunk_hec_secret) [[ "${owned}" == true ]] ;;
      splunk_operator_bundle_v2|namespace_splunk-operator|scc_anyuid_ai_namespace|scc_privileged_ai_namespace|scc_privileged_splunk_operator)
        [[ "${dependencies_owned}" == true ]]
        ;;
      *) return 1 ;;
    esac
  }
  force_delete_namespace() { printf 'namespace %s\n' "$1" >> "${tmp}/deletes"; }
  oc() {
    case "$*" in
      'get configmap test-state -n openshift-config --ignore-not-found -o json')
        case "${CLEANUP_STATE_READ:-ok}" in
          ok) printf '%s\n' "${mock_state}" ;;
          invalid) echo 'not-json' ;;
          *) return 1 ;;
        esac
        ;;
      # All probed Splunk resources exist, including unowned ones.
      'get '*' --ignore-not-found -o name')
        [[ "${CLEANUP_PROBE:-ok}" == ok ]] || return 1
        echo found
        ;;
      'delete standalone '*) echo standalone >> "${tmp}/deletes" ;;
      'delete configmap splunk-defaults '*) echo defaults >> "${tmp}/deletes" ;;
      'delete secret splunk-ai-platform-secret '*) echo hec >> "${tmp}/deletes" ;;
      'delete secret minio-credentials '*) echo object-store >> "${tmp}/deletes" ;;
      'delete configmap test-state '*) echo state-deleted >> "${tmp}/state" ;;
      'replace -f -') { echo state-pruned; jq -r '.data | keys | join(",")'; } >> "${tmp}/state" ;;
      'delete -f - '*) echo splunk-operator-bundle >> "${tmp}/deletes" ;;
      'adm policy remove-scc-from-group anyuid system:serviceaccounts:ai-platform')
        echo ai-anyuid-scc >> "${tmp}/deletes"
        ;;
      'adm policy remove-scc-from-group privileged system:serviceaccounts:ai-platform')
        echo ai-privileged-scc >> "${tmp}/deletes"
        ;;
      'adm policy remove-scc-from-group privileged system:serviceaccounts:splunk-operator')
        echo splunk-operator-scc >> "${tmp}/deletes"
        ;;
    esac
    return 0
  }
  main_delete || return
  [[ ! -f "${tmp}/${show}" ]] || cat "${tmp}/${show}"
)
assert_eq "disabled cleanup preserves unowned Splunk resources and their previously marked namespace" "" \
  "$(_optional_splunk_cleanup false true)"
assert_eq "disabled cleanup can remove previously recorded owned Splunk resources" \
  $'standalone\ndefaults\nhec\nobject-store' "$(_optional_splunk_cleanup true false)"
assert_eq "changing the configured Standalone name preserves it and its configuration dependencies" "" \
  "$(_optional_splunk_cleanup true true different-splunk)"
assert_eq "retaining an unowned Standalone also preserves owned Splunk CRDs, namespaces, SCC grants and object storage credentials" "" \
  "$(_optional_splunk_cleanup false true splunk true)"
assert_eq "owned Splunk cleanup still removes its bundle, SCC grants and object storage credentials" \
  $'standalone\ndefaults\nhec\nobject-store\nsplunk-operator-bundle\nnamespace splunk-operator\nai-anyuid-scc\nai-privileged-scc\nsplunk-operator-scc' \
  "$(_optional_splunk_cleanup true false splunk true)"
assert_eq "an enabled delete-time config does not remove unowned Splunk resources" "" \
  "$(CLEANUP_SPLUNK_ENABLED=true _optional_splunk_cleanup false true)"
assert_eq "state without Splunk records does not authorize deleting unrecorded Splunk from older installers" "" \
  "$(_optional_splunk_cleanup false false)"

# Ownership read failures must abort cleanup, not read as "not owned".
_cleanup_with_state_read() { CLEANUP_STATE_READ="$1" _optional_splunk_cleanup true true; }
assert_rc "an unreadable ownership state refuses deletion" 1 _cleanup_with_state_read error
assert_eq "an unreadable ownership state deletes nothing" "" "$(_cleanup_with_state_read error)"
assert_rc "an invalid ownership state refuses deletion" 1 _cleanup_with_state_read invalid
assert_eq "an invalid ownership state deletes nothing" "" "$(_cleanup_with_state_read invalid)"
assert_eq "a failed Splunk existence probe keeps the namespace and Splunk dependencies" "" \
  "$(CLEANUP_PROBE=error _optional_splunk_cleanup false true)"

_owned_from_snapshot() (
  INSTALL_STATE_SNAPSHOT="$1"
  installer_state_name() { echo test-state; }
  oc() { echo unexpected-oc-call; return 1; }
  if component_is_owned "$2"; then echo owned; else echo not-owned; fi
)
assert_eq "delete-time ownership comes from the validated snapshot" owned \
  "$(_owned_from_snapshot '{"data":{"kuberay_operator":"true"}}' kuberay_operator)"
assert_eq "a missing installer state owns nothing" not-owned \
  "$(_owned_from_snapshot none kuberay_operator)"

assert_eq "retained Splunk keeps a pruned installer state instead of deleting it" $'state-pruned\naiNamespace' \
  "$(CLEANUP_SHOW=state _optional_splunk_cleanup false true splunk true)"
assert_eq "full cleanup still deletes the installer state" "state-deleted" \
  "$(CLEANUP_SHOW=state _optional_splunk_cleanup true false)"
# Owned Standalone A survives when the config names unowned Standalone B.
assert_eq "pruning keeps the ownership record of a surviving owned Standalone" \
  $'state-pruned\naiNamespace,splunk_standalone_splunk' \
  "$(CLEANUP_SHOW=state CLEANUP_STATE_JSON='{"data":{"aiNamespace":"ai-platform","splunk_standalone_splunk":"true","kuberay_operator":"true"}}' \
    _optional_splunk_cleanup true true different-splunk)"
assert_eq "pruned installer state keeps records of retained resources and drops the deleted Standalone" \
  "aiNamespace,namespace_ai-platform,scc_privileged_ai_namespace,splunk_operator_bundle_v2,splunk_standalone_other" \
  "$(printf '%s' '{"data":{"aiNamespace":"ai-platform","namespace_ai-platform":"true","scc_privileged_ai_namespace":"true","splunk_operator_bundle_v2":"true","kuberay_operator":"true","cert_manager":"true","splunk_standalone_splunk":"true","splunk_standalone_other":"true"}}' \
    | retain_splunk_ownership_records namespace_ai-platform splunk_standalone_splunk | jq -r '.data | keys | join(",")')"

_mutable_image_warnings() (
  SLIM_API_IMAGE="$1"
  warn() { printf '%s\n' "$*"; }
  warn_on_mutable_image_tags
)

echo "OpenShift mutable image tag warnings"
mutable_output=$(_mutable_image_warnings "slim-api:latest")
assert_eq "warns when the SLIM image uses a mutable tag" "1" \
  "$(grep -c 'images.slim.apiImage.*mutable tag' <<<"${mutable_output}" || true)"
immutable_output=$(_mutable_image_warnings "slim-api:v0.0.4")
assert_eq "does not warn for an immutable SLIM image tag" "0" \
  "$(grep -c 'images.slim.apiImage' <<<"${immutable_output}" || true)"

_run_slim_nodeport_patch() (
  AI_NS="ai-platform"
  AI_PLATFORM_NAME="test-platform"
  CONFIG_FILE="test-config.yaml"
  local oc_call_log
  oc_call_log=$(mktemp)
  openshift_slim_feature_enabled() { return 0; }
  yq() {
    case "${2:-}" in
      '.aiPlatform.serviceTemplate.type // ""') echo "NodePort" ;;
      '.aiPlatform.serviceTemplate.nodePort // ""') echo "30080" ;;
      '.aiPlatform.serviceTemplate.slimNodePort // ""') echo "30081" ;;
      *) echo "" ;;
    esac
  }
  oc() { printf 'oc %s\n' "$*" >> "${oc_call_log}"; }
  patch_openshift_slim_public_service_workaround
  cat "${oc_call_log}"
  rm -f "${oc_call_log}"
)

echo "OpenShift SLIM NodePort patch"
slim_patch_output=$(_run_slim_nodeport_patch)
assert_eq "patches the generated SLIM AIService" "1" \
  "$(grep -c 'patch aiservice test-platform-slim' <<<"${slim_patch_output}" || true)"
assert_eq "uses the configured distinct SLIM NodePort" "1" \
  "$(grep -c '\"nodePort\": 30081' <<<"${slim_patch_output}" || true)"
assert_eq "recreates only the SLIM public Service" "1" \
  "$(grep -c 'delete svc test-platform-slim-slim-service' <<<"${slim_patch_output}" || true)"

_run_clusterip_normalization() (
  AI_NS="ai-platform"
  AI_PLATFORM_NAME="test-platform"
  CONFIG_FILE="test-config.yaml"
  local oc_call_log recreated_marker
  oc_call_log=$(mktemp)
  recreated_marker=$(mktemp)
  rm -f "${recreated_marker}"
  yq() {
    case "${2:-}" in
      '.aiPlatform.serviceTemplate.type // ""') echo "ClusterIP" ;;
      '.aiPlatform.features | length') echo "1" ;;
      '.aiPlatform.features[0].name // ""') echo "slim" ;;
      *) echo "" ;;
    esac
  }
  oc() {
    printf 'oc %s\n' "$*" >> "${oc_call_log}"
    if [[ "$*" == *'get svc test-platform-slim-slim-service'*jsonpath* ]]; then
      [[ -f "${recreated_marker}" ]] && echo "ClusterIP" || echo "NodePort"
    elif [[ "$*" == *'delete svc test-platform-slim-slim-service'* ]]; then
      : > "${recreated_marker}"
    fi
    return 0
  }
  normalize_openshift_clusterip_feature_services
  cat "${oc_call_log}"
  rm -f "${oc_call_log}" "${recreated_marker}"
)

echo "OpenShift ClusterIP convergence"
clusterip_output=$(_run_clusterip_normalization)
assert_eq "patches a preserved SLIM exposure override back to ClusterIP" "1" \
  "$(grep -c 'patch aiservice test-platform-slim' <<<"${clusterip_output}" || true)"
assert_eq "writes ClusterIP into the AIService exposure override" "1" \
  "$(grep -c '"type": "ClusterIP"' <<<"${clusterip_output}" || true)"
assert_eq "recreates a legacy SLIM NodePort Service" "1" \
  "$(grep -c 'delete svc test-platform-slim-slim-service' <<<"${clusterip_output}" || true)"

_render_feature_route() (
  local feature="$1"
  AI_NS="ai-platform"
  INGRESS_DOMAIN="apps.example.com"
  CONFIG_FILE="test-config.yaml"
  yq() { echo ""; }
  oc() {
    if [[ "${1:-}" == "apply" ]]; then
      cat
    elif [[ "${1:-}" == "get" && "${2:-}" == "route" ]]; then
      return 0
    else
      return 1
    fi
  }
  create_openshift_feature_route \
    "${feature}" "${feature}" "test-platform-${feature}-${feature}-service"
)

echo "OpenShift feature Routes"
slim_route=$(_render_feature_route slim)
assert_eq "creates a SLIM Route" "1" \
  "$(grep -c '^  name: slim$' <<<"${slim_route}" || true)"
assert_eq "derives a stable SLIM ingress host" "1" \
  "$(grep -c '^  host: slim.apps.example.com$' <<<"${slim_route}" || true)"
assert_eq "targets the generated SLIM Service" "1" \
  "$(grep -c '^    name: test-platform-slim-slim-service$' <<<"${slim_route}" || true)"
assert_eq "routes SLIM to its HTTP service port" "1" \
  "$(grep -c '^    targetPort: 8080$' <<<"${slim_route}" || true)"

echo "OpenShift model artifact config selection"
assert_eq "RTX Pro 6000 uses the quantized artifact manifest" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name rtx_pro_6000_blackwell)"
assert_eq "defaultAcceleratorType values are normalized" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name RTX_PRO_6000_BLACKWELL)"
assert_rc "unsupported artifact accelerator is rejected" 1 model_artifacts_config_name A100

_exercise_airgap_model_staging_resolution() (
  SILENT_INSTALL=false
  AIRGAP_MODE=true
  MODEL_STAGING_ENABLED=true
  resolve_model_staging <<< "yes" >/dev/null 2>&1
  printf '%s' "${MODEL_STAGING_ENABLED}"
)
assert_eq "air-gap mode offers staging from the connected installer machine" \
  "true" "$(_exercise_airgap_model_staging_resolution)"
assert_eq "air-gap model staging is not short-circuited" "0" \
  "$(awk '/^stage_model_artifacts\(\)/,/^}/' "${SCRIPT}" | grep -c 'AIRGAP_MODE=true.*skipping model staging' | tr -d '[:space:]')"

echo "OpenShift Splunk HEC parsing"
hec_btool_output=$'[http]\ndisabled = 0\nenableSSL = true\nport = 8088\n'
assert_eq "reads effective HEC TLS from the global http stanza" "true" \
  "$(printf '%s' "${hec_btool_output}" | _internal_splunk_btool_http_value enableSSL)"
assert_eq "reads effective HEC port" "8088" \
  "$(printf '%s' "${hec_btool_output}" | _internal_splunk_btool_http_value port)"
ambiguous_hec_output=$'[http]\nport = 8088\n[http]\nport = 8089\n'
_parse_ambiguous_hec() { printf '%s' "${ambiguous_hec_output}" | _internal_splunk_btool_http_value port; }
assert_rc "rejects ambiguous effective HEC values" 1 _parse_ambiguous_hec

echo "OpenShift installer safety contracts"
preflight_line=$(grep -n '^[[:space:]]*preflight_checks$' "${SCRIPT}" | head -1 | cut -d: -f1)
staging_line=$(grep -n '^[[:space:]]*stage_model_artifacts$' "${SCRIPT}" | head -1 | cut -d: -f1)
assert_eq "command dispatcher exposes validate" "1" \
  "$(grep -c '^  validate)$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "command dispatcher exposes OpenShift-safe clean-all" "1" \
  "$(grep -c '^  clean-all)$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "command dispatcher exposes verify-pods" "1" \
  "$(grep -c '^  verify-pods)$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "command dispatcher no longer exposes legacy delete" "0" \
  "$(grep -c '^  delete)$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "command dispatcher no longer exposes legacy verify" "0" \
  "$(grep -c '^  verify)' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "main install runs preflight before model downloads" "1" \
  "$(( preflight_line < staging_line ))"
assert_eq "preflight has a fatal summary gate" "1" \
  "$(awk '/^preflight_checks\(\)/,/^}/' "${SCRIPT}" | grep -c '^[[:space:]]*pf_summary$' | tr -d '[:space:]')"
assert_eq "air-gap install verifies pre-staged model markers" "1" \
  "$(awk '/^main_install\(\)/,/^}/' "${SCRIPT}" | grep -c 'verify_pre_staged_model_artifacts' | tr -d '[:space:]')"
assert_eq "AWS model checks use object-store region" "0" \
  "$(grep -F -e 'S3_REGION="${REGION' -e '--region "${REGION' "${SCRIPT}" | wc -l | tr -d '[:space:]')"
assert_eq "normal install gates completion on platform readiness" "1" \
  "$(awk '/^main_install\(\)/,/^}/' "${SCRIPT}" | grep -c 'verify_all_pods_healthy' | tr -d '[:space:]')"
assert_eq "missing derived Splunk HEC secret is fatal" "1" \
  "$(awk '/^install_ai_platform_cr\(\)/,/^}/' "${SCRIPT}" | grep -c 'derived.*Secret cannot be created' | tr -d '[:space:]')"
assert_eq "NFD and GPU reruns validate their exact OLM subscriptions" "2" \
  "$(grep -c '^[[:space:]]*wait_for_subscription_csv .*\(nfd\|gpu-operator-certified\)' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "node-storage preflight derives one scale-aware shared AI-tier threshold" "1" \
  "$(awk '/^preflight_check_node_storage\(\)/,/^}/' "${SCRIPT}" | grep -c 'MIN_DISK_AI_TIER_NODE' | tr -d '[:space:]')"
assert_eq "node-storage preflight does not invent exclusive CPU/GPU roles" "0" \
  "$(awk '/^preflight_check_node_storage\(\)/,/^}/' "${SCRIPT}" | grep -c '0x10de' | tr -d '[:space:]')"
assert_eq "cleanup protects shared components with ownership checks" "1" \
  "$(awk '/^main_delete\(\)/,/^}/' "${SCRIPT}" | grep -c 'component_is_owned cert_manager' | tr -d '[:space:]')"
assert_eq "cleanup targets only this stack's named platform resources" "0" \
  "$(awk '/^main_delete\(\)/,/^}/' "${SCRIPT}" | grep -Ec 'delete (aiplatform|standalone) --all' | tr -d '[:space:]')"
assert_eq "cleanup removes both installer-managed feature Routes" "1" \
  "$(awk '/^main_delete\(\)/,/^}/' "${SCRIPT}" | grep -c 'delete route saia slim' | tr -d '[:space:]')"
assert_eq "Splunk Operator restart does not delete all ReplicaSets" "0" \
  "$(awk '/^install_splunk_operator\(\)/,/^}/' "${SCRIPT}" | grep -Ec 'delete replicaset .*--all' | tr -d '[:space:]')"
assert_eq "Splunk Standalone explicitly configures both PVC storage classes" "2" \
  "$(awk '/^install_splunk_standalone\(\)/,/^}/' "${SCRIPT}" | grep -o 'storageClassName:' | wc -l | tr -d '[:space:]')"
assert_eq "Splunk Standalone readiness detects the live HEC endpoint" "1" \
  "$(awk '/^wait_for_internal_splunk_ready\(\)/,/^}/' "${SCRIPT}" | grep -c '_detect_internal_splunk_hec_url' | tr -d '[:space:]')"
assert_eq "Splunk management readiness accepts the expected unauthenticated 401 response" "0" \
  "$(awk '/^wait_for_internal_splunk_ready\(\)/,/^}/' "${SCRIPT}" | grep -c -- '--fail' | tr -d '[:space:]')"
assert_eq "feature Route creation remains compatible with Bash 3.2" "0" \
  "$(awk '/^create_openshift_feature_route\(\)/,/^}/' "${SCRIPT}" | grep -c '\^\^' | tr -d '[:space:]')"
assert_eq "OpenTelemetry Operator chart is pinned" "1" \
  "$(grep -c '^readonly OTEL_OPERATOR_CHART_VERSION="0.121.0"$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap bundle pins the same OpenTelemetry chart" "1" \
  "$(grep -c '^OTEL_CHART_VERSION="0.121.0"$' "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap bundle does not resolve a mutable latest OpenTelemetry chart" "0" \
  "$(grep -c 'helm search repo open-telemetry/opentelemetry-operator' "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "qualified Ray runtime matches the published Ray images" "1" \
  "$(grep -c '^readonly QUALIFIED_RAY_RUNTIME_VERSION="2.56.0"$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap prerequisites scope AWS CLI to AWS S3 storage" "1" \
  "$(grep -c 'aws.*storage.objectStore.type=aws' "${SCRIPT_DIR}/install_from_airgap_bundle_openshift.sh" | tr -d '[:space:]')"
assert_eq "qualified OpenShift minor is an immutable installer constant" "1" \
  "$(grep -c '^readonly QUALIFIED_OPENSHIFT_MINOR="4.21"$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "configured OpenShift minor cannot override qualification" "1" \
  "$(awk '/^load_config\(\)/,/^}/' "${SCRIPT}" | grep -c 'cannot override the installer qualification' | tr -d '[:space:]')"
assert_eq "air-gap bundle does not duplicate repository model metadata" "0" \
  "$(grep -c 'cp .*MODEL_METADATA_SOURCE.*model-metadata' "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap wrapper does not override the repository model profile" "0" \
  "$(grep -c '^export MODEL_ARTIFACTS_CONFIG_DIR=.*model-metadata' "${AIRGAP_INSTALL_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap bundle captures Operator packages with oc-mirror v2" "1" \
  "$(grep -c '^apiVersion: mirror.openshift.io/v2alpha1' "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap bundle records customer-provided application images separately" "1" \
  "$(grep -c 'sort -u .*customer-provided-images.txt' "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap wrapper imports bundled images into the configured registry" "1" \
  "$(grep -c -- '--from.*BUNDLE_DIR.*/mirror' "${AIRGAP_INSTALL_SCRIPT}" | tr -d '[:space:]')"
assert_eq "same-host air-gap preparation skips the duplicate transfer archive" "1" \
  "$(awk '/^delegate_airgap_install_if_needed\(\)/,/^}/' "${SCRIPT}" | grep -c -- '--no-archive' | tr -d '[:space:]')"
assert_eq "air-gap wrapper accepts a prepared bundle directory" "1" \
  "$(grep -c 'Reusing prepared bundle directory directly' "${AIRGAP_INSTALL_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap wrapper applies generated OpenShift mirror resources" "1" \
  "$(grep -c '^apply_generated_mirror_resources()' "${AIRGAP_INSTALL_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap preparation avoids the oc-mirror REGISTRY_AUTH_FILE parser conflict" "1" \
  "$(grep -c '^env -u REGISTRY_AUTH_FILE "\${MIRROR_CMD\[@\]}"$' "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap import avoids the oc-mirror REGISTRY_AUTH_FILE parser conflict" "1" \
  "$(grep -c 'env -u REGISTRY_AUTH_FILE "\${MIRROR_CMD\[@\]}"' "${AIRGAP_INSTALL_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap import retries transient registry upload failures" "1" \
  "$(grep -c 'oc-mirror import failed after.*attempts' "${AIRGAP_INSTALL_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap import allows slow large-image uploads" "1" \
  "$(awk '/^import_bundled_images\(\)/,/^}/' "${AIRGAP_INSTALL_SCRIPT}" | grep -c -- '--image-timeout 30m' | tr -d '[:space:]')"
assert_eq "air-gap bundle excludes the mutable oc-mirror workspace from checksums" "1" \
  "$(grep -c "! -path './mirror/working-dir/\*'" "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap retries ignore runtime oc-mirror workspace checksum changes" "2" \
  "$(awk '/^verify_checksums\(\)/,/^}/' "${AIRGAP_INSTALL_SCRIPT}" | grep -c "grep -vE.*mirror/working-dir" | tr -d '[:space:]')"
assert_eq "air-gap preparation tolerates unavailable source signature objects" "1" \
  "$(grep -c 'MIRROR_CMD=.*--remove-signatures' "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap import does not require detached signature storage" "1" \
  "$(awk '/^import_bundled_images\(\)/,/^}/' "${AIRGAP_INSTALL_SCRIPT}" | grep -c -- '--remove-signatures' | tr -d '[:space:]')"
assert_eq "air-gap preparation does not expose an assets-only mode" "0" \
  "$(grep -c -- '--assets-only' "${AIRGAP_PREPARE_SCRIPT}" || true)"
assert_eq "air-gap wrapper does not expose a pre-mirrored mode" "0" \
  "$(grep -c -- '--skip-image-import' "${AIRGAP_INSTALL_SCRIPT}" || true)"
assert_eq "normal install checks for OpenShift air-gap delegation" "1" \
  "$(grep -c '^delegate_airgap_install_if_needed "\${_CMD}" "\$@"$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap wrapper sets the staged recursion guard" "1" \
  "$(grep -c '^export AIRGAP_STAGED="true"$' "${AIRGAP_INSTALL_SCRIPT}" | tr -d '[:space:]')"
assert_eq "normal install automatically configures explicitly insecure endpoints" "1" \
  "$(awk '/^main_install\(\)/,/^}/' "${SCRIPT}" | grep -c 'configure_openshift_insecure_endpoints' | tr -d '[:space:]')"
assert_eq "unified air-gap entry point prepares registry authentication" "1" \
  "$(awk '/^delegate_airgap_install_if_needed\(\)/,/^}/' "${SCRIPT}" | grep -c 'prepare_airgap_registry_auth_file' | tr -d '[:space:]')"
assert_eq "OpenShift insecure registry configuration preserves existing entries" "1" \
  "$(awk '/^configure_openshift_insecure_endpoints\(\)/,/^}/' "${SCRIPT}" | grep -c 'insecureRegistries.*unique' | tr -d '[:space:]')"
assert_eq "air-gap import defaults omitted registryInsecure to true" "1" \
  "$(awk '/^import_bundled_images\(\)/,/^}/' "${AIRGAP_INSTALL_SCRIPT}" | grep -c "images.registryInsecure'.*echo true" | tr -d '[:space:]')"
assert_eq "standard air-gap README does not require manual registry auth export" "0" \
  "$(grep -c '^export \(AIRGAP_\)\?REGISTRY_AUTH_FILE=' "${OPENSHIFT_README}" | tr -d '[:space:]')"
assert_eq "Splunk Operator ownership checks every manifest resource" "1" \
  "$(awk '/^install_splunk_operator\(\)/,/^}/' "${SCRIPT}" | grep -c 'manifest_has_existing_resources' | tr -d '[:space:]')"
assert_eq "Splunk Operator ownership is not inferred from deployment presence" "0" \
  "$(awk '/^install_splunk_operator\(\)/,/^}/' "${SCRIPT}" | grep -c 'operator_existed' | tr -d '[:space:]')"
assert_eq "node restoration annotations are namespace-qualified" "1" \
  "$(awk '/^set_installer_node_label\(\)/,/^}/' "${SCRIPT}" | grep -c '\${AI_NS}\.installer\.splunk\.com/previous-' | tr -d '[:space:]')"
assert_eq "disconnected preflight validates mirror source coverage" "1" \
  "$(awk '/^preflight_check_airgap_prerequisites\(\)/,/^}/' "${SCRIPT}" | grep -c 'mirror_sources_cover_repository' | tr -d '[:space:]')"
assert_eq "OLM readiness requires currentCSV to become installedCSV" "1" \
  "$(awk '/^wait_for_subscription_csv\(\)/,/^}/' "${SCRIPT}" | grep -c 'installed_csv.*==.*current_csv' | tr -d '[:space:]')"
assert_eq "non-AWS Splunk app repositories use the MinIO provider" "1" \
  "$(awk '/^install_splunk_standalone\(\)/,/^}/' "${SCRIPT}" | grep -c 'splunk_app_repo_provider="minio"' | tr -d '[:space:]')"
assert_eq "Splunk app repository polling is configured explicitly" "1" \
  "$(awk '/^install_splunk_standalone\(\)/,/^}/' "${SCRIPT}" | grep -c 'appsRepoPollIntervalSeconds: 60' | tr -d '[:space:]')"
assert_eq "OpenShift object-store Routes resolve to cluster-local services" "1" \
  "$(grep -c '^openshift_route_service_endpoint()' "${SCRIPT}" | tr -d '[:space:]')"

_exercise_airgap_delegation() (
  local mode="$1" tmp trace config bundle=""
  tmp=$(mktemp -d)
  trace="${tmp}/trace.log"
  config="${tmp}/config.yaml"

  cat > "${config}" <<'YAML'
cluster:
  airgap: true
YAML

  cat > "${tmp}/prepare_airgap_bundle_openshift.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
output_dir=""
no_archive="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) shift 2 ;;
    --output-dir) output_dir="$2"; shift 2 ;;
    --no-archive) no_archive="true"; shift ;;
    *) exit 2 ;;
  esac
done
mkdir -p "${output_dir}/airgap-bundle-openshift-test"
printf 'prepare no_archive=%s\n' "${no_archive}" >> "${TRACE_FILE}"
SCRIPT

  cat > "${tmp}/install_from_airgap_bundle_openshift.sh" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  chmod +x \
    "${tmp}/prepare_airgap_bundle_openshift.sh" \
    "${tmp}/install_from_airgap_bundle_openshift.sh"

  if [[ "${mode}" == "existing" ]]; then
    bundle="${tmp}/transferred-airgap-bundle.tar.gz"
    : > "${bundle}"
    export OPENSHIFT_AIRGAP_BUNDLE="${bundle}"
  else
    unset OPENSHIFT_AIRGAP_BUNDLE
  fi

  export TRACE_FILE="${trace}"
  CONFIG_FILE="${config}"
  OPENSHIFT_AIRGAP_PREPARE_SCRIPT="${tmp}/prepare_airgap_bundle_openshift.sh"
  OPENSHIFT_AIRGAP_INSTALL_SCRIPT="${tmp}/install_from_airgap_bundle_openshift.sh"
  OPENSHIFT_AIRGAP_OUTPUT_DIR="${tmp}/output"
  OPENSHIFT_AIRGAP_EXTRACT_DIR="${tmp}/extract"
  AIRGAP_MODE="false"
  AIRGAP_STAGED="false"
  SILENT_INSTALL="false"
  uname() { echo Linux; }
  configure_openshift_insecure_endpoints() { :; }
  prepare_airgap_registry_auth_file() { :; }
  yq() {
    case "${2:-}" in
      '.cluster.airgap // "false"') echo "true" ;;
      *) echo "" ;;
    esac
  }
  exec() {
    printf 'wrapper %s\n' "$*" >> "${trace}"
    printf 'silent=%s\n' "${SILENT_INSTALL:-false}" >> "${trace}"
  }

  delegate_airgap_install_if_needed install --silent

  cat "${trace}"
  rm -rf "${tmp}"
)

echo "OpenShift unified air-gap entry point"
auto_airgap_trace=$(_exercise_airgap_delegation auto)
assert_eq "air-gap install automatically prepares a bundle when none is supplied" "1" \
  "$(grep -c '^prepare no_archive=true$' <<<"${auto_airgap_trace}" || true)"
assert_eq "air-gap install delegates the prepared directory to the wrapper" "1" \
  "$(grep -c 'wrapper .*--bundle .*airgap-bundle-openshift-test .*--subcommand install' <<<"${auto_airgap_trace}" || true)"
assert_eq "same-host prepared directories are not assigned an extraction directory" "0" \
  "$(grep -c 'wrapper .*airgap-bundle-openshift-test.*--extract-dir' <<<"${auto_airgap_trace}" || true)"
assert_eq "air-gap delegation preserves silent install mode" "silent=true" \
  "$(grep '^silent=' <<<"${auto_airgap_trace}" || true)"

existing_airgap_trace=$(_exercise_airgap_delegation existing)
assert_eq "a transferred bundle skips automatic bundle preparation" "0" \
  "$(grep -c '^prepare ' <<<"${existing_airgap_trace}" || true)"
assert_eq "a transferred bundle is passed directly to the wrapper" "1" \
  "$(grep -c 'wrapper .*--bundle .*transferred-airgap-bundle.tar.gz.*--subcommand install' <<<"${existing_airgap_trace}" || true)"
assert_eq "a transferred archive receives an extraction directory" "1" \
  "$(grep -c 'wrapper .*transferred-airgap-bundle.tar.gz.*--extract-dir' <<<"${existing_airgap_trace}" || true)"

echo "OpenShift k0s-style insecure endpoints"
assert_eq "normalizes a registry with scheme and repository prefix" \
  "registry.apps.example.com" \
  "$(openshift_endpoint_host 'https://registry.apps.example.com/team/images')"

_exercise_insecure_endpoint_configuration() (
  local registry_insecure="${1:-true}" tmp config route_trace image_patch previous argument
  tmp=$(mktemp -d)
  config="${tmp}/config.yaml"
  route_trace="${tmp}/routes"
  image_patch="${tmp}/image-patch.json"
  cat > "${config}" <<'YAML'
images:
  registry: registry.apps.example.com
YAML
  [[ "${registry_insecure}" == "omitted" ]] || \
    printf '  registryInsecure: %s\n' "${registry_insecure}" >> "${config}"
  cat >> "${config}" <<'YAML'
storage:
  objectStore:
    endpoint: http://minio.apps.example.com
openshift:
  nodeLabelStrategy: manual
  nodes: []
YAML
  yq() { "${REAL_YQ}" "$@"; }
  oc() {
    case "$*" in
      'get routes.route.openshift.io -A -o json')
        printf '%s\n' '{"items":[{"metadata":{"namespace":"ai-infra","name":"registry"},"spec":{"host":"registry.apps.example.com","tls":{"termination":"edge","insecureEdgeTerminationPolicy":"Redirect"}}},{"metadata":{"namespace":"ai-infra","name":"minio-api"},"spec":{"host":"minio.apps.example.com","tls":{"termination":"edge","insecureEdgeTerminationPolicy":"Redirect"}}}]}'
        ;;
      '-n ai-infra patch route registry --type=merge '*|'-n ai-infra patch route minio-api --type=merge '*)
        printf '%s\n' "$*" >> "${route_trace}"
        ;;
      'get image.config.openshift.io/cluster -o json')
        printf '%s\n' '{"spec":{"registrySources":{"insecureRegistries":["existing.example.com"]}}}'
        ;;
      'patch image.config.openshift.io/cluster --type=merge '*)
        previous=""
        for argument in "$@"; do
          [[ "${previous}" == "-p" ]] && printf '%s\n' "${argument}" > "${image_patch}"
          previous="${argument}"
        done
        ;;
      *) return 1 ;;
    esac
  }
  configure_openshift_insecure_endpoints "${config}"
  printf '%s ' "$(wc -l < "${route_trace}" | tr -d '[:space:]')"
  if [[ -s "${image_patch}" ]]; then
    jq -r '(.spec.registrySources.insecureRegistries | sort) == ["existing.example.com","registry.apps.example.com"]' "${image_patch}"
  else
    printf '%s\n' false
  fi
  rm -rf "${tmp}"
)
assert_eq "allows HTTP Routes and preserves existing OpenShift registry policy" \
  "2 true" "$(_exercise_insecure_endpoint_configuration)"
assert_eq "omitted registryInsecure enables the OpenShift insecure registry policy" \
  "2 true" "$(_exercise_insecure_endpoint_configuration omitted)"
assert_eq "explicit registryInsecure false skips the OpenShift insecure registry policy" \
  "1 false" "$(_exercise_insecure_endpoint_configuration false)"

_load_registry_insecure_setting() (
  local registry_insecure="$1" tmp config
  tmp=$(mktemp -d)
  config="${tmp}/config.yaml"
  cat > "${config}" <<'YAML'
images:
  registry: registry.apps.example.com
YAML
  [[ "${registry_insecure}" == "omitted" ]] || \
    printf '  registryInsecure: %s\n' "${registry_insecure}" >> "${config}"
  yq() { "${REAL_YQ}" "$@"; }
  oc() { printf '%s\n' "apps.example.com"; }
  CONFIG_FILE="${config}"
  QUALIFIED_RAY_RUNTIME_VERSION="2.56.0"
  QUALIFIED_OPENSHIFT_MINOR="4.21"
  AIRGAP_MODE="false"
  load_config
  printf '%s\n' "${IMAGE_REGISTRY_INSECURE}"
  rm -rf "${tmp}"
)
assert_eq "load_config defaults omitted registryInsecure to true" "true" \
  "$(_load_registry_insecure_setting omitted)"
assert_eq "load_config preserves explicit registryInsecure false" "false" \
  "$(_load_registry_insecure_setting false)"


_load_optional_splunk_setting() (
  local setting="$1" loader="${2:-load_splunk_config}" tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' EXIT
  CONFIG_FILE="${tmp}/config.yaml"
  if [[ "${setting}" == omitted ]]; then
    printf '{}\n' > "${CONFIG_FILE}"
  else
    printf 'splunk:\n  enabled: %s\n' "${setting}" > "${CONFIG_FILE}"
  fi
  yq() { "${REAL_YQ}" "$@"; }
  SPLUNK_ENABLED=stale
  QUALIFIED_RAY_RUNTIME_VERSION=2.56.0
  QUALIFIED_OPENSHIFT_MINOR=4.21
  AIRGAP_MODE=false
  oc() { printf '%s\n' apps.example.com; }
  "${loader}" || return
  printf '%s\n' "${SPLUNK_ENABLED}"
)

if [[ -n "${REAL_YQ}" ]]; then
  for splunk_loader in load_splunk_config load_config load_airgap_splunk_config; do
    # Same opt-in rule as k0s_cluster_with_stack.sh: only "true" enables Splunk.
    assert_eq "${splunk_loader} defaults omitted enabled to false" false \
      "$(_load_optional_splunk_setting omitted "${splunk_loader}")"
    assert_eq "${splunk_loader} preserves explicit false" false \
      "$(_load_optional_splunk_setting false "${splunk_loader}")"
    assert_eq "${splunk_loader} preserves explicit true" true \
      "$(_load_optional_splunk_setting true "${splunk_loader}")"
    for disabled_setting in '"false"' null 1 True; do
      assert_eq "${splunk_loader} treats ${disabled_setting} as disabled" false \
        "$(_load_optional_splunk_setting "${disabled_setting}" "${splunk_loader}")"
    done
  done
fi

_airgap_customer_inventory() (
  local enabled="$1" tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' EXIT
  CONFIG_FILE="${tmp}/config.yaml"
  cat > "${CONFIG_FILE}" <<'YAML'
images:
  operator:
    image: platform/operator:v1
  splunk:
    image: platform/splunk:v1
    operatorImage: platform/splunk-operator:v1
YAML
  [[ "${enabled}" == omitted ]] || \
    printf 'splunk:\n  enabled: %s\n' "${enabled}" >> "${CONFIG_FILE}"
  yq() { "${REAL_YQ}" "$@"; }
  IMAGE_REGISTRY=registry.example.com
  load_airgap_splunk_config || return
  append_customer_application_images "${tmp}/images.txt" || return
  sort "${tmp}/images.txt"
)
if [[ -n "${REAL_YQ}" ]]; then
  assert_eq "air-gap inventory excludes both disabled Splunk images" \
    registry.example.com/platform/operator:v1 "$(_airgap_customer_inventory false)"
  assert_eq "air-gap inventory retains both enabled Splunk images" \
    $'registry.example.com/platform/operator:v1\nregistry.example.com/platform/splunk-operator:v1\nregistry.example.com/platform/splunk:v1' \
    "$(_airgap_customer_inventory true)"
  assert_eq "air-gap inventory excludes Splunk images when enabled is omitted" \
    "$(_airgap_customer_inventory false)" "$(_airgap_customer_inventory omitted)"
fi

_registry_splunk_probe() (
  local enabled="$1" variable tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp}"' EXIT
  for variable in SAIA_API_IMAGE RAY_HEAD_IMAGE SAIA_API_V2_IMAGE SAIA_DATALOADER_IMAGE \
    SLIM_API_IMAGE RAY_WORKER_IMAGE WEAVIATE_IMAGE FLUENT_BIT_IMAGE OTEL_COLLECTOR_IMAGE \
    NGINX_IMAGE OPERATOR_IMAGE; do
    printf -v "${variable}" '%s' quay.io/platform/other:v1
  done
  SPLUNK_ENABLED="${enabled}"
  SPLUNK_IMAGE=platform/splunk:v1
  SPLUNK_OPERATOR_IMAGE=platform/splunk-operator:v1
  IMAGE_REGISTRY=registry.example.com
  IMAGE_REGISTRY_INSECURE=false
  IMAGE_PULL_SECRETS_DOCKERHUB_ENABLED=false
  IMAGE_PULL_SECRETS_ACR_ENABLED=false
  IMAGE_PULL_SECRETS_CUSTOM_ENABLED=false
  pf_header() { :; }
  pf_ok() { :; }
  pf_warn() { :; }
  pf_fail() { return 1; }
  curl() { printf '%s\n' "$*" >> "${tmp}/curl.log"; printf 200; }
  preflight_check_registry
  grep -c '/manifests/' "${tmp}/curl.log" || true
)
assert_eq "disabled Splunk images are excluded from private-registry manifest probes" 0 \
  "$(_registry_splunk_probe false)"
assert_eq "enabled Splunk images remain eligible for private-registry manifest probes" 1 \
  "$(_registry_splunk_probe true)"

_preflight_insecure_registry_without_registry() (
  local headers=0
  pf_header() { headers=$((headers + 1)); }
  pf_ok() { :; }
  pf_fail() { :; }
  openshift_endpoint_host() { :; }
  oc() { printf '%s\n' '{"spec":{"registrySources":{"insecureRegistries":[]}}}'; }
  jq() { :; }
  IMAGE_REGISTRY_INSECURE="true"
  IMAGE_REGISTRY=""
  preflight_check_insecure_registry_policy
  printf '%s\n' "${headers}"
)
assert_eq "insecure-registry preflight skips an empty registry" "0" \
  "$(_preflight_insecure_registry_without_registry)"

_exercise_auto_registry_auth() (
  local tmp config source_auth custom_auth
  tmp=$(mktemp -d)
  config="${tmp}/config.yaml"
  cat > "${config}" <<'YAML'
imagePullSecrets:
  custom:
    enabled: true
    server: https://registry.apps.example.com
    username: registry-user
    password: registry-password
YAML
  source_auth='{"auths":{"registry.redhat.io":{"auth":"redhat-token"}}}'
  PULL_SECRET_ENCODED=$(printf '%s' "${source_auth}" | base64 | tr -d '\n')
  oc() {
    printf '{"data":{".dockerconfigjson":"%s"}}\n' "${PULL_SECRET_ENCODED}"
  }
  yq() { "${REAL_YQ}" "$@"; }
  TMP_FILES=()
  unset REGISTRY_AUTH_FILE
  unset OPENSHIFT_AUTO_REGISTRY_AUTH_FILE
  prepare_airgap_registry_auth_file "${config}"
  custom_auth=$(printf '%s' 'registry-user:registry-password' | base64 | tr -d '\n')
  jq -r --arg expected "${custom_auth}" \
    '[(.auths["registry.redhat.io"].auth == "redhat-token"), (.auths["registry.apps.example.com"].auth == $expected)] | all' \
    "${REGISTRY_AUTH_FILE}"
  ((${#TMP_FILES[@]} == 0)) || rm -f "${TMP_FILES[@]}"
  rm -rf "${tmp}"
)
assert_eq "merges cluster pull-secret and custom internal-registry credentials" \
  "true" "$(_exercise_auto_registry_auth)"

echo "OpenShift disconnected mirror source matching"
assert_eq "qualifies a Docker Hub organization image for oc-mirror" \
  "docker.io/rancher/local-path-provisioner:v0.0.26" \
  "$(qualified_additional_image 'rancher/local-path-provisioner:v0.0.26')"
assert_eq "preserves an explicitly qualified registry image" \
  "quay.io/kuberay/operator:v1.2.2" \
  "$(qualified_additional_image 'quay.io/kuberay/operator:v1.2.2')"
mirror_sources=$'registry.redhat.io/openshift4\nnvcr.io/nvidia'
assert_rc "accepts a required repository covered by a parent mirror source" 0 \
  mirror_sources_cover_repository "${mirror_sources}" "nvcr.io/nvidia/cloud-native/gpu-operator"
assert_rc "rejects an unrelated mirror source" 1 \
  mirror_sources_cover_repository "${mirror_sources}" "quay.io/unrelated/application"

_operator_repositories_fixture() (
  oc() {
    printf '%s\n' '{"items":[{"metadata":{"name":"gpu-operator-certified"},"status":{"catalogSource":"certified-operators","channels":[{"name":"v26.3","currentCSVDesc":{"containerImage":"registry.connect.redhat.com/nvidia/gpu-operator:v26.3","relatedImages":["nvcr.io/nvidia/driver@sha256:abc",{"image":"nvcr.io/nvidia/k8s-device-plugin:v1"}]}}]}}]}'
  }
  operator_package_repositories gpu-operator-certified certified-operators v26.3
)
assert_eq "reads string and object relatedImages from PackageManifest" \
  $'nvcr.io/nvidia/driver\nnvcr.io/nvidia/k8s-device-plugin\nregistry.connect.redhat.com/nvidia/gpu-operator' \
  "$(_operator_repositories_fixture)"

_subscription_upgrade_waits_for_target() (
  local polls=0
  log() { :; }
  sleep() { polls=$((polls + 1)); }
  err() { return 1; }
  oc() {
    if [[ "${2:-}" == "subscription" && "$*" == *currentCSV* ]]; then
      echo new.v2
    elif [[ "${2:-}" == "subscription" && "$*" == *installedCSV* ]]; then
      (( polls == 0 )) && echo old.v1 || echo new.v2
    elif [[ "${2:-}" == "csv" && "$*" == *status.phase* ]]; then
      echo Succeeded
    else
      return 1
    fi
  }
  wait_for_subscription_csv operators test-subscription 30
  echo "${polls}"
)
assert_eq "waits while currentCSV has not become installedCSV" "1" \
  "$(_subscription_upgrade_waits_for_target)"

_manifest_inventory_result() (
  local mode="$1"
  warn() { :; }
  manifest_without_namespaces() { printf '%s\n' 'apiVersion: apps/v1' 'kind: Deployment'; }
  oc() { [[ "${mode}" == "existing" ]] && echo deployment.apps/existing; return 0; }
  manifest_has_existing_resources manifest.yaml
)
assert_rc "treats any existing manifest resource as pre-existing ownership" 0 \
  _manifest_inventory_result existing
assert_rc "allows exclusive ownership only when no manifest resource exists" 1 \
  _manifest_inventory_result absent

_exercise_platform_snapshot() (
  local mode="$1"
  SPLUNK_ENABLED="${2:-true}"
  AI_STANDALONE_NAME=test-splunk
  AI_NS="ai-platform"
  AI_PLATFORM_NAME="test-platform"
  CONFIG_FILE="test-config.yaml"
  PLATFORM_PENDING_REASON=""
  yq() {
    case "${2:-}" in
      '.aiPlatform.features | length') echo 1 ;;
      '.aiPlatform.features[].name // ""') echo saia ;;
      *) echo "" ;;
    esac
  }
  oc() {
    case "${2:-}" in
      pods)
        if [[ "${mode}" == "ready" ]]; then
          printf '%s\n' '{"items":[{"metadata":{"name":"ready-pod"},"status":{"phase":"Running","containerStatuses":[{"ready":true}]}}]}'
        elif [[ "${mode}" == splunk-pending ]]; then
          printf '%s\n' '{"items":[{"metadata":{"name":"existing-splunk","labels":{"app.kubernetes.io/managed-by":"splunk-operator"}},"status":{"phase":"Pending","containerStatuses":[{"ready":false}]}}]}'
        elif [[ "${mode}" == standalone-pending ]]; then
          printf '%s\n' '{"items":[{"metadata":{"name":"existing-splunk","ownerReferences":[{"kind":"StatefulSet","name":"splunk-test-splunk-standalone"}]},"status":{"phase":"Pending","containerStatuses":[{"ready":false}]}}]}'
        else
          printf '%s\n' '{"items":[{"metadata":{"name":"pending-pod"},"status":{"phase":"Pending","containerStatuses":[{"ready":false,"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}]}'
        fi
        ;;
      aiplatform)
        if [[ "${mode}" == "stale-platform" ]]; then
          printf '%s\n' '{"metadata":{"name":"test-platform","generation":2},"status":{"observedGeneration":1,"rayServiceName":"test-platform","conditions":[{"type":"Ready","status":"True"}]}}'
        else
          printf '%s\n' '{"metadata":{"name":"test-platform","generation":2},"status":{"observedGeneration":2,"rayServiceName":"test-platform","conditions":[{"type":"Ready","status":"True"}]}}'
        fi
        ;;
      aiservice)
        [[ "${3:-}" == "test-platform-saia" ]] || return 1
        if [[ "${mode}" == "stale-service" ]]; then
          printf '%s\n' '{"metadata":{"name":"test-platform-saia","generation":3},"status":{"observedGeneration":2,"conditions":[{"type":"Ready","status":"True"}]}}'
        else
          printf '%s\n' '{"metadata":{"name":"test-platform-saia","generation":3},"status":{"observedGeneration":3,"conditions":[{"type":"Ready","status":"True"}]}}'
        fi
        ;;
      rayservice)
        [[ "${3:-}" == "test-platform" ]] || return 1
        printf '%s\n' '{"metadata":{"name":"test-platform"},"status":{"serviceStatus":"Running","activeServiceStatus":{"rayClusterName":"test-platform-cluster"}}}'
        ;;
      raycluster)
        [[ "${3:-}" == "test-platform-cluster" ]] || return 1
        printf '%s\n' '{"metadata":{"name":"test-platform-cluster"},"status":{"state":"ready","desiredWorkerReplicas":1,"readyWorkerReplicas":1}}'
        ;;
      *) return 1 ;;
    esac
  }
  platform_readiness_snapshot
)
assert_rc "accepts a fully Ready platform snapshot" 0 _exercise_platform_snapshot ready
assert_rc "rejects a Pending pod despite Ready CRs" 1 _exercise_platform_snapshot pending
assert_rc "rejects stale AIPlatform status from a prior generation" 1 _exercise_platform_snapshot stale-platform
assert_rc "rejects stale AIService status from a prior generation" 1 _exercise_platform_snapshot stale-service
assert_rc "disabled readiness ignores pre-existing Splunk Operator-managed pods" 0 \
  _exercise_platform_snapshot splunk-pending false
assert_rc "disabled readiness ignores pods owned by the configured Splunk Standalone" 0 \
  _exercise_platform_snapshot standalone-pending false
assert_rc "enabled readiness still checks bundled Splunk pods" 1 \
  _exercise_platform_snapshot splunk-pending true
assert_rc "disabled readiness still rejects unhealthy AI workload pods" 1 \
  _exercise_platform_snapshot pending false

echo "OpenShift accelerator validation"
DEFAULT_ACCELERATOR=""
assert_rc "omitted accelerator defaults to RTX Pro 6000" 0 resolve_accelerator_type
assert_eq "omitted accelerator resolves to the supported value" \
  "RTX_PRO_6000_BLACKWELL" "${DEFAULT_ACCELERATOR}"
DEFAULT_ACCELERATOR="rtx_pro_6000_blackwell"
assert_rc "lowercase RTX Pro 6000 is normalized" 0 resolve_accelerator_type
assert_eq "configured accelerator is canonicalized" \
  "RTX_PRO_6000_BLACKWELL" "${DEFAULT_ACCELERATOR}"
DEFAULT_ACCELERATOR="A100"
assert_rc "unsupported OpenShift accelerator is rejected" 1 resolve_accelerator_type

echo "OpenShift scaleFactor validation"
assert_rc "omitted value defaults to 1" 0 validate_scale_factor_config

scale_present="true"
scale_value="1"
scale_tag="!!int"
assert_rc "accepts integer 1" 0 validate_scale_factor_config

scale_value="3"
assert_rc "accepts integer greater than 1" 0 validate_scale_factor_config

scale_value="0"
assert_rc "rejects zero" 1 validate_scale_factor_config

scale_value="-1"
assert_rc "rejects a negative integer" 1 validate_scale_factor_config

scale_value="1.5"
scale_tag="!!float"
assert_rc "rejects a decimal" 1 validate_scale_factor_config

scale_value="2"
scale_tag="!!str"
assert_rc "rejects a quoted integer" 1 validate_scale_factor_config

scale_value="null"
scale_tag="!!null"
assert_rc "rejects explicit null" 1 validate_scale_factor_config

scale_present="false"
legacy_scale_count="1"
assert_rc "rejects legacy per-feature scaleFactor" 1 validate_scale_factor_config
legacy_message=$(validate_scale_factor_config 2>&1 || true)
assert_eq "legacy error points to top-level setting" \
  "aiPlatform.features[].scaleFactor is no longer supported; move the capacity multiplier to aiPlatform.scaleFactor" \
  "${legacy_message}"

echo "OpenShift scale-aware disk minimum"
assert_eq "scale 1 requires 1024 GiB" "1024" "$(required_ai_tier_disk_gib 1024 1)"
assert_eq "scale 2 requires 2048 GiB" "2048" "$(required_ai_tier_disk_gib 1024 2)"

echo "OpenShift AIPlatform manifest render"
AI_PLATFORM_NAME="test-platform"
AI_NS="ai-platform"
AI_STANDALONE_NAME="splunk"
SPLUNK_ENABLED=true
AI_SCALE_FACTOR="3"
DEFAULT_ACCELERATOR="RTX_PRO_6000_BLACKWELL"
OBJ_STORE_REGION="us-east-2"
WORKER_IMAGE_REGISTRY="example.invalid/worker"
obj_path="s3://test-bucket"
obj_endpoint=""
image_pull_secrets=""
features_yaml=$'    - name: saia\n      version: "1.1.0"\n'
svc_template_yaml=$'  serviceTemplate:\n    spec:\n      type: NodePort\n      ports:\n      - name: http\n        port: 8080\n        targetPort: 8080\n        nodePort: 30080\n'
storage_yaml=""
cpu_tolerations_inline="[]"
splunk_ns_secret="splunk-ai-platform-secret"
trusted_issuers_yaml=$'    trustedIssuers:\n      - "https://splunk-splunk-standalone-service.ai-platform.svc.cluster.local:8089"\n'

splunk_defaults_manifest=$(render_splunk_defaults_manifest)
manifest=$(render_ai_platform_manifest)
rendered_issuer=$(awk -F'issuer_uri: ' '/issuer_uri:/{print $2; exit}' <<<"${splunk_defaults_manifest}")
rendered_endpoint=$(awk '
  /^[[:space:]]*splunkConfiguration:/ { in_splunk=1; next }
  in_splunk && /^[[:space:]]*endpoint:/ {
    sub(/^[[:space:]]*endpoint:[[:space:]]*/, ""); print; exit
  }
' <<<"${manifest}")
rendered_hec_endpoint=$(awk '
  /^[[:space:]]*splunkConfiguration:/ { in_splunk=1; next }
  in_splunk && /^[[:space:]]*hecEndpoint:/ {
    sub(/^[[:space:]]*hecEndpoint:[[:space:]]*/, ""); print; exit
  }
' <<<"${manifest}")
scale_count=$(grep -c '^[[:space:]]*scaleFactor:' <<<"${manifest}" || true)
feature_scale_count=$(grep -c '^      scaleFactor:' <<<"${manifest}" || true)
assert_eq "renders exactly one scaleFactor field" "1" "${scale_count}"
assert_eq "renders scaleFactor at AIPlatform spec level" "1" \
  "$(grep -c '^  scaleFactor: 3$' <<<"${manifest}" || true)"
assert_eq "does not render feature scaleFactor" "0" "${feature_scale_count}"
assert_eq "renders the supported OpenShift accelerator" "1" \
  "$(grep -c '^  defaultAcceleratorType: RTX_PRO_6000_BLACKWELL$' <<<"${manifest}" || true)"
assert_eq "renders configured feature" "1" \
  "$(grep -c '^    - name: saia$' <<<"${manifest}" || true)"
assert_eq "Splunk defaults and AIPlatform render the same JWT issuer" \
  "${rendered_issuer}" "${rendered_endpoint}"
assert_eq "renders the short HTTPS management issuer" \
  "https://splunk-splunk-standalone-service:8089" "${rendered_endpoint}"
assert_eq "renders a separate HEC telemetry endpoint" \
  "http://splunk-splunk-standalone-service.ai-platform.svc.cluster.local:8088" \
  "${rendered_hec_endpoint}"
assert_eq "renders configured trusted issuers" "1" \
  "$(grep -c '^    trustedIssuers:$' <<<"${manifest}" || true)"

if [[ -n "${REAL_YQ}" ]]; then
  assert_eq "rendered manifest is valid YAML" "3" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '.spec.scaleFactor' - 2>/dev/null)"
  assert_eq "rendered feature objects contain no scaleFactor" "0" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '[.spec.features[]? | select(has("scaleFactor"))] | length' - 2>/dev/null)"
  assert_eq "rendered AIPlatform uses the SAIA NodePort" "30080" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '.spec.serviceTemplate.spec.ports[0].nodePort' - 2>/dev/null)"
  assert_eq "installer-only slimNodePort is not rendered into the AIPlatform CR" "false" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '.spec.serviceTemplate | has("slimNodePort")' - 2>/dev/null)"
  assert_eq "rendered manifest preserves the HEC endpoint" \
    "http://splunk-splunk-standalone-service.ai-platform.svc.cluster.local:8088" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '.spec.splunkConfiguration.hecEndpoint' - 2>/dev/null)"
  assert_eq "rendered manifest preserves one trusted issuer" "1" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '.spec.splunkConfiguration.trustedIssuers | length' - 2>/dev/null)"
  assert_eq "rendered manifest preserves the configured trusted issuer" \
    "https://splunk-splunk-standalone-service.ai-platform.svc.cluster.local:8089" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '.spec.splunkConfiguration.trustedIssuers[0]' - 2>/dev/null)"


  SPLUNK_ENABLED=false
  disabled_manifest=$(render_ai_platform_manifest)
  assert_eq "disabled bundled Splunk renders only the external JWT issuer list" trustedIssuers \
    "$(printf '%s\n' "${disabled_manifest}" | "${REAL_YQ}" eval '.spec.splunkConfiguration | keys | .[]' -)"
  assert_eq "disabled bundled Splunk preserves its configured external issuer" \
    "https://splunk-splunk-standalone-service.ai-platform.svc.cluster.local:8089" \
    "$(printf '%s\n' "${disabled_manifest}" | "${REAL_YQ}" eval '.spec.splunkConfiguration.trustedIssuers[0]' -)"
  trusted_issuers_yaml=""
  no_splunk_manifest=$(render_ai_platform_manifest)
  assert_eq "disabled Splunk without external issuers omits splunkConfiguration" false \
    "$(printf '%s\n' "${no_splunk_manifest}" | "${REAL_YQ}" eval '.spec | has("splunkConfiguration")' -)"
  SPLUNK_ENABLED=true

  _install_disabled_ai_platform() (
    local tmp trace rendered
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' EXIT
    trace="${tmp}/calls"
    rendered="${tmp}/aiplatform.yaml"
    CONFIG_FILE="${tmp}/config.yaml"
    cat > "${CONFIG_FILE}" <<'YAML'
splunk:
  enabled: false
  trustedIssuers:
    - https://external-splunk.example.com:8089
aiPlatform:
  features:
    - name: saia
      version: 1.1.0
YAML
    SPLUNK_ENABLED=false
    OBJ_STORE_TYPE=minio
    OBJ_STORE_BUCKET=models
    OBJ_STORE_ENDPOINT=http://object-store.example.com:9000
    STORAGE_CLASS=""
    AI_NS=ai-platform
    AI_PLATFORM_NAME=test-platform
    yq() { "${REAL_YQ}" "$@"; }
    ensure_namespace() { :; }
    ensure_object_store_credentials_secret() { echo object-store >> "${trace}"; }
    sleep() { echo unexpected-wait >&2; exit 42; }
    err() { echo "$*" >&2; exit 1; }
    oc() {
      printf 'oc %s\n' "$*" >> "${trace}"
      case "$*" in
        'get secrets -n ai-platform '*) return 0 ;;
        'get secret splunk-'*) return 1 ;;
        # Only failed-ai is both failed and owned by an ai.splunk.com resource.
        'get jobs -n ai-platform -o json')
          printf '%s\n' '{"items":[
            {"metadata":{"name":"running-ai","ownerReferences":[{"apiVersion":"ai.splunk.com/v1","kind":"AIService"}]},"status":{"active":1}},
            {"metadata":{"name":"pending-ai","ownerReferences":[{"apiVersion":"ai.splunk.com/v1","kind":"AIService"}]},"status":{}},
            {"metadata":{"name":"failed-ai","ownerReferences":[{"apiVersion":"ai.splunk.com/v1","kind":"AIService"}]},"status":{"conditions":[{"type":"Failed","status":"True"}]}},
            {"metadata":{"name":"complete-ai","ownerReferences":[{"apiVersion":"ai.splunk.com/v1","kind":"AIService"}]},"status":{"conditions":[{"type":"Complete","status":"True"}]}},
            {"metadata":{"name":"failed-customer"},"status":{"conditions":[{"type":"Failed","status":"True"}]}},
            {"metadata":{"name":"failed-cronjob","ownerReferences":[{"apiVersion":"batch/v1","kind":"CronJob"}]},"status":{"conditions":[{"type":"Failed","status":"True"}]}}
          ]}'
          ;;
        '-n ai-platform apply --server-side --force-conflicts -f -')
          cat > "${rendered}"
          ;;
        'apply --dry-run=server -f '*|'get aiplatform '*|'delete '*) return 0 ;;
        *) return 1 ;;
      esac
    }
    install_ai_platform_cr || return
    if [[ "${1:-}" == cleanup ]]; then
      grep -E '^oc delete (job|jobs|pods) ' "${trace}"
      return
    fi
    [[ -f "${rendered}" ]] || return 1
    grep '^object-store$' "${trace}" || return 1
    if grep -q 'oc get secret splunk-' "${trace}"; then
      return 1
    fi
    "${REAL_YQ}" eval '.spec.splunkConfiguration | keys | .[]' "${rendered}"
  )
  assert_eq "disabled AIPlatform ensures object storage and external JWT config without polling Splunk HEC" \
    $'object-store\ntrustedIssuers' "$(_install_disabled_ai_platform)"
  assert_eq "AIPlatform rerun removes only failed AI-owned Jobs and keeps running, pending and customer Jobs" \
    $'oc delete job failed-ai -n ai-platform --wait=false\noc delete pods -n ai-platform --field-selector status.phase=Failed --selector app.kubernetes.io/managed-by!=splunk-operator --wait=false' \
    "$(_install_disabled_ai_platform cleanup)"

  unset -f yq
  CONFIG_FILE="${SCRIPT_DIR}/openshift-cluster-config.yaml"
  assert_rc "repository OpenShift config passes real validation" 0 validate_scale_factor_config
  repository_slim_image=$("${REAL_YQ}" eval '.images.slim.apiImage // ""' "${CONFIG_FILE}" 2>/dev/null)
  assert_eq "repository OpenShift config defines a non-empty SLIM image" "1" \
    "$([[ -n "${repository_slim_image}" ]] && echo 1 || echo 0)"
  assert_eq "repository OpenShift config enables the SLIM feature" "1" \
    "$("${REAL_YQ}" eval '[.aiPlatform.features[] | select(.name == "slim")] | length' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config keeps feature Services internal" "ClusterIP" \
    "$("${REAL_YQ}" eval '.aiPlatform.serviceTemplate.type' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config does not allocate NodePorts by default" "0" \
    "$("${REAL_YQ}" eval '[.aiPlatform.serviceTemplate.nodePort, .aiPlatform.serviceTemplate.slimNodePort] | map(select(. != null)) | length' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config enables the SAIA Route" "true" \
    "$("${REAL_YQ}" eval '.openshift.routes.saia.enabled' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config enables the SLIM Route" "true" \
    "$("${REAL_YQ}" eval '.openshift.routes.slim.enabled' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config defaults registryInsecure to true" "true" \
    "$("${REAL_YQ}" eval '.images.registryInsecure' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config pins the qualified cluster minor" "4.21" \
    "$("${REAL_YQ}" eval '.openshift.requiredVersion' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config stages only missing or changed models by default" "true" \
    "$("${REAL_YQ}" eval '.storage.modelStaging.enabled' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config defaults to connected installation" "false" \
    "$("${REAL_YQ}" eval '.cluster.airgap' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config does not expose an air-gap content mode" "false" \
    "$("${REAL_YQ}" eval '.cluster | has("airgapContentMode")' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config does not require an air-gap bundle path" "false" \
    "$("${REAL_YQ}" eval '.cluster | has("airgapBundlePath")' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config matches the qualified Ray runtime" "2.56.0" \
    "$("${REAL_YQ}" eval '.operators.ray.rayVersion' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config requires 1024 GiB at scale 1" "1024" \
    "$("${REAL_YQ}" eval '.storage.minimumDiskSpace.aiTierNode' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config defines one additional trusted issuer" "1" \
    "$("${REAL_YQ}" eval '.splunk.trustedIssuers | length' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config defines the AITK FQDN issuer" \
    "https://splunk-splunk-standalone-standalone-service.ai-platform.svc.cluster.local:8089" \
    "$("${REAL_YQ}" eval '.splunk.trustedIssuers[0]' "${CONFIG_FILE}" 2>/dev/null)"

  assert_eq "bundled AIPlatform CRD accepts trustedIssuers" "array" \
    "$("${REAL_YQ}" eval 'select(.kind == "CustomResourceDefinition" and .metadata.name == "aiplatforms.ai.splunk.com") | .spec.versions[] | select(.name == "v1") | .schema.openAPIV3Schema.properties.spec.properties.splunkConfiguration.properties.trustedIssuers.type' "${SCRIPT_DIR}/artifacts.yaml" 2>/dev/null)"
  assert_eq "bundled AIService CRD accepts trustedIssuers" "array" \
    "$("${REAL_YQ}" eval 'select(.kind == "CustomResourceDefinition" and .metadata.name == "aiservices.ai.splunk.com") | .spec.versions[] | select(.name == "v1") | .schema.openAPIV3Schema.properties.spec.properties.splunkConfiguration.properties.trustedIssuers.type' "${SCRIPT_DIR}/artifacts.yaml" 2>/dev/null)"

  TMP_FILES=()
  SPLUNK_AI_FILE="${SCRIPT_DIR}/artifacts.yaml"
  SPLUNK_OPERATOR_FILE="${SCRIPT_DIR}/manifest-that-does-not-exist.yaml"
  IMAGE_REGISTRY="registry.example.com"
  OPERATOR_IMAGE="platform/operator:v1"
  RAY_HEAD_IMAGE="platform/ray-head:v1"
  RAY_WORKER_IMAGE="platform/ray-worker:v1"
  WEAVIATE_IMAGE="platform/weaviate:v1"
  SAIA_API_IMAGE="platform/saia:v1"
  SAIA_API_V2_IMAGE="platform/saia-v2:v1"
  SAIA_DATALOADER_IMAGE="platform/data-loader:v1"
  SLIM_API_IMAGE="platform/slim-api:v2"
  SPLUNK_IMAGE="platform/splunk:v1"
  SPLUNK_OPERATOR_IMAGE="platform/splunk-operator:v1"
  FLUENT_BIT_IMAGE="platform/fluent-bit:v1"
  OTEL_COLLECTOR_IMAGE="platform/otel:v1"
  NGINX_IMAGE="platform/nginx:v1"
  MODEL_VERSION="model-v1"
  RAY_RUNTIME_VERSION="ray-v1"
  configure_images >/dev/null 2>&1
  assert_eq "manifest rendering patches RELATED_IMAGE_SLIM_API" \
    "registry.example.com/platform/slim-api:v2" \
    "$("${REAL_YQ}" eval 'select(.kind == "Deployment" and .metadata.name == "splunk-ai-operator-controller-manager") | .spec.template.spec.containers[] | select(.name == "manager") | .env[] | select(.name == "RELATED_IMAGE_SLIM_API") | .value' "${SPLUNK_AI_FILE}" 2>/dev/null)"
  ((${#TMP_FILES[@]} == 0)) || rm -f "${TMP_FILES[@]}"
else
  echo "  SKIP: yq not installed; YAML parse checks skipped"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
((FAIL == 0))
