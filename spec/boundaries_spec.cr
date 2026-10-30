require "./spec_helper"

describe "Evidence and operation boundaries" do
  it "does not expose installed private sources without explicit configuration" do
    fixture do |config, root|
      app = config.workspace("app").root
      private_root = File.join(app, "lib/joobq_pro")
      Dir.mkdir_p(private_root)
      File.write(File.join(private_root, "shard.yml"), "name: joobq_pro\nversion: 1.0.0\n")
      File.write(File.join(private_root, "README.md"), "PrivateWorkflowSymbol")
      File.write(File.join(app, "shard.lock"), "version: 2.0\nshards:\n  joobq_pro:\n    git: https://github.com/azutoolkit/joobq-pro.git\n    version: 1.0.0\n")
      AzuMCP::Catalog.new(config).sources("app").should be_empty
      authorized = AzuMCP::Config.from_yaml("state_dir: #{config.state_dir}\nworkspaces:\n  app:\n    root: #{app}\n    repositories:\n      joobq-pro: #{private_root}\n")
      index = AzuMCP::KnowledgeIndex.new(authorized, AzuMCP::Catalog.new(authorized))
      index.refresh("app")
      index.search("app", "PrivateWorkflowSymbol", nil)["results"].as_a.size.should eq(1)
      index.close
      revoked = AzuMCP::KnowledgeIndex.new(config, AzuMCP::Catalog.new(config))
      begin
        revoked.search("app", "PrivateWorkflowSymbol", nil)["results"].as_a.should be_empty
      ensure
        revoked.close
      end
    end
  end

  it "reports stale indexed content after a source changes" do
    fixture do |config, root|
      app = config.workspace("app").root
      File.write(File.join(app, "shard.yml"), "name: azu\nversion: 1.0.0\n")
      path = File.join(app, "src/main.cr")
      File.write(path, "class OriginalEndpoint\nend\n")
      index = AzuMCP::KnowledgeIndex.new(config, AzuMCP::Catalog.new(config))
      begin
        index.refresh("app")
        File.write(path, "class NewEndpoint\nend\n")
        index.search("app", "OriginalEndpoint", "azu")["results"][0]["evidence"].as_s.should eq("stale")
      ensure
        index.close
      end
    end
  end

  it "redacts dollar quoted, escaped and malformed SQL literals" do
    fixture do |config, root|
      broker = AzuMCP::TelemetryBroker.new(config)
      ["SELECT $$private$$", "SELECT $tag$private$tag$", "SELECT E'pri\\'vate'", "SELECT 'unfinished"].each do |sql|
        rendered = broker.filter(AzuMCP.json({query: sql})).to_json
        rendered.should_not contain("private")
        rendered.should_not contain("vate")
        rendered.should_not contain("unfinished")
      end
    end
  end

  it "merges database summaries without losing schema and distinguishes feature states" do
    fixture do |config, root|
      path = File.join(root, "snapshot.json")
      configured = AzuMCP::Config.from_yaml("state_dir: #{config.state_dir}\nworkspaces:\n  app:\n    root: #{config.workspace("app").root}\n    snapshot: #{path}\n")
      broker = AzuMCP::TelemetryBroker.new(configured)
      File.write(path, {v: 1, database: {tables: [{name: "products"}]}, dashboard: {database: {total_queries: 8}, features: {sessions: "unavailable", cache: "disabled"}}}.to_json)
      database = broker.snapshot("app", "database")["data"]
      database["total_queries"].as_i.should eq(8)
      database["tables"][0]["name"].as_s.should eq("products")
      broker.snapshot("app", "cache")["status"].as_s.should eq("disabled")
      broker.snapshot("app", "sessions")["status"].as_s.should eq("unavailable")
      File.write(path, {v: 1, at: (Time.utc - 1.minute).to_rfc3339, requests: {total: 0}}.to_json)
      broker.snapshot("app", "requests")["status"].as_s.should eq("stale")
    end
  end

  it "binds a remote review to the configured target" do
    fixture do |config, root|
      config.prepare
      id = "a" * 32
      File.write(File.join(config.state_dir, "remote-#{id}.json"), {target: "staging", target_digest: "another-target", remote: {} of String => String}.to_json)
      changed = AzuMCP::Config.from_yaml("state_dir: #{config.state_dir}\ntargets:\n  staging:\n    host: other-host\n    runner: azu-mcp\n    config: /etc/azu-mcp/config.yml\n    workspace: app\n    enabled: true\n")
      expect_raises(ArgumentError, /Target configuration changed/) { AzuMCP::RemoteOperations.new(changed).review(id) }
    end
  end

  it "refuses build source traversal before invoking a compiler" do
    fixture do |config, root|
      app = config.workspace("app").root
      File.write(File.join(app, "shard.yml"), "name: app\ntargets:\n  app:\n    main: ../outside.cr\n")
      expect_raises(ArgumentError, /relative/) { AzuMCP::Build.run("does-not-exist", app) }
    end
  end
end

describe "Index concurrency" do
  it "reports a competing writer as busy while keeping existing evidence readable" do
    fixture do |config, root|
      app = config.workspace("app").root
      File.write(File.join(app, "shard.yml"), "name: azu\nversion: 1.0.0\n")
      File.write(File.join(app, "src/main.cr"), "class ExampleEndpoint\nend\n")
      index = AzuMCP::KnowledgeIndex.new(config, AzuMCP::Catalog.new(config))
      begin
        index.refresh("app")
        File.open(File.join(config.state_dir, "index.lock"), "a") do |lease|
          lease.flock_exclusive
          index.refresh("app")["status"].as_s.should eq("busy")
          index.search("app", "ExampleEndpoint", "azu")["results"].as_a.size.should eq(1)
        end
        index.refresh("app")["indexed"].as_i.should eq(1)
      ensure
        index.close
      end
    end
  end
end

describe "Durable operation records" do
  it "keeps an unconfirmed remote start reconcilable and cancellable" do
    fixture do |config, root|
      operations = AzuMCP::Operations.new(config)
      plan = operations.plan("app", "build", [] of String)
      operations.mark_dispatched(plan.id)
      operations.status(plan.id)["status"].as_s.should eq("unknown")
      operations.cancel(plan.id)
      File.exists?(File.join(config.state_dir, "operations", "#{plan.id}.result.json.cancel")).should be_true
    end
  end

  it "does not execute an already completed plan again" do
    pending! "Build azu-mcp and set AZU_MCP_EXECUTABLE to test process ownership" unless ENV["AZU_MCP_EXECUTABLE"]?
    fixture do |config, root|
      configured = AzuMCP::Config.from_yaml("state_dir: #{config.state_dir}\nworkspaces:\n  app:\n    root: #{config.workspace("app").root}\n    trusted: true\n    azu: /usr/bin/true\n")
      operations = AzuMCP::Operations.new(configured)
      plan = operations.plan("app", "doctor", [] of String)
      operations.execute(plan.id)
      operations.wait(plan.id)["status"].as_s.should eq("succeeded")
      expect_raises(ArgumentError, /already claimed/) { operations.execute(plan.id) }
    end
  end
end

describe "Model-facing plan redaction" do
  it "hides generated credentials without altering stored plan bytes" do
    plan = AzuMCP.json({id: "review", details: {files: [
      {path: ".env", content: "SESSION_SECRET=never-export-this", after_sha256: "digest"},
      {path: "src/config.cr", content: "password = \"also-private\""},
    ]}})
    public_plan = AzuMCP::Redaction.public_view(plan)
    public_plan.to_json.should_not contain("never-export-this")
    public_plan.to_json.should_not contain("also-private")
    public_plan["details"]["files"][0]["after_sha256"].as_s.should eq("digest")
    plan["details"]["files"][0]["content"].as_s.should contain("never-export-this")
    AzuMCP::Redaction.text(%({"token":"private-token"})).should_not contain("private-token")
  end
end

describe "Review digest integrity" do
  it "rejects changed persisted plan contents even when its old digest is retained" do
    fixture do |config, root|
      operations = AzuMCP::Operations.new(config)
      plan = operations.plan("app", "build", [] of String)
      file = File.join(config.state_dir, "operations", "#{plan.id}.plan.json")
      changed = JSON.parse(File.read(file))
      changed.as_h["action"] = JSON::Any.new("doctor")
      File.write(file, changed.to_json)
      expect_raises(ArgumentError, /no longer matches/) { operations.load_plan(plan.id) }
      expect_raises(ArgumentError, /no longer matches/) { operations.approve(plan.id, plan.digest) }
    end
  end
end
