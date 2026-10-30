#!/usr/bin/env bash
# install_from_airgap_bundle.sh
# Run on the air-gapped install machine (a real install needs kubectl/helm/ssh
# pre-installed, but NO outbound internet). Extracts the bundle produced by
# prepare_airgap_bundle.sh, sets environment-variable overrides, then invokes
# k0s_cluster_with_stack.sh.
#
# Usage:
#   ./install_from_airgap_bundle.sh --bundle airgap-bundle-<date>.tar.gz \
#       --config my-cluster-config.yaml [--extract-dir /opt/airgap] \
#       [--validate-only]
#
# The installer (k0s_cluster_with_stack.sh) must be in the same directory as
# this script, or pass --installer /path/to/k0s_cluster_with_stack.sh.

set -euo pipefail

BUNDLE_TARBALL=""
CONFIG_FILE="${CONFIG_FILE:-}"
EXTRACT_DIR="${EXTRACT_DIR:-/opt/airgap}"
INSTALLER_SCRIPT=""
SUBCOMMAND="${SUBCOMMAND:-install}"
VALIDATE_ONLY=false
EXPECTED_BUNDLE_SHA256="${EXPECTED_BUNDLE_SHA256:-}"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)      BUNDLE_TARBALL="$2"; shift 2 ;;
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --extract-dir) EXTRACT_DIR="$2"; shift 2 ;;
    --installer)   INSTALLER_SCRIPT="$2"; shift 2 ;;
    --subcommand)  SUBCOMMAND="$2"; shift 2 ;;
    --expected-bundle-sha256) EXPECTED_BUNDLE_SHA256="$2"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=true; shift ;;
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
                        environment or its default location. Required for a
                        CPU-only bundle.

  --extract-dir DIR     Directory where the bundle is extracted.
                        Default: /opt/airgap
                        Env: EXTRACT_DIR

  --installer SCRIPT    Path to k0s_cluster_with_stack.sh.
                        Default: same directory as this script. A CPU-only
                        bundle runs its included version-matched installer.

  --subcommand CMD      Installer subcommand to run: install | join-workers
                        Default: install
                        Env: SUBCOMMAND

  --expected-bundle-sha256 SHA256
                        SHA-256 recorded on the connected build host. Required
                        for CPU-only bundles and validation-only mode.
                        Env: EXPECTED_BUNDLE_SHA256

  --validate-only       Validate a CPU-only bundle and its selected config,
                        then exit before privileged host or cluster changes.
                        The bundle is still extracted into --extract-dir.

  -h, --help            Show this help text.

WHAT THIS SCRIPT DOES
  1. Extracts the bundle into --extract-dir.
  2. Verifies the external tarball SHA-256 and the complete internal checksum
     manifest before using any bundled executable.
  3. With --validate-only, stops after CPU-only artifact/config validation.
  4. Installs the bundled k0s binary to /usr/local/bin/k0s (if not already present).
  5. Installs the bundled yq binary to /usr/local/bin/yq (if not already present).
  6. Registers a local Helm chart repository pointing at the bundled .tgz files.
  7. Exports the following environment variables so k0s_cluster_with_stack.sh
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

  8. Invokes k0s_cluster_with_stack.sh <subcommand>.

  CPU-only bundles include the installer and matching operator manifests. The
  wrapper verifies their contents and the OCI image archive references before
  installation, then runs from the bundled source directory.

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
  A real install requires kubectl, helm, tar, python3 and ssh. Validation-only
  requires tar and python3; it does not invoke kubectl, helm, ssh or network
  clients.
  The installer will use the bundled k0s and yq binaries.

EXAMPLES
  # Minimal — config in current directory
  ./install_from_airgap_bundle.sh --bundle airgap-bundle-20260612-103000.tar.gz

  # Explicit config and extract path
  ./install_from_airgap_bundle.sh \
    --bundle /mnt/transfer/airgap-bundle-20260612-103000.tar.gz \
    --expected-bundle-sha256 <sha256-recorded-before-transfer> \
    --config /etc/splunk-ai/my-cluster-config.yaml \
    --extract-dir /opt/airgap

  # Validate a CPU-only bundle without installing binaries or touching a cluster
  ./install_from_airgap_bundle.sh \
    --bundle /mnt/transfer/airgap-bundle-20260612-103000.tar.gz \
    --expected-bundle-sha256 <sha256-recorded-before-transfer> \
    --config /etc/splunk-ai/my-cluster-config.yaml \
    --extract-dir /tmp/airgap-validation \
    --validate-only

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
if [[ -n "${CONFIG_FILE}" ]]; then
  [[ -f "${CONFIG_FILE}" ]] || err "Config file not found: ${CONFIG_FILE}"
fi
require_cmd tar
require_cmd python3
if [[ "${VALIDATE_ONLY}" == "true" && -z "${EXPECTED_BUNDLE_SHA256}" ]]; then
  err "--validate-only requires --expected-bundle-sha256"
fi
if [[ -n "${EXPECTED_BUNDLE_SHA256}" ]]; then
  [[ "${EXPECTED_BUNDLE_SHA256}" =~ ^[0-9a-f]{64}$ ]] ||
    err "Expected bundle SHA-256 must be 64 lowercase hexadecimal characters"
  ACTUAL_BUNDLE_SHA256="$(python3 - "${BUNDLE_TARBALL}" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"
  [[ "${ACTUAL_BUNDLE_SHA256}" == "${EXPECTED_BUNDLE_SHA256}" ]] ||
    err "Bundle tarball SHA-256 does not match the externally recorded value"
  log "External bundle SHA-256 verified"
fi

if [[ "${VALIDATE_ONLY}" != "true" ]]; then
  require_cmd helm
  require_cmd kubectl
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "=== Splunk AI Platform — Air-Gap Installation ==="
log "Bundle          : ${BUNDLE_TARBALL}"
log "Extract dir     : ${EXTRACT_DIR}"
log "Installer       : ${INSTALLER_SCRIPT}"
log "Subcommand      : ${SUBCOMMAND}"
[[ -n "${CONFIG_FILE}" ]] && log "Config          : ${CONFIG_FILE}"
log ""

# ── Validate and extract bundle ───────────────────────────────────────────────
# Inspect with Python's tar parser before invoking tar extraction. This avoids
# platform-specific parsing of `tar -tv` output and rejects paths or member
# types that could escape or redirect extraction.
if ! BUNDLE_METADATA="$(python3 - "${BUNDLE_TARBALL}" <<'PY'
import pathlib
import sys
import tarfile

archive_path = sys.argv[1]
roots = set()
seen = set()
members_by_name = {}
try:
    with tarfile.open(archive_path, mode="r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError("bundle archive is empty")
        for member in members:
            raw_name = member.name
            if any(ord(character) < 32 or ord(character) == 127 for character in raw_name):
                raise ValueError(f"bundle archive contains a control character in member path: {raw_name!r}")
            path = pathlib.PurePosixPath(raw_name)
            if path.is_absolute() or not raw_name or ".." in path.parts:
                raise ValueError(f"bundle archive contains unsafe member path: {raw_name!r}")
            parts = tuple(part for part in path.parts if part not in ("", "."))
            if not parts:
                raise ValueError(f"bundle archive contains unsafe member path: {raw_name!r}")
            normalized = "/".join(parts)
            if normalized in seen:
                raise ValueError(f"bundle archive contains duplicate member: {normalized!r}")
            seen.add(normalized)
            members_by_name[normalized] = member
            root = parts[0]
            if not root.startswith("airgap-bundle-") or root == "airgap-bundle-":
                raise ValueError("bundle archive must contain exactly one airgap-bundle-* root")
            roots.add(root)
            if not (member.isfile() or member.isdir()):
                raise ValueError(
                    f"bundle archive contains unsupported member type for {raw_name!r}; "
                    "only regular files and directories are allowed"
                )
        if len(roots) != 1:
            raise ValueError("bundle archive must contain exactly one airgap-bundle-* root")
        root = next(iter(roots))
        profile = ""
        profile_member = members_by_name.get(f"{root}/bundle-profile.txt")
        if profile_member is not None:
            if not profile_member.isfile() or profile_member.size > 64:
                raise ValueError("bundle-profile.txt is not a small regular file")
            stream = archive.extractfile(profile_member)
            if stream is None:
                raise ValueError("bundle-profile.txt could not be read")
            profile = stream.read().decode("utf-8").strip()
            if profile != "cpuOnly":
                raise ValueError("unknown bundle profile")
except (OSError, tarfile.TarError, ValueError) as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    raise SystemExit(1)
print(f"{root}\t{profile}")
PY
)"; then
  err "Bundle archive member validation failed"
fi
IFS=$'\t' read -r BUNDLE_NAME ARCHIVE_PROFILE <<< "${BUNDLE_METADATA}"

# Determine whether the external config selects cpuOnly without executing any
# file from the bundle. The bundled yq remains authoritative after the bundle's
# externally recorded digest has been verified.
CONFIG_PROFILE=""
if [[ -n "${CONFIG_FILE}" ]]; then
  CONFIG_PROFILE="$(python3 - "${CONFIG_FILE}" <<'PY'
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
section_indent = None
for raw in lines:
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    if "\t" in raw:
        print("unknown")
        raise SystemExit
    indent = len(raw) - len(raw.lstrip(" "))
    content = raw.strip()
    if section_indent is None:
        if indent == 0 and re.match(r"aiPlatform\s*:", content):
            if re.fullmatch(r"aiPlatform\s*:\s*(?:#.*)?", content):
                section_indent = indent
            else:
                print("unknown")
                raise SystemExit
        continue
    if indent <= section_indent:
        break
    match = re.fullmatch(r"profile\s*:\s*([^#]+?)\s*(?:#.*)?", content)
    if match:
        value = match.group(1).strip().strip("'\"")
        print(value if value in {"cpuOnly", "full"} else "unknown")
        raise SystemExit
    if re.match(r"profile\s*:", content):
        print("unknown")
        raise SystemExit
print("")
PY
)"
fi

CPU_ONLY_BUNDLE=false
[[ "${ARCHIVE_PROFILE}" == "cpuOnly" ]] && CPU_ONLY_BUNDLE=true
if [[ "${CPU_ONLY_BUNDLE}" == "true" || "${CONFIG_PROFILE}" == "cpuOnly" || "${CONFIG_PROFILE}" == "unknown" ]]; then
  [[ -n "${EXPECTED_BUNDLE_SHA256}" ]] ||
    err "CPU-only bundle or config requires --expected-bundle-sha256 before bundled tools can run"
fi

log "Extracting bundle..."
mkdir -p "${EXTRACT_DIR}"
EXTRACT_DIR="$(cd "${EXTRACT_DIR}" && pwd)"
BUNDLE_DIR="${EXTRACT_DIR}/${BUNDLE_NAME}"
[[ ! -e "${BUNDLE_DIR}" ]] ||
  err "Bundle extraction destination already exists: ${BUNDLE_DIR}; use an empty --extract-dir"
tar -xzf "${BUNDLE_TARBALL}" -C "${EXTRACT_DIR}"

[[ -d "${BUNDLE_DIR}" ]] || err "Could not find extracted bundle directory in ${EXTRACT_DIR}"
log "Bundle extracted to: ${BUNDLE_DIR}"

# ── Verify checksums ──────────────────────────────────────────────────────────
# Do not delegate untrusted manifest paths to sha256sum. Require the manifest to
# cover every regular bundle file exactly once, then hash those safe paths.
log "Verifying complete checksum manifest..."
python3 - "${BUNDLE_DIR}" <<'PY' || exit 1
import hashlib
import pathlib
import re
import sys

bundle = pathlib.Path(sys.argv[1]).resolve()
manifest = bundle / "checksums.sha256"
line_re = re.compile(r"^([0-9a-f]{64})[ \t]+[*]?(.+)$")

def fail(message):
    print(f"ERROR: Checksum verification failed — {message}", file=sys.stderr)
    raise SystemExit(1)

if not manifest.is_file() or manifest.is_symlink():
    fail("checksums.sha256 is missing or unsafe")

listed = {}
for number, raw in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
    if not raw:
        continue
    match = line_re.fullmatch(raw)
    if not match:
        fail(f"invalid manifest line {number}")
    expected, relative = match.groups()
    path = pathlib.PurePosixPath(relative)
    if (
        path.is_absolute()
        or not relative
        or ".." in path.parts
        or any(ord(character) < 32 or ord(character) == 127 for character in relative)
    ):
        fail(f"unsafe manifest path on line {number}")
    normalized = pathlib.PurePosixPath(*[part for part in path.parts if part not in ("", ".")]).as_posix()
    if normalized in listed:
        fail(f"duplicate manifest path: {normalized}")
    candidate = (bundle / normalized).resolve()
    if bundle not in candidate.parents or not candidate.is_file() or candidate.is_symlink():
        fail(f"listed artifact is missing or unsafe: {normalized}")
    listed[normalized] = expected

actual_files = {
    path.relative_to(bundle).as_posix()
    for path in bundle.rglob("*")
    if path.is_file() and not path.is_symlink() and path != manifest
}
if set(listed) != actual_files:
    missing = sorted(actual_files - set(listed))
    extra = sorted(set(listed) - actual_files)
    fail(f"manifest coverage mismatch (unlisted={missing}, nonexistent={extra})")

for relative, expected in listed.items():
    digest = hashlib.sha256()
    with (bundle / relative).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        fail(f"checksum mismatch for {relative}")
PY
log "Checksums verified OK"

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

# Check the selected workload closure before modifying the installer host or
# reaching any cluster node. A bundle prepared for another config must fail
# here, rather than leaving a partially installed private cluster.
if [[ -f "${BUNDLE_DIR}/bundle-profile.txt" ]]; then
  [[ "$(cat "${BUNDLE_DIR}/bundle-profile.txt")" == "cpuOnly" ]] ||
    err "Unknown bundle profile"
  CPU_ONLY_BUNDLE=true
  [[ -n "${CONFIG_FILE}" ]] ||
    err "CPU-only bundle requires an explicit --config or CONFIG_FILE"
fi
if [[ -n "${CONFIG_FILE}" ]]; then
  BUNDLE_YQ="${BUNDLE_DIR}/binaries/yq"
  [[ -x "${BUNDLE_YQ}" ]] || err "Bundled yq is missing or not executable"
  if [[ "$("${BUNDLE_YQ}" eval -r '.aiPlatform.profile // ""' "${CONFIG_FILE}")" == "cpuOnly" ]]; then
    [[ "${CPU_ONLY_BUNDLE}" == "true" ]] ||
      err "CPU-only config requires a CPU-only bundle made with --config"
    [[ "$("${BUNDLE_YQ}" eval -r '.cluster.airgap // false' "${CONFIG_FILE}")" == "true" ]] || \
      err "cpuOnly offline bundle requires cluster.airgap: true"
    for required in k0s-images.tar k0s-images.list addon-images.tar addon-images.list workload-images.tar workload-images.list; do
      [[ -s "${BUNDLE_DIR}/images/${required}" ]] || err "Required CPU-only bundle artifact missing: images/${required}"
    done
    for expression in \
      '.images.operator.image' \
      '.images.splunk.image' \
      '.images.splunk.operatorImage' \
      '.images.slim.apiImage'; do
      expected="$("${BUNDLE_YQ}" eval -r "${expression} // \"\"" "${CONFIG_FILE}")"
      [[ -n "${expected}" && "${expected}" != "null" ]] || err "Missing ${expression} in CPU-only config"
      grep -Fxq -- "${expected}" "${BUNDLE_DIR}/images/workload-images.list" || \
        err "CPU-only bundle does not contain configured image ${expression}: ${expected}"
    done
    las_repository="$("${BUNDLE_YQ}" eval -r '.aiPlatform.features[] | select(.name == "agentruntime") | .las.image.repository' "${CONFIG_FILE}")"
    las_tag="$("${BUNDLE_YQ}" eval -r '.aiPlatform.features[] | select(.name == "agentruntime") | .las.image.tag' "${CONFIG_FILE}")"
    [[ -n "${las_repository}" && -n "${las_tag}" && "${las_repository}" != "null" && "${las_tag}" != "null" ]] || \
      err "Missing Agent Runtime image repository/tag in CPU-only config"
    grep -Fxq -- "${las_repository}:${las_tag}" "${BUNDLE_DIR}/images/workload-images.list" || \
      err "CPU-only bundle does not contain configured Agent Runtime image"
    log "CPU-only workload image closure verified against ${CONFIG_FILE}"
  elif [[ "${CPU_ONLY_BUNDLE}" == "true" ]]; then
    err "CPU-only bundle requires aiPlatform.profile: cpuOnly"
  fi
fi

if [[ "${CPU_ONLY_BUNDLE}" == "true" ]]; then
  [[ -n "${EXPECTED_BUNDLE_SHA256}" ]] ||
    err "CPU-only bundle requires --expected-bundle-sha256"
  require_cmd cmp
  for required in source-commit.txt binaries/k0s binaries/yq manifests/cert-manager.yaml \
                  manifests/local-path-storage.yaml packages/pyyaml.filename; do
    [[ -s "${BUNDLE_DIR}/${required}" ]] ||
      err "Required CPU-only bundle artifact missing: ${required}"
  done
  SOURCE_COMMIT="$(cat "${BUNDLE_DIR}/source-commit.txt")"
  [[ "${SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] ||
    err "Bundled source-commit.txt is not a 40-character Git commit"
  [[ "$(get_version source_commit)" == "${SOURCE_COMMIT}" ]] ||
    err "Bundled source commit does not match bundle-versions.txt"
  bundled_pyyaml="$(cat "${BUNDLE_DIR}/packages/pyyaml.filename")"
  [[ "${bundled_pyyaml}" == "$(basename "${bundled_pyyaml}")" &&
     -s "${BUNDLE_DIR}/packages/${bundled_pyyaml}" ]] ||
    err "Bundled PyYAML package is missing or has an invalid filename"
  BUNDLED_SETUP="${BUNDLE_DIR}/cluster_setup"
  for required in k0s_cluster_with_stack.sh install_from_airgap_bundle.sh \
                  artifacts.yaml splunk-operator-cluster.yaml las_deployment.py \
                  build_airgap_image_inventory.py validate_cpu_airgap_runtime.py; do
    [[ -s "${BUNDLED_SETUP}/${required}" ]] ||
      err "Version-matched installer artifact missing: cluster_setup/${required}"
  done
  cmp -s "${SCRIPT_DIR}/install_from_airgap_bundle.sh" \
         "${BUNDLED_SETUP}/install_from_airgap_bundle.sh" ||
    err "Bundle was built from a different installer revision; run its bundled installer"
  if [[ -n "${INSTALLER_SCRIPT}" ]]; then
    cmp -s "${INSTALLER_SCRIPT}" "${BUNDLED_SETUP}/k0s_cluster_with_stack.sh" ||
      err "--installer differs from the version-matched installer in the bundle"
  fi
  INSTALLER_SCRIPT="${BUNDLED_SETUP}/k0s_cluster_with_stack.sh"

  # The config's relative files are resolved from the bundled script directory
  # when we invoke it below. Absolute files are permitted only if identical.
  for entry in 'aiPlatform:artifacts.yaml' 'splunkOperator:splunk-operator-cluster.yaml'; do
    key="${entry%%:*}"
    file="${entry#*:}"
    configured="$("${BUNDLE_YQ}" eval -r ".files.${key} // \"\"" "${CONFIG_FILE}")"
    [[ -n "${configured}" ]] || err "Missing files.${key} in CPU-only config"
    if [[ "${configured}" == /* ]]; then
      candidate="${configured}"
    else
      candidate="${BUNDLED_SETUP}/${configured}"
    fi
    [[ -f "${candidate}" ]] && cmp -s "${candidate}" "${BUNDLED_SETUP}/${file}" ||
      err "files.${key} must match the bundled ${file}"
  done

  # The CPU profile has no Helm add-ons. Its two static manifests must account
  # for exactly the add-on references that were packed into the OCI archive.
  manifest_refs="$(grep -hoE 'image:[[:space:]]*["'"'"']?[^"'"'"' ]+' \
      "${BUNDLE_DIR}/manifests/cert-manager.yaml" \
      "${BUNDLE_DIR}/manifests/local-path-storage.yaml" \
      | sed -E 's/image:[[:space:]]*["'"'"']?//' \
      | grep -E '[:/]' | sort -u)" ||
    err "Could not enumerate CPU-only manifest images"
  [[ -n "${manifest_refs}" && "${manifest_refs}" == "$(cat "${BUNDLE_DIR}/images/addon-images.list")" ]] ||
    err "CPU-only add-on image list does not match its manifests"
  for archive in "${BUNDLE_DIR}"/images/*.tar; do
    case "$(basename "${archive}")" in
      k0s-images.tar|addon-images.tar|workload-images.tar) ;;
      *) err "Unexpected image archive in CPU-only bundle: ${archive}" ;;
    esac
  done

  # k0s emits OCI Image Layout archives. Verify actual named references in
  # all three archives, then compare the workload list with the chosen config.
  for kind in k0s addon workload; do
    archive="${BUNDLE_DIR}/images/${kind}-images.tar"
    list="${BUNDLE_DIR}/images/${kind}-images.list"
    index="$(tar -xOf "${archive}" index.json 2>/dev/null)" ||
      index="$(tar -xOf "${archive}" ./index.json 2>/dev/null)" ||
      err "OCI index.json missing from images/${kind}-images.tar"
    refs="$(printf '%s' "${index}" |
      "${BUNDLE_YQ}" eval -r '.manifests[] | .annotations."org.opencontainers.image.ref.name" // .annotations."io.containerd.image.name" // ""' -)" ||
      err "Cannot read OCI references in images/${kind}-images.tar"
    while IFS= read -r image_ref; do
      [[ -z "${image_ref}" ]] && continue
      canonical="${image_ref}"
      first="${image_ref%%/*}"
      if [[ "${image_ref}" != */* ]]; then
        canonical="docker.io/library/${image_ref}"
      elif [[ "${first}" != *.* && "${first}" != *:* && "${first}" != "localhost" ]]; then
        canonical="docker.io/${image_ref}"
      fi
      grep -Fxq -- "${image_ref}" <<< "${refs}" ||
        grep -Fxq -- "${canonical}" <<< "${refs}" ||
        err "OCI archive images/${kind}-images.tar is missing image ${image_ref}"
    done < "${list}"
  done
  python3 "${BUNDLED_SETUP}/build_airgap_image_inventory.py" validate \
    --inventory "${BUNDLE_DIR}/image-inventory.json" \
    --bundle-dir "${BUNDLE_DIR}" ||
    err "CPU-only image inventory is invalid or its staged LAS chart/image artifact is missing."
  log "CPU-only OCI archive, image inventory, and version-matched installer closure verified"
else
  [[ -n "${INSTALLER_SCRIPT}" ]] ||
    INSTALLER_SCRIPT="${SCRIPT_DIR}/k0s_cluster_with_stack.sh"
fi

if [[ "${VALIDATE_ONLY}" == "true" ]]; then
  [[ "${CPU_ONLY_BUNDLE}" == "true" ]] ||
    err "--validate-only is supported only for CPU-only bundles"
  PATH="${BUNDLE_DIR}/binaries:${PATH}" \
    CONFIG_FILE="${CONFIG_FILE}" AIRGAP_MODE=true \
    bash "${INSTALLER_SCRIPT}" validate-airgap-cpu-profile
  log "CPU-only bundle validation completed; no privileged host or cluster changes made"
  exit 0
fi

[[ -f "${INSTALLER_SCRIPT}" ]] ||
  err "Installer not found: ${INSTALLER_SCRIPT}"
[[ -x "${INSTALLER_SCRIPT}" ]] || chmod +x "${INSTALLER_SCRIPT}"

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

# Binaries
export K0S_INSTALL_URL="file://${BUNDLE_DIR}/binaries/k0s"
export YQ_DOWNLOAD_URL="file://${BUNDLE_DIR}/binaries/yq"

# Pre-loaded container-image bundles (OCI tarballs). The installer scp's EVERY
# *.tar in this directory to each node's /var/lib/k0s/images/, where k0s
# auto-imports all of them into containerd at startup — covering both k0s
# control-plane images (k0s-images.tar: pause/calico/kube-proxy/coredns/…) AND
# add-on component images (addon-images.tar: cert-manager/prometheus/metallb/…).
# This removes the need to pull from quay.io/ghcr.io/etc. over a blocked link.
if compgen -G "${BUNDLE_DIR}/images/*.tar" >/dev/null 2>&1; then
  export AIRGAP_K0S_IMAGE_DIR="${BUNDLE_DIR}/images"
  log "Pre-loaded image bundles found in: ${AIRGAP_K0S_IMAGE_DIR}"
  for _t in "${BUNDLE_DIR}/images"/*.tar; do log "  - $(basename "${_t}") ($(du -h "${_t}" | cut -f1))"; done
else
  err "No pre-loaded image bundles in air-gap bundle (images/*.tar)"
fi

# Static manifests
export CERT_MANAGER_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/local-path-storage.yaml"
if [[ "${CPU_ONLY_BUNDLE}" != "true" ]]; then
  export NVIDIA_DEVICE_PLUGIN_MANIFEST_URL="file://${BUNDLE_DIR}/manifests/nvidia-device-plugin.yml"
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

if [[ "${CPU_ONLY_BUNDLE}" != "true" ]]; then
  PROM_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/kube-prometheus-stack-${PROMETHEUS_CHART_VERSION}*.tgz" "kube-prometheus-stack")"
  OTEL_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/opentelemetry-operator-${OTEL_CHART_VERSION}*.tgz" "opentelemetry-operator")"
  KUBERAY_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/kuberay-operator-${KUBERAY_CHART_VERSION}*.tgz" "kuberay-operator")"
  METALLB_TGZ="$(_resolve_chart "${LOCAL_CHARTS_DIR}/metallb-${METALLB_CHART_VERSION}*.tgz" "metallb")"

  export PROMETHEUS_CHART_PATH="${PROM_TGZ}"
  export OTEL_CHART_PATH="${OTEL_TGZ}"
  export KUBERAY_CHART_PATH="${KUBERAY_TGZ}"
  export METALLB_CHART_PATH="${METALLB_TGZ}"
fi

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
if [[ -n "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="$(realpath "${CONFIG_FILE}")"
  if [[ "${CPU_ONLY_BUNDLE}" == "true" ]]; then
    cd "${BUNDLED_SETUP}"
  fi
  exec env CONFIG_FILE="${CONFIG_FILE}" "${INSTALLER_SCRIPT}" "${SUBCOMMAND}"
else
  log "No --config supplied. The installer will look for CONFIG_FILE in the environment"
  log "or its default location. Set CONFIG_FILE if it is not in the current directory."
  exec "${INSTALLER_SCRIPT}" "${SUBCOMMAND}"
fi
