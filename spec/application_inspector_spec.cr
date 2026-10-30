require "./spec_helper"

class RecordingCLIAdapter < AzuMCP::CLIAdapter
  getter calls = [] of String
  property response = AzuMCP.json({queues: [] of String, workers: [] of String})

  def call(id : String, command : String) : JSON::Any
    @calls << command
    @response
  end
end

def inspection_fixture(trusted = true, environment = "development", &)
  fixture do |original, root|
    app = original.workspace("app").root
    path = File.join(root, "snapshot.json")
    config = AzuMCP::Config.from_yaml({state_dir: original.state_dir, workspaces: {
      app: {root: app, trusted: trusted, environment: environment, snapshot: path},
    }}.to_yaml)
    Dir.mkdir_p(File.join(app, "src/initializers"))
    File.write(File.join(app, "src/initializers/joobq.cr"), "# configured")
    adapter = RecordingCLIAdapter.new(config)
    inspector = AzuMCP::ApplicationInspector.new(config, AzuMCP::TelemetryBroker.new(config), adapter)
    yield inspector, adapter, path, config
  end
end

describe AzuMCP::ApplicationInspector do
  it "never loads an application for untrusted or production inspection" do
    [{false, "development"}, {true, "production"}].each do |trusted, environment|
      inspection_fixture(trusted, environment) do |inspector, adapter, _, _|
        %w(queues workflows dlq routes).each do |section|
          inspector.snapshot("app", section)["status"].as_s.should eq("unavailable")
        end
        adapter.calls.should be_empty
      end
    end
  end

  it "preserves disabled, empty and stale telemetry without invoking an adapter" do
    inspection_fixture do |inspector, adapter, path, _|
      samples = {
        "disabled" => AzuMCP.json({v: 1, dashboard: {features: {queues: "disabled"}}}),
        "empty"    => AzuMCP.json({v: 1, queues: {total: 0}}),
        "stale"    => AzuMCP.json({v: 1, at: (Time.utc - 1.minute).to_rfc3339, queues: {total: 4}}),
      }
      samples.each do |status, sample|
        File.write(path, sample.to_json)
        inspector.snapshot("app", "queues")["status"].as_s.should eq(status)
      end
      adapter.calls.should be_empty
    end
  end

  it "does not mistake worker data for an available queue provider" do
    inspection_fixture do |inspector, adapter, _, _|
      adapter.response = AzuMCP.json({workers: [{id: "worker-1"}]})
      result = inspector.snapshot("app", "queues")
      result["status"].as_s.should eq("unavailable")
      result["data"]["queues"].raw.should be_nil
      result["data"]["workers"][0]["id"].as_s.should eq("worker-1")
    end
  end

  it "filters adapter data while keeping worker health separate from queue depth" do
    inspection_fixture do |inspector, adapter, _, _|
      adapter.response = AzuMCP.json({queues: [{name: "default", pending: 5, token: "secret"}], workers: [] of String})
      result = inspector.snapshot("app", "queues")
      result["status"].as_s.should eq("available")
      result["data"]["queues"][0]["pending"].as_i.should eq(5)
      result["data"]["workers"].as_a.should be_empty
      result.to_json.should_not contain("secret")
      adapter.calls.should eq(["jobs-inspect"])
    end
  end

  it "requires explicit Pro workflow availability even when a collection exists" do
    inspection_fixture do |inspector, adapter, _, _|
      adapter.response = AzuMCP.json({workflows: [] of String, workflows_available: false})
      inspector.snapshot("app", "workflows")["status"].as_s.should eq("unavailable")
      adapter.response = AzuMCP.json({workflows: [] of String, workflows_available: true})
      inspector.snapshot("app", "workflows")["status"].as_s.should eq("available")
    end
  end

  it "loads only the requested local routes when passive telemetry is missing" do
    inspection_fixture do |inspector, adapter, _, _|
      adapter.response = AzuMCP.json({routes: [{method: "GET", path: "/"}]})
      inspector.snapshot("app", "routes").should eq(adapter.response)
      adapter.calls.should eq(["routes-inspect"])
      inspector.snapshot("app", "sessions")["status"].as_s.should eq("unavailable")
      adapter.calls.size.should eq(1)
    end
  end
end

describe AzuMCP::CLIAdapter do
  it "enforces trust independently of the inspection policy" do
    inspection_fixture(false) do |_, _, _, config|
      expect_raises(ArgumentError, /not trusted/) { AzuMCP::CLIAdapter.new(config).call("app", "catalog") }
    end
  end
end
