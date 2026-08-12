# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Normal test coverage for AgentTree-scoped log filtering and chat-target snapshots.
class TuiLogScopeTest < Minitest::Test
  include TUISupport

  LogScope = Meringue::TUI::LogScope

  def test_issue_scope_includes_child_issue_subtree_and_workers
    scope = LogScope.snapshot(scoped_tree_state, "P1-I1")
    entries = [
      log_record("L1", "source_id" => "P1-I1"),
      log_record("L2", "source_id" => "P1-I1-W1"),
      log_record("L3", "source_id" => "P1-I2-W1"),
      log_record("L4", "details" => { "issue_id" => "P1-I2" }),
      log_record("L5", "details" => { "agent_ids" => ["P1-I2-W1", "P9-I9-W9"] }),
      log_record("L6", "source_id" => "P1-I3-W1"),
      log_record("L7", "details" => { "project_id" => "P1" }),
      log_record("L8", "source_id" => "H1")
    ]

    assert_equal %w[P1-I1 P1-I2 P1-I1-W1 P1-I2-W1], scope.fetch("member_ids")
    assert_equal %w[L1 L2 L3 L4 L5], LogScope.filter(scope, entries).map { |entry| entry.fetch("id") }
  end

  def test_project_scope_includes_project_tree_without_top_level_heads
    scope = LogScope.snapshot(scoped_tree_state, "P1")
    entries = [
      log_record("L1", "source_id" => "P1"),
      log_record("L2", "source_id" => "P1-I1-W1"),
      log_record("L3", "details" => { "project_id" => "P1" }),
      log_record("L4", "details" => { "removed_issue_ids" => ["P1-I1", "P2-I1"] }),
      log_record("L5", "source_id" => "H1"),
      log_record("L6", "details" => { "head_id" => "H1" }),
      log_record("L7", "source_id" => "P2-I1-W1")
    ]

    assert_equal %w[P1 P1-I1 P1-I2 P1-I3 P1-I1-W1 P1-I2-W1 P1-I3-W1], scope.fetch("member_ids")
    assert_equal %w[L1 L2 L3 L4], LogScope.filter(scope, entries).map { |entry| entry.fetch("id") }
  end

  def test_head_scope_includes_its_prompt_and_own_logs_only
    scope = LogScope.snapshot(scoped_tree_state, "H1")
    entries = [
      log_record("L1", "source_type" => "user", "source_id" => nil, "details" => { "head_id" => "H1" }),
      log_record("L2", "source_type" => "head", "source_id" => "H1"),
      log_record("L3", "source_type" => "kernel", "source_id" => nil, "details" => { "project_id" => "P1" }),
      log_record("L4", "source_type" => "head", "source_id" => "H2"),
      log_record("L5", "source_type" => "kernel", "source_id" => "P1-I1",
                       "details" => { "command_author_type" => "head", "command_author_id" => "H1" })
    ]

    assert_equal ["H1"], scope.fetch("member_ids")
    assert_equal %w[L1 L2 L5], LogScope.filter(scope, entries).map { |entry| entry.fetch("id") }
  end

  def test_routed_user_prompt_is_retained_by_issue_and_worker_scopes
    state = scoped_tree_state
    routed_prompt = log_record(
      "L1",
      "source_type" => "user",
      "source_id" => nil,
      "message" => "Fix the retry race",
      "details" => {
        "head_id" => "H9",
        "routed_issue_ids" => ["P1-I1"],
        "routed_agent_ids" => ["P1-I1-W1"]
      }
    )
    unrelated_prompt = log_record(
      "L2",
      "source_type" => "user",
      "source_id" => nil,
      "message" => "Clean up the sibling",
      "details" => { "head_id" => "H10", "routed_issue_ids" => ["P1-I3"] }
    )
    entries = [routed_prompt, unrelated_prompt]

    assert_equal [routed_prompt], LogScope.filter(LogScope.snapshot(state, "P1-I1"), entries)
    assert_equal [routed_prompt], LogScope.filter(LogScope.snapshot(state, "P1-I1-W1"), entries)
    assert_equal [unrelated_prompt], LogScope.filter(LogScope.snapshot(state, "P1-I3"), entries)
  end

  def test_worker_issue_project_and_unbound_head_chat_targets
    state = scoped_tree_state

    worker_target = LogScope.snapshot(state, "P1-I1-W1").fetch("selected_target")
    assert_equal "agent", worker_target.fetch("selected_type")
    assert_equal "P1-I1-W1", worker_target.fetch("selected_agent_id")
    assert_equal "P1-I1", worker_target.fetch("issue_id")
    assert_equal "Parent goal", worker_target.fetch("issue_title")

    issue_target = LogScope.snapshot(state, "P1-I1").fetch("selected_target")
    assert_equal "issue", issue_target.fetch("selected_type")
    assert_equal "P1-I1", issue_target.fetch("issue_id")
    refute issue_target.key?("selected_agent_id")

    refute LogScope.snapshot(state, "P1").key?("selected_target")
    refute LogScope.snapshot(state, "H1").key?("selected_target")
  end

  def test_missing_or_empty_scope_leaves_entries_unfiltered
    entries = [log_record("L1"), log_record("L2")]

    assert_equal({}, LogScope.snapshot(scoped_tree_state, "P9-I9"))
    assert_equal entries, LogScope.filter({}, entries)
    assert_equal entries, LogScope.filter(nil, entries)
  end

  private

  def scoped_tree_state
    composed_state(
      empty_state.merge(
        "projects" => [project_record("P1"), project_record("P2")],
        "issues" => [
          issue_record("P1-I1", "title" => "Parent goal"),
          issue_record("P1-I2", "parent_issue_id" => "P1-I1", "title" => "Child goal"),
          issue_record("P1-I3", "title" => "Sibling goal"),
          issue_record("P2-I1", "title" => "Other project goal")
        ],
        "agents" => [
          agent_record("H1", "harness_metadata" => { "title" => "Unbound head" }),
          agent_record("H2", "issue_id" => "P1-I1", "project_id" => "P1", "harness_metadata" => { "title" => "Bound head" }),
          agent_record("P1-I1-W1", "issue_id" => "P1-I1", "project_id" => "P1", "harness_metadata" => { "title" => "Parent worker" }),
          agent_record("P1-I2-W1", "issue_id" => "P1-I2", "project_id" => "P1", "harness_metadata" => { "title" => "Child worker" }),
          agent_record("P1-I3-W1", "issue_id" => "P1-I3", "project_id" => "P1", "harness_metadata" => { "title" => "Sibling worker" }),
          agent_record("P2-I1-W1", "issue_id" => "P2-I1", "project_id" => "P2", "harness_metadata" => { "title" => "Other worker" })
        ]
      )
    )
  end
end
