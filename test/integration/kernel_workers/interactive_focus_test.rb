# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

class KernelWorkersInteractiveFocusTest < Minitest::Test
  include KernelWorkersSupport

  class InteractiveHarnessClient < RecordingHarnessClient
    attr_reader :prepared, :resumed, :reclaimed
    attr_accessor :replacement_session, :prepare_error, :resume_error, :resume_streaming

    def initialize
      super(provider: "pi")
      @prepared = []
      @resumed = []
      @reclaimed = []
    end

    def interactive_session_supported?
      true
    end

    def prepare_interactive_session(session_ref)
      @prepared << session_ref.dup
      raise @prepare_error if @prepare_error

      was_streaming = session_ref.fetch("is_streaming", false)
      ref = session_ref.merge("pid" => nil, "is_streaming" => false)
      ref = ref.merge(@replacement_session) if @replacement_session
      {
        "session_ref" => ref,
        "interactive_argv" => ["pi", "--session", ref.fetch("session_file"), "continue the interrupted assignment"],
        "handoff" => {
          "mode" => "native_interactive",
          "transfer" => was_streaming ? "interrupted_turn" : "settled_session",
          "was_streaming" => was_streaming,
          "exact_stream_transfer" => !was_streaming,
          "prompt" => was_streaming ? "continue the interrupted assignment" : nil,
          "captured_event_count" => 3
        }.compact
      }
    end

    def reclaim_interactive_session(_session_ref, pid:)
      @reclaimed << pid
      true
    end

    def resume_dashboard_session(session_ref)
      @resumed << session_ref.dup
      raise @resume_error if @resume_error

      session_ref.merge("pid" => 49_999, "is_streaming" => !!@resume_streaming)
    end
  end

  def test_focus_preempts_a_streaming_turn_once_and_reconciliation_stands_down
    client = InteractiveHarnessClient.new
    client.streaming = true
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Preserve this original assignment while entering focus."
    ).fetch("target_id")

    prepared = engine.begin_agent_interactive_focus(worker_id)
    assert_equal "accepted", prepared.fetch("status")
    assert_equal ["pi", "--session", agent(engine, worker_id).fetch("harness_session_file"), "continue the interrupted assignment"], prepared.dig("result", "interactive_argv")
    assert_equal "interactive_pending", agent(engine, worker_id).dig("harness_metadata", "interactive_handoff", "state")
    assert_equal "interrupted_turn", prepared.dig("result", "handoff", "transfer")
    assert_equal 1, client.prepared.length
    assert_empty client.aborts
    context_handoff = client.prepared.first.dig("metadata", "interactive_handoff", "context")
    assert_equal worker_id, context_handoff.fetch("agent_id")
    assert_equal context.fetch("issue_id"), context_handoff.fetch("issue_id")
    assert_equal "Fix the login bug", context_handoff.fetch("issue_title")
    assert_equal "Details here.", context_handoff.fetch("issue_description")
    assert_equal "Preserve this original assignment while entering focus.", context_handoff.fetch("assignment")
    assert_equal agent(engine, worker_id).fetch("workspace_path"), context_handoff.fetch("workspace_path")
    assert_equal agent(engine, worker_id).fetch("workspace_branch"), context_handoff.fetch("workspace_branch")

    repeated = engine.begin_agent_interactive_focus(worker_id)
    assert_equal "rejected", repeated.fetch("status")
    assert_equal "interactive_focus_active", repeated.fetch("errors").first
    assert_equal 1, client.prepared.length
    assert_empty client.aborts, "focus should terminate the writer directly without an abort/settle round trip"

    # A background tick cannot read or settle the same JSONL while the native PTY owns it.
    before = agent(engine, worker_id).fetch("updated_at")
    engine.reconcile_sessions
    assert_equal before, agent(engine, worker_id).fetch("updated_at")

    started = engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    assert_equal "accepted", started.fetch("status")
    assert_equal "interactive", agent(engine, worker_id).dig("harness_metadata", "interactive_handoff", "state")
    repeated_while_active = engine.begin_agent_interactive_focus(worker_id)
    assert_equal "rejected", repeated_while_active.fetch("status")
    assert_equal 1, client.prepared.length
    assert_empty client.aborts

    blocked = engine.apply(
      "type" => "PromptAgent",
      "payload" => { "agent_id" => worker_id, "prompt" => "Do not create a second writer." }
    )
    assert_equal "rejected", blocked.fetch("status")
    assert_equal "interactive_focus_active", blocked.fetch("errors").first

    resumed = engine.end_agent_interactive_focus(worker_id)
    assert_equal "accepted", resumed.fetch("status"), resumed.inspect
    assert_equal 1, client.resumed.length
    refute agent(engine, worker_id).fetch("harness_metadata").key?("interactive_handoff")
    assert_equal "interactive_closed", agent(engine, worker_id).dig("harness_metadata", "last_interactive_handoff", "outcome")
    assert_equal "idle", agent(engine, worker_id).fetch("status")
    assert_equal 49_999, agent(engine, worker_id).fetch("pid")

    already_resumed = engine.end_agent_interactive_focus(worker_id)
    assert_equal "accepted", already_resumed.fetch("status")
    assert_equal 1, client.resumed.length, "dashboard ownership must be resumed exactly once"

    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata")["interactive_handoff"] = {
        "state" => "interactive",
        "owner_instance_id" => "dead-instance",
        "owner_instance_pid" => 999_999,
        "interactive_pid" => 999_998
      }
    end
    recovered = engine.begin_agent_interactive_focus(worker_id)
    assert_equal "accepted", recovered.fetch("status")
  end

  def test_a_second_engine_cannot_claim_or_prepare_the_same_workspace_handoff
    client = InteractiveHarnessClient.new
    client.streaming = true
    first_engine = build_engine(harness_client: client)
    second_engine = build_engine(harness_client: client)
    context = project_with_issue(first_engine)
    worker_id = spawn_worker(first_engine, context.fetch("issue_id")).fetch("target_id")

    first = first_engine.begin_agent_interactive_focus(worker_id)
    second = second_engine.begin_agent_interactive_focus(worker_id)

    assert_equal "accepted", first.fetch("status")
    assert_equal "rejected", second.fetch("status")
    assert_equal "interactive_focus_active", second.fetch("errors").first
    assert_equal 1, client.prepared.length
    assert_empty client.aborts
  end

  def test_completed_non_streaming_worker_without_a_process_can_open_native_focus
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    patch_agent!(worker_id) do |record|
      record["status"] = "completed"
      record["pid"] = nil
      record.fetch("harness_metadata")["is_streaming"] = false
      record.fetch("harness_metadata")["last_assistant_text"] = "The managed turn already completed."
    end

    prepared = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "accepted", prepared.fetch("status"), prepared.inspect
    assert_nil client.prepared.first.fetch("pid")
    assert_equal false, client.prepared.first.fetch("is_streaming")
    assert_equal "settled_session", prepared.dig("result", "handoff", "transfer")
    assert_equal "interactive_pending", agent(engine, worker_id).dig("harness_metadata", "interactive_handoff", "state")
    assert_equal "completed", agent(engine, worker_id).fetch("status")
  end

  def test_replacement_session_ref_is_used_for_both_native_focus_and_dashboard_return
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    replacement_file = tmp_path("replacement-session.jsonl")
    client.replacement_session = { "session_id" => "replacement-session", "session_file" => replacement_file }

    prepared = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "accepted", prepared.fetch("status")
    assert_equal "replacement-session", agent(engine, worker_id).fetch("harness_session_id")
    assert_equal replacement_file, agent(engine, worker_id).fetch("harness_session_file")
    engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    engine.end_agent_interactive_focus(worker_id)
    assert_equal replacement_file, client.resumed.last.fetch("session_file")
  end

  def test_focus_reclaims_a_live_native_process_left_by_a_crashed_owner
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    orphan_pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30")

    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata")["interactive_handoff"] = {
        "state" => "interactive",
        "owner_instance_id" => "dead-instance",
        "owner_instance_pid" => 999_999,
        "interactive_pid" => orphan_pid
      }
    end

    result = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "accepted", result.fetch("status")
    assert_equal [orphan_pid], client.reclaimed
  ensure
    begin
      Process.kill("TERM", orphan_pid) if orphan_pid && Meringue::Harness::ProcessIdentity.alive?(orphan_pid)
      Process.wait(orphan_pid) if orphan_pid
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  def test_prepare_failure_restores_dashboard_ownership_and_keeps_durable_context
    client = InteractiveHarnessClient.new
    client.streaming = true
    client.resume_streaming = true
    client.prepare_error = IOError.new("handoff preparation failed")
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Keep this assignment.").fetch("target_id")

    result = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "failed", result.fetch("status")
    assert_equal 1, client.prepared.length
    assert_equal 1, client.resumed.length
    recovered = agent(engine, worker_id)
    assert_equal "working", recovered.fetch("status")
    assert_equal 49_999, recovered.fetch("pid")
    refute recovered.fetch("harness_metadata").key?("interactive_handoff")
    failure = recovered.dig("harness_metadata", "last_interactive_handoff")
    assert_equal "prepare_failed", failure.fetch("outcome")
    assert_equal "Keep this assignment.", failure.dig("context", "assignment")
  end

  def test_prepare_and_rollback_failure_does_not_leave_a_false_interactive_owner
    client = InteractiveHarnessClient.new
    client.streaming = true
    client.prepare_error = IOError.new("handoff preparation failed")
    client.resume_error = IOError.new("dashboard recovery failed")
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    result = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "failed", result.fetch("status")
    assert_includes result.fetch("errors").join(" "), "dashboard_recovery_failed"
    recovered = agent(engine, worker_id)
    assert_equal "blocked", recovered.fetch("status")
    refute recovered.fetch("harness_metadata").key?("interactive_handoff")
    assert_equal "dashboard recovery failed", recovered.dig("harness_metadata", "last_interactive_handoff", "recovery_error")
  end

  def test_dashboard_resume_failure_is_retryable_without_duplicate_native_ownership
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    engine.begin_agent_interactive_focus(worker_id)
    engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    client.resume_error = IOError.new("cannot restart RPC")

    failed = engine.end_agent_interactive_focus(worker_id)

    assert_equal "failed", failed.fetch("status")
    assert_equal "resume_failed", agent(engine, worker_id).dig("harness_metadata", "interactive_handoff", "state")
    assert_equal 1, client.resumed.length

    client.resume_error = nil
    recovered = engine.end_agent_interactive_focus(worker_id)

    assert_equal "accepted", recovered.fetch("status"), recovered.inspect
    assert_equal 2, client.resumed.length
    refute agent(engine, worker_id).fetch("harness_metadata").key?("interactive_handoff")
    assert_equal "idle", agent(engine, worker_id).fetch("status")
  end

  def test_unsupported_harness_is_rejected_without_mutating_worker_state
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    original = agent(engine, worker_id).fetch("harness_metadata").dup

    result = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "rejected", result.fetch("status")
    assert_equal "interactive_session_unsupported", result.fetch("errors").first
    assert_equal original, agent(engine, worker_id).fetch("harness_metadata")
  end
end
