# frozen_string_literal: true

require "test_helper"

class TuiWorkspaceTranscriptTest < Minitest::Test
  Transcript = Meringue::TUI::WorkspaceTranscript

  def test_pi_tool_call_argument_deltas_are_not_rendered_as_assistant_prose
    entries = Transcript.entries(
      workspace: {
        "agent_session" => {
          "items" => [
            {
              "id" => "assistant-1",
              "role" => "assistant",
              "content" => "",
              "delta" => "{\"command\":\"rake test\"}",
              "delta_type" => "toolcall_delta",
              "tool_call_id" => "call-1",
              "tool_name" => "bash",
              "timestamp" => "2026-01-01T00:00:00Z"
            }
          ]
        }
      },
      agent_id: "P1-I1-W1"
    )

    assert_equal ["tool_call"], entries.map { |entry| entry.fetch("role") }
    refute entries.any? { |entry| entry.fetch("role") == "agent" }
    assert_includes entries.first.fetch("text"), "rake test"
  end

  def test_pi_control_entries_stay_in_order_with_the_transcript
    entries = Transcript.entries(
      workspace: {
        "agent_session" => {
          "items" => [
            { "id" => "m1", "role" => "user", "content" => "start", "timestamp" => "2026-01-01T00:00:00Z" },
            { "id" => "c1", "kind" => "notice", "role" => "system", "content" => "Context compacted", "timestamp" => "2026-01-01T00:00:01Z" },
            { "id" => "m2", "role" => "assistant", "content" => "continuing", "timestamp" => "2026-01-01T00:00:02Z" }
          ]
        }
      },
      agent_id: "P1-I1-W1"
    )

    assert_equal %w[you system agent], entries.map { |entry| entry.fetch("role") }
    assert_equal ["start", "Context compacted", "continuing"], entries.map { |entry| entry.fetch("text") }
  end
end
