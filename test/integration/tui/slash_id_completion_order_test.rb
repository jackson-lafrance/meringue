# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Tab completing a record id is how `/kill` and `/prompt` are actually driven, so the first
# suggestion has to be the record the typed fragment names rather than something nested under it.
class TuiSlashIdCompletionOrderTest < Minitest::Test
  include TUISupport

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

  # Tab with nothing selected applies the first suggestion, so the shallowest match must lead.
  def test_tab_completing_an_id_fragment_picks_the_shallowest_match_first
    {
      "/kill i10" => "/kill P3-I10",
      "/kill p3" => "/kill P3",
      "/kill p3-i10-w" => "/kill P3-I10-W1",
      "/prompt i10" => "/prompt P3-I10-W1"
    }.each do |typed, expected|
      completion = @app.send(:safe_slash_completion, typed, 0, @state)

      assert_equal expected, completion.to_s.strip, "completion for #{typed.inspect}"
    end
  end

  # The workers are still offered, just after the issue that owns them.
  def test_descendants_stay_in_the_list_below_their_ancestor
    records = @app.send(:slash_suggestion_records, "/kill i10", @state)

    assert_equal %w[P3-I10 P3-I10-W1 P3-I10-W2], records.map { |record| record.fetch("usage") }
    assert_equal "/kill P3-I10-W2", @app.send(:safe_slash_completion, "/kill i10", 2, @state).to_s.strip
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
