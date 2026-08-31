# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# The git half of workspace sharing. The kernel decides *who* may continue in another worker's
# workspace; the manager answers only whether git still agrees that the directory is a healthy
# worktree of this repository sitting on the recorded Meringue branch.
#
# Notably absent: a cleanliness check. Uncommitted work is exactly what a successor is meant to
# inherit, and `git status --untracked-files=all` is the slowest command in the provisioning path,
# so a dirty worktree is reusable and is never inspected for it.
class WorkspaceManagerSharedWorktreeTest < Minitest::Test
  include WorkspaceSupport

  def inspect_workspace(manager, workspace, branch: nil, git_root: nil)
    manager.inspect_shared_worktree(
      worktree_root: workspace.fetch("worktree_root_path"),
      branch: branch || workspace.fetch("workspace_branch"),
      git_root: git_root || workspace.fetch("git_root")
    )
  end

  def test_a_clean_registered_worktree_on_its_branch_is_reusable
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Reusable")

      outcome = inspect_workspace(manager, workspace)

      assert outcome.fetch("usable")
      assert_equal "worktree_reusable", outcome.fetch("reason")
      assert_equal real_path(workspace.fetch("worktree_root_path")), outcome.fetch("worktree_root_path")
      assert_equal workspace.fetch("workspace_branch"), outcome.fetch("workspace_branch")
    end
  end

  def test_a_dirty_worktree_is_still_reusable_because_that_work_is_the_point
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Dirty but reusable")
      File.write(File.join(workspace.fetch("workspace_path"), "unfinished.txt"), "half done\n")

      outcome = inspect_workspace(manager, workspace)

      assert outcome.fetch("usable")
      assert_equal "worktree_reusable", outcome.fetch("reason")
    end
  end

  def test_a_worktree_that_moved_to_another_branch_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Moved on")
      git_output(project, workspace.fetch("worktree_root_path"), "switch", "--create", "elsewhere")

      outcome = inspect_workspace(manager, workspace)

      refute outcome.fetch("usable")
      assert_equal "worktree_branch_moved", outcome.fetch("reason")
      assert_equal "elsewhere", outcome.fetch("checked_out_branch")
    end
  end

  def test_a_detached_worktree_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Detached")
      git_output(project, workspace.fetch("worktree_root_path"), "checkout", "--detach", "HEAD")

      outcome = inspect_workspace(manager, workspace)

      refute outcome.fetch("usable")
      assert_equal "worktree_branch_moved", outcome.fetch("reason")
      assert outcome.fetch("detached")
    end
  end

  def test_a_locked_worktree_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Locked")
      git_output(project, project.fetch("project_root"), "worktree", "lock", workspace.fetch("worktree_root_path"))

      outcome = inspect_workspace(manager, workspace)

      refute outcome.fetch("usable")
      assert_equal "worktree_locked", outcome.fetch("reason")
    end
  end

  def test_a_directory_git_does_not_register_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Unregistered")
      git_output(project, project.fetch("project_root"), "worktree", "remove", "--force", workspace.fetch("worktree_root_path"))
      FileUtils.mkdir_p(workspace.fetch("worktree_root_path"))

      outcome = inspect_workspace(manager, workspace)

      refute outcome.fetch("usable")
      assert_equal "worktree_not_registered", outcome.fetch("reason")
    end
  end

  def test_a_missing_worktree_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Gone")
      FileUtils.remove_entry(workspace.fetch("worktree_root_path"))

      outcome = inspect_workspace(manager, workspace)

      refute outcome.fetch("usable")
      assert_equal "worktree_missing", outcome.fetch("reason")
    end
  end

  def test_a_path_outside_the_managed_workspace_root_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)

      outcome = manager.inspect_shared_worktree(
        worktree_root: project.fetch("project_root"),
        branch: "whatever",
        git_root: project.fetch("project_root")
      )

      refute outcome.fetch("usable")
      assert_equal "outside_managed_workspace_root", outcome.fetch("reason")
    end
  end

  def test_a_branch_meringue_does_not_manage_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Foreign branch")

      outcome = inspect_workspace(manager, workspace, branch: "feature/somebody-elses")

      refute outcome.fetch("usable")
      assert_equal "branch_not_delivery_managed", outcome.fetch("reason")
    end
  end

  def test_a_missing_repository_is_refused
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "No repo")

      outcome = inspect_workspace(manager, workspace, git_root: File.join(tmp, "not-a-repo"))

      refute outcome.fetch("usable")
      assert_equal "git_root_missing", outcome.fetch("reason")
    end
  end

  # A shared worktree still has exactly one owner as far as prune is concerned: whoever asks last.
  # The manager's cleanup contract does not change, so the second removal is idempotent rather than
  # an error, which is what lets the kernel prune several sharers in one pass.
  def test_removing_a_shared_worktree_twice_is_idempotent
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Shared cleanup")

      first = manager.cleanup_pruned_worker_workspace(workspace)
      second = manager.cleanup_pruned_worker_workspace(workspace)

      assert_equal "removed", first.fetch("status")
      assert_equal "already_removed", second.fetch("status")
      assert second.fetch("success"), "a sharer whose worktree is already gone must not block pruning"
      assert branch_exists?(project, workspace.fetch("workspace_branch"))
    end
  end
end
