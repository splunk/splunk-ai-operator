#!/usr/bin/env bash

# Reusable baseline smoke check for the standalone LangSmith Agent Server.
# It writes one synthetic thread/run to LAS and verifies that the resulting
# state can be read back. It does not manage Kubernetes or dependency resources.

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/las-baseline-smoke.sh

Required environment:
  LAS_BASE_URL                  LAS API base URL, usually a local port-forward.
  LAS_OPERATOR_IMAGE            Operator manager image reference.
  LAS_OPERATOR_IMAGE_DIGEST     Operator manager image sha256 digest.
  LAS_CHART_VERSION             Pinned langgraph-cloud chart version.
  LAS_CHART_SHA256              SHA256 digest of the chart archive.
  LAS_AGENT_SERVER_IMAGE        Product Agent Server image reference.
  LAS_AGENT_SERVER_DIGEST       Product Agent Server image sha256 digest.

Optional environment:
  LAS_GRAPH_ID                  Graph/assistant ID (default: echo).
  LAS_EXPECTED_RESPONSE_PREFIX  Expected sample response prefix
                                (default: "LAS sample agent received: ").
  LAS_REQUEST_TIMEOUT_SECONDS   Per-request timeout (default: 30).

Example:
  LAS_BASE_URL=http://127.0.0.1:18083 \
  LAS_OPERATOR_IMAGE=registry/operator:tag \
  LAS_OPERATOR_IMAGE_DIGEST=sha256:... \
  LAS_CHART_VERSION=0.3.4 \
  LAS_CHART_SHA256=... \
  LAS_AGENT_SERVER_IMAGE=registry/sample-agent:tag \
  LAS_AGENT_SERVER_DIGEST=sha256:... \
  scripts/las-baseline-smoke.sh

The script prints sanitized key/value results. It never prints HTTP response
bodies, credentials, or the full API URL. The smoke thread/run remains in LAS
state so the persistence check is observable.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

fail() {
  local step="$1"
  local reason="$2"
  emit_report "FAIL" "$step" "$reason"
  exit 1
}

emit_report() {
  local overall="$1"
  local failed_step="${2:-none}"
  local failure_reason="${3:-none}"
  printf '%s\n' \
    "result=${overall}" \
    "failed_step=${failed_step}" \
    "failure_reason=${failure_reason}" \
    "endpoint=${ENDPOINT_HOST:-unavailable}" \
    "graph_id=${GRAPH_ID:-unavailable}" \
    "thread_id=${THREAD_ID:-unavailable}" \
    "health=${HEALTH_RESULT:-NOT_RUN}" \
    "thread=${THREAD_RESULT:-NOT_RUN}" \
    "run=${RUN_RESULT:-NOT_RUN}" \
    "state=${STATE_RESULT:-NOT_RUN}" \
    "operator_image=${LAS_OPERATOR_IMAGE:-unavailable}" \
    "operator_image_digest=${LAS_OPERATOR_IMAGE_DIGEST:-unavailable}" \
    "chart_version=${LAS_CHART_VERSION:-unavailable}" \
    "chart_sha256=${LAS_CHART_SHA256:-unavailable}" \
    "agent_server_image=${LAS_AGENT_SERVER_IMAGE:-unavailable}" \
    "agent_server_digest=${LAS_AGENT_SERVER_DIGEST:-unavailable}" \
    "request_marker=${REQUEST_MARKER:-unavailable}"
}

required_vars=(
  LAS_BASE_URL
  LAS_OPERATOR_IMAGE
  LAS_OPERATOR_IMAGE_DIGEST
  LAS_CHART_VERSION
  LAS_CHART_SHA256
  LAS_AGENT_SERVER_IMAGE
  LAS_AGENT_SERVER_DIGEST
)
for name in "${required_vars[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'Missing required environment variable: %s\n\n' "$name" >&2
    usage >&2
    exit 2
  fi
  if [[ "${!name}" == *$'\n'* || "${!name}" == *$'\r'* ]]; then
    printf 'Environment variable %s must be a single line.\n' "$name" >&2
    exit 2
  fi
done

GRAPH_ID="${LAS_GRAPH_ID:-echo}"
EXPECTED_RESPONSE_PREFIX="${LAS_EXPECTED_RESPONSE_PREFIX:-LAS sample agent received: }"
REQUEST_TIMEOUT="${LAS_REQUEST_TIMEOUT_SECONDS:-30}"
if [[ ! "$REQUEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  printf 'LAS_REQUEST_TIMEOUT_SECONDS must be a positive integer.\n' >&2
  exit 2
fi

command -v curl >/dev/null 2>&1 || { printf 'curl is required.\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'python3 is required.\n' >&2; exit 2; }

URL_DETAILS="$(python3 - "$LAS_BASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError
    if parsed.username is not None or parsed.password is not None:
        raise ValueError
    if parsed.query or parsed.fragment:
        raise ValueError
    host = parsed.hostname
    if ":" in host:
        host = f"[{host}]"
    if parsed.port:
        host = f"{host}:{parsed.port}"
    print(parsed.scheme)
    print(parsed.path.rstrip("/"))
    print(host)
except (ValueError, TypeError):
    print("Invalid LAS_BASE_URL: provide an http(s) URL without userinfo, query, or fragment.", file=sys.stderr)
    sys.exit(1)
PY
)" || exit 2
URL_REMAINDER="${URL_DETAILS#*$'\n'}"
URL_SCHEME="${URL_DETAILS%%$'\n'*}"
URL_PATH="${URL_REMAINDER%%$'\n'*}"
ENDPOINT_HOST="${URL_REMAINDER#*$'\n'}"
BASE_URL="${LAS_BASE_URL%/}"
if [[ -n "$URL_PATH" ]]; then
  BASE_URL="${URL_SCHEME}://${ENDPOINT_HOST}${URL_PATH}"
else
  BASE_URL="${URL_SCHEME}://${ENDPOINT_HOST}"
fi

RUN_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
REQUEST_MARKER="las-baseline-smoke-${RUN_UUID}"
EXPECTED_RESPONSE="${EXPECTED_RESPONSE_PREFIX}${REQUEST_MARKER}"
HEALTH_RESULT="NOT_RUN"
THREAD_RESULT="NOT_RUN"
RUN_RESULT="NOT_RUN"
STATE_RESULT="NOT_RUN"
THREAD_ID=""

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/las-baseline-smoke.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

http_request() {
  local method="$1"
  local path="$2"
  local response_file="$3"
  local payload="${4:-}"
  local -a args=(
    --silent
    --output "$response_file"
    --write-out '%{http_code}'
    --connect-timeout 5
    --max-time "$REQUEST_TIMEOUT"
    --request "$method"
    --header 'Accept: application/json'
  )
  if [[ -n "$payload" ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "$payload")
  fi
  if ! HTTP_STATUS="$(curl "${args[@]}" "${BASE_URL}${path}" 2>/dev/null)"; then
    HTTP_STATUS="000"
    return 1
  fi
  return 0
}

is_healthy() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as response:
        payload = json.load(response)
    sys.exit(0 if isinstance(payload, dict) and payload.get("ok") is True else 1)
except (OSError, ValueError):
    sys.exit(1)
PY
}

get_thread_id() {
  python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as response:
        payload = json.load(response)
    thread_id = payload.get("thread_id") if isinstance(payload, dict) else None
    if not isinstance(thread_id, str) or not thread_id or "\n" in thread_id or "\r" in thread_id:
        raise ValueError
    print(thread_id)
except (OSError, ValueError, AttributeError):
    sys.exit(1)
PY
}

path_segment() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
}

has_expected_output() {
  python3 - "$1" "$REQUEST_MARKER" "$EXPECTED_RESPONSE" <<'PY'
import json
import sys

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)

try:
    with open(sys.argv[1], encoding="utf-8") as response:
        payload = json.load(response)
    values = list(strings(payload))
    marker, expected = sys.argv[2], sys.argv[3]
    sys.exit(0 if marker in values and expected in values else 1)
except (OSError, ValueError):
    sys.exit(1)
PY
}

has_expected_state_values() {
  python3 - "$1" "$REQUEST_MARKER" "$EXPECTED_RESPONSE" <<'PY'
import json
import sys

def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from strings(child)

try:
    with open(sys.argv[1], encoding="utf-8") as response:
        payload = json.load(response)
    if not isinstance(payload, dict) or "values" not in payload:
        sys.exit(1)
    state_values = list(strings(payload["values"]))
    marker, expected = sys.argv[2], sys.argv[3]
    sys.exit(0 if marker in state_values and expected in state_values else 1)
except (OSError, ValueError):
    sys.exit(1)
PY
}

# Health check
if ! http_request GET "/ok" "$WORK_DIR/health.json"; then
  fail health connection_failed
fi
if [[ "$HTTP_STATUS" != "200" ]] || ! is_healthy "$WORK_DIR/health.json"; then
  fail health "http_${HTTP_STATUS}_or_invalid_health_body"
fi
HEALTH_RESULT="PASS"

# Create a fresh thread for this invocation.
if ! http_request POST "/threads" "$WORK_DIR/thread.json" '{}'; then
  fail thread connection_failed
fi
if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "201" ]]; then
  fail thread "http_${HTTP_STATUS}"
fi
if ! THREAD_ID="$(get_thread_id "$WORK_DIR/thread.json")"; then
  fail thread invalid_thread_response
fi
THREAD_RESULT="PASS"
THREAD_PATH="$(path_segment "$THREAD_ID")"

# Run the deterministic sample graph synchronously and verify its output.
RUN_PAYLOAD="$(python3 - "$GRAPH_ID" "$REQUEST_MARKER" <<'PY'
import json
import sys

print(json.dumps({
    "assistant_id": sys.argv[1],
    "input": {"request": sys.argv[2]},
}, separators=(",", ":")))
PY
)"
if ! http_request POST "/threads/${THREAD_PATH}/runs/wait" "$WORK_DIR/run.json" "$RUN_PAYLOAD"; then
  fail run connection_failed
fi
if [[ "$HTTP_STATUS" != "200" ]]; then
  fail run "http_${HTTP_STATUS}"
fi
if ! has_expected_output "$WORK_DIR/run.json" "$REQUEST_MARKER" "$EXPECTED_RESPONSE"; then
  fail run expected_output_missing
fi
RUN_RESULT="PASS"

# Read the thread state in a separate request and verify persistence.
if ! http_request GET "/threads/${THREAD_PATH}/state" "$WORK_DIR/state.json"; then
  fail state connection_failed
fi
if [[ "$HTTP_STATUS" != "200" ]]; then
  fail state "http_${HTTP_STATUS}"
fi
if ! has_expected_state_values "$WORK_DIR/state.json"; then
  fail state persisted_output_missing
fi
STATE_RESULT="PASS"

emit_report PASS
