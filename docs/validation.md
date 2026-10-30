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

Do not infer coverage beyond recorded evidence. GUI workflows in VS Code and Claude Code, production infrastructure, and real organizational credentials require their own checks. Native Linux/macOS builds and the compiler matrix are covered by hosted CI; check the reviewed commit’s status before merging. Incomplete or macro-heavy programs can return unavailable semantic results. Optional providers remain unavailable unless configured.

Coordinated core changes must land before enabling the corresponding production tools. Preview tags and package publication must be verified separately. A shortened or interrupted soak is not a completed 30-minute run.

### Coordinated adapters and protocol

- Native boundary/process suite: 27 passing examples, including persisted-plan digest tampering, model-facing generated-secret redaction, and inspection policy across trust, production and provider states. Independent framing tests cover malformed initialization recovery, omitted params, oversized frames, compiler cancellation and descendant cleanup.
- CLI: the final development/control/bridge regression run passed 36 examples; generator-shadow validation passed 9 examples. Earlier affected suites also passed, along with the 49-page documentation check. These counts overlap and must not be added together.
- CQL: 32 SQLite migration/transaction examples and 8 live PostgreSQL lock examples passed. The reviewed-plan race commits once and rejects the waiter after the version set changes. Targeted Ameba and GitBook checks passed.
- JoobQ: 21 DLQ examples passed; separate real-Redis runs completed reviewed queue pause/resume and exact-member replay. A real Pro workflow was visible with its running state and pending step.
- A restricted loopback SSH runner rejected execution before approval, completed a reviewed migration, and reported durable success after the client disconnected and reconnected. Approval could not be reused. An identified migration rollback also passed. The final digest-verifying runner repeated the migration/reconnect flow successfully; this is a controlled staging fixture, not a real production deployment.
- The generated application reported real memory-session lifecycle events, authentication outcomes, and cache get/set/delete activity. Session contents, cache keys/values, and generated `.env` contents were absent from model-facing results. Cookie-session active counts remain unavailable.
- The CLI stdio handoff passed the independent protocol client. Codex accepted the server configuration. This does not establish GUI interaction coverage in every client.

### Reproduce concurrent workload validation

The SDK is a **test-client** dependency only:

```sh
npm install --prefix /tmp/azu-mcp-sdk @modelcontextprotocol/sdk@1.32.2
cp scripts/concurrent_soak.mjs /tmp/azu-mcp-sdk/soak.mjs
node /tmp/azu-mcp-sdk/soak.mjs "$PWD/bin/azu-mcp" CONFIG WORKSPACE 1800
```

This sends concurrent searches, snapshot reads and capability requests, with periodic index refreshes. It records latency, Linux RSS and clean exit. Development hardware: Linux x86_64, AMD EPYC 9V74, five visible CPUs with a four-CPU cgroup quota; Crystal 1.22.1. The completed concurrent run used the eight-repository corpus and four concurrent requests:

| Measurement | Result |
|---|---:|
| Duration | 1,800.62 seconds |
| Calls | 4,311 |
| Warm indexed search p95 | 19.69 ms |
| Initial / peak / final RSS | 19,104 / 20,512 / 20,300 KiB |
| Shutdown | Clean exit |

Snapshot reads in this workload returned unavailable; this measures protocol/index concurrency, not application or database throughput. The binary was frozen before the final plan-digest, public-output redaction, and diagnostic-message refinements. Those changes have separate regression coverage; this is not an exact-final-commit soak. A subsequent 120-second run passed 323 calls with 20.16 ms search p95 and a clean exit. Short smoke tests are not substitutes for the completed 30-minute run.

Real email delivery, full Authly OAuth flows, and a dedicated durable Delivery telemetry provider remain unvalidated or unavailable in this preview. The Pro workflow store was exercised independently; indexing private Pro sources still requires explicit authorization.

Hosted CI passed the Linux/macOS 15 matrix on Crystal 1.22.1 and `latest` for the native preview. The initial macOS 14 jobs were cancelled before execution by GitHub's scheduled runner-image retirement brownout; the workflow now uses macOS 15. CLI hosted checks also exercised generated API/web/Spark apps and three JoobQ adapter revisions. CQL and JoobQ hosted matrices passed for the coordinated adapter PRs.
