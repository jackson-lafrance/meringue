# frozen_string_literal: true

require "test_helper"
require "support/state_support"

# State::Compactor may reclaim diagnostic state, but it must never turn one user,
# worker, or log message into a misleading prefix. Message histories are bounded by
# retaining or evicting whole records instead.
class StateCompactorTest < Minitest::Test
  include StateSupport

  def test_compaction_preserves_every_message_bearing_scalar_verbatim
    user_message = "USER START\n#{"u" * 150_000}\nUSER END"
    worker_message = "WORKER START\n#{"w" * 40_000}\nWORKER END"
    log_message = "LOG START\n#{"l" * 9_000}\nLOG END"
    conversation_message = "CHAT START\n#{"c" * 150_000}\nCHAT END"
    state = {
      "agents" => [
        { "type" => "head", "harness_metadata" => { "head_request" => { "user_message" => user_message } } },
        { "type" => "worker", "harness_metadata" => { "last_assistant_text" => worker_message } }
      ],
      "logs" => [{
        "source_type" => "worker",
        "message" => log_message,
        "details" => { "last_assistant_text" => worker_message }
      }],
      "conversation" => { "messages" => [{ "role" => "user", "text" => conversation_message }] },
      "question" => { "original_user_message" => user_message },
      "prompt" => user_message,
      "error_message" => "ERROR START\n#{"e" * 9_000}\nERROR END"
    }
    snapshot = Marshal.load(Marshal.dump(state))

    refute Compactor.compact!(state), "message text alone never needs scalar compaction"
    assert_equal snapshot, state
    refute_includes JSON.generate(state), "[truncated"
  end

  def test_store_save_and_load_preserve_complete_user_worker_and_log_messages
    with_store do |store, path|
      state = sample_state
      user_message = "USER START\n#{"u" * 150_000}\nUSER END"
      worker_message = "WORKER START\n#{"w" * 40_000}\nWORKER END"
      log_message = "LOG START\n#{"l" * 9_000}\nLOG END"
      state.fetch("agents").find { |agent| agent.fetch("type") == "head" }
           .merge!("harness_metadata" => { "head_request" => { "user_message" => user_message } })
      worker = state.fetch("agents").find { |agent| agent.fetch("type") == "worker" }
      worker.fetch("harness_metadata")["last_assistant_text"] = worker_message
      state.fetch("logs").first.merge!(
        "message" => log_message,
        "details" => { "last_assistant_text" => worker_message }
      )
      state.fetch("conversation").fetch("messages").first["text"] = user_message

      store.save(state, preserve_log_buffer: false)
      on_disk = read_state_file(path)
      reloaded = store.load

      [on_disk, reloaded].each do |persisted|
        assert_equal user_message,
                     persisted.fetch("agents").find { |agent| agent.fetch("type") == "head" }
                              .dig("harness_metadata", "head_request", "user_message")
        assert_equal worker_message,
                     persisted.fetch("agents").find { |agent| agent.fetch("type") == "worker" }
                              .dig("harness_metadata", "last_assistant_text")
        assert_equal log_message, persisted.fetch("logs").first.fetch("message")
        assert_equal worker_message, persisted.fetch("logs").first.dig("details", "last_assistant_text")
        assert_equal user_message, persisted.dig("conversation", "messages", 0, "text")
      end
    end
  end

  def test_loading_a_legacy_oversized_message_keeps_it_complete
    with_store do |store, path|
      state = sample_state
      complete_message = "BEGIN\n#{"日" * 50_000}\nEND"
      state.fetch("logs").first["message"] = complete_message
      write_state_file(path, state)

      loaded = store.load

      assert_equal complete_message, loaded.fetch("logs").first.fetch("message")
      assert_equal complete_message, read_state_file(path).fetch("logs").first.fetch("message"),
                   "load normalization does not rewrite or slice the source file"
      assert loaded.fetch("logs").first.fetch("message").valid_encoding?
    end
  end

  def test_store_compact_bang_does_not_rewrite_a_complete_oversized_message
    with_store do |store, path|
      state = sample_state
      complete_message = "BEGIN\n#{"m" * 150_000}\nEND"
      state.fetch("logs").first["message"] = complete_message
      write_state_file(path, state)

      refute store.compact!, "a long complete message is not itself compactable"
      assert_equal complete_message, read_state_file(path).fetch("logs").first.fetch("message")
    end
  end

  def test_log_retention_reclaims_space_by_dropping_whole_old_records
    messages = (1..(Models::LOG_RETENTION_LIMIT + 1)).to_h do |index|
      [index, "log #{index} start\n#{index.to_s * 5_000}\nlog #{index} end"]
    end
    state = {
      "logs" => messages.map do |index, message|
        { "id" => "L#{index}", "message" => message }
      end
    }

    Models.ensure_state_shape!(state)

    assert_equal Models::LOG_RETENTION_LIMIT, state.fetch("logs").length
    refute_includes state.fetch("logs").map { |log| log.fetch("id") }, "L1"
    state.fetch("logs").each do |log|
      index = log.fetch("id").delete_prefix("L").to_i
      assert_equal messages.fetch(index), log.fetch("message"), "retained records stay byte-complete"
    end
  end

  # `harness_metadata.command` is spawn diagnostics. The command has already run, and
  # one argument may duplicate an entire head prompt and kernel snapshot. It is safe to
  # omit that diagnostic argument as a whole; keeping its first 2KB would be misleading.
  def test_an_oversized_spawn_argv_element_is_omitted_whole
    argument = "SYSTEM PROMPT START\n#{"s" * 90_000}\nSYSTEM PROMPT END"
    state = {
      "agents" => [{
        "id" => "H1",
        "harness_metadata" => { "command" => ["pi", "--mode", "rpc", "--append-system-prompt", argument] }
      }]
    }

    assert Compactor.compact!(state)

    argv = state.dig("agents", 0, "harness_metadata", "command")
    assert_equal %w[pi --mode rpc --append-system-prompt], argv.first(4)
    assert_equal(
      format(Compactor::COMMAND_ARGUMENT_OMISSION, bytes: argument.bytesize),
      argv.last
    )
    refute_includes argv.last, "SYSTEM PROMPT START"
    refute_includes argv.last, "[truncated"
  end

  def test_command_argument_compaction_is_idempotent
    state = { "command" => ["x" * (Compactor::COMMAND_ARGUMENT_MAX_BYTES + 1)] }

    assert Compactor.compact!(state)
    snapshot = JSON.generate(state)

    refute Compactor.compact!(state)
    assert_equal snapshot, JSON.generate(state)
  end

  # A goal's metric and guardrail commands are scalars under the same key name, and
  # Meringue still has to run them. Diagnostic argv compaction must never reach them.
  def test_an_executable_command_string_is_preserved
    metric = "bundle exec rake test 2>&1 | tail -1 | #{"grep -o x " * 400}"
    state = {
      "goals" => [{
        "metric" => { "command" => metric },
        "guardrails" => [{ "command" => metric, "expect" => "exit_zero" }]
      }]
    }

    refute Compactor.compact!(state)
    assert_equal metric, state.dig("goals", 0, "metric", "command")
    assert_equal metric, state.dig("goals", 0, "guardrails", 0, "command")
  end
end
