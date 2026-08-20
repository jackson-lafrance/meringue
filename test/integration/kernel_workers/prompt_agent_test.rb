# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# PromptAgent: mode selection and bookkeeping, mapping onto the harness client's
# queued-prompt behavior, transient queueing, and rejection of unroutable agents.
class KernelWorkersPromptAgentTest < Minitest::Test
  include KernelWorkersSupport

  class ReceiptHarnessClient < KernelWorkersSupport::RecordingHarnessClient
    attr_accessor :receipt_status
    attr_reader :delivery_ids, :receipt_checks, :state_reads

    def initialize
      super(streaming: true, provider: "pi")
      @receipt_status = "pending"
      @delivery_ids = []
      @receipt_checks = 0
      @state_reads = 0
      @timeout_next_prompt = true
    end

    def prompt_delivery_receipts_supported?
      true
    end

    def ambiguous_prompt_delivery_error?(error)
      error.is_a?(Meringue::Harness::PiClient::RpcTimeoutError) && error.command_type == "follow_up"
    end

    def prompt_session(session_ref, prompt, mode: "normal", delivery_id: nil)
      @delivery_ids << delivery_id
      result = super(session_ref, prompt, mode: mode)
      if @timeout_next_prompt
        @timeout_next_prompt = false
        raise Meringue::Harness::PiClient::RpcTimeoutError.new(
          "Timed out waiting for Pi RPC response to \"follow_up\"",
          command_type: "follow_up"
        )
      end
      result
    end

    def prompt_delivery_status(session_ref, delivery_id:, prompt:, started_at: nil)
      @receipt_checks += 1
      {
        "status" => receipt_status,
        "process_alive" => receipt_status != "not_delivered",
        "pid" => receipt_status == "delivered" ? session_ref.fetch("pid", nil) : nil,
        "delivered_at" => receipt_status == "delivered" ? "2026-01-01T00:00:05Z" : nil
      }.compact
    end

    def get_state(session_ref)
      @state_reads += 1
      super
    end
  end

  def test_normal_prompt_continues_the_existing_session
    engine = build_engine
    worker_id = spawned_worker(engine)

    result = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Also update the changelog." })
    worker = agent(engine, worker_id)
    prompt_call = @harness_client.prompts.fetch(0)

    assert_equal "normal", prompt_call.fetch("mode")
    assert_equal "Also update the changelog.", prompt_call.fetch("prompt")
    assert_equal worker.fetch("harness_session_id"), prompt_call.fetch("session_id")
    assert_equal "working", worker.fetch("status")
    assert_equal 1, worker.fetch("harness_metadata").fetch("prompt_count")
    assert_equal "normal", worker.fetch("harness_metadata").fetch("last_prompt_mode")
    assert_equal "resume_session", worker.fetch("harness_metadata").fetch("routing_action")
    assert_equal "resume_session", issue(engine, "P1-I1").fetch("last_routing_action")
    assert_equal worker_id, issue(engine, "P1-I1").fetch("last_agent_id")
    assert_equal "Continued worker #{worker_id} on P1-I1 using its existing session.", result.fetch("message")
    assert_includes log_messages(engine), result.fetch("message")
  end

  def test_replaying_a_prompt_command_id_does_not_deliver_twice
    engine = build_engine
    worker_id = spawned_worker(engine)

    first = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Only deliver this once." }, command_id: "prompt-once")
    second = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Only deliver this once." }, command_id: "prompt-once")

    assert_equal "accepted", first.fetch("status")
    assert_equal "accepted", second.fetch("status")
    assert_equal worker_id, second.fetch("target_id")
    assert_equal ["Only deliver this once."], @harness_client.prompts.map { |call| call.fetch("prompt") }
    assert_equal 1, agent(engine, worker_id).fetch("harness_metadata").fetch("prompt_count")
  end

  def test_prompt_queues_behind_a_live_cross_instance_delivery_claim
    engine = build_engine
    worker_id = spawned_worker(engine)
    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata")["prompt_delivery_claim"] = {
        "token" => "other-claim",
        "owner_instance_id" => "other-instance",
        "owner_instance_pid" => Process.pid,
        "command_id" => "other-command"
      }
    end

    result = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Wait for the active delivery." }, command_id: "wait-command")
    worker = agent(engine, worker_id)

    assert_equal "accepted", result.fetch("status")
    assert_equal true, result.dig("result", "queued")
    assert_empty @harness_client.prompts
    assert_equal ["Wait for the active delivery."], worker.fetch("harness_metadata").fetch("pending_prompts").map { |entry| entry.fetch("prompt") }
  end

  def test_timed_out_prompt_waits_for_durable_receipt_and_is_not_replayed
    @harness_client = ReceiptHarnessClient.new
    engine = build_engine
    worker_id = spawned_worker(engine)

    result = apply_raw(
      engine,
      "PromptAgent",
      { "agent_id" => worker_id, "prompt" => "Continue after compaction." },
      command_id: "H138-C5"
    )
    worker = agent(engine, worker_id)
    pending = worker.fetch("harness_metadata").fetch("pending_prompts").fetch(0)

    assert_equal "accepted", result.fetch("status"), "an unacknowledged delivery must not fail its command journal entry"
    assert_equal true, result.dig("result", "awaiting_receipt")
    assert_equal "awaiting_receipt", pending.fetch("delivery_state")
    assert_equal "meringue:H138-C5", pending.fetch("delivery_id")
    assert_equal ["meringue:H138-C5"], @harness_client.delivery_ids
    assert_equal 1, logs_matching(engine, /durable session receipt/).length

    apply!(engine, "ReconcileSessions", {})

    assert_equal 1, @harness_client.receipt_checks
    assert_equal 0, @harness_client.state_reads,
                 "ordinary polling must not race a live prompt whose acknowledgement timed out"
    assert_equal 1, @harness_client.prompts.length
    assert_equal 0, agent(engine, worker_id).fetch("harness_metadata").fetch("prompt_count", 0)

    @harness_client.receipt_status = "delivered"
    apply!(engine, "ReconcileSessions", {})
    apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal 1, @harness_client.prompts.length, "the transcript receipt must replace RPC replay"
    assert_equal 1, worker.fetch("harness_metadata").fetch("prompt_count")
    assert_includes worker.fetch("harness_metadata").fetch("prompt_command_ids"), "H138-C5"
    assert_empty worker.fetch("harness_metadata").fetch("pending_prompts")
    assert state(engine).fetch("logs").any? { |entry|
      entry.fetch("details", {}).fetch("delivery_confirmation", nil) == "pi_session_transcript"
    }
  end

  def test_later_prompts_cannot_pass_a_timed_out_prompt_awaiting_receipt
    @harness_client = ReceiptHarnessClient.new
    engine = build_engine
    worker_id = spawned_worker(engine)

    apply_raw(
      engine,
      "PromptAgent",
      { "agent_id" => worker_id, "prompt" => "First, continue after compaction." },
      command_id: "H138-C5"
    )
    later = apply_raw(
      engine,
      "PromptAgent",
      { "agent_id" => worker_id, "prompt" => "Then report the result." },
      command_id: "H139-C1"
    )

    assert_equal "accepted", later.fetch("status")
    assert_equal 1, @harness_client.prompts.length
    assert_equal [
      "First, continue after compaction.",
      "Then report the result."
    ], agent(engine, worker_id).dig("harness_metadata", "pending_prompts").map { |entry| entry.fetch("prompt") }

    apply!(engine, "ReconcileSessions", {})
    assert_equal 1, @harness_client.prompts.length

    @harness_client.receipt_status = "delivered"
    apply!(engine, "ReconcileSessions", {})
    assert_equal 1, @harness_client.prompts.length,
                 "the pending-delivery snapshot must not send a later prompt in the receipt-confirmation pass"

    apply!(engine, "ReconcileSessions", {})
    assert_equal [
      "First, continue after compaction.",
      "Then report the result."
    ], @harness_client.prompts.map { |call| call.fetch("prompt") }
  end

  def test_timed_out_prompt_retries_only_after_dead_process_and_durable_absence
    @harness_client = ReceiptHarnessClient.new
    engine = build_engine
    worker_id = spawned_worker(engine)

    apply_raw(
      engine,
      "PromptAgent",
      { "agent_id" => worker_id, "prompt" => "Continue after compaction." },
      command_id: "H138-C5"
    )
    @harness_client.receipt_status = "not_delivered"
    second_engine = build_engine

    [engine, second_engine].map { |candidate|
      Thread.new { apply!(candidate, "ReconcileSessions", {}) }
    }.each(&:value)
    worker = agent(engine, worker_id)

    assert_equal 2, @harness_client.prompts.length,
                 "concurrent reconcilers may issue only one retry after proving durable absence"
    assert_equal ["meringue:H138-C5", "meringue:H138-C5"], @harness_client.delivery_ids
    assert_equal 1, worker.fetch("harness_metadata").fetch("prompt_count")
    assert_empty worker.fetch("harness_metadata").fetch("pending_prompts")
  end

  def test_steer_mode_is_forwarded_to_the_active_session
    engine = build_engine
    worker_id = spawned_worker(engine)
    @harness_client.streaming = true

    result = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Stop, wrong file.", "mode" => "steer" })
    worker = agent(engine, worker_id)

    assert_equal "steer", @harness_client.prompts.fetch(0).fetch("mode")
    assert_equal "steer", worker.fetch("harness_metadata").fetch("last_prompt_mode")
    assert_equal "steer_active_session", worker.fetch("harness_metadata").fetch("routing_action")
    assert_equal true, worker.fetch("harness_metadata").fetch("is_streaming")
    assert_equal "Steered active worker #{worker_id} on P1-I1 with the user's correction.", result.fetch("message")
  end

  def test_follow_up_mode_maps_to_the_harness_queued_prompt_behavior
    engine = build_engine
    worker_id = spawned_worker(engine)

    result = apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Then open the PR.", "mode" => "follow_up" })
    worker = agent(engine, worker_id)

    assert_equal "follow_up", @harness_client.prompts.fetch(0).fetch("mode")
    assert_equal ["Then open the PR."], worker.fetch("harness_metadata").fetch("queued_prompts")
    assert_equal "queue_follow_up", worker.fetch("harness_metadata").fetch("routing_action")
    assert_equal "Queued a follow-up for worker #{worker_id} on P1-I1.", result.fetch("message")
  end

  # Regression: a head routing a plain user message picks mode "normal". When the target session was
  # mid-turn the kernel used to fail the command and the user's message was lost.
  def test_normal_prompt_against_a_streaming_session_is_delivered_as_a_follow_up
    engine = build_engine
    worker_id = spawned_worker(engine)
    @harness_client.streaming = true

    result = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Extend it to completed rows too." })
    worker = agent(engine, worker_id)
    metadata = worker.fetch("harness_metadata")

    assert_equal "accepted", result.fetch("status")
    assert_equal "follow_up", @harness_client.prompts.fetch(0).fetch("mode")
    assert_equal "normal", @harness_client.prompts.fetch(0).fetch("requested_mode")
    assert_equal ["Extend it to completed rows too."], metadata.fetch("queued_prompts")
    assert_equal "follow_up", metadata.fetch("last_prompt_mode")
    assert_equal "normal", metadata.fetch("requested_prompt_mode")
    assert_equal "queue_follow_up", metadata.fetch("routing_action")
    assert_equal "queue_follow_up", issue(engine, "P1-I1").fetch("last_routing_action")
    # The coercion is stated in the user-visible line instead of being silently relabelled.
    assert_match(/Queued a follow-up for worker #{worker_id} on P1-I1\./, result.fetch("message"))
    assert_match(/Requested normal, delivered follow_up: /, result.fetch("message"))
    assert_includes log_messages(engine), result.fetch("message")
    assert_empty Array(metadata["pending_prompts"]), "an accepted delivery must not also be queued for redelivery"
  end

  def test_a_prompt_delivered_mid_turn_is_not_redelivered_once_the_session_settles
    engine = build_engine
    worker_id = spawned_worker(engine)
    @harness_client.streaming = true

    apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Extend it to completed rows too." }, command_id: "C-27")
    @harness_client.streaming = false
    apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_equal ["Extend it to completed rows too."], @harness_client.prompts.map { |call| call.fetch("prompt") }
    assert_equal 1, worker.fetch("harness_metadata").fetch("prompt_count")
    assert_empty Array(worker.fetch("harness_metadata")["pending_prompts"])
    assert_equal 1, logs_matching(engine, /Queued a follow-up for worker #{worker_id}/).length
  end

  def test_steer_semantics_are_unchanged_when_a_session_is_streaming
    engine = build_engine
    worker_id = spawned_worker(engine)
    @harness_client.streaming = true

    apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Stop, wrong file.", "mode" => "steer" })
    apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Then open the PR.", "mode" => "follow_up" })
    metadata = agent(engine, worker_id).fetch("harness_metadata")

    assert_equal %w[steer follow_up], @harness_client.prompt_modes
    assert_nil metadata["requested_prompt_mode"], "an as-requested delivery records no coercion"
    assert_nil metadata["prompt_mode_note"]
  end

  def test_prompt_bookkeeping_accumulates_across_modes
    engine = build_engine
    worker_id = spawned_worker(engine)

    apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "One." })
    apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Two.", "mode" => "follow_up" })
    apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Three.", "mode" => "steer" })
    worker = agent(engine, worker_id)

    assert_equal %w[normal follow_up steer], @harness_client.prompt_modes
    assert_equal 3, worker.fetch("harness_metadata").fetch("prompt_count")
    assert_equal "steer", worker.fetch("harness_metadata").fetch("last_prompt_mode")
    refute_nil worker.fetch("harness_metadata").fetch("last_prompted_at")
  end

  def test_unknown_mode_is_rejected
    engine = build_engine
    worker_id = spawned_worker(engine)

    result = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Go.", "mode" => "shout" })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "mode must be one of normal, steer, follow_up"
    assert_empty @harness_client.prompts
  end

  def test_missing_agent_id_and_prompt_are_rejected
    engine = build_engine

    result = apply_raw(engine, "PromptAgent", { "prompt" => "   " })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_id is required"
    assert_includes result.fetch("errors"), "prompt is required"
  end

  def test_unknown_agent_is_rejected
    engine = build_engine

    result = apply_raw(engine, "PromptAgent", { "agent_id" => "P1-I1-W7", "prompt" => "Go." })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_not_found"
    assert_empty @harness_client.prompts
  end

  def test_killed_worker_cannot_be_prompted
    engine = build_engine
    worker_id = spawned_worker(engine)
    patch_agent!(worker_id) { |record| record["status"] = "killed" }

    result = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Go." })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_not_resumable"
    assert_empty @harness_client.prompts
  end

  def test_errored_worker_cannot_be_prompted
    engine = build_engine
    worker_id = spawned_worker(engine)
    patch_agent!(worker_id) { |record| record["status"] = "errored" }

    result = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Go." })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_not_resumable"
  end

  # A head record without its original request cannot be safely taken over. Stopped heads still
  # use the separate `/retry H<n>` command.
  def test_working_head_agents_without_a_recorded_request_are_not_promptable_as_workers
    engine = build_engine
    spawned_worker(engine)
    patch_state! do |state|
      state.fetch("agents") << {
        "id" => "H1",
        "type" => "head",
        "status" => "working",
        "project_id" => nil,
        "issue_id" => nil,
        "harness" => "fake",
        "pid" => 999,
        "harness_session_id" => "fake-head-session-1",
        "harness_session_file" => nil,
        "harness_metadata" => {},
        "created_at" => "2026-01-01T00:00:00Z",
        "updated_at" => "2026-01-01T00:00:00Z"
      }
    end

    result = apply_raw(engine, "PromptAgent", { "agent_id" => "H1", "prompt" => "Go." })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "head_request_unavailable"
    assert_includes result.fetch("message"), "fresh prompt"
    assert_empty @harness_client.prompts
    assert_equal "head", agent(engine, "H1").fetch("type")
    assert_equal "working", agent(engine, "H1").fetch("status")
  end

  def test_worker_without_a_harness_session_is_rejected
    engine = build_engine
    worker_id = spawned_worker(engine)
    patch_agent!(worker_id) do |record|
      record["pid"] = nil
      record["harness_session_id"] = nil
      record["harness_session_file"] = nil
    end

    result = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Go." })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "missing_harness_session"
    assert_empty @harness_client.prompts
  end

  def test_transient_session_error_queues_the_prompt_for_redelivery
    engine = build_engine
    worker_id = spawned_worker(engine)
    @harness_client.prompt_error = BusySessionError.new("session is owned by another turn")

    queued = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Add the migration." }, command_id: "C-9")
    pending = agent(engine, worker_id).fetch("harness_metadata").fetch("pending_prompts")

    assert_equal "accepted", queued.fetch("status")
    assert_equal true, queued.fetch("result").fetch("queued")
    assert_equal 1, pending.length
    assert_equal "Add the migration.", pending.fetch(0).fetch("prompt")
    assert_equal "normal", pending.fetch(0).fetch("mode")
    assert_equal 1, pending.fetch(0).fetch("attempts")
    assert_includes log_messages(engine), "Waiting to deliver the prompt for worker #{worker_id} until its current turn settles."

    @harness_client.prompt_error = nil
    apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)

    assert_empty worker.fetch("harness_metadata").fetch("pending_prompts")
    assert_equal ["Add the migration.", "Add the migration."], @harness_client.prompts.map { |call| call.fetch("prompt") }
    assert_equal 1, worker.fetch("harness_metadata").fetch("prompt_count")
    assert_includes log_messages(engine), "Continued worker #{worker_id} on P1-I1 using its existing session."
  end

  def test_worker_session_service_picks_normal_for_an_idle_session
    engine = build_engine
    worker_id = spawned_worker(engine)
    @harness_client.session_state = "idle"
    session = Meringue::Sessions::WorkerSessionService.new(engine: engine).open(worker_id)

    begin
      result = session.submit("Please continue.")
    ensure
      session.close
    end

    assert_equal "accepted", result.fetch("status")
    assert_equal "normal", result.fetch("session_prompt_mode")
    assert_equal "normal", @harness_client.prompts.fetch(0).fetch("mode")
  end

  def test_worker_session_service_picks_steer_for_a_streaming_session
    engine = build_engine
    worker_id = spawned_worker(engine)
    @harness_client.session_state = "streaming"
    session = Meringue::Sessions::WorkerSessionService.new(engine: engine).open(worker_id)

    begin
      result = session.submit("Stop, wrong file.")
    ensure
      session.close
    end

    assert_equal "accepted", result.fetch("status")
    assert_equal "steer", result.fetch("session_prompt_mode")
    assert_equal "steer", @harness_client.prompts.fetch(0).fetch("mode")
    assert_equal "steer_active_session", agent(engine, worker_id).fetch("harness_metadata").fetch("routing_action")
  end

  def test_worker_session_service_rejects_an_empty_prompt_without_touching_the_harness
    engine = build_engine
    worker_id = spawned_worker(engine)
    session = Meringue::Sessions::WorkerSessionService.new(engine: engine).open(worker_id)

    begin
      result = session.submit("   ")
    ensure
      session.close
    end

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "prompt_required"
    assert_empty @harness_client.prompts
  end

  private

  def spawned_worker(engine)
    context = project_with_issue(engine)
    spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
  end
end
