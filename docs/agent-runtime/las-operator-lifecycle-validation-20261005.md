# LAS operator lifecycle validation — 2026-10-05

Target: `agentruntime-dev` k0s cluster, namespace `ai-platform`. Kubernetes, Helm, and Podman commands below ran on installer `ec2-user@52.12.115.104` with `KUBECONFIG=$HOME/.kube/k0s-agentruntime-dev`; AWS commands ran on the workstation. This is Plan 1 from the POC review: create a disposable `AIService`, observe dependency and Helm failures, recover, check unchanged reconciliation, and upgrade the same release. Deletion of `poc-lifecycle` is deferred until the multi-instance isolation check. No credential values or raw connection URLs are recorded.

## 0. Restore installer access — passed

The previously used SSH address timed out. AWS `describe-instances` confirmed `i-00a43c8d5bf68146c` (`agentruntime-dev-installer`) was running at the same public IP, and `describe-instance-status` reported instance/system `ok`. Systems Manager did not list it as a managed instance. The workstation's current public IP was absent from security group `sg-09b91f081efe3c4a3`'s SSH allowlist.

```sh
aws --profile splunkcloud-ai-dev_admin --region us-west-2 ec2 authorize-security-group-ingress \
  --group-id sg-09b91f081efe3c4a3 \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"106.222.234.36/32","Description":"Temporary LAS lifecycle POC SSH"}]}]'
ssh -o BatchMode=yes -o ConnectTimeout=10 -i /Users/kchoudhary/.ssh/agentruntime-dev.pem ec2-user@52.12.115.104 'printf connected'
```

AWS created temporary rule `sgr-0831f73a93d3960fc`; SSH returned `connected`. After the lifecycle checks, the exact rule was removed:

```sh
aws --profile splunkcloud-ai-dev_admin --region us-west-2 ec2 revoke-security-group-ingress \
  --group-id sg-09b91f081efe3c4a3 \
  --security-group-rule-ids sgr-0831f73a93d3960fc
aws --profile splunkcloud-ai-dev_admin --region us-west-2 ec2 describe-security-group-rules \
  --security-group-rule-ids sgr-0831f73a93d3960fc
```

Revoke returned `True`; describe returned `InvalidSecurityGroupRuleId.NotFound`, confirming removal.

## 1. Remove the manual deployment — passed

Before removal, `helm list` showed manual `las-poc` revision 2 and operator-owned `las-agentruntime-dev-ai-p-eb88ba0f` revision 1, both deployed. `helm get manifest las-poc` listed its two Deployments, two ServiceAccounts, and API Service. The primary AIService UID was `39598b65-89e6-4b32-ba5b-547dc9902036`, with `Ready=True / LASReady`.

```sh
helm -n ai-platform uninstall las-poc --wait --timeout 5m
helm -n ai-platform status las-poc
kubectl -n ai-platform get deploy,service,serviceaccount -o name | grep las-poc-langgraph-cloud
kubectl -n ai-platform get aiservice agentruntime-dev-ai-platform-agentruntime-mltk -o json
```

Helm reported `release "las-poc" uninstalled`. Subsequent Helm status failed as expected, the named chart resources were absent, and the primary AIService remained `Ready=True / LASReady` with its release deployed at revision 1.

## 2. Prepare isolated dependencies — passed

The installer has Podman containers `mltk-postgres` and `las-redis` bound at `10.0.35.244:5432` and `10.0.35.244:6379`. The existing LAS Secrets point to PostgreSQL database `las_poc` and Redis DB 0. A credential-safe Redis protocol check authenticated, selected DB 1, and returned `DBSIZE=0`. PostgreSQL role `mltk` has database-creation rights; the existing LAS connection URL uses application role `las_poc_user`.

```sh
sudo podman exec mltk-postgres createdb -U mltk las_poc_lifecycle
sudo podman exec mltk-postgres psql -v ON_ERROR_STOP=1 -U mltk -d postgres \
  -c 'ALTER DATABASE las_poc_lifecycle OWNER TO las_poc_user'
sudo podman exec mltk-postgres psql -U mltk -d postgres -Atc \
  "select datname,pg_get_userbyid(datdba) from pg_database where datname='las_poc_lifecycle'"
```

The ownership query returned `las_poc_lifecycle|las_poc_user`. The first attempt to query PostgreSQL as `postgres` failed because that role does not exist in this container. A later existence check had a shell-quoting error; no database change occurred from that check. The corrected commands above created and verified the database.

Secrets `las-postgres-poc` and `las-redis-poc` were created with no owner reference and label `ai.splunk.com/poc=las-lifecycle`. An installer-local Python process decoded the existing URLs in memory, changed only the database path to `/las_poc_lifecycle` and `/1`, and piped new Secret JSON directly to `kubectl apply -f -`. It printed only scheme, host, port, and database. The first Secret-creation attempt stopped before mutation when it found that the source PostgreSQL URL used `las_poc_user`, while the new database was still owned by `mltk`; ownership was corrected first. Both new Secrets are `Opaque` and contain the expected connection keys.

## 3. Missing Secret status — passed

Created standalone `AIService/poc-lifecycle` (UID `cebd2f48-1e88-4f6f-82ad-9718f4b708da`) with no AIPlatform owner reference. It uses `las-postgres-poc`, `las-redis-poc`, existing `ecr-registry-secret`, and intentionally absent `las-auth-poc`. The manifest is on the installer at `/tmp/las-poc-lifecycle-aiservice.yaml`. Its LAS feature has provider `poc-lifecycle`; the CRD also requires `aiPlatformRef`, `vectorDbUrl`, and `taskVolume.path`/`region`, though LAS does not use those fields. The first apply was rejected because `taskVolume.region` was omitted; adding `us-west-2` succeeded.

```sh
kubectl apply -f /tmp/las-poc-lifecycle-aiservice.yaml
kubectl -n ai-platform get aiservice poc-lifecycle -o json
helm -n ai-platform list -a -o json
kubectl -n ai-platform get events --field-selector involvedObject.name=poc-lifecycle
```

The operator added finalizer `ai.splunk.com/aiservice-protect`. AIService generation 2 reported `Ready=False / DependenciesUnavailable` with message `LAS Secret "las-auth-poc" unavailable: Secret "las-auth-poc" not found`; a matching Warning event existed. There was no `las-poc-lifecycle` Helm release.

## 4. Recoverable Helm failure — passed

Created disposable `Service/las-poc-lifecycle-langgraph-cloud-api-server` before satisfying the missing license dependency. Its UID was `5556ade6-9068-4604-8d0d-6a04a4f995b6`, and it had label `ai.splunk.com/poc=las-lifecycle-blocker`, no owner reference, and no Helm ownership metadata. An installer-local Python process copied only Secret data from `las-auth` to disposable `las-auth-poc` through `kubectl apply -f -`; it printed only the key name `langgraph_cloud_license_key`.

```sh
kubectl apply -f /tmp/las-poc-lifecycle-helm-blocker.yaml
# Copy las-auth data in memory to las-auth-poc without printing values.
kubectl -n ai-platform get aiservice poc-lifecycle -o json
helm -n ai-platform list -a -o json
kubectl -n ai-platform get service las-poc-lifecycle-langgraph-cloud-api-server -o json
kubectl -n ai-platform delete service las-poc-lifecycle-langgraph-cloud-api-server --wait=true
```

The AIService reported `Ready=False / HelmInstallFailed`. The message identified the existing Service and its missing Helm ownership label and annotations; a matching Warning event existed. No active test release was present. The collision Service retained its original UID, showing Helm did not adopt or delete it. Its UID and label were checked before deletion. The operator's retry after removal is recorded in the next section.

## 5. Automatic retry and installation — passed

After the blocker Service was removed, the AIService stayed at generation 2; no metadata or spec nudge was sent. The operator's error backoff was long because the intentionally missing Secret had already caused 15 retries. `LASInstalling` appeared again at 14:02:12 UTC, followed by `LASInstalled` at 14:02:35 and `LASReady` at 14:02:37. The delay from blocker removal was roughly five minutes. This is eventual automatic recovery, with a slow retry that should be considered when setting operational expectations.

```sh
kubectl -n ai-platform wait --for=condition=Ready aiservice/poc-lifecycle --timeout=360s
helm -n ai-platform list -o json
kubectl -n ai-platform get deploy -l app.kubernetes.io/instance=las-poc-lifecycle
kubectl -n ai-platform get secret sh.helm.release.v1.las-poc-lifecycle.v1 -o json
```

The wait succeeded. AIService UID remained `cebd2f48-1e88-4f6f-82ad-9718f4b708da`, with `Ready=True / LASReady` and observed generation 2. Exactly one active release, `las-poc-lifecycle` revision 1, was deployed with chart `langgraph-cloud-0.3.4`. Its Helm release Secret had owner label `ai.splunk.com/aiservice-uid=cebd2f48-1e88-4f6f-82ad-9718f4b708da`. API and queue Deployments were each `1/1 Ready`, generation 1. Their initial Pod UIDs were `601d9298-c424-4fc5-8cc5-bf36287bee24` and `70dd1a07-ad3e-4060-9361-c143cdc5dbea`.

## 6. Unchanged reconcile — passed

Saved Helm release, Deployment templates/generations, and Pod UID baselines under `/tmp/las-poc-lifecycle-*-before.json` on the installer. Annotated the AIService with `ai.splunk.com/poc-reconcile-check=1` to trigger reconciliation without changing any LAS Helm value.

```sh
kubectl -n ai-platform annotate aiservice poc-lifecycle ai.splunk.com/poc-reconcile-check=1 --overwrite
# Compare JSON baselines produced by kubectl/helm before and after the reconcile.
cmp -s /tmp/las-poc-lifecycle-release-before.json /tmp/las-poc-lifecycle-release-after-idempotence.json
cmp -s /tmp/las-poc-lifecycle-deploy-before.json /tmp/las-poc-lifecycle-deploy-after-idempotence.json
cmp -s /tmp/las-poc-lifecycle-pods-before.json /tmp/las-poc-lifecycle-pods-after-idempotence.json
```

All three comparisons succeeded: release name/revision/status remained unchanged at revision 1, both Deployment UIDs/generations/templates/readiness remained unchanged, and both Pod UIDs remained unchanged. The AIService reported `Ready=True / LASReady`, observed generation 3. Kubernetes advanced the CR generation from 2 to 3 after the annotation; this did not alter the LAS Helm values or cause a rollout.

## 7. Same-release upgrade — passed

Changed the disposable `licenseSecretRef` from `las-auth-poc` to `las-auth`. The former was an in-cluster copy of the latter, so the key was the same; only the chart's Secret name changed. Captured the primary release and Pod UID baseline first.

```sh
kubectl -n ai-platform patch aiservice poc-lifecycle --type=json -p \
  '[{"op":"test","path":"/spec/features/licenseSecretRef","value":"las-auth-poc"},{"op":"replace","path":"/spec/features/licenseSecretRef","value":"las-auth"}]'
# Poll until Ready=True/LASReady at observed generation 4 and Helm revision 2.
helm -n ai-platform list -o json
kubectl -n ai-platform get deploy -l app.kubernetes.io/instance=las-poc-lifecycle
kubectl -n ai-platform get secret sh.helm.release.v1.las-poc-lifecycle.v2 -o json
```

AIService UID stayed `cebd2f48-1e88-4f6f-82ad-9718f4b708da`. The same release `las-poc-lifecycle` advanced to revision 2, status `deployed`, chart `langgraph-cloud-0.3.4`; its new release Secret retained that UID ownership label. Both Deployments advanced to generation 2 and returned to `1/1 Ready`. Events show `LASUpgrading` at 14:06:49 UTC, `LASUpgraded` at 14:07:02, and `LASReady` at 14:07:04. AIService is `Ready=True / LASReady`, observed generation 4. The primary release JSON (revision 1) and both primary Pod UIDs compared byte-for-byte equal to their pre-upgrade baselines.

Through a temporary port-forward of `Service/poc-lifecycle-svc` (AIService-owned UID, port `8080` to LAS port `8000`), `GET /ok` returned `{"ok":true}`. An `echo` run on thread `01a10c65-5538-7750-adbe-6191c6ed36ff` returned `LAS sample agent received: LAS lifecycle revision two check`; a state read returned the saved request and response. The port-forward was stopped afterward.

```sh
kubectl -n ai-platform port-forward service/poc-lifecycle-svc 18083:8080 \
  >/tmp/las-poc-lifecycle-port-forward.log 2>&1 &
pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
curl -fsS http://127.0.0.1:18083/ok
thread_id=$(curl -fsS -H 'Content-Type: application/json' -d '{}' \
  http://127.0.0.1:18083/threads | python3 -c 'import json,sys; print(json.load(sys.stdin)["thread_id"])')
curl -fsS -H 'Content-Type: application/json' \
  -d '{"assistant_id":"echo","input":{"request":"LAS lifecycle revision two check"}}' \
  "http://127.0.0.1:18083/threads/$thread_id/runs/wait"
curl -fsS "http://127.0.0.1:18083/threads/$thread_id/state"
```

Final `helm get values` reported `las-auth`, `las-postgres-poc`, `las-redis-poc`, queue enabled, API CPU request `250m`, and three API probe timeouts of five seconds. PostgreSQL `las_poc_lifecycle` contained 12 non-system tables after startup and the run. Both primary and disposable AIService reported `True/LASReady`; their release revisions were 1 and 2 respectively.

## 8. State left for Plan 2

`AIService/poc-lifecycle` and its Helm release remain running, with PostgreSQL database `las_poc_lifecycle`, Redis DB 1, and disposable Secrets `las-postgres-poc`, `las-redis-poc`, and `las-auth-poc`. Its active license reference is now the shared `las-auth` Secret. The primary AIService and its release remain deployed and unchanged. Deletion of `poc-lifecycle`, finalizer/uninstall verification, external Secret preservation, and cleanup of disposable dependencies are deliberately deferred until the multi-instance isolation checks.

Later outcome: those checks and the deferred deletion passed. The disposable resources were then removed; see [Plan 2 isolation validation](las-operator-isolation-validation-20261005.md).

## Reproduction inputs

The disposable AIService manifest applied after adding the required region was:

```yaml
apiVersion: ai.splunk.com/v1
kind: AIService
metadata:
  name: poc-lifecycle
  namespace: ai-platform
  labels:
    ai.splunk.com/poc: las-lifecycle
spec:
  aiPlatformRef:
    apiVersion: ai.splunk.com/v1
    kind: AIPlatform
    name: agentruntime-dev-ai-platform
    namespace: ai-platform
  vectorDbUrl: agentruntime-dev-ai-platform-weaviate
  taskVolume:
    path: minio://ai-platform
    region: us-west-2
  imagePullSecrets:
    - name: ecr-registry-secret
  features:
    name: agentruntime
    provider: poc-lifecycle
    licenseSecretRef: las-auth-poc
    postgresSecretRef: las-postgres-poc
    redisSecretRef: las-redis-poc
```

The deliberate Helm blocker applied at `/tmp/las-poc-lifecycle-helm-blocker.yaml` was:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: las-poc-lifecycle-langgraph-cloud-api-server
  namespace: ai-platform
  labels:
    ai.splunk.com/poc: las-lifecycle-blocker
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: 8000
```

The installer created the two dependency Secrets through the following in-memory transform; it did not put decoded URLs in a file or command argument:

```python
import base64, json, subprocess, urllib.parse

items = [
    ("las-postgres", "postgres_connection_url", "las-postgres-poc", "las_poc_lifecycle"),
    ("las-redis", "redis_connection_url", "las-redis-poc", "1"),
]
for source, key, target, database in items:
    existing = subprocess.run(
        ["kubectl", "-n", "ai-platform", "get", "secret", target,
         "--ignore-not-found", "-o", "name"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if existing:
        raise RuntimeError(target + " already exists")
    original_secret = json.loads(subprocess.check_output(
        ["kubectl", "-n", "ai-platform", "get", "secret", source, "-o", "json"]
    ))
    original = base64.b64decode(original_secret["data"][key]).decode()
    url = urllib.parse.urlsplit(original)
    if source == "las-postgres" and urllib.parse.unquote(url.username or "") != "las_poc_user":
        raise RuntimeError("unexpected PostgreSQL application role")
    updated = urllib.parse.urlunsplit(
        (url.scheme, url.netloc, "/" + database, url.query, url.fragment)
    )
    secret = {
        "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
        "metadata": {
            "name": target, "namespace": "ai-platform",
            "labels": {"ai.splunk.com/poc": "las-lifecycle"},
        },
        "stringData": {key: updated},
    }
    subprocess.run(
        ["kubectl", "apply", "-f", "-"],
        input=json.dumps(secret), text=True, capture_output=True, check=True,
    )
```

The license alias was created in the same way, using `data` copied from `las-auth` into a new `Secret/las-auth-poc` with no owner reference; no key value was printed. The target was checked absent before creation.

```python
import json, subprocess

source = json.loads(subprocess.check_output(
    ["kubectl", "-n", "ai-platform", "get", "secret", "las-auth", "-o", "json"]
))
assert "langgraph_cloud_license_key" in source["data"]
assert subprocess.run(
    ["kubectl", "-n", "ai-platform", "get", "secret", "las-auth-poc"],
    capture_output=True,
).returncode != 0
alias = {
    "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
    "metadata": {
        "name": "las-auth-poc", "namespace": "ai-platform",
        "labels": {"ai.splunk.com/poc": "las-lifecycle"},
    },
    "data": source["data"],
}
subprocess.run(
    ["kubectl", "apply", "-f", "-"],
    input=json.dumps(alias), text=True, capture_output=True, check=True,
)
```

Redis DB 1 was checked with a short Python RESP client that decoded `las-redis/redis_connection_url` only in memory, sent `AUTH`, `SELECT 1`, and `DBSIZE`, and printed only `OK`, `OK`, and `0`. This avoided passing the Redis URL as a process argument or writing it to a file.
