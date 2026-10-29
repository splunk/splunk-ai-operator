# Agent Launchpad qualification evidence — 2026-10-29

This record contains sanitized evidence from the earlier installer integration
environment. It contains no credentials, request bodies, raw model output,
connection URLs, Secret data, checkpoint contents, or unsanitized logs.

The external caller rows below are supplemented by the immutable execution
record in
[`mpr-44-caller-route-evidence-20261030.md`](mpr-44-caller-route-evidence-20261030.md).

## Execution summary

- Environment: approved installer EC2 integration cluster
- Installer host: approved installer host (address omitted from publishable evidence)
- Kubernetes context: `Default`
- Namespace and UID: `ai-platform` / `29d5efa1-04b4-4c95-86dc-992bc3f8761a`
- Evidence base commit: `f590502127efaffd4a4688d52c778e059dfb027d`
- Execution completed: `2026-10-29T19:54:30Z`
- Executed direct-Agent-Server rows: `PASS`
- Full four-story conclusion: `BLOCKED` by the explicitly listed dependencies and
  unexecuted owner-input phases
- Credential gate: `KNOWN_FAIL (MPR-131)`; it was not waived or converted to a
  pass

## Immutable deployed identity

- Launchpad source commit represented by the image:
  `00f6ded582253e55c7ff267fd734976d83a83eba`
- Configured Launchpad image:
  `658391232643.dkr.ecr.us-west-2.amazonaws.com/agent-launchpad:main-00f6ded-20261028`
- Resolved Launchpad digest:
  `sha256:5cc1a49d2f3de8cd324e1ce42009216a617f95d162ff05462ac3f1163b63fccb`
- API and queue Pod image IDs matched that digest before and after restart.
- Agent Server/runtime version: `0.2.3`
- Registered graph ID: `agent`
- Operator digest:
  `sha256:1913af32312218a5343f084e86139cafd674534d8c219ab1bb187a5538794d12`
- Helm release: `las-agentruntime-dev-ai-p-eb88ba0f`, revision `27`
- Live chart: `langgraph-cloud-0.3.5-splunk.2`
- Declared embedded chart archive SHA-256:
  `4fa2580f6e38254f399cc23e230f314dfdf42566f71df41ff1e4b23d36426058`
- Stable API Service:
  `agentruntime-dev-ai-platform-agentruntime-mltk-svc`
- API Deployment:
  `las-agentruntime-dev-ai-p-eb88ba0f-langgraph-cloud-api-server`
- Queue Deployment and HPA:
  `las-agentruntime-dev-ai-p-eb88ba0f-langgraph-cloud-queue`
- SLIM configured image:
  `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/slim-api:202609221216-80c31ac1a210`
- PostgreSQL and Redis were observed as the host Podman containers
  `mltk-postgres` (`postgres:16`) and `las-redis`
  (`redis:7.4.11-alpine`). Neither container was interrupted.

## Graph and schema discovery

- Graph search found one registered `agent` graph: `PASS`.
- A temporary assistant was created and deleted: `PASS`.
- Input fields were `messages`, `skills`, `structured_output`, and
  `system_prompt`.
- Context fields were `kb_configs`, `llm_config`, and `mcp_configs`.
- Output field was `messages`.

## MPR-45 dependency qualification

- Mock OpenAI-compatible LLM integration through the deployed product graph:
  `PASS`. This proves request mapping and model-client connectivity to the
  controlled fixture; it is not evidence for a real cloud provider or public
  egress.
- Mock Streamable HTTP MCP discovery and `greet` invocation: `PASS`. Persisted
  state contained the deterministic tool result and the final synthetic result;
  the thread was deleted.
- Real owner-approved Bedrock LLM call through the authenticated external SLIM
  edge: `PASS`; the terminal result contained the expected non-secret marker,
  and a second same-session call recalled the expected marker.
- Real owner-approved KB call: `BLOCKED`. No non-production Bedrock KB identity
  and role were supplied. The product has no local live-KB fixture.
- MCP approval/deny resume: `NOT_RUN`. The deterministic MCP fixture did not
  require approval.
- Missing LLM config: expected terminal `error`, observed terminal `error`,
  thread deleted: `PASS`.
- Unsupported provider: expected terminal `error`, observed terminal `error`,
  thread deleted: `PASS`.
- MCP missing URL: expected terminal `error`, observed terminal `error`, thread
  deleted: `PASS`.
- Public-context `stdio` MCP: expected terminal `error`, observed terminal
  `error`, thread deleted: `PASS`.
- Empty KB ID: expected terminal `error`, observed terminal `error`, thread
  deleted: `PASS`.

MPR-45 result: `BLOCKED` for full acceptance because the real KB row and the
MPR-58 credential gate remain outstanding. The real Bedrock egress, controlled
LLM/MCP, and negative-validation rows passed.

## MPR-47 regression qualification

- Ordinary model response and persisted state via direct Agent Server:
  `PASS`.
- Structured output with required string fields, persisted marker, and cleanup:
  `PASS`.
- Five missing/invalid dependency cases: `PASS` as expected failures.
- Authenticated external SLIM ordinary Bedrock response: `PASS`.
- External caller-route conversation follow-up on the same session: `PASS`.
- Missing/malformed bearer denial and byte-level malformed JSON rejection:
  `PASS`.
- Assistant deletion plus direct LAS assistant/thread HTTP 404 cleanup:
  `PASS`.
- The original in-Pod helper remained incompatible with the cluster's primary
  SLIM image. MPR-44 therefore used an isolated, digest-pinned candidate without
  replacing the operator-owned SLIM AIService; its temporary cluster resources
  and remote test artifacts were removed after the recorded checks.
- Structured-output, MCP-tool, typed negative dependency, and HITL rows through
  the external edge: `NOT_RUN`; their direct/in-Pod supporting rows must not be
  relabeled as external-edge evidence.
- Installed AITK application caller origin: `NOT_RUN`; the cluster did not have
  an installed AITK/MLTK agent application.

MPR-47 result: `BLOCKED` pending the unexecuted external structured-output,
tool, typed-negative, HITL, and installed-AITK-origin rows. External ordinary,
same-session, authentication, malformed-input, and cleanup rows passed; direct
product and structured-output supporting rows also passed.

## MPR-50 protocol and persistence qualification

- Synchronous run: HTTP 200, terminal success, expected marker persisted,
  thread deleted: `PASS`.
- Queued run: HTTP 200, terminal success, expected marker persisted, thread
  deleted: `PASS`.
- SSE run: HTTP 200, terminal success, expected marker persisted, thread
  deleted: `PASS`.
- The pinned runtime emitted `metadata`, followed by three `values` events. It
  did not emit an explicit `end` event. A stream-only probe established this
  version-specific contract before the final assertion.
- Initial sync, queued, and SSE state survived API revision `28 -> 29`: `PASS`.
- The same state survived queue revision `29 -> 30`: `PASS`.
- A second sync, queued, and SSE protocol matrix passed after recovery.
- All six intentionally retained restart-test threads were deleted before the
  helper emitted its final `PASS`.
- In-flight run across queue replacement: `NOT_RUN`; no deterministic bounded
  delay fixture exists in this product image.

MPR-50 direct-Agent-Server result: `PASS`. The external SLIM route's final NDJSON
mapping and same-session behavior also passed. Background/queued and SSE
protocol behavior was verified directly against Agent Server because this SLIM
contract exposes the final mapped result rather than separate public queue/SSE
operations. Installed-AITK-origin attribution remains `NOT_RUN`.

## MPR-49 lifecycle, load, and HPA qualification

- Exact operator, API, queue, chart, graph, context, and namespace identities:
  `PASS`.
- HPA policy: minimum `1`, maximum `3`, CPU target `80%`, scale-down window
  `300s`, `Min` policy, one Pod per `60s`: `PASS`.
- Representative load submitted six concurrent queued product runs: six
  completed, zero failed, and every thread was deleted.
- Run latency was 2.172s minimum, 2.179s p50, 2.225s p95, and 2.225s maximum.
- Peak queue CPU average utilization was `1%`; current, desired, and ready queue
  replicas remained `1`; API replicas remained `1`.
- Product-load scale observation: `no_cpu_scale_observed`. This is an honest
  result for the short I/O-bound mock workload, not a deterministic CPU-scaling
  pass.
- API and queue controlled restarts, rollout recovery, and state persistence:
  `PASS`.
- Product image/config upgrade: `NOT_RUN`.
- Managed Secret rotation: `NOT_RUN`; no disposable replacement credentials or
  installer configs were supplied.
- PostgreSQL/Redis interruption and recovery: `NOT_RUN`; they are host Podman
  containers and were deliberately left untouched.
- Deterministic CPU scale-up/cap/downscale proof: `BLOCKED`; the deployed
  Launchpad graph has no CPU-burn operation.
- Timeout/cancellation and active-work classification: `BLOCKED` by MPR-48.
- Per-worker attribution: `BLOCKED`; the Agent Server API did not expose it and
  unsanitized queue logs were not used.

MPR-49 result: `BLOCKED` until the unexecuted lifecycle inputs and MPR-48 are
available. The exact-identity, representative-load, HPA-policy, restart, and
persistence rows passed.

## Credential and safety status

- No real credential was used in this execution. The fixtures used only a
  synthetic non-secret key value.
- Run-list credential exposure was not re-tested. It remains
  `KNOWN_FAIL (MPR-131)` based on the separately recorded reproduction.
- This execution does not claim that response, checkpoint, run-list, log, or
  trace credential redaction passed.
- MPR-58 must be rerun against a fixed immutable digest before the credential
  gate can pass.

## Repository regression verification — 2026-10-30

- Cluster setup suite: `303 passed`, `0 failed`, `0 skipped`.
- LAS deployment helper: `17 passed`.
- Installer dry-run matrix: all `5` configurations passed.
- Runtime/product-route helper: `48 passed`.
- Lifecycle/rotation helper: `19 passed`.
- External SLIM caller helper: `19 passed`.
- Python compilation, Bash syntax, workflow YAML parsing, and `git diff --check`:
  `PASS`.

These are offline harness/regression results. They support the live evidence
above but do not convert an unexecuted or dependency-blocked live row to
`PASS`.

## Cleanup and restored state

- Temporary assistants: deleted.
- Temporary protocol, negative, MCP, structured-output, load, and restart
  threads: deleted and verified by the helpers before `PASS`.
- Managed port-forwards: stopped.
- Disposable mock LLM and MCP processes: stopped.
- Temporary files copied into the active SLIM Pod: deleted.
- Private EC2 test directory: deleted after sanitized results were copied for
  this record.
- API and queue Deployments: one Ready/Available replica each after testing.
- Queue HPA: current `1`, desired `1`, CPU `0%`, bounds `1..3` after testing.
- Final API and queue Pod image IDs still matched the qualified Launchpad
  digest.
- PostgreSQL and Redis remained running and were not modified.
- Temporary SSH security-group ingress: the exact temporary rule used for the
  external caller qualification was revoked; AWS readback returned no matching
  rule.

## Required reruns

- Rerun real LLM and KB rows when owner-approved non-production identities are
  available.
- Run the remaining external structured-output, MCP-tool, typed-negative, and
  HITL rows when their deterministic fixtures are available. Run the installed
  AITK caller-origin check when an AITK/MLTK agent application is installed.
- Rerun timeout/cancel and active-work replacement rows when MPR-48 is deployed.
- Rerun upgrade, Secret rotation, deterministic CPU-control, dependency
  recovery, and worker-attribution rows only with the required disposable
  inputs and explicit authorization.
- Rerun all credential surfaces after the MPR-131 fix is deployed on a new
  immutable digest.
