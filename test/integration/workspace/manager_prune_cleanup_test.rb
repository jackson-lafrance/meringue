# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Prune cleanup is intentionally more conservative than failed-allocation release:
# it never forces a dirty/locked worktree and requires persisted path/branch ownership.
class WorkspaceManagerPruneCleanupTest < Minitest::Test
  include WorkspaceSupport

  def test_removes_a_clean_registered_worktree_but_preserves_its_branch
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Clean prune")
      branch = workspace.fetch("workspace_branch")

      outcome = manager.cleanup_pruned_worker_workspace(workspace)

      assert_equal "removed", outcome.fetch("status")
      assert outcome.fetch("success")
      assert outcome.fetch("attempted")
      refute Dir.exist?(workspace.fetch("worktree_root_path"))
      assert branch_exists?(project, branch), "pruning a worktree must keep delivered commits reachable"
    end
  end

  def test_removes_the_worktree_root_when_the_managed_project_is_a_subdirectory
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(
        manager,
        project,
        task_title: "Nested project cleanup",
        project_root: File.join(project.fetch("project_root"), "app")
      )

      outcome = manager.cleanup_pruned_worker_workspace(workspace)

      assert_equal "removed", outcome.fetch("status")
      refute Dir.exist?(workspace.fetch("worktree_root_path"))
      assert Dir.exist?(project.fetch("project_root")), "the main checkout must survive nested-project cleanup"
    end
  end

  def test_dirty_worktree_is_retained_without_forcing_uncommitted_changes
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Dirty prune")
      uncommitted = File.join(workspace.fetch("workspace_path"), "unfinished.txt")
      File.write(uncommitted, "keep me\n")

      outcome = manager.cleanup_pruned_worker_workspace(workspace)

      assert_equal "failed", outcome.fetch("status")
      assert_equal "worktree_dirty", outcome.fetch("reason")
      refute outcome.fetch("success")
      refute outcome.fetch("attempted")
      assert_equal "keep me\n", File.read(uncommitted)
      assert Dir.exist?(workspace.fetch("worktree_root_path"))
    end
  end

  def test_locked_worktree_is_retained_until_it_is_unlocked
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Locked prune")
      git_output(project, project.fetch("project_root"), "worktree", "lock", "--reason", "manual review", workspace.fetch("worktree_root_path"))

      outcome = manager.cleanup_pruned_worker_workspace(workspace)

      assert_equal "failed", outcome.fetch("status")
      assert_equal "worktree_locked", outcome.fetch("reason")
      refute outcome.fetch("success")
      assert Dir.exist?(workspace.fetch("worktree_root_path"))
    ensure
      if workspace && Dir.exist?(workspace.fetch("worktree_root_path", ""))
        git_output(project, project.fetch("project_root"), "worktree", "unlock", workspace.fetch("worktree_root_path"))
      end
    end
  end

  def test_missing_registered_worktree_is_deregistered_without_global_prune
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Missing prune")
      FileUtils.rm_rf(workspace.fetch("worktree_root_path"))

      outcome = manager.cleanup_pruned_worker_workspace(workspace)

      assert_equal "removed", outcome.fetch("status")
      assert outcome.fetch("success")
      listing = git_output(project, project.fetch("project_root"), "worktree", "list", "--porcelain")
      refute_includes listing, workspace.fetch("worktree_root_path")
    end
  end

  def test_already_removed_worktree_is_an_idempotent_success
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Already gone")
      assert manager.release_worker_workspace(workspace)

      outcome = manager.cleanup_pruned_worker_workspace(workspace)

      assert_equal "already_removed", outcome.fetch("status")
      assert_equal "worktree_already_removed", outcome.fetch("reason")
      assert outcome.fetch("success")
      refute outcome.fetch("attempted")
    end
  end

  def test_refuses_the_main_checkout_and_another_workers_protected_path
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      broad_manager = Meringue::Workspace::Manager.new(root_path: tmp)
      main_record = {
        "strategy" => "git_worktree",
        "git_root" => project.fetch("project_root"),
        "worktree_root_path" => project.fetch("project_root"),
        "workspace_branch" => "not-the-main-checkout-a1b2c3d4"
      }

      main_outcome = broad_manager.cleanup_pruned_worker_workspace(main_record)
      assert_equal "failed", main_outcome.fetch("status")
      assert_equal "main_checkout_protected", main_outcome.fetch("reason")
      assert Dir.exist?(project.fetch("project_root"))

      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Owned by somebody else")
      protected_outcome = manager.cleanup_pruned_worker_workspace(
        workspace,
        protected_paths: [workspace.fetch("worktree_root_path")]
      )

      assert_equal "failed", protected_outcome.fetch("status")
      assert_equal "workspace_owned_by_another_worker", protected_outcome.fetch("reason")
      assert Dir.exist?(workspace.fetch("worktree_root_path"))
    end
  end

  def test_refuses_a_registered_worktree_when_the_persisted_branch_does_not_match
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Branch mismatch")

      outcome = manager.cleanup_pruned_worker_workspace(
        workspace.merge("workspace_branch" => "someone-elses-branch-a1b2c3d4")
      )

      assert_equal "failed", outcome.fetch("status")
      assert_equal "worktree_branch_mismatch", outcome.fetch("reason")
      assert Dir.exist?(workspace.fetch("worktree_root_path"))
    end
  end
end
