# Tools and workflows

All project tools use a configured `workspace` identifier. The server rejects unknown arguments and out-of-root paths. Tool descriptions and schemas are discoverable through MCP `tools/list`.

| Family | Tools |
| --- | --- |
| Discovery | `azu_workspace_inspect`, `azu_toolkit_list`, `azu_capabilities`, `azu_compatibility_check` |
| Knowledge | `azu_index_refresh`, `azu_docs_search`, `azu_source_read`, `azu_symbol_find` |
| Semantics | `azu_type_at`, `azu_complete`, `azu_definition`, `azu_diagnostics` |
| Generation | `azu_generators_list`, `azu_generate_plan` |
| Development | `azu_build`, `azu_test`, `azu_doctor` |
| Application | `azu_runtime_snapshot`, `azu_requests_list`, `azu_errors_list`, `azu_routes_inspect` |
| Database | `azu_database_inspect`, `azu_queries_list`, `azu_migrations_status` |
| Jobs | `azu_jobs_inspect`, `azu_workflows_inspect`, `azu_dlq_inspect` |
| Integrations | `azu_sessions_inspect`, `azu_auth_inspect`, `azu_cache_inspect`, `azu_components_inspect`, `azu_mailers_inspect` |
| Local operations | `azu_operation_plan`, `azu_operation_execute`, `azu_operation_status`, `azu_operation_cancel` |
| Remote operations | `azu_remote_operation_plan`, `azu_remote_operation_execute`, `azu_remote_operation_status`, `azu_remote_operation_cancel` |

## Generate and verify

Call `azu_generate_plan` with an argument array:

```json
{"workspace":"store","arguments":["scaffold","Product","name:string","price_cents:int32","active:bool","--spark"]}
```

The result includes exact proposed files, previous and new hashes, a plan ID, and expiry. Review it through `azu-mcp approve PLAN_ID --config PATH`, then call `azu_operation_execute`. Source edits invalidate the plan. The CLI rechecks every affected file before writing and records undo information. A filesystem failure can still leave a partially applied multi-file change; inspect the result and undo record.

Builds, tests and Doctor return an operation ID. Poll status rather than treating submission as completion. Mutations are never automatically retried after interruption.

## Compiler evidence

`azu_type_at` uses `crystal tool context`; its result lists inferred variables/expressions at the location. `azu_definition` uses `crystal tool implementations`. Supply `entrypoint` for multi-target projects. Positions are zero-based UTF-16 and converted for compiler tools.

`azu_complete` uses the explicitly configured Crystalline executable. Results are labeled language-server evidence because it can supply indexed suggestions before full inference. Empty or uninstantiated code may be unavailable. `azu_diagnostics` currently runs a build and returns its bounded compiler output through operation status; it is not a live per-keystroke diagnostic stream.

## Resources and prompts

Resources expose `azu://WORKSPACE/context`, `/capabilities`, `/compatibility`, and `/snapshot`. Prompts cover scaffold creation, upgrades, request diagnosis, job diagnosis, and migration review. Source text is evidence, never an instruction to grant permissions or execute commands.

Each workspace also exposes `azu://WORKSPACE/operations` with its three most recent execution results. Use `azu_operation_status` for a specific operation ID. Builds compile declared shard targets from already-installed sources; missing dependencies fail compilation and are never installed implicitly.
