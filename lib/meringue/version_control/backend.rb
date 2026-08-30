# frozen_string_literal: true

module Meringue
  module VersionControl
    # Contract implemented by every backend that can host mutable workers.
    # Backends own isolation evidence; the kernel never infers safety from a path.
    class Backend
      def id
        raise NotImplementedError
      end

      def inspect_project(root_path:)
        raise NotImplementedError
      end

      def provision_workspace(**)
        raise NotImplementedError
      end

      def validate_workspace(**)
        raise NotImplementedError
      end

      def release_workspace(**)
        raise NotImplementedError
      end
    end

    # Configuring `command` reserves an extension point but does not ship an
    # implementation. Until a user supplies a backend object, it fails closed.
    class UnavailableBackend < Backend
      def initialize(id = "alternate") = @backend_id = id
      def id = @backend_id
      def inspect_project(root_path:)
        { "available" => false, "backend" => id,
          "capabilities" => { "isolated_workspaces" => false },
          "diagnostics" => ["alternate_backend_requires_user_implementation"] }
      end
    end

    # First-party Git + GitHub backend. GitHub identity is required for the
    # built-in delivery workflow, while workspace ownership remains Git-based.
    class GitHubGitBackend < Backend
      attr_reader :manager

      def initialize(manager:)
        @manager = manager
      end

      def id = "github_git"

      def inspect_project(root_path:)
        result = manager.inspect_project(root_path)
        result.merge("backend" => id)
      rescue StandardError => e
        unavailable("backend_probe_failed", e.message)
      end

      def provision_workspace(project:, worker:, task_title:, unavailable_paths: [], progress: nil)
        manager.allocate_worker_workspace(
          project_root: project.fetch("root_path"), project_id: project.fetch("id"),
          issue_id: worker.fetch("issue_id", worker.fetch("id", "unknown")),
          agent_id: worker.fetch("id"), task_title: task_title,
          unavailable_paths: unavailable_paths, progress: progress
        )
      end

      def validate_workspace(workspace:, worker_id:)
        manager.validate_worker_workspace(workspace, agent_id: worker_id)
      end

      def release_workspace(workspace:, preserve_delivery: true)
        manager.release_worker_workspace(workspace, delete_branch: !preserve_delivery)
      end

      private

      def unavailable(reason, error)
        {
          "available" => false, "backend" => id,
          "capabilities" => { "isolated_workspaces" => false, "mutable_workspace" => false },
          "diagnostics" => [{ "reason" => reason, "detail" => error.to_s }]
        }
      end
    end
  end
end
