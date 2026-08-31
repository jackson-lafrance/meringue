# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# A worker's harness process can leave while the worker still looks like live work. That happened
# for real: a Pi process exited mid-tool-call, and the first thing Meringue said about it, 46
# seconds later, was that a *resume* had failed:
#
#   original_error_class:   Meringue::Harness::PiClient::ProcessExitedError
#   original_error_message: "Pi session … has no live process and no completed assistant response"
#   error_class:            Meringue::Harness::PiClient::RpcTimeoutError
#   error_message:          "Timed out waiting for Pi RPC response to \"prompt\""
#
# Three `prompt` RPCs were replayed into a session whose process was already gone, each one leaving
# a new untracked harness process behind, and the failure the user finally read named the RPC
# timeout rather than the exit that actually happened.
#
# The contract these tests hold: evidence that the process is gone settles the worker on the first
# pass that sees it, with the exit as the reason, without a single prompt replay.
class KernelWorkersDeadHarnessProcessTest < Minitest::Test
  include KernelWorkersSupport

  PROCESS_GONE_MESSAGE = "Pi session /tmp/sessions/worker.jsonl has no live process and no completed assistant response"

  # Same shape as PiClient::ProcessExitedError: the harness proves the process is gone rather than
  # inferring it from a timeout, so a legitimately slow start can never be classified as one.
  class ProcessGoneError < StandardError
    include Meringue::Harness::SessionProcessGoneError
  end

  # A session whose process left. `get_state` is where reconciliation meets the evidence.
  class DeadProcessHarnessClient < RecordingHarnessClient
    attr_reader :attaches
    attr_accessor :exit_evidence

    def initialize(exit_evidence: nil, **options)
      super(**options)
      @attaches = []
      @exit_evidence = exit_evidence
    end

    def get_state(_session_ref)
      raise ProcessGoneError, PROCESS_GONE_MESSAGE
    end

    def session_exit_evidence(_session_ref)
      exit_evidence
    end

    def attach_session(session_ref)
      @attaches << session_ref.fetch("session_id", nil)
      session_ref
    end
  end

  # Same dead process, but this client cannot say anything about the exit (a Meringue restart loses
  # the process object that knew the exit status).
  class SilentExitHarnessClient < DeadProcessHarnessClient
    undef_method :session_exit_evidence
  end

  class PendingToolCallDeadProcessHarnessClient < DeadProcessHarnessClient
    attr_accessor :outcome

    def initialize(outcome:, **options)
      super(**options)
      @outcome = outcome
    end

    def turn_outcome(_session_ref)
      outcome
    end
  end

  EXIT_EVIDENCE = {
    "pid" => 27_282,
    "exit_status" => { "exit_code" => 1, "termsig" => nil, "success" => false },
    "stderr_tail" => "pi: fatal: heap out of memory",
    "last_event_at" => "2026-08-06T18:22:51Z"
  }.freeze

  def dead_process_client(client_class: DeadProcessHarnessClient, exit_evidence: EXIT_EVIDENCE)
    client_class.new(provider: "pi", exit_evidence: exit_evidence).tap do |client|
      # The process left mid-tool-call, so the session never produced a final answer.
      client.last_assistant_text = ""
      client.events = [{ "type" => "process_exit", "pid" => 27_282, "status" => { "exit_code" => 1 } }]
    end
  end

  def build_worker(client)
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id"), title: "Map the batch PR mechanics").fetch("target_id")
    [engine, context, worker_id]
  end

  # --- detection and classification -------------------------------------------------------------

  def test_a_dead_harness_process_settles_the_worker_on_the_first_pass_with_the_exit_as_the_reason
    client = dead_process_client
    engine, context, worker_id = build_worker(client)

    result = apply!(engine, "ReconcileSessions", {})

    poll = result.dig("result", "poll_results").first
    assert_equal "settle_failed", poll.fetch("state"), "the exit must be classified, not rediscovered by a resume"

    worker = agent(engine, worker_id)
    failure = worker.dig("harness_metadata", "settle_failure")

    assert_equal "errored", worker.fetch("status")
    assert_equal "harness_process_exited", failure.fetch("kind")
    assert_equal "harness_process_exit", failure.fetch("source")
    assert_includes failure.fetch("reason"), "its agent session process exited before it produced a result"
    assert_includes failure.fetch("reason"), "exit code 1", "the log line has to say what actually happened"
    assert_equal ProcessGoneError.name, failure.fetch("error_class")
    assert_equal PROCESS_GONE_MESSAGE, failure.fetch("error_message")
    assert_equal 1, failure.dig("exit_status", "exit_code")
    assert_includes failure.fetch("stderr_tail"), "heap out of memory"
    assert_equal "2026-08-06T18:22:51Z", failure.fetch("process_exited_at")
    assert_equal "errored", issue(engine, context.fetch("issue_id")).fetch("status")
    # What a head reads in routing context, and what the focused pane shows.
    assert_includes worker.dig("harness_metadata", "status_reason"), "agent session process exited"
    assert_equal failure.fetch("reason"), worker.dig("harness_metadata", "error_message")

    settle_log = worker_scoped_logs(engine, worker_id).find { |entry| entry.fetch("level") == "error" }
    refute_nil settle_log, "the user needs one visible line saying the process exited"
    assert_includes settle_log.fetch("message"), "its agent session process exited before it produced a result (exit code 1)"
    assert_includes settle_log.fetch("message"), "prompting this worker continues it in a new agent process"
  end

  def test_a_dead_process_with_pending_tool_evidence_keeps_the_worker_recoverable
    outcome = {
      "state" => "incomplete",
      "kind" => "pending_tool_call",
      "reason" => "its last turn stopped while a tool call was still pending",
      "stop_reason" => "toolUse"
    }
    client = PendingToolCallDeadProcessHarnessClient.new(
      provider: "pi",
      outcome: outcome,
      exit_evidence: EXIT_EVIDENCE
    )
    client.last_assistant_text = "I started the tool call."
    client.events = [{ "type" => "process_exit", "pid" => 27_282, "status" => { "exit_code" => 1 } }]
    engine, context, worker_id = build_worker(client)

    result = apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal "recoverable", result.dig("result", "poll_results").first.fetch("state")
    assert_equal "idle", worker.fetch("status")
    assert_equal "pending_tool_call", worker.dig("harness_metadata", "incomplete_turn", "kind")
    assert_nil worker.dig("harness_metadata", "settle_failure")
    assert_equal "working", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_empty client.attaches
  end

  # The failure the user reads must be the process exit, never the downstream RPC timeout a replayed
  # prompt would have produced.
  def test_a_dead_harness_process_is_never_re_prompted
    client = dead_process_client
    engine, _context, worker_id = build_worker(client)

    apply!(engine, "ReconcileSessions", {})
    apply!(engine, "ReconcileSessions", {})

    assert_empty client.attaches, "a process that is gone cannot be resumed, so nothing may try"
    assert_empty client.prompts, "replaying a prompt into a dead process only produces an RPC timeout"

    reconcile = agent(engine, worker_id).dig("harness_metadata", "reconcile")
    assert_nil reconcile, "no resume attempt was made, so no resume attempt may be recorded"
    refute_includes log_messages(engine).join("\n"), "could not resume its agent session"
  end

  # The incident's framing: a record that still says it is mid-turn, with no prompt of its own yet,
  # must not keep rendering as live work. One pass is all it takes, whatever the record claims.
  def test_a_worker_that_still_looks_mid_turn_is_settled_in_a_single_pass
    client = dead_process_client
    client.streaming = true
    engine, _context, worker_id = build_worker(client)
    spawned = agent(engine, worker_id)

    assert_equal 0, spawned.dig("harness_metadata", "prompt_count").to_i
    assert spawned.dig("harness_metadata", "is_streaming"), "the record has to start out looking like live work"

    apply!(engine, "ReconcileSessions", {})

    worker = agent(engine, worker_id)
    assert_equal "errored", worker.fetch("status")
    refute worker.dig("harness_metadata", "is_streaming"), "a settled record must not still claim to be streaming"
  end

  # The exit event the harness journalled is the durable evidence of the exit. It used to be
  # unreachable: `get_state` raises first, so nothing ever drained it.
  def test_the_harness_process_exit_event_is_logged
    client = dead_process_client
    client.events = []
    engine, _context, worker_id = build_worker(client)
    # Journalled after the worker was already running, which is the only way this event can arrive.
    client.events = [{ "type" => "process_exit", "pid" => 27_282, "status" => { "exit_code" => 1 } }]

    apply!(engine, "ReconcileSessions", {})

    exit_log = worker_scoped_logs(engine, worker_id).find do |entry|
      entry.fetch("source_type") == "harness" && entry.fetch("message").include?("process_exit")
    end
    refute_nil exit_log, "the process exit itself must appear in the log"

    settle_log = worker_scoped_logs(engine, worker_id).find { |entry| entry.fetch("level") == "error" }
    assert_equal 1, settle_log.dig("details", "settled_event_count"), "the settle record must count the evidence it drained"
  end

  def test_the_same_dead_process_is_recorded_once_across_repeated_passes
    engine, _context, worker_id = build_worker(dead_process_client)

    5.times { apply!(engine, "ReconcileSessions", {}) }

    settle_logs = worker_scoped_logs(engine, worker_id).select do |entry|
      entry.fetch("message").include?("its agent session process exited")
    end
    assert_equal 1, settle_logs.length, "a 2s pass must not re-log a failure it cannot repair"
    assert_equal "errored", agent(engine, worker_id).fetch("status")
  end

  # A restart loses the process object that knew the exit status. The record still carries it, so
  # the same failure keeps the same wording and is not re-logged as if it were new.
  def test_a_client_that_cannot_report_the_exit_status_reuses_what_the_record_already_knows
    engine, _context, worker_id = build_worker(dead_process_client)
    apply!(engine, "ReconcileSessions", {})

    restarted_engine = build_engine(harness_client: dead_process_client(client_class: SilentExitHarnessClient))
    apply!(restarted_engine, "ReconcileSessions", {})

    failure = agent(restarted_engine, worker_id).dig("harness_metadata", "settle_failure")
    assert_includes failure.fetch("reason"), "exit code 1"
    settle_logs = worker_scoped_logs(restarted_engine, worker_id).select do |entry|
      entry.fetch("message").include?("its agent session process exited")
    end
    assert_equal 1, settle_logs.length
  end

  def test_a_harness_that_cannot_report_the_exit_status_still_names_the_exit
    engine, _context, worker_id = build_worker(dead_process_client(exit_evidence: nil))

    apply!(engine, "ReconcileSessions", {})

    failure = agent(engine, worker_id).dig("harness_metadata", "settle_failure")
    assert_equal "harness_process_exited", failure.fetch("kind")
    assert_equal "its agent session process exited before it produced a result", failure.fetch("reason")
    refute failure.key?("exit_status")
  end

  # --- recovery is still available ---------------------------------------------------------------

  # The session history and the worktree are intact, so this worker is recoverable by prompting it:
  # that is what separates it from a session the provider refuses to replay.
  def test_the_settled_worker_is_still_promptable_and_keeps_its_workspace
    engine, _context, worker_id = build_worker(dead_process_client)
    before = agent(engine, worker_id)

    apply!(engine, "ReconcileSessions", {})

    worker = agent(engine, worker_id)
    assert_equal before.fetch("workspace_path"), worker.fetch("workspace_path")
    assert_equal before.fetch("workspace_branch"), worker.fetch("workspace_branch")
    assert_equal before.fetch("harness_session_id"), worker.fetch("harness_session_id")

    settle_log = worker_scoped_logs(engine, worker_id).find { |entry| entry.fetch("level") == "error" }
    assert settle_log.dig("details", "recoverable"), "an intact session and worktree can still be continued"
  end

  # --- queued dependents -------------------------------------------------------------------------

  # A dependent behind a predecessor whose *session* died keeps waiting, because reconciliation
  # resumes that session by itself. Nothing revives a predecessor whose process is gone without a
  # user prompt, so waiting on it is the unbounded silent wait this issue is about.
  def test_a_queued_dependent_is_resolved_by_policy_instead_of_waiting_on_a_dead_process
    client = dead_process_client
    engine, context, worker_id = build_worker(client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Synthesise the findings.",
      after_agent_id: worker_id,
      if_predecessor_fails: "cancel"
    ).fetch("target_id")
    assert_equal "queued", agent(engine, dependent_id).fetch("status")

    apply!(engine, "ReconcileSessions", {})

    assert_nil agent(engine, dependent_id), "a cancelled queued worker is removed like a killed one"
    cancellation = state(engine).fetch("logs").find { |entry| entry.fetch("message").include?("Cancelled queued worker #{dependent_id}") }
    refute_nil cancellation, "the cancellation must be visible instead of a silent wait"
    assert_equal "warning", cancellation.fetch("level")
    assert_includes cancellation.fetch("message"), "agent session process exited"
    assert_includes cancellation.fetch("message"), "Prompting #{worker_id} continues its work"
  end

  def test_a_queued_dependent_with_run_on_failure_still_starts
    client = dead_process_client
    engine, context, worker_id = build_worker(client)
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Synthesise the findings.",
      after_agent_id: worker_id,
      if_predecessor_fails: "run"
    ).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    assert_equal "working", agent(engine, dependent_id).fetch("status")
  end

  def test_queueing_a_new_worker_behind_a_dead_process_is_rejected_with_a_reason
    client = dead_process_client
    engine, context, worker_id = build_worker(client)
    apply!(engine, "ReconcileSessions", {})

    rejection = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Synthesise.", "after_agent_id" => worker_id }
    )

    assert_equal "rejected", rejection.fetch("status")
    assert_includes rejection.fetch("errors"), "deferred_predecessor_already_errored"
  end

  # --- the resume ladder is unchanged for everything else ---------------------------------------

  # Only *proof* that the process is gone skips the resume ladder. An ordinary transport failure is
  # still re-attached and re-prompted, because that session really can come back.
  def test_an_ordinary_transport_failure_still_uses_the_resume_ladder
    client = BrokenSessionClient.new(provider: "pi")
    engine, _context, worker_id = build_worker(client)

    apply!(engine, "ReconcileSessions", {})

    worker = agent(engine, worker_id)
    assert_equal "blocked", worker.fetch("status")
    assert_equal 1, worker.dig("harness_metadata", "reconcile", "resume_attempt_count")
    assert_nil worker.dig("harness_metadata", "settle_failure")
  end

  # --- spawn time --------------------------------------------------------------------------------

  # "Spawned worker …" must never be logged for a process that is already gone: the spawn round trip
  # includes a state read after the prompt, so a dead process fails the spawn instead.
  def test_a_process_that_dies_during_spawn_fails_the_spawn_instead_of_reporting_a_live_worker
    client = RecordingHarnessClient.new(provider: "pi")
    client.spawn_error = ProcessGoneError.new(PROCESS_GONE_MESSAGE)
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)

    result = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Do the work." })

    assert_equal "failed", result.fetch("status")
    assert_includes result.fetch("message"), "Could not start an agent session"
    assert_includes result.fetch("message"), PROCESS_GONE_MESSAGE
    refute_includes log_messages(engine).join("\n"), "Spawned worker"
  end
end
