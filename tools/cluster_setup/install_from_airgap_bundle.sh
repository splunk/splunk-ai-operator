#!/usr/bin/env bash
# install_from_airgap_bundle.sh
# Run on the air-gapped install machine (needs kubectl/helm/ssh pre-installed,
# but NO outbound internet). Extracts the bundle produced by
# prepare_airgap_bundle.sh, sets environment-variable overrides, then invokes
# k0s_cluster_with_stack.sh.
#
# Usage:
#   ./install_from_airgap_bundle.sh --bundle airgap-bundle-<date>.tar.gz \
#       --config my-cluster-config.yaml [--extract-dir /opt/airgap]
#
# The installer (k0s_cluster_with_stack.sh) must be in the same directory as
# this script, or pass --installer /path/to/k0s_cluster_with_stack.sh.

set -euo pipefail

BUNDLE_TARBALL=""
CONFIG_FILE=""
EXTRACT_DIR="${EXTRACT_DIR:-/opt/airgap}"
INSTALLER_SCRIPT=""
SUBCOMMAND="${SUBCOMMAND:-install}"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)      BUNDLE_TARBALL="$2"; shift 2 ;;
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --extract-dir) EXTRACT_DIR="$2"; shift 2 ;;
    --installer)   INSTALLER_SCRIPT="$2"; shift 2 ;;
    --subcommand)  SUBCOMMAND="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELP'
install_from_airgap_bundle.sh — extract an air-gap bundle and run the
Splunk AI Platform installer with no outbound internet required.

USAGE
  ./install_from_airgap_bundle.sh --bundle BUNDLE.tar.gz [OPTIONS]

REQUIRED
  --bundle FILE         Path to the tar.gz produced by prepare_airgap_bundle.sh.

OPTIONS
  --config FILE         Path to your k0s-cluster-config.yaml.
                        If omitted, the installer looks for CONFIG_FILE in the
                        environment or its default location.

  --extract-dir DIR     Directory where the bundle is extracted.
                        Default: /opt/airgap
                        Env: EXTRACT_DIR

  --installer SCRIPT    Path to k0s_cluster_with_stack.sh.
                        Default: same directory as this script.

  --subcommand CMD      Installer subcommand to run: install | join-workers
                        Default: install
                        Env: SUBCOMMAND

  -h, --help            Show this help text.

WHAT THIS SCRIPT DOES
  1. Extracts the bundle into --extract-dir.
  2. Verifies SHA-256 checksums of all bundled files.
  3. Installs the bundled k0s binary to /usr/local/bin/k0s (if not already present).
  4. Installs the bundled yq binary to /usr/local/bin/yq (if not already present).
  5. Registers a local Helm chart repository pointing at the bundled .tgz files.
  6. Exports the following environment variables so k0s_cluster_with_stack.sh
     uses local files instead of downloading from the internet:

     K0S_INSTALL_URL                   → file://<bundle>/binaries/k0s
     YQ_DOWNLOAD_URL                   → file://<bundle>/binaries/yq
     CERT_MANAGER_MANIFEST_URL         → file://<bundle>/manifests/cert-manager.yaml
     LOCAL_PATH_MANIFEST_URL           → file://<bundle>/manifests/local-path-storage.yaml
     NVIDIA_DEVICE_PLUGIN_MANIFEST_URL → file://<bundle>/manifests/nvidia-device-plugin.yml
     PROMETHEUS_CHART_PATH             → <bundle>/charts/kube-prometheus-stack-*.tgz
     OTEL_CHART_PATH                   → <bundle>/charts/opentelemetry-operator-*.tgz
     KUBERAY_CHART_PATH                → <bundle>/charts/kuberay-operator-*.tgz
     METALLB_CHART_PATH                → <bundle>/charts/metallb-*.tgz
     AIRGAP_PYYAML_WHEEL_PATH          → <bundle>/packages/PyYAML-*.whl (or .tar.gz)
     AIRGAP_MODE                       → true

  7. Invokes k0s_cluster_with_stack.sh <subcommand>.

NOTE ON GPU NODE PACKAGES
  The bundle contains OS package files under packages/:
    - epel-release-latest-<N>.noarch.rpm
    - cuda-<os>.repo
    - nvidia-container-toolkit.repo
    - PyYAML-*.whl (or .tar.gz)

  install_from_airgap_bundle.sh does NOT automatically SCP these to GPU nodes
  because the GPU node IPs and SSH credentials are defined in the cluster config,
  which is loaded by k0s_cluster_with_stack.sh itself. Instead:

  Option A (recommended): pre-install NVIDIA drivers + nvidia-container-toolkit
    on GPU nodes before running this script.  The installer detects and skips
    driver installation if nvidia-smi is already present.

  Option B: use the packages/ files to set up a local RPM mirror, then set
    EPEL_RPM_URL_OVERRIDE / CUDA_REPO_URL_OVERRIDE / NVIDIA_CTK_REPO_URL_OVERRIDE
    to point at that mirror before running this script.

  See AIRGAP.md → 'GPU Node OS Packages' for full step-by-step instructions.

PREREQUISITES ON THIS MACHINE (no internet needed)
  kubectl, helm, tar, ssh — must be pre-installed.
  The installer will use the bundled k0s and yq binaries.

EXAMPLES
  # Minimal — config in current directory
  ./install_from_airgap_bundle.sh --bundle airgap-bundle-20260612-103000.tar.gz

  # Explicit config and extract path
  ./install_from_airgap_bundle.sh \
    --bundle /mnt/transfer/airgap-bundle-20260612-103000.tar.gz \
    --config /etc/splunk-ai/my-cluster-config.yaml \
    --extract-dir /opt/airgap

  # Re-join workers after a failed or partial install
  ./install_from_airgap_bundle.sh \
    --bundle airgap-bundle-20260612-103000.tar.gz \
    --config my-cluster-config.yaml \
    --subcommand join-workers

MANUAL USE (advanced)
  If you extracted the bundle yourself and want to run the installer directly,
  source the env-var file from the bundle then call the installer:

    export AIRGAP_BUNDLE_DIR=/opt/airgap/airgap-bundle-20260612-103000
    source "${AIRGAP_BUNDLE_DIR}/airgap-env.sh"
    CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install

HELP
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2
       echo "Run with --help for usage." >&2
       exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN  $*" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required tool not found: $1 — install it on this machine before running."
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
[[ -n "${BUNDLE_TARBALL}" ]] || err "No bundle specified. Use --bundle airgap-bundle-<date>.tar.gz"
[[ -f "${BUNDLE_TARBALL}" ]] || err "Bundle file not found: ${BUNDLE_TARBALL}"

require_cmd tar
require_cmd helm
require_cmd kubectl

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${INSTALLER_SCRIPT}" ]]; then
  INSTALLER_SCRIPT="${SCRIPT_DIR}/k0s_cluster_with_stack.sh"
fi
[[ -f "${INSTALLER_SCRIPT}" ]] || err "Installer not found: ${INSTALLER_SCRIPT}. Pass --installer /path/to/k0s_cluster_with_stack.sh"
[[ -x "${INSTALLER_SCRIPT}" ]] || chmod +x "${INSTALLER_SCRIPT}"

log "=== Splunk AI Platform — Air-Gap Installation ==="
log "Bundle          : ${BUNDLE_TARBALL}"
log "Extract dir     : ${EXTRACT_DIR}"
log "Installer       : ${INSTALLER_SCRIPT}"
log "Subcommand      : ${SUBCOMMAND}"
[[ -n "${CONFIG_FILE}" ]] && log "Config          : ${CONFIG_FILE}"
log ""

# ── Extract bundle ────────────────────────────────────────────────────────────
log "Extracting bundle..."
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${BUNDLE_TARBALL}" -C "${EXTRACT_DIR}"

# Find the extracted bundle directory (named airgap-bundle-<timestamp>)
BUNDLE_DIR="$(find "${EXTRACT_DIR}" -maxdepth 1 -mindepth 1 -type d -name 'airgap-bundle-*' | sort | tail -1)"
[[ -n "${BUNDLE_DIR}" ]] || err "Could not find extracted bundle directory in ${EXTRACT_DIR}"
log "Bundle extracted to: ${BUNDLE_DIR}"

# ── Verify checksums ──────────────────────────────────────────────────────────
if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
  log "Verifying checksums..."
  (
    cd "${BUNDLE_DIR}"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum --check checksums.sha256 --quiet
    else
      shasum -a 256 --check checksums.sha256 --quiet
    fi
  ) || err "Checksum verification failed — bundle may be corrupt or tampered with."
  log "Checksums verified OK"
else
  warn "sha256sum / shasum not found — skipping checksum verification"
fi

# ── Read version manifest ─────────────────────────────────────────────────────
VERSION_FILE="${BUNDLE_DIR}/bundle-versions.txt"
[[ -f "${VERSION_FILE}" ]] || err "bundle-versions.txt missing from bundle — bundle is incomplete."

get_version() {
  grep "^${1}=" "${VERSION_FILE}" | cut -d= -f2
}

K0S_VERSION="$(get_version k0s_version)"
KUBERAY_CHART_VERSION="$(get_version kuberay_chart_version)"
METALLB_CHART_VERSION="$(get_version metallb_chart_version)"
PROMETHEUS_CHART_VERSION="$(get_version prometheus_chart_version)"
OTEL_CHART_VERSION="$(get_version otel_chart_version)"

log "Bundle component versions:"
log "  k0s         : ${K0S_VERSION}"
log "  kuberay     : ${KUBERAY_CHART_VERSION}"
log "  metallb     : ${METALLB_CHART_VERSION}"
log "  prometheus  : ${PROMETHEUS_CHART_VERSION}"
log "  otel        : ${OTEL_CHART_VERSION}"

# ── Install bundled k0s binary into PATH for node provisioning ────────────────
log "Installing bundled k0s binary to /usr/local/bin/k0s ..."
if [[ -f "${BUNDLE_DIR}/binaries/k0s" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    cp "${BUNDLE_DIR}/binaries/k0s" /usr/local/bin/k0s
    chmod +x /usr/local/bin/k0s
  else
    sudo cp "${BUNDLE_DIR}/binaries/k0s" /usr/local/bin/k0s
    sudo chmod +x /usr/local/bin/k0s
  fi
  log "k0s ${K0S_VERSION} installed to /usr/local/bin/k0s"
else
  warn "k0s binary not found in bundle — ensure k0s is pre-installed on all nodes."
fi

# Install yq if not present
if ! command -v yq >/dev/null 2>&1; then
  log "Installing bundled yq binary..."
  if [[ "$(id -u)" -eq 0 ]]; then
    cp "${BUNDLE_DIR}/binaries/yq" /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
  else
    sudo cp "${BUNDLE_DIR}/binaries/yq" /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
  fi
  log "yq installed to /usr/local/bin/yq"
fi

# ── Set up local Helm chart repository ───────────────────────────────────────
log "Registering local Helm chart repository..."
LOCAL_CHARTS_DIR="${BUNDLE_DIR}/charts"
helm repo add airgap-charts "file://${LOCAL_CHARTS_DIR}" 2>/dev/null || \
  helm repo add airgap-charts "file://${LOCAL_CHARTS_DIR}"

# Helm needs an index file for the local repo to work with `helm install REPO/chart`.
# Build one from the .tgz files present.
helm repo index "${LOCAL_CHARTS_DIR}" --url "file://${LOCAL_CHARTS_DIR}" 2>/dev/null || true
helm repo update airgap-charts 2>/dev/null || true

# ── Export env-var overrides read by k0s_cluster_with_stack.sh ───────────────
# The main installer respects these vars via ${VAR:-default} patterns.
export AIRGAP_BUNDLE_DIR="${BUNDLE_DIR}"

# Binaries
export K0S_INSTALL_URL="file://${BUNDLE_DIR}/binaries/k0s"
export YQ_DOWNLOAD_URL="file://${BUNDLE_DIR}/binaries/yq"

# Static manifests
export CERT_MANAGER_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/local-path-storage.yaml"
export NVIDIA_DEVICE_PLUGIN_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/nvidia-device-plugin.yml"

# Helm chart paths — installer uses these instead of remote repos.
# helm pull sometimes produces underscores instead of dashes in the filename,
# so resolve via glob; fail fast if the chart is genuinely missing.
_resolve_chart() {
  local pattern="$1" label="$2"
  # shellcheck disable=SC2206
  local matches=( ${pattern} )
  if [[ ${#matches[@]} -eq 0 || ! -f "${matches[0]}" ]]; then
    err "Chart not found for ${label} (expected: ${pattern}). Bundle may be corrupt or version-mismatched."
  fi
  echo "${matches[0]}"
}

PROM_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/kube-prometheus-stack-${PROMETHEUS_CHART_VERSION}*.tgz" "kube-prometheus-stack")"
OTEL_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/opentelemetry-operator-${OTEL_CHART_VERSION}*.tgz" "opentelemetry-operator")"
KUBERAY_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/kuberay-operator-${KUBERAY_CHART_VERSION}*.tgz" "kuberay-operator")"
METALLB_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/metallb-${METALLB_CHART_VERSION}*.tgz" "metallb")"

export PROMETHEUS_CHART_PATH="${PROM_TGZ}"
export OTEL_CHART_PATH="${OTEL_TGZ}"
export KUBERAY_CHART_PATH="${KUBERAY_TGZ}"
export METALLB_CHART_PATH="${METALLB_TGZ}"

# GPU node OS packages — pyyaml wheel path for offline pip3 install on all nodes
PYYAML_FNAME=""
[[ -f "${BUNDLE_DIR}/packages/pyyaml.filename" ]] && \
  PYYAML_FNAME="$(cat "${BUNDLE_DIR}/packages/pyyaml.filename")"
if [[ -n "${PYYAML_FNAME}" && -f "${BUNDLE_DIR}/packages/${PYYAML_FNAME}" ]]; then
  export AIRGAP_PYYAML_WHEEL_PATH="${BUNDLE_DIR}/packages/${PYYAML_FNAME}"
  log "PyYAML wheel found: ${AIRGAP_PYYAML_WHEEL_PATH}"
else
  log "No PyYAML wheel in bundle — nodes will fall back to OS package manager for pyyaml."
fi

# Disable helm repo add/update calls inside the installer — all charts are local
export AIRGAP_MODE="true"

log ""
log "Environment overrides set. Launching installer..."
log ""

# ── Invoke main installer ─────────────────────────────────────────────────────
INSTALLER_CMD="${INSTALLER_SCRIPT} ${SUBCOMMAND}"
if [[ -n "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="$(realpath "${CONFIG_FILE}")"
  exec env CONFIG_FILE="${CONFIG_FILE}" ${INSTALLER_CMD}
else
  log "No --config supplied. The installer will look for CONFIG_FILE in the environment"
  log "or its default location. Set CONFIG_FILE if it is not in the current directory."
  exec ${INSTALLER_CMD}
fi
