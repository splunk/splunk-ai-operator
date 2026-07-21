# Proposal: Admin-configurable capacity scaling via a single platform-wide `scaleFactor`

**Status:** Implemented in this change. This doc describes the resulting design and the reasoning behind it.
It supersedes an earlier per-*feature* approach (see "History" at the end).

## Background

We want to let on-prem admins control model-serving capacity through the k0s cluster config, without
requiring them to understand the internal model/GPU layout. Investigation found:

- Individual models are internal Ray Serve applications identified by internal names; admins are not
  expected to know these.
- Model-serving capacity was previously driven by **per-feature** files (`config/configs/features/<name>.yaml`,
  of which only `saia.yaml` ever existed) plus a **per-feature** `FeatureSpec.ScaleFactor`. The operator
  looped `spec.Features`, read `features/<name>.yaml`, and accumulated replica/worker demand across
  features. This coupled two unrelated concerns onto `spec.Features`: (1) RayService sizing and
  (2) AIService child creation in `ReconcileFeatures` (one AIService per feature).
- The old per-feature `scaleFactor` scaled only the model (application) replicas, not the GPU worker pool.
  These share a fixed GPU pool, so scaling replicas alone overcommits the hardware and leaves replicas
  unschedulable.

## Approach that landed

Consolidate to a **single, shared source of truth** with one platform-wide capacity knob:

- **Two global config files** replace the per-feature files, keeping the same map shapes:
  - `config/configs/model-scale.yaml` — `applicationScale:` (model name → base replica count). Migrated
    verbatim from the `applicationScale` block of `features/saia.yaml`. A separate file is required because
    `applications.yaml` is a Go `text/template` whose replica fields are `{{.Replicas.X}}` placeholders, so
    base replicas cannot be parsed back out of it.
  - `config/configs/worker-scale.yaml` — `instanceScale:` (accelerator → tier → base pod count). Migrated
    verbatim from the `instanceScale` block of `features/saia.yaml`.
  - `config/configs/instance.yaml` (tier / gpusPerPod / resources) is **untouched**.
  - `config/configs/features/` is **deleted**.
- **One global `spec.scaleFactor`** — a platform-wide multiplier that scales **both** the model (Serve)
  replicas **and** the GPU worker-group pod counts uniformly, so the two stay in lockstep on the shared,
  fixed GPU pool. It must be an integer greater than or equal to 1 and defaults to 1 (CRD `Minimum=1`,
  `default=1`). One knob grows capacity end-to-end without the admin needing to know which models exist or
  how many GPUs each uses. Zero and negative values are rejected; `scaleFactor` is not a platform pause
  mechanism.
- **Every model is always deployed.** Models are **not** tagged with features (see "Why not feature-tagged
  models" below).
- The old **per-feature** `FeatureSpec.ScaleFactor` is **removed** from the API. Capacity is controlled
  solely by the platform-wide `spec.scaleFactor`.

Intended outcome: sizing is decoupled from `spec.Features`; `spec.Features` continues to drive only
AIService creation (`ReconcileFeatures` untouched); one knob (`spec.scaleFactor`) controls capacity.

## Assumptions we are making (and why)

1. **Platform-level scaling is the right granularity, not per-feature or per-model.**
   *Why:* A single dial is the simplest safe surface for an audience that shouldn't manage internal model
   names or per-model GPU math. Because every model is always deployed, there is no per-feature capacity to
   reason about.
   *Trade-off:* `scaleFactor` scales every model and worker tier uniformly — it can't grow one model alone.

2. **`scaleFactor` scales application replicas and instance (GPU) scale together.**
   *Why:* They draw on one shared, fixed GPU pool. Scaling only replicas overcommits the pool and produces
   stuck/pending replicas. Coupling both keeps the knob safe by construction.

3. **Min and max replicas stay pinned to the same value (no elastic autoscaling).**
   *Why:* Matches prior behaviour and suits provisioned GPU LLM serving — replicas stay warm (avoiding slow
   cold-start weight loads) and the provisioned GPU pool is fully used.

4. **Admins discover the knob through config comments, not CRD introspection.**
   *Why:* This audience runs a DevOps stack and isn't expected to use `kubectl explain`. The config file is
   the reliable admin-facing surface.

5. **Per-model base replica values remain unchanged.**
   *Why:* Keeps `scaleFactor` a clean multiplier over current defaults; changing bases is out of scope.

## Why not feature-tagged models (out of scope)

Tagging each model with the feature(s) it belongs to, then filtering models and auto-sizing worker groups
from feature membership, is **not feasible with the current model** and is explicitly out of scope.

There is *no structured link* between a model and the GPU footprint it needs on a worker tier. A model's
GPU demand exists only as an opaque template literal in `applications.yaml` (`num_gpus: 1`, `0.5`,
`0.0375`, …), never parsed by Go. Worker-tier counts (`instanceScale`) are **hand-authored magic numbers**
unrelated to which models run. So if we tagged and filtered models, the worker pool would have no way to
shrink or grow to match — nothing tells the operator which tiers a disabled feature's models consumed or
how much GPU they freed. The result would be feature-filtered models against a fixed, mismatched worker
pool, which is worse than always deploying everything.

Revisiting this later would first require a structured per-model GPU footprint (lifting `num_gpus` out of
the template into data) plus an explicit model→tier assignment, so `buildClusterConfig` could sum
`replicas × gpusPerReplica` per tier. That is a larger, separate effort.

## Migration / upgrade behaviour

The per-feature `scaleFactor` was never reachable from any admin-facing config surface (the k0s installer
never emitted it), so no in-the-wild CR ever set it to a non-default value. Backward-compat handling for it
was therefore unnecessary and has been dropped — the field is removed from the API.

- **Removed feature files.** Deployments mounting `features/*.yaml` no longer need them; the operator stops
  reading that path. The two global scale files are baked into the operator image instead.
- **Removed API field.** `FeatureSpec.ScaleFactor` is gone. A CR that still hand-sets
  `features[].scaleFactor` will now be rejected by strict/server-side apply (unknown field) rather than
  silently ignored — but the k0s installer regenerates the CR each run, so the normal upgrade path never
  emits it.
- **Parity.** With `scaleFactor` unset (=1) the rendered Serve config and worker specs are identical to the
  prior single-feature (saia) `base × 1` output. Guarded by a parity test. An upgrade that refreshes the
  operator image and re-applies the CR keeps capacity unchanged unless `spec.scaleFactor` is set.

## Change set

1. **Config files — done.** Added `config/configs/model-scale.yaml` and `config/configs/worker-scale.yaml`
   (migrated verbatim from `features/saia.yaml`); deleted `config/configs/features/`.
2. **Operator — done.** `pkg/ai/raybuilder/builder.go`: `effectiveScaleFactor()` helper; `ScaleConfig`
   struct (renamed from `FeatureConfig`); `loadScaleConfig(envVar, defaultFile)` reads the two global files
   (`MODEL_SCALE_FILE` / `WORKER_SCALE_FILE`). `ReconcileRayService` builds `replicas = base × scaleFactor`
   for every model; `buildClusterConfig` builds `instanceScale[tier] = count × scaleFactor`. The
   per-feature loops and cross-feature accumulation are gone. `ReconcileFeatures` (AIService creation) is
   untouched.
3. **CRD / API / webhook — done.** Added `AIPlatformSpec.ScaleFactor *int32` (`Minimum=1`, `default=1`);
   removed `FeatureSpec.ScaleFactor` entirely. Webhook `validateScaleFactor` rejects values below 1.
   Regenerated via `make manifests generate helm-sync`.
4. **Dockerfile — done.** Copies `model-scale.yaml` / `worker-scale.yaml` (instead of `features/`); sets
   `MODEL_SCALE_FILE` / `WORKER_SCALE_FILE` env vars.
5. **k0s script + config — done.** `k0s_cluster_with_stack.sh` reads top-level `aiPlatform.scaleFactor` and
   emits `scaleFactor:` into the CR near `defaultAcceleratorType` (features loop emits `name`/`version`
   only). `k0s-cluster-config.yaml` documents `scaleFactor` as a top-level `aiPlatform` knob with the
   "needs proportionally more GPUs" caveat.
6. **Tests — done.** `pkg/ai/raybuilder/scale_factor_test.go`:
   `TestReconcileRayService_GlobalScaleFactor` (replicas = base × factor in the rendered ConfigMap),
   `TestBuildClusterConfig_GlobalScaleFactor` (worker Replicas/Min/Max = count × factor), and
   `TestScaleFactor_DefaultsToOne_Parity` (unset factor equals migrated `saia.yaml` values). Webhook tests
   cover zero and negative values being rejected, while 1 and an unset value are accepted. The k0s config
   tests additionally reject decimals, quoted integers, and explicit null values.

## Out of scope (tracked as follow-ups)

- Per-model replica control and elastic min/max autoscaling — future, if a need emerges.
- Feature-tagged models + auto-sized worker groups — needs a computable per-model GPU footprint first (see
  "Why not feature-tagged models").
- **EKS parity.** `tools/cluster_setup/eks_cluster_with_stack.sh` is a separate script with a hardcoded
  features block and does not emit `scaleFactor` today. The operator-side change benefits EKS-deployed
  platforms regardless, but EKS admins have no config knob to set it yet.

## History

An earlier iteration exposed the **per-feature** `FeatureSpec.ScaleFactor` through the k0s config and made
it accumulate replica/worker demand across features. That direction was superseded because sizing was
coupled to `spec.Features`, per-feature scale factors interacted in ways admins couldn't reason about, and
adding a feature file was the only way to change sizing. The current design decouples sizing into two
global files plus a single platform-wide `scaleFactor`.
