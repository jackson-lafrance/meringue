# frozen_string_literal: true

module Meringue
  module Harness
    class AntigravityClient < ProcessClient
      DEFAULT_COMMAND = "agy"

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [], **kwargs)
        super(harness_name: "antigravity", command: command, env: env, extra_args: extra_args, **kwargs)
      end

      protected

      def build_spawn_argv(kind:, prompt:, system_prompt:, session_name:, session_id:)
        prompt_text = combine_system_prompt(system_prompt, prompt)
        base_prompt_argv + extra_args + [prompt_text]
      end

      def build_resume_argv(session_ref:, prompt:, mode:, session_id:)
        base_prompt_argv + ["--continue"] + extra_args + [prompt.to_s]
      end

      def base_prompt_argv
        command_argv + ["--print"]
      end
    end
  end
end
