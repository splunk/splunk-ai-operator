# Test Plan — `make_customers_exp_better` Branch

## Implementation Chart

| Change | Code size (lines added/changed) | Existing functions touched | Risk of breaking existing behavior | Review without live run? |
|---|---|---|---|---|
| **P0 — Timestamps on every log line** | 4 lines (rewrite `log`/`warn`/`err`) | `log`, `warn`, `err` — called ~300× | **Low** — output format change only; no logic | **Yes** — `bash -n` + grep output |
| **P0 — err() prints log path + diagnose hint** | +2 lines inside `err()` | `err()` | **None** — additive to stderr | **Yes** |
| **P0 — delete/clean-all confirmation prompt** | ~20 lines in `main_delete` | `main_delete`, `clean_all` | **Low** — `AUTO_APPROVE=true` bypasses it; CI unaffected | **Yes** — read the guard logic |
| **P0 — Log rotation (keep last 10)** | 12 lines at session start | None (new `_rotate_logs` helper) | **None** — deletes old log files only | **Yes** |
| **P1 — show_install_plan()** | ~50 lines (new function) + 3 call-site lines | `main_install` | **Low** — gated by `AUTO_APPROVE`; adds a `yes` prompt | **Partial** — logic reviewable; prompt needs a live test |
| **P1 — wait_for_dependency()** | ~30 lines (new function) | Not yet wired into any call site (library function) | **None** — unused until explicitly called | **Yes** |
| **P1 — Step progress tracker + show_step_summary** | ~60 lines (new helpers) + ~20 wiring lines | `main_install` | **Low** — purely additive output; install logic unchanged | **Yes** |
| **P1 — phase_start/phase_end markers** | 2 lines (new helpers) + ~8 call-site lines | `main_install` | **None** — output only | **Yes** |
| **P2 — need() with install instructions** | ~20 lines (rewrite `need()`) | `need()` — called ~8× in preflight | **None** — same exit behavior, better message | **Yes** |
| **P2 — validate subcommand** | ~60 lines (new `validate_config`) | Dispatch case only | **None** — no-op, read-only | **Yes** |
| **P2 — diagnose subcommand** | ~70 lines (new `diagnose`) | Dispatch case only | **None** — read-only + creates a tar.gz | **Yes** |
| **Air-gap env-var overrides** | ~80 lines (all `${VAR:-url}` patterns) | 5 install functions | **Low** — original URLs preserved as defaults | **Yes** |
| **prepare_airgap_bundle.sh** | 384 lines (new script) | None | **None** — new file | **Yes** — `bash -n` |
| **install_from_airgap_bundle.sh** | 283 lines (new script) | None | **None** — new file | **Yes** — `bash -n` |
| **AIRGAP.md** | 381 lines (new doc) | None | **None** — documentation | **Yes** |
| **H100 removal from k0s docs** | ~10 lines removed/changed | K0S_README, K0S_QUICKSTART, k0s-cluster-config.yaml, k0s_cluster_with_stack.sh | **None** — documentation + comment | **Yes** — grep |
| **Gemma model list additions** | ~30 lines added | K0S_README, EKS_README, artifacts/README | **None** — documentation | **Yes** — grep |
| **wait_for_dependency() — object store** | ~20 lines in `ensure_s3compat_credentials` | `ensure_s3compat_credentials` | **Low** — adds a wait before secret creation; worst case adds ≤5 min if store is briefly unreachable | **Partial** — guard logic reviewable; wait behaviour needs live test |
| **wait_for_dependency() — HuggingFace** | ~8 lines in `stage_model_artifacts` | `stage_model_artifacts` | **Low** — skipped when `AIRGAP_MODE=true`; adds pause before download | **Partial** — AIRGAP_MODE guard reviewable; wait needs live test |
| **wait_for_dependency() — NVIDIA repos** | ~10 lines in `install_nvidia_host_drivers` | `install_nvidia_host_drivers` | **Low** — skipped when `AIRGAP_MODE=true`; per-node check before toolkit install | **Partial** — AIRGAP_MODE guard reviewable; wait needs live test |
| **`_check_node_os()` helper + wiring** | ~45 lines (new helper) + 2 wiring sites | `prepare_nodes_for_k0s`, `_install_nvidia_on_node` | **Medium** — gates all node work; wrong regex exits prematurely | **Partial** — guard logic reviewable; must run against real node to verify OS string parsing |
| **AIRGAP_MODE hard-fail on missing nvidia-smi** | ~8 lines in `_install_nvidia_on_node` | `_install_nvidia_on_node` | **Low** — new branch between existing detection and install phases | **Yes** — grep code path |
| **GPU package URL overrides (EPEL, CUDA, CTK)** | ~20 lines (`${VAR:-url}` patterns in `_install_nvidia_on_node`) | `_install_nvidia_on_node` | **Low** — original URLs preserved as defaults | **Yes** — grep |
| **`AIRGAP_PYYAML_WHEEL_PATH` support (all nodes)** | ~15 lines in `prepare_nodes_for_k0s` + ~10 lines in `install_from_airgap_bundle.sh` | `prepare_nodes_for_k0s` | **Low** — new branch; falls through to `dnf install` if var unset | **Yes** — grep |
| **`prepare_airgap_bundle.sh` packages/ section** | ~80 lines (new section 5) | None (new code in existing script) | **Low** — additive; does not touch existing sections | **Yes** — `bash -n` + grep |
| **`--gpu-os` argument + validation gate** | ~30 lines in `prepare_airgap_bundle.sh` | Argument-parsing block | **None** — new argument; existing behaviour unchanged if not passed | **Yes** — grep |
| **RHEL 10 / AL2023 removal from docs** | ~50 lines changed across 4 docs | K0S_README, K0S_QUICKSTART, AIRGAP, k0s_cluster_with_stack.sh comments | **None** — documentation | **Yes** — grep |
| **DEPLOYMENT_GUIDE.md (new file)** | 829 lines (new file, 14 Mermaid diagrams) | None | **None** — new file, no code change | **Partial** — file parseable locally; diagram rendering needs GitHub preview |
| **Staging machine requirements** | ~20 lines across AIRGAP.md, K0S_QUICKSTART.md, DEPLOYMENT_GUIDE.md | None | **None** — documentation | **Yes** — grep |
| **GPU spec update (8 × L40S, g6e.12xlarge)** | ~15 lines across K0S_QUICKSTART, K0S_README, DEPLOYMENT_GUIDE | None | **None** — documentation | **Yes** — grep |
| **VOC Portal removal from k0s docs** | ~5 lines changed in K0S_QUICKSTART, DEPLOYMENT_GUIDE | None | **None** — documentation | **Yes** — grep |
| **`defaultAcceleratorType` description (L40S only)** | ~3 lines across K0S_QUICKSTART, K0S_README | None | **None** — documentation | **Yes** — grep |

---

## Tier 1 — Local, no cluster, no internet required

Run on any developer laptop. Total time: under 5 minutes. All tests are gating for PR merge.

### T1-1: Bash syntax validation

```bash
bash -n tools/cluster_setup/k0s_cluster_with_stack.sh
bash -n tools/cluster_setup/prepare_airgap_bundle.sh
bash -n tools/cluster_setup/install_from_airgap_bundle.sh
```

**Pass:** All exit 0, no output.
**Fail:** Any syntax error printed.

---

### T1-2: `--help` output is complete and exits cleanly

```bash
tools/cluster_setup/prepare_airgap_bundle.sh --help
echo "exit: $?"

tools/cluster_setup/install_from_airgap_bundle.sh --help
echo "exit: $?"
```

**Pass:** Both print usage including every env var in the reference table, exit 0.
**Fail:** Exits non-zero, crashes, or any variable from the env-var reference is missing.

---

### T1-3: H100 removed from k0s-specific files

```bash
grep -rn "H100" \
  tools/cluster_setup/K0S_README.md \
  tools/cluster_setup/K0S_QUICKSTART.md \
  tools/cluster_setup/k0s-cluster-config.yaml \
  tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** Zero matches.
**Fail:** Any match.

EKS H100 references must still be present (real code path):

```bash
grep -c "H100" tools/cluster_setup/EKS_README.md
```

**Pass:** Count > 0.
**Fail:** 0 — EKS references were accidentally removed.

---

### T1-4: Gemma references present in all required docs

```bash
grep -l "gemma-4-31b-it" \
  tools/cluster_setup/K0S_README.md \
  tools/cluster_setup/EKS_README.md \
  tools/artifacts_download_upload_scripts/README.md
```

**Pass:** All 3 filenames printed.
**Fail:** Any file missing.

---

### T1-5: Model list in artifacts README matches source of truth

```bash
# Source of truth
grep "^  name:" tools/artifacts_download_upload_scripts/model_artifacts_configs.yaml \
  | awk '{print $2}' | sort

# README list
grep -E "^\| \`" tools/artifacts_download_upload_scripts/README.md \
  | awk -F'`' '{print $2}' | sort
```

**Pass:** Both lists are identical.
**Fail:** Any model present in the YAML is absent from the README, or vice versa.

---

### T1-6: All 9 air-gap env-var overrides are wired into the installer

```bash
for var in \
  K0S_INSTALL_URL \
  YQ_DOWNLOAD_URL \
  CERT_MANAGER_MANIFEST_URL \
  LOCAL_PATH_MANIFEST_URL \
  NVIDIA_DEVICE_PLUGIN_MANIFEST_URL \
  PROMETHEUS_CHART_PATH \
  OTEL_CHART_PATH \
  KUBERAY_CHART_PATH \
  METALLB_CHART_PATH; do
  grep -q "\${${var}" tools/cluster_setup/k0s_cluster_with_stack.sh \
    && echo "OK: $var" \
    || echo "MISSING: $var"
done
```

**Pass:** All 9 lines print `OK`.
**Fail:** Any `MISSING`.

---

### T1-7: Online URLs still present as fallback defaults

```bash
grep "get.k0s.sh"                    tools/cluster_setup/k0s_cluster_with_stack.sh
grep "cert-manager/releases/download" tools/cluster_setup/k0s_cluster_with_stack.sh
grep "rancher/local-path-provisioner" tools/cluster_setup/k0s_cluster_with_stack.sh
grep "NVIDIA/k8s-device-plugin"       tools/cluster_setup/k0s_cluster_with_stack.sh
grep "mikefarah/yq/releases"          tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** All 5 print at least one match — original URLs preserved as defaults.
**Fail:** Any grep finds nothing.

---

### T1-8: Internal doc links resolve

```bash
grep -oP '\[.*?\]\(\K[^)]+(?=\))' tools/cluster_setup/AIRGAP.md \
  | grep -v "^http" \
  | while read -r f; do
      [ -f "tools/cluster_setup/$f" ] \
        && echo "OK: $f" \
        || echo "BROKEN: $f"
    done
```

**Pass:** All print `OK`.
**Fail:** Any `BROKEN`.

AIRGAP.md referenced from K0S_README:

```bash
grep -c "AIRGAP.md" tools/cluster_setup/K0S_README.md
```

**Pass:** Count ≥ 2 (ToC callout + Air-Gapped Deployment section).

---

### T1-9: Timestamps appear in log/warn/err definitions

```bash
grep -A1 "^log()\|^warn()\|^err()" tools/cluster_setup/k0s_cluster_with_stack.sh \
  | grep "_ts\|date"
```

**Pass:** `_ts` or `date` appears in the function bodies.
**Fail:** No match — timestamps not wired in.

---

### T1-10: New subcommands present in dispatch

```bash
for sub in validate diagnose; do
  grep -q "^  ${sub})" tools/cluster_setup/k0s_cluster_with_stack.sh \
    && echo "OK: $sub" || echo "MISSING: $sub"
done
```

**Pass:** Both print `OK`.

---

### T1-11: Log rotation code present

```bash
grep -c "_rotate_logs" tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** Count = 2 (definition + call).

---

### T1-12: Confirmation prompt present in main_delete

```bash
grep -A5 "Type the cluster name" tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** Shows the prompt text and a `read -r` call.
**Fail:** No match.

---

### T1-13: AUTO_APPROVE bypasses all prompts

```bash
grep -c 'AUTO_APPROVE.*true' tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** Count ≥ 2 (install plan gate + delete prompt gate).

---

### T1-14: `_check_node_os()` helper is defined and wired at both call sites

```bash
# Helper definition present
grep -c "^_check_node_os()" tools/cluster_setup/k0s_cluster_with_stack.sh

# Wired into prepare_nodes_for_k0s
grep -A60 "^prepare_nodes_for_k0s()" tools/cluster_setup/k0s_cluster_with_stack.sh \
  | grep "_check_node_os"

# Wired into _install_nvidia_on_node
grep -A20 "^_install_nvidia_on_node()" tools/cluster_setup/k0s_cluster_with_stack.sh \
  | grep "_check_node_os"
```

**Pass:** Definition count = 1; both function bodies show a `_check_node_os` call.
**Fail:** Any output missing — helper not defined or not wired.

---

### T1-15: `FORCE_UNSUPPORTED_OS` escape hatch is present

```bash
grep "FORCE_UNSUPPORTED_OS" tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** At least one line with `FORCE_UNSUPPORTED_OS:-0` guard in `_check_node_os`.
**Fail:** No match — internal testing escape hatch missing.

---

### T1-16: AIRGAP_MODE hard-fail code path is present in `_install_nvidia_on_node`

```bash
grep -A8 'AIRGAP_MODE.*true' tools/cluster_setup/k0s_cluster_with_stack.sh \
  | grep -E "ERROR.*AIRGAP_MODE|nvidia-smi.*not found"
```

**Pass:** At least one error message mentioning `AIRGAP_MODE` and missing nvidia-smi.
**Fail:** No match — AIRGAP hard-fail was not added.

---

### T1-17: GPU package URL override variables are wired into `_install_nvidia_on_node`

```bash
for var in EPEL_RPM_URL_OVERRIDE CUDA_REPO_URL_OVERRIDE NVIDIA_CTK_REPO_URL_OVERRIDE; do
  grep -q "\${${var}" tools/cluster_setup/k0s_cluster_with_stack.sh \
    && echo "OK: $var" \
    || echo "MISSING: $var"
done
```

**Pass:** All 3 print `OK`.
**Fail:** Any `MISSING` — override env var not wired in.

---

### T1-18: Original GPU package URLs still present as defaults

```bash
grep "dl.fedoraproject.org/pub/epel"        tools/cluster_setup/k0s_cluster_with_stack.sh
grep "developer.download.nvidia.com/compute" tools/cluster_setup/k0s_cluster_with_stack.sh
grep "nvidia.github.io/libnvidia-container"  tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** All 3 match — original URLs preserved as `${VAR:-<url>}` defaults.
**Fail:** Any grep finds nothing — URL was removed rather than made overridable.

---

### T1-19: `AIRGAP_PYYAML_WHEEL_PATH` branch is present in installer

```bash
grep "AIRGAP_PYYAML_WHEEL_PATH" tools/cluster_setup/k0s_cluster_with_stack.sh
grep "AIRGAP_PYYAML_WHEEL_PATH" tools/cluster_setup/install_from_airgap_bundle.sh
```

**Pass:** At least one match in each file.
**Fail:** Missing from either file — offline pyyaml install not wired.

---

### T1-20: RHEL 10 and Amazon Linux 2023 removed from all k0s docs

```bash
grep -rni "rhel.10\|rhel10\|amazon.linux.2023\|amzn2023\|AL2023" \
  tools/cluster_setup/K0S_README.md \
  tools/cluster_setup/K0S_QUICKSTART.md \
  tools/cluster_setup/AIRGAP.md \
  tools/cluster_setup/DEPLOYMENT_GUIDE.md
```

**Pass:** Zero matches.
**Fail:** Any match — removed OS still mentioned in docs.

---

### T1-21: Supported OS stated consistently as RHEL 9 family

```bash
grep -c "Rocky.*9\|AlmaLinux.*9\|CentOS.*Stream.*9" \
  tools/cluster_setup/K0S_README.md \
  tools/cluster_setup/K0S_QUICKSTART.md
```

**Pass:** Count > 0 in each file — compatible distros listed.
**Fail:** 0 — only "RHEL 9" listed without mentioning compatible alternatives.

---

### T1-22: VOC Portal removed from all k0s docs

```bash
grep -rni "VOC.Portal\|voc portal" \
  tools/cluster_setup/K0S_README.md \
  tools/cluster_setup/K0S_QUICKSTART.md \
  tools/cluster_setup/AIRGAP.md \
  tools/cluster_setup/DEPLOYMENT_GUIDE.md
```

**Pass:** Zero matches.
**Fail:** Any match — VOC Portal reference still present.

---

### T1-23: `defaultAcceleratorType` described as required, L40S only

```bash
grep -A2 "defaultAcceleratorType" tools/cluster_setup/K0S_README.md \
  | grep -i "L40S\|only"
grep -i "defaultAcceleratorType" tools/cluster_setup/K0S_QUICKSTART.md \
  | grep -i "L40S"
```

**Pass:** Both return a match confirming L40S is the required/only value.
**Fail:** No match — description may still say "e.g." or omit the constraint.

---

### T1-24: GPU spec is consistently 8 × L40S across docs

```bash
grep -c "8.*L40S\|L40S.*8" \
  tools/cluster_setup/K0S_QUICKSTART.md \
  tools/cluster_setup/DEPLOYMENT_GUIDE.md
```

**Pass:** Count ≥ 1 in each file.
**Fail:** 0 in any file — 8-GPU total not explicitly called out.

---

### T1-25: Staging machine requirements (250 GB / 16 GB) present in all three docs

```bash
for f in \
  tools/cluster_setup/AIRGAP.md \
  tools/cluster_setup/K0S_QUICKSTART.md \
  tools/cluster_setup/DEPLOYMENT_GUIDE.md; do
  grep -qiE "250.?GB|250 GB" "$f" \
    && echo "OK (250 GB): $f" \
    || echo "MISSING (250 GB): $f"
  grep -qiE "16.?GB|16 GB" "$f" \
    && echo "OK (16 GB): $f" \
    || echo "MISSING (16 GB): $f"
done
```

**Pass:** All 6 lines print `OK`.
**Fail:** Any `MISSING` — staging requirements inconsistent across docs.

---

### T1-26: `prepare_airgap_bundle.sh` — `--gpu-os` argument parsing present

```bash
grep "gpu.os\|gpu_os\|GPU_NODE_OS" tools/cluster_setup/prepare_airgap_bundle.sh
```

**Pass:** At least 3 matches (variable declaration, argument parsing, validation gate).
**Fail:** Fewer than 3 — argument or validation not fully wired.

---

### T1-27: `prepare_airgap_bundle.sh` validation gate rejects non-rhel9 values — code review

```bash
grep -A5 "gpu_node_os.*not supported\|GPU_NODE_OS.*!=.*rhel9\|Only.*rhel9" \
  tools/cluster_setup/prepare_airgap_bundle.sh
```

**Pass:** Error message and exit 1 present.
**Fail:** No match — non-rhel9 values would silently proceed.

---

### T1-28: `prepare_airgap_bundle.sh` packages/ section present

```bash
grep -c "packages/" tools/cluster_setup/prepare_airgap_bundle.sh
```

**Pass:** Count ≥ 3 (mkdir, download lines, checksums find).
**Fail:** Count < 3 — packages directory not fully integrated.

---

### T1-29: DEPLOYMENT_GUIDE.md exists and contains all 14 Mermaid diagrams

```bash
# File exists
test -f tools/cluster_setup/DEPLOYMENT_GUIDE.md && echo "OK: file exists" || echo "MISSING"

# Count Mermaid blocks
grep -c '```mermaid' tools/cluster_setup/DEPLOYMENT_GUIDE.md
```

**Pass:** File exists; count = 14.
**Fail:** File missing or count ≠ 14.

---

## Tier 2 — Internet-connected machine, no cluster

Requires: `curl`, `helm`, `tar`. Time: ~10–15 minutes.

### T2-1: `prepare_airgap_bundle.sh` runs end-to-end

```bash
cd tools/cluster_setup
./prepare_airgap_bundle.sh --output-dir /tmp/test-bundle --k0s-version v1.31.2+k0s.0
```

Verify bundle structure:

```bash
tar -tzf /tmp/test-bundle/airgap-bundle-*.tar.gz | sort
```

Expected paths:
```
airgap-bundle-.../binaries/k0s
airgap-bundle-.../binaries/k0s.version
airgap-bundle-.../binaries/yq
airgap-bundle-.../manifests/cert-manager.yaml
airgap-bundle-.../manifests/local-path-storage.yaml
airgap-bundle-.../manifests/nvidia-device-plugin.yml
airgap-bundle-.../charts/kube-prometheus-stack-*.tgz
airgap-bundle-.../charts/opentelemetry-operator-*.tgz
airgap-bundle-.../charts/kuberay-operator-1.2.2.tgz
airgap-bundle-.../charts/metallb-0.14.8.tgz
airgap-bundle-.../bundle-versions.txt
airgap-bundle-.../container-images.txt
airgap-bundle-.../airgap-env.sh
airgap-bundle-.../checksums.sha256
```

**Pass:** All paths present, script exits 0.
**Fail:** Any expected path missing or non-zero exit.

---

### T2-2: Bundle checksums self-verify

```bash
BUNDLE_DIR=$(tar -tzf /tmp/test-bundle/airgap-bundle-*.tar.gz | head -1 | cut -d/ -f1)
tar -xzf /tmp/test-bundle/airgap-bundle-*.tar.gz -C /tmp/test-bundle
cd /tmp/test-bundle/${BUNDLE_DIR}
sha256sum --check checksums.sha256 --quiet
echo "exit: $?"
```

**Pass:** Exit 0, no output.
**Fail:** Any "FAILED" line or non-zero exit.

---

### T2-3: Bundled k0s binary is correct version

```bash
BUNDLE_DIR=$(ls -d /tmp/test-bundle/airgap-bundle-*)
chmod +x "${BUNDLE_DIR}/binaries/k0s"
"${BUNDLE_DIR}/binaries/k0s" version
cat "${BUNDLE_DIR}/binaries/k0s.version"
```

**Pass:** Version output matches `--k0s-version` flag value.
**Fail:** Different version or crash.

---

### T2-4: Bundled Helm charts are valid

```bash
BUNDLE_DIR=$(ls -d /tmp/test-bundle/airgap-bundle-*)
for chart in "${BUNDLE_DIR}"/charts/*.tgz; do
  helm show chart "$chart" | grep "^name:" \
    && echo "  → OK: $(basename $chart)" \
    || echo "  → FAIL: $(basename $chart)"
done
```

**Pass:** All charts print a name line followed by `OK`.
**Fail:** Any `FAIL` or helm error.

---

### T2-5: `airgap-env.sh` syntax valid

```bash
BUNDLE_DIR=$(ls -d /tmp/test-bundle/airgap-bundle-*)
bash -n "${BUNDLE_DIR}/airgap-env.sh" && echo "Syntax OK"
```

**Pass:** "Syntax OK".

---

### T2-6: `install_from_airgap_bundle.sh` error handling

```bash
./tools/cluster_setup/install_from_airgap_bundle.sh
# Expected: "No bundle specified" error, exit 1

./tools/cluster_setup/install_from_airgap_bundle.sh --bundle /nonexistent.tar.gz
# Expected: "Bundle file not found" error, exit 1
```

**Pass:** Descriptive error message, exit 1.
**Fail:** Crash, stack trace, or silent exit 0.

---

### T2-7: `validate` subcommand catches missing config values

```bash
CONFIG_FILE=tools/cluster_setup/k0s-cluster-config.yaml \
  ./tools/cluster_setup/k0s_cluster_with_stack.sh validate
```

**Pass:** Prints a checklist with ✔/✖/! symbols, exits 1 because placeholder `CHANGE THIS` values are detected.
**Fail:** Crashes or exits 0 on a config with unfilled placeholders.

---

### T2-8: `diagnose` subcommand runs without a live cluster

```bash
CONFIG_FILE=tools/cluster_setup/k0s-cluster-config.yaml \
  ./tools/cluster_setup/k0s_cluster_with_stack.sh diagnose
```

**Pass:** Prints "Cluster not reachable" warning, produces a `.tar.gz` in `logs/`, exits 0.
**Fail:** Crashes or hangs.

---

### T2-9: Log rotation deletes oldest logs when > 10 exist

```bash
mkdir -p /tmp/rot-test
for i in $(seq 1 12); do
  touch "/tmp/rot-test/k0s-install-2025-01-0${i:0:1}_0${i}-00-00.log"
done
ls /tmp/rot-test/ | wc -l  # Should be 12

LOG_DIR=/tmp/rot-test bash -c '
  source tools/cluster_setup/k0s_cluster_with_stack.sh 2>/dev/null || true' 2>/dev/null

ls /tmp/rot-test/ | wc -l  # Should be ≤ 11
```

**Pass:** Count drops to ≤ 11.
**Fail:** Still 12+ — rotation did not fire.

---

### T2-10: `wait_for_dependency()` times out cleanly

```bash
bash -c '
  source tools/cluster_setup/k0s_cluster_with_stack.sh 2>/dev/null
  wait_for_dependency "unreachable host" "ping -c1 192.0.2.1 >/dev/null 2>&1" 10
' 2>&1
echo "exit: $?"
```

**Pass:** Prints timeout message, exits 1 after ~10 s.
**Fail:** Hangs or exits 0.

---

### T2-11: `show_install_plan` aborts on non-"yes" input

```bash
echo "no" | CONFIG_FILE=tools/cluster_setup/k0s-cluster-config.yaml \
  AUTO_APPROVE=false \
  ./tools/cluster_setup/k0s_cluster_with_stack.sh install 2>&1 | tail -5
echo "exit: $?"
```

**Pass:** "Aborted by user", exit 0 — no cluster changes made.
**Fail:** Proceeds past the plan prompt.

---

### T2-12: `delete` aborts on wrong cluster name input

```bash
echo "wrong-name" | AUTO_APPROVE=false \
  CONFIG_FILE=tools/cluster_setup/k0s-cluster-config.yaml \
  ./tools/cluster_setup/k0s_cluster_with_stack.sh delete 2>&1 | tail -3
echo "exit: $?"
```

**Pass:** "Aborted — input did not match cluster name", exit 0.
**Fail:** Proceeds to deletion.

---

### T2-13: `wait_for_dependency()` wired into `ensure_s3compat_credentials` — code review

```bash
grep -A25 "^ensure_s3compat_credentials" \
  tools/cluster_setup/k0s_cluster_with_stack.sh \
  | grep "wait_for_dependency"
```

**Pass:** `wait_for_dependency` call is present in the function body.
**Fail:** No match — the wait was not wired in.

---

### T2-14: HuggingFace wait is skipped in air-gap mode — code review

```bash
grep -A5 "AIRGAP_MODE.*true.*skip.*HuggingFace\|skipping HuggingFace" \
  tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** Log line confirming skip is present.
**Fail:** No guard — air-gap installs would attempt HuggingFace connectivity check unnecessarily.

---

### T2-15: NVIDIA repo wait is skipped in air-gap mode — code review

```bash
grep -A5 "AIRGAP_MODE.*true.*skip.*NVIDIA\|skipping NVIDIA repo" \
  tools/cluster_setup/k0s_cluster_with_stack.sh
```

**Pass:** Log line confirming skip is present.
**Fail:** No guard — air-gap GPU installs would fail the connectivity check instead of proceeding with pre-installed drivers.

---

### T2-16: `prepare_airgap_bundle.sh --gpu-os` validation rejects unsupported values

```bash
./tools/cluster_setup/prepare_airgap_bundle.sh --gpu-os rhel10 --output-dir /tmp/dummy 2>&1
echo "exit: $?"

./tools/cluster_setup/prepare_airgap_bundle.sh --gpu-os amzn2023 --output-dir /tmp/dummy 2>&1
echo "exit: $?"
```

**Pass:** Both print an "ERROR: ... not supported" message and exit 1 immediately without downloading anything.
**Fail:** Either proceeds past the validation gate or exits 0.

---

### T2-17: `prepare_airgap_bundle.sh --gpu-os rhel9` downloads all 4 GPU package files

```bash
./tools/cluster_setup/prepare_airgap_bundle.sh \
  --output-dir /tmp/test-bundle-gpu \
  --gpu-os rhel9 \
  --k0s-version v1.31.2+k0s.0
```

Verify the packages/ directory:

```bash
BUNDLE_DIR=$(tar -tzf /tmp/test-bundle-gpu/airgap-bundle-*.tar.gz | head -1 | cut -d/ -f1)
tar -tzf /tmp/test-bundle-gpu/airgap-bundle-*.tar.gz | grep "packages/"
```

Expected:
```
airgap-bundle-.../packages/epel-release-latest-9.noarch.rpm
airgap-bundle-.../packages/cuda-rhel9.repo
airgap-bundle-.../packages/nvidia-container-toolkit.repo
airgap-bundle-.../packages/PyYAML-*.whl
airgap-bundle-.../packages/pyyaml.filename
```

**Pass:** All 5 paths present and files non-empty; script exits 0.
**Fail:** Any path missing or empty file.

---

### T2-18: Bundle checksums include packages/ files

```bash
BUNDLE_DIR=$(tar -tzf /tmp/test-bundle-gpu/airgap-bundle-*.tar.gz | head -1 | cut -d/ -f1)
tar -xzf /tmp/test-bundle-gpu/airgap-bundle-*.tar.gz -C /tmp/test-bundle-gpu
grep "packages/" "/tmp/test-bundle-gpu/${BUNDLE_DIR}/checksums.sha256"
```

**Pass:** At least 4 lines — each GPU package file checksummed.
**Fail:** 0 lines — packages/ not included in checksums.sha256.

---

### T2-19: `install_from_airgap_bundle.sh` exports `AIRGAP_PYYAML_WHEEL_PATH` from bundle

```bash
# Use the bundle created in T2-17
BUNDLE=/tmp/test-bundle-gpu/airgap-bundle-*.tar.gz

# Dry-run: source the env setup portion and check the variable
bash -c "
  BUNDLE_DIR=\$(tar -tzf ${BUNDLE} | head -1 | cut -d/ -f1)
  tar -xzf ${BUNDLE} -C /tmp/pyyaml-test 2>/dev/null
  PYYAML_FNAME=\$(cat /tmp/pyyaml-test/\${BUNDLE_DIR}/packages/pyyaml.filename 2>/dev/null)
  echo \"PYYAML_FNAME: \${PYYAML_FNAME}\"
  [[ -f \"/tmp/pyyaml-test/\${BUNDLE_DIR}/packages/\${PYYAML_FNAME}\" ]] \
    && echo 'WHEEL: found' \
    || echo 'WHEEL: missing'
"
```

**Pass:** Both `PYYAML_FNAME` (non-empty) and `WHEEL: found` printed.
**Fail:** Either empty or `WHEEL: missing` — pointer file or wheel absent.

---

### T2-20: `bundle-versions.txt` includes gpu_node_os field

```bash
BUNDLE_DIR=$(tar -tzf /tmp/test-bundle-gpu/airgap-bundle-*.tar.gz | head -1 | cut -d/ -f1)
grep "gpu_node_os" "/tmp/test-bundle-gpu/${BUNDLE_DIR}/bundle-versions.txt"
```

**Pass:** Line `gpu_node_os=rhel9` present.
**Fail:** Missing — consumers cannot verify what GPU OS the bundle targets.

---

### T2-21: `--help` output of `prepare_airgap_bundle.sh` references `--gpu-os` and package strategy notes

```bash
./tools/cluster_setup/prepare_airgap_bundle.sh --help | grep -E "gpu.os|GPU_NODE_OS|EPEL|CUDA|NVIDIA_CTK|PyYAML|rhel9"
```

**Pass:** At least 4 matching lines covering the new options and package notes.
**Fail:** Fewer — new options not documented in help output.

---

## Tier 3 — Live cluster (real machines or EC2)

### T3-1: Normal (online) install still works — regression test

No env vars set. Confirms `${VAR:-default}` changes did not break the happy path.

```bash
CONFIG_FILE=./my-k0s-config.yaml ./k0s_cluster_with_stack.sh install
```

**Pass criteria:**
- All Helm charts install (prometheus, otel, kuberay, metallb)
- cert-manager and local-path-provisioner apply cleanly
- NVIDIA device plugin loads on GPU nodes
- `kubectl get nodes` shows all nodes Ready
- AI Platform pods reach Running state

**Regression check:** Compare component versions installed vs. pinned values in the script — no chart version drift.

---

### T3-2: Full air-gap install from bundle

Block outbound internet on all cluster nodes (firewall/security group). On install machine:

```bash
./install_from_airgap_bundle.sh \
  --bundle airgap-bundle-<timestamp>.tar.gz \
  --config my-k0s-config.yaml
```

**Pass criteria:**
- No `curl: (6) Could not resolve host` errors in logs
- All 9 "Using local chart: ..." log lines appear
- "Checksums verified OK" log line appears
- Same end-state as T3-1

Verify in logs:
```
[INFO]  Using local chart: .../charts/kube-prometheus-stack-*.tgz
[INFO]  Using local chart: .../charts/opentelemetry-operator-*.tgz
[INFO]  Using local chart: .../charts/kuberay-operator-1.2.2.tgz
[INFO]  Using local chart: .../charts/metallb-0.14.8.tgz
```

---

### T3-3: Partial env-var override (single component)

```bash
export CERT_MANAGER_MANIFEST_URL="file:///tmp/cert-manager.yaml"
CONFIG_FILE=./my-k0s-config.yaml ./k0s_cluster_with_stack.sh install
```

**Pass:** cert-manager installs from local file; all other components use internet as normal.
**Fail:** Any unrelated component tries to use `file://` paths or fails.

---

### T3-4: Timestamps appear in session log file

```bash
grep -c "20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]" \
  logs/k0s-install-*.log | head -1
```

**Pass:** Count > 100.
**Fail:** 0 — timestamps not written.

---

### T3-5: Step summary table appears at end of install

```bash
grep "INSTALL SUMMARY"              logs/k0s-install-*.log | tail -1
grep "steps completed\|step(s) failed" logs/k0s-install-*.log | tail -1
```

**Pass:** Both lines present.
**Fail:** Either missing.

---

### T3-6: Phase section markers are grep-able in logs

```bash
grep "════ PHASE:" logs/k0s-install-*.log
```

**Pass:** All four phases present: `Preflight`, `Model Staging`, `AI Platform Stack`, `Health Verification`.
**Fail:** Any phase missing.

---

### T3-7: `diagnose` produces a complete bundle on a live cluster

```bash
CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh diagnose
ls -lh logs/splunk-ai-diagnose-*.tar.gz | tail -1
tar -tzf logs/splunk-ai-diagnose-*.tar.gz | grep -E "pods.txt|events.txt|nodes.txt"
```

**Pass:** Bundle exists and contains `pods.txt`, `events.txt`, `nodes.txt`.
**Fail:** Bundle missing, empty, or missing key files.

---

### T3-8: err() message includes log file path on failure

Trigger a deliberate failure (e.g. wrong controller IP in config):

```bash
grep "Log file:" logs/k0s-install-*.log | tail -3
grep "run.*diagnose"               logs/k0s-install-*.log | tail -3
```

**Pass:** Both "Log file:" and "run diagnose" appear near the error.
**Fail:** Not present.

---

### T3-9: Object store wait fires and resolves during online install

During T3-1 (online install), check the log for the wait message:

```bash
grep "Waiting for external dependency.*object store" logs/k0s-install-*.log | tail -3
grep "object store.*ready"                           logs/k0s-install-*.log | tail -3
```

**Pass:** Both lines present — wait fired and resolved immediately because the store was already up.
**Fail:** Neither line present — `wait_for_dependency` was not called.

---

### T3-10: Object store wait pauses when store is not yet up (interactive test)

Start an install where the MinIO endpoint is unreachable at install time (e.g. stop MinIO, let install start, restart MinIO within 30 s):

```bash
# Stop MinIO on its host
ssh minio-host "sudo systemctl stop minio"

# Start install
CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install &
INSTALL_PID=$!

# Wait ~15s then restart MinIO
sleep 15
ssh minio-host "sudo systemctl start minio"

# Install should continue automatically
wait $INSTALL_PID
```

**Pass:** Log shows "not ready yet. Retrying...", then "ready" after MinIO comes back — install continues without operator intervention.
**Fail:** Install immediately errors with "connection refused" before MinIO started.

---

### T3-11: Air-gap install skips HuggingFace and NVIDIA repo waits

During T3-2 (full air-gap install):

```bash
# HuggingFace wait must NOT appear (AIRGAP_MODE=true, modelStaging irrelevant)
grep "Waiting for external dependency.*HuggingFace" logs/k0s-install-*.log | tail -3
# Expected: no output

# NVIDIA skip message must appear for each GPU node
grep "AIRGAP_MODE=true.*NVIDIA\|skipping NVIDIA repo" logs/k0s-install-*.log | tail -3
# Expected: one line per GPU worker

# Object store wait must still appear (store is always external, even in air-gap)
grep "Waiting for external dependency.*object store" logs/k0s-install-*.log | tail -3
# Expected: present
```

**Pass:** HuggingFace wait absent, NVIDIA skip present per GPU node, object store wait present.
**Fail:** HuggingFace wait fires in air-gap mode (wastes time on an unreachable host), or object store wait is missing.

---

### T3-12: `_check_node_os()` passes on RHEL 9 (and compatible) nodes

Run the installer against a RHEL 9 (or Rocky 9 / AlmaLinux 9) cluster:

```bash
grep "OS check passed" logs/k0s-install-*.log
```

**Pass:** One `OS check passed` line per node (controller + workers + GPU workers).
**Fail:** Any `Unsupported OS` error — RHEL 9 incorrectly rejected.

Repeat with Rocky Linux 9 and AlmaLinux 9 if available. Both should pass.

---

### T3-13: `_check_node_os()` blocks install on unsupported OS

Attempt an install against a node running an unsupported OS (e.g. Ubuntu 22.04 or RHEL 8):

```bash
# Run installer — expect failure at OS gate, before any k0s components are touched
CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install 2>&1 | grep -E "Unsupported OS|Only RHEL 9"
echo "exit: $?"
```

**Pass:** Error message names the detected OS and mentions `FORCE_UNSUPPORTED_OS=1`; installer exits non-zero before touching k0s.
**Fail:** Install proceeds on unsupported OS, or error message is unhelpful.

---

### T3-14: `FORCE_UNSUPPORTED_OS=1` downgrades error to warning and continues

```bash
FORCE_UNSUPPORTED_OS=1 CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install 2>&1 \
  | grep -E "Unsupported OS|WARN"
```

**Pass:** Warning message (not error) is printed; install continues past the OS check.
**Fail:** Install still exits — `FORCE_UNSUPPORTED_OS=1` guard not working.

---

### T3-15: AIRGAP_MODE=true hard-fails when nvidia-smi absent on GPU node

Set up a GPU node with no NVIDIA drivers pre-installed and run the installer with `AIRGAP_MODE=true`:

```bash
AIRGAP_MODE=true CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install 2>&1 \
  | grep -E "AIRGAP_MODE.*nvidia-smi|Pre-install the NVIDIA driver"
echo "exit: $?"
```

**Pass:** Error message references `AIRGAP_MODE=true`, missing `nvidia-smi`, and points to `AIRGAP.md`; exit non-zero.
**Fail:** Installer attempts package downloads (which timeout) or exits with an unhelpful message.

---

### T3-16: GPU package URL overrides redirect install to local mirror

Set up a local HTTP server serving the EPEL RPM, CUDA repo, and CTK repo files. Export the overrides and run the installer:

```bash
export EPEL_RPM_URL_OVERRIDE="http://mirror.test.internal/epel-release-latest-9.noarch.rpm"
export CUDA_REPO_URL_OVERRIDE="http://mirror.test.internal/cuda-rhel9.repo"
export NVIDIA_CTK_REPO_URL_OVERRIDE="http://mirror.test.internal/nvidia-container-toolkit.repo"

CONFIG_FILE=./my-config.yaml ./k0s_cluster_with_stack.sh install
```

Verify in the install log that the overridden URLs (not the default NVIDIA/Fedora CDN URLs) were fetched:

```bash
grep "mirror.test.internal" logs/k0s-install-*.log
```

**Pass:** All 3 override URLs appear in the log; no `dl.fedoraproject.org` or `developer.download.nvidia.com` requests on the GPU node.
**Fail:** Default URLs still used — `${VAR:-default}` substitution not taking effect.

---

### T3-17: `AIRGAP_PYYAML_WHEEL_PATH` installs pyyaml offline on all nodes

Set `AIRGAP_PYYAML_WHEEL_PATH` to the bundled `.whl` file and run the installer. On each node after install:

```bash
python3 -c "import yaml; print(yaml.__version__)"
```

And in the install log:

```bash
grep "pip3.*no-index\|AIRGAP_PYYAML_WHEEL_PATH\|pyyaml.*wheel" logs/k0s-install-*.log
```

**Pass:** `yaml` imports successfully on each node; log shows offline pip3 install path (not `dnf install python3-pyyaml`).
**Fail:** `dnf install` called for pyyaml when wheel path was set, or import fails.

---

### T3-18: Full air-gap install with bundled GPU packages (end-to-end)

Use the bundle from T2-17 (which includes the `packages/` directory). Pre-configure nodes with no NVIDIA drivers. Run the installer with `install_from_airgap_bundle.sh`:

1. `install_from_airgap_bundle.sh` should automatically set `AIRGAP_PYYAML_WHEEL_PATH`
2. On GPU nodes, follow Strategy 1 from AIRGAP.md using the bundled package files before running the installer
3. Run the installer — it should detect `nvidia-smi` and skip driver install

```bash
grep "nvidia-smi.*found\|skipping.*driver" logs/k0s-install-*.log
grep "pip3.*no-index\|pyyaml.*offline" logs/k0s-install-*.log
```

**Pass:** Log shows nvidia-smi detected on GPU nodes (skipping install), and pyyaml installed from wheel on all nodes.
**Fail:** Either driver install attempted in air-gap, or pyyaml falls back to dnf.

---

## Tier 4 — EC2-based testing

### Why EC2

EC2 instances exactly replicate the customer bare-metal environment: fresh OS, real SSH, real NVIDIA drivers, real network constraints. No special hardware needed — instances launch in minutes and can be terminated immediately after testing.

### Minimum instance setup

| Role | Recommended type | OS | Purpose |
|---|---|---|---|
| Install machine | `t3.medium` | Amazon Linux 2023 or Ubuntu 22.04 | Where `k0s_cluster_with_stack.sh` runs |
| Controller node | `t3.xlarge` | Amazon Linux 2023 | k0s control plane |
| CPU worker | `t3.2xlarge` | Amazon Linux 2023 | Weaviate, saia-api, fluent-bit |
| GPU worker | `g4dn.12xlarge` (4× T4) or `g5.12xlarge` (4× A10G) | Amazon Linux 2023 | Ray GPU workers, model loading |

### Launch instances

```bash
# Security group: allow inbound 22, 6443, 8080, 10250 within the VPC
aws ec2 run-instances \
  --image-id ami-0c101f26f147fa7fd \
  --instance-type t3.xlarge \
  --key-name my-test-key \
  --security-group-ids sg-xxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k0s-controller}]' \
  --count 1

# Repeat with t3.2xlarge for cpu-worker, g4dn.12xlarge for gpu-worker
```

### Test config for EC2

```yaml
# ec2-test-config.yaml
cluster:
  name: ec2-test
  sshKeyPath: ~/.ssh/my-test-key.pem
  sshUser: ec2-user       # Amazon Linux; use 'ubuntu' for Ubuntu AMIs

nodes:
  existingIPs:
    controllers:
      - <controller-private-ip>
    workers:
      - <cpu-worker-private-ip>
      - <gpu-worker-private-ip>

storage:
  objectStore:
    type: "minio"
    bucket: "ai-platform-test"
    endpoint: "http://<minio-ip>:9000"
    auth:
      rootUser: "minioadmin"
      rootPassword: "minioadmin"

images:
  registry: "<your-ecr-or-registry>"
  operator:
    image: "<your-operator-image>"
```

### Mapping tier-3 tests to EC2 actions

| Test | EC2 action |
|---|---|
| T3-1 (normal install) | Run `install` from install machine with internet; verify stack via `kubectl` |
| T3-2 (air-gap) | Add outbound-deny security group rule to all nodes except install machine; run `install_from_airgap_bundle.sh` |
| T3-3 (partial override) | Set one `*_MANIFEST_URL` to a pre-signed S3 URL; run install normally |
| T3-4..T3-8 (UX changes) | Inspect log files and terminal output after T3-1 run |
| Delete confirmation (T2-12) | Run `delete` interactively on install machine |

### Cost estimate

| Run type | Duration | Cost (approx) |
|---|---|---|
| T3-1 (online install) | ~1 hr | ~$5–8 (dominated by `g4dn.12xlarge` at ~$3.91/hr) |
| T3-2 (air-gap) | ~1 hr | ~$5–8 |
| T3-3 (partial override) | ~1 hr | ~$5–8 |

Use Spot instances to cut cost by ~70%. Terminate all instances immediately after each run.

### Visual review — DEPLOYMENT_GUIDE.md diagrams

Open the file on GitHub (or in a Mermaid-aware viewer) and confirm all 14 diagrams render without syntax errors:

```bash
# Quick local check — count mermaid blocks to catch accidental deletions
grep -c '```mermaid' tools/cluster_setup/DEPLOYMENT_GUIDE.md
# Expected: 14
```

For each diagram verify:
- No "Syntax error" overlay in the GitHub renderer
- Node labels are legible (no truncation)
- Arrows point in the correct direction
- Air-gap and non-air-gap paths are visually distinct

The 14 diagrams to review (in order):
1. Non-air-gap deployment overview (flowchart)
2. Non-air-gap install sequence (sequenceDiagram)
3. Network requirements (flowchart)
4. Air-gap deployment overview (flowchart)
5. Air-gap install sequence (sequenceDiagram)
6. Air-gap network architecture (flowchart)
7. Bundle contents (graph)
8. GPU node strategy selection (flowchart)
9. Strategy 1 — pre-install steps (flowchart)
10. Strategy 2 — local mirror setup (flowchart)
11. Full cluster architecture (graph)
12. Install state machine (stateDiagram-v2)
13. Troubleshooting decision tree (flowchart)
14. Component dependency graph (graph)

**Pass:** All 14 render cleanly on GitHub with correct labels and flow directions.
**Fail:** Any diagram shows a syntax error or visually broken layout.

---

### Teardown

```bash
# Clean up Kubernetes resources and stop k0s on all nodes
CONFIG_FILE=./ec2-test-config.yaml AUTO_APPROVE=true \
  ./tools/cluster_setup/k0s_cluster_with_stack.sh clean-all

# Terminate EC2 instances
aws ec2 terminate-instances --instance-ids i-xxx i-yyy i-zzz i-www
```

---

## Test summary matrix

| ID | What | Needs cluster | Needs internet | Approx time | Gating for merge |
|---|---|---|---|---|---|
| T1-1 | Bash syntax | No | No | < 1 min | Yes |
| T1-2 | `--help` output | No | No | < 1 min | Yes |
| T1-3 | H100 removed from k0s files | No | No | < 1 min | Yes |
| T1-4 | Gemma present in all docs | No | No | < 1 min | Yes |
| T1-5 | Model list consistency | No | No | < 1 min | Yes |
| T1-6 | All 9 env vars wired in | No | No | < 1 min | Yes |
| T1-7 | Original URLs still present as defaults | No | No | < 1 min | Yes |
| T1-8 | Internal doc links resolve | No | No | < 1 min | Yes |
| T1-9 | Timestamps in log/warn/err | No | No | < 1 min | Yes |
| T1-10 | New subcommands in dispatch | No | No | < 1 min | Yes |
| T1-11 | Log rotation code present | No | No | < 1 min | Yes |
| T1-12 | Confirmation prompt in main_delete | No | No | < 1 min | Yes |
| T1-13 | AUTO_APPROVE bypasses prompts | No | No | < 1 min | Yes |
| T2-1 | Bundle end-to-end | No | Yes | ~5 min | Recommended |
| T2-2 | Bundle checksums self-verify | No | No | < 1 min | Recommended |
| T2-3 | k0s binary correct version | No | No | < 1 min | Recommended |
| T2-4 | Helm charts valid | No | No | < 1 min | Recommended |
| T2-5 | `airgap-env.sh` syntax | No | No | < 1 min | Recommended |
| T2-6 | Error handling on bad args | No | No | < 1 min | Recommended |
| T2-7 | `validate` catches bad config | No | No | < 1 min | Recommended |
| T2-8 | `diagnose` without cluster | No | No | < 1 min | Recommended |
| T2-9 | Log rotation deletes old logs | No | No | < 1 min | Recommended |
| T2-10 | `wait_for_dependency` timeout | No | No | ~10 s | Recommended |
| T2-11 | Install plan abort on non-yes | No | No | < 1 min | Recommended |
| T2-12 | Delete aborts on wrong name | No | No | < 1 min | Recommended |
| T2-13 | Object store wait wired into credentials function | No | No | < 1 min | Yes |
| T2-14 | HuggingFace wait skipped in air-gap mode | No | No | < 1 min | Yes |
| T2-15 | NVIDIA repo wait skipped in air-gap mode | No | No | < 1 min | Yes |
| T3-1 | Online install regression | Yes | Yes | ~45 min | Yes (before shipping) |
| T3-2 | Full air-gap install | Yes | No (blocked) | ~60 min | Yes (for air-gap customers) |
| T3-3 | Partial env-var override | Yes | Yes | ~45 min | Recommended |
| T3-4 | Timestamps in log file | Yes | Yes | Part of T3-1 | Yes |
| T3-5 | Step summary table in log | Yes | Yes | Part of T3-1 | Yes |
| T3-6 | Phase markers grep-able | Yes | Yes | Part of T3-1 | Yes |
| T3-7 | `diagnose` full bundle | Yes | Yes | ~2 min | Recommended |
| T3-8 | err() shows log path | Yes | Yes | Part of T3-1 | Yes |
| T3-9 | Object store wait fires and resolves | Yes | Yes | Part of T3-1 | Yes (for air-gap customers) |
| T3-10 | Object store wait pauses when store is down | Yes | Yes | ~5 min interactive | Recommended |
| T3-11 | Air-gap skips HuggingFace + NVIDIA waits, keeps object store wait | Yes | No (blocked) | Part of T3-2 | Yes (for air-gap customers) |
| T1-14 | `_check_node_os()` defined + wired at both call sites | No | No | < 1 min | Yes |
| T1-15 | `FORCE_UNSUPPORTED_OS` escape hatch present | No | No | < 1 min | Yes |
| T1-16 | AIRGAP hard-fail code path in `_install_nvidia_on_node` | No | No | < 1 min | Yes |
| T1-17 | GPU package URL override vars wired in | No | No | < 1 min | Yes |
| T1-18 | Original GPU package URLs still present as defaults | No | No | < 1 min | Yes |
| T1-19 | `AIRGAP_PYYAML_WHEEL_PATH` branch present in installer + bundle script | No | No | < 1 min | Yes |
| T1-20 | RHEL 10 / AL2023 removed from all k0s docs | No | No | < 1 min | Yes |
| T1-21 | Supported OS stated consistently (RHEL 9 + compatible) | No | No | < 1 min | Yes |
| T1-22 | VOC Portal removed from all k0s docs | No | No | < 1 min | Yes |
| T1-23 | `defaultAcceleratorType` — L40S required, no "e.g." | No | No | < 1 min | Yes |
| T1-24 | 8 × L40S total called out in K0S_QUICKSTART + DEPLOYMENT_GUIDE | No | No | < 1 min | Yes |
| T1-25 | Staging requirements (250 GB / 16 GB) in all 3 docs | No | No | < 1 min | Yes |
| T1-26 | `--gpu-os` argument parsing present in `prepare_airgap_bundle.sh` | No | No | < 1 min | Yes |
| T1-27 | `--gpu-os` validation gate rejects non-rhel9 — code review | No | No | < 1 min | Yes |
| T1-28 | `packages/` section integrated into `prepare_airgap_bundle.sh` | No | No | < 1 min | Yes |
| T1-29 | `DEPLOYMENT_GUIDE.md` exists with 14 Mermaid diagrams | No | No | < 1 min | Yes |
| T2-16 | `--gpu-os` validation rejects unsupported values (live run) | No | No | < 1 min | Yes |
| T2-17 | `packages/` dir in bundle — all 4 GPU package files present | No | Yes | ~5 min | Recommended |
| T2-18 | Bundle checksums include `packages/` files | No | No | < 1 min | Recommended |
| T2-19 | `AIRGAP_PYYAML_WHEEL_PATH` exported correctly from bundle | No | No | < 1 min | Recommended |
| T2-20 | `bundle-versions.txt` includes `gpu_node_os` field | No | No | < 1 min | Recommended |
| T2-21 | `prepare_airgap_bundle.sh --help` documents new GPU options | No | No | < 1 min | Yes |
| T3-12 | `_check_node_os()` passes on RHEL 9 / Rocky 9 / AlmaLinux 9 | Yes | Yes | Part of T3-1 | Yes (before shipping) |
| T3-13 | `_check_node_os()` blocks install on unsupported OS | Yes | Yes | ~5 min | Yes (before shipping) |
| T3-14 | `FORCE_UNSUPPORTED_OS=1` downgrades error to warning | Yes | Yes | ~5 min | Recommended |
| T3-15 | AIRGAP_MODE hard-fails when nvidia-smi absent on GPU node | Yes | No | ~5 min | Yes (for air-gap customers) |
| T3-16 | GPU package URL overrides redirect to local mirror | Yes | Yes | ~30 min | Recommended |
| T3-17 | `AIRGAP_PYYAML_WHEEL_PATH` installs pyyaml offline on all nodes | Yes | No | Part of T3-2 | Yes (for air-gap customers) |
| T3-18 | Full air-gap install with bundled GPU packages end-to-end | Yes | No (blocked) | ~60 min | Yes (for air-gap customers) |
