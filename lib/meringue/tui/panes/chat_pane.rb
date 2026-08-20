# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    module Panes
      class ChatPane
        VISIBLE_SUGGESTION_LIMIT = 3
        # The model picker is a list the user browses rather than a hint over the
        # composer, so it gets a taller window than the slash-command popup while
        # still sharing the same slot, border, and keys.
        MODEL_PICKER_VISIBLE_LIMIT = 10
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
          lines = []
          paragraph_ranges = {}
          worker_click_targets = {}
          if entries.empty?
            append_log_body_paragraphs(lines, paragraph_ranges, empty_logs_lines(state, width: width))
          else
            selected_agent_id = AgentTreeNavigation.selected_agent_id(state)
            entries.each do |entry|
              fragment = cached_log_entry_fragment(entry, width: width, selected_agent_id: selected_agent_id)
              append_log_fragment(lines, paragraph_ranges, worker_click_targets, fragment)
            end
          end
          @log_lines_cache = {
            key: cache_key,
            lines: lines,
            paragraph_ranges: paragraph_ranges,
            worker_click_targets: worker_click_targets
          }
          lines
        end

        # Durable log changes add a fresh record id; retention or explicit replacement may also
        # remove an older one. A new worker update used to invalidate the whole-pane cache and re-run
        # Markdown layout for all 500 retained logs. Keep each entry's wrapped rows independently so
        # only fresh records need layout; assembling scrollback stays cheap and preserves coordinates.
        def cached_log_entry_fragment(entry, width:, selected_agent_id:)
          @log_entry_fragment_cache ||= {}
          key = log_entry_fragment_cache_key(entry, width, selected_agent_id)
          return @log_entry_fragment_cache.fetch(key) if @log_entry_fragment_cache.key?(key)

          fragment_lines = []
          fragment_ranges = {}
          gutter = gutter_segment(entry)
          header_rows = role_lines(entry, selected_agent_id: selected_agent_id, width: width)
          body_rows = body_lines(entry, width: width, gutter: gutter)
          append_log_paragraph(fragment_lines, fragment_ranges, header_rows)
          append_log_body_paragraphs(fragment_lines, fragment_ranges, body_rows)
          if entry.fetch("kind", nil) == "message" && entry.fetch("status", nil)
            append_log_paragraph(fragment_lines, fragment_ranges, [status_line(entry.fetch("status"), gutter)])
          end

          @log_entry_fragment_cache[key] = {
            lines: fragment_lines,
            paragraph_ranges: fragment_ranges,
            worker_click_targets: worker_click_targets(entry, header_rows, body_rows)
          }
          # Keep more than two full retained windows so normal append/evict traffic never causes a
          # synchronized cache cliff. Hash insertion order lets us discard only the oldest fragments.
          @log_entry_fragment_cache.shift while @log_entry_fragment_cache.length > 1_200
          @log_entry_fragment_cache.fetch(key)
        end

        def append_log_fragment(lines, paragraph_ranges, worker_click_targets, fragment)
          offset = lines.length
          lines.concat(fragment.fetch(:lines))
          fragment.fetch(:paragraph_ranges).each do |line_index, range|
            paragraph_ranges[line_index + offset] = {
              "start_line" => range.fetch("start_line") + offset,
              "end_line" => range.fetch("end_line") + offset
            }
          end
          fragment.fetch(:worker_click_targets, {}).each do |line_index, targets|
            worker_click_targets[line_index + offset] = targets
          end
        end

        # Clickable worker references are deliberately narrower than a whole log
        # row. Header targets are the rendered worker id and title; body targets
        # are nonblank authored text after the identity gutter. Timestamps, icons,
        # separators, trailing whitespace, status rows, heads, and kernel
        # provenance remain ordinary selectable text.
        def worker_click_targets(entry, header_rows, body_rows)
          return {} unless entry.fetch("role", nil) == "agent"
          return {} unless agent_kind(entry) == "worker"

          worker_id = entry.fetch("source_id", nil).to_s
          return {} if worker_id.empty?

          targets = {}
          header_text = header_rows.map { |row| plain_text(row) }.join
          id_start = header_text.index(worker_id)
          add_wrapped_worker_target(targets, header_rows, id_start, worker_id.length, worker_id) if id_start

          title = agent_title(entry.fetch("agent", nil))
          title_start = title.empty? ? nil : header_text.index(title, id_start.to_i + worker_id.length)
          add_wrapped_worker_target(targets, header_rows, title_start, title.length, worker_id) if title_start

          body_offset = header_rows.length
          body_rows.each_with_index do |row, index|
            text = plain_text(row)
            content_start = text.start_with?(AGENT_GUTTER) ? AGENT_GUTTER.length : 0
            first = text.index(/\S/, content_start)
            last = text.rindex(/\S/)
            next unless first && last && last >= content_start

            targets[body_offset + index] = [{ "start_column" => first, "end_column" => last + 1, "worker_id" => worker_id }]
          end
          targets
        end

        def add_wrapped_worker_target(targets, rows, absolute_start, length, worker_id)
          cursor = 0
          rows.each_with_index do |row, line_index|
            row_length = plain_text(row).length
            start_column = [absolute_start - cursor, 0].max
            end_column = [absolute_start + length - cursor, row_length].min
            if start_column < end_column
              (targets[line_index] ||= []) << {
                "start_column" => start_column,
                "end_column" => end_column,
                "worker_id" => worker_id
              }
            end
            cursor += row_length
          end
        end

        # Worker id for a rendered logs cell, or nil when the cell is selectable
        # text but not an action target.
        def log_worker_at(state, line_index, column, width: nil)
          log_lines(state, width: width)
          targets = @log_lines_cache.fetch(:worker_click_targets, {}).fetch(line_index.to_i, [])
          target = targets.find do |candidate|
            column.to_i >= candidate.fetch("start_column") && column.to_i < candidate.fetch("end_column")
          end
          target&.fetch("worker_id", nil)
        end

        def log_entry_fragment_cache_key(entry, width, selected_agent_id)
          agent = entry.fetch("agent", nil)
          metadata = agent.is_a?(Hash) ? (agent.fetch("harness_metadata", {}) || {}) : {}
          [
            width,
            entry.fetch("kind", nil),
            entry.fetch("record_id", nil),
            entry.fetch("timestamp", nil),
            entry.fetch("role", nil),
            entry.fetch("source_type", nil),
            entry.fetch("source_id", nil),
            entry.fetch("text", nil),
            entry.fetch("status", nil),
            entry.fetch("level", nil),
            entry.fetch("presentation", nil),
            agent.is_a?(Hash) ? agent.fetch("status", nil) : nil,
            metadata.fetch("title", nil),
            selected_agent_id,
            Style.current_colorscheme,
            Timestamps.context_key
          ]
        end

        # Inclusive wrapped-row bounds for the displayed paragraph containing a
        # logs content row. Headers and statuses are their own paragraphs; body
        # text stays together across soft wraps and stops at displayed blank
        # lines or at the next log entry.
        def log_paragraph_range(state, line_index, width: nil)
          lines = log_lines(state, width: width)
          index = line_index.to_i
          return nil unless index.between?(0, lines.length - 1)

          range = @log_lines_cache.fetch(:paragraph_ranges, {}).fetch(index, nil)
          range&.dup
        end

        def append_log_body_paragraphs(lines, paragraph_ranges, rows)
          paragraph = []
          flush = lambda do
            append_log_paragraph(lines, paragraph_ranges, paragraph)
            paragraph = []
          end

          Array(rows).each do |row|
            if blank_log_body_row?(row)
              flush.call
              append_log_paragraph(lines, paragraph_ranges, [row])
            else
              paragraph << row
            end
          end
          flush.call
        end

        def append_log_paragraph(lines, paragraph_ranges, rows)
          rows = Array(rows)
          return if rows.empty?

          start_line = lines.length
          lines.concat(rows)
          finish_line = lines.length - 1
          range = { "start_line" => start_line, "end_line" => finish_line }
          (start_line..finish_line).each { |line_index| paragraph_ranges[line_index] = range }
        end

        def blank_log_body_row?(row)
          segments = Array(row)
          text = plain_text(segments)
          return true if text.strip.empty?
          return false unless segments.length == 1

          [AGENT_GUTTER, PLAIN_GUTTER].include?(text)
        end

        # Pane title, so an active AgentTree selection is always visible as the
        # reason the logs pane is filtered. A worker scope gets its own compact
        # status strip; issue/project scopes remain plain because they do not
        # identify one session's telemetry.
        def log_pane_title(state, width: nil)
          label = LogScope.label(state)
          return "logs" if label.empty?
          return "logs — #{label}" unless LogScope.kind(state) == "worker"

          worker = agent_by_id(state, label)
          return "logs — #{label}" unless worker

          base = "logs — #{label}"
          fragments = selected_worker_status_fragments(worker)
          return [base, *fragments].join(" · ") if width.nil?

          fit_worker_log_title(base, fragments, width)
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
        # itself. This title is the *only* place the target is named, so it spells
        # the resolved issue out when the agent id does not already encode it
        # rather than implying a direct line to the worker. ChatTarget owns the
        # wording for every selection state.
        def composer_pane_title(state)
          ChatTarget.composer_title(state)
        end

        # Composer border/title tinted with the selected node's own log color, so
        # the box the user types into matches the row it will prompt. nil keeps
        # the pane default, which is what makes no-target chat read as plainly
        # unscoped.
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
          segments = compact_harness_status_segments(state)
          defaults = (state.fetch("metadata", {}) || {}).fetch("pi_session_defaults", {}) || {}
          return [] if segments.empty? && defaults.empty?

          unless defaults.empty?
            head_model = defaults.dig("roles", "head", "model") || defaults["model"] || "mixed"
            worker_model = defaults.dig("roles", "worker", "model") || defaults["model"] || "mixed"
            head_thinking = defaults.dig("roles", "head", "thinking_level") || defaults["thinking_level"] || "mixed"
            worker_thinking = defaults.dig("roles", "worker", "thinking_level") || defaults["thinking_level"] || "mixed"
            segments << [" · ", Style::DIM] unless segments.empty?
            segments.concat(compact_model_status_segments(
              head_model: head_model,
              worker_model: worker_model,
              head_thinking: head_thinking,
              worker_thinking: worker_thinking
            ))
          end
          segments
        end

        # Keep the footer short when the two roles share values, while making
        # every role-specific combination explicit enough to scan at a glance.
        def compact_model_status_segments(head_model:, worker_model:, head_thinking:, worker_thinking:)
          if head_model == worker_model && head_thinking == worker_thinking
            [
              ["model: ", Style::DIM],
              [head_model.to_s, Style::MUTED],
              [" · thinking: ", Style::DIM],
              [head_thinking.to_s, Style::MUTED]
            ]
          elsif head_model != worker_model && head_thinking == worker_thinking
            [
              ["head model: ", Style::DIM],
              [head_model.to_s, Style::MUTED],
              [" · worker model: ", Style::DIM],
              [worker_model.to_s, Style::MUTED],
              [" · thinking: ", Style::DIM],
              [head_thinking.to_s, Style::MUTED]
            ]
          elsif head_model == worker_model
            [
              ["model: ", Style::DIM],
              [head_model.to_s, Style::MUTED],
              [" · head thinking: ", Style::DIM],
              [head_thinking.to_s, Style::MUTED],
              [" · worker thinking: ", Style::DIM],
              [worker_thinking.to_s, Style::MUTED]
            ]
          else
            [
              ["head model: ", Style::DIM],
              [head_model.to_s, Style::MUTED],
              [" (thinking: ", Style::DIM],
              [head_thinking.to_s, Style::MUTED],
              [") · worker model: ", Style::DIM],
              [worker_model.to_s, Style::MUTED],
              [" (thinking: ", Style::DIM],
              [worker_thinking.to_s, Style::MUTED],
              [")", Style::DIM]
            ]
          end
        end

        def slash_suggestions?(state)
          slash_suggestion_records(state).any?
        end

        # The popup slot between the logs pane and the composer. The model picker,
        # the open-PR picker, and the slash-command list are all transient lists
        # over the composer, so they share one geometry, one border, and one
        # keyboard shape instead of introducing another overlay mechanism. A picker
        # wins while it is up.
        #
        # First-run setup is a full-screen Settings mode rather than a popup in
        # this composer slot.
        def popup?(state)
          model_picker?(state) || delivery_pr_picker?(state) || slash_suggestions?(state)
        end

        # How many entry rows the popup shows at once, and therefore how tall the
        # layout should let the box grow.
        def popup_visible_limit(state)
          model_picker?(state) ? MODEL_PICKER_VISIBLE_LIMIT : VISIBLE_SUGGESTION_LIMIT
        end

        def popup_max_box_height(state)
          popup_visible_limit(state) + 2
        end

        def popup_pane_title(state)
          return "models (#{ModelPicker.harness_for(state, model_picker_state(state).fetch("harness", nil))})" if model_picker?(state)

          delivery_pr_picker?(state) ? "open pull requests" : "slash commands"
        end

        # Only entries live inside the popup box. The counter and the key hints are
        # *about* the list rather than members of it, so a row that says "1–15 of
        # 27 commands" inside the border reads like a 16th command and costs the
        # list a visible row. The layout draws #popup_footer_line under the box.
        def popup_lines(state)
          return model_picker_lines(state) if model_picker?(state)

          delivery_pr_picker?(state) ? delivery_pr_picker_lines(state) : slash_suggestion_lines(state)
        end

        # Dim line rendered directly below the popup box: where the window sits in
        # the full list, and the keys that move it. Empty when there is nothing to
        # say, in which case the layout reserves no row for it.
        def popup_footer_line(state)
          return model_picker_footer_line(state) if model_picker?(state)

          delivery_pr_picker?(state) ? delivery_pr_picker_footer_line(state) : slash_suggestion_footer_line(state)
        end

        # The `/models` picker: one searchable list of the models the harness
        # itself reported, replacing the old catalog dump in the log.
        def model_picker?(state)
          model_picker_state(state).fetch("active", false) == true
        end

        def model_picker_state(state)
          value = chat_state(state).fetch("model_picker", nil)
          value.is_a?(Hash) ? value : {}
        end

        def model_picker_query(state)
          model_picker_state(state).fetch("query", "").to_s
        end

        def model_picker_harness(state)
          ModelPicker.harness_for(state, model_picker_state(state).fetch("harness", nil))
        end

        def model_picker_entries(state)
          ModelPicker.entries(state, harness: model_picker_harness(state), query: model_picker_query(state))
        end

        # Clamped against the list that exists this frame, so a refresh that
        # shortens the catalog cannot leave the cursor past the end.
        def model_picker_index(state)
          entries = model_picker_entries(state)
          return NO_SLASH_SELECTION if entries.empty?

          model_picker_state(state).fetch("index", 0).to_i.clamp(0, entries.length - 1)
        end

        def model_picker_window_start(state)
          slash_suggestion_window_start(
            model_picker_entries(state).length,
            model_picker_index(state),
            limit: MODEL_PICKER_VISIBLE_LIMIT
          )
        end

        # An empty list always explains itself: an unavailable or unsupported
        # harness catalog says so in the harness's own words instead of rendering
        # a blank box the user cannot tell from "no models exist".
        def model_picker_lines(state)
          entries = model_picker_entries(state)
          if entries.empty?
            message = ModelPicker.empty_message(state, harness: model_picker_harness(state), query: model_picker_query(state))
            return [[[message, Style::MUTED]]]
          end

          selected_index = model_picker_index(state)
          window_start = model_picker_window_start(state)
          entries.drop(window_start).first(MODEL_PICKER_VISIBLE_LIMIT).map.with_index do |entry, offset|
            model_picker_line(entry, selected: window_start + offset == selected_index)
          end
        end

        def model_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          details = []
          details << "current default" if entry.fetch("current", false)
          details << entry.fetch("name") unless entry.fetch("name", "").to_s.empty?
          levels = Array(entry.fetch("thinking_levels", []))
          details << "thinking: #{levels.join(", ")}" unless levels.empty?
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            [entry.fetch("reference"), selected ? Style::ACCENT_BOLD : Style::TEXT],
            details.empty? ? nil : ["  #{details.join(" · ")}", Style::MUTED]
          ].compact
        end

        # Caption under the box: where the window sits, what the query is, and the
        # keys. The picker is modal and met rarely, so it always states its keys.
        def model_picker_footer_line(state)
          total = model_picker_entries(state).length
          segments = []
          if total.positive?
            segments << [model_picker_count_label(state, total), Style::MUTED]
          end
          query = model_picker_query(state)
          segments << ["  ·  filter: #{query}", Style::TEXT] unless query.empty?
          segments << ["#{segments.empty? ? "" : "  ·  "}type to filter · ↑↓ move · Enter sets the default · Ctrl-R refreshes · Esc closes", Style::DIM]
          segments
        end

        def model_picker_count_label(state, total)
          label = if total > MODEL_PICKER_VISIBLE_LIMIT
                    window_start = model_picker_window_start(state)
                    "#{window_start + 1}–#{[window_start + MODEL_PICKER_VISIBLE_LIMIT, total].min} of #{total} models"
                  else
                    "#{total} model#{total == 1 ? "" : "s"}"
                  end
          state_label = ModelPicker.state_label(state, harness: model_picker_harness(state))
          state_label ? "#{label} (#{state_label})" : label
        end

        def delivery_pr_picker?(state)
          Settings.github_enabled?(state) && delivery_pr_picker_state(state).fetch("active", false) == true
        end

        # Highlighted row, clamped to the list that exists this frame so a PR that
        # merged (and left the list) cannot leave the cursor pointing past the end.
        def delivery_pr_picker_index(state)
          entries = OpenPullRequests.entries(state)
          return NO_SLASH_SELECTION if entries.empty?

          delivery_pr_picker_state(state).fetch("index", 0).to_i.clamp(0, entries.length - 1)
        end

        def delivery_pr_picker_window_start(state)
          slash_suggestion_window_start(OpenPullRequests.entries(state).length, delivery_pr_picker_index(state))
        end

        def delivery_pr_picker_lines(state)
          entries = OpenPullRequests.entries(state)
          return [[["No open pull requests are tracked yet.", Style::MUTED]]] if entries.empty?

          selected_index = delivery_pr_picker_index(state)
          window_start = delivery_pr_picker_window_start(state)
          entries.drop(window_start).first(VISIBLE_SUGGESTION_LIMIT).map.with_index do |entry, offset|
            delivery_pr_picker_line(entry, selected: window_start + offset == selected_index)
          end
        end

        def delivery_pr_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            ["##{entry.fetch("number")}", selected ? Style::ACCENT_BOLD : Style::PR_MARKER],
            ["  #{entry.fetch("title")}", selected ? Style::ACCENT_BOLD : Style::TEXT],
            ["  #{entry.fetch("issue_id")} · #{entry.fetch("status")}", Style::MUTED]
          ]
        end

        # The picker always explains its own keys, because it is a modal list a user
        # meets rarely; the count is only interesting once the window hides rows.
        def delivery_pr_picker_footer_line(state)
          total = OpenPullRequests.entries(state).length
          return [["Esc closes", Style::DIM]] if total.zero?

          count = if total > VISIBLE_SUGGESTION_LIMIT
                    window_start = delivery_pr_picker_window_start(state)
                    "#{window_start + 1}–#{[window_start + VISIBLE_SUGGESTION_LIMIT, total].min} of #{total} open PRs"
                  else
                    "#{total} open PR#{total == 1 ? "" : "s"}"
                  end
          [[count, Style::MUTED], ["  ·  ↑↓ move · Enter opens · Esc closes", Style::DIM]]
        end

        def delivery_pr_picker_state(state)
          value = chat_state(state).fetch("delivery_pr_picker", nil)
          value.is_a?(Hash) ? value : {}
        end

        def slash_suggestion_lines(state)
          records = slash_suggestion_records(state)
          return [[["No matching slash commands.", Style::MUTED]]] if slash_prompt?(chat_state(state).fetch("input_buffer", "")) && records.empty?

          selected_index = selected_slash_suggestion_index(state, records.length)
          window_start = slash_suggestion_window_start_for(state)
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

        # A three-row window over a long list reads like a three-item list. A
        # harness can offer a hundred models, so say how many entries exist and
        # how to reach the rest instead of letting the window imply the total.
        # This is a caption under the box, not a list row (see #popup_lines).
        def slash_suggestion_footer_line(state)
          records = slash_suggestion_records(state)
          # The trailing catalog-state note is an explanation, not an entry.
          total = records.count { |record| record.fetch("kind", "command") != "session_models_unavailable" }
          return [] if total <= VISIBLE_SUGGESTION_LIMIT

          # The same window the rows above use, so the caption can never disagree
          # with what is on screen.
          window_start = slash_suggestion_window_start_for(state)
          last_shown = [window_start + VISIBLE_SUGGESTION_LIMIT, total].min
          [
            ["#{window_start + 1}–#{last_shown} of #{total} #{slash_suggestion_scope_label(records)}", Style::MUTED],
            ["  ·  ↑↓ scroll · keep typing to filter", Style::DIM]
          ]
        end

        def slash_suggestion_window_start_for(state)
          records = slash_suggestion_records(state)
          slash_suggestion_window_start(records.length, selected_slash_suggestion_index(state, records.length))
        end

        def slash_suggestion_scope_label(records)
          kinds = records.map { |record| record.fetch("kind", "command") }.uniq
          return "models" if kinds.include?("session_models")
          return "thinking levels" if kinds == ["thinking_levels"]

          kinds == ["command"] ? "commands" : "matches"
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

        def selected_worker_status_fragments(agent)
          status, model, thinking, context, turns = selected_worker_status_values(agent)
          fragments = [
            status,
            "model #{model}",
            "thinking #{thinking}",
            context
          ]
          fragments << "turns #{turns}" unless turns.nil?
          fragments
        end

        def selected_worker_status_values(agent)
          settings = agent.fetch("session_settings", {})
          settings = {} unless settings.is_a?(Hash)
          model = effective_model_reference(settings.fetch("model", nil)) || "unavailable"
          thinking = (settings["thinking_level"] || settings["thinkingLevel"]).to_s.strip
          thinking = "unavailable" if thinking.empty?
          stats = agent.fetch("session_stats", nil)
          stats = agent.fetch("context_usage", nil) unless stats.is_a?(Hash)
          stats = agent.dig("harness_metadata", "session_stats") unless stats.is_a?(Hash)
          stats = agent.dig("harness_metadata", "context_usage") unless stats.is_a?(Hash)
          stats = {} unless stats.is_a?(Hash)
          context = context_usage_fragment(stats, settings: settings)
          turns = session_turn_count(stats)
          status = agent.fetch("status", nil).to_s.strip
          status = "unavailable" if status.empty?
          [status, model, thinking, context, turns]
        end

        def effective_model_reference(model)
          return nil if model.nil?
          if model.is_a?(Hash)
            reference = model.fetch("reference", nil).to_s.strip
            return reference unless reference.empty?

            provider = model.fetch("provider", nil).to_s.strip
            id = model.fetch("id", model.fetch("modelId", nil)).to_s.strip
            return [provider, id].reject(&:empty?).join("/") unless provider.empty? || id.empty?
            return nil
          end

          value = model.to_s.strip
          value.empty? ? nil : value
        end

        def context_usage_fragment(stats, settings:)
          usage = stats["context_usage"] || stats["contextUsage"]
          usage = stats if usage.nil? && (stats.key?("tokens") || stats.key?("used") || stats.key?("capacity"))
          usage = usage.is_a?(Hash) ? usage : {}
          model = settings.fetch("model", nil)
          model = {} unless model.is_a?(Hash)
          capacity = numeric_telemetry_value(
            usage["capacity"] || usage["contextWindow"] || usage["context_window"] ||
              model["context_window"] || model["contextWindow"]
          )
          capacity = nil unless capacity&.positive?
          used = numeric_telemetry_value(usage.key?("tokens") ? usage["tokens"] : usage["used"])
          approximate = usage["approximate"] == true || usage["estimated"] == true ||
                        usage["source"].to_s == "pi_session_stats"
          prefix = approximate && used ? "~" : ""
          used_text = used.nil? ? "?" : token_count(used)
          capacity_text = capacity.nil? ? "?" : token_count(capacity)
          if used && capacity && capacity.positive?
            percent = (used.to_f / capacity.to_f) * 100.0
            "context #{prefix}#{used_text}/#{capacity_text} (#{percentage(percent)})"
          elsif used || capacity
            "context #{prefix}#{used_text}/#{capacity_text} (unavailable)"
          else
            "context unavailable"
          end
        end

        def numeric_telemetry_value(value)
          return nil if value.nil? || value.to_s.strip.empty?

          number = Float(value)
          number.finite? && number >= 0 ? number : nil
        rescue ArgumentError, TypeError
          nil
        end

        def token_count(value)
          number = value.to_f
          return number.round.to_s if number < 1_000

          scaled = if number >= 1_000_000
                     [number / 1_000_000.0, "M"]
                   else
                     [number / 1_000.0, "K"]
                   end
          rounded = scaled.fetch(0).round(1)
          formatted = rounded.to_i == rounded ? rounded.to_i.to_s : rounded.to_s
          "#{formatted}#{scaled.fetch(1)}"
        end

        def percentage(value)
          rounded = value.round(1)
          rounded.to_i == rounded ? "#{rounded.to_i}%" : "#{rounded}%"
        end

        def session_turn_count(stats)
          value = stats["turn_count"]
          value = stats["user_messages"] if value.nil?
          value = stats["userMessages"] if value.nil?
          number = numeric_telemetry_value(value)
          number&.to_i
        end

        def fit_worker_log_title(base, fragments, width)
          limit = [width.to_i, 1].max
          full = [base, *fragments].join(" · ")
          return full if full.length <= limit

          status, model, thinking, context, turns = selected_worker_status_values_from_fragments(fragments)
          compact = [
            base,
            status,
            "m #{clip_title_value(model, 18)}",
            "t #{clip_title_value(thinking, 8)}",
            context.sub(/\Acontext/, "ctx")
          ]
          compact << "n #{turns}" unless turns.nil?
          compact_text = compact.join(" · ")
          return compact_text if compact_text.length <= limit

          compact.delete_if { |part| part.start_with?("n ") }
          compact_text = compact.join(" · ")
          return compact_text if compact_text.length <= limit

          # At ordinary dashboard widths, dropping the `logs —` caption and
          # shortening labels preserves all four requested signals. The model is
          # visibly elided rather than silently replaced with an id-only guess.
          tight_base = base.sub(/\Alogs — /, "")
          tight_context = context.sub(/\Acontext /, "ctx ").sub(/\s+\(([^)]*)\)\z/, " \\1")
          tight = [
            tight_base,
            status,
            "m #{clip_title_value(model, 12)}",
            "t #{clip_title_value(thinking, 6)}",
            tight_context
          ].join(" · ")
          return tight if tight.length <= limit

          tight = [
            tight_base,
            status,
            "m #{clip_title_value(model, 4)}",
            "t #{clip_title_value(thinking, 6)}",
            tight_context
          ].join(" · ")
          return tight if tight.length <= limit

          # Keep the worker id, lifecycle state, thinking level, and context
          # signal ahead of the optional model spelling when a genuinely narrow
          # pane cannot fit all fields. An ellipsis means the value was clipped,
          # never a guessed value.
          core = [
            tight_base,
            status,
            "t #{clip_title_value(thinking, 6)}",
            tight_context
          ].join(" · ")
          clip_title_value(core, limit)
        end

        def selected_worker_status_values_from_fragments(fragments)
          status = fragments.fetch(0, "unavailable")
          model = fragments.fetch(1, "model unavailable").sub(/\Amodel /, "")
          thinking = fragments.fetch(2, "thinking unavailable").sub(/\Athinking /, "")
          context = fragments.fetch(3, "context unavailable")
          turns = fragments.find { |fragment| fragment.start_with?("turns ") }&.sub(/\Aturns /, "")
          [status, model, thinking, context, turns]
        end

        def clip_title_value(value, limit)
          text = value.to_s
          return text if text.length <= limit
          return text[0, limit] if limit <= 1

          "#{text[0, limit - 1]}…"
        end

        # Gestures for the current selection, never its identity: the composer
        # title one row above already names the target, so this only says that a
        # fresh head routes the message (or that a slash command ignores the
        # selection) and that Esc clears it. With nothing selected it is empty,
        # leaving the width to the status, delivery-PR, and interaction hints.
        def log_scope_hint_segments(state)
          ChatTarget.hint_segments(state)
        end

        def empty_logs_lines(state, width: nil)
          wrap_text_line(empty_logs_text(state), width && [width.to_i, 1].max).map { |line| [[line, Style::MUTED]] }
        end

        def empty_logs_text(state)
          label = LogScope.label(state)
          return "No logs yet. Type a prompt below and press Enter." if label.empty?

          "No logs for #{label} yet. Click another AgentTree row to move this filter, or press Esc to clear it."
        end

        # One PR only when the dashboard is actually looking at one node. Unscoped
        # chat is not about a single worker, so it reports how many PRs are open
        # across the tree instead of pinning whichever worker happened to be
        # focused last. Ctrl-B is not advertised inline: the keybinding still works
        # and `/keybind` documents it, but repeating it on every frame cost the
        # width this line needs for everything else.
        def delivery_pr_hint_segments(state)
          return [] unless Settings.github_enabled?(state)

          scoped_id = DeliveryPullRequest.scoped_id(state)
          return open_pull_requests_hint_segments(state) if scoped_id.empty?

          presentation = DeliveryPullRequest.for_id(state, scoped_id)
          return scoped_delivery_pr_segments(presentation) if DeliveryPullRequest.openable?(presentation)
          return [["PR link unusable", Style::WARNING]] if presentation.fetch("state", nil) == "invalid"

          [["no PR yet", Style::MUTED]]
        end

        def scoped_delivery_pr_segments(presentation)
          verified = presentation.fetch("metadata_available", true) && !presentation["stale"]
          [
            ["PR ##{presentation.fetch("number", "?")}", Style::ACCENT_BOLD],
            [" #{DeliveryPullRequest.status_label(presentation)}", verified ? Style::SUCCESS : Style::WARNING]
          ]
        end

        # Silence when the tree has never had a delivery PR: there is nothing to
        # count and nothing for Ctrl-B to open. Once PRs exist, "no open PRs" is a
        # plain fact rather than the old "PR unavailable", which read like a fault.
        def open_pull_requests_hint_segments(state)
          return [] unless OpenPullRequests.tracked?(state)

          total = OpenPullRequests.count(state)
          [[OpenPullRequests.summary_label(state), total.positive? ? Style::ACCENT_BOLD : Style::MUTED]]
        end

        # Input editing and reconciliation metadata do not change the logs pane,
        # but the layout asks for the complete wrapped history twice per frame.
        # Key the cache by compact presentation fields instead of deep-hashing
        # every retained log and complete agent record on each request.
        def log_lines_cache_key(state, width)
          chat = chat_state(state)
          [
            width,
            log_records_cache_key(state.fetch("logs", [])),
            log_agents_cache_key(state.fetch("agents", [])),
            message_records_cache_key(chat.fetch("messages", [])),
            AgentTreeNavigation.selected_agent_id(state),
            log_scope_cache_key(state),
            state.dig("metadata", "last_recount", "recounted_at"),
            Style.current_colorscheme,
            Timestamps.context_key
          ]
        end

        # Independent durable logs append, retention removes from the front, and a replaceable
        # status removes its predecessor before appending a fresh last id. The boundaries and count
        # therefore identify every visible window change without deep-reading Markdown-heavy details.
        def log_records_cache_key(logs)
          records = Array(logs)
          [records.length, log_record_id(records.first), log_record_id(records.last)]
        end

        def log_record_id(record)
          record.is_a?(Hash) ? record.fetch("id", nil) : record
        end

        def message_records_cache_key(messages)
          Array(messages).map do |message|
            next message unless message.is_a?(Hash)

            message.values_at("id", "role", "text", "status", "visible", "timestamp", "source_id")
          end
        end

        def log_agents_cache_key(agents)
          Array(agents).map do |agent|
            next agent unless agent.is_a?(Hash)

            [
              agent.fetch("id", nil),
              agent.fetch("type", nil),
              agent_title(agent),
              !AgentTreeNavigation.active_agent_pr_url(agent).nil?
            ]
          end
        end

        def log_scope_cache_key(state)
          scope = LogScope.scope(state)
          [
            scope.fetch("id", nil),
            scope.fetch("label", nil),
            Array(scope.fetch("member_ids", [])).map(&:to_s)
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
            "record_id" => entry.fetch("id", nil),
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
            ["#{timestamp(entry)} ", Style::DIM],
            [entry_icon(entry), style]
          ]
          segments.concat(participant_segments(entry, style))
          segments.concat(agent_title_segments(entry, selected_agent_id: selected_agent_id))
          segments.concat(log_level_segments(entry))
          segments
        end

        # Headers contain agent-written titles and can be wider than the pane even
        # though message bodies are wrapped. Split them into styled rows too, so a
        # narrow terminal scrolls through the header instead of losing its suffix
        # at the right edge.
        def role_lines(entry, selected_agent_id:, width:)
          segments = role_line(entry, selected_agent_id: selected_agent_id)
          return [segments] if width.nil?

          wrap_segments(segments, width)
        end

        def wrap_segments(segments, width)
          limit = [width.to_i, 1].max
          rows = [[]]
          remaining = limit

          Array(segments).each do |segment|
            text = segment.is_a?(Array) ? segment.fetch(0, "").to_s : segment.to_s
            style = segment.is_a?(Array) ? segment.fetch(1, nil) : nil
            chars = text.chars
            offset = 0
            while offset < chars.length
              if remaining.zero?
                rows << []
                remaining = limit
              end
              chunk = chars.slice(offset, remaining)
              rows.last << [chunk.join, style] unless chunk.empty?
              offset += chunk.length
              remaining -= chunk.length
            end
          end

          rows.pop if rows.length > 1 && rows.last.empty?
          rows
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
          gutter = if entry.fetch("role", nil) == "agent"
                     [AGENT_GUTTER, agent_body_style(entry)]
                   else
                     [PLAIN_GUTTER, Style::DIM]
                   end
          Selection.display_only_segment(gutter)
        end

        def participant_segments(entry, style)
          segments = [[" #{participant_label(entry)}", style]]
          author_id = head_command_author_id(entry)
          return segments unless author_id

          # Keep the kernel as the speaking/applying participant, then show the proposing head as
          # secondary provenance in that head's identity color. The wording matters: H127 did not
          # apply state itself; the command reached the user through Meringue.
          segments + [
            [" · via ", Style::DIM],
            [author_id, Style.agent_style(author_id, kind: "head")]
          ]
        end

        def participant_label(entry)
          return "you" if entry.fetch("role", nil) == "you"
          return "meringue" unless entry.fetch("role", nil) == "agent"

          agent_id = entry.fetch("source_id", nil).to_s
          return "agent" if agent_id.empty?

          agent_id
        end

        def head_command_author_id(entry)
          return nil unless entry.fetch("role", nil) == "meringue"

          details = entry.fetch("details", nil)
          return nil unless details.is_a?(Hash)

          author_type = details.fetch("command_author_type", nil).to_s
          author_id = details.fetch("command_author_id", nil).to_s
          # Compatibility for command-output rows persisted before explicit author metadata was
          # added: those rows already carried the proposing head in `details.head_id`.
          if author_id.empty? && details.fetch("kind", nil).to_s == "kernel_command_output"
            author_type = "head"
            author_id = details.fetch("head_id", nil).to_s
          end
          return nil unless author_type == "head" && author_id.match?(/\AH\d+\z/)

          author_id
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
          details.is_a?(Hash) && %w[head_summary head_response].include?(details.fetch("kind", nil).to_s)
        end

        def body_text_style(entry)
          case entry.fetch("level", nil)
          when "warning" then Style::WARNING
          when "error" then Style::ERROR
          else Style::TEXT
          end
        end

        def timestamp(entry)
          Timestamps.display(entry.fetch("timestamp", nil)) || "[--:--]"
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
          paste_ranges = PasteRegistry.marker_ranges_in(input_buffer)

          spans.each_with_index.map do |span, index|
            input_line_segments(
              chars,
              span,
              first_line: index.zero?,
              cursor_column: index == cursor_row ? cursor_column : nil,
              selection_range: selection_range,
              prompt_style: prompt_style,
              paste_ranges: paste_ranges
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

        def paste_marker_index?(paste_ranges, index)
          return false if paste_ranges.empty?

          paste_ranges.any? { |range| range.cover?(index) }
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
        def input_line_segments(chars, span, first_line:, cursor_column:, selection_range:, prompt_style: Style::ACCENT_BOLD,
                                paste_ranges: [])
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

            # A collapsed paste is one chunk, so it is tinted as one token rather
            # than reading as literal text the user typed.
            style = if selection_range&.include?(index)
                      Style::SELECTION
                    elsif paste_marker_index?(paste_ranges, index)
                      Style::ACCENT
                    else
                      Style::TEXT
                    end
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
          gutter = Selection.display_only_segment(gutter)
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
          return [["use the mouse or shift+arrows to select text.", Style::MUTED]] if logs_pane_focused?(state)

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

        def compact_harness_status_segments(state)
          metadata = state.fetch("metadata", {}) || {}
          head = metadata.fetch("active_head_harness_label", "").to_s.strip
          worker = metadata.fetch("active_worker_harness_label", "").to_s.strip
          head = Meringue::Harness::Registry.provider_label(metadata["active_head_harness"]) if head.empty? && metadata["active_head_harness"]
          worker = Meringue::Harness::Registry.provider_label(metadata["active_worker_harness"]) if worker.empty? && metadata["active_worker_harness"]
          shared = active_harness_label(state)
          head = shared if head.empty?
          worker = shared if worker.empty?
          return [] if head.empty? && worker.empty?
          return [["harness: ", Style::DIM], [head, Style::ACCENT_BOLD]] if head == worker

          [
            ["head: ", Style::DIM], [head, Style::ACCENT_BOLD],
            [" · worker: ", Style::DIM], [worker, Style::ACCENT_BOLD]
          ]
        end

        def compact_status_segments(state, pending_count)
          working_workers = active_agent_count(state, "worker")
          working_heads = active_agent_count(state, "head")
          return active_status_segments(working_workers, working_heads) if working_workers.positive? || working_heads.positive?
          return [[prompt_count_label(pending_count), Style::ACCENT]] if pending_count.positive?

          []
        end

        # `● 2W 1H` rather than `● active  2W 1H`: the lit dot and the counts
        # already say work is running, so the word only spent width.
        def active_status_segments(working_workers, working_heads)
          segments = [["● ", Style::ACCENT_BOLD]]
          metrics = []
          metrics << ["#{working_workers}W", Style::WORKING] if working_workers.positive?
          metrics << ["#{working_heads}H", Style::ACCENT_BOLD] if working_heads.positive?
          metrics.each_with_index do |metric, index|
            segments << [" ", Style::DIM] unless index.zero?
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

        def slash_suggestion_window_start(count, selected_index, limit: VISIBLE_SUGGESTION_LIMIT)
          return 0 if count <= limit || selected_index.negative?

          max_start = count - limit
          [selected_index - limit + 1, 0].max.clamp(0, max_start)
        end

        def plain_text(line)
          return line.to_s unless line.is_a?(Array)

          line.map { |segment| segment.is_a?(Array) ? segment.first.to_s : segment.to_s }.join
        end
      end
    end
  end
end
