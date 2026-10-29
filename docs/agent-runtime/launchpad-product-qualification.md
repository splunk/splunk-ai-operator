# Agent Launchpad product qualification

This runbook qualifies the deployed Agent Launchpad graph for MPR-45, MPR-47,
MPR-50, and MPR-49. It deliberately separates reusable test tooling from live
evidence. Passing local tests proves that the harness behaves correctly; it does
not prove that a particular product image, caller route, or Kubernetes release is
qualified.

Live testing for this campaign runs from the approved installer EC2 host, where
the cluster's `kubectl` context is configured. It must not run on the CPU
air-gapped qualification host.

## Qualification order and gates

Run the stories in this order:

1. **MPR-45:** actual graph, LLM, MCP, and applicable knowledge-base dependencies.
2. **MPR-47 and MPR-50:** product input/output/negative regression and
   sync/background/SSE persistence.
3. **MPR-49:** lifecycle, representative load, multi-worker state, and HPA
   behavior.

The following gates remain visible in every result:

- **MPR-131 is `KNOWN_FAIL`, not `PASS`.** Agent Server run listing currently
  exposes per-run context in `run.kwargs`. The owning team is fixing it. Do not
  weaken canary assertions, suppress the finding, or interpret successful
  functional tests as credential-handling acceptance. MPR-58 and the security
  part of MPR-45 remain blocked until the fix is deployed and rerun against the
  exact digest.
- **MPR-44 external SLIM edge is qualified.** The authenticated external SLIM
  contract, Bedrock invocation, same-session follow-up, malformed-input
  rejection, authentication failures, and cleanup passed on the recorded
  immutable digests. See
  [`mpr-44-caller-route-evidence-20261030.md`](mpr-44-caller-route-evidence-20261030.md).
  An installed AITK application's own request construction remains `NOT_RUN`;
  do not represent the external-edge result as an AITK UI or backend-origin
  result.
- **MPR-48 is not complete.** MPR-49 timeout, cancellation, and interruption
  acceptance remains partial until those semantics are agreed and verified.

Use these result values consistently:

- `PASS`: the exact check ran and met its expectation.
- `FAIL`: the check ran and contradicted its expectation.
- `BLOCKED`: a required dependency or test input was unavailable.
- `KNOWN_FAIL`: a reproduced, separately owned defect remains open.
- `NOT_RUN`: the check was outside this execution.

## Secret-handling rules

The qualification tools accept trusted scenario JSON on standard input so that
per-invocation context does not need to be committed, written to a scenario file,
or placed in command-line arguments.

- Start with unique synthetic canaries in LLM, MCP, and optional KB fields.
- Every scenario that carries credentials must list a unique synthetic or real
  `sensitive_values` canary. The helpers reject credential-bearing scenarios
  without declared canaries and also derive every recognized secret-bearing
  value (API/access keys, tokens, authorization headers, passwords, role ARNs,
  and similar fields) from the in-memory config into the scan set. An empty or
  partial manually declared list therefore cannot omit a recognized credential
  from redaction checks.
- Use owner-approved, short-lived, least-privilege non-production credentials
  only for the real dependency checks that need them.
- Never put credentials in Git, Jira, shell history, process arguments, evidence
  files, test names, expected text, or environment snapshots.
- Do not record raw model output. Record only the approved expectation name,
  structural outcome, status, timing, and sanitized identifiers.
- Never print or copy Kubernetes Secret data into evidence. Dependency binding
  decodes only the approved endpoint URL in memory to compare its hostname with
  the exact Service; rotation hashes only the three role-bound encoded values
  (`langgraph_cloud_license_key`, `postgres_connection_url`, and
  `redis_connection_url`). Neither helper emits a value or hash.
- Treat logs, diagnostics, responses, event streams, state, checkpoint history,
  and run listings as sensitive inspection surfaces. Published evidence contains
  only whether each surface passed, failed, or was blocked.
- Deleting a thread removes active application rows but does not prove erasure
  from database WAL, replicas, backups, or previously captured logs.

## Record the deployment identity first

Before submitting any run, record all of the following without Secret values:

- Launchpad source repository and commit.
- configured image reference, resolved registry digest, and Pod image ID;
- Agent Server/runtime version, graph ID, assistant ID, and graph/schema identity;
- operator image reference and digest;
- embedded chart version and archive digest;
- AIPlatform/AIService generation and observed Helm release revision;
- namespace, API Deployment, queue Deployment, Service, and queue HPA names;
- SLIM/AITK image identity and the route used by the test;
- PostgreSQL and Redis resource identities, but not connection URLs;
- UTC start time and tester-generated execution ID.

The registry digest is the authoritative product identity. If a mutable tag
resolves to a new digest, stop and create a new qualification record.

## Trusted scenario format

The caller-route helper reads a versioned document from standard input. The
illustrative shape below contains placeholders only:

```json
{
  "scenario_version": 1,
  "external_gates": {
    "MPR-131": "KNOWN_FAIL"
  },
  "sensitive_values": [
    "<unique synthetic LLM canary>",
    "<unique synthetic MCP canary>",
    "<unique synthetic KB canary>"
  ],
  "cases": [
    {
      "name": "representative-model-response",
      "calls": [
        {
          "task_prompt": "<owner-approved non-sensitive request>",
          "system_prompt": "<owner-approved non-sensitive instructions>",
          "llm": {"provider": "<provider>", "model": "<model>"},
          "mcps": [],
          "knowledge_bases": [],
          "expect": {
            "outcome": "success",
            "text": "<non-sensitive expected marker>"
          }
        }
      ]
    },
    {
      "name": "invalid-dependency",
      "expect_empty_state": true,
      "calls": [
        {
          "task_prompt": "<non-sensitive request>",
          "expect": {
            "outcome": "failure",
            "error_category": "dependency",
            "http_status": [502, 503],
            "owner": "dependency"
          }
        }
      ]
    }
  ]
}
```

For structured output, supply `structured_output` (or the caller version's
`structured_response` compatibility field) in the call. Set `expect.shape` with
`required` dotted paths and `types` using `array`, `boolean`, `integer`, `null`,
`number`, `object`, or `string`. Do not put a credential or raw expected model
answer in the schema. A resume case uses a second call in the same case with
`hitl_response` and fresh per-invocation context.

Set `expect_empty_state: true` only for a negative case whose contract says the
request must not create graph state. A missing thread (HTTP 404) and structurally
empty default containers count as empty; any persisted value fails the case.

The direct LAS protocol helper accepts complete product `input` and `context`
objects. Do not add the sample graph's `request` field to the Launchpad graph.
The Launchpad graph requires its actual message/system-prompt input and its LLM,
MCP, and KB context shape.

Use `expected_response_paths` only when the graph nests output under a reviewed
product-specific dotted path. Paths that select
request, input, context, checkpoint, or metadata fields are rejected. Without
an explicit path, the helper searches only
assistant/AI message content and known response/output fields; it deliberately
does not search arbitrary state strings, request messages, or checkpoint
metadata. This prevents an echoed input marker from satisfying a response
assertion.
For explicit paths, every expected response value must also be absent from the
submitted input/context/run options; otherwise an echoed request could satisfy
the assertion and the helper rejects the case.

Every successful stream case must declare the exact event sequence and one of
two reviewed terminal proofs. Prefer `expected_sse_terminal_event` plus
`expected_sse_terminal_status`. For a pinned runtime that closes after its final
values event, set `expected_sse_completion` to
`eof_after_expected_values`; the helper then extracts the run ID from stream
metadata and independently polls that run to terminal `success`. A clean HTTP
200, connection close, or stream that merely contains a values event is never
terminal-success evidence.

## Local verification

Run these checks before copying any scripts to the installer host:

```sh
python3 tools/cluster_setup/test_las_runtime_acceptance.py
python3 tools/cluster_setup/test_las_product_lifecycle_acceptance.py
python3 tools/cluster_setup/test_mpr44_product_caller_acceptance.py
python3 -m py_compile \
  scripts/las-runtime-acceptance.py \
  scripts/las-product-lifecycle-acceptance.py \
  tools/cluster_setup/validation/aip5410_product_route_acceptance.py \
  tools/cluster_setup/validation/mpr44_product_caller_acceptance.py
bash -n \
  scripts/las-restart-persistence-acceptance.sh \
  scripts/las-credential-rotation-acceptance.sh
```

Also run each helper's `--help` and invalid-input paths. Confirm that failure
output contains no scenario body, provider response, context value, or Secret.

## Earlier installer EC2 workflow

### 1. Connect and perform a read-only preflight

Connect to the approved installer host with the previously authorized installer
key. Before any mutation, inspect the active context and resolve exact targets:

```sh
kubectl config current-context
kubectl get namespaces
kubectl -n <namespace> get aiplatform,aiservice 2>/dev/null || true
kubectl -n <namespace> get deployment,service,hpa,pod
kubectl -n <namespace> get deployment <api-deployment> <queue-deployment> -o wide
kubectl -n <namespace> get hpa <queue-hpa> -o yaml
```

Verify that the namespace, release, image digest, and graph match the identity
record. Stop if the host points to the air-gapped cluster or an unexpected
environment.

### 2. Establish temporary access

Use a temporary local port-forward to the stable Agent Server Service when a
direct LAS check is required. Use the supported AITK/SLIM endpoint for
caller-route evidence. Record which route each result used; do not merge the two
categories.

### 3. Run MPR-45 dependency qualification

Run representative cases for:

- actual graph and schema discovery;
- owner-approved LLM call;
- MCP discovery/invocation and any required approve/deny resume;
- applicable KB call, or record `BLOCKED` if no owner-approved KB is available;
- missing and invalid LLM, MCP, and KB context;
- unavailable downstream dependency.

For every negative case, require a safe actionable category and confirm that no
run side effect or credential echo occurred where the API contract promises
that behavior. Inspect sanitized application/LAS logs and state surfaces. Record
MPR-131 separately as `KNOWN_FAIL`.

### 4. Run MPR-47 functional and negative regression

Run positive, authentication, and byte-level malformed-JSON cases through the
external SLIM helper. Use the in-Pod helper only for additional typed-router
coverage, and label that route explicitly. Include ordinary model output, MCP
tool use, structured output, conversation follow-up/resume, missing required
fields, invalid field types, unsupported provider/tool configuration, and
downstream failure. Do not infer external-route coverage for a row that ran only
inside the Pod.

The evidence must show each row's expected and actual outcome, response/schema
assertion, duration, route, and likely owner (`product`, `caller`, `platform`, or
`dependency`). A direct LAS pass remains supporting evidence for caller
behavior; the external-edge evidence proves only the rows it actually executed.

### 5. Run MPR-50 protocol and persistence checks

Pipe the actual product scenario into the runtime protocol helper and exercise:

- synchronous completion;
- background/queued completion and terminal run status;
- ordered SSE event types and terminal success;
- graph state containing a unique non-secret marker;
- same-session response recall through the caller route, when that route runs;
- checkpoint-history persistence through an explicit supported history read.
  Neither `/state` nor same-session recall proves checkpoint history, so record
  that row as `BLOCKED` unless the history read actually runs.

On the disposable integration deployment, run the restart helper with exact API
and queue Deployment names and explicit confirmation:

```sh
<trusted-scenario-provider> | \
LAS_DISPOSABLE_CLUSTER_CONFIRMED=true \
LAS_BASE_URL=http://127.0.0.1:<forwarded-port> \
LAS_NAMESPACE=<namespace> \
LAS_EXPECTED_KUBE_CONTEXT=<exact-context> \
LAS_EXPECTED_NAMESPACE_UID=<namespace-uid> \
LAS_API_DEPLOYMENT=<api-deployment> \
LAS_QUEUE_DEPLOYMENT=<queue-deployment> \
LAS_API_SERVICE=<api-service> \
LAS_API_SERVICE_UID=<immutable-service-uid> \
LAS_API_SERVICE_PORT=<service-port> \
LAS_OPERATOR_NAMESPACE=<operator-namespace> \
LAS_OPERATOR_DEPLOYMENT=<operator-deployment> \
LAS_OPERATOR_IMAGE=<operator-reference> \
LAS_OPERATOR_IMAGE_DIGEST=<sha256:digest> \
LAS_CHART_NAME=<chart-name> \
LAS_CHART_VERSION=<chart-version> \
LAS_CHART_SHA256=<archive-sha256> \
LAS_HELM_RELEASE=<release> \
LAS_HELM_NAMESPACE=<namespace> \
LAS_AGENT_SERVER_IMAGE=<launchpad-reference> \
LAS_AGENT_SERVER_DIGEST=<sha256:digest> \
scripts/las-restart-persistence-acceptance.sh
```

The restart helper verifies the exact operator/API/queue configured images and
same-container running digests, the exact deployed Helm chart name/version, and
the API Service UID/selector/port/EndpointSlice-to-Pod binding before its first
product call and after each rollout. The direct-LAS scenario
must set `cleanup_threads` to `false`, provide non-secret
`expected_state_values`, and request `sync`, `queued`, and `stream` in every
case. The helper seeds those modes, restarts the API, reads the existing state,
restarts the queue, reads the same state, and repeats product protocol execution
after recovery. Add `active_run_case` only when an owner-approved bounded
product call is expected to remain `running` long enough to span queue
replacement. The helper owns and recreates the Service port-forward and deletes
all qualification threads in its exit trap. It pins Kubernetes calls to the
approved context and feeds the trusted scenario to state/cleanup checks over
stdin so cleanup-only credential exposure also fails the run. Keep the output
sanitized. Do not run this against a shared or production cluster.

### 6. Run MPR-49 lifecycle and load checks

Select lifecycle phases explicitly; no phase is implied by another:

- product image/config upgrade through the supported AIPlatform/AIService path;
- managed Secret rotation through the installer/operator path;
- API and queue restart/replacement;
- PostgreSQL and Redis interruption/recovery on disposable dependencies;
- queued and active work during a controlled replacement;
- representative actual-product load;
- deterministic CPU-control load for HPA scale-up/cap/downscale/floor.

Start with a read-only identity/policy snapshot. The lifecycle helper requires
the exact kube context and namespace UID, verifies operator/API/queue Pod image
digests and the deployed Helm chart version, and rejects unhealthy workloads or
an unexpected HPA policy. Protocol and load phases also require `--api-service`;
the helper owns that Service port-forward so a healthy URL from another cluster
cannot be mistaken for evidence from the verified cluster.

When `--run-load` is selected, the direct-LAS scenario must contain an explicit
successful `load_case`. Do not rely on whichever item happens to be first in
`cases`. The following is a shape-only example; substitute only owner-approved
non-secret provider configuration and assertions:

```json
{
  "graph_id": "agent",
  "cleanup_threads": true,
  "sensitive_values": [
    "<unique synthetic or real credential canary for every supplied secret>"
  ],
  "cases": [
    {
      "name": "product-protocol",
      "input": {
        "messages": [{"role": "user", "content": "qualification {{RUN_MARKER}}"}],
        "system_prompt": "<non-secret system prompt>"
      },
      "context": {
        "llm_config": {"provider": "<provider>", "model": "<model>"},
        "mcp_configs": [],
        "kb_configs": []
      },
      "run_modes": ["sync", "queued", "stream"],
      "expected_state_values": ["{{RUN_MARKER}}"],
      "expected_response_values": ["<non-sensitive expected response marker>"],
      "expected_sse_event_sequence": ["metadata", "values", "end"],
      "expected_sse_terminal_event": "end",
      "expected_sse_terminal_status": "success"
    }
  ],
  "load_case": {
    "name": "representative-product-load",
    "expected_outcome": "success",
    "input": {
      "messages": [{"role": "user", "content": "load {{RUN_MARKER}}"}],
      "system_prompt": "<non-secret system prompt>"
    },
    "context": {
      "llm_config": {"provider": "<provider>", "model": "<model>"},
      "mcp_configs": [],
      "kb_configs": []
    },
    "expected_state_values": ["{{RUN_MARKER}}"],
    "expected_response_values": ["<non-sensitive expected response marker>"]
  }
}
```

The `end`/`success` stream contract above is illustrative, not a claim about a
specific runtime. Replace it only with the exact reviewed contract for the
deployed version. Add `expected_response_paths` only when it identifies a
response-specific value and cannot select echoed user input.

A representative live invocation is:

```sh
<trusted-scenario-provider> | \
LAS_BASE_URL=http://127.0.0.1:<port> \
LAS_DISPOSABLE_CLUSTER_CONFIRMED=true \
LAS_LIFECYCLE_MUTATIONS_CONFIRMED=true \
scripts/las-product-lifecycle-acceptance.py \
  --namespace <namespace> \
  --api-deployment <api-deployment> \
  --queue-deployment <queue-deployment> \
  --hpa <queue-hpa> \
  --hpa-min-replicas <min> --hpa-max-replicas <max> \
  --hpa-cpu-target <percent> \
  --expected-context <exact-context> --namespace-uid <uid> \
  --operator-namespace <operator-namespace> \
  --operator-deployment <operator-deployment> \
  --operator-image <reference> --operator-image-digest <sha256:digest> \
  --agent-image <reference> --agent-image-digest <sha256:digest> \
  --chart-name <name> --chart-version <version> \
  --chart-sha256 <archive-sha256> \
  --helm-release <release> --helm-namespace <namespace> \
  --runtime-version <version> --graph-id <graph> \
  --api-service <service> --api-service-uid <immutable-service-uid> \
  --request-timeout 180 \
  --run-protocol --run-load --load-scale-expectation observe
```

Even protocol and representative-load phases create temporary product state, so
live execution requires both explicit confirmation variables shown above. Use
`--load-scale-expectation observe` only to record an I/O-bound product-load
observation; it is labeled non-acceptance. Omit it, or select `required`, when
the scenario is expected to prove CPU scale-up. Add only the mutation flags
explicitly approved for that execution. The lifecycle orchestrator supports
Kubernetes Deployments/StatefulSets for dependency recovery only when each
`--postgres-workload`/`--redis-workload` is accompanied by its exact Service,
Service UID, endpoint Secret, and endpoint Secret key. The helper proves that
the Service selector exactly matches that workload controller, the in-memory
endpoint URL names that Service, and both LAS Deployments reference the same Secret/key before it can
restart the dependency. On the earlier EC2,
PostgreSQL and Redis are host Podman containers, so their interruption is
`NOT_RUN` by this helper and must not be claimed. A separate disposable-host
procedure and authorization are required before stopping either container.

An installer upgrade additionally requires
`--pre-upgrade-agent-image`, `--pre-upgrade-agent-image-digest`, and, when the
chart changes, `--pre-upgrade-chart-version`, plus
`--post-upgrade-api-template-sha256` and
`--post-upgrade-queue-template-sha256`. Compute those values from the intended
post-upgrade manifests before execution. The helper requires both Deployment
revisions and both Pod-template identities to change and to match the declared
values. It verifies the declared pre-upgrade image/digest and chart before any
credential-bearing product request, then verifies the intended post-upgrade
identity before the post-upgrade request. A revision-only or unrelated rollout
cannot count as an upgrade pass.

For managed credential rotation, use two owner-prepared installer configs and
pipe a cleanup-enabled product scenario to
`scripts/las-credential-rotation-acceptance.sh`. In addition to the exact
Deployment/Service identity variables used above, provide the exact three Secret
names in auth, PostgreSQL, Redis order, queue HPA, operator
namespace/Deployment, expected kube context, and
namespace UID. Also provide `LAS_CHART_NAME`, `LAS_HELM_RELEASE` (and
`LAS_HELM_NAMESPACE` when it differs from the workload namespace).
`LAS_API_SERVICE` and `LAS_API_SERVICE_UID` are required: the helper binds that
Service's selector, port, EndpointSlices, Pod identities, and resolved agent
digest to the attested API Deployment before using the local port-forward, and
fails if that process exits. The helper runs
the product before and after rotation, compares non-emitted hashes of the exact
`langgraph_cloud_license_key`, `postgres_connection_url`, and
`redis_connection_url` values, verifies both Deployment revisions, proves the
API and queue Pod templates reference those role-bound Secret/key pairs,
preserves the HPA spec, verifies the exact Helm release/chart and live Pod image
digests before each credential-bearing call, and cleans all product threads.
Installer output is discarded because it may contain
credentials. Do not run this phase without disposable credentials and explicit
installer authorization.

For HPA evidence, record the configured CPU target, minimum, maximum, scale-down
stabilization and policy, current/desired replicas, ready queue Pods, API replica
count, CPU samples, run latency, failures, backlog, and terminal run states. A
real model or tool call may spend most of its time waiting and produce
`no_cpu_scale_observed`; record that honestly. Use the deterministic CPU-control
case to prove that the configured CPU policy can scale.

Do not infer multi-worker execution merely because multiple Pods are Ready. Use
a supported worker/run correlation in the deployed runtime or sanitized queue
logs. Verify every marker and terminal status against shared PostgreSQL-backed
state. Do not claim exactly-once behavior unless the product contract explicitly
provides and proves it.

Credential rotation and upgrade must preserve HPA ownership of queue replicas.
Do not directly scale the queue Deployment during an HPA acceptance run.

## Direct LAS versus caller-route evidence

Direct LAS proves the product graph and Agent Server protocol. It can establish
sync, background, SSE, state, restart, and runtime dependency behavior. It does
not prove AITK authentication, SLIM request mapping, caller response mapping, or
the complete supported route.

An in-Pod SLIM router call proves SLIM mapping and product interaction but may
bypass external ingress/authentication. The authenticated external SLIM helper
closes the external-edge criteria it executes. It does not prove that an
installed AITK application's UI/backend constructed the same request.

Every evidence row must name one of these routes rather than saying only that
"the agent worked."

## Cleanup and recovery

- Delete temporary assistants and threads after collecting the required state.
- Stop temporary port-forwards.
- Wait for restarted Deployments and disposable dependencies to become Ready.
- Confirm the queue returns to the HPA minimum and the API remains at one replica.
- Confirm the product image/config matches the intended post-test state.
- Record any intentionally retained thread or artifact and its owner.

## Rerun triggers

Rerun the affected checks when any of these changes:

- Launchpad image digest, source commit, graph, or schema;
- Agent Server/runtime version;
- caller mapping, SLIM/AITK image, authentication, or route;
- operator image, embedded chart, Helm values, or HPA policy;
- LLM, MCP, or KB provider/configuration;
- PostgreSQL or Redis implementation/capacity;
- MPR-131 remediation.

After the MPR-131 fix, rerun the complete credential-canary gate against the
fixed immutable digest. Do not convert the previous `KNOWN_FAIL` record into a
pass without new evidence.
