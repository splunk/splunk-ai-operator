# LAS POC chart contract

**Candidate chart:** `langchain/langgraph-cloud`  
**Pinned chart version:** `0.3.4`  
**Chart appVersion:** `0.2.3`  
**Upstream chart source ref:** `langgraph-cloud-0.3.4` (`24e850b3841c5ce8bb99924917799ae2c3ab25ba`)

**POC sample Agent Server image:** `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/las-sample-agent:las-poc-20260930-115209`  
**Pushed digest:** `sha256:bc4c1a779904e0c422392deabcf4091f79c1fcdf82bc483d49b82ba79a5b4eba`  
**Build inputs:** LangGraph CLI `0.4.32`, `langgraph==0.4.10`, `linux/amd64`

**Later state:** The manual `las-poc` release was uninstalled after these chart checks. The operator-managed primary release remains Ready; see the [POC handoff](las-ai-tier-poc-handoff-20261005.md).

This is the upstream standalone Agent Server chart. It deploys the Agent Server and its optional queue process; it is not the LangSmith platform/control-plane chart. The chart repository index on its `gh-pages` branch lists `langgraph-cloud-0.3.4` and the matching package URL. Its digest is `31dab99c9b1c6ddfb8672a4a9a287a044d50bb628665c641eb2b1170833df953`.

## POC values

`config/samples/las-ai-tier-chart-values.yaml` captures the candidate configuration. It uses a custom Agent Server image, references pre-created Secrets, enables queue mode, disables MongoDB, and keeps the API Service internal.

Secret data keys expected by chart `0.3.4`:

| Secret reference | Required key | Used for |
| --- | --- | --- |
| `config.existingSecretName` | `langgraph_cloud_license_key` | `LANGGRAPH_CLOUD_LICENSE_KEY` |
| `config.existingSecretName` | `api_key` (optional) | `LANGSMITH_API_KEY`, when LangSmith access is required |
| `postgres.external.existingSecretName` | `postgres_connection_url` | `POSTGRES_URI` |
| `redis.external.existingSecretName` | `redis_connection_url` | `REDIS_URI` |

With those existing Secret names set, chart templates reference those Secrets and skip generating replacement Secrets. Do not put credentials in values. Both API and queue Deployments consume PostgreSQL, Redis, and license Secret references. If a LangSmith API key is not needed, omit `api_key`; the chart marks that environment variable optional. The standalone server uses its license key at startup and requires egress to `https://beacon.langchain.com`; the POC environment has that egress.

## Expected rendered resources from the tagged templates

This inventory was source-inspected and then confirmed against the rendered chart during the installer deployment.

- `Deployment/<release>-langgraph-cloud-api-server` with one replica by default, port 8000, healthcheck startup/readiness/liveness probes, 1 CPU/2 GiB requests and 2 CPU/4 GiB limits by default.
- `Service/<release>-langgraph-cloud-api-server`, overridden to `ClusterIP`; the chart template exposes service ports 80 and 443, both targeting the API container port 8000. In this topology, access should use the in-cluster API service and HTTP port 80.
- `ServiceAccount/<release>-langgraph-cloud-api-server`.
- With `queue.enabled: true`, `Deployment/<release>-langgraph-cloud-queue` and `ServiceAccount/<release>-langgraph-cloud-queue`, one replica by default. Queue health probes use `/ok` on port 8000; the queue has the same default resource requests and limits as the API server.
- The queue chart template sets the API server's `N_JOBS_PER_WORKER` to `0` and starts the separate queue worker. The upstream standalone deployment docs identify this split mode as the chart path for background runs; Redis backs streaming output for background runs.
- No chart-managed PostgreSQL StatefulSet/Service or Redis Deployment/Service when their respective `external.enabled` flags are true.
- No chart-managed license, PostgreSQL, or Redis Secret when each existing Secret name is supplied.
- No MongoDB resources when `mongo.enabled` is false. Ingress, Gateway API, and Istio routes are disabled by default.

## Render, deployment, and smoke result

On 2026-10-05 the published chart package was fetched and rendered on the Agent Runtime installer with Helm `v3.21.3`. Chart `0.3.4` rendered the expected API and queue Deployments and ClusterIP API Service. It rendered no PostgreSQL or Redis workloads and referenced the existing `las-auth`, `las-postgres`, and `las-redis` Secrets. The release `las-poc` is deployed in `ai-platform`, revision 2; both Deployments reached `1/1 Ready`.

The API startup logs confirmed connections to the Secret-sourced PostgreSQL and Redis endpoints, and both API and queue Deployments became Ready. A request to graph `echo` returned `LAS sample agent received: hello from LAS`; a subsequent `GET /threads/{thread_id}/state` returned the saved request and response. The pod also resolved `beacon.langchain.com` and established TLS 1.3. The API log reports `api_variant=licensed`, and also says `Running in air-gapped mode, skipping metadata loop`; the TLS check proves host reachability but does not independently establish which license-verification transaction ran. The POC did not configure a LangSmith API key, so tracing was not validated.

Two startup issues were corrected during deployment:

- The k0s nodes' ECR containerd authorization had expired. A fresh `us-west-2` token was installed in `hosts.toml` on all three nodes, after which the image pulled. This token expires after about 12 hours. The existing `refresh_ecr_credentials.sh` creates Kubernetes registry Secrets and defaults to `us-east-2`; it does not refresh these per-node containerd files, so it is not a drop-in refresh for this cluster.
- The chart's default API exec probes used a one-second timeout. The application completed startup and connected to both dependencies, but the probe timed out and caused the initial Helm wait to fail. The sample values now set API startup, readiness, and liveness probe timeouts to five seconds; Helm revision 2 then became Ready.

The separate queue/background/streaming behavior and persistence across API/queue restarts were subsequently verified on 2026-10-05. Sanitized PostgreSQL and Redis connection targets were also recorded. See [manual deployment validation](las-ai-tier-manual-validation.md) for run IDs, queue logs, SSE events, restart evidence, storage destinations, and the remaining limit on transaction-level license-verification evidence. Valkey is not qualified by this chart selection.
