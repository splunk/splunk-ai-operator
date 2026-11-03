# MPR-129 CPU-only air-gap fresh-install evidence

Date: 2026-10-29

## Result

The approved CPU-only offline bundle completed a fresh installation on the
shared disposable qualification cluster. The two RHEL 9.8 `linux/amd64` nodes
became Ready without GPU capacity, the AIPlatform and Agent Runtime and SLIM
AIServices became Ready, and the LAS API, LAS queue, SLIM, Splunk, AI operator,
and Splunk operator workloads were healthy.

A post-install read-only qualification passed. A bounded queue-Pod replacement
also passed: the Deployment created a new Ready Pod with a different UID and the
same archive-approved OCI runtime digest. A final read-only qualification passed
after the replacement.

## Qualified bundle and source

- Bundle source commit: `b03708770270bb1fdab95952294ced914e1706bf`
- Bundle SHA-256:
  `c0a103d8bd53da89f54fed9a41473dbfc8edb1127c17ff6bfbf5e96fb19872ad`
- Checksum-manifest SHA-256:
  `04c7ee85ad1c85843ec9883e37249abeac41169035ce9abacdff003fb4753d7b`
- Bundle profile: `cpuOnly`
- Embedded chart: `langgraph-cloud` `0.3.5-splunk.2`
- Selected Launchpad OCI index digest:
  `sha256:5cc1a49d2f3de8cd324e1ce42009216a617f95d162ff05462ac3f1163b63fccb`
- Selected `linux/amd64` manifest digest:
  `sha256:703bcba51240359b28dd8952708bd5d778c546bff3d7811736255115d287d4ab`
- Observed and archive-derived OCI config/runtime digest:
  `sha256:3f3874e0603810d203dfa173af7a9f01d85a28c6962c7a54589552e1279fa113`

The bundle tarball, extracted tree, source marker, image inventory, embedded
chart, and all required image archives were checksum-verified before Kubernetes
was queried or changed. A negative preflight using an incorrect approved bundle
SHA-256 failed before extraction or cluster mutation.

## Fresh-install procedure and recovery

1. Captured the existing health state and created an owner-only backup of the
   three referenced LAS Secret objects required across the rebuild.
2. Ran the normal cluster deletion/reset path, not `clean-all`; both cluster
   nodes reset successfully.
3. Ran the offline installer from a newly extracted copy of the approved
   tarball.
4. The first attempt stopped in preflight because the protected object-store
   password was intentionally absent from the YAML config. No cluster rebuild
   occurred in that attempt.
5. Retried with the existing owner-managed object-store password supplied only
   through the installer process environment. The offline installer exited
   successfully.
6. Restored the referenced LAS Secrets, verified their presence without
   printing values, promoted the validated config to the canonical installer
   location, and removed the temporary Secret backup and checksum.

The backup operation necessarily read the Kubernetes Secret objects, including
their base64-encoded `data` fields. Those values were never decoded, printed,
copied into this repository, or included in the shareable evidence. The backup
was mode-protected and deleted after successful restoration; the live Secrets
remain in the cluster.

## Network-isolation proof

A fresh read-only AWS and runtime capture proved all of the following before the
final qualification runs:

- installer, controller, and CPU worker were running with private addresses and
  no public addresses;
- cluster subnets did not assign public addresses;
- no Internet-gateway or NAT-gateway default route existed;
- active routes and security-group egress were limited to private CIDRs or
  private endpoint prefix lists;
- the private registry, object store, PostgreSQL, Redis, DNS, and SSH
  dependencies were reachable; and
- bounded public TCP probes were not reachable.

The validator converted raw destinations into sanitized destination classes in
the evidence output. No private addresses or AWS resource identifiers are
included in this record.

## Runtime qualification

The final validator and OCI helper came from hardening commit `7c124aa`. Their
copies on the installer were SHA-256 matched to the local files before use.

The validator proved:

- exactly one Ready controller and one Ready CPU worker, both `linux/amd64` and
  without GPU resources or external node addresses;
- current-generation Ready conditions for the platform and both AIServices;
- no forbidden GPU, Ray, or model-staging workloads;
- desired and Ready replicas for every required Deployment and StatefulSet;
- configured and observed image identities for LAS, SLIM, Splunk, the AI
  operator, and the Splunk operator;
- every observed runtime digest derived through a checksum-covered OCI
  reference-to-index-to-platform-manifest-to-config chain;
- LAS API Service ownership, selector, port, and Ready endpoint continuity; and
- a queue replacement with a new Pod UID, Ready state, correct controller
  ownership, and the same approved runtime digest.

Three sanitized evidence sets were retained in the protected installer evidence
directory: pre-replacement read-only health, queue replacement, and
post-replacement read-only health. A credential and private-identifier scan of
their JSON and Markdown outputs returned no matches.

## Automated tests and review

- 24 OCI inventory tests passed locally and on the installer.
- 31 runtime-qualification tests passed locally and on the installer.
- 19 validation-only installer-wrapper tests passed locally.
- Shell syntax checks, Python compilation, and `git diff --check` passed.
- Independent review completed with no remaining P1 or P2 findings.

Coverage includes checksum and tar safety, missing artifacts, invalid source or
profile, schema-v1 compatibility, schema-v2 runtime identities, multi-arch
platform filtering, single-manifest images, OCI config/platform binding,
supporting-component identity chains, stale readiness, unapproved digests,
sanitization, replacement opt-in, and replacement recovery.

## Scope and follow-up

The fresh installation used the immutable schema-v1 bundle built from
`b0370877`. Commit `7c124aa` was then used as qualification tooling; it was not
embedded into or used to rebuild that already approved bundle. The install is
therefore evidence for the recorded bundle and source commit, not proof that a
new bundle built from `7c124aa` has been installed.

For a production candidate, rebuild the offline bundle from the final reviewed
source so its schema-v2 inventory records the explicit `linux/amd64` target and
archive-derived runtime digests, then repeat the fresh-install gate against that
new immutable bundle identity.
