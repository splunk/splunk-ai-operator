# Agent Runtime candidate refresh procedure

MPR-188 tracks the integration candidates used by Agent Launchpad. The set contains four container images: Agent Runtime base, Launchpad carrier/provider, schema setup, and SLIM. The MLTK provider is delivered by the Launchpad carrier image. AITK is a Splunk app, not a container image, and its app/build and endpoint contract are recorded separately.

The current manifest is [`config/agent-runtime/candidate-manifest.yaml`](../../config/agent-runtime/candidate-manifest.yaml). Its values include historical handoff evidence and the SLIM candidate tag supplied for MPR-188. Story-owner review excludes image provenance, owners, architectures, and current registry digest checks from this story. Previously recorded digests remain historical evidence. Remaining contract fields marked pending must stay visible until resolved.

The reviewed loader selection uses `AGENT_MODULE=agentcore_operations.loader:MLTKAgentLoader`. Schema setup uses `/schema.sql` from `ai/ai-agent-runtime` commit `5a91e680`, applied with the PostgreSQL client tools. The checkpoint Secret is `mltk-postgres-conn`, type `Opaque`, with `DATABASE_URL`, `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD`, and `PG_DBNAME`; both Runtime and schema setup consume it through `checkpointDbSecretRef`. The matching example is in [`config/samples/ai_v1_aiplatform_agentruntime.yaml`](../../config/samples/ai_v1_aiplatform_agentruntime.yaml).

Runtime's prefix is `/system/ai-agent-runtime/v1`. AITK uses `/tenant/slim-api/v1alpha1/agent/agent_runtime` on SLIM; its source is `ML/mltk/mltk`, branch `pmitra/aitk_app_runtime`. Its package version is `6.2.0`; packaging generates the build number and writes `githash`. The PostgreSQL URL and supplied fields work directly, with no additional TLS mode or certificate configuration.

## Refresh steps

1. Record the candidate image references and their service/config contracts. For AITK, record the Splunk app version/build and its endpoint/config contract. Image provenance, owners, architectures, and current registry digest verification are outside this story's reviewed scope.
2. Save the preceding manifest before editing. Record new values in the next manifest revision and append a history item with date, source of the confirmed contract, changed fields, and reason. For every changed image, retain its old reference under that history item's `previousImages.<component>` key. Clear stale image digest metadata or retain it explicitly as historical evidence. Keep unresolved required fields explicitly marked pending; the validator rejects such fields before rendering.
3. Compare ports, service routes, required environment and Secret keys, TLS/auth mode, endpoint paths, and the schema migration entry point with the existing contract. Startup, liveness, and readiness probes use the shared `GET /health` API on Runtime and SLIM. Retain database checks during schema setup and Runtime startup; periodic PostgreSQL connectivity checks are not required. Record the contract revision and flag missing required details.
4. Re-render the operator configuration against the updated candidate record and run the focused local contract/render checks. Confirm SLIM receives both `PLATFORM_URL` and `AI_TIER_AGENT_RUNTIME_URL`; `PLATFORM_URL` is derived from the Ray endpoint for `fullfeature` and is empty for `cpuOnly`. The story owner confirms the selected SLIM image accepts `AI_TIER_AGENT_RUNTIME_URL`; the previously inspected SLIM commit does not define this candidate's contract.
5. Record the validation command/scope, outcome, and any defect or build reference next to the new history entry. A passing local render/contract check establishes compatibility evidence only; it does not qualify the candidate for product release.

Final immutable release selection and certification remain in MPR-216. Image mirroring and execution are covered by MPR-187.

## Local validation and rendering

Run from the repository root:

```sh
go run ./cmd/candidate-contract --profile cpuOnly > /tmp/mpr188-cpuOnly.yaml
go run ./cmd/candidate-contract --profile fullfeature > /tmp/mpr188-fullfeature.yaml
```

The command validates the record against the supported contract and selected compatibility pair, projects its images/module into the operator's existing `RELATED_IMAGE_*` / `RELATED_AGENT_RUNTIME_MODULE_PROVIDER_*` inputs, and runs the real Runtime/SLIM reconcilers against an in-memory client. The result includes the candidate revision, operator environment, API prefix, AITK dependency, and rendered Deployments/Services/schema Job. It validates all four images, service routing/selectors, ports, shared health probes, loader selection, Secret references, and both SLIM variables. `ray-service-origin` and `agentruntime-service-origin` in the candidate bindings identify those derivations; `PLATFORM_URL` is explicitly empty for `cpuOnly`.

The schema Job's completion is simulated to exercise the dependent render stages. Synthetic Secret values stay inside the fixture and are excluded from output. The tool loads no kubeconfig and contacts no cluster, registry, PostgreSQL server, or product endpoint.

Validate a candidate refresh using the saved preceding record:

```sh
go run ./cmd/candidate-contract \
  --manifest config/agent-runtime/testdata/candidate-refresh.yaml \
  --previous config/agent-runtime/candidate-manifest.yaml \
  --profile cpuOnly > /tmp/mpr188-refreshed.yaml
```

The checked-in revision 6 fixture is synthetic: it changes SLIM's tag, preserves revision 5's image reference/history, and exercises the same path as a later externally supplied build. It is not an image to deploy. Repeat with `--profile fullfeature` for the other profile. For an actual refresh, use the real updated record with the preceding snapshot in `--previous`; no Go change is needed for an image-only fix. Changing a base or carrier may require a new pending matrix record/pair. An unlisted pair remains visible as `unlisted` under the matrix's documentation-only policy; a blocked or mismatched selected pair fails validation.

Run the focused regression checks:

```sh
go test ./internal/candidatecontract ./cmd/candidate-contract \
  ./pkg/ai/features/slim ./pkg/ai/features/agentruntime ./pkg/ai -count=1
go vet ./internal/candidatecontract ./cmd/candidate-contract \
  ./pkg/ai/features/slim ./pkg/ai/features/agentruntime
```

Append the outcome and report reference to the new history entry after validation. Initial and refresh results are recorded in [mpr-188-validation.md](mpr-188-validation.md) and its machine-readable evidence file. The compatibility matrix remains pending product qualification.
