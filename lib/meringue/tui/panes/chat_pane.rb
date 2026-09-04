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
            "human_input" => human_input_segments(state),
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

        # A killed or completed worker keeps its last marker for history; only a live worker is
        # still waiting on someone, so only live workers count here.
        HUMAN_INPUT_TERMINAL_STATUSES = %w[completed killed].freeze

        def human_input_segments(state)
          count = Array(state.fetch("agents", [])).count do |agent|
            next false unless agent.is_a?(Hash) && agent.fetch("type", nil).to_s == "worker"
            next false if HUMAN_INPUT_TERMINAL_STATUSES.include?(agent.fetch("status", nil).to_s)

            Harness::HumanInput.pending_marker?(agent.dig("harness_metadata", "human_input_request"))
          end
          return [] unless count.positive?

          label = count == 1 ? "⚠ 1 agent needs input" : "⚠ #{count} agents need input"
          [[label, Style::WARNING], [" · double-click worker", Style::MUTED]]
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
