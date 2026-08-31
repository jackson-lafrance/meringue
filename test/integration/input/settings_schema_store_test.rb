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

  def test_preferred_editor_has_curated_presets_and_is_on_first_setup_page
    definition = Meringue::Config::Schema.fetch("workspace.editor")

    assert_equal %w[vim nvim emacs cursor code], definition.option_values(empty_config)
    refute definition.option_values(empty_config).any? { |command| command.include?("--wait") }
    assert_equal "editor_command", definition.editor
    assert definition.advanced, "the full Settings page keeps editor details advanced"
    assert_includes Meringue::TUI::Settings::SetupFlow.setting_ids(Meringue::TUI::Settings::SetupFlow::HARNESS), "workspace.editor"
  end

  def test_preferred_editor_defaults_to_visual_then_editor_and_preserves_argv
    definition = Meringue::Config::Schema.fetch("workspace.editor")

    assert_equal ["nvim", "--wait"], definition.default_value(empty_config, env: { "VISUAL" => "nvim --wait", "EDITOR" => "vi" })
    assert_equal ["emacs"], definition.default_value(empty_config, env: { "EDITOR" => "emacs" })
    assert_equal ["code"], definition.validate_value("code", config: empty_config)
    assert_equal ["emacs"], definition.validate_value("emacs", config: empty_config)
    assert_equal ["code", "--wait"], definition.validate_value("code --wait", config: empty_config)
  end

  # Enum normalization used to rewrite every underscore to a hyphen, which meant an
  # option id that contains one could be read out of the file but never written back:
  # picking "github_git" in Settings produced "github-git", which its own option list
  # rejected. Switching the backend away from Git was therefore a one-way door.
  def test_enum_options_containing_an_underscore_round_trip_through_validation
    config = empty_config

    %w[version_control.backend workspace.worktree_provider workspace.worktree_provider_fallback].each do |id|
      definition = Meringue::Config::Schema.fetch(id)
      definition.option_values(config).each do |option|
        assert_equal option, definition.validate_value(option, config: config), "#{id} must accept its own option #{option}"
      end
    end
  end

  def test_enum_values_are_matched_case_and_separator_insensitively
    config = empty_config

    assert_equal "github_git", Meringue::Config::Schema.fetch("version_control.backend").validate_value("GitHub-Git", config: config)
    assert_equal "rose-pine", Meringue::Config::Schema.fetch("appearance.theme").validate_value("rose_pine", config: config)
    assert_equal "role-specific", Meringue::Config::Schema.fetch("experiments.agent_defaults_mode").validate_value("role_specific", config: config)

    error = assert_raises(ArgumentError) do
      Meringue::Config::Schema.fetch("version_control.backend").validate_value("mercurial", config: config)
    end
    assert_includes error.message, "must be one of: github_git, command"
  end

  def test_removed_harness_is_absent_from_settings_choices_and_validation
    config = empty_config
    definitions = Meringue::Config::Schema.definitions

    assert_equal %w[pi claude codex], Meringue::Config::Schema.fetch("agent.head_harness").option_values(config)
    assert_equal %w[pi claude codex], Meringue::Config::Schema.fetch("agent.worker_harness").option_values(config)
    refute definitions.any? { |definition| definition.id.start_with?("harnesses.antigravity.") }

    error = assert_raises(Meringue::Config::ValidationError) do
      Meringue::Config::Schema.validate_changes({ "agent.head_harness" => "antigravity" }, config: config)
    end
    assert_includes error.field_errors.fetch("agent.head_harness"), "pi, claude, codex"
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

  # A key the schema does not know about belongs to whoever wrote it, so a transaction
  # that rewrites one section must carry the rest of the file across untouched.
  def test_transaction_preserves_unknown_keys
    with_paths do |config_path, _state_path|
      File.write(config_path, <<~TOML)
        custom = "keep me"
        [plugin.future]
        enabled = true
        [harness.pi]
        command = "pi"
      TOML
      store = Meringue::Config::Store.new(path: config_path)
      store.save(
        base_fingerprint: store.fingerprint,
        changes: {
          "agent.head_model" => "openai/gpt-5.6-sol",
          "agent.worker_model" => "anthropic/claude-opus-5"
        }
      )

      config = Meringue::Config.load(path: config_path)
      assert_equal "keep me", config.value("custom")
      assert_equal true, config.value("plugin", "future", "enabled")
      assert_equal "pi", config.value("harness", "pi", "command")
      assert_equal "openai/gpt-5.6-sol", config.value("harness", "head_model")
      assert_equal "anthropic/claude-opus-5", config.value("harness", "worker_model")
    end
  end

  # Roles are stored independently even when they agree. There is no shared key that a
  # matching pair collapses into any more, and no provider-scoped one either: writing
  # both spellings is what let a role-named save report back the value it had replaced.
  def test_role_values_are_stored_per_role_even_when_they_match
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

      assert_equal "claude", config.value("harness", "head_provider")
      assert_equal "claude", config.value("harness", "worker_provider")
      assert_equal "high", config.value("harness", "head_thinking_level")
      assert_equal "high", config.value("harness", "worker_thinking_level")
      assert_nil config.value("harness", "provider")
      assert_equal({}, config.section("harness", "pi"))
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
          "agent.head_model" => "openai/gpt-5.6-sol",
          "agent.worker_model" => "anthropic/claude-opus-5",
          "experiments.github_support" => true
        },
        onboarding_outcome: "completed",
        completed_at: "2026-08-16T12:00:00Z"
      )

      config = Meringue::Config.load(path: config_path)
      assert_equal "completed", transaction.fetch("onboarding_outcome")
      assert_equal Meringue::Config::ONBOARDING_VERSION, config.onboarding_version
      assert_equal "2026-08-16T12:00:00Z", config.value("onboarding", "completed_at")
      assert_equal "openai/gpt-5.6-sol", config.setting("agent.head_model", env: {})
      assert_equal "anthropic/claude-opus-5", config.setting("agent.worker_model", env: {})
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

  def test_setup_moves_untouched_model_defaults_with_the_selected_harness
    config = Meringue::Config.new({}, path: "/tmp/settings-codex.toml", file_data: {})
    draft = Meringue::TUI::Settings::Draft.new(config, env: {})

    assert_equal Meringue::Harness::Registry::DEFAULT_MODEL, draft.value("agent.head_model")
    draft.set("agent.head_harness", "codex")
    assert_equal "openai/gpt-5.6-sol", draft.value("agent.head_model")

    draft.set("agent.head_harness", "claude")
    assert_equal Meringue::Harness::Registry::DEFAULT_MODEL, draft.value("agent.head_model")

    draft.set("agent.head_model", "openai/custom-model")
    draft.set("agent.head_harness", "codex")
    assert_equal "openai/custom-model", draft.value("agent.head_model"), "an explicit model choice must survive a harness switch"

    configured = Meringue::Config.new(
      { "harness" => { "head_provider" => "codex" } },
      path: "/tmp/settings-codex-existing.toml",
      file_data: { "harness" => { "head_provider" => "codex" } }
    )
    assert_equal "openai/gpt-5.6-sol", configured.setting("agent.head_model", env: {})
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

  # Setup and startup have to agree on one schema. Config.reject_obsolete_settings!
  # refuses to load a file containing any of these paths, so if a writer can still
  # target one, setup writes configuration that startup then calls obsolete. A dead
  # canonicalizer used to write harness.provider, harness.model, harness.pi.model,
  # and both thinking_level paths for exactly that reason.
  OBSOLETE_WRITE_TARGETS = [
    %w[harness provider], %w[harness model], %w[harness thinking_level],
    %w[harness pi model], %w[harness pi thinking_level], %w[harness pi head_model],
    %w[harness pi worker_model], %w[harness pi head_thinking_level],
    %w[harness pi worker_thinking_level], %w[tui color_scheme]
  ].freeze

  def test_no_schema_owned_write_target_is_a_path_startup_rejects
    owned = Meringue::Config::Schema.definitions.flat_map do |definition|
      [definition.path, *definition.aliases]
    end.compact

    OBSOLETE_WRITE_TARGETS.each do |path|
      refute_includes owned, path,
                      "#{path.join(".")} is rejected at startup but is still a schema-owned write target"
    end
  end

  # The guard above only covers paths the schema names. This one covers the writers
  # themselves: whatever the store persists for every editable setting must survive a
  # real load, so no writer can reintroduce a file startup refuses to open.
  def test_every_editable_setting_the_store_writes_still_loads_at_startup
    with_paths do |config_path, _state_path|
      store = Meringue::Config::Store.new(path: config_path)
      Meringue::Config::Schema.definitions.each do |definition|
        next if definition.path.nil? || definition.type == "action"
        next if %w[internal read_only].include?(definition.visibility)

        config = Meringue::Config.load(path: config_path)
        value = Meringue::Config::Schema.fetch(definition.id).effective_value(config, env: {})
        next if value.nil?

        begin
          store.save(base_fingerprint: store.fingerprint, changes: { definition.id => value })
        rescue Meringue::Config::Store::ValidationError
          next
        end
      end

      # Raises ParseError if any write above landed on an obsolete path.
      Meringue::Config.load(path: config_path)

      Meringue::Config.reject_obsolete_settings!(
        Meringue::Config.load(path: config_path).to_file_h, path: config_path
      )
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
