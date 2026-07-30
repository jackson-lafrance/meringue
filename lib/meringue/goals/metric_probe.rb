# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "timeout"

require_relative "record"

module Meringue
  module Goals
    # Runs a goal's metric and guardrail commands and reads a number out of their output.
    #
    # The probe is deliberately owned by the kernel, not by the attempt agent: a metric an
    # agent reports about its own work is not a measurement. It follows the same bounded
    # external-command discipline as the workspace manager (own process group, hard
    # timeout, group kill on timeout, capped captured output) so one wedged command cannot
    # stall the reconcile tick.
    class MetricProbe
      DEFAULT_TIMEOUT_SECONDS = Record::DEFAULT_METRIC_TIMEOUT_SECONDS
      TERMINATION_GRACE_SECONDS = 1
      FINGERPRINT_TIMEOUT_SECONDS = 10

      def initialize(shell: ["/bin/sh", "-c"], output_limit: Record::OUTPUT_TAIL_LIMIT)
        @shell = Array(shell)
        @output_limit = Integer(output_limit)
      end

      # Runs the metric command and parses a numeric value out of it.
      def measure(command:, cwd:, parse: {}, timeout: DEFAULT_TIMEOUT_SECONDS)
        outcome = run(command: command, cwd: cwd, timeout: timeout)
        return outcome if outcome.fetch("timed_out", false) || outcome.key?("error")

        parsed = parse_value(outcome, parse)
        outcome.merge(parsed)
      end

      # Runs one guardrail command. Guardrails are pass/fail only: a guardrail exists to
      # prove the metric was not gained by breaking something else.
      def check_guardrail(command:, cwd:, timeout: DEFAULT_TIMEOUT_SECONDS)
        outcome = run(command: command, cwd: cwd, timeout: timeout)
        outcome.merge(
          "command" => command.to_s,
          "expect" => "exit_zero",
          "passed" => !outcome.fetch("timed_out", false) && outcome.fetch("exit_status", nil).to_i.zero? && !outcome.key?("error")
        )
      end

      # A cheap, deterministic fingerprint of the workspace's current tree. Two iterations
      # with the same fingerprint produced the same code, which is how the loop detects
      # that attempts are going in circles.
      def workspace_fingerprint(cwd:)
        return nil unless cwd && Dir.exist?(cwd.to_s)

        head = run(command: "git rev-parse HEAD", cwd: cwd, timeout: FINGERPRINT_TIMEOUT_SECONDS)
        return nil unless head.fetch("exit_status", nil).to_i.zero?

        dirty = run(command: "git status --porcelain", cwd: cwd, timeout: FINGERPRINT_TIMEOUT_SECONDS)
        Digest::SHA256.hexdigest([head.fetch("stdout_tail", ""), dirty.fetch("stdout_tail", "")].join("\n"))[0, 16]
      rescue StandardError
        nil
      end

      private

      attr_reader :shell, :output_limit

      def run(command:, cwd:, timeout:)
        return { "error" => "metric command is empty", "exit_status" => nil, "timed_out" => false, "stdout_tail" => "", "stderr_tail" => "" } if Record.present_string(command).nil?
        return { "error" => "workspace #{cwd} does not exist", "exit_status" => nil, "timed_out" => false, "stdout_tail" => "", "stderr_tail" => "" } unless cwd && Dir.exist?(cwd.to_s)

        stdout = +""
        stderr = +""
        status = nil
        timed_out = false

        Open3.popen3(*shell, command.to_s, chdir: cwd.to_s, pgroup: true) do |child_stdin, child_out, child_err, wait_thread|
          child_stdin.close
          readers = [
            Thread.new { stdout << child_out.read.to_s },
            Thread.new { stderr << child_err.read.to_s }
          ]
          begin
            Timeout.timeout(Float(timeout)) { status = wait_thread.value }
          rescue Timeout::Error
            timed_out = true
            terminate_process_group(wait_thread.pid)
            readers.each { |reader| reader.join(TERMINATION_GRACE_SECONDS) }
          ensure
            terminate_process_group(wait_thread.pid) if status.nil? && wait_thread.alive?
            readers.each { |reader| reader.join(TERMINATION_GRACE_SECONDS) }
            child_out.close unless child_out.closed?
            child_err.close unless child_err.closed?
          end
        end

        {
          "exit_status" => status&.exitstatus,
          "timed_out" => timed_out,
          "stdout_tail" => tail(stdout),
          "stderr_tail" => tail(stderr)
        }
      rescue StandardError => e
        { "error" => e.message, "exit_status" => nil, "timed_out" => false, "stdout_tail" => tail(stdout.to_s), "stderr_tail" => tail(stderr.to_s) }
      end

      def parse_value(outcome, parse)
        parse = {} unless parse.is_a?(Hash)
        type = Record::PARSE_TYPES.include?(parse["type"].to_s) ? parse["type"].to_s : Record::DEFAULT_PARSE_TYPE
        text = [outcome.fetch("stdout_tail", ""), outcome.fetch("stderr_tail", "")].join("\n")

        case type
        when "exit_status"
          { "value" => outcome.fetch("exit_status", nil).to_i.zero? ? 1.0 : 0.0 }
        when "regex"
          parse_with_regex(text, parse)
        when "json_path"
          parse_with_json_path(outcome.fetch("stdout_tail", ""), parse)
        when "first_number"
          value = numbers_in(text).first
          value.nil? ? { "value" => nil, "parse_error" => "no number in metric output" } : { "value" => value }
        else
          value = numbers_in(text).last
          value.nil? ? { "value" => nil, "parse_error" => "no number in metric output" } : { "value" => value }
        end
      end

      def parse_with_regex(text, parse)
        pattern = Record.present_string(parse["pattern"])
        return { "value" => nil, "parse_error" => "regex parse requires a pattern" } unless pattern

        match = Regexp.new(pattern, Regexp::MULTILINE).match(text)
        return { "value" => nil, "parse_error" => "metric pattern did not match" } unless match

        capture = parse["capture"].nil? ? 1 : parse["capture"].to_i
        captured = capture.zero? ? match[0] : match[capture]
        value = Record.float_or_nil(captured)
        value.nil? ? { "value" => nil, "parse_error" => "metric pattern captured a non-number" } : { "value" => value }
      rescue RegexpError => e
        { "value" => nil, "parse_error" => "invalid metric pattern: #{e.message}" }
      end

      def parse_with_json_path(text, parse)
        path = Record.present_string(parse["path"])
        return { "value" => nil, "parse_error" => "json_path parse requires a path" } unless path

        document = JSON.parse(text)
        value = path.split(".").reduce(document) do |node, key|
          case node
          when Hash then node[key]
          when Array then node[key.to_i]
          end
        end
        parsed = Record.float_or_nil(value)
        parsed.nil? ? { "value" => nil, "parse_error" => "metric json path #{path} is not a number" } : { "value" => parsed }
      rescue JSON::ParserError => e
        { "value" => nil, "parse_error" => "metric output is not JSON: #{e.message}" }
      end

      def numbers_in(text)
        text.to_s.scan(/-?\d+(?:\.\d+)?/).map(&:to_f)
      end

      def tail(text)
        Record.truncate_output(text)
      end

      def terminate_process_group(pid)
        Process.kill("TERM", -pid)
        sleep(TERMINATION_GRACE_SECONDS)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
