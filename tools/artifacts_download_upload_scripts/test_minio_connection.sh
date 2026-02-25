#!/bin/bash
# Test script to diagnose MinIO connectivity and bucket creation issues

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://13.59.216.105:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
MINIO_BUCKET="${MINIO_BUCKET:-personal}"

echo "=========================================="
echo "MinIO Connection Test"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Endpoint: $MINIO_ENDPOINT"
echo "  Username: $MINIO_ROOT_USER"
echo "  Password: ${MINIO_ROOT_PASSWORD:0:3}***"
echo "  Bucket:   $MINIO_BUCKET"
echo ""

# Check if mc is installed
echo "[1/6] Checking if MinIO Client (mc) is installed..."
if command -v mc &> /dev/null; then
    echo "✓ MinIO Client found"
    mc --version
else
    echo "✗ MinIO Client not found, installing..."
    
    # Detect OS and Architecture
    OS="$(uname -s)"
    ARCH="$(uname -m)"
    
    if [[ "$OS" == "Darwin" ]]; then
        # macOS installation
        if command -v brew &> /dev/null; then
            echo "Installing MinIO Client via Homebrew..."
            brew install minio/stable/mc
        else
            echo "Homebrew not found. Installing MinIO Client manually..."
            if [[ "$ARCH" == "arm64" ]]; then
                MC_URL="https://dl.min.io/client/mc/release/darwin-arm64/mc"
            else
                MC_URL="https://dl.min.io/client/mc/release/darwin-amd64/mc"
            fi
            curl -o /tmp/mc "$MC_URL"
            chmod +x /tmp/mc
            sudo mv /tmp/mc /usr/local/bin/mc
        fi
    elif [[ "$OS" == "Linux" ]]; then
        # Linux installation
        echo "Installing MinIO Client for Linux..."
        
        if [[ "$ARCH" == "x86_64" ]]; then
            MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"
        elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
            MC_URL="https://dl.min.io/client/mc/release/linux-arm64/mc"
        else
            echo "Error: Unsupported architecture: $ARCH"
            exit 1
        fi
        
        curl -o /tmp/mc "$MC_URL"
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
fi
echo ""

# Check if MinIO endpoint is accessible
echo "[2/6] Testing MinIO endpoint connectivity..."
if curl -s "$MINIO_ENDPOINT/minio/health/live" > /dev/null 2>&1; then
    echo "✓ MinIO endpoint is accessible at $MINIO_ENDPOINT"
elif curl -s --connect-timeout 3 "$MINIO_ENDPOINT" > /dev/null 2>&1; then
    echo "✓ Endpoint responds (health check not available)"
else
    echo "✗ Cannot reach MinIO at $MINIO_ENDPOINT"
    echo "  Is MinIO running?"
    echo "  If using Docker: docker ps | grep minio"
    exit 1
fi
echo ""

# Configure alias
echo "[3/6] Configuring MinIO Client alias..."
ALIAS_NAME="test-minio"
mc alias set "$ALIAS_NAME" "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "✓ Alias configured successfully"
else
    echo "✗ Failed to configure alias"
    echo "  Check your credentials"
    exit 1
fi
echo ""

# List all buckets
echo "[4/6] Listing all buckets..."
BUCKETS=$(mc ls "$ALIAS_NAME" 2>&1)
LIST_STATUS=$?

if [ $LIST_STATUS -eq 0 ]; then
    echo "✓ Successfully listed buckets:"
    echo "$BUCKETS" | sed 's/^/  /'
    if [[ -z "$BUCKETS" ]]; then
        echo "  (No buckets found)"
    fi
else
    echo "✗ Failed to list buckets"
    echo "Error: $BUCKETS"
    exit 1
fi
echo ""

# Check specific bucket
echo "[5/6] Checking if bucket '$MINIO_BUCKET' exists..."
BUCKET_EXISTS=$(echo "$BUCKETS" | grep -w "$MINIO_BUCKET" || echo "")

if [[ -n "$BUCKET_EXISTS" ]]; then
    echo "✓ Bucket '$MINIO_BUCKET' exists"
else
    echo "✗ Bucket '$MINIO_BUCKET' not found"
fi
echo ""

# Try to create bucket
echo "[6/6] Testing bucket creation..."
TEST_BUCKET="test-bucket-$(date +%s)"
echo "Creating test bucket: $TEST_BUCKET"

CREATE_OUTPUT=$(mc mb "$ALIAS_NAME/$TEST_BUCKET" 2>&1)
CREATE_STATUS=$?

if [ $CREATE_STATUS -eq 0 ]; then
    echo "✓ Test bucket created successfully"
    
    # Clean up test bucket
    echo "Cleaning up test bucket..."
    mc rb "$ALIAS_NAME/$TEST_BUCKET" > /dev/null 2>&1
    echo "✓ Test bucket removed"
else
    echo "✗ Failed to create test bucket"
    echo "Error: $CREATE_OUTPUT"
    echo ""
    echo "Common issues:"
    echo "  - Insufficient permissions"
    echo "  - Invalid bucket name format"
    echo "  - MinIO storage quota exceeded"
    exit 1
fi

# Cleanup alias
mc alias remove "$ALIAS_NAME" > /dev/null 2>&1

echo ""
echo "=========================================="
echo "✓ All tests passed!"
echo "=========================================="
echo ""
echo "Your MinIO setup is working correctly."
echo "You can now run: ./upload_to_minio.sh"

