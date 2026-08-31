# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

class KernelWorkersInteractiveFocusTest < Minitest::Test
  include KernelWorkersSupport

  class ManagedSessionHarnessClient < RecordingHarnessClient
    def initialize
      super(streaming: true, provider: "pi")
    end

    def managed_session_view_supported?
      true
    end

    def prepare_interactive_session(_session_ref)
      raise "managed focus must not prepare a handoff"
    end
  end

  class InteractiveHarnessClient < RecordingHarnessClient
    attr_reader :prepared, :resumed, :reclaimed
    attr_accessor :replacement_session, :prepare_error, :resume_error, :resume_streaming, :native_completed,
                  :reported_turn_outcome

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
      if was_streaming
        abort_session(session_ref)
        self.streaming = false
      end
      ref = session_ref.merge("pid" => nil, "is_streaming" => false)
      ref = ref.merge(@replacement_session) if @replacement_session
      interactive_argv = ["pi", "--session", ref.fetch("session_file")]
      model = ref.dig("session_settings", "model", "reference")
      thinking = ref.dig("session_settings", "thinking_level")
      interactive_argv += ["--model", model] if model
      interactive_argv += ["--thinking", thinking] if thinking
      interactive_argv << "continue the interrupted assignment"
      {
        "session_ref" => ref,
        "interactive_argv" => interactive_argv,
        "handoff" => {
          "mode" => "native_interactive",
          "transfer" => was_streaming ? "coordinated_turn_abort" : "settled_session",
          "was_streaming" => was_streaming,
          "continuation_required" => was_streaming,
          "exact_stream_transfer" => !was_streaming,
          "interruption_method" => was_streaming ? "rpc_abort" : nil,
          "prompt" => was_streaming ? "continue the interrupted assignment" : nil,
          "turn_checkpoint" => was_streaming ? (reported_turn_outcome || { "state" => "incomplete", "stop_reason" => "toolUse" }) : nil,
          "captured_event_count" => 3
        }.compact
      }
    end

    def reclaim_interactive_session(_session_ref, pid:)
      @reclaimed << pid
      true
    end

    def turn_outcome(_session_ref)
      reported_turn_outcome
    end

    def resume_dashboard_session(session_ref, handoff: nil)
      @resumed << session_ref.merge("handoff" => handoff)
      raise @resume_error if @resume_error

      resumed = session_ref.merge("pid" => 49_999, "is_streaming" => !!@resume_streaming)
      details = handoff.is_a?(Hash) ? handoff.fetch("handoff", {}) : {}
      return resumed unless details.fetch("continuation_required", false) && !native_completed

      self.streaming = false
      continued = prompt_session(resumed, details.fetch("prompt"), mode: "normal")
      self.streaming = true
      continued.merge(
        "is_streaming" => true,
        "metadata" => continued.fetch("metadata", {}).merge("interactive_dashboard_continuation" => "started")
      )
    end
  end

  def test_pi_focus_selects_the_managed_view_without_preparing_or_prompting
    client = ManagedSessionHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    assert_equal "session_view", engine.agent_focus_mode(worker_id)
    assert_empty client.aborts
    assert_empty client.prompts
    assert_equal true, agent(engine, worker_id).dig("harness_metadata", "is_streaming")

    direct_handoff = engine.begin_agent_interactive_focus(worker_id)
    assert_equal "rejected", direct_handoff.fetch("status")
    assert_equal "interactive_session_unsupported", direct_handoff.fetch("errors").first
    assert_empty client.aborts
    assert_empty client.prompts
  end

  def test_focus_safely_hands_off_a_pending_tool_turn_and_dashboard_continues_without_error
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
    assert_equal "coordinated_turn_abort", prepared.dig("result", "handoff", "transfer")
    assert_equal "rpc_abort", prepared.dig("result", "handoff", "interruption_method")
    assert_equal true, prepared.dig("result", "handoff", "continuation_required")
    assert_equal 1, client.prepared.length
    assert_equal 1, client.aborts.length, "the managed turn must settle before its RPC writer is stopped"
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
    assert_equal 1, client.aborts.length, "a repeated focus request must not abort the turn twice"

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
    assert_equal 1, client.aborts.length

    blocked = engine.apply(
      "type" => "PromptAgent",
      "payload" => { "agent_id" => worker_id, "prompt" => "Do not create a second writer." }
    )
    assert_equal "accepted", blocked.fetch("status")
    assert_equal true, blocked.dig("result", "queued")

    resumed = engine.end_agent_interactive_focus(worker_id)
    assert_equal "accepted", resumed.fetch("status"), resumed.inspect
    assert_equal 1, client.resumed.length
    refute agent(engine, worker_id).fetch("harness_metadata").key?("interactive_handoff")
    assert_equal "dashboard_continuation_started", agent(engine, worker_id).dig("harness_metadata", "last_interactive_handoff", "outcome")
    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_equal 49_999, agent(engine, worker_id).fetch("pid")
    assert_equal ["continue the interrupted assignment"], client.prompts.map { |entry| entry.fetch("prompt") }

    engine.reconcile_sessions
    assert_equal "working", agent(engine, worker_id).fetch("status")
    refute agent(engine, worker_id).fetch("harness_metadata").key?("settle_failure")

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

  def test_focus_handoff_keeps_the_workers_complex_model_reference
    reference = "fireworks/fireworks:accounts/fireworks/models/glm-5p3"
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      model: reference,
      thinking_level: "high"
    ).fetch("target_id")

    prepared = engine.begin_agent_interactive_focus(worker_id)

    assert_equal "accepted", prepared.fetch("status"), prepared.inspect
    assert_equal reference, client.prepared.first.dig("session_settings", "model", "reference")
    assert_equal reference, client.prepared.first.dig("metadata", "interactive_handoff", "context", "session_settings", "model", "reference")
    assert_includes prepared.dig("result", "interactive_argv").each_cons(2).to_a, ["--model", reference]
    assert_includes prepared.dig("result", "interactive_argv").each_cons(2).to_a, ["--thinking", "high"]

    engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    resumed = engine.end_agent_interactive_focus(worker_id)

    assert_equal "accepted", resumed.fetch("status")
    assert_equal reference, client.resumed.last.dig("session_settings", "model", "reference")
    assert_equal reference, agent(engine, worker_id).dig("session_settings", "model", "reference")
  end

  def test_focus_exit_logs_a_visible_model_substitution_warning
    requested = "fireworks/fireworks:accounts/fireworks/models/glm-5p3"
    effective = "fireworks-300k/fireworks:accounts/fireworks/routers/glm-5p2-fast"
    client = InteractiveHarnessClient.new
    client.replacement_session = {
      "session_settings" => { "model" => Meringue::Harness::ModelReference.parse(effective) },
      "metadata" => {
        "session_model_substitution" => {
          "requested" => requested,
          "effective" => effective,
          "warning" => "Pi substituted model #{effective} for requested model #{requested}."
        }
      }
    }
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id"), model: requested).fetch("target_id")

    engine.begin_agent_interactive_focus(worker_id)
    engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    resumed = engine.end_agent_interactive_focus(worker_id)

    warning = state(engine).fetch("logs").last
    assert_equal [warning.fetch("id")], resumed.fetch("log_entry_ids")
    assert_equal "warning", warning.fetch("level")
    assert_equal requested, warning.dig("details", "requested_model")
    assert_equal effective, warning.dig("details", "effective_model")
    assert_equal "Pi substituted model #{effective} for requested model #{requested}.", warning.fetch("message")
  end

  def test_successful_focus_entry_and_exit_do_not_append_user_visible_handoff_logs
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)

    [false, true].each do |streaming|
      client.streaming = streaming
      worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
      log_ids_before_focus = state(engine).fetch("logs").map { |entry| entry.fetch("id") }

      prepared = engine.begin_agent_interactive_focus(worker_id)
      assert_equal "accepted", prepared.fetch("status")
      assert_empty prepared.fetch("log_entry_ids"), "successful focus entry should not add a lifecycle log"

      started = engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
      assert_equal "accepted", started.fetch("status")
      resumed = engine.end_agent_interactive_focus(worker_id)
      assert_equal "accepted", resumed.fetch("status")
      assert_empty resumed.fetch("log_entry_ids"), "successful focus exit should not add a lifecycle log"
      assert_equal log_ids_before_focus, state(engine).fetch("logs").map { |entry| entry.fetch("id") },
                   "#{streaming ? "active" : "settled"} session ownership changes should stay out of the user-visible log"
    end
  end

  def test_restart_recovers_an_interrupted_focus_before_polling_the_old_session
    client = InteractiveHarnessClient.new
    client.streaming = true
    first_engine = build_engine(harness_client: client)
    context = project_with_issue(first_engine)
    worker_id = spawn_worker(
      first_engine,
      context.fetch("issue_id"),
      prompt: "Keep the unfinished assignment alive across a dashboard crash."
    ).fetch("target_id")

    interrupted_checkpoint = {
      "state" => "completed",
      "stop_reason" => "abort",
      "last_assistant_text" => "I was still inspecting the unfinished tool call."
    }
    client.reported_turn_outcome = interrupted_checkpoint
    client.last_assistant_text = interrupted_checkpoint.fetch("last_assistant_text")
    first_engine.begin_agent_interactive_focus(worker_id)
    first_engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata").fetch("interactive_handoff").merge!(
        "owner_instance_id" => "crashed-dashboard",
        "owner_instance_pid" => 999_999,
        "interactive_pid" => 999_998
      )
    end

    restarted_engine = build_engine(harness_client: client)
    result = restarted_engine.reconcile_sessions

    recovered = agent(restarted_engine, worker_id)
    assert_equal "working", recovered.fetch("status"), "restart must resume the unfinished turn"
    refute_equal "completed", recovered.fetch("status"), "the aborted checkpoint is not a final result"
    refute recovered.fetch("harness_metadata").key?("interactive_handoff")
    assert_equal "dashboard_continuation_started", recovered.dig("harness_metadata", "last_interactive_handoff", "outcome")
    assert_equal "working", issue(restarted_engine, context.fetch("issue_id")).fetch("status")
    assert_equal 1, result.dig("result", "interactive_focus_results").length
    assert_equal 1, client.resumed.length
    assert_equal ["continue the interrupted assignment"], client.prompts.map { |entry| entry.fetch("prompt") }
  end

  def test_restart_recovers_a_crash_during_focus_preparation_as_unfinished_work
    client = InteractiveHarnessClient.new
    client.streaming = true
    first_engine = build_engine(harness_client: client)
    context = project_with_issue(first_engine)
    worker_id = spawn_worker(first_engine, context.fetch("issue_id")).fetch("target_id")
    first_engine.begin_agent_interactive_focus(worker_id)
    patch_agent!(worker_id) do |record|
      marker = record.fetch("harness_metadata").fetch("interactive_handoff")
      marker.delete("handoff")
      marker.merge!(
        "state" => "preparing",
        "managed_turn_was_streaming" => true,
        "owner_instance_id" => "crashed-dashboard",
        "owner_instance_pid" => 999_999
      )
    end

    restarted_engine = build_engine(harness_client: client)
    restarted_engine.reconcile_sessions

    recovered = agent(restarted_engine, worker_id)
    assert_equal "completed", recovered.fetch("status")
    refute recovered.fetch("harness_metadata").key?("interactive_handoff")
    assert_equal 1, client.resumed.length
    assert_empty client.prompts
  end

  def test_restart_retries_a_focus_return_that_crashed_while_resuming
    client = InteractiveHarnessClient.new
    client.streaming = true
    first_engine = build_engine(harness_client: client)
    context = project_with_issue(first_engine)
    worker_id = spawn_worker(first_engine, context.fetch("issue_id")).fetch("target_id")
    first_engine.begin_agent_interactive_focus(worker_id)
    first_engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata").fetch("interactive_handoff").merge!(
        "state" => "resuming",
        "owner_instance_id" => "crashed-dashboard",
        "owner_instance_pid" => 999_999,
        "interactive_pid" => 999_998
      )
    end

    restarted_engine = build_engine(harness_client: client)
    restarted_engine.reconcile_sessions

    recovered = agent(restarted_engine, worker_id)
    assert_equal "working", recovered.fetch("status")
    refute recovered.fetch("harness_metadata").key?("interactive_handoff")
    assert_equal 1, client.resumed.length
    assert_equal ["continue the interrupted assignment"], client.prompts.map { |entry| entry.fetch("prompt") }
  end

  def test_failed_startup_focus_return_stays_resumable_and_is_not_polled_as_complete
    client = InteractiveHarnessClient.new
    client.streaming = true
    first_engine = build_engine(harness_client: client)
    context = project_with_issue(first_engine)
    worker_id = spawn_worker(first_engine, context.fetch("issue_id")).fetch("target_id")
    checkpoint = {
      "state" => "completed",
      "stop_reason" => "abort",
      "last_assistant_text" => "This interrupted checkpoint is not the final answer."
    }
    client.reported_turn_outcome = checkpoint
    client.last_assistant_text = checkpoint.fetch("last_assistant_text")
    first_engine.begin_agent_interactive_focus(worker_id)
    first_engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata").fetch("interactive_handoff").merge!(
        "owner_instance_id" => "crashed-dashboard",
        "owner_instance_pid" => 999_999,
        "interactive_pid" => 999_998
      )
    end
    client.resume_error = IOError.new("attach failed during restart")

    restarted_engine = build_engine(harness_client: client)
    result = restarted_engine.reconcile_sessions

    preserved = agent(restarted_engine, worker_id)
    assert_equal "working", preserved.fetch("status")
    refute_equal "completed", preserved.fetch("status")
    assert_equal "resume_failed", preserved.dig("harness_metadata", "interactive_handoff", "state")
    assert_empty result.dig("result", "poll_results"), "failed focus return must remain outside ordinary settlement polling"
    assert_empty client.prompts
  end

  def test_dashboard_return_does_not_continue_again_after_native_focus_finished
    client = InteractiveHarnessClient.new
    client.streaming = true
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    engine.begin_agent_interactive_focus(worker_id)
    engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    client.native_completed = true

    resumed = engine.end_agent_interactive_focus(worker_id)

    assert_equal "accepted", resumed.fetch("status")
    assert_empty client.prompts
    assert_equal "interactive_closed", agent(engine, worker_id).dig("harness_metadata", "last_interactive_handoff", "outcome")
    assert_equal "idle", agent(engine, worker_id).fetch("status")
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
    assert_equal 1, client.aborts.length
    warning = state(second_engine).fetch("logs").last
    assert_equal "warning", warning.fetch("level")
    assert_equal "BeginInteractiveFocus", warning.dig("details", "command_type")
    assert_includes warning.fetch("message"), "already has an interactive focus transition in progress"
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
    assert_empty client.aborts
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

  def test_a_focused_prompt_reactivates_a_completed_worker_and_rolls_up_its_issue
    client = InteractiveHarnessClient.new
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    patch_state! do |durable_state|
      durable_state.fetch("agents").find { |record| record.fetch("id") == worker_id }["status"] = "completed"
      durable_state.fetch("issues").find { |record| record.fetch("id") == context.fetch("issue_id") }["status"] = "completed"
    end

    result = engine.note_agent_interactive_prompt(worker_id)
    worker = agent(engine, worker_id)

    assert_equal "accepted", result.fetch("status")
    assert_equal "working", worker.fetch("status")
    assert_equal true, worker.dig("harness_metadata", "is_streaming")
    assert_equal "working", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_equal worker.fetch("updated_at"), worker.dig("harness_metadata", "focused_prompt_at")
  end

  def test_returning_after_a_completed_worker_was_prompted_keeps_it_working_until_reconciled
    client = InteractiveHarnessClient.new
    client.native_completed = true
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    patch_agent!(worker_id) { |record| record["status"] = "completed" }

    engine.begin_agent_interactive_focus(worker_id)
    engine.mark_agent_interactive_focus_started(worker_id, pid: 52_424)
    engine.note_agent_interactive_prompt(worker_id)
    resumed = engine.end_agent_interactive_focus(worker_id)

    assert_equal "accepted", resumed.fetch("status")
    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_equal "working", issue(engine, context.fetch("issue_id")).fetch("status")
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
    failure_log = state(engine).fetch("logs").last
    assert_equal [failure_log.fetch("id")], result.fetch("log_entry_ids")
    assert_equal "error", failure_log.fetch("level")
    assert_equal "BeginInteractiveFocus", failure_log.dig("details", "command_type")
    assert_includes failure_log.fetch("message"), "handoff preparation failed"
  end

  def test_prepare_failure_does_not_settle_a_pending_tool_turn_or_start_recovery
    client = InteractiveHarnessClient.new
    client.streaming = true
    client.resume_streaming = false
    client.prepare_error = IOError.new("handoff preparation failed")
    client.reported_turn_outcome = {
      "state" => "incomplete",
      "kind" => "pending_tool_call",
      "reason" => "its last turn stopped while a tool call was still pending",
      "stop_reason" => "toolUse"
    }
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Keep this assignment.").fetch("target_id")
    original = agent(engine, worker_id)

    failed = engine.begin_agent_interactive_focus(worker_id)
    client.streaming = false
    reconciled = engine.reconcile_sessions
    recovered = agent(engine, worker_id)

    assert_equal "failed", failed.fetch("status")
    assert_equal "recoverable", reconciled.dig("result", "poll_results").first.fetch("state")
    assert_equal "idle", recovered.fetch("status")
    assert_equal original.fetch("harness_session_id"), recovered.fetch("harness_session_id")
    assert_equal original.fetch("harness_session_file"), recovered.fetch("harness_session_file")
    assert Dir.exist?(recovered.fetch("workspace_path")), "focus preparation must not remove the worker workspace"
    assert_nil recovered.dig("harness_metadata", "settle_failure")
    assert_equal "pending_tool_call", recovered.dig("harness_metadata", "incomplete_turn", "kind")
    assert log_messages(engine).any? { |message| message.include?("Could not prepare worker #{worker_id} for interactive focus") }
    refute_includes log_messages(engine), "Started one bounded self-fixing recovery for worker #{worker_id}"
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
    refute recovered.fetch("harness_metadata").fetch("is_streaming"),
           "a failed focus rollback must not leave a dead session marked streaming"
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
    failure_log = state(engine).fetch("logs").last
    assert_equal [failure_log.fetch("id")], failed.fetch("log_entry_ids")
    assert_equal "error", failure_log.fetch("level")
    assert_equal "EndInteractiveFocus", failure_log.dig("details", "command_type")
    assert_includes failure_log.fetch("message"), "cannot restart RPC"

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
