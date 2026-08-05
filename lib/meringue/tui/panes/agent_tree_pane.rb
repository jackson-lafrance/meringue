# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class AgentTreePane
        MAX_ITEM_LINES = 3
        ELLIPSIS = "…"
        AGENT_TYPES = %w[head worker].freeze

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
              suffix: active_pr_marker(head),
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
              suffix: active_pr_marker(head),
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

            output.concat(item_lines(
              prefix: "#{prefix}#{connector}",
              record: issue,
              id: short_id(issue["id"]),
              title: issue.fetch("title", "Untitled issue"),
              suffix: issue_suffix(issue, workers, goals),
              selected: AgentTreeNavigation.selected_agent?(issue, selected_agent_id),
              width: width
            ))

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

            output.concat(Array.new(item_line_count(
              prefix: "#{prefix}#{connector}",
              record: issue,
              id: short_id(issue["id"]),
              title: issue.fetch("title", "Untitled issue"),
              suffix: issue_suffix(issue, workers, goals),
              selected: AgentTreeNavigation.selected_agent?(issue, selected_agent_id),
              width: width
            ), issue.fetch("id")))

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

            append_issue_worker_ids(output, issues_by_parent, agents, selected_agent_id: selected_agent_id, parent_id: issue["id"], prefix: next_prefix, width: width)
          end
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
          suffix_text = suffix.to_s
          content = [title, suffix_text.empty? ? nil : suffix_text].compact.join("  ")
          suffix_style = suffix_text.empty? ? nil : (selected ? Style::PR_MARKER_SELECTED : Style::PR_MARKER)
          if selected
            selected_item_lines(prefix: prefix, record: record, id: id, content: content, suffix_text: suffix_text, suffix_style: suffix_style, width: width)
          else
            normal_item_lines(prefix: prefix, record: record, id: id, content: content, suffix_text: suffix_text, suffix_style: suffix_style, width: width)
          end
        end

        def normal_item_lines(prefix:, record:, id:, content:, suffix_text: "", suffix_style: nil, width: nil)
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
            suffix_text: suffix_text,
            suffix_style: suffix_style
          )
        end

        # The selected row keeps its own high-contrast palette rather than the
        # agent's identity color: it already owns the highlight and explicit
        # selection marker, and an identity foreground on the selection
        # background is not guaranteed to stay legible in every theme.
        def selected_item_lines(prefix:, record:, id:, content:, suffix_text: "", suffix_style: nil, width: nil)
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
            suffix_text: suffix_text,
            suffix_style: suffix_style
          )
        end

        def wrapped_lines(leader_segments, content, title_style:, continuation_style:, width:, selected: false,
                          continuation_segments: nil, suffix_text: "", suffix_style: nil)
          leader_text = plain_text(leader_segments)
          continuation_segments ||= [[" " * leader_text.length, selected ? Style::AGENT_TREE_SELECTED_DIM : Style::DIM]]
          content_width = wrapped_content_width(width, leader_text.length)
          chunks = wrap_content(content, content_width)

          lines = []
          chunks.each_with_index do |chunk, index|
            segments = if index.zero?
                         leader_segments + [[chunk, title_style]]
                       else
                         continuation_segments + [[chunk, continuation_style]]
                       end
            segments = style_suffix_marker(segments, suffix_text, suffix_style)
            lines << (selected ? pad_selected_line(segments, width) : segments)
          end
          lines
        end

        def wrapped_content_width(width, leader_length)
          return nil unless width

          [width.to_i - leader_length, 1].max
        end

        def style_suffix_marker(segments, suffix_text, suffix_style)
          return segments if suffix_text.to_s.empty? || suffix_style.nil?

          segments.each_with_index.reverse_each do |segment, index|
            next unless segment.is_a?(Array)

            text = segment.fetch(0, "").to_s
            next unless text.end_with?(suffix_text)

            base_text = text[0...-suffix_text.length]
            styled_suffix = []
            styled_suffix << [base_text, segment.fetch(1, nil)] unless base_text.empty?
            styled_suffix << [suffix_text, suffix_style]
            return segments[0...index] + styled_suffix + segments[(index + 1)..]
          end

          segments
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

        def wrap_content(content, width)
          text = normalized_content(content)
          return [text] unless width

          lines = split_wrapped_lines(text, width)
          return lines if lines.length <= MAX_ITEM_LINES

          visible = lines.first(MAX_ITEM_LINES)
          visible[-1] = ellipsize(visible.last, width)
          visible
        end

        def normalized_content(content)
          value = content.to_s.gsub(/[[:cntrl:]]+/, " ").gsub(/\s+/, " ").strip
          value.empty? ? " " : value
        end

        def split_wrapped_lines(text, width)
          remaining = text.dup
          lines = []

          until remaining.empty?
            if remaining.length <= width
              lines << remaining
              break
            end

            slice = remaining[0, width + 1]
            break_at = slice.rindex(" ") || width
            break_at = width if break_at <= 0
            lines << remaining[0, break_at].rstrip
            remaining = remaining[break_at..].to_s.lstrip
          end

          lines.empty? ? [" "] : lines
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

        def issue_suffix(issue, workers, goals = [])
          [goal_marker(issue, goals), progress(workers), active_pr_marker(issue)].reject(&:empty?).join(" ")
        end

        # A goal loop is rendered as a suffix on the issue it controls, not as a new node kind:
        # the AgentTree stays projects -> issues -> workers.
        def goal_marker(issue, goals)
          goal = Array(goals).find { |candidate| candidate.is_a?(Hash) && candidate["issue_id"] == issue["id"] }
          return "" unless goal

          budget = goal["budget"].is_a?(Hash) ? goal["budget"] : {}
          parts = ["◎#{goal["current_iteration"].to_i}/#{budget["max_iterations"].to_i}"]
          metric = goal["metric"].is_a?(Hash) ? goal["metric"] : {}
          latest = goal["last_metric"].is_a?(Hash) ? goal["last_metric"]["value"] : nil
          parts << "#{goal_number(latest)}/#{goal_number(metric["target"])}" if metric["target"]
          parts << goal["stop_reason"].to_s.tr("_", " ") if goal["stop_reason"]
          parts << "paused" if goal["paused"]
          parts.reject { |part| part.to_s.empty? }.join(" ")
        end

        def goal_number(value)
          return "?" if value.nil?

          number = Float(value)
          number == number.round ? number.round.to_s : format("%.1f", number)
        rescue ArgumentError, TypeError
          "?"
        end

        def progress(workers)
          visible_workers = workers.reject { |worker| worker["status"] == "killed" && worker["replaced_by_agent_id"] }
          return "" if visible_workers.empty?

          completed = visible_workers.count { |worker| worker["status"] == "completed" }
          "#{completed}/#{visible_workers.length}"
        end

        def worker_suffix(worker, issue = nil)
          # Delivery PRs are owned by issues so they survive worker replacement and restart.
          # Reflect the issue marker on its worker rows without copying metadata back to workers.
          [
            provisioning_marker(worker),
            unfinished_marker(worker),
            worker_relationship_marker(worker),
            active_pr_marker(issue || worker)
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

          percent = progress["detail"].to_s[/\d+%/]
          percent || (progress["elapsed_seconds"] ? "#{progress["elapsed_seconds"].to_f.round}s" : nil)
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

          metadata["settle_failure"]["kind"].to_s == "network_failure" ? "stopped: connection lost" : "stopped mid-turn"
        end

        def worker_relationship_marker(worker)
          # A worker that has not started yet must say so, and say who it is waiting for; otherwise a
          # queued dependent looks identical to a worker whose session is still being provisioned.
          waiting = deferred_wait_marker(worker)
          return waiting unless waiting.empty?
          return "replaces #{short_id(worker.fetch("replaces_agent_id"))}" if worker["replaces_agent_id"]
          return "after #{short_id(worker.fetch("follow_up_of_agent_id"))}" if worker["follow_up_of_agent_id"]
          return "replaced by #{short_id(worker.fetch("replaced_by_agent_id"))}" if worker["replaced_by_agent_id"]

          ""
        end

        def deferred_wait_marker(worker)
          metadata = worker["harness_metadata"]
          deferred = metadata.is_a?(Hash) ? metadata["deferred_spawn"] : nil
          return "" unless deferred.is_a?(Hash)
          return "" unless %w[waiting activating].include?(deferred["state"].to_s)

          predecessor_id = deferred["after_agent_id"].to_s
          verb = deferred["state"].to_s == "activating" ? "starting after" : "waiting on"
          return verb.split.first if predecessor_id.empty?

          "#{verb} #{relationship_id(worker, predecessor_id)}"
        end

        # Same-issue relationships stay short; a predecessor on another issue needs its full id to
        # be identifiable.
        def relationship_id(worker, id)
          issue_id = id.to_s.sub(/-W\d+\z/, "")
          issue_id == worker["issue_id"].to_s ? short_id(id) : id.to_s
        end

        def active_pr_marker(record)
          AgentTreeNavigation.active_agent_pr_url(record) ? "↗" : ""
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
