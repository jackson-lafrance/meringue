# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# A Pi session that is no longer streaming has not necessarily finished its work.
# When the network drops, Pi ends the turn and records the failure on the turn's
# final assistant message, so `turn_outcome` is how the kernel can tell a real
# completion from a turn that died mid-flight.
class HarnessPiClientTurnOutcomeTest < HarnessIntegrationTest
  PiClient = Meringue::Harness::PiClient

  def client
    @client ||= PiClient.new(session_dir: File.join(tmpdir, "pi-sessions"))
  end

  def assistant_line(stop_reason:, text: nil, error_message: nil, id: "m9", parent_id: "m2", timestamp: "2026-01-01T00:05:00Z")
    message = { "role" => "assistant" }
    message["content"] = text ? [{ "type" => "text", "text" => text }] : []
    message["stopReason"] = stop_reason if stop_reason
    message["errorMessage"] = error_message if error_message
    JSON.generate(
      "type" => "message",
      "id" => id,
      "parentId" => parent_id,
      "timestamp" => timestamp,
      "message" => message
    )
  end

  def user_line(text: "continue", id: "m10", parent_id: "m9", timestamp: "2026-01-01T00:06:00Z")
    JSON.generate(
      "type" => "message",
      "id" => id,
      "parentId" => parent_id,
      "timestamp" => timestamp,
      "message" => { "role" => "user", "content" => [{ "type" => "text", "text" => text }] }
    )
  end

  def outcome_for(extra_lines, completed: true)
    path = pi_session_file(tmpdir, completed: completed, extra_lines: extra_lines)
    client.turn_outcome(pi_session_ref(session_file: path))
  end

  def test_a_dropped_connection_reports_a_failed_turn_with_a_human_readable_reason
    outcome = outcome_for([assistant_line(stop_reason: "error", error_message: "Connection error.")])

    assert_equal "failed", outcome.fetch("state")
    assert_equal "network_failure", outcome.fetch("kind")
    assert_equal "error", outcome.fetch("stop_reason")
    assert_equal "Connection error.", outcome.fetch("error_message")
    assert_equal "its model request failed mid-turn (network error: Connection error.)", outcome.fetch("reason")
    refute outcome.key?("last_assistant_text"), "an aborted turn has no final assistant text"
  end

  def test_a_non_network_provider_error_is_reported_as_a_provider_error
    outcome = outcome_for([assistant_line(stop_reason: "error", error_message: "invalid request: tool schema rejected")])

    assert_equal "failed", outcome.fetch("state")
    assert_equal "provider_error", outcome.fetch("kind")
    assert_equal "its model request failed mid-turn (invalid request: tool schema rejected)", outcome.fetch("reason")
  end

  # The failure that dead-ended a real worker: the provider refused the *saved transcript* it was
  # asked to replay, so every resume of that session fails identically. It must not be classified as
  # a transport blip, because a transport blip is retried and this cannot be.
  def test_a_rejected_thinking_block_replay_is_classified_as_an_unreplayable_session
    message = '400 {"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.44: ' \
              '`thinking` or `redacted_thinking` blocks in the latest assistant message cannot be modified. ' \
              'These blocks must remain as they were in the original response."},"request_id":"req_vrtx_1"}'
    outcome = outcome_for([assistant_line(stop_reason: "error", error_message: message)])

    assert_equal "failed", outcome.fetch("state")
    assert_equal "unreplayable_session", outcome.fetch("kind")
    assert_equal "fresh_session", outcome.fetch("recovery")
    assert_includes outcome.fetch("reason"), "its saved session can no longer be replayed to the model"
    assert_includes outcome.fetch("reason"), "fails the same way every time"
    assert_equal message, outcome.fetch("error_message")
  end

  # The same rejection wording routed through a proxy that says "expected `thinking`" instead. It is
  # still the transcript being refused, and the word "proxy" in the text must not make it look like a
  # network failure.
  def test_an_expected_thinking_block_rejection_is_also_unreplayable_and_not_a_network_failure
    outcome = outcome_for([
                            assistant_line(
                              stop_reason: "error",
                              error_message: "proxy returned 400: messages.3: Expected `thinking` or `redacted_thinking`, but found `text`"
                            )
                          ])

    assert_equal "unreplayable_session", outcome.fetch("kind")
    assert_equal "fresh_session", outcome.fetch("recovery")
  end

  def test_a_transport_failure_carries_no_fresh_session_recovery_hint
    outcome = outcome_for([assistant_line(stop_reason: "error", error_message: "Connection error.")])

    refute outcome.key?("recovery"), "a dropped connection is recovered by resuming the same session"
  end

  def test_a_failed_turn_without_an_error_message_still_reports_a_reason
    outcome = outcome_for([assistant_line(stop_reason: "error")])

    assert_equal "failed", outcome.fetch("state")
    assert_equal "its model request failed mid-turn", outcome.fetch("reason")
  end

  def test_a_finished_turn_reports_a_completed_outcome
    outcome = outcome_for([])

    assert_equal "completed", outcome.fetch("state")
    assert_equal "endTurn", outcome.fetch("stop_reason")
    assert_equal "worker finished the task", outcome.fetch("last_assistant_text")
  end

  def test_interactive_outcome_reports_only_a_terminal_turn_newer_than_the_handoff_checkpoint
    path = pi_session_file(tmpdir)
    ref = pi_session_ref(session_file: path)
    checkpoint = client.turn_outcome(ref)
    handoff = { "handoff" => { "turn_checkpoint" => checkpoint } }

    assert_nil client.interactive_turn_outcome(ref, handoff: handoff)

    File.open(path, "a") do |file|
      file.puts user_line
      file.puts assistant_line(
        stop_reason: "endTurn",
        text: "finished while focused",
        id: "m11",
        parent_id: "m10",
        timestamp: "2026-01-01T00:07:00Z"
      )
    end
    outcome = client.interactive_turn_outcome(ref, handoff: handoff)

    assert_equal "completed", outcome.fetch("state")
    assert_equal "finished while focused", outcome.fetch("last_assistant_text")
  end

  def test_a_previous_turn_result_is_not_used_after_a_new_prompt_without_a_result
    path = pi_session_file(tmpdir, extra_lines: [user_line])
    ref = pi_session_ref(session_file: path)

    assert_nil client.turn_outcome(ref), "the previous assistant message is not the current turn's result"
    assert_nil client.last_assistant_text(ref), "stale previous-turn text must not settle the worker"
    error = assert_raises(PiClient::ProcessExitedError) { client.get_state(ref) }
    assert_match(/no live process and no completed assistant response/, error.message)
  end

  def test_a_result_after_the_new_prompt_is_still_reported_as_the_current_completion
    path = pi_session_file(
      tmpdir,
      extra_lines: [
        user_line,
        assistant_line(
          stop_reason: "endTurn",
          text: "finished the continuation",
          id: "m11",
          parent_id: "m10",
          timestamp: "2026-01-01T00:07:00Z"
        )
      ]
    )

    outcome = client.turn_outcome(pi_session_ref(session_file: path))

    assert_equal "completed", outcome.fetch("state")
    assert_equal "finished the continuation", outcome.fetch("last_assistant_text")
  end

  def test_a_turn_stopped_on_a_pending_tool_call_is_incomplete_but_not_a_failure
    outcome = outcome_for([assistant_line(stop_reason: "toolUse")])

    assert_equal "incomplete", outcome.fetch("state")
    assert_equal "pending_tool_call", outcome.fetch("kind")
  end

  def test_an_aborted_assistant_checkpoint_is_not_a_final_result
    path = pi_session_file(
      tmpdir,
      extra_lines: [assistant_line(
        stop_reason: "aborted",
        text: "I was still working when focus changed.",
        id: "m11",
        parent_id: "m10"
      )]
    )
    ref = pi_session_ref(session_file: path)
    outcome = client.turn_outcome(ref)

    assert_equal "incomplete", outcome.fetch("state")
    assert_equal "interrupted_turn", outcome.fetch("kind")
    assert_equal "aborted", outcome.fetch("stop_reason")
    refute outcome.key?("last_assistant_text")
    assert_raises(PiClient::ProcessExitedError) { client.get_state(ref) }
  end

  # A recovered session ends with a real answer, so the earlier failure must not
  # keep the worker errored forever.
  def test_a_recovered_turn_after_a_failure_reports_the_recovered_completion
    outcome = outcome_for(
      [
        assistant_line(stop_reason: "error", error_message: "Connection error.", id: "m9"),
        assistant_line(stop_reason: "endTurn", text: "recovered and shipped the fix", id: "m10", parent_id: "m9")
      ]
    )

    assert_equal "completed", outcome.fetch("state")
    assert_equal "recovered and shipped the fix", outcome.fetch("last_assistant_text")
  end

  # Session files grow to megabytes and reconciliation runs every couple of
  # seconds, so only the tail is read. The classification must still be right.
  def test_only_the_session_file_tail_is_read_and_the_last_turn_still_classifies
    padding = Array.new(80) do |index|
      JSON.generate(
        "type" => "message",
        "id" => "pad-#{index}",
        "parentId" => "m2",
        "timestamp" => "2026-01-01T00:04:00Z",
        "message" => { "role" => "toolResult", "toolName" => "bash", "content" => [{ "type" => "text", "text" => "x" * 2_000 }] }
      )
    end
    path = pi_session_file(tmpdir, extra_lines: padding + [assistant_line(stop_reason: "error", error_message: "socket hang up")])

    assert_operator File.size(path), :>, PiClient::TURN_OUTCOME_TAIL_BYTES, "fixture must be larger than the tail window"

    outcome = client.turn_outcome(pi_session_ref(session_file: path))

    assert_equal "failed", outcome.fetch("state")
    assert_equal "network_failure", outcome.fetch("kind")
    assert_equal "socket hang up", outcome.fetch("error_message")
  end

  def test_no_evidence_is_reported_when_the_session_file_is_unavailable
    assert_nil client.turn_outcome(pi_session_ref(session_file: File.join(tmpdir, "missing.jsonl"), session_id: "gone"))
  end

  def test_a_session_without_an_assistant_message_reports_no_evidence
    path = File.join(tmpdir, "empty.jsonl")
    File.write(path, "#{JSON.generate("type" => "session", "id" => "sess-1", "cwd" => tmpdir)}\n")

    assert_nil client.turn_outcome(pi_session_ref(session_file: path))
  end

  def test_a_corrupt_session_line_does_not_raise
    path = pi_session_file(tmpdir, extra_lines: ["{not json", assistant_line(stop_reason: "error", error_message: "ETIMEDOUT")])

    outcome = client.turn_outcome(pi_session_ref(session_file: path))

    assert_equal "failed", outcome.fetch("state")
    assert_equal "network_failure", outcome.fetch("kind")
  end

  # Every harness must answer the question; only clients with real evidence say
  # anything, so the kernel keeps its existing behaviour elsewhere.
  def test_clients_without_turn_evidence_report_nothing
    assert_nil Meringue::Harness::FakeClient.new.turn_outcome("session_id" => "fake")
    assert_nil Meringue::Harness::Client.new.turn_outcome("session_id" => "abstract")
  end
end
