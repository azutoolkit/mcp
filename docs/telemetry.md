# Live telemetry

Use the coordinated CLI's snapshot export to share the same application data with the HUD and MCP:

```sh
mkdir -m 700 /absolute/private/path/store
azu dev --snapshot /absolute/private/path/store/snapshot.json
```

Set that path as the workspace's `snapshot`. Plain mode is also supported:

```sh
azu dev --ui plain --snapshot /absolute/private/path/store/snapshot.json
```

The CLI retains ownership of the application's private Unix socket and atomically publishes the latest snapshot. MCP reads the file; it does not register another CQL subscriber. Existing `Azu::CQL.attach` instrumentation remains authoritative.

Responses distinguish `available`, `empty`, `disabled`, `unavailable`, and `stale`. Older applications may not export every section. Metrics retain their original windows: recent requests are not a complete access log. A missing session provider is unavailable, and cookie sessions do not become a fabricated active-session count.

The server filters fields, bounds collections, removes sensitive payloads, and normalizes SQL literals. Production snapshots should already be sanitized by the existing read-only monitoring publisher. This server does not enable the development dashboard in production.

Optional cache, mailer, session and component integrations must publish their existing telemetry. No sending email, revoking sessions, or arbitrary SQL execution is exposed. Redis connectivity must never be interpreted as worker health.

Authentication frames are coalesced with the application snapshot, retain their own capture time, and are cleared when the app process changes. A source that stops reporting becomes stale even while other application metrics continue arriving. Generated `.env` file contents are hidden from model-facing generator previews; exact bytes remain in the private plan for terminal review and hash-checked application.
