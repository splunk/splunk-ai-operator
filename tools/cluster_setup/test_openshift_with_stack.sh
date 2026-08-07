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
eval "$(extract_function model_artifacts_config_name)"
eval "$(extract_function resolve_accelerator_type)"
eval "$(grep '^readonly OPENSHIFT_ACCELERATOR=' "${SCRIPT}")"

log() { :; }
err() { return 1; }

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

echo "OpenShift model artifact config selection"
assert_eq "RTX Pro 6000 uses the quantized artifact manifest" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name rtx_pro_6000_blackwell)"
assert_eq "defaultAcceleratorType values are normalized" \
  "model_artifacts_configs_quantized.yaml" "$(model_artifacts_config_name RTX_PRO_6000_BLACKWELL)"
assert_rc "unsupported artifact accelerator is rejected" 1 model_artifacts_config_name A100

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

echo "OpenShift cert-manager installation contract"
_CM_INSTALL_BODY() { extract_function install_cert_manager; }
_SPLUNK_CERT_BODY() { extract_function provision_splunk_cert; }
_SPLUNK_STANDALONE_BODY() { extract_function install_splunk_standalone; }

assert_eq "installs the pinned cert-manager manifest" "1" \
  "$(_CM_INSTALL_BODY | grep -c 'releases/download/v1.13.0/cert-manager.yaml')"
assert_eq "waits for the Certificate CRD" "1" \
  "$(_CM_INSTALL_BODY | grep -c 'wait_for_crd certificates.cert-manager.io 300')"
assert_eq "retains the OpenShift SCC setup for all cert-manager service accounts" "3" \
  "$(_CM_INSTALL_BODY | grep -c 'oc adm policy add-scc-to-user anyuid')"
assert_eq "waits for both cert-manager Deployment rollouts" "2" \
  "$(_CM_INSTALL_BODY | grep -c 'oc rollout status deployment/cert-manager')"
assert_eq "waits for cert-manager and webhook pods to become ready" "2" \
  "$(_CM_INSTALL_BODY | grep -c 'oc wait --for=condition=ready pod')"
assert_eq "does not mutate cert-manager Deployment arguments" "0" \
  "$(_CM_INSTALL_BODY | grep -c 'oc patch deployment')"

echo "OpenShift Splunk TLS provisioning"
assert_eq "provisions self-signed CA, CA issuer, and service leaf" "4" \
  "$(_SPLUNK_CERT_BODY | grep -c '^kind: \(Issuer\|Certificate\)$')"
assert_eq "root CA has conservative ten-year duration" "1" \
  "$(_SPLUNK_CERT_BODY | grep -c 'duration: 87600h')"
assert_eq "root CA renews one year before expiry" "1" \
  "$(_SPLUNK_CERT_BODY | grep -c 'renewBefore: 8760h')"
assert_eq "root CA retains its ECDSA private key across renewal" "1" \
  "$(_SPLUNK_CERT_BODY | grep -c 'rotationPolicy: Never')"
assert_eq "leaf rotates its RSA private key on renewal" "1" \
  "$(_SPLUNK_CERT_BODY | grep -c 'rotationPolicy: Always')"
assert_eq "root CA uses an ECDSA-256 key" "1" \
  "$(_SPLUNK_CERT_BODY | grep -A2 'algorithm: ECDSA' | grep -c 'size: 256')"
assert_eq "Splunk leaf uses a compatible RSA-2048 key" "1" \
  "$(_SPLUNK_CERT_BODY | grep -A2 'algorithm: RSA' | grep -c 'size: 2048')"
assert_eq "Splunk/KV Store leaf has all required key and extended-key usages" \
  $'  usages:\n    - digital signature\n    - key encipherment\n    - server auth\n    - client auth' \
  "$(_SPLUNK_CERT_BODY | sed -n '/^  usages:/,/^  dnsNames:/p' | sed '$d')"
assert_eq "leaf SAN contains the exact management service FQDN" "1" \
  "$(_SPLUNK_CERT_BODY | grep -c -- '- ${svc}.${AI_NS}.svc.cluster.local')"
assert_eq "leaf Certificate uses only cert-manager's standard Secret outputs" "0" \
  "$(_SPLUNK_CERT_BODY | grep -c 'additionalOutputFormats:')"
assert_eq "CA and leaf readiness failures are fatal" "2" \
  "$(_SPLUNK_CERT_BODY | grep -c '^    err .*Certificate did not become Ready')"
assert_eq "leaf Secret readiness requires exactly its three source TLS keys" "1" \
  "$(_SPLUNK_CERT_BODY | grep -c '\["tls.crt", "tls.key", "ca.crt"\]')"
assert_eq "Standalone mounts the leaf Secret only in Splunk" "1" \
  "$(_SPLUNK_STANDALONE_BODY | grep -c 'secretName: ai-splunk-server-tls')"
assert_eq "registers the supported Splunk-Ansible PEM assembly pre-task" "1" \
  "$(_SPLUNK_STANDALONE_BODY | grep -c 'file:///mnt/defaults/prepare-server-pem.yml')"
assert_eq "assembles server.pem in certificate-then-private-key order" "1" \
  "$(_SPLUNK_STANDALONE_BODY | grep -c 'cat /mnt/splunk-cert-source/tls.crt /mnt/splunk-cert-source/tls.key > /mnt/splunk-certs/server.pem.tmp')"
assert_eq "atomically installs the private PEM with restricted output" "3" \
  "$(_SPLUNK_STANDALONE_BODY | grep -cE 'chmod 0600 .*server.pem.tmp|mv -f .*server.pem.tmp .*server.pem|no_log: true')"
assert_eq "Splunk-Ansible management TLS fields preserve the prepared PEM and CA" \
  $'      ssl:\n        enable: true\n        cert: /mnt/splunk-certs/server.pem\n        password: ""\n        ca: /mnt/splunk-cert-source/ca.crt' \
  "$(_SPLUNK_STANDALONE_BODY | sed -n '/^      ssl:$/,/^      hec:$/p' | sed '$d')"
assert_eq "Splunk-Ansible HEC fields enforce HTTPS with the prepared PEM" \
  $'      hec:\n        enable: true\n        ssl: true\n        port: 8088\n        cert: /mnt/splunk-certs/server.pem\n        password: ""' \
  "$(_SPLUNK_STANDALONE_BODY | sed -n '/^      hec:$/,/^      http_enableSSL:/p' | sed '$d')"
assert_eq "does not mix in the deprecated HEC TLS input" "0" \
  "$(_SPLUNK_STANDALONE_BODY | grep -c 'hec_enableSSL:')"
assert_eq "Splunk-Ansible Web TLS fields preserve the separate cert and key" "4" \
  "$(_SPLUNK_STANDALONE_BODY | grep -cE '^      http_enableSSL(:|_cert:|_privKey:|_privKey_password:)')"
assert_eq "splunkd uses the prepared certificate-first PEM" "1" \
  "$(_SPLUNK_STANDALONE_BODY | grep -A5 'sslConfig:' | grep -c 'serverCert: /mnt/splunk-certs/server.pem')"
assert_eq "Splunk Web uses separate projected certificate and key files" "2" \
  "$(_SPLUNK_STANDALONE_BODY | grep -A9 'key: web' | grep -cE 'serverCert: /mnt/splunk-cert-source/tls.crt|privKeyPath: /mnt/splunk-cert-source/tls.key')"
assert_eq "HEC explicit inputs config uses the prepared PEM" "1" \
  "$(_SPLUNK_STANDALONE_BODY | awk '/key: inputs/{f=1} f && /key: authentication/{exit} f' | grep -c 'serverCert: /mnt/splunk-certs/server.pem')"
assert_eq "projects exactly tls.crt, tls.key, and ca.crt from the leaf Secret" "3" \
  "$(_SPLUNK_STANDALONE_BODY | awk '/^    - name: splunk-cert-source$/{f=1; next} f && /^    - name: splunk-certs$/{exit} f' | grep -c '^          - key:')"
assert_eq "prepared PEM is written to a bounded, memory-backed emptyDir" "2" \
  "$(_SPLUNK_STANDALONE_BODY | grep -A3 '^    - name: splunk-certs$' | grep -cE 'medium: Memory|sizeLimit: 1Mi')"
assert_eq "installer warns that Splunk needs a controlled renewal restart" "1" \
  "$(_SPLUNK_CERT_BODY | grep -c 'controlled.*restart after renewal')"

echo "OpenShift AIPlatform manifest render"
AI_PLATFORM_NAME="test-platform"
AI_NS="ai-platform"
AI_STANDALONE_NAME="splunk-standalone"
AI_SCALE_FACTOR="3"
DEFAULT_ACCELERATOR="RTX_PRO_6000_BLACKWELL"
OBJ_STORE_REGION="us-east-2"
WORKER_IMAGE_REGISTRY="example.invalid/worker"
obj_path="s3://test-bucket"
obj_endpoint=""
image_pull_secrets=""
features_yaml=$'    - name: saia\n      version: "1.1.0"\n'
svc_template_yaml=""
storage_yaml=""
cpu_tolerations_inline="[]"
splunk_ns_secret="splunk-ai-platform-secret"

manifest=$(render_ai_platform_manifest)
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
assert_eq "renders Splunk management/JWKS endpoint on HTTPS 8089" "1" \
  "$(grep -c '^    endpoint: https://splunk-splunk-standalone-standalone-service.ai-platform.svc.cluster.local:8089$' <<<"${manifest}" || true)"
assert_eq "renders distinct Splunk HEC endpoint on HTTPS 8088" "1" \
  "$(grep -c '^    hecEndpoint: https://splunk-splunk-standalone-standalone-service.ai-platform.svc.cluster.local:8088$' <<<"${manifest}" || true)"
assert_eq "oauth issuer is byte-identical to rendered management endpoint" "1" \
  "$(_SPLUNK_STANDALONE_BODY | grep -c 'issuer_uri: https://splunk-${AI_STANDALONE_NAME}-standalone-service.${AI_NS}.svc.cluster.local:8089')"
assert_eq "renders same-namespace public CA projection" "1" \
  "$(grep -A4 '^    caCertRef:' <<<"${manifest}" | grep -c '^      namespace: ai-platform$' || true)"
assert_eq "caCertRef selects only ca.crt" "1" \
  "$(grep -A4 '^    caCertRef:' <<<"${manifest}" | grep -c '^      key: ca.crt$' || true)"
assert_eq "AIPlatform never asks to mount the private-key entry" "0" \
  "$(grep -c '^[[:space:]]*key: tls.key$' <<<"${manifest}" || true)"

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

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
((FAIL == 0))
