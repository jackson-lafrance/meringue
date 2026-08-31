# frozen_string_literal: true

require "time"

module Meringue
  module TUI
    module Panes
      class ChatPane
        VISIBLE_SUGGESTION_LIMIT = 3
        # Choice pickers are lists the user browses rather than hints over the
        # composer, so they get a taller window than slash suggestions while
        # still sharing the same slot, border, and keys.
        MODEL_PICKER_VISIBLE_LIMIT = 10
        QUESTION_PICKER_VISIBLE_LIMIT = 10
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

        # Moves through the rows the composer actually renders, including soft
        # wraps. At the first/last row it deliberately returns the original
        # cursor so App can hand that edge gesture to input-history navigation.
        def composer_vertical_cursor(input_buffer, input_cursor, direction:, width: nil)
          MultilineInput.vertical_cursor(
            input_buffer,
            input_cursor,
            direction: direction,
            width: width
          )
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

          # The idle dashboard is the only place for standing discovery hints.
          # Once the row has changing state, a selection, or a transient command
          # popup, show that context instead of appending a shortcut inventory.
          return prefix unless prefix.empty?
          return [] if slash_prompt?(chat.fetch("input_buffer", ""))

          interaction_hint_segments
        end

        def bottom_right_status_line(state)
          segments = compact_harness_status_segments(state)
          defaults = (state.fetch("metadata", {}) || {}).fetch("agent_session_defaults", {}) || {}
          return [] if segments.empty? && defaults.empty?

          unless defaults.empty?
            role_values = normalized_agent_role_defaults(defaults)
            segments << [" · ", Style::DIM] unless segments.empty?
            segments.concat(compact_model_status_segments(**role_values))
          end
          segments
        end

        # The dashboard footer is assembled from semantic components so shared and
        # split role defaults use one resolution path.
        def status_bar_components(state)
          metadata = state.fetch("metadata", {}) || {}
          defaults = metadata.fetch("agent_session_defaults", {}) || {}
          role_values = defaults.empty? ? nil : normalized_agent_role_defaults(defaults)
          workers = active_agent_count(state, "worker")
          heads = active_agent_count(state, "head")
          {
            "context" => bottom_context_segments(state),
            "open_pull_requests" => bottom_open_pull_request_segments(state),
            "workers" => bottom_worker_count_segments(workers, Settings.quiet_worker_count(state)),
            "heads" => bottom_agent_count_segments(heads, "head", Style::ACCENT_BOLD),
            "harness" => compact_harness_status_segments(state),
            "model" => role_values ? bottom_model_segments(**role_values) : [],
            "thinking" => role_values ? bottom_thinking_segments(**role_values) : []
          }
        end

        # What the bar has to say about where you are right now, as opposed to
        # the standing counts the other components render: which log scope is
        # pinned, the gesture that clears a selected chat target, unanswered
        # questions, and the delivery pull request of the selected target.
        #
        # The worker/head counts that the old combined hint line also carried are
        # deliberately absent, because the `workers` and `heads` components
        # render them; including them here would print each count twice whenever
        # both are placed. The all-open-PR count is absent for the same reason:
        # the `open_pull_requests` component owns it, so the delivery-PR hint is
        # asked for the scoped answer only.
        #
        # With nothing selected and nothing pending there is no context to state,
        # so the idle dashboard falls back to the standing discovery hints. A
        # half-typed slash command suppresses those, since the popup above the
        # bar is already showing that inventory.
        def bottom_context_segments(state)
          chat = chat_state(state)
          segments = log_scope_hint_segments(state)
          segments = join_context_segments(segments, selection_hint_segments(state))
          open_questions = state.fetch("questions", []).count { |question| question["status"] == "open" }
          segments = join_context_segments(segments, [["? #{open_questions}", Style::WARNING]]) if open_questions.positive?
          segments = join_context_segments(segments, delivery_pr_hint_segments(state, include_open_summary: false))
          return segments unless segments.empty?
          return [] if slash_prompt?(chat.fetch("input_buffer", ""))

          interaction_hint_segments
        end

        def join_context_segments(segments, addition)
          return segments if addition.empty?
          return addition if segments.empty?

          segments + [["  ·  ", Style::DIM]] + addition
        end

        # Config and old state files can represent the same effective settings in
        # two ways: a shared top-level value, or one value under each role. Read
        # both forms once and resolve empty strings as absent before deciding how
        # to render. Otherwise a save that moves from a shared value to role
        # overrides can make the right-aligned footer alternate between a compact
        # shared label and a misleading "mixed" placeholder across frames.
        def normalized_agent_role_defaults(defaults)
          shared_model = present_status_value(defaults["model"])
          shared_thinking = present_status_value(defaults["thinking_level"])
          roles = defaults["roles"].is_a?(Hash) ? defaults["roles"] : {}
          values = {}
          %w[head worker].each do |role|
            role_defaults = roles[role]
            role_defaults = {} unless role_defaults.is_a?(Hash)
            values[role] = {
              model: present_status_value(role_defaults["model"]) || shared_model || "unavailable",
              thinking: present_status_value(role_defaults["thinking_level"]) || shared_thinking || "unavailable"
            }
          end
          {
            head_model: values.fetch("head").fetch(:model),
            worker_model: values.fetch("worker").fetch(:model),
            head_thinking: values.fetch("head").fetch(:thinking),
            worker_thinking: values.fetch("worker").fetch(:thinking)
          }
        end

        def present_status_value(value)
          value.to_s.strip unless value.to_s.strip.empty?
        end

        def bottom_open_pull_request_segments(state)
          return [] unless Settings.github_enabled?(state)

          total = OpenPullRequests.count(state)
          [[OpenPullRequests.summary_label(state), total.positive? ? Style::ACCENT_BOLD : Style::MUTED]]
        end

        def bottom_agent_count_segments(count, singular, active_style)
          count = count.to_i
          label = "#{count} #{singular}#{count == 1 ? "" : "s"}"
          count.positive? ? [["● ", active_style], [label, active_style]] : [[label, Style::MUTED]]
        end

        # "3 workers" says how many are running, not whether any of them has stopped saying
        # anything - which is the question a person with several agents in flight actually has.
        def bottom_worker_count_segments(workers, quiet)
          segments = bottom_agent_count_segments(workers, "worker", Style::WORKING)
          return segments unless quiet.positive?

          segments + [[" · ", Style::DIM], ["#{quiet} quiet", Style::WARNING]]
        end


        def bottom_model_segments(head_model:, worker_model:, **)
          if head_model == worker_model
            [["model: ", Style::DIM], [head_model.to_s, Style::MUTED]]
          else
            [
              ["head model: ", Style::DIM], [head_model.to_s, Style::MUTED],
              [" · worker model: ", Style::DIM], [worker_model.to_s, Style::MUTED]
            ]
          end
        end

        def bottom_thinking_segments(head_thinking:, worker_thinking:, **)
          if head_thinking == worker_thinking
            [["thinking: ", Style::DIM], [head_thinking.to_s, Style::MUTED]]
          else
            [
              ["head thinking: ", Style::DIM], [head_thinking.to_s, Style::MUTED],
              [" · worker thinking: ", Style::DIM], [worker_thinking.to_s, Style::MUTED]
            ]
          end
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

        # The popup slot between the logs pane and the composer. Question, model,
        # thinking, theme, harness, open-PR, and slash-command lists are all
        # transient lists
        # over the composer, so they share one geometry, one border, and one
        # keyboard shape instead of introducing another overlay mechanism. A picker
        # wins while it is up.
        #
        # First-run setup is a full-screen Settings mode rather than a popup in
        # this composer slot.
        def popup?(state)
          question_picker?(state) || model_picker?(state) || delivery_pr_picker?(state) || slash_suggestions?(state)
        end

        # How many entry rows the popup shows at once, and therefore how tall the
        # layout should let the box grow.
        def popup_visible_limit(state)
          return QUESTION_PICKER_VISIBLE_LIMIT if question_picker?(state)
          return MODEL_PICKER_VISIBLE_LIMIT if model_picker?(state)

          VISIBLE_SUGGESTION_LIMIT
        end

        def popup_max_box_height(state)
          popup_visible_limit(state) + 2
        end

        def popup_pane_title(state)
          return "open questions" if question_picker?(state)

          if model_picker?(state)
            label = if model_picker_thinking?(state)
                      "thinking"
                    elsif model_picker_theme?(state)
                      "theme"
                    elsif model_picker_harness_picker?(state)
                      "harness"
                    else
                      "models (#{model_picker_harness(state)})"
                    end
            tabs = model_picker_role_tabs?(state) ? " · #{model_picker_tabs(state)}" : ""
            return "#{label}#{tabs}"
          end

          delivery_pr_picker?(state) ? "open pull requests" : "slash commands"
        end

        # Only entries live inside the popup box. The counter and the key hints are
        # *about* the list rather than members of it, so a row that says "1–15 of
        # 27 commands" inside the border reads like a 16th command and costs the
        # list a visible row. The layout draws #popup_footer_line under the box.
        def popup_lines(state)
          return question_picker_lines(state) if question_picker?(state)
          return model_picker_lines(state) if model_picker?(state)

          delivery_pr_picker?(state) ? delivery_pr_picker_lines(state) : slash_suggestion_lines(state)
        end

        # Dim line rendered directly below the popup box: where the window sits in
        # the full list, and the keys that move it. Empty when there is nothing to
        # say, in which case the layout reserves no row for it.
        def popup_footer_line(state)
          return question_picker_footer_line(state) if question_picker?(state)
          return model_picker_footer_line(state) if model_picker?(state)

          delivery_pr_picker?(state) ? delivery_pr_picker_footer_line(state) : slash_suggestion_footer_line(state)
        end

        def question_picker?(state)
          question_picker_state(state).fetch("active", false) == true
        end

        def question_picker_state(state)
          value = chat_state(state).fetch("question_picker", nil)
          value.is_a?(Hash) ? value : {}
        end

        def question_picker_entries(state)
          QuestionPicker.entries(state)
        end

        def question_picker_index(state)
          entries = question_picker_entries(state)
          return NO_SLASH_SELECTION if entries.empty?

          question_picker_state(state).fetch("index", 0).to_i.clamp(0, entries.length - 1)
        end

        def question_picker_window_start(state)
          slash_suggestion_window_start(
            question_picker_entries(state).length,
            question_picker_index(state),
            limit: QUESTION_PICKER_VISIBLE_LIMIT
          )
        end

        def question_picker_lines(state)
          entries = question_picker_entries(state)
          return [[["No open questions.", Style::MUTED]]] if entries.empty?

          selected_index = question_picker_index(state)
          window_start = question_picker_window_start(state)
          entries.drop(window_start).first(QUESTION_PICKER_VISIBLE_LIMIT).map.with_index do |entry, offset|
            question_picker_line(entry, selected: window_start + offset == selected_index)
          end
        end

        def question_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          style = selected ? Style::ACCENT_BOLD : Style::TEXT
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            ["#{entry.fetch("display_number")}. ", style],
            [entry.fetch("id"), selected ? Style::ACCENT_BOLD : Style::MUTED],
            ["  #{entry.fetch("question", "")}", style]
          ]
        end

        def question_picker_footer_line(state)
          total = question_picker_entries(state).length
          return [["Esc closes", Style::DIM]] if total.zero?

          count = if total > QUESTION_PICKER_VISIBLE_LIMIT
                    window_start = question_picker_window_start(state)
                    "#{window_start + 1}–#{[window_start + QUESTION_PICKER_VISIBLE_LIMIT, total].min} of #{total} open questions"
                  else
                    "#{total} open question#{total == 1 ? "" : "s"}"
                  end
          [[count, Style::MUTED], ["  ·  ↑↓ move · Enter inserts /answer · Esc closes", Style::DIM]]
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

        def model_picker_role(state)
          role = model_picker_state(state).fetch("role", "head").to_s.downcase
          %w[head worker].include?(role) ? role : "head"
        end

        def model_picker_kind(state)
          kind = model_picker_state(state).fetch("kind", "model").to_s
          %w[model thinking theme harness].include?(kind) ? kind : "model"
        end

        def model_picker_thinking?(state)
          model_picker_kind(state) == "thinking"
        end

        def model_picker_theme?(state)
          model_picker_kind(state) == "theme"
        end

        def model_picker_harness_picker?(state)
          model_picker_kind(state) == "harness"
        end

        # Themes have no roles at all. Model and thinking have two only while
        # heads and workers keep independent values; in shared mode there is one
        # value and nothing to switch between. Role harnesses are always
        # independent, so the harness picker keeps its tabs either way.
        def model_picker_role_tabs?(state)
          return false if model_picker_theme?(state)
          return true if model_picker_harness_picker?(state)

          model_picker_state(state).fetch("role_tabs", true) != false
        end

        def model_picker_tabs(state)
          role = model_picker_role(state)
          role == "head" ? "[Head]  Worker" : "Head  [Worker]"
        end

        def model_picker_harness(state)
          ModelPicker.harness_for(state, model_picker_state(state).fetch("harness", nil))
        end

        def model_picker_entries(state)
          if model_picker_thinking?(state)
            ModelPicker.thinking_entries(state, role: model_picker_role(state), query: model_picker_query(state))
          elsif model_picker_theme?(state)
            query = model_picker_query(state).downcase
            Style.colorschemes.filter_map.with_index do |theme, index|
              next unless query.empty? || theme.downcase.include?(query)

              {
                "reference" => theme,
                "name" => theme,
                "index" => index
              }
            end
          elsif model_picker_harness_picker?(state)
            query = model_picker_query(state).downcase
            Harness::Registry.provider_choices.filter_map.with_index do |choice, index|
              provider = choice.fetch("provider")
              label = choice.fetch("label")
              next unless query.empty? || provider.downcase.include?(query) || label.downcase.include?(query)

              {
                "reference" => provider,
                "name" => label,
                "description" => choice.fetch("description", "future #{model_picker_role(state)} harness"),
                "index" => index
              }
            end
          else
            ModelPicker.entries(
              state,
              harness: model_picker_harness(state),
              query: model_picker_query(state),
              role: model_picker_role(state)
            )
          end
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
            message = if model_picker_thinking?(state)
                        "No thinking level matches “#{model_picker_query(state)}”."
                      elsif model_picker_theme?(state)
                        "No theme matches “#{model_picker_query(state)}”."
                      elsif model_picker_harness_picker?(state)
                        "No harness matches “#{model_picker_query(state)}”."
                      else
                        ModelPicker.empty_message(state, harness: model_picker_harness(state), query: model_picker_query(state))
                      end
            return [[[message, Style::MUTED]]]
          end

          selected_index = model_picker_index(state)
          window_start = model_picker_window_start(state)
          entries.drop(window_start).first(MODEL_PICKER_VISIBLE_LIMIT).map.with_index do |entry, offset|
            selected = window_start + offset == selected_index
            if model_picker_thinking?(state)
              thinking_picker_line(entry, selected: selected)
            elsif model_picker_theme?(state) || model_picker_harness_picker?(state)
              choice_picker_line(entry, selected: selected)
            else
              model_picker_line(entry, selected: selected)
            end
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
        def thinking_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          details = entry.fetch("description", "").to_s
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            [entry.fetch("level"), selected ? Style::ACCENT_BOLD : Style::TEXT],
            details.empty? ? nil : ["  #{details}", Style::MUTED]
          ].compact
        end

        # No row is labelled as the active choice. The theme picker applies each
        # highlighted theme live, so the dashboard itself already shows which one
        # is current, and the selection color marks the row; a "current" tag next
        # to that is redundant. A name that merely repeats the reference (every
        # theme is listed by its own slug) is dropped for the same reason, so a
        # theme row reads as one word instead of the same word twice.
        def choice_picker_line(entry, selected:)
          marker = selected ? "›" : " "
          reference = entry.fetch("reference", "").to_s
          name = entry.fetch("name", "").to_s
          details = []
          details << name unless name.empty? || name == reference
          details << entry.fetch("description", "") unless entry.fetch("description", "").to_s.empty?
          [
            ["#{marker} ", selected ? Style::ACCENT_BOLD : Style::DIM],
            [entry.fetch("reference"), selected ? Style::ACCENT_BOLD : Style::TEXT],
            details.empty? ? nil : ["  #{details.join(" · ")}", Style::MUTED]
          ].compact
        end

        def model_picker_footer_line(state)
          total = model_picker_entries(state).length
          segments = []
          if total.positive?
            segments << [model_picker_count_label(state, total), Style::MUTED]
          end
          query = model_picker_query(state)
          segments << ["  ·  filter: #{query}", Style::TEXT] unless query.empty?
          action = if model_picker_theme?(state)
                     "Enter applies the theme"
                   elsif model_picker_harness_picker?(state)
                     "Enter applies the harness"
                   else
                     "Enter sets the default"
                   end
          tabs = model_picker_role_tabs?(state) ? " · ←→ switch role" : ""
          refresh = model_picker_theme?(state) || model_picker_harness_picker?(state) ? "" : " · Ctrl-R refreshes"
          segments << ["#{segments.empty? ? "" : "  ·  "}type to filter · ↑↓ move#{tabs} · #{action}#{refresh} · Esc closes", Style::DIM]
          segments
        end

        def model_picker_count_label(state, total)
          kind_label = if model_picker_thinking?(state)
                         "thinking level"
                       elsif model_picker_theme?(state)
                         "theme"
                       elsif model_picker_harness_picker?(state)
                         "harness"
                       else
                         "model"
                       end
          noun = total == 1 ? kind_label : "#{kind_label}s"
          label = if total > MODEL_PICKER_VISIBLE_LIMIT
                    window_start = model_picker_window_start(state)
                    "#{window_start + 1}–#{[window_start + MODEL_PICKER_VISIBLE_LIMIT, total].min} of #{total} #{noun}"
                  else
                    "#{total} #{noun}"
                  end
          return label unless model_picker_kind(state) == "model"

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
          input_buffer.to_s.strip.start_with?("/") || Meringue::Input::SlashCommandParser.inline_suggestion_active?(input_buffer)
        end

        private












        # Gestures for the current selection, never its identity: the composer
        # title one row above already names the target, so this only says that a
        # slash command ignores the selection or that Esc clears it. With nothing
        # selected it is empty, leaving the width to status and discovery hints.


        # One PR only when the dashboard is actually looking at one node. Unscoped
        # chat is not about a single worker, so it reports how many PRs are open
        # across the tree instead of pinning whichever worker happened to be
        # focused last. Ctrl-B is not advertised inline: the keybinding still works
        # and `/keybind` documents it, but repeating it on every frame cost the
        # width this line needs for everything else.


        # Silence when the tree has never had a delivery PR: there is nothing to
        # count and nothing for Ctrl-B to open. Once PRs exist, "no open PRs" is a
        # plain fact rather than the old "PR unavailable", which read like a fault.

        # Input editing and reconciliation metadata do not change the logs pane,
        # but the layout asks for the complete wrapped history twice per frame.
        # Key the cache by compact presentation fields instead of deep-hashing
        # every retained log and complete agent record on each request.

        # Independent durable logs append, retention removes from the front, and a replaceable
        # status removes its predecessor before appending a fresh last id. The boundaries and count
        # therefore identify every visible window change without deep-reading Markdown-heavy details.






















        # Compare absolute instants so UTC-stored and local-stored timestamps interleave correctly.







        # Headers contain agent-written titles and can be wider than the pane even
        # though message bodies are wrapped. Split them into styled rows too, so a
        # narrow terminal scrolls through the header instead of losing its suffix
        # at the right edge.


        # Agent lines are colored per agent id; everything else keeps the
        # kernel/user styles so agent output stays separable from kernel logs.




















        # Wrapping is computed from the buffer itself (not from a buffer with the
        # cursor marker spliced in) so visual rows map back to exact character
        # indexes for mouse selection.




        # Input text itself always keeps Style::TEXT (and SELECTION inside a
        # highlight): the tint only reaches the prompt marker, so typed text
        # stays at full contrast in every colorscheme.





        # Keep only the small idle-state discovery line here. Enter is the
        # familiar submit action, and complete bindings belong in /keybind rather
        # than consuming a row on every frame.




        # `● 2W 1H` rather than `● active  2W 1H`: the lit dot and the counts
        # already say work is running, so the word only spent width.






      end
    end
  end
end
