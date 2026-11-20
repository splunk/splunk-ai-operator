# MPR-191 live readiness validation — 19 November 2026

Result: **9/9 cases passed on the existing agentruntime-dev CPU cluster**.
All temporary Kubernetes changes and authorized ingress rules were removed;
the original shared runtime and operator remained healthy and unchanged.
Sanitized results and condition snapshots are in
[mpr-191-live-results.json](validation/mpr-191-live-results.json).

## Candidate and execution scope

Branch `codex/MPR-191-readiness-gates`, base feature-branch commit
`bac158828b34ac574354153f76539f54b9f96986`, with the uncommitted MPR-191 changes.
The candidate is a static Linux/amd64 binary built with Go 1.26.10. Its SHA-256:

```text
aa714c823e2f7e56d7a17be7d1ec95f1592ec04769164dbf163107571eefc380
```

The reusable [scoped command](../../cmd/mpr191-live/main.go) registers both
production AIService and AIPlatform reconcilers, handlers, watches and predicates.
Its cache is restricted to an explicit disposable `mpr191-*` namespace. It
impersonates that namespace's test ServiceAccount, bound through a namespaced
RoleBinding to the generated source role. No broad admin identity is used by
the reconcilers. This validates the changed discovery permissions in the live
API server; it does not validate container-image packaging or an operator upgrade.

A namespace-specific admission guard prevented the legacy operator from writing
to the fixture. Server-side checks confirmed that the legacy identity was denied
and the test identity allowed. The shared operator and its webhook server stayed
running. Older webhooks were excluded only from the labelled test namespace.
The older installed CRDs needed five missing prerequisite profile/schema-status
fields from the feature branch. Only those fields were temporarily added; no
whole CRD replacement was performed. They were removed after namespace cleanup,
and both complete original CRD specs were compared successfully.

The fixture used a cpuOnly AIPlatform, an MLTK AgentRuntime with **two desired
replicas**, and dedicated disposable PostgreSQL/Secrets with no persistent volume.
It did not use the shared runtime's database or change its platform annotations.
No cluster, worker, preparation host or SSH key was created or replaced.

## Verified component identities

All three images were digest-pinned after ECR verification. Live container
imageIDs confirmed the runtime, provider init container and successful schema
Job used these digests. Registry/account details and access evidence remain local.

| Component | Digest |
| --- | --- |
| Agent Runtime | `sha256:ddedf855e6751625d1eae206793fe3cd14d72c6934609fe2c0641c9a8eae5219` |
| MLTK provider | `sha256:d73301133cf67ce561bd04b52a5f7947134cad955c18bba1ab2ea0537c0319f5` |
| Schema setup | `sha256:5877fcbdea301b945af0be55eeb33bcb30c93b0e3b1906a58be779680650d987` |

## Observed cases

The observations came from the real API server, Deployment/EndpointSlice
controllers and kubelet. No AIService, AIPlatform or workload status was patched
to manufacture a result. An optional client wrapper held only the disposable
Deployment's probe path or Service selector at the requested fault value so
normal reconciliation could not repair it before the failure was observed.

| Case | Result and evidence |
| --- | --- |
| Initial schema and complete rollout | Passed. Schema Job succeeded; two updated, ready and available replicas; matching ready endpoints; GET `/health` through the Service returned HTTP 200; child and parent current-generation Ready=True. |
| Actual kubelet probe failure during rollout | Passed. Kubelet emitted HTTP 404 readiness-probe failures. Two old replicas remained available while only one replacement was updated/unready; child Ready=False/`RolloutPending`, parent Ready=False/`AgentRuntimeNotReady`. Old capacity did not satisfy the gate. |
| Probe recovery | Passed. Restored probe; complete rollout and both Ready=True recovered. |
| Selector mismatch and endpoint loss | Passed. Two runtime replicas stayed healthy, but the Service had zero ready backends. Child Ready=False/`SelectorMismatch`; parent Ready=False. |
| Endpoint recovery | Passed. Restored selector; live endpoints and both Ready=True recovered. |
| Completed schema Job removed | Passed. Deleted the completed Job to model TTL cleanup. Recorded success/applied hash remained valid, with no rerun and both Ready=True. This does not test the TTL controller's 24-hour timing. |
| Controller restart and unchanged reconciliation | Passed. Restarted the scoped controller and delivered a real Pod label event. Child/parent resource versions, Deployment generation/template and Pod UIDs stayed stable through an additional eight-second observation; no schema Job was created. |
| Changed schema inputs and failed Job | Passed. Invalidated only the disposable database credential. The real schema Job exhausted retries, current-generation child Ready=False/`Failed` propagated to the parent while runtime Pods remained healthy. Condition messages contained no test password or database URL. |
| Schema retry recovery | Passed. Restored the disposable credential, producing new input identity and successful schema execution; child and parent Ready=True recovered. |

The first three passing cases and subsequent six used the same fixed binary and
fixture. A test-checker correction required resuming at the endpoint-loss check;
its recorded elapsed time measures resumed observation of an already-held fault,
not injection-to-detection latency. Other elapsed values include polling and are
functional test observations, not performance guarantees.

## Issue discovered and corrected

The first complete rollout exposed a real reconciliation conflict: the runtime
handler removed `deployment.kubernetes.io/revision`, and Kubernetes restored it.
That loop repeatedly advanced Deployment generation, preventing its observed
generation from catching up even with healthy Pods. The handler now preserves
this Kubernetes-owned annotation on Deployment metadata and excludes it from
the Pod template. The fixed binary passed all live cases, including restart and
unchanged reconciliation. A focused unit regression and the local API-server
stability test cover preservation and lack of template/generation churn.

Two test-fixture corrections were also necessary: supplying the runtime image's
`PG_SSLMODE`/`DATABASE_URL` settings for the disposable plaintext PostgreSQL, and
treating a null EndpointSlice endpoint list as empty in the Python checker.
These are recorded separately from the product fix; neither justified changing
the runtime image or shared database configuration.

The complete local non-E2E suite passed after the product fix (30 packages,
including controller/webhook API-server tests), as did `go vet ./...`. The final
focused runtime/schema run passed 61 test/subtest events with zero failures.

## Cleanup and retained limits

Cleanup verified all of the following:

- Scoped controller stopped; disposable namespace, PostgreSQL, Secrets and
  workloads deleted; test policy, binding and ClusterRole removed.
- Both original CRD specs and all original webhook namespace selectors restored.
- Shared operator specification unchanged and one replica Ready. Shared native
  runtime Deployment UID/generation and Pod UIDs matched the original baseline;
  its replica, AIService and AIPlatform were Ready. All three nodes were Ready.
- Remote test binaries/logs/backups removed after evidence collection; existing
  cluster access files preserved.
- Both run-created ingress rules removed. A fresh AWS read matched every
  original security-group rule exactly; no persistent test SSH control socket
  remained. No access rule or key was retained.

Private evidence stays in the locally excluded run directory. This result
qualifies the MPR-191 readiness behavior exercised here. Product request paths,
streaming/inference, continuous PostgreSQL checks, GPU/fullfeature behavior,
installation/upgrade, TLS and OS matrices retain their separate test scope.
The candidate had not been committed or published when these live tests ran.
Readiness evidence alone does not imply Jira closure or a merged change.
