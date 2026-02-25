#!/bin/bash
# Upload Splunk_AI_Assistant_Cloud.tgz to SeaweedFS at bucket/apps/Splunk_AI_Assistant_Cloud.tgz.
# Uses the same OBJECT_STORE_* / SEAWEEDFS_* env vars as upload_to_seaweedfs.sh and create_seaweedfs_folders.sh.

set -e

APP_FILENAME="${SPLUNK_APP_FILENAME:-Splunk_AI_Assistant_Cloud.tgz}"
LOCAL_PATH="${SPLUNK_APP_LOCAL_PATH:-./${APP_FILENAME}}"

OBJECT_STORE_ENDPOINT="${OBJECT_STORE_ENDPOINT:-${SEAWEEDFS_ENDPOINT:-http://127.0.0.1:8333}}"
OBJECT_STORE_BUCKET="${OBJECT_STORE_BUCKET:-${SEAWEEDFS_BUCKET:-ai-platform-bucket-minio-us-east-2}}"
OBJECT_STORE_ACCESS_KEY="${OBJECT_STORE_ACCESS_KEY:-${SEAWEEDFS_ACCESS_KEY:-minioadmin}}"
OBJECT_STORE_SECRET_KEY="${OBJECT_STORE_SECRET_KEY:-${SEAWEEDFS_SECRET_KEY:-minioadmin}}"

OBJECT_STORE_BUCKET=$(echo "$OBJECT_STORE_BUCKET" | tr '[:upper:]' '[:lower:]')

seaweedfs_ok() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "${OBJECT_STORE_ENDPOINT}" 2>/dev/null || echo "000")
  [[ "$code" == "200" || "$code" == "403" || "$code" == "400" ]]
}

if [[ ! -f "$LOCAL_PATH" ]]; then
  echo "Error: App file not found: $LOCAL_PATH"
  echo "Set SPLUNK_APP_LOCAL_PATH to the path of Splunk_AI_Assistant_Cloud.tgz, or put the file in the current directory."
  exit 1
fi

if ! seaweedfs_ok; then
  echo "SeaweedFS not reachable at ${OBJECT_STORE_ENDPOINT}. Start SeaweedFS first (e.g. sudo systemctl start seaweedfs)."
  exit 1
fi

if ! command -v mc &>/dev/null; then
  echo "MinIO Client (mc) is required. Install it or run create_seaweedfs_folders.sh first (it installs mc)."
  exit 1
fi

MC_ALIAS="seaweedfs"
mc alias set "$MC_ALIAS" "$OBJECT_STORE_ENDPOINT" "$OBJECT_STORE_ACCESS_KEY" "$OBJECT_STORE_SECRET_KEY" --api S3v4
mc mb "${MC_ALIAS}/${OBJECT_STORE_BUCKET}" --ignore-existing 2>/dev/null || true

DEST="${MC_ALIAS}/${OBJECT_STORE_BUCKET}/apps/${APP_FILENAME}"
echo "Uploading ${LOCAL_PATH} to ${DEST}..."
mc cp "$LOCAL_PATH" "$DEST"
echo "Done. App is at ${OBJECT_STORE_BUCKET}/apps/${APP_FILENAME}"
