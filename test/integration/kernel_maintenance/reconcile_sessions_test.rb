# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# ReconcileSessions inspects tracked harness sessions and updates lifecycle state
# from the evidence it can observe: live vs dead pids, readable vs missing
# session files, resumable vs unresumable transports.
class KernelMaintenanceReconcileSessionsTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def stub_engine(sessions, attach_support: true)
    client = if attach_support
               StubHarnessClient.new(sessions: sessions)
             else
               StubHarnessClientWithoutAttach.new(sessions: sessions)
             end
    engine = build_engine(harness_client_resolver: ->(_agent) { client })
    [engine, client]
  end

  def live_session_file
    path = tmp_path("sessions", "live.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate({ "messages" => [] }))
    path
  end

  def state_with_worker(status: "working", pid: nil, session_id: "sess-1", session_file: nil, harness_metadata: {})
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: ["P1-I1-W1"])],
        agents: [
          worker_record(
            id: "P1-I1-W1",
            issue_id: "P1-I1",
            project_id: "P1",
            status: status,
            harness: "pi",
            pid: pid,
            session_id: session_id,
            session_file: session_file,
            harness_metadata: harness_metadata
          )
        ]
      )
    )
  end

  def test_streaming_session_keeps_the_worker_working_and_marks_it_healthy
    state_with_worker(pid: Process.pid.to_s, session_file: live_session_file)
    engine, client = stub_engine({ "sess-1" => { "streaming" => true, "events" => [{ "type" => "agent_start" }] } })

    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal "accepted", result.fetch("status")
    assert_equal 1, result.dig("result", "checked_count")
    poll = result.dig("result", "poll_results").first
    assert_equal "working", poll.fetch("state")

    worker = agent_by_id(read_state, "P1-I1-W1")
    assert_equal "working", worker.fetch("status")
    assert_equal "healthy", worker.dig("harness_metadata", "reconcile_state")
    assert_includes client.calls, ["get_state", "sess-1"]
  end

  def test_settled_session_completes_the_worker_and_rolls_status_up
    state_with_worker(pid: Process.pid.to_s, session_file: live_session_file)
    engine, = stub_engine({ "sess-1" => { "streaming" => false, "completed" => true, "last_assistant_text" => "done" } })

    result = apply_command(engine, "ReconcileSessions", {})

    poll = result.dig("result", "poll_results").first
    assert_equal "completed", poll.fetch("state")

    state = read_state
    assert_equal "completed", agent_by_id(state, "P1-I1-W1").fetch("status")
    assert_equal "completed", issue_by_id(state, "P1-I1").fetch("status")
    assert_documented_status_vocabulary(state)
  end

  def test_dead_pid_without_resumable_transport_errors_the_worker
    dead_pid = reaped_pid
    refute Meringue::Harness::ProcessIdentity.alive?(dead_pid), "test fixture pid should already be reaped"
    state_with_worker(pid: dead_pid.to_s, session_file: live_session_file)
    engine, = stub_engine({ "sess-1" => { "require_live_pid" => true } }, attach_support: false)

    result = apply_command(engine, "ReconcileSessions", {})

    poll = result.dig("result", "poll_results").first
    assert_equal "errored", poll.fetch("state")

    state = read_state
    worker = agent_by_id(state, "P1-I1-W1")
    assert_equal "errored", worker.fetch("status")
    assert_equal "terminal_error", worker.dig("harness_metadata", "reconcile_state")
    assert_equal "terminal_error", worker.dig("harness_metadata", "reconcile", "state")
    assert_match(/is not alive/, worker.dig("harness_metadata", "error_message"))
    assert_equal "errored", issue_by_id(state, "P1-I1").fetch("status")
    error_log = state.fetch("logs").find { |log| log.fetch("level") == "error" }
    assert_match(/errored while reconciling its agent session/, error_log.fetch("message"))
    assert_documented_status_vocabulary(state)
  end

  def test_missing_session_file_is_resumed_when_the_transport_can_be_attached
    state_with_worker(pid: Process.pid.to_s, session_file: tmp_path("sessions", "gone.json"))
    engine, client = stub_engine(
      { "sess-1" => { "require_session_file" => true, "attach_error" => nil } }
    )

    result = apply_command(engine, "ReconcileSessions", {})

    poll = result.dig("result", "poll_results").first
    assert_equal "working", poll.fetch("state")
    assert poll.fetch("resumed")
    assert_equal "resuming", poll.dig("reconcile", "state")
    assert_equal 1, poll.dig("reconcile", "resume_attempt_count")
    assert_includes client.calls, ["attach_session", "sess-1"]
    # A settled resumed session is prompted to continue; a streaming one is not.
    assert_includes client.calls, ["prompt_session", "sess-1", "normal"]

    state = read_state
    assert_equal "working", agent_by_id(state, "P1-I1-W1").fetch("status")
    resume_log = state.fetch("logs").find { |log| log.fetch("message").include?("Resumed agent session for worker") }
    assert_equal "info", resume_log.fetch("level")
  end

  def test_streaming_resumed_session_is_not_reprompted
    state_with_worker(pid: Process.pid.to_s, session_file: tmp_path("sessions", "gone.json"))
    engine, client = stub_engine(
      { "sess-1" => { "require_session_file" => true, "streaming" => true } }
    )

    result = apply_command(engine, "ReconcileSessions", {})

    assert result.dig("result", "poll_results").first.fetch("resumed")
    assert_includes client.calls, ["attach_session", "sess-1"]
    refute_includes client.calls.map(&:first), "prompt_session"
    assert_equal "working", agent_by_id(read_state, "P1-I1-W1").fetch("status")
  end

  def test_worker_that_cannot_be_resumed_is_blocked_and_retried_later
    state_with_worker(pid: Process.pid.to_s, session_file: live_session_file)
    engine, = stub_engine(
      { "sess-1" => { "get_state_error" => "rpc pipe closed", "attach_error" => "cannot attach to session" } }
    )

    result = apply_command(engine, "ReconcileSessions", {})

    poll = result.dig("result", "poll_results").first
    assert poll.fetch("blocked")
    assert_equal "resume_failed", poll.dig("reconcile", "state")

    state = read_state
    worker = agent_by_id(state, "P1-I1-W1")
    assert_equal "blocked", worker.fetch("status")
    assert_equal "resume_failed", worker.dig("harness_metadata", "reconcile_state")
    assert_equal 2, worker.dig("harness_metadata", "reconcile", "resume_attempts_remaining")
    warning = state.fetch("logs").find { |log| log.fetch("message").include?("could not resume its agent session") }
    assert_equal "warning", warning.fetch("level")
    assert_documented_status_vocabulary(state)
  end

  def test_worker_errors_after_the_resume_attempt_budget_is_exhausted
    state_with_worker(
      status: "blocked",
      pid: Process.pid.to_s,
      session_file: live_session_file,
      harness_metadata: {
        "reconcile_state" => "resume_failed",
        "reconcile" => { "state" => "resume_failed", "resume_attempt_count" => 3 }
      }
    )
    engine, client = stub_engine(
      { "sess-1" => { "get_state_error" => "rpc pipe closed", "attach_error" => "cannot attach to session" } }
    )

    apply_command(engine, "ReconcileSessions", {})

    worker = agent_by_id(read_state, "P1-I1-W1")
    assert_equal "errored", worker.fetch("status")
    assert_equal "terminal_error", worker.dig("harness_metadata", "reconcile", "state")
    refute_includes client.calls.map(&:first), "attach_session"
  end

  # Proof that the process is gone is not a transport blip: there is nothing to attach and nothing to
  # re-prompt, so the resume ladder is skipped entirely and the exit is the recorded reason.
  def test_a_session_whose_process_is_gone_is_settled_without_a_resume_attempt
    state_with_worker(pid: Process.pid.to_s, session_file: live_session_file)
    engine, client = stub_engine(
      { "sess-1" => {
        "process_gone_error" => "Pi session /tmp/sess-1.jsonl has no live process and no completed assistant response",
        "exit_status" => { "exit_code" => nil, "termsig" => 9, "success" => false },
        "stderr_tail" => "Killed: 9",
        "process_exited_at" => "2026-01-01T00:05:00Z",
        "events" => [{ "type" => "process_exit" }]
      } }
    )

    result = apply_command(engine, "ReconcileSessions", {})

    poll = result.dig("result", "poll_results").first
    assert_equal "settle_failed", poll.fetch("state")

    state = read_state
    worker = agent_by_id(state, "P1-I1-W1")
    failure = worker.dig("harness_metadata", "settle_failure")

    assert_equal "errored", worker.fetch("status")
    assert_equal "harness_process_exited", failure.fetch("kind")
    assert_includes failure.fetch("reason"), "terminated by signal 9"
    assert_equal "Killed: 9", failure.fetch("stderr_tail")
    assert_equal "2026-01-01T00:05:00Z", failure.fetch("process_exited_at")
    assert_nil worker.dig("harness_metadata", "reconcile")

    refute_includes client.calls.map(&:first), "attach_session"
    refute_includes client.calls.map(&:first), "prompt_session"
    assert_includes client.calls, ["read_events", "sess-1"], "the exit evidence must still be drained"
    assert_documented_status_vocabulary(state)
  end

  # A resume attempt that fails after attaching has already started a replacement session. Leaving it
  # running is how three failed attempts left three untracked processes on one session file.
  def test_a_resume_attempt_that_fails_after_attaching_kills_the_session_it_started
    state_with_worker(pid: Process.pid.to_s, session_file: live_session_file)
    engine, client = stub_engine(
      { "sess-1" => { "get_state_error" => "rpc pipe closed", "prompt_error" => "prompt timed out" } }
    )

    apply_command(engine, "ReconcileSessions", {})

    assert_includes client.calls, ["attach_session", "sess-1"]
    assert_includes client.calls, ["kill_session", "sess-1"], "the half-started session must not be orphaned"
    assert_equal "blocked", agent_by_id(read_state, "P1-I1-W1").fetch("status")
  end

  def test_fake_and_sessionless_agents_are_not_polled
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: %w[P1-I1-W1 P1-I1-W2])],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "working",
                        harness: "fake", session_id: "sess-fake"),
          worker_record(id: "P1-I1-W2", issue_id: "P1-I1", project_id: "P1", status: "working", harness: "pi")
        ]
      )
    )
    engine, client = stub_engine({ "default" => { "streaming" => true } })

    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal 0, result.dig("result", "checked_count")
    assert_empty client.calls
    state = read_state
    assert_equal "working", agent_by_id(state, "P1-I1-W1").fetch("status")
    assert_equal "working", agent_by_id(state, "P1-I1-W2").fetch("status")
  end

  def test_terminal_workers_are_not_polled_or_revived
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "completed")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: ["P1-I1-W1"])],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "completed",
                        harness: "pi", pid: Process.pid.to_s, session_id: "sess-1")
        ]
      )
    )
    engine, client = stub_engine({ "sess-1" => { "streaming" => true } })

    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal 0, result.dig("result", "checked_count")
    assert_empty client.calls
    assert_equal "completed", agent_by_id(read_state, "P1-I1-W1").fetch("status")
  end

  def test_head_transient_error_is_deferred_inside_the_startup_grace_window
    write_state(
      state_fixture(
        agents: [
          head_record(id: "H1", status: "working", harness: "pi", pid: Process.pid.to_s, session_id: "head-sess")
        ]
      )
    )
    engine, = stub_engine({ "head-sess" => { "get_state_error" => "head rpc not ready yet" } })

    result = apply_command(engine, "ReconcileSessions", {})

    poll = result.dig("result", "poll_results").first
    assert poll.fetch("deferred")
    assert_equal "transient_error", poll.dig("reconcile", "state")

    head = agent_by_id(read_state, "H1")
    assert_equal "working", head.fetch("status")
    assert_equal "transient_error", head.dig("harness_metadata", "reconcile_state")
    assert_equal 1, head.dig("harness_metadata", "reconcile", "error_count")
    assert_documented_status_vocabulary(read_state)
  end

  def test_head_errors_once_the_grace_window_and_recovery_budget_are_spent
    write_state(
      state_fixture(
        agents: [
          head_record(
            id: "H1",
            status: "working",
            harness: "pi",
            pid: Process.pid.to_s,
            session_id: "head-sess",
            harness_metadata: {
              "reconcile" => {
                "state" => "transient_error",
                "first_error_at" => "2020-01-01T00:00:00Z",
                "error_count" => 4,
                "head_recovery_attempt_count" => 1
              }
            }
          )
        ]
      )
    )
    engine, = stub_engine({ "head-sess" => { "get_state_error" => "head rpc is gone" } })

    apply_command(engine, "ReconcileSessions", {})

    head = agent_by_id(read_state, "H1")
    assert_equal "errored", head.fetch("status")
    assert_equal "terminal_error", head.dig("harness_metadata", "reconcile", "state")
    assert_documented_status_vocabulary(read_state)
  end

  def test_session_identity_is_used_for_adoption_and_ownership_checks
    state_with_worker(pid: Process.pid.to_s, session_id: "sess-1", session_file: live_session_file)
    engine = build_engine

    adopted = engine.mark_worker_completed(
      agent_id: "P1-I9-W9",
      session_ref: { "session_id" => "sess-1" },
      last_assistant_text: "finished"
    )

    assert_equal "accepted", adopted.fetch("status")
    assert_equal "P1-I1-W1", adopted.fetch("target_id")

    unowned = engine.mark_worker_completed(
      agent_id: "P1-I1-W1",
      session_ref: { "session_id" => "sess-unknown" },
      last_assistant_text: "finished"
    )

    assert_equal "rejected", unowned.fetch("status")
    assert_includes unowned.fetch("errors"), "agent_not_found"
  end

  def test_reconcile_never_introduces_undocumented_statuses_for_mixed_evidence
    dead_pid = reaped_pid
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: %w[P1-I1-W1 P1-I1-W2]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", agent_ids: ["P1-I2-W1"])
        ],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "working",
                        harness: "pi", pid: Process.pid.to_s, session_id: "healthy"),
          worker_record(id: "P1-I1-W2", issue_id: "P1-I1", project_id: "P1", status: "working",
                        harness: "pi", pid: dead_pid.to_s, session_id: "dead"),
          worker_record(id: "P1-I2-W1", issue_id: "P1-I2", project_id: "P1", status: "working",
                        harness: "pi", pid: Process.pid.to_s, session_id: "settled"),
          head_record(id: "H1", status: "working", harness: "pi", pid: Process.pid.to_s, session_id: "head-sess")
        ],
        questions: [question_record(id: "Q1", status: "open")]
      )
    )
    engine, = stub_engine(
      {
        "healthy" => { "streaming" => true },
        "dead" => { "require_live_pid" => true, "attach_error" => "cannot attach" },
        "settled" => { "streaming" => false, "completed" => true },
        "head-sess" => { "get_state_error" => "not ready" }
      }
    )

    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal 4, result.dig("result", "checked_count")
    state = read_state
    assert_documented_status_vocabulary(state)
    statuses = state.fetch("agents").to_h { |agent| [agent.fetch("id"), agent.fetch("status")] }
    assert_equal "working", statuses.fetch("P1-I1-W1")
    assert_equal "blocked", statuses.fetch("P1-I1-W2")
    assert_equal "completed", statuses.fetch("P1-I2-W1")
    assert_equal "working", statuses.fetch("H1")
    assert_equal "open", question_by_id(state, "Q1").fetch("status")
  end
end
