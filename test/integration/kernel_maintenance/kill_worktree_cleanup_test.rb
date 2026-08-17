# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"
require "support/workspace_support"

# End-to-end kernel coverage for the worktree side effect of `/kill`. A kill now removes each
# killed worker's managed git worktree using the SAME safe cleanup path Prune uses: a clean
# worktree is removed (the delivery branch is retained), a dirty / locked / mismatched worktree
# is preserved with a warning while the kill still succeeds, a worktree another live or queued
# worker still needs is never removed, and a later reconcile never double-removes anything.
class KernelMaintenanceKillWorktreeCleanupTest < Minitest::Test
  include KernelMaintenanceSupport
  include WorkspaceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_kill_removes_a_clean_managed_worktree_and_retains_the_branch
    project, workspace = managed_project_and_workspace(task_title: "Kill the running worker")
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    write_managed_worker_state(project, workspace, worker: worker, issue_status: "working")
    engine = build_engine(harness_client: stub_harness_client)

    result = apply_command(engine, "Kill", { "target_id" => "P1-I1-W1" })

    assert_equal "accepted", result.fetch("status")
    refute Dir.exist?(workspace.fetch("worktree_root_path")), "a clean managed worktree is removed by kill"
    assert branch_exists?(project, workspace.fetch("workspace_branch")), "kill retains the delivery branch"
    state = read_state
    assert_empty state.fetch("agents"), "the killed worker leaves active state"
    kill_log = state.fetch("logs").find { |log| log.fetch("message") == "Killed P1-I1-W1." }
    assert_equal ["P1-I1-W1"], kill_log.dig("details", "removed_worktree_agent_ids")
    assert_equal ["P1-I1-W1"], kill_log.dig("details", "killed_agent_ids")
    assert stub_harness_client.calls.any? { |call| call.first == "kill_session" }, "kill stops the harness session"
  end

  def test_kill_preserves_a_dirty_worktree_with_a_warning_and_still_succeeds
    project, workspace = managed_project_and_workspace(task_title: "Kill a dirty worker")
    unfinished = File.join(workspace.fetch("workspace_path"), "unfinished.txt")
    File.write(unfinished, "do not discard\n")
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    write_managed_worker_state(project, workspace, worker: worker, issue_status: "working")
    engine = build_engine(harness_client: stub_harness_client)

    result = apply_command(engine, "Kill", { "target_id" => "P1-I1-W1" })

    assert_equal "accepted", result.fetch("status"), "a preserved worktree never fails the kill"
    assert_equal "do not discard\n", File.read(unfinished)
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a dirty worktree must never be force-removed"
    state = read_state
    assert_empty state.fetch("agents"), "the killed worker still leaves active state"
    warning = state.fetch("logs").find { |log| log.fetch("message").include?("could not be removed") }
    assert_equal "warning", warning.fetch("level")
    assert_equal "worktree_dirty", warning.dig("details", "reason")
    kill_log = state.fetch("logs").find { |log| log.fetch("message") == "Killed P1-I1-W1." }
    assert_empty kill_log.dig("details", "removed_worktree_agent_ids")
  end

  def test_kill_preserves_a_locked_worktree_and_still_succeeds
    project, workspace = managed_project_and_workspace(task_title: "Kill a locked worker")
    git_output(project, project.fetch("project_root"), "worktree", "lock", workspace.fetch("worktree_root_path"))
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    write_managed_worker_state(project, workspace, worker: worker, issue_status: "working")
    engine = build_engine(harness_client: stub_harness_client)

    result = apply_command(engine, "Kill", { "target_id" => "P1-I1-W1" })

    assert_equal "accepted", result.fetch("status")
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a locked worktree must never be force-removed"
    state = read_state
    assert_empty state.fetch("agents")
    warning = state.fetch("logs").find { |log| log.fetch("message").include?("could not be removed") }
    assert_equal "warning", warning.fetch("level")
    assert_equal "worktree_locked", warning.dig("details", "reason")
  ensure
    # Unlock so the teardown worktree directory can be cleaned up by the OS tmpdir.
    begin
      git_output(project, project.fetch("project_root"), "worktree", "unlock", workspace.fetch("worktree_root_path"))
    rescue StandardError
      nil
    end
  end

  def test_kill_preserves_a_worktree_shared_with_a_retained_worker
    project, workspace = managed_project_and_workspace(task_title: "Shared checkout")
    doomed = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    survivor = managed_worker_record(workspace, id: "P1-I2-W1", issue_id: "P1-I2", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [doomed.fetch("id")]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", agent_ids: [survivor.fetch("id")])
        ],
        agents: [doomed, survivor]
      )
    )
    engine = build_engine(harness_client: stub_harness_client)

    result = apply_command(engine, "Kill", { "target_id" => "P1-I1-W1" })

    assert_equal "accepted", result.fetch("status")
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "the survivor still needs the shared worktree"
    state = read_state
    assert_nil agent_by_id(state, "P1-I1-W1")
    refute_nil agent_by_id(state, "P1-I2-W1"), "the survivor is untouched by the kill"
    kill_log = state.fetch("logs").find { |log| log.fetch("message") == "Killed P1-I1-W1." }
    assert_empty kill_log.dig("details", "removed_worktree_agent_ids")
    assert_empty state.fetch("logs").select { |log| log.fetch("message").include?("could not be removed") }
  end

  def test_kill_preserves_a_worktree_handed_over_to_a_queued_successor
    project, workspace = managed_project_and_workspace(task_title: "Handed over checkout")
    predecessor = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    predecessor["replaced_by_agent_id"] = "P1-I1-W2"
    successor = managed_worker_record(workspace, id: "P1-I1-W2", issue_id: "P1-I1", status: "queued")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: %w[P1-I1-W1 P1-I1-W2])],
        agents: [predecessor, successor]
      )
    )
    engine = build_engine(harness_client: stub_harness_client)

    result = apply_command(engine, "Kill", { "target_id" => "P1-I1-W1" })

    assert_equal "accepted", result.fetch("status")
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "the queued successor still needs the handed-over worktree"
    state = read_state
    assert_nil agent_by_id(state, "P1-I1-W1")
    refute_nil agent_by_id(state, "P1-I1-W2"), "the queued successor is not collateral damage"
    kill_log = state.fetch("logs").find { |log| log.fetch("message") == "Killed P1-I1-W1." }
    assert_empty kill_log.dig("details", "removed_worktree_agent_ids")
  end

  def test_killing_an_issue_subtree_removes_eligible_worktrees_and_preserves_ineligible_ones
    project = create_git_project(@kernel_maintenance_tmp, name: "managed-project")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    clean_workspace = allocate_workspace(manager, project, task_title: "Clean subtree worker", issue_id: "P1-I1", agent_id: "P1-I1-W1")
    dirty_workspace = allocate_workspace(manager, project, task_title: "Dirty subtree worker", issue_id: "P1-I2", agent_id: "P1-I2-W1")
    File.write(File.join(dirty_workspace.fetch("workspace_path"), "unfinished.txt"), "keep me\n")
    clean_worker = managed_worker_record(clean_workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    dirty_worker = managed_worker_record(dirty_workspace, id: "P1-I2-W1", issue_id: "P1-I2", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: [clean_worker.fetch("id")]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", agent_ids: [dirty_worker.fetch("id")])
        ],
        agents: [clean_worker, dirty_worker]
      )
    )
    engine = build_engine(harness_client: stub_harness_client)

    result = apply_command(engine, "Kill", { "target_id" => "P1" })

    assert_equal "accepted", result.fetch("status")
    refute Dir.exist?(clean_workspace.fetch("worktree_root_path")), "the clean subtree worktree is removed"
    assert Dir.exist?(dirty_workspace.fetch("worktree_root_path")), "the dirty subtree worktree is preserved"
    assert branch_exists?(project, clean_workspace.fetch("workspace_branch")), "eligible subtree branches are retained"
    state = read_state
    assert_empty state.fetch("agents")
    assert_empty state.fetch("issues")
    kill_log = state.fetch("logs").find { |log| log.fetch("message") == "Killed P1." }
    assert_equal ["P1-I1-W1"], kill_log.dig("details", "removed_worktree_agent_ids")
    warning = state.fetch("logs").find { |log| log.fetch("source_id", nil) == "P1-I2-W1" }
    assert_equal "warning", warning.fetch("level")
    assert_equal "worktree_dirty", warning.dig("details", "reason")
  end

  def test_reconcile_after_kill_does_not_double_remove_a_worktree
    project, workspace = managed_project_and_workspace(task_title: "Killed before reconcile")
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "working")
    write_managed_worker_state(project, workspace, worker: worker, issue_status: "working")
    engine = build_engine(harness_client: stub_harness_client)

    apply_command(engine, "Kill", { "target_id" => "P1-I1-W1" })
    refute Dir.exist?(workspace.fetch("worktree_root_path"))

    # A later reconciliation pass must find nothing left to prune for the killed worker and must
    # not error or attempt a second removal of a worktree that is already gone.
    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal "accepted", result.fetch("status")
    refute Dir.exist?(workspace.fetch("worktree_root_path"))
    state = read_state
    assert_empty state.fetch("agents")
    assert_empty state.fetch("logs").select { |log| log.fetch("message").include?("could not be removed") }
  end

  private

  def stub_harness_client
    @stub_harness_client ||= StubHarnessClient.new(harness_name: "stub")
  end

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
      harness: "stub",
      pid: 120_000 + id.slice(/\d+\z/).to_i,
      session_id: "stub-session-#{id}",
      session_file: File.join(workspace.fetch("workspace_path"), ".stub-session.json"),
      workspace_path: workspace.fetch("workspace_path"),
      harness_metadata: { "workspace_plan" => workspace, "cwd" => workspace.fetch("workspace_path") },
      extra: {
        "workspace_strategy" => "git_worktree",
        "workspace_branch" => workspace.fetch("workspace_branch")
      }
    )
  end

  def write_managed_worker_state(project, workspace, worker:, issue_status: "completed")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: worker.fetch("issue_id"), project_id: "P1", status: issue_status, agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )
  end
end
