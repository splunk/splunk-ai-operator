# LAS contract fixture candidate validation — 2026-10-08

Scope: execute the first four fixture-plan steps for AIP-5388 against the
`agentruntime-dev` POC cluster. This is candidate validation, not immutable
promotion or Launchpad product-image qualification. No real model, MCP, or
knowledge-base endpoint was used. Credential-like run values were fake tokens.

**Scope decision, 2026-10-08:** [AIP-5388](https://splunk.atlassian.net/browse/AIP-5388)
may complete candidate fixture selection, deployment configuration and a
nonsecret baseline smoke. Approval and immutable image identity move to
[AIP-5567](https://splunk.atlassian.net/browse/AIP-5567) with the actual
Launchpad image. Candidate fixture success does not approve credential-bearing
run context. The checkpoint finding remains in
[AIP-5402](https://splunk.atlassian.net/browse/AIP-5402); the actual product
image and full path must pass
[AIP-5567](https://splunk.atlassian.net/browse/AIP-5567) before real credentials
or product acceptance. The original results below are retained as evidence.

## Result

**Partial pass at the time of the test.** A separate deterministic
fixture image was built, published, selected from typed AIPlatform
configuration, and run through the operator-owned stable LAS Service with an
air-gapped license. Health, graph discovery, execution, interrupt/resume, and
persisted graph values worked. LAS returned the fake per-run context values in
the thread state response's `metadata`, so the checkpoint credential criterion
failed. The fixture's own `values` and response omitted those values. The
current SLIM Service did not expose a verified LAS caller route in this check.

## Step 1 — fixture and configuration

- Source: `samples/las-contract-fixture/{agent.py,langgraph.json,requirements.txt}`.
  Graph/default assistant ID: `contract_fixture`. Graph state contains request,
  deterministic response, optional pause flag, and the *names* of context
  fields received. It neither calls external services nor copies context
  values into graph state.
- Final source SHA256: `agent.py`
  `98ae3745f1c66192beac759a8d8f75d67640bdd13915ea125f4272744c120801`;
  `langgraph.json`
  `504b1c82aea70c09d161164149196a0ddc212d4c1ac853460fba7fce58a9c672`;
  `requirements.txt`
  `e845e774c753614ffc939cd5fd522e80ad26c49fe9c2f980626b033de08652f8`.
  Base Git HEAD at test time: `483a832`; the fixture and operator changes were
  in the working tree during validation, so that HEAD alone does not identify
  their source.
- Pinned `langgraph==1.2.14`, built with
  `langgraph-cli[inmem]==0.4.32`, Agent Server base
  `langchain/langgraph-api:3.11` at digest
  `sha256:5e2279e2a21b627a8f76ef178deb58c612d0124abd0f3349b47402af3231c529`.
  The POC's `langgraph==0.4.10` lacked the runtime context API; `1.0.10`
  conflicted with the base image's SDK constraint. `1.2.14` built and the
  graph ran locally with fake context.
- Added typed `features[].las.image.repository`, `tag`, and `assistantId` to
  AIPlatform/AIService, admission checks, generated deep-copy code, both CRD
  copies, and the sample configuration. `lasValues` now takes the image from
  the AIService instead of the hardcoded POC image. The AIPlatform reconciler
  already copies the FeatureSpec into AIService. The assistant ID is retained
  there for the caller; this Helm chart has no assistant-ID value and the
  current SLIM caller does not consume it.
- Focused Go tests for image selection, Secret reference rendering, and LAS
  field validation passed. `git diff --check` passed. The existing Ginkgo
  webhook suite reported 27 skipped specs because its BeforeSuite skipped;
  this is not counted as a webhook integration pass.

## Step 2 — candidate publication

- Created ECR repository `ml-platform/las-contract-fixture` in AWS account
  `658391232643`, region `us-west-2`, with mutable tags and scan-on-push.
- First candidate `candidate-20261008-0751`: ECR digest
  `sha256:bd197d27dbef70373017eb87fd9abea55d917fcb21150fbe0a8a20117dbec944`.
  It passed the basic run and exposed the checkpoint metadata issue.
- Final resume-capable candidate `candidate-20261008-0810`: ECR digest
  `sha256:38b7825b1581762e2fbfbc091999cefb3e33b509d1c3c5d6211fe185a2ee60f2`,
  compressed ECR size 264,014,564 bytes. Local build platform was Linux AMD64.
  Its tag is **mutable**. Approval and immutable-reference qualification are
  deferred to the actual-image validation gate under AIP-5567.
- Updated operator candidate image:
  `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/splunk-ai-operator:las-fixture-20261008-483a832`,
  ECR digest
  `sha256:3470b246dbb50081199508d5ca1bcd749fbcd049491934a6a714d559d66e96c7`.
  The Linux AMD64 manager binary SHA256 was
  `feebd97c7aaebd10d7efd280cce2b7beea6fc34b38a424e89a2d3897226a8df6`.
  It was packaged with the same distroless base, config files, user, and
  entrypoint as the POC Dockerfile.

## Step 3 — operator deployment using offline license

- Verified AWS account/role before publishing. Applied the generated
  AIPlatform/AIService CRDs, created `ai-platform/las-auth-offline-fixture` from
  the **first line only** of `/Users/kchoudhary/langsmith license es team`, and
  refreshed short-lived ECR pull Secrets. No license/token bytes or decoded
  payload were printed or saved in this record.
- Patched the existing AIPlatform agentruntime feature to select the fixture
  image, `assistantId: contract_fixture`, and the offline license Secret.
  Rolled the updated operator. AIService UID stayed
  `39598b65-89e6-4b32-ba5b-547dc9902036`; it received the selected fields
  and reached `Ready=True/LASReady` at Helm revision 3 for the first candidate
  and revision 4 for the resume-capable candidate. API and queue were Ready.
  For the first candidate both running Pod image IDs matched its ECR digest.
  The second candidate's running Pod digest was not captured before rollback;
  its Helm values/tag and ECR digest were verified separately.
- Helm values rendered the selected repository/tag and only Secret references
  (`las-auth-offline-fixture`, `las-postgres`, `las-redis`). No
  `llm_config`, `mcp_configs`, `kb_configs`, or fake token appeared in values.
  Recent API/queue log scans found none of the fake tokens. The ready LAS
  workloads under this Secret are evidence of successful offline-key startup;
  network isolation or complete air-gapped operation was not tested.

## Step 4 — smoke and caller check

| Check | Result / evidence |
| --- | --- |
| Stable Service health | `GET /ok` returned HTTP 200, `{"ok":true}` through `agentruntime-dev-ai-platform-agentruntime-mltk-svc:8080`. |
| Graph selection | `POST /assistants/search` returned `graph_id=contract_fixture` and assistant ID `600ffcb3-cb30-5870-83a1-d13f860eb8aa`. |
| Basic run | Thread `01a11a8b-0447-75f2-8afb-1499a6319aaa`; `runs/wait` HTTP 200 returned `LAS contract fixture received: candidate smoke` and all three context field names. Fake token absent from response. |
| Persisted graph values | `GET /threads/{id}/state` HTTP 200 returned request, response, and context field names. Fake token absent from `values`. |
| Checkpoint metadata **failed** | The same state response contained the fake token at `metadata.llm_config.api_key`, `metadata.mcp_configs[0].headers.Authorization`, and `metadata.kb_configs[0].token`. No token value is reproduced here. |
| Interrupt/resume | Thread `01a11a8f-9722-7d71-987d-1b15a3bbcb54`; first `runs/wait` returned `__interrupt__`, state `next=["respond"]`. Resuming with fresh context returned HTTP 200, expected response, and only `mcp_configs`/`kb_configs` context field names. Final state `next=[]`. |
| Resume metadata **failed** | Final state still exposed the initial fake token at `metadata.llm_config.api_key` and the resume fake token at `metadata.mcp_configs[0].token` and `metadata.kb_configs[0].token`. |
| SLIM route | `PLATFORM_URL` points to the stable LAS Service, but SLIM `/ok`, `/threads`, and `/assistants/search` returned HTTP 400 `Request ID not present in header` under the tested requests. Standard request-ID header spellings did not clear this. End-to-end SLIM payload mapping was not established. |

The observed metadata behavior means graph-level redaction is insufficient:
the Agent Server/state API itself must be assessed before credential-bearing
Launchpad context is sent in production. Determine whether a supported LAS
configuration/version can prevent context persistence, or revise the trusted
caller/credential transport and state-access contract. Repeat this exact fake
token check on run and resume under AIP-5402 and AIP-5567 before any
credential-bearing product use.

## Cleanup and remaining work

- Deleted both disposable test threads through LAS (`DELETE` returned HTTP
  204). Database-level cascading deletion was not independently verified.
- Rolled the operator back to image
  `las-poc-20261005-114954-483a832`, removed `las` from the AIPlatform
  feature, and restored `licenseSecretRef: las-auth`. The original AIService UID
  remained unchanged and reached `Ready=True/LASReady` at Helm revision 6;
  API and queue again specify the original `las-sample-agent` image. Deleted
  the temporary offline license Secret. The generated CRD additions remain
  installed and are optional; the old operator is running against them.
- Revoked temporary installer SSH rule `sgr-09210776c41d7c587` and confirmed
  it no longer exists. Refreshed ECR pull Secrets remain; no license value was
  left in the temporary Secret.
- Subsequent acceptance against the revised AIP-5388 criteria is recorded in
  [the candidate acceptance record](aip-5388-candidate-acceptance-20261008.md).
  Resolve checkpoint metadata exposure and the caller-route/credential
  redaction contract under AIP-5402; qualify approval, immutable identity and
  credential handling of the actual Launchpad image under AIP-5567.
- The finding was recorded in AIP-5388 comment `21700075`, AIP-5402 comment
  `21700089`, and AI Tier ERD Confluence version 12. The revised scope appears
  in ERD version 14. Jira evidence comment `21700720` was added; AIP-5388 is
  In Progress pending code review and merge. This original test record remains
  a partial-pass result.
