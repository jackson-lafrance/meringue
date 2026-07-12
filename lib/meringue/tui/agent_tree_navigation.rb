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

        ids = agents.select { |agent| agent["type"] == "head" && active_agent_pr_url(agent) }
                    .sort_by { |agent| sort_key(agent["id"]) }
                    .map { |agent| agent.fetch("id") }

        ids.concat(project_pr_worker_ids(projects, issues, agents))
        ids
      end

      def agent_pr_url(agent)
        pr_urls_from_record(agent).compact.map(&:to_s).find { |url| pull_request_url?(url) }
      end

      def active_agent_pr_url(agent)
        active_pr_urls_from_record(agent).compact.map(&:to_s).find { |url| pull_request_url?(url) }
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
          workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] && active_agent_pr_url(agent) }
                          .sort_by { |worker| sort_key(worker["id"]) }
                          .map { |worker| worker.fetch("id") }
          workers + pr_worker_ids(issues_by_parent, agents, issue["id"])
        end
      end

      def pr_urls_from_record(record)
        pull_request_records_from_record(record).map { |pull_request| pull_request.is_a?(Hash) ? pull_request["url"] : pull_request.to_s }
      end

      def active_pr_urls_from_record(record)
        pull_request_records_from_record(record).filter_map do |pull_request|
          next unless active_pull_request?(pull_request)

          pull_request["url"]
        end
      end

      def pull_request_records_from_record(record)
        metadata = record.fetch("harness_metadata", {}) || {}
        [
          record["delivery_pull_request"],
          metadata["delivery_pull_request"],
          *Array(record["delivery_pull_requests"]),
          *Array(metadata["delivery_pull_requests"])
        ].compact
      end

      def active_pull_request?(pull_request)
        return false unless pull_request.is_a?(Hash)

        state = pull_request["state"] || pull_request["status"] || pull_request["raw_state"]
        state.to_s.downcase == "open"
      end

      def pull_request_url?(url)
        url.to_s.match?(%r{\Ahttps?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+(?:[/?#].*)?\z})
      end
    end
  end
end
