# Azu Toolkit MCP

A native Crystal MCP server for coding assistants working with **Azu, Azu CLI, CQL, JoobQ, JoobQ Pro, Authly, Session, and Schema**.

Inspect version-matched source, preview generators, run trusted development checks, read redacted telemetry, and review supported operational changes. Runs locally over stdio; no hosted service or Node runtime is required.

**Preview:** the server and coordinated CLI/core changes need to be installed together. Production adapters require CQL's `apply_reviewed` and JoobQ's `redrive_reviewed`; older versions fail closed. See [validation](docs/validation.md) for what has actually been exercised.

## Build

Requires Crystal 1.22.1+, Shards, SQLite development headers, OpenSSL and libyaml.

```sh
shards install
shards build --release
./bin/azu-mcp --version
```

Create a user-owned configuration outside your project:

```yaml
# ~/.config/azu-mcp/config.yml
workspaces:
  store:
    root: /absolute/path/to/store
    trusted: false
```

```sh
azu-mcp check --config ~/.config/azu-mcp/config.yml
azu-mcp serve --config ~/.config/azu-mcp/config.yml
```

`serve` reserves stdout for MCP. Connect it through your client's configuration; it is not an interactive console.

## Start here

- [Configuration and trust](docs/configuration.md)
- [VS Code, Codex and Claude Code](docs/clients.md)
- [Tools and workflows](docs/tools.md)
- [Telemetry](docs/telemetry.md)
- [Reviewed operations](docs/operations.md)
- [Architecture](docs/architecture.md)
- [Validation and limits](docs/validation.md)

Example requests:

> Explain this project's endpoint, model and job boundaries using its installed versions.
>
> Preview a live Product scaffold, show conflicts, then build it after approval.
>
> Find evidence for slow requests and repeated SQL in the retained telemetry.

`echo`, `flux`, `dashforge`, `duo`, `topia`, `joobqui`, and `authority` are not supported integrations. They may appear in dependency metadata, but are not indexed as dedicated toolkit repositories.

## Development

```sh
shards build
AZU_MCP_EXECUTABLE="$PWD/bin/azu-mcp" crystal spec
crystal tool format --check src spec
python3 scripts/check_docs.py
```

See [architecture](docs/architecture.md) for the SDK adapter and [validation](docs/validation.md) for protocol, application and soak checks. Package publication and client UI validation are separate release gates; documentation does not imply they have happened.
