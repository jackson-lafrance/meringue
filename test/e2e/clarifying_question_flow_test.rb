# frozen_string_literal: true

require "test_helper"
require "support/e2e_support"

# Flow 4: a head asks for a clarification, the question is stored open exactly once, the user
# answers it, and a head that receives the answer plus the question's context resumes the work.
class E2eClarifyingQuestionFlowTest < Minitest::Test
  include E2eSupport

  def setup
    setup_e2e
  end

  def teardown
    teardown_e2e
  end

  def test_clarifying_question_is_stored_once_then_answered_and_work_proceeds
    head_runner.script do
      {
        "title" => "Speed up the test suite",
        "summary" => "Registered the project and started the slow-test investigation.",
        "commands" => [
          E2eSupport.add_project_command(project_root, "demo-project"),
          E2eSupport.create_issue_command(project_id: "P1", title: "Speed up the test suite", description: "Suite takes 10 minutes."),
          E2eSupport.spawn_worker_command(issue_id: "P1-I1", title: "Profile slow tests", prompt: "Profile the slowest tests.")
        ]
      }
    end

    engine = build_engine
    prompt_loop = build_prompt_loop(engine)
    prompt_loop.call("The test suite is too slow, look into it")

    # The next message is ambiguous, so the head asks one clarification. Heads sometimes state
    # the same clarification twice (questions array plus an AskQuestion command); the kernel must
    # still record exactly one question.
    clarification = "Should I parallelize the suite or delete the slowest tests?"
    head_runner.script do |call|
      head_id = call.fetch("context").head_id
      {
        "title" => "Need a decision before continuing",
        "summary" => "Asked the user which direction to take on P1-I1.",
        "commands" => [
          {
            "type" => "AskQuestion",
            "payload" => {
              "head_id" => head_id,
              "question" => clarification,
              "context" => "P1-I1 has a worker profiling the suite.",
              "project_id" => "P1",
              "issue_id" => "P1-I1"
            }
          }
        ],
        "questions" => [
          {
            "question" => clarification,
            "context" => "P1-I1 has a worker profiling the suite.",
            "project_id" => "P1",
            "issue_id" => "P1-I1"
          }
        ]
      }
    end
    prompt_loop.call("Make it faster somehow")

    asked_state = reloaded_state
    assert_equal 1, asked_state.fetch("questions").length, "one clarification must produce one question record"
    stored = question(asked_state, "Q1")
    assert_equal "open", stored.fetch("status")
    assert_equal clarification, stored.fetch("question")
    assert_equal "P1", stored.fetch("project_id")
    assert_equal "P1-I1", stored.fetch("issue_id")
    assert_nil stored.fetch("answer")
    assert_logged(/Question Q1: #{Regexp.escape(clarification)}/, asked_state)
    assert_equal 1, log_messages(asked_state).count { |message| message.start_with?("Question Q1:") }

    # The user answers the open question from the chat prompt.
    answer_result = prompt_loop.call(%(/answer Q1 "Parallelize the suite, do not delete tests"))
    assert_equal "slash_command_applied", answer_result.fetch("event")
    assert_equal ["accepted"], answer_result.fetch("command_results").map { |result| result.fetch("status") }

    answered_state = reloaded_state
    assert_equal "answered", question(answered_state, "Q1").fetch("status")
    assert_equal "Parallelize the suite, do not delete tests", question(answered_state, "Q1").fetch("answer")
    assert_equal 1, answered_state.fetch("questions").length
    assert_logged(/Answered question Q1\./, answered_state)

    # A head that receives the answer gets the full question record as context and routes the
    # work back onto the issue the question came from.
    head_runner.script do |call|
      being_answered = call.fetch("context").to_prompt_h.fetch("routing_context").fetch("question_being_answered")
      assert_equal "Q1", being_answered.fetch("id")
      assert_equal clarification, being_answered.fetch("question")
      assert_equal "P1-I1 has a worker profiling the suite.", being_answered.fetch("context")
      assert_equal "P1", being_answered.fetch("project_id")
      assert_equal "P1-I1", being_answered.fetch("issue_id")
      assert_equal "answered", being_answered.fetch("status")
      assert_equal "Parallelize the suite, do not delete tests", being_answered.fetch("answer")

      {
        "title" => "Continue with parallelization",
        "summary" => "Reused P1-I1 and prompted its existing worker with the user's answer.",
        "commands" => [
          E2eSupport.prompt_agent_command(
            agent_id: "P1-I1-W1",
            prompt: "The user chose parallelization: parallelize the suite, do not delete tests.",
            mode: "follow_up"
          )
        ]
      }
    end

    spawn = engine.apply(
      "type" => "SpawnHead",
      "payload" => { "user_message" => "Parallelize the suite, do not delete tests", "question_id" => "Q1" }
    )
    assert_equal "accepted", spawn.fetch("status")
    head_result = spawn.fetch("result").fetch("harness_metadata").fetch("head_result")
    applied = engine.apply(
      "type" => "ApplyHeadResult",
      "payload" => { "head_id" => spawn.fetch("target_id"), "head_result" => head_result }
    )
    assert_equal "accepted", applied.fetch("status")

    final = reloaded_state
    # Work proceeded on the original issue: no new issue and no second worker.
    assert_equal ["P1-I1"], final.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal ["P1-I1-W1"], workers(final).map { |worker| worker.fetch("id") }
    worker = agent(final, "P1-I1-W1")
    assert_equal "follow_up", worker.fetch("harness_metadata").fetch("last_prompt_mode")
    assert_equal(
      ["The user chose parallelization: parallelize the suite, do not delete tests."],
      harness_client.prompts_for(worker.fetch("harness_session_id")).map { |prompt| prompt.fetch("prompt") }
    )
    assert_logged(/Queued a follow-up for worker P1-I1-W1 on P1-I1\./, final)

    persisted = raw_persisted_state
    assert_equal 1, persisted.fetch("questions").length
    assert_equal "answered", persisted.fetch("questions").first.fetch("status")
    assert_equal 1, persisted.fetch("counters").fetch("questions")
  end
end
