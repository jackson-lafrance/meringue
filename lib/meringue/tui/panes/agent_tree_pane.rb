# frozen_string_literal: true

module Meringue
  module TUI
    module Panes
      class AgentTreePane
        STATUS_MARKERS = {
          "queued" => "[ ]",
          "working" => "[>]",
          "idle" => "[-]",
          "blocked" => "[!]",
          "completed" => "[✓]",
          "errored" => "[x]",
          "killed" => "[/]"
        }.freeze

        def render(state)
          lines(state).join("\n")
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
          output.empty? ? ["No AgentTree data yet."] : output
        end

        private

        def records(state, key)
          state.fetch(key, []) || []
        end

        def append_heads(output, agents)
          heads = agents.select { |agent| agent["type"] == "head" }.sort_by { |agent| sort_key(agent["id"]) }
          return if heads.empty?

          output << "Heads"
          heads.each do |head|
            output << "  #{marker(head)} #{head.fetch("id")} #{record_title(head)}"
          end
          output << ""
        end

        def append_projects(output, projects, issues, agents)
          projects.sort_by { |project| sort_key(project["id"]) }.each do |project|
            output << "#{marker(project)} #{project.fetch("id")} #{project.fetch("name", "Untitled project")}"

            project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
            issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
            render_issues(output, issues_by_parent, agents, parent_id: nil, depth: 1)
            output << ""
          end
        end

        def render_issues(output, issues_by_parent, agents, parent_id:, depth:)
          issues_by_parent.fetch(parent_id, []).sort_by { |issue| sort_key(issue["id"]) }.each do |issue|
            workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] }
            output << "#{indent(depth)}#{marker(issue)} #{short_id(issue["id"])} #{issue.fetch("title", "Untitled issue")} #{progress(workers)}".rstrip

            workers.sort_by { |worker| sort_key(worker["id"]) }.each do |worker|
              output << "#{indent(depth + 1)}#{marker(worker)} #{short_id(worker["id"])} #{record_title(worker)}"
            end

            render_issues(output, issues_by_parent, agents, parent_id: issue["id"], depth: depth + 1)
          end
        end

        def append_questions(output, questions)
          open_questions = questions.select { |question| question["status"] == "open" }.sort_by { |question| sort_key(question["id"]) }
          return if open_questions.empty?

          output << "Questions"
          open_questions.each do |question|
            output << "  [?] #{question.fetch("id")} #{question.fetch("question", "Open question")}"
          end
        end

        def marker(record)
          STATUS_MARKERS.fetch(record["status"], "[?]")
        end

        def record_title(record)
          metadata = record.fetch("harness_metadata", {}) || {}
          metadata.fetch("title", "#{record.fetch("type", "item")} session")
        end

        def progress(workers)
          return "" if workers.empty?

          completed = workers.count { |worker| worker["status"] == "completed" }
          "(#{completed}/#{workers.length})"
        end

        def short_id(id)
          id.to_s.split("-").last || id.to_s
        end

        def indent(depth)
          "  " * depth
        end

        def sort_key(id)
          id.to_s.scan(/\d+/).map(&:to_i)
        end
      end
    end
  end
end
