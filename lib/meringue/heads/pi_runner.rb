# frozen_string_literal: true

require "json"

module Meringue
  module Heads
    class PiRunner < Runner
      HEAD_SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a Meringue head agent.

        Decide how a user request should be represented as Meringue kernel commands.
        Do not edit files. Do not mutate Meringue state. Return structured JSON only.

        The only valid response shape is:
        {
          "title": "Short display title",
          "summary": "Short user-visible summary",
          "commands": [],
          "questions": []
        }

        Commands must be structured kernel command objects, not prose. Use this shape:
        { "type": "CreateIssue", "payload": { "project_id": "P1", "title": "...", "description": "..." } }

        Common MVP command types are AddProject, CreateIssue, ModifyIssue, SpawnWorker,
        PromptAgent, AskQuestion, AnswerQuestion, Kill, and ListAll.

        Questions should only be used when ambiguity would likely cause bad work.
      PROMPT

      class InvalidHeadResultError < StandardError
        attr_reader :raw_output, :validation_errors

        def initialize(raw_output:, validation_errors:)
          @raw_output = raw_output
          @validation_errors = validation_errors
          super("Pi head returned invalid HeadResult JSON: #{validation_errors.join(", ")}")
        end
      end

      attr_reader :harness_client, :cwd, :session_name_prefix, :timeout

      def initialize(harness_client:, cwd: Dir.pwd, session_name_prefix: "Meringue Head",
                     timeout: Meringue::Harness::PiClient::DEFAULT_EVENT_TIMEOUT)
        @harness_client = harness_client
        @cwd = File.expand_path(cwd)
        @session_name_prefix = session_name_prefix
        @timeout = timeout
      end

      def run(user_message:, snapshot:, question_id: nil)
        session_ref = harness_client.spawn_session(
          kind: "head",
          cwd: cwd,
          prompt: nil,
          system_prompt: HEAD_SYSTEM_PROMPT,
          session_name: session_name(user_message)
        )

        harness_client.prompt_session(session_ref, head_prompt(user_message, snapshot, question_id), mode: "normal")
        harness_client.wait_for_settled(session_ref, timeout: timeout)
        raw_output = harness_client.last_assistant_text(session_ref).to_s
        result = parse_head_result(raw_output)
        validate_head_result!(result, raw_output)
        result
      ensure
        harness_client.kill_session(session_ref) if session_ref
      end

      private

      def session_name(user_message)
        title = user_message.to_s.strip.gsub(/\s+/, " ")[0, 48]
        title = "untitled request" if title.empty?
        "#{session_name_prefix}: #{title}"
      end

      def head_prompt(user_message, snapshot, question_id)
        <<~PROMPT
          Return only a JSON object matching the Meringue HeadResult contract.

          User message:
          #{user_message}

          Question ID, if this is answering a prior question:
          #{question_id || "null"}

          Current Meringue state snapshot JSON:
          #{JSON.pretty_generate(snapshot || {})}
        PROMPT
      end

      def parse_head_result(raw_output)
        JSON.parse(raw_output.strip)
      rescue JSON::ParserError => e
        raise InvalidHeadResultError.new(raw_output: raw_output, validation_errors: [e.message])
      end

      def validate_head_result!(result, raw_output)
        errors = []
        errors << "result must be a JSON object" unless result.is_a?(Hash)

        if result.is_a?(Hash)
          errors << "title must be a string" unless result["title"].is_a?(String)
          errors << "summary must be a string" unless result["summary"].is_a?(String)
          errors << "commands must be an array" unless result["commands"].is_a?(Array)
          errors << "questions must be an array" unless result["questions"].is_a?(Array)
        end

        return if errors.empty?

        raise InvalidHeadResultError.new(raw_output: raw_output, validation_errors: errors)
      end
    end
  end
end
