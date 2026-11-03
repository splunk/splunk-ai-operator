#!/usr/bin/env bash
# Contract tests for CPU-only --validate-only bundle preflight.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${SCRIPT_DIR}/install_from_airgap_bundle.sh"
INVENTORY_HELPER="${SCRIPT_DIR}/build_airgap_image_inventory.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

PASSED=0

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_checksums() {
  local root="$1" entry digest
  : > "${root}/checksums.sha256"
  while IFS= read -r entry; do
    digest="$(hash_file "${root}/${entry}")"
    printf '%s  %s\n' "${digest}" "${entry}" >> "${root}/checksums.sha256"
  done < <(cd "${root}" && find . -type f ! -name checksums.sha256 -print | sed 's#^./##' | LC_ALL=C sort)
}

make_oci_archive() {
  local archive="$1"
  shift
  local layout="${archive}.layout" ref separator=""
  mkdir -p "${layout}"
  printf '{"schemaVersion":2,"manifests":[' > "${layout}/index.json"
  for ref in "$@"; do
    printf '%s{"digest":"sha256:%064d","annotations":{"org.opencontainers.image.ref.name":"%s"}}' \
      "${separator}" 0 "${ref}" >> "${layout}/index.json"
    separator=,
  done
  printf ']}\n' >> "${layout}/index.json"
  COPYFILE_DISABLE=1 tar -cf "${archive}" -C "${layout}" index.json
  rm -rf "${layout}"
}

write_yq_stub() {
  local target="$1"
  # This fixture is created only in the test's temporary directory.
  cat > "${target}" <<'YQ'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${YQ_SENTINEL:-}" ]] && printf invoked > "${YQ_SENTINEL}"
expression="${3:-}"
input="${4:-}"
case "${expression}" in
  '.manifests[]'*)
    python3 -c 'import json,sys
for item in json.load(sys.stdin).get("manifests", []):
    annotations=item.get("annotations", {})
    print(annotations.get("org.opencontainers.image.ref.name") or annotations.get("io.containerd.image.name") or "")'
    ;;
  '.aiPlatform.profile // ""')
    if grep -Eq '^[[:space:]]*profile:[[:space:]]*full$' "${input}"; then printf 'full\n'; else printf 'cpuOnly\n'; fi
    ;;
  '.cluster.airgap // false') printf 'true\n' ;;
  '.images.operator.image // ""') printf 'registry.internal/operator:v1\n' ;;
  '.images.splunk.image // ""') printf 'registry.internal/splunk:v1\n' ;;
  '.images.splunk.operatorImage // ""') printf 'registry.internal/splunk-operator:v1\n' ;;
  '.images.slim.apiImage // ""') printf 'registry.internal/slim:v1\n' ;;
  '.aiPlatform.features[] | select(.name == "agentruntime") | .las.image.repository')
    printf 'registry.internal/launchpad\n'
    ;;
  '.aiPlatform.features[] | select(.name == "agentruntime") | .las.image.tag')
    if grep -q '^las-tag-mismatch: true$' "${input}"; then printf 'v2\n'; else printf 'v1\n'; fi
    ;;
  '.files.aiPlatform // ""') printf 'artifacts.yaml\n' ;;
  '.files.splunkOperator // ""') printf 'splunk-operator-cluster.yaml\n' ;;
  *) printf 'fixture yq does not implement expression: %s\n' "${expression}" >&2; exit 2 ;;
esac
YQ
  chmod +x "${target}"
}

write_inventory() {
  local root="$1"
  python3 - "${root}" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
imports = []
images = []
for kind in ("k0s", "addon", "workload"):
    listing = root / "images" / f"{kind}-images.list"
    archive = f"images/{kind}-images.tar"
    imports.append({"archive": archive, "imageList": f"images/{kind}-images.list"})
    for reference in listing.read_text(encoding="utf-8").splitlines():
        if reference:
            images.append({
                "reference": reference,
                "digest": "sha256:" + "a" * 64,
                "platforms": [{"os": "linux", "architecture": "amd64"}],
                "importArchives": [archive],
            })
chart = root / "charts" / "langgraph-cloud.tgz"
payload = {
    "schemaVersion": 1,
    "profile": "cpuOnly",
    "imageImports": imports,
    "images": images,
    "embeddedDistribution": {
        "path": "charts/langgraph-cloud.tgz",
        "sha256": hashlib.sha256(chart.read_bytes()).hexdigest(),
    },
}
(root / "image-inventory.json").write_text(json.dumps(payload) + "\n", encoding="utf-8")
PY
}

make_fixture() {
  local case_dir="$1" mode="$2"
  local source="${case_dir}/source"
  local root="${source}/airgap-bundle-fixture"
  mkdir -p "${root}"/{binaries,charts,cluster_setup,images,manifests,packages}

  printf 'cpuOnly\n' > "${root}/bundle-profile.txt"
  printf '%040d\n' 1 > "${root}/source-commit.txt"
  cat > "${root}/bundle-versions.txt" <<'VERSIONS'
k0s_version=v1.36.4+k0s.0
kuberay_chart_version=unused
metallb_chart_version=unused
prometheus_chart_version=unused
otel_chart_version=unused
source_commit=0000000000000000000000000000000000000001
VERSIONS
  printf '#!/usr/bin/env bash\nexit 0\n' > "${root}/binaries/k0s"
  chmod +x "${root}/binaries/k0s"
  write_yq_stub "${root}/binaries/yq"

  printf 'registry.internal/k0s:v1\n' > "${root}/images/k0s-images.list"
  printf 'registry.internal/addon:v1\n' > "${root}/images/addon-images.list"
  cat > "${root}/images/workload-images.list" <<'IMAGES'
registry.internal/launchpad:v1
registry.internal/operator:v1
registry.internal/slim:v1
registry.internal/splunk-operator:v1
registry.internal/splunk:v1
IMAGES
  make_oci_archive "${root}/images/k0s-images.tar" registry.internal/k0s:v1
  make_oci_archive "${root}/images/addon-images.tar" registry.internal/addon:v1
  make_oci_archive "${root}/images/workload-images.tar" \
    registry.internal/launchpad:v1 registry.internal/operator:v1 \
    registry.internal/slim:v1 registry.internal/splunk-operator:v1 \
    registry.internal/splunk:v1

  printf 'image: registry.internal/addon:v1\n' > "${root}/manifests/cert-manager.yaml"
  printf 'image: registry.internal/addon:v1\n' > "${root}/manifests/local-path-storage.yaml"
  printf 'fixture wheel\n' > "${root}/packages/PyYAML.whl"
  printf 'PyYAML.whl\n' > "${root}/packages/pyyaml.filename"
  printf 'fixture chart\n' > "${root}/charts/langgraph-cloud.tgz"

  cp "${WRAPPER}" "${root}/cluster_setup/install_from_airgap_bundle.sh"
  cp "${INVENTORY_HELPER}" "${root}/cluster_setup/build_airgap_image_inventory.py"
  printf 'fixture runtime validator\n' > "${root}/cluster_setup/validate_cpu_airgap_runtime.py"
  cat > "${root}/cluster_setup/k0s_cluster_with_stack.sh" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "validate-airgap-cpu-profile" ]]; then
  printf invoked > "${VALIDATOR_SENTINEL:?}"
  if grep -q '^invalid-airgap-profile: true$' "${CONFIG_FILE:?}"; then
    printf 'cpuOnly air-gap profile rejects invalid fixture config\n' >&2
    exit 1
  fi
  exit 0
fi
printf invoked > "${INSTALLER_SENTINEL:?}"
INSTALLER
  chmod +x "${root}/cluster_setup/k0s_cluster_with_stack.sh"
  printf 'fixture artifacts\n' > "${root}/cluster_setup/artifacts.yaml"
  printf 'fixture splunk operator\n' > "${root}/cluster_setup/splunk-operator-cluster.yaml"
  printf 'fixture deployment helper\n' > "${root}/cluster_setup/las_deployment.py"

  cat > "${case_dir}/config.yaml" <<'CONFIG'
cluster:
  airgap: true
aiPlatform:
  profile: cpuOnly
CONFIG
  write_inventory "${root}"

  case "${mode}" in
    valid|stale-preseed|bundle-sha-mismatch) ;;
    corrupt-checksum) ;;
    missing-archive) rm "${root}/images/workload-images.tar" ;;
    config-closure) printf 'las-tag-mismatch: true\n' >> "${case_dir}/config.yaml" ;;
    invalid-airgap-profile) printf 'invalid-airgap-profile: true\n' >> "${case_dir}/config.yaml" ;;
    missing-oci-ref)
      make_oci_archive "${root}/images/workload-images.tar" \
        registry.internal/operator:v1 registry.internal/slim:v1 \
        registry.internal/splunk-operator:v1 registry.internal/splunk:v1
      ;;
    chart-mismatch)
      python3 - "${root}/image-inventory.json" <<'PY'
import json, pathlib, sys
path=pathlib.Path(sys.argv[1]); data=json.loads(path.read_text())
data["embeddedDistribution"]["sha256"]="0"*64
path.write_text(json.dumps(data)+"\n")
PY
      ;;
    source-mismatch)
      printf '%040d\n' 2 > "${root}/source-commit.txt"
      ;;
    checksum-missing-entry)
      ;;
    checksum-duplicate-entry)
      ;;
    checksum-traversal-entry)
      ;;
    non-cpu)
      rm "${root}/bundle-profile.txt"
      printf 'aiPlatform:\n  profile: full\n' > "${case_dir}/config.yaml"
      ;;
    *) printf 'unknown fixture mode: %s\n' "${mode}" >&2; exit 2 ;;
  esac

  write_checksums "${root}"
  if [[ "${mode}" == "checksum-missing-entry" ]]; then
    grep -v '  source-commit.txt$' "${root}/checksums.sha256" > "${root}/checksums.sha256.tmp"
    mv "${root}/checksums.sha256.tmp" "${root}/checksums.sha256"
  elif [[ "${mode}" == "checksum-duplicate-entry" ]]; then
    head -n 1 "${root}/checksums.sha256" >> "${root}/checksums.sha256"
  elif [[ "${mode}" == "checksum-traversal-entry" ]]; then
    printf '%064d  ../escape\n' 0 >> "${root}/checksums.sha256"
  fi
  if [[ "${mode}" == "corrupt-checksum" ]]; then
    printf 'tampered\n' >> "${root}/charts/langgraph-cloud.tgz"
  fi
  COPYFILE_DISABLE=1 tar -czf "${case_dir}/bundle.tar.gz" -C "${source}" "$(basename "${root}")"
}

make_malicious_archive() {
  local case_dir="$1" mode="$2"
  printf 'aiPlatform:\n  profile: cpuOnly\n' > "${case_dir}/config.yaml"
  python3 - "${case_dir}/bundle.tar.gz" "${mode}" <<'PY'
import io
import sys
import tarfile

archive_path, mode = sys.argv[1:]
with tarfile.open(archive_path, "w:gz") as archive:
    root = tarfile.TarInfo("airgap-bundle-fixture")
    root.type = tarfile.DIRTYPE
    root.mode = 0o755
    archive.addfile(root)
    if mode == "second-root":
        payload = b"unexpected root\n"
        member = tarfile.TarInfo("another-root/payload")
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    elif mode == "traversal":
        payload = b"escape\n"
        member = tarfile.TarInfo("airgap-bundle-fixture/../escape")
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    elif mode == "symlink":
        member = tarfile.TarInfo("airgap-bundle-fixture/escape-link")
        member.type = tarfile.SYMTYPE
        member.linkname = "../../escape"
        archive.addfile(member)
    elif mode == "hardlink":
        member = tarfile.TarInfo("airgap-bundle-fixture/escape-hardlink")
        member.type = tarfile.LNKTYPE
        member.linkname = "../../escape"
        archive.addfile(member)
    elif mode == "duplicate-member":
        for name, payload in (
            ("airgap-bundle-fixture/duplicate", b"first\n"),
            ("airgap-bundle-fixture/./duplicate", b"second\n"),
        ):
            member = tarfile.TarInfo(name)
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
    elif mode == "control-name":
        payload = b"control\n"
        member = tarfile.TarInfo("airgap-bundle-fixture/bad\nname")
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
    else:
        raise SystemExit(f"unknown malicious fixture mode: {mode}")
PY
}

make_command_stubs() {
  local stub_dir="$1" tool
  mkdir -p "${stub_dir}"
  for tool in helm kubectl curl ssh skopeo; do
    cat > "${stub_dir}/${tool}" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${COMMAND_SENTINEL:?}"
exit 97
STUB
    chmod +x "${stub_dir}/${tool}"
  done
}

run_case() {
  local name="$1" mode="$2" want_status="$3" expected="$4"
  local case_dir="${TEST_ROOT}/${name}" output status=0 expected_sha
  mkdir -p "${case_dir}"
  case "${mode}" in
    second-root|traversal|symlink|hardlink|duplicate-member|control-name)
      make_malicious_archive "${case_dir}" "${mode}"
      ;;
    *)
      make_fixture "${case_dir}" "${mode}"
      ;;
  esac
  if [[ "${mode}" == "stale-preseed" ]]; then
    mkdir -p "${case_dir}/extract/airgap-bundle-fixture/images"
    printf 'stale artifact\n' > "${case_dir}/extract/airgap-bundle-fixture/images/workload-images.tar"
  fi
  make_command_stubs "${case_dir}/stubs"
  export COMMAND_SENTINEL="${case_dir}/command-invoked"
  export INSTALLER_SENTINEL="${case_dir}/installer-invoked"
  export VALIDATOR_SENTINEL="${case_dir}/validator-invoked"
  expected_sha="$(hash_file "${case_dir}/bundle.tar.gz")"
  if [[ "${mode}" == "bundle-sha-mismatch" ]]; then
    expected_sha="$(printf '%064d' 0)"
  fi

  if output="$(PATH="${case_dir}/stubs:${PATH}" bash "${WRAPPER}" \
      --bundle "${case_dir}/bundle.tar.gz" \
      --expected-bundle-sha256 "${expected_sha}" \
      --config "${case_dir}/config.yaml" \
      --extract-dir "${case_dir}/extract" \
      --validate-only 2>&1)"; then
    status=0
  else
    status=$?
  fi

  if [[ "${want_status}" == "pass" && "${status}" -ne 0 ]]; then
    printf 'FAIL %s: expected success, got %s\n%s\n' "${name}" "${status}" "${output}" >&2
    exit 1
  fi
  if [[ "${want_status}" == "fail" && "${status}" -eq 0 ]]; then
    printf 'FAIL %s: expected failure\n%s\n' "${name}" "${output}" >&2
    exit 1
  fi
  if [[ "${output}" != *"${expected}"* ]]; then
    printf 'FAIL %s: output did not contain %q\n%s\n' "${name}" "${expected}" "${output}" >&2
    exit 1
  fi
  if [[ -e "${COMMAND_SENTINEL}" || -e "${INSTALLER_SENTINEL}" ]]; then
    printf 'FAIL %s: validation invoked a forbidden command or installer\n' "${name}" >&2
    [[ -e "${COMMAND_SENTINEL}" ]] && cat "${COMMAND_SENTINEL}" >&2
    exit 1
  fi
  if [[ "${name}" == "valid" && ! -e "${VALIDATOR_SENTINEL}" ]]; then
    printf 'FAIL %s: validation did not invoke the real-profile validator entry point\n' "${name}" >&2
    exit 1
  fi
  PASSED=$((PASSED + 1))
  printf 'PASS %s\n' "${name}"
}

run_cpu_missing_external_hash_case() {
  local case_dir="${TEST_ROOT}/cpu-missing-external-hash" output status=0
  mkdir -p "${case_dir}"
  make_fixture "${case_dir}" valid
  make_command_stubs "${case_dir}/stubs"
  export COMMAND_SENTINEL="${case_dir}/command-invoked"
  export INSTALLER_SENTINEL="${case_dir}/installer-invoked"
  export VALIDATOR_SENTINEL="${case_dir}/validator-invoked"
  export YQ_SENTINEL="${case_dir}/yq-invoked"

  if output="$(PATH="${case_dir}/stubs:${PATH}" bash "${WRAPPER}" \
      --bundle "${case_dir}/bundle.tar.gz" \
      --config "${case_dir}/config.yaml" \
      --extract-dir "${case_dir}/extract" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  unset YQ_SENTINEL

  if [[ "${status}" -eq 0 || "${output}" != *"requires --expected-bundle-sha256 before bundled tools can run"* ]]; then
    printf 'FAIL cpu-missing-external-hash: expected early trust failure\n%s\n' "${output}" >&2
    exit 1
  fi
  if [[ -e "${case_dir}/yq-invoked" || -e "${COMMAND_SENTINEL}" ||
        -e "${INSTALLER_SENTINEL}" || -e "${case_dir}/extract" ]]; then
    printf 'FAIL cpu-missing-external-hash: untrusted bundle content was used or extracted\n' >&2
    exit 1
  fi
  PASSED=$((PASSED + 1))
  printf 'PASS cpu-missing-external-hash\n'
}

run_cpu_missing_external_hash_case
run_case valid valid pass "CPU-only bundle validation completed"
run_case stale-preseed stale-preseed fail "Bundle extraction destination already exists"
run_case bundle-sha-mismatch bundle-sha-mismatch fail "Bundle tarball SHA-256 does not match"
run_case corrupt-checksum corrupt-checksum fail "Checksum verification failed"
run_case checksum-missing-entry checksum-missing-entry fail "manifest coverage mismatch"
run_case checksum-duplicate-entry checksum-duplicate-entry fail "duplicate manifest path"
run_case checksum-traversal-entry checksum-traversal-entry fail "unsafe manifest path"
run_case missing-archive missing-archive fail "Required CPU-only bundle artifact missing: images/workload-images.tar"
run_case config-closure config-closure fail "does not contain configured Agent Runtime image"
run_case invalid-airgap-profile invalid-airgap-profile fail "cpuOnly air-gap profile rejects invalid fixture config"
run_case missing-oci-ref missing-oci-ref fail "OCI archive images/workload-images.tar is missing image registry.internal/launchpad:v1"
run_case chart-mismatch chart-mismatch fail "embedded LAS chart digest does not match the inventory"
run_case source-mismatch source-mismatch fail "source commit does not match bundle-versions.txt"
run_case non-cpu non-cpu fail "--validate-only is supported only for CPU-only bundles"
run_case second-root second-root fail "exactly one airgap-bundle-* root"
run_case traversal traversal fail "unsafe member path"
run_case symlink symlink fail "unsupported member type"
run_case hardlink hardlink fail "unsupported member type"
run_case duplicate-member duplicate-member fail "duplicate member"
run_case control-name control-name fail "control character"

printf '%s validation-only bundle tests passed\n' "${PASSED}"
