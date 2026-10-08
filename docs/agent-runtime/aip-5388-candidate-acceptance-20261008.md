# AIP-5388 candidate fixture acceptance — 2026-10-08

## Scope

This record assesses [AIP-5388](https://splunk.atlassian.net/browse/AIP-5388)
against its revised candidate-image criteria. Jira evidence comment
`21700720` was added on 2026-10-08. The story is In Progress pending code review and merge. Product image approval and
immutability are in [AIP-5567](https://splunk.atlassian.net/browse/AIP-5567).
Credential-bearing caller/state checks are in
[AIP-5402](https://splunk.atlassian.net/browse/AIP-5402). The reusable smoke
script is a separate [AIP-5390](https://splunk.atlassian.net/browse/AIP-5390)
deliverable.

## Candidate and prior cluster evidence

- Candidate image: `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/las-contract-fixture:candidate-20261008-0810`.
- Recorded ECR digest: `sha256:38b7825b1581762e2fbfbc091999cefb3e33b509d1c3c5d6211fe185a2ee60f2`.
- Graph/default assistant ID: `contract_fixture`. Current source hashes still match
  the [2026-10-08 candidate test record](las-contract-fixture-candidate-validation-20261008.md).
- With typed AIPlatform selection and the air-gapped license Secret, the same
  AIService reached `Ready=True/LASReady` at Helm revision 4. API and queue
  were Ready. Helm values selected the candidate tag and contained references
  to the license, PostgreSQL and Redis Secrets, without per-run model/MCP/KB
  context or fake credential values.
- Through the stable LAS Service, `/ok` returned HTTP 200; graph discovery,
  a basic thread/run, persisted nonsecret graph values and interrupt/resume
  passed. The final candidate's Pod image digest was not captured before the
  POC deployment was restored; Helm tag and ECR digest were verified separately.

## Focused verification in the current working tree

- Added a chart-render check confirming that API and queue Deployments use
  the selected candidate image and that per-invocation fields are absent.
- Added an AIPlatform builder check for image, assistant ID and deployment
  Secret-reference propagation, including a changed candidate tag.
- Updated the feature-registry test to expect the LAS handler selected by the
  current POC factory.
- `go test ./pkg/ai/... ./internal/controller/... ./internal/webhook/v1/... -count=1`
  passed with a writable temporary Go cache and localhost test-port access.
  The webhook Ginkgo suite skipped 27 environment specs in `BeforeSuite`;
  direct LAS configuration validation tests did pass.
- `git diff --check` passed. Both distributed CRD copies match their source
  CRDs byte-for-byte.

## Acceptance assessment and limits

The three revised AIP-5388 criteria have local candidate evidence: typed
selection and propagation, a Ready operator-owned deployment with baseline
LAS behavior, and Secret-reference-only Helm configuration. No actual
Launchpad image or approved immutable release artifact was used.

The fixture test found fake per-run credential values in LAS thread-state
checkpoint metadata. That remains a failure under AIP-5402 and a product
validation gate under AIP-5567; it is not evidence that credential-bearing
run context is safe. The SLIM caller route was not verified in this test.

The candidate changes are proposed for review from a dedicated AIP-5388 branch
based on `agent-runtime/ai-tier`. The POC cluster was restored to its original
operator/image after candidate testing.
