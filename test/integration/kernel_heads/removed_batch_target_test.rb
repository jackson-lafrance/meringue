# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

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

    skip_log = logs.find { |entry| entry.fetch("message", "").start_with?("Skipped ModifyIssue:") }
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

    apply_head_result(
      head_id,
      head_result(commands: [
        modify_issue_command(issue_id: live_id, status: "working"),
        modify_issue_command(issue_id: doomed_id, status: "completed")
      ]),
      cleanup_head: false
    )

    summary = logs.find { |entry| entry.fetch("message", "").start_with?("Head result for #{head_id}:") }
    refute_nil summary
    assert_equal "info", summary.fetch("level")
    assert_equal(
      "Head result for #{head_id}: 1 accepted, 0 rejected, 0 failed. 1 command skipped because its target was removed before this result was applied.",
      summary.fetch("message")
    )
    assert_equal 1, summary.dig("details", "skipped_command_count")

    head = find_agent_record(head_id)
    assert_equal "completed", head.fetch("status"), "a removed target does not block the head"
    assert_equal "applied", head.fetch("harness_metadata").fetch("head_result_apply_state")
    assert_equal "accepted", head.fetch("harness_metadata").fetch("head_result_apply_status")
    assert_equal 1, head.fetch("harness_metadata").fetch("head_result_skipped_command_count")
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

    skip_log = logs.find { |entry| entry.fetch("message", "").start_with?("Skipped SpawnWorker:") }
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

  def test_removal_ledger_is_bounded_and_records_the_reason
    project_id = add_project!
    doomed_id = seed_issue!(project_id, "Finished goal")
    settle_issue!(doomed_id)
    apply_command("Prune", {})

    ledger = JSON.parse(File.read(state_path)).fetch("metadata").fetch("removed_issues")
    entry = ledger.find { |record| record.fetch("issue_id") == doomed_id }
    refute_nil entry
    assert_equal "prune", entry.fetch("reason")
    refute_nil entry.fetch("removed_at")
    assert_operator ledger.length, :<=, Meringue::Kernel::Engine::REMOVED_ISSUE_LEDGER_LIMIT
  end

  private

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
