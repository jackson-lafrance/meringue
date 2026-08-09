# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "timeout"

# What the user sees for a head that stopped without routing its request.
#
# A `blocked` head is the common stranded case: the kernel applied its batch, rejected or failed
# part of it, and the request inside it went nowhere. Those heads sit in the AgentTree, so every
# presentation layer has to agree that retry is a deliberate visible action (`/retry` or
# double-click), while ordinary selection only filters logs.
class TuiBlockedHeadRecoveryTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::AgentTreePane
  WIDTH = 100
  HEIGHT = 32

  class RecordingSessionOpener
    attr_reader :opened

    def initialize
      @opened = []
    end

    def open(agent)
      @opened << agent.fetch("id")
      { "status" => "opened", "message" => "Opened #{agent.fetch("id")}." }
    end
  end

  def setup
    @pane = Pane.new
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(layout: @layout, out: StringIO.new, terminal: TUISupport::FakeTerminal.new)
  end

  def test_a_blocked_head_row_shows_the_retry_affordance
    rendered = plain_lines(@pane.lines(tree_state(agents: [blocked_head("H26")]), width: 60))

    assert_includes rendered, "  └─ ! H26  Fix the slow query retry me"
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
    refute_includes rendered.join("\n"), "retry me"
  end

  # Selecting the row filters logs only. It must not turn the next typed message into a head
  # prompt or retry; retry stays explicit.
  def test_selecting_a_blocked_head_is_log_only
    state = selected_tree_state("H26", blocked_head("H26"))

    assert_nil Meringue::TUI::LogScope.chat_target(state)

    pane = Meringue::TUI::Panes::ChatPane.new
    assert_equal "chat · head routes · H26 logs only", pane.composer_pane_title(state)
    assert_equal "enter a prompt", Meringue::TUI::ChatTarget.placeholder(state)
    assert_includes plain_line(pane.bottom_hint_line(state)), "head routes"
  end

  # `/retry` is the explicit command entry point, so its completion offers blocked heads while
  # `/prompt` remains worker-only.
  def test_retry_completion_offers_a_blocked_head_and_prompt_does_not
    state = { "agents" => [blocked_head("H26")] }

    retry_records = Meringue::Input::SlashCommandParser.command_suggestion_records("/retry ", limit: 5, state: state)
    assert_equal ["H26"], retry_records.map { |record| record.fetch("usage") }
    assert_includes retry_records.first.fetch("description"), "retry"

    prompt = Meringue::Input::SlashCommandParser.command_suggestion_records("/prompt ", limit: 5, state: state)
    assert_empty prompt
  end

  def test_double_clicking_a_retryable_head_submits_retry_command
    state = tree_state(agents: [blocked_head("H26")])
    submissions = Queue.new
    handler = lambda do |text, **_kwargs|
      submissions << text
      { "event" => "slash_command_applied", "command_results" => [] }
    end

    send_left_click(state, "H26")
    send_left_click(state, "H26", handler: handler)

    assert_equal "/retry H26", Timeout.timeout(5) { submissions.pop }
  end

  def test_open_session_command_can_open_a_head_session_for_debugging
    opener = RecordingSessionOpener.new
    app = Meringue::TUI::App.new(layout: @layout, out: StringIO.new, terminal: TUISupport::FakeTerminal.new, session_opener: opener)
    state = tree_state(agents: [blocked_head("H26")])

    result = app.send(:handle_key, "\r", "/open-session H26", "/open-session H26".length, -1, nil, state)

    assert_equal ["", 0, -1], result
    assert_equal ["H26"], opener.opened
  end

  private

  def send_left_click(state, item_id, handler: nil)
    position = screen_position_for_item(state, item_id)
    key = {
      "type" => "mouse",
      "kind" => "button",
      "pressed" => true,
      "button" => 0,
      "x" => position.fetch("x"),
      "y" => position.fetch("y")
    }
    @app.send(:handle_key, key, "", 0, -1, handler, state)
  end

  def screen_position_for_item(state, item_id)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        next unless @layout.agent_tree_item_at(state, width: WIDTH, height: HEIGHT, x: x, y: y) == item_id

        return { "x" => x + 1, "y" => y + 1 }
      end
    end

    flunk "no screen position maps to AgentTree item #{item_id}"
  end

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
