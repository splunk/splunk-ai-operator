#!/bin/bash
# Script to upload model artifacts to MinIO or any S3-compatible storage (e.g. SeaweedFS).
# Prefer generic env vars; MINIO_* are accepted for backward compatibility.

SOURCE_DIR="./model_artifacts"
# Generic names (preferred); fallback to MINIO_* for backward compatibility
OBJECT_STORE_ENDPOINT="${OBJECT_STORE_ENDPOINT:-${MINIO_ENDPOINT:-http://127.0.0.1:9000}}"
OBJECT_STORE_BUCKET="${OBJECT_STORE_BUCKET:-${MINIO_BUCKET:-ai-platform-bucket-minio-us-east-2}}"
OBJECT_STORE_ACCESS_KEY="${OBJECT_STORE_ACCESS_KEY:-${MINIO_ROOT_USER:-${MINIO_ACCESS_KEY:-minioadmin}}}"
OBJECT_STORE_SECRET_KEY="${OBJECT_STORE_SECRET_KEY:-${MINIO_ROOT_PASSWORD:-${MINIO_SECRET_KEY:-minioadmin}}}"
# Internal use (script uses one set)
MINIO_ENDPOINT="${OBJECT_STORE_ENDPOINT}"
MINIO_BUCKET="${OBJECT_STORE_BUCKET}"
MINIO_ROOT_USER="${OBJECT_STORE_ACCESS_KEY}"
MINIO_ROOT_PASSWORD="${OBJECT_STORE_SECRET_KEY}"

# Convert bucket name to lowercase (S3/MinIO requirement)
ORIGINAL_BUCKET="$MINIO_BUCKET"
MINIO_BUCKET=$(echo "$MINIO_BUCKET" | tr '[:upper:]' '[:lower:]')
if [[ "$ORIGINAL_BUCKET" != "$MINIO_BUCKET" ]]; then
    echo "Note: Bucket name normalized to lowercase: $ORIGINAL_BUCKET -> $MINIO_BUCKET"
    echo ""
fi

echo "Checking and installing dependencies..."
echo ""

# sudo on Amazon Linux uses a restricted PATH that excludes /usr/local/bin
export PATH="$PATH:/usr/local/bin"

# Detect OS and Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"
echo "Detected OS: $OS ($ARCH)"

# Install MinIO Client (mc) if not present
if ! command -v mc &> /dev/null; then
    echo "MinIO Client (mc) not found, installing..."
    
    if [[ "$OS" == "Darwin" ]]; then
        # macOS installation
        if command -v brew &> /dev/null; then
            echo "Installing MinIO Client via Homebrew..."
            brew install minio/stable/mc
        else
            echo "Homebrew not found. Installing MinIO Client manually..."
            # Download and install mc for macOS
            if [[ "$ARCH" == "arm64" ]]; then
                MC_URL="https://dl.min.io/client/mc/release/darwin-arm64/mc"
            else
                MC_URL="https://dl.min.io/client/mc/release/darwin-amd64/mc"
            fi
            
            curl -fsSL -o /tmp/mc "$MC_URL" || { echo "Error: Failed to download mc from $MC_URL"; exit 1; }
            chmod +x /tmp/mc
            sudo mv /tmp/mc /usr/local/bin/mc
        fi
    elif [[ "$OS" == "Linux" ]]; then
        # Linux installation
        echo "Installing MinIO Client for Linux..."

        # Determine architecture
        if [[ "$ARCH" == "x86_64" ]]; then
            MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"
        elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
            MC_URL="https://dl.min.io/client/mc/release/linux-arm64/mc"
        else
            echo "Error: Unsupported architecture: $ARCH"
            exit 1
        fi

        # Download mc
        curl -fsSL -o /tmp/mc "$MC_URL" || { echo "Error: Failed to download mc from $MC_URL"; exit 1; }
        chmod +x /tmp/mc
        
        # Try to move to /usr/local/bin
        if [[ $EUID -eq 0 ]]; then
            mv /tmp/mc /usr/local/bin/mc
        elif command -v sudo &> /dev/null; then
            sudo mv /tmp/mc /usr/local/bin/mc
        else
            # Install to user's local bin if no sudo
            mkdir -p ~/.local/bin
            mv /tmp/mc ~/.local/bin/mc
            export PATH=$PATH:~/.local/bin
            echo "Note: mc installed to ~/.local/bin - ensure this is in your PATH"
        fi
    else
        echo "Error: Unsupported operating system: $OS"
        echo "Please install MinIO Client manually."
        echo "Visit: https://min.io/docs/minio/linux/reference/minio-mc.html"
        exit 1
    fi
    
    # Verify installation
    if command -v mc &> /dev/null; then
        echo "✓ MinIO Client installed successfully"
        mc --version
    else
        echo "Error: MinIO Client installation failed"
        exit 1
    fi
else
    echo "✓ MinIO Client already installed"
    mc --version
fi

echo ""
echo "All dependencies installed successfully!"
echo ""

# Check if source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: Directory $SOURCE_DIR not found."
    echo "Run ./download_from_huggingface.sh first to download the artifacts."
    exit 1
fi

# Count artifacts in the directory (both files and directories)
artifact_count=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')

if [[ "$artifact_count" -eq 0 ]]; then
    echo "No artifacts found in $SOURCE_DIR"
    echo "Run ./download_from_huggingface.sh first to download the artifacts."
    exit 1
fi

echo "Found $artifact_count artifacts to upload from $SOURCE_DIR"
echo ""

# Validate MinIO configuration
if [[ -z "$MINIO_ENDPOINT" || -z "$MINIO_BUCKET" || -z "$MINIO_ROOT_USER" || -z "$MINIO_ROOT_PASSWORD" ]]; then
    echo "Error: MinIO configuration incomplete."
    echo "Required variables: MINIO_ENDPOINT, MINIO_BUCKET, MINIO_ROOT_USER, MINIO_ROOT_PASSWORD"
    exit 1
fi

# Validate bucket name (must be DNS-compliant: lowercase, numbers, hyphens)
if [[ ! "$MINIO_BUCKET" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] && [[ ! "$MINIO_BUCKET" =~ ^[a-z0-9]$ ]]; then
    echo "Warning: Bucket name '$MINIO_BUCKET' may contain invalid characters."
    echo "MinIO/S3 bucket names must:"
    echo "  - Be lowercase"
    echo "  - Start and end with a letter or number"
    echo "  - Only contain lowercase letters, numbers, and hyphens"
fi

# Configure MinIO Client alias
MINIO_ALIAS="myminio"
echo "Configuring MinIO Client..."
ALIAS_OUTPUT=$(mc alias set "$MINIO_ALIAS" "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 2>&1)
ALIAS_STATUS=$?

if [ $ALIAS_STATUS -eq 0 ]; then
    echo "✓ MinIO alias configured successfully"
else
    echo "✗ Failed to configure MinIO alias"
    echo ""
    echo "Error details:"
    echo "$ALIAS_OUTPUT" | sed 's/^/  /'
    echo ""
    echo "Current configuration:"
    echo "  Endpoint: $MINIO_ENDPOINT"
    echo "  Username: $MINIO_ROOT_USER"
    echo "  Password: ${MINIO_ROOT_PASSWORD:0:3}***"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check endpoint is correct and accessible"
    echo "  2. Verify MinIO is running"
    echo "  3. Check credentials (default: minioadmin/minioadmin)"
    exit 1
fi

echo ""

# Check if bucket exists, create if it doesn't
echo "Checking if bucket '$MINIO_BUCKET' exists..."

# First, test MinIO connection by listing all buckets
echo "Testing MinIO connection..."
CONNECTION_TEST=$(mc ls "$MINIO_ALIAS" 2>&1)
CONNECTION_STATUS=$?

if [ $CONNECTION_STATUS -ne 0 ]; then
    echo "✗ Cannot connect to MinIO at $MINIO_ENDPOINT"
    echo ""
    
    # Check for specific error types
    if echo "$CONNECTION_TEST" | grep -qi "Access Denied\|InvalidAccessKeyId\|SignatureDoesNotMatch\|signature.*does not match"; then
        echo "Error: Authentication failed - Invalid credentials"
        echo ""
        echo "Current configuration:"
        echo "  Username: $MINIO_ROOT_USER"
        echo "  Password: ${MINIO_ROOT_PASSWORD:0:3}***"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check MINIO_ROOT_USER is correct (currently: $MINIO_ROOT_USER)"
        echo "  2. Check MINIO_ROOT_PASSWORD is correct"
        echo "  3. Default MinIO credentials are usually:"
        echo "     - Username: minioadmin"
        echo "     - Password: minioadmin"
        echo "  4. If you installed MinIO with a custom password (e.g. install_minio_ec2.sh --password 'xxx'), run:"
        echo "     MINIO_ROOT_PASSWORD='your-password' ./upload_to_minio.sh"
    elif echo "$CONNECTION_TEST" | grep -q "dial tcp\|connection refused\|no such host"; then
        echo "Error: Cannot reach MinIO endpoint"
        echo ""
        echo "Endpoint: $MINIO_ENDPOINT"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Ensure MinIO is running"
        echo "     - If using Docker: docker ps | grep minio"
        echo "     - If local service: systemctl status minio"
        echo "  2. Check the endpoint URL is correct"
        echo "  3. Verify port 9000 is not blocked by firewall"
    else
        echo "Error details:"
        echo "$CONNECTION_TEST" | sed 's/^/  /'
        echo ""
        echo "Troubleshooting:"
        echo "  1. Verify MinIO is running and accessible"
        echo "  2. Check endpoint: $MINIO_ENDPOINT"
        echo "  3. Verify credentials are correct"
    fi
    
    exit 1
fi

echo "✓ Successfully connected to MinIO"

# Check if specific bucket exists
BUCKET_CHECK=$(mc ls "$MINIO_ALIAS" 2>/dev/null | grep -w "$MINIO_BUCKET" || echo "")

if [[ -n "$BUCKET_CHECK" ]]; then
    echo "✓ Bucket '$MINIO_BUCKET' already exists"
else
    echo "Bucket '$MINIO_BUCKET' not found. Creating..."
    
    # Create bucket with verbose output
    CREATE_OUTPUT=$(mc mb "$MINIO_ALIAS/$MINIO_BUCKET" 2>&1)
    CREATE_STATUS=$?
    
    if [ $CREATE_STATUS -eq 0 ]; then
        echo "✓ Bucket '$MINIO_BUCKET' created successfully"
    else
        echo "Error: Failed to create bucket '$MINIO_BUCKET'"
        echo "Error details: $CREATE_OUTPUT"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Ensure MinIO is running: docker ps (if using Docker)"
        echo "  2. Check MinIO endpoint: $MINIO_ENDPOINT"
        echo "  3. Verify credentials are correct"
        echo "  4. Check bucket name is valid (lowercase, no special chars)"
        exit 1
    fi
fi

echo ""

# Upload all artifacts from the source directory
for artifact_path in "$SOURCE_DIR"/*; do
    if [[ -e "$artifact_path" ]]; then
        id=$(basename "$artifact_path")
        echo "Processing: $id"
        
        if [[ -d "$artifact_path" ]]; then
            # It's a directory - upload recursively (trailing slash on source = copy contents, not directory as single object)
            echo "Uploading directory to MinIO: $MINIO_ENDPOINT/$MINIO_BUCKET/model_artifacts/$id/"
            
            mc cp --recursive "$artifact_path/" "$MINIO_ALIAS/$MINIO_BUCKET/model_artifacts/$id/"
        else
            # It's a file - upload directly
            echo "Uploading file to MinIO: $MINIO_ENDPOINT/$MINIO_BUCKET/model_artifacts/$id"
            
            mc cp "$artifact_path" "$MINIO_ALIAS/$MINIO_BUCKET/model_artifacts/$id"
        fi
        
        if [ $? -eq 0 ]; then
            echo "✓ Uploaded $id to MinIO: $MINIO_ENDPOINT/$MINIO_BUCKET/model_artifacts/$id"
        else
            echo "✗ Failed to upload $id"
        fi
        echo "-----------------------------"
    fi
done

echo ""
echo "✓ Upload complete! Uploaded $artifact_count artifacts."
