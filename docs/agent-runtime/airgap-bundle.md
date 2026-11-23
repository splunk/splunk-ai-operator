# Air-gapped import and install: the `airgap-bundle` contract

An air-gapped AI Tier install is made from a local **bundle** and an **image snapshot**
(see [image-snapshot.md](image-snapshot.md)). This page is the contract for whoever runs
that install: an operator by hand, or the per-profile pipeline jobs (MPR-190, MPR-192),
which call this primitive instead of copying its logic.

- **Fail closed, before any change.** Every missing, altered or incompatible artifact and
  every unmet host prerequisite is reported by name before the install changes cluster
  state. There is no download fallback.
- **Pull by digest from the mirror.** Every AI Tier image the install applies is a
  digest-pinned reference in the private mirror. Registry authentication uses Kubernetes
  Secret references.
- **Safe to retry.** Importing a bundle is idempotent, and an interrupted import resumes
  without accepting a partial bundle.

Design source: the [Agent-Runtime / AI-Tier Integration ERD](https://splunk.atlassian.net/wiki/spaces/PROD/pages/1080352114691/Agent-Runtime+AI-Tier+Integration),
FR-14, FR-16, NFR-1, NFR-3, NFR-7 and §14.4.1 to §14.4.4. Evidence:
[mpr-193-validation.md](mpr-193-validation.md).

## End to end

| Step | Where | Command | Network |
|---|---|---|---|
| 1. Mirror the images | connected host | `image-snapshot create --mirror <registry>/<prefix> --store snapshots ...` | source registries and the mirror |
| 2. Stage the bundle | connected staging host | `airgap_install.sh --config <cfg> --download-only` | public downloads (staging only) |
| 3. Check the bundle before transfer | staging host | done by step 2 (`airgap-bundle verify --scope bundle`) | none |
| 4. Transfer | customer process | copy the bundle directory | — |
| 5. Import on the install host | install host | `airgap-bundle import --from <transferred> --to <bundles>` | none |
| 6. Generate the install settings | any | `image-snapshot install-config --snapshot <bundle>/snapshot/manifest.json --profile <cpuOnly\|fullfeature>` | none |
| 7. Install | install host | `export AIRGAP_BUNDLE_DIR=<bundles>/<bundle id>; source "$AIRGAP_BUNDLE_DIR/airgap-env.sh"; k0s_cluster_with_stack.sh install` with `cluster.airgap: true` | the mirror and the cluster only |

`airgap-env.sh` sets `AIRGAP_MODE` and `AIRGAP_STAGED` and points the installer at the bundle's
files. Without `AIRGAP_STAGED` the installer would hand off to `airgap_install.sh`, which
stages a bundle again from the internet. Step 7 runs the **install preflight** (`airgap-bundle verify --scope install`) as the last
preflight check, after SSH reachability and before model staging, which is the first
change. A failed preflight stops the install with nothing changed.

## Inputs

| Input | Supplied as | Notes |
|---|---|---|
| Image snapshot | `images.snapshotManifest` in the cluster config, or `AIRGAP_SNAPSHOT_MANIFEST` | Required. Copied into the bundle at `snapshot/manifest.json` (+ `.sha256`). |
| `airgap-bundle` tool | built from this repository by `airgap_install.sh`, or `AIRGAP_BUNDLE_BINARY` (a prebuilt linux/amd64 binary, for CI) | Staged at `binaries/airgap-bundle`. The installer checks its checksum against the bundle manifest before running it. |
| Bundle directory | `AIRGAP_BUNDLE_DIR` (exported by `airgap_install.sh`, or by the bundle's `airgap-env.sh`) | The imported bundle. |
| Install configuration | the cluster config, with the output of `image-snapshot install-config --profile <the install's profile>` merged into `images:` | It holds only that profile's images: cpuOnly gets no Ray, Weaviate or SAIA setting, which the installer rejects for cpuOnly. Every configured AI Tier image must be its component's mirror reference by digest. `images.registry` must be the mirror's host (for example `10.0.39.38:5099`), which `install-config` sets. The installer configures the nodes' access to a registry only for `images.registry`. It does not prefix the generated references, which already name the mirror. |
| Registry credentials | `images.imagePullSecrets: [{name, dockerConfigFile?}]` | Secret references. A missing Secret is created as `kubernetes.io/dockerconfigjson` from `dockerConfigFile` (never logged). A missing Secret without a file, or a Secret of another type, fails. Each name is listed on the AIPlatform CR (every pod, the schema Job included) and on the operator and Splunk Operator Deployments. The same credentials authenticate the preflight's registry and mirror checks: each entry's `dockerConfigFile`, or the Secret it names as it already exists in the target cluster (read-only), the first entry for a registry winning. They are never logged. |
| Model artifacts (fullfeature) | the model configuration the installer selects for `aiPlatform.defaultAcceleratorType` | Recorded in the bundle manifest; must be staged in the object store with a matching staging marker. |
| Plain-HTTP mirror | `images.registryInsecure: true` | The installer then configures every node's containerd for plain HTTP to `images.registry`, and passes `--insecure` to the preflight. Use `false` for an HTTPS mirror. |

## Commands

```
airgap-bundle manifest --bundle DIR [--snapshot FILE] [--model-config FILE] [--id ID]
airgap-bundle verify   --bundle DIR --profile cpuOnly|fullfeature [--scope bundle|install]
                       [--snapshot FILE] [--config FILE] [--values-cpuonly FILE] [--values-fullfeature FILE]
                       [--candidate FILE] [--facts FILE] [--gpus N] [--insecure] [--report FILE]
                       [--addon-list FILE] [--k0s-list FILE]
airgap-bundle import   --from DIR --to DIR
image-snapshot install-config (--snapshot FILE | --store DIR --id ID) --profile cpuOnly|fullfeature [--candidate FILE]
```

- `manifest` writes `bundle-manifest.json` and its `.sha256` at the top of the bundle. It
  never rewrites a different manifest. `--snapshot` defaults to the bundle's own snapshot.
- `verify --scope bundle` checks the bundle alone (staging host); it needs no candidate,
  snapshot or cluster. `verify --scope install` (the default) adds the snapshot, the mirror,
  the install configuration and the host facts. The image lists default to the bundle's own.
- `import` copies a bundle into `<to>/<bundle id>`.
- `install-config` prints the installer `images:` settings for one profile from a
  snapshot, including the versioned base pin for the candidate's `runtimeVersion`. Entries
  of the other profile only are left out.

### Exit status

| Status | Meaning |
|---|---|
| 0 | everything is in order (or the bundle was already imported) |
| 1 | a check found a problem, or an import was refused; nothing was changed or accepted |
| 2 | a usage or input error (a missing flag, an unreadable or malformed input file) |

Findings are printed to stderr, one per line, as `[CODE] subject: message`, sanitized of
anything credential-shaped. `--report FILE` also writes them as JSON:
`{"findings": [{"component", "code", "message"}]}`.

### Finding codes

| Code | Subject | Meaning |
|---|---|---|
| `BUNDLE_MANIFEST_INVALID` | `bundle-manifest.json` | no readable, checksummed, valid bundle manifest |
| `BUNDLE_FILE_MISSING` | file path | a listed file is absent |
| `BUNDLE_FILE_CHANGED` | file path | a listed file has another size or checksum (truncated or replaced) |
| `BUNDLE_FILE_UNLISTED` | file path | a file in the bundle that its manifest does not list |
| `REQUIRED_ARTIFACT_MISSING` | `role:name` | the profile installs a binary, chart, manifest, package or archive the bundle lacks |
| `ARCHIVE_IMAGE_MISSING` | image | an image list names an image its archive does not hold |
| `ARCHIVE_IMAGE_UNPINNED` | image | an archive holds an image without a manifest digest |
| `ARCHIVE_IMAGE_DIGEST_MISMATCH` | image | an archive image is not the snapshot's image (another build or platform) |
| `ARCHIVE_IMAGE_UNMAPPED` | image | an archive image the snapshot has no entry for |
| `SNAPSHOT_MISMATCH` | `snapshot` | the snapshot is missing or not the one the bundle was made for |
| `INSTALL_CONFIG_MISSING` | `install-config` | no install references to compare with the snapshot |
| `INSTALL_REGISTRY_MISMATCH` | `images.registry` | `images.registry` is not the mirror host, so the nodes would not be configured for the mirror |
| `HOST_FACTS_MISSING` | `host` | the install preflight was given no host facts |
| `NODE_PLATFORM_MISMATCH` | `node:<name>` | a node is not linux/amd64, or did not report its platform |
| `GPU_NODE_MISSING` | `host` | fullfeature, and no GPU node was reported |
| `GPU_DEVICES_MISSING` | `node:<name>` | a GPU node reports no NVIDIA GPU |
| `GPU_DRIVER_MISSING` | `node:<name>` | no driver is loaded and the bundle cannot install one for the node's kernel and package format |
| `GPU_RUNTIME_MISSING` | `node:<name>` | no NVIDIA container toolkit, and the bundle does not carry it |
| `GPU_CAPACITY_INSUFFICIENT` | `host` | fewer usable GPUs than fullfeature needs (`--gpus`, default 1) |
| `MODEL_INVENTORY_MISSING` | `models` | fullfeature, and the bundle records no model artifacts |
| `MODEL_ARTIFACT_MISSING` | `model:<id>` | a required model artifact is not staged |
| `MODEL_ARTIFACT_MISMATCH` | `model:<id>` | a staged model artifact has another source or checksum |

The install scope also reports the image snapshot's own codes
([image-snapshot.md](image-snapshot.md)): `MIRROR_MISSING_IMAGE`, `DIGEST_MISMATCH`,
`WRONG_ARCHITECTURE`, `MISSING_MIRROR_MAPPING`, `SNAPSHOT_ENTRY_BLOCKED`,
`CANDIDATE_REVISION_DIFF`, `SOURCE_REGISTRY_REFERENCE` and `UNACCOUNTED_REFERENCE`.

## The bundle

`airgap_install.sh` stages the layout below; `airgap-bundle manifest` gives each file a role
from its place in it.

| Path | Role | Required |
|---|---|---|
| `binaries/k0s`, `binaries/yq`, `binaries/airgap-bundle` | binary | always |
| `images/k0s-images.tar` + `.list` | image archive + list | always |
| `images/addon-images.tar` + `.list` | image archive + list | always |
| `manifests/local-path-storage.yaml` | manifest | always |
| `manifests/cert-manager.yaml` | manifest | when `certManager` is on |
| `manifests/nvidia-device-plugin.yml` | manifest | when `nvidia` is on |
| `charts/kube-prometheus-stack-*.tgz` | chart | when `monitoring` is on |
| `charts/opentelemetry-operator-*.tgz` | chart | when `otel` is on |
| `charts/kuberay-operator-*.tgz` | chart | when `kuberay` is on |
| `charts/metallb-*.tgz` | chart | when `metallb` is on and `metallb.install: true` |
| `packages/pyyaml-*` | package | always |
| `packages/nvidia-closure/` | package | for a GPU node whose driver or toolkit must be installed |
| `snapshot/manifest.json` + `.sha256` | snapshot | always |
| `bundle-versions.txt`, `checksums.sha256`, `airgap-env.sh`, `container-images.txt`, `*.version`, `*.manifest` | metadata | — |

Component switches are read as the installer reads them: the rendered profile values,
else the configuration's `components`, else on (cpuOnly turns `kuberay` and `nvidia` off).

**Image archives** are OCI layouts written by `k0s airgap bundle-artifacts`. Every image in
them is recorded with its manifest digest. In the install scope each must be the
snapshot's image for that reference (its linux/amd64 manifest or the index that holds
it), which settles both digest and architecture. After import, the installer checks each
node's images by digest against the bundle manifest, not only by name.

**AI Tier images** come from the mirror: the operator, agent runtime base and provider,
schema setup, SLIM, SAIA, Ray, Weaviate, nginx, Fluent Bit and the OpenTelemetry collector.
The k0s system images and the add-on chart images come from the verified archives (ERD
NFR-3, §14.4.4).

AITK is a Splunk app, not an image: it is not part of the bundle or of cluster setup.

## Host facts

The installer collects the facts read-only and passes them as `--facts`. A pipeline job
that runs the preflight itself writes the same JSON. Unknown fields are rejected.

```json
{
  "nodes": [
    {"name": "10.0.0.11", "platform": "linux/amd64", "os": "rhel", "kernel": "5.14.0-503.40.1.el9_5.x86_64"},
    {"name": "10.0.0.12", "platform": "linux/amd64", "os": "rhel", "kernel": "5.14.0-503.40.1.el9_5.x86_64",
     "gpu": {"devices": 2, "driver": "550.54.15", "runtime": true, "allocatable": 2}}
  ],
  "stagedModels": [{"id": "all-minilm-l6-v2", "source": "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2"}]
}
```

| Field | Collected by the installer from |
|---|---|
| `platform`, `os`, `kernel` | `uname -m`, `/etc/os-release` `ID`, `uname -r` over SSH |
| `gpu.devices` | NVIDIA display/3D controllers in `lspci -nn`, or `nvidia-smi -L` |
| `gpu.driver` | `nvidia-smi --query-gpu=driver_version`, kept only when it is a version such as `550.54.15` (empty: no driver loaded, `nvidia-smi` absent, or failing) |
| `gpu.runtime` | `nvidia-container-runtime` or `nvidia-ctk` present |
| `gpu.allocatable` | the node's `nvidia.com/gpu` allocatable, only when the nodes already form the cluster this install will use (see "The target cluster") |
| `stagedModels` | each model's `staging_state/<id>/.staging_complete` marker in the object store |

GPU nodes are the workers after the CPU workers, as the installer counts them.

### The target cluster

The preflight runs before the installer chooses the cluster it installs into, so it decides
that the same way first, read-only:

- `cluster.useExisting` `auto` or `force`, and `KUBECONFIG` names a reachable cluster whose
  context contains `cluster.name` (any context with `force`): that cluster;
- otherwise, k0s already running on the first controller: that cluster, read with
  `sudo k0s kubectl get` over SSH;
- otherwise there is no cluster yet (a fresh install).

The pull-Secret checks and `gpu.allocatable` read only that cluster, and only with `get`. A
kubeconfig on the installer host that names some other cluster is never read.

### fullfeature GPU rule

Before any change, a GPU node must have NVIDIA GPUs. It must have a driver loaded, or the
bundle's `nvidia-closure` must cover its exact kernel and package format (`rpm` or `deb`).
The container toolkit must be installed, or be in the closure. Usable capacity
(allocatable on an existing cluster, devices otherwise) must meet `--gpus`. After the
driver and device-plugin steps, the installer's existing device-runtime and
schedulable-capacity checks still apply.

## Outputs

- `LOG_DIR/airgap-preflight-report.json`: the preflight findings.
- `LOG_DIR/airgap-install-record.json`: which bundle and snapshot the install used. It is
  written when the preflight passes (`started`) and at the end (`completed` or
  `completed-not-ready`), and holds no credential (ERD NFR-7):

  ```json
  {"recordType": "airgap-install", "status": "completed", "recordedAt": "2026-11-23T04:50:00Z",
   "profile": "cpuOnly", "bundleId": "...", "snapshotId": "...", "snapshotChecksum": "...", "mirror": "..."}
  ```

## For the pipeline jobs (MPR-190, MPR-192)

1. Take the snapshot, the bundle location and the credential references from the job inputs
   (MPR-183). Never pass secret values as parameters.
2. `airgap-bundle import --from <transferred bundle> --to <bundles dir>`. Exit 1: stop, the
   bundle is damaged or a different bundle holds the ID.
   Each `images.imagePullSecrets` entry without a `dockerConfigFile` must already exist as a
   `kubernetes.io/dockerconfigjson` Secret in every namespace that uses it (the AI namespace,
   `splunk-ai-operator-system`, and `splunk-operator` when it is installed). The preflight
   checks this in the target cluster (an existing cluster reached over SSH included); on a
   fresh cluster give a `dockerConfigFile` instead.
3. Merge `image-snapshot install-config --snapshot <bundle>/snapshot/manifest.json --profile <profile>`
   into the install configuration's `images:` (it also sets `images.registry` to the mirror host), set
   `images.registryInsecure` for a plain-HTTP mirror, and set `images.imagePullSecrets` to
   the mirror's Secret reference.
4. `export AIRGAP_BUNDLE_DIR=<bundles dir>/<bundle id>`, `source "$AIRGAP_BUNDLE_DIR/airgap-env.sh"`,
   then run `k0s_cluster_with_stack.sh install` with `cluster.airgap: true`. A preflight
   failure exits nonzero with nothing changed; publish `airgap-preflight-report.json`.
5. Publish `airgap-install-record.json` with the job's results.

**Upgrading an existing cluster:** apply the operator's CRDs and RBAC before running a
newer operator. Run against older CRDs, a newer operator cannot record schema Job
completion (`status.featureStatus` is pruned) and recreates the Job repeatedly. See the
smoke findings in [mpr-193-validation.md](mpr-193-validation.md).
