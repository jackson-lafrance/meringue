# frozen_string_literal: true

require "test_helper"
require "support/heads_support"

# A worker that errored because its turn was cut short by a transport failure still owns a
# resumable session, worktree, and branch. Heads must be able to tell it apart from a worker
# that genuinely failed, or the recovery path is "spawn a new worker and abandon the work".
class HeadStoppedWorkerRoutingTest < Minitest::Test
  include HeadsSupport

  SETTLE_FAILURE = {
    "kind" => "network_failure",
    "reason" => "its model request failed mid-turn (network error: Connection error.)",
    "source" => "harness_turn_outcome",
    "stop_reason" => "error",
    "error_message" => "Connection error."
  }.freeze

  def worker_candidate(status:, metadata_overrides: {})
    snapshot = head_snapshot
    worker = snapshot.fetch("agents").first
    worker["status"] = status
    worker["harness_metadata"] = worker.fetch("harness_metadata").merge(metadata_overrides)
    build_head_context(snapshot: snapshot).to_prompt_h.dig("routing_context", "worker_candidates").first
  end

  def test_a_worker_stopped_by_a_transport_failure_is_offered_as_resumable
    candidate = worker_candidate(
      status: "errored",
      metadata_overrides: {
        "settle_state" => "failed",
        "settle_failure" => SETTLE_FAILURE,
        "status_reason" => "errored without finishing: #{SETTLE_FAILURE.fetch("reason")}"
      }
    )

    assert candidate.fetch("resumable")
    assert candidate.fetch("stopped_without_finishing")
    assert_equal ["normal"], candidate.fetch("supported_prompt_modes_now")
    assert_equal "normal", candidate.fetch("recommended_prompt_mode")
    assert_includes candidate.fetch("status_reason"), "network error: Connection error."
  end

  def test_an_ordinary_errored_worker_is_still_terminal_for_routing
    candidate = worker_candidate(status: "errored", metadata_overrides: { "error_message" => "spawn failed" })

    refute candidate.fetch("resumable")
    refute candidate.key?("stopped_without_finishing")
    assert_empty candidate.fetch("supported_prompt_modes_now")
  end

  def test_a_killed_worker_is_never_resumable_even_with_a_recorded_dead_turn
    candidate = worker_candidate(status: "killed", metadata_overrides: { "settle_failure" => SETTLE_FAILURE })

    refute candidate.fetch("resumable")
    assert_empty candidate.fetch("supported_prompt_modes_now")
  end

  def test_a_healthy_worker_is_unchanged
    candidate = worker_candidate(status: "idle")

    assert candidate.fetch("resumable")
    refute candidate.key?("stopped_without_finishing")
  end
end
