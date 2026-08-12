# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Pi RPC workers are long-lived children of the Meringue dashboard process. If that one supervisor
# exits, every child's stdin pipe closes together. The Pi processes then exit even though their
# durable JSONL sessions and dedicated workspaces remain valid. These tests model that shared cause
# separately from an isolated harness crash (covered by dead_harness_process_test.rb).
class KernelWorkersSupervisorExitRecoveryTest < Minitest::Test
  include KernelWorkersSupport

  PROCESS_GONE_MESSAGE = "Pi session has no live process and no completed assistant response"

  class ProcessGoneError < StandardError
    include Meringue::Harness::SessionProcessGoneError
  end

  class SupervisorExitHarnessClient < RecordingHarnessClient
    attr_reader :attaches
    attr_accessor :attach_error, :gate_attach

    def initialize(**options)
      super(**options)
      @attaches = []
      @dead_session_ids = Set.new
      @attached_session_ids = Set.new
      @recovered_session_ids = Set.new
      @replacement_pids = {}
      @attach_error = nil
      @gate_attach = false
      @attach_started = Queue.new
      @continue_attach = Queue.new
    end

    def lose_supervisor!(*session_ids)
      @dead_session_ids.merge(session_ids.flatten.map(&:to_s))
    end

    def release_attach
      @continue_attach << true
    end

    def wait_for_attach
      Timeout.timeout(5) { @attach_started.pop }
    end

    def get_state(session_ref)
      session_id = session_ref.fetch("session_id").to_s
      raise ProcessGoneError, PROCESS_GONE_MESSAGE if dead?(session_id)

      session_ref.merge(
        "pid" => @replacement_pids.fetch(session_id, session_ref.fetch("pid", nil)),
        "is_streaming" => @recovered_session_ids.include?(session_id)
      )
    end

    def session_supervision_evidence(session_ref)
      return nil unless @dead_session_ids.include?(session_ref.fetch("session_id").to_s)

      {
        "source" => "transport_ownership",
        "transport_key" => "pi-#{session_ref.fetch("session_id")}",
        "owner_pid" => 14_111,
        "owner_started_at" => "2026-01-01T14:00:00Z",
        "owner_alive" => false,
        "harness_pid" => session_ref.fetch("pid", nil),
        "harness_alive" => false,
        "supervisor_exited" => true,
        "observed_at" => "2026-01-01T14:11:19Z"
      }
    end

    def attach_session(session_ref)
      session_id = session_ref.fetch("session_id").to_s
      @attaches << session_id
      @attach_started << session_id if gate_attach
      @continue_attach.pop if gate_attach
      raise attach_error if attach_error

      replacement_pid = 90_000 + @attaches.length
      @replacement_pids[session_id] = replacement_pid
      @attached_session_ids << session_id
      session_ref.merge("pid" => replacement_pid, "is_streaming" => false)
    end

    def prompt_session(session_ref, prompt, mode: "normal")
      session_id = session_ref.fetch("session_id").to_s
      attached = dead?(session_id) ? attach_session(session_ref) : session_ref
      result = super(attached, prompt, mode: mode)
      @recovered_session_ids << session_id
      result.merge("pid" => @replacement_pids.fetch(session_id), "is_streaming" => true)
    end

    private

    def dead?(session_id)
      @dead_session_ids.include?(session_id) &&
        !@attached_session_ids.include?(session_id) &&
        !@recovered_session_ids.include?(session_id)
    end
  end

  def build_supervised_workers(count: 1, client: SupervisorExitHarnessClient.new(provider: "pi"))
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_ids = Array.new(count) do |index|
      spawn_worker(
        engine,
        context.fetch("issue_id"),
        prompt: "Do worker task #{index + 1}.",
        title: "Worker task #{index + 1}"
      ).fetch("target_id")
    end
    session_ids = worker_ids.map { |worker_id| agent(engine, worker_id).fetch("harness_session_id") }
    client.lose_supervisor!(session_ids)
    [engine, client, context, worker_ids]
  end

  def test_nine_workers_lost_with_one_supervisor_are_resumed_in_one_bounded_reconciliation_pass
    engine, client, _context, worker_ids = build_supervised_workers(count: 9)
    before = worker_ids.to_h do |worker_id|
      worker = agent(engine, worker_id)
      [worker_id, worker.slice("harness_session_id", "workspace_path", "workspace_branch")]
    end

    result = apply!(engine, "ReconcileSessions", {})

    assert_equal 9, result.dig("result", "changed_count")
    assert_equal ["recovered"], result.dig("result", "poll_results").map { |poll| poll.fetch("state") }.uniq
    assert_equal 9, client.attaches.length
    assert_equal 9, client.prompts.length
    recovery_ids = client.prompts.map do |delivery|
      delivery.fetch("prompt").match(/Meringue supervisor recovery id: (\S+)/)&.captures&.first
    end
    assert_equal 9, recovery_ids.compact.uniq.length, "each worker must receive one uniquely claimed continuation"

    worker_ids.each do |worker_id|
      worker = agent(engine, worker_id)
      assert_equal "working", worker.fetch("status")
      assert_equal before.fetch(worker_id).fetch("harness_session_id"), worker.fetch("harness_session_id")
      assert_equal before.fetch(worker_id).fetch("workspace_path"), worker.fetch("workspace_path")
      assert_equal before.fetch(worker_id).fetch("workspace_branch"), worker.fetch("workspace_branch")
      assert_equal "resumed", worker.dig("harness_metadata", "supervisor_recovery", "state")
      assert_equal 1, worker.dig("harness_metadata", "supervisor_recovery", "attempt_count")
      assert_equal false, worker.dig("harness_metadata", "supervisor_recovery", "supervision", "owner_alive")
    end

    logs = state(engine).fetch("logs")
    assert_equal 9, logs.count { |entry| entry.fetch("message", "").include?("supervising Meringue process exited") }
    refute logs.any? { |entry| entry.fetch("message", "").include?("harness process exited") }

    apply!(engine, "ReconcileSessions", {})
    assert_equal 9, client.prompts.length, "periodic reconciliation must not replay recovered continuations"
    assert_equal 9, client.attaches.length
  end

  def test_a_pending_user_prompt_recovers_the_transport_before_the_operational_continuation
    engine, client, _context, worker_ids = build_supervised_workers
    worker_id = worker_ids.fetch(0)
    queued_prompt = "Use the already-reviewed migration plan."
    command_id = "queued-after-restart"
    seeded = store.load
    worker = seeded.fetch("agents").find { |record| record.fetch("id") == worker_id }
    worker.fetch("harness_metadata")["pending_prompts"] = [
      {
        "id" => "#{worker_id}-PP1",
        "command_id" => command_id,
        "prompt" => queued_prompt,
        "mode" => "normal",
        "queued_at" => "2026-01-01T14:10:59Z"
      }
    ]
    store.save(seeded)

    apply!(engine, "ReconcileSessions", {})

    assert_equal [queued_prompt], client.prompts.map { |delivery| delivery.fetch("prompt") }
    assert_equal 1, client.attaches.length
    recovered = agent(engine, worker_id)
    assert_equal "working", recovered.fetch("status")
    assert_empty recovered.dig("harness_metadata", "pending_prompts")
    assert_includes recovered.dig("harness_metadata", "prompt_command_ids"), command_id
    refute client.prompts.first.fetch("prompt").include?("Meringue supervisor recovery id")

    apply!(engine, "ReconcileSessions", {})
    assert_equal 1, client.prompts.length, "the queued command must remain exactly-once after recovery"
  end

  def test_a_live_reconciler_claim_prevents_another_instance_from_attaching_or_prompting
    engine, first_client, _context, worker_ids = build_supervised_workers
    worker_id = worker_ids.fetch(0)
    first_client.gate_attach = true
    second_client = SupervisorExitHarnessClient.new(provider: "pi")
    second_client.lose_supervisor!(agent(engine, worker_id).fetch("harness_session_id"))
    second_engine = build_engine(harness_client: second_client)

    first_result = nil
    first_thread = Thread.new { first_result = apply!(engine, "ReconcileSessions", {}) }
    first_client.wait_for_attach

    competing = apply!(second_engine, "ReconcileSessions", {})
    queued_prompt = apply!(
      second_engine,
      "PromptAgent",
      { "agent_id" => worker_id, "prompt" => "Also preserve the queued review note.", "mode" => "normal" }
    )

    assert_equal "unchanged", competing.dig("result", "poll_results", 0, "state")
    assert_equal true, competing.dig("result", "poll_results", 0, "supervisor_recovery_deferred")
    assert_empty second_client.attaches
    assert_empty second_client.prompts
    assert_equal "accepted", queued_prompt.fetch("status")
    assert_match(/Queued the prompt/, queued_prompt.fetch("message"))
    assert_equal 1, agent(second_engine, worker_id).dig("harness_metadata", "pending_prompts").length
    assert_equal "claimed", agent(second_engine, worker_id).dig("harness_metadata", "supervisor_recovery", "state")

    first_client.release_attach
    first_thread.join(5)
    refute first_thread.alive?, "the claiming reconciler should finish after its attach is released"
    assert_equal "recovered", first_result.dig("result", "poll_results", 0, "state")
    assert_equal 1, first_client.attaches.length
    assert_equal 1, first_client.prompts.length
    assert_equal "resumed", agent(engine, worker_id).dig("harness_metadata", "supervisor_recovery", "state")

    apply!(engine, "ReconcileSessions", {})
    assert_equal 2, first_client.prompts.length
    assert_equal "Also preserve the queued review note.", first_client.prompts.last.fetch("prompt")
    assert_empty agent(engine, worker_id).dig("harness_metadata", "pending_prompts")
  ensure
    first_client&.release_attach if first_thread&.alive?
    first_thread&.join(1)
  end

  def test_failed_supervisor_recovery_is_bounded_before_falling_back_to_process_exit_settlement
    client = SupervisorExitHarnessClient.new(provider: "pi")
    client.attach_error = IOError.new("Pi refused to resume the saved transcript")
    engine, client, _context, worker_ids = build_supervised_workers(client: client)
    worker_id = worker_ids.fetch(0)
    original = agent(engine, worker_id).slice("harness_session_id", "workspace_path", "workspace_branch")

    2.times do |index|
      apply!(engine, "ReconcileSessions", {})
      worker = agent(engine, worker_id)
      assert_equal "blocked", worker.fetch("status")
      assert_equal index + 1, worker.dig("harness_metadata", "supervisor_recovery", "attempt_count")
      assert_equal original.fetch("harness_session_id"), worker.fetch("harness_session_id")
      assert_equal original.fetch("workspace_path"), worker.fetch("workspace_path")
      assert_equal original.fetch("workspace_branch"), worker.fetch("workspace_branch")
    end

    apply!(engine, "ReconcileSessions", {})
    worker = agent(engine, worker_id)
    assert_equal "errored", worker.fetch("status")
    assert_equal 3, worker.dig("harness_metadata", "supervisor_recovery", "attempt_count")
    assert_equal "harness_process_exited", worker.dig("harness_metadata", "settle_failure", "kind")
    assert_equal 3, client.attaches.length

    apply!(engine, "ReconcileSessions", {})
    assert_equal 3, client.attaches.length, "an exhausted recovery must never become a restart loop"
  end
end
