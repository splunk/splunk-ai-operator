# MPR-202 validation record

Scope: deleting an AgentRuntime feature removes only operator-owned objects and keeps
customer data. The rules and the inventory are in
[ownership-and-deletion.md](ownership-and-deletion.md). Design source: the
Agent-Runtime / AI-Tier Integration ERD (version 8), FR-17 and §14.4.3.

## What was wrong before

Each of these was reproduced on a real API server (envtest) before the fix:

1. **A customer ServiceAccount was adopted, then deleted.** A ServiceAccount named in
   `features[].serviceAccountName` was given the AIService as its controller, so garbage
   collection would delete it with the AIService. That happened if it already existed,
   and also if the operator created it first, for example before the customer's GitOps
   applied it, or for another AIService that shares the name. A user-named ServiceAccount
   is now always customer-managed. If missing, it is created without an owner reference,
   and an owner reference left by an earlier build is removed.
2. **Same-named objects were overwritten and left behind.** An existing ConfigMap,
   Certificate, Service, HPA or ServiceMonitor under a name the feature uses was
   silently accepted:
   - the ConfigMap's content was replaced;
   - none of them was given an owner reference, so they would survive the deletion as
     orphans.

   A same-named Deployment failed with only a generic error.
3. **The mTLS Secret was left behind.** cert-manager writes `<name>-tls` without an
   owner, so it outlived the AIService.
4. **The finalizer handlers were dead code.** No code adds the `aiservice-protect` or
   `aiplatform-protect` finalizer (builds from 2025-08 did), but their handlers remained.
   The platform's handler deleted the AIServices itself and held the platform until they
   were gone.
5. **Pruning matched by name only.** Removing a feature matched the platform's children
   by owner name, so it also deleted an AIService left by an earlier platform of the same
   name.

## Completion criteria

| # | Criterion | Implementation | Evidence |
|---|---|---|---|
| 1 | Ownership inventory of operator-owned objects, and separately the external and customer-managed ones | [ownership-and-deletion.md](ownership-and-deletion.md), "Inventory" | `TestOwnership/every_object_the_feature_creates_is_owned,...` checks the inventory against what garbage collection would remove |
| 2 | Deleting the CR removes each feature-owned object and no shared one; orphans from an interrupted reconcile follow an explicit rule, without label-only deletion | Every object is created owned (`common.ClaimOrRefuse`). A same-named object that is not ours is refused, by UID (`OwnershipConflict`). Nothing is deleted by label. Pruning matches by UID | `TestOwnership` (inventory, same-named objects, partial install); `TestClaimOrRefuse`; `TestReconcileFeatures_PrunesOnlyItsOwnRemovedFeatures` |
| 3 | PostgreSQL and checkpoint data stay readable; referenced Secrets, PVCs and model artifacts stay; no finalizer blocks deletion | The checkpoint Secret, user-named Secrets and ServiceAccounts are never owned. The runtime uses no PVC. No finalizer is added, and a legacy one is released at once | `TestOwnership` (checkpoint Secret and similarly named object unchanged; the AIService is gone on delete); controller specs "releases the finalizer an early build added", "never adds a finalizer", "keeps another controller's finalizer"; checkpoint readback on the cluster (below) |
| 4 | Repeated deletion and reconciliation are idempotent; a missing owned object counts as removed; an API failure is surfaced and retried without deleting customer objects | Stage errors set the condition and are retried. A missing owned object is recreated | `TestOwnership` (idempotent passes leave every resourceVersion unchanged; a deleted ConfigMap is recreated; an injected `ServiceUnavailable` on the Deployment is surfaced, the retry completes, and no delete is issued); a repeated reconcile of a deleted AIService is not an error |
| 5 | Both profiles follow the same rules; hosted-model resources only where the operator owns their lifecycle | The same resource set in both profiles. Hosted-model resources belong to the AIPlatform, not the feature | `TestOwnership` runs the inventory case for `cpuOnly` and for `fullfeature` |
| 6 | Tests: normal deletion, partial install, retry after API failure, a similarly named customer object, data preservation; the cleanup inventory and expected residual data documented for the runbook | As above. The runbook sections are "Deleting, and what remains" and "Checking a deletion" | the tests above; [ownership-and-deletion.md](ownership-and-deletion.md) |

Envtest runs a real API server but no garbage collector. The tests therefore check the
set garbage collection removes: every object whose owner references name the
AIService's UID. They also check that the AIService itself is deleted at once. The
cascade itself needs a cluster.

## Tests

| Check | Result |
|---|---|
| New and updated Go tests | 24 tests and subtests in `common`, `agentruntime` (envtest) and `pkg/ai`, and 5 controller specs |
| Mutation checks | 32 deliberate breakages of the new rules (including making the helpers' default path strict, which would change SAIA), each caught by a failing test. One first-run miss was a real test gap (the user-named ServiceAccount path swallowing an API failure) and was closed |
| PR #291 review (Codex) | an operator-named TLS Secret that the user later names in `mtls.secretName` kept the AIService's owner reference and would have been deleted with it. It is now released (other owner references kept); envtest reproduces the sequence; 2 more mutations, each caught |
| Independent review | no correctness bug. Its five minor points were addressed: a user-named ServiceAccount is now never owned; a same-named schema Job is reported as `OwnershipConflict`; SAIA's conflict event names the object; the TLS-Secret rule is documented; a vacuous assertion was fixed |
| Module | `go build ./...` and `go vet`; all 24 non-e2e packages pass; race detector clean on `common`, `agentruntime`, `saia` and `pkg/ai` |
| Controller suite | passes repeatedly. Under the race detector, some spec orders report a race on the base branch too (seeds 8, 13 and 16 there): older specs register types in the shared client-go scheme (`scheme.Scheme`) while an envtest manager's event recorder reads it. The new specs use a private scheme and add no such write. The existing ones are left for a separate fix |

## Cluster evidence

Run on fullfeature-dev on 2026-11-24 with the branch's operator, CRDs and ClusterRole; the captured
output is in [validation/mpr-202-cluster.txt](validation/mpr-202-cluster.txt). Every change was reverted
and each restored object compared with its backup.

| Criterion | What was shown |
|---|---|
| 1, 2 | On a cpuOnly platform the runtime owned exactly the inventory's objects; removing the features removed those and SLIM's, and nothing else. A customer ServiceAccount, a ConfigMap whose name extends the runtime's, the checkpoint and pull Secrets and PostgreSQL stayed at their resourceVersions |
| 2 | A same-named customer ServiceAccount and ConfigMap were refused with `OwnershipConflict` naming them, left unchanged, and the install recovered once the customer removed them. Killing the operator 0.3 s into an install left only owned objects, and the new operator completed it |
| 3 | Marker checkpoint rows read back with identical checksums after the feature removal, after deleting two fullfeature runtimes, and after deleting four platforms. The live platform's checkpoint counts were unchanged throughout. Objects with the 2025-08 finalizers were deleted within a second |
| 4 | Removing the HPA permission failed only that stage (`ReconcileFailed`, Forbidden) with nothing deleted; once restored, the install completed. Repeating the removal, and deleting the gone AIService, were no-ops |
| 5 | Two standalone runtimes against the live fullfeature platform: the same rules. The operator-generated TLS Secret was owned and removed with its AIService; the user-named one, and the Issuer, stayed |
| — | The live fullfeature platform stayed Ready under the branch operator, and its runtime's objects were all owned |

Retested on 2026-11-25 on `ai-agent-runtime` 9d4a0cd (which includes PR #290) with the events
RBAC rule added: every scenario passed again, no event was rejected, and the
`OwnershipConflict` Warning appeared with the operator's own ClusterRole (section 12 of the
captured output).

### Findings on the cluster (pre-existing, not caused by this change)

- **The operator could not record events on AIServices** (fixed in this change). Its ClusterRole had no `events`
  permission. The only grant is in the leader-election Role, in the operator's own namespace. So
  every event it emits elsewhere is rejected ("events is forbidden"): `InvalidSpec` and the new
  `OwnershipConflict` alike. With the permission granted for the test, the `OwnershipConflict`
  Warning appeared as documented. The condition, which is what the runbook relies on, is
  unaffected.
- **The newer operator rewrote the live SAIA and SLIM Deployments constantly** (fixed by PR #290; caused by 955dd11, see section 11). That is about
  1,180 generation bumps in 3 minutes, and the base `ai-agent-runtime` build does the same as
  this branch (A/B on the live platform). Templates, replicas and readiness were unaffected.

## Not done yet

- **PodDisruptionBudget and NetworkPolicy** do not exist yet (MPR-205). Built with the
  same helper, they will follow the same rule; their deletion tests belong with them.

## Follow-ups outside this story

- SLIM and SAIA are unchanged. Neither the ERD nor MPR-202 covers their ownership: the
  story is scoped to the AgentRuntime feature's own objects. The shared ServiceAccount
  and Certificate helpers therefore apply the new rule only when the caller asks
  (`RefuseUnowned`). SAIA still adopts an unowned same-named ServiceAccount or
  Certificate, as before; a test pins that. SLIM and SAIA also create their other
  objects the way the AgentRuntime feature used to (owner reference set before
  `CreateOrUpdate`), so a same-named customer object may be overwritten there. If that
  is wanted, it needs its own ticket.
- Turning mTLS or metrics off later leaves the earlier Certificate or ServiceMonitor
  until the AIService is deleted. For the ServiceMonitor, that is MPR-208's first
  criterion.
