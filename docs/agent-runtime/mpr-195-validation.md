# PostgreSQL Secret creation and validation

Reviewed and validated on 23 November 2026, against `ai-agent-runtime` commit
`636d408e483d7a7d488d1fe007215d365abfd85d`.

The deployment configuration creates a same-namespace PostgreSQL checkpoint
Secret before AIPlatform application. Both profile examples enable creation from
a named deployment-time input. The installer validates inputs, preserves
identical or explicitly external Secrets, and refuses conflicting contents.
Admission and reconciliation reject plaintext connection overrides, validate the
six-key Secret contract and contain raw API/parser/status diagnostics. No new
credential API/CRD field or automatic runtime rollout fingerprint is added.

See [deployment and migration guidance](postgres-secrets.md),
[local results](validation/mpr-195-local-results.json), and the
[live validation record](mpr-195-live-validation.md).

## Review fixes

Three independent reviews covered security, installer behavior, and Go/Kubernetes
reliability. Review found and fixed three gaps:

- A decoded database name containing `=` or a PostgreSQL URI prefix could be
  interpreted by libpq as connection settings. Both validators now reject it.
- Extra Secret aliases such as `PGHOSTADDR` or `PGSERVICE` could override the
  selected connection after whole-Secret import. They are rejected, including
  empty aliases. Installer reruns also reject these extras and invalid SSL modes.
- Python URI parsing accepted inputs that Go rejected after installation had
  persisted the Secret. The renderer now rejects those inputs before writing and
  decodes scoped IPv6 consistently. Ten table cases compare the actual shell
  renderer with the Go validator, covering ordinary/escaped credentials, scoped
  IPv6, raw spaces, invalid host escapes, query separators and nested connections.

All findings were re-reviewed after correction. The reviews used independent
contexts with the same model; they do not claim cross-model agreement.

## Final local verification

| Check | Result |
| --- | --- |
| All non-E2E Go packages | 22 packages with tests passed; 12 packages have no test files; zero failures |
| Local Kubernetes API server | Kubernetes 1.35.0 controller/admission tests passed, including actual production-helper Secret creation and stable rerun |
| Focused installer Secret tests | Nine passed |
| Shell renderer-to-Go contract regressions | Ten cases passed |
| Both profile CLI renders | cpuOnly/fullfeature matched their profile-values golden files |
| Static/format checks | `go vet ./...`, Go formatting, shell syntax and whitespace passed |
| Broad installer suite | 579 passed, 8 failed; complete clean baseline: 572 passed, 13 failed; no new failure descriptions |

The remaining broad-suite failures are seven existing mutable/untagged-image
assertions and the positive cpuOnly `validate` assertion. Five baseline Splunk
fixture assertions now pass after supplying their required settings; two formerly
undefined-helper assertions now execute. The suite is not represented as green.
Existing externally gated registry/S3 tests and two placeholders remain skipped;
individual skip names are recorded in the JSON results. This run used Go 1.26.10.

## Scope

All eleven disposable agentruntime-dev scenarios passed after the review fixes,
with verified resource/access cleanup and unchanged shared workloads and Secret.
The live record identifies the binary and immutable image digests.

PostgreSQL-only validation does not qualify provider/model/MCP credentials.
Automatic rotation remains optional for this release and deferred to MPR-268.
Product invocation, operator packaging/shared upgrade, cold installation,
PostgreSQL TLS, GPU/fullfeature execution and OS matrices remain separate.
