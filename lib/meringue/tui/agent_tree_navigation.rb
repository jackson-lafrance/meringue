# frozen_string_literal: true

module Meringue
  module TUI
    module AgentTreeNavigation
      module_function

      def selectable_agent_ids(state)
        agents = records(state, "agents")
        issues = records(state, "issues")
        projects = records(state, "projects")

        ids = agents.select { |agent| agent["type"] == "head" }
                    .sort_by { |agent| sort_key(agent["id"]) }
                    .map { |agent| agent.fetch("id") }

        ids.concat(project_worker_ids(projects, issues, agents))
        ids
      end

      def selectable_pr_agent_ids(state)
        agents = records(state, "agents")
        issues = records(state, "issues")
        projects = records(state, "projects")

        ids = agents.select { |agent| agent["type"] == "head" && agent_pr_url(agent) }
                    .sort_by { |agent| sort_key(agent["id"]) }
                    .map { |agent| agent.fetch("id") }

        ids.concat(project_pr_worker_ids(projects, issues, agents))
        ids
      end

      def agent_pr_url(agent)
        pr_urls_from_record(agent).compact.map(&:to_s).find { |url| pull_request_url?(url) }
      end

      def sort_key(id)
        parts = id.to_s.scan(/\d+/).map(&:to_i)
        parts.empty? ? [id.to_s] : parts
      end

      def selected_agent_id(state)
        navigation = state.fetch("_agent_tree_navigation", {}) || {}
        navigation.fetch("selected_agent_id", nil)
      end

      def active?(state)
        navigation = state.fetch("_agent_tree_navigation", {}) || {}
        !!navigation.fetch("active", false)
      end

      def selectable_agent?(record)
        %w[head worker].include?(record["type"])
      end

      def selected_agent?(record, selected_agent_id)
        selectable_agent?(record) && !selected_agent_id.to_s.empty? && record["id"].to_s == selected_agent_id.to_s
      end

      def records(state, key)
        state.fetch(key, []) || []
      end

      def project_worker_ids(projects, issues, agents)
        projects.sort_by { |project| sort_key(project["id"]) }.flat_map do |project|
          project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
          issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
          issue_worker_ids(issues_by_parent, agents, nil)
        end
      end

      def issue_worker_ids(issues_by_parent, agents, parent_id)
        issues_by_parent.fetch(parent_id, []).sort_by { |issue| sort_key(issue["id"]) }.flat_map do |issue|
          workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] }
                          .sort_by { |worker| sort_key(worker["id"]) }
                          .map { |worker| worker.fetch("id") }
          workers + issue_worker_ids(issues_by_parent, agents, issue["id"])
        end
      end

      def project_pr_worker_ids(projects, issues, agents)
        projects.sort_by { |project| sort_key(project["id"]) }.flat_map do |project|
          project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
          issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
          pr_worker_ids(issues_by_parent, agents, nil)
        end
      end

      def pr_worker_ids(issues_by_parent, agents, parent_id)
        issues_by_parent.fetch(parent_id, []).sort_by { |issue| sort_key(issue["id"]) }.flat_map do |issue|
          workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] && agent_pr_url(agent) }
                          .sort_by { |worker| sort_key(worker["id"]) }
                          .map { |worker| worker.fetch("id") }
          workers + pr_worker_ids(issues_by_parent, agents, issue["id"])
        end
      end

      def pr_urls_from_record(record)
        metadata = record.fetch("harness_metadata", {}) || {}
        issue_metadata = record.fetch("metadata", {}) || {}
        [
          record["pr_url"],
          record["pull_request_url"],
          record["pull_request"],
          *Array(record["pr_urls"]),
          *Array(record["pull_request_urls"]),
          *Array(record["pull_requests"]),
          metadata["pr_url"],
          metadata["pull_request_url"],
          metadata["pull_request"],
          *Array(metadata["pr_urls"]),
          *Array(metadata["reported_pr_urls"]),
          *Array(metadata["pull_request_urls"]),
          issue_metadata["pr_url"],
          issue_metadata["pull_request_url"],
          issue_metadata["pull_request"],
          *Array(issue_metadata["pr_urls"]),
          *Array(issue_metadata["reported_pr_urls"]),
          *Array(issue_metadata["pull_request_urls"])
        ]
      end

      def pull_request_url?(url)
        url.to_s.match?(%r{\Ahttps?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+(?:[/?#].*)?\z})
      end
    end
  end
end
