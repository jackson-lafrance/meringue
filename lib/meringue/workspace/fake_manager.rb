# frozen_string_literal: true

require "digest"
require "fileutils"

module Meringue
  module Workspace
    # Deterministic stand-in for the real workspace manager, in the same spirit as
    # `Harness::FakeClient` and `VersionControl::FakeBackend`.
    #
    # A worker's workspace has to be isolated from the project root — that is the whole
    # contract the kernel enforces — but proving isolation with Git costs a repository and
    # several subprocesses per test. This provisions a real, separate directory per worker
    # under its own root and reports it the way a provisioned worktree is reported, so a
    # test about issues, workers, or head routing exercises the real allocation path
    # without arranging a repository for it.
    #
    # It is not a substitute for the real manager in tests that are about worktrees:
    # `test/integration/workspace/` and the e2e suite use `Workspace::Manager` against real
    # repositories.
    class FakeManager
      attr_reader :root_path, :released, :cleaned

      def initialize(root_path:)
        @root_path = File.expand_path(root_path.to_s)
        @released = []
        @cleaned = []
      end

      def plan_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil, **)
        slug = DeliveryArtifactPolicy.slug(task_title)
        suffix = Digest::SHA256.hexdigest([File.expand_path(project_root), project_id, issue_id, agent_id, slug].join("\0"))[0, 8]
        branch = [slug, suffix].join("-")
        {
          "strategy" => "git_worktree",
          "project_root" => File.expand_path(project_root),
          "workspace_path" => File.join(root_path, project_id.to_s, branch),
          "workspace_branch" => branch,
          "workspace_owner_id" => agent_id.to_s,
          "requested_worktree_provider" => "native_git",
          "worktree_provider" => "native_git",
          "created" => false
        }
      end

      def allocate_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil,
                                    unavailable_paths: [], progress: nil, **)
        plan = plan_worker_workspace(
          project_root: project_root, project_id: project_id, issue_id: issue_id,
          agent_id: agent_id, task_title: task_title
        )
        path = plan.fetch("workspace_path")
        # An allocation that collides with a path the caller says is taken moves aside, the
        # way the real manager reallocates rather than handing two workers one directory.
        path = "#{path}-2" if Array(unavailable_paths).any? { |taken| File.expand_path(taken.to_s) == File.expand_path(path) }
        FileUtils.mkdir_p(path)
        # One terminal report, in the shape the reporter reads. There is no checkout to
        # narrate, so there is nothing to report part-way through.
        progress&.call({ "phase" => "checkout", "elapsed" => 0.0, "percent" => 100 })
        plan.merge(
          "workspace_path" => path,
          "workspace_root_path" => path,
          "worktree_root_path" => path,
          "git_root" => File.expand_path(project_root),
          "base_ref" => "main",
          "created" => true,
          "errors" => []
        )
      end

      def validate_worker_workspace(workspace, agent_id: nil)
        _ = agent_id
        return outcome(false, "invalid_workspace_record") unless workspace.is_a?(Hash)

        path = workspace["workspace_path"].to_s
        return outcome(false, "workspace_missing") if path.empty? || !Dir.exist?(path)

        outcome(true, "fake_workspace")
      end

      def release_worker_workspace(workspace, delete_branch: false)
        @released << { "workspace" => workspace, "delete_branch" => delete_branch }
        path = workspace.is_a?(Hash) ? workspace["workspace_path"].to_s : ""
        return false if path.empty? || !Dir.exist?(path)

        FileUtils.remove_entry(path)
        true
      end

      def cleanup_pruned_worker_workspace(workspace, protected_paths: [])
        @cleaned << { "workspace" => workspace, "protected_paths" => Array(protected_paths) }
        path = workspace.is_a?(Hash) ? workspace["workspace_path"].to_s : ""
        return { "status" => "skipped", "reason" => "workspace_missing", "success" => true, "attempted" => false } if
          path.empty? || !Dir.exist?(path)
        if Array(protected_paths).any? { |protected_path| File.expand_path(protected_path.to_s) == File.expand_path(path) }
          return { "status" => "skipped", "reason" => "workspace_protected", "success" => true, "attempted" => false }
        end

        FileUtils.remove_entry(path)
        { "status" => "removed", "reason" => nil, "success" => true, "attempted" => true }
      end

      # Nothing here is a real worktree, so there is never anything dangling to prune.
      def prune_dangling_worktrees(*, **)
        { "pruned" => [], "errors" => [] }
      end

      def inspect_project(root_path)
        {
          "available" => true, "backend" => "github_git",
          "repository_identity" => "git@github.com:example/#{File.basename(File.expand_path(root_path.to_s))}.git",
          "capabilities" => { "isolated_workspaces" => true, "mutable_workspace" => true,
                              "shared_read_only_workspace" => true, "delivery" => true },
          "diagnostics" => [], "diagnostic_at" => Time.now.utc.iso8601
        }
      end

      private

      def outcome(usable, reason)
        { "usable" => usable, "reason" => reason }
      end
    end
  end
end
