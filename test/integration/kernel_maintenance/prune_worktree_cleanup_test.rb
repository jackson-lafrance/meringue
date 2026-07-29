# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"
require "support/workspace_support"

# End-to-end kernel coverage for the filesystem side effect coupled to record pruning.
# All repositories, worktrees, state, and logs live under one temporary directory.
class KernelMaintenancePruneWorktreeCleanupTest < Minitest::Test
  include KernelMaintenanceSupport
  include WorkspaceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_prune_removes_clean_managed_worktree_and_records_the_outcome
    project, workspace = managed_project_and_workspace(task_title: "Completed cleanup")
    write_managed_worker_state(project, workspace)

    result = apply_command(build_engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1-W1"], result.dig("result", "removed_agent_ids")
    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "removed", cleanup.fetch("status")
    assert cleanup.fetch("success")
    refute Dir.exist?(workspace.fetch("worktree_root_path"))
    assert branch_exists?(project, workspace.fetch("workspace_branch")), "worktree cleanup must preserve the delivery branch"

    cleanup_log = read_state.fetch("logs").find { |log| log.fetch("message").start_with?("Removed managed worktree") }
    refute_nil cleanup_log
    assert_equal "info", cleanup_log.fetch("level")
    assert_equal real_path(File.dirname(workspace.fetch("worktree_root_path"))),
                 File.dirname(cleanup_log.dig("details", "worktree_root_path"))
    assert_equal File.basename(workspace.fetch("worktree_root_path")),
                 File.basename(cleanup_log.dig("details", "worktree_root_path"))
  end

  def test_already_removed_worktree_is_logged_as_idempotent_and_does_not_block_pruning
    project, workspace = managed_project_and_workspace(task_title: "Already removed cleanup")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    assert manager.release_worker_workspace(workspace)
    write_managed_worker_state(project, workspace)

    result = apply_command(build_engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal "already_removed", result.dig("result", "workspace_cleanup_outcomes", 0, "status")
    state = read_state
    log = state.fetch("logs").find { |entry| entry.fetch("message").start_with?("Confirmed the managed worktree") }
    refute_nil log
    assert_equal "worktree_already_removed", log.dig("details", "reason")
  end

  def test_dirty_worktree_blocks_record_pruning_and_is_retried_after_it_is_clean
    project, workspace = managed_project_and_workspace(task_title: "Dirty cleanup")
    unfinished = File.join(workspace.fetch("workspace_path"), "unfinished.txt")
    File.write(unfinished, "do not discard\n")
    write_managed_worker_state(project, workspace)
    engine = build_engine

    blocked = apply_command(engine, "Prune", {})

    assert_empty blocked.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1-W1"], blocked.dig("result", "workspace_cleanup_blocked_agent_ids")
    assert_equal "worktree_dirty", blocked.dig("result", "workspace_cleanup_outcomes", 0, "reason")
    decision = blocked.dig("result", "issue_decisions").find { |item| item.fetch("issue_id") == "P1-I1" }
    assert_includes decision.fetch("blockers"), "workspace_cleanup_failed"
    assert_equal "do not discard\n", File.read(unfinished)
    assert_equal %w[P1-I1-W1], ids(read_state.fetch("agents"))
    warning = read_state.fetch("logs").find { |log| log.fetch("message").include?("could not be removed") }
    assert_equal "warning", warning.fetch("level")
    assert_equal "worktree_dirty", warning.dig("details", "reason")

    File.delete(unfinished)
    retried = apply_command(engine, "Prune", {})

    assert_equal ["P1-I1"], retried.dig("result", "removed_issue_ids")
    assert_equal "removed", retried.dig("result", "workspace_cleanup_outcomes", 0, "status")
    refute Dir.exist?(workspace.fetch("worktree_root_path"))
  end

  def test_prune_never_removes_a_workspace_still_referenced_by_another_worker
    project, workspace = managed_project_and_workspace(task_title: "Shared metadata")
    first = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "completed")
    second = managed_worker_record(workspace, id: "P1-I2-W1", issue_id: "P1-I2", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: [first.fetch("id")]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", agent_ids: [second.fetch("id")])
        ],
        agents: [first, second]
      )
    )

    result = apply_command(build_engine, "Prune", {})

    assert_empty result.dig("result", "removed_issue_ids")
    assert_equal "workspace_owned_by_another_worker", result.dig("result", "workspace_cleanup_outcomes", 0, "reason")
    assert Dir.exist?(workspace.fetch("worktree_root_path"))
    assert_equal %w[P1-I1-W1 P1-I2-W1], ids(read_state.fetch("agents")).sort
  end

  def test_stale_issue_agent_link_never_prunes_another_issues_worker_or_worktree
    project, workspace = managed_project_and_workspace(task_title: "Sibling ownership")
    worker = managed_worker_record(workspace, id: "P1-I2-W1", issue_id: "P1-I2", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: [worker.fetch("id")]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", agent_ids: [worker.fetch("id")])
        ],
        agents: [worker]
      )
    )

    result = apply_command(build_engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_empty result.dig("result", "removed_agent_ids")
    assert_empty result.dig("result", "workspace_cleanup_outcomes")
    assert Dir.exist?(workspace.fetch("worktree_root_path"))
    state = read_state
    assert_equal ["P1-I2-W1"], ids(state.fetch("agents"))
    assert_equal ["P1-I2-W1"], issue_by_id(state, "P1-I2").fetch("agent_ids")
  end

  def test_reconciliation_cleans_a_standalone_killed_workers_worktree_before_removing_its_record
    project, workspace = managed_project_and_workspace(task_title: "Killed cleanup")
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "killed")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )

    result = apply_command(build_engine, "ReconcileSessions", {})

    assert_equal ["P1-I1-W1"], result.dig("result", "pruned_agent_ids")
    refute Dir.exist?(workspace.fetch("worktree_root_path"))
    state = read_state
    assert_empty state.fetch("agents")
    assert_equal ["P1-I1"], ids(state.fetch("issues"))
    assert_empty issue_by_id(state, "P1-I1").fetch("agent_ids")
    assert state.fetch("logs").any? { |log| log.fetch("message").start_with?("Removed managed worktree") }
  end

  def test_project_root_and_dedicated_directory_workspaces_are_not_deleted
    project_root = make_dir("plain-project")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project_root, status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: ["P1-I1-W1"])],
        agents: [
          worker_record(
            id: "P1-I1-W1",
            issue_id: "P1-I1",
            project_id: "P1",
            status: "completed",
            workspace_path: project_root,
            extra: { "workspace_strategy" => "project_root" }
          )
        ]
      )
    )

    result = apply_command(build_engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal "skipped", result.dig("result", "workspace_cleanup_outcomes", 0, "status")
    assert_equal "not_a_managed_worktree", result.dig("result", "workspace_cleanup_outcomes", 0, "reason")
    assert Dir.exist?(project_root), "the project checkout must never be removed"
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
      workspace_path: workspace.fetch("workspace_path"),
      harness_metadata: { "workspace_plan" => workspace },
      extra: {
        "workspace_strategy" => "git_worktree",
        "workspace_branch" => workspace.fetch("workspace_branch")
      }
    )
  end

  def write_managed_worker_state(project, workspace)
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "completed")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )
  end
end
