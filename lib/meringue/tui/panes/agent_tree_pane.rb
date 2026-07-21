# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class AgentTreePane
        MAX_ITEM_LINES = 3
        ELLIPSIS = "…"

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
          selected_agent_id = AgentTreeNavigation.selected_agent_id(state)

          output = []
          append_heads(output, agents, selected_agent_id, width)
          append_projects(output, projects, issues, agents, selected_agent_id, width)
          output.empty? ? [[['No AgentTree data yet.', Style::MUTED]]] : output
        end

        def line_worker_ids(state, width: nil)
          projects = records(state, "projects")
          issues = records(state, "issues")
          agents = records(state, "agents")
          selected_agent_id = AgentTreeNavigation.selected_agent_id(state)

          output = []
          append_head_worker_ids(output, agents, selected_agent_id, width)
          append_project_worker_ids(output, projects, issues, agents, selected_agent_id, width)
          output.empty? ? [nil] : output
        end

        private

        def records(state, key)
          state.fetch(key, []) || []
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
            )))
          end
          output << nil
        end

        def append_projects(output, projects, issues, agents, selected_agent_id, width)
          sorted_projects = projects.sort_by { |project| sort_key(project["id"]) }
          sorted_projects.each_with_index do |project, index|
            output.concat(project_lines(project, width: width))

            project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
            issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
            render_issues(output, issues_by_parent, agents, selected_agent_id: selected_agent_id, parent_id: nil, prefix: "", width: width)
            output << spacer_line unless index == sorted_projects.length - 1
          end
        end

        def render_issues(output, issues_by_parent, agents, selected_agent_id:, parent_id:, prefix:, width:)
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
              suffix: issue_suffix(issue, workers),
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
                suffix: active_pr_marker(worker),
                selected: AgentTreeNavigation.selected_agent?(worker, selected_agent_id),
                width: width
              ))
            end

            render_issues(output, issues_by_parent, agents, selected_agent_id: selected_agent_id, parent_id: issue["id"], prefix: next_prefix, width: width)
          end
        end

        def append_project_worker_ids(output, projects, issues, agents, selected_agent_id, width)
          sorted_projects = projects.sort_by { |project| sort_key(project["id"]) }
          sorted_projects.each_with_index do |project, index|
            output.concat(Array.new(project_lines(project, width: width).length))

            project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
            issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
            append_issue_worker_ids(output, issues_by_parent, agents, selected_agent_id: selected_agent_id, parent_id: nil, prefix: "", width: width)
            output << nil unless index == sorted_projects.length - 1
          end
        end

        def append_issue_worker_ids(output, issues_by_parent, agents, selected_agent_id:, parent_id:, prefix:, width:)
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
              suffix: issue_suffix(issue, workers),
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
                suffix: active_pr_marker(worker),
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

        def project_lines(project, width: nil)
          leader_segments = [
            [status_dot(project), status_style(project)],
            [" #{project.fetch("id")}", Style::MUTED],
            ["  ", Style::DIM]
          ]
          content = [project.fetch("name", "Untitled project"), project.fetch("status", "idle")].join("  ")
          wrapped_lines(leader_segments, content, title_style: Style::TITLE, continuation_style: Style::TITLE, width: width)
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
          leader_segments = [
            ["#{prefix} ", Style::DIM],
            [status_dot(record), status_style(record)],
            [" #{id}", Style::MUTED],
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

        def record_title(record)
          metadata = record.fetch("harness_metadata", {}) || {}
          metadata.fetch("title", "#{record.fetch("type", "item")} session")
        end

        def issue_suffix(issue, workers)
          [progress(workers), active_pr_marker(issue)].reject(&:empty?).join(" ")
        end

        def progress(workers)
          return "" if workers.empty?

          completed = workers.count { |worker| worker["status"] == "completed" }
          "#{completed}/#{workers.length}"
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
