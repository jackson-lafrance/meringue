require "test_helper"

class HumanInputDetectionTest < Minitest::Test
  def test_detects_extension_input_request
    request = Meringue::Harness::HumanInput.requests([
      { "type" => "extension_ui_request", "requestType" => "input", "question" => "Choose a target" }
    ]).first

    assert_equal "extension_ui_request", request.fetch("source")
    assert_equal "Choose a target", request.fetch("message")
    assert_equal "input", request.fetch("request_type")
  end

  def test_detects_every_pi_dialog_method
    requests = Meringue::Harness::HumanInput.requests([
      { "type" => "extension_ui_request", "id" => "1", "method" => "select", "title" => "Allow dangerous command?", "options" => %w[Allow Block] },
      { "type" => "extension_ui_request", "id" => "2", "method" => "confirm", "title" => "Continue?", "message" => "Really?" },
      { "type" => "extension_ui_request", "id" => "3", "method" => "input", "title" => "Name" },
      { "type" => "extension_ui_request", "id" => "4", "method" => "editor", "title" => "Edit" }
    ])

    assert_equal %w[Allow\ dangerous\ command? Really? Name Edit], requests.map { |request| request.fetch("message") }
    assert_equal %w[select confirm input editor], requests.map { |request| request.dig("details", "method") }
  end

  # Pi emits every `ctx.ui.*` call as an `extension_ui_request`. A status-bar extension calling
  # `setWidget` on each turn used to mark every head and worker as blocked on human input.
  def test_ignores_fire_and_forget_extension_ui_requests
    assert_empty Meringue::Harness::HumanInput.requests([
      { "type" => "extension_ui_request", "id" => "1", "method" => "setWidget", "widgetKey" => "pi.precognition",
        "widgetLines" => ["precog · watching · silent"], "widgetPlacement" => "aboveEditor" },
      { "type" => "extension_ui_request", "id" => "2", "method" => "setStatus", "statusKey" => "x", "statusText" => "busy" },
      { "type" => "extension_ui_request", "id" => "3", "method" => "notify", "message" => "Done", "notifyType" => "info" },
      { "type" => "extension_ui_request", "id" => "4", "method" => "setTitle", "title" => "pi - project" },
      { "type" => "extension_ui_request", "id" => "5", "method" => "set_editor_text", "text" => "prefill" }
    ])
  end

  def test_pending_marker_reclassifies_persisted_fire_and_forget_request
    stale = {
      "source" => "extension_ui_request", "state" => "pending",
      "details" => { "type" => "extension_ui_request", "method" => "setWidget", "widgetKey" => "pi.precognition" }
    }
    dialog = {
      "source" => "extension_ui_request", "state" => "pending",
      "details" => { "type" => "extension_ui_request", "method" => "select", "title" => "Allow?" }
    }
    approval = { "source" => "dangerous_command_approval", "state" => "pending" }

    refute Meringue::Harness::HumanInput.pending_marker?(stale)
    assert Meringue::Harness::HumanInput.pending_marker?(dialog)
    assert Meringue::Harness::HumanInput.pending_marker?(approval)
    refute Meringue::Harness::HumanInput.pending_marker?(approval.merge("state" => "answered"))
    refute Meringue::Harness::HumanInput.pending_marker?(nil)
  end

  def test_detects_dangerous_command_approval
    request = Meringue::Harness::HumanInput.requests([
      { "type" => "tool_execution_start", "name" => "bash", "command" => "rm -rf tmp", "requiresApproval" => true }
    ]).first

    assert_equal "dangerous_command_approval", request.fetch("source")
    assert_equal "rm -rf tmp", request.fetch("message")
  end

  def test_dashboard_alert_counts_pending_worker_requests
    pane = Meringue::TUI::Panes::ChatPane.new
    state = {
      "agents" => [
        { "type" => "worker", "harness_metadata" => { "human_input_request" => { "state" => "pending" } } },
        { "type" => "worker", "harness_metadata" => { "human_input_request" => { "state" => "answered" } } }
      ],
      "questions" => [], "issues" => [], "projects" => [], "logs" => [], "metadata" => {}
    }

    text = pane.status_bar_components(state).fetch("human_input").map(&:first).join
    assert_equal "⚠ 1 agent needs input · double-click worker", text
  end

  # The footer counter used to only climb: a killed worker kept its pending marker, and a
  # `setWidget` request persisted before the dialog filter existed stayed pending forever.
  def test_dashboard_alert_skips_dead_workers_and_stale_fire_and_forget_markers
    pane = Meringue::TUI::Panes::ChatPane.new
    pending = { "state" => "pending", "source" => "approval_request" }
    widget = { "state" => "pending", "source" => "extension_ui_request", "details" => { "method" => "setWidget" } }
    state = {
      "agents" => [
        { "type" => "worker", "status" => "blocked", "harness_metadata" => { "human_input_request" => pending } },
        { "type" => "worker", "status" => "killed", "harness_metadata" => { "human_input_request" => pending } },
        { "type" => "worker", "status" => "completed", "harness_metadata" => { "human_input_request" => pending } },
        { "type" => "worker", "status" => "blocked", "harness_metadata" => { "human_input_request" => widget } },
        { "type" => "head", "status" => "blocked", "harness_metadata" => { "human_input_request" => pending } }
      ],
      "questions" => [], "issues" => [], "projects" => [], "logs" => [], "metadata" => {}
    }

    text = pane.status_bar_components(state).fetch("human_input").map(&:first).join
    assert_equal "⚠ 1 agent needs input · double-click worker", text
  end

  def test_ignores_ordinary_tool_execution
    assert_empty Meringue::Harness::HumanInput.requests([{ "type" => "tool_execution_start", "name" => "bash" }])
  end

  def test_ignores_unrelated_permission_and_approval_events
    assert_empty Meringue::Harness::HumanInput.requests([
      { "type" => "permission_denied", "message" => "The command was denied." },
      { "type" => "tool_execution_end", "approval" => { "approved" => true } }
    ])
  end
end
