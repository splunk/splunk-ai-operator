# LAS AI tier manual deployment validation

**Date:** 2026-10-05  
**Release:** `las-poc` in namespace `ai-platform`  
**Chart:** `langchain/langgraph-cloud` 0.3.4 (appVersion 0.2.3)  
**Sample graph:** `echo`  
**Existing thread:** `01a10b20-c2df-7cb3-8ecd-a579ee78186b`

This record covers only the LAS POC API and queue Deployments. No unrelated cluster workloads were inspected or changed.

Later state: the manual `las-poc` release was uninstalled after this validation; the results below are historical evidence. See the [POC handoff](las-ai-tier-poc-handoff-20261005.md) for final cluster state.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| API health | Pass | `GET /ok` returned `{"ok":true}`. |
| Queued background run | Pass | Run `01a10b74-59d8-70c2-9f5a-96890c87fba1` finished `success`. Queue log at 2026-10-05 09:45:37 UTC records the thread being claimed, this run being dequeued, and `Background run succeeded`. The run response was `LAS sample agent received: LAS POC queued background check 2026-10-05`. |
| Streaming run | Pass | Run `01a10b74-5d5d-7680-9c01-4053bf91060c` streamed `metadata`, `values`, and `updates` SSE events to the curl client. The final state contained `LAS sample agent received: LAS POC streaming check 2026-10-05`. |
| API and queue restart | Pass | `kubectl rollout status` succeeded for both Deployments. New API pod `las-poc-langgraph-cloud-api-server-5c7dcf4b5-m65kw` and queue pod `las-poc-langgraph-cloud-queue-66dcdbb454-gppmd` each reported `1/1 Running`. |
| Existing state after restart | Pass | A state read after both rollouts returned the existing thread and the streaming run’s state before any new post-restart run was submitted. |
| Queued run after restart | Pass | Run `01a10b75-66c0-7f22-8b39-c57ade113be2` finished `success`. The new queue pod logged the matching run ID as dequeued and succeeded. Final state was `LAS sample agent received: LAS POC post-restart check 2026-10-05`. |
| PostgreSQL and Redis destinations | Recorded | Secret URLs were parsed in memory; only scheme, host, port, and database were printed. See below. |
| License mode | Runtime accepted; verifier transaction not directly observed | See the license evidence and limitation below. |

## Restart and persistence details

Both Deployments were `1/1` ready before the restart. The queue Deployment was restarted and reached rollout completion first, followed by the API Deployment. Both new pods were `1/1 Running` afterward. The existing thread state remained readable after the API restart, with checkpoint state retained in PostgreSQL. A subsequent queued run completed on the restarted queue pod and advanced the thread state to step 10.

The post-restart API and queue logs report `langgraph_api_version=0.15.1`; thread metadata reports the sample graph’s LangGraph version as `0.4.10` and API version as `0.15.1`.

## Streaming evidence

The client received these SSE event types from `POST /threads/{thread_id}/runs/stream`:

```text
event: metadata
event: values
event: updates
event: values
```

The sample graph is deterministic and returns one short value from its `echo` node. This confirms server-to-client SSE delivery of graph events; it does not test token-by-token model generation.

## License and “air-gapped mode”

The restarted API and queue logs both contain `api_variant=licensed` and the message `Running in air-gapped mode, skipping metadata loop`. The Deployments reference `LANGGRAPH_CLOUD_LICENSE_KEY` from `las-auth/langgraph_cloud_license_key`; the license value was not read or recorded. Both processes completed startup, reached Ready, and served successful runs with the licensed variant. This is positive evidence that the configured license allowed the runtime to start and operate.

The message specifically says the **metadata loop** is skipped. It does not say that all outbound traffic is disabled, and it is not itself a license verdict. LangChain’s data-plane documentation separates telemetry from license validation: self-hosted air-gapped keys use self-reported usage for telemetry, while the licensing section says an air-gapped license key or Platform License Key is validated against LangSmith SaaS. See [LangSmith data plane: telemetry and licensing](https://docs.langchain.com/langsmith/data-plane).

No explicit validation HTTP response, verifier success event, or license-status endpoint result appeared in the restarted pod logs. Therefore the evidence supports **runtime acceptance and licensed operation**, but does not identify the precise validation transaction, endpoint response, or key subtype. The prior TLS 1.3 check to `beacon.langchain.com` confirms network reachability only; it is not evidence of license acceptance. To establish the transaction-level result, LangChain must confirm which validation endpoint and success signal apply to this key/runtime version, or provide a supported runtime diagnostic that exposes the verifier result.

## PostgreSQL and Redis used

Values below are derived from the referenced Kubernetes Secrets in namespace `ai-platform`. Usernames, passwords, query credentials, and raw connection URLs were not emitted.

| Dependency | Deployment Secret reference | URI scheme | Host | Port | Database | TLS indication |
| --- | --- | --- | --- | --- | --- | --- |
| PostgreSQL | `las-postgres/postgres_connection_url` | `postgresql` | `10.0.35.244` | `5432` | `las_poc` | Not indicated by URI scheme |
| Redis | `las-redis/redis_connection_url` | `redis` | `10.0.35.244` | `6379` | `0` | Not indicated by URI scheme |

Both Deployments reference these same Secret keys, plus `las-auth/langgraph_cloud_license_key`. The PostgreSQL and Redis URIs share a host address but use different ports and databases. The URI scheme does not establish whether transport TLS is enabled by any separate client configuration; that was not independently determined in this check.

## Scope and handling

- The API was accessed through a temporary installer-local `kubectl port-forward`; the port-forward process ended with its SSH session.
- The only Deployment mutations were rolling restarts of `las-poc-langgraph-cloud-queue` and `las-poc-langgraph-cloud-api-server`.
- Secret values were never printed. Connection details were decoded in process and reduced to an allowlist of non-credential fields.
- No cluster-wide checks or changes were made.
