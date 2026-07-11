# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class AgentTreePane
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

        def render(state)
          lines(state).map { |line| plain_text(line) }.join("\n")
        end

        def lines(state)
          projects = records(state, "projects")
          issues = records(state, "issues")
          agents = records(state, "agents")
          questions = records(state, "questions")

          output = []
          append_heads(output, agents)
          append_projects(output, projects, issues, agents)
          append_questions(output, questions)
          output.empty? ? [["No AgentTree data yet.", Style::MUTED]] : output
        end

        private

        def records(state, key)
          state.fetch(key, []) || []
        end

        def append_heads(output, agents)
          heads = agents.select { |agent| agent["type"] == "head" }.sort_by { |agent| sort_key(agent["id"]) }
          return if heads.empty?

          output << section_line("heads")
          heads.each_with_index do |head, index|
            output << item_line(
              prefix: index == heads.length - 1 ? "└─" : "├─",
              record: head,
              id: head.fetch("id"),
              title: record_title(head)
            )
          end
          output << spacer_line
        end

        def append_projects(output, projects, issues, agents)
          sorted_projects = projects.sort_by { |project| sort_key(project["id"]) }
          sorted_projects.each_with_index do |project, index|
            output << project_line(project)

            project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
            issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
            render_issues(output, issues_by_parent, agents, parent_id: nil, prefix: "")
            output << spacer_line unless index == sorted_projects.length - 1
          end
        end

        def render_issues(output, issues_by_parent, agents, parent_id:, prefix:)
          child_issues = issues_by_parent.fetch(parent_id, []).sort_by { |issue| sort_key(issue["id"]) }

          child_issues.each_with_index do |issue, issue_index|
            issue_last = issue_index == child_issues.length - 1
            connector = issue_last ? "└─" : "├─"
            next_prefix = "#{prefix}#{issue_last ? "  " : "│ "}"
            workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] }

            output << item_line(
              prefix: "#{prefix}#{connector}",
              record: issue,
              id: short_id(issue["id"]),
              title: issue.fetch("title", "Untitled issue"),
              suffix: progress(workers)
            )

            workers.sort_by { |worker| sort_key(worker["id"]) }.each_with_index do |worker, worker_index|
              worker_last = worker_index == workers.length - 1 && issues_by_parent.fetch(issue["id"], []).empty?
              output << item_line(
                prefix: "#{next_prefix}#{worker_last ? "└─" : "├─"}",
                record: worker,
                id: short_id(worker["id"]),
                title: record_title(worker)
              )
            end

            render_issues(output, issues_by_parent, agents, parent_id: issue["id"], prefix: next_prefix)
          end
        end

        def append_questions(output, questions)
          open_questions = questions.select { |question| question["status"] == "open" }.sort_by { |question| sort_key(question["id"]) }
          return if open_questions.empty?

          output << spacer_line
          output << section_line("questions")
          open_questions.each_with_index do |question, index|
            output << [
              [index == open_questions.length - 1 ? "└─ " : "├─ ", Style::DIM],
              ["?", Style::WARNING],
              [" #{question.fetch("id")}", Style::MUTED],
              ["  #{question.fetch("question", "Open question")}", Style::TEXT]
            ]
          end
        end

        def section_line(title)
          [[title.upcase, Style::DIM]]
        end

        def spacer_line
          [["", Style::DIM]]
        end

        def project_line(project)
          [
            [status_dot(project), status_style(project)],
            [" #{project.fetch("id")}", Style::MUTED],
            ["  #{project.fetch("name", "Untitled project")}", Style::TITLE],
            ["  #{project.fetch("status", "idle")}", Style::DIM]
          ]
        end

        def item_line(prefix:, record:, id:, title:, suffix: "")
          [
            ["#{prefix} ", Style::DIM],
            [status_dot(record), status_style(record)],
            [" #{id}", Style::MUTED],
            ["  #{title}", title_style(record)],
            [suffix.to_s.empty? ? "" : "  #{suffix}", Style::DIM]
          ]
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

        def progress(workers)
          return "" if workers.empty?

          completed = workers.count { |worker| worker["status"] == "completed" }
          "#{completed}/#{workers.length}"
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
