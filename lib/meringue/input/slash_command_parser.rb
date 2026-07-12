# frozen_string_literal: true

module Meringue
  module Input
    class SlashCommandParser
      def parse(input)
        stripped = input.to_s.strip
        return nil unless stripped.start_with?("/")

        command_text, arguments = stripped.delete_prefix("/").split(/\s+/, 2)
        command_text = command_text.to_s.downcase
        arguments = arguments.to_s

        case command_text
        when "clear"
          Meringue::Kernel::Command.new(type: "ClearState", payload: {})
        when "answer"
          question_id, answer = parse_answer_arguments(arguments)
          Meringue::Kernel::Command.new(
            type: "AnswerQuestion",
            payload: {
              "question_id" => question_id,
              "answer" => answer
            }
          )
        else
          Meringue::Kernel::Command.new(
            type: "SlashCommand",
            payload: {
              "name" => command_text,
              "arguments" => arguments,
              "raw" => stripped
            }
          )
        end
      end

      private

      def parse_answer_arguments(arguments)
        question_id, answer = arguments.to_s.strip.split(/\s+/, 2)
        [question_id, unquote(answer.to_s.strip)]
      end

      def unquote(text)
        if (text.start_with?("\"") && text.end_with?("\"")) || (text.start_with?("'") && text.end_with?("'"))
          text[1...-1]
        else
          text
        end
      end
    end
  end
end
