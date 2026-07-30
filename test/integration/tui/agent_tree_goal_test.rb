# frozen_string_literal: true

require "test_helper"

# A goal loop is rendered as a suffix on the issue it controls. The AgentTree stays
# projects -> issues -> workers: no new node kind and no new lifecycle status.
class TuiAgentTreeGoalTest < Minitest::Test
  def pane
    @pane ||= Meringue::TUI::Panes::AgentTreePane.new
  end

  def state(goal_overrides = {}, issue_status = "working")
    goal = {
      "id" => "G1",
      "issue_id" => "P1-I1",
      "project_id" => "P1",
      "status" => "working",
      "current_iteration" => 2,
      "budget" => { "max_iterations" => 5 },
      "metric" => { "target" => 80.0, "comparator" => "gte" },
      "last_metric" => { "value" => 64.75 }
    }.merge(goal_overrides)
    {
      "projects" => [{ "id" => "P1", "name" => "demo", "status" => "working" }],
      "issues" => [{ "id" => "P1-I1", "project_id" => "P1", "title" => "Raise coverage", "status" => issue_status }],
      "agents" => [
        { "id" => "P1-I1-W1", "type" => "worker", "issue_id" => "P1-I1", "status" => "completed", "harness_metadata" => { "title" => "G1 iteration 1" } }
      ],
      "goals" => [goal]
    }
  end

  def issue_line(rendered)
    rendered.lines.find { |line| line.include?("Raise coverage") }.to_s
  end

  def test_an_issue_with_a_goal_shows_its_iteration_and_metric_progress
    line = issue_line(pane.render(state))

    assert_includes line, "2/5"
    assert_includes line, "64.8/80"
    assert_includes line, "◎"
  end

  def test_a_stopped_goal_shows_why_it_stopped
    line = issue_line(pane.render(state("status" => "blocked", "stop_reason" => "no_progress")))

    assert_includes line, "no progress"
  end

  def test_a_paused_goal_says_so
    assert_includes issue_line(pane.render(state("paused" => true))), "paused"
  end

  def test_an_issue_without_a_goal_is_unchanged
    goalless = state
    goalless["goals"] = []
    line = issue_line(pane.render(goalless))

    refute_includes line, "◎"
    assert_includes line, "1/1", "the ordinary worker progress suffix still renders"
  end

  def test_a_goal_with_no_measurement_yet_renders_without_a_number
    line = issue_line(pane.render(state("last_metric" => nil, "current_iteration" => 0)))

    assert_includes line, "0/5"
    assert_includes line, "?/80"
  end

  def test_goal_rows_do_not_change_the_clickable_row_mapping
    with_goal = state
    without_goal = state
    without_goal["goals"] = []

    [with_goal, without_goal].each do |candidate|
      assert_equal pane.lines(candidate).length, pane.line_item_ids(candidate).length,
                   "rendered rows and hit-test ids must stay aligned"
      assert_equal %w[P1 P1-I1 P1-I1-W1], pane.line_item_ids(candidate).compact
    end
  end

  def test_a_narrow_pane_still_maps_wrapped_goal_rows_to_their_issue
    narrow = 28

    assert_equal pane.lines(state, width: narrow).length, pane.line_item_ids(state, width: narrow).length
  end

  def test_malformed_goal_records_do_not_break_rendering
    broken = state
    broken["goals"] = [{ "id" => "G1", "issue_id" => "P1-I1" }, "not a goal"]

    line = issue_line(pane.render(broken))

    assert_includes line, "◎0/0"
  end
end
