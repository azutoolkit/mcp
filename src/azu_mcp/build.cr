module AzuMCP
  # Build installed sources directly. `shards build` may install missing shards,
  # which is deliberately outside the MCP execution contract.
  module Build
    def self.run(compiler : String, root = Dir.current) : Int32
      manifest = YAML.parse(Paths.read(root, "shard.yml"))
      targets = manifest["targets"]?.try(&.as_h?) || raise ArgumentError.new("No build targets in shard.yml")
      raise ArgumentError.new("Expected 1–32 build targets") unless 1 <= targets.size <= 32
      targets.each do |key, target|
        name = key.as_s
        raise ArgumentError.new("Invalid target name") unless name.matches?(/\A[A-Za-z0-9_][A-Za-z0-9_-]{0,127}\z/)
        source = Paths.safe(root, target["main"].as_s)
        output = File.join(root, "bin")
        raise ArgumentError.new("Build output must not be a symlink") if File.symlink?(output)
        Dir.mkdir_p(output)
        destination = File.join(output, name)
        raise ArgumentError.new("Build target must not be a symlink") if File.symlink?(destination)
        status = Process.run(compiler, ["build", source, "-o", destination, "--error-trace"], chdir: root,
          output: STDOUT, error: STDERR)
        return status.exit_code? || 1 unless status.success?
      end
      0
    end
  end
end
