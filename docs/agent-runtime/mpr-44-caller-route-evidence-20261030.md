# MPR-44 caller-route qualification evidence — 2026-10-30

## Disposition

- **External SLIM caller edge:** **PASS**. A Splunk-authenticated caller created
  a temporary assistant through the public SLIM HTTP route, invoked the
  Launchpad graph twice with Bedrock, received both expected terminal results
  on the same caller session, and deleted the assistant.
- **Authentication and malformed input:** **PASS**. Missing and malformed
  bearer requests were denied, and malformed JSON was rejected.
- **Persistence cleanup:** **PASS**. Direct LAS reads after SLIM deletion
  returned HTTP 404 for both the temporary assistant and the derived thread.
- **Installed AITK application caller:** **NOT_RUN**. The cluster did not have
  an installed AITK/MLTK agent application that could originate this request.
  This evidence qualifies the supported external SLIM contract and downstream
  Launchpad route; it must not be represented as evidence of an installed
  AITK application's own request construction or UI/backend caller.

## Scope and immutable identities

The qualification used the isolated fixture documented in
[`mpr-44-caller-route-qualification.md`](mpr-44-caller-route-qualification.md).
The operator-owned SLIM AIService was not patched or replaced.

| Item | Observed value |
| --- | --- |
| Installer host | `ip-10-0-35-244.splunkcorp.com` |
| Kubernetes context / namespace | `Default` / `ai-platform` |
| Namespace UID | `29d5efa1-04b4-4c95-86dc-992bc3f8761a` |
| Local branch base | `f590502127efaffd4a4688d52c778e059dfb027d` (`origin/agent-runtime/ai-tier`) |
| AIPlatform | `agentruntime-dev-ai-platform`, UID `0ee6ab74-4d45-4fc6-95f9-d563f94e0622`, generation 37, `Ready=True` |
| AgentRuntime AIService | `agentruntime-dev-ai-platform-agentruntime-mltk`, UID `39598b65-89e6-4b32-ba5b-547dc9902036`, generation 21436, `Ready=True` |
| SLIM AIService | `agentruntime-dev-ai-platform-slim`, UID `0acaaa07-59be-4428-8ba8-5fe7fa0392b8`, generation 2435, `Ready=True` |
| Stable LAS Service | `agentruntime-dev-ai-platform-agentruntime-mltk-svc:8080`, ready endpoint observed |
| Selected graph | `agent` |
| Launchpad image | `658391232643.dkr.ecr.us-west-2.amazonaws.com/agent-launchpad:main-00f6ded-20261028` |
| Launchpad running digest | `sha256:5cc1a49d2f3de8cd324e1ce42009216a617f95d162ff05462ac3f1163b63fccb` |
| Candidate image | `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/slim-api:feature-las-202610152102-b7cb6e97e381` |
| Candidate ECR/running digest | `sha256:951ac687c0753399e9a636cd507ec541f55ecaade4717c19276d228115c003ef` |
| Deployed operator digest (not changed) | `sha256:1913af32312218a5343f084e86139cafd674534d8c219ab1bb187a5538794d12` |

ECR resolved the supplied candidate tag to the required digest before the
manifest was applied. The running candidate Pod reported the same digest.
`AGENT_SERVER_URL` pointed to the stable LAS Service and `LAS_GRAPH_ID` was
`agent`.

## Executed checks

| Check | Result | Evidence |
| --- | --- | --- |
| Local caller-helper unit tests | **PASS** | 18 tests; strict scenario validation, auth denials, terminal NDJSON mapping, response-size bounds, no redirects/proxies, exact media type, strict JSON, secret scanning, cleanup, and failure paths |
| Existing LAS runtime helper tests | **PASS** | 13 tests |
| Existing cluster-setup regressions | **PASS** | 303 passed, 0 failed, 0 skipped |
| Candidate manifest server dry-run | **PASS** | Both ConfigMaps, Deployment, and Service accepted by server-side dry-run |
| Candidate health | **PASS** | `/health` returned HTTP 200 with `status=true`; Deployment reached 1/1 Ready and EndpointSlice was ready |
| Candidate OpenAPI | **PASS** | `/service/info/specs/v1alpha1/openapi.json` registered create, invoke, and assistant delete under `/{tenant}/slim-api/v1alpha1/agent/las` |
| Splunk caller identity | **PASS** | A short-lived interactive JWT was minted in memory; current-context returned HTTP 200 with one identity entry |
| Missing bearer | **PASS** | Create was denied with an accepted authentication status |
| Malformed bearer | **PASS** | Create was denied with an accepted authentication status |
| Malformed JSON | **PASS** | Authenticated create rejected the malformed body with an accepted validation status |
| Authenticated assistant create | **PASS** | The public SLIM route returned a UUID runtime ID |
| Bedrock graph invocation | **PASS** | The terminal NDJSON event reported success and contained the expected unique non-secret result marker |
| Same-session follow-up | **PASS** | A second request reused the caller-owned session UUID and returned the expected recalled marker |
| Assistant deletion | **PASS** | SLIM deletion succeeded and a second delete reported the resource absent |
| Direct LAS cleanup confirmation | **PASS** | `GET /assistants/{id}` and `GET /threads/{derived-id}` both returned HTTP 404 |

The sanitized helper result contained these checks:

```text
missing-bearer-denied
malformed-bearer-denied
malformed-json-rejected
authenticated-assistant-create
launchpad-bedrock-session-mapping:call-1
launchpad-bedrock-session-mapping:call-2
launchpad-bedrock-session-mapping:same-session-follow-up
assistant-delete-confirmed
```

The first credential-free `splunk_default` diagnostic reached the authenticated
route but its terminal event reported failure because this cluster does not
provide a Bedrock workload identity to the Launchpad Pod. It was not counted as
an acceptance pass. The successful case used the approved Bedrock connection
shape and repeated the complete transient LLM context on both calls.

## Credential handling

- The Splunk admin password was read from the named Kubernetes Secret into
  process memory only and used to mint a one-hour interactive JWT over a
  loopback-only port-forward.
- The caller JWT was passed to the helper through an inherited pipe file
  descriptor, not a command argument, environment value, or file.
- The supplied Bedrock source credentials were streamed from protected process
  memory over SSH stdin. No scenario or credential file was created locally,
  remotely, or in the repository.
- Access-key, secret-key, role, caller-token, prompt, and response bytes were
  excluded from this record. The helper scanned all inspected HTTP and NDJSON
  bodies and its final evidence object for the declared sensitive values.

The Launchpad image's current `provider=bedrock` path accepts a source access
key and secret, then assumes the configured role. It does not accept a source
AWS session token, so locally assumed temporary source credentials could not be
substituted without changing the product contract.

## Cleanup and residual state

- Candidate Deployment, Service, two ConfigMaps, and `mpr44-ecr-pull` Secret
  were deleted. The final story-label query returned no resources.
- The candidate Pod terminated, all loopback port-forwards stopped, and the
  story-scoped remote temporary directory was removed.
- Temporary assistant `41badd05-2c64-4ce2-ac3b-d0916b5a9534` and derived
  thread `15e08115-4199-57ba-a876-fe33547fe838` both returned HTTP 404 after
  cleanup.
- The exact temporary SSH ingress rule `sgr-0b0430dec2abf96cf` was revoked from
  `sg-09b91f081efe3c4a3`; AWS readback returned an empty result.
- The original Launchpad API and queue Deployments remained 1/1 Ready on
  `agent-launchpad:main-00f6ded-20261028`.
- The primary SLIM Deployment retained image
  `slim-api:202609221216-80c31ac1a210`, with its pre-existing one Ready Pod and
  one Pending Pod. Both AgentRuntime and SLIM AIServices remained `Ready=True`.

## Acceptance note

This run provides a reproducible positive result for the authenticated external
SLIM-to-Launchpad caller contract, including same-session behavior, negative
requests, response mapping, and cleanup. If MPR-44 requires the request to
originate inside the installed AITK application rather than at SLIM's supported
external HTTP edge, that final caller-origin check remains outstanding and
must be recorded separately.
