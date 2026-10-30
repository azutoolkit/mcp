# Azu Toolkit MCP

Give your coding assistant project context it can verify: installed shard versions, cited source, generator previews, compiler results, and retained application telemetry.

The server is written in Crystal and runs on your machine. Start with [configuration](configuration.md), then connect your [coding client](clients.md).

{% hint style="info" %}
Knowledge tools do not boot your application. Builds, semantic analysis and runtime adapters require a trusted workspace. Crystal macros and application initializers can execute code.
{% endhint %}

The supported toolkit consists of Azu, Azu CLI, CQL, JoobQ, JoobQ Pro, Authly, Session, and Schema. Private sources remain local and are indexed only when configured or installed in your authorized workspace.

{% hint style="warning" %}
This is a preview. Production changes require a named target, compatible core APIs, and separate terminal approval. A plan is not proof of execution; inspect its final operation status.
{% endhint %}
