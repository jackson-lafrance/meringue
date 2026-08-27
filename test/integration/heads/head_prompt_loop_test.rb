# frozen_string_literal: true

require "test_helper"
require "support/heads_support"

# Full fake head cycles through Heads::PromptLoop: user message -> head spawn ->
# HeadResult -> kernel-validated commands -> state mutation -> head torn down.
# Nothing here starts a real harness process.
class HeadPromptLoopTest < Minitest::Test
  include HeadsSupport

  def test_full_fake_head_cycle_mutates_state_and_kills_the_head
    env = build_head_environment
    events = []

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("add a docs cleanup task") do |event|
      events << event
    end

    assert_equal "head_loop_iteration", payload.fetch("event")
    assert_equal "natural_language", payload.dig("route", "kind")
    assert_equal "SpawnHead", payload.dig("route", "commands", 0, "type")
    assert_equal "add a docs cleanup task", payload.dig("route", "commands", 0, "payload", "user_message")
    assert_equal "accepted", payload.dig("spawn_head_result", "status")
    assert_equal "H1", payload.dig("spawn_head_result", "target_id")
    assert_equal "accepted", payload.dig("apply_head_result", "status")
    assert payload.fetch("state_mutated")

    command_types = payload.dig("apply_head_result", "result", "command_results").map { |result| result.fetch("command_type") }
    assert_equal %w[AddProject CreateIssue SpawnWorker], command_types
    assert(payload.dig("apply_head_result", "result", "command_results").all? { |result| result.fetch("status") == "accepted" })

    state = env.state
    assert_equal [env.project_path], state.fetch("projects").map { |project| project.fetch("root_path") }
    assert_equal ["P1-I1"], state.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal "H1", state.fetch("issues").first.fetch("originating_head_id")
    assert_equal [["P1-I1-W1", "worker", "working"]],
                 state.fetch("agents").map { |agent| agent.values_at("id", "type", "status") }

    # The head is torn down once its batch is applied.
    assert_equal "H1", payload.dig("apply_head_result", "result", "head_cleanup", "removed_agent_id")
    assert_equal "head_result_applied", payload.dig("apply_head_result", "result", "head_cleanup", "reason")
    assert_empty env.agents(type: "head")

    assert_equal %w[head_completed head_result_applied], events.map { |event| event.fetch("event") }
    assert_equal "H1", events.first.fetch("head_id")
    assert_equal "Add a docs cleanup task", events.first.dig("head_result", "title")
    assert_equal "accepted", events.last.dig("apply_result", "status")
  end

  def test_full_text_only_head_cycle_answers_without_a_command_worker_or_no_op
    runner = ScriptedHeadRunner.new(
      results: [
        head_result(
          title: "Explain the label",
          summary: "Answered from stable Meringue behavior.",
          response: "“Waiting on W1” means the queued worker will start after W1 settles.",
          commands: [],
          questions: []
        )
      ]
    )
    env = build_head_environment(runner: runner)
    events = []

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("What does waiting on W1 mean?") { |event| events << event }

    assert_equal "accepted", payload.dig("apply_head_result", "status")
    assert_equal "“Waiting on W1” means the queued worker will start after W1 settles.", payload.dig("apply_head_result", "result", "response")
    assert_empty payload.dig("apply_head_result", "result", "command_results")
    assert_empty env.state.fetch("projects")
    assert_empty env.state.fetch("issues")
    assert_empty env.agents(type: "worker")
    assert_empty env.agents(type: "head"), "the response-only head still has the normal short lifetime"
    assert_equal %w[head_completed head_result_applied], events.map { |event| event.fetch("event") }

    response_log = env.state.fetch("logs").find { |entry| entry.dig("details", "kind") == "head_response" }
    refute_nil response_log
    assert_equal "“Waiting on W1” means the queued worker will start after W1 settles.", response_log.fetch("message")
    refute env.state.fetch("logs").any? { |entry| entry.dig("details", "kind") == "unrouted_user_message" }
    refute env.state.fetch("logs").any? { |entry| entry.fetch("message", "").include?("intentionally routed no work") }
  end

  def test_automatic_project_name_preserves_the_product_capitalization
    env = build_head_environment
    File.write(File.join(env.project_path, "README.md"), "# Meringue\n\nThe product description is not its name.\n")

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("add a docs cleanup task")

    assert_equal "accepted", payload.dig("apply_head_result", "status")
    assert_equal "Meringue", env.state.fetch("projects").first.fetch("name")
  end

  def test_head_receives_user_message_snapshot_and_context
    runner = ScriptedHeadRunner.new(results: [head_result(commands: [])])
    env = build_head_environment(runner: runner)

    Meringue::Heads::PromptLoop.new(engine: env.engine).call("why did the worker stall?")

    assert_equal 1, runner.calls.length
    call = runner.calls.first
    assert_equal "why did the worker stall?", call.fetch("user_message")
    assert_nil call.fetch("question_id")

    context = call.fetch("context")
    assert_instance_of Meringue::Heads::Context, context
    assert_equal "H1", context.head_id
    assert_equal env.project_path, context.cwd
    assert_equal env.state_path, context.state_path
    assert_equal "why did the worker stall?", context.to_prompt_h.fetch("user_message")

    # The snapshot is the state as of spawn time, including the head itself.
    snapshot_head = call.fetch("snapshot").fetch("agents").find { |agent| agent.fetch("id") == "H1" }
    assert_equal "head", snapshot_head.fetch("type")
    assert_equal "why did the worker stall?", snapshot_head.dig("harness_metadata", "head_request", "user_message")
  end

  def test_head_cannot_mutate_state_or_project_files_itself
    env = nil
    observed = {}
    runner = ScriptedHeadRunner.new do |call|
      snapshot = call.fetch("snapshot")
      snapshot.fetch("projects") << { "id" => "P99", "name" => "ghost" }
      snapshot.fetch("issues") << { "id" => "P99-I1" }
      observed["persisted_projects"] = env.state.fetch("projects").length
      observed["persisted_issues"] = env.state.fetch("issues").length
      head_result(
        commands: [
          kernel_command("AddProject", "path" => call.fetch("context").cwd, "name" => "demo-project"),
          kernel_command("CreateIssue", "project_id" => "P1", "title" => "Cleanup docs")
        ]
      )
    end
    env = build_head_environment(runner: runner)
    files_before = env.project_entries

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("register this project and open an issue")

    # Nothing the head did to its snapshot reached the store.
    assert_equal 0, observed.fetch("persisted_projects")
    assert_equal 0, observed.fetch("persisted_issues")
    refute payload.fetch("state_mutated") == false
    assert_equal %w[P1], env.state.fetch("projects").map { |project| project.fetch("id") }
    assert_equal %w[P1-I1], env.state.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal files_before, env.project_entries
  end

  def test_questions_only_head_result_records_an_open_question_without_commands
    runner = ScriptedHeadRunner.new(
      results: [
        head_result(
          title: "Needs clarification",
          summary: "Two issues are plausible.",
          commands: [],
          questions: [{ "question" => "Did you mean the docs issue or the answering issue?", "context" => "Both are open." }]
        )
      ]
    )
    env = build_head_environment(runner: runner)

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("fix that thing we discussed")

    assert_equal "accepted", payload.dig("apply_head_result", "status")
    assert_equal ["Q1"], payload.dig("apply_head_result", "result", "question_ids")
    assert_empty payload.dig("apply_head_result", "result", "command_results")

    question = env.state.fetch("questions").first
    assert_equal "Q1", question.fetch("id")
    assert_equal "H1", question.fetch("head_id")
    assert_equal "open", question.fetch("status")
    assert_nil question.fetch("answer")
    assert_equal "Did you mean the docs issue or the answering issue?", question.fetch("question")
    assert_empty env.agents(type: "head")
  end

  def test_answering_a_question_spawns_a_head_to_route_the_unblocked_work
    runner = ScriptedHeadRunner.new do |call|
      if call.fetch("question_id", nil) == "Q1"
        head_result(
          commands: [
            { "type" => "AddProject", "payload" => { "path" => call.fetch("context").cwd, "name" => "proj" } },
            { "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Keep existing branch" } }
          ]
        )
      else
        head_result(commands: [], questions: [{ "question" => "Keep the branch?", "context" => "two branches" }])
      end
    end
    env = build_head_environment(runner: runner)
    prompt_loop = Meringue::Heads::PromptLoop.new(engine: env.engine)
    prompt_loop.call("which branch should the worker use?")

    payload = prompt_loop.call('/answer Q1 keep the existing branch')
    answer_result = payload.fetch("command_results").first
    routing = answer_result.dig("result", "routing")

    assert_equal "slash_command_applied", payload.fetch("event")
    assert_equal "AnswerQuestion", payload.dig("route", "commands", 0, "type")
    assert_equal "Q1", payload.dig("route", "commands", 0, "payload", "question_id")
    assert_equal "keep the existing branch", payload.dig("route", "commands", 0, "payload", "answer")
    assert_equal ["accepted"], payload.fetch("command_results").map { |result| result.fetch("status") }
    assert_equal "Answered question Q1 and spawned head H2 to act on the answer.", payload.fetch("summary")
    assert_equal %w[AddProject CreateIssue], routing.fetch("command_results").map { |result| result.fetch("command_type") }

    question = env.state.fetch("questions").first
    assert_equal "answered", question.fetch("status")
    assert_equal "keep the existing branch", question.fetch("answer")
    assert_equal 2, runner.calls.length
    assert_equal ["Keep existing branch"], env.state.fetch("issues").map { |issue| issue.fetch("title") }
  end

  def test_answering_an_unknown_question_is_rejected
    env = build_head_environment
    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("/answer Q9 nope")

    assert_equal ["rejected"], payload.fetch("command_results").map { |result| result.fetch("status") }
    assert_equal ["question_not_found"], payload.fetch("command_results").first.fetch("errors")
    refute payload.fetch("state_mutated")
  end

  def test_slash_commands_are_logged_with_their_output
    env = build_head_environment
    Meringue::Heads::PromptLoop.new(engine: env.engine).call("/questions")

    messages = env.state.fetch("logs").map { |log| log.fetch("message") }
    assert_includes messages, "User ran command: /questions"
    assert(messages.any? { |message| message.start_with?("Command output: ListQuestions: accepted") })
  end

  def test_runner_failure_is_reported_without_mutating_state
    runner = ScriptedHeadRunner.new(error: Timeout::Error.new("timed out waiting for head session to settle"))
    env = build_head_environment(runner: runner)

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("do the thing")

    assert_equal "Head spawn failed or was rejected; proposed commands were not applied.", payload.fetch("summary")
    refute payload.fetch("state_mutated")
    assert_equal "failed", payload.dig("spawn_head_result", "status")
    assert_includes payload.dig("spawn_head_result", "errors"), "Timeout::Error"
    refute payload.key?("apply_head_result")

    head = env.agents(type: "head").first
    assert_equal "errored", head.fetch("status")
    assert_empty env.state.fetch("issues")
    assert_includes env.state.fetch("logs").map { |log| log.fetch("message") },
                    "Head H1 failed: timed out waiting for head session to settle"
  end

  def test_invalid_head_result_error_from_the_runner_is_surfaced
    runner = ScriptedHeadRunner.new(
      error: Meringue::Heads::InvalidHeadResultError.new(
        raw_output: "I could not decide.",
        validation_errors: ["assistant output was not parseable JSON"]
      )
    )
    env = build_head_environment(runner: runner)

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("do the thing")

    assert_equal "failed", payload.dig("spawn_head_result", "status")
    assert_includes payload.dig("spawn_head_result", "errors"), "Meringue::Heads::InvalidHeadResultError"
    assert_equal "errored", env.agents(type: "head").first.fetch("status")
  end

  # Current behaviour: a runner that returns nothing leaves the head "completed"
  # in state with an empty summary and no applied batch.
  def test_runner_returning_nothing_produces_an_empty_summary
    env = build_head_environment(runner: ScriptedHeadRunner.new(results: [nil]))

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("do the thing")

    assert_equal "", payload.fetch("summary")
    assert_equal "accepted", payload.dig("spawn_head_result", "status")
    refute payload.key?("apply_head_result")
    assert_equal [["H1", "head", "completed"]],
                 env.state.fetch("agents").map { |agent| agent.values_at("id", "type", "status") }
  end

  def test_malformed_head_result_shape_is_rejected_by_the_kernel
    env = build_head_environment(runner: ScriptedHeadRunner.new(results: [{ "title" => "t", "summary" => "s" }]))

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("do the thing")

    assert_equal "rejected", payload.dig("apply_head_result", "status")
    assert_equal ["head_result.commands must be an array", "head_result.questions must be an array"],
                 payload.dig("apply_head_result", "errors")
    refute payload.fetch("state_mutated")
    assert_empty env.state.fetch("issues")
  end

  def test_unknown_command_types_are_rejected_and_block_head_cleanup
    env = build_head_environment(
      runner: ScriptedHeadRunner.new(results: [head_result(commands: [kernel_command("DefinitelyNotAKernelCommand", {})])])
    )

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("do the thing")

    command_result = payload.dig("apply_head_result", "result", "command_results").first
    assert_equal "rejected", command_result.fetch("status")
    assert_equal ["unknown_command"], command_result.fetch("errors")
    assert_equal "partially_applied", payload.dig("apply_head_result", "result", "head_cleanup", "reason")
    assert_equal "blocked", env.agents(type: "head").first.fetch("status")
  end

  def test_multiple_concurrent_heads_do_not_block_user_input
    gate = Queue.new
    started = Queue.new
    runner = ScriptedHeadRunner.new do |call|
      started << call.fetch("user_message")
      gate.pop
      head_result(commands: [])
    end
    env = build_head_environment(runner: runner)
    prompt_loop = Meringue::Heads::PromptLoop.new(engine: env.engine)

    threads = ["first goal", "second goal"].map { |message| Thread.new { prompt_loop.call(message) } }
    wait_until(description: "two heads to start thinking") { started.size == 2 }

    # A slash command still runs to completion while both heads are mid-flight.
    slash_payload = prompt_loop.call("/questions")
    assert_equal "slash_command_applied", slash_payload.fetch("event")
    assert_equal "Loaded 0 questions.", slash_payload.fetch("summary")

    in_flight = env.agents(type: "head")
    assert_equal %w[H1 H2], in_flight.map { |head| head.fetch("id") }.sort
    assert(in_flight.all? { |head| head.fetch("status") == "working" })

    2.times { gate << true }
    payloads = threads.map { |thread| thread.join(15) && thread.value }

    assert_equal %w[accepted accepted], payloads.map { |payload| payload.dig("apply_head_result", "status") }
    assert_equal %w[H1 H2], payloads.map { |payload| payload.dig("spawn_head_result", "target_id") }.sort
    assert_empty env.agents(type: "head")
    assert_equal ["first goal", "second goal"],
                 runner.calls.map { |call| call.fetch("user_message") }.sort
  end

  def test_waiting_for_workers_settles_them_and_records_pull_requests
    harness_client = SettlingHarnessClient.new(assistant_text: "Opened https://example.test/pr/9")
    env = build_head_environment(harness_client: harness_client)
    events = []

    payload = Meringue::Heads::PromptLoop.new(
      engine: env.engine,
      wait_for_workers: true,
      worker_wait_timeout: 5
    ).call("add a docs cleanup task") { |event| events << event }

    wait_result = payload.fetch("worker_wait_results").first
    assert_equal "P1-I1-W1", wait_result.fetch("agent_id")
    assert_equal "settled", wait_result.fetch("status")
    assert_equal 1, wait_result.fetch("event_count")
    assert_equal "Opened https://example.test/pr/9", wait_result.fetch("last_assistant_text")

    assert_equal 1, harness_client.waits.length
    assert_equal 5, harness_client.waits.first.fetch("timeout")
    assert_equal "fake", harness_client.waits.first.dig("session_ref", "harness")

    assert_equal %w[head_completed head_result_applied worker_wait_started worker_completed],
                 events.map { |event| event.fetch("event") }
    assert_equal "completed", env.agents(type: "worker").first.fetch("status")
  end

  def test_worker_wait_failures_are_captured_per_worker
    harness_client = SettlingHarnessClient.new
    harness_client.define_singleton_method(:wait_for_settled) do |_session_ref, timeout: nil|
      raise IOError, "session vanished"
    end
    env = build_head_environment(harness_client: harness_client)
    events = []

    payload = Meringue::Heads::PromptLoop.new(
      engine: env.engine,
      wait_for_workers: true
    ).call("add a docs cleanup task") { |event| events << event }

    wait_result = payload.fetch("worker_wait_results").first
    assert_equal "error", wait_result.fetch("status")
    assert_equal "IOError", wait_result.dig("error", "class")
    assert_equal "session vanished", wait_result.dig("error", "message")
    assert_includes events.map { |event| event.fetch("event") }, "worker_wait_failed"
    assert_equal "working", env.agents(type: "worker").first.fetch("status")
  end

  # `Engine#harness_client` used to be shadowed by a second definition below the `private`
  # keyword, so this whole path raised `NoMethodError: private method 'harness_client'`.
  def test_worker_waiting_works_against_the_real_engine
    harness_client = SettlingHarnessClient.new(assistant_text: "done")
    env = build_head_environment(harness_client: harness_client)

    assert_respond_to env.engine, :harness_client
    assert_respond_to env.engine, :head_runner

    payload = Meringue::Heads::PromptLoop.new(
      engine: env.engine,
      wait_for_workers: true,
      worker_wait_timeout: 5
    ).call("add a docs cleanup task")

    wait_result = payload.fetch("worker_wait_results").first

    assert_equal "P1-I1-W1", wait_result.fetch("agent_id")
    assert_equal "settled", wait_result.fetch("status")
    assert_equal "done", wait_result.fetch("last_assistant_text")
    assert_equal 1, env.agents(type: "worker").length
    assert_equal "completed", env.agents(type: "worker").first.fetch("status")
  end

  def test_engine_mutex_is_shared_so_slash_commands_serialize
    env = build_head_environment
    mutex = Mutex.new
    prompt_loop = Meringue::Heads::PromptLoop.new(engine: env.engine, engine_mutex: mutex)

    mutex.lock
    thread = Thread.new { prompt_loop.call("/questions") }
    wait_until(description: "the slash command to block on the shared mutex") { thread.status == "sleep" }
    refute thread.join(0.05)
    mutex.unlock

    assert thread.join(10)
    assert_equal "slash_command_applied", thread.value.fetch("event")
  end

  def test_state_summary_reports_the_shape_of_the_mutated_state
    env = build_head_environment
    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("add a docs cleanup task")
    summary = payload.fetch("state_summary")

    assert_equal 1, summary.fetch("project_count")
    assert_equal 1, summary.fetch("issue_count")
    assert_equal 1, summary.fetch("agent_count")
    assert_equal 0, summary.fetch("active_head_count")
    assert_equal 1, summary.fetch("working_worker_count")
    assert_equal 0, summary.fetch("open_question_count")
    assert_equal ["P1-I1"], summary.fetch("recent_issues").map { |issue| issue.fetch("id") }
  end
end
