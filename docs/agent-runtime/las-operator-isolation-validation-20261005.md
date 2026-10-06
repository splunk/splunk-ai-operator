# LAS operator Plan 2: isolation, deletion, and handoff — 2026-10-05

Target: `agentruntime-dev` k0s cluster, namespace `ai-platform`. Kubernetes, Helm, PostgreSQL Podman, and Redis checks ran on installer `ec2-user@52.12.115.104` with `KUBECONFIG=$HOME/.kube/k0s-agentruntime-dev`. AWS commands ran on the workstation. This continues [Plan 1](las-operator-lifecycle-validation-20261005.md). No Secret values or raw connection URLs were printed or saved.

## Result

Plan 2's multi-instance and deletion checks passed, with one capacity intervention during the second instance's upgrade. Three LAS releases were Ready concurrently: the primary AIService, `poc-lifecycle`, and `poc-isolation`. The two disposable instances used different PostgreSQL databases and Redis logical databases; each API returned HTTP 404 for the other instance's thread ID. Upgrading and deleting `poc-isolation` did not change the primary or `poc-lifecycle` release, Deployment, Pod, status, or Secret references. Deleting each disposable AIService uninstalled only its release and owned resources while its external Secrets and PostgreSQL database remained. After that evidence was captured, both disposable databases, Redis DBs, and five disposable Secrets were removed. The primary release remains deployed and Ready.

The caveat is significant: the second queue Pod could not schedule alongside its old Pod during a Helm upgrade because the chart requests 1 CPU and 2 GiB for each queue. A temporary `maxSurge: 0, maxUnavailable: 1` patch on that disposable queue let the upgrade finish. The chart's `25%/25%` strategy was restored afterward. This POC did not demonstrate an unattended upgrade under the current cluster capacity.

## 0. Installer access and baseline

SSH to the installer initially timed out. A first automatic sandbox approval review timed out without running its commands; a retry succeeded. The workstation public IP was `106.222.234.36`. The existing security group `sg-09b91f081efe3c4a3` did not allow that address, so a temporary single-IP rule was added:

```sh
curl -fsS --max-time 8 https://checkip.amazonaws.com
aws --profile splunkcloud-ai-dev_admin --region us-west-2 ec2 describe-security-group-rules \
  --filters Name=group-id,Values=sg-09b91f081efe3c4a3
aws --profile splunkcloud-ai-dev_admin --region us-west-2 ec2 authorize-security-group-ingress \
  --group-id sg-09b91f081efe3c4a3 \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"106.222.234.36/32","Description":"Temporary LAS Plan 2 SSH"}]}]'
ssh -o BatchMode=yes -o ConnectTimeout=10 \
  -i /Users/kchoudhary/.ssh/agentruntime-dev.pem ec2-user@52.12.115.104
```

AWS created rule `sgr-0198fc4ad752017e6` and SSH connected. At completion, this exact rule was revoked; `revoke-security-group-ingress` returned `True` and a filtered `describe-security-group-rules` query returned `[]`.

The saved installer baseline `/tmp/las-plan2-baseline.json` was produced with `/tmp/las_plan2_snapshot.py`, which records AIService UID/generation/Ready condition/Secret refs, Helm name/revision/status/chart, Deployment UID/generation/readiness, and Pod UID/phase. It contained:

| AIService | UID | Helm release | Revision | Ready |
| --- | --- | --- | --- | --- |
| `agentruntime-dev-ai-platform-agentruntime-mltk` | `39598b65-89e6-4b32-ba5b-547dc9902036` | `las-agentruntime-dev-ai-p-eb88ba0f` | 1 | `True/LASReady` |
| `poc-lifecycle` | `cebd2f48-1e88-4f6f-82ad-9718f4b708da` | `las-poc-lifecycle` | 2 | `True/LASReady` |

Both existing releases used `langgraph-cloud-0.3.4`, appVersion `0.2.3`; each had one Ready API Deployment and one Ready queue Deployment. Node allocations were approximately 85%, 84%, and 92% of CPU requests. An installer attempt to use `rg` failed because it is not installed there; the capacity check was repeated with `grep`.

## 1. Allocate the second instance's dependencies

The proposed database `las_poc_isolation` was absent. A credential-safe Redis RESP check authenticated, selected DB 2, and returned `DBSIZE=0`. The database was created for the existing LAS application role:

```sh
sudo podman exec mltk-postgres createdb -U mltk -O las_poc_user las_poc_isolation
sudo podman exec mltk-postgres psql -U mltk -d postgres -Atc \
  "select datname,pg_get_userbyid(datdba) from pg_database where datname='las_poc_isolation'"
```

The query returned `las_poc_isolation|las_poc_user`. The two new external Secrets were created without owner references, with label `ai.splunk.com/poc=las-isolation`. This installer-local Python transform decoded the original Secret URLs only in memory, changed only the URL database path, and piped Secret JSON directly into `kubectl apply -f -`:

```python
import base64, json, subprocess, urllib.parse

for source, key, target, database in [
    ("las-postgres", "postgres_connection_url", "las-postgres-poc2", "las_poc_isolation"),
    ("las-redis", "redis_connection_url", "las-redis-poc2", "2"),
]:
    existing = subprocess.run(
        ["kubectl", "-n", "ai-platform", "get", "secret", target,
         "--ignore-not-found", "-o", "name"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if existing:
        raise RuntimeError(target + " already exists")
    original = json.loads(subprocess.check_output(
        ["kubectl", "-n", "ai-platform", "get", "secret", source, "-o", "json"]
    ))
    url = urllib.parse.urlsplit(base64.b64decode(original["data"][key]).decode())
    if source == "las-postgres" and urllib.parse.unquote(url.username or "") != "las_poc_user":
        raise RuntimeError("unexpected PostgreSQL role")
    updated = urllib.parse.urlunsplit(
        (url.scheme, url.netloc, "/" + database, url.query, url.fragment)
    )
    secret = {
        "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
        "metadata": {
            "name": target, "namespace": "ai-platform",
            "labels": {"ai.splunk.com/poc": "las-isolation"},
        },
        "stringData": {key: updated},
    }
    subprocess.run(
        ["kubectl", "apply", "-f", "-"],
        input=json.dumps(secret), text=True, capture_output=True, check=True,
    )
    print("SECRET_CREATED", target, "database", database)
```

The output identified `las-postgres-poc2` for `las_poc_isolation` and `las-redis-poc2` for DB 2. Secret paths were later read back without credentials: the primary used PostgreSQL `/las_poc` and Redis `/0`; `poc-lifecycle` used `/las_poc_lifecycle` and `/1`; `poc-isolation` used `/las_poc_isolation` and `/2`. All used the same endpoint hosts `10.0.35.244` at ports 5432 and 6379, respectively. This proves logical database separation, not separate servers or credentials.

## 2. Create the second AIService and compare instances

The following manifest was saved on the installer as `/tmp/las-poc-isolation-aiservice.yaml` and applied:

```yaml
apiVersion: ai.splunk.com/v1
kind: AIService
metadata:
  name: poc-isolation
  namespace: ai-platform
  labels:
    ai.splunk.com/poc: las-isolation
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
    provider: poc-isolation
    licenseSecretRef: las-auth
    postgresSecretRef: las-postgres-poc2
    redisSecretRef: las-redis-poc2
```

```sh
kubectl apply -f /tmp/las-poc-isolation-aiservice.yaml
kubectl -n ai-platform wait --for=condition=Ready aiservice/poc-isolation --timeout=360s
helm -n ai-platform list -o json
kubectl -n ai-platform get secret sh.helm.release.v1.las-poc-isolation.v1 -o json
python3 /tmp/las_plan2_snapshot.py \
  agentruntime-dev-ai-platform-agentruntime-mltk poc-lifecycle poc-isolation \
  > /tmp/las-plan2-after-create.json
```

`kubectl wait` succeeded. The new AIService UID was `587ee49d-2d98-404c-b537-77a443a13c9e`; it had no AIPlatform owner reference, reached observed generation 2 and `True/LASReady`, and owned Helm release `las-poc-isolation` revision 1. The Helm release Secret's `ai.splunk.com/aiservice-uid` label matched that UID. The release had chart `langgraph-cloud-0.3.4`, appVersion `0.2.3`, with API and queue each `1/1 Ready`. Events recorded `LASInstalling`, `LASInstalled`, and `LASReady`. The primary and `poc-lifecycle` compact snapshots compared byte-for-byte equal to baseline.

## 3. Exercise both APIs and cross-read isolation

Temporary installer-local forwards were started for `Service/poc-lifecycle-svc` and `Service/poc-isolation-svc`, then stopped by a shell trap:

```sh
kubectl -n ai-platform port-forward service/poc-lifecycle-svc 18083:8080 \
  >/tmp/las-plan2-lifecycle-forward.log 2>&1 &
pf1=$!
kubectl -n ai-platform port-forward service/poc-isolation-svc 18084:8080 \
  >/tmp/las-plan2-isolation-forward.log 2>&1 &
pf2=$!
trap 'kill "$pf1" "$pf2" 2>/dev/null || true' EXIT
```

Using Python `urllib.request`, the executed sequence for each port was `GET /ok`, `POST /threads` with `{}`, `POST /threads/{id}/runs/wait` with assistant `echo` and a distinct request string, then `GET /threads/{id}/state`. Both health calls returned HTTP 200 and `{"ok":true}`. The run and state results were:

| Instance | Thread | Saved request | Response |
| --- | --- | --- | --- |
| `poc-lifecycle` | `01a10c7f-c02c-7881-808b-fdf188ae0677` | `Plan 2 isolated run for poc-lifecycle` | `LAS sample agent received: Plan 2 isolated run for poc-lifecycle` |
| `poc-isolation` | `01a10c7f-c0b6-71e0-ba30-94d7878d3fc3` | `Plan 2 isolated run for poc-isolation` | `LAS sample agent received: Plan 2 isolated run for poc-isolation` |

`GET /threads/{poc-lifecycle-thread}/state` through `poc-isolation` returned HTTP 404, `thread ... not found`. The reverse cross-read also returned HTTP 404. Thread IDs were saved on the installer in `/tmp/las-plan2-threads.json` for later persistence checks.

## 4. Upgrade only the second instance — passed with capacity intervention

`las-auth` and the disposable `las-auth-poc` held equal `langgraph_cloud_license_key` data at the time of the test; the values were compared in memory and never printed. Changing only the Secret name exercised a supported Helm value:

```sh
kubectl -n ai-platform patch aiservice poc-isolation --type=json -p \
  '[{"op":"test","path":"/spec/features/licenseSecretRef","value":"las-auth"},{"op":"replace","path":"/spec/features/licenseSecretRef","value":"las-auth-poc"}]'
```

The AIService advanced to generation 3 and reported `Unknown/Upgrading`. Helm revision 2 was `pending-upgrade`. The new API Pod became Ready, but the new queue Pod stayed Pending while the old queue Pod remained Ready. `kubectl describe pod las-poc-isolation-langgraph-cloud-queue-5776f9f745-ml9t7` reported `0/3 nodes are available: 3 Insufficient cpu` and a 1 CPU/2 GiB request. The queue Deployment's chart strategy was `maxSurge: 25%, maxUnavailable: 25%`, which requires a surge Pod for a one-replica rollout.

Only the disposable queue Deployment was patched to replace its old Pod before scheduling the new one:

```sh
kubectl -n ai-platform patch deploy las-poc-isolation-langgraph-cloud-queue \
  --type=merge \
  -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
```

The old queue Pod was removed, the replacement scheduled and reached Ready, and Helm completed revision 2 with `deployed` status. The AIService reached observed generation 3, `True/LASReady`. Events recorded `LASUpgrading`, `LASUpgraded`, a transient `WorkloadsNotReady`, and then `LASReady`. The chart strategy was then restored:

```sh
kubectl -n ai-platform patch deploy las-poc-isolation-langgraph-cloud-queue \
  --type=merge \
  -p '{"spec":{"strategy":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}}'
```

The queue remained `1/1 Ready`. The primary and `poc-lifecycle` snapshots again compared byte-for-byte equal to their pre-upgrade snapshots, including Helm revision, Deployment UIDs/generations, Pod UIDs, readiness, and AIService status. Both previously created threads remained readable after the upgrade. The second PostgreSQL database contained 12 public tables.

## 5. Delete the second instance; preserve its dependencies

Before deletion, the UID and data-key names of `las-postgres-poc2`, `las-redis-poc2`, and `las-auth-poc` were saved in `/tmp/las-plan2-secrets-before-delete.json`. Then:

```sh
kubectl -n ai-platform delete aiservice poc-isolation --wait=true --timeout=360s
helm -n ai-platform list -a -o json
kubectl -n ai-platform get deploy,service,serviceaccount \
  -l app.kubernetes.io/instance=las-poc-isolation -o name
kubectl -n ai-platform get service poc-isolation-svc --ignore-not-found -o name
kubectl -n ai-platform get secret sh.helm.release.v1.las-poc-isolation.v1 \
  sh.helm.release.v1.las-poc-isolation.v2 --ignore-not-found -o name
```

The deletion returned successfully. No `las-poc-isolation` release, chart resource, compatibility Service, or Helm release Secret remained. Events recorded `LASUninstalling` and `LASUninstalled`. The three external Secrets' UID/key snapshots compared byte-for-byte equal before and after deletion. PostgreSQL `las_poc_isolation` still existed with 12 public tables. The primary and `poc-lifecycle` snapshots remained unchanged. After this deletion, `poc-lifecycle` still returned its old thread state and successfully ran the `echo` graph again with request `Plan 2 survivor after peer deletion`.

## 6. Delete the first disposable instance; preserve its dependencies

The same Secret UID/key baseline was saved for `las-postgres-poc`, `las-redis-poc`, and `las-auth-poc`. Then:

```sh
kubectl -n ai-platform delete aiservice poc-lifecycle --wait=true --timeout=360s
helm -n ai-platform list -a -o json
kubectl -n ai-platform get deploy,service,serviceaccount \
  -l app.kubernetes.io/instance=las-poc-lifecycle -o name
kubectl -n ai-platform get service poc-lifecycle-svc --ignore-not-found -o name
kubectl -n ai-platform get secret sh.helm.release.v1.las-poc-lifecycle.v1 \
  sh.helm.release.v1.las-poc-lifecycle.v2 --ignore-not-found -o name
```

The deletion returned successfully. Neither disposable Helm release nor its chart/compatibility resources or release Secrets remained. Events recorded `LASUninstalling` and `LASUninstalled`. The first instance's external Secret UID/key snapshot was unchanged and PostgreSQL `las_poc_lifecycle` still had 12 public tables. The primary compact snapshot remained byte-for-byte unchanged and `True/LASReady` at release revision 1.

## 7. Remove disposable dependencies after evidence capture

Before cleanup, `kubectl get aiservice` showed only the primary and unrelated `slim` AIService, with no references to the five disposable Secrets. A cluster Pod-spec scan found no environment, `envFrom`, or volume reference to them. The five Secrets still had the POC labels and no owner references. Redis DB 1 had 4 keys and DB 2 had 1 key at the first post-deletion check. An initial guarded cleanup attempt expected exactly those counts and stopped before mutation when an expiring key reduced DB 1 to 3. The retry selected only DBs 1 and 2, issued `FLUSHDB`, and checked `DBSIZE=0`; it reported 3→0 and 1→0 keys. Credentials were decoded from `las-redis` only in process.

```sh
sudo podman exec mltk-postgres dropdb -U mltk las_poc_isolation
sudo podman exec mltk-postgres dropdb -U mltk las_poc_lifecycle
sudo podman exec mltk-postgres psql -U mltk -d postgres -Atc \
  "select datname from pg_database where datname in ('las_poc_isolation','las_poc_lifecycle')"
kubectl -n ai-platform delete secret \
  las-postgres-poc las-redis-poc las-postgres-poc2 las-redis-poc2 las-auth-poc \
  --wait=true
```

The PostgreSQL query returned no rows and Kubernetes confirmed all five Secret deletions. The final `helm list -a` contained only primary release `las-agentruntime-dev-ai-p-eb88ba0f` revision 1, `deployed`. The original `las-auth`, `las-postgres`, and `las-redis` Secrets remained with their original UIDs. Database `las_poc` remained; the two POC databases were absent. The primary compact snapshot was byte-for-byte equal to the initial baseline.

## Tested versions and remaining work

| Component | Live identity |
| --- | --- |
| LAS Helm chart | `langgraph-cloud-0.3.4`, appVersion `0.2.3` |
| LAS sample agent image | `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/las-sample-agent:las-poc-20260930-115209`, running digest `sha256:bc4c1a779904e0c422392deabcf4091f79c1fcdf82bc483d49b82ba79a5b4eba` |
| Operator manager image | `658391232643.dkr.ecr.us-west-2.amazonaws.com/ml-platform/splunk-ai-operator:las-poc-20261005-114954-483a832`, running digest `sha256:f7b98f37ab2571af598cc13c3698f0d3dc575d6c29b5f96b9f586753708103bc` |
| Source state | `las-poc` branch; operator image from the preceding [rollout](las-operator-rollout-20261005.md). No separate operator Helm release was listed in `splunk-ai-operator-system`. |

1. Resolve queue upgrade headroom before treating upgrades as unattended. In this cluster, the chart's 1 CPU queue request plus the default surge strategy blocked a one-replica queue rollout. Review a supported queue resource/rollout value or provide sufficient spare capacity; repeat the upgrade without a live patch.
2. The two POCs used separate databases on shared PostgreSQL/Redis endpoints and the same PostgreSQL application role. The HTTP 404 cross-read checks prove application-level separation for these threads; they do not prove credential or server isolation. Production dependency and retention policy remain design work.
3. The runtime accepted a concurrent second instance, but this does not establish the license's contractual instance entitlement. The earlier [manual validation](las-ai-tier-manual-validation.md) also did not observe a transaction-level license-verification result; obtain vendor-supported evidence if that is required.
4. The primary AIService was intentionally kept running. All disposable Plan 1/2 resources and the temporary SSH security group rule were removed.
