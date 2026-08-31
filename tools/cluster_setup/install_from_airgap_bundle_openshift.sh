#!/usr/bin/env bash
# Reuse a prepared OpenShift bundle directory or extract a transferred archive,
# import installer-owned image content into the configured internal registry,
# apply generated mirror and catalog resources, then invoke the installer.

set -euo pipefail

# Delete only the temporary auth file created by the unified installer. User-
# supplied REGISTRY_AUTH_FILE/AIRGAP_REGISTRY_AUTH_FILE values are never removed.
cleanup_auto_registry_auth_file() {
  local path="${OPENSHIFT_AUTO_REGISTRY_AUTH_FILE:-}"
  if [[ -n "${path}" && "${path}" == "${TMPDIR:-/tmp}"/openshift-registry-auth.* ]]; then
    rm -f -- "${path}" 2>/dev/null || true
  fi
}
trap cleanup_auto_registry_auth_file EXIT

BUNDLE_SOURCE=""
CONFIG_FILE=""
EXTRACT_DIR="${EXTRACT_DIR:-/opt/airgap}"
INSTALLER_SCRIPT=""
SUBCOMMAND="${SUBCOMMAND:-install}"

# Print the disconnected-side import and installation contract.
usage() {
  cat <<'HELP'
install_from_airgap_bundle_openshift.sh — install from an OpenShift disconnected
content bundle. Normally this wrapper is called automatically when
cluster.airgap=true.

USAGE
  ./install_from_airgap_bundle_openshift.sh --bundle BUNDLE --config CONFIG [OPTIONS]

REQUIRED
  --bundle PATH       Prepared bundle directory or transfer archive produced by
                      prepare_airgap_bundle_openshift.sh
  --config FILE       Target openshift-cluster-config.yaml

OPTIONS
  --extract-dir DIR   Extraction directory. Default: /opt/airgap
  --installer FILE    openshift_with_stack.sh path
  --subcommand CMD    install or delete. Default: install
  -h, --help          Show this help

INSTALL-TIME REQUIREMENTS
  - a Linux installer machine because Red Hat oc-mirror is Linux-only
  - oc logged in as cluster-admin, helm, tar, and yq v4
  - aws — AWS CLI only when storage.objectStore.type=aws
  - access to the internal registry named by images.registry
  - imagePullSecrets.custom credentials for the internal registry; the normal
    openshift_with_stack.sh entry point combines them with the cluster pull
    secret (direct wrapper use may set AIRGAP_REGISTRY_AUTH_FILE or
    REGISTRY_AUTH_FILE)
  - customer-provided application images from customer-provided-images.txt
    already present in that registry
  - object-store access; Hugging Face access and HF_TOKEN only when
    storage.modelStaging.enabled=true and a required model is missing

The bundle supplies its matching oc-mirror binary and automatically imports
installer-owned content before installing platform components.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_SOURCE="$2"; shift 2 ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --extract-dir) EXTRACT_DIR="$2"; shift 2 ;;
    --installer) INSTALLER_SCRIPT="$2"; shift 2 ;;
    --subcommand) SUBCOMMAND="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN  $*" >&2; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR $*" >&2; exit 1; }

# Fail early when a required disconnected-side command is unavailable.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required tool not found: $1"
}

# Resolve a file path without depending on GNU realpath.
absolute_path() {
  local path="$1" dir base
  dir=$(cd "$(dirname "${path}")" && pwd)
  base=$(basename "${path}")
  printf '%s/%s\n' "${dir}" "${base}"
}

# Verify every immutable file recorded by the connected bundle builder.
verify_checksums() {
  log "Verifying bundle checksums"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${BUNDLE_DIR}" && \
      grep -vE '  (\./)?mirror/working-dir/' checksums.sha256 \
        | sha256sum --check - --quiet) \
      || err "Checksum verification failed; bundle is incomplete or modified"
  elif command -v shasum >/dev/null 2>&1; then
    (cd "${BUNDLE_DIR}" && \
      grep -vE '  (\./)?mirror/working-dir/' checksums.sha256 \
        | shasum -a 256 --check - --quiet) \
      || err "Checksum verification failed; bundle is incomplete or modified"
  else
    warn "sha256sum/shasum is unavailable; checksum verification skipped"
    return 0
  fi
  log "Checksums verified"
}

# Wait until a mirrored Operator catalog is available to PackageManifest.
wait_for_catalog_source() {
  local name="$1" elapsed=0 timeout_seconds=1200 state
  while (( elapsed < timeout_seconds )); do
    state=$(oc get catalogsource "${name}" -n openshift-marketplace \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    [[ "${state}" == "READY" ]] && { log "CatalogSource ${name} is READY"; return 0; }
    sleep 10
    elapsed=$((elapsed + 10))
  done
  err "CatalogSource openshift-marketplace/${name} did not become READY"
}

# Copy the import authentication into the Marketplace namespace so the catalog
# pods can pull private catalog images. CatalogSource references are
# namespace-scoped; oc-mirror's --authfile authenticates only the import
# process and does not configure catalog pods.
create_catalog_pull_secret() {
  local auth_file="${AIRGAP_REGISTRY_AUTH_FILE:-${REGISTRY_AUTH_FILE:-}}"
  CATALOG_PULL_SECRET=""
  [[ -n "${auth_file}" ]] || return 0
  [[ -f "${auth_file}" ]] || err "Registry auth file does not exist: ${auth_file}"

  CATALOG_PULL_SECRET="splunk-ai-airgap-registry-pull"
  oc -n openshift-marketplace create secret generic "${CATALOG_PULL_SECRET}" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="${auth_file}" \
    --dry-run=client -o yaml | oc apply -f -
  log "Configured Marketplace catalog registry authentication"
}

# Apply generated ImageDigestMirrorSet/ImageTagMirrorSet resources and preserve
# the generated CatalogSource names. The OpenShift Marketplace Operator owns
# the default redhat-operators and certified-operators CatalogSources and
# reconciles their public image references, so disconnected catalogs must use
# distinct names.
apply_generated_mirror_resources() {
  local resource_dir file kind image source_name found=0
  MIRRORED_NFD_CATALOG_SOURCE=""
  MIRRORED_GPU_CATALOG_SOURCE=""
  while IFS= read -r resource_dir; do
    [[ -n "${resource_dir}" ]] || continue
    found=1
    log "Applying generated OpenShift mirror resources from ${resource_dir}"
    while IFS= read -r file; do
      kind=$(yq eval '.kind // ""' "${file}" 2>/dev/null || true)
      if [[ "${kind}" != "CatalogSource" ]]; then
        oc apply -f "${file}"
        continue
      fi

      image=$(yq eval '.spec.image // ""' "${file}")
      source_name=$(yq eval '.metadata.name // ""' "${file}")
      case "${image} $(basename "${file}")" in
        *redhat-operator-index*) MIRRORED_NFD_CATALOG_SOURCE="${source_name}" ;;
        *certified-operator-index*) MIRRORED_GPU_CATALOG_SOURCE="${source_name}" ;;
      esac

      log "Applying mirrored CatalogSource openshift-marketplace/${source_name}"
      if [[ -n "${CATALOG_PULL_SECRET:-}" ]]; then
        yq eval ".spec.secrets = [\"${CATALOG_PULL_SECRET}\"]" "${file}" | oc apply -f -
      else
        oc apply -f "${file}"
      fi
    done < <(find "${resource_dir}" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  done < <(find "${BUNDLE_DIR}/mirror" -type d -path '*/working-dir/cluster-resources' | sort -u)

  (( found == 1 )) || err "oc-mirror did not generate a working-dir/cluster-resources directory"
  [[ -n "${MIRRORED_NFD_CATALOG_SOURCE}" ]] \
    || err "oc-mirror did not generate the Red Hat Operator CatalogSource"
  [[ -n "${MIRRORED_GPU_CATALOG_SOURCE}" ]] \
    || err "oc-mirror did not generate the Certified Operator CatalogSource"

  # Image mirror policy changes can roll the MachineConfigPools. Do not start
  # Operator Lifecycle Manager subscriptions while nodes are still converging.
  log "Waiting for OpenShift MachineConfigPools after mirror-policy changes"
  oc wait machineconfigpool --all --for=condition=Updated=True --timeout=45m \
    || err "MachineConfigPools did not finish applying image mirror policies"

  wait_for_catalog_source "${MIRRORED_NFD_CATALOG_SOURCE}"
  wait_for_catalog_source "${MIRRORED_GPU_CATALOG_SOURCE}"
}

# Import oc-mirror archives into images.registry and configure cluster redirects.
import_bundled_images() {
  local target_registry insecure auth_file mirror_bin attempt=1 max_attempts=3
  target_registry=$(yq eval '.images.registry // ""' "${CONFIG_FILE}")
  target_registry="${target_registry#http://}"
  target_registry="${target_registry#https://}"
  target_registry="${target_registry%/}"
  [[ -n "${target_registry}" ]] || err "images.registry must name the disconnected internal registry"

  insecure=$(yq eval '.images.registryInsecure // "false"' "${CONFIG_FILE}")
  mirror_bin="${BUNDLE_DIR}/bin/oc-mirror"
  [[ -x "${mirror_bin}" ]] || err "Bundled oc-mirror executable is missing"
  # oc-mirror 4.21 requires selecting v2 even for its version command; plain
  # `--version` exits 255 and would incorrectly be reported as an architecture
  # mismatch.
  "${mirror_bin}" --v2 version >/dev/null 2>&1 \
    || err "The bundled oc-mirror executable cannot run on this installer OS/architecture. Prepare the bundle on a matching machine."

  MIRROR_CMD=(
    "${mirror_bin}"
    --config "${BUNDLE_DIR}/imageset-config.yaml"
    --from "file://${BUNDLE_DIR}/mirror"
    "docker://${target_registry}"
    --v2
    --remove-signatures
    --image-timeout 30m
  )
  auth_file="${AIRGAP_REGISTRY_AUTH_FILE:-${REGISTRY_AUTH_FILE:-}}"
  if [[ -n "${auth_file}" ]]; then
    [[ -f "${auth_file}" ]] || err "Registry auth file does not exist: ${auth_file}"
    MIRROR_CMD+=(--authfile "${auth_file}")
  fi
  [[ "${insecure}" == "true" ]] && MIRROR_CMD+=(--dest-tls-verify=false)

  while true; do
    log "Importing bundled infrastructure and Operator content into ${target_registry} (attempt ${attempt}/${max_attempts})"
    # oc-mirror 4.21 v2 misinterprets an exported REGISTRY_AUTH_FILE path as
    # structured configuration. Authentication is already supplied by --authfile.
    if env -u REGISTRY_AUTH_FILE "${MIRROR_CMD[@]}"; then
      break
    fi
    if (( attempt >= max_attempts )); then
      err "oc-mirror import failed after ${max_attempts} attempts"
    fi
    warn "oc-mirror import attempt ${attempt} failed; retrying in 15 seconds"
    sleep 15
    attempt=$((attempt + 1))
  done
  create_catalog_pull_secret
  apply_generated_mirror_resources
}

[[ -n "${BUNDLE_SOURCE}" ]] || err "--bundle is required"
[[ -f "${BUNDLE_SOURCE}" || -d "${BUNDLE_SOURCE}" ]] \
  || err "Bundle file or directory not found: ${BUNDLE_SOURCE}"
[[ -n "${CONFIG_FILE}" ]] || err "--config is required"
[[ -f "${CONFIG_FILE}" ]] || err "Config not found: ${CONFIG_FILE}"
[[ "${SUBCOMMAND}" == "install" || "${SUBCOMMAND}" == "delete" ]] \
  || err "--subcommand must be install or delete"

[[ "$(uname -s)" == "Linux" ]] \
  || err "Disconnected image import requires Linux because the bundled Red Hat oc-mirror executable is Linux-only."
for tool in helm oc tar yq; do require_cmd "${tool}"; done
oc auth can-i '*' '*' --all-namespaces 2>/dev/null | grep -qx yes \
  || err "The current oc user does not have cluster-admin access"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${INSTALLER_SCRIPT}" ]] || INSTALLER_SCRIPT="${SCRIPT_DIR}/openshift_with_stack.sh"
[[ -f "${INSTALLER_SCRIPT}" ]] || err "Installer not found: ${INSTALLER_SCRIPT}"
CONFIG_FILE=$(absolute_path "${CONFIG_FILE}")
BUNDLE_SOURCE=$(absolute_path "${BUNDLE_SOURCE}")

if [[ -d "${BUNDLE_SOURCE}" ]]; then
  # The unified same-host flow consumes the completed staging directory
  # directly. This avoids creating a transfer tarball and then extracting a
  # second copy of the same multi-gigabyte mirror content.
  BUNDLE_DIR="${BUNDLE_SOURCE}"
  log "Reusing prepared bundle directory directly: ${BUNDLE_DIR}"
else
  log "Extracting transferred bundle archive: ${BUNDLE_SOURCE}"
  mkdir -p "${EXTRACT_DIR}"
  # The matching entry is at the start of bundles produced by the companion
  # builder. grep -m1 intentionally closes the pipe early, so mask the resulting
  # SIGPIPE from tar under `set -o pipefail`; the explicit non-empty check below
  # still rejects malformed archives.
  BUNDLE_TOP=$(tar -tzf "${BUNDLE_SOURCE}" \
    | sed 's#/.*##' \
    | grep -m1 '^airgap-bundle-openshift-' \
    || true)
  [[ -n "${BUNDLE_TOP}" ]] || err "Bundle has no airgap-bundle-openshift-* top-level directory"
  BUNDLE_DIR="${EXTRACT_DIR}/${BUNDLE_TOP}"
  if [[ -d "${BUNDLE_DIR}" ]]; then
    log "Using existing extracted bundle: ${BUNDLE_DIR}"
  else
    tar -xzf "${BUNDLE_SOURCE}" -C "${EXTRACT_DIR}" \
      || err "Failed to extract bundle: ${BUNDLE_SOURCE}"
  fi
fi
[[ -d "${BUNDLE_DIR}" ]] || err "Extracted bundle directory is missing: ${BUNDLE_DIR}"
verify_checksums

NFD_CATALOG_SOURCE=$(yq eval '.operators.nfd.catalogSource // "redhat-operators"' "${CONFIG_FILE}")
GPU_CATALOG_SOURCE=$(yq eval '.operators.gpu.catalogSource // "certified-operators"' "${CONFIG_FILE}")

if [[ "${SUBCOMMAND}" == "install" ]]; then
  import_bundled_images
  export AIRGAP_NFD_CATALOG_SOURCE="${MIRRORED_NFD_CATALOG_SOURCE}"
  export AIRGAP_GPU_CATALOG_SOURCE="${MIRRORED_GPU_CATALOG_SOURCE}"
fi

export AIRGAP_BUNDLE_DIR="${BUNDLE_DIR}"
export CERT_MANAGER_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/local-path-storage.yaml"
export OTEL_CHART_PATH="${BUNDLE_DIR}/charts/opentelemetry-operator-$(grep '^otel_chart_version=' "${BUNDLE_DIR}/bundle-versions.txt" | cut -d= -f2).tgz"
export KUBERAY_CHART_PATH="${BUNDLE_DIR}/charts/kuberay-operator-$(grep '^kuberay_chart_version=' "${BUNDLE_DIR}/bundle-versions.txt" | cut -d= -f2).tgz"
export AIRGAP_MODE="true"
export AIRGAP_STAGED="true"

log "Launching openshift_with_stack.sh ${SUBCOMMAND}"
cleanup_auto_registry_auth_file
if [[ -n "${OPENSHIFT_AUTO_REGISTRY_AUTH_FILE:-}" &&
      "${REGISTRY_AUTH_FILE:-}" == "${OPENSHIFT_AUTO_REGISTRY_AUTH_FILE}" ]]; then
  unset REGISTRY_AUTH_FILE
fi
unset OPENSHIFT_AUTO_REGISTRY_AUTH_FILE
exec env CONFIG_FILE="${CONFIG_FILE}" "${INSTALLER_SCRIPT}" "${SUBCOMMAND}"
