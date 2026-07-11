# frozen_string_literal: true

module Meringue
  module Input
    class SlashCommandParser
      def parse(input)
        stripped = input.to_s.strip
        return nil unless stripped.start_with?("/")

        command_text, arguments = stripped.delete_prefix("/").split(/\s+/, 2)

        Meringue::Kernel::Command.new(
          type: "SlashCommand",
          payload: {
            "name" => command_text,
            "arguments" => arguments.to_s,
            "raw" => stripped
          }
        )
      end
    end
  end
end
