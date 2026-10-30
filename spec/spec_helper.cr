require "spec"
require "../src/azu_mcp"

def fixture(&)
  root = File.join(Dir.tempdir, "azu-mcp-spec-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(File.join(root, "app", "src"))
  File.write(File.join(root, "app", "shard.yml"), "name: app\nversion: 0.1.0\n")
  config = AzuMCP::Config.new({"app" => AzuMCP::Workspace.new(File.join(root, "app"), true)}, File.join(root, "state"))
  yield config, root
ensure
  FileUtils.rm_rf(root) if root
end
