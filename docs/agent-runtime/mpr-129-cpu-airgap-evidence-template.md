# MPR-129 CPU-only air-gap qualification evidence

> Template only. No qualification run is recorded in this file. Complete a
> dated copy after a fresh isolated install, review it for sensitive data, and
> store environment-specific attachments in the protected evidence location.

## Qualification status

- Status: `NOT RUN`
- Run date and timezone: `<YYYY-MM-DD, timezone>`
- Reviewer: `<name or team>`
- Maintenance-window approval: `<protected reference>`
- Result: `<PASS | FAIL | BLOCKED>`
- Remaining limitations: `<none or concise list>`

## Source and artifact identity

- Repository commit: `<40-character commit>`
- Source worktree clean: `<yes/no; command result reference>`
- Operator image reference: `<repository:tag>`
- Operator immutable image digest: `<sha256:...>`
- LAS/Launchpad image reference: `<repository:tag>`
- Approved LAS image digest(s): `<manifest and selected platform sha256:...>`
- Embedded LAS chart path/version: `<path and version>`
- Embedded LAS chart SHA-256: `<64 hex characters>`
- k0s version: `<version>`
- Bundle filename: `<non-sensitive filename>`
- Bundle SHA-256 before transfer: `<64 hex characters>`
- Bundle SHA-256 after transfer: `<64 hex characters>`
- `checksums.sha256` result: `<PASS/FAIL>`
- `image-inventory.json` validation: `<PASS/FAIL>`
- Image source used by nodes: `<OCI archive or separately verified private mirror>`
- Runtime validator result/scope: `<RUNTIME_PASS / runtime-only; not final acceptance>`

Protected attachments:

- Bundle inventory: `<reference>`
- Checksum manifest: `<reference>`
- Builder transcript, sanitized: `<reference>`
- Transfer verification, sanitized: `<reference>`

## Isolation evidence

Record conclusions and protected attachment references, not account numbers,
private addresses, endpoint IDs, SSH paths, or host keys.

- Installer has private addressing only: `<PASS/FAIL>`
- Controller/worker have private addressing only: `<PASS/FAIL>`
- No Internet-gateway default route: `<PASS/FAIL>`
- No NAT default route: `<PASS/FAIL>`
- Security-group egress limited to approved private destinations: `<PASS/FAIL>`
- Required private endpoints reachable: `<PASS/FAIL>`
- Public TCP reachability unavailable: `<PASS/FAIL and bounded method>`
- Kubernetes NetworkPolicy claim made: `NO, unless an effective policy was separately installed and tested`
- Sanitized network evidence JSON: `<reference>`
- Protected AWS/VPC evidence: `<reference>`

## Preflight and fresh installation

- Validation-only command, sanitized: `<reference or command without private paths>`
- Validation-only result: `<PASS/FAIL>`
- Fresh-install command, sanitized: `<reference or command without private paths>`
- `AUTO_DIAGNOSE=false` used: `<yes/no>`
- Fresh-install start/end time: `<timestamps>`
- Fresh-install result: `<PASS/FAIL>`
- Installer output reviewed before sharing: `<yes/no>`
- Historical deployment reused as proof: `NO`

## CPU-only topology

- Controller count and Ready count: `<expected/ready>`
- CPU worker count and Ready count: `<expected/ready>`
- GPU worker count: `0`
- GPU allocatable resources observed: `<none or failure>`
- NVIDIA workloads observed: `<none or failure>`
- KubeRay/Ray workloads observed: `<none or failure>`
- Model-staging workloads observed: `<none or failure>`
- Node observation attachment, sanitized: `<reference>`

## Platform and supporting workload readiness

- AIPlatform name: `<non-sensitive resource name>`
- AIPlatform generation/observed generation: `<value/value>`
- AIPlatform Ready: `<True/False>`
- Agent Runtime AIService name: `<non-sensitive resource name>`
- AIService generation/observed generation: `<value/value>`
- AIService Ready: `<True/False>`
- LAS API desired/ready replicas: `<value/value>`
- LAS queue desired/ready replicas: `<value/value>`
- LAS compatibility Service ready endpoints: `<count>`
- SLIM desired/ready replicas: `<value/value>`
- Operator desired/ready replicas: `<value/value>`
- Splunk Operator desired/ready replicas: `<value/value>`
- Splunk readiness: `<status>`
- PostgreSQL private-path reachability: `<PASS/FAIL; no URL>`
- Redis private-path reachability: `<PASS/FAIL; no URL>`
- Object-store private-path reachability: `<PASS/FAIL; no credentials>`
- Readiness evidence attachment, sanitized: `<reference>`

## Running LAS image identity

### API Pod before replacement

- Pod name: `<name>`
- Pod UID: `<uid>`
- Node architecture: `<os/architecture>`
- Declared image reference: `<repository:tag>`
- Runtime `imageID`: `<repository@sha256:... or runtime form>`
- Normalized digest: `<sha256:...>`
- Digest present in approved inventory: `<PASS/FAIL>`
- Ready: `<yes/no>`

### Queue Pod before replacement

- Pod name: `<name>`
- Pod UID: `<uid>`
- Node architecture: `<os/architecture>`
- Declared image reference: `<repository:tag>`
- Runtime `imageID`: `<repository@sha256:... or runtime form>`
- Normalized digest: `<sha256:...>`
- Digest present in approved inventory: `<PASS/FAIL>`
- Ready: `<yes/no>`

## Replacement-Pod evidence

- Explicit replacement opt-in flags used: `<yes/no>`
- Component replaced: `<api/queue>`
- Original Pod name and UID: `<name, uid>`
- Original normalized digest: `<sha256:...>`
- Replacement Pod name and UID: `<name, different uid>`
- Replacement became Ready: `<PASS/FAIL>`
- Replacement normalized digest: `<sha256:...>`
- Same digest before and after: `<PASS/FAIL>`
- Replacement digest present in approved inventory: `<PASS/FAIL>`
- Port-forward recreated after replacement, if applicable: `<yes/no/not used>`
- Replacement evidence attachment, sanitized: `<reference>`

## Invalid-artifact fail-closed evidence

- Scratch bundle used; approved original unchanged: `<yes/no>`
- Artifact deliberately removed or corrupted: `<non-sensitive relative path/type>`
- Scratch validation-only command: `<sanitized reference>`
- Exit status: `<nonzero value>`
- Expected bounded error: `<checksum/artifact/OCI/inventory/chart category>`
- Bundled installer invoked: `NO`
- Host binaries or Helm repositories changed: `NO`
- `kubectl` or SSH invoked: `NO`
- Registry/public download attempted: `NO`
- Sentinel/transcript evidence, sanitized: `<reference>`

## Sensitive-data review

- Secret data queried or decoded: `NO`
- Populated deployment config attached: `NO`
- License key, database/Redis URL, registry auth, SSH key, or raw environment present: `NO`
- Private topology identifiers removed from shareable evidence: `<yes/no>`
- Logs and generated JSON/Markdown reviewed locally: `<yes/no>`
- Reviewer sign-off: `<name/date or protected approval reference>`

## Cleanup and final health

- Disposable graph threads/runs removed: `<yes/no/not created>`
- Test fixtures and port-forwards stopped: `<yes/no/not used>`
- Changed resources restored: `<yes/no/not changed>`
- Final nodes Ready: `<PASS/FAIL>`
- Final AIPlatform/AIService Ready: `<PASS/FAIL>`
- Final API/queue/supporting workloads Ready: `<PASS/FAIL>`
- Cleanup/final-health evidence, sanitized: `<reference>`

## Final acceptance statement

Use this statement only when every required live check above passes:

> A fresh CPU-only k0s environment installed the reviewed AI Tier/LAS build from
> the SHA-pinned offline bundle while public artifact access was unavailable.
> API, queue, and supporting workloads became Ready without GPU, Ray, or model
> staging artifacts. A replacement LAS Pod became Ready with a new UID and the
> same approved runtime image digest. A deliberately invalid scratch bundle
> failed before installer, cluster, or public fallback activity. The retained
> evidence was reviewed and contains no credentials or private topology.
