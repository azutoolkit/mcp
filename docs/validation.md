# Validation and limitations

This page records preview evidence, not an enterprise-readiness certification.

## Automated checks

```sh
shards build
AZU_MCP_EXECUTABLE="$PWD/bin/azu-mcp" crystal spec
python3 scripts/check_docs.py
```

`scripts/protocol_test.py BINARY CONFIG WORKSPACE` is an independent newline-JSON client. It checks lifecycle, strict argument validation, prompts/resources, citations, supported repository coverage and exclusions. The configured fixture needs an Azu source containing `Endpoint`.

`scripts/soak.py BINARY CONFIG WORKSPACE 1800` measures a 30-minute real-process workload. Keep indexing and request output separate from protocol stdout. The report includes elapsed time, calls, warm-search p95 and RSS on Linux.

## Evidence from development

- Generated a SQLite application using released Azu 1.0.5 and CQL 1.0.1.
- Previewed 35 live Spark scaffold files, rejected unapproved execution, approved through a PTY, applied the plan, and built the app.
- Exercised a CSRF-protected Product create/list flow, a failed route, and shared request/SQL/component telemetry.
- Tested protocol discovery and six concurrent requests with the maintained TypeScript SDK client. This is a client test; the server remains entirely Crystal.
- Verified compiler context/definition results on Crystal 1.22.1 and method completion with Crystalline 0.20 on a small fixture.
- Added separate focused CQL and JoobQ tests for reviewed migration state and exact-member replay.

## Remaining release gates

Do not infer coverage beyond recorded evidence. GUI workflows in VS Code and Claude Code, supported macOS builds, the newer compiler matrix, production infrastructure, and real organizational credentials require their own checks. Incomplete or macro-heavy programs can return unavailable semantic results. Optional providers remain unavailable unless configured.

Coordinated core changes must land before enabling the corresponding production tools. Preview tags and package publication must be verified separately. A shortened or interrupted soak is not a completed 30-minute run.

### Coordinated adapters and protocol

- Native boundary/process suite: 18 passing examples. Independent framing tests cover malformed initialization recovery, omitted params, oversized frames, compiler cancellation and descendant cleanup.
- CLI: 42 affected development/control/bridge examples, 7 bridge/JoobQ-screen examples, and the 49-page documentation check passed.
- CQL: 32 SQLite migration/transaction examples and 8 live PostgreSQL lock examples passed. The reviewed-plan race commits once and rejects the waiter after the version set changes. Targeted Ameba and GitBook checks passed.
- JoobQ: 21 DLQ examples passed; separate real-Redis runs completed reviewed queue pause/resume and exact-member replay. A real Pro workflow was visible with its running state and pending step.
- A restricted loopback SSH runner rejected execution before approval, completed a reviewed migration, and reported durable success after the client disconnected and reconnected. Approval could not be reused.
- The CLI stdio handoff passed the independent protocol client. Codex accepted the server configuration. This does not establish GUI interaction coverage in every client.

### Reproduce concurrent workload validation

The SDK is a **test-client** dependency only:

```sh
npm install --prefix /tmp/azu-mcp-sdk @modelcontextprotocol/sdk@1.32.2
cp scripts/concurrent_soak.mjs /tmp/azu-mcp-sdk/soak.mjs
node /tmp/azu-mcp-sdk/soak.mjs "$PWD/bin/azu-mcp" CONFIG WORKSPACE 1800
```

This sends concurrent searches, snapshot reads and capability requests, with periodic index refreshes. It records latency, Linux RSS and clean exit. Development hardware: Linux x86_64, AMD EPYC 9V74, five visible CPUs with a four-CPU cgroup quota; Crystal 1.22.1. The complete concurrent run is recorded separately when it finishes; short smoke tests are not substitutes.
