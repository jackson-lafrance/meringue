# frozen_string_literal: true

require "test_helper"
require "support/input_support"

# Config loading tests: defaults, loading from a tmp path, invalid/partial
# config handling, CLI-flag-vs-config-vs-default precedence, and env var
# overrides. The real ~/.meringue/config.toml is never read or written.
class InputConfigTest < Minitest::Test
  include InputSupport

  FULL_CONFIG = <<~TOML
    # Meringue test config
    [tui]
    colorscheme = "gruvbox"

    [tui.keybindings]
    agent_select_next = ["j", "down"]

    [harness]
    provider = "pi"
    head_provider = "claude"

    [harness.pi]
    command = "pi"
    head_extra_args = ["--model", "anthropic/claude-opus-5"]
    use_json_schema = true
    retries = 3

    [workspace]
    editor_args = ["."]
  TOML

  def test_missing_config_file_yields_empty_defaults
    Dir.mktmpdir("meringue-config-test") do |dir|
      config = Meringue::Config.load(path: File.join(dir, "absent.toml"))

      refute config.loaded?
      assert_equal({}, config.to_h)
      assert_nil config.value("harness", "provider")
      assert_nil config.value("tui", "colorscheme")
      assert_equal({}, config.section("tui"))
      assert_equal({}, config.section("tui", "keybindings"))
      assert_equal File.join(dir, "absent.toml"), config.path
    end
  end

  def test_loading_a_config_from_a_tmp_path
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = write_config(File.join(dir, "config.toml"), FULL_CONFIG)
      config = Meringue::Config.load(path: path)

      assert config.loaded?
      assert_equal path, config.path
      assert_equal "gruvbox", config.value("tui", "colorscheme")
      assert_equal "claude", config.value("harness", "head_provider")
      assert_equal "pi", config.value("harness", "provider")
      assert_equal %w[j down], config.value("tui", "keybindings", "agent_select_next")
      assert_equal ["--model", "anthropic/claude-opus-5"], config.value("harness", "pi", "head_extra_args")
      assert_equal true, config.value("harness", "pi", "use_json_schema")
      assert_equal 3, config.value("harness", "pi", "retries")
      assert_equal({ "agent_select_next" => %w[j down] }, config.section("tui", "keybindings"))
    end
  end

  def test_partial_config_keeps_untouched_values_absent
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = write_config(File.join(dir, "config.toml"), "[tui]\ncolorscheme = \"tokyonight\"\n")
      config = Meringue::Config.load(path: path)

      assert_equal "tokyonight", config.value("tui", "colorscheme")
      assert_nil config.value("harness", "provider")
      assert_equal({}, config.section("harness"))
      assert_equal({}, config.section("harness", "pi"))
    end
  end

  def test_invalid_config_raises_a_parse_error_with_path_and_line
    Dir.mktmpdir("meringue-config-test") do |dir|
      cases = {
        "junk.toml" => ["this is not toml\n", "expected key = value"],
        "section.toml" => ["[tui\ncolorscheme = \"meringue\"\n", "invalid section header"],
        "empty_section.toml" => ["[]\n", "empty section header"],
        "value.toml" => ["[tui]\ncolorscheme = @nope\n", "unsupported value"]
      }

      cases.each do |file, (contents, message)|
        path = write_config(File.join(dir, file), contents)

        error = assert_raises(Meringue::Config::ParseError) { Meringue::Config.load(path: path) }
        assert_includes error.message, path
        assert_includes error.message, message
      end
    end
  end

  def test_comments_and_quoting_are_handled
    Dir.mktmpdir("meringue-config-test") do |dir|
      contents = <<~TOML
        # leading comment
        [tui]
        colorscheme = "meringue" # trailing comment
        note = 'single # quoted'
        hash_in_string = "value # not a comment"
      TOML
      config = Meringue::Config.load(path: write_config(File.join(dir, "config.toml"), contents))

      assert_equal "meringue", config.value("tui", "colorscheme")
      assert_equal "single # quoted", config.value("tui", "note")
      assert_equal "value # not a comment", config.value("tui", "hash_in_string")
    end
  end

  def test_with_overrides_deep_merges_without_mutating_the_original
    Dir.mktmpdir("meringue-config-test") do |dir|
      config = Meringue::Config.load(path: write_config(File.join(dir, "config.toml"), FULL_CONFIG))

      merged = config.with_overrides("harness" => { "provider" => "antigravity" })

      assert_equal "antigravity", merged.value("harness", "provider")
      assert_equal "claude", merged.value("harness", "head_provider")
      assert_equal "pi", merged.value("harness", "pi", "command")
      assert_equal "gruvbox", merged.value("tui", "colorscheme")

      assert_equal "pi", config.value("harness", "provider")
      assert_equal config.path, merged.path
      assert_equal config.loaded?, merged.loaded?
    end
  end

  def test_empty_overrides_change_nothing
    Dir.mktmpdir("meringue-config-test") do |dir|
      config = Meringue::Config.load(path: write_config(File.join(dir, "config.toml"), FULL_CONFIG))

      assert_equal config.to_h, config.with_overrides({}).to_h
      assert_equal config.to_h, config.with_overrides(nil).to_h
    end
  end

  def test_harness_provider_precedence_default_then_config_then_cli_then_env
    Dir.mktmpdir("meringue-config-test") do |dir|
      with_env("MERINGUE_HARNESS" => nil, "MERINGUE_HEAD_HARNESS" => nil, "MERINGUE_WORKER_HARNESS" => nil) do
        empty = Meringue::Config.load(path: File.join(dir, "absent.toml"))
        default_registry = Meringue::Harness::Registry.new(config: empty)
        assert_equal "pi", default_registry.head_provider
        assert_equal "pi", default_registry.worker_provider

        config = Meringue::Config.load(path: write_config(File.join(dir, "config.toml"), FULL_CONFIG))
        config_registry = Meringue::Harness::Registry.new(config: config)
        assert_equal "claude", config_registry.head_provider
        assert_equal "pi", config_registry.worker_provider

        # CLI flags arrive as config overrides.
        cli_overrides = parse_cli_runtime_options(["--worker-harness", "antigravity"]).fetch("overrides")
        cli_registry = Meringue::Harness::Registry.new(config: config.with_overrides(cli_overrides))
        assert_equal "claude", cli_registry.head_provider
        assert_equal "antigravity", cli_registry.worker_provider

        # Env vars win over both config and CLI flags.
        with_env("MERINGUE_HARNESS" => "antigravity") do
          assert_equal "antigravity", config_registry.head_provider
          assert_equal "antigravity", config_registry.worker_provider

          with_env("MERINGUE_HEAD_HARNESS" => "cc") do
            assert_equal "claude", config_registry.head_provider
            assert_equal "antigravity", config_registry.worker_provider
          end
        end
      end
    end
  end

  def test_unsupported_provider_is_rejected
    Dir.mktmpdir("meringue-config-test") do |dir|
      config = Meringue::Config.load(
        path: write_config(File.join(dir, "config.toml"), "[harness]\nprovider = \"nope\"\n")
      )
      registry = Meringue::Harness::Registry.new(config: config)

      with_env("MERINGUE_HARNESS" => nil, "MERINGUE_HEAD_HARNESS" => nil, "MERINGUE_WORKER_HARNESS" => nil) do
        error = assert_raises(ArgumentError) { registry.head_provider }
        assert_includes error.message, "Unsupported harness provider"
      end
    end
  end

  def test_provider_aliases_normalize_to_canonical_names
    assert_equal "claude", Meringue::Harness::Registry.normalize_provider("claude_code")
    assert_equal "claude", Meringue::Harness::Registry.normalize_provider("Claude-Code")
    assert_equal "claude", Meringue::Harness::Registry.normalize_provider("cc")
    assert_equal "antigravity", Meringue::Harness::Registry.normalize_provider("agy")
    assert_equal "pi", Meringue::Harness::Registry.normalize_provider("")
    assert_equal "pi", Meringue::Harness::Registry.normalize_provider(nil)
  end

  def test_saving_a_theme_writes_colorscheme_and_drops_the_legacy_alias
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = write_config(File.join(dir, "config.toml"), "[tui]\ncolor_scheme = \"tokyonight\"\n")

      saved = Meringue::Config.save_tui_theme!("gruvbox", path: path)

      assert_equal "gruvbox", saved.value("tui", "colorscheme")
      contents = File.read(path)
      assert_includes contents, 'colorscheme = "gruvbox"'
      refute_includes contents, "color_scheme"
      assert_equal "gruvbox", Meringue::Config.load(path: path).value("tui", "colorscheme")
      assert_empty Dir.glob(File.join(dir, "*.tmp.*"))
    end
  end

  def test_saving_a_theme_creates_a_missing_config_file
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = File.join(dir, "nested", "config.toml")

      Meringue::Config.save_tui_theme!("kanagawa", path: path)

      assert File.file?(path)
      assert_equal "kanagawa", Meringue::Config.load(path: path).value("tui", "colorscheme")
    end
  end

  def test_saving_pi_session_defaults_preserves_unrelated_config_and_role_arguments
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = write_config(File.join(dir, "config.toml"), FULL_CONFIG)

      saved = Meringue::Config.save_pi_session_defaults!(
        model: "openai/gpt-5.6-sol",
        thinking_level: "xhigh",
        path: path
      )

      assert_equal "openai/gpt-5.6-sol", saved.value("harness", "pi", "model")
      assert_equal "xhigh", saved.value("harness", "pi", "thinking_level")
      assert_equal ["--model", "anthropic/claude-opus-5"], saved.value("harness", "pi", "head_extra_args")
      assert_equal "gruvbox", saved.value("tui", "colorscheme")
      reloaded = Meringue::Config.load(path: path)
      assert_equal "openai/gpt-5.6-sol", reloaded.value("harness", "pi", "model")
      assert_equal "xhigh", reloaded.value("harness", "pi", "thinking_level")
    end
  end

  def test_saving_role_specific_thinking_defaults_preserves_shared_compatibility_and_shared_save_resets_overrides
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = File.join(dir, "config.toml")
      Meringue::Config.save_pi_session_defaults!(thinking_level: "medium", path: path)
      Meringue::Config.save_pi_session_defaults!(thinking_level: "low", thinking_role: "head", path: path)
      split = Meringue::Config.save_pi_session_defaults!(thinking_level: "xhigh", thinking_role: "worker", path: path)

      assert_equal "medium", split.value("harness", "pi", "thinking_level")
      assert_equal "low", split.value("harness", "pi", "head_thinking_level")
      assert_equal "xhigh", split.value("harness", "pi", "worker_thinking_level")

      shared = Meringue::Config.save_pi_session_defaults!(thinking_level: "high", path: path)
      assert_equal "high", shared.value("harness", "pi", "thinking_level")
      assert_nil shared.value("harness", "pi", "head_thinking_level")
      assert_nil shared.value("harness", "pi", "worker_thinking_level")
    end
  end

  def test_conflict_predecessor_failure_accepts_supported_values_and_defaults_safely
    assert_equal "cancel", Meringue::Config.new({}, path: "/tmp/config.toml").conflict_predecessor_failure
    assert_equal "run", Meringue::Config.new(
      { "conflicts" => { "predecessor_failure" => "run" } }, path: "/tmp/config.toml"
    ).conflict_predecessor_failure
    assert_equal "cancel", Meringue::Config.new(
      { "conflicts" => { "predecessor_failure" => "unexpected" } }, path: "/tmp/config.toml"
    ).conflict_predecessor_failure
  end

  def test_worker_provisioning_concurrency_defaults_validates_and_caps_the_bound
    default = Meringue::Config::DEFAULT_WORKER_PROVISIONING_CONCURRENCY
    maximum = Meringue::Config::MAX_WORKER_PROVISIONING_CONCURRENCY

    assert_equal default, Meringue::Config.new({}, path: "/tmp/config.toml").worker_provisioning_concurrency
    assert_equal 4, Meringue::Config.new(
      { "workspace" => { "worker_provisioning_concurrency" => 4 } }, path: "/tmp/config.toml"
    ).worker_provisioning_concurrency
    assert_equal default, Meringue::Config.new(
      { "workspace" => { "worker_provisioning_concurrency" => 0 } }, path: "/tmp/config.toml"
    ).worker_provisioning_concurrency
    assert_equal default, Meringue::Config.new(
      { "workspace" => { "worker_provisioning_concurrency" => "many" } }, path: "/tmp/config.toml"
    ).worker_provisioning_concurrency
    assert_equal maximum, Meringue::Config.new(
      { "workspace" => { "worker_provisioning_concurrency" => maximum + 100 } }, path: "/tmp/config.toml"
    ).worker_provisioning_concurrency
  end

  def test_saving_one_pi_session_default_preserves_the_other
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = File.join(dir, "config.toml")
      Meringue::Config.save_pi_session_defaults!(model: "openai/gpt-5.6-sol", thinking_level: "high", path: path)

      saved = Meringue::Config.save_pi_session_defaults!(thinking_level: "xhigh", path: path)

      assert_equal "openai/gpt-5.6-sol", saved.value("harness", "pi", "model")
      assert_equal "xhigh", saved.value("harness", "pi", "thinking_level")
    end
  end

  def test_shipped_example_config_parses
    config = Meringue::Config.load(path: Meringue.root_path("fixtures", "config.example.toml"))

    assert config.loaded?
    assert_equal "meringue", config.value("tui", "colorscheme")
    assert_equal "pi", config.value("harness", "provider")
    assert_equal "pi", config.value("harness", "pi", "command")
    assert_includes config.value("harness", "pi", "head_extra_args"), "--thinking"
    assert_equal ["."], config.value("workspace", "editor_args")
    assert_equal "cancel", config.conflict_predecessor_failure
    assert_includes Meringue::TUI::Style.colorschemes, config.value("tui", "colorscheme")
  end

  def test_round_trip_write_and_read_preserves_scalar_types
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = File.join(dir, "written.toml")
      data = {
        "tui" => { "colorscheme" => "meringue" },
        "harness" => { "provider" => "pi", "pi" => { "retries" => 2, "use_json_schema" => false, "args" => %w[a b] } }
      }

      Meringue::Config.write_toml(path, data)
      config = Meringue::Config.load(path: path)

      assert_equal "meringue", config.value("tui", "colorscheme")
      assert_equal "pi", config.value("harness", "provider")
      assert_equal 2, config.value("harness", "pi", "retries")
      assert_equal false, config.value("harness", "pi", "use_json_schema")
      assert_equal %w[a b], config.value("harness", "pi", "args")
    end
  end
end
