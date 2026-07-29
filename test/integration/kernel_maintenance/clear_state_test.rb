# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# ClearState resets persisted orchestration state and the visible log buffer,
# and must leave a valid loadable state file behind.
class KernelMaintenanceClearStateTest < Minitest::Test
  include KernelMaintenanceSupport

  def populated_state
    state_fixture(
      projects: [project_record(id: "P1", status: "working"), project_record(id: "P2", status: "completed")],
      issues: [
        issue_record(id: "P1-I1", project_id: "P1", status: "working", agent_ids: ["P1-I1-W1"]),
        issue_record(id: "P2-I1", project_id: "P2", status: "completed")
      ],
      agents: [
        worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "working"),
        head_record(id: "H4", status: "working")
      ],
      questions: [question_record(id: "Q3", status: "open")],
      logs: [log_record(id: "L7", message: "existing log")],
      counters: {
        "projects" => 2,
        "heads" => 4,
        "questions" => 3,
        "logs" => 7,
        "issues_by_project" => { "P1" => 1, "P2" => 1 },
        "workers_by_issue" => { "P1-I1" => 1, "P2-I1" => 0 }
      },
      conversation: { "messages" => [{ "id" => 5, "role" => "user", "text" => "hello" }], "next_message_id" => 6 }
    )
  end

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_clear_state_wipes_every_record_collection_and_counter
    write_state(populated_state)
    engine = build_engine

    result = apply_command(engine, "ClearState", {})

    assert_equal "accepted", result.fetch("status")
    assert_equal "Cleared Meringue state.", result.fetch("message")

    state = read_state
    %w[projects issues agents questions logs].each do |collection|
      assert_empty state.fetch(collection), "#{collection} should be empty after ClearState"
    end
    counters = state.fetch("counters")
    assert_equal 0, counters.fetch("projects")
    assert_equal 0, counters.fetch("heads")
    assert_equal 0, counters.fetch("questions")
    assert_equal 0, counters.fetch("logs")
    assert_empty counters.fetch("issues_by_project")
    assert_empty counters.fetch("workers_by_issue")
  end

  def test_clear_state_clears_the_visible_log_buffer
    write_state(populated_state)
    engine = build_engine

    apply_command(engine, "ClearState", {})

    state = read_state
    assert_empty state.dig("conversation", "messages")
    assert_equal 0, state.dig("conversation", "next_message_id")
  end

  def test_clear_state_leaves_a_valid_loadable_state_file
    write_state(populated_state)
    engine = build_engine

    apply_command(engine, "ClearState", {})

    raw = JSON.parse(File.read(state_path))
    assert_equal Meringue::State::Models::SCHEMA_VERSION, raw.fetch("schema_version")
    assert raw.dig("metadata", "created_at"), "cleared state should carry metadata.created_at"
    assert raw.dig("metadata", "updated_at"), "cleared state should carry metadata.updated_at"

    reloaded = Meringue::State::Store.new(path: state_path).load
    assert_equal Meringue::State::Models::SCHEMA_VERSION, reloaded.fetch("schema_version")
    assert_empty reloaded.fetch("agents")

    listed = apply_command(engine, "ListAll", {})
    assert_equal "accepted", listed.fetch("status")
    assert_empty listed.dig("result", "projects")
  end

  def test_state_is_usable_again_after_clearing
    write_state(populated_state)
    engine = build_engine
    apply_command(engine, "ClearState", {})
    project_root = make_dir("fresh-project")

    added = apply_command(engine, "AddProject", "path" => project_root, "name" => "fresh")

    assert_equal "accepted", added.fetch("status")
    assert_equal "P1", added.fetch("target_id")
    state = read_state
    assert_equal ["P1"], ids(state.fetch("projects"))
    assert_documented_status_vocabulary(state)
  end

  def test_clear_state_on_an_empty_state_file_is_accepted
    engine = build_engine

    result = apply_command(engine, "ClearState", {})

    assert_equal "accepted", result.fetch("status")
    assert_empty read_state.fetch("projects")
  end
end
