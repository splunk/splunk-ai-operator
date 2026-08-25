#!/bin/bash
# Script to upload model artifacts to AWS S3

SOURCE_DIR="./model_artifacts"
S3_BUCKET="${S3_BUCKET:-ai-platform-artifacts-bucket}"
S3_REGION="${S3_REGION:-us-east-2}"
S3_PREFIX="${S3_PREFIX:-model_artifacts}"
# Set to 1 to skip artifacts whose .staging_complete marker already exists in S3.
SKIP_IF_STAGED="${SKIP_IF_STAGED:-0}"

# Convert bucket name to lowercase (S3 requirement)
if [[ -n "$S3_BUCKET" ]]; then
    ORIGINAL_BUCKET="$S3_BUCKET"
    S3_BUCKET=$(echo "$S3_BUCKET" | tr '[:upper:]' '[:lower:]')
    if [[ "$ORIGINAL_BUCKET" != "$S3_BUCKET" ]]; then
        echo "Note: Bucket name normalized to lowercase: $ORIGINAL_BUCKET -> $S3_BUCKET"
    fi
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
artifact_count=$(find -L "$SOURCE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')

if [[ "$artifact_count" -eq 0 ]]; then
    echo "No artifacts found in $SOURCE_DIR"
    echo "Run ./download_from_huggingface.sh first to download the artifacts."
    exit 1
fi

echo "Found $artifact_count artifacts to upload from $SOURCE_DIR"
echo ""

# Validate S3 configuration
if [[ -z "$S3_BUCKET" ]]; then
    echo "Error: S3_BUCKET environment variable not set."
    echo ""
    echo "Usage:"
    echo "  export S3_BUCKET=your-bucket-name"
    echo "  export S3_REGION=us-east-2  # Optional, defaults to us-east-2"
    echo "  export S3_PREFIX=model_artifacts  # Optional, defaults to 'model_artifacts'"
    echo "  ./upload_to_s3.sh"
    echo ""
    echo "Or set inline:"
    echo "  S3_BUCKET=your-bucket-name ./upload_to_s3.sh"
    exit 1
fi

# Validate bucket name (must be DNS-compliant: lowercase, numbers, hyphens, dots)
if [[ ! "$S3_BUCKET" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] && [[ ! "$S3_BUCKET" =~ ^[a-z0-9]$ ]]; then
    echo "Warning: Bucket name '$S3_BUCKET' may contain invalid characters."
    echo "S3 bucket names must:"
    echo "  - Be lowercase"
    echo "  - Start and end with a letter or number"
    echo "  - Only contain lowercase letters, numbers, hyphens, and dots"
    echo "  - Be between 3 and 63 characters long"
fi

# Check AWS credentials
echo "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Error: AWS credentials not configured or invalid."
    echo ""
    echo "Please configure AWS credentials using one of these methods:"
    echo "  1. AWS CLI: aws configure"
    echo "  2. Environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
    echo "  3. IAM role (if running on EC2/ECS/Lambda)"
    echo ""
    exit 1
fi

CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null)
AWS_ACCOUNT=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*' | cut -d'"' -f4)
AWS_USER=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4)

echo "✓ AWS credentials valid"
echo "  Account: $AWS_ACCOUNT"
echo "  Identity: $AWS_USER"
echo "  Region: $S3_REGION"
echo "  Bucket: s3://$S3_BUCKET"
echo "  Prefix: $S3_PREFIX"
echo ""

# Check if bucket exists, create if it doesn't
echo "Checking if S3 bucket '$S3_BUCKET' exists..."
if aws s3 ls "s3://$S3_BUCKET" --region "$S3_REGION" &> /dev/null; then
    echo "✓ Bucket 's3://$S3_BUCKET' exists"
else
    echo "Bucket 's3://$S3_BUCKET' not found. Creating..."
    
    # Create bucket with appropriate location constraint
    if [[ "$S3_REGION" == "us-east-1" ]]; then
        # us-east-1 doesn't need location constraint
        aws s3 mb "s3://$S3_BUCKET" --region "$S3_REGION"
    else
        # Other regions need location constraint - use s3api create-bucket
        aws s3api create-bucket \
            --bucket "$S3_BUCKET" \
            --region "$S3_REGION" \
            --create-bucket-configuration "LocationConstraint=$S3_REGION"
    fi
    
    if [ $? -eq 0 ]; then
        echo "✓ Bucket 's3://$S3_BUCKET' created successfully in region $S3_REGION"
    else
        echo "Error: Failed to create bucket 's3://$S3_BUCKET'"
        echo "Please check your AWS permissions or create the bucket manually"
        exit 1
    fi
fi

echo ""

# Upload all artifacts from the source directory
for artifact_path in "$SOURCE_DIR"/*; do
    if [[ -e "$artifact_path" ]]; then
        id=$(basename "$artifact_path")
        echo "Processing: $id"

        s3_base="s3://$S3_BUCKET/$S3_PREFIX/$id"
        # Marker lives in staging_state/ — separate from model_artifacts/ —
        # so model loaders never encounter it at inference time.
        marker_s3="s3://$S3_BUCKET/staging_state/$id/.staging_complete"

        # Skip entirely if already fully staged in S3 with matching hf_url.
        # Presence-only check is not enough: a marker from a prior run may lack
        # hf_url= or have a stale URL; in that case we must re-upload so the
        # verification step finds a current marker.
        if [[ "$SKIP_IF_STAGED" == "1" ]]; then
            local_hf_url=$(grep "^hf_url=" "$artifact_path/.staging_complete" 2>/dev/null | cut -d= -f2-)
            remote_hf_url=$(aws s3 cp "$marker_s3" - --region "$S3_REGION" 2>/dev/null | grep "^hf_url=" | cut -d= -f2-)
            if [[ -n "$local_hf_url" && "$local_hf_url" == "$remote_hf_url" ]]; then
                echo "✓ $id already staged in S3 (hf_url matches) — skipping."
                echo "-----------------------------"
                continue
            fi
        fi

        upload_ok=0
        if [[ -d "$artifact_path" ]]; then
            # Sync directory — add --delete when replacing a prior version (URL changed)
            # so stale weight files from the old model are deleted from the store.
            sync_opts=(--exclude ".staging_complete" --region "$S3_REGION")
            if [[ -n "$remote_hf_url" && "$remote_hf_url" != "$local_hf_url" ]]; then
                echo "↻ $id: hf_url changed — syncing with --delete to clean up stale files."
                sync_opts+=(--delete)
            fi
            echo "Syncing directory to: ${s3_base}/"
            if aws s3 sync "$artifact_path" "${s3_base}/" \
                    "${sync_opts[@]}"; then
                # Upload marker to staging_state/ last — its presence proves upload is complete
                if [[ -f "$artifact_path/.staging_complete" ]]; then
                    aws s3 cp "$artifact_path/.staging_complete" "$marker_s3" \
                        --region "$S3_REGION" && upload_ok=1
                else
                    upload_ok=1
                fi
            fi
        else
            # Single-file artifact — upload directly
            echo "Uploading file to: $s3_base"
            aws s3 cp "$artifact_path" "$s3_base" --region "$S3_REGION" && upload_ok=1
        fi

        if [[ "$upload_ok" == "1" ]]; then
            echo "✓ Uploaded $id to $s3_base"
        else
            echo "✗ Failed to upload $id"
        fi
        echo "-----------------------------"
    fi
done

echo ""
echo "✓ Upload complete! Uploaded $artifact_count artifacts to s3://$S3_BUCKET/$S3_PREFIX/"

