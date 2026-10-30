module AzuMCP
  class TelemetryBroker
    # Narrow allowlist excludes raw SQL literals, auth identifiers, arbitrary
    # request bodies and adapter-specific secrets before they reach any client.
    FIELDS = %w(v at captured_at pid process_id started_at status enabled available backend environment crystal_version
      heap_bytes free_bytes rss_bytes uptime uptime_seconds total count requests errors failed error_rate throughput rps
      p50 p95 p99 p50_ms p95_ms p99_ms max_ms avg_ms average_ms duration_ms ms waiting pending processing completed retries workers queues name
      active mounts unmounts refreshes average_age slow_queries n_plus_one patterns queries pool transactions
      size idle checked_out checkout_wait_ms max_size hits misses reads writes deletes operations hit_rate
      sent delivered failed_count registered enabled_features features runtime database cache components mailers sessions auth
      sql query normalized_sql process port crystal handler tracing endpoints profiler leak_suspected detail section recent_errors
      gets sets written_bytes breakdown operation store hit event outcome type avg_age memory_delta
      tables columns nullable primary foreign_key schema_name migration_version pool_waits
      in_flight max pool_wait_ms slow class file line trace id jid queue failed_at redrivable state nested
      steps attempt depends_on workflow_id worker_id heartbeat_at last_seen concurrency busy processed rate delivery
      health score insights dashboard summary latency memory traffic routes methods GET POST PUT PATCH DELETE HEAD OPTIONS
      histogram buckets series samples recent slowest spans method route path endpoint level message exception_class stack
      gc_heap_bytes latency_ms memory_bytes label timestamp value total_queries total_time_ms active_count warning_count)

    def initialize(@config : Config)
    end

    def snapshot(id : String, section : String? = nil) : JSON::Any
      w = @config.workspace(id)
      path = w.snapshot
      return AzuMCP.json({status: "unavailable", reason: "Configure a snapshot exported by azu dev --snapshot"}) unless path && File.file?(path)
      raise ArgumentError.new("Snapshot exceeds 1 MiB") if File.size(path) > MAX_FILE
      age = (Time.utc - File.info(path).modification_time).total_seconds
      value = JSON.parse(File.read(path))
      if at = value["at"]?.try(&.as_s?)
        sampled = Time.parse_rfc3339(at) rescue nil
        age = Math.max(age, (Time.utc - sampled).total_seconds) if sampled
      end
      raise ArgumentError.new("Unsupported snapshot") unless value["v"]?.try(&.as_i?) == 1
      feature = section && value["dashboard"]?.try(&.as_h?).try(&.["features"]?).try(&.as_h?).try(&.[section]?).try(&.as_s?)
      return AzuMCP.json({status: "disabled"}) if feature == "disabled"
      return AzuMCP.json({status: "unavailable", reason: "Application reports this provider unavailable"}) if feature == "unavailable"
      payload = section ? value[section]? : value
      if section && (payload.nil? || payload.try(&.as_h?).try(&.empty?))
        dashboard = value["dashboard"]?.try(&.as_h?)
        payload = dashboard.try(&.[section]?) || dashboard.try(&.["summary"]?).try(&.as_h?).try(&.[section]?)
      end
      if section == "database" && (summary = value["dashboard"]?.try(&.as_h?).try(&.["database"]?).try(&.as_h?))
        payload = JSON::Any.new((payload.try(&.as_h?) || {} of String => JSON::Any).merge(summary))
      end
      return AzuMCP.json({status: "unavailable", reason: "Application does not export #{section}"}) unless payload
      if payload.as_h?.try(&.["enabled"]?).try(&.as_bool?) == false
        return AzuMCP.json({status: "disabled"})
      end
      total = payload.as_h?.try(&.["total"]?).try(&.as_i64?)
      if captured = payload.as_h?.try(&.["captured_at"]?).try(&.as_s?)
        sampled = Time.parse_rfc3339(captured) rescue nil
        age = Math.max(age, (Time.utc - sampled).total_seconds) if sampled
      end
      AzuMCP.json({status: age > 10 ? "stale" : (total == 0 ? "empty" : "available"), age_seconds: age, data: filter(payload),
                   note: "Retained telemetry, not a full audit log. Redis connectivity is not worker health. Auth events are not session counts."})
    end

    def filter(value : JSON::Any, depth = 0) : JSON::Any
      return JSON::Any.new(nil) if depth > 12
      case raw = value.raw
      when Hash
        filtered = {} of String => JSON::Any
        raw.each do |key, item|
          next unless FIELDS.includes?(key)
          filtered[key] = if %w(sql query normalized_sql).includes?(key) && (text = item.as_s?)
                            JSON::Any.new(normalize_sql(text))
                          else
                            filter(item, depth + 1)
                          end
        end
        JSON::Any.new(filtered)
      when Array
        JSON::Any.new(raw.first(120).map { |entry| filter(entry, depth + 1) })
      when String
        JSON::Any.new(Redaction.text(raw)[0, 1024])
      else
        value
      end
    end

    private def normalize_sql(text : String) : String
      normalized = text.gsub(/(\$[A-Za-z_]\w*\$|\$\$).*?\1/m, "?")
        .gsub(/'(?:''|\\.|[^'\\])*'|"(?:""|[^"])*"/, "?")
        .gsub(/--[^\n]*|\/\*.*?\*\//m, " ")
        .gsub(/\b\d+(?:\.\d+)?\b/, "?")
      return "[unparseable SQL omitted]" if normalized.matches?(/['"]|\$[A-Za-z_]\w*\$|\$\$/)
      normalized[0, 4096]
    end
  end
end
