# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class InputSettingsSchemaStoreTest < Minitest::Test
  class FailingPublishStore < Meringue::Config::Store
    private

    def publish!(_data)
      raise Errno::ENOSPC, "simulated full disk"
    end
  end

  def test_schema_has_unique_ids_and_owned_paths_and_registers_every_keybinding
    assert Meringue::Config::Schema.validate_registry!
    definitions = Meringue::Config::Schema.definitions

    assert_equal definitions.length, definitions.map(&:id).uniq.length
    paths = definitions.flat_map { |definition| [definition.path, *definition.aliases] }.compact.map { |path| path.join(".") }
    assert_equal paths.length, paths.uniq.length
    Meringue::TUI::Keybindings.actions.each do |action|
      assert definitions.any? { |definition| definition.id == "keybindings.#{action}" }, action
    end
  end

  def test_every_supported_editor_type_normalizes_and_validates
    samples = {
      "boolean" => true,
      "enum" => "run",
      "integer" => 2,
      "duration" => 30,
      "path" => "/tmp/work",
      "string" => "prefix",
      "command_argv" => "code --reuse-window",
      "string_list" => "one,two",
      "environment_map" => "A=one\nB=two",
      "blacklist_glob_list" => "*gh api*,*rm -rf*",
      "keybinding_list" => "ctrl-x,shift-enter",
      "model_reference" => "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast",
      "thinking_level" => "xhigh"
    }

    samples.each do |type, sample|
      definition = Meringue::Config::Schema.definitions.find { |candidate| candidate.type == type }
      refute_nil definition, type
      sample = definition.option_values(empty_config).first if type == "enum"
      normalized = definition.validate_value(sample, config: empty_config)
      refute_nil normalized, type
    end
  end

  def test_transaction_preserves_unknown_keys_and_serializes_role_fallbacks
    with_paths do |config_path, _state_path|
      File.write(config_path, <<~TOML)
        custom = "keep me"
        [plugin.future]
        enabled = true
        [harness.pi]
        model = "anthropic/claude-opus-5"
      TOML
      store = Meringue::Config::Store.new(path: config_path)
      store.save(
        base_fingerprint: store.fingerprint,
        changes: {
          "experiments.split_agent_defaults" => true,
          "agent.head_model" => "openai/gpt-5.6-sol",
          "agent.worker_model" => "anthropic/claude-opus-5"
        }
      )

      config = Meringue::Config.load(path: config_path)
      assert_equal "keep me", config.value("custom")
      assert_equal true, config.value("plugin", "future", "enabled")
      assert_equal "anthropic/claude-opus-5", config.value("harness", "model")
      assert_nil config.value("harness", "pi", "model")
      assert_equal true, config.value("experiments", "split_agent_defaults")
      assert_equal "openai/gpt-5.6-sol", config.value("harness", "head_model")
      assert_nil config.value("harness", "worker_model")
    end
  end

  def test_equal_role_values_collapse_to_shared_compatibility_keys
    with_paths do |config_path, _state_path|
      store = Meringue::Config::Store.new(path: config_path)
      store.save(
        base_fingerprint: store.fingerprint,
        changes: {
          "agent.head_harness" => "claude",
          "agent.worker_harness" => "claude",
          "agent.head_thinking" => "high",
          "agent.worker_thinking" => "high"
        }
      )
      config = Meringue::Config.load(path: config_path)

      assert_equal "claude", config.value("harness", "provider")
      assert_nil config.value("harness", "head_provider")
      assert_nil config.value("harness", "worker_provider")
      assert_equal "high", config.value("harness", "thinking_level")
      assert_nil config.value("harness", "head_thinking_level")
      assert_nil config.value("harness", "worker_thinking_level")
    end
  end

  def test_shared_session_defaults_persist_for_heads_and_workers
    with_paths do |config_path, _state_path|
      Meringue::Config.save_agent_session_defaults!(
        model: "openai/gpt-5.6-sol",
        thinking_level: "high",
        path: config_path
      )

      config = Meringue::Config.load(path: config_path)
      registry = Meringue::Harness::Registry.new(config: config)
      defaults = registry.session_defaults(provider: "pi")
      assert_equal "openai/gpt-5.6-sol", config.value("harness", "model")
      assert_equal "high", config.value("harness", "thinking_level")
      assert_equal "openai/gpt-5.6-sol", defaults.dig("roles", "head", "model")
      assert_equal "openai/gpt-5.6-sol", defaults.dig("roles", "worker", "model")
      assert_equal "high", defaults.dig("roles", "head", "thinking_level")
      assert_equal "high", defaults.dig("roles", "worker", "thinking_level")
      assert_equal "consistent", defaults.fetch("consistency")
    end
  end

  def test_split_agent_defaults_persist_role_values_and_collapse_when_disabled
    with_paths do |config_path, _state_path|
      store = Meringue::Config::Store.new(path: config_path)
      store.save(base_fingerprint: store.fingerprint, changes: { "experiments.split_agent_defaults" => true })
      Meringue::Config.save_agent_session_defaults!(
        model: "openai/head-model",
        model_role: "head",
        thinking_level: "low",
        thinking_role: "head",
        path: config_path
      )
      Meringue::Config.save_agent_session_defaults!(
        model: "anthropic/worker-model",
        model_role: "worker",
        thinking_level: "max",
        thinking_role: "worker",
        path: config_path
      )

      config = Meringue::Config.load(path: config_path)
      defaults = Meringue::Harness::Registry.new(config: config).session_defaults(provider: "pi")
      assert_equal "openai/head-model", defaults.dig("roles", "head", "model")
      assert_equal "anthropic/worker-model", defaults.dig("roles", "worker", "model")
      assert_equal "low", defaults.dig("roles", "head", "thinking_level")
      assert_equal "max", defaults.dig("roles", "worker", "thinking_level")
      assert_equal "mixed", defaults.fetch("consistency")

      store.save(base_fingerprint: store.fingerprint, changes: { "experiments.split_agent_defaults" => false })
      config = Meringue::Config.load(path: config_path)
      defaults = Meringue::Harness::Registry.new(config: config).session_defaults(provider: "pi")
      assert_equal false, config.value("experiments", "split_agent_defaults")
      assert_equal defaults.dig("roles", "head", "model"), defaults.dig("roles", "worker", "model")
      assert_equal defaults.dig("roles", "head", "thinking_level"), defaults.dig("roles", "worker", "thinking_level")
      assert_nil config.value("harness", "head_model")
      assert_nil config.value("harness", "worker_model")
    end
  end

  def test_stale_draft_is_rejected_without_overwriting_external_edit
    with_paths do |config_path, _state_path|
      File.write(config_path, "[tui]\ncolorscheme = \"meringue\"\n")
      store = Meringue::Config::Store.new(path: config_path)
      baseline = store.fingerprint
      File.write(config_path, "[tui]\ncolorscheme = \"kanagawa\"\n")

      assert_raises(Meringue::Config::StaleRevisionError) do
        store.save(base_fingerprint: baseline, changes: { "appearance.theme" => "gruvbox" })
      end
      assert_equal "kanagawa", Meringue::Config.load(path: config_path).value("tui", "colorscheme")
    end
  end

  def test_concurrent_writers_publish_once_and_make_the_other_stale
    with_paths do |config_path, _state_path|
      store = Meringue::Config::Store.new(path: config_path)
      baseline = store.fingerprint
      outcomes = Queue.new
      threads = %w[gruvbox kanagawa].map do |theme|
        Thread.new do
          begin
            store.save(base_fingerprint: baseline, changes: { "appearance.theme" => theme })
            outcomes << :saved
          rescue Meringue::Config::StaleRevisionError
            outcomes << :stale
          end
        end
      end
      threads.each(&:join)

      assert_equal %i[saved stale], 2.times.map { outcomes.pop }.sort
      assert_includes %w[gruvbox kanagawa], Meringue::Config.load(path: config_path).value("tui", "colorscheme")
    end
  end

  def test_new_files_are_private_and_existing_mode_is_preserved
    with_paths do |config_path, _state_path|
      store = Meringue::Config::Store.new(path: config_path)
      store.save(base_fingerprint: store.fingerprint, changes: { "appearance.theme" => "gruvbox" })
      assert_equal 0o600, File.stat(config_path).mode & 0o777

      File.chmod(0o640, config_path)
      store.save(base_fingerprint: store.fingerprint, changes: { "appearance.theme" => "kanagawa" })
      assert_equal 0o640, File.stat(config_path).mode & 0o777
    end
  end

  def test_failed_publish_leaves_the_previous_file_untouched
    with_paths do |config_path, _state_path|
      File.write(config_path, "[tui]\ncolorscheme = \"meringue\"\n")
      before = File.binread(config_path)
      store = FailingPublishStore.new(path: config_path)

      error = assert_raises(Meringue::Config::PersistenceError) do
        store.save(base_fingerprint: store.fingerprint, changes: { "appearance.theme" => "gruvbox" })
      end
      assert_includes error.message, "No space left on device"
      assert_equal before, File.binread(config_path)
      assert_empty Dir.glob(File.join(File.dirname(config_path), ".config.toml.tmp-*"))
    end
  end

  def test_setup_marker_and_reviewed_settings_publish_in_one_transaction
    with_paths do |config_path, _state_path|
      store = Meringue::Config::Store.new(path: config_path)
      transaction = store.save(
        base_fingerprint: store.fingerprint,
        changes: {
          "agent.model" => "openai/gpt-5.6-sol",
          "agent.thinking" => "high",
          "experiments.github_support" => true
        },
        onboarding_outcome: "completed",
        completed_at: "2026-08-16T12:00:00Z"
      )

      config = Meringue::Config.load(path: config_path)
      assert_equal "completed", transaction.fetch("onboarding_outcome")
      assert_equal Meringue::Config::ONBOARDING_VERSION, config.onboarding_version
      assert_equal "2026-08-16T12:00:00Z", config.value("onboarding", "completed_at")
      assert_equal "openai/gpt-5.6-sol", config.setting("agent.model", env: {})
      assert_equal "openai/gpt-5.6-sol", config.setting("agent.head_model", env: {})
      assert_equal "openai/gpt-5.6-sol", config.setting("agent.worker_model", env: {})
      assert_equal "high", config.setting("agent.thinking", env: {})
      assert_equal true, config.value("experiments", "github_support")
    end
  end

  def test_failed_setup_publish_writes_neither_marker_nor_draft
    with_paths do |config_path, _state_path|
      File.write(config_path, "[tui]\ncolorscheme = \"meringue\"\n")
      before = File.binread(config_path)
      store = FailingPublishStore.new(path: config_path)

      assert_raises(Meringue::Config::PersistenceError) do
        store.save(
          base_fingerprint: store.fingerprint,
          changes: { "appearance.theme" => "gruvbox" },
          onboarding_outcome: "completed"
        )
      end
      assert_equal before, File.binread(config_path)
      assert_equal 0, Meringue::Config.load(path: config_path).onboarding_version
    end
  end

  def test_cross_field_validation_rejects_blacklist_for_non_pi_workers
    with_paths do |config_path, _state_path|
      store = Meringue::Config::Store.new(path: config_path)
      error = assert_raises(Meringue::Config::ValidationError) do
        store.save(
          base_fingerprint: store.fingerprint,
          changes: {
            "agent.worker_harness" => "claude",
            "safety.worker_blacklist" => ["*gh api*"]
          }
        )
      end
      assert_includes error.field_errors.fetch("safety.worker_blacklist"), "pi"
      refute File.exist?(config_path)
    end
  end

  def test_runtime_override_provenance_is_not_mistaken_for_file_data
    config = Meringue::Config.new(
      { "harness" => { "provider" => "pi" } },
      path: "/tmp/config.toml",
      file_data: { "harness" => { "provider" => "pi" } }
    ).with_overrides({ "harness" => { "head_provider" => "claude" } }, source: "cli")

    assert_equal "claude", config.setting("agent.head_harness", env: {})
    assert_equal "cli", config.setting_source("agent.head_harness", env: {})
    assert_nil config.to_file_h.dig("harness", "head_provider")
  end

  def test_migration_enables_existing_installations_and_disables_new_ones
    with_paths do |config_path, state_path|
      new_config = Meringue::Config.migrate_settings!(path: config_path, state_path: state_path)
      assert_equal false, new_config.value("experiments", "github_support")

      old_config_path = File.join(File.dirname(config_path), "old.toml")
      old_state_path = File.join(File.dirname(config_path), "old-state.json")
      File.write(old_state_path, JSON.generate(Meringue::State::Models.empty_state))
      old_config = Meringue::Config.migrate_settings!(path: old_config_path, state_path: old_state_path)
      assert_equal true, old_config.value("experiments", "github_support")
    end
  end

  private

  def empty_config
    Meringue::Config.new({}, path: "/tmp/config.toml", file_data: {})
  end

  def with_paths
    Dir.mktmpdir("meringue-settings-schema") do |dir|
      yield File.join(dir, "config.toml"), File.join(dir, "state.json")
    end
  end
end
