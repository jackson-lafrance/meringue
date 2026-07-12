# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

require_relative "../lib/meringue"

class ConcurrentHeadsTest < Minitest::Test
  class BlockingRunner < Meringue::Heads::Runner
    attr_reader :max_active

    def initialize(expected_active_count:)
      @expected_active_count = expected_active_count
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @started_count = 0
      @active_count = 0
      @max_active = 0
      @released = false
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      enter_head
      wait_until_released
      issue_id = snapshot.fetch("issues").first.fetch("id")

      {
        "title" => "Head for #{user_message}",
        "summary" => "Spawn a worker for #{user_message}.",
        "commands" => [
          {
            "type" => "SpawnWorker",
            "payload" => {
              "issue_id" => issue_id,
              "title" => "Worker for #{user_message}",
              "prompt" => "Handle #{user_message}"
            }
          }
        ],
        "questions" => []
      }
    ensure
      leave_head
    end

    def wait_until_all_started(timeout: 2)
      deadline = Time.now + timeout
      @mutex.synchronize do
        until @started_count >= @expected_active_count
          remaining = deadline - Time.now
          raise "Timed out waiting for heads to start" if remaining <= 0

          @condition.wait(@mutex, remaining)
        end
      end
    end

    def release
      @mutex.synchronize do
        @released = true
        @condition.broadcast
      end
    end

    private

    def enter_head
      @mutex.synchronize do
        @started_count += 1
        @active_count += 1
        @max_active = [@max_active, @active_count].max
        @condition.broadcast
      end
    end

    def wait_until_released
      @mutex.synchronize do
        @condition.wait(@mutex) until @released
      end
    end

    def leave_head
      @mutex.synchronize do
        @active_count -= 1
        @condition.broadcast
      end
    end
  end

  class FirstImmediateSecondBlockingRunner < Meringue::Heads::Runner
    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @second_started = false
      @released = false
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      if user_message.to_s.include?("second")
        @mutex.synchronize do
          @second_started = true
          @condition.broadcast
          @condition.wait(@mutex) until @released
        end
      end

      issue_id = snapshot.fetch("issues").first.fetch("id")
      {
        "title" => "Head for #{user_message}",
        "summary" => "Spawn a worker for #{user_message}.",
        "commands" => [
          {
            "type" => "SpawnWorker",
            "payload" => {
              "issue_id" => issue_id,
              "title" => "Worker for #{user_message}",
              "prompt" => "Handle #{user_message}"
            }
          }
        ],
        "questions" => []
      }
    end

    def wait_until_second_started(timeout: 2)
      deadline = Time.now + timeout
      @mutex.synchronize do
        until @second_started
          remaining = deadline - Time.now
          raise "Timed out waiting for second head to start" if remaining <= 0

          @condition.wait(@mutex, remaining)
        end
      end
    end

    def release_second
      @mutex.synchronize do
        @released = true
        @condition.broadcast
      end
    end
  end

  class BlockingWorkerHarness < Meringue::Harness::FakeClient
    def initialize
      super
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @worker_spawn_started = false
      @released = false
    end

    def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
      if kind == "worker"
        @mutex.synchronize do
          @worker_spawn_started = true
          @condition.broadcast
          @condition.wait(@mutex) until @released
        end
      end

      super
    end

    def wait_until_worker_spawn_started(timeout: 2)
      deadline = Time.now + timeout
      @mutex.synchronize do
        until @worker_spawn_started
          remaining = deadline - Time.now
          raise "Timed out waiting for worker spawn to start" if remaining <= 0

          @condition.wait(@mutex, remaining)
        end
      end
    end

    def release_worker_spawns
      @mutex.synchronize do
        @released = true
        @condition.broadcast
      end
    end
  end

  def test_multiple_prompt_loop_heads_run_concurrently_and_spawn_workers
    Dir.mktmpdir("meringue-concurrent-heads-") do |root|
      store = Meringue::State::Store.new(path: File.join(root, "state.json"))
      runner = BlockingRunner.new(expected_active_count: 2)
      engine = Meringue::Kernel::Engine.new(
        store: store,
        harness_client: Meringue::Harness::FakeClient.new,
        head_runner: runner,
        cwd: root
      )
      engine.apply("type" => "AddProject", "payload" => { "path" => root, "name" => "tmp" })
      issue_result = engine.apply(
        "type" => "CreateIssue",
        "payload" => { "project_id" => "P1", "title" => "Shared issue", "description" => "Existing work" }
      )
      assert_equal "accepted", issue_result.fetch("status")

      prompt_loop = Meringue::Heads::PromptLoop.new(engine: engine, wait_for_workers: false)
      threads = ["first prompt", "second prompt"].map do |prompt|
        Thread.new { prompt_loop.handle_prompt(prompt) }
      end

      runner.wait_until_all_started
      working_heads = store.load.fetch("agents").select { |agent| agent.fetch("type") == "head" && agent.fetch("status") == "working" }
      assert_equal 2, working_heads.length
      assert_equal 2, runner.max_active

      runner.release
      results = threads.map(&:value)

      assert results.all? { |result| result.fetch("spawn_head_result").fetch("status") == "accepted" }
      assert results.all? { |result| result.fetch("apply_head_result").fetch("status") == "accepted" }

      state = store.load
      completed_heads = state.fetch("agents").select { |agent| agent.fetch("type") == "head" && agent.fetch("status") == "completed" }
      workers = state.fetch("agents").select { |agent| agent.fetch("type") == "worker" }
      assert_equal 2, completed_heads.length
      assert_equal %w[P1-I1-W1 P1-I1-W2], workers.map { |worker| worker.fetch("id") }.sort
    end
  end

  def test_new_head_can_start_while_previous_head_is_spawning_worker
    Dir.mktmpdir("meringue-concurrent-heads-worker-spawn-") do |root|
      store = Meringue::State::Store.new(path: File.join(root, "state.json"))
      runner = FirstImmediateSecondBlockingRunner.new
      harness = BlockingWorkerHarness.new
      engine = Meringue::Kernel::Engine.new(
        store: store,
        harness_client: harness,
        head_runner: runner,
        cwd: root
      )
      engine.apply("type" => "AddProject", "payload" => { "path" => root, "name" => "tmp" })
      engine.apply(
        "type" => "CreateIssue",
        "payload" => { "project_id" => "P1", "title" => "Shared issue", "description" => "Existing work" }
      )

      prompt_loop = Meringue::Heads::PromptLoop.new(engine: engine, wait_for_workers: false)
      first_thread = Thread.new { prompt_loop.handle_prompt("first prompt") }
      harness.wait_until_worker_spawn_started

      second_thread = Thread.new { prompt_loop.handle_prompt("second prompt") }
      runner.wait_until_second_started

      working_heads = store.load.fetch("agents").select { |agent| agent.fetch("type") == "head" && agent.fetch("status") == "working" }
      assert_equal ["H2"], working_heads.map { |head| head.fetch("id") }

      runner.release_second
      harness.release_worker_spawns
      first_result = first_thread.value
      second_result = second_thread.value

      assert_equal "accepted", first_result.fetch("apply_head_result").fetch("status")
      assert_equal "accepted", second_result.fetch("apply_head_result").fetch("status")
      workers = store.load.fetch("agents").select { |agent| agent.fetch("type") == "worker" }
      assert_equal %w[P1-I1-W1 P1-I1-W2], workers.map { |worker| worker.fetch("id") }.sort
    end
  end
end
