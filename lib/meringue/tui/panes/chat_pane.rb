# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class ChatPane
        VISIBLE_SUGGESTION_LIMIT = 3

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

        def composer_lines(state, width: nil)
          open_questions = state.fetch("questions", []).count { |question| question["status"] == "open" }
          chat = chat_state(state)
          input_buffer = chat.fetch("input_buffer", "").to_s
          pending_count = chat.fetch("pending_count", 0).to_i

          input_lines = wrapped_input_lines(input_buffer, width: width)
          input_lines + [
            [["", Style::DIM]],
            [
              [pending_status(pending_count), pending_count.positive? ? Style::WARNING : Style::SUCCESS],
              ["  ·  ", Style::DIM],
              ["open questions: #{open_questions}", Style::MUTED],
              ["  ·  ", Style::DIM],
              ["enter sends · tab completes slash commands · esc/ctrl-c quits", Style::MUTED]
            ]
          ]
        end

        def slash_suggestions?(state)
          slash_suggestion_records(state).any?
        end

        def slash_suggestion_lines(state)
          records = slash_suggestion_records(state)
          return [[["No matching slash commands.", Style::MUTED]]] if slash_prompt?(chat_state(state).fetch("input_buffer", "")) && records.empty?

          selected_index = selected_slash_suggestion_index(state, records.length)
          window_start = slash_suggestion_window_start(records.length, selected_index)
          records.drop(window_start).first(VISIBLE_SUGGESTION_LIMIT).map.with_index do |record, offset|
            selected = window_start + offset == selected_index
            marker = selected ? "›" : " "
            marker_style = selected ? Style::ACCENT_BOLD : Style::DIM
            usage_style = selected ? Style::ACCENT_BOLD : Style::TEXT
            [
              ["#{marker} ", marker_style],
              [record.fetch("usage"), usage_style],
              [" — #{record.fetch("description")}", Style::MUTED]
            ]
          end
        end

        def slash_suggestion_records(state)
          input_buffer = chat_state(state).fetch("input_buffer", "")
          return [] unless slash_prompt?(input_buffer)

          Meringue::Input::SlashCommandParser.command_suggestion_records(input_buffer, limit: nil, state: state)
        end

        def slash_prompt?(input_buffer)
          input_buffer.to_s.strip.start_with?("/")
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

        def wrapped_input_lines(input_buffer, width: nil)
          if input_buffer.empty?
            return [[
              ["›", Style::ACCENT_BOLD],
              [" enter a prompt", Style::MUTED]
            ]]
          end

          display_text = "#{input_buffer}_"
          available_width = width ? [width.to_i - 2, 1].max : display_text.length
          chunks = display_text.chars.each_slice(available_width).map(&:join)
          chunks.each_with_index.map do |chunk, index|
            input_line_segments(chunk, first_line: index.zero?, cursor_line: index == chunks.length - 1)
          end
        end

        def input_line_segments(chunk, first_line:, cursor_line:)
          prefix = first_line ? "› " : "  "
          return [[prefix, Style::ACCENT_BOLD], [chunk, Style::TEXT]] unless cursor_line && chunk.end_with?("_")

          text = chunk[0...-1]
          [[prefix, Style::ACCENT_BOLD], [text, Style::TEXT], ["_", Style::ACCENT_BOLD]]
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

        def selected_slash_suggestion_index(state, count)
          return 0 unless count.positive?

          chat_state(state).fetch("slash_suggestion_index", 0).to_i.clamp(0, count - 1)
        end

        def slash_suggestion_window_start(count, selected_index)
          return 0 if count <= VISIBLE_SUGGESTION_LIMIT

          max_start = count - VISIBLE_SUGGESTION_LIMIT
          [selected_index - VISIBLE_SUGGESTION_LIMIT + 1, 0].max.clamp(0, max_start)
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
