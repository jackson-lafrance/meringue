# frozen_string_literal: true

require "test_helper"
require "support/heads_support"

# The head-contract side of answering open questions: what a head is told about
# open questions, and what happens when a head proposes AnswerQuestion together
# with routing commands (the implicit-answer flow) versus leaving questions alone.
class HeadQuestionAnsweringTest < Minitest::Test
  include HeadsSupport

  def test_head_result_can_answer_a_question_and_route_work_in_one_batch
    env = seeded_environment(
      head_result(
        title: "Answered Q1 and continued the worker",
        summary: "Treated the reply as the answer to Q1 and prompted the existing worker.",
        commands: [
          kernel_command("AnswerQuestion", "question_id" => "Q1", "answer" => "keep the existing branch"),
          kernel_command("PromptAgent", "agent_id" => "P1-I1-W1", "prompt" => "The user answered: keep the existing branch", "mode" => "normal")
        ]
      )
    )

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("keep the existing branch")

    command_results = payload.dig("apply_head_result", "result", "command_results")
    assert_equal %w[AnswerQuestion PromptAgent], command_results.map { |result| result.fetch("command_type") }
    assert_equal %w[accepted accepted], command_results.map { |result| result.fetch("status") }

    question = env.state.fetch("questions").find { |candidate| candidate.fetch("id") == "Q1" }
    assert_equal "answered", question.fetch("status")
    assert_equal "keep the existing branch", question.fetch("answer")
    # The question keeps the scope it carried.
    assert_equal "P1", question.fetch("project_id")
    assert_equal "P1-I1", question.fetch("issue_id")

    worker_metadata = env.state.fetch("agents").find { |agent| agent.fetch("id") == "P1-I1-W1" }.fetch("harness_metadata")
    assert_equal "resume_session", worker_metadata.fetch("routing_action")
    assert_equal 3, worker_metadata.fetch("prompt_count")
    assert_empty env.agents(type: "head")
  end

  def test_answering_a_question_can_also_spawn_a_worker_on_the_question_issue
    env = seeded_environment(
      head_result(
        commands: [
          kernel_command("AnswerQuestion", "question_id" => "Q2", "answer" => "start with docs/"),
          kernel_command("SpawnWorker", "issue_id" => "P1-I2", "title" => "Clean docs/", "prompt" => "Clean docs/ first, per the user's answer.")
        ]
      )
    )

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("start with docs/")

    assert_equal %w[AnswerQuestion SpawnWorker],
                 payload.dig("apply_head_result", "result", "command_results").map { |result| result.fetch("command_type") }
    assert_equal "answered", env.state.fetch("questions").find { |question| question.fetch("id") == "Q2" }.fetch("status")

    spawned = env.state.fetch("agents").find { |agent| agent.fetch("issue_id") == "P1-I2" }
    assert_equal "P1-I2-W1", spawned.fetch("id")
    assert_equal "working", spawned.fetch("status")
  end

  def test_open_questions_stay_open_when_the_head_routes_an_unrelated_new_goal
    env = seeded_environment(
      head_result(
        title: "New goal",
        summary: "This is a brand-new goal, so the open questions were left alone.",
        commands: [kernel_command("CreateIssue", "project_id" => "P1", "title" => "Add telemetry dashboards")]
      )
    )

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("separately, build telemetry dashboards")

    assert_equal ["CreateIssue"], payload.dig("apply_head_result", "result", "command_results").map { |result| result.fetch("command_type") }
    assert_equal %w[open open], env.state.fetch("questions").map { |question| question.fetch("status") }
    assert(env.state.fetch("questions").all? { |question| question.fetch("answer").nil? })
  end

  def test_ambiguous_reply_can_ask_a_new_question_without_closing_the_open_ones
    env = seeded_environment(
      head_result(
        title: "Needs disambiguation",
        summary: "Two open questions could match this reply, so the head asked instead of guessing.",
        commands: [],
        questions: [{ "question" => "Is that answering Q1 (branch) or Q2 (docs directory)?", "context" => "Both are open." }]
      )
    )

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("the first one")

    assert_equal ["Q3"], payload.dig("apply_head_result", "result", "question_ids")
    statuses = env.state.fetch("questions").to_h { |question| [question.fetch("id"), question.fetch("status")] }
    assert_equal({ "Q1" => "open", "Q2" => "open", "Q3" => "open" }, statuses)
  end

  def test_answer_question_for_an_unknown_id_is_rejected_and_blocks_head_cleanup
    env = seeded_environment(
      head_result(commands: [kernel_command("AnswerQuestion", "question_id" => "Q99", "answer" => "whatever")])
    )

    payload = Meringue::Heads::PromptLoop.new(engine: env.engine).call("keep the existing branch")

    command_result = payload.dig("apply_head_result", "result", "command_results").first
    assert_equal "rejected", command_result.fetch("status")
    assert_equal ["question_not_found"], command_result.fetch("errors")
    assert_equal %w[open open], env.state.fetch("questions").map { |question| question.fetch("status") }
    assert_equal "blocked", env.agents(type: "head").first.fetch("status")
  end

  def test_answer_question_without_an_answer_is_rejected
    env = seeded_environment(
      head_result(commands: [kernel_command("AnswerQuestion", "question_id" => "Q1")])
    )

    command_result = Meringue::Heads::PromptLoop.new(engine: env.engine)
                       .call("keep the existing branch")
                       .dig("apply_head_result", "result", "command_results").first

    assert_equal "rejected", command_result.fetch("status")
    assert_equal ["answer is required"], command_result.fetch("errors")
    assert_equal "open", env.state.fetch("questions").first.fetch("status")
  end

  def test_head_context_for_an_implicit_reply_lists_the_question_ids_it_could_answer
    runner = ScriptedHeadRunner.new(results: [head_result(commands: [])])
    env = seeded_environment(nil, runner: runner)

    Meringue::Heads::PromptLoop.new(engine: env.engine).call("ANSWERING Q1 keep the existing branch")

    context = runner.calls.first.fetch("context")
    payload = context.to_prompt_h

    # What a head can use today to infer an implicit answer.
    assert_equal 2, payload.dig("current_state_summary", "open_question_count")
    assert_includes payload.dig("routing_context", "explicit_references").fetch("known_ids"), "Q1"
    open_questions = runner.calls.first.fetch("snapshot").fetch("questions")
                           .select { |question| question.fetch("status") == "open" }
    assert_equal %w[Q1 Q2], open_questions.map { |question| question.fetch("id") }

    assert_nil payload.fetch("question_id")
    answered = payload.dig("routing_context", "question_being_answered")
    assert_equal "Q1", answered.fetch("id")
    assert_equal "P1-I1", answered.fetch("issue_id")
    assert_equal "This message appears to answer this open question. Propose AnswerQuestion for it with the user's answer, then route the work it unblocks in the same HeadResult.",
                 answered.fetch("instruction")

    open_questions = payload.dig("routing_context", "open_questions")
    assert_equal %w[Q1 Q2], open_questions.map { |question| question.fetch("id") }
    assert_equal 2, payload.dig("current_state_summary", "open_question_count")
  end

  def test_question_id_is_passed_through_spawn_head_to_the_head_context
    runner = ScriptedHeadRunner.new(results: [head_result(commands: [])])
    env = seeded_environment(nil, runner: runner)

    result = env.engine.apply(
      "type" => "SpawnHead",
      "payload" => { "user_message" => "keep the existing branch", "question_id" => "Q1" }
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal "Q1", runner.calls.first.fetch("question_id")
    payload = runner.calls.first.fetch("context").to_prompt_h
    assert_equal "Q1", payload.fetch("question_id")
    assert_equal "P1-I1", payload.dig("routing_context", "question_being_answered", "issue_id")
    assert_equal "Should the worker keep the existing branch or start a new one?",
                 payload.dig("routing_context", "question_being_answered", "question")
  end

  def test_spawn_head_with_an_unknown_question_id_is_rejected
    env = seeded_environment(nil)

    result = env.engine.apply(
      "type" => "SpawnHead",
      "payload" => { "user_message" => "keep the existing branch", "question_id" => "Q99" }
    )

    assert_equal "rejected", result.fetch("status")
    assert_equal ["question_not_found"], result.fetch("errors")
    assert_empty env.agents(type: "head")
  end

  private

  # A project/issue/worker/question state where Q1 and Q2 are open, plus a head
  # runner that returns the supplied HeadResult.
  def seeded_environment(scripted_result, runner: nil)
    runner ||= ScriptedHeadRunner.new(results: [scripted_result])
    env = build_head_environment(runner: runner)
    state = head_snapshot
    state.fetch("projects").first["root_path"] = env.project_path
    state.fetch("questions")[0] = state.fetch("questions")[0].merge("id" => "Q1", "head_id" => nil)
    state.fetch("questions")[1] = state.fetch("questions")[1].merge("id" => "Q2", "head_id" => nil)
    state.fetch("agents").reject! { |agent| agent.fetch("type") == "head" }
    state.fetch("counters")["questions"] = 2
    state.fetch("counters")["heads"] = 0
    env.store.save(normalized_seed_state(state))
    env
  end
end
