# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# What the user sees for a head that stopped without routing its request.
#
# A `blocked` head is the common stranded case: the kernel applied its batch, rejected or failed
# part of it, and the request inside it went nowhere. Those heads sit in the AgentTree, so every
# presentation layer has to agree that selecting one and typing re-runs the request, rather than
# leaving the row looking like dead state whose only affordance is /kill.
class TuiBlockedHeadRecoveryTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::AgentTreePane

  def setup
    @pane = Pane.new
  end

  def test_a_blocked_head_row_says_it_can_be_reprompted
    rendered = plain_lines(@pane.lines(tree_state(agents: [blocked_head("H26")]), width: 60))

    assert_includes rendered, "  └─ ! H26  Fix the slow query prompt to retry"
  end

  # Once a head has been retried, the successor is the more useful fact on the row: the user needs
  # to know their request is running again rather than being invited to retry it a second time.
  def test_a_retried_head_row_names_its_successor
    head = blocked_head("H26")
    head.fetch("harness_metadata")["retried_by_head_id"] = "H41"

    rendered = plain_lines(@pane.lines(tree_state(agents: [head]), width: 60))

    assert_includes rendered, "  └─ ! H26  Fix the slow query retried as H41"
  end

  # A head that routed every command it proposed is finished, not stranded, so it must not
  # advertise a retry.
  def test_a_fully_routed_head_row_offers_no_retry
    head = blocked_head("H26", status: "completed")
    head.fetch("harness_metadata")["head_result_command_journal"] = [
      { "command_id" => "H26-C1", "command_type" => "CreateIssue", "status" => "accepted", "target_id" => "P4-I2" }
    ]

    rendered = plain_lines(@pane.lines(tree_state(agents: [head]), width: 60))

    assert_includes rendered, "  └─ ✓ H26  Fix the slow query"
    refute_includes rendered.join("\n"), "prompt to retry"
  end

  # Selecting the row has to resolve to a head chat target, which is what makes the next typed
  # message a retry instead of an unrelated new request.
  def test_selecting_a_blocked_head_targets_chat_at_a_retry
    state = selected_tree_state("H26", blocked_head("H26"))
    target = Meringue::TUI::LogScope.chat_target(state)

    refute_nil target, "a blocked head must be a chat target, not a log-only filter"
    assert_equal "H26", target.fetch("selected_id")
    assert_equal "head", target.fetch("selected_type")
    assert_equal "blocked", target.fetch("selected_head_status")

    pane = Meringue::TUI::Panes::ChatPane.new
    assert_equal "chat → retry H26 · blocked", pane.composer_pane_title(state)
    assert_equal "retry H26", Meringue::TUI::ChatTarget.placeholder(state)
    assert_includes plain_line(pane.bottom_hint_line(state)), "retries this head"
  end

  # `/prompt` is the explicit entry point for the same recovery, so its completion has to offer
  # blocked heads too.
  def test_prompt_completion_offers_a_blocked_head
    state = { "agents" => [blocked_head("H26")] }

    records = Meringue::Input::SlashCommandParser.command_suggestion_records("/prompt ", limit: 5, state: state)

    assert_equal ["H26"], records.map { |record| record.fetch("usage") }
    assert_includes records.first.fetch("description"), "retry"
  end

  private

  # The AgentTree selection as the App composes it for a frame: the sticky log scope the kernel
  # snapshot is resolved against.
  def selected_tree_state(selected_id, *agents)
    state = tree_state(agents: agents, selected_agent_id: selected_id)
    state[Meringue::TUI::LogScope::STATE_KEY] = Meringue::TUI::LogScope.snapshot(state, selected_id)
    state
  end

  # A head whose applied batch left commands unrouted: exactly what the kernel writes when it
  # rejects or fails part of a head result.
  def blocked_head(id, status: "blocked")
    agent_record(
      id,
      "status" => status,
      "harness_metadata" => {
        "title" => "Fix the slow query",
        "head_result_applied_at" => "2026-08-05T12:59:56Z",
        "head_result_apply_state" => "partially_applied",
        "head_result_command_journal" => [
          { "command_id" => "H26-C1", "command_type" => "CreateIssue", "status" => "accepted", "target_id" => "P4-I2" },
          { "command_id" => "H26-C2", "command_type" => "SpawnWorker", "status" => "failed", "errors" => ["git worktree add timed out"] }
        ]
      }
    )
  end
end
