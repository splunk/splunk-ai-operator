#!/usr/bin/env bash

# Keep the canonical CRD documents embedded in the cluster-setup bundle while
# preserving that bundle's installer-specific Deployment image and environment.

set -euo pipefail

mode="${1:-sync}"
if [[ "${mode}" != "sync" && "${mode}" != "check" ]]; then
  echo "usage: $0 [sync|check]" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bundle="${repo_root}/tools/cluster_setup/artifacts.yaml"
platform_crd="${repo_root}/config/crd/bases/ai.splunk.com_aiplatforms.yaml"
service_crd="${repo_root}/config/crd/bases/ai.splunk.com_aiservices.yaml"

first_tmp=$(mktemp /tmp/splunk-ai-crd-sync-first.XXXXXX)
second_tmp=$(mktemp /tmp/splunk-ai-crd-sync-second.XXXXXX)
trap 'rm -f "${first_tmp}" "${second_tmp}"' EXIT

replace_crd_document() {
  local canonical_file=$1
  local input_bundle=$2
  local crd_name=$3
  local output_bundle=$4

  awk -v target_name="${crd_name}" '
    FNR == NR {
      canonical = canonical $0 ORS
      next
    }

    function flush_document() {
      if (document == "") {
        return
      }
      if (is_crd && has_target_name) {
        printf "%s", canonical
        replacements++
      } else {
        printf "%s", document
      }
    }

    $0 == "---" {
      flush_document()
      document = $0 ORS
      is_crd = 0
      has_target_name = 0
      next
    }

    {
      document = document $0 ORS
      if ($0 == "kind: CustomResourceDefinition") {
        is_crd = 1
      }
      if ($0 == "  name: " target_name) {
        has_target_name = 1
      }
    }

    END {
      flush_document()
      if (replacements != 1) {
        printf "expected exactly one CRD document named %s, found %d\n", target_name, replacements > "/dev/stderr"
        exit 1
      }
    }
  ' "${canonical_file}" "${input_bundle}" > "${output_bundle}"
}

replace_crd_document "${platform_crd}" "${bundle}" "aiplatforms.ai.splunk.com" "${first_tmp}"
replace_crd_document "${service_crd}" "${first_tmp}" "aiservices.ai.splunk.com" "${second_tmp}"

if [[ "${mode}" == "check" ]]; then
  if ! cmp -s "${bundle}" "${second_tmp}"; then
    echo "tools/cluster_setup/artifacts.yaml contains stale CRD documents." >&2
    echo "Run 'make sync-crd-artifacts' and commit the result." >&2
    diff -u "${bundle}" "${second_tmp}" || true
    exit 1
  fi
  echo "Cluster-setup CRD documents are synchronized."
  exit 0
fi

cp "${second_tmp}" "${bundle}"
echo "Synchronized canonical CRDs into tools/cluster_setup/artifacts.yaml."
