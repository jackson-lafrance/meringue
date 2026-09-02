# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# A harness turn that stops streaming has not necessarily finished its work. When the
# user's wifi drops mid-turn the session settles with no final assistant message, and
# Meringue used to record that as a completion: five workers were logged "completed",
# their issues were flipped to `completed`, and the dashboard claimed finished work
# that was actually mid-flight. These tests pin the classification instead.
class KernelWorkersSettleClassificationTest < Minitest::Test
  include KernelWorkersSupport

  # Harness that reports a turn outcome the way Pi does: the last turn either finished
  # or died, independently of the session no longer streaming.
  class TurnOutcomeHarnessClient < RecordingHarnessClient
    attr_accessor :outcome

    def initialize(outcome: nil, **options)
      super(**options)
      @outcome = outcome
    end

    def turn_outcome(_session_ref)
      @outcome
    end
  end

  # Harness that cannot report a turn outcome at all; the kernel must fall back to the
  # session events plus the missing final message.
  class EventOnlyHarnessClient < RecordingHarnessClient
    undef_method :turn_outcome
  end

  # Harness that attaches the turn outcome to the session ref metadata instead of
  # answering a client call, which is the other supported evidence channel.
  class MetadataOutcomeHarnessClient < RecordingHarnessClient
    attr_accessor :outcome

    def initialize(outcome: nil, **options)
      super(**options)
      @outcome = outcome
    end

    def get_state(session_ref)
      ref = super
      ref.merge("metadata" => (ref.fetch("metadata", {}) || {}).merge("turn_outcome" => @outcome))
    end
  end

  # Interactive providers can return a settled state after their PTY has exited. The process exit
  # marker is the only failure evidence when the transcript contains no final assistant response.
  class ProcessGoneStateHarnessClient < RecordingHarnessClient
    undef_method :turn_outcome if method_defined?(:turn_outcome)

    def get_state(session_ref)
      ref = super
      ref.merge(
        "pid" => nil,
        "is_streaming" => false,
        "metadata" => (ref.fetch("metadata", {}) || {}).merge(
          "process_gone" => true,
          "exit_status" => { "success" => false, "exit_code" => 42 }
        )
      )
    end
  end

  NETWORK_FAILURE = {
    "state" => "failed",
    "kind" => "network_failure",
    "reason" => "its model request failed mid-turn (network error: Connection error.)",
    "stop_reason" => "error",
    "error_message" => "Connection error."
  }.freeze

  INCOMPLETE_TURN = {
    "state" => "incomplete",
    "kind" => "pending_tool_call",
    "reason" => "its last turn stopped while a tool call was still pending",
    "stop_reason" => "toolUse"
  }.freeze

  def build_worker(client)
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    [engine, context, worker_id]
  end

  def network_aborted_client
    TurnOutcomeHarnessClient.new(provider: "pi", outcome: NETWORK_FAILURE).tap do |client|
      client.last_assistant_text = ""
    end
  end

  def incomplete_turn_client
    TurnOutcomeHarnessClient.new(provider: "pi", outcome: INCOMPLETE_TURN).tap do |client|
      # Partial assistant text must not make a pending tool call look like a final result.
      client.last_assistant_text = "I started checking the repository."
    end
  end

  def test_human_input_request_blocks_worker_without_settling_or_recovering
    client = RecordingHarnessClient.new(provider: "pi")
    client.events = [{ "type" => "approval_request", "message" => "Approve the command" }]
    client.define_singleton_method(:human_input_requests) do |events|
      Meringue::Harness::HumanInput.requests(events)
    end
    engine, context, worker_id = build_worker(client)

    result = apply!(engine, "ReconcileSessions", {})
    poll = result.dig("result", "poll_results").first
    worker = agent(engine, worker_id)

    assert_equal "working", poll.fetch("state")
    assert_equal "blocked", worker.fetch("status")
    assert_equal "pending", worker.dig("harness_metadata", "human_input_request", "state")
    assert_equal "Approve the command", worker.dig("harness_metadata", "human_input_request", "message")
    assert_nil worker.dig("harness_metadata", "settle_failure")
    assert_nil worker.dig("harness_metadata", "self_fixing_recovery")
    assert_equal "blocked", issue(engine, context.fetch("issue_id")).fetch("status")
  end

  def test_a_tool_call_that_stops_before_a_final_result_keeps_the_worker_recoverable
    engine, context, worker_id = build_worker(incomplete_turn_client)

    result = apply!(engine, "ReconcileSessions", {})
    poll = result.dig("result", "poll_results").first
    worker = agent(engine, worker_id)

    assert_equal "recoverable", poll.fetch("state")
    assert_equal "idle", worker.fetch("status")
    assert_nil worker.dig("harness_metadata", "completed_at")
    assert_nil worker.dig("harness_metadata", "settle_failure")
    assert_equal "pending_tool_call", worker.dig("harness_metadata", "incomplete_turn", "kind")
    assert_equal "toolUse", worker.dig("harness_metadata", "incomplete_turn", "stop_reason")
    assert_match(/stopped while a tool call was still pending/, worker.dig("harness_metadata", "status_reason"))
    assert_equal "working", issue(engine, context.fetch("issue_id")).fetch("status")
    refute_includes log_messages(engine), "Worker #{worker_id} completed."
    assert log_messages(engine).any? { |message| message.include?("Worker #{worker_id} stopped while a tool call was pending") }

    prompt = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Continue the pending tool call." })
    assert_equal "accepted", prompt.fetch("status")
    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_nil agent(engine, worker_id).dig("harness_metadata", "incomplete_turn")
  end

  def test_a_tool_call_failure_keeps_the_worker_recoverable_and_its_dependent_queued
    client = incomplete_turn_client
    engine, context, worker_id = build_worker(client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Finish the implementation.",
      after_agent_id: worker_id
    ).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    assert_equal "idle", agent(engine, worker_id).fetch("status")
    assert_equal "queued", agent(engine, dependent_id).fetch("status")
    assert_equal "waiting", agent(engine, dependent_id).dig("harness_metadata", "deferred_spawn", "state")
    assert Dir.exist?(agent(engine, worker_id).fetch("workspace_path")), "the failed turn must not remove its worktree"

    client.outcome = { "state" => "completed", "stop_reason" => "endTurn" }
    client.last_assistant_text = "Finished the tool call and shipped the change."
    prompt = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Continue from the interrupted tool call." })
    assert_equal "accepted", prompt.fetch("status")
    assert_nil agent(engine, worker_id).dig("harness_metadata", "incomplete_turn")
    apply!(engine, "ReconcileSessions", {})

    assert_equal "completed", agent(engine, worker_id).fetch("status")
    assert_equal "working", agent(engine, dependent_id).fetch("status")
    assert_includes log_messages(engine), "Started queued worker #{dependent_id} on #{context.fetch("issue_id")} because #{worker_id} settled (completed)."
  end

  def test_a_network_aborted_turn_settles_the_worker_as_errored_with_a_reason
    engine, context, worker_id = build_worker(network_aborted_client)

    result = apply!(engine, "ReconcileSessions", {})
    poll = result.dig("result", "poll_results").first
    worker = agent(engine, worker_id)
    metadata = worker.fetch("harness_metadata")

    assert_equal "settle_failed", poll.fetch("state")
    assert_equal "errored", worker.fetch("status")
    assert_nil metadata["completed_at"], "an aborted turn must not look like a completion"
    assert_equal "failed", metadata.fetch("settle_state")
    assert_equal "network_failure", metadata.dig("settle_failure", "kind")
    assert_equal "harness_turn_outcome", metadata.dig("settle_failure", "source")
    assert_equal "Connection error.", metadata.dig("settle_failure", "error_message")
    assert_match(/network error: Connection error\./, metadata.fetch("error_message"))
    assert_equal(
      "errored without finishing: its model request failed mid-turn (network error: Connection error.)",
      metadata.fetch("status_reason")
    )
    refute metadata.fetch("is_streaming")

    refute_includes log_messages(engine), "Worker #{worker_id} completed."
    error_log = state(engine).fetch("logs").find { |entry| entry.fetch("source_id", nil) == worker_id && entry.fetch("level") == "error" }
    refute_nil error_log, "the user needs a visible error log line"
    assert_equal(
      "Worker #{worker_id} errored without finishing: its model request failed mid-turn (network error: Connection error.)",
      error_log.fetch("message")
    )
    assert error_log.dig("details", "recoverable")
    assert_equal context.fetch("issue_id"), error_log.dig("details", "issue_id")
  end

  def test_a_network_aborted_worker_never_completes_its_issue_or_project
    engine, context, = build_worker(network_aborted_client)

    apply!(engine, "ReconcileSessions", {})

    assert_equal "errored", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_equal "errored", project(engine, context.fetch("project_id")).fetch("status")
  end

  def test_one_aborted_worker_keeps_a_mixed_issue_out_of_completed
    client = network_aborted_client
    engine, context, aborted_id = build_worker(client)
    finished_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Second pass.").fetch("target_id")

    # The second worker really did finish, before the outage hit the first one.
    client.outcome = { "state" => "completed", "stop_reason" => "endTurn" }
    client.last_assistant_text = "Shipped the fix in a pull request."
    apply!(engine, "ReconcileSessions", {})

    assert_equal "completed", agent(engine, finished_id).fetch("status")
    assert_equal "completed", agent(engine, aborted_id).fetch("status"),
                 "both workers settle from the same scripted outcome in this pass"

    # Now replay the incident: a second worker on the issue dies mid-turn.
    third_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Third pass.").fetch("target_id")
    client.outcome = NETWORK_FAILURE
    client.last_assistant_text = ""
    apply!(engine, "ReconcileSessions", {})

    assert_equal "errored", agent(engine, third_id).fetch("status")
    refute_equal "completed", issue(engine, context.fetch("issue_id")).fetch("status"),
                 "an issue must not be completed on the back of a worker that died mid-turn"
    assert_equal "errored", issue(engine, context.fetch("issue_id")).fetch("status")
  end

  def test_a_finished_turn_still_settles_the_worker_as_completed
    client = TurnOutcomeHarnessClient.new(provider: "pi", outcome: { "state" => "completed", "stop_reason" => "endTurn" })
    client.last_assistant_text = "Shipped the fix in a pull request."
    engine, context, worker_id = build_worker(client)

    result = apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal "completed", result.dig("result", "poll_results").first.fetch("state")
    assert_equal "completed", worker.fetch("status")
    assert_equal "Shipped the fix in a pull request.", worker.dig("harness_metadata", "last_assistant_text")
    refute_nil worker.dig("harness_metadata", "completed_at")
    assert_nil worker.dig("harness_metadata", "settle_failure")
    assert_equal "completed", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_includes log_messages(engine), "Worker #{worker_id} completed."
  end

  def test_repeated_settlement_clears_a_stale_streaming_flag_on_a_terminal_worker
    client = TurnOutcomeHarnessClient.new(provider: "pi", outcome: { "state" => "completed", "stop_reason" => "endTurn" })
    client.last_assistant_text = "Done."
    engine, _context, worker_id = build_worker(client)
    apply!(engine, "ReconcileSessions", {})
    patch_agent!(worker_id) { |record| record.fetch("harness_metadata")["is_streaming"] = true }

    result = engine.mark_worker_completed(agent_id: worker_id, last_assistant_text: "Done.")

    assert_equal "accepted", result.fetch("status")
    assert_equal "completed", agent(engine, worker_id).fetch("status")
    assert_equal false, agent(engine, worker_id).dig("harness_metadata", "is_streaming")
  end

  def test_a_harness_without_turn_evidence_still_completes_a_settled_worker
    client = EventOnlyHarnessClient.new(provider: "pi")
    client.last_assistant_text = "Delivered the change."
    engine, _context, worker_id = build_worker(client)

    apply!(engine, "ReconcileSessions", {})

    assert_equal "completed", agent(engine, worker_id).fetch("status")
  end

  def test_a_transport_event_without_a_final_message_settles_the_worker_as_errored
    client = EventOnlyHarnessClient.new(provider: "pi")
    client.events = [{ "type" => "process_exit", "pid" => 4321, "status" => { "success" => false, "exit_code" => 1 } }]
    client.last_assistant_text = nil
    engine, _context, worker_id = build_worker(client)

    apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal "errored", worker.fetch("status")
    assert_equal "transport_failure", worker.dig("harness_metadata", "settle_failure", "kind")
    assert_equal "harness_events", worker.dig("harness_metadata", "settle_failure", "source")
    assert_equal "process_exit", worker.dig("harness_metadata", "settle_failure", "event_type")
    assert_includes log_messages(engine), "Worker #{worker_id} errored without finishing: its agent session ended before it produced a result"
  end

  def test_a_failed_turn_event_without_a_final_message_settles_the_worker_as_errored
    client = EventOnlyHarnessClient.new(provider: "pi")
    client.events = [
      { "type" => "message_end", "message" => { "role" => "assistant", "stopReason" => "error", "errorMessage" => "fetch failed" } },
      { "type" => "agent_settled" }
    ]
    client.last_assistant_text = ""
    engine, _context, worker_id = build_worker(client)

    apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal "errored", worker.fetch("status")
    assert_equal "network_failure", worker.dig("harness_metadata", "settle_failure", "kind")
    assert_equal "fetch failed", worker.dig("harness_metadata", "settle_failure", "error_message")
  end

  # A worker can legitimately finish and then have its transport close. The final
  # assistant message is what makes that a completion.
  def test_a_process_exit_after_a_real_result_is_still_a_completion
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    result = engine.mark_worker_completed(
      agent_id: worker_id,
      harness_events: [{ "type" => "process_exit", "status" => "0" }],
      last_assistant_text: "Fixed the redirect and opened a PR."
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal "completed", agent(engine, worker_id).fetch("status")
    assert_equal "completed", issue(engine, context.fetch("issue_id")).fetch("status")
  end

  def test_a_gone_interactive_process_without_a_final_response_is_not_a_completion
    client = ProcessGoneStateHarnessClient.new(provider: "pi")
    engine, context, worker_id = build_worker(client)

    result = apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)
    failure = worker.dig("harness_metadata", "settle_failure")

    assert_equal "settle_failed", result.dig("result", "poll_results").first.fetch("state")
    assert_equal "errored", worker.fetch("status")
    assert_equal "harness_process_exited", failure.fetch("kind")
    assert_equal "harness_process_exit", failure.fetch("source")
    assert_equal 42, failure.dig("exit_status", "exit_code")
    assert_match(/process exited before it produced a result/, failure.fetch("reason"))
    assert_equal "errored", issue(engine, context.fetch("issue_id")).fetch("status")
    refute_includes log_messages(engine), "Worker #{worker_id} completed."
  end

  def test_a_turn_outcome_on_the_session_ref_metadata_is_also_honoured
    client = MetadataOutcomeHarnessClient.new(provider: "pi", outcome: NETWORK_FAILURE)
    client.last_assistant_text = ""
    engine, _context, worker_id = build_worker(client)

    apply!(engine, "ReconcileSessions", {})

    assert_equal "errored", agent(engine, worker_id).fetch("status")
    assert_equal "network_failure", agent(engine, worker_id).dig("harness_metadata", "settle_failure", "kind")
  end

  # Reconciliation polls every couple of seconds. Re-observing the same dead turn must
  # not append another log line or churn the record.
  def test_repeated_reconciliation_does_not_relog_the_same_dead_turn
    engine, _context, worker_id = build_worker(network_aborted_client)

    apply!(engine, "ReconcileSessions", {})
    errored_at = agent(engine, worker_id).dig("harness_metadata", "errored_at")
    later = 3.times.map { apply!(engine, "ReconcileSessions", {}) }

    assert_equal 1, logs_matching(engine, /errored without finishing/).length
    assert_equal 1, state(engine).fetch("logs").count { |entry| entry.fetch("level") == "error" }
    assert_equal errored_at, agent(engine, worker_id).dig("harness_metadata", "errored_at")
    later.each do |result|
      poll = result.dig("result", "poll_results").first
      assert_equal "settle_failed", poll.fetch("state")
      refute poll.fetch("changed"), "re-observing a recorded dead turn is not a change"
    end
  end

  def test_an_errored_worker_from_a_dead_turn_stays_recoverable
    client = network_aborted_client
    engine, _context, worker_id = build_worker(client)
    apply!(engine, "ReconcileSessions", {})
    before = agent(engine, worker_id)

    assert_equal "errored", before.fetch("status")

    prompt = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Your turn was cut off; continue." })
    after = agent(engine, worker_id)

    assert_equal "accepted", prompt.fetch("status")
    assert_equal "working", after.fetch("status")
    assert_nil after.dig("harness_metadata", "settle_failure")
    assert_nil after.dig("harness_metadata", "status_reason")
    assert_nil after.dig("harness_metadata", "settle_state")
    assert_equal "network_failure", after.dig("harness_metadata", "previous_settle_failure", "kind")
    # The workspace the worker was mid-flight in must survive untouched.
    assert_equal before.fetch("workspace_path"), after.fetch("workspace_path")
    assert_equal before.fetch("workspace_branch"), after.fetch("workspace_branch")
    assert Dir.exist?(after.fetch("workspace_path")), "the worktree must not be removed by an errored settle"
    assert_equal "working", issue(engine, before.fetch("issue_id")).fetch("status")
  end

  def test_an_errored_worker_whose_session_is_gone_is_still_not_resumable
    engine, _context, worker_id = build_worker(network_aborted_client)
    apply!(engine, "ReconcileSessions", {})
    patch_agent!(worker_id) do |record|
      record["pid"] = nil
      record["harness_session_id"] = nil
      record["harness_session_file"] = nil
    end

    result = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Continue." })

    assert_equal "rejected", result.fetch("status")
  end

  # A prompt queued while the worker was mid-turn is user intent. Losing it because the
  # turn then died from a dropped connection is the same class of bug as the false
  # completion, so the queued prompt is redelivered once the session can take it.
  def test_a_prompt_queued_before_the_outage_is_still_delivered_afterwards
    client = network_aborted_client
    engine, _context, worker_id = build_worker(client)
    client.prompt_error = BusySessionError.new("session is busy mid-turn")

    queued = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Also update the docs." })

    assert queued.dig("result", "queued")
    assert_equal 1, agent(engine, worker_id).dig("harness_metadata", "pending_prompts").length

    apply!(engine, "ReconcileSessions", {})

    assert_equal "errored", agent(engine, worker_id).fetch("status")
    assert_equal 1, agent(engine, worker_id).dig("harness_metadata", "pending_prompts").length,
                 "the queued prompt must survive the errored settle"

    client.prompt_error = nil
    apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal "working", worker.fetch("status")
    assert_empty Array(worker.dig("harness_metadata", "pending_prompts"))
    assert_includes client.prompts.map { |call| call.fetch("prompt") }, "Also update the docs."
  end

  def test_a_settled_worker_that_streams_again_clears_the_dead_turn_reason
    client = network_aborted_client
    engine, _context, worker_id = build_worker(client)
    apply!(engine, "ReconcileSessions", {})

    assert_equal "errored", agent(engine, worker_id).fetch("status")

    # Something outside Meringue resumed the session: it is streaming again.
    client.streaming = true
    apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal "working", worker.fetch("status")
    assert_nil worker.dig("harness_metadata", "settle_failure")
    assert_nil worker.dig("harness_metadata", "status_reason")
  end

  # A worker queued behind another one (`after_agent_id`) must not be cancelled by a wifi blip:
  # its predecessor did not fail its work, it stopped mid-turn and can still be continued.
  def test_a_dependent_queued_behind_an_aborted_worker_keeps_waiting
    client = network_aborted_client
    engine, context, predecessor_id = build_worker(client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Ship what the first worker found.",
      after_agent_id: predecessor_id
    ).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    assert_equal "errored", agent(engine, predecessor_id).fetch("status")
    refute_nil agent(engine, dependent_id), "a recoverable dead turn must not cancel the queued dependent"
    assert_equal "queued", agent(engine, dependent_id).fetch("status")
    assert_equal "waiting", agent(engine, dependent_id).dig("harness_metadata", "deferred_spawn", "state")
    refute_includes log_messages(engine), "Cancelled queued worker #{dependent_id} because #{predecessor_id} errored before it could start."

    # Recovering the predecessor resumes the chain.
    client.prompt_error = nil
    apply!(engine, "PromptAgent", { "agent_id" => predecessor_id, "prompt" => "Your turn was cut off; continue." })
    client.outcome = { "state" => "completed", "stop_reason" => "endTurn" }
    client.last_assistant_text = "Finished after the reconnect."
    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Finished after the reconnect.")

    assert_equal "completed", agent(engine, predecessor_id).fetch("status")
    assert_equal "working", agent(engine, dependent_id).fetch("status")
    assert_includes log_messages(engine), "Started queued worker #{dependent_id} on #{context.fetch("issue_id")} because #{predecessor_id} settled (completed)."
  end

  def test_a_run_anyway_dependent_still_starts_when_the_predecessor_turn_dies
    client = network_aborted_client
    engine, context, predecessor_id = build_worker(client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Do the follow-up regardless.",
      after_agent_id: predecessor_id,
      if_predecessor_fails: "run"
    ).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    assert_equal "errored", agent(engine, predecessor_id).fetch("status")
    assert_equal "working", agent(engine, dependent_id).fetch("status")
  end

  # Upstream behaviour that must survive: an emergency stop still stops the queue behind it.
  def test_killing_an_aborted_worker_still_cancels_its_dependent
    engine, context, predecessor_id = build_worker(network_aborted_client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Ship it.",
      after_agent_id: predecessor_id
    ).fetch("target_id")
    apply!(engine, "ReconcileSessions", {})

    apply!(engine, "Kill", { "target_id" => predecessor_id })

    assert_nil agent(engine, dependent_id)
    assert_includes(
      log_messages(engine),
      "Cancelled queued worker #{dependent_id} because #{predecessor_id} was killed before it could start."
    )
  end

  def test_a_worker_can_be_queued_behind_an_already_aborted_worker
    engine, context, predecessor_id = build_worker(network_aborted_client)
    apply!(engine, "ReconcileSessions", {})

    assert_equal "errored", agent(engine, predecessor_id).fetch("status")

    result = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id)
    dependent = agent(engine, result.fetch("target_id"))

    assert_equal "queued", dependent.fetch("status")
    assert_equal predecessor_id, dependent.fetch("after_agent_id")
  end

  # An ordinary errored predecessor (no recoverable session) still cancels its dependent.
  def test_a_dependent_behind_an_unrecoverable_errored_worker_is_still_cancelled
    engine, context, predecessor_id = build_worker(network_aborted_client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Ship it.",
      after_agent_id: predecessor_id
    ).fetch("target_id")
    apply!(engine, "ReconcileSessions", {})
    patch_agent!(predecessor_id) do |record|
      record["pid"] = nil
      record["harness_session_id"] = nil
      record["harness_session_file"] = nil
    end

    apply!(engine, "ReconcileSessions", {})

    assert_nil agent(engine, dependent_id)
    assert_includes(
      log_messages(engine),
      "Cancelled queued worker #{dependent_id} because #{predecessor_id} errored before it could start."
    )
  end

  def test_documented_status_vocabulary_is_used
    engine, _context, worker_id = build_worker(network_aborted_client)
    apply!(engine, "ReconcileSessions", {})

    statuses = state(engine).fetch("agents").map { |record| record.fetch("status") } +
               state(engine).fetch("issues").map { |record| record.fetch("status") } +
               state(engine).fetch("projects").map { |record| record.fetch("status") }

    statuses.each { |status| assert_includes Meringue::State::Models::LIFECYCLE_STATUSES, status }
    assert_equal "errored", agent(engine, worker_id).fetch("status")
  end
end
