#!/bin/bash
# Script to download model artifacts from Hugging Face

# Exit on pipeline errors; intentionally NOT set -e so we can collect per-model
# failures and resume on re-runs rather than aborting on the first error.
set -o pipefail

# ---------- Accelerator / config-file selection ----------
# Precedence: --accelerator/-a flag > ACCELERATOR env var > interactive prompt.
# Passing ACCELERATOR=<type> is also how k0s_cluster_with_stack.sh forwards
# the aiPlatform.defaultAcceleratorType value from the cluster config.

usage() {
  cat <<EOF
Usage: $(basename "$0") [--accelerator <type>] [--skip-if-staged] [--help]

Options:
  -a, --accelerator <type>  GPU accelerator type for which to download models.
                            Supported: l40s (default), h100, rtx_pro_6000_blackwell
  --skip-if-staged          Check the configured object store first; skip
                            downloading (and uploading) any artifact that is
                            already fully staged there.
  -h, --help                Show this help message

Environment:
  ACCELERATOR           Fallback when --accelerator is not given (used by the k0s installer).
  SKIP_IF_EXISTS        Set to 1 to skip models that have a local completion marker.
  SKIP_IF_STAGED        Set to 1 to enable the object-store pre-check (same as --skip-if-staged).
  HF_DOWNLOAD_RETRIES   Number of retry attempts per model on failure (default: 2).

  Object store pre-check (used when SKIP_IF_STAGED=1):
    OBJ_STORE_TYPE          aws | minio | seaweedfs  (default: minio)
    OBJ_STORE_BUCKET        Bucket name              (default: ai-platform-data)
    OBJ_STORE_ENDPOINT      MinIO/SeaweedFS API URL  (not required for AWS)
    OBJ_STORE_ACCESS_KEY    Access key / AWS_ACCESS_KEY_ID
    OBJ_STORE_SECRET_KEY    Secret key / AWS_SECRET_ACCESS_KEY
    S3_REGION               AWS region               (default: us-east-2, AWS only)
    S3_PREFIX               Key prefix inside bucket (default: model_artifacts, AWS only)

Resume behaviour:
  - A model with a local .staging_complete marker is considered fully downloaded
    and is skipped on re-runs (SKIP_IF_EXISTS=1 also checks this).
  - A model directory WITHOUT the marker is treated as a partial/failed download
    and is automatically removed so the re-run starts it clean.
  - With SKIP_IF_STAGED=1, a model whose store marker exists is skipped entirely
    (no download and no upload needed).
EOF
}

ACCEL_FLAG=""
SKIP_IF_STAGED="${SKIP_IF_STAGED:-0}"
SKIP_IF_EXISTS="${SKIP_IF_EXISTS:-0}"
HF_DOWNLOAD_RETRIES="${HF_DOWNLOAD_RETRIES:-2}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--accelerator) ACCEL_FLAG="${2:-}"; shift 2 ;;
    --skip-if-staged) SKIP_IF_STAGED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Resolve: CLI flag > env var > interactive prompt
if [[ -z "$ACCEL_FLAG" && -z "$ACCELERATOR" ]]; then
  echo "Select GPU type:"
  echo "  1) l40s"
  echo "  2) h100"
  echo "  3) rtx_pro_6000_blackwell"
  read -rp "Enter 1, 2, or 3: " GPU_CHOICE
  case "$GPU_CHOICE" in
    1) ACCEL_FLAG="l40s" ;;
    2) ACCEL_FLAG="h100" ;;
    3) ACCEL_FLAG="rtx_pro_6000_blackwell" ;;
    *) echo "Error: invalid choice '${GPU_CHOICE}'. Please enter 1, 2, or 3." >&2; exit 1 ;;
  esac
fi

ACCEL="$(printf '%s' "${ACCEL_FLAG:-${ACCELERATOR}}" | tr '[:upper:]' '[:lower:]')"

# RTX PRO 6000 Blackwell uses the default (l40s) config: it needs the quantized
# gemma-4-31b-it-qat-w4a16-ct artifact, which only exists in that config. The h100
# config ships the full-precision gemma-4-31b-it instead.
case "${ACCEL}" in
  l40s|""|rtx_pro_6000_blackwell) CONFIG_FILE="./model_artifacts_configs.yaml" ;;
  h100)                           CONFIG_FILE="./model_artifacts_configs_h100.yaml" ;;
  *)
    echo "Error: unsupported accelerator '${ACCEL}'. Supported values: l40s, h100, rtx_pro_6000_blackwell" >&2
    exit 1
    ;;
esac

echo "Accelerator: ${ACCEL} → config: ${CONFIG_FILE}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Error: config file '${CONFIG_FILE}' not found in $(pwd)" >&2
  exit 1
fi

DOWNLOAD_DIR="./model_artifacts"
mkdir -p "$DOWNLOAD_DIR"

# ---------- Install dependencies ----------

if ! command -v wget &> /dev/null; then
    echo "wget not found, installing..."
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command -v brew &> /dev/null; then
            brew install wget
        else
            echo "Error: Homebrew not found. Please install wget manually or install Homebrew first."
            exit 1
        fi
    else
        if [ "$(id -u)" -eq 0 ]; then
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y wget
            elif command -v yum &> /dev/null; then
                yum install -y wget
            elif command -v dnf &> /dev/null; then
                dnf install -y wget
            else
                echo "Error: No supported package manager found. Please install wget manually."
                exit 1
            fi
        elif command -v sudo &> /dev/null; then
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y wget
            elif command -v yum &> /dev/null; then
                sudo yum install -y wget
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y wget
            else
                echo "Error: No supported package manager found. Please install wget manually."
                exit 1
            fi
        else
            echo "Error: Root privileges are required to install wget. Please run this script as root or install wget manually."
            exit 1
        fi
    fi
fi

# Find the correct yq
YQ_CMD=""
if command -v brew &> /dev/null && [[ -f "$(brew --prefix yq 2>/dev/null)/bin/yq" ]]; then
    YQ_CMD="$(brew --prefix yq)/bin/yq"
    echo "Using Homebrew yq: $YQ_CMD"
elif command -v yq &> /dev/null && yq --version 2>&1 | grep -q "mikefarah"; then
    YQ_CMD="yq"
else
    echo "yq (mikefarah's version) not found, installing..."
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    case "$OS" in
        Linux*)
            if [[ "$ARCH" == "x86_64" ]]; then
                YQ_BINARY="yq_linux_amd64"
            elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
                YQ_BINARY="yq_linux_arm64"
            else
                echo "Unsupported architecture: $ARCH"
                exit 1
            fi
            ;;
        Darwin*)
            if [[ "$ARCH" == "x86_64" ]]; then
                YQ_BINARY="yq_darwin_amd64"
            elif [[ "$ARCH" == "arm64" ]]; then
                YQ_BINARY="yq_darwin_arm64"
            else
                echo "Unsupported architecture: $ARCH"
                exit 1
            fi
            ;;
        *)
            echo "Unsupported OS: $OS"
            exit 1
            ;;
    esac

    if [[ $EUID -eq 0 ]]; then
        wget "https://github.com/mikefarah/yq/releases/download/v4.44.1/$YQ_BINARY" -O /usr/local/bin/yq
        chmod +x /usr/local/bin/yq
        YQ_CMD="/usr/local/bin/yq"
    elif command -v sudo &> /dev/null && [[ "$OS" == "Darwin" ]]; then
        wget "https://github.com/mikefarah/yq/releases/download/v4.44.1/$YQ_BINARY" -O /tmp/yq
        chmod +x /tmp/yq
        sudo mv /tmp/yq /usr/local/bin/yq
        YQ_CMD="/usr/local/bin/yq"
    else
        mkdir -p ~/.local/bin
        wget "https://github.com/mikefarah/yq/releases/download/v4.44.1/$YQ_BINARY" -O ~/.local/bin/yq
        chmod +x ~/.local/bin/yq
        export PATH=$PATH:~/.local/bin
        YQ_CMD="$HOME/.local/bin/yq"
        echo "Note: yq installed to ~/.local/bin - ensure this is in your PATH"
    fi
fi

# HF_TOKEN and HF_USERNAME are set in the model_artifacts_configs.yaml file
HF_TOKEN=$("$YQ_CMD" -r '.hf-token' "$CONFIG_FILE")
HF_USERNAME=$("$YQ_CMD" -r '.hf-username' "$CONFIG_FILE")

# SECURITY: Redact credentials in logs to prevent exposure
if [[ "$HF_TOKEN" != "null" && -n "$HF_TOKEN" ]]; then
    echo "HF_TOKEN: ${HF_TOKEN:0:3}...${HF_TOKEN: -4}"
else
    echo "HF_TOKEN: not set"
fi
if [[ "$HF_USERNAME" != "null" && -n "$HF_USERNAME" ]]; then
    echo "HF_USERNAME: $HF_USERNAME"
else
    echo "HF_USERNAME: not set"
fi

if ! command -v git-lfs &> /dev/null; then
    echo "git-lfs not found, installing..."
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if command -v brew &> /dev/null; then
            brew install git-lfs
        else
            echo "Error: Homebrew not found. Please install git-lfs manually or install Homebrew first."
            exit 1
        fi
    else
        if [ "$(id -u)" -eq 0 ]; then
            if command -v apt-get &> /dev/null; then
                apt-get update && apt-get install -y git-lfs
            elif command -v yum &> /dev/null; then
                yum install -y git-lfs
            elif command -v dnf &> /dev/null; then
                dnf install -y git-lfs
            else
                echo "Error: No supported package manager found. Please install git-lfs manually."
                exit 1
            fi
        elif command -v sudo &> /dev/null; then
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y git-lfs
            elif command -v yum &> /dev/null; then
                sudo yum install -y git-lfs
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y git-lfs
            else
                echo "Error: No supported package manager found. Please install git-lfs manually."
                exit 1
            fi
        else
            echo "Error: This script requires root privileges to install git-lfs. Please run as root or install git-lfs manually."
            exit 1
        fi
    fi
    if ! git lfs install; then
        echo "ERROR: Failed to initialize git-lfs"
        exit 1
    fi
fi

if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 is required but not found"
    echo "Python 3 is needed to securely encode credentials for gated model downloads"
    echo ""
    echo "Installation instructions:"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "  macOS: brew install python3"
        echo "  or download from: https://www.python.org/downloads/"
    else
        echo "  Ubuntu/Debian: sudo apt-get install python3"
        echo "  RHEL/CentOS: sudo yum install python3"
        echo "  Fedora: sudo dnf install python3"
    fi
    exit 1
fi

# ---------- Object-store pre-check helpers ----------

# Lazily configure mc alias once for minio/seaweedfs store checks.
_MC_ALIAS="staging_precheck"
_MC_ALIAS_READY=0
_MC_ALIAS_WARN_DONE=0
_setup_mc_alias() {
    if [[ "$_MC_ALIAS_READY" == "1" ]]; then return 0; fi
    if ! command -v mc &>/dev/null; then
        if [[ "$_MC_ALIAS_WARN_DONE" == "0" ]]; then
            echo "WARNING: mc not found — object-store pre-check unavailable; will download from HuggingFace." >&2
            _MC_ALIAS_WARN_DONE=1
        fi
        return 1
    fi
    local endpoint="${OBJ_STORE_ENDPOINT:-}"
    local access_key="${OBJ_STORE_ACCESS_KEY:-}"
    local secret_key="${OBJ_STORE_SECRET_KEY:-}"
    if [[ -z "$endpoint" || -z "$access_key" || -z "$secret_key" ]]; then
        if [[ "$_MC_ALIAS_WARN_DONE" == "0" ]]; then
            echo "WARNING: OBJ_STORE_ENDPOINT / OBJ_STORE_ACCESS_KEY / OBJ_STORE_SECRET_KEY not set — object-store pre-check unavailable; will download from HuggingFace." >&2
            _MC_ALIAS_WARN_DONE=1
        fi
        return 1
    fi
    mc alias set "$_MC_ALIAS" "$endpoint" "$access_key" "$secret_key" --api S3v4 &>/dev/null || {
        if [[ "$_MC_ALIAS_WARN_DONE" == "0" ]]; then
            echo "WARNING: Could not configure mc alias for pre-check — will download from HuggingFace." >&2
            _MC_ALIAS_WARN_DONE=1
        fi
        return 1
    }
    _MC_ALIAS_READY=1
}

_AWS_WARN_DONE=0
# remote_model_staged <artifact-id> <hf_url>
# Returns 0 if the .staging_complete marker exists in the object store AND its
# hf_url= field matches the current config URL, 1 otherwise.
# Fails open (returns 1) on any configuration or tool error so staging always proceeds.
remote_model_staged() {
    local id="$1"
    local hf_url="$2"
    local store_type="${OBJ_STORE_TYPE:-minio}"
    local bucket="${OBJ_STORE_BUCKET:-ai-platform-data}"
    local marker_path="staging_state/${id}/.staging_complete"

    local _marker_content
    case "$store_type" in
        aws)
            local access_key="${OBJ_STORE_ACCESS_KEY:-}"
            local secret_key="${OBJ_STORE_SECRET_KEY:-}"
            local region="${S3_REGION:-us-east-2}"
            if ! command -v aws &>/dev/null; then
                if [[ "$_AWS_WARN_DONE" == "0" ]]; then
                    echo "WARNING: aws CLI not found — object-store pre-check unavailable; will download from HuggingFace." >&2
                    _AWS_WARN_DONE=1
                fi
                return 1
            fi
            if [[ -z "$access_key" || -z "$secret_key" ]]; then
                if [[ "$_AWS_WARN_DONE" == "0" ]]; then
                    echo "WARNING: OBJ_STORE_ACCESS_KEY / OBJ_STORE_SECRET_KEY not set — skipping AWS pre-check; will download from HuggingFace." >&2
                    _AWS_WARN_DONE=1
                fi
                return 1
            fi
            _marker_content=$(AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key" \
                aws s3 cp "s3://${bucket}/${marker_path}" - --region "$region" 2>/dev/null) || return 1
            ;;
        minio|seaweedfs)
            _setup_mc_alias || return 1
            _marker_content=$(mc cat "${_MC_ALIAS}/${bucket}/${marker_path}" 2>/dev/null) || return 1
            ;;
        *)
            echo "WARNING: Unknown OBJ_STORE_TYPE '${store_type}' — skipping pre-check for ${id}; will download from HuggingFace." >&2
            return 1
            ;;
    esac
    # Validate that the marker was written for the same HF URL.
    # If the URL changed (model updated in config), the staged artifact is stale
    # and must be re-downloaded regardless of GPU type.
    echo "${_marker_content}" | grep -q "^hf_url=${hf_url}$"
}

# ---------- Per-model download with retry and cleanup ----------

# download_one_model <id> <hf_url> <is_gated> <files_to_exclude>
# Clones and pulls LFS files; retries up to HF_DOWNLOAD_RETRIES times on failure.
# On any failure: deletes the partial folder so the next attempt or re-run is clean.
# On success: writes model_artifacts/<id>/.staging_complete marker.
download_one_model() {
    local id="$1"
    local hf_url="$2"
    local is_gated="$3"
    local files_to_exclude="$4"
    local dest="$DOWNLOAD_DIR/$id"
    local attempt=1
    local max_attempts=$(( HF_DOWNLOAD_RETRIES + 1 ))

    while [[ $attempt -le $max_attempts ]]; do
        if [[ $attempt -gt 1 ]]; then
            echo "Retry $((attempt - 1))/$HF_DOWNLOAD_RETRIES for $id (waiting 15s)..."
            sleep 15
        fi

        rm -rf "$dest"
        export GIT_LFS_SKIP_SMUDGE=1

        # ---- Clone ----
        if [[ "$is_gated" == "true" ]]; then
            if [[ "$HF_TOKEN" == "null" || -z "$HF_TOKEN" ]] || [[ "$HF_USERNAME" == "null" || -z "$HF_USERNAME" ]]; then
                echo "ERROR: Cannot download gated model $id — HF_TOKEN and HF_USERNAME are required in $CONFIG_FILE"
                unset GIT_LFS_SKIP_SMUDGE
                return 1
            fi
            local HF_USERNAME_ENC
            HF_USERNAME_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$HF_USERNAME'''))")
            # SECURITY: auth_hf_url contains credentials — NEVER log or echo this variable
            local auth_hf_url
            auth_hf_url=$(echo "$hf_url" | sed "s#https://#https://$HF_USERNAME_ENC:$HF_TOKEN@#")
            echo "Cloning gated model $hf_url for $id (memory-optimized)"
            if ! git clone --depth 1 --single-branch "$auth_hf_url" "$dest"; then
                echo "ERROR: Failed to clone gated model from $hf_url for artifact $id"
                echo "  Possible causes: invalid/expired HF_TOKEN, no model access, network issue, bad URL"
                unset GIT_LFS_SKIP_SMUDGE
                rm -rf "$dest"
                attempt=$(( attempt + 1 ))
                continue
            fi
        else
            echo "Cloning $hf_url for $id (memory-optimized)"
            if ! git clone --depth 1 --single-branch "$hf_url" "$dest"; then
                echo "ERROR: Failed to clone from $hf_url for artifact $id"
                echo "  Possible causes: network issue, bad URL, repository not found or private"
                unset GIT_LFS_SKIP_SMUDGE
                rm -rf "$dest"
                attempt=$(( attempt + 1 ))
                continue
            fi
        fi

        # ---- Pull LFS files (SHA256-verified by git-lfs against HuggingFace oids) ----
        local lfs_rc=0
        (
            cd "$dest" || exit 1
            if [ -f .gitattributes ] && grep -q "filter=lfs" .gitattributes; then
                echo "Downloading LFS files for $id..."
                if [[ -n "$files_to_exclude" ]]; then
                    local lfs_exclude_arg
                    lfs_exclude_arg=$(echo "$files_to_exclude" | tr '\n' ',' | sed 's/,$//')
                    echo "Excluding from LFS download: $lfs_exclude_arg"
                    git lfs pull --exclude="$lfs_exclude_arg"
                else
                    git lfs pull
                fi
            fi
        )
        lfs_rc=$?
        unset GIT_LFS_SKIP_SMUDGE

        if [[ $lfs_rc -ne 0 ]]; then
            echo "ERROR: LFS download failed for $id (exit $lfs_rc) — removing partial folder for clean retry."
            rm -rf "$dest"
            attempt=$(( attempt + 1 ))
            continue
        fi

        # ---- Post-processing (only reached on clone + LFS success) ----

        # Remove git metadata
        find "$dest" -type f \( -name ".gitattributes" -o -name ".gitignore" -o -name ".gitmodules" \) -exec rm -f {} +
        rm -rf "$dest/.git"

        # Apply files-to-exclude
        if [[ -n "$files_to_exclude" ]]; then
            shopt -s nullglob
            while IFS= read -r exclude_file; do
                if [[ "$exclude_file" == */ ]]; then
                    rm -rf "$dest/$exclude_file"
                    echo "Excluded folder $exclude_file"
                elif [[ "$exclude_file" == *"*"* || "$exclude_file" == *"?"* ]]; then
                    for match in "$dest"/$exclude_file; do
                        [ -e "$match" ] && { rm -f "$match"; echo "Excluded $match"; }
                    done
                else
                    rm -f "$dest/$exclude_file"
                    echo "Excluded $exclude_file"
                fi
            done <<< "$files_to_exclude"
            shopt -u nullglob
        fi

        # Write local completion marker (written last — its presence means fully done & verified)
        local file_count
        file_count=$(find "$dest" -type f | wc -l | tr -d ' ')
        printf 'staged=%s\naccel=%s\nhf_url=%s\nfiles=%s\n' \
            "$(date -Iseconds 2>/dev/null || date)" "$ACCEL" "$hf_url" "$file_count" \
            > "$dest/.staging_complete"

        ls -lR "$dest"
        echo "Successfully downloaded $id to $dest"
        return 0
    done

    echo "ERROR: All $HF_DOWNLOAD_RETRIES retry attempt(s) for $id failed. Folder removed — re-run this script to retry."
    rm -rf "$dest"
    return 1
}

# ---------- Main download loop ----------

if [ ! -f "$CONFIG_FILE" ]; then
    echo "$CONFIG_FILE not found!"
    exit 1
fi

echo "Reading $CONFIG_FILE"

artifact_count=$("$YQ_CMD" '.artifact-configs | length' "$CONFIG_FILE" 2>/dev/null) || {
    echo "ERROR: yq failed to parse '$CONFIG_FILE' — check that yq is installed and the file is valid YAML." >&2
    exit 1
}
if [[ -z "$artifact_count" || "$artifact_count" == "null" || "$artifact_count" -eq 0 ]]; then
    echo "ERROR: No artifacts found in '$CONFIG_FILE' (artifact-configs list is empty or missing)." >&2
    exit 1
fi
echo "Found $artifact_count artifacts to process"
echo ""

failed_ids=()

for ((idx=0; idx<artifact_count; idx++)); do
    id=$("$YQ_CMD" -r ".artifact-configs[$idx].artifact-id" "$CONFIG_FILE")
    hf_url=$("$YQ_CMD" -r ".artifact-configs[$idx].hf-url" "$CONFIG_FILE")
    files_to_exclude=$("$YQ_CMD" -r ".artifact-configs[$idx].files-to-exclude[]?" "$CONFIG_FILE")
    is_a_gated_model=$("$YQ_CMD" -r ".artifact-configs[$idx].is-a-gated-model" "$CONFIG_FILE")

    echo "Processing artifact ID: $id"
    echo "hf-url: $hf_url"
    echo "files-to-exclude: $files_to_exclude"
    echo "is-a-gated-model: $is_a_gated_model"

    if [[ -z "$hf_url" || "$hf_url" == "null" ]]; then
        echo "hf-url not set for $id, skipping."
        echo "-----------------------------"
        continue
    fi

    # 1. Object-store pre-check — skip download AND upload if fully staged remotely
    #    with the same HF URL (URL change means the model was updated in config).
    if [[ "$SKIP_IF_STAGED" == "1" ]] && remote_model_staged "$id" "$hf_url"; then
        echo "✓ $id already fully staged in object store (hf_url matches) — skipping download and upload."
        echo "-----------------------------"
        continue
    fi

    # 2. Local completion marker — skip re-download if marker exists and URL matches.
    if [[ "$SKIP_IF_EXISTS" == "1" || "$SKIP_IF_STAGED" == "1" ]] && [[ -f "$DOWNLOAD_DIR/$id/.staging_complete" ]]; then
        local_url=$(grep "^hf_url=" "$DOWNLOAD_DIR/$id/.staging_complete" 2>/dev/null | cut -d= -f2-)
        if [[ "$local_url" == "$hf_url" ]]; then
            echo "✓ $id already downloaded locally (hf_url matches) — skipping download."
            echo "-----------------------------"
            continue
        else
            echo "↻ $id local marker exists but hf_url changed (was: ${local_url:-unknown}, now: $hf_url) — re-downloading."
        fi
    fi

    # 3. Partial/stale folder without marker — wipe and start clean
    if [[ -d "$DOWNLOAD_DIR/$id" ]]; then
        echo "Incomplete folder found for $id (no .staging_complete marker) — removing for clean download..."
        rm -rf "$DOWNLOAD_DIR/$id"
    fi

    # Download with retry and automatic cleanup on failure
    if ! download_one_model "$id" "$hf_url" "$is_a_gated_model" "$files_to_exclude"; then
        failed_ids+=("$id")
    fi

    echo "-----------------------------"
done

echo ""
if [[ ${#failed_ids[@]} -gt 0 ]]; then
    echo "ERROR: The following artifact(s) failed to download after $HF_DOWNLOAD_RETRIES retries: ${failed_ids[*]}"
    echo "Their folders have been removed. Re-run this script to resume — completed models will be skipped automatically."
    exit 1
fi

echo "Download complete! Artifacts are located in: $DOWNLOAD_DIR"
echo "To upload to MinIO, run: ./upload_to_minio.sh"
