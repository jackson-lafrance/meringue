# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Production SpawnWorker persists intent and returns before workspace or harness I/O. These tests
# hold allocation at a deterministic barrier so a synchronous regression would hang instead of
# merely looking a little slower on a test repository.
class KernelWorkersAsynchronousProvisioningTest < Minitest::Test
  include KernelWorkersSupport

  class BlockingWorkspaceManager < Meringue::Workspace::Manager
    attr_reader :maximum_active, :allocation_count

    def initialize(**options)
      super
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @held = true
      @active = 0
      @maximum_active = 0
      @allocation_count = 0
    end

    def allocate_worker_workspace(**options)
      @mutex.synchronize do
        @allocation_count += 1
        @active += 1
        @maximum_active = [@maximum_active, @active].max
        @condition.broadcast
        @condition.wait(@mutex) while @held
      end
      super
    ensure
      @mutex.synchronize do
        @active -= 1
        @condition.broadcast
      end
    end

    def wait_for_allocations(count, timeout: 2)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        while @allocation_count < count
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false unless remaining.positive?

          @condition.wait(@mutex, remaining)
        end
      end
      true
    end

    def release
      @mutex.synchronize do
        @held = false
        @condition.broadcast
      end
    end
  end

  def test_spawn_returns_after_durable_reservation_and_independent_workers_provision_concurrently
    manager = BlockingWorkspaceManager.new(root_path: workspace_root)
    engine = build_async_engine(manager, concurrency: 2)
    context = project_with_issue(engine)
    second_issue = create_issue(engine, context.fetch("project_id"), title: "Fix account export")
    third_issue = create_issue(engine, context.fetch("project_id"), title: "Fix search indexing")

    results = [context.fetch("issue_id"), second_issue, third_issue].map do |issue_id|
      apply_raw(engine, "SpawnWorker", { "issue_id" => issue_id, "prompt" => "Go." })
    end

    assert results.all? { |result| result.fetch("status") == "accepted" }
    assert results.all? { |result| result.fetch("message").include?("provisioning will continue in the background") }
    assert manager.wait_for_allocations(2), "two independent reservations should enter allocation"
    assert_equal 2, manager.maximum_active
    assert_equal 3, state(engine).fetch("agents").length
    assert state(engine).fetch("agents").all? { |worker| worker.fetch("status") == "queued" }
    assert_includes state(engine).fetch("agents").map { |worker| worker.dig("harness_metadata", "provisioning_state") },
                    "provisioning_queued"
    assert_empty @harness_client.spawns

    manager.release
    assert engine.wait_for_worker_provisioning(timeout: 5)
    workers = state(engine).fetch("agents")
    assert workers.all? { |worker| worker.fetch("status") == "working" }
    assert workers.all? { |worker| worker.dig("harness_metadata", "provisioning_state") == "ready" }
    assert_equal 3, @harness_client.spawns.length
    assert_equal 2, manager.maximum_active, "the configured bound must apply to the whole batch"
  ensure
    manager&.release
    engine&.wait_for_worker_provisioning(timeout: 5)
  end

  def test_replaying_spawn_while_provisioning_reuses_the_reservation_exactly_once
    manager = BlockingWorkspaceManager.new(root_path: workspace_root)
    engine = build_async_engine(manager, concurrency: 1)
    context = project_with_issue(engine)
    payload = { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." }

    first = apply_raw(engine, "SpawnWorker", payload, command_id: "C-async")
    assert manager.wait_for_allocations(1)
    replay = apply_raw(engine, "SpawnWorker", payload, command_id: "C-async")

    assert_equal first.fetch("target_id"), replay.fetch("target_id")
    assert_includes replay.fetch("message"), "already reserved"
    assert_equal 1, state(engine).fetch("agents").length
    assert_equal 1, manager.allocation_count

    manager.release
    assert engine.wait_for_worker_provisioning(timeout: 5)
    assert_equal 1, @harness_client.spawns.length
  ensure
    manager&.release
    engine&.wait_for_worker_provisioning(timeout: 5)
  end

  def test_prompt_for_a_reserved_worker_is_durable_and_delivered_in_its_first_turn
    manager = BlockingWorkspaceManager.new(root_path: workspace_root)
    engine = build_async_engine(manager, concurrency: 1)
    context = project_with_issue(engine)
    spawned = apply_raw(
      engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Initial work." },
      command_id: "H1-C1"
    )
    assert manager.wait_for_allocations(1)

    prompted = apply_raw(
      engine, "PromptAgent", { "agent_id" => spawned.fetch("target_id"), "prompt" => "Also preserve compatibility." },
      command_id: "H1-C2"
    )
    replay = apply_raw(
      engine, "PromptAgent", { "agent_id" => spawned.fetch("target_id"), "prompt" => "Also preserve compatibility." },
      command_id: "H1-C2"
    )

    assert_equal "accepted", prompted.fetch("status")
    assert_includes prompted.fetch("message"), "pending launch"
    assert_includes replay.fetch("message"), "already delivered"
    manager.release
    assert engine.wait_for_worker_provisioning(timeout: 5)
    launch_prompt = @harness_client.spawns.fetch(0).fetch("prompt")
    assert_includes launch_prompt, "Initial work."
    assert_includes launch_prompt, "Also preserve compatibility."
    assert_equal 1, launch_prompt.scan("Also preserve compatibility.").length
  ensure
    manager&.release
    engine&.wait_for_worker_provisioning(timeout: 5)
  end

  def test_deferred_worker_stays_dormant_then_activates_through_the_executor
    context_engine = build_engine
    context = project_with_issue(context_engine)
    predecessor = spawn_worker(context_engine, context.fetch("issue_id"), prompt: "Research.").fetch("target_id")
    manager = BlockingWorkspaceManager.new(root_path: workspace_root)
    engine = build_async_engine(manager, concurrency: 1)

    dependent = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Implement.",
        "after_agent_id" => predecessor,
        "follow_up_of_agent_id" => predecessor
      }
    )
    assert_equal "deferred", agent(engine, dependent.fetch("target_id")).dig("harness_metadata", "provisioning_state")
    assert_equal 0, manager.allocation_count

    patch_agent!(predecessor) do |worker|
      worker["status"] = "completed"
      worker["harness_metadata"] = worker.fetch("harness_metadata").merge(
        "is_streaming" => false,
        "final_report" => "Use the verified parser path."
      )
    end
    reconciliation = engine.reconcile_sessions

    assert_equal [dependent.fetch("target_id")],
                 reconciliation.dig("result", "deferred_worker_results").map { |entry| entry.fetch("target_id") }
    manager.release
    assert engine.wait_for_worker_provisioning(timeout: 5)
    launched = agent(engine, dependent.fetch("target_id"))
    assert_equal "working", launched.fetch("status")
    assert_includes @harness_client.spawns.last.fetch("prompt"), "--- Handover from #{predecessor}"
  ensure
    manager&.release
    engine&.wait_for_worker_provisioning(timeout: 5)
  end

  def test_reconciliation_requeues_a_crash_abandoned_reservation
    manager = BlockingWorkspaceManager.new(root_path: workspace_root)
    first_engine = build_async_engine(manager, concurrency: 1)
    context = project_with_issue(first_engine)
    first_issue = context.fetch("issue_id")
    second_issue = create_issue(first_engine, context.fetch("project_id"), title: "Recover queued worker")
    apply_raw(first_engine, "SpawnWorker", { "issue_id" => first_issue, "prompt" => "Hold the slot." })
    assert manager.wait_for_allocations(1)
    queued = apply_raw(first_engine, "SpawnWorker", { "issue_id" => second_issue, "prompt" => "Recover me." })

    patch_agent!(queued.fetch("target_id")) do |worker|
      worker["harness_metadata"] = worker.fetch("harness_metadata").merge(
        "owner_instance_id" => "dead-instance",
        "owner_instance_pid" => 999_999_999,
        "owner_instance_started_at" => "2000-01-01T00:00:00Z"
      )
    end
    recovery_manager = Meringue::Workspace::Manager.new(root_path: workspace_root, command_timeout: 30)
    recovery_engine = build_async_engine(recovery_manager, concurrency: 2)

    result = recovery_engine.reconcile_sessions
    scheduled = result.dig("result", "recovered_worker_results")
    assert_equal [queued.fetch("target_id")], scheduled.map { |entry| entry.fetch("target_id") }
    assert recovery_engine.wait_for_worker_provisioning(timeout: 5)
    recovered = agent(recovery_engine, queued.fetch("target_id"))
    assert_equal "working", recovered.fetch("status")
    refute_nil recovered.fetch("harness_session_id")

    manager.release
    assert first_engine.wait_for_worker_provisioning(timeout: 5)
    assert_equal 2, state(first_engine).fetch("agents").length
  ensure
    manager&.release
    first_engine&.wait_for_worker_provisioning(timeout: 5)
    recovery_engine&.wait_for_worker_provisioning(timeout: 5)
  end

  private

  def build_async_engine(manager, concurrency:)
    Meringue::Kernel::Engine.new(
      store: store,
      harness_client: @harness_client,
      head_runner: Meringue::Heads::FakeRunner.new,
      workspace_manager: manager,
      cwd: tmpdir,
      forge_client: OfflineForgeClient.new,
      config_path: tmp_path("config.toml"),
      async_worker_provisioning: true,
      worker_provisioning_concurrency: concurrency
    )
  end
end
