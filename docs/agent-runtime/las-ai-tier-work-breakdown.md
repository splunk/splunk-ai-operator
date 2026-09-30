# Standalone LAS AI Tier Work Breakdown

**Purpose:** Break down the AI tier work to deploy standalone LangSmith Agent Server (LAS) as one Helm release per AIService.  
**Estimate basis:** Staff Engineer using enterprise-grade AI development tools, including Codex.  
**Effort unit:** Engineer-month (EM), approximately four weeks of focused engineering.

## Scope baseline

- Standalone LAS; no LangSmith deployment control plane.
- The operator creates, reconciles, observes, upgrades, and removes one LAS Helm release per AIService.
- One product is onboarded in the initial release. Keep identity, configuration, status, and release naming scoped per AIService/provider so additional product LAS instances do not require a singleton-to-multi-instance redesign.
- The customer provides PostgreSQL and Redis-compatible service details and credentials. AI tier does not provision these services in the initial release.
- PostgreSQL service may be shared across LAS instances, but each LAS release uses its own database.
- Use upstream chart values first; maintain only necessary chart modifications.
- Carrier image changes and LAS/product contract matching are excluded.

## Task estimates and validation

### 1. Chart fit check and release/value design — 0.15–0.25 EM

| Task | Effort | Validation evidence |
|---|---:|---|
| Review and pin a candidate LAS chart version; identify chart-owned resources, external PostgreSQL/Redis options, API/queue topology, probes, services, and upgrade behavior. | 0.10–0.15 | Chart dependency/version recorded; values inventory and unsupported requirements documented. Rendered chart output confirms expected resources and that bundled dependencies can be disabled when external services are used. |
| Define the per-AIService Helm release identity and values/Secret contract, including customer database/Redis inputs and provider scoping. | 0.05–0.10 | Design note or API proposal reviewed; release names are deterministic and distinct across AIService/provider instances; sensitive values are passed by Secret reference, not embedded in chart values or logs. |

### 2. Helm release lifecycle in the operator — 0.5–0.8 EM

| Task | Effort | Validation evidence |
|---|---:|---|
| Add chart retrieval/packaging and Helm action support to the operator runtime and deployment packaging. | 0.10–0.15 | Operator image/package includes the selected chart or can reliably retrieve it under the supported network policy; install works with the intended service account and RBAC. |
| Implement idempotent install and reconciliation for a release derived from one AIService. | 0.20–0.30 | Repeated reconciles converge without duplicate resources; two AIService objects produce separate releases; release state is tied to the intended namespace and owner. |
| Implement upgrade, failed-release recovery, and deletion behavior. | 0.10–0.20 | A values/version change upgrades the intended release; simulated or induced failure is surfaced and retryable; AIService deletion removes the release without deleting customer-owned database or Redis resources. |
| Surface Helm release state and errors through AIService conditions/events. | 0.10–0.15 | Ready is reported only after chart workloads and required service are ready; install/upgrade errors are visible in status/events and reconciliation retries converge after correction. |

### 3. AIService settings and customer-provided dependencies — 0.2–0.35 EM

| Task | Effort | Validation evidence |
|---|---:|---|
| Map existing AIService/provider settings to chart values for resource requests/limits, scheduling, image pull secrets, and supported replica/scaling controls. | 0.10–0.15 | Rendered values match the AIService spec; omitted fields receive documented defaults; provider-specific settings do not leak between releases. |
| Define and implement the PostgreSQL and Redis-compatible connection/Secret references for a LAS release. | 0.10–0.20 | LAS pods receive required settings through Secret references; credentials are not logged or copied into status; a missing/invalid reference fails clearly before reporting Ready. |

### 4. Readiness, service access, security, and monitoring — 0.25–0.45 EM

| Task | Effort | Validation evidence |
|---|---:|---|
| Integrate the LAS API Service with the AI tier’s in-cluster discovery and access expectations. | 0.05–0.10 | The expected Service name and port resolve within the supported namespace; access remains limited to intended callers and does not create unrequested external exposure. |
| Map startup/readiness/health behavior to AIService readiness and remove or adapt legacy runtime-specific certificate/schema stages as required. | 0.05–0.10 | AIService readiness follows the chart’s actual server state; LAS failure and recovery update conditions correctly; no readiness dependency remains on the legacy schema Job unless LAS requires it. |
| Configure supported network and security controls for the chart workloads and external database/Redis egress. | 0.05–0.10 | Rendered workloads use approved service accounts/security settings; required egress is documented and validated; Secrets are mounted/referenced with least exposure. |
| Integrate metrics scraping and workload scaling defaults for LAS API and queue roles. | 0.10–0.15 | Metrics are discoverable by the supported monitoring stack; rendered scaling resources match documented limits; API/queue behavior is separately observable where the chart separates them. |

### 5. Tests, cluster qualification, packaging, and documentation — 0.45–0.7 EM

| Task | Effort | Validation evidence |
|---|---:|---|
| Add unit and controller tests for release identity, value generation, Secret handling, lifecycle, status, retries, and deletion. | 0.12–0.20 | Automated tests cover create, no-op reconcile, update, failure/retry, multiple providers, and cleanup without touching customer-owned dependencies. |
| Qualify installation, upgrade, recovery, and deletion on a representative Kubernetes cluster with external PostgreSQL and Redis-compatible service. | 0.20–0.30 | Qualification record captures chart/operator versions and outcomes; LAS becomes Ready, survives a chart upgrade, recovers from a dependency/release failure, and is removed cleanly. |
| Pin and package supported chart versions and update the operator deployment artifacts as needed. | 0.08–0.10 | Clean package/install path uses the pinned chart; a version change is explicit and reviewable; no unpinned chart dependency is required for a supported offline/air-gapped mode unless separately approved. |
| Add AIService samples and operator/customer documentation for dependency Secrets, PostgreSQL database isolation, Redis-compatible endpoint requirements, and troubleshooting. | 0.05–0.10 | Sample validates against the CRD; documented setup can be followed to install one customer-managed LAS instance; required network and data ownership assumptions are stated. |

### 6. Integration uncertainty allowance — 0.2–0.3 EM

Reserve this effort for chart gaps, Helm SDK behavior, cluster policy interactions, and integration defects discovered during qualification.

**Validation:** consume this allowance only against documented issues or required fixes. If unused, do not treat it as additional feature scope.

## Initial-path total

| Work area | Effort |
|---|---:|
| Chart fit check and release/value design | 0.15–0.25 EM |
| Helm release lifecycle | 0.5–0.8 EM |
| AIService settings and external dependency references | 0.2–0.35 EM |
| Readiness, access, security, and monitoring | 0.25–0.45 EM |
| Tests, qualification, packaging, and documentation | 0.45–0.7 EM |
| Uncertainty allowance | 0.2–0.3 EM |
| **Total** | **1.8–2.8 EM** |

## Later options and validation

These are not part of the initial-path total. There is overlap between the options, especially in per-AIService configuration and release lifecycle.

| Later capability | Effort | Validation evidence |
|---|---:|---|
| Multi-product LAS support | +0.4–1.0 EM when per-AIService abstractions are preserved; +0.8–1.8 EM if refactoring is required | At least two provider LAS releases with distinct settings coexist, reconcile independently, report independent status, and upgrade/delete without cross-impact. |
| AI tier provisions isolated databases on customer-managed PostgreSQL | +0.4–0.8 EM | Each LAS release receives a distinct database and scoped credentials; reconcile retries are safe; deletion follows an approved data retention policy and never drops data unexpectedly. |
| AI tier operates Valkey | +0.8–1.6 EM | Valkey lifecycle, authentication/TLS, availability, monitoring, upgrades, and failure recovery are validated; LAS uses the selected Valkey version successfully under representative run/stream/cancel workloads; support status is documented. |

**Combined later work:** +1.5–3.0 EM when implemented after the initial integration, subject to overlap and product requirements. The combined program estimate is **3.3–5.8 EM**.

## Open validation questions

1. Will the customer provide a separate PostgreSQL database and credentials for each LAS instance, or only a shared service endpoint from which AI tier is expected to provision databases?
2. Is Valkey an approved first-release backend, or should the initial contract accept customer-provided Redis-compatible service while Valkey qualification remains a later gate?
3. Which cluster installation modes must be supported at launch, particularly private registries, restricted egress, and air-gapped installation?
4. What is the required behavior for persisted LAS state when an AIService is deleted or a provider is offboarded?

## External references

- [LangChain: Self-host standalone Agent Servers](https://docs.langchain.com/langsmith/deploy-standalone-server)
- [LangChain: Agent Server data plane](https://docs.langchain.com/langsmith/data-plane)
- [LangChain: Agent Server Helm chart configuration](https://github.com/langchain-ai/helm/blob/main/charts/langgraph-cloud/README.md)
- [Valkey: Redis compatibility and migration](https://valkey.io/topics/migration/)
