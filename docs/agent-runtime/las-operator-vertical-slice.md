# LAS operator vertical slice

The `agentruntime` feature now reconciles the standalone LangGraph Agent Server (LAS). There is no new AIService feature name. An AIPlatform `features[]` entry still uses `name: agentruntime` and its existing `provider` identity; the AIPlatform controller copies its feature fields to the child AIService.

## Configuration

Use `licenseSecretRef`, `postgresSecretRef`, and `redisSecretRef` on the `agentruntime` feature. All three Secrets must already exist in the AIService namespace. The operator checks that they contain nonempty `langgraph_cloud_license_key`, `postgres_connection_url`, and `redis_connection_url` keys, respectively. See `config/samples/ai_v1_aiplatform_agentruntime.yaml` for a sample using the POC Secrets in `ai-platform`.

AgentRuntime does not accept feature `env`; runtime configuration is provided through the LAS block and referenced Secrets. Shared feature `env` remains available to non-AgentRuntime features. LAS runs one API replica and one queue replica. The API CPU request is `250m` for the POC cluster's available capacity; its memory request and limits and the queue resources use chart defaults.

The operator embeds and verifies the upstream `langgraph-cloud` chart version `0.3.4` (SHA256 `31dab99c9b1c6ddfb8672a4a9a287a044d50bb628665c641eb2b1170833df953`). It pins the POC sample image `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/las-sample-agent:las-poc-20260930-115209`, enables the separate queue worker, uses the three existing Secrets, disables in-chart PostgreSQL, Redis, and MongoDB, sets an internal API Service, and sets the three API probe timeouts to five seconds. AIService `imagePullSecrets` flow into chart `images.imagePullSecrets` when configured. The sample image and chart are operator build inputs in this slice; changing either requires a new operator build.

## Reconciliation and deletion

Each AIService maps to one deterministic `las-...` Helm release in its namespace. The release Secret carries the AIService UID. The operator refuses to upgrade or uninstall a release with a different owner UID. It compares the installed chart and values before upgrading, checks the API and queue Deployments, and rechecks every 30 seconds. A missing Deployment triggers a Helm upgrade to restore it. `Ready` condition reasons distinguish installation, upgrade, dependency, Helm, workload, and cleanup failures. Kubernetes events report install/upgrade progress and outcomes.

After both LAS Deployments are ready, the operator preserves the former AIService Service name and port `8080`, pointing it at LAS API Pods. It then deletes only resources with this AIService as their controller owner from the old direct-managed implementation. It leaves the three external Secrets and their PostgreSQL and Redis services alone. The AIService finalizer is added before Helm installation and removes only its UID-owned release during deletion; Kubernetes garbage collection removes the AIService-owned compatibility Service. The Helm chart's own API Service remains available on port `80`.

The compatibility Service preserves the network address, not the former runtime's HTTP protocol. Callers need to use LAS endpoints and payloads.

## Deployment sequence used

1. Install the updated AIPlatform and AIService CRDs, webhook, RBAC, and operator image built from this branch.
2. Ensure the LAS sample image remains pullable in `ai-platform` and the three dependency Secrets are present with the required keys. The POC's node-level ECR token was short lived; provide a durable pull Secret through AIPlatform image configuration or refresh node authorization before rollout.
3. Apply the updated AIPlatform `agentruntime` feature references. The child AIService will retain the same name and provider while switching to LAS.
4. Watch the child AIService `Ready` condition and events, the UID-owned Helm release, and the API and queue Deployments. Application protocol validation and other POC tests are a separate follow-up.

This implementation was deployed from branch `las-poc` on 2026-10-05. The existing AIService now owns a deployed LAS Helm release; see `las-operator-rollout-20261005.md` for image digests, the installer profile, rollout findings, and live evidence. The earlier manual `las-poc` Helm release was independent and was uninstalled at the user's request before the lifecycle checks recorded in `las-operator-lifecycle-validation-20261005.md`.

The complete POC outcome, remaining gaps, and implementation gates are summarized in the [handoff](las-ai-tier-poc-handoff-20261005.md) and [post-POC implementation plan](las-ai-tier-implementation-plan-post-poc.md).
