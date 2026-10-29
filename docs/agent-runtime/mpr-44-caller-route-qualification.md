# MPR-44 Launchpad caller-route qualification

## Purpose and acceptance boundary

This runbook qualifies representative Launchpad requests at SLIM's supported
external HTTP caller boundary:

```text
caller-contract client -> authenticated SLIM HTTP route -> stable LAS Service -> graph agent
```

The SLIM-edge pass condition is a successful product result returned through SLIM's
terminal NDJSON response, followed by a successful call on the same caller
session. Direct Agent Server requests and in-Pod calls to
`slim_api.routers.las_agent` are useful diagnostics, but they do not prove the
HTTP path or caller authentication and cannot satisfy MPR-44 alone.

This helper does not execute an installed AITK application. When the accepted
MPR-44 boundary requires AITK's own request construction or UI/backend caller,
repeat the same reviewed cases from that component and attach its sanitized
evidence. Do not represent the helper's SLIM-edge result as an AITK application
result.

Run this procedure only on the approved integration cluster. The isolated SLIM
candidate creates assistants, threads and runs in the shared LAS dependencies.
Do not use production credentials or a production tenant.

## Immutable identities to record

Record these values before the run and re-read the deployed values afterward:

- splunk-ai-operator source commit and deployed operator image digest;
- Kubernetes context, namespace and namespace UID;
- AIPlatform and AgentRuntime AIService names, generations and Ready conditions;
- Launchpad Agent Server image and Pod `imageID` digest;
- graph ID `agent` and stable LAS Service name;
- SLIM candidate image:
  `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/slim-api:feature-las-202610152102-b7cb6e97e381`;
- required SLIM digest:
  `sha256:951ac687c0753399e9a636cd507ec541f55ecaade4717c19276d228115c003ef`.

The mutable image tag is not evidence. Require both ECR resolution and the
running Pod `imageID` to match the digest.

## Prerequisites

- The operator-owned LAS API and queue workloads are Ready and the stable LAS
  Service has ready endpoints.
- The deployed Launchpad image registers graph `agent`.
- A product-owner-reviewed request and expected outcome are available.
- A short-lived model connection is available for each invocation. Supply the
  complete model/MCP/knowledge-base context again on every follow-up or resume.
- A short-lived Splunk-issued caller bearer is available through an approved
  secure process. The token must pass the configured issuer/current-context
  checks. Record whether this is the actual AITK/product principal or an admin
  integration identity; the latter does not prove least-privilege access.
- The caller bearer, model credentials and scenario are held in memory or in
  owner-controlled permission-restricted temporary files. They must not appear
  in command arguments, shell tracing, repository files or evidence output.
- A fresh story-scoped `mpr44-ecr-pull` Secret is available. Do not reuse an
  expired or unrelated registry Secret.

Disable shell tracing before reading any credential or scenario:

```sh
set +x
```

## Preflight

The following checks are read-only:

```sh
kubectl config current-context
kubectl get namespace ai-platform -o jsonpath='{.metadata.uid}{"\n"}'
kubectl -n ai-platform get aiplatform,aiservice
kubectl -n ai-platform get deployment,service,endpointslice
kubectl -n ai-platform get pods -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,IMAGE_ID:.status.containerStatuses[0].imageID
```

Confirm the configured stable LAS Service in
`tools/cluster_setup/validation/mpr44-slim-candidate.yaml` still matches the
operator-owned AgentRuntime Service. Confirm ECR resolves the supplied tag to
the required digest before applying anything. Abort rather than editing the
manifest live if any identity differs.

Resolve the immutable candidate identity explicitly:

```sh
aws ecr describe-images --region us-west-2 \
  --repository-name ml-platform/slim-api \
  --image-ids imageTag=feature-las-202610152102-b7cb6e97e381 \
  --query 'imageDetails[0].imageDigest' --output text
```

## Deploy the isolated SLIM candidate

The manifest uses separate names and the label
`validation.splunk.com/story=mpr-44`. It does not patch or replace the existing
SLIM AIService. It sets:

- `DEPLOYMENT_TYPE=AITIER`;
- authentication and authorization enabled;
- `AGENT_SERVER_URL` to the stable LAS Service;
- `LAS_GRAPH_ID=agent` explicitly;
- the supplied image pinned by tag and digest.

After securely streaming a fresh ECR token into the temporary
`mpr44-ecr-pull` Secret, run a server-side dry-run and then apply the manifest:

```sh
kubectl apply --server-side --dry-run=server \
  -f tools/cluster_setup/validation/mpr44-slim-candidate.yaml
kubectl apply -f tools/cluster_setup/validation/mpr44-slim-candidate.yaml
kubectl -n ai-platform rollout status deployment/mpr44-slim-candidate --timeout=10m
```

Verify readiness, immutable image identity and the route without printing
environment values or Secrets:

```sh
kubectl -n ai-platform get deployment/mpr44-slim-candidate
kubectl -n ai-platform get pods -l validation.splunk.com/story=mpr-44 \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,IMAGE_ID:.status.containerStatuses[0].imageID
kubectl -n ai-platform get endpointslice \
  -l kubernetes.io/service-name=mpr44-slim-candidate
kubectl -n ai-platform get deployment mpr44-slim-candidate -o json | \
  jq -r '.spec.template.spec.containers[0].env[] |
    select(.name == "AGENT_SERVER_URL" or .name == "LAS_GRAPH_ID") |
    [.name, .value] | @tsv'
```

Start a loopback-only port-forward from the installer host:

```sh
kubectl -n ai-platform port-forward service/mpr44-slim-candidate 18082:8080
```

Check `/health` and
`/service/info/specs/v1alpha1/openapi.json`. The OpenAPI document must register
create, invoke and delete beneath
`/{tenant}/slim-api/v1alpha1/agent/las`. Do not weaken authentication flags to
make the test pass.

## Run the external caller check

`tools/cluster_setup/validation/mpr44_product_caller_acceptance.py` runs outside
the SLIM Pod. It owns the temporary assistant and session IDs, sends the public
double-envelope request, parses the bounded NDJSON response, and deletes the
temporary resources. Its output contains only safe case/check names, generated
non-secret IDs and pass/fail status.

Supply scenario JSON on stdin from the approved secure producer. The logical
shape is:

```json
{
  "scenario_version": 1,
  "sensitive_values": ["<unique credential canary>"],
  "cases": [
    {
      "name": "launchpad-session-mapping",
      "calls": [
        {
          "task_prompt": "Return the approved unique marker exactly.",
          "system_prompt": "Follow the request and answer concisely.",
          "llm": {"<approved short-lived model configuration>": "<in-memory value>"},
          "mcps": [],
          "knowledge_bases": [],
          "expected_text": "<approved unique marker>"
        },
        {
          "task_prompt": "Return the marker from the preceding request.",
          "system_prompt": "Follow the request and answer concisely.",
          "llm": {"<repeat the complete model configuration>": "<in-memory value>"},
          "mcps": [],
          "knowledge_bases": [],
          "expected_text": "<approved unique marker>"
        }
      ]
    }
  ]
}
```

Do not save this example with real values. In the command below,
`secure_scenario_producer` is a placeholder for the approved in-memory secret
producer, not a repository command. Use the helper's protected bearer source
and set the loopback base URL; never put the bearer on the command line. If a
temporary token file is required, create it in an owner-only directory, set
mode `0600`, and remove it immediately after the run:

```sh
secure_scenario_producer | \
  SLIM_BASE_URL=http://127.0.0.1:18082 \
  SLIM_BEARER_TOKEN_FILE=/path/to/permission-restricted/ephemeral-token \
  python3 tools/cluster_setup/validation/mpr44_product_caller_acceptance.py
```

The helper also runs missing-bearer, malformed-bearer and malformed-JSON
negative checks. A transport-level HTTP 200 does not pass an invocation when
the terminal NDJSON event has `success=false` or lacks a completed response.
Sensitive canaries must be absent from every inspected success/error body.

At minimum, retain the sanitized helper result and record:

- assistant creation through the authenticated HTTP route;
- the first expected product response;
- the expected same-session follow-up response;
- terminal response mapping from `Completed.response`;
- safe denial of missing/malformed authentication and malformed JSON;
- successful assistant deletion and its idempotent/not-found confirmation.

For the pinned SLIM candidate, assistant deletion is the documented cascade
operation for its owned threads. The helper verifies only the assistant delete
contract and does not directly query each LAS thread after deletion.
Use the generated session IDs for a direct LAS absence check before claiming
that thread cleanup itself was independently verified.

If direct LAS state is inspected afterward, label it as supporting persistence
evidence. It cannot replace the external caller result.

## Evidence disposition

For every case, record `PASS`, `FAIL`, or `NOT_RUN` and the applicable immutable
identities. A routing, schema or response-mapping failure is a product defect
with a sanitized reproduction; do not convert it to a pass because direct LAS
or an in-Pod router call succeeded.

Never record:

- caller/model/MCP/knowledge-base credentials;
- prompts or model output that may contain customer data;
- Kubernetes Secret data or decoded connection URLs;
- unsanitized HTTP bodies, checkpoints, logs or environment dumps.

## Cleanup

The helper must complete its assistant delete and idempotent/not-found check
before reporting PASS. Stop the port-forward, then delete only the exact
validation resources:

```sh
kubectl delete -f tools/cluster_setup/validation/mpr44-slim-candidate.yaml
kubectl -n ai-platform delete secret mpr44-ecr-pull
kubectl -n ai-platform get all,configmap,secret \
  -l validation.splunk.com/story=mpr-44
```

The final label query must return no resources. Re-run the preflight health
checks and confirm that the primary operator-owned LAS, queue and SLIM workloads
retain their original identities and Ready state. Revoke any temporary SSH
security-group ingress rule by its exact rule ID and verify that it is absent.

If cleanup fails, report the exact resource type/name without Secret values and
do not mark the run complete.

The first execution of this procedure is recorded in
[`mpr-44-caller-route-evidence-20261030.md`](mpr-44-caller-route-evidence-20261030.md).
