# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# How long a working agent has gone without producing anything.
#
# `status == "working"` said the same thing two seconds into a turn and forty minutes into
# silence. These tests pin the activity clock that separates them, and the rule that makes it
# trustworthy: only observed activity advances it, and Meringue's own bookkeeping writes - the
# quiet warning very much included - never do.
class KernelWorkersQuietWorkerTest < Minitest::Test
  include KernelWorkersSupport

  THRESHOLD = Meringue::Kernel::Engine::WORKER_QUIET_WARNING_SECONDS

  def test_a_spawned_worker_starts_with_its_activity_clock_running
    engine = build_engine(harness_client: streaming_client)
    worker_id = spawn_worker(engine, project_with_issue(engine).fetch("issue_id")).fetch("target_id")

    recorded = last_activity_at(engine, worker_id)

    refute_nil recorded, "a worker that has just started is not quiet since the epoch"
    assert_in_delta Time.now, Time.iso8601(recorded), 60
    assert_empty quiet_logs(engine)
  end

  def test_a_worker_quiet_past_the_threshold_is_reported_once
    engine, worker_id = quiet_worker(seconds: THRESHOLD + 60)

    results = apply!(engine, "ReconcileSessions", {}).dig("result", "quiet_worker_results")

    assert_equal [worker_id], results.map { |result| result.fetch("agent_id") }
    entry = only_quiet_log(engine, worker_id)
    assert_equal "warning", entry.fetch("level")
    assert_equal "worker", entry.fetch("source_type")
    assert_includes entry.fetch("message"), worker_id
    assert_includes entry.fetch("message"), "16 minutes"
    assert_includes entry.fetch("message"), "may still be working"
    assert_equal "worker_quiet", entry.dig("details", "kind")
    assert_operator entry.dig("details", "quiet_seconds"), :>=, THRESHOLD
  end

  # The warning writes to the worker record. If that write reset the clock the row would flip
  # straight back to "not quiet", and if it did not suppress itself the log would fill up.
  def test_the_warning_neither_repeats_nor_resets_the_clock_it_measured
    engine, worker_id = quiet_worker(seconds: THRESHOLD + 60)
    apply!(engine, "ReconcileSessions", {})
    recorded = last_activity_at(engine, worker_id)

    3.times { apply!(engine, "ReconcileSessions", {}) }

    assert_equal 1, quiet_logs(engine).length
    assert_equal recorded, last_activity_at(engine, worker_id), "the quiet warning must not move the activity clock"
  end

  def test_output_clears_the_warning_so_the_next_quiet_stretch_is_reported_again
    client = streaming_client
    engine, worker_id = quiet_worker(seconds: THRESHOLD + 60, client: client)
    apply!(engine, "ReconcileSessions", {})
    assert_equal 1, quiet_logs(engine).length

    client.events = [assistant_message("Back with a plan.")]
    apply!(engine, "ReconcileSessions", {})

    refute quiet_warning_marked?(engine, worker_id), "observed output ends the quiet stretch"
    client.events = []
    age_activity!(worker_id, seconds: THRESHOLD + 60)
    apply!(engine, "ReconcileSessions", {})

    assert_equal 2, quiet_logs(engine).length, "a second quiet stretch is its own event"
  end

  def test_prompting_a_quiet_worker_restarts_its_clock
    engine, worker_id = quiet_worker(seconds: THRESHOLD + 60)
    apply!(engine, "ReconcileSessions", {})
    assert quiet_warning_marked?(engine, worker_id)

    apply!(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Where are you?" })

    refute quiet_warning_marked?(engine, worker_id)
    assert_in_delta Time.now, Time.iso8601(last_activity_at(engine, worker_id)), 60
  end

  def test_a_settled_worker_is_never_called_quiet
    engine, worker_id = quiet_worker(seconds: THRESHOLD * 4)
    patch_agent!(worker_id) { |record| record["status"] = "completed" }

    apply!(engine, "ReconcileSessions", {})

    assert_empty quiet_logs(engine), "a worker that finished is silent on purpose"
  end

  def test_a_worker_still_waiting_on_its_worktree_is_never_called_quiet
    engine, worker_id = quiet_worker(seconds: THRESHOLD * 4)
    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata")["provisioning_state"] = "allocating_workspace"
    end

    apply!(engine, "ReconcileSessions", {})

    assert_empty quiet_logs(engine), "a worker without a session yet has nothing to be quiet in"
  end

  def test_zero_turns_the_signal_off_entirely
    File.write(tmp_path("config.toml"), "[agent]\nquiet_worker_warning_seconds = 0\n")
    engine, _worker_id = quiet_worker(seconds: THRESHOLD * 4)

    apply!(engine, "ReconcileSessions", {})

    assert_empty quiet_logs(engine)
    assert_equal 0, state.dig("metadata", "quiet_worker_warning_seconds")
  end

  def test_a_configured_threshold_is_honoured_and_published_for_the_dashboard
    File.write(tmp_path("config.toml"), "[agent]\nquiet_worker_warning_seconds = 60\n")
    engine, worker_id = quiet_worker(seconds: 120)

    apply!(engine, "ReconcileSessions", {})

    assert_equal 60, state.dig("metadata", "quiet_worker_warning_seconds")
    assert_equal 1, quiet_logs(engine).length
    assert_includes only_quiet_log(engine, worker_id).fetch("message"), "2 minutes"
  end

  # A harness heartbeat is evidence of activity, but only a *newer* one. A provider replaying a
  # stale timestamp must not make a quiet worker look busy.
  def test_the_activity_clock_only_moves_forward
    engine, worker_id = quiet_worker(seconds: THRESHOLD + 60)
    recorded = last_activity_at(engine, worker_id)
    patch_agent!(worker_id) do |record|
      record.fetch("harness_metadata")["last_event_at"] = (Time.now.utc - (THRESHOLD * 4)).iso8601
    end

    apply!(engine, "ReconcileSessions", {})

    assert_equal recorded, last_activity_at(engine, worker_id)
  end

  # A worker adopted from a state file - written before this existed, or left behind by a
  # previous run - has its clock started at the pass that first observes it, not at whatever its
  # record last said. Meringue can honestly report silence it watched; it cannot report silence
  # from the days it was not running, and seeding from the stale record would light up every
  # `working` row of a reloaded state file at once.
  def test_a_worker_with_no_clock_starts_one_now_rather_than_being_called_quiet_on_sight
    engine, worker_id = quiet_worker(seconds: THRESHOLD * 4)
    patch_agent!(worker_id) { |record| record.fetch("harness_metadata").delete("last_activity_at") }

    apply!(engine, "ReconcileSessions", {})

    assert_empty quiet_logs(engine), "Meringue was not watching for that silence"
    assert_in_delta Time.now, Time.iso8601(last_activity_at(engine, worker_id)), 60

    age_activity!(worker_id, seconds: THRESHOLD + 60)
    apply!(engine, "ReconcileSessions", {})

    assert_equal 1, quiet_logs(engine).length, "silence it did watch is reported normally"
  end

  private

  def quiet_worker(seconds:, client: streaming_client)
    engine = build_engine(harness_client: client)
    worker_id = spawn_worker(engine, project_with_issue(engine).fetch("issue_id")).fetch("target_id")
    age_activity!(worker_id, seconds: seconds)
    [engine, worker_id]
  end

  # Ages every clock a quiet calculation can read, so the fixture does not silently depend on
  # which one the implementation happens to prefer.
  def age_activity!(worker_id, seconds:)
    patch_agent!(worker_id) do |record|
      metadata = record.fetch("harness_metadata")
      moved = (Time.now.utc - seconds).iso8601
      metadata["last_activity_at"] = moved
      record["updated_at"] = moved
      record["created_at"] = moved
    end
  end

  def last_activity_at(engine, worker_id)
    agent(engine, worker_id).fetch("harness_metadata").fetch("last_activity_at", nil)
  end

  def quiet_warning_marked?(engine, worker_id)
    !agent(engine, worker_id).fetch("harness_metadata").fetch("quiet_warning_at", nil).nil?
  end

  def quiet_logs(engine = nil)
    state(engine).fetch("logs").select { |entry| (entry.fetch("details", {}) || {}).fetch("kind", nil) == "worker_quiet" }
  end

  def only_quiet_log(engine, worker_id)
    entries = quiet_logs(engine).select { |entry| entry.fetch("source_id", nil) == worker_id }
    assert_equal 1, entries.length, "expected exactly one quiet line, got #{entries.map { |entry| entry.fetch("message") }.inspect}"
    entries.first
  end

  def streaming_client
    KernelWorkersSupport::RecordingHarnessClient.new(provider: "pi", streaming: true)
  end

  def assistant_message(text)
    {
      "type" => "message_end",
      "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => text }] }
    }
  end
end
