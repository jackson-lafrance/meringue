# frozen_string_literal: true

require "test_helper"
require "support/input_support"

# End-to-end tests for answering an open question from the input layer: the
# /answer slash command, the AnswerQuestion kernel command, SpawnHead's
# question_id plumbing, and the head context a question-answering head receives.
#
# These tests assert the complete answer flow: answers are recorded, follow-up
# heads receive the question context, and implicit replies expose candidate
# questions to head routing.
class InputQuestionAnswerFlowTest < Minitest::Test
  include InputSupport

  QUESTION_TEXT = "Which environment should the fix target?"

  def test_answering_an_open_question_records_the_answer_and_closes_it
    input_sandbox do |sandbox|
      open_question(sandbox)

      payload = sandbox.submit('/answer Q1 "use the staging environment"')

      assert_equal "slash_command_applied", payload.fetch("event")
      assert_equal [%w[AnswerQuestion accepted]], sandbox.command_result_pairs(payload)
      assert_equal "Answered question Q1 and spawned head H2 to act on the answer.", payload.fetch("summary")
      assert payload.fetch("state_mutated")

      question = sandbox.question("Q1")
      assert_equal "answered", question.fetch("status")
      assert_equal "use the staging environment", question.fetch("answer")
      assert_empty sandbox.open_questions
    end
  end

  def test_answering_a_question_logs_the_user_command_and_the_kernel_result
    input_sandbox do |sandbox|
      open_question(sandbox)
      sandbox.submit('/answer Q1 "use the staging environment"')

      messages = sandbox.state.fetch("logs").map { |log| log.fetch("message") }

      assert(messages.any? { |message| message.include?('User ran command: /answer Q1 "use the staging environment"') })
      assert_includes messages, "Answered question Q1."
      refute(messages.any? { |message| message.include?("Answered Q1: use the staging environment") })
    end
  end

  def test_answering_a_question_spawns_a_head_that_routes_follow_up_work
    input_sandbox do |sandbox|
      open_question(sandbox)
      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Route answered question",
          summary: "Created the issue unlocked by the answer.",
          commands: [
            { "type" => "AddProject", "payload" => { "path" => sandbox.project_path, "name" => "proj" } },
            { "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Fix login in staging" } }
          ]
        )
      )
      head_calls_before = sandbox.head_runner.calls.length

      payload = sandbox.submit('/answer Q1 "use the staging environment"')
      answer_result = sandbox.command_results(payload).first
      routing = answer_result.dig("result", "routing")

      assert_equal ["AnswerQuestion"], sandbox.command_results(payload).map { |result| result.fetch("command_type") }
      assert_equal head_calls_before + 1, sandbox.head_runner.calls.length
      assert_equal "accepted", routing.fetch("spawn_head_status")
      assert_equal "accepted", routing.fetch("apply_head_result_status")
      assert_equal %w[AddProject CreateIssue], routing.fetch("command_results").map { |result| result.fetch("command_type") }
      assert_equal ["Fix login in staging"], sandbox.state.fetch("issues").map { |issue| issue.fetch("title") }

      call = sandbox.head_runner.calls.last
      assert_equal "Q1", call.fetch("question_id")
      answered = call.fetch("context_prompt").fetch("routing_context").fetch("question_being_answered")
      assert_equal "answered", answered.fetch("status")
      assert_equal "use the staging environment", answered.fetch("answer")
    end
  end

  def test_answering_an_unknown_question_is_rejected_and_leaves_state_untouched
    input_sandbox do |sandbox|
      open_question(sandbox)

      payload = sandbox.submit('/answer Q9 "does not matter"')

      assert_equal [%w[AnswerQuestion rejected]], sandbox.command_result_pairs(payload)
      assert_includes sandbox.command_results(payload).first.fetch("errors"), "question_not_found"
      refute payload.fetch("state_mutated")
      assert_equal "open", sandbox.question("Q1").fetch("status")
    end
  end

  def test_answer_without_answer_text_is_rejected
    input_sandbox do |sandbox|
      open_question(sandbox)

      payload = sandbox.submit("/answer Q1")

      result = sandbox.command_results(payload).first
      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("errors"), "answer is required"
      assert_equal "open", sandbox.question("Q1").fetch("status")
    end
  end

  def test_answer_without_question_id_is_rejected
    input_sandbox do |sandbox|
      open_question(sandbox)

      payload = sandbox.submit("/answer")

      result = sandbox.command_results(payload).first
      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("errors"), "question_id is required"
      assert_includes result.fetch("errors"), "answer is required"
      assert_equal "open", sandbox.question("Q1").fetch("status")
    end
  end

  def test_dismissing_a_question_closes_it_without_an_answer
    input_sandbox do |sandbox|
      open_question(sandbox)

      payload = sandbox.submit("/dismiss Q1")

      assert_equal [%w[DismissQuestion accepted]], sandbox.command_result_pairs(payload)
      question = sandbox.question("Q1")
      assert_equal "dismissed", question.fetch("status")
      assert_nil question.fetch("answer")
    end
  end

  def test_questions_command_lists_open_and_closed_questions
    input_sandbox do |sandbox|
      open_question(sandbox)
      sandbox.submit('/answer Q1 "staging"')

      payload = sandbox.submit("/questions")
      result = sandbox.command_results(payload).first

      assert_equal "accepted", result.fetch("status")
      assert_equal "Loaded 1 question.", result.fetch("message")
    end
  end

  # SpawnHead already accepts question_id, and the head context already carries
  # the answered question. This is the plumbing an explicit or inferred answer
  # needs in order to drive follow-up routing.
  def test_spawn_head_with_a_question_id_gives_the_head_the_question_context
    input_sandbox do |sandbox|
      open_question(sandbox)
      sandbox.submit('/answer Q1 "use the staging environment"')

      result = sandbox.apply(
        "SpawnHead",
        "user_message" => "use the staging environment",
        "question_id" => "Q1"
      )

      assert_equal "accepted", result.fetch("status")

      call = sandbox.head_runner.calls.last
      assert_equal "Q1", call.fetch("question_id")

      context = call.fetch("context_prompt")
      assert_equal "Q1", context.fetch("question_id")
      answered = context.fetch("routing_context").fetch("question_being_answered")
      assert_equal "Q1", answered.fetch("id")
      assert_equal QUESTION_TEXT, answered.fetch("question")
      assert_equal "staging or production", answered.fetch("context")
      assert_equal "use the staging environment", answered.fetch("answer")
      assert_equal "answered", answered.fetch("status")
      assert_equal sandbox.question("Q1").fetch("head_id"), answered.fetch("head_id")
      refute answered.key?("project_id")
      refute answered.key?("issue_id")
      assert answered.key?("created_at")
    end
  end

  def test_spawn_head_rejects_an_unknown_question_id
    input_sandbox do |sandbox|
      result = sandbox.apply("SpawnHead", "user_message" => "an answer", "question_id" => "Q42")

      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("errors"), "question_not_found"
    end
  end

  def test_input_layer_populates_question_being_answered_for_clear_prose_answers
    input_sandbox do |sandbox|
      open_question(sandbox)

      sandbox.submit("ANSWERING Q1 I meant the staging environment")

      call = sandbox.head_runner.calls.last
      assert_nil call.fetch("question_id")
      context = call.fetch("context_prompt")
      assert_nil context.fetch("question_id")
      answered = context.fetch("routing_context").fetch("question_being_answered")
      assert_equal "Q1", answered.fetch("id")
      assert_equal QUESTION_TEXT, answered.fetch("question")
      assert_equal "user_message_reference", answered.fetch("inference_source")
    end
  end

  def test_head_context_surfaces_open_question_records
    input_sandbox do |sandbox|
      open_question(sandbox)

      sandbox.submit("I meant the staging environment")

      context = sandbox.head_runner.calls.last.fetch("context_prompt")
      assert_equal 1, context.fetch("current_state_summary").fetch("open_question_count")
      open_questions = context.fetch("routing_context").fetch("open_questions")
      assert_equal ["Q1"], open_questions.map { |question| question.fetch("id") }
      assert_equal QUESTION_TEXT, open_questions.first.fetch("question")
      assert_equal "staging or production", open_questions.first.fetch("context")
      refute context.fetch("current_state_summary").key?("open_questions")

      assert_equal sandbox.state_path, context.fetch("state_access").fetch("state_path")
      commands = context.fetch("state_access").fetch("suggested_commands").map { |entry| entry.values.join(" ") }
      assert(commands.any? { |command| command.include?("open_questions") })
      assert_equal sandbox.state_path, sandbox.head_runner.calls.last.fetch("context").state_path
    end
  end

  # The implicit-answer contract at the kernel command layer: one HeadResult may
  # both answer the question and route the work it was blocking.
  def test_head_result_may_pair_answer_question_with_routing_commands
    input_sandbox do |sandbox|
      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Clarify target environment",
          summary: "Asked which environment to target.",
          commands: [
            { "type" => "AddProject", "payload" => { "path" => sandbox.project_path, "name" => "proj" } },
            { "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Fix login" } }
          ],
          questions: [{ "question" => QUESTION_TEXT, "context" => "staging or production", "issue_id" => "P1-I1" }]
        )
      )
      sandbox.submit("fix the login bug")

      question = sandbox.question("Q1")
      assert_equal "open", question.fetch("status")
      assert_equal "P1-I1", question.fetch("issue_id")

      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Answer Q1 and continue",
          summary: "Inferred that the message answers Q1 and reused the question's issue.",
          commands: [
            { "type" => "AnswerQuestion", "payload" => { "question_id" => "Q1", "answer" => "staging" } },
            {
              "type" => "SpawnWorker",
              "payload" => { "issue_id" => "P1-I1", "title" => "Fix login", "prompt" => "Target staging." }
            }
          ]
        )
      )
      payload = sandbox.submit("staging please")

      assert_equal(
        [%w[AnswerQuestion accepted], %w[SpawnWorker accepted]],
        sandbox.command_result_pairs(payload)
      )
      answered = sandbox.question("Q1")
      assert_equal "answered", answered.fetch("status")
      assert_equal "staging", answered.fetch("answer")
      workers = sandbox.agents.select { |agent| agent.fetch("type") == "worker" }
      assert_equal 1, workers.length
      assert_equal "P1-I1", workers.first.fetch("issue_id")
    end
  end

  # Ambiguity handling: a head that decides the message is a new goal must leave
  # the open question alone. The kernel does not close questions on its own.
  def test_unrelated_head_routing_leaves_open_questions_untouched
    input_sandbox do |sandbox|
      open_question(sandbox)
      before = sandbox.question("Q1")

      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Route a brand new goal",
          summary: "Treated the message as a new goal, so Q1 stays open.",
          commands: [
            { "type" => "AddProject", "payload" => { "path" => sandbox.project_path, "name" => "proj" } },
            { "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Add a changelog" } }
          ]
        )
      )
      payload = sandbox.submit("separately, please add a changelog")

      assert_equal(
        [%w[AddProject accepted], %w[CreateIssue accepted]],
        sandbox.command_result_pairs(payload)
      )
      after = sandbox.question("Q1")
      assert_equal "open", after.fetch("status")
      assert_nil after.fetch("answer")
      assert_equal before.fetch("updated_at"), after.fetch("updated_at")
      assert_equal 1, sandbox.open_questions.length
    end
  end

  # A head may also ask a clarifying question instead of guessing, which keeps
  # the original question open.
  def test_head_can_ask_a_second_question_without_closing_the_first
    input_sandbox do |sandbox|
      open_question(sandbox)

      sandbox.head_runner.enqueue(
        sandbox.head_result(
          title: "Ambiguous answer",
          summary: "Could not tell which open question this answers.",
          questions: [{ "question" => "Did you mean Q1 or something new?", "context" => "ambiguous reply" }]
        )
      )
      sandbox.submit("the second one")

      statuses = sandbox.questions.map { |question| [question.fetch("id"), question.fetch("status")] }
      assert_equal [%w[Q1 open], %w[Q2 open]], statuses
    end
  end

  def test_answering_an_already_answered_question_is_accepted_and_overwrites_the_answer
    input_sandbox do |sandbox|
      open_question(sandbox)
      sandbox.submit('/answer Q1 "staging"')

      payload = sandbox.submit('/answer Q1 "actually production"')

      assert_equal [%w[AnswerQuestion accepted]], sandbox.command_result_pairs(payload)
      assert_equal "actually production", sandbox.question("Q1").fetch("answer")
      assert_equal "answered", sandbox.question("Q1").fetch("status")
    end
  end

  def test_dismissing_an_answered_question_is_rejected
    input_sandbox do |sandbox|
      open_question(sandbox)
      sandbox.submit('/answer Q1 "staging"')

      payload = sandbox.submit("/dismiss Q1")
      result = sandbox.command_results(payload).first

      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("errors"), "question_not_open"
    end
  end

  private

  # Opens one question the same way a real head does: through a HeadResult that
  # asks for clarification.
  def open_question(sandbox, question_text: QUESTION_TEXT, context: "staging or production")
    sandbox.head_runner.enqueue(
      sandbox.head_result(
        title: "Clarify target environment",
        summary: "Asked the user which environment to target.",
        questions: [{ "question" => question_text, "context" => context }]
      )
    )
    sandbox.submit("fix the login bug")
    assert_equal 1, sandbox.open_questions.length
  end
end
