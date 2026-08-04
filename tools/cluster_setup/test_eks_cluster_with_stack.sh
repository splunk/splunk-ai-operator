#!/usr/bin/env bash
# Static assertions for EKS installer AIP-4614 Splunk TLS cert wiring.
# No EKS cluster, aws/kubectl credentials, or network access is required —
# these are grep/awk checks against the installer source, mirroring
# test_openshift_with_stack.sh's provision_splunk_cert / caCertRef suites.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/eks_cluster_with_stack.sh"

PASS=0
FAIL=0

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: ${description}"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ${description}"
    echo "        expected: $(printf '%q' "${expected}")"
    echo "        actual:   $(printf '%q' "${actual}")"
  fi
}

bash -n "${SCRIPT}"
assert_eq "script passes bash -n syntax check" "0" "$?"

# ── Tests: SPLUNK_MODE derivation ─────────────────────────────────────────────
echo
echo "EKS SPLUNK_MODE derivation"

assert_eq "derives SPLUNK_MODE=disabled when splunk.enabled != true" \
  "1" "$(grep -c 'SPLUNK_MODE="disabled"' "${SCRIPT}")"

assert_eq "derives SPLUNK_MODE=external when external endpoint is set" \
  "1" "$(grep -c 'SPLUNK_MODE="external"' "${SCRIPT}")"

assert_eq "derives SPLUNK_MODE=internal otherwise" \
  "1" "$(grep -c 'SPLUNK_MODE="internal"' "${SCRIPT}")"

assert_eq "config parser reads splunk.enabled via yq" \
  "1" "$(grep -c "yq eval '\.splunk\.enabled'" "${SCRIPT}")"

assert_eq "config parser reads splunk.external.endpoint via yq" \
  "1" "$(grep -c 'yq eval .\.splunk\.external\.endpoint' "${SCRIPT}")"

# ── Tests: AIP-4614 Splunk TLS cert provisioning (provision_splunk_cert) ──────
echo
echo "EKS provision_splunk_cert"

_PSC_BODY() { awk '/^provision_splunk_cert\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }

assert_eq "gated on SPLUNK_MODE != internal (early return)" \
  "1" "$(_PSC_BODY | grep -A2 'SPLUNK_MODE.*!= .internal.' | grep -c 'return 0')"

assert_eq "waits for cert-manager webhook before applying the chain" \
  "1" "$(_PSC_BODY | grep -c 'wait_for_cert_manager_webhook')"

assert_eq "derives the Standalone service name from AI_STANDALONE_NAME (operator's GetSplunkServiceName)" \
  "1" "$(_PSC_BODY | grep -c 'svc="splunk-\${AI_STANDALONE_NAME}-standalone-service"')"

assert_eq "derives the headless service name from AI_STANDALONE_NAME" \
  "1" "$(_PSC_BODY | grep -c 'headless="splunk-\${AI_STANDALONE_NAME}-standalone-headless"')"

assert_eq "selfSigned root Issuer is defined and referenced by the CA cert's issuerRef" \
  "2" "$(_PSC_BODY | grep -c 'name: ai-splunk-selfsigned')"

assert_eq "CA Certificate is isCA and stored in ai-splunk-ca-tls" \
  "1" "$(awk '/name: ai-splunk-ca$/{f=1} f && /secretName: ai-splunk-ca-tls/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-ca-tls')"

assert_eq "CA Issuer chains off the ai-splunk-ca-tls secret" \
  "1" "$(awk '/name: ai-splunk-ca-issuer/{f=1} f && /secretName: ai-splunk-ca-tls/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-ca-tls')"

assert_eq "leaf Certificate ai-splunk-server writes to ai-splunk-server-tls" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /secretName: ai-splunk-server-tls/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-server-tls')"

assert_eq "leaf cert issued by the CA issuer (not the selfsigned root)" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /issuerRef:/{g=1} f && g && /name: ai-splunk-ca-issuer/{print; exit}' "${SCRIPT}" | grep -c 'ai-splunk-ca-issuer')"

assert_eq "leaf cert SANs cover both the standalone service and headless service (short/ns/svc/cluster.local forms)" \
  "8" "$(awk '/name: ai-splunk-server$/{f=1} f && /^---/{exit} f' "${SCRIPT}" | grep -cE '\$\{svc\}|\$\{headless\}')"

assert_eq "leaf cert requests a CombinedPEM output (splunkd needs cert+key in one file)" \
  "1" "$(awk '/name: ai-splunk-server$/{f=1} f && /^---/{exit} f' "${SCRIPT}" | grep -c 'type: CombinedPEM')"

assert_eq "waits for the leaf cert to reach Ready before returning" \
  "1" "$(_PSC_BODY | grep -c -e 'kubectl wait --for=condition=Ready certificate/ai-splunk-server')"

assert_eq "install_splunk_operator is gated on SPLUNK_MODE == internal" \
  "1" "$(awk '/^install_splunk_operator\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -A2 'SPLUNK_MODE.*!= .internal.' | grep -c 'return 0')"

assert_eq "install_splunk_standalone is gated on SPLUNK_MODE == internal" \
  "1" "$(awk '/^install_splunk_standalone\(\)/{f=1} f && /^}/{exit} f' "${SCRIPT}" | grep -A2 'SPLUNK_MODE.*!= .internal.' | grep -c 'return 0')"

assert_eq "orchestrator provisions the cert before the Standalone CR is applied (cert must exist first)" \
  "1" "$(awk '/provision_splunk_cert$/{p=NR} /install_splunk_standalone$/{s=NR} END{print(p > 0 && s > 0 && p < s)}' "${SCRIPT}")"

# provision_splunk_cert is called from inside install_ai_platform_stack, not
# directly from reconcile_flow, so the ordering check has to compare
# reconcile_flow's own call sites (install_cert_manager vs
# install_ai_platform_stack) rather than raw line numbers of the two leaf
# function names.
_RECONCILE_FLOW_BODY() { awk '/^reconcile_flow\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }
assert_eq "orchestrator runs cert-manager install before the AI platform stack (which provisions the Splunk cert)" \
  "1" "$(_RECONCILE_FLOW_BODY | awk '/^  install_cert_manager$/{c=NR} /^  install_ai_platform_stack$/{p=NR} END{print(c > 0 && p > 0 && c < p)}')"

# ── Tests: Standalone CR wiring (splunk-certs volume + default.yml stanzas) ──
echo
echo "EKS Splunk Standalone cert wiring"

_STANDALONE_BODY() { awk '/^install_splunk_standalone\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }

# The Standalone CR is applied twice (external-objstore branch and the
# default S3 branch), so the volume/cert lines appear twice — once per branch.
assert_eq "splunk-certs volume mounts the ai-splunk-server-tls secret (both Standalone CR branches)" \
  "2" "$(_STANDALONE_BODY | grep -A2 'name: splunk-certs' | grep -c 'secretName: ai-splunk-server-tls')"

assert_eq "default.yml [server]/[web] stanzas point serverCert at the mounted cert" \
  "2" "$(_STANDALONE_BODY | grep -c 'serverCert: /mnt/splunk-certs/tls-combined.pem')"

assert_eq "default.yml [server] stanza sets sslRootCAPath to the mounted CA" \
  "1" "$(_STANDALONE_BODY | grep -c 'sslRootCAPath: /mnt/splunk-certs/ca.crt')"

assert_eq "default.yml [web] stanza enables Splunk Web SSL with the mounted cert" \
  "1" "$(_STANDALONE_BODY | grep -c 'enableSplunkWebSSL: true')"

assert_eq "default.yml oauth2_settings issuer_uri is interpolated from AI_STANDALONE_NAME/AI_NS (not hardcoded)" \
  "1" "$(_STANDALONE_BODY | grep -c 'issuer_uri: https://splunk-\${AI_STANDALONE_NAME}-standalone-service.\${AI_NS}.svc.cluster.local:8089')"

# ── Tests: caCertRef wiring into the AIPlatform CR (internal mode) ───────────
echo
echo "EKS caCertRef wiring (install_ai_platform_cr, internal mode)"

_AIPC_BODY() { awk '/^install_ai_platform_cr\(\)/{f=1} f{print} f && /^}/{exit}' "${SCRIPT}"; }

assert_eq "internal-mode splunkConfiguration includes a caCertRef" \
  "1" "$(_AIPC_BODY | awk '/^ *internal\)$/{f=1} f && /;;/{exit} f' | grep -c 'caCertRef:')"

assert_eq "caCertRef points at the cert provisioned by provision_splunk_cert (ai-splunk-server-tls)" \
  "1" "$(_AIPC_BODY | awk '/^ *internal\)$/{f=1} f && /;;/{exit} f' | grep -c 'name: ai-splunk-server-tls')"

assert_eq "caCertRef key matches the leaf Certificate's default CA output key (ca.crt)" \
  "1" "$(_AIPC_BODY | awk '/^ *internal\)$/{f=1} f && /;;/{exit} f' | grep -c 'key: ca.crt')"

assert_eq "internal-mode endpoint uses the management port (8089), matching the ConfigMap's issuer_uri" \
  "1" "$(_AIPC_BODY | awk '/^ *internal\)$/{f=1} f && /;;/{exit} f' | grep -c 'standalone-service.\${AI_NS}.svc.cluster.local:8089')"

assert_eq "disabled mode does not set caCertRef (no Splunk to trust at all)" \
  "0" "$(_AIPC_BODY | awk '/^ *\*\)$/{f=1} /;;/{f=0} f' | grep -c 'caCertRef:')"

# ── Tests: caCertRef wiring into the AIPlatform CR (external mode) ──────────
echo
echo "EKS caCertRef wiring (install_ai_platform_cr, external mode)"

_AIPC_EXTERNAL_BODY() { _AIPC_BODY | awk '/^ *external\)$/{f=1} f && /;;/{exit} f'; }

assert_eq "config parser reads splunk.external.caCertSecretName via yq" \
  "1" "$(grep -c 'yq eval .\.splunk\.external\.caCertSecretName' "${SCRIPT}")"

assert_eq "external-mode caCertRef emission is gated on SPLUNK_EXTERNAL_CA_SECRET_NAME being set" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'if \[\[ -n \"\${SPLUNK_EXTERNAL_CA_SECRET_NAME}\" \]\]')"

assert_eq "external-mode caCertRef uses the customer-supplied secret name (not a hardcoded one)" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'name: \${SPLUNK_EXTERNAL_CA_SECRET_NAME}')"

assert_eq "external-mode caCertRef key matches the documented convention (ca.crt)" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'key: ca.crt')"

assert_eq "external-mode caCertRef fragment is interpolated into splunk_config_yaml (not dropped)" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'external_ca_cert_yaml}\${trusted_issuers_yaml}')"

assert_eq "external-mode HEC token requires SPLUNK_HEC_TOKEN env var (never the config file)" \
  "1" "$(_AIPC_EXTERNAL_BODY | grep -c 'Splunk external mode requires the HEC token')"

# ── Tests: repository EKS config is valid YAML with the splunk: block ───────
echo
echo "EKS repository config"

REAL_YQ=$(command -v yq 2>/dev/null || true)
if [[ -n "${REAL_YQ}" ]]; then
  assert_eq "repository EKS config is valid YAML" "0" \
    "$("${REAL_YQ}" eval '.' "${SCRIPT_DIR}/cluster-config.yaml" >/dev/null 2>&1; echo $?)"
  assert_eq "repository EKS config's splunk.enabled defaults to false" "false" \
    "$("${REAL_YQ}" eval '.splunk.enabled' "${SCRIPT_DIR}/cluster-config.yaml" 2>/dev/null)"
else
  echo "  SKIP: yq not installed; YAML parse checks skipped"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
((FAIL == 0))
