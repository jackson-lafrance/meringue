# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# `SpawnWorker` with `after_agent_id`: queueing a worker behind another agent, activating it from
# the worker-settle path and from reconciliation, the handover prompt, and the failure policy for a
# predecessor that errors, is killed, is replaced, or disappears.
class KernelWorkersDeferredChainingTest < Minitest::Test
  include KernelWorkersSupport

  # --- Queueing -------------------------------------------------------------------------------

  def test_configured_predecessor_failure_policy_is_used_when_command_omits_one
    File.write(tmp_path("config.toml"), "[conflicts]\npredecessor_failure = \"run\"\n")
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Investigate.").fetch("target_id")

    dependent = agent(
      engine,
      spawn_worker(engine, context.fetch("issue_id"), prompt: "Continue.", after_agent_id: predecessor_id).fetch("target_id")
    )

    assert_equal "run", dependent.fetch("harness_metadata").fetch("deferred_spawn").fetch("if_predecessor_fails")
  end

  def test_worker_queued_behind_a_live_worker_is_recorded_without_a_session
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Investigate.").fetch("target_id")

    result = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement the fix.",
      title: "Implement the fix",
      after_agent_id: predecessor_id
    )
    dependent = agent(engine, result.fetch("target_id"))
    deferred = dependent.fetch("harness_metadata").fetch("deferred_spawn")

    assert_equal "queued", dependent.fetch("status")
    assert_equal predecessor_id, dependent.fetch("after_agent_id")
    assert_equal "waiting", deferred.fetch("state")
    assert_equal predecessor_id, deferred.fetch("after_agent_id")
    assert_equal "cancel", deferred.fetch("if_predecessor_fails")
    assert_equal true, deferred.fetch("include_predecessor_result")
    assert_equal 1, deferred.fetch("chain_depth")
    assert_equal "Implement the fix.", deferred.fetch("queued_prompt")
    assert_nil dependent.fetch("harness_session_id")
    assert_nil dependent.fetch("pid")
    # Only the predecessor ever reached the harness.
    assert_equal 1, @harness_client.spawns.length
  end

  def test_queueing_logs_who_the_worker_is_waiting_for_and_lists_it_on_the_issue
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Then ship it.", after_agent_id: predecessor_id).fetch("target_id")

    assert_includes log_messages(engine), "Queued worker #{dependent_id} on P1-I1 to start after #{predecessor_id} settles."
    queue_log = state(engine).fetch("logs").find { |entry| entry.fetch("details", {})["agent_id"] == dependent_id }
    assert_equal "queue_deferred_worker", queue_log.fetch("details").fetch("routing_action")
    assert_equal predecessor_id, queue_log.fetch("details").fetch("after_agent_id")
    assert_includes issue(engine, context.fetch("issue_id")).fetch("agent_ids"), dependent_id
  end

  def test_a_queued_worker_does_not_complete_its_issue_when_the_predecessor_finishes
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    spawn_worker(engine, context.fetch("issue_id"), prompt: "Then ship it.", after_agent_id: predecessor_id)

    @harness_client.streaming = true
    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Investigated.")

    refute_equal "completed", issue(engine, context.fetch("issue_id")).fetch("status")
  end

  # --- Activation -----------------------------------------------------------------------------

  def test_predecessor_completion_starts_the_queued_worker_with_a_handover_prompt
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Investigate.").fetch("target_id")
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement the fix the research found.",
      after_agent_id: predecessor_id
    ).fetch("target_id")

    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "The bug is in SessionController#create.")
    dependent = agent(engine, dependent_id)
    deferred = dependent.fetch("harness_metadata").fetch("deferred_spawn")
    spawn_prompt = @harness_client.spawns.last.fetch("prompt")

    assert_equal "working", dependent.fetch("status")
    assert_equal "activated", deferred.fetch("state")
    assert_equal "completed", deferred.fetch("predecessor_status")
    assert_equal "predecessor_settled", deferred.fetch("activation_trigger")
    assert_equal predecessor_id, dependent.fetch("after_agent_id")
    refute_nil dependent.fetch("harness_session_id")
    assert_equal 2, @harness_client.spawns.length

    assert_includes spawn_prompt, "Implement the fix the research found."
    assert_includes spawn_prompt, "Handover from #{predecessor_id}"
    assert_includes spawn_prompt, "Status when it settled: completed"
    assert_includes spawn_prompt, "The bug is in SessionController#create."
  end

  def test_handover_preserves_the_predecessors_complete_final_message
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Investigate.").fetch("target_id")
    spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement every finding.",
      after_agent_id: predecessor_id
    )
    complete_report = "REPORT START\n#{"finding\n" * 1_000}REPORT END"

    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: complete_report)

    spawn_prompt = @harness_client.spawns.last.fetch("prompt")
    assert_includes spawn_prompt, complete_report
    assert_includes spawn_prompt, "REPORT END"
    refute_includes spawn_prompt, "[handover truncated]"
  end

  def test_activation_is_logged_as_a_started_queued_worker
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Done.")

    assert_includes log_messages(engine), "Starting queued worker #{dependent_id} because #{predecessor_id} settled (completed)."
    assert_includes(
      log_messages(engine),
      "Started queued worker #{dependent_id} on P1-I1 because #{predecessor_id} settled (completed)."
    )
  end

  def test_handover_can_be_turned_off_by_the_caller
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Do the independent follow-up.",
      after_agent_id: predecessor_id,
      include_predecessor_result: false
    )

    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Secret findings.")
    spawn_prompt = @harness_client.spawns.last.fetch("prompt")

    assert_includes spawn_prompt, "Do the independent follow-up."
    refute_includes spawn_prompt, "Secret findings."
    refute_includes spawn_prompt, "Original assignment"
    # Turning the *handover* off says nothing about the workspace: this worker still continues in
    # its settled predecessor's worktree, and is still told so.
    assert_includes spawn_prompt, "--- Shared workspace ---"
  end

  def test_naming_an_already_completed_worker_starts_immediately_with_the_handover
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Already finished.")

    result = spawn_worker(engine, context.fetch("issue_id"), prompt: "Continue.", after_agent_id: predecessor_id)
    dependent = agent(engine, result.fetch("target_id"))

    assert_equal "working", dependent.fetch("status")
    assert_equal predecessor_id, dependent.fetch("after_agent_id")
    assert_nil dependent.fetch("harness_metadata")["deferred_spawn"]
    assert_includes @harness_client.spawns.last.fetch("prompt"), "Already finished."
  end

  def test_a_queued_worker_keeps_its_issue_when_it_activates
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")
    queued_issue_id = agent(engine, dependent_id).fetch("issue_id")

    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Done.")

    assert_equal queued_issue_id, agent(engine, dependent_id).fetch("issue_id")
  end

  # --- Cross-issue chaining -------------------------------------------------------------------

  def test_a_worker_may_wait_for_a_worker_on_another_issue
    engine = build_engine
    context = project_with_issue(engine, title: "Research the crash")
    implementation_issue_id = create_issue(engine, context.fetch("project_id"), title: "Fix the crash")
    predecessor_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Research.").fetch("target_id")

    dependent_id = spawn_worker(
      engine,
      implementation_issue_id,
      prompt: "Fix it.",
      after_agent_id: predecessor_id
    ).fetch("target_id")
    engine.mark_worker_completed(agent_id: predecessor_id, last_assistant_text: "Root cause found.")
    dependent = agent(engine, dependent_id)

    assert_equal implementation_issue_id, dependent.fetch("issue_id")
    assert_equal "working", dependent.fetch("status")
    assert_includes @harness_client.spawns.last.fetch("prompt"), "Root cause found."
  end

  # --- Restart recovery -----------------------------------------------------------------------

  def test_reconciliation_activates_a_worker_whose_predecessor_settled_while_meringue_was_down
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    # The predecessor settles without the settle path running: this is the crash window between A
    # finishing and B starting.
    patch_agent!(predecessor_id) do |record|
      record["status"] = "completed"
      record["harness_metadata"] = record.fetch("harness_metadata").merge("last_assistant_text" => "Findings from before the restart.")
    end

    restarted = build_engine
    result = apply!(restarted, "ReconcileSessions")
    dependent = agent(restarted, dependent_id)

    assert_equal "working", dependent.fetch("status")
    assert_equal "activated", dependent.fetch("harness_metadata").fetch("deferred_spawn").fetch("state")
    assert_equal "reconcile", dependent.fetch("harness_metadata").fetch("deferred_spawn").fetch("activation_trigger")
    assert_includes @harness_client.spawns.last.fetch("prompt"), "Findings from before the restart."
    assert_equal 1, result.dig("result", "deferred_worker_results").length
  end

  def test_reconciliation_leaves_a_queued_worker_alone_while_its_predecessor_runs
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    3.times { apply!(build_engine, "ReconcileSessions") }
    dependent = agent(engine, dependent_id)

    assert_equal "queued", dependent.fetch("status")
    assert_equal "waiting", dependent.fetch("harness_metadata").fetch("deferred_spawn").fetch("state")
    assert_equal 1, @harness_client.spawns.length
    assert_equal 1, logs_matching(engine, /Queued worker #{dependent_id}/).length
  end

  # --- Predecessor failure --------------------------------------------------------------------

  def test_errored_predecessor_cancels_the_queued_worker_with_a_warning
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    patch_agent!(predecessor_id) { |record| record["status"] = "errored" }
    apply!(engine, "ReconcileSessions")

    assert_nil agent(engine, dependent_id)
    cancel_log = state(engine).fetch("logs").find { |entry| entry.fetch("details", {})["agent_id"] == dependent_id && entry.fetch("level") == "warning" }
    refute_nil cancel_log, "expected a warning naming the cancelled dependent"
    assert_equal(
      "Cancelled queued worker #{dependent_id} because #{predecessor_id} errored before it could start.",
      cancel_log.fetch("message")
    )
    assert_equal "predecessor_errored", cancel_log.fetch("details").fetch("reason")
    assert_equal 1, @harness_client.spawns.length
  end

  def test_errored_predecessor_can_still_start_the_queued_worker_when_asked
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Pick up whatever is left.",
      after_agent_id: predecessor_id,
      if_predecessor_fails: "run"
    ).fetch("target_id")

    patch_agent!(predecessor_id) do |record|
      record["status"] = "errored"
      record["harness_metadata"] = record.fetch("harness_metadata").merge("last_assistant_text" => "Got halfway.")
    end
    apply!(engine, "ReconcileSessions")
    dependent = agent(engine, dependent_id)
    spawn_prompt = @harness_client.spawns.last.fetch("prompt")

    assert_equal "working", dependent.fetch("status")
    assert_equal "errored", dependent.fetch("harness_metadata").fetch("deferred_spawn").fetch("predecessor_status")
    assert_includes spawn_prompt, "Got halfway."
    assert_includes spawn_prompt, "did not finish cleanly"
    assert_includes(
      log_messages(engine),
      "Starting queued worker #{dependent_id} because #{predecessor_id} settled (errored). " \
        "Its predecessor did not complete, and if_predecessor_fails is \"run\"."
    )
  end

  def test_missing_predecessor_cancels_the_queued_worker
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    patch_state! { |state| state["agents"] = state.fetch("agents").reject { |record| record.fetch("id") == predecessor_id } }
    apply!(engine, "ReconcileSessions")

    assert_nil agent(engine, dependent_id)
    assert_includes(
      log_messages(engine),
      "Cancelled queued worker #{dependent_id} because #{predecessor_id} is no longer in Meringue state."
    )
  end

  # --- Kill and prune interaction --------------------------------------------------------------

  def test_killing_the_predecessor_cancels_the_queued_worker_in_the_same_command
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    result = apply!(engine, "Kill", { "target_id" => predecessor_id })

    assert_nil agent(engine, predecessor_id)
    assert_nil agent(engine, dependent_id)
    kill_log = state(engine).fetch("logs").find { |entry| entry.fetch("message") == "Killed #{predecessor_id}." }
    assert_equal [dependent_id], kill_log.fetch("details").fetch("cancelled_deferred_agent_ids")
    assert_includes(
      log_messages(engine),
      "Cancelled queued worker #{dependent_id} because #{predecessor_id} was killed before it could start."
    )
    assert_equal "accepted", result.fetch("status")
  end

  def test_killing_a_queued_worker_cancels_only_that_worker
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    apply!(engine, "Kill", { "target_id" => dependent_id })

    assert_nil agent(engine, dependent_id)
    assert_equal "working", agent(engine, predecessor_id).fetch("status")
  end

  def test_killing_the_predecessor_cascades_through_a_chain_of_queued_workers
    engine = build_engine
    context = project_with_issue(engine)
    first_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    second_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Second.", after_agent_id: first_id).fetch("target_id")
    third_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Third.", after_agent_id: second_id).fetch("target_id")

    apply!(engine, "Kill", { "target_id" => first_id })

    assert_nil agent(engine, second_id)
    assert_nil agent(engine, third_id)
    assert_includes(
      log_messages(engine),
      "Cancelled queued worker #{third_id} because #{second_id} was cancelled before it could start."
    )
  end

  def test_prune_retains_a_settled_predecessor_while_a_worker_still_waits_for_it
    engine = build_engine
    context = project_with_issue(engine, title: "Research the crash")
    implementation_issue_id = create_issue(engine, context.fetch("project_id"), title: "Fix the crash")
    predecessor_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Research.").fetch("target_id")
    dependent_id = spawn_worker(engine, implementation_issue_id, prompt: "Fix it.", after_agent_id: predecessor_id).fetch("target_id")

    # The research issue is settled and would normally be pruned; its worker is still a predecessor.
    patch_agent!(predecessor_id) { |record| record["status"] = "completed" }
    patch_state! do |state|
      state.fetch("issues").each { |record| record["status"] = "completed" if record.fetch("id") == context.fetch("issue_id") }
    end
    result = apply!(engine, "Prune")
    decision = result.dig("result", "issue_decisions").find { |entry| entry.fetch("issue_id") == context.fetch("issue_id") }

    refute_nil agent(engine, predecessor_id), "the predecessor must survive while a dependent waits"
    refute_nil agent(engine, dependent_id)
    assert_equal false, decision.fetch("prunable")
    assert_includes decision.fetch("blockers"), "pending_deferred_dependents"
    assert_equal [dependent_id], decision.fetch("deferred_dependent_worker_ids")
  end

  # --- Replacement ----------------------------------------------------------------------------

  def test_replacing_the_predecessor_repoints_the_queued_worker_at_its_successor
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    successor_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Investigate again.",
      replace_agent_id: predecessor_id
    ).fetch("target_id")
    apply!(engine, "ReconcileSessions")
    dependent = agent(engine, dependent_id)

    assert_equal "queued", dependent.fetch("status")
    assert_equal successor_id, dependent.fetch("after_agent_id")
    assert_equal predecessor_id, dependent.fetch("harness_metadata").fetch("deferred_spawn").fetch("repointed_from_agent_id")
    assert_includes(
      log_messages(engine),
      "Queued worker #{dependent_id} now waits for #{successor_id} because #{predecessor_id} was replaced."
    )
  end

  def test_a_repointed_worker_starts_when_the_replacement_completes
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")
    successor_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Retry.", replace_agent_id: predecessor_id).fetch("target_id")

    engine.mark_worker_completed(agent_id: successor_id, last_assistant_text: "Second attempt worked.")
    dependent = agent(engine, dependent_id)

    assert_equal "working", dependent.fetch("status")
    assert_equal successor_id, dependent.fetch("after_agent_id")
    assert_includes @harness_client.spawns.last.fetch("prompt"), "Second attempt worked."
    assert_includes(
      log_messages(engine),
      "Starting queued worker #{dependent_id} because #{successor_id} settled (completed). " \
        "It was queued behind #{predecessor_id}, which that worker replaced."
    )
  end

  # --- Validation and guardrails ---------------------------------------------------------------

  def test_unknown_predecessor_is_rejected
    engine = build_engine
    context = project_with_issue(engine)

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "after_agent_id" => "P1-I1-W9" }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "after_agent_not_found"
    assert_empty @harness_client.spawns
  end

  def test_waiting_for_a_head_is_rejected
    engine = build_engine
    context = project_with_issue(engine)
    head_id = apply!(engine, "SpawnHead", { "user_message" => "look into the crash" }).fetch("target_id")

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "after_agent_id" => head_id }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "after_agent_is_not_worker"
  end

  def test_after_agent_and_replace_agent_are_mutually_exclusive
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    result = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Go.",
        "after_agent_id" => predecessor_id,
        "replace_agent_id" => predecessor_id
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "deferred_after_agent_conflicts_with_replace"
    assert_equal 1, @harness_client.spawns.length
  end

  def test_an_unknown_failure_policy_is_rejected
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    result = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Go.",
        "after_agent_id" => predecessor_id,
        "if_predecessor_fails" => "retry-forever"
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "invalid_if_predecessor_fails"
  end

  def test_a_killed_predecessor_cannot_be_waited_for
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    patch_agent!(predecessor_id) { |record| record["status"] = "killed" }

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "after_agent_id" => predecessor_id }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "deferred_predecessor_already_killed"
  end

  def test_a_chain_longer_than_the_limit_is_rejected
    engine = build_engine
    context = project_with_issue(engine)
    previous_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    limit = Meringue::Kernel::Engine::DEFERRED_WORKER_MAX_CHAIN_DEPTH

    limit.times do |index|
      previous_id = spawn_worker(
        engine,
        context.fetch("issue_id"),
        prompt: "Step #{index + 1}.",
        after_agent_id: previous_id
      ).fetch("target_id")
    end
    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "One too many.", "after_agent_id" => previous_id }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "deferred_chain_too_deep"
    assert_equal 1, @harness_client.spawns.length
  end

  def test_a_dependency_cycle_in_state_is_rejected_instead_of_queued
    engine = build_engine
    context = project_with_issue(engine)
    first_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    second_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Second.", after_agent_id: first_id).fetch("target_id")
    # Only reachable by corrupting state (or a future repointing bug): the predecessor now waits on
    # its own dependent.
    patch_agent!(first_id) do |record|
      record["status"] = "queued"
      record["after_agent_id"] = second_id
      record["harness_metadata"] = record.fetch("harness_metadata").merge(
        "deferred_spawn" => { "state" => "waiting", "after_agent_id" => second_id }
      )
    end

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Third.", "after_agent_id" => second_id }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "deferred_after_agent_cycle"
  end

  # --- Exactly-once ----------------------------------------------------------------------------

  def test_re_applying_the_same_queue_command_does_not_queue_a_second_worker
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    payload = { "issue_id" => context.fetch("issue_id"), "prompt" => "Ship it.", "after_agent_id" => predecessor_id }

    first = apply_raw(engine, "SpawnWorker", payload, command_id: "cmd-queue-1")
    second = apply_raw(engine, "SpawnWorker", payload, command_id: "cmd-queue-1")

    assert_equal "accepted", second.fetch("status")
    assert_equal first.fetch("target_id"), second.fetch("target_id")
    assert_equal 1, state(engine).fetch("agents").count { |record| record.fetch("status") == "queued" }
    assert_equal 1, logs_matching(engine, /Queued worker/).length
  end

  def test_recount_keeps_a_queued_dependency_pointing_at_its_renamed_predecessor
    engine = build_engine
    context = project_with_issue(engine, title: "First goal")
    middle_issue_id = create_issue(engine, context.fetch("project_id"), title: "Middle goal")
    chained_issue_id = create_issue(engine, context.fetch("project_id"), title: "Chained goal")
    predecessor_id = spawn_worker(engine, chained_issue_id, prompt: "Research.").fetch("target_id")
    dependent_id = spawn_worker(engine, chained_issue_id, prompt: "Implement.", after_agent_id: predecessor_id).fetch("target_id")

    # Removing the middle issue leaves a numbering gap, so Recount renames the chained issue and
    # both of its workers.
    apply!(engine, "Kill", { "target_id" => middle_issue_id })
    apply!(engine, "Recount")
    renamed_issue = state(engine).fetch("issues").find { |record| record.fetch("title") == "Chained goal" }
    workers = state(engine).fetch("agents").select { |record| record.fetch("issue_id") == renamed_issue.fetch("id") }
    renamed_predecessor = workers.find { |record| record.fetch("status") == "working" }
    renamed_dependent = workers.find { |record| record.fetch("status") == "queued" }

    refute_equal chained_issue_id, renamed_issue.fetch("id"), "expected Recount to renumber the chained issue"
    refute_equal dependent_id, renamed_dependent.fetch("id")
    assert_equal renamed_predecessor.fetch("id"), renamed_dependent.fetch("after_agent_id")
    assert_equal(
      renamed_predecessor.fetch("id"),
      renamed_dependent.fetch("harness_metadata").fetch("deferred_spawn").fetch("after_agent_id")
    )

    engine.mark_worker_completed(agent_id: renamed_predecessor.fetch("id"), last_assistant_text: "Found it.")

    assert_equal "working", agent(engine, renamed_dependent.fetch("id")).fetch("status")
    assert_includes @harness_client.spawns.last.fetch("prompt"), "Found it."
  end

  def test_get_info_reports_what_a_queued_worker_is_waiting_for
    engine = build_engine
    context = project_with_issue(engine)
    predecessor_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    dependent_id = spawn_worker(engine, context.fetch("issue_id"), prompt: "Ship it.", after_agent_id: predecessor_id).fetch("target_id")

    dependent_info = apply!(engine, "GetInfo", { "target_id" => dependent_id }).fetch("result")
    predecessor_info = apply!(engine, "GetInfo", { "target_id" => predecessor_id }).fetch("result")

    assert_equal "waiting", dependent_info.fetch("deferred_spawn").fetch("state")
    assert_equal predecessor_id, dependent_info.fetch("deferred_spawn").fetch("after_agent_id")
    assert_equal "working", dependent_info.fetch("deferred_spawn").fetch("after_agent_status")
    assert_equal [dependent_id], predecessor_info.fetch("waiting_dependent_agent_ids")
  end
end
