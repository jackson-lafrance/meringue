# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# Heads echo ids back in whatever case they read them in, so a head-proposed command payload must
# resolve the same way a typed slash command does, and the journal/log must keep canonical ids.
class KernelHeadsCaseInsensitiveIdsTest < KernelHeadsTestCase
  def test_head_proposed_commands_resolve_lowercase_and_mixed_case_ids
    add_project!
    head_id = spawn_head!("register the work")
    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: "p1", title: "Fix retries"),
          spawn_worker_command(issue_id: "p1-i1", title: "Inspect retries", prompt: "Look at the retry path.")
        ]
      )
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal [["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(result)
    assert_equal %w[P1-I1 P1-I1-W1], command_results(result).map { |command_result| command_result.fetch("target_id") }
    assert_equal ["P1-I1"], issues.map { |issue| issue.fetch("id") }
    worker = agents(type: "worker").first
    assert_equal "P1-I1", worker.fetch("issue_id")
    assert_equal "P1", worker.fetch("project_id")
    assert_equal ["P1-I1-W1"], issues.first.fetch("agent_ids")
  end

  def test_head_proposed_prompt_and_kill_resolve_a_mixed_case_worker_id
    add_project!
    first_head = spawn_head!("start the work")
    apply_head_result(
      first_head,
      head_result(
        commands: [
          create_issue_command(project_id: "P1", title: "Fix retries"),
          spawn_worker_command(issue_id: "P1-I1", title: "Inspect retries")
        ]
      )
    )

    second_head = spawn_head!("follow up then stop")
    result = apply_head_result(
      second_head,
      head_result(
        commands: [
          { "type" => "PromptAgent", "payload" => { "agent_id" => "p1-i1-w1", "prompt" => "any update?", "mode" => "follow_up" } },
          { "type" => "Kill", "payload" => { "target_id" => "P1-i1-W1" } }
        ]
      )
    )

    assert_equal [["PromptAgent", "accepted"], ["Kill", "accepted"]], command_statuses(result)
    assert_equal %w[P1-I1-W1 P1-I1-W1], command_results(result).map { |command_result| command_result.fetch("target_id") }
    assert_includes log_messages, "Killed P1-I1-W1."
    assert_empty agents(type: "worker")
  end

  def test_head_proposed_question_ids_resolve_and_unknown_ids_are_still_rejected
    add_project!
    asking_head = spawn_head!("ask me something")
    apply_head_result(
      asking_head,
      head_result(commands: [ask_question_command(head_id: asking_head, question: "Which environment?")]),
      cleanup_head: false
    )
    assert_equal ["Q1"], questions.map { |question| question.fetch("id") }

    answering_head = spawn_head!("staging please")
    result = apply_head_result(
      answering_head,
      head_result(
        commands: [
          { "type" => "AnswerQuestion", "payload" => { "question_id" => "q1", "answer" => "staging" } },
          { "type" => "DismissQuestion", "payload" => { "question_id" => "q9" } }
        ]
      )
    )

    statuses = command_statuses(result)
    assert_equal ["AnswerQuestion", "accepted"], statuses.first
    assert_equal ["DismissQuestion", "rejected"], statuses.last
    assert_equal "Q1", command_results(result).first.fetch("target_id")
    assert_equal "Question q9 does not exist.", command_results(result).last.fetch("message")
    assert_equal "answered", questions.first.fetch("status")
    assert_equal "staging", questions.first.fetch("answer")
  end

  # An intra-batch reference is not a record id, so it keeps its `@...` spelling and still binds to
  # the issue the batch created.
  def test_batch_issue_references_still_resolve_alongside_lowercase_ids
    add_project!
    head_id = spawn_head!("create and staff an issue")
    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: "p1", title: "Fix retries", command_id: "H1-C1"),
          spawn_worker_command(issue_id: "@H1-C1", title: "Inspect retries")
        ]
      )
    )

    assert_equal [["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(result)
    assert_equal "P1-I1", agents(type: "worker").first.fetch("issue_id")
  end
end
