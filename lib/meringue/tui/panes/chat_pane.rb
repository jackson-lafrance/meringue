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

        def conversation_lines(state)
          messages = chat_state(state).fetch("messages", []) || []
          return [[["No conversation yet. Type a prompt below and press Enter.", Style::MUTED]]] if messages.empty?

          messages.flat_map.with_index do |message, index|
            role = message.fetch("role", "meringue")
            style = role == "you" ? Style::USER : Style::ASSISTANT
            lines = [role_line(role, style)]
            lines.concat(wrapped_text_lines(message.fetch("text", "")))
            lines << status_line(message.fetch("status")) if message.fetch("status", nil)
            lines << spacer_line unless index == messages.length - 1
            lines
          end
        end

        def composer_lines(state)
          open_questions = state.fetch("questions", []).count { |question| question["status"] == "open" }
          chat = chat_state(state)
          input_buffer = chat.fetch("input_buffer", "").to_s
          pending_count = chat.fetch("pending_count", 0).to_i
          placeholder = input_buffer.empty? ? "enter a prompt" : input_buffer
          input_line = [
            ["›", Style::ACCENT_BOLD],
            [" #{placeholder}", input_buffer.empty? ? Style::MUTED : Style::TEXT]
          ]
          input_line << ["_", Style::ACCENT_BOLD] unless input_buffer.empty?

          [
            input_line,
            [["", Style::DIM]],
            [
              [pending_status(pending_count), pending_count.positive? ? Style::WARNING : Style::SUCCESS],
              ["  ·  ", Style::DIM],
              ["open questions: #{open_questions}", Style::MUTED],
              ["  ·  ", Style::DIM],
              ["enter sends · /clear resets · esc/ctrl-c quits", Style::MUTED]
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

        def status_line(status)
          [
            ["  ", Style::DIM],
            [status.to_s, Style::MUTED]
          ]
        end

        def wrapped_text_lines(text)
          text.to_s.split("\n", -1).map do |line|
            text_line(line)
          end
        end

        def pending_status(pending_count)
          return "head loop idle" unless pending_count.positive?

          "#{pending_count} prompt#{pending_count == 1 ? "" : "s"} running"
        end

        def chat_state(state)
          state.fetch("_chat", {}) || {}
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
