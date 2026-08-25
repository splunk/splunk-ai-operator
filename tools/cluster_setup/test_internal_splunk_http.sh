#!/usr/bin/env bash
# Read-only AIP-4614 integration check for native-HTTPS internal Splunk.
# The historical filename is retained for CI compatibility; management port
# 8089 is expected to use native HTTPS, while Splunk Web remains HTTP.
#
# The script validates the deployed state; it does not create, patch, restart,
# or delete resources and does not read the Splunk admin password.

set -euo pipefail

NAMESPACE="ai-platform"
STANDALONE_NAME="splunk-standalone"
AIPLATFORM_NAME=""
EXPECTED_SAIA_TAG=""
WAIT_TIMEOUT=600

usage() {
  cat <<'EOF'
Usage: test_internal_splunk_http.sh [options]

Options:
  --namespace NAME          Namespace containing Splunk and AIPlatform
                            (default: ai-platform)
  --standalone NAME         Standalone CR name (default: splunk-standalone)
  --aiplatform NAME         AIPlatform CR name (auto-discovered when unique)
  --expected-saia-tag TAG   Also require every running SAIA image to use TAG
  --timeout SECONDS         Reconcile wait timeout (default: 600)
  -h, --help                Show this help

The active kubectl context/KUBECONFIG is used.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="${2:?--namespace requires a value}"
      shift 2
      ;;
    --standalone)
      STANDALONE_NAME="${2:?--standalone requires a value}"
      shift 2
      ;;
    --aiplatform)
      AIPLATFORM_NAME="${2:?--aiplatform requires a value}"
      shift 2
      ;;
    --expected-saia-tag)
      EXPECTED_SAIA_TAG="${2:?--expected-saia-tag requires a value}"
      shift 2
      ;;
    --timeout)
      WAIT_TIMEOUT="${2:?--timeout requires a value}"
      [[ "${WAIT_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || {
        echo "--timeout must be a positive integer" >&2
        exit 2
      }
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command_name in kubectl jq; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    echo "Required command not found: ${command_name}" >&2
    exit 2
  }
done

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SPLUNK_POD="splunk-${STANDALONE_NAME}-standalone-0"
SPLUNK_SERVICE="splunk-${STANDALONE_NAME}-standalone-service"
EXPECTED_URL="https://${SPLUNK_SERVICE}:8089"

kubectl get namespace "${NAMESPACE}" >/dev/null
kubectl get standalone "${STANDALONE_NAME}" -n "${NAMESPACE}" >/dev/null
kubectl get pod "${SPLUNK_POD}" -n "${NAMESPACE}" >/dev/null

if [[ -z "${AIPLATFORM_NAME}" ]]; then
  _platform_names=()
  while IFS= read -r platform_name; do
    [[ -n "${platform_name}" ]] && _platform_names+=("${platform_name}")
  done < <(kubectl get aiplatform -n "${NAMESPACE}" \
    -o json | jq -r '.items[].metadata.name')
  [[ ${#_platform_names[@]} -eq 1 ]] || \
    fail "expected exactly one AIPlatform in ${NAMESPACE}; pass --aiplatform explicitly"
  AIPLATFORM_NAME="${_platform_names[0]}"
fi

telemetry_bootstrapped=$(kubectl get standalone "${STANDALONE_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.telAppInstalled}')
[[ "${telemetry_bootstrapped}" == "true" ]] || \
  fail "Standalone.status.telAppInstalled=${telemetry_bootstrapped:-unset}, expected true"
pass "Splunk Operator one-time telemetry bootstrap completed"

standalone_phase=$(kubectl get standalone "${STANDALONE_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.phase}')
[[ "${standalone_phase}" == "Ready" ]] || \
  fail "Standalone phase=${standalone_phase:-unset}, expected Ready"
standalone_message=$(kubectl get standalone "${STANDALONE_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.message}')
[[ -z "${standalone_message}" ]] || \
  fail "Standalone reports a reconcile error despite phase=Ready: ${standalone_message}"
pass "Standalone phase is Ready with no reconcile error"

pod_ready=$(kubectl get pod "${SPLUNK_POD}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[[ "${pod_ready}" == "True" ]] || fail "Splunk pod Ready=${pod_ready:-unset}, expected True"
pass "Splunk pod is Ready"

spec_tls_value=$(kubectl get standalone "${STANDALONE_NAME}" -n "${NAMESPACE}" -o json \
  | jq -r '[.spec.extraEnv[]? | select(.name == "SPLUNKD_SSL_ENABLE") | .value] | last // ""')
[[ "${spec_tls_value}" == "true" ]] || \
  fail "Standalone.spec.extraEnv SPLUNKD_SSL_ENABLE=${spec_tls_value:-unset}, expected true"
pass "Standalone declares SPLUNKD_SSL_ENABLE=true for the bundled Splunk app"

container_tls_value=$(kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
  printenv SPLUNKD_SSL_ENABLE)
[[ "${container_tls_value}" == "true" ]] || \
  fail "pod SPLUNKD_SSL_ENABLE=${container_tls_value:-unset}, expected true"
pass "replacement pod received SPLUNKD_SSL_ENABLE=true"

effective_tls_value=$(kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
  /opt/splunk/bin/splunk btool server list sslConfig 2>/dev/null \
  | awk '$1 == "enableSplunkdSSL" { value = tolower($3) } END { if (value != "") print value }')
[[ "${effective_tls_value}" == "true" || "${effective_tls_value}" == "1" ]] || \
  fail "btool enableSplunkdSSL=${effective_tls_value:-unset}, expected true/1"
pass "effective Splunk configuration keeps native management HTTPS enabled"

server_ssl_debug=$(kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
  /opt/splunk/bin/splunk btool server list sslConfig --debug 2>/dev/null) || \
  fail "could not read effective server.conf TLS settings"
if grep -q '/mnt/splunk-cert' <<<"${server_ssl_debug}"; then
  fail "server.conf still references the removed installer TLS mounts"
fi
pass "server.conf contains no stale installer TLS mount paths"

web_tls_value=$(kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
  /opt/splunk/bin/splunk btool web list settings 2>/dev/null \
  | awk '$1 == "enableSplunkWebSSL" { value = tolower($3) } END { if (value != "") print value }')
[[ "${web_tls_value}" == "false" || "${web_tls_value}" == "0" ]] || \
  fail "btool enableSplunkWebSSL=${web_tls_value:-unset}, expected false/0"
web_tls_debug=$(kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
  /opt/splunk/bin/splunk btool web list settings --debug 2>/dev/null) || \
  fail "could not read effective web.conf settings"
if grep -q '/mnt/splunk-cert' <<<"${web_tls_debug}"; then
  fail "web.conf still references the removed installer TLS mounts"
fi
pass "Splunk Web reverted to HTTP with no stale installer TLS mount paths"

kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
  curl --silent --show-error --fail --max-time 15 \
  http://localhost:8000/ >/dev/null || \
  fail "Splunk Web did not respond successfully over HTTP"
if kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
    curl --insecure --silent --show-error --max-time 5 \
    https://localhost:8000/ >/dev/null 2>&1; then
  fail "HTTPS unexpectedly succeeded on Splunk Web after stale TLS cleanup"
fi
pass "Splunk Web responds over HTTP rather than the removed preview TLS configuration"

kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
  curl --insecure --silent --show-error --fail --max-time 15 \
  https://127.0.0.1:8089/services/authorization/tokens-keys >/dev/null || \
  fail "Splunk JWKS endpoint did not respond successfully over native HTTPS"
pass "native Splunkd HTTPS works locally for the bundled Splunk app"

if kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
    curl --silent --show-error --fail --max-time 5 \
    http://127.0.0.1:8089/services/authorization/tokens-keys >/dev/null 2>&1; then
  fail "plaintext HTTP unexpectedly succeeded on native Splunk management port 8089"
fi
pass "native Splunk management port rejects plaintext HTTP"

service_type=$(kubectl get service "${SPLUNK_SERVICE}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.type}')
[[ "${service_type}" == "ClusterIP" ]] || \
  fail "${SPLUNK_SERVICE} type=${service_type}, expected ClusterIP"
pass "native HTTPS management service remains internal (ClusterIP)"

issuer_uri=$(kubectl exec -n "${NAMESPACE}" "${SPLUNK_POD}" -- \
  /opt/splunk/bin/splunk btool authentication list oauth2_settings 2>/dev/null \
  | awk '$1 == "issuer_uri" { value = $3 } END { if (value != "") print value }')
platform_endpoint=$(kubectl get aiplatform "${AIPLATFORM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.splunkConfiguration.endpoint}')
platform_hec_endpoint=$(kubectl get aiplatform "${AIPLATFORM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.splunkConfiguration.hecEndpoint}')
platform_secret_ref=$(kubectl get aiplatform "${AIPLATFORM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.splunkConfiguration.secretRef.name}')
otel_enabled=$(kubectl get aiplatform "${AIPLATFORM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.sidecars.otel}')
mtls_enabled=$(kubectl get aiplatform "${AIPLATFORM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.mtls.enabled}')

[[ "${issuer_uri}" == "${EXPECTED_URL}" ]] || \
  fail "issuer_uri=${issuer_uri:-unset}, expected ${EXPECTED_URL}"
[[ "${platform_endpoint}" == "${EXPECTED_URL}" ]] || \
  fail "AIPlatform endpoint=${platform_endpoint:-unset}, expected ${EXPECTED_URL}"
[[ "${issuer_uri}" == "${platform_endpoint}" ]] || \
  fail "issuer_uri and AIPlatform endpoint differ"
pass "issuer_uri and AIPlatform endpoint are byte-identical short HTTPS URLs"
[[ -z "${platform_hec_endpoint}" ]] || \
  fail "AIPlatform unexpectedly contains unsupported hecEndpoint=${platform_hec_endpoint}"
[[ -z "${platform_secret_ref}" ]] || \
  fail "AIPlatform issuer-only config unexpectedly contains HEC secretRef=${platform_secret_ref}"
[[ "${otel_enabled}" == "false" ]] || \
  fail "AIPlatform sidecars.otel=${otel_enabled:-unset}, expected false"
[[ "${mtls_enabled}" == "false" ]] || \
  fail "AIPlatform mtls.enabled=${mtls_enabled:-unset}, expected false"
pass "AIPlatform explicitly fences HEC, workload OTel, and mTLS"

if kubectl get opentelemetrycollector "${AIPLATFORM_NAME}-otel-coll" \
    -n "${NAMESPACE}" >/dev/null 2>&1; then
  fail "unsupported AIPlatform OpenTelemetryCollector still exists"
fi
if kubectl get configmap "${AIPLATFORM_NAME}-otel-config" \
    -n "${NAMESPACE}" >/dev/null 2>&1; then
  fail "unsupported AIPlatform OTel configuration still exists"
fi
if kubectl get pods -n "${NAMESPACE}" -o json | jq -e '
    any(.items[];
      .metadata.annotations["sidecar.opentelemetry.io/inject"] != null
      or any(.spec.initContainers[]?; any(.env[]?; .name == "OTEL_CONFIG")))
  ' >/dev/null; then
  fail "an AI workload pod still requests or contains OTel injection"
fi
pass "AI workloads contain no OTel collector or injection configuration"

if kubectl get crd opentelemetrycollectors.opentelemetry.io >/dev/null 2>&1 && \
   kubectl get pods -n opentelemetry-operator-system -o json 2>/dev/null | jq -e '
     any(.items[];
       .status.phase == "Running"
       and any(.status.conditions[]?; .type == "Ready" and .status == "True"))
   ' >/dev/null; then
  pass "optional OTel operator infrastructure is installed and Ready"
else
  printf 'WARN: optional OTel operator infrastructure is not Ready; workload OTel remains disabled\n' >&2
fi

platform_uid=$(kubectl get aiplatform "${AIPLATFORM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.metadata.uid}')
[[ -n "${platform_uid}" ]] || fail "AIPlatform ${AIPLATFORM_NAME} has no UID"

# AIPlatform reconciliation is asynchronous. Poll only the owner chain selected
# by --aiplatform so stale or unrelated AIService resources cannot skew results.
reconcile_deadline=$((SECONDS + WAIT_TIMEOUT))
owned_ai_service_names_json='[]'
issuer_rows=''
while (( SECONDS < reconcile_deadline )); do
  ai_services_json=$(kubectl get aiservice -n "${NAMESPACE}" -o json)
  owned_ai_service_names_json=$(printf '%s\n' "${ai_services_json}" | jq -c --arg uid "${platform_uid}" '
    [.items[]
      | select(any(.metadata.ownerReferences[]?; .uid == $uid))
      | .metadata.name]
  ')
  configmaps_json=$(kubectl get configmap -n "${NAMESPACE}" -o json)
  issuer_rows=$(printf '%s\n' "${configmaps_json}" | jq -r \
    --argjson names "${owned_ai_service_names_json}" '
      .items[]
      | select(.data.SPLUNK_ISSUERS != null)
      | select(any(.metadata.ownerReferences[]?;
          .kind == "AIService" and (.name as $owner | $names | index($owner))))
      | [.metadata.name, .data.SPLUNK_ISSUERS]
      | @tsv
    ')
  if [[ "$(printf '%s\n' "${owned_ai_service_names_json}" | jq 'length')" -gt 0 && \
        -n "${issuer_rows}" ]]; then
    break
  fi
  sleep 5
done

[[ "$(printf '%s\n' "${owned_ai_service_names_json}" | jq 'length')" -gt 0 ]] || \
  fail "no AIService owned by AIPlatform ${AIPLATFORM_NAME} after ${WAIT_TIMEOUT}s"
[[ -n "${issuer_rows}" ]] || \
  fail "no owned SAIA/Slim SPLUNK_ISSUERS ConfigMap after ${WAIT_TIMEOUT}s"

issuer_configmaps=()
while IFS= read -r issuer_row; do
  [[ -n "${issuer_row}" ]] && issuer_configmaps+=("${issuer_row}")
done <<<"${issuer_rows}"
for issuer_row in "${issuer_configmaps[@]}"; do
  configmap_name="${issuer_row%%$'\t'*}"
  configured_issuers="${issuer_row#*$'\t'}"
  case ",${configured_issuers}," in
    *,"${EXPECTED_URL}",*) ;;
    *) fail "ConfigMap ${configmap_name} does not include ${EXPECTED_URL}" ;;
  esac
  pass "ConfigMap ${configmap_name} trusts the short native-HTTPS issuer"
done

deployments_json=$(kubectl get deployment -n "${NAMESPACE}" -o json)
deployment_rows=$(printf '%s\n' "${deployments_json}" | jq -r \
  --argjson names "${owned_ai_service_names_json}" '
    .items[]
    | select(any(.metadata.ownerReferences[]?;
        .kind == "AIService" and (.name as $owner | $names | index($owner))))
    | [
        .metadata.name,
        ((.spec.replicas // 1) | tostring),
        ((.status.readyReplicas // 0) | tostring),
        (.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(","))
      ]
    | @tsv
  ')
[[ -n "${deployment_rows}" ]] || \
  fail "no Deployments owned by the selected AIPlatform's AIServices"

consumer_env_count=0
saia_image_count=0
jwks_endpoint_checked=false
while IFS=$'\t' read -r deployment_name desired_replicas ready_replicas pod_selector; do
  [[ -n "${deployment_name}" ]] || continue
  (( ready_replicas >= desired_replicas )) || \
    fail "Deployment ${deployment_name} ready=${ready_replicas}/${desired_replicas}"

  pod_json=$(kubectl get pods -n "${NAMESPACE}" -l "${pod_selector}" -o json)
  pod_name=$(printf '%s\n' "${pod_json}" | jq -r '
    [.items[]
      | select(.metadata.deletionTimestamp == null)
      | select(.status.phase == "Running")
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | .metadata.name][0] // ""
  ')
  [[ -n "${pod_name}" ]] || fail "Deployment ${deployment_name} has no Running Ready pod"

  container_rows=$(printf '%s\n' "${pod_json}" | jq -r --arg pod "${pod_name}" '
    .items[] | select(.metadata.name == $pod) | .spec.containers[]
    | [.name, .image] | @tsv
  ')
  while IFS=$'\t' read -r container_name image_ref; do
    [[ -n "${container_name}" ]] || continue
    if printf '%s\n' "${image_ref}" | grep -qi 'saia'; then
      saia_image_count=$((saia_image_count + 1))
      printf 'INFO: active SAIA image %s/%s/%s = %s\n' \
        "${deployment_name}" "${pod_name}" "${container_name}" "${image_ref}"
      if [[ -n "${EXPECTED_SAIA_TAG}" && "${image_ref}" != *":${EXPECTED_SAIA_TAG}" ]]; then
        fail "active SAIA image ${image_ref} does not use expected tag ${EXPECTED_SAIA_TAG}"
      fi
    fi

    if effective_issuers=$(kubectl exec -n "${NAMESPACE}" "${pod_name}" \
        -c "${container_name}" -- printenv SPLUNK_ISSUERS 2>/dev/null); then
      case ",${effective_issuers}," in
        *,"${EXPECTED_URL}",*) ;;
        *) fail "${pod_name}/${container_name} has stale SPLUNK_ISSUERS=${effective_issuers}" ;;
      esac
      consumer_env_count=$((consumer_env_count + 1))
      pass "${pod_name}/${container_name} has the effective native HTTPS issuer"

      # Main does not install a CA bundle for SAIA/Slim. This probe deliberately
      # validates DNS/routing and native Splunk token-key payload availability
      # only; authenticated service tests must determine the selected image's
      # own TLS policy. Splunk's native management API does not provide the
      # proxy-specific /.well-known/oauth2_keys alias.
      if [[ "${jwks_endpoint_checked}" != "true" ]] && \
          kubectl exec -n "${NAMESPACE}" "${pod_name}" -c "${container_name}" -- \
            python -c '
import json, ssl, sys, urllib.request

base_url = sys.argv[1]
context = ssl._create_unverified_context()
path = "/services/authorization/tokens-keys?output_mode=json"
with urllib.request.urlopen(base_url + path, timeout=15, context=context) as response:
    assert response.status == 200, "token-key route did not return HTTP 200"
    payload = json.load(response)
encoded = json.dumps(payload)
assert "RSA" in encoded or "RS256" in encoded, "response has no RSA signing key"
' "${EXPECTED_URL}" >/dev/null 2>&1; then
        jwks_endpoint_checked=true
        pass "consumer pod reaches the native HTTPS token-key route"
      fi
    fi
  done <<<"${container_rows}"
done <<<"${deployment_rows}"

(( consumer_env_count > 0 )) || fail "no active consumer container exposes SPLUNK_ISSUERS"
(( saia_image_count > 0 )) || fail "no active SAIA image reference found"
[[ "${jwks_endpoint_checked}" == "true" ]] || \
  fail "no consumer container could reach the native HTTPS token-key route through ${EXPECTED_URL}"
[[ -z "${EXPECTED_SAIA_TAG}" ]] || pass "all active SAIA images use ${EXPECTED_SAIA_TAG}"

printf '\nAIP-4614 native-HTTPS internal Splunk validation passed.\n'
