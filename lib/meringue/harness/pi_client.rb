# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "thread"
require "time"
require "timeout"

module Meringue
  module Harness
    class PiClient < Client
      DEFAULT_COMMAND = "pi"
      DEFAULT_COMMAND_TIMEOUT = 30
      DEFAULT_EVENT_TIMEOUT = 120
      DEFAULT_SHUTDOWN_TIMEOUT = 2
      MAX_STDERR_CHARS = 20_000

      MODE_ALIASES = {
        "normal" => "normal",
        "steer" => "steer",
        "follow_up" => "follow_up",
        "followUp" => "follow_up"
      }.freeze

      class Error < StandardError; end
      class ProcessNotFoundError < Error; end
      class ProcessExitedError < Error; end
      class RpcError < Error; end
      class RpcTimeoutError < Error; end
      class InvalidModeError < Error; end

      attr_reader :command, :env, :extra_args, :session_dir, :command_timeout,
                  :event_timeout, :shutdown_timeout

      def harness_name
        "pi"
      end

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [], session_dir: nil,
                     command_timeout: DEFAULT_COMMAND_TIMEOUT,
                     event_timeout: DEFAULT_EVENT_TIMEOUT,
                     shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT)
        @command = command
        @env = env.transform_keys(&:to_s).transform_values(&:to_s)
        @extra_args = extra_args.map(&:to_s)
        @session_dir = session_dir
        @command_timeout = command_timeout
        @event_timeout = event_timeout
        @shutdown_timeout = shutdown_timeout
        @processes_by_pid = {}
        @processes_mutex = Mutex.new
      end

      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
        expanded_cwd = validate_cwd!(cwd)
        argv = build_argv(session_name: session_name, system_prompt: system_prompt)
        process = start_rpc_process(argv: argv, cwd: expanded_cwd)
        register_process(process)

        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        set_session_name(process, session_name) if present?(session_name)
        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        session_ref = build_session_ref(process, state, kind: kind, cwd: expanded_cwd,
                                                        session_name: session_name)

        return session_ref unless present?(prompt)

        prompt_session(session_ref, prompt, mode: "normal")
      rescue StandardError
        if process
          unregister_process(process)
          process.terminate(timeout: shutdown_timeout)
        end
        raise
      end

      def prompt_session(session_ref, prompt, mode: "normal")
        process = process_for(session_ref)
        normalized_mode = normalize_mode!(mode)
        message = prompt.to_s
        current_ref = get_state(session_ref)

        command = case normalized_mode
                  when "normal"
                    if current_ref.fetch("is_streaming", false)
                      raise InvalidModeError,
                            "#{harness_label} session is streaming; use mode: \"steer\" or \"follow_up\""
                    end

                    { "type" => "prompt", "message" => message }
                  when "steer"
                    { "type" => "steer", "message" => message }
                  when "follow_up"
                    { "type" => "follow_up", "message" => message }
                  end

        rpc_data(process.request(command, timeout: command_timeout), allow_nil_data: true)
        get_state(current_ref)
      end

      def abort_session(session_ref)
        process = process_for(session_ref)
        rpc_data(process.request({ "type" => "abort" }, timeout: command_timeout), allow_nil_data: true)
        get_state(session_ref)
      end

      def kill_session(session_ref)
        process = process_for(session_ref, required: false)
        unless process
          return session_ref.merge(
            "is_streaming" => false,
            "metadata" => metadata_with(session_ref, "killed" => true, "kill_note" => "no live #{harness_label} process found")
          )
        end

        process.terminate(timeout: shutdown_timeout)
        unregister_process(process)

        session_ref.merge(
          "harness" => harness_name,
          "pid" => process.pid,
          "is_streaming" => false,
          "last_event_at" => process.last_event_at,
          "metadata" => metadata_with(
            session_ref,
            "killed" => true,
            "exit_status" => process.exit_status,
            "stderr_tail" => process.stderr_tail
          )
        )
      end

      def get_state(session_ref)
        process = process_for(session_ref, required: false)
        if process
          state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
          return build_session_ref(
            process,
            state,
            kind: metadata_value(session_ref, "kind"),
            cwd: session_ref.fetch("cwd", process.cwd),
            session_name: metadata_value(session_ref, "session_name") || state["sessionName"]
          )
        end

        build_session_ref_from_file(session_ref)
      end

      def read_events(session_ref)
        process = process_for(session_ref, required: false)
        return [] unless process

        process.drain_events
      end

      def attach_session(session_ref)
        process = process_for(session_ref, required: false)
        return get_state(session_ref) if process

        expanded_cwd = validate_cwd!(session_ref["cwd"] || session_ref[:cwd])
        session = resume_session_argument(session_ref)
        session_name = metadata_value(session_ref, "session_name")
        argv = build_argv(session_name: session_name, system_prompt: nil, session: session)
        process = start_rpc_process(argv: argv, cwd: expanded_cwd)
        register_process(process)

        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        set_session_name(process, session_name) if present?(session_name)
        state = rpc_data(process.request({ "type" => "get_state" }, timeout: command_timeout))
        resumed_ref = build_session_ref(process, state, kind: metadata_value(session_ref, "kind"), cwd: expanded_cwd,
                                                        session_name: session_name)
        resumed_ref.merge(
          "metadata" => metadata_with(
            session_ref,
            resumed_ref.fetch("metadata", {}).merge(
              "attach_supported" => true,
              "resumed_from_session" => true,
              "resume_session" => session
            )
          )
        )
      rescue StandardError
        if process
          unregister_process(process)
          process.terminate(timeout: shutdown_timeout)
        end
        raise
      end

      def wait_for_event(session_ref, type:, timeout: event_timeout)
        process = process_for(session_ref)
        deadline = Time.now + timeout
        events = []

        loop do
          remaining = deadline - Time.now
          raise RpcTimeoutError, "Timed out waiting for #{harness_label} event #{type.inspect}" if remaining <= 0

          event = process.next_event(timeout: remaining)
          events << event
          return events if event["type"] == type
        end
      end

      def wait_for_settled(session_ref, timeout: event_timeout)
        wait_for_event(session_ref, type: "agent_settled", timeout: timeout)
      end

      def last_assistant_text(session_ref)
        process = process_for(session_ref, required: false)
        if process
          data = rpc_data(process.request({ "type" => "get_last_assistant_text" }, timeout: command_timeout))
          return data["text"]
        end

        session_file_summary(session_ref).fetch("last_assistant_text", nil)
      end

      private

      def build_argv(session_name:, system_prompt:, session: nil)
        argv = Array(command).map(&:to_s) + ["--mode", "rpc"]
        argv += ["--session-dir", File.expand_path(session_dir)] if present?(session_dir)
        argv += ["--session", session.to_s] if present?(session)
        argv += session_name_argv(session_name)
        argv += ["--append-system-prompt", system_prompt.to_s] if present?(system_prompt)
        argv + extra_args
      end

      def session_name_argv(session_name)
        present?(session_name) ? ["--name", session_name.to_s] : []
      end

      def start_rpc_process(argv:, cwd:)
        stdin, stdout, stderr, wait_thread = Open3.popen3(env, *argv, chdir: cwd)
        RpcProcess.new(stdin: stdin, stdout: stdout, stderr: stderr, wait_thread: wait_thread,
                       argv: argv, cwd: cwd, harness_label: harness_label)
      rescue Errno::ENOENT => e
        raise Error, "Unable to start #{harness_label} RPC process with #{argv.first.inspect}: #{e.message}"
      end

      def set_session_name(process, session_name)
        rpc_data(
          process.request({ "type" => "set_session_name", "name" => session_name.to_s },
                          timeout: command_timeout),
          allow_nil_data: true
        )
      end

      def build_session_ref(process, pi_state, kind:, cwd:, session_name:)
        {
          "harness" => harness_name,
          "pid" => process.pid,
          "cwd" => cwd,
          "session_id" => pi_state["sessionId"],
          "session_file" => pi_state["sessionFile"],
          "is_streaming" => !!pi_state["isStreaming"],
          "last_event_at" => process.last_event_at,
          "metadata" => {
            "kind" => kind.to_s,
            "session_name" => session_name,
            "started_at" => process.started_at,
            "command" => process.argv,
            "pi_state" => pi_state,
            "stderr_tail" => process.stderr_tail
          }
        }
      end

      def build_session_ref_from_file(session_ref)
        summary = session_file_summary(session_ref)
        if !summary.fetch("completed", false) && !summary.fetch("process_alive", false)
          raise ProcessExitedError,
                "#{harness_label} session #{summary.fetch("session_file", nil) || summary.fetch("session_id", nil)} has no live process and no completed assistant response"
        end

        pi_state = {
          "sessionId" => summary.fetch("session_id", nil),
          "sessionFile" => summary.fetch("session_file", nil),
          "sessionName" => summary.fetch("session_name", nil),
          "isStreaming" => !summary.fetch("completed", false),
          "cwd" => summary.fetch("cwd", nil),
          "fromSessionFile" => true,
          "processAlive" => summary.fetch("process_alive", false),
          "completed" => summary.fetch("completed", false),
          "lastStopReason" => summary.fetch("last_stop_reason", nil)
        }

        session_ref.merge(
          "harness" => harness_name,
          "pid" => session_ref["pid"] || session_ref[:pid],
          "cwd" => summary.fetch("cwd", nil) || session_ref["cwd"] || session_ref[:cwd],
          "session_id" => summary.fetch("session_id", nil) || session_ref["session_id"] || session_ref[:session_id],
          "session_file" => summary.fetch("session_file", nil),
          "is_streaming" => !summary.fetch("completed", false),
          "last_event_at" => summary.fetch("last_event_at", nil),
          "metadata" => metadata_with(
            session_ref,
            "session_name" => summary.fetch("session_name", nil) || metadata_value(session_ref, "session_name"),
            "pi_state" => pi_state,
            "session_file_summary" => summary,
            "reconnected_from_session_file" => true
          )
        )
      end

      def session_file_summary(session_ref)
        path = session_file_path(session_ref)
        raise ProcessNotFoundError, "#{harness_label} session file is missing for #{session_ref_summary(session_ref)}" unless path && File.file?(path)

        summary = {
          "session_file" => path,
          "session_id" => session_ref["session_id"] || session_ref[:session_id],
          "process_alive" => process_alive?(session_ref["pid"] || session_ref[:pid]),
          "completed" => false,
          "last_assistant_text" => nil,
          "last_stop_reason" => nil,
          "last_event_at" => nil,
          "cwd" => session_ref["cwd"] || session_ref[:cwd],
          "session_name" => metadata_value(session_ref, "session_name")
        }
        last_assistant = nil

        File.foreach(path) do |line|
          record = JSON.parse(line)
          summary["last_event_at"] = record["timestamp"] if record["timestamp"]
          if record["type"] == "session"
            summary["session_id"] ||= record["id"]
            summary["cwd"] ||= record["cwd"]
          elsif record["type"] == "session_info"
            summary["session_name"] = record["name"] if record["name"]
          elsif record["type"] == "message" && record.dig("message", "role") == "assistant"
            last_assistant = record
            text = assistant_text_from_message(record)
            summary["last_assistant_text"] = text if present?(text)
            summary["last_stop_reason"] = record["stopReason"] if record.key?("stopReason")
          end
        rescue JSON::ParserError
          next
        end

        summary["completed"] = assistant_message_completed?(last_assistant)
        summary
      end

      def session_file_path(session_ref)
        path = session_ref["session_file"] || session_ref[:session_file]
        expanded_path = File.expand_path(path) if present?(path)
        return expanded_path if expanded_path && File.file?(expanded_path)

        session_id = session_ref["session_id"] || session_ref[:session_id]
        discovered_path = if present?(session_id) && session_dir
                            Dir[File.join(File.expand_path(session_dir), "*#{session_id}*.jsonl")].max_by { |candidate| File.mtime(candidate) }
                          end

        discovered_path || expanded_path
      end

      def resume_session_argument(session_ref)
        path = session_file_path(session_ref)
        return path if present?(path) && File.file?(path)

        session_id = session_ref["session_id"] || session_ref[:session_id]
        return session_id if present?(session_id)

        raise ProcessNotFoundError, "#{harness_label} session cannot be resumed without a session file or session id: #{session_ref_summary(session_ref)}"
      end

      def session_ref_summary(session_ref)
        metadata = session_ref["metadata"] || session_ref[:metadata] || {}
        {
          "pid" => session_ref["pid"] || session_ref[:pid],
          "session_id" => session_ref["session_id"] || session_ref[:session_id],
          "session_file" => session_ref["session_file"] || session_ref[:session_file],
          "cwd" => session_ref["cwd"] || session_ref[:cwd],
          "kind" => metadata["kind"] || metadata[:kind],
          "session_name" => metadata["session_name"] || metadata[:session_name]
        }.compact
      end

      def assistant_text_from_message(record)
        Array(record.dig("message", "content")).filter_map do |part|
          part["text"] if part.is_a?(Hash) && part["type"] == "text"
        end.join("\n").strip
      end

      def assistant_message_completed?(record)
        return false unless record

        stop_reason = record["stopReason"]
        return false if stop_reason.to_s == "toolUse"
        return true if present?(stop_reason)

        Array(record.dig("message", "content")).any? do |part|
          part.is_a?(Hash) && part["type"] == "text" && present?(part["text"])
        end
      end

      def process_alive?(pid)
        return false unless present?(pid)

        Process.kill(0, pid.to_i)
        true
      rescue Errno::ESRCH, TypeError, ArgumentError
        false
      rescue Errno::EPERM
        true
      end

      def rpc_data(response, allow_nil_data: false)
        unless response.is_a?(Hash) && response["type"] == "response"
          raise RpcError, "Expected #{harness_label} RPC response, got: #{response.inspect}"
        end

        unless response["success"]
          raise RpcError, response["error"].to_s.empty? ? "#{harness_label} RPC command failed" : response["error"].to_s
        end

        data = response["data"]
        return data if data || allow_nil_data

        raise RpcError, "#{harness_label} RPC response for #{response["command"].inspect} did not include data"
      end

      def validate_cwd!(cwd)
        expanded = File.expand_path(cwd.to_s)
        raise ArgumentError, "cwd must be an existing directory: #{cwd.inspect}" unless Dir.exist?(expanded)

        expanded
      end

      def normalize_mode!(mode)
        normalized = MODE_ALIASES[mode.to_s]
        return normalized if normalized

        raise InvalidModeError, "Unknown #{harness_label} prompt mode: #{mode.inspect}"
      end

      def register_process(process)
        @processes_mutex.synchronize do
          @processes_by_pid[process.pid] = process
        end
      end

      def unregister_process(process)
        @processes_mutex.synchronize do
          @processes_by_pid.delete(process.pid)
        end
      end

      def process_for(session_ref, required: true)
        pid = session_ref["pid"] || session_ref[:pid]
        process = @processes_mutex.synchronize { @processes_by_pid[pid] }

        return process if process && process.alive?
        return nil unless required

        raise ProcessNotFoundError, "No live #{harness_label} RPC process for pid #{pid.inspect}"
      end

      def metadata_value(session_ref, key)
        metadata = session_ref["metadata"] || session_ref[:metadata] || {}
        metadata[key] || metadata[key.to_sym]
      end

      def metadata_with(session_ref, values)
        metadata = (session_ref["metadata"] || session_ref[:metadata] || {}).dup
        metadata.merge(values)
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end

      def harness_label
        harness_name == "pi" ? "Pi" : harness_name.split("_").map(&:capitalize).join(" ")
      end

      class RpcProcess
        attr_reader :stdin, :stdout, :stderr, :wait_thread, :argv, :cwd, :pid, :started_at,
                    :last_event_at, :exit_status, :harness_label

        def initialize(stdin:, stdout:, stderr:, wait_thread:, argv:, cwd:, harness_label: "Pi")
          @stdin = stdin
          @stdout = stdout
          @stderr = stderr
          @wait_thread = wait_thread
          @argv = argv
          @cwd = cwd
          @harness_label = harness_label
          @pid = wait_thread.pid
          @started_at = Time.now.utc.iso8601
          @last_event_at = nil
          @exit_status = nil
          @pending = {}
          @pending_mutex = Mutex.new
          @write_mutex = Mutex.new
          @event_queue = Queue.new
          @stderr_buffer = +""
          @stderr_mutex = Mutex.new

          @stdin.sync = true
          start_stdout_reader
          start_stderr_reader
          start_exit_watcher
        end

        def request(command, timeout:)
          ensure_alive!

          id = command.fetch("id") { "req_#{SecureRandom.hex(8)}" }
          queue = Queue.new
          payload = command.merge("id" => id)

          @pending_mutex.synchronize { @pending[id] = queue }
          write_json(payload)

          result = Timeout.timeout(timeout) { queue.pop }
          raise result if result.is_a?(Exception)

          result
        rescue Timeout::Error
          @pending_mutex.synchronize { @pending.delete(id) } if id
          raise RpcTimeoutError, "Timed out waiting for #{harness_label} RPC response to #{command["type"].inspect}"
        rescue IOError, Errno::EPIPE => e
          @pending_mutex.synchronize { @pending.delete(id) } if id
          raise ProcessExitedError, "#{harness_label} RPC stdin is closed: #{e.message}"
        end

        def drain_events
          events = []
          loop do
            events << @event_queue.pop(true)
          rescue ThreadError
            break
          end
          events
        end

        def next_event(timeout:)
          Timeout.timeout(timeout) { @event_queue.pop }
        rescue Timeout::Error
          raise RpcTimeoutError, "Timed out waiting for next #{harness_label} RPC event"
        end

        def stderr_tail
          @stderr_mutex.synchronize { @stderr_buffer.dup }
        end

        def alive?
          wait_thread.alive?
        end

        def terminate(timeout:)
          close_stdin
          send_signal("TERM") if alive?
          wait_for_exit(timeout)
          send_signal("KILL") if alive?
          wait_for_exit(0.5)
        end

        private

        def ensure_alive!
          return if alive?

          raise ProcessExitedError, "#{harness_label} RPC process #{pid} is not running. Stderr: #{stderr_tail}"
        end

        def write_json(payload)
          @write_mutex.synchronize do
            stdin.write(JSON.generate(payload))
            stdin.write("\n")
            stdin.flush
          end
        end

        def start_stdout_reader
          @stdout_thread = Thread.new do
            Thread.current.abort_on_exception = false
            buffer = +""

            begin
              loop do
                buffer << stdout.readpartial(4096)
                buffer = emit_complete_lines(buffer)
              end
            rescue EOFError
              emit_line(buffer) unless buffer.empty?
            rescue IOError
              # Process shutdown closes the pipe.
            end
          end
        end

        def emit_complete_lines(buffer)
          while (newline_index = buffer.index("\n"))
            line = buffer.slice!(0..newline_index)
            line = line[0...-1]
            emit_line(line)
          end

          buffer
        end

        def emit_line(line)
          line = line[0...-1] if line.end_with?("\r")
          return if line.empty?

          record = JSON.parse(line)
          if record["type"] == "response" && record["id"]
            pending_queue = @pending_mutex.synchronize { @pending.delete(record["id"]) }
            if pending_queue
              pending_queue << record
            else
              enqueue_event(record)
            end
          else
            enqueue_event(record)
          end
        rescue JSON::ParserError => e
          enqueue_event(
            "type" => "rpc_parse_error",
            "error" => e.message,
            "line" => line
          )
        end

        def start_stderr_reader
          @stderr_thread = Thread.new do
            Thread.current.abort_on_exception = false
            begin
              loop do
                append_stderr(stderr.readpartial(4096))
              end
            rescue EOFError, IOError
              # Process shutdown closes the pipe.
            end
          end
        end

        def append_stderr(chunk)
          @stderr_mutex.synchronize do
            @stderr_buffer << chunk.to_s
            @stderr_buffer = @stderr_buffer[-MAX_STDERR_CHARS, MAX_STDERR_CHARS] || @stderr_buffer if @stderr_buffer.length > MAX_STDERR_CHARS
          end
        end

        def start_exit_watcher
          @exit_thread = Thread.new do
            Thread.current.abort_on_exception = false
            status = wait_thread.value
            @exit_status = {
              "exit_code" => status.exitstatus,
              "termsig" => status.termsig,
              "success" => status.success?
            }
            enqueue_event("type" => "process_exit", "pid" => pid, "status" => @exit_status)
            fail_pending(
              ProcessExitedError.new(
                "#{harness_label} RPC process #{pid} exited with #{@exit_status.inspect}. Stderr: #{stderr_tail}"
              )
            )
          end
        end

        def enqueue_event(event)
          @last_event_at = Time.now.utc.iso8601
          @event_queue << event
        end

        def fail_pending(error)
          queues = @pending_mutex.synchronize do
            pending = @pending.values
            @pending.clear
            pending
          end
          queues.each { |queue| queue << error }
        end

        def close_stdin
          stdin.close unless stdin.closed?
        rescue IOError
          nil
        end

        def send_signal(signal)
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end

        def wait_for_exit(timeout)
          deadline = Time.now + timeout
          sleep 0.05 while alive? && Time.now < deadline
        end
      end
    end
  end
end
