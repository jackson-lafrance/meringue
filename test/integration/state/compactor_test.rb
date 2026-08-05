# frozen_string_literal: true

require "test_helper"
require "support/state_support"

# State::Compactor trims oversized strings by key before state is persisted, so a single
# verbose message cannot dominate the state file.
class StateCompactorTest < Minitest::Test
  include StateSupport

  TRUNCATION_MARKER = "bytes by Meringue state compaction]"

  def test_key_limits_and_defaults
    assert_equal 100_000, Compactor::DEFAULT_STRING_MAX_BYTES
    assert_equal 2_000, Compactor.limit_for_key("error")
    assert_equal 2_000, Compactor.limit_for_key("error_message")
    assert_equal 4_000, Compactor.limit_for_key("message")
    assert_equal 4_000, Compactor.limit_for_key("stderr_tail")
    assert_equal 4_000, Compactor.limit_for_key("line")
    assert_equal 20_000, Compactor.limit_for_key("last_assistant_text")
    assert_equal 100_000, Compactor.limit_for_key("anything_else")
    assert_equal 100_000, Compactor.limit_for_key(nil)
    assert_equal 2_000, Compactor.limit_for_key("command", in_array: true)
    assert_equal 100_000, Compactor.limit_for_key("command"),
                 "a scalar command is something Meringue still has to run, not a diagnostic"
  end

  def test_values_within_their_limit_are_untouched
    state = {
      "message" => "m" * 4_000,
      "error" => "e" * 2_000,
      "details" => { "last_assistant_text" => "a" * 20_000, "nested" => { "message" => "short" } },
      "list" => ["fine", { "error" => "still fine" }],
      "numbers" => [1, 2, 3],
      "flag" => true,
      "nothing" => nil
    }
    snapshot = JSON.generate(state)

    refute Compactor.compact!(state), "nothing over a limit means no change"
    assert_equal snapshot, JSON.generate(state)
  end

  def test_oversized_values_are_truncated_to_their_key_limit_with_a_marker
    state = {
      "message" => "m" * 5_000,
      "details" => { "error" => "e" * 3_000, "last_assistant_text" => "a" * 30_000 },
      "unknown_key" => "u" * 150_000
    }

    assert Compactor.compact!(state)

    assert_operator state.fetch("message").bytesize, :<, 5_000
    assert state.fetch("message").start_with?("m" * 4_000)
    assert state.fetch("message").end_with?(TRUNCATION_MARKER)
    assert_includes state.fetch("message"), "[truncated 1000 bytes"
    assert_operator state.dig("details", "error").bytesize, :<, 3_000
    assert state.dig("details", "error").start_with?("e" * 2_000)
    assert_operator state.dig("details", "last_assistant_text").bytesize, :<, 30_000
    assert state.dig("details", "last_assistant_text").start_with?("a" * 20_000)
    assert_operator state.fetch("unknown_key").bytesize, :<, 150_000
    assert state.fetch("unknown_key").start_with?("u" * 100_000)
  end

  def test_array_elements_are_compacted_using_the_array_key
    state = { "line" => ["x" * 5_000, "short"], "unknown_list" => ["y" * 5_000] }

    assert Compactor.compact!(state)

    assert_operator state.fetch("line").first.bytesize, :<, 5_000
    assert_equal "short", state.fetch("line").last
    assert_equal 5_000, state.fetch("unknown_list").first.bytesize,
                 "an unknown array key keeps the 100KB default limit"
  end

  # `harness_metadata.command` is the spawn argv kept for diagnostics. One of its elements is the
  # whole `--append-system-prompt` payload, which for a head is the entire kernel snapshot. On a
  # real 1 MB state file that argv was 29% of the whole file, re-read and re-serialized on every
  # frame and every save, and nothing ever read it back.
  def test_a_spawn_argv_element_is_truncated_but_the_argv_shape_survives
    state = {
      "agents" => [{
        "id" => "H1",
        "harness_metadata" => { "command" => ["pi", "--mode", "rpc", "--append-system-prompt", "s" * 90_000] }
      }]
    }

    assert Compactor.compact!(state)

    argv = state.dig("agents", 0, "harness_metadata", "command")
    assert_equal %w[pi --mode rpc --append-system-prompt], argv.first(4), "the program and its flags stay readable"
    assert_operator argv.last.bytesize, :<, 3_000
    assert argv.last.start_with?("s" * 2_000)
    assert_includes argv.last, TRUNCATION_MARKER
  end

  # A goal's metric and guardrail commands are scalars under the same key name, and Meringue still
  # has to run them. Truncating one would silently corrupt a goal loop, so the argv limit is scoped
  # to the array form only.
  def test_an_executable_command_string_is_not_truncated_by_the_argv_limit
    metric = "bundle exec rake test 2>&1 | tail -1 | #{"grep -o x " * 400}"
    state = {
      "goals" => [{
        "metric" => { "command" => metric },
        "guardrails" => [{ "command" => metric, "expect" => "exit_zero" }]
      }]
    }

    refute Compactor.compact!(state), "a 5KB command string is well inside the default limit"
    assert_equal metric, state.dig("goals", 0, "metric", "command")
    assert_equal metric, state.dig("goals", 0, "guardrails", 0, "command")
  end

  def test_deeply_nested_structures_are_visited
    state = { "a" => { "b" => [{ "c" => { "message" => "m" * 9_000 } }] } }

    assert Compactor.compact!(state)

    assert_operator state.dig("a", "b", 0, "c", "message").bytesize, :<, 9_000
  end

  def test_truncation_never_produces_invalid_utf8
    state = { "message" => "日" * 2_000 }

    assert Compactor.compact!(state)

    value = state.fetch("message")
    assert value.valid_encoding?, "a multibyte cut must be scrubbed"
    assert_equal JSON.parse(JSON.generate([value])).first, value, "the value must survive JSON round-tripping"
  end

  def test_repeated_compaction_converges_to_a_fixed_point
    # Compaction is convergent but not idempotent after a single pass: the marker itself
    # counts toward the limit, so a second pass re-trims the already-trimmed value once
    # before the value stops changing. See test/findings/state.md.
    state = { "message" => "m" * 5_000 }
    sizes = []
    changed = []

    5.times do
      changed << Compactor.compact!(state)
      sizes << state.fetch("message").bytesize
    end

    assert_equal [true, true, true, false, false], changed
    assert_equal sizes.last, state.fetch("message").bytesize
    assert_operator sizes.last, :<=, 4_000 + 100
    assert_equal 1, state.fetch("message").scan(TRUNCATION_MARKER).length,
                 "markers never accumulate"
  end

  def test_store_compacts_oversized_values_on_save_and_load
    with_store do |store, path|
      state = sample_state
      state.fetch("logs").first["message"] = "m" * 9_000
      state.fetch("logs").first.fetch("details")["last_assistant_text"] = "a" * 40_000

      store.save(state, preserve_log_buffer: false)

      on_disk = read_state_file(path).fetch("logs").first
      assert_operator on_disk.fetch("message").bytesize, :<, 9_000
      assert_operator on_disk.dig("details", "last_assistant_text").bytesize, :<, 40_000
      assert_includes on_disk.fetch("message"), TRUNCATION_MARKER
    end
  end

  def test_load_compacts_an_oversized_file_written_outside_the_store
    with_store do |store, path|
      state = sample_state
      state.fetch("logs").first["message"] = "m" * 12_000
      write_state_file(path, state)

      loaded = store.load

      assert_operator loaded.fetch("logs").first.fetch("message").bytesize, :<, 12_000
      assert_equal 12_000, read_state_file(path).fetch("logs").first.fetch("message").bytesize,
                   "load compacts in memory and leaves the file for the next save"
    end
  end

  def test_store_compact_bang_reports_whether_the_file_changed
    with_store do |store, path|
      state = sample_state
      state.fetch("logs").first["message"] = "m" * 12_000
      write_state_file(path, state)

      assert store.compact!, "an oversized file is compacted"
      assert_operator read_state_file(path).fetch("logs").first.fetch("message").bytesize, :<, 12_000

      # The convergence pass above means one further compaction can still report a change;
      # the size must remain bounded and stable after that.
      store.compact!
      bounded = read_state_file(path).fetch("logs").first.fetch("message").bytesize
      store.compact!
      assert_equal bounded, read_state_file(path).fetch("logs").first.fetch("message").bytesize
      refute store.compact!, "a settled state reports no further change"
    end
  end
end
