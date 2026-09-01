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

  def test_ignores_ordinary_tool_execution
    assert_empty Meringue::Harness::HumanInput.requests([{ "type" => "tool_execution_start", "name" => "bash" }])
  end
end
