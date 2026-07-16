# frozen_string_literal: true

module Meringue
  module TUI
    module LogVisibility
      module_function

      def visible?(entry)
        return false unless entry.is_a?(Hash)

        details = details_for(entry)
        return true if important_level?(entry)
        return true if command_log?(entry)
        return true if details["user_visible"] == true || details["visible"] == true
        return false if details["user_visible"] == false || details["visible"] == false
        return false if details["presentation"].to_s == "routine"

        !routine_info?(entry)
      end

      def command_log?(entry)
        details = details_for(entry)
        details["presentation"] == "cmd" || details["kind"].to_s.start_with?("kernel_command")
      end

      def important_level?(entry)
        %w[warning error].include?(entry.fetch("level", nil).to_s)
      end

      def routine_info?(entry)
        return false unless entry.fetch("level", "info").to_s == "info"

        source_type = entry.fetch("source_type", "system").to_s
        message = entry.fetch("message", "").to_s
        details = details_for(entry)

        case source_type
        when "user"
          message.match?(/\AUser prompt routed to head H\d+\.\z/)
        when "head"
          routine_head_message?(message)
        when "kernel"
          routine_kernel_message?(message, details)
        when "harness"
          routine_harness_message?(message)
        else
          false
        end
      end

      def details_for(entry)
        details = entry.fetch("details", {}) || {}
        details.is_a?(Hash) ? details : {}
      end

      def routine_head_message?(message)
        message.match?(/\ASpawned head H\d+\.\z/) ||
          message.match?(/\AHead H\d+ completed with \d+ proposed command\(s\)\.\z/) ||
          message.match?(/\APolled head H\d+ completed and applied its HeadResult\.\z/) ||
          message.match?(/\AKilled completed head H\d+ after applying its HeadResult\.\z/)
      end

      def routine_kernel_message?(message, details)
        message.match?(/\AApplying head result for H\d+\.\z/) ||
          routine_successful_head_result_summary?(message, details) ||
          message.match?(/\ARemoved completed head H\d+ from active state\.\z/) ||
          message.match?(/\ARemoved \d+ killed agent(?:s)? from active state\.\z/)
      end

      def routine_successful_head_result_summary?(message, details)
        return false unless message.match?(/\AApplied head result for H\d+:/)

        command_results = Array(details["command_results"])
        return true if command_results.empty?

        command_results.all? { |result| result.is_a?(Hash) && result["status"].to_s == "accepted" }
      end

      def routine_harness_message?(message)
        message.match?(/\AStarted \S+ head session for H\d+;/) ||
          message.match?(/\AStarted \S+ session for .+\z/)
      end
    end
  end
end
