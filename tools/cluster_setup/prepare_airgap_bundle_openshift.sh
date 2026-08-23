#!/usr/bin/env bash
# prepare_airgap_bundle_openshift.sh
# Run on an internet-connected machine to download every Helm chart and static
# manifest needed by openshift_with_stack.sh. Produces a single tar.gz that
# can be copied to an air-gapped OpenShift cluster and consumed by
# install_from_airgap_bundle_openshift.sh.
#
# NOTE: This script does NOT bundle container images or OLM catalog content.
#   - Container images: mirror them using `oc mirror` + your internal registry.
#     See container-images.txt in the output bundle for the full image list.
#   - NFD / GPU Operator: install via OLM from a mirrored catalog
#     (oc mirror + ImageContentSourcePolicy). See bundle README section.
#   - Model weights: stage separately via tools/artifacts_download_upload_scripts/.
#
# Usage:
#   ./prepare_airgap_bundle_openshift.sh [--output-dir DIR]
#
# Requirements on this machine:
#   curl, helm, tar, gzip, sha256sum (or shasum on macOS)

set -euo pipefail

# ── Versions (keep in sync with openshift_with_stack.sh; source of truth:
#    tools/cluster_setup/versions.env — run check_versions.sh after bumping) ─
CERT_MANAGER_VERSION="v1.13.0"              # ver:OPENSHIFT_CERT_MANAGER_VERSION
LOCAL_PATH_PROVISIONER_VERSION="v0.0.26"    # ver:OPENSHIFT_LOCAL_PATH_PROVISIONER_VERSION
KUBERAY_CHART_VERSION="1.2.2"               # ver:OPENSHIFT_KUBERAY_CHART_VERSION

OUTPUT_DIR="${OUTPUT_DIR:-./airgap-bundle-openshift}"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELP'
prepare_airgap_bundle_openshift.sh — download all Splunk AI Platform install
artifacts needed by openshift_with_stack.sh into a self-contained tar.gz bundle
for air-gapped OpenShift deployments.

USAGE
  ./prepare_airgap_bundle_openshift.sh [OPTIONS]

OPTIONS
  --output-dir DIR      Directory where the bundle is written.
                        Default: ./airgap-bundle-openshift
                        Env: OUTPUT_DIR

  -h, --help            Show this help text.

WHAT IS BUNDLED
  manifests/
    cert-manager.yaml          — cert-manager CRDs + controller
    local-path-storage.yaml    — Rancher local-path provisioner

  charts/
    opentelemetry-operator-*.tgz  — OTel operator (version resolved at bundle time)
    kuberay-operator-1.2.2.tgz    — KubeRay operator (pinned)

  airgap-env.sh         — Source this to set env-var overrides before a manual install
  container-images.txt  — Full list of images to mirror to your internal registry
  bundle-versions.txt   — Records all component versions for reproducibility
  checksums.sha256      — SHA-256 checksums for every file in the bundle

WHAT IS NOT BUNDLED (and why)
  Container images
    OpenShift uses oc mirror + ImageContentSourcePolicy / ImageDigestMirrorSet to
    redirect pulls from public registries to your internal mirror. Run:
      oc mirror --config=imageset-config.yaml file:///path/to/mirror
    then push the mirror to your registry. See container-images.txt for the list.

  NFD / GPU Operator (OLM)
    Install via OLM from a mirrored OperatorHub catalog:
      oc mirror --config=imageset-config.yaml file:///path/to/mirror
    Apply the resulting ImageContentSourcePolicy + CatalogSource, then create
    Subscription objects as normal.

  k0s binary / yq — not applicable (OpenShift provides its own cluster)
  MetalLB — not applicable (OpenShift uses Routes; MetalLB is k0s-only)
  kube-prometheus-stack — not applicable (OpenShift ships its own monitoring stack)
  NVIDIA device plugin manifest — not applicable (GPU Operator via OLM handles this)
  GPU node OS packages — not applicable (GPU Operator manages driver lifecycle)
  Model weights — stage separately via tools/artifacts_download_upload_scripts/

ENVIRONMENT VARIABLE OVERRIDES (set before running the installer manually)
  These are exported automatically by install_from_airgap_bundle_openshift.sh.
  You only need to set them manually if you extract the bundle yourself.

  CERT_MANAGER_MANIFEST_URL   URL/path to cert-manager.yaml (file:// or https://)
  LOCAL_PATH_MANIFEST_URL     URL/path to local-path-storage.yaml
  OTEL_CHART_PATH             Local path to opentelemetry-operator .tgz
  KUBERAY_CHART_PATH          Local path to kuberay-operator .tgz

EXAMPLES
  # Basic bundle
  ./prepare_airgap_bundle_openshift.sh

  # Custom output directory
  ./prepare_airgap_bundle_openshift.sh --output-dir /mnt/transfer

  # Using env vars instead of flags
  OUTPUT_DIR=/mnt/transfer ./prepare_airgap_bundle_openshift.sh

NEXT STEPS AFTER BUNDLING
  1. Mirror container images listed in container-images.txt to your internal registry.
     Update images.registry and images.* in your openshift-cluster-config.yaml.
  2. Stage model weights via tools/artifacts_download_upload_scripts/ (separate step).
  3. For NFD / GPU Operator: mirror OLM catalogs using oc mirror and apply
     ImageContentSourcePolicy before running the installer.
  4. Copy the .tar.gz to the air-gapped install machine.
  5. Run: ./install_from_airgap_bundle_openshift.sh \
             --bundle airgap-bundle-openshift-<date>.tar.gz \
             --config openshift-cluster-config.yaml

HELP
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; echo "Run with --help for usage." >&2; exit 1 ;;
  esac
done

BUNDLE_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE_NAME="airgap-bundle-openshift-${BUNDLE_TIMESTAMP}"
STAGE_DIR="${OUTPUT_DIR}/${BUNDLE_NAME}"

# ── Helpers ───────────────────────────────────────────────────────────────────
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

# ── Pre-flight ─────────────────────────────────────────────────────────────────
require_cmd curl
require_cmd helm
require_cmd tar

log "=== Splunk AI Platform — OpenShift Air-Gap Bundle Preparation ==="
log "Output directory : ${OUTPUT_DIR}"
log "Bundle name      : ${BUNDLE_NAME}"
log ""
log "Component versions:"
log "  cert-manager          : ${CERT_MANAGER_VERSION}"
log "  local-path-provisioner: ${LOCAL_PATH_PROVISIONER_VERSION}"
log "  kuberay chart         : ${KUBERAY_CHART_VERSION}"
log "  otel chart            : (resolved at bundle time)"
log ""

mkdir -p \
  "${STAGE_DIR}/manifests" \
  "${STAGE_DIR}/charts"

# ── 1. Static Kubernetes manifests ────────────────────────────────────────────
log "--- Downloading static manifests ---"

download \
  "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
  "${STAGE_DIR}/manifests/cert-manager.yaml"

download \
  "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml" \
  "${STAGE_DIR}/manifests/local-path-storage.yaml"

# ── 2. Helm charts ────────────────────────────────────────────────────────────
log "--- Pulling Helm charts ---"

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ 2>/dev/null || true
helm repo update open-telemetry kuberay

# opentelemetry-operator — resolve latest version at bundle time
OTEL_CHART_VERSION="$(helm search repo open-telemetry/opentelemetry-operator \
  --output json | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
[[ -z "${OTEL_CHART_VERSION}" ]] && err "Could not resolve opentelemetry-operator chart version."
log "Resolved opentelemetry-operator chart version: ${OTEL_CHART_VERSION}"

helm pull open-telemetry/opentelemetry-operator \
  --version "${OTEL_CHART_VERSION}" \
  --destination "${STAGE_DIR}/charts"
echo "${OTEL_CHART_VERSION}" > "${STAGE_DIR}/charts/opentelemetry-operator.version"

# kuberay — pinned
helm pull kuberay/kuberay-operator \
  --version "${KUBERAY_CHART_VERSION}" \
  --destination "${STAGE_DIR}/charts"

# ── 3. Env-var override manifest ──────────────────────────────────────────────
log "--- Writing env-var override manifest ---"

cat > "${STAGE_DIR}/airgap-env.sh" <<'ENVEOF'
# Source this file before running openshift_with_stack.sh in an air-gapped
# environment. It points every internet URL to the local bundle.
#
# Usage:
#   source /path/to/bundle/airgap-env.sh
#   CONFIG_FILE=./openshift-cluster-config.yaml ./openshift_with_stack.sh install

# Set by install_from_airgap_bundle_openshift.sh to the extraction directory.
# Override here only if you extracted the bundle manually.
: "${AIRGAP_BUNDLE_DIR:?AIRGAP_BUNDLE_DIR must be set to the bundle extraction path}"

# Static manifests — oc apply -f does not understand file://, so these are bare
# paths. The installer strips the file:// prefix automatically.
export CERT_MANAGER_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/local-path-storage.yaml"

# Helm chart paths — installer uses these instead of remote repos when set.
export OTEL_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator-$(cat "${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator.version").tgz"
export KUBERAY_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/kuberay-operator-${KUBERAY_CHART_VERSION:-1.2.2}.tgz"

# Signal to the installer that this is an air-gapped run.
export AIRGAP_MODE="true"
ENVEOF

# ── 4. Container image list ───────────────────────────────────────────────────
log "--- Generating container image list ---"

cat > "${STAGE_DIR}/container-images.txt" <<'IMGEOF'
# Container images required by the Splunk AI Platform stack on OpenShift.
# Mirror ALL of these into your internal registry before running the installer.
#
# Recommended mirroring tool: oc mirror (OpenShift mirror registry)
#   oc mirror --config=imageset-config.yaml file:///path/to/local-mirror
#
# Alternative using crane:
#   while IFS= read -r img; do
#     [[ "$img" =~ ^# ]] && continue
#     [[ -z "$img" ]] && continue
#     dest="your-internal-registry.example.com/${img##*/}"
#     crane copy "$img" "$dest"
#   done < container-images.txt
#
# After mirroring, update images.registry in your openshift-cluster-config.yaml
# to your internal registry prefix, and set each images.* field to the mirrored path.

# ── Splunk ───────────────────────────────────────────────────────────────────
# Set images.splunk.image / images.splunk.operatorImage in cluster config
splunk/splunk:10.2.0
docker.io/splunk/splunk-operator:3.0.0

# ── Ray ──────────────────────────────────────────────────────────────────────
# Built internally — not on a public registry.
# Set images.ray.headImage and images.ray.workerImage in cluster config.
# Example (replace with your actual build tags):
#   <your-ecr>/ml-platform/ray/ray-head:build-953
#   <your-ecr>/ml-platform/ray/ray-worker-gpu:build-953

# ── SAIA ─────────────────────────────────────────────────────────────────────
# Built internally — set images.saia.* in cluster config.
# Example:
#   <your-ecr>/ml-platform/saia/saia-api:build-v2-main-c3b489d
#   <your-ecr>/ml-platform/saia/saia-api-v2:build-v2-main-c3b489d
#   <your-ecr>/ml-platform/saia/saia-data-loader:build-v2-main-c3b489d

# ── SLIM ─────────────────────────────────────────────────────────────────────
# Built internally — set images.slim.apiImage in cluster config when the
# "slim" feature is enabled.
# Example:
#   <your-ecr>/ml-platform/slim/slim-api:build-1

# ── Weaviate ──────────────────────────────────────────────────────────────────
docker.io/semitechnologies/weaviate:stable-v1.28-007846a

# ── KubeRay Operator ─────────────────────────────────────────────────────────
quay.io/kuberay/operator:v1.2.2

# ── OpenTelemetry ─────────────────────────────────────────────────────────────
# Collector image (injected into OpenTelemetryCollector CRs). The operator's own
# controller-manager + kube-rbac-proxy images are appended below from the bundled chart.
docker.io/otel/opentelemetry-collector-contrib:0.122.1

# ── Fluent Bit ────────────────────────────────────────────────────────────────
docker.io/fluent/fluent-bit:1.9.6

# ── Nginx ─────────────────────────────────────────────────────────────────────
docker.io/library/nginx:1.27-alpine

# ── cert-manager (images extracted from bundled manifest) ─────────────────────
IMGEOF

grep 'image: ' "${STAGE_DIR}/manifests/cert-manager.yaml" 2>/dev/null | sed 's/.*image: *//' | awk '{print $1}' | sort -u >> "${STAGE_DIR}/container-images.txt" || true

cat >> "${STAGE_DIR}/container-images.txt" <<'IMGEOF'

# ── local-path-provisioner ────────────────────────────────────────────────────
# The helper pod and `oc debug` relabeling image is hard-coded to ubi8/ubi-minimal
# in openshift_with_stack.sh (no tag → :latest); mirror the exact image it pulls.
registry.access.redhat.com/ubi8/ubi-minimal:latest
IMGEOF

# opentelemetry-operator controller images — extracted from the bundled chart so they
# always match the version pulled above (chart version is resolved dynamically). The
# installer only overrides manager.collectorImage; the manager (+ any rbac-proxy) image
# comes from chart defaults, so a disconnected install that mirrors only this list would
# otherwise ImagePullBackOff on the operator pod. Rendered images are inline-quoted, e.g.
#   image: "ghcr.io/.../opentelemetry-operator:0.154.0"
# Exclude helm test-hook images (busybox:latest) — they never deploy during install.
{
  echo ""
  echo "# ── OpenTelemetry Operator (controller images from bundled chart) ─────────────"
  helm template opentelemetry-operator \
    "${STAGE_DIR}/charts/opentelemetry-operator-${OTEL_CHART_VERSION}.tgz" \
    2>/dev/null \
    | grep -oE 'image:[[:space:]]*"?[^[:space:]"]+' \
    | sed -E 's/^image:[[:space:]]*"?//' \
    | grep -v '^busybox:' \
    | sort -u
} >> "${STAGE_DIR}/container-images.txt" || true

grep 'image: ' "${STAGE_DIR}/manifests/local-path-storage.yaml" 2>/dev/null | sed 's/.*image: *//' | awk '{print $1}' | sort -u >> "${STAGE_DIR}/container-images.txt" || true

cat >> "${STAGE_DIR}/container-images.txt" <<'IMGEOF'

# ── OLM Operators (NFD + GPU Operator) ───────────────────────────────────────
# These are NOT direct image references — they are OLM Subscriptions backed by
# OperatorHub catalog content. Mirror them with oc mirror:
#
#   The GPU Operator ships in the CERTIFIED catalog (certified-operators /
#   certified-operator-index) while NFD ships in the redhat-operators catalog
#   (redhat-operator-index). They must be mirrored from their respective catalogs,
#   matching the installer defaults: operators.gpu.catalogSource=certified-operators,
#   operators.nfd.catalogSource=redhat-operators.
#
#   imageset-config.yaml example:
#     kind: ImageSetConfiguration
#     apiVersion: mirror.openshift.io/v1alpha2
#     mirror:
#       operators:
#         - catalog: registry.redhat.io/redhat/certified-operator-index:v4.14
#           packages:
#             - name: gpu-operator-certified
#         - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.14
#           packages:
#             - name: nfd
#
#   Then apply the generated ImageContentSourcePolicy and CatalogSource.
#   See: https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/

# ── NOTE: Model weights (HuggingFace) ─────────────────────────────────────────
# Model weights (~60 GB total) are NOT container images.
# Use tools/artifacts_download_upload_scripts/ to stage them separately to S3/MinIO.
# Models: gemma-4-31b-it-qat-w4a16-ct, gpt-oss-20b, all-minilm-l6-v2,
#         bi-encoder, cross-encoder, e5-language-classifier, fm_timeseries,
#         mbart-translator, pii-classifier, uae-large,
#         xlm-roberta-language-classifier
IMGEOF

# ── 5. Write version manifest ─────────────────────────────────────────────────
cat > "${STAGE_DIR}/bundle-versions.txt" <<VEOF
cert_manager_version=${CERT_MANAGER_VERSION}
local_path_provisioner_version=${LOCAL_PATH_PROVISIONER_VERSION}
kuberay_chart_version=${KUBERAY_CHART_VERSION}
otel_chart_version=${OTEL_CHART_VERSION}
bundle_timestamp=${BUNDLE_TIMESTAMP}
VEOF

# ── 6. Checksums ──────────────────────────────────────────────────────────────
log "--- Computing checksums ---"
(
  cd "${STAGE_DIR}"
  find . -type f ! -name "checksums.sha256" | sed 's|^\./||' | sort | while read -r f; do
    printf "%s  %s\n" "$(sha256 "$f")" "$f"
  done
) > "${STAGE_DIR}/checksums.sha256"
log "Checksums written to ${STAGE_DIR}/checksums.sha256"

# ── 7. Pack the bundle ────────────────────────────────────────────────────────
log "--- Creating tar.gz bundle ---"
BUNDLE_TARBALL="${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz"
tar -czf "${BUNDLE_TARBALL}" -C "${OUTPUT_DIR}" "${BUNDLE_NAME}"

BUNDLE_SIZE="$(du -sh "${BUNDLE_TARBALL}" | cut -f1)"
BUNDLE_SHA="$(sha256 "${BUNDLE_TARBALL}")"
log ""
log "=== Bundle ready ==="
log "  File  : ${BUNDLE_TARBALL}"
log "  Size  : ${BUNDLE_SIZE}"
log "  SHA256: ${BUNDLE_SHA}"
log ""
log "Next steps:"
log "  1. Mirror the container images listed in:"
log "       ${STAGE_DIR}/container-images.txt"
log "     to your internal registry. Update images.* in your cluster config."
log "     For NFD/GPU Operator, mirror OLM catalogs with oc mirror."
log ""
log "  2. Stage model weights (if not already staged) using:"
log "       tools/artifacts_download_upload_scripts/"
log ""
log "  3. Copy ${BUNDLE_TARBALL} to the air-gapped install machine."
log ""
log "  4. On the install machine, run:"
log "       ./install_from_airgap_bundle_openshift.sh \\"
log "         --bundle ${BUNDLE_NAME}.tar.gz \\"
log "         --config openshift-cluster-config.yaml"
log ""
log "Cleaning up staging directory..."
rm -rf "${STAGE_DIR}"
