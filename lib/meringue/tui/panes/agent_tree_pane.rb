# frozen_string_literal: true

require_relative "../../goals/record"

module Meringue
  module TUI
    module Panes
      class AgentTreePane
        MAX_ITEM_LINES = 3
        ELLIPSIS = "…"
        AGENT_TYPES = %w[head worker].freeze
        # A queued worker waiting on a command shows that command (or its label) in the row, so
        # it is bounded the same way every other tree marker is.
        GATE_LABEL_LIMIT = 28

        # Shown when a goal has a numeric target but nothing measurable to compare against
        # it yet: honest about the gap instead of implying 0% progress was made.
        GOAL_UNKNOWN_PERCENT = "?%"
        # A settled goal says why it settled in words a user can read at a glance.
        GOAL_STOP_LABELS = {
          "goal_met" => "goal met",
          "user_stopped" => "stopped by you",
          "killed" => "killed",
          "max_iterations" => "stopped: out of iterations",
          "budget_exhausted" => "stopped: out of budget",
          "probe_unavailable" => "stopped: metric unreadable"
        }.freeze

        # One wrapped row of a tree item, plus where it started in the laid-out content.
        # The offset is what lets a suffix chip keep its color when the wrap splits it across
        # lines: the chip is located by position rather than by matching text at a line end.
        Chunk = Struct.new(:text, :offset, :elided)
        # The wrapped rows of one item together with the index at which the suffix chips begin
        # in the text those rows were wrapped from.
        ContentLayout = Struct.new(:chunks, :suffix_start)

        STATUS_DOTS = {
          "queued" => "○",
          "working" => "●",
          "idle" => "·",
          "blocked" => "!",
          "completed" => "✓",
          "errored" => "×",
          "killed" => "∅"
        }.freeze

        STATUS_STYLES = {
          "queued" => Style::QUEUED,
          "working" => Style::WORKING,
          "idle" => Style::IDLE,
          "blocked" => Style::WARNING,
          "completed" => Style::SUCCESS,
          "errored" => Style::ERROR,
          "killed" => Style::DIM
        }.freeze

        def render(state, width: nil)
          lines(state, width: width).map { |line| plain_text(line) }.join("\n")
        end

        def lines(state, width: nil)
          projects = records(state, "projects")
          issues = records(state, "issues")
          agents = records(state, "agents")
          # Both the jump-mode cursor and the sticky logs selection render as a
          # selected row, so the highlight survives focus changes.
          selected_agent_id = AgentTreeNavigation.highlighted_ids_for(state)

          goals = records(state, "goals")

          output = []
          append_heads(output, agents, selected_agent_id, width)
          append_projects(output, projects, issues, agents, selected_agent_id, width, goals)
          output.empty? ? [[['No AgentTree data yet.', Style::MUTED]]] : output
        end

        def line_item_ids(state, width: nil)
          projects = records(state, "projects")
          issues = records(state, "issues")
          agents = records(state, "agents")
          selected_agent_id = AgentTreeNavigation.highlighted_ids_for(state)

          goals = records(state, "goals")

          output = []
          append_head_worker_ids(output, agents, selected_agent_id, width)
          append_project_worker_ids(output, projects, issues, agents, selected_agent_id, width, goals)
          output.empty? ? [nil] : output
        end

        # Compatibility for callers from before issue/head rows became clickable.
        def line_worker_ids(state, width: nil)
          line_item_ids(state, width: width)
        end

        private

        def records(state, key)
          entries = state.fetch(key, []) || []
          return entries unless %w[projects issues].include?(key)

          # Killed projects and issues are removed by the kernel, but state written by an older
          # Meringue version can still contain them. Never render a killed subtree.
          entries.reject { |entry| entry.is_a?(Hash) && entry["status"] == "killed" }
        end

        def append_heads(output, agents, selected_agent_id, width)
          heads = agents.select { |agent| agent["type"] == "head" }.sort_by { |agent| sort_key(agent["id"]) }
          return if heads.empty?

          output << section_line("heads")
          heads.each_with_index do |head, index|
            output.concat(item_lines(
              prefix: index == heads.length - 1 ? "└─" : "├─",
              record: head,
              id: head.fetch("id"),
              title: record_title(head),
              suffix: head_suffix(head),
              selected: AgentTreeNavigation.selected_agent?(head, selected_agent_id),
              width: width
            ))
          end
          output << spacer_line
        end

        def append_head_worker_ids(output, agents, selected_agent_id, width)
          heads = agents.select { |agent| agent["type"] == "head" }.sort_by { |agent| sort_key(agent["id"]) }
          return if heads.empty?

          output << nil
          heads.each_with_index do |head, index|
            output.concat(Array.new(item_line_count(
              prefix: index == heads.length - 1 ? "└─" : "├─",
              record: head,
              id: head.fetch("id"),
              title: record_title(head),
              suffix: head_suffix(head),
              selected: AgentTreeNavigation.selected_agent?(head, selected_agent_id),
              width: width
            ), head.fetch("id")))
          end
          output << nil
        end

        def append_projects(output, projects, issues, agents, selected_agent_id, width, goals = [])
          sorted_projects = projects.sort_by { |project| sort_key(project["id"]) }
          sorted_projects.each_with_index do |project, index|
            output.concat(project_lines(project, width: width, selected: AgentTreeNavigation.selected_agent?(project, selected_agent_id)))

            project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
            issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
            render_issues(output, issues_by_parent, agents, selected_agent_id: selected_agent_id, parent_id: nil, prefix: "", width: width, goals: goals)
            output << spacer_line unless index == sorted_projects.length - 1
          end
        end

        def render_issues(output, issues_by_parent, agents, selected_agent_id:, parent_id:, prefix:, width:, goals: [])
          child_issues = issues_by_parent.fetch(parent_id, []).sort_by { |issue| sort_key(issue["id"]) }

          child_issues.each_with_index do |issue, issue_index|
            issue_last = issue_index == child_issues.length - 1
            connector = issue_last ? "└─" : "├─"
            next_prefix = "#{prefix}#{issue_last ? "  " : "│ "}"
            workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] }

            output.concat(item_lines(**issue_row_arguments(
              issue,
              workers,
              goals,
              prefix: "#{prefix}#{connector}",
              selected: AgentTreeNavigation.selected_agent?(issue, selected_agent_id),
              width: width
            )))

            workers.sort_by { |worker| sort_key(worker["id"]) }.each_with_index do |worker, worker_index|
              worker_last = worker_index == workers.length - 1 && issues_by_parent.fetch(issue["id"], []).empty?
              output.concat(item_lines(
                prefix: "#{next_prefix}#{worker_last ? "└─" : "├─"}",
                record: worker,
                id: short_id(worker["id"]),
                title: record_title(worker),
                suffix: worker_suffix(worker, issue),
                selected: AgentTreeNavigation.selected_agent?(worker, selected_agent_id),
                width: width
              ))
            end

            render_issues(output, issues_by_parent, agents, selected_agent_id: selected_agent_id, parent_id: issue["id"], prefix: next_prefix, width: width, goals: goals)
          end
        end

        def append_project_worker_ids(output, projects, issues, agents, selected_agent_id, width, goals = [])
          sorted_projects = projects.sort_by { |project| sort_key(project["id"]) }
          sorted_projects.each_with_index do |project, index|
            # Project rows are clickable, so they carry their own id for hit-testing.
            # The same selected flag is passed here and in #lines so wrapped row
            # counts stay aligned with the rendered rows.
            project_line_count = project_lines(project, width: width, selected: AgentTreeNavigation.selected_agent?(project, selected_agent_id)).length
            output.concat(Array.new(project_line_count, project.fetch("id")))

            project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
            issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
            append_issue_worker_ids(output, issues_by_parent, agents, selected_agent_id: selected_agent_id, parent_id: nil, prefix: "", width: width, goals: goals)
            output << nil unless index == sorted_projects.length - 1
          end
        end

        def append_issue_worker_ids(output, issues_by_parent, agents, selected_agent_id:, parent_id:, prefix:, width:, goals: [])
          child_issues = issues_by_parent.fetch(parent_id, []).sort_by { |issue| sort_key(issue["id"]) }

          child_issues.each_with_index do |issue, issue_index|
            issue_last = issue_index == child_issues.length - 1
            connector = issue_last ? "└─" : "├─"
            next_prefix = "#{prefix}#{issue_last ? "  " : "│ "}"
            workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] }

            output.concat(Array.new(item_line_count(**issue_row_arguments(
              issue,
              workers,
              goals,
              prefix: "#{prefix}#{connector}",
              selected: AgentTreeNavigation.selected_agent?(issue, selected_agent_id),
              width: width
            )), issue.fetch("id")))

            workers.sort_by { |worker| sort_key(worker["id"]) }.each_with_index do |worker, worker_index|
              worker_last = worker_index == workers.length - 1 && issues_by_parent.fetch(issue["id"], []).empty?
              line_count = item_line_count(
                prefix: "#{next_prefix}#{worker_last ? "└─" : "├─"}",
                record: worker,
                id: short_id(worker["id"]),
                title: record_title(worker),
                suffix: worker_suffix(worker, issue),
                selected: AgentTreeNavigation.selected_agent?(worker, selected_agent_id),
                width: width
              )
              output.concat(Array.new(line_count, worker.fetch("id")))
            end

            # The goals must be carried into nested issues too: a goal chip changes how a row
            # wraps, so dropping it here would desynchronise the hit-test map from the render.
            append_issue_worker_ids(output, issues_by_parent, agents, selected_agent_id: selected_agent_id, parent_id: issue["id"], prefix: next_prefix, width: width, goals: goals)
          end
        end

        # The render path and the id-listing path build issue rows from exactly the same
        # arguments, so a goal row can never wrap to a different number of lines than the
        # clickable-row map expects.
        def issue_row_arguments(issue, workers, goals, prefix:, selected:, width:)
          goal = goal_for(issue, goals)
          {
            prefix: prefix,
            record: issue,
            id: short_id(issue["id"]),
            title: issue.fetch("title", "Untitled issue"),
            suffix: issue_suffix(issue, workers, goal),
            selected: selected,
            width: width
          }
        end

        def item_line_count(prefix:, record:, id:, title:, suffix: "", selected: false, width: nil)
          item_lines(prefix: prefix, record: record, id: id, title: title, suffix: suffix, selected: selected, width: width).length
        end

        def section_line(title)
          [[title.upcase, Style::DIM]]
        end

        def spacer_line
          [["", Style::DIM]]
        end

        # A selected project keeps the exact leader width of an unselected one, so
        # selecting it can never reflow the rows under the mouse. The marker takes
        # over the two separator columns instead of adding an indent, which keeps
        # the selection visible even with colors disabled.
        def project_lines(project, width: nil, selected: false)
          leader_segments = if selected
                              [
                                [status_dot(project), Style::AGENT_TREE_SELECTED_STATUS],
                                [" #{project.fetch("id")}", Style::AGENT_TREE_SELECTED_DIM],
                                [" ▸", Style::AGENT_TREE_SELECTED_STATUS]
                              ]
                            else
                              [
                                [status_dot(project), status_style(project)],
                                [" #{project.fetch("id")}", Style::MUTED],
                                ["  ", Style::DIM]
                              ]
                            end
          content = project_title(project)
          title_style = selected ? Style::AGENT_TREE_SELECTED : Style::TITLE
          wrapped_lines(
            leader_segments,
            content,
            title_style: title_style,
            continuation_style: title_style,
            width: width,
            selected: selected
          )
        end

        # A project row shows the product name and nothing else. Its lifecycle status is
        # already carried by the status dot, exactly like issue and worker rows, so the
        # label must never read "Meringue working". A stored name that still carries a
        # status word (written by an older Meringue, or not yet re-saved after the state
        # repair) is cleaned here too, so the user never reads the polluted label.
        def project_title(project)
          ProjectNaming.without_status_suffix(project.fetch("name", nil)) || "Untitled project"
        end

        def item_lines(prefix:, record:, id:, title:, suffix: "", selected: false, width: nil)
          parts = suffix_parts(suffix)
          suffix_text = suffix_parts_text(parts)
          content = [title, suffix_text.empty? ? nil : suffix_text].compact.join("  ")
          if selected
            selected_item_lines(prefix: prefix, record: record, id: id, content: content, suffix_parts: parts, width: width)
          else
            normal_item_lines(prefix: prefix, record: record, id: id, content: content, suffix_parts: parts, width: width)
          end
        end

        # A suffix is an ordered list of [text, kind] chips so the goal chip can keep its own
        # color next to the PR marker instead of the whole suffix sharing one style. Plain
        # strings (head and worker rows) still work and render as one marker chip.
        def suffix_parts(suffix)
          entries = suffix.is_a?(Array) ? suffix : [[suffix.to_s, :marker]]
          entries.filter_map do |entry|
            text, kind = entry.is_a?(Array) ? entry : [entry, :marker]
            text = text.to_s
            next nil if text.empty?

            [text, kind || :marker]
          end
        end

        def suffix_parts_text(parts)
          parts.map { |part| part.fetch(0) }.join(" ")
        end

        # The chips exactly as they appear in the wrapped content: the row text is whitespace
        # normalized before it is wrapped, so the chips have to be normalized the same way for
        # their positions inside that text to line up.
        def suffix_chips(parts)
          parts.filter_map do |text, kind|
            normalized = normalized_content(text).strip
            next nil if normalized.empty?

            [normalized, kind]
          end
        end

        def chips_text(chips)
          chips.map { |chip| chip.fetch(0) }.join(" ")
        end

        def suffix_style(kind, selected)
          if kind == :goal
            selected ? Style::GOAL_MARKER_SELECTED : Style::GOAL_MARKER
          else
            selected ? Style::PR_MARKER_SELECTED : Style::PR_MARKER
          end
        end

        def normal_item_lines(prefix:, record:, id:, content:, suffix_parts: [], width: nil)
          # Reserve the same two columns used by the selected-row marker so
          # selecting an item cannot reflow wrapped rows under the mouse.
          leader_segments = [
            ["  ", Style::DIM],
            ["#{prefix} ", Style::DIM],
            [status_dot(record), status_style(record)],
            [" #{id}", identity_style(record) || Style::MUTED],
            ["  ", Style::DIM]
          ]
          wrapped_lines(
            leader_segments,
            content,
            title_style: title_style(record),
            continuation_style: title_style(record),
            width: width,
            continuation_segments: normal_continuation_segments(prefix, record, id),
            suffix_parts: suffix_parts
          )
        end

        # The selected row keeps its own high-contrast palette rather than the
        # agent's identity color: it already owns the highlight and explicit
        # selection marker, and an identity foreground on the selection
        # background is not guaranteed to stay legible in every theme.
        def selected_item_lines(prefix:, record:, id:, content:, suffix_parts: [], width: nil)
          leader_segments = [
            ["▸", Style::AGENT_TREE_SELECTED_STATUS],
            [" #{prefix} ", Style::AGENT_TREE_SELECTED_DIM],
            [status_dot(record), Style::AGENT_TREE_SELECTED_STATUS],
            [" #{id}", Style::AGENT_TREE_SELECTED_DIM],
            ["  ", Style::AGENT_TREE_SELECTED_DIM]
          ]
          wrapped_lines(
            leader_segments,
            content,
            title_style: Style::AGENT_TREE_SELECTED,
            continuation_style: Style::AGENT_TREE_SELECTED,
            width: width,
            selected: true,
            continuation_segments: selected_continuation_segments(prefix, record, id),
            suffix_parts: suffix_parts
          )
        end

        def wrapped_lines(leader_segments, content, title_style:, continuation_style:, width:, selected: false,
                          continuation_segments: nil, suffix_parts: [])
          leader_text = plain_text(leader_segments)
          continuation_segments ||= [[" " * leader_text.length, selected ? Style::AGENT_TREE_SELECTED_DIM : Style::DIM]]
          content_width = wrapped_content_width(width, leader_text.length)
          chips = suffix_chips(suffix_parts)
          layout = wrap_content(content, content_width, chips_text(chips))

          layout.chunks.each_with_index.map do |chunk, index|
            leader = index.zero? ? leader_segments : continuation_segments
            body_style = index.zero? ? title_style : continuation_style
            segments = leader + chunk_segments(chunk, layout.suffix_start, chips, body_style, selected)
            selected ? pad_selected_line(segments, width) : segments
          end
        end

        def wrapped_content_width(width, leader_length)
          return nil unless width

          [width.to_i - leader_length, 1].max
        end

        # Suffix chips are located by their position in the wrapped content, not by matching
        # text at the end of a line. A chip is row status ("waiting on CI concluded on…",
        # "1/3", "↗", the goal chip) and it must keep its accent no matter where the wrap
        # falls, including when one chip is split over two rows or shares a row with the tail
        # of the title. Regression: a long "waiting on <label>" chip that wrapped matched no
        # line end, so the whole suffix silently fell back to the plain title style.
        def chunk_segments(chunk, suffix_start, chips, body_style, selected)
          text = chunk.text.to_s
          return [[text, body_style]] if text.empty? || suffix_start.nil? || chips.empty?
          # Rows that stop before the suffix begins (the title lines of a wrapped row) are the
          # common case and never need a per-character pass.
          return [[text, body_style]] if chunk.offset + text.length <= suffix_start

          segments = []
          buffer = +""
          buffer_style = nil
          text.each_char.with_index do |char, index|
            # A trailing "…" is synthetic: it has no source character, so it inherits the style
            # of the character before it rather than reading past the end of the row.
            elided_tail = chunk.elided && index.positive? && index == text.length - 1
            style = style_at(chunk.offset + (elided_tail ? index - 1 : index), suffix_start, chips, body_style, selected)
            if buffer_style.nil? || style == buffer_style
              buffer_style = style
              buffer << char
            else
              segments << [buffer, buffer_style]
              buffer = char.dup
              buffer_style = style
            end
          end
          segments << [buffer, buffer_style] unless buffer.empty?
          segments
        end

        def style_at(position, suffix_start, chips, body_style, selected)
          return body_style if position < suffix_start

          kind = chip_kind_at(position - suffix_start, chips)
          kind.nil? ? body_style : suffix_style(kind, selected)
        end

        # Chips are joined by a single space inside the suffix. The separator is styled with
        # the chip that follows it, so two adjacent chips never show an unstyled gap.
        def chip_kind_at(offset, chips)
          cursor = 0
          chips.each_with_index do |(text, kind), index|
            start = index.zero? ? cursor : cursor - 1
            finish = cursor + text.length
            return kind if offset >= start && offset < finish

            cursor = finish + 1
          end

          nil
        end

        def normal_continuation_segments(prefix, record, id)
          [
            ["  ", Style::DIM],
            ["#{continuation_prefix(prefix)} ", Style::DIM],
            [" " * status_dot(record).length, Style::DIM],
            [" " * (id.to_s.length + 1), Style::DIM],
            ["  ", Style::DIM]
          ]
        end

        def selected_continuation_segments(prefix, record, id)
          [
            [" ", Style::AGENT_TREE_SELECTED_DIM],
            [" #{continuation_prefix(prefix)} ", Style::AGENT_TREE_SELECTED_DIM],
            [" " * status_dot(record).length, Style::AGENT_TREE_SELECTED_DIM],
            [" " * (id.to_s.length + 1), Style::AGENT_TREE_SELECTED_DIM],
            ["  ", Style::AGENT_TREE_SELECTED_DIM]
          ]
        end

        def continuation_prefix(prefix)
          case prefix
          when /├─\z/
            "#{prefix[0...-2]}│ "
          when /└─\z/
            "#{prefix[0...-2]}  "
          else
            " " * prefix.length
          end
        end

        # `suffix` is the already-normalized chip text, so it can be located inside the
        # normalized content by position.
        def wrap_content(content, width, suffix = "")
          text = normalized_content(content)
          return content_layout(text, [Chunk.new(text, 0)], suffix) unless width

          lines = split_wrapped_lines(text, width)
          return content_layout(text, lines, suffix) if lines.length <= MAX_ITEM_LINES

          fitted = fit_lines_keeping_suffix(text, suffix, width)
          return fitted if fitted

          visible = lines.first(MAX_ITEM_LINES)
          visible[-1] = Chunk.new(ellipsize(visible.last.text, width), visible.last.offset, true)
          content_layout(text, visible, suffix)
        end

        def content_layout(text, chunks, suffix)
          start = suffix.to_s.empty? || !text.end_with?(suffix) ? nil : text.length - suffix.length
          ContentLayout.new(chunks, start)
        end

        # The goal chip and the PR marker are the row's status, not decoration, so an
        # over-long title is ellipsized until they fit rather than allowed to push them off
        # the row. Line count only grows with the title, so a binary search finds the longest
        # title that still leaves the markers visible in a handful of cheap wraps.
        def fit_lines_keeping_suffix(text, suffix, width)
          return nil if suffix.empty? || !text.end_with?(suffix)

          head = text[0...-suffix.length].rstrip
          return nil if head.empty?

          low = 0
          high = head.length
          best = nil
          while low <= high
            middle = (low + high) / 2
            candidate = content_keeping_suffix(head, middle, suffix)
            lines = split_wrapped_lines(candidate, width)
            if lines.length <= MAX_ITEM_LINES
              # The suffix survives, but at a new offset: the layout is rebuilt from the
              # truncated text so chip positions stay correct.
              best = content_layout(candidate, lines, suffix)
              low = middle + 1
            else
              high = middle - 1
            end
          end

          best
        end

        def content_keeping_suffix(head, length, suffix)
          truncated = head[0, length].to_s.rstrip
          truncated = "#{truncated}#{ELLIPSIS}" unless truncated.empty?
          [truncated, suffix].reject(&:empty?).join("  ")
        end

        def normalized_content(content)
          value = content.to_s.gsub(/[[:cntrl:]]+/, " ").gsub(/\s+/, " ").strip
          value.empty? ? " " : value
        end

        # Returns Chunks rather than bare strings: the offset of each wrapped row into `text`
        # is what keeps suffix chip styling correct across a wrap.
        def split_wrapped_lines(text, width)
          cursor = 0
          lines = []

          while cursor < text.length
            remaining = text[cursor..].to_s
            if remaining.length <= width
              lines << Chunk.new(remaining, cursor)
              break
            end

            slice = remaining[0, width + 1]
            break_at = slice.rindex(" ") || width
            break_at = width if break_at <= 0
            lines << Chunk.new(remaining[0, break_at].rstrip, cursor)
            tail = remaining[break_at..].to_s
            # Wrapping drops the whitespace it broke on, so the next row's offset has to skip it.
            cursor += break_at + (tail.length - tail.lstrip.length)
          end

          lines.empty? ? [Chunk.new(" ", 0)] : lines
        end

        def ellipsize(text, width)
          return ELLIPSIS if width <= 1

          base = text.to_s.rstrip
          return "#{base[0, width - 1].rstrip}#{ELLIPSIS}" if base.length >= width

          "#{base}#{ELLIPSIS}"
        end

        def pad_selected_line(segments, width)
          return segments unless width

          remaining = width.to_i - plain_text(segments).length
          remaining.positive? ? segments + [[" " * remaining, Style::AGENT_TREE_SELECTED_DIM]] : segments
        end

        def status_dot(record)
          STATUS_DOTS.fetch(record["status"], "?")
        end

        def status_style(record)
          STATUS_STYLES.fetch(record["status"], Style::MUTED)
        end

        def title_style(record)
          record["status"] == "completed" ? Style::MUTED : Style::TEXT
        end

        def agent_record?(record)
          AGENT_TYPES.include?(record["type"].to_s)
        end

        # Identity color for an agent row: the same per-id assignment the logs
        # pane and the chat composer use (Style::AGENT_PALETTE via
        # Style.agent_palette_index, lib/meringue/tui/style.rb), so one agent is
        # the same color in the tree, in its log rows, and in the composer that
        # prompts it. There is no second palette and no per-status palette.
        #
        # Deliberately status-independent: a working agent and a completed,
        # blocked, errored, or killed one all keep their identity. Status stays
        # legible next to it through the status glyph's own semantic color and
        # the muted title of a completed row, so color is additive.
        def identity_style(record)
          return nil unless agent_record?(record)

          Style.agent_body_style(record.fetch("id", "").to_s)
        end

        def record_title(record)
          metadata = record.fetch("harness_metadata", {}) || {}
          metadata.fetch("title", "#{record.fetch("type", "item")} session")
        end

        # A goal loop is rendered on the issue it controls, not as a new node kind: the
        # AgentTree stays projects -> issues -> workers. The goal is its own suffix chip with
        # its own color, carrying the iteration and percent complete, so it reads as goal
        # state rather than as more issue text. Deliberately no badge glyph beside the issue
        # id: the numbers are the signal, and the row keeps the leader every other row has.
        def issue_suffix(issue, workers, goal = nil)
          [
            [goal_marker(goal), :goal],
            # A goal issue already reports progress as iteration and percent complete; the
            # worker ratio beside that reads as a second, conflicting fraction, so the goal
            # chip stands in for it. Every other issue keeps the ordinary worker ratio.
            [goal ? "" : progress(workers), :marker],
            # Delivery PRs are issue state. Older snapshots may still have the record on a
            # worker until the state migration runs, so use that only as an issue-row fallback;
            # never copy the marker onto each worker row.
            [active_pr_marker(issue, workers), :marker]
          ].reject { |text, _kind| text.to_s.empty? }
        end

        def goal_for(issue, goals)
          Array(goals).find { |candidate| candidate.is_a?(Hash) && candidate["issue_id"] == issue["id"] }
        end

        # "<iteration>/<budget> <percent/review state>" plus the goal's paused/stopped state.
        # The iteration ratio is budget spent; the second label is either numeric progress
        # toward a metric target or, for reviewer-judged loops, the reviewer's latest verdict.
        def goal_marker(goal)
          return "" unless goal.is_a?(Hash)

          budget = goal["budget"].is_a?(Hash) ? goal["budget"] : {}
          parts = ["#{goal["current_iteration"].to_i}/#{budget["max_iterations"].to_i}"]
          parts << if Goals::Record.reviewer_judged?(goal)
                     # A reviewer-judged goal has no number to show, so the tree shows where the
                     # reviewer stands instead: that is the only progress signal it has.
                     Goals::Record.review_state(goal)
                   else
                     goal_percent_label(goal)
                   end
          parts << "paused" if goal["paused"]
          parts << goal_stop_label(goal["stop_reason"])
          parts.reject { |part| part.to_s.empty? }.join(" ")
        end

        # The progress reading, in order of how much the record can honestly support:
        # a percentage when the metric has a baseline to have travelled from, the raw
        # "where it is now -> where it needs to be" pair when it does not, and an explicit
        # unknown when nothing numeric has been measured at all. A goal with no numeric
        # target (a reviewer-judged loop) has nothing to be a percentage of, so it shows its
        # iteration alone rather than a fabricated reading.
        def goal_percent_label(goal)
          view = goal_metric_view(goal)
          target = Goals::Record.target(view)
          return "" if target.nil?

          percent = goal_percent(goal)
          return "#{percent}%" if percent

          latest = Goals::Record.metric_value(view["last_metric"])
          return GOAL_UNKNOWN_PERCENT if latest.nil?

          "#{goal_number(latest)}→#{goal_number(target)}"
        end

        def goal_number(value)
          number = Goals::Record.float_or_nil(value)
          return "?" if number.nil?

          number == number.round ? number.round.to_s : format("%.1f", number)
        end

        # Percent complete is progress *made*, not budget *spent*: how far the metric has
        # travelled from the baseline the goal started at toward its target.
        # Meringue::Goals::Record owns that formula and the kernel scores every iteration
        # with it, so the tree reuses it rather than inventing a second reading of the same
        # numbers. It is comparator aware, so an `lte` goal driving a number down reads the
        # same way an increasing one does. Returns nil whenever the honest answer is
        # "unknown": nothing measured yet, a non-numeric measurement, or no baseline to
        # measure travel from.
        def goal_percent(goal)
          view = goal_metric_view(goal)
          baseline = Goals::Record.metric_value(view["baseline_metric"])
          measured = Goals::Record.metric_value(view["last_metric"])
          value = measured.nil? ? baseline : measured
          return nil if value.nil?
          return 100 if Goals::Record.target_satisfied?(view, value)
          return nil if baseline.nil?

          score = Goals::Record.progress_score(view, value)
          return nil if score.nil?

          # Only a satisfied target may read 100%, and an unmeasurable step never reads below 0%.
          (score * 100).round.clamp(0, 99)
        end

        # Hand-edited or older state can hold anything, and Goals::Record digs through these
        # keys, so the pane hands it a shape it can always read.
        def goal_metric_view(goal)
          {
            "metric" => goal["metric"].is_a?(Hash) ? goal["metric"] : {},
            "baseline_metric" => goal["baseline_metric"].is_a?(Hash) ? goal["baseline_metric"] : nil,
            "last_metric" => goal["last_metric"].is_a?(Hash) ? goal["last_metric"] : nil
          }
        end

        def goal_stop_label(stop_reason)
          reason = stop_reason.to_s
          return "" if reason.strip.empty?

          GOAL_STOP_LABELS.fetch(reason, "stopped: #{reason.tr("_", " ")}")
        end

        def progress(workers)
          visible_workers = workers.reject { |worker| worker["status"] == "killed" && worker["replaced_by_agent_id"] }
          return "" if visible_workers.empty?

          completed = visible_workers.count { |worker| worker["status"] == "completed" }
          "#{completed}/#{visible_workers.length}"
        end

        def worker_suffix(worker, _issue = nil)
          # Delivery PRs belong to the issue row. Worker rows retain only worker/session state,
          # so a replacement or a second worker cannot duplicate the issue's PR affordance.
          [
            provisioning_marker(worker),
            unfinished_marker(worker),
            worker_relationship_marker(worker)
          ].reject(&:empty?).join(" ")
        end

        # A worker with no session yet is either having its workspace checked out, waiting for an
        # automatic retry, or waiting for the user. Those read identically without a marker: all
        # three are just a queued or blocked dot with no output.
        def provisioning_marker(worker)
          metadata = worker.is_a?(Hash) ? (worker["harness_metadata"] || {}) : {}
          return "" unless metadata.is_a?(Hash)

          case metadata["provisioning_state"].to_s
          when "allocating_workspace" then ["provisioning workspace", provisioning_detail(metadata)].compact.join(" ")
          when "retry_pending" then "workspace retry #{provisioning_attempt(metadata)}"
          when "retry_exhausted" then "workspace failed: prompt to retry"
          when "failed" then "workspace failed"
          else ""
          end
        end

        def provisioning_detail(metadata)
          progress = metadata["provisioning_progress"]
          return nil unless progress.is_a?(Hash)

          # `percent` is Git's checkout percentage, never a fabricated percentage for the full
          # worker lifecycle. Older records only have the raw detail, so retain that fallback while
          # newer kernel records can render the structured value without parsing Git output here.
          percent = progress["percent"]
          percent = progress["detail"].to_s[/\d+%/] if percent.nil?
          if percent
            percent = percent.to_s.delete_suffix("%")
            return "#{percent}%"
          end

          phase = progress["phase"].to_s.strip
          elapsed = progress["elapsed_seconds"] ? "#{progress["elapsed_seconds"].to_f.round}s" : nil
          [phase.empty? ? nil : phase, elapsed].compact.join(" ").yield_self { |value| value.empty? ? nil : value }
        end

        def provisioning_attempt(metadata)
          attempts = metadata["provisioning_attempts"].to_i
          limit = metadata["provisioning_attempt_limit"].to_i
          return "pending" unless limit.positive?

          "#{[attempts + 1, limit].min}/#{limit}"
        end

        # An errored worker whose turn died mid-flight reads differently from one that failed its
        # work, so the row says so instead of only showing the error dot.
        def unfinished_marker(worker)
          metadata = worker.is_a?(Hash) ? (worker["harness_metadata"] || {}) : {}
          return "" unless metadata.is_a?(Hash) && metadata["settle_failure"].is_a?(Hash)

          case metadata["settle_failure"]["kind"].to_s
          when "network_failure" then "stopped: connection lost"
          # Not resumable: its saved session is what the provider rejected, so the row must not read
          # like something a prompt will pick up where it left off.
          when "unreplayable_session" then "stopped: session unusable"
          else "stopped mid-turn"
          end
        end

        def worker_relationship_marker(worker)
          # A worker that has not started yet must say so, and say who it is waiting for; otherwise a
          # queued dependent looks identical to a worker whose session is still being provisioned.
          waiting = deferred_wait_marker(worker)
          return waiting unless waiting.empty?
          completion_wait = completion_wait_marker(worker)
          return completion_wait unless completion_wait.empty?
          return "replaces #{short_id(worker.fetch("replaces_agent_id"))}" if worker["replaces_agent_id"]
          return "after #{short_id(worker.fetch("follow_up_of_agent_id"))}" if unstarted_follow_up?(worker)
          return "replaced by #{short_id(worker.fetch("replaced_by_agent_id"))}" if worker["replaced_by_agent_id"]

          ""
        end

        # Lineage answers a pre-start question: "why is this row not doing anything yet, and what is
        # it behind?". Once the worker starts, the answer is stale — its predecessor settled, the
        # row is live work, and a permanent "after W1" both reads as still-waiting and eats the width
        # the status, progress, and PR markers need. Provisioning keeps a worker `queued` until its
        # harness session is live, so `queued` is exactly "has not started". The relationship stays
        # on the record, in GetInfo ("started after: …"), and in the spawn log line.
        def unstarted_follow_up?(worker)
          return false unless worker["follow_up_of_agent_id"]

          worker["status"].to_s == "queued"
        end

        def deferred_wait_marker(worker)
          metadata = worker["harness_metadata"]
          deferred = metadata.is_a?(Hash) ? metadata["deferred_spawn"] : nil
          return "" unless deferred.is_a?(Hash)
          return "" unless %w[waiting activating].include?(deferred["state"].to_s)

          predecessor_id = deferred["after_agent_id"].to_s
          verb = deferred["state"].to_s == "activating" ? "starting after" : "waiting on"
          # A worker whose command gate is live is waiting on that condition, not on its
          # predecessor: the predecessor has already settled by the time a gate is armed.
          gate = gate_wait_label(deferred)
          return "#{verb} #{gate}" if gate
          return verb.split.first if predecessor_id.empty?

          "#{verb} #{relationship_id(worker, predecessor_id)}"
        end

        def completion_wait_marker(worker)
          metadata = worker["harness_metadata"]
          continuation = metadata.is_a?(Hash) ? metadata["completion_continuation"] : nil
          return "" unless continuation.is_a?(Hash) && continuation["state"].to_s == "waiting"

          gate = gate_wait_label(continuation)
          gate ? "routing after #{gate}" : ""
        end

        # A script-gated queued worker must read honestly in the tree: it is not "waiting on W1",
        # it is waiting for a command to say go.
        def gate_wait_label(deferred)
          gate = deferred["command_gate"]
          return nil unless gate.is_a?(Hash)
          return nil unless gate["state"].to_s == "pending"
          return nil if gate["armed_at"].to_s.empty?

          label = gate["label"].to_s.strip
          label = gate["command"].to_s.strip if label.empty?
          return nil if label.empty?

          label = label.gsub(/\s+/, " ")
          label.length > GATE_LABEL_LIMIT ? "#{label[0, GATE_LABEL_LIMIT - 1].rstrip}…" : label
        end

        # Same-issue relationships stay short; a predecessor on another issue needs its full id to
        # be identifiable.
        def relationship_id(worker, id)
          issue_id = id.to_s.sub(/-W\d+\z/, "")
          issue_id == worker["issue_id"].to_s ? short_id(id) : id.to_s
        end

        def active_pr_marker(record, fallback_records = [])
          return "↗" if AgentTreeNavigation.active_agent_pr_url(record)

          Array(fallback_records).any? { |candidate| AgentTreeNavigation.active_agent_pr_url(candidate) } ? "↗" : ""
        end

        def head_suffix(head)
          [head_retry_marker(head), active_pr_marker(head)].reject(&:empty?).join(" ")
        end

        # A head that stopped without routing its request is recoverable, not dead state: selecting
        # it and typing (or `/prompt H<n> "..."`) re-runs the request. Say so on the row, because a
        # blocked or errored head otherwise reads as something the user can only kill. Once it has
        # been retried, the successor is the more useful fact.
        def head_retry_marker(head)
          retried_by = State::Models.head_metadata(head).fetch("retried_by_head_id", nil).to_s
          return "retried as #{retried_by}" unless retried_by.empty?
          return "" unless State::Models.head_retry_target?(head)

          "prompt to retry"
        end

        def short_id(id)
          id.to_s.split("-").last || id.to_s
        end

        def sort_key(id)
          id.to_s.scan(/\d+/).map(&:to_i)
        end

        def plain_text(line)
          return line.to_s unless line.is_a?(Array)

          line.map { |segment| segment.is_a?(Array) ? segment.first.to_s : segment.to_s }.join
        end
      end
    end
  end
end
