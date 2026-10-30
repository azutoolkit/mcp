# Architecture

```mermaid
flowchart TD
  Client[MCP client] --> Transport[Bounded stdio adapter]
  Transport --> Registry[ToolRegistry: protocol boundary]
  Registry --> Server[Server: capability composition]
  Server --> Knowledge[Versioned catalog and SQLite FTS]
  Server --> Semantic[Compiler and Crystalline broker]
  Server --> Inspector[ApplicationInspector: provider selection]
  Inspector --> CLI[CLIAdapter: trusted application calls]
  Inspector --> Telemetry[Read-only snapshot broker]
  Server --> Operations[Plans, policy and operation journal]
  Operations --> Local[Bounded process runner]
  Operations --> SSH[Restricted SSH runner]
```

`Server` composes the services and registers tools by capability. `ToolRegistry`
owns input validation, response limits, redaction and protocol results; tool
annotations are explicit at registration and never authorize execution.
`ApplicationInspector` selects passive snapshots or trusted local adapters.
`CLIAdapter` owns the application-loading process boundary and checks trust again
before starting a process. Its injected interface lets inspection policy be
tested without booting an application.

Disabled, empty and stale snapshots never trigger an application-loading
fallback. Untrusted and production workspaces use passive inspection only.
Worker data does not imply that a queue provider is available. These boundaries
keep protocol details out of inspection policy without adding a generic plugin
framework or dependency-injection container.

The protocol dependency is pinned to `spider-gazelle/mcp.cr` revision `d6ca3e5a3ad37e394af7cf91a2c0717f73cd232f`. The adapter repairs its tools-list constructor/cursor spelling, normalizes omitted optional params, and replaces the stdio transport with bounded framing and serialized writes. Protocol support is negotiated; newer clients may agree on the SDK's supported `2025-06-18` revision.

Each server admits at most eight in-flight protocol requests. Tool inputs and source reads are bounded; subprocess output is drained even after the retained prefix fills. Compiler and operation children run in separate process sessions so cancellation terminates descendants. Unknown or stale operation outcomes remain explicit.

SQLite uses WAL and an exclusive write transaction for refresh. Paths are scoped to configured roots, symlink escapes are rejected, and excluded repositories receive no dedicated indexes. Search results carry file digests and version provenance; refresh removes deleted entries.

The implementation is intentionally additive. It does not change the web HUD calculation rules, CQL subscriber topology, or the existing read-only SSH monitor.

Refresh admission is serialized across server processes with an advisory file lock. A competing refresh returns `busy` and leaves the existing index readable. Reads use a separate WAL connection; refresh yields between file batches. File digests mark changed search evidence as `stale`, and removing private-source authorization immediately prevents cached Pro results from being returned.

Operation journals admit at most 1,000 local plans and 1,000 remote plans per state directory. Archive resolved records deliberately when capacity is reached; unresolved records and replay guards are never pruned automatically. Output remains bounded to 128 KiB per subprocess stream.
