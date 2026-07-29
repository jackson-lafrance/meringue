# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# The harness event journal is the seam between a live harness transport and
# every Meringue reader (kernel reconciliation, focused session view, waiters).
class HarnessEventJournalTest < HarnessIntegrationTest
  def journal(**kwargs)
    Meringue::Harness::EventJournal.new(**kwargs)
  end

  def test_appends_lifecycle_events_in_order_with_monotonic_sequences
    log = journal
    %w[agent_start tool_execution_start tool_execution_end agent_end process_exit].each do |type|
      log.publish("type" => type)
    end

    result = log.read(after: 0)

    assert_equal %w[agent_start tool_execution_start tool_execution_end agent_end process_exit],
                 result.fetch("entries").map { |entry| entry.fetch("event").fetch("type") }
    assert_equal [1, 2, 3, 4, 5], result.fetch("entries").map { |entry| entry.fetch("sequence") }
    assert_equal 5, result.fetch("cursor")
    assert_equal 5, result.fetch("latest_cursor")
    refute result.fetch("gap")
    assert(result.fetch("entries").all? { |entry| entry.key?("timestamp") })
    refute(result.fetch("entries").any? { |entry| entry.key?("bytes") })
  end

  def test_publish_returns_sequence_and_cursor_tracks_latest
    log = journal

    assert_equal 1, log.publish("type" => "agent_start")
    assert_equal 2, log.publish("type" => "agent_end")
    assert_equal 2, log.cursor
  end

  def test_reads_are_non_destructive_and_cursors_are_per_reader
    log = journal
    log.publish("type" => "agent_start")
    log.publish("type" => "agent_end")

    kernel_view = log.read(after: 0)
    assert_equal 2, kernel_view.fetch("entries").length

    # A second, independent reader still sees everything from cursor 0.
    focused_view = log.read(after: 0)
    assert_equal 2, focused_view.fetch("entries").length

    log.publish("type" => "agent_settled")
    incremental = log.read(after: kernel_view.fetch("cursor"))
    assert_equal ["agent_settled"], incremental.fetch("entries").map { |entry| entry.fetch("event").fetch("type") }
    assert_equal 3, incremental.fetch("cursor")
  end

  def test_read_respects_limit_without_dropping_later_events
    log = journal
    5.times { |index| log.publish("type" => "message_update", "index" => index) }

    first = log.read(after: 0, limit: 2)
    assert_equal [0, 1], first.fetch("entries").map { |entry| entry.fetch("event").fetch("index") }
    assert_equal 2, first.fetch("cursor")
    assert_equal 5, first.fetch("latest_cursor")

    rest = log.read(after: first.fetch("cursor"))
    assert_equal [2, 3, 4], rest.fetch("entries").map { |entry| entry.fetch("event").fetch("index") }
  end

  def test_read_after_current_cursor_returns_no_entries
    log = journal
    log.publish("type" => "agent_start")

    result = log.read(after: 1)

    assert_empty result.fetch("entries")
    assert_equal 1, result.fetch("cursor")
    assert_equal 1, result.fetch("latest_cursor")
  end

  def test_truncates_to_max_events_and_reports_gap_for_stale_cursors
    log = journal(max_events: 3)
    5.times { |index| log.publish("type" => "message_update", "index" => index) }

    result = log.read(after: 0)

    assert_equal [2, 3, 4], result.fetch("entries").map { |entry| entry.fetch("event").fetch("index") }
    assert result.fetch("gap"), "a reader whose cursor predates the oldest retained event must see a gap"

    fresh = log.read(after: 3)
    refute fresh.fetch("gap")
    assert_equal [3, 4], fresh.fetch("entries").map { |entry| entry.fetch("event").fetch("index") }
  end

  # Streaming token deltas must not accumulate without bound: the journal is a
  # bounded buffer, so durable state never grows with every streamed token.
  def test_truncates_by_byte_budget_for_streaming_deltas
    log = journal(max_events: 10_000, max_bytes: 400)
    50.times { |index| log.publish("type" => "message_update", "delta" => "token-#{index}" * 5) }

    entries = log.read(after: 0).fetch("entries")

    assert_operator entries.length, :<, 50
    assert_operator entries.length, :>=, 1
    assert_equal "message_update", entries.last.fetch("event").fetch("type")
    assert_includes entries.last.fetch("event").fetch("delta"), "token-49"
  end

  def test_published_events_are_deep_copied
    log = journal
    event = { "type" => "tool_execution_end", "result" => { "content" => "before" } }
    log.publish(event)
    event["result"]["content"] = "mutated"

    stored = log.read(after: 0).fetch("entries").first.fetch("event")

    assert_equal "before", stored.fetch("result").fetch("content")
  end

  def test_wait_returns_immediately_when_events_are_already_pending
    log = journal
    log.publish("type" => "agent_settled")

    result = log.wait(after: 0, timeout: 5)

    assert_equal ["agent_settled"], result.fetch("entries").map { |entry| entry.fetch("event").fetch("type") }
  end

  def test_wait_wakes_up_on_publish
    log = journal
    writer = Thread.new do
      sleep 0.05
      log.publish("type" => "agent_settled")
    end

    result = log.wait(after: 0, timeout: 5, limit: 1)
    writer.join

    assert_equal ["agent_settled"], result.fetch("entries").map { |entry| entry.fetch("event").fetch("type") }
  end

  def test_wait_times_out_with_no_entries
    log = journal

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = log.wait(after: 0, timeout: 0.05)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_empty result.fetch("entries")
    assert_operator elapsed, :<, 3.0
  end
end
