# Agent Launchpad product qualification evidence

> Copy this template for one immutable product-image execution. Do not include
> credentials, tokens, connection URLs, Kubernetes Secret contents, raw request
> payloads, raw model output, raw checkpoint content, or unsanitized logs.

## Result vocabulary

Use only `PASS`, `FAIL`, `BLOCKED`, `KNOWN_FAIL`, or `NOT_RUN`.

- `KNOWN_FAIL` identifies a reproduced, separately owned defect; it is not a
  pass or a waiver.
- `BLOCKED` identifies a missing dependency or required test input.
- A local harness pass is not live product acceptance.

## Execution metadata

- Execution ID: `<non-secret unique ID>`
- Start/end time (UTC): `<timestamps>`
- Tester: `<name/team>`
- Environment: `<environment name>`
- Installer host: `<approved installer host identity>`
- Kubernetes context: `<sanitized context name>`
- Namespace: `<namespace>`
- Evidence commit: `<operator branch commit>`
- Overall functional result: `<PASS|FAIL|BLOCKED>`
- Overall credential gate: `KNOWN_FAIL (MPR-131)`

## Immutable identity

### Product

- Launchpad source repository: `<repository>`
- Source commit: `<full SHA>`
- Configured image reference: `<repository:tag or repository@digest>`
- Resolved registry digest: `<sha256:...>`
- Pod image ID: `<registry/repository@sha256:...>`
- Agent Server/runtime version: `<version>`
- Graph ID: `<graph>`
- Assistant ID: `<sanitized ID>`
- Input/context/output schema identity: `<version or digest>`

### Platform and caller

- Operator image/digest: `<reference>` / `<sha256:...>`
- Embedded chart version/archive digest: `<version>` / `<sha256>`
- AIPlatform/AIService generation: `<generation>`
- Helm release/revision: `<release>` / `<revision>`
- API Deployment: `<name>`
- Queue Deployment: `<name>`
- Queue HPA: `<name>`
- Stable Service: `<name>`
- SLIM/AITK image/digest: `<reference>` / `<sha256:...>`
- Caller path tested: `<direct LAS|in-Pod SLIM|supported external route>`
- PostgreSQL resource identity: `<sanitized name/version>`
- Redis resource identity: `<sanitized name/version>`

## Dependency and acceptance gates

| Gate | Status | Evidence/limitation |
| --- | --- | --- |
| MPR-43 product image | `<status>` | `<immutable identity reference>` |
| MPR-58 credential handling | `KNOWN_FAIL` | `MPR-131; rerun required after fixed digest` |
| MPR-44 external SLIM edge | `<status>` | `<external route evidence or limitation>` |
| Installed AITK caller origin | `<status>` | `<AITK UI/backend-origin evidence or NOT_RUN>` |
| MPR-48 timeout/cancel semantics | `<status>` | `<evidence or limitation>` |
| Real KB configuration available | `<status>` | `<sanitized owner/availability statement>` |

## Surfaces inspected for synthetic canaries

Record only status and a sanitized evidence location. Do not paste the canary.

| Surface | Initial run | Resume | Notes |
| --- | --- | --- | --- |
| Direct response | `<status>` | `<status>` | `<notes>` |
| Caller response | `<status>` | `<status>` | `<notes>` |
| SSE/event stream | `<status>` | `<status>` | `<notes>` |
| Thread graph-state values | `<status>` | `<status>` | `<notes>` |
| Complete checkpoint history | `<status>` | `<status>` | `<notes>` |
| Run listing | `KNOWN_FAIL` | `KNOWN_FAIL` | `MPR-131 run.kwargs exposure` |
| API logs | `<status>` | `<status>` | `<sanitized time range>` |
| Queue logs | `<status>` | `<status>` | `<sanitized time range>` |
| SLIM/AITK logs | `<status>` | `<status>` | `<sanitized time range>` |
| Traces/diagnostics | `<status>` | `<status>` | `<notes>` |

## MPR-45: graph, model, and tool dependencies

| Case | Route | Expected outcome | Actual outcome | Duration | State/run ID | Result | Owner if failed |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Graph/schema discovery | `<route>` | `<expectation>` | `<sanitized result>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| Approved LLM call | `<route>` | `<expectation>` | `<sanitized result>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| MCP discovery/call | `<route>` | `<expectation>` | `<sanitized result>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| MCP approve/resume | `<route>` | `<expectation>` | `<sanitized result>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| MCP deny/resume | `<route>` | `<expectation>` | `<sanitized result>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| KB call | `<route>` | `<expectation>` | `<sanitized result>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| Missing LLM context | `<route>` | `safe actionable failure` | `<category/status>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| Invalid provider/model | `<route>` | `safe actionable failure` | `<category/status>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| Invalid MCP context | `<route>` | `safe actionable failure` | `<category/status>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| Invalid KB context | `<route>` | `safe actionable failure` | `<category/status>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |
| Unavailable dependency | `<route>` | `safe actionable failure` | `<category/status>` | `<s>` | `<IDs>` | `<status>` | `<owner>` |

MPR-45 functional conclusion: `<PASS|FAIL|BLOCKED>`

Credential conclusion: `KNOWN_FAIL (MPR-131); MPR-58 rerun required`

## MPR-47: product regression matrix

| Case | Route | Input/schema class | Expected | Actual | Duration | Reproduction ID | Result | Classification |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Ordinary model response | `<route>` | `<class>` | `<expectation>` | `<sanitized result>` | `<s>` | `<ID>` | `<status>` | `<product/caller/platform/dependency>` |
| Structured output schema 1 | `<route>` | `<class>` | `<required keys/types>` | `<structural result>` | `<s>` | `<ID>` | `<status>` | `<classification>` |
| Structured output schema 2 | `<route>` | `<class>` | `<required keys/types>` | `<structural result>` | `<s>` | `<ID>` | `<status>` | `<classification>` |
| Conversation follow-up | `<route>` | `<class>` | `<expectation>` | `<sanitized result>` | `<s>` | `<ID>` | `<status>` | `<classification>` |
| HITL resume | `<route>` | `<class>` | `<expectation>` | `<sanitized result>` | `<s>` | `<ID>` | `<status>` | `<classification>` |
| Malformed JSON | `<route>` | `invalid` | `rejected safely` | `<category/status>` | `<s>` | `<ID>` | `<status>` | `<classification>` |
| Missing required field | `<route>` | `invalid` | `rejected safely` | `<category/status>` | `<s>` | `<ID>` | `<status>` | `<classification>` |
| Wrong field/schema type | `<route>` | `invalid` | `rejected safely` | `<category/status>` | `<s>` | `<ID>` | `<status>` | `<classification>` |
| Unsupported provider/tool | `<route>` | `invalid` | `rejected safely` | `<category/status>` | `<s>` | `<ID>` | `<status>` | `<classification>` |
| Downstream failure | `<route>` | `negative` | `mapped safely` | `<category/status>` | `<s>` | `<ID>` | `<status>` | `<classification>` |

MPR-47 conclusion: `<PASS|FAIL|BLOCKED>`

External-route or installed-AITK-origin limitation, if any: `<exact missing evidence>`

## MPR-50: streaming and persisted state

### Protocol results

| Mode | Route | Thread ID | Run ID | Event types/terminal status | Non-secret marker persisted | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Synchronous | `<route>` | `<ID>` | `<ID>` | `<terminal>` | `<yes/no>` | `<status>` |
| Background/queued | `<route>` | `<ID>` | `<ID>` | `<terminal>` | `<yes/no>` | `<status>` |
| SSE | `<route>` | `<ID>` | `<ID>` | `<ordered event names; terminal>` | `<yes/no>` | `<status>` |

### Restart chronology

| Stage | UTC time | Deployment/revision | Ready state | Existing sync state | Existing queue state | Existing SSE state | New background run | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Before restart | `<time>` | `<revision>` | `<ready>` | `<status>` | `<status>` | `<status>` | `N/A` | `<status>` |
| After API restart | `<time>` | `<revision>` | `<ready>` | `<status>` | `<status>` | `<status>` | `<status>` | `<status>` |
| After queue restart | `<time>` | `<revision>` | `<ready>` | `<status>` | `<status>` | `<status>` | `<status>` | `<status>` |

MPR-50 conclusion: `<PASS|FAIL|BLOCKED>`

External-route or installed-AITK-origin limitation, if any: `<exact missing evidence>`

## MPR-49: lifecycle, load, and HPA

### Lifecycle phases

| Phase | Exact target | Work in progress | Expected | Actual terminal/state outcome | Rollout/recovery evidence | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Product image/config upgrade | `<target>` | `<queued/active/none>` | `<expectation>` | `<outcome>` | `<revision/readiness>` | `<status>` |
| Managed Secret rotation | `<target>` | `<queued/active/none>` | `<expectation>` | `<outcome>` | `<revision/readiness>` | `<status>` |
| API restart | `<target>` | `<queued/active/none>` | `<expectation>` | `<outcome>` | `<revision/readiness>` | `<status>` |
| Queue restart | `<target>` | `<queued/active/none>` | `<expectation>` | `<outcome>` | `<revision/readiness>` | `<status>` |
| PostgreSQL recovery | `<target>` | `<queued/active/none>` | `<expectation>` | `<outcome>` | `<readiness/state>` | `<status>` |
| Redis recovery | `<target>` | `<queued/active/none>` | `<expectation>` | `<outcome>` | `<readiness/state>` | `<status>` |

### Representative product load

- Concurrent requests: `<count>`
- Duration/window: `<duration>`
- Latency minimum/median/p95/maximum: `<values>`
- Success/failure counts: `<values>`
- Queue backlog samples: `<sanitized values>`
- HPA current/desired samples: `<values>`
- Queue ready-replica samples: `<values>`
- CPU samples/availability: `<values>`
- Observed product-load scaling: `<scaled|no_cpu_scale_observed|blocked>`
- Multi-worker execution attribution source: `<supported field or sanitized log correlation>`
- Workers that executed jobs: `<sanitized worker IDs/count>`
- Every run terminal and every marker present: `<yes/no; evidence reference>`

### Deterministic CPU-control HPA result

- HPA minimum/maximum: `<min>/<max>`
- CPU utilization target: `<target>`
- Scale-down stabilization/policy: `<values>`
- Starting current/desired/ready: `<values>`
- Peak current/desired/ready: `<values>`
- Maximum cap respected: `<yes/no>`
- API remained at one replica: `<yes/no>`
- Returned to minimum/floor: `<yes/no and elapsed time>`
- Active-run scale-down outcome: `<terminal/retry/failure and agreed classification>`
- Result: `<status>`

### Dependency capacity

- PostgreSQL configured connection limit reviewed: `<yes/no; sanitized source>`
- Estimated peak PostgreSQL consumers: `<count/rationale>`
- Redis client/capacity limit reviewed: `<yes/no; sanitized source>`
- Estimated peak Redis consumers: `<count/rationale>`
- Capacity conclusion: `<PASS|FAIL|BLOCKED>`

MPR-49 conclusion: `<PASS|FAIL|BLOCKED>`

Timeout/cancellation limitation, if any: `<MPR-48 status and missing evidence>`

## Defects and reproductions

| Defect | Priority/owner | Affected rows | Sanitized reproduction | Status | Required rerun |
| --- | --- | --- | --- | --- | --- |
| MPR-131 | `<owner>` | `credential surfaces` | `run listing exposes run.kwargs` | `KNOWN_FAIL` | `all canary surfaces on fixed digest` |
| `<key>` | `<value>` | `<rows>` | `<steps without secrets>` | `<status>` | `<scope>` |

## Cleanup and restored state

- Temporary assistants deleted: `<yes/no/list of retained IDs>`
- Temporary threads deleted: `<yes/no/list of retained IDs>`
- Port-forwards stopped: `<yes/no>`
- API/queue Ready: `<yes/no>`
- Queue returned to HPA floor: `<yes/no>`
- API replica count is one: `<yes/no>`
- PostgreSQL/Redis Ready: `<yes/no>`
- Final product image/config identity: `<digest/config generation>`
- Intentionally retained evidence/artifacts and owner: `<list>`

## Rerun decision

Mark every applicable trigger:

- [ ] Launchpad image digest/source changed.
- [ ] Graph or schema changed.
- [ ] Agent Server/runtime changed.
- [ ] SLIM/AITK image, mapping, authentication, or route changed.
- [ ] Operator/chart/Helm/HPA configuration changed.
- [ ] LLM/MCP/KB provider configuration changed.
- [ ] PostgreSQL/Redis implementation or capacity changed.
- [ ] MPR-131 fix was deployed.

Required rerun scope: `<cases/phases>`

## Publication attestation

- [ ] No credential, token, connection URL, or Secret value is present.
- [ ] No raw request payload or raw model output is present.
- [ ] No raw checkpoint, run kwargs, or unsanitized log content is present.
- [ ] Every `PASS` maps to executed evidence for the exact immutable digest.
- [ ] MPR-131 is represented as `KNOWN_FAIL`, not `PASS` or omitted.
- [ ] Direct LAS, in-Pod SLIM, external SLIM, and installed-AITK-origin evidence are distinguished.
- [ ] Unmet installed-AITK-origin/MPR-48 gates are recorded as limitations.
