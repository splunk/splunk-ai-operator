#!/usr/bin/env bash
# fix_insecure_registry.sh — run on the controller node to push an insecure
# registry drop-in to all k0s nodes and restart containerd so pods can pull
# images from a plain-HTTP registry.
#
# By default reads SSH credentials and worker IPs from the same config file
# used by k0s_cluster_with_stack.sh (k0s-cluster-config.yaml in the same
# directory), so no extra configuration is needed if that file is already
# filled in.
#
# Usage:
#   ./fix_insecure_registry.sh [--config <path>] [--registry <host:port>]
#                              [--workers "<ip1> <ip2>"]
#                              [--ssh-key <path>] [--ssh-user <user>]
#
# All flags are optional — values from the config file are used as defaults.
#
# Examples:
#   # Zero config — reads everything from k0s-cluster-config.yaml
#   ./fix_insecure_registry.sh
#
#   # Override registry only
#   ./fix_insecure_registry.sh --registry 172.31.51.179:5000
#
#   # Fully explicit (no config file needed)
#   ./fix_insecure_registry.sh \
#     --registry 172.31.51.179:5000 \
#     --workers "172.31.22.91 172.31.22.173" \
#     --ssh-key ~/.ssh/id_rsa \
#     --ssh-user ec2-user

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── defaults (overridden by config file, then by CLI flags) ──────────────────
CONFIG_FILE="${SCRIPT_DIR}/k0s-cluster-config.yaml"
REGISTRY=""
WORKER_IPS=""
SSH_USER="root"
SSH_KEY=""

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)    CONFIG_FILE="$2"; shift 2 ;;
    --registry)  REGISTRY="$2";   shift 2 ;;
    --workers)   WORKER_IPS="$2"; shift 2 ;;
    --ssh-key)   SSH_KEY="$2";    shift 2 ;;
    --ssh-user)  SSH_USER="$2";   shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── read config file (yq required only when config file is present) ───────────
if [[ -f "${CONFIG_FILE}" ]]; then
  log "Reading config from ${CONFIG_FILE}"
  if command -v yq &>/dev/null; then
    [[ -z "${SSH_KEY}" ]]      && SSH_KEY=$(yq eval '.cluster.sshKeyPath // ""'           "${CONFIG_FILE}" 2>/dev/null || true)
    [[ -z "${SSH_USER}" || "${SSH_USER}" == "root" ]] \
                               && SSH_USER=$(yq eval '.cluster.sshUser // "root"'         "${CONFIG_FILE}" 2>/dev/null || true)
    [[ -z "${REGISTRY}" ]]     && REGISTRY=$(yq eval '.images.registry // ""'             "${CONFIG_FILE}" 2>/dev/null || true)
    if [[ -z "${WORKER_IPS}" ]]; then
      WORKER_IPS=$(yq eval '.nodes.existingIPs.workers[]' "${CONFIG_FILE}" 2>/dev/null \
                  | tr '\n' ' ' || true)
    fi
  else
    warn "yq not found — cannot parse ${CONFIG_FILE}. Pass --ssh-key / --ssh-user / --registry / --workers explicitly."
  fi
  # Expand ~ in SSH key path
  SSH_KEY="${SSH_KEY/#\~/$HOME}"
else
  warn "Config file not found at ${CONFIG_FILE}. Using CLI flags / auto-detection."
fi

# ── ssh helper ────────────────────────────────────────────────────────────────
ssh_exec() {
  local host="$1"; shift
  local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                  -o ConnectTimeout=10 -o BatchMode=yes)
  [[ -n "${SSH_KEY}" && -f "${SSH_KEY}" ]] && ssh_opts+=(-i "${SSH_KEY}")
  ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"
}

# ── auto-detect registry from running pod image refs ─────────────────────────
detect_registry() {
  local img
  img=$(kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image} {.items[*].spec.initContainers[*].image}' \
        2>/dev/null | tr ' ' '\n' \
        | grep -oP '^\d+\.\d+\.\d+\.\d+:\d+' \
        | sort -u | head -1 || true)
  echo "${img}"
}

# ── auto-detect worker IPs from kubectl node list ────────────────────────────
detect_workers() {
  local local_ips
  local_ips=$(hostname -I 2>/dev/null || ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1)
  kubectl get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    2>/dev/null | while read -r ip; do
      [[ -z "${ip}" ]] && continue
      if ! echo "${local_ips}" | grep -qw "${ip}"; then
        echo -n "${ip} "
      fi
    done
}

# ── write insecure registry drop-in on a node via SSH ────────────────────────
write_dropin_ssh() {
  local ip="$1"
  local registry="$2"
  ssh_exec "${ip}" bash -s -- "${registry}" <<'REMOTE'
    REGISTRY="$1"
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
REMOTE
}

# ── write insecure registry drop-in locally (controller) ─────────────────────
write_dropin_local() {
  local registry="$1"
  sudo mkdir -p /etc/k0s/containerd.d
  sudo tee /etc/k0s/containerd.d/insecure-registry.toml >/dev/null <<TOML
[plugins."io.containerd.grpc.v1.cri".registry]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${registry}"]
      endpoint = ["http://${registry}"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."${registry}".tls]
      insecure_skip_verify = true
TOML
}

# ─────────────────────────────────────────────────────────────────────────────
log "============================================"
log "  Insecure registry fix"
log "============================================"

# ── print resolved config so user can verify ─────────────────────────────────
echo -e "  ${BOLD}Config file  :${NC} ${CONFIG_FILE}"
echo -e "  ${BOLD}SSH user     :${NC} ${SSH_USER}"
echo -e "  ${BOLD}SSH key      :${NC} ${SSH_KEY:-"(agent / default)"}$( [[ -n "${SSH_KEY}" && ! -f "${SSH_KEY}" ]] && echo " ⚠ NOT FOUND" || true)"
echo -e "  ${BOLD}Registry     :${NC} ${REGISTRY:-"(will auto-detect)"}"
echo -e "  ${BOLD}Worker IPs   :${NC} ${WORKER_IPS:-"(will auto-detect)"}"
echo ""

# ── validate SSH key if specified ────────────────────────────────────────────
if [[ -n "${SSH_KEY}" && ! -f "${SSH_KEY}" ]]; then
  err "SSH key not found: ${SSH_KEY}"
  err "Update cluster.sshKeyPath in ${CONFIG_FILE} or pass --ssh-key <path>."
  exit 1
fi

# ── resolve registry ─────────────────────────────────────────────────────────
if [[ -z "${REGISTRY}" ]]; then
  log "Auto-detecting registry from pod specs..."
  REGISTRY=$(detect_registry)
  if [[ -z "${REGISTRY}" ]]; then
    err "Could not auto-detect registry. Pass --registry <host:port> or set images.registry in ${CONFIG_FILE}."
    exit 1
  fi
  log "Detected registry: ${REGISTRY}"
else
  log "Registry: ${REGISTRY}"
fi

# ── verify registry responds on HTTP ─────────────────────────────────────────
log "Verifying registry at http://${REGISTRY}/v2/ ..."
if curl -sf --max-time 5 "http://${REGISTRY}/v2/" >/dev/null 2>&1; then
  log "✓ Registry responding on HTTP"
else
  warn "Registry did not respond at http://${REGISTRY}/v2/ — proceeding anyway"
fi

# ── resolve worker IPs ────────────────────────────────────────────────────────
if [[ -z "${WORKER_IPS}" ]]; then
  log "Auto-detecting worker IPs from kubectl node list..."
  WORKER_IPS=$(detect_workers)
  [[ -z "${WORKER_IPS}" ]] && warn "No worker nodes detected — will only fix the controller."
fi
[[ -n "${WORKER_IPS}" ]] && log "Workers: ${WORKER_IPS}"

# ── fix controller (local, no SSH) ───────────────────────────────────────────
log ""
log "── Controller (localhost) ──"
write_dropin_local "${REGISTRY}"
log "Drop-in written. Restarting k0s controller service..."
if sudo systemctl restart k0scontroller 2>/dev/null; then
  log "✓ k0scontroller restarted"
elif sudo systemctl restart k0s 2>/dev/null; then
  log "✓ k0s restarted"
else
  err "Could not restart controller service — tried k0scontroller and k0s."
  err "Check: sudo systemctl list-units 'k0s*'"
  exit 1
fi

log "Waiting for API server..."
for i in $(seq 1 30); do
  if kubectl get --raw /healthz >/dev/null 2>&1; then
    log "✓ API server ready (${i}s)"
    break
  fi
  sleep 2
  if [[ ${i} -eq 30 ]]; then
    err "API server not ready after 60s — check: sudo journalctl -u k0s -n 50"
    exit 1
  fi
done

# ── fix each worker via SSH ───────────────────────────────────────────────────
failed_workers=()
if [[ -n "${WORKER_IPS}" ]]; then
  log ""
  log "── Worker nodes ──"
  for worker_ip in ${WORKER_IPS}; do
    log "  ${worker_ip}..."
    if write_dropin_ssh "${worker_ip}" "${REGISTRY}"; then
      log "  Drop-in written. Restarting k0sworker..."
      ssh_exec "${worker_ip}" "sudo systemctl restart k0sworker"
      log "  ✓ ${worker_ip} done"
    else
      err "  Failed on ${worker_ip}"
      failed_workers+=("${worker_ip}")
    fi
  done
fi

# ── delete pending pods so they reschedule immediately ───────────────────────
log ""
log "Deleting Pending pods to trigger reschedule..."
pending=$(kubectl get pods -A --field-selector=status.phase=Pending \
          -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ -z "${pending}" ]]; then
  log "No Pending pods found."
else
  while IFS=' ' read -r ns pod; do
    [[ -z "${ns}" ]] && continue
    kubectl delete pod -n "${ns}" "${pod}" --ignore-not-found
    log "  Deleted ${ns}/${pod}"
  done <<< "${pending}"
fi

# ── summary ──────────────────────────────────────────────────────────────────
log ""
log "============================================"
if [[ ${#failed_workers[@]} -gt 0 ]]; then
  warn "Failed on: ${failed_workers[*]}"
  warn "SSH manually and run:"
  warn "  sudo mkdir -p /etc/k0s/containerd.d"
  warn "  sudo tee /etc/k0s/containerd.d/insecure-registry.toml <<EOF"
  warn "  ... (see script for TOML content) ..."
  warn "  sudo systemctl restart k0sworker"
  exit 1
else
  log "✓ All nodes fixed."
  log "  Monitor: kubectl get pods -A -w"
fi
