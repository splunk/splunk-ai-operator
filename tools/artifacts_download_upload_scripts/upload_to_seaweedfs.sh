#!/bin/bash
# Upload model artifacts to SeaweedFS (S3-compatible). If SeaweedFS is not running,
# the script can install and start it (weed binary, no Docker). Creates configured
# buckets and uploads from ./model_artifacts. Use OBJECT_STORE_* or SEAWEEDFS_* env vars.

set -e

SOURCE_DIR="./model_artifacts"
SEAWEEDFS_PORT="${SEAWEEDFS_PORT:-8333}"

# Endpoint and credentials (prefer generic OBJECT_STORE_*, then SEAWEEDFS_*).
# SeaweedFS S3 has no built-in users: if the server is started with credentials (env or -config),
# they must match these values. This script sets them when it auto-starts SeaweedFS.
OBJECT_STORE_ENDPOINT="${OBJECT_STORE_ENDPOINT:-${SEAWEEDFS_ENDPOINT:-http://127.0.0.1:8333}}"
OBJECT_STORE_BUCKET="${OBJECT_STORE_BUCKET:-${SEAWEEDFS_BUCKET:-ai-platform-bucket}}"
OBJECT_STORE_ACCESS_KEY="${OBJECT_STORE_ACCESS_KEY:-${SEAWEEDFS_ACCESS_KEY:-minioadmin}}"
OBJECT_STORE_SECRET_KEY="${OBJECT_STORE_SECRET_KEY:-${SEAWEEDFS_SECRET_KEY:-minioadmin}}"
# Bucket list to create (comma-separated). If unset, only primary bucket is created.
SEAWEEDFS_BUCKETS="${SEAWEEDFS_BUCKETS:-$OBJECT_STORE_BUCKET}"
# Set to 1 to skip auto-install and only fail if SeaweedFS is not reachable.
SEAWEEDFS_SKIP_INSTALL="${SEAWEEDFS_SKIP_INSTALL:-0}"
# Retries for each artifact upload (large files can trigger transient "internal error").
SEAWEEDFS_UPLOAD_RETRIES="${SEAWEEDFS_UPLOAD_RETRIES:-3}"
SEAWEEDFS_UPLOAD_RETRY_DELAY="${SEAWEEDFS_UPLOAD_RETRY_DELAY:-15}"
# Max concurrent uploads (1 = sequential).
SEAWEEDFS_PARALLEL_JOBS="${SEAWEEDFS_PARALLEL_JOBS:-1}"
# Path to log failed artifact ids and messages (appended to on failure).
SEAWEEDFS_ERROR_LOG="${SEAWEEDFS_ERROR_LOG:-./seaweedfs_upload_errors.log}"
# Set to 1 to skip uploading a file if it already exists at destination (avoids re-uploading on script re-runs).
SEAWEEDFS_SKIP_EXISTING="${SEAWEEDFS_SKIP_EXISTING:-0}"
# Wait up to this many seconds for a volume server to appear in the cluster before uploading (avoids "0 node candidates").
# Set to 0 to skip. Only used when endpoint is local and weed is available.
SEAWEEDFS_WAIT_VOLUME_SERVER="${SEAWEEDFS_WAIT_VOLUME_SERVER:-60}"
# Master address for cluster.ps (default: host from endpoint with port 9333).
SEAWEEDFS_MASTER="${SEAWEEDFS_MASTER:-}"
# Max volumes per volume server (default 100; 0 = auto from disk). Avoids "0 node candidates" when default (e.g. 7) is reached.
SEAWEEDFS_VOLUME_MAX="${SEAWEEDFS_VOLUME_MAX:-100}"

# Normalize primary bucket to lowercase
OBJECT_STORE_BUCKET=$(echo "$OBJECT_STORE_BUCKET" | tr '[:upper:]' '[:lower:]')

# ---- Check SeaweedFS is reachable ----
seaweedfs_ok() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "${OBJECT_STORE_ENDPOINT}" 2>/dev/null || echo "000")
  [[ "$code" == "200" || "$code" == "403" || "$code" == "400" ]] && return 0
  return 1
}

# ---- Install and start SeaweedFS (weed binary from GitHub releases) ----
install_and_start_seaweedfs() {
  local os arch tag asset url tmpdir bindir
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)   case "$arch" in x86_64|amd64) asset="linux_amd64.tar.gz";; aarch64|arm64) asset="linux_arm64.tar.gz";; *) echo "Unsupported arch: $arch"; return 1;; esac ;;
    Darwin)  case "$arch" in x86_64|amd64) asset="darwin_amd64.tar.gz";; arm64) asset="darwin_arm64.tar.gz";; *) echo "Unsupported arch: $arch"; return 1;; esac ;;
    *)       echo "Unsupported OS: $os"; return 1 ;;
  esac
  echo "Installing SeaweedFS (weed) for $os $arch..."
  tag=$(curl -sL https://api.github.com/repos/seaweedfs/seaweedfs/releases/latest | grep '"tag_name":' | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')
  [[ -z "$tag" ]] && { echo "Could not get latest SeaweedFS release tag."; return 1; }
  url="https://github.com/seaweedfs/seaweedfs/releases/download/${tag}/${asset}"
  tmpdir="$(mktemp -d)"
  if ! curl -sSL -o "$tmpdir/weed.tar.gz" "$url"; then
    echo "Download failed: $url"; rm -rf "$tmpdir"; return 1
  fi
  tar -xzf "$tmpdir/weed.tar.gz" -C "$tmpdir"
  [[ ! -f "$tmpdir/weed" ]] && { echo "weed binary not found in archive."; rm -rf "$tmpdir"; return 1; }
  chmod +x "$tmpdir/weed"
  if [[ "$(id -u)" -eq 0 ]] && [[ -d /usr/local/bin ]]; then
    mv "$tmpdir/weed" /usr/local/bin/weed
    bindir="/usr/local/bin"
  elif command -v sudo &>/dev/null && [[ -d /usr/local/bin ]]; then
    sudo mv "$tmpdir/weed" /usr/local/bin/weed
    bindir="/usr/local/bin"
  else
    mkdir -p ~/.local/bin
    mv "$tmpdir/weed" ~/.local/bin/weed
    bindir="$HOME/.local/bin"
    export PATH="$PATH:$bindir"
    echo "Note: weed installed to $bindir (ensure it is in your PATH)"
  fi
  rm -rf "$tmpdir"
  echo "Installed: $bindir/weed"
  "$bindir/weed" version 2>/dev/null || true
  echo "Starting SeaweedFS (master, volume, filer, S3 on port ${SEAWEEDFS_PORT}, volume.max=${SEAWEEDFS_VOLUME_MAX})..."
  # SeaweedFS S3 validates credentials when provided; use script defaults so mc alias works.
  export AWS_ACCESS_KEY_ID="${OBJECT_STORE_ACCESS_KEY:-minioadmin}"
  export AWS_SECRET_ACCESS_KEY="${OBJECT_STORE_SECRET_KEY:-minioadmin}"
  nohup env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" "$bindir/weed" server -s3 -ip.bind=0.0.0.0 -volume.max="$SEAWEEDFS_VOLUME_MAX" > /tmp/seaweedfs.log 2>&1 &
  echo $! > /tmp/seaweedfs.pid
  local i
  for i in {1..30}; do
    sleep 2
    if seaweedfs_ok; then echo "SeaweedFS is up."; return 0; fi
  done
  echo "Timeout waiting for SeaweedFS. Check /tmp/seaweedfs.log"
  return 1
}

if ! seaweedfs_ok; then
  if [[ "$SEAWEEDFS_SKIP_INSTALL" == "1" ]]; then
    echo "Error: SeaweedFS S3 gateway is not reachable at $OBJECT_STORE_ENDPOINT"
    echo "Set OBJECT_STORE_ENDPOINT or start SeaweedFS manually (weed server -s3)."
    exit 1
  fi
  # Only auto-install when endpoint is local (otherwise we'd start local server while user meant a remote one)
  if [[ "$OBJECT_STORE_ENDPOINT" != *"127.0.0.1"* ]] && [[ "$OBJECT_STORE_ENDPOINT" != *"localhost"* ]]; then
    echo "Error: SeaweedFS is not reachable at $OBJECT_STORE_ENDPOINT"
    echo "For a remote endpoint, start SeaweedFS on that host or set OBJECT_STORE_ENDPOINT=http://127.0.0.1:8333 and run again to install locally."
    exit 1
  fi
  echo "SeaweedFS not reachable at $OBJECT_STORE_ENDPOINT. Attempting to install and start..."
  if ! install_and_start_seaweedfs; then
    echo ""
    echo "Install failed or SeaweedFS did not start. You can:"
    echo "  1. Install manually: https://github.com/seaweedfs/seaweedfs/releases"
    echo "  2. Run: weed server -s3"
    echo "  3. Or set OBJECT_STORE_ENDPOINT=http://<host>:8333 if SeaweedFS runs elsewhere"
    exit 1
  fi
fi
echo "SeaweedFS reachable at $OBJECT_STORE_ENDPOINT"

# ---- Wait for volume server (avoids "Not enough data nodes found" right after restart) ----
if [[ "$SEAWEEDFS_WAIT_VOLUME_SERVER" -gt 0 ]] && command -v weed &>/dev/null; then
  if [[ "$OBJECT_STORE_ENDPOINT" == *"127.0.0.1"* ]] || [[ "$OBJECT_STORE_ENDPOINT" == *"localhost"* ]]; then
    master="${SEAWEEDFS_MASTER}"
    [[ -z "$master" ]] && master="127.0.0.1:9333"
    echo "Waiting up to ${SEAWEEDFS_WAIT_VOLUME_SERVER}s for a volume server in the cluster..."
    waited=0
    while [[ $waited -lt "$SEAWEEDFS_WAIT_VOLUME_SERVER" ]]; do
      out=$(echo -e "cluster.ps\nexit" | weed shell -master="$master" 2>/dev/null) || true
      if echo "$out" | grep -q "volume servers" && echo "$out" | grep -q ":8080"; then
        echo "Volume server is ready."
        break
      fi
      sleep 2
      waited=$((waited + 2))
    done
    if [[ $waited -ge "$SEAWEEDFS_WAIT_VOLUME_SERVER" ]]; then
      echo "Warning: no volume server seen after ${SEAWEEDFS_WAIT_VOLUME_SERVER}s. Upload may fail with 'Not enough data nodes'. Wait longer and re-run, or set SEAWEEDFS_WAIT_VOLUME_SERVER=0 to skip."
    fi
  fi
fi
echo ""

# ---- Install mc if needed (same pattern as upload_to_minio.sh) ----
# sudo on Amazon Linux uses a restricted PATH that excludes /usr/local/bin
export PATH="$PATH:/usr/local/bin"
OS="$(uname -s)"
ARCH="$(uname -m)"
if ! command -v mc &>/dev/null; then
  echo "Installing MinIO Client (mc)..."
  if [[ "$OS" == "Darwin" ]]; then
    if command -v brew &>/dev/null; then
      brew install minio/stable/mc
    else
      if [[ "$ARCH" == "arm64" ]]; then MC_URL="https://dl.min.io/client/mc/release/darwin-arm64/mc"; else MC_URL="https://dl.min.io/client/mc/release/darwin-amd64/mc"; fi
      curl -fsSL -o /tmp/mc "$MC_URL" && chmod +x /tmp/mc && sudo mv /tmp/mc /usr/local/bin/mc
    fi
  elif [[ "$OS" == "Linux" ]]; then
    if [[ "$ARCH" == "x86_64" ]]; then MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"; elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then MC_URL="https://dl.min.io/client/mc/release/linux-arm64/mc"; else echo "Unsupported arch: $ARCH"; exit 1; fi
    curl -fsSL -o /tmp/mc "$MC_URL" && chmod +x /tmp/mc
    sudo mv /tmp/mc /usr/local/bin/mc 2>/dev/null || { mkdir -p ~/.local/bin; mv /tmp/mc ~/.local/bin/mc; export PATH="$PATH:$HOME/.local/bin"; }
  else
    echo "Unsupported OS: $OS"; exit 1
  fi
fi
mc --version
echo ""

# ---- Source dir and count ----
[[ ! -d "$SOURCE_DIR" ]] && { echo "Error: $SOURCE_DIR not found. Run ./download_from_huggingface.sh first."; exit 1; }
artifact_count=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
[[ "$artifact_count" -eq 0 ]] && { echo "No artifacts in $SOURCE_DIR."; exit 1; }
echo "Found $artifact_count artifacts to upload."
echo ""

# ---- Configure mc alias ----
MC_ALIAS="seaweedfs"
mc alias set "$MC_ALIAS" "$OBJECT_STORE_ENDPOINT" "$OBJECT_STORE_ACCESS_KEY" "$OBJECT_STORE_SECRET_KEY" --api S3v4

# ---- Create buckets (from list + primary) ----
for b in $(echo "$SEAWEEDFS_BUCKETS" | tr ',' '\n'); do
  b=$(echo "$b" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  [[ -z "$b" ]] && continue
  mc mb "${MC_ALIAS}/${b}" --ignore-existing 2>/dev/null || true
done
mc mb "${MC_ALIAS}/${OBJECT_STORE_BUCKET}" --ignore-existing 2>/dev/null || true
echo ""

# ---- Upload with retries (single file; large files can trigger "internal error") ----
do_upload_file() {
  local src="$1" dest="$2" attempt=1
  if [[ "$SEAWEEDFS_SKIP_EXISTING" == "1" ]]; then
    mc stat "$dest" &>/dev/null && return 0
  fi
  while [[ $attempt -le "$SEAWEEDFS_UPLOAD_RETRIES" ]]; do
    mc cp "$src" "$dest" && return 0
    echo "Attempt $attempt/$SEAWEEDFS_UPLOAD_RETRIES failed. Retrying in ${SEAWEEDFS_UPLOAD_RETRY_DELAY}s..."
    attempt=$((attempt + 1))
    [[ $attempt -le "$SEAWEEDFS_UPLOAD_RETRIES" ]] && sleep "$SEAWEEDFS_UPLOAD_RETRY_DELAY"
  done
  return 1
}

# Upload a directory artifact file-by-file (per-file retries; one failed file doesn't re-upload the rest).
upload_artifact_dir() {
  local artifact_path="$1" dest_base="$2" id="$3" failed=0 f rel
  while IFS= read -r -d '' f; do
    rel="${f#${artifact_path}/}"
    if ! do_upload_file "$f" "${dest_base}/${rel}"; then
      echo "$(date -Iseconds 2>/dev/null || date) FAILED: $id $rel" >> "$SEAWEEDFS_ERROR_LOG"
      failed=1
    fi
  done < <(find "$artifact_path" -type f -print0)
  return $failed
}

# Clear error log from previous runs
: > "$SEAWEEDFS_ERROR_LOG"

# Build list of artifacts for parallel upload
artifact_paths=()
for artifact_path in "$SOURCE_DIR"/*; do
  [[ -e "$artifact_path" ]] || continue
  artifact_paths+=("$artifact_path")
done

parallel_jobs="$SEAWEEDFS_PARALLEL_JOBS"
[[ "$parallel_jobs" -lt 1 ]] && parallel_jobs=1
idx=0
total=${#artifact_paths[@]}
echo "Uploading $total artifacts (per-file) with up to $parallel_jobs parallel job(s). Errors logged to: $SEAWEEDFS_ERROR_LOG"
[[ "$SEAWEEDFS_SKIP_EXISTING" == "1" ]] && echo "Skip-existing is ON: files already present at destination will be skipped."
echo ""

while [[ $idx -lt $total ]]; do
  batch=0
  while [[ $batch -lt $parallel_jobs && $idx -lt $total ]]; do
    artifact_path="${artifact_paths[$idx]}"
    id=$(basename "$artifact_path")
    dest_base="${MC_ALIAS}/${OBJECT_STORE_BUCKET}/model_artifacts/$id"
    (
      if [[ -d "$artifact_path" ]]; then
        upload_artifact_dir "$artifact_path" "$dest_base" "$id" || exit 1
      else
        do_upload_file "$artifact_path" "$dest_base" || { echo "$(date -Iseconds 2>/dev/null || date) FAILED: $id" >> "$SEAWEEDFS_ERROR_LOG"; exit 1; }
      fi
      echo "Completed: $id"
    ) &
    batch=$((batch + 1))
    idx=$((idx + 1))
  done
  wait || true
done

if [[ -s "$SEAWEEDFS_ERROR_LOG" ]]; then
  echo ""
  echo "One or more artifacts failed. See $SEAWEEDFS_ERROR_LOG:"
  cat "$SEAWEEDFS_ERROR_LOG"
  exit 1
fi
echo "Upload complete. Uploaded $artifact_count artifacts to ${OBJECT_STORE_ENDPOINT}/${OBJECT_STORE_BUCKET}/model_artifacts/"