#!/usr/bin/env bash
# fix_insecure_registry.sh — run on the controller node to push an insecure
# registry drop-in to all k0s nodes and restart containerd so pods can pull
# images from a plain-HTTP registry.
#
# Usage:
#   ./fix_insecure_registry.sh [--registry <host:port>] [--workers "<ip1> <ip2>"]
#                              [--ssh-key <path>] [--ssh-user <user>]
#
# All flags are optional. Defaults are auto-detected from the k0s node list
# and the registry is derived from running pod specs if not provided.
#
# Examples:
#   ./fix_insecure_registry.sh
#   ./fix_insecure_registry.sh --registry 172.31.51.179:5000
#   ./fix_insecure_registry.sh --registry 172.31.51.179:5000 --workers "172.31.22.91 172.31.22.173"

set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── defaults ─────────────────────────────────────────────────────────────────
REGISTRY=""
WORKER_IPS=""
SSH_USER="root"
SSH_KEY=""

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)  REGISTRY="$2";   shift 2 ;;
    --workers)   WORKER_IPS="$2"; shift 2 ;;
    --ssh-key)   SSH_KEY="$2";    shift 2 ;;
    --ssh-user)  SSH_USER="$2";   shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── ssh helper ────────────────────────────────────────────────────────────────
ssh_exec() {
  local host="$1"; shift
  local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                  -o ConnectTimeout=10 -o BatchMode=yes)
  [[ -n "${SSH_KEY}" ]] && ssh_opts+=(-i "${SSH_KEY}")
  ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"
}

# ── auto-detect registry from running pod image refs ─────────────────────────
detect_registry() {
  log "Auto-detecting image registry from pod specs..."
  local img
  img=$(kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' 2>/dev/null \
        | tr ' ' '\n' \
        | grep -oP '^\d+\.\d+\.\d+\.\d+:\d+' \
        | sort -u | head -1 || true)
  if [[ -z "${img}" ]]; then
    img=$(kubectl get pods -A -o jsonpath='{.items[*].spec.initContainers[*].image}' 2>/dev/null \
          | tr ' ' '\n' \
          | grep -oP '^\d+\.\d+\.\d+\.\d+:\d+' \
          | sort -u | head -1 || true)
  fi
  echo "${img}"
}

# ── auto-detect worker IPs from k0s node list ────────────────────────────────
detect_workers() {
  log "Auto-detecting worker node IPs..."
  # InternalIP of nodes that are not the controller (not the local machine)
  local local_ips
  local_ips=$(hostname -I 2>/dev/null || ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1)
  kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    2>/dev/null | while read -r ip; do
      if ! echo "${local_ips}" | grep -qw "${ip}"; then
        echo "${ip}"
      fi
    done | tr '\n' ' '
}

# ── write drop-in and restart containerd on a single node ────────────────────
fix_node() {
  local ip="$1"
  local registry="$2"
  local is_controller="${3:-false}"

  log "  ── ${ip} ($([ "${is_controller}" = true ] && echo controller || echo worker)) ──"

  # 1. Write the drop-in
  ssh_exec "${ip}" "
    sudo mkdir -p /etc/k0s/containerd.d
    sudo tee /etc/k0s/containerd.d/insecure-registry.toml >/dev/null <<'TOML'
[plugins.\"io.containerd.grpc.v1.cri\".registry]
  [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors]
    [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"${registry}\"]
      endpoint = [\"http://${registry}\"]
  [plugins.\"io.containerd.grpc.v1.cri\".registry.configs]
    [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${registry}\".tls]
      insecure_skip_verify = true
TOML
    echo 'Drop-in written:'
    cat /etc/k0s/containerd.d/insecure-registry.toml
  "

  # 2. Restart the right service
  if [[ "${is_controller}" == "true" ]]; then
    log "  Restarting k0s (controller) on ${ip}..."
    ssh_exec "${ip}" "sudo systemctl restart k0s"
  else
    log "  Restarting k0sworker on ${ip}..."
    ssh_exec "${ip}" "sudo systemctl restart k0sworker"
  fi

  log "  ✓ ${ip} done"
}

# ── main ──────────────────────────────────────────────────────────────────────
log "============================================"
log "  Insecure registry fix"
log "============================================"

# Resolve registry
if [[ -z "${REGISTRY}" ]]; then
  REGISTRY=$(detect_registry)
  if [[ -z "${REGISTRY}" ]]; then
    err "Could not auto-detect registry. Pass --registry <host:port>."
    exit 1
  fi
  log "Detected registry: ${REGISTRY}"
else
  log "Using registry: ${REGISTRY}"
fi

# Verify the registry is actually reachable over HTTP
log "Verifying registry is reachable at http://${REGISTRY}/v2/ ..."
if curl -sf --max-time 5 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
  log "✓ Registry responding on HTTP"
else
  warn "Registry did not respond at http://${REGISTRY}/v2/ — proceeding anyway (may be auth-gated)"
fi

# Resolve worker IPs
if [[ -z "${WORKER_IPS}" ]]; then
  WORKER_IPS=$(detect_workers)
  if [[ -z "${WORKER_IPS}" ]]; then
    warn "No worker nodes detected — will only fix the controller."
  else
    log "Detected workers: ${WORKER_IPS}"
  fi
else
  log "Using workers: ${WORKER_IPS}"
fi

# Fix controller (localhost — no SSH needed)
log ""
log "Fixing controller (localhost)..."
sudo mkdir -p /etc/k0s/containerd.d
sudo tee /etc/k0s/containerd.d/insecure-registry.toml >/dev/null <<TOML
[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${REGISTRY}"]
      endpoint = ["http://${REGISTRY}"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."${REGISTRY}".tls]
      insecure_skip_verify = true
TOML
log "Drop-in written on controller:"
cat /etc/k0s/containerd.d/insecure-registry.toml
log "Restarting k0s on controller..."
sudo systemctl restart k0s
log "✓ Controller done"

# Wait for API server to come back
log ""
log "Waiting for API server to be ready..."
for i in $(seq 1 30); do
  if kubectl get --raw /healthz >/dev/null 2>&1; then
    log "✓ API server ready (${i}s)"
    break
  fi
  sleep 2
  if [[ ${i} -eq 30 ]]; then
    err "API server not ready after 60s — check 'sudo journalctl -u k0s -n 50'"
    exit 1
  fi
done

# Fix each worker
if [[ -n "${WORKER_IPS}" ]]; then
  log ""
  log "Fixing worker nodes..."
  failed_workers=()
  for worker_ip in ${WORKER_IPS}; do
    if fix_node "${worker_ip}" "${REGISTRY}" false; then
      : # logged inside fix_node
    else
      err "Failed to fix ${worker_ip}"
      failed_workers+=("${worker_ip}")
    fi
  done
fi

# Delete pending pods so they reschedule immediately
log ""
log "Deleting Pending pods to trigger immediate reschedule..."
pending=$(kubectl get pods -A --field-selector=status.phase=Pending \
          -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ -z "${pending}" ]]; then
  log "No Pending pods found."
else
  while IFS=' ' read -r ns pod; do
    [[ -z "${ns}" ]] && continue
    kubectl delete pod -n "${ns}" "${pod}" --ignore-not-found && log "  Deleted ${ns}/${pod}"
  done <<< "${pending}"
fi

# Summary
log ""
log "============================================"
log "  Summary"
log "============================================"
if [[ ${#failed_workers[@]:-0} -gt 0 ]]; then
  warn "Failed workers: ${failed_workers[*]}"
  warn "Run manually on each: sudo mkdir -p /etc/k0s/containerd.d && ..."
  exit 1
else
  log "✓ All nodes fixed. Registry ${REGISTRY} configured as insecure HTTP."
  log "  Monitor pod status: kubectl get pods -A -w"
fi
