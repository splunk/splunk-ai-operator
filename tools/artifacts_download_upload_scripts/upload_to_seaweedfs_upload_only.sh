#!/bin/bash
# Upload model artifacts to an ALREADY-RUNNING SeaweedFS (S3-compatible) endpoint.
# Unlike upload_to_seaweedfs.sh, this script does NOT install or start the SeaweedFS
# (weed) server — it assumes SeaweedFS is already up at OBJECT_STORE_ENDPOINT and fails
# fast if it is not reachable. Creates configured buckets and uploads from ./model_artifacts.
# Use OBJECT_STORE_* or SEAWEEDFS_* env vars.

set -e

SOURCE_DIR="./model_artifacts"

# Endpoint and credentials (prefer generic OBJECT_STORE_*, then SEAWEEDFS_*).
# SeaweedFS S3 has no built-in users: if the server is started with credentials (env or -config),
# they must match these values.
OBJECT_STORE_ENDPOINT="${OBJECT_STORE_ENDPOINT:-${SEAWEEDFS_ENDPOINT:-http://127.0.0.1:8333}}"
OBJECT_STORE_BUCKET="${OBJECT_STORE_BUCKET:-${SEAWEEDFS_BUCKET:-ai-platform-bucket}}"
OBJECT_STORE_ACCESS_KEY="${OBJECT_STORE_ACCESS_KEY:-${SEAWEEDFS_ACCESS_KEY:-minioadmin}}"
OBJECT_STORE_SECRET_KEY="${OBJECT_STORE_SECRET_KEY:-${SEAWEEDFS_SECRET_KEY:-minioadmin}}"
# Bucket list to create (comma-separated). If unset, only primary bucket is created.
SEAWEEDFS_BUCKETS="${SEAWEEDFS_BUCKETS:-$OBJECT_STORE_BUCKET}"
# Retries for each artifact upload (large files can trigger transient "internal error").
SEAWEEDFS_UPLOAD_RETRIES="${SEAWEEDFS_UPLOAD_RETRIES:-3}"
SEAWEEDFS_UPLOAD_RETRY_DELAY="${SEAWEEDFS_UPLOAD_RETRY_DELAY:-15}"
# Max concurrent uploads (1 = sequential).
SEAWEEDFS_PARALLEL_JOBS="${SEAWEEDFS_PARALLEL_JOBS:-1}"
# Path to log failed artifact ids and messages (appended to on failure).
SEAWEEDFS_ERROR_LOG="${SEAWEEDFS_ERROR_LOG:-./seaweedfs_upload_errors.log}"
# Set to 1 to skip uploading a file if it already exists at destination (avoids re-uploading on script re-runs).
SEAWEEDFS_SKIP_EXISTING="${SEAWEEDFS_SKIP_EXISTING:-0}"
# Set to 1 to skip artifacts whose .staging_complete marker already exists in SeaweedFS.
SKIP_IF_STAGED="${SKIP_IF_STAGED:-0}"

# Normalize primary bucket to lowercase
OBJECT_STORE_BUCKET=$(echo "$OBJECT_STORE_BUCKET" | tr '[:upper:]' '[:lower:]')

# ---- Check SeaweedFS is reachable ----
seaweedfs_ok() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "${OBJECT_STORE_ENDPOINT}" 2>/dev/null || echo "000")
  [[ "$code" == "200" || "$code" == "403" || "$code" == "400" ]] && return 0
  return 1
}

if ! seaweedfs_ok; then
  echo "Error: SeaweedFS S3 gateway is not reachable at $OBJECT_STORE_ENDPOINT"
  echo ""
  echo "This script does not install or start SeaweedFS. Make sure it is already running, then re-run."
  echo "  1. Start SeaweedFS manually:  weed server -s3"
  echo "  2. Or install it as a service: ./install_seaweedfs_systemd.sh"
  echo "  3. Or point at a remote endpoint: OBJECT_STORE_ENDPOINT=http://<host>:8333 ./$(basename "$0")"
  echo "  4. To auto-install/start a local SeaweedFS instead, use ./upload_to_seaweedfs.sh"
  exit 1
fi
echo "SeaweedFS reachable at $OBJECT_STORE_ENDPOINT"
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
      curl -fsSL -o /tmp/mc "$MC_URL" || { echo "Error: Failed to download mc from $MC_URL"; exit 1; }
      chmod +x /tmp/mc && sudo mv /tmp/mc /usr/local/bin/mc
    fi
  elif [[ "$OS" == "Linux" ]]; then
    if [[ "$ARCH" == "x86_64" ]]; then MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"; elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then MC_URL="https://dl.min.io/client/mc/release/linux-arm64/mc"; else echo "Unsupported arch: $ARCH"; exit 1; fi
    curl -fsSL -o /tmp/mc "$MC_URL" || { echo "Error: Failed to download mc from $MC_URL"; exit 1; }
    chmod +x /tmp/mc
    sudo mv /tmp/mc /usr/local/bin/mc 2>/dev/null || { mkdir -p ~/.local/bin; mv /tmp/mc ~/.local/bin/mc; export PATH="$PATH:$HOME/.local/bin"; }
  else
    echo "Unsupported OS: $OS"; exit 1
  fi
fi
mc --version
echo ""

# ---- Source dir and count ----
[[ ! -d "$SOURCE_DIR" ]] && { echo "Error: $SOURCE_DIR not found. Run ./download_from_huggingface.sh first."; exit 1; }
artifact_count=$(find -L "$SOURCE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
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
# .staging_complete is excluded from the main loop and uploaded last so its presence proves completeness.
upload_artifact_dir() {
  local artifact_path="$1" dest_base="$2" id="$3" failed=0 f rel
  local marker_local="${artifact_path}/.staging_complete"
  # Marker lives in staging_state/ — separate from model_artifacts/ —
  # so model loaders never encounter it at inference time.
  local marker_dest="${MC_ALIAS}/${OBJECT_STORE_BUCKET}/staging_state/${id}/.staging_complete"
  while IFS= read -r -d '' f; do
    rel="${f#${artifact_path}/}"
    # Skip local marker — not uploaded into model_artifacts/
    [[ "$rel" == ".staging_complete" ]] && continue
    if ! do_upload_file "$f" "${dest_base}/${rel}"; then
      echo "$(date -Iseconds 2>/dev/null || date) FAILED: $id $rel" >> "$SEAWEEDFS_ERROR_LOG"
      failed=1
    fi
  done < <(find "$artifact_path" -type f -print0)
  # Upload marker to staging_state/ last — its presence proves upload is complete
  if [[ $failed -eq 0 && -f "$marker_local" ]]; then
    if ! do_upload_file "$marker_local" "$marker_dest"; then
      echo "$(date -Iseconds 2>/dev/null || date) FAILED: $id .staging_complete" >> "$SEAWEEDFS_ERROR_LOG"
      failed=1
    fi
  fi
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

    # Skip entirely if already fully staged with matching hf_url.
    # Presence-only check is not enough: a marker from a prior run may lack
    # hf_url= or have a stale URL; in that case we must re-upload so the
    # verification step finds a current marker.
    if [[ "$SKIP_IF_STAGED" == "1" ]]; then
      local_hf_url=$(grep "^hf_url=" "${artifact_path}/.staging_complete" 2>/dev/null | cut -d= -f2-)
      remote_hf_url=$(mc cat "${MC_ALIAS}/${OBJECT_STORE_BUCKET}/staging_state/${id}/.staging_complete" 2>/dev/null | grep "^hf_url=" | cut -d= -f2-)
      if [[ -n "$local_hf_url" && "$local_hf_url" == "$remote_hf_url" ]]; then
        echo "✓ $id already staged (hf_url matches) — skipping."
        idx=$((idx + 1))
        continue
      fi
    fi

    (
      if [[ -d "$artifact_path" ]]; then
        # Remove stale remote files when hf_url changed — SeaweedFS has no native
        # sync-with-delete, so explicitly wipe the remote dir before re-uploading.
        if [[ -n "$remote_hf_url" && "$remote_hf_url" != "$local_hf_url" ]]; then
          echo "↻ $id: hf_url changed — removing stale remote files before re-upload."
          mc rm --recursive --force "${MC_ALIAS}/${OBJECT_STORE_BUCKET}/model_artifacts/${id}/" 2>/dev/null || true
        fi
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
