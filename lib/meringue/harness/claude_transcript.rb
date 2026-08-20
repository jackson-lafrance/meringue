# frozen_string_literal: true

require "json"
require "time"

module Meringue
  module Harness
    # Reads Claude Code's durable session transcript into the harness-neutral shapes the rest of
    # Meringue speaks.
    #
    # Claude Code writes one JSONL file per session while it runs, whether it was started for a
    # single print invocation or as a full interactive session. That file is the authority on what
    # the agent did: it carries the assistant messages, their stop reasons, and the tool traffic
    # between them. Meringue reads state from here rather than from the interactive screen, because
    # the screen is a TUI layout that may change with any release while the transcript is a
    # structured record.
    #
    # Claude Code names and record types stop at this boundary. Callers above it only ever see
    # SessionView items, SessionProgress items, and the neutral turn-outcome contract.
    module ClaudeTranscript
      MESSAGE_TYPES = %w[user assistant].freeze
      MAX_TOOL_CONTENT_CHARS = 12_000
      # A stop reason that is not a finished answer. Anything else settles the turn.
      IN_FLIGHT_STOP_REASONS = %w[tool_use].freeze
      # Stop reasons that end a turn without a complete answer, so the kernel settles the worker as
      # errored rather than silently accepting a truncated result as its report.
      INCOMPLETE_STOP_REASONS = %w[max_tokens model_context_window_exceeded pause_turn].freeze
      NETWORK_ERROR_PATTERN = /\b(ECONNRESET|ENOTFOUND|ETIMEDOUT|EAI_AGAIN|socket hang up|network|fetch failed|connection (?:closed|error|reset)|timed out)\b/i.freeze
      OVERLOAD_ERROR_PATTERN = /\b(overloaded|rate.?limit|429|5\d\d|service unavailable|internal server error)\b/i.freeze

      module_function

      # ------------------------------------------------------------------- state

      # The turn-level state of the session, read from its own records.
      #
      # A turn is still running whenever the newest conversation record is anything other than a
      # finished assistant message: an assistant message that stopped to call a tool, or a user
      # record carrying a prompt or a tool result the agent has not answered yet.
      def session_state(records)
        conversation = conversation_records(records)
        return "unknown" if conversation.empty?

        last = conversation.last
        return "streaming" unless last.fetch("type", nil).to_s == "assistant"
        return "streaming" if IN_FLIGHT_STOP_REASONS.include?(stop_reason(last))
        return "errored" if error_record?(last)

        "idle"
      end

      # Neutral outcome of the most recent turn. Returning nil means "no evidence", which leaves
      # the kernel's own event-based classification in charge.
      def turn_outcome(records)
        last = conversation_records(records).reverse_each.find { |record| record.fetch("type", nil).to_s == "assistant" }
        return nil unless last

        reason = stop_reason(last)
        ended_at = last["timestamp"]
        text = message_text(last.fetch("message", {}))

        if error_record?(last)
          error_message = text.to_s.strip
          {
            "state" => "failed",
            "kind" => error_kind(error_message),
            "reason" => error_reason(error_message),
            "stop_reason" => reason,
            "error_message" => truncate(error_message, 2_000),
            "ended_at" => ended_at
          }.compact
        elsif IN_FLIGHT_STOP_REASONS.include?(reason)
          {
            "state" => "incomplete",
            "kind" => "interrupted_tool_call",
            "reason" => "the turn ended while a tool call was still outstanding",
            "stop_reason" => reason,
            "ended_at" => ended_at
          }.compact
        elsif INCOMPLETE_STOP_REASONS.include?(reason)
          {
            "state" => "incomplete",
            "kind" => "truncated_turn",
            "reason" => "the turn stopped early (#{reason}) without a complete answer",
            "stop_reason" => reason,
            "ended_at" => ended_at
          }.compact
        else
          {
            "state" => "completed",
            "stop_reason" => reason,
            "last_assistant_text" => truncate(text, 2_000),
            "ended_at" => ended_at
          }.compact
        end
      end

      def last_assistant_text(records)
        record = conversation_records(records).reverse_each.find do |candidate|
          candidate.fetch("type", nil).to_s == "assistant" &&
            !IN_FLIGHT_STOP_REASONS.include?(stop_reason(candidate)) &&
            !error_record?(candidate)
        end
        return nil unless record

        text = message_text(record.fetch("message", {}))
        text.to_s.strip.empty? ? nil : text
      end

      # Proof that a prompt Meringue typed actually reached the session. The marker is matched
      # first because it is exact; the raw text is a fallback for a prompt sent without one.
      def user_prompt_present?(records, marker: nil, text: nil)
        needle = marker.to_s.strip
        fallback = text.to_s.strip
        return false if needle.empty? && fallback.empty?

        conversation_records(records).any? do |record|
          next false unless record.fetch("type", nil).to_s == "user"

          body = message_text(record.fetch("message", {})).to_s
          next true if !needle.empty? && body.include?(needle)

          !fallback.empty? && needle.empty? && body.include?(fallback)
        end
      end

      # ------------------------------------------------------------------ events

      # Conversation records pass through with their own shape intact. They already carry `type`
      # and `message` with a `stop_reason`, which is exactly what the kernel's settle-failure
      # classification and SessionProgress both read, so no translation layer is needed and none
      # is invented. Only oversized tool payloads are trimmed, to keep one chatty turn from
      # dragging megabytes through the poll path.
      def events(records)
        conversation_records(records).map { |record| bounded_event(record) }
      end

      def progress(events)
        SessionProgress.from_process_events(events)
      end

      def normalize_journal_entry(entry)
        event = entry.is_a?(Hash) ? (entry["event"] || entry) : {}
        return [] unless event.is_a?(Hash)

        [
          {
            "sequence" => entry.is_a?(Hash) ? entry["sequence"] : nil,
            "timestamp" => event["timestamp"] || (entry.is_a?(Hash) ? entry["timestamp"] : nil),
            "harness_event_type" => event["type"],
            "kind" => event.fetch("type", nil).to_s == "assistant" ? "message" : "tool",
            "role" => event.dig("message", "role"),
            "content" => truncate(message_text(event.fetch("message", {})), MAX_TOOL_CONTENT_CHARS),
            "stop_reason" => stop_reason(event)
          }.compact
        ]
      end

      # ----------------------------------------------------------------- snapshot

      def snapshot(records:, session_ref:, harness: "claude", live: false)
        conversation = conversation_records(records)
        state = session_state(records)
        state = "completed" if !live && state == "idle"
        {
          "availability" => live ? "live" : (conversation.empty? ? "unavailable" : "history"),
          "session_state" => state,
          "harness" => harness.to_s,
          "session_id" => session_ref["session_id"] || session_ref[:session_id],
          "session_name" => session_name(records) || (session_ref.fetch("metadata", {}) || {})["session_name"],
          "items" => conversation.flat_map { |record| view_items(record) },
          "capabilities" => {
            "live_events" => live,
            "prompt" => live,
            "steer" => live,
            "follow_up" => live,
            "abort" => live
          },
          "warning" => live ? nil : "Showing this agent's saved transcript; no live session is attached.",
          "session_file" => session_ref["session_file"] || session_ref[:session_file]
        }.compact
      end

      # ------------------------------------------------------------------ helpers

      # The records that make up the conversation proper.
      #
      # Sidechain records are a subagent's own conversation. They are excluded because the parent
      # session's turn is not finished just because a subagent's was, and a subagent's answer is
      # not the worker's report.
      def conversation_records(records)
        Array(records).select do |record|
          next false unless record.is_a?(Hash)
          next false unless MESSAGE_TYPES.include?(record.fetch("type", nil).to_s)
          next false unless record["message"].is_a?(Hash)
          next false if record["isSidechain"] == true
          next false if record["isMeta"] == true

          true
        end
      end

      def view_items(record)
        message = record.fetch("message", {})
        role = message.fetch("role", "unknown").to_s
        blocks = content_blocks(message)
        text = block_text(blocks)
        thinking = block_thinking(blocks)
        tool_calls = block_tool_calls(blocks)
        tool_results = block_tool_results(blocks)
        items = []

        unless text.strip.empty? && thinking.strip.empty? && tool_calls.empty?
          items << {
            "id" => record["uuid"],
            "kind" => "message",
            "role" => role,
            "content" => text,
            "thinking" => thinking.strip.empty? ? nil : thinking,
            "tool_calls" => tool_calls.empty? ? nil : tool_calls,
            "is_error" => error_record?(record) || nil,
            "stop_reason" => stop_reason(record),
            "timestamp" => record["timestamp"],
            "entry_type" => "message",
            "phase" => "complete"
          }.compact
        end

        tool_results.each_with_index do |result, index|
          items << {
            "id" => "#{record["uuid"]}-tool-#{index}",
            "kind" => "tool",
            "role" => "tool",
            "content" => truncate(result.fetch("text"), MAX_TOOL_CONTENT_CHARS),
            "tool_call_id" => result.fetch("tool_use_id", nil),
            "is_error" => result.fetch("is_error", false) || nil,
            "timestamp" => record["timestamp"],
            "entry_type" => "tool_result",
            "phase" => "complete"
          }.compact
        end
        items
      end

      def session_name(records)
        title = Array(records).reverse_each.find { |record| record.is_a?(Hash) && record["aiTitle"] }
        title && title["aiTitle"].to_s
      end

      def bounded_event(record)
        message = record.fetch("message", {})
        blocks = content_blocks(message)
        return record if blocks.none? { |block| oversized_block?(block) }

        record.merge(
          "message" => message.merge(
            "content" => blocks.map { |block| oversized_block?(block) ? bounded_block(block) : block }
          )
        )
      end

      def oversized_block?(block)
        return false unless block.is_a?(Hash)

        JSON.generate(block).bytesize > MAX_TOOL_CONTENT_CHARS
      rescue StandardError
        false
      end

      def bounded_block(block)
        case block.fetch("type", nil).to_s
        when "tool_result"
          block.merge("content" => truncate(tool_result_text(block), MAX_TOOL_CONTENT_CHARS))
        when "tool_use"
          block.merge("input" => { "truncated" => truncate(JSON.generate(block["input"]), MAX_TOOL_CONTENT_CHARS) })
        when "text", "thinking"
          key = block.fetch("type").to_s == "text" ? "text" : "thinking"
          block.merge(key => truncate(block[key].to_s, MAX_TOOL_CONTENT_CHARS))
        else
          block
        end
      rescue StandardError
        block
      end

      def content_blocks(message)
        return [] unless message.is_a?(Hash)

        content = message["content"]
        return [{ "type" => "text", "text" => content }] if content.is_a?(String)

        Array(content).select { |block| block.is_a?(Hash) }
      end

      def message_text(message)
        block_text(content_blocks(message))
      end

      def block_text(blocks)
        blocks.filter_map do |block|
          case block.fetch("type", nil).to_s
          when "text" then block["text"]
          when "image" then "[image]"
          end
        end.join("\n")
      end

      def block_thinking(blocks)
        blocks.filter_map { |block| block["thinking"] if block.fetch("type", nil).to_s == "thinking" }.join("\n")
      end

      def block_tool_calls(blocks)
        blocks.filter_map do |block|
          next unless block.fetch("type", nil).to_s == "tool_use"

          { "id" => block["id"], "name" => block["name"], "arguments" => block["input"] }.compact
        end
      end

      def block_tool_results(blocks)
        blocks.filter_map do |block|
          next unless block.fetch("type", nil).to_s == "tool_result"

          {
            "text" => tool_result_text(block),
            "tool_use_id" => block["tool_use_id"],
            "is_error" => !!block["is_error"]
          }
        end
      end

      def tool_result_text(block)
        content = block["content"]
        return content.to_s if content.is_a?(String)

        Array(content).filter_map do |part|
          part["text"] if part.is_a?(Hash) && part.fetch("type", nil).to_s == "text"
        end.join("\n")
      end

      def stop_reason(record)
        return nil unless record.is_a?(Hash)

        (record.dig("message", "stop_reason") || record["stop_reason"]).to_s.empty? ? nil : (record.dig("message", "stop_reason") || record["stop_reason"]).to_s
      end

      def error_record?(record)
        return false unless record.is_a?(Hash)

        record["isApiErrorMessage"] == true
      end

      def error_kind(message)
        return "network_failure" if message.to_s.match?(NETWORK_ERROR_PATTERN)
        return "provider_error" if message.to_s.match?(OVERLOAD_ERROR_PATTERN)

        "provider_error"
      end

      def error_reason(message)
        text = message.to_s.strip.gsub(/\s+/, " ")
        return "the agent reported a provider error and the turn ended without an answer" if text.empty?

        "the agent's turn ended with a provider error: #{truncate(text, 240)}"
      end

      def truncate(value, limit)
        text = value.to_s
        return text if text.length <= limit

        "#{text[0, limit]}…[truncated]"
      end
    end
  end
end
