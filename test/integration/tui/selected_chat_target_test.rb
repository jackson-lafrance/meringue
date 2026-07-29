# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "timeout"

class TuiSelectedChatTargetTest < Minitest::Test
  include TUISupport

  class RecordingLogStore
    attr_reader :log_buffer_writes

    def initialize
      @log_buffer_writes = []
    end

    def save_log_buffer(messages:, next_message_id:)
      @log_buffer_writes << { "messages" => messages, "next_message_id" => next_message_id }
    end
  end

  class FailingWorkspaceController
    def open_workspace(agent:, state:)
      _ = [agent, state]
      raise "workspace transport failed"
    end
  end

  def setup
    @state = empty_state.merge(
      "projects" => [project_record("P1")],
      "issues" => [issue_record("P1-I1", "title" => "Fix retries", "agent_ids" => ["P1-I1-W1"])],
      "agents" => [
        agent_record("H83", "harness_metadata" => { "title" => "Pending head", "head_session_state" => "pending" }),
        agent_record(
          "P1-I1-W1",
          "project_id" => "P1",
          "issue_id" => "P1-I1",
          "harness_metadata" => { "title" => "Inspect retries" }
        )
      ]
    )
    @app = build_app
  end

  def test_worker_selection_focuses_its_logs_and_resolves_chat_to_the_owning_issue
    assert @app.send(:select_agent_tree_item, @state, "P1-I1-W1")
    composed = compose_app_state(@app, @state)
    target = Meringue::TUI::LogScope.selected_target(composed)

    assert_equal "P1-I1-W1", Meringue::TUI::LogScope.id(composed)
    assert_equal "agent", target.fetch("selected_type")
    assert_equal "P1-I1-W1", target.fetch("selected_agent_id")
    assert_equal "P1-I1", target.fetch("issue_id")

    pane = Meringue::TUI::Panes::ChatPane.new
    assert_equal "logs — P1-I1-W1", pane.log_pane_title(composed)
    assert_equal "chat → P1-I1", pane.composer_pane_title(composed)
    hint = plain_line(pane.bottom_hint_line(composed))
    assert_includes hint, "target: P1-I1 via P1-I1-W1"
    assert_includes hint, "head routes"
    assert_includes hint, "Esc clears"
  end

  def test_issue_selection_targets_the_issue_directly_and_can_be_changed_or_cleared
    @app.send(:select_agent_tree_item, @state, "P1-I1-W1")
    @app.send(:select_agent_tree_item, @state, "P1-I1")

    selected = compose_app_state(@app, @state)
    target = Meringue::TUI::LogScope.selected_target(selected)
    assert_equal "P1-I1", Meringue::TUI::LogScope.id(selected)
    assert_equal "issue", target.fetch("selected_type")
    assert_equal "P1-I1", target.fetch("issue_id")
    refute target.key?("selected_agent_id")

    @app.send(:deselect_agent_tree_item)
    cleared = compose_app_state(@app, @state)
    assert_empty Meringue::TUI::LogScope.selected_target(cleared)
    assert_equal "chat", Meringue::TUI::Panes::ChatPane.new.composer_pane_title(cleared)
  end

  def test_subsequent_chat_passes_the_selection_to_the_head_callback
    @app.send(:select_agent_tree_item, @state, "P1-I1-W1")
    # Clicking into the composer exits jump mode but deliberately keeps the
    # sticky selected target.
    @app.send(:exit_agent_tree_navigation)
    composed = compose_app_state(@app, @state, "also check timeouts")
    submissions = Queue.new
    handler = lambda do |text, selected_target: nil|
      submissions << { "text" => text, "selected_target" => selected_target }
      {
        "summary" => "routed",
        "spawn_head_result" => { "status" => "accepted", "log_entry_ids" => ["L1"] }
      }
    end

    result = @app.send(:handle_key, "\r", "also check timeouts", 19, -1, handler, composed)

    assert_equal ["", 0, -1], result
    submission = Timeout.timeout(5) { submissions.pop }
    assert_equal "also check timeouts", submission.fetch("text")
    assert_equal "P1-I1-W1", submission.dig("selected_target", "selected_id")
    assert_equal "P1-I1", submission.dig("selected_target", "issue_id")
  end

  def test_selected_user_prompt_is_visible_in_the_focused_worker_logs
    @state["logs"] = [
      log_record(
        "L1",
        "source_type" => "user",
        "message" => "also check timeouts",
        "details" => {
          "head_id" => "H84",
          "selected_target_id" => "P1-I1-W1",
          "issue_id" => "P1-I1",
          "agent_id" => "P1-I1-W1",
          "routing_action" => "selected_target"
        }
      )
    ]
    @app.send(:select_agent_tree_item, @state, "P1-I1-W1")

    lines = plain_lines(Meringue::TUI::Panes::ChatPane.new.log_lines(compose_app_state(@app, @state), width: 70))

    assert_includes lines.join("\n"), "also check timeouts"
  end

  def test_repeated_clicks_on_a_pending_head_do_not_show_or_persist_unavailable_messages
    store = RecordingLogStore.new
    app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new,
      log_store: store
    )
    click = { "x" => 3, "y" => 3 }

    6.times { app.send(:handle_agent_tree_item_click, "H83", click, @state) }
    3.times { refute app.send(:open_agent_workspace_by_id, @state, "H83") }

    assert_empty app.instance_variable_get(:@messages)
    assert_empty store.log_buffer_writes
    refute app.instance_variable_get(:@agent_workspace_active)
  end

  def test_real_workspace_open_errors_are_still_reported
    store = RecordingLogStore.new
    app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new,
      log_store: store,
      workspace_controller: FailingWorkspaceController.new
    )

    refute app.send(:open_agent_workspace_by_id, @state, "P1-I1-W1")

    messages = app.instance_variable_get(:@messages)
    assert_equal 1, messages.length
    assert_includes messages.first.fetch("text"), "Could not open focused workspace for P1-I1-W1"
    assert_includes messages.first.fetch("text"), "workspace transport failed"
    assert_equal 1, store.log_buffer_writes.length
  end
end
