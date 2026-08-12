#!/bin/bash
# Test-env helper (NOT part of the product install flow) — recreates the
# k0s-test air-gap mirror registry: installs podman, brings up a plain-HTTP
# registry:2 container (paired with images.registryInsecure: true in the
# cluster config), and mirrors the docker.io images (incl. preview builds)
# the k0s-test cluster runs off. Run this ON THE INSTALLER HOST (the one
# with internet access and SSH reach to the cluster nodes), not on the
# sealed nodes.
#
# TLS was tried first (self-signed CA + OS trust store) and deliberately
# reverted for this test env — the installer has no CA-distribution
# mechanism, so plain HTTP + registryInsecure is simpler here. See
# images.registryInsecure in k0s-cluster-config.yaml.
set -uo pipefail

REG_IP="${REG_IP:-10.0.39.244}"
REG_PORT="${REG_PORT:-5000}"
REG="${REG_IP}:${REG_PORT}"
# Keep registry data off the 49 GB root volume — the mirrored set (splunk
# 10.2-rhel9 + the ai-tier ray/saia builds) does not fit there.
DATA_DIR="${DATA_DIR:-/data/registry}"

# All platform images are now on docker.io (preview build) — no ECR login
# needed. Path is preserved verbatim after stripping the docker.io/ prefix,
# e.g. docker.io/splunk/splunk:10.2-rhel9 -> ${REG}/splunk/splunk:10.2-rhel9
DOCKERHUB_IMAGES="
docker.io/splunk/splunk:10.2-rhel9
docker.io/splunk/splunk-operator:3.0.0
docker.io/semitechnologies/weaviate:stable-v1.28-007846a
docker.io/fluent/fluent-bit:1.9.6
docker.io/otel/opentelemetry-collector-contrib:0.122.1
docker.io/library/nginx:1.27-alpine
docker.io/splunk/ai-tier-ray-worker:preview
docker.io/splunk/ai-tier-ray-head:preview
docker.io/splunk/ai-tier-saia-api:preview
docker.io/splunk/ai-tier-saia-api-v2:preview
docker.io/splunk/ai-tier-saia-data-loader:preview
docker.io/kpratyush775/splunk-ai-operator:v2.3
"

log() { printf '\n=== %s ===\n' "$1"; }

log "1. podman"
if ! command -v podman >/dev/null 2>&1; then
  sudo dnf install -y podman
else
  echo "podman already present: $(podman --version)"
fi

log "2. registry data dir"
sudo mkdir -p "${DATA_DIR}"

# podman stages pulled layers in its graphroot BEFORE the push, and rmi only
# reclaims after each image — so the default /var/lib/containers would spike
# the root volume even with DATA_DIR elsewhere. Pin the graphroot next to the
# registry data so both live on the big volume.
GRAPHROOT="${GRAPHROOT:-$(dirname "${DATA_DIR}")/containers}"
sudo mkdir -p "${GRAPHROOT}"
PODMAN=(sudo podman --root "${GRAPHROOT}")
echo "graphroot: ${GRAPHROOT}"

# A graphroot outside /var/lib/containers inherits default_t under SELinux,
# and container_t then cannot exec its loader — musl-based images (registry:2
# is Alpine) die with "RELRO protection failed" and exit 127. Give the new
# path the same labelling rules as the default one.
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  log "2b. SELinux labelling for ${GRAPHROOT}"
  command -v semanage >/dev/null 2>&1 || sudo dnf install -y -q policycoreutils-python-utils
  sudo semanage fcontext -a -e /var/lib/containers "${GRAPHROOT}" 2>/dev/null || true
  sudo restorecon -RF "${GRAPHROOT}"
  ls -Zd "${GRAPHROOT}"
fi

log "3. bring up plain-HTTP registry:2 (no TLS env vars)"
"${PODMAN[@]}" rm -f k0s-registry 2>/dev/null || true
"${PODMAN[@]}" run -d --name k0s-registry --restart=always \
  -p "${REG_PORT}:5000" \
  -v "${DATA_DIR}:/var/lib/registry:z" \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  docker.io/library/registry:2
sleep 3
"${PODMAN[@]}" ps --filter name=k0s-registry --format '{{.Names}} {{.Status}} {{.Ports}}'

log "4. verify plain HTTP (expect 200, no --cacert needed)"
# Gate the mirror loop on this: a dead registry otherwise produces a run that
# logs a connection-refused per image and still ends with a partial catalog,
# which only surfaces much later as ImagePullBackOff during the install.
for attempt in 1 2 3 4 5; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${REG}/v2/")
  echo "  attempt ${attempt}: http://${REG}/v2/ -> ${code}"
  [[ "${code}" == "200" ]] && break
  sleep 3
done
if [[ "${code}" != "200" ]]; then
  echo "ERROR: registry at ${REG} is not serving /v2/ — aborting before mirroring." >&2
  echo "       check: sudo podman --root ${GRAPHROOT} logs k0s-registry" >&2
  exit 1
fi

log "5. mirror docker.io images"
FAILED=()
for src in ${DOCKERHUB_IMAGES}; do
  path="${src#docker.io/}"
  dest="${REG}/${path}"
  echo "-- ${src} -> ${dest}"
  if "${PODMAN[@]}" pull "${src}" \
    && "${PODMAN[@]}" push --tls-verify=false "${src}" "${dest}"; then
    "${PODMAN[@]}" rmi "${src}" >/dev/null 2>&1
  else
    # Leave a failed image in local storage on purpose — a retry can then push
    # it straight from there instead of re-downloading gigabytes.
    FAILED+=("${src}")
  fi
  df -h "${DATA_DIR}" | tail -1 | awk '{print "   disk avail: "$4}'
done

log "6. registry catalog"
curl -s "http://${REG}/v2/_catalog"; echo

if (( ${#FAILED[@]} )); then
  echo ""
  echo "!! ${#FAILED[@]} image(s) FAILED to mirror — the cluster will hit ImagePullBackOff on these:" >&2
  printf '   %s\n' "${FAILED[@]}" >&2
  echo "   They are still in local storage; re-run this script to retry them." >&2
  exit 1
fi

log "7. cluster config reminder"
cat <<EOF
Set in your CONFIG_FILE (e.g. k0s-cluster-config.yaml):
  images.registry: "${REG}"
  images.registryInsecure: true
  imagePullSecrets.autoCreateECR: false
  imagePullSecrets.secrets: []
Then rewrite every docker.io/* image ref in the config to ${REG}/...
(build_image_url only prefixes BARE names like ml-platform/*; full-path
refs are left intact and must be rewritten explicitly).
EOF
