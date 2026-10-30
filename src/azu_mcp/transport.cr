require "mcp"

# Upstream Input currently omits additionalProperties. Keep schema enforcement
# in our dispatcher as well; annotations are hints, never authorization.
struct MCP::Protocol::Tool::Input
  getter additionalProperties : Bool = false
end

# Compatibility fixes for the pinned SDK's tools-list constructor and cursor.
class MCP::Protocol::ListToolsResult
  def initialize(@tools, @next_cursor = nil, @meta = nil)
    super(@next_cursor, @meta)
  end
end

abstract class MCP::Protocol::PaginatedResult
  @[JSON::Field(key: "nextCursor")]
  property next_cursor : String?
end

class MCP::Server::Server
  def annotate_tool(name : String, read_only : Bool, destructive : Bool)
    registered = @tools[name]
    old = registered.tool
    annotations = MCP::Protocol::ToolAnnotations.new(read_only_hint: read_only, destructive_hint: destructive, open_world_hint: true)
    @tools[name] = RegisteredTool.new(MCP::Protocol::Tool.new(name, old.input_schema, old.description, annotations: annotations), registered.handler)
  end
end

module AzuMCP
  class StdioTransport < MCP::Shared::AbstractTransport
    SEMANTIC_TOOLS = %w(azu_type_at azu_complete azu_definition)
    @closed = false
    @initialized = false
    @write_lock = Mutex.new
    @active = {} of String => String
    @cancelled = Set(String).new
    property on_cancel : Proc(String, Nil) = ->(_name : String) { }

    getter done = Channel(Nil).new(1)

    def initialize(@input : IO, @output : IO)
      super()
    end

    def start
      spawn do
        begin
          while line = @input.gets('\n', MAX_FILE + 1)
            raise IO::Error.new("MCP frame exceeds 1 MiB") if line.bytesize > MAX_FILE || !line.ends_with?('\n')
            next if line.strip.empty?
            raw = nil
            begin
              raw = JSON.parse(line)
              unless raw["jsonrpc"]?.try(&.as_s?) == "2.0"
                error(raw["id"]?, -32600, "Invalid JSON-RPC request")
                next
              end
              method = raw["method"]?.try(&.as_s?)
              if method == "initialize"
                if @initialized
                  error(raw["id"]?, -32600, "Already initialized")
                  next
                end
              elsif !@initialized && method != "ping"
                error(raw["id"]?, -32002, "Initialize first")
                next
              end
              if method == "notifications/cancelled"
                if request_id = raw["params"]?.try(&.["requestId"]?)
                  key = request_id.to_json
                  if name = @active[key]?
                    @cancelled << key
                    @on_cancel.call(name)
                  end
                end
                next
              end
              raw.as_h["params"] = JSON.parse("{}") unless raw["params"]?
              message = MCP::Protocol::JSONRPCMessage.from_json(raw.to_json)
              @initialized = true if method == "initialize"
              if method == "initialize" || !raw["id"]?
                @_on_message.call(message)
              else
                key = raw["id"].to_json
                name = raw["params"]?.try(&.["name"]?).try(&.as_s?) || method || ""
                if @active.size >= 8 || @active.has_key?(key)
                  error(raw["id"]?, -32000, "Server busy or duplicate request ID")
                  next
                end
                if SEMANTIC_TOOLS.includes?(name) && @active.each_value.any? { |active| SEMANTIC_TOOLS.includes?(active) }
                  error(raw["id"]?, -32000, "Semantic session busy")
                  next
                end
                @active[key] = name
                dispatch(message, key)
              end
            rescue JSON::ParseException
              error(raw.try(&.["id"]?), raw ? -32602 : -32700, raw ? "Invalid request parameters" : "Invalid JSON")
            rescue ex
              error(raw.try(&.["id"]?), -32602, "Invalid request")
            end
          end
        rescue IO::Error
        ensure
          close
        end
      end
    end

    private def dispatch(message : MCP::Protocol::JSONRPCMessage, key : String)
      spawn do
        begin
          @_on_message.call(message)
        ensure
          @active.delete(key)
          @cancelled.delete(key)
        end
      end
    end

    def send(message : MCP::Protocol::JSONRPCMessage)
      if message.is_a?(MCP::Protocol::JSONRPCMessageWithId)
        return if @cancelled.includes?(message.id.to_json)
      end
      write(message.to_json) unless @closed
    end

    def close
      return if @closed
      @closed = true
      @_on_close.call
      @done.send(nil)
    end

    def drain(deadline = 5.seconds)
      expires = Time.instant + deadline
      while !@active.empty? && Time.instant < expires
        sleep 10.milliseconds
      end
    end

    private def error(id : JSON::Any?, code, message)
      return if id && id.raw.nil?
      write({jsonrpc: "2.0", id: id, error: {code: code, message: message}}.to_json)
    end

    private def write(body : String)
      @write_lock.synchronize do
        @output.puts(body)
        @output.flush
      end
    end
  end
end
