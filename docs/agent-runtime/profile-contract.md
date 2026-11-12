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
| Provider loader module, one per provider (`package.module:ClassName`, the `AGENT_MODULE` value; TBD for Launchpad) | `images.agentRuntime.providerModules.<provider>` |
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
from 1 to 100. Rejected values are never echoed in error messages (an unsupported profile name is shown only when it is a short plain name, otherwise "(value not shown)"). `aiPlatform.scaleFactor`, when set, must be a
YAML integer of at least 1 (the same rule `install` enforces). Duplicate feature
identities (`agentruntime` is keyed by provider) are rejected, as in the webhook.

Optional: `images.aitk.image`. Nothing in the operator or the air-gap bundle
consumes the AITK image yet, so it is not required; whether it becomes required
is to be decided with MPR-188. When given it is validated as a safe scalar and
rendered into the values file.

Optional: `images.snapshotManifest`, the per-run image snapshot manifest
(MPR-187 output). It is passed through to the rendered values unchanged. A
final release digest is not required.

The exact Launchpad provider key and `AGENT_MODULE` value are TBD until the
image owners supply a validated contract (ERD 14.4.6). The examples use a
placeholder.

## Rules by profile

`cpuOnly` contradictions are enforced in two places. Both give field-specific
errors.

Operator and webhook (`spec.*`):

- features `saia` or `seca`
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
- any sidecar flag that is not an explicit `false`

For `cpuOnly` the installer also skips the air-gap model-artifact verification
(there is no local model to verify) and never prompts for model staging or an
accelerator.

`fullfeature` is rejected with `components.kuberay: false`, since model serving
uses Ray. When KubeRay and the AIPlatform CR are enabled it also requires
`images.ray.headImage`, `images.ray.workerImage` and `images.weaviate.image`, so
that `validate` and `render-profile` agree with `install`. CPU/GPU placement and
resource semantics are MPR-186's.

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

The webhook also rejects switching an existing platform (omitted, `full` or
`fullfeature`) to `cpuOnly`. An omitted profile and `fullfeature` are the same
profile on update.

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

## Not covered here

- Reconcile behaviour per profile (a separate story). The platform reconciler still runs its Ray,
  Weaviate and ingress stages, and the agentruntime handler waits for
  `RayServiceStatusReady`. A `cpuOnly` platform therefore cannot become Ready
  until the reconcile stages and readiness gating are made profile-aware.
- The install waits that assume Ray and Weaviate after the CR is applied.
- Placement, resource budgets, mirroring and image digest resolution.

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
