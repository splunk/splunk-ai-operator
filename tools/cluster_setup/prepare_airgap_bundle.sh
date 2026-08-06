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

# Target OS for GPU node RPM packages. Only rhel9 is tested and supported.
# rhel10 and amzn2023 code paths are kept for internal testing only.
GPU_NODE_OS="${GPU_NODE_OS:-rhel9}"

OUTPUT_DIR="${OUTPUT_DIR:-./airgap-bundle}"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --k0s-version) K0S_VERSION="$2"; shift 2 ;;
    --gpu-os)      GPU_NODE_OS="$2"; shift 2 ;;
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

  --gpu-os OS           Target OS for GPU node package files.
                        Supported: rhel9 (default — only tested/supported value)
                        Env: GPU_NODE_OS
                        Only RHEL 9 is tested and supported.
                        Any other value will error.

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

  packages/  (GPU node OS packages — for fully offline GPU worker setup)
    epel-release-latest-<N>.noarch.rpm  — EPEL RPM for RHEL/AL2023
    cuda-<os>.repo                      — CUDA package repository definition
    nvidia-container-toolkit.repo       — nvidia-container-toolkit RPM repo definition
    pyyaml-*.whl                        — PyYAML pure-Python wheel (all nodes)

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
  EPEL_RPM_URL_OVERRIDE             URL/path to EPEL release RPM (GPU nodes)
  CUDA_REPO_URL_OVERRIDE            URL/path to CUDA .repo file (GPU nodes)
  NVIDIA_CTK_REPO_URL_OVERRIDE      URL/path to nvidia-container-toolkit .repo (GPU nodes)
  AIRGAP_PYYAML_WHEEL_PATH          Path to PyYAML .whl file (all nodes, optional)

EXAMPLES
  # Basic bundle (RHEL 9 GPU nodes — only supported target)
  ./prepare_airgap_bundle.sh

  # Custom output directory and pinned k0s version
  ./prepare_airgap_bundle.sh --output-dir /mnt/transfer --k0s-version v1.31.2+k0s.0

  # Using env vars instead of flags
  OUTPUT_DIR=/mnt/transfer ./prepare_airgap_bundle.sh

NEXT STEPS AFTER BUNDLING
  1. Mirror container images listed in container-images.txt to your internal registry.
  2. Stage model weights via tools/artifacts_download_upload_scripts/ (separate step).
  3. Copy the .tar.gz to the air-gapped install machine.
  4. Run: ./install_from_airgap_bundle.sh --bundle airgap-bundle-<date>.tar.gz \
                                          --config my-cluster-config.yaml

GPU NODE PACKAGES (packages/ directory)
  The bundle includes OS package files for GPU workers. install_from_airgap_bundle.sh
  copies these to each GPU node via scp before the main installer runs, so the
  installer can use them without internet access.

  For RHEL 9 GPU nodes the bundle provides:
    - EPEL release RPM (installs EPEL repo for DKMS)
    - CUDA .repo file (redirects dnf to the bundled content if served via HTTP)
    - nvidia-container-toolkit .repo file
    - PyYAML wheel (pure Python, installed via pip3 --no-index)

  NOTE: The CUDA and nvidia-container-toolkit .repo files redirect dnf to
  developer.download.nvidia.com. For a truly offline install you still need
  either a local RPM mirror or to pre-install the NVIDIA driver and
  nvidia-container-toolkit before running this script.
  See K0S_README.md — 'GPU Nodes in Air-Gapped Environments' for full options.

HELP
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; echo "Run with --help for usage." >&2; exit 1 ;;
  esac
done

BUNDLE_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE_NAME="airgap-bundle-${BUNDLE_TIMESTAMP}"
STAGE_DIR="${OUTPUT_DIR}/${BUNDLE_NAME}"

# ── OS validation ─────────────────────────────────────────────────────────────
if [[ "${GPU_NODE_OS}" != "rhel9" ]]; then
  echo "ERROR: --gpu-os '${GPU_NODE_OS}' is not supported." >&2
  echo "  Only 'rhel9' is tested and supported for GPU node packages." >&2
  echo "  rhel10 and amzn2023 paths exist in the code for internal testing" >&2
  echo "  but are not validated for production use." >&2
  echo "  To use an untested OS path, set GPU_NODE_OS directly and accept the risk:" >&2
  echo "    GPU_NODE_OS=rhel10 ./prepare_airgap_bundle.sh ..." >&2
  exit 1
fi

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
log "  gpu node OS           : ${GPU_NODE_OS}"
log ""

mkdir -p \
  "${STAGE_DIR}/binaries" \
  "${STAGE_DIR}/manifests" \
  "${STAGE_DIR}/charts" \
  "${STAGE_DIR}/packages"

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

# ── 1b. k0s system-image bundle (pause, calico, kube-proxy, coredns, etc.) ─────
# k0s pulls its OWN control-plane images (quay.io/k0sproject/*) at startup; in an
# air-gapped cluster those pulls time out. k0s solves this natively: any OCI image
# bundle dropped at /var/lib/k0s/images/ is auto-imported into containerd before
# the kubelet starts. We build that bundle here (M1 has internet) using the exact
# k0s binary we just downloaded, and stage it for the installer to scp to every
# node. --all includes images for every bundled component (both calico AND
# kube-router network providers, metrics-server, etc.) so the bundle is correct
# regardless of which provider the cluster config selects.
log "--- Building k0s system-image bundle (this pulls ~8 images, may take a few minutes) ---"
mkdir -p "${STAGE_DIR}/images"
if "${STAGE_DIR}/binaries/k0s" airgap list-images --all > "${STAGE_DIR}/images/k0s-images.list" 2>/dev/null \
   && [[ -s "${STAGE_DIR}/images/k0s-images.list" ]]; then
  log "k0s system images to bundle:"
  while IFS= read -r _img; do log "    ${_img}"; done < "${STAGE_DIR}/images/k0s-images.list"
  # --concurrency=1 makes the tarball reproducible (deterministic image order).
  "${STAGE_DIR}/binaries/k0s" airgap bundle-artifacts --concurrency=1 \
    -o "${STAGE_DIR}/images/k0s-images.tar" \
    < "${STAGE_DIR}/images/k0s-images.list" \
    || err "Failed to build k0s system-image bundle (k0s airgap bundle-artifacts)."
  log "k0s system-image bundle written: ${STAGE_DIR}/images/k0s-images.tar ($(du -h "${STAGE_DIR}/images/k0s-images.tar" | cut -f1))"
else
  err "Could not enumerate k0s system images (k0s airgap list-images --all). k0s ${K0S_VERSION} binary may be incompatible."
fi

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

# ── 4b. Add-on component image bundle ──────────────────────────────────────────
# The add-on components (cert-manager, local-path, kube-prometheus-stack, otel,
# kuberay, metallb) reference their images inside their HELM CHARTS and STATIC
# MANIFESTS — NOT in the cluster config — so the installer's registry-rewrite
# never touches them, and on an air-gapped node those pulls (quay.io, ghcr.io,
# rancher, registry.k8s.io, docker.io) time out. We enumerate every image those
# charts+manifests render to, then build a SECOND k0s image bundle (addon-images
# .tar) that the installer drops at /var/lib/k0s/images/ alongside k0s-images.tar.
# k0s imports every tarball in that dir at startup, so containerd already has the
# exact image refs and pods pull them with IfNotPresent — no registry needed.
log "--- Enumerating add-on component images (rendering charts + manifests) ---"
ADDON_LIST="${STAGE_DIR}/images/addon-images.list"
{
  # Static manifests: grep image: refs (skip the bare 'busybox' with no tag — we
  # pin busybox:latest explicitly below so containerd has a concrete ref).
  # Match BOTH *.yaml and *.yml — nvidia-device-plugin.yml uses the .yml
  # extension, so a bare *.yaml glob silently skipped it and its image
  # (nvcr.io/nvidia/k8s-device-plugin) never made it into the bundle, leaving
  # the device-plugin DaemonSet in ImagePullBackOff on air-gapped GPU nodes.
  # `|| true` on each grep pipeline: a no-match returns exit 1, which under
  # `set -euo pipefail` would otherwise abort the whole bundle build before the
  # `[[ -s "${ADDON_LIST}" ]] ... else warn` best-effort fallback below could
  # run. Same guard the PyYAML URL resolution above already uses.
  grep -hoE 'image:[[:space:]]*["'"'"']?[^"'"'"' ]+' \
    "${STAGE_DIR}"/manifests/*.yaml "${STAGE_DIR}"/manifests/*.yml 2>/dev/null \
    | sed -E 's/image:[[:space:]]*["'"'"']?//' || true
  # Helm charts: render with default values and grep image: refs. Guard the glob
  # with compgen so an empty charts/ dir doesn't run the loop once with a literal
  # unexpanded "*.tgz" path (which makes `helm template` fail and, under set -e,
  # abort the build).
  if compgen -G "${STAGE_DIR}/charts/*.tgz" >/dev/null 2>&1; then
    for _tgz in "${STAGE_DIR}"/charts/*.tgz; do
      helm template "${_tgz}" 2>/dev/null \
        | grep -oE 'image:[[:space:]]*["'"'"']?[^"'"'"' ]+' \
        | sed -E 's/image:[[:space:]]*["'"'"']?//' || true
    done
  fi
  # busybox:latest (otel init) — pin a concrete tag so it resolves offline.
  echo "busybox:latest"
} | grep -E '[:/]' | grep -vE '^busybox$' | sort -u > "${ADDON_LIST}"

if [[ -s "${ADDON_LIST}" ]]; then
  log "Add-on images to bundle ($(wc -l < "${ADDON_LIST}")):"
  while IFS= read -r _img; do log "    ${_img}"; done < "${ADDON_LIST}"
  log "Building add-on image bundle (pulls the images above, may take several minutes)..."
  "${STAGE_DIR}/binaries/k0s" airgap bundle-artifacts --concurrency=1 \
    -o "${STAGE_DIR}/images/addon-images.tar" \
    < "${ADDON_LIST}" \
    || err "Failed to build add-on image bundle (k0s airgap bundle-artifacts)."
  log "Add-on image bundle written: ${STAGE_DIR}/images/addon-images.tar ($(du -h "${STAGE_DIR}/images/addon-images.tar" | cut -f1))"
else
  warn "Could not enumerate any add-on images from charts/manifests — add-on pods may fail to pull on air-gapped nodes."
fi

# ── 5. GPU node OS packages ───────────────────────────────────────────────────
# These files are SCPed to GPU nodes by install_from_airgap_bundle.sh before
# the main installer runs so the nodes can install dependencies without internet.
#
# Strategy:
#  - EPEL RPM: installs the EPEL repo (provides DKMS on RHEL/AL2023).
#  - CUDA .repo file: tells dnf/apt where the CUDA packages live.
#    For a fully offline setup the customer must serve the CUDA RPMs from a
#    local HTTP mirror and redirect CUDA_REPO_URL_OVERRIDE to it.
#    Without a local mirror, the .repo file still points at NVIDIA's servers.
#  - nvidia-container-toolkit .repo: same pattern.
#  - PyYAML wheel: pure-Python, installed offline via pip3 --no-index.
log "--- Downloading GPU node OS packages (target OS: ${GPU_NODE_OS}) ---"

# Resolve EPEL major from GPU_NODE_OS
case "${GPU_NODE_OS}" in
  rhel9|amzn2023) EPEL_MAJOR=9 ;;
  rhel10)         EPEL_MAJOR=10 ;;
  *)
    warn "Unknown GPU_NODE_OS '${GPU_NODE_OS}'; defaulting EPEL major to 9"
    EPEL_MAJOR=9 ;;
esac

# EPEL release RPM
EPEL_RPM_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EPEL_MAJOR}.noarch.rpm"
download "${EPEL_RPM_URL}" "${STAGE_DIR}/packages/epel-release-latest-${EPEL_MAJOR}.noarch.rpm"
echo "${EPEL_RPM_URL}" > "${STAGE_DIR}/packages/epel-release-latest-${EPEL_MAJOR}.noarch.rpm.url"

# CUDA repo definition file (text file — not the full RPM package set)
case "${GPU_NODE_OS}" in
  amzn2023)
    CUDA_REPO_FILE_URL="https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo"
    CUDA_REPO_FILENAME="cuda-amzn2023.repo" ;;
  rhel10)
    CUDA_REPO_FILE_URL="https://developer.download.nvidia.com/compute/cuda/repos/rhel10/x86_64/cuda-rhel10.repo"
    CUDA_REPO_FILENAME="cuda-rhel10.repo" ;;
  *)
    CUDA_REPO_FILE_URL="https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo"
    CUDA_REPO_FILENAME="cuda-rhel9.repo" ;;
esac
download "${CUDA_REPO_FILE_URL}" "${STAGE_DIR}/packages/${CUDA_REPO_FILENAME}"

# nvidia-container-toolkit RPM repo definition (text file)
CTK_REPO_URL="https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo"
download "${CTK_REPO_URL}" "${STAGE_DIR}/packages/nvidia-container-toolkit.repo"

# PyYAML — fetched from PyPI so the nodes can install it without pip's network
# access (avoids requiring pip on the bundle machine). PyYAML does NOT publish a
# pure-Python (none-any) wheel — every wheel is platform-specific (cp3x, manylinux,
# win) — so we resolve the real download URL from PyPI's per-version JSON metadata
# rather than guessing a path. The per-version endpoint (.../PyYAML/<ver>/json)
# lists only that release's files in `urls[]`, so the source sdist is matched
# reliably and the modern hash-based pythonhosted URL is used verbatim.
#
# Each grep is guarded with `|| true`: a no-match returns exit 1, which under
# `set -euo pipefail` would otherwise abort the whole script mid-resolution.
log "Resolving PyYAML download URL from PyPI..."
PYYAML_VERSION="$(curl -fsSL https://pypi.org/pypi/PyYAML/json \
  | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
[[ -z "${PYYAML_VERSION}" ]] && err "Could not resolve latest PyYAML version from PyPI."

PYYAML_META="$(curl -fsSL "https://pypi.org/pypi/PyYAML/${PYYAML_VERSION}/json")" \
  || err "Could not fetch PyPI metadata for PyYAML ${PYYAML_VERSION}."

# Prefer a pure-Python wheel if one is ever published (future-proofing); the
# urls[] array here contains only this version's artifacts.
PYYAML_WHEEL_URL="$(echo "${PYYAML_META}" \
  | grep -o '"url":"[^"]*none-any\.whl"' | head -1 | cut -d'"' -f4 || true)"
if [[ -z "${PYYAML_WHEEL_URL}" ]]; then
  # No pure-Python wheel: fall back to the source sdist (pip3 install builds it
  # in-place on the node — the on-node installer already handles this).
  PYYAML_WHEEL_URL="$(echo "${PYYAML_META}" \
    | grep -o '"url":"[^"]*\.tar\.gz"' | head -1 | cut -d'"' -f4 || true)"
  warn "No pure-Python PyYAML wheel published; using source sdist for ${PYYAML_VERSION}."
fi
[[ -z "${PYYAML_WHEEL_URL}" ]] && err "Could not resolve a PyYAML download URL for ${PYYAML_VERSION}."
PYYAML_FILENAME="$(basename "${PYYAML_WHEEL_URL}")"

download "${PYYAML_WHEEL_URL}" "${STAGE_DIR}/packages/${PYYAML_FILENAME}"
echo "${PYYAML_FILENAME}" > "${STAGE_DIR}/packages/pyyaml.filename"

log "GPU node packages downloaded to ${STAGE_DIR}/packages/"

# ── 6. Env-var override manifest ──────────────────────────────────────────────
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

# GPU node OS packages — used by install_from_airgap_bundle.sh to SCP packages
# to each GPU node before the main installer runs.
# The installer reads AIRGAP_PYYAML_WHEEL_PATH to install pyyaml without internet.
# EPEL, CUDA, and CTK packages are distributed as files on the node, then the
# installer uses EPEL_RPM_URL_OVERRIDE / CUDA_REPO_URL_OVERRIDE /
# NVIDIA_CTK_REPO_URL_OVERRIDE to reference those local copies.
PYYAML_FNAME="$(cat "${AIRGAP_BUNDLE_DIR}/packages/pyyaml.filename" 2>/dev/null || echo "")"
if [[ -n "${PYYAML_FNAME}" ]]; then
  export AIRGAP_PYYAML_WHEEL_PATH="${AIRGAP_BUNDLE_DIR}/packages/${PYYAML_FNAME}"
fi
ENVEOF

# ── 7. Container image list ───────────────────────────────────────────────────
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
# Gemma artifact: gemma-4-31b-it for L40S, or
#                 gemma-4-31b-it-qat-w4a16-ct for H100 and RTX Pro.
# Other models: gpt-oss-20b, all-minilm-l6-v2, bi-encoder, cross-encoder,
#               e5-language-classifier, fm_timeseries, mbart-translator,
#               pii-classifier, uae-large, xlm-roberta-language-classifier
IMGEOF

# ── 8. Write version manifest ─────────────────────────────────────────────────
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
gpu_node_os=${GPU_NODE_OS}
epel_major=${EPEL_MAJOR}
bundle_timestamp=${BUNDLE_TIMESTAMP}
VEOF

# ── 9. Checksums ──────────────────────────────────────────────────────────────
log "--- Computing checksums ---"
(
  cd "${STAGE_DIR}"
  find . -type f ! -name "checksums.sha256" | sed 's|^\./||' | sort | while read -r f; do
    printf "%s  %s\n" "$(sha256 "$f")" "$f"
  done
) > "${STAGE_DIR}/checksums.sha256"
log "Checksums written to ${STAGE_DIR}/checksums.sha256"

# ── 10. Pack the bundle ───────────────────────────────────────────────────────
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
