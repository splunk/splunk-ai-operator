#!/bin/bash
# Script to upload model artifacts to MinIO using AWS CLI (S3-compatible API)

SOURCE_DIR="./model_artifacts"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
# Change the bucket name to the one you want to use. It will be created if it doesn't exist.
MINIO_BUCKET="${MINIO_BUCKET:-ai-platform-artifacts-bucket}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"

# Convert bucket name to lowercase (S3/MinIO requirement)
ORIGINAL_BUCKET="$MINIO_BUCKET"
MINIO_BUCKET=$(echo "$MINIO_BUCKET" | tr '[:upper:]' '[:lower:]')
if [[ "$ORIGINAL_BUCKET" != "$MINIO_BUCKET" ]]; then
    echo "Note: Bucket name normalized to lowercase: $ORIGINAL_BUCKET -> $MINIO_BUCKET"
    echo ""
fi

echo "Checking and installing dependencies..."
echo ""

# Detect OS and Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"
echo "Detected OS: $OS ($ARCH)"

# Install AWS CLI if not present
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found, installing..."
    
    if [[ "$OS" == "Darwin" ]]; then
        # macOS installation
        if command -v brew &> /dev/null; then
            echo "Installing AWS CLI via Homebrew..."
            brew install awscli
        else
            echo "Homebrew not found. Installing AWS CLI manually..."
            # Download and install AWS CLI for macOS
            curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "/tmp/AWSCLIV2.pkg"
            sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
            rm /tmp/AWSCLIV2.pkg
        fi
    elif [[ "$OS" == "Linux" ]]; then
        # Linux installation
        echo "Installing AWS CLI for Linux..."
        
        # Determine architecture
        if [[ "$ARCH" == "x86_64" ]]; then
            AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
        elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
            AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
        else
            echo "Error: Unsupported architecture: $ARCH"
            exit 1
        fi
        
        # Download and install AWS CLI
        cd /tmp
        curl "$AWS_URL" -o "awscliv2.zip"
        
        if ! command -v unzip &> /dev/null; then
            echo "Installing unzip..."
            if [[ $EUID -eq 0 ]]; then
                if command -v apt-get &> /dev/null; then
                    apt-get update && apt-get install -y unzip
                elif command -v yum &> /dev/null; then
                    yum install -y unzip
                elif command -v dnf &> /dev/null; then
                    dnf install -y unzip
                else
                    echo "Error: No supported package manager found. Please install unzip manually."
                    exit 1
                fi
            elif command -v sudo &> /dev/null; then
                if command -v apt-get &> /dev/null; then
                    sudo apt-get update && sudo apt-get install -y unzip
                elif command -v yum &> /dev/null; then
                    sudo yum install -y unzip
                elif command -v dnf &> /dev/null; then
                    sudo dnf install -y unzip
                else
                    echo "Error: No supported package manager found. Please install unzip manually."
                    exit 1
                fi
            else
                echo "Error: unzip not found and cannot install. Please install unzip manually."
                exit 1
            fi
        fi
        
        unzip -q awscliv2.zip
        
        if [[ $EUID -eq 0 ]]; then
            ./aws/install
        elif command -v sudo &> /dev/null; then
            sudo ./aws/install
        else
            ./aws/install -i ~/.local/aws-cli -b ~/.local/bin
            export PATH=$PATH:~/.local/bin
            echo "Note: AWS CLI installed to ~/.local/bin - ensure this is in your PATH"
        fi
        
        rm -rf awscliv2.zip aws
        cd - > /dev/null
    else
        echo "Error: Unsupported operating system: $OS"
        echo "Please install AWS CLI manually."
        echo "Visit: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        exit 1
    fi
    
    # Verify installation
    if command -v aws &> /dev/null; then
        echo "✓ AWS CLI installed successfully"
        aws --version
    else
        echo "Error: AWS CLI installation failed"
        exit 1
    fi
else
    echo "✓ AWS CLI already installed"
    aws --version
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
if [[ -z "$MINIO_ENDPOINT" || -z "$MINIO_BUCKET" || -z "$MINIO_ACCESS_KEY" || -z "$MINIO_SECRET_KEY" ]]; then
    echo "Error: MinIO configuration incomplete."
    echo "Required variables: MINIO_ENDPOINT, MINIO_BUCKET, MINIO_ACCESS_KEY, MINIO_SECRET_KEY"
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

# Set AWS credentials for MinIO
export AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"

echo "Connecting to MinIO..."
echo "  Endpoint: $MINIO_ENDPOINT"
echo "  Bucket: $MINIO_BUCKET"
echo ""

# Test MinIO connection by listing buckets
echo "Testing MinIO connection..."
CONNECTION_TEST=$(aws s3 ls --endpoint-url "$MINIO_ENDPOINT" 2>&1)
CONNECTION_STATUS=$?

if [ $CONNECTION_STATUS -eq 0 ]; then
    echo "✓ Successfully connected to MinIO"
else
    echo "✗ Failed to connect to MinIO"
    echo ""
    
    # Check for specific error types
    if echo "$CONNECTION_TEST" | grep -q "InvalidAccessKeyId\|SignatureDoesNotMatch\|AccessDenied"; then
        echo "Error: Authentication failed - Invalid credentials"
        echo ""
        echo "Current configuration:"
        echo "  Access Key: $MINIO_ACCESS_KEY"
        echo "  Secret Key: ${MINIO_SECRET_KEY:0:3}***"
        echo ""
        echo "Troubleshooting:"
        echo "  1. Check MINIO_ACCESS_KEY is correct (currently: $MINIO_ACCESS_KEY)"
        echo "  2. Check MINIO_SECRET_KEY is correct"
        echo "  3. Default MinIO credentials are usually:"
        echo "     - Access Key: minioadmin"
        echo "     - Secret Key: minioadmin"
        echo "  4. If you changed MinIO credentials, update them in this script"
    elif echo "$CONNECTION_TEST" | grep -q "could not connect\|Connection refused\|Failed to connect"; then
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
        echo "General troubleshooting:"
        echo "  1. Verify MinIO is running and accessible"
        echo "  2. Check endpoint: $MINIO_ENDPOINT"
        echo "  3. Verify credentials are correct"
    fi
    
    exit 1
fi

# Check if bucket exists, create if it doesn't
echo ""
echo "Checking if bucket '$MINIO_BUCKET' exists..."

BUCKET_LIST=$(aws s3 ls --endpoint-url "$MINIO_ENDPOINT" 2>&1)
BUCKET_EXISTS=$(echo "$BUCKET_LIST" | grep -w "$MINIO_BUCKET" || echo "")

if [[ -n "$BUCKET_EXISTS" ]]; then
    echo "✓ Bucket '$MINIO_BUCKET' already exists"
else
    echo "Bucket '$MINIO_BUCKET' not found. Creating..."
    
    # Create bucket using AWS CLI
    CREATE_OUTPUT=$(aws s3 mb "s3://$MINIO_BUCKET" --endpoint-url "$MINIO_ENDPOINT" 2>&1)
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
            # It's a directory - upload recursively
            echo "Uploading directory to MinIO: $MINIO_ENDPOINT/$MINIO_BUCKET/model_artifacts/$id/"
            
            aws s3 cp "$artifact_path" "s3://$MINIO_BUCKET/model_artifacts/$id/" \
                --recursive \
                --endpoint-url "$MINIO_ENDPOINT"
        else
            # It's a file - upload directly
            echo "Uploading file to MinIO: $MINIO_ENDPOINT/$MINIO_BUCKET/model_artifacts/$id"
            
            aws s3 cp "$artifact_path" "s3://$MINIO_BUCKET/model_artifacts/$id" \
                --endpoint-url "$MINIO_ENDPOINT"
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
echo "✓ Upload complete! Uploaded $artifact_count artifacts to MinIO bucket '$MINIO_BUCKET'"

