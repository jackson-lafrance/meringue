# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# A head batch journals durable worker reservations, not multi-minute provisioning work. Holding
# both allocations proves command 2 is applied while command 1's external I/O is still blocked.
class KernelHeadsAsynchronousWorkerBatchTest < KernelHeadsTestCase
  class BlockingWorkspaceManager < KernelHeadsSupport::StubWorkspaceManager
    attr_reader :allocation_count, :maximum_active

    def initialize
      super
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @held = true
      @allocation_count = 0
      @active = 0
      @maximum_active = 0
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

  def test_one_head_batch_reserves_both_workers_before_either_provision_finishes
    manager = BlockingWorkspaceManager.new
    async_engine = Meringue::Kernel::Engine.new(
      store: Meringue::State::Store.new(path: @state_path),
      harness_client: @harness_client,
      head_runner: @head_runner,
      workspace_manager: manager,
      cwd: @project_path,
      forge_client: KernelHeadsSupport::StubForgeClient.new,
      config_path: @config_path,
      async_worker_provisioning: true,
      worker_provisioning_concurrency: 2
    )
    project_id = add_project!(target_engine: async_engine)
    first_issue = apply_command(
      "CreateIssue", { "project_id" => project_id, "title" => "First task" }, target_engine: async_engine
    ).fetch("target_id")
    second_issue = apply_command(
      "CreateIssue", { "project_id" => project_id, "title" => "Second task" }, target_engine: async_engine
    ).fetch("target_id")
    head_id = spawn_head!("Start both tasks", target_engine: async_engine)

    result = apply_head_result(
      head_id,
      head_result(commands: [
        spawn_worker_command(issue_id: first_issue, prompt: "First."),
        spawn_worker_command(issue_id: second_issue, prompt: "Second.")
      ]),
      cleanup_head: false,
      target_engine: async_engine
    )

    assert_equal [["SpawnWorker", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(result)
    assert manager.wait_for_allocations(2), "both journaled reservations should provision concurrently"
    assert_equal 2, manager.maximum_active
    journal = find_agent_record(head_id, current_state: async_engine.list_all).dig("harness_metadata", "head_result_command_journal")
    assert_equal %w[accepted accepted], journal.map { |entry| entry.fetch("status") }
    assert_equal 2, async_engine.list_all.fetch("agents").count { |agent| agent.fetch("type") == "worker" }

    manager.release
    assert async_engine.wait_for_worker_provisioning(timeout: 5)
    assert_equal 2, async_engine.list_all.fetch("agents").count { |agent| agent.fetch("status") == "working" }
  ensure
    manager&.release
    async_engine&.wait_for_worker_provisioning(timeout: 5)
  end
end
