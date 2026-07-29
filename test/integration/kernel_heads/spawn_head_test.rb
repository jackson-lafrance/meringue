# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# SpawnHead contract: the kernel owns head ids, head records, and head sessions.
# A head only ever proposes work; nothing it returns changes state until the
# kernel applies its HeadResult.
class KernelHeadsSpawnHeadTest < KernelHeadsTestCase
  def test_head_ids_are_assigned_sequentially_by_the_kernel
    first = spawn_head!("First request")
    second = spawn_head!("Second request")
    third = spawn_head!("Third request")

    assert_equal %w[H1 H2 H3], [first, second, third]
    assert_equal 3, state.fetch("counters").fetch("heads")
  end

  def test_head_record_fields_are_populated_by_the_kernel
    head_id = spawn_head!("Look into the flaky login test")
    head = find_agent_record(head_id)

    assert_equal "head", head.fetch("type")
    assert_equal "completed", head.fetch("status")
    assert_nil head.fetch("project_id")
    assert_nil head.fetch("issue_id")
    refute_nil head.fetch("created_at")
    refute_nil head.fetch("updated_at")

    metadata = head.fetch("harness_metadata")
    assert_equal "KernelHeadsSupport::StubHeadRunner", metadata.fetch("runner")
    assert_equal project_path, metadata.fetch("cwd")
    assert_equal "Look into the flaky login test", metadata.fetch("head_request").fetch("user_message")
    assert_equal "Stub head", metadata.fetch("title")
    assert_equal "Stub head made no proposals.", metadata.fetch("summary")
    assert_equal KernelHeadsSupport.empty_head_result, metadata.fetch("head_result")
  end

  def test_spawn_head_logs_the_user_message_with_the_head_id
    head_id = spawn_head!("Investigate the deploy failure")
    entry = logs.find { |log| log.fetch("message", nil) == "Investigate the deploy failure" }

    refute_nil entry
    assert_equal "user", entry.fetch("source_type")
    assert_nil entry.fetch("source_id")
    assert_equal "info", entry.fetch("level")
    assert_equal head_id, entry.fetch("details").fetch("head_id")
  end

  def test_head_runner_receives_a_state_snapshot_and_routing_context
    project_id = add_project!
    head_id = spawn_head!("Route this somewhere")

    call = head_runner.calls.fetch(-1)
    assert_equal "Route this somewhere", call.fetch("user_message")
    assert_nil call.fetch("question_id")
    assert_equal [project_id], call.fetch("snapshot").fetch("projects").map { |project| project.fetch("id") }

    context = call.fetch("context")
    assert_instance_of Meringue::Heads::Context, context
    assert_equal head_id, context.head_id
    assert_equal project_path, context.cwd
    assert_equal state_path, context.state_path
  end

  def test_head_proposals_do_not_mutate_state_until_the_kernel_applies_them
    project_id = add_project!
    head_runner.head_result = head_result(
      commands: [
        create_issue_command(project_id: project_id, title: "Proposed but not applied"),
        spawn_worker_command(issue_id: "#{project_id}-I1")
      ]
    )

    head_id = spawn_head!("Please do the thing")

    assert_empty issues
    assert_empty agents(type: "worker")
    proposed = find_agent_record(head_id).fetch("harness_metadata").fetch("head_result").fetch("commands")
    assert_equal %w[CreateIssue SpawnWorker], proposed.map { |command| command.fetch("type") }

    apply_head_result(head_id, head_runner.head_result)

    assert_equal ["#{project_id}-I1"], issues.map { |issue| issue.fetch("id") }
    assert_equal ["#{project_id}-I1-W1"], agents(type: "worker").map { |agent| agent.fetch("id") }
  end

  def test_head_record_is_cleaned_up_after_its_result_is_applied
    project_id = add_project!
    head_id = spawn_head!("Create one issue")
    result = apply_head_result(head_id, head_result(commands: [create_issue_command(project_id: project_id, title: "Cleanup check")]))

    assert_equal "accepted", result.fetch("status")
    cleanup = result.dig("result", "head_cleanup")
    assert_equal true, cleanup.fetch("changed")
    assert_equal "head_result_applied", cleanup.fetch("reason")
    assert_equal head_id, cleanup.fetch("removed_agent_id")

    assert_nil find_agent_record(head_id)
    assert_empty agents(type: "head")
    # The counter is not rewound, so head ids stay unique after cleanup.
    assert_equal "H2", spawn_head!("Another request")
  end

  def test_partially_applied_head_is_retained_for_inspection
    head_id = spawn_head!("Create an issue in a missing project")
    result = apply_head_result(head_id, head_result(commands: [create_issue_command(project_id: "P99", title: "No such project")]))

    assert_equal "accepted", result.fetch("status")
    assert_equal({ "changed" => false, "reason" => "partially_applied" }, result.dig("result", "head_cleanup"))

    head = find_agent_record(head_id)
    refute_nil head
    assert_equal "blocked", head.fetch("status")
    assert_equal "partially_applied", head.fetch("harness_metadata").fetch("head_result_apply_state")
    assert_equal "partial", head.fetch("harness_metadata").fetch("head_result_apply_status")
  end

  def test_spawn_head_rejects_a_blank_user_message
    result = apply_command("SpawnHead", { "user_message" => "   " })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "user_message is required"
    assert_empty agents(type: "head")
    assert_equal 0, state.fetch("counters").fetch("heads")
  end

  def test_spawn_head_rejects_an_unknown_question_id
    result = apply_command("SpawnHead", { "user_message" => "Answering something", "question_id" => "Q42" })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "question_not_found"
    assert_empty agents(type: "head")
  end

  def test_spawn_head_carries_the_question_id_it_answers
    question_head = spawn_head!("Ambiguous request")
    apply_head_result(question_head, head_result(questions: [{ "question" => "Which project?", "context" => "Two candidates" }]))
    question_id = questions.fetch(0).fetch("id")

    head_id = spawn_head!("The second project", question_id: question_id)

    head = find_agent_record(head_id)
    assert_equal question_id, head.fetch("harness_metadata").fetch("head_request").fetch("question_id")
    assert_equal question_id, head_runner.calls.fetch(-1).fetch("question_id")
    assert_equal question_id, head_runner.calls.fetch(-1).fetch("context").question_id

    entry = logs.find { |log| log.fetch("message", nil) == "The second project" }
    assert_equal question_id, entry.fetch("details").fetch("question_id")
  end

  def test_head_runner_snapshot_includes_open_question_records
    project_id = add_project!
    question_head = spawn_head!("Ambiguous request")
    apply_head_result(
      question_head,
      head_result(questions: [{ "question" => "Which project?", "context" => "Two candidates", "project_id" => project_id }])
    )

    spawn_head!("The meringue one")

    snapshot_questions = head_runner.calls.fetch(-1).fetch("snapshot").fetch("questions")
    assert_equal 1, snapshot_questions.length
    question = snapshot_questions.fetch(0)
    assert_equal "Q1", question.fetch("id")
    assert_equal "Which project?", question.fetch("question")
    assert_equal "Two candidates", question.fetch("context")
    assert_equal "open", question.fetch("status")
    assert_equal question_head, question.fetch("head_id")
    assert_equal project_id, question.fetch("project_id")
    refute_nil question.fetch("created_at")
  end

  def test_head_session_is_recorded_and_released_by_the_kernel
    session_runner = KernelHeadsSupport::SessionHeadRunner.new
    session_engine = build_engine(head_runner: session_runner)
    head_id = spawn_head!("Route with a live head session", target_engine: session_engine)

    session_state = session_engine.list_all
    head = find_agent_record(head_id, current_state: session_state)
    assert_equal 1, session_runner.spawned_sessions.length
    assert_equal "fake-head-session-1", head.fetch("harness_session_id")
    assert_equal "active", head.fetch("harness_metadata").fetch("head_session_state")

    opened = logs(current_state: session_state).find { |log| log.fetch("message", "").start_with?("Opened ") }
    refute_nil opened
    assert_equal "harness", opened.fetch("source_type")
    assert_equal head_id, opened.fetch("source_id")

    apply_head_result(head_id, KernelHeadsSupport.empty_head_result, target_engine: session_engine)
    assert_nil find_agent_record(head_id, current_state: session_engine.list_all)
  end

  def test_head_session_is_marked_unavailable_when_the_runner_has_no_session
    head_id = spawn_head!("Route without a head session")
    metadata = find_agent_record(head_id).fetch("harness_metadata")

    assert_equal "unavailable", metadata.fetch("head_session_state")
    assert_equal "head_runner_has_no_session", metadata.fetch("head_session_note")
    assert_nil find_agent_record(head_id).fetch("harness_session_id")
  end

  def test_async_heads_defer_result_application_to_polling
    session_runner = KernelHeadsSupport::SessionHeadRunner.new
    async_engine = build_engine(head_runner: session_runner, async_heads: true)
    result = apply_command("SpawnHead", { "user_message" => "Async routing" }, target_engine: async_engine)

    assert_equal "accepted", result.fetch("status")
    assert_includes result.fetch("message"), "polling will apply its HeadResult"
    head = find_agent_record(result.fetch("target_id"), current_state: async_engine.list_all)
    assert_equal "working", head.fetch("status")
    assert_nil head.fetch("harness_metadata").fetch("head_result", nil)
  end

  def test_head_failure_is_reported_and_the_head_is_marked_errored
    failing_runner = KernelHeadsSupport::StubHeadRunner.new
    failing_runner.head_result = proc { raise "head exploded" }
    failing_engine = build_engine(head_runner: failing_runner)

    result = apply_command("SpawnHead", { "user_message" => "Boom" }, target_engine: failing_engine)

    assert_equal "failed", result.fetch("status")
    assert_includes result.fetch("message"), "head exploded"
    head = find_agent_record("H1", current_state: failing_engine.list_all)
    assert_equal "errored", head.fetch("status")
  end
end
