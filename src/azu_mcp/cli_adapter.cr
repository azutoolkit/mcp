module AzuMCP
  # Application-loading CLI calls share one explicit workspace trust boundary.
  class CLIAdapter
    def initialize(@config : Config)
    end

    def call(id : String, command : String) : JSON::Any
      workspace = @config.workspace(id)
      workspace.trust!
      result = ProcessRunner.run(workspace.azu, ["mcp", "bridge", command], workspace.canonical, 90.seconds, raw_output: true) { |_| }
      raise ArgumentError.new("CLI adapter unavailable; upgrade azu_cli") unless result.exit_code == 0 && !result.truncated
      JSON.parse(result.output)
    end
  end
end
