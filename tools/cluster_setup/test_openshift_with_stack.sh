#!/usr/bin/env bash
# Local unit, contract, and render-smoke tests for the OpenShift installer.
# No OpenShift cluster, oc login, or network access is required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/openshift_with_stack.sh"
AIRGAP_PREPARE_SCRIPT="${SCRIPT_DIR}/prepare_airgap_bundle_openshift.sh"
AIRGAP_INSTALL_SCRIPT="${SCRIPT_DIR}/install_from_airgap_bundle_openshift.sh"
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
  local name="$1" start end
  start=$(grep -n "^${name}()" "${SCRIPT}" | cut -d: -f1)
  [[ -n "${start}" ]] || return 1
  end=$(awk -v start="${start}" 'NR > start && /^}$/ { print NR; exit }' "${SCRIPT}")
  sed -n "${start},${end}p" "${SCRIPT}"
}

eval "$(extract_function validate_scale_factor_config)"
eval "$(extract_function openshift_slim_feature_enabled)"
eval "$(extract_function warn_on_mutable_image_tags)"
eval "$(extract_function validate_image_config)"
eval "$(extract_function build_image_url)"
eval "$(extract_function configure_images)"
eval "$(extract_function internal_splunk_management_url)"
eval "$(extract_function internal_splunk_hec_url)"
eval "$(extract_function _internal_splunk_btool_http_value)"
eval "$(extract_function render_splunk_defaults_manifest)"
eval "$(extract_function render_ai_platform_manifest)"
eval "$(extract_function patch_openshift_slim_public_service_workaround)"
eval "$(extract_function platform_readiness_snapshot)"
eval "$(extract_function model_artifacts_config_name)"
eval "$(extract_function image_repository_from_ref)"
eval "$(extract_function mirror_sources_cover_repository)"
eval "$(extract_function operator_package_repositories)"
eval "$(extract_function wait_for_subscription_csv)"
eval "$(extract_function manifest_has_existing_resources)"
eval "$(extract_function resolve_accelerator_type)"
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

echo "OpenShift SLIM feature detection"
feature_names=$'saia\nslim'
assert_rc "detects enabled SLIM feature" 0 openshift_slim_feature_enabled
feature_names="saia"
assert_rc "does not enable SLIM for a SAIA-only config" 1 openshift_slim_feature_enabled

_run_validate_image_config() (
  local slim_enabled="$1" slim_image="$2"
  OPERATOR_IMAGE="operator:v1"
  RAY_HEAD_IMAGE="ray-head:v1"
  RAY_WORKER_IMAGE="ray-worker:v1"
  WEAVIATE_IMAGE="weaviate:v1"
  SAIA_API_IMAGE="saia:v1"
  SAIA_API_V2_IMAGE="saia-v2:v1"
  SAIA_DATALOADER_IMAGE="loader:v1"
  SLIM_API_IMAGE="${slim_image}"
  SPLUNK_IMAGE="splunk:v1"
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

echo "OpenShift model artifact config selection"
assert_eq "RTX Pro 6000 uses the quantized artifact manifest" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name rtx_pro_6000_blackwell)"
assert_eq "defaultAcceleratorType values are normalized" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name RTX_PRO_6000_BLACKWELL)"
assert_rc "unsupported artifact accelerator is rejected" 1 model_artifacts_config_name A100

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
assert_eq "node-storage preflight applies one shared AI-tier threshold" "3" \
  "$(awk '/^preflight_check_node_storage\(\)/,/^}/' "${SCRIPT}" | grep -c 'MIN_DISK_AI_TIER_NODE' | tr -d '[:space:]')"
assert_eq "node-storage preflight does not invent exclusive CPU/GPU roles" "0" \
  "$(awk '/^preflight_check_node_storage\(\)/,/^}/' "${SCRIPT}" | grep -c '0x10de' | tr -d '[:space:]')"
assert_eq "delete protects shared components with ownership checks" "1" \
  "$(awk '/^main_delete\(\)/,/^}/' "${SCRIPT}" | grep -c 'component_is_owned cert_manager' | tr -d '[:space:]')"
assert_eq "delete targets only this stack's named platform resources" "0" \
  "$(awk '/^main_delete\(\)/,/^}/' "${SCRIPT}" | grep -Ec 'delete (aiplatform|standalone) --all' | tr -d '[:space:]')"
assert_eq "Splunk Operator restart does not delete all ReplicaSets" "0" \
  "$(awk '/^install_splunk_operator\(\)/,/^}/' "${SCRIPT}" | grep -Ec 'delete replicaset .*--all' | tr -d '[:space:]')"
assert_eq "Splunk Standalone explicitly configures both PVC storage classes" "2" \
  "$(awk '/^install_splunk_standalone\(\)/,/^}/' "${SCRIPT}" | grep -o 'storageClassName:' | wc -l | tr -d '[:space:]')"
assert_eq "Splunk Standalone readiness detects the live HEC endpoint" "1" \
  "$(awk '/^wait_for_internal_splunk_ready\(\)/,/^}/' "${SCRIPT}" | grep -c '_detect_internal_splunk_hec_url' | tr -d '[:space:]')"
assert_eq "qualified OpenShift minor is an immutable installer constant" "1" \
  "$(grep -c '^readonly QUALIFIED_OPENSHIFT_MINOR="4.21"$' "${SCRIPT}" | tr -d '[:space:]')"
assert_eq "configured OpenShift minor cannot override qualification" "1" \
  "$(awk '/^load_config\(\)/,/^}/' "${SCRIPT}" | grep -c 'cannot override the installer qualification' | tr -d '[:space:]')"
assert_eq "air-gap bundle includes model verification metadata" "1" \
  "$(grep -c 'cp .*MODEL_METADATA_SOURCE.*model-metadata' "${AIRGAP_PREPARE_SCRIPT}" | tr -d '[:space:]')"
assert_eq "air-gap wrapper exports bundled model metadata path" "1" \
  "$(grep -c '^export MODEL_ARTIFACTS_CONFIG_DIR=.*model-metadata' "${AIRGAP_INSTALL_SCRIPT}" | tr -d '[:space:]')"
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

echo "OpenShift disconnected mirror source matching"
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

echo "OpenShift AIPlatform manifest render"
AI_PLATFORM_NAME="test-platform"
AI_NS="ai-platform"
AI_STANDALONE_NAME="splunk"
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

  unset -f yq
  CONFIG_FILE="${SCRIPT_DIR}/openshift-cluster-config.yaml"
  assert_rc "repository OpenShift config passes real validation" 0 validate_scale_factor_config
  repository_slim_image=$("${REAL_YQ}" eval '.images.slim.apiImage // ""' "${CONFIG_FILE}" 2>/dev/null)
  assert_eq "repository OpenShift config defines a non-empty SLIM image" "1" \
    "$([[ -n "${repository_slim_image}" ]] && echo 1 || echo 0)"
  assert_eq "repository OpenShift config enables the SLIM feature" "1" \
    "$("${REAL_YQ}" eval '[.aiPlatform.features[] | select(.name == "slim")] | length' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config exposes SAIA on NodePort 30080" "30080" \
    "$("${REAL_YQ}" eval '.aiPlatform.serviceTemplate.nodePort' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config exposes SLIM on NodePort 30081" "30081" \
    "$("${REAL_YQ}" eval '.aiPlatform.serviceTemplate.slimNodePort' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config pins the qualified cluster minor" "4.21" \
    "$("${REAL_YQ}" eval '.openshift.requiredVersion' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config explicitly verifies pre-staged models" "false" \
    "$("${REAL_YQ}" eval '.storage.modelStaging.enabled' "${CONFIG_FILE}" 2>/dev/null)"
  assert_eq "repository OpenShift config requires 500 GiB on shared AI-tier nodes" "500" \
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
