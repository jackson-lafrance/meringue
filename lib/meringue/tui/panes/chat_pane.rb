# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    module Panes
      class ChatPane
        VISIBLE_SUGGESTION_LIMIT = 3
        HEAD_ICON = "◆"
        WORKER_ICON = "✦"
        RESULT_ICON = "✓"
        ERROR_ICON = "!"
        KERNEL_ICON = "▪"
        # Matches TUI::App::NO_SLASH_SELECTION: no suggestion is highlighted until the user navigates.
        NO_SLASH_SELECTION = -1
        USER_ICON = "●"
        AGENT_GUTTER = "▌ "
        PLAIN_GUTTER = "  "

        def render(state)
          log_lines(state).map { |line| plain_text(line) }.join("\n")
        end

        def lines(state, width: nil)
          log_lines(state, width: width)
        end

        def log_lines(state, width: nil)
          entries = log_entries(state)

          if entries.empty?
            return [[["No logs yet. Type a prompt below and press Enter.", Style::MUTED]]]
          end

          selected_agent_id = AgentTreeNavigation.selected_agent_id(state)
          entries.flat_map do |entry|
            gutter = gutter_segment(entry)
            lines = [role_line(entry, selected_agent_id: selected_agent_id)]
            lines.concat(body_lines(entry, width: width, gutter: gutter))
            lines << status_line(entry.fetch("status"), gutter) if entry.fetch("kind", nil) == "message" && entry.fetch("status", nil)
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

        def bottom_right_status_line(state)
          label = active_harness_label(state)
          return [] if label.empty?

          [["harness: ", Style::DIM], [label, Style::ACCENT_BOLD]]
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

        def log_entries(state)
          message_entries = visible_messages(chat_state(state).fetch("messages", []) || []).map.with_index { |message, index| message_entry(message, index, state) }
          durable_log_entries = Array(state.fetch("logs", [])).map.with_index { |entry, index| log_entry(entry, index, state) }.compact
          message_topics = topic_index(message_entries)
          durable_log_entries = durable_log_entries.reject { |entry| redundant_lifecycle_log?(entry, message_topics) }
          duplicate_log_texts = duplicate_text_index(durable_log_entries)
          entries = message_entries.filter_map { |entry| deduplicate_message_entry(entry, duplicate_log_texts) } + durable_log_entries
          entries.each_with_index { |entry, sequence| entry["sequence"] = sequence }
          entries.sort_by { |entry| entry_sort_key(entry) }
        end

        def visible_messages(messages)
          messages.select { |message| visible_message?(message) }
        end

        def visible_message?(message)
          return false if message.fetch("visible", true) == false

          !message.fetch("text", "").to_s.strip.empty?
        end

        def topic_index(entries)
          entries.each_with_object({}) do |entry, topics|
            key = event_topic_key(entry)
            topics[key] = true if key
          end
        end

        def event_topic_key(entry)
          return nil unless entry.fetch("kind", nil) == "message"
          return nil unless entry.fetch("role", nil) == "agent"

          source_id = entry.fetch("source_id", nil).to_s
          return nil if source_id.empty?

          "worker_completed:#{source_id}"
        end

        def redundant_lifecycle_log?(entry, message_topics)
          source_id = entry.fetch("source_id", nil).to_s
          return false unless message_topics["worker_completed:#{source_id}"]

          message = entry.fetch("message", entry.fetch("text", "")).to_s
          entry.fetch("source_type", nil) == "worker" && message == "Worker #{source_id} completed."
        end

        def duplicate_text_index(entries)
          entries.each_with_object({}) do |entry, index|
            text = normalized_duplicate_text(entry.fetch("text", ""))
            index[text] = true unless text.empty?
          end
        end

        def deduplicate_message_entry(entry, duplicate_texts)
          text = entry.fetch("text", "").to_s
          return nil if duplicate_texts[normalized_duplicate_text(text)]

          lines = text.lines.map(&:chomp)
          return entry unless lines.length > 1 && duplicate_texts[normalized_duplicate_text(lines.first)]

          trimmed_text = lines.drop(1).join("\n").strip
          return nil if trimmed_text.empty?

          entry.merge("text" => trimmed_text)
        end

        def normalized_duplicate_text(text)
          text.to_s.gsub(/[[:space:]]+/, " ").strip
        end

        def message_entry(message, index, state = {})
          role = normalized_message_role(message.fetch("role", "meringue"))
          source_id = message.fetch("source_id", nil)
          {
            "kind" => "message",
            "timestamp" => message.fetch("timestamp", nil),
            "role" => role,
            "source_id" => source_id,
            "text" => message.fetch("text", "").to_s,
            "status" => message.fetch("status", nil),
            "agent" => agent_by_id(state, source_id),
            "ordinal" => index
          }
        end

        def log_entry(entry, index, state)
          return nil unless entry.is_a?(Hash)

          source_type = entry.fetch("source_type", "system").to_s
          source_id = entry.fetch("source_id", nil)
          role = log_role(source_type, source_id)
          {
            "kind" => "log",
            "timestamp" => entry.fetch("timestamp", nil),
            "role" => role,
            "source_type" => source_type,
            "source_id" => source_id,
            "text" => log_display_text(entry),
            "message" => entry.fetch("message", "").to_s,
            "details" => entry.fetch("details", {}) || {},
            "status" => log_status(entry),
            "level" => entry.fetch("level", "info"),
            "presentation" => log_presentation(entry),
            "agent" => agent_by_id(state, source_id),
            "ordinal" => index
          }
        end

        def log_display_text(entry)
          worker_completion_text(entry) || entry.fetch("message", "").to_s
        end

        def worker_completion_text(entry)
          return nil unless worker_completion_entry?(entry)

          source_id = entry.fetch("source_id").to_s
          details = entry.fetch("details", {}) || {}
          details = {} unless details.is_a?(Hash)
          pr_urls = worker_completion_pr_urls(details)
          output = AgentOutput.normalize(details["last_assistant_text"], source_id: source_id, pr_urls: pr_urls)
          lines = pr_urls.map { |url| "PR  #{url}" }
          lines << output unless output.empty?
          lines.empty? ? "Completed." : lines.join("\n")
        end

        def worker_completion_entry?(entry)
          source_id = entry.fetch("source_id", nil).to_s
          !source_id.empty? &&
            entry.fetch("source_type", nil).to_s == "worker" &&
            entry.fetch("message", "").to_s == "Worker #{source_id} completed."
        end

        def worker_completion_pr_urls(details)
          delivery_pull_requests = [
            details["delivery_pull_request"],
            *Array(details["delivery_pull_requests"])
          ].compact
          delivery_pull_requests.filter_map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }.compact.map(&:to_s).reject(&:empty?).uniq
        end

        def log_presentation(entry)
          return "result" if worker_completion_entry?(entry)
          return "error" if entry.fetch("level", nil).to_s == "error"
          return "warning" if entry.fetch("level", nil).to_s == "warning"

          "progress"
        end

        def entry_sort_key(entry)
          [sortable_timestamp(entry.fetch("timestamp", nil)), entry.fetch("sequence", entry.fetch("ordinal", 0)).to_i]
        end

        def sortable_timestamp(timestamp)
          timestamp.to_s.empty? ? "9999-12-31T23:59:59Z" : timestamp.to_s
        end

        def normalized_message_role(role)
          case role.to_s
          when "you" then "you"
          when "agent" then "agent"
          else "meringue"
          end
        end

        def log_role(source_type, source_id)
          return "you" if source_type == "user"
          return "agent" if %w[head worker].include?(source_type)
          return "agent" if source_type == "harness" && !source_id.to_s.empty?

          "meringue"
        end

        def log_status(entry)
          return "done" if worker_completion_entry?(entry)

          label = log_level(entry)
          return nil if label == "info"

          label
        end

        def log_level(entry)
          details = entry.fetch("details", {}) || {}
          details = {} unless details.is_a?(Hash)
          return "cmd" if details["presentation"] == "cmd" || details["kind"].to_s.start_with?("kernel_command")

          {
            "info" => "info",
            "warning" => "warn",
            "error" => "err"
          }.fetch(entry.fetch("level", nil), "log")
        end

        def agent_by_id(state, source_id)
          return nil if source_id.to_s.empty?

          Array(state.fetch("agents", [])).find { |agent| agent["id"].to_s == source_id.to_s }
        end

        def role_line(entry, selected_agent_id: nil)
          style = entry_style(entry)
          segments = [
            ["[#{timestamp(entry)}] ", Style::DIM],
            [entry_icon(entry), style],
            [" #{participant_label(entry)}", style]
          ]
          segments.concat(agent_title_segments(entry, selected_agent_id: selected_agent_id))
          segments.concat(log_level_segments(entry))
          segments
        end

        # Agent lines are colored per agent id; everything else keeps the
        # kernel/user styles so agent output stays separable from kernel logs.
        def entry_style(entry)
          case entry.fetch("role", "meringue")
          when "you" then Style::USER
          when "agent" then agent_role_style(entry)
          else Style::ACCENT_BOLD
          end
        end

        def agent_role_style(entry)
          agent_id = entry.fetch("source_id", nil).to_s
          return Style::ASSISTANT if agent_id.empty?

          Style.agent_style(agent_id, kind: agent_kind(entry))
        end

        def agent_body_style(entry)
          agent_id = entry.fetch("source_id", nil).to_s
          return Style::ASSISTANT if agent_id.empty?

          Style.agent_body_style(agent_id)
        end

        def agent_kind(entry)
          agent = entry.fetch("agent", nil)
          kind = agent.is_a?(Hash) ? agent.fetch("type", nil).to_s : ""
          return kind if %w[head worker].include?(kind)

          source_type = entry.fetch("source_type", nil).to_s
          return source_type if %w[head worker].include?(source_type)
          return "head" if entry.fetch("source_id", nil).to_s.match?(/\AH\d+\z/)

          ""
        end

        def entry_icon(entry)
          return ERROR_ICON if %w[error warning].include?(entry.fetch("presentation", nil))
          return RESULT_ICON if entry.fetch("presentation", nil) == "result"

          case entry.fetch("role", "meringue")
          when "you" then USER_ICON
          when "agent" then agent_kind(entry) == "head" ? HEAD_ICON : WORKER_ICON
          else KERNEL_ICON
          end
        end

        def gutter_segment(entry)
          return [PLAIN_GUTTER, Style::DIM] unless entry.fetch("role", nil) == "agent"

          [AGENT_GUTTER, agent_body_style(entry)]
        end

        def participant_label(entry)
          return "you" if entry.fetch("role", nil) == "you"
          return "meringue" unless entry.fetch("role", nil) == "agent"

          agent_id = entry.fetch("source_id", nil).to_s
          return "agent" if agent_id.empty?

          agent_id
        end

        def agent_title_segments(entry, selected_agent_id: nil)
          return [] unless entry.fetch("role", nil) == "agent"

          agent = entry.fetch("agent", nil)
          title = agent_title(agent)
          marker = agent && AgentTreeNavigation.active_agent_pr_url(agent) ? " ↗" : ""
          text = [title, marker].join
          return [] if text.strip.empty?

          selected = !selected_agent_id.to_s.empty? && entry.fetch("source_id", nil).to_s == selected_agent_id.to_s
          [[" · ", Style::DIM], [text, selected ? Style::AGENT_TREE_SELECTED : Style::TITLE]]
        end

        def agent_title(agent)
          return "" unless agent

          metadata = agent.fetch("harness_metadata", {}) || {}
          metadata.fetch("title", "#{agent.fetch("type", "agent")} session").to_s
        end

        def log_level_segments(entry)
          return [] unless entry.fetch("kind", nil) == "log"

          status = entry.fetch("status", nil).to_s
          return [] if status.empty?

          [[" · ", Style::DIM], [status, log_level_style(entry)]]
        end

        def log_level_style(entry)
          return Style::SUCCESS if entry.fetch("presentation", nil) == "result"

          case entry.fetch("level", nil)
          when "warning" then Style::LOG_WARNING
          when "error" then Style::LOG_ERROR
          else entry.fetch("status", nil) == "cmd" ? Style::LOG_COMMAND : Style::LOG_INFO
          end
        end

        def body_lines(entry, width:, gutter:)
          if conversational_markdown?(entry)
            Markdown.render(
              entry.fetch("text", ""),
              width: width,
              gutter: gutter,
              base_style: Style::TEXT,
              accent_style: agent_body_style(entry)
            )
          else
            wrapped_text_lines(
              entry.fetch("text", ""),
              width: width,
              gutter: gutter,
              style: body_text_style(entry)
            )
          end
        end

        def conversational_markdown?(entry)
          return false unless entry.fetch("role", nil) == "agent"
          return false if entry.fetch("status", nil).to_s.match?(/err|fail|warn/i)
          return true if entry.fetch("kind", nil) == "message"
          return true if entry.fetch("presentation", nil) == "result"

          details = entry.fetch("details", {}) || {}
          details.is_a?(Hash) && details.fetch("kind", nil).to_s == "head_summary"
        end

        def body_text_style(entry)
          case entry.fetch("level", nil)
          when "warning" then Style::WARNING
          when "error" then Style::ERROR
          else Style::TEXT
          end
        end

        def timestamp(entry)
          Time.iso8601(entry.fetch("timestamp")).strftime("%H:%M")
        rescue ArgumentError, KeyError, TypeError
          "--:--:--"
        end

        def status_line(status, gutter = [PLAIN_GUTTER, Style::DIM])
          [
            gutter,
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

        def wrapped_text_lines(text, width: nil, gutter: [PLAIN_GUTTER, Style::DIM], style: Style::TEXT)
          content_width = width ? [width.to_i - 2, 1].max : nil
          text.to_s.split("\n", -1).flat_map do |line|
            wrap_text_line(line, content_width)
          end.map do |line|
            line.empty? ? [["", style]] : [gutter, [line, style]]
          end
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
            ["Ctrl-C clears/quits", Style::MUTED],
            [" • ", Style::DIM],
            ["Tab focus", Style::MUTED],
            [" • ", Style::DIM],
            ["/keybind help", Style::MUTED]
          ]
        end

        def active_harness_label(state)
          metadata = state.fetch("metadata", {}) || {}
          explicit_label = metadata.fetch("active_harness_label", "").to_s.strip
          return explicit_label unless explicit_label.empty?

          provider = metadata.fetch("active_harness", "").to_s.strip
          return "" if provider.empty?

          Meringue::Harness::Registry.provider_label(provider)
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
          index = chat_state(state).fetch("slash_suggestion_index", NO_SLASH_SELECTION).to_i
          # Negative means the user has not navigated the list yet, so nothing is highlighted.
          return NO_SLASH_SELECTION unless count.positive? && index >= 0

          index.clamp(0, count - 1)
        end

        def slash_suggestion_window_start(count, selected_index)
          return 0 if count <= VISIBLE_SUGGESTION_LIMIT || selected_index.negative?

          max_start = count - VISIBLE_SUGGESTION_LIMIT
          [selected_index - VISIBLE_SUGGESTION_LIMIT + 1, 0].max.clamp(0, max_start)
        end

        def plain_text(line)
          return line.to_s unless line.is_a?(Array)

          line.map { |segment| segment.is_a?(Array) ? segment.first.to_s : segment.to_s }.join
        end
      end
    end
  end
end
