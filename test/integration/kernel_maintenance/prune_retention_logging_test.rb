# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# One prune pass is one visible line, even when it has to preserve several managed worktrees.
#
# Regression coverage for a pass that reported the same three retentions five times: one
# "could not be removed" warning per worker, the pass summary naming all three, and a trailing
# post-prune line that re-rendered the retention with a *different* reason
# (`cleanup_blocked_missing_path`) invented by the retry when the blocked outcome had no git root
# to retry with. The retention is now rendered once, in the pass summary, with the real reason.
class KernelMaintenancePruneRetentionLoggingTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def write_unverifiable_workspace_state(count)
    workspaces = (1..count).map do |index|
      path = make_dir("workspaces", "acme", "unverified-#{index}")
      File.write(File.join(path, "NOTES.md"), "worker output\n")
      path
    end
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: (1..count).map do |index|
          issue_record(id: "P1-I#{index}", project_id: "P1", status: "completed", agent_ids: ["P1-I#{index}-W1"])
        end,
        agents: (1..count).map do |index|
          worker_record(
            id: "P1-I#{index}-W1",
            issue_id: "P1-I#{index}",
            project_id: "P1",
            status: "completed",
            workspace_path: workspaces[index - 1]
          )
        end
      )
    )
    workspaces
  end

  def test_prune_reports_several_retained_worktrees_in_one_summary_entry
    workspaces = write_unverifiable_workspace_state(3)

    result = apply_command(build_engine, "Prune")

    assert_equal "Pruned 3 issues, 3 agents, 0 worktrees, and 0 projects. " \
                 "Preserved 3 managed worktrees because cleanup was not safe: " \
                 "P1-I1-W1 (branch_not_delivery_managed), P1-I2-W1 (branch_not_delivery_managed), " \
                 "P1-I3-W1 (branch_not_delivery_managed).", result.fetch("message")

    logs = read_state.fetch("logs")
    assert_equal 1, logs.length, "three retained worktrees must not cost four log entries"
    summary = logs.first
    assert_equal "warning", summary.fetch("level"), "cleanup failures stay at warning"
    assert_nil summary.fetch("source_id", nil), "the pass owns the line, not any single worker"
    assert_equal "prune_result", summary.dig("details", "kind")
    assert_empty logs.select { |log| log.fetch("message").include?("could not be removed") }
    assert_empty logs.select { |log| log.dig("details", "kind") == "post_prune_cleanup" }

    # The per-worker detail is still there, in the summary entry's structured details.
    outcomes = summary.dig("details", "workspace_cleanup_outcomes")
    assert_equal %w[P1-I1-W1 P1-I2-W1 P1-I3-W1], outcomes.map { |outcome| outcome.fetch("agent_id") }
    assert(outcomes.all? { |outcome| outcome.fetch("reason") == "branch_not_delivery_managed" },
           "one accurate reason per worktree, in the outcome the pass recorded")
    assert_equal %w[P1-I1-W1 P1-I2-W1 P1-I3-W1], summary.dig("details", "workspace_cleanup_blocked_agent_ids")
    workspaces.each { |path| assert Dir.exist?(path), "an unverifiable workspace must be preserved" }
  end

  # The retry cannot even attempt a worktree whose blocked outcome has no git root - the manager
  # refuses `branch_not_delivery_managed` before it resolves one. That is a property of the retry
  # input, so it must not overwrite the reason the pass reported.
  def test_post_prune_retry_keeps_the_reason_the_pass_reported
    write_unverifiable_workspace_state(1)

    result = apply_command(build_engine, "Prune")

    retained = result.dig("result", "post_prune_cleanup", "summary", "retained").first
    assert_equal "P1-I1-W1", retained.fetch("agent_id")
    assert_equal "branch_not_delivery_managed", retained.fetch("reason")
    assert_equal "branch_not_delivery_managed", retained.fetch("original_reason")
    outcome = result.dig("result", "post_prune_cleanup", "outcomes").first
    assert_equal "incomplete_workspace_identity", outcome.fetch("retry_skipped")
    refute outcome.fetch("attempted")

    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects. Preserved 1 managed worktree " \
                 "because cleanup was not safe: P1-I1-W1 (branch_not_delivery_managed).", result.fetch("message")
    refute_includes result.fetch("message"), "cleanup_blocked_missing_path"
    logs = read_state.fetch("logs")
    assert_equal 1, logs.length, "a retry that recovered nothing adds no second line"
  end

  # A pass with nothing to preserve keeps its single info line.
  def test_prune_without_retention_stays_one_info_line
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: ["P1-I1-W1"])],
        agents: [worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "completed")]
      )
    )

    result = apply_command(build_engine, "Prune")

    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects.", result.fetch("message")
    logs = read_state.fetch("logs")
    assert_equal 1, logs.length
    assert_equal "info", logs.first.fetch("level")
  end
end
