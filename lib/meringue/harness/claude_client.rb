# frozen_string_literal: true

require "json"

module Meringue
  module Harness
    class ClaudeClient < ProcessClient
      DEFAULT_COMMAND = "claude"

      attr_reader :use_json_schema, :claude_home

      def initialize(command: DEFAULT_COMMAND, env: {}, extra_args: [], use_json_schema: true,
                     claude_home: ENV.fetch("CLAUDE_CONFIG_DIR", File.expand_path("~/.claude")), **kwargs)
        super(harness_name: "claude", command: command, env: env, extra_args: extra_args, **kwargs)
        @use_json_schema = use_json_schema
        @claude_home = File.expand_path(claude_home.to_s)
      end

      def last_assistant_text(session_ref)
        text = super
        return text if present?(text)

        text_from_session_file(session_ref)
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

      def build_session_ref(process, kind:, cwd:, session_name:, fallback_session_id:, previous_metadata: {})
        with_session_file(super)
      end

      def completed_session_ref(session_ref)
        with_session_file(super)
      end

      def with_session_file(session_ref)
        session_file = session_ref["session_file"] || claude_session_file(
          cwd: session_ref["cwd"] || session_ref[:cwd],
          session_id: session_ref["session_id"] || session_ref[:session_id]
        )
        metadata = (session_ref.fetch("metadata", {}) || {}).merge("session_file" => session_file).compact
        session_ref.merge("session_file" => session_file, "metadata" => metadata)
      end

      def text_from_session_file(session_ref)
        session_file = session_ref["session_file"] || session_ref[:session_file] || claude_session_file(
          cwd: session_ref["cwd"] || session_ref[:cwd],
          session_id: session_ref["session_id"] || session_ref[:session_id]
        )
        return nil unless present?(session_file) && File.file?(session_file)

        extract_last_assistant_text(read_session_records(session_file), "")
      end

      def read_session_records(session_file)
        records = []
        File.foreach(session_file) do |line|
          parsed = JSON.parse(line)
          records << parsed if parsed.is_a?(Hash)
          records.shift while records.length > 500
        rescue JSON::ParserError
          next
        end
        records
      rescue Errno::ENOENT, Errno::EACCES
        []
      end

      def claude_session_file(cwd:, session_id:)
        return nil unless present?(session_id)

        direct = File.join(claude_home, "projects", claude_project_dir_name(cwd), "#{session_id}.jsonl") if present?(cwd)
        return direct if direct && File.file?(direct)

        Dir.glob(File.join(claude_home, "projects", "**", "#{session_id}.jsonl")).find { |path| File.file?(path) }
      end

      def claude_project_dir_name(cwd)
        File.expand_path(cwd.to_s).tr("/", "-").delete(".")
      end
    end
  end
end
