# Image snapshots: source to private mirror

An air-gapped install must not depend on an external registry at install time. This
tool takes the images of an agent-runtime candidate revision, works out which images each
profile needs, resolves every one to an immutable digest, copies it to a private
mirror, and keeps a versioned, checksummed record of the result: a **snapshot**. A
preflight then checks the mirror against that record before an install starts.

What it owns, and what it does not:

| Owned here | Owned elsewhere |
|---|---|
| inventory, digest and platform resolution, mirroring, the snapshot manifest, preflight, comparison, refresh | building or changing any image (external teams) |
| | importing images onto nodes, the offline bundle and install behaviour |
| | wiring the inputs into CI and the install jobs |
| | final release digests and certification |

```
go run ./cmd/image-snapshot <command> [flags]
```

## Inputs

| Input | Flag | Used for |
|---|---|---|
| Candidate manifest | `--candidate` (default `config/agent-runtime/candidate-manifest.yaml`) | the four candidate images; validated first, so a contradictory record fails |
| Installer configuration | `--config` | images outside the candidate set: operator, Ray, Weaviate, SAIA, Fluent Bit, nginx, OpenTelemetry, Splunk; also its `components` switches and `images.registry` (see below) |
| Rendered values per profile | `--values-cpuonly`, `--values-fullfeature` (output of `k0s_cluster_with_stack.sh render-profile`) | the effective `components`, which switch add-on images on and off per profile |
| Add-on images | `--addon-list` (`addon-images.list` from `airgap_install.sh`) | cert-manager, Prometheus, KubeRay, NVIDIA device plugin, local-path, MetalLB, ... |
| k0s system images | `--k0s-list` (`k0s airgap list-images`) | Kubernetes components |
| Owners | `--owners` (YAML map of component to owner) | the component owner recorded for each image |

## How this relates to the existing air-gap process

The installer already has a mirroring recipe (deployment guide, Phase 2: `crane copy`
each image into your registry, then set `images.registry` and relative image paths) and
the air-gap bundle (`airgap_install.sh`) for add-on and k0s images. This tool does not
replace either. It adds a verified, digest-pinned record of that mirror and reads the
installer configuration **the way the installer does**, so the inventory names the images
an install will really pull:

- **Defaults.** An omitted `images.splunk.operatorImage`, `images.fluentBit.image`,
  `images.otelCollector.image` or `images.nginx.image` takes the installer's default
  (`docker.io/splunk/splunk-operator:3.0.0`, `fluent/fluent-bit:1.9.6`,
  `otel/opentelemetry-collector-contrib:0.122.1`, `docker.io/library/nginx:1.27-alpine`),
  gated as the installer gates it: the Splunk Operator (and the Standalone image) only in
  the installer's *internal* Splunk mode (`splunk.enabled: true` and no
  `splunk.external.endpoint`) with `components.splunkOperator` on; the collector with
  `otel`; nginx is read only by the SAIA feature (`RELATED_IMAGE_NGINX`), so `fullfeature`
  only. A `null` or blank image counts as omitted. Run
  without `--config` and no installer default is assumed.
- **`images.registry`.** `build_image_url` puts it in front of any image path that does not
  already begin with a registry host (a dotted host or IPv4, an optional port, then a path
  and a tag or digest). The same rule is applied here, including its quirks: `localhost:5000/x:1`
  (no dot) and `quay.io/x` (no tag) are *not* treated as qualified. Rendered values and
  the add-on and k0s lists already hold final references and are used as they are. A test
  runs the installer's own function against the Go copy to catch drift.
- **Component switches.** The rendered `components` of each profile decide first; without
  rendered values the configuration's own `components.*` apply, an omitted switch being on,
  as in the installer. The AI operator image is an install reference only when
  `aiOperator` is on. One difference: the installer also skips the NVIDIA device plugin
  when there are no GPU workers; without rendered values this tool cannot see the node
  count and keeps the plugin's images in `fullfeature`, which over-includes rather than
  omits. Supply the rendered values to get the exact set.

Give `create` the configuration that names where images come **from** (the public or
candidate references). Give `compare` the configuration the air-gapped install will use,
which names the mirror references from the snapshot. The snapshot's own layout
(`<mirror>/<source host>/<repo>@<digest>`) is digest-pinned, which the operator requires for
the schema setup image; the Phase 2 recipe's tag-based layout remains valid for the images
this tool does not govern.

## The inventory

`image-snapshot inventory` lists every image, for both profiles, with the profiles
that need it, where the reference came from (`origin`), its category and its owner.
It is deterministic and carries a checksum over the candidate record and the images.

- **The candidate manifest is authoritative** for the Agent Runtime base, the
  Launchpad carrier and provider, schema setup and SLIM images.
- **Versioned base pins and other providers.** The installer sets every
  `images.agentRuntime.baseImages` entry (`RELATED_IMAGE_AGENT_RUNTIME_BASE_<VERSION>`) and
  every `images.agentRuntime.providerImages` entry on the operator, which uses a pin when a
  feature sets `runtimeVersion`. Each is inventoried for both profiles, under
  `agent-runtime-base-<version>` and `agent-runtime-provider-<name>`, unless it is the
  candidate's own: the pin for the candidate's `runtimeVersion` and the candidate's provider
  are the candidate images, and `compare` requires the install to point them at those images'
  mirror references (the candidate renderer uses the same mapping). This follows FR-16 and §14.4.4 of the
  Agent-Runtime / AI-Tier Integration ERD: the inventory is complete for what the operator
  can select.
- **AITK is not in the inventory.** It is the Splunk app `Splunk_ML_Toolkit`, not a
  container image; it ships separately.
- **`cpuOnly` never needs** Ray, Weaviate, SAIA, nginx, the KubeRay operator or the
  NVIDIA device plugin. A component switched off in a profile's rendered `components`
  (for example `otel: false`) drops its images from that profile.
- **Owners** come from the candidate manifest's source repository where it names one
  (today only the schema setup image), then from `--owners`, and are otherwise
  `unassigned`. No owner is invented.

## The snapshot

A snapshot is `<store>/<id>/manifest.json` plus `manifest.json.sha256`. Use
`--store snapshots/launchpad` to match the `images.snapshotManifest` path in the
installer examples (`snapshots/launchpad/<run-id>/manifest.json`).

Each entry records the component, role, category and owner; the profiles that need
it; the **source reference as supplied** and where it came from; the **source digest**
(the image index, for a multi-platform image); the **digest of the linux/amd64
manifest**, which is what is mirrored and what installs must use; every platform the
source offers; a build ID taken from the image's OCI `revision` or `created` label,
or from a build-stamp tag such as `202609221052-eae3b33005a5`; the **digest-pinned
mirror reference**; and a status. The snapshot also records the candidate revision
and the checksum of the candidate file it was derived from, the inventory checksum,
and the mirror. Output is canonical JSON, so the same snapshot is always the same
bytes.

- **Never rewritten.** `create` and `refresh` refuse an ID that already exists, and do so
  before any image is copied, so a moved tag cannot change what an earlier test run was
  based on and a clash cannot waste a long mirror run. A refresh records its
  `predecessor`. An ID may contain only letters, digits, `.`, `-` and `_`.
- **Written atomically.** A snapshot is written into a temporary directory and moved into
  place, so a crash never leaves a half-written snapshot or uses up the ID.
- **Checksummed, and required to be.** Every command that reads a snapshot checks it
  against its `.sha256` file and refuses one without it, then validates it, so deleting the
  checksum cannot switch verification off.
- **Only complete snapshots are stored.** An entry that is not verified, or whose
  mirror reference is not pinned to its digest, is refused.
- **No credentials.** A snapshot is built from references and digests only, and the
  store refuses content shaped like a credential (userinfo in a URL, a bearer token, a
  password or token key). Error text recorded in a snapshot is stripped of anything
  credential-shaped and bounded in length.

The digest-pinned `mirrorRef` is the form the operator now requires for the schema
setup image: `RELATED_IMAGE_AGENT_RUNTIME_SCHEMA_SETUP` must be a full, immutable
`registry/path@sha256:<digest>` reference (see `schema-job-lifecycle.md`), so
a snapshot's entry can be used as it is.

### Digest and platform

The AI Tier runs on `linux/amd64`. For each source the tool resolves the reference,
selects the linux/amd64 manifest and pins that digest. A platform variant is part of the
platform, for an index entry and a single manifest alike: `linux/amd64/v3` is not
`linux/amd64`. An image with no linux/amd64
manifest is **incompatible**; an image that cannot be resolved is **unresolved**.
Either fails the snapshot **before anything is copied**, as an external blocker that
names the component. The image is never replaced by a public one.

### Mirror naming

```
<mirror>[/<prefix>]/<source registry host>/<source repository>@sha256:<digest>
```

Keeping the source host stops `docker.io/splunk/x` and `quay.io/splunk/x` from
colliding. The mirror reference is digest-pinned, so a tag in the mirror cannot move
the image under an install.

## Commands

```sh
# What does each profile need?
image-snapshot inventory --config install.yaml \
  --values-cpuonly values-cpuonly.yaml --values-fullfeature values-fullfeature.yaml \
  --addon-list addon-images.list --k0s-list k0s-images.list --profile cpuOnly

# Resolve, mirror, verify, store.
image-snapshot create --mirror registry.internal:5000/ai-tier --store snapshots/launchpad \
  --id run-42 <the same inputs>

# Preflight: is the mirror ready for this profile?
image-snapshot verify --store snapshots/launchpad --id run-42 --profile cpuOnly <the same inputs>

# Will the install use only images of the snapshot?
image-snapshot compare --store snapshots/launchpad --id run-42 --profile cpuOnly <inputs naming the mirror references>

# A candidate image was replaced: redo only what changed.
image-snapshot refresh --store snapshots/launchpad --previous run-42 --id run-43 <the new inputs>
```

`install-config` prints the installer `images:` settings that make an install pull every
configured image from the snapshot's mirror by digest. That includes the versioned base pin
for the candidate's `runtimeVersion`. It also sets `images.registry` to the mirror's host,
because the installer configures the nodes for that registry only. The air-gapped install preflight compares the
configuration it is given with the snapshot (see [airgap-bundle.md](airgap-bundle.md)).

`create --resolve-only` resolves digests and platforms and stops, copying and storing
nothing. `--insecure` allows plain HTTP to a registry on an isolated network.
`--report FILE` writes the blocker report (`create`, `refresh`) or the change report
(`refresh`). Exit status: **0** all good, **1** a snapshot is blocked or a check found
problems, **2** a usage or input error.

### Credentials

Registry credentials come only from the local Docker configuration, the way
`docker pull` uses them; for ECR, log in first with
`aws ecr get-login-password | docker login --username AWS --password-stdin <registry>`.
The tool never reads one into, or writes one to, an artifact. Pulling the mirrored
images in the cluster is separate: the installer is given a Secret **reference** for
the mirror, and every pod, including the schema Job, must list it in
`images.imagePullSecrets` (see the pull-secret note in `profile-contract.md`).

## Preflight and comparison

`verify` checks one profile and exits non-zero naming the offending component:

| Code | Meaning |
|---|---|
| `OMITTED_FROM_SNAPSHOT` | the profile needs an image the snapshot has no entry for, or has an entry that lists only other profiles |
| `INVENTORY_CHANGED` / `CANDIDATE_REVISION_DIFF` | the snapshot was made from a different inventory or candidate record |
| `SNAPSHOT_ENTRY_BLOCKED` | the snapshot records an unresolved or unmirrored image |
| `MISSING_MIRROR_MAPPING` | an entry has no mirror reference |
| `MIRROR_MISSING_IMAGE` | the mirror does not hold the image |
| `DIGEST_MISMATCH` | the mirror serves a different digest than the snapshot records |
| `WRONG_ARCHITECTURE` | the mirrored image is not linux/amd64, or the mirror serves a multi-platform index where the snapshot pins one manifest |

`compare` checks every image an install will use (the rendered values and installer
configuration, after the references are pointed at the mirror) against the snapshot. An
install must use the mirror, so a reference is accounted for only when it is that
component's own mirror reference, pinned to the recorded digest. Everything else is a
finding:

| Code | Meaning |
|---|---|
| `SOURCE_REGISTRY_REFERENCE` | the reference points at the registry the image was copied from (by tag or digest), so the install would depend on an external registry |
| `DIGEST_MISMATCH` | the reference pins a different digest in the mirror repository |
| `UNACCOUNTED_REFERENCE` | the reference is not in the snapshot, uses a mutable tag in the mirror, or is the image of a different component |

A comparison with no install references is an error (exit 2), not a pass: give the
installer `--config` and the rendered `--values-<profile>` the install will use.

## Refresh

When an external team replaces a candidate build, `refresh` derives a new snapshot
from the stored one. Images are paired with their predecessors by component and source;
where several images share a component (an add-on's images, two tags of one repository),
an image is paired by repository only when exactly one remains on each side, and is
otherwise reported as new and removed rather than guessed. Entries whose source is unchanged are carried forward with no
registry calls; only new or replaced entries are resolved, mirrored and verified. Each
changed entry records the digest it replaces, and the report lists the install jobs
and qualification cells that must rerun: a change to an image only `fullfeature` uses
reruns the `fullfeature` install job and the three `fullfeature` cells (RHEL 9.8,
RHEL 10.2, Ubuntu 24.04), a change to a shared image reruns both install jobs and all six
cells. `--recheck-tags` re-resolves every source to catch a tag
that now points at a different digest. If nothing changed it says so and stores
nothing; if the replacement is unavailable it fails as an external blocker and stores
nothing.

## What this does not establish

The registry client is tested against real in-memory OCI registries, and opt-in tests
read real ones: `IMAGE_SNAPSHOT_LIVE=1 go test -run TestLive ./internal/imagesnapshot`
resolves public images anonymously and mirrors one into a local registry, and
`IMAGE_SNAPSHOT_LIVE_CANDIDATES=1 go test -run TestLive_MirrorsTheCandidates`
copies the four candidate images from ECR into a throwaway local registry and
pulls them back with every blob verified (see `validation/mpr-187-ecr-mirror.txt`).
Copying to a customer or CI mirror that needs credentials or sits behind a proxy has not
been done: access to such a mirror is an external input.
An air-gapped host, the offline bundle and the import onto nodes are out of scope here. The add-on
and k0s image lists are produced by the existing air-gap bundle mechanism and are
consumed as they are; the hand-written `container-images.txt` in `airgap_install.sh` is
not changed.
