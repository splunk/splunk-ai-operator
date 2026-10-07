# LAS AI tier implementation plan after the POC

**Planning baseline:** 2026-10-05 POC on branch `las-poc`  
**Goal:** Make LAS the supported implementation of the existing `agentruntime` AIService feature, with one stable Helm release per AIService and externally managed PostgreSQL and Redis-compatible dependencies.  
**Current state:** The vertical slice works in the test cluster. It is not a production release. See the [POC handoff](las-ai-tier-poc-handoff-20261005.md) and its linked evidence.

This plan replaces the sequence in the original [POC brief](las-ai-tier-poc.md) and reorganizes the pre-POC [work breakdown](las-ai-tier-work-breakdown.md) around decisions, implementation dependencies, and release gates. The POC decided that LAS replaces the former direct-managed runtime; it is not a separate AIService type.

## Scope and design rules

- Keep `name: agentruntime` and the AIService/provider identity. One AIService owns one release in its namespace; do not introduce a second runtime type.
- Treat PostgreSQL and Redis as customer-managed for the first increment. Require one PostgreSQL database and one isolated Redis database/endpoint per LAS release. Define credentials and retention explicitly. Do not add automatic provisioning without a separate decision.
- Keep credentials in Secrets and Helm values free of secret payloads. Support the approved connected/private-registry modes explicitly.
- Use an approved, pinned chart and Agent Server image. The current ECR sample image and hardcoded image tag are POC artifacts.
- Preserve the established AIService Service address during migration, while defining the LAS HTTP contract for callers. DNS compatibility alone is insufficient.
- Keep carrier image changes, product contract matching, AI tier-managed databases/Valkey, and unapproved air-gapped support outside this initial implementation.

## Critical path and release gates

| Gate | What must be true before proceeding |
| --- | --- |
| **G0 — contract approved** | Image/graph ownership, AIService configuration and legacy-field policy, caller route/payload/authentication, dependency isolation/retention, and licensing mode are recorded. |
| **G1 — implementation reviewable** | POC code is split into coherent changes, chart/image configuration is supported, generated schemas/RBAC match source, and focused LAS tests pass. |
| **G2 — unattended lifecycle** | Fresh install, no-op reconcile, upgrade, Secret rotation, failure/retry, rollback, and deletion pass without manual edits. Queue upgrades complete under the minimum supported cluster capacity. |
| **G3 — product path works** | A real supported graph/image is reached through the agreed AI tier caller path, with the required auth and request/response behavior. |
| **G4 — release qualification** | Security, observability, storage/retention, multi-instance, upgrade/migration, and operational documentation meet the launch bar. The license mode and entitlement are approved. |

Work on packaging, lifecycle tests, and dependency design can proceed in parallel after G0. G2 and G3 are both required before release qualification.

## Epic 0 — Decide the supported contract

**Outcome:** An architecture decision and customer-facing contract that remove ambiguity exposed by the POC.

| Jira-ready task | Concrete decision or deliverable | Acceptance |
| --- | --- | --- |
| 0.1 Define the Agent Server artifact contract | Decide who builds and supplies each LAS graph image, how it is pinned, which registry/authentication modes are supported, and whether image/version is set per AIService or by operator deployment policy. | A sample customer configuration uses a non-POC image without rebuilding the operator for an ordinary image change, or the approved rebuild policy is explicit. |
| 0.2 Define AIService configuration and migration | Specify LAS fields, defaults, resource/rollout controls, provider identity, and the policy for legacy `runtimeVersion`, `checkpointDbSecretRef`, `env`, and HPA fields that are currently accepted but ignored by LAS. | Webhook behavior, CRD schema, migration notes, and upgrade path agree; no customer setting is silently ignored. |
| 0.3 Define caller protocol | Specify the LAS API route, request/response/stream format, authentication, and which Service name/port SLIM/AITK or other callers use. | A documented contract and a representative request from the intended caller exist. |
| 0.4 Define dependency ownership | Choose distinct database/credential requirements, Redis logical DB versus endpoint policy, TLS requirements, backup, and data retention on AIService deletion. | Customer and operator responsibilities and deletion semantics are written down and testable. |
| 0.5 Confirm license and deployment modes | Confirm instance entitlement, verifier success signal, need for `LANGSMITH_API_KEY`, required egress, and first-release connected/restricted/air-gapped modes. | Vendor/product decision is recorded; release tests have an observable pass condition. |

**Dependency:** This gate defines the implementation and release target. The POC's licensed runtime startup is useful evidence but is not a contract or transaction-level verifier result.

## Epic 1 — Turn the vertical slice into a maintainable operator change

**Outcome:** One active LAS implementation with reviewable API, packaging, and configuration.

| Jira-ready task | Implementation work | Acceptance |
| --- | --- | --- |
| 1.1 Split and review the POC branch | Separate LAS operator/API/chart changes from the broader SLIM/Splunk/k0s E2E changes. Commit the embedded chart, sample source, generated CRDs/RBAC, and build inputs in coherent reviews. | A reviewer can trace source → generated manifests → image artifact; unrelated installer changes are not hidden in the LAS change. |
| 1.2 Retire or quarantine the direct runtime path | The feature factory already selects LAS, but `pkg/ai/features/agentruntime/impl.go` and most tests still exercise the old direct-managed runtime. Remove dead code after migration handling is preserved, or isolate it behind an explicit supported migration path. | There is one supported runtime implementation for `agentruntime`; tests target that implementation, and existing AIService upgrades remain safe. |
| 1.3 Support artifact and chart configuration | Replace hardcoded POC ECR repository/tag in `las.go` with the G0 contract. Keep explicit chart version/digest pinning, require immutable chart packages or compare the deployed digest, and define a controlled upgrade path. | A supported image/chart update is reviewable and reproducible; a changed chart cannot be silently skipped under the same version; values remain Secret references, not credential values. |
| 1.4 Reconcile API and installer schemas | Keep API types, webhook validation, both CRD copies, samples, RBAC, and k0s profile synchronized. Add focused installer assertions for the three LAS Secret refs and generated AIPlatform feature. | Generated manifests match source; invalid/missing LAS refs fail clearly; a clean install path does not depend on an operator image with local-only configuration. |

The POC image was packaged after Docker Desktop exhausted disk space. The production build path should produce the same immutable artifact through CI rather than rely on a workstation workaround.

## Epic 2 — Make Helm lifecycle and configuration reliable

**Outcome:** Operator-owned install and upgrade converge without manual cluster edits.

| Jira-ready task | Implementation work | Acceptance |
| --- | --- | --- |
| 2.1 Fix queue upgrade headroom | Review chart-supported queue resource requests and rollout strategy. Choose either sufficient minimum cluster capacity or a supported zero-surge/recreate setting with an explicit availability tradeoff. | A one-replica queue upgrade completes unattended at the minimum supported capacity; the Plan 2 `Insufficient cpu` case is a regression test. |
| 2.2 Handle Secret data rotation | The controller watches referenced Secrets, but `lasValues` compares only Secret names; env values in running Pods do not refresh automatically. Add a safe rollout trigger or documented rotation mechanism for license, PostgreSQL, and Redis Secret data. | Rotating each Secret changes the intended Pods once, retains the release identity, and restores Ready without exposing values. |
| 2.3 Harden release state handling | Cover interrupted installs/upgrades, pending/failed releases, atomic rollback, missing resources, ownership conflict, retries, and finalizer errors. Keep retries observable without a several-minute blind period after a corrected dependency. | Automated tests and cluster fault injection show deterministic recovery and useful AIService condition/event messages. |
| 2.4 Verify readiness and service drift | Ensure API and queue readiness, compatibility Service selector/port, and Helm chart Service are checked against the desired state. Define behavior if an operator-owned Service or Deployment is externally changed. | No false Ready; drift is repaired or reported, and a no-op reconcile does not roll Pods or create revisions. |
| 2.5 Add LAS-focused unit/controller tests | Test release name/ownership, chart digest/version, values/Secret references, no-op behavior, status transitions, install/upgrade/finalize paths, and multi-instance scoping. Replace legacy-only tests with current-path coverage. | Focused tests exercise `LASReconciler` directly, not only the old `AgentRuntimeReconciler`; cluster tests remain a separate integration layer. |

## Epic 3 — Define secure external dependency operations

**Outcome:** A customer can supply and operate dependencies safely across multiple LAS instances.

| Jira-ready task | Implementation work | Acceptance |
| --- | --- | --- |
| 3.1 Publish dependency and Secret contract | Document required keys, URL forms, authentication/TLS, one-database-per-release rule, Redis DB/endpoint policy, and customer ownership. Validate syntax and supported connectivity failure modes without logging credentials. | A customer follows the guide to bring up one and two independent instances; invalid settings produce actionable status. |
| 3.2 Scope access and image pulls | Review service accounts, RBAC, pod security, egress to PostgreSQL/Redis/license endpoint, and private registry pulls. Replace the POC's expiring per-node ECR token workaround with a supported durable method. | Fresh install and Pod replacement can pull images and reach only approved destinations using the supported deployment mode. |
| 3.3 Define data retention and recovery | Specify what AIService deletion preserves, how database/Redis data is backed up/restored, and who performs offboarding cleanup. | Deletion tests leave external data intact by default; recovery/retention tests match the approved policy. |
| 3.4 Decide optional Valkey qualification | Do not infer support from Redis protocol similarity. If Valkey is in launch scope, test the selected version with queued runs, streaming, restart, and failure recovery. | A documented supported version/result exists, or Valkey remains explicitly unsupported. |

## Epic 4 — Integrate the actual AI tier caller and graph

**Outcome:** The product path works, beyond the POC's direct `echo` API call.

| Jira-ready task | Implementation work | Acceptance |
| --- | --- | --- |
| 4.1 Replace sample graph assumptions | Define the supported product graph/image build, versioning, configuration, model/tool dependencies, and observability hooks. Keep the deterministic sample only as a smoke fixture. | A real graph image deploys through the approved artifact contract and survives restart/upgrade. |
| 4.2 Connect SLIM/AITK to LAS | Resolve the final `PLATFORM_URL` route and payload mapping. The compatibility Service currently preserves DNS and port but LAS has a different HTTP protocol. Scope authentication and authorization deliberately. | A request initiated through the intended caller reaches LAS, returns the expected result/stream, and persists state; failures are traceable across the path. |
| 4.3 Validate migration from existing AgentRuntime | For existing AIPlatform/AIService objects, define rollout order, service cutover, state migration or reset, rollback, and legacy resource cleanup. | An upgrade rehearsal keeps the expected service endpoint, produces a clear status, and has an exercised rollback path. |

Carrier image work or product contract matching should be added as separate work only if the agreed caller contract requires them.

## Epic 5 — Operate and qualify the release

**Outcome:** A supported installation can be monitored, upgraded, and recovered by operators and customers.

| Jira-ready task | Implementation work | Acceptance |
| --- | --- | --- |
| 5.1 Add operational visibility | Define API/queue metrics, structured logs, Helm revision/status visibility, alert thresholds, capacity signals, and runbooks for common dependency and licensing failures. | An operator can distinguish API, queue, Helm, Secret, PostgreSQL, Redis, image-pull, and license failures without reading credentials. |
| 5.2 Qualify supported deployment modes | Test clean installation and upgrade with the approved registry/network modes, correct chart and image digests, multi-instance isolation, and restricted egress if in scope. | A reproducible qualification record exists for each supported mode; the queue upgrade passes without live patching. |
| 5.3 Run lifecycle and recovery matrix | Repeat manual POC checks on an operator-owned release: queued background run, SSE stream, API/queue restarts, saved state, no-op reconcile, Secret rotation, induced Helm/dependency failures, rollback, deletion, and dependency preservation. | Each case has automated or scripted pass evidence and known issue tracking; no POC-only manual intervention is needed. |
| 5.4 Exercise capacity and availability | Test the minimum supported node capacity, queue/API scaling policy, Pod disruption, upgrade surge, and selected HA expectations. | Resource requests and rollout settings have a documented sizing envelope and failure behavior. |
| 5.5 Publish customer and release docs | Produce configuration examples, install/upgrade/migration instructions, Secret rotation, database/Redis ownership, troubleshooting, and version support matrix. | Docs match the shipped CRDs/chart/image and are validated from a clean setup. |

## Suggested implementation order

1. Complete Epic 0 decisions and isolate the POC source changes for review.
2. In parallel, implement Epic 1 packaging/API cleanup, Epic 2 queue/Secret lifecycle fixes, and Epic 3 dependency/security contract.
3. Integrate the real graph and caller path in Epic 4 once the image and HTTP contracts are fixed.
4. Run Epic 5 qualification across all supported deployment modes; release only after G2–G4 pass.

The pre-POC estimate of **1.8–2.8 engineer-months** described the initial integration path, not remaining production effort. Do not subtract completed POC work mechanically. Re-estimate these epics after G0 choices, especially the required caller contract, license mode, image pipeline, queue availability target, and deployment modes. Track the queue upgrade fix, Secret rotation, and LAS-specific test expansion explicitly; they were not closed by the POC.

## Release decision

The POC justifies proceeding with implementation. It does not justify a production release yet. A release candidate should be blocked if it still requires a manual queue Deployment patch to upgrade, embeds the POC ECR image as the only runtime choice, silently ignores accepted AgentRuntime fields, cannot handle Secret rotation, lacks the agreed caller flow, or has unresolved license/dependency ownership for the selected deployment mode.
