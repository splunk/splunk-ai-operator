#!/bin/bash
# Script to download model artifacts from Hugging Face

# Exit on error
set -e
set -o pipefail

CONFIG_FILE="./model_artifacts_configs.yaml"
DOWNLOAD_DIR="./model_artifacts"

# Ensure download directory exists
mkdir -p "$DOWNLOAD_DIR"

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
        # Linux - detect package manager
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
    
    # Try to install to /usr/local/bin, fallback to ~/.local/bin if no sudo
    if [[ $EUID -eq 0 ]]; then
        wget "https://github.com/mikefarah/yq/releases/download/v4.44.1/$YQ_BINARY" -O /usr/local/bin/yq
        chmod +x /usr/local/bin/yq
        YQ_CMD="/usr/local/bin/yq"
    elif command -v sudo &> /dev/null && [[ "$OS" == "Darwin" ]]; then
        # On macOS, try sudo
        wget "https://github.com/mikefarah/yq/releases/download/v4.44.1/$YQ_BINARY" -O /tmp/yq
        chmod +x /tmp/yq
        sudo mv /tmp/yq /usr/local/bin/yq
        YQ_CMD="/usr/local/bin/yq"
    else
        # Install to user directory (Linux without sudo or failed sudo)
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
    # Show only last 4 characters of token for verification
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
        # Linux - detect package manager
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

# Check for Python 3 (required for URL encoding gated model credentials)
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

if [ -f "$CONFIG_FILE" ]; then
    echo "Reading $CONFIG_FILE"
    
    # Get total count of artifacts
    artifact_count=$("$YQ_CMD" '.artifact-configs | length' "$CONFIG_FILE")
    echo "Found $artifact_count artifacts to download"
    echo ""
    
    # Process all artifacts in the config
    for ((idx=0; idx<artifact_count; idx++)); do
        id=$("$YQ_CMD" -r ".artifact-configs[$idx].artifact-id" "$CONFIG_FILE")
        echo "Processing artifact ID: $id"
        
        # Get artifact configuration
        hf_url=$("$YQ_CMD" -r ".artifact-configs[$idx].hf-url" "$CONFIG_FILE")
        files_to_exclude=$("$YQ_CMD" -r ".artifact-configs[$idx].files-to-exclude[]?" "$CONFIG_FILE")
        is_a_gated_model=$("$YQ_CMD" -r ".artifact-configs[$idx].is-a-gated-model" "$CONFIG_FILE")
        
        echo "hf-url: $hf_url"
        echo "files-to-exclude: $files_to_exclude"
        echo "is-a-gated-model: $is_a_gated_model"
        
        if [[ -n "$hf_url" && "$hf_url" != "null" ]]; then
            # Remove existing directory if it exists to force re-download
            if [ -d "$DOWNLOAD_DIR/$id" ]; then
                echo "Model $id already exists at $DOWNLOAD_DIR/$id, removing for fresh download..."
                rm -rf "$DOWNLOAD_DIR/$id"
            fi
            
            # Clone from Hugging Face with optimizations for large repos
            # Use GIT_LFS_SKIP_SMUDGE to avoid downloading LFS files during clone
            # Then download them with git lfs pull which is more memory efficient
            export GIT_LFS_SKIP_SMUDGE=1
            
            if [[ "$is_a_gated_model" == "true" ]]; then
                # Validate credentials for gated model
                if [[ "$HF_TOKEN" == "null" || -z "$HF_TOKEN" ]] || [[ "$HF_USERNAME" == "null" || -z "$HF_USERNAME" ]]; then
                    echo "ERROR: Cannot download gated model $id - HF_TOKEN and HF_USERNAME are required"
                    echo "Please set these in $CONFIG_FILE"
                    exit 1
                fi
                
                HF_USERNAME_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$HF_USERNAME'''))")
                # SECURITY: auth_hf_url contains credentials - NEVER log or echo this variable
                auth_hf_url=$(echo "$hf_url" | sed "s#https://#https://$HF_USERNAME_ENC:$HF_TOKEN@#")
                # Log the non-authenticated URL only (NOT auth_hf_url which contains credentials)
                echo "Cloning gated model $hf_url for $id (memory-optimized)"
                if ! git clone --depth 1 --single-branch "$auth_hf_url" "$DOWNLOAD_DIR/$id"; then
                    # Use non-authenticated URL in error messages to avoid credential leaks
                    echo "ERROR: Failed to clone gated model from $hf_url for artifact $id"
                    echo "This could be due to:"
                    echo "  - Invalid or expired HF_TOKEN"
                    echo "  - No access to the gated model"
                    echo "  - Network connectivity issues"
                    echo "  - Invalid repository URL"
                    exit 1
                fi
            else
                echo "Cloning $hf_url for $id (memory-optimized)"
                if ! git clone --depth 1 --single-branch "$hf_url" "$DOWNLOAD_DIR/$id"; then
                    echo "ERROR: Failed to clone from $hf_url for artifact $id"
                    echo "This could be due to:"
                    echo "  - Network connectivity issues"
                    echo "  - Invalid repository URL"
                    echo "  - Repository not found or private"
                    exit 1
                fi
            fi
            
            # Now download LFS files if needed (more memory efficient than during clone)
            cd "$DOWNLOAD_DIR/$id"
            if [ -f .gitattributes ] && grep -q "filter=lfs" .gitattributes; then
                echo "Downloading LFS files for $id..."
                if [[ -n "$files_to_exclude" ]]; then
                    lfs_exclude_arg=$(echo "$files_to_exclude" | tr '\n' ',' | sed 's/,$//')
                    echo "Excluding from LFS download: $lfs_exclude_arg"
                    if ! git lfs pull --exclude="$lfs_exclude_arg"; then
                        echo "WARNING: Failed to download some LFS files for $id"
                    fi
                else
                    if ! git lfs pull; then
                        echo "WARNING: Failed to download some LFS files for $id"
                    fi
                fi
            fi
            cd - > /dev/null
            unset GIT_LFS_SKIP_SMUDGE
            
            # Clean up git files
            find "$DOWNLOAD_DIR/$id" -type f \( -name ".gitattributes" -o -name ".gitignore" -o -name ".gitmodules" \) -exec rm -f {} +
            rm -rf "$DOWNLOAD_DIR/$id/.git"
            
            # Exclude files-to-exclude
            if [[ -n "$files_to_exclude" ]]; then
                shopt -s nullglob
                while IFS= read -r exclude_file; do
                    if [[ "$exclude_file" == */ ]]; then
                        rm -rf "$DOWNLOAD_DIR/$id/$exclude_file"
                        echo "Excluded folder $exclude_file"
                    elif [[ "$exclude_file" == *"*"* || "$exclude_file" == *"?"* ]]; then
                        for match in "$DOWNLOAD_DIR/$id"/$exclude_file; do
                            if [ -e "$match" ]; then
                                rm -f "$match"
                                echo "Excluded $match"
                            fi
                        done
                    else
                        rm -f "$DOWNLOAD_DIR/$id/$exclude_file"
                        echo "Excluded $exclude_file"
                    fi
                done <<< "$files_to_exclude"
                shopt -u nullglob
            fi
            
            ls -lR "$DOWNLOAD_DIR/$id"
            echo "Successfully downloaded $id to $DOWNLOAD_DIR/$id"
        else
            echo "hf-url not set for $id, skipping clone."
        fi
        
        echo "-----------------------------"
    done
    
    echo ""
    echo "Download complete! Artifacts are located in: $DOWNLOAD_DIR"
    echo "To upload to MinIO, run: ./upload_to_minio.sh"
else
    echo "$CONFIG_FILE not found!"
    exit 1
fi

