require "./spec_helper"

describe AzuMCP::ProcessRunner do
  it "bounds output and stops descendants on a deadline" do
    next unless ENV["AZU_MCP_EXECUTABLE"]?
    started = Time.instant
    result = AzuMCP::ProcessRunner.run("/bin/sh", ["-c", "sleep 30 & wait"], "/tmp", 100.milliseconds) { |_| }
    result.timed_out.should be_true
    (Time.instant - started).total_seconds.should be < 3
    flooded = AzuMCP::ProcessRunner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero"], "/tmp", 3.seconds) { |_| }
    flooded.truncated.should be_true
    flooded.output.bytesize.should be <= 131072
  end
end
