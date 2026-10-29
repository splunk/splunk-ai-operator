# LAS queue, restart, product-case, and scale qualification

This document describes the runnable qualification for AIP-5409, AIP-5410,
and AIP-5411. It distinguishes code-level coverage from evidence that must come
from an isolated cluster and the approved product image.

## AIP-5409: caller, queued run, stream, and persisted state

`scripts/las-runtime-acceptance.py protocol` uses the Agent Server REST API to
run one or more cases synchronously, through the background queue, and through
the SSE endpoint. It checks completion and reads the graph state from the
separate `/threads/{thread_id}/state` endpoint. Persistence checks inspect only
`payload.values`; metadata, checkpoint metadata, run output, or unrelated
response fields cannot satisfy the graph-state marker check. The protocol
check also rejects user-supplied sensitive markers if they appear in run
output, streamed data, or persisted graph values.

The scenario is piped on stdin. Do not save product credentials or a product
payload fixture in the repository or shell history. Example with the
deterministic graph:

```sh
cat <<'JSON' | LAS_BASE_URL=http://127.0.0.1:18083 python3 scripts/las-runtime-acceptance.py protocol
{
  "graph_id": "contract_fixture",
  "cases": [{
    "name": "caller-baseline",
    "input": {"request": "qualification-marker-unique-value"},
    "expected_state_values": ["qualification-marker-unique-value"],
    "run_modes": ["sync", "queued", "stream"]
  }]
}
JSON
```

For authenticated LAS, set `LAS_API_KEY` in the environment. The tool does not
print the key, request input, or response bodies. The output contains check
names, generated thread IDs, and pass/fail status only. Keep case names and
expected values non-sensitive. Add known credential canaries to each case's
`sensitive_values` list when checking redaction.

To verify database-backed state survives an API and queue rollout, use
`scripts/las-restart-persistence-acceptance.sh` only in a disposable cluster.
Set `LAS_DISPOSABLE_CLUSTER_CONFIRMED=true`, the LAS URL, namespace, and exact
API/queue Deployment names. It creates a synchronous and a queued fixture run,
then runs `kubectl rollout restart` on the API and queue sequentially and
checks both graph-state markers after each restart. This script changes
Kubernetes workloads. Never point it at the shared development cluster.

## AIP-5410: approved product graph cases

`tools/cluster_setup/validation/aip5410_product_route_acceptance.py` runs
inside the SLIM Pod and exercises the actual `create_agent` / `invoke_agent`
caller path. It accepts JSON on stdin, creates a temporary assistant, executes
one or more calls per case (including a caller resume when the case provides
`hitl_response`), checks the expected caller result and graph state values,
scans complete checkpoint history for supplied sensitive markers, and cleans
up the assistant and its threads.

This in-Pod helper validates SLIM's adapter and Launchpad mapping, but it
bypasses HTTP route registration and the external authentication middleware.
It therefore does not, by itself, satisfy the full caller-route requirement.
Use `tools/cluster_setup/validation/mpr44_product_caller_acceptance.py` from
outside the SLIM Pod against the supported Service endpoint for MPR-44 evidence;
the MPR-44 helper covers authenticated HTTP create/invoke/delete, terminal
NDJSON response mapping, same-session follow-up, negative authentication and
malformed request handling. See
[`mpr-44-caller-route-qualification.md`](mpr-44-caller-route-qualification.md).
It qualifies the external SLIM edge, not an installed AITK application's own
request construction; record that separate caller evidence when it is part of
the accepted product boundary.

Input shape:

```json
{
  "sensitive_values": ["<canary supplied by the secret owner>"],
  "cases": [{
    "name": "approved-product-case-name",
    "calls": [{
      "task_prompt": "<approved request>",
      "system_prompt": "<approved system context>",
      "llm": {"model": "<approved model>", "api_key": "<in-memory secret>"},
      "mcps": [],
      "knowledge_bases": [],
      "expected_text": "<approved expected result>"
    }]
  }]
}
```

The JSON must be piped from a trusted secret-management process or typed into
the running process; avoid shell history, checked-in fixtures, and command-line
arguments. The test only reports case/check names and pass/fail. It does not
print request bodies, model output, state values, or credentials. If a case
needs a resume, add a second entry in `calls` with its `hitl_response` and
expected post-resume result. The caller supplies approved graph ID through the
same LAS/SLIM configuration used for the candidate deployment.

This harness is ready for representative product cases, but it does not claim
product qualification until the approved immutable Launchpad image, graph ID,
trusted case inputs, expected outputs, model/MCP/knowledge-base access, license,
and permitted egress destinations are supplied. Those product artifacts are
tracked as AIP-5405 prerequisites. Do not substitute the contract fixture for
the product graph in the final acceptance record.

## AIP-5411: queue HPA runtime behavior

The deterministic fixture accepts `cpu_seconds` from 1 to 15 and burns CPU in
the Agent Server worker. The scale command sends bounded concurrent synchronous
runs while reading HPA and Deployment status with read-only `kubectl get`. It
confirms the HPA targets the named queue Deployment and that the starting
replicas are ready, then keeps observing after requests finish until both the
HPA count and ready worker count rise above their starting values or the
scale-up timeout expires. It also checks for current CPU metrics, the configured
replica cap, return to the minimum after the chart's 300-second stabilization
window, the ready worker floor, and an API Deployment configured for one
replica.

Example for an isolated disposable cluster:

```sh
LAS_DISPOSABLE_CLUSTER_CONFIRMED=true \
LAS_BASE_URL=http://127.0.0.1:18083 \
python3 scripts/las-runtime-acceptance.py scale \
  --namespace ai-platform \
  --hpa <exact-queue-hpa-name> \
  --deployment <exact-queue-deployment-name> \
  --api-deployment <exact-api-deployment-name> \
  --workers 4 --cpu-seconds 15 --timeout 300 --downscale-timeout 600
```

This creates test threads and runs. Use only with the contract fixture and a
disposable cluster. The script does not edit Deployments/HPA directly; the
operator and HPA own those resources. Choose a starting worker count below
`maxReplicas`, allow enough node CPU/memory headroom, and ensure Metrics API is
available. Any active workload may be interrupted by HPA scale-down; the graph
must be safe to retry.

Before running, record HPA min/max/CPU target and the chart stabilization
policy. After the run, record HPA current/desired replicas, conditions, events,
queue Pod readiness, run terminal states, and persisted request markers. The
static Go tests cover configuration bounds, CPU-only metrics, replica
ownership, API fixed replica, and scale-down policy; the runtime command
supplies cluster evidence. Connection-budget qualification must also compare
the configured PostgreSQL connection limit and Redis client capacity against
the maximum API + queue workload and any other users of those services. The
operator cannot infer server-side limits from the Secrets, and this harness
does not print or decode Secret values. Record those values from the database
and Redis configuration owners or approved administrative metrics.

## Evidence still requiring a cluster

Do not report the runtime stories as fully qualified from the local scripts
alone. Run the protocol, restart, and scale commands on an isolated LAS install
and retain their sanitized output plus HPA/rollout observations. The scale
test must show scale-up, cap, stabilized downscale, floor, API replica count,
and integrity of all request markers. AIP-5411 also needs an active-run
recovery observation across worker termination; this requires a deliberately
controlled run that lasts through a worker replacement and must be recorded
separately. This harness does not assert exactly-once execution. PostgreSQL
and Redis capacity must be reviewed against the actual configured workload.
