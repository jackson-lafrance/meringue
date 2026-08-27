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

  # A submission that raises on the way to the kernel used to stay pending forever: the
  # composer had already been cleared, so it was replayed on every start, failed the same way,
  # and was never shown to anyone.
  def test_a_submission_that_raises_leaves_the_queue_and_still_reaches_the_caller
    engine = RaisingEngine.new(@store)
    prompt_loop = Meringue::Heads::PromptLoop.new(engine: engine)
    submission = prompt_loop.enqueue_submission("break this")

    assert_raises(RuntimeError) { prompt_loop.deliver_submission(submission) }

    assert_empty prompt_loop.submission_queue.pending, "the poison submission must not be replayed"
    assert_empty Meringue::Heads::PromptLoop.new(engine: RaisingEngine.new(@store)).submission_queue.pending
  end

  # An unbalanced quote used to raise `NameError: uninitialized constant Shellwords::ParseError`
  # out of the parser, which is exactly how a poison submission was produced in practice.
  def test_an_unbalanced_quote_is_delivered_as_a_usage_message_and_drains_the_queue
    engine = RecordingEngine.new(@store)
    prompt_loop = Meringue::Heads::PromptLoop.new(engine: engine)

    result = prompt_loop.call(%(/answer Q1 "unterminated))

    assert_equal "InvalidSlashCommand", engine.applied.first.fetch("type")
    assert_equal "slash_command_applied", result.fetch("event")
    assert_empty prompt_loop.submission_queue.pending
  end

  # Recovered submissions have no composer waiting on them, so an exception there has no caller
  # to report it and Ruby's default report_on_exception would print a backtrace onto the
  # rendered dashboard.
  def test_a_failing_recovered_submission_is_reported_as_an_event_rather_than_on_stderr
    Meringue::Input::DurableSubmissionQueue.new(state_path: @store.path).enqueue(text: "break this")
    events = []

    prompt_loop = Meringue::Heads::PromptLoop.new(engine: RaisingEngine.new(@store))
    prompt_loop.recover_pending_submissions { |event| events << event }.each(&:join)

    failure = events.find { |event| event.fetch("event") == "submission_recovery_failed" }
    refute_nil failure
    assert_equal "break this", failure.fetch("text")
    assert_equal "RuntimeError", failure.dig("error", "class")
    assert_empty prompt_loop.submission_queue.pending
  end

  class RaisingEngine
    attr_reader :store

    def initialize(store)
      @store = store
    end

    def apply(_command)
      raise "kernel exploded"
    end
  end

  class RecordingEngine
    attr_reader :store, :applied

    def initialize(store)
      @store = store
      @applied = []
    end

    def apply(command)
      @applied << command
      {
        "status" => "rejected",
        "command_type" => command.fetch("type"),
        "target_id" => nil,
        "message" => "nope",
        "result" => nil,
        "log_entry_ids" => []
      }
    end
  end
end
