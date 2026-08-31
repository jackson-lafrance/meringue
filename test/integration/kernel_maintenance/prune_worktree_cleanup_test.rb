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

    # A successful cleanup no longer costs a log line of its own: the pass summary counts it and
    # carries the per-agent outcome, including the exact worktree path that was removed.
    logs = read_state.fetch("logs")
    assert_empty logs.select { |log| log.fetch("message").include?("managed worktree for worker") }
    summaries = logs.select { |log| log.fetch("message").start_with?("Pruned ") }
    assert_equal 1, summaries.length
    summary = summaries.first
    assert_equal "Pruned 1 issue, 1 agent, 1 worktree, and 0 projects.", summary.fetch("message")
    assert_equal "info", summary.fetch("level")
    assert_equal ["P1-I1-W1"], summary.dig("details", "removed_worktree_agent_ids")
    logged_cleanup = summary.dig("details", "workspace_cleanup_outcomes", 0)
    assert_equal "P1-I1-W1", logged_cleanup.fetch("agent_id")
    assert_equal "removed", logged_cleanup.fetch("status")
    assert_equal real_path(File.dirname(workspace.fetch("worktree_root_path"))),
                 File.dirname(logged_cleanup.fetch("worktree_root_path"))
    assert_equal File.basename(workspace.fetch("worktree_root_path")),
                 File.basename(logged_cleanup.fetch("worktree_root_path"))
  end

  def test_pruning_many_worktrees_reports_them_in_one_summary_line
    project = create_git_project(@kernel_maintenance_tmp, name: "managed-project")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    workspaces = (1..3).map do |index|
      allocate_workspace(
        manager,
        project,
        task_title: "Completed cleanup #{index}",
        issue_id: "P1-I#{index}",
        agent_id: "P1-I#{index}-W1"
      )
    end
    workers = workspaces.each_with_index.map do |workspace, index|
      managed_worker_record(workspace, id: "P1-I#{index + 1}-W1", issue_id: "P1-I#{index + 1}", status: "completed")
    end
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: workers.each_with_index.map do |worker, index|
          issue_record(id: "P1-I#{index + 1}", project_id: "P1", status: "completed", agent_ids: [worker.fetch("id")])
        end,
        agents: workers
      )
    )

    result = apply_command(build_engine, "Prune", {})

    assert_equal "Pruned 3 issues, 3 agents, 3 worktrees, and 0 projects.", result.fetch("message")
    assert_equal %w[P1-I1-W1 P1-I2-W1 P1-I3-W1], result.dig("result", "removed_worktree_agent_ids").sort
    workspaces.each { |workspace| refute Dir.exist?(workspace.fetch("worktree_root_path")) }

    logs = read_state.fetch("logs")
    assert_equal 1, logs.length, "three worktree removals must still be one visible log line"
    assert_equal 3, logs.first.dig("details", "workspace_cleanup_outcomes").length
  end

  def test_already_removed_worktree_is_recorded_as_idempotent_and_does_not_block_pruning
    project, workspace = managed_project_and_workspace(task_title: "Already removed cleanup")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    assert manager.release_worker_workspace(workspace)
    write_managed_worker_state(project, workspace)

    result = apply_command(build_engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal "already_removed", result.dig("result", "workspace_cleanup_outcomes", 0, "status")
    # Nothing was deleted by this pass, so the worktree count is zero and the confirmation stays in
    # the details rather than spending a line of its own.
    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects.", result.fetch("message")
    assert_empty result.dig("result", "removed_worktree_agent_ids")
    state = read_state
    assert_equal 1, state.fetch("logs").length
    summary = state.fetch("logs").first
    assert_equal "worktree_already_removed", summary.dig("details", "workspace_cleanup_outcomes", 0, "reason")
  end

  def test_missing_registered_worktree_is_deregistered_without_retention_warning
    project, workspace = managed_project_and_workspace(task_title: "Missing cleanup")
    FileUtils.rm_rf(workspace.fetch("worktree_root_path"))
    write_managed_worker_state(project, workspace)

    result = apply_command(build_engine, "Prune", {})

    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "removed", cleanup.fetch("status")
    assert cleanup.fetch("success")
    assert_equal "worktree_removed", cleanup.fetch("reason")
    assert cleanup.fetch("worktree_missing"), "a missing registered path is safely deregistered"
    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects.", result.fetch("message")
    state = read_state
    assert_equal 1, state.fetch("logs").length
    assert_equal "info", state.fetch("logs").first.fetch("level")
    assert_empty state.fetch("logs").select { |log| log.fetch("message").include?("Preserved") }
  end

  def test_dirty_worktree_is_preserved_while_eligible_records_are_pruned
    project, workspace = managed_project_and_workspace(task_title: "Dirty cleanup")
    unfinished = File.join(workspace.fetch("workspace_path"), "unfinished.txt")
    File.write(unfinished, "do not discard\n")
    write_managed_worker_state(project, workspace)

    result = apply_command(build_engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1-W1"], result.dig("result", "removed_agent_ids")
    assert_equal ["P1-I1-W1"], result.dig("result", "workspace_cleanup_blocked_agent_ids")
    assert_equal "worktree_dirty", result.dig("result", "workspace_cleanup_outcomes", 0, "reason")
    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects. Preserved 1 managed worktree " \
                 "because cleanup was not safe: P1-I1-W1 (worktree_dirty).", result.fetch("message")
    assert_equal "do not discard\n", File.read(unfinished)
    state = read_state
    assert_empty state.fetch("issues")
    assert_empty state.fetch("agents")
    assert_equal 1, state.fetch("logs").length, "one prune pass writes one line"
    summary = state.fetch("logs").first
    assert_equal "warning", summary.fetch("level")
    assert_equal "worktree_dirty", summary.dig("details", "workspace_cleanup_outcomes", 0, "reason")
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a dirty worktree must never be forced away"
  end

  def test_branch_mismatch_prunes_records_but_preserves_the_registered_worktree
    project, workspace = managed_project_and_workspace(task_title: "Mismatched cleanup")
    registered_branch = workspace.fetch("workspace_branch")
    mismatched_branch = "someone-elses-branch"
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "completed")
    worker["workspace_branch"] = mismatched_branch
    worker.fetch("harness_metadata").fetch("workspace_plan")["workspace_branch"] = mismatched_branch
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )

    result = apply_command(build_engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1-W1"], result.dig("result", "removed_agent_ids")
    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "worktree_branch_mismatch", cleanup.fetch("reason")
    refute cleanup.fetch("success")
    assert_empty result.dig("result", "removed_worktree_agent_ids")
    assert_empty result.dig("result", "retained_issue_ids")
    decision = result.dig("result", "issue_decisions").find { |item| item.fetch("issue_id") == "P1-I1" }
    assert decision.fetch("prunable")
    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects. Preserved 1 managed worktree " \
                 "because cleanup was not safe: P1-I1-W1 (worktree_branch_mismatch).", result.fetch("message")
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a branch mismatch must preserve the worktree"
    listing = git_output(project, project.fetch("project_root"), "worktree", "list", "--porcelain")
    assert_includes listing, "worktree #{real_path(workspace.fetch("worktree_root_path"))}"
    assert_includes listing, "branch refs/heads/#{registered_branch}"
    state = read_state
    assert_empty state.fetch("issues")
    assert_empty state.fetch("agents")
    assert_equal 1, state.fetch("logs").length, "one prune pass writes one line"
    summary = state.fetch("logs").first
    assert_equal "warning", summary.fetch("level")
    assert_nil summary.fetch("source_id", nil), "the retention is reported by the pass, not per worker"
    assert_equal "worktree_branch_mismatch", summary.dig("details", "workspace_cleanup_outcomes", 0, "reason")
  end

  # A shared worktree is removed only once nobody needs it. The *record* of a worker that is done
  # with it may go immediately: retaining it would mean a record prune can never clean up plus one
  # "could not be removed" warning on every single pass.
  def test_prune_keeps_a_shared_worktree_alive_for_the_worker_still_using_it
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

    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "skipped", cleanup.fetch("status")
    assert_equal "workspace_shared_with_retained_worker", cleanup.fetch("reason")
    assert cleanup.fetch("success")
    assert_equal ["P1-I2-W1"], cleanup.fetch("sharing_agent_ids")
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "the worker still using it must keep its checkout"
    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I2-W1"], ids(read_state.fetch("agents"))
    assert_empty result.dig("result", "removed_worktree_agent_ids")
    assert_empty read_state.fetch("logs").select { |log| log.fetch("message").include?("could not be removed") }
  end

  # Once every sharer is settled, one pass removes the shared worktree exactly once and credits the
  # removal to a single worker rather than double-counting it.
  def test_prune_removes_a_shared_worktree_once_when_every_sharer_is_settled
    project, workspace = managed_project_and_workspace(task_title: "Shared handover")
    first = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "completed")
    second = managed_worker_record(workspace, id: "P1-I1-W2", issue_id: "P1-I1", status: "completed")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "completed")],
        issues: [
          issue_record(
            id: "P1-I1",
            project_id: "P1",
            status: "completed",
            agent_ids: [first.fetch("id"), second.fetch("id")]
          )
        ],
        agents: [first, second]
      )
    )

    result = apply_command(build_engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal %w[P1-I1-W1 P1-I1-W2], result.dig("result", "removed_agent_ids").sort
    refute Dir.exist?(workspace.fetch("worktree_root_path"))
    assert_equal 1, result.dig("result", "removed_worktree_agent_ids").length
    assert_equal "Pruned 1 issue, 2 agents, 1 worktree, and 1 project.", result.fetch("message")
    assert branch_exists?(project, workspace.fetch("workspace_branch")), "the shared delivery branch must survive"
    assert_empty read_state.fetch("logs").select { |log| log.fetch("message").include?("could not be removed") }
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
    # Reconciliation shares the consolidated wording, so the filesystem side effect is still
    # visible without one line per worker.
    summaries = state.fetch("logs").select { |log| log.fetch("message").start_with?("Pruned killed records:") }
    assert_equal 1, summaries.length
    assert_equal "Pruned killed records: 0 issues, 1 agent, 1 worktree, and 0 projects.",
                 summaries.first.fetch("message")
    assert_equal ["P1-I1-W1"], summaries.first.dig("details", "removed_worktree_agent_ids")
  end

  # The killed-record cleanup shares the prune summary shape, so it must also report a preserved
  # worktree in that one line - at `warning` - instead of a separate per-worker entry.
  def test_reconciliation_reports_a_preserved_worktree_in_its_one_summary_line
    project, workspace = managed_project_and_workspace(task_title: "Killed dirty cleanup")
    File.write(File.join(workspace.fetch("workspace_path"), "unfinished.txt"), "do not discard\n")
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "killed")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )

    apply_command(build_engine, "ReconcileSessions", {})

    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a dirty worktree is never force-removed"
    logs = read_state.fetch("logs")
    summaries = logs.select { |log| log.fetch("message").start_with?("Pruned killed records:") }
    assert_equal 1, summaries.length
    assert_equal "Pruned killed records: 0 issues, 1 agent, 0 worktrees, and 0 projects. " \
                 "Preserved 1 managed worktree because cleanup was not safe: P1-I1-W1 (worktree_dirty).",
                 summaries.first.fetch("message")
    assert_equal "warning", summaries.first.fetch("level")
    assert_equal "worktree_dirty", summaries.first.dig("details", "workspace_cleanup_outcomes", 0, "reason")
    assert_empty logs.select { |log| log.fetch("message").include?("could not be removed") }
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
