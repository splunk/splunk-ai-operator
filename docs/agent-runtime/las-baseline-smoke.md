# LAS baseline smoke check

This script exercises the deterministic sample graph through the standalone
LangSmith Agent Server API. It verifies API health, thread creation, a completed
run, and persisted thread state. It does not install or modify Kubernetes
resources or manage PostgreSQL/Redis ownership.

Each run creates a new thread and run with a generated synthetic request marker.
That data remains in LAS state so the script can confirm persistence.

## Prerequisites

- A reachable LAS API endpoint, usually through a port-forward to the AIService
  compatibility Service (port `8080`).
- `curl` and Python 3 on the machine running the script.
- The `echo` graph in the target Agent Server image, unless another graph ID is
  supplied.
- Artifact identities for the deployed Operator, LAS chart, and Agent Server
  image. Use the actual target deployment values, not historical POC defaults.

The deterministic sample graph source is in
[`samples/las-sample-agent`](../../samples/las-sample-agent/README.md); its
`langgraph.json` registers graph ID `echo`. The POC baseline used chart
`langgraph-cloud` `0.3.4`. See the [chart contract](https://github.com/splunk/splunk-ai-operator/blob/5fa706a56f7185976c65461c4d3f6bea8107e059/docs/agent-runtime/las-ai-tier-chart-contract.md)
and [manual runtime validation](https://github.com/splunk/splunk-ai-operator/blob/5fa706a56f7185976c65461c4d3f6bea8107e059/docs/agent-runtime/las-ai-tier-manual-validation.md)
for the recorded POC evidence. That evidence is historical and does not establish
the current cluster state.

## Run

Start a port-forward to the target AIService Service, for example:

```bash
kubectl -n ai-platform port-forward service/<aiservice-name>-svc 18083:8080
```

In another shell on that machine, set the API URL and artifact identities, then
run the script:

```bash
LAS_BASE_URL=http://127.0.0.1:18083 \
LAS_OPERATOR_IMAGE='registry.example.com/splunk-ai-operator:<tag>' \
LAS_OPERATOR_IMAGE_DIGEST='sha256:<operator-digest>' \
LAS_CHART_VERSION='<chart-version>' \
LAS_CHART_SHA256='<chart-archive-sha256>' \
LAS_AGENT_SERVER_IMAGE='registry.example.com/product/agent-server:<tag>' \
LAS_AGENT_SERVER_DIGEST='sha256:<agent-server-digest>' \
scripts/las-baseline-smoke.sh
```

The script reports `PASS` only after it:

1. Receives HTTP 200 and `{"ok":true}` from `GET /ok`.
2. Creates a thread with `POST /threads`.
3. Runs the configured graph using `POST /threads/{thread_id}/runs/wait` and
   confirms the deterministic response contains this invocation's marker.
4. Reads `GET /threads/{thread_id}/state` and confirms that the same marker and
   response were persisted.

Optional environment variables:

- `LAS_GRAPH_ID` selects the graph/assistant; default is `echo`.
- `LAS_EXPECTED_RESPONSE_PREFIX` changes the deterministic response prefix;
  default is `LAS sample agent received: `.
- `LAS_REQUEST_TIMEOUT_SECONDS` sets the per-request timeout; default is 30.

## Output and handling

Output is sanitized key/value data containing the result, failed step (if any),
endpoint host, graph and thread IDs, check results, request marker, and Operator,
chart, and Agent Server image identities. Response bodies are not printed. The
base URL must not contain credentials, a query, or a fragment.

The generated thread/run is an intentional write to the LAS-backed database.
The script does not delete it, change dependencies, create Secrets, or alter
Helm releases. Use a development/qualification LAS instance for smoke runs.

## Relationship to broader qualification

This check covers the baseline API health/thread/run/state path. It does not
qualify AITK/SLIM caller behavior, streaming, API/queue restart recovery, queue
autoscaling, license-verifier transactions, or air-gapped behavior. See the
[LAS integration ERD](https://splunk.atlassian.net/wiki/spaces/PROD/pages/1080622219514/ERD+LAS+integration+into+AI+Tier)
for the broader release contract.
