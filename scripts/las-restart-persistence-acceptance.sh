#!/usr/bin/env bash

# Never allow an inherited xtrace setting to print the trusted stdin scenario.
set +x
# Disposable-cluster-only verification of persisted LAS state across restarts.
set -Eeuo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/las-restart-persistence-acceptance.sh

Required environment:
  LAS_DISPOSABLE_CLUSTER_CONFIRMED=true
  LAS_BASE_URL                    Local http URL reserved for this script's port-forward.
  LAS_NAMESPACE                   Namespace containing the LAS release.
  LAS_EXPECTED_KUBE_CONTEXT       Exact kubectl context permitted for mutation.
  LAS_EXPECTED_NAMESPACE_UID      Exact namespace UID permitted for mutation.
  LAS_API_DEPLOYMENT              Exact API Deployment name.
  LAS_QUEUE_DEPLOYMENT            Exact queue Deployment name.
  LAS_API_SERVICE                 Exact API Service used for port-forwarding.
  LAS_API_SERVICE_UID             Exact immutable UID of LAS_API_SERVICE.
  LAS_API_SERVICE_PORT            Remote Service port used by the Agent Server API.
  LAS_OPERATOR_NAMESPACE          Namespace containing the operator Deployment.
  LAS_OPERATOR_DEPLOYMENT         Exact operator Deployment name.
  LAS_OPERATOR_IMAGE              Deployed operator image reference.
  LAS_OPERATOR_IMAGE_DIGEST       Resolved operator image digest.
  LAS_CHART_NAME                  Exact deployed Helm chart name.
  LAS_CHART_VERSION               Embedded LAS chart version.
  LAS_CHART_SHA256                Embedded LAS chart archive digest.
  LAS_HELM_RELEASE                Exact deployed LAS Helm release.
  LAS_AGENT_SERVER_IMAGE          Deployed Launchpad image reference.
  LAS_AGENT_SERVER_DIGEST         Resolved Launchpad image digest.

Optional:
  LAS_REQUEST_TIMEOUT             Per-request seconds (default 180).
  LAS_RUN_TIMEOUT                 Run completion seconds (default 600).
  LAS_RUNNING_TIMEOUT             Wait-for-running seconds (default 180).
  LAS_ROLLOUT_TIMEOUT             kubectl rollout duration (default 300s).
  LAS_HELM_NAMESPACE              Defaults to LAS_NAMESPACE.
  HELM                            Defaults to helm.

Pipe a trusted product protocol scenario to stdin. It must request sync,
queued, and stream modes and set cleanup_threads=false. The script owns an
exact Service port-forward, recreates it after the API rollout, verifies graph
state and complete bounded checkpoint history before and after API and queue
restarts, then deletes every thread it created.

An optional active_run_case is submitted before queue replacement and verified
after replacement. Use a bounded long-running product call. Use only on a
disposable cluster.
EOF
  exit 0
fi

required=(
  LAS_DISPOSABLE_CLUSTER_CONFIRMED LAS_BASE_URL LAS_NAMESPACE
  LAS_EXPECTED_KUBE_CONTEXT LAS_EXPECTED_NAMESPACE_UID
  LAS_API_DEPLOYMENT LAS_QUEUE_DEPLOYMENT LAS_API_SERVICE LAS_API_SERVICE_UID
  LAS_API_SERVICE_PORT
  LAS_OPERATOR_NAMESPACE LAS_OPERATOR_DEPLOYMENT
  LAS_OPERATOR_IMAGE LAS_OPERATOR_IMAGE_DIGEST
  LAS_CHART_NAME LAS_CHART_VERSION LAS_CHART_SHA256 LAS_HELM_RELEASE
  LAS_AGENT_SERVER_IMAGE LAS_AGENT_SERVER_DIGEST
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'Missing required environment variable: %s\n' "$name" >&2
    exit 2
  fi
done
if [[ "$LAS_DISPOSABLE_CLUSTER_CONFIRMED" != "true" ]]; then
  printf 'Set LAS_DISPOSABLE_CLUSTER_CONFIRMED=true only for a disposable cluster.\n' >&2
  exit 2
fi
if [[ ! "$LAS_OPERATOR_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || [[ ! "$LAS_AGENT_SERVER_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || [[ ! "$LAS_CHART_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  printf 'Image and chart identities must use lowercase sha256 values.\n' >&2
  exit 2
fi
for resource_name in \
  "$LAS_NAMESPACE" "$LAS_API_DEPLOYMENT" "$LAS_QUEUE_DEPLOYMENT" "$LAS_API_SERVICE" \
  "$LAS_OPERATOR_NAMESPACE" "$LAS_OPERATOR_DEPLOYMENT" "$LAS_CHART_NAME" \
  "${LAS_HELM_NAMESPACE:-$LAS_NAMESPACE}" "$LAS_HELM_RELEASE"; do
  if [[ ! "$resource_name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
    printf 'Namespace and Kubernetes resource names must be simple DNS names.\n' >&2
    exit 2
  fi
done
if [[ ! "$LAS_API_SERVICE_PORT" =~ ^[0-9]+$ ]] \
  || (( LAS_API_SERVICE_PORT < 1 || LAS_API_SERVICE_PORT > 65535 )); then
  printf 'LAS_API_SERVICE_PORT must be in the range 1..65535.\n' >&2
  exit 2
fi
if [[ ! "$LAS_API_SERVICE_UID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; then
  printf 'LAS_API_SERVICE_UID must be one exact safe Kubernetes UID.\n' >&2
  exit 2
fi

LAS_REQUEST_TIMEOUT="${LAS_REQUEST_TIMEOUT:-180}"
LAS_RUN_TIMEOUT="${LAS_RUN_TIMEOUT:-600}"
LAS_RUNNING_TIMEOUT="${LAS_RUNNING_TIMEOUT:-180}"
LAS_ROLLOUT_TIMEOUT="${LAS_ROLLOUT_TIMEOUT:-300s}"
LAS_HELM_NAMESPACE="${LAS_HELM_NAMESPACE:-$LAS_NAMESPACE}"
if [[ ! "$LAS_REQUEST_TIMEOUT" =~ ^[0-9]+$ ]] || (( LAS_REQUEST_TIMEOUT < 1 || LAS_REQUEST_TIMEOUT > 600 )) \
  || [[ ! "$LAS_RUN_TIMEOUT" =~ ^[0-9]+$ ]] || (( LAS_RUN_TIMEOUT < 30 || LAS_RUN_TIMEOUT > 1800 )) \
  || [[ ! "$LAS_RUNNING_TIMEOUT" =~ ^[0-9]+$ ]] || (( LAS_RUNNING_TIMEOUT < 10 || LAS_RUNNING_TIMEOUT > 300 )); then
  printf 'LAS timeout values are outside their supported bounds.\n' >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUALIFIER="${SCRIPT_DIR}/las-runtime-acceptance.py"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
command -v "$KUBECTL" >/dev/null 2>&1 || { printf 'kubectl is required.\n' >&2; exit 2; }
command -v "$HELM" >/dev/null 2>&1 || { printf 'helm is required.\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'python3 is required.\n' >&2; exit 2; }

kubectl_scoped() {
  "$KUBECTL" --context "$LAS_EXPECTED_KUBE_CONTEXT" "$@"
}
[[ -r "$QUALIFIER" ]] || { printf 'LAS runtime acceptance script is missing.\n' >&2; exit 2; }

verify_cluster_scope() {
  actual_context="$("$KUBECTL" config current-context)" || return 1
  actual_namespace_uid="$(kubectl_scoped get namespace "$LAS_NAMESPACE" -o 'jsonpath={.metadata.uid}')" || return 1
  [[ "$actual_context" == "$LAS_EXPECTED_KUBE_CONTEXT" \
    && -n "$actual_namespace_uid" \
    && "$actual_namespace_uid" == "$LAS_EXPECTED_NAMESPACE_UID" ]]
}
verify_cluster_scope || {
  printf 'Kubernetes context or namespace identity does not match the approved target.\n' >&2
  exit 2
}

PF_LOCAL_PORT="$(LAS_BASE_URL="$LAS_BASE_URL" python3 -c '
import os
import urllib.parse
value = urllib.parse.urlsplit(os.environ["LAS_BASE_URL"])
if (
    value.scheme != "http"
    or value.hostname not in {"127.0.0.1", "localhost"}
    or value.username
    or value.password
    or value.query
    or value.fragment
    or value.path not in {"", "/"}
    or value.port is None
    or not 1024 <= value.port <= 65535
):
    raise SystemExit(1)
print(value.port)
')" || {
  printf 'LAS_BASE_URL must be an uncredentialed localhost http URL on port 1024..65535.\n' >&2
  exit 2
}

scenario="$(cat)"
if [[ -z "$scenario" ]]; then
  printf 'A trusted product protocol scenario is required on stdin.\n' >&2
  exit 2
fi
if ! printf '%s' "$scenario" | python3 -c '
import json
import sys
value = json.load(sys.stdin)
if not isinstance(value, dict) or value.get("cleanup_threads") is not False:
    raise SystemExit(1)
cases = value.get("cases")
scenario_sensitive = value.get("sensitive_values", [])
if (
    not isinstance(cases, list)
    or not cases
    or not isinstance(scenario_sensitive, list)
    or not all(isinstance(item, str) for item in scenario_sensitive)
):
    raise SystemExit(1)
required_modes = {"sync", "queued", "stream"}
def contains_marker(value, marker):
    if isinstance(value, dict):
        return any(contains_marker(item, marker) for item in value.values())
    if isinstance(value, list):
        return any(contains_marker(item, marker) for item in value)
    return isinstance(value, str) and marker in value
for case in cases:
    if not isinstance(case, dict) or set(case.get("run_modes", [])) != required_modes:
        raise SystemExit(1)
    expected = case.get("expected_state_values")
    placeholder = case.get("marker_placeholder", "{{RUN_MARKER}}")
    sensitive = scenario_sensitive + case.get("sensitive_values", [])
    if (
        not isinstance(expected, list)
        or not expected
        or not isinstance(placeholder, str)
        or not placeholder
        or not isinstance(sensitive, list)
        or not all(isinstance(item, str) for item in sensitive)
        or not contains_marker(expected, placeholder)
        or not contains_marker(
            {
                "input": case.get("input"),
                "context": case.get("context"),
            },
            placeholder,
        )
    ):
        raise SystemExit(1)
    for item in expected:
        if (
            not isinstance(item, str)
            or not item
            or any(character in item for character in "\t\r\n")
            or any(secret and secret in item for secret in sensitive)
        ):
            raise SystemExit(1)
active = value.get("active_run_case")
if active is not None and not isinstance(active, dict):
    raise SystemExit(1)
'; then
  printf 'Scenario must contain safe sync, queued, and stream cases with cleanup_threads=false.\n' >&2
  exit 2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/las-restart-acceptance.XXXXXX")"
PF_PID=""
declare -a THREAD_IDS=()
declare -A THREAD_IDS_SEEN=()

record_thread() {
  local thread_id="$1"
  if [[ -n "$thread_id" && -z "${THREAD_IDS_SEEN[$thread_id]:-}" ]]; then
    THREAD_IDS+=("$thread_id")
    THREAD_IDS_SEEN["$thread_id"]=1
  fi
}

stop_port_forward() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" >/dev/null 2>&1 || true
    PF_PID=""
  fi
}

start_port_forward() {
  local attempt
  verify_cluster_scope || return 1
  verify_api_service_binding || return 1
  stop_port_forward
  : >"$WORK_DIR/port-forward.log"
  kubectl_scoped -n "$LAS_NAMESPACE" port-forward \
    "service/${LAS_API_SERVICE}" "${PF_LOCAL_PORT}:${LAS_API_SERVICE_PORT}" \
    >"$WORK_DIR/port-forward.log" 2>&1 &
  PF_PID=$!
  for attempt in {1..60}; do
    if ! kill -0 "$PF_PID" >/dev/null 2>&1; then
      printf 'Managed LAS API port-forward exited before becoming healthy.\n' >&2
      return 1
    fi
    if LAS_BASE_URL="$LAS_BASE_URL" python3 "$QUALIFIER" health \
      --request-timeout 2 >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  printf 'Managed LAS API port-forward did not become healthy.\n' >&2
  return 1
}

cleanup() {
  local original_status="$1" thread_id cleanup_failed=0
  set +e
  if (( ${#THREAD_IDS[@]} > 0 )); then
    if [[ -z "$PF_PID" ]] || ! kill -0 "$PF_PID" >/dev/null 2>&1; then
      start_port_forward >/dev/null 2>&1 || true
    fi
    for thread_id in "${THREAD_IDS[@]}"; do
      printf '%s' "$scenario" | LAS_BASE_URL="$LAS_BASE_URL" \
        python3 "$QUALIFIER" delete-thread --scenario-stdin \
        --thread-id "$thread_id" --request-timeout "$LAS_REQUEST_TIMEOUT" >/dev/null 2>&1 || {
        cleanup_failed=1
        printf 'qualification_thread_cleanup=FAIL (a retained thread may require manual cleanup)\n' >&2
      }
    done
  fi
  stop_port_forward
  rm -rf "$WORK_DIR"
  if (( cleanup_failed != 0 && original_status == 0 )); then
    return 1
  fi
  return "$original_status"
}
trap 'cleanup $?' EXIT

record_threads_from_result() {
  local result="$1" thread_id
  while IFS= read -r thread_id; do
    record_thread "$thread_id"
  done < <(python3 -c '
import json
import sys
value = json.loads(sys.argv[1])
for thread_id in dict.fromkeys(
    check.get("thread_id") for check in value.get("checks", []) if isinstance(check, dict)
):
    if isinstance(thread_id, str) and thread_id:
        print(thread_id)
' "$result")
}

verify_deployment_identity() {
  local namespace="$1" deployment="$2" expected_image="$3" expected_digest="$4"
  local identity_data selector container_names
  identity_data="$(kubectl_scoped -n "$namespace" get deployment "$deployment" -o json | \
    EXPECTED_IMAGE="$expected_image" python3 -c '
import json, os, sys
value = json.load(sys.stdin)
containers = value.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
names = [item.get("name") for item in containers if item.get("image") == os.environ["EXPECTED_IMAGE"]]
labels = value.get("spec", {}).get("selector", {}).get("matchLabels", {})
if not names or any(not isinstance(name, str) or not name for name in names) or not labels:
    raise SystemExit(1)
selector = ",".join(f"{key}={value}" for key, value in sorted(labels.items()))
print(selector + "\t" + ",".join(names))
')" || return 1
  IFS=$'\t' read -r selector container_names <<<"$identity_data"
  kubectl_scoped -n "$namespace" get pods -l "$selector" -o json | \
    EXPECTED_DIGEST="$expected_digest" EXPECTED_CONTAINER_NAMES="$container_names" python3 -c '
import json, os, sys
items = json.load(sys.stdin).get("items", [])
digest = os.environ["EXPECTED_DIGEST"]
names = set(os.environ["EXPECTED_CONTAINER_NAMES"].split(","))
for item in items:
    statuses = {
        status.get("name"): status.get("imageID", "")
        for status in item.get("status", {}).get("containerStatuses", [])
    }
    if any(name not in statuses or digest not in statuses[name] for name in names):
        raise SystemExit(1)
if not items:
    raise SystemExit(1)
'
}

verify_api_service_binding() {
  EXPECTED_SERVICE_UID="$LAS_API_SERVICE_UID" \
  EXPECTED_SERVICE_PORT="$LAS_API_SERVICE_PORT" \
  EXPECTED_NAMESPACE="$LAS_NAMESPACE" \
  EXPECTED_IMAGE="$LAS_AGENT_SERVER_IMAGE" \
  EXPECTED_DIGEST="$LAS_AGENT_SERVER_DIGEST" \
  python3 -c '
import json, os, sys

def read(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)

deployment, service, pod_list, slice_list = map(read, sys.argv[1:5])
selector_spec = deployment.get("spec", {}).get("selector", {})
selector = selector_spec.get("matchLabels", {})
if (
    not isinstance(selector, dict)
    or not selector
    or selector_spec.get("matchExpressions") not in (None, [])
):
    raise SystemExit(1)
if service.get("metadata", {}).get("uid") != os.environ["EXPECTED_SERVICE_UID"]:
    raise SystemExit(1)
if service.get("spec", {}).get("selector") != selector:
    raise SystemExit(1)
expected_port = int(os.environ["EXPECTED_SERVICE_PORT"])
service_ports = [
    port for port in service.get("spec", {}).get("ports", [])
    if isinstance(port, dict) and port.get("port") == expected_port
]
if len(service_ports) != 1:
    raise SystemExit(1)

expected_image = os.environ["EXPECTED_IMAGE"]
expected_digest = os.environ["EXPECTED_DIGEST"]
deployment_containers = deployment.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
agent_containers = [
    container for container in deployment_containers
    if isinstance(container, dict) and container.get("image") == expected_image
]
target_port = service_ports[0].get("targetPort", expected_port)
if isinstance(target_port, int) and not isinstance(target_port, bool):
    resolved_ports = {
        port.get("containerPort")
        for container in agent_containers
        for port in container.get("ports", [])
        if isinstance(port, dict) and port.get("containerPort") == target_port
    }
elif isinstance(target_port, str) and target_port:
    resolved_ports = {
        port.get("containerPort")
        for container in agent_containers
        for port in container.get("ports", [])
        if isinstance(port, dict)
        and port.get("name") == target_port
        and isinstance(port.get("containerPort"), int)
        and not isinstance(port.get("containerPort"), bool)
    }
else:
    resolved_ports = set()
if len(resolved_ports) != 1:
    raise SystemExit(1)
resolved_port = next(iter(resolved_ports))
pods = [
    pod for pod in pod_list.get("items", [])
    if all(pod.get("metadata", {}).get("labels", {}).get(key) == value for key, value in selector.items())
]
if not pods:
    raise SystemExit(1)
pod_uids = set()
ready_pod_uids = set()
for pod in pods:
    uid = pod.get("metadata", {}).get("uid")
    containers = pod.get("spec", {}).get("containers", [])
    names = {
        container.get("name") for container in containers
        if container.get("image") == expected_image
    }
    statuses = {
        status.get("name"): status.get("imageID", "")
        for status in pod.get("status", {}).get("containerStatuses", [])
    }
    if not uid or not names or any(expected_digest not in statuses.get(name, "") for name in names):
        raise SystemExit(1)
    pod_uids.add(uid)
    if any(
        condition.get("type") == "Ready" and condition.get("status") == "True"
        for condition in pod.get("status", {}).get("conditions", [])
    ):
        ready_pod_uids.add(uid)

slices = slice_list.get("items", [])
if not slices or any(
    item.get("metadata", {}).get("labels", {}).get("kubernetes.io/service-name")
    != service.get("metadata", {}).get("name")
    for item in slices
):
    raise SystemExit(1)
ready_targets = set()
for endpoint_slice in slices:
    if resolved_port not in {
        port.get("port")
        for port in endpoint_slice.get("ports", [])
        if isinstance(port, dict)
    }:
        raise SystemExit(1)
    for endpoint in endpoint_slice.get("endpoints", []):
        target = endpoint.get("targetRef", {})
        uid = target.get("uid")
        if (
            target.get("kind") != "Pod"
            or target.get("namespace") not in (None, os.environ["EXPECTED_NAMESPACE"])
            or uid not in pod_uids
        ):
            raise SystemExit(1)
        if endpoint.get("conditions", {}).get("ready") is True:
            ready_targets.add(uid)
if not ready_targets or not ready_targets.issubset(ready_pod_uids):
    raise SystemExit(1)
' \
    <(kubectl_scoped -n "$LAS_NAMESPACE" get deployment "$LAS_API_DEPLOYMENT" -o json) \
    <(kubectl_scoped -n "$LAS_NAMESPACE" get service "$LAS_API_SERVICE" -o json) \
    <(kubectl_scoped -n "$LAS_NAMESPACE" get pods -o json) \
    <(kubectl_scoped -n "$LAS_NAMESPACE" get endpointslices.discovery.k8s.io \
      -l "kubernetes.io/service-name=${LAS_API_SERVICE}" -o json)
}

verify_helm_identity() {
  "$HELM" --kube-context "$LAS_EXPECTED_KUBE_CONTEXT" list --namespace "$LAS_HELM_NAMESPACE" \
    --filter "^${LAS_HELM_RELEASE}$" --output json | \
    EXPECTED_RELEASE="$LAS_HELM_RELEASE" EXPECTED_CHART_NAME="$LAS_CHART_NAME" \
    EXPECTED_CHART_VERSION="$LAS_CHART_VERSION" python3 -c '
import json, os, sys
items = json.load(sys.stdin)
if not isinstance(items, list) or len(items) != 1:
    raise SystemExit(1)
release = items[0]
if (
    release.get("name") != os.environ["EXPECTED_RELEASE"]
    or release.get("status") != "deployed"
    or release.get("chart") != os.environ["EXPECTED_CHART_NAME"] + "-" + os.environ["EXPECTED_CHART_VERSION"]
):
    raise SystemExit(1)
'
}

verify_stack_identity() {
  verify_cluster_scope \
    && verify_deployment_identity "$LAS_OPERATOR_NAMESPACE" "$LAS_OPERATOR_DEPLOYMENT" \
      "$LAS_OPERATOR_IMAGE" "$LAS_OPERATOR_IMAGE_DIGEST" \
    && verify_deployment_identity "$LAS_NAMESPACE" "$LAS_API_DEPLOYMENT" \
      "$LAS_AGENT_SERVER_IMAGE" "$LAS_AGENT_SERVER_DIGEST" \
    && verify_api_service_binding \
    && verify_deployment_identity "$LAS_NAMESPACE" "$LAS_QUEUE_DEPLOYMENT" \
      "$LAS_AGENT_SERVER_IMAGE" "$LAS_AGENT_SERVER_DIGEST" \
    && verify_helm_identity
}

verify_stack_identity || {
  printf 'Live operator/API/queue/Helm identity did not match the declared stack.\n' >&2
  exit 1
}
start_port_forward
result="$(printf '%s' "$scenario" | LAS_BASE_URL="$LAS_BASE_URL" python3 "$QUALIFIER" \
  protocol --request-timeout "$LAS_REQUEST_TIMEOUT" --run-timeout "$LAS_RUN_TIMEOUT")" || {
  printf 'Initial product protocol qualification failed.\n' >&2
  exit 1
}
record_threads_from_result "$result"
printf 'initial_product_protocol=%s\n' "$result"

state_plan="$(printf '%s' "$scenario" | python3 -c '
import json
import re
import sys

result = json.loads(sys.argv[1])
scenario = json.load(sys.stdin)
cases = {case["name"]: case for case in scenario["cases"]}
expected_keys = {
    (case["name"], mode)
    for case in scenario["cases"]
    for mode in case["run_modes"]
}
checks = result.get("checks")
if result.get("result") != "PASS" or not isinstance(checks, list):
    raise SystemExit(1)
actual_keys = []
rows = []
history_rows = []
thread_ids = []
for check in checks:
    if not isinstance(check, dict):
        raise SystemExit(1)
    name = check.get("case")
    mode = check.get("mode")
    thread_id = check.get("thread_id")
    marker = check.get("marker")
    if (
        (name, mode) not in expected_keys
        or not isinstance(thread_id, str)
        or not thread_id
        or not isinstance(marker, str)
        or not re.fullmatch(r"aip-qualification-[0-9a-f]{32}", marker)
    ):
        raise SystemExit(1)
    actual_keys.append((name, mode))
    thread_ids.append(thread_id)
    case = cases[name]
    placeholder = case.get("marker_placeholder", "{{RUN_MARKER}}")
    for expected in case["expected_state_values"]:
        rows.append([thread_id, expected.replace(placeholder, marker), name, mode])
    history_rows.append([thread_id, marker, name, mode])
if len(actual_keys) != len(set(actual_keys)) or set(actual_keys) != expected_keys:
    raise SystemExit(1)
print(json.dumps({
    "rows": rows,
    "history_rows": history_rows,
    "thread_ids": list(dict.fromkeys(thread_ids)),
}, separators=(",", ":")))
' "$result")" || {
  printf 'Could not build the sanitized restart state plan.\n' >&2
  exit 1
}

mapfile -t state_checks < <(STATE_PLAN="$state_plan" python3 -c '
import json
import os
for row in json.loads(os.environ["STATE_PLAN"])["rows"]:
    print("\t".join(row))
')
mapfile -t history_checks < <(STATE_PLAN="$state_plan" python3 -c '
import json
import os
for row in json.loads(os.environ["STATE_PLAN"])["history_rows"]:
    print("\t".join(row))
')
expected_row_count="$(STATE_PLAN="$state_plan" python3 -c \
  'import json,os; print(len(json.loads(os.environ["STATE_PLAN"])["rows"]))')"
expected_history_count="$(STATE_PLAN="$state_plan" python3 -c \
  'import json,os; print(len(json.loads(os.environ["STATE_PLAN"])["history_rows"]))')"
if (( ${#state_checks[@]} != expected_row_count || expected_row_count < 3 \
  || ${#history_checks[@]} != expected_history_count || expected_history_count < 3 )); then
  printf 'Protocol qualification returned an incomplete persistence-check matrix.\n' >&2
  exit 1
fi

check_states() {
  local stage="$1" row thread_id expected_value case_name mode
  for row in "${state_checks[@]}"; do
    IFS=$'\t' read -r thread_id expected_value case_name mode <<<"$row"
    printf '%s' "$scenario" | LAS_BASE_URL="$LAS_BASE_URL" \
      python3 "$QUALIFIER" state --scenario-stdin \
      --thread-id "$thread_id" --expected-value "$expected_value" \
      --request-timeout "$LAS_REQUEST_TIMEOUT" >/dev/null
    printf 'persisted_state_after_%s=%s:%s:PASS\n' "$stage" "$case_name" "$mode"
  done
}

check_history_persistence() {
  local stage="$1" row thread_id marker case_name mode
  for row in "${history_checks[@]}"; do
    IFS=$'\t' read -r thread_id marker case_name mode <<<"$row"
    printf '%s' "$scenario" | LAS_BASE_URL="$LAS_BASE_URL" \
      python3 "$QUALIFIER" persistence --scenario-stdin \
      --thread-id "$thread_id" --expected-value "$marker" \
      --request-timeout "$LAS_REQUEST_TIMEOUT" >/dev/null
    printf 'persisted_state_and_checkpoint_history_after_%s=%s:%s:PASS\n' \
      "$stage" "$case_name" "$mode"
  done
}

deployment_revision() {
  kubectl_scoped -n "$LAS_NAMESPACE" get deployment "$1" \
    -o 'jsonpath={.metadata.annotations.deployment\.kubernetes\.io/revision}'
}

restart_and_wait() {
  local deployment="$1"
  verify_cluster_scope || return 1
  kubectl_scoped -n "$LAS_NAMESPACE" rollout restart "deployment/${deployment}" >/dev/null
  kubectl_scoped -n "$LAS_NAMESPACE" rollout status "deployment/${deployment}" \
    --timeout="$LAS_ROLLOUT_TIMEOUT" >/dev/null
}

printf '%s\n' \
  "kube_context=${actual_context}" \
  "namespace_uid=${actual_namespace_uid}" \
  "declared_operator_image=${LAS_OPERATOR_IMAGE}" \
  "declared_operator_image_digest=${LAS_OPERATOR_IMAGE_DIGEST}" \
  "declared_chart_version=${LAS_CHART_VERSION}" \
  "declared_chart_sha256=${LAS_CHART_SHA256}" \
  "declared_agent_server_image=${LAS_AGENT_SERVER_IMAGE}" \
  "declared_agent_server_digest=${LAS_AGENT_SERVER_DIGEST}" \
  'identity_verification=PASS'

check_history_persistence initial

api_before="$(deployment_revision "$LAS_API_DEPLOYMENT")"
if [[ -z "$api_before" ]]; then
  printf 'Could not read the initial API Deployment revision.\n' >&2
  exit 1
fi
restart_and_wait "$LAS_API_DEPLOYMENT"
verify_stack_identity || {
  printf 'Live stack identity changed during the API restart.\n' >&2
  exit 1
}
api_after="$(deployment_revision "$LAS_API_DEPLOYMENT")"
[[ -n "$api_after" && "$api_after" != "$api_before" ]] || {
  printf 'API Deployment revision did not advance after restart.\n' >&2
  exit 1
}
start_port_forward
printf 'api_rollout_revision=%s->%s:PASS\n' "$api_before" "$api_after"
check_states api_restart
check_history_persistence api_restart

active_result=""
if printf '%s' "$scenario" | python3 -c \
  'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("active_run_case") else 1)'; then
  active_result="$(printf '%s' "$scenario" | LAS_BASE_URL="$LAS_BASE_URL" python3 "$QUALIFIER" \
    submit-product-active --request-timeout "$LAS_REQUEST_TIMEOUT" \
    --running-timeout "$LAS_RUNNING_TIMEOUT")" || {
    printf 'Active product run could not be prepared before queue replacement.\n' >&2
    exit 1
  }
  active_thread="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["thread_id"])' "$active_result")"
  active_run="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["run_id"])' "$active_result")"
  active_marker="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["marker"])' "$active_result")"
  record_thread "$active_thread"
  printf 'active_product_submission=%s\n' "$active_result"
else
  printf 'active_run_queue_replacement=NOT_RUN (active_run_case not supplied)\n'
fi

# Capture the queue baseline immediately before the queue mutation. This
# prevents an unrelated rollout during the earlier API test from being
# mistaken for the restart performed below.
queue_before="$(deployment_revision "$LAS_QUEUE_DEPLOYMENT")"
if [[ -z "$queue_before" ]]; then
  printf 'Could not read the pre-restart queue Deployment revision.\n' >&2
  exit 1
fi
restart_and_wait "$LAS_QUEUE_DEPLOYMENT"
verify_stack_identity || {
  printf 'Live stack identity changed during the queue restart.\n' >&2
  exit 1
}
queue_after="$(deployment_revision "$LAS_QUEUE_DEPLOYMENT")"
[[ -n "$queue_after" && "$queue_after" != "$queue_before" ]] || {
  printf 'Queue Deployment revision did not advance after restart.\n' >&2
  exit 1
}
printf 'queue_rollout_revision=%s->%s:PASS\n' "$queue_before" "$queue_after"
check_states queue_restart
check_history_persistence queue_restart
if [[ -n "$active_result" ]]; then
  active_verification="$(printf '%s' "$scenario" | LAS_BASE_URL="$LAS_BASE_URL" python3 "$QUALIFIER" \
    verify-product-active --thread-id "$active_thread" --run-id "$active_run" \
    --marker "$active_marker" --request-timeout "$LAS_REQUEST_TIMEOUT" \
    --run-timeout "$LAS_RUN_TIMEOUT")" || {
    printf 'Active product run did not survive queue replacement.\n' >&2
    exit 1
  }
  printf 'active_run_queue_replacement=%s\n' "$active_verification"
fi

post_restart_result="$(printf '%s' "$scenario" | LAS_BASE_URL="$LAS_BASE_URL" python3 "$QUALIFIER" \
  protocol --request-timeout "$LAS_REQUEST_TIMEOUT" --run-timeout "$LAS_RUN_TIMEOUT")" || {
  printf 'Product protocol qualification failed after queue recovery.\n' >&2
  exit 1
}
record_threads_from_result "$post_restart_result"
printf 'post_restart_product_protocol=%s\n' "$post_restart_result"
cleanup_count="${#THREAD_IDS[@]}"
for thread_id in "${THREAD_IDS[@]}"; do
  printf '%s' "$scenario" | LAS_BASE_URL="$LAS_BASE_URL" \
    python3 "$QUALIFIER" delete-thread --scenario-stdin \
    --thread-id "$thread_id" --request-timeout "$LAS_REQUEST_TIMEOUT" >/dev/null || {
    printf 'Qualification thread cleanup failed; PASS is withheld.\n' >&2
    exit 1
  }
done
THREAD_IDS=()
printf 'qualification_threads_cleanup=deleted:%s:PASS\n' "$cleanup_count"
printf 'las_restart_persistence=PASS\n'
