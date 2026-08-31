# frozen_string_literal: true

module Meringue
  module Harness
    class PiClient
    private
      def without_options(arguments, *options)
        result = []
        skip_next = false
        Array(arguments).each do |argument|
          if skip_next
            skip_next = false
            next
          end

          text = argument.to_s
          if options.include?(text)
            skip_next = true
          elsif options.any? { |option| text.start_with?("#{option}=") }
            next
          else
            result << text
          end
        end
        result
      end

      def start_rpc_process(argv:, cwd:)
        stdin, stdout, stderr, wait_thread = Open3.popen3(process_environment(cwd), *argv, chdir: cwd)
        RpcProcess.new(stdin: stdin, stdout: stdout, stderr: stderr, wait_thread: wait_thread,
                       argv: argv, cwd: cwd)
      rescue Errno::ENOENT => e
        raise Error, "Unable to start Pi RPC process with #{argv.first.inspect}: #{e.message}"
      end

      def process_environment(cwd)
        configured = ENV.to_h.merge(env)
        environment = env.merge(Git::CommitIdentity.environment(cwd: cwd, base_environment: configured))
        # Open3 inherits unspecified variables, but the native PTY performs its
        # own executable discovery before spawning. Preserve the effective PATH
        # explicitly so that a provider installed outside a restricted launcher
        # environment is still resolved by the handoff.
        environment["PATH"] ||= configured.fetch("PATH", "")
        environment
      end

      def set_session_name(process, session_name)
        rpc_data(
          process.request({ "type" => "set_session_name", "name" => session_name.to_s },
                          timeout: command_timeout),
          allow_nil_data: true
        )
      end

      def build_session_ref(process, pi_state, kind:, cwd:, session_name:, workspace_mode: "isolated", session_stats: nil)
        {
          "harness" => "pi",
          "pid" => process.pid,
          "cwd" => cwd,
          "session_id" => pi_state["sessionId"],
          "session_file" => pi_state["sessionFile"],
          "is_streaming" => !!pi_state["isStreaming"],
          "last_event_at" => process.last_event_at,
          "session_settings" => session_settings_from_pi_state(pi_state),
          "session_stats" => session_stats,
          "metadata" => {
            "kind" => kind.to_s,
            "session_name" => session_name,
            "workspace_mode" => workspace_mode.to_s,
            "started_at" => process.started_at,
            "command" => process.argv,
            "prompt_modes" => prompt_modes,
            "completed" => !!pi_state["completed"],
            "pi_state" => pi_state,
            "stderr_tail" => process.stderr_tail,
            "supervision" => {
              "owner_pid" => Process.pid,
              "owner_started_at" => transport_ownership.owner_started_at,
              "harness_pid" => process.pid,
              "harness_started_at" => process.started_at,
              "recorded_at" => Time.now.utc.iso8601(6)
            }.compact
          }
        }
      end

      def build_session_ref_from_file(session_ref)
        summary = session_file_summary(session_ref)
        kind = metadata_value(session_ref, "kind").to_s
        unless summary.fetch("completed", false) || (summary.fetch("process_alive", false) && kind != "head")
          session = summary.fetch("session_file", nil) || summary.fetch("session_id", nil)
          if summary.fetch("process_alive", false)
            raise UnmanagedProcessError,
                  "Pi head session #{session} is still running outside this client and has no completed assistant response"
          end

          raise ProcessExitedError,
                "Pi session #{session} has no live process and no completed assistant response"
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
          "harness" => "pi",
          "pid" => session_ref["pid"] || session_ref[:pid],
          "cwd" => summary.fetch("cwd", nil) || session_ref["cwd"] || session_ref[:cwd],
          "session_id" => summary.fetch("session_id", nil) || session_ref["session_id"] || session_ref[:session_id],
          "session_file" => summary.fetch("session_file", nil),
          "is_streaming" => !summary.fetch("completed", false),
          "last_event_at" => summary.fetch("last_event_at", nil),
          "session_settings" => summary.fetch("session_settings"),
          "session_stats" => summary.fetch("session_stats", nil),
          "metadata" => metadata_with(
            session_ref,
            "session_name" => summary.fetch("session_name", nil) || metadata_value(session_ref, "session_name"),
            "completed" => summary.fetch("completed", false),
            "pi_state" => pi_state,
            "session_file_summary" => summary,
            "reconnected_from_session_file" => true
          )
        )
      end

      def session_file_summary(session_ref)
        path = session_file_path(session_ref)
        raise ProcessNotFoundError, "Pi session file is missing for #{session_ref_summary(session_ref)}" unless path && File.file?(path)

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
        last_assistant_index = nil
        last_user_index = nil
        records = []

        File.foreach(path) do |line|
          record = JSON.parse(line)
          record_index = records.length
          records << record
          summary["last_event_at"] = record["timestamp"] if record["timestamp"]
          if record["type"] == "session"
            summary["session_id"] ||= record["id"]
            summary["cwd"] ||= record["cwd"]
          elsif record["type"] == "session_info"
            summary["session_name"] = record["name"] if record["name"]
          elsif record["type"] == "message"
            case record.dig("message", "role")
            when "user"
              last_user_index = record_index
              user_text = message_text_from_message(record.fetch("message", {}))
              summary["last_user_text"] = user_text.byteslice(0, 4000).to_s.scrub if present?(user_text)
            when "assistant"
              last_assistant = record
              last_assistant_index = record_index
              text = assistant_text_from_message(record)
              summary["last_assistant_text"] = text if present?(text)
              stop_reason = record["stopReason"] || record.dig("message", "stopReason")
              summary["last_stop_reason"] = stop_reason if present?(stop_reason)
            end
          end
        rescue JSON::ParserError
          next
        end

        turn_pending = last_user_index && (!last_assistant_index || last_user_index > last_assistant_index)
        summary["turn_pending"] = !!turn_pending
        summary["last_assistant_text"] = nil if turn_pending
        summary["last_stop_reason"] = nil if turn_pending
        summary["completed"] = !turn_pending && assistant_message_completed?(last_assistant)
        summary["session_settings"] = session_settings_from_session_records(records)
        summary
      end

      def normalize_session_stats(stats)
        return nil unless stats.is_a?(Hash)

        context = stats["contextUsage"] || stats["context_usage"]
        context = normalize_context_usage(context)
        {
          "user_messages" => stats["userMessages"] || stats["user_messages"],
          "assistant_messages" => stats["assistantMessages"] || stats["assistant_messages"],
          "tool_calls" => stats["toolCalls"] || stats["tool_calls"],
          "tool_results" => stats["toolResults"] || stats["tool_results"],
          "total_messages" => stats["totalMessages"] || stats["total_messages"],
          "context_usage" => context
        }.compact
      end

      def normalize_context_usage(context)
        return nil unless context.is_a?(Hash)

        {
          "tokens" => context.key?("tokens") ? context["tokens"] : context["used"],
          "capacity" => context["contextWindow"] || context["context_window"] || context["capacity"],
          "percent" => context["percent"],
          # Pi documents this value as an estimate: it combines provider usage
          # with estimated tokens for messages after the latest response.
          "approximate" => true,
          "source" => "pi_session_stats"
        }
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

        raise ProcessNotFoundError, "Pi session cannot be resumed without a session file or session id: #{session_ref_summary(session_ref)}"
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

      def assistant_stop_reason(record)
        record["stopReason"] || record.dig("message", "stopReason")
      end

      def assistant_error_message(record)
        record["errorMessage"] || record.dig("message", "errorMessage") ||
          record["error"] || record.dig("message", "error")
      end

      def assistant_turn_ended_at(record)
        timestamp = record["timestamp"]
        return timestamp.to_s if present?(timestamp) && timestamp.is_a?(String)

        epoch_ms = record.dig("message", "timestamp")
        return nil unless epoch_ms.is_a?(Numeric)

        Time.at(epoch_ms / 1000.0).utc.iso8601
      end

      def completed_turn_outcome(stop_reason, text, ended_at)
        {
          "state" => "completed",
          "stop_reason" => present?(stop_reason) ? stop_reason.to_s : nil,
          "turn_ended_at" => ended_at,
          "last_assistant_text" => present?(text) ? text : nil
        }.compact
      end

      def incomplete_turn_outcome(stop_reason, ended_at)
        interrupted = %w[abort aborted].include?(stop_reason.to_s)
        {
          "state" => "incomplete",
          "kind" => interrupted ? "interrupted_turn" : "pending_tool_call",
          "reason" => interrupted ? "its last turn was interrupted before a final assistant result" :
                                    "its last turn stopped while a tool call was still pending",
          "stop_reason" => stop_reason.to_s,
          "turn_ended_at" => ended_at
        }.compact
      end

      def failed_turn_outcome(stop_reason, error_message, text, ended_at)
        unreplayable = UNREPLAYABLE_SESSION_PATTERN.match?(error_message.to_s)
        network = !unreplayable && NETWORK_ERROR_PATTERN.match?(error_message.to_s)
        {
          "state" => "failed",
          "kind" => turn_failure_kind(unreplayable, network),
          "reason" => turn_failure_reason(network, error_message, unreplayable: unreplayable),
          # Harness-neutral hint for the kernel: this session can never be resumed, but the work
          # can continue in a fresh session on the same workspace.
          "recovery" => unreplayable ? "fresh_session" : nil,
          "stop_reason" => stop_reason.to_s,
          "error_message" => present?(error_message) ? error_message.to_s : nil,
          # When the turn ended, so a later prompt can be told apart from stale evidence.
          "turn_ended_at" => ended_at,
          "last_assistant_text" => present?(text) ? text : nil
        }.compact
      end

      def turn_failure_kind(unreplayable, network)
        return "unreplayable_session" if unreplayable

        network ? "network_failure" : "provider_error"
      end

      def turn_failure_reason(network, error_message, unreplayable: false)
        detail = error_message.to_s.strip
        if unreplayable
          return "its saved session can no longer be replayed to the model, so resuming it fails the same way every time" if detail.empty?

          return "its saved session can no longer be replayed to the model, so resuming it fails " \
                 "the same way every time (#{detail})"
        end

        if network
          return "its model request failed mid-turn because the network connection dropped" if detail.empty?

          "its model request failed mid-turn (network error: #{detail})"
        else
          return "its model request failed mid-turn" if detail.empty?

          "its model request failed mid-turn (#{detail})"
        end
      end

      def last_assistant_record(session_ref)
        path = session_file_path(session_ref)
        return nil unless present?(path) && File.file?(path)

        records = session_file_tail_lines(path).filter_map do |line|
          record = parse_session_line(line)
          record if record.is_a?(Hash)
        end
        assistant_index = nil
        user_index = nil
        records.each_with_index do |record, index|
          next unless record["type"].nil? || record["type"] == "message"

          case record.dig("message", "role")
          when "assistant"
            assistant_index = index
          when "user"
            user_index = index
          end
        end
        # A session can retain a perfectly good answer from the previous turn after the next user
        # prompt has been written. It is not evidence for the current turn.
        return nil if user_index && (!assistant_index || user_index > assistant_index)

        assistant_index && records.fetch(assistant_index)
      end

      def session_file_tail_lines(path)
        size = File.size(path)
        offset = [size - TURN_OUTCOME_TAIL_BYTES, 0].max
        chunk = File.open(path, "rb") do |file|
          file.seek(offset)
          file.read
        end
        lines = chunk.to_s.split("\n")
        # The first line of a mid-file read is almost always truncated.
        lines.shift if offset.positive?
        lines.reject { |line| line.strip.empty? }
      end

      def parse_session_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      def current_turn_pending?(session_ref)
        path = session_file_path(session_ref)
        return false unless present?(path) && File.file?(path)

        session_file_summary(session_ref).fetch("turn_pending", false)
      rescue ProcessNotFoundError
        false
      end

      def assistant_message_completed?(record)
        return false unless record

        stop_reason = record["stopReason"] || record.dig("message", "stopReason")
        return false if TURN_INCOMPLETE_STOP_REASONS.include?(stop_reason.to_s)
        return true if present?(stop_reason)

        Array(record.dig("message", "content")).any? do |part|
          part.is_a?(Hash) && part["type"] == "text" && present?(part["text"])
        end
      end

      def history_session_view(session_ref)
        cache_mutex = Mutex.new
        cached_signature = nil
        cached_snapshot = nil
        SessionView::Handle.new(
          snapshot_loader: lambda {
            path = session_ref["session_file"] || session_ref[:session_file]
            signature = begin
              stat = path && File.stat(File.expand_path(path.to_s))
              [stat.size, stat.mtime.to_f]
            rescue SystemCallError
              [:missing]
            end
            process_alive = unmanaged_process_alive?(session_ref)
            signature << process_alive
            cache_mutex.synchronize do
              if cached_snapshot && cached_signature == signature
                next cached_snapshot
              end

              cached_signature = signature
              cached_snapshot = PiSessionView.history_snapshot(session_ref: session_ref, process_alive: process_alive)
            end
          }
        )
      end

      def exited_process_for(session_ref)
        process = managed_process_for_transport(session_ref)
        process && !process.alive? ? process : nil
      end

      def unmanaged_process_alive?(session_ref)
        !unmanaged_process_pid(session_ref).nil?
      end

      def unmanaged_process_pid(session_ref)
        supervision = transport_record(session_ref)
        candidates = [
          [session_ref["pid"] || session_ref[:pid], metadata_value(session_ref, "started_at")],
          [supervision["pid"], supervision["harness_started_at"]]
        ].uniq
        candidates.find do |pid, started_at|
          next false unless pid
          next false if process_for({ "pid" => integer_or_nil(pid) }, required: false)

          live_harness_process_at?(pid, started_at: started_at)
        end&.first&.to_i
      end

      def process_for_session(session_ref, required: false)
        process = managed_process_for_transport(session_ref)
        return process if process&.alive?

        # Session-bearing refs must never fall back to a pid-only lookup: during recovery that pid
        # can already belong to another session's newly attached process. Refs without a stable key
        # are only used during initial process setup and retain the legacy lookup.
        process = process_for(session_ref, required: false) unless stable_transport_key?(session_ref)
        return process if process
        return nil unless required

        raise ProcessNotFoundError,
              "No live Pi RPC process for session #{session_ref["session_id"] || session_ref[:session_id] || "unknown"}"
      end

      def stable_transport_key?(session_ref)
        present?(session_ref["session_id"] || session_ref[:session_id]) ||
          present?(session_ref["session_file"] || session_ref[:session_file])
      end

      def managed_process_for_transport(session_ref)
        key = transport_key(session_ref)
        return nil unless key

        @processes_mutex.synchronize { @processes_by_transport_key[key] }
      end

      def associate_process_with_transport(session_ref)
        key = transport_key(session_ref)
        pid = integer_or_nil(session_ref["pid"] || session_ref[:pid])
        return false unless key && pid

        @processes_mutex.synchronize do
          process = @processes_by_pid[pid]
          return false unless process

          @processes_by_transport_key[key] = process
          true
        end
      end

      def transport_record(session_ref)
        key = transport_key(session_ref)
        key ? transport_ownership.record_for(key) : {}
      rescue StandardError
        {}
      end

      def newest_supervision_source(lease, persisted)
        lease_available = lease.is_a?(Hash) && lease["owner_pid"]
        persisted_available = persisted.is_a?(Hash) && persisted["owner_pid"]
        return [lease, "transport_ownership"] if lease_available && !persisted_available
        return [persisted, "session_metadata"] if persisted_available && !lease_available
        return [{}, nil] unless lease_available && persisted_available

        lease_time = parse_supervision_time(lease["updated_at"])
        persisted_time = parse_supervision_time(persisted["recorded_at"])
        if persisted_time && (!lease_time || persisted_time > lease_time)
          [persisted, "session_metadata"]
        else
          [lease, "transport_ownership"]
        end
      end

      def parse_supervision_time(value)
        return nil unless present?(value)

        Time.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def live_harness_process_at?(pid, started_at: nil)
        return false unless process_alive?(pid)

        ProcessIdentity.matches?(pid, command: Array(command).first, started_at: started_at)
      end

      def process_identity_alive?(pid, started_at: nil)
        return false unless pid
        return ProcessIdentity.alive?(pid) unless present?(started_at)

        ProcessIdentity.matches?(pid, started_at: started_at)
      end

      def integer_or_nil(value)
        numeric = Integer(value)
        numeric.positive? ? numeric : nil
      rescue ArgumentError, TypeError
        nil
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
          raise RpcError, "Expected Pi RPC response, got: #{response.inspect}"
        end

        unless response["success"]
          raise RpcError, response["error"].to_s.empty? ? "Pi RPC command failed" : response["error"].to_s
        end

        data = response["data"]
        return data if data || allow_nil_data

        raise RpcError, "Pi RPC response for #{response["command"].inspect} did not include data"
      end

      def validate_cwd!(cwd)
        expanded = File.expand_path(cwd.to_s)
        raise ArgumentError, "cwd must be an existing directory: #{cwd.inspect}" unless Dir.exist?(expanded)

        expanded
      end

      def normalize_mode!(mode)
        normalized = MODE_ALIASES[mode.to_s]
        return normalized if normalized

        raise InvalidModeError, "Unknown Pi prompt mode: #{mode.inspect}"
      end

      def delivered_mode_metadata(requested_mode:, delivered_mode:, note:)
        {
          "requested_prompt_mode" => requested_mode,
          "delivered_prompt_mode" => delivered_mode,
          "prompt_mode_note" => note
        }
      end

      def prompt_mode_noun(mode)
        case mode.to_s
        when "steer" then "correction"
        when "follow_up" then "follow-up"
        else "prompt"
        end
      end

      def register_process(process)
        @processes_mutex.synchronize do
          @processes_by_pid[process.pid] = process
        end
      end

      def unregister_process(process)
        @processes_mutex.synchronize do
          @processes_by_pid.delete(process.pid)
          @processes_by_transport_key.delete_if { |_key, registered| registered.equal?(process) }
        end
      end

      def process_for(session_ref, required: true)
        pid = session_ref["pid"] || session_ref[:pid]
        process = @processes_mutex.synchronize { @processes_by_pid[pid] }

        return process if process && process.alive?
        return nil unless required

        raise ProcessNotFoundError, "No live Pi RPC process for pid #{pid.inspect}"
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

    end
  end
end
