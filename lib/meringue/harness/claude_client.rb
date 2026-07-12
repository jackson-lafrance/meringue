# frozen_string_literal: true

module Meringue
  module Harness
    class ClaudeClient < ProcessClient
      DEFAULT_COMMAND = "claude"

      attr_reader :use_json_schema

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [], use_json_schema: true, **kwargs)
        super(harness_name: "claude", command: command, env: env, extra_args: extra_args, **kwargs)
        @use_json_schema = use_json_schema
      end

      protected

      def build_spawn_argv(kind:, prompt:, system_prompt:, session_name:, session_id:)
        argv = base_print_argv
        argv += ["--session-id", session_id.to_s] if present?(session_id)
        argv += ["--system-prompt", system_prompt.to_s] if present?(system_prompt)
        argv += ["--json-schema", Heads::ResultParser.json_schema] if kind.to_s == "head" && use_json_schema
        argv += extra_args
        argv << prompt.to_s if present?(prompt)
        argv
      end

      def build_resume_argv(session_ref:, prompt:, mode:, session_id:)
        argv = base_print_argv
        argv += ["--resume", session_id.to_s] if present?(session_id)
        argv += extra_args
        argv << prompt.to_s if present?(prompt)
        argv
      end

      def base_print_argv
        command_argv + ["--print", "--output-format", "stream-json", "--verbose"]
      end
    end

    # Backward-compatible explicit name for the Claude Code harness backend.
    class ClaudeCodeClient < ClaudeClient; end
  end
end
