# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# Question lifecycle contract: one clarification is one question record, ids and
# statuses are owned by the kernel, and open questions never block unrelated work.
class KernelHeadsQuestionsTest < KernelHeadsTestCase
  ROUTING_QUESTION = "Which project should this land in, meringue or the demo app?"

  def ask_via_questions_array(head_id, question: ROUTING_QUESTION, context: "Two candidate projects", project_id: nil, issue_id: nil, cleanup_head: true)
    entry = { "question" => question, "context" => context }
    entry["project_id"] = project_id if project_id
    entry["issue_id"] = issue_id if issue_id
    apply_head_result(head_id, head_result(questions: [entry]), cleanup_head: cleanup_head)
  end

  def question_log_entries(current_state: nil)
    logs_matching(current_state: current_state) { |log| log.fetch("message", "").start_with?("Question Q") }
  end

  def test_head_result_questions_create_one_open_question_record
    project_id = add_project!
    head_id = spawn_head!("Do the ambiguous thing")
    result = ask_via_questions_array(head_id, project_id: project_id, cleanup_head: false)

    assert_equal ["Q1"], result.dig("result", "question_ids")
    question = questions.fetch(0)
    assert_equal "Q1", question.fetch("id")
    assert_equal head_id, question.fetch("head_id")
    assert_equal project_id, question.fetch("project_id")
    assert_nil question.fetch("issue_id")
    assert_equal ROUTING_QUESTION, question.fetch("question")
    assert_equal "Two candidate projects", question.fetch("context")
    assert_equal "open", question.fetch("status")
    assert_nil question.fetch("answer")
    refute_nil question.fetch("created_at")
    refute_nil question.fetch("updated_at")

    entry = question_log_entries.fetch(0)
    assert_equal 1, question_log_entries.length
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal "Q1", entry.fetch("source_id")
    assert_equal head_id, entry.fetch("details").fetch("head_id")
    assert_equal project_id, entry.fetch("details").fetch("project_id")
  end

  def test_question_ids_increment_across_heads
    first_head = spawn_head!("First ambiguous request")
    ask_via_questions_array(first_head, question: "Which project should this land in?")
    second_head = spawn_head!("Second ambiguous request")
    ask_via_questions_array(second_head, question: "Which project should this land in?")

    assert_equal %w[Q1 Q2], questions.map { |question| question.fetch("id") }
    assert_equal [first_head, second_head], questions.map { |question| question.fetch("head_id") }
  end

  def test_questions_array_and_ask_question_command_record_one_question
    head_id = spawn_head!("Restated clarification")
    result = apply_head_result(
      head_id,
      head_result(
        commands: [ask_question_command(head_id: head_id, question: ROUTING_QUESTION, context: "Same clarification as a command")],
        questions: [{ "question" => ROUTING_QUESTION, "context" => "Same clarification in the questions array" }]
      ),
      cleanup_head: false
    )

    assert_equal 1, questions.length
    assert_equal 1, question_log_entries.length
    command_result = command_results(result).fetch(0)
    assert_equal "accepted", command_result.fetch("status")
    assert_equal "Q1", command_result.fetch("target_id")
    assert_includes command_result.fetch("message"), "already records this clarification"
    assert_empty command_result.fetch("log_entry_ids")
    assert_equal "Same clarification in the questions array", questions.fetch(0).fetch("context")
  end

  def test_a_reworded_restatement_resolves_to_the_stored_question
    head_id = spawn_head!("Reworded clarification")
    apply_head_result(
      head_id,
      head_result(
        commands: [
          ask_question_command(
            head_id: head_id,
            question: "Which project should this land in: meringue, or the demo app instead?"
          )
        ],
        questions: [{ "question" => ROUTING_QUESTION, "context" => "canonical" }]
      ),
      cleanup_head: false
    )

    assert_equal 1, questions.length
    assert_equal 1, question_log_entries.length
  end

  def test_genuinely_different_clarifications_are_stored_separately
    head_id = spawn_head!("Two clarifications")
    result = apply_head_result(
      head_id,
      head_result(
        questions: [
          { "question" => ROUTING_QUESTION, "context" => "routing" },
          { "question" => "Do you want a pull request opened, or only local commits?", "context" => "delivery" }
        ]
      ),
      cleanup_head: false
    )

    assert_equal %w[Q1 Q2], result.dig("result", "question_ids")
    assert_equal 2, questions.length
    assert_equal 2, question_log_entries.length
  end

  def test_ask_question_validation
    head_id = spawn_head!("Validation", target_engine: engine)

    missing_head = apply_command("AskQuestion", { "question" => "Anything?" })
    assert_equal "rejected", missing_head.fetch("status")
    assert_includes missing_head.fetch("errors"), "head_id is required"

    missing_question = apply_command("AskQuestion", { "head_id" => head_id })
    assert_equal "rejected", missing_question.fetch("status")
    assert_includes missing_question.fetch("errors"), "question is required"

    unknown_head = apply_command("AskQuestion", { "head_id" => "H99", "question" => "Anything?" })
    assert_equal "rejected", unknown_head.fetch("status")
    assert_includes unknown_head.fetch("errors"), "head_not_found"

    unknown_project = apply_command("AskQuestion", { "head_id" => head_id, "question" => "Anything?", "project_id" => "P42" })
    assert_equal "rejected", unknown_project.fetch("status")
    assert_includes unknown_project.fetch("errors"), "project_not_found"

    unknown_issue = apply_command("AskQuestion", { "head_id" => head_id, "question" => "Anything?", "issue_id" => "P1-I3" })
    assert_equal "rejected", unknown_issue.fetch("status")
    assert_includes unknown_issue.fetch("errors"), "issue_not_found"

    assert_empty questions
  end

  def test_answer_question_stores_the_answer_and_marks_it_answered
    head_id = spawn_head!("Ambiguous request")
    ask_via_questions_array(head_id)

    result = apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "Use the meringue project." })

    assert_equal "accepted", result.fetch("status")
    assert_equal "Q1", result.fetch("target_id")
    assert_equal "Answered question Q1 and spawned head H2 to act on the answer.", result.fetch("message")
    assert_equal "H2", result.dig("result", "routing", "head_id")
    assert_equal "accepted", result.dig("result", "routing", "spawn_head_status")
    assert_equal "accepted", result.dig("result", "routing", "apply_head_result_status")

    question = questions.fetch(0)
    assert_equal "answered", question.fetch("status")
    assert_equal "Use the meringue project.", question.fetch("answer")
    assert_operator question.fetch("updated_at"), :>=, question.fetch("created_at")

    entry = logs.find { |log| log.fetch("message", nil) == "Answered question Q1." }
    refute_nil entry
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal "Q1", entry.fetch("source_id")
    assert_equal head_id, entry.fetch("details").fetch("head_id")
  end

  def test_answer_question_keeps_the_project_and_issue_scope_of_the_question
    project_id = add_project!
    scope_head = spawn_head!("Create an issue to scope the question")
    apply_head_result(scope_head, head_result(commands: [create_issue_command(project_id: project_id, title: "Scoped work")]))
    issue_id = issues.fetch(0).fetch("id")

    head_id = spawn_head!("Ambiguous follow-up")
    ask_via_questions_array(head_id, project_id: project_id, issue_id: issue_id)
    result = apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "Yes, keep it on that issue." })

    assert_equal project_id, result.dig("result", "project_id")
    assert_equal issue_id, result.dig("result", "issue_id")
    assert_equal project_id, questions.fetch(0).fetch("project_id")
    assert_equal issue_id, questions.fetch(0).fetch("issue_id")
  end

  def test_answering_a_question_spawns_a_head_and_applies_its_routing_commands
    project_id = add_project!
    head_id = spawn_head!("Ambiguous request")
    ask_via_questions_array(head_id, project_id: project_id)
    @head_runner.head_result = head_result(commands: [create_issue_command(project_id: project_id, title: "Answered follow-up")])
    heads_before = state.fetch("counters").fetch("heads")

    result = apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "Use the meringue project." })
    routing = result.dig("result", "routing")

    assert_equal heads_before + 1, state.fetch("counters").fetch("heads")
    assert_equal "accepted", routing.fetch("spawn_head_status")
    assert_equal "accepted", routing.fetch("apply_head_result_status")
    assert_equal ["CreateIssue"], routing.fetch("command_results").map { |entry| entry.fetch("command_type") }
    assert_equal ["Answered follow-up"], issues.map { |issue| issue.fetch("title") }

    routed_call = @head_runner.calls.last
    assert_equal "Q1", routed_call.fetch("question_id")
    assert_includes routed_call.fetch("user_message"), "The user answered open Meringue question Q1"
    assert_includes routed_call.fetch("user_message"), "User answer: Use the meringue project."
  end

  def test_answer_question_validation
    head_id = spawn_head!("Validation")
    ask_via_questions_array(head_id)

    missing_id = apply_command("AnswerQuestion", { "answer" => "Anything" })
    assert_equal "rejected", missing_id.fetch("status")
    assert_includes missing_id.fetch("errors"), "question_id is required"

    missing_answer = apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "  " })
    assert_equal "rejected", missing_answer.fetch("status")
    assert_includes missing_answer.fetch("errors"), "answer is required"

    unknown = apply_command("AnswerQuestion", { "question_id" => "Q9", "answer" => "Anything" })
    assert_equal "rejected", unknown.fetch("status")
    assert_includes unknown.fetch("errors"), "question_not_found"

    assert_equal "open", questions.fetch(0).fetch("status")
    assert_nil questions.fetch(0).fetch("answer")
  end

  def test_answering_the_same_question_with_the_same_answer_is_idempotent
    head_id = spawn_head!("Ambiguous request")
    ask_via_questions_array(head_id)

    apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "First answer" })
    heads_after_first_answer = state.fetch("counters").fetch("heads")
    second = apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "First answer" })

    assert_equal "accepted", second.fetch("status")
    assert_equal "Question Q1 already records this answer.", second.fetch("message")
    assert_nil second.dig("result", "routing")
    assert_equal heads_after_first_answer, state.fetch("counters").fetch("heads")
  end

  # Current behavior: re-answering with a new answer is allowed and overwrites the stored answer.
  def test_answering_twice_overwrites_the_stored_answer
    head_id = spawn_head!("Ambiguous request")
    ask_via_questions_array(head_id)

    apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "First answer" })
    second = apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "Second answer" })

    assert_equal "accepted", second.fetch("status")
    assert_equal "Second answer", questions.fetch(0).fetch("answer")
    assert_equal "answered", questions.fetch(0).fetch("status")
    assert_equal 1, questions.length
  end

  # Current behavior: unlike DismissQuestion, AnswerQuestion has no status guard, so a
  # dismissed question can still be answered.
  def test_answering_a_dismissed_question_is_currently_accepted
    head_id = spawn_head!("Ambiguous request")
    ask_via_questions_array(head_id)
    apply_command("DismissQuestion", { "question_id" => "Q1" })

    result = apply_command("AnswerQuestion", { "question_id" => "Q1", "answer" => "Actually, meringue." })

    assert_equal "accepted", result.fetch("status")
    assert_equal "answered", questions.fetch(0).fetch("status")
    assert_equal "Actually, meringue.", questions.fetch(0).fetch("answer")
  end

  def test_dismiss_question_marks_an_open_question_dismissed
    head_id = spawn_head!("Ambiguous request")
    ask_via_questions_array(head_id)

    result = apply_command("DismissQuestion", { "question_id" => "Q1" })

    assert_equal "accepted", result.fetch("status")
    assert_equal "dismissed", questions.fetch(0).fetch("status")
    assert_nil questions.fetch(0).fetch("answer")

    entry = logs.find { |log| log.fetch("message", nil) == "Dismissed question Q1." }
    refute_nil entry
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal "Q1", entry.fetch("source_id")
  end

  def test_dismiss_question_is_idempotent_and_refuses_answered_questions
    head_id = spawn_head!("Ambiguous request")
    apply_head_result(
      head_id,
      head_result(
        questions: [
          { "question" => ROUTING_QUESTION, "context" => "routing" },
          { "question" => "Do you want a pull request opened, or only local commits?", "context" => "delivery" }
        ]
      )
    )

    apply_command("DismissQuestion", { "question_id" => "Q1" })
    repeat = apply_command("DismissQuestion", { "question_id" => "Q1" })
    assert_equal "accepted", repeat.fetch("status")
    assert_includes repeat.fetch("message"), "already dismissed"
    assert_empty repeat.fetch("log_entry_ids")

    apply_command("AnswerQuestion", { "question_id" => "Q2", "answer" => "Open a PR." })
    answered = apply_command("DismissQuestion", { "question_id" => "Q2" })
    assert_equal "rejected", answered.fetch("status")
    assert_includes answered.fetch("errors"), "question_not_open"
    assert_equal "answered", questions.fetch(1).fetch("status")

    missing_id = apply_command("DismissQuestion", {})
    assert_equal "rejected", missing_id.fetch("status")
    assert_includes missing_id.fetch("errors"), "question_id is required"

    unknown = apply_command("DismissQuestion", { "question_id" => "Q9" })
    assert_equal "rejected", unknown.fetch("status")
    assert_includes unknown.fetch("errors"), "question_not_found"
  end

  def test_list_questions_reports_every_status
    head_id = spawn_head!("Ambiguous request")
    apply_head_result(
      head_id,
      head_result(
        questions: [
          { "question" => ROUTING_QUESTION, "context" => "routing" },
          { "question" => "Do you want a pull request opened, or only local commits?", "context" => "delivery" },
          { "question" => "Should the rollout wait for next week's release train?", "context" => "timing" }
        ]
      )
    )
    apply_command("AnswerQuestion", { "question_id" => "Q2", "answer" => "Open a PR." })
    apply_command("DismissQuestion", { "question_id" => "Q3" })

    result = apply_command("ListQuestions", {})

    assert_equal "accepted", result.fetch("status")
    listed = Array(result.fetch("result"))
    assert_equal %w[Q1 Q2 Q3], listed.map { |question| question.fetch("id") }
    assert_equal %w[open answered dismissed], listed.map { |question| question.fetch("status") }
  end

  def test_an_open_question_does_not_block_unrelated_work
    project_id = add_project!
    question_head = spawn_head!("Ambiguous request")
    ask_via_questions_array(question_head)

    other_head = spawn_head!("Unrelated goal that needs a worker")
    result = apply_head_result(
      other_head,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Unrelated goal"),
          spawn_worker_command(issue_id: "#{project_id}-I1", title: "Unrelated goal")
        ]
      )
    )

    assert_equal([["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(result))
    assert_equal 1, agents(type: "worker").length
    assert_equal "open", questions.fetch(0).fetch("status")
    assert_equal question_head, questions.fetch(0).fetch("head_id")
  end

  # The implicit/explicit answer flow depends on one head batch being able to answer a
  # question and route the resulting work at the same time.
  def test_a_head_result_can_answer_a_question_and_route_work_in_one_batch
    project_id = add_project!
    question_head = spawn_head!("Ambiguous request")
    ask_via_questions_array(question_head, project_id: project_id)

    answering_head = spawn_head!("Use the meringue project", question_id: "Q1")
    result = apply_head_result(
      answering_head,
      head_result(
        commands: [
          { "type" => "AnswerQuestion", "payload" => { "question_id" => "Q1", "answer" => "Use the meringue project." } },
          create_issue_command(project_id: project_id, title: "Answered goal"),
          spawn_worker_command(issue_id: "#{project_id}-I1", title: "Answered goal")
        ]
      )
    )

    assert_equal(
      [["AnswerQuestion", "accepted"], ["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]],
      command_statuses(result)
    )
    assert_equal "answered", questions.fetch(0).fetch("status")
    assert_equal "Use the meringue project.", questions.fetch(0).fetch("answer")
    assert_equal 1, issues.length
    assert_equal 1, agents(type: "worker").length
    assert_equal 1, questions.length
  end

  def test_a_head_result_can_dismiss_a_question_and_route_work_in_one_batch
    project_id = add_project!
    question_head = spawn_head!("Ambiguous request")
    ask_via_questions_array(question_head, project_id: project_id)

    routing_head = spawn_head!("Never mind, just do it in meringue")
    result = apply_head_result(
      routing_head,
      head_result(
        commands: [
          { "type" => "DismissQuestion", "payload" => { "question_id" => "Q1" } },
          create_issue_command(project_id: project_id, title: "Superseded goal")
        ]
      )
    )

    assert_equal([["DismissQuestion", "accepted"], ["CreateIssue", "accepted"]], command_statuses(result))
    assert_equal "dismissed", questions.fetch(0).fetch("status")
    assert_equal 1, issues.length
  end

  def test_questions_survive_the_cleanup_of_the_head_that_asked_them
    head_id = spawn_head!("Ambiguous request")
    ask_via_questions_array(head_id)

    assert_nil find_agent_record(head_id)
    assert_equal 1, questions.length
    assert_equal head_id, questions.fetch(0).fetch("head_id")
    assert_equal "open", questions.fetch(0).fetch("status")
  end
end
