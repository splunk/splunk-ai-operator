#!/usr/bin/env bash
# Focused, local tests for the air-gap P0 fixes. No SSH, cluster, container
# runtime, or network access is required.
# Variables consumed by eval-loaded production helpers are intentionally not
# visible to ShellCheck's static analysis.
# shellcheck disable=SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/k0s_cluster_with_stack.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass
  else
    fail "${description} (expected=${expected}, actual=${actual})"
  fi
}

assert_rc() {
  local description="$1" expected="$2"
  shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  assert_eq "${description}" "${expected}" "${actual}"
}

extract_fn() {
  local name="$1" start end
  start="$(grep -n "^${name}()" "${SCRIPT}" | cut -d: -f1)"
  [[ -n "${start}" ]] || {
    printf 'Missing function: %s\n' "${name}" >&2
    return 1
  }
  end="$(awk -v start="${start}" 'NR > start && /^}$/ {print NR; exit}' "${SCRIPT}")"
  sed -n "${start},${end}p" "${SCRIPT}"
}

for function_name in \
  sha256_file \
  stage_k0s_image_bundle \
  airgap_expected_image_records \
  airgap_pinned_image_records_from_ctr_list \
  airgap_images_present_on_node \
  wait_for_airgap_images_on_node \
  sync_airgap_images_to_existing_cluster \
  generate_k0s_controller_config; do
  eval "$(extract_fn "${function_name}")"
done

log() { :; }
warn() { :; }
err() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || {
  printf 'SKIP: yq is required for %s\n' "${0}" >&2
  exit 0
}

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP}"' EXIT

run_config_case() (
  local external_address="$1" expected_external="$2"
  local captured="${TEST_TMP}/captured-${expected_external//\//_}.yaml"
  SSH_USER="test"
  SSH_KEY_PATH=""
  K0S_API_EXTERNAL_ADDRESS="${external_address}"

  ssh_exec() {
    shift
    local command="$*"
    if [[ "${command}" == "k0s config create" ]]; then
      printf '%s\n' \
        'apiVersion: k0s.k0sproject.io/v1beta1' \
        'kind: ClusterConfig' \
        'spec:' \
        '  api:' \
        '    address: 10.0.0.10' \
        '    sans:' \
        '      - existing.example'
    fi
  }
  scp_file() {
    cp "$1" "${captured}"
  }

  generate_k0s_controller_config 192.0.2.10

  [[ "$(yq eval '.spec.api.externalAddress' "${captured}")" == "${expected_external}" ]]
  [[ "$(yq eval '[.spec.api.sans[] | select(. == "192.0.2.10")] | length' "${captured}")" == "1" ]]
  [[ "$(EXPECTED_SAN="${expected_external}" yq eval '[.spec.api.sans[] | select(. == strenv(EXPECTED_SAN))] | length' "${captured}")" == "1" ]]
  [[ "$(yq eval '.spec.network.provider' "${captured}")" == "calico" ]]
  [[ "$(yq eval '.spec.network.calico.mode' "${captured}")" == "vxlan" ]]
  [[ "$(yq eval '.spec.storage.type' "${captured}")" == "kine" ]]
  [[ "$(yq eval '.spec.storage.kine.extraArgs."compact-interval"' "${captured}")" == "5m" ]]
)

assert_rc "generated config falls back to the detected private API address" 0 \
  run_config_case "" "10.0.0.10"
assert_rc "configured external API address takes precedence" 0 \
  run_config_case "203.0.113.20" "203.0.113.20"
assert_eq "remote installer contains no PyYAML dependency" "0" \
  "$(grep -cE 'AIRGAP_PYYAML|import yaml|python3-pyyaml|k0s-config-update.py' "${SCRIPT}" | tr -d '[:space:]')"

AIRGAP_K0S_IMAGE_DIR="${TEST_TMP}/images"
mkdir -p "${AIRGAP_K0S_IMAGE_DIR}"
mkdir -p "${TEST_TMP}/oci-layout"
cat > "${TEST_TMP}/oci-layout/index.json" <<'JSON'
{
  "schemaVersion": 2,
  "manifests": [
    {
      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "annotations": {"org.opencontainers.image.ref.name": "docker.io/library/busybox:1.36"}
    },
    {
      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "annotations": {"org.opencontainers.image.ref.name": "quay.io/example/component:v1"}
    }
  ]
}
JSON
tar -cf "${AIRGAP_K0S_IMAGE_DIR}/addon-images.tar" \
  -C "${TEST_TMP}/oci-layout" index.json
LOCAL_ARCHIVE_HASH="$(sha256_file "${AIRGAP_K0S_IMAGE_DIR}/addon-images.tar")"
SCP_CALLS=0
REMOTE_HASH=""
PLACEMENT_COMMAND=""
REFRESH_COMMAND=""
REMOTE_INVENTORY=$'REF TYPE DIGEST SIZE PLATFORMS LABELS\ndocker.io/library/busybox:1.36 application/vnd.oci.image.index.v1+json sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2.1MiB linux/amd64 io.cri-containerd.pinned=pinned,io.k0sproject.ocibundle-paths={...}\nquay.io/example/component:v1 application/vnd.oci.image.manifest.v1+json sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 5.4MiB linux/amd64 io.cri-containerd.pinned=pinned\nquay.io/example/unpinned:v1 application/vnd.oci.image.manifest.v1+json sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd 1.0MiB linux/amd64 -'
SSH_USER="test"
SSH_KEY_PATH=""

ssh_exec() {
  shift
  local command="$*"
  if [[ "${command}" == *"sha256sum /var/lib/k0s/images/addon-images.tar"* ]]; then
    printf '%s\n' "${REMOTE_HASH}"
  elif [[ "${command}" == *"sudo k0s ctr images list"* ]]; then
    printf '%s\n' "${REMOTE_INVENTORY}"
  elif [[ "${command}" == *"sudo cp /tmp/addon-images.tar"* ]]; then
    PLACEMENT_COMMAND="${command}"
  elif [[ "${command}" == *"sudo touch /var/lib/k0s/images/addon-images.tar"* ]]; then
    REFRESH_COMMAND="${command}"
  fi
}
scp_file() {
  SCP_CALLS=$((SCP_CALLS + 1))
}

assert_rc "staging a changed archive succeeds" 0 stage_k0s_image_bundle node-a
assert_eq "changed archive is copied exactly once" "1" "${SCP_CALLS}"
[[ "${PLACEMENT_COMMAND}" == *"/var/lib/k0s/.images-staging/"* ]] && pass || \
  fail "archive is not staged outside the watched images directory"

REMOTE_HASH="${LOCAL_ARCHIVE_HASH}"
assert_rc "staging an unchanged archive is idempotent" 0 stage_k0s_image_bundle node-a
assert_eq "unchanged archive is not retransferred" "1" "${SCP_CALLS}"
assert_rc "expected pinned image digests are verified" 0 \
  wait_for_airgap_images_on_node node-a

PARSED_INVENTORY="$(airgap_pinned_image_records_from_ctr_list <<< "${REMOTE_INVENTORY}")"
assert_eq "ctr inventory parser selects REF and DIGEST from pinned rows" \
  $'docker.io/library/busybox:1.36\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nquay.io/example/component:v1\tsha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  "${PARSED_INVENTORY}"

REMOTE_INVENTORY=$'REF TYPE DIGEST SIZE PLATFORMS LABELS\ndocker.io/library/busybox:1.36 application/vnd.oci.image.index.v1+json sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 2.1MiB linux/amd64 io.cri-containerd.pinned=pinned\nquay.io/example/component:v1 application/vnd.oci.image.manifest.v1+json sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 5.4MiB linux/amd64 io.cri-containerd.pinned=pinned'
assert_rc "a stale digest does not satisfy bundle verification" 1 \
  airgap_images_present_on_node node-a
assert_rc "a same-hash archive can retrigger a failed or garbage-collected import" 0 \
  stage_k0s_image_bundle node-a true
[[ "${REFRESH_COMMAND}" == *"sudo touch /var/lib/k0s/images/addon-images.tar"* ]] && pass || \
  fail "same-hash recovery did not retrigger the live k0s importer"
REMOTE_INVENTORY=$'REF TYPE DIGEST SIZE PLATFORMS LABELS\ndocker.io/library/busybox:1.36 application/vnd.oci.image.index.v1+json sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2.1MiB linux/amd64 io.cri-containerd.pinned=pinned\nquay.io/example/component:v1 application/vnd.oci.image.manifest.v1+json sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 5.4MiB linux/amd64 io.cri-containerd.pinned=pinned'

scp_file() { return 1; }
REMOTE_HASH=""
assert_rc "an archive copy failure is fatal" 1 stage_k0s_image_bundle node-a

AIRGAP_MODE=true
EXISTING_CONTROLLER_IPS="10.0.0.1"
EXISTING_WORKER_IPS="10.0.0.2 10.0.0.3"
SYNC_STAGED=()
SYNC_VERIFIED=()
CLUSTER_NODES_JSON='{"items":[{"metadata":{"name":"worker-a"},"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.2"}]}},{"metadata":{"name":"worker-b"},"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.3"}]}}]}'
kubectl() {
  printf '%s\n' "${CLUSTER_NODES_JSON}"
}
ssh_exec() { return 0; }
airgap_expected_image_records() {
  printf '%s\n' \
    $'docker.io/library/busybox:1.36\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
}
airgap_images_present_on_node() { return 0; }
stage_k0s_image_bundle() {
  SYNC_STAGED+=("$1")
}
wait_for_airgap_images_on_node() {
  SYNC_VERIFIED+=("$1")
}
assert_rc "existing-cluster synchronization succeeds for configured k0s nodes" 0 \
  sync_airgap_images_to_existing_cluster
assert_eq "only actual worker-enabled cluster members receive archives" \
  "10.0.0.2 10.0.0.3" "${SYNC_STAGED[*]}"
assert_eq "only actual worker-enabled cluster members verify imported images" \
  "10.0.0.2 10.0.0.3" "${SYNC_VERIFIED[*]}"

CLUSTER_NODES_JSON='{"items":[{"metadata":{"name":"worker-a"},"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.2"}]}},{"metadata":{"name":"unmapped-worker"},"status":{"addresses":[{"type":"InternalIP","address":"10.0.0.4"}]}}]}'
assert_rc "an unmapped Kubernetes worker aborts synchronization" 1 \
  sync_airgap_images_to_existing_cluster

printf 'Air-gap P0 tests: %d passed, %d failed\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
