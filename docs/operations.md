# Reviewed operations

Local builds, tests and Doctor checks require workspace trust. Generator application and operational mutations also require separate terminal approval. Production execution is disabled by default.

Supported production changes are pending migrations, rollback of the exact latest reviewed migration, replay of one selected DLQ job, and named queue pause/resume. Database reset/drop, arbitrary SQL or shell commands, bulk queue clearing, deployment and session deletion are not exposed.

## Core compatibility

Migration execution requires `CQL::Migrator#apply_reviewed`, which checks applied and pending version sets under CQL's migration lock. Nontransactional migrations are rejected for manual handling. MySQL DDL and application migration effects are not universally reversible.

Targeted replay requires `JoobQ::DeadLetterQueue#redrive_reviewed`, which checks the reviewed member digest and consumes that member through the existing Lua transition. At-least-once processing still requires idempotent external effects. Older cores fail closed at execution.

## Remote target

On the remote host, use a dedicated SSH identity with a forced command such as:

```text
command="/opt/azu/bin/azu-mcp runner --config /etc/azu-mcp/production.yml",restrict ssh-ed25519 PUBLIC_KEY
```

The remote configuration enables only the intended production workspace:

```yaml
production_enabled: true
state_dir: /var/lib/azu-mcp
workspaces:
  store:
    root: /srv/store/current
    trusted: true
    environment: production
    azu: /opt/azu/bin/azu
```

Keep this configuration and the runner binary outside application-writable directories. The SSH identity is an operations principal; its key authorizes the restricted runner. This is not protection against a malicious holder of that key.

Configure the corresponding target locally, using SSH config for ports and jump hosts:

```yaml
targets:
  production:
    host: azu-production
    config: /etc/azu-mcp/production.yml
    workspace: store
    runner: /opt/azu/bin/azu-mcp
    enabled: true
```

1. Call `azu_remote_operation_plan` for the named target.
2. Review the exact target, action, preconditions and recovery limitations.
3. Run `azu-mcp approve-remote PLAN_ID --config LOCAL_CONFIG` in your terminal.
4. Call `azu_remote_operation_execute` and inspect status.

Approval expires after 15 minutes and is consumed before sending execution. Target changes invalidate it. The remote worker persists operation state independently of the SSH connection. If a connection fails, query status before doing anything else. `unknown` means reconciliation is required, not permission to retry.

Cancellation requests are journaled; the worker stops its process group. Already committed database or external effects are not undone. Operation journals contain sensitive operational context and proposed source; keep them private. Do not delete active or unresolved records.

Queue pause/resume requires `JoobQ::RedisStore#set_paused_reviewed`. Plans bind the resolved Redis endpoint/database or CQL schema URI without exposing credentials. The runner pins both `CRYSTAL_ENV` and `AZU_ENV` to the configured environment. Source fingerprints cover Crystal files in `src`, `db`, `config`, and `spec`, plus the shard manifest and lockfile.

Reviewed migration execution is limited to PostgreSQL and SQLite transactional DDL. MySQL, CockroachDB and explicitly nontransactional migrations use a manual procedure. A migrator constructor can initialize its metadata table during planning. Keep deployed code and dependencies immutable during a review/execution window: the workspace lock serializes MCP runners, not unrelated editors or other deployment tools.
