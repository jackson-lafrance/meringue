# frozen_string_literal: true

require "test_helper"
require "support/state_support"

# Persisted log retention (docs/log-retention.md): append-only inside the retained
# window, oldest-first eviction at the documented limit, monotonic log identifiers
# across eviction, independence from record pruning, and no streamed-token noise.
#
# This file also carries the correctness assertions that used to live in
# scripts/benchmark_log_retention.rb, with bounded workloads and generous limits.
class StateLogRetentionTest < Minitest::Test
  include StateSupport

  LIMIT = Meringue::State::Models::LOG_RETENTION_LIMIT

  def test_retention_limit_matches_the_documented_window
    assert_equal 500, LIMIT
    assert_includes File.read(File.join(REPO_ROOT, "docs", "log-retention.md")), "500 newest durable log entries"
  end

  def test_logs_below_the_limit_are_appended_without_eviction
    state = { "logs" => build_logs(1..LIMIT) }

    refute Models.retain_recent_logs!(state), "no eviction is needed at exactly the limit"
    Models.ensure_state_shape!(state)

    assert_equal LIMIT, state.fetch("logs").length
    assert_equal "L1", state.fetch("logs").first.fetch("id")
    assert_equal "L#{LIMIT}", state.fetch("logs").last.fetch("id")
    assert_equal LIMIT, state.dig("counters", "logs")
  end

  # Ported from scripts/benchmark_log_retention.rb#verify_boundary!.
  def test_one_entry_over_the_limit_evicts_only_the_oldest_entry
    timestamp = "2026-07-27T00:00:00Z"
    state = { "logs" => build_logs(1..(LIMIT + 1), timestamp: timestamp) }

    Models.ensure_state_shape!(state, now: timestamp)

    assert_equal LIMIT, state.fetch("logs").length, "boundary count must be capped"
    assert_equal "L2", state.fetch("logs").first.fetch("id"), "the oldest log is removed first"
    assert_equal "L#{LIMIT + 1}", state.fetch("logs").last.fetch("id"), "the newest log is retained"
    assert_equal LIMIT + 1, state.dig("counters", "logs"),
                 "a missing counter still preserves the high-water mark"
  end

  def test_eviction_keeps_the_window_chronological_and_oldest_first
    state = { "logs" => build_logs(1..(LIMIT + 37)) }

    Models.ensure_state_shape!(state)

    numbers = log_numbers(state)
    assert_equal LIMIT, numbers.length
    assert_equal numbers.sort, numbers, "retained logs stay in append order"
    assert_equal 38, numbers.first
    assert_equal LIMIT + 37, numbers.last
    timestamps = state.fetch("logs").map { |log| log.fetch("timestamp") }
    assert_equal timestamps.sort, timestamps, "retained logs stay chronological"
  end

  def test_retain_recent_logs_accepts_an_explicit_limit
    state = { "logs" => build_logs(1..10) }

    assert Models.retain_recent_logs!(state, limit: 4)
    assert_equal %w[L7 L8 L9 L10], log_ids(state)
    refute Models.retain_recent_logs!(state, limit: 4), "a second pass has nothing to evict"
  end

  # Ported from scripts/benchmark_log_retention.rb: legacy load, bounded save, reload.
  def test_legacy_unbounded_state_is_bounded_on_load_and_persisted_smaller
    log_count = 1_200
    with_store do |store, path|
      legacy = legacy_log_state(log_count, timestamp: "2026-07-27T00:00:00Z")
      write_state_file(path, legacy)
      legacy_bytes = File.size(path)

      retained = store.load

      assert_equal LIMIT, retained.fetch("logs").length, "legacy load must cap logs"
      assert_equal "L#{log_count - LIMIT + 1}", retained.fetch("logs").first.fetch("id")
      assert_equal "L#{log_count}", retained.fetch("logs").last.fetch("id")
      assert_equal log_count, retained.dig("counters", "logs"), "legacy load must not lower the log counter"
      assert_equal log_count, read_state_file(path).fetch("logs").length, "load alone does not rewrite the file"

      store.save(retained, preserve_log_buffer: false)
      assert_operator File.size(path), :<, legacy_bytes, "the bounded save must be smaller"
      assert_equal LIMIT, read_state_file(path).fetch("logs").length
      assert_equal LIMIT, store.load.fetch("logs").length
      assert_equal log_count, store.load.dig("counters", "logs")
    end
  end

  def test_compact_bang_persists_the_bound_immediately_and_is_idempotent
    with_store do |store, path|
      write_state_file(path, legacy_log_state(LIMIT + 100))

      assert store.compact!, "the first compaction bounds the legacy window"
      on_disk = read_state_file(path)
      assert_equal LIMIT, on_disk.fetch("logs").length
      assert_equal "L101", on_disk.fetch("logs").first.fetch("id")
      assert_equal LIMIT + 100, on_disk.dig("counters", "logs")

      refute store.compact!, "an already bounded state needs no further compaction"
      assert_equal on_disk, read_state_file(path)
    end
  end

  # Ported from scripts/benchmark_log_retention.rb: kernel appends stay monotonic after
  # the pruned window discarded older identifiers.
  def test_kernel_appends_stay_monotonic_after_eviction
    log_count = 800
    with_store do |store, path, dir|
      write_state_file(path, legacy_log_state(log_count))
      store.save(store.load, preserve_log_buffer: false)
      engine = build_engine(store: store, dir: dir)

      result = engine.apply(
        "type" => "AddProject",
        "command_id" => "retention-test",
        "payload" => { "path" => dir, "name" => "Retention" }
      )
      assert_equal "accepted", result.fetch("status"), result.inspect

      reloaded = store.load
      assert_equal LIMIT, reloaded.fetch("logs").length, "an append must not exceed the cap"
      assert_equal "L#{log_count + 1}", reloaded.fetch("logs").last.fetch("id"), "an append must not reuse a pruned ID"
      assert_equal log_count + 1, reloaded.dig("counters", "logs"), "the counter stays monotonic across reloads"
      assert_equal ["L#{log_count + 1}"], result.fetch("log_entry_ids")
    end
  end

  def test_repeated_kernel_appends_never_reuse_an_identifier
    with_store do |store, path, dir|
      write_state_file(path, legacy_log_state(LIMIT))
      engine = build_engine(store: store, dir: dir)

      12.times do |index|
        project_path = File.join(dir, "project-#{index}")
        FileUtils.mkdir_p(project_path)
        result = engine.apply(
          "type" => "AddProject",
          "command_id" => "append-#{index}",
          "payload" => { "path" => project_path, "name" => "Project #{index}" }
        )
        assert_equal "accepted", result.fetch("status"), result.inspect
      end

      state = store.load
      numbers = log_numbers(state)
      assert_equal LIMIT, numbers.length
      assert_equal numbers.uniq, numbers, "log identifiers must be unique"
      assert_equal numbers.sort, numbers
      assert_equal LIMIT + 12, numbers.last
      assert_equal LIMIT + 12, state.dig("counters", "logs")
      state.fetch("logs").each do |log|
        assert_includes Models::LOG_LEVELS, log.fetch("level")
        assert_includes Models::LOG_SOURCE_TYPES, log.fetch("source_type")
        assert iso8601?(log.fetch("timestamp"))
      end
    end
  end

  def test_retention_is_independent_from_issue_and_project_pruning
    with_store do |store, path, dir|
      seed_worker_state(store, dir)
      engine = build_engine(store: store, dir: dir)

      completion = engine.mark_worker_completed(agent_id: "P1-I1-W1", last_assistant_text: "done")
      assert_equal "accepted", completion.fetch("status"), completion.inspect
      logs_before = log_ids(store.load)

      prune = engine.apply("type" => "Prune", "command_id" => "prune-1", "payload" => { "selector" => "resolved" })
      assert_equal "accepted", prune.fetch("status"), prune.inspect

      after = store.load
      assert_empty after.fetch("issues"), "the resolved issue is pruned"
      assert_empty after.fetch("agents"), "its worker is pruned"
      assert_empty after.fetch("projects"), "the now-empty project is pruned"

      assert_equal logs_before, log_ids(after).first(logs_before.length),
                   "pruning records must not evict or renumber existing logs"
      assert_operator after.fetch("logs").length, :>, logs_before.length, "pruning appends its own log"
      assert(after.fetch("logs").any? { |log| log.to_s.include?("P1-I1") },
             "logs may reference records that no longer exist")
    end
  end

  def test_streamed_harness_tokens_are_not_persisted_as_log_entries
    with_store do |store, path, dir|
      seed_worker_state(store, dir)
      engine = build_engine(store: store, dir: dir)

      streamed = [
        { "type" => "token", "data" => { "text" => "hel" } },
        { "type" => "text_delta", "data" => { "text" => "lo" } },
        { "type" => "content_delta" },
        { "type" => "message_delta" },
        { "type" => "thinking_delta" },
        { "type" => "stream_chunk" },
        { "type" => "response" },
        { "type" => "heartbeat" },
        { "type" => "tool_call", "name" => "read" },
        { "type" => "tool_result", "name" => "read" },
        { "type" => "turn_completed" }
      ]
      settled = [{ "type" => "process_exit", "status" => 0 }, { "type" => "rpc_parse_error", "error" => "bad json" }]

      result = engine.mark_worker_completed(
        agent_id: "P1-I1-W1",
        harness_events: streamed + settled,
        last_assistant_text: "Done."
      )
      assert_equal "accepted", result.fetch("status"), result.inspect

      logs = store.load.fetch("logs")
      serialized = JSON.generate(logs)
      %w[token text_delta content_delta message_delta thinking_delta stream_chunk heartbeat turn_completed].each do |ignored|
        refute_includes serialized, "\"#{ignored}\"", "#{ignored} events must not be persisted as logs"
      end
      refute_includes serialized, "hel", "streamed token text must not be persisted"

      harness_logs = logs.select { |log| log.fetch("source_type") == "harness" }
      assert_equal %w[process_exit rpc_parse_error], harness_logs.map { |log| log.dig("details", "event_type") }
      assert_equal %w[info warning], harness_logs.map { |log| log.fetch("level") }
      assert_equal 1, logs.count { |log| log.fetch("source_type") == "worker" }
      assert_equal(
        streamed.length + settled.length,
        logs.reverse.find { |log| log.fetch("source_type") == "worker" }.dig("details", "settled_event_count")
      )
    end
  end

  def test_streamed_tokens_do_not_land_in_the_conversation_log_buffer
    with_store do |store, path, dir|
      seed_worker_state(store, dir)
      engine = build_engine(store: store, dir: dir)

      engine.mark_worker_completed(
        agent_id: "P1-I1-W1",
        harness_events: [{ "type" => "token", "data" => { "text" => "streamed" } }],
        last_assistant_text: "Done."
      )

      assert_equal [], store.load.dig("conversation", "messages")
    end
  end

  # Bounded version of the persistence measurement in scripts/benchmark_log_retention.rb.
  # Limits are intentionally generous: this guards order of magnitude, not machine speed.
  def test_bounded_window_is_cheaper_to_persist_than_a_legacy_window
    log_count = 2_500
    iterations = 3
    with_store do |store, path|
      legacy = legacy_log_state(log_count, non_log_payload_bytes: 20_000)
      legacy_json = JSON.pretty_generate(legacy) + "\n"
      File.write(path, legacy_json)
      legacy_log_bytes = JSON.generate(legacy.fetch("logs")).bytesize
      assert_operator legacy_log_bytes, :>, JSON.generate(legacy).bytesize / 2,
                      "logs dominate an unbounded legacy state"

      legacy_load_ms = average_ms(iterations) { store.load }
      retained = store.load
      store.save(retained, preserve_log_buffer: false)
      retained_bytes = File.size(path)
      retained_log_bytes = JSON.generate(retained.fetch("logs")).bytesize
      retained_load_ms = average_ms(iterations) { store.load }
      retained_save_ms = average_ms(iterations) { store.save(retained, preserve_log_buffer: false) }

      assert_operator retained_bytes, :<, legacy_json.bytesize / 2, "the bounded file is far smaller"
      assert_operator retained_log_bytes, :<, legacy_log_bytes / 2, "the bounded log JSON is far smaller"
      assert_operator retained_load_ms, :<=, legacy_load_ms + 250, "bounded loads never cost dramatically more"
      assert_operator retained_load_ms, :<, 2_000, "a bounded load stays well under two seconds"
      assert_operator retained_save_ms, :<, 2_000, "a bounded save stays well under two seconds"
    end
  end
end
