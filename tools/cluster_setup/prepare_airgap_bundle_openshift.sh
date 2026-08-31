#!/usr/bin/env bash
# Build the installer-owned OpenShift transfer bundle on a connected machine.
# Customer-provided application images from images.* and model weights are
# deliberately excluded. Operator Lifecycle Manager content and infrastructure
# images are captured with Red Hat oc-mirror v2 for automatic import later.

set -euo pipefail

CERT_MANAGER_VERSION="v1.13.0"
LOCAL_PATH_PROVISIONER_VERSION="v0.0.26"
KUBERAY_CHART_VERSION="1.2.2"
OTEL_CHART_VERSION="0.121.0"
QUALIFIED_OPENSHIFT_VERSION="4.21"
NFD_CHANNEL="stable"
GPU_CHANNEL="v26.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/openshift-cluster-config.yaml}"
OUTPUT_DIR="${OUTPUT_DIR:-./airgap-bundle-openshift}"

# Print the connected-side bundle-builder contract and command options.
usage() {
  cat <<'HELP'
prepare_airgap_bundle_openshift.sh — build the installer-owned content bundle
for a disconnected OpenShift deployment.

USAGE
  ./prepare_airgap_bundle_openshift.sh [OPTIONS]

OPTIONS
  --config FILE       OpenShift cluster config used by the target install.
                      Default: ./openshift-cluster-config.yaml beside this script
  --output-dir DIR    Output directory. Default: ./airgap-bundle-openshift
  -h, --help          Show this help.

BUNDLED AUTOMATICALLY
  - cert-manager and local-path-provisioner manifests
  - KubeRay Operator and OpenTelemetry Operator Helm charts
  - infrastructure images referenced by the manifests and charts
  - Node Feature Discovery Operator package and operand images
  - NVIDIA GPU Operator package, driver, and operand images
  - the target cluster's current OpenShift Driver Toolkit image
  - the oc-mirror binary used to import the image archives

NOT BUNDLED
  - application images listed under images.* in the cluster config; the customer
    must provide those in the configured internal registry
  - model weights; install-time model staging checks the configured object store,
    skips current models, and downloads/uploads only missing or changed models
  - registry credentials, object-store credentials, or Hugging Face tokens

REQUIREMENTS
  curl, helm, jq, oc, oc-mirror, tar, yq v4
  - Bundle preparation requires Linux because Red Hat distributes oc-mirror
    for Linux.
  - oc must be logged in to the target OpenShift cluster so its exact Driver
    Toolkit image can be discovered.
  - oc-mirror must be able to pull from Red Hat and public registries. The
    normal openshift_with_stack.sh install entry point builds its auth file from
    the cluster pull secret and imagePullSecrets.custom. For direct standalone
    use of this helper, REGISTRY_AUTH_FILE remains available.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO  $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR $*" >&2; exit 1; }

# Fail early when a required connected-side command is unavailable.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required tool not found: $1"
}

# Print a portable SHA-256 digest on Linux or macOS.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Download one pinned manifest with bounded retries.
download() {
  local url="$1" dest="$2"
  log "Downloading $(basename "${dest}")"
  curl -fsSL --retry 3 --retry-delay 5 -o "${dest}" "${url}" \
    || err "Download failed: ${url}"
}

# Resolve a file path without depending on GNU realpath.
absolute_path() {
  local path="$1" dir base
  dir=$(cd "$(dirname "${path}")" && pwd)
  base=$(basename "${path}")
  printf '%s/%s\n' "${dir}" "${base}"
}

# Match openshift_with_stack.sh image resolution so this inventory names the
# exact application references the customer must make available.
resolved_application_image() {
  local image="$1" registry="$2"
  if [[ "${image}" =~ ^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?)/.*:.+ ]]; then
    printf '%s\n' "${image}"
  elif [[ -n "${registry}" && "${registry}" != "null" ]]; then
    printf '%s/%s\n' "${registry%/}" "${image#/}"
  else
    printf '%s\n' "${image}"
  fi
}

# oc-mirror v2 requires an explicit registry hostname for additionalImages.
# Kubernetes treats unqualified names as Docker Hub references; record that
# expansion directly so the mirror mapping is deterministic.
qualified_additional_image() {
  local image="$1" first
  first="${image%%/*}"
  if [[ "${image}" != */* ]]; then
    printf 'docker.io/library/%s\n' "${image}"
  elif [[ "${first}" == *.* || "${first}" == *:* || "${first}" == "localhost" ]]; then
    printf '%s\n' "${image}"
  else
    printf 'docker.io/%s\n' "${image}"
  fi
}

# Append concrete container image references rendered in a static manifest.
append_manifest_images() {
  local file="$1" output="$2"
  yq eval \
    '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' \
    "${file}" 2>/dev/null \
    | sed '/^---$/d' \
    | grep -v '^busybox\(:.*\)\?$' \
    >> "${output}" || true
}

# Render a Helm chart and append images used by non-test workloads.
append_chart_images() {
  local release="$1" chart="$2" output="$3"
  helm template "${release}" "${chart}" 2>/dev/null \
    | yq eval \
        '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' - 2>/dev/null \
    | sed '/^---$/d' \
    | grep -v '^busybox\(:.*\)\?$' \
    >> "${output}" || true
}

[[ "$(uname -s)" == "Linux" ]] \
  || err "Disconnected bundle preparation requires Linux because Red Hat oc-mirror is Linux-only."
require_cmd oc-mirror
for tool in curl helm jq oc tar yq; do require_cmd "${tool}"; done
[[ -f "${CONFIG_FILE}" ]] || err "Config file not found: ${CONFIG_FILE}"
yq eval '.' "${CONFIG_FILE}" >/dev/null || err "Invalid YAML: ${CONFIG_FILE}"
oc whoami >/dev/null 2>&1 || err "oc is not logged in to the target OpenShift cluster"

CONFIG_FILE=$(absolute_path "${CONFIG_FILE}")
OPENSHIFT_VERSION=$(yq eval ".openshift.requiredVersion // \"${QUALIFIED_OPENSHIFT_VERSION}\"" "${CONFIG_FILE}")
[[ "${OPENSHIFT_VERSION}" == "${QUALIFIED_OPENSHIFT_VERSION}" ]] \
  || err "This installer bundle is qualified only for OpenShift ${QUALIFIED_OPENSHIFT_VERSION}; config requests ${OPENSHIFT_VERSION}"
IMAGE_REGISTRY=$(yq eval '.images.registry // ""' "${CONFIG_FILE}")

DRIVER_TOOLKIT_IMAGE="${OPENSHIFT_DRIVER_TOOLKIT_IMAGE:-}"
if [[ -z "${DRIVER_TOOLKIT_IMAGE}" ]]; then
  DRIVER_TOOLKIT_IMAGE=$(oc get imagestream driver-toolkit -n openshift -o json 2>/dev/null \
    | jq -r '[.status.tags[]?.items[]?.dockerImageReference][0] // empty')
fi
[[ -n "${DRIVER_TOOLKIT_IMAGE}" ]] || err "Could not resolve the target cluster's OpenShift Driver Toolkit image. Log in with oc or set OPENSHIFT_DRIVER_TOOLKIT_IMAGE to its digest reference."

BUNDLE_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE_NAME="airgap-bundle-openshift-${BUNDLE_TIMESTAMP}"
STAGE_DIR="${OUTPUT_DIR}/${BUNDLE_NAME}"
mkdir -p "${STAGE_DIR}/bin" "${STAGE_DIR}/charts" "${STAGE_DIR}/manifests" "${STAGE_DIR}/mirror"

log "=== OpenShift disconnected bundle preparation ==="
log "Config              : ${CONFIG_FILE}"
log "OpenShift           : ${OPENSHIFT_VERSION}"
log "Driver Toolkit      : ${DRIVER_TOOLKIT_IMAGE}"
log "Application registry: ${IMAGE_REGISTRY:-<not set>}"

download \
  "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
  "${STAGE_DIR}/manifests/cert-manager.yaml"
download \
  "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_PROVISIONER_VERSION}/deploy/local-path-storage.yaml" \
  "${STAGE_DIR}/manifests/local-path-storage.yaml"

log "Pulling pinned Helm charts"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null 2>&1 || true
helm repo update open-telemetry kuberay >/dev/null
helm pull open-telemetry/opentelemetry-operator --version "${OTEL_CHART_VERSION}" --destination "${STAGE_DIR}/charts"
helm pull kuberay/kuberay-operator --version "${KUBERAY_CHART_VERSION}" --destination "${STAGE_DIR}/charts"
echo "${OTEL_CHART_VERSION}" > "${STAGE_DIR}/charts/opentelemetry-operator.version"

# Keep the host-compatible plugin in the transfer bundle so import does not
# require a separate oc-mirror installation.
cp -L "$(command -v oc-mirror)" "${STAGE_DIR}/bin/oc-mirror"
chmod +x "${STAGE_DIR}/bin/oc-mirror"

APPLICATION_RAW="${STAGE_DIR}/.application-images.raw"
: > "${APPLICATION_RAW}"
for path in \
  '.images.operator.image' \
  '.images.ray.headImage' \
  '.images.ray.workerImage' \
  '.images.weaviate.image' \
  '.images.saia.apiImage' \
  '.images.saia.apiV2Image' \
  '.images.saia.dataLoaderImage' \
  '.images.slim.apiImage' \
  '.images.splunk.image' \
  '.images.splunk.operatorImage' \
  '.images.fluentBit.image' \
  '.images.otelCollector.image' \
  '.images.nginx.image'; do
  image=$(yq eval "${path} // \"\"" "${CONFIG_FILE}")
  [[ -n "${image}" && "${image}" != "null" ]] \
    && resolved_application_image "${image}" "${IMAGE_REGISTRY}" >> "${APPLICATION_RAW}"
done
sort -u "${APPLICATION_RAW}" > "${STAGE_DIR}/customer-provided-images.txt"
rm -f "${APPLICATION_RAW}"

INFRA_RAW="${STAGE_DIR}/.infrastructure-images.raw"
: > "${INFRA_RAW}"
append_manifest_images "${STAGE_DIR}/manifests/cert-manager.yaml" "${INFRA_RAW}"
append_manifest_images "${STAGE_DIR}/manifests/local-path-storage.yaml" "${INFRA_RAW}"
append_chart_images kuberay-operator "${STAGE_DIR}/charts/kuberay-operator-${KUBERAY_CHART_VERSION}.tgz" "${INFRA_RAW}"
append_chart_images opentelemetry-operator "${STAGE_DIR}/charts/opentelemetry-operator-${OTEL_CHART_VERSION}.tgz" "${INFRA_RAW}"
printf '%s\n' \
  'registry.access.redhat.com/ubi8/ubi-minimal:latest' \
  "registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9:v${OPENSHIFT_VERSION}" \
  >> "${INFRA_RAW}"
# A pre-existing disconnected OpenShift release mirror already owns Driver
# Toolkit content when the imagestream points into the configured registry.
if [[ -z "${IMAGE_REGISTRY}" || "${DRIVER_TOOLKIT_IMAGE}" != "${IMAGE_REGISTRY%/}/"* ]]; then
  printf '%s\n' "${DRIVER_TOOLKIT_IMAGE}" >> "${INFRA_RAW}"
else
  log "Driver Toolkit already resolves inside images.registry; reusing the cluster's base release mirror"
fi
while IFS= read -r image; do
  [[ -n "${image}" ]] && qualified_additional_image "${image}"
done < <(sort -u "${INFRA_RAW}" | grep -v '^$') \
  | sort -u > "${STAGE_DIR}/bundled-infrastructure-images.txt"
rm -f "${INFRA_RAW}"

ISC="${STAGE_DIR}/imageset-config.yaml"
cat > "${ISC}" <<YAML
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
archiveSize: 4
mirror:
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v${OPENSHIFT_VERSION}
      packages:
        - name: nfd
          channels:
            - name: ${NFD_CHANNEL}
    - catalog: registry.redhat.io/redhat/certified-operator-index:v${OPENSHIFT_VERSION}
      packages:
        - name: gpu-operator-certified
          channels:
            - name: ${GPU_CHANNEL}
  additionalImages:
YAML
while IFS= read -r image; do
  printf '    - name: %s\n' "${image}" >> "${ISC}"
done < "${STAGE_DIR}/bundled-infrastructure-images.txt"

log "Capturing Operator Lifecycle Manager packages and infrastructure images"
# Some certified Operator sources publish the image manifest without the
# detached signature object. Red Hat documents --remove-signatures for bypassing
# source-side invalid, expired, or unavailable signatures during mirroring.
MIRROR_CMD=("${STAGE_DIR}/bin/oc-mirror" --config "${ISC}" "file://${STAGE_DIR}/mirror" --v2 --remove-signatures)
if [[ -n "${REGISTRY_AUTH_FILE:-}" ]]; then
  [[ -f "${REGISTRY_AUTH_FILE}" ]] || err "REGISTRY_AUTH_FILE does not exist: ${REGISTRY_AUTH_FILE}"
  MIRROR_CMD+=(--authfile "${REGISTRY_AUTH_FILE}")
fi
# oc-mirror 4.21 v2 treats REGISTRY_AUTH_FILE as its own structured
# configuration variable and panics when its normal path value is exported.
# The explicit flag is the supported authentication input for this invocation.
env -u REGISTRY_AUTH_FILE "${MIRROR_CMD[@]}"

cat > "${STAGE_DIR}/airgap-env.sh" <<'ENVEOF'
: "${AIRGAP_BUNDLE_DIR:?AIRGAP_BUNDLE_DIR must point to the extracted bundle}"
export CERT_MANAGER_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/local-path-storage.yaml"
export OTEL_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator-0.121.0.tgz"
export KUBERAY_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/kuberay-operator-1.2.2.tgz"
export AIRGAP_MODE="true"
ENVEOF

cat > "${STAGE_DIR}/bundle-versions.txt" <<VEOF
cert_manager_version=${CERT_MANAGER_VERSION}
local_path_provisioner_version=${LOCAL_PATH_PROVISIONER_VERSION}
kuberay_chart_version=${KUBERAY_CHART_VERSION}
otel_chart_version=${OTEL_CHART_VERSION}
openshift_version=${OPENSHIFT_VERSION}
bundle_os=$(uname -s)
bundle_arch=$(uname -m)
bundle_timestamp=${BUNDLE_TIMESTAMP}
VEOF

cat > "${STAGE_DIR}/README.txt" <<'README'
This bundle contains installer-owned OpenShift infrastructure content only.
The disconnected installer imports its oc-mirror archives into images.registry
and applies generated image mirror policies and Operator catalog sources.

The customer must separately provide every image in customer-provided-images.txt.
Model weights are not bundled. With storage.modelStaging.enabled=true, the
installer checks completion markers in the configured object store and downloads
and uploads only missing or changed models from the installer machine.

Registry credentials and Hugging Face credentials are intentionally external
to the bundle. The installer reads registry credentials from the target
cluster/config when it runs.
README

log "Computing checksums"
(
  cd "${STAGE_DIR}"
  # oc-mirror updates mirror/working-dir during disk-to-registry import. Verify
  # the transfer archives and all installer assets, but do not checksum that
  # explicitly mutable retry workspace.
  find . -type f ! -name checksums.sha256 ! -path './mirror/working-dir/*' \
    | sed 's#^./##' | sort | while IFS= read -r file; do
    printf '%s  %s\n' "$(sha256 "${file}")" "${file}"
  done
) > "${STAGE_DIR}/checksums.sha256"

BUNDLE_TARBALL="${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz"
tar -czf "${BUNDLE_TARBALL}" -C "${OUTPUT_DIR}" "${BUNDLE_NAME}"
BUNDLE_SIZE=$(du -sh "${BUNDLE_TARBALL}" | awk '{print $1}')
BUNDLE_SHA=$(sha256 "${BUNDLE_TARBALL}")

log "Bundle ready: ${BUNDLE_TARBALL} (${BUNDLE_SIZE})"
log "SHA256: ${BUNDLE_SHA}"
log "Customer application image inventory: ${STAGE_DIR}/customer-provided-images.txt"
log "Run the normal install command with cluster.airgap=true and this bundle path."
