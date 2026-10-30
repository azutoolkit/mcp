# Configuration and trust

Keep configuration outside repository-controlled files, for example `~/.config/azu-mcp/config.yml`. Use absolute workspace paths. Configuration is explicit: the server never scans your home directory or fetches repositories automatically.

```yaml
state_dir: /absolute/private/path/azu-mcp-state
workspaces:
  store:
    root: /absolute/path/to/store
    trusted: true
    environment: development
    azu: /absolute/path/to/azu
    crystal: crystal
    # Optional; completion needs a tested Crystalline executable.
    crystalline: /absolute/path/to/crystalline
    snapshot: /absolute/private/path/store/snapshot.json
    # Reference checkouts when an installed source is unavailable.
    repositories:
      azu: /absolute/path/to/azu
      cql: /absolute/path/to/cql
      joobq-pro: /absolute/path/to/authorized/joobq-pro
```

Untrusted workspaces support manifest inspection and source/documentation tools. Trust enables compiler macros, tests, CLI adapters, and application initializers. Trust is an execution decision, not a sandbox: all run with your OS account's permissions. Use a separate account/container for untrusted applications.

The state directory is private and contains the SQLite knowledge index and reviewed operation records, including generated source. It must not be committed or shared. Configure a separate state directory per OS identity; restrict backups and retention accordingly.

`shard.lock` provides dependency identity. Installed sources take precedence over reference checkouts. Working-tree references are labeled, not represented as a verified release. Missing or excluded sources remain unavailable. No inference of compatibility is made from version numbers alone.

Use `azu-mcp check --config PATH` to validate configuration. `azu mcp setup PATH` prints a client configuration snippet and does not overwrite editor settings. Set `AZU_MCP_BINARY` when the CLI should launch a binary outside PATH.

JoobQ Pro requires an explicit `repositories.joobq-pro` entry even when it is installed under `lib/`. Removing that entry revokes search access immediately; refresh removes its indexed rows. Database files and backups may retain deleted pages until you securely retire the index.
