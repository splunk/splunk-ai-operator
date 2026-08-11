#!/usr/bin/env bash
# OS-aware prerequisite management for k0s_cluster_with_stack.sh.
#
# This file is a source-only library. It intentionally performs no work when
# sourced, never changes the caller's shell options, and never exits the caller.
# Public functions return a stable status and set PREREQ_LAST_ERROR on failure.

PREREQ_RC_MISSING=10
PREREQ_RC_UNSUPPORTED=20
PREREQ_RC_PRIVILEGE=21
PREREQ_RC_PACKAGE=22
PREREQ_RC_DOWNLOAD=23
PREREQ_RC_CHECKSUM=24
PREREQ_RC_VERSION=25

PREREQ_OS=""
PREREQ_DISTRO=""
PREREQ_OS_FAMILY=""
PREREQ_ARCH=""
PREREQ_PACKAGE_MANAGER=""
PREREQ_LAST_ERROR=""
PREREQ_LOCK_LOADED="false"
PREREQ_APT_UPDATED="false"
PREREQ_RESOLVED_KUBECTL_VERSION=""
PREREQ_KUBECTL_PINNED_VERSION="${PREREQ_KUBECTL_PINNED_VERSION:-}"
PREREQ_HELM_VERSION="${PREREQ_HELM_VERSION:-}"
PREREQ_JQ_VERSION="${PREREQ_JQ_VERSION:-}"
PREREQ_YQ_VERSION="${PREREQ_YQ_VERSION:-}"
declare -a PREREQ_PROFILE_TOOLS=()
declare -a PREREQ_MISSING_TOOLS=()
declare -a PREREQ_LOCAL_TOOLS_TO_ACTIVATE=()

prereq_log() {
  if declare -F log >/dev/null 2>&1; then
    log "Prerequisites: $*"
  else
    printf '[prerequisites] %s\n' "$*" >&2
  fi
}

prereq_warn() {
  if declare -F warn >/dev/null 2>&1; then
    warn "Prerequisites: $*"
  else
    printf '[prerequisites] WARNING: %s\n' "$*" >&2
  fi
}

prereq_fail() {
  PREREQ_LAST_ERROR="$1"
  return "${2:-1}"
}

# External-boundary wrappers. Tests override these instead of mocking internal
# orchestration. Commands are always passed as argument arrays; no eval is used.
prereq_command_exists() { command -v "$1" >/dev/null 2>&1; }
prereq_command_path() { command -v "$1"; }
prereq_exec() { "$@"; }
prereq_effective_uid() { id -u; }
prereq_uname_os() { uname -s; }
prereq_uname_arch() { uname -m; }

prereq_download() {
  local url="$1" destination="$2"
  if [[ "${url}" == file://* ]]; then
    prereq_exec cp -- "${url#file://}" "${destination}"
  else
    prereq_exec curl --fail --location --silent --show-error \
      --retry 3 --connect-timeout 15 --output "${destination}" "${url}"
  fi
}

prereq_verify_checksum() {
  local file="$1" expected="$2" actual=""
  [[ "${expected}" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  if prereq_command_exists sha256sum; then
    actual="$(sha256sum "${file}" | awk '{print $1}')"
  elif prereq_command_exists shasum; then
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  elif prereq_command_exists openssl; then
    actual="$(openssl dgst -sha256 "${file}" | awk '{print $NF}')"
  else
    return 1
  fi
  [[ "${actual,,}" == "${expected,,}" ]]
}

prereq_load_lock() {
  [[ "${PREREQ_LOCK_LOADED}" == "true" ]] && return 0

  local module_dir lock_file line key value
  module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  lock_file="${PREREQ_LOCK_FILE:-${module_dir}/../prerequisites.lock}"
  [[ -r "${lock_file}" ]] || prereq_fail \
    "version lock is missing or unreadable: ${lock_file}" "${PREREQ_RC_VERSION}" || return $?

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ ! "${line}" =~ ^(PREREQ_[A-Z0-9_]+)=\"([^\"]*)\"$ ]]; then
      prereq_fail "invalid entry in ${lock_file}: ${line}" "${PREREQ_RC_VERSION}"
      return $?
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    printf -v "${key}" '%s' "${value}"
  done < "${lock_file}"

  PREREQ_LOCK_LOADED="true"
}

prereq_activate_local_tools() {
  local install_dir="${PREREQ_INSTALL_DIR:-${XDG_BIN_HOME:-${HOME}/.local/bin}}"
  local runtime_dir="${PREREQ_RUNTIME_BIN_DIR:-${install_dir}/.splunk-ai-prereq-bin}"
  local tool target
  local -a managed_tools=(kubectl helm jq yq timeout)

  (( $# > 0 )) || return 0
  mkdir -p "${runtime_dir}" || {
    prereq_fail "cannot create prerequisite runtime directory: ${runtime_dir}" "${PREREQ_RC_PACKAGE}"
    return $?
  }
  chmod 0700 "${runtime_dir}" || return "${PREREQ_RC_PACKAGE}"

  # This module owns only symlinks in its dot-directory. Preserve verified
  # links from an earlier bootstrap phase, but remove stale links before this
  # directory is placed first in PATH.
  for tool in "${managed_tools[@]}"; do
    target="${runtime_dir}/${tool}"
    if [[ -e "${target}" && ! -L "${target}" ]]; then
      prereq_fail "refusing to replace non-symlink prerequisite runtime entry: ${target}" "${PREREQ_RC_PACKAGE}"
      return $?
    fi
    if [[ -L "${target}" ]] && ! prereq_owned_tool_is_compatible "${tool}"; then
      rm -f -- "${target}"
    fi
  done

  for tool in "$@"; do
    target="${install_dir}/${tool}"
    [[ -x "${target}" ]] || {
      prereq_fail "verified local prerequisite disappeared: ${target}" "${PREREQ_RC_VERSION}"
      return $?
    }
    rm -f -- "${runtime_dir}/${tool}"
    ln -s "${target}" "${runtime_dir}/${tool}" || return "${PREREQ_RC_PACKAGE}"
  done

  case ":${PATH}:" in
    *":${runtime_dir}:"*) ;;
    *) export PATH="${runtime_dir}:${PATH}" ;;
  esac

  # A long-lived Bash process may have cached an earlier command location.
  # Clear that cache so subsequent tool invocations use the verified runtime
  # links that were just placed first in PATH.
  hash -r 2>/dev/null || true
}

prereq_read_linux_identity() {
  local release_file="${PREREQ_OS_RELEASE_FILE:-/etc/os-release}"
  local line key value id="" id_like=""
  [[ -r "${release_file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    case "${key}" in
      ID) id="${value}" ;;
      ID_LIKE) id_like="${value}" ;;
    esac
  done < "${release_file}"
  PREREQ_DISTRO="${PREREQ_DISTRO_OVERRIDE:-${id}}"
  printf '%s\n' "${PREREQ_DISTRO}|${id_like}"
}

prereq_detect_platform() {
  PREREQ_LAST_ERROR=""
  local raw_os raw_arch identity id_like
  raw_os="${PREREQ_OS_OVERRIDE:-$(prereq_uname_os)}"
  raw_arch="${PREREQ_ARCH_OVERRIDE:-$(prereq_uname_arch)}"

  case "${raw_arch}" in
    x86_64|amd64) PREREQ_ARCH="amd64" ;;
    arm64|aarch64) PREREQ_ARCH="arm64" ;;
    *) prereq_fail "unsupported installer architecture: ${raw_arch}" "${PREREQ_RC_UNSUPPORTED}"; return $? ;;
  esac

  case "${raw_os}" in
    Linux|linux)
      PREREQ_OS="linux"
      identity="$(prereq_read_linux_identity)" || {
        prereq_fail "cannot read installer OS identity from ${PREREQ_OS_RELEASE_FILE:-/etc/os-release}" "${PREREQ_RC_UNSUPPORTED}"
        return $?
      }
      PREREQ_DISTRO="${identity%%|*}"
      id_like="${identity#*|}"
      if [[ -n "${PREREQ_OS_FAMILY_OVERRIDE:-}" ]]; then
        PREREQ_OS_FAMILY="${PREREQ_OS_FAMILY_OVERRIDE}"
      else
        case "${PREREQ_DISTRO}" in
          ubuntu|debian) PREREQ_OS_FAMILY="debian" ;;
          rhel|centos|rocky|almalinux|fedora|amzn) PREREQ_OS_FAMILY="rhel" ;;
          *)
            if [[ " ${id_like} " == *" debian "* ]]; then
              PREREQ_OS_FAMILY="debian"
            elif [[ " ${id_like} " == *" rhel "* || " ${id_like} " == *" fedora "* ]]; then
              PREREQ_OS_FAMILY="rhel"
            else
              prereq_fail "unsupported installer Linux distribution: ${PREREQ_DISTRO:-unknown}" "${PREREQ_RC_UNSUPPORTED}"
              return $?
            fi
            ;;
        esac
      fi
      case "${PREREQ_OS_FAMILY}" in
        debian)
          prereq_command_exists apt-get || {
            prereq_fail "apt-get is required on ${PREREQ_DISTRO}" "${PREREQ_RC_UNSUPPORTED}"
            return $?
          }
          PREREQ_PACKAGE_MANAGER="apt-get"
          ;;
        rhel)
          if prereq_command_exists dnf; then
            PREREQ_PACKAGE_MANAGER="dnf"
          elif prereq_command_exists yum; then
            PREREQ_PACKAGE_MANAGER="yum"
          else
            prereq_fail "dnf or yum is required on ${PREREQ_DISTRO}" "${PREREQ_RC_UNSUPPORTED}"
            return $?
          fi
          ;;
        *) prereq_fail "unsupported installer OS family: ${PREREQ_OS_FAMILY}" "${PREREQ_RC_UNSUPPORTED}"; return $? ;;
      esac
      ;;
    Darwin|darwin|macos)
      PREREQ_OS="darwin"
      PREREQ_DISTRO="macos"
      PREREQ_OS_FAMILY="macos"
      if prereq_command_exists brew; then
        PREREQ_PACKAGE_MANAGER="brew"
      else
        PREREQ_PACKAGE_MANAGER="none"
      fi
      ;;
    *) prereq_fail "unsupported installer operating system: ${raw_os}" "${PREREQ_RC_UNSUPPORTED}"; return $? ;;
  esac
}

prereq_profile_tools() {
  local profile="$1"
  PREREQ_PROFILE_TOOLS=()
  case "${profile}" in
    bootstrap)
      PREREQ_PROFILE_TOOLS=(curl yq)
      ;;
    cluster)
      # git remains here because the existing preflight requires it. It can be
      # moved to a model-staging profile when that preflight becomes conditional.
      PREREQ_PROFILE_TOOLS=(ssh scp curl kubectl helm git jq yq tar timeout)
      ;;
    *) prereq_fail "unknown prerequisite profile: ${profile}" "${PREREQ_RC_UNSUPPORTED}"; return $? ;;
  esac
}

prereq_kubectl_client_version() {
  local binary="$1" output version
  output="$(prereq_exec "${binary}" version --client --output=yaml 2>/dev/null)" || return 1
  version="$(printf '%s\n' "${output}" | awk '$1 == "gitVersion:" {gsub(/"/, "", $2); print $2; exit}')"
  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-].*)?$ ]] || return 1
  printf '%s\n' "${version}"
}

prereq_tool_is_compatible() {
  local tool="$1" output="" actual_version="" required_version=""
  local actual_core required_core actual_major actual_minor required_major required_minor
  prereq_command_exists "${tool}" || return 1

  case "${tool}" in
    yq)
      output="$(prereq_exec yq --version 2>/dev/null)" || return 1
      [[ "${output}" == *mikefarah* && "${output}" =~ version[[:space:]]+v?4\. ]]
      ;;
    helm)
      output="$(prereq_exec helm version --short 2>/dev/null)" || return 1
      [[ "${output}" =~ ^v3\. ]]
      ;;
    jq)
      output="$(prereq_exec jq --version 2>/dev/null)" || return 1
      [[ "${output}" =~ ^jq-1\.([6-9]|[1-9][0-9])([.-]|$) ]]
      ;;
    kubectl)
      actual_version="$(prereq_kubectl_client_version kubectl)" || return 1
      prereq_resolve_kubectl_version || return $?
      required_version="${PREREQ_RESOLVED_KUBECTL_VERSION}"
      actual_core="${actual_version#v}"; actual_core="${actual_core%%[+-]*}"
      required_core="${required_version#v}"; required_core="${required_core%%[+-]*}"
      IFS=. read -r actual_major actual_minor _ <<< "${actual_core}"
      IFS=. read -r required_major required_minor _ <<< "${required_core}"
      [[ "${actual_major}" =~ ^[0-9]+$ && "${actual_minor}" =~ ^[0-9]+$ \
         && "${required_major}" =~ ^[0-9]+$ && "${required_minor}" =~ ^[0-9]+$ ]] || return 1
      (( actual_major == required_major \
         && actual_minor >= required_minor - 1 \
         && actual_minor <= required_minor + 1 ))
      ;;
    *)
      return 0
      ;;
  esac
}

prereq_collect_missing_tools() {
  local profile="$1" tool rc=0
  prereq_profile_tools "${profile}" || return $?
  PREREQ_MISSING_TOOLS=()
  for tool in "${PREREQ_PROFILE_TOOLS[@]}"; do
    rc=0
    prereq_tool_is_compatible "${tool}" || rc=$?
    if (( rc == 1 )); then
      PREREQ_MISSING_TOOLS+=("${tool}")
    elif (( rc != 0 )); then
      return "${rc}"
    fi
  done
}

prereq_check_profile() {
  local profile="${1:-cluster}"
  prereq_collect_missing_tools "${profile}" || return $?
  if (( ${#PREREQ_MISSING_TOOLS[@]} == 0 )); then
    prereq_log "${profile} profile is satisfied"
    return 0
  fi
  PREREQ_LAST_ERROR="missing or incompatible ${profile} tools: ${PREREQ_MISSING_TOOLS[*]}"
  prereq_warn "${PREREQ_LAST_ERROR}"
  return "${PREREQ_RC_MISSING}"
}

prereq_run_as_root() {
  if [[ "$(prereq_effective_uid)" == "0" ]]; then
    prereq_exec "$@"
    return $?
  fi
  prereq_command_exists sudo || {
    prereq_fail "sudo is required to install operating-system packages" "${PREREQ_RC_PRIVILEGE}"
    return $?
  }
  if [[ "${PREREQ_NONINTERACTIVE:-false}" == "true" ]]; then
    prereq_exec sudo -n true >/dev/null 2>&1 || {
      prereq_fail "passwordless sudo is required for non-interactive prerequisite installation" "${PREREQ_RC_PRIVILEGE}"
      return $?
    }
    prereq_exec sudo -n "$@"
  else
    prereq_exec sudo -v || {
      prereq_fail "sudo authorization failed while installing prerequisites" "${PREREQ_RC_PRIVILEGE}"
      return $?
    }
    prereq_exec sudo "$@"
  fi
}

prereq_append_unique() {
  local value="$1" existing
  shift
  for existing in "$@"; do
    [[ "${existing}" == "${value}" ]] && return 1
  done
  return 0
}

prereq_install_debian_packages() {
  local tool package rc=0
  local -a packages=()
  for tool in "$@"; do
    case "${tool}" in
      curl) package="curl"; prereq_append_unique ca-certificates "${packages[@]}" && packages+=(ca-certificates) ;;
      ssh|scp) package="openssh-client" ;;
      git) package="git" ;;
      tar) package="tar" ;;
      timeout) package="coreutils" ;;
      *) continue ;;
    esac
    prereq_append_unique "${package}" "${packages[@]}" && packages+=("${package}")
  done
  (( ${#packages[@]} > 0 )) || return 0
  if [[ "${PREREQ_APT_UPDATED}" != "true" ]]; then
    rc=0
    prereq_run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update || rc=$?
    if (( rc != 0 )); then
      (( rc == PREREQ_RC_PRIVILEGE )) && return "${rc}"
      PREREQ_LAST_ERROR="apt-get update failed"
      return "${PREREQ_RC_PACKAGE}"
    fi
    PREREQ_APT_UPDATED="true"
  fi
  rc=0
  prereq_run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" || rc=$?
  if (( rc != 0 )); then
    (( rc == PREREQ_RC_PRIVILEGE )) && return "${rc}"
    PREREQ_LAST_ERROR="apt-get could not install: ${packages[*]}"
    return "${PREREQ_RC_PACKAGE}"
  fi
}

prereq_install_rhel_packages() {
  local tool package rc=0
  local -a packages=()
  for tool in "$@"; do
    case "${tool}" in
      curl) package="curl"; prereq_append_unique ca-certificates "${packages[@]}" && packages+=(ca-certificates) ;;
      ssh|scp) package="openssh-clients" ;;
      git) package="git" ;;
      tar) package="tar" ;;
      timeout) package="coreutils" ;;
      *) continue ;;
    esac
    prereq_append_unique "${package}" "${packages[@]}" && packages+=("${package}")
  done
  (( ${#packages[@]} > 0 )) || return 0
  prereq_run_as_root "${PREREQ_PACKAGE_MANAGER}" install -y "${packages[@]}" || rc=$?
  if (( rc != 0 )); then
    (( rc == PREREQ_RC_PRIVILEGE )) && return "${rc}"
    PREREQ_LAST_ERROR="${PREREQ_PACKAGE_MANAGER} could not install: ${packages[*]}"
    return "${PREREQ_RC_PACKAGE}"
  fi
}

prereq_install_macos_packages() {
  local tool package install_dir gtimeout_path
  local -a packages=()
  for tool in "$@"; do
    case "${tool}" in
      curl) package="curl" ;;
      ssh|scp) package="openssh" ;;
      git) package="git" ;;
      timeout) package="coreutils" ;;
      tar) package="gnu-tar" ;;
      *) continue ;;
    esac
    prereq_append_unique "${package}" "${packages[@]}" && packages+=("${package}")
  done
  (( ${#packages[@]} > 0 )) || return 0
  [[ "${PREREQ_PACKAGE_MANAGER}" == "brew" ]] || {
    prereq_fail "Homebrew must already be installed to add missing macOS prerequisites: ${packages[*]}" "${PREREQ_RC_PACKAGE}"
    return $?
  }
  prereq_exec brew install "${packages[@]}" || {
    prereq_fail "Homebrew could not install: ${packages[*]}" "${PREREQ_RC_PACKAGE}"
    return $?
  }

  # Homebrew coreutils intentionally prefixes GNU timeout with 'g'. Provide a
  # run-local user shim without editing shell startup files.
  if ! prereq_command_exists timeout && prereq_command_exists gtimeout; then
    install_dir="${PREREQ_INSTALL_DIR:-${XDG_BIN_HOME:-${HOME}/.local/bin}}"
    mkdir -p "${install_dir}" || {
      prereq_fail "cannot create prerequisite install directory: ${install_dir}" "${PREREQ_RC_PACKAGE}"
      return $?
    }
    gtimeout_path="$(prereq_command_path gtimeout)" || {
      prereq_fail "Homebrew installed coreutils but gtimeout is not available in PATH" "${PREREQ_RC_VERSION}"
      return $?
    }
    prereq_exec ln -sf "${gtimeout_path}" "${install_dir}/timeout" || {
      prereq_fail "could not create the user-local timeout shim in ${install_dir}" "${PREREQ_RC_PACKAGE}"
      return $?
    }
    PREREQ_LOCAL_TOOLS_TO_ACTIVATE+=(timeout)
  fi
}

prereq_install_native_packages() {
  case "${PREREQ_OS_FAMILY}" in
    debian) prereq_install_debian_packages "$@" ;;
    rhel) prereq_install_rhel_packages "$@" ;;
    macos) prereq_install_macos_packages "$@" ;;
    *) prereq_fail "no native prerequisite installer for ${PREREQ_OS_FAMILY:-unknown}" "${PREREQ_RC_UNSUPPORTED}"; return $? ;;
  esac
}

prereq_checksum_for() {
  local tool="$1" key
  key="PREREQ_${tool^^}_${PREREQ_OS^^}_${PREREQ_ARCH^^}_SHA256"
  printf '%s' "${!key:-}"
}

prereq_resolve_kubectl_version() {
  PREREQ_RESOLVED_KUBECTL_VERSION=""
  prereq_load_lock || return $?
  if [[ -n "${PREREQ_KUBECTL_VERSION:-}" ]]; then
    PREREQ_RESOLVED_KUBECTL_VERSION="${PREREQ_KUBECTL_VERSION}"
  elif [[ "${K0S_VERSION:-}" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)\+k0s ]]; then
    PREREQ_RESOLVED_KUBECTL_VERSION="v${BASH_REMATCH[1]}"
  else
    PREREQ_RESOLVED_KUBECTL_VERSION="${PREREQ_KUBECTL_PINNED_VERSION}"
  fi
  [[ "${PREREQ_RESOLVED_KUBECTL_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    prereq_fail "invalid kubectl version: ${PREREQ_RESOLVED_KUBECTL_VERSION:-empty}" "${PREREQ_RC_VERSION}"
    return $?
  }
}

prereq_install_atomic() {
  local source="$1" tool="$2"
  local install_dir="${PREREQ_INSTALL_DIR:-${XDG_BIN_HOME:-${HOME}/.local/bin}}"
  local destination="${install_dir}/${tool}" staged="${install_dir}/.${tool}.prereq.$$"
  mkdir -p "${install_dir}" || {
    prereq_fail "cannot create prerequisite install directory: ${install_dir}" "${PREREQ_RC_PACKAGE}"
    return $?
  }
  if cp -- "${source}" "${staged}" \
      && chmod 0755 "${staged}" \
      && mv -f -- "${staged}" "${destination}"; then
    return 0
  fi
  rm -f -- "${staged}"
  prereq_fail "could not install ${tool} into ${install_dir}" "${PREREQ_RC_PACKAGE}"
  return $?
}

prereq_verify_installed_binary() {
  local tool="$1" path="$2" output="" actual_version=""
  [[ -x "${path}" ]] || return 1
  case "${tool}" in
    kubectl)
      actual_version="$(prereq_kubectl_client_version "${path}")" || return 1
      [[ "${actual_version}" == "${PREREQ_RESOLVED_KUBECTL_VERSION}" ]]
      ;;
    helm)
      output="$("${path}" version --short 2>/dev/null)" || return 1
      [[ "${output}" == "${PREREQ_HELM_VERSION}"* ]]
      ;;
    jq)
      output="$("${path}" --version 2>/dev/null)" || return 1
      [[ "${output}" == "jq-${PREREQ_JQ_VERSION}" ]]
      ;;
    yq)
      output="$("${path}" --version 2>/dev/null)" || return 1
      [[ "${output}" == *mikefarah* && "${output}" == *"version ${PREREQ_YQ_VERSION}"* ]]
      ;;
    *) return 1 ;;
  esac
}

prereq_owned_tool_is_compatible() {
  local tool="$1"
  local install_dir="${PREREQ_INSTALL_DIR:-${XDG_BIN_HOME:-${HOME}/.local/bin}}"
  local path="${install_dir}/${tool}" output=""
  [[ -x "${path}" ]] || return 1

  case "${tool}" in
    kubectl)
      prereq_resolve_kubectl_version || return $?
      prereq_verify_installed_binary "${tool}" "${path}"
      ;;
    helm|jq|yq)
      prereq_load_lock || return $?
      prereq_verify_installed_binary "${tool}" "${path}"
      ;;
    timeout)
      output="$("${path}" --version 2>/dev/null)" || return 1
      [[ "${output}" == *"GNU coreutils"* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

prereq_install_verified_binary() {
  local tool="$1" url="" expected="" asset_name="" archive="false"
  local version="" tmp_dir="" payload="" source_binary="" install_dir="" old_umask="" install_rc=0 asset_os=""
  prereq_load_lock || return $?

  case "${tool}" in
    kubectl)
      prereq_resolve_kubectl_version || return $?
      version="${PREREQ_RESOLVED_KUBECTL_VERSION}"
      asset_name="kubectl"
      url="${PREREQ_KUBECTL_URL:-https://dl.k8s.io/release/${version}/bin/${PREREQ_OS}/${PREREQ_ARCH}/kubectl}"
      if [[ -n "${PREREQ_KUBECTL_SHA256:-}" ]]; then
        expected="${PREREQ_KUBECTL_SHA256}"
      elif [[ "${version}" == "${PREREQ_KUBECTL_PINNED_VERSION}" ]]; then
        expected="$(prereq_checksum_for KUBECTL)"
      fi
      ;;
    helm)
      version="${PREREQ_HELM_VERSION}"
      asset_name="helm-${version}-${PREREQ_OS}-${PREREQ_ARCH}.tar.gz"
      url="${PREREQ_HELM_URL:-https://get.helm.sh/${asset_name}}"
      expected="${PREREQ_HELM_SHA256:-$(prereq_checksum_for HELM)}"
      archive="true"
      ;;
    jq)
      version="${PREREQ_JQ_VERSION}"
      asset_os="${PREREQ_OS}"
      [[ "${asset_os}" == "darwin" ]] && asset_os="macos"
      asset_name="jq-${asset_os}-${PREREQ_ARCH}"
      url="${PREREQ_JQ_URL:-https://github.com/jqlang/jq/releases/download/jq-${version}/${asset_name}}"
      expected="${PREREQ_JQ_SHA256:-$(prereq_checksum_for JQ)}"
      ;;
    yq)
      version="${PREREQ_YQ_VERSION}"
      asset_name="yq_${PREREQ_OS}_${PREREQ_ARCH}"
      url="${PREREQ_YQ_URL:-${YQ_DOWNLOAD_URL:-https://github.com/mikefarah/yq/releases/download/${version}/${asset_name}}}"
      expected="${PREREQ_YQ_SHA256:-${YQ_DOWNLOAD_SHA256:-$(prereq_checksum_for YQ)}}"
      ;;
    *) prereq_fail "no verified binary installer for ${tool}" "${PREREQ_RC_UNSUPPORTED}"; return $? ;;
  esac

  [[ -n "${expected}" ]] || {
    prereq_fail "no SHA-256 is recorded for ${tool} on ${PREREQ_OS}/${PREREQ_ARCH}" "${PREREQ_RC_CHECKSUM}"
    return $?
  }

  old_umask="$(umask)"
  umask 077
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/splunk-prereq-${tool}.XXXXXX")" || {
    umask "${old_umask}"
    prereq_fail "could not create a temporary directory for ${tool}" "${PREREQ_RC_DOWNLOAD}"
    return $?
  }
  umask "${old_umask}"
  payload="${tmp_dir}/${asset_name}"
  if ! prereq_download "${url}" "${payload}"; then
    rm -rf -- "${tmp_dir}"
    prereq_fail "download failed for ${tool} ${version}" "${PREREQ_RC_DOWNLOAD}"
    return $?
  fi

  if ! prereq_verify_checksum "${payload}" "${expected}"; then
    rm -rf -- "${tmp_dir}"
    prereq_fail "SHA-256 verification failed for ${tool} ${version}" "${PREREQ_RC_CHECKSUM}"
    return $?
  fi

  if [[ "${archive}" == "true" ]]; then
    if ! tar -xzf "${payload}" -C "${tmp_dir}"; then
      rm -rf -- "${tmp_dir}"
      prereq_fail "could not extract ${asset_name}" "${PREREQ_RC_PACKAGE}"
      return $?
    fi
    source_binary="${tmp_dir}/${PREREQ_OS}-${PREREQ_ARCH}/helm"
  else
    source_binary="${payload}"
  fi

  prereq_install_atomic "${source_binary}" "${tool}" || install_rc=$?
  if (( install_rc != 0 )); then
    rm -rf -- "${tmp_dir}"
    return "${install_rc}"
  fi
  rm -rf -- "${tmp_dir}"

  install_dir="${PREREQ_INSTALL_DIR:-${XDG_BIN_HOME:-${HOME}/.local/bin}}"
  if ! prereq_verify_installed_binary "${tool}" "${install_dir}/${tool}"; then
    rm -f -- "${install_dir}/${tool}"
    prereq_fail "${tool} was installed but failed its version check" "${PREREQ_RC_VERSION}"
    return $?
  fi
  prereq_log "installed ${tool} ${version} in ${install_dir}"
}

prereq_install_profile() {
  local profile="${1:-cluster}" interaction="${2:-interactive}" tool rc=0
  local -a native_tools=() binary_tools=()
  PREREQ_NONINTERACTIVE="false"
  [[ "${interaction}" == "noninteractive" ]] && PREREQ_NONINTERACTIVE="true"

  prereq_collect_missing_tools "${profile}" || return $?
  (( ${#PREREQ_MISSING_TOOLS[@]} > 0 )) || return 0
  prereq_detect_platform || return $?
  PREREQ_LOCAL_TOOLS_TO_ACTIVATE=()

  for tool in "${PREREQ_MISSING_TOOLS[@]}"; do
    case "${tool}" in
      kubectl|helm|jq|yq) binary_tools+=("${tool}") ;;
      *) native_tools+=("${tool}") ;;
    esac
  done

  if (( ${#native_tools[@]} > 0 )); then
    prereq_log "installing native packages for: ${native_tools[*]}"
    prereq_install_native_packages "${native_tools[@]}" || return $?
  fi

  # Direct binary downloads require curl. Recheck it after the native package
  # phase so a missing downloader is bootstrapped before any URL is accessed.
  if (( ${#binary_tools[@]} > 0 )) && ! prereq_command_exists curl; then
    prereq_fail "curl is still unavailable after native package installation" "${PREREQ_RC_PACKAGE}"
    return $?
  fi

  for tool in "${binary_tools[@]}"; do
    rc=0
    prereq_owned_tool_is_compatible "${tool}" || rc=$?
    if (( rc == 0 )); then
      prereq_log "reusing verified ${tool} from ${PREREQ_INSTALL_DIR:-${XDG_BIN_HOME:-${HOME}/.local/bin}}"
    elif (( rc == 1 )); then
      prereq_install_verified_binary "${tool}" || return $?
    else
      return "${rc}"
    fi
    PREREQ_LOCAL_TOOLS_TO_ACTIVATE+=("${tool}")
  done

  # Check mode is PATH-inert. Install mode exposes only the exact verified
  # binaries selected above, never unrelated or stale files in ~/.local/bin.
  if (( ${#PREREQ_LOCAL_TOOLS_TO_ACTIVATE[@]} > 0 )); then
    prereq_activate_local_tools "${PREREQ_LOCAL_TOOLS_TO_ACTIVATE[@]}" || return $?
  fi

  rc=0
  prereq_check_profile "${profile}" || rc=$?
  if (( rc != 0 )); then
    prereq_fail "prerequisite installation finished but tools are still missing: ${PREREQ_MISSING_TOOLS[*]}" "${PREREQ_RC_VERSION}"
    return $?
  fi
}

prereq_ensure_profile() {
  local profile="${1:-cluster}" interaction="${2:-interactive}" rc=0
  prereq_check_profile "${profile}" || rc=$?
  (( rc == 0 )) && return 0
  (( rc == PREREQ_RC_MISSING )) || return "${rc}"

  prereq_log "attempting to install missing ${profile} prerequisites"
  prereq_install_profile "${profile}" "${interaction}" || return $?

  rc=0
  prereq_check_profile "${profile}" || rc=$?
  (( rc == 0 )) || {
    prereq_fail "${profile} prerequisite recheck failed: ${PREREQ_MISSING_TOOLS[*]}" "${PREREQ_RC_VERSION}"
    return $?
  }
}
