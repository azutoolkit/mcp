module AzuMCP
  class Plan
    include JSON::Serializable
    getter id : String
    getter workspace : String
    getter action : String
    getter arguments : Array(String)
    getter fingerprint : String
    getter target : String?
    getter expires_at : Int64
    getter details : JSON::Any
    getter digest : String

    def initialize(@workspace, @action, @arguments, @fingerprint, @details, @target = nil)
      @id = Random::Secure.hex(16)
      @expires_at = Time.utc.to_unix + 900
      @digest = Digest::SHA256.hexdigest({@id, @workspace, @action, @arguments, @fingerprint, @target, @expires_at, @details}.to_json)
    end

    def verify! : Nil
      expected = Digest::SHA256.hexdigest({@id, @workspace, @action, @arguments, @fingerprint, @target, @expires_at, @details}.to_json)
      raise ArgumentError.new("Plan content no longer matches its digest; prepare a new plan") unless expected == @digest
    end
  end

  class Operation
    include JSON::Serializable
    getter id : String
    getter plan : Plan
    property status : String = "queued"
    property updated_at : Int64 = Time.utc.to_unix
    @[JSON::Field(ignore: true)]
    property lease : File? = nil
    property result : JSON::Any? = nil
    @[JSON::Field(ignore: true)]
    property process : RunningProcess? = nil

    def initialize(@plan)
      @id = plan.id
    end
  end

  class Operations
    ACTIONS   = %w(build test doctor generate db:migrate db:rollback jobs:retry jobs:pause jobs:resume)
    MUTATIONS = %w(generate db:migrate db:rollback jobs:retry jobs:pause jobs:resume)
    MAX_PLANS = 1000
    @running = {} of String => Operation
    @busy = Set(String).new

    def initialize(@config : Config)
      @config.prepare
      Dir.mkdir_p(File.join(@config.state_dir, "operations"), 0o700)
    end

    def fingerprint(w : Workspace) : String
      digest = Digest::SHA256.new
      digest.update({w.canonical, w.environment, w.azu, w.crystal}.to_json)
      %w(shard.yml shard.lock).each do |name|
        path = File.join(w.canonical, name)
        digest.update(File.read(path)) if File.file?(path)
      end
      # Includes source changes to invalidate approved plans after edits.
      paths = %w(src db config spec).flat_map { |directory| Dir.glob(File.join(w.canonical, directory, "**", "*.cr")) }.uniq.sort
      raise ArgumentError.new("Workspace has more than 10,000 source files; configure a smaller workspace") if paths.size > 10_000
      paths.each do |path|
        relative = Path[path].relative_to(w.canonical).to_s
        digest.update(relative)
        digest.update(Paths.read(w.canonical, relative))
      end
      digest.final.hexstring
    end

    def plan(id : String, action : String, args : Array(String), target : String? = nil) : Plan
      w = @config.workspace(id)
      w.trust!
      validate(action, args)
      raise ArgumentError.new("Use remote planning for configured targets") if target
      production!(w, action)
      raise ArgumentError.new("Operation journal capacity reached; archive resolved records before planning more work") if Dir.glob(File.join(@config.state_dir, "operations", "*.plan.json")).size >= MAX_PLANS
      details = AzuMCP.json({command: argv(w, action, args), environment: w.environment,
                             warning: "Migration rollback can lose data; job replay can repeat external effects. No automatic retry after unknown outcomes."})
      if action == "generate"
        response = ProcessRunner.run(w.azu, ["mcp", "bridge", "generate-plan", "--"] + args, w.canonical, 60.seconds, raw_output: true) { |_| }
        raise ArgumentError.new("Generator planning failed: #{response.error}") unless response.exit_code == 0 && !response.truncated
        details = JSON.parse(response.output)
      elsif action.starts_with?("db:") || action.starts_with?("jobs:")
        response = ProcessRunner.run(w.azu, ["mcp", "bridge", "precondition", action] + args, w.canonical, 90.seconds, env: {"CRYSTAL_ENV" => w.environment, "AZU_ENV" => w.environment}, raw_output: true) { |_| }
        unless response.exit_code == 0 && !response.truncated
          raise ArgumentError.new("Cannot verify operation preconditions: #{response.error[0, 4096]}")
        end
        details = JSON.parse(response.output)
      end
      plan = Plan.new(id, action, args, fingerprint(w), details)
      write(plan_path(plan.id), plan.to_json)
      plan
    end

    def approve(id : String, digest : String) : Nil
      plan = load_plan(id)
      raise ArgumentError.new("Plan expired or digest mismatch") unless plan.expires_at > Time.utc.to_unix && plan.digest == digest
      write(approval_path(id), digest)
    end

    def execute(id : String) : JSON::Any
      plan = load_plan(id)
      w = @config.workspace(plan.workspace)
      w.trust!
      validate(plan.action, plan.arguments)
      production!(w, plan.action)
      raise ArgumentError.new("Plan expired") if plan.expires_at <= Time.utc.to_unix
      raise ArgumentError.new("Project changed; create a new plan") unless fingerprint(w) == plan.fingerprint
      if MUTATIONS.includes?(plan.action) || w.environment == "production"
        raise ArgumentError.new("Human review required: azu-mcp approve #{id} --config CONFIG") unless File.file?(approval_path(id)) && File.read(approval_path(id)) == plan.digest
      end
      raise ArgumentError.new("Workspace busy") if @busy.includes?(plan.workspace)
      # The workspace flock serializes the replay guard across processes.
      lease = File.open(File.join(@config.state_dir, "workspace-#{plan.workspace}.lock"), "a", perm: 0o600)
      begin
        lease.flock_exclusive(blocking: false)
        raise ArgumentError.new("Operation was already claimed; inspect its status") if File.exists?(result_path(id))
        File.write(result_path(id), Operation.new(plan).to_json, perm: 0o600)
      rescue ex
        lease.close
        raise ex
      end
      File.delete?(approval_path(id))
      operation = Operation.new(plan)
      operation.lease = lease
      @running[id] = operation
      @busy << plan.workspace
      spawn run(operation, w)
      AzuMCP.json({operation_id: id, status: "queued"})
    end

    def status(id : String) : JSON::Any
      valid_id!(id)
      if operation = @running[id]?
        return AzuMCP.json(operation)
      end
      unless File.file?(result_path(id))
        return AzuMCP.json({operation_id: id, status: "unknown", reason: "Remote worker startup not yet confirmed; reconcile before retrying"}) if File.file?(dispatch_path(id))
        raise ArgumentError.new("Unknown operation")
      end
      result = JSON.parse(File.read(result_path(id)))
      if %w(queued running cancelling).includes?(result["status"].as_s) && Time.utc.to_unix - (result["updated_at"]?.try(&.as_i64) || 0) > 10
        result.as_h["status"] = JSON::Any.new("unknown")
      end
      result
    end

    def mark_dispatched(id : String) : Nil
      load_plan(id)
      write(dispatch_path(id), Time.utc.to_unix.to_s)
    end

    def cancel(id : String) : JSON::Any
      valid_id!(id)
      current = status(id)
      if operation = @running[id]?
        operation.process.try(&.cancel)
        operation.status = "cancelling"
        persist(operation)
      elsif %w(queued running cancelling).includes?(current["status"].as_s) || (current["status"].as_s == "unknown" && File.file?(dispatch_path(id)))
        write(result_path(id) + ".cancel", "cancel")
      end
      status(id)
    end

    def recent(workspace : String) : JSON::Any
      @config.workspace(workspace)
      records = [] of JSON::Any
      Dir.glob(File.join(@config.state_dir, "operations", "*.result.json"))
        .sort_by { |path| File.info(path).modification_time }.reverse_each do |path|
        id = File.basename(path).rchop(".result.json")
        next unless load_plan(id).workspace == workspace
        current = status(id)
        records << AzuMCP.json({operation_id: id, status: current["status"], result: current["result"]?})
        break if records.size == 3
      end
      AzuMCP.json({operations: records, note: "Latest three results; use azu_operation_status for a specific operation ID."})
    end

    def load_plan(id : String) : Plan
      valid_id!(id)
      plan = Plan.from_json(File.read(plan_path(id)))
      raise ArgumentError.new("Plan identifier mismatch") unless plan.id == id
      plan.verify!
      plan
    end

    def wait(id : String) : JSON::Any
      while @running.has_key?(id)
        sleep 50.milliseconds
      end
      status(id)
    end

    def close : Nil
      @running.each_value { |op| op.process.try(&.cancel) }
    end

    private def run(operation : Operation, w : Workspace) : Nil
      operation.status = "running"
      persist(operation)
      spawn do
        while @running.has_key?(operation.id)
          sleep 2.seconds
          if @running.has_key?(operation.id)
            cancel(operation.id) if File.file?(result_path(operation.id) + ".cancel")
            persist(operation)
          end
        end
      end
      command = argv(w, operation.plan.action, operation.plan.arguments)
      if operation.plan.action == "generate"
        command = [w.azu, "mcp", "bridge", "generate-apply"]
      end
      execution = ProcessRunner.run(command.first, command[1..], w.canonical, 300.seconds,
        input: operation.plan.details.to_json,
        env: {"CRYSTAL_ENV" => w.environment, "AZU_ENV" => w.environment, "AZU_UI" => "plain", "NO_COLOR" => "1"}) do |process|
        operation.process = process
        process.cancel if operation.status == "cancelling" || File.file?(result_path(operation.id) + ".cancel")
      end
      operation.result = AzuMCP.json(execution)
      operation.status = if execution.timed_out || operation.process.try(&.cancelled)
                           MUTATIONS.includes?(operation.plan.action) ? "unknown" : "cancelled"
                         elsif execution.exit_code == 0
                           "succeeded"
                         else
                           "failed"
                         end
    rescue ex
      operation.status = "failed"
      operation.result = AzuMCP.json({error: Redaction.text(ex.message || "Execution failed")})
    ensure
      persist(operation)
      operation.lease.try(&.close)
      @busy.delete(operation.plan.workspace)
      @running.delete(operation.id)
    end

    private def validate(action : String, args : Array(String)) : Nil
      raise ArgumentError.new("Unsupported operation") unless ACTIONS.includes?(action)
      raise ArgumentError.new("Too many or oversized arguments") if args.size > 64 || args.any? { |a| a.bytesize > 1024 || a.includes?('\0') }
      case action
      when "build", "doctor", "db:migrate"
        raise ArgumentError.new("Action accepts no arguments") unless args.empty?
      when "test"
        raise ArgumentError.new("Provide only relative spec paths") unless args.all? { |a| a.matches?(/\Aspec\/[\w\/.:-]+\.cr(?::\d+)?\z/) && !a.split('/').includes?("..") }
      when "db:rollback"
        raise ArgumentError.new("Rollback requires one numeric version") unless args.size == 1 && args.first.matches?(/\A\d{1,20}\z/)
      when "jobs:retry", "jobs:pause", "jobs:resume"
        raise ArgumentError.new("Specify one job ID or queue name") unless args.size == 1 && args.first.matches?(/\A[\w:.-]{1,128}\z/)
      when "generate"
        raise ArgumentError.new("Generator arguments required") if args.empty?
        raise ArgumentError.new("Preview flags are managed by MCP") if args.any? { |a| a.in?(%w(--yes --dry-run --check --ui --help --force)) || a.starts_with?("--ui=") }
      end
    end

    private def argv(w : Workspace, action : String, args : Array(String)) : Array(String)
      case action
      when "build"    then [Process.executable_path.not_nil!, "__build", w.crystal]
      when "test"     then [w.crystal, "spec"] + args
      when "doctor"   then [w.azu, "doctor", "--json"]
      when "generate" then [w.azu, "generate"] + args
      else                 [w.azu, "mcp", "bridge", "execute", action] + args
      end
    end

    private def production!(w : Workspace, action : String) : Nil
      return unless w.environment == "production"
      raise ArgumentError.new("Production execution is disabled") unless @config.production_enabled
      raise ArgumentError.new("Action not permitted in production") unless %w(db:migrate db:rollback jobs:retry jobs:pause jobs:resume).includes?(action)
    end

    private def persist(operation : Operation)
      operation.updated_at = Time.utc.to_unix
      write(result_path(operation.id), operation.to_json)
    end

    private def valid_id!(id)
      raise ArgumentError.new("Invalid operation id") unless id.matches?(/\A[0-9a-f]{32}\z/)
    end

    private def plan_path(id)
      File.join(@config.state_dir, "operations", "#{id}.plan.json")
    end

    private def approval_path(id)
      File.join(@config.state_dir, "operations", "#{id}.approval")
    end

    private def result_path(id)
      File.join(@config.state_dir, "operations", "#{id}.result.json")
    end

    private def dispatch_path(id)
      File.join(@config.state_dir, "operations", "#{id}.dispatch")
    end

    private def write(path, content)
      temporary = "#{path}.#{Random::Secure.hex(6)}"
      File.write(temporary, content, perm: 0o600)
      File.rename(temporary, path)
    ensure
      File.delete?(temporary) if temporary
    end
  end
end
