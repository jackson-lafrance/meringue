# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Cycling to a record id is how `/kill` and `/prompt` are actually driven, so the first
# suggestion has to be the record the typed fragment names rather than something nested under it.
class TuiSlashIdCompletionOrderTest < Minitest::Test
  include TUISupport

  TAB = "\t"
  SHIFT_TAB = "\e[Z"

  def setup
    @state = empty_state.merge(
      "projects" => [project_record("P3"), project_record("P10")],
      "issues" => [
        issue_record("P3-I10", "title" => "Sort completions", "agent_ids" => %w[P3-I10-W1 P3-I10-W2]),
        issue_record("P3-I2", "title" => "Fix login"),
        issue_record("P10-I1", "title" => "Update vim config")
      ],
      "agents" => [
        worker("P3-I10-W2", "P3-I10"),
        worker("P3-I10-W1", "P3-I10"),
        worker("P10-I1-W1", "P10-I1")
      ]
    )
    @app = build_app
  end

  # The first forward cycle selects the shallowest match, so it remains the first accept choice.
  def test_tab_cycling_an_id_fragment_starts_with_the_shallowest_match
    {
      "/kill i10" => "/kill P3-I10",
      "/kill p3" => "/kill P3",
      "/kill p3-i10-w" => "/kill P3-I10-W1",
      "/prompt i10" => "/prompt P3-I10-W1"
    }.each do |typed, expected|
      records = @app.send(:slash_suggestion_records, typed, @state)
      result = @app.send(:handle_key, TAB, typed, typed.length, -1, nil, @state)

      assert_equal [typed, typed.length, 0], result, "first selection for #{typed.inspect}"
      assert_equal expected, records.fetch(0).fetch("completion"), "completion for #{typed.inspect}"
    end
  end

  # The workers are still offered, just after the issue that owns them.
  def test_descendants_stay_in_the_list_below_their_ancestor
    records = @app.send(:slash_suggestion_records, "/kill i10", @state)

    assert_equal %w[P3-I10 P3-I10-W1 P3-I10-W2], records.map { |record| record.fetch("usage") }
    assert_equal "/kill P3-I10-W2", @app.send(:safe_slash_completion, "/kill i10", 2, @state).to_s.strip
  end

  def test_tab_cycles_forward_and_shift_tab_cycles_backward_for_inline_id_suggestions
    {
      "/kill " => %w[P3-I10-W2 P3-I10-W1 P10-I1-W1],
      "/prompt " => %w[P3-I10-W2 P3-I10-W1 P10-I1-W1],
      "/jump " => %w[P3-I10-W2 P3-I10-W1 P10-I1-W1]
    }.each do |input, expected_prefix|
      records = @app.send(:slash_suggestion_records, input, @state)
      assert_operator records.length, :>, 1, input
      assert_equal expected_prefix, records.map { |record| record.fetch("usage") }.first(3), input

      first = @app.send(:handle_key, TAB, input, input.length, -1, nil, @state)
      second = @app.send(:handle_key, TAB, input, input.length, first.fetch(2), nil, @state)
      backward = @app.send(:handle_key, SHIFT_TAB, input, input.length, -1, nil, @state)

      assert_equal 0, first.fetch(2), input
      assert_equal 1, second.fetch(2), input
      assert_equal records.length - 1, backward.fetch(2), input
    end
  end

  private

  def worker(id, issue_id)
    agent_record(
      id,
      "project_id" => issue_id.split("-").first,
      "issue_id" => issue_id,
      "harness_session_id" => "fake-session-#{id}"
    )
  end
end
