module AzuMCP
  # Prefer passive telemetry. Only trusted local workspaces may load an app to
  # fill a missing provider; disabled, empty and stale snapshots remain intact.
  class ApplicationInspector
    JOB_SECTIONS = %w(queues workflows dlq)

    def initialize(@config : Config, @telemetry : TelemetryBroker, @cli : CLIAdapter)
    end

    def snapshot(id : String, section : String? = nil) : JSON::Any
      snapshot = @telemetry.snapshot(id, section)
      workspace = @config.workspace(id)
      return snapshot unless snapshot["status"].as_s == "unavailable" && workspace.trusted && workspace.environment != "production"

      if section && JOB_SECTIONS.includes?(section) && File.file?(File.join(workspace.canonical, "src/initializers/joobq.cr"))
        jobs(id, section)
      elsif section == "routes"
        @cli.call(id, "routes-inspect")
      else
        snapshot
      end
    end

    private def jobs(id : String, section : String) : JSON::Any
      data = @cli.call(id, "jobs-inspect")
      payload = data[section]? || JSON::Any.new(nil)
      available = !payload.raw.nil?
      available &&= data["workflows_available"]?.try(&.as_bool?) == true if section == "workflows"
      payload = AzuMCP.json({queues: payload, workers: data["workers"]?}) if section == "queues"

      AzuMCP.json({status: available ? "available" : "unavailable", data: @telemetry.filter(payload),
                   note: "Application adapter executed. Queue metrics describe legacy processing; durable Delivery needs its own provider. Worker registry is distinct from Redis connectivity."})
    end
  end
end
