# frozen_string_literal: true

require "test_helper"
require "support/state_support"

# `Store#load` is the hottest read in Meringue: the TUI calls it for every rendered frame and the
# kernel calls it for every command. It used to re-read, re-normalize, and deep string-compact the
# whole state file every single time, so per-keystroke cost grew with total state size for no
# reason: `save` already normalized and compacted whatever is on disk.
#
# These tests pin the cache and, just as importantly, the two properties that make it safe to
# have one: every `load` still hands back an independent, mutable copy, and any write - ours or
# another Meringue instance's - is observed.
class StateStoreSnapshotCacheTest < Minitest::Test
  include StateSupport

  def test_repeated_loads_of_an_unchanged_file_read_and_normalize_once
    with_store do |store, path|
      write_state_file(path, seeded_state)

      10.times { store.load }

      assert_equal 1, store.snapshot_misses, "an unchanged state file must be normalized once, not once per load"
    end
  end

  def test_each_load_returns_an_independent_mutable_copy
    with_store do |store, path|
      write_state_file(path, seeded_state)

      first = store.load
      first.fetch("issues").first["title"] = "mutated by a caller"
      first.fetch("logs").clear
      first["projects"] = []
      second = store.load

      refute_equal "mutated by a caller", second.fetch("issues").first.fetch("title")
      refute_empty second.fetch("logs")
      refute_empty second.fetch("projects")
    end
  end

  def test_a_write_by_another_instance_invalidates_the_cache
    with_store do |store, path|
      write_state_file(path, seeded_state)
      store.load

      other = Store.new(path: path)
      state = other.load
      state.fetch("projects").first["name"] = "renamed by another instance"
      other.save(state, preserve_log_buffer: false)

      assert_equal "renamed by another instance", store.load.fetch("projects").first.fetch("name")
    end
  end

  def test_a_write_that_reuses_the_path_in_place_invalidates_the_cache
    with_store do |store, path|
      write_state_file(path, seeded_state)
      store.load

      state = seeded_state
      state.fetch("projects").first["name"] = "rewritten in place"
      # Not an atomic rename, so the inode is unchanged: only size and mtime differ.
      File.write(path, JSON.pretty_generate(state) + "\n")

      assert_equal "rewritten in place", store.load.fetch("projects").first.fetch("name")
    end
  end

  def test_this_stores_own_save_is_visible_to_its_next_load
    with_store do |store, path|
      write_state_file(path, seeded_state)
      state = store.load
      state.fetch("projects").first["name"] = "renamed by this store"

      store.save(state, preserve_log_buffer: false)

      assert_equal "renamed by this store", store.load.fetch("projects").first.fetch("name")
    end
  end

  def test_a_save_seeds_the_cache_instead_of_invalidating_it
    with_store do |store, path|
      write_state_file(path, seeded_state)
      store.load
      before = store.snapshot_misses

      store.save(store.load, preserve_log_buffer: false)
      3.times { store.load }

      assert_equal before, store.snapshot_misses, "a save publishes a snapshot this store already has"
    end
  end

  def test_readonly_load_reuses_one_frozen_object_without_weakening_mutable_load
    with_store do |store, path|
      write_state_file(path, seeded_state)

      first = store.load_readonly
      second = store.load_readonly

      assert_same first, second
      assert_predicate first, :frozen?
      assert_predicate first.fetch("issues"), :frozen?
      assert_raises(FrozenError) { first.fetch("issues").first["title"] = "unsafe" }
      mutable = store.load
      mutable.fetch("issues").first["title"] = "safe kernel mutation"
      assert_equal "safe kernel mutation", mutable.fetch("issues").first.fetch("title")
    end
  end

  def test_readonly_load_observes_an_external_atomic_write
    with_store do |store, path|
      write_state_file(path, seeded_state)
      original = store.load_readonly
      other = Store.new(path: path)
      changed = other.load
      changed.fetch("projects").first["name"] = "externally changed"
      other.save(changed, preserve_log_buffer: false)

      refreshed = store.load_readonly

      refute_same original, refreshed
      assert_equal "externally changed", refreshed.fetch("projects").first.fetch("name")
    end
  end

  def test_readonly_load_never_falls_back_to_an_older_cache_when_file_changes_during_read
    with_store do |store, path|
      write_state_file(path, state_named("old cached snapshot"))
      old_snapshot = store.load_readonly
      publish_atomic(path, state_named("snapshot parsed during race"))

      # Force the second atomic publication into the exact gap between parsing and
      # cache publication. remember_snapshot must decline the now-unattributable
      # parse, leaving the old readonly cache in place.
      original_remember = store.method(:remember_snapshot)
      publish = state_named("snapshot published during read")
      raced = false
      store.define_singleton_method(:remember_snapshot) do |fingerprint, state|
        unless raced
          raced = true
          temp = "#{path}.racing"
          File.write(temp, JSON.pretty_generate(publish) + "\n")
          File.rename(temp, path)
        end
        original_remember.call(fingerprint, state)
      end

      raced_snapshot = store.load_readonly

      refute_same old_snapshot, raced_snapshot
      assert_equal "snapshot parsed during race", raced_snapshot.fetch("projects").first.fetch("name")
      assert_predicate raced_snapshot, :frozen?
      assert_predicate raced_snapshot.fetch("projects").first, :frozen?
      assert_equal "snapshot published during read", store.load_readonly.fetch("projects").first.fetch("name")
    end
  end

  def test_a_missing_state_file_still_loads_an_empty_state
    with_store do |store, path|
      refute_path_exists path

      assert_equal Models.empty_state.fetch("projects"), store.load.fetch("projects")
    end
  end

  def test_concurrent_loads_all_observe_a_complete_state
    with_store do |store, path|
      write_state_file(path, seeded_state)

      results = 8.times.map do
        Thread.new { 25.times.map { store.load.fetch("issues").length } }
      end.flat_map(&:value)

      assert_equal [1], results.uniq
    end
  end

  private

  def state_named(name)
    seeded_state.tap { |state| state.fetch("projects").first["name"] = name }
  end

  def publish_atomic(path, state)
    temp = "#{path}.publish"
    File.write(temp, JSON.pretty_generate(state) + "\n")
    File.rename(temp, path)
  end

  def seeded_state
    state = Models.empty_state
    state["projects"] << {
      "id" => "P1", "name" => "Fixture", "root_path" => "/tmp/fixture", "status" => "working",
      "created_at" => timestamp, "updated_at" => timestamp
    }
    state["issues"] << {
      "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil, "title" => "Fixture issue",
      "description" => "Seeded.", "status" => "working", "agent_ids" => [],
      "created_at" => timestamp, "updated_at" => timestamp
    }
    state["logs"] << {
      "id" => "L1", "timestamp" => timestamp, "source_type" => "kernel", "source_id" => nil,
      "level" => "info", "message" => "Seeded.", "details" => {}
    }
    state
  end
end
