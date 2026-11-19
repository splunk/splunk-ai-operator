# MPR-191 implementation and verification — 19 November 2026

Branch: `codex/MPR-191-readiness-gates`, based on `ai-agent-runtime` commit
`bac158828b34ac574354153f76539f54b9f96986`. This report describes the local
working-tree change. Local verification passed, followed by nine live cases on
the existing **agentruntime-dev** deployment. See the
[live validation report](mpr-191-live-validation.md) for exact image identities,
test isolation, the live-discovered fix and verified cleanup. The candidate ran
as a scoped Linux binary using the production reconcilers; an operator container
image and installation/upgrade path were not qualified.

## Resulting readiness contract

AgentRuntime now distinguishes successful object reconciliation from an
operational runtime. Overall `Ready=True` requires:

- Current schema success from the existing MPR-189 lifecycle. Recorded success
  remains valid after completed-Job TTL cleanup while schema inputs are
  unchanged. A retry, changed input, failed or unknown attempt cannot reuse that
  historical success.
- An owned Deployment whose current generation has been observed, with every
  desired replica updated, ready and available. Old available replicas do not
  satisfy an incomplete rollout.
- Healthy current Pods belonging through a ReplicaSet to the desired Deployment
  template. The runtime container must have the agreed GET `/health` probe,
  report ready/running, and belong to a nonterminating Pod with `PodReady=True`.
- An owned ClusterIP Service with the expected selector/application port, and a
  ready application EndpointSlice backend matching the Service UID and a
  current healthy Pod UID/address. Foreign, stale, wrong-port, missing and
  nonready backends do not satisfy readiness.

The handler always supplies overall readiness, including on errors. Conditions
carry observed generation, retain transition times when status is unchanged,
preserve unrelated status and bounded prior diagnostic reasons, and skip
unchanged status writes. Persistence failures are returned. Blocked downstream
observations are explicit rather than carrying forward an apparent success.

Pod, ReplicaSet and EndpointSlice changes map to the owning runtime AIService through
namespace-scoped indexes. Both resource-specific and controller-wide predicates
admit health changes and deletion. Existing Job/Deployment status watches remain
intact. Service spec changes are also admitted even when their generation does
not change. Ordinary nonready workload observation has a five-second retry fallback.

Deployment reconciliation preserves Kubernetes' revision annotation on
Deployment metadata and excludes it from the Pod template. Live execution
exposed a generation loop when the operator removed that annotation and the
Deployment controller restored it. Unit, API-server and live restart/no-op
checks now cover this behavior.

AIPlatform now requires current `Ready=True` for each configured AgentRuntime
child, rather than relying on the string `Error`. Meaningful child readiness
changes wake the parent, while unrelated child writes remain filtered to avoid
spec reconciliation loops. Fullfeature's existing infrastructure precondition
is retained; AgentRuntime does not wait on parent overall readiness.

The generated and Helm roles add only `get/list/watch` for EndpointSlices and
ReplicaSets. No new endpoint-write permission or new CRD field is introduced.

## Local evidence

The original lifecycle test was first changed to expect nonready workload
conditions after schema completion alone. It failed against the original code,
demonstrating the false-positive readiness behavior, and passes with the change.

The focused runtime/schema result and condition snapshots are recorded in
[mpr-191-results.json](validation/mpr-191-results.json). The snapshots come from
actual handler status in an in-memory test fixture: healthy, completed Job
removed, and changed schema inputs. Image digests, database credentials and
workload statuses in these unit fixtures are synthetic and do not qualify a
runtime image or database execution.

The complete local suite result is recorded in
[mpr-191-local-suite.json](validation/mpr-191-local-suite.json). It includes all
30 non-E2E Go packages, including the controller and webhook API-server suites
and the new scoped live-validation command.
All passed. Local API-server assets were Kubernetes 1.35.0, with Go 1.26.10.
The final focused run recorded 61 passing test/subtest events and zero failures.

| Check | Result | What it establishes |
| --- | --- | --- |
| Runtime/schema gate and transition tests | Passed | Complete/partial rollout, current template/ownership, probe failure, missing/mismatched endpoints, stale schema condition, failure states, TTL reuse, generation updates, input-change invalidation and persistence-conflict handling |
| Parent and event unit tests | Passed | Missing/stale/nonready child handling, stable parent transitions, endpoint/Pod mapping and predicates, namespace isolation, generated/Helm RBAC equivalence and read-only grants |
| Production controllers on a local API server without Ray CRDs | Passed | Job completion, Deployment status, endpoint-only loss/recovery, Pod-only readiness loss/recovery, ReplicaSet ownership loss/recovery, EndpointSlice deletion/recreation, Service selector repair and parent propagation |
| Stable healthy reconciliation on a local API server | Passed | A fresh healthy-Pod observation causes no AIService, AIPlatform or Deployment resource-version churn for longer than the retry interval; controller-owned Deployment revision is preserved |
| Existing non-E2E regression suite | Passed, 30 packages | Includes candidate rendering, profile/placement, other feature handlers, webhook admission, storage and controller tests |
| `go vet ./...` and formatting/diff checks | Passed | Static checks and clean patch formatting |
| RBAC generation and packaging check | Passed | Source markers generate the checked-in permissions; source and Helm rules are equivalent |
| Helm lint | Passed, zero failed charts | Chart lint only; dependency archives are absent locally, producing the existing missing-dependencies warning |

The API-server test uses the production AIPlatform and AIService controller
registration, handlers, predicates and event mappings. It supplies workload
status because a local API server has no Deployment controller, EndpointSlice
controller or kubelet. Each loss/recovery must propagate before the five-second
fallback; the separate watch test retains the existing no-retry event-delivery
proof for Job and Deployment updates. Actual probe execution and live
Service-controller behavior are covered by the subsequent cluster test.

Reproduction of the complete local unit/API-server suite:

```sh
export KUBEBUILDER_ASSETS="$PWD/bin/k8s/1.35.0-darwin-arm64"
go test $(go list ./... | grep -v /e2e) -count=1 -coverprofile=/tmp/mpr191-cover.out -timeout=300s
go vet ./...
bin/controller-gen rbac:roleName=manager-role paths=./...
helm lint helm-chart/splunk-ai-operator
```

Use the appropriate local API-server asset directory on other platforms. These
test servers need permission to bind loopback ports. The initial restricted
controller/webhook runs could not bind ports; reruns with that permission
passed. Offline module mode was used for the recorded Go tests with an existing
writable Go cache.

Full `make manifests` also regenerates pre-existing CRD documentation/order
differences from the current dependency types. Those unrelated CRD changes were
excluded; the RBAC-only generator output is reproducible for this change.

## Live validation and limits

All nine scoped cases passed on **agentruntime-dev**, with real schema execution,
two desired runtime replicas, kubelet probes, EndpointSlices and both production
controllers. The candidate used a test ServiceAccount with the generated source
permissions, restricted to its disposable namespace. Schema failure, probe
failure and selector/backend loss all propagated to AIPlatform; recovery,
recorded-success reuse and restart/no-op stability passed.

The disposable namespace/database, test policies/RBAC, temporary prerequisite
CRD fields, webhook exclusions and authorized ingress rules were removed.
Original CRD specs, webhook selectors, operator configuration and security-group
rules were verified restored. The shared runtime retained its Deployment
generation and Pod identities; it, its parent, the shared operator and all three
nodes were Ready afterward.

These checks do not establish product invocation, continuous PostgreSQL health,
fullfeature GPU behavior, installation/upgrade qualification or OS coverage.
MPR-194 retains product request-path assertions. This validation does not imply
Jira closure or a merged change.
