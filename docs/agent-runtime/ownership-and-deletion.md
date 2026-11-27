# AgentRuntime resource ownership and deletion (MPR-202)

Deleting an AgentRuntime feature removes only the objects the operator created for it.
Customer-managed data is kept: the PostgreSQL database and its checkpoint records,
referenced Secrets, PVCs, model artifacts and shared AI Tier infrastructure. The same
rules apply to both `cpuOnly` and `fullfeature`.

Design source: the [Agent-Runtime / AI-Tier Integration ERD](https://splunk.atlassian.net/wiki/spaces/PROD/pages/1080352114691/Agent-Runtime+AI-Tier+Integration),
FR-17 and §14.4.3: "Deleting the feature removes only operator-owned Deployment,
Service, ConfigMap, schema Job, HPA, certificate, ServiceMonitor, PDB, and NetworkPolicy
objects as applicable. Customer-managed PostgreSQL data, checkpoint records, referenced
Secrets, model artifacts, and shared AI Tier infrastructure remain." Evidence:
[mpr-202-validation.md](mpr-202-validation.md).

## Ownership rule

1. **Owned objects carry an owner reference.** Every object the feature creates gets the
   AgentRuntime AIService as its controller, in the same write that creates it. Deleting
   the AIService therefore lets Kubernetes garbage collection remove them. A
   reconciliation that is interrupted part way can leave only owned objects behind.
2. **Existing objects are never adopted.** If an object already exists under a name the
   feature uses, and this AIService (matched by UID) does not control it, the operator
   does not adopt, rewrite or delete it. The stage fails with reason
   `OwnershipConflict`, and the message names the object; see "Troubleshooting".
3. **Nothing is deleted by label.** The operator selects nothing for deletion by label or
   name pattern. Removal is always garbage collection through owner references.
4. **No finalizer.** The operator adds no finalizer and runs no cleanup on deletion, so
   an unavailable PostgreSQL server, registry or other dependency cannot hold a deletion.
   Builds from 2025-08 added `ai.splunk.com/aiservice-protect` and
   `ai.splunk.com/aiplatform-protect`. An object that still carries one is released at
   once when it is deleted.
5. **Failures are retried, never answered with a delete.** A Kubernetes API failure fails
   the stage, sets its condition to `False` and is retried. A missing owned object is
   recreated, and an owned object that is already gone counts as removed.

## Inventory

`<svc>` is the AgentRuntime AIService's name. For a platform-managed feature that is
`<platform>-agentruntime-<provider>`, for example `ai-agentruntime-mltk`.

### Operator-owned: removed with the AIService

| Object | Name | Created when |
|---|---|---|
| ServiceAccount | `<svc>-sa` | when `serviceAccountName` is unset, or names `<svc>-sa` |
| ConfigMap | `<svc>-agentruntime-config` | always |
| cert-manager Certificate | `<svc>-agentruntime-cert` | `mtls.enabled` with `termination: operator` |
| TLS Secret | `<svc>-tls` | with the Certificate, when `mtls.secretName` is unset. cert-manager writes it; the operator then adds an owner reference |
| Schema Job (and its Pods) | `<svc>-schema-<input hash>` | always; a finished Job also expires through its 24 hour TTL |
| Deployment (and its ReplicaSets and Pods) | `<svc>-agentruntime-deployment` | after schema success |
| Service | `<svc>-svc` | after schema success |
| HorizontalPodAutoscaler | `<svc>-agentruntime-hpa` | after schema success |
| ServiceMonitor | `<svc>-agentruntime-metrics` | `metrics.enabled` |
| PodDisruptionBudget | `<svc>-agentruntime-pdb` | after schema success |
| NetworkPolicy | `<svc>-network`, `<svc>-schema-network` | for every AgentRuntime service, before schema setup |

The TLS Secret is recognised by the `cert-manager.io/certificate-name` annotation that
cert-manager writes. A Secret you created yourself under the generated name `<svc>-tls`
would already have been overwritten by cert-manager. If you need to keep such a Secret,
set `mtls.secretName` to it instead: a Secret you name is never owned. Naming the
operator-generated Secret this way also keeps it: the operator removes its owner reference
on the next pass, so the Secret survives the AIService.

When the feature is platform-managed, the AIService itself is owned by its AIPlatform.
Removing the feature from `AIPlatform.spec.features` deletes only that feature's
AIService, and only one this platform controls (matched by UID).

The resource set is the same in both profiles. The profile changes only what the runtime
waits for: `fullfeature` waits for the hosted-model platform. The hosted-model
resources (KubeRay `RayService`, the model-serving and vector-database workloads) belong
to the AIPlatform, not to the AgentRuntime feature. Removing the feature leaves them.

### Customer-managed or shared: never removed with the feature

| Item | Why it stays |
|---|---|
| PostgreSQL database and checkpoint records | external and customer-managed; the operator connects only through the schema Job, which applies the schema and never drops data |
| Checkpoint Secret (`checkpointDbSecretRef`) | referenced, never owned. This includes one the installer created from `aiPlatform.agentRuntime.checkpointSecrets`: delete it yourself once nothing uses it |
| A user-named mTLS Secret (`mtls.secretName`) and the cert-manager Issuer | named or managed by the user |
| A ServiceAccount the user named in `serviceAccountName` | customer-managed: used if it exists, and created without an owner reference if not, so another AIService or your own tooling can rely on it. Delete it yourself when nothing uses it |
| Registry pull Secrets (`images.imagePullSecrets`) | created by the installer for the whole namespace |
| PVCs | the runtime uses none (its scratch space is an `emptyDir`); none is deleted |
| Model artifacts and the object store (`taskVolume`, `objectStorage`) | outside the cluster |
| Shared AI Tier infrastructure: the AIPlatform, SLIM, the operator, CRDs, cert-manager, the namespace | not owned by the feature |
| Objects whose names only resemble the feature's (for example `<svc>-agentruntime-config-backup`) | never selected by name |

## Deleting, and what remains

| Action | Removed | Remains |
|---|---|---|
| Remove the `agentruntime` entry from `AIPlatform.spec.features` | that AIService and everything in the operator-owned table above | everything in the customer-managed table. Under `cpuOnly`, SLIM routes to AgentRuntime, so the webhook refuses a platform with `slim` and no `agentruntime`: remove `slim` in the same change, or delete the platform |
| Delete a standalone AgentRuntime AIService | the same | the same |
| Delete the AIPlatform | every AIService of the platform (SLIM included) and their owned objects, and the platform's hosted-model resources | everything in the customer-managed table except the AIPlatform itself |
| `k0s_cluster_with_stack.sh delete` | the whole cluster (`k0s reset` on every node): every in-cluster object, Secrets included | only what lives outside the cluster: the external PostgreSQL database and the object store |

### Checking a deletion

Before deleting, record what garbage collection will remove (the objects whose owner
references name the AIService) and what must remain:

```sh
NS=ai-platform SVC=ai-agentruntime-mltk
UID=$(kubectl get aiservice "$SVC" -n "$NS" -o jsonpath='{.metadata.uid}')
kubectl get serviceaccount,configmap,secret,job,deployment,service,hpa,servicemonitor,certificate,poddisruptionbudget,networkpolicy -n "$NS" -o json \
  | jq -r --arg uid "$UID" '.items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid)) | "\(.kind)/\(.metadata.name)"'
```

After the deletion, that command finds nothing within a few seconds (Pods finish
terminating shortly after). Every item in the customer-managed table is still present.
The checkpoint records read back unchanged: query them with the application's usual
PostgreSQL client and the checkpoint Secret's credentials. The operator logs no Secret
value.

## Troubleshooting

**`OwnershipConflict`.** A stage condition (for example `AgentRuntimeConfigMapReady`) and
`Ready` are `False`, with a message like:

```
ConfigMap ai-platform/ai-agentruntime-mltk-agentruntime-config already exists and is not managed by this AIService; it was left unchanged: rename or remove it
```

The operator also records a Warning event with the same text on the AIService
(`kubectl describe aiservice <name>`). Two causes:
- **A customer object uses the name.** Rename or remove it, and the next pass creates
  the operator's own.
- **It was left by an earlier AIService of the same name that was just deleted.**
  Garbage collection removes it shortly, and the retry then succeeds without action.

## Upgrading

Objects created by earlier operator builds are already owned, so an upgrade causes no
conflict. Earlier builds also adopted, or created and owned, the ServiceAccount named in
`features[].serviceAccountName`. After the upgrade the operator removes its own owner
reference from that ServiceAccount on the next pass, keeping any other, so the
ServiceAccount is no longer deleted with the AIService.
