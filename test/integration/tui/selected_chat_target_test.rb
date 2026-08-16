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
          "H84",
          "status" => "errored",
          "harness_metadata" => { "title" => "Failed head", "error_message" => "fetch failed" }
        ),
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
    assert_includes pane.log_pane_title(composed), "logs — P1-I1-W1"
    assert_includes pane.log_pane_title(composed), "working"
    # The composer title is the one place the target is named: the clicked agent
    # plus its issue's short title. The worker id already contains the durable
    # issue id a fresh head will receive.
    assert_equal "chat → P1-I1-W1 · Fix retries", pane.composer_pane_title(composed)
    # The line below the chat bar carries gestures only, so it does not repeat it.
    hint = plain_line(pane.bottom_hint_line(composed))
    assert_includes hint, "head routes"
    assert_includes hint, "Esc clears"
    refute_includes hint, "P1-I1-W1"
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

  # Regression: submit_prompt used to call empty? on the deliberately nil target
  # for slash commands, so every slash submit raised NoMethodError and took the
  # whole TUI down.
  def test_slash_command_submits_without_a_selection
    submissions, handler = recording_prompt_handler("event" => "slash_command_applied", "command_results" => [])
    composed = compose_app_state(@app, @state, "/prune")

    result = @app.send(:handle_key, "\r", "/prune", 6, -1, handler, composed)

    assert_equal ["", 0, -1], result
    submission = Timeout.timeout(5) { submissions.pop }
    assert_equal "/prune", submission.fetch("text")
    assert_nil submission.fetch("selected_target")
    assert_empty @app.instance_variable_get(:@messages)
  end

  def test_slash_command_submits_while_a_target_is_selected_and_ignores_it
    select_chat_target("P1-I1-W1")
    submissions, handler = recording_prompt_handler("event" => "slash_command_applied", "command_results" => [])
    composed = compose_app_state(@app, @state, "/help")

    assert_equal "P1-I1", Meringue::TUI::LogScope.chat_target(composed).fetch("issue_id")
    # The composer says what routing will actually do: a slash command drops the
    # target tint and says the selection is not targeted.
    pane = Meringue::TUI::Panes::ChatPane.new
    assert_equal "chat · slash command · P1-I1-W1 not targeted", pane.composer_pane_title(composed)
    assert_nil pane.composer_border_style(composed, active: true)

    result = @app.send(:handle_key, "\r", "/help", 5, -1, handler, composed)

    assert_equal ["", 0, -1], result
    submission = Timeout.timeout(5) { submissions.pop }
    assert_equal "/help", submission.fetch("text")
    assert_nil submission.fetch("selected_target")
    # The selection is a chat-routing hint, not a slash-command argument, so it
    # survives the submit untouched.
    assert_equal "P1-I1-W1", Meringue::TUI::LogScope.id(compose_app_state(@app, @state))
  end

  # Locally handled slash commands answer on the calling thread, so they never
  # reach the prompt handler and never consult the selected target at all.
  def test_local_navigation_slash_commands_submit_while_a_target_is_selected
    select_chat_target("P1-I1")
    submissions, handler = recording_prompt_handler

    keybind = @app.send(:handle_key, "\r", "/keybind", 8, -1, handler, compose_app_state(@app, @state, "/keybind"))
    jump = @app.send(:handle_key, "\r", "/jump", 5, -1, handler, compose_app_state(@app, @state, "/jump"))

    assert_equal ["", 0, -1], keybind
    assert_equal ["", 0, -1], jump
    assert_empty submissions
    assert @app.instance_variable_get(:@messages).any? { |message| message.fetch("text", "").include?("Enter") }
    # /jump enters navigation on the already selected row instead of clearing it.
    assert_equal "P1-I1", Meringue::TUI::LogScope.id(compose_app_state(@app, @state))
  end

  def test_plain_prompt_submits_without_a_selection
    submissions, handler = recording_prompt_handler
    composed = compose_app_state(@app, @state, "look at retries")

    assert_nil Meringue::TUI::LogScope.chat_target(composed)

    result = @app.send(:handle_key, "\r", "look at retries", 15, -1, handler, composed)

    assert_equal ["", 0, -1], result
    submission = Timeout.timeout(5) { submissions.pop }
    assert_equal "look at retries", submission.fetch("text")
    assert_nil submission.fetch("selected_target")
  end

  def test_plain_prompt_carries_a_selected_issue_and_stops_after_it_is_cleared
    select_chat_target("P1-I1")
    submissions, handler = recording_prompt_handler
    pane = Meringue::TUI::Panes::ChatPane.new

    typing = compose_app_state(@app, @state, "keep going")
    # A tinted composer and a carried target are the same fact rendered twice.
    assert_equal Meringue::TUI::Style.agent_chrome_style("P1-I1", bold: true), pane.composer_title_style(typing)

    @app.send(:handle_key, "\r", "keep going", 10, -1, handler, typing)
    selected = Timeout.timeout(5) { submissions.pop }
    assert_equal "P1-I1", selected.dig("selected_target", "selected_id")
    assert_equal "issue", selected.dig("selected_target", "selected_type")
    assert_equal "P1-I1", selected.dig("selected_target", "issue_id")

    @app.send(:deselect_agent_tree_item)
    unscoped = compose_app_state(@app, @state, "keep going")
    assert_nil pane.composer_title_style(unscoped)
    assert_equal "chat", pane.composer_pane_title(unscoped)

    @app.send(:handle_key, "\r", "keep going", 10, -1, handler, unscoped)
    cleared = Timeout.timeout(5) { submissions.pop }
    assert_nil cleared.fetch("selected_target")
  end

  # A failed head is retryable, but ordinary chat never targets or messages it. It stays a
  # log-only selection; retry is explicit via /retry or the row's double-click affordance.
  def test_selecting_a_failed_head_is_log_only_not_chat_retry
    select_chat_target("H84")
    composed = compose_app_state(@app, @state, "try again")

    assert_nil Meringue::TUI::LogScope.chat_target(composed)

    pane = Meringue::TUI::Panes::ChatPane.new
    assert_equal "chat · head routes · H84 logs only", pane.composer_pane_title(composed)
    assert_nil pane.composer_title_style(composed)
    assert_includes plain_line(pane.bottom_hint_line(composed)), "head routes"
    assert_equal "enter a prompt", Meringue::TUI::ChatTarget.placeholder(composed)

    submissions, handler = recording_prompt_handler
    @app.send(:handle_key, "\r", "try again", 9, -1, handler, composed)
    submission = Timeout.timeout(5) { submissions.pop }

    assert_equal "try again", submission.fetch("text")
    assert_nil submission.fetch("selected_target")
  end

  # A selection on a project or a head that is still routing filters logs but
  # resolves to no issue and nothing to retry, so chat has to fall back to
  # unscoped routing instead of shipping a half-populated target.
  def test_project_and_unbound_head_selections_do_not_target_chat
    select_chat_target("P1")
    assert_nil Meringue::TUI::LogScope.chat_target(compose_app_state(@app, @state))

    select_chat_target("H83")
    composed = compose_app_state(@app, @state, "keep going")
    assert_nil Meringue::TUI::LogScope.chat_target(composed)

    submissions, handler = recording_prompt_handler
    @app.send(:handle_key, "\r", "keep going", 10, -1, handler, composed)

    assert_nil Timeout.timeout(5) { submissions.pop }.fetch("selected_target")
  end

  # Embedders that predate selected-target routing still pass a one-argument
  # prompt handler. A selection must not turn their next prompt into an
  # ArgumentError.
  def test_legacy_single_argument_prompt_handler_still_receives_selected_prompts
    select_chat_target("P1-I1-W1")
    submissions = Queue.new
    handler = lambda do |text|
      submissions << text
      { "summary" => "routed", "spawn_head_result" => { "status" => "accepted", "log_entry_ids" => ["L1"] } }
    end

    @app.send(:handle_key, "\r", "keep going", 10, -1, handler, compose_app_state(@app, @state, "keep going"))

    assert_equal "keep going", Timeout.timeout(5) { submissions.pop }
    messages = @app.instance_variable_get(:@messages)
    refute messages.any? { |message| message.fetch("text", "").include?("ArgumentError") }
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

  private

  # Click a row, then move focus back to the composer. Jump mode swallows Enter
  # while it is active, so this is the state a user types their next prompt in:
  # the sticky selected target outlives jump mode.
  def select_chat_target(item_id)
    assert @app.send(:select_agent_tree_item, @state, item_id)
    @app.send(:exit_agent_tree_navigation)
  end

  # Prompt handler shaped like Heads::PromptLoop#call: it accepts the optional
  # selected_target keyword and records exactly what the TUI handed it.
  def recording_prompt_handler(result = nil)
    submissions = Queue.new
    handler = lambda do |text, selected_target: nil, &_on_event|
      submissions << { "text" => text, "selected_target" => selected_target }
      result || {
        "summary" => "routed",
        "spawn_head_result" => { "status" => "accepted", "log_entry_ids" => ["L1"] }
      }
    end
    [submissions, handler]
  end
end
