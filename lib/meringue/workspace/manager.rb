# frozen_string_literal: true

module Meringue
  module Workspace
    class Manager
      DEFAULT_ROOT = File.expand_path("~/.meringue/workspaces")

      attr_reader :root_path

      def initialize(root_path: DEFAULT_ROOT)
        @root_path = File.expand_path(root_path)
      end

      def plan_worker_workspace(project_root:, project_id:, issue_id:, agent_id:)
        safe_project_id = safe_identifier(project_id)
        safe_issue_id = safe_identifier(issue_id)
        safe_agent_id = safe_identifier(agent_id)
        branch = "meringue/#{safe_agent_id}"
        workspace_path = File.join(root_path, safe_project_id, safe_issue_id, safe_agent_id)

        {
          "strategy" => "git_worktree",
          "project_root" => File.expand_path(project_root),
          "workspace_path" => workspace_path,
          "workspace_branch" => branch,
          "created" => false
        }
      end

      private

      def safe_identifier(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]/, "-")
      end
    end
  end
end
