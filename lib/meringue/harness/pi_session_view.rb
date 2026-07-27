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

      def live_snapshot(pi_state:, messages:, session_ref:)
        {
          "availability" => "live",
          "session_state" => pi_state.fetch("isStreaming", false) ? "streaming" : "idle",
          "harness" => "pi",
          "session_id" => pi_state["sessionId"] || session_ref["session_id"],
          "session_name" => pi_state["sessionName"] || metadata_value(session_ref, "session_name"),
          "items" => normalize_messages(messages),
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
            message: "Saved Pi session history is unavailable#{path ? ": #{path}" : "."}"
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
        messages = active_session_records(records).filter_map do |record|
          next unless record["type"] == "message" && record["message"].is_a?(Hash)

          normalize_message(record.fetch("message"), id: record["id"], timestamp: record["timestamp"])
        end
        last_message = messages.last || {}
        completed = last_message["role"] == "assistant" && completed_stop_reason?(last_message["stop_reason"])
        availability = process_alive ? "history_follow" : "history"
        warning = if process_alive
                    "The Pi process is still running, but this Meringue instance does not own its RPC transport. Showing persisted history without attaching a second process."
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
          message: "Saved Pi session history could not be read: #{e.message}"
        )
      end

      def active_session_records(records)
        entries = records.select { |record| record["id"] }
        leaf = entries.last
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
        when "message_start", "message_update", "message_end"
          message_event(base, event, type)
        when "tool_execution_start", "tool_execution_update", "tool_execution_end"
          [tool_event(base, event, type)]
        when "queue_update"
          [base.merge("kind" => "queue", "phase" => "update", "steering" => Array(event["steering"]), "follow_up" => Array(event["followUp"]))]
        when "compaction_start", "compaction_end"
          [base.merge("kind" => "notice", "phase" => type.delete_prefix("compaction_"), "notice_type" => "compaction", "reason" => event["reason"], "error" => event["errorMessage"])]
        when "auto_retry_start", "auto_retry_end", "summarization_retry_scheduled", "summarization_retry_attempt_start", "summarization_retry_finished"
          [base.merge("kind" => "notice", "phase" => type, "notice_type" => "retry", "message" => event["errorMessage"] || event["finalError"])]
        when "extension_ui_request"
          [base.merge("kind" => "interaction_request", "phase" => "unsupported", "message" => "Pi requested extension UI input that is not available in the managed worker view.")]
        when "extension_error", "rpc_parse_error", "process_exit"
          [base.merge("kind" => "transport", "phase" => type == "process_exit" ? "closed" : "error", "message" => event["error"], "details" => compact_event(event))]
        else
          []
        end
      end

      def normalize_messages(messages)
        Array(messages).filter_map.with_index do |message, index|
          normalize_message(message, id: message["id"] || "message-#{index}") if message.is_a?(Hash)
        end
      end

      def normalize_message(message, id:, timestamp: nil)
        role = message.fetch("role", "unknown").to_s
        content = message_content(message)
        content["text"] = truncate_tool_content(content.fetch("text")) if role == "toolResult"
        {
          "id" => id || message_identity(message),
          "kind" => role == "toolResult" ? "tool" : "message",
          "role" => normalize_role(role),
          "content" => content.fetch("text"),
          "thinking" => content.fetch("thinking"),
          "tool_calls" => content.fetch("tool_calls"),
          "tool_name" => message["toolName"],
          "tool_call_id" => message["toolCallId"],
          "is_error" => !!message["isError"] || message["stopReason"] == "error",
          "stop_reason" => message["stopReason"],
          "timestamp" => timestamp || normalize_timestamp(message["timestamp"]),
          "phase" => "complete"
        }.compact
      end

      def message_event(base, event, type)
        message = event["message"].is_a?(Hash) ? event["message"] : {}
        normalized = normalize_message(message, id: message_identity(message))
        phase = { "message_start" => "start", "message_update" => "update", "message_end" => "end" }.fetch(type)
        delta = event.fetch("assistantMessageEvent", {}) || {}
        [base.merge(normalized).merge(
          "phase" => phase,
          "delta" => delta["delta"],
          "delta_type" => delta["type"]
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
        blocks = message["content"]
        blocks = [{ "type" => "text", "text" => blocks }] if blocks.is_a?(String)
        blocks = Array(blocks)
        {
          "text" => blocks.filter_map { |part| part["text"] if part.is_a?(Hash) && part["type"] == "text" }.join("\n"),
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

      def message_identity(message)
        role = message.fetch("role", "message")
        timestamp = message["timestamp"]
        "#{role}-#{timestamp || message.object_id}"
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
