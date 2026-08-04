# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Worker lifecycle transitions: completion (with last-result capture), reconciliation
# blocked/errored states, and how those roll up to the parent issue and project.
class KernelWorkersTransitionsTest < Minitest::Test
  include KernelWorkersSupport

  def test_completion_captures_the_last_result_and_rolls_up_to_issue_and_project
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    result = engine.mark_worker_completed(
      agent_id: worker_id,
      harness_events: [{ "type" => "process_exit", "status" => "0" }],
      last_assistant_text: "Fixed the login redirect and added a regression test."
    )
    worker = agent(engine, worker_id)

    assert_equal "accepted", result.fetch("status")
    assert_equal "completed", worker.fetch("status")
    assert_equal(
      "Fixed the login redirect and added a regression test.",
      worker.fetch("harness_metadata").fetch("last_assistant_text")
    )
    assert_equal 1, worker.fetch("harness_metadata").fetch("settled_event_count")
    assert_equal false, worker.fetch("harness_metadata").fetch("is_streaming")
    refute_nil worker.fetch("harness_metadata").fetch("completed_at")

    assert_equal "completed", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_equal "completed", project(engine, context.fetch("project_id")).fetch("status")

    completion_log = state(engine).fetch("logs").find { |entry| entry.fetch("message") == "Worker #{worker_id} completed." }
    refute_nil completion_log
    assert_equal(
      "Fixed the login redirect and added a regression test.",
      completion_log.fetch("details").fetch("last_assistant_text")
    )
    assert_equal context.fetch("issue_id"), completion_log.fetch("details").fetch("issue_id")
    assert_includes log_messages(engine), "#{worker_id} agent session process_exit."
  end

  def test_completing_an_already_completed_worker_is_idempotent
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    engine.mark_worker_completed(agent_id: worker_id, last_assistant_text: "Done.")

    result = engine.mark_worker_completed(agent_id: worker_id, last_assistant_text: "Done again.")

    assert_equal "accepted", result.fetch("status")
    assert_includes result.fetch("message"), "is already completed"
    assert_equal "Done.", agent(engine, worker_id).fetch("harness_metadata").fetch("last_assistant_text")
    assert_equal 1, logs_matching(engine, /Worker #{worker_id} completed\./).length
  end

  def test_completing_an_unknown_agent_is_rejected
    engine = build_engine

    result = engine.mark_worker_completed(agent_id: "P1-I1-W1")

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_not_found"
  end

  def test_reconciliation_completes_a_settled_worker_session
    client = RecordingHarnessClient.new(provider: "pi")
    client.last_assistant_text = "Shipped the fix in a pull request."
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    reconcile = apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal 1, reconcile.fetch("result").fetch("checked_count")
    assert_equal "completed", worker.fetch("status")
    assert_equal "Shipped the fix in a pull request.", worker.fetch("harness_metadata").fetch("last_assistant_text")
    assert_equal "completed", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_includes log_messages(engine), "Worker #{worker_id} completed."
  end

  def test_unresumable_session_blocks_the_worker_then_errors_it_after_retries
    client = BrokenSessionClient.new(provider: "pi")
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})
    blocked = agent(engine, worker_id)

    assert_equal "blocked", blocked.fetch("status")
    assert_equal "resume_failed", blocked.fetch("harness_metadata").fetch("reconcile_state")
    assert_equal 1, blocked.fetch("harness_metadata").fetch("reconcile").fetch("resume_attempt_count")
    assert_equal "blocked", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_includes log_messages(engine), "Worker #{worker_id} could not resume its agent session; will retry reconciliation."

    apply!(engine, "ReconcileSessions", {})
    apply!(engine, "ReconcileSessions", {})
    errored = agent(engine, worker_id)

    assert_equal "errored", errored.fetch("status")
    assert_equal "terminal_error", errored.fetch("harness_metadata").fetch("reconcile_state")
    assert_equal "IOError", errored.fetch("harness_metadata").fetch("error_class")
    assert_equal "errored", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_equal "errored", project(engine, context.fetch("project_id")).fetch("status")
  end

  def test_an_errored_worker_is_no_longer_reconciled
    client = BrokenSessionClient.new(provider: "pi")
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    3.times { apply!(engine, "ReconcileSessions", {}) }

    assert_equal "errored", agent(engine, worker_id).fetch("status")

    final = apply!(engine, "ReconcileSessions", {})

    assert_equal 0, final.fetch("result").fetch("checked_count")
  end

  def test_completed_and_killed_workers_are_not_reconciled
    client = RecordingHarnessClient.new(provider: "pi")
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    completed_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    engine.mark_worker_completed(agent_id: completed_id, last_assistant_text: "Done.")

    reconcile = apply!(engine, "ReconcileSessions", {})

    assert_equal 0, reconcile.fetch("result").fetch("checked_count")
    assert_equal "completed", agent(engine, completed_id).fetch("status")
  end
end
