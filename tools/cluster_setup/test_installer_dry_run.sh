#!/usr/bin/env bash
# Dry-run test for Splunk-optional installer modes.
#
# Tests the splunk_config_yaml block generation that install_ai_platform_cr()
# emits into the AIPlatform CR, for all 5 Splunk mode combinations.
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
  local hec="${2:-}"
  local standalone="${3:-splunk-standalone}"

  [[ -n "${hec}" ]] && export SPLUNK_HEC_TOKEN="${hec}"

  # Derive SPLUNK_MODE the same way load_config() does
  local SPLUNK_ENABLED SPLUNK_EXTERNAL_ENDPOINT SPLUNK_EXTERNAL_SECRET_NAME SPLUNK_MODE AI_NS
  SPLUNK_ENABLED="$(yq eval '.splunk.enabled' "${cfg}" 2>/dev/null || echo "false")"
  SPLUNK_EXTERNAL_ENDPOINT="$(yq eval '.splunk.external.endpoint // ""' "${cfg}" 2>/dev/null || echo "")"
  [[ "${SPLUNK_EXTERNAL_ENDPOINT}" == "null" ]] && SPLUNK_EXTERNAL_ENDPOINT=""
  SPLUNK_EXTERNAL_SECRET_NAME="$(yq eval '.splunk.external.secretName // "splunk-hec-external"' "${cfg}" 2>/dev/null || echo "splunk-hec-external")"
  AI_NS="$(yq eval '.kubernetes.namespace // "ai-platform"' "${cfg}" 2>/dev/null || echo "ai-platform")"
  AI_STANDALONE_NAME="${standalone}"

  if [[ "${SPLUNK_ENABLED}" != "true" ]]; then
    SPLUNK_MODE="disabled"
  elif [[ -n "${SPLUNK_EXTERNAL_ENDPOINT}" ]]; then
    SPLUNK_MODE="external"
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
      local splunk_secret="splunk-${AI_STANDALONE_NAME}-standalone-secret-v1"
      splunk_config_yaml=$(cat <<EOF

  # Splunk configuration (internal — in-cluster Standalone)
  splunkConfiguration:
    endpoint: http://splunk-${AI_STANDALONE_NAME}-standalone-service.${AI_NS}.svc.cluster.local:8089
    # Fresh Splunk Operator installs report enableSSL=0. The production
    # installer reads btool after readiness rather than assuming this scheme.
    hecEndpoint: http://splunk-${AI_STANDALONE_NAME}-standalone-service.${AI_NS}.svc.cluster.local:8088
    secretRef:
      name: ${splunk_secret}
      namespace: ${AI_NS}
${trusted_issuers_yaml}
EOF
)
      ;;
    external)
      splunk_config_yaml=$(cat <<EOF

  # Splunk configuration (external — customer-managed Splunk)
  splunkConfiguration:
    endpoint: ${SPLUNK_EXTERNAL_ENDPOINT}
    secretRef:
      name: ${SPLUNK_EXTERNAL_SECRET_NAME}
      namespace: ${AI_NS}
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

  echo "${splunk_config_yaml}"
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
OUT=$(render_splunk_block "${CFG}" "" "my-standalone")
EXPECTED_INTERNAL_URL="http://splunk-my-standalone-standalone-service.ai-platform.svc.cluster.local:8089"
EXPECTED_INTERNAL_HEC_URL="http://splunk-my-standalone-standalone-service.ai-platform.svc.cluster.local:8088"
info "SPLUNK_MODE=internal → in-cluster management/JWKS endpoint + secretRef"
check_contains     "${OUT}" "splunkConfiguration"                              "splunkConfiguration block present"
check_contains     "${OUT}" "endpoint: ${EXPECTED_INTERNAL_URL}"               "Canonical HTTP management/JWKS endpoint"
check_contains     "${OUT}" "hecEndpoint: ${EXPECTED_INTERNAL_HEC_URL}"         "Distinct OTel-only HEC endpoint"
check_contains     "${OUT}" "splunk-my-standalone-standalone-secret-v1"        "Operator-managed secret"
check_contains     "${OUT}" "secretRef"                                        "secretRef present"
check_not_contains "${OUT}" "trustedIssuers"                                   "No trustedIssuers when not set"
rm -f "${CFG}"

# ═════════════════════════════════════════════════════════════════════════════
echo -e "\n${BOLD}Case 4: INTERNAL + trustedIssuers (dual-Splunk)${RESET}"
CFG=$(make_config "splunk:
  enabled: true
  trustedIssuers:
    - https://external.splunk:8089")
OUT=$(render_splunk_block "${CFG}" "" "my-standalone")
info "SPLUNK_MODE=internal → in-cluster management/JWKS endpoint + external issuer appended"
check_contains "${OUT}" "splunkConfiguration"                "splunkConfiguration block present"
check_contains "${OUT}" "endpoint: ${EXPECTED_INTERNAL_URL}" "Canonical HTTP management/JWKS endpoint"
check_contains "${OUT}" "hecEndpoint: ${EXPECTED_INTERNAL_HEC_URL}" "Distinct OTel-only HEC endpoint"
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
OUT=$(render_splunk_block "${CFG}" "dummy-hec-token")
info "SPLUNK_MODE=external → external HEC endpoint, no in-cluster Splunk"
check_contains     "${OUT}" "splunkConfiguration"                         "splunkConfiguration block present"
check_contains     "${OUT}" "endpoint: https://splunk.example.com:8088"   "External HEC endpoint"
check_contains     "${OUT}" "splunk-hec-external"                         "External secret name"
check_contains     "${OUT}" "trustedIssuers"                              "trustedIssuers key present"
check_contains     "${OUT}" "https://splunk.example.com:8089"             "Issuer present"
check_not_contains "${OUT}" "standalone-service"                          "No in-cluster endpoint"
rm -f "${CFG}"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
if [[ "${FAILURES}" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All dry-run checks passed (5 cases).${RESET}"
else
  echo -e "${RED}${BOLD}${FAILURES} check(s) failed.${RESET}"
  exit 1
fi
