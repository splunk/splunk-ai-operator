# Model Artifacts Scripts

This directory contains scripts for downloading model artifacts from Hugging Face and uploading them to MinIO/S3.

## ⚠️ Important Prerequisites

**Sudo Access May Be Required:**
- These scripts automatically install dependencies (wget, yq, git-lfs, AWS CLI, MinIO Client, etc.)
- On Linux systems, installing dependencies typically requires sudo/root access
- On macOS, sudo may be required depending on your Homebrew configuration
- If you don't have sudo access:
  - Dependencies will be installed to user directories (`~/.local/bin`)
  - Ensure `~/.local/bin` is in your PATH
  - Manual installation instructions will be provided if automatic installation fails

**Running Scripts:**
- If dependency installation fails, try running with sudo: `sudo ./script_name.sh`
- Or manually install required dependencies first (see Dependency Installation Methods section)

## Scripts

### 1. `download_from_huggingface.sh`
Downloads model artifacts from Hugging Face repositories.

**Features:**
- Reads configuration from `model_artifacts_configs.yaml`
- Supports both public and gated Hugging Face models
- Automatically installs dependencies (wget, yq, git-lfs)
- Validates Python 3 availability (required for gated model credential encoding)
- **Memory-optimized cloning**: Uses shallow clone and separate LFS pull to minimize memory usage
  - Uses `--depth 1 --single-branch` to reduce clone size
  - Downloads LFS files separately for better memory efficiency
  - Prevents OOM (Out of Memory) kills on resource-constrained instances
- **Force re-download**: Removes and re-downloads models if they already exist
- **Fail-fast error handling**: Exits immediately on any download failure
- **Detailed error messages**: Prints specific error information for troubleshooting
- **Credential validation**: Validates HF credentials before attempting gated model downloads
- **Security**: Redacts sensitive credentials in logs to prevent exposure
- Cleans up git files after download
- Excludes specified files based on configuration
- Saves downloads to `./model_artifacts/` directory

**Usage:**
```bash
./download_from_huggingface.sh
```

Or with sudo if dependency installation fails:
```bash
sudo ./download_from_huggingface.sh
```

**Prerequisites:**
- `model_artifacts_configs.yaml` must be present in the same directory
- Python 3 must be installed (required for URL encoding credentials)
- For gated models: HF token and username must be configured in the YAML file
- May require sudo for installing dependencies (wget, yq, git-lfs)

**Error Handling:**
- The script exits immediately if any download fails (no partial downloads)
- Existing model directories are automatically removed before re-downloading
- Memory-optimized to prevent OOM (Out of Memory) kills on cloud instances
- Error messages include possible causes:
  - Invalid or expired HF_TOKEN
  - No access to gated models
  - Network connectivity issues
  - Invalid repository URLs
  - Repository not found or private
  - Out of memory (OOM) - see Troubleshooting section
- Script returns non-zero exit code on failure (suitable for CI/CD pipelines)

### 2. `upload_to_minio.sh`
Uploads downloaded artifacts to MinIO or any S3-compatible storage (e.g. SeaweedFS).

**Features:**
- Automatically uploads **all artifacts** from `./model_artifacts/` directory
- No config file needed - just uploads everything found
- **Auto-creates bucket** if it doesn't exist
- Uses native MinIO Client (mc) for optimal performance
- Works with **MinIO, SeaweedFS, or any S3-compatible** backend; set endpoint and credentials to match your store.
- Comprehensive dependency installation:
  - MinIO Client via **Homebrew on macOS** or **direct download on Linux**
  - Supports macOS (Intel & Apple Silicon) and Linux (amd64 & arm64)
  - Multiple fallback installation methods

**Usage:**
```bash
./upload_to_minio.sh
```

Or with sudo if dependency installation fails:
```bash
sudo ./upload_to_minio.sh
```

**Environment variables (S3-compatible target):**  
Preferred generic names; `MINIO_*` are accepted for backward compatibility.

| Preferred (generic) | Fallback | Description |
|---------------------|----------|-------------|
| `OBJECT_STORE_ENDPOINT` | `MINIO_ENDPOINT` | S3 API endpoint URL (e.g. http://host:9000 for MinIO, http://host:8333 for SeaweedFS) |
| `OBJECT_STORE_BUCKET` | `MINIO_BUCKET` | Bucket name |
| `OBJECT_STORE_ACCESS_KEY` | `MINIO_ROOT_USER` or `MINIO_ACCESS_KEY` | Access key |
| `OBJECT_STORE_SECRET_KEY` | `MINIO_ROOT_PASSWORD` or `MINIO_SECRET_KEY` | Secret key |

Example for SeaweedFS: `OBJECT_STORE_ENDPOINT=http://seaweedfs:8333 OBJECT_STORE_BUCKET=my-bucket ./upload_to_minio.sh`

**Prerequisites:**
- Run `download_from_huggingface.sh` first to download artifacts
- May require sudo for installing MinIO Client (mc)
- Set endpoint, bucket, and credentials via the env vars above (defaults point to a local MinIO).

### 3. `upload_to_seaweedfs.sh`
Uploads downloaded artifacts to SeaweedFS (S3-compatible). If SeaweedFS is not running at the endpoint, the script can **install and start it** (downloads the `weed` binary from GitHub releases, no Docker). If you run SeaweedFS via **systemd** (see **§4 `install_seaweedfs_systemd.sh`** below), ensure the service is up (`sudo systemctl start seaweedfs`) before running the upload script so the script doesn’t start a second instance.

**Features:**
- **Auto-install SeaweedFS** when not reachable: downloads latest `weed` for Linux/macOS (amd64/arm64), installs to `/usr/local/bin` or `~/.local/bin`, and starts `weed server -s3` in the background (S3 gateway on port 8333).
- Auto-install only runs when the endpoint is local (`127.0.0.1` or `localhost`). For remote endpoints, SeaweedFS must already be running.
- Creates configured buckets (from `SEAWEEDFS_BUCKETS` or primary bucket), then uploads all of `./model_artifacts/` to the primary bucket.
- Uses MinIO Client (mc); installs mc if missing.

**Usage:**
```bash
./upload_to_seaweedfs.sh
```

With a remote SeaweedFS:
```bash
S3COMPAT_OBJECT_STORE_ENDPOINT=http://seaweedfs-host:8333 S3COMPAT_OBJECT_STORE_BUCKET=my-bucket ./upload_to_seaweedfs.sh
```

To skip auto-install and only fail if unreachable:
```bash
SEAWEEDFS_SKIP_INSTALL=1 ./upload_to_seaweedfs.sh
```

**Volume limit:** When the script starts SeaweedFS it uses `-volume.max=100` (set `SEAWEEDFS_VOLUME_MAX`; use `0` for auto). The default (~7) can cause "0 node candidates" once the volume server is "full."

**Environment variables:** `S3COMPAT_OBJECT_STORE_ENDPOINT` (default: http://127.0.0.1:8333), `S3COMPAT_OBJECT_STORE_BUCKET`, `S3COMPAT_OBJECT_STORE_ACCESS_KEY`, `S3COMPAT_OBJECT_STORE_SECRET_KEY`, `SEAWEEDFS_BUCKETS`, `SEAWEEDFS_SKIP_INSTALL`, `SEAWEEDFS_UPLOAD_RETRIES`, `SEAWEEDFS_UPLOAD_RETRY_DELAY`, `SEAWEEDFS_PARALLEL_JOBS`, `SEAWEEDFS_ERROR_LOG`, `SEAWEEDFS_SKIP_EXISTING`, `SEAWEEDFS_WAIT_VOLUME_SERVER`, `SEAWEEDFS_MASTER`, `SEAWEEDFS_VOLUME_MAX` (default 100).

**SeaweedFS credentials:** SeaweedFS S3 has no built-in users (unlike MinIO’s default `minioadmin`). If you start SeaweedFS yourself, it must be configured to accept the same access key/secret the script uses (defaults: `minioadmin`/`minioadmin`). Options: (1) Start with env vars: `AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin weed server -s3`; (2) Use a JSON config file with `weed s3 -config=/path/to/s3.json` (see [SeaweedFS S3 Credentials](https://github.com/seaweedfs/seaweedfs/wiki/S3-Credentials)). If you see *"The access key ID you provided does not exist in our records"*, restart SeaweedFS with the same credentials as `S3COMPAT_OBJECT_STORE_ACCESS_KEY`/`S3COMPAT_OBJECT_STORE_SECRET_KEY` (or set those env vars to match your SeaweedFS config).

**Volume server readiness:** After SeaweedFS has just started (or restarted), the master may not see a volume server yet, so uploads can fail with "Not enough data nodes found". The script can **wait for a volume server** (when endpoint is local and `weed` is available): it polls `weed shell -master=... cluster.ps` for up to `SEAWEEDFS_WAIT_VOLUME_SERVER` seconds (default 60) before starting uploads. Set `SEAWEEDFS_WAIT_VOLUME_SERVER=0` to skip.

**Parallel uploads and error log:** Uploads run in parallel (up to `SEAWEEDFS_PARALLEL_JOBS` at a time, default 3). Directory artifacts are uploaded **file-by-file** with per-file retries, so one failed file (e.g. a single `.safetensors` shard) only retries that file, not the whole artifact. Failed files/artifacts are appended to `SEAWEEDFS_ERROR_LOG` (default `./seaweedfs_upload_errors.log`) with artifact id and relative path; at the end the script prints that file and exits with code 1 if any failed.

**Large artifacts (e.g. LLaMA 70B):** Uploads of very large files (multi-GB `.safetensors` shards) can fail with *"We encountered an internal error, please try again"*. The script retries each artifact up to `SEAWEEDFS_UPLOAD_RETRIES` (default 3) with `SEAWEEDFS_UPLOAD_RETRY_DELAY` seconds between attempts. If failures persist, check SeaweedFS host memory and disk (`/tmp/seaweedfs.log` or volume server logs), ensure enough free space for the full object, and consider increasing retries: `SEAWEEDFS_UPLOAD_RETRIES=5 SEAWEEDFS_UPLOAD_RETRY_DELAY=30 ./upload_to_seaweedfs.sh`.

**"0 node candidates" / "Not enough data nodes":** Usually the volume server hit its max volume count (default ~7), disk is near full (read-only), heartbeat timeouts, or OOM. The script and systemd unit use `-volume.max=100` by default. When the error happens: `curl -s http://localhost:9333/cluster/status | jq` (master view); `curl -s http://127.0.0.1:8080/status | jq` (volume server; if Max==Count, increase `SEAWEEDFS_VOLUME_MAX`). See `tools/artifacts_download_upload_scripts/SEAWEEDFS_SYSTEMD.md` for full troubleshooting.

**Prerequisites:**
- Run `download_from_huggingface.sh` first to download artifacts
- For auto-install: curl, tar; optional sudo for `/usr/local/bin`
- No Docker required

**Create standard folders:** To create the platform folders (`apps/`, `artifacts/`, `config/`, `job_groups/`, `model_artifacts/`, `tasks/`) in SeaweedFS, run `./create_seaweedfs_folders.sh` after SeaweedFS is up. It uses the same endpoint and credentials as `upload_to_seaweedfs.sh`.

**Upload Splunk AI Assistant app:** To upload `Splunk_AI_Assistant_Cloud.tgz` to `bucket/apps/`, run `./upload_splunk_app_to_seaweedfs.sh`. Put the .tgz in the current directory or set `SPLUNK_APP_LOCAL_PATH=/path/to/Splunk_AI_Assistant_Cloud.tgz`. Same endpoint/credentials as above.

### 4. `install_seaweedfs_systemd.sh`
Installs SeaweedFS as a **systemd service** so it starts on boot and restarts on failure. Run this on the host where SeaweedFS should run (e.g. EC2), after the `weed` binary is installed.

**Features:**
- Copies `seaweedfs.service` from this directory into `/etc/systemd/system/`
- Enables and starts the `seaweedfs` service (master, volume, filer, S3 gateway)
- Service runs as `ec2-user` (configurable in the unit file); data directory is `/home/ec2-user/data` by default
- Handles SELinux: on Enforcing systems, labels `/usr/local/bin/weed` so the service can execute it
- Requires the `weed` binary at `/usr/local/bin/weed` (install it first via `upload_to_seaweedfs.sh` or manually from [SeaweedFS releases](https://github.com/seaweedfs/seaweedfs/releases))

**Usage:**
```bash
# 1. Install weed first (e.g. run upload_to_seaweedfs.sh once, or download weed and put it in /usr/local/bin)
# 2. Then install the systemd service (requires sudo)
sudo ./install_seaweedfs_systemd.sh
```

**Prerequisites:**
- `weed` at `/usr/local/bin/weed` (run `./upload_to_seaweedfs.sh` once to auto-install it, or download and extract from GitHub releases)
- Run the script as root: `sudo ./install_seaweedfs_systemd.sh`
- The `seaweedfs.service` unit file must be in the same directory as the script

**After install:**
- **Status:** `sudo systemctl status seaweedfs`
- **Logs:** `journalctl -u seaweedfs -f`
- **Stop:** `sudo systemctl stop seaweedfs`
- **Restart:** `sudo systemctl restart seaweedfs`
- **S3 endpoint:** http://127.0.0.1:8333 (default credentials: minioadmin/minioadmin)
- **Data directory:** `/home/ec2-user/data` (edit the unit file or use a drop-in to change)

**Unit file details (`seaweedfs.service`):**
- `ExecStart`: `/usr/local/bin/weed server -s3 -ip.bind=0.0.0.0 -dir=/home/ec2-user/data -volume.max=100`
- `Restart=on-failure`, `RestartSec=5`
- S3 credentials are set via `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in the unit (default minioadmin/minioadmin); override with `/etc/default/seaweedfs` or a systemd drop-in if needed
- To use a different user or data dir, copy the unit to a drop-in or edit `/etc/systemd/system/seaweedfs.service` after install

**Troubleshooting:** If the service fails to start, check `sudo systemctl status seaweedfs` and `journalctl -u seaweedfs -n 50`. Ensure `/home/ec2-user/data` exists and is writable by `ec2-user`, and that `/usr/local/bin/weed` is executable. On SELinux systems, the script runs `chcon -t bin_t /usr/local/bin/weed` to allow execution.

### 5. `upload_to_minio_aws.sh`
Uploads downloaded artifacts to MinIO using AWS CLI (S3-compatible API).

**Features:**
- Automatically uploads **all artifacts** from `./model_artifacts/` directory
- No config file needed - just uploads everything found
- **Auto-creates bucket** if it doesn't exist
- Uses AWS CLI with S3-compatible API for MinIO
- Comprehensive dependency installation:
  - AWS CLI via **Homebrew on macOS** or **official AWS installer on Linux**
  - Supports macOS (Intel & Apple Silicon) and Linux (amd64 & arm64)
  - Multiple fallback installation methods
- Alternative to `upload_to_minio.sh` (uses AWS CLI instead of mc)

**Usage:**
```bash
./upload_to_minio_aws.sh
```

Or with sudo if dependency installation fails:
```bash
sudo ./upload_to_minio_aws.sh
```

**Prerequisites:**
- Run `download_from_huggingface.sh` first to download artifacts
- May require sudo for installing AWS CLI
- Use generic env vars (MINIO_* accepted for backward compatibility):
  - `S3COMPAT_OBJECT_STORE_ENDPOINT` (default: http://127.0.0.1:9000)
  - `S3COMPAT_OBJECT_STORE_BUCKET` (default: ai-platform-artifacts-bucket)
  - `S3COMPAT_OBJECT_STORE_ACCESS_KEY` (default: minioadmin)
  - `S3COMPAT_OBJECT_STORE_SECRET_KEY` (default: minioadmin)

**When to use this vs `upload_to_minio.sh`:**
- Use this if you prefer AWS CLI over MinIO Client (mc)
- Use this if you already have AWS CLI installed
- Use `upload_to_minio.sh` for better MinIO native support

### 6. `upload_to_s3.sh`
Uploads downloaded artifacts to AWS S3 storage.

**Features:**
- Automatically uploads **all artifacts** from `./model_artifacts/` directory
- No config file needed - just uploads everything found
- **Auto-creates bucket** if it doesn't exist (with proper region configuration)
- Uses AWS CLI with proper credential validation
- Comprehensive dependency installation:
  - AWS CLI via **Homebrew on macOS** or **official AWS installer on Linux**
  - Supports macOS (Intel & Apple Silicon) and Linux (amd64 & arm64)
  - Multiple fallback installation methods
- Validates AWS credentials before upload

**Usage:**
```bash
export S3_BUCKET=your-bucket-name
export S3_REGION=us-east-1  # Optional, defaults to us-east-2
export S3_PREFIX=model_artifacts  # Optional, defaults to 'model_artifacts'
./upload_to_s3.sh
```

Or set inline:
```bash
S3_BUCKET=your-bucket-name S3_REGION=us-west-2 ./upload_to_s3.sh
```

Or with sudo if dependency installation fails:
```bash
sudo S3_BUCKET=your-bucket-name ./upload_to_s3.sh
```

**Prerequisites:**
- Run `download_from_huggingface.sh` first to download artifacts
- May require sudo for installing AWS CLI
- AWS credentials must be configured:
  - AWS CLI configuration (`aws configure`)
  - Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
  - IAM role (if running on AWS infrastructure)
- Set `S3_BUCKET` environment variable
- Optional: Set `S3_REGION` (default: us-east-1) and `S3_PREFIX` (default: model_artifacts)

### 7. `test_minio_connection.sh`
Diagnostic script to test S3-compatible object store connectivity (MinIO, SeaweedFS, etc.) and troubleshoot issues.

**Features:**
- Tests MinIO Client (mc) installation
- Verifies endpoint connectivity
- Tests authentication with credentials
- Lists all existing buckets
- Tests bucket creation permissions
- Provides detailed troubleshooting information

**Usage:**
```bash
./test_minio_connection.sh
```

Or with custom settings (use generic names; MINIO_* also accepted):
```bash
S3COMPAT_OBJECT_STORE_ENDPOINT=http://localhost:9000 S3COMPAT_OBJECT_STORE_BUCKET=nexus ./test_minio_connection.sh
```

Or with sudo if dependency installation fails:
```bash
sudo ./test_minio_connection.sh
```

**Prerequisites:**
- May require sudo for installing MinIO Client (mc)

**When to use:**
- Before running upload scripts for the first time
- When bucket creation fails
- To diagnose object store connectivity issues
- To verify credentials and permissions

## Configuration

The download script uses the `model_artifacts_configs.yaml` configuration file.

### ⚠️ What You Need to Change:

**Only update these fields if you're downloading gated models:**
- `hf-token`: Your Hugging Face API token
  - Get your token from: https://huggingface.co/settings/tokens
  - **Leave as-is for public models**
- `hf-username`: Your Hugging Face username
  - **Only required for gated models**

**✅ Everything else is pre-configured - no changes needed!**

---

### Configuration File Reference (Pre-configured):

**Top-Level Fields:**
- `hf-token`: Hugging Face API token (update only for gated models)
- `hf-username`: Hugging Face username (update only for gated models)

**Artifact Configuration (`artifact-configs`):**

The following models are pre-configured and ready to download:
- `gemma-4-31b-it` - Primary LLM for chat, SPL generation, reasoning
- `gpt-oss-20b` - Secondary LLM
- `all-minilm-l6-v2` - Sentence transformer model
- `bi-encoder` - BGE small encoder
- `cross-encoder` - MS MARCO cross-encoder
- `e5-language-classifier` - Multilingual language detection
- `mbart-translator` - Multilingual translation
- `pii-classifier` - PII detection model
- `uae-large` - UAE embedding model
- `xlm-roberta-language-classifier` - Language classifier

Each artifact includes:
- `artifact-id`: Unique identifier (used as directory/file name)
- `hf-url`: Hugging Face repository URL
- `is-a-gated-model`: Authentication requirement (`true`/`false`)
- `files-to-exclude`: (Optional) Files/patterns to skip during download

**Note:** 
- All artifacts listed in `artifact-configs` will be downloaded by the download script
- The upload script automatically uploads all directories found in `./model_artifacts/` - no config needed!

### Example Configuration Structure:

```yaml
hf-token: "your_hf_token_here"
hf-username: "your_username"

artifact-configs:
  - artifact-id: model-1
    hf-url: "https://huggingface.co/org/model-name"
    is-a-gated-model: false
    files-to-exclude:
      - "*.bin"
      - "test/"
  
  - artifact-id: model-2
    hf-url: "https://huggingface.co/org/gated-model"
    is-a-gated-model: true
  
  - artifact-id: model-3
    hf-url: "https://huggingface.co/org/another-model"
    is-a-gated-model: false
```

All artifacts in the list will be downloaded and uploaded automatically.

## Workflow

1. **Download artifacts from Hugging Face:**
   ```bash
   ./download_from_huggingface.sh
   ```
   This will download all configured artifacts to `./model_artifacts/` directory.
   
   **Note:** The script will:
   - Use memory-optimized cloning to prevent OOM issues
   - Remove existing artifacts before downloading (ensures fresh copies)
   - Stop immediately if any download fails
   - Display detailed error messages if issues occur
   - Validate credentials before attempting gated model downloads
   
   **For large models on cloud instances:**
   - Monitor memory usage: `watch -n 1 free -h` (in another terminal)
   - If script gets killed (OOM), see the **Troubleshooting** section below
   - Consider adding swap space before downloading (especially for 70B+ models)

2. **Upload to storage** (choose one or more):

   **Option A - Upload to MinIO (using MinIO Client):**
   ```bash
   ./upload_to_minio.sh
   ```
   
   **Option B - Upload to MinIO (using AWS CLI):**
   ```bash
   ./upload_to_minio_aws.sh
   ```
   
   **Option C - Upload to AWS S3:**
   ```bash
   export S3_BUCKET=your-bucket-name
   ./upload_to_s3.sh
   ```
   
   You can run multiple scripts to upload to different destinations!

## Environment Variables

### For Download Script:
- No additional environment variables needed (reads from `model_artifacts_configs.yaml`)

### For MinIO / S3-compatible Upload Script (using mc, `upload_to_minio.sh`):
- No config file needed - automatically uploads all artifacts from `./model_artifacts/`
- Works with MinIO, SeaweedFS, or any S3-compatible backend.
- **Preferred (generic):** `S3COMPAT_OBJECT_STORE_ENDPOINT`, `S3COMPAT_OBJECT_STORE_BUCKET`, `S3COMPAT_OBJECT_STORE_ACCESS_KEY`, `S3COMPAT_OBJECT_STORE_SECRET_KEY`
- **Backward compatibility:** `MINIO_ENDPOINT`, `MINIO_BUCKET`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` (or `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY`)
- Defaults: endpoint http://127.0.0.1:9000, bucket ai-platform-bucket, minioadmin/minioadmin

### For S3-compatible Upload Script (using AWS CLI, `upload_to_minio_aws.sh`):
- No config file needed - automatically uploads all artifacts from `./model_artifacts/`
- **Preferred (generic):** `S3COMPAT_OBJECT_STORE_ENDPOINT`, `S3COMPAT_OBJECT_STORE_BUCKET`, `S3COMPAT_OBJECT_STORE_ACCESS_KEY`, `S3COMPAT_OBJECT_STORE_SECRET_KEY`
- **Backward compatibility:** `MINIO_ENDPOINT`, `MINIO_BUCKET`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` (or `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`)
- Defaults: endpoint http://127.0.0.1:9000, bucket ai-platform-artifacts-bucket, minioadmin/minioadmin

### For S3 Upload Script:
- No config file needed - automatically uploads all artifacts from `./model_artifacts/`
- `S3_BUCKET`: (Required) Target S3 bucket name
- `S3_REGION`: AWS region (default: us-east-1)
- `S3_PREFIX`: Path prefix in bucket (default: model_artifacts)
- AWS credentials via:
  - `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
  - AWS CLI configuration (`~/.aws/credentials`)
  - IAM role (for EC2/ECS/Lambda)

## Notes

- The download script creates a `./model_artifacts/` directory and downloads artifacts based on `model_artifacts_configs.yaml`
- **Memory optimization**: The script uses shallow cloning and separate LFS downloads to minimize memory usage, making it suitable for cloud instances with limited RAM
- **Re-download behavior**: If an artifact already exists, it will be automatically removed and re-downloaded to ensure fresh copies
- **Error handling**: The script fails immediately on any error and provides detailed error messages for troubleshooting
- All upload scripts are config-free - they simply upload **everything** found in `./model_artifacts/` directory
- **Buckets are automatically created** if they don't exist:
  - MinIO: Creates bucket using `mc mb` command
  - S3: Creates bucket with appropriate region configuration
- **Bucket names are automatically normalized** to lowercase:
  - MinIO/S3 require lowercase bucket names
  - Scripts automatically convert names like "Nexus" to "nexus"
  - Warning displayed if bucket name contains invalid characters
- This means you can manually place any additional artifacts in `./model_artifacts/` and they will be uploaded
- You can upload to both MinIO and S3 if needed - just run both upload scripts
- All scripts support macOS (Darwin) and Linux environments
- Dependencies are automatically installed if missing:
  - **Download script**: wget, yq, git-lfs (Note: Python 3 is required but must be manually installed)
  - **MinIO upload script (mc)**: MinIO Client (mc) - native client for MinIO
  - **MinIO upload script (AWS CLI)**: AWS CLI - S3-compatible API for MinIO
  - **S3 upload script**: AWS CLI - official AWS command line tool
- Architecture support: Intel/AMD64 and ARM64 (Apple Silicon, AWS Graviton, etc.)
- The original combined script is retained for backwards compatibility

## Troubleshooting

### Out of Memory (OOM) Issues on EC2/Cloud Instances

If the download script gets killed with messages like `Killed` or `line 298: 28141 Killed`, this indicates the system ran out of memory during large model downloads.

**The script now includes memory optimizations** that should prevent most OOM issues:
- Shallow cloning with `--depth 1 --single-branch`
- Separate LFS file download using `GIT_LFS_SKIP_SMUDGE=1`
- Downloads LFS files one at a time instead of all at once

However, for **very large models** (like 70B parameter models) on small instances, you may still need additional steps:

#### Solution 1: Add Swap Space (Recommended)

Create a swap file to supplement RAM:

```bash
# Create 8GB swap file
sudo dd if=/dev/zero of=/swapfile bs=1G count=8
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Verify swap is active
free -h

# Make swap permanent (optional)
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

#### Solution 2: Increase Instance Size

For downloading 70B+ parameter models, consider:
- **Minimum recommended**: 8GB RAM (t3.large, t3a.large)
- **Recommended for multiple large models**: 16GB+ RAM (r6i.xlarge, r6a.xlarge)
- Check current memory: `free -h`
- Monitor memory during download: `watch -n 1 free -h`

#### Solution 3: Download Models Selectively

Edit `model_artifacts_configs.yaml` to comment out models and download them one at a time:

```yaml
artifact-configs:
  # Download one model at a time
  - artifact-id: llama31-70b-instruct-awq
    hf-url: https://huggingface.co/hugging-quants/Meta-Llama-3.1-70B-Instruct-AWQ-INT4
    is-a-gated-model: false
  
  # Uncomment others after first completes
  # - artifact-id: all-minilm-l6-v2
  #   hf-url: https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
  #   is-a-gated-model: false
```

#### What is GIT_LFS_SKIP_SMUDGE?

The script uses `GIT_LFS_SKIP_SMUDGE=1` to optimize memory usage:

- **Normal git clone**: Downloads all LFS files during clone (10-20+ GB in memory)
- **With GIT_LFS_SKIP_SMUDGE**: 
  1. Clone only downloads small pointer files (~200 bytes each)
  2. Large files are downloaded separately with `git lfs pull`
  3. Files stream directly to disk without loading into memory

This prevents OOM kills by keeping memory usage low throughout the download process.

### Other Common Issues

#### Git LFS Installation Failed
If git-lfs installation fails, manually install it:
- **macOS**: `brew install git-lfs`
- **Ubuntu/Debian**: `sudo apt-get install git-lfs`
- **RHEL/CentOS**: `sudo yum install git-lfs`

Then run: `git lfs install`

#### Gated Model Access Denied
- Ensure you have accepted the model license on Hugging Face
- Verify your HF token has correct permissions
- Check token at: https://huggingface.co/settings/tokens

## Dependency Installation Methods

### Download Script Dependencies:
- **Python 3** (required, must be manually installed if not present):
  - macOS: `brew install python3` or download from https://www.python.org/downloads/
  - Ubuntu/Debian: `sudo apt-get install python3`
  - RHEL/CentOS: `sudo yum install python3`
  - Fedora: `sudo dnf install python3`
- wget, yq, git-lfs (automatically installed based on OS)

### MinIO Upload Script Dependencies:
Installs MinIO Client (mc):

1. **macOS**:
   - **Homebrew** (recommended for macOS): `brew install minio/stable/mc`
   - Direct download fallback: Downloads appropriate binary (Intel or Apple Silicon)
   - Installs to `/usr/local/bin/mc`

2. **Linux**:
   - **Direct download** (Homebrew is NOT used on Linux)
   - Downloads appropriate binary (amd64 or arm64)
   - Installs to `/usr/local/bin/mc` (with sudo) or `~/.local/bin/mc` (without sudo)
   - Provides manual installation instructions if all methods fail

### S3 Upload Script Dependencies:
Installs AWS CLI:

1. **macOS**:
   - **Homebrew** (recommended for macOS): `brew install awscli`
   - Official installer fallback: Downloads and installs AWSCLIV2.pkg

2. **Linux**:
   - **Official AWS installer** (Homebrew is NOT used on Linux)
   - Downloads appropriate binary (amd64 or arm64)
   - Installs to `/usr/local/aws-cli` (with sudo) or `~/.local/aws-cli` (without sudo)
   - Requires unzip utility (auto-installed if missing)

