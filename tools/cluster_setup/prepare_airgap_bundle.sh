#!/usr/bin/env bash
# prepare_airgap_bundle.sh
# Run on an internet-connected machine to download every binary, Helm chart,
# and static manifest needed by k0s_cluster_with_stack.sh. Produces a single
# tar.gz that can be copied to an air-gapped cluster and consumed by
# install_from_airgap_bundle.sh.
#
# Usage:
#   ./prepare_airgap_bundle.sh [--output-dir DIR] [--k0s-version VERSION]
#
# Requirements on this machine:
#   curl, helm, tar, gzip, sha256sum (or shasum on macOS)

set -euo pipefail

# ── Versions (keep in sync with k0s_cluster_with_stack.sh) ─────────────────
YQ_VERSION="v4.44.1"
CERT_MANAGER_VERSION="v1.13.0"
LOCAL_PATH_PROVISIONER_VERSION="v0.0.24"
NVIDIA_DEVICE_PLUGIN_VERSION="v0.17.3"
METALLB_CHART_VERSION="0.14.8"
KUBERAY_CHART_VERSION="1.2.2"

# k0s does not pin a version in the install script (it installs latest stable).
# Override with --k0s-version if you need a specific release.
K0S_VERSION="${K0S_VERSION:-latest}"

OUTPUT_DIR="${OUTPUT_DIR:-./airgap-bundle}"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --k0s-version) K0S_VERSION="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELP'
prepare_airgap_bundle.sh — download all Splunk AI Platform install artifacts
into a self-contained tar.gz bundle for air-gapped deployments.

USAGE
  ./prepare_airgap_bundle.sh [OPTIONS]

OPTIONS
  --output-dir DIR      Directory where the bundle is written.
                        Default: ./airgap-bundle
                        Env: OUTPUT_DIR

  --k0s-version VER     Specific k0s release to download (e.g. v1.31.2+k0s.0).
                        Default: latest stable release
                        Env: K0S_VERSION

  -h, --help            Show this help text.

WHAT IS BUNDLED
  binaries/
    k0s          — k0s Kubernetes binary (linux/amd64)
    yq           — YAML processor used by the installer

  manifests/
    cert-manager.yaml          — cert-manager CRDs + controller
    local-path-storage.yaml    — Rancher local-path provisioner
    nvidia-device-plugin.yml   — NVIDIA GPU device plugin DaemonSet

  charts/
    kube-prometheus-stack-*.tgz   — Prometheus + Grafana (version resolved at bundle time)
    opentelemetry-operator-*.tgz  — OTel operator (version resolved at bundle time)
    kuberay-operator-1.2.2.tgz    — KubeRay operator (pinned)
    metallb-0.14.8.tgz            — MetalLB load-balancer (pinned)

  airgap-env.sh         — Source this to set env-var overrides before a manual install
  container-images.txt  — List of container images to mirror to your internal registry
  bundle-versions.txt   — Records all component versions for reproducibility
  checksums.sha256      — SHA-256 checksums for every file in the bundle

ENVIRONMENT VARIABLE OVERRIDES (set before running the installer manually)
  These are exported automatically by install_from_airgap_bundle.sh.
  You only need to set them manually if you extract the bundle yourself.

  K0S_INSTALL_URL                   URL/path to k0s binary (file:// or https://)
  YQ_DOWNLOAD_URL                   URL/path to yq binary
  CERT_MANAGER_MANIFEST_URL         URL/path to cert-manager.yaml
  LOCAL_PATH_MANIFEST_URL           URL/path to local-path-storage.yaml
  NVIDIA_DEVICE_PLUGIN_MANIFEST_URL URL/path to nvidia-device-plugin.yml
  PROMETHEUS_CHART_PATH             Local path to kube-prometheus-stack .tgz
  OTEL_CHART_PATH                   Local path to opentelemetry-operator .tgz
  KUBERAY_CHART_PATH                Local path to kuberay-operator .tgz
  METALLB_CHART_PATH                Local path to metallb .tgz

EXAMPLES
  # Basic bundle in current directory
  ./prepare_airgap_bundle.sh

  # Custom output directory and pinned k0s version
  ./prepare_airgap_bundle.sh --output-dir /mnt/transfer --k0s-version v1.31.2+k0s.0

  # Using env vars instead of flags
  OUTPUT_DIR=/mnt/transfer K0S_VERSION=v1.31.2+k0s.0 ./prepare_airgap_bundle.sh

NEXT STEPS AFTER BUNDLING
  1. Mirror container images listed in container-images.txt to your internal registry.
  2. Stage model weights via tools/artifacts_download_upload_scripts/ (separate step).
  3. Copy the .tar.gz to the air-gapped install machine.
  4. Run: ./install_from_airgap_bundle.sh --bundle airgap-bundle-<date>.tar.gz \
                                          --config my-cluster-config.yaml

HELP
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; echo "Run with --help for usage." >&2; exit 1 ;;
  esac
done

BUNDLE_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE_NAME="airgap-bundle-${BUNDLE_TIMESTAMP}"
STAGE_DIR="${OUTPUT_DIR}/${BUNDLE_NAME}"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN  $*" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required tool not found: $1 — install it before running this script."
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

download() {
  local url="$1" dest="$2"
  log "Downloading $(basename "$dest") ..."
  if ! curl -fsSL --retry 3 --retry-delay 5 -o "$dest" "$url"; then
    err "Download failed: $url"
  fi
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
require_cmd curl
require_cmd helm
require_cmd tar

log "=== Splunk AI Platform — Air-Gap Bundle Preparation ==="
log "Output directory : ${OUTPUT_DIR}"
log "Bundle name      : ${BUNDLE_NAME}"
log ""
log "Component versions:"
log "  k0s                   : ${K0S_VERSION}"
log "  yq                    : ${YQ_VERSION}"
log "  cert-manager          : ${CERT_MANAGER_VERSION}"
log "  local-path-provisioner: ${LOCAL_PATH_PROVISIONER_VERSION}"
log "  nvidia-device-plugin  : ${NVIDIA_DEVICE_PLUGIN_VERSION}"
log "  metallb chart         : ${METALLB_CHART_VERSION}"
log "  kuberay chart         : ${KUBERAY_CHART_VERSION}"
log ""

mkdir -p \
  "${STAGE_DIR}/binaries" \
  "${STAGE_DIR}/manifests" \
  "${STAGE_DIR}/charts"

# ── 1. k0s binary ─────────────────────────────────────────────────────────────
log "--- Downloading k0s binary ---"
if [[ "${K0S_VERSION}" == "latest" ]]; then
  K0S_VERSION="$(curl -fsSL https://api.github.com/repos/k0sproject/k0s/releases/latest \
    | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)".*/\1/')"
  log "Resolved latest k0s version: ${K0S_VERSION}"
fi

K0S_URL="https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION}/k0s-${K0S_VERSION}-amd64"
download "${K0S_URL}" "${STAGE_DIR}/binaries/k0s"
chmod +x "${STAGE_DIR}/binaries/k0s"
echo "${K0S_VERSION}" > "${STAGE_DIR}/binaries/k0s.version"

# ── 2. yq binary ──────────────────────────────────────────────────────────────
log "--- Downloading yq binary ---"
YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
download "${YQ_URL}" "${STAGE_DIR}/binaries/yq"
chmod +x "${STAGE_DIR}/binaries/yq"

# ── 3. Static Kubernetes manifests ────────────────────────────────────────────
log "--- Downloading static manifests ---"

download \
  "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
  "${STAGE_DIR}/manifests/cert-manager.yaml"

download \
  "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml" \
  "${STAGE_DIR}/manifests/local-path-storage.yaml"

download \
  "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml" \
  "${STAGE_DIR}/manifests/nvidia-device-plugin.yml"

# ── 4. Helm charts ────────────────────────────────────────────────────────────
log "--- Pulling Helm charts ---"

# Add repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null 2>&1 || true
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo update prometheus-community open-telemetry kuberay metallb

# kube-prometheus-stack — resolve latest version at bundle time
PROMETHEUS_CHART_VERSION="$(helm search repo prometheus-community/kube-prometheus-stack \
  --output json | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
log "Resolved kube-prometheus-stack chart version: ${PROMETHEUS_CHART_VERSION}"

helm pull prometheus-community/kube-prometheus-stack \
  --version "${PROMETHEUS_CHART_VERSION}" \
  --destination "${STAGE_DIR}/charts"
echo "${PROMETHEUS_CHART_VERSION}" > "${STAGE_DIR}/charts/kube-prometheus-stack.version"

# opentelemetry-operator — resolve latest version at bundle time
OTEL_CHART_VERSION="$(helm search repo open-telemetry/opentelemetry-operator \
  --output json | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
log "Resolved opentelemetry-operator chart version: ${OTEL_CHART_VERSION}"

helm pull open-telemetry/opentelemetry-operator \
  --version "${OTEL_CHART_VERSION}" \
  --destination "${STAGE_DIR}/charts"
echo "${OTEL_CHART_VERSION}" > "${STAGE_DIR}/charts/opentelemetry-operator.version"

# kuberay — pinned
helm pull kuberay/kuberay-operator \
  --version "${KUBERAY_CHART_VERSION}" \
  --destination "${STAGE_DIR}/charts"

# metallb — pinned
helm pull metallb/metallb \
  --version "${METALLB_CHART_VERSION}" \
  --destination "${STAGE_DIR}/charts"

# ── 5. Write manifest: env var overrides for k0s_cluster_with_stack.sh ────────
log "--- Writing env-var override manifest ---"

cat > "${STAGE_DIR}/airgap-env.sh" <<'ENVEOF'
# Source this file before running k0s_cluster_with_stack.sh in an air-gapped
# environment. It points every internet URL to the local bundle extracted by
# install_from_airgap_bundle.sh.
#
# Usage:
#   source /path/to/bundle/airgap-env.sh
#   CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install

# Set by install_from_airgap_bundle.sh to the extraction directory.
# Override here only if you extracted the bundle manually.
: "${AIRGAP_BUNDLE_DIR:?AIRGAP_BUNDLE_DIR must be set to the bundle extraction path}"

export K0S_INSTALL_URL="file://${AIRGAP_BUNDLE_DIR}/binaries/k0s"
export YQ_DOWNLOAD_URL="file://${AIRGAP_BUNDLE_DIR}/binaries/yq"

export CERT_MANAGER_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/local-path-storage.yaml"
export NVIDIA_DEVICE_PLUGIN_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/nvidia-device-plugin.yml"

export PROMETHEUS_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/kube-prometheus-stack-$(cat "${AIRGAP_BUNDLE_DIR}/charts/kube-prometheus-stack.version").tgz"
export OTEL_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator-$(cat "${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator.version").tgz"
export KUBERAY_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/kuberay-operator-${KUBERAY_CHART_VERSION:-1.2.2}.tgz"
export METALLB_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/metallb-${METALLB_CHART_VERSION:-0.14.8}.tgz"
ENVEOF

# ── 6. Container image list ───────────────────────────────────────────────────
log "--- Generating container image list ---"

cat > "${STAGE_DIR}/container-images.txt" <<'IMGEOF'
# Container images required by the Splunk AI Platform stack.
# Mirror ALL of these into your internal registry before running the installer.
#
# How to mirror (example using crane):
#   while IFS= read -r img; do
#     [[ "$img" =~ ^# ]] && continue
#     [[ -z "$img" ]] && continue
#     dest="your-internal-registry.example.com/${img##*/}"
#     crane copy "$img" "$dest"
#   done < container-images.txt
#
# How to mirror using docker:
#   docker pull IMAGE && docker tag IMAGE INTERNAL_REGISTRY/IMAGE && docker push INTERNAL_REGISTRY/IMAGE
#
# After mirroring, set images.registry in your k0s-cluster-config.yaml to
# your internal registry prefix.

# ── Splunk ──────────────────────────────────────────────────────────────────
splunk/splunk:10.2.0
docker.io/splunk/splunk-operator:3.0.0

# ── Ray ─────────────────────────────────────────────────────────────────────
# Set images.ray.headImage and images.ray.workerImage in config to your mirrors
# (these are built internally — not on a public registry)

# ── Weaviate ─────────────────────────────────────────────────────────────────
docker.io/semitechnologies/weaviate:stable-v1.28-007846a

# ── KubeRay Operator ─────────────────────────────────────────────────────────
quay.io/kuberay/operator:v1.2.2

# ── OpenTelemetry ─────────────────────────────────────────────────────────────
docker.io/otel/opentelemetry-collector-contrib:0.122.1

# ── Fluent Bit ────────────────────────────────────────────────────────────────
docker.io/fluent/fluent-bit:1.9.6

# ── Nginx ────────────────────────────────────────────────────────────────────
docker.io/library/nginx:1.27-alpine

# ── MetalLB (installed by Helm chart — the chart handles its own images) ─────
# The metallb Helm chart pulls its own images; check the chart for the current
# image tags after running: helm show values metallb/metallb --version 0.14.8

# ── cert-manager (installed from manifest) ───────────────────────────────────
# cert-manager manifest embeds image references; check the manifest for exact tags:
# grep 'image:' manifests/cert-manager.yaml

# ── Prometheus stack (Helm chart — many images) ──────────────────────────────
# Run after pulling the chart: helm show values charts/kube-prometheus-stack-*.tgz
# to get the full image list.

# ── NOTE: Model weights (HuggingFace) ────────────────────────────────────────
# Model weights (~60 GB total) are NOT container images.
# Use tools/artifacts_download_upload_scripts/ to stage them separately.
# Models: gemma-4-31b-it, gpt-oss-20b, all-minilm-l6-v2, bi-encoder,
#         cross-encoder, e5-language-classifier, mbart-translator,
#         pii-classifier, uae-large, xlm-roberta-language-classifier
IMGEOF

# ── 7. Write version manifest ─────────────────────────────────────────────────
cat > "${STAGE_DIR}/bundle-versions.txt" <<VEOF
k0s_version=${K0S_VERSION}
yq_version=${YQ_VERSION}
cert_manager_version=${CERT_MANAGER_VERSION}
local_path_provisioner_version=${LOCAL_PATH_PROVISIONER_VERSION}
nvidia_device_plugin_version=${NVIDIA_DEVICE_PLUGIN_VERSION}
metallb_chart_version=${METALLB_CHART_VERSION}
kuberay_chart_version=${KUBERAY_CHART_VERSION}
prometheus_chart_version=${PROMETHEUS_CHART_VERSION}
otel_chart_version=${OTEL_CHART_VERSION}
bundle_timestamp=${BUNDLE_TIMESTAMP}
VEOF

# ── 8. Checksums ──────────────────────────────────────────────────────────────
log "--- Computing checksums ---"
(
  cd "${STAGE_DIR}"
  find binaries manifests charts -type f | sort | while read -r f; do
    printf "%s  %s\n" "$(sha256 "$f")" "$f"
  done
) > "${STAGE_DIR}/checksums.sha256"
log "Checksums written to ${STAGE_DIR}/checksums.sha256"

# ── 9. Pack the bundle ────────────────────────────────────────────────────────
log "--- Creating tar.gz bundle ---"
BUNDLE_TARBALL="${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz"
tar -czf "${BUNDLE_TARBALL}" -C "${OUTPUT_DIR}" "${BUNDLE_NAME}"

BUNDLE_SIZE="$(du -sh "${BUNDLE_TARBALL}" | cut -f1)"
BUNDLE_SHA="$(sha256 "${BUNDLE_TARBALL}")"
log ""
log "=== Bundle ready ==="
log "  File : ${BUNDLE_TARBALL}"
log "  Size : ${BUNDLE_SIZE}"
log "  SHA256: ${BUNDLE_SHA}"
log ""
log "Next steps:"
log "  1. Mirror the container images listed in:"
log "       ${STAGE_DIR}/container-images.txt"
log "     to your internal registry. Update images.* in your cluster config."
log ""
log "  2. Stage model weights (if not already staged) on an internet-connected"
log "     machine using: tools/artifacts_download_upload_scripts/"
log ""
log "  3. Copy ${BUNDLE_TARBALL} to the air-gapped install machine."
log ""
log "  4. On the install machine, run:"
log "       ./install_from_airgap_bundle.sh --bundle ${BUNDLE_NAME}.tar.gz"
log ""
log "Cleaning up staging directory..."
rm -rf "${STAGE_DIR}"
