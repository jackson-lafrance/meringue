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
          cache_key = log_lines_cache_key(state, width)
          return @log_lines_cache.fetch(:lines) if @log_lines_cache&.fetch(:key, nil) == cache_key

          entries = log_entries(state)
          lines = if entries.empty?
                    empty_logs_lines(state, width: width)
                  else
                    selected_agent_id = AgentTreeNavigation.selected_agent_id(state)
                    entries.flat_map do |entry|
                      gutter = gutter_segment(entry)
                      entry_lines = [role_line(entry, selected_agent_id: selected_agent_id)]
                      entry_lines.concat(body_lines(entry, width: width, gutter: gutter))
                      entry_lines << status_line(entry.fetch("status"), gutter) if entry.fetch("kind", nil) == "message" && entry.fetch("status", nil)
                      entry_lines
                    end
                  end
          @log_lines_cache = { key: cache_key, lines: lines }
          lines
        end

        # Pane title, so an active AgentTree selection is always visible as the
        # reason the logs pane is filtered.
        def log_pane_title(state)
          label = LogScope.label(state)
          return "logs" if label.empty?

          "logs — #{label}"
        end

        # A filtered logs pane takes the identity color of the node it is filtered
        # to, so the pane, that agent's rows inside it, its AgentTree row, and the
        # composer all agree. A project filter has no identity color of its own,
        # and an unfiltered pane keeps the theme's panel title.
        def log_pane_title_style(state)
          return nil unless %w[head worker issue].include?(LogScope.kind(state))

          Style.agent_chrome_style(LogScope.id(state), bold: true)
        end

        # The composer names the concrete destination of the next prompt: the
        # selected agent (plus its owning issue's short title) or the issue
        # itself. An agent selection still routes through a fresh head, so the
        # chip spells the resolved issue out rather than implying a direct line
        # to the worker. ChatTarget owns the wording for every selection state.
        def composer_pane_title(state)
          ChatTarget.composer_title(state)
        end

        # Composer border/title tinted with the selected node's own log color, so
        # the box the user types into matches the row it will prompt. nil keeps
        # the pane default, which is what makes "no target, head routes" read as
        # plainly unscoped.
        def composer_border_style(state, active: false)
          ChatTarget.border_style(state, active: active)
        end

        def composer_title_style(state)
          ChatTarget.title_style(state)
        end

        def composer_lines(state, width: nil)
          chat = chat_state(state)
          input_buffer = chat.fetch("input_buffer", "").to_s
          input_cursor = chat.fetch("input_cursor", input_buffer.chars.length).to_i

          wrapped_input_lines(
            input_buffer,
            input_cursor: input_cursor,
            width: width,
            selection: chat.fetch("selection", nil),
            prompt_style: ChatTarget.prompt_style(state),
            placeholder: ChatTarget.placeholder(state)
          )
        end

        # Visual rows of the composer as buffer character spans. Mouse selection
        # uses this to map a click back to a character index without duplicating
        # the wrapping rules used for rendering.
        def composer_row_spans(state, width: nil)
          input_buffer = chat_state(state).fetch("input_buffer", "").to_s
          return [] if input_buffer.empty?

          input_row_spans(input_buffer, composer_available_width(input_buffer, width))
        end

        def composer_char_index_at(state, row:, column:, width: nil)
          chat = chat_state(state)
          input_buffer = chat.fetch("input_buffer", "").to_s
          return 0 if input_buffer.empty?

          spans = composer_row_spans(state, width: width)
          return 0 if spans.empty?

          row_index = row.to_i.clamp(0, spans.length - 1)
          span = spans.fetch(row_index)
          cursor = chat.fetch("input_cursor", input_buffer.chars.length).to_i.clamp(0, input_buffer.chars.length)
          cursor_row, cursor_column = composer_cursor_location(spans, cursor)
          column = column.to_i
          # The cursor marker occupies one visual cell, so clicks to its right
          # land one column further along the row than the buffer index.
          column -= 1 if cursor_row == row_index && column > cursor_column
          span.fetch(:start) + column.clamp(0, span.fetch(:length))
        end

        def bottom_hint_line(state)
          chat = chat_state(state)
          pending_count = chat.fetch("pending_count", 0).to_i
          prefix = log_scope_hint_segments(state)
          selection_segments = selection_hint_segments(state)
          prefix += [["  ·  ", Style::DIM]] unless prefix.empty? || selection_segments.empty?
          prefix += selection_segments
          status_segments = compact_status_segments(state, pending_count)
          prefix += [["  ·  ", Style::DIM]] unless prefix.empty? || status_segments.empty?
          prefix += status_segments
          open_questions = state.fetch("questions", []).count { |question| question["status"] == "open" }
          if open_questions.positive?
            prefix += [["  ·  ", Style::DIM]] unless prefix.empty?
            prefix += [["? #{open_questions}", Style::WARNING]]
          end
          delivery_pr = delivery_pr_hint_segments(state)
          unless delivery_pr.empty?
            prefix += [["  ·  ", Style::DIM]] unless prefix.empty?
            prefix += delivery_pr
          end
          separator = prefix.empty? ? [] : [["  ·  ", Style::DIM]]

          prefix + separator + interaction_hint_segments
        end

        def bottom_right_status_line(state)
          label = active_harness_label(state)
          defaults = (state.fetch("metadata", {}) || {}).fetch("pi_session_defaults", {}) || {}
          return [] if label.empty? && defaults.empty?

          segments = label.empty? ? [] : [["harness: ", Style::DIM], [label, Style::ACCENT_BOLD]]
          unless defaults.empty?
            model = defaults.fetch("model", nil) || "mixed"
            thinking = defaults.fetch("thinking_level", nil) || "mixed"
            segments << [" · ", Style::DIM] unless segments.empty?
            segments.concat([
              ["Pi defaults: ", Style::DIM],
              [model.to_s, Style::MUTED],
              [" · ", Style::DIM],
              [thinking.to_s, Style::MUTED]
            ])
          end
          segments
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

        # Selection chip plus its clear affordance, so both focused logs and the
        # head-routing target stay visible. The chip is tinted with the same
        # color as the composer border, and every state (including "nothing is
        # selected") says who routes the message.
        def log_scope_hint_segments(state)
          ChatTarget.chip_segments(state)
        end

        def empty_logs_lines(state, width: nil)
          wrap_text_line(empty_logs_text(state), width && [width.to_i, 1].max).map { |line| [[line, Style::MUTED]] }
        end

        def empty_logs_text(state)
          label = LogScope.label(state)
          return "No logs yet. Type a prompt below and press Enter." if label.empty?

          "No logs for #{label} yet. Click another AgentTree row to move this filter, or press Esc to clear it."
        end

        def delivery_pr_hint_segments(state)
          navigation_id = AgentTreeNavigation.selected_agent_id(state)
          workspace = state.fetch("_agent_workspace", {}) || {}
          agent_id = navigation_id || workspace["agent_id"]
          return [] if agent_id.to_s.empty?

          presentation = DeliveryPullRequest.for_id(state, agent_id)
          unless DeliveryPullRequest.openable?(presentation)
            return [["PR", Style::MUTED], [" #{DeliveryPullRequest.status_label(presentation)}", Style::WARNING]]
          end

          number = presentation.fetch("number", "?")
          status = DeliveryPullRequest.status_label(presentation)
          status_style = presentation.fetch("metadata_available", true) && !presentation["stale"] ? Style::SUCCESS : Style::WARNING
          [
            ["PR ##{number}", Style::ACCENT_BOLD],
            [" #{status}", status_style],
            ["  Ctrl-B open", Style::MUTED]
          ]
        end

        # Input editing only changes _chat.input_buffer, but the layout asks for
        # the complete, wrapped log history twice per frame (scroll bounds and
        # drawing). Cache that expensive work by the state that can affect log
        # presentation so a keystroke only redraws the composer.
        def log_lines_cache_key(state, width)
          chat = chat_state(state)
          [
            width,
            Array(state.fetch("logs", [])).hash,
            Array(state.fetch("agents", [])).hash,
            Array(chat.fetch("messages", [])).hash,
            AgentTreeNavigation.selected_agent_id(state),
            LogScope.id(state),
            Style.current_colorscheme
          ]
        end

        def log_entries(state)
          message_entries = visible_messages(chat_state(state).fetch("messages", []) || []).map.with_index { |message, index| message_entry(message, index, state) }
          durable_log_entries = Array(state.fetch("logs", [])).map.with_index { |entry, index| log_entry(entry, index, state) }.compact
          message_topics = topic_index(message_entries)
          durable_log_entries = durable_log_entries.reject { |entry| redundant_lifecycle_log?(entry, message_topics) }
          duplicate_log_texts = duplicate_text_index(durable_log_entries)
          entries = message_entries.filter_map { |entry| deduplicate_message_entry(entry, duplicate_log_texts) } + durable_log_entries
          # A selected AgentTree node scopes the pane to that node's subtree.
          entries = LogScope.filter(LogScope.scope(state), entries)
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

        # Compare absolute instants so UTC-stored and local-stored timestamps interleave correctly.
        def sortable_timestamp(timestamp)
          Timestamps.sort_key(timestamp)
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
          Timestamps.format(entry.fetch("timestamp", nil), "%H:%M") || "--:--"
        end

        def status_line(status, gutter = [PLAIN_GUTTER, Style::DIM])
          [
            gutter,
            [status.to_s, Style::MUTED]
          ]
        end

        def wrapped_input_lines(input_buffer, input_cursor:, width: nil, selection: nil,
                                prompt_style: Style::ACCENT_BOLD, placeholder: "enter a prompt")
          if input_buffer.empty?
            return [[
              ["›", prompt_style],
              [" #{placeholder}", Style::MUTED]
            ]]
          end

          chars = input_buffer.chars
          cursor = input_cursor.to_i.clamp(0, chars.length)
          spans = input_row_spans(input_buffer, composer_available_width(input_buffer, width))
          cursor_row, cursor_column = composer_cursor_location(spans, cursor)
          selection_range = composer_selection_range(selection, chars.length)

          spans.each_with_index.map do |span, index|
            input_line_segments(
              chars,
              span,
              first_line: index.zero?,
              cursor_column: index == cursor_row ? cursor_column : nil,
              selection_range: selection_range,
              prompt_style: prompt_style
            )
          end
        end

        def composer_available_width(input_buffer, width)
          return [width.to_i - 2, 1].max if width

          [input_buffer.to_s.chars.length, 1].max
        end

        # Wrapping is computed from the buffer itself (not from a buffer with the
        # cursor marker spliced in) so visual rows map back to exact character
        # indexes for mouse selection.
        def input_row_spans(input_buffer, available_width)
          spans = []
          index = 0
          input_buffer.to_s.split("\n", -1).each do |logical_line|
            line_length = logical_line.chars.length
            if line_length.zero?
              spans << { start: index, length: 0 }
            else
              offset = 0
              while offset < line_length
                length = [available_width, line_length - offset].min
                spans << { start: index + offset, length: length }
                offset += length
              end
            end
            index += line_length + 1
          end
          spans
        end

        def composer_cursor_location(spans, cursor)
          spans.each_with_index do |span, index|
            finish = span.fetch(:start) + span.fetch(:length)
            return [index, cursor - span.fetch(:start)] if cursor < finish
            next unless cursor == finish

            next_span = spans[index + 1]
            # A cursor sitting at the end of a wrapped row belongs at the start of
            # the continuation row; a hard newline keeps it on the current row.
            return [index, cursor - span.fetch(:start)] if next_span.nil? || next_span.fetch(:start) > cursor

            return [index + 1, 0]
          end

          last_span = spans.last
          [[spans.length - 1, 0].max, last_span ? last_span.fetch(:length) : 0]
        end

        def composer_selection_range(selection, buffer_length)
          return nil unless selection.is_a?(Hash)

          start_index = selection.fetch("start", 0).to_i.clamp(0, buffer_length)
          finish_index = selection.fetch("end", 0).to_i.clamp(0, buffer_length)
          return nil if finish_index <= start_index

          (start_index...finish_index)
        end

        # Input text itself always keeps Style::TEXT (and SELECTION inside a
        # highlight): the tint only reaches the prompt marker, so typed text
        # stays at full contrast in every colorscheme.
        def input_line_segments(chars, span, first_line:, cursor_column:, selection_range:, prompt_style: Style::ACCENT_BOLD)
          prefix = first_line ? "› " : "  "
          segments = [[prefix, first_line ? prompt_style : Style::DIM]]
          run = +""
          run_style = nil

          span.fetch(:length).times do |offset|
            index = span.fetch(:start) + offset
            if cursor_column == offset
              segments << [run.dup, run_style] unless run.empty?
              run.clear
              segments << ["_", Style::ACCENT_BOLD]
            end

            style = selection_range&.include?(index) ? Style::SELECTION : Style::TEXT
            if style != run_style
              segments << [run.dup, run_style] unless run.empty?
              run.clear
              run_style = style
            end
            run << chars[index].to_s
          end

          segments << [run.dup, run_style] unless run.empty?
          segments << ["_", Style::ACCENT_BOLD] if cursor_column && cursor_column >= span.fetch(:length)
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

        def selection_hint_segments(state)
          selection = state.fetch("_selection", {}) || {}
          status = selection.fetch("status", "").to_s.strip
          return [["⧉ #{status}", Style::SUCCESS]] unless status.empty?
          if selection.fetch("mode", nil).to_s == "logs_cursor"
            return [["⧉ logs select", Style::ACCENT], ["  arrows move · Shift+arrows extend · Ctrl-C copies · Esc exits", Style::MUTED]]
          end
          return [["⧉ selection", Style::ACCENT], ["  Ctrl-C copies", Style::MUTED]] if selection.fetch("active", false)
          return [["Alt-V or Shift+arrows select logs", Style::MUTED]] if logs_pane_focused?(state)

          []
        end

        def logs_pane_focused?(state)
          (state.fetch("_scroll", {}) || {}).fetch("active_pane", nil).to_s == "logs"
        end

        # Shares the focused workspace's bottom-bar styling: accented keys with
        # muted labels and dim dividers, so both bars read as one product.
        def interaction_hint_segments
          HintLine.segments(
            [
              ["Enter", "send"],
              ["Ctrl-C", "clear/quit"],
              ["Tab", "focus"],
              ["/", "commands"],
              ["/keybind", "keys"]
            ]
          )
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
