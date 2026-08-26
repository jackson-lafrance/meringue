# frozen_string_literal: true

require "json"
require "set"

module Meringue
  module Harness
    # OpenAI Codex as a Meringue backend, driven through Codex's native interactive TUI.
    # One PTY remains alive for autonomous prompting and focused viewing; Codex's rollout JSONL is
    # the durable authority for state, results, recovery, and reconciliation.
    class CodexInteractiveClient < InteractiveClient
      DEFAULT_COMMAND = "codex"
      DEFAULT_CODEX_HOME = File.expand_path("~/.codex")
      READY_TIMEOUT = 120
      READY_QUIET_SECONDS = 0.5
      TRUST_PROMPT_PATTERN = /Do you trust the contents of this directory/i.freeze
      PROMPT_PATTERN = /[›>]\s*(?:Ask Codex to do anything|Implement|Explain|Fix|Review|Generate|Ask)/i.freeze
      INTERRUPT_KEY = "\e"
      FOLLOW_UP_KEY = "\t"
      SUBMIT_KEY = "\r"

      attr_reader :codex_home

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [], codex_home: nil, **kwargs)
        super(
          harness_name: "codex",
          command: command,
          transcript_schema: CodexTranscript,
          env: env,
          extra_args: extra_args,
          ready_timeout: kwargs.fetch(:ready_timeout, READY_TIMEOUT),
          shutdown_timeout: kwargs.fetch(:shutdown_timeout, DEFAULT_SHUTDOWN_TIMEOUT),
          delivery_confirm_timeout: kwargs.fetch(:delivery_confirm_timeout, DEFAULT_DELIVERY_CONFIRM_TIMEOUT)
        )
        resolved_home = codex_home || env["CODEX_HOME"] || env[:CODEX_HOME] || ENV.fetch("CODEX_HOME", DEFAULT_CODEX_HOME)
        @codex_home = File.expand_path(resolved_home.to_s)
      end

      def read_only_workspace_supported?
        true
      end

      def model_catalog_supported?
        true
      end

      def available_models(cwd: nil)
        CodexModelCatalog.fetch(command: command, env: env.merge("CODEX_HOME" => codex_home), cwd: cwd)
      end

      protected

      # Codex reports its effective model and reasoning level in each rollout's turn_context.
      # Cache that pair as the shared transport incrementally drains records. This is a read
      # capability only: Codex does not advertise the live mutation API used by Pi.
      def initial_reported_session_settings(session_settings)
        settings = session_settings || {}
        settings if settings.is_a?(Hash) && present?(settings["availability"] || settings[:availability])
      end

      def observe_transcript_records(entry, records)
        settings = CodexTranscript.session_settings(records)
        return if settings.fetch("availability") == "unknown"

        entry.fetch("mutex").synchronize { entry["reported_session_settings"] = settings }
      end

      def spawn_argv(kind:, cwd:, session_id:, system_prompt:, session_name:, session_settings:)
        _ = [kind, cwd, session_id, session_name]
        argv = command_argv + extra_args + session_settings_argv(session_settings)
        argv += ["-c", "developer_instructions=#{toml_string(system_prompt)}"] if present?(system_prompt)
        argv
      end

      def spawn_argv_for_workspace_mode(argv, kind:, workspace_mode:)
        _ = kind
        return argv unless workspace_mode.to_s == "shared_read_only"

        enforce_read_only(argv)
      end

      def resume_argv(session_ref)
        # Current future-session defaults must never rewrite an existing Codex thread. Strip model
        # selection from the cached spawn argv and reapply only the effective settings recorded on
        # this session; when the rollout has not reported them, `codex resume` uses its own saved
        # thread context.
        args = without_session_settings(extra_args)
        args += session_settings_argv(session_ref.fetch("session_settings", {}) || {})
        if metadata_value(session_ref, "workspace_mode").to_s == "shared_read_only"
          args = enforce_read_only(args)
        end
        command_argv + args + ["resume", session_id_value(session_ref)]
      end

      # Codex chooses its own thread id and creates the rollout only after the first prompt. The
      # initial delivery marker contains Meringue's temporary id, giving discovery an exact match
      # even when several Codex sessions start concurrently in the same checkout.
      def session_identity_required?
        true
      end

      def initial_delivery_id(requested_session_id)
        "codex-spawn:#{requested_session_id}"
      end

      def capture_session_identity(cwd:, requested_session_id:)
        {
          "cwd" => canonical_path(cwd),
          "requested_session_id" => requested_session_id.to_s,
          "existing_paths" => Set.new(session_paths)
        }
      end

      def discover_session_identity(entry)
        current = entry.fetch("transcript_path", nil)
        if present?(current) && File.file?(current.to_s)
          metadata = session_metadata(current)
          return identity_from(current, metadata) if metadata
        end

        discovery = entry.fetch("session_identity_discovery", {}) || {}
        existing = discovery.fetch("existing_paths", Set.new)
        requested = discovery.fetch("requested_session_id", entry.fetch("requested_session_id", nil)).to_s
        cwd = discovery.fetch("cwd", canonical_path(entry.fetch("cwd")))
        candidates = session_paths.reject { |path| existing.include?(path) }
        candidates.sort_by! { |path| File.mtime(path) rescue Time.at(0) }
        candidates.reverse_each do |path|
          metadata = session_metadata(path)
          next unless metadata
          next unless canonical_path(metadata["cwd"]) == cwd
          next unless transcript_contains?(path, requested)

          return identity_from(path, metadata)
        end
        nil
      end

      def transcript_path(cwd:, session_id:)
        _ = cwd
        return nil unless present?(session_id)

        session_paths.find do |path|
          File.basename(path).end_with?("-#{session_id}.jsonl") || session_metadata(path)&.values_at("id", "session_id")&.include?(session_id.to_s)
        end
      end

      def wait_until_ready(process)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ready_timeout
        loop do
          return false unless process.alive?
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          screen = process.plain_screen_text.to_s
          if screen.match?(TRUST_PROMPT_PATTERN) && !prompt_box_visible?(screen)
            process.write(SUBMIT_KEY)
            process.wait_for_screen(timeout: 20) do |text|
              prompt_box_visible?(text) || !text.match?(TRUST_PROMPT_PATTERN)
            end
            next
          end

          visible = process.wait_for_screen(timeout: 5) { |text| prompt_box_visible?(text) }
          next unless visible

          process.wait_for_quiet(quiet_for: READY_QUIET_SECONDS, timeout: 5)
          return true if prompt_box_visible?(process.plain_screen_text)
        end
      end

      def submit_prompt(process, text, mode: "normal")
        process.write("\e[200~#{text}\e[201~")
        process.wait_for_quiet(quiet_for: 0.25, timeout: 15)
        process.write(mode.to_s == "follow_up" ? FOLLOW_UP_KEY : SUBMIT_KEY)
      end

      def interrupt(process)
        process.write(INTERRUPT_KEY)
      end

      def process_environment(cwd)
        super.merge("CODEX_HOME" => codex_home)
      end

      private

      def session_settings_argv(session_settings)
        settings = session_settings || {}
        model = settings["model"] || settings[:model]
        effort = settings["thinking_level"] || settings[:thinking_level]
        reference = model.is_a?(Hash) ? (model["reference"] || model[:reference]) : model
        argv = []
        argv += ["--model", ModelReference.bare_id(reference)] if present?(reference)
        argv += ["-c", "model_reasoning_effort=#{toml_string(effort.to_s)}"] if present?(effort)
        argv
      end

      def without_session_settings(arguments)
        result = []
        values = Array(arguments).map(&:to_s)
        index = 0
        while index < values.length
          argument = values[index]
          if %w[--model -m].include?(argument)
            index += 2
            next
          end
          if argument.start_with?("--model=") || argument.start_with?("-m=")
            index += 1
            next
          end
          if %w[-c --config].include?(argument) && values[index + 1].to_s.start_with?("model_reasoning_effort=")
            index += 2
            next
          end
          if argument.start_with?("--config=model_reasoning_effort=")
            index += 1
            next
          end
          result << argument
          index += 1
        end
        result
      end

      def enforce_read_only(arguments)
        values = Array(arguments).map(&:to_s)
        result = []
        index = 0
        while index < values.length
          argument = values[index]
          if %w[--sandbox -s --ask-for-approval -a].include?(argument)
            index += 2
            next
          end
          if argument == "--dangerously-bypass-approvals-and-sandbox" ||
             argument.match?(/\A(?:--sandbox|-s|--ask-for-approval|-a)=/) ||
             safety_config_override?(argument)
            index += 1
            next
          end
          if %w[-c --config].include?(argument) && safety_config_override?(values[index + 1])
            index += 2
            next
          end
          if argument.start_with?("--config=") && safety_config_override?(argument.delete_prefix("--config="))
            index += 1
            next
          end

          result << argument
          index += 1
        end
        result + ["--sandbox", "read-only", "--ask-for-approval", "never"]
      end

      def safety_config_override?(value)
        value.to_s.match?(/\A(?:sandbox_mode|approval_policy)\s*=/)
      end

      def session_paths
        Dir.glob(File.join(codex_home, "sessions", "**", "*.jsonl"))
      end

      def session_metadata(path)
        File.foreach(path) do |line|
          record = JSON.parse(line)
          next unless record.is_a?(Hash) && record["type"].to_s == "session_meta"

          payload = record["payload"]
          return payload if payload.is_a?(Hash) && present?(payload["id"] || payload["session_id"])
        rescue JSON::ParserError
          next
        end
        nil
      rescue SystemCallError
        nil
      end

      def identity_from(path, metadata)
        id = metadata["session_id"] || metadata["id"]
        return nil unless present?(id)

        { "session_id" => id.to_s, "session_file" => File.expand_path(path.to_s) }
      end

      def transcript_contains?(path, needle)
        return false unless present?(needle)

        File.foreach(path).any? { |line| line.include?(needle.to_s) }
      rescue SystemCallError
        false
      end

      def prompt_box_visible?(text)
        value = text.to_s
        value.match?(PROMPT_PATTERN) || (value.include?("›") && value.match?(/\b(?:low|medium|high|xhigh|max)\b/i))
      end

      def canonical_path(path)
        expanded = File.expand_path(path.to_s)
        File.realpath(expanded)
      rescue SystemCallError
        expanded
      end

      def session_id_value(session_ref)
        (session_ref["session_id"] || session_ref[:session_id]).to_s
      end

      def toml_string(value)
        JSON.generate(value.to_s)
      end
    end
  end
end
