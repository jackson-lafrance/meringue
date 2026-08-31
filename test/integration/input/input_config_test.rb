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
    head_provider = "claude"
    worker_provider = "pi"

    [harness.pi]
    command = "pi"
    head_extra_args = ["--model", "anthropic/claude-opus-5"]
    use_json_schema = true
    retries = 3

    [commands]
    worker_blacklist = ["*gh pr comment *", "*gh api *pulls/*/comments/*/replies*"]

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
      assert_equal "pi", config.value("harness", "worker_provider")
      assert_equal %w[j down], config.value("tui", "keybindings", "agent_select_next")
      assert_equal ["--model", "anthropic/claude-opus-5"], config.value("harness", "pi", "head_extra_args")
      assert_equal true, config.value("harness", "pi", "use_json_schema")
      assert_equal 3, config.value("harness", "pi", "retries")
      assert_equal ["*gh pr comment *", "*gh api *pulls/*/comments/*/replies*"],
                   config.value("commands", "worker_blacklist")
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

  # The rejection used to name the leaf key, so the same sentence said `head_model`
  # was obsolete and that `harness.head_model` was the replacement. What was actually
  # stale was the provider-scoped `harness.pi.head_model`.
  def test_obsolete_settings_are_reported_as_full_paths
    Dir.mktmpdir("meringue-config-test") do |dir|
      contents = <<~TOML
        [harness]
        provider = "pi"
        head_model = "openai-codex/gpt-5.6-sol"

        [harness.pi]
        head_model = "pi/legacy"
        worker_thinking_level = "medium"

        [tui]
        color_scheme = "gruvbox"
      TOML
      path = write_config(File.join(dir, "config.toml"), contents)

      error = assert_raises(Meringue::Config::ParseError) { Meringue::Config.load(path: path) }

      assert_includes error.message, path
      reported = error.message[/settings in .+?: (.+?)\. Delete/, 1].split(", ")

      # Every entry is a full path, and the current `harness.head_model` this file also
      # sets is not among them.
      assert_equal %w[harness.pi.head_model harness.pi.worker_thinking_level harness.provider tui.color_scheme], reported.sort
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

      merged = config.with_overrides("harness" => { "worker_provider" => "claude" })

      assert_equal "claude", merged.value("harness", "worker_provider")
      assert_equal "claude", merged.value("harness", "head_provider")
      assert_equal "pi", merged.value("harness", "pi", "command")
      assert_equal "gruvbox", merged.value("tui", "colorscheme")

      assert_equal "pi", config.value("harness", "worker_provider")
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
        # With no config and no environment there is no harness to fall back to; Meringue says so
        # rather than choosing one on the user's behalf.
        empty = Meringue::Config.load(path: File.join(dir, "absent.toml"))
        default_registry = Meringue::Harness::Registry.new(config: empty)
        assert_raises(Meringue::Harness::Registry::MissingProviderError) { default_registry.head_provider }
        assert_raises(Meringue::Harness::Registry::MissingProviderError) { default_registry.worker_provider }

        config = Meringue::Config.load(path: write_config(File.join(dir, "config.toml"), FULL_CONFIG))
        config_registry = Meringue::Harness::Registry.new(config: config)
        assert_equal "claude", config_registry.head_provider
        assert_equal "pi", config_registry.worker_provider

        # CLI flags arrive as config overrides.
        cli_overrides = parse_cli_runtime_options(["--worker-harness", "claude_code"]).fetch("overrides")
        cli_registry = Meringue::Harness::Registry.new(config: config.with_overrides(cli_overrides))
        assert_equal "claude", cli_registry.head_provider
        assert_equal "claude", cli_registry.worker_provider

        # Env vars win over both config and CLI flags.
        with_env("MERINGUE_HARNESS" => "pi") do
          assert_equal "pi", config_registry.head_provider
          assert_equal "pi", config_registry.worker_provider

          with_env("MERINGUE_HEAD_HARNESS" => "cc") do
            assert_equal "claude", config_registry.head_provider
            assert_equal "pi", config_registry.worker_provider
          end
        end
      end
    end
  end

  def test_unsupported_provider_is_rejected
    Dir.mktmpdir("meringue-config-test") do |dir|
      config = Meringue::Config.load(
        path: write_config(File.join(dir, "config.toml"), "[harness]\nhead_provider = \"nope\"\n")
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
    assert_equal "codex", Meringue::Harness::Registry.normalize_provider("Codex CLI")
    assert_equal "codex", Meringue::Harness::Registry.normalize_provider("openai-codex")
    assert_equal "", Meringue::Harness::Registry.normalize_provider("")
    assert_equal "", Meringue::Harness::Registry.normalize_provider(nil)
  end

  def test_saving_a_theme_writes_colorscheme
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = write_config(File.join(dir, "config.toml"), "[tui]\ncolorscheme = \"tokyonight\"\n")

      saved = Meringue::Config.save_tui_theme!("gruvbox", path: path)

      assert_equal "gruvbox", saved.value("tui", "colorscheme")
      contents = File.read(path)
      assert_includes contents, 'colorscheme = "gruvbox"'
      refute_includes contents, "color_scheme"
      assert_equal "gruvbox", Meringue::Config.load(path: path).value("tui", "colorscheme")
      assert_empty Dir.glob(File.join(dir, "*.tmp.*"))
    end
  end

  # `tui.color_scheme` is not migrated on the reader's behalf any more: it is one of the
  # obsolete spellings the loader refuses outright, so saving over it never gets far
  # enough to rewrite it.
  def test_the_legacy_theme_alias_is_refused_rather_than_migrated
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = write_config(File.join(dir, "config.toml"), "[tui]\ncolor_scheme = \"tokyonight\"\n")

      error = assert_raises(Meringue::Config::ParseError) { Meringue::Config.save_tui_theme!("gruvbox", path: path) }

      assert_includes error.message, "tui.color_scheme"
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

  # Model and reasoning defaults are role-scoped and provider-independent, so a save
  # writes them under [harness] and leaves the provider table's launch arguments alone.
  def test_saving_agent_session_defaults_preserves_unrelated_config_and_role_arguments
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = write_config(File.join(dir, "config.toml"), FULL_CONFIG)

      saved = Meringue::Config.save_agent_session_defaults!(
        model: "openai/gpt-5.6-sol",
        thinking_level: "xhigh",
        path: path
      )

      assert_equal "openai/gpt-5.6-sol", saved.value("harness", "head_model")
      assert_equal "openai/gpt-5.6-sol", saved.value("harness", "worker_model")
      assert_equal "xhigh", saved.value("harness", "head_thinking_level")
      assert_equal "xhigh", saved.value("harness", "worker_thinking_level")
      assert_equal ["--model", "anthropic/claude-opus-5"], saved.value("harness", "pi", "head_extra_args")
      assert_equal "gruvbox", saved.value("tui", "colorscheme")
      reloaded = Meringue::Config.load(path: path)
      assert_equal "openai/gpt-5.6-sol", reloaded.value("harness", "head_model")
      assert_equal "xhigh", reloaded.value("harness", "worker_thinking_level")
    end
  end

  # The default mode keeps the roles independent, so a role-less save writes both keys
  # and a role-named save moves only that role.
  def test_saving_role_specific_thinking_defaults_writes_only_the_named_role
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = File.join(dir, "config.toml")
      shared = Meringue::Config.save_agent_session_defaults!(thinking_level: "medium", path: path)

      assert_equal "medium", shared.value("harness", "head_thinking_level")
      assert_equal "medium", shared.value("harness", "worker_thinking_level")

      Meringue::Config.save_agent_session_defaults!(thinking_level: "low", thinking_role: "head", path: path)
      split = Meringue::Config.save_agent_session_defaults!(thinking_level: "xhigh", thinking_role: "worker", path: path)

      assert_equal "low", split.value("harness", "head_thinking_level")
      assert_equal "xhigh", split.value("harness", "worker_thinking_level")
      assert_equal "xhigh", Meringue::Config.load(path: path).value("harness", "worker_thinking_level")
    end
  end

  def test_saving_role_specific_model_defaults_preserves_shared_compatibility_and_shared_save_resets_overrides
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = File.join(dir, "config.toml")
      Meringue::Config.save_agent_session_defaults!(model: "anthropic/claude-opus-5", path: path)
      Meringue::Config.save_agent_session_defaults!(model: "openai/gpt-5.6-sol", model_role: "head", path: path)
      split = Meringue::Config.save_agent_session_defaults!(model: "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", model_role: "worker", path: path)

      assert_equal "openai/gpt-5.6-sol", split.value("harness", "head_model")
      assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", split.value("harness", "worker_model")

      shared = Meringue::Config.save_agent_session_defaults!(model: "openai/gpt-5.6-sol", path: path)
      assert_equal "openai/gpt-5.6-sol", shared.value("harness", "head_model")
      assert_equal "openai/gpt-5.6-sol", shared.value("harness", "worker_model")
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

  def test_saving_one_agent_session_default_preserves_the_other
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = File.join(dir, "config.toml")
      Meringue::Config.save_agent_session_defaults!(model: "openai/gpt-5.6-sol", thinking_level: "high", path: path)

      saved = Meringue::Config.save_agent_session_defaults!(thinking_level: "xhigh", path: path)

      assert_equal "openai/gpt-5.6-sol", saved.value("harness", "head_model")
      assert_equal "xhigh", saved.value("harness", "head_thinking_level")
    end
  end

  def test_shipped_example_config_parses
    config = Meringue::Config.load(path: Meringue.root_path("fixtures", "config.example.toml"))

    assert config.loaded?
    assert_equal "meringue", config.value("tui", "colorscheme")
    assert_equal "pi", config.value("harness", "head_provider")
    assert_equal "pi", config.value("harness", "worker_provider")
    assert_equal "pi", config.value("harness", "pi", "command")
    assert_includes config.value("harness", "pi", "head_extra_args"), "--thinking"
    assert_equal ["."], config.value("workspace", "editor_args")
    assert_equal "cancel", config.conflict_predecessor_failure
    assert_equal [], config.value("commands", "worker_blacklist")
    assert_includes Meringue::TUI::Style.colorschemes, config.value("tui", "colorscheme")
  end

  def test_round_trip_write_and_read_preserves_scalar_types
    Dir.mktmpdir("meringue-config-test") do |dir|
      path = File.join(dir, "written.toml")
      data = {
        "tui" => { "colorscheme" => "meringue" },
        "harness" => { "head_provider" => "pi", "pi" => { "retries" => 2, "use_json_schema" => false, "args" => %w[a b] } }
      }

      Meringue::Config.write_toml(path, data)
      config = Meringue::Config.load(path: path)

      assert_equal "meringue", config.value("tui", "colorscheme")
      assert_equal "pi", config.value("harness", "head_provider")
      assert_equal 2, config.value("harness", "pi", "retries")
      assert_equal false, config.value("harness", "pi", "use_json_schema")
      assert_equal %w[a b], config.value("harness", "pi", "args")
    end
  end
end
