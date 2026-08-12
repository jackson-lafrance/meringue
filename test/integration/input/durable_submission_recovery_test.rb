# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class InputDurableSubmissionRecoveryTest < Minitest::Test
  class BlockingEngine
    attr_reader :store, :entered, :release, :applied

    def initialize(store)
      @store = store
      @entered = Queue.new
      @release = Queue.new
      @applied = []
    end

    def apply(command)
      @applied << command
      entered << command
      release.pop
      {
        "status" => "accepted",
        "command_type" => command.fetch("type"),
        "target_id" => "H1",
        "result" => nil,
        "log_entry_ids" => []
      }
    end
  end

  def setup
    @tmp = Dir.mktmpdir("meringue-durable-input")
    @store = Meringue::State::Store.new(path: File.join(@tmp, "state.json"))
    @store.save(Meringue::State::Models.empty_state)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def test_submission_survives_process_loss_while_an_earlier_prune_is_slow
    engine = BlockingEngine.new(@store)
    first_loop = Meringue::Heads::PromptLoop.new(engine: engine)
    prune = first_loop.enqueue_submission("/prune")
    prune_thread = Thread.new { first_loop.deliver_submission(prune) }
    assert_equal "Prune", engine.entered.pop.fetch("type")

    message = first_loop.enqueue_submission("route this after prune")
    assert_equal [prune.fetch("id"), message.fetch("id")], first_loop.submission_queue.pending.map { |entry| entry.fetch("id") }

    # Simulate the supervising process disappearing: in-memory delivery threads are gone, but a
    # fresh loop over the same state path can recover both fsynced submissions. Complete prune as
    # if its old process died after applying it; recovery must still route the later message.
    first_loop.submission_queue.complete(prune.fetch("id"))
    recovered_engine = BlockingEngine.new(@store)
    recovered_loop = Meringue::Heads::PromptLoop.new(engine: recovered_engine)
    recovery_threads = recovered_loop.recover_pending_submissions
    recovered = recovered_engine.entered.pop

    assert_equal "SpawnHead", recovered.fetch("type")
    assert_equal "route this after prune", recovered.dig("payload", "user_message")
    assert_nil recovered.fetch("command_id")
    assert_equal message.fetch("id"), recovered.dig("payload", "_input_submission_id")
    recovered_engine.release << true
    recovery_threads.each(&:join)
    assert_empty recovered_loop.submission_queue.pending
  ensure
    engine&.release&.push(true) if prune_thread&.alive?
    prune_thread&.join(1)
    prune_thread&.kill if prune_thread&.alive?
  end

  def test_kernel_deduplicates_replayed_natural_language_submission
    engine = Meringue::Kernel::Engine.new(
      store: @store,
      harness_client: Meringue::Harness::FakeClient.new,
      head_runner: Meringue::Heads::FakeRunner.new,
      workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(@tmp, "workspaces")),
      cwd: @tmp,
      config_path: File.join(@tmp, "config.toml")
    )
    command = {
      "command_id" => "input-stable-C1",
      "type" => "SpawnHead",
      "payload" => { "user_message" => "route once", "_input_submission_id" => "input-stable" }
    }

    first = engine.apply(command)
    second = engine.apply(command)
    heads = @store.load.fetch("agents").select { |agent| agent.fetch("type") == "head" }

    assert_equal "accepted", first.fetch("status")
    assert_equal "accepted", second.fetch("status")
    assert_equal first.fetch("target_id"), second.fetch("target_id")
    assert_equal 1, heads.length
    assert_equal "input-stable", heads.first.dig("harness_metadata", "head_request", "input_submission_id")
  end

  def test_recovery_replays_a_submission_only_once_after_completion
    queue = Meringue::Input::DurableSubmissionQueue.new(state_path: @store.path)
    submission = queue.enqueue(text: "one message")
    queue.complete(submission.fetch("id"))

    assert_empty Meringue::Input::DurableSubmissionQueue.new(state_path: @store.path).pending
  end
end
