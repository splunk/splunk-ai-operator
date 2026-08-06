#!/usr/bin/env bash
# Focused tests for installer ownership of fixed-name internal Splunk objects.
# No Kubernetes cluster or network access is required.
# Variables consumed by eval-loaded production helpers are intentionally not
# visible to ShellCheck's static analysis.
# shellcheck disable=SC2034
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/k0s_cluster_with_stack.sh"
PASS=0
FAIL=0

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
      "${description}" "${expected}" "${actual}" >&2
  fi
}

assert_before() {
  local description="$1" first_pattern="$2" second_pattern="$3" body="$4"
  local first_line second_line
  first_line="$(grep -n -m1 -- "${first_pattern}" <<< "${body}" | cut -d: -f1)"
  second_line="$(grep -n -m1 -- "${second_pattern}" <<< "${body}" | cut -d: -f1)"
  if [[ -n "${first_line}" && -n "${second_line}" && ${first_line} -lt ${second_line} ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  first line: %s\n  second line: %s\n' \
      "${description}" "${first_line:-missing}" "${second_line:-missing}" >&2
  fi
}

extract_function() {
  local name="$1"
  awk -v signature="${name}()" '
    index($0, signature) == 1 { found=1 }
    found { print }
    found && /^}$/ { exit }
  ' "${SCRIPT}"
}

ownership_body="$(extract_function splunk_assert_owned_or_absent)"
preflight_body="$(extract_function preflight_internal_splunk_resource_ownership)"
certificate_body="$(extract_function provision_splunk_cert)"
standalone_body="$(extract_function install_splunk_standalone)"
stack_body="$(extract_function install_ai_platform_stack)"

assert_eq "ownership helper exists" "1" \
  "$(grep -c '^splunk_assert_owned_or_absent()' <<< "${ownership_body}")"
assert_eq "ownership requires both labels" "2" \
  "$(grep -c 'metadata.labels\["app.kubernetes.io/' <<< "${ownership_body}")"
assert_eq "ownership requires the exact installer instance annotation" "1" \
  "$(grep -c 'metadata.annotations\["ai.splunk.com/owner-id"\]' <<< "${ownership_body}")"
assert_eq "ownership failure provides an explicit legacy adoption command" "1" \
  "$(grep -c 'kubectl -n .* label .*app.kubernetes.io/managed-by=' <<< "${ownership_body}")"
assert_eq "legacy adoption command records the exact owner id" "1" \
  "$(grep -c 'kubectl -n .* annotate .*ai.splunk.com/owner-id=' <<< "${ownership_body}")"

assert_eq "transaction-wide preflight covers all eight fixed-name objects" "8" \
  "$(grep -c 'splunk_assert_owned_or_absent' <<< "${preflight_body}")"
assert_eq "transaction-wide preflight covers both generated Secrets" "2" \
  "$(grep 'splunk_assert_owned_or_absent' <<< "${preflight_body}" | grep -c ' secret ')"
assert_eq "transaction-wide preflight covers ConfigMap and Standalone" "2" \
  "$(grep 'splunk_assert_owned_or_absent' <<< "${preflight_body}" | grep -Ec 'configmap|standalone.enterprise')"
assert_before "certificate transaction preflight precedes manifest application" \
  'preflight_internal_splunk_resource_ownership' 'cat <<YAML' "${certificate_body}"
assert_before "stack ownership preflight precedes pull-secret mutation" \
  'preflight_internal_splunk_resource_ownership' 'create_image_pull_secrets' "${stack_body}"
assert_before "stack ownership preflight precedes Splunk Operator installation" \
  'preflight_internal_splunk_resource_ownership' 'install_splunk_operator' "${stack_body}"
assert_eq "certificate provisioning does not force field conflicts" "0" \
  "$(grep -c -- '--force-conflicts' <<< "${certificate_body}")"
assert_eq "both Certificates label their generated Secrets" "2" \
  "$(grep -c '^  secretTemplate:' <<< "${certificate_body}")"
assert_eq "four cert-manager objects and two generated Secrets are labelled" "6" \
  "$(grep -Ec '^[[:space:]]+app.kubernetes.io/managed-by: splunk-ai-platform-installer' <<< "${certificate_body}")"
assert_eq "four cert-manager objects and two generated Secrets carry owner ids" "6" \
  "$(grep -Ec '^[[:space:]]+ai.splunk.com/owner-id:' <<< "${certificate_body}")"

assert_eq "Standalone provisioning preflights ConfigMap and Standalone" "2" \
  "$(grep -c 'splunk_assert_owned_or_absent' <<< "${standalone_body}")"
assert_before "Standalone ownership preflight precedes credential mutation" \
  'splunk_assert_owned_or_absent' 'create secret generic minio-credentials' "${standalone_body}"
assert_eq "ConfigMap and Standalone carry installer ownership labels" "2" \
  "$(grep -c '^    app.kubernetes.io/managed-by: splunk-ai-platform-installer' <<< "${standalone_body}")"
assert_eq "ConfigMap and Standalone carry exact owner ids" "2" \
  "$(grep -c '^    ai.splunk.com/owner-id:' <<< "${standalone_body}")"
assert_eq "Standalone provisioning does not force field conflicts" "0" \
  "$(grep -c -- '--force-conflicts' <<< "${standalone_body}")"

# Exercise the ownership decision itself with a fake kubectl response.
eval "${ownership_body}"
eval "${preflight_body}"
CLUSTER_NAME="test-cluster"
AI_STANDALONE_NAME="splunk-standalone"
AI_NS="ai-platform"
SPLUNK_MODE="internal"
MOCK_OBJECT_JSON=""
MOCK_KUBECTL_RC=0
ERROR_TEXT=""
kubectl() {
  (( MOCK_KUBECTL_RC == 0 )) || return "${MOCK_KUBECTL_RC}"
  printf '%s' "${MOCK_OBJECT_JSON}"
}
err() {
  ERROR_TEXT="$*"
  return 1
}

missing_rc=0
splunk_assert_owned_or_absent ai-platform secret ai-splunk-server-tls || missing_rc=$?
assert_eq "absent object is safe" "0" "${missing_rc}"

MOCK_OBJECT_JSON='{"metadata":{"labels":{"app.kubernetes.io/managed-by":"splunk-ai-platform-installer","app.kubernetes.io/instance":"splunk-ai-internal"},"annotations":{"ai.splunk.com/owner-id":"test-cluster/splunk-standalone"}}}'
owned_rc=0
splunk_assert_owned_or_absent ai-platform secret ai-splunk-server-tls || owned_rc=$?
assert_eq "matching ownership labels are accepted" "0" "${owned_rc}"

MOCK_OBJECT_JSON='{"metadata":{"labels":{"app.kubernetes.io/managed-by":"another-installer","app.kubernetes.io/instance":"splunk-ai-internal"},"annotations":{"ai.splunk.com/owner-id":"test-cluster/splunk-standalone"}}}'
foreign_rc=0
splunk_assert_owned_or_absent ai-platform secret ai-splunk-server-tls || foreign_rc=$?
assert_eq "foreign object is rejected" "1" "${foreign_rc}"
assert_eq "collision error identifies the exact object" "1" \
  "$(grep -c 'ai-platform/secret/ai-splunk-server-tls' <<< "${ERROR_TEXT}")"

MOCK_OBJECT_JSON='{"metadata":{"labels":{"app.kubernetes.io/managed-by":"splunk-ai-platform-installer","app.kubernetes.io/instance":"splunk-ai-internal"},"annotations":{"ai.splunk.com/owner-id":"other-cluster/splunk-standalone"}}}'
wrong_owner_rc=0
splunk_assert_owned_or_absent ai-platform secret ai-splunk-server-tls || wrong_owner_rc=$?
assert_eq "another installer instance is rejected" "1" "${wrong_owner_rc}"

kubectl() {
  if [[ "${1:-}" == "get" && "${2:-}" == "crd" ]]; then
    printf '%s\n' 'customresourcedefinition.apiextensions.k8s.io/standalones.enterprise.splunk.com'
  elif [[ "${4:-}" == "standalone.enterprise.splunk.com" ]]; then
    printf '%s' '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"another-installer","app.kubernetes.io/instance":"splunk-ai-internal"},"annotations":{"ai.splunk.com/owner-id":"test-cluster/splunk-standalone"}}}'
  fi
}
transaction_rc=0
preflight_internal_splunk_resource_ownership || transaction_rc=$?
assert_eq "foreign Standalone aborts the transaction-wide preflight" "1" "${transaction_rc}"

kubectl() { return 0; }
absent_crd_rc=0
preflight_internal_splunk_resource_ownership || absent_crd_rc=$?
assert_eq "an absent Standalone CRD is safe before operator installation" "0" "${absent_crd_rc}"

kubectl() {
  if [[ "${1:-}" == "get" && "${2:-}" == "crd" ]]; then
    return 1
  fi
}
crd_lookup_rc=0
preflight_internal_splunk_resource_ownership || crd_lookup_rc=$?
assert_eq "Standalone CRD discovery failure is fatal" "1" "${crd_lookup_rc}"

kubectl() {
  (( MOCK_KUBECTL_RC == 0 )) || return "${MOCK_KUBECTL_RC}"
  printf '%s' "${MOCK_OBJECT_JSON}"
}
MOCK_OBJECT_JSON=""
MOCK_KUBECTL_RC=1
lookup_rc=0
splunk_assert_owned_or_absent ai-platform secret ai-splunk-server-tls || lookup_rc=$?
assert_eq "ownership lookup failure is fatal" "1" "${lookup_rc}"

printf 'Splunk ownership tests: %d passed, %d failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
