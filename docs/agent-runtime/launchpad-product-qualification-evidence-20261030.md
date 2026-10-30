# Agent Launchpad qualification evidence — 2026-10-30

This record contains only sanitized results. It contains no credentials, caller
tokens, request bodies, raw model output, connection URLs, Secret data,
checkpoint contents, or unsanitized logs. A `PASS` below means the stated
assertions were observed; `FAIL`, `KNOWN_FAIL`, `BLOCKED`, and `NOT_RUN` are not
acceptance passes.

This supplement follows the earlier evidence in
[`launchpad-product-qualification-evidence-20261029.md`](launchpad-product-qualification-evidence-20261029.md)
and the authenticated caller evidence in
[`mpr-44-caller-route-evidence-20261030.md`](mpr-44-caller-route-evidence-20261030.md).

## Immutable execution identity

- Launchpad image digest:
  `sha256:5cc1a49d2f3de8cd324e1ce42009216a617f95d162ff05462ac3f1163b63fccb`
- Launchpad source identity represented by the image:
  `00f6ded582253e55c7ff267fd734976d83a83eba`
- Agent Server/runtime version: `0.2.3`
- Registered graph ID: `agent`
- Operator digest:
  `sha256:1913af32312218a5343f084e86139cafd674534d8c219ab1bb187a5538794d12`
- Chart: `langgraph-cloud-0.3.5-splunk.2`
- Embedded chart archive SHA-256:
  `4fa2580f6e38254f399cc23e230f314dfdf42566f71df41ff1e4b23d36426058`
- Isolated external-caller candidate digest:
  `sha256:951ac687c0753399e9a636cd507ec541f55ecaade4717c19276d228115c003ef`
- Kubernetes namespace, Deployments, Service, and resource UIDs were checked
  before execution and are retained in the restricted execution record.

## MPR-45 — real dependency qualification

- Owner-approved Bedrock Knowledge Base configuration through the authenticated
  external SLIM edge: `PASS`.
- The first call constructed and used the configured Knowledge Base tool and
  returned the expected non-secret marker: `PASS`.
- A second call reused the same caller session and recalled the expected marker:
  `PASS`.
- Temporary assistant deletion and derived thread absence: `PASS`.
- The external helper scanned all inspected response, event, error, header, and
  cleanup surfaces and did not find a declared credential value in this path:
  `PASS` for the executed path only.
- A direct queued response exposed a declared credential canary:
  `KNOWN_FAIL (MPR-131)`. The credential gate remains blocked and this run does
  not claim that MPR-58 passed.
- A typed invalid-request rerun was attempted, but the cluster-local Splunk
  management endpoint alternated between reachable and connection-refused.
  JWT verification failed with HTTP 401 before the typed payload was evaluated:
  `BLOCKED (environment/auth dependency)`.

MPR-45 disposition: `BLOCKED`. The real Knowledge Base path passed, but the
current acceptance criteria still require the MPR-58 credential gate and safe
negative-dependency evidence.

## MPR-47 — product regression qualification

- Authenticated ordinary external call and same-session follow-up: `PASS`.
- Missing bearer, malformed bearer, and malformed JSON denial: `PASS` in the
  completed caller-route run.
- External structured output using both candidate request field names returned
  a plain non-JSON product response instead of the required object:
  `FAIL (structured-output contract)`.
- Typed invalid-request classification and empty-state proof:
  `BLOCKED (environment/auth dependency)` as described above.
- Direct-Agent-Server structured-output and negative supporting rows remain
  useful regression evidence, but they are not relabeled as external-edge
  evidence.

MPR-47 disposition: `BLOCKED`. Credential and cancellation deferral does not
waive the independent external structured-output failure or the unexecuted
typed-negative row.

## MPR-50 — protocol and restart persistence

A credential-free deterministic provider fixture was used for this matrix so
that the known MPR-131 exposure could not contaminate the persistence result.

- Initial synchronous run: `PASS` in `0.251s`.
- Initial queued run: `PASS` in `2.055s`.
- Initial SSE run: `PASS` in `0.102s`; ordered `metadata` and `values` events
  were observed, and terminal success was independently polled after the
  version-specific end-of-stream condition.
- Graph state and bounded checkpoint history contained each non-secret marker:
  `PASS` for all three modes.
- API Deployment revision `29 -> 30`: `PASS`.
- State and complete bounded checkpoint history after the API restart:
  `PASS` for all three modes.
- Queue Deployment revision `30 -> 31`: `PASS`.
- State and complete bounded checkpoint history after the queue restart:
  `PASS` for all three modes.
- Post-restart synchronous, queued, and SSE runs: `PASS` in `0.531s`, `2.068s`,
  and `0.099s` respectively.
- All six retained restart-test threads were deleted and absence was confirmed:
  `PASS`.
- In-flight run replacement: `NOT_RUN`; this remains part of the deferred
  interruption matrix tracked by MPR-48 and MPR-135.

MPR-50 technical disposition: `PASS` for sync, queued, SSE, state, checkpoint
history, both controlled restarts, post-restart operation, and confirmed
cleanup. Jira dependency closure remains subject to MPR-45 unless the owner
explicitly treats that dependency as test ordering rather than a completion
gate.

## MPR-49 — lifecycle, load, and autoscaling

- Exact operator, API, queue, chart, runtime, graph, and HPA identities:
  `PASS`.
- API and queue controlled restart recovery with state and checkpoint-history
  preservation: `PASS` through the MPR-50 matrix.
- Lifecycle/load/HPA execution preflight: `BLOCKED`. The operator Deployment
  had `0` Ready/Available replicas and was in `CrashLoopBackOff`; the API and
  queue workloads remained `1/1` Ready.
- Representative product load from the earlier run completed six of six queued
  requests with no failures, but queue CPU stayed below the HPA threshold and
  no scale transition occurred. It remains an observation, not deterministic
  scale-up/scale-down evidence.
- Deterministic HPA scale-up/cap/down/floor, cross-worker state correctness,
  operator/chart upgrade, Secret rotation, PostgreSQL recovery, Redis recovery,
  backlog metrics, and worker attribution: `NOT_RUN` or `BLOCKED`.
- Timeout/cancellation and in-flight replacement are deferred to MPR-48 and
  MPR-135, but that deferral does not waive the other lifecycle rows.

MPR-49 disposition: `BLOCKED`.

## Deferred qualification

[MPR-135](https://splunk.atlassian.net/browse/MPR-135) tracks the two explicitly
deferred areas:

- rerun credential-safety surfaces after MPR-131 is fixed and MPR-58 can run
  against the same immutable image digest;
- run bounded timeout, disconnect, cancellation, and in-flight queue
  replacement after MPR-48 is available.

MPR-135 explicitly does not waive structured-output, lifecycle, dependency
recovery, HPA, or worker-attribution acceptance criteria.

## Local regression results

- Runtime acceptance suite: `81 passed`.
- External caller suite: `33 passed`.
- Python and Bash syntax validation: `PASS`.
- `git diff --check`: `PASS`.

These local tests validate the harness and fail-closed assertions; they do not
convert a live `FAIL`, `BLOCKED`, or `NOT_RUN` row to `PASS`.

## Cleanup and final cluster state

- Temporary validation assistants and threads from completed runs were deleted
  and the strengthened helpers confirmed absence where reported above.
- Loopback port-forwards created by this execution were stopped.
- The digest-pinned candidate Deployment, Service, ConfigMaps, and temporary ECR
  pull Secret are removed during final cleanup.
- Launchpad API and queue Deployments remained `1/1` Ready at the final pre-
  cleanup check.
- PostgreSQL and Redis were not interrupted by this execution.
- The operator remained unavailable at the final lifecycle preflight, so no HPA
  or lifecycle acceptance claim is made.
