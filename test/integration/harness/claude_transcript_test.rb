# frozen_string_literal: true

require "test_helper"

class HarnessClaudeTranscriptTest < Minitest::Test
  def test_completed_outcome_preserves_a_long_final_report
    report = "REPORT START\n#{"finding\n" * 1_000}REPORT END"
    records = [
      {
        "type" => "assistant",
        "message" => {
          "stop_reason" => "end_turn",
          "content" => [{ "type" => "text", "text" => report }]
        }
      }
    ]

    outcome = Meringue::Harness::ClaudeTranscript.turn_outcome(records)

    assert_operator report.bytesize, :>, 4_000
    assert_equal report, outcome.fetch("last_assistant_text")
  end
end
