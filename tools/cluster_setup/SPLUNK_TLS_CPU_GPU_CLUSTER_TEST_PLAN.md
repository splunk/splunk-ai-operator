# PR #148: Splunk TLS CPU/GPU Cluster Test Plan

## 1. Purpose and scope

This document is the live-cluster acceptance plan for
[PR #148](https://github.com/splunk/splunk-ai-operator/pull/148). It targets
head commit `aa1d40cdff46d2e114223a2b8adc0d66c2c291c4`.

The primary path is a new k0s cluster with installer-managed internal Splunk,
one CPU worker, and two NVIDIA L40S GPU workers. Repeat the platform-independent
TLS cases on EKS and OpenShift after the k0s qualification succeeds.

In scope:

- cert-manager CA and leaf issuance;
- hostname-valid TLS on Splunk management/JWKS (`8089`), HEC (`8088`), and
  Splunk Web (`8000`);
- separate management and HEC endpoints;
- CA trust in SAIA, SLIM, and OpenTelemetry (OTel);
- prevention of Splunk private-key exposure to AI workloads;
- verified HEC delivery;
- CA bundle data rotation and pod-template rollout;
- leaf certificate renewal and controlled-restart behavior;
- CPU/GPU placement, GPU availability, model serving, and telemetry during an
  inference request;
- negative admission and TLS-verification cases.

Out of scope:

- true client-certificate mTLS. The legacy `spec.mtls` field provides
  server-authentication TLS only;
- Traefik HTTPS. PR #148 contains a design document, not its deployment;
- production CA-key rollover. The safe overlap procedure is still manual.

## 2. Test strategy

Run the plan in this order:

1. local/static qualification of the exact PR commit;
2. cluster provisioning and CPU/control-plane qualification;
3. Splunk TLS and workload trust tests;
4. GPU and model-serving qualification;
5. non-disruptive CA bundle rotation;
6. disruptive negative and renewal tests;
7. evidence collection and cleanup.

Do not use a zero installer exit code as the only success signal. At this PR
head, the install path can print partial readiness and still return success.
`verify-pods` must return zero for the full CPU+GPU acceptance run.

A GPU-free run is useful only as a cheaper control-plane/TLS smoke test. The
platform still creates GPU Ray workloads, so full readiness and `verify-pods`
are expected to fail without GPU capacity.

## 3. Required environment

### 3.1 Recommended k0s topology

| Role | Count | Minimum sizing at this PR head | Workload |
|---|---:|---|---|
| Controller | 1 | 4 CPU, 8 GB RAM, 100 GB disk | Kubernetes control plane |
| CPU worker | 1 | 8 CPU, 32 GB RAM, 200 GB disk | Splunk, SAIA/SLIM, Weaviate, Ray head |
| GPU worker | 2 | 48 vCPU, 384 GiB RAM, 500 GB disk, 4 x L40S each | Ray GPU workers and models |

The full default L40S deployment therefore expects eight L40S GPUs. Use the
release BOM if a different model set or accelerator is selected.

The ordered `nodes.existingIPs.workers` list matters: the first
`nodes.cpuWorkers` entries are labeled CPU and all remaining entries are
labeled GPU. Set both counts and list CPU addresses first, even though the
template currently says the counts are not used with `existingIPs`.

### 3.2 Prerequisites

- A disposable cluster or an approved maintenance window.
- RHEL 9 nodes with passwordless SSH and passwordless sudo.
- Inter-node connectivity for TCP `22`, `6443`, `2380`, `10250`, `8132`, and
  `179`, plus UDP `4789`.
- A reachable S3-compatible object store and all model artifacts required by
  the configured artifact manifest.
- Access to every private container image and the Splunk license.
- An approved registry location for the PR operator image.
- On the admin workstation: Bash 4+, `git`, `make`, Go, `kubectl`, `helm`,
  `jq`, `yq`, `openssl`, `curl`, `cmctl`, and SSH.
- An approved CUDA smoke-test image in the private registry.

Never commit cluster credentials, HEC tokens, object-store credentials, test
private keys, or extracted Secret YAML. The evidence below deliberately saves
only public certificates and non-secret metadata.

## 4. Configuration and test variables

Create a clean worktree for the PR. Do not run the test from a dirty checkout.

```bash
git fetch origin pull/148/head:pr-148
git worktree add ../splunk-ai-operator-pr148 pr-148
cd ../splunk-ai-operator-pr148
test "$(git rev-parse HEAD)" = "aa1d40cdff46d2e114223a2b8adc0d66c2c291c4"
```

Build and publish the operator image, then set `images.operator.image` in the
cluster configuration to the same immutable reference.

```bash
export TEST_OPERATOR_IMAGE=<registry>/splunk-ai-operator:pr-148-aa1d40c
make docker-build-amd64 docker-push IMG="$TEST_OPERATOR_IMAGE"
```

Copy `k0s-cluster-config.yaml` to a private, ignored file and configure at
least the following shape:

```yaml
cluster:
  useExisting: auto  # permits safe installer reconciliation on a rerun

nodes:
  controllers: 1
  cpuWorkers: 1
  gpuWorkers: 2
  existingIPs:
    controllers:
      - <controller-ip>
    workers:
      - <cpu-worker-ip>   # CPU entries must come first
      - <gpu-worker-1-ip>
      - <gpu-worker-2-ip>

splunk:
  enabled: true
  standaloneName: splunk-standalone
  # Do not set splunk.external for this internal-Splunk run.

aiPlatform:
  defaultAcceleratorType: L40S
  features:
    - name: saia
      version: "1.1.0"
    - name: slim
      version: "1.0.0"
```

Also configure the object store, every image, SSH settings, storage class, and
model staging. Derive the model count and expected completion markers from the
artifact YAML; do not hard-code the older documentation's count of ten.

After installation, initialize reusable variables:

```bash
export AI_NS=ai-platform
export STANDALONE=splunk-standalone
export AI_PLATFORM="$(kubectl -n "$AI_NS" get aiplatform -o jsonpath='{.items[0].metadata.name}')"
export SPLUNK_SERVICE="splunk-${STANDALONE}-standalone-service"
export SPLUNK_FQDN="${SPLUNK_SERVICE}.${AI_NS}.svc.cluster.local"
export SPLUNK_SECRET="splunk-${STANDALONE}-standalone-secret-v1"
export SPLUNK_POD="splunk-${STANDALONE}-standalone-0"
export EVIDENCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/splunk-ai-operator-pr148-tls.XXXXXX")"
```

If the cluster uses a non-default DNS domain, replace `cluster.local` above.
Treat custom-domain testing as a separate known-gap case; propagation is not
complete at this PR head.

## 5. Test cases

Record each result as `PASS`, `FAIL`, `BLOCKED`, or `EXPECTED GAP`, with the
timestamp, tester, cluster identity, PR SHA, and evidence filename.

### TLS-LOCAL-01: Exact-head automated tests

Run:

```bash
make test
make check-crd-artifacts
bash tools/cluster_setup/test_installer_dry_run.sh
bash tools/cluster_setup/test_k0s_cluster_with_stack.sh
bash tools/cluster_setup/test_eks_with_stack.sh
bash tools/cluster_setup/test_openshift_with_stack.sh
```

Expected result:

- all commands exit zero;
- generated CRD copies match the canonical CRDs;
- installer render tests confirm standard Secret outputs only, separate
  `8089`/`8088` endpoints, CA projection, and TLS configuration.

### TLS-INSTALL-01: Validate and install the CPU/GPU cluster

Run:

```bash
cd tools/cluster_setup
CONFIG_FILE=./<private-test-config>.yaml ./k0s_cluster_with_stack.sh validate
CONFIG_FILE=./<private-test-config>.yaml ./k0s_cluster_with_stack.sh install
CONFIG_FILE=./<private-test-config>.yaml ./k0s_cluster_with_stack.sh verify-pods
```

Expected result:

- validation and installation exit zero;
- `verify-pods` exits zero for the full CPU+GPU run;
- no pod is in `Pending`, `CrashLoopBackOff`, `ImagePullBackOff`, or
  `CreateContainerConfigError` after the documented startup window.

Save:

```bash
kubectl get nodes -o wide > "$EVIDENCE_DIR/nodes.txt"
kubectl get pods -A -o wide > "$EVIDENCE_DIR/pods.txt"
kubectl -n "$AI_NS" get aiplatform,aiservice,rayservice,standalone > "$EVIDENCE_DIR/workloads.txt"
kubectl get events -A --sort-by=.lastTimestamp > "$EVIDENCE_DIR/events.txt"
```

### TLS-NODE-01: CPU/GPU classification and capacity

Run:

```bash
kubectl get nodes -L splunk.ai/workload-type,nvidia.com/gpu
kubectl get nodes -l splunk.ai/workload-type=gpu -o json |
  jq -e '.items | length == 2 and all(.[]; ((.status.allocatable["nvidia.com/gpu"] // "0") | tonumber) == 4)'
kubectl -n kube-system get pods -o wide | grep nvidia-device-plugin
```

Expected result:

- exactly one CPU worker and two GPU workers have the intended labels;
- each GPU worker advertises four `nvidia.com/gpu` resources;
- device-plugin pods are running on both GPU nodes;
- non-GPU workloads are not unintentionally placed on GPU-only nodes.

### TLS-CERT-01: Certificate resources and policy

Run:

```bash
kubectl -n "$AI_NS" get issuer ai-splunk-selfsigned ai-splunk-ca-issuer
kubectl -n "$AI_NS" get certificate ai-splunk-ca ai-splunk-server
kubectl -n "$AI_NS" wait --for=condition=Ready certificate/ai-splunk-ca --timeout=180s
kubectl -n "$AI_NS" wait --for=condition=Ready certificate/ai-splunk-server --timeout=180s
kubectl -n "$AI_NS" get certificate ai-splunk-ca -o json |
  jq -e '(.spec.duration | test("^87600h(0m0s)?$")) and
    (.spec.renewBefore | test("^8760h(0m0s)?$")) and
    .spec.privateKey.rotationPolicy == "Never"'
kubectl -n "$AI_NS" get certificate ai-splunk-server -o json |
  jq -e '(.spec.duration | test("^2160h(0m0s)?$")) and
    (.spec.renewBefore | test("^720h(0m0s)?$")) and
    .spec.privateKey.rotationPolicy == "Always"'
```

Expected result: both Certificates are Ready; the CA is a stable ten-year
ECDSA trust anchor, and the leaf is a 90-day RSA certificate renewed 30 days
early with a new key.

### TLS-CERT-02: Leaf Secret contract and certificate contents

Run:

```bash
kubectl -n "$AI_NS" get secret ai-splunk-server-tls -o json |
  jq -e '.data as $d | ["tls.crt","tls.key","ca.crt"] | all(.[]; ($d[.] // "") != "")'
kubectl -n "$AI_NS" get secret ai-splunk-server-tls -o json |
  jq -e '(.data["tls-combined.pem"] // null) == null'

kubectl -n "$AI_NS" get secret ai-splunk-server-tls \
  -o jsonpath='{.data.ca\.crt}' | openssl base64 -d -A > "$EVIDENCE_DIR/splunk-ca.crt"
kubectl -n "$AI_NS" get secret ai-splunk-server-tls \
  -o jsonpath='{.data.tls\.crt}' | openssl base64 -d -A |
  openssl x509 -noout -subject -issuer -dates -serial -ext subjectAltName -ext extendedKeyUsage \
  > "$EVIDENCE_DIR/splunk-leaf.txt"
```

Expected result:

- the Secret contains `tls.crt`, `tls.key`, and `ca.crt`;
- `tls-combined.pem` is absent, so no cert-manager alpha feature gate is
  required;
- SANs include the service short name and FQDN used by the AIPlatform;
- extended key usage includes server and client authentication.

Do not extract or save `tls.key`.

### TLS-ENDPOINT-01: Verified TLS on ports 8089, 8088, and 8000

In a separate terminal, keep this port-forward running:

```bash
kubectl -n "$AI_NS" port-forward "service/$SPLUNK_SERVICE" 18089:8089 18088:8088 18000:8000
```

In the test terminal, run:

```bash
openssl s_client -connect 127.0.0.1:18089 -servername "$SPLUNK_FQDN" \
  -verify_hostname "$SPLUNK_FQDN" -CAfile "$EVIDENCE_DIR/splunk-ca.crt" \
  -verify_return_error </dev/null
openssl s_client -connect 127.0.0.1:18088 -servername "$SPLUNK_FQDN" \
  -verify_hostname "$SPLUNK_FQDN" -CAfile "$EVIDENCE_DIR/splunk-ca.crt" \
  -verify_return_error </dev/null
openssl s_client -connect 127.0.0.1:18000 -servername "$SPLUNK_FQDN" \
  -verify_hostname "$SPLUNK_FQDN" -CAfile "$EVIDENCE_DIR/splunk-ca.crt" \
  -verify_return_error </dev/null
```

Expected result: every command exits zero and reports certificate verification
code `0`. A hostname mismatch, untrusted chain, plaintext listener, or wrong
certificate is a failure.

### TLS-CR-01: AIPlatform endpoint and CA wiring

Run:

```bash
kubectl -n "$AI_NS" get aiplatform "$AI_PLATFORM" -o json |
  jq -e --arg ns "$AI_NS" --arg fqdn "$SPLUNK_FQDN" '
    .spec.splunkConfiguration.endpoint == ("https://" + $fqdn + ":8089") and
    .spec.splunkConfiguration.hecEndpoint == ("https://" + $fqdn + ":8088") and
    .spec.splunkConfiguration.caCertRef.name == "ai-splunk-server-tls" and
    .spec.splunkConfiguration.caCertRef.namespace == $ns and
    .spec.splunkConfiguration.caCertRef.key == "ca.crt"'
```

Expected result: management/JWKS uses `8089`, HEC uses `8088`, and the CA
reference is same-namespace and selects only `ca.crt`.

### TLS-SECRET-01: No Splunk private key in AI workloads

First confirm the expected Splunk Standalone pod exists, then inspect every
other pod. Excluding the exact pod avoids relying on labels that the Splunk
Operator does not guarantee will equal the Standalone CR name.

```bash
kubectl -n "$AI_NS" get pod "$SPLUNK_POD"

kubectl -n "$AI_NS" get pods -o json |
  jq -e --arg splunkPod "$SPLUNK_POD" '
    [
      .items[]
      | select(.metadata.name != $splunkPod)
      | .spec.volumes[]?
      | select(.secret.secretName == "ai-splunk-server-tls")
      | (.secret.items // [] | map(.key))
    ] as $projections
    | ($projections | length) > 0
      and all($projections[]; length == 1 and .[0] == "ca.crt")'
```

Also inspect SAIA and SLIM Deployment specs:

```bash
kubectl -n "$AI_NS" get deployments -o json |
  jq -e '
    [
      .items[]
      | select(.metadata.name | test("saia|slim"))
      | .spec.template.spec.volumes[]?
      | select(.secret.secretName == "ai-splunk-server-tls")
      | (.secret.items // [] | map(.key))
    ]
    | length > 0 and all(.[]; length == 1 and .[0] == "ca.crt")'
```

Expected result: every non-Splunk projection contains only `ca.crt`; no AI or
OTel container receives `tls.key`. Splunk itself is expected to mount the leaf
certificate and key.

### TLS-TRUST-01: SAIA/SLIM merged trust store

Require all four CA-consuming SAIA/SLIM Deployments, then run the checks in
each one:

```bash
mapfile -t CA_CONSUMER_DEPLOYMENTS < <(
  kubectl -n "$AI_NS" get deployment -o json |
    jq -r '.items[].metadata.name |
      select(test("(saia-deployment|saia-v2-deployment|saia-v2-worker|slim-deployment)$"))'
)
test "${#CA_CONSUMER_DEPLOYMENTS[@]}" -eq 4

for deployment in "${CA_CONSUMER_DEPLOYMENTS[@]}"; do
  kubectl -n "$AI_NS" exec "deployment/$deployment" -- sh -c '
    test "$REQUESTS_CA_BUNDLE" = /etc/splunk-ca-combined/ca-certificates.crt &&
    test "$SSL_CERT_FILE" = /etc/splunk-ca-combined/ca-certificates.crt &&
    test -s /etc/splunk-ca-combined/ca-certificates.crt &&
    test ! -e /etc/splunk-ca/tls.key &&
    awk "/BEGIN CERTIFICATE/{n++} END{exit !(n > 1)}" /etc/splunk-ca-combined/ca-certificates.crt'
done
```

Expected result: the private CA is combined with the image's system roots;
public-root trust is retained, and the Splunk private key is absent.

### TLS-OTEL-01: Secure OTel configuration and projection

Run only field-specific queries; do not dump the full ConfigMap because the
current implementation also contains the HEC token.

```bash
kubectl -n "$AI_NS" get configmap "${AI_PLATFORM}-otel-config" \
  -o jsonpath='{.data.otel-config\.yaml}' |
  yq eval '.exporters.splunk_hec.endpoint,
           .exporters.splunk_hec.tls.insecure_skip_verify,
           .exporters.splunk_hec.tls.ca_file' -

kubectl -n "$AI_NS" get opentelemetrycollector "${AI_PLATFORM}-otel-coll" -o json |
  jq -e '
    .spec.volumes[]
    | select(.secret.secretName == "ai-splunk-server-tls")
    | (.secret.items | length == 1 and .secret.items[0].key == "ca.crt")'
```

Expected result:

- exporter endpoint is `https://<Splunk FQDN>:8088/services/collector`;
- `insecure_skip_verify` is `false`;
- `ca_file` is `/etc/splunk-ca/ca.crt`;
- exactly one public CA key is projected.

### TLS-HEC-01: Send and find a verified HEC event

With the port-forward still active:

```bash
HEC_TOKEN="$(kubectl -n "$AI_NS" get secret "$SPLUNK_SECRET" \
  -o jsonpath='{.data.hec_token}' | openssl base64 -d -A)"
EVENT_ID="pr148-tls-$(date +%s)"

HEC_RESPONSE="$(curl --fail --silent --show-error \
  --cacert "$EVIDENCE_DIR/splunk-ca.crt" \
  --resolve "$SPLUNK_FQDN:18088:127.0.0.1" \
  -H "Authorization: Splunk $HEC_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"event\":\"$EVENT_ID\",\"source\":\"pr148-tls-test\"}" \
  "https://$SPLUNK_FQDN:18088/services/collector/event")"
jq -e '.code == 0' <<<"$HEC_RESPONSE"

unset HEC_TOKEN

SPLUNK_PASSWORD="$(kubectl -n "$AI_NS" get secret "$SPLUNK_SECRET" \
  -o jsonpath='{.data.password}' | openssl base64 -d -A)"
SEARCH_FOUND=false
for attempt in {1..30}; do
  if SEARCH_RESPONSE="$(curl --fail --silent --show-error \
      --cacert "$EVIDENCE_DIR/splunk-ca.crt" \
      --resolve "$SPLUNK_FQDN:18089:127.0.0.1" \
      --user "admin:$SPLUNK_PASSWORD" \
      --data-urlencode "search=search index=* source=\"pr148-tls-test\" \"$EVENT_ID\" earliest=-5m latest=now | head 1" \
      --data 'output_mode=json' \
      "https://$SPLUNK_FQDN:18089/services/search/jobs/export")" &&
      jq -se --arg event "$EVENT_ID" \
        'any(.[]; ((.result // {}) | tostring | contains($event)))' \
        <<<"$SEARCH_RESPONSE"; then
    SEARCH_FOUND=true
    break
  fi
  sleep 5
done
unset SPLUNK_PASSWORD
test "$SEARCH_FOUND" = true
```

Expected result: HEC returns code `0`, and an authorized Splunk search finds
`EVENT_ID`. Do not save or print the token.

### TLS-JWKS-01: JWKS retrieval through verified TLS

Run:

```bash
curl --fail --silent --show-error \
  --cacert "$EVIDENCE_DIR/splunk-ca.crt" \
  --resolve "$SPLUNK_FQDN:18089:127.0.0.1" \
  "https://$SPLUNK_FQDN:18089/.well-known/oauth2_keys" |
  jq -e '.keys | length > 0'

if kubectl -n "$AI_NS" logs deployment/<saia-v2-deployment> --since=15m |
  grep -iE 'certificate_verify_failed|unknown authority|hostname mismatch'; then
  echo "FAIL: SAIA reported a TLS verification error"
  exit 1
fi
```

Expected result: the JWKS document contains at least one key, and SAIA does
not report TLS verification errors.

### TLS-GPU-01: Schedule a one-GPU smoke job

Set `GPU_SMOKE_IMAGE` to an approved CUDA image that contains `nvidia-smi`.

```bash
export GPU_SMOKE_IMAGE=<private-registry>/cuda-smoke:<tag>
kubectl -n "$AI_NS" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: pr148-gpu-smoke
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      runtimeClassName: nvidia
      nodeSelector:
        splunk.ai/workload-type: gpu
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: nvidia-smi
          image: ${GPU_SMOKE_IMAGE}
          command: ["nvidia-smi"]
          resources:
            limits:
              nvidia.com/gpu: 1
YAML
kubectl -n "$AI_NS" wait --for=condition=Complete job/pr148-gpu-smoke --timeout=300s
kubectl -n "$AI_NS" logs job/pr148-gpu-smoke > "$EVIDENCE_DIR/gpu-smoke.txt"
```

Expected result: the Job completes on a GPU node and reports the assigned GPU.

### TLS-GPU-02: Ray GPU placement and readiness

Run:

```bash
kubectl -n "$AI_NS" get rayservice -o wide
kubectl -n "$AI_NS" get pods -l ray.io/node-type=worker -o wide
kubectl -n "$AI_NS" get pods -o json |
  jq -r '
    .items[]
    | select(any(.spec.containers[]?;
        ((.resources.limits["nvidia.com/gpu"] // "0") | tonumber) > 0))
    | [.metadata.name, .spec.nodeName, .status.phase] | @tsv'
```

Expected result: RayServices are running/ready, every GPU-requesting pod is
Running on a GPU-labeled node, and model replicas become healthy after their
documented loading window.

### TLS-GPU-03: End-to-end inference plus telemetry

First exercise Ray Serve directly as the deterministic GPU/model gate. Select
the Serve Service for the model RayService if the namespace contains more than
one candidate.

```bash
RAY_SERVE_SERVICE="$(kubectl -n "$AI_NS" get service -o json |
  jq -r '.items[] | select(.metadata.name | endswith("-serve-svc")) |
    .metadata.name' | head -1)"
kubectl -n "$AI_NS" port-forward "service/$RAY_SERVE_SERVICE" 18080:8000
```

With the port-forward active in a separate terminal:

```bash
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  --data '{
    "model":"gemma4_31b_it",
    "messages":[{"role":"user","content":"Reply with exactly PR148_GPU_OK"}],
    "temperature":0,
    "max_tokens":32
  }' \
  http://127.0.0.1:18080/gemma4_31b_it/v1/chat/completions |
  tee "$EVIDENCE_DIR/ray-serve-response.json" |
  jq -e '.choices[0].message.content |
    gsub("^\\s+|\\s+$"; "") == "PR148_GPU_OK"'
```

Then use the product-supported SAIA request for the installed version. Set the
externally reachable SAIA URL and obtain a short-lived Splunk JWT without
printing it.

```bash
export SAIA_BASE_URL=<approved-saia-url>
export SPLUNK_JWT=<short-lived-token>
REQUEST_ID="pr148-gpu-$(date +%s)"

curl --fail --silent --show-error \
  -H "Authorization: Bearer $SPLUNK_JWT" \
  -H 'Content-Type: application/json' \
  -H "X-Request-ID: $REQUEST_ID" \
  --data @<approved-saia-request-body.json> \
  "$SAIA_BASE_URL/<supported-query-path>" \
  > "$EVIDENCE_DIR/inference-response.json"

unset SPLUNK_JWT
```

Expected result:

- a model-backed response is returned successfully;
- a GPU worker shows activity during the request;
- the corresponding OTel event/trace/metric is searchable in Splunk through
  the HTTPS HEC path;
- SAIA, Ray, and OTel logs contain no TLS verification errors.

### TLS-ROTATE-01: Same-Secret CA data rotation with overlap

This is the safe live rotation test. It does not modify a cert-manager-owned
Secret or remove the currently trusted CA.

1. Copy the current public CA to a test Secret and point the AIPlatform to it.
2. Append a second test CA to the same Secret, retaining the original CA.
3. Verify that data-only Secret change rolls every CA consumer.
4. Restore the installer-managed reference.

```bash
cp "$EVIDENCE_DIR/splunk-ca.crt" "$EVIDENCE_DIR/rotation-ca-before.pem"
ROTATION_TMP="$(mktemp -d)"
kubectl -n "$AI_NS" create secret generic splunk-ca-rotation-test \
  --from-file=ca.crt="$EVIDENCE_DIR/rotation-ca-before.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$AI_NS" patch aiplatform "$AI_PLATFORM" --type=merge -p \
  "{\"spec\":{\"splunkConfiguration\":{\"caCertRef\":{\"name\":\"splunk-ca-rotation-test\",\"namespace\":\"$AI_NS\",\"key\":\"ca.crt\"}}}}"

# Wait until SAIA/SLIM and Ray are stable, then capture their pod identities.
kubectl -n "$AI_NS" get pods -o json |
  jq -r '.items[] | select(.metadata.annotations["splunk-ai-operator/splunk-ca-hash"] != null) |
    [.metadata.name,.metadata.uid,.metadata.annotations["splunk-ai-operator/splunk-ca-hash"]] | @tsv' \
  > "$EVIDENCE_DIR/ca-consumers-before.tsv"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj '/CN=pr148-overlap-test-only' \
  -keyout "$ROTATION_TMP/overlap-test.key" \
  -out "$ROTATION_TMP/overlap-test.crt"
cat "$EVIDENCE_DIR/rotation-ca-before.pem" "$ROTATION_TMP/overlap-test.crt" \
  > "$EVIDENCE_DIR/rotation-ca-overlap.pem"

kubectl -n "$AI_NS" create secret generic splunk-ca-rotation-test \
  --from-file=ca.crt="$EVIDENCE_DIR/rotation-ca-overlap.pem" \
  --dry-run=client -o yaml | kubectl apply -f -
```

After reconciliation completes, capture the same table again and repeat
`TLS-ENDPOINT-01`, `TLS-HEC-01`, and `TLS-GPU-03`.

```bash
kubectl -n "$AI_NS" get pods -o json |
  jq -r '.items[] | select(.metadata.annotations["splunk-ai-operator/splunk-ca-hash"] != null) |
    [.metadata.name,.metadata.uid,.metadata.annotations["splunk-ai-operator/splunk-ca-hash"]] | @tsv' \
  > "$EVIDENCE_DIR/ca-consumers-after.tsv"
```

Expected result:

- the Secret name stays the same and only `.data.ca.crt` changes;
- the CA hash changes;
- SAIA v1/v2/worker, SLIM, Ray head, and all OTel-enabled Ray workers are
  replaced or rolled;
- TLS, HEC, JWKS, and inference remain functional because the original CA is
  retained during overlap.

Restore:

```bash
kubectl -n "$AI_NS" patch aiplatform "$AI_PLATFORM" --type=merge -p \
  "{\"spec\":{\"splunkConfiguration\":{\"caCertRef\":{\"name\":\"ai-splunk-server-tls\",\"namespace\":\"$AI_NS\",\"key\":\"ca.crt\"}}}}"
```

Delete the test Secret and the test private key only after all workloads are
stable on the restored reference.

### TLS-ROTATE-02: Equivalent CA bytes under a different reference

This is a defect-reproduction case at PR head, not a pass criterion.

Point `caCertRef` from `ai-splunk-server-tls/ca.crt` to another Secret/key that
contains identical CA bytes. SAIA and SLIM should roll because their volume
spec changes. The Ray OTel hash currently covers only CA bytes, not Secret name
or key, so existing admission-injected OTel sidecars may keep the old Secret
reference until another event recreates the pods.

Expected result at `aa1d40c`: `EXPECTED GAP`. Record Ray pod UIDs, the live
sidecar volume source, and the unchanged hash. A complete fix must hash the
reference identity and key as well as the bytes.

### TLS-RENEW-01: Leaf renewal and served-certificate adoption

This case is disruptive and must run only on the disposable test cluster or in
an approved maintenance window.

Before renewal, record the Secret UID/resourceVersion, leaf serial/fingerprint,
CA fingerprint, private-key hash without saving the key, Certificate revision,
and the serial served by port `8089`.

```bash
capture_renewal_state() {
  local phase="$1"

  kubectl -n "$AI_NS" get secret ai-splunk-server-tls \
    -o jsonpath='{.metadata.uid}{"\t"}{.metadata.resourceVersion}{"\n"}' \
    > "$EVIDENCE_DIR/renew-secret-$phase.txt"
  kubectl -n "$AI_NS" get secret ai-splunk-server-tls \
    -o jsonpath='{.data.tls\.crt}' | openssl base64 -d -A |
    openssl x509 -noout -serial -fingerprint -sha256 \
    > "$EVIDENCE_DIR/renew-leaf-$phase.txt"
  kubectl -n "$AI_NS" get secret ai-splunk-server-tls \
    -o jsonpath='{.data.ca\.crt}' | openssl base64 -d -A |
    openssl x509 -noout -fingerprint -sha256 \
    > "$EVIDENCE_DIR/renew-ca-$phase.txt"
  kubectl -n "$AI_NS" get secret ai-splunk-server-tls \
    -o jsonpath='{.data.tls\.key}' | openssl base64 -d -A |
    openssl dgst -sha256 > "$EVIDENCE_DIR/renew-key-hash-$phase.txt"
  kubectl -n "$AI_NS" get certificate ai-splunk-server \
    -o jsonpath='{.status.revision}{"\n"}' \
    > "$EVIDENCE_DIR/renew-revision-$phase.txt"
  openssl s_client -connect 127.0.0.1:18089 \
    -servername "$SPLUNK_FQDN" \
    -CAfile "$EVIDENCE_DIR/splunk-ca.crt" </dev/null 2>/dev/null |
    openssl x509 -noout -serial \
    > "$EVIDENCE_DIR/renew-served-$phase.txt"
  kubectl -n "$AI_NS" get secret ai-splunk-server-tls -o json |
    jq -e '.data | keys | sort == ["ca.crt", "tls.crt", "tls.key"]'
}

capture_renewal_state before
BEFORE_REVISION="$(<"$EVIDENCE_DIR/renew-revision-before.txt")"
BEFORE_SERIAL="$(sed -n 's/^serial=//p' "$EVIDENCE_DIR/renew-leaf-before.txt")"
[[ "$BEFORE_REVISION" =~ ^[0-9]+$ && -n "$BEFORE_SERIAL" ]]

cmctl renew ai-splunk-server -n "$AI_NS"

RENEWED=false
for attempt in {1..60}; do
  CURRENT_REVISION="$(kubectl -n "$AI_NS" get certificate ai-splunk-server \
    -o jsonpath='{.status.revision}' 2>/dev/null || true)"
  CURRENT_SERIAL="$(kubectl -n "$AI_NS" get secret ai-splunk-server-tls \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | openssl base64 -d -A 2>/dev/null |
    openssl x509 -noout -serial 2>/dev/null | sed -n 's/^serial=//p' || true)"
  if [[ "$CURRENT_REVISION" =~ ^[0-9]+$ ]] &&
      (( CURRENT_REVISION > BEFORE_REVISION )) &&
      [[ -n "$CURRENT_SERIAL" && "$CURRENT_SERIAL" != "$BEFORE_SERIAL" ]]; then
    RENEWED=true
    break
  fi
  sleep 3
done
test "$RENEWED" = true

capture_renewal_state after-renewal

IFS=$'\t' read -r BEFORE_UID BEFORE_RESOURCE_VERSION \
  < "$EVIDENCE_DIR/renew-secret-before.txt"
IFS=$'\t' read -r AFTER_UID AFTER_RESOURCE_VERSION \
  < "$EVIDENCE_DIR/renew-secret-after-renewal.txt"
AFTER_REVISION="$(<"$EVIDENCE_DIR/renew-revision-after-renewal.txt")"

test "$AFTER_UID" = "$BEFORE_UID"
test "$AFTER_RESOURCE_VERSION" != "$BEFORE_RESOURCE_VERSION"
(( AFTER_REVISION > BEFORE_REVISION ))
! cmp -s "$EVIDENCE_DIR/renew-leaf-before.txt" \
  "$EVIDENCE_DIR/renew-leaf-after-renewal.txt"
! cmp -s "$EVIDENCE_DIR/renew-key-hash-before.txt" \
  "$EVIDENCE_DIR/renew-key-hash-after-renewal.txt"
cmp -s "$EVIDENCE_DIR/renew-ca-before.txt" \
  "$EVIDENCE_DIR/renew-ca-after-renewal.txt"
```

The loop deliberately polls revision and leaf serial rather than only waiting
for `Ready`, which may remain true while reissuance is in progress.

Expected immediately after cert-manager renewal:

- same Secret name and UID, new resourceVersion;
- changed leaf serial/fingerprint and private-key hash;
- unchanged CA fingerprint;
- exactly the standard three Secret keys remain.

Known behavior at this PR head: the live Splunk endpoint continues serving the
old serial because the memory-backed `server.pem` is built only at pod startup
and no automatic Standalone restart/reload trigger exists. Confirm and record
this as `EXPECTED GAP`, then perform a controlled StatefulSet restart:

```bash
cmp -s "$EVIDENCE_DIR/renew-served-before.txt" \
  "$EVIDENCE_DIR/renew-served-after-renewal.txt"

SPLUNK_STATEFULSET="$(kubectl -n "$AI_NS" get pod "$SPLUNK_POD" \
  -o jsonpath='{.metadata.ownerReferences[?(@.kind=="StatefulSet")].name}')"
test -n "$SPLUNK_STATEFULSET"
kubectl -n "$AI_NS" rollout restart "statefulset/$SPLUNK_STATEFULSET"
kubectl -n "$AI_NS" rollout status "statefulset/$SPLUNK_STATEFULSET" \
  --timeout=15m

openssl s_client -connect 127.0.0.1:18089 \
  -servername "$SPLUNK_FQDN" \
  -CAfile "$EVIDENCE_DIR/splunk-ca.crt" </dev/null 2>/dev/null |
  openssl x509 -noout -serial \
  > "$EVIDENCE_DIR/renew-served-after-restart.txt"

RENEWED_SECRET_SERIAL="$(sed -n 's/^serial=//p' \
  "$EVIDENCE_DIR/renew-leaf-after-renewal.txt")"
RESTARTED_SERVED_SERIAL="$(sed -n 's/^serial=//p' \
  "$EVIDENCE_DIR/renew-served-after-restart.txt")"
test "$RESTARTED_SERVED_SERIAL" = "$RENEWED_SECRET_SERIAL"
```

Finally repeat `TLS-ENDPOINT-01`; the served certificate must match the renewed
Secret and remain valid for the service hostname.

### TLS-NEG-01: Cross-namespace CA reference is rejected

Use server-side dry-run so the live object is not changed:

```bash
if kubectl -n "$AI_NS" patch aiplatform "$AI_PLATFORM" \
  --type=merge --dry-run=server -p \
  '{"spec":{"splunkConfiguration":{"caCertRef":{"name":"some-ca","namespace":"other-namespace","key":"ca.crt"}}}}'; then
  echo "FAIL: cross-namespace caCertRef was admitted"
  exit 1
fi
```

Expected result: admission rejects the request. Repeat against a directly
created AIService if that API is in the qualification scope.

### TLS-NEG-02: Wrong CA fails closed

Create a wrong public CA Secret, point the AIPlatform at it, and verify that
JWKS/HEC calls fail with certificate errors. Do not replace the data in
`ai-splunk-server-tls`. Restore the original reference immediately and wait
for every workload to recover.

Expected result:

- no component falls back to `insecure_skip_verify`;
- SAIA/JWKS and OTel/HEC report verification failure;
- restoration rolls the consumers and returns them to Ready.

### TLS-NEG-03: HEC-only OTel configuration

This is a current defect-reproduction case. A configuration containing only
`hecEndpoint + secretRef` is admitted and creates an OTel Collector, but Ray
sidecar injection currently checks `endpoint` or `splunkCustomResourceRef`
instead of `hecEndpoint`. No OTel sidecar is injected.

Expected result at `aa1d40c`: `EXPECTED GAP`. A fix must include
`hecEndpoint` in the Ray injection gate and add a live regression test.

### TLS-SEC-01: OTel credential storage and rotation

Without printing the token, compare the HEC Secret value with the managed OTel
ConfigMap and inspect whether a data-only HEC Secret update triggers reconcile
and process adoption.

Expected result at `aa1d40c`: `EXPECTED GAP`.

- the HEC token is embedded literally in the ConfigMap/Collector spec;
- only CA Secrets have an explicit data-change watch;
- an in-place HEC token rotation is not guaranteed to update/restart OTel.

This should be resolved or explicitly risk-accepted before production use.

## 6. Cross-platform matrix

After k0s passes, rerun the applicable cases on EKS and OpenShift.

| Platform | Required cases | Additional focus |
|---|---|---|
| k0s | All cases | Primary CPU/GPU and rotation qualification |
| EKS | CERT, ENDPOINT, CR, SECRET, TRUST, OTEL, HEC, GPU, ROTATE, RENEW | cert-manager Helm v1.18 path and EKS GPU scheduling |
| OpenShift | CERT, ENDPOINT, CR, SECRET, TRUST, OTEL, HEC, ROTATE, RENEW | SCC behavior and hard-coded `cluster.local` limitation |

Do not use the existing `test/e2e/cluster-e2e-test.sh` as the sole PR
acceptance test. At this PR head it does not exercise `caCertRef` or rotation,
uses an obsolete accelerator value, and omits `hecEndpoint` while OTel defaults
to enabled.

## 7. Exit criteria

The live qualification passes only when all of the following are true:

- exact-head local and installer tests pass;
- full CPU+GPU `verify-pods` exits zero;
- certificates are Ready and all three Splunk listeners verify hostname and CA;
- management/JWKS uses `8089`, HEC uses `8088`, and no fallback is observed;
- no non-Splunk workload receives `tls.key`;
- SAIA/SLIM retain system roots and trust the private Splunk CA;
- OTel uses `insecure_skip_verify: false`, the projected CA, and verified HEC;
- a unique HEC event and a GPU-backed inference are both observable in Splunk;
- a same-Secret CA data update rolls every intended consumer without loss of
  trust during overlap;
- cross-namespace refs are rejected and a wrong CA fails closed;
- renewal results and the manual Splunk restart limitation are documented;
- every known gap has an owner, severity, and merge/waiver decision.

## 8. Known gaps to record in the PR

At `aa1d40c`, record these separately from passed tests:

1. Splunk does not automatically load a renewed leaf certificate.
2. CA-key rollover and trust overlap remain manual.
3. True client-authentication mTLS is not implemented.
4. HEC-only OTel configuration is admitted but does not trigger Ray sidecar
   injection.
5. Ray CA rollout hashing omits the Secret name/key identity.
6. HEC token material is stored in an OTel ConfigMap and token rotation lacks a
   Secret watch/restart path.
7. Endpoint HTTPS/URL validation and CA name/key validation are weak.
8. OpenShift hardcodes `cluster.local`; k0s/EKS custom-domain propagation is
   incomplete.
9. External private-CA bootstrap is awkward on a brand-new installer-created
   cluster because the CA Secret must exist before AIPlatform reconciliation,
   but there is no pre-AIPlatform hook.
10. Custom SAIA/SLIM images implicitly require `/bin/sh`, `cat`/`cp`, and the
    Debian CA-bundle path `/etc/ssl/certs/ca-certificates.crt`.
11. The installer enables HTTPS on Splunk Web, but its access banner and k0s
    documentation still print `http://...:8000`; the correct scheme is HTTPS.
12. Splunk Web HTTPS plus the default HTTP SAIA NodePort can cause browser
    mixed-content failures. Browser UI qualification needs the separate HTTPS
    SAIA/Traefik work and is not a PR #148 acceptance gate.

## 9. Cleanup and evidence

Before teardown, collect non-secret diagnostics:

```bash
kubectl get nodes -o yaml > "$EVIDENCE_DIR/nodes.yaml"
kubectl -n "$AI_NS" get aiplatform,aiservice,rayservice,certificate,issuer -o yaml \
  > "$EVIDENCE_DIR/resources.yaml"
kubectl -n "$AI_NS" get pods -o wide > "$EVIDENCE_DIR/final-pods.txt"
kubectl -n "$AI_NS" get events --sort-by=.lastTimestamp > "$EVIDENCE_DIR/final-events.txt"
```

Do not collect Secret YAML or the complete OTel ConfigMap. Review logs for
tokens before attaching them to the PR.

Then:

- restore `caCertRef` to `ai-splunk-server-tls/ca.crt`;
- wait for all affected workloads to become Ready;
- remove `splunk-ca-rotation-test`, `pr148-gpu-smoke`, and all locally generated
  test private keys, then remove the empty `ROTATION_TMP` directory;
- use the installer's documented teardown for the disposable cluster;
- revoke temporary registry/object-store credentials and remove temporary
  firewall rules;
- attach the result matrix and sanitized evidence to the PR, then remove the
  temporary evidence directory after confirming the approved copy is complete.
