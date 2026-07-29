# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Prune with the errored selector, plus the killed-record reconciliation prune
# that runs inside ReconcileSessions.
class KernelMaintenancePruneErroredTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_errored_selector_removes_errored_issue_bundles_and_standalone_errored_heads
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

    result = apply_command(engine, "Prune", "selector" => "errored")

    assert_equal "accepted", result.fetch("status")
    assert_equal "Pruned 1 errored issue bundle and 1 standalone errored agent.", result.fetch("message")
    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["H1"], result.dig("result", "removed_standalone_agent_ids")
    assert_equal "errored", result.dig("result", "reason")

    state = read_state
    assert_equal ["P1-I2"], ids(state.fetch("issues"))
    assert_equal ["H2"], ids(state.fetch("agents"))
    log = state.fetch("logs").last
    assert_equal "Pruned 1 errored issue bundle and 1 standalone errored agent.", log.fetch("message")
    assert_equal "errored", log.dig("details", "selector")
    assert_documented_status_vocabulary(state)
  end

  def test_errored_issue_with_live_worker_is_retained
    %w[queued working idle blocked].each do |worker_status|
      write_state(
        state_fixture(
          projects: [project_record(id: "P1", status: "working")],
          issues: [issue_record(id: "P1-I1", project_id: "P1", status: "errored", agent_ids: ["P1-I1-W1"])],
          agents: [worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: worker_status)]
        )
      )
      engine = build_engine

      result = apply_command(engine, "Prune", "selector" => "errored")

      assert_empty result.dig("result", "removed_issue_ids"),
                   "errored issue with a #{worker_status} worker must be retained"
      assert_equal ["P1-I1"], ids(read_state.fetch("issues"))
    end
  end

  def test_errored_selector_ignores_completed_issues_and_healthy_heads
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed")],
        agents: [head_record(id: "H1", status: "working")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "errored")

    assert_equal "Pruned 0 errored issue bundles and 0 standalone errored agents.", result.fetch("message")
    state = read_state
    assert_equal ["P1-I1"], ids(state.fetch("issues"))
    assert_equal ["H1"], ids(state.fetch("agents"))
  end

  def test_errored_prune_removes_the_project_when_every_issue_is_removed
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "errored")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "errored")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "errored")

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
  end
end
