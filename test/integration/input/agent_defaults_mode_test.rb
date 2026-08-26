# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The three arrangements of model and reasoning defaults, which used to be two
# independent booleans. The bug this consolidation fixes: with role-specific
# settings turned off, `/model head <id>` wrote a head key that the shared-mode
# reader ignored, so Meringue reported the unchanged shared value back as though
# it had saved the requested one.
class InputAgentDefaultsModeTest < Minitest::Test
  Mode = Meringue::Experiments::AgentDefaultsMode

  def with_config(body)
    Dir.mktmpdir("meringue-agent-defaults-mode") do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, body)
      yield path
    end
  end

  def defaults_for(path)
    config = Meringue::Config.load(path: path)
    Meringue::Harness::Registry.new(config: config).session_defaults(provider: "pi")
  end

  def config_body(mode)
    <<~TOML
      [settings]
      schema_version = 2
      [experiments]
      agent_defaults_mode = "#{mode}"

      [harness]
      provider = "pi"
      head_model = "openai/gpt-5.6-sol"
      worker_model = "openai/gpt-5.6-sol"
      head_thinking_level = "high"
      worker_thinking_level = "high"
    TOML
  end

  def test_shared_mode_applies_a_role_named_write_to_both_roles
    with_config(config_body(Mode::SHARED)) do |path|
      Meringue::Config.save_agent_session_defaults!(
        model: "openai/gpt-5.6-luna", model_role: "head", provider: "pi", path: path
      )
      defaults = defaults_for(path)

      assert_equal "openai/gpt-5.6-luna", defaults.dig("roles", "head", "model")
      assert_equal "openai/gpt-5.6-luna", defaults.dig("roles", "worker", "model")
      # Both roles agree, so the shared summary is the value that was requested
      # rather than the one it replaced.
      assert_equal "openai/gpt-5.6-luna", defaults.fetch("model")
      assert_equal "consistent", defaults.fetch("consistency")
    end
  end

  def test_shared_mode_applies_a_role_named_thinking_write_to_both_roles
    with_config(config_body(Mode::SHARED)) do |path|
      Meringue::Config.save_agent_session_defaults!(
        thinking_level: "xhigh", thinking_role: "worker", provider: "pi", path: path
      )
      defaults = defaults_for(path)

      assert_equal "xhigh", defaults.dig("roles", "head", "thinking_level")
      assert_equal "xhigh", defaults.dig("roles", "worker", "thinking_level")
      assert_equal "xhigh", defaults.fetch("thinking_level")
    end
  end

  def test_role_specific_and_guided_modes_keep_the_roles_independent
    [Mode::ROLE_SPECIFIC, Mode::GUIDED].each do |mode|
      with_config(config_body(mode)) do |path|
        Meringue::Config.save_agent_session_defaults!(
          model: "openai/gpt-5.6-luna", model_role: "head", provider: "pi", path: path
        )
        defaults = defaults_for(path)

        assert_equal "openai/gpt-5.6-luna", defaults.dig("roles", "head", "model"), mode
        assert_equal "openai/gpt-5.6-sol", defaults.dig("roles", "worker", "model"), mode
        assert_nil defaults.fetch("model"), mode
        assert_equal "mixed", defaults.fetch("consistency"), mode
      end
    end
  end

  def test_mode_drives_role_specific_and_guided_predicates
    {
      Mode::SHARED => [false, false],
      Mode::ROLE_SPECIFIC => [true, false],
      Mode::GUIDED => [true, true]
    }.each do |mode, (role_specific, guided)|
      with_config(config_body(mode)) do |path|
        config = Meringue::Config.load(path: path)

        assert_equal mode, config.agent_defaults_mode
        assert_equal role_specific, config.role_specific_agent_defaults?, mode
        # Guided assigns a model per worker, so it needs role-specific values too.
        assert_equal guided, config.worker_spawning_guidance?, mode
      end
    end
  end

  def test_retired_booleans_still_decide_the_mode_before_migration
    {
      "split_defaults = false" => Mode::SHARED,
      "split_defaults = true" => Mode::ROLE_SPECIFIC,
      "worker_spawning_guidance = true" => Mode::GUIDED,
      # Guidance was the narrower opt-in, so it wins over a stale split flag.
      "split_defaults = false\nworker_spawning_guidance = true" => Mode::GUIDED
    }.each do |legacy, expected|
      with_config("[experiments]\n#{legacy}\n") do |path|
        assert_equal expected, Meringue::Config.load(path: path).agent_defaults_mode, legacy
      end
    end
  end

  def test_an_installation_with_no_experiments_is_role_specific
    with_config("") do |path|
      assert_equal Mode::ROLE_SPECIFIC, Meringue::Config.load(path: path).agent_defaults_mode
    end
  end

  def test_migration_records_the_mode_and_leaves_an_explicit_mode_alone
    with_config("[experiments]\nworker_spawning_guidance = true\n") do |path|
      Meringue::Config.migrate_settings!(path: path)

      assert_equal Mode::GUIDED, Meringue::Config.load(path: path).value("experiments", "agent_defaults_mode")
    end

    with_config(config_body(Mode::SHARED) + "\n[experiments]\nsplit_defaults = true\n") do |path|
      Meringue::Config.migrate_settings!(path: path)

      assert_equal Mode::SHARED, Meringue::Config.load(path: path).agent_defaults_mode
    end
  end

  def test_the_mode_is_one_experiment_and_the_retired_pair_is_gone
    ids = Meringue::Experiments::Registry.ids

    assert_includes ids, "agent_defaults_mode"
    refute_includes ids, "split_defaults"
    refute_includes ids, "worker_spawning_guidance"

    definition = Meringue::Experiments::Registry.fetch("agent_defaults_mode")

    assert_predicate definition, :mode?
    assert_equal [Mode::SHARED, Mode::ROLE_SPECIFIC, Mode::GUIDED], definition.modes
    assert_equal ["Shared", "By role", "Guided"], definition.modes.map { |mode| definition.mode_label(mode) }
  end

  def test_the_mode_setting_is_a_selector_over_its_three_modes
    setting = Meringue::Config::Schema.fetch("experiments.agent_defaults_mode")

    assert_equal "enum", setting.type
    assert_equal "selector", setting.editor
    assert_equal Mode::MODES, setting.option_values
    assert_equal "By role", setting.option_label(Mode::ROLE_SPECIFIC)
    # A mode experiment is not on/off, and asking that way is a mistake rather
    # than a silently wrong answer.
    assert_raises(ArgumentError) do
      Meringue::Config.new({}, path: "/tmp/unused.toml").experiment_enabled?("agent_defaults_mode")
    end
  end

  def test_an_unknown_stored_mode_falls_back_to_the_default
    with_config("[experiments]\nagent_defaults_mode = \"nonsense\"\n") do |path|
      config = Meringue::Config.load(path: path)

      assert_equal Mode::ROLE_SPECIFIC, config.agent_defaults_mode
      assert_equal Mode::ROLE_SPECIFIC, config.experiment_mode("agent_defaults_mode")
    end
  end

  def test_the_underscored_spelling_is_accepted
    with_config("[experiments]\nagent_defaults_mode = \"role_specific\"\n") do |path|
      assert_equal Mode::ROLE_SPECIFIC, Meringue::Config.load(path: path).agent_defaults_mode
    end
  end
end
