#!/usr/bin/env bash
# install_from_airgap_bundle_openshift.sh
# Run on the air-gapped OpenShift install machine (needs oc + helm pre-installed,
# but NO outbound internet). Extracts the bundle produced by
# prepare_airgap_bundle_openshift.sh, sets environment-variable overrides, then
# invokes openshift_with_stack.sh.
#
# Usage:
#   ./install_from_airgap_bundle_openshift.sh \
#       --bundle airgap-bundle-openshift-<date>.tar.gz \
#       --config openshift-cluster-config.yaml [--extract-dir /opt/airgap]
#
# The installer (openshift_with_stack.sh) must be in the same directory as
# this script, or pass --installer /path/to/openshift_with_stack.sh.

set -euo pipefail

BUNDLE_TARBALL=""
CONFIG_FILE=""
EXTRACT_DIR="${EXTRACT_DIR:-/opt/airgap}"
INSTALLER_SCRIPT=""
SUBCOMMAND="${SUBCOMMAND:-install}"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)      BUNDLE_TARBALL="$2"; shift 2 ;;
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --extract-dir) EXTRACT_DIR="$2"; shift 2 ;;
    --installer)   INSTALLER_SCRIPT="$2"; shift 2 ;;
    --subcommand)  SUBCOMMAND="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELP'
install_from_airgap_bundle_openshift.sh — extract an OpenShift air-gap bundle
and run the Splunk AI Platform installer with no outbound internet required.

USAGE
  ./install_from_airgap_bundle_openshift.sh --bundle BUNDLE.tar.gz [OPTIONS]

REQUIRED
  --bundle FILE         Path to the tar.gz produced by prepare_airgap_bundle_openshift.sh.

OPTIONS
  --config FILE         Path to your openshift-cluster-config.yaml.
                        If omitted, the installer looks for CONFIG_FILE in the
                        environment or its default location.

  --extract-dir DIR     Directory where the bundle is extracted.
                        Default: /opt/airgap
                        Env: EXTRACT_DIR

  --installer SCRIPT    Path to openshift_with_stack.sh.
                        Default: same directory as this script.

  --subcommand CMD      Installer subcommand to run: install | delete
                        Default: install
                        Env: SUBCOMMAND

  -h, --help            Show this help text.

WHAT THIS SCRIPT DOES
  1. Extracts the bundle into --extract-dir.
  2. Verifies SHA-256 checksums of all bundled files.
  3. Exports the following environment variables so openshift_with_stack.sh
     uses local files instead of downloading from the internet:

     CERT_MANAGER_MANIFEST_URL   → file://<bundle>/manifests/cert-manager.yaml
     LOCAL_PATH_MANIFEST_URL     → file://<bundle>/manifests/local-path-storage.yaml
     OTEL_CHART_PATH             → <bundle>/charts/opentelemetry-operator-*.tgz
     KUBERAY_CHART_PATH          → <bundle>/charts/kuberay-operator-*.tgz
     AIRGAP_MODE                 → true

  4. Invokes openshift_with_stack.sh <subcommand>.

PREREQUISITES
  On this machine (no internet needed):
    oc      — logged in to the target OpenShift cluster (oc login ... done)
    helm    — v3+
    tar

  Before running this script:
    - Mirror container images to your internal registry and update images.*
      in your cluster config.
    - For NFD / GPU Operator: apply the oc mirror ImageContentSourcePolicy and
      CatalogSource so OLM can pull from your mirrored catalog.
    - Stage model weights via tools/artifacts_download_upload_scripts/.

MANUAL USE (advanced)
  If you extracted the bundle yourself and want to run the installer directly:

    export AIRGAP_BUNDLE_DIR=/opt/airgap/airgap-bundle-openshift-<timestamp>
    source "${AIRGAP_BUNDLE_DIR}/airgap-env.sh"
    CONFIG_FILE=./openshift-cluster-config.yaml ./openshift_with_stack.sh install

HELP
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2
       echo "Run with --help for usage." >&2
       exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN  $*" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required tool not found: $1 — install it on this machine before running."
}

# ── Pre-flight ─────────────────────────────────────────────────────────────────
[[ -n "${BUNDLE_TARBALL}" ]] || err "No bundle specified. Use --bundle airgap-bundle-openshift-<date>.tar.gz"
[[ -f "${BUNDLE_TARBALL}" ]] || err "Bundle file not found: ${BUNDLE_TARBALL}"

require_cmd tar
require_cmd helm
require_cmd oc

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${INSTALLER_SCRIPT}" ]]; then
  INSTALLER_SCRIPT="${SCRIPT_DIR}/openshift_with_stack.sh"
fi
[[ -f "${INSTALLER_SCRIPT}" ]] || err "Installer not found: ${INSTALLER_SCRIPT}. Pass --installer /path/to/openshift_with_stack.sh"
[[ -x "${INSTALLER_SCRIPT}" ]] || chmod +x "${INSTALLER_SCRIPT}"

log "=== Splunk AI Platform — OpenShift Air-Gap Installation ==="
log "Bundle          : ${BUNDLE_TARBALL}"
log "Extract dir     : ${EXTRACT_DIR}"
log "Installer       : ${INSTALLER_SCRIPT}"
log "Subcommand      : ${SUBCOMMAND}"
[[ -n "${CONFIG_FILE}" ]] && log "Config          : ${CONFIG_FILE}"
log ""

# ── Extract bundle ─────────────────────────────────────────────────────────────
log "Extracting bundle..."
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${BUNDLE_TARBALL}" -C "${EXTRACT_DIR}"

# Resolve the bundle directory from the tarball's own top-level entry rather than
# globbing EXTRACT_DIR — otherwise a stale airgap-bundle-openshift-* directory from a
# previous run could be selected instead of the bundle the user just passed via --bundle.
BUNDLE_TOP="$(tar -tzf "${BUNDLE_TARBALL}" 2>/dev/null | sed 's#/.*##' | grep -m1 '^airgap-bundle-openshift-')"
[[ -n "${BUNDLE_TOP}" ]] || err "Could not find airgap-bundle-openshift-* directory inside ${BUNDLE_TARBALL}"
BUNDLE_DIR="${EXTRACT_DIR}/${BUNDLE_TOP}"
[[ -d "${BUNDLE_DIR}" ]] || err "Expected extracted bundle directory not found: ${BUNDLE_DIR}"
log "Bundle extracted to: ${BUNDLE_DIR}"

# ── Verify checksums ───────────────────────────────────────────────────────────
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

# ── Read version manifest ──────────────────────────────────────────────────────
VERSION_FILE="${BUNDLE_DIR}/bundle-versions.txt"
[[ -f "${VERSION_FILE}" ]] || err "bundle-versions.txt missing from bundle — bundle is incomplete."

get_version() {
  grep "^${1}=" "${VERSION_FILE}" | cut -d= -f2
}

CERT_MANAGER_VERSION="$(get_version cert_manager_version)"
KUBERAY_CHART_VERSION="$(get_version kuberay_chart_version)"
OTEL_CHART_VERSION="$(get_version otel_chart_version)"

log "Bundle component versions:"
log "  cert-manager  : ${CERT_MANAGER_VERSION}"
log "  kuberay chart : ${KUBERAY_CHART_VERSION}"
log "  otel chart    : ${OTEL_CHART_VERSION}"

# ── Resolve chart paths ────────────────────────────────────────────────────────
LOCAL_CHARTS_DIR="${BUNDLE_DIR}/charts"

_resolve_chart() {
  local pattern="$1" label="$2"
  # shellcheck disable=SC2206
  local matches=( ${pattern} )
  if [[ ${#matches[@]} -eq 0 || ! -f "${matches[0]}" ]]; then
    err "Chart not found for ${label} (expected: ${pattern}). Bundle may be corrupt or version-mismatched."
  fi
  echo "${matches[0]}"
}

OTEL_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/opentelemetry-operator-${OTEL_CHART_VERSION}*.tgz" "opentelemetry-operator")"
KUBERAY_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/kuberay-operator-${KUBERAY_CHART_VERSION}*.tgz" "kuberay-operator")"

# ── Export env-var overrides read by openshift_with_stack.sh ──────────────────
export AIRGAP_BUNDLE_DIR="${BUNDLE_DIR}"

# Static manifests (installer strips file:// to a bare path for oc apply)
export CERT_MANAGER_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/local-path-storage.yaml"

# Helm chart paths — installer uses these instead of remote repos
export OTEL_CHART_PATH="${OTEL_TGZ}"
export KUBERAY_CHART_PATH="${KUBERAY_TGZ}"

# Signal air-gapped mode (skips model staging, enforces offline paths)
export AIRGAP_MODE="true"

log ""
log "Environment overrides set:"
log "  CERT_MANAGER_MANIFEST_URL = ${CERT_MANAGER_MANIFEST_URL}"
log "  LOCAL_PATH_MANIFEST_URL   = ${LOCAL_PATH_MANIFEST_URL}"
log "  OTEL_CHART_PATH           = ${OTEL_CHART_PATH}"
log "  KUBERAY_CHART_PATH        = ${KUBERAY_CHART_PATH}"
log "  AIRGAP_MODE               = ${AIRGAP_MODE}"
log ""
log "Launching installer..."
log ""

# ── Invoke main installer ──────────────────────────────────────────────────────
INSTALLER_CMD="${INSTALLER_SCRIPT} ${SUBCOMMAND}"
if [[ -n "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="$(realpath "${CONFIG_FILE}")"
  exec env CONFIG_FILE="${CONFIG_FILE}" ${INSTALLER_CMD}
else
  log "No --config supplied. The installer will look for CONFIG_FILE in the environment"
  log "or its default location. Set CONFIG_FILE if it is not in the current directory."
  exec ${INSTALLER_CMD}
fi
