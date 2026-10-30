require "./spec_helper"

describe "Toolkit boundaries" do
  it "supports exactly the eight repositories" do
    AzuMCP::REPOSITORIES.should eq(%w(azu azu_cli cql joobq joobq-pro authly session schema))
  end

  it "reports missing providers without inventing metrics" do
    fixture do |config, root|
      catalog = AzuMCP::Catalog.new(config)
      catalog.list("app").as_a.size.should eq(8)
      catalog.list("app").as_a.all? { |row| row["status"].as_s == "unavailable" }.should be_true
      AzuMCP::TelemetryBroker.new(config).snapshot("app")["status"].as_s.should eq("unavailable")
      expect_raises(ArgumentError) { catalog.source("app", "authority") }
    end
  end

  it "rejects traversal, secrets and symlink escapes" do
    fixture do |config, root|
      app = config.workspace("app").root
      File.write(File.join(root, "outside.cr"), "secret")
      File.symlink(root, File.join(app, "escape"))
      %w(../outside.cr escape/outside.cr .env src/credentials.cr).each do |path|
        expect_raises(ArgumentError) { AzuMCP::Paths.read(app, path) }
      end
      expect_raises(ArgumentError) { AzuMCP::Paths.safe(app, "escape/new.cr", false) }
    end
  end

  it "redacts sensitive telemetry, bounds collections and preserves nil counts" do
    fixture do |config, root|
      broker = AzuMCP::TelemetryBroker.new(config)
      value = JSON.parse({v: 1, sessions: {active_count: nil, token: "nope"}, sql: {recent: Array.new(300) { {ms: 2, query: "SELECT 'secret'", bindings: ["password"]} }}}.to_json)
      filtered = broker.filter(value)
      filtered["sessions"]["active_count"].raw.should be_nil
      filtered["sessions"]["token"]?.should be_nil
      filtered["sql"]["recent"].as_a.size.should eq(120)
      filtered.to_json.should_not contain("password")
      filtered.to_json.should_not contain("secret")
    end
  end

  it "requires workspace trust for execution and semantic loading" do
    fixture do |config, root|
      untrusted = AzuMCP::Config.new({"app" => AzuMCP::Workspace.new(config.workspace("app").root)}, config.state_dir)
      operations = AzuMCP::Operations.new(untrusted)
      expect_raises(ArgumentError, /not trusted/) { operations.plan("app", "build", [] of String) }
    end
  end
end

describe AzuMCP::KnowledgeIndex do
  it "indexes all supported repositories and removes changed and deleted evidence" do
    fixture do |config, root|
      yaml = "state_dir: #{config.state_dir}\nworkspaces:\n  app:\n    root: #{config.workspace("app").root}\n    repositories:\n"
      AzuMCP::REPOSITORIES.each do |repo|
        path = File.join(root, repo)
        Dir.mkdir_p(File.join(path, "src"))
        File.write(File.join(path, "shard.yml"), "name: #{repo}\nversion: 1.0.0\n")
        File.write(File.join(path, "src", "sample.cr"), "class OriginalSymbol\nend\n")
        yaml += "      #{repo}: #{path}\n"
      end
      configured = AzuMCP::Config.from_yaml(yaml)
      catalog = AzuMCP::Catalog.new(configured)
      index = AzuMCP::KnowledgeIndex.new(configured, catalog)
      begin
        index.refresh("app")["indexed"].as_i.should eq(8)
        AzuMCP::REPOSITORIES.each do |repo|
          found = index.search("app", "OriginalSymbol", repo)["results"].as_a
          found.size.should eq(1)
          found.first["line"].as_i.should eq(1)
          found.first["version"].as_s.should eq("1.0.0")
        end
        File.write(File.join(root, "azu/src/sample.cr"), "class ChangedSymbol\nend")
        File.delete(File.join(root, "cql/src/sample.cr"))
        index.refresh("app")
        index.search("app", "OriginalSymbol", "azu")["results"].as_a.should be_empty
        index.search("app", "OriginalSymbol", "cql")["results"].as_a.should be_empty
        index.search("app", "ChangedSymbol", "azu")["results"].as_a.size.should eq(1)
        expect_raises(ArgumentError) { index.search("app", "query", "echo") }
      ensure
        index.close
      end
    end
  end
end

describe AzuMCP::Operations do
  it "invalidates plans after source edits and rejects arbitrary actions/arguments" do
    fixture do |config, root|
      operations = AzuMCP::Operations.new(config)
      plan = operations.plan("app", "build", [] of String)
      File.write(File.join(config.workspace("app").root, "src/main.cr"), "puts 1")
      expect_raises(ArgumentError, /changed/) { operations.execute(plan.id) }
      %w(shell db:drop db:reset jobs:clear session:clear).each do |action|
        expect_raises(ArgumentError, /Unsupported/) { operations.plan("app", action, [] of String) }
      end
      expect_raises(ArgumentError) { operations.plan("app", "test", ["spec/../../secret.cr"]) }
      expect_raises(ArgumentError) { operations.plan("app", "jobs:retry", ["--all"]) }
      expect_raises(ArgumentError) { operations.approve(plan.id, "forged") }
      expect_raises(ArgumentError) { operations.status("../file") }
    end
  end

  it "blocks production execution by default" do
    fixture do |config, root|
      production = AzuMCP::Config.from_yaml("state_dir: #{config.state_dir}\nworkspaces:\n  app:\n    root: #{config.workspace("app").root}\n    trusted: true\n    environment: production\n")
      expect_raises(ArgumentError, /disabled/) { AzuMCP::Operations.new(production).plan("app", "db:migrate", [] of String) }
    end
  end
end
