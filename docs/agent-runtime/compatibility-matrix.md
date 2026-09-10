# Agent Runtime Compatibility Matrix

Status: initial policy for AIP-4648

This document defines how the AI-Tier platform records compatibility between
the shared Agent Runtime base image and product-owned provider carrier images.
It is documentation and data only for the initial AIP-4648 scope. It does not
add runtime enforcement or define the compatibility report format.

The product onboarding expectations are documented in the [Product Onboarding
process & expectations](https://splunk.atlassian.net/wiki/spaces/PROD/pages/1080389174185/Product+Onboarding+process+expectations).

## Compatibility identity

The deployable unit is a certified pair, represented by this tuple:

```text
runtime base image digest
+ provider carrier image digest
+ Agent Runtime contract version
+ provider
+ graphCompatibilityVersion
```

Image tags are descriptive metadata only. A tag such as `latest` must be
resolved to an immutable digest before a pair can be certified.

The matrix record should also retain the provider's logical `agentId` values,
loader mappings, source revisions, supported architectures, and validation
harness revision. Those fields make a certification reproducible without
changing the operator's public API.

## Policy

### Carrier certification

A new carrier image must be tested against:

1. The current supported Agent Runtime base.
2. The immediately preceding supported Agent Runtime base (N-1).

The carrier is eligible for certification only when both required base tracks
pass the applicable checks. If a base track is unavailable or a test is not
run, the pair remains `untested` and must not be represented as certified.

### Base certification

A new Agent Runtime base image must be tested against every carrier that is
still supported by the matrix. A base upgrade is not complete when it has only
been tested with a newly created or representative carrier.

Each supported carrier must retain a passing pair with the new base before the
base can become the current supported base. Existing carrier certification on
older bases is retained for rollback and N-1 support until its support window
expires.

### Support window

The matrix maintains one `current` base track and one `n-1` base track. A base
may be marked `deprecated` only after the replacement base and all still-
supported carriers have passed the required checks. A carrier can be
deprecated independently when product support ends.

### Initial enforcement level

For AIP-4648, the matrix is documentation-only. The data format is designed
for future validation, but the operator must not reject a deployment merely
because a pair is absent from the matrix yet.

The intended enforcement progression is:

1. Document and record pairs.
2. Warn when a selected pair is absent or not certified.
3. Gate release/CI on the required certification checks.
4. Consider deployment-time enforcement only after the product onboarding and
   upgrade workflows are proven.

## Matrix status values

| Status | Meaning |
| --- | --- |
| `certified` | Required checks passed for the exact immutable base/carrier pair. |
| `pending` | The pair is selected for testing, but certification is incomplete. |
| `untested` | No valid certification evidence exists for the pair. |
| `blocked` | Testing or use is prohibited because a known incompatibility exists. |
| `deprecated` | Previously supported, but no longer part of the supported release window. |

Only `certified` pairs satisfy the compatibility policy. `pending` and
`untested` are useful for planning and coverage tracking; they are not
approval states.

## Required matrix records

### Base record

Each supported base record should contain:

- Stable base version, such as `v2.0.0`.
- Track: `current`, `n-1`, or `deprecated`.
- Full image reference and immutable digest.
- Agent Runtime contract version.
- Runtime source/build revision.
- Supported architecture list.
- Base status and support dates.

### Carrier record

Each supported carrier record should contain:

- Provider name.
- Carrier version and immutable image reference/digest.
- Source/build revision.
- Logical `agentId` values.
- One loader mapping for every `agentId`.
- `graphCompatibilityVersion`.
- Supported architecture list.
- Carrier status and support dates.

### Pair record

Each base/carrier pair should contain:

- References to the base and carrier records.
- Contract and graph compatibility versions observed by the test.
- Matrix status.
- Validation harness revision.
- Test timestamp.
- A link or identifier for the later compatibility report artifact.

The report field is intentionally reserved here; its schema will be defined in
later stories.

## Required checks

The platform-owned validation harness should provide the checks below. Local
AI-skill checks remain the primary product-team feedback loop; CI should run a
small, deterministic subset against the exact image digest.

### Manifest and loader checks

- Every `agentId` has exactly one loader mapping.
- Every loader path has the form `package.module:ClassName`.
- Each loader imports successfully.
- Each loader implements the public asynchronous `build(request,
  checkpointer)` contract.
- The graph compiles with the runtime-provided checkpointer.
- Graph state is checkpoint-serializable.
- Credentials, clients, tool objects, and database handles are not stored in
  checkpointed state.

### Image checks

- Both images can be pulled by digest.
- The carrier payload is present at the agreed handoff path.
- The payload is importable by the shared base image.
- No package installation or dependency resolution is required at runtime.
- The image architecture and CPU-only execution assumptions match the support
  record.
- The selected dependency set is compatible with the base runtime.

### Runtime checks

- Runtime startup and health/readiness succeed.
- One new turn succeeds.
- A follow-up turn succeeds with the same `threadId`.
- Checkpoint persist and resume succeed.
- HITL pause and resume succeed.
- Cancellation stops model, MCP, and tool work cleanly.
- An unknown `agentId` returns the documented `AGENT_NOT_FOUND` behavior.

## Matrix maintenance workflows

### New carrier

1. Add the carrier record with its immutable digest and manifest metadata.
2. Select the `current` and `n-1` base records.
3. Run the required checks for both pairs.
4. Mark both pairs `certified` only after both pass.
5. Keep the carrier `pending` or `untested` if either base track is missing.

### New base

1. Add the base record as `pending`.
2. Enumerate every carrier whose status is supported.
3. Run the required checks for every new-base/carrier pair.
4. Mark the new base `current` only when all required pairs pass.
5. Move the prior current base to `n-1` only after the new current base is
   fully covered.

### Carrier or base rollback

Rollback is allowed only to a pair that remains `certified` and whose image
digests are still available. A rollback must not silently reuse a certification
for a different digest behind the same tag.

## Ownership

Product teams own carrier code, product dependencies, loader behavior, agent
IDs, graph checkpoint compatibility, and local skill validation.

The platform/operator side owns the public runtime contract, base images,
matrix format, supported-version policy, validation harness, CI integration,
and compatibility status transitions.

The `agentRuntimeSkillReview` value belongs to the product onboarding manifest
and attests that local validation was rerun for relevant changes. It is not an
operator CRD field in this initial design.

## Relationship to the operator

The operator currently selects the base image using `runtimeVersion` and the
carrier/module using `provider`-derived related-image environment variables.
Those selectors identify the images to test, but they do not yet enforce the
matrix. The matrix therefore needs to resolve the exact image references and
digests used during certification rather than relying on operator defaults or
mutable tags.

The machine-readable starting point is
[`config/agent-runtime/compatibility-matrix.yaml`](../../config/agent-runtime/compatibility-matrix.yaml).
