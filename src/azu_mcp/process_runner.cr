module AzuMCP
  # Always drains pipes, retaining only a bounded prefix. The process group is
  # terminated on cancellation/deadline so descendants cannot hold pipes open.
  class Capture < IO
    getter truncated = false
    @buffer = IO::Memory.new

    def initialize(@limit = 131_072)
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("write-only")
    end

    def write(slice : Bytes) : Nil
      size = Math.min(slice.size, @limit - @buffer.size)
      @buffer.write(slice[0, size]) if size > 0
      @truncated = true if size < slice.size
    end

    def raw : String
      @buffer.to_s.scrub
    end

    def text : String
      Redaction.text(@buffer.to_s.scrub)
    end
  end

  class RunningProcess
    getter process : Process
    getter cancelled = false

    def initialize(executable : String, args : Array(String), directory : String, output : IO, error : IO, input : IO = IO::Memory.new, env : Process::Env = nil)
      @process = Process.new(ProcessRunner.helper, ["__exec", executable] + args, chdir: directory, input: input, output: output, error: error, env: env)
    end

    def cancel : Nil
      @cancelled = true
      Process.signal(Signal::KILL, -process.pid) rescue nil
      process.signal(Signal::KILL) rescue nil
    end
  end

  record Execution, exit_code : Int32, output : String, error : String, truncated : Bool, timed_out : Bool do
    include JSON::Serializable
  end

  module ProcessRunner
    @@active = Set(RunningProcess).new

    def self.cancel_all : Nil
      @@active.each(&.cancel)
    end

    def self.helper : String
      ENV["AZU_MCP_EXECUTABLE"]? || Process.executable_path || raise "Cannot locate azu-mcp executable"
    end

    def self.run(executable : String, args : Array(String), directory : String, deadline = 60.seconds,
                 input = "", env : Process::Env = nil, raw_output = false, &started : RunningProcess ->) : Execution
      output = Capture.new
      error = Capture.new
      running = RunningProcess.new(executable, args, directory, output, error, IO::Memory.new(input), env)
      @@active << running
      yield running
      done = Channel(Process::Status).new(1)
      spawn { done.send(running.process.wait) }
      timed_out = false
      status = select
      when result = done.receive then result
      when timeout(deadline)
        timed_out = true
        running.cancel
        done.receive
      end
      Execution.new(status.exit_code? || 128 + (status.exit_signal?.try(&.value) || 0), raw_output ? output.raw : output.text, error.text, output.truncated || error.truncated, timed_out)
    ensure
      running.try { |p| p.cancel if p.process.exists? }
      @@active.delete(running) if running
    end
  end
end
