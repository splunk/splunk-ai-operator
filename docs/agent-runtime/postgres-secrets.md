# PostgreSQL Secret deployment

The deployment configuration creates the PostgreSQL checkpoint Secret before
applying AIPlatform. Runtime and schema setup use the same existing
`checkpointDbSecretRef` field. PostgreSQL itself, its database and its user must
already exist.

## Deployment inputs

Both `tools/ai-tier-cluster-setup/examples/profile-cpuonly.yaml` and
`profile-fullfeature.yaml` declare the supported creation path:

```yaml
aiPlatform:
  features:
    - name: agentruntime
      provider: mltk
      checkpointDbSecretRef: mltk-postgres-conn
  agentRuntime:
    checkpointSecrets:
      - name: mltk-postgres-conn
        create: true
        databaseUrlEnv: AGENT_RUNTIME_CHECKPOINT_DB_URL
```

Supply the named environment variable through the deployment environment's
credential workflow. Its value is a `postgres://` or `postgresql://` URI with
one TCP host, a user, password and database. Percent-encode reserved characters
in URI userinfo. Omitted ports resolve to 5432. Keep the value out of committed
configuration, command-line arguments and diagnostic artifacts. Legacy private
configuration files can still supply `databaseUrl`; the environment input is the
documented default and nothing copies it into AIPlatform or rendered profile values.

The installer derives one Opaque Secret in the AIService namespace with all six
required keys: `DATABASE_URL`, `PG_HOST`, `PG_PORT`, `PG_USER`, `PG_PASSWORD`, and
`PG_DBNAME`. Both workload consumers import it through `envFrom`; no credential
value is inserted into a ConfigMap, workload env literal, command argument,
status or Pod annotation. The Helm platform chart renders only the Secret
reference; configured creation belongs to the installer.

The creation entry's name must match an AgentRuntime feature reference. Invalid
declarations, missing configured credential input, malformed URIs, invalid ports
and ambiguous query overrides fail with fixed diagnostics. Offline profile
validation checks configuration shape without requiring the credential input.
The deployment step requires that input and stops before cleanup or AIPlatform
application if it is invalid.

## Existing Secrets and repeated deployments

An identical existing Opaque Secret is reused without an update, retaining its
resource version and avoiding an unnecessary schema rerun. Conflicting existing
content is preserved and deployment fails. This creation path does not perform
credential rotation; changing external database credentials and existing Secret
contents requires an explicit credential-management workflow.

For an externally managed Secret, set the matching entry to `create: false` or
omit creation entries and retain `checkpointDbSecretRef`. The installer leaves
that Secret untouched. Reconciliation still validates its six-key contract.
Deleting the feature does not give the operator ownership of the external
database or referenced Secret.

## Validation and migration

Admission and reconciliation reject PostgreSQL connection keys in AgentRuntime
feature env and direct AIService env, including empty values and libpq aliases
such as `PGPASSWORD`, `PGHOST`, `PGDATABASE`, `PGPASSFILE` and `PGSERVICE`.
Optional non-credential settings such as `PG_SSLMODE` and `PGSSLMODE` remain
supported. The selected image contract adds no mandatory PostgreSQL TLS fields.

The operator requires all six Secret keys, validates URI syntax and port range,
and compares URL and structured host/port/user/password/database values after
URI decoding. Query options cannot override connection identity. Database names
must be literal names:
`=` and nested PostgreSQL URI prefixes are rejected because libpq would interpret
them as connection settings. Connection aliases such as `PGHOSTADDR` and
`PGSERVICE` are also rejected inside the Secret, including empty aliases, because
`envFrom` would otherwise import a second connection source. Identical-deployment
checks reject those extras and invalid optional SSL modes before proceeding.
Missing or malformed required data prevents schema/runtime creation and produces current
`Ready=False` with a field-only diagnostic. Correcting an initially blocked
configuration permits reconciliation to proceed. Database connectivity remains
the responsibility of bounded schema preparation and Runtime startup; validation
does not add periodic database queries.

To migrate existing plaintext configuration, prepare a dedicated matching Secret
through deployment configuration, remove the connection literals from the
AIPlatform feature or directly managed AIService, and retain its reference.
For a parent-managed service, edit the parent rather than patching only the child.
For an already existing Secret with conflicting contents, use an explicitly
managed reference or a new dedicated Secret name instead of overwriting it.
Do not copy old credential values into a ticket or migration report. Removing
them from configuration cannot erase object history, audit history or old
artifacts; replace exposed credentials through the supplying database system.

Automatic runtime Pod replacement when a Secret changes is deferred and optional
for this release. Existing schema input/version handling remains active, so a
changed Secret can rerun schema setup while existing Pods retain their original
environment. Do not treat this story's validation or creation support as completed
rotation or immediate revocation. Provider/model/MCP credential support, product
request tokens, product E2E invocation and live installation qualification keep
their separate scope.
