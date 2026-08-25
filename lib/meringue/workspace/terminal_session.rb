# frozen_string_literal: true

require "io/console"
require "pty"
require "thread"

module Meringue
  module Workspace
    # Owns an interactive shell PTY for one worker workspace. It deliberately
    # does not know about agent harness processes: closing or restarting this
    # shell only signals the PTY process group created here.
    class TerminalSession
      DEFAULT_ROWS = 24
      DEFAULT_COLUMNS = 80
      DEFAULT_BUFFER_BYTES = 4 * 1024 * 1024
      READ_CHUNK_BYTES = 16 * 1024
      TERMINATION_GRACE_SECONDS = 1.0
      POLL_INTERVAL = 0.025

      def self.from_config(config, env: ENV)
        section = config.respond_to?(:section) ? config.section("workspace") : {}
        section = {} unless section.is_a?(Hash)
        new(
          command: section["shell_command"],
          env: env,
          max_buffer_bytes: section.fetch("terminal_buffer_bytes", DEFAULT_BUFFER_BYTES)
        )
      end

      def initialize(command: nil, env: ENV, max_buffer_bytes: DEFAULT_BUFFER_BYTES, pty: PTY,
                     session_environment_patterns: [])
        @env = stringify_environment(env)
        @session_environment_patterns = Array(session_environment_patterns)
        @pty = pty
        @max_buffer_bytes = normalize_buffer_size(max_buffer_bytes)
        @mutex = Mutex.new
        @write_mutex = Mutex.new
        @condition = ConditionVariable.new
        @output = +"".b
        @transcript = +"".b
        @state = "new"
        @exit_status = nil
        @workspace_path = nil
        @reader = nil
        @writer = nil
        @pid = nil
        @process_group_id = nil
        @reader_thread = nil
        @wait_thread = nil
        @configuration_error = nil
        @command = LaunchCommand.parse(command, default: default_shell_command(@env), label: "workspace shell_command")
      rescue ArgumentError => e
        @configuration_error = e.message
        @command = nil
        @state = "failed"
      end

      attr_reader :configuration_error

      def start(workspace_path:, rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS, on_started: nil)
        path = expanded_workspace_path(workspace_path)
        return rejected("This worker has no assigned workspace for its terminal.") unless path
        return rejected("Worker workspace is missing or is not a directory: #{path}") unless Dir.exist?(path)
        if configuration_error
          return rejected("Terminal configuration is invalid: #{configuration_error}. Update [workspace] shell_command in ~/.meringue/config.toml.")
        end

        existing = @mutex.synchronize do
          if running_unlocked?
            if @workspace_path == path
              true
            else
              return rejected("This terminal is already running in #{@workspace_path}; create a separate TerminalSession for #{path}.")
            end
          end
        end
        if existing
          resize(rows: rows, columns: columns)
          return active_result("Terminal is already running in #{path}.", started: false)
        end

        # Reap and close a previous shell before replacing its IO. This prevents
        # an old waiter thread from closing a newly-started PTY during restart.
        close if @mutex.synchronize { !@pid.nil? }

        executable = command.executable_path(cwd: path, path: env.fetch("PATH", ""))
        unless executable
          return failed("Could not start the workspace terminal because #{command.executable.inspect} was not found or is not executable. Set [workspace] shell_command to an installed shell CLI.")
        end

        reader, writer, child_pid = pty.spawn(
          terminal_environment(path),
          executable,
          *command.argv.drop(1),
          chdir: path
        )
        reader.binmode
        writer.binmode
        writer.sync = true
        process_group_id = safe_process_group_id(child_pid)

        @mutex.synchronize do
          @workspace_path = path
          @reader = reader
          @writer = writer
          @pid = child_pid
          @process_group_id = process_group_id
          @state = "running"
          @exit_status = nil
          @output.clear
          @transcript.clear
        end
        on_started&.call(child_pid)
        resize(rows: rows, columns: columns)
        start_background_threads(reader, child_pid)
        active_result("Started terminal in #{path}.", started: true)
      rescue Errno::ENOENT
        failed("Could not start the workspace terminal because #{command&.executable.inspect} was not found. Check [workspace] shell_command.")
      rescue Errno::EACCES
        failed("Could not start the workspace terminal because #{command&.executable.inspect} is not executable. Check its permissions or [workspace] shell_command.")
      rescue SystemCallError => e
        close_handles
        failed("Could not start the workspace terminal in #{path || workspace_path}: #{e.message}")
      rescue StandardError => e
        close_handles
        failed("Could not start the workspace terminal: #{e.class}: #{e.message}")
      end

      def write(data)
        bytes = data.to_s.b
        return active_result("No terminal input to send.") if bytes.empty?

        io = @mutex.synchronize { running_unlocked? ? @writer : nil }
        return failed("Workspace terminal is not running. Open it again to restart the shell.") unless io

        @write_mutex.synchronize do
          offset = 0
          while offset < bytes.bytesize
            written = io.write_nonblock(bytes.byteslice(offset..), exception: false)
            case written
            when :wait_writable
              IO.select(nil, [io], nil, 0.25)
            when Integer
              offset += written
            else
              return failed("Workspace terminal stopped accepting input. Open it again to restart the shell.")
            end
          end
        end
        { "status" => "written", "bytes" => bytes.bytesize }
      rescue Errno::EIO, Errno::EPIPE, IOError => e
        failed("Workspace terminal stopped accepting input: #{e.message}. Open it again to restart the shell.")
      rescue SystemCallError => e
        failed("Could not send input to the workspace terminal: #{e.message}")
      end

      # Returns output not previously drained. A background reader keeps the PTY
      # flowing even while the user has switched back to the agent view.
      def drain_output(timeout: 0)
        @mutex.synchronize do
          if @output.empty? && timeout.to_f.positive? && running_unlocked?
            @condition.wait(@mutex, timeout.to_f)
          end
          bytes = @output.dup
          @output.clear
          bytes
        end
      end

      # Raw PTY output retained for redrawing a terminal after switching views.
      # The oldest bytes are bounded by terminal_buffer_bytes.
      def transcript
        @mutex.synchronize { @transcript.dup }
      end

      def resize(rows:, columns:)
        normalized_rows = positive_dimension(rows, DEFAULT_ROWS)
        normalized_columns = positive_dimension(columns, DEFAULT_COLUMNS)
        io, child_pid = @mutex.synchronize { [@writer, @pid] }
        return failed("Workspace terminal is not running, so it cannot be resized.") unless io && child_pid

        io.winsize = [normalized_rows, normalized_columns]
        signal_process("WINCH", child_pid, group: false)
        {
          "status" => "resized",
          "rows" => normalized_rows,
          "columns" => normalized_columns
        }
      rescue Errno::EIO, Errno::ESRCH, IOError
        failed("Workspace terminal exited before it could be resized. Open it again to restart the shell.")
      rescue SystemCallError => e
        failed("Could not resize the workspace terminal: #{e.message}")
      end

      def alive?
        settle_completed_process
        @mutex.synchronize { running_unlocked? }
      end

      def status
        settle_completed_process
        @mutex.synchronize do
          {
            "state" => @state,
            "pid" => @pid,
            "workspace_path" => @workspace_path,
            "alive" => running_unlocked?,
            "exit_status" => serialized_exit_status(@exit_status),
            "configuration_error" => configuration_error
          }.compact
        end
      end

      # Idempotently stop only this shell and its descendants. Managed agent
      # process ids are never accepted by or visible to this object.
      def close
        pid, process_group_id, reader_thread, wait_thread = @mutex.synchronize do
          @state = "closing" if running_unlocked?
          [@pid, @process_group_id, @reader_thread, @wait_thread]
        end

        if pid && process_alive?(pid)
          signal_owned_process("HUP", pid, process_group_id)
          wait_until_dead(pid, TERMINATION_GRACE_SECONDS / 2)
          if process_alive?(pid)
            signal_owned_process("TERM", pid, process_group_id)
            wait_until_dead(pid, TERMINATION_GRACE_SECONDS)
          end
          signal_owned_process("KILL", pid, process_group_id) if process_alive?(pid)
        end

        close_handles
        reader_thread&.join(TERMINATION_GRACE_SECONDS)
        wait_thread&.join(TERMINATION_GRACE_SECONDS)
        @mutex.synchronize do
          @state = "closed"
          @condition.broadcast
        end
        { "status" => "closed", "message" => "Workspace terminal stopped." }
      rescue StandardError => e
        close_handles
        { "status" => "failed", "message" => "Could not completely stop the workspace terminal: #{e.class}: #{e.message}" }
      end

      private

      attr_reader :command, :env, :pty, :max_buffer_bytes

      def default_shell_command(environment)
        environment["MERINGUE_SHELL"] || environment["SHELL"] || "/bin/sh"
      end

      def terminal_environment(workspace_path)
        SubprocessEnvironment.clean_agent_session(
          env,
          session_environment_patterns: @session_environment_patterns
        ).merge(
          "TERM" => env.fetch("TERM", "xterm-256color"),
          "COLORTERM" => env.fetch("COLORTERM", "truecolor"),
          "MERINGUE_WORKSPACE" => workspace_path.to_s
        )
      end

      def expanded_workspace_path(value)
        return nil if value.to_s.strip.empty?

        File.expand_path(value.to_s)
      end

      def stringify_environment(value)
        value.to_h.each_with_object({}) do |(key, child), result|
          result[key.to_s] = child.to_s
        end
      end

      def normalize_buffer_size(value)
        size = Integer(value)
        raise ArgumentError unless size.positive?

        size
      rescue ArgumentError, TypeError
        raise ArgumentError, "workspace terminal_buffer_bytes must be a positive integer"
      end

      def positive_dimension(value, fallback)
        number = Integer(value)
        number.positive? ? number : fallback
      rescue ArgumentError, TypeError
        fallback
      end

      def start_background_threads(reader, child_pid)
        @reader_thread = Thread.new do
          Thread.current.name = "meringue-workspace-terminal-reader" if Thread.current.respond_to?(:name=)
          read_pty_output(reader)
        end
        @wait_thread = Thread.new do
          Thread.current.name = "meringue-workspace-terminal-waiter" if Thread.current.respond_to?(:name=)
          _pid, exit_status = Process.waitpid2(child_pid)
          record_exit(exit_status)
        rescue Errno::ECHILD
          record_exit(nil)
        end
      end

      def read_pty_output(reader)
        loop do
          chunk = reader.readpartial(READ_CHUNK_BYTES)
          append_output(chunk)
        end
      rescue EOFError, Errno::EIO, IOError
        nil
      rescue SystemCallError => e
        append_output("\r\n[Meringue could not read terminal output: #{e.message}]\r\n")
      ensure
        @mutex.synchronize { @condition.broadcast }
      end

      def append_output(chunk)
        bytes = chunk.to_s.b
        @mutex.synchronize do
          @output << bytes
          @transcript << bytes
          trim_buffer!(@output)
          trim_buffer!(@transcript)
          @condition.broadcast
        end
      end

      def trim_buffer!(buffer)
        overflow = buffer.bytesize - max_buffer_bytes
        buffer.slice!(0, overflow) if overflow.positive?
      end

      def record_exit(exit_status)
        @mutex.synchronize do
          @exit_status = exit_status
          @state = "exited" unless @state == "closed"
          @condition.broadcast
        end
        close_handles
      end

      def running_unlocked?
        @state == "running" && @pid && process_alive?(@pid)
      end

      # There is a very small interval after waitpid reaps the child and before
      # the waiter records its status. Let the waiter acquire the mutex so UI
      # callers never observe the contradictory state running/alive=false.
      def settle_completed_process
        @mutex.synchronize do
          if @state == "running" && @pid && !process_alive?(@pid) && @wait_thread&.alive?
            @condition.wait(@mutex, 0.05)
          end
        end
      end

      def serialized_exit_status(exit_status)
        return nil unless exit_status

        {
          "success" => exit_status.success?,
          "exitstatus" => exit_status.exitstatus,
          "termsig" => exit_status.termsig
        }.compact
      end

      def safe_process_group_id(child_pid)
        Process.getpgid(child_pid)
      rescue Errno::ESRCH, SystemCallError
        nil
      end

      def signal_owned_process(signal, pid, process_group_id)
        if process_group_id == pid
          signal_process(signal, -process_group_id, group: true)
        else
          signal_process(signal, pid, group: false)
        end
      end

      def signal_process(signal, target, group:)
        Process.kill(signal, target)
      rescue Errno::ESRCH
        nil
      rescue Errno::EPERM => e
        raise e unless group
      end

      def process_alive?(pid)
        return false unless pid

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def wait_until_dead(pid, timeout)
        deadline = monotonic_time + timeout
        sleep POLL_INTERVAL while process_alive?(pid) && monotonic_time < deadline
      end

      def close_handles
        handles = @mutex.synchronize do
          current = [@reader, @writer].compact.uniq
          @reader = nil
          @writer = nil
          current
        end
        handles.each do |io|
          io.close unless io.closed?
        rescue IOError, SystemCallError
          nil
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def active_result(message, started: false)
        {
          "status" => "active",
          "message" => message,
          "pid" => @mutex.synchronize { @pid },
          "workspace_path" => @mutex.synchronize { @workspace_path },
          "started" => !!started
        }
      end

      def rejected(message)
        { "status" => "rejected", "message" => message }
      end

      def failed(message)
        @mutex.synchronize { @state = "failed" unless running_unlocked? }
        { "status" => "failed", "message" => message }
      end
    end
  end
end
