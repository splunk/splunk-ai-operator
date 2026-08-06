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
CONFIG_FILE="${CONFIG_FILE:-}"
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
     TRAEFIK_MANIFEST_DIR              → <bundle>/manifests/traefik
     PROMETHEUS_CHART_PATH             → <bundle>/charts/kube-prometheus-stack-*.tgz
     OTEL_CHART_PATH                   → <bundle>/charts/opentelemetry-operator-*.tgz
     KUBERAY_CHART_PATH                → <bundle>/charts/kuberay-operator-*.tgz
     METALLB_CHART_PATH                → <bundle>/charts/metallb-*.tgz
     AIRGAP_PYYAML_WHEEL_PATH          → <bundle>/packages/PyYAML-*.whl (or .tar.gz)
     AIRGAP_K0S_IMAGE_DIR              → <bundle>/images
     AIRGAP_BUNDLE_VERSION_FILE        → <bundle>/bundle-versions.txt
     BUNDLE_CERT_MANAGER_VERSION       → verified bundle cert-manager version
     BUNDLE_INGRESS_ENABLED            → verified bundle ingress setting
     BUNDLE_TRAEFIK_IMAGE              → verified bundled Traefik image
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

require_version_key() {
  local key="$1" occurrences
  occurrences="$(grep -c "^${key}=" "${VERSION_FILE}" || true)"
  [[ "${occurrences}" == "1" ]] || \
    err "bundle-versions.txt must contain exactly one ${key}= entry (found ${occurrences})"
}

get_version() {
  local key="$1"
  require_version_key "${key}"
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${VERSION_FILE}"
}

get_required_version() {
  local key="$1" value
  value="$(get_version "${key}")"
  [[ -n "${value}" ]] || err "bundle-versions.txt contains an empty ${key}= value"
  printf '%s\n' "${value}"
}

K0S_VERSION="$(get_required_version k0s_version)"
CERT_MANAGER_VERSION="$(get_required_version cert_manager_version)"
KUBERAY_CHART_VERSION="$(get_required_version kuberay_chart_version)"
METALLB_CHART_VERSION="$(get_required_version metallb_chart_version)"
PROMETHEUS_CHART_VERSION="$(get_required_version prometheus_chart_version)"
OTEL_CHART_VERSION="$(get_required_version otel_chart_version)"
BUNDLE_INGRESS_ENABLED="$(get_required_version ingress_enabled)"
BUNDLE_TRAEFIK_IMAGE="$(get_version traefik_image)"

EXPECTED_CERT_MANAGER_VERSION="v1.21.1"
[[ "${CERT_MANAGER_VERSION}" == "${EXPECTED_CERT_MANAGER_VERSION}" ]] || \
  err "Bundle cert-manager version ${CERT_MANAGER_VERSION:-missing} does not match installer requirement ${EXPECTED_CERT_MANAGER_VERSION}"
[[ "${BUNDLE_INGRESS_ENABLED}" == "true" || "${BUNDLE_INGRESS_ENABLED}" == "false" ]] || \
  err "Bundle ingress_enabled must be true or false, got: ${BUNDLE_INGRESS_ENABLED}"
if [[ "${BUNDLE_INGRESS_ENABLED}" == "true" ]]; then
  [[ -n "${BUNDLE_TRAEFIK_IMAGE}" ]] || \
    err "Bundle enables ingress but bundle-versions.txt has an empty traefik_image value"
fi

# Validate the independently written k0s version marker before copying any
# binary to the host. A mismatch means the bundle cannot prove which Kubernetes
# release it will install.
K0S_VERSION_FILE="${BUNDLE_DIR}/binaries/k0s.version"
[[ -s "${K0S_VERSION_FILE}" ]] || \
  err "Air-gap bundle is missing binaries/k0s.version; refusing an unversioned Kubernetes install"
BINARY_K0S_VERSION="$(tr -d '\r\n' < "${K0S_VERSION_FILE}")"
[[ "${BINARY_K0S_VERSION}" == "${K0S_VERSION}" ]] || \
  err "Bundle version mismatch: bundle-versions.txt says ${K0S_VERSION}, binaries/k0s.version says ${BINARY_K0S_VERSION:-empty}"

BUNDLED_K0S="${BUNDLE_DIR}/binaries/k0s"
BUNDLED_YQ="${BUNDLE_DIR}/binaries/yq"
[[ -f "${BUNDLED_K0S}" ]] || err "Bundled k0s binary is missing: ${BUNDLED_K0S}"
[[ -f "${BUNDLED_YQ}" ]] || err "Bundled yq binary is missing: ${BUNDLED_YQ}"
[[ -x "${BUNDLED_YQ}" ]] || err "Bundled yq binary is not executable: ${BUNDLED_YQ}"

# The validation below is deliberately completed before k0s or yq is copied to
# /usr/local/bin. A host yq is convenient, but the verified bundled binary is a
# mutation-free fallback on a minimal offline host.
if command -v yq >/dev/null 2>&1; then
  CONFIG_YQ="$(command -v yq)"
else
  CONFIG_YQ="${BUNDLED_YQ}"
fi

log "Bundle component versions:"
log "  k0s         : ${K0S_VERSION}"
log "  cert-manager: ${CERT_MANAGER_VERSION}"
log "  kuberay     : ${KUBERAY_CHART_VERSION}"
log "  metallb     : ${METALLB_CHART_VERSION}"
log "  prometheus  : ${PROMETHEUS_CHART_VERSION}"
log "  otel        : ${OTEL_CHART_VERSION}"
log "  ingress     : ${BUNDLE_INGRESS_ENABLED:-false}"

# The add-on image bundle is built from one concrete cluster config. Refuse an
# offline install that enables Traefik with a different/not-bundled image,
# otherwise containerd cannot satisfy that pull and the DaemonSet fails later
# with an opaque ImagePullBackOff.
EFFECTIVE_CONFIG_FILE="${CONFIG_FILE:-$(cd "$(dirname "${INSTALLER_SCRIPT}")" && pwd)/k0s-cluster-config.yaml}"
[[ -f "${EFFECTIVE_CONFIG_FILE}" ]] || \
  err "Cluster config not found: ${EFFECTIVE_CONFIG_FILE}; pass --config explicitly"
INSTALL_INGRESS_ENABLED="$("${CONFIG_YQ}" eval -r '.ingress.enabled // false' "${EFFECTIVE_CONFIG_FILE}")" || \
  err "Unable to read ingress.enabled from ${EFFECTIVE_CONFIG_FILE}"
[[ "${INSTALL_INGRESS_ENABLED}" == "true" || "${INSTALL_INGRESS_ENABLED}" == "false" ]] || \
  err "ingress.enabled in ${EFFECTIVE_CONFIG_FILE} must be true or false"
if [[ "${INSTALL_INGRESS_ENABLED}" == "true" ]]; then
  DEFAULT_TRAEFIK_IMAGE="docker.io/library/traefik:v3.6.25@sha256:31267173a15b4944e797a76ffd9c419707c8d8b32fe5b610f80cd0cfa05f372d"
  INSTALL_TRAEFIK_IMAGE="$("${CONFIG_YQ}" eval -r ".images.ingress.traefikImage // \"${DEFAULT_TRAEFIK_IMAGE}\"" \
    "${EFFECTIVE_CONFIG_FILE}")" || err "Unable to read the configured Traefik image"
  [[ -n "${INSTALL_TRAEFIK_IMAGE}" && "${INSTALL_TRAEFIK_IMAGE}" != "null" ]] || \
    err "ingress.enabled=true requires a non-empty images.ingress.traefikImage"
  [[ "${BUNDLE_INGRESS_ENABLED}" == "true" ]] || \
    err "Install config enables Traefik, but this bundle was built without --config ingress enabled"
  [[ "${BUNDLE_TRAEFIK_IMAGE}" == "${INSTALL_TRAEFIK_IMAGE}" ]] || \
    err "Traefik image mismatch: bundle contains ${BUNDLE_TRAEFIK_IMAGE:-none}, install config requires ${INSTALL_TRAEFIK_IMAGE}"
fi

# No bundle/config incompatibility remains. Host mutation starts below.
[[ -x "${INSTALLER_SCRIPT}" ]] || chmod +x "${INSTALLER_SCRIPT}"

# ── Install bundled k0s binary into PATH for node provisioning ────────────────
log "Installing bundled k0s binary to /usr/local/bin/k0s ..."
if [[ "$(id -u)" -eq 0 ]]; then
  cp "${BUNDLED_K0S}" /usr/local/bin/k0s
  chmod +x /usr/local/bin/k0s
else
  sudo cp "${BUNDLED_K0S}" /usr/local/bin/k0s
  sudo chmod +x /usr/local/bin/k0s
fi
log "k0s ${K0S_VERSION} installed to /usr/local/bin/k0s"

# Install yq if not present
if ! command -v yq >/dev/null 2>&1; then
  log "Installing bundled yq binary..."
  if [[ "$(id -u)" -eq 0 ]]; then
    cp "${BUNDLED_YQ}" /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
  else
    sudo cp "${BUNDLED_YQ}" /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
  fi
  log "yq installed to /usr/local/bin/yq"
fi

# ── Set up local Helm chart repository (best-effort convenience only) ─────────
# NOTE: The main installer (k0s_cluster_with_stack.sh) installs every chart by
# ABSOLUTE PATH via the *_CHART_PATH env vars exported below — it never references
# this "airgap-charts" repo. Registration is therefore purely optional convenience.
#
# Modern Helm (v3.7+) dropped support for "file://" as a `helm repo add` protocol
# ("Error: could not find protocol handler for: file"). Since the repo is unused,
# we make the whole block strictly non-fatal so it cannot abort the install under
# `set -euo pipefail` on a host with a newer Helm.
log "Registering local Helm chart repository (optional; charts install by path)..."
LOCAL_CHARTS_DIR="${BUNDLE_DIR}/charts"
helm repo index "${LOCAL_CHARTS_DIR}" --url "file://${LOCAL_CHARTS_DIR}" >/dev/null 2>&1 || true
if helm repo add airgap-charts "file://${LOCAL_CHARTS_DIR}" >/dev/null 2>&1; then
  helm repo update airgap-charts >/dev/null 2>&1 || true
else
  log "  Helm rejected file:// repo (expected on Helm 3.7+); charts will install by path — no action needed."
fi

# ── Export env-var overrides read by k0s_cluster_with_stack.sh ───────────────
# The main installer respects these vars via ${VAR:-default} patterns.
export AIRGAP_BUNDLE_DIR="${BUNDLE_DIR}"
export AIRGAP_BUNDLE_VERSION_FILE="${VERSION_FILE}"
export BUNDLE_K0S_VERSION="${K0S_VERSION}"
export BUNDLE_CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION}"
export BUNDLE_INGRESS_ENABLED
export BUNDLE_TRAEFIK_IMAGE

# Binaries
export K0S_INSTALL_URL="file://${BUNDLE_DIR}/binaries/k0s"
export K0S_VERSION
export YQ_DOWNLOAD_URL="file://${BUNDLE_DIR}/binaries/yq"

# Pre-loaded container-image bundles (OCI tarballs). The installer scp's EVERY
# *.tar in this directory to each node's /var/lib/k0s/images/, where k0s
# auto-imports all of them into containerd at startup — covering both k0s
# control-plane images (k0s-images.tar: pause/calico/kube-proxy/coredns/…) AND
# add-on component images (addon-images.tar: cert-manager/prometheus/metallb/…).
# This removes the need to pull from quay.io/ghcr.io/etc. over a blocked link.
export AIRGAP_K0S_IMAGE_DIR="${BUNDLE_DIR}/images"
if compgen -G "${AIRGAP_K0S_IMAGE_DIR}/*.tar" >/dev/null 2>&1; then
  log "Pre-loaded image bundles found in: ${AIRGAP_K0S_IMAGE_DIR}"
  for _t in "${BUNDLE_DIR}/images"/*.tar; do log "  - $(basename "${_t}") ($(du -h "${_t}" | cut -f1))"; done
else
  warn "No pre-loaded image bundles in air-gap bundle (images/*.tar) — k0s control-plane AND add-on images may fail to pull on air-gapped nodes."
fi

# Static manifests
export CERT_MANAGER_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/local-path-storage.yaml"
export NVIDIA_DEVICE_PLUGIN_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/nvidia-device-plugin.yml"
if [[ -f "${BUNDLE_DIR}/manifests/traefik/traefik-crds.yaml" && \
      -f "${BUNDLE_DIR}/manifests/traefik/traefik-rbac.yaml" ]]; then
  export TRAEFIK_MANIFEST_DIR="${BUNDLE_DIR}/manifests/traefik"
else
  # Compatibility with bundles built before the manifests were embedded. A
  # full repository checkout still has them beside the installer; ingress-off
  # installs do not consume them at all.
  TRAEFIK_MANIFEST_DIR="$(cd "$(dirname "${INSTALLER_SCRIPT}")" && pwd)/traefik"
  export TRAEFIK_MANIFEST_DIR
  warn "Bundle has no embedded Traefik manifests; falling back to ${TRAEFIK_MANIFEST_DIR}"
fi

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
INSTALLER_CMD=("${INSTALLER_SCRIPT}" "${SUBCOMMAND}")
if [[ -n "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="$(realpath "${CONFIG_FILE}")"
  exec env CONFIG_FILE="${CONFIG_FILE}" "${INSTALLER_CMD[@]}"
else
  log "No --config supplied. The installer will look for CONFIG_FILE in the environment"
  log "or its default location. Set CONFIG_FILE if it is not in the current directory."
  exec "${INSTALLER_CMD[@]}"
fi
