# frozen_string_literal: true

module Meringue
  module Input
    class Router
      def initialize(slash_command_parser: SlashCommandParser.new)
        @slash_command_parser = slash_command_parser
      end

      def route(input)
        text = input.to_s
        stripped = text.strip

        if stripped.start_with?("/")
          command = slash_command_parser.parse(stripped)
          return {
            "kind" => "slash_command",
            "commands" => [command.to_h]
          }
        end

        {
          "kind" => "natural_language",
          "commands" => [
            Meringue::Kernel::Command.new(
              type: "SpawnHead",
              payload: { "user_message" => text }
            ).to_h
          ]
        }
      end

      private

      attr_reader :slash_command_parser
    end
  end
end
