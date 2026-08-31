# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"
require "support/workspace_support"

# Kill-side coverage for the managed worktree cleanup coupled to /kill. Killing a worker
# removes its private managed git worktree from disk (branch retained) reusing the same safe
# cleanup path as /prune; a worktree another live or queued agent still shares is left in
# place and reported as retained, and a dirty or locked checkout is never force-removed.
class KernelWorkersKillWorktreeCleanupTest < Minitest::Test
  include KernelMaintenanceSupport
  include WorkspaceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_killing_a_worker_removes_its_private_worktree_and_keeps_the_branch
    project, workspace = managed_project_and_workspace(task_title: "Kill private cleanup")
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )

    result = apply_command(build_engine, "Kill", { "target_id" => "P1-I1-W1" })

    refute Dir.exist?(workspace.fetch("worktree_root_path")), "a killed worker's private worktree is removed"
    assert branch_exists?(project, workspace.fetch("workspace_branch")), "the delivery branch is retained"
    assert_equal ["P1-I1-W1"], result.dig("result", "removed_worktree_agent_ids")
    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "removed", cleanup.fetch("status")
    assert cleanup.fetch("success")
    state = read_state
    assert_empty state.fetch("agents")
    summary = state.fetch("logs").find { |log| log.fetch("message").start_with?("Removed ") }
    refute_nil summary, "the kill log surfaces the removed worktree outcome"
    assert_equal "info", summary.fetch("level")
  end

  def test_killing_a_worker_retains_a_worktree_shared_with_another_live_worker
    project, workspace = managed_project_and_workspace(task_title: "Kill shared cleanup")
    first = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    second = managed_worker_record(workspace, id: "P1-I2-W1", issue_id: "P1-I2", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [first.fetch("id")]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", agent_ids: [second.fetch("id")])
        ],
        agents: [first, second]
      )
    )

    result = apply_command(build_engine, "Kill", { "target_id" => "P1-I1-W1" })

    assert Dir.exist?(workspace.fetch("worktree_root_path")), "the shared worktree stays for the live sharer"
    assert_empty result.dig("result", "removed_worktree_agent_ids")
    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "skipped", cleanup.fetch("status")
    assert_equal "workspace_shared_with_retained_worker", cleanup.fetch("reason")
    assert cleanup.fetch("success")
    assert_equal ["P1-I2-W1"], cleanup.fetch("sharing_agent_ids")
    state = read_state
    assert_empty ids(state.fetch("agents")).grep(/^P1-I1-W1$/)
    assert_equal ["P1-I2-W1"], ids(state.fetch("agents"))
    summary = state.fetch("logs").find { |log| log.fetch("message").start_with?("Retained ") }
    refute_nil summary, "the kill log names the agent still using the retained worktree"
    assert_includes summary.fetch("message"), "still in use by P1-I2-W1"
    assert_equal "info", summary.fetch("level")
  end

  def test_killing_an_issue_subtree_removes_private_worktrees_but_retains_a_shared_one
    project = create_git_project(@kernel_maintenance_tmp, name: "managed-project")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    private_workspace = allocate_workspace(manager, project, task_title: "Private kill", issue_id: "P1-I1", agent_id: "P1-I1-W1")
    shared_workspace = allocate_workspace(manager, project, task_title: "Shared kill", issue_id: "P1-I1", agent_id: "P1-I1-W2")
    private_worker = managed_worker_record(private_workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    shared_worker = managed_worker_record(shared_workspace, id: "P1-I1-W2", issue_id: "P1-I1", status: "working")
    survivor = managed_worker_record(shared_workspace, id: "P1-I2-W1", issue_id: "P1-I2", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [private_worker.fetch("id"), shared_worker.fetch("id")]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", agent_ids: [survivor.fetch("id")])
        ],
        agents: [private_worker, shared_worker, survivor]
      )
    )

    result = apply_command(build_engine, "Kill", { "target_id" => "P1-I1" })

    refute Dir.exist?(private_workspace.fetch("worktree_root_path")), "the private worktree is removed with its issue"
    assert Dir.exist?(shared_workspace.fetch("worktree_root_path")), "the shared worktree stays for the surviving sharer"
    assert branch_exists?(project, private_workspace.fetch("workspace_branch")), "removed worktrees keep their branches"
    assert_equal ["P1-I1-W1"], result.dig("result", "removed_worktree_agent_ids")
    outcomes = result.dig("result", "workspace_cleanup_outcomes")
    shared_outcome = outcomes.find { |outcome| outcome.fetch("agent_id", nil) == "P1-I1-W2" }
    assert_equal "skipped", shared_outcome.fetch("status")
    assert_equal "workspace_shared_with_retained_worker", shared_outcome.fetch("reason")
    assert_equal ["P1-I2-W1"], shared_outcome.fetch("sharing_agent_ids")
    state = read_state
    assert_nil issue_by_id(state, "P1-I1")
    assert_equal ["P1-I2-W1"], ids(state.fetch("agents"))
  end

  def test_killing_a_worker_with_a_dirty_worktree_preserves_it_with_a_warning
    project, workspace = managed_project_and_workspace(task_title: "Kill dirty cleanup")
    unfinished = File.join(workspace.fetch("workspace_path"), "unfinished.txt")
    File.write(unfinished, "do not discard\n")
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )

    result = apply_command(build_engine, "Kill", { "target_id" => "P1-I1-W1" })

    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a dirty worktree is never force-removed"
    assert_equal "do not discard\n", File.read(unfinished)
    assert_empty result.dig("result", "removed_worktree_agent_ids")
    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "worktree_dirty", cleanup.fetch("reason")
    refute cleanup.fetch("success")
    state = read_state
    assert_empty state.fetch("agents"), "the killed record is removed even when the worktree is preserved"
    summary = state.fetch("logs").find { |log| log.fetch("message").start_with?("Preserved ") }
    refute_nil summary, "the kill log warns that the worktree was preserved"
    assert_equal "warning", summary.fetch("level")
    assert_includes summary.fetch("message"), "worktree_dirty"
    # The preserved worktree is named once, by the kill summary. The per-worker detail lives in
    # that entry's structured outcomes rather than a warning line of its own.
    assert_empty state.fetch("logs").select { |log| log.fetch("message").include?("could not be removed") }
    assert_equal "worktree_dirty", summary.dig("details", "workspace_cleanup_outcomes", 0, "reason")
  end

  def test_killing_a_worker_with_a_locked_worktree_preserves_it
    project, workspace = managed_project_and_workspace(task_title: "Kill locked cleanup")
    git_output(project, project.fetch("project_root"), "worktree", "lock", workspace.fetch("worktree_root_path"))
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )

    result = apply_command(build_engine, "Kill", { "target_id" => "P1-I1-W1" })

    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a locked worktree is never force-removed"
    assert_empty result.dig("result", "removed_worktree_agent_ids")
    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "worktree_locked", cleanup.fetch("reason")
    refute cleanup.fetch("success")
    state = read_state
    assert_empty state.fetch("agents")
    summary = state.fetch("logs").find { |log| log.fetch("message").start_with?("Preserved ") }
    refute_nil summary
    assert_equal "warning", summary.fetch("level")
  ensure
    # Unlock so the worktree can be cleaned up during teardown; a locked worktree blocks
    # `git worktree remove --force` and would leak the temp directory otherwise.
    if defined?(project) && project && Dir.exist?(workspace.fetch("worktree_root_path"))
      begin
        git_output(project, project.fetch("project_root"), "worktree", "unlock", workspace.fetch("worktree_root_path"))
      rescue StandardError
        nil
      end
    end
  end

  private

  def managed_project_and_workspace(task_title:)
    project = create_git_project(@kernel_maintenance_tmp, name: "managed-project")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    workspace = allocate_workspace(manager, project, task_title: task_title)
    [project, workspace]
  end

  def managed_worker_record(workspace, id:, issue_id:, status:)
    worker_record(
      id: id,
      issue_id: issue_id,
      project_id: "P1",
      status: status,
      harness: nil,
      workspace_path: workspace.fetch("workspace_path"),
      harness_metadata: { "workspace_plan" => workspace },
      extra: {
        "workspace_strategy" => "git_worktree",
        "workspace_branch" => workspace.fetch("workspace_branch")
      }
    )
  end
end
