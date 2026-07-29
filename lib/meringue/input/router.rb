# frozen_string_literal: true

module Meringue
  module Input
    class Router
      def initialize(slash_command_parser: SlashCommandParser.new)
        @slash_command_parser = slash_command_parser
      end

      # A selected AgentTree issue/agent is routing evidence for the head, not a
      # shortcut around it. Natural-language input therefore remains a SpawnHead
      # command and carries only the selected node id for the kernel to resolve
      # against its current state. Slash commands keep their explicit clutch-path
      # semantics and intentionally ignore dashboard selection.
      def route(input, selected_target: nil)
        text = input.to_s
        stripped = text.strip

        if stripped.start_with?("/")
          command = slash_command_parser.parse(stripped)
          return {
            "kind" => "slash_command",
            "input" => stripped,
            "commands" => [command.to_h]
          }
        end

        payload = { "user_message" => text }
        normalized_target = normalize_selected_target(selected_target)
        payload["selected_target"] = normalized_target if normalized_target

        {
          "kind" => "natural_language",
          "commands" => [
            Meringue::Kernel::Command.new(
              type: "SpawnHead",
              payload: payload
            ).to_h
          ]
        }
      end

      private

      attr_reader :slash_command_parser

      def normalize_selected_target(selected_target)
        selected_id = if selected_target.is_a?(Hash)
                        selected_target["selected_id"] || selected_target[:selected_id] ||
                          selected_target["id"] || selected_target[:id]
                      else
                        selected_target
                      end
        selected_id = selected_id.to_s.strip
        return nil if selected_id.empty?

        { "selected_id" => selected_id }
      end
    end
  end
end
