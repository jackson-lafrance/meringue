# frozen_string_literal: true

module Meringue
  module Harness
    class GeminiClient < ProcessClient
      DEFAULT_COMMAND = "gemini"
      DEFAULT_OUTPUT_FORMAT = "json"
      DEFAULT_PROMPT_FLAG = "-p"
      DEFAULT_RESUME_FLAG = "--resume"

      attr_reader :output_format, :prompt_flag, :resume_flag

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [],
                     output_format: DEFAULT_OUTPUT_FORMAT,
                     prompt_flag: DEFAULT_PROMPT_FLAG,
                     resume_flag: DEFAULT_RESUME_FLAG,
                     **kwargs)
        super(harness_name: "gemini", command: command, env: env, extra_args: extra_args, **kwargs)
        @output_format = output_format.to_s
        @prompt_flag = prompt_flag.to_s
        @resume_flag = resume_flag.to_s
      end

      protected

      def build_spawn_argv(kind:, prompt:, system_prompt:, session_name:, session_id:)
        prompt_text = combine_system_prompt(system_prompt, prompt)
        prompt_argv(prompt_text)
      end

      def build_resume_argv(session_ref:, prompt:, mode:, session_id:)
        argv = base_prompt_argv
        argv += [resume_flag, session_id.to_s] if present?(resume_flag) && present?(session_id)
        argv += extra_args
        argv += prompt_argument(prompt.to_s)
        argv
      end

      def prompt_argv(prompt)
        base_prompt_argv + extra_args + prompt_argument(prompt)
      end

      def prompt_argument(prompt)
        return [] unless present?(prompt)
        return [prompt] unless present?(prompt_flag)

        [prompt_flag, prompt]
      end

      def base_prompt_argv
        argv = command_argv
        argv += ["--output-format", output_format] if present?(output_format)
        argv
      end
    end
  end
end
