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

  def test_repeated_healthy_poll_does_not_rewrite_unchanged_state
    state_with_worker(
      pid: Process.pid.to_s,
      session_file: live_session_file,
      harness_metadata: {
        "kind" => "worker",
        "completed" => false,
        "is_streaming" => true,
        "reconcile_state" => "healthy"
      }
    )
    engine, client = stub_engine({ "sess-1" => { "streaming" => true } })
    apply_command(engine, "ReconcileSessions", {})
    unchanged_state_json = File.read(state_path)
    unchanged_state_inode = File.stat(state_path).ino
    worker_updated_at = agent_by_id(read_state, "P1-I1-W1").fetch("updated_at")

    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal 1, result.dig("result", "checked_count")
    assert_equal 0, result.dig("result", "changed_count")
    refute result.dig("result", "poll_results").first.fetch("changed")
    assert_equal unchanged_state_json, File.read(state_path)
    assert_equal unchanged_state_inode, File.stat(state_path).ino
    assert_equal worker_updated_at, agent_by_id(read_state, "P1-I1-W1").fetch("updated_at")
    assert_equal 2, client.calls.count { |call| call == ["get_state", "sess-1"] }
  end

  def test_one_save_persists_meaningful_changes_for_many_streaming_workers
    agents = 5.times.map do |index|
      worker_record(
        id: "P1-I1-W#{index + 1}",
        issue_id: "P1-I1",
        project_id: "P1",
        status: "working",
        harness: "pi",
        pid: Process.pid.to_s,
        session_id: "sess-#{index + 1}",
        harness_metadata: { "kind" => "worker", "is_streaming" => true }
      )
    end
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: agents.map { |agent| agent.fetch("id") })],
        agents: agents
      )
    )
    sessions = agents.to_h do |agent|
      [agent.fetch("harness_session_id"), { "streaming" => true, "events" => [{ "type" => "agent_start" }] }]
    end
    store = CountingStore.new(path: state_path)
    client = StubHarnessClient.new(sessions: sessions)
    engine = build_engine(store: store, harness_client_resolver: ->(_agent) { client })
    engine.send(:persist_normalized_state_if_changed)
    store.reset_save_count!

    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal 5, result.dig("result", "poll_results").count { |poll| poll.fetch("changed", false) }
    assert_equal 1, store.save_count
    assert_equal 5, read_state.fetch("agents").count { |agent| agent.dig("harness_metadata", "reconcile_state") == "healthy" }
  end

  def test_heartbeat_only_ticks_do_not_save_or_change_any_durable_timestamp
    state_with_worker(
      pid: Process.pid.to_s,
      session_file: live_session_file,
      harness_metadata: {
        "kind" => "worker",
        "completed" => false,
        "is_streaming" => true,
        "last_event_at" => "2026-01-01T00:00:01Z",
        "reconcile_state" => "healthy"
      }
    )
    before = read_state
    sessions = {
      "sess-1" => {
        "streaming" => true,
        "last_event_at" => "2026-01-01T00:00:02Z",
        "metadata" => { "messageCount" => 42 }
      }
    }
    client_class = Class.new(StubHarnessClient) do
      def get_state(session_ref)
        super.merge(
          "last_event_at" => config_for(session_ref).fetch("last_event_at"),
          "metadata" => config_for(session_ref).fetch("metadata")
        )
      end
    end
    store = CountingStore.new(path: state_path)
    client = client_class.new(sessions: sessions)
    engine = build_engine(store: store, harness_client_resolver: ->(_agent) { client })
    engine.send(:persist_normalized_state_if_changed)
    before_json = File.read(state_path)
    store.reset_save_count!

    3.times { apply_command(engine, "ReconcileSessions", {}) }

    assert_equal 0, store.save_count
    assert_equal before_json, File.read(state_path)
    after = read_state
    assert_equal before.fetch("metadata").fetch("updated_at"), after.fetch("metadata").fetch("updated_at")
    assert_equal before.fetch("projects").first.fetch("updated_at"), after.fetch("projects").first.fetch("updated_at")
    assert_equal before.fetch("issues").first.fetch("updated_at"), after.fetch("issues").first.fetch("updated_at")
    assert_equal before.fetch("agents").first.fetch("updated_at"), after.fetch("agents").first.fetch("updated_at")
  end

  def test_session_identity_transition_is_persisted_immediately
    state_with_worker(pid: Process.pid.to_s, session_file: live_session_file)
    store = CountingStore.new(path: state_path)
    client = StubHarnessClient.new(sessions: { "sess-1" => { "streaming" => true } })
    client.define_singleton_method(:get_state) do |session_ref|
      super(session_ref).merge("session_id" => "sess-replaced")
    end
    engine = build_engine(store: store, harness_client_resolver: ->(_agent) { client })
    engine.send(:persist_normalized_state_if_changed)
    store.reset_save_count!

    result = apply_command(engine, "ReconcileSessions", {})

    assert result.dig("result", "poll_results").first.fetch("changed")
    assert_equal 1, store.save_count
    assert_equal "sess-replaced", agent_by_id(read_state, "P1-I1-W1").fetch("harness_session_id")
  end

  def test_concurrent_create_issue_during_poll_is_preserved_by_the_merge_transaction
    state_with_worker(
      pid: Process.pid.to_s,
      session_file: live_session_file,
      harness_metadata: { "kind" => "worker", "is_streaming" => true, "reconcile_state" => "healthy" }
    )
    entered = Queue.new
    release = Queue.new
    client = StubHarnessClient.new(sessions: { "sess-1" => { "streaming" => true, "events" => [{ "type" => "agent_start" }] } })
    client.define_singleton_method(:get_state) do |session_ref|
      entered << true
      release.pop
      super(session_ref)
    end
    reconcile_engine = build_engine(harness_client_resolver: ->(_agent) { client })
    command_engine = build_engine(harness_client_resolver: ->(_agent) { client })

    reconcile_thread = Thread.new { reconcile_engine.reconcile_sessions }
    entered.pop
    prompted = apply_command(command_engine, "PromptAgent", {
      "agent_id" => "P1-I1-W1",
      "prompt" => "Preserve this concurrent prompt."
    })
    created = apply_command(command_engine, "CreateIssue", {
      "project_id" => "P1",
      "title" => "Concurrent issue",
      "description" => "Created while polling was outside the state lock."
    })
    release << true
    reconcile = reconcile_thread.value

    assert_equal "accepted", prompted.fetch("status")
    assert_equal "accepted", created.fetch("status")
    assert_equal "accepted", reconcile.fetch("status")
    state = read_state
    assert_equal "Concurrent issue", state.fetch("issues").find { |issue| issue.fetch("id") == created.fetch("target_id") }.fetch("title")
    assert_equal 1, agent_by_id(state, "P1-I1-W1").dig("harness_metadata", "prompt_count")
  end

  def test_restart_after_coalesced_completion_does_not_repeat_events_or_transition
    state_with_worker(pid: Process.pid.to_s, session_file: live_session_file)
    sessions = {
      "sess-1" => {
        "streaming" => false,
        "completed" => true,
        "last_assistant_text" => "done",
        "events" => [{ "type" => "agent_end" }]
      }
    }
    first_engine, = stub_engine(sessions)

    first = apply_command(first_engine, "ReconcileSessions", {})
    after_first = File.read(state_path)
    restarted_engine, restarted_client = stub_engine(sessions)
    second = apply_command(restarted_engine, "ReconcileSessions", {})

    assert first.dig("result", "poll_results").first.fetch("changed")
    assert_equal 0, second.dig("result", "checked_count")
    assert_empty restarted_client.calls
    assert_equal after_first, File.read(state_path)
    state = read_state
    assert_equal "completed", agent_by_id(state, "P1-I1-W1").fetch("status")
    assert_equal 1, state.fetch("logs").count { |log| log.fetch("message", "").include?("completed") }
  end

  def test_healthy_poll_repairs_stale_parent_statuses
    state_with_worker(pid: Process.pid.to_s, session_file: live_session_file)
    state = read_state
    state.fetch("issues").first["status"] = "blocked"
    state.fetch("projects").first["status"] = "blocked"
    write_state(state)
    engine, = stub_engine({ "sess-1" => { "streaming" => true } })

    result = apply_command(engine, "ReconcileSessions", {})

    assert result.dig("result", "poll_results").first.fetch("changed")
    state = read_state
    assert_equal "working", issue_by_id(state, "P1-I1").fetch("status")
    assert_equal "working", state.fetch("projects").first.fetch("status")
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
