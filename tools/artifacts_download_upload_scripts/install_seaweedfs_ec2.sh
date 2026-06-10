#!/bin/bash
# Install SeaweedFS (weed) binary and start it as a systemd service.
# Does NOT upload any model artifacts — use upload_to_seaweedfs_upload_only.sh for that.
#
# Usage (run on the EC2 instance as root or with sudo):
#   sudo ./install_seaweedfs_ec2.sh [--port PORT] [--data-dir DIR] [--access-key KEY] [--secret-key SECRET]
#
# Defaults:
#   port:       8333
#   data-dir:   /data/seaweedfs
#   access-key: minioadmin
#   secret-key: minioadmin

set -e

SEAWEEDFS_PORT="${SEAWEEDFS_PORT:-8333}"
SEAWEEDFS_DATA_DIR="${SEAWEEDFS_DATA_DIR:-/data/seaweedfs}"
SEAWEEDFS_ACCESS_KEY="${SEAWEEDFS_ACCESS_KEY:-minioadmin}"
SEAWEEDFS_SECRET_KEY="${SEAWEEDFS_SECRET_KEY:-minioadmin}"
SEAWEEDFS_VOLUME_MAX="${SEAWEEDFS_VOLUME_MAX:-100}"

log() { echo "[seaweedfs-ec2] $*"; }
err() { echo "[seaweedfs-ec2] ERROR: $*" >&2; exit 1; }

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)        SEAWEEDFS_PORT="$2"; shift 2 ;;
    --data-dir)    SEAWEEDFS_DATA_DIR="$2"; shift 2 ;;
    --access-key)  SEAWEEDFS_ACCESS_KEY="$2"; shift 2 ;;
    --secret-key)  SEAWEEDFS_SECRET_KEY="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  err "This script must be run as root (or with sudo). Run: sudo $0 ${*:-}"
fi

# ---------- Install weed binary ----------
install_weed_binary() {
  local os arch tag asset url tmpdir bindir
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)   case "$arch" in x86_64|amd64) asset="linux_amd64.tar.gz";; aarch64|arm64) asset="linux_arm64.tar.gz";; *) err "Unsupported arch: $arch";; esac ;;
    Darwin)  case "$arch" in x86_64|amd64) asset="darwin_amd64.tar.gz";; arm64) asset="darwin_arm64.tar.gz";; *) err "Unsupported arch: $arch";; esac ;;
    *) err "Unsupported OS: $os" ;;
  esac
  log "Fetching latest SeaweedFS release tag..."
  tag=$(curl -sL https://api.github.com/repos/seaweedfs/seaweedfs/releases/latest | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')
  [[ -z "$tag" ]] && err "Could not determine latest SeaweedFS release tag."
  url="https://github.com/seaweedfs/seaweedfs/releases/download/${tag}/${asset}"
  log "Downloading SeaweedFS ${tag} (${asset})..."
  tmpdir="$(mktemp -d)"
  if ! curl -sSL -o "$tmpdir/weed.tar.gz" "$url"; then
    rm -rf "$tmpdir"; err "Download failed: $url"
  fi
  tar -xzf "$tmpdir/weed.tar.gz" -C "$tmpdir"
  [[ ! -f "$tmpdir/weed" ]] && { rm -rf "$tmpdir"; err "weed binary not found in archive."; }
  chmod 755 "$tmpdir/weed"
  mv "$tmpdir/weed" /usr/local/bin/weed
  rm -rf "$tmpdir"
  # Fix SELinux context so systemd can exec the binary (binary moved from tmpdir gets tmp_t).
  command -v restorecon &>/dev/null && restorecon /usr/local/bin/weed || true
  command -v chcon &>/dev/null && chcon -t bin_t /usr/local/bin/weed 2>/dev/null || true
  log "Installed: /usr/local/bin/weed $(/usr/local/bin/weed version 2>/dev/null | head -1)"
}

if [[ ! -f /usr/local/bin/weed ]]; then
  install_weed_binary
else
  log "weed already present: $(/usr/local/bin/weed version 2>/dev/null | head -1)"
  # Ensure SELinux context is correct even for existing binary.
  command -v restorecon &>/dev/null && restorecon /usr/local/bin/weed || true
fi

# ---------- Prepare data directory ----------
mkdir -p "${SEAWEEDFS_DATA_DIR}"
chmod 755 "${SEAWEEDFS_DATA_DIR}"

# ---------- Write credentials config ----------
CONFIG_DIR="/etc/seaweedfs"
mkdir -p "${CONFIG_DIR}"
cat > "${CONFIG_DIR}/s3.json" <<JSON
{
  "identities": [
    {
      "name": "admin",
      "credentials": [
        {
          "accessKey": "${SEAWEEDFS_ACCESS_KEY}",
          "secretKey": "${SEAWEEDFS_SECRET_KEY}"
        }
      ],
      "actions": ["Admin", "Read", "Write", "List", "Tagging"]
    }
  ]
}
JSON
chmod 600 "${CONFIG_DIR}/s3.json"
log "Wrote ${CONFIG_DIR}/s3.json"

# ---------- Write systemd unit ----------
cat > /etc/systemd/system/seaweedfs.service <<UNIT
[Unit]
Description=SeaweedFS Object Storage
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/weed server -s3 -s3.config=${CONFIG_DIR}/s3.json \
  -s3.port=${SEAWEEDFS_PORT} \
  -ip.bind=0.0.0.0 \
  -volume.max=${SEAWEEDFS_VOLUME_MAX} \
  -dir=${SEAWEEDFS_DATA_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65536
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable seaweedfs
systemctl restart seaweedfs
log "SeaweedFS service started (port ${SEAWEEDFS_PORT})"

# ---------- Wait for S3 gateway to respond ----------
seaweedfs_ok=false
for i in {1..30}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${SEAWEEDFS_PORT}" 2>/dev/null || echo "000")
  if [[ "$code" == "200" || "$code" == "403" || "$code" == "400" ]]; then
    seaweedfs_ok=true; break
  fi
  sleep 2
done
if [[ "$seaweedfs_ok" != "true" ]]; then
  err "SeaweedFS did not respond on port ${SEAWEEDFS_PORT} within 60s. Check: systemctl status seaweedfs && journalctl -u seaweedfs -n 30"
fi

PRIVATE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$PRIVATE_IP" ]] && PRIVATE_IP="$(curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null || echo 'SEAWEEDFS_EC2_PRIVATE_IP')"
ENDPOINT="http://${PRIVATE_IP}:${SEAWEEDFS_PORT}"

echo ""
log "=== SeaweedFS on EC2 is ready ==="
echo "  Endpoint:   ${ENDPOINT}"
echo "  Data dir:   ${SEAWEEDFS_DATA_DIR}"
echo "  Access key: ${SEAWEEDFS_ACCESS_KEY}"
echo "  Secret key: ${SEAWEEDFS_SECRET_KEY}"
echo ""
echo "Add to k0s-cluster-config.yaml (storage.objectStore):"
echo "  objectStore:"
echo "    type: seaweedfs"
echo "    bucket: ai-platform-bucket"
echo "    endpoint: \"${ENDPOINT}\""
echo "    auth:"
echo "      rootUser: \"${SEAWEEDFS_ACCESS_KEY}\""
echo "      rootPassword: \"${SEAWEEDFS_SECRET_KEY}\""
echo ""
echo "  status:  systemctl status seaweedfs"
echo "  logs:    journalctl -u seaweedfs -f"
echo "  stop:    systemctl stop seaweedfs"
echo ""
