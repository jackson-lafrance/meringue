# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

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

  def setup
    @opener = RecordingOpener.new
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new,
      pull_request_opener: @opener
    )
  end

  def test_right_clicking_an_agent_opens_its_issue_delivery_pull_request
    url = "https://github.com/owner/repo/pull/42"
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "delivery_pull_request" => { "url" => url, "state" => "open" })],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
    )

    result = send_right_click(state, "P1-I1-W1")

    assert_equal ["", 0, -1], result
    assert_equal [url], @opener.opened
  end

  def test_right_clicking_an_agent_without_a_pr_shows_a_transient_notice
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1")],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
    )

    send_right_click(state, "P1-I1-W1")

    assert_empty @opener.opened
    messages = compose_app_state(@app, state).fetch("_chat").fetch("messages")
    assert_includes messages.last.fetch("text"), "does not have an attached pull request yet"
  end

  def test_right_clicking_an_issue_does_not_open_a_pull_request
    url = "https://github.com/owner/repo/pull/42"
    state = tree_state(
      projects: [project_record("P1")],
      issues: [issue_record("P1-I1", "delivery_pull_request" => { "url" => url, "state" => "open" })],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
    )

    send_right_click(state, "P1-I1")

    assert_empty @opener.opened
  end

  private

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
