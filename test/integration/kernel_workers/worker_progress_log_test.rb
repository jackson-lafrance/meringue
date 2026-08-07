# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Mid-work worker progress in the main Meringue log.
#
# A worker used to say nothing between "Spawned worker ..." and its final report, so a healthy
# 40-minute session looked identical to a hung one. These tests pin what now reaches the log, and
# just as importantly what does not: the log window is bounded (500 entries), so the volume
# controls are the feature, not a detail.
class KernelWorkersProgressLogTest < Minitest::Test
  include KernelWorkersSupport

  # A harness that streams events but predates the progress contract entirely.
  class ProgressUnawareClient < KernelWorkersSupport::RecordingHarnessClient
    undef_method :session_progress
  end

  # A harness whose progress extraction blows up. Reconciliation must survive it.
  class ExplodingProgressClient < KernelWorkersSupport::RecordingHarnessClient
    def session_progress(_events)
      raise IOError, "progress transport is gone"
    end
  end

  def test_a_working_worker_reports_its_authored_text_in_the_main_log
    client = streaming_client
    client.events = [assistant_message("Rebasing onto origin/main before I touch the reconcile path.")]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    entry = only_progress_log(engine, worker_id)
    assert_equal "Rebasing onto origin/main before I touch the reconcile path.", entry.fetch("message")
    assert_equal "worker", entry.fetch("source_type")
    assert_equal worker_id, entry.fetch("source_id")
    assert_equal "info", entry.fetch("level")
    assert_equal "assistant_text", entry.fetch("details").fetch("progress_kind")
    assert_equal context.fetch("issue_id"), entry.fetch("details").fetch("issue_id")
    assert_equal context.fetch("project_id"), entry.fetch("details").fetch("project_id")

    progress = agent(engine, worker_id).fetch("harness_metadata").fetch("progress")
    assert_equal 1, progress.fetch("logged_count")
    refute_nil progress.fetch("observed_at")
  end

  def test_progress_is_rate_limited_per_worker_but_still_tracked_on_the_record
    client = streaming_client
    client.events = [assistant_message("First decision.")]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    apply!(engine, "ReconcileSessions", {})

    client.events = [assistant_message("Second decision, moments later.")]
    3.times { apply!(engine, "ReconcileSessions", {}) }

    assert_equal ["First decision."], progress_messages(engine, worker_id)
    progress = agent(engine, worker_id).fetch("harness_metadata").fetch("progress")
    assert_equal "Second decision, moments later.", progress.fetch("text"),
                 "the newest observation must stay visible on the record even while the log line is throttled"
    assert_equal "First decision.", progress.fetch("logged_text")
    assert_equal 1, progress.fetch("logged_count")

    age_progress!(worker_id, seconds: Meringue::Kernel::Engine::WORKER_PROGRESS_LOG_INTERVAL_SECONDS + 1)
    apply!(engine, "ReconcileSessions", {})

    assert_equal ["First decision.", "Second decision, moments later."], progress_messages(engine, worker_id)
  end

  def test_repeating_the_same_text_never_spends_a_log_slot
    client = streaming_client
    client.events = [assistant_message("Still rebasing.")]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    apply!(engine, "ReconcileSessions", {})

    5.times do
      age_progress!(worker_id, seconds: Meringue::Kernel::Engine::WORKER_PROGRESS_LOG_INTERVAL_SECONDS * 10)
      apply!(engine, "ReconcileSessions", {})
    end

    assert_equal ["Still rebasing."], progress_messages(engine, worker_id)
  end

  def test_a_burst_of_authored_text_collapses_to_the_newest_line
    client = streaming_client
    client.events = [
      assistant_message("Read the reconcile path."),
      { "type" => "tool_execution_start", "toolName" => "bash", "args" => { "command" => "rake test" } },
      assistant_message("Now writing the failing test.")
    ]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    assert_equal ["Now writing the failing test."], progress_messages(engine, worker_id)
  end

  def test_a_long_message_is_truncated_to_a_headline
    long_text = "Investigating the reconcile tick. " * 40
    client = streaming_client
    client.events = [assistant_message(long_text)]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    message = progress_messages(engine, worker_id).fetch(0)
    assert_operator message.length, :<=, Meringue::Kernel::Engine::WORKER_PROGRESS_MESSAGE_MAX_CHARS
    assert_operator message.length, :>, Meringue::Kernel::Engine::WORKER_PROGRESS_MESSAGE_MAX_CHARS - 10
    assert message.end_with?("…"), "a truncated progress line should say so"
    assert message.start_with?("Investigating the reconcile tick.")
  end

  def test_tool_only_work_falls_back_to_a_quieter_still_working_line
    client = streaming_client
    client.events = [
      { "type" => "tool_execution_start", "toolName" => "read", "args" => { "path" => "lib/a.rb" } },
      { "type" => "tool_execution_start", "toolName" => "grep", "args" => { "pattern" => "reconcile" } },
      { "type" => "tool_execution_start", "toolName" => "read", "args" => { "path" => "lib/b.rb" } }
    ]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    apply!(engine, "ReconcileSessions", {})

    entry = only_progress_log(engine, worker_id)
    assert_equal "Still working: read, grep (3 tool calls).", entry.fetch("message")
    assert_equal "tool_activity", entry.fetch("details").fetch("progress_kind")
    assert_equal %w[read grep], entry.fetch("details").fetch("tool_names")
    assert_equal 3, entry.fetch("details").fetch("tool_call_count")

    # The text floor is not enough for a silent worker: tool activity waits far longer.
    client.events = [{ "type" => "tool_execution_start", "toolName" => "edit", "args" => { "path" => "lib/c.rb" } }]
    age_progress!(worker_id, seconds: Meringue::Kernel::Engine::WORKER_PROGRESS_LOG_INTERVAL_SECONDS + 1)
    apply!(engine, "ReconcileSessions", {})
    assert_equal 1, progress_messages(engine, worker_id).length

    age_progress!(worker_id, seconds: Meringue::Kernel::Engine::WORKER_PROGRESS_TOOL_INTERVAL_SECONDS + 1)
    apply!(engine, "ReconcileSessions", {})
    assert_equal(
      ["Still working: read, grep (3 tool calls).", "Still working: edit (1 tool call)."],
      progress_messages(engine, worker_id)
    )
  end

  def test_authored_text_always_wins_over_tool_activity
    client = streaming_client
    client.events = [
      { "type" => "tool_execution_start", "toolName" => "read", "args" => { "path" => "lib/a.rb" } },
      assistant_message("The bug is in the shared drain cursor."),
      { "type" => "tool_execution_start", "toolName" => "edit", "args" => { "path" => "lib/a.rb" } }
    ]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    assert_equal ["The bug is in the shared drain cursor."], progress_messages(engine, worker_id)
  end

  def test_a_harness_with_no_events_stays_silent
    client = streaming_client
    client.events = []
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    reconcile = apply!(engine, "ReconcileSessions", {})

    assert_equal 1, reconcile.fetch("result").fetch("checked_count")
    assert_empty progress_messages(engine, worker_id)
    assert_nil agent(engine, worker_id).fetch("harness_metadata").fetch("progress", nil)
  end

  def test_a_harness_without_the_progress_contract_stays_silent
    client = ProgressUnawareClient.new(provider: "pi", streaming: true)
    client.events = [assistant_message("This backend cannot report progress.")]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    reconcile = apply!(engine, "ReconcileSessions", {})

    assert_equal 1, reconcile.fetch("result").fetch("checked_count")
    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_empty progress_messages(engine, worker_id)
  end

  def test_progress_extraction_can_never_break_a_reconcile_pass
    client = ExplodingProgressClient.new(provider: "pi", streaming: true)
    client.events = [assistant_message("Never reaches the log.")]
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    reconcile = apply!(engine, "ReconcileSessions", {})

    assert_equal 1, reconcile.fetch("result").fetch("checked_count")
    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_empty progress_messages(engine, worker_id)
    assert_empty logs_matching(engine, /Skipped session reconciliation step/)
  end

  # Heads are short-lived routers that already log their own summary. Narrating their tool calls
  # would be pure noise, so progress is a worker-only concept.
  def test_heads_never_emit_progress_lines
    client = streaming_client
    client.events = [assistant_message("Head narration that must not reach the log.")]
    engine = build_engine(harness_client: client)
    seed_streaming_head!("H1")

    reconcile = apply!(engine, "ReconcileSessions", {})

    assert_equal 1, reconcile.fetch("result").fetch("checked_count"), "the head must actually be polled for this to prove anything"
    assert_equal ["working"], reconcile.fetch("result").fetch("poll_results").map { |poll| poll.fetch("state") }
    assert_empty progress_logs(engine, "H1")
    assert_nil agent(engine, "H1").fetch("harness_metadata").fetch("progress", nil)
  end

  def test_a_settled_session_reports_its_result_instead_of_progress
    client = KernelWorkersSupport::RecordingHarnessClient.new(provider: "pi", streaming: false)
    client.events = [assistant_message("Mid-work narration.")]
    client.last_assistant_text = "Opened the pull request."
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    apply!(engine, "ReconcileSessions", {})

    assert_equal "completed", agent(engine, worker_id).fetch("status")
    assert_empty progress_messages(engine, worker_id)
    assert_includes log_messages(engine), "Worker #{worker_id} completed."
  end

  private

  def streaming_client
    KernelWorkersSupport::RecordingHarnessClient.new(provider: "pi", streaming: true)
  end

  # Raw Pi RPC shape: `message_end` carries the complete assistant message, including its text
  # blocks, before the tool calls in that message execute.
  def assistant_message(text)
    {
      "type" => "message_end",
      "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => text }] }
    }
  end

  def progress_logs(engine, worker_id)
    state(engine).fetch("logs").select do |entry|
      entry.fetch("source_id", nil) == worker_id &&
        (entry.fetch("details", {}) || {}).fetch("kind", nil) == "worker_progress"
    end
  end

  def progress_messages(engine, worker_id)
    progress_logs(engine, worker_id).map { |entry| entry.fetch("message") }
  end

  def only_progress_log(engine, worker_id)
    entries = progress_logs(engine, worker_id)
    assert_equal 1, entries.length, "expected exactly one progress line, got #{entries.map { |entry| entry.fetch("message") }.inspect}"
    entries.first
  end

  # A head record the reconciler will poll: a live-looking session that has not applied a result
  # yet. Seeded directly because a FakeRunner head settles before reconciliation ever sees it.
  def seed_streaming_head!(head_id)
    now = Time.now.utc.iso8601
    patch_state! do |state|
      state.fetch("agents") << {
        "id" => head_id,
        "type" => "head",
        "status" => "working",
        "harness" => "pi",
        "pid" => 41_234,
        "harness_session_id" => "fake-head-session-1",
        "harness_session_file" => nil,
        "harness_metadata" => { "cwd" => tmpdir, "kind" => "head", "is_streaming" => true },
        "created_at" => now,
        "updated_at" => now
      }
      state.fetch("counters")["heads"] = 1
    end
  end

  # Moves the recorded throttle marker into the past instead of stubbing the clock, so the test
  # stays hermetic and exercises the same durable marker a restart would read.
  def age_progress!(worker_id, seconds:)
    patch_agent!(worker_id) do |record|
      progress = record.fetch("harness_metadata").fetch("progress")
      progress["logged_at"] = (Time.iso8601(progress.fetch("logged_at")) - seconds).iso8601
    end
  end
end
