# frozen_string_literal: true

require "test_helper"
require "support/input_support"
require "tmpdir"

class WorkerModelSelectionGuidanceTest < Minitest::Test
  include InputSupport

  class RecordingSessionRunner
    attr_reader :calls

    def initialize
      @calls = []
    end

    def spawn_head_session(**kwargs)
      @calls << kwargs
      {
        "harness" => "fake",
        "session_id" => "restarted-head",
        "is_streaming" => false,
        "metadata" => {}
      }
    end
  end

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

  def test_default_prompt_is_concise_task_based_and_independent_of_global_defaults
    prompt = Meringue::Experiments::WorkerSpawningGuidance.default_text

    assert_includes prompt, "complexity, risk, and need for speed"
    assert_includes prompt, "Set both model and thinking_level explicitly on every SpawnWorker"
    assert_includes prompt, "off, minimal, low, medium, high, xhigh, or max"
    refute_includes prompt, "@openai/gpt-5.6-luna"
    refute_match(/global|configured .*default|compensat/i, prompt)
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
    assert enabled.to_prompt_h.fetch("state_access").fetch("privacy_filtered")
    refute enabled.to_prompt_h.fetch("state_access").key?("state_path")
    refute disabled.to_prompt_h.key?("additional_system_prompt")
    refute_includes disabled.system_prompt, prompt
  end

  def test_guidance_context_and_runner_snapshot_hide_worker_default_selections
    snapshot = Meringue::State::Models.empty_state
    snapshot.fetch("metadata").merge!(
      "active_harness" => "pi",
      "active_worker_harness" => "pi",
      "agent_session_defaults" => {
        "model" => "private/default-worker-model",
        "thinking_level" => "xhigh",
        "roles" => {
          "head" => { "model" => "public/head-model", "thinking_level" => "low" },
          "worker" => { "model" => "private/default-worker-model", "thinking_level" => "xhigh" }
        }
      },
      "pi_session_defaults" => {
        "model" => "private/legacy-worker-model",
        "thinking_level" => "max",
        "roles" => { "worker" => { "model" => "private/legacy-worker-model", "thinking_level" => "max" } }
      },
      "harness_model_catalogs" => {
        "pi" => Meringue::Harness::ModelCatalog.available(
          harness: "pi",
          models: [
            { "provider" => "openai", "id" => "gpt-5.6-sol", "thinking_levels" => %w[low high] },
            { "provider" => "private", "id" => "default-worker-model", "thinking_levels" => %w[low high] }
          ]
        ).to_h
      }
    )
    snapshot.fetch("agents") << {
      "id" => "P1-I1-W1",
      "type" => "worker",
      "status" => "idle",
      "session_settings" => { "model" => { "reference" => "private/default-worker-model" }, "thinking_level" => "xhigh" },
      "harness_metadata" => {
        "spawn_session_settings" => { "model" => "private/default-worker-model", "thinking_level" => "xhigh" },
        "pi_state" => { "model" => { "provider" => "private", "id" => "default-worker-model" }, "thinkingLevel" => "xhigh" },
        "command" => ["pi", "--model", "private/default-worker-model", "--thinking", "xhigh"]
      }
    }
    snapshot.fetch("logs") << {
      "id" => "L1",
      "source_type" => "kernel",
      "message" => "Set worker default model to private/default-worker-model.",
      "details" => {
        "changed_field" => "model",
        "scope" => "future_worker_sessions",
        "agent_session_defaults" => { "model" => "private/default-worker-model" }
      }
    }
    snapshot.fetch("logs") << {
      "id" => "L2",
      "source_type" => "kernel",
      "message" => "Spawned worker P1-I1-W1 for P1-I1.",
      "details" => {
        "session_settings" => { "model" => { "reference" => "private/default-worker-model" }, "thinking_level" => "xhigh" }
      }
    }

    context = Meringue::Heads::Context.new(
      head_id: "H1",
      user_message: "route work",
      snapshot: snapshot,
      state_path: "/private/state.json",
      worker_spawning_guidance: true
    )
    serialized = JSON.generate(
      "snapshot" => context.snapshot,
      "prompt" => context.to_prompt_h,
      "system_prompt" => context.system_prompt
    )

    refute_includes serialized, "private/default-worker-model"
    refute_includes serialized, "private/legacy-worker-model"
    refute_includes serialized, "/private/state.json"
    assert_nil context.state_path
    refute_includes context.system_prompt, "GetSessionDefaults"
    refute_includes context.system_prompt, "future-session head and worker model and thinking levels"
    refute context.snapshot.fetch("metadata").key?("agent_session_defaults")
    refute context.snapshot.fetch("metadata").key?("pi_session_defaults")
    refute context.snapshot.fetch("agents").first.key?("session_settings")
    refute context.snapshot.fetch("agents").first.fetch("harness_metadata").key?("spawn_session_settings")
    assert_empty context.snapshot.fetch("logs")
    assert_equal ["openai/gpt-5.6-sol"], context.to_prompt_h.dig("worker_selection_catalog", "models").map { |model| model.fetch("reference") }
    selection_rule = context.to_prompt_h.dig("routing_context", "decision_rules").find { |rule| rule.include?("Set both SpawnWorker.model") }
    assert_includes selection_rule, "supplied worker-selection guidance"
    refute_includes selection_rule, "default"
  end

  def test_initial_and_restarted_head_runner_paths_receive_only_the_filtered_snapshot
    Dir.mktmpdir("meringue-guidance-runner-snapshot") do |dir|
      config_path = File.join(dir, "config.toml")
      File.write(config_path, <<~TOML)
        [settings]
        schema_version = 1
        [harness]
        provider = "pi"
        head_model = "public/head-model"
        worker_model = "private/configured-worker-model"
        head_thinking_level = "low"
        worker_thinking_level = "xhigh"
        [experiments]
        worker_spawning_guidance = true
      TOML
      store = Meringue::State::Store.new(path: File.join(dir, "state.json"))
      store.save(Meringue::State::Models.empty_state)
      initial_runner = InputSupport::StubHeadRunner.new
      engine = Meringue::Kernel::Engine.new(
        store: store,
        head_runner: initial_runner,
        config: Meringue::Config.load(path: config_path),
        config_path: config_path,
        cwd: dir
      )

      engine.apply("type" => "SpawnHead", "payload" => { "user_message" => "route this" })
      initial_call = initial_runner.calls.first
      refute_nil initial_call
      assert_filtered_runner_call(initial_call)

      restart_runner = RecordingSessionRunner.new
      restart_engine = Meringue::Kernel::Engine.new(
        store: store,
        head_runner: restart_runner,
        config: Meringue::Config.load(path: config_path),
        config_path: config_path,
        cwd: dir
      )
      restart_agent = {
        "id" => "H99",
        "type" => "head",
        "status" => "working",
        "harness" => "pi",
        "harness_metadata" => {}
      }
      restart_engine.send(:restart_head_session, restart_agent, { "user_message" => "route this" })
      assert_equal 1, restart_runner.calls.length
      assert_filtered_runner_call(restart_runner.calls.first)
    end
  end

  def test_guided_head_spawns_require_explicit_model_and_thinking_but_direct_spawns_do_not
    Dir.mktmpdir("meringue-guided-spawn") do |dir|
      project_path = File.join(dir, "project")
      FileUtils.mkdir_p(project_path)
      config_path = File.join(dir, "config.toml")
      File.write(config_path, <<~TOML)
        [settings]
        schema_version = 1
        [experiments]
        worker_spawning_guidance = true
      TOML
      state = Meringue::State::Models.empty_state
      state.fetch("projects") << {
        "id" => "P1", "name" => "Project", "root_path" => project_path, "status" => "working"
      }
      state.fetch("issues") << {
        "id" => "P1-I1", "project_id" => "P1", "parent_issue_id" => nil,
        "title" => "Task", "description" => "", "status" => "working", "agent_ids" => []
      }
      %w[H1 H2 H3].each do |id|
        state.fetch("agents") << {
          "id" => id, "type" => "head", "status" => "working",
          "harness_metadata" => { "worker_spawning_guidance" => true, "head_request" => { "user_message" => "route" } }
        }
      end
      store = Meringue::State::Store.new(path: File.join(dir, "state.json"))
      store.save(state)
      engine = Meringue::Kernel::Engine.new(
        store: store,
        harness_client: Meringue::Harness::FakeClient.new,
        workspace_manager: Meringue::Workspace::Manager.new(root_path: File.join(dir, "workspaces")),
        config: Meringue::Config.load(path: config_path),
        config_path: config_path,
        cwd: project_path
      )

      missing = apply_head_spawn(engine, "H1", {})
      rejected = missing.dig("result", "command_results", 0)
      assert_equal "rejected", rejected.fetch("status")
      assert_includes rejected.fetch("errors"), "worker_selection_guidance_requires_explicit_settings"
      assert_includes rejected.fetch("errors"), "missing: model, thinking_level"

      explicit = apply_head_spawn(
        engine,
        "H2",
        "model" => "openai/gpt-5.6-sol",
        "thinking_level" => "high"
      )
      assert_equal "accepted", explicit.dig("result", "command_results", 0, "status")

      defaults = apply_head_command(engine, "H3", "GetSessionDefaults")
      default_result = defaults.dig("result", "command_results", 0)
      assert_equal "rejected", default_result.fetch("status")
      assert_includes default_result.fetch("errors"), "worker_selection_guidance_hides_defaults"

      direct = engine.apply(
        "command_id" => "direct-spawn",
        "type" => "SpawnWorker",
        "payload" => { "issue_id" => "P1-I1", "prompt" => "Direct user spawn.", "title" => "Direct spawn" }
      )
      assert_equal "accepted", direct.fetch("status")
    end
  end

  private

  def assert_filtered_runner_call(call)
    snapshot = call["snapshot"] || call.fetch(:snapshot)
    context = call["context"] || call.fetch(:context)
    serialized = JSON.generate("snapshot" => snapshot, "prompt" => context.to_prompt_h, "system" => context.system_prompt)
    refute_includes serialized, "private/configured-worker-model"
    refute snapshot.fetch("metadata").key?("agent_session_defaults")
    refute snapshot.fetch("metadata").key?("pi_session_defaults")
    assert context.to_prompt_h.fetch("state_access").fetch("privacy_filtered")
  end

  def apply_head_command(engine, head_id, command_type, payload = {})
    engine.apply(
      "type" => "ApplyHeadResult",
      "payload" => {
        "head_id" => head_id,
        "head_result" => {
          "title" => "Read defaults",
          "summary" => "Read a kernel record.",
          "commands" => [{ "type" => command_type, "payload" => payload }],
          "questions" => []
        }
      }
    )
  end

  def apply_head_spawn(engine, head_id, settings)
    engine.apply(
      "type" => "ApplyHeadResult",
      "payload" => {
        "head_id" => head_id,
        "head_result" => {
          "title" => "Route task",
          "summary" => "Spawn a worker.",
          "commands" => [{
            "type" => "SpawnWorker",
            "payload" => {
              "issue_id" => "P1-I1",
              "prompt" => "Do the task.",
              "title" => "Do task"
            }.merge(settings)
          }],
          "questions" => []
        }
      }
    )
  end

  def slash_parser
    @slash_parser ||= Meringue::Input::SlashCommandParser.new
  end
end
