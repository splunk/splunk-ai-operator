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

- Authenticated ordinary external Bedrock call and same-session follow-up:
  `PASS`. Both calls returned HTTP 200 terminal-success results, and the second
  call recalled a generated non-secret marker that was absent from its request.
- Missing bearer, malformed bearer, and malformed JSON denial: `PASS`.
- Direct LAS Bedrock structured output: `PASS` in `9.313s`. The response and
  persisted graph state matched the required object fields and types, the run
  reached terminal `success`, and deletion of the temporary thread was
  confirmed.
- The same Bedrock structured-output contract through the authenticated SLIM
  edge returned plain non-JSON product text: `FAIL`. Because the direct LAS
  run passed against the same Launchpad image, graph, model and schema, this is
  classified as a SLIM caller-field/response-mapping integration defect rather
  than a Launchpad graph or Bedrock defect.
- A wrong-type `task_prompt` through the authenticated SLIM edge returned an
  HTTP 200 transport envelope whose reported product error was HTTP 500 with
  category `platform`, instead of the expected HTTP 400/422 validation error:
  `FAIL (negative error contract)`. The returned response contained no graph
  state, and deletion of the temporary assistant was confirmed.
- Intermittent SLIM-to-Splunk verification produced one HTTP 401 precondition
  failure during the bounded reruns. It was not counted as a product result;
  the subsequent authenticated run completed the functional and typed-negative
  rows.
- Credential values were supplied from a protected local profile, held only in
  process memory, declared as leak canaries, and excluded from evidence output.
  MPR-131 remains the separate credential-persistence defect.

MPR-47 execution disposition: `COMPLETE_WITH_FAILURES`. Every executed
functional and negative row now has a recorded expected/actual result and a
concrete ownership reproduction. The product qualification result is not an
all-pass result: external structured-output mapping and typed validation-error
mapping both failed.

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
- Lifecycle/load/HPA execution preflight after operator recovery: `PASS`. The
  operator, API, and queue Deployments were each `1/1` Ready/Available; their
  configured and running digests, the API Service UID/EndpointSlice binding,
  Helm release/chart, namespace UID, and HPA policy all matched the immutable
  record.
- A credential-free Ollama-compatible fixture exercised the actual Launchpad
  graph without entering the known MPR-131 credential-exposure path. Sync,
  queued, and SSE modes reached terminal success, persisted unique markers,
  and confirmed all three thread deletions: `PASS`.
- Controlled API and queue replacements completed and advanced generations
  `30 -> 31` and `33 -> 34`; both returned to `1/1` Ready while the operator
  remained `1/1`: `PASS`. Immediately after queue replacement, metrics-server
  briefly reported `ScalingActive=False/FailedGetResourceMetric`; the CPU
  metric recovered to `ScalingActive=True` before the final verification.
- Post-replacement protocol verification repeated sync, queued, and SSE with
  terminal success and confirmed cleanup: `PASS`.
- The post-recovery representative load completed six of six concurrent queued
  requests with zero failures and confirmed cleanup. Durations were
  `2.164s` minimum, `2.165s` p50, `2.183s` p95/maximum. Queue CPU peaked at
  `2%`, so replicas correctly remained at one; this is
  `OBSERVATION_ONLY_NOT_HPA_ACCEPTANCE`, not deterministic scale evidence.
- Representative product load from the earlier run completed six of six queued
  requests with no failures, but queue CPU stayed below the HPA threshold and
  no scale transition occurred. It remains an observation, not deterministic
  scale-up/scale-down evidence.
- Deterministic HPA scale-up/cap/down/floor, cross-worker state correctness,
  operator/chart upgrade, Secret rotation, PostgreSQL recovery, Redis recovery,
  backlog metrics, and worker attribution: `NOT_RUN` or `BLOCKED`.
- Timeout/cancellation and in-flight replacement are deferred to MPR-48 and
  MPR-135, but that deferral does not waive the other lifecycle rows.

MPR-49 disposition: `BLOCKED`. Operator health, exact identity, controlled
replacement recovery, post-replacement protocol, representative load, and
cleanup are now verified. The remaining blockers are the intended
image/config upgrade input, disposable Secret-rotation configs, separately
authorized host-Podman dependency interruption, a CPU-control graph for causal
HPA scale-up/down evidence, and supported worker attribution.

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
- The temporary mock provider and copied validation helpers were stopped and
  removed from the installer host.
- The operator, Launchpad API, and queue Deployments were each `1/1`
  Ready/Available at the final check. The queue HPA returned to current/desired
  replica count `1`, CPU `0%`, and `ScalingActive=True`.
- PostgreSQL and Redis were not interrupted by this execution.
- No deterministic HPA scale acceptance, upgrade, Secret rotation, or
  PostgreSQL/Redis recovery claim is made by this rerun.
