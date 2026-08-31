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

        ids.concat(project_tree_ids(projects, issues, agents))
        ids
      end

      def selectable_pr_agent_ids(state)
        agents = records(state, "agents")
        issues = records(state, "issues")
        projects = records(state, "projects")

        ids = agents.select { |agent| agent["type"] == "head" && active_agent_pr_url(agent) }
                    .sort_by { |agent| sort_key(agent["id"]) }
                    .map { |agent| agent.fetch("id") }

        ids.concat(project_pr_tree_ids(projects, issues, agents))
        ids
      end

      def agent_pr_url(record)
        pr_urls_from_record(record).compact.map(&:to_s).find { |url| pull_request_url?(url) }
      end

      def active_agent_pr_url(record)
        active_pr_urls_from_record(record).compact.map(&:to_s).find { |url| pull_request_url?(url) }
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
        %w[head worker].include?(record["type"]) || issue_record?(record)
      end

      # Projects are clickable AgentTree rows too. They are not jump-mode
      # targets, but they can carry the sticky selection that scopes the logs.
      def selectable_node?(record)
        selectable_agent?(record) || project_record?(record)
      end

      # Accepts one id or a list of ids so a row can be highlighted by the jump
      # cursor, by the sticky logs selection, or by both at once.
      def selected_agent?(record, selected_agent_id)
        return false unless selectable_node?(record)

        highlighted_ids(selected_agent_id).include?(record["id"].to_s)
      end

      def highlighted_ids(selected)
        Array(selected).map(&:to_s).reject(&:empty?)
      end

      # Ids the AgentTree should render as selected: the jump-mode cursor plus the
      # sticky selection that scopes the logs pane. The sticky id is rendered even
      # when the AgentTree is not the focused pane, so the user can always see
      # what the logs are filtered by.
      def highlighted_ids_for(state)
        (highlighted_ids(selected_agent_id(state)) + highlighted_ids(LogScope.id(state))).uniq
      end

      def records(state, key)
        entries = state.fetch(key, []) || []
        return entries unless %w[projects issues].include?(key)

        # Keep selectable ids aligned with the rendered AgentTree, which hides killed subtrees.
        entries.reject { |entry| entry.is_a?(Hash) && entry["status"] == "killed" }
      end

      def project_tree_ids(projects, issues, agents)
        projects.sort_by { |project| sort_key(project["id"]) }.flat_map do |project|
          project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
          issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
          issue_tree_ids(issues_by_parent, agents, nil)
        end
      end

      def issue_tree_ids(issues_by_parent, agents, parent_id)
        issues_by_parent.fetch(parent_id, []).sort_by { |issue| sort_key(issue["id"]) }.flat_map do |issue|
          workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] }
                          .sort_by { |worker| sort_key(worker["id"]) }
                          .map { |worker| worker.fetch("id") }
          [issue.fetch("id")] + workers + issue_tree_ids(issues_by_parent, agents, issue["id"])
        end
      end

      def project_pr_tree_ids(projects, issues, agents)
        projects.sort_by { |project| sort_key(project["id"]) }.flat_map do |project|
          project_issues = issues.select { |issue| issue["project_id"] == project["id"] }
          issues_by_parent = project_issues.group_by { |issue| issue["parent_issue_id"] }
          pr_tree_ids(issues_by_parent, agents, nil)
        end
      end

      def pr_tree_ids(issues_by_parent, agents, parent_id)
        issues_by_parent.fetch(parent_id, []).sort_by { |issue| sort_key(issue["id"]) }.flat_map do |issue|
          workers = agents.select { |agent| agent["type"] == "worker" && agent["issue_id"] == issue["id"] }
          # A delivery PR is an issue affordance. The worker check is only a compatibility
          # fallback for pre-migration state; it must never add worker rows to PR navigation.
          has_active_pr = active_agent_pr_url(issue) || workers.any? { |worker| active_agent_pr_url(worker) }
          ids = []
          ids << issue.fetch("id") if has_active_pr
          ids + pr_tree_ids(issues_by_parent, agents, issue["id"])
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
        [
          *Array(record["delivery_pull_requests"]),
          *Array(record["reported_pr_urls"])
        ]
      end

      def issue_record?(record)
        record.is_a?(Hash) && record.key?("project_id") && record.key?("agent_ids")
      end

      def project_record?(record)
        record.is_a?(Hash) && record.key?("root_path")
      end

      def active_pull_request?(pull_request)
        return false unless pull_request.is_a?(Hash)

        state = pull_request["state"] || pull_request["status"] || pull_request["raw_state"]
        state.to_s.downcase == "open"
      end

      def pull_request_url?(url)
        Forge.pull_request_url?(url)
      end
    end
  end
end
