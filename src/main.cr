require "./azu_mcp"
require "option_parser"

lib LibC
  fun setsid : Int32
end

if ARGV.first? == "__exec"
  raise "Process session creation failed" if LibC.setsid < 0
  Process.exec(ARGV[1], ARGV[2..])
end

if ARGV.first? == "__build"
  exit AzuMCP::Build.run(ARGV[1])
end

Log.setup(:warn, Log::IOBackend.new(STDERR))
begin
  args = ARGV.dup
  config_path = File.join(Path.home.to_s, ".config/azu-mcp/config.yml")
  OptionParser.parse(args) do |parser|
    parser.on("--config PATH", "User-owned configuration") { |path| config_path = path }
    parser.on("--version", "Version") { puts AzuMCP::VERSION; exit }
    parser.on("--help", "Help") do
      puts "azu-mcp serve|check|approve PLAN_ID --config PATH\nMutations require approval through a separate terminal. Stdout is MCP-only during serve."
      exit
    end
  end
  config = AzuMCP::Config.load(config_path)
  case args.first? || "serve"
  when "serve"
    AzuMCP::Server.new(config).run
  when "check"
    puts({version: AzuMCP::VERSION, workspaces: config.workspaces.keys, repositories: AzuMCP::REPOSITORIES}.to_json)
  when "worker"
    operations = AzuMCP::Operations.new(config)
    id = args[1]? || raise "Plan ID required"
    Signal::TERM.trap { operations.cancel(id) }
    Signal::INT.trap { operations.cancel(id) }
    operations.execute(id)
    operations.wait(id)
  when "runner"
    raise "Production runner disabled" unless config.production_enabled
    body = STDIN.gets('\0', AzuMCP::MAX_FILE + 1) || ""
    raise "Request too large" if body.bytesize > AzuMCP::MAX_FILE
    request = JSON.parse(body)
    operations = AzuMCP::Operations.new(config)
    case request["method"].as_s
    when "plan"
      workspace = request["workspace"].as_s
      raise "Remote runner requires a production workspace" unless config.workspace(workspace).environment == "production"
      plan = operations.plan(workspace, request["action"].as_s, request["arguments"].as_a.map(&.as_s))
      puts plan.to_json
    when "execute"
      id = request["id"].as_s
      plan = operations.load_plan(id)
      raise "Only production plans may use the runner" unless config.workspace(plan.workspace).environment == "production"
      operations.approve(id, request["digest"].as_s)
      operations.mark_dispatched(id)
      # The SSH principal is authorized for this restricted action set. The
      # detached worker owns the operation after SSH disconnects.
      Process.new(Process.executable_path.not_nil!, ["__exec", Process.executable_path.not_nil!, "worker", id, "--config", File.expand_path(config_path)], input: Process::Redirect::Close, output: Process::Redirect::Close, error: Process::Redirect::Close)
      response = nil
      100.times do
        begin
          state = operations.status(id)
          if state["status"].as_s == "unknown"
            sleep 50.milliseconds
            next
          end
          response = state
          break
        rescue
          sleep 50.milliseconds
        end
      end
      puts (response || operations.status(id)).to_json
    when "cancel"
      puts operations.cancel(request["id"].as_s).to_json
    when "status"
      puts operations.status(request["id"].as_s).to_json
    else
      raise "Unsupported runner method"
    end
  when "approve-remote"
    raise "Approval requires an interactive terminal" unless STDIN.tty? && STDOUT.tty?
    remote = AzuMCP::RemoteOperations.new(config)
    id = args[1]? || raise "Plan ID required"
    puts remote.review(id).to_pretty_json
    print "Approve this exact remote plan? Type #{id}: "
    raise "Not approved" unless STDIN.gets.try(&.strip) == id
    remote.approve(id)
    puts "Remote plan approved"
  when "approve"
    raise "Approval requires an interactive terminal" unless STDIN.tty? && STDOUT.tty?
    operations = AzuMCP::Operations.new(config)
    id = args[1]? || raise "Provide the plan ID"
    plan = operations.load_plan(id)
    puts plan.to_pretty_json
    print "Approve this exact plan? Type #{plan.id}: "
    raise "Not approved" unless STDIN.gets.try(&.strip) == plan.id
    operations.approve(id, plan.digest)
    puts "Approved until #{Time.unix(plan.expires_at)}"
  else
    raise "Unknown command"
  end
rescue ex
  STDERR.puts AzuMCP::Redaction.text(ex.message || "MCP failed")
  exit 1
end
