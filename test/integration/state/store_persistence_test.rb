# frozen_string_literal: true

require "test_helper"
require "support/state_support"

# Store-level persistence contract: fresh/missing files, atomic writes, schema version,
# full round trips, ISO8601 timestamps, tolerant loading, and corrupt-file behavior.
class StateStorePersistenceTest < Minitest::Test
  include StateSupport

  def test_load_of_missing_file_returns_empty_state_without_creating_it
    with_store do |store, path|
      state = store.load

      refute File.exist?(path), "loading must not create the state file"
      assert_equal Models::SCHEMA_VERSION, state.fetch("schema_version")
      %w[projects issues agents questions logs].each do |key|
        assert_equal [], state.fetch(key), "#{key} should start empty"
      end
      assert_equal({ "messages" => [], "next_message_id" => 0 }, state.fetch("conversation"))
      assert_equal 0, state.fetch("counters").fetch("logs")
      assert_equal({}, state.fetch("counters").fetch("issues_by_project"))
      assert_equal({}, state.fetch("counters").fetch("workers_by_issue"))
      assert iso8601?(state.fetch("metadata").fetch("created_at"))
      assert_equal state.fetch("metadata").fetch("created_at"), state.fetch("metadata").fetch("updated_at")
    end
  end

  def test_default_path_follows_state_path_environment_variable
    original = ENV["MERINGUE_STATE_PATH"]
    ENV["MERINGUE_STATE_PATH"] = "/tmp/meringue-env-state.json"

    assert_equal "/tmp/meringue-env-state.json", Store.default_path
    assert_equal "/tmp/meringue-env-state.json", Store.new.path
  ensure
    if original.nil?
      ENV.delete("MERINGUE_STATE_PATH")
    else
      ENV["MERINGUE_STATE_PATH"] = original
    end
  end

  def test_save_creates_missing_directories_and_writes_pretty_json_with_trailing_newline
    with_state_dir do |dir|
      path = File.join(dir, "nested", "deeper", "state.json")
      store = Store.new(path: path)

      store.save(Models.empty_state, preserve_log_buffer: false)

      contents = File.read(path)
      assert contents.end_with?("\n"), "state file should end with a newline"
      assert_match(/\n  "projects": \[\s*\],/, contents, "state should be pretty-generated")
      assert_kind_of Hash, JSON.parse(contents)
    end
  end

  def test_save_is_atomic_and_leaves_no_temporary_files
    with_store do |store, path, dir|
      store.save(sample_state, preserve_log_buffer: false)

      # The only other file the store is allowed to leave behind is the cross-process lock file
      # that guards single-writer state updates.
      assert_equal ["state.json", "state.json.lock"], Dir.children(dir).sort
      assert_empty Dir.glob(File.join(dir, "*.tmp.*")), "no temporary files may remain after a save"
      assert_kind_of Hash, read_state_file(path)
    end
  end

  def test_round_trip_preserves_projects_issues_agents_questions_logs_and_counters
    with_store do |store, path|
      original = sample_state
      saved = store.save(deep_dup(original), preserve_log_buffer: false)
      on_disk = read_state_file(path)
      reloaded = store.load

      assert_equal saved, on_disk, "save must persist exactly what it returns"
      assert_equal on_disk, reloaded, "load must return the persisted snapshot"

      assert_equal ["P1"], reloaded.fetch("projects").map { |project| project.fetch("id") }
      assert_equal ["P1-I1"], reloaded.fetch("issues").map { |issue| issue.fetch("id") }
      assert_equal %w[P1-I1-W1 H1], reloaded.fetch("agents").map { |agent| agent.fetch("id") }
      assert_equal ["Q1"], reloaded.fetch("questions").map { |question| question.fetch("id") }
      assert_equal ["L1"], log_ids(reloaded)
      assert_equal original.fetch("counters"), reloaded.fetch("counters")
      assert_equal original.fetch("conversation"), reloaded.fetch("conversation")
      assert_equal true, reloaded.fetch("agents").first.fetch("harness_metadata").fetch("is_streaming")
    end
  end

  def test_round_trip_keeps_iso8601_timestamps_intact
    with_store do |store|
      now = "2026-07-11T00:08:00Z"
      store.save(sample_state(now: now), preserve_log_buffer: false)
      reloaded = store.load

      assert_equal now, reloaded.fetch("metadata").fetch("created_at")
      assert_equal now, reloaded.fetch("projects").first.fetch("created_at")
      assert_equal now, reloaded.fetch("logs").first.fetch("timestamp")
      [
        reloaded.dig("metadata", "created_at"),
        reloaded.dig("metadata", "updated_at"),
        reloaded.fetch("issues").first.fetch("updated_at"),
        reloaded.fetch("questions").first.fetch("created_at"),
        reloaded.fetch("logs").first.fetch("timestamp")
      ].each { |value| assert iso8601?(value), "#{value.inspect} should be ISO8601" }
    end
  end

  def test_existing_schema_version_is_preserved_and_absent_version_is_defaulted
    with_store do |store, path|
      write_state_file(path, { "projects" => [] })
      assert_equal Models::SCHEMA_VERSION, store.load.fetch("schema_version")

      write_state_file(path, { "schema_version" => 99, "projects" => [] })
      assert_equal 99, store.load.fetch("schema_version"),
                   "an unknown future schema version is loaded as-is rather than rewritten"
    end
  end

  def test_partial_file_is_filled_in_and_counters_are_derived_from_records
    with_store do |store, path|
      write_state_file(path, {
        "projects" => [{ "id" => "P1" }, { "id" => "P4" }],
        "agents" => [{ "id" => "H2", "type" => "head" }, { "id" => "P1-I1-W1", "type" => "worker", "issue_id" => "P1-I1" }],
        "questions" => [{ "id" => "Q3", "status" => "open" }],
        "logs" => [{ "id" => "L7", "message" => "seeded" }]
      })

      state = store.load

      assert_equal 4, state.fetch("counters").fetch("projects")
      assert_equal 2, state.fetch("counters").fetch("heads")
      assert_equal 3, state.fetch("counters").fetch("questions")
      assert_equal 7, state.fetch("counters").fetch("logs")
      assert_equal [], state.fetch("issues")
      assert_equal 0, state.dig("conversation", "next_message_id")
      assert iso8601?(state.dig("metadata", "created_at"))
    end
  end

  def test_unknown_top_level_and_record_fields_survive_a_round_trip
    with_store do |store|
      state = sample_state
      state["future_section"] = { "enabled" => true, "list" => [1, 2, 3] }
      state.fetch("projects").first["future_project_field"] = "keep me"
      state.fetch("logs").first["future_log_field"] = %w[a b]

      store.save(state, preserve_log_buffer: false)
      reloaded = store.load

      assert_equal({ "enabled" => true, "list" => [1, 2, 3] }, reloaded.fetch("future_section"))
      assert_equal "keep me", reloaded.fetch("projects").first.fetch("future_project_field")
      assert_equal %w[a b], reloaded.fetch("logs").first.fetch("future_log_field")
    end
  end

  def test_demo_state_fixture_loads_tolerantly_without_being_rewritten
    with_state_dir do |dir|
      path = File.join(dir, "state.json")
      FileUtils.cp(DEMO_STATE_FIXTURE, path)
      fixture = read_state_file(DEMO_STATE_FIXTURE)

      state = Store.new(path: path).load

      assert_equal read_state_file(DEMO_STATE_FIXTURE), read_state_file(path), "loading must not rewrite the file"
      assert_equal fixture.fetch("projects").length, state.fetch("projects").length
      assert_equal fixture.fetch("issues").length, state.fetch("issues").length
      assert_equal fixture.fetch("agents").length, state.fetch("agents").length
      assert_equal fixture.fetch("questions").length, state.fetch("questions").length
      assert_equal fixture.fetch("logs").length, state.fetch("logs").length

      # Sections that the fixture omits are materialized with defaults.
      assert_equal({ "messages" => [], "next_message_id" => 0 }, state.fetch("conversation"))
      assert_equal "agent", state.dig("ui", "agent_workspace", "view")
      assert_equal "all", state.dig("ui", "agent_workspace", "filter")

      question = state.fetch("questions").first
      assert_includes Models::QUESTION_STATUSES, question.fetch("status")
      state.fetch("logs").each { |log| assert_includes Models::LOG_LEVELS, log.fetch("level") }
      state.fetch("agents").each { |agent| assert_includes Models::LIFECYCLE_STATUSES, agent.fetch("status") }
    end
  end

  def test_demo_state_fixture_round_trips_through_save_and_load
    with_state_dir do |dir|
      path = File.join(dir, "state.json")
      FileUtils.cp(DEMO_STATE_FIXTURE, path)
      store = Store.new(path: path)

      loaded = store.load
      store.save(loaded, preserve_log_buffer: false)

      assert_equal loaded, store.load
      assert_equal loaded, read_state_file(path)
    end
  end

  def test_corrupt_and_truncated_files_raise_a_json_parse_error
    with_store do |store, path|
      File.write(path, "{not json")
      assert_raises(JSON::ParserError) { store.load }

      valid = JSON.pretty_generate(sample_state)
      File.write(path, valid.byteslice(0, valid.bytesize / 2))
      assert_raises(JSON::ParserError) { store.load }

      File.write(path, "")
      assert_raises(JSON::ParserError) { store.load }
    end
  end

  def test_non_object_json_document_raises_type_error
    with_store do |store, path|
      File.write(path, "[]\n")
      assert_raises(TypeError) { store.load }
    end
  end

  def test_save_recovers_a_state_file_that_was_corrupted_on_disk
    with_store do |store, path|
      File.write(path, "{not json")

      # preserve_log_buffer must not blow up on an unreadable snapshot.
      store.save(sample_state)

      assert_equal ["P1"], store.load.fetch("projects").map { |project| project.fetch("id") }
    end
  end

  def test_compact_bang_on_missing_file_is_a_no_op
    with_state_dir do |dir|
      refute Store.new(path: File.join(dir, "absent.json")).compact!
    end
  end

  private

  def deep_dup(value)
    JSON.parse(JSON.generate(value))
  end
end
