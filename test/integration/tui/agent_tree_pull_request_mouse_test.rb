# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "tmpdir"

class TuiAgentTreePullRequestMouseTest < Minitest::Test
  include TUISupport

  WIDTH = 100
  HEIGHT = 32

  class RecordingOpener
    attr_reader :opened

    def initialize
      @opened = []
    end

    def open(url)
      @opened << url
      { "status" => "opened" }
    end
  end

  class RecordingWorkspaceController
    attr_reader :opened

    def initialize
      @opened = []
    end

    def open_workspace(agent:, state:)
      @opened << [agent.fetch("id"), state]
      { "status" => "opened" }
    end
  end

  def setup
    @opener = RecordingOpener.new
    @workspace = RecordingWorkspaceController.new
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new,
      pull_request_opener: @opener,
      workspace_controller: @workspace
    )
  end

  # Right-click now opens the row's menu rather than firing one hard-coded
  # action, so opening a pull request is a choice inside that menu.
  def test_right_clicking_an_issue_opens_its_context_menu
    url = "https://github.com/owner/repo/pull/42"
    state = state_with_issue_and_worker("delivery_pull_request" => { "url" => url, "state" => "open" })

    result = send_right_click(state, "P1-I1")

    assert_equal ["", 0, -1], result
    assert @app.send(:context_menu_active?)
    assert_empty @opener.opened, "the menu opens; it does not act on its own"
    labels = menu_entries.map { |entry| entry.fetch("label") }
    assert_includes labels, "Open pull request"
    assert_includes labels, "Move to project…"
  end

  def test_choosing_open_pull_request_from_the_menu_opens_it
    url = "https://github.com/owner/repo/pull/42"
    state = state_with_issue_and_worker("delivery_pull_request" => { "url" => url, "state" => "open" })
    send_right_click(state, "P1-I1")

    activate_menu_entry(state, "Open pull request")

    assert_equal [url], @opener.opened
    refute @app.send(:context_menu_active?)
  end

  def test_right_clicking_a_worker_offers_worker_verbs_instead_of_the_issue_pull_request
    url = "https://github.com/owner/repo/pull/42"
    state = state_with_issue_and_worker("delivery_pull_request" => { "url" => url, "state" => "open" })

    send_right_click(state, "P1-I1-W1")

    assert_empty @opener.opened
    labels = menu_entries.map { |entry| entry.fetch("label") }
    assert_includes labels, "Open workspace"
    assert_includes labels, "Move to issue…"
    refute_includes labels, "Spawn worker…"
  end

  def test_choosing_open_pull_request_without_one_shows_a_transient_notice
    state = state_with_issue_and_worker
    send_right_click(state, "P1-I1")

    activate_menu_entry(state, "Open pull request")

    assert_empty @opener.opened
    messages = compose_app_state(@app, state).fetch("_chat").fetch("messages")
    assert_includes messages.last.fetch("text"), "does not have an attached pull request yet"
  end

  def test_double_clicking_an_issue_opens_its_pull_request_instead_of_a_worker_workspace
    url = "https://github.com/owner/repo/pull/42"
    state = state_with_issue_and_worker("delivery_pull_request" => { "url" => url, "state" => "open" })

    double_click(state, "P1-I1")

    assert_equal [url], @opener.opened
    assert_empty @workspace.opened
  end

  def test_double_clicking_an_issue_without_a_pr_does_not_open_a_worker_workspace
    state = state_with_issue_and_worker

    double_click(state, "P1-I1")

    assert_empty @opener.opened
    assert_empty @workspace.opened
  end

  def test_double_clicking_a_worker_with_a_workspace_opens_that_workspace
    Dir.mktmpdir("meringue-worker-") do |workspace_path|
      state = state_with_issue_and_worker("worker_overrides" => { "workspace_path" => workspace_path })

      double_click(state, "P1-I1-W1")

      assert_empty @opener.opened
      assert_equal [["P1-I1-W1", state]], @workspace.opened
    end
  end

  def test_double_clicking_a_worker_without_a_workspace_does_not_open_a_pull_request
    state = state_with_issue_and_worker

    double_click(state, "P1-I1-W1")

    assert_empty @opener.opened
    assert_empty @workspace.opened
  end

  private

  def menu_entries
    Array(@app.instance_variable_get(:@context_menu).fetch("entries", []))
  end

  # Drive the menu the way a person would: move the selection onto the labelled
  # row, then press Enter.
  def activate_menu_entry(state, label)
    index = menu_entries.index { |entry| entry.fetch("label") == label }
    flunk "no context menu entry labelled #{label.inspect}" unless index

    @app.instance_variable_get(:@context_menu)["index"] = index
    @app.send(:handle_key, "\r", "", 0, -1, nil, state)
  end

  def state_with_issue_and_worker(issue_overrides = {})
    worker_overrides = issue_overrides.fetch("worker_overrides", {})
    issue_fields = issue_overrides.reject { |key, _value| key.to_s == "worker_overrides" }
    tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", issue_fields)],
      agents: [agent_record("P1-I1-W1", { "issue_id" => "P1-I1" }.merge(worker_overrides))]
    )
  end

  def double_click(state, item_id)
    position = screen_position_for_item(state, item_id)
    2.times do
      key = {
        "type" => "mouse",
        "kind" => "button",
        "pressed" => true,
        "button" => 0,
        "x" => position.fetch("x"),
        "y" => position.fetch("y")
      }
      @app.send(:handle_key, key, "", 0, -1, nil, state)
    end
  end

  def send_right_click(state, item_id)
    position = screen_position_for_item(state, item_id)
    key = {
      "type" => "mouse",
      "kind" => "button",
      "pressed" => true,
      "button" => 2,
      "x" => position.fetch("x"),
      "y" => position.fetch("y")
    }
    @app.send(:handle_key, key, "", 0, -1, nil, state)
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
end
