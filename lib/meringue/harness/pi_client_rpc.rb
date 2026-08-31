# frozen_string_literal: true

module Meringue
  module Harness
    class PiClient
      public
      def wait_for_settled(session_ref, timeout: event_timeout)
        wait_for_event(session_ref, type: "agent_settled", timeout: timeout)
      end

      def last_assistant_text(session_ref)
        process = process_for_session(session_ref, required: false)
        if process
          # Pi's RPC can still expose the previous turn's answer after a new prompt has been
          # accepted. Never let that stale answer settle the current turn as completed.
          return nil if current_turn_pending?(session_ref)

          data = rpc_data(process.request({ "type" => "get_last_assistant_text" }, timeout: command_timeout))
          return data["text"]
        end

        session_file_summary(session_ref).fetch("last_assistant_text", nil)
      end

      public
      def turn_outcome(session_ref)
        record = last_assistant_record(session_ref)
        return nil unless record

        stop_reason = assistant_stop_reason(record)
        text = assistant_text_from_message(record)
        ended_at = assistant_turn_ended_at(record)
        return incomplete_turn_outcome(stop_reason, ended_at) if TURN_INCOMPLETE_STOP_REASONS.include?(stop_reason.to_s)
        return completed_turn_outcome(stop_reason, text, ended_at) unless TURN_FAILURE_STOP_REASONS.include?(stop_reason.to_s)

        failed_turn_outcome(stop_reason, assistant_error_message(record), text, ended_at)
      rescue StandardError
        nil
      end

      private
      def settle_interactive_rpc_turn(session_ref)
        settled_ref = abort_session(session_ref)
        return settled_ref unless settled_ref.fetch("is_streaming", false)

        wait_for_settled(settled_ref)
        refreshed = get_state(settled_ref)
        return refreshed unless refreshed.fetch("is_streaming", false)

        raise SessionBusyError,
              "Pi acknowledged the focus handoff abort but the managed turn is still active; the RPC writer was left untouched."
      end

      def quiesce_interactive_rpc(session_ref)
        process = process_for_session(session_ref, required: false)
        unless process
          if unmanaged_process_alive?(session_ref)
            raise SessionTransportUnavailableError,
                  "Refusing the Agent session while another live Pi process still owns this session"
          end

          release_transport(session_ref, pid: session_ref.fetch("pid", nil))
          return session_ref.merge(
            "pid" => nil,
            "is_streaming" => false,
            "metadata" => metadata_with(
              session_ref,
              "interactive_rpc_quiesced" => true,
              "interactive_rpc_already_stopped" => true
            )
          )
        end

        process.terminate(timeout: INTERACTIVE_RPC_SHUTDOWN_TIMEOUT)
        unregister_process(process)
        release_transport(session_ref, pid: process.pid)
        session_ref.merge(
          "pid" => nil,
          "is_streaming" => false,
          "last_event_at" => process.last_event_at,
          "metadata" => metadata_with(session_ref, "interactive_rpc_quiesced" => true)
        )
      end

      def prompt_delivery_marker(delivery_id)
        value = delivery_id.to_s.strip
        return nil if value.empty?

        safe_id = value.gsub(/[^A-Za-z0-9_.:@\/-]/, "_")
        "#{PROMPT_DELIVERY_MARKER_PREFIX}#{safe_id} -->"
      end

      def prompt_with_delivery_marker(prompt, delivery_id)
        marker = prompt_delivery_marker(delivery_id)
        return prompt unless marker
        return prompt if prompt.include?(marker)

        "#{prompt}\n\n#{marker}"
      end

      def scan_prompt_delivery_receipt(path, marker)
        @prompt_receipt_mutex.synchronize do
          stat = File.stat(path)
          key = [File.expand_path(path), marker]
          cached = @prompt_receipt_cache[key]
          return [true, cached["delivered_at"]] if cached&.fetch("delivered", false)

          offset = if cached && cached.fetch("inode", nil) == stat.ino && cached.fetch("size", 0).to_i <= stat.size
                     [cached.fetch("size", 0).to_i - marker.bytesize, 0].max
                   else
                     0
                   end
          bytes = File.open(path, "rb") do |file|
            file.seek(offset)
            file.read.to_s
          end
          marker_offset = bytes.index(marker)
          delivered = !marker_offset.nil?
          delivered_at = if delivered
                           line_start = bytes.rindex("\n", marker_offset) || -1
                           line_end = bytes.index("\n", marker_offset) || bytes.bytesize
                           line = bytes.byteslice(line_start + 1, line_end - line_start - 1)
                           begin
                             entry = JSON.parse(line)
                             message = entry.is_a?(Hash) ? entry["message"] : nil
                             entry.fetch("timestamp", nil) || (message.is_a?(Hash) && message.fetch("timestamp", nil)) || stat.mtime.utc.iso8601
                           rescue JSON::ParserError
                             stat.mtime.utc.iso8601
                           end
                         end
          @prompt_receipt_cache[key] = {
            "inode" => stat.ino,
            "size" => stat.size,
            "delivered" => delivered,
            "delivered_at" => delivered_at
          }
          [delivered, delivered_at]
        end
      end

      def compatible_thinking_level(current_level, available_levels)
        current_index = THINKING_LEVELS.index(current_level)
        return nil unless current_index

        THINKING_LEVELS.first(current_index + 1).reverse_each.find do |level|
          available_levels.include?(level)
        end || available_levels.first
      end

      def model_catalog_timeout
        [command_timeout.to_i, DEFAULT_MODEL_CATALOG_TIMEOUT].max
      end

      def build_model_catalog_argv
        Array(command).map(&:to_s) + ["--mode", "rpc", "--no-session"] +
          without_options(extra_args, "--model", "--thinking")
      end

      def catalog_probe_cwd(cwd)
        [cwd, Dir.pwd, Dir.tmpdir].compact.each do |candidate|
          expanded = File.expand_path(candidate.to_s)
          return expanded if Dir.exist?(expanded)
        end
        raise Error, "No usable working directory for a Pi model catalog probe"
      end

      def model_catalog_entry(model)
        return nil unless model.is_a?(Hash)

        provider = model["provider"].to_s
        model_id = (model["id"] || model["modelId"]).to_s
        return nil if provider.empty? || model_id.empty?

        ModelCatalog.entry(
          provider: provider,
          id: model_id,
          name: model["name"],
          thinking_levels: supported_thinking_levels(model),
          reasoning: !!model["reasoning"],
          context_window: model["contextWindow"],
          max_tokens: model["maxTokens"]
        )
      end

      def supported_thinking_levels(model)
        return ["off"] unless model["reasoning"]

        map = model["thinkingLevelMap"]
        map = nil unless map.is_a?(Hash)
        THINKING_LEVELS.select do |level|
          mapped_present = map&.key?(level)
          next false if mapped_present && map[level].nil?
          next !!mapped_present if EXPLICIT_THINKING_LEVELS.include?(level)

          true
        end
      end

      def parse_model_reference!(model_reference)
        parsed = ModelReference.parse(model_reference)
        unless parsed
          raise InvalidModelReferenceError,
                "Pi models must use a provider/model id: " \
                "#{ModelReference.rejection_reason(model_reference)}. #{ModelReference::FORMAT_HINT}"
        end

        [parsed.fetch("provider"), parsed.fetch("id")]
      end

      def writable_session_state(session_ref)
        if unmanaged_process_alive?(session_ref) && !process_for_session(session_ref, required: false)
          owner_pid = transport_owner_pid(session_ref)
          owner = owner_pid ? "Meringue instance #{owner_pid}" : "another Meringue instance"
          raise SessionTransportUnavailableError,
                "This Pi session is owned by #{owner}; update it from that window or wait until it is resumable."
        end

        existing_process = process_for_session(session_ref, required: false)
        state_ref = if existing_process
                      get_state(session_ref)
                    else
                      attach_session(session_ref)
                    end
        if state_ref.fetch("is_streaming", false)
          raise SessionSettingsBusyError,
                "Pi session is currently running; wait for it to settle before changing its model or thinking level."
        end

        [state_ref, process_for(state_ref), existing_process.nil?]
      end

      def release_settings_attachment(process, session_ref)
        return unless process

        process.terminate(timeout: shutdown_timeout)
        unregister_process(process)
        release_transport(session_ref || {}, pid: process.pid)
      rescue StandardError
        nil
      end

      def session_settings_from_pi_state(pi_state)
        model = pi_state["model"]
        normalized_model = normalize_pi_model(model)
        thinking_level = present?(pi_state["thinkingLevel"]) ? pi_state["thinkingLevel"].to_s : nil
        session_settings(
          model: normalized_model,
          thinking_level: thinking_level,
          source: "live_session_state",
          note: normalized_model || thinking_level ? nil : "Pi get_state did not report a model or thinking level."
        )
      end

      def session_settings_from_session_records(records)
        entries = Array(records).select { |record| record.is_a?(Hash) && present?(record["id"]) }
        by_id = entries.to_h { |record| [record["id"].to_s, record] }
        branch = []
        cursor = entries.last
        seen = {}
        while cursor && !seen[cursor["id"].to_s]
          branch << cursor
          seen[cursor["id"].to_s] = true
          parent_id = cursor["parentId"]
          cursor = present?(parent_id) ? by_id[parent_id.to_s] : nil
        end
        branch.reverse!

        model_change = branch.reverse.find { |record| record["type"] == "model_change" }
        assistant = branch.reverse.find do |record|
          record["type"] == "message" && record.dig("message", "role") == "assistant"
        end
        provider = model_change&.fetch("provider", nil) || assistant&.dig("message", "provider")
        model_id = model_change&.fetch("modelId", nil) || assistant&.dig("message", "model")
        normalized_model = if present?(provider) && present?(model_id)
                             normalize_pi_model("provider" => provider, "id" => model_id)
                           end
        thinking_change = branch.reverse.find { |record| record["type"] == "thinking_level_change" }
        thinking_level = thinking_change&.fetch("thinkingLevel", nil)&.to_s

        settings = session_settings(
          model: normalized_model,
          thinking_level: thinking_level,
          source: "persisted_session",
          note: normalized_model || thinking_level ? nil : "Pi session metadata does not contain model or thinking settings."
        )
        settings["model_source"] = model_change ? "model_change" : "assistant_message" if normalized_model
        settings
      end

      def normalize_pi_model(model)
        return nil unless model.is_a?(Hash)

        provider = model["provider"].to_s
        model_id = (model["id"] || model["modelId"]).to_s
        return nil if provider.empty? || model_id.empty?

        {
          "provider" => provider,
          "id" => model_id,
          "reference" => ModelReference.format(provider: provider, id: model_id),
          "name" => present?(model["name"]) ? model["name"].to_s : nil
        }.compact
      end

      def session_settings(model:, thinking_level:, source:, note: nil)
        availability = if model && thinking_level
                         "available"
                       elsif model || thinking_level
                         "partial"
                       else
                         "unknown"
                       end
        {
          "model" => model,
          "thinking_level" => thinking_level,
          "availability" => availability,
          "source" => source,
          "note" => note
        }.compact
      end

      def unknown_session_settings(note)
        {
          "model" => nil,
          "thinking_level" => nil,
          "availability" => "unknown",
          "source" => "pi",
          "note" => note.to_s
        }
      end

      def transport_key(session_ref)
        session_id = session_ref["session_id"] || session_ref[:session_id]
        return "pi-#{session_id}" if present?(session_id)

        session_file = session_ref["session_file"] || session_ref[:session_file]
        return "pi-#{File.basename(session_file.to_s, ".jsonl")}" if present?(session_file)

        pid = session_ref["pid"] || session_ref[:pid]
        present?(pid) ? "pi-pid-#{pid}" : nil
      end

      def claim_transport(session_ref, note: nil)
        key = transport_key(session_ref)
        return false unless key

        # Bind the in-memory pipes to the durable session key before exposing the ref. Looking up
        # transports by pid alone is unsafe during mass recovery because the OS may reuse one dead
        # worker's pid for a different worker's replacement process.
        associate_process_with_transport(session_ref)
        transport_ownership.claim(
          key,
          pid: session_ref["pid"] || session_ref[:pid],
          session_id: session_ref["session_id"] || session_ref[:session_id],
          note: note
        )
      rescue StandardError
        false
      end

      def release_transport(session_ref, pid: nil)
        key = transport_key(session_ref)
        return false unless key

        transport_ownership.release(key, pid: pid)
      rescue StandardError
        false
      end

      def take_over_transport(session_ref)
        key = transport_key(session_ref)
        return { "action" => "none", "resumable" => resumable_session?(session_ref) } unless key

        transport_ownership.with_lease(key) do |lease|
          pid = live_unowned_pid(session_ref, lease)
          unless pid
            lease.release!(pid: lease.harness_pid) if lease.harness_pid && !process_alive?(lease.harness_pid)
            next { "action" => "none", "resumable" => resumable_session?(session_ref) }
          end

          owner_pid = owner_pid_for(pid, lease)
          owner_alive = owner_pid && owner_pid != Process.pid && ProcessIdentity.alive?(owner_pid)
          raise SessionBusyError, busy_owner_message(owner_pid, pid) if owner_alive && !settled_for_takeover?(session_ref)

          terminate_unowned_process(pid)
          lease.release!(pid: pid)
          {
            "action" => "reclaimed",
            "reclaimed_pid" => pid,
            "previous_owner_pid" => owner_pid,
            "previous_owner_alive" => !!owner_alive,
            "resumable" => true
          }
        end
      rescue TransportOwnership::LockTimeout => e
        raise SessionTransportUnavailableError,
              "#{e.message}. Another Meringue instance is taking this session over right now; retry in a moment."
      end

      def takeover_metadata(takeover)
        return {} unless takeover.is_a?(Hash) && takeover.fetch("action", nil) == "reclaimed"

        {
          "transport_available" => true,
          "transport_reclaimed_at" => Time.now.utc.iso8601,
          "transport_reclaimed_pid" => takeover["reclaimed_pid"],
          "transport_previous_owner_pid" => takeover["previous_owner_pid"],
          "transport_note" => "Meringue instance #{Process.pid} took this Pi session over from " \
                              "#{takeover["previous_owner_pid"] || "a previous owner"} and resumed it from its session file."
        }.compact
      end

      def live_unowned_pid(session_ref, lease)
        candidates = [lease.harness_pid, session_ref["pid"] || session_ref[:pid]].compact.uniq
        candidates.find do |candidate|
          next false if process_for({ "pid" => candidate }, required: false)

          live_harness_process?(candidate, session_ref)
        end
      end

      def owner_pid_for(pid, lease)
        recorded = lease.recorded_owner_pid if lease.harness_pid == pid
        return recorded if recorded

        description = ProcessIdentity.describe(pid)
        parent = description && description.fetch("ppid", nil)
        parent && parent > 1 ? parent : nil
      end

      def live_harness_process?(pid, session_ref)
        return false unless process_alive?(pid)

        ProcessIdentity.matches?(
          pid,
          command: Array(command).first,
          started_at: metadata_value(session_ref, "started_at")
        )
      end

      def settled_for_takeover?(session_ref)
        deadline = monotonic_time + takeover_settle_timeout
        loop do
          return true if resumable_session?(session_ref)
          return false if monotonic_time >= deadline

          sleep TAKEOVER_POLL_INTERVAL
        end
      end

      def resumable_session?(session_ref)
        session_file_summary(session_ref).fetch("completed", false)
      rescue StandardError
        false
      end

      def terminate_unowned_process(pid)
        signal_unowned_process("TERM", pid)
        return true unless wait_for_process_exit(pid, TAKEOVER_EXIT_TIMEOUT)

        signal_unowned_process("KILL", pid)
        wait_for_process_exit(pid, TAKEOVER_EXIT_TIMEOUT)
        !process_alive?(pid)
      end

      def signal_unowned_process(signal, pid)
        Process.kill(signal, Integer(pid))
        true
      rescue Errno::ESRCH, ArgumentError, TypeError
        false
      rescue Errno::EPERM
        raise SessionTransportUnavailableError,
              "Pi process #{pid} belongs to another user, so this Meringue instance cannot take its session over. " \
              "Stop that process, or continue this issue with a new worker."
      end

      def wait_for_process_exit(pid, timeout)
        deadline = monotonic_time + timeout
        while process_alive?(pid)
          return true if monotonic_time >= deadline

          sleep TAKEOVER_POLL_INTERVAL
        end
        false
      end

      def busy_owner_message(owner_pid, pid)
        "Meringue instance #{owner_pid} owns this Pi session (process #{pid}) and is still mid-turn. " \
          "Prompting will take it over automatically once that turn settles: retry in a moment, " \
          "or quit instance #{owner_pid} to hand the session over now."
      end

      def transport_owner_pid(session_ref)
        key = transport_key(session_ref)
        return nil unless key

        record = transport_ownership.record_for(key)
        owner = record["owner_pid"]
        owner && Integer(owner) != Process.pid ? Integer(owner) : nil
      rescue StandardError
        nil
      end

      def unowned_transport_note(session_ref)
        owner_pid = transport_owner_pid(session_ref)
        if owner_pid && ProcessIdentity.alive?(owner_pid)
          "The saved Pi process is alive and Meringue instance #{owner_pid} owns its RPC pipes. " \
            "Showing persisted history; prompting takes the session over once its current turn settles."
        else
          "The saved Pi process is alive but no Meringue instance owns its RPC pipes. " \
            "Showing persisted history; prompting reclaims the session automatically."
        end
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def preserve_session_identity(current_ref, previous_ref)
        current_ref.merge(
          "session_file" => current_ref.fetch("session_file", nil) || previous_ref.fetch("session_file", nil),
          "session_id" => current_ref.fetch("session_id", nil) || previous_ref.fetch("session_id", nil),
          "cwd" => current_ref.fetch("cwd", nil) || previous_ref.fetch("cwd", nil)
        ).compact
      end

      def create_replacement_session_from_rpc(session_ref)
        process = process_for_session(session_ref)
        data = rpc_data(process.request({ "type" => "get_entries" }, timeout: command_timeout))
        entries = Array(data.fetch("entries", []))
        replacement_id = SecureRandom.uuid
        cwd = session_ref.fetch("cwd", nil) || Dir.pwd
        directory = File.expand_path(session_dir || File.join(cwd, ".meringue", "pi-sessions"))
        FileUtils.mkdir_p(directory)
        path = File.join(directory, "#{Time.now.utc.strftime("%Y%m%d_%H%M%S")}_#{replacement_id}.jsonl")
        temporary = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}"
        header = {
          "type" => "session",
          "version" => 3,
          "id" => replacement_id,
          "timestamp" => Time.now.utc.iso8601,
          "cwd" => cwd,
          "parentSession" => session_ref.fetch("session_file", nil)
        }.compact
        File.open(temporary, "w", 0o600) do |file|
          file.puts(JSON.generate(header))
          entries.each { |entry| file.puts(JSON.generate(entry)) }
        end
        File.rename(temporary, path)
        {
          "session_id" => replacement_id,
          "session_file" => path,
          "entry_count" => entries.length,
          "source_session_id" => session_ref.fetch("session_id", nil),
          "latest_user_intent" => entries.reverse_each.filter_map do |entry|
            message = entry.is_a?(Hash) ? entry["message"] : nil
            next unless message.is_a?(Hash) && message.fetch("role", nil).to_s == "user"

            message_text_from_message(message)
          end.first,
          "reason" => "rpc_session_file_unavailable"
        }.compact
      rescue StandardError
        File.delete(temporary) if defined?(temporary) && temporary && File.file?(temporary)
        raise
      end

      def safe_session_file_summary(session_ref)
        session_file_summary(session_ref)
      rescue StandardError
        {}
      end

      def bounded_handoff_summary(summary)
        return {} unless summary.is_a?(Hash)

        summary.slice(
          "session_file", "session_id", "turn_pending", "last_stop_reason", "last_event_at", "session_name",
          "last_user_text", "last_assistant_text"
        ).each_with_object({}) do |(key, value), bounded|
          bounded[key] = value.is_a?(String) ? value.byteslice(0, 4000).to_s.scrub : value
        end.compact
      end

      def latest_user_intent(events)
        Array(events).reverse_each do |entry|
          event = entry.is_a?(Hash) ? (entry["event"] || entry) : {}
          message = event["message"] || event
          next unless message.is_a?(Hash) && message.fetch("role", nil).to_s == "user"

          text = message_text_from_message(message)
          return text if present?(text)
        end
        nil
      end

      def message_text_from_message(message)
        content = message.fetch("content", nil)
        return content.to_s.strip if content.is_a?(String)

        Array(content).filter_map do |part|
          part["text"] if part.is_a?(Hash) && part["type"].to_s == "text"
        end.join("\n").strip
      end

      def interactive_continuation_prompt(session_ref, events:, latest_user_intent:, session_summary:)
        context = session_ref.dig("metadata", "interactive_handoff", "context")
        context = {} unless context.is_a?(Hash)
        progress = PiSessionView.progress_items(events).last(10).filter_map do |item|
          text = item.is_a?(Hash) ? item["text"] : nil
          bounded_handoff_text(text, 2_000) if present?(text)
        end

        sections = [
          "Meringue interrupted the dashboard-managed turn because the user requested an Agent session. " \
          "Continue the same task in this existing workspace and session. Inspect the transcript and current files " \
          "before repeating tool calls; work completed before the interruption may already be present."
        ]
        issue_line = [context["issue_id"], context["issue_title"]].compact.map(&:to_s).reject(&:empty?).join(" — ")
        sections << "Current issue: #{bounded_handoff_text(issue_line, 1_000)}" unless issue_line.empty?
        sections << "Issue description:\n#{bounded_handoff_text(context["issue_description"], 4_000)}" if present?(context["issue_description"])
        sections << "Original worker assignment:\n#{bounded_handoff_text(context["assignment"], 6_000)}" if present?(context["assignment"])
        sections << "Latest user intent in the saved transcript:\n#{bounded_handoff_text(latest_user_intent, 3_000)}" if present?(latest_user_intent)
        sections << "Last durable assistant text before interruption:\n#{bounded_handoff_text(session_summary["last_assistant_text"], 3_000)}" if present?(session_summary["last_assistant_text"])
        sections << "Recent in-memory assistant progress before interruption:\n#{progress.join("\n")}" unless progress.empty?
        workspace = [context["workspace_path"], context["workspace_branch"]].compact.map(&:to_s).reject(&:empty?).join(" on branch ")
        sections << "Workspace continuity: #{bounded_handoff_text(workspace, 2_000)}" unless workspace.empty?
        sections.join("\n\n")
      end

      def bounded_handoff_text(value, bytes)
        value.to_s.byteslice(0, bytes).to_s.scrub.strip
      end

      def interactive_session_argv(session_ref, handoff_prompt: nil)
        session = resume_session_argument(session_ref)
        argv = Array(command).map(&:to_s)
        argv += ["--session-dir", File.expand_path(session_dir)] if present?(session_dir)
        argv += ["--session", session]
        session_name = metadata_value(session_ref, "session_name")
        argv += ["--name", session_name.to_s] if present?(session_name)
        session_arguments = without_options(extra_args, "--model", "--thinking")
        session_arguments += session_setting_arguments(session_ref.fetch("session_settings", {}))
        session_arguments = enforce_read_only_tools(session_arguments) if metadata_value(session_ref, "workspace_mode") == "shared_read_only"
        argv += session_arguments
        argv << handoff_prompt.to_s if present?(handoff_prompt)
        argv
      end

      def resolve_interactive_executable(argv, cwd:, environment:)
        name = Array(argv).first.to_s
        path = environment.fetch("PATH", ENV.fetch("PATH", "")).to_s
        resolved = if name.include?(File::SEPARATOR)
                     candidate = File.expand_path(name, cwd.to_s)
                     candidate if File.file?(candidate) && File.executable?(candidate)
                   else
                     path.split(File::PATH_SEPARATOR).each_with_object(nil) do |directory, _unused|
                       directory = "." if directory.empty?
                       candidate = File.expand_path(File.join(directory, name), cwd.to_s)
                       break candidate if File.file?(candidate) && File.executable?(candidate)
                     end
                   end
        return resolved if resolved

        raise Error,
              "The configured Pi command #{name.inspect} could not be resolved for the Agent session " \
              "with PATH=#{path.inspect}. Configure [harness.pi] command with an executable path or make it " \
              "available in [harness.pi.env] PATH, then restart Meringue."
      end

      def interactive_handoff_metadata(was_streaming:, events:, prompt:, latest_user_intent:, session_summary:, interrupted_turn_outcome:, turn_checkpoint:, replacement:)
        progress = PiSessionView.progress_items(events)
        {
          "mode" => "native_interactive",
          "transfer" => was_streaming ? "coordinated_turn_abort" : "settled_session",
          "exact_stream_transfer" => !was_streaming,
          "was_streaming" => !!was_streaming,
          "continuation_required" => !!was_streaming,
          "interruption_method" => was_streaming ? "rpc_abort" : nil,
          "prompt" => prompt,
          "latest_user_intent" => latest_user_intent,
          "session_file_summary" => session_summary,
          "interrupted_turn_outcome" => interrupted_turn_outcome,
          "turn_checkpoint" => turn_checkpoint,
          "replacement" => replacement,
          "captured_event_count" => events.length,
          "last_progress" => progress.last(20),
          "tool_call_ids" => events.filter_map do |event|
            next unless event.is_a?(Hash)

            event["toolCallId"] || event.dig("message", "content")&.filter_map do |part|
              part["id"] if part.is_a?(Hash) && part["type"] == "toolCall"
            end
          end.flatten.uniq.last(50)
        }.compact
      end

      def bounded_turn_outcome(outcome)
        return nil unless outcome.is_a?(Hash)

        outcome.slice("state", "kind", "stop_reason", "turn_ended_at", "last_assistant_text").transform_values do |value|
          value.is_a?(String) ? value.byteslice(0, 4_000).to_s.scrub : value
        end.compact
      end

      def dashboard_continuation_required?(session_ref, handoff)
        details = handoff.is_a?(Hash) ? (handoff["handoff"] || handoff[:handoff] || handoff) : {}
        return false unless details.is_a?(Hash) && details.fetch("continuation_required", false)

        current = bounded_turn_outcome(turn_outcome(session_ref))
        checkpoint = details.fetch("turn_checkpoint", nil)
        return true unless current.is_a?(Hash)
        return true unless current.fetch("state", nil) == "completed"
        return true unless present?(current.fetch("last_assistant_text", nil))

        turn_outcome_signature(current) == turn_outcome_signature(checkpoint)
      end

      def turn_outcome_signature(outcome)
        return nil unless outcome.is_a?(Hash)

        %w[state kind stop_reason turn_ended_at last_assistant_text].map { |key| outcome.fetch(key, nil).to_s }.join("|")
      end

      def dashboard_continuation_prompt(handoff)
        details = handoff.is_a?(Hash) ? (handoff["handoff"] || handoff[:handoff] || handoff) : {}
        original = details.is_a?(Hash) ? details.fetch("prompt", nil) : nil
        return original if present?(original)

        "Continue the focused task from the existing transcript and workspace. Inspect current files and any pending tool work before repeating actions, then finish with a final result."
      end

      def build_argv(session_name:, system_prompt:, session: nil, session_settings: {}, workspace_mode: "isolated")
        argv = Array(command).map(&:to_s) + ["--mode", "rpc"]
        argv += ["--session-dir", File.expand_path(session_dir)] if present?(session_dir)
        argv += ["--session", session.to_s] if present?(session)
        argv += ["--name", session_name.to_s] if present?(session_name)
        argv += ["--append-system-prompt", system_prompt.to_s] if present?(system_prompt)
        session_arguments = extra_args
        if present?(session)
          # Config defaults are spawn-only. A resumed session receives its own
          # persisted effective settings, never defaults that changed later.
          session_arguments = without_options(session_arguments, "--model", "--thinking")
          session_arguments += session_setting_arguments(session_settings)
        elsif !session_settings.empty?
          model = session_settings["model"] || session_settings[:model]
          thinking = session_settings["thinking_level"] || session_settings[:thinking_level]
          if present?(model)
            session_arguments = without_options(session_arguments, "--model")
            session_arguments += ["--model", model.to_s]
          end
          if present?(thinking)
            session_arguments = without_options(session_arguments, "--thinking")
            session_arguments += ["--thinking", thinking.to_s]
          end
        end
        session_arguments = enforce_read_only_tools(session_arguments) if workspace_mode.to_s == "shared_read_only"
        argv + session_arguments
      end

      def session_setting_arguments(settings)
        return [] unless settings.is_a?(Hash)

        arguments = []
        model = model_reference_from_settings(settings)
        thinking = settings["thinking_level"] || settings[:thinking_level]
        arguments += ["--model", model] if ModelReference.valid?(model)
        arguments += ["--thinking", thinking.to_s] if present?(thinking)
        arguments
      end

      # Pi assistant messages can report a transport model name rather than the
      # catalog id. Prefer the explicit model_change record parsed from the
      # session file, then fill missing values from Meringue's live record.
      def persisted_session_settings(session_ref)
        recorded = session_ref["session_settings"] || session_ref[:session_settings] || {}
        recorded = {} unless recorded.is_a?(Hash)
        persisted = safe_session_file_summary(session_ref).fetch("session_settings", {})
        persisted = {} unless persisted.is_a?(Hash)

        persisted_model = persisted["model"] || persisted[:model]
        recorded_model = recorded["model"] || recorded[:model]
        model = if persisted.fetch("model_source", nil) == "model_change"
                  persisted_model
                else
                  recorded_model || persisted_model
                end
        thinking = persisted["thinking_level"] || persisted[:thinking_level] ||
                   recorded["thinking_level"] || recorded[:thinking_level]
        { "model" => model, "thinking_level" => thinking }.compact
      end

      def model_reference_from_settings(settings)
        return nil unless settings.is_a?(Hash)

        model = settings["model"] || settings[:model]
        return model.to_s if model.is_a?(String)
        return nil unless model.is_a?(Hash)

        reference = model["reference"] || model[:reference]
        return reference.to_s if present?(reference)

        provider = model["provider"] || model[:provider]
        id = model["id"] || model[:id] || model["modelId"] || model[:modelId]
        return nil unless present?(provider) && present?(id)

        ModelReference.format(provider: provider, id: id)
      end

      def enforce_read_only_tools(arguments)
        # Tool allowlisting blocks write/edit/bash, while disabling extensions closes the startup
        # side door: Pi extensions execute with full user permissions before a tool call and can
        # replace a built-in tool by name. Explicit -e/--extension arguments are removed too,
        # because Pi intentionally lets explicit extensions override --no-extensions.
        safe = without_options(arguments, "--tools", "-t", "--extension", "-e")
        safe << "--no-extensions" unless safe.include?("--no-extensions")
        safe + ["--tools", "read,grep,find,ls"]
      end

    end
  end
end
