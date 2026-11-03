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
- Kubernetes context and namespace identity: verified against the approved
  integration cluster; exact values retained in the restricted execution
  record
- Evidence base commit: `f590502127efaffd4a4688d52c778e059dfb027d`
- Execution completed: `2026-10-29T19:54:30Z`
- Executed direct-Agent-Server behavioral rows: sync, queued, negative, load,
  and restart-state observations passed; strengthened SSE terminal and cleanup
  absence proof remain `BLOCKED` pending rerun
- Full four-story conclusion: `BLOCKED` by the explicitly listed dependencies and
  unexecuted owner-input phases
- Credential gate: `KNOWN_FAIL (MPR-131)`; it was not waived or converted to a
  pass

## Immutable deployed identity

- Launchpad source commit represented by the image:
  `00f6ded582253e55c7ff267fd734976d83a83eba`
- Configured Launchpad image: approved private-registry Launchpad repository and
  reviewed tag (exact reference retained in the restricted execution record)
- Resolved Launchpad digest:
  `sha256:5cc1a49d2f3de8cd324e1ce42009216a617f95d162ff05462ac3f1163b63fccb`
- API and queue Pod image IDs matched that digest before and after restart.
- Agent Server/runtime version: `0.2.3`
- Registered graph ID: `agent`
- Operator digest:
  `sha256:1913af32312218a5343f084e86139cafd674534d8c219ab1bb187a5538794d12`
- Helm release revision: `27` (release name retained in the restricted record)
- Live chart: `langgraph-cloud-0.3.5-splunk.2`
- Declared embedded chart archive SHA-256:
  `4fa2580f6e38254f399cc23e230f314dfdf42566f71df41ff1e4b23d36426058`
- Stable API Service, API Deployment, queue Deployment/HPA, and SLIM image:
  exact internal identifiers retained in the restricted execution record
- PostgreSQL and Redis were observed as host Podman containers running
  `postgres:16` and `redis:7.4.11-alpine`. Neither container was interrupted.

## Graph and schema discovery

- Graph search found one registered `agent` graph: `PASS`.
- A temporary assistant was created and its deletion request was accepted:
  historical observation. Confirmed absence was added to the hardened helper
  after this execution.
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
  its cleanup request was accepted.
- Real owner-approved Bedrock LLM call through the authenticated external SLIM
  edge: `PASS`; the terminal result contained the expected non-secret marker,
  and a second same-session call recalled the expected marker.
- Real owner-approved KB call: `BLOCKED`. No non-production Bedrock KB identity
  and role were supplied. The product has no local live-KB fixture.
- MCP approval/deny resume: `NOT_RUN`. The deterministic MCP fixture did not
  require approval.
- Missing LLM config: expected terminal `error`, observed terminal `error`, and
  cleanup request accepted: `PASS` for behavior; confirmed absence needs rerun.
- Unsupported provider: expected terminal `error`, observed terminal `error`,
  and cleanup request accepted: `PASS` for behavior; confirmed absence needs
  rerun.
- MCP missing URL: expected terminal `error`, observed terminal `error`, cleanup
  request accepted: `PASS` for behavior; confirmed absence needs rerun.
- Public-context `stdio` MCP: expected terminal `error`, observed terminal
  `error`, cleanup request accepted: `PASS` for behavior; confirmed absence
  needs rerun.
- Empty KB ID: expected terminal `error`, observed terminal `error`, cleanup
  request accepted: `PASS` for behavior; confirmed absence needs rerun.

MPR-45 result: `BLOCKED` for full acceptance because the real KB row and the
MPR-58 credential gate remain outstanding. The real Bedrock egress, controlled
LLM/MCP, and negative-validation rows passed.

## MPR-47 regression qualification

- Ordinary model response and persisted state via direct Agent Server:
  `PASS`.
- Structured output with required string fields and persisted marker: `PASS`;
  its cleanup request was accepted, while confirmed absence needs rerun.
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
same-session, authentication, malformed-input, and independently confirmed
cleanup rows passed; direct product and structured-output supporting rows also
passed, with their older cleanup proof limited to accepted deletion requests.

## MPR-50 protocol and persistence qualification

- Synchronous run: HTTP 200, terminal success, expected marker persisted, and
  cleanup request accepted: `PASS` for behavior; confirmed absence needs rerun.
- Queued run: HTTP 200, terminal success, expected marker persisted, and cleanup
  request accepted: `PASS` for behavior; confirmed absence needs rerun.
- SSE run: HTTP 200 with the expected marker in ordered `metadata`/`values`
  events and cleanup: historical observation only. The pinned runtime emitted
  no explicit terminal event, and this execution predated the strengthened
  terminal-contract assertion: `BLOCKED` pending rerun with a reviewed,
  version-specific completion contract.
- Initial sync, queued, and SSE state survived API revision `28 -> 29`: `PASS`.
- The same state survived queue revision `29 -> 30`: `PASS`.
- A second sync and queued matrix passed after recovery. The second SSE run
  again produced the expected ordered values/state, but remains a historical
  behavioral observation rather than terminal-success acceptance evidence.
- Cleanup requests for all six intentionally retained restart-test threads were
  accepted before the historical helper emitted its final `PASS`; the run
  predated bounded read-back confirmation and therefore does not prove absence.
- In-flight run across queue replacement: `NOT_RUN`; no deterministic bounded
  delay fixture exists in this product image.
- Checkpoint-history read after completion/restart: `NOT_RUN`; neither the
  direct state helper nor the external caller helper queries checkpoint history.

MPR-50 direct-Agent-Server result: `BLOCKED` for full acceptance. Sync, queued,
and restart persistence passed; the SSE and confirmed-cleanup rows require a
strengthened rerun. The external SLIM route's final NDJSON mapping and
same-session behavior also passed. Background/queued behavior and the historical
SSE observation ran directly against Agent Server because this SLIM contract
exposes the final mapped result rather than separate public queue/SSE
operations. Installed-AITK-origin attribution remains `NOT_RUN`.

## MPR-49 lifecycle, load, and HPA qualification

- Exact operator, API, queue, chart, graph, context, and namespace identities:
  `PASS`.
- HPA policy: minimum `1`, maximum `3`, CPU target `80%`, scale-down window
  `300s`, `Min` policy, one Pod per `60s`: `PASS`.
- Representative load submitted six concurrent queued product runs: six
  completed, zero failed, and every cleanup request was accepted. Confirmed
  absence was not part of the historical helper.
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

- The original 2026-10-29 direct-Agent-Server execution used only synthetic
  fixture values. It did not use a real provider credential.
- The separate 2026-10-30 MPR-44 external-route supplement used approved
  Bedrock credentials in process memory and successfully exercised the real
  provider. No credential value was written to either evidence record.
- Run-list credential exposure was not re-tested. It remains
  `KNOWN_FAIL (MPR-131)` based on the separately recorded reproduction.
- This execution does not claim that response, checkpoint, run-list, log, or
  trace credential redaction passed.
- MPR-58 must be rerun against a fixed immutable digest before the credential
  gate can pass.

## Recorded repository regression baseline — 2026-10-30

- Cluster setup suite: `303 passed`, `0 failed`, `0 skipped`.
- LAS deployment helper: `17 passed`.
- Installer dry-run matrix: all `5` configurations passed.
- Runtime/product-route helper: `76 passed`.
- Lifecycle/rotation helper: `27 passed`.
- External SLIM caller helper: `24 passed`.
- Python syntax parsing, Bash syntax, changed multi-document YAML parsing,
  and `git diff --check`:
  `PASS`.

These are the current local regression results after the negative and
false-pass hardening described in this branch; use the current CI run for the
authoritative remote result. Offline harness results support the historical live
evidence but do not convert an unexecuted, stale, or dependency-blocked live row
to `PASS`.

## Cleanup and restored state

- Temporary assistants: the 2026-10-30 external-route assistant was confirmed
  absent; earlier direct helper deletion requests were accepted but not read
  back.
- Temporary protocol, negative, MCP, structured-output, load, and restart
  threads: historical deletion requests were accepted. This execution predated
  the current bounded read-back confirmation, so confirmed absence requires a
  rerun. The 2026-10-30 external-route thread was independently confirmed 404.
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
- Temporary SSH ingress: the exact story-scoped rule was revoked; cloud
  readback returned no matching rule. Its internal identifier is retained only
  in the restricted execution record.

## Required reruns

- Rerun the real KB row when an owner-approved non-production identity is
  available. The real Bedrock LLM row passed in the 2026-10-30 external-route
  supplement and needs rerun only when its identity or route changes.
- Rerun SSE with the strengthened terminal-completion contract and execute an
  explicit supported checkpoint-history read before changing the MPR-50 result
  from `BLOCKED`.
- Rerun direct protocol/load cleanup with the current bounded absence checks;
  historical 2xx deletion responses alone are not confirmed-deletion evidence.
- Run the remaining external structured-output, MCP-tool, typed-negative, and
  HITL rows when their deterministic fixtures are available. Run the installed
  AITK caller-origin check when an AITK/MLTK agent application is installed.
- Rerun timeout/cancel and active-work replacement rows when MPR-48 is deployed.
- Rerun upgrade, Secret rotation, deterministic CPU-control, dependency
  recovery, and worker-attribution rows only with the required disposable
  inputs and explicit authorization.
- Rerun all credential surfaces after the MPR-131 fix is deployed on a new
  immutable digest.
