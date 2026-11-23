# PostgreSQL Secret live validation

23 November 2026 — **passed on the existing agentruntime-dev cluster**.
Eleven live scenarios and seven deployment-helper checks passed. Cleanup restored
all original network rules and cluster configuration; shared workloads and the
checkpoint Secret matched their baseline. Sanitized results and source hashes
are in [live results](validation/mpr-195-live-results.json).

## Candidate and isolation

Branch `codex/MPR-195-secret-references-redaction`, based on feature head `636d408e483d7a7d488d1fe007215d365abfd85d`.

The [scoped command](../../cmd/agentruntime-live/main.go) ran the production
AIPlatform/AIService reconcilers and admission handlers as a static Linux/amd64
binary. Its SHA-256 was verified after transfer:

`72ed3321441e3573615a82c5a3c5466e561d75a30737cecdae5b5376de98bdad`

The cache and candidate identity were limited to a disposable namespace through
a namespaced RoleBinding to the generated source role. A tested admission guard
denied the legacy operator's fixture writes while allowing the candidate. The
shared operator continued running. Older webhooks were excluded only from the
labelled fixture; candidate webhooks served that namespace with an ephemeral TLS
certificate. Five missing prerequisite profile/schema-status fields were added
temporarily, with no wholesale CRD replacement.

PostgreSQL used an emptyDir volume and dedicated synthetic credentials. The
checkpoint Secret was created by the actual production deployment helper from a
deployment-time environment input. No shared database or Secret was modified.
Runtime, provider and schema images were immutable and verified in ECR. Actual
Kubernetes controllers, kubelet, schema execution and HTTP health supplied the
observations; resource statuses were not simulated.

## Observed results

The deployment-helper checks passed: missing input rejected; invalid URL rejected;
Secret created; all six required keys present; identical rerun preserved resource
version; conflicting input preserved the existing Secret; reference-only mode
left it untouched. The optional `PG_SSLMODE` key selected the disposable plaintext
PostgreSQL fixture's supported mode.

| Live scenario | Result |
| --- | --- |
| Parent admission with plaintext credential | Rejected by the candidate webhook; returned error contained no canary |
| Missing checkpoint Secret | Current parent/child Ready=False; no schema Job or runtime Deployment created |
| Incomplete checkpoint Secret | Reconciliation remained blocked; no schema/runtime workload created |
| Alternate connection aliases in Secret | Rejected before schema/runtime creation; diagnostic identified the forbidden field |
| Connection-string database name | Rejected before schema/runtime creation; diagnostic identified PG_DBNAME |
| Secret correction | Real schema Job succeeded; runtime became Ready; Service `/health` returned HTTP 200 |
| Direct AIService credential overrides | Both feature and top-level env updates rejected safely by live admission |
| Identical deployment rerun | Secret resource version, schema Job, runtime generation/template and Pod identity stayed stable |
| Contradictory Secret fields | Rejected without a new schema Job or Pod rollout; current readiness became False |
| Credential redaction | Canary values and their base64 forms absent from ten non-Secret resource kinds, Events, candidate output and fixture container logs |
| Final correction | Schema preparation and parent/child readiness recovered; existing runtime Pod identity was retained |

The final scan covered five container logs, including the runtime/provider,
PostgreSQL and schema executions. API-server audit retention and unrelated
application payloads were outside the scan.

The first setup attempt used a JSON configuration filename, causing the YAML
reader to retain scalar quotes. The fixture was corrected to the documented YAML
format and all checks were rerun successfully. No product change was needed.

## Cleanup and access

Verified cleanup removed the disposable namespace, PostgreSQL, Secrets,
workloads, scoped controller, admission guard, webhook configurations and test
permissions. Both complete original CRD specs and original webhook arrays were
restored and compared. The shared operator configuration, runtime UID/generation
and Pod identity, platform/service identity and readiness, and shared Secret
UID/resource version/key set matched the original snapshot. All three nodes
were Ready. Remote binaries, logs, test inputs and ephemeral TLS key were removed.

The authorized existing private AWS tunnel was used for this final run. Its
single temporary SSH rule was removed, a fresh AWS read matched every original
security-group rule exactly, and the SSH control socket was absent. Remote test
files and ephemeral TLS material were removed. No key, endpoint, cluster or node
was created or replaced. Private account/access evidence remains outside Git.

## Limits

These results qualify PostgreSQL Secret creation, validation, admission, safe
diagnostics and recovery exercised here. Rotation remains optional for this
release and deferred to MPR-268. Restoring the same disposable credential does
not establish real credential rotation. Provider/model/MCP credentials, product
invocation, shared-operator upgrade, operator image packaging, cold installation,
PostgreSQL TLS, GPU/fullfeature execution and OS qualification remain separate.
The recorded source fingerprints identify the tested candidate. This evidence
does not establish a merged change or close Jira.
