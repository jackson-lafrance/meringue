# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Prune of errored records (removed in the same pass as resolved ones), plus the killed-record
# reconciliation prune that runs inside ReconcileSessions.
class KernelMaintenancePruneErroredTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_prune_removes_errored_bundles_and_standalone_errored_heads
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "errored", agent_ids: ["P1-I1-W1"]),
          issue_record(id: "P1-I2", project_id: "P1", status: "completed")
        ],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "errored"),
          head_record(id: "H1", status: "errored"),
          head_record(id: "H2", status: "working")
        ]
      )
    )
    engine = build_engine

    # One pass: the errored bundle, the completed bundle, and the standalone errored head all go.
    result = apply_command(engine, "Prune", {})

    assert_equal "accepted", result.fetch("status")
    # The agent count is every agent record the pass removed: the issue-owned worker plus the
    # standalone errored head. Reporting only standalone agents used to claim "0 standalone agents"
    # for a pass that had just deleted a worker.
    assert_equal "Pruned 2 issues, 2 agents, 0 worktrees, and 0 projects.", result.fetch("message")
    assert_equal %w[P1-I1 P1-I2], result.dig("result", "removed_issue_ids").sort
    assert_equal ["H1"], result.dig("result", "removed_standalone_agent_ids")
    assert_equal %w[H1 P1-I1-W1], result.dig("result", "removed_agent_ids").sort

    state = read_state
    assert_empty state.fetch("issues")
    assert_equal ["H2"], ids(state.fetch("agents"))
    log = state.fetch("logs").last
    assert_equal "Pruned 2 issues, 2 agents, 0 worktrees, and 0 projects.", log.fetch("message")
    assert_equal ["H1"], log.dig("details", "removed_standalone_agent_ids")
    assert_equal %w[H1 P1-I1-W1], log.dig("details", "removed_agent_ids").sort
    refute log.fetch("details").key?("selector"), "prune no longer has a selector"
    assert_documented_status_vocabulary(state)
  end

  # The case the summary rewrite was asked for: several issue-owned workers and a couple of
  # standalone heads leave in one pass, and the user is told about all of them in one line.
  def test_summary_counts_issue_owned_and_standalone_agents_together_in_one_line
    issues = (1..5).map do |index|
      issue_record(id: "P1-I#{index}", project_id: "P1", status: "completed", agent_ids: ["P1-I#{index}-W1"])
    end
    workers = (1..5).map do |index|
      worker_record(id: "P1-I#{index}-W1", issue_id: "P1-I#{index}", project_id: "P1", status: "completed")
    end
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: issues,
        agents: workers + [head_record(id: "H1", status: "errored"), head_record(id: "H2", status: "errored")]
      )
    )

    result = apply_command(build_engine, "Prune", {})

    assert_equal "Pruned 5 issues, 7 agents, 0 worktrees, and 0 projects.", result.fetch("message")
    assert_equal 7, result.dig("result", "removed_agent_ids").length
    assert_equal %w[H1 H2], result.dig("result", "removed_standalone_agent_ids").sort

    state = read_state
    assert_empty state.fetch("agents")
    prune_logs = state.fetch("logs").select { |log| log.fetch("message").start_with?("Pruned ") }
    assert_equal 1, prune_logs.length, "one prune pass must produce one summary line"
  end

  def test_errored_issue_with_live_worker_is_retained
    # "idle" is deliberately absent: an idle worker has nothing in flight, so it does not block
    # cleanup (see test_errored_issue_with_an_idle_worker_is_pruned below).
    %w[queued working blocked].each do |worker_status|
      write_state(
        state_fixture(
          projects: [project_record(id: "P1", status: "working")],
          issues: [issue_record(id: "P1-I1", project_id: "P1", status: "errored", agent_ids: ["P1-I1-W1"])],
          agents: [worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: worker_status)]
        )
      )
      engine = build_engine

      result = apply_command(engine, "Prune", {})

      assert_empty result.dig("result", "removed_issue_ids"),
                   "errored issue with a #{worker_status} worker must be retained"
      assert_equal ["P1-I1"], ids(read_state.fetch("issues"))
    end
  end

  def test_errored_issue_with_an_idle_worker_is_pruned
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "errored", agent_ids: ["P1-I1-W1"])],
        agents: [worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "idle")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1-W1"], result.dig("result", "removed_agent_ids")
    assert_empty read_state.fetch("issues")
  end

  def test_prune_never_removes_a_healthy_head
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working")],
        agents: [head_record(id: "H1", status: "working")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", {})

    assert_equal "Pruned 0 issues, 0 agents, 0 worktrees, and 0 projects.", result.fetch("message")
    state = read_state
    assert_equal ["P1-I1"], ids(state.fetch("issues"))
    assert_equal ["H1"], ids(state.fetch("agents"))
  end

  def test_prune_removes_the_project_when_every_issue_is_removed
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "errored")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "errored")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["P1"], result.dig("result", "removed_project_ids")
    assert_empty read_state.fetch("projects")
  end

  def test_kill_removes_the_issue_subtree_and_its_workers_immediately
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: ["P1-I1-W1"]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", parent_issue_id: "P1-I1"),
          issue_record(id: "P1-I3", project_id: "P1", status: "working")
        ],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "working"),
          worker_record(id: "P1-I3-W1", issue_id: "P1-I3", project_id: "P1", status: "working")
        ]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Kill", "target_id" => "P1-I1")

    assert_equal "accepted", result.fetch("status")
    assert_equal "Killed P1-I1.", result.fetch("message")
    state = read_state
    assert_equal ["P1-I3"], ids(state.fetch("issues"))
    assert_equal ["P1-I3-W1"], ids(state.fetch("agents"))
    assert_equal ["P1"], ids(state.fetch("projects"))
    kill_log = state.fetch("logs").find { |log| log.fetch("message") == "Killed P1-I1." }
    assert_equal %w[P1-I1 P1-I2], kill_log.dig("details", "removed_issue_ids").sort
    assert_documented_status_vocabulary(state)
  end

  def test_reconcile_sessions_prunes_leftover_killed_records
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "killed", agent_ids: ["P1-I1-W1"]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working")
        ],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "killed"),
          head_record(id: "H1", status: "killed")
        ]
      )
    )
    engine = build_engine

    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal "accepted", result.fetch("status")
    assert_equal ["P1-I1"], result.dig("result", "pruned_issue_ids")
    assert_equal %w[H1 P1-I1-W1], result.dig("result", "pruned_agent_ids").sort

    state = read_state
    assert_equal ["P1-I2"], ids(state.fetch("issues"))
    assert_empty state.fetch("agents")
    assert_equal ["P1"], ids(state.fetch("projects"))
    # The reconcile prune reports the same consolidated counts as `/prune`, prefixed so the line
    # says which pass removed the records.
    summaries = state.fetch("logs").select { |log| log.fetch("message").start_with?("Pruned killed records:") }
    assert_equal 1, summaries.length
    assert_equal "Pruned killed records: 1 issue, 2 agents, 0 worktrees, and 0 projects.",
                 summaries.first.fetch("message")
  end

  def test_reconcile_sessions_reports_no_pruning_when_nothing_is_killed
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "ReconcileSessions", {})

    assert_empty result.dig("result", "pruned_issue_ids")
    assert_empty result.dig("result", "pruned_agent_ids")
    assert_equal ["P1-I1"], ids(read_state.fetch("issues"))
    refute read_state.fetch("logs").any? { |log| log.fetch("message").start_with?("Pruned killed records:") },
           "a reconcile pass that removed nothing must stay silent"
  end
end
