# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# A head batch that accepts nothing must never let the user's message disappear behind command
# error lines, and a correctly routed message must survive a target session that happens to be
# mid-turn. Both regressions come from one observed incident: a head proposed
# PromptAgent(mode: "normal") against a streaming Pi session, the command failed, the batch ended
# 0 accepted / 1 failed, and the user's request was only visible as two red log lines.
class KernelHeadsUnroutedUserMessageTest < KernelHeadsTestCase
  # Harness whose sessions report an in-flight turn, and which mirrors the harness contract by
  # queueing a normal prompt as a follow-up and reporting the substitution.
  class StreamingHarnessClient < Meringue::Harness::FakeClient
    attr_reader :prompts

    def initialize
      @prompts = []
      super()
    end

    def spawn_session(**kwargs)
      super(**kwargs).merge("is_streaming" => true, "pid" => 4242)
    end

    def get_state(session_ref)
      session_ref.merge("is_streaming" => true)
    end

    def prompt_session(session_ref, prompt, mode: "normal")
      delivered = mode.to_s == "normal" ? "follow_up" : mode.to_s
      @prompts << { "prompt" => prompt, "requested_mode" => mode.to_s, "mode" => delivered }
      coercion = if delivered == mode.to_s
                   {}
                 else
                   {
                     "requested_prompt_mode" => mode.to_s,
                     "delivered_prompt_mode" => delivered,
                     "prompt_mode_note" => "The session was mid-turn, so this prompt was queued as a follow-up " \
                                           "instead of interrupting the active turn."
                   }
                 end
      session_ref.merge(
        "is_streaming" => true,
        "metadata" => (session_ref.fetch("metadata", {}) || {}).merge(coercion)
      )
    end
  end

  def unrouted_log(current_state: nil)
    logs(current_state: current_state).find { |entry| entry.fetch("details", {})["kind"] == "unrouted_user_message" }
  end

  def test_a_batch_whose_commands_all_failed_surfaces_the_user_message
    failing_engine = build_engine(harness_client: KernelHeadsSupport::FailingSpawnHarnessClient.new)
    project_id = add_project!(target_engine: failing_engine)
    issue = apply_command(
      "CreateIssue",
      { "project_id" => project_id, "title" => "Agent colours", "description" => "Colour the tree." },
      target_engine: failing_engine
    )
    head_id = spawn_head!("extend the agent colour work to working and completed rows", target_engine: failing_engine)

    result = apply_head_result(
      head_id,
      head_result(commands: [spawn_worker_command(issue_id: issue.fetch("target_id"))]),
      target_engine: failing_engine
    )
    failing_state = failing_engine.list_all

    assert_equal [%w[SpawnWorker failed]], command_statuses(result)
    entry = unrouted_log(current_state: failing_state)
    refute_nil entry, "a batch that accepted nothing must surface the user's message"
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal head_id, entry.fetch("source_id")
    assert_equal "error", entry.fetch("level")
    assert_includes entry.fetch("message"), "extend the agent colour work to working and completed rows"
    assert_includes entry.fetch("message"), "still needs handling"
    assert_includes entry.fetch("message"), "/retry #{head_id}"
    assert_includes entry.fetch("message"), "/prompt"
    details = entry.fetch("details")
    assert_equal "extend the agent colour work to working and completed rows", details.fetch("user_message")
    assert_equal 0, details.fetch("accepted_command_count")
    assert_equal 1, details.fetch("command_count")
    assert_equal [%w[SpawnWorker failed]], details.fetch("command_results").map { |r| [r.fetch("command_type"), r.fetch("status")] }
  end

  def test_a_batch_with_no_commands_and_no_questions_surfaces_the_user_message
    head_id = spawn_head!("please colour the working rows too")

    apply_head_result(head_id, head_result(commands: [], questions: []))

    entry = unrouted_log
    refute_nil entry
    assert_equal "warning", entry.fetch("level")
    assert_includes entry.fetch("message"), "routed nothing for this message"
    assert_includes entry.fetch("message"), "please colour the working rows too"
    assert_equal "please colour the working rows too", entry.fetch("details").fetch("user_message")
  end

  def test_a_long_user_message_is_excerpted_in_the_log_line_but_kept_whole_in_details
    long_message = "colour the rows " * 40
    head_id = spawn_head!(long_message)

    apply_head_result(head_id, head_result(commands: [], questions: []))

    entry = unrouted_log
    refute_nil entry
    assert_operator entry.fetch("message").length, :<, long_message.length
    assert_includes entry.fetch("message"), "…"
    assert_equal long_message.strip, entry.fetch("details").fetch("user_message")
  end

  def test_an_accepted_command_does_not_surface_an_unrouted_message
    project_id = add_project!
    head_id = spawn_head!("file the colour work")

    apply_head_result(head_id, head_result(commands: [create_issue_command(project_id: project_id, title: "Colours")]))

    assert_nil unrouted_log, "an applied batch routed the message"
  end

  def test_an_intentional_no_op_does_not_surface_an_unrouted_warning
    head_id = spawn_head!("make onboarding theme-first")

    result = apply_head_result(
      head_id,
      head_result(commands: [{ "type" => "NoOp", "payload" => { "reason" => "P2-I3 already includes the theme-first onboarding requirement." } }]),
      cleanup_head: false
    )

    assert_equal [%w[NoOp accepted]], command_statuses(result)
    assert_nil unrouted_log, "an explicit NoOp marks intentional no-work routing"
    assert_includes log_messages.join("\n"), "P2-I3 already includes the theme-first onboarding requirement"
    assert_equal "completed", find_agent_record(head_id).fetch("status")
  end

  def test_a_clarifying_question_keeps_the_message_actionable_without_an_extra_error
    head_id = spawn_head!("colour the rows")

    apply_head_result(
      head_id,
      head_result(commands: [], questions: [{ "question" => "Which project?", "context" => "two candidates" }])
    )

    assert_equal 1, questions.length
    assert_nil unrouted_log, "an open question is already an actionable record of the request"
  end

  # End-to-end proof of the original incident: the head still picks mode "normal", the worker's
  # session is still mid-turn, and the message now lands as a queued follow-up.
  def test_head_routed_normal_prompt_against_a_streaming_worker_is_delivered_not_dropped
    streaming_client = StreamingHarnessClient.new
    streaming_engine = build_engine(harness_client: streaming_client)
    project_id = add_project!(target_engine: streaming_engine)
    first_head = spawn_head!("start the agent colour work", target_engine: streaming_engine)
    apply_head_result(
      first_head,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Agent colours"),
          spawn_worker_command(issue_id: "#{project_id}-I1", title: "Agent colours")
        ]
      ),
      target_engine: streaming_engine
    )
    worker_id = agents(type: "worker", current_state: streaming_engine.list_all).fetch(0).fetch("id")

    second_head = spawn_head!("extend it to working and completed rows", target_engine: streaming_engine)
    result = apply_head_result(
      second_head,
      head_result(
        commands: [
          {
            "type" => "PromptAgent",
            "payload" => { "agent_id" => worker_id, "prompt" => "extend it to working and completed rows", "mode" => "normal" }
          }
        ]
      ),
      target_engine: streaming_engine
    )
    streaming_state = streaming_engine.list_all

    assert_equal [%w[PromptAgent accepted]], command_statuses(result)
    assert_nil unrouted_log(current_state: streaming_state)
    delivered = streaming_client.prompts.fetch(0)
    assert_equal "follow_up", delivered.fetch("mode")
    assert_equal "extend it to working and completed rows", delivered.fetch("prompt")
    worker = find_agent_record(worker_id, current_state: streaming_state)
    assert_equal "follow_up", worker.fetch("harness_metadata").fetch("last_prompt_mode")
    assert_equal "normal", worker.fetch("harness_metadata").fetch("requested_prompt_mode")
    assert_includes log_messages(current_state: streaming_state).join("\n"), "Requested normal, delivered follow_up"
    refute_includes log_messages(current_state: streaming_state).join("\n"), "Pi session is streaming"
  end
end
