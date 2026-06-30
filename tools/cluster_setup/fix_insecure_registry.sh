#!/usr/bin/env bash
# fix_insecure_registry.sh — run from ANY machine with SSH access to the
# cluster nodes. Pushes an insecure registry drop-in to the controller and
# all worker nodes, restarts containerd, then deletes Pending pods.
#
# By default reads all values from k0s-cluster-config.yaml in the same
# directory, so no flags are needed if that file is already configured.
#
# Usage:
#   ./fix_insecure_registry.sh [--config <path>] [--registry <host:port>]
#                              [--controller <ip>] [--workers "<ip1> <ip2>"]
#                              [--ssh-key <path>] [--ssh-user <user>]
#
# Examples:
#   ./fix_insecure_registry.sh
#   ./fix_insecure_registry.sh --registry 172.31.51.179:5000
#   ./fix_insecure_registry.sh \
#     --controller 172.31.51.179 \
#     --workers "172.31.33.255 172.31.22.91 172.31.22.173" \
#     --registry 172.31.51.179:5000 \
#     --ssh-key ~/.ssh/id_rsa --ssh-user ec2-user

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

CONFIG_FILE="${SCRIPT_DIR}/k0s-cluster-config.yaml"
REGISTRY=""
CONTROLLER_IP=""
WORKER_IPS=""
SSH_USER="root"
SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)      CONFIG_FILE="$2";    shift 2 ;;
    --registry)    REGISTRY="$2";      shift 2 ;;
    --controller)  CONTROLLER_IP="$2"; shift 2 ;;
    --workers)     WORKER_IPS="$2";    shift 2 ;;
    --ssh-key)     SSH_KEY="$2";       shift 2 ;;
    --ssh-user)    SSH_USER="$2";      shift 2 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── read config file ──────────────────────────────────────────────────────────
if [[ -f "${CONFIG_FILE}" ]]; then
  log "Reading config from ${CONFIG_FILE}"
  if command -v yq &>/dev/null; then
    [[ -z "${SSH_KEY}" ]]  && SSH_KEY=$(yq eval '.cluster.sshKeyPath // ""'    "${CONFIG_FILE}" 2>/dev/null || true)
    [[ -z "${SSH_USER}" || "${SSH_USER}" == "root" ]] \
                           && SSH_USER=$(yq eval '.cluster.sshUser // "root"'  "${CONFIG_FILE}" 2>/dev/null || true)
    [[ -z "${REGISTRY}" ]] && REGISTRY=$(yq eval '.images.registry // ""'      "${CONFIG_FILE}" 2>/dev/null || true)
    if [[ -z "${CONTROLLER_IP}" ]]; then
      CONTROLLER_IP=$(yq eval '.nodes.existingIPs.controllers[0]' "${CONFIG_FILE}" 2>/dev/null || true)
    fi
    if [[ -z "${WORKER_IPS}" ]]; then
      WORKER_IPS=$(yq eval '.nodes.existingIPs.workers[]' "${CONFIG_FILE}" 2>/dev/null | tr '\n' ' ' || true)
    fi
  else
    warn "yq not found — cannot parse config file. Pass all values via CLI flags."
  fi
  SSH_KEY="${SSH_KEY/#\~/$HOME}"
else
  warn "Config file not found at ${CONFIG_FILE}. Using CLI flags."
fi

# ── ssh helper ────────────────────────────────────────────────────────────────
ssh_exec() {
  local host="$1"; shift
  local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                  -o ConnectTimeout=10 -o BatchMode=yes)
  [[ -n "${SSH_KEY}" && -f "${SSH_KEY}" ]] && ssh_opts+=(-i "${SSH_KEY}")
  ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"
}

# ── write drop-in and restart containerd on a node via SSH ───────────────────
fix_node() {
  local ip="$1"
  local registry="$2"
  local role="$3"   # controller | worker

  log "  ── ${ip} (${role}) ──"

  # Write registry config — use hosts.toml for containerd v2, drop-in TOML for v1.
  # containerd v2 (k0s >= 1.33) rejects io.containerd.grpc.v1.cri in a pre-flight
  # check and crash-loops. Detect by checking the k0s managed base config.
  ssh_exec "${ip}" bash -s -- "${registry}" <<'REMOTE'
    REGISTRY="$1"
    if sudo grep -q 'io\.containerd\.cri\.v1' /etc/k0s/containerd.toml 2>/dev/null; then
      echo "--- containerd v2 detected: writing hosts.toml ---"
      sudo mkdir -p "/etc/k0s/containerd/certs.d/${REGISTRY}"
      printf 'server = "http://%s"\n\n[host."http://%s"]\n  capabilities = ["pull", "resolve", "push"]\n  skip_verify = true\n' \
        "${REGISTRY}" "${REGISTRY}" \
        | sudo tee "/etc/k0s/containerd/certs.d/${REGISTRY}/hosts.toml" >/dev/null
      echo "Written: /etc/k0s/containerd/certs.d/${REGISTRY}/hosts.toml"
    else
      echo "--- containerd v1 detected: writing drop-in TOML ---"
      sudo mkdir -p /etc/k0s/containerd.d
      # Remove the broken v1 drop-in if it was previously written
      sudo rm -f /etc/k0s/containerd.d/insecure-registry.toml
      printf '[plugins."io.containerd.grpc.v1.cri".registry]\n  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]\n    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."%s"]\n      endpoint = ["http://%s"]\n  [plugins."io.containerd.grpc.v1.cri".registry.configs]\n    [plugins."io.containerd.grpc.v1.cri".registry.configs."%s".tls]\n      insecure_skip_verify = true\n' \
        "${REGISTRY}" "${REGISTRY}" "${REGISTRY}" \
        | sudo tee /etc/k0s/containerd.d/insecure-registry.toml >/dev/null
      echo "Written: /etc/k0s/containerd.d/insecure-registry.toml"
    fi
REMOTE

  # Restart the right service
  if [[ "${role}" == "controller" ]]; then
    log "  Restarting k0s controller service..."
    ssh_exec "${ip}" "
      if sudo systemctl restart k0scontroller 2>/dev/null; then
        echo 'restarted k0scontroller'
      elif sudo systemctl restart k0s 2>/dev/null; then
        echo 'restarted k0s'
      else
        echo 'ERROR: no k0s controller service found' >&2
        sudo systemctl list-units 'k0s*' >&2
        exit 1
      fi
    "
  else
    log "  Restarting k0sworker..."
    ssh_exec "${ip}" "sudo systemctl restart k0sworker"
  fi

  log "  ✓ ${ip} done"
}

# ─────────────────────────────────────────────────────────────────────────────
log "============================================"
log "  Insecure registry fix"
log "============================================"
echo -e "  ${BOLD}Config file   :${NC} ${CONFIG_FILE}"
echo -e "  ${BOLD}SSH user      :${NC} ${SSH_USER}"
echo -e "  ${BOLD}SSH key       :${NC} ${SSH_KEY:-"(agent / default)"}$([[ -n "${SSH_KEY}" && ! -f "${SSH_KEY}" ]] && echo " ⚠ NOT FOUND" || true)"
echo -e "  ${BOLD}Registry      :${NC} ${REGISTRY:-"(will auto-detect)"}"
echo -e "  ${BOLD}Controller IP :${NC} ${CONTROLLER_IP:-"(required)"}"
echo -e "  ${BOLD}Worker IPs    :${NC} ${WORKER_IPS:-"(none)"}"
echo ""

# ── validate ─────────────────────────────────────────────────────────────────
if [[ -n "${SSH_KEY}" && ! -f "${SSH_KEY}" ]]; then
  err "SSH key not found: ${SSH_KEY}"
  err "Update cluster.sshKeyPath in ${CONFIG_FILE} or pass --ssh-key <path>."
  exit 1
fi

if [[ -z "${CONTROLLER_IP}" ]]; then
  err "Controller IP is required. Set nodes.existingIPs.controllers[0] in ${CONFIG_FILE} or pass --controller <ip>."
  exit 1
fi

# ── resolve registry ─────────────────────────────────────────────────────────
if [[ -z "${REGISTRY}" ]]; then
  log "Auto-detecting registry from pod specs (via controller)..."
  REGISTRY=$(ssh_exec "${CONTROLLER_IP}" "
    sudo k0s kubectl get pods -A \
      -o jsonpath='{.items[*].spec.containers[*].image} {.items[*].spec.initContainers[*].image}' \
      2>/dev/null | tr ' ' '\n' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' | sort -u | head -1
  " 2>/dev/null || true)
  if [[ -z "${REGISTRY}" ]]; then
    err "Could not auto-detect registry. Pass --registry <host:port>."
    exit 1
  fi
  log "Detected registry: ${REGISTRY}"
else
  log "Registry: ${REGISTRY}"
fi

# ── fix controller ────────────────────────────────────────────────────────────
log ""
log "── Fixing controller (${CONTROLLER_IP}) ──"
# Remove any previously written v1 drop-in that is crash-looping the controller
ssh_exec "${CONTROLLER_IP}" "sudo rm -f /etc/k0s/containerd.d/insecure-registry.toml" || true
fix_node "${CONTROLLER_IP}" "${REGISTRY}" "controller"

# Wait for API server to come back
log "Waiting for API server (up to 180s)..."
for i in $(seq 1 90); do
  if ssh_exec "${CONTROLLER_IP}" "sudo k0s kubectl get --raw /healthz" >/dev/null 2>&1; then
    log "✓ API server ready ($((i * 2))s)"
    break
  fi
  sleep 2
  if [[ ${i} -eq 90 ]]; then
    err "API server not ready after 180s — check: ssh ${SSH_USER}@${CONTROLLER_IP} 'sudo journalctl -u k0scontroller -n 50'"
    exit 1
  fi
done

# ── fix workers ───────────────────────────────────────────────────────────────
failed_workers=()
if [[ -n "${WORKER_IPS}" ]]; then
  log ""
  log "── Fixing worker nodes ──"
  for worker_ip in ${WORKER_IPS}; do
    if fix_node "${worker_ip}" "${REGISTRY}" "worker"; then
      : # logged inside fix_node
    else
      err "Failed on ${worker_ip}"
      failed_workers+=("${worker_ip}")
    fi
  done
fi

# ── delete pending pods ───────────────────────────────────────────────────────
log ""
log "Deleting Pending pods to trigger reschedule..."
pending=$(ssh_exec "${CONTROLLER_IP}" "
  sudo k0s kubectl get pods -A --field-selector=status.phase=Pending \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{\" \"}{.metadata.name}{\"\n\"}{end}' 2>/dev/null
" || true)

if [[ -z "${pending}" ]]; then
  log "No Pending pods found."
else
  while IFS=' ' read -r ns pod; do
    [[ -z "${ns}" ]] && continue
    ssh_exec "${CONTROLLER_IP}" "sudo k0s kubectl delete pod -n ${ns} ${pod} --ignore-not-found"
    log "  Deleted ${ns}/${pod}"
  done <<< "${pending}"
fi

# ── summary ───────────────────────────────────────────────────────────────────
log ""
log "============================================"
if [[ ${#failed_workers[@]} -gt 0 ]]; then
  warn "Failed on: ${failed_workers[*]}"
  exit 1
else
  log "✓ All nodes fixed."
  log "  Monitor: ssh ${SSH_USER}@${CONTROLLER_IP} 'sudo k0s kubectl get pods -A -w'"
fi
