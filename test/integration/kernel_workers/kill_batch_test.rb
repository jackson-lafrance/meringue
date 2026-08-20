# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Regression coverage for the /kill batch slowdown: rapid kills must not serialize on the
# state lock while waiting for harness process termination. The harness `kill_session` call
# (a synchronous `process.terminate` that can block for seconds) runs outside the state lock,
# so N kills fired in quick succession overlap instead of queueing for N x (process exit).
class KernelWorkersKillBatchTest < Minitest::Test
  include KernelWorkersSupport

  # A harness client whose kill_session blocks for a fixed window, simulating a slow
  # process exit. Recording is mutex-guarded because kills run concurrently.
  class SlowKillHarnessClient < RecordingHarnessClient
    SLEEP_SECONDS = 1.0

    def initialize(**options)
      super
      @kill_mutex = Mutex.new
      @kill_session_ids = []
      @kill_call_count = 0
    end

    def kill_session(session_ref)
      sleep SLEEP_SECONDS
      @kill_mutex.synchronize do
        @kill_call_count += 1
        @kill_session_ids << session_ref.fetch("session_id", nil)
      end
      super
    end

    def kill_call_count
      @kill_mutex.synchronize { @kill_call_count }
    end

    def kill_session_ids
      @kill_mutex.synchronize { @kill_session_ids.dup }
    end
  end

  def test_rapid_kills_do_not_serialize_on_the_state_lock
    harness_client = SlowKillHarnessClient.new
    engine = build_engine(harness_client: harness_client)
    context = project_with_issue(engine)
    worker_ids = 5.times.map do |index|
      spawn_worker(engine, context.fetch("issue_id"), prompt: "Do task #{index}.").fetch("target_id")
    end
    session_ids = worker_ids.map { |id| agent(engine, id).fetch("harness_session_id") }

    started_at = monotonic_time
    threads = worker_ids.map do |worker_id|
      Thread.new { apply!(engine, "Kill", { "target_id" => worker_id }) }
    end
    results = threads.map(&:value)
    elapsed = monotonic_time - started_at

    # Five kills whose kill_session each blocks ~1s must finish in roughly one window, not five.
    # A generous upper bound keeps the test stable on slow CI without hiding the regression:
    # the old in-lock path would take ~5s here.
    assert_equal 5, results.length
    results.each { |result| assert_equal "accepted", result.fetch("status") }
    assert elapsed < (SlowKillHarnessClient::SLEEP_SECONDS * 3),
           "expected batched kills to overlap (elapsed #{elapsed.round(2)}s), not serialize"

    # Exactly-once session stop: each killed worker's session is stopped once, no more.
    assert_equal 5, harness_client.kill_call_count
    assert_equal session_ids.sort, harness_client.kill_session_ids.sort

    # Every killed worker is gone from active state and each session stop is recorded once.
    worker_ids.each { |id| assert_nil agent(engine, id), "killed worker #{id} must leave active state" }
  end

  def test_reconciler_can_acquire_the_state_lock_during_a_kill_storm
    harness_client = SlowKillHarnessClient.new
    engine = build_engine(harness_client: harness_client)
    context = project_with_issue(engine)
    worker_ids = 3.times.map do |index|
      spawn_worker(engine, context.fetch("issue_id"), prompt: "Do task #{index}.").fetch("target_id")
    end

    kill_threads = worker_ids.map do |worker_id|
      Thread.new { apply!(engine, "Kill", { "target_id" => worker_id }) }
    end

    # While kills are in their out-of-lock termination window, a reconcile tick (which needs
    # the state lock) must complete promptly rather than queueing behind the whole storm.
    reconcile_started_at = monotonic_time
    reconcile_result = engine.apply("type" => "ReconcileSessions", "payload" => {})
    reconcile_elapsed = monotonic_time - reconcile_started_at

    assert_equal "accepted", reconcile_result.fetch("status")
    assert reconcile_elapsed < (SlowKillHarnessClient::SLEEP_SECONDS * 2),
           "expected reconcile to acquire the lock mid-storm (elapsed #{reconcile_elapsed.round(2)}s)"

    kill_threads.map(&:value)
    worker_ids.each { |id| assert_nil agent(engine, id) }
    assert_equal 3, harness_client.kill_call_count
  end

  # Process.monotonic_time is not available on all Rubies; fall back to Time.
  def monotonic_time
    if defined?(Process) && Process.respond_to?(:clock_gettime) &&
       Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    else
      Time.now.to_f
    end
  end
end
