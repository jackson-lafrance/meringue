# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiFocusedWorkspaceTimestampTest < Minitest::Test
  include TUISupport

  WorkspacePane = Meringue::TUI::Panes::AgentWorkspacePane
  LogsPane = Meringue::TUI::Panes::ChatPane
  Timestamps = Meringue::TUI::Timestamps

  def test_utc_focused_timestamp_matches_the_local_logs_clock
    with_env("TZ" => "Etc/GMT+6") do
      timestamp = "2026-01-15T18:30:00Z"
      focused_header = focused_headers(timestamp).first
      logs_state = composed_state(empty_state.merge("logs" => [log_record("L1", "timestamp" => timestamp)]))
      logs_header = plain_lines(LogsPane.new.log_lines(logs_state, width: 70)).first

      expected = Timestamps.display(timestamp)
      assert_includes focused_header, "· #{expected}"
      assert_includes logs_header, expected
    end
  end

  def test_focused_timestamps_convert_aware_and_epoch_values_to_local_time
    with_env("TZ" => "Etc/GMT+6") do
      same_instant = Time.utc(2026, 1, 15, 18, 30).to_f * 1000
      headers = focused_headers("2026-01-15T21:30:00+03:00", same_instant)

      expected = Timestamps.display("2026-01-15T21:30:00+03:00")
      assert_equal ["● you · #{expected}", "● you · #{expected}"], headers
    end
  end

  private

  def focused_headers(*timestamps)
    worker = agent_record("P1-I1-W1", "issue_id" => "P1-I1", "project_id" => "P1")
    items = timestamps.each_with_index.map do |timestamp, index|
      {
        "id" => "message-#{index}",
        "role" => "user",
        "content" => "message #{index}",
        "timestamp" => timestamp
      }
    end
    state = composed_state(
      empty_state.merge("agents" => [worker]),
      workspace: {
        "agent_id" => worker.fetch("id"),
        "view" => "agent",
        "filter" => "all",
        "content_revision" => 1,
        "agent_session" => { "items" => items }
      }
    )

    plain_lines(WorkspacePane.new.content_lines(state, width: 70)).select { |line| line.start_with?("● you") }
  end
end
