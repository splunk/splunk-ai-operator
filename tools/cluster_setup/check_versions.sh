#!/usr/bin/env bash
# Fails if a version hardcoded in scripts/docs disagrees with versions.env.
#
# Every pinned version must be tagged inline with `ver:<KEY>` immediately
# after the version string, e.g.:
#   YQ_VERSION="v4.44.1"  # ver:YQ_VERSION
#   pinned to `v4.44.1` <!-- ver:YQ_VERSION -->
#
# This script finds every `ver:<KEY>` marker in the repo, and checks that the
# version string named by KEY in versions.env also appears on that line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERSIONS_FILE="${SCRIPT_DIR}/versions.env"

[[ -f "${VERSIONS_FILE}" ]] || { echo "missing ${VERSIONS_FILE}" >&2; exit 1; }

declare -A EXPECTED
while IFS='=' read -r key value; do
  [[ -z "${key}" || "${key}" == \#* ]] && continue
  EXPECTED["${key}"]="${value}"
done < "${VERSIONS_FILE}"

mismatches=0
checked=0

# grep -rn output is "path:line_no:content" — content may itself contain ':',
# so split only on the first two colons.
while IFS= read -r hit; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  line_no="${rest%%:*}"
  content="${rest#*:}"

  # Require a non-identifier char (or start of line) before "ver:" so this
  # doesn't false-match inside words like "nvidia-driver:latest-dkms".
  [[ "${content}" =~ (^|[^A-Za-z0-9_-])ver:([A-Za-z0-9_]+) ]] || continue
  key="${BASH_REMATCH[2]}"

  if [[ -z "${EXPECTED[${key}]+x}" ]]; then
    echo "UNKNOWN KEY: ${file}:${line_no} references ver:${key}, not present in versions.env" >&2
    mismatches=$(( mismatches + 1 ))
    continue
  fi

  expected="${EXPECTED[${key}]}"
  if ! grep -qF -- "${expected}" <<<"${content}"; then
    echo "MISMATCH: ${file}:${line_no} expected '${expected}' (versions.env:${key}) — got: ${content}" >&2
    mismatches=$(( mismatches + 1 ))
  fi
  checked=$(( checked + 1 ))
done < <(grep -rn 'ver:[A-Za-z0-9_]\+' \
  --include='*.sh' --include='*.md' \
  "${REPO_ROOT}/tools/cluster_setup" "${REPO_ROOT}/docs/deployment" 2>/dev/null)

if (( checked == 0 )); then
  echo "No ver:<KEY> markers found — nothing checked. Is the marker convention still in use?" >&2
  exit 1
fi

echo "Checked ${checked} marker(s)."
if (( mismatches > 0 )); then
  echo "${mismatches} version drift issue(s) found." >&2
  exit 1
fi

echo "No version drift."
