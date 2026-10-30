module AzuMCP
  record Source, repository : String, root : String, version : String, revision : String, origin : String do
    include JSON::Serializable
  end

  class Catalog
    def initialize(@config : Config)
    end

    def sources(id : String) : Array(Source)
      workspace = @config.workspace(id)
      root = workspace.canonical
      lock = yaml(File.join(root, "shard.lock"))
      result = [] of Source
      manifest = yaml(File.join(root, "shard.yml"))
      own_name = manifest["name"]?.try(&.as_s?)
      REPOSITORIES.each do |repo|
        dep_name = repo.tr("-", "_")
        entry = lock["shards"]?.try { |s| s[dep_name]? || s[repo]? }
        installed = File.join(root, "lib", dep_name)
        configured = workspace.repositories[repo]?
        # Private source access requires an explicit per-workspace opt-in even
        # when the dependency is already installed under lib/.
        next if repo == "joobq-pro" && !configured
        path = if own_name == repo || own_name == dep_name
                 root
               elsif entry && canonical_github?(entry, repo) && Dir.exists?(installed)
                 installed
               elsif configured
                 configured
               else
                 next
               end
        next unless Dir.exists?(path)
        source_root = File.realpath(path)
        shard = yaml(File.join(source_root, "shard.yml"))
        version = shard["version"]?.try(&.as_s?) || "unknown"
        revision = entry.try(&.["version"]?).try(&.as_s?) || version
        reference = configured == path || path == root
        revision = "working-tree" if reference
        origin = reference ? "configured checkout; compare with application lock" : "installed"
        result << Source.new(repo, source_root, version, revision, origin)
      end
      result
    end

    def inspect(id : String) : JSON::Any
      w = @config.workspace(id)
      manifest = yaml(File.join(w.canonical, "shard.yml"))
      lock = yaml(File.join(w.canonical, "shard.lock"))
      Redaction.clean(AzuMCP.json({workspace: id, root: w.canonical, trusted: w.trusted, environment: w.environment,
                                   manifest: manifest, dependencies: lock["shards"]?, repositories: list(id),
                                   note: "Declared versions are not a guarantee of runtime compatibility; no application code was loaded."}))
    end

    def list(id : String) : JSON::Any
      found = sources(id)
      AzuMCP.json(REPOSITORIES.map do |repo|
        source = found.find { |item| item.repository == repo }
        {repository: repo, status: source ? "available" : "unavailable", source: source}
      end)
    end

    def source(id : String, repository : String) : Source
      if repository == "application"
        w = @config.workspace(id)
        return Source.new("application", w.canonical, "workspace", "working-tree", "application")
      end
      raise ArgumentError.new("Unsupported repository") unless REPOSITORIES.includes?(repository)
      sources(id).find { |s| s.repository == repository } || raise ArgumentError.new("Repository source unavailable")
    end

    def read(id : String, repository : String, path : String, start : Int32, limit : Int32) : JSON::Any
      source = source(id, repository)
      raise ArgumentError.new("Source type is not indexable") unless indexable?(path)
      text = Paths.read(source.root, path)
      lines = text.lines
      raise ArgumentError.new("Invalid line range") unless start > 0 && limit.in?(1..200)
      AzuMCP.json({repository: repository, version: source.version, revision: source.revision,
                   path: path, line: start, digest: Digest::SHA256.hexdigest(text),
                   content: Redaction.text(lines.skip(start - 1).first(limit).join('\n')), total_lines: lines.size})
    end

    def indexable?(path : String) : Bool
      %w(.cr .md .ecr).any? { |ext| path.ends_with?(ext) } && !path.split('/').any? { |part| %w(lib node_modules bin vendor).includes?(part) || part.starts_with?('.') }
    end

    private def canonical_github?(entry : YAML::Any, repo : String) : Bool
      url = entry["git"]?.try(&.as_s?) || entry["github"]?.try(&.as_s?) || ""
      url == "azutoolkit/#{repo}" || url == "https://github.com/azutoolkit/#{repo}.git" || url == "https://github.com/azutoolkit/#{repo}"
    end

    private def yaml(path : String) : YAML::Any
      return YAML.parse("{}") unless File.file?(path)
      raise ArgumentError.new("Manifest exceeds 1 MiB") if File.size(path) > MAX_FILE
      YAML.parse(File.read(path))
    end
  end
end
