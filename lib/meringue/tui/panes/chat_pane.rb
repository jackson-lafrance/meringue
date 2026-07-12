# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class ChatPane
        VISIBLE_SUGGESTION_LIMIT = 3
        MAX_CONVERSATION_ENTRY_LINES = 10

        def render(state)
          conversation_lines(state).map { |line| plain_text(line) }.join("\n")
        end

        def lines(state, width: nil)
          conversation_lines(state, width: width)
        end

        def conversation_lines(state, width: nil)
          messages = chat_state(state).fetch("messages", []) || []
          durable_pr_lines = durable_pr_conversation_lines(state, width: width)

          if messages.empty?
            return durable_pr_lines unless durable_pr_lines.empty?

            return [[["No conversation yet. Type a prompt below and press Enter.", Style::MUTED]]]
          end

          message_lines = messages.flat_map.with_index do |message, index|
            role = message.fetch("role", "meringue")
            style = role == "you" ? Style::USER : Style::ASSISTANT
            lines = [role_line(role, style)]
            lines.concat(wrapped_text_lines(message.fetch("text", ""), width: width, max_lines: MAX_CONVERSATION_ENTRY_LINES))
            lines << status_line(message.fetch("status")) if message.fetch("status", nil)
            lines << spacer_line unless index == messages.length - 1
            lines
          end

          durable_pr_lines.empty? ? message_lines : durable_pr_lines + [spacer_line] + message_lines
        end

        def composer_lines(state, width: nil)
          open_questions = state.fetch("questions", []).count { |question| question["status"] == "open" }
          chat = chat_state(state)
          input_buffer = chat.fetch("input_buffer", "").to_s
          input_cursor = chat.fetch("input_cursor", input_buffer.chars.length).to_i
          pending_count = chat.fetch("pending_count", 0).to_i

          input_lines = wrapped_input_lines(input_buffer, input_cursor: input_cursor, width: width)
          input_lines + [
            [["", Style::DIM]],
            [
              [pending_status(pending_count), pending_count.positive? ? Style::WARNING : Style::SUCCESS],
              ["  ·  ", Style::DIM],
              ["open questions: #{open_questions}", Style::MUTED],
              ["  ·  ", Style::DIM],
              ["enter sends · shift-enter newline · ctrl-c clears/quits · tab completes slash commands", Style::MUTED]
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

        def durable_pr_conversation_lines(state, width: nil)
          entries = persisted_pr_entries(state)
          return [] if entries.empty?

          lines = [role_line("worker PRs", Style::ASSISTANT)]
          entries.each do |entry|
            branch = entry.fetch("workspace_branch", nil)
            branch_text = branch.to_s.empty? ? "" : " (#{branch})"
            lines.concat(
              wrapped_text_lines(
                "#{entry.fetch("source_id", "worker")}#{branch_text}: #{entry.fetch("url")}",
                width: width,
                max_lines: MAX_CONVERSATION_ENTRY_LINES
              )
            )
          end
          lines
        end

        def persisted_pr_entries(state)
          seen = {}
          state.fetch("logs", []).filter_map do |log|
            details = log.fetch("details", {}) || {}
            Array(details["pr_urls"]).filter_map do |url|
              key = [log.fetch("source_id", nil), url]
              next if seen[key]

              seen[key] = true
              {
                "source_id" => log.fetch("source_id", nil),
                "workspace_branch" => details["workspace_branch"],
                "url" => url
              }
            end
          end.flatten.last(5)
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
          available_width = width ? [width.to_i - 2, 1].max : chars.length

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
          marker_index = chunk.index(cursor_marker)
          return [[prefix, Style::ACCENT_BOLD], [chunk, Style::TEXT]] unless marker_index

          before = chunk[0...marker_index]
          after = chunk[(marker_index + cursor_marker.length)..].to_s
          segments = [[prefix, Style::ACCENT_BOLD]]
          segments << [before, Style::TEXT] unless before.empty?
          segments << ["_", Style::ACCENT_BOLD]
          segments << [after, Style::TEXT] unless after.empty?
          segments
        end

        def wrapped_text_lines(text, width: nil, max_lines: nil)
          content_width = width ? [width.to_i - 2, 1].max : nil
          wrapped = text.to_s.split("\n", -1).flat_map do |line|
            wrap_text_line(line, content_width)
          end

          limited_lines(wrapped, max_lines).map { |line| text_line(line) }
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

        def limited_lines(lines, max_lines)
          return lines unless max_lines && lines.length > max_lines

          visible_count = [max_lines - 1, 0].max
          hidden_count = lines.length - visible_count
          lines.first(visible_count) + ["… #{hidden_count} more line#{hidden_count == 1 ? "" : "s"}"]
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
