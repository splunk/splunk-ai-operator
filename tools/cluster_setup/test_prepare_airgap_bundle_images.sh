#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${SCRIPT_DIR}/prepare_airgap_bundle.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT

failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_rc() {
  local description="$1" expected="$2" actual
  shift 2

  if "$@"; then
    actual=0
  else
    actual=$?
  fi
  if [[ "${actual}" == "${expected}" ]]; then
    pass "${description}"
  else
    fail "${description} (expected rc=${expected}, got rc=${actual})"
  fi
}

assert_file_contains() {
  local description="$1" expected="$2" file="$3"

  if grep -Fqx -- "${expected}" "${file}"; then
    pass "${description}"
  else
    fail "${description} (missing: ${expected})"
  fi
}

extract_function() {
  local function_name="$1"

  awk -v signature="${function_name}()" '
    $0 == signature " {" { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
  ' "${BUILDER}"
}

# Load only the pure helper functions under test. Sourcing the builder itself
# would perform downloads and construct an entire air-gap bundle.
# shellcheck disable=SC2294
eval "$(extract_function pin_local_path_helper_image)"
# shellcheck disable=SC2294
eval "$(extract_function extract_image_references)"
# shellcheck disable=SC2294
eval "$(extract_function render_chart_for_image_inventory)"
# shellcheck disable=SC2294
eval "$(extract_function validate_addon_image_reference)"

err() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 97
}

LOCAL_PATH_HELPER_IMAGE="docker.io/library/busybox@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0"

validate_case() {
  (validate_addon_image_reference "$1" >/dev/null 2>&1)
}

assert_rc "versioned image is accepted" 0 \
  validate_case "registry.example.invalid/component:v1.2.3"
assert_rc "sha256-pinned image is accepted" 0 \
  validate_case "registry.example.invalid/component@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_rc "latest image is rejected" 97 \
  validate_case "registry.example.invalid/component:latest"
assert_rc "untagged image is rejected" 97 \
  validate_case "registry.example.invalid/component"
assert_rc "unrendered template image is rejected" 97 \
  validate_case '{{ .Values.image.repository }}:v1'
assert_rc "malformed digest is rejected" 97 \
  validate_case "registry.example.invalid/component@sha256:abcd"

cat > "${TEST_TMP}/image-fields.yaml" <<'YAML'
image: "registry.example.invalid/quoted:v1"
  image: registry.example.invalid/unquoted:v2
YAML
extract_image_references "${TEST_TMP}/image-fields.yaml" > "${TEST_TMP}/extracted-images"
assert_file_contains "quoted manifest image is extracted" \
  "registry.example.invalid/quoted:v1" "${TEST_TMP}/extracted-images"
assert_file_contains "unquoted manifest image is extracted" \
  "registry.example.invalid/unquoted:v2" "${TEST_TMP}/extracted-images"

cat > "${TEST_TMP}/deferred-images.yaml" <<'YAML'
args:
  - --collector-image=otel/opentelemetry-collector-k8s:0.148.0
  - --acme-http01-solver-image=quay.io/jetstack/cert-manager-acmesolver:v1.21.1
  - --prometheus-config-reloader=quay.io/prometheus-operator/prometheus-config-reloader:v0.82.2
YAML
extract_image_references "${TEST_TMP}/deferred-images.yaml" > "${TEST_TMP}/deferred-images"
assert_file_contains "operator-created collector image is extracted" \
  "otel/opentelemetry-collector-k8s:0.148.0" "${TEST_TMP}/deferred-images"
assert_file_contains "operator-created solver image is extracted" \
  "quay.io/jetstack/cert-manager-acmesolver:v1.21.1" "${TEST_TMP}/deferred-images"
assert_file_contains "operator-created reloader image is extracted from a non-image flag" \
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.82.2" "${TEST_TMP}/deferred-images"

cat > "${TEST_TMP}/local-path.yaml" <<'YAML'
kind: ConfigMap
data:
  helperPod.yaml: |-
    spec:
      containers:
        - name: helper-pod
          image: busybox
YAML
pin_local_path_helper_image "${TEST_TMP}/local-path.yaml"
assert_file_contains "local-path helper is rewritten to an immutable image" \
  "          image: ${LOCAL_PATH_HELPER_IMAGE}" "${TEST_TMP}/local-path.yaml"

cat > "${TEST_TMP}/changed-local-path.yaml" <<'YAML'
kind: ConfigMap
data:
  helperPod.yaml: "upstream format changed"
YAML
pin_failure_case() {
  (pin_local_path_helper_image "${TEST_TMP}/changed-local-path.yaml" >/dev/null 2>&1)
}
assert_rc "changed local-path manifest fails closed" 97 pin_failure_case

HELM_ARGS_LOG="${TEST_TMP}/helm.args"
# Invoked indirectly by render_chart_for_image_inventory.
# shellcheck disable=SC2329
helm() {
  printf '%s\n' "$@" > "${HELM_ARGS_LOG}"
  printf 'image: "ghcr.io/open-telemetry/opentelemetry-operator:v1.0.0"\n'
}

render_chart_for_image_inventory \
  "${TEST_TMP}/opentelemetry-operator-0.99.0.tgz" \
  "${TEST_TMP}/otel-rendered.yaml"
assert_file_contains "chart render skips Helm test hooks" \
  "--skip-tests" "${HELM_ARGS_LOG}"
assert_file_contains "OTel render uses the installed collector repository" \
  "manager.collectorImage.repository=otel/opentelemetry-collector-contrib" "${HELM_ARGS_LOG}"
assert_file_contains "OTel render enables cert-manager webhooks" \
  "admissionWebhooks.certManager.enabled=true" "${HELM_ARGS_LOG}"

# Invoked indirectly by render_chart_for_image_inventory.
# shellcheck disable=SC2329
helm() {
  return 64
}
render_failure_case() {
  (render_chart_for_image_inventory \
    "${TEST_TMP}/metallb-0.14.8.tgz" \
    "${TEST_TMP}/failed-render.yaml" >/dev/null 2>&1)
}
assert_rc "Helm rendering failure aborts image enumeration" 97 render_failure_case

unknown_chart_case() {
  (render_chart_for_image_inventory \
    "${TEST_TMP}/unknown-1.0.0.tgz" \
    "${TEST_TMP}/unknown-render.yaml" >/dev/null 2>&1)
}
assert_rc "unknown chart has no silent default render profile" 97 unknown_chart_case

if (( failures > 0 )); then
  printf '\n%d focused air-gap image test(s) failed.\n' "${failures}" >&2
  exit 1
fi

printf '\nAll focused air-gap image tests passed.\n'
