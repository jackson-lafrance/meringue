# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Cleanup after a provisioning failure.
#
# `git worktree add` writes `.git/worktrees/<name>/locked` ("initializing") for the duration of
# the checkout and only unlinks it on success. A worktree add that was killed therefore leaves a
# *locked* registration, which is why the production failure recorded
# `cleanup: {"attempted": true, "worktree_remove_status": 128}`: `git worktree remove --force`
# refuses a locked worktree and `git worktree prune` skips it. The half-written worktree and the
# freshly created `meringue/*` branch both leaked, once per failure.
#
# These tests reproduce that exact state (a real worktree, really locked) and assert cleanup now
# clears it - without ever deleting a branch that carries commits.
class WorkspaceManagerFailedAllocationCleanupTest < Minitest::Test
  include WorkspaceSupport

  def test_a_killed_worktree_add_leaves_no_worktree_and_no_branch_behind
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = TimingOutManager.new(run_add_first: true, reason: "stalled", root_path: File.join(tmp, "workspaces"))

      workspace = allocate_workspace(manager, project, task_title: "Killed mid checkout")

      refute workspace.fetch("created")
      assert workspace.fetch("timed_out")
      cleanup = workspace.fetch("cleanup")
      assert cleanup.fetch("attempted")
      assert cleanup.fetch("worktree_removed"), "the partial worktree must be gone: #{cleanup.inspect}"
      assert cleanup.fetch("branch_removed"), "the branch Meringue created must be gone: #{cleanup.inspect}"
      assert_empty cleanup.fetch("warnings")

      refute Dir.exist?(workspace.fetch("worktree_root_path")), "the half-written worktree directory must be deleted"
      refute branch_exists?(project, workspace.fetch("workspace_branch"))
      registered = git_output(project, project.fetch("project_root"), "worktree", "list", "--porcelain")
      refute_includes registered, workspace.fetch("worktree_root_path")
      refute_includes registered, "locked"
    end
  end

  def test_the_locked_registration_really_is_what_used_to_return_128
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = TimingOutManager.new(run_add_first: true, root_path: File.join(tmp, "workspaces"))
      workspace = allocate_workspace(manager, project, task_title: "Locked worktree")

      # A plain `--force` remove is what the old cleanup ran; it is still refused by git, which is
      # why cleanup has to unlock and double-force. Re-running it now that the worktree is gone
      # proves the registration itself was cleared rather than merely retried.
      _out, stderr, status = Open3.capture3(
        project.fetch("git_env"), "git", "worktree", "remove", "--force", workspace.fetch("worktree_root_path"),
        chdir: project.fetch("project_root")
      )
      refute status.success?
      assert_match(/is not a working tree|No such file/i, stderr)
    end
  end

  # The rule that must never be traded away for tidiness.
  def test_cleanup_keeps_a_branch_that_carries_commits_and_says_why
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = TimingOutManager.new(
        run_add_first: true, commit_before_timeout: true, root_path: File.join(tmp, "workspaces")
      )

      workspace = allocate_workspace(manager, project, task_title: "Committed before the kill")

      cleanup = workspace.fetch("cleanup")
      assert cleanup.fetch("worktree_removed"), "the worktree still goes away"
      refute cleanup.fetch("branch_removed")
      assert_equal "kept_has_commits", cleanup.fetch("branch_result")
      assert_includes cleanup.fetch("warnings").join(" "), "carries 1 commit"
      assert branch_exists?(project, workspace.fetch("workspace_branch"))
      assert_includes(
        git_output(project, project.fetch("project_root"), "log", "--oneline", workspace.fetch("workspace_branch")),
        "worker delivery"
      )
    end
  end

  # Cleanup runs after the allocation budget is spent, so it must not inherit that exhausted
  # budget and kill its own first command.
  def test_cleanup_is_not_killed_by_the_exhausted_allocation_budget
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = TimingOutManager.new(
        run_add_first: true,
        root_path: File.join(tmp, "workspaces"),
        checkout_timeout: 0.5,
        checkout_stall_timeout: 0.5
      )

      workspace = allocate_workspace(manager, project, task_title: "Budget already gone")

      assert workspace.fetch("cleanup").fetch("attempted")
      assert_empty workspace.fetch("cleanup").fetch("warnings")
      refute Dir.exist?(workspace.fetch("worktree_root_path"))
    end
  end

  # A failure that is a collision belongs to someone else's worktree, so cleanup must not touch it.
  def test_a_collision_failure_removes_nothing
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
      git_output(project, project.fetch("project_root"), "worktree", "add", "-b", plan.fetch("workspace_branch"),
                 other_worktree, "origin/main")
      File.write(File.join(other_worktree, "their-work.txt"), "not yours\n")

      workspace = allocate_workspace(manager, project, task_title: "Busy branch")

      assert workspace.fetch("created")
      assert_equal "#{plan.fetch("workspace_branch")}-2", workspace.fetch("workspace_branch")
      assert branch_exists?(project, plan.fetch("workspace_branch")), "the colliding branch is not ours to delete"
      assert_path_exists File.join(other_worktree, "their-work.txt")
    end
  end

  def test_disk_exhaustion_is_detected_cleaned_and_reported_with_bounded_diagnostics
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = DiskExhaustedManager.new(root_path: File.join(tmp, "workspaces"))

      workspace = allocate_workspace(manager, project, task_title: "Disk fills during checkout")

      refute workspace.fetch("created")
      assert_equal "disk_exhausted", workspace.fetch("failure_kind")
      assert_equal Meringue::Workspace::Manager::RECOVERY_RESUME, workspace.fetch("recovery"),
                   "retrying immediately on the same full disk would only repeat the failure"
      assert_equal [
        "git worktree add failed: disk is full (no space left on device); " \
          "free disk space, then prompt this worker to retry provisioning"
      ], workspace.fetch("errors")
      assert workspace.fetch("diagnostics_truncated")
      assert_equal manager.injected_stderr_bytes, workspace.fetch("stderr_bytes")
      assert_operator workspace.fetch("stderr").bytesize, :<=,
                      Meringue::Workspace::Manager::DIAGNOSTIC_OUTPUT_LIMIT_BYTES
      assert_includes workspace.fetch("stderr"), "output bytes omitted"
      assert_includes workspace.fetch("stderr"), "No space left on device",
                      "the bounded tail must retain the actual errno"

      cleanup = workspace.fetch("cleanup")
      assert cleanup.fetch("worktree_removed"), cleanup.inspect
      assert cleanup.fetch("branch_removed"), cleanup.inspect
      assert_empty cleanup.fetch("warnings")
      refute Dir.exist?(workspace.fetch("worktree_root_path"))
      refute branch_exists?(project, workspace.fetch("workspace_branch"))
      refute_includes git_output(project, project.fetch("project_root"), "worktree", "list", "--porcelain"),
                      workspace.fetch("worktree_root_path")
    end
  end

  def test_preflight_enospc_does_not_clean_a_path_that_this_attempt_never_owned
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = PreflightDiskExhaustedManager.new(root_path: File.join(tmp, "workspaces"))
      plan = manager.plan_worker_workspace(
        project_root: project.fetch("project_root"), project_id: "P1", issue_id: "P1-I1",
        agent_id: "P1-I1-W1", task_title: "Preflight ENOSPC"
      )
      FileUtils.mkdir_p(plan.fetch("workspace_path"))
      keep = File.join(plan.fetch("workspace_path"), "user-owned.txt")
      File.write(keep, "do not remove\n")

      workspace = allocate_workspace(manager, project, task_title: "Preflight ENOSPC")

      assert_equal "disk_exhausted", workspace.fetch("failure_kind")
      assert_equal "allocation_not_started", workspace.dig("cleanup", "reason")
      refute workspace.dig("cleanup", "attempted")
      assert_equal "do not remove\n", File.read(keep)
    end
  end

  def test_a_direct_enospc_exception_gets_the_same_recoverable_classification
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = RaisingDiskExhaustedManager.new(root_path: File.join(tmp, "workspaces"))

      workspace = allocate_workspace(manager, project, task_title: "Ruby raises ENOSPC")

      refute workspace.fetch("created")
      assert_equal "disk_exhausted", workspace.fetch("failure_kind")
      assert_equal Meringue::Workspace::Manager::RECOVERY_RESUME, workspace.fetch("recovery")
      assert_includes workspace.fetch("errors").join(" "), "free disk space"
      assert workspace.dig("cleanup", "attempted")
      refute Dir.exist?(workspace.fetch("worktree_root_path"))
      refute branch_exists?(project, workspace.fetch("workspace_branch"))
    end
  end

  def test_cleanup_keeps_the_branch_when_the_partial_worktree_cannot_be_removed
    manager = IncompleteCleanupManager.new(root_path: "/managed")

    cleanup = manager.send(
      :cleanup_incomplete_allocation,
      git_root: "/repo",
      worktree_root: "/managed/partial",
      branch: "meringue/partial"
    )

    refute cleanup.fetch("branch_removed")
    refute manager.branch_release_attempted, "a still-registered branch must not be deleted"
    assert_equal "kept_worktree_remaining", cleanup.fetch("branch_result")
    assert_includes cleanup.fetch("warnings").join(" "), "partial worktree could not be fully removed"
  end

  def test_disk_exhaustion_preserves_an_unowned_preexisting_branch_and_retries_on_a_reserved_candidate
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = DiskExhaustedManager.new(
        fail_once: true,
        root_path: File.join(tmp, "workspaces")
      )
      plan = manager.plan_worker_workspace(
        project_root: project.fetch("project_root"), project_id: "P1", issue_id: "P1-I1",
        agent_id: "P1-I1-W1", task_title: "Retry existing branch"
      )
      git_output(
        project, project.fetch("project_root"), "branch", plan.fetch("workspace_branch"), "origin/main"
      )

      failed = allocate_workspace(manager, project, task_title: "Retry existing branch")

      assert_equal "disk_exhausted", failed.fetch("failure_kind")
      assert_equal "deleted", failed.dig("cleanup", "branch_result")
      assert branch_exists?(project, plan.fetch("workspace_branch")),
             "an unrelated branch has no ownership record and must never be adopted or deleted"
      refute Dir.exist?(plan.fetch("workspace_path"))

      retried = allocate_workspace(manager, project, task_title: "Retry existing branch")
      assert retried.fetch("created"), retried.inspect
      assert_equal "#{plan.fetch("workspace_branch")}-2", retried.fetch("workspace_branch")
      assert_equal "#{plan.fetch("workspace_path")}-2", retried.fetch("workspace_path")
    end
  end

  def test_prune_cleanup_releases_a_failed_allocations_stale_owner_for_a_later_worker
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = TimingOutManager.new(root_path: File.join(tmp, "workspaces"))
      failed = allocate_workspace(manager, project, task_title: "Interrupted owner")
      owner_path = manager.send(:workspace_owner_path, failed.fetch("worktree_root_path"))
      assert_path_exists owner_path

      cleanup = manager.cleanup_pruned_worker_workspace(failed)

      assert cleanup.fetch("success"), cleanup.inspect
      assert_equal "already_removed", cleanup.fetch("status")
      refute_path_exists owner_path

      recovered_manager = workspace_manager(tmp)
      next_worker = allocate_workspace(recovered_manager, project, task_title: "Interrupted owner")
      assert next_worker.fetch("created"), next_worker.inspect
      assert_equal failed.fetch("workspace_path"), next_worker.fetch("workspace_path")
    end
  end

  def test_cleanup_refuses_paths_outside_the_managed_workspace_root
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      outside = File.join(tmp, "not-managed")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "keep.txt"), "keep\n")

      cleanup = manager.send(
        :cleanup_incomplete_allocation,
        git_root: project.fetch("project_root"),
        worktree_root: outside,
        branch: "meringue/whatever"
      )

      assert_path_exists File.join(outside, "keep.txt")
      assert_includes cleanup.fetch("warnings").join(" "), "outside the Meringue workspace root"
    end
  end
end
