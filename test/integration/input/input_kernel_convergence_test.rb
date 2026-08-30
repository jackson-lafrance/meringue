# frozen_string_literal: true

require "test_helper"
require "support/input_support"

# Convergence tests: slash commands typed by the user and commands proposed by a
# head agent both land in the same validated kernel command layer, against a tmp
# state file with the in-repo fake harness client and a stubbed head runner.
class InputKernelConvergenceTest < Minitest::Test
  include InputSupport

  def test_slash_commands_walk_the_whole_lifecycle_against_a_tmp_state_file
    input_sandbox do |sandbox|
      expectations = [
        ["/help", "Help", "accepted"],
        ["/tree", "ListAll", "accepted"],
        ["/state", "GetState", "accepted"],
        ["/questions", "ListQuestions", "accepted"],
        ["/project add #{sandbox.project_path} My Proj", "AddProject", "accepted"],
        ['/issue create P1 "Fix the login bug" "Users cannot log in"', "CreateIssue", "accepted"],
        ['/worker spawn P1-I1 "Fix it please"', "SpawnWorker", "accepted"],
        ['/prompt P1-I1-W1 "any update?"', "PromptAgent", "accepted"],
        ["/kill P1-I1-W1", "Kill", "accepted"],
        ["/prune", "Prune", "accepted"],
        ["/recount", "Recount", "accepted"],
        ["/clear", "ClearState", "accepted"]
      ]

      expectations.each do |input, command_type, status|
        payload = sandbox.submit(input)

        assert_equal "slash_command_applied", payload.fetch("event"), input
        assert_equal [[command_type, status]], sandbox.command_result_pairs(payload), input
      end

      state = sandbox.state
      assert_empty state.fetch("projects")
      assert_empty state.fetch("issues")
      assert_empty state.fetch("agents")
      assert_equal sandbox.state_path, sandbox.store.path
      assert File.file?(sandbox.state_path)
    end
  end

  def test_slash_commands_persist_records_before_state_is_cleared
    input_sandbox do |sandbox|
      sandbox.submit("/project add #{sandbox.project_path} My Proj")
      sandbox.submit('/issue create P1 "Fix the login bug"')
      sandbox.submit('/worker spawn P1-I1 "Fix it please"')

      state = sandbox.state
      assert_equal ["P1"], state.fetch("projects").map { |project| project.fetch("id") }
      assert_equal ["P1-I1"], state.fetch("issues").map { |issue| issue.fetch("id") }
      worker = state.fetch("agents").find { |agent| agent.fetch("type") == "worker" }
      assert_equal "P1-I1-W1", worker.fetch("id")
      assert_equal "fake", worker.fetch("harness")
      assert_equal "P1", state.fetch("projects").first.fetch("id")
      assert_equal File.expand_path(sandbox.project_path), state.fetch("projects").first.fetch("root_path")
    end
  end

  def test_rejected_slash_commands_are_reported_and_do_not_mutate_state
    input_sandbox do |sandbox|
      [
        ['/prompt P9-I9-W9 "nope"', "PromptAgent", "agent_not_found"],
        ['/issue create P9 "Nope"', "CreateIssue", "project_not_found"],
        ['/worker spawn P9-I9 "Nope"', "SpawnWorker", "issue_not_found"],
        ["/kill P9", "Kill", "target_not_found"],
        ['/answer Q9 "Nope"', "AnswerQuestion", "question_not_found"],
        ["/dismiss Q9", "DismissQuestion", "question_not_found"]
      ].each do |input, command_type, error|
        payload = sandbox.submit(input)
        result = sandbox.command_results(payload).first

        assert_equal command_type, result.fetch("command_type"), input
        assert_equal "rejected", result.fetch("status"), input
        assert_includes result.fetch("errors"), error, input
        refute payload.fetch("state_mutated"), input
      end

      state = sandbox.state
      assert_empty state.fetch("projects")
      assert_empty state.fetch("issues")
      assert_empty state.fetch("agents")
      assert_empty state.fetch("questions")
    end
  end

  def test_unknown_slash_command_is_rejected_by_the_kernel_with_help_text
    input_sandbox do |sandbox|
      payload = sandbox.submit("/bogus")
      result = sandbox.command_results(payload).first

      assert_equal "InvalidSlashCommand", result.fetch("command_type")
      assert_equal "rejected", result.fetch("status")
      assert_equal "Unknown slash command: /bogus", result.fetch("message")
      refute payload.fetch("state_mutated")
    end
  end

  def test_harness_selection_slash_command_validates_the_provider
    input_sandbox do |sandbox|
      accepted = sandbox.submit("/harness pi")
      assert_equal [%w[SetHarness accepted]], sandbox.command_result_pairs(accepted)

      %w[bogus antigravity agy].each do |provider|
        rejected = sandbox.submit("/harness #{provider}")
        result = sandbox.command_results(rejected).first
        assert_equal "rejected", result.fetch("status")
        assert_includes result.fetch("errors"), "unsupported_harness_provider"
      end
    end
  end

  def test_codex_harness_selection_persists_safe_future_defaults
    input_sandbox do |sandbox|
      result = sandbox.submit("/harness codex")
      assert_equal [%w[SetHarness accepted]], sandbox.command_result_pairs(result)

      saved = Meringue::Config.load(path: sandbox.config_path)
      assert_equal "codex", saved.setting("agent.head_harness", env: {})
      assert_equal "codex", saved.setting("agent.worker_harness", env: {})
      assert_equal "openai/gpt-5.6-sol", saved.setting("agent.head_model", env: {})
      assert_equal "openai/gpt-5.6-sol", saved.setting("agent.worker_model", env: {})
      assert_equal "Codex CLI", sandbox.state.dig("metadata", "active_harness_label")
    end
  end

  def test_harness_switch_repairs_incompatible_shared_and_role_defaults_without_rewriting_sessions
    input_sandbox do |sandbox|
      write_config(
        sandbox.config_path,
        <<~TOML
          [harness]
          head_provider = "pi"
          worker_provider = "pi"
          head_model = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"
          worker_model = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"
          head_thinking_level = "minimal"
          worker_thinking_level = "off"
        TOML
      )

      result = sandbox.submit("/harness claude")
      assert_equal [%w[SetHarness accepted]], sandbox.command_result_pairs(result)

      saved = Meringue::Config.load(path: sandbox.config_path)
      assert_equal "claude", saved.setting("agent.head_harness", env: {})
      assert_equal "claude", saved.setting("agent.worker_harness", env: {})
      assert_equal "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast", saved.setting("agent.head_model", env: {})
      assert_equal "max", saved.setting("agent.head_thinking", env: {})
      assert_equal "max", saved.setting("agent.worker_thinking", env: {})
      assert_equal "max", sandbox.state.dig("metadata", "agent_session_defaults", "thinking_level")
      assert_empty sandbox.state.fetch("agents")
    end
  end

  def test_future_pi_default_slash_commands_validate_and_persist_in_the_sandbox
    input_sandbox do |sandbox|
      model = sandbox.submit("/model openai/gpt-5.6-sol")
      thinking = sandbox.submit("/thinking xhigh")
      assert_equal [%w[SetDefaultSessionModel accepted]], sandbox.command_result_pairs(model)
      assert_equal [%w[SetDefaultSessionThinkingLevel accepted]], sandbox.command_result_pairs(thinking)
      config = Meringue::Config.load(path: sandbox.config_path)
      assert_equal "openai/gpt-5.6-sol", config.value("harness", "head_model")
      assert_equal "openai/gpt-5.6-sol", config.value("harness", "worker_model")
      assert_equal "xhigh", config.value("harness", "head_thinking_level")
      assert_equal "xhigh", config.value("harness", "worker_thinking_level")

      rejected = sandbox.submit("/thinking ultra")
      result = sandbox.command_results(rejected).first
      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("errors").join(" "), "thinking level must be one of"
      assert_equal "xhigh", Meringue::Config.load(path: sandbox.config_path).value("harness", "head_thinking_level")
    end
  end

  # Reported bug: `/model fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast`
  # was rejected end to end even though Pi accepts that model. The provider is
  # everything before the first slash; the model id keeps the rest, colon and all.
  def test_a_multi_segment_model_reference_survives_the_whole_slash_command_path
    reference = "fireworks/fireworks:accounts/fireworks/routers/glm-5p2-fast"
    input_sandbox do |sandbox|
      applied = sandbox.submit("/model #{reference}")

      assert_equal [%w[SetDefaultSessionModel accepted]], sandbox.command_result_pairs(applied)
      assert_equal reference, Meringue::Config.load(path: sandbox.config_path).value("harness", "head_model")

      # A rejection names its reason in the message the user sees, not only in
      # the errors detail.
      rejected = sandbox.command_results(sandbox.submit("/model glm-5p2-fast")).first
      assert_equal "rejected", rejected.fetch("status")
      assert_includes rejected.fetch("message"), "has no provider prefix"
      assert_includes rejected.fetch("message"), "Use <provider>/<model-id>"
      assert_equal reference, Meringue::Config.load(path: sandbox.config_path).value("harness", "head_model")
    end
  end

  # `/defaults` is gone: it only printed the pair the status line and `/config`
  # already show. Typing it is now an unknown command, while a head asked "which
  # model will future agents use" still reaches the same kernel command.
  def test_defaults_slash_command_is_removed_but_heads_can_still_read_the_defaults
    input_sandbox do |sandbox|
      typed = sandbox.submit("/defaults")
      result = sandbox.command_results(typed).first

      assert_equal "InvalidSlashCommand", result.fetch("command_type")
      assert_equal "rejected", result.fetch("status")
      assert_equal "Unknown slash command: /defaults", result.fetch("message")
      refute typed.fetch("state_mutated")

      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Report the defaults",
          summary: "Reported the future-session pair.",
          commands: [{ "type" => "GetSessionDefaults", "payload" => {} }]
        )
      )
      head_driven = sandbox.submit("which model will future agents use")

      assert_equal [%w[GetSessionDefaults accepted]], sandbox.command_result_pairs(head_driven)
      assert_includes(
        sandbox.command_results(head_driven).first.fetch("message"),
        "Future heads and workers use"
      )
    end
  end

  def test_theme_slash_command_writes_only_the_sandbox_config_file
    with_preserved_tui_style do
      input_sandbox do |sandbox|
        payload = sandbox.submit("/theme gruvbox")
        result = sandbox.command_results(payload).first

        assert_equal "SetTheme", result.fetch("command_type")
        assert_equal "accepted", result.fetch("status")
        assert_includes result.fetch("message"), sandbox.config_path
        assert_includes File.read(sandbox.config_path), 'colorscheme = "gruvbox"'
        assert_equal "gruvbox", Meringue::TUI::Style.current_colorscheme

        rejected = sandbox.submit("/theme not-a-theme")
        assert_equal "rejected", sandbox.command_results(rejected).first.fetch("status")
      end
    end
  end

  # First-run setup ends by typing its own slash command, so the completion
  # marker takes the same validated, journaled path as every other config write
  # and lands only in the sandbox config file.
  def test_setup_completion_marker_is_written_through_the_typed_slash_path
    input_sandbox do |sandbox|
      payload = sandbox.submit("/setup skip")

      assert_equal [%w[CompleteOnboarding accepted]], sandbox.command_result_pairs(payload)
      config = Meringue::Config.load(path: sandbox.config_path)
      assert_equal "skipped", config.onboarding_outcome
      assert Meringue::TUI::Onboarding.completed?(config)

      assert_equal [%w[CompleteOnboarding accepted]], sandbox.command_result_pairs(sandbox.submit("/setup complete"))
      assert_equal "completed", Meringue::Config.load(path: sandbox.config_path).onboarding_outcome
    end
  end

  def test_head_proposed_and_user_typed_commands_produce_identical_result_shapes
    input_sandbox do |sandbox|
      sandbox.submit("/project add #{sandbox.project_path} My Proj")
      typed = sandbox.command_results(sandbox.submit('/issue create P1 "Typed issue"')).first

      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Create an issue",
          summary: "Routed a new goal to a new issue.",
          commands: [{ "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Head issue" } }]
        )
      )
      head_driven = sandbox.command_results(sandbox.submit("create a head issue")).last

      assert_equal typed.keys.sort, head_driven.keys.sort
      assert_equal "CreateIssue", typed.fetch("command_type")
      assert_equal "CreateIssue", head_driven.fetch("command_type")
      assert_equal "accepted", typed.fetch("status")
      assert_equal "accepted", head_driven.fetch("status")
      assert_equal "P1-I1", typed.fetch("target_id")
      assert_equal "P1-I2", head_driven.fetch("target_id")

      # A user-typed command carries no command id; a head-proposed command is
      # journaled under its head.
      assert_nil typed.fetch("command_id")
      assert_match(/\AH\d+-C\d+\z/, head_driven.fetch("command_id"))
    end
  end

  def test_natural_language_input_runs_the_head_then_applies_its_commands
    input_sandbox do |sandbox|
      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Route the request",
          summary: "Registered the project, created an issue, and spawned a worker.",
          commands: [
            { "type" => "AddProject", "payload" => { "path" => sandbox.project_path, "name" => "proj" } },
            { "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Add caching" } },
            {
              "type" => "SpawnWorker",
              "payload" => { "issue_id" => "P1-I1", "title" => "Add caching", "prompt" => "Add a cache layer." }
            }
          ]
        )
      )

      payload = sandbox.submit("add caching to the api layer")

      assert_equal "head_loop_iteration", payload.fetch("event")
      assert_equal "accepted", payload.fetch("spawn_head_result").fetch("status")
      assert_equal "accepted", payload.fetch("apply_head_result").fetch("status")
      assert_equal(
        [%w[AddProject accepted], %w[CreateIssue accepted], %w[SpawnWorker accepted]],
        sandbox.command_result_pairs(payload)
      )
      assert payload.fetch("state_mutated")

      assert_equal 1, sandbox.head_runner.calls.length
      call = sandbox.head_runner.calls.first
      assert_equal "add caching to the api layer", call.fetch("user_message")
      assert_nil call.fetch("question_id")

      state = sandbox.state
      assert_equal ["P1"], state.fetch("projects").map { |project| project.fetch("id") }
      assert_equal ["P1-I1"], state.fetch("issues").map { |issue| issue.fetch("id") }
      assert_equal ["P1-I1-W1"], state.fetch("agents").map { |agent| agent.fetch("id") }
    end
  end

  # A head that dies before routing leaves the user's request unrouted. Typing `/retry H1`
  # re-runs it through a fresh head, and that retry head's own HeadResult is applied exactly like
  # a natural-language head's.
  def test_retrying_a_failed_head_retries_the_request_it_never_routed
    input_sandbox do |sandbox|
      sandbox.head_runner.enqueue_failure("model transport failed mid-turn")
      failed = sandbox.submit("add caching to the api layer")

      assert_equal "failed", failed.fetch("spawn_head_result").fetch("status")
      assert_equal "errored", sandbox.agents.fetch(0).fetch("status")

      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Route the request",
          summary: "Registered the project on the retry.",
          commands: [{ "type" => "AddProject", "payload" => { "path" => sandbox.project_path, "name" => "proj" } }]
        )
      )
      payload = sandbox.submit("/retry H1")

      assert_equal "slash_command_applied", payload.fetch("event")
      assert_equal [%w[RetryHead accepted], %w[AddProject accepted]], sandbox.command_result_pairs(payload)
      assert payload.fetch("state_mutated")

      retry_message = sandbox.head_runner.calls.last.fetch("user_message")
      assert_includes retry_message, "Retry of head H1"
      assert_includes retry_message, "add caching to the api layer"

      assert_equal ["P1"], sandbox.state.fetch("projects").map { |project| project.fetch("id") }
      assert_nil sandbox.agents.find { |agent| agent.fetch("id") == "H1" }
      assert_includes sandbox.state.fetch("logs").map { |log| log.fetch("message") }.join("\n"), "Retrying head H1 as head H2"
    end
  end

  def test_rejected_head_command_marks_the_head_blocked_and_keeps_the_rest_of_state
    input_sandbox do |sandbox|
      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Bad routing",
          summary: "Proposed an issue under a project that does not exist.",
          commands: [{ "type" => "CreateIssue", "payload" => { "project_id" => "P9", "title" => "Nope" } }]
        )
      )

      payload = sandbox.submit("do something impossible")

      assert_equal [%w[CreateIssue rejected]], sandbox.command_result_pairs(payload)
      head = sandbox.agents.find { |agent| agent.fetch("type") == "head" }
      assert_equal "blocked", head.fetch("status")
      assert_empty sandbox.state.fetch("issues")
    end
  end

  def test_kernel_accepts_snake_case_command_aliases_from_heads
    input_sandbox do |sandbox|
      result = sandbox.apply("add_project", "path" => sandbox.project_path, "name" => "proj")

      assert_equal "AddProject", result.fetch("command_type")
      assert_equal "accepted", result.fetch("status")

      unknown = sandbox.apply("Nonsense")
      assert_equal "rejected", unknown.fetch("status")
      assert_includes unknown.fetch("errors"), "unknown_command"
    end
  end

  def test_kernel_command_results_always_share_one_shape
    input_sandbox do |sandbox|
      payloads = [
        sandbox.submit("/help"),
        sandbox.submit("/bogus"),
        sandbox.submit('/answer Q9 "no such question"')
      ]

      payloads.flat_map { |payload| sandbox.command_results(payload) }.each do |result|
        assert_equal(
          %w[command_id command_type errors log_entry_ids message result status target_id],
          result.keys.sort
        )
        assert_includes %w[accepted rejected failed], result.fetch("status")
        assert_kind_of Array, result.fetch("errors")
        assert_kind_of Array, result.fetch("log_entry_ids")
      end
    end
  end
end
