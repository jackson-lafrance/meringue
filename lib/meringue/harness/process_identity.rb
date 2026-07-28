# frozen_string_literal: true

require "open3"
require "time"

module Meringue
  module Harness
    # Read-only OS process inspection used before a harness transport is taken
    # over. Persisted process ids can be reused by unrelated processes after a
    # reboot or a long-lived state file, so a pid alone is never enough evidence
    # to signal something.
    module ProcessIdentity
      START_TIME_TOLERANCE_SECONDS = 120

      # Returns { "pid", "ppid", "command", "started_at" } or nil when the
      # process does not exist or cannot be inspected.
      def self.describe(pid)
        return nil unless pid.to_s.match?(/\A\d+\z/) || pid.is_a?(Integer)

        numeric_pid = Integer(pid)
        return nil unless numeric_pid.positive?

        stdout, _stderr, status = Open3.capture3("ps", "-o", "ppid=,lstart=,comm=", "-p", numeric_pid.to_s)
        return nil unless status.success?

        line = stdout.lines.map(&:strip).reject(&:empty?).first
        return nil unless line

        # ps -o lstart= prints five whitespace-separated fields, and their order
        # depends on the locale (for example "Tue 28 Jul 15:00:16 2026").
        match = line.match(/\A(\d+)\s+(\S+\s+\S+\s+\S+\s+\d+:\d+:\d+\s+\d+)\s+(.*)\z/)
        return nil unless match

        {
          "pid" => numeric_pid,
          "ppid" => match[1].to_i,
          "started_at" => parse_time(match[2]),
          "command" => match[3].to_s.strip
        }
      rescue StandardError
        nil
      end

      def self.alive?(pid)
        return false if pid.nil? || pid.to_s.strip.empty?

        Process.kill(0, Integer(pid))
        true
      rescue Errno::ESRCH, ArgumentError, TypeError
        false
      rescue Errno::EPERM
        true
      end

      # True when the live process at +pid+ still looks like the recorded harness
      # process: the executable name matches the configured command and, when a
      # start time was recorded, the OS start time matches it.
      def self.matches?(pid, command: nil, started_at: nil)
        description = describe(pid)
        return false unless description

        return false unless command_matches?(description.fetch("command", ""), command)

        recorded = parse_time(started_at)
        observed = description.fetch("started_at", nil)
        return true unless recorded && observed

        (observed - recorded).abs <= START_TIME_TOLERANCE_SECONDS
      end

      def self.command_matches?(observed_command, expected_command)
        expected = executable_name(expected_command)
        return true if expected.nil?

        observed = File.basename(observed_command.to_s.split(/\s+/).first.to_s)
        return false if observed.empty?

        observed == expected || observed.start_with?(expected) || expected.start_with?(observed)
      end

      def self.executable_name(command)
        first = command.is_a?(Array) ? command.first : command
        text = first.to_s.strip
        return nil if text.empty?

        File.basename(text.split(/\s+/).first.to_s)
      end

      def self.parse_time(value)
        return value.utc if value.is_a?(Time)

        text = value.to_s.strip
        return nil if text.empty?

        Time.parse(text).utc
      rescue ArgumentError, TypeError
        nil
      end
      private_class_method :parse_time
    end
  end
end
