# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Branch/path collisions, reuse of an interrupted allocation, and release. The
# invariant under test is that no user work is ever deleted to make room.
class WorkspaceManagerCollisionTest < Minitest::Test
  include WorkspaceSupport

  def test_reallocation_adopts_the_existing_worktree_and_keeps_uncommitted_work
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      first = allocate_workspace(manager, project, task_title: "Adopt me")
      in_progress = File.join(first.fetch("workspace_path"), "in-progress.txt")
      File.write(in_progress, "half-finished work\n")

      second = allocate_workspace(manager, project, task_title: "Adopt me")

      assert second.fetch("created")
      assert second.fetch("adopted")
      assert_equal first.fetch("workspace_path"), second.fetch("workspace_path")
      assert_equal first.fetch("workspace_branch"), second.fetch("workspace_branch")
      assert_equal "half-finished work\n", File.read(in_progress)
    end
  end

  def test_non_empty_colliding_directory_is_left_alone_and_allocation_uniquifies
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      plan = manager.plan_worker_workspace(
        project_root: project.fetch("project_root"),
        project_id: "P1",
        issue_id: "P1-I1",
        agent_id: "P1-I1-W1",
        task_title: "Occupied path"
      )
      FileUtils.mkdir_p(plan.fetch("workspace_path"))
      squatter = File.join(plan.fetch("workspace_path"), "user-notes.txt")
      File.write(squatter, "do not delete me\n")

      workspace = allocate_workspace(manager, project, task_title: "Occupied path")

      assert workspace.fetch("created")
      assert_equal "#{plan.fetch("workspace_path")}-2", workspace.fetch("workspace_path")
      assert_equal "#{plan.fetch("workspace_branch")}-2", workspace.fetch("workspace_branch")
      assert_equal "do not delete me\n", File.read(squatter)
    end
  end

  def test_empty_leftover_directory_is_reclaimed_for_the_preferred_name
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      plan = manager.plan_worker_workspace(
        project_root: project.fetch("project_root"),
        project_id: "P1",
        issue_id: "P1-I1",
        agent_id: "P1-I1-W1",
        task_title: "Empty leftover"
      )
      FileUtils.mkdir_p(plan.fetch("workspace_path"))

      workspace = allocate_workspace(manager, project, task_title: "Empty leftover")

      assert workspace.fetch("created")
      assert_equal plan.fetch("workspace_path"), workspace.fetch("workspace_path")
      assert_equal plan.fetch("workspace_branch"), workspace.fetch("workspace_branch")
    end
  end

  def test_branch_checked_out_elsewhere_forces_a_suffixed_branch
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      plan = manager.plan_worker_workspace(
        project_root: project.fetch("project_root"),
        project_id: "P1",
        issue_id: "P1-I1",
        agent_id: "P1-I1-W1",
        task_title: "Busy branch"
      )
      other_worktree = File.join(tmp, "someone-elses-worktree")
      git_output(project, project.fetch("project_root"), "worktree", "add", "-b", plan.fetch("workspace_branch"), other_worktree, "origin/main")

      workspace = allocate_workspace(manager, project, task_title: "Busy branch")

      assert workspace.fetch("created")
      assert_equal "#{plan.fetch("workspace_branch")}-2", workspace.fetch("workspace_branch")
      assert_equal "#{plan.fetch("workspace_path")}-2", workspace.fetch("workspace_path")
      assert Dir.exist?(other_worktree), "an unrelated worktree must never be removed"
    end
  end

  # Documents current behavior: after the worktree is released, the leftover
  # meringue/ branch is treated as an orphan, deleted, and recreated from
  # origin/main. Commits that only existed on it stop being reachable. See
  # test/findings/workspace.md.
  def test_reallocating_after_release_recreates_the_branch_from_origin_main
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      first = allocate_workspace(manager, project, task_title: "Interrupted run")
      File.write(File.join(first.fetch("workspace_path"), "committed.txt"), "worker commit\n")
      git_output(project, first.fetch("workspace_path"), "add", ".")
      git_output(project, first.fetch("workspace_path"), "commit", "-m", "worker commit")
      worker_sha = git_output(project, first.fetch("workspace_path"), "rev-parse", "HEAD").strip
      assert manager.release_worker_workspace(first)
      assert branch_exists?(project, first.fetch("workspace_branch"))

      second = allocate_workspace(manager, project, task_title: "Interrupted run")

      assert second.fetch("created")
      assert_equal first.fetch("workspace_branch"), second.fetch("workspace_branch")
      assert_equal first.fetch("workspace_path"), second.fetch("workspace_path")
      refute_path_exists File.join(second.fetch("workspace_path"), "committed.txt")
      assert_equal(
        project.fetch("origin_sha"),
        git_output(project, second.fetch("workspace_path"), "rev-parse", "HEAD").strip
      )
      refute_includes git_output(project, project.fetch("project_root"), "log", "--oneline", second.fetch("workspace_branch")), "worker commit"
      assert_equal "commit", git_output(project, project.fetch("project_root"), "cat-file", "-t", worker_sha).strip
    end
  end

  def test_release_removes_the_worktree_but_keeps_the_branch_and_its_commits
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Keep the branch")
      File.write(File.join(workspace.fetch("workspace_path"), "delivered.txt"), "delivered\n")
      git_output(project, workspace.fetch("workspace_path"), "add", ".")
      git_output(project, workspace.fetch("workspace_path"), "commit", "-m", "delivered work")

      assert manager.release_worker_workspace(workspace)

      refute Dir.exist?(workspace.fetch("workspace_path"))
      assert branch_exists?(project, workspace.fetch("workspace_branch"))
      log = git_output(project, project.fetch("project_root"), "log", "--oneline", workspace.fetch("workspace_branch"))
      assert_includes log, "delivered work"
    end
  end

  def test_release_can_delete_the_branch_when_asked
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Delete the branch")

      assert manager.release_worker_workspace(workspace, delete_branch: true)

      refute Dir.exist?(workspace.fetch("workspace_path"))
      refute branch_exists?(project, workspace.fetch("workspace_branch"))
    end
  end

  def test_release_refuses_records_it_does_not_own
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Owned check")

      refute manager.release_worker_workspace("not a hash")
      refute manager.release_worker_workspace(workspace.merge("created" => false))
      refute manager.release_worker_workspace(workspace.merge("strategy" => "project_root"))
      refute manager.release_worker_workspace({
        "strategy" => "project_root",
        "created" => true,
        "workspace_path" => project.fetch("project_root")
      })

      assert Dir.exist?(workspace.fetch("workspace_path")), "refused releases must not delete the worktree"
      assert Dir.exist?(project.fetch("project_root")), "the project checkout must never be removed"
    end
  end

  def test_release_is_idempotent_after_the_worktree_is_gone
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Twice released")

      assert manager.release_worker_workspace(workspace)
      refute manager.release_worker_workspace(workspace)
    end
  end
end
