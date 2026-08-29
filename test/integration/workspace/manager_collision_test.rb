# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Branch/path collisions, reuse of an interrupted allocation, and release. The
# invariant under test is that no user work is ever deleted to make room.
class WorkspaceManagerCollisionTest < Minitest::Test
  include WorkspaceSupport

  # Forces independent workers onto the same preferred candidate so ownership—not the normal
  # agent-id hash in the name—is what must prevent adoption. This reproduces legacy plans and any
  # future naming collision without weakening production branch naming.
  class SameCandidateManager < Meringue::Workspace::Manager
    def plan_worker_workspace(**arguments)
      plan = super
      project = File.basename(File.expand_path(arguments.fetch(:project_root)))
      plan.merge(
        "workspace_path" => File.join(root_path, project, "forced-candidate"),
        "workspace_branch" => "forced-candidate-deadbeef"
      )
    end
  end

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

  def test_foreign_owner_is_never_adopted_and_allocation_uniquifies
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = SameCandidateManager.new(root_path: File.join(tmp, "workspaces"))
      first = allocate_workspace(manager, project, task_title: "One", issue_id: "P1-I1", agent_id: "P1-I1-W1")
      foreign_file = File.join(first.fetch("workspace_path"), "owner-one.txt")
      File.write(foreign_file, "do not share\n")

      second = allocate_workspace(manager, project, task_title: "Two", issue_id: "P1-I2", agent_id: "P1-I2-W1")

      assert second.fetch("created"), second.inspect
      assert_equal "#{first.fetch("workspace_path")}-2", second.fetch("workspace_path")
      assert_equal "#{first.fetch("workspace_branch")}-2", second.fetch("workspace_branch")
      assert_equal "do not share\n", File.read(foreign_file)
      assert manager.validate_worker_workspace(first, agent_id: "P1-I1-W1").fetch("usable")
      assert manager.validate_worker_workspace(second, agent_id: "P1-I2-W1").fetch("usable")
      refute manager.validate_worker_workspace(first, agent_id: "P1-I2-W1").fetch("usable")
    end
  end

  def test_concurrent_foreign_claims_cannot_receive_the_same_candidate
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = SameCandidateManager.new(root_path: File.join(tmp, "workspaces"))
      ready = Queue.new
      start = Queue.new
      ids = %w[P1-I1-W1 P1-I2-W1]
      threads = ids.map do |agent_id|
        Thread.new do
          ready << true
          start.pop
          allocate_workspace(
            manager,
            project,
            task_title: "Concurrent collision",
            issue_id: agent_id.sub(/-W\d+\z/, ""),
            agent_id: agent_id
          )
        end
      end
      ids.length.times { ready.pop }
      ids.length.times { start << true }
      allocated = threads.map(&:value)

      assert allocated.all? { |workspace| workspace.fetch("created") }, allocated.inspect
      assert_equal 2, allocated.map { |workspace| workspace.fetch("workspace_path") }.uniq.length
      assert_equal 2, allocated.map { |workspace| workspace.fetch("workspace_branch") }.uniq.length
      allocated.zip(ids).each do |workspace, agent_id|
        assert manager.validate_worker_workspace(workspace, agent_id: agent_id).fetch("usable")
      end
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

  # A previous attempt for this worker may leave an intact, registered, unlocked worktree on
  # the exact planned branch at the planned path while its ownership record is gone (a crashed
  # instance, a migrated workspace root, or a checkout created before ownership files existed).
  # That is this worker's own resumable checkout of a branch already checked out locally, not a
  # foreign collision: re-provisioning must adopt it instead of spending minutes on a redundant
  # `git worktree add` for a suffixed branch.
  def test_reuses_an_existing_checkout_of_the_same_branch_when_ownership_is_absent
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      first = allocate_workspace(manager, project, task_title: "Resume me")
      in_progress = File.join(first.fetch("workspace_path"), "in-progress.txt")
      File.write(in_progress, "half-finished work\n")

      # Simulate the ownership record being lost while the worktree stays intact and registered.
      FileUtils.rm_rf(manager.send(:ownership_directory))

      second = allocate_workspace(manager, project, task_title: "Resume me")

      assert second.fetch("created"), second.inspect
      assert second.fetch("adopted"), "must adopt the existing local checkout instead of provisioning a new worktree"
      assert_equal first.fetch("workspace_path"), second.fetch("workspace_path")
      assert_equal first.fetch("workspace_branch"), second.fetch("workspace_branch")
      assert_equal "half-finished work\n", File.read(in_progress)
      assert manager.validate_worker_workspace(second, agent_id: "P1-I1-W1").fetch("usable")
    end
  end

  # The ownership-absent reuse must not adopt a worktree that has moved to another branch, nor
  # one that a different worker owns. Both stay collisions so the allocator falls back to a
  # uniquified candidate, and the existing checkout is left untouched.
  def test_an_existing_checkout_on_a_different_branch_is_not_adopted_when_ownership_is_absent
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      first = allocate_workspace(manager, project, task_title: "Moved branch")
      foreign_file = File.join(first.fetch("workspace_path"), "do-not-share.txt")
      File.write(foreign_file, "someone moved branches\n")
      # Move the existing worktree onto a different managed branch so it no longer matches the
      # planned branch, then drop the ownership record so reuse is considered.
      git_output(project, first.fetch("workspace_path"), "checkout", "-b", "meringue/someone-else")
      FileUtils.rm_rf(manager.send(:ownership_directory))

      second = allocate_workspace(manager, project, task_title: "Moved branch")

      assert second.fetch("created"), second.inspect
      refute second.fetch("adopted", false)
      assert_equal "#{first.fetch("workspace_path")}-2", second.fetch("workspace_path")
      assert_equal "#{first.fetch("workspace_branch")}-2", second.fetch("workspace_branch")
      assert_equal "someone moved branches\n", File.read(foreign_file)
    end
  end

  # A locked (half-finished) checkout is never adopted even when ownership is absent: reusing it
  # would hand a worker a worktree git still considers mid-checkout. It stays a collision.
  def test_a_locked_existing_checkout_is_not_adopted_when_ownership_is_absent
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      first = allocate_workspace(manager, project, task_title: "Locked checkout")
      lock_path = File.join(project.fetch("project_root"), ".git", "worktrees",
                             File.basename(first.fetch("worktree_root_path")), "locked")
      File.write(lock_path, "initializing\n") if Dir.exist?(File.dirname(lock_path))
      FileUtils.rm_rf(manager.send(:ownership_directory))

      second = allocate_workspace(manager, project, task_title: "Locked checkout")

      assert second.fetch("created"), second.inspect
      refute second.fetch("adopted", false)
      assert_equal "#{first.fetch("workspace_path")}-2", second.fetch("workspace_path")
      assert_equal "#{first.fetch("workspace_branch")}-2", second.fetch("workspace_branch")
      assert Dir.exist?(first.fetch("workspace_path")), "the locked worktree must not be removed"
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

  # A leftover meringue/ branch that carries commits is never recreated from
  # origin/main: reallocation checks the branch back out, so an interrupted
  # worker's commits stay reachable and stay in its worktree.
  def test_reallocating_after_release_keeps_the_branch_and_its_commits
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
      assert_path_exists File.join(second.fetch("workspace_path"), "committed.txt")
      assert_equal worker_sha, git_output(project, second.fetch("workspace_path"), "rev-parse", "HEAD").strip
      assert_includes git_output(project, project.fetch("project_root"), "log", "--oneline", second.fetch("workspace_branch")), "worker commit"
    end
  end

  # The other half of the same rule: an empty leftover branch carries nothing, so
  # it is deleted and recreated from a fresh origin/main instead of pinning the
  # worker to a stale base.
  def test_reallocating_after_release_recreates_an_empty_branch_from_origin_main
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      first = allocate_workspace(manager, project, task_title: "Nothing committed")
      assert manager.release_worker_workspace(first)
      assert branch_exists?(project, first.fetch("workspace_branch"))

      second = allocate_workspace(manager, project, task_title: "Nothing committed")

      assert second.fetch("created")
      assert_equal first.fetch("workspace_branch"), second.fetch("workspace_branch")
      assert_equal(
        project.fetch("origin_sha"),
        git_output(project, second.fetch("workspace_path"), "rev-parse", "HEAD").strip
      )
    end
  end

  def test_release_with_delete_branch_keeps_a_branch_that_carries_commits
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Committed then released")
      File.write(File.join(workspace.fetch("workspace_path"), "delivered.txt"), "delivered\n")
      git_output(project, workspace.fetch("workspace_path"), "add", ".")
      git_output(project, workspace.fetch("workspace_path"), "commit", "-m", "delivered work")

      assert manager.release_worker_workspace(workspace, delete_branch: true)

      refute Dir.exist?(workspace.fetch("workspace_path"))
      assert branch_exists?(project, workspace.fetch("workspace_branch")),
             "a branch with commits must survive even an explicit delete"
      assert_includes(
        git_output(project, project.fetch("project_root"), "log", "--oneline", workspace.fetch("workspace_branch")),
        "delivered work"
      )
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
