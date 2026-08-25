# frozen_string_literal: true

require "io/console"
require "pty"
require "thread"

module Meringue
  module Harness
    # One long-lived agent CLI running in its native interactive mode inside a PTY that Meringue
    # owns for the whole life of the session.
    #
    # This is the transport that makes a backend both autonomously drivable and directly viewable
    # without ever handing the session between two writers. Meringue types into the PTY to drive
    # the agent, and the same PTY's rendered screen is what the focused session viewer shows. A
    # user switching into focus is therefore a pure UI change: no turn is aborted, no transport is
    # quiesced, and no process is replaced.
    #
    # Structured results never come from this screen. Interactive agent CLIs draw a TUI whose
    # layout is presentation, not contract, so scraping it for state would be guesswork. The screen
    # is only ever shown to a human; every state decision is read from the harness's own durable
    # transcript (see TranscriptTail).
    class InteractiveProcess
      DEFAULT_ROWS = 40
      DEFAULT_COLUMNS = 120
      READ_CHUNK_BYTES = 16 * 1024
      DEFAULT_MAX_TRANSCRIPT_BYTES = 2 * 1024 * 1024
      TERMINATION_GRACE_SECONDS = 1.0
      POLL_INTERVAL = 0.025

      class StartError < StandardError; end

      attr_reader :argv, :cwd, :pid, :started_at

      def initialize(argv:, cwd:, env: {}, rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS,
                     max_transcript_bytes: DEFAULT_MAX_TRANSCRIPT_BYTES, pty: PTY)
        @argv = Array(argv).map(&:to_s)
        @cwd = File.expand_path(cwd.to_s)
        @env = stringify_environment(env)
        @rows = positive_dimension(rows, DEFAULT_ROWS)
        @columns = positive_dimension(columns, DEFAULT_COLUMNS)
        @max_transcript_bytes = [max_transcript_bytes.to_i, 1024].max
        @pty = pty
        @mutex = Mutex.new
        @write_mutex = Mutex.new
        @condition = ConditionVariable.new
        @screen = Workspace::TerminalScreen.new(rows: @rows, columns: @columns)
        @transcript = +"".b
        @pending = +"".b
        @state = "new"
        @exit_status = nil
        @pid = nil
        @process_group_id = nil
        @started_at = nil
        @output_bytes = 0
      end

      def start
        raise StartError, "interactive process already started" unless @mutex.synchronize { @state == "new" }

        reader, writer, child_pid = pty.spawn(@env, *argv, chdir: cwd)
        reader.binmode
        writer.binmode
        writer.sync = true
        @mutex.synchronize do
          @reader = reader
          @writer = writer
          @pid = child_pid
          @process_group_id = safe_process_group_id(child_pid)
          @state = "running"
          @started_at = Time.now.utc
        end
        apply_winsize(@rows, @columns)
        start_background_threads(reader, child_pid)
        self
      rescue Errno::ENOENT
        @mutex.synchronize { @state = "failed" }
        raise StartError, "#{argv.first.inspect} was not found or is not executable"
      rescue SystemCallError => e
        @mutex.synchronize { @state = "failed" }
        raise StartError, "could not start #{argv.first.inspect}: #{e.message}"
      end

      def write(bytes)
        payload = bytes.to_s.b
        return 0 if payload.empty?

        io = @mutex.synchronize { running_unlocked? ? @writer : nil }
        raise IOError, "interactive agent process is not running" unless io

        @write_mutex.synchronize do
          offset = 0
          while offset < payload.bytesize
            written = io.write_nonblock(payload.byteslice(offset..), exception: false)
            case written
            when :wait_writable then IO.select(nil, [io], nil, 0.25)
            when Integer then offset += written
            else raise IOError, "interactive agent process stopped accepting input"
            end
          end
          offset
        end
      end

      # Total bytes the child has produced. A caller waiting for the TUI to react to input can
      # sample this before writing and wait for it to move, without owning the byte stream itself.
      def output_bytes
        @mutex.synchronize { @output_bytes }
      end

      # The visible screen as plain text. Used only for readiness and for recognizing a modal the
      # agent CLI puts in front of its prompt; never for reading agent results.
      def plain_screen_text
        @mutex.synchronize { @screen.lines.join("\n") }
      end

      # Blocks until the rendered screen matches, so a caller can wait for the agent's prompt to
      # be ready instead of sleeping a fixed interval and hoping.
      def wait_for_screen(timeout:, poll: 0.1)
        deadline = monotonic_now + timeout.to_f
        loop do
          text = plain_screen_text
          return text if yield(text)
          return nil unless alive?
          return nil if monotonic_now >= deadline

          sleep poll
        end
      end

      # Waits for the child to stop producing output, which is how an interactive TUI signals it
      # has finished reacting to the last thing it was sent.
      def wait_for_quiet(quiet_for:, timeout:, poll: 0.05)
        deadline = monotonic_now + timeout.to_f
        last = output_bytes
        stable_since = monotonic_now
        loop do
          sleep poll
          current = output_bytes
          if current != last
            last = current
            stable_since = monotonic_now
          elsif monotonic_now - stable_since >= quiet_for.to_f
            return true
          end
          return false if monotonic_now >= deadline || !alive?
        end
      end

      def snapshot(rows: nil, columns: nil)
        resize(rows: rows, columns: columns) if rows && columns
        @mutex.synchronize do
          rendered = @screen.render_snapshot
          {
            "lines" => rendered.fetch("lines"),
            "styled_lines" => rendered.fetch("styled_lines"),
            "cursor" => rendered.fetch("cursor"),
            "revision" => rendered.fetch("revision"),
            "rows" => @rows,
            "columns" => @columns,
            "pid" => @pid,
            "alive" => running_unlocked?,
            "state" => @state
          }
        end
      end

      def resize(rows:, columns:)
        normalized_rows = positive_dimension(rows, @rows)
        normalized_columns = positive_dimension(columns, @columns)
        changed = @mutex.synchronize do
          next false if @rows == normalized_rows && @columns == normalized_columns

          @rows = normalized_rows
          @columns = normalized_columns
          @screen.resize(rows: normalized_rows, columns: normalized_columns)
          true
        end
        apply_winsize(normalized_rows, normalized_columns) if changed
        { "status" => "resized", "rows" => normalized_rows, "columns" => normalized_columns }
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
            "cwd" => cwd,
            "alive" => running_unlocked?,
            "started_at" => @started_at&.iso8601,
            "exit_status" => serialized_exit_status(@exit_status)
          }.compact
        end
      end

      def exit_status
        settle_completed_process
        @mutex.synchronize { serialized_exit_status(@exit_status) }
      end

      # Bounded raw PTY bytes, kept so a viewer can be handed the recent stream if it wants to
      # rebuild its own screen rather than reuse this one.
      def transcript
        @mutex.synchronize { @transcript.dup }
      end

      def terminate(timeout: TERMINATION_GRACE_SECONDS)
        pid, process_group_id, reader_thread, wait_thread = @mutex.synchronize do
          @state = "closing" if running_unlocked?
          [@pid, @process_group_id, @reader_thread, @wait_thread]
        end

        if pid && process_alive?(pid)
          signal_owned_process("HUP", pid, process_group_id)
          wait_until_dead(pid, timeout / 2)
          if process_alive?(pid)
            signal_owned_process("TERM", pid, process_group_id)
            wait_until_dead(pid, timeout)
          end
          signal_owned_process("KILL", pid, process_group_id) if process_alive?(pid)
        end

        close_handles
        reader_thread&.join(timeout)
        wait_thread&.join(timeout)
        @mutex.synchronize do
          @state = "closed"
          @condition.broadcast
        end
        true
      rescue StandardError
        close_handles
        false
      end

      private

      attr_reader :env, :pty

      def start_background_threads(reader, child_pid)
        @reader_thread = Thread.new do
          Thread.current.name = "meringue-agent-pty-reader" if Thread.current.respond_to?(:name=)
          read_output(reader)
        end
        @wait_thread = Thread.new do
          Thread.current.name = "meringue-agent-pty-waiter" if Thread.current.respond_to?(:name=)
          _pid, status = Process.waitpid2(child_pid)
          record_exit(status)
        rescue Errno::ECHILD
          record_exit(nil)
        end
      end

      def read_output(reader)
        loop do
          chunk = reader.readpartial(READ_CHUNK_BYTES)
          append_output(chunk)
        end
      rescue EOFError, Errno::EIO, IOError, SystemCallError
        nil
      ensure
        @mutex.synchronize { @condition.broadcast }
      end

      # The screen is fed here rather than lazily on snapshot so it is always current. Readiness
      # checks can then read it without a viewer being attached, and a viewer that attaches later
      # sees the agent's real current screen immediately instead of a blank pane.
      def append_output(chunk)
        bytes = chunk.to_s.b
        @mutex.synchronize do
          @output_bytes += bytes.bytesize
          @transcript << bytes
          overflow = @transcript.bytesize - @max_transcript_bytes
          @transcript.slice!(0, overflow) if overflow.positive?
          @pending << bytes
          feed_screen_unlocked
          @condition.broadcast
        end
      end

      def feed_screen_unlocked
        return if @pending.empty?

        @screen.feed(@pending)
        @pending = +"".b
      end

      def apply_winsize(rows, columns)
        io, child_pid = @mutex.synchronize { [@writer, @pid] }
        return unless io && child_pid

        io.winsize = [rows, columns]
        signal_process("WINCH", child_pid)
      rescue Errno::EIO, Errno::ESRCH, IOError, SystemCallError
        nil
      end

      def record_exit(status)
        @mutex.synchronize do
          @exit_status = status
          @state = "exited" unless @state == "closed"
          @condition.broadcast
        end
        close_handles
      end

      def running_unlocked?
        @state == "running" && @pid && process_alive?(@pid)
      end

      def settle_completed_process
        @mutex.synchronize do
          if @state == "running" && @pid && !process_alive?(@pid) && @wait_thread&.alive?
            @condition.wait(@mutex, 0.05)
          end
        end
      end

      def serialized_exit_status(status)
        return nil unless status

        {
          "success" => status.success?,
          "exit_code" => status.exitstatus,
          "termsig" => status.termsig
        }.compact
      end

      def safe_process_group_id(child_pid)
        Process.getpgid(child_pid)
      rescue SystemCallError
        nil
      end

      def signal_owned_process(signal, pid, process_group_id)
        if process_group_id == pid
          signal_process(signal, -process_group_id, group: true)
        else
          signal_process(signal, pid)
        end
      end

      def signal_process(signal, target, group: false)
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
        deadline = monotonic_now + timeout
        sleep POLL_INTERVAL while process_alive?(pid) && monotonic_now < deadline
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

      def stringify_environment(value)
        value.to_h.each_with_object({}) do |(key, child), result|
          result[key.to_s] = child.nil? ? nil : child.to_s
        end
      end

      def positive_dimension(value, fallback)
        number = Integer(value)
        number.positive? ? number : fallback
      rescue ArgumentError, TypeError
        fallback
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
