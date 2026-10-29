#!/usr/bin/env bash

# Disposable-cluster acceptance check for deployment-config credential rotation.
# This performs two full installer runs and a real LAS thread/run/state check.
set -Eeuo pipefail
# Trusted scenarios and installer configs may contain credentials. Never honor
# inherited shell tracing for this process.
set +x

usage() {
  cat <<'EOF'
Usage: scripts/las-credential-rotation-acceptance.sh

Required environment:
  LAS_DISPOSABLE_CLUSTER_CONFIRMED=true
  LAS_INITIAL_CONFIG                 Config with initial test credentials.
  LAS_ROTATED_CONFIG                 Config with rotated test credentials.
  LAS_NAMESPACE                      Namespace containing the LAS release.
  LAS_SECRET_NAMES                   Comma-separated managed Secret names in
                                     this exact order: auth, PostgreSQL, Redis.
                                     Required data keys are respectively
                                     langgraph_cloud_license_key,
                                     postgres_connection_url, redis_connection_url.
  LAS_API_DEPLOYMENT                 LAS API Deployment name.
  LAS_QUEUE_DEPLOYMENT               LAS queue Deployment name.
  LAS_QUEUE_HPA                      Exact queue HPA name.
  LAS_EXPECTED_KUBE_CONTEXT          Exact kubectl context authorized for mutation.
  LAS_EXPECTED_NAMESPACE_UID         Exact UID of LAS_NAMESPACE.
  LAS_BASE_URL                       Explicit localhost URL used by this script's
                                     managed Service port-forward.
  LAS_API_SERVICE                    Exact LAS API Service name. Required so
                                     protocol evidence is bound to this cluster.
  LAS_API_SERVICE_UID                Exact immutable UID of LAS_API_SERVICE.
  LAS_OPERATOR_NAMESPACE             Namespace of the operator Deployment.
  LAS_OPERATOR_DEPLOYMENT            Exact operator Deployment name.
  LAS_OPERATOR_IMAGE/DIGEST          Expected operator image identity.
  LAS_AGENT_SERVER_IMAGE/DIGEST      Expected API/queue image identity.
  LAS_CHART_NAME/VERSION/SHA256      Operator build-time chart provenance.
  LAS_HELM_RELEASE                   Exact LAS Helm release name.

Pipe the trusted product protocol scenario to stdin. The scenario is held only
  in memory and is not printed. It is executed before and after rotation to prove
  that the actual graph remains usable; the deterministic sample is not substituted.

Optional:
  LAS_INSTALLER                      Defaults to tools/cluster_setup/
                                     k0s_cluster_with_stack.sh.
  KUBECTL                            Defaults to "kubectl".
  HELM                               Defaults to "helm".
  LAS_HELM_NAMESPACE                 Defaults to LAS_NAMESPACE.
  ROLLOUT_TIMEOUT                    Defaults to 300s.
  LAS_API_SERVICE_PORT               Remote Service port (default: 2024).

This changes cluster resources by running the installer twice. Use only with
disposable test credentials and a disposable cluster. Output contains names,
resource versions, and smoke metadata; it does not print credential values.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

required=(
  LAS_DISPOSABLE_CLUSTER_CONFIRMED LAS_INITIAL_CONFIG LAS_ROTATED_CONFIG
  LAS_NAMESPACE LAS_SECRET_NAMES LAS_API_DEPLOYMENT LAS_QUEUE_DEPLOYMENT
  LAS_QUEUE_HPA LAS_EXPECTED_KUBE_CONTEXT LAS_EXPECTED_NAMESPACE_UID LAS_BASE_URL
  LAS_API_SERVICE LAS_API_SERVICE_UID
  LAS_OPERATOR_NAMESPACE LAS_OPERATOR_DEPLOYMENT LAS_OPERATOR_IMAGE
  LAS_OPERATOR_IMAGE_DIGEST LAS_CHART_NAME LAS_CHART_VERSION LAS_CHART_SHA256
  LAS_AGENT_SERVER_IMAGE LAS_AGENT_SERVER_DIGEST LAS_HELM_RELEASE
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'Missing required environment variable: %s\n' "$name" >&2
    usage >&2
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
if [[ ! "${LAS_REQUEST_TIMEOUT:-180}" =~ ^[0-9]+$ ]] \
  || [[ ! "${LAS_RUN_TIMEOUT:-600}" =~ ^[0-9]+$ ]] \
  || (( ${LAS_REQUEST_TIMEOUT:-180} < 1 || ${LAS_RUN_TIMEOUT:-600} < ${LAS_REQUEST_TIMEOUT:-180} )); then
  printf 'LAS request/run timeouts must be positive integers with run >= request.\n' >&2
  exit 2
fi
if [[ ! "${LAS_API_SERVICE_PORT:-2024}" =~ ^[0-9]+$ ]] \
  || (( ${LAS_API_SERVICE_PORT:-2024} < 1 || ${LAS_API_SERVICE_PORT:-2024} > 65535 )); then
  printf 'LAS_API_SERVICE_PORT must be an integer between 1 and 65535.\n' >&2
  exit 2
fi
if [[ ! "$LAS_API_SERVICE_UID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; then
  printf 'LAS_API_SERVICE_UID must be one exact safe Kubernetes UID.\n' >&2
  exit 2
fi
if [[ ! -r "$LAS_INITIAL_CONFIG" || ! -r "$LAS_ROTATED_CONFIG" ]]; then
  printf 'Both LAS config files must be readable.\n' >&2
  exit 2
fi

LAS_HELM_NAMESPACE="${LAS_HELM_NAMESPACE:-$LAS_NAMESPACE}"

for resource_name in \
  "$LAS_NAMESPACE" "$LAS_API_DEPLOYMENT" "$LAS_QUEUE_DEPLOYMENT" "$LAS_QUEUE_HPA" \
  "$LAS_OPERATOR_NAMESPACE" "$LAS_OPERATOR_DEPLOYMENT" "$LAS_API_SERVICE" \
  "$LAS_HELM_NAMESPACE" "$LAS_HELM_RELEASE" "$LAS_CHART_NAME"; do
  if [[ ! "$resource_name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
    printf 'Namespace and Kubernetes resource names must be simple DNS names.\n' >&2
    exit 2
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${LAS_INSTALLER:-${REPO_ROOT}/tools/cluster_setup/k0s_cluster_with_stack.sh}"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
IFS=',' read -r -a SECRET_NAMES <<< "$LAS_SECRET_NAMES"
SECRET_KEYS=(langgraph_cloud_license_key postgres_connection_url redis_connection_url)
SECRET_ROLES=(auth postgres redis)
if (( ${#SECRET_NAMES[@]} != 3 )); then
  printf 'LAS_SECRET_NAMES must list exactly the auth, PostgreSQL, and Redis Secret names.\n' >&2
  exit 2
fi
seen_secret_names=','
for secret in "${SECRET_NAMES[@]}"; do
  if [[ ! "$secret" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
    printf 'Managed Secret names must be exact Kubernetes DNS names.\n' >&2
    exit 2
  fi
  if [[ "$seen_secret_names" == *",${secret},"* ]]; then
    printf 'LAS_SECRET_NAMES must contain three distinct managed Secret names.\n' >&2
    exit 2
  fi
  seen_secret_names+="${secret},"
done

command -v "$KUBECTL" >/dev/null 2>&1 || { printf 'kubectl not found: %s\n' "$KUBECTL" >&2; exit 2; }
command -v "$HELM" >/dev/null 2>&1 || { printf 'helm not found: %s\n' "$HELM" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'python3 is required.\n' >&2; exit 2; }
[[ -f "$INSTALLER" && -r "$INSTALLER" ]] || { printf 'Installer is not readable: %s\n' "$INSTALLER" >&2; exit 2; }
[[ -r "${SCRIPT_DIR}/las-runtime-acceptance.py" ]] || { printf 'LAS runtime acceptance helper is missing.\n' >&2; exit 2; }

kubectl_scoped() {
  "$KUBECTL" --context "$LAS_EXPECTED_KUBE_CONTEXT" "$@"
}

port_data="$(LAS_BASE_URL="$LAS_BASE_URL" python3 -c '
import os, urllib.parse
parsed = urllib.parse.urlsplit(os.environ["LAS_BASE_URL"])
if (
    parsed.scheme != "http"
    or parsed.hostname not in ("127.0.0.1", "localhost", "::1")
    or parsed.username is not None
    or parsed.password is not None
    or parsed.path not in ("", "/")
    or parsed.query
    or parsed.fragment
    or parsed.port is None
    or not 1024 <= parsed.port <= 65535
):
    raise SystemExit(1)
print(parsed.hostname, parsed.port)
')" || {
  printf 'LAS_BASE_URL must be an uncredentialed HTTP loopback URL with no path/query/fragment and port 1024..65535.\n' >&2
  exit 2
}
read -r PF_LOCAL_HOST PF_LOCAL_PORT <<<"$port_data"
unset port_data

scenario="$(cat)"
if [[ -z "$scenario" ]] || ! printf '%s' "$scenario" | python3 -c '
import json, sys
value = json.load(sys.stdin)
raise SystemExit(0 if isinstance(value, dict) and value.get("cases") else 1)
'; then
  printf 'A valid trusted product protocol scenario is required on stdin.\n' >&2
  exit 2
fi

qualification_scenario="$(printf '%s' "$scenario" | python3 -c '
import json, sys
value = json.load(sys.stdin)
value["cleanup_threads"] = True
for case in value.get("cases", []):
    if isinstance(case, dict):
        case["cleanup"] = True
print(json.dumps(value, separators=(",", ":")))
')"
unset scenario

PORT_FORWARD_PID=""
cleanup() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
  unset qualification_scenario
}
trap cleanup EXIT

verify_cluster_scope() {
  local actual_context actual_namespace_uid
  actual_context="$("$KUBECTL" config current-context)" || return 1
  actual_namespace_uid="$(kubectl_scoped get namespace "$LAS_NAMESPACE" -o 'jsonpath={.metadata.uid}')" || return 1
  if [[ "$actual_context" != "$LAS_EXPECTED_KUBE_CONTEXT" \
    || -z "$actual_namespace_uid" \
    || "$actual_namespace_uid" != "$LAS_EXPECTED_NAMESPACE_UID" ]]; then
    printf 'Kubernetes context or namespace identity does not match the approved target.\n' >&2
    return 1
  fi
}
verify_cluster_scope || exit 2

wait_las_health() {
  local attempt
  for attempt in $(seq 1 60); do
    if [[ -z "$PORT_FORWARD_PID" ]] || ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
      printf 'Managed LAS Service port-forward exited before becoming healthy.\n' >&2
      return 1
    fi
    if LAS_BASE_URL="$LAS_BASE_URL" python3 -c '
import json, os, urllib.error, urllib.request
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None
url = os.environ["LAS_BASE_URL"].rstrip("/") + "/ok"
headers = {}
api_key = os.environ.get("LAS_API_KEY", "")
if api_key:
    headers["X-Api-Key"] = api_key
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
with opener.open(urllib.request.Request(url, headers=headers), timeout=2) as response:
    value = json.load(response)
    leaked = api_key and api_key in json.dumps(value, ensure_ascii=False)
    raise SystemExit(0 if response.status == 200 and value.get("ok") is True and not leaked else 1)
' >/dev/null 2>&1; then
      if kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
        return 0
      fi
      printf 'Managed LAS Service port-forward exited during its health check.\n' >&2
      return 1
    fi
    sleep 1
  done
  printf 'Managed LAS Service port-forward did not become healthy.\n' >&2
  return 1
}

refresh_las_access() {
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=""
  fi
  verify_cluster_scope || return 1
  verify_api_service_binding || return 1
  kubectl_scoped -n "$LAS_NAMESPACE" port-forward \
    --address "$PF_LOCAL_HOST" "service/${LAS_API_SERVICE}" \
    "${PF_LOCAL_PORT}:${LAS_API_SERVICE_PORT:-2024}" \
    >/dev/null 2>&1 &
  PORT_FORWARD_PID=$!
  wait_las_health
}

resource_version() {
  kubectl_scoped -n "$LAS_NAMESPACE" get secret "$1" -o 'jsonpath={.metadata.resourceVersion}'
}

secret_key_hash() {
  kubectl_scoped -n "$LAS_NAMESPACE" get secret "$1" -o json | \
    EXPECTED_SECRET_KEY="$2" python3 -c '
import hashlib, json, os, sys
value = json.load(sys.stdin).get("data", {})
key = os.environ["EXPECTED_SECRET_KEY"]
encoded_value = value.get(key) if isinstance(value, dict) else None
if not isinstance(encoded_value, str) or not encoded_value:
    raise SystemExit(1)
print(hashlib.sha256(encoded_value.encode()).hexdigest())
'
}

hpa_spec_hash() {
  kubectl_scoped -n "$LAS_NAMESPACE" get hpa "$LAS_QUEUE_HPA" -o json | \
    LAS_QUEUE_DEPLOYMENT="$LAS_QUEUE_DEPLOYMENT" python3 -c '
import hashlib, json, os, sys
value = json.load(sys.stdin)
target = value.get("spec", {}).get("scaleTargetRef", {})
if target.get("kind") != "Deployment" or target.get("name") != os.environ["LAS_QUEUE_DEPLOYMENT"]:
    raise SystemExit(1)
spec = json.dumps(value.get("spec", {}), sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(spec).hexdigest())
'
}

deployment_revision() {
  kubectl_scoped -n "$LAS_NAMESPACE" get deployment "$1" -o json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("metadata",{}).get("annotations",{}).get("deployment.kubernetes.io/revision", ""))'
}

verify_deployment_identity() {
  local namespace="$1" deployment="$2" expected_image="$3" expected_digest="$4" role="$5"
  local identity_data selector container_names
  identity_data="$(kubectl_scoped -n "$namespace" get deployment "$deployment" -o json | \
    EXPECTED_IMAGE="$expected_image" python3 -c '
import json, os, sys
value = json.load(sys.stdin)
containers = value.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
names = [item.get("name") for item in containers if item.get("image") == os.environ["EXPECTED_IMAGE"]]
if not names or any(not isinstance(name, str) or not name for name in names):
    raise SystemExit(1)
labels = value.get("spec", {}).get("selector", {}).get("matchLabels", {})
if not labels:
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
if not items or any(
    any(
        name not in {status.get("name") for status in item.get("status", {}).get("containerStatuses", [])}
        or digest not in next(
            status.get("imageID", "")
            for status in item.get("status", {}).get("containerStatuses", [])
            if status.get("name") == name
        )
        for name in names
    )
    for item in items
):
    raise SystemExit(1)
'
  printf 'configured_and_resolved_image_%s=PASS\n' "$role"
}

verify_api_service_binding() {
  EXPECTED_SERVICE_UID="$LAS_API_SERVICE_UID" \
  EXPECTED_SERVICE_PORT="${LAS_API_SERVICE_PORT:-2024}" \
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
    names = {
        container.get("name")
        for container in pod.get("spec", {}).get("containers", [])
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
  printf 'api_service_routes_to_attested_api_pods=PASS\n'
}

verify_secret_references() {
  kubectl_scoped -n "$LAS_NAMESPACE" get deployment \
    "$LAS_API_DEPLOYMENT" "$LAS_QUEUE_DEPLOYMENT" -o json | \
    EXPECTED_SECRET_NAMES="$LAS_SECRET_NAMES" \
    EXPECTED_SECRET_KEYS="$(IFS=,; printf '%s' "${SECRET_KEYS[*]}")" \
    EXPECTED_IMAGE="$LAS_AGENT_SERVER_IMAGE" \
    EXPECTED_DEPLOYMENTS="$LAS_API_DEPLOYMENT,$LAS_QUEUE_DEPLOYMENT" python3 -c '
import json, os, sys
names = os.environ["EXPECTED_SECRET_NAMES"].split(",")
keys = os.environ["EXPECTED_SECRET_KEYS"].split(",")
expected = set(zip(names, keys))
value = json.load(sys.stdin)
items = value.get("items", []) if isinstance(value, dict) else []
if (
    len(items) != 2
    or {item.get("metadata", {}).get("name") for item in items}
       != set(os.environ["EXPECTED_DEPLOYMENTS"].split(","))
):
    raise SystemExit(1)

def exposes_key(items, mount, secret_key):
    if mount.get("subPathExpr") is not None:
        return False
    key_path = secret_key
    if items is not None:
        if not isinstance(items, list):
            return False
        matching = [
            entry for entry in items
            if isinstance(entry, dict) and entry.get("key") == secret_key
        ]
        if not matching:
            return False
        path = matching[0].get("path")
        if not isinstance(path, str) or not path:
            return False
        key_path = path
    sub_path = mount.get("subPath")
    return sub_path is None or sub_path == key_path

def references_secret_key(pod, container, secret_name, secret_key):
    for source in container.get("envFrom", []):
        if not isinstance(source, dict):
            continue
        reference = source.get("secretRef")
        if isinstance(reference, dict) and reference.get("name") == secret_name:
            return True
    for variable in container.get("env", []):
        if not isinstance(variable, dict):
            continue
        value_from = variable.get("valueFrom")
        reference = value_from.get("secretKeyRef") if isinstance(value_from, dict) else None
        if (
            isinstance(reference, dict)
            and reference.get("name") == secret_name
            and reference.get("key") == secret_key
        ):
            return True
    mounted = {
        mount.get("name"): mount
        for mount in container.get("volumeMounts", [])
        if isinstance(mount, dict) and isinstance(mount.get("name"), str)
    }
    for volume in pod.get("volumes", []):
        if not isinstance(volume, dict):
            continue
        mount = mounted.get(volume.get("name"))
        if not isinstance(mount, dict):
            continue
        direct = volume.get("secret")
        if (
            isinstance(direct, dict)
            and direct.get("secretName") == secret_name
            and exposes_key(direct.get("items"), mount, secret_key)
        ):
            return True
        projected = volume.get("projected")
        sources = projected.get("sources", []) if isinstance(projected, dict) else []
        for source in sources:
            if not isinstance(source, dict):
                continue
            reference = source.get("secret")
            if (
                isinstance(reference, dict)
                and reference.get("name") == secret_name
                and exposes_key(reference.get("items"), mount, secret_key)
            ):
                return True
    return False

for item in items:
    pod = item.get("spec", {}).get("template", {}).get("spec", {})
    agent_containers = [
        container for container in pod.get("containers", [])
        if container.get("image") == os.environ["EXPECTED_IMAGE"]
    ]
    if not agent_containers:
        raise SystemExit(1)
    for container in agent_containers:
        if any(
            not references_secret_key(pod, container, name, key)
            for name, key in expected
        ):
            raise SystemExit(1)
'
  printf 'managed_secret_workload_references=PASS\n'
}

verify_helm_identity() {
  "$HELM" --kube-context "$LAS_EXPECTED_KUBE_CONTEXT" list --namespace "$LAS_HELM_NAMESPACE" \
    --filter "^${LAS_HELM_RELEASE}$" --output json | \
    EXPECTED_RELEASE="$LAS_HELM_RELEASE" EXPECTED_CHART_NAME="$LAS_CHART_NAME" \
    EXPECTED_CHART_VERSION="$LAS_CHART_VERSION" \
    python3 -c '
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
  printf 'live_helm_release_identity=PASS\n'
}

verify_stack_identity() {
  verify_deployment_identity "$LAS_OPERATOR_NAMESPACE" "$LAS_OPERATOR_DEPLOYMENT" \
    "$LAS_OPERATOR_IMAGE" "$LAS_OPERATOR_IMAGE_DIGEST" operator || {
    printf 'Operator image identity did not match the live Deployment.\n' >&2
    return 1
  }
  verify_deployment_identity "$LAS_NAMESPACE" "$LAS_API_DEPLOYMENT" \
    "$LAS_AGENT_SERVER_IMAGE" "$LAS_AGENT_SERVER_DIGEST" api || {
    printf 'API image identity did not match the live Deployment.\n' >&2
    return 1
  }
  verify_api_service_binding || {
    printf 'API Service identity or EndpointSlice routing did not match the attested API pods.\n' >&2
    return 1
  }
  verify_deployment_identity "$LAS_NAMESPACE" "$LAS_QUEUE_DEPLOYMENT" \
    "$LAS_AGENT_SERVER_IMAGE" "$LAS_AGENT_SERVER_DIGEST" queue || {
    printf 'Queue image identity did not match the live Deployment.\n' >&2
    return 1
  }
  verify_secret_references || {
    printf 'Declared managed Secrets were not referenced by the LAS workloads.\n' >&2
    return 1
  }
  verify_helm_identity || {
    printf 'Live Helm release identity did not match the declared chart.\n' >&2
    return 1
  }
}

install_config() {
  local config="$1"
  verify_cluster_scope || return 1
  if ! AUTO_APPROVE=true CONFIG_FILE="$config" bash "$INSTALLER" install --silent >/dev/null 2>&1; then
    printf 'Installer failed for a LAS configuration (details withheld to avoid credential leakage).\n' >&2
    return 1
  fi
}

wait_rollout() {
  local deployment="$1"
  kubectl_scoped -n "$LAS_NAMESPACE" rollout status "deployment/${deployment}" \
    --timeout="${ROLLOUT_TIMEOUT:-300s}" >/dev/null
  printf 'rollout=%s:PASS\n' "$deployment"
}

printf 'phase=verify_operator_before_initial_secret_install\n'
verify_deployment_identity "$LAS_OPERATOR_NAMESPACE" "$LAS_OPERATOR_DEPLOYMENT" \
  "$LAS_OPERATOR_IMAGE" "$LAS_OPERATOR_IMAGE_DIGEST" operator || {
  printf 'Operator image identity did not match before the initial Secret install.\n' >&2
  exit 1
}
printf 'phase=install_initial\n'
install_config "$LAS_INITIAL_CONFIG"
verify_cluster_scope || exit 1
wait_rollout "$LAS_API_DEPLOYMENT"
wait_rollout "$LAS_QUEUE_DEPLOYMENT"
declare -a initial_versions=()
declare -a initial_hashes=()
for index in "${!SECRET_NAMES[@]}"; do
  secret="${SECRET_NAMES[$index]}"
  version="$(resource_version "$secret")" || { printf 'Could not read managed Secret metadata.\n' >&2; exit 1; }
  [[ -n "$version" ]] || { printf 'Managed Secret has no resource version.\n' >&2; exit 1; }
  initial_versions+=("$version")
  data_hash="$(secret_key_hash "$secret" "${SECRET_KEYS[$index]}")" || {
    printf 'Managed %s Secret is missing its required data key.\n' "${SECRET_ROLES[$index]}" >&2
    exit 1
  }
  initial_hashes+=("$data_hash")
done
initial_api_revision="$(deployment_revision "$LAS_API_DEPLOYMENT")"
initial_queue_revision="$(deployment_revision "$LAS_QUEUE_DEPLOYMENT")"
if [[ -z "$initial_api_revision" || -z "$initial_queue_revision" ]]; then
  printf 'Could not read the initial LAS Deployment revisions.\n' >&2
  exit 1
fi
initial_hpa_hash="$(hpa_spec_hash)" || {
  printf 'Queue HPA does not target the expected Deployment.\n' >&2
  exit 1
}
printf 'phase=verify_initial_immutable_identity\n'
verify_stack_identity || exit 1
refresh_las_access
printf '%s\n' \
  "chart_version=${LAS_CHART_VERSION}" \
  "chart_sha256=${LAS_CHART_SHA256}" \
  'chart_archive_identity_source=operator_build_provenance'
printf 'phase=product_before_rotation\n'
initial_qualification="$(printf '%s' "$qualification_scenario" | python3 "${SCRIPT_DIR}/las-runtime-acceptance.py" \
  protocol --request-timeout "${LAS_REQUEST_TIMEOUT:-180}" --run-timeout "${LAS_RUN_TIMEOUT:-600}")" || {
  printf 'Actual product qualification failed before Secret rotation.\n' >&2
  exit 1
}
printf 'product_protocol_before_rotation=%s\n' "$initial_qualification"

printf 'phase=install_rotated\n'
install_config "$LAS_ROTATED_CONFIG"
verify_cluster_scope || exit 1
changed=0
for index in "${!SECRET_NAMES[@]}"; do
  version="$(resource_version "${SECRET_NAMES[$index]}")" || { printf 'Could not read managed Secret metadata after rotation.\n' >&2; exit 1; }
  if [[ "$version" == "${initial_versions[$index]}" ]]; then
    printf 'secret_rotation=%s:FAIL (resource version unchanged)\n' "${SECRET_NAMES[$index]}" >&2
    exit 1
  fi
  data_hash="$(secret_key_hash "${SECRET_NAMES[$index]}" "${SECRET_KEYS[$index]}")" || {
    printf 'Managed %s Secret is missing its required data key after rotation.\n' "${SECRET_ROLES[$index]}" >&2
    exit 1
  }
  if [[ "$data_hash" == "${initial_hashes[$index]}" ]]; then
    printf 'secret_rotation=%s:FAIL (Secret data hash unchanged)\n' "${SECRET_NAMES[$index]}" >&2
    exit 1
  fi
  changed=$((changed + 1))
  printf 'secret_rotation=%s:PASS\n' "${SECRET_NAMES[$index]}"
done

wait_rollout "$LAS_API_DEPLOYMENT"
wait_rollout "$LAS_QUEUE_DEPLOYMENT"
verify_cluster_scope || exit 1
api_revision="$(deployment_revision "$LAS_API_DEPLOYMENT")"
queue_revision="$(deployment_revision "$LAS_QUEUE_DEPLOYMENT")"
if [[ "$api_revision" == "$initial_api_revision" || "$queue_revision" == "$initial_queue_revision" ]]; then
  printf 'LAS API and queue must each roll to a new Deployment revision after credential rotation.\n' >&2
  exit 1
fi
printf 'pod_template_rotation=api:%s->%s:PASS\n' "$initial_api_revision" "$api_revision"
printf 'pod_template_rotation=queue:%s->%s:PASS\n' "$initial_queue_revision" "$queue_revision"
rotated_hpa_hash="$(hpa_spec_hash)" || {
  printf 'Queue HPA does not target the expected Deployment after rotation.\n' >&2
  exit 1
}
if [[ "$rotated_hpa_hash" != "$initial_hpa_hash" ]]; then
  printf 'Queue HPA spec changed during credential rotation.\n' >&2
  exit 1
fi
printf 'queue_hpa_ownership_preserved=PASS\n'
printf 'phase=verify_rotated_immutable_identity\n'
verify_stack_identity || exit 1
refresh_las_access
printf '%s\n' \
  "chart_version=${LAS_CHART_VERSION}" \
  "chart_sha256=${LAS_CHART_SHA256}" \
  'chart_archive_identity_source=operator_build_provenance'
printf 'phase=product_run_and_persisted_state\n'
qualification_result="$(printf '%s' "$qualification_scenario" | python3 "${SCRIPT_DIR}/las-runtime-acceptance.py" \
  protocol --request-timeout "${LAS_REQUEST_TIMEOUT:-180}" --run-timeout "${LAS_RUN_TIMEOUT:-600}")" || {
  printf 'Actual product qualification failed after Secret rotation.\n' >&2
  exit 1
}
printf 'product_protocol=%s\n' "$qualification_result"
printf 'credential_rotation_acceptance=PASS\n'
