# frozen_string_literal: true

module Meringue
  module Harness
    # Harness-neutral shape for "what is this session doing right now".
    #
    # A worker can run for tens of minutes between the line that says it was spawned and the line
    # that carries its final report. The kernel turns these items into a small number of durable
    # progress log lines so that stretch is not silent. The items themselves are deliberately
    # dumb: extraction happens inside each harness client (provider event names never leave
    # their adapter), and every item is derived from events the caller has *already* drained, so
    # producing progress never costs an extra harness round trip.
    #
    # Item shape:
    #
    #   { "kind" => "assistant_text", "text" => "The root cause is the shared drain cursor." }
    #
    # Only authored text is progress. Tool calls prove activity but cannot truthfully communicate
    # a finding, decision, or milestone on the agent's behalf. A harness with no authored update
    # returns `[]`, and Meringue simply stays quiet for that worker.
    module SessionProgress
      KINDS = %w[assistant_text].freeze
      # Progress lines are a summary, never a transcript. The kernel truncates again for the log
      # line itself; this bound only keeps a runaway message out of the poll result.
      MAX_TEXT_CHARS = 2_000

      module_function

      def assistant_text(text)
        normalized = normalize_text(text)
        return nil unless normalized

        { "kind" => "assistant_text", "text" => normalized }
      end

      def normalize_text(value)
        return nil unless value.is_a?(String) || value.is_a?(Symbol)

        text = value.to_s.gsub(/\s+/, " ").strip
        return nil if text.empty?

        text.length > MAX_TEXT_CHARS ? text[0, MAX_TEXT_CHARS] : text
      end

      # Progress for line-oriented CLI harnesses (Claude Code and anything else built on
      # `ProcessClient`). Their events are the wrapper `ManagedProcess` puts around each parsed
      # stdout record: `{"type" => ..., "timestamp" => ..., "data" => {original record}}`.
      #
      # A harness whose stdout is not JSON (Antigravity's `--print`) produces no records at all,
      # so this returns `[]` and the worker simply has no derived progress.
      def from_process_events(events)
        Array(events).flat_map { |event| from_process_event(event) }.compact
      end

      def from_process_event(event)
        return [] unless event.is_a?(Hash)

        record = event["data"].is_a?(Hash) ? event["data"] : event
        # The terminal `result` record is the session's final answer. The kernel already logs that
        # as the worker's completion output, so replaying it as progress would only duplicate it.
        return [] if record["type"].to_s == "result"

        message = record["message"].is_a?(Hash) ? record["message"] : record
        return [] unless assistant_record?(record, message)

        text = assistant_text(text_blocks(message["content"]))
        text ? [text] : []
      end

      def assistant_record?(record, message)
        return true if message["role"].to_s == "assistant"

        %w[assistant assistant_message].include?(record["type"].to_s)
      end

      def text_blocks(content)
        return content if content.is_a?(String)
        return nil unless content.is_a?(Array)

        content.filter_map do |block|
          next unless block.is_a?(Hash) && block["type"].to_s == "text"

          block["text"]
        end.join("\n")
      end

    end
  end
end
