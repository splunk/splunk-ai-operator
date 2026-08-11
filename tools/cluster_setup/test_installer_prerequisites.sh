#!/usr/bin/env bash
# Focused unit tests for lib/installer_prereqs.sh.
#
# Every test runs in a subshell and replaces the library's external-operation
# wrappers. The suite must never access the network, a package manager, sudo,
# or the host's real toolchain state.
# shellcheck disable=SC1090,SC1091,SC2016,SC2030,SC2031,SC2034,SC2329
# Dynamic sourcing, injected globals, and indirectly called mock functions are
# intentional parts of this harness.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib/installer_prereqs.sh"
MAIN_SCRIPT="${SCRIPT_DIR}/k0s_cluster_with_stack.sh"
AWS_PROVISIONER="${SCRIPT_DIR}/k0s_aws_provision.sh"

PASS=0
FAIL=0
VERBOSE=0

if [[ "${1:-}" == "-v" ]]; then
  VERBOSE=1
fi

fail() {
  echo "       $*" >&2
  return 1
}

assert_eq() {
  local expected="$1" actual="$2"
  [[ "${expected}" == "${actual}" ]] ||
    fail "expected $(printf '%q' "${expected}"), got $(printf '%q' "${actual}")"
}

assert_empty_file() {
  local path="$1"
  [[ ! -s "${path}" ]] || fail "expected no external calls, got: $(tr '\n' ' ' < "${path}")"
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "${haystack}" == *"${needle}"* ]] ||
    fail "expected $(printf '%q' "${haystack}") to contain $(printf '%q' "${needle}")"
}

assert_function() {
  declare -F "$1" >/dev/null || fail "required function '$1' is not defined"
}

source_library() {
  [[ -r "${LIB}" ]] || fail "library not found: ${LIB}"
  # shellcheck source=lib/installer_prereqs.sh
  source "${LIB}"
}

run_test() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    [[ "${VERBOSE}" == "1" ]] && echo "  PASS ${name}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL ${name}"
  fi
}

test_public_api() (
  source_library || return

  local fn
  for fn in \
    prereq_detect_platform \
    prereq_collect_missing_tools \
    prereq_tool_is_compatible \
    prereq_check_profile \
    prereq_install_profile \
    prereq_ensure_profile \
    prereq_install_native_packages \
    prereq_install_debian_packages \
    prereq_install_rhel_packages \
    prereq_install_macos_packages \
    prereq_install_verified_binary \
    prereq_command_exists \
    prereq_command_path \
    prereq_exec \
    prereq_run_as_root \
    prereq_download \
    prereq_verify_checksum \
    prereq_effective_uid \
    prereq_uname_os \
    prereq_uname_arch; do
    assert_function "${fn}" || return
  done
)

test_source_is_inert() (
  local test_dir calls
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  calls="${test_dir}/calls"
  : > "${calls}"

  curl()    { echo curl >> "${calls}"; }
  sudo()    { echo sudo >> "${calls}"; }
  apt-get() { echo apt-get >> "${calls}"; }
  dnf()     { echo dnf >> "${calls}"; }
  yum()     { echo yum >> "${calls}"; }
  brew()    { echo brew >> "${calls}"; }

  source_library || return
  assert_empty_file "${calls}"
)

test_platform_detection() (
  local raw_os="$1" distro="$2" available_command="$3"
  local expected_os="$4" expected_family="$5" expected_manager="$6"
  local raw_arch="${7:-x86_64}" expected_arch="${8:-amd64}"
  local test_dir release_file
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  release_file="${test_dir}/os-release"
  printf 'ID=%s\n' "${distro}" > "${release_file}"

  source_library || return
  PREREQ_OS_OVERRIDE="${raw_os}"
  PREREQ_ARCH_OVERRIDE="${raw_arch}"
  PREREQ_OS_RELEASE_FILE="${release_file}"
  prereq_command_exists() { [[ "$1" == "${available_command}" ]]; }

  prereq_detect_platform || return
  assert_eq \
    "${expected_os}|${expected_family}|${expected_manager}|${expected_arch}" \
    "${PREREQ_OS}|${PREREQ_OS_FAMILY}|${PREREQ_PACKAGE_MANAGER}|${PREREQ_ARCH}"
)

test_os_dispatch() (
  local family="$1" expected="$2" test_dir calls
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  calls="${test_dir}/calls"
  : > "${calls}"

  source_library || return
  PREREQ_OS_FAMILY="${family}"
  PREREQ_ARCH="amd64"
  prereq_detect_platform() { :; }
  prereq_install_debian_packages() { printf 'debian:%s\n' "$*" >> "${calls}"; }
  prereq_install_rhel_packages()   { printf 'rhel:%s\n' "$*" >> "${calls}"; }
  prereq_install_macos_packages()  { printf 'macos:%s\n' "$*" >> "${calls}"; }

  prereq_install_native_packages ca-certificates curl || return
  assert_eq "${expected}:ca-certificates curl" "$(< "${calls}")"
)

test_debian_package_mapping() (
  local test_dir calls
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  calls="${test_dir}/calls"
  : > "${calls}"

  source_library || return
  PREREQ_APT_UPDATED="false"
  prereq_run_as_root() { printf '%s\n' "$*" >> "${calls}"; }

  prereq_install_debian_packages curl ssh scp git tar timeout || return
  assert_eq \
    $'env DEBIAN_FRONTEND=noninteractive apt-get update\nenv DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl openssh-client git tar coreutils' \
    "$(< "${calls}")"
)

test_rhel_package_mapping() (
  local test_dir calls
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  calls="${test_dir}/calls"
  : > "${calls}"

  source_library || return
  PREREQ_PACKAGE_MANAGER="dnf"
  prereq_run_as_root() { printf '%s\n' "$*" >> "${calls}"; }

  prereq_install_rhel_packages curl ssh scp git tar timeout || return
  assert_eq \
    'dnf install -y ca-certificates curl openssh-clients git tar coreutils' \
    "$(< "${calls}")"
)

test_macos_package_mapping() (
  local test_dir calls
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  calls="${test_dir}/calls"
  : > "${calls}"

  source_library || return
  PREREQ_PACKAGE_MANAGER="brew"
  prereq_exec() { printf '%s\n' "$*" >> "${calls}"; }
  prereq_command_exists() { [[ "$1" == "brew" ]]; }

  prereq_install_macos_packages curl ssh git timeout || return
  assert_eq 'brew install curl openssh git coreutils' "$(< "${calls}")"
)

test_unsupported_os_dispatch() (
  local test_dir calls rc=0
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  calls="${test_dir}/calls"
  : > "${calls}"

  source_library || return
  PREREQ_OS_FAMILY="solaris"
  PREREQ_ARCH="amd64"
  prereq_detect_platform() { :; }
  prereq_install_debian_packages() { echo debian >> "${calls}"; }
  prereq_install_rhel_packages()   { echo rhel >> "${calls}"; }
  prereq_install_macos_packages()  { echo macos >> "${calls}"; }

  prereq_install_native_packages curl >/dev/null 2>&1 || rc=$?
  assert_eq "${PREREQ_RC_UNSUPPORTED}" "${rc}" || return
  assert_empty_file "${calls}"
)

test_profile_check_is_non_mutating() (
  local test_dir mutations
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  mutations="${test_dir}/mutations"
  : > "${mutations}"

  source_library || return
  prereq_log() { :; }
  prereq_tool_is_compatible() { return 0; }
  prereq_exec() { echo "exec:$*" >> "${mutations}"; return 1; }
  prereq_run_as_root() { echo "root:$*" >> "${mutations}"; return 1; }
  prereq_download() { echo "download:$*" >> "${mutations}"; return 1; }

  prereq_check_profile cluster >/dev/null || return
  assert_empty_file "${mutations}"
)

test_profile_check_reports_missing_without_mutation() (
  local test_dir mutations rc=0
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  mutations="${test_dir}/mutations"
  : > "${mutations}"

  source_library || return
  prereq_tool_is_compatible() { [[ "$1" != "yq" ]]; }
  prereq_exec() { echo "exec:$*" >> "${mutations}"; return 1; }
  prereq_run_as_root() { echo "root:$*" >> "${mutations}"; return 1; }
  prereq_download() { echo "download:$*" >> "${mutations}"; return 1; }

  prereq_check_profile bootstrap >/dev/null 2>&1 || rc=$?
  assert_eq "${PREREQ_RC_MISSING}" "${rc}" || return
  assert_empty_file "${mutations}"
)

test_install_then_recheck_is_idempotent() (
  local test_dir installs present=0
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  installs="${test_dir}/installs"
  : > "${installs}"

  source_library || return
  prereq_command_exists() {
    [[ "$1" != "yq" || "${present}" == "1" ]]
  }
  prereq_tool_is_compatible() {
    [[ "$1" != "yq" || "${present}" == "1" ]]
  }
  prereq_install_verified_binary() {
    [[ "$1" == "yq" ]] || return 1
    echo "$1" >> "${installs}"
    present=1
  }
  prereq_install_native_packages() {
    fail "native package installation was not expected for: $*"
  }
  prereq_owned_tool_is_compatible() { return 1; }
  prereq_activate_local_tools() { :; }

  prereq_ensure_profile bootstrap noninteractive >/dev/null 2>&1 || return
  prereq_ensure_profile bootstrap noninteractive >/dev/null 2>&1 || return
  assert_eq "yq" "$(< "${installs}")"
)

test_noninteractive_root_uses_sudo_n() (
  local test_dir calls
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  calls="${test_dir}/calls"
  : > "${calls}"

  source_library || return
  prereq_command_exists() { [[ "$1" == "sudo" ]]; }
  prereq_effective_uid() { echo 1000; }
  prereq_exec() {
    printf '<%s>' "$@" >> "${calls}"
  }

  PREREQ_NONINTERACTIVE="true"
  prereq_run_as_root apt-get install -y curl || return
  assert_contains "$(< "${calls}")" '<sudo><-n>'
)

test_noninteractive_root_without_sudo_fails() (
  local test_dir calls rc=0
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  calls="${test_dir}/calls"
  : > "${calls}"

  source_library || return
  prereq_command_exists() { return 1; }
  prereq_effective_uid() { echo 1000; }
  prereq_exec() { echo "$*" >> "${calls}"; }

  PREREQ_NONINTERACTIVE="true"
  prereq_run_as_root apt-get install -y curl >/dev/null 2>&1 || rc=$?
  assert_eq "${PREREQ_RC_PRIVILEGE}" "${rc}" || return
  assert_empty_file "${calls}"
)

test_authorized_sudo_package_failure_is_not_privilege_error() (
  local rc=0
  source_library || return
  PREREQ_APT_UPDATED="false"
  prereq_effective_uid() { echo 1000; }
  prereq_command_exists() { [[ "$1" == "sudo" ]]; }
  prereq_exec() {
    [[ "$1" == "sudo" && "$2" == "-n" && "$3" == "true" ]] && return 0
    return 42
  }

  PREREQ_NONINTERACTIVE="true"
  prereq_install_debian_packages curl >/dev/null 2>&1 || rc=$?
  assert_eq "${PREREQ_RC_PACKAGE}" "${rc}" || return
  assert_eq "apt-get update failed" "${PREREQ_LAST_ERROR}"
)

test_unsupported_arch_fails_before_mutation() (
  local test_dir mutations rc=0
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  mutations="${test_dir}/mutations"
  : > "${mutations}"

  source_library || return
  prereq_uname_os() { echo Darwin; }
  prereq_uname_arch() { echo ppc64; }
  prereq_exec() { echo "exec:$*" >> "${mutations}"; }
  prereq_run_as_root() { echo "root:$*" >> "${mutations}"; }
  prereq_download() { echo "download:$*" >> "${mutations}"; }

  prereq_detect_platform >/dev/null 2>&1 || rc=$?
  assert_eq "${PREREQ_RC_UNSUPPORTED}" "${rc}" || return
  assert_empty_file "${mutations}"
)

test_checksum_failure_leaves_no_binary() (
  local test_dir install_dir download_path_file rc=0 downloaded_path
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  install_dir="${test_dir}/bin"
  download_path_file="${test_dir}/download-path"
  mkdir -p "${install_dir}"

  source_library || return
  PREREQ_OS_FAMILY="debian"
  PREREQ_OS="linux"
  PREREQ_ARCH="amd64"
  PREREQ_INSTALL_DIR="${install_dir}"
  prereq_download() {
    local destination="${2}"
    echo "${destination}" > "${download_path_file}"
    printf 'tampered payload' > "${destination}"
  }
  prereq_verify_checksum() { return 1; }
  prereq_run_as_root() { fail "checksum failure must occur before privileged installation"; }

  prereq_install_verified_binary yq >/dev/null 2>&1 || rc=$?
  assert_eq "${PREREQ_RC_CHECKSUM}" "${rc}" || return
  [[ -r "${download_path_file}" ]] || {
    fail "download wrapper was not called"
    return
  }
  downloaded_path="$(< "${download_path_file}")"
  [[ ! -e "${downloaded_path}" ]] || {
    fail "unverified temporary payload was not removed"
    return
  }
  [[ ! -e "${install_dir}/yq" ]] || fail "unverified yq was installed"
)

test_version_failure_removes_installed_binary() (
  local test_dir install_dir rc=0
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  install_dir="${test_dir}/bin"

  source_library || return
  PREREQ_OS="linux"
  PREREQ_OS_FAMILY="debian"
  PREREQ_ARCH="amd64"
  PREREQ_INSTALL_DIR="${install_dir}"
  prereq_download() {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$2"
  }
  prereq_verify_checksum() { return 0; }

  prereq_install_verified_binary yq >/dev/null 2>&1 || rc=$?
  assert_eq "${PREREQ_RC_VERSION}" "${rc}" || return
  [[ ! -e "${install_dir}/yq" ]] || fail "failed yq binary was left installed"
)

test_darwin_jq_asset_mapping() (
  local test_dir install_dir url_file
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  install_dir="${test_dir}/bin"
  url_file="${test_dir}/url"

  source_library || return
  PREREQ_OS="darwin"
  PREREQ_OS_FAMILY="macos"
  PREREQ_ARCH="arm64"
  PREREQ_INSTALL_DIR="${install_dir}"
  prereq_log() { :; }
  prereq_download() {
    printf '%s' "$1" > "${url_file}"
    printf '#!/bin/sh\nprintf "jq-1.8.2\\n"\n' > "$2"
  }
  prereq_verify_checksum() { return 0; }

  prereq_install_verified_binary jq || return
  assert_contains "$(< "${url_file}")" "/jq-1.8.2/jq-macos-arm64" || return
  [[ -x "${install_dir}/jq" ]] || fail "verified jq was not installed"
)

test_incompatible_present_binary_is_replaced() (
  local replaced=0
  source_library || return
  prereq_tool_is_compatible() {
    [[ "$1" != "yq" || "${replaced}" == "1" ]]
  }
  prereq_detect_platform() {
    PREREQ_OS="linux"
    PREREQ_OS_FAMILY="debian"
    PREREQ_ARCH="amd64"
    PREREQ_PACKAGE_MANAGER="apt-get"
  }
  prereq_install_native_packages() { fail "no native package was expected"; }
  prereq_install_verified_binary() {
    [[ "$1" == "yq" ]] || return 1
    replaced=1
  }
  prereq_owned_tool_is_compatible() { return 1; }
  prereq_activate_local_tools() { :; }

  prereq_ensure_profile bootstrap noninteractive >/dev/null 2>&1 || return
  assert_eq "1" "${replaced}"
)

test_versioned_tool_compatibility() (
  local test_dir fake_bin
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}"
  PATH="${fake_bin}:${PATH}"

  source_library || return
  printf '#!/bin/sh\nprintf "yq 3.4.1\\n"\n' > "${fake_bin}/yq"
  chmod +x "${fake_bin}/yq"
  ! prereq_tool_is_compatible yq || fail "yq v3 was accepted" || return
  printf '#!/bin/sh\nprintf "yq (https://github.com/mikefarah/yq/) version v4.53.3\\n"\n' > "${fake_bin}/yq"
  prereq_tool_is_compatible yq || fail "mikefarah yq v4 was rejected" || return

  printf '#!/bin/sh\nprintf "v4.0.0\\n"\n' > "${fake_bin}/helm"
  chmod +x "${fake_bin}/helm"
  ! prereq_tool_is_compatible helm || fail "Helm 4 was accepted" || return
  printf '#!/bin/sh\nprintf "v3.21.0\\n"\n' > "${fake_bin}/helm"
  prereq_tool_is_compatible helm || fail "Helm 3 was rejected"
)

test_pinned_kubectl_compatibility_window() (
  local test_dir fake_bin
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}"
  PATH="${fake_bin}:${PATH}"

  source_library || return
  printf '%s\n' \
    '#!/bin/sh' \
    'printf '\''clientVersion:\n  gitVersion: %s\n'\'' "${FAKE_KUBECTL_VERSION}"' \
    > "${fake_bin}/kubectl"
  chmod +x "${fake_bin}/kubectl"

  FAKE_KUBECTL_VERSION="v1.20.0"; export FAKE_KUBECTL_VERSION
  ! prereq_tool_is_compatible kubectl || fail "obsolete kubectl was accepted" || return
  FAKE_KUBECTL_VERSION="v1.35.9"; export FAKE_KUBECTL_VERSION
  prereq_tool_is_compatible kubectl || fail "kubectl within one minor of the pin was rejected" || return
  assert_eq "v1.36.1" "${PREREQ_KUBECTL_PINNED_VERSION}" || return
  PREREQ_OS="darwin"; PREREQ_ARCH="arm64"
  assert_eq \
    "9092778abaef3079449da4cd70ded0e4be112480c93efcdeace3155968d1d133" \
    "$(prereq_checksum_for KUBECTL)"
)

test_check_mode_preserves_path() (
  local before_path
  source_library || return
  before_path="${PATH}"
  PREREQ_INSTALL_DIR="/tmp/should-not-be-prepended"
  prereq_tool_is_compatible() { return 0; }

  prereq_check_profile cluster >/dev/null || return
  assert_eq "${before_path}" "${PATH}"
)

test_verified_local_binary_is_reused_across_process_path() (
  local test_dir install_dir runtime_dir calls original_path version_output
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  install_dir="${test_dir}/bin"
  runtime_dir="${install_dir}/.splunk-ai-prereq-bin"
  calls="${test_dir}/downloads"
  mkdir -p "${install_dir}"
  : > "${calls}"
  printf '#!/bin/sh\nprintf "yq (https://github.com/mikefarah/yq/) version v4.53.3\\n"\n' > "${install_dir}/yq"
  chmod +x "${install_dir}/yq"

  source_library || return
  PREREQ_INSTALL_DIR="${install_dir}"
  original_path="${PATH}"
  PATH="/usr/bin:/bin"
  prereq_command_exists() {
    # GitHub runners may provide /usr/bin/yq. This case intentionally treats
    # only the managed runtime link as present so activation is deterministic.
    case "$1" in
      curl) return 0 ;;
      yq)
        [[ "$(command -v yq 2>/dev/null || true)" == "${runtime_dir}/yq" ]]
        ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  prereq_download() { echo "$*" >> "${calls}"; return 1; }

  prereq_ensure_profile bootstrap noninteractive >/dev/null 2>&1 || return
  assert_empty_file "${calls}" || return
  [[ "${PATH%%:*}" == "${runtime_dir}" ]] \
    || fail "verified prerequisite runtime directory was not activated" || return
  [[ -L "${runtime_dir}/yq" && "$(readlink "${runtime_dir}/yq")" == "${install_dir}/yq" ]] \
    || fail "verified off-PATH yq runtime link was not created" || return
  version_output="$(yq --version)" || fail "activated yq could not be executed" || return
  assert_contains "${version_output}" "version v4.53.3" || return
  PATH="${original_path}"
)

test_runtime_activation_preserves_bootstrap_tool() (
  local test_dir install_dir runtime_dir
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  install_dir="${test_dir}/bin"
  runtime_dir="${install_dir}/.splunk-ai-prereq-bin"
  mkdir -p "${install_dir}"
  printf '#!/bin/sh\nprintf "yq (https://github.com/mikefarah/yq/) version v4.53.3\\n"\n' > "${install_dir}/yq"
  printf '#!/bin/sh\nprintf "jq-1.8.2\\n"\n' > "${install_dir}/jq"
  chmod +x "${install_dir}/yq" "${install_dir}/jq"

  source_library || return
  PREREQ_INSTALL_DIR="${install_dir}"
  prereq_activate_local_tools yq || return
  prereq_activate_local_tools jq || return

  [[ -L "${runtime_dir}/yq" ]] || fail "cluster activation removed bootstrap yq" || return
  [[ -L "${runtime_dir}/jq" ]] || fail "cluster jq was not activated"
)

test_bootstrap_then_cluster_preserves_runtime_tools() (
  local test_dir install_dir runtime_dir
  test_dir="$(mktemp -d)" || return
  trap 'rm -rf "${test_dir}"' EXIT
  install_dir="${test_dir}/bin"
  runtime_dir="${install_dir}/.splunk-ai-prereq-bin"

  source_library || return
  PREREQ_INSTALL_DIR="${install_dir}"
  prereq_profile_tools() {
    case "$1" in
      bootstrap) PREREQ_PROFILE_TOOLS=(yq) ;;
      cluster) PREREQ_PROFILE_TOOLS=(yq jq) ;;
      *) return 20 ;;
    esac
  }
  prereq_command_exists() {
    local found=""
    case "$1" in
      yq|jq)
        found="$(command -v "$1" 2>/dev/null || true)"
        [[ "${found}" == "${runtime_dir}/$1" ]]
        ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  prereq_detect_platform() {
    PREREQ_OS="linux"
    PREREQ_OS_FAMILY="debian"
    PREREQ_ARCH="amd64"
    PREREQ_PACKAGE_MANAGER="apt-get"
  }
  prereq_install_verified_binary() {
    mkdir -p "${install_dir}"
    case "$1" in
      yq) printf '#!/bin/sh\nprintf "yq (https://github.com/mikefarah/yq/) version v4.53.3\\n"\n' > "${install_dir}/yq" ;;
      jq) printf '#!/bin/sh\nprintf "jq-1.8.2\\n"\n' > "${install_dir}/jq" ;;
      *) return 1 ;;
    esac
    chmod +x "${install_dir}/$1"
  }

  prereq_ensure_profile bootstrap noninteractive >/dev/null 2>&1 || return
  prereq_ensure_profile cluster noninteractive >/dev/null 2>&1 || return
  [[ -L "${runtime_dir}/yq" ]] || fail "cluster ensure removed bootstrap yq" || return
  [[ -L "${runtime_dir}/jq" ]] || fail "cluster ensure did not activate jq"
)

test_main_integration_contract() (
  local bootstrap_line delegation_line show_line cluster_line preflight_line
  bootstrap_line="$(grep -n '^  ensure_installer_prerequisites bootstrap$' "${MAIN_SCRIPT}" | cut -d: -f1)"
  delegation_line="$(grep -n '^# ====== AIR-GAP DELEGATION ======$' "${MAIN_SCRIPT}" | cut -d: -f1)"
  show_line="$(grep -n '^  show_install_plan$' "${MAIN_SCRIPT}" | cut -d: -f1)"
  cluster_line="$(grep -n '^  ensure_installer_prerequisites cluster$' "${MAIN_SCRIPT}" | cut -d: -f1)"
  preflight_line="$(grep -n '^  phase_start "Preflight"$' "${MAIN_SCRIPT}" | cut -d: -f1)"

  [[ -n "${bootstrap_line}" && -n "${delegation_line}" && bootstrap_line -lt delegation_line ]] \
    || fail "bootstrap prerequisite ensure must precede air-gap delegation" || return
  [[ -n "${show_line}" && -n "${cluster_line}" && -n "${preflight_line}" \
     && show_line -lt cluster_line && cluster_line -lt preflight_line ]] \
    || fail "cluster ensure must remain between install confirmation and preflight" || return
  # Literal source-code contract; expansion here would defeat the assertion.
  # shellcheck disable=SC2016
  grep -Fq 'INSTALL_PREREQS="${INSTALL_PREREQS:-true}"' "${MAIN_SCRIPT}" \
    || fail "automatic prerequisite installation is not the install default" || return
  grep -q -- '--no-install-prereqs' "${MAIN_SCRIPT}" \
    || fail "install opt-out flag is not wired" || return
  grep -q 'prerequisites.lock' "${AWS_PROVISIONER}" \
    || fail "AWS provisioner does not copy the prerequisite lock" || return
  grep -q 'lib/installer_prereqs.sh' "${AWS_PROVISIONER}" \
    || fail "AWS provisioner does not copy the prerequisite module" || return
  grep -q 'prereq_ensure_profile cluster noninteractive' "${AWS_PROVISIONER}" \
    || fail "AWS provisioner does not invoke the shared prerequisite module" || return
  ! grep -q 'stable.txt\|get-helm-3' "${AWS_PROVISIONER}" \
    || fail "AWS provisioner still contains a floating prerequisite installer"
)

echo "Prerequisite installer unit tests"
run_test "library exports its documented API and mock seams" test_public_api
run_test "sourcing the library has no external side effects" test_source_is_inert
run_test "Ubuntu detection selects apt" test_platform_detection Linux ubuntu apt-get linux debian apt-get
run_test "Rocky Linux detection selects dnf" test_platform_detection Linux rocky dnf linux rhel dnf
run_test "Amazon Linux ARM detection falls back to yum" test_platform_detection Linux amzn yum linux rhel yum aarch64 arm64
run_test "macOS detection selects Homebrew" test_platform_detection Darwin ignored brew darwin macos brew
run_test "Debian package dispatch" test_os_dispatch debian debian
run_test "RHEL package dispatch" test_os_dispatch rhel rhel
run_test "macOS package dispatch" test_os_dispatch macos macos
run_test "Debian installer maps canonical tools to apt packages once" test_debian_package_mapping
run_test "RHEL installer maps canonical tools to dnf packages once" test_rhel_package_mapping
run_test "macOS installer maps canonical tools to Homebrew packages" test_macos_package_mapping
run_test "unsupported OS fails before package mutation" test_unsupported_os_dispatch
run_test "check mode is a no-op when every tool is present" test_profile_check_is_non_mutating
run_test "check mode reports a missing tool without mutation" test_profile_check_reports_missing_without_mutation
run_test "ensure performs check-install-recheck once and is then idempotent" test_install_then_recheck_is_idempotent
run_test "noninteractive privileged commands use sudo -n" test_noninteractive_root_uses_sudo_n
run_test "noninteractive privileged commands fail when sudo is unavailable" test_noninteractive_root_without_sudo_fails
run_test "authorized sudo package failures report package errors" test_authorized_sudo_package_failure_is_not_privilege_error
run_test "unsupported architecture fails before mutation" test_unsupported_arch_fails_before_mutation
run_test "checksum failure removes the temporary payload and installs nothing" test_checksum_failure_leaves_no_binary
run_test "post-install version failure removes the invalid binary" test_version_failure_removes_installed_binary
run_test "macOS jq uses the upstream macos asset name" test_darwin_jq_asset_mapping
run_test "an incompatible present binary is replaced" test_incompatible_present_binary_is_replaced
run_test "versioned tool compatibility rejects yq v3 and Helm 4" test_versioned_tool_compatibility
run_test "kubectl compatibility follows the pinned minor and locked checksum" test_pinned_kubectl_compatibility_window
run_test "check mode does not change PATH precedence" test_check_mode_preserves_path
run_test "verified user-local tools are reused when a new process PATH omits them" test_verified_local_binary_is_reused_across_process_path
run_test "cluster activation preserves the bootstrap yq link" test_runtime_activation_preserves_bootstrap_tool
run_test "bootstrap then cluster ensure preserves all verified runtime tools" test_bootstrap_then_cluster_preserves_runtime_tools
run_test "main install preserves prerequisite ordering and packaging" test_main_integration_contract

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
