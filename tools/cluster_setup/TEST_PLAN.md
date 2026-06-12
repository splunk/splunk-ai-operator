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
