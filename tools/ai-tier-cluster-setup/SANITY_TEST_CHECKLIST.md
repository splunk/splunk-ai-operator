# Splunk AI tier Post-Install Sanity Checklist

Use this checklist after `k0s_cluster_with_stack.sh install` to confirm that the
installation completed, the cluster and AI workloads are ready, a model can
serve inference, and the basic Splunk AI Assistant (SAIA) user flow works.

This is a focused acceptance suite, not a performance, upgrade, or security test.

## Prerequisites

- `kubectl`, `jq`, and `curl`
- The kubeconfig and installer configuration used for the deployment
- Access to Splunk Web and a user allowed to open the Splunk AI Assistant app
- The browser-reachable HTTPS URL configured for SAIA

Set these values before starting:

```bash
export KUBECONFIG="<path-to-kubeconfig>"
export CONFIG_FILE="<path-to-cluster-config.yaml>"
export AI_NS=ai-platform
export SAIA_URL="https://<certificate-covered-saia-host>:8443"
```

For a private ingress CA, also set `SAIA_CA_FILE` to the public CA PEM. When the
SAIA certificate is publicly trusted, omit `--cacert "$SAIA_CA_FILE"` from the
client-side `curl` command below. Never use `curl -k`, `--insecure`, or
`verify=False` as an acceptance result.

## Test cases

### SAN-01 — Post-install verifier succeeds

Run the installer's standalone verifier. This is the authoritative check after
the install command: it validates current Pods and expected workload resources,
including Ray workers that may be created after the Ray head becomes ready.

```bash
POD_HEALTH_STABLE_WAIT=1800 \
  CONFIG_FILE="$CONFIG_FILE" \
  tools/ai-tier-cluster-setup/k0s_cluster_with_stack.sh verify-pods
echo "exit_code=$?"
```

Pass criteria:

- Exit code is `0`.
- Output says all Pods are healthy and the Ray, Splunk, and AI Platform
  workloads are Ready.
- The installer log ends with `Your AI Platform is ready to use!` rather than a
  partially-ready or not-ready banner.
- There are no unresolved failure diagnostics in the output.

Evidence: save the command output and the corresponding installer log.

### SAN-02 — Nodes, Pods, containers, and GPUs are ready

```bash
kubectl wait --for=condition=Ready node --all --timeout=10m
kubectl get nodes -o wide
kubectl get pods -A

# This command must print nothing.
kubectl get pods -A -o json |
  jq -r '
    .items[]
    | select(.status.phase != "Succeeded")
    | select(
        .status.phase != "Running" or
        ((.status.containerStatuses // []) | length) !=
          ((.spec.containers // []) | length) or
        any(.status.containerStatuses[]?; .ready != true)
      )
    | "\(.metadata.namespace)/\(.metadata.name) phase=\(.status.phase)"
  '

kubectl get nodes -l splunk.ai/workload-type=gpu -o json |
  jq -e '
    (.items | length) > 0 and
    all(.items[]; ((.status.allocatable["nvidia.com/gpu"] // "0") | tonumber) > 0)
  '
```

Pass criteria:

- Every expected node is `Ready`.
- Every long-running Pod is `Running` with all containers Ready; completed Jobs
  are `Succeeded`/`Completed`.
- No Pod is stuck in `Pending`, `Failed`, `CrashLoopBackOff`,
  `ImagePullBackOff`, or `ErrImagePull`.
- Every expected GPU node reports a non-zero allocatable `nvidia.com/gpu`
  value. Mark this item not applicable only for an intentionally CPU-only
  deployment.

Evidence: attach the node and all-namespace Pod listings.

### SAN-03 — Platform and SAIA workload resources are Ready

```bash
kubectl wait --for=condition=Ready aiplatform --all \
  -n "$AI_NS" --timeout=20m
kubectl wait --for=condition=Ready aiservice --all \
  -n "$AI_NS" --timeout=20m

kubectl get aiplatform,aiservice,raycluster,rayservice \
  -n "$AI_NS" -o wide
# Installer-managed Splunk only:
kubectl get standalone -n "$AI_NS" -o wide
kubectl get aiplatform -n "$AI_NS" -o json |
  jq -r '.items[].status.conditions[] |
    select(.type == "Ready" or .type == "RayServiceReady" or
           .type == "RayClusterReady" or .type == "RayServeRouteReady" or
           .type == "WeaviateDatabaseReady") |
    [.type, .status, .reason] | @tsv'
```

Pass criteria:

- Every `AIPlatform` and `AIService` has `Ready=True`.
- The platform conditions `RayServiceReady`, `RayClusterReady`,
  `RayServeRouteReady`, and `WeaviateDatabaseReady` are `True`.
- Every `RayService` is Ready and its active `RayCluster` has all expected head
  and worker Pods.
- For installer-managed Splunk, the `Standalone` phase is `Ready`. This item is
  not applicable when Splunk is externally managed.

Evidence: attach the resource table and condition output.

### SAN-04 — A deployed model returns inference

First check Ray Serve application and deployment status:

```bash
kubectl get rayservice -n "$AI_NS" -o json |
  jq -r '.items[] |
    [.metadata.name,
     ([.status.conditions[]? | select(.type == "Ready")][0].status // "Unknown"),
     (.status.numServeEndpoints // 0)] | @tsv'

RAY_HEAD="$(kubectl get pods -n "$AI_NS" -l ray.io/node-type=head -o json |
  jq -r '.items[] |
    select(.status.phase == "Running") |
    select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
    .metadata.name' | head -1)"
kubectl exec -n "$AI_NS" "$RAY_HEAD" -c ray-head -- serve status
```

Then port-forward the Ray Serve Service in a separate terminal:

```bash
RAY_SERVE_SERVICE="$(kubectl get service -n "$AI_NS" -o json |
  jq -r '.items[] | select(.metadata.name | endswith("-serve-svc")) |
    .metadata.name' | head -1)"
kubectl port-forward -n "$AI_NS" "service/$RAY_SERVE_SERVICE" 18080:8000
```

With the port-forward running, exercise the default Gemma deployment:

```bash
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  --data '{
    "model":"gemma4_31b_it",
    "messages":[{"role":"user","content":"Reply with the marker SAIA_SANITY_OK"}],
    "temperature":0,
    "max_tokens":32
  }' \
  http://127.0.0.1:18080/gemma4_31b_it/v1/chat/completions |
  jq -e '.choices[0].message.content |
    type == "string" and length > 0 and contains("SAIA_SANITY_OK")'
```

If the deployment uses a different model, select an application reported by
`serve status` and replace both the model ID and route.

Pass criteria:

- Expected Ray Serve applications report `RUNNING` and their deployments
  report `HEALTHY`; none report `DEPLOY_FAILED` or `UNHEALTHY`.
- Every RayService reports `Ready=True` and at least one Serve endpoint.
- The inference request returns HTTP 2xx and a non-empty model response
  containing `SAIA_SANITY_OK`.

Evidence: attach `serve status` and the redacted response. Stop the
port-forward after the test.

### SAN-05 — SAIA is reachable with valid TLS from both required clients

First confirm that the generated public SAIA Service has ready backends:

```bash
SAIA_SERVICE="$(kubectl get service -n "$AI_NS" -o json |
  jq -r '[.items[] | select(.metadata.name | endswith("-saia-service"))][0] |
    .metadata.name')"
kubectl get service "$SAIA_SERVICE" -n "$AI_NS"
kubectl get endpointslice -n "$AI_NS" \
  -l "kubernetes.io/service-name=$SAIA_SERVICE"
```

From an authorized client/browser network:

```bash
curl --fail --silent --show-error \
  --cacert "$SAIA_CA_FILE" \
  "$SAIA_URL/health"
```

For installer-managed Splunk, also run the same verified request from the
Splunk search-head Pod. Replace the Pod name if necessary:

```bash
SPLUNK_POD="$(kubectl get pods -n "$AI_NS" -o json |
  jq -r '.items[] |
    select(.metadata.name | test("^splunk-.*-standalone-0$")) |
    .metadata.name' | head -1)"

kubectl exec -n "$AI_NS" "$SPLUNK_POD" -- \
  env SAIA_URL="$SAIA_URL" \
  /opt/splunk/bin/splunk cmd python3 -c \
  'import os, requests; s=requests.Session(); s.trust_env=False; r=s.get(os.environ["SAIA_URL"] + "/health", timeout=20); print(r.status_code); r.raise_for_status()'
```

For externally managed Splunk, run an equivalent verified request from the
actual search head.

Pass criteria:

- The SAIA Service has at least one ready EndpointSlice address.
- Both requests return HTTP `200` with hostname and certificate validation
  enabled.
- No DNS, routing, certificate, mixed-content, or timeout error occurs.

Evidence: attach both outputs without credentials or tokens.

### SAN-06 — Basic SAIA end-to-end user flow works

For installer-managed Splunk, first inspect the AI Assistant app deployment:

```bash
kubectl get standalone -n "$AI_NS" -o json |
  jq '.items[].status.appContext.appSrcDeployStatus'
```

Then perform the user flow:

1. Sign in to Splunk Web with a fresh session.
2. Open **Splunk AI Assistant → Configuration**, enter `SAIA_URL`, and save.
3. Confirm the onboarding connection test succeeds.
4. Open the assistant and submit this prompt:

   ```text
   Using data models, generate SPL to show the top two users with the most failed login attempts over the past week.
   ```

5. Wait for the streamed response, then refresh or reopen the conversation.

Pass criteria:

- For installer-managed Splunk, the app status has `deployStatus: 3` and
  `isDeploymentInProgress: false`.
- The assistant returns a non-empty response and generated SPL without an
  authentication, TLS, mixed-content, or model error.
- The conversation is present after refresh/reopen.
- The flow works from the real user browser, not only through a Kubernetes
  port-forward.

This final case covers the paths that health checks do not: Splunk search head
to SAIA for setup/v1 calls, browser to SAIA for v2 calls, SAIA token validation
against Splunk, SAIA to Ray model inference, and conversation persistence.

Evidence: attach a timestamped screenshot of the response and restored chat
history. Do not capture JWTs, passwords, HEC tokens, or other credentials.

## Result summary

| Test | Result | Evidence / Notes |
|---|---|---|
| SAN-01 Post-install verifier | Pass / Fail / Blocked | |
| SAN-02 Nodes, Pods, and GPUs | Pass / Fail / Blocked | |
| SAN-03 Workload readiness | Pass / Fail / Blocked | |
| SAN-04 Direct model inference | Pass / Fail / Blocked | |
| SAN-05 Verified SAIA reachability | Pass / Fail / Blocked | |
| SAN-06 SAIA end-to-end flow | Pass / Fail / Blocked | |

Overall sanity testing passes only when all applicable cases pass. A successful
`/health` response alone is not sufficient evidence of model inference or the
end-to-end SAIA user flow.

For deployments using bundled/internal Splunk, the read-only
`tools/ai-tier-cluster-setup/test_internal_splunk_http.sh` provides optional regression
coverage for the existing management/JWT, HEC configuration, injected OTel
collector, and workload path. This diagnostic protects the tested internal
behavior; it does not qualify external HEC/OTel, certify telemetry delivery, or
replace SAN-04 or SAN-06. Because the bundled telemetry path is experimental,
this diagnostic is regression evidence rather than a release support gate.
