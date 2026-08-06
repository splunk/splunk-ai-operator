#!/usr/bin/env bash
# prepare_airgap_bundle.sh
# Run on an internet-connected machine to download every binary, Helm chart,
# and static manifest needed by k0s_cluster_with_stack.sh. Produces a single
# tar.gz that can be copied to an air-gapped cluster and consumed by
# install_from_airgap_bundle.sh.
#
# Usage:
#   ./prepare_airgap_bundle.sh [--output-dir DIR] [--k0s-version VERSION]
#                              [--config k0s-cluster-config.yaml]
#
# Requirements on this machine:
#   Linux/amd64, curl, helm, tar, gzip, sha256sum
#   yq v4 when --config is supplied

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Versions (keep in sync with k0s_cluster_with_stack.sh) ─────────────────
YQ_VERSION="v4.44.1"
CERT_MANAGER_VERSION="v1.21.1"
LOCAL_PATH_PROVISIONER_VERSION="v0.0.24"
# local-path-provisioner v0.0.24 embeds an untagged helper image in its
# ConfigMap. Rewrite that runtime manifest to an immutable digest before it is
# bundled so an offline install never resolves the mutable implicit :latest.
LOCAL_PATH_HELPER_IMAGE="docker.io/library/busybox@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0"
NVIDIA_DEVICE_PLUGIN_VERSION="v0.17.3"
METALLB_CHART_VERSION="0.14.8"
KUBERAY_CHART_VERSION="1.2.2"
DEFAULT_TRAEFIK_IMAGE="docker.io/library/traefik:v3.6.25@sha256:31267173a15b4944e797a76ffd9c419707c8d8b32fe5b610f80cd0cfa05f372d"

# Keep the default aligned with k0s_cluster_with_stack.sh and cert-manager's
# tested Kubernetes range. An explicit override is accepted only when it still
# embeds Kubernetes 1.33-1.36.
DEFAULT_K0S_VERSION="v1.33.13+k0s.1"
K0S_VERSION="${K0S_VERSION:-${DEFAULT_K0S_VERSION}}"

# Target OS for GPU node RPM packages. Only rhel9 is tested and supported.
# rhel10 and amzn2023 code paths are kept for internal testing only.
GPU_NODE_OS="${GPU_NODE_OS:-rhel9}"

OUTPUT_DIR="${OUTPUT_DIR:-./airgap-bundle}"
BUNDLE_CONFIG_FILE="${BUNDLE_CONFIG_FILE:-}"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --k0s-version) K0S_VERSION="$2"; shift 2 ;;
    --gpu-os)      GPU_NODE_OS="$2"; shift 2 ;;
    --config)      BUNDLE_CONFIG_FILE="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELP'
prepare_airgap_bundle.sh — download all Splunk AI Platform install artifacts
into a self-contained tar.gz bundle for air-gapped deployments.

USAGE
  ./prepare_airgap_bundle.sh [OPTIONS]

BUILD HOST
  Linux/amd64 is required. The script executes the downloaded k0s Linux/amd64
  binary while constructing the offline image archives.

OPTIONS
  --output-dir DIR      Directory where the bundle is written.
                        Default: ./airgap-bundle
                        Env: OUTPUT_DIR

  --k0s-version VER     Specific supported k0s release to download
                        (e.g. v1.35.2+k0s.0).
                        Default: v1.33.13+k0s.1 (compatibility pin)
                        The embedded Kubernetes minor must be 1.33-1.36.
                        Env: K0S_VERSION

  --gpu-os OS           Target OS for GPU node package files.
                        Supported: rhel9 (default — only tested/supported value)
                        Env: GPU_NODE_OS
                        Only RHEL 9 is tested and supported.
                        Any other value will error.

  --config FILE         Cluster config that will be used for the offline install.
                        When ingress.enabled is true, the configured
                        images.ingress.traefikImage is added to both the k0s
                        add-on image tar and container-images.txt.
                        Requires mikefarah/yq v4 on the bundle-building host.
                        Env: BUNDLE_CONFIG_FILE

  -h, --help            Show this help text.

WHAT IS BUNDLED
  binaries/
    k0s          — k0s Kubernetes binary (linux/amd64)
    yq           — YAML processor used by the installer

  manifests/
    cert-manager.yaml          — cert-manager CRDs + controller
    local-path-storage.yaml    — Rancher local-path provisioner
    nvidia-device-plugin.yml   — NVIDIA GPU device plugin DaemonSet
    traefik/                   — pinned Traefik CRDs + installer RBAC template

  charts/
    kube-prometheus-stack-*.tgz   — Prometheus + Grafana (version resolved at bundle time)
    opentelemetry-operator-*.tgz  — OTel operator (version resolved at bundle time)
    kuberay-operator-1.2.2.tgz    — KubeRay operator (pinned)
    metallb-0.14.8.tgz            — MetalLB load-balancer (pinned)

  packages/  (GPU node OS packages — for fully offline GPU worker setup)
    epel-release-latest-<N>.noarch.rpm  — EPEL RPM for RHEL/AL2023
    cuda-<os>.repo                      — CUDA package repository definition
    nvidia-container-toolkit.repo       — nvidia-container-toolkit RPM repo definition

  airgap-env.sh         — Source this to set env-var overrides before a manual install
  container-images.txt  — List of container images to mirror to your internal registry
                          (includes Traefik when --config enables ingress)
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
  TRAEFIK_MANIFEST_DIR              Directory containing pinned Traefik CRDs/RBAC
  PROMETHEUS_CHART_PATH             Local path to kube-prometheus-stack .tgz
  OTEL_CHART_PATH                   Local path to opentelemetry-operator .tgz
  KUBERAY_CHART_PATH                Local path to kuberay-operator .tgz
  METALLB_CHART_PATH                Local path to metallb .tgz
  EPEL_RPM_URL_OVERRIDE             URL/path to EPEL release RPM (GPU nodes)
  CUDA_REPO_URL_OVERRIDE            URL/path to CUDA .repo file (GPU nodes)
  NVIDIA_CTK_REPO_URL_OVERRIDE      URL/path to nvidia-container-toolkit .repo (GPU nodes)
  AIRGAP_K0S_IMAGE_DIR              Directory containing offline OCI image archives
  AIRGAP_BUNDLE_VERSION_FILE        Verified bundle-versions.txt path
  BUNDLE_CERT_MANAGER_VERSION       Verified cert-manager version metadata
  BUNDLE_INGRESS_ENABLED            Verified ingress-enabled metadata
  BUNDLE_TRAEFIK_IMAGE              Verified Traefik image metadata
  AIRGAP_MODE                       Always true for a sourced air-gap environment

EXAMPLES
  # Basic bundle (RHEL 9 GPU nodes — only supported target)
  ./prepare_airgap_bundle.sh

  # Custom output directory and pinned k0s version
  ./prepare_airgap_bundle.sh --output-dir /mnt/transfer --k0s-version v1.35.2+k0s.0

  # Include the configured Traefik image when HTTPS ingress is enabled
  ./prepare_airgap_bundle.sh --config ./k0s-cluster-config.yaml

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

pin_local_path_helper_image() {
  local manifest="$1"
  local temp_manifest="${manifest}.tmp"

  # The helperPod.yaml is embedded inside a ConfigMap, so a Kubernetes-aware
  # YAML rewrite cannot address it as a normal Pod field. Require exactly one
  # replacement; a changed upstream manifest must fail the bundle build rather
  # than silently reintroduce an untagged helper image.
  if ! awk -v replacement="${LOCAL_PATH_HELPER_IMAGE}" '
    BEGIN { replacements = 0 }
    /^[[:space:]]*image:[[:space:]]*busybox[[:space:]]*$/ {
      sub(/busybox[[:space:]]*$/, replacement)
      replacements++
    }
    { print }
    END { if (replacements != 1) exit 42 }
  ' "${manifest}" > "${temp_manifest}"; then
    rm -f -- "${temp_manifest}"
    err "Expected exactly one untagged local-path helper image in ${manifest}; upstream manifest format may have changed."
  fi

  mv -- "${temp_manifest}" "${manifest}"
}

extract_image_references() {
  local manifest="$1"
  local references

  # Operators often carry images for workloads they create later in command
  # arguments (for example --collector-image=... or
  # --prometheus-config-reloader=...), not in their own Pod's `image:` field.
  # Those deferred images are just as necessary offline as directly rendered
  # containers, so enumerate both forms from the final rendered manifest.
  references="$({
    grep -hoE 'image:[[:space:]]*["'"'"']?[^"'"'"'[:space:]]+' "${manifest}" \
      | sed -E 's/^image:[[:space:]]*["'"'"']?//' || true
    grep -hoE -- '--[[:alnum:]_.-]+=([[:alnum:]_.-]+(:[0-9]+)?/)+([[:alnum:]_.-]+:[[:alnum:]_][[:alnum:]_.-]*(@sha256:[[:xdigit:]]{64})?|[[:alnum:]_.-]+@sha256:[[:xdigit:]]{64})' "${manifest}" \
      | sed -E 's/^--[[:alnum:]_.-]+=//' || true
  } | sed '/^$/d')"
  [[ -n "${references}" ]] || return 1
  printf '%s\n' "${references}"
}

render_chart_for_image_inventory() {
  local chart_path="$1" output_path="$2" chart_file release_name namespace
  local -a install_values=()

  chart_file="$(basename "${chart_path}")"
  case "${chart_file}" in
    kube-prometheus-stack-*.tgz)
      release_name="kube-prometheus-stack"
      namespace="monitoring"
      install_values=(
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
      )
      ;;
    opentelemetry-operator-*.tgz)
      release_name="opentelemetry-operator"
      namespace="opentelemetry-operator-system"
      # Keep these values identical to install_otel_operator_and_contrib_collector.
      install_values=(
        --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib
        --set admissionWebhooks.certManager.enabled=true
      )
      ;;
    kuberay-operator-*.tgz)
      release_name="kuberay-operator"
      namespace="ray-system"
      install_values=(
        --set image.repository=quay.io/kuberay/operator
        --set image.tag=v1.2.2
      )
      ;;
    metallb-*.tgz)
      release_name="metallb"
      namespace="metallb-system"
      ;;
    *)
      err "No install-equivalent image-rendering profile exists for chart: ${chart_file}"
      ;;
  esac

  # Helm test hooks are not installed by `helm upgrade --install`; including
  # them adds mutable helper images that are irrelevant to runtime and
  # breaks deterministic offline inventory validation.
  if ! helm template "${release_name}" "${chart_path}" \
    --namespace "${namespace}" \
    --skip-tests \
    "${install_values[@]}" > "${output_path}"; then
    err "Failed to render ${chart_file} while enumerating add-on images."
  fi
  [[ -s "${output_path}" ]] \
    || err "Helm rendered no manifests for ${chart_file}; refusing an incomplete add-on image bundle."
}

validate_addon_image_reference() {
  local image="$1" name_part leaf tag digest

  [[ -n "${image}" ]] || err "Add-on image inventory contains an empty reference."
  [[ "${image}" != *[[:space:]]* ]] \
    || err "Add-on image reference contains whitespace: ${image}"
  [[ "${image}" != *'{{'* && "${image}" != *'}}'* ]] \
    || err "Add-on image reference was not fully rendered: ${image}"

  name_part="${image%@*}"
  [[ "${name_part}" != *@* ]] \
    || err "Add-on image reference contains multiple digest separators: ${image}"
  leaf="${name_part##*/}"
  if [[ "${leaf}" == *:* ]]; then
    tag="${leaf##*:}"
    [[ -n "${tag}" ]] || err "Add-on image reference has an empty tag: ${image}"
    [[ "${tag}" != "latest" ]] \
      || err "Mutable :latest image is not allowed in the add-on bundle: ${image}"
  elif [[ "${image}" != *@* ]]; then
    err "Untagged image is not allowed in the add-on bundle: ${image}"
  fi

  if [[ "${image}" == *@* ]]; then
    digest="${image##*@}"
    [[ "${digest}" =~ ^sha256:[[:xdigit:]]{64}$ ]] \
      || err "Add-on image has an invalid or unsupported digest: ${image}"
  fi
}

validate_addon_image_list() {
  local image image_count=0

  while IFS= read -r image || [[ -n "${image}" ]]; do
    image="${image%$'\r'}"
    validate_addon_image_reference "${image}"
    ((image_count += 1))
  done < "$1"

  (( image_count > 0 )) \
    || err "Could not enumerate any add-on images from the staged charts and manifests."
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
require_cmd curl
require_cmd helm
require_cmd tar
[[ "$(uname -s)" == "Linux" && "$(uname -m)" == "x86_64" ]] || \
  err "Bundle preparation requires a Linux/amd64 host because it executes the downloaded k0s Linux/amd64 binary"

if [[ -n "${BUNDLE_CONFIG_FILE}" ]]; then
  [[ -f "${BUNDLE_CONFIG_FILE}" ]] \
    || err "Cluster config not found: ${BUNDLE_CONFIG_FILE}"
  # The staged yq binary targets the offline nodes. Use the build host's yq to
  # resolve the supplied configuration.
  require_cmd yq
fi

INGRESS_ENABLED="false"
TRAEFIK_IMAGE=""
if [[ -n "${BUNDLE_CONFIG_FILE}" ]]; then
  ingress_value="$(yq eval -r '.ingress.enabled // false' "${BUNDLE_CONFIG_FILE}")" \
    || err "Could not read ingress.enabled from ${BUNDLE_CONFIG_FILE}"
  if [[ "${ingress_value}" == "true" ]]; then
    INGRESS_ENABLED="true"
    TRAEFIK_IMAGE="$(yq eval -r ".images.ingress.traefikImage // \"${DEFAULT_TRAEFIK_IMAGE}\"" "${BUNDLE_CONFIG_FILE}")" \
      || err "Could not read images.ingress.traefikImage from ${BUNDLE_CONFIG_FILE}"
    [[ -n "${TRAEFIK_IMAGE}" && "${TRAEFIK_IMAGE}" != "null" ]] \
      || err "ingress.enabled=true requires a non-empty images.ingress.traefikImage"
  fi
fi

log "=== Splunk AI Platform — Air-Gap Bundle Preparation ==="
log "Output directory : ${OUTPUT_DIR}"
log "Bundle name      : ${BUNDLE_NAME}"
if [[ -n "${BUNDLE_CONFIG_FILE}" ]]; then
  log "Cluster config   : ${BUNDLE_CONFIG_FILE}"
  log "HTTPS ingress    : ${INGRESS_ENABLED}"
  [[ "${INGRESS_ENABLED}" == "true" ]] && log "Traefik image    : ${TRAEFIK_IMAGE}"
else
  log "Cluster config   : not supplied (Traefik image will not be bundled)"
fi
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
  "${STAGE_DIR}/manifests/traefik" \
  "${STAGE_DIR}/charts" \
  "${STAGE_DIR}/packages"

# These manifests are vendored with the installer rather than downloaded at
# bundle-build time. Include them so a bundle remains self-contained even when
# the operator copied only the top-level installer scripts to the offline host.
for traefik_manifest in traefik-crds.yaml traefik-rbac.yaml; do
  [[ -f "${SCRIPT_DIR}/traefik/${traefik_manifest}" ]] \
    || err "Required Traefik manifest is missing: ${SCRIPT_DIR}/traefik/${traefik_manifest}"
  cp "${SCRIPT_DIR}/traefik/${traefik_manifest}" \
    "${STAGE_DIR}/manifests/traefik/${traefik_manifest}"
done

# ── 1. k0s binary ─────────────────────────────────────────────────────────────
log "--- Downloading k0s binary ---"
if [[ "${K0S_VERSION}" == "latest" ]]; then
  K0S_VERSION="$(curl -fsSL https://api.github.com/repos/k0sproject/k0s/releases/latest \
    | grep '"tag_name"' | sed 's/.*"tag_name": "\(.*\)".*/\1/')"
  log "Resolved explicitly requested latest k0s version: ${K0S_VERSION}"
fi
if [[ ! "${K0S_VERSION}" =~ ^v1\.([0-9]+)\.[0-9]+\+k0s\.[0-9]+$ ]] || \
    (( 10#${BASH_REMATCH[1]:-0} < 33 || 10#${BASH_REMATCH[1]:-0} > 36 )); then
  err "k0s ${K0S_VERSION} is outside cert-manager ${CERT_MANAGER_VERSION}'s supported Kubernetes 1.33-1.36 range"
fi

K0S_URL="https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION}/k0s-${K0S_VERSION}-amd64"
download "${K0S_URL}" "${STAGE_DIR}/binaries/k0s"
chmod +x "${STAGE_DIR}/binaries/k0s"
echo "${K0S_VERSION}" > "${STAGE_DIR}/binaries/k0s.version"

# ── 1b. k0s system-image bundle (pause, calico, kube-proxy, coredns, etc.) ─────
# k0s pulls its OWN control-plane images (quay.io/k0sproject/*) at startup; in an
# air-gapped cluster those pulls time out. k0s solves this natively: any OCI image
# bundle dropped at /var/lib/k0s/images/ is auto-imported into containerd before
# the kubelet starts. We build that bundle on this connected Linux host using the exact
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
pin_local_path_helper_image "${STAGE_DIR}/manifests/local-path-storage.yaml"

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
# kuberay, metallb, and optionally Traefik) reference images outside the normal
# application-image rewrite path. Charts and static manifests carry most of
# those references; Traefik is read from the supplied cluster config.
# The installer's application-image registry rewrite does not cover these
# references, so on an air-gapped node their pulls would time out. We enumerate
# every image those charts/manifests render plus the configured Traefik image,
# then build a SECOND k0s image bundle (addon-images.tar) that the installer
# drops at /var/lib/k0s/images/ alongside k0s-images.tar.
# k0s imports every tarball in that directory before first start or through its
# live image-directory watcher, so containerd has the exact image refs before
# add-on installation continues — no registry needed.
log "--- Enumerating add-on component images (rendering charts + manifests) ---"
ADDON_LIST="${STAGE_DIR}/images/addon-images.list"
ADDON_CANDIDATES="${STAGE_DIR}/images/.addon-images.candidates"
: > "${ADDON_CANDIDATES}"

# Static manifests are installation inputs too. Require every expected manifest
# to exist and contain at least one image rather than treating a missing glob or
# parser mismatch as an empty, apparently successful inventory.
for _manifest in \
  "${STAGE_DIR}/manifests/cert-manager.yaml" \
  "${STAGE_DIR}/manifests/local-path-storage.yaml" \
  "${STAGE_DIR}/manifests/nvidia-device-plugin.yml"; do
  [[ -s "${_manifest}" ]] || err "Required add-on manifest is missing or empty: ${_manifest}"
  if ! extract_image_references "${_manifest}" >> "${ADDON_CANDIDATES}"; then
    err "Could not enumerate an image from required add-on manifest: ${_manifest}"
  fi
done

# Render the exact four charts that were staged. Each profile mirrors the
# installer's values, and any Helm error or empty render aborts the build.
for _tgz in \
  "${STAGE_DIR}/charts/kube-prometheus-stack-${PROMETHEUS_CHART_VERSION}.tgz" \
  "${STAGE_DIR}/charts/opentelemetry-operator-${OTEL_CHART_VERSION}.tgz" \
  "${STAGE_DIR}/charts/kuberay-operator-${KUBERAY_CHART_VERSION}.tgz" \
  "${STAGE_DIR}/charts/metallb-${METALLB_CHART_VERSION}.tgz"; do
  [[ -s "${_tgz}" ]] || err "Required add-on chart is missing or empty: ${_tgz}"
  _rendered_manifest="${STAGE_DIR}/images/.rendered-$(basename "${_tgz}").yaml"
  render_chart_for_image_inventory "${_tgz}" "${_rendered_manifest}"
  if ! extract_image_references "${_rendered_manifest}" >> "${ADDON_CANDIDATES}"; then
    err "Rendered chart contains no image references: ${_tgz}"
  fi
  rm -f -- "${_rendered_manifest}"
done

# Traefik is configured directly rather than rendered from a chart/manifest.
if [[ "${INGRESS_ENABLED}" == "true" ]]; then
  printf '%s\n' "${TRAEFIK_IMAGE}" >> "${ADDON_CANDIDATES}"
fi

sort -u "${ADDON_CANDIDATES}" > "${ADDON_LIST}"
rm -f -- "${ADDON_CANDIDATES}"
validate_addon_image_list "${ADDON_LIST}"

log "Add-on images to bundle ($(wc -l < "${ADDON_LIST}")):"
while IFS= read -r _img; do log "    ${_img}"; done < "${ADDON_LIST}"
log "Building add-on image bundle (pulls the images above, may take several minutes)..."
"${STAGE_DIR}/binaries/k0s" airgap bundle-artifacts --concurrency=1 \
  -o "${STAGE_DIR}/images/addon-images.tar" \
  < "${ADDON_LIST}" \
  || err "Failed to build add-on image bundle (k0s airgap bundle-artifacts)."
log "Add-on image bundle written: ${STAGE_DIR}/images/addon-images.tar ($(du -h "${STAGE_DIR}/images/addon-images.tar" | cut -f1))"

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

_airgap_env_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

_airgap_env_read_value() {
  local key="$1" version_file="$2" occurrences
  occurrences="$(grep -c "^${key}=" "${version_file}" || true)"
  if [[ "${occurrences}" != "1" ]]; then
    _airgap_env_error "${version_file} must contain exactly one ${key}= entry (found ${occurrences})"
    return 1
  fi
  awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "${version_file}"
}

_airgap_env_read_required_value() {
  local key="$1" version_file="$2" value
  value="$(_airgap_env_read_value "${key}" "${version_file}")" || return 1
  if [[ -z "${value}" ]]; then
    _airgap_env_error "${version_file} contains an empty ${key}= value"
    return 1
  fi
  printf '%s\n' "${value}"
}

_airgap_env_configure() {
  local version_file binary_version_file binary_k0s_version
  local bundle_k0s_version bundle_cert_manager_version
  local bundle_ingress_enabled bundle_traefik_image
  local bundle_prometheus_version bundle_otel_version
  local bundle_kuberay_version bundle_metallb_version
  local marker_version _airgap_binary _airgap_marker

  if [[ -z "${AIRGAP_BUNDLE_DIR:-}" ]]; then
    _airgap_env_error "AIRGAP_BUNDLE_DIR must be set to the bundle extraction path"
    return 1
  fi

  version_file="${AIRGAP_BUNDLE_DIR}/bundle-versions.txt"
  binary_version_file="${AIRGAP_BUNDLE_DIR}/binaries/k0s.version"
  if [[ ! -f "${version_file}" ]]; then
    _airgap_env_error "bundle-versions.txt is missing from ${AIRGAP_BUNDLE_DIR}"
    return 1
  fi
  if [[ ! -s "${binary_version_file}" ]]; then
    _airgap_env_error "binaries/k0s.version is missing or empty in ${AIRGAP_BUNDLE_DIR}"
    return 1
  fi

  bundle_k0s_version="$(_airgap_env_read_required_value k0s_version "${version_file}")" || return 1
  bundle_cert_manager_version="$(_airgap_env_read_required_value cert_manager_version "${version_file}")" || return 1
  bundle_ingress_enabled="$(_airgap_env_read_required_value ingress_enabled "${version_file}")" || return 1
  bundle_traefik_image="$(_airgap_env_read_value traefik_image "${version_file}")" || return 1
  bundle_prometheus_version="$(_airgap_env_read_required_value prometheus_chart_version "${version_file}")" || return 1
  bundle_otel_version="$(_airgap_env_read_required_value otel_chart_version "${version_file}")" || return 1
  bundle_kuberay_version="$(_airgap_env_read_required_value kuberay_chart_version "${version_file}")" || return 1
  bundle_metallb_version="$(_airgap_env_read_required_value metallb_chart_version "${version_file}")" || return 1

  binary_k0s_version="$(tr -d '\r\n' < "${binary_version_file}")"
  if [[ "${binary_k0s_version}" != "${bundle_k0s_version}" ]]; then
    _airgap_env_error "k0s version mismatch: bundle-versions.txt says ${bundle_k0s_version}, binaries/k0s.version says ${binary_k0s_version:-empty}"
    return 1
  fi
  if [[ "${bundle_cert_manager_version}" != "v1.21.1" ]]; then
    _airgap_env_error "bundle cert-manager version ${bundle_cert_manager_version} does not match installer requirement v1.21.1"
    return 1
  fi
  if [[ "${bundle_ingress_enabled}" != "true" && "${bundle_ingress_enabled}" != "false" ]]; then
    _airgap_env_error "ingress_enabled must be true or false, got ${bundle_ingress_enabled}"
    return 1
  fi
  if [[ "${bundle_ingress_enabled}" == "true" && -z "${bundle_traefik_image}" ]]; then
    _airgap_env_error "bundle enables ingress but traefik_image is empty"
    return 1
  fi

  for _airgap_binary in k0s yq; do
    if [[ ! -f "${AIRGAP_BUNDLE_DIR}/binaries/${_airgap_binary}" ]]; then
      _airgap_env_error "bundled binary is missing: binaries/${_airgap_binary}"
      return 1
    fi
  done
  if [[ ! -d "${AIRGAP_BUNDLE_DIR}/images" ]] || \
      ! compgen -G "${AIRGAP_BUNDLE_DIR}/images/*.tar" >/dev/null 2>&1; then
    _airgap_env_error "bundle has no pre-loaded k0s image archives under images/*.tar"
    return 1
  fi

  for _airgap_marker in kube-prometheus-stack.version opentelemetry-operator.version; do
    if [[ ! -s "${AIRGAP_BUNDLE_DIR}/charts/${_airgap_marker}" ]]; then
      _airgap_env_error "chart version marker is missing or empty: charts/${_airgap_marker}"
      return 1
    fi
  done
  marker_version="$(tr -d '\r\n' < "${AIRGAP_BUNDLE_DIR}/charts/kube-prometheus-stack.version")"
  if [[ "${marker_version}" != "${bundle_prometheus_version}" ]]; then
    _airgap_env_error "Prometheus chart version marker does not match bundle-versions.txt"
    return 1
  fi
  marker_version="$(tr -d '\r\n' < "${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator.version")"
  if [[ "${marker_version}" != "${bundle_otel_version}" ]]; then
    _airgap_env_error "OpenTelemetry chart version marker does not match bundle-versions.txt"
    return 1
  fi

  export AIRGAP_MODE="true"
  export AIRGAP_K0S_IMAGE_DIR="${AIRGAP_BUNDLE_DIR}/images"
  export AIRGAP_BUNDLE_VERSION_FILE="${version_file}"
  export BUNDLE_K0S_VERSION="${bundle_k0s_version}"
  export BUNDLE_CERT_MANAGER_VERSION="${bundle_cert_manager_version}"
  export BUNDLE_INGRESS_ENABLED="${bundle_ingress_enabled}"
  export BUNDLE_TRAEFIK_IMAGE="${bundle_traefik_image}"

  export K0S_INSTALL_URL="file://${AIRGAP_BUNDLE_DIR}/binaries/k0s"
  export K0S_VERSION="${bundle_k0s_version}"
  export YQ_DOWNLOAD_URL="file://${AIRGAP_BUNDLE_DIR}/binaries/yq"

  export CERT_MANAGER_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/cert-manager.yaml"
  export LOCAL_PATH_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/local-path-storage.yaml"
  export NVIDIA_DEVICE_PLUGIN_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/nvidia-device-plugin.yml"
  export TRAEFIK_MANIFEST_DIR="${AIRGAP_BUNDLE_DIR}/manifests/traefik"

  export PROMETHEUS_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/kube-prometheus-stack-${bundle_prometheus_version}.tgz"
  export OTEL_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator-${bundle_otel_version}.tgz"
  export KUBERAY_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/kuberay-operator-${bundle_kuberay_version}.tgz"
  export METALLB_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/metallb-${bundle_metallb_version}.tgz"

}

_airgap_env_status=0
_airgap_env_configure || _airgap_env_status=$?
unset -f _airgap_env_configure _airgap_env_read_required_value \
  _airgap_env_read_value _airgap_env_error
if (( _airgap_env_status != 0 )); then
  _airgap_env_failed_status="${_airgap_env_status}"
  unset _airgap_env_status
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return "${_airgap_env_failed_status}"
  fi
  exit "${_airgap_env_failed_status}"
fi
unset _airgap_env_status _airgap_env_failed_status
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
# After mirroring application images, set images.registry in your config.
# Traefik is intentionally an exact, independently pinned reference: set
# images.ingress.traefikImage to its mirrored tag/digest explicitly.

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

if [[ "${INGRESS_ENABLED}" == "true" ]]; then
  {
    printf '\n# ── Traefik HTTPS ingress (from bundle-build config) ──\n'
    printf '%s\n' "${TRAEFIK_IMAGE}"
  } >> "${STAGE_DIR}/container-images.txt"
fi

# ── 8. Write version manifest ─────────────────────────────────────────────────
cat > "${STAGE_DIR}/bundle-versions.txt" <<VEOF
k0s_version=${K0S_VERSION}
yq_version=${YQ_VERSION}
cert_manager_version=${CERT_MANAGER_VERSION}
local_path_provisioner_version=${LOCAL_PATH_PROVISIONER_VERSION}
local_path_helper_image=${LOCAL_PATH_HELPER_IMAGE}
nvidia_device_plugin_version=${NVIDIA_DEVICE_PLUGIN_VERSION}
metallb_chart_version=${METALLB_CHART_VERSION}
kuberay_chart_version=${KUBERAY_CHART_VERSION}
prometheus_chart_version=${PROMETHEUS_CHART_VERSION}
otel_chart_version=${OTEL_CHART_VERSION}
gpu_node_os=${GPU_NODE_OS}
ingress_enabled=${INGRESS_ENABLED}
traefik_image=${TRAEFIK_IMAGE}
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
