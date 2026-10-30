module AzuMCP
  # Protocol boundary: schemas, validation, redaction and bounded tool results.
  class ToolRegistry
    def initialize(@protocol : MCP::Server::Server)
    end

    private def schema(type : String) : JSON::Any
      case type
      when "array"   then AzuMCP.json({type: "array", items: {type: "string", maxLength: 1024}, maxItems: 64})
      when "integer" then AzuMCP.json({type: "integer", minimum: 0, maximum: 1_000_000})
      else                AzuMCP.json({type: "string", maxLength: 4096})
      end
    end

    def register(name : String, description : String, fields : Hash(String, String), required : Array(String), *, read_only = false, destructive = false, &block : Hash(String, JSON::Any) -> JSON::Any)
      props = fields.transform_values { |type| schema(type) }
      @protocol.add_tool(name, description, MCP::Protocol::Tool::Input.new(props, required)) do |request|
        begin
          args = request.arguments || {} of String => JSON::Any
          validate(args, fields, required)
          value = Redaction.public_view(block.call(args))
          value = AzuMCP.json({result: value}) unless value.as_h?
          body = value.to_json
          raise ArgumentError.new("Response exceeds 1 MiB; narrow your request") if body.bytesize > MAX_FILE
          MCP::Protocol::CallToolResult.new([MCP::Protocol::TextContentBlock.new(body)] of MCP::Protocol::ContentBlock, value.as_h)
        rescue ex
          error = Redaction.text(ex.message || "Tool failed")
          MCP::Protocol::CallToolResult.new([MCP::Protocol::TextContentBlock.new(error)] of MCP::Protocol::ContentBlock, is_error: true)
        end
      end
      @protocol.annotate_tool(name, read_only, destructive)
    end

    private def validate(args : Hash(String, JSON::Any), fields : Hash(String, String), required : Array(String)) : Nil
      raise ArgumentError.new("Unknown argument") if args.keys.any? { |key| !fields.has_key?(key) }
      raise ArgumentError.new("Missing required argument") if required.any? { |key| !args.has_key?(key) }
      args.each do |key, value|
        valid = case fields[key]
                when "integer" then value.as_i64?.try { |n| n.in?(0..1_000_000) }
                when "array"   then value.as_a?.try { |items| items.size <= 64 && items.all? { |item| item.as_s?.try { |s| s.bytesize <= 1024 } } }
                else                value.as_s?.try { |s| s.bytesize <= 4096 }
                end
        raise ArgumentError.new("Invalid argument #{key}") unless valid
      end
    end
  end
end
