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

    def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:, session_settings: {}, workspace_mode: "isolated")
      @session_counter += 1
      model = session_settings.fetch("model", spawn_defaults.fetch("model"))
      thinking = session_settings.fetch("thinking_level", spawn_defaults.fetch("thinking_level"))
      super.merge(
        "harness" => "pi",
        "session_id" => "pi-settings-#{@session_counter}",
        "session_settings" => settings(model, thinking)
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
      default_model = client.spawn_defaults.fetch("model")
      default_thinking = client.spawn_defaults.fetch("thinking_level")
      @role_model = { "head" => default_model, "worker" => default_model }
      @role_thinking = { "head" => default_thinking, "worker" => default_thinking }
    end

    def defaults(_provider)
      model_values = @role_model.values.uniq
      model = model_values.one? ? model_values.first : nil
      thinking_values = @role_thinking.values.uniq
      thinking = thinking_values.one? ? thinking_values.first : nil
      {
        "harness" => "pi",
        "model" => model,
        "thinking_level" => thinking,
        "consistency" => "consistent",
        "roles" => {
          "head" => { "model" => @role_model.fetch("head"), "thinking_level" => @role_thinking.fetch("head") },
          "worker" => { "model" => @role_model.fetch("worker"), "thinking_level" => @role_thinking.fetch("worker") }
        },
        "scope" => "future_pi_sessions"
      }
    end

    def update(provider, model: nil, model_role: nil, thinking_level: nil, thinking_role: nil)
      call = { "provider" => provider, "model" => model, "thinking_level" => thinking_level }
      call["model_role"] = model_role if model_role
      call["thinking_role"] = thinking_role if thinking_role
      @calls << call
      Meringue::Config.save_agent_session_defaults!(
        model: model,
        model_role: model_role,
        thinking_level: thinking_level,
        thinking_role: thinking_role,
        path: @config_path
      )
      if model
        if model_role
          @role_model[model_role] = model
        else
          @role_model.transform_values! { model }
        end
      end
      if thinking_level
        if thinking_role
          @role_thinking[thinking_role] = thinking_level
        else
          @role_thinking.transform_values! { thinking_level }
        end
      end
      @client.configure_defaults(model: model, thinking_level: thinking_level) if (model || thinking_level) && (model_role.nil? || model_role == "worker") && (thinking_role.nil? || thinking_role == "worker")
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
      session_defaults_updater: lambda do |provider, model: nil, model_role: nil, thinking_level: nil, thinking_role: nil|
        @coordinator.update(provider, model: model, model_role: model_role, thinking_level: thinking_level, thinking_role: thinking_role)
      end
    )
  end

  def test_global_commands_persist_future_defaults_without_mutating_existing_sessions
    add_project!(name: "defaults")
    create_issue!("P1", title: "Exercise defaults")
    spawn_worker!("P1-I1")
    first_before = persisted_agents.fetch(0).fetch("session_settings")

    model_result = apply_command("SetDefaultSessionModel", "model" => "openai/gpt-5.6-sol")
    thinking_result = apply_command("SetDefaultSessionThinkingLevel", "level" => "xhigh")

    assert_accepted(model_result)
    assert_accepted(thinking_result)
    assert_equal "future_pi_sessions", thinking_result.dig("result", "scope")
    assert_equal ["P1-I1-W1"], model_result.dig("result", "existing_session_ids_unchanged")
    assert_includes model_result.fetch("message"), "Existing sessions were not changed."
    refute_includes model_result.fetch("message"), "Existing sessions were not changed:"
    assert_equal ["P1-I1-W1"], thinking_result.dig("result", "existing_session_ids_unchanged")
    assert_includes thinking_result.fetch("message"), "Existing sessions were not changed."
    refute_includes thinking_result.fetch("message"), "Existing sessions were not changed:"
    assert_equal first_before, persisted_agents.fetch(0).fetch("session_settings")
    config = Meringue::Config.load(path: File.join(tmp_root, "config.toml"))
    assert_equal "openai/gpt-5.6-sol", config.value("harness", "head_model")
    assert_equal "openai/gpt-5.6-sol", config.value("harness", "worker_model")
    assert_equal "xhigh", config.value("harness", "head_thinking_level")
    assert_equal "xhigh", config.value("harness", "worker_thinking_level")

    spawn_worker!("P1-I1")
    second = persisted_agents.find { |agent| agent.fetch("id") == "P1-I1-W2" }
    assert_equal "openai/gpt-5.6-sol", second.dig("session_settings", "model", "reference")
    assert_equal "xhigh", second.dig("session_settings", "thinking_level")
    assert_includes log_messages.last(4).join("\n"), "Existing sessions were not changed."
    refute_includes log_messages.last(4).join("\n"), "Existing sessions were not changed:"
  end

  def test_role_specific_commands_persist_independent_defaults_and_scope_their_results
    head_result = apply_command("SetDefaultSessionThinkingLevel", "role" => "head", "level" => "low")
    worker_result = apply_command("SetDefaultSessionThinkingLevel", "role" => "worker", "level" => "xhigh")

    assert_accepted(head_result)
    assert_accepted(worker_result)
    assert_equal "future_pi_head_sessions", head_result.dig("result", "scope")
    assert_equal "future_pi_worker_sessions", worker_result.dig("result", "scope")
    assert_match(/for future heads\. Existing sessions were not changed\./, head_result.fetch("message"))
    assert_match(/for future workers\. Existing sessions were not changed\./, worker_result.fetch("message"))
    assert_equal "low", worker_result.dig("result", "roles", "head", "thinking_level")
    assert_equal "xhigh", worker_result.dig("result", "roles", "worker", "thinking_level")

    config = Meringue::Config.load(path: File.join(tmp_root, "config.toml"))
    assert_equal "low", config.value("harness", "head_thinking_level")
    assert_equal "xhigh", config.value("harness", "worker_thinking_level")
  end

  def test_shared_thinking_command_resets_role_specific_overrides
    apply_command("SetDefaultSessionThinkingLevel", "role" => "head", "level" => "low")
    apply_command("SetDefaultSessionThinkingLevel", "role" => "worker", "level" => "xhigh")

    result = apply_command("SetDefaultSessionThinkingLevel", "level" => "high")

    assert_accepted(result)
    assert_equal "high", result.dig("result", "thinking_level")
    assert_equal "high", result.dig("result", "roles", "head", "thinking_level")
    assert_equal "high", result.dig("result", "roles", "worker", "thinking_level")
    config = Meringue::Config.load(path: File.join(tmp_root, "config.toml"))
    assert_equal "high", config.value("harness", "head_thinking_level")
    assert_equal "high", config.value("harness", "worker_thinking_level")
  end

  def test_role_specific_model_commands_persist_independent_defaults_and_scope_their_results
    head_result = apply_command("SetDefaultSessionModel", "role" => "head", "model" => "openai/gpt-5.6-sol")
    worker_result = apply_command("SetDefaultSessionModel", "role" => "worker", "model" => "anthropic/claude-opus-5")

    assert_accepted(head_result)
    assert_accepted(worker_result)
    assert_equal "future_pi_head_sessions", head_result.dig("result", "scope")
    assert_equal "future_pi_worker_sessions", worker_result.dig("result", "scope")
    assert_equal "openai/gpt-5.6-sol", worker_result.dig("result", "roles", "head", "model")
    assert_equal "anthropic/claude-opus-5", worker_result.dig("result", "roles", "worker", "model")
    assert_match(/for future heads\. Existing sessions were not changed\./, head_result.fetch("message"))
    assert_match(/for future workers\. Existing sessions were not changed\./, worker_result.fetch("message"))

    config = Meringue::Config.load(path: File.join(tmp_root, "config.toml"))
    assert_equal "openai/gpt-5.6-sol", config.value("harness", "head_model")
    assert_equal "anthropic/claude-opus-5", config.value("harness", "worker_model")
  end

  def test_shared_model_command_resets_role_specific_overrides
    apply_command("SetDefaultSessionModel", "role" => "head", "model" => "openai/gpt-5.6-sol")
    apply_command("SetDefaultSessionModel", "role" => "worker", "model" => "anthropic/claude-opus-5")

    result = apply_command("SetDefaultSessionModel", "model" => "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast")

    assert_accepted(result)
    assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", result.dig("result", "model")
    assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", result.dig("result", "roles", "head", "model")
    assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", result.dig("result", "roles", "worker", "model")
    assert_match(/for all future heads and workers\./, result.fetch("message"))
    config = Meringue::Config.load(path: File.join(tmp_root, "config.toml"))
    assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", config.value("harness", "head_model")
    assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", config.value("harness", "worker_model")
  end

  def test_role_specific_model_command_rejects_an_invalid_role
    result = apply_command("SetDefaultSessionModel", "role" => "reviewer", "model" => "openai/gpt-5.6-sol")

    assert_equal "rejected", result.fetch("status")
    assert_match(/role must be head or worker/, result.fetch("message"))
  end

  def test_role_specific_model_command_rejects_an_invalid_model_reference
    result = apply_command("SetDefaultSessionModel", "role" => "head", "model" => "not-a-model")

    assert_equal "rejected", result.fetch("status")
    assert_match(/Default model was not changed/, result.fetch("message"))
  end

  def test_spawn_worker_partial_override_uses_other_default_and_does_not_change_future_defaults
    add_project!(name: "per-worker")
    create_issue!("P1", title: "Exercise per-worker settings")
    result = apply_command(
      "SpawnWorker",
      "issue_id" => "P1-I1",
      "prompt" => "Do the work",
      "model" => "openai/gpt-5.6-sol"
    )
    assert_accepted(result)
    worker = persisted_agents.fetch(0)

    assert_equal "openai/gpt-5.6-sol", worker.dig("session_settings", "model", "reference")
    assert_equal "max", worker.dig("session_settings", "thinking_level")
    assert_equal "anthropic/claude-opus-5", @coordinator.defaults("pi").fetch("model")
    assert_empty @coordinator.calls
  end

  def test_targeted_commands_change_one_existing_session_without_changing_defaults
    add_project!(name: "targeted")
    create_issue!("P1", title: "Exercise targeted settings")
    spawn_worker!("P1-I1")

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

    [model_result, thinking_result].each { |result| assert_accepted(result) }
    assert_equal "current_session", thinking_result.dig("result", "scope")
    assert_equal "openai/gpt-5.6-sol", thinking_result.dig("result", "session_settings", "model", "reference")
    assert_equal "xhigh", thinking_result.dig("result", "session_settings", "thinking_level")
    assert_empty @coordinator.calls, "targeted updates must not call the persistent default updater"
    assert_equal "anthropic/claude-opus-5", @coordinator.defaults("pi").fetch("model")
    assert_equal "max", @coordinator.defaults("pi").fetch("thinking_level")
    refute File.exist?(File.join(tmp_root, "config.toml"))
  end

  # `/model` and `/thinking` are typed with the agent id in whatever case the user used. The id
  # resolves; the model reference stays byte-exact.
  def test_targeted_session_commands_accept_lowercase_and_mixed_case_agent_ids
    add_project!(name: "targeted")
    create_issue!("P1", title: "Exercise targeted settings")
    spawn_worker!("P1-I1")

    model_result = apply_command("SetSessionModel", "agent_id" => "p1-i1-w1", "model" => "openai/gpt-5.6-sol")
    thinking_result = apply_command("SetSessionThinkingLevel", "agent_id" => "P1-i1-W1", "level" => "xhigh")

    [model_result, thinking_result].each { |result| assert_accepted(result) }
    assert_equal %w[P1-I1-W1 P1-I1-W1], [model_result, thinking_result].map { |result| result.fetch("target_id") }
    assert_equal "openai/gpt-5.6-sol", thinking_result.dig("result", "session_settings", "model", "reference")
    assert_equal "xhigh", thinking_result.dig("result", "session_settings", "thinking_level")
    assert_equal "openai/gpt-5.6-sol", persisted_agents.fetch(0).dig("session_settings", "model", "reference")
    log_entry(model_result.fetch("log_entry_ids").first).then do |entry|
      assert_equal "P1-I1-W1", entry.fetch("source_id")
      assert_includes entry.fetch("message"), "P1-I1-W1"
    end
    assert_empty @coordinator.calls, "targeted updates must not call the persistent default updater"
  end

  def test_targeted_session_commands_still_reject_an_unknown_agent_id
    result = apply_command("SetSessionModel", "agent_id" => "p1-i9-w9", "model" => "openai/gpt-5.6-sol")

    assert_rejected(result, "agent_not_found")
    assert_equal "Agent p1-i9-w9 does not exist.", result.fetch("message")
  end

  # `/session-settings` and its `GetSessionSettings` kernel command were removed. The command type
  # is no longer dispatchable, no longer head-proposable, and no longer advertised by `/help`; a
  # session's effective pair is still recorded on the agent record and readable through `GetInfo`.
  def test_get_session_settings_is_no_longer_a_kernel_command
    add_project!(name: "removed")
    create_issue!("P1", title: "Exercise removed inspection")
    spawn_worker!("P1-I1")

    removed = apply_command("GetSessionSettings", "agent_id" => "P1-I1-W1")

    assert_rejected(removed, "unknown_command")
    assert_equal "Unknown kernel command: GetSessionSettings", removed.fetch("message")
    refute_includes Meringue::Kernel::Engine::HEAD_PROPOSABLE_COMMANDS, "GetSessionSettings"
    refute Meringue::Kernel::Engine::HELP_COMMANDS.any? { |usage, _| usage.start_with?("/session") }

    info = apply_command("GetInfo", "target_id" => "P1-I1-W1")
    assert_accepted(info)
    assert_equal(
      "anthropic/claude-opus-5",
      info.dig("result", "record", "session_settings", "model", "reference")
    )
    assert_equal "max", info.dig("result", "record", "session_settings", "thinking_level")
  end

  def test_default_commands_validate_values_before_persistence
    # Shapes that cannot be a model reference at all: a bare id, whitespace, an
    # empty half, a mangled flag, and a filesystem path. A model id containing
    # extra slashes is NOT in this list any more; see the multi-segment tests
    # below.
    bad_models = ["gpt-5.6-sol", "openai/has space", "openai/", "/gpt-5.6-sol", "--model", "./models/foo"]
    bad_models.each do |model|
      assert_rejected(apply_command("SetDefaultSessionModel", "model" => model), "model must be a provider/model id")
    end
    assert_rejected(apply_command("SetDefaultSessionThinkingLevel", "level" => "ultra"), "thinking level must be one of")

    assert_empty @coordinator.calls
    refute File.exist?(File.join(tmp_root, "config.toml"))
  end

  # Reported bug: `/model fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`
  # was rejected even though Pi lists that model, accepts it on `--model`, and
  # reports it back from `get_state`. The kernel's `%r{\A[^/\s]+/[^/\s]+\z}`
  # allowed exactly one slash, so a provider prefix plus a Fireworks
  # account/router path could never match. Provider is everything before the
  # FIRST slash; the model id may contain more slashes and colons.
  MULTI_SEGMENT_MODEL = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"

  def test_a_multi_segment_model_reference_is_saved_and_reaches_new_sessions
    add_project!(name: "multi-segment")
    create_issue!("P1", title: "Exercise multi-segment models")

    [MULTI_SEGMENT_MODEL, "openai/gpt-5.6-sol"].each do |reference|
      result = apply_command("SetDefaultSessionModel", "model" => reference)

      assert_accepted(result)
      assert_equal reference, result.dig("result", "model")
      assert_includes result.fetch("message"), "Set the default model to #{reference}"

      config = Meringue::Config.load(path: File.join(tmp_root, "config.toml"))
      assert_equal reference, config.value("harness", "head_model")
      assert_equal reference, config.value("harness", "worker_model")
    end

    # The value round-trips into a session spawned after the change.
    apply_command("SetDefaultSessionModel", "model" => MULTI_SEGMENT_MODEL)
    spawn_worker!("P1-I1")
    spawned = persisted_agents.fetch(0)
    assert_equal MULTI_SEGMENT_MODEL, spawned.dig("session_settings", "model", "reference")
    assert_equal "fireworks", spawned.dig("session_settings", "model", "provider")
    assert_equal "fireworks:accounts/fireworks/routers/glm-5p2-fast", spawned.dig("session_settings", "model", "id")
  end

  def test_a_multi_segment_model_reference_is_accepted_for_one_existing_session
    add_project!(name: "multi-segment-session")
    create_issue!("P1", title: "Exercise multi-segment models")
    spawn_worker!("P1-I1")

    result = apply_command("SetSessionModel", "agent_id" => "P1-I1-W1", "model" => MULTI_SEGMENT_MODEL)

    assert_accepted(result)
    assert_equal MULTI_SEGMENT_MODEL, result.dig("result", "session_settings", "model", "reference")
    assert_equal MULTI_SEGMENT_MODEL, persisted_agents.fetch(0).dig("session_settings", "model", "reference")
    assert_empty @coordinator.calls, "a session change must not touch the persistent defaults"
  end

  # The user saw only "Rejected SetDefaultSessionModel: Default Pi model was not
  # changed." The reason existed, but only in the details blob, so a malformed id
  # and an over-strict rule looked identical. Every `/model` rejection now names
  # its reason in the line the user reads.
  def test_a_rejected_model_reference_states_its_reason_in_the_visible_line
    bare = apply_command("SetDefaultSessionModel", "model" => "glm-5p2-fast")

    assert_rejected(bare, "model must be a provider/model id")
    assert_includes bare.fetch("message"), "\"glm-5p2-fast\" has no provider prefix"
    assert_includes bare.fetch("message"), "Use <provider>/<model-id>, for example openai/gpt-5.6-sol"
    # The example proves multi-segment ids are legal, which is what the reporter
    # could not tell from the old message.
    assert_includes bare.fetch("message"), MULTI_SEGMENT_MODEL
    refute_equal "Default model was not changed.", bare.fetch("message")
    # The visible log line carries the same explanation, not just the details.
    visible = log_entry(bare.fetch("log_entry_ids").first).fetch("message")
    assert_includes visible, "has no provider prefix"
    refute_equal "Rejected SetDefaultSessionModel: Default model was not changed.", visible

    missing = apply_command("SetDefaultSessionModel", {})
    assert_includes missing.fetch("message"), "Default model was not changed: a model id is required."

    spaced = apply_command("SetDefaultSessionModel", "model" => "openai/gpt 5.6")
    assert_includes spaced.fetch("message"), "contains whitespace, so it is not a single model id"

    session_missing = apply_command("SetSessionModel", "agent_id" => "P1-I1-W1")
    assert_includes session_missing.fetch("message"), "Session model was not changed: a model id is required."

    assert_empty @coordinator.calls
    refute File.exist?(File.join(tmp_root, "config.toml"))
  end

  # Validation is catalog-independent by design, so a catalog that does not list
  # a model can never make it unsettable. It only decides whether the accepted
  # message labels the id verified or unverified.
  def test_the_catalog_labels_an_unlisted_model_instead_of_refusing_it
    engine = build_engine(
      store: Meringue::State::Store.new(path: File.join(tmp_root, "catalog.json")),
      harness_client: @settings_client,
      harness_client_provider: ->(_provider) { @settings_client },
      default_harness_provider: "pi",
      config_path: File.join(tmp_root, "catalog-config.toml"),
      model_catalog_provider: lambda do |_provider|
        Meringue::Harness::ModelCatalog.available(
          harness: "pi",
          models: [
            { "provider" => "fireworks", "id" => "fireworks:accounts/fireworks/routers/glm-5p2-fast",
              "name" => "GLM 5.2 Fast (Fireworks)", "thinking_levels" => %w[off low high], "reasoning" => true }
          ],
          source: "test_catalog_source"
        )
      end
    )
    engine.apply("type" => "GetModelCatalog", "payload" => {})

    listed = engine.apply("type" => "SetDefaultSessionModel", "payload" => { "model" => MULTI_SEGMENT_MODEL })
    assert_equal "accepted", listed.fetch("status")
    refute_includes listed.fetch("message"), "unverified"

    unlisted = engine.apply("type" => "SetDefaultSessionModel", "payload" => { "model" => "openai/gpt-5.6-sol" })
    assert_equal "accepted", unlisted.fetch("status")
    assert_equal "openai/gpt-5.6-sol", unlisted.dig("result", "model")
    assert_includes unlisted.fetch("message"), "does not include openai/gpt-5.6-sol, so the id is unverified"
    assert_includes unlisted.fetch("message"), "/models refresh"
  end

  # No catalog at all is the degraded state the picker and completion already
  # describe: the id is still saved, and still labelled unverified.
  def test_a_model_set_without_any_catalog_is_saved_and_labelled_unverified
    result = apply_command("SetDefaultSessionModel", "model" => MULTI_SEGMENT_MODEL)

    assert_accepted(result)
    assert_includes result.fetch("message"), "Meringue has no confirmed Pi model list right now"
    assert_includes result.fetch("message"), "#{MULTI_SEGMENT_MODEL} is unverified"
  end

  # A rejected level used to read only "Default Pi thinking level was not
  # changed.", which never said which words are legal, so the user had to guess
  # ("xhi", "ten"). The user-visible message now carries the ladder itself and
  # the obvious near-miss for a truncated level.
  def test_a_rejected_thinking_level_names_the_valid_levels
    truncated = apply_command("SetDefaultSessionThinkingLevel", "level" => "xhi")

    assert_rejected(truncated, "thinking level must be one of")
    assert_includes truncated.fetch("message"), "\"xhi\" is not a supported reasoning level"
    assert_includes truncated.fetch("message"), "Did you mean xhigh?"
    assert_includes truncated.fetch("message"), "Valid levels: off, minimal, low, medium, high, xhigh, max."
    # The visible log line carries the same explanation, not just the details blob.
    assert_includes log_entry(truncated.fetch("log_entry_ids").first).fetch("message"), "Valid levels:"

    nonsense = apply_command("SetDefaultSessionThinkingLevel", "level" => "ten")
    assert_includes nonsense.fetch("message"), "\"ten\" is not a supported reasoning level"
    refute_includes nonsense.fetch("message"), "Did you mean"
    assert_includes nonsense.fetch("message"), "Valid levels: off, minimal, low, medium, high, xhigh, max."

    missing = apply_command("SetDefaultSessionThinkingLevel", {})
    assert_includes missing.fetch("message"), "a level is required"
    assert_includes missing.fetch("message"), "Valid levels: off, minimal, low, medium, high, xhigh, max."

    session_missing = apply_command("SetSessionThinkingLevel", "agent_id" => "P1-I1-W1")
    assert_includes session_missing.fetch("message"), "Session thinking level was not changed: a level is required."

    assert_empty @coordinator.calls
    refute File.exist?(File.join(tmp_root, "config.toml"))
  end

  # Validation stays catalog-independent, so a level a model's catalog entry does
  # not advertise is still saved: a provider extension can under-declare its
  # `thinkingLevelMap`, and Pi clamps at spawn time instead of failing. The
  # accepted message says what Pi will actually run so the pair cannot look
  # silently honoured.
  def test_a_level_the_catalog_does_not_list_is_saved_and_reports_pis_clamp
    proxy = "anthropic-250k-prefer-using-this-one/claude-opus-5"
    engine = build_engine(
      store: Meringue::State::Store.new(path: File.join(tmp_root, "clamp.json")),
      harness_client: @settings_client,
      harness_client_provider: ->(_provider) { @settings_client },
      default_harness_provider: "pi",
      config_path: File.join(tmp_root, "clamp-config.toml"),
      model_catalog_provider: lambda do |_provider|
        Meringue::Harness::ModelCatalog.available(
          harness: "pi",
          models: [
            { "provider" => "anthropic-250k-prefer-using-this-one", "id" => "claude-opus-5",
              "thinking_levels" => %w[off minimal low medium high xhigh], "reasoning" => true }
          ],
          source: "test_catalog_source"
        )
      end
    )
    engine.apply("type" => "GetModelCatalog", "payload" => {})
    engine.apply("type" => "SetDefaultSessionModel", "payload" => { "model" => proxy })

    result = engine.apply("type" => "SetDefaultSessionThinkingLevel", "payload" => { "level" => "max" })

    assert_equal "accepted", result.fetch("status"), result.fetch("errors", []).inspect
    assert_equal "max", result.dig("result", "thinking_level")
    assert_includes result.fetch("message"), "Set the default thinking level to max"
    assert_includes result.fetch("message"), "Pi's catalog does not list max for #{proxy}"
    assert_includes result.fetch("message"), "run xhigh instead"

    # A head-proposed GetSessionDefaults repeats the same caveat, so the pair
    # never reads as honoured (there is no `/defaults` command any more).
    defaults = engine.apply("type" => "GetSessionDefaults", "payload" => {})
    assert_equal "accepted", defaults.fetch("status")
    assert_includes defaults.fetch("message"), "#{proxy} with thinking max"
    assert_includes defaults.fetch("message"), "run xhigh instead"

    # A level the model does advertise says nothing extra.
    quiet = engine.apply("type" => "SetDefaultSessionThinkingLevel", "payload" => { "level" => "xhigh" })
    assert_equal "accepted", quiet.fetch("status")
    refute_includes quiet.fetch("message"), "catalog does not list"
    refute_includes engine.apply("type" => "GetSessionDefaults", "payload" => {}).fetch("message"), "catalog does not list"
  end

  # GetSessionDefaults survived the removal of `/defaults` because heads still
  # propose it for "show the defaults"; its output is a durable log line, not a
  # status-line glance.
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
