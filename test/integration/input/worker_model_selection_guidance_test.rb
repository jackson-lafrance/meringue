# frozen_string_literal: true

require "test_helper"
require "support/input_support"
require "tmpdir"

class WorkerModelSelectionGuidanceTest < Minitest::Test
  include InputSupport

  def test_guide_command_persists_the_additional_prompt_payload
    command = slash_parser.parse('/worker guide "Implementation uses @openai/gpt-5.6-luna #xhigh"').to_h

    assert_equal "SetWorkerSelectionGuidance", command.fetch("type")
    assert_equal "Implementation uses @openai/gpt-5.6-luna #xhigh", command.fetch("payload").fetch("prompt")
  end

  def test_inline_model_and_thinking_completion_use_catalog_and_ladder
    state = sample_state_with_model_catalog(
      catalogs: {
        "pi" => model_catalog_snapshot(
          models: [
            { "provider" => "openai", "id" => "gpt-5.6-luna", "name" => "GPT-5.6 Luna", "thinking_levels" => %w[high xhigh] },
            { "provider" => "openai", "id" => "gpt-5.6-sol", "name" => "GPT-5.6 Sol", "thinking_levels" => %w[medium high] }
          ]
        )
      }
    )

    models = Meringue::Input::SlashCommandParser.command_suggestion_records(
      "For implementation use @luna", limit: nil, state: state
    )
    levels = Meringue::Input::SlashCommandParser.command_suggestion_records(
      "For implementation use #xh", limit: nil, state: state
    )

    assert_equal ["openai/gpt-5.6-luna"], models.map { |record| record.fetch("usage") }
    assert_equal ["For implementation use #xhigh"], levels.map { |record| record.fetch("completion") }
    assert_equal "For implementation use @openai/gpt-5.6-luna", models.first.fetch("completion")
  end

  def test_prompt_row_is_hidden_when_toggle_is_disabled_and_visible_when_enabled
    Dir.mktmpdir("meringue-guidance-settings") do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, <<~TOML)
        [settings]
        schema_version = 1
        [experiments]
        worker_spawning_guidance = false
        worker_spawning_guidance_prompt = "saved custom prompt"
      TOML
      config = Meringue::Config.load(path: path)
      draft = Meringue::TUI::Settings::Draft.new(config, env: {})

      refute_includes draft.definitions_for("Experiments").map(&:id), "experiments.worker_spawning_guidance_prompt"
      draft.set("experiments.worker_spawning_guidance", true)
      assert_includes draft.definitions_for("Experiments").map(&:id), "experiments.worker_spawning_guidance_prompt"
      assert_equal "saved custom prompt", draft.value("experiments.worker_spawning_guidance_prompt")
      assert_includes Meringue::TUI::Settings::SetupFlow.setting_ids("Experiments", draft: draft),
                      "experiments.worker_spawning_guidance_prompt"
    end
  end

  def test_enabled_command_writes_the_same_schema_setting_and_disabled_command_is_rejected
    Dir.mktmpdir("meringue-guidance-command") do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, <<~TOML)
        [settings]
        schema_version = 1
        [experiments]
        worker_spawning_guidance = true
      TOML
      store = Meringue::State::Store.new(path: File.join(dir, "state.json"))
      store.save(Meringue::State::Models.empty_state)
      engine = Meringue::Kernel::Engine.new(
        store: store,
        config: Meringue::Config.load(path: path),
        config_path: path
      )

      result = engine.apply(
        "command_id" => "guidance-1",
        "type" => "SetWorkerSelectionGuidance",
        "payload" => { "prompt" => "Use @openai/gpt-5.6-sol for investigation #medium" }
      )

      assert_equal "accepted", result.fetch("status"), result.inspect
      assert_equal "Use @openai/gpt-5.6-sol for investigation #medium",
                   Meringue::Config.load(path: path).setting("experiments.worker_spawning_guidance_prompt")

      disabled_path = File.join(dir, "disabled.toml")
      File.write(disabled_path, <<~TOML)
        [settings]
        schema_version = 1
        [experiments]
        worker_spawning_guidance = false
      TOML
      disabled_engine = Meringue::Kernel::Engine.new(
        store: store,
        config: Meringue::Config.load(path: disabled_path),
        config_path: disabled_path
      )
      rejected = disabled_engine.apply(
        "command_id" => "guidance-2",
        "type" => "SetWorkerSelectionGuidance",
        "payload" => { "prompt" => "hidden" }
      )

      assert_equal "rejected", rejected.fetch("status")
      assert_includes rejected.fetch("errors"), "worker_spawning_guidance_disabled"
    end
  end

  def test_default_prompt_stays_limited_to_model_and_thinking_selection
    prompt = Meringue::Experiments::WorkerSpawningGuidance.default_text

    assert_includes prompt, "@openai/gpt-5.6-luna"
    assert_includes prompt, "#xhigh"
    refute_match(/prefer (?:a )?(?:fresh|existing) worker/i, prompt)
    refute_match(/reuse (?:a )?worker/i, prompt)
  end

  def test_head_context_delivers_the_saved_prompt_only_when_enabled
    snapshot = Meringue::State::Models.empty_state
    prompt = "Use @openai/gpt-5.6-luna #xhigh for implementation."
    enabled = Meringue::Heads::Context.new(
      head_id: "H1", user_message: "route", snapshot: snapshot,
      worker_spawning_guidance: true, worker_spawning_guidance_prompt: prompt
    )
    disabled = Meringue::Heads::Context.new(
      head_id: "H2", user_message: "route", snapshot: snapshot,
      worker_spawning_guidance: false, worker_spawning_guidance_prompt: prompt
    )

    assert_equal prompt, enabled.to_prompt_h.fetch("additional_system_prompt")
    assert_includes enabled.system_prompt, prompt
    refute disabled.to_prompt_h.key?("additional_system_prompt")
    refute_includes disabled.system_prompt, prompt
  end

  private

  def slash_parser
    @slash_parser ||= Meringue::Input::SlashCommandParser.new
  end
end
