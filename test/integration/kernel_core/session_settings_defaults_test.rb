# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# Covers the kernel contract between persistent future-session defaults and one
# existing session's effective values. The Pi RPC protocol itself is exercised
# in harness/pi_client_protocol_test.rb; this client keeps this slice hermetic.
class KernelCoreSessionSettingsDefaultsTest < Minitest::Test
  include KernelCoreSupport

  class SettingsClient < Meringue::Harness::FakeClient
    attr_reader :spawn_defaults

    def initialize
      @spawn_defaults = {
        "model" => "anthropic/claude-opus-5",
        "thinking_level" => "max"
      }
      @session_counter = 0
    end

    def harness_name
      "pi"
    end

    def configure_defaults(model: nil, thinking_level: nil)
      @spawn_defaults["model"] = model if model
      @spawn_defaults["thinking_level"] = thinking_level if thinking_level
    end

    def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
      @session_counter += 1
      super.merge(
        "harness" => "pi",
        "session_id" => "pi-settings-#{@session_counter}",
        "session_settings" => settings(spawn_defaults.fetch("model"), spawn_defaults.fetch("thinking_level"))
      )
    end

    def session_settings_supported?
      true
    end

    def get_session_settings(session_ref)
      {
        "session_ref" => session_ref,
        "settings" => session_ref.fetch("session_settings")
      }
    end

    def set_session_model(session_ref, model)
      updated_settings = settings(model, session_ref.dig("session_settings", "thinking_level"))
      updated_ref = session_ref.merge("session_settings" => updated_settings)
      { "session_ref" => updated_ref, "settings" => updated_settings }
    end

    def set_session_thinking_level(session_ref, level)
      updated_settings = settings(session_ref.dig("session_settings", "model", "reference"), level)
      updated_ref = session_ref.merge("session_settings" => updated_settings)
      { "session_ref" => updated_ref, "settings" => updated_settings }
    end

    private

    def settings(model, thinking_level)
      provider, model_id = model.split("/", 2)
      {
        "model" => { "provider" => provider, "id" => model_id, "reference" => model },
        "thinking_level" => thinking_level,
        "availability" => "available",
        "source" => "test_pi_session"
      }
    end
  end

  class DefaultsCoordinator
    attr_reader :calls

    def initialize(client, config_path)
      @client = client
      @config_path = config_path
      @calls = []
    end

    def defaults(_provider)
      model = @client.spawn_defaults.fetch("model")
      thinking = @client.spawn_defaults.fetch("thinking_level")
      {
        "harness" => "pi",
        "model" => model,
        "thinking_level" => thinking,
        "consistency" => "consistent",
        "roles" => {
          "head" => { "model" => model, "thinking_level" => thinking },
          "worker" => { "model" => model, "thinking_level" => thinking }
        },
        "scope" => "future_pi_sessions"
      }
    end

    def update(provider, model: nil, thinking_level: nil)
      @calls << { "provider" => provider, "model" => model, "thinking_level" => thinking_level }
      Meringue::Config.save_pi_session_defaults!(
        model: model,
        thinking_level: thinking_level,
        path: @config_path
      )
      @client.configure_defaults(model: model, thinking_level: thinking_level)
      defaults(provider)
    end
  end

  def setup
    super
    @settings_client = SettingsClient.new
    @coordinator = DefaultsCoordinator.new(@settings_client, File.join(tmp_root, "config.toml"))
    @engine = build_engine(
      harness_client: @settings_client,
      harness_client_provider: ->(_provider) { @settings_client },
      harness_client_resolver: ->(_agent) { @settings_client },
      default_harness_provider: "pi",
      session_defaults_provider: ->(provider) { @coordinator.defaults(provider) },
      session_defaults_updater: lambda do |provider, model: nil, thinking_level: nil|
        @coordinator.update(provider, model: model, thinking_level: thinking_level)
      end
    )
  end

  def test_global_commands_persist_future_defaults_without_mutating_existing_sessions
    add_project!(name: "defaults")
    create_issue!("P1", title: "Exercise defaults")
    spawn_worker!("P1-I1", workspace_path: make_project_dir("worker-one"))
    first_before = persisted_agents.fetch(0).fetch("session_settings")

    model_result = apply_command("SetDefaultSessionModel", "model" => "openai/gpt-5.6-sol")
    thinking_result = apply_command("SetDefaultSessionThinkingLevel", "level" => "xhigh")

    assert_accepted(model_result)
    assert_accepted(thinking_result)
    assert_equal "future_pi_sessions", thinking_result.dig("result", "scope")
    assert_equal ["P1-I1-W1"], model_result.dig("result", "existing_session_ids_unchanged")
    assert_equal first_before, persisted_agents.fetch(0).fetch("session_settings")
    config = Meringue::Config.load(path: File.join(tmp_root, "config.toml"))
    assert_equal "openai/gpt-5.6-sol", config.value("harness", "pi", "model")
    assert_equal "xhigh", config.value("harness", "pi", "thinking_level")

    spawn_worker!("P1-I1", workspace_path: make_project_dir("worker-two"))
    second = persisted_agents.find { |agent| agent.fetch("id") == "P1-I1-W2" }
    assert_equal "openai/gpt-5.6-sol", second.dig("session_settings", "model", "reference")
    assert_equal "xhigh", second.dig("session_settings", "thinking_level")
    assert_includes log_messages.last(4).join("\n"), "Existing Pi sessions were not changed"
  end

  def test_targeted_commands_change_one_existing_session_without_changing_defaults
    add_project!(name: "targeted")
    create_issue!("P1", title: "Exercise targeted settings")
    spawn_worker!("P1-I1", workspace_path: make_project_dir("worker"))

    model_result = apply_command(
      "SetSessionModel",
      "agent_id" => "P1-I1-W1",
      "model" => "openai/gpt-5.6-sol"
    )
    thinking_result = apply_command(
      "SetSessionThinkingLevel",
      "agent_id" => "P1-I1-W1",
      "level" => "xhigh"
    )
    inspection = apply_command("GetSessionSettings", "agent_id" => "P1-I1-W1")

    [model_result, thinking_result, inspection].each { |result| assert_accepted(result) }
    assert_equal "current_session", inspection.dig("result", "scope")
    assert_equal "openai/gpt-5.6-sol", inspection.dig("result", "session_settings", "model", "reference")
    assert_equal "xhigh", inspection.dig("result", "session_settings", "thinking_level")
    assert_empty @coordinator.calls, "targeted updates must not call the persistent default updater"
    assert_equal "anthropic/claude-opus-5", @coordinator.defaults("pi").fetch("model")
    assert_equal "max", @coordinator.defaults("pi").fetch("thinking_level")
    refute File.exist?(File.join(tmp_root, "config.toml"))
  end

  def test_default_commands_validate_values_before_persistence
    bad_models = ["gpt-5.6-sol", "openai/model/extra", "openai/has space"]
    bad_models.each do |model|
      assert_rejected(apply_command("SetDefaultSessionModel", "model" => model), "provider/model")
    end
    assert_rejected(apply_command("SetDefaultSessionThinkingLevel", "level" => "ultra"), "thinking level must be one of")

    assert_empty @coordinator.calls
    refute File.exist?(File.join(tmp_root, "config.toml"))
  end

  def test_get_defaults_reports_both_future_roles_and_logs_scope
    result = apply_command("GetSessionDefaults")

    assert_accepted(result)
    assert_equal "future_pi_sessions", result.dig("result", "scope")
    assert_equal "anthropic/claude-opus-5", result.dig("result", "roles", "head", "model")
    assert_equal "anthropic/claude-opus-5", result.dig("result", "roles", "worker", "model")
    assert_includes result.fetch("message"), "Existing sessions keep their own effective settings"
    assert_equal "info", log_entry(result.fetch("log_entry_ids").first).fetch("level")
  end
end
