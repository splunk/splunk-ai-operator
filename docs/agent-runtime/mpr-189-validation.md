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

An additional scoped live replay used a disposable database and AIService,
preserving the active service and checkpoint database.

## Evidence assessment

The local test criterion is supported by direct, reproducible evidence below.
The focused suite also covers A → B → A schema digest transitions before
the first Job's TTL expires, both when B's completion was observed and when
it was not: the old A success is removed and a fresh A Job is created.
The PR review exposed a stale-success case after that replay: if the new A Job
failed or disappeared before its outcome was observed, its TTL cleanup could
make the old A success look current. The operator now invalidates the previous
applied result when a new attempt starts or is observed. Regression tests cover
both failed and unknown A replay outcomes after Job removal. A stale-cache
`AlreadyExists` result is re-read instead of adopting a retained Job as the
new attempt.
After [Saurabh's MPR-189 comment](https://splunk.atlassian.net/browse/MPR-189?focusedCommentId=24503970),
the controller watch path was also checked against a local Kubernetes API
server. The previous in-memory lifecycle tests did not exercise controller
event delivery, and the first watch test failed: a completed Job produced no
AIService reconcile request. The controller-wide event filter excluded status
updates even though the owned-Job filter admitted them. The corrected filter
and regression test now cover succeeded and failed Jobs and ready Deployments.
The API-server test also confirms that AgentRuntime schema state persists under
`status.featureStatus.agentRuntime.schema`, while AgentRuntime leaves the
legacy SAIA `schemaJobId` empty and the SLIM service has no feature status.
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

All commands passed. The JSONL has 108 events, 24 passing test/subtest/package
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

## Scoped live replay

The supplied schema image was resolved to an immutable digest before the test
Job ran. A temporary label-scoped controller used the production AIService
reconciler with a disposable AIService and PostgreSQL database. The original
operator was restored after the test.

An initial SQL application and two MPR-189 Jobs completed sequentially. An
unchanged controller restart created no new Job; changing the disposable
Secret version created exactly one. Both MPR-189 Jobs carried the 300 second
active deadline, backoff limit 1, and 86400 second terminal TTL. The AIService
ended with `PostgresSchemaSetupReady=True / Succeeded` and `Ready=True`.
The PostgreSQL checks remained at four tables, nine migration rows, and ten
indexes, with the same column catalog before and after replay. All disposable
resources were removed and the original resources returned to Ready. Exact
infrastructure identifiers and raw deployment evidence are intentionally
omitted from this repository. Full profile installation and OS qualification
remain with MPR-193/MPR-190/MPR-192.
