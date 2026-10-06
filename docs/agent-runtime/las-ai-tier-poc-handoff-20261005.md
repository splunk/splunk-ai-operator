# LAS AI tier POC: outcome and handoff

**Date:** 2026-10-05  
**Status:** Technical feasibility demonstrated; production implementation remains  
**Decision reflected in this POC:** LAS replaces the implementation of the existing `agentruntime` AIService feature. It is not a second runtime type.

## Short update for Jira

The POC showed that the AI tier operator can manage standalone LangSmith Agent Server (LAS) as one Helm release per `AIService`. Chart `langgraph-cloud` 0.3.4 ran with an externally managed PostgreSQL database, Redis, and a Secret-sourced license. The operator installed the API and queue, reported progress and failures through the existing Ready condition and events, reconciled without creating another release, upgraded the same release, and uninstalled it on AIService deletion without deleting external dependencies. A second AIService ran concurrently with separate PostgreSQL and Redis logical databases; cross-instance thread reads returned 404, and updating or deleting one instance left the other unchanged.

The sample `echo` graph passed health, run, and persisted-state checks. The manual chart deployment also passed queued background execution, SSE streaming, and state retrieval after API/queue restarts. The primary operator-managed instance remains Ready in `ai-platform`. All manual and disposable POC releases and their disposable dependencies were removed.

**Decision:** Proceed to a production implementation, using the existing `agentruntime` feature and one LAS release per AIService. The POC is not a release qualification. The most immediate issue is queue upgrade capacity: a one-replica upgrade stalled because the chart's default 1 CPU queue request and rolling surge could not fit on the test cluster; it completed only after a temporary rollout-strategy patch. Other open work includes a supported image/configuration contract, direct LAS lifecycle tests, Secret rotation, caller protocol integration, license-verification evidence, and operational controls.

## POC objective and architecture

The [original POC brief](las-ai-tier-poc.md) asked for a thin vertical slice proving the highest-risk integration path: an AIService controls one pinned standalone LAS Helm release using customer-supplied PostgreSQL and Redis-compatible services, serves an agent request, and follows the AIService lifecycle. The later design decision replaced the direct-managed AgentRuntime implementation with LAS behind the existing `agentruntime` feature name.

```text
AIPlatform feature: agentruntime
  → child AIService, with license/PostgreSQL/Redis Secret references
  → one UID-owned LAS Helm release
  → LAS API + separate queue worker
  → existing AIService DNS name and port 8080, routed to LAS API port 8000
  → customer-managed PostgreSQL and Redis
```

The compatibility Service preserves the old address and port. LAS uses its own HTTP API and payloads, so callers must be integrated with that protocol.

## What was built

| Area | POC change |
| --- | --- |
| API and admission | Added `licenseSecretRef`, `postgresSecretRef`, and `redisSecretRef` to the `agentruntime` feature, webhook validation, and both published CRD copies. Existing legacy AgentRuntime fields remain in the API but do not configure LAS. |
| Operator | The `agentruntime` factory now returns `LASReconciler`. It verifies an embedded chart package/digest, generates Secret-reference Helm values, installs or upgrades one stable release, checks API/queue readiness, sets AIService Ready conditions/events, preserves the in-cluster Service name, and uninstalls its UID-owned release through a finalizer. |
| Packaging and permissions | Added Helm SDK dependencies, embedded chart `0.3.4`, ReplicaSet and event RBAC needed by Helm wait and status events, and an operator image deployed to ECR. |
| Test environment | Built a small deterministic `echo` Agent Server image, updated the k0s AI tier profile and sample values to use the LAS Secrets, and deployed the revised operator on `agentruntime-dev`. |

The old direct-managed AgentRuntime implementation and most of its unit tests are still present in source, although the active feature factory selects LAS. The branch also contains SLIM/Splunk and installer E2E changes from the broader `agent-runtime/ai-tier` work. Those should be reviewed and landed in coherent changes rather than treated as LAS qualification evidence.

## Goal-to-evidence review

| POC goal | Assessment | Evidence and limit |
| --- | --- | --- |
| Pinned standalone chart and external dependencies | **Met** | Chart `0.3.4`, appVersion `0.2.3`, digest checked in operator. Rendered/live chart created API and queue but no PostgreSQL, Redis, or MongoDB workload. API and queue referenced existing Secrets. |
| License and image startup | **Met for runtime operation; verifier detail open** | API/queue started in licensed mode and served runs using `las-auth`. `beacon.langchain.com` was reachable. No explicit verifier response or license subtype was observed. |
| Background execution, streaming, and state persistence | **Met on manual chart deployment** | A queued run completed in the queue worker; client received SSE `metadata`/`values`/`updates`; saved thread state survived API and queue restarts. These paths were not repeated after the operator took ownership. |
| One AIService controls one Helm release | **Met** | Primary and disposable AIServices each installed one distinct chart `0.3.4` release. Release ownership labels matched AIService UIDs. No-op reconcile kept revision, Deployment generation, and Pod UIDs unchanged. |
| Useful failure status and retry | **Met** | Missing license Secret reported `DependenciesUnavailable`; a deliberate Helm Service collision reported `HelmInstallFailed`; removal led to automatic installation and Ready. Retry after repeated failures took about five minutes. |
| Same-release upgrade | **Met with a capacity caveat** | Changing a supported Secret reference advanced a disposable release from revision 1 to 2. Another isolated upgrade required a temporary queue rollout-strategy patch because the replacement queue Pod could not schedule. |
| Deletion preserves external dependencies | **Met** | Both disposable AIService finalizers recorded `LASUninstalling`/`LASUninstalled`, removed only their releases and owned resources, and left their external Secrets and PostgreSQL databases unchanged. Disposable dependencies were cleaned up after this check. |
| Multiple instances stay isolated | **Met for logical database and application state** | Three releases were Ready concurrently. Disposable instances used PostgreSQL databases `las_poc_lifecycle` and `las_poc_isolation` and Redis DBs 1 and 2. Each returned HTTP 404 for the other's thread ID. Updating/deleting one left the others' recorded snapshots unchanged. The PostgreSQL role and servers were shared. |
| Product caller integration | **Not in this POC** | The deterministic sample graph was called directly. The full AITK → SLIM → LAS endpoint, payload, and authorization contract was not validated end to end. |
| Valkey and production operations | **Not in this POC** | Valkey, HA, backup/restore, disaster recovery, sustained load, Secret rotation, customer registry/air-gapped packaging, and production monitoring were not qualified. |

## Tests and reproducibility

- On 2026-10-05, a fresh `go test -count=1` run passed for `./pkg/ai/features/agentruntime`, `./pkg/ai`, `./internal/webhook/v1`, and `./internal/controller`. The installer script suite passed **163 tests, 0 failures, 0 skips**; shell syntax and `git diff --check` also passed. This review did not run the full repository test suite.
- Automated LAS-specific coverage is narrow: current feature tests directly cover factory selection, removal of stale legacy conditions, and owner-scoped legacy cleanup; webhook tests cover required Secret references. Most `impl_test.go` cases still target the old direct-managed AgentRuntime reconciler. The 163 installer tests do not directly assert the new LAS Secret validation/render path. Helm install, upgrade, retry, finalizer, values, ownership, and multi-instance isolation were established primarily by the recorded cluster runs.
- The current upgrade check compares chart version and Helm values. It does not detect changed chart contents repackaged under the same version; production chart packages should be immutable and require a version change, or the deployed chart digest must become part of reconciliation.
- Detailed sequence and sanitized evidence: [chart contract](las-ai-tier-chart-contract.md), [manual runtime validation](las-ai-tier-manual-validation.md), [operator rollout](las-operator-rollout-20261005.md), [lifecycle and failure recovery](las-operator-lifecycle-validation-20261005.md), and [isolation, deletion, and cleanup](las-operator-isolation-validation-20261005.md).

## Tested artifacts and final environment

| Artifact | Tested identity |
| --- | --- |
| LAS chart | `langgraph-cloud` `0.3.4`, appVersion `0.2.3`, package SHA256 `31dab99c9b1c6ddfb8672a4a9a287a044d50bb628665c641eb2b1170833df953` |
| Sample Agent Server | `ml-platform/las-sample-agent:las-poc-20260930-115209`, ECR digest `sha256:bc4c1a779904e0c422392deabcf4091f79c1fcdf82bc483d49b82ba79a5b4eba` |
| Operator manager | `ml-platform/splunk-ai-operator:las-poc-20261005-114954-483a832`, ECR digest `sha256:f7b98f37ab2571af598cc13c3698f0d3dc575d6c29b5f96b9f586753708103bc` |
| Source state | Local `las-poc` branch based on `agent-runtime/ai-tier` at `483a832`; POC changes remain in the working tree and are not a merged release. |

Final cluster state: only the primary LAS release `las-agentruntime-dev-ai-p-eb88ba0f` remains at revision 1, `Ready=True/LASReady`. The original `las-auth`, `las-postgres`, and `las-redis` Secrets and PostgreSQL database `las_poc` remain. Manual `las-poc` and both disposable releases, their disposable databases/Redis DB contents/Secrets, and the temporary SSH rule were removed.

## Recommendation and decisions needed

Proceed with the [post-POC implementation plan](las-ai-tier-implementation-plan-post-poc.md). Treat the POC as evidence that the architecture is feasible, and require an unattended queue upgrade, product caller flow, supported image/Secret contract, and an expanded automated/operational qualification before release.

Decide these contracts early:

1. How customers supply the Agent Server image/graph, chart version policy, and registry credentials. The POC image repository/tag is hardcoded into the operator binary.
2. Whether customers supply a distinct PostgreSQL database and scoped credentials and a distinct Redis endpoint/logical DB per AIService; define retention and deletion policy.
3. The exact LAS endpoint, payload, authentication, and routing contract for SLIM/AITK and other AI tier callers.
4. The approved license mode and a vendor-supported way to observe verification; confirm whether `LANGSMITH_API_KEY` is needed for the intended features.
5. Which deployment modes are in the first release: connected, restricted egress, private registry, or air-gapped. Valkey should have its own qualification decision.
