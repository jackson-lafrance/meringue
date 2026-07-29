# frozen_string_literal: true

require "test_helper"
require "support/state_support"

# Concurrent-writer behavior for two Store instances pointed at one state path.
#
# Saves publish a complete snapshot with an atomic rename, so a reader always observes
# either the previous or the next snapshot; the read-modify-write entry points
# (save_log_buffer / save_agent_workspace) re-read the newest snapshot so they do not
# lose another writer's records. Whole-snapshot Store#save is last-writer-wins for
# orchestration sections; see test/findings/state.md.
class StateStoreConcurrencyTest < Minitest::Test
  include StateSupport

  def test_readers_never_observe_a_partial_snapshot_while_another_instance_writes
    with_store do |writer, path|
      reader = Store.new(path: path)
      writer.save(sample_state, preserve_log_buffer: false)
      stop = false
      errors = []

      writer_thread = Thread.new do
        200.times do |index|
          state = sample_state
          state.fetch("logs").concat(build_logs(1..40))
          state.fetch("metadata")["iteration"] = index
          writer.save(state, preserve_log_buffer: false)
        end
      rescue StandardError => e
        errors << e
      ensure
        stop = true
      end

      reads = 0
      until stop
        begin
          snapshot = reader.load
          assert_kind_of Hash, snapshot
          assert_equal Models::SCHEMA_VERSION, snapshot.fetch("schema_version")
          refute_empty snapshot.fetch("projects")
          reads += 1
        rescue StandardError => e
          errors << e
          break
        end
      end
      writer_thread.join

      assert_empty errors.map { |error| "#{error.class}: #{error.message}" }
      assert_operator reads, :>, 0, "the reader must have observed at least one snapshot"
      assert_equal %w[state.json state.json.lock], Dir.children(File.dirname(path)).sort,
                   "only the state file and its lock file may remain"
    end
  end

  def test_many_saves_through_one_instance_are_serialized_by_its_mutex
    with_store do |store, path|
      store.save(sample_state, preserve_log_buffer: false)
      errors = []

      threads = 4.times.map do |thread_index|
        Thread.new do
          25.times do |index|
            state = store.load
            state.fetch("metadata")["thread_#{thread_index}"] = index
            store.save(state, preserve_log_buffer: false)
          end
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)

      assert_empty errors.map { |error| "#{error.class}: #{error.message}" }
      final = read_state_file(path)
      assert_equal ["P1"], final.fetch("projects").map { |project| project.fetch("id") }
      assert_equal %w[state.json state.json.lock], Dir.children(File.dirname(path)).sort,
                   "only the state file and its lock file may remain"
    end
  end

  def test_temp_file_name_is_shared_per_process_so_a_save_clobbers_another_writers_temp_file
    # Current behavior, recorded in test/findings/state.md: the temporary file name is
    # "<state path>.tmp.<pid>", so two Store instances saving whole snapshots at the same
    # time inside one process reuse the same temporary path.
    with_store do |store, path|
      temp_path = "#{path}.tmp.#{Process.pid}"
      File.write(temp_path, "another writer's in-flight snapshot")

      store.save(Models.empty_state, preserve_log_buffer: false)

      refute File.exist?(temp_path), "the shared temporary path is consumed by the save"
      assert_kind_of Hash, read_state_file(path)
      assert_equal [], read_state_file(path).fetch("projects")
    end
  end

  def test_sequential_saves_from_two_instances_keep_the_state_file_valid
    with_store do |first, path|
      second = Store.new(path: path)
      first.save(sample_state, preserve_log_buffer: false)

      20.times do |index|
        store = index.even? ? first : second
        state = store.load
        state.fetch("metadata")["iteration"] = index
        store.save(state, preserve_log_buffer: false)
      end

      final = read_state_file(path)
      assert_equal ["P1"], final.fetch("projects").map { |project| project.fetch("id") }
      assert_equal ["P1-I1"], final.fetch("issues").map { |issue| issue.fetch("id") }
      assert_equal ["L1"], log_ids(final)
      assert_equal 19, final.dig("metadata", "iteration")
      assert_equal %w[state.json state.json.lock], Dir.children(File.dirname(path)).sort
    end
  end

  def test_log_buffer_save_from_another_instance_keeps_orchestration_records
    with_store do |first, path|
      second = Store.new(path: path)
      first.save(sample_state, preserve_log_buffer: false)

      second.save_log_buffer(
        messages: [{ "id" => 7, "role" => "user", "text" => "still here" }],
        next_message_id: 8
      )

      merged = first.load
      assert_equal ["P1"], merged.fetch("projects").map { |project| project.fetch("id") },
                   "another instance's log-buffer save must not drop projects"
      assert_equal ["P1-I1"], merged.fetch("issues").map { |issue| issue.fetch("id") }
      assert_equal [7], merged.dig("conversation", "messages").map { |message| message.fetch("id") }
      assert_equal 8, merged.dig("conversation", "next_message_id")
    end
  end

  def test_snapshot_save_merges_the_persisted_log_buffer_by_default
    with_store do |first, path|
      second = Store.new(path: path)
      first.save(sample_state, preserve_log_buffer: false)
      first.save_log_buffer(messages: [{ "id" => 1, "text" => "one" }], next_message_id: 2)

      stale = second.load
      stale["conversation"] = { "messages" => [{ "id" => 3, "text" => "three" }], "next_message_id" => 4 }
      second.save(stale)

      merged = first.load.fetch("conversation")
      assert_equal [1, 3], merged.fetch("messages").map { |message| message.fetch("id") },
                   "the persisted buffer is merged with the incoming buffer by message id"
      assert_equal 4, merged.fetch("next_message_id")
    end
  end

  def test_snapshot_save_can_opt_out_of_log_buffer_merging
    with_store do |store|
      store.save(sample_state, preserve_log_buffer: false)
      store.save_log_buffer(messages: [{ "id" => 1, "text" => "one" }], next_message_id: 2)

      state = store.load
      state["conversation"] = { "messages" => [{ "id" => 9, "text" => "nine" }], "next_message_id" => 10 }
      store.save(state, preserve_log_buffer: false)

      assert_equal [9], store.load.dig("conversation", "messages").map { |message| message.fetch("id") }
    end
  end

  def test_agent_workspace_save_from_another_instance_keeps_orchestration_records
    with_store do |first, path|
      second = Store.new(path: path)
      first.save(sample_state, preserve_log_buffer: false)

      saved = second.save_agent_workspace({
        "selected_agent_id" => "P1-I1-W1",
        "view" => "terminal",
        "filter" => "tools",
        "draft" => "keep typing",
        "agent_scroll_offset" => 3
      })

      assert_equal "P1-I1-W1", saved.fetch("selected_agent_id")
      assert_equal "terminal", saved.fetch("view")
      assert iso8601?(saved.fetch("updated_at"))

      reloaded = first.load
      assert_equal ["P1"], reloaded.fetch("projects").map { |project| project.fetch("id") }
      assert_equal ["L1"], log_ids(reloaded), "presentation state must not disturb logs"
      workspace = reloaded.dig("ui", "agent_workspace")
      assert_equal "P1-I1-W1", workspace.fetch("selected_agent_id")
      assert_equal "keep typing", workspace.fetch("draft")
      assert_equal 3, workspace.fetch("agent_scroll_offset")
    end
  end

  def test_concurrent_log_buffer_saves_through_one_instance_stay_consistent
    # save_log_buffer replaces the whole buffer, so racing read-modify-write callers can
    # drop each other's newest messages (recorded in test/findings/state.md). What must
    # always hold: no errors, no duplicate ids, the persisted seed message survives, and
    # orchestration records are untouched.
    with_store do |store|
      store.save(sample_state, preserve_log_buffer: false)
      errors = []
      allowed_ids = [1]

      threads = 4.times.map do |thread_index|
        ids = 10.times.map { |index| 1_000 + (thread_index * 100) + index + 1 }
        allowed_ids.concat(ids)
        Thread.new do
          ids.each do |message_id|
            existing = store.load.dig("conversation", "messages")
            store.save_log_buffer(
              messages: existing + [{ "id" => message_id, "text" => "m#{message_id}" }],
              next_message_id: message_id + 1
            )
          end
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)

      assert_empty errors.map { |error| "#{error.class}: #{error.message}" }
      final = store.load
      assert_equal ["P1"], final.fetch("projects").map { |project| project.fetch("id") }
      assert_equal ["P1-I1-W1", "H1"], final.fetch("agents").map { |agent| agent.fetch("id") }
      ids = final.dig("conversation", "messages").map { |message| message.fetch("id") }
      assert_equal ids.uniq, ids, "persisted messages must be unique by id"
      assert_includes ids, 1, "the already persisted message is never dropped"
      assert_empty ids - allowed_ids, "no unexpected message ids appear"
      assert_operator final.dig("conversation", "next_message_id"), :>, 0
    end
  end

  def test_whole_snapshot_saves_are_last_writer_wins_for_orchestration_records
    # Documented current behavior: Store has an in-process mutex and atomic renames but
    # no cross-instance advisory lock for whole-snapshot saves, so a stale snapshot
    # overwrites concurrent orchestration edits. Recorded in test/findings/state.md.
    with_store do |first, path|
      second = Store.new(path: path)
      first.save(Models.empty_state, preserve_log_buffer: false)

      first_view = first.load
      second_view = second.load
      first_view.fetch("projects") << { "id" => "P1", "name" => "first" }
      second_view.fetch("projects") << { "id" => "P2", "name" => "second" }
      first.save(first_view, preserve_log_buffer: false)
      second.save(second_view, preserve_log_buffer: false)

      assert_equal ["P2"], first.load.fetch("projects").map { |project| project.fetch("id") }
    end
  end
end
