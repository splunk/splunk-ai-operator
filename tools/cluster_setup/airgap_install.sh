#!/usr/bin/env bash
# airgap_install.sh
# One-command air-gapped install of the Splunk AI Platform.
#
# Run this on the internet-connected installer machine that also has SSH access
# to the (sealed) cluster nodes. It downloads every binary, Helm chart, static
# manifest, container-image tarball, and the complete NVIDIA driver RPM closure,
# then hands them to k0s_cluster_with_stack.sh, which pushes them to the nodes.
# The cluster nodes themselves never need outbound internet.
#
# Usage:
#   ./airgap_install.sh --config my-k0s-config.yaml
#
# Requirements on this machine:
#   RHEL 9 x86_64, curl, helm, tar, dnf, rpm, createrepo_c, sha256sum

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

# Target OS for GPU node driver packages. Supported: rhel9 (RPM closure) and
# ubuntu24 (deb closure). Default 'auto' detects it from the GPU nodes over SSH,
# because the installer delegates here without passing --gpu-os and there is no
# cluster-config key for it — so a hardcoded default silently builds the wrong
# package format. rhel10/amzn2023 code paths remain for internal testing only.
GPU_NODE_OS="${GPU_NODE_OS:-auto}"

# GPU driver closure inputs. The NVIDIA kernel module is DKMS-only (NVIDIA
# publishes no precompiled kmod for RHEL 9), so it must compile on each GPU
# node against that node's exact running kernel. kernel-devel/kernel-headers
# are therefore pinned per kernel and every target kernel must be named here.
GPU_KERNELS="${GPU_KERNELS:-}"        # comma-separated `uname -r` values
GPU_HOSTS="${GPU_HOSTS:-}"            # comma-separated IPs to survey over SSH
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-}"  # empty = latest in repo
SKIP_NVIDIA_CLOSURE="${SKIP_NVIDIA_CLOSURE:-false}"

OUTPUT_DIR="${OUTPUT_DIR:-./airgap-bundle}"

# Cluster config, used both to derive the GPU node IPs for the driver closure and
# to run the install. This is the only argument most users need to pass.
CONFIG_FILE="${CONFIG_FILE:-}"
INSTALLER_SCRIPT="${INSTALLER_SCRIPT:-}"
SUBCOMMAND="${SUBCOMMAND:-install}"
# Stop after staging artifacts instead of running the install. Useful for
# pre-staging, or for inspecting what would be pushed to the nodes.
DOWNLOAD_ONLY="${DOWNLOAD_ONLY:-false}"
# Keep the staged artifact tree instead of deleting it after a successful install.
KEEP_STAGING="${KEEP_STAGING:-false}"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --installer)   INSTALLER_SCRIPT="$2"; shift 2 ;;
    --subcommand)  SUBCOMMAND="$2"; shift 2 ;;
    --download-only) DOWNLOAD_ONLY="true"; shift ;;
    --keep-staging)  KEEP_STAGING="true"; shift ;;
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --k0s-version) K0S_VERSION="$2"; shift 2 ;;
    --gpu-os)      GPU_NODE_OS="$2"; shift 2 ;;
    --gpu-kernels) GPU_KERNELS="$2"; shift 2 ;;
    --gpu-hosts)   GPU_HOSTS="$2"; shift 2 ;;
    --driver-version) NVIDIA_DRIVER_VERSION="$2"; shift 2 ;;
    --skip-nvidia-closure) SKIP_NVIDIA_CLOSURE="true"; shift ;;
    -h|--help)
      cat <<'HELP'
airgap_install.sh — one-command air-gapped install of the Splunk AI Platform.

Downloads every artifact the cluster needs (binaries, Helm charts, manifests,
container-image tarballs, and the complete NVIDIA driver RPM closure), then runs
the installer, which pushes them to the nodes over SSH. The cluster nodes never
need outbound internet — only THIS machine does.

USAGE
  ./airgap_install.sh --config my-k0s-config.yaml

  That is the whole thing. GPU node IPs are read from the config and surveyed
  over SSH for their kernel versions, so no GPU flags are normally needed.

OPTIONS
  --config FILE         Path to your k0s-cluster-config.yaml. REQUIRED (unless
                        --download-only). GPU node IPs and SSH settings are read
                        from it.
                        Env: CONFIG_FILE

  --download-only       Download and stage everything, then STOP without
                        installing. Use to pre-stage artifacts or inspect them.
                        Env: DOWNLOAD_ONLY=true

  --keep-staging        Keep the staged artifact tree after a successful install.
                        Default: it is deleted to reclaim disk.
                        Env: KEEP_STAGING=true

  --subcommand CMD      Installer subcommand: install | join-workers | validate
                        Default: install
                        Env: SUBCOMMAND

  --installer SCRIPT    Path to k0s_cluster_with_stack.sh.
                        Default: same directory as this script.

  --output-dir DIR      Directory where artifacts are staged.
                        Default: ./airgap-bundle
                        Env: OUTPUT_DIR

  --k0s-version VER     Specific k0s release to download (e.g. v1.31.2+k0s.0).
                        Default: latest stable release
                        Env: K0S_VERSION

  --gpu-os OS           Target OS for GPU node package files.
                        Supported: auto (default), rhel9, ubuntu24
                        'auto' SSHes to the first GPU node and reads
                        /etc/os-release, then builds an RPM closure for RHEL 9 or
                        a .deb closure for Ubuntu 24.04. Set it explicitly only
                        when the nodes are not reachable yet.
                        Env: GPU_NODE_OS
                        A .deb closure is resolved inside an ubuntu:24.04
                        container, so podman or docker is required for it.

  --gpu-hosts LIST      Comma-separated GPU node IPs/hostnames. This machine
                        SSHes to each and reads `uname -r`. Normally NOT needed:
                        the GPU IPs are derived from --config automatically.
                        Use this only to override that.
                        Env: GPU_HOSTS

  --gpu-kernels LIST    Comma-separated `uname -r` values of every GPU node, e.g.
                          5.14.0-687.29.1.el9_8.x86_64,5.14.0-687.10.1.el9_8.x86_64
                        kernel-devel/kernel-headers are pinned to each of these
                        so DKMS can build on every node. Use only when the GPU
                        nodes are not reachable over SSH yet.
                        Env: GPU_KERNELS

  --driver-version VER  Pin the NVIDIA driver, e.g. 610.57.04. Default: whatever
                        is newest in NVIDIA's repo at bundle time. Pin this for
                        reproducible rebuilds.
                        Env: NVIDIA_DRIVER_VERSION

  --skip-nvidia-closure Skip building the offline NVIDIA driver RPM closure.
                        Use only when GPU nodes already have drivers installed.
                        Env: SKIP_NVIDIA_CLOSURE=true

  -h, --help            Show this help text.

WHAT IT DOES
  1. Preflight: verifies this host can build the closure and that the config and
     installer exist. Everything that can fail cheaply fails here, in seconds.
  2. Downloads binaries, manifests, Helm charts, and container-image tarballs.
  3. Surveys each GPU node's running kernel over SSH.
  4. Builds the NVIDIA driver RPM closure (~500 MB) for those exact kernels.
  5. Exports the file:// and path overrides the installer reads.
  6. Runs k0s_cluster_with_stack.sh, which pushes artifacts to every node.

WHAT IS STAGED
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
    nvidia-closure/     — a COMPLETE, self-contained dnf repository holding the
                          NVIDIA driver, DKMS, the gcc/make build toolchain, the
                          nvidia-container-toolkit, and kernel-devel/kernel-headers
                          for every kernel named by --gpu-kernels/--gpu-hosts.
                          ~500 MB / ~270 RPMs. This is what makes a truly offline
                          GPU install work: the installer scp's this directory to
                          each GPU node and installs with
                          `dnf --disablerepo='*' --repofrompath=...`, so the node
                          never contacts developer.download.nvidia.com.
    nvidia-closure.manifest — kernels covered, driver version, RPM inventory
    pyyaml-*.whl        — PyYAML wheel/sdist (all nodes)

  airgap-env.sh         — Source this to set env-var overrides for a manual install
  container-images.txt  — List of container images to mirror to your internal registry
  bundle-versions.txt   — Records all component versions for reproducibility
  checksums.sha256      — SHA-256 checksums for every staged file

ENVIRONMENT VARIABLE OVERRIDES
  This script exports all of these automatically before invoking the installer.
  You only need them if you are driving k0s_cluster_with_stack.sh by hand
  (see MANUAL USE below).

  K0S_INSTALL_URL                   URL/path to k0s binary (file:// or https://)
  YQ_DOWNLOAD_URL                   URL/path to yq binary
  CERT_MANAGER_MANIFEST_URL         URL/path to cert-manager.yaml
  LOCAL_PATH_MANIFEST_URL           URL/path to local-path-storage.yaml
  NVIDIA_DEVICE_PLUGIN_MANIFEST_URL URL/path to nvidia-device-plugin.yml
  PROMETHEUS_CHART_PATH             Local path to kube-prometheus-stack .tgz
  OTEL_CHART_PATH                   Local path to opentelemetry-operator .tgz
  KUBERAY_CHART_PATH                Local path to kuberay-operator .tgz
  METALLB_CHART_PATH                Local path to metallb .tgz
  AIRGAP_NVIDIA_CLOSURE_DIR         Path to packages/nvidia-closure (GPU nodes).
                                    The installer scp's this to each GPU node.
  AIRGAP_PYYAML_WHEEL_PATH          Path to PyYAML .whl file (all nodes, optional)

REQUIREMENTS FOR THE NVIDIA CLOSURE
  Building the closure requires this machine to be:
    - the SAME major OS family and arch as the GPU nodes (RHEL 9, x86_64).
      The OS MINOR version and running kernel do NOT need to match: dnf's
      $releasever resolves to '9', so a RHEL 9.6 host can download
      kernel-devel for a 9.8 node, and DKMS compiles on the target node.
    - able to reach dl.fedoraproject.org, developer.download.nvidia.com,
      and nvidia.github.io.
    - equipped with `dnf` and `createrepo_c` (dnf install -y createrepo_c).
  This step therefore cannot run on macOS. Run it on an internet-connected
  RHEL 9 host — the same "installer machine" that will later push the bundle.

EXAMPLES
  # The one-click case: download everything and install.
  ./airgap_install.sh --config my-k0s-config.yaml

  # Pin the driver for a reproducible rebuild.
  ./airgap_install.sh --config my-k0s-config.yaml --driver-version 610.57.04

  # GPU nodes already have drivers — skip the 500 MB closure.
  ./airgap_install.sh --config my-k0s-config.yaml --skip-nvidia-closure

  # Stage artifacts now, install later (no --config needed to download).
  ./airgap_install.sh --download-only --gpu-hosts 10.0.38.138,10.0.38.139

  # Add GPU workers to an existing cluster.
  ./airgap_install.sh --config my-k0s-config.yaml --subcommand join-workers

BEFORE YOU RUN
  Container images and model weights are NOT handled by this script:
    1. Mirror the images in container-images.txt to your internal registry and
       set images.registry in your config. (Run with --download-only first to
       generate that list.)
    2. Stage model weights via tools/artifacts_download_upload_scripts/.

MANUAL USE (advanced)
  To drive the installer yourself against already-staged artifacts:
    export AIRGAP_BUNDLE_DIR=./airgap-bundle/airgap-bundle-<timestamp>
    source "${AIRGAP_BUNDLE_DIR}/airgap-env.sh"
    CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install

GPU NODE PACKAGES (packages/ directory)
  The bundle includes a complete offline dnf repository for GPU workers. The
  main installer scp's it to each GPU node and installs from it with
  `--disablerepo='*'`, so no GPU node ever needs internet access.

  What is in packages/nvidia-closure/:
    - kmod-nvidia-latest-dkms + nvidia-driver-* + nvidia-kmod-common
    - nvidia-container-toolkit + libnvidia-container*
    - dkms, gcc, make, elfutils-libelf-devel (DKMS needs a compiler on-node)
    - kernel-devel + kernel-headers for EVERY kernel in --gpu-kernels
    - repodata/ generated by createrepo_c

  WHY kernels must be enumerated: NVIDIA ships no precompiled kernel module for
  RHEL 9 — only DKMS packages — so the module is compiled on each GPU node at
  install time and needs kernel-devel matching that node's exact `uname -r`.
  A bundle is valid ONLY for the kernels it was built for.

  IMPORTANT — pin kernels on GPU nodes. If a node later boots a kernel not in
  the bundle, DKMS has no headers to rebuild against and nvidia-smi will fail
  with no way to recover offline. Add to /etc/dnf/dnf.conf on GPU nodes:
    exclude=kernel*

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
# Only the explicitly-named values are rejected here. 'auto' is resolved further
# down, once the GPU node IPs have been derived from the config and can be
# probed over SSH.
case "${GPU_NODE_OS}" in
  auto|rhel9|ubuntu24) ;;
  *)
    echo "ERROR: --gpu-os '${GPU_NODE_OS}' is not supported." >&2
    echo "  Supported: 'rhel9', 'ubuntu24', or 'auto' (detect over SSH)." >&2
    echo "  rhel10 and amzn2023 paths exist in the code for internal testing" >&2
    echo "  but are not validated for production use." >&2
    echo "  To use an untested OS path, set GPU_NODE_OS directly and accept the risk:" >&2
    echo "    GPU_NODE_OS=rhel10 ./airgap_install.sh ..." >&2
    exit 1
    ;;
esac

# ── Install-target validation ─────────────────────────────────────────────────
# Resolved before any downloading: a missing config or installer is a certain
# failure, and finding out after a 500 MB closure build wastes the whole run.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "${INSTALLER_SCRIPT}" ]] || INSTALLER_SCRIPT="${SCRIPT_DIR}/k0s_cluster_with_stack.sh"

if [[ "${DOWNLOAD_ONLY}" != "true" ]]; then
  if [[ -z "${CONFIG_FILE}" ]]; then
    echo "ERROR: no cluster config given — nothing to install." >&2
    echo "" >&2
    echo "  Usage: ./airgap_install.sh --config my-k0s-config.yaml" >&2
    echo "" >&2
    echo "  Or pass --download-only to stage artifacts without installing." >&2
    exit 1
  fi
  [[ -f "${CONFIG_FILE}" ]] || { echo "ERROR: config file not found: ${CONFIG_FILE}" >&2; exit 1; }
  CONFIG_FILE="$(cd "$(dirname "${CONFIG_FILE}")" && pwd)/$(basename "${CONFIG_FILE}")"

  if [[ ! -f "${INSTALLER_SCRIPT}" ]]; then
    echo "ERROR: installer not found: ${INSTALLER_SCRIPT}" >&2
    echo "  Pass --installer /path/to/k0s_cluster_with_stack.sh" >&2
    exit 1
  fi
  [[ -x "${INSTALLER_SCRIPT}" ]] || chmod +x "${INSTALLER_SCRIPT}"
fi

# ── Derive GPU nodes and SSH settings from the cluster config ─────────────────
# This is what makes the one-command flow work: the config already lists every
# node IP and the SSH key, so the user does not repeat them as flags. Workers
# after the first cpuWorkers entries are the GPU workers — the same rule
# k0s_cluster_with_stack.sh uses to pick GPU nodes.
if [[ -n "${CONFIG_FILE}" ]] && command -v yq >/dev/null 2>&1; then
  [[ -n "${SSH_USER:-}" ]] || SSH_USER="$(yq eval '.cluster.sshUser' "${CONFIG_FILE}" 2>/dev/null || true)"
  [[ -n "${SSH_KEY_PATH:-}" ]] || SSH_KEY_PATH="$(yq eval '.cluster.sshKeyPath' "${CONFIG_FILE}" 2>/dev/null || true)"
  [[ "${SSH_USER:-}"     == "null" ]] && SSH_USER=""
  [[ "${SSH_KEY_PATH:-}" == "null" ]] && SSH_KEY_PATH=""
  # Expand a leading ~ so ssh/scp receive a real path.
  [[ -n "${SSH_KEY_PATH:-}" ]] && SSH_KEY_PATH="${SSH_KEY_PATH/#\~/${HOME}}"
  export SSH_USER SSH_KEY_PATH

  if [[ -z "${GPU_HOSTS}" && -z "${GPU_KERNELS}" ]]; then
    _cpu_count="$(yq eval '.nodes.cpuWorkers' "${CONFIG_FILE}" 2>/dev/null || echo 0)"
    [[ "${_cpu_count}" =~ ^[0-9]+$ ]] || _cpu_count=0
    _idx=0
    while IFS= read -r _w; do
      [[ -z "${_w}" || "${_w}" == "null" ]] && continue
      [[ ${_idx} -ge ${_cpu_count} ]] && GPU_HOSTS="${GPU_HOSTS}${GPU_HOSTS:+,}${_w}"
      _idx=$((_idx + 1))
    done < <(yq eval '.nodes.existingIPs.workers[]' "${CONFIG_FILE}" 2>/dev/null || true)
    [[ -n "${GPU_HOSTS}" ]] && echo "Derived GPU nodes from ${CONFIG_FILE##*/}: ${GPU_HOSTS}"
  fi
fi

# ── Resolve --gpu-os auto ─────────────────────────────────────────────────────
# Probing the node is the only reliable source: the installer delegates here with
# just --config, and the cluster config has no OS field. Detect before preflight
# so the capability checks below test for the right toolchain.
if [[ "${GPU_NODE_OS}" == "auto" ]]; then
  if [[ "${SKIP_NVIDIA_CLOSURE}" == "true" ]]; then
    # Nothing OS-specific is built, so the value only labels the manifest.
    GPU_NODE_OS="rhel9"
  else
    _os_probe_host="$(echo "${GPU_HOSTS}" | cut -d, -f1 | tr -d '[:space:]')"
    if [[ -z "${_os_probe_host}" ]]; then
      echo "ERROR: --gpu-os is 'auto' but no GPU node is known to probe." >&2
      echo "  Pass --gpu-os rhel9|ubuntu24 explicitly, or --gpu-hosts <ip>," >&2
      echo "  or a --config that lists nodes.existingIPs.workers." >&2
      exit 1
    fi
    _os_probe="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
                  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
                  ${SSH_KEY_PATH:+-i "${SSH_KEY_PATH}"} \
                  "${SSH_USER:-ec2-user}@${_os_probe_host}" \
                  '. /etc/os-release 2>/dev/null; echo "${ID}:${VERSION_ID}"' 2>/dev/null || true)"
    case "${_os_probe}" in
      ubuntu:24*)                      GPU_NODE_OS="ubuntu24" ;;
      rhel:9*|centos:9*|rocky:9*|almalinux:9*) GPU_NODE_OS="rhel9" ;;
      *)
        echo "ERROR: could not determine the GPU node OS from ${_os_probe_host}." >&2
        echo "  Probe returned: '${_os_probe:-<no response>}'" >&2
        echo "  Check SSH_USER/SSH_KEY_PATH reachability, or pass --gpu-os explicitly." >&2
        exit 1
        ;;
    esac
    echo "Detected GPU node OS from ${_os_probe_host}: ${GPU_NODE_OS}"
  fi
fi

# Package format the closure will be built in. Every format-specific branch below
# switches on this rather than re-testing GPU_NODE_OS.
if [[ "${GPU_NODE_OS}" == "ubuntu24" ]]; then
  CLOSURE_PKG_FORMAT="deb"
else
  CLOSURE_PKG_FORMAT="rpm"
fi

# ── Closure preflight ─────────────────────────────────────────────────────────
# Validated up front, before the ~15 minutes of image pulls and chart downloads
# below: a missing kernel list or a macOS build host is a certain failure, and
# discovering it at the end wastes the whole run.
if [[ "${SKIP_NVIDIA_CLOSURE}" != "true" ]]; then
  if [[ -z "${GPU_KERNELS}" && -z "${GPU_HOSTS}" ]]; then
    echo "ERROR: could not determine the GPU nodes — cannot build the offline NVIDIA repo." >&2
    echo "" >&2
    echo "  NVIDIA ships DKMS-only packages for RHEL 9, so the kernel module is compiled" >&2
    echo "  on each GPU node and needs kernel-devel matching that node's exact kernel." >&2
    echo "  A bundle is valid only for the kernels it was built for." >&2
    echo "" >&2
    echo "  Normally these come from --config via nodes.existingIPs.workers and" >&2
    echo "  nodes.cpuWorkers. Check those are set, or name the nodes directly:" >&2
    echo "    --gpu-hosts 10.0.38.138,10.0.38.139         # survey the nodes over SSH" >&2
    echo "    --gpu-kernels 5.14.0-687.29.1.el9_8.x86_64  # name kernels explicitly" >&2
    echo "" >&2
    echo "  Or, if the GPU nodes already have NVIDIA drivers installed:" >&2
    echo "    --skip-nvidia-closure" >&2
    exit 1
  fi
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: the NVIDIA driver closure must be built on a RHEL 9 x86_64 Linux host." >&2
    echo "  This machine is $(uname -s). dnf resolves RPMs against the host's own repo" >&2
    echo "  metadata, so the closure cannot be built on macOS." >&2
    echo "" >&2
    echo "  Run this script on your internet-connected RHEL 9 installer machine, or" >&2
    echo "  pass --skip-nvidia-closure to build a bundle without GPU driver packages." >&2
    exit 1
  fi
  if [[ "${CLOSURE_PKG_FORMAT}" == "deb" ]]; then
    # A .deb closure needs apt to resolve dependencies against Ubuntu's archive.
    # The build host is normally RHEL, which has no apt, so resolution runs inside
    # an ubuntu:24.04 container instead. That is also the more correct approach
    # even on an Ubuntu host: apt skips packages already installed locally, so
    # resolving in a pristine rootfs is what makes the closure complete.
    CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"
    if [[ -z "${CONTAINER_RUNTIME}" ]]; then
      for _rt in podman docker; do
        command -v "${_rt}" >/dev/null 2>&1 && { CONTAINER_RUNTIME="${_rt}"; break; }
      done
    fi
    if [[ -z "${CONTAINER_RUNTIME}" ]]; then
      echo "ERROR: neither podman nor docker found — required to build a .deb driver closure." >&2
      echo "  Ubuntu driver packages are resolved inside an ubuntu:24.04 container so the" >&2
      echo "  closure is complete and independent of this host's own package state." >&2
      echo "  Install one with: sudo dnf install -y podman" >&2
      echo "  Or pass --skip-nvidia-closure and pre-install drivers on the GPU nodes." >&2
      exit 1
    fi
  else
    for _cmd in dnf rpm createrepo_c; do
      if ! command -v "${_cmd}" >/dev/null 2>&1; then
        echo "ERROR: ${_cmd} not found — required to build the offline NVIDIA driver repo." >&2
        echo "  Install it with: sudo dnf install -y ${_cmd}" >&2
        echo "  Or pass --skip-nvidia-closure to build a bundle without GPU driver packages." >&2
        exit 1
      fi
    done
    _host_major="$(rpm -E %{rhel} 2>/dev/null || echo "")"
    if [[ "${_host_major}" != "9" ]]; then
      echo "ERROR: this host reports RHEL major '${_host_major}' but --gpu-os is rhel9." >&2
      echo "  The closure must be built on the same major OS family as the GPU nodes so" >&2
      echo "  dnf resolves the right dependency versions. Minor version and running" >&2
      echo "  kernel need NOT match — \$releasever resolves to '9' and DKMS compiles on" >&2
      echo "  the target node." >&2
      exit 1
    fi
  fi
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
if [[ "${SKIP_NVIDIA_CLOSURE}" == "true" ]]; then
  log "  nvidia closure        : SKIPPED (drivers must be pre-installed on GPU nodes)"
else
  log "  nvidia driver         : ${NVIDIA_DRIVER_VERSION:-latest available}"
  log "  gpu kernels           : ${GPU_KERNELS:-<to be surveyed from --gpu-hosts>}"
fi
log ""

mkdir -p \
  "${STAGE_DIR}/binaries" \
  "${STAGE_DIR}/manifests" \
  "${STAGE_DIR}/charts" \
  "${STAGE_DIR}/packages"

# Absolute from here on. OUTPUT_DIR defaults to the relative ./airgap-bundle, and
# the file:// URLs exported below are URIs, not paths — curl rejects
# file://./relative/path with "URL using bad/illegal format".
STAGE_DIR="$(cd "${STAGE_DIR}" && pwd)"

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
      # Images passed as container ARGS rather than an `image:` key. The
      # prometheus-operator takes --prometheus-config-reloader=<ref> and
      # --thanos-default-base-image=<ref>, so an image:-only grep left
      # prometheus-config-reloader out of the bundle and every Prometheus and
      # Alertmanager pod sat in Init:ImagePullBackOff. Requires a dotted registry
      # host in the ref to avoid matching non-image flag values.
      helm template "${_tgz}" 2>/dev/null \
        | grep -oE '=[a-z0-9-]+(\.[a-z0-9-]+)+/[a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+' \
        | sed -E 's/^=//' || true
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
# The main installer scp's packages/nvidia-closure/ to every GPU node and
# installs from it with `dnf --disablerepo='*' --repofrompath=...`, so GPU nodes
# never contact developer.download.nvidia.com.
log "--- Building GPU node package closure (target OS: ${GPU_NODE_OS}) ---"

# Resolve EPEL major from GPU_NODE_OS. Only the rpm closure needs EPEL (it is
# where `dkms` lives on RHEL); on Debian dkms is in the main archive, so warning
# about an "unknown" OS here would be noise on a perfectly supported target.
if [[ "${CLOSURE_PKG_FORMAT}" == "deb" ]]; then
  EPEL_MAJOR=9
else
  case "${GPU_NODE_OS}" in
    rhel9|amzn2023) EPEL_MAJOR=9 ;;
    rhel10)         EPEL_MAJOR=10 ;;
    *)
      warn "Unknown GPU_NODE_OS '${GPU_NODE_OS}'; defaulting EPEL major to 9"
      EPEL_MAJOR=9 ;;
  esac
fi

CLOSURE_DIR="${STAGE_DIR}/packages/nvidia-closure"

# ── 5a. Resolve the target kernel list ────────────────────────────────────────
# DKMS compiles the nvidia kmod on each GPU node, so kernel-devel must be pinned
# to each node's exact `uname -r`. Survey the nodes over SSH if asked.
GPU_GLIBC_VERSIONS=""
# Every kernel-core INSTALLED on a GPU node, not just the running one. dkms's rich
# dependency is evaluated per installed kernel-core, so a node that kept an older
# (or staged a newer) kernel needs kernel-devel-matched for that one too.
GPU_INSTALLED_KERNELS=""
if [[ "${SKIP_NVIDIA_CLOSURE}" != "true" && -z "${GPU_KERNELS}" && -n "${GPU_HOSTS}" ]]; then
  log "Surveying GPU hosts for running kernels: ${GPU_HOSTS}"
  _ssh_user="${SSH_USER:-ec2-user}"
  _surveyed=""
  IFS=',' read -ra _hosts <<< "${GPU_HOSTS}"
  for _h in "${_hosts[@]}"; do
    _h="$(echo "${_h}" | tr -d '[:space:]')"
    [[ -z "${_h}" ]] && continue
    # Same three facts on both families, different tools. Line 1: running kernel.
    # Line 2: the libc version other packages pin to exactly. Then every kernel
    # INSTALLED on the node — on Debian that is /lib/modules, which is exactly the
    # set dkms iterates over when it auto-builds on install.
    if [[ "${CLOSURE_PKG_FORMAT}" == "deb" ]]; then
      _probe_cmd='uname -r; dpkg-query -W -f="\${Version}\n" libc6 2>/dev/null | head -1; echo "--cores--"; ls -1 /lib/modules 2>/dev/null'
    else
      _probe_cmd='uname -r; rpm -q glibc --qf "%{VERSION}-%{RELEASE}\n" 2>/dev/null; echo "--cores--"; rpm -q kernel-core --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" 2>/dev/null'
    fi
    _probe="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
               ${SSH_KEY_PATH:+-i "${SSH_KEY_PATH}"} \
               "${_ssh_user}@${_h}" \
               "${_probe_cmd}" 2>/dev/null || true)"
    _krel="$(echo "${_probe}" | sed -n 1p | tr -d '[:space:]')"
    _glibc="$(echo "${_probe}" | sed -n 2p | tr -d '[:space:]')"
    _cores="$(echo "${_probe}" | sed -n '/^--cores--$/,$p' | tail -n +2)"
    [[ -z "${_krel}" ]] && err "Could not read 'uname -r' from GPU host ${_h}. Check SSH_USER/SSH_KEY_PATH, or pass --gpu-kernels explicitly."
    log "  ${_h} -> ${_krel}${_glibc:+ (glibc ${_glibc})}"
    # Dedupe: a homogeneous fleet reports the same kernel from every host, and a
    # repeated entry means the closure builder asks for the same
    # linux-headers/kernel-devel package once per node.
    if [[ ",${_surveyed}," != *",${_krel},"* ]]; then
      _surveyed="${_surveyed}${_surveyed:+,}${_krel}"
    fi
    if [[ -n "${_glibc}" && ",${GPU_GLIBC_VERSIONS}," != *",${_glibc},"* ]]; then
      GPU_GLIBC_VERSIONS="${GPU_GLIBC_VERSIONS}${GPU_GLIBC_VERSIONS:+,}${_glibc}"
    fi
    while read -r _c; do
      _c="$(echo "${_c}" | tr -d '[:space:]')"
      [[ -z "${_c}" ]] && continue
      if [[ ",${GPU_INSTALLED_KERNELS}," != *",${_c},"* ]]; then
        GPU_INSTALLED_KERNELS="${GPU_INSTALLED_KERNELS}${GPU_INSTALLED_KERNELS:+,}${_c}"
        [[ "${_c}" != "${_krel}" ]] && log "    also installed (not running): ${_c}"
      fi
    done <<< "${_cores}"
  done
  GPU_KERNELS="${_surveyed}"
fi

if [[ "${SKIP_NVIDIA_CLOSURE}" == "true" ]]; then
  warn "SKIP_NVIDIA_CLOSURE=true — not building the offline NVIDIA driver repo."
  warn "  GPU nodes MUST already have the NVIDIA driver and nvidia-container-toolkit"
  warn "  installed, or the air-gapped install will fail on the GPU nodes."
elif [[ -z "${GPU_KERNELS}" ]]; then
  # Reachable only if the --gpu-hosts survey above found nothing; the
  # neither-flag-given case already failed in preflight.
  err "Could not determine any GPU node kernel from --gpu-hosts '${GPU_HOSTS}'.
  Every SSH survey failed. Check reachability and SSH_KEY_PATH, or name the
  kernels explicitly with --gpu-kernels 5.14.0-687.29.1.el9_8.x86_64"
elif [[ "${CLOSURE_PKG_FORMAT}" == "deb" ]]; then
  # ── 5b-deb. Build the Ubuntu .deb closure ──────────────────────────────────
  # Resolution runs inside an ubuntu:24.04 container, for two reasons. The build
  # host is normally RHEL and has no apt at all; and even on an Ubuntu host, apt
  # silently omits any dependency already installed locally, which offline turns
  # into a missing package on the node. A pristine minimal rootfs has strictly
  # FEWER packages preinstalled than a real Ubuntu Server node, so resolving
  # there errs toward over-collecting — the safe direction for an air-gap bundle.
  mkdir -p "${CLOSURE_DIR}"

  IFS=',' read -ra _kernels <<< "${GPU_KERNELS}"
  _hdr_pkgs=()
  for _k in "${_kernels[@]}"; do
    _k="$(echo "${_k}" | tr -d '[:space:]')"
    [[ -z "${_k}" ]] && continue
    _hdr_pkgs+=( "linux-headers-${_k}" )
  done
  [[ ${#_hdr_pkgs[@]} -gt 0 ]] || err "Could not parse any kernel version out of '${GPU_KERNELS}'."

  # Kernels installed on a node but not running. Debian's dkms ships
  # /etc/kernel/postinst.d/dkms and builds the module for every kernel in
  # /lib/modules — and a build for a spare kernel fails as a postinst WARNING,
  # not an install error. So unlike RHEL (where the transaction aborts loudly)
  # omitting these yields a node that looks fine until it reboots into the spare
  # kernel with no nvidia module.
  for _c in $(echo "${GPU_INSTALLED_KERNELS}" | tr ',' ' '); do
    _c="$(echo "${_c}" | tr -d '[:space:]')"
    [[ -z "${_c}" ]] && continue
    [[ ",${GPU_KERNELS}," == *",${_c},"* ]] && continue
    log "  also staging headers for installed-but-not-running kernel: ${_c}"
    _hdr_pkgs+=( "linux-headers-${_c}" )
  done

  # Driver package set. Unlike the rhel9 repo (where `cuda-drivers` does not
  # exist), the Ubuntu CUDA repo does publish it and resolving it is how the
  # concrete DKMS driver packages get picked — the same meta-package the
  # non-air-gap Ubuntu path installs, so both paths converge on one driver set.
  _deb_pkgs=( cuda-drivers nvidia-container-toolkit dkms build-essential libelf-dev )

  # libc6 is handled the opposite way from RHEL's glibc. There, shipping a newer
  # glibc-devel made dnf try to upgrade glibc and collide with glibc-langpack-en,
  # so the fix was to DROP glibc and pin devel/headers to the node. apt has no
  # equivalent collision: it upgrades libc6 + libc-bin + libc6-dev + linux-libc-dev
  # atomically as long as all four are present. So the fix here is the inverse —
  # ship the whole consistent set rather than removing it, and let apt do the
  # coordinated upgrade offline.
  _deb_pkgs+=( libc6 libc-bin libc6-dev linux-libc-dev )

  _node_libc="$(echo "${GPU_GLIBC_VERSIONS}" | cut -d, -f1)"
  if [[ -n "${_node_libc}" ]]; then
    log "  GPU node libc6 : ${_node_libc} (closure ships a consistent libc set)"
  else
    warn "GPU node libc6 version unknown (kernels were passed via --gpu-kernels)."
    warn "  Prefer --gpu-hosts so the closure can be checked against the node."
  fi

  log "Resolving NVIDIA driver closure in a ${CONTAINER_RUNTIME} ubuntu:24.04 container..."
  log "  driver package : cuda-drivers (meta)"
  log "  target kernels : ${GPU_KERNELS}"

  # The whole resolve is one container run so a failure leaves nothing behind.
  # `set -e` inside matters: apt-get failures must fail the container, not get
  # masked by a later successful command.
  if ! "${CONTAINER_RUNTIME}" run --rm \
        -v "${CLOSURE_DIR}:/closure:z" \
        docker.io/library/ubuntu:24.04 \
        bash -euo pipefail -c "
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq
          apt-get install -y --no-install-recommends ca-certificates curl gnupg dpkg-dev >/dev/null

          # Same CUDA repo the non-air-gap path adds on the node itself.
          curl -fsSL 'https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb' -o /tmp/k.deb
          dpkg -i /tmp/k.deb >/dev/null

          # nvidia-container-toolkit lives in its own repo, not the CUDA one.
          curl -fsSL 'https://nvidia.github.io/libnvidia-container/gpgkey' \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
          curl -fsSL 'https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list' \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list

          apt-get update -qq

          # Walk the dependency graph explicitly rather than using
          # \`apt-get install --download-only\`. That command omits anything already
          # installed in this container — measured: it silently skipped libc6,
          # libc-bin, make and perl-base, so offline the node had no installable
          # 'make' and build-essential (hence DKMS) could not install. Recursing
          # the graph and downloading each package individually is immune to the
          # local package state, which is the whole point of a closure.
          apt-cache depends --recurse --no-recommends --no-suggests \
            --no-conflicts --no-breaks --no-replaces --no-enhances \
            ${_deb_pkgs[*]} ${_hdr_pkgs[*]} 2>/dev/null \
            | grep -v '^ ' | grep -v '^<' | sed 's/:i386$//' | sort -u > /tmp/pkgs.txt

          cd /closure
          _missing=0
          while read -r _p; do
            [ -z \"\${_p}\" ] && continue
            # Virtual packages have no downloadable file; a real provider is
            # already in the list, so a miss here is expected and harmless.
            apt-get download \"\${_p}\" >/dev/null 2>&1 || {
              echo \"  note: no downloadable file for '\${_p}' (virtual or unavailable)\"
              _missing=\$((_missing + 1))
            }
          done < /tmp/pkgs.txt
          echo \"resolved \$(wc -l < /tmp/pkgs.txt) graph nodes, \${_missing} without a file\"

          # Multiarch i386 variants are dead weight offline (the RHEL closure
          # excludes *.i686 for the same reason).
          rm -f /closure/*_i386.deb

          dpkg-scanpackages --multiversion . /dev/null > Packages 2>/dev/null
          gzip -9c Packages > Packages.gz
          chmod -R a+rX /closure
        "; then
    err "Failed to resolve the Ubuntu NVIDIA driver closure.
  Common causes:
    - A requested linux-headers version is not in the Ubuntu archive. AWS/HWE
      kernels age out of -updates; check with
        apt-cache madison linux-headers-<kernel>
      inside an ubuntu:24.04 container.
    - No outbound access to developer.download.nvidia.com or nvidia.github.io
      from this build host.
    - ${CONTAINER_RUNTIME} could not pull docker.io/library/ubuntu:24.04."
  fi

  _pkg_count="$(find "${CLOSURE_DIR}" -name '*.deb' -type f | wc -l | tr -d ' ')"
  [[ "${_pkg_count}" -gt 0 ]] || err "Closure resolution produced no .deb files — nothing to bundle."
  log "Closure resolved: ${_pkg_count} debs"

  # Headers are the one package DKMS cannot work around, so assert per kernel
  # rather than trusting the resolve.
  for _k in "${_kernels[@]}"; do
    _k="$(echo "${_k}" | tr -d '[:space:]')"
    [[ -z "${_k}" ]] && continue
    compgen -G "${CLOSURE_DIR}/linux-headers-${_k}_*.deb" >/dev/null 2>&1 \
      || err "linux-headers for '${_k}' is missing from the closure — DKMS could not build on that node.
  That kernel is probably no longer in the Ubuntu archive. Either boot the node
  onto a current kernel, or name an available one with --gpu-kernels."
  done

  [[ -f "${CLOSURE_DIR}/Packages.gz" ]] \
    || err "dpkg-scanpackages produced no Packages.gz — the offline repo would be unusable on the nodes."

  {
    echo "# NVIDIA offline closure manifest"
    echo "built_on_os=$(. /etc/os-release; echo "${PRETTY_NAME}")"
    echo "built_on_kernel=$(uname -r)"
    echo "built_via=${CONTAINER_RUNTIME} ubuntu:24.04"
    echo "gpu_node_os=${GPU_NODE_OS}"
    echo "pkg_format=deb"
    echo "target_kernels=${GPU_KERNELS}"
    echo "node_libc6=${_node_libc:-unknown}"
    echo "deb_count=${_pkg_count}"
    echo "size=$(du -sh "${CLOSURE_DIR}" | cut -f1)"
    echo ""
    echo "# deb inventory"
    find "${CLOSURE_DIR}" -name '*.deb' -type f -exec basename {} \; | sort
  } > "${STAGE_DIR}/packages/nvidia-closure.manifest"

  echo "${GPU_KERNELS}" > "${CLOSURE_DIR}/.target-kernels"
  # Explicit format marker so the installer dispatches on a recorded value
  # instead of sniffing for repodata/ vs Packages.gz.
  echo "deb" > "${CLOSURE_DIR}/.pkg-format"
  log "NVIDIA closure ready: ${CLOSURE_DIR} ($(du -sh "${CLOSURE_DIR}" | cut -f1), ${_pkg_count} debs)"
else
  # ── 5b. Build the closure ──────────────────────────────────────────────────
  # Build-host capability (Linux, dnf/rpm/createrepo_c, RHEL major 9) was already
  # validated in preflight so a bad host fails before the long downloads above.
  mkdir -p "${CLOSURE_DIR}"

  # Repos needed on THIS host to resolve the closure. All three are additive and
  # left in place afterwards; they only affect this build host, not the nodes.
  log "Ensuring build-host repos are configured (EPEL, CUDA, nvidia-container-toolkit)..."
  if ! rpm -q epel-release >/dev/null 2>&1; then
    _epel_tmp="$(mktemp -d)"
    download "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EPEL_MAJOR}.noarch.rpm" \
             "${_epel_tmp}/epel-release.rpm"
    sudo dnf install -y "${_epel_tmp}/epel-release.rpm" \
      || err "Failed to install epel-release on the build host (needed to resolve 'dkms')."
    rm -rf "${_epel_tmp}"
  fi
  if [[ ! -f /etc/yum.repos.d/cuda-rhel9.repo ]]; then
    sudo curl -fsSL \
      "https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo" \
      -o /etc/yum.repos.d/cuda-rhel9.repo \
      || err "Could not fetch the CUDA repo definition for the build host."
  fi
  if [[ ! -f /etc/yum.repos.d/nvidia-container-toolkit.repo ]]; then
    sudo curl -fsSL \
      "https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo" \
      -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
      || err "Could not fetch the nvidia-container-toolkit repo definition for the build host."
  fi
  # CRB provides a few EPEL build deps on RHEL. Best-effort (absent on AL2023).
  sudo dnf config-manager --set-enabled crb >/dev/null 2>&1 || true

  # Driver package set. Deliberately NOT the `cuda-drivers` meta-package: NVIDIA
  # split its rhel9 repo and `cuda-drivers` no longer exists there. These are the
  # concrete packages that a working install resolves to.
  _drv_suffix=""
  [[ -n "${NVIDIA_DRIVER_VERSION}" ]] && _drv_suffix="-3:${NVIDIA_DRIVER_VERSION}"
  NVIDIA_PKGS=(
    "kmod-nvidia-latest-dkms${_drv_suffix}"
    "nvidia-driver-cuda${_drv_suffix}"
    "nvidia-driver-cuda-libs${_drv_suffix}"
    "nvidia-kmod-common${_drv_suffix}"
    "nvidia-modprobe${_drv_suffix}"
    "nvidia-persistenced${_drv_suffix}"
    nvidia-container-toolkit
    dkms gcc make elfutils-libelf-devel
  )

  # kernel-devel/kernel-headers for every target kernel.
  IFS=',' read -ra _kernels <<< "${GPU_KERNELS}"
  _kernel_pkgs=()
  _kdm_pkgs=()
  for _k in "${_kernels[@]}"; do
    _k="$(echo "${_k}" | tr -d '[:space:]')"
    [[ -z "${_k}" ]] && continue
    _k="${_k%.x86_64}"     # dnf wants the NVR without the arch suffix
    _kernel_pkgs+=( "kernel-devel-${_k}" "kernel-headers-${_k}" )
    _kdm_pkgs+=( "kernel-devel-matched-${_k}" )
  done
  [[ ${#_kernel_pkgs[@]} -gt 0 ]] || err "Could not parse any kernel version out of '${GPU_KERNELS}'."

  # Kernels a node has INSTALLED but is not running. dkms's rich dependency is
  # evaluated against every installed kernel-core, so leaving these out means the
  # transaction still fails on a node that kept an old kernel around — the same
  # failure mode the running-kernel kernel-devel-matched was added to fix.
  # kernel-devel only, never kernel-headers: kernel-devel is install-only (many
  # versions coexist) while kernel-headers is not, so a second headers version
  # would conflict with the one already on the node.
  _extra_devel_pkgs=()
  if [[ -n "${GPU_INSTALLED_KERNELS}" ]]; then
    IFS=',' read -ra _all_cores <<< "${GPU_INSTALLED_KERNELS}"
    for _c in "${_all_cores[@]}"; do
      _c="$(echo "${_c}" | tr -d '[:space:]')"; _c="${_c%.x86_64}"
      [[ -z "${_c}" ]] && continue
      [[ ",${GPU_KERNELS//.x86_64/}," == *",${_c},"* ]] && continue
      _extra_devel_pkgs+=( "kernel-devel-${_c}" )
      _kdm_pkgs+=( "kernel-devel-matched-${_c}" )
    done
  fi

  # Exclusions, each one load-bearing:
  #  kernel-core/kernel-modules-core/kernel-5.14* — a driver install otherwise
  #    drags in a NEWER kernel as a dependency. Offline that is a trap: the node
  #    could reboot into a kernel the DKMS module was never built for.
  #  *.i686 + --forcearch=x86_64 — without these, dnf pulls 32-bit duplicates of
  #    every glibc/gcc dependency (~100 MB of dead weight).
  #
  # glibc is deliberately NOT excluded here. Every package in the closure needs
  # libc.so.6, so an -x 'glibc' leaves that with no provider and dnf abandons the
  # entire resolve ("requires libc.so.6()(64bit), but none of the providers can be
  # installed"). The glibc version skew is corrected AFTER the resolve instead, by
  # discarding the resolved glibc RPMs and substituting node-pinned ones.
  log "Resolving NVIDIA driver closure (this downloads ~500 MB, several minutes)..."
  log "  driver version : ${NVIDIA_DRIVER_VERSION:-latest available}"
  log "  target kernels : ${GPU_KERNELS}"
  if ! sudo dnf download --resolve --alldeps --forcearch=x86_64 \
         --setopt=install_weak_deps=False \
         --destdir="${CLOSURE_DIR}" \
         -x 'kernel-core*' -x 'kernel-modules-core*' -x 'kernel-5.14*' -x '*.i686' \
         "${NVIDIA_PKGS[@]}" "${_kernel_pkgs[@]}"; then
    err "Failed to resolve the NVIDIA driver closure.
  Common causes:
    - A requested kernel-devel is not in this host's repos. RHEL EUS kernels are
      a frequent culprit: check with
        dnf list available kernel-devel --showduplicates | grep <kernel>
      and enable the matching EUS repo if the node runs an EUS kernel.
    - --driver-version '${NVIDIA_DRIVER_VERSION}' does not exist in the CUDA repo.
      List valid versions with:
        dnf list available kmod-nvidia-latest-dkms --showduplicates"
  fi

  # kernel-devel-matched, fetched separately and WITHOUT --resolve.
  #
  # dkms >= 3.4 carries the rich dependency `(kernel-devel-matched if kernel-core)`,
  # so on any node with kernel-core installed dnf demands kernel-devel-matched and
  # the whole transaction fails with "none of the providers can be installed".
  #
  # It cannot go in the resolve above: kernel-devel-matched hard-requires
  # `kernel-core = <exact>`, which the -x 'kernel-core*' exclusion filters out,
  # and dnf then errors instead of just omitting it. Downloading it on its own
  # sidesteps the dependency walk — the node already has the matching kernel-core,
  # so the dep is satisfied there even though it cannot be satisfied here.
  #
  # Best-effort per kernel: kernel-devel-matched is absent for some older/EUS
  # kernels, and a node only needs it for kernels it actually has installed.
  # kernel-devel for the non-running installed kernels. Fetched here rather than in
  # the resolve so a version missing from this host's repos is a warning, not a
  # fatal error — a node's spare kernel is far less likely to be available than the
  # one it is actually running.
  if [[ ${#_extra_devel_pkgs[@]} -gt 0 ]]; then
    log "Fetching kernel-devel for kernels installed but not running on GPU nodes..."
    for _ed in "${_extra_devel_pkgs[@]}"; do
      if sudo dnf download --destdir="${CLOSURE_DIR}" --forcearch=x86_64 \
           "${_ed}" >/dev/null 2>&1; then
        log "  ${_ed}"
      else
        warn "  ${_ed} unavailable in this host's repos — skipping."
        warn "    dkms may fail on the node that has that kernel-core installed."
      fi
    done
  fi

  log "Fetching kernel-devel-matched (satisfies the dkms >= 3.4 rich dependency)..."
  for _kdm in "${_kdm_pkgs[@]}"; do
    if sudo dnf download --destdir="${CLOSURE_DIR}" --forcearch=x86_64 \
         "${_kdm}" >/dev/null 2>&1; then
      log "  ${_kdm}"
    else
      warn "  ${_kdm} unavailable in this host's repos — skipping."
      warn "    If a GPU node has that kernel-core installed, dkms will fail there."
    fi
  done

  # glibc substitution: discard whatever glibc the resolve pulled (this host's
  # repos serve the newest, e.g. 2.34-275) and replace it with glibc-devel/headers
  # pinned to each NODE's installed glibc.
  #
  # gcc requires glibc-devel, which hard-requires `glibc = <exact>`. Ship the newer
  # pair and offline dnf tries to UPGRADE glibc on the node, which collides with the
  # already-installed glibc-langpack-en ("cannot install both glibc-2.34-275 and
  # glibc-2.34-274 from @System") and aborts the whole transaction — no dkms, no
  # driver. Removing glibc itself from the closure is what makes the pinning work:
  # with no glibc RPM available, a mismatched glibc-devel is simply unsatisfiable
  # and dnf picks the version matching the glibc the node already has.
  if [[ -n "${GPU_GLIBC_VERSIONS}" ]]; then
    log "Substituting node-pinned glibc-devel/headers into the closure..."
    sudo rm -f "${CLOSURE_DIR}"/glibc-*.rpm 2>/dev/null || true
    IFS=',' read -ra _glibcs <<< "${GPU_GLIBC_VERSIONS}"
    for _g in "${_glibcs[@]}"; do
      [[ -z "${_g}" ]] && continue
      for _gp in "glibc-devel-${_g}" "glibc-headers-${_g}"; do
        if sudo dnf download --destdir="${CLOSURE_DIR}" --forcearch=x86_64 \
             "${_gp}" >/dev/null 2>&1; then
          log "  ${_gp}"
        else
          warn "  ${_gp} unavailable in this host's repos — skipping."
          warn "    gcc cannot install on a node running glibc ${_g}, so DKMS will fail there."
        fi
      done
    done
    # i686 variants come along for the ride and are dead weight offline.
    sudo rm -f "${CLOSURE_DIR}"/glibc-*.i686.rpm 2>/dev/null || true
  else
    warn "GPU node glibc versions unknown (kernels were passed via --gpu-kernels)."
    warn "  If a node's glibc differs from this host's repos, gcc/dkms will fail to install."
    warn "  Prefer --gpu-hosts so the closure can be pinned to each node."
  fi

  # --alldeps still omits packages already installed on THIS host, and the
  # resolved set can carry a glibc newer than the nodes'. Both are silent
  # correctness traps offline, so verify rather than assume.
  _rpm_count="$(find "${CLOSURE_DIR}" -name '*.rpm' -type f | wc -l | tr -d ' ')"
  [[ "${_rpm_count}" -gt 0 ]] || err "Closure resolution produced no RPMs — nothing to bundle."
  log "Closure resolved: ${_rpm_count} RPMs"

  for _k in "${_kernels[@]}"; do
    _k="$(echo "${_k}" | tr -d '[:space:]')"; _k="${_k%.x86_64}"
    [[ -z "${_k}" ]] && continue
    compgen -G "${CLOSURE_DIR}/kernel-devel-${_k}*.rpm" >/dev/null 2>&1 \
      || err "kernel-devel for '${_k}' is missing from the closure — DKMS could not build on that node.
  The package resolved but did not download, which usually means the kernel is
  only in an EUS/older repo. Enable that repo on this host and re-run."
  done

  log "Generating repodata (createrepo_c)..."
  createrepo_c --quiet "${CLOSURE_DIR}" \
    || err "createrepo_c failed — the offline repo would be unusable on the nodes."

  # Manifest: makes a rebuilt bundle auditable and records exactly which kernels
  # this closure is valid for, which the installer re-checks per node.
  {
    echo "# NVIDIA offline closure manifest"
    echo "built_on_os=$(. /etc/os-release; echo "${PRETTY_NAME}")"
    echo "built_on_kernel=$(uname -r)"
    echo "gpu_node_os=${GPU_NODE_OS}"
    echo "target_kernels=${GPU_KERNELS}"
    echo "driver_version_requested=${NVIDIA_DRIVER_VERSION:-latest}"
    echo "driver_version_resolved=$(basename "$(compgen -G "${CLOSURE_DIR}/kmod-nvidia-latest-dkms-*.rpm" | head -1)" 2>/dev/null || echo unknown)"
    echo "rpm_count=${_rpm_count}"
    echo "size=$(du -sh "${CLOSURE_DIR}" | cut -f1)"
    echo ""
    echo "# RPM inventory"
    find "${CLOSURE_DIR}" -name '*.rpm' -type f -exec basename {} \; | sort
  } > "${STAGE_DIR}/packages/nvidia-closure.manifest"

  echo "${GPU_KERNELS}" > "${CLOSURE_DIR}/.target-kernels"
  echo "rpm" > "${CLOSURE_DIR}/.pkg-format"
  log "NVIDIA closure ready: ${CLOSURE_DIR} ($(du -sh "${CLOSURE_DIR}" | cut -f1), ${_rpm_count} RPMs)"
fi

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
# Source this file to run k0s_cluster_with_stack.sh directly against an already
# staged air-gap tree. It points every internet URL at that local tree.
# airgap_install.sh exports these itself, so this is only needed to resume a
# failed install without re-downloading.
#
# Usage:
#   AIRGAP_BUNDLE_DIR=/path/to/staged source /path/to/staged/airgap-env.sh
#   CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install

# Must point at the staged artifact directory (the --output-dir timestamped path).
: "${AIRGAP_BUNDLE_DIR:?AIRGAP_BUNDLE_DIR must be set to the bundle extraction path}"

# Without this the installer runs in ONLINE mode against a sealed cluster: it
# would try to reach HuggingFace and NVIDIA's repos and hang until they time out.
export AIRGAP_MODE="true"

# Suppress the installer's air-gap delegation: artifacts are already staged, so
# it must not hand back to airgap_install.sh and re-download everything.
export AIRGAP_STAGED="true"

export K0S_INSTALL_URL="file://${AIRGAP_BUNDLE_DIR}/binaries/k0s"
export YQ_DOWNLOAD_URL="file://${AIRGAP_BUNDLE_DIR}/binaries/yq"

export CERT_MANAGER_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/local-path-storage.yaml"
export NVIDIA_DEVICE_PLUGIN_MANIFEST_URL="file://${AIRGAP_BUNDLE_DIR}/manifests/nvidia-device-plugin.yml"

export PROMETHEUS_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/kube-prometheus-stack-$(cat "${AIRGAP_BUNDLE_DIR}/charts/kube-prometheus-stack.version").tgz"
export OTEL_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator-$(cat "${AIRGAP_BUNDLE_DIR}/charts/opentelemetry-operator.version").tgz"
export KUBERAY_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/kuberay-operator-${KUBERAY_CHART_VERSION:-1.2.2}.tgz"
export METALLB_CHART_PATH="${AIRGAP_BUNDLE_DIR}/charts/metallb-${METALLB_CHART_VERSION:-0.14.8}.tgz"

# Container-image tarballs. The installer scp's every *.tar here into
# /var/lib/k0s/images/ on each node, where k0s auto-imports them at startup.
# Omitting this leaves every infra pod in ImagePullBackOff on sealed nodes.
if compgen -G "${AIRGAP_BUNDLE_DIR}/images/*.tar" >/dev/null 2>&1; then
  export AIRGAP_K0S_IMAGE_DIR="${AIRGAP_BUNDLE_DIR}/images"
fi

# GPU node OS packages. The main installer scp's the closure directory to each
# GPU node itself (env vars do not cross the SSH boundary, so a path-based
# override alone would be useless to the node).
if [[ -d "${AIRGAP_BUNDLE_DIR}/packages/nvidia-closure" ]]; then
  export AIRGAP_NVIDIA_CLOSURE_DIR="${AIRGAP_BUNDLE_DIR}/packages/nvidia-closure"
fi

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
nvidia_closure_kernels=${GPU_KERNELS}
nvidia_driver_version=${NVIDIA_DRIVER_VERSION:-latest}
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

STAGE_SIZE="$(du -sh "${STAGE_DIR}" | cut -f1)"
log ""
log "=== Artifacts staged (${STAGE_SIZE}) ==="
log "  ${STAGE_DIR}"
log ""

# ── 10. Install the bundled k0s and yq into PATH ──────────────────────────────
# The installer shells out to both; on a sealed host they may not be present yet.
_install_binary() {
  local src="$1" dest="$2"
  [[ -f "${src}" ]] || return 0
  if [[ "$(id -u)" -eq 0 ]]; then
    cp "${src}" "${dest}" && chmod +x "${dest}"
  else
    sudo cp "${src}" "${dest}" && sudo chmod +x "${dest}"
  fi
  log "Installed $(basename "${dest}") to ${dest}"
}
_install_binary "${STAGE_DIR}/binaries/k0s" /usr/local/bin/k0s
command -v yq >/dev/null 2>&1 || _install_binary "${STAGE_DIR}/binaries/yq" /usr/local/bin/yq

# ── 11. Export the overrides the installer reads ──────────────────────────────
# Every URL points at a local file, so the installer downloads nothing.
export AIRGAP_MODE="true"
export AIRGAP_BUNDLE_DIR="${STAGE_DIR}"
export K0S_INSTALL_URL="file://${STAGE_DIR}/binaries/k0s"
export YQ_DOWNLOAD_URL="file://${STAGE_DIR}/binaries/yq"
export CERT_MANAGER_MANIFEST_URL="file://${STAGE_DIR}/manifests/cert-manager.yaml"
export LOCAL_PATH_MANIFEST_URL="file://${STAGE_DIR}/manifests/local-path-storage.yaml"
export NVIDIA_DEVICE_PLUGIN_MANIFEST_URL="file://${STAGE_DIR}/manifests/nvidia-device-plugin.yml"

_resolve_chart() {
  local pattern="$1" label="$2"
  # shellcheck disable=SC2206
  local matches=( ${pattern} )
  [[ ${#matches[@]} -gt 0 && -f "${matches[0]}" ]] \
    || err "Chart not found for ${label} (expected ${pattern}) — staging is incomplete."
  echo "${matches[0]}"
}
PROMETHEUS_CHART_PATH="$(_resolve_chart "${STAGE_DIR}/charts/kube-prometheus-stack-${PROMETHEUS_CHART_VERSION}*.tgz" kube-prometheus-stack)"
OTEL_CHART_PATH="$(_resolve_chart "${STAGE_DIR}/charts/opentelemetry-operator-${OTEL_CHART_VERSION}*.tgz" opentelemetry-operator)"
KUBERAY_CHART_PATH="$(_resolve_chart "${STAGE_DIR}/charts/kuberay-operator-${KUBERAY_CHART_VERSION}*.tgz" kuberay-operator)"
METALLB_CHART_PATH="$(_resolve_chart "${STAGE_DIR}/charts/metallb-${METALLB_CHART_VERSION}*.tgz" metallb)"
export PROMETHEUS_CHART_PATH OTEL_CHART_PATH KUBERAY_CHART_PATH METALLB_CHART_PATH

# Image tarballs: the installer scp's every *.tar here into /var/lib/k0s/images/
# on each node, where k0s auto-imports them into containerd at startup.
if compgen -G "${STAGE_DIR}/images/*.tar" >/dev/null 2>&1; then
  export AIRGAP_K0S_IMAGE_DIR="${STAGE_DIR}/images"
  for _t in "${STAGE_DIR}/images"/*.tar; do
    log "Image bundle: $(basename "${_t}") ($(du -h "${_t}" | cut -f1))"
  done
else
  warn "No image tarballs staged — infra pods may fail to pull on sealed nodes."
fi

# NVIDIA driver closure: the installer scp's this to each GPU node and installs
# with --disablerepo='*', so the node never reaches NVIDIA's servers.
if [[ -f "${CLOSURE_DIR}/repodata/repomd.xml" || -f "${CLOSURE_DIR}/Packages.gz" ]]; then
  export AIRGAP_NVIDIA_CLOSURE_DIR="${CLOSURE_DIR}"
  _cl_fmt="$(cat "${CLOSURE_DIR}/.pkg-format" 2>/dev/null || echo rpm)"
  log "NVIDIA closure (${_cl_fmt}): $(find "${CLOSURE_DIR}" -name "*.${_cl_fmt}" | wc -l | tr -d ' ') packages for kernels $(cat "${CLOSURE_DIR}/.target-kernels" 2>/dev/null || echo unknown)"
elif [[ "${SKIP_NVIDIA_CLOSURE}" == "true" ]]; then
  warn "No NVIDIA closure (--skip-nvidia-closure) — GPU nodes must already have"
  warn "  the driver and nvidia-container-toolkit installed."
fi

if [[ -n "${PYYAML_FILENAME:-}" && -f "${STAGE_DIR}/packages/${PYYAML_FILENAME}" ]]; then
  export AIRGAP_PYYAML_WHEEL_PATH="${STAGE_DIR}/packages/${PYYAML_FILENAME}"
fi

# ── 12. Run the installer ─────────────────────────────────────────────────────
if [[ "${DOWNLOAD_ONLY}" == "true" ]]; then
  log "=== --download-only: stopping before install ==="
  log ""
  log "Artifacts are staged at: ${STAGE_DIR}"
  log ""
  log "Before installing, mirror the container images listed in"
  log "  ${STAGE_DIR}/container-images.txt"
  log "to your internal registry and set images.registry in your config."
  log ""
  log "To install later:"
  log "  export AIRGAP_BUNDLE_DIR=${STAGE_DIR}"
  log "  source \"\${AIRGAP_BUNDLE_DIR}/airgap-env.sh\""
  log "  CONFIG_FILE=<your-config.yaml> ${INSTALLER_SCRIPT} install"
  exit 0
fi

log "=== Running installer: ${SUBCOMMAND} ==="
log "  Config    : ${CONFIG_FILE}"
log "  Installer : ${INSTALLER_SCRIPT}"
log ""

# AIRGAP_STAGED tells the installer that staging already happened, so its own
# air-gap delegation branch stands down instead of calling back here forever.
export AIRGAP_STAGED="true"

if CONFIG_FILE="${CONFIG_FILE}" "${INSTALLER_SCRIPT}" "${SUBCOMMAND}"; then
  log ""
  log "=== Air-gapped install complete ==="
  if [[ "${KEEP_STAGING}" == "true" ]]; then
    log "Staged artifacts kept at: ${STAGE_DIR} (${STAGE_SIZE})"
  else
    log "Removing staged artifacts (${STAGE_SIZE}) — pass --keep-staging to retain them."
    rm -rf "${STAGE_DIR}"
  fi
else
  _rc=$?
  warn ""
  warn "Installer exited with status ${_rc}."
  warn "Staged artifacts kept for retry at: ${STAGE_DIR}"
  warn "Re-run without re-downloading:"
  warn "  export AIRGAP_BUNDLE_DIR=${STAGE_DIR}"
  warn "  source \"\${AIRGAP_BUNDLE_DIR}/airgap-env.sh\""
  warn "  CONFIG_FILE=${CONFIG_FILE} ${INSTALLER_SCRIPT} ${SUBCOMMAND}"
  exit "${_rc}"
fi
