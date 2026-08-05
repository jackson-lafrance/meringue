# frozen_string_literal: true

require "test_helper"
require "support/heads_support"

# The kernel talks to head runners through one small interface. This covers the
# base contract plus FakeRunner and HarnessRunner (and its PiRunner subclass)
# satisfying it, without launching a real harness.
class HeadRunnerParityTest < Minitest::Test
  include HeadsSupport

  # FakeClient with a transcript exposed through get_state instead of the optional
  # wait_for_settled/last_assistant_text helpers.
  class PollingHarnessClient < Meringue::Harness::FakeClient
    def initialize(raw_output:)
      @raw_output = raw_output
    end

    def spawn_session(kind:, cwd:, prompt:, system_prompt:, session_name:)
      session_ref = super
      session_ref.merge(
        "metadata" => session_ref.fetch("metadata").merge("last_assistant_text" => @raw_output)
      )
    end
  end

  def test_base_runner_requires_an_implementation
    error = assert_raises(NotImplementedError) do
      Meringue::Heads::Runner.new.run(user_message: "hi", snapshot: head_snapshot)
    end

    assert_includes error.message, "head runners must implement #run"
  end

  def test_all_runners_share_the_run_signature
    expected = [%i[keyreq user_message], %i[keyreq snapshot], %i[key context], %i[key question_id]]

    [
      Meringue::Heads::Runner,
      Meringue::Heads::FakeRunner,
      Meringue::Heads::HarnessRunner,
      Meringue::Heads::PiRunner
    ].each do |runner_class|
      assert_equal expected, runner_class.instance_method(:run).parameters, runner_class.name
    end
  end

  def test_runner_class_hierarchy
    assert_operator Meringue::Heads::FakeRunner, :<, Meringue::Heads::Runner
    assert_operator Meringue::Heads::HarnessRunner, :<, Meringue::Heads::Runner
    assert_operator Meringue::Heads::PiRunner, :<, Meringue::Heads::HarnessRunner
    assert_equal Meringue::Heads::InvalidHeadResultError, Meringue::Heads::PiRunner::InvalidHeadResultError
  end

  def test_fake_runner_returns_a_valid_head_result_envelope
    result = Meringue::Heads::FakeRunner.new.run(user_message: "clean up the docs", snapshot: head_snapshot)

    assert_equal %w[title summary commands questions], result.keys
    assert_equal "Clean up the docs", result.fetch("title")
    assert_empty result.fetch("questions")
    # The envelope a real head would return must pass the parser unchanged.
    assert_equal result, Meringue::Heads::ResultParser.parse(JSON.generate(result))
  end

  def test_fake_runner_bootstraps_a_project_issue_and_worker_from_empty_state
    context = build_head_context(snapshot: Meringue::State::Models.empty_state)
    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "set up a docs cleanup task",
      snapshot: Meringue::State::Models.empty_state,
      context: context
    )

    types = result.fetch("commands").map { |command| command.fetch("type") }
    assert_equal %w[AddProject CreateIssue SpawnWorker], types
    assert_equal context.cwd, result.dig("commands", 0, "payload", "path")
    assert_equal "P1", result.dig("commands", 1, "payload", "project_id")
    assert_nil result.dig("commands", 1, "payload", "parent_issue_id")
    assert_equal "create-issue", result.dig("commands", 2, "payload", "issue_from_command")
    refute_empty result.dig("commands", 2, "payload", "title")
  end

  def test_fake_runner_prompts_an_explicitly_referenced_resumable_worker
    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "P1-I1-W1 also update the changelog",
      snapshot: head_snapshot
    )

    assert_equal ["PromptAgent"], result.fetch("commands").map { |command| command.fetch("type") }
    assert_equal "P1-I1-W1", result.dig("commands", 0, "payload", "agent_id")
    assert_equal "normal", result.dig("commands", 0, "payload", "mode")
  end

  def test_fake_runner_steers_a_streaming_worker_on_an_urgent_correction
    snapshot = head_snapshot
    snapshot.fetch("agents").first.fetch("harness_metadata")["is_streaming"] = true

    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "P1-I1-W1 stop, that approach is wrong",
      snapshot: snapshot
    )

    assert_equal "steer", result.dig("commands", 0, "payload", "mode")
  end

  def test_fake_runner_follows_up_on_a_streaming_worker_for_related_work
    snapshot = head_snapshot
    snapshot.fetch("agents").first.fetch("harness_metadata")["is_streaming"] = true

    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "P1-I1-W1 also add a regression test",
      snapshot: snapshot
    )

    assert_equal "follow_up", result.dig("commands", 0, "payload", "mode")
  end

  def test_fake_runner_replaces_an_errored_worker_on_the_referenced_issue
    snapshot = head_snapshot
    worker = snapshot.fetch("agents").first
    worker["status"] = "errored"

    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "P1-I1 try that again",
      snapshot: snapshot
    )

    assert_equal ["SpawnWorker"], result.fetch("commands").map { |command| command.fetch("type") }
    assert_equal "P1-I1", result.dig("commands", 0, "payload", "issue_id")
    assert_equal "P1-I1-W1", result.dig("commands", 0, "payload", "replace_agent_id")
    refute result.dig("commands", 0, "payload").key?("follow_up_of_agent_id")
  end

  def test_fake_runner_creates_a_new_issue_in_the_referenced_project_for_a_new_goal
    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "P1 telemetry dashboards for release metrics",
      snapshot: head_snapshot
    )

    types = result.fetch("commands").map { |command| command.fetch("type") }
    assert_equal %w[CreateIssue SpawnWorker], types
    assert_equal "P1", result.dig("commands", 0, "payload", "project_id")
    assert_equal "create-issue", result.dig("commands", 1, "payload", "issue_from_command")
  end

  def test_fake_runner_routes_a_product_request_to_the_matching_project_not_the_first_repository
    snapshot = head_snapshot
    snapshot.fetch("projects").first["name"] = "Meringue completed"
    snapshot.fetch("projects") << {
      "id" => "P2",
      "name" => "Shopify storefront",
      "root_path" => "/tmp/shopify-storefront",
      "status" => "working",
      "updated_at" => "2024-01-04T00:00:00Z"
    }

    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "The Shopify checkout integration is completed; update it",
      snapshot: snapshot
    )

    assert_equal "P2", result.dig("commands", 0, "payload", "project_id")
    assert_equal "create-issue", result.dig("commands", 1, "payload", "issue_from_command")
  end

  def test_fake_runner_generates_new_project_names_from_the_repository_readme
    root = head_temp_root
    File.write(File.join(root, "README.md"), "# Shopify storefront\n")
    context = build_head_context(snapshot: Meringue::State::Models.empty_state, cwd: root)

    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "set up checkout integration",
      snapshot: Meringue::State::Models.empty_state,
      context: context
    )

    assert_equal "Shopify", result.dig("commands", 0, "payload", "name")
  end

  def test_harness_runner_owns_a_session_for_one_run_and_closes_it
    raw = JSON.generate(head_result(commands: [kernel_command("AnswerQuestion", "question_id" => "Q4", "answer" => "keep it")]))
    client = HeadResultHarnessClient.new(raw_output: raw)
    project_path = head_temp_root
    runner = Meringue::Heads::HarnessRunner.new(harness_client: client, cwd: project_path, timeout: 5)

    result = runner.run(user_message: "keep the existing branch", snapshot: head_snapshot, question_id: "Q4")

    assert_equal "AnswerQuestion", result.dig("commands", 0, "type")
    assert_equal 1, client.spawned.length
    spawned = client.spawned.first
    assert_equal "head", spawned.fetch("kind")
    assert_equal project_path, spawned.fetch("cwd")
    assert_equal "Meringue Head H?: keep the existing branch", spawned.fetch("session_name")
    assert_equal 1, client.killed.length
    assert_equal 5, client.waits.first.fetch("timeout")
  end

  def test_harness_runner_prompt_contains_the_context_json_and_system_prompt_has_the_reference
    client = HeadResultHarnessClient.new(raw_output: JSON.generate(head_result))
    runner = Meringue::Heads::HarnessRunner.new(harness_client: client, cwd: head_temp_root)

    runner.run(user_message: "keep the existing branch", snapshot: head_snapshot, question_id: "Q4")

    spawned = client.spawned.first
    assert_includes spawned.fetch("prompt"), "Meringue head context JSON:"
    context_json = JSON.parse(spawned.fetch("prompt")[spawned.fetch("prompt").index("{")..])
    assert_equal "keep the existing branch", context_json.fetch("user_message")
    assert_equal "Q4", context_json.fetch("question_id")
    assert_equal "Q4", context_json.dig("routing_context", "question_being_answered", "id")
    assert_equal "P1-I1", context_json.dig("routing_context", "question_being_answered", "issue_id")

    assert_includes spawned.fetch("system_prompt"), "stateless Meringue head agent"
    assert_includes spawned.fetch("system_prompt"), "# Head Agent Kernel Command Reference"
    refute_match(/SECRET_[A-Z_]+/, spawned.fetch("prompt"))
    refute_match(/SECRET_[A-Z_]+/, spawned.fetch("system_prompt"))
  end

  def test_harness_runner_session_lifecycle_methods_are_separately_usable
    client = HeadResultHarnessClient.new(raw_output: "```json\n#{JSON.generate(head_result)}\n```")
    runner = Meringue::Heads::HarnessRunner.new(harness_client: client, cwd: head_temp_root)

    session_ref = runner.spawn_head_session(user_message: "route this", snapshot: head_snapshot)
    assert_equal "fake-head-session", session_ref.fetch("session_id")
    assert_empty client.killed

    result = runner.await_head_result(session_ref)
    assert_equal "Routed the request", result.fetch("title")
    assert_empty client.killed

    assert runner.close_head_session(session_ref)
    assert_equal 1, client.killed.length
    refute runner.close_head_session(nil)
  end

  def test_harness_runner_polls_get_state_when_the_client_has_no_settle_helpers
    client = PollingHarnessClient.new(raw_output: JSON.generate(head_result(title: "Polled")))
    runner = Meringue::Heads::HarnessRunner.new(harness_client: client, cwd: head_temp_root, timeout: 5)

    refute client.respond_to?(:wait_for_settled)
    refute client.respond_to?(:last_assistant_text)
    assert_equal "Polled", runner.run(user_message: "route this", snapshot: head_snapshot).fetch("title")
  end

  def test_harness_runner_raises_invalid_head_result_for_unparseable_output
    client = HeadResultHarnessClient.new(raw_output: "I could not decide, sorry.")
    runner = Meringue::Heads::HarnessRunner.new(harness_client: client, cwd: head_temp_root)

    error = assert_raises(Meringue::Heads::InvalidHeadResultError) do
      runner.run(user_message: "route this", snapshot: head_snapshot)
    end

    assert_equal ["assistant output was not parseable JSON"], error.validation_errors
    # The session is still closed even when parsing fails.
    assert_equal 1, client.killed.length
  end

  def test_harness_runner_parse_helper_accepts_fenced_output
    runner = Meringue::Heads::HarnessRunner.new(harness_client: HeadResultHarnessClient.new(raw_output: ""), cwd: head_temp_root)

    parsed = runner.parse_head_result_text("prose\n```json\n#{JSON.generate(head_result)}\n```")

    assert_equal "Routed the request", parsed.fetch("title")
  end

  def test_pi_runner_defaults_to_the_pi_event_timeout
    runner = Meringue::Heads::PiRunner.new(harness_client: HeadResultHarnessClient.new(raw_output: JSON.generate(head_result)), cwd: head_temp_root)

    assert_equal Meringue::Harness::PiClient::DEFAULT_EVENT_TIMEOUT, runner.timeout
    assert_equal "Meringue Head", runner.session_name_prefix
    assert_equal "Routed the request", runner.run(user_message: "route this", snapshot: head_snapshot).fetch("title")
  end

  def test_kernel_drives_a_session_owning_runner_and_records_its_session
    env = build_head_environment
    raw = JSON.generate(
      head_result(
        commands: [
          kernel_command("AddProject", "path" => env.project_path, "name" => "demo-project"),
          kernel_command("CreateIssue", "project_id" => "P1", "title" => "Session-owning head cycle")
        ]
      )
    )
    client = HeadResultHarnessClient.new(raw_output: raw)
    runner = Meringue::Heads::HarnessRunner.new(harness_client: client, cwd: env.project_path, timeout: 5)
    engine = rebuilt_engine(env, runner)

    payload = Meringue::Heads::PromptLoop.new(engine: engine).call("register this project and open an issue")

    assert_equal "accepted", payload.dig("spawn_head_result", "status")
    assert_equal %w[AddProject CreateIssue],
                 payload.dig("apply_head_result", "result", "command_results").map { |result| result.fetch("command_type") }
    assert_equal ["P1-I1"], env.state.fetch("issues").map { |issue| issue.fetch("id") }

    # The kernel spawned the session, tracked it on the head record, and released it.
    assert_equal 1, client.spawned.length
    assert_equal "head", client.spawned.first.fetch("kind")
    # The session is active while the head lives; releasing it happens during cleanup.
    assert_equal "active", payload.dig("spawn_head_result", "result", "harness_metadata", "head_session_state")
    assert_equal "fake-head-session", payload.dig("spawn_head_result", "result", "harness_session_id")
    assert_empty env.agents(type: "head")
  end

  def test_kernel_reports_a_session_runner_failure_and_releases_the_head
    runner = ScriptedSessionHeadRunner.new(await_error: Timeout::Error.new("head session never settled"))
    env = build_head_environment(runner: runner)

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("route this")

    assert_equal "failed", payload.dig("spawn_head_result", "status")
    assert_includes payload.dig("spawn_head_result", "errors"), "Timeout::Error"
    assert_equal 1, runner.spawned_sessions.length
    assert_equal "errored", env.agents(type: "head").first.fetch("status")
  end

  private

  def rebuilt_engine(env, runner)
    Meringue::Kernel::Engine.new(
      store: env.store,
      harness_client: env.harness_client,
      head_runner: runner,
      workspace_manager: env.workspace_manager,
      cwd: env.project_path,
      default_harness_provider: "fake",
      config_path: File.join(env.root, "config.toml")
    )
  end
end
