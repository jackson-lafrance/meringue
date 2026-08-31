# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Real git worktree allocation against a throwaway repository with a local
# origin. Never runs git against the Meringue checkout.
class WorkspaceManagerWorktreeTest < Minitest::Test
  include WorkspaceSupport

  def test_allocates_worktree_based_on_origin_main
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      local_sha = advance_local_main(project)
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Allocate a worktree")

      assert_equal [], workspace.fetch("errors")
      assert workspace.fetch("created"), "expected the worktree to be created: #{workspace.inspect}"
      assert_equal "git_worktree", workspace.fetch("strategy")
      assert_equal "origin/main", workspace.fetch("base_ref")
      assert Dir.exist?(workspace.fetch("workspace_path"))

      head = git_output(project, workspace.fetch("workspace_path"), "rev-parse", "HEAD").strip
      assert_equal project.fetch("origin_sha"), head
      refute_equal local_sha, head
      assert_equal(
        workspace.fetch("workspace_branch"),
        git_output(project, workspace.fetch("workspace_path"), "rev-parse", "--abbrev-ref", "HEAD").strip
      )
    end
  end

  def test_allocated_workspace_records_metadata_for_persistence
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "Persisted metadata")

      assert_equal real_path(project.fetch("project_root")), workspace.fetch("project_root")
      assert_equal real_path(project.fetch("project_root")), workspace.fetch("git_root")
      assert_equal ".", workspace.fetch("project_relative_path")
      assert_equal workspace.fetch("workspace_path"), workspace.fetch("worktree_root_path")
      assert_equal workspace.fetch("worktree_root_path"), workspace.fetch("workspace_root_path")
      assert_equal File.join(tmp, "workspaces", "project"), File.dirname(workspace.fetch("worktree_root_path"))
      refute workspace.key?("adopted")

      %w[strategy project_root workspace_path workspace_branch workspace_root_path
         worktree_root_path git_root base_ref project_relative_path created].each do |key|
        assert workspace.key?(key), "expected persisted workspace metadata to include #{key}"
      end
    end
  end

  def test_bare_repository_root_is_used_as_a_source_for_an_editable_worktree
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(
        manager,
        project,
        task_title: "World bare repository",
        project_root: project.fetch("origin_path")
      )

      assert workspace.fetch("created"), workspace.inspect
      assert_equal "git_worktree", workspace.fetch("strategy")
      refute_equal real_path(project.fetch("origin_path")), real_path(workspace.fetch("workspace_path"))
      assert_equal real_path(project.fetch("origin_path")), workspace.fetch("git_root")
      assert_equal ".", workspace.fetch("project_relative_path")
      assert_equal "false", git_output(project, workspace.fetch("workspace_path"), "rev-parse", "--is-bare-repository").strip
      assert_equal "true", git_output(project, workspace.fetch("workspace_path"), "rev-parse", "--is-inside-work-tree").strip
      assert_equal true, manager.validate_worker_workspace(workspace, agent_id: "P1-I1-W1").fetch("usable")
    end
  end

  def test_project_root_inside_git_root_gets_subdirectory_workspace_path
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(
        manager,
        project,
        task_title: "Work in a subdirectory",
        project_root: File.join(project.fetch("project_root"), "app")
      )

      assert workspace.fetch("created")
      assert_equal "app", workspace.fetch("project_relative_path")
      assert_equal File.join(workspace.fetch("worktree_root_path"), "app"), workspace.fetch("workspace_path")
      assert Dir.exist?(workspace.fetch("workspace_path"))
      assert_path_exists File.join(workspace.fetch("workspace_path"), "main.rb")
    end
  end

  def test_concurrent_workers_from_one_bare_repository_get_distinct_owned_worktrees
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      ready = Queue.new
      start = Queue.new
      workers = %w[P1-I1-W1 P1-I2-W1].map do |agent_id|
        Thread.new do
          ready << true
          start.pop
          allocate_workspace(
            manager,
            project,
            task_title: "Parallel World work",
            issue_id: agent_id.sub(/-W\d+\z/, ""),
            agent_id: agent_id,
            project_root: project.fetch("origin_path")
          )
        end
      end
      workers.length.times { ready.pop }
      workers.length.times { start << true }
      allocated = workers.map(&:value)

      assert allocated.all? { |workspace| workspace.fetch("created") }, allocated.inspect
      assert_equal 2, allocated.map { |workspace| workspace.fetch("workspace_path") }.uniq.length
      assert_equal 2, allocated.map { |workspace| workspace.fetch("workspace_branch") }.uniq.length
      allocated.zip(%w[P1-I1-W1 P1-I2-W1]).each do |workspace, agent_id|
        validation = manager.validate_worker_workspace(workspace, agent_id: agent_id)
        assert validation.fetch("usable"), validation.inspect
      end
    end
  end

  def test_two_workers_on_one_issue_get_distinct_worktrees
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)

      first = allocate_workspace(manager, project, task_title: "Parallel slice", agent_id: "P1-I1-W1")
      second = allocate_workspace(manager, project, task_title: "Parallel slice", agent_id: "P1-I1-W2")

      assert first.fetch("created")
      assert second.fetch("created")
      refute_equal first.fetch("workspace_branch"), second.fetch("workspace_branch")
      refute_equal first.fetch("workspace_path"), second.fetch("workspace_path")
      assert Dir.exist?(first.fetch("workspace_path"))
      assert Dir.exist?(second.fetch("workspace_path"))
    end
  end

  def test_worktree_changes_are_isolated_from_the_project_checkout
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Isolated edits")

      File.write(File.join(workspace.fetch("workspace_path"), "worker.txt"), "worker output\n")

      refute_path_exists File.join(project.fetch("project_root"), "worker.txt")
      assert_equal "", git_output(project, project.fetch("project_root"), "status", "--porcelain")
      refute_equal "", git_output(project, workspace.fetch("workspace_path"), "status", "--porcelain")
    end
  end

  def test_allocation_outside_a_git_repository_fails_instead_of_falling_back
    with_workspace_tmpdir do |tmp|
      plain_root = File.join(tmp, "plain-project")
      FileUtils.mkdir_p(plain_root)
      manager = workspace_manager(tmp)

      workspace = manager.allocate_worker_workspace(
        project_root: plain_root,
        project_id: "P2",
        issue_id: "P2-I1",
        agent_id: "P2-I1-W1",
        task_title: "No git here"
      )

      # There is no fallback to the project root any more: a worker's workspace has to be
      # isolated, so a project that cannot host a worktree fails the allocation outright.
      refute workspace.fetch("created")
      assert_includes workspace.fetch("errors").join(" "), "project root is not inside a git repository"
      assert_equal "version_control_backend_unavailable", workspace.fetch("failure_kind")
      refute Dir.exist?(File.join(tmp, "workspaces")), "a failed allocation must not create a workspaces root"
    end
  end

  def test_missing_project_root_fails_without_creating_anything
    with_workspace_tmpdir do |tmp|
      manager = workspace_manager(tmp)

      workspace = manager.allocate_worker_workspace(
        project_root: File.join(tmp, "does-not-exist"),
        project_id: "P3",
        issue_id: "P3-I1",
        agent_id: "P3-I1-W1",
        task_title: "Missing root"
      )

      refute workspace.fetch("created")
      refute_empty workspace.fetch("errors")
      refute Dir.exist?(File.join(tmp, "does-not-exist"))
    end
  end

  def test_git_worktree_timeout_reports_failure_and_attempts_cleanup
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = TimingOutManager.new(root_path: File.join(tmp, "workspaces"))

      workspace = allocate_workspace(manager, project, task_title: "Hangs forever")

      refute workspace.fetch("created")
      assert workspace.fetch("timed_out")
      assert_in_delta 0.25, workspace.fetch("timeout_seconds"), 0.0001
      assert_includes workspace.fetch("errors"), "git worktree add timed out after 0.25 seconds"
      assert_equal "simulated hang", workspace.fetch("stderr")
      assert workspace.dig("cleanup", "attempted")
      refute branch_exists?(project, workspace.fetch("workspace_branch"))
    end
  end
end
