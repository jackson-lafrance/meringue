# frozen_string_literal: true

require "json"

module Meringue
  module Heads
    class PiRunner < Runner
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

      def run(user_message:, snapshot:, context: nil, question_id: nil)
        context ||= Context.new(
          head_id: "H?",
          user_message: user_message,
          snapshot: snapshot,
          question_id: question_id,
          cwd: cwd
        )

        session_ref = harness_client.spawn_session(
          kind: "head",
          cwd: cwd,
          prompt: nil,
          system_prompt: context.system_prompt,
          session_name: session_name(context)
        )

        session_ref = harness_client.prompt_session(session_ref, head_prompt(context), mode: "normal")
        harness_client.wait_for_settled(session_ref, timeout: timeout)
        raw_output = harness_client.last_assistant_text(session_ref).to_s
        result = parse_head_result(raw_output)
        validate_head_result!(result, raw_output)
        result
      ensure
        harness_client.kill_session(session_ref) if session_ref
      end

      private

      def session_name(context)
        title = context.user_message.to_s.strip.gsub(/\s+/, " ")[0, 48]
        title = "untitled request" if title.empty?
        "#{session_name_prefix} #{context.head_id}: #{title}"
      end

      def head_prompt(context)
        <<~PROMPT
          Return only a JSON object matching the Meringue HeadResult contract.

          The kernel command reference has already been appended to your system prompt.
          Use the context JSON below to decide which kernel command to propose.
          When the project is unclear, use your read-only tools to inspect local repositories before returning the final JSON.

          Meringue head context JSON:
          #{JSON.pretty_generate(context.to_prompt_h)}
        PROMPT
      end

      def parse_head_result(raw_output)
        text = raw_output.to_s.strip
        candidates = [text]
        fenced_json = first_fenced_json(text)
        candidates << fenced_json if fenced_json
        extracted_json = first_json_object(text)
        candidates << extracted_json if extracted_json

        candidates.each do |candidate|
          return JSON.parse(candidate)
        rescue JSON::ParserError
          next
        end

        raise InvalidHeadResultError.new(
          raw_output: raw_output,
          validation_errors: ["assistant output was not parseable JSON"]
        )
      end

      def first_fenced_json(text)
        match = text.match(/```(?:json)?\s*(.*?)```/m)
        match && match[1].strip
      end

      def first_json_object(text)
        start_index = text.index("{")
        return nil unless start_index

        depth = 0
        in_string = false
        escaped = false

        text.chars.each_with_index do |char, index|
          next if index < start_index

          if in_string
            if escaped
              escaped = false
            elsif char == "\\"
              escaped = true
            elsif char == '"'
              in_string = false
            end
            next
          end

          case char
          when '"'
            in_string = true
          when "{"
            depth += 1
          when "}"
            depth -= 1
            return text[start_index..index] if depth.zero?
          end
        end

        nil
      end

      def validate_head_result!(result, raw_output)
        errors = []
        errors << "result must be a JSON object" unless result.is_a?(Hash)

        if result.is_a?(Hash)
          errors << "title must be a string" unless result["title"].is_a?(String)
          errors << "summary must be a string" unless result["summary"].is_a?(String)
          validate_commands(result["commands"], errors)
          validate_questions(result["questions"], errors)
        end

        return if errors.empty?

        raise InvalidHeadResultError.new(raw_output: raw_output, validation_errors: errors)
      end

      def validate_commands(commands, errors)
        unless commands.is_a?(Array)
          errors << "commands must be an array"
          return
        end

        commands.each_with_index do |command, index|
          unless command.is_a?(Hash)
            errors << "commands[#{index}] must be an object"
            next
          end

          errors << "commands[#{index}].type must be a string" unless command["type"].is_a?(String)
          errors << "commands[#{index}].payload must be an object" unless command["payload"].is_a?(Hash)
        end
      end

      def validate_questions(questions, errors)
        unless questions.is_a?(Array)
          errors << "questions must be an array"
          return
        end

        questions.each_with_index do |question, index|
          unless question.is_a?(Hash)
            errors << "questions[#{index}] must be an object"
            next
          end

          errors << "questions[#{index}].question must be a string" unless question["question"].is_a?(String)
        end
      end
    end
  end
end
