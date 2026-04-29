#!/bin/bash
# Install SeaweedFS as a systemd service (restart on failure, start on boot).
# Run with sudo on the host where SeaweedFS should run (e.g. EC2).
# Prereqs: weed binary at /usr/local/bin/weed (run upload_to_seaweedfs.sh once to install, or install manually).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="seaweedfs"
UNIT_FILE="${SCRIPT_DIR}/seaweedfs.service"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo to install the systemd service."
  exit 1
fi

if [[ ! -f /usr/local/bin/weed ]]; then
  echo "weed not found at /usr/local/bin/weed. Install it first, e.g.:"
  echo "  Run ./upload_to_seaweedfs.sh once (it will install weed), or"
  echo "  download from https://github.com/seaweedfs/seaweedfs/releases and extract weed to /usr/local/bin/"
  exit 1
fi

# Service runs as ec2-user; ensure the binary is executable by that user (fixes "Permission denied" on EXEC).
chmod 755 /usr/local/bin/weed
# On SELinux systems (e.g. RHEL, Amazon Linux), label the binary so the service can execute it.
if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
  if command -v chcon &>/dev/null; then
    chcon -t bin_t /usr/local/bin/weed 2>/dev/null || true
  fi
fi

echo "Installing ${SERVICE_NAME}.service..."
cp "$UNIT_FILE" /etc/systemd/system/"${SERVICE_NAME}.service"
chmod 644 /etc/systemd/system/"${SERVICE_NAME}.service"
systemctl daemon-reload

echo "Enabling ${SERVICE_NAME} to start on boot..."
systemctl enable "${SERVICE_NAME}"

echo "Starting ${SERVICE_NAME} now..."
systemctl start "${SERVICE_NAME}"

sleep 2
if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo "Warning: ${SERVICE_NAME} did not stay running. Check: sudo systemctl status ${SERVICE_NAME} && journalctl -u ${SERVICE_NAME} -n 30"
  exit 1
fi

echo ""
echo "SeaweedFS is running as a systemd service."
echo "  status:  sudo systemctl status ${SERVICE_NAME}"
echo "  logs:    journalctl -u ${SERVICE_NAME} -f"
echo "  stop:    sudo systemctl stop ${SERVICE_NAME}"
echo "  restart: sudo systemctl restart ${SERVICE_NAME}"
echo ""
echo "S3 endpoint: http://127.0.0.1:8333 (default credentials minioadmin/minioadmin)"
echo "Data dir:    /home/ec2-user/data (edit SEAWEEDFS_DIR in the unit to change)"
