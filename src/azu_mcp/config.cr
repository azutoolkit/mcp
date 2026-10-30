require "yaml"
require "json"
require "digest/sha256"
require "file_utils"
require "random/secure"

module AzuMCP
  VERSION      = "0.1.0"
  REPOSITORIES = %w(azu azu_cli cql joobq joobq-pro authly session schema)
  MAX_FILE     = 1_048_576

  def self.json(value) : JSON::Any
    JSON.parse(value.to_json)
  end

  class Workspace
    include YAML::Serializable
    getter root : String
    getter trusted : Bool = false
    getter environment : String = "development"
    getter repositories : Hash(String, String) = {} of String => String
    getter snapshot : String? = nil
    getter crystalline : String? = nil
    getter azu : String = "azu"
    getter crystal : String = "crystal"

    def initialize(@root, @trusted = false)
    end

    def canonical : String
      File.realpath(root)
    end

    def trust! : Nil
      raise ArgumentError.new("Workspace is not trusted; enable trusted in the user-owned MCP configuration") unless trusted
    end
  end

  class Target
    include YAML::Serializable
    getter host : String
    getter config : String
    getter workspace : String
    getter enabled : Bool = false
    getter runner : String = "azu-mcp"

    def validate! : Nil
      raise ArgumentError.new("Target is disabled") unless enabled
      raise ArgumentError.new("Invalid SSH host") unless host.matches?(/\A[A-Za-z0-9_][A-Za-z0-9_.@-]*\z/)
      raise ArgumentError.new("Invalid runner path") unless runner.matches?(/\A[A-Za-z0-9_\/.:-]+\z/)
      raise ArgumentError.new("Remote config must be an absolute safe path") unless config.matches?(/\A\/[A-Za-z0-9_\/.:-]+\z/) && !config.split('/').includes?("..")
    end
  end

  class Config
    include YAML::Serializable
    getter workspaces : Hash(String, Workspace) = {} of String => Workspace
    getter targets : Hash(String, Target) = {} of String => Target
    getter state_dir : String = File.join(ENV["XDG_STATE_HOME"]? || File.join(Path.home.to_s, ".local/state"), "azu-mcp")
    getter production_enabled : Bool = false

    def initialize(@workspaces, @state_dir)
    end

    def self.load(path : String) : Config
      raise ArgumentError.new("Configuration exceeds 64 KiB") if File.size(path) > 65_536
      config = from_yaml(File.read(path))
      raise ArgumentError.new("Configure at least one workspace") if config.workspaces.empty?
      config.workspaces.each do |name, workspace|
        raise ArgumentError.new("Invalid workspace id") unless name.matches?(/\A[\w-]{1,64}\z/)
        raise ArgumentError.new("Workspace root must be absolute") unless Path[workspace.root].absolute?
        workspace.canonical
        workspace.repositories.each_key do |repo|
          raise ArgumentError.new("Unsupported repository: #{repo}") unless REPOSITORIES.includes?(repo)
        end
      end
      config
    end

    def workspace(id : String) : Workspace
      workspaces[id]? || raise ArgumentError.new("Unknown workspace")
    end

    def prepare : Nil
      Dir.mkdir_p(state_dir, 0o700)
      raise ArgumentError.new("State directory must not be a symlink") if File.symlink?(state_dir)
      File.chmod(state_dir, 0o700)
    end
  end

  module Paths
    def self.safe(root : String, relative : String, exists = true) : String
      raise ArgumentError.new("Use a relative path") if Path[relative].absolute? || relative.split('/').includes?("..") || relative.includes?('\0')
      raise ArgumentError.new("Sensitive or generated path is excluded") if relative.split('/').any? { |part| part.starts_with?('.') || %w(node_modules bin tmp log vendor).includes?(part) } || relative.matches?(/(?:secret|credential|\.pem$|\.key$|\.db$|\.sqlite)/i)
      base = File.realpath(root)
      candidate = File.expand_path(relative, base)
      # Check all existing ancestors, including symlinks, even for new files.
      ancestor = candidate
      until File.exists?(ancestor) || File.symlink?(ancestor)
        ancestor = File.dirname(ancestor)
      end
      resolved = File.realpath(ancestor)
      raise ArgumentError.new("Path escapes configured root") unless resolved == base || resolved.starts_with?(base + "/")
      raise ArgumentError.new("File does not exist") if exists && !File.file?(candidate)
      candidate
    end

    def self.read(root : String, relative : String) : String
      path = safe(root, relative)
      raise ArgumentError.new("File exceeds 1 MiB") if File.size(path) > MAX_FILE
      File.read(path)
    end
  end

  module Redaction
    SENSITIVE = /password|passwd|secret|token|authorization|cookie|params|parameters|bindings|payload|email|body|preview/i

    def self.clean(value : JSON::Any, depth = 0) : JSON::Any
      return JSON::Any.new("[truncated]") if depth > 12
      case raw = value.raw
      when Hash
        filtered = {} of String => JSON::Any
        raw.first(100).each { |key, entry| filtered[key] = key.matches?(SENSITIVE) ? JSON::Any.new("[redacted]") : clean(entry, depth + 1) }
        JSON::Any.new(filtered)
      when Array
        JSON::Any.new(raw.first(200).map { |entry| clean(entry, depth + 1) })
      when String
        JSON::Any.new(text(raw)[0, 4096])
      else
        value
      end
    end

    def self.text(value : String) : String
      value.gsub(/([a-z]+:\/\/)[^\s\/@]+:[^\s\/@]+@/i, "\\1[redacted]@")
        .gsub(/((?:password|secret|token|authorization|api_key)\s*[=:]\s*)[^\s,;]+/i, "\\1[redacted]")
        .gsub(/Bearer\s+[^\s]+/i, "Bearer [redacted]")
    end
  end
end
