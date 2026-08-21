# frozen_string_literal: true

require "test_helper"
require "support/input_support"

# CLI-level tests: argument parsing, version/help, and the --state / --config
# overrides. Every path exercised here runs without a TTY and never opens the
# TUI, starts a harness process, or reads the real ~/.meringue config.
class InputCLITest < Minitest::Test
  include InputSupport

  def test_version_is_printed_without_a_terminal
    result = run_cli(["--version"])

    assert_equal 0, result.fetch("status")
    assert_equal Meringue::VERSION, result.fetch("out").strip
    assert_empty result.fetch("err")

    %w[-v version].each do |flag|
      assert_equal Meringue::VERSION, run_cli([flag]).fetch("out").strip
    end
  end

  def test_help_lists_commands_flags_and_config_defaults
    %w[-h --help help].each do |flag|
      result = run_cli([flag])

      assert_equal 0, result.fetch("status")
      assert_empty result.fetch("err")
      out = result.fetch("out")
      assert_includes out, "meringue tui --state PATH"
      assert_includes out, "meringue tui --config PATH"
      assert_includes out, "meringue reset-state"
      assert_includes out, "meringue workers export"
      assert_includes out, "meringue workers import"
      assert_includes out, "meringue --version"
      assert_includes out, Meringue::Config::DEFAULT_PATH
      assert_includes out, "Supported harness providers"
    end
  end

  # Documented gap: the CLI help lists only the TUI-local slash commands, so the
  # question flow (/questions, /answer, /dismiss) is not discoverable from
  # `meringue --help`. See test/findings/input.md.
  def test_help_does_not_yet_document_the_question_answer_slash_commands
    out = run_cli(["--help"]).fetch("out")

    assert_includes out, "/help"
    assert_includes out, "/recount"
    refute_includes out, "/answer"
    refute_includes out, "/questions"
    refute_includes out, "/dismiss"
  end

  def test_workers_export_cli_writes_a_portable_bundle
    Dir.mktmpdir("meringue-cli-worker-export") do |dir|
      state_path = File.join(dir, "state.json")
      bundle_path = File.join(dir, "workers.json")
      state = Meringue::State::Models.empty_state
      state["projects"] << { "id" => "P1", "name" => "Demo", "root_path" => File.join(dir, "source") }
      state["issues"] << { "id" => "P1-I1", "project_id" => "P1", "title" => "Retry me", "description" => "Do it", "agent_ids" => [] }
      state["agents"] << {
        "id" => "P1-I1-W1", "type" => "worker", "status" => "errored", "project_id" => "P1", "issue_id" => "P1-I1",
        "harness" => "pi", "pid" => 99, "harness_session_id" => "machine-only", "workspace_path" => "/machine/work",
        "harness_metadata" => { "spawn_prompt" => "Retry the task." }
      }
      Meringue::State::Store.new(path: state_path).save(state)

      result = run_cli(["workers", "export", bundle_path, "--state", state_path])

      assert_equal 0, result.fetch("status")
      assert_includes result.fetch("out"), "Exported 1 worker"
      bundle = JSON.parse(File.read(bundle_path))
      serialized = JSON.generate(bundle)
      refute_includes serialized, "machine-only"
      refute_includes serialized, "/machine/work"
      assert_equal "P1-I1-W1", bundle.dig("workers", 0, "source_worker_id")
    end
  end

  def test_unknown_command_prints_help_and_fails
    result = run_cli(["bogus-command"])

    assert_equal 1, result.fetch("status")
    assert_equal "Unknown command: bogus-command", result.fetch("err").strip
    assert_includes result.fetch("out"), "Usage:"
  end

  def test_invalid_option_fails_before_any_tui_setup
    result = run_cli(["tui", "--bogus"])

    assert_equal 1, result.fetch("status")
    assert_equal "invalid option: --bogus", result.fetch("err").strip
    assert_empty result.fetch("out")
  end

  def test_unexpected_positional_arguments_fail
    result = run_cli(["tui", "leftover"])

    assert_equal 1, result.fetch("status")
    assert_equal "Unexpected argument(s): leftover", result.fetch("err").strip
    assert_empty result.fetch("out")
  end

  def test_unparsable_config_fails_before_any_tui_setup
    Dir.mktmpdir("meringue-cli-test") do |dir|
      config_path = write_config(File.join(dir, "config.toml"), "this is not toml\n")

      result = run_cli(["tui", "--config", config_path])

      assert_equal 1, result.fetch("status")
      assert_equal "#{config_path}:1: expected key = value", result.fetch("err").strip
      assert_empty result.fetch("out")
    end
  end

  def test_demo_state_prints_the_fixture_as_json
    result = run_cli(["demo-state"])

    assert_equal 0, result.fetch("status")
    state = JSON.parse(result.fetch("out"))
    assert_kind_of Hash, state
    assert state.key?("projects")
    assert state.key?("agents")
  end

  def test_reset_state_writes_an_empty_state_to_the_configured_state_path
    Dir.mktmpdir("meringue-cli-test") do |dir|
      state_path = File.join(dir, "state.json")

      with_env("MERINGUE_STATE_PATH" => state_path) do
        result = run_cli(["reset-state"])

        assert_equal 0, result.fetch("status")
        assert_equal "Reset Meringue state at #{state_path}", result.fetch("out").strip
      end

      assert File.file?(state_path)
      state = JSON.parse(File.read(state_path))
      assert_empty state.fetch("projects")
      assert_empty state.fetch("issues")
      assert_empty state.fetch("agents")
      assert_empty state.fetch("questions")
      assert_equal Meringue::State::Models::SCHEMA_VERSION, state.fetch("schema_version")
    end
  end

  # Documented behavior: reset-state does not parse runtime options, so --state
  # is ignored and MERINGUE_STATE_PATH (or the default) always wins.
  def test_reset_state_ignores_a_state_flag
    Dir.mktmpdir("meringue-cli-test") do |dir|
      env_path = File.join(dir, "env-state.json")
      flag_path = File.join(dir, "flag-state.json")

      with_env("MERINGUE_STATE_PATH" => env_path) do
        result = run_cli(["reset-state", "--state", flag_path])

        assert_equal 0, result.fetch("status")
        assert_includes result.fetch("out"), env_path
      end

      assert File.file?(env_path)
      refute File.exist?(flag_path)
    end
  end

  def test_state_and_config_flags_override_the_defaults
    parsed = parse_cli_runtime_options(
      ["--state", "/tmp/meringue-state.json", "--config", "/tmp/meringue-config.toml"],
      default_state_path: "/default/state.json"
    )
    options = parsed.fetch("options")

    assert_equal "/tmp/meringue-state.json", options.fetch(:state_path)
    assert_equal "/tmp/meringue-config.toml", options.fetch(:config_path)
    assert_equal({}, parsed.fetch("overrides"))
  end

  def test_defaults_are_used_when_no_flags_are_given
    parsed = parse_cli_runtime_options([], default_state_path: "/default/state.json")
    options = parsed.fetch("options")

    assert_equal "/default/state.json", options.fetch(:state_path)
    assert_equal Meringue::Config::DEFAULT_PATH, options.fetch(:config_path)
    assert_nil options.fetch(:harness)
    assert_nil options.fetch(:head_harness)
    assert_nil options.fetch(:worker_harness)
  end

  def test_harness_flags_become_config_overrides
    parsed = parse_cli_runtime_options(
      ["--harness", "claude_code", "--head-harness", "antigravity", "--worker-harness", "pi"]
    )

    assert_equal(
      {
        "harness" => {
          "provider" => "claude_code",
          "head_provider" => "antigravity",
          "worker_provider" => "pi"
        }
      },
      parsed.fetch("overrides")
    )
  end

  def test_runtime_option_parsing_reports_failures_as_nil
    parsed = parse_cli_runtime_options(["--nope"])

    assert_nil parsed.fetch("options")
  end
end
