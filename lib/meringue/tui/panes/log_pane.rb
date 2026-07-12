# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    module Panes
      class LogPane
        LEVEL_LABELS = {
          "info" => "info",
          "warning" => "warn",
          "error" => "err"
        }.freeze

        LEVEL_STYLES = {
          "info" => Style::LOG_INFO,
          "warning" => Style::LOG_WARNING,
          "error" => Style::LOG_ERROR
        }.freeze

        def render(state)
          lines(state).map { |line| plain_text(line) }.join("\n")
        end

        def lines(state)
          logs = state.fetch("logs", []) || []
          return [[["No logs yet.", Style::MUTED]]] if logs.empty?

          logs.sort_by { |entry| [entry["timestamp"].to_s, entry["id"].to_s] }.map do |entry|
            line = [
              [timestamp(entry), Style::DIM],
              ["  #{level(entry)}", level_style(entry)]
            ]
            log_source = source(entry)
            line << ["  #{log_source}", Style::MUTED] if log_source
            line << ["  #{entry.fetch("message", "")}", Style::TEXT]
            line
          end
        end

        private

        def timestamp(entry)
          Time.iso8601(entry.fetch("timestamp")).strftime("%H:%M:%S")
        rescue ArgumentError, KeyError, TypeError
          "--:--:--"
        end

        def level(entry)
          return "cmd" if command_log?(entry)

          LEVEL_LABELS.fetch(entry["level"], "????")
        end

        def level_style(entry)
          return Style::LOG_COMMAND if command_log?(entry)

          LEVEL_STYLES.fetch(entry["level"], Style::MUTED)
        end

        def command_log?(entry)
          details = entry.fetch("details", {}) || {}
          details["presentation"] == "cmd" || details["kind"].to_s.start_with?("kernel_command")
        end

        def source(entry)
          source_type = entry.fetch("source_type", "system")
          source_id = entry["source_id"]
          source_id ? "#{source_type}:#{source_id}" : source_type
        end

        def plain_text(line)
          return line.to_s unless line.is_a?(Array)

          line.map { |segment| segment.is_a?(Array) ? segment.first.to_s : segment.to_s }.join
        end
      end
    end
  end
end
