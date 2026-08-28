# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# The dashboard someone lands on after finishing setup used to be three empty
# panes reporting their own emptiness. These cover what it says instead, and —
# just as importantly — that it stops saying it the moment there is real work.
class TuiFirstRunDashboardTest < Minitest::Test
  include TUISupport

  FirstRun = Meringue::TUI::FirstRun

  def setup
    @pane = Meringue::TUI::Panes::ChatPane.new
    @tree = Meringue::TUI::Panes::AgentTreePane.new
  end

  def test_a_completely_empty_dashboard_offers_examples_instead_of_reporting_emptiness
    text = logs_text(empty_state)

    assert_includes text, "Nothing here yet. Try one of these:"
    assert_includes text, %(add tests for the login flow)
    assert_includes text, "a goal, in plain English"
    assert_includes text, "/help"
    refute_includes text, "No logs yet."
  end

  # Without a project there is nowhere for an issue to go, so that outranks the
  # general encouragement.
  def test_the_footer_names_the_missing_project_first
    assert_includes logs_text(empty_state), "No project is registered yet"
    refute_includes logs_text(empty_state), "Meringue creates the issue"
  end

  def test_with_a_project_the_footer_explains_what_happens_next
    state = empty_state
    state["projects"] = [{ "id" => "P1", "name" => "Sample", "root_path" => "/tmp/sample" }]

    text = logs_text(state)
    assert_includes text, "Meringue creates the issue and starts the worker"
    refute_includes text, "No project is registered yet"
  end

  # It costs a returning user nothing, which is only true if it disappears.
  def test_the_card_is_gone_as_soon_as_there_is_anything_to_show
    with_logs = empty_state
    with_logs["logs"] = [{ "id" => "L1", "source_type" => "user", "message" => "hello", "created_at" => "2026-08-27T00:00:00Z" }]

    refute_includes logs_text(with_logs), "Nothing here yet"
  end

  # Setup adopts the launch directory, so "one project, nothing in it" is the
  # most common first dashboard there is — and the one that most needs the card.
  def test_an_adopted_project_alone_is_still_a_first_run
    state = empty_state
    state["projects"] = [{ "id" => "P1", "name" => "Sample", "root_path" => "/tmp/sample" }]

    assert FirstRun.empty_dashboard?(state)
  end

  def test_a_dashboard_with_an_issue_is_no_longer_a_first_run
    state = empty_state
    state["projects"] = [{ "id" => "P1", "name" => "Sample", "root_path" => "/tmp/sample" }]
    state["issues"] = [{ "id" => "P1-I1", "project_id" => "P1", "title" => "Something" }]

    refute FirstRun.empty_dashboard?(state)
    assert_includes logs_text(state), "No logs yet."
  end

  # A filter narrowing the view to something empty is not a first run, and
  # answering it with a first-run card would hide why the pane is blank.
  def test_a_scoped_but_empty_view_keeps_its_own_explanation
    scoped = composed_state(empty_state).merge(
      "_log_scope" => { "id" => "P1-I1-W1", "label" => "P1-I1-W1", "kind" => "agent" }
    )

    text = plain_lines(@pane.log_lines(scoped, width: 80)).join("\n")
    assert_includes text, "No logs for P1-I1-W1 yet"
    refute_includes text, "Nothing here yet"
  end

  def test_the_agent_tree_points_at_the_chat_rather_than_naming_its_own_data
    lines = plain_lines(@tree.lines(composed_state(empty_state), width: 40))

    assert_equal ["No agents yet.", "Describe a goal in the chat below."], lines
  end

  def test_the_composer_placeholder_shows_the_shape_of_a_first_message
    placeholder = Meringue::TUI::ChatTarget.placeholder(composed_state(empty_state))

    assert_includes placeholder, "describe a goal"
    refute_equal "enter a prompt", placeholder
  end

  # The card is a first-run affordance, not a permanent decoration, so it must
  # not survive into a dashboard that is merely quiet.
  def test_empty_dashboard_is_false_once_work_exists
    %w[issues agents].each do |key|
      state = empty_state
      state[key] = [{ "id" => "X1" }]

      refute FirstRun.empty_dashboard?(state), "#{key} should end the first run"
    end
  end

  private

  def logs_text(state)
    plain_lines(@pane.log_lines(composed_state(state), width: 80)).join("\n")
  end
end
