# MPR-188 candidate contract

**Status:** all required candidate inputs captured in manifest revision 5 (2026-11-18) and [MPR-188](https://splunk.atlassian.net/browse/MPR-188); the saved Jira description was read back and verified. Local acceptance evidence is in [mpr-188-validation.md](mpr-188-validation.md). Code review and merge remain before delivery is finalized.

This draft combines the two Agent Runtime ERDs, the historical deployment handoff already captured for MPR-188, source in the relevant repositories, and the story owner's review decisions. The ERDs are Draft documents; source observations remain distinct from the agreed candidate behavior.

## Confirmed review decisions

- All HTTP services in this candidate set use `GET /health` for startup, liveness, and readiness probes. The operator already targets `/health` on port 8080 for Runtime and SLIM, so no probe implementation change is required.
- Periodic PostgreSQL connectivity checks are not required. Keep schema setup and Runtime startup database initialization checks.
- The supplied SLIM image accepts `AI_TIER_AGENT_RUNTIME_URL`. Disregard the previously inspected SLIM commit when determining this candidate's environment contract.
- Supply SLIM both `PLATFORM_URL` and `AI_TIER_AGENT_RUNTIME_URL`. Propagate the resolved `AIService.spec.aiPlatformUrl` using the existing URL normalization. The current CPU-only system naturally leaves this URL empty; that observation is not a profile constraint. Preserve a supplied URL under either profile.
- Skip image provenance, owners, architectures, and current registry digest checks for all images in MPR-188. Previously recorded historical digests may remain in the manifest; these metadata items are not open requirements for this story.
- Schema setup comes from `ai/ai-agent-runtime` commit `5a91e680` (full SHA `5a91e68028ebfa9503963a983c967104fb6a8e92`). Its Dockerfile and SQL confirm the `/schema.sql` entry point.
- The schema setup image is `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/agent-runtime-schema-setup:202609171357-39c5803f686e`. All four candidate image references are now recorded.
- Loader selection requires `AGENT_MODULE=agentcore_operations.loader:MLTKAgentLoader`.
- The checkpoint Secret is `mltk-postgres-conn`, type `Opaque`, with the six data keys `DATABASE_URL`, `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD`, and `PG_DBNAME`. The existing sample matches the supplied contract.
- The Runtime API prefix is `/system/ai-agent-runtime/v1`, confirmed by the story owner.
- The PostgreSQL URL and structured fields work directly. No additional PostgreSQL TLS mode or certificate configuration is required.
- The authoritative AITK source is `ML/mltk/mltk`, branch `pmitra/aitk_app_runtime`; the inspected snapshot is `82ee65f54f210887740c3d594cc5609de92d39f2`.

## Candidate inventory

| Component | Candidate value | Evidence and review status |
|---|---|---|
| Agent Runtime base | `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/agent-runtime:202609221052-eae3b33005a5` | From the older deployment handoff. Current Runtime source exposes application port 8080 and metrics port 9090. |
| Launchpad carrier / MLTK provider | `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/agent-runtime-provider-mltk:202609221517-f4466f2ccd` | The inspected [`loader.py`](https://cd.splunkdev.com/ML/mltk/agent-launchpad/-/blob/f4466f2ccde5a850194a1bccf436ebf799000a5f/Agent-Builder-POC/agentcore_operations/loader.py) defines `MLTKAgentLoader`; the carrier Dockerfile resolves and copies the wheel payload to `/payload/` and contains no service process. `provider: mltk` and the loader entry point are confirmed by the story owner. |
| Schema setup | `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/agent-runtime-schema-setup:202609171357-39c5803f686e` | Image and source commit `5a91e680` confirmed by the story owner. The [`schema-setup Dockerfile at that commit`](https://cd.splunkdev.com/ai/ai-agent-runtime/-/blob/5a91e68028ebfa9503963a983c967104fb6a8e92/cicd/docker/schema-setup/Dockerfile) uses `postgres:16-alpine`, copies `agent-runtime/db/schema.sql` to `/schema.sql`, waits with `pg_isready`, then applies SQL with `psql`. The operator invokes the same SQL path. |
| SLIM API | `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/slim-api:es-runtime-sync-create-ready-21d4bf15f-20261116-amd64` | Updated image selected by the story owner. Accepts `AI_TIER_AGENT_RUNTIME_URL`; health probes use `/health`. The previous November 12 candidate is retained in manifest history. |
| AITK | Splunk app `Splunk_ML_Toolkit`, label `AI Toolkit`, version `6.2.0` | From the authoritative branch's `package.json` and packaging code. Build number is generated at packaging time; the package's `githash` records the source commit. |

## Runtime and provider contract

The story owner confirms `provider: mltk` and the following loader selection contract:

```text
AGENT_MODULE=agentcore_operations.loader:MLTKAgentLoader
```

This is the only environment variable required for loader selection in the selected candidate. The operator already supplies `AGENT_MODULE`; loader selection is resolved. The inspected Launchpad source also contains this loader. The earlier question about `AGENT_LOADERS` and an additional logical agent ID is closed by the story owner's clarification.

The two ERDs describe Agent Runtime as a ClusterIP service called by SLIM, with PostgreSQL-backed checkpointing. The newer integration ERD says AITK-to-SLIM-to-Runtime traffic uses the internal service route, app-level JWT/Authorization is not required between SLIM and Runtime, and NetworkPolicy restricts access. It also describes credentials as Kubernetes Secret references and fail-closed behavior when a required Secret is missing or malformed.

Current Runtime source provides these implementation facts:

- Application port defaults to `8080`; metrics use `9090`.
- API routes use the confirmed `/system/ai-agent-runtime/v1` prefix. This supersedes the generic ERD's proposed `/v1` path.
- Startup loads configured loaders/catalog, initializes PostgreSQL and the checkpointer, and fails startup on an exception. PostgreSQL schema verification requires `checkpoints`, `checkpoint_blobs`, and `checkpoint_writes`.
- Current Runtime source contains password and AWS IAM modes, PostgreSQL connection settings, and TLS defaults. See [`config.py`](https://cd.splunkdev.com/ai/ai-agent-runtime/-/blob/main/agent-runtime/agent_runtime/config.py) and [`postgres_provider.py`](https://cd.splunkdev.com/ai/ai-agent-runtime/-/blob/main/agent-runtime/agent_runtime/utils/postgres_provider.py). The selected candidate uses the password credentials and six-key Secret contract confirmed below; the other modes do not add required keys to that contract.

## Health, readiness, and PostgreSQL connectivity

The agreed contract uses the same `GET /health` API for startup, liveness, and readiness on Runtime and SLIM. The operator already implements this in [`agentruntime/impl.go`](../../pkg/ai/features/agentruntime/impl.go) and [`slim/impl.go`](../../pkg/ai/features/slim/impl.go), using port 8080. The carrier is an init-container payload and schema setup is a Job; their completion is checked through Kubernetes container/Job status rather than an HTTP probe.

Current Runtime [`app.py`](https://cd.splunkdev.com/ai/ai-agent-runtime/-/blob/main/agent-runtime/agent_runtime/app.py) implements `/health` and initializes/verifies PostgreSQL at startup. Schema setup also waits for PostgreSQL before applying SQL. These startup checks remain part of the contract. Periodic PostgreSQL connectivity checks and database queries on health requests are not required by the story owner. The separate Runtime Helm chart's `/service/health` default and the app's additional `/service/ready` endpoint do not change the agreed operator probe target.

## SLIM variables and profile behavior

The operator change for this story supplies both variables to SLIM:

| Variable | Confirmed value |
|---|---|
| `PLATFORM_URL` | Propagate the resolved `AIService.spec.aiPlatformUrl`, stripping a trailing slash and `/ai-platform-models/v1`. Its value is not constrained by the profile. |
| `AI_TIER_AGENT_RUNTIME_URL` | Supply the AIPlatform Agent Runtime feature/provider Service URL for both profiles. |

The ERDs support the CPU/full-feature split: Runtime remains CPU in both; full-feature adds GPU model service/Ray-related integration, while CPU-only does not require Ray and can use the private/BYO LLM path. `AI_TIER_AGENT_RUNTIME_URL` supplies the Runtime Service origin (`http://<service>.<namespace>.svc.<cluster-domain>:8080`); the downstream API prefix is `/system/ai-agent-runtime/v1`.

Use `AI_TIER_AGENT_RUNTIME_URL` as the reviewed SLIM candidate contract. The ERD's no-app-level-auth statement applies specifically to the SLIM-to-Runtime hop; AITK and SLIM still handle caller authorization.

## AITK application contract

The story owner designated [ML/mltk/mltk, branch pmitra/aitk_app_runtime](https://cd.splunkdev.com/ML/mltk/mltk/-/tree/pmitra/aitk_app_runtime) as authoritative. At snapshot `82ee65f54f210887740c3d594cc5609de92d39f2`:

- `package.json` identifies `Splunk_ML_Toolkit`, label `AI Toolkit`, version `6.2.0`.
- `gulpfile.js` substitutes those values into `resources/default/app.conf`; `@build@` becomes `new Date().valueOf()` (Unix milliseconds at packaging time). The package includes `githash`. The source candidate's build policy is fully specified; no packaged build number is invented or required to select this branch candidate.
- Connections > AI Tier saves the shared endpoint via authenticated `GET`, `POST`, and `DELETE /services/mltk/ai_tier_settings`. Config capability checks apply.
- The configured endpoint is a SLIM URL ending in `/tenant/slim-api/v1alpha1`. Here `tenant` is the literal path accepted by AITK's endpoint validator. Existing chat/models, chat/completions, and ai/infer suffixes are normalized by the URL helper.
- The AI Tier agent route appends `/agent/agent_runtime`; AITK sends a Bearer interactive token to SLIM. Route metadata records `ES_AGENT_RUNTIME` / `es-agent-runtime`.
- Existing agents retain their saved runtime backend. New-agent routing also considers Cloud Connect activation, so a saved AI Tier endpoint alone does not change the route of an existing AWS AgentCore agent.

## Schema setup and database values

At the supplied [commit `5a91e680`](https://cd.splunkdev.com/ai/ai-agent-runtime/-/commit/5a91e68028ebfa9503963a983c967104fb6a8e92), [`agent-runtime/db/schema.sql`](https://cd.splunkdev.com/ai/ai-agent-runtime/-/blob/5a91e68028ebfa9503963a983c967104fb6a8e92/agent-runtime/db/schema.sql) replaces the earlier Flyway migrations with a rerunnable SQL file. It creates `checkpoint_migrations`, `checkpoints`, `checkpoint_blobs`, and `checkpoint_writes`, adds the associated indexes/date columns, and seeds migration records. The Dockerfile copies this file to `/schema.sql` in a `postgres:16-alpine` image, providing the PostgreSQL client tools used during setup.

The operator overrides the setup image command with `sh -c` to wait with `pg_isready` and apply `/schema.sql` with `psql -v ON_ERROR_STOP=1`. Both the Job and Runtime import the Secret named by `checkpointDbSecretRef` in the AIService namespace. The confirmed example is already present in [`config/samples/ai_v1_aiplatform_agentruntime.yaml`](../../config/samples/ai_v1_aiplatform_agentruntime.yaml):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mltk-postgres-conn
type: Opaque
stringData:
  DATABASE_URL: postgresql://user:password@postgres.default.svc.cluster.local:5432/checkpoints
  PG_HOST: postgres.default.svc.cluster.local
  PG_PORT: "5432"
  PG_USER: user
  PG_PASSWORD: password
  PG_DBNAME: checkpoints
```

Set `checkpointDbSecretRef: mltk-postgres-conn` for the feature. The URI and structured values describe the same database and password credentials. The example values are placeholders; supply the installation's actual values while retaining all six data keys.

The Secret contract and password authentication are resolved. Per story-owner confirmation, the URL and supplied fields work directly; no additional PostgreSQL TLS mode/certificate settings are required. The candidate renderer adds no such fields. Existing optional schema command support for `PGSSLMODE`/`PG_SSLMODE` does not add a requirement to this contract.

## ERD statements retained as design intent

- Two deployment profiles: `cpuOnly` and `fullfeature`; Runtime is CPU in both, while full-feature uses GPU-backed model serving.
- AITK calls SLIM; SLIM calls the Agent Runtime ClusterIP service; Runtime loads carrier payload and persists checkpoint state in customer-managed PostgreSQL.
- Missing required Secret/config should fail closed; NetworkPolicy limits ingress/egress; candidate images should be pinned and mirrored by digest/architecture for customer installation.
- Candidate set is four container images (Runtime base, Launchpad carrier/provider, schema setup, SLIM) plus the AITK Splunk app.

The newer ERD still labels provider and `AGENT_MODULE` as TBD. That statement is superseded by the story owner's explicit `mltk` and loader values, and the inspected Launchpad source corroborates the loader. The ERDs are Draft. Their digest/architecture publication policy belongs to later image mirroring/release qualification; the story owner has excluded those checks from MPR-188.

## Completion and remaining work

There are no missing required contract inputs. The versioned candidate, compatibility record, refresh fixture/procedure, and repeatable local validation/render tool cover all five MPR-188 criteria; see [the validation record](mpr-188-validation.md) for the evidence and limits. Code review and merge remain delivery steps. Product invocation, image mirroring, and release qualification remain in their separate stories.

## Sources

- [Agent-Runtime AI-Tier Integration ERD](https://splunk.atlassian.net/wiki/spaces/PROD/pages/1080352114691/Agent-Runtime+AI-Tier+Integration) (Draft; integration/profile/security intent).
- [ERD part 1: Decoupling ES Agent Runtime](https://splunk.atlassian.net/wiki/spaces/PROD/pages/1080324333078/ERD+part+1+Decoupling+ES+Agent+Runtime+A+Generic+Execution+Layer+for+LangGraph+Agents) (Draft; API, configuration and Runtime design intent).
- [`ai/ai-agent-runtime`](https://cd.splunkdev.com/ai/ai-agent-runtime) current `main` source.
- Schema setup [Dockerfile](https://cd.splunkdev.com/ai/ai-agent-runtime/-/blob/5a91e68028ebfa9503963a983c967104fb6a8e92/cicd/docker/schema-setup/Dockerfile) and [SQL](https://cd.splunkdev.com/ai/ai-agent-runtime/-/blob/5a91e68028ebfa9503963a983c967104fb6a8e92/agent-runtime/db/schema.sql) at the story-owner supplied commit `5a91e680`.
- [`ML/mltk/agent-launchpad`](https://cd.splunkdev.com/ML/mltk/agent-launchpad), loader/carrier source linked above.
- [`sparta/aie/splunk-mltk/slim-api`](https://cd.splunkdev.com/sparta/aie/splunk-mltk/slim-api), previously inspected `feature/las` route only; environment contract superseded by story-owner confirmation.
- AITK [package.json](https://cd.splunkdev.com/ML/mltk/mltk/-/blob/82ee65f54f210887740c3d594cc5609de92d39f2/package.json), [gulpfile.js](https://cd.splunkdev.com/ML/mltk/mltk/-/blob/82ee65f54f210887740c3d594cc5609de92d39f2/gulpfile.js), [AI Tier settings](https://cd.splunkdev.com/ML/mltk/mltk/-/blob/82ee65f54f210887740c3d594cc5609de92d39f2/ml-spl/bin/rest_handlers/ai_tier_settings.py), [URL helpers](https://cd.splunkdev.com/ML/mltk/mltk/-/blob/82ee65f54f210887740c3d594cc5609de92d39f2/ml-spl/bin/util/ai_commander_util.py), and [runtime routing](https://cd.splunkdev.com/ML/mltk/mltk/-/blob/82ee65f54f210887740c3d594cc5609de92d39f2/ml-spl/bin/agent_manager/runtime_routing.py).
- Historical deployment handoff and story-owner clarifications already recorded in `config/agent-runtime/candidate-manifest.yaml`.
- Local operator implementation in `pkg/ai/features/agentruntime/impl.go` and `pkg/ai/features/slim/impl.go`, plus `docs/agent-runtime/live-cluster-rebase-validation-2026-11-11.md` for the historical structured PostgreSQL key requirement.
