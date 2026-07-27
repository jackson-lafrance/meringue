# frozen_string_literal: true

require "benchmark"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../lib/meringue"

LOG_COUNT = Integer(ENV.fetch("MERINGUE_BENCHMARK_LOGS", "5000"), 10)
ITERATIONS = Integer(ENV.fetch("MERINGUE_BENCHMARK_ITERATIONS", "20"), 10)
LIMIT = Meringue::State::Models::LOG_RETENTION_LIMIT

raise "benchmark log count must exceed the retention limit" unless LOG_COUNT > LIMIT

def build_log(index, timestamp)
  long_result = index % 5 == 0
  {
    "id" => "L#{index}",
    "timestamp" => timestamp,
    "source_type" => long_result ? "worker" : "kernel",
    "source_id" => long_result ? "P1-I1-W1" : "P1-I1",
    "level" => "info",
    "message" => long_result ? "Worker P1-I1-W1 completed." : "Updated issue P1-I1.",
    "details" => long_result ? {
      "last_assistant_text" => "## Result #{index}\n\n" + ("Measured diagnostic output. " * 115)
    } : {
      "issue_id" => "P1-I1",
      "changed_fields" => ["status"]
    }
  }
end

def average_ms(iterations)
  Benchmark.realtime { iterations.times { yield } } * 1_000 / iterations
end

def percentage_reduction(before, after)
  ((before - after) * 100.0 / before).round(1)
end

def verify_boundary!
  timestamp = Time.now.utc.iso8601
  state = {
    "logs" => (1..(LIMIT + 1)).map { |index| build_log(index, timestamp) }
  }

  Meringue::State::Models.ensure_state_shape!(state, now: timestamp)
  raise "boundary count is not capped" unless state.fetch("logs").length == LIMIT
  raise "oldest log was not removed" unless state.fetch("logs").first.fetch("id") == "L2"
  raise "newest log was not retained" unless state.fetch("logs").last.fetch("id") == "L#{LIMIT + 1}"
  raise "missing counter did not preserve the high-water mark" unless state.dig("counters", "logs") == LIMIT + 1
end

verify_boundary!

timestamp = Time.now.utc.iso8601
large_state = Meringue::State::Models.empty_state(now: timestamp)
# Approximate the non-log portion of the measured real state so the percentage
# reflects a complete state file instead of an otherwise-empty synthetic shell.
large_state.fetch("metadata")["benchmark_non_log_payload"] = "s" * 90_000
large_state["logs"] = (1..LOG_COUNT).map { |index| build_log(index, timestamp) }
large_state.fetch("counters")["logs"] = LOG_COUNT
legacy_json = JSON.pretty_generate(large_state) + "\n"
legacy_log_bytes = JSON.generate(large_state.fetch("logs")).bytesize
legacy_parse_ms = average_ms(ITERATIONS) { JSON.parse(legacy_json) }
legacy_serialize_ms = average_ms(ITERATIONS) { JSON.pretty_generate(large_state) }

Dir.mktmpdir("meringue-log-retention-") do |directory|
  path = File.join(directory, "state.json")
  File.write(path, legacy_json)
  store = Meringue::State::Store.new(path: path)

  legacy_load_ms = average_ms(ITERATIONS) { store.load }
  retained_state = store.load
  expected_first_id = "L#{LOG_COUNT - LIMIT + 1}"
  raise "legacy load did not cap logs" unless retained_state.fetch("logs").length == LIMIT
  raise "legacy load retained the wrong boundary" unless retained_state.fetch("logs").first.fetch("id") == expected_first_id
  raise "legacy load lost the newest log" unless retained_state.fetch("logs").last.fetch("id") == "L#{LOG_COUNT}"
  raise "legacy load lowered the log counter" unless retained_state.dig("counters", "logs") == LOG_COUNT

  store.save(retained_state, preserve_log_buffer: false)
  retained_bytes = File.size(path)
  retained_log_bytes = JSON.generate(retained_state.fetch("logs")).bytesize
  retained_load_ms = average_ms(ITERATIONS) { store.load }
  retained_save_ms = average_ms(ITERATIONS) { store.save(retained_state, preserve_log_buffer: false) }

  engine = Meringue::Kernel::Engine.new(store: store, cwd: directory)
  result = engine.apply(
    "type" => "AddProject",
    "command_id" => "retention-benchmark",
    "payload" => { "path" => directory, "name" => "Retention benchmark" }
  )
  raise "kernel append failed: #{result.inspect}" unless result.fetch("status") == "accepted"

  reloaded = store.load
  raise "append exceeded cap after reload" unless reloaded.fetch("logs").length == LIMIT
  raise "append reused a pruned ID" unless reloaded.fetch("logs").last.fetch("id") == "L#{LOG_COUNT + 1}"
  raise "counter is not monotonic after reload" unless reloaded.dig("counters", "logs") == LOG_COUNT + 1

  puts "retention limit: #{LIMIT} newest logs"
  puts "synthetic legacy state: #{LOG_COUNT} logs, #{legacy_json.bytesize} bytes"
  puts format(
    "legacy log contribution: %d bytes (%.1f%% of compact JSON state)",
    legacy_log_bytes,
    legacy_log_bytes * 100.0 / JSON.generate(large_state).bytesize
  )
  puts format("legacy JSON parse: %.2f ms average", legacy_parse_ms)
  puts format("legacy JSON serialization: %.2f ms average", legacy_serialize_ms)
  puts format("legacy Store#load (including prune): %.2f ms average", legacy_load_ms)
  puts "retained state: #{LIMIT} logs, #{retained_bytes} bytes (#{percentage_reduction(legacy_json.bytesize, retained_bytes)}% smaller)"
  puts "retained log JSON: #{retained_log_bytes} bytes (#{percentage_reduction(legacy_log_bytes, retained_log_bytes)}% smaller)"
  puts format("retained Store#load: %.2f ms average (%.1f%% faster)", retained_load_ms, percentage_reduction(legacy_load_ms, retained_load_ms))
  puts format("retained Store#save: %.2f ms average", retained_save_ms)
  puts "boundary, newest-entry, reload, and monotonic-ID checks: passed"
end
