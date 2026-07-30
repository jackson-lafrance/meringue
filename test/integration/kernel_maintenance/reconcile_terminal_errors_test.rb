# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Reconciliation runs every couple of seconds for as long as Meringue is open, so a record it
# can never repair must be recorded once and then left alone. These tests pin the log-once,
# no-churn contract for terminally errored heads and workers: the user gets one honest error
# line per failure instead of the same line several times per second.
class KernelMaintenanceReconcileTerminalErrorsTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def build_stub_engine(sessions, attach_support: true)
    client = if attach_support
               StubHarnessClient.new(sessions: sessions)
             else
               StubHarnessClientWithoutAttach.new(sessions: sessions)
             end
    [build_engine(harness_client_resolver: ->(_agent) { client }), client]
  end

  def live_session_file
    path = tmp_path("sessions", "live.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate({ "messages" => [] }))
    path
  end

  def reconcile_error_logs(state, agent_id)
    Array(state.fetch("logs")).select do |log|
      log.fetch("level", nil) == "error" &&
        log.fetch("source_id", nil) == agent_id &&
        log.fetch("message", "").include?("errored while reconciling")
    end
  end

  def worker_state(status:, pid:, harness_metadata: {})
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
            session_id: "sess-1",
            session_file: live_session_file,
            harness_metadata: harness_metadata
          )
        ]
      )
    )
  end

  def head_state(status:, harness_metadata:)
    write_state(
      state_fixture(
        agents: [
          head_record(
            id: "H1",
            status: status,
            harness: "pi",
            pid: Process.pid.to_s,
            session_id: "head-sess",
            session_file: live_session_file,
            harness_metadata: harness_metadata
          )
        ]
      )
    )
  end

  def test_unrepairable_worker_session_is_logged_once_and_never_repolled
    worker_state(status: "working", pid: reaped_pid.to_s)
    engine, client = build_stub_engine({ "sess-1" => { "require_live_pid" => true } }, attach_support: false)

    first = apply_command(engine, "ReconcileSessions", {})
    assert_equal 1, first.dig("result", "checked_count")

    after_first = read_state
    worker = agent_by_id(after_first, "P1-I1-W1")
    assert_equal "errored", worker.fetch("status")
    assert_equal "terminal_error", worker.dig("harness_metadata", "reconcile_state")
    assert_equal 1, reconcile_error_logs(after_first, "P1-I1-W1").length

    settled_state_json = File.read(state_path)
    calls_after_first = client.calls.dup

    3.times do
      repeat = apply_command(engine, "ReconcileSessions", {})
      assert_equal "accepted", repeat.fetch("status")
      # The record is terminal: reconciliation must not even talk to the harness about it.
      assert_equal 0, repeat.dig("result", "checked_count")
      assert_equal 0, repeat.dig("result", "changed_count")
      assert_empty repeat.fetch("log_entry_ids")
    end

    assert_equal calls_after_first, client.calls
    assert_equal settled_state_json, File.read(state_path), "repeat reconciliation rewrote state for a settled record"

    after_repeats = read_state
    assert_equal 1, reconcile_error_logs(after_repeats, "P1-I1-W1").length
    assert_equal worker.fetch("updated_at"), agent_by_id(after_repeats, "P1-I1-W1").fetch("updated_at")
    assert_documented_status_vocabulary(after_repeats)
  end

  def test_head_that_cannot_return_a_result_errors_once_and_releases_its_session
    head_state(
      status: "working",
      harness_metadata: {
        "head_session_state" => "active",
        "head_session_started_at" => BASE_TIME,
        # The repair budget is already spent, so the next unparseable answer is terminal.
        "head_result_repair_count" => 1
      }
    )
    engine, client = build_stub_engine(
      { "head-sess" => { "streaming" => false, "completed" => true, "last_assistant_text" => "Sorry, I cannot help." } }
    )

    first = apply_command(engine, "ReconcileSessions", {})
    assert_equal 1, first.dig("result", "checked_count")

    after_first = read_state
    head = agent_by_id(after_first, "H1")
    assert_equal "errored", head.fetch("status")
    assert_equal "terminal_error", head.dig("harness_metadata", "reconcile_state")
    assert_equal "Meringue::Heads::InvalidHeadResultError", head.dig("harness_metadata", "reconcile", "error_class")
    # A terminally failed head must not keep an orphaned harness process alive.
    assert_equal "released", head.dig("harness_metadata", "head_session_state")
    assert_equal "head_reconcile_error", head.dig("harness_metadata", "head_session_release_reason")
    assert_includes client.calls, ["kill_session", "head-sess"]

    error_logs = reconcile_error_logs(after_first, "H1")
    assert_equal 1, error_logs.length
    assert_equal "Head H1 errored while reconciling its agent session.", error_logs.first.fetch("message")

    settled_state_json = File.read(state_path)
    calls_after_first = client.calls.dup

    3.times { apply_command(engine, "ReconcileSessions", {}) }

    assert_equal calls_after_first, client.calls
    assert_equal settled_state_json, File.read(state_path), "repeat reconciliation rewrote state for a settled head"
    assert_equal 1, reconcile_error_logs(read_state, "H1").length
    assert_documented_status_vocabulary(read_state)
  end

  # Silencing repeats must not silence discoveries: a record that is `errored` without recorded
  # reconcile evidence (a head the runner failed before reconciliation ever saw it, or state
  # written by an older Meringue) is still polled once and still reports its failure once.
  def test_errored_record_without_recorded_reconcile_details_still_logs_once
    worker_state(status: "errored", pid: reaped_pid.to_s, harness_metadata: { "error_message" => "spawn failed" })
    engine, client = build_stub_engine({ "sess-1" => { "require_live_pid" => true } }, attach_support: false)

    first = apply_command(engine, "ReconcileSessions", {})
    assert_equal 1, first.dig("result", "checked_count")
    assert_equal 1, reconcile_error_logs(read_state, "P1-I1-W1").length
    refute_empty client.calls

    calls_after_first = client.calls.dup
    settled_state_json = File.read(state_path)

    apply_command(engine, "ReconcileSessions", {})

    assert_equal calls_after_first, client.calls
    assert_equal settled_state_json, File.read(state_path)
    assert_equal 1, reconcile_error_logs(read_state, "P1-I1-W1").length
  end

  # The skip is scoped to the settled record only. Live work in the same pass keeps reconciling.
  def test_live_sessions_still_reconcile_alongside_a_settled_errored_record
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: %w[P1-I1-W1 P1-I1-W2])],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "errored",
                        harness: "pi", pid: Process.pid.to_s, session_id: "settled-error",
                        session_file: live_session_file,
                        harness_metadata: {
                          "reconcile_state" => "terminal_error",
                          "reconcile" => { "state" => "terminal_error", "error_message" => "harness process is not alive" }
                        }),
          worker_record(id: "P1-I1-W2", issue_id: "P1-I1", project_id: "P1", status: "working",
                        harness: "pi", pid: Process.pid.to_s, session_id: "healthy",
                        session_file: live_session_file)
        ]
      )
    )
    engine, client = build_stub_engine({ "healthy" => { "streaming" => true, "events" => [{ "type" => "agent_start" }] } })

    result = apply_command(engine, "ReconcileSessions", {})

    assert_equal 1, result.dig("result", "checked_count")
    assert_equal ["get_state", "healthy"], client.calls.first
    refute_includes client.calls, ["get_state", "settled-error"]

    state = read_state
    assert_equal "working", agent_by_id(state, "P1-I1-W2").fetch("status")
    assert_equal "healthy", agent_by_id(state, "P1-I1-W2").dig("harness_metadata", "reconcile_state")
    assert_equal "errored", agent_by_id(state, "P1-I1-W1").fetch("status")
    assert_empty reconcile_error_logs(state, "P1-I1-W1")
  end

  # Standalone errored heads are cleared by /prune, not by reconciliation, so the record stays
  # visible in the AgentTree until the user asks for housekeeping.
  def test_settled_errored_head_is_retained_until_prune_removes_it
    head_state(
      status: "errored",
      harness_metadata: {
        "head_session_state" => "released",
        "reconcile_state" => "terminal_error",
        "reconcile" => { "state" => "terminal_error", "error_message" => "assistant output was not parseable JSON" }
      }
    )
    engine, = build_stub_engine({ "head-sess" => { "get_state_error" => "rpc pipe closed" } })

    apply_command(engine, "ReconcileSessions", {})
    refute_nil agent_by_id(read_state, "H1"), "reconciliation must not sweep head records on its own"

    prune = apply_command(engine, "Prune", {})

    assert_equal "accepted", prune.fetch("status")
    assert_includes prune.dig("result", "removed_standalone_agent_ids"), "H1"
    assert_nil agent_by_id(read_state, "H1")
  end
end
