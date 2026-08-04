#!/usr/bin/env bash
# Local unit and render-smoke tests for OpenShift installer scaleFactor wiring.
# No OpenShift cluster, oc login, or network access is required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/openshift_with_stack.sh"
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
eval "$(extract_function render_ai_platform_manifest)"

scale_present="false"
scale_value="null"
scale_tag="!!null"
legacy_scale_count="0"
yq() {
  local expression="${2:-}"
  if [[ "${expression}" == *features* ]]; then
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
DEFAULT_ACCELERATOR="L40S"
OBJ_STORE_REGION="us-east-2"
WORKER_IMAGE_REGISTRY="example.invalid/worker"
obj_path="s3://test-bucket"
obj_endpoint=""
image_pull_secrets=""
features_yaml=$'    - name: saia\n      version: "1.1.0"\n'
svc_template_yaml=""
storage_yaml=""
cpu_tolerations_inline="[]"
splunk_config_yaml=$'\n  splunkConfiguration:\n    endpoint: https://splunk-splunk-standalone-service.ai-platform.svc.cluster.local:8089\n'

manifest=$(render_ai_platform_manifest)
scale_count=$(grep -c '^[[:space:]]*scaleFactor:' <<<"${manifest}" || true)
feature_scale_count=$(grep -c '^      scaleFactor:' <<<"${manifest}" || true)
assert_eq "renders exactly one scaleFactor field" "1" "${scale_count}"
assert_eq "renders scaleFactor at AIPlatform spec level" "1" \
  "$(grep -c '^  scaleFactor: 3$' <<<"${manifest}" || true)"
assert_eq "does not render feature scaleFactor" "0" "${feature_scale_count}"
assert_eq "renders configured feature" "1" \
  "$(grep -c '^    - name: saia$' <<<"${manifest}" || true)"

if [[ -n "${REAL_YQ}" ]]; then
  assert_eq "rendered manifest is valid YAML" "3" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '.spec.scaleFactor' - 2>/dev/null)"
  assert_eq "rendered feature objects contain no scaleFactor" "0" \
    "$(printf '%s\n' "${manifest}" | "${REAL_YQ}" eval '[.spec.features[]? | select(has("scaleFactor"))] | length' - 2>/dev/null)"

  unset -f yq
  CONFIG_FILE="${SCRIPT_DIR}/openshift-cluster-config.yaml"
  assert_rc "repository OpenShift config passes real validation" 0 validate_scale_factor_config
else
  echo "  SKIP: yq not installed; YAML parse checks skipped"
fi

# ── Tests: AIP-4614 Splunk TLS cert provisioning (provision_splunk_cert) ──────
echo
echo "OpenShift provision_splunk_cert"

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

assert_eq "CA Issuer chains off the ai-splunk-ca-tls secret" \
  "1" "$(awk '/name: ai-splunk-ca-issuer/{f=1} f && /secretName: ai-splunk-ca-tls/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-ca-tls')"

assert_eq "leaf Certificate ai-splunk-server writes to ai-splunk-server-tls" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /secretName: ai-splunk-server-tls/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-server-tls')"

assert_eq "leaf cert issued by the CA issuer (not the selfsigned root)" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /issuerRef:/{g=1} f && g && /name: ai-splunk-ca-issuer/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-ca-issuer')"

assert_eq "leaf cert SANs cover both the standalone service and headless service (short/ns/svc/cluster.local forms)" \
  "8" "$(awk '/name: ai-splunk-server$/{f=1} f && /^---/{exit} f' "${SCRIPT}" | grep -cE '\$\{svc\}|\$\{headless\}')"

assert_eq "leaf cert requests a CombinedPEM output (splunkd needs cert+key in one file)" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /^---/{exit} f' "${SCRIPT}" | grep -c 'type: CombinedPEM')"

assert_eq "waits for the leaf cert to reach Ready before returning" \
  "1" "$(awk '/^provision_splunk_cert\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -c -e 'oc wait --for=condition=Ready certificate/ai-splunk-server')"

assert_eq "orchestrator provisions the cert before the Standalone CR is applied (cert must exist first)" \
  "1" "$(awk '/provision_splunk_cert$/{p=NR} /install_splunk_standalone$/{s=NR} END{print(p > 0 && s > 0 && p < s)}' "${SCRIPT}")"

assert_eq "orchestrator runs cert-manager install before provisioning the Splunk cert" \
  "1" "$(awk '/install_cert_manager$/{c=NR} /provision_splunk_cert$/{p=NR} END{print(c > 0 && p > 0 && c < p)}' "${SCRIPT}")"

# ── Tests: caCertRef wiring into the AIPlatform CR (internal Splunk mode) ────
echo
echo "OpenShift caCertRef wiring (install_ai_platform_cr, internal mode)"

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
echo
echo "OpenShift caCertRef wiring (install_ai_platform_cr, external mode)"

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

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
((FAIL == 0))
