# Standalone LAS AI Tier POC

**Status:** Implementation brief  
**Purpose:** Validate the highest-risk parts of integrating standalone LangSmith Agent Server (LAS) into AI tier before committing to the full implementation.  
**Target branch:** `agent-runtime/ai-tier`

## 1. POC objective

Build a thin vertical slice in which the AI tier operator reconciles one `AIService` into one upstream LAS Helm release. Prove that LAS starts with customer-supplied PostgreSQL and Redis-compatible dependencies, serves an agent request, and follows the AIService lifecycle.

Keep the implementation small and disposable. Reuse the current AgentRuntime API and provider abstraction where practical. The POC should reveal chart/operator integration gaps; it is not a production-ready feature.

## 2. Decisions and constraints

- Deploy standalone LAS. Do not use the LangSmith deployment control plane or self-host the full LangSmith platform.
- The operator owns creation, reconciliation, update, status reporting, and removal of one LAS Helm release per AIService.
- Use the upstream LAS chart at an explicitly pinned version. Prefer chart values; record any required chart patch separately and keep it minimal.
- Treat PostgreSQL and Redis-compatible services as externally managed. For a disposable POC cluster, they may be installed as separate releases, provided they are outside the LAS Helm release and are not owned or deleted by the AI tier operator.
- Give this LAS release a dedicated PostgreSQL database. A shared PostgreSQL server is acceptable; sharing a database between separate LAS deployments is not.
- Store connection details and the LAS license key in Kubernetes Secrets. Do not commit credentials or put secret values in AIService status, logs, or Helm release values stored in plaintext.
- Do not modify carrier images or implement LAS/product contract matching.
- Do not provision PostgreSQL, Redis, or Valkey through the AI tier operator.
- Do not treat Valkey as supported based only on Redis protocol compatibility. Qualify it separately and record the tested version and result.

## 3. POC boundaries

### In scope

- Inspect the existing AgentRuntime reconciler, AIService API, Helm/dependency patterns, status conditions, and packaging before choosing the smallest implementation seam.
- One AIService-to-one-Helm-release mapping, with deterministic release identity and ownership.
- Customer-style PostgreSQL and Redis-compatible Secret references.
- License Secret wiring, LAS readiness, in-cluster service discovery, and meaningful error status.
- Install, no-op reconcile, values update, failure/retry, and delete behavior.
- A minimal sample agent image and one request that validates persisted state and streaming/background execution where supported by the selected chart topology.

### Out of scope

- Carrier image changes, product contract matching, or product-specific agent behavior.
- Multi-product feature completeness, automatic database creation, or AI tier-managed Redis/Valkey.
- Production HA, load testing, backup/restore, disaster recovery, air-gapped support, or a general chart-fork strategy.
- A complete Helm release manager abstraction unless existing operator patterns require it for the vertical slice.

## 4. Starting points in this repository

Read the current code and local `AGENTS.md` instructions before editing. These are likely entry points; confirm the current structure rather than assuming they are unchanged:

- `pkg/ai/features/agentruntime/impl.go` — current AgentRuntime reconciliation.
- `api/v1/aiservice_types.go` — AIService API and configuration surface.
- Existing AgentRuntime tests and adjacent feature reconcilers — controller conventions, fake clients, status, and ownership patterns.
- Operator deployment/package configuration — Helm SDK/runtime dependencies, RBAC, network policy, and image packaging constraints.

Do not replace the existing runtime behavior as part of the POC unless required to make the LAS vertical slice work. Keep the POC implementation identifiable and easy to revise after chart findings.

## 5. Phased implementation plan

### Phase 0 — Verify the chart contract

- Select and pin one LAS chart release compatible with the available license and sample server image.
- Render the chart with bundled PostgreSQL/Redis disabled and external endpoints enabled.
- Identify every created workload, service, probe, Secret reference, required value, and resource name.
- Confirm whether queue/split mode must be enabled for the intended background-run and streaming check.
- Record chart gaps and assumptions before writing operator code.

**Exit evidence:** chart version and image version recorded; rendered resources reviewed; external PostgreSQL/Redis and license Secret inputs are demonstrated; unsupported requirements are listed.

### Phase 1 — Deploy LAS once by Helm

- In a disposable Kubernetes namespace, install external PostgreSQL and Redis-compatible dependencies separately from the LAS release, or connect to approved test services.
- Create a dedicated PostgreSQL database for the POC deployment.
- Install LAS manually using the pinned chart and a values file that refers to pre-created Secrets.
- Keep the API service internal and use port-forwarding or in-cluster access for validation.

**Exit evidence:** LAS pods become ready; health endpoint responds; a minimal agent request succeeds; a follow-up request can read persisted state; streaming/background behavior works if required by the chosen topology.

### Phase 2 — Add the operator vertical slice

- Add the smallest AIService configuration needed to select the LAS provider and reference the dependency/license Secrets. Reuse existing fields if they represent the same contract; do not add generic fields speculatively.
- Derive one stable Helm release identity from the AIService/provider identity and namespace.
- Reconcile install and no-op updates through the operator using the pinned chart and reviewed values.
- Surface release progress, readiness, and actionable failures through existing AIService conditions/events.
- On AIService deletion, remove only the LAS release and operator-owned objects. Preserve customer dependencies and dependency Secrets.

**Exit evidence:** an AIService creates exactly one LAS release; repeated reconcile converges; a supported settings change upgrades that release; errors are visible and retryable; deleting the AIService removes the release without deleting external dependencies.

### Phase 3 — Validate isolation and hand off findings

- Run the automated tests below and record the tested operator/chart/image versions.
- If license terms and test resources allow, create a second temporary AIService/release using a different PostgreSQL database and a distinct Redis logical database or endpoint. Verify names, values, status, and cleanup do not cross between releases.
- Document gaps, follow-up work, and estimate changes. Remove disposable resources after capturing results.

**Exit evidence:** POC checklist is complete or each failed item has a reproducible issue and owner; no credentials are present in committed files or logs.

## 6. Validation checklist

### Chart and dependency wiring

- [ ] Chart version is pinned; chart values render successfully.
- [ ] LAS release does not create PostgreSQL or Redis resources in external-dependency mode.
- [ ] LAS API and queue workloads receive the expected dependency configuration from Secret references.
- [ ] A dedicated PostgreSQL database is used for this LAS deployment.
- [ ] License is mounted using the chart-supported mechanism. Do not inject `LANGGRAPH_CLOUD_LICENSE_KEY` through a competing `extraEnv` path if the chart manages it.
- [ ] Required license-verification egress is documented and works in the POC environment, or the approved air-gapped procedure is followed.
- [ ] Confirm whether a separate `LANGSMITH_API_KEY` is required for the chosen configuration; it is distinct from the license key.

### Operator lifecycle

- [ ] AIService create installs exactly one release in the intended namespace.
- [ ] A second reconcile does not create duplicate releases or unnecessary changes.
- [ ] Release status and LAS readiness are reflected in AIService status.
- [ ] Invalid or missing Secret references fail clearly and do not report Ready.
- [ ] A correctable Helm/dependency failure can recover on a later reconcile.
- [ ] Updating supported values updates the existing release.
- [ ] AIService deletion removes LAS/operator-owned resources and preserves customer-owned PostgreSQL, Redis, and Secrets.

### Runtime smoke checks

- [ ] Health check is successful and in-cluster Service discovery resolves.
- [ ] A minimal agent invocation succeeds.
- [ ] Thread/run state persists across requests using PostgreSQL.
- [ ] Streaming or background execution works through Redis in the selected chart topology.
- [ ] No external service exposure is created unless explicitly required for the POC.

### Optional second-instance check

- [ ] Two AIService objects produce distinct Helm releases and independent status.
- [ ] Each release points to a distinct PostgreSQL database.
- [ ] If Redis is shared, the releases use isolated logical databases/endpoints as supported by LAS.
- [ ] Updating or deleting one release does not affect the other.

## 7. Suggested test cases

Keep tests focused on the POC contract, not on exhaustive production behavior.

1. Unit: deterministic release naming for an AIService/provider identity.
2. Unit: values/Secret reference generation; assert secret payloads are not copied into status or logs.
3. Controller: create AIService -> one release and expected status.
4. Controller: reconcile same object twice -> stable release and no duplicate resources.
5. Controller: missing dependency Secret -> actionable non-Ready status.
6. Controller: supported configuration update -> release upgrade request.
7. Controller: delete AIService -> release cleanup without deleting external dependency resources.
8. Cluster smoke: install, health check, sample run, persisted state, streaming/background behavior, upgrade, and deletion.

## 8. Agent implementation guardrails

- Start by inspecting repository guidance and existing controller conventions; report the intended files and design seam before broad changes.
- Keep changes limited to the POC path and its tests/docs. Do not reformat or modify unrelated dirty files in the shared working tree.
- Do not assume Helm release secrets, chart version behavior, or failure semantics; verify against the selected Helm library and chart.
- Never log or serialize license, database, Redis, or model credentials.
- Do not silently delete or mutate customer-owned dependency resources.
- Do not add tests outside this POC unless explicitly requested; validation should focus on the listed acceptance checks.
- Record exact versions, commands/steps, observed failures, and unresolved vendor questions in the POC result notes.

## 9. Open questions to resolve during the POC

1. What chart and server image versions are approved for the license key provided?
2. Does the license permit the optional second LAS instance test, or is it scoped to one deployment?
3. Is a separate LangSmith API key needed for license verification, traces, or this deployment mode? The standalone deployment documentation lists `LANGSMITH_API_KEY` and `LANGGRAPH_CLOUD_LICENSE_KEY` separately.
4. Which external PostgreSQL and Redis-compatible services are available for the POC, and what TLS/authentication requirements apply?
5. Is Redis logical database selection allowed in the target Redis service, or must each LAS deployment receive an isolated Redis endpoint?
6. Is the test cluster allowed to reach the license verification endpoint, or must an air-gapped procedure be validated?
7. Which AIService condition should represent Helm release readiness, and what service name/port does the AI tier caller expect?

## 10. Definition of done

- [ ] The minimum one-AIService vertical slice is documented and reproducible.
- [ ] The LAS chart runs with external PostgreSQL and Redis-compatible services and a Secret-sourced license.
- [ ] Operator install, reconcile, status, update, retry, and delete behavior passes the POC checks.
- [ ] Runtime smoke checks prove health, a sample run, persistence, and the selected streaming/background path.
- [ ] Dependency ownership and deletion behavior are demonstrated.
- [ ] POC findings, versions, follow-up work, and estimate changes are recorded.
- [ ] No carrier image or LAS/product contract work was included.

## References

- [LangChain: Self-host standalone Agent Servers](https://docs.langchain.com/langsmith/deploy-standalone-server)
- [LangChain Helm chart: `langgraph-cloud`](https://github.com/langchain-ai/helm/blob/main/charts/langgraph-cloud/README.md)
- [Initial AI tier estimate](las-ai-tier-estimate.md)
- [Detailed AI tier work breakdown](las-ai-tier-work-breakdown.md)
