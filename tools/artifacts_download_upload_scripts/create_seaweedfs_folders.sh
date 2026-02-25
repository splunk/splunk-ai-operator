#!/bin/bash
# Create standard folder prefixes in SeaweedFS (S3-compatible). Uses the same
# OBJECT_STORE_* / SEAWEEDFS_* env vars as upload_to_seaweedfs.sh. Run after
# SeaweedFS is up (e.g. systemd service or upload script has started it).

set -e

# Same endpoint/credentials as upload_to_seaweedfs.sh
OBJECT_STORE_ENDPOINT="${OBJECT_STORE_ENDPOINT:-${SEAWEEDFS_ENDPOINT:-http://127.0.0.1:8333}}"
OBJECT_STORE_BUCKET="${OBJECT_STORE_BUCKET:-${SEAWEEDFS_BUCKET:-ai-platform-bucket}}"
OBJECT_STORE_ACCESS_KEY="${OBJECT_STORE_ACCESS_KEY:-${SEAWEEDFS_ACCESS_KEY:-minioadmin}}"
OBJECT_STORE_SECRET_KEY="${OBJECT_STORE_SECRET_KEY:-${SEAWEEDFS_SECRET_KEY:-minioadmin}}"

OBJECT_STORE_BUCKET=$(echo "$OBJECT_STORE_BUCKET" | tr '[:upper:]' '[:lower:]')

# Standard folders expected by the platform (create by uploading .keep)
FOLDERS=(apps artifacts config job_groups model_artifacts tasks)

seaweedfs_ok() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "${OBJECT_STORE_ENDPOINT}" 2>/dev/null || echo "000")
  [[ "$code" == "200" || "$code" == "403" || "$code" == "400" ]]
}

if ! seaweedfs_ok; then
  echo "SeaweedFS not reachable at ${OBJECT_STORE_ENDPOINT}. Start SeaweedFS first (e.g. sudo systemctl start seaweedfs)."
  exit 1
fi

# Install mc if needed
if ! command -v mc &>/dev/null; then
  echo "Installing MinIO Client (mc)..."
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  if [[ "$OS" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew install minio/stable/mc
    else
      if [[ "$ARCH" == "arm64" ]]; then MC_URL="https://dl.min.io/client/mc/release/darwin-arm64/mc"; else MC_URL="https://dl.min.io/client/mc/release/darwin-amd64/mc"; fi
      curl -o /tmp/mc "$MC_URL" && chmod +x /tmp/mc && sudo mv /tmp/mc /usr/local/bin/mc
    fi
  elif [[ "$OS" == "Linux" ]]; then
    if [[ "$ARCH" == "x86_64" ]]; then MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"; elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then MC_URL="https://dl.min.io/client/mc/release/linux-arm64/mc"; else echo "Unsupported arch: $ARCH"; exit 1; fi
    curl -o /tmp/mc "$MC_URL" && chmod +x /tmp/mc
    sudo mv /tmp/mc /usr/local/bin/mc 2>/dev/null || { mkdir -p ~/.local/bin; mv /tmp/mc ~/.local/bin/mc; export PATH="$PATH:$HOME/.local/bin"; }
  else
    echo "Unsupported OS: $OS"; exit 1
  fi
fi

MC_ALIAS="seaweedfs"
mc alias set "$MC_ALIAS" "$OBJECT_STORE_ENDPOINT" "$OBJECT_STORE_ACCESS_KEY" "$OBJECT_STORE_SECRET_KEY" --api S3v4
mc mb "${MC_ALIAS}/${OBJECT_STORE_BUCKET}" --ignore-existing 2>/dev/null || true

echo "Creating folders in ${OBJECT_STORE_BUCKET}: ${FOLDERS[*]}"
for dir in "${FOLDERS[@]}"; do
  echo "placeholder" | mc pipe "${MC_ALIAS}/${OBJECT_STORE_BUCKET}/${dir}/.keep" 2>/dev/null || true
  echo "  ${dir}/"
done
echo "Done. Folders: apps/, artifacts/, config/, job_groups/, model_artifacts/, tasks/"
