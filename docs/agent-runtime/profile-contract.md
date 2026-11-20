# AI Tier deployment profile contract

Status: MPR-184. Consumers: MPR-186 (placement and resources), MPR-190 and
MPR-192 (cpuOnly and fullfeature pipeline jobs).

This document is the handoff contract for the deployment profile. MPR-184
defines the profile API, validation, defaults and installer rendering. It does
not decide node placement, resource budgets or mirroring, and it does not run an
installation.

## Canonical names

| Value | Meaning |
|---|---|
| `cpuOnly` | No local GPU-hosted model. Runtime pods on CPU capacity; models and tools reached over the customer's BYO LLM endpoint and Splunk MCP. No Ray, Weaviate, GPU node or GPU driver. |
| `fullfeature` | Runtime pods on CPU capacity; supplied hosted-model workloads on GPU capacity through Ray. |

`fullfeature` is the canonical name and no third profile exists. The legacy
value `full` is accepted and always resolves to `fullfeature`. Documentation and
examples must use the canonical names. In the installer configuration an empty `aiPlatform.profile` is ignored (treated as omitted); a CR with `spec.profile: ""` is rejected by the CRD enum, so omit the field instead.

The selector is `aiPlatform.profile` in the installer configuration and
`spec.profile` on the `AIPlatform` CR. The Go helpers are
`AIPlatformProfile.Resolve()`, `AIPlatformSpec.ResolvedProfile()` and
`AIPlatformSpec.ValidateProfile()` in `api/v1/aiplatform_profile.go`.

## Compatibility rule for existing configurations

An omitted profile and the legacy `full` both resolve to
`fullfeature` and keep the pre-profile behaviour:

- Operator: an `AIPlatform` without `spec.profile` behaves exactly as before.
  The field is never written back by defaulting, so omitted stays omitted.
- Installer: only the value itself is validated (an unknown value is still
  rejected). None of the Launchpad requirements below apply, and no `profile:`
  line is rendered into the CR. Existing unrelated AI Tier v1.0 configurations,
  including ones that already spell `full`, stay valid unchanged.
- Only the canonical names `cpuOnly` and `fullfeature` opt in to the Agent
  Launchpad path, whose required inputs are listed below.

The resolved profile is published on the CR as `status.profile` (and the
`Profile` print column), so the compatibility rule never has to be re-derived.

## Required values when the profile opts in (`cpuOnly` or `fullfeature`)

| Input | Installer key |
|---|---|
| Features | `aiPlatform.features` contains `slim` and `agentruntime` |
| Runtime base image | `images.agentRuntime.baseImage` |
| Schema image | `images.agentRuntime.schemaSetupImage` |
| Provider/carrier image, one per agentruntime feature | `images.agentRuntime.providerImages.<provider>` |
| Provider loader module, one per provider (`package.module:ClassName`, the `AGENT_MODULE` value; `agentcore_operations.loader:MLTKAgentLoader` for the `mltk` provider) | `images.agentRuntime.providerModules.<provider>` |
| Provider key (DNS-1123 label, at most 63 characters; unique per feature) | `aiPlatform.features[].provider` |
| Checkpoint Secret (external reference) | `aiPlatform.features[].checkpointDbSecretRef` |
| SLIM image | `images.slim.apiImage` |

Image references and the snapshot manifest must not contain whitespace, quotes
or backslashes. Because the installer splices feature fields into the CR, each
`aiPlatform.features[]` field is checked as a safe scalar: `name` is one of the
CRD enum values (`saia`, `seca`, `slim`, `agentruntime`); `provider` is a
DNS-1123 label; `serviceAccountName` and `checkpointDbSecretRef` are Kubernetes
names, i.e. DNS-1123 subdomains (dot-separated lowercase labels of at most 63
characters, at most 253 overall, so `a..b` and `a.-b` are rejected); `version`
and `runtimeVersion` are version strings; `minReplicas` and `maxReplicas` are
positive integers with min at most max; and `targetCPUUtilization` is an integer
from 1 to 100. Rejected values are not echoed in error messages: an unsupported profile name is shown only when it is a short plain name (otherwise "(value not shown)"), the scale-factor message omits the value, and duplicate-feature messages name only the position. `aiPlatform.scaleFactor`, when set, must be a
YAML integer of at least 1 (the same rule `install` enforces). Duplicate feature
identities (`agentruntime` is keyed by provider) are rejected, as in the webhook.

AITK is the Splunk app `Splunk_ML_Toolkit` (label "AI Toolkit", version 6.2.0),
installed on Splunk. It is not a container image, and nothing in cluster setup
depends on it: the installer has no AITK setting, `render-profile` renders none,
and neither the image snapshot nor the air-gap bundle includes it.

Optional: `images.snapshotManifest`, the per-run image snapshot manifest
(MPR-187 output). It is passed through to the rendered values unchanged. A
final release digest is not required.

Provider key and loader module are settled by the MPR-188 candidate contract
(`config/agent-runtime/candidate-manifest.yaml`, the authority for image
references, ports, probes and the Secret contract; see
`docs/agent-runtime/candidate-contract-review.md`): the provider key is `mltk`,
`AGENT_MODULE` is `agentcore_operations.loader:MLTKAgentLoader`, and that is the
only loader selection required (no `AGENT_LOADERS` map). The checkpoint Secret
the examples reference is `mltk-postgres-conn`, a Secret of type `Opaque` in the
AIService namespace with the keys `DATABASE_URL`, `PG_HOST`, `PG_PORT`, `PG_USER`,
`PG_PASSWORD` and `PG_DBNAME`; the installer never creates or changes it. Image
references in the examples stay sanitized placeholders; the immutable digests of
the candidate images are resolved by the mirror step (MPR-187).

## Rules by profile

`cpuOnly` contradictions are enforced in two places. Both give field-specific
errors.

Operator and webhook (`spec.*`):

- features `saia` or `seca`
- a `slim` feature without an `agentruntime` feature (under `cpuOnly` SLIM routes
  to AgentRuntime, so it would otherwise fail on every reconcile)
- GPU settings: `gpuInstanceType`, `defaultAcceleratorType`, `gpuScheduler`,
  `workerGroupConfig`, `scaleFactor` above 1
- Ray, Weaviate or SAIA image overrides, `vectorDB` storage, enabled ingress
- any sidecar (`envoy`, `otel`, `prometheusOperator`)

Installer (config keys), which does not render the CR-only sections above, so it
checks only what would otherwise take effect:

- features `saia` or `seca`; `aiPlatform.defaultAcceleratorType`; `scaleFactor`
  above 1
- `nodes.gpuWorkers` other than 0 (omitted counts as 0), `components.nvidia: true`,
  `components.kuberay` anything other than an explicit `false`,
  `storage.modelStaging.enabled` anything other than an explicit `false`
- `images.ray.*`, `images.weaviate.image` and `images.saia.*`, which `install`
  would otherwise inject into the operator Deployment as `RELATED_IMAGE_*`
- any sidecar flag that is not an explicit `false` (every sidecar flag must be a real YAML boolean; a typo such as `"ture"` is rejected rather than read as false)

For `cpuOnly` the installer also skips the air-gap model-artifact verification
(there is no local model to verify) and never prompts for model staging or an
accelerator.

`fullfeature` is rejected with `components.kuberay: false`, since model serving
uses Ray. When KubeRay and the AIPlatform CR are enabled it also requires
`images.ray.headImage`, `images.ray.workerImage` and `images.weaviate.image`, so
that `validate` and `render-profile` agree with `install`. CPU/GPU placement and
resource budgets are described in "Placement and resource budgets" below.

CRD defaulting: the CRD defaults `sidecars.otel` and `sidecars.prometheusOperator`
to `true`, and `storage.vectorDB.size` to `50Gi`, whenever the parent object is
present. The webhook re-marshals the spec into a JSON patch, and Go writes empty
value-typed structs, so a spec that omits `storage` and `sidecars` would come
back as `storage: {vectorDB: {}}` and `sidecars: {}` and then pick up those
defaults. For `cpuOnly` that would make every CR invalid, so
`AIPlatformSpec.MarshalJSON` leaves empty `storage` and `sidecars` out of a
`cpuOnly` spec (verified against a real API server in the envtest specs). Other
profiles marshal exactly as before and keep their defaults. A `cpuOnly` CR may
therefore omit `sidecars` and `storage.vectorDB` entirely, or set every sidecar
flag to `false`. A partial object such as `sidecars: {envoy: false}` or
`storage: {vectorDB: {}}` is present, so it picks up the defaults and is
rejected; the error message says so.

The webhook rejects changing the profile of an existing platform between
`cpuOnly` and `fullfeature`, in both directions (an omitted profile and legacy
`full` count as `fullfeature`). The profile decides which infrastructure exists,
so there is no supported live migration and no partial conversion is possible.
Staying on the same profile, including spelling it differently, is fine.

An unknown or malformed profile is never converted into the other profile.

## Output path and format

```
CONFIG_FILE=<config.yaml> tools/ai-tier-cluster-setup/k0s_cluster_with_stack.sh \
  render-profile [--output FILE]
```

- Writes one YAML document to `FILE`; default is `profile-values.generated.yaml`
  next to the config file. The installer tees stdout into its session log, so
  the document is never written to stdout.
- On any problem it writes no file and exits nonzero.
- Deterministic: the same input produces byte-identical output (no timestamps,
  stable key order). It contains references and names only, never Secret
  contents.
- Schema (version 1): `profile.{configured,effective,explicit}`,
  `aiPlatformSpec.profile`, `images.{snapshotManifest,operator,agentRuntime.{base,schemaSetup,providers.<name>,modules.<name>},slim,aitk}`
  (registry-qualified, as the operator will receive them), `features`,
  `checkpointDbSecretRefs`, `components.*`, `nodes.gpuWorkers`. All strings are
  YAML-escaped.
- `components.*` is the effective set the installer will act on, not the raw
  flags: for example `nvidia` is `false` when there are no GPU workers whatever
  `components.nvidia` says.
- `aiPlatformSpec.profile` is the value rendered into the CR: the canonical name
  when the profile is explicit, `""` (field omitted) otherwise.

`validate` runs the same checks, and `install` runs them before any cluster
change. For `cluster.airgap: true` they also run before the artifact staging step
begins (when `yq` is available on the install host), so a bad profile fails in
seconds instead of after the download. A configuration that cannot be loaded at
all is reported as such, not as a profile error.

## Failure codes

Problems are printed one per line as `[CODE] field: message`. Messages name
fields and never echo credentials. The process exit code is 1 for any problem.

| Code | Meaning |
|---|---|
| `PROFILE_UNSUPPORTED` | Unknown profile name (the supported names are listed in the message). |
| `PROFILE_INVALID_VALUE` | Wrong value shape: not a string, or whitespace in an image reference. |
| `PROFILE_CONFLICT` | A setting contradicts the selected profile. |
| `PROFILE_MISSING_REFERENCE` | A required feature, image or Secret reference is absent. |

The operator and webhook report profile validity and the `cpuOnly`
contradictions as Kubernetes field errors (`spec.profile`: Unsupported value;
`spec.<field>`: Forbidden). The required-reference rules (features, image
references, provider, checkpoint Secret) and the scale-factor and
duplicate-provider checks run in the installer; the webhook and the agentruntime
handler enforce the equivalent provider and Secret rules at admission and
reconcile.

## Examples

- `tools/ai-tier-cluster-setup/examples/profile-cpuonly.yaml`
- `tools/ai-tier-cluster-setup/examples/profile-fullfeature.yaml`

Golden outputs (rendered values and the applied `AIPlatform` CR) are in
`tools/ai-tier-cluster-setup/testdata/profile/`. Regenerate with
`UPDATE_GOLDEN=1 tools/ai-tier-cluster-setup/test_k0s_cluster_with_stack.sh`.

## Reconcile behaviour per profile

Added by MPR-229.

| | `cpuOnly` | `fullfeature` (and omitted, legacy `full`) |
|---|---|---|
| Platform stages | Validate, AIService, AIServiceStatus | unchanged: Validate, Sidecars, rayAutoscalerRBAC, RayService, ActiveClusterScale, WeaviateDatabase, Ingress, the three status stages, AIService, AIServiceStatus |
| Ray, Weaviate, ingress, sidecar monitoring | none created, none reported | unchanged |
| Operator without KubeRay | starts and reconciles: the `RayService` and `RayCluster` watches are registered only when those APIs exist | unchanged (watches registered when KubeRay is installed) |
| AgentRuntime handler | no wait for Ray, no platform URL required; no `PLATFORM_URL`, no `VECTOR_DB_URL` | waits for Ray, derives the platform URL, sets `PLATFORM_URL` |
| SLIM handler | no wait for Ray; `PLATFORM_URL` carries the resolved `spec.aiPlatformUrl` (empty when none is supplied; a supplied value is kept); `AI_TIER_AGENT_RUNTIME_URL` = the AgentRuntime Service URL | waits for Ray; `PLATFORM_URL` = the Ray serve root; `AI_TIER_AGENT_RUNTIME_URL` = the AgentRuntime Service URL when the platform has an `agentruntime` feature, otherwise empty |
| AIService `vectorDbUrl` | may be empty (no vector database) | required, as before |

SLIM always receives both `PLATFORM_URL` and `AI_TIER_AGENT_RUNTIME_URL`, under
both profiles (MPR-188). `PLATFORM_URL` is the resolved `spec.aiPlatformUrl` with the
existing trailing-slash and `/ai-platform-models/v1` normalization applied,
independent of the profile; an empty value under `cpuOnly` is just what that
platform has to give, not a rule, and a supplied non-empty value is preserved.
`AI_TIER_AGENT_RUNTIME_URL` is the origin of the AgentRuntime Service,
`http://<service>.<namespace>.svc.<cluster-domain>:8080`; the Runtime's own API
prefix `/system/ai-agent-runtime/v1` is not part of it, and no application JWT or
Authorization header is used on this internal hop.

The URL is `spec.agentRuntimeUrl` when set, otherwise it is derived from the
platform's `agentruntime` feature, with the Service name and port defined once
(`agentruntime.FeatureServiceURL`). The platform controller also sets
`spec.agentRuntimeUrl` explicitly for `cpuOnly`. There is no way to choose between
several `agentruntime` features, so the SLIM handler refuses to guess (it reports
"multiple agentruntime features") and `cpuOnly` admission rejects a `slim` feature
alongside more than one `agentruntime` feature. An empty `clusterDomain` falls back
to the CRD default `cluster.local`.

### Cluster prerequisites

KubeRay is **not** required for `cpuOnly`: the operator starts and reconciles
without the `ray.io` CRDs. The AIService controller does, however, watch
`Certificate` (cert-manager) and `ServiceMonitor` (Prometheus operator), and the
AgentRuntime and SLIM handlers create them, so those two CRDs must exist in the
cluster for every profile. The installer's `components.certManager` and
`components.monitoring` (both `true` in the shipped examples) install them. A
cluster without them keeps that controller from starting, exactly as a missing
KubeRay did for the platform controller; making those two watches optional is a
separate piece of work.

Private-registry images need the pull secret on every pod, even when the image
is already cached on the node. Verified on a live k0s cluster: the AgentRuntime
schema Job stayed in `ImagePullBackOff` until `ecr-registry-secret` was present
in the namespace and listed in `spec.images.imagePullSecrets`. The operator
passes `imagePullSecrets` to the schema Job and the Deployments, so the install
path must always set it for private images (MPR-193, MPR-190).

## Placement and resource budgets

No new API fields: placement comes from `spec.cpuScheduler` and `spec.gpuScheduler`
(node selector, tolerations, affinity) and budgets from the AIService
`spec.resources`. The operator never invents a node selector or toleration, so a
CPU-only host without node labels still places every workload; it only refuses
settings that contradict the profile.

**Agent runtime (both profiles).** Always on CPU nodes, never a GPU.

- It follows `spec.cpuScheduler`.
- Its budget defaults to requests `cpu 500m`, `memory 512Mi`, `ephemeral-storage 1Gi`
  and limits `cpu 1`, `memory 1Gi`, `ephemeral-storage 2Gi`
  (`agentruntime.DefaultResources`, the single definition). Requests are defaulted
  only when the whole map is unset, as before. Every cpu, memory and
  ephemeral-storage limit that is missing is added, as the larger of the default
  and the request for that resource, so the Deployment always has an explicit
  limit for each and a default never falls below something you asked for. Values
  you set are never changed.
- Refused, with the field in the message: a negative quantity, a request above its
  limit, a zero cpu, memory or ephemeral-storage budget, and any accelerator
  resource (`nvidia.com/*`, `amd.com/gpu`, `gpu.intel.com/*`). The admission webhook
  and the handler apply the same rules, so a CR applied without the webhook gets
  the same answer.

**SLIM.** Under `cpuOnly` it follows `spec.cpuScheduler` too, since every workload
there is a CPU workload, and an accelerator resource is refused. Under
`fullfeature` (and omitted or `full`) it stays unplaced as before and its
resources are not checked for accelerators: it is an existing component whose
resources an administrator may have set freely. Its default budget is unchanged
(`cpu 4`, `memory 5Gi`, requests equal to limits), and negative quantities and
requests above limits are refused under every profile. The SLIM Deployment now
honours `spec.nodeSelector`; before, only affinity and tolerations were copied.
The platform controller sets no selector for SLIM under `fullfeature`, so only a
selector patched directly onto a SLIM AIService takes effect where it was
silently ignored before.

**What "selects GPU capacity" means.** A node selector on any `nvidia.com/*` label
or on `splunk.ai/workload-type=gpu`; a required node affinity that matches such a
label with `In` (or `Exists` for an `nvidia.com/*` key); or a toleration of the
`nvidia.com/gpu` taint. An affinity that keeps a workload *off* GPU nodes
(`NotIn`, `DoesNotExist`) is not a selection, and neither is a toleration with an
empty key, which tolerates every taint but is not GPU-specific. Preferred
(soft) affinity is not examined.

**`cpuOnly`.** Renders no GPU workload, request or toleration. Besides the GPU
settings listed above, `spec.cpuScheduler` must not select GPU capacity. That check
is an error when the platform is created and an admission warning when it is
updated, so a platform made before the rule stays editable.

**`fullfeature`.** Hosted models run on GPU capacity through Ray and keep their own
resource ownership; the agent runtime stays on CPU nodes. For an *explicit*
`profile: fullfeature` the operator checks that GPU capacity is identifiable
(`gpuScheduler` node selector, affinity or a toleration of the GPU taint, or
`gpuInstanceType`, or `defaultAcceleratorType`), that `cpuScheduler` does not select
GPU capacity, and that the two schedulers do not place workloads identically (same
node selector, tolerations and affinity; a shared broad selector is fine when required
affinity or a taint separates the pools). Same split: an
error on create, a warning on update. An omitted profile and legacy `full` are the
same profile but are not checked at all.

**Why updates only warn, and deletion is never blocked.** The operator's own
finalizer removal is an update that goes through the webhook, and the operator runs
the profile validation on every reconcile. A placement rule that refused updates or
failed a reconcile could leave an existing platform uneditable or stuck in
Terminating over a setting that worked before the rule existed. So these rules
never fail a reconcile, only create refuses, and the AIPlatform and AIService
update webhooks allow any update of an object that is being deleted.

**Upgrade notes.** Every CR with the agent-runtime budget unset, or with requests
and limits both fully set, renders byte-identically to before (checked by rendering
the same inputs with the previous release). The only change to an existing
workload is a CR that sets *some* limits but not all of cpu, memory and
ephemeral-storage: the missing ones are added, which changes that Deployment's
hash, rolls its pods and re-runs its schema Job once. A CR that previously failed
because it set `requests.cpu` above the defaulted limit now works, with the limit
raised to the request.

Not in this section: the GPU requests and limits of the hosted-model workloads
(the MPR-188 contract covers the runtime, carrier, schema and SLIM images and AITK, not hosted models, so these stay an external input supplied with the model images), HPA replica control (MPR-197), and
NetworkPolicy and PDB (MPR-205).

## Not covered here

- Readiness gating of AgentRuntime itself (schema, pods, endpoints, probe): MPR-191.
- SLIM and AITK routing and trust configuration: MPR-199.
- The install waits that assume Ray and Weaviate after the CR is applied.
- Hosted-model GPU requests and limits (supplied with the hosted-model images, outside the MPR-188 contract), mirroring and image digest resolution (MPR-187).

## Reused code from `agent-runtime/ai-tier`

| Reused | Source | Adaptation |
|---|---|---|
| `Profile` field and `cpuOnly` constant | `api/v1/aiplatform_types.go` | Added `fullfeature` as canonical and `full` as legacy alias; omitted resolves to `fullfeature`; moved logic to `api/v1/aiplatform_profile.go` |
| cpuOnly conflict rules | `pkg/ai/validate_defaults.go`, `internal/webhook/v1/aiplatform_webhook.go` | One shared `ValidateProfile` used by both, field-specific errors, deterministic order |
| Skip vectorDB defaulting for cpuOnly | webhook defaulter | Unchanged intent |
| Switch to cpuOnly is rejected | webhook update | Unchanged; compares resolved profiles |
| Installer `aiPlatform.profile` parsing and cpuOnly conflict checks | `tools/cluster_setup/k0s_cluster_with_stack.sh` | Moved to `tools/ai-tier-cluster-setup`, added codes and required-reference checks, removed LAS, tracing and air-gap rules |
| cpuOnly CR rendering without GPU, Ray worker and vectorDB sections | same | Applies to the explicit profile only |

Not imported: everything LAS-specific (LAS image and tracing keys, LAS
assistant ID, the air-gap LAS checks).
