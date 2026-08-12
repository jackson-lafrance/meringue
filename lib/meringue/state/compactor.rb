# frozen_string_literal: true

require "json"

module Meringue
  module State
    module Compactor
      # `harness_metadata.command` is diagnostic spawn argv, not executable state. One
      # argument can contain the complete head system prompt and kernel snapshot, which
      # used to account for a large share of state.json. Omit that bounded diagnostic
      # field as a whole instead of keeping a misleading prefix of it.
      COMMAND_ARGUMENT_MAX_BYTES = 2_000
      COMMAND_ARGUMENT_OMISSION = "[omitted %<bytes>d-byte command argument by Meringue state compaction]"

      # These bounds apply only to redundant log diagnostics. Worker reports, goal
      # commands, command journals, and workspace/provisioning orchestration records
      # remain byte-complete. JSON.generate is the canonical measurement so the bound
      # is deterministic across pretty/compact state serialization.
      DIAGNOSTIC_DETAILS_MAX_BYTES = 16_384
      DIAGNOSTIC_MESSAGE_MAX_BYTES = 2_048
      DIAGNOSTIC_TEXT_HEAD_BYTES = 2_048
      DIAGNOSTIC_TEXT_TAIL_BYTES = 4_096
      DIAGNOSTIC_FIELD_MAX_BYTES = 1_024
      HEAD_COMMAND_RESULT_LIMIT = 12

      module_function

      # Message-bearing scalar values are deliberately never compacted here. Durable
      # logs reclaim space by evicting whole oldest records in Models, and routing
      # contexts select bounded sets of complete records. The only remaining deep-state
      # compaction is diagnostic command argv, whose oversized elements are replaced in
      # full rather than partially truncated.
      def compact!(state)
        compact_value!(state, nil)
      end

      def compact_value!(value, key)
        case value
        when Hash
          compact_hash!(value)
        when Array
          compact_array!(value, key)
        else
          false
        end
      end

      def compact_hash!(hash)
        changed = false
        hash.each do |key, value|
          if key.to_s == "logs" && value.is_a?(Array)
            value.each { |log| changed = true if compact_log!(log) }
          end
          changed = true if compact_value!(value, key.to_s)
        end
        changed
      end

      def compact_log!(log)
        return false unless log.is_a?(Hash) && log["details"].is_a?(Hash)

        details = log.fetch("details")
        return false if details["diagnostic_compaction"].to_s.match?(/\A(?:workspace|head_commands|spawn_failure)_v1\z/)
        compacted = if workspace_diagnostic?(details)
                      workspace_diagnostic_log(log.fetch("message", ""), details)
                    elsif head_command_diagnostic?(details)
                      { "message" => log.fetch("message", ""), "details" => head_command_diagnostic_details(details) }
                    elsif spawn_failure_diagnostic?(details)
                      diagnostic_log(log.fetch("message", ""), spawn_failure_diagnostic_details(details))
                    end
        return false unless compacted

        changed = compacted.fetch("details") != details || compacted.fetch("message") != log.fetch("message", "")
        log["message"] = compacted.fetch("message")
        log["details"] = compacted.fetch("details")
        changed
      end

      def workspace_diagnostic?(details)
        details["workspace"].is_a?(Hash) && details.key?("provisioning_state")
      end

      def head_command_diagnostic?(details)
        # Typed log records such as `unrouted_user_message` also carry concise command results.
        # Their `kind` is part of the user-facing lookup contract, not redundant diagnostics.
        !details.key?("kind") && details.key?("head_id") && details["command_results"].is_a?(Array)
      end

      def spawn_failure_diagnostic?(details)
        details["command_type"].to_s == "SpawnWorker" && details["status"].to_s != "accepted"
      end

      def workspace_diagnostic_log(message, details)
        diagnostic_log(message, workspace_diagnostic_details(details))
      end

      def diagnostic_log(message, details)
        compacted_message = diagnostic_message(message)
        if compacted_message != message.to_s
          details["message_original_bytes"] = message.to_s.bytesize
          details["message_omitted_bytes"] = message.to_s.bytesize - (DIAGNOSTIC_MESSAGE_MAX_BYTES / 2) - (DIAGNOSTIC_MESSAGE_MAX_BYTES / 3)
        end
        enforce_details_bound!(details)
        { "message" => compacted_message, "details" => details }
      end

      def diagnostic_message(value)
        text = value.to_s
        return text if text.bytesize <= DIAGNOSTIC_MESSAGE_MAX_BYTES

        head_bytes = DIAGNOSTIC_MESSAGE_MAX_BYTES / 2
        tail_bytes = DIAGNOSTIC_MESSAGE_MAX_BYTES / 3
        omitted = text.bytesize - head_bytes - tail_bytes
        marker = "\n[omitted #{omitted} diagnostic message bytes]\n"
        byteslice_utf8(text, 0, head_bytes) + marker + byteslice_utf8(text, text.bytesize - tail_bytes, tail_bytes)
      end

      def workspace_diagnostic_details(details)
        workspace = details.fetch("workspace")
        result = copy_fields(details, %w[issue_id provisioning_state provisioning_attempts command_author_id])
        result["recovery_guidance"] = details["recovery_guidance"] if details.key?("recovery_guidance")
        result["errors"] = diagnostic_values(details["errors"], max_bytes: DIAGNOSTIC_FIELD_MAX_BYTES)
        result["workspace"] = workspace_summary(workspace)
        result["diagnostic_compaction"] = "workspace_v1"
        enforce_details_bound!(result)
      end

      def spawn_failure_diagnostic_details(details)
        result = copy_fields(details, %w[command_id command_type status command_author_id])
        result["errors"] = diagnostic_values(details["errors"], max_bytes: DIAGNOSTIC_TEXT_HEAD_BYTES)
        result["diagnostic_compaction"] = "spawn_failure_v1"
        enforce_details_bound!(result)
      end

      def head_command_diagnostic_details(details)
        commands = details.fetch("command_results")
        result = copy_fields(details, %w[head_id question_ids skipped_command_count command_author_id])
        result["command_results"] = commands.first(HEAD_COMMAND_RESULT_LIMIT).map { |entry| command_result_summary(entry) }
        omitted = commands.length - result.fetch("command_results").length
        result["omitted_command_result_count"] = omitted if omitted.positive?
        result["diagnostic_compaction"] = "head_commands_v1"
        enforce_details_bound!(result, reducible: "command_results")
      end

      def command_result_summary(entry)
        return { "message" => bounded_text(entry.to_s, DIAGNOSTIC_FIELD_MAX_BYTES) } unless entry.is_a?(Hash)

        result = copy_fields(entry, %w[command_id command_type status target_id message])
        result["message"] = bounded_text(result["message"], DIAGNOSTIC_FIELD_MAX_BYTES) if result.key?("message")
        result["errors"] = diagnostic_values(entry["errors"], max_bytes: DIAGNOSTIC_FIELD_MAX_BYTES)
        nested = entry["result"]
        if nested.is_a?(Hash)
          result["exit_status"] = nested["exit_status"] if nested.key?("exit_status")
          result["workspace_path"] = nested["workspace_path"] if nested.key?("workspace_path")
          result["recovery"] = nested["recovery"] if nested.key?("recovery")
          result["stderr"] = bounded_output(nested["stderr"]) if nested.key?("stderr")
        end
        result.compact
      end

      def workspace_summary(workspace)
        plan = workspace["plan"].is_a?(Hash) ? workspace.fetch("plan") : {}
        fields = %w[workspace_path workspace_root_path worktree_root_path workspace_strategy workspace_branch
                    git_root base_ref failure_kind exit_status timed_out timeout_seconds recovery]
        result = fields.each_with_object({}) do |field, summary|
          # A failed resolver points the worker at the project root while the nested plan
          # names the worktree that actually failed. Keep that attempted workspace path.
          source = field == "workspace_path" ? [plan, workspace] : [workspace, plan]
          owner = source.find { |candidate| candidate.key?(field) }
          summary[field] = owner[field] if owner
        end
        stderr = workspace.key?("stderr") ? workspace["stderr"] : plan["stderr"]
        stdout = workspace.key?("stdout") ? workspace["stdout"] : plan["stdout"]
        result["stderr"] = bounded_output(stderr) unless stderr.nil?
        result["stdout"] = bounded_output(stdout) unless stdout.nil?
        result.compact
      end

      def bounded_output(value)
        text = value.to_s
        return text if text.bytesize <= DIAGNOSTIC_TEXT_HEAD_BYTES + DIAGNOSTIC_TEXT_TAIL_BYTES

        {
          "head" => byteslice_utf8(text, 0, DIAGNOSTIC_TEXT_HEAD_BYTES),
          "tail" => byteslice_utf8(text, text.bytesize - DIAGNOSTIC_TEXT_TAIL_BYTES, DIAGNOSTIC_TEXT_TAIL_BYTES),
          "omitted_bytes" => text.bytesize - DIAGNOSTIC_TEXT_HEAD_BYTES - DIAGNOSTIC_TEXT_TAIL_BYTES,
          "original_bytes" => text.bytesize
        }
      end

      def diagnostic_values(values, max_bytes:)
        Array(values).first(8).map { |value| bounded_text(value.to_s, max_bytes) }
      end

      def bounded_text(value, max_bytes)
        return value if value.bytesize <= max_bytes

        head_bytes = max_bytes / 2
        tail_bytes = max_bytes - head_bytes
        {
          "head" => byteslice_utf8(value, 0, head_bytes),
          "tail" => byteslice_utf8(value, value.bytesize - tail_bytes, tail_bytes),
          "omitted_bytes" => value.bytesize - max_bytes,
          "original_bytes" => value.bytesize
        }
      end

      def byteslice_utf8(value, start, length)
        slice = value.b.byteslice([start, 0].max, length).to_s
        slice.force_encoding(Encoding::UTF_8)
        slice = slice.scrub("") unless slice.valid_encoding?
        slice
      end

      def copy_fields(source, fields)
        fields.each_with_object({}) { |field, result| result[field] = source[field] if source.key?(field) }
      end

      def enforce_details_bound!(details, reducible: nil)
        while JSON.generate(details).bytesize > DIAGNOSTIC_DETAILS_MAX_BYTES && reducible && Array(details[reducible]).any?
          details[reducible].pop
          details["omitted_command_result_count"] = details.fetch("omitted_command_result_count", 0).to_i + 1
        end
        return details if JSON.generate(details).bytesize <= DIAGNOSTIC_DETAILS_MAX_BYTES

        # Prefer one useful stderr head/tail over duplicated secondary diagnostics.
        workspace = details["workspace"]
        if workspace.is_a?(Hash)
          workspace.delete("stdout")
          %w[workspace_root_path worktree_root_path git_root base_ref].each do |key|
            break if JSON.generate(details).bytesize <= DIAGNOSTIC_DETAILS_MAX_BYTES
            workspace.delete(key)
          end
        end
        details.delete("errors") if JSON.generate(details).bytesize > DIAGNOSTIC_DETAILS_MAX_BYTES
        if JSON.generate(details).bytesize > DIAGNOSTIC_DETAILS_MAX_BYTES && workspace.is_a?(Hash) && workspace.key?("stderr")
          workspace["stderr"] = bounded_text(workspace.fetch("stderr").to_s, DIAGNOSTIC_TEXT_HEAD_BYTES)
        end
        if JSON.generate(details).bytesize > DIAGNOSTIC_DETAILS_MAX_BYTES && workspace.is_a?(Hash) && workspace["workspace_path"].is_a?(String)
          workspace["workspace_path"] = bounded_text(workspace.fetch("workspace_path"), 4_096)
        end
        details
      end

      def compact_array!(array, key)
        changed = false
        array.each_with_index do |value, index|
          if command_argument?(key, value)
            compacted = compact_command_argument(value)
            if compacted != value
              array[index] = compacted
              changed = true
            end
          else
            changed = true if compact_value!(value, key)
          end
        end
        changed
      end

      def command_argument?(key, value)
        key.to_s == "command" && value.is_a?(String)
      end

      def compact_command_argument(value)
        return value if value.bytesize <= COMMAND_ARGUMENT_MAX_BYTES
        return value if omitted_command_argument?(value)

        format(COMMAND_ARGUMENT_OMISSION, bytes: value.bytesize)
      end

      def omitted_command_argument?(value)
        /\A\[omitted \d+-byte command argument by Meringue state compaction\]\z/.match?(value)
      end
    end
  end
end
