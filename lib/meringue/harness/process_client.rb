# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "shellwords"
require "thread"
require "time"
require "timeout"

module Meringue
  module Harness
    class ProcessClient < Client
      DEFAULT_COMMAND_TIMEOUT = 30
      DEFAULT_EVENT_TIMEOUT = 120
      DEFAULT_SHUTDOWN_TIMEOUT = 2
      MAX_BUFFER_CHARS = 40_000

      class Error < StandardError; end
      class ProcessNotFoundError < Error; end
      class ProcessExitedError < Error; end
      class InvalidModeError < Error; end

      attr_reader :harness_name, :command, :env, :extra_args, :command_timeout,
                  :event_timeout, :shutdown_timeout

      def initialize(harness_name:, command:, env: {}, extra_args: [],
                     command_timeout: DEFAULT_COMMAND_TIMEOUT,
                     event_timeout: DEFAULT_EVENT_TIMEOUT,
                     shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT)
        @harness_name = harness_name.to_s
        @command = command
        @env = env.transform_keys(&:to_s).transform_values(&:to_s)
        @extra_args = extra_args.map(&:to_s)
        @command_timeout = command_timeout
        @event_timeout = event_timeout
        @shutdown_timeout = shutdown_timeout
        @processes_by_pid = {}
        @processes_mutex = Mutex.new
      end

      def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
        expanded_cwd = validate_cwd!(cwd)
        session_id = new_session_id
        argv = build_spawn_argv(
          kind: kind,
          prompt: prompt.to_s,
          system_prompt: system_prompt.to_s,
          session_name: session_name.to_s,
          session_id: session_id
        )
        process = start_process(argv: argv, cwd: expanded_cwd)
        register_process(process)
        build_session_ref(process, kind: kind, cwd: expanded_cwd, session_name: session_name, fallback_session_id: session_id)
      rescue StandardError
        if process
          unregister_process(process)
          process.terminate(timeout: shutdown_timeout)
        end
        raise
      end

      def prompt_session(session_ref, prompt, mode: "normal")
        current_process = process_for(session_ref, required: false)
        if current_process&.alive?
          raise InvalidModeError,
                "#{harness_name} sessions do not support live #{mode} prompts yet; wait for the current turn to finish"
        end

        expanded_cwd = validate_cwd!(session_ref["cwd"] || session_ref[:cwd] || Dir.pwd)
        session_id = session_ref["session_id"] || session_ref[:session_id] || new_session_id
        argv = build_resume_argv(
          session_ref: session_ref,
          prompt: prompt.to_s,
          mode: mode.to_s,
          session_id: session_id
        )
        process = start_process(argv: argv, cwd: expanded_cwd)
        register_process(process)
        build_session_ref(
          process,
          kind: metadata_value(session_ref, "kind"),
          cwd: expanded_cwd,
          session_name: metadata_value(session_ref, "session_name"),
          fallback_session_id: session_id,
          previous_metadata: session_ref.fetch("metadata", {}) || {}
        )
      rescue StandardError
        if process
          unregister_process(process)
          process.terminate(timeout: shutdown_timeout)
        end
        raise
      end

      def abort_session(session_ref)
        process = process_for(session_ref, required: false)
        return session_ref.merge("is_streaming" => false) unless process

        process.terminate(timeout: shutdown_timeout)
        build_session_ref(
          process,
          kind: metadata_value(session_ref, "kind"),
          cwd: session_ref["cwd"] || session_ref[:cwd] || process.cwd,
          session_name: metadata_value(session_ref, "session_name"),
          fallback_session_id: session_ref["session_id"] || session_ref[:session_id],
          previous_metadata: session_ref.fetch("metadata", {}) || {}
        )
      ensure
        unregister_process(process) if process
      end

      def kill_session(session_ref)
        process = process_for(session_ref, required: false)
        unless process
          return session_ref.merge(
            "is_streaming" => false,
            "metadata" => metadata_with(session_ref, "killed" => true, "kill_note" => "no live #{harness_name} process found")
          )
        end

        process.terminate(timeout: shutdown_timeout)
        unregister_process(process)
        build_session_ref(
          process,
          kind: metadata_value(session_ref, "kind"),
          cwd: session_ref["cwd"] || session_ref[:cwd] || process.cwd,
          session_name: metadata_value(session_ref, "session_name"),
          fallback_session_id: session_ref["session_id"] || session_ref[:session_id],
          previous_metadata: session_ref.fetch("metadata", {}) || {}
        ).merge(
          "is_streaming" => false,
          "metadata" => metadata_with(session_ref, process_metadata(process).merge("killed" => true))
        )
      end

      def get_state(session_ref)
        process = process_for(session_ref, required: false)
        return completed_session_ref(session_ref) unless process

        ref = build_session_ref(
          process,
          kind: metadata_value(session_ref, "kind"),
          cwd: session_ref["cwd"] || session_ref[:cwd] || process.cwd,
          session_name: metadata_value(session_ref, "session_name"),
          fallback_session_id: session_ref["session_id"] || session_ref[:session_id],
          previous_metadata: session_ref.fetch("metadata", {}) || {}
        )
        ensure_successful_exit!(process) unless process.alive?
        ref
      end

      def read_events(session_ref)
        process = process_for(session_ref, required: false)
        return [] unless process

        process.drain_events
      end

      def attach_session(session_ref)
        session_ref.merge(
          "metadata" => metadata_with(session_ref, "attach_supported" => false, "attach_note" => "#{harness_name} terminal attach is handled by TerminalSessionOpener")
        )
      end

      def wait_for_settled(session_ref, timeout: event_timeout)
        process = process_for(session_ref)
        status = process.wait(timeout: timeout)
        ensure_successful_exit!(process)
        [{ "type" => "agent_settled", "status" => status&.exitstatus, "timestamp" => timestamp }]
      rescue Timeout::Error
        raise Error, "Timed out waiting for #{harness_name} session to settle"
      end

      def last_assistant_text(session_ref)
        process = process_for(session_ref, required: false)
        return extract_last_assistant_text(process.records, process.stdout_text) if process

        metadata = session_ref.fetch("metadata", {}) || {}
        metadata["last_assistant_text"] || extract_last_assistant_text(Array(metadata["structured_events"]), metadata["stdout_tail"].to_s)
      end

      protected

      def build_spawn_argv(kind:, prompt:, system_prompt:, session_name:, session_id:)
        raise NotImplementedError, "#{self.class} must implement #build_spawn_argv"
      end

      def build_resume_argv(session_ref:, prompt:, mode:, session_id:)
        raise NotImplementedError, "#{self.class} must implement #build_resume_argv"
      end

      def command_argv
        case command
        when Array
          command.map(&:to_s)
        else
          Shellwords.split(command.to_s)
        end
      rescue ArgumentError
        [command.to_s]
      end

      def new_session_id
        SecureRandom.uuid
      end

      def combine_system_prompt(system_prompt, prompt)
        return prompt.to_s unless present?(system_prompt)

        <<~PROMPT
          System instructions:
          #{system_prompt}

          User prompt:
          #{prompt}
        PROMPT
      end

      def extract_last_assistant_text(records, stdout_text)
        records.reverse_each do |record|
          next unless record.is_a?(Hash)

          text = text_from_result_record(record)
          return text if present?(text)
        end

        records.reverse_each do |record|
          text = text_from_record(record)
          return text if present?(text)
        end

        stdout_text.to_s.strip
      end

      def text_from_result_record(record)
        type = record["type"].to_s
        return nil unless type == "result" || type.end_with?(".result")

        first_present_string(
          record["result"],
          record["response"],
          record["text"],
          record.dig("data", "result"),
          record.dig("data", "response"),
          record.dig("data", "text")
        ) ||
          text_from_record(record["result"]) ||
          text_from_record(record["response"]) ||
          text_from_record(record.dig("data", "result")) ||
          text_from_record(record.dig("data", "response")) ||
          text_from_record(record["message"])
      end

      def text_from_record(value)
        case value
        when String
          value
        when Array
          value.filter_map { |child| text_from_record(child) }.join
        when Hash
          direct = first_present_string(value["text"], value["content"], value["result"], value["response"])
          return direct if direct

          text_from_record(value["content"]) ||
            text_from_record(value["result"]) ||
            text_from_record(value["response"]) ||
            text_from_record(value.dig("message", "content")) ||
            text_from_record(value["message"]) ||
            text_from_record(value["parts"]) ||
            text_from_record(value.dig("data", "content")) ||
            text_from_record(value.dig("data", "result")) ||
            text_from_record(value.dig("data", "response"))
        end
      end

      def first_present_string(*values)
        values.each do |value|
          next unless value.is_a?(String)

          stripped = value.strip
          return stripped unless stripped.empty?
        end
        nil
      end

      def session_id_from_records(records)
        records.reverse_each do |record|
          next unless record.is_a?(Hash)

          value = first_present_string(
            record["session_id"],
            record["sessionId"],
            record["sessionID"],
            record.dig("data", "session_id"),
            record.dig("data", "sessionId"),
            record.dig("message", "session_id"),
            record.dig("session", "id"),
            record.dig("session", "session_id"),
            record.dig("result", "session_id"),
            record.dig("response", "session_id")
          )
          return value if value
        end

        nil
      end

      def validate_cwd!(cwd)
        expanded = File.expand_path(cwd.to_s)
        raise Error, "Working directory does not exist: #{expanded}" unless Dir.exist?(expanded)

        expanded
      end

      def ensure_successful_exit!(process)
        status = process.exit_status
        return if status.nil? || status.success?

        code = status.exitstatus || status.termsig
        raise ProcessExitedError, "#{harness_name} process exited with status #{code}. Stderr: #{tail(process.stderr_text)}"
      end

      def start_process(argv:, cwd:)
        stdin, stdout, stderr, wait_thread = Open3.popen3(env, *argv, chdir: cwd)
        stdin.close
        ManagedProcess.new(stdin: stdin, stdout: stdout, stderr: stderr, wait_thread: wait_thread,
                           argv: argv, cwd: cwd)
      rescue Errno::ENOENT => e
        raise Error, "Unable to start #{harness_name} process with #{argv.first.inspect}: #{e.message}"
      end

      def register_process(process)
        @processes_mutex.synchronize { @processes_by_pid[process.pid] = process }
      end

      def unregister_process(process)
        @processes_mutex.synchronize { @processes_by_pid.delete(process.pid) }
      end

      def process_for(session_ref, required: true)
        pid = session_ref["pid"] || session_ref[:pid]
        process = @processes_mutex.synchronize { @processes_by_pid[pid] }
        return process if process
        raise ProcessNotFoundError, "No live #{harness_name} process found for pid #{pid.inspect}" if required

        nil
      end

      def build_session_ref(process, kind:, cwd:, session_name:, fallback_session_id:, previous_metadata: {})
        session_id = session_id_from_records(process.records) || fallback_session_id
        completed = !process.alive?
        metadata = (previous_metadata || {}).merge(
          process_metadata(process).merge(
            "kind" => kind.to_s,
            "session_name" => session_name,
            "completed" => completed,
            "last_assistant_text" => completed ? extract_last_assistant_text(process.records, process.stdout_text) : nil
          ).compact
        )

        {
          "harness" => harness_name,
          "pid" => process.pid,
          "cwd" => cwd,
          "session_id" => session_id,
          "session_file" => nil,
          "is_streaming" => !completed,
          "last_event_at" => process.last_event_at,
          "metadata" => metadata
        }
      end

      def completed_session_ref(session_ref)
        metadata = session_ref.fetch("metadata", {}) || {}
        session_ref.merge(
          "harness" => harness_name,
          "is_streaming" => false,
          "metadata" => metadata.merge("completed" => true)
        )
      end

      def process_metadata(process)
        {
          "started_at" => process.started_at,
          "command" => process.argv,
          "structured_events" => process.records.last(50),
          "stdout_tail" => tail(process.stdout_text),
          "stderr_tail" => tail(process.stderr_text),
          "exit_status" => process.exit_status_value,
          "last_event_at" => process.last_event_at
        }.compact
      end

      def metadata_value(session_ref, key)
        metadata = session_ref.fetch("metadata", {}) || {}
        metadata[key] || metadata[key.to_sym]
      end

      def metadata_with(session_ref, values)
        (session_ref.fetch("metadata", {}) || {}).merge(values.compact)
      end

      def tail(text)
        value = text.to_s
        return value if value.length <= MAX_BUFFER_CHARS

        value[-MAX_BUFFER_CHARS, MAX_BUFFER_CHARS]
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end

      def timestamp
        Time.now.utc.iso8601
      end

      class ManagedProcess
        attr_reader :stdin, :stdout, :stderr, :wait_thread, :argv, :cwd, :started_at

        def initialize(stdin:, stdout:, stderr:, wait_thread:, argv:, cwd:)
          @stdin = stdin
          @stdout = stdout
          @stderr = stderr
          @wait_thread = wait_thread
          @argv = argv
          @cwd = cwd
          @started_at = Time.now.utc.iso8601
          @stdout_chunks = []
          @stderr_chunks = []
          @records = []
          @events = []
          @event_cursor = 0
          @last_event_at = @started_at
          @mutex = Mutex.new
          @stdout_reader = Thread.new { read_stdout }
          @stderr_reader = Thread.new { read_stderr }
        end

        def pid
          wait_thread.pid
        end

        def alive?
          wait_thread.alive?
        end

        def wait(timeout:)
          Timeout.timeout(timeout) { wait_thread.value }
        ensure
          join_readers(0.2) unless alive?
        end

        def terminate(timeout:)
          Process.kill("TERM", pid) if alive?
          Timeout.timeout(timeout) { wait_thread.value } if alive?
        rescue Errno::ESRCH, Timeout::Error
          begin
            Process.kill("KILL", pid) if alive?
          rescue Errno::ESRCH
            nil
          end
        ensure
          join_readers(0.2)
        end

        def stdout_text
          @mutex.synchronize { @stdout_chunks.join }
        end

        def stderr_text
          @mutex.synchronize { @stderr_chunks.join }
        end

        def records
          @mutex.synchronize { @records.dup }
        end

        def drain_events
          @mutex.synchronize do
            drained = @events[@event_cursor..] || []
            @event_cursor = @events.length
            drained
          end
        end

        def last_event_at
          @mutex.synchronize { @last_event_at }
        end

        def exit_status
          return nil if alive?

          wait_thread.value
        end

        def exit_status_value
          status = exit_status
          status&.exitstatus || status&.termsig
        end

        private

        def read_stdout
          stdout.each_line do |line|
            record_stdout_line(line)
          end
        rescue IOError
          nil
        end

        def read_stderr
          stderr.each_line do |line|
            @mutex.synchronize { @stderr_chunks << line }
          end
        rescue IOError
          nil
        end

        def record_stdout_line(line)
          parsed = parse_json_line(line)
          @mutex.synchronize do
            @stdout_chunks << line
            @last_event_at = Time.now.utc.iso8601
            if parsed
              @records << parsed
              @events << normalize_event(parsed)
            end
          end
        end

        def parse_json_line(line)
          parsed = JSON.parse(line)
          parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        def normalize_event(record)
          {
            "type" => record.fetch("type", "event"),
            "timestamp" => Time.now.utc.iso8601,
            "data" => record
          }
        end

        def join_readers(timeout)
          @stdout_reader.join(timeout) if @stdout_reader
          @stderr_reader.join(timeout) if @stderr_reader
        end
      end
    end
  end
end
