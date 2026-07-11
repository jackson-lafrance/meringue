# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class ChatPane
        def render(state)
          lines(state).join("\n")
        end

        def lines(state)
          open_questions = state.fetch("questions", []).count { |question| question["status"] == "open" }

          [
            "User > Build the TUI demo rendering only.",
            "Head > Fake state loaded; no Pi sessions, workers, or kernel mutations were started.",
            "",
            "Input preview",
            "> ask meringue to split this work across two agents_",
            "Slash commands later: /help /tree /state /questions /answer",
            "Open questions: #{open_questions} | Press q, Esc, or Ctrl-C to quit."
          ]
        end
      end
    end
  end
end
