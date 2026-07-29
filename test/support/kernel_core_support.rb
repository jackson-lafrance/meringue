# frozen_string_literal: true

require "test_helper"

# Shared harness for the kernel_core integration slice.
#
# Every engine built here is fully hermetic: state, config, and workspace roots all live
# inside a per-test Dir.mktmpdir, the harness client is the in-process fake, and the head
# runner is a local recording stub. Nothing touches ~/.meringue, the network, or a real
# Pi/Claude process.
module KernelCoreSupport
  # Deterministic stand-in for Heads::PiRunner. It records what the kernel handed it and
  # returns a fixed HeadResult, so kernel-side behaviour is the only thing under test.
  class RecordingHeadRunner < Meringue::Heads::Runner
    attr_reader :calls

    def initialize(head_result: nil)
      @head_result = head_result
      @calls = []
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      @calls << {
        "user_message" => user_message,
        "question_id" => question_id,
        "snapshot" => snapshot,
        "context" => context
      }
      @head_result || {
        "title" => "Recorded head",
        "summary" => "Recording head runner proposed no kernel commands.",
        "commands" => [],
        "questions" => []
      }
    end
  end

  attr_reader :engine, :store, :head_runner, :tmp_root, :state_path

  def setup
    super
    @tmp_root = Dir.mktmpdir("meringue-kernel-core")
    @state_path = File.join(@tmp_root, "state", "state.json")
    @head_runner = RecordingHeadRunner.new
    @store = Meringue::State::Store.new(path: @state_path)
    @engine = build_engine
  end

  def teardown
    FileUtils.remove_entry(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
    super
  end

  def build_engine(store: @store, head_runner: @head_runner)
    Meringue::Kernel::Engine.new(
      store: store,
      harness_client: Meringue::Harness::FakeClient.new,
      head_runner: head_runner,
      workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(@tmp_root, "workspaces")),
      cwd: @tmp_root,
      config_path: File.join(@tmp_root, "config.toml")
    )
  end

  # --- state access -------------------------------------------------------------------

  # Reads the persisted snapshot straight off disk without going through the engine, so a
  # test can prove a rejected command left nothing durable behind.
  def persisted_state
    return nil unless File.exist?(state_path)

    JSON.parse(File.read(state_path))
  end

  def persisted_projects
    Array(persisted_state && persisted_state["projects"])
  end

  def persisted_issues
    Array(persisted_state && persisted_state["issues"])
  end

  def persisted_agents
    Array(persisted_state && persisted_state["agents"])
  end

  def persisted_questions
    Array(persisted_state && persisted_state["questions"])
  end

  def persisted_logs
    Array(persisted_state && persisted_state["logs"])
  end

  def persisted_issue(issue_id)
    persisted_issues.find { |issue| issue["id"] == issue_id }
  end

  def persisted_project(project_id)
    persisted_projects.find { |project| project["id"] == project_id }
  end

  # Domain records only. Log entries, the log counter, and metadata timestamps are excluded
  # because a rejected command legitimately appends one warning log entry.
  def domain_snapshot
    state = persisted_state || {}
    {
      "projects" => Array(state["projects"]),
      "issues" => Array(state["issues"]),
      "agents" => Array(state["agents"]),
      "questions" => Array(state["questions"])
    }
  end

  # Id counters without the log counter, which every rejected command advances by one.
  def domain_counters
    counters = (persisted_state || {})["counters"] || {}
    counters.reject { |key, _value| key == "logs" }
  end

  def rewrite_persisted_state
    state = persisted_state
    yield state
    File.write(state_path, JSON.pretty_generate(state) + "\n")
    state
  end

  # --- fixtures -----------------------------------------------------------------------

  def make_project_dir(name = "app")
    path = File.join(tmp_root, "projects", name)
    FileUtils.mkdir_p(path)
    path
  end

  # Positional-only on purpose so callers can pass a braceless payload hash.
  def apply_command(type, payload = {}, command_id = nil)
    command = { "type" => type, "payload" => payload }
    command["command_id"] = command_id if command_id
    engine.apply(command)
  end

  def add_project!(name: "app", project_name: nil)
    path = make_project_dir(name)
    result = apply_command("AddProject", { "path" => path, "name" => project_name }.compact)
    assert_accepted(result)
    result
  end

  def create_issue!(project_id, title: "Ship the thing", **payload)
    result = apply_command("CreateIssue", { "project_id" => project_id, "title" => title }.merge(payload))
    assert_accepted(result)
    result
  end

  # Spawns a worker without provisioning a git worktree by pointing the worker at an
  # existing directory. This keeps the test hermetic (no git subprocesses) while still
  # exercising the real SpawnWorker code path.
  def spawn_worker!(issue_id, workspace_path:, prompt: "Do the work")
    result = apply_command(
      "SpawnWorker",
      "issue_id" => issue_id,
      "prompt" => prompt,
      "workspace_path" => workspace_path
    )
    assert_accepted(result)
    result
  end

  def spawn_head!(user_message: "Please look into the flaky signup spec", question_id: nil)
    payload = { "user_message" => user_message }
    payload["question_id"] = question_id if question_id
    result = apply_command("SpawnHead", payload)
    assert_accepted(result)
    result
  end

  def ask_question!(head_id, question: "Which environment should this target?", **payload)
    result = apply_command(
      "AskQuestion",
      { "head_id" => head_id, "question" => question }.merge(payload)
    )
    assert_accepted(result)
    result
  end

  # --- assertions ---------------------------------------------------------------------

  RESULT_KEYS = %w[
    command_id command_type status target_id message result errors log_entry_ids
  ].freeze

  def assert_result_shape(result)
    assert_kind_of Hash, result
    assert_equal RESULT_KEYS.sort, result.keys.sort, "unexpected KernelCommandResult keys"
    assert_includes Meringue::Kernel::Result::STATUSES, result.fetch("status")
    assert_kind_of Array, result.fetch("errors")
    assert_kind_of Array, result.fetch("log_entry_ids")
    result.fetch("log_entry_ids").each { |log_id| assert_match(/\AL\d+\z/, log_id) }
    result
  end

  def assert_accepted(result)
    assert_result_shape(result)
    assert_equal "accepted", result.fetch("status"), "expected accepted, got #{result.inspect}"
    assert_empty result.fetch("errors")
    result
  end

  def assert_rejected(result, *expected_errors)
    assert_result_shape(result)
    assert_equal "rejected", result.fetch("status"), "expected rejected, got #{result.inspect}"
    expected_errors.each do |expected|
      assert result.fetch("errors").any? { |error| error.to_s.include?(expected) },
             "expected errors #{result.fetch("errors").inspect} to include #{expected.inspect}"
    end
    result
  end

  def assert_iso8601(value, label = "timestamp")
    assert_kind_of String, value, "#{label} should be a string"
    parsed = Time.iso8601(value)
    assert_kind_of Time, parsed, "#{label} should parse as ISO8601"
    parsed
  rescue ArgumentError
    flunk "#{label} #{value.inspect} is not ISO8601"
  end

  def log_entry(log_id)
    persisted_logs.find { |entry| entry["id"] == log_id }
  end

  def log_messages
    persisted_logs.map { |entry| entry["message"].to_s }
  end

  def assert_log_levels_valid
    persisted_logs.each do |entry|
      assert_includes Meringue::State::Models::LOG_LEVELS, entry.fetch("level"),
                      "log #{entry.fetch("id")} has an unsupported level"
      assert_includes Meringue::State::Models::LOG_SOURCE_TYPES, entry.fetch("source_type"),
                      "log #{entry.fetch("id")} has an unsupported source_type"
    end
  end
end
