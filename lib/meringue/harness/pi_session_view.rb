# frozen_string_literal: true

require "json"
require "time"

module Meringue
  module Harness
    # Converts Pi RPC/session-file records into the generic SessionView contract.
    # Pi event names and message shapes intentionally stop at this boundary.
    module PiSessionView
      MAX_TOOL_CONTENT_CHARS = 12_000

      module_function

      def live_snapshot(pi_state:, messages: nil, entries: nil, leaf_id: nil, session_ref:)
        items = if entries
                  normalize_records(entries, leaf_id: leaf_id)
                else
                  normalize_messages(messages)
                end
        {
          "availability" => "live",
          "session_state" => pi_state.fetch("isStreaming", false) ? "streaming" : "idle",
          "harness" => "pi",
          "session_id" => pi_state["sessionId"] || session_ref["session_id"],
          "session_name" => pi_state["sessionName"] || metadata_value(session_ref, "session_name"),
          "items" => items,
          "capabilities" => capabilities(live: true, prompt: true),
          "warning" => nil
        }
      end

      def history_snapshot(session_ref:, process_alive: false)
        path = session_file_path(session_ref)
        unless path && File.file?(path)
          return SessionView.unavailable_snapshot(
            harness: "pi",
            availability: "unavailable",
            message: "Saved agent session history is unavailable#{path ? ": #{path}" : "."}"
          )
        end

        records = File.foreach(path).filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
        header = records.find { |record| record["type"] == "session" } || {}
        session_id = session_ref["session_id"] || session_ref[:session_id] || header["id"]
        session_name = records.reverse_each.find { |record| record["type"] == "session_info" && record["name"] }&.fetch("name", nil) ||
          metadata_value(session_ref, "session_name")
        messages = normalize_records(records)
        last_message = messages.reverse_each.find { |item| item["role"] == "assistant" } || {}
        completed = completed_stop_reason?(last_message["stop_reason"])
        availability = process_alive ? "history_follow" : "history"
        warning = if process_alive
                    "The agent process is still running, but this Meringue instance does not own its RPC transport. Showing persisted history without attaching a second process."
                  end
        {
          "availability" => availability,
          "session_state" => completed ? "completed" : (process_alive ? "streaming" : "idle"),
          "harness" => "pi",
          "session_id" => session_id,
          "session_name" => session_name,
          "items" => messages.compact,
          "capabilities" => capabilities(live: false, prompt: !process_alive),
          "warning" => warning,
          "session_file" => path
        }
      rescue SystemCallError => e
        SessionView.unavailable_snapshot(
          harness: "pi",
          availability: "unavailable",
          message: "Saved agent session history could not be read: #{e.message}"
        )
      end

      def active_session_records(records, leaf_id: nil)
        entries = records.select { |record| record["id"] }
        leaf = leaf_id && entries.find { |record| record["id"].to_s == leaf_id.to_s }
        leaf ||= entries.last
        return [] unless leaf

        by_id = entries.to_h { |record| [record["id"], record] }
        active_ids = {}
        current = leaf
        while current
          active_ids[current["id"]] = true
          current = by_id[current["parentId"]]
        end
        entries.select { |record| active_ids[record["id"]] }
      end

      def normalize_event(entry)
        event = entry.fetch("event", {}) || {}
        sequence = entry.fetch("sequence", nil)
        timestamp = entry.fetch("timestamp", nil)
        type = event.fetch("type", "event").to_s
        base = { "sequence" => sequence, "timestamp" => timestamp, "harness_event_type" => type }

        case type
        when "agent_start"
          [base.merge("kind" => "lifecycle", "phase" => "streaming")]
        when "agent_end"
          [base.merge("kind" => "lifecycle", "phase" => "turn_complete", "will_retry" => !!event["willRetry"])]
        when "agent_settled"
          [base.merge("kind" => "lifecycle", "phase" => "settled")]
        when "turn_start"
          [base.merge("kind" => "lifecycle", "phase" => "turn_start")]
        when "turn_end"
          [base.merge("kind" => "lifecycle", "phase" => "turn_end")]
        when "message_start", "message_update", "message_end"
          message_event(base, event, type)
        when "tool_execution_start", "tool_execution_update", "tool_execution_end"
          [tool_event(base, event, type)]
        when "bash_execution_update"
          [base.merge("kind" => "tool", "phase" => "update", "id" => event["id"], "tool_name" => "bash", "content" => truncate_tool_content(event["delta"]))]
        when "queue_update"
          [base.merge("kind" => "queue", "phase" => "update", "steering" => Array(event["steering"]), "follow_up" => Array(event["followUp"]))]
        when "compaction_start", "compaction_end"
          [base.merge("kind" => "notice", "phase" => type.delete_prefix("compaction_"), "notice_type" => "compaction", "reason" => event["reason"], "error" => event["errorMessage"])]
        when "auto_retry_start", "auto_retry_end", "summarization_retry_scheduled", "summarization_retry_attempt_start", "summarization_retry_finished"
          [base.merge(
            "kind" => "notice",
            "phase" => type,
            "notice_type" => "retry",
            "message" => event["errorMessage"] || event["finalError"] || event["reason"] || event["message"],
            "details" => compact_event(event)
          )]
        when "extension_ui_request"
          # Fire-and-forget UI calls (setWidget, setStatus, notify, setTitle) are cosmetic in a
          # managed view; only a dialog that waits for an answer is worth a row.
          return [] unless HumanInput.blocking_extension_ui_request?(event)

          [base.merge(
            "kind" => "interaction_request",
            "phase" => "unsupported",
            "message" => "Pi requested extension UI input that is not available in the managed worker view.",
            "request_type" => event["method"] || event["requestType"] || event["type"],
            "details" => compact_event(event)
          )]
        when "extension_error", "rpc_parse_error", "process_exit"
          [base.merge("kind" => "transport", "phase" => type == "process_exit" ? "closed" : "error", "message" => event["error"] || event["message"], "details" => compact_event(event))]
        else
          []
        end
      end

      # Mid-work progress items for the main Meringue log, derived from raw Pi RPC events the
      # kernel already drained. Only `message_end` carries usable semantic progress: the complete
      # assistant-authored text emitted before its tool calls execute. Raw tool events prove
      # activity but cannot explain a finding, decision, or milestone, so they stay out of the
      # progress path. Everything else is either noise (`message_update` fires per token) or
      # already handled as a lifecycle/harness event by the kernel.
      def progress_items(events)
        Array(events).flat_map { |event| progress_items_for_event(event) }.compact
      end

      def progress_items_for_event(event)
        return [] unless event.is_a?(Hash)

        return [] unless event["type"].to_s == "message_end"

        message = event["message"].is_a?(Hash) ? event["message"] : {}
        return [] unless message["role"].to_s == "assistant"

        item = SessionProgress.assistant_text(message_content(message).fetch("text"))
        item ? [item] : []
      end

      # Pi's durable session is an append-only tree, not a flat message list. Keep the active
      # branch (the same branch InteractiveMode would show), but retain the control and extension
      # entries that explain compaction, branch changes, and model/thinking changes in that view.
      # Hidden custom entries remain hidden because their renderer belongs to the extension that
      # created them; displaying their opaque state would be less faithful than omitting it.
      def normalize_records(records, leaf_id: nil)
        active_session_records(Array(records), leaf_id: leaf_id).flat_map do |record|
          normalize_record(record)
        end
      end

      def normalize_messages(messages)
        Array(messages).filter_map.with_index do |message, index|
          normalize_message(message, id: message["id"] || "message-#{index}") if message.is_a?(Hash)
        end
      end

      def normalize_record(record)
        return [] unless record.is_a?(Hash)

        case record.fetch("type", nil).to_s
        when "message"
          message = record["message"]
          message.is_a?(Hash) ? [normalize_message(message, id: record["id"], timestamp: record["timestamp"]).merge("entry_type" => "message")] : []
        when "compaction"
          [control_item(record, "compaction", "Context compacted", record["summary"],
                        extra: { "tokens_before" => record["tokensBefore"] || record["tokens_before"] })]
        when "branch_summary"
          [control_item(record, "branch_summary", "Branch summary", record["summary"],
                        extra: { "from_id" => record["fromId"] || record["from_id"] })]
        when "model_change"
          provider = record["provider"].to_s
          model = record["modelId"] || record["model_id"]
          value = [provider, model].reject { |part| part.to_s.empty? }.join("/")
          [control_item(record, "model_change", "Model changed", value)]
        when "thinking_level_change"
          [control_item(record, "thinking_level_change", "Thinking level changed", record["thinkingLevel"] || record["thinking_level"])]
        when "custom_message"
          return [] unless record.fetch("display", true)

          message = {
            "role" => "custom",
            "content" => record["content"],
            "customType" => record["customType"]
          }
          [normalize_message(message, id: record["id"], timestamp: record["timestamp"]).merge(
            "entry_type" => "custom_message",
            "custom_type" => record["customType"]
          ).compact]
        else
          []
        end
      end

      def control_item(record, entry_type, heading, value, extra: {})
        text = value.to_s.strip
        text = heading if text.empty?
        {
          "id" => record["id"],
          "kind" => "notice",
          "role" => "system",
          "content" => text.empty? ? heading : "#{heading}: #{text}",
          "entry_type" => entry_type,
          "notice_type" => entry_type,
          "timestamp" => record["timestamp"]
        }.merge(extra).compact
      end

      def normalize_message(message, id:, timestamp: nil)
        role = message.fetch("role", "unknown").to_s
        content = message_content(message)
        content["text"] = truncate_tool_content(content.fetch("text")) if role == "toolResult"
        {
          "id" => id.nil? ? message_identity(message) : id.to_s,
          "kind" => role == "toolResult" ? "tool" : "message",
          "role" => normalize_role(role),
          "content" => content.fetch("text"),
          "thinking" => content.fetch("thinking"),
          "tool_calls" => content.fetch("tool_calls"),
          "tool_name" => message["toolName"],
          "tool_call_id" => message["toolCallId"],
          "is_error" => !!message["isError"] || %w[error aborted].include?(message["stopReason"]),
          "stop_reason" => message["stopReason"],
          "error_message" => message["errorMessage"] || message["error"],
          "timestamp" => timestamp || normalize_timestamp(message["timestamp"]),
          "phase" => "complete"
        }.compact
      end

      def message_event(base, event, type)
        message = event["message"].is_a?(Hash) ? event["message"] : {}
        delta = event.fetch("assistantMessageEvent", {}) || {}
        delta = {} unless delta.is_a?(Hash)
        phase = { "message_start" => "start", "message_update" => "update", "message_end" => "end" }.fetch(type)
        delta_type = delta["type"].to_s
        tool_call = delta["toolCall"].is_a?(Hash) ? delta["toolCall"] : {}
        tool_call = message_content(message).fetch("tool_calls", []).last || {} if tool_call.empty? && delta_type.start_with?("toolcall_")
        # RPC events do not carry a separate event id. Pi's partial message timestamp is stable
        # across updates in practice; a tool-call id is the next-best stable identity for an
        # argument stream. The journal sequence is only the final fallback. Never use object_id:
        # reopening a view must not turn one streamed response into duplicate message blocks.
        partial_timestamp = delta["partial"].is_a?(Hash) ? delta["partial"]["timestamp"] : nil
        message_id = event["messageId"] || message["id"] || message["timestamp"] || partial_timestamp || tool_call["id"] || base["sequence"]
        normalized = normalize_message(message, id: message_id)
        [base.merge(normalized).merge(
          "phase" => phase,
          "delta" => delta["delta"],
          "delta_type" => delta_type.empty? ? nil : delta_type,
          "tool_call_id" => tool_call["id"],
          "tool_name" => tool_call["name"],
          "tool_arguments" => tool_call["arguments"]
        ).compact]
      end

      def tool_event(base, event, type)
        phase = { "tool_execution_start" => "start", "tool_execution_update" => "update", "tool_execution_end" => "end" }.fetch(type)
        result = event["partialResult"] || event["result"]
        base.merge(
          "kind" => "tool",
          "phase" => phase,
          "id" => event["toolCallId"],
          "tool_name" => event["toolName"],
          "arguments" => event["args"],
          "content" => result_text(result),
          "is_error" => !!event["isError"]
        ).compact
      end

      def message_content(message)
        if message.fetch("role", nil).to_s == "bashExecution"
          command = message.fetch("command", "").to_s
          output = message.fetch("output", "").to_s
          status = message.fetch("exitCode", nil)
          heading = command.empty? ? "direct bash" : "$ #{command}"
          heading += " (exit #{status})" unless status.nil?
          return { "text" => truncate_tool_content([heading, output].reject(&:empty?).join("\n")), "thinking" => "", "tool_calls" => [] }
        end

        blocks = message["content"]
        blocks = [{ "type" => "text", "text" => blocks }] if blocks.is_a?(String)
        blocks = Array(blocks)
        {
          "text" => blocks.filter_map do |part|
            next unless part.is_a?(Hash)

            if part["type"] == "text"
              part["text"]
            elsif part["type"] == "image"
              mime = part["mimeType"].to_s
              mime.empty? ? "[image]" : "[image #{mime}]"
            end
          end.join("\n"),
          "thinking" => blocks.filter_map { |part| part["thinking"] if part.is_a?(Hash) && part["type"] == "thinking" }.join("\n"),
          "tool_calls" => blocks.filter_map do |part|
            next unless part.is_a?(Hash) && part["type"] == "toolCall"

            { "id" => part["id"], "name" => part["name"], "arguments" => part["arguments"] }.compact
          end
        }
      end

      def result_text(result)
        text = if result.is_a?(String)
                 result
               elsif result.is_a?(Hash)
                 Array(result["content"]).filter_map do |part|
                   part["text"] if part.is_a?(Hash) && part["type"] == "text"
                 end.join("\n")
               end
        truncate_tool_content(text)
      end

      def truncate_tool_content(text)
        value = text.to_s
        return value if value.length <= MAX_TOOL_CONTENT_CHARS

        head_length = MAX_TOOL_CONTENT_CHARS / 2
        tail_length = MAX_TOOL_CONTENT_CHARS - head_length
        "#{value[0, head_length]}\n… tool output truncated …\n#{value[-tail_length, tail_length]}"
      end

      def capabilities(live:, prompt:)
        {
          "live_events" => live,
          "prompt" => prompt,
          "steer" => live,
          "follow_up" => live,
          "abort" => live
        }
      end

      def normalize_role(role)
        { "toolResult" => "tool", "bashExecution" => "tool" }.fetch(role, role)
      end

      def message_identity(message, fallback: nil)
        role = message.fetch("role", "message")
        timestamp = message["timestamp"]
        return "#{role}-#{timestamp}" unless timestamp.to_s.empty?

        tool_call_id = message["toolCallId"]
        return "#{role}-#{tool_call_id}" unless tool_call_id.to_s.empty?

        fallback || role.to_s
      end

      def normalize_timestamp(value)
        return nil unless value
        return Time.at(value.to_f / 1000).utc.iso8601(3) if value.is_a?(Numeric)

        value.to_s
      rescue ArgumentError, RangeError
        nil
      end

      def completed_stop_reason?(reason)
        !reason.to_s.empty? && reason.to_s != "toolUse"
      end

      def metadata_value(session_ref, key)
        metadata = session_ref["metadata"] || session_ref[:metadata] || {}
        metadata[key] || metadata[key.to_sym]
      end

      def session_file_path(session_ref)
        value = session_ref["session_file"] || session_ref[:session_file]
        value && File.expand_path(value.to_s)
      end

      def compact_event(event)
        event.reject { |key, _value| %w[messages message result partialResult].include?(key) }
      end
    end
  end
end
