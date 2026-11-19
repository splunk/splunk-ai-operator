# MPR-187 validation record

Scope: the source-to-mirror snapshot, mirror and preflight process described in
[image-snapshot.md](image-snapshot.md). Nothing was built or modified, no cluster was
used, and no ECR or AWS call was made. Layers 1 to 4 below ran against in-memory OCI
registries; layer 5 resolved public images anonymously.

## Completion criteria

| # | Criterion | Implementation | Evidence |
|---|---|---|---|
| 1 | Complete per-profile inventory from the candidate revision, rendered values, installer and add-ons, with profile applicability | `BuildInventory`: candidate manifest (four images), installer-config images, rendered `components` gating, add-on and k0s lists, per-component owner, deterministic checksum. AITK is not an image and is not listed. | `TestBuildInventory_*`, `TestInstallRefs_*`; run on the real MPR-188 manifest and the real example config: 10 images for the example configuration, with `cpuOnly` excluding Ray, Weaviate and nginx |
| 2 | Resolve every image to its immutable digest and platform; record source reference, digest, mirror reference, build ID, owner, manifest revision; fail on unresolved or incompatible | `Create` resolves each source to the linux/amd64 manifest digest, records the index digest, all platforms, a build ID from OCI labels or a build-stamp tag, and the candidate revision and checksum; an unresolved or incompatible image fails the snapshot **before anything is copied** | `TestCreate_ResolvesTheAmd64Digest...`, `TestCreate_AnIncompatibleOrUnresolvedImageFailsTheSnapshotBeforeAnythingIsCopied`, `TestBuildID`; sample run |
| 3 | Mirror by digest and verify the target; versioned, machine-readable manifest with inventory checksum and candidate link; keep prior snapshots | `mirrorOne` copies then re-reads the target (digest and linux/amd64 must match); `Store` writes `manifest.json` plus a `.sha256`, never overwrites, refuses an incomplete snapshot | `TestCreate_VerifiesTheTargetAfterTransfer`, `TestStore_*`; sample run |
| 4 | Preflight detects a missing image, wrong architecture, wrong digest, missing mirror mapping and a profile image omitted from the inventory; names the component; exits nonzero | `Preflight` with `MIRROR_MISSING_IMAGE`, `WRONG_ARCHITECTURE`, `DIGEST_MISMATCH`, `MISSING_MIRROR_MAPPING`, `OMITTED_FROM_SNAPSHOT` (and inventory, candidate and blocked-entry checks); exit status 1 | `TestPreflight_*` (one subtest per case); the negative preflight in the sample run |
| 5 | Comparison shows no unaccounted reference; refresh only the affected entries, record old and new digests, name the jobs and cells to rerun; an unavailable image is an external blocker, never a public fallback | `Compare`, `Refresh`, `RerunTargets`, `ErrNoChange`, `BlockedError` | `TestCompare_*`, `TestRefresh_*`; the refresh, no-change and blocked-refresh steps of the sample run |
| 6 | No credentials in any artifact | credentials only from the local Docker configuration; the store refuses credential-shaped content; recorded errors are sanitized | `TestStore_RefusesCredentialLookingContent`, `TestSanitize...`, `TestPreflight_ErrorsDoNotLeakCredentials` |

## Results

Tested in six layers. Layers 1 to 4 use real in-memory OCI registries over the actual
registry protocol; layers 5 and 6 are opt-in and read real registries.

1. **Unit and end-to-end tests:** `go test -count=1 ./internal/imagesnapshot ./cmd/image-snapshot`
   passes **103 tests and subtests** (90 in the package, 13 CLI tests that check real exit
   codes), with 0 failures; the 3 live tests are skipped unless asked for. The race detector
   is clean, and statement coverage of the two packages together is **90.9%**.
2. **Registry behaviour a plain fake does not produce:** an index with a BuildKit
   attestation entry (platform `unknown/unknown`), a Docker manifest list, a six-layer
   image copied with every blob pulled back and checked against its digest, sources pinned
   by digest or by tag and digest, a protected source and mirror authenticated only through
   the Docker configuration (the snapshot, log and errors never contain the password, and
   missing or wrong credentials fail without echoing anything), a mirror that refuses
   writes, a cancelled context, an unreachable host, and identical inputs producing
   byte-identical snapshots.
3. **Mutation checks:** **42 deliberate breakages**, each caught by a failing test (24 from
   the first version and 18 for the review fixes below; one early mutation became
   equivalent when the store started writing atomically and was replaced by a true
   overwrite):
   copying despite a blocked image; pinning the index instead of the amd64 digest; skipping
   the digest or architecture check after the copy; overwriting a stored snapshot; the
   credential guard off; ignoring registry credentials; a preflight that ignores the
   profile or the architecture; accepting a mutable mirror tag; a refresh that redoes every
   image, forgets the replaced digest or its predecessor; rerun targets that ignore the
   profile; rendered components that no longer switch images off; unsanitized errors; a
   blocked entry that passes validation; duplicate inventory entries; `index.docker.io` not
   normalised; attestation entries counted as platforms; build IDs never read from labels or
   a placeholder label such as `unknown` taken as the build ID;
   the CLI exiting 0 on a blocked snapshot or a failed preflight; AITK listed as an image.
4. **Regression against the baseline** (`ai-agent-runtime` at `bac1588`, MPR-186 and
   MPR-189 merged): the base passes 732 tests with 0 failures and this branch passes 835
   with 0 failures. All 103 added tests are in the two new packages; **every existing
   package has exactly the same test count as before**. The installer tests give the same
   573 passed and 12 pre-existing failures, MPR-188's four acceptance renders pass,
   `go vet` and `gofmt` are clean, and the operator still builds as a static linux/amd64
   binary. The only changes to existing files are `go.mod`, `go.sum`, the changelog and one
   link in `candidate-refresh.md`.
5. **Real public registries** (opt-in, anonymous, read-only apart from one copy into a local
   in-memory mirror): `IMAGE_SNAPSHOT_LIVE=1 go test -run TestLive -v ./internal/imagesnapshot`.
   Nine images that the installer and the existing air-gap bundle already name were
   resolved on Docker Hub, quay.io, nvcr.io and registry.k8s.io. Every one has a
   linux/amd64 manifest; multi-platform images pin a digest different from their index
   (nginx 7 platforms, otel collector 6, cert-manager 5, pause 6); fluent-bit's build ID was
   read from its OCI revision label. `registry.k8s.io/pause:3.9` was copied into a local
   mirror and pulled back in full: the config and every layer match the source, and the
   preflight passes on the result.

6. **The real MPR-188 candidate images in ECR** (2026-11-19, with a
   developer AWS profile through a throwaway Docker config that was deleted
   afterwards; ECR was only read, and your Docker configuration was not touched).
   - *Resolve:* all four images resolve and are linux/amd64 only. Three digests are
     **identical to the ones MPR-188 recorded** as historical evidence (and explicitly did not
     verify): the Agent Runtime base `ddedf855…`, the carrier `d7330113…` and the schema setup
     image `5877fcbd…`. SLIM, which had no recorded digest, is now pinned (`f4ea9e5f…`); its
     tag is an index with a provenance entry (`c413762c…`), which the tool handles by pinning
     the linux/amd64 manifest. The run found that the carrier's own revision label is the
     string `unknown`; build IDs now ignore placeholder labels and use the build-stamp tag.
     Output: [validation/mpr-187-ecr-resolution.txt](validation/mpr-187-ecr-resolution.txt).
   - *Real copy:* all four images (about 2.0 GB compressed) were copied into a throwaway local
     registry that keeps its blobs on disk, in 9 minutes 11 seconds, then **pulled back in
     full with every blob verified against its digest**: 49 layers for the base, 2 for the
     carrier, 12 for the schema setup image and 14 for SLIM. The preflight passes for both
     profiles and the snapshot is stored and checksummed. Output:
     [validation/mpr-187-ecr-mirror.txt](validation/mpr-187-ecr-mirror.txt). Repeat it with
     `IMAGE_SNAPSHOT_LIVE_CANDIDATES=1 go test -run TestLive_MirrorsTheMPR188Candidates -v
     -timeout 60m ./internal/imagesnapshot` after logging in to the candidate registry.

## Independent review

A reviewer who had not seen this work read the code against the story and found problems
that the first version's tests did not cover. All were confirmed and fixed, each with a
regression test, before this was proposed:

- A refresh keyed images by component name only, but several add-on images share one (the
  Prometheus and Alertmanager images are both `monitoring-stack`): an unchanged refresh
  reported spurious changes with the wrong digests. Images are now matched by their own
  source repository where a component has several.
- The error sanitizer removed the word `Basic` or `Bearer` but left the credential after
  it, and missed URL userinfo and a JSON `auth` value. All three are now redacted, and the
  blocker report refuses credential-shaped content.
- The preflight's "image omitted" check ignored profile applicability.
- `compare` accepted a reference to the public source registry, which would have made the
  install depend on an external registry; it now accepts only the component's own mirror
  reference pinned to the recorded digest, and reports the rest by code.
- `compare` could pass having checked no reference at all; that is now an error.
- The store was not crash safe (an interrupted write used up the ID) and accepted a
  snapshot whose checksum file was missing; it now writes atomically, requires the checksum
  file, validates IDs on read, and checks mirror references against the snapshot's mirror.
- `refresh --recheck-tags` dropped a profile change and kept a stale previous digest;
  duplicate inventory entries lost profiles; platform variants were not kept distinct; an
  ID clash was found only after a long mirror run; and a report that could not be written
  changed the exit code.

## PR #283 review fixes

Five review findings were fixed so the tool reads the installer configuration the way
`k0s_cluster_with_stack.sh` does (see "How this relates to the existing air-gap process" in
[image-snapshot.md](image-snapshot.md)):

- omitted Splunk Operator, Fluent Bit, OpenTelemetry and nginx images take the installer's
  defaults, gated as the installer gates them (the Splunk images only in internal Splunk mode);
- `images.registry` is applied with the same rule as `build_image_url`, checked by a test that
  runs the installer's own function, and the defaults are checked against the script's literals;
- the AI operator install reference is gated on `aiOperator`, and without rendered values the
  configuration's own `components` switches apply;
- refresh pairs the images of a shared component by source, then by repository or as a lone
  image only when unambiguous, and otherwise reports new and removed;
- a single-manifest image keeps its platform variant (`linux/amd64/v3` is not `linux/amd64`).

After the fixes the two packages pass 125 tests and subtests (3 live tests skipped), the race
detector is clean, coverage is 92.8% (package) and 85.7% (CLI), and 18 further mutations
targeting the fixes are each caught. An independent review of the fixes found that the
Splunk Operator default ignored the Splunk mode; that was fixed with a test over eight
Splunk configurations before this was proposed.

## Sample run

[validation/mpr-187-sample-run.txt](validation/mpr-187-sample-run.txt) is the captured
output of a full flow against two in-memory registries (registry addresses replaced by
placeholders; digests differ on every run because the test images are random):

1. `create` mirrors eight images and stores snapshot `run-1`; a second `create` with the
   same ID is refused.
2. `verify` passes for both profiles; against a copy whose `slim` mirror reference points
   at an image the mirror never received it exits 1 with `[MIRROR_MISSING_IMAGE] slim`.
3. `compare` accepts an install that uses the mirror reference and exits 1 with
   `[UNACCOUNTED_REFERENCE] slim` for an unknown image.
4. `refresh` after SLIM's candidate tag is replaced changes only `slim`, prints the old
   and new digests and the eight jobs and cells to rerun; a second refresh reports no
   change; a refresh whose replacement does not exist exits 1 as an external blocker and
   stores nothing.

The capture is opt-in: set `IMAGE_SNAPSHOT_EVIDENCE=<file>` when running
`go test ./cmd/image-snapshot -run TestEndToEnd`.

## Limits

- **Not a customer or CI mirror.** The real candidates were copied to a throwaway local
  registry with no authentication. A mirror that needs credentials to push, or sits behind a
  proxy, has been exercised only with test registries (layer 2), not a production one; the
  story lists mirror access as an external input.
- **Owners** are known only for the schema setup image (from the candidate manifest's
  source repository). The rest are `unassigned` until an owners file is supplied.
- **Add-on and k0s images** are consumed from the lists the existing air-gap bundle
  mechanism produces; this tool does not generate them. Whether they are also mirrored
  to the registry or only bundled for the nodes is a decision for MPR-193.
- **Not in scope here:** importing the images onto nodes and install behaviour (MPR-193),
  CI input wiring (MPR-183), the install jobs (MPR-190, MPR-192), final release digests
  and certification (MPR-216).
