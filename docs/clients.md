# Client setup

Install the native server and create its configuration first. Use absolute paths in client settings because GUI applications often inherit a different PATH than your terminal.

{% tabs %}
{% tab title="VS Code" %}
Add a server to `.vscode/mcp.json` (keep credentials out of this file):

```json
{
  "servers": {
    "azu": {
      "type": "stdio",
      "command": "/absolute/path/to/azu-mcp",
      "args": ["serve", "--config", "/absolute/path/to/config.yml"]
    }
  }
}
```

Start the server using VS Code's MCP controls and review its tools. MCP assistance complements your Crystal extension; it does not replace editor language-server integration.
{% endtab %}
{% tab title="Codex" %}
Register the local binary:

```sh
codex mcp add azu -- /absolute/path/to/azu-mcp serve --config /absolute/path/to/config.yml
codex mcp get azu
```

Then open a new client session and inspect the available tools.
{% endtab %}
{% tab title="Claude Code" %}
Use a local stdio server:

```sh
claude mcp add --transport stdio azu -- /absolute/path/to/azu-mcp serve --config /absolute/path/to/config.yml
```

Clients using `mcpServers` JSON can use the snippet printed by `azu mcp setup /absolute/path/to/config.yml`.
{% endtab %}
{% endtabs %}

Begin by asking the assistant to call `azu_workspace_inspect`, `azu_capabilities`, then `azu_index_refresh`. Search results include source locations and content digests. Reindex after dependency upgrades or source edits.

Client configuration examples are not evidence of a tested graphical workflow. See the [validation record](validation.md) for actual client coverage.
