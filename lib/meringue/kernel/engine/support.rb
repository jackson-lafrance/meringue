# frozen_string_literal: true

module Meringue
  module Kernel
    class Engine
      # Small shared helpers: harness client selection, command result shapes, payload reading, and
      # timestamps.
      #
      # Visibility does not carry across a reopened class body, so it is restated here.
      private

      def harness_client_for_agent(agent)
        resolved = @harness_client_resolver&.call(agent)
        return resolved if resolved

        if agent.fetch("type", nil) == "head" && active_head_runner(provider: agent.fetch("harness", nil)).respond_to?(:harness_client)
          return active_head_runner(provider: agent.fetch("harness", nil)).harness_client
        end

        active_harness_client(provider: agent.fetch("harness", nil))
      end

      def active_harness_provider(state = nil, role: "worker")
        source_state = state || normalized_state
        metadata = source_state.fetch("metadata", {})
        role = role.to_s == "head" ? "head" : "worker"
        fallback = role == "head" ? @default_head_harness_provider : @default_worker_harness_provider
        normalize_harness_provider(metadata["active_#{role}_harness"] || metadata["active_harness"] || fallback)
      end

      def normalize_harness_provider(provider)
        normalized = Meringue::Harness::Registry.normalize_provider(provider)
        selectable_harness_provider?(normalized) || normalized == "fake" ? normalized : @default_harness_provider.to_s
      end

      def normalize_initial_harness_provider(provider)
        normalized = Meringue::Harness::Registry.normalize_provider(provider)
        selectable_harness_provider?(normalized) || normalized == "fake" ? normalized : Meringue::Harness::Registry::DEFAULT_PROVIDER
      end

      def normalize_selectable_harness_provider(provider)
        normalized = Meringue::Harness::Registry.normalize_provider(provider)
        selectable_harness_provider?(normalized) ? normalized : nil
      end

      def selectable_harness_provider?(provider)
        Meringue::Harness::Registry::PROVIDERS.include?(provider.to_s)
      end

      def active_harness_selection_blockers(state)
        state.fetch("agents", []).select do |agent|
          %w[queued working].include?(agent.fetch("status", nil).to_s) ||
            (agent.fetch("harness_metadata", {}) || {}).fetch("is_streaming", false)
        end.map { |agent| agent.fetch("id", nil) }.compact
      end

      def inferred_default_harness_provider
        if @harness_client.respond_to?(:harness_name)
          @harness_client.harness_name
        elsif @head_runner.respond_to?(:harness_client) && @head_runner.harness_client&.respond_to?(:harness_name)
          @head_runner.harness_client.harness_name
        elsif @head_runner.class.name.to_s.end_with?("FakeRunner")
          "fake"
        else
          Meringue::Harness::Registry::DEFAULT_PROVIDER
        end
      end

      def merge_session_ref_into_agent!(agent, session_ref, persist_heartbeat: true)
        metadata = session_ref.fetch("metadata", {}) || {}
        unless persist_heartbeat
          # Harness freshness is runtime health evidence, not orchestration state. Provider state
          # may move message counters and last-event fields while a turn streams; preserve the
          # persisted values at any nesting depth so routine polls cannot touch lifecycle timestamps
          # or invalidate the durable snapshot. Drained events and progress use dedicated paths.
          persisted_metadata = agent.fetch("harness_metadata", {}) || {}
          metadata = stable_session_metadata(metadata, persisted_metadata)
        end
        agent["harness"] = session_ref.fetch("harness", agent.fetch("harness", nil))
        agent["pid"] = session_ref.fetch("pid", agent.fetch("pid", nil))
        agent["harness_session_id"] = session_ref.fetch("session_id", agent.fetch("harness_session_id", nil))
        agent["harness_session_file"] = session_ref.fetch("session_file", agent.fetch("harness_session_file", nil))
        agent["workspace_path"] ||= session_ref.fetch("cwd", nil)
        agent["session_settings"] = deep_copy(session_ref.fetch("session_settings")) if session_ref.fetch("session_settings", nil).is_a?(Hash)
        agent["session_stats"] = deep_copy(session_ref.fetch("session_stats")) if session_ref.fetch("session_stats", nil).is_a?(Hash)
        agent["harness_metadata"] = (agent.fetch("harness_metadata", {}) || {}).merge(
          metadata,
          "cwd" => session_ref.fetch("cwd", metadata.fetch("cwd", nil)),
          "is_streaming" => session_ref.fetch("is_streaming", false),
          "last_event_at" => persist_heartbeat ? session_ref.fetch("last_event_at", nil) : agent.dig("harness_metadata", "last_event_at"),
          "reconcile_state" => RECONCILE_STATE_HEALTHY,
          "reconcile" => nil
        ).compact
        mark_head_session_active!(agent)
      end

      def stable_session_metadata(incoming, persisted)
        return deep_copy(incoming) unless incoming.is_a?(Hash)

        persisted = {} unless persisted.is_a?(Hash)
        incoming.each_with_object({}) do |(key, value), stable|
          if heartbeat_session_metadata_key?(key)
            stable[key] = deep_copy(persisted[key]) if persisted.key?(key)
          elsif value.is_a?(Hash)
            stable[key] = stable_session_metadata(value, persisted[key])
          else
            stable[key] = deep_copy(value)
          end
        end
      end

      def heartbeat_session_metadata_key?(key)
        %w[last_event_at lastEventAt messageCount message_count].include?(key.to_s)
      end

      def cleanup_applied_head!(state, head_id, now: timestamp)
        head = find_agent(state, head_id)
        return { "changed" => false, "reason" => "head_not_found" } unless head
        return { "changed" => false, "reason" => "agent_is_not_head" } unless head.fetch("type", nil) == "head"

        session_release = release_head_session!(head, reason: "head_result_applied", now: now)

        metadata = head.fetch("harness_metadata", {}) || {}
        metadata = {} unless metadata.is_a?(Hash)
        head["status"] = "killed"
        head["updated_at"] = now
        head["harness_metadata"] = metadata.merge(
          "completed_at" => metadata.fetch("completed_at", nil) || now,
          "head_result_applied_at" => metadata.fetch("head_result_applied_at", nil) || now,
          "killed_at" => now,
          "cleanup_reason" => "head_result_applied",
          "is_streaming" => false
        ).compact

        remove_agent_from_active_state!(state, head_id)

        # Teardown detail rides along with the ApplyHeadResult log instead of adding a
        # second per-message log line to the visible history.
        {
          "changed" => true,
          "removed_agent_id" => head_id,
          "reason" => "head_result_applied",
          "session_release" => session_release,
          "session_id" => head.fetch("harness_session_id", nil),
          "log_entry_ids" => []
        }.compact
      end

      def remove_agent_from_active_state!(state, agent_id)
        state["agents"] = state.fetch("agents").reject { |agent| agent.fetch("id", nil) == agent_id }
        state.fetch("issues").each do |issue|
          next unless issue.key?("agent_ids")

          issue["agent_ids"] = Array(issue["agent_ids"]) - [agent_id]
        end
      end

      def payload_has?(hash, *keys)
        return false unless hash.respond_to?(:key?)

        keys.any? do |key|
          hash.key?(key) || hash.key?(key.to_sym)
        end
      end

      def value_at(hash, *keys)
        return nil unless hash.respond_to?(:[])

        keys.each do |key|
          return hash[key] if hash.key?(key)

          symbol_key = key.to_sym
          return hash[symbol_key] if hash.key?(symbol_key)
        end
        nil
      end

      # Whether the caller mentioned a key at all, as opposed to what its value
      # is. MoveIssue needs the difference: an explicitly empty parent means
      # "promote to top level", while an absent one means "leave parentage alone".
      def payload_key?(hash, *keys)
        return false unless hash.respond_to?(:key?)

        keys.any? { |key| hash.key?(key) || hash.key?(key.to_sym) }
      end

      def accepted_result(command_id, command_type, target_id, message, result, log_entry_ids)
        Result.new(
          command_id: command_id,
          command_type: command_type,
          status: "accepted",
          target_id: target_id,
          message: message,
          result: result,
          errors: [],
          log_entry_ids: log_entry_ids
        ).to_h
      end

      def rejected_result(command_id, command_type, message, errors)
        log_entry_ids = record_result_log(
          command_id: command_id,
          command_type: command_type,
          status: "rejected",
          level: "warning",
          message: message,
          errors: errors
        )

        Result.new(
          command_id: command_id,
          command_type: command_type,
          status: "rejected",
          message: message,
          errors: errors,
          log_entry_ids: log_entry_ids
        ).to_h
      end

      # A command the kernel deliberately did not apply because its target disappeared between the
      # decision and the application. Nothing mutated, so the journaled status stays `rejected` and
      # the batch cannot re-run it, but the user-visible line says "Skipped", carries the reason,
      # and names the intent that had nowhere to land. See `HEAD_BATCH_SKIP_ERROR_CODES`.
      def skipped_result(command_id, command_type, target_id, message, errors, level: "info", details: {})
        log_entry_ids = record_result_log(
          command_id: command_id,
          command_type: command_type,
          status: "rejected",
          level: level,
          message: message,
          errors: errors,
          label: "Skipped",
          extra_details: details
        )

        Result.new(
          command_id: command_id,
          command_type: command_type,
          status: "rejected",
          target_id: target_id,
          message: message,
          result: { "skipped" => errors.first, "details" => details },
          errors: errors,
          log_entry_ids: log_entry_ids
        ).to_h
      end

      def head_command_result_skipped?(result)
        return false unless result.is_a?(Hash)

        Array(result.fetch("errors", [])).any? { |error| HEAD_BATCH_SKIP_ERROR_CODES.include?(error.to_s) }
      end

      # A rejected or skipped command is a piece of the user's intent that did not land, so the line
      # the user reads must say what was dropped. "1 rejected" with no consequence is exactly how a
      # head's issue update disappeared without anyone being able to tell what it was.
      def with_dropped_intent(message, command)
        intent = dropped_command_intent(command)
        return message unless intent

        "#{message} Dropped #{intent}."
      end

      def dropped_command_intent(command)
        command_type = canonical_command_type(value_at(command, "type", "command_type"))
        payload = value_at(command, "payload")
        return nil unless payload.respond_to?(:[])

        case command_type
        when "ModifyIssue" then modify_issue_dropped_intent(payload)
        when "MoveWorker" then move_worker_dropped_intent(payload)
        when "SpawnWorker" then worker_dropped_intent(payload)
        when "PromptAgent" then prompt_dropped_intent(payload)
        end
      end

      def move_worker_dropped_intent(payload)
        agent_id = present_string(value_at(payload, "agent_id", "AgentID", "agentId"))
        target_issue_id = present_string(value_at(payload, "target_issue_id", "TargetIssueID", "targetIssueId", "issue_id", "IssueID", "issueId"))
        return "worker move" unless agent_id || target_issue_id

        "move of #{agent_id || "a worker"} to #{target_issue_id || "another issue"}"
      end

      def modify_issue_dropped_intent(payload)
        changes = []
        changes << "status → #{present_string(value_at(payload, "status", "Status"))}" if present_string(value_at(payload, "status", "Status"))
        changes << "title → #{single_line_excerpt(value_at(payload, "title", "Title"), limit: 60).inspect}" if payload_has?(payload, "title", "Title")
        changes << "description" if payload_has?(payload, "description", "Description")
        changes << "parent issue" if payload_has?(payload, "parent_issue_id", "ParentIssueID", "parentIssueId")
        return "issue update" if changes.empty?

        "issue update (#{changes.join(", ")})"
      end

      def worker_dropped_intent(payload)
        title = present_string(value_at(payload, "title", "Title"))
        return "worker #{single_line_excerpt(title, limit: 60).inspect}" if title

        prompt = present_string(value_at(payload, "prompt", "Prompt"))
        return "worker" unless prompt

        "worker for #{single_line_excerpt(prompt, limit: 60).inspect}"
      end

      def prompt_dropped_intent(payload)
        prompt = present_string(value_at(payload, "prompt", "Prompt", "message", "Message"))
        return "prompt" unless prompt

        "prompt #{single_line_excerpt(prompt, limit: 60).inspect}"
      end

      def failed_result(command_id, command_type, message, errors)
        log_entry_ids = record_result_log(
          command_id: command_id,
          command_type: command_type,
          status: "failed",
          level: "error",
          message: message,
          errors: errors
        )

        Result.new(
          command_id: command_id,
          command_type: command_type,
          status: "failed",
          message: message,
          errors: errors,
          log_entry_ids: log_entry_ids
        ).to_h
      end

      def record_result_log(command_id:, command_type:, status:, level:, message:, errors: [], label: nil, extra_details: {})
        state = normalized_state
        log_ids = append_log(
          state,
          source_type: "kernel",
          source_id: nil,
          level: level,
          message: "#{label || status.capitalize} #{command_type || "unknown"}: #{message}",
          details: {
            "command_id" => command_id,
            "command_type" => command_type,
            "status" => status,
            "errors" => errors
          }.merge(extra_details.is_a?(Hash) ? extra_details : {})
        )
        touch_state!(state)
        store.save(state)
        log_ids
      rescue StandardError
        []
      end

      def kill_session_safely(session_ref, agent: nil)
        client = agent ? harness_client_for_agent(agent) : harness_client
        client.kill_session(session_ref)
      rescue StandardError
        nil
      end

      def head_harness_name
        if head_runner.respond_to?(:harness_client) && head_runner.harness_client
          client = head_runner.harness_client
          return client.harness_name if client.respond_to?(:harness_name)

          client.class.name.to_s.split("::").last.to_s.sub(/Client\z/, "").downcase
        elsif head_runner.class.name.to_s.end_with?("FakeRunner")
          "fake"
        else
          "unknown"
        end
      end

      def same_path?(left, right)
        File.expand_path(left.to_s) == File.expand_path(right.to_s)
      end

      def default_project_name(path)
        basename = File.basename(path)
        fallback = basename.empty? || basename == "/" ? path : basename
        project_display_name(fallback) || fallback
      end

      # A project's name is its product name. A lifecycle status is what Meringue is
      # currently doing to it, so a status word can never be stored as part of the name
      # no matter who proposed it: a head echoing a rendered label, a slash command, or
      # the directory basename fallback.
      def project_display_name(name)
        ProjectNaming.without_status_suffix(present_string(name))
      end

      # Two logical projects over one directory are told apart by name, so the
      # comparison ignores case and surrounding space the way a person would.
      def same_project_name?(left, right)
        left.to_s.strip.casecmp(right.to_s.strip).zero?
      end

      def present_string(value)
        value = value.to_s.strip unless value.nil?
        value unless blank?(value)
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def error_payload(error)
        {
          "class" => error.class.name,
          "message" => sanitized_error_message(error)
        }
      end

      def sanitized_error_message(error)
        truncate_for_state(error.message.to_s, ERROR_MESSAGE_MAX_BYTES)
      end

      def truncate_for_state(text, max_bytes)
        return text if text.bytesize <= max_bytes

        text.byteslice(0, max_bytes).to_s.scrub + "\n… [truncated #{text.bytesize - max_bytes} bytes]"
      end

      def timestamp
        local_timestamp
      rescue StandardError
        global_timestamp
      end

      def local_timestamp
        Time.now.getlocal.iso8601
      end

      def global_timestamp
        Time.now.utc.iso8601
      end
    end
  end
end
