# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class ChatPane
        def render(state)
          conversation_lines(state).map { |line| plain_text(line) }.join("\n")
        end

        def lines(state)
          conversation_lines(state)
        end

        def conversation_lines(_state)
          [
            role_line("you", Style::USER),
            text_line("Okay now that we have an empty project structure, build out the TUI demo."),
            text_line("Rendering only: fake chat box, demo AgentTree, and demo logs."),
            spacer_line,
            role_line("meringue", Style::ASSISTANT),
            text_line("Built a fake-state rendering pass from fixtures/demo_state.json."),
            text_line("No Pi process, worker prompt, or real state mutation is happening here."),
            action_line("AgentTree", "shows projects, issues, heads, workers, and questions"),
            action_line("Activity", "shows durable logs from user, kernel, head, worker, and harness sources")
          ]
        end

        def composer_lines(state)
          open_questions = state.fetch("questions", []).count { |question| question["status"] == "open" }

          [
            [
              ["›", Style::ACCENT_BOLD],
              [" ask meringue to split signup work across two workers", Style::TEXT],
              ["_", Style::ACCENT_BOLD]
            ],
            [["", Style::DIM]],
            [
              ["fake input only", Style::WARNING],
              ["  ·  ", Style::DIM],
              ["open questions: #{open_questions}", Style::MUTED],
              ["  ·  ", Style::DIM],
              ["q / esc / ctrl-c quits", Style::MUTED]
            ]
          ]
        end

        private

        def role_line(role, style)
          [
            ["✦", style],
            [" #{role}", style]
          ]
        end

        def text_line(text)
          [
            ["  ", Style::DIM],
            [text, Style::TEXT]
          ]
        end

        def action_line(label, detail)
          [
            ["  • ", Style::ACCENT],
            [label, Style::TITLE],
            [" — #{detail}", Style::MUTED]
          ]
        end

        def spacer_line
          [["", Style::DIM]]
        end

        def plain_text(line)
          return line.to_s unless line.is_a?(Array)

          line.map { |segment| segment.is_a?(Array) ? segment.first.to_s : segment.to_s }.join
        end
      end
    end
  end
end
