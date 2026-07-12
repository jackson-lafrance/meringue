# frozen_string_literal: true

module Meringue
  module Harness
    class GeminiClient < ProcessClient
      DEFAULT_COMMAND = "gemini"

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [], **kwargs)
        super(harness_name: "gemini", command: command, env: env, extra_args: extra_args, **kwargs)
      end

      protected

      def build_spawn_argv(kind:, prompt:, system_prompt:, session_name:, session_id:)
        prompt_text = combine_system_prompt(system_prompt, prompt)
        base_prompt_argv + extra_args + ["-p", prompt_text]
      end

      def build_resume_argv(session_ref:, prompt:, mode:, session_id:)
        argv = base_prompt_argv
        argv += ["-r", session_id.to_s] if present?(session_id)
        argv + extra_args + ["-p", prompt.to_s]
      end

      def base_prompt_argv
        command_argv + ["--output-format", "stream-json"]
      end
    end
  end
end
