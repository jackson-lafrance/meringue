# frozen_string_literal: true

require "time"

# Shared helpers for the state-layer integration tests (store, models, logs, compactor).
#
# Everything here is hermetic: temporary directories only, no network, no real harness
# processes, and never a read or write against ~/.meringue.
module StateSupport
  REPO_ROOT = File.expand_path("../..", __dir__)
  DEMO_STATE_FIXTURE = File.join(REPO_ROOT, "fixtures", "demo_state.json")

  Models = Meringue::State::Models
  Compactor = Meringue::State::Compactor
  Store = Meringue::State::Store

  # Yields an isolated temporary directory that is removed afterwards.
  def with_state_dir(&block)
    Dir.mktmpdir("meringue-state-test-", &block)
  end

  # Yields [store, path] for a fresh state file inside a temporary directory.
  def with_store
    with_state_dir do |dir|
      path = File.join(dir, "state.json")
      yield Store.new(path: path), path, dir
    end
  end

  def read_state_file(path)
    JSON.parse(File.read(path))
  end

  def write_state_file(path, state)
    File.write(path, JSON.pretty_generate(state) + "\n")
    path
  end

  def timestamp
    Time.now.utc.iso8601
  end

  def iso8601?(value)
    return false unless value.is_a?(String)

    Time.iso8601(value)
    true
  rescue ArgumentError
    false
  end

  # A kernel Engine wired to fakes and confined to the given temporary directory.
  # Config lives inside the temporary directory so no user config is read or written.
  def build_engine(store:, dir:)
    Meringue::Kernel::Engine.new(
      store: store,
      cwd: dir,
      config_path: File.join(dir, "config.toml")
    )
  end

  # Mirrors the log shape used by scripts/benchmark_log_retention.rb (now replaced by
  # test/integration/state/log_retention_test.rb) so retention assertions stay comparable.
  def build_log(index, timestamp: self.timestamp)
    long_result = (index % 5).zero?
    {
      "id" => "L#{index}",
      "timestamp" => timestamp,
      "source_type" => long_result ? "worker" : "kernel",
      "source_id" => long_result ? "P1-I1-W1" : "P1-I1",
      "level" => "info",
      "message" => long_result ? "Worker P1-I1-W1 completed." : "Updated issue P1-I1.",
      "details" => if long_result
                     { "last_assistant_text" => "## Result #{index}\n\n" + ("Measured diagnostic output. " * 115) }
                   else
                     { "issue_id" => "P1-I1", "changed_fields" => ["status"] }
                   end
    }
  end

  def build_logs(range, timestamp: self.timestamp)
    range.map { |index| build_log(index, timestamp: timestamp) }
  end

  # A legacy, pre-retention snapshot: unbounded logs plus a non-log payload so state
  # size is not dominated by an otherwise-empty shell.
  def legacy_log_state(log_count, timestamp: self.timestamp, non_log_payload_bytes: 4_000)
    state = Models.empty_state(now: timestamp)
    state.fetch("metadata")["test_non_log_payload"] = "s" * non_log_payload_bytes
    state["logs"] = build_logs(1..log_count, timestamp: timestamp)
    state.fetch("counters")["logs"] = log_count
    state
  end

  # A small but complete orchestration snapshot: project, issue, worker, head,
  # question, log, counters and conversation buffer.
  def sample_state(now: timestamp, project_root: "/tmp/meringue-sample")
    state = Models.empty_state(now: now)
    state["projects"] = [{
      "id" => "P1", "name" => "Sample", "root_path" => project_root,
      "status" => "working", "created_at" => now, "updated_at" => now
    }]
    state["issues"] = [{
      "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil,
      "title" => "Sample issue", "description" => "Round-trip fixture.",
      "status" => "working", "agent_ids" => ["P1-I1-W1"],
      "originating_head_id" => "H1", "created_at" => now, "updated_at" => now
    }]
    state["agents"] = [
      {
        "id" => "P1-I1-W1", "type" => "worker", "project_id" => "P1", "issue_id" => "P1-I1",
        "status" => "working", "harness_metadata" => { "is_streaming" => true },
        "created_at" => now, "updated_at" => now
      },
      {
        "id" => "H1", "type" => "head", "status" => "idle",
        "created_at" => now, "updated_at" => now
      }
    ]
    state["questions"] = [{
      "id" => "Q1", "head_id" => "H1", "project_id" => "P1", "issue_id" => "P1-I1",
      "question" => "Keep the sample?", "context" => "Round-trip fixture.",
      "status" => "open", "answer" => nil, "created_at" => now, "updated_at" => now
    }]
    state["logs"] = [{
      "id" => "L1", "timestamp" => now, "source_type" => "kernel", "source_id" => "P1",
      "level" => "info", "message" => "Added project P1: Sample", "details" => { "project_id" => "P1" }
    }]
    state["conversation"] = {
      "messages" => [{ "id" => 1, "role" => "user", "text" => "hello" }],
      "next_message_id" => 2
    }
    counters = state.fetch("counters")
    counters["projects"] = 1
    counters["heads"] = 1
    counters["questions"] = 1
    counters["logs"] = 1
    counters["issues_by_project"] = { "P1" => 1 }
    counters["workers_by_issue"] = { "P1-I1" => 1 }
    state
  end

  # Seeds a project/issue/worker triple through the store so kernel entry points can
  # operate on it without spawning anything.
  def seed_worker_state(store, dir, now: timestamp)
    state = Models.empty_state(now: now)
    state["projects"] = [{
      "id" => "P1", "name" => "Seeded", "root_path" => dir,
      "status" => "working", "created_at" => now, "updated_at" => now
    }]
    state["issues"] = [{
      "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil,
      "title" => "Seeded issue", "description" => "Seeded for kernel log assertions.",
      "status" => "working", "agent_ids" => ["P1-I1-W1"], "created_at" => now, "updated_at" => now
    }]
    state["agents"] = [{
      "id" => "P1-I1-W1", "type" => "worker", "project_id" => "P1", "issue_id" => "P1-I1",
      "status" => "working", "harness_metadata" => {}, "created_at" => now, "updated_at" => now
    }]
    state.fetch("counters")["projects"] = 1
    state.fetch("counters")["issues_by_project"] = { "P1" => 1 }
    state.fetch("counters")["workers_by_issue"] = { "P1-I1" => 1 }
    store.save(state, preserve_log_buffer: false)
    state
  end

  def log_ids(state)
    Array(state["logs"]).map { |log| log.fetch("id") }
  end

  def log_numbers(state)
    log_ids(state).map { |id| id.delete_prefix("L").to_i }
  end

  # Bounded timing helper for the ported persistence benchmark. Limits in tests are
  # deliberately generous so they measure order of magnitude, not machine speed.
  def average_ms(iterations)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times { yield }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000 / iterations
  end
end
