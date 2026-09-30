# Standalone LAS Integration: AI Tier Effort Estimate

**Estimate date:** 2026-09-30  
**Status:** Directional planning estimate  
**Estimate basis:** One Staff Engineer driving implementation and validation with enterprise-grade AI development tools, including Codex.

## Executive summary

The estimated effort for the first standalone LangSmith Agent Server (LAS) integration in AI tier is **1.8–2.8 engineer-months (EM)**. A practical planning point is **2.3 EM**. For one Staff Engineer working primarily full time, this is approximately **8–12 weeks of focused work**, excluding external wait time for customer infrastructure, vendor responses, or review queues.

The estimate assumes the AI tier operator creates and reconciles one upstream LAS Helm release for each AIService. The customer supplies the PostgreSQL service and Redis-compatible endpoint and credentials. AI tier does not initially provision or operate these services.

If AI tier later adds multi-product LAS variations, database provisioning, and AI tier-managed Valkey, the combined effort is estimated at **3.3–5.8 EM**, including the initial integration. The later-option estimate is conditional and has wider uncertainty because the required product-specific differences and support commitments are not yet known.

## Target design and estimate assumptions

- LAS runs in standalone mode without the LangSmith deployment control plane.
- The operator owns the Helm release lifecycle: install, upgrade, observe, and uninstall.
- Each AIService maps to one LAS Helm release. The `agentruntime` provider identifies the product/provider instance and remains the per-instance identity used for configuration and resource naming.
- The first onboarding is for one product LAS. The implementation should avoid tier-wide singleton assumptions so additional providers can be added through the same per-AIService model.
- PostgreSQL is customer-managed and may be shared as a service across LAS instances. Each LAS deployment uses a distinct database; LangChain documents that separate deployments must not reuse the same database.
- Redis is not currently managed by AI tier. The initial integration accepts a customer-provided Redis-compatible service and Secret. Valkey is a candidate, but its support in the selected LAS/chart version must be qualified.
- The upstream LAS chart is used with values wherever possible. Any chart modifications are limited to necessary integration gaps and should be maintained as a small, explicit patch set.
- The estimate includes implementation, automated tests, cluster qualification, packaging/version pinning, and documentation.
- AI-assisted development is expected to accelerate scaffolding, implementation iteration, and test authoring. The estimate still includes engineering review and real-cluster validation.

## Existing implementation leveraged

The current AgentRuntime implementation provides a useful foundation: AIService/provider identity and validation, reconciliation stages and status conditions, resource naming and ownership patterns, Secret references, scheduling/resource configuration, image pull secrets, metrics/HPA patterns, and a unit-test scaffold.

The LAS implementation will replace or adapt parts of the existing runtime-specific reconciliation. In particular, direct management of the in-house runtime Deployment, Service, HPA, and PostgreSQL schema setup Job is not assumed to transfer directly. LAS chart behavior for database initialization, workload structure, health probes, service exposure, and scaling needs to be confirmed.

Relevant current code includes the [AgentRuntime reconciler](../../pkg/ai/features/agentruntime/impl.go) and [AIService API type](../../api/v1/aiservice_types.go).

## Initial integration estimate

| Work area | Effort |
|---|---:|
| Upstream chart fit check and release/value design | 0.15–0.25 EM |
| Helm release lifecycle in the operator | 0.5–0.8 EM |
| AIService settings and customer-supplied dependency references | 0.2–0.35 EM |
| Readiness, service access, security, and monitoring integration | 0.25–0.45 EM |
| Tests, cluster qualification, packaging, and documentation | 0.45–0.7 EM |
| Integration uncertainty allowance | 0.2–0.3 EM |
| **Total** | **1.8–2.8 EM** |

The detailed task list and validation evidence are in [Standalone LAS AI Tier Work Breakdown](las-ai-tier-work-breakdown.md).

## Later options

| Later capability | Incremental effort | Notes |
|---|---:|---|
| Multi-product LAS support | +0.4–1.0 EM | Assumes the initial design keeps release configuration and status scoped per AIService. If product differences force refactoring, allow +0.8–1.8 EM instead. |
| Customer PostgreSQL database provisioning by AI tier | +0.4–0.8 EM | Assumes the customer still operates PostgreSQL; AI tier provisions isolated databases and manages credentials/lifecycle. |
| AI tier-managed Valkey | +0.8–1.6 EM | Adds Valkey lifecycle, availability, security, monitoring, upgrades, and LAS compatibility qualification. |
| **Combined later work** | **+1.5–3.0 EM** | Ranges overlap in per-instance configuration and lifecycle work; do not sum all maxima mechanically. |

The combined estimate, including the initial integration, is **3.3–5.8 EM**. Higher effort is possible if multi-product onboarding requires independent chart versions, materially different deployment policies, or platform-wide dependency architecture changes.

## Estimate risks and uncertainty

1. **Helm lifecycle inside the operator:** release storage, idempotency, interrupted upgrades, rollback behavior, and deletion semantics may require more custom handling than anticipated.
2. **Chart fit:** the upstream chart may not expose all required values for service naming, security, metrics, resource limits, or cluster policy. Any needed chart fork increases maintenance and upgrade effort.
3. **Database contract:** the customer can provide a shared PostgreSQL service, but each LAS release needs a distinct database. The effort changes depending on whether the customer supplies per-instance database credentials or AI tier must provision databases from shared credentials.
4. **Valkey support:** Valkey uses the Redis protocol and is technically plausible, but official standalone LAS documentation identifies Redis and does not establish a Valkey support commitment. Qualification results or vendor confirmation may change the estimate.
5. **Multi-product variation:** provider-specific runtime settings, chart versions, scaling, security, and data policies are not yet defined. These variations determine whether provider identity is enough or a richer per-provider configuration model is needed.
6. **Operational expectations:** high availability, backups, air-gapped deployment, cluster upgrades, and long-running request draining can add work if required for the first release.
7. **External validation availability:** access to a representative cluster, PostgreSQL service, and Redis-compatible service can affect elapsed calendar time even when engineering effort is unchanged.

## Scope exclusions

- Carrier image changes and contract matching between LAS and product carriers.
- Changes to LAS server implementation itself.
- LangSmith Cloud, Hybrid deployment control plane, or self-hosting the full LangSmith platform.
- AI tier-managed PostgreSQL or Valkey in the initial integration.
- Product-specific agent behavior or functional validation owned by product teams.

## References

- [LangChain: Self-host standalone Agent Servers](https://docs.langchain.com/langsmith/deploy-standalone-server)
- [LangChain: Agent Server data plane](https://docs.langchain.com/langsmith/data-plane)
- [LangChain: Agent Server Helm chart configuration](https://github.com/langchain-ai/helm/blob/main/charts/langgraph-cloud/README.md)
- [Valkey: Redis compatibility and migration](https://valkey.io/topics/migration/)
