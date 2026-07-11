# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    module Panes
      class LogPane
        LEVEL_LABELS = {
          "info" => "INFO",
          "warning" => "WARN",
          "error" => "ERR "
        }.freeze

        def render(state)
          lines(state).join("\n")
        end

        def lines(state)
          logs = state.fetch("logs", []) || []
          return ["No logs yet."] if logs.empty?

          logs.sort_by { |entry| [entry["timestamp"].to_s, entry["id"].to_s] }.map do |entry|
            "#{timestamp(entry)} #{level(entry)} #{source(entry)} #{entry.fetch("message", "")}".rstrip
          end
        end

        private

        def timestamp(entry)
          Time.iso8601(entry.fetch("timestamp")).strftime("%H:%M:%S")
        rescue ArgumentError, KeyError, TypeError
          "--:--:--"
        end

        def level(entry)
          LEVEL_LABELS.fetch(entry["level"], "????")
        end

        def source(entry)
          source_type = entry.fetch("source_type", "system")
          source_id = entry["source_id"]
          source_id ? "#{source_type}:#{source_id}" : source_type
        end
      end
    end
  end
end
