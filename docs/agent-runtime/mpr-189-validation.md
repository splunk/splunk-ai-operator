# MPR-189 local and live validation — 18 November 2026

Base: `ai-agent-runtime` at `3e4bb9912b8959456e84d66b26ac998017847010`.
The MPR-189 branch was rebased onto that head. The base includes the merged
MPR-188 candidate renderer, whose tag-based inputs now use an explicitly
synthetic schema digest only for in-memory rendering. Production schema Jobs
require a resolved immutable digest, which was supplied directly from the
verified schema image without waiting for MPR-187. [MPR-189](https://splunk.atlassian.net/browse/MPR-189)
lists MPR-188 as its prerequisite; MPR-187 has no blocking link to this story.

## Required test type

MPR-189 requires focused local operator tests and rendered Job/condition
evidence. The acceptance criteria call for bounds and retry/backoff, failure
states and safe diagnostics, unchanged-input reuse, changed-input reruns,
deduplication, and serial replacement of an active Job. Full profile install,
PostgreSQL administration, product requests, and OS qualification belong to
MPR-193, MPR-190, MPR-192, and their downstream qualification stories.

The user selected the existing `agentruntime-dev` cluster for an additional
live schema replay. The test used its own database and AIService, preserving the
active service and checkpoint database. The `fullfeature-dev` cluster was not
used.

## Evidence assessment

The local test criterion is supported by direct, reproducible evidence below.
The focused suite also covers A → B → A schema digest transitions before
the first Job's TTL expires, both when B's completion was observed and when
it was not: the old A success is removed and a fresh A Job is created.
After [Saurabh's MPR-189 comment](https://splunk.atlassian.net/browse/MPR-189?focusedCommentId=24503970),
the controller watch path was also checked against a local Kubernetes API
server. The previous in-memory lifecycle tests did not exercise controller
event delivery, and the first watch test failed: a completed Job produced no
AIService reconcile request. The controller-wide event filter excluded status
updates even though the owned-Job filter admitted them. The corrected filter
and regression test now cover succeeded and failed Jobs and ready Deployments.
The candidate renderer uses a synthetic digest solely for in-memory tests; the
live test resolved the supplied image tag through ECR and used its real digest.
The supplied `/schema.sql` was reviewed in the
[MPR-188 contract review](candidate-contract-review.md) and replayed twice
against the disposable PostgreSQL database below.

| MPR-189 criterion | Evidence here | Limit |
| --- | --- | --- |
| 1. Finite execution and cleanup | Local shell tests record 12 failed readiness attempts and capped backoff. Two live Jobs using the supplied image completed with a 300 second deadline, backoff limit 1, and terminal TTL 86400 seconds. | Unreachable database and deadline exhaustion were exercised locally, not on the shared cluster. |
| 2. Lifecycle status and safe diagnostics | Local tests cover `Pending`, `Succeeded`, `TimedOut`, `Failed`, and `Superseded`, including a credential-bearing failure canary that is absent from status. Live Jobs and the AIService reached `Succeeded` without exposing credentials in the evidence. | Live terminal failure was not induced. |
| 3. Reuse and changed inputs | Local tests cover digest, Secret version, and PostgreSQL configuration changes. Live ECR resolved the supplied tag to a digest; a scoped controller restart kept Job count at two, while a disposable Secret version change created exactly one new digest-pinned Job. | Product candidate snapshot ingestion belongs to its separate path; the digest was verified directly here. |
| 4. Serialized retry and SQL idempotence | Local tests cover active Job replacement and explicit nonce retry. The three live Job intervals did not overlap. The supplied SQL ran three times against one disposable database; table, migration, index counts and column catalog fingerprint stayed identical. | The live rerun used a Secret version change; explicit nonce behavior remains local-test evidence. |
| 5. Focused tests and captured evidence | The JSONL contains sanitized lifecycle results. Local API-server tests show succeeded/failed Job and Deployment status events enqueue their owner. The live scoped controller advanced the disposable AIService to `PostgresSchemaSetupReady=True` and `Ready=True`. | The production operator Deployment was not replaced; a temporary label-scoped controller ran the same production reconciler. Full profile installation and OS qualification are separate stories. |

## Commands and results

With a writable Go cache and offline module mode, the focused result stream was
captured in [mpr-189-results.jsonl](validation/mpr-189-results.jsonl):

```text
GOCACHE=/private/tmp/mpr189-gocache GOPROXY=off go test -json ./pkg/ai/features/agentruntime -run '^TestSchema' -count=1 > docs/agent-runtime/validation/mpr-189-results.jsonl
go test ./api/v1 ./pkg/ai ./internal/candidatecontract ./cmd/candidate-contract
go vet ./pkg/ai/features/agentruntime ./internal/candidatecontract
```

All commands passed. The JSONL has 92 events, 20 passing test/subtest/package
events, and zero failures. The candidate renderer suite passed for `cpuOnly`,
`fullfeature`, and candidate refreshes after the rebase. Its schema digest is
synthetic test input and is labelled as such in the snapshot scope.

The controller watch regression was first run with the old global filter and
failed at the completed Job status update after two seconds with no reconcile
request. After the filter change, this focused local API-server command passed:

```text
KUBEBUILDER_ASSETS=/Users/kchoudhary/splunk-ai-operator/bin/k8s/1.35.0-darwin-arm64 \
  GOCACHE=/private/tmp/mpr189-gocache GOPROXY=off \
  go test ./internal/controller -run '^TestControllers$' \
  -ginkgo.focus='AIService owned status watches|cpuOnly AIPlatform end to end' \
  -count=1 -timeout 180s
```

The watch test uses a real API server and a reconciler that returns no retry.
It observes an owner request after each terminal Job status update and after
Deployment readiness. The full controller test confirms the resulting
`PostgresSchemaSetupReady=True` condition. These checks isolate the watch path
from error-backoff retries, which had hidden the defect in an earlier full
controller test. The complete controller test suite also passed with the same
local API-server assets and offline Go module settings:
`go test ./internal/controller -count=1 -timeout 300s`.

The result stream captured this sanitized projection of the actual in-memory
Job returned by the operator, plus condition and rerun observations:

```text
jobEvidence={"name":"schema-lifecycle-schema-a85004b3375edd8e","ownerUID":"schema-lifecycle-uid","image":"docker.io/splunk/agent-runtime-schema-setup@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","imageDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","deadlineSeconds":300,"backoffLimit":1,"ttlSeconds":86400,"condition":"Pending"}
unchanged pending reconciliation: jobCount=1
completed schema Job: condition=Succeeded
successful Job after TTL cleanup: condition=Succeeded jobCount=0
deadline failure: condition=TimedOut message=schema Job exceeded its deadline; change schemaRetryNonce to retry
retry-limit failure: condition=Failed message=schema Job exhausted its retry limit; change schemaRetryNonce to retry
explicit nonce retry: condition=Pending jobCount=1
input change during active Job: condition=Superseded
input change digest: condition=Pending totalJobs=2
input change secret version: condition=Pending totalJobs=2
input change postgres config: condition=Pending totalJobs=2
unreachable database: attempts=12 backoff=["1" "2" "4" "8" "8" "8" "8" "8" "8" "8" "8"] diagnostic="postgres unavailable after bounded wait"
```

The JSONL contains no database URL. The source assertions are in
[schema_lifecycle_test.go](../../pkg/ai/features/agentruntime/schema_lifecycle_test.go).

## `agentruntime-dev` live replay

The selected cluster was verified live in AWS account `658391232643`, region
`us-west-2`, with three Ready k0s nodes. Before the test, the original operator
was 1/1 Ready on `localhost/splunk-ai-operator:rebased-6c3c744-sslfix`; the
existing AIService UID `39598b65-89e6-4b32-ba5b-547dc9902036` was Ready.
The supplied schema tag `202609171357-39c5803f686e` resolved in ECR to
`sha256:5877fcbdea301b945af0be55eeb33bcb30c93b0e3b1906a58be779680650d987`.
The existing completed Job Pod had pulled that same digest. This direct
resolution satisfies the image input for this test without an MPR-187 handoff.

The exact story revision `badbbb6` built as a `linux/amd64` operator image,
verified in ECR at `sha256:cd5a38b651f192f09dfb5179ae54bdf1ecda5f55cc5dc5f54bcf4ec5a4d62cef`.
For safe isolation, a temporary image based on it added only the
[label-scoped controller entrypoint](../../cmd/mpr189-live/main.go), at
`sha256:0afe06fdf4975180971df15a8112b7a430b9a686859cd347ef0f88b3bf95c1d3`.
It registered the production AIService reconciler and filtered its AIService
cache to `mpr189-validation=badbbb6`. The original operator was paused only
during the scoped test phase; its image and environment were never replaced.
The AIPlatform controller did not run in the test image. The two additive CRD
changes were applied for the test and later restored from backups. An attempted
shortcut to mark the existing AIService's schema status as applied was rejected
by automatic review and was never executed; the test used only the disposable
AIService and database.

A new AIService, UID `50ef9109-3e5f-4aaa-9e0c-361bd7a2a979`, used only
`mpr189_badbbb6_20261118` and its own checkpoint Secret. The original operator
admitted it and completed the first SQL application before handoff. The scoped
MPR-189 controller then ran the same SQL with the pinned image. An unchanged
controller restart left the owned Job count at two. Changing a harmless key
only in the disposable Secret advanced its resource version from `20861569` to
`20869432` and created exactly one more Job:

| SQL run | Job suffix | UTC interval | Result |
| --- | --- | --- | --- |
| Existing operator, supplied tag | `2c0dd965` | 08:44:59–08:45:03 | Complete |
| MPR-189 scoped controller, pinned digest | `f6b845b6776a8f31` | 08:47:27–08:47:31 | Complete; input hash and recorded image digest match |
| MPR-189 after Secret version change | `cd3d381f96a8c0f1` | 08:50:52–08:50:56 | Complete; new input hash, same image digest |

Both MPR-189 Jobs had owner UID `50ef9109-3e5f-4aaa-9e0c-361bd7a2a979`,
300 second active deadline, backoff limit 1, and 86400 second terminal TTL.
The intervals did not overlap. The test AIService ended with
`PostgresSchemaSetupReady=True / Succeeded`, `Ready=True`, and the verified
image digest in status. The Job output ended with `Schema setup complete.`

Credential-free PostgreSQL checks before and after both reapplications were
identical: four checkpoint tables, nine migration rows, ten indexes, and
column catalog MD5 `7e112569e4541dc1b18939c97921b342`. The queried database
name was the disposable database on every check. This proves the supplied
schema file completed three applications without changing that observed
catalog and seed count; it does not make a claim about application requests.

Cleanup was verified: the disposable AIService, Secret, Jobs, controller and
database were removed; the two CRDs returned to their original schemas; the
original operator was again 1/1 Ready on its original image and pull policy;
the existing AIPlatform and AIService retained their UIDs and Ready status.
Both temporary ECR tags were deleted and verified absent. The temporary SSH
rule `sgr-0cabc47c8fb8f3685` was revoked and verified absent, and the tunnel
was closed. The two ECR pull Secrets were refreshed because their previous
tokens had expired; they remain refreshed. Full profile installation and OS
qualification remain with MPR-193/MPR-190/MPR-192.
