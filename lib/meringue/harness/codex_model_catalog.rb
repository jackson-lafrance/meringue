# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
require "timeout"

module Meringue
  module Harness
    # Reads Codex CLI's own model catalog without creating or touching an agent session.
    module CodexModelCatalog
      SOURCE = "codex_debug_models"
      PROVIDER = "openai"
      DEFAULT_TIMEOUT = 20
      MAX_OUTPUT_BYTES = 2 * 1024 * 1024

      module_function

      def fetch(command:, env: {}, cwd: nil, timeout: DEFAULT_TIMEOUT)
        argv = command_argv(command) + ["debug", "models"]
        stdout, stderr, status = capture(argv, env: env, cwd: cwd, timeout: timeout)
        unless status&.success?
          return ModelCatalog.unavailable(
            harness: "codex",
            note: failure_note(stderr, status),
            source: SOURCE,
            reason: "fetch_failed",
            error: "exit_status_#{status&.exitstatus || "unknown"}"
          )
        end

        parse(stdout, stderr: stderr)
      rescue StandardError => e
        ModelCatalog.unavailable(
          harness: "codex",
          note: "Could not read Codex's model catalog: #{bounded(e.message)}",
          source: SOURCE,
          reason: "fetch_failed",
          error: e.class.name
        )
      end

      def parse(output, stderr: nil)
        payload = JSON.parse(output.to_s)
        models = payload.is_a?(Hash) ? payload["models"] : nil
        entries = Array(models).filter_map { |model| entry_for(model) }
        if entries.empty?
          detail = bounded(stderr.to_s.strip)
          note = "Codex did not report any available models."
          note = "#{note} #{detail}" unless detail.empty?
          return ModelCatalog.unavailable(
            harness: "codex",
            note: note,
            source: SOURCE,
            reason: "empty_catalog",
            error: "empty_model_list"
          )
        end

        ModelCatalog.available(harness: "codex", models: entries, source: SOURCE)
      rescue JSON::ParserError => e
        ModelCatalog.unavailable(
          harness: "codex",
          note: "Codex returned a malformed model catalog: #{bounded(e.message)}",
          source: SOURCE,
          reason: "malformed_catalog",
          error: e.class.name
        )
      end

      def entry_for(model)
        return nil unless model.is_a?(Hash)
        return nil if model["visibility"].to_s == "hide"

        id = model["slug"].to_s.strip
        return nil if id.empty?

        levels = Array(model["supported_reasoning_levels"]).filter_map do |level|
          value = level.is_a?(Hash) ? level["effort"] : level
          normalized = value.to_s.strip.downcase
          normalized if ModelCatalog::THINKING_LEVELS.include?(normalized)
        end.uniq
        {
          "provider" => PROVIDER,
          "id" => id,
          "name" => present(model["display_name"]) || id,
          "thinking_levels" => levels,
          "reasoning" => !levels.empty?,
          "context_window" => integer_or_nil(model["context_window"] || model["max_context_window"])
        }.compact
      end

      def command_argv(command)
        command.is_a?(Array) ? command.map(&:to_s) : Shellwords.split(command.to_s)
      rescue ArgumentError
        [command.to_s]
      end

      def capture(argv, env:, cwd:, timeout:)
        options = {}
        options[:chdir] = File.expand_path(cwd.to_s) unless cwd.to_s.strip.empty?
        environment = env.transform_keys(&:to_s).transform_values(&:to_s)
        Open3.popen3(environment, *argv, **options) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          out_reader = Thread.new { bounded_read(stdout) }
          err_reader = Thread.new { bounded_read(stderr) }
          begin
            status = Timeout.timeout(timeout.to_f) { wait_thread.value }
          rescue Timeout::Error
            Process.kill("TERM", wait_thread.pid)
            status = wait_thread.value rescue nil
            raise Timeout::Error, "Codex model discovery timed out after #{timeout} seconds"
          ensure
            stdout.close unless stdout.closed?
            stderr.close unless stderr.closed?
          end
          [out_reader.value, err_reader.value, status]
        end
      end

      def bounded_read(io)
        buffer = +""
        while (chunk = io.readpartial(4096))
          remaining = MAX_OUTPUT_BYTES - buffer.bytesize
          buffer << chunk.byteslice(0, remaining) if remaining.positive?
          # Keep draining after the retained cap so a verbose Codex process cannot block forever
          # on a full stdout/stderr pipe. Parsing the truncated payload degrades to unavailable.
        end
        buffer
      rescue EOFError, IOError
        buffer
      end

      def failure_note(stderr, status)
        detail = bounded(stderr.to_s.strip)
        detail = "exit status #{status&.exitstatus || "unknown"}" if detail.empty?
        "Could not read Codex's model catalog: #{detail}"
      end

      def integer_or_nil(value)
        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def present(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def bounded(value)
        text = value.to_s.strip
        return text if text.bytesize <= 2_000

        "#{text.byteslice(0, 1_997)}..."
      end
    end
  end
end
