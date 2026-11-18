# Agent Runtime schema Job lifecycle (MPR-189)

The operator runs one schema setup Job per AgentRuntime AIService. Each AIService
has its own checkpoint database. The schema image is the supplied `/schema.sql`
image from the candidate contract; the operator does not produce SQL or an image.

## Inputs and reruns

Supply `RELATED_IMAGE_AGENT_RUNTIME_SCHEMA_SETUP` as a full, immutable
`registry/path@sha256:<64 hex digits>` reference from the candidate or mirror
snapshot. A mutable tag is rejected before a Job is created. The resolved
digest is recorded on the Job and in `AIService.status.schemaImageDigest` after
success.

The Job identity includes the pinned schema image, checkpoint Secret reference
and resource version, schema related PostgreSQL feature environment, and
`AIPlatform.spec.features[].schemaRetryNonce`. A successful result is reused
while those inputs are unchanged, including after Kubernetes removes the Job
through its 24 hour TTL. Runtime replica or placement changes do not rerun SQL.
If a previously used digest or PostgreSQL configuration becomes current again
after a different schema run, the operator removes its historical completed Job
and creates a fresh one for that transition.
Starting or observing a fresh Job invalidates the previous applied result.
If the new Job later fails or its outcome is lost before observation, TTL
cleanup cannot turn that historical success into a current one.

After a terminal failure, change `schemaRetryNonce` to a new value on the
AgentRuntime feature in the AIPlatform manifest and apply the manifest. The
same nonce never retries. The operator stops an active old Job and waits for
its Pods to terminate before starting the replacement. It never deletes the
checkpoint database or its Secret.

## Bounds and status

Each Job has a 300 second active deadline, one Kubernetes backoff retry, and a
24 hour terminal Job TTL. Each Pod makes at most 12 PostgreSQL readiness
attempts with a two second per-attempt timeout and exponential delays capped
at eight seconds. SQL execution is also bounded by the Job deadline.

`PostgresSchemaSetupReady` reports `Pending`, `Succeeded`, `TimedOut`, `Failed`,
or `Superseded` as its reason. Terminal status uses fixed diagnostic text and
does not copy database URLs, SQL, Kubernetes Job messages, or credentials into
the condition. `status.schemaAppliedHash` and the terminal failure hash keep
reuse and retry decisions stable after Job TTL cleanup.

Focused local tests cover rendered Job bounds and image, status reasons,
successful reuse after TTL cleanup, failure persistence, retry nonce changes,
active Job replacement, and the bounded PostgreSQL wait. Full product install
and OS qualification belong to the separate installation stories.

The MPR-188 candidate renderer accepts candidate tags and uses a clearly
labelled synthetic digest only for its in-memory operator render. It does not
resolve registry digests or make those candidate tags executable by MPR-189.
