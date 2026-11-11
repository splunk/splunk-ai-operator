# Agent Runtime rebase: live cluster validation (2026-11-11)

## Scope and baseline

- Branch: `ai-agent-runtime`; validation started from rebased commit `6c3c744d1d39244368cb4e6280144a40b40c52ca` on `origin/main` `322135e5b24c64affff418147984eef4fadf3f78`.
- Cluster: `agentruntime-dev`, k0s on three existing RHEL 9.8 nodes (one controller and two CPU workers). No GPU node was added.
- Before this validation, the operator used ECR image `ml-platform/splunk-ai-operator@sha256:53e922709e381ed71b51b4a8ee08eea16374e4f73e3c2b811f947bb7c49f9208` (`mpr-44-route-84ac5ec-20261103`).
- The platform had `slim` and `agentruntime` features. The Agent Runtime Service selected the LAS Helm API server. The LAS Helm release was `las-agentruntime-dev-ai-p-eb88ba0f`.
- The existing checkpoint Secret `mltk-postgres-conn` has a `DATABASE_URL` key; its value is deliberately omitted here.

## Changes applied to the development cluster

1. Backed up the live AI CRDs, operator Deployment, and AI custom resources to a restricted directory on the installer host.
2. Built the exact rebased HEAD as a local `linux/amd64` image and imported it on the existing three nodes. After fixing the schema Job issue described below, rebuilt the working tree as `localhost/splunk-ai-operator:rebased-6c3c744-sslfix` (`sha256:577f633331f835d57dcd8494b511054a5f9a14ef8ca34ba6fb1e34df1e335eea`), imported it on those same nodes, and selected it in the operator Deployment using `imagePullPolicy: Never`. No Git or registry push was made.
3. Applied the rebased AIPlatform and AIService CRDs using server-side apply under the existing `kubectl` field manager.
4. Replaced the AIPlatform feature list with the MLTK `agentruntime` feature, `runtimeVersion: v2.0.0`, one-to-two replicas, and `checkpointDbSecretRef: mltk-postgres-conn`. The operator removed the old SLIM AIService and its workload.
5. Fixed the schema Job's handling of an absent SSL mode in the local operator source. The original Job exported an empty `PGSSLMODE`, which caused `pg_isready` to return `no attempt` against the reachable database. The rebuilt operator recreated the Job, which completed in four seconds.
6. Refreshed the expired ECR pull Secret in `ai-platform` so the existing Agent Runtime images could be pulled. Enriched the existing checkpoint Secret with `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD`, and `PG_DBNAME` parsed from its existing `DATABASE_URL`. The currently deployed base image requires those structured keys. Set `PG_SSLMODE=disable` in this development cluster because its PostgreSQL endpoint does not support SSL. No credential values were logged or saved in this report.
7. Once the replacement Agent Runtime Service had a ready endpoint, uninstalled the LAS Helm release with history retained. Removed the stale, unowned schema Pod from the old deployment. The LAS API server and queue Deployments, Services, and HPA are gone. LAS auth, PostgreSQL, and Redis Secrets remain for rollback; they are not active deployments.
8. Revoked the temporary EC2 Instance Connect Endpoint SSH ingress rule and verified the rule is absent, then closed the local tunnel.

## Verified outcome

- Operator Deployment: 1/1 ready with the rebuilt local image. Agent Runtime Deployment: 1/1 ready and available with the last-used ECR base image. Its Service selects the new Agent Runtime labels and has a ready EndpointSlice. The HPA and ServiceMonitor were created. All three pre-existing nodes remain; no GPU node was added.
- The latest schema setup Jobs completed successfully. AIPlatform and AIService report `Ready=True`.
- From inside the installer host, a port-forward to the Agent Runtime Service returned HTTP 200 with `{"status":"ok"}` from `/health` and HTTP 200 with 11,684 bytes from `/metrics`, both before and after LAS removal.
- The LAS Helm release `las-agentruntime-dev-ai-p-eb88ba0f` reports `uninstalled`. A final namespace inventory showed only the new Agent Runtime Deployment/Service/HPA for that route, with no LAS Deployment/Service/HPA.
- This establishes startup, schema setup, Service routing, readiness, and health/metrics availability on this CPU-only cluster. It does not establish an end-to-end MLTK request or a live cluster rollout on a GPU-capable topology.

## Image inputs used for this validation

The existing operator environment refers to these ECR images, which were verified present by digest:

| Component | Tag | Digest |
| --- | --- | --- |
| Agent Runtime base | `202609221052-eae3b33005a5` | `sha256:ddedf855e6751625d1eae206793fe3cd14d72c6934609fe2c0641c9a8eae5219` |
| Schema setup | `202609171357-39c5803f686e` | `sha256:5877fcbdea301b945af0be55eeb33bcb30c93b0e3b1906a58be779680650d987` |
| MLTK provider | `202609221517-f4466f2ccd` | `sha256:d73301133cf67ce561bd04b52a5f7947134cad955c18bba1ab2ea0537c0319f5` |

## Known gap and local source changes

- The existing RayService is still not ready: four L40S worker Pods remain Pending, and its model applications lack required artifacts. The stable Ray head Service named in the AIService platform URL is absent. Ray-dependent MLTK requests remain blocked and were not exercised. The user chose startup and API health validation first and prohibited adding GPU nodes.
- `pkg/ai/features/agentruntime/impl.go` now leaves `PGSSLMODE` unset when no setting exists and honors the standard `PGSSLMODE` over `PG_SSLMODE` when both are supplied. A shell-level regression test covers the unset and precedence cases. `go test ./pkg/ai/features/agentruntime -count=1` passed.
- An earlier `make test` run refreshed `api/v1/zz_generated.deepcopy.go` to use the cert-manager `IssuerRef` deep-copy method; this generated change is recorded with the validation fixes.
- The installer now creates checkpoint Secrets with both `DATABASE_URL` and structured `PG_*` keys; the Agent Runtime development profile explicitly sets `pgSslMode: disable` for its non-SSL database. The focused installer checks passed (13/13). Against a clean export of rebased HEAD, the full installer suite had 246 passes and 12 failures; the working tree had 258 passes and the same 12 failures, so this patch added no full-suite regression. The existing failures concern mutable-image validation and AIP-4614 manifest cases.
- The operator image contains the schema fix from this local work. It is present only on these nodes and the local machine. A later node replacement or cluster recreation will need this image made available on the replacement nodes. No registry or Git push was performed.
