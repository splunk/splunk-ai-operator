#!/usr/bin/env bash
# Opt-in AIP-4614 authenticated integration test for a live internal-Splunk
# cluster. This test reads the operator-managed Splunk admin Secret and mints a
# short-lived interactive JWT. It never prints or stores either credential.

set -euo pipefail
set +x

NAMESPACE="ai-platform"
STANDALONE_NAME="splunk-standalone"
AIPLATFORM_NAME=""
SAIA_TENANT="tenant-id-sok"
SLIM_TENANT="admin"

usage() {
  cat <<'EOF'
Usage: test_internal_splunk_authenticated.sh [options]

Options:
  --namespace NAME       Namespace containing Splunk and AIPlatform
                         (default: ai-platform)
  --standalone NAME      Standalone CR name (default: splunk-standalone)
  --aiplatform NAME      AIPlatform CR name (auto-discovered when unique)
  --saia-tenant NAME     Tenant used for the SAIA metadata request
                         (default: tenant-id-sok)
  --slim-tenant NAME     Tenant used for the Slim models request
                         (default: admin)
  -h, --help             Show this help

The active kubectl context/KUBECONFIG is used. This opt-in test reads the
operator-managed Splunk admin Secret and mints a short-lived interactive JWT.
The password and token remain inside a single in-pod Python process and are
never printed, passed as command arguments, or written to files.
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
    --saia-tenant)
      SAIA_TENANT="${2:?--saia-tenant requires a value}"
      shift 2
      ;;
    --slim-tenant)
      SLIM_TENANT="${2:?--slim-tenant requires a value}"
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

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ -z "${AIPLATFORM_NAME}" ]]; then
  platform_names_json=$(kubectl get aiplatform -n "${NAMESPACE}" -o json | \
    jq -c '[.items[].metadata.name]')
  [[ "$(printf '%s\n' "${platform_names_json}" | jq 'length')" -eq 1 ]] || \
    fail "expected exactly one AIPlatform in ${NAMESPACE}; pass --aiplatform explicitly"
  AIPLATFORM_NAME=$(printf '%s\n' "${platform_names_json}" | jq -r '.[0]')
fi

platform_json=$(kubectl get aiplatform "${AIPLATFORM_NAME}" -n "${NAMESPACE}" -o json) || \
  fail "could not read AIPlatform ${NAMESPACE}/${AIPLATFORM_NAME}"
platform_uid=$(printf '%s\n' "${platform_json}" | jq -r '.metadata.uid // ""')
expected_issuer=$(printf '%s\n' "${platform_json}" | \
  jq -r '.spec.splunkConfiguration.endpoint // ""')
[[ -n "${platform_uid}" ]] || fail "AIPlatform ${AIPLATFORM_NAME} has no UID"
[[ "${expected_issuer}" == https://*:8089 ]] || \
  fail "AIPlatform endpoint is not the expected internal HTTPS management URL"

ai_services_json=$(kubectl get aiservice -n "${NAMESPACE}" -o json)
find_owned_feature() {
  local feature_name="$1"
  printf '%s\n' "${ai_services_json}" | jq -r \
    --arg uid "${platform_uid}" --arg feature "${feature_name}" '
      [.items[]
       | select(any(.metadata.ownerReferences[]?; .uid == $uid))
       | select((.metadata.labels.feature // .spec.feature.name // "") == $feature)
       | .metadata.name]
      | if length == 1 then .[0] else empty end
    '
}

saia_ai_service=$(find_owned_feature saia)
slim_ai_service=$(find_owned_feature slim)
[[ -n "${saia_ai_service}" ]] || \
  fail "expected exactly one SAIA AIService owned by ${AIPLATFORM_NAME}"
[[ -n "${slim_ai_service}" ]] || \
  fail "expected exactly one Slim AIService owned by ${AIPLATFORM_NAME}"

saia_service="${saia_ai_service}-saia-service"
slim_service="${slim_ai_service}-slim-service"
kubectl get service "${saia_service}" -n "${NAMESPACE}" >/dev/null || \
  fail "SAIA Service ${NAMESPACE}/${saia_service} is missing"
kubectl get service "${slim_service}" -n "${NAMESPACE}" >/dev/null || \
  fail "Slim Service ${NAMESPACE}/${slim_service} is missing"

splunk_pod="splunk-${STANDALONE_NAME}-standalone-0"
splunk_secret="splunk-${STANDALONE_NAME}-standalone-secret-v1"
kubectl get pod "${splunk_pod}" -n "${NAMESPACE}" >/dev/null || \
  fail "Splunk pod ${NAMESPACE}/${splunk_pod} is missing"
kubectl get secret "${splunk_secret}" -n "${NAMESPACE}" >/dev/null || \
  fail "Splunk Secret ${NAMESPACE}/${splunk_secret} is missing"
kubectl exec -n "${NAMESPACE}" "${splunk_pod}" -- \
  test -d /opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud/lib || \
  fail "Splunk AI Assistant app libraries are not installed in ${splunk_pod}"

saia_url="http://${saia_service}.${NAMESPACE}.svc.cluster.local:8080/${SAIA_TENANT}/saia-api/v1alpha1/api/metadata"
slim_url="http://${slim_service}.${NAMESPACE}.svc.cluster.local:8080/${SLIM_TENANT}/slim-api/v1alpha1/chat/models"

python_code=$(cat <<'PY'
import base64
import json
import os
import sys
import uuid

stage = "decode-password"
try:
    encoded_password = sys.stdin.read().strip()
    password = base64.b64decode(encoded_password, validate=True).decode("utf-8")
    if not password:
        raise RuntimeError("empty password")

    stage = "load-app-sdk"
    sys.path.insert(0, "/opt/splunk/etc/apps/Splunk_AI_Assistant_Cloud/lib")
    import requests
    from splunklib.client import connect
    from spl_gen.utils import read_splk_content

    stage = "local-sdk-https"
    # Deliberately omit scheme and port, matching the immutable app. Its bundled
    # SDK must retain the native https://127.0.0.1:8089 default contract.
    service = connect(
        username="admin",
        password=password,
        host="127.0.0.1",
        app="Splunk_AI_Assistant_Cloud",
        owner="admin",
        retries=2,
        retryDelay=1,
    )
    service.get("/services/server/info", output_mode="json")
    print("PASS: bundled app SDK reached local splunkd over native HTTPS")

    stage = "mint-interactive-token"
    response = service.post(
        "/services/authorization/tokens",
        type="interactive",
        output_mode="json",
    )
    token = read_splk_content(response).get("token")
    if not token:
        raise RuntimeError("interactive token missing")

    parts = token.split(".")
    if len(parts) != 3:
        raise RuntimeError("interactive token is not a JWT")
    payload = json.loads(
        base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4))
    )
    if payload.get("iss") != os.environ["EXPECTED_ISSUER"]:
        raise RuntimeError("JWT issuer mismatch")
    if not payload.get("exp"):
        raise RuntimeError("JWT has no expiration")
    print("PASS: fresh interactive JWT has the configured issuer and expiration")

    session = requests.Session()
    session.trust_env = False
    for label, env_name in (("SAIA", "SAIA_URL"), ("Slim", "SLIM_URL")):
        stage = label.lower() + "-authenticated-request"
        result = session.get(
            os.environ[env_name],
            headers={
                "Authorization": "Bearer " + token,
                "request_id": str(uuid.uuid4()),
            },
            timeout=30,
        )
        if result.status_code != 200:
            raise RuntimeError(label + " returned a non-200 status")
        result.json()
        print("PASS: fresh Splunk JWT authenticated to " + label + " (HTTP 200)")
except Exception as exc:
    # Keep failures diagnosable without printing exception text, response
    # bodies, credentials, request headers, or the JWT.
    print(
        "FAIL: stage=" + stage + " exception=" + type(exc).__name__,
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
)

# Stream the encoded Secret value directly into the in-pod process. The shell
# never holds the decoded password or the JWT, and command tracing is disabled.
kubectl get secret "${splunk_secret}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.password}' | \
  kubectl exec -i -n "${NAMESPACE}" "${splunk_pod}" -- env \
    "EXPECTED_ISSUER=${expected_issuer}" \
    "SAIA_URL=${saia_url}" \
    "SLIM_URL=${slim_url}" \
    /opt/splunk/bin/splunk cmd python3 -c "${python_code}"

printf '\nAIP-4614 authenticated SAIA and Slim validation passed.\n'
