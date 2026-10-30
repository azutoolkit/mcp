module AzuMCP
  # SSH keys authorize this restricted protocol, never a model-supplied command.
  # Deploy with a forced command and DisableForwarding on a dedicated account.
  class RemoteOperations
    def initialize(@config : Config)
    end

    def request(target_id : String, body : JSON::Any, deadline = 60.seconds) : JSON::Any
      target = @config.targets[target_id]? || raise ArgumentError.new("Unknown target")
      target.validate!
      command = "#{target.runner} runner --config #{target.config}"
      args = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
              "-o", "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
              "-o", "RemoteCommand=none", "-o", "ControlPath=none", "-o", "ControlMaster=no",
              "-o", "ForkAfterAuthentication=no", "-o", "SendEnv=-*", "-o", "ConnectTimeout=5",
              "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "--", target.host, command]
      response = ProcessRunner.run("ssh", args, Dir.current, deadline, body.to_json, raw_output: true) { |_| }
      unless response.exit_code == 0 && !response.truncated
        raise IO::Error.new("SSH runner failed: #{response.error[0, 2048]}. Reconcile any dispatched operation before retrying")
      end
      JSON.parse(response.output)
    end

    def plan(target_id : String, action : String, args : Array(String)) : JSON::Any
      raise ArgumentError.new("Remote journal capacity reached; archive resolved records before planning more work") if Dir.glob(File.join(@config.state_dir, "remote-*.json")).size >= Operations::MAX_PLANS
      target = @config.targets[target_id]? || raise ArgumentError.new("Unknown target")
      data = request(target_id, AzuMCP.json({method: "plan", workspace: target.workspace, action: action, arguments: args}), 180.seconds)
      received = Plan.from_json(data.to_json)
      received.verify!
      raise ArgumentError.new("Remote plan does not match the requested operation") unless received.workspace == target.workspace && received.action == action && received.arguments == args
      id = data["id"].as_s
      valid_id!(id)
      @config.prepare
      path = path(id)
      File.write(path, {target: target_id, target_digest: Digest::SHA256.hexdigest(target.to_yaml), remote: data}.to_json, perm: 0o600)
      AzuMCP.json({operation_id: id, target: target_id, plan: data, authorization: "azu-mcp approve-remote #{id} --config CONFIG"})
    end

    def review(id : String) : JSON::Any
      valid_id!(id)
      plan = JSON.parse(File.read(path(id)))
      target = @config.targets[plan["target"].as_s]? || raise ArgumentError.new("Target no longer configured")
      raise ArgumentError.new("Target configuration changed; prepare a new plan") unless plan["target_digest"].as_s == Digest::SHA256.hexdigest(target.to_yaml)
      reviewed = Plan.from_json(plan["remote"].to_json)
      reviewed.verify!
      raise ArgumentError.new("Remote plan identifier or workspace changed") unless reviewed.id == id && reviewed.workspace == target.workspace
      plan
    end

    def approve(id : String) : Nil
      plan = review(id)
      raise ArgumentError.new("Remote plan expired") unless plan["remote"]["expires_at"].as_i64 > Time.utc.to_unix
      File.write(path(id) + ".approval", Digest::SHA256.hexdigest(plan.to_json), perm: 0o600)
    end

    def execute(id : String) : JSON::Any
      plan = review(id)
      approval = path(id) + ".approval"
      raise ArgumentError.new("Separate human approval required") unless File.file?(approval) && File.read(approval) == Digest::SHA256.hexdigest(plan.to_json)
      raise ArgumentError.new("Remote plan expired") unless plan["remote"]["expires_at"].as_i64 > Time.utc.to_unix
      File.delete(approval)
      # Consume approval before sending. A network failure is reconciled via status.
      request(plan["target"].as_s, AzuMCP.json({method: "execute", id: id, digest: plan["remote"]["digest"]}))
    end

    def status(id : String) : JSON::Any
      plan = review(id)
      request(plan["target"].as_s, AzuMCP.json({method: "status", id: id}))
    end

    def cancel(id : String) : JSON::Any
      plan = review(id)
      request(plan["target"].as_s, AzuMCP.json({method: "cancel", id: id}))
    end

    private def path(id)
      File.join(@config.state_dir, "remote-#{id}.json")
    end

    private def valid_id!(id)
      raise ArgumentError.new("Invalid operation id") unless id.matches?(/\A[0-9a-f]{32}\z/)
    end
  end
end
