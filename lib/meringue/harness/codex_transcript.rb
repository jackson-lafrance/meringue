# frozen_string_literal: true

require "json"

module Meringue
  module Harness
    # Translates Codex CLI rollout JSONL records into Meringue's neutral session shapes.
    # Codex's event names and payload layout stop here; the kernel only sees session state,
    # turn outcomes, authored progress, and SessionView items.
    module CodexTranscript
      LIFECYCLE_TYPES = %w[task_started task_complete turn_aborted].freeze
      MESSAGE_TYPES = %w[user_message agent_message].freeze
      TOOL_TYPES = %w[
        function_call function_call_output custom_tool_call custom_tool_call_output
        local_shell_call web_search_call image_generation_call
      ].freeze
      ACTIVITY_TYPES = (LIFECYCLE_TYPES + MESSAGE_TYPES + TOOL_TYPES + %w[message reasoning]).freeze
      MAX_CONTENT_CHARS = 12_000
      NETWORK_ERROR_PATTERN = /\b(ECONNRESET|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|socket hang up|network|fetch failed|connection (?:closed|error|reset)|timed out)\b/i.freeze
      AUTH_ERROR_PATTERN = /\b(unauthori[sz]ed|authentication|access token|refresh token|log in|sign in|401|403)\b/i.freeze
      OVERLOAD_ERROR_PATTERN = /\b(overloaded|rate.?limit|429|5\d\d|service unavailable|internal server error)\b/i.freeze

      module_function

      # ------------------------------------------------------------------- state

      def session_state(records)
        last = activity_records(records).last
        return "unknown" unless last

        type = payload_type(last)
        return "idle" if %w[task_complete turn_aborted].include?(type)

        "streaming"
      end

      def turn_outcome(records)
        lifecycle = activity_records(records).reverse_each.find { |record| LIFECYCLE_TYPES.include?(payload_type(record)) }
        return nil unless lifecycle

        payload = payload_for(lifecycle)
        type = payload_type(lifecycle)
        return nil if type == "task_started"

        if type == "turn_aborted"
          reason = present(payload["reason"]) || "Codex interrupted the turn before it produced a final answer"
          return {
            "state" => "incomplete",
            "kind" => "interrupted_turn",
            "reason" => reason,
            "stop_reason" => "turn_aborted",
            "error_message" => reason,
            "ended_at" => lifecycle["timestamp"]
          }.compact
        end

        error = error_text(payload["error"])
        unless error.empty?
          return {
            "state" => "failed",
            "kind" => error_kind(error),
            "reason" => error_reason(error),
            "stop_reason" => "task_complete_error",
            "error_message" => truncate(error, 2_000),
            "last_assistant_text" => present(payload["last_agent_message"]),
            "ended_at" => payload["completed_at"] || lifecycle["timestamp"]
          }.compact
        end

        {
          "state" => "completed",
          "stop_reason" => "task_complete",
          "last_assistant_text" => present(payload["last_agent_message"]) || final_assistant_text(records),
          "ended_at" => payload["completed_at"] || lifecycle["timestamp"]
        }.compact
      end

      def last_assistant_text(records)
        outcome = turn_outcome(records)
        return nil unless outcome && outcome["state"] == "completed"

        present(outcome["last_assistant_text"])
      end

      def session_settings(records)
        context = Array(records).reverse_each.find do |record|
          record.is_a?(Hash) && record["type"].to_s == "turn_context" && record["payload"].is_a?(Hash)
        end
        payload = context && context["payload"]
        model_id = payload && present(payload["model"])
        effort = payload && present(payload["effort"])
        model = if model_id
                  {
                    "provider" => "openai",
                    "id" => model_id,
                    "reference" => "openai/#{model_id}"
                  }
                end
        availability = if model && effort
                         "available"
                       elsif model || effort
                         "partial"
                       else
                         "unknown"
                       end
        {
          "model" => model,
          "thinking_level" => effort,
          "availability" => availability,
          "source" => context ? "codex_turn_context" : "codex",
          "note" => context ? nil : "Codex rollout does not contain effective session settings yet."
        }.compact
      end

      def user_prompt_present?(records, marker: nil, text: nil)
        needle = marker.to_s.strip
        fallback = text.to_s.strip
        return false if needle.empty? && fallback.empty?

        activity_records(records).any? do |record|
          next false unless user_record?(record)

          body = user_text(record)
          next true if !needle.empty? && body.include?(needle)

          needle.empty? && !fallback.empty? && body.include?(fallback)
        end
      end

      # ------------------------------------------------------------------ events

      def events(records)
        activity_records(records).map { |record| bounded_record(record) }
      end

      # Codex emits explicit `agent_message` events for commentary and final output. Only
      # non-final authored messages become progress; the kernel logs the final answer on settle.
      def progress(events)
        seen = {}
        Array(events).filter_map do |record|
          next unless record.is_a?(Hash)

          payload = payload_for(record)
          text = if record["type"].to_s == "event_msg" && payload["type"].to_s == "agent_message"
                   next if payload["phase"].to_s == "final_answer"

                   payload["message"]
                 elsif record["type"].to_s == "response_item" && payload["type"].to_s == "message" &&
                       payload["role"].to_s == "assistant" && payload["phase"].to_s == "commentary"
                   content_text(payload["content"])
                 end
          item = SessionProgress.assistant_text(text)
          next unless item
          next if seen[item.fetch("text")]

          seen[item.fetch("text")] = true
          item
        end
      end

      def normalize_journal_entry(entry)
        record = entry.is_a?(Hash) ? (entry["event"] || entry) : {}
        return [] unless record.is_a?(Hash)

        view_items(record).map do |item|
          item.merge(
            "sequence" => entry.is_a?(Hash) ? entry["sequence"] : nil,
            "timestamp" => item["timestamp"] || (entry.is_a?(Hash) ? entry["timestamp"] : nil),
            "harness_event_type" => payload_type(record)
          ).compact
        end
      end

      # ----------------------------------------------------------------- snapshot

      def snapshot(records:, session_ref:, harness: "codex", live: false)
        relevant = activity_records(records)
        state = session_state(relevant)
        state = "completed" if !live && state == "idle"
        items = relevant.flat_map { |record| view_items(record) }
        {
          "availability" => live ? "live" : (items.empty? ? "unavailable" : "history"),
          "session_state" => state,
          "harness" => harness.to_s,
          "session_id" => session_ref["session_id"] || session_ref[:session_id],
          "session_name" => (session_ref.fetch("metadata", {}) || {})["session_name"],
          "items" => deduplicate_items(items),
          "capabilities" => {
            "live_events" => live,
            "prompt" => live,
            "steer" => live,
            "follow_up" => live,
            "abort" => live
          },
          "warning" => live ? nil : "Showing this agent's saved Codex rollout; no live session is attached.",
          "session_file" => session_ref["session_file"] || session_ref[:session_file]
        }.compact
      end

      # ------------------------------------------------------------------ helpers

      def conversation_records(records)
        activity_records(records)
      end

      def activity_records(records)
        Array(records).select do |record|
          next false unless record.is_a?(Hash)

          type = record["type"].to_s
          payload = payload_for(record)
          case type
          when "event_msg"
            LIFECYCLE_TYPES.include?(payload["type"].to_s) || MESSAGE_TYPES.include?(payload["type"].to_s)
          when "response_item"
            ACTIVITY_TYPES.include?(payload["type"].to_s)
          else
            false
          end
        end
      end

      def view_items(record)
        payload = payload_for(record)
        timestamp = record["timestamp"] || payload["completed_at"] || payload["started_at"]
        if record["type"].to_s == "event_msg"
          case payload["type"].to_s
          when "user_message"
            return [message_item(role: "user", content: user_text(record), timestamp: timestamp)]
          when "agent_message"
            return [message_item(
              role: "assistant",
              content: payload["message"],
              timestamp: timestamp,
              phase: payload["phase"]
            )]
          end
          return []
        end

        case payload["type"].to_s
        when "message"
          return [] unless %w[user assistant].include?(payload["role"].to_s)

          [message_item(
            role: payload["role"],
            content: content_text(payload["content"]),
            timestamp: timestamp,
            phase: payload["phase"]
          )]
        when "reasoning"
          thinking = reasoning_text(payload)
          thinking.empty? ? [] : [message_item(role: "assistant", content: "", thinking: thinking, timestamp: timestamp)]
        when *TOOL_TYPES
          [tool_item(payload, timestamp: timestamp)]
        else
          []
        end
      end

      def message_item(role:, content:, timestamp:, phase: nil, thinking: nil)
        {
          "kind" => "message",
          "role" => role.to_s,
          "content" => truncate(content.to_s, MAX_CONTENT_CHARS),
          "thinking" => present(thinking),
          "timestamp" => timestamp,
          "entry_type" => "message",
          "phase" => present(phase) || "complete"
        }.compact
      end

      def tool_item(payload, timestamp:)
        type = payload["type"].to_s
        output = payload["output"] || payload["result"] || payload["aggregated_output"]
        input = payload["arguments"] || payload["input"] || payload["command"]
        {
          "kind" => "tool",
          "role" => "tool",
          "content" => truncate(output || input || type, MAX_CONTENT_CHARS),
          "tool_call_id" => payload["call_id"] || payload["id"],
          "tool_name" => payload["name"] || type,
          "is_error" => payload["is_error"] == true || nil,
          "timestamp" => timestamp,
          "entry_type" => type,
          "phase" => "complete"
        }.compact
      end

      def final_assistant_text(records)
        activity_records(records).reverse_each do |record|
          payload = payload_for(record)
          if record["type"].to_s == "event_msg" && payload["type"].to_s == "agent_message"
            text = present(payload["message"])
            return text if text && (payload["phase"].to_s.empty? || payload["phase"].to_s == "final_answer")
          end
          if record["type"].to_s == "response_item" && payload["type"].to_s == "message" &&
             payload["role"].to_s == "assistant"
            text = present(content_text(payload["content"]))
            return text if text && (payload["phase"].to_s.empty? || payload["phase"].to_s == "final_answer")
          end
        end
        nil
      end

      def user_record?(record)
        payload = payload_for(record)
        (record["type"].to_s == "event_msg" && payload["type"].to_s == "user_message") ||
          (record["type"].to_s == "response_item" && payload["type"].to_s == "message" && payload["role"].to_s == "user")
      end

      def user_text(record)
        payload = payload_for(record)
        return payload["message"].to_s if payload["type"].to_s == "user_message"

        content_text(payload["content"])
      end

      def payload_for(record)
        payload = record.is_a?(Hash) ? record["payload"] : nil
        payload.is_a?(Hash) ? payload : {}
      end

      def payload_type(record)
        payload_for(record)["type"].to_s
      end

      def content_text(content)
        return content.to_s if content.is_a?(String)

        Array(content).filter_map do |part|
          next unless part.is_a?(Hash)

          part["text"] || part["output_text"] || part["input_text"]
        end.join("\n")
      end

      def reasoning_text(payload)
        values = Array(payload["summary"]) + Array(payload["content"])
        values.filter_map do |part|
          part.is_a?(Hash) ? (part["text"] || part["summary_text"] || part["reasoning_text"]) : part
        end.join("\n")
      end

      def bounded_record(record)
        generated = JSON.generate(record)
        return record if generated.bytesize <= MAX_CONTENT_CHARS

        {
          "timestamp" => record["timestamp"],
          "type" => record["type"],
          "payload" => {
            "type" => payload_type(record),
            "message" => truncate(payload_for(record)["message"], MAX_CONTENT_CHARS),
            "truncated" => true
          }.compact
        }.compact
      rescue StandardError
        record
      end

      # Codex can persist the same authored message as a response_item and an event_msg next to
      # each other. Collapse only that adjacent representation pair: the agent may legitimately
      # repeat the same text in a later turn, and global content deduplication would hide it.
      def deduplicate_items(items)
        last_message_key = nil
        Array(items).reject do |item|
          unless item["kind"] == "message"
            last_message_key = nil
            next false
          end

          key = [item["role"], item["content"], item["thinking"], item["phase"]]
          duplicate = key == last_message_key
          last_message_key = key
          duplicate
        end
      end

      def error_text(error)
        case error
        when Hash
          present(error["message"]) || JSON.generate(error)
        when nil
          ""
        else
          error.to_s.strip
        end.to_s
      rescue StandardError
        error.to_s
      end

      def error_kind(message)
        return "authentication_failure" if message.match?(AUTH_ERROR_PATTERN)
        return "network_failure" if message.match?(NETWORK_ERROR_PATTERN)
        return "provider_error" if message.match?(OVERLOAD_ERROR_PATTERN)

        "provider_error"
      end

      def error_reason(message)
        text = truncate(message.to_s.gsub(/\s+/, " ").strip, 240)
        return "Codex reported an error and the turn ended without an answer" if text.empty?

        "Codex ended the turn with an error: #{text}"
      end

      def present(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def truncate(value, limit)
        text = value.to_s
        return text if text.length <= limit

        "#{text[0, limit]}…[truncated]"
      end
    end
  end
end
