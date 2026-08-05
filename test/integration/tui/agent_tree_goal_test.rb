# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# A goal loop is rendered on the issue it controls. The AgentTree stays
# projects -> issues -> workers: no new node kind and no new lifecycle status.
#
# What a goal issue must say for itself:
#   * that it is a goal at all (the ◎ gutter marker beside its id, in its own color)
#   * which iteration of its budget it is on
#   * how much of the goal is actually done, as a percentage of the distance the
#     metric has to travel from its baseline to its target
#   * its paused/stopped state
#   * all of that *beside* the delivery PR marker, never instead of it
class TuiAgentTreeGoalTest < Minitest::Test
  include TUISupport

  Pane = Meringue::TUI::Panes::AgentTreePane
  Style = Meringue::TUI::Style

  OPEN_PR = { "url" => "https://github.com/owner/repo/pull/12", "state" => "open" }.freeze

  def pane
    @pane ||= Pane.new
  end

  def goal_record(overrides = {})
    {
      "id" => "G1",
      "project_id" => "P1",
      "issue_id" => "P1-I1",
      "status" => "working",
      "paused" => false,
      "stop_reason" => nil,
      "current_iteration" => 2,
      "budget" => { "max_iterations" => 5 },
      "metric" => { "command" => "rake coverage", "comparator" => "gte", "target" => 80.0 },
      "baseline_metric" => { "value" => 52.0 },
      "last_metric" => { "value" => 64.75 }
    }.merge(overrides)
  end

  def state_with_goals(goals, issue_overrides = {})
    state = tree_state(
      projects: [project_record("P1", "name" => "demo")],
      issues: [issue_record("P1-I1", { "title" => "Raise coverage" }.merge(issue_overrides))],
      agents: [agent_record("P1-I1-W1", "issue_id" => "P1-I1", "status" => "completed", "harness_metadata" => { "title" => "G1 iteration 1" })]
    )
    state["goals"] = goals
    state
  end

  # 52 → 64.75 of the 52 → 80 the goal has to cover is 46% of the way there.
  def goal_state(goal_overrides = {}, issue_overrides = {})
    state_with_goals([goal_record(goal_overrides)], issue_overrides)
  end

  def issue_row(state, width: 60)
    pane.lines(state, width: width).find { |line| plain_line(line).include?("Raise coverage") }
  end

  def issue_line(state, width: 60)
    plain_line(issue_row(state, width: width))
  end

  # --- a goal issue reads as a goal ------------------------------------------

  def test_a_goal_issue_is_marked_as_a_goal_in_a_fixed_column_beside_its_id
    row = issue_row(goal_state)

    assert_includes plain_line(row), "I1#{Pane::GOAL_GLYPH}", "the goal marker sits in the gutter between the id and the title"
    assert_includes styles_in(row), Style::GOAL_MARKER, "a goal reads as goal state, not as more issue text"
  end

  def test_an_issue_without_a_goal_carries_no_goal_marker_and_keeps_its_worker_ratio
    goalless = goal_state
    goalless["goals"] = []
    row = issue_row(goalless)

    refute_includes plain_line(row), Pane::GOAL_GLYPH
    refute_includes styles_in(row), Style::GOAL_MARKER
    assert_includes plain_line(row), "1/1", "the ordinary worker progress suffix still renders"
  end

  # The goal already reports progress as iteration plus percent complete. A second
  # fraction from the worker rollup beside it reads as a conflicting ratio.
  def test_the_goal_chip_stands_in_for_the_worker_ratio_on_a_goal_issue
    line = issue_line(goal_state)

    assert_includes line, "2/5"
    refute_includes line, "1/1"
  end

  def test_the_goal_marker_survives_selection_with_its_selected_palette
    state = goal_state
    state["_agent_tree_navigation"] = { "active" => true, "selected_agent_id" => "P1-I1" }
    row = issue_row(state, width: 60)

    assert plain_line(row).start_with?("▸")
    assert_includes plain_line(row), Pane::GOAL_GLYPH
    assert_includes styles_in(row), Style::GOAL_MARKER_SELECTED
    refute_includes styles_in(row), Style::GOAL_MARKER, "the selected row uses the selection background everywhere"
  end

  # --- iteration and percent complete ----------------------------------------

  def test_a_goal_issue_shows_the_iteration_it_is_on_and_percent_complete
    line = issue_line(goal_state)

    assert_includes line, "2/5", "iteration 2 of a 5 iteration budget"
    assert_includes line, "46%", "52 → 64.75 of the 52 → 80 span"
  end

  # The whole point of the percentage: iterations measure budget *spent*, and that is
  # not the same reading as progress *made*.
  def test_percent_complete_is_progress_made_not_budget_spent
    line = issue_line(goal_state(
                        "current_iteration" => 1,
                        "metric" => { "comparator" => "gte", "target" => 10.0 },
                        "baseline_metric" => { "value" => 0.0 },
                        "last_metric" => { "value" => 9.0 }
                      ))

    assert_includes line, "1/5"
    assert_includes line, "90%"
    refute_includes line, "20%", "1 of 5 iterations spent is not 20% of the goal"
  end

  # A `lte`/`lt` goal is achieved by driving a number down, so travel toward the
  # target has to count the same way it does for an increasing metric.
  def test_a_decreasing_metric_goal_counts_progress_downward
    line = issue_line(goal_state(
                        "metric" => { "comparator" => "lte", "target" => 0.0 },
                        "baseline_metric" => { "value" => 40.0 },
                        "last_metric" => { "value" => 12.0 }
                      ))

    assert_includes line, "70%", "40 → 12 of the 40 → 0 span"
  end

  def test_a_decreasing_metric_that_got_worse_never_reads_below_zero
    line = issue_line(goal_state(
                        "metric" => { "comparator" => "lte", "target" => 0.0 },
                        "baseline_metric" => { "value" => 40.0 },
                        "last_metric" => { "value" => 61.0 }
                      ))

    assert_includes line, "0%"
    refute_includes line, "-"
  end

  def test_a_goal_that_reached_its_target_reads_one_hundred_percent
    line = issue_line(goal_state("last_metric" => { "value" => 81.0 }))

    assert_includes line, "100%"
  end

  def test_a_goal_that_is_nearly_there_never_rounds_up_to_one_hundred_percent
    line = issue_line(goal_state(
                        "metric" => { "comparator" => "gte", "target" => 100.0 },
                        "baseline_metric" => { "value" => 0.0 },
                        "last_metric" => { "value" => 99.6 }
                      ))

    assert_includes line, "99%", "only a satisfied target may read 100%"
    refute_includes line, "100%"
  end

  # --- degrading gracefully ---------------------------------------------------

  def test_a_goal_with_nothing_measured_yet_reads_as_unknown_rather_than_a_number
    line = issue_line(goal_state("current_iteration" => 0, "baseline_metric" => nil, "last_metric" => nil))

    assert_includes line, "0/5"
    assert_includes line, Pane::GOAL_UNKNOWN_PERCENT
    refute_includes line, "NaN"
    refute_includes line, "Infinity"
  end

  # The baseline is measured before the first attempt, so a goal that has been
  # baselined but not yet attempted really is 0% of the way there.
  def test_a_baselined_goal_with_no_attempt_measurement_yet_reads_zero_percent
    line = issue_line(goal_state("current_iteration" => 0, "last_metric" => nil))

    assert_includes line, "0/5"
    assert_includes line, "0%"
  end

  def test_a_baseline_that_already_satisfies_the_target_reads_complete
    line = issue_line(goal_state("current_iteration" => 0, "baseline_metric" => { "value" => 91.0 }, "last_metric" => nil))

    assert_includes line, "100%"
  end

  # Without a baseline there is no span to measure travel across, so the row shows the
  # raw "where it is now → where it has to get to" reading instead of inventing one.
  def test_a_goal_with_no_baseline_falls_back_to_the_raw_metric_reading
    line = issue_line(goal_state("baseline_metric" => nil))

    assert_includes line, "64.8→80"
    refute_includes line, "%"
  end

  def test_a_non_numeric_measurement_reads_as_unknown
    line = issue_line(goal_state("baseline_metric" => { "value" => "n/a" }, "last_metric" => { "value" => "boom" }))

    assert_includes line, "2/5"
    assert_includes line, Pane::GOAL_UNKNOWN_PERCENT
  end

  # An exit_status metric is a pass/fail measurement, so its percentage is honestly
  # binary rather than broken.
  def test_an_exit_status_goal_reads_as_zero_or_one_hundred_percent
    failing = goal_state(
      "metric" => { "comparator" => "eq", "target" => 0.0, "parse" => { "type" => "exit_status" } },
      "baseline_metric" => { "value" => 1.0 },
      "last_metric" => { "value" => 1.0 }
    )
    passing = goal_state(
      "metric" => { "comparator" => "eq", "target" => 0.0, "parse" => { "type" => "exit_status" } },
      "baseline_metric" => { "value" => 1.0 },
      "last_metric" => { "value" => 0.0 }
    )

    assert_includes issue_line(failing), "0%"
    assert_includes issue_line(passing), "100%"
  end

  # A reviewer-judged loop has no number to be a percentage of. It still has to render
  # as a goal, with its iteration accounting, instead of a fabricated or broken score.
  def test_a_goal_with_no_numeric_target_shows_its_iteration_and_no_percentage
    row = issue_row(goal_state("metric" => { "command" => "", "comparator" => "gte", "target" => nil }))

    assert_includes plain_line(row), "I1#{Pane::GOAL_GLYPH}"
    assert_includes plain_line(row), "2/5"
    refute_includes plain_line(row), "%"
    assert_includes styles_in(row), Style::GOAL_MARKER
  end

  def test_malformed_goal_records_do_not_break_rendering
    broken = state_with_goals([{ "id" => "G1", "issue_id" => "P1-I1" }, "not a goal", nil])
    line = issue_line(broken)

    assert_includes line, "I1#{Pane::GOAL_GLYPH}"
    assert_includes line, "0/0"
  end

  def test_a_goal_whose_metric_is_not_a_hash_does_not_raise
    line = issue_line(goal_state("metric" => "rake coverage", "budget" => "wide open"))

    assert_includes line, "2/0"
  end

  # --- paused and stopped -----------------------------------------------------

  def test_a_paused_goal_says_so_without_losing_its_progress
    line = issue_line(goal_state("paused" => true))

    assert_includes line, "paused"
    assert_includes line, "2/5"
    assert_includes line, "46%"
  end

  def test_a_stopped_goal_shows_why_it_stopped
    line = issue_line(goal_state("status" => "blocked", "stop_reason" => "no_progress"))

    assert_includes line, "stopped: no progress"
    assert_includes line, "46%"
  end

  def test_a_completed_goal_reads_as_met_rather_than_stopped
    line = issue_line(goal_state("status" => "completed", "stop_reason" => "goal_met", "current_iteration" => 3, "last_metric" => { "value" => 82.0 }))

    assert_includes line, "3/5"
    assert_includes line, "100%"
    assert_includes line, "goal met"
    refute_includes line, "stopped"
  end

  def test_a_user_stopped_goal_says_the_user_stopped_it
    assert_includes issue_line(goal_state("status" => "killed", "stop_reason" => "user_stopped")), "stopped by you"
  end

  # --- the goal chip and the delivery PR share the row ------------------------

  def test_a_goal_issue_with_a_delivery_pull_request_shows_both_markers
    row = issue_row(goal_state({}, "delivery_pull_request" => OPEN_PR))
    line = plain_line(row)

    assert_includes line, "2/5"
    assert_includes line, "46%"
    assert_includes line, "↗"
    assert_operator line.index("46%"), :<, line.index("↗"), "the goal chip sits beside the PR marker, not over it"
    assert_includes styles_in(row), Style::GOAL_MARKER
    assert_includes styles_in(row), Style::PR_MARKER, "the two markers stay separately colored"
  end

  # The markers are the row's status, not decoration: a title long enough to fill the
  # pane is ellipsized so they survive, instead of being pushed off the row.
  def test_a_narrow_pane_keeps_the_goal_chip_and_the_pr_marker
    long_title = "Raise coverage of the kernel command application path above eighty percent"
    state = goal_state({}, "title" => long_title, "delivery_pull_request" => OPEN_PR)

    [24, 30, 34, 38].each do |width|
      rendered = plain_lines(pane.lines(state, width: width))
      ids = pane.line_item_ids(state, width: width)
      issue_rows = rendered.each_with_index.select { |_line, index| ids[index] == "P1-I1" }.map(&:first)
      text = issue_rows.join("\n")

      assert_includes text, "2/5 46%", "width #{width} must keep the goal chip"
      assert_includes text, "↗", "width #{width} must keep the PR marker"
      assert_includes text, Pane::ELLIPSIS, "width #{width} ellipsizes the title instead"
      assert_operator issue_rows.length, :<=, Pane::MAX_ITEM_LINES
      assert rendered.all? { |line| line.length <= width }, "no row may exceed the pane content width"
    end
  end

  # A goal chip that wrapped onto its own continuation row still has to look like a
  # goal chip.
  def test_a_wrapped_goal_chip_keeps_its_marker_styling
    state = goal_state({}, "title" => "Raise coverage of the kernel command application path")
    rows = pane.lines(state, width: 30).select { |line| plain_line(line).include?("2/5") }

    refute_empty rows
    assert_includes styles_in(rows.first), Style::GOAL_MARKER
  end

  # `bundle exec meringue demo` is how the AgentTree is reviewed without spawning real
  # sessions, so the demo fixture carries a goal-driven issue.
  def test_the_demo_fixture_shows_a_goal_driven_issue
    rendered = plain_lines(pane.lines(composed_state(demo_state), width: 34)).join("\n")

    assert_includes rendered, "I2#{Pane::GOAL_GLYPH}"
    assert_includes rendered, "2/4 46%"
  end

  # --- the id-listing path stays aligned with the render path -----------------

  def test_goal_rows_do_not_change_the_clickable_row_mapping
    with_goal = goal_state
    without_goal = goal_state
    without_goal["goals"] = []

    [with_goal, without_goal].each do |candidate|
      assert_equal pane.lines(candidate).length, pane.line_item_ids(candidate).length,
                   "rendered rows and hit-test ids must stay aligned"
      assert_equal %w[P1 P1-I1 P1-I1-W1], pane.line_item_ids(candidate).compact
    end
  end

  def test_a_narrow_pane_still_maps_wrapped_goal_rows_to_their_issue
    state = goal_state({}, "title" => "Raise coverage of the kernel command application path", "delivery_pull_request" => OPEN_PR)

    (20..60).each do |width|
      assert_equal pane.lines(state, width: width).length, pane.line_item_ids(state, width: width).length,
                   "row/id mapping drifted at width #{width}"
    end
  end

  # Regression: the id-listing path dropped the goals when it recursed into child
  # issues, so a goal on a nested issue wrapped differently in the two paths.
  def test_a_goal_on_a_nested_child_issue_maps_to_the_same_rows_in_both_paths
    state = tree_state(
      projects: [project_record("P1", "name" => "demo")],
      issues: [
        issue_record("P1-I1", "title" => "Parent issue"),
        issue_record("P1-I2", "title" => "Raise coverage of the kernel command application path", "parent_issue_id" => "P1-I1")
      ],
      agents: []
    )
    state["goals"] = [goal_record("issue_id" => "P1-I2")]

    (20..60).each do |width|
      assert_equal pane.lines(state, width: width).length, pane.line_item_ids(state, width: width).length,
                   "row/id mapping drifted at width #{width}"
    end
    assert_includes plain_lines(pane.lines(state, width: 60)).join("\n"), "2/5 46%"
  end
end
