#!/usr/bin/env bash
# Static and rendered-manifest regression checks for the EKS installer TLS chain.
# The production functions are loaded dynamically below, so ShellCheck cannot
# see their use of the test doubles and render variables.
# shellcheck disable=SC2034,SC2329,SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/eks_cluster_with_stack.sh"

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

assert_contains() {
  local description="$1" needle="$2" haystack="$3"
  if grep -Fq -- "${needle}" <<<"${haystack}"; then
    PASS=$((PASS + 1))
    echo "  PASS: ${description}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${description}"
    echo "        missing: ${needle}"
  fi
}

assert_not_contains() {
  local description="$1" needle="$2" haystack="$3"
  if grep -Fq -- "${needle}" <<<"${haystack}"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${description}"
    echo "        unexpected: ${needle}"
  else
    PASS=$((PASS + 1))
    echo "  PASS: ${description}"
  fi
}

extract_function() {
  local function_name="$1"
  awk -v name="${function_name}" '
    index($0, name "() {") == 1 { found=1 }
    found { print }
    found && /^}$/ { exit }
    END { if (!found) exit 1 }
  ' "${SCRIPT}"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
provision_render="${tmp_dir}/provision.yaml"
standalone_render="${tmp_dir}/standalone.yaml"
platform_render="${tmp_dir}/platform.yaml"

render_provision() (
  # shellcheck disable=SC1090
  source <(extract_function provision_splunk_cert)
  log() { :; }
  warn() { :; }
  err() { echo "$*" >&2; return 1; }
  ensure_namespace() { :; }
  wait_for_crd() { :; }
  sleep() { :; }
  jq() { command cat >/dev/null; return 0; }
  kubectl() {
    case " $* " in
      *" apply "*) command cat; return 0 ;;
      *" get secret/ai-splunk-server-tls "*)
        printf '%s\n' '{"data":{"tls.crt":"YQ==","tls.key":"Yg==","ca.crt":"Yw=="}}'
        return 0
        ;;
      *) return 0 ;;
    esac
  }

  AI_NS="ai-test"
  AI_STANDALONE_NAME="demo"
  CLUSTER_DOMAIN="corp.local"
  SPLUNK_SERVICE_NAME="splunk-demo-standalone-service"
  SPLUNK_SERVICE_FQDN="${SPLUNK_SERVICE_NAME}.${AI_NS}.svc.${CLUSTER_DOMAIN}"
  provision_splunk_cert
)

render_standalone() (
  # shellcheck disable=SC1090
  source <(extract_function install_splunk_standalone)
  log() { :; }
  warn() { :; }
  err() { echo "$*" >&2; return 1; }
  ensure_namespace() { :; }
  wait_for_crd() { :; }
  wait_resource_exists() { :; }
  ensure_ecr_only_policy() { printf '%s\n' 'arn:aws:iam::123456789012:policy/test'; }
  ensure_bucket_policy() { printf '%s\n' 'arn:aws:iam::123456789012:policy/test'; }
  ensure_irsa_for_sa() { :; }
  kubectl() {
    case " $* " in
      *" get secret ecr-registry-secret "*) return 1 ;;
      *" apply "*) command cat; return 0 ;;
      *) return 0 ;;
    esac
  }

  AI_NS="ai-test"
  AI_STANDALONE_NAME="demo"
  STANDALONE_SA="splunk-sa"
  STORAGE_CLASS="gp3"
  USE_EXTERNAL_OBJ_STORE="true"
  MINIO_ENDPOINT="https://objects.example.test"
  OBJ_STORE_ENDPOINT="${MINIO_ENDPOINT}"
  MINIO_BUCKET="apps"
  SPLUNK_MANAGEMENT_ENDPOINT="https://splunk-demo-standalone-service.ai-test.svc.corp.local:8089"
  install_splunk_standalone
)

render_platform() (
  # shellcheck disable=SC1090
  source <(extract_function install_ai_platform_cr)
  log() { :; }
  ensure_namespace() { :; }
  saia_service_template_enabled() { return 1; }
  wait_aiplatform_ready() { :; }
  patch_saia_public_service_workaround() { :; }
  wait_for_saia_load_balancer() { :; }
  kubectl() {
    case " $* " in
      *" apply "*) command cat; return 0 ;;
      *) return 0 ;;
    esac
  }

  AI_NS="ai-test"
  AI_PLATFORM_NAME="platform"
  OBJ_STORE_TYPE="aws"
  S3_BUCKET="bucket"
  REGION="us-east-2"
  RAY_HEAD_SA="ray-head"
  DEFAULT_ACCELERATOR="L40S"
  SAIA_SERVICE_SA="saia"
  VECTORDB_SIZE="50Gi"
  STORAGE_CLASS="gp3"
  RAY_WORKER_SA="ray-worker"
  WORKER_IMAGE_REGISTRY=""
  INGRESS_CLASS="nginx"
  INGRESS_HOST="ai.example.test"
  INGRESS_TLS_SECRET="ai-platform-tls"
  CERT_ISSUER="platform-issuer"
  SPLUNK_MANAGEMENT_ENDPOINT="https://splunk-demo-standalone-service.ai-test.svc.corp.local:8089"
  SPLUNK_HEC_ENDPOINT="https://splunk-demo-standalone-service.ai-test.svc.corp.local:8088"
  install_ai_platform_cr "splunk-demo-secret-v1"
)

echo "EKS cert-manager installation contract"
installer_source="$(<"${SCRIPT}")"
assert_contains "pins cert-manager to the reviewed 1.18 chart" \
  'local cert_manager_chart_version="v1.18.0"' "${installer_source}"
assert_contains "installs cert-manager CRDs with the pinned chart" \
  '--namespace cert-manager --create-namespace --set crds.enabled=true' "${installer_source}"
assert_contains "waits for the cert-manager webhook rollout" \
  'wait_rollout cert-manager deploy cert-manager-webhook' "${installer_source}"
assert_contains "waits for the cert-manager controller rollout" \
  'wait_rollout cert-manager deploy cert-manager' "${installer_source}"
assert_contains "waits for the cert-manager cainjector rollout" \
  'wait_rollout cert-manager deploy cert-manager-cainjector' "${installer_source}"
assert_not_contains "does not create temporary readiness resources" \
  'kind: Certificate' "$(extract_function install_cert_manager)"

echo
echo "EKS Splunk certificate render"
if render_provision >"${provision_render}"; then
  PASS=$((PASS + 1)); echo "  PASS: renders the certificate chain"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: renders the certificate chain"
fi
provision_yaml="$(<"${provision_render}")"
assert_contains "renders the self-signed bootstrap Issuer" 'name: ai-splunk-selfsigned' "${provision_yaml}"
assert_contains "renders a CA Certificate" 'isCA: true' "${provision_yaml}"
assert_contains "pins the CA lifetime to ten years" 'duration: 87600h' "${provision_yaml}"
assert_contains "renews the CA one year before expiry" 'renewBefore: 8760h' "${provision_yaml}"
assert_contains "keeps the CA private key across renewal" 'rotationPolicy: Never' "${provision_yaml}"
assert_contains "rotates the leaf private key" 'rotationPolicy: Always' "${provision_yaml}"
assert_contains "renders the exact service FQDN SAN" \
  '- splunk-demo-standalone-service.ai-test.svc.corp.local' "${provision_yaml}"
assert_not_contains "leaf uses only cert-manager's standard Secret outputs" \
  'additionalOutputFormats:' "${provision_yaml}"
assert_contains "uses ECDSA for the long-lived CA key" 'algorithm: ECDSA' "${provision_yaml}"
assert_eq "uses ECDSA only for the CA" "1" \
  "$(grep -c '^    algorithm: ECDSA$' "${provision_render}" || true)"
assert_eq "uses a 256-bit ECDSA CA key" "1" \
  "$(grep -c '^    size: 256$' "${provision_render}" || true)"
assert_eq "uses Splunk-compatible RSA only for the leaf" "1" \
  "$(grep -c '^    algorithm: RSA$' "${provision_render}" || true)"
assert_eq "uses a 2048-bit RSA leaf key" "1" \
  "$(grep -c '^    size: 2048$' "${provision_render}" || true)"
assert_contains "allows the leaf to sign TLS handshakes" '    - digital signature' "${provision_yaml}"
assert_contains "allows RSA key encipherment" '    - key encipherment' "${provision_yaml}"
assert_contains "allows Splunk server authentication" '    - server auth' "${provision_yaml}"
assert_contains "allows KV Store client authentication" '    - client auth' "${provision_yaml}"
assert_contains "waits fatally for the real leaf Certificate" \
  'if ! kubectl -n "${AI_NS}" wait --for=condition=Ready certificate/ai-splunk-server' \
  "$(extract_function provision_splunk_cert)"
assert_contains "validates every Secret key consumed by Splunk" \
  '["tls.crt", "tls.key", "ca.crt"]' \
  "$(extract_function provision_splunk_cert)"

echo
echo "EKS Standalone TLS render"
if render_standalone >"${standalone_render}"; then
  PASS=$((PASS + 1)); echo "  PASS: renders the Standalone resources"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: renders the Standalone resources"
fi
standalone_yaml="$(<"${standalone_render}")"
assert_contains "registers the supported PEM assembly pre-task" \
  'file:///mnt/defaults/prepare-server-pem.yml' "${standalone_yaml}"
assert_contains "assembles Splunk's PEM in certificate-then-private-key order" \
  'cat /mnt/splunk-cert-source/tls.crt /mnt/splunk-cert-source/tls.key > /mnt/splunk-certs/server.pem.tmp' \
  "${standalone_yaml}"
assert_contains "atomically installs the private PEM with restrictive permissions" \
  'mv -f /mnt/splunk-certs/server.pem.tmp /mnt/splunk-certs/server.pem' "${standalone_yaml}"
assert_contains "suppresses private PEM task output" 'no_log: true' "${standalone_yaml}"
assert_contains "sets splunkd's certificate-first server PEM" \
  'serverCert: /mnt/splunk-certs/server.pem' "${standalone_yaml}"
assert_contains "sets splunkd's CA root" \
  'sslRootCAPath: /mnt/splunk-cert-source/ca.crt' "${standalone_yaml}"
assert_contains "enables TLS for Splunk Web" 'enableSplunkWebSSL: true' "${standalone_yaml}"
assert_contains "Splunk Web uses the projected certificate" \
  'serverCert: /mnt/splunk-cert-source/tls.crt' "${standalone_yaml}"
assert_contains "Splunk Web uses the projected private key" \
  'privKeyPath: /mnt/splunk-cert-source/tls.key' "${standalone_yaml}"
assert_contains "uses Splunk-Ansible's supported management TLS fields" \
  $'      ssl:\n        enable: true\n        cert: /mnt/splunk-certs/server.pem\n        password: ""\n        ca: /mnt/splunk-cert-source/ca.crt' \
  "${standalone_yaml}"
assert_contains "uses Splunk-Ansible's supported HEC TLS fields" \
  $'      hec:\n        enable: true\n        ssl: true\n        port: 8088\n        cert: /mnt/splunk-certs/server.pem\n        password: ""' \
  "${standalone_yaml}"
assert_not_contains "does not mix in the deprecated HEC TLS input" \
  'hec_enableSSL:' "${standalone_yaml}"
assert_contains "uses Splunk-Ansible's supported Web TLS fields" \
  $'      http_enableSSL: 1\n      http_enableSSL_cert: /mnt/splunk-cert-source/tls.crt\n      http_enableSSL_privKey: /mnt/splunk-cert-source/tls.key\n      http_enableSSL_privKey_password: ""' \
  "${standalone_yaml}"
assert_contains "pins HEC to the same prepared server certificate" \
  $'directory: /opt/splunk/etc/apps/splunk_httpinput/local\n            content:\n              http:\n                enableSSL: 1\n                serverCert: /mnt/splunk-certs/server.pem' \
  "${standalone_yaml}"
assert_contains "uses the prepared PEM as the OAuth signing certificate" \
  'certFile: /mnt/splunk-certs/server.pem' "${standalone_yaml}"
assert_contains "uses the hostname-valid FQDN as OAuth issuer" \
  'issuer_uri: https://splunk-demo-standalone-service.ai-test.svc.corp.local:8089' "${standalone_yaml}"
assert_contains "mounts the projected leaf source only into Splunk" 'name: splunk-cert-source' "${standalone_yaml}"
assert_contains "selects the issued leaf Secret" 'secretName: ai-splunk-server-tls' "${standalone_yaml}"
assert_eq "projects only tls.crt, tls.key, and ca.crt from the leaf Secret" "3" \
  "$(awk '/^    - name: splunk-cert-source$/{f=1; next} f && /^    - name: splunk-certs$/{exit} f' \
      <<<"${standalone_yaml}" | grep -c '^          - key:' || true)"
assert_contains "uses a bounded, memory-backed volume for the prepared PEM" \
  $'    - name: splunk-certs\n      emptyDir:\n        medium: Memory\n        sizeLimit: 1Mi' "${standalone_yaml}"
assert_eq "mounts the TLS Secret in both Standalone storage branches" "2" \
  "$(grep -c '^        secretName: ai-splunk-server-tls$' <<<"$(extract_function install_splunk_standalone)" || true)"

echo
echo "EKS AIPlatform TLS render"
if render_platform >"${platform_render}"; then
  PASS=$((PASS + 1)); echo "  PASS: renders the AIPlatform resource"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: renders the AIPlatform resource"
fi
platform_yaml="$(<"${platform_render}")"
assert_contains "renders the management/JWKS endpoint on 8089" \
  'endpoint: https://splunk-demo-standalone-service.ai-test.svc.corp.local:8089' "${platform_yaml}"
assert_contains "renders the distinct HEC endpoint on 8088" \
  'hecEndpoint: https://splunk-demo-standalone-service.ai-test.svc.corp.local:8088' "${platform_yaml}"
assert_contains "keeps a CA-only projection in the workload namespace" \
  $'    caCertRef:\n      name: ai-splunk-server-tls\n      namespace: ai-test\n      key: ca.crt' "${platform_yaml}"
assert_not_contains "does not request tls.key through caCertRef" 'key: tls.key' "${platform_yaml}"

issuer_value="$(awk '/^[[:space:]]+issuer_uri:/ { print $2; exit }' "${standalone_render}")"
endpoint_value="$(awk '/^    endpoint:/ { print $2; exit }' "${platform_render}")"
assert_eq "OAuth issuer and management endpoint are byte-identical" "${issuer_value}" "${endpoint_value}"

stack_body="$(extract_function install_ai_platform_stack)"
provision_line="$(grep -n '^  provision_splunk_cert$' <<<"${stack_body}" | cut -d: -f1)"
standalone_line="$(grep -n '^  install_splunk_standalone$' <<<"${stack_body}" | cut -d: -f1)"
if [[ -n "${provision_line}" && -n "${standalone_line}" && "${provision_line}" -lt "${standalone_line}" ]]; then
  PASS=$((PASS + 1)); echo "  PASS: provisions TLS before creating the Standalone"
else
  FAIL=$((FAIL + 1)); echo "  FAIL: provisions TLS before creating the Standalone"
fi
assert_contains "documents the required controlled restart after renewal" \
  'splunkd does not hot-reload' "${installer_source}"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
((FAIL == 0))
