# frozen_string_literal: true

require "json"

module Meringue
  module Heads
    class InvalidHeadResultError < StandardError
      attr_reader :raw_output, :validation_errors

      def initialize(raw_output:, validation_errors:)
        @raw_output = raw_output
        @validation_errors = validation_errors
        super("Head returned invalid HeadResult JSON: #{validation_errors.join(", ")}")
      end
    end

    module ResultParser
      JSON_SCHEMA = {
        "type" => "object",
        "additionalProperties" => true,
        "required" => %w[title summary commands questions],
        "properties" => {
          "title" => { "type" => "string" },
          "summary" => { "type" => "string" },
          "commands" => {
            "type" => "array",
            "items" => {
              "type" => "object",
              "required" => %w[type payload],
              "properties" => {
                "type" => { "type" => "string" },
                "payload" => { "type" => "object" }
              }
            }
          },
          "questions" => {
            "type" => "array",
            "items" => {
              "type" => "object",
              "required" => ["question"],
              "properties" => {
                "question" => { "type" => "string" },
                "context" => { "type" => ["object", "string", "null"] }
              }
            }
          }
        }
      }.freeze

      module_function

      def parse(raw_output)
        result = parse_json_object(raw_output)
        validate!(result, raw_output)
        result
      end

      def json_schema
        JSON.generate(JSON_SCHEMA)
      end

      def parse_json_object(raw_output)
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

      def validate!(result, raw_output)
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
