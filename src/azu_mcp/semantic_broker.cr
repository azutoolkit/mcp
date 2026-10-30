module AzuMCP
  # LSP bridge uses Content-Length framing (MCP stdio uses newline JSON).
  # Each bounded session owns one process; no duplicate in-editor LSP is started.
  class SemanticBroker
    @busy = false
    @process : Process?
    @compiler : RunningProcess?

    def initialize(@config : Config)
    end

    def query(workspace : String, method : String, path : String, line : Int32, character : Int32, entrypoint : String? = nil) : JSON::Any
      w = @config.workspace(workspace)
      w.trust!
      source = Paths.safe(w.canonical, path)
      raise ArgumentError.new("Expected a Crystal source file") unless source.ends_with?(".cr")
      text = Paths.read(w.canonical, path)
      raise ArgumentError.new("Use zero-based document positions") if line < 0 || character < 0 || line >= text.lines.size
      if method != "textDocument/completion"
        return compiler_query(w, method, path, line, character, text, entrypoint)
      end
      executable = w.crystalline
      return AzuMCP.json({status: "unavailable", reason: "Configure a validated crystalline executable; indexed declarations are not type inference"}) unless executable
      raise ArgumentError.new("Semantic session busy; retry after the current request") if @busy
      @busy = true
      owned = true
      process = Process.new(ProcessRunner.helper, ["__exec", executable], chdir: w.canonical, input: Process::Redirect::Pipe, output: Process::Redirect::Pipe, error: Process::Redirect::Close)
      @process = process
      replies = Channel(JSON::Any | Exception).new(4)
      spawn do
        begin
          loop do
            value = read_frame(process.output)
            replies.send(value) if value["id"]?
          end
        rescue ex
          replies.send(ex) unless replies.closed?
        end
      end
      send_frame(process.input, {jsonrpc: "2.0", id: 1, method: "initialize", params: {processId: Process.pid, rootUri: URI.new(scheme: "file", path: w.canonical).to_s, capabilities: {} of String => String}})
      initialized = reply(replies, 30.seconds)
      raise ArgumentError.new("LSP initialization failed") if initialized["error"]?
      send_frame(process.input, {jsonrpc: "2.0", method: "initialized", params: {} of String => String})
      uri = URI.new(scheme: "file", path: source).to_s
      send_frame(process.input, {jsonrpc: "2.0", method: "textDocument/didOpen", params: {textDocument: {uri: uri, languageId: "crystal", version: 1, text: text}}})
      send_frame(process.input, {jsonrpc: "2.0", id: 2, method: method, params: {textDocument: {uri: uri}, position: {line: line, character: character}}})
      response = reply(replies, 60.seconds)
      current = Digest::SHA256.hexdigest(Paths.read(w.canonical, path))
      digest = Digest::SHA256.hexdigest(text)
      AzuMCP.json({status: current != digest ? "stale" : (response["result"]?.try(&.raw) ? "available" : "unavailable"), evidence: "language-server", digest: digest,
                   result: response["result"]?, error: response["error"]?, note: "Backend may return indexed completions or omit uninstantiated methods; not all results establish compiler-inferred types."})
    ensure
      if process
        Process.signal(Signal::KILL, -process.pid) rescue nil
        process.signal(Signal::KILL) rescue nil
        process.wait rescue nil
      end
      replies.try(&.close)
      @busy = false if owned
      @process = nil if owned
    end

    def cancel : Nil
      @compiler.try(&.cancel)
      if process = @process
        Process.signal(Signal::KILL, -process.pid) rescue nil
        process.signal(Signal::KILL) rescue nil
      end
    end

    private def compiler_query(w : Workspace, method : String, path : String, line : Int32, character : Int32, text : String, entrypoint : String?) : JSON::Any
      owned = false
      raise ArgumentError.new("Semantic session busy") if @busy
      @busy = true
      owned = true
      main = entrypoint
      unless main
        manifest = YAML.parse(Paths.read(w.canonical, "shard.yml"))
        targets = manifest["targets"]?.try(&.as_h?)
        if targets && targets.size == 1
          main = targets.values.first["main"].as_s.lchop("./")
        elsif targets && targets.size > 1
          raise ArgumentError.new("Multiple targets: supply entrypoint explicitly")
        else
          main = path
        end
      end
      Paths.safe(w.canonical, main)
      units = 0
      column = 0
      text.lines[line].each_char do |char|
        break if units >= character
        units += char.ord > 0xffff ? 2 : 1
        column += 1
      end
      raise ArgumentError.new("Invalid UTF-16 position") unless units == character
      tool = method == "textDocument/definition" ? "implementations" : "context"
      result = ProcessRunner.run(w.crystal, ["tool", tool, "--format", "json", "--no-color", "--cursor", "#{path}:#{line + 1}:#{column + 1}", main], w.canonical, 90.seconds, raw_output: true) { |process| @compiler = process }
      digest = Digest::SHA256.hexdigest(text)
      stale = Digest::SHA256.hexdigest(Paths.read(w.canonical, path)) != digest
      data = JSON.parse(result.output) rescue JSON::Any.new(nil)
      AzuMCP.json({status: stale ? "stale" : (result.exit_code == 0 && !data.raw.nil? ? "available" : "unavailable"),
                   evidence: "compiler-confirmed", compiler_tool: tool, entrypoint: main, digest: digest,
                   result: data, diagnostics: result.error, timed_out: result.timed_out,
                   note: "Context lists compiler-inferred variables at this location; uninstantiated methods may have no inference."})
    ensure
      if owned
        @compiler = nil
        @busy = false
      end
    end

    private def send_frame(io : IO, message)
      body = message.to_json
      io << "Content-Length: " << body.bytesize << "\r\n\r\n" << body
      io.flush
    end

    private def read_frame(io : IO) : JSON::Any
      length = nil
      20.times do
        header = io.gets('\n', 4097) || raise IO::EOFError.new
        raise IO::Error.new("LSP header too large") if header.bytesize > 4096
        break if header.strip.empty?
        length = header.split(':', 2)[1].strip.to_i? if header.downcase.starts_with?("content-length:")
      end
      size = length || raise IO::Error.new("LSP missing content length")
      raise IO::Error.new("LSP response too large") unless size.in?(1..MAX_FILE)
      JSON.parse(io.read_string(size))
    end

    private def reply(channel, deadline) : JSON::Any
      result = select
      when value = channel.receive then value
      when timeout(deadline) then raise IO::TimeoutError.new("Semantic analysis deadline exceeded")
      end
      raise result if result.is_a?(Exception)
      result
    end
  end
end
