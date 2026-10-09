# LAS operator rollout evidence — 2026-10-05

Target: `agentruntime-dev` k0s cluster, namespace `ai-platform`, installer `ec2-user@52.12.115.104`. The existing `agentruntime` AIService is being migrated to LAS; the separate manual `las-poc` Helm release is left alone. Secret values are not included here.

Later update: the user requested removal of the manual `las-poc` release for lifecycle testing. It was uninstalled on 2026-10-05 after this rollout record was captured; see `las-operator-lifecycle-validation-20261005.md`. The operator-managed primary release stayed deployed.

The subsequent live deletion and multi-instance isolation checks are recorded in [Plan 2 isolation validation](las-operator-isolation-validation-20261005.md). Both disposable releases were uninstalled and their dependencies cleaned up; the primary release remained Ready.

## 1. Source and focused checks — passed

- Branch: `las-poc`, base commit `483a832`, with the LAS implementation and existing working-tree changes.
- `go test ./pkg/ai/features/agentruntime ./internal/webhook/v1 ./internal/controller` passed for all three packages.
- `./tools/cluster_setup/test_k0s_cluster_with_stack.sh` reported **163 passed, 0 failed, 0 skipped**.
- `bash -n tools/cluster_setup/k0s_cluster_with_stack.sh` and `git diff --check` passed.

## 2. Operator image — passed

- AWS identity was verified as account `658391232643`, role `splunkcloud_account_admin`; ECR repository `ml-platform/splunk-ai-operator` exists in `us-west-2`.
- The Dockerfile build stopped at `go mod download` because Docker Desktop ran out of disk space. The operator was instead cross compiled on the host as a statically linked `linux/amd64` ELF and packaged with the same distroless runtime files, configuration, license, user, and entrypoint as the main Dockerfile.
- Compiled manager SHA256: `694f5c62afc6ad56b30bbc75cc3d70597a8e8db6b5fdf9a6a3d153e83a2fdfc0`.
- Image: `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/splunk-ai-operator:las-poc-20261005-111613-483a832`.
- Local image ID: `sha256:ba0e9e262585e07072cc79f39aa58c767f9e0f01f4e15aaf98e8166baef25b7f`; inspected platform `linux/amd64`.
- Docker push succeeded. ECR `describe-images` returned digest `sha256:46d7e0a21d926ce14613aec87fe61357ce1096ad1f6c371cdf2175a802463528`, tag `las-poc-20261005-111613-483a832`, and size `50,479,345` bytes.
- Two follow-up images were built and pushed after rollout findings. The **final deployed image** is `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/splunk-ai-operator:las-poc-20261005-114954-483a832`. Its manager binary SHA256 is `cc2938595b538c5b693b712afab7688066bc0a32f5444cd7bdc5fd61cdd81b49`. Local image ID `sha256:c2ab7721b31798db3961b6d0785be2ba9646b9f82f3328d9470ce37d3d280835` is `linux/amd64`. ECR returned digest `sha256:f7b98f37ab2571af598cc13c3698f0d3dc575d6c29b5f96b9f586753708103bc` and size `50,484,186` bytes. The final running Pod's image ID matches that digest.
- One final packaging attempt briefly failed to resolve `gcr.io`; a retry using the cached base image succeeded. This did not change the deployed image contents.

## 3. Testing profile and prerequisites — passed

- Updated `tools/cluster_setup/k0s-cluster-config-agentruntime.yaml` to use the new image and existing `las-auth`, `las-postgres`, and `las-redis` Secrets. Removed the legacy runtime image and checkpoint settings. The installer now emits the three LAS fields and checks existing Secret keys.
- Regenerated `tools/cluster_setup/artifacts.yaml`; staged it, the updated installer script, profile, and both CRDs on the installer. Backed up the active installer config, then refreshed only its deployment image and AIPlatform feature settings from the updated profile.
- Installer `validate` completed with no errors. Its one warning was that `images.registry` is empty; the operator image is an explicit ECR URL.
- Existing Secrets had the required keys: `las-auth/langgraph_cloud_license_key`, `las-postgres/postgres_connection_url`, `las-redis/redis_connection_url`. The two `ecr-registry-secret` pull Secrets were refreshed in `splunk-ai-operator-system` and `ai-platform` using a fresh token from the verified local AWS profile. The installer's own AWS token was expired, so it was not used.

## 4. Cluster schema and staged AIPlatform configuration — passed

- Both AIPlatform and AIService CRDs were server-side applied and reached `Established`; live schemas exposed `licenseSecretRef`, `postgresSecretRef`, and `redisSecretRef`.
- The existing AIPlatform feature was patched to add the three LAS references while retaining the legacy fields for the old operator during the handover. Readback showed AIPlatform generation `27` and the three exact Secret names.
- Before the image change, operator Deployment generation `42` was `1/1 Ready` on the old image. The existing AIService UID was `39598b65-89e6-4b32-ba5b-547dc9902036`; its legacy status reported `PostgresSchemaSetupReady=False` because the schema Job was still running. The separate manual `las-poc` release was `deployed`, revision `2`.

## 5. New operator rollout — passed

- Set the operator Deployment's `manager` image to the ECR tag above. `kubectl rollout status` reported a successful rollout; Deployment generation `43` had `1/1 Ready` and observed generation `43`.
- The new Pod's image ID was `...@sha256:46d7e0a21d926ce14613aec87fe61357ce1096ad1f6c371cdf2175a802463528`, matching ECR.
- The existing AIService kept its UID, received the three LAS references at generation `21417`, and gained finalizer `ai.splunk.com/aiservice-protect`. Its `Ready` condition moved to `Unknown/Installing`, naming release `las-agentruntime-dev-ai-p-eb88ba0f` and chart `0.3.4`.

## 6. LAS release and workload readiness — passed after two fixes

1. The first Helm install reported `HelmInstallFailed`: the operator service account could not list `apps/replicasets` in `ai-platform`, which Helm's wait logic needs. Atomic install removed the failed release. The AIService recorded the exact error as `Ready=False`. Added `get/list/watch` on ReplicaSets to the controller RBAC marker and Helm RBAC template, regenerated `artifacts.yaml`, applied the exact generated ClusterRole, and verified `kubectl auth can-i list` and `watch` both returned `yes` for the operator service account.
2. The next attempt created the queue and API Deployments. Queue reached `1/1 Ready`; the API Pod remained Pending because every node had less than the chart's default 1 CPU request free (`FailedScheduling: 0/3 nodes ... Insufficient cpu`). Helm's five-minute wait expired and its atomic rollback removed that attempt. The operator surfaced the timeout through `Ready=False / HelmInstallFailed` and a Warning event. The POC values now set only `apiServer.deployment.resources.requests.cpu: 250m`; API memory request remains `2Gi`, and limits remain 2 CPU/4 GiB. The updated image was pushed and deployed.
3. The retry installed release `las-agentruntime-dev-ai-p-eb88ba0f`, chart `langgraph-cloud-0.3.4`, revision `1`, status `deployed`. Both API and queue Deployments reached `1/1 Ready`. The API Pod scheduled on `ip-10-0-34-19.splunkcorp.com`, and the queue Pod on `ip-10-0-34-28.splunkcorp.com`.
4. Helm's release Secret `sh.helm.release.v1.las-agentruntime-dev-ai-p-eb88ba0f.v1` has label `ai.splunk.com/aiservice-uid=39598b65-89e6-4b32-ba5b-547dc9902036`, matching the unchanged AIService UID. `helm get values` showed chart `0.3.4` configuration using `las-auth`, `las-postgres`, `las-redis`, queue enabled, the POC sample image, and API startup/readiness/liveness timeout values `5/5/5` seconds. The live API Deployment also showed these probe timeouts, `250m` CPU/`2Gi` memory requests, and `ecr-registry-secret` for image pulls.
5. `helm get manifest` contains two Deployments, two ServiceAccounts, and the API Service. It contains no chart-managed PostgreSQL, Redis, or MongoDB workload or Secret. The three external dependency Secrets still exist.
6. The operator was initially unable to patch repeated Kubernetes events. Added `create/patch/update` on core Events to the RBAC marker and Helm template, regenerated and applied the role, and verified the service account could create and patch Events. The AIService event history then showed `LASInstalling` at 11:45:30 UTC, `LASInstalled` at 11:45:45 UTC, and `LASReady` at 11:45:47 UTC. The earlier Helm timeout Warning remains in event history, as expected.

## 7. Compatibility Service and application request — passed

- The original AIService-owned Service `agentruntime-dev-ai-platform-agentruntime-mltk-svc` remains on port `8080`, now targeting port `8000` on the LAS API Pod. Its endpoint resolved to ready API Pod IP `10.244.132.43` at the time of the check.
- From a temporary installer-local port-forward of that Service, `GET /ok` returned `{"ok":true}`. Created thread `01a10be5-e257-7463-bfba-cddad30b8504`; `POST /threads/{id}/runs/wait` with graph `echo` returned `LAS sample agent received: operator managed LAS compatibility service check`. `GET /threads/{id}/state` returned the same saved request and response. The port-forward was stopped after the check.
- The old AIService-owned direct-runtime Deployment and running schema Job were removed. Listing Deployments, Jobs, ConfigMaps, Services, ServiceAccounts, and HPAs by the AIService controller UID returned only the intended compatibility Service. The separate manual `las-poc` Helm release and unrelated workloads were left alone.

## 8. AIPlatform status migration — passed

- After LAS became ready, AIPlatform still showed `AIServiceStatusReady=False` because the existing AIService retained `PostgresSchemaSetupReady=False` from the removed legacy Job. Updated LAS condition handling to retain only the LAS `Ready` condition; a focused fake-client test verifies the stale condition is removed. Built and deployed the final image above.
- The live AIPlatform `agentruntime` feature was simplified to LAS configuration and Secret references. Its generation is `28`; the child AIService kept the same UID, reached generation `21418`, and has `licenseSecretRef: las-auth`, `postgresSecretRef: las-postgres`, and `redisSecretRef: las-redis`.
- Final operator Deployment generation `45` is observed and `1/1 Available`. The Pod image ID matches final ECR digest `sha256:f7b98f37ab2571af598cc13c3698f0d3dc575d6c29b5f96b9f586753708103bc`. AIService has only `Ready=True / LASReady`, observed generation `21418`, and finalizer `ai.splunk.com/aiservice-protect`. AIPlatform `AIServiceReady=True` and `AIServiceStatusReady=True`; no AIPlatform condition is false.

## 9. Final checks and scope

- `go test ./pkg/ai/features/agentruntime ./pkg/ai ./internal/webhook/v1 ./internal/controller` passed. The LAS tests include legacy-condition removal and owner-scoped cleanup that preserves the compatibility Service and unrelated objects. Installer script tests reported **163 passed, 0 failed, 0 skipped**. Shell syntax and `git diff --check` passed.
- The installer’s active `my-k0s-config.yaml` and checked-in testing profile both point to the final ECR image. `k0s_cluster_with_stack.sh validate`, run from `~/cluster_setup`, passed with one existing warning: `images.registry` is empty while the operator uses an explicit ECR image URL. An earlier invocation from the installer's home directory failed only because relative manifest paths were resolved there; rerunning from `~/cluster_setup` passed.
- The operator finalizer's Helm uninstall path was not exercised against the live AIService because that would delete the working POC release. Its owner-scoped cleanup helper was unit tested; a live deletion test remains for a disposable AIService. The license verifier's transaction-level result also remains unobserved; runtime acceptance and its limitation are recorded in `las-ai-tier-manual-validation.md`.
