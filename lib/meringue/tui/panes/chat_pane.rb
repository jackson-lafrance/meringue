# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class ChatPane
        VISIBLE_SUGGESTION_LIMIT = 3
        MAX_CONVERSATION_ENTRY_LINES = 10
        AGENT_ICON = "✦"
        USER_ICON = "●"

        def render(state)
          conversation_lines(state).map { |line| plain_text(line) }.join("\n")
        end

        def lines(state, width: nil)
          conversation_lines(state, width: width)
        end

        def conversation_lines(state, width: nil)
          messages = visible_messages(chat_state(state).fetch("messages", []) || [])

          if messages.empty?
            return [[["No conversation yet. Type a prompt below and press Enter.", Style::MUTED]]]
          end

          messages.flat_map.with_index do |message, index|
            role = message.fetch("role", "meringue")
            style = role == "you" ? Style::USER : Style::ASSISTANT
            lines = [role_line(role, style)]
            lines.concat(wrapped_text_lines(message.fetch("text", ""), width: width))
            lines << status_line(message.fetch("status")) if message.fetch("status", nil)
            lines << spacer_line unless index == messages.length - 1
            lines
          end
        end

        def composer_lines(state, width: nil)
          chat = chat_state(state)
          input_buffer = chat.fetch("input_buffer", "").to_s
          input_cursor = chat.fetch("input_cursor", input_buffer.chars.length).to_i

          wrapped_input_lines(input_buffer, input_cursor: input_cursor, width: width)
        end

        def bottom_hint_line(state)
          chat = chat_state(state)
          pending_count = chat.fetch("pending_count", 0).to_i
          prefix = compact_status_segments(state, pending_count)
          open_questions = state.fetch("questions", []).count { |question| question["status"] == "open" }
          if open_questions.positive?
            prefix += [["  ·  ", Style::DIM]] unless prefix.empty?
            prefix += [["? #{open_questions}", Style::WARNING]]
          end
          separator = prefix.empty? ? [] : [["  ·  ", Style::DIM]]

          prefix + separator + interaction_hint_segments
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

        def visible_messages(messages)
          messages.select { |message| visible_message?(message) }
        end

        def visible_message?(message)
          return false if message.fetch("visible", true) == false

          !message.fetch("text", "").to_s.strip.empty?
        end

        def role_line(role, style)
          [
            [role == "you" ? USER_ICON : AGENT_ICON, style],
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

        def wrapped_input_lines(input_buffer, input_cursor:, width: nil)
          if input_buffer.empty?
            return [[
              ["›", Style::ACCENT_BOLD],
              [" enter a prompt", Style::MUTED]
            ]]
          end

          cursor_marker = "\u0000"
          chars = input_buffer.chars
          cursor = input_cursor.to_i.clamp(0, chars.length)
          chars.insert(cursor, cursor_marker)
          available_width = width ? [width.to_i - 2, 1].max : [chars.length, 1].max

          rows = []
          chars.join.split("\n", -1).each do |logical_line|
            chunks = logical_line.empty? ? [""] : logical_line.chars.each_slice(available_width).map(&:join)
            chunks.each do |chunk|
              rows << input_line_segments(chunk, first_line: rows.empty?, cursor_marker: cursor_marker)
            end
          end
          rows
        end

        def input_line_segments(chunk, first_line:, cursor_marker:)
          prefix = first_line ? "› " : "  "
          prefix_style = first_line ? Style::ACCENT_BOLD : Style::DIM
          marker_index = chunk.index(cursor_marker)
          return [[prefix, prefix_style], [chunk, Style::TEXT]] unless marker_index

          before = chunk[0...marker_index]
          after = chunk[(marker_index + cursor_marker.length)..].to_s
          segments = [[prefix, prefix_style]]
          segments << [before, Style::TEXT] unless before.empty?
          segments << ["_", Style::ACCENT_BOLD]
          segments << [after, Style::TEXT] unless after.empty?
          segments
        end

        def wrapped_text_lines(text, width: nil)
          content_width = width ? [width.to_i - 2, 1].max : nil
          text.to_s.split("\n", -1).flat_map do |line|
            wrap_text_line(line, content_width)
          end.map { |line| text_line(line) }
        end

        def wrap_text_line(line, width)
          return [line] unless width && line.length > width

          chunks = []
          remaining = line.dup
          until remaining.empty?
            if remaining.length <= width
              chunks << remaining
              break
            end

            break_at = remaining.rindex(/\s/, width)
            if break_at&.positive?
              chunks << remaining[0...break_at]
              remaining = remaining[(break_at + 1)..].to_s.lstrip
            else
              chunks << remaining[0...width]
              remaining = remaining[width..].to_s.lstrip
            end
          end
          chunks
        end

        def interaction_hint_segments
          [
            ["Enter sends", Style::MUTED],
            [" • ", Style::DIM],
            ["Shift+Enter newline", Style::MUTED],
            [" • ", Style::DIM],
            ["Ctrl-C clears/quits", Style::MUTED],
            [" • ", Style::DIM],
            ["Tab/⇧Tab focus", Style::MUTED],
            [" • ", Style::DIM],
            ["arrows/mouse scroll", Style::MUTED],
            [" • ", Style::DIM],
            ["/keybind help", Style::MUTED]
          ]
        end

        def compact_status_segments(state, pending_count)
          working_workers = active_agent_count(state, "worker")
          working_heads = active_agent_count(state, "head")
          return active_status_segments(working_workers, working_heads) if working_workers.positive? || working_heads.positive?
          return [[prompt_count_label(pending_count), Style::ACCENT]] if pending_count.positive?

          []
        end

        def active_status_segments(working_workers, working_heads)
          segments = [["● active", Style::ACCENT_BOLD]]
          metrics = []
          metrics << ["#{working_workers}W", Style::WORKING] if working_workers.positive?
          metrics << ["#{working_heads}H", Style::ACCENT_BOLD] if working_heads.positive?
          metrics.each_with_index do |metric, index|
            segments << [index.zero? ? "  " : " ", Style::DIM]
            segments << metric
          end
          segments
        end

        def active_agent_count(state, type)
          state.fetch("agents", []).count do |agent|
            agent["type"] == type && agent["status"] == "working"
          end
        end

        def prompt_count_label(pending_count)
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
