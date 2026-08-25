#!/usr/bin/env bash
# Dry-run test for Splunk-optional installer modes.
#
# Tests the splunk_config_yaml block generation that install_ai_platform_cr()
# emits into the AIPlatform CR, including unsupported-feature fences.
# No cluster, no kubectl, no artifacts files needed.
#
# Usage: bash test_installer_dry_run.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
pass()  { echo -e "  ${GREEN}✓${RESET} $*"; }
fail()  { echo -e "  ${RED}✗${RESET} $*"; FAILURES=$((FAILURES+1)); }
info()  { echo -e "  ${YELLOW}→${RESET} $*"; }
FAILURES=0

check_contains()     { echo "${OUT}" | grep -qF "$2" && pass "$3" || fail "$3 (missing: '$2')"; }
check_not_contains() { echo "${OUT}" | grep -qF "$2" && fail "$3 (unexpected: '$2')" || pass "$3"; }

# ── Inline the exact splunk_config_yaml logic from install_ai_platform_cr() ──
# This is the code under test; taken verbatim from k0s_cluster_with_stack.sh.
# We exercise it by setting the same variables the installer would set.
render_splunk_block() {
  local cfg="$1"
  local standalone="${2:-splunk-standalone}"

  # Derive SPLUNK_MODE the same way load_config() does
  local SPLUNK_ENABLED SPLUNK_EXTERNAL_ENDPOINT SPLUNK_MODE
  SPLUNK_ENABLED="$(yq eval '.splunk.enabled' "${cfg}" 2>/dev/null || echo "false")"
  SPLUNK_EXTERNAL_ENDPOINT="$(yq eval '.splunk.external.endpoint // ""' "${cfg}" 2>/dev/null || echo "")"
  [[ "${SPLUNK_EXTERNAL_ENDPOINT}" == "null" ]] && SPLUNK_EXTERNAL_ENDPOINT=""
  AI_STANDALONE_NAME="${standalone}"

  if [[ -n "${SPLUNK_EXTERNAL_ENDPOINT}" ]]; then
    echo "splunk.external.endpoint configures external HEC integration, which is not supported in this release" >&2
    return 1
  fi

  if [[ "${SPLUNK_ENABLED}" != "true" ]]; then
    SPLUNK_MODE="disabled"
  else
    SPLUNK_MODE="internal"
  fi

  # Build trustedIssuers YAML fragment — verbatim from install_ai_platform_cr()
  local trusted_issuers_yaml=""
  local trusted_issuers_count
  trusted_issuers_count=$(yq eval '.splunk.trustedIssuers | length' "${cfg}" 2>/dev/null || echo "0")
  if [[ "${trusted_issuers_count}" -gt 0 ]]; then
    trusted_issuers_yaml="    trustedIssuers:"$'\n'
    local _ti=0
    while [[ $_ti -lt $trusted_issuers_count ]]; do
      local _url
      _url=$(yq eval ".splunk.trustedIssuers[$_ti]" "${cfg}" 2>/dev/null || echo "")
      [[ -n "${_url}" && "${_url}" != "null" ]] && trusted_issuers_yaml+="      - \"${_url}\""$'\n'
      _ti=$((_ti + 1))
    done
  fi

  # Build splunk_config_yaml — verbatim from install_ai_platform_cr()
  local splunk_config_yaml=""
  case "${SPLUNK_MODE}" in
    internal)
      splunk_config_yaml=$(cat <<EOF

  # Splunk configuration (internal — in-cluster Standalone)
  splunkConfiguration:
    endpoint: https://splunk-${AI_STANDALONE_NAME}-standalone-service:8089
${trusted_issuers_yaml}
EOF
)
      ;;
    *)
      if [[ -n "${trusted_issuers_yaml}" ]]; then
        splunk_config_yaml=$(cat <<EOF

  # Splunk configuration (disabled — trustedIssuers only for JWT validation)
  splunkConfiguration:
${trusted_issuers_yaml}
EOF
)
      fi
      ;;
  esac

  cat <<EOF
  sidecars:
    otel: false
  mtls:
    enabled: false
${splunk_config_yaml}
EOF
}

# ── Config writer ─────────────────────────────────────────────────────────────
make_config() {
  local splunk_block="$1"
  local f; f=$(mktemp /tmp/dry-run.XXXXXX)
  cat > "${f}" <<YAML
kubernetes:
  namespace: ai-platform
${splunk_block}
YAML
  echo "${f}"
}

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Case 1: DISABLED — splunk.enabled: false, no trustedIssuers${RESET}"
CFG=$(make_config "splunk:
  enabled: false
  standaloneName: splunk-standalone")
OUT=$(render_splunk_block "${CFG}")
info "SPLUNK_MODE=disabled → splunkConfiguration block must be absent"
check_not_contains "${OUT}" "splunkConfiguration" "No splunkConfiguration block"
check_not_contains "${OUT}" "endpoint:"           "No Splunk endpoint"
check_contains     "${OUT}" "otel: false"          "Workload OTel explicitly disabled"
check_contains     "${OUT}" "enabled: false"       "mTLS explicitly disabled"
rm -f "${CFG}"

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Case 2: DISABLED + trustedIssuers${RESET}"
CFG=$(make_config "splunk:
  enabled: false
  trustedIssuers:
    - https://43.203.164.228:8089
    - https://splunk.example.com:8089")
OUT=$(render_splunk_block "${CFG}")
info "SPLUNK_MODE=disabled → splunkConfiguration with trustedIssuers only"
check_contains     "${OUT}" "splunkConfiguration"              "splunkConfiguration block present"
check_contains     "${OUT}" "trustedIssuers"                   "trustedIssuers key present"
check_contains     "${OUT}" "https://43.203.164.228:8089"      "First issuer"
check_contains     "${OUT}" "https://splunk.example.com:8089"  "Second issuer"
check_not_contains "${OUT}" "endpoint:"                        "No Splunk endpoint"
rm -f "${CFG}"

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Case 3: INTERNAL — splunk.enabled: true, no external.endpoint${RESET}"
CFG=$(make_config "splunk:
  enabled: true")
OUT=$(render_splunk_block "${CFG}" "my-standalone")
EXPECTED_INTERNAL_URL="https://splunk-my-standalone-standalone-service:8089"
info "SPLUNK_MODE=internal → short native HTTPS JWT issuer only"
check_contains     "${OUT}" "splunkConfiguration"                              "splunkConfiguration block present"
check_contains     "${OUT}" "endpoint: ${EXPECTED_INTERNAL_URL}"               "Short native HTTPS issuer endpoint"
check_not_contains "${OUT}" "hecEndpoint"                                      "No HEC endpoint"
check_not_contains "${OUT}" "secretRef"                                        "No HEC secret reference"
check_not_contains "${OUT}" ":8088"                                            "No HEC port"
check_not_contains "${OUT}" "trustedIssuers"                                   "No trustedIssuers when not set"
rm -f "${CFG}"

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Case 4: INTERNAL + trustedIssuers (dual-Splunk)${RESET}"
CFG=$(make_config "splunk:
  enabled: true
  trustedIssuers:
    - https://external.splunk:8089")
OUT=$(render_splunk_block "${CFG}" "my-standalone")
info "SPLUNK_MODE=internal → native HTTPS issuer + external issuer appended"
check_contains "${OUT}" "splunkConfiguration"                "splunkConfiguration block present"
check_contains "${OUT}" "endpoint: ${EXPECTED_INTERNAL_URL}" "Short native HTTPS issuer endpoint"
check_not_contains "${OUT}" "hecEndpoint"                    "No HEC endpoint"
check_not_contains "${OUT}" "secretRef"                      "No HEC secret reference"
check_contains "${OUT}" "trustedIssuers"                     "trustedIssuers key present"
check_contains "${OUT}" "https://external.splunk:8089"       "External issuer present"
rm -f "${CFG}"

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Case 5: EXTERNAL — splunk.enabled: true + external.endpoint${RESET}"
CFG=$(make_config "splunk:
  enabled: true
  external:
    endpoint: https://splunk.example.com:8088
    secretName: splunk-hec-external
  trustedIssuers:
    - https://splunk.example.com:8089")
if OUT=$(render_splunk_block "${CFG}" 2>&1); then
  fail "External HEC configuration must be rejected"
else
  pass "External HEC configuration is rejected"
fi
check_contains "${OUT}" "not supported in this release" "Clear unsupported-feature error"
check_not_contains "${OUT}" "dummy-hec-token" "Error output does not expose token material"
rm -f "${CFG}"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
if [[ "${FAILURES}" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All dry-run checks passed (5 cases).${RESET}"
else
  echo -e "${RED}${BOLD}${FAILURES} check(s) failed.${RESET}"
  exit 1
fi
