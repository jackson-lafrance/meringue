# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# A worker whose turn died mid-flight must read as "this died", not as "this finished".
# The kernel records the reason on the record; these are the two places the user looks.
class TuiSettleFailurePresentationTest < Minitest::Test
  include TUISupport

  TreePane = Meringue::TUI::Panes::AgentTreePane
  WorkspacePane = Meringue::TUI::Panes::AgentWorkspacePane
  Style = Meringue::TUI::Style

  SETTLE_FAILURE = {
    "kind" => "network_failure",
    "reason" => "its model request failed mid-turn (network error: Connection error.)",
    "source" => "harness_turn_outcome",
    "stop_reason" => "error",
    "error_message" => "Connection error."
  }.freeze

  def aborted_worker(overrides = {})
    agent_record(
      "P1-I1-W1",
      {
        "issue_id" => "P1-I1",
        "project_id" => "P1",
        "status" => "errored",
        "workspace_path" => "/tmp/meringue-workspace",
        "harness_metadata" => {
          "title" => "Fix prune retention",
          "settle_state" => "failed",
          "settle_failure" => SETTLE_FAILURE,
          "status_reason" => "errored without finishing: #{SETTLE_FAILURE.fetch("reason")}"
        }
      }.merge(stringify(overrides))
    )
  end

  def tree_with(worker)
    tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "status" => "errored", "agent_ids" => [worker.fetch("id")])],
      agents: [worker]
    )
  end

  def worker_row(worker, width: 60)
    plain_lines(TreePane.new.lines(tree_with(worker), width: width)).find { |row| row.include?("W1") }
  end

  def test_the_agent_tree_marks_a_worker_that_stopped_when_the_connection_dropped
    row = worker_row(aborted_worker)

    refute_nil row
    assert_includes row, TreePane::STATUS_DOTS.fetch("errored")
    assert_includes row, "stopped: connection lost"
  end

  def test_a_non_network_dead_turn_still_says_the_worker_stopped_mid_turn
    worker = aborted_worker
    worker["harness_metadata"] = worker.fetch("harness_metadata").merge(
      "settle_failure" => SETTLE_FAILURE.merge("kind" => "provider_error")
    )

    rendered = plain_lines(TreePane.new.lines(tree_with(worker), width: 60)).join("\n")

    assert_includes rendered, "stopped mid-turn"
  end

  # A session the provider refuses to replay is not something a prompt picks up where it left off,
  # so the row must not read like the resumable case.
  def test_a_worker_whose_session_cannot_be_replayed_says_the_session_is_unusable
    worker = aborted_worker
    worker["harness_metadata"] = worker.fetch("harness_metadata").merge(
      "settle_failure" => SETTLE_FAILURE.merge("kind" => "unreplayable_session"),
      "status_reason" => "errored without finishing: its saved session can no longer be replayed to the model. " \
                         "Its worktree and branch meringue/fix-prune-retention still hold the work, so Meringue " \
                         "does not resume this session: continuing means a fresh session on the same workspace."
    )

    rendered = plain_lines(TreePane.new.lines(tree_with(worker), width: 60)).join("\n")

    assert_includes rendered, "stopped: session unusable"
    refute_includes rendered, "stopped mid-turn"

    state = composed_state(
      tree_with(worker),
      workspace: { "agent_id" => worker.fetch("id"), "view" => "agent", "filter" => "all", "content_revision" => 1 }
    )
    focused = plain_lines(WorkspacePane.new.content_lines(state, width: 100)).join("\n")

    assert_includes focused, "can no longer be replayed"
    assert_includes focused, "fresh session on the same workspace"
  end

  def test_a_completed_worker_gets_no_stopped_marker
    worker = agent_record(
      "P1-I1-W1",
      "issue_id" => "P1-I1",
      "project_id" => "P1",
      "status" => "completed",
      "harness_metadata" => { "title" => "Fix prune retention", "completed_at" => "2026-07-11T00:00:00Z" }
    )

    row = worker_row(worker)

    refute_nil row
    assert_includes row, TreePane::STATUS_DOTS.fetch("completed")
    refute_includes row, "stopped"
  end

  def test_the_focused_workspace_pane_shows_why_the_worker_stopped
    worker = aborted_worker
    state = composed_state(
      tree_with(worker),
      workspace: { "agent_id" => worker.fetch("id"), "view" => "agent", "filter" => "all", "content_revision" => 1 }
    )

    lines = WorkspacePane.new.content_lines(state, width: 70)
    rendered = plain_lines(lines)
    reason_row = lines.find { |line| plain_line(line).include?("errored without finishing") }

    assert_includes rendered.join("\n"), "P1-I1-W1 · errored"
    refute_nil reason_row, "the focused pane must explain the errored status"
    assert_includes plain_line(reason_row), "network error: Connection error."
    assert_includes styles_in(reason_row), Style::ERROR
  end

  def test_the_focused_workspace_pane_stays_unchanged_for_a_healthy_worker
    worker = agent_record(
      "P1-I1-W1",
      "issue_id" => "P1-I1",
      "project_id" => "P1",
      "status" => "working",
      "harness_metadata" => { "title" => "Fix prune retention" }
    )
    state = composed_state(
      tree_with(worker),
      workspace: { "agent_id" => worker.fetch("id"), "view" => "agent", "filter" => "all", "content_revision" => 1 }
    )

    rendered = plain_lines(WorkspacePane.new.content_lines(state, width: 70)).join("\n")

    refute_includes rendered, "status "
  end
end
