# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"
require "timeout"

module Meringue
  module Harness
    # Discovers the model choices Claude Code itself exposes from its `/model`
    # help response. This is deliberately a short-lived, no-session invocation:
    # it does not create a transcript, alter a managed PTY, or turn the model
    # picker into a second Claude session.
    module ClaudeModelCatalog
      SOURCE = "claude_print_model_command"
      PROVIDER = "anthropic"
      DEFAULT_TIMEOUT = 15
      MAX_OUTPUT_BYTES = 64 * 1024
      EFFORT_LEVELS = %w[low medium high xhigh max].freeze
      CATALOG_PROMPT = "/model"

      module_function

      def fetch(command:, env: {}, cwd: nil, extra_args: [], timeout: DEFAULT_TIMEOUT)
        argv = strip_spawn_settings(command_argv(command)) + catalog_args(extra_args)
        stdout, stderr, status = capture(argv, env: env, cwd: cwd, timeout: timeout)
        unless status&.success?
          return ModelCatalog.unavailable(
            harness: "claude",
            note: failure_note(stderr, status),
            reason: "fetch_failed",
            error: "exit_status_#{status&.exitstatus || "unknown"}"
          )
        end

        parse(stdout, stderr: stderr)
      rescue StandardError => e
        ModelCatalog.unavailable(
          harness: "claude",
          note: "Could not read Claude Code's model catalog: #{bounded(e.message)}",
          reason: "fetch_failed",
          error: e.class.name
        )
      end

      def parse(output, stderr: nil)
        text = extract_result_text(output)
        structured = structured_entries(output)
        entries = if structured && !structured.empty?
                    structured
                  else
                    entries_from_help(text)
                  end
        if entries.empty?
          note = text.to_s.strip
          note = bounded(note) unless note.empty?
          note = "Claude Code did not report any model choices#{": #{note}" unless note.empty?}."
          note = "#{note} #{bounded(stderr)}" unless stderr.to_s.strip.empty?
          return ModelCatalog.unavailable(
            harness: "claude",
            note: note,
            reason: "empty_catalog",
            error: "empty_model_list"
          )
        end

        ModelCatalog.available(
          harness: "claude",
          models: entries,
          source: SOURCE,
          authentication: {
            "status" => ModelCatalog::AUTHENTICATION_UNKNOWN,
            "source" => SOURCE,
            "reason" => "harness_did_not_report_auth"
          }
        )
      end

      def catalog_args(extra_args)
        # Resource and permission settings can affect what Claude Code reports,
        # but spawn-only settings must not leak into discovery. In particular a
        # saved model or effort value cannot make `/model` fail before it can
        # tell us what is available.
        filtered = strip_spawn_settings(Array(extra_args).map(&:to_s))
        ["--bare", "--no-session-persistence", "--tools", "", "--print", "--output-format", "json", *filtered, CATALOG_PROMPT]
      end

      def command_argv(command)
        command.is_a?(Array) ? command.map(&:to_s) : Shellwords.split(command.to_s)
      rescue ArgumentError
        [command.to_s]
      end

      def capture(argv, env:, cwd:, timeout:)
        options = {}
        options[:chdir] = File.expand_path(cwd.to_s) unless cwd.to_s.strip.empty?
        Open3.popen3(env.transform_keys(&:to_s).transform_values(&:to_s), *argv, **options) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          out_reader = Thread.new { bounded_read(stdout) }
          err_reader = Thread.new { bounded_read(stderr) }
          begin
            status = Timeout.timeout(timeout.to_f) { wait_thread.value }
          rescue Timeout::Error
            Process.kill("TERM", wait_thread.pid)
            status = wait_thread.value rescue nil
            raise Timeout::Error, "Claude Code model discovery timed out after #{timeout} seconds"
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
          break if remaining <= 0

          buffer << chunk.byteslice(0, remaining)
        end
        buffer
      rescue EOFError, IOError
        buffer
      end

      def structured_entries(output)
        payload = parse_json(output)
        return nil unless payload.is_a?(Hash)

        models = payload["models"] || payload.dig("data", "models")
        return nil unless models.is_a?(Array)

        models.filter_map do |model|
          if model.is_a?(Hash)
            model = model.dup
            model["provider"] ||= PROVIDER
            model["thinking_levels"] ||= EFFORT_LEVELS
            model
          elsif model.is_a?(String)
            entry_for(model)
          end
        end
      end

      def entries_from_help(text)
        match = text.to_s.match(/\bAvailable:\s*(.+?)(?:\.|\z)/im)
        return [] unless match

        choices = match[1].to_s
          .sub(/,?\s*or\s+a\s+full\s+model\s+ID.*\z/i, "")
          .split(/,\s*/)
          .map { |choice| choice.to_s.strip.gsub(/\A[\"'`]|[\"'`]\z/, "") }
          .reject(&:empty?)
          .reject { |choice| choice.match?(/\A(?:and|or)\s+/i) }
        # New Claude releases occasionally include concrete ids in the same help text while still
        # advertising aliases. Keep those ids too; aliases and full ids are both authoritative.
        choices.concat(text.to_s.scan(/\bclaude-[A-Za-z0-9._:-]+/i).map { |id| id.delete_suffix(".") })

        choices.filter_map { |choice| entry_for(choice) }
      end

      def entry_for(id)
        value = id.to_s.strip
        return nil if value.empty? || value.match?(/\bfull\s+model\s+id\b/i)

        provider, model_id = if value.include?("/")
                              ModelReference.split(value)
                            else
                              [PROVIDER, value]
                            end
        return nil if provider.empty? || model_id.empty?

        {
          "provider" => provider,
          "id" => model_id,
          "name" => display_name(model_id),
          "thinking_levels" => EFFORT_LEVELS,
          "reasoning" => true
        }
      end

      def display_name(id)
        id.to_s
          .sub(/\[1m\]\z/i, " (1M)")
          .split(/[-_]/).map { |word| word.empty? ? word : word[0].upcase + word[1..].to_s }.join(" ")
      end

      def parse_json(output)
        text = output.to_s.strip
        return nil if text.empty?

        JSON.parse(text)
      rescue JSON::ParserError
        output.to_s.lines.reverse_each do |line|
          begin
            parsed = JSON.parse(line)
            return parsed if parsed.is_a?(Hash)
          rescue JSON::ParserError
            next
          end
        end
        nil
      end

      def extract_result_text(output)
        payload = parse_json(output)
        return payload["result"].to_s if payload.is_a?(Hash) && payload["result"]
        return payload.dig("data", "result").to_s if payload.is_a?(Hash) && payload.dig("data", "result")

        output.to_s
      end

      def strip_spawn_settings(args)
        result = []
        skip_next = false
        args.each do |argument|
          if skip_next
            skip_next = false
            next
          end
          if %w[--model --effort --session-id --name --system-prompt --json-schema].include?(argument)
            skip_next = true
            next
          end
          if %w[--model= --effort= --session-id= --name= --system-prompt= --json-schema=].any? { |prefix| argument.start_with?(prefix) }
            next
          end
          result << argument
        end
        result
      end

      def failure_note(stderr, status)
        detail = bounded(stderr.to_s.strip)
        detail = "exit status #{status&.exitstatus || "unknown"}" if detail.empty?
        "Could not read Claude Code's model catalog: #{detail}"
      end

      def bounded(value)
        text = value.to_s.strip
        return text if text.bytesize <= 2_000

        "#{text.byteslice(0, 1_997)}..."
      end
    end
  end
end
