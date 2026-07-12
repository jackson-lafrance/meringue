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
          durable_pr_lines = durable_pr_conversation_lines(state)

          if messages.empty?
            return durable_pr_lines unless durable_pr_lines.empty?

            return [[["No conversation yet. Type a prompt below and press Enter.", Style::MUTED]]]
          end

          message_lines = messages.flat_map.with_index do |message, index|
            role = message.fetch("role", "meringue")
            style = role == "you" ? Style::USER : Style::ASSISTANT
            lines = [role_line(role, style)]
            lines.concat(wrapped_text_lines(message.fetch("text", "")))
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
          pending_count = chat.fetch("pending_count", 0).to_i

          input_lines = wrapped_input_lines(input_buffer, width: width)
          input_lines + [
            [["", Style::DIM]],
            [
              [pending_status(pending_count), pending_count.positive? ? Style::WARNING : Style::SUCCESS],
              ["  ·  ", Style::DIM],
              ["open questions: #{open_questions}", Style::MUTED],
              ["  ·  ", Style::DIM],
              ["enter sends · shift/alt-enter newline · tab completes slash commands · esc/ctrl-c quits", Style::MUTED]
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

        def durable_pr_conversation_lines(state)
          entries = persisted_pr_entries(state)
          return [] if entries.empty?

          lines = [role_line("worker PRs", Style::ASSISTANT)]
          entries.each do |entry|
            branch = entry.fetch("workspace_branch", nil)
            branch_text = branch.to_s.empty? ? "" : " (#{branch})"
            lines << text_line("#{entry.fetch("source_id", "worker")}#{branch_text}: #{entry.fetch("url")}")
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

        def wrapped_input_lines(input_buffer, width: nil)
          if input_buffer.empty?
            return [[
              ["›", Style::ACCENT_BOLD],
              [" enter a prompt", Style::MUTED]
            ]]
          end

          display_text = "#{input_buffer}_"
          content_width = input_content_width(display_text, width)
          logical_lines = display_text.split("\n", -1)
          rows = []

          logical_lines.each_with_index do |logical_line, logical_index|
            chunks = wrapped_input_chunks(logical_line, content_width)
            chunks.each_with_index do |chunk, chunk_index|
              cursor_line = logical_index == logical_lines.length - 1 && chunk_index == chunks.length - 1
              rows << input_line_segments(chunk, first_line: rows.empty?, cursor_line: cursor_line)
            end
          end

          rows
        end

        def input_content_width(display_text, width)
          return [display_text.lines.map { |line| line.chomp.length }.max.to_i, 1].max unless width

          [width.to_i - input_prefix_width, 1].max
        end

        def input_prefix_width
          2
        end

        def wrapped_input_chunks(text, content_width)
          return [""] if text.empty?

          text.chars.each_slice(content_width).map(&:join)
        end

        def input_line_segments(chunk, first_line:, cursor_line:)
          prefix = first_line ? "› " : "  "
          prefix_style = first_line ? Style::ACCENT_BOLD : Style::DIM
          return [[prefix, prefix_style], [chunk, Style::TEXT]] unless cursor_line && chunk.end_with?("_")

          text = chunk[0...-1]
          segments = [[prefix, prefix_style]]
          segments << [text, Style::TEXT] unless text.empty?
          segments << ["_", Style::ACCENT_BOLD]
          segments
        end

        def wrapped_text_lines(text)
          text.to_s.split("\n", -1).map do |line|
            text_line(line)
          end
        end

        def pending_status(pending_count)
          return "head loop idle" unless pending_count.positive?

          "#{pending_count} head prompt#{pending_count == 1 ? "" : "s"} in flight"
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
