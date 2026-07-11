# frozen_string_literal: true

module Meringue
  module TUI
    class Layout
      def render(state)
        [
          "Meringue TUI scaffold",
          "Projects: #{state.fetch("projects", []).length}",
          "Issues: #{state.fetch("issues", []).length}",
          "Agents: #{state.fetch("agents", []).length}",
          "Logs: #{state.fetch("logs", []).length}"
        ].join("\n")
      end
    end
  end
end
