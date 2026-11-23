# MPR-193 validation record

Scope: the fail-closed offline import, preflight and install primitive described in
[airgap-bundle.md](airgap-bundle.md). Design source: the Agent-Runtime / AI-Tier
Integration ERD (version 8). The captured smoke output is in
[validation/mpr-193-smoke.txt](validation/mpr-193-smoke.txt).

## Completion criteria

| # | Criterion | Implementation | Evidence |
|---|---|---|---|
| 1 | Before changing cluster state, check the snapshot, the bundle's checksums, architecture, binaries/charts/manifests/packages, image mirror mappings and fullfeature model references; for fullfeature the GPU driver, runtime and capacity; fail by name with nonzero status | `airgap-bundle verify` (bundle and install scope), run by the installer as the last preflight check, before model staging (the first change). The two-stage GPU rule: present or installable from the bundle before any change, the installer's existing health and capacity gates after provisioning | `TestVerify_*` (65 package tests and subtests), the installer suite; smoke steps 3-4 on real nodes and a real mirror |
| 2 | Every applied image resolves to the private mirror by digest; Secret references for registry auth; no public fallback | `image-snapshot install-config` generates the digest-pinned settings and the install preflight compares the effective configuration with the snapshot. Add-on and k0s images come from verified archives, digest-checked against the snapshot and again on each node after import. `images.imagePullSecrets` Secret references. Every download fallback fails by name in air-gap mode | `TestInstallConfig_*` (round trip through `compare`), `TestVerify_TheInstallConfigurationMustUseTheMirrorByDigest`, `TestVerify_ArchiveImagesMustBeTheSnapshotsImages`, installer suites "no download fallback", "pull Secrets by reference" and "node digests"; smoke step 6 |
| 3 | Import idempotent for an already imported bundle; retry after an interrupted transfer without corrupting the manifest or leaving a partially accepted bundle | `airgap-bundle import`: verify the source first, assemble in `.partial-<id>`, reuse intact files, accept with one rename; refuse a damaged or different bundle under the same ID | `TestImport_*`; smoke step 5b (a second import changes nothing; a `SIGKILL`ed import resumes; a tampered import is refused) |
| 4 | A representative network-isolated installer smoke: import and reach basic Kubernetes readiness with public egress blocked; evidence of image-pull sources and egress attempts; cpuOnly and fullfeature inventories distinguished | Smoke on fullfeature-dev | Smoke step 6: a cpuOnly AIPlatform `Ready=True`, every pod image from the mirror by digest, the mirror's log showing each CPU worker's containerd pulling them, and Docker Hub, ECR and 1.1.1.1 blocked from inside the namespace; the profiles' inventories |
| 5 | Removing one image, one binary or chart and one model reference each fails before installation with a specific error and no public pull | install preflight | `TestVerify_AnImageMissingFromTheMirror...`, `...AMissingBinaryOrChart...`, `...AMissingModelArtifact...`; smoke step 5a on the real bundle and mirror |
| 6 | A documented command with stable inputs and exit codes and sanitized logs for MPR-190/MPR-192 | [airgap-bundle.md](airgap-bundle.md): commands, inputs, exit codes 0/1/2, finding codes, bundle layout, host facts schema, outputs and the job steps | `TestUsageErrorsExitTwo`, `TestVerify_FailuresAreNamedExitOneAndAreSanitized`, `TestImport_ARefusedImportExitsOne` |

Jira comment (2026-11-17), "the pull secret is needed on every pod": every
`images.imagePullSecrets` Secret is listed on the AIPlatform CR, which the operator passes
to every pod, the schema Job included. It is also listed on the operator and Splunk Operator
Deployments.

## Tests

| Check | Result |
|---|---|
| Go: `internal/airgapbundle`, `cmd/airgap-bundle`, `internal/imagesnapshot`, `cmd/image-snapshot` | 219 tests and subtests pass, 0 fail; race detector clean; statement coverage 87.6%, 88.1%, 92.0% and 86.5% |
| Mutation checks on `internal/airgapbundle` | 50 deliberate breakages, each caught by a failing test (checksums, sizes, unlisted files, component gates, MetalLB, archive lists, digests, aliases and architecture, the snapshot and mirror checks, the install-configuration comparison, facts, platform, every GPU rule, models, the import's verification, resume, pruning and refusals, write-once, path safety) |
| Mutation checks on `image-snapshot install-config` | 12 deliberate breakages, each caught (including the profile filter, the unknown-profile refusal and the CLI's required `--profile`) |
| Mutation checks on the installer's target-cluster and registry-credential code | 19 deliberate breakages, each caught (the target-cluster choice, read-only `get`, SSH quoting, caching, the readers' route; key matching, `username`/`password`, Docker Hub, Secret-sourced credentials and their type, first-reference-wins, file mode, the message) |
| Installer suite (`test_k0s_cluster_with_stack.sh`) | 709 passed and the same 12 pre-existing failures as the base (the 48 tests of the second review round included). The OpenShift suite passes, 238 tests |
| Module | `go build ./...`, `go vet`; all 23 non-e2e packages pass |
| Real format | the archive reader was checked against k0s v1.36.3's `airgap bundle-artifacts` source and against real archives it wrote during the smoke |

## The smoke (fullfeature-dev, 2026-11-20 and 2026-11-23)

1. **Real bundle.** It was staged on the controller the way `airgap_install.sh` stages one:
   - the k0s v1.36.3 binary, yq and the tool;
   - k0s's own `airgap list-images --all` (13 images) and `airgap bundle-artifacts`;
   - the add-on images grepped from the cert-manager and local-path manifests (4);
   - a PyYAML wheel, `bundle-versions.txt` and `checksums.sha256`.

   The bundle is 744 MB. The installer's RHEL-only package steps were left out; these hosts
   are Ubuntu.
2. **Snapshot.** All 23 inventory images were resolved, mirrored by digest and verified: the
   4 ECR candidates, 13 k0s images, 4 add-ons, Fluent Bit and nginx.
3. **Bundle check.** It passes for cpuOnly. For fullfeature it reports
   `MODEL_INVENTORY_MISSING`, as expected for a bundle built without the model configuration.
4. **Install preflight.** It passes for cpuOnly against the real mirror, with the generated
   settings, which are all `10.0.39.38:5099/ai-tier/…@sha256:…`.
5. **Negative checks.** Each passes again after it is restored:
   - the Fluent Bit manifest deleted from the mirror gives `MIRROR_MISSING_IMAGE fluent-bit`;
   - `binaries/k0s` removed gives `BUNDLE_FILE_MISSING binaries/k0s`;
   - one of the 10 real fullfeature models not staged gives
     `MODEL_ARTIFACT_MISSING model:all-minilm-l6-v2`.

   The fullfeature check also passed the GPU rule against the GPU node's 2 schedulable GPUs.
6. **Import.** It copied 16 files. A second import changed nothing. An import `SIGKILL`ed
   after one second left only `.partial-…`, and the retry reused the intact file and
   recopied the rest. The imported bundle passes the install preflight, and a tampered
   import is refused.
7. **Readiness.**
   - The CPU workers' containerd got a temporary host entry for the mirror.
   - The shared operator, built from this branch, ran from the mirror, with its
     agent-runtime and SLIM images pointed at the mirror (the same digests).
   - A cpuOnly AIPlatform in a namespace that allows egress only to cluster DNS and its own
     pods reached `Ready=True`, with the agent runtime "Ready=True: schema is current; all
     desired runtime replicas and the Service endpoint are ready". Every image came from the
     mirror by digest: the agent runtime base and provider, schema setup, SLIM, Postgres,
     and the operator itself.
   - The mirror's access log shows each CPU worker's containerd fetching them.
   - From inside the namespace, Docker Hub, ECR and 1.1.1.1 are blocked, while the
     in-namespace Postgres is reachable.
   - The existing fullfeature platform ran on mirror-pulled images for the duration and
     stayed `Ready`.
8. **Teardown.** Every change was reverted and checked:
   - the operator Deployment's image and environment are identical to the saved copy;
   - the ClusterRole and both CRDs are back to their originals;
   - both workers have no containerd drop-in and no mirror-named images;
   - the namespace and the mirror are gone, and the existing platform is back on its
     original images and Ready.

### Limits of the smoke

- **Staging used egress.** The images were mirrored over the controller's egress, which is
  the connected staging step, with a short-lived ECR token deleted after use. The node
  without a usable shell image pulled `postgres` once from Docker Hub for the configuration
  pod.
- **Host facts came from `kubectl`.** The controller has no SSH access to the workers, so
  the facts were taken read-only from the Kubernetes API rather than by the installer's SSH
  collector. The collector itself was exercised with the real installer functions in the
  installer suite and checked against the Go decoder.
- **Some GPU and model facts were supplied, not observed.** For the fullfeature check, the
  GPU node's driver and toolkit were taken as present because it advertises
  `nvidia.com/gpu`. The model staging markers were not read from the object store; 9 of
  the 10 models were listed as staged.
- **Egress was blocked for pods only.** It was enforced by a NetworkPolicy; node-level
  egress was not blocked. The node pulls are attributed by the mirror's own access log.
- **Not a fresh install.** The cluster already existed, so the installer's cluster
  bring-up was not run; the readiness smoke covered the AI Tier stack on it. No six-OS
  qualification or product invocation is claimed (MPR-190, MPR-192, MPR-194, MPR-198).

### Findings

- **The cluster's operator panics on cpuOnly.** The operator on the cluster (the MPR-184
  build) panics on a cpuOnly AIPlatform (`raybuilder/builder.go:1068`). MPR-186's per-profile
  reconcile fixes this; the smoke used the current operator.
- **Upgrade order: CRDs and RBAC first.** The current operator needs two read permissions
  the older ClusterRole lacks (`apps/replicasets` and `discovery.k8s.io/endpointslices`;
  without them its caches never sync). Run against the older CRDs, it deleted and recreated
  the completed schema Job every few seconds, because `status.featureStatus` was pruned and
  its record of completion was lost. Installing the current CRDs stopped this at once.
  [airgap-bundle.md](airgap-bundle.md) tells jobs to apply CRDs and RBAC before a newer
  operator.
- **My first mirror OOM-killed system containers.** That throwaway registry ran out of
  memory on the multi-gigabyte SLIM layer. The OOM also killed `coredns`,
  `konnectivity-agent` and `node-exporter` on the controller node once; Kubernetes restarted
  them. The replacement ran under a memory cap.

## PR #286 review fixes

Four review findings were valid and are fixed, each with a test that fails without the fix:

1. **GPU facts.** On a GPU host without `nvidia-smi`, the collector's driver line was
   missing, so the toolkit flag shifted into it (`driver: "false"`). A fresh host then passed
   the preflight as if a driver were loaded, without the closure having to cover its kernel.
   The driver line is now always emitted, and is kept only when it is a version. The test runs
   the real SSH payload against fake `lspci`, `nvidia-smi` and `nvidia-ctk` executables:
   - a fresh host without `nvidia-smi`;
   - a host where `nvidia-smi` is present but failing;
   - a provisioned host.
2. **Plain-HTTP mirror.** The installer configures the nodes for `images.registry` only, and
   `install-config` had said to leave it unset. `install-config` now sets `images.registry` to
   the mirror's host, and the install preflight reports `INSTALL_REGISTRY_MISMATCH` when it is
   anything else. The smoke had needed a hand-written node configuration for exactly this
   reason.
3. **Splunk Standalone.** Its default ServiceAccount now gets every pull Secret present,
   configured ones included, merged with any it already had. Before, it got only
   `ecr-registry-secret`.
4. **Secret references without a file.** These are now checked in the preflight, before any
   change, in every namespace that uses them. On a fresh install they fail at once, because
   such a Secret cannot exist yet. A Secret of another type fails too.

## PR #286 review fixes, round 2

Three more review findings were valid and are fixed, each with tests that fail without the fix:

1. **Referenced credentials in the registry check.** The installer's registry check
   authenticated only with the legacy `imagePullSecrets.*` settings. A mirror whose
   credentials were given only as an `images.imagePullSecrets` reference therefore failed
   the preflight, although the credentials were valid. The check now uses the reference's
   `dockerConfigFile`, or, for a name-only reference, its existing Secret in the target
   cluster (read-only, `kubernetes.io/dockerconfigjson` only). The first reference for a
   registry wins, and keys are matched by host. The bundle check's mirror access uses the same
   credentials, which are never printed. The test runs the real check against a fake
   registry that requires Basic auth.
2. **The target cluster.** The pull-Secret check and the GPU-allocatable fact read the
   installer host's kubectl. For an existing cluster reached over SSH, that is not the
   target: `main_install` exports its `KUBECONFIG` only after the preflight. The tests also
   showed that the checks read any cluster the host's kubeconfig named, even an unrelated one.
   The preflight now decides the target first, the way `main_install` does. It reads that
   cluster only with `get`, through `KUBECONFIG` when that names it, or with
   `sudo k0s kubectl` on the first controller.
3. **Per-profile install settings.** `install-config` printed every entry of a snapshot made
   for both profiles. Merged into a cpuOnly configuration, these settings made the installer
   reject it (Ray, Weaviate and SAIA settings). `install-config` now requires `--profile` and
   prints only that profile's entries. The test reads the installer's own cpuOnly rejection
   list.

## Design decisions

The decisions and their basis in the ERD and Jira are recorded in the pull request. In
short:

- the fullfeature GPU rule is "present or installable from the bundle, before any change";
- image references are generated from the snapshot, then enforced;
- add-on and k0s images come from verified archives (ERD NFR-3, §14.4.4), a recorded
  deviation from the wording of criterion 2 for add-on charts;
- registry authentication uses Secret references (ERD FR-14, §14.4.2);
- the tool travels, checksummed, in the bundle;
- AITK is not part of cluster setup.
