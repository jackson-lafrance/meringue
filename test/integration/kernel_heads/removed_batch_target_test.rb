# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# Runs a removal at the exact command submission boundary. This models the inter-process race
# without sleeps: the head's fresh target check succeeds, then kill/prune wins before dispatch.
class KernelHeadsSubmissionRaceEngine < Meringue::Kernel::Engine
  def remove_before_next_issue_command!(command)
    @submission_race_action = command
  end

  def apply(command)
    if @submission_race_action && command.is_a?(Hash) && command.fetch("type", nil).to_s == "ModifyIssue"
      action = @submission_race_action
      @submission_race_action = nil
      super(action)
    end
    super(command)
  end
end

# A head is spawned against a snapshot of state and its result is applied seconds later. A /prune
# or /kill can land in between, so the issue a head legitimately read can be gone by the time its
# command is applied.
#
# The regression this file locks down: that race used to be reported as
#
#   Rejected ModifyIssue: ModifyIssue targets issue P4-I4, which this head result did not create
#   and the head could not have seen. Reference the issue-creating command with issue_from_command
#   instead of predicting an issue id.
#
# because visibility was decided from live state instead of the head's spawn snapshot. The head had
# read a real id, so the message blamed it for a mistake it did not make, prescribed a fix that did
# not apply, marked the head blocked, and dropped part of the user's intent behind a warning nobody
# could act on.
class KernelHeadsRemovedBatchTargetTest < KernelHeadsTestCase
  # The kill lands after the fresh check but before ModifyIssue is dispatched. The result is
  # converted from a generic issue_not_found failure into a safe skip and the user line is retained.
  def test_kill_wins_the_submission_race_without_losing_the_request
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Concurrent kill target")
    race_engine = build_submission_race_engine
    head_id = spawn_head!("Update the target while another command kills it", target_engine: race_engine)
    race_engine.remove_before_next_issue_command!("type" => "Kill", "payload" => { "target_id" => doomed_id })

    result = apply_head_result(
      head_id,
      head_result(commands: [modify_issue_command(issue_id: doomed_id, status: "working")]),
      cleanup_head: false,
      target_engine: race_engine
    )

    skipped = command_results(result).fetch(0)
    assert_equal ["issue_removed_before_head_result_applied"], skipped.fetch("errors")
    assert_includes skipped.fetch("message"), "removed by a kill"
    replacement_id = result.dig("result", "automatic_retry", "target_id")
    refute_nil replacement_id
    assert_nil find_agent_record(head_id, current_state: race_engine.list_all)
    assert_includes find_agent_record(replacement_id, current_state: race_engine.list_all).dig("harness_metadata", "head_request", "user_message"), "Update the target"
    unrouted = logs(current_state: race_engine.list_all).find { |entry| entry.dig("details", "kind") == "unrouted_user_message" }
    refute_nil unrouted
    assert_includes unrouted.dig("details", "user_message"), "Update the target"
  end

  # The same boundary with prune exercises the removal ledger used by the bulk-removal path.
  def test_prune_wins_the_submission_race_without_losing_the_request
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Concurrent prune target")
    settle_issue!(doomed_id)
    race_engine = build_submission_race_engine
    head_id = spawn_head!("Update the finished target while prune runs", target_engine: race_engine)
    race_engine.remove_before_next_issue_command!("type" => "Prune", "payload" => {})

    result = apply_head_result(
      head_id,
      head_result(commands: [modify_issue_command(issue_id: doomed_id, status: "working")]),
      cleanup_head: false,
      target_engine: race_engine
    )

    skipped = command_results(result).fetch(0)
    assert_equal ["issue_removed_before_head_result_applied"], skipped.fetch("errors")
    assert_includes skipped.fetch("message"), "removed by a prune"
    replacement_id = result.dig("result", "automatic_retry", "target_id")
    refute_nil replacement_id
    assert_nil find_agent_record(head_id, current_state: race_engine.list_all)
    assert_includes find_agent_record(replacement_id, current_state: race_engine.list_all).dig("harness_metadata", "head_request", "user_message"), "Update the finished target"
    unrouted = logs(current_state: race_engine.list_all).find { |entry| entry.dig("details", "kind") == "unrouted_user_message" }
    refute_nil unrouted
    assert_includes unrouted.dig("details", "user_message"), "Update the finished target"
  end

  # The reported failure, end to end: /prune removes an issue while a head result is in flight.
  def test_prune_during_a_head_result_skips_the_removed_issue_instead_of_blaming_the_head
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    live_id = seed_issue!(project_id, "Live goal")
    settle_issue!(doomed_id)

    head_id = spawn_head!("Get all the failed work moving again")
    assert_includes head_snapshot_issue_ids(head_id), doomed_id, "the head was spawned with the issue in view"

    pruned = apply_command("Prune", {})
    assert_includes Array(pruned.dig("result", "removed_issue_ids")), doomed_id
    assert_nil issues.find { |issue| issue.fetch("id") == doomed_id }

    result = apply_head_result(
      head_id,
      head_result(commands: [
        modify_issue_command(issue_id: live_id, status: "working"),
        modify_issue_command(issue_id: doomed_id, status: "completed", description: "Already delivered.")
      ]),
      cleanup_head: false
    )

    live_result, removed_result = command_results(result)
    assert_equal "accepted", live_result.fetch("status")
    assert_equal "working", issues.find { |issue| issue.fetch("id") == live_id }.fetch("status")

    assert_equal ["issue_removed_before_head_result_applied"], removed_result.fetch("errors")
    assert_equal doomed_id, removed_result.fetch("target_id")
    message = removed_result.fetch("message")
    assert_includes message, "issue #{doomed_id} was removed by a prune"
    assert_includes message, "after head #{head_id} was spawned with it in view"
    assert_includes message, "Dropped issue update (status \u2192 completed, description)"
    refute_includes message, "could not have seen"
    refute_includes message, "issue_from_command"

    skip_log = logs.find { |entry| Array(entry.dig("details", "errors")).include?("issue_removed_before_head_result_applied") }
    refute_nil skip_log, "the skip is visible in the log"
    assert_equal "info", skip_log.fetch("level"), "a target removed by a prune is not a head mistake"
    assert_equal doomed_id, skip_log.dig("details", "issue_id")
    assert_equal "issue_removed_before_head_result_applied", skip_log.dig("details", "reason")
    assert_equal "prune", skip_log.dig("details", "issue_removal", "reason")

    refute(log_messages.any? { |entry| entry.include?("could not have seen") }, "no log blames the head")
    refute(log_messages.any? { |entry| entry.start_with?("Rejected ModifyIssue:") })
  end

  # The dropped intent has to be readable in the batch summary too, or "1 rejected" is all the user
  # sees for an update that silently never happened.
  def test_batch_summary_counts_the_skip_separately_and_keeps_the_head_applied
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    live_id = seed_issue!(project_id, "Live goal")
    settle_issue!(doomed_id)
    head_id = spawn_head!("Tidy up the finished work")
    apply_command("Prune", {})

    result = apply_head_result(
      head_id,
      head_result(commands: [
        modify_issue_command(issue_id: live_id, status: "working"),
        modify_issue_command(issue_id: doomed_id, status: "completed")
      ]),
      cleanup_head: false
    )

    summary = logs.find { |entry| entry.fetch("message", "").include?("command skipped because") }
    refute_nil summary
    assert_equal "info", summary.fetch("level")
    assert_equal(
      "1 command skipped because its target was removed before this result was applied.",
      summary.fetch("message")
    )
    assert_equal 1, summary.dig("details", "skipped_command_count")

    replacement_id = result.dig("result", "automatic_retry", "target_id")
    refute_nil replacement_id
    assert_nil find_agent_record(head_id), "the routed head is replaced after the removal"
    assert_equal true, result.dig("result", "automatic_retry", "automatic")
    replacement_message = find_agent_record(replacement_id).dig("harness_metadata", "head_request", "user_message")
    assert_includes replacement_message, "Tidy up the finished work"
    assert_includes replacement_message, "ModifyIssue accepted"
    assert_includes replacement_message, "ModifyIssue rejected"
  end

  # H36 in the reported logs: every command in the batch pointed at one pruned issue, so the head
  # was left blocked with `0 accepted, 2 rejected` and the user's request vanished into two lines
  # that blamed the head. Nothing here can be applied, but nothing is the head's fault either.
  def test_whole_batch_aimed_at_a_removed_issue_is_skipped_and_the_message_is_surfaced
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Setup flow")
    settle_issue!(doomed_id)
    head_id = spawn_head!("I want the /setup flow to take over the whole screen with animations")
    apply_command("Prune", {})

    result = apply_head_result(
      head_id,
      head_result(commands: [
        modify_issue_command(issue_id: doomed_id, status: "working"),
        spawn_worker_command(issue_id: doomed_id, title: "Full-screen animated setup flow")
      ]),
      cleanup_head: false
    )

    statuses = command_results(result).map { |entry| entry.fetch("errors") }
    assert_equal [["issue_removed_before_head_result_applied"]] * 2, statuses

    summary = logs.find { |entry| entry.fetch("message", "").include?("commands skipped because") }
    assert_equal(
      "2 commands skipped because their targets were removed before this result was applied.",
      summary.fetch("message")
    )
    assert_equal "info", summary.fetch("level")

    replacement_id = result.dig("result", "automatic_retry", "target_id")
    refute_nil replacement_id
    assert_nil find_agent_record(head_id), "the unrouted request is handed to a replacement head"
    assert_includes find_agent_record(replacement_id).dig("harness_metadata", "head_request", "user_message"), "take over the whole screen"

    # The request itself still needs handling, so it is restated once, in full, without blaming the
    # head and without an error the user cannot act on.
    unrouted = logs.find { |entry| entry.dig("details", "kind") == "unrouted_user_message" }
    refute_nil unrouted
    assert_equal "warning", unrouted.fetch("level")
    assert_includes unrouted.fetch("message"), "Every command from head #{head_id} targeted a record that was removed before its result was applied"
    assert_includes unrouted.fetch("details").fetch("user_message"), "take over the whole screen"
    refute(log_messages.any? { |entry| entry.include?("could not have seen") })
  end

  # The same prune removed 21 agents. A head prompting a worker that was pruned under it is the
  # same race, and it used to stop at "Agent P3-I9-W2 does not exist." plus a blocked head.
  def test_prompt_for_a_worker_removed_by_the_prune_is_skipped_not_blamed
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    worker_id = agents(type: "worker").find { |agent| agent.fetch("issue_id", nil) == doomed_id }.fetch("id")
    settle_issue!(doomed_id)
    head_id = spawn_head!("Ask that worker to double-check its cleanup")
    apply_command("Prune", {})

    result = apply_head_result(
      head_id,
      head_result(commands: [
        { "type" => "PromptAgent", "payload" => { "agent_id" => worker_id, "prompt" => "Double-check the cleanup you reported.", "mode" => "normal" } }
      ]),
      cleanup_head: false
    )

    skipped = command_results(result).fetch(0)
    assert_equal ["agent_removed_before_head_result_applied"], skipped.fetch("errors")
    assert_equal worker_id, skipped.fetch("target_id")
    assert_includes skipped.fetch("message"), "agent #{worker_id} was removed by a prune"
    assert_includes skipped.fetch("message"), "so the prompt was not delivered"
    assert_includes skipped.fetch("message"), "Dropped prompt \"Double-check the cleanup you reported.\""
    replacement_id = result.dig("result", "automatic_retry", "target_id")
    refute_nil replacement_id
    assert_nil find_agent_record(head_id)
    assert_includes find_agent_record(replacement_id).dig("harness_metadata", "head_request", "user_message"), "double-check its cleanup"

    skip_log = logs.find { |entry| Array(entry.dig("details", "errors")).include?("agent_removed_before_head_result_applied") }
    refute_nil skip_log
    assert_equal "warning", skip_log.fetch("level")
    replacement_id = result.dig("result", "automatic_retry", "target_id")
    refute_nil replacement_id
    assert_nil find_agent_record(head_id)
  end

  # Killing a record a prune already removed is a no-op whose intent is already satisfied.
  def test_kill_of_an_already_removed_issue_is_a_quiet_no_op
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    settle_issue!(doomed_id)
    head_id = spawn_head!("Kill off the finished goal")
    apply_command("Prune", {})

    result = apply_head_result(
      head_id,
      head_result(commands: [{ "type" => "Kill", "payload" => { "target_id" => doomed_id } }]),
      cleanup_head: false
    )

    skipped = command_results(result).fetch(0)
    assert_equal ["issue_removed_before_head_result_applied"], skipped.fetch("errors")
    assert_includes skipped.fetch("message"), "so there was nothing left to kill"
    skip_log = logs.find { |entry| Array(entry.dig("details", "errors")).include?("issue_removed_before_head_result_applied") }
    refute_nil skip_log
    assert_equal "info", skip_log.fetch("level")
    replacement_id = result.dig("result", "automatic_retry", "target_id")
    refute_nil replacement_id
    assert_nil find_agent_record(head_id)
    assert_includes find_agent_record(replacement_id).dig("harness_metadata", "head_request", "user_message"), "Kill off the finished goal"
  end

  # A worker id the user types after a prune gets the same explanation, without the batch machinery.
  def test_typed_prompt_for_a_pruned_worker_names_the_removal
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    worker_id = agents(type: "worker").find { |agent| agent.fetch("issue_id", nil) == doomed_id }.fetch("id")
    settle_issue!(doomed_id)
    apply_command("Prune", {})

    result = apply_command("PromptAgent", { "agent_id" => worker_id, "prompt" => "Keep going." })

    assert_equal "rejected", result.fetch("status")
    assert_equal ["agent_not_found"], result.fetch("errors")
    assert_includes result.fetch("message"), "Agent #{worker_id} no longer exists: it was removed by a prune"
    assert_includes result.fetch("message"), "Dropped prompt \"Keep going.\""
  end

  # The boundary of this fix, asserted so it cannot drift: a command that genuinely failed (H26's
  # `git worktree add` timeout) and the dependent command that could not resolve its predecessor are
  # a different root cause. They still count as rejected/failed and still leave the head blocked for
  # inspection; making such a head reprompt-able is owned elsewhere.
  def test_a_genuinely_failed_command_still_blocks_the_head
    project_id = add_project!
    engine_with_failing_spawn = build_engine(
      head_runner: KernelHeadsSupport::StubHeadRunner.new,
      harness_client: KernelHeadsSupport::FailingSpawnHarnessClient.new
    )
    head_id = spawn_head!("Fix the slow query and then pair review it", target_engine: engine_with_failing_spawn)

    result = apply_head_result(
      head_id,
      head_result(commands: [
        create_issue_command(project_id: project_id, title: "Slow query", command_id: "issue"),
        spawn_worker_command(issue_id: "@issue", title: "Force the right index", command_id: "fix"),
        spawn_worker_command(issue_id: "@issue", title: "Devx pair review", extra: { "after_from_command" => "fix" })
      ]),
      cleanup_head: false,
      target_engine: engine_with_failing_spawn
    )

    statuses = command_results(result).map { |entry| entry.fetch("status") }
    assert_equal %w[accepted failed rejected], statuses
    assert_equal "blocked", find_agent_record(head_id, current_state: engine_with_failing_spawn.list_all).fetch("status")
    summary = logs(current_state: engine_with_failing_spawn.list_all)
             .find { |entry| entry.fetch("message", "").start_with?("Head result for #{head_id}:") }
    assert_nil summary, "acceptance counts are not rendered as a batch summary"
  end

  def test_killed_issue_target_names_the_kill_rather_than_a_prune
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Killed goal")
    head_id = spawn_head!("Close out the killed goal")
    apply_command("Kill", { "target_id" => doomed_id })

    result = apply_head_result(
      head_id,
      head_result(commands: [modify_issue_command(issue_id: doomed_id, status: "completed")]),
      cleanup_head: false
    )

    removed_result = command_results(result).fetch(0)
    assert_equal ["issue_removed_before_head_result_applied"], removed_result.fetch("errors")
    assert_includes removed_result.fetch("message"), "was removed by a kill"
  end

  # A dropped worker is dropped work, so it stays a warning: the wording is corrected, not muted.
  def test_spawn_worker_for_a_removed_issue_is_skipped_as_a_warning_naming_the_worker
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    settle_issue!(doomed_id)
    head_id = spawn_head!("Keep the finished goal moving")
    apply_command("Prune", {})

    result = apply_head_result(
      head_id,
      head_result(commands: [spawn_worker_command(issue_id: doomed_id, title: "Re-run the cleanup")]),
      cleanup_head: false
    )

    skipped = command_results(result).fetch(0)
    assert_equal ["issue_removed_before_head_result_applied"], skipped.fetch("errors")
    assert_includes skipped.fetch("message"), "so no worker was started on it"
    assert_includes skipped.fetch("message"), "Dropped worker \"Re-run the cleanup\""
    assert_empty agents(type: "worker").select { |agent| agent.fetch("issue_id", nil) == doomed_id }

    skip_log = logs.find { |entry| Array(entry.dig("details", "errors")).include?("issue_removed_before_head_result_applied") }
    refute_nil skip_log
    assert_equal "warning", skip_log.fetch("level"), "dropped work stays a warning"

    unrouted = logs.find { |entry| entry.dig("details", "kind") == "unrouted_user_message" }
    refute_nil unrouted, "a batch that routed nothing still surfaces the user's message"
    assert_equal "warning", unrouted.fetch("level")
    assert_includes unrouted.fetch("message"), "targeted a record that was removed before its result was applied"
  end

  # The other half of the distinction: an id the head never saw is still a mispredicted id.
  def test_issue_id_the_head_never_saw_is_still_rejected_as_a_prediction
    project_id = add_project!
    seed_issue!(project_id, "Only goal")
    head_id = spawn_head!("Invent an issue id")

    result = apply_head_result(
      head_id,
      head_result(commands: [modify_issue_command(issue_id: "#{project_id}-I99", status: "completed")]),
      cleanup_head: false
    )

    rejected = command_results(result).fetch(0)
    assert_equal "rejected", rejected.fetch("status")
    assert_equal ["issue_id_not_created_by_this_head_result"], rejected.fetch("errors")
    assert_includes rejected.fetch("message"), "could not have seen"
    assert_includes rejected.fetch("message"), "issue_from_command"
    # Even a genuine head mistake has to say what was dropped.
    assert_includes rejected.fetch("message"), "Dropped issue update (status \u2192 completed)"
    assert_equal "blocked", find_agent_record(head_id).fetch("status")
  end

  # H38 in the reported logs: a head spawned after the prune, reusing an id from the warning text
  # the user pasted. That is not a removal race, but the message should still say what happened to
  # the id instead of only asserting the head could not have seen it.
  def test_issue_removed_before_the_head_was_spawned_is_rejected_but_explained
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    settle_issue!(doomed_id)
    apply_command("Prune", {})
    head_id = spawn_head!("Fix whatever caused that warning about #{doomed_id}")

    result = apply_head_result(
      head_id,
      head_result(commands: [modify_issue_command(issue_id: doomed_id, status: "completed")]),
      cleanup_head: false
    )

    rejected = command_results(result).fetch(0)
    assert_equal "rejected", rejected.fetch("status")
    assert_equal ["issue_id_not_created_by_this_head_result"], rejected.fetch("errors")
    assert_includes rejected.fetch("message"), "was removed by a prune"
    assert_includes rejected.fetch("message"), "before head #{head_id} was spawned"
    assert_includes rejected.fetch("message"), "Dropped issue update (status \u2192 completed)"
  end

  # An issue created by another head after this head was spawned is not a removal race either.
  def test_issue_created_after_the_head_was_spawned_is_still_rejected
    project_id = add_project!
    head_id = spawn_head!("Route against a snapshot")
    later_id = seed_issue!(project_id, "Created later")

    result = apply_head_result(
      head_id,
      head_result(commands: [modify_issue_command(issue_id: later_id, status: "completed")]),
      cleanup_head: false
    )

    rejected = command_results(result).fetch(0)
    assert_equal ["issue_id_not_created_by_this_head_result"], rejected.fetch("errors")
    assert_includes rejected.fetch("message"), "could not have seen"
  end

  # Heads recorded before spawn snapshots were tracked still get the right answer, because the
  # kernel records what it removed.
  def test_head_without_a_spawn_snapshot_uses_the_removal_ledger
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    settle_issue!(doomed_id)
    head_id = spawn_head!("Close out the finished goal")
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head.fetch("harness_metadata").delete("snapshot_issue_ids")
    end
    apply_command("Prune", {})

    result = apply_head_result(
      head_id,
      head_result(commands: [modify_issue_command(issue_id: doomed_id, status: "completed")]),
      cleanup_head: false
    )

    skipped = command_results(result).fetch(0)
    assert_equal ["issue_removed_before_head_result_applied"], skipped.fetch("errors")
    assert_includes skipped.fetch("message"), "was removed by a prune"
  end

  # With neither a snapshot nor a removal record the kernel cannot tell the two cases apart, so it
  # says so instead of asserting a prediction.
  def test_head_without_evidence_reports_an_unknown_target_without_blaming_the_head
    project_id = add_project!
    head_id = spawn_head!("Route against unknown state")
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head.fetch("harness_metadata").delete("snapshot_issue_ids")
    end

    result = apply_head_result(
      head_id,
      head_result(commands: [modify_issue_command(issue_id: "#{project_id}-I7", status: "completed")]),
      cleanup_head: false
    )

    rejected = command_results(result).fetch(0)
    assert_equal ["issue_id_not_created_by_this_head_result"], rejected.fetch("errors")
    assert_includes rejected.fetch("message"), "no spawn snapshot for this head"
    refute_includes rejected.fetch("message"), "could not have seen"
  end

  # The typed path benefits from the same record: a slash-command ModifyIssue on a pruned issue says
  # what happened to it and what the edit was.
  def test_typed_modify_issue_on_a_removed_issue_names_the_removal_and_the_dropped_update
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    settle_issue!(doomed_id)
    apply_command("Prune", {})

    result = apply_command("ModifyIssue", { "issue_id" => doomed_id, "status" => "working", "title" => "Reopened" })

    assert_equal "rejected", result.fetch("status")
    assert_equal ["issue_not_found"], result.fetch("errors")
    assert_includes result.fetch("message"), "Issue #{doomed_id} no longer exists: it was removed by a prune"
    assert_includes result.fetch("message"), "Dropped issue update (status \u2192 working, title \u2192 \"Reopened\")"
  end

  def test_removal_ledger_records_both_kinds_with_their_reason_and_stays_bounded
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    worker_id = agents(type: "worker").find { |agent| agent.fetch("issue_id", nil) == doomed_id }.fetch("id")
    settle_issue!(doomed_id)
    apply_command("Prune", {})

    metadata = JSON.parse(File.read(state_path)).fetch("metadata")
    issue_entry = metadata.fetch("removed_issues").find { |record| record.fetch("id") == doomed_id }
    agent_entry = metadata.fetch("removed_agents").find { |record| record.fetch("id") == worker_id }

    refute_nil issue_entry
    assert_equal ["issue", "prune"], [issue_entry.fetch("kind"), issue_entry.fetch("reason")]
    refute_nil issue_entry.fetch("removed_at")
    refute_nil agent_entry
    assert_equal ["agent", "prune"], [agent_entry.fetch("kind"), agent_entry.fetch("reason")]
    # Issues and agents are bounded separately, so pruning many workers cannot evict the issue
    # history an in-flight head result still needs.
    assert_operator metadata.fetch("removed_issues").length, :<=, Meringue::Kernel::Engine::REMOVED_RECORD_LEDGER_LIMIT
    assert_operator metadata.fetch("removed_agents").length, :<=, Meringue::Kernel::Engine::REMOVED_RECORD_LEDGER_LIMIT
  end

  private

  def build_submission_race_engine
    KernelHeadsSubmissionRaceEngine.new(
      store: Meringue::State::Store.new(path: @state_path),
      harness_client: Meringue::Harness::FakeClient.new,
      head_runner: KernelHeadsSupport::StubHeadRunner.new,
      workspace_manager: Meringue::Workspace::FakeManager.new(root_path: File.join(@temp_root, "workspaces")),
      cwd: @project_path,
      forge_client: KernelHeadsSupport::StubForgeClient.new,
      config_path: @config_path
    )
  end

  def modify_issue_command(issue_id:, status: nil, description: nil, title: nil)
    payload = { "issue_id" => issue_id }
    payload["status"] = status if status
    payload["description"] = description if description
    payload["title"] = title if title
    { "type" => "ModifyIssue", "payload" => payload }
  end

  def seed_issue!(project_id, title)
    head_id = spawn_head!("Seed #{title}")
    apply_head_result(
      head_id,
      head_result(commands: [
        create_issue_command(project_id: project_id, title: title, command_id: "seed"),
        spawn_worker_command(issue_id: "@seed", title: "#{title} worker")
      ]),
      cleanup_head: false
    )
    issues.find { |issue| issue.fetch("title") == title }.fetch("id")
  end

  # Makes an issue prunable the way finished work becomes prunable: its worker settles and the
  # issue itself reaches a terminal status.
  def settle_issue!(issue_id)
    agents(type: "worker").select { |agent| agent.fetch("issue_id", nil) == issue_id }.each do |worker|
      engine.mark_worker_completed(agent_id: worker.fetch("id"), last_assistant_text: "Done.")
    end
    apply_command("ModifyIssue", { "issue_id" => issue_id, "status" => "completed" })
  end

  def head_snapshot_issue_ids(head_id)
    Array(find_agent_record(head_id).fetch("harness_metadata").fetch("snapshot_issue_ids", []))
  end
end
