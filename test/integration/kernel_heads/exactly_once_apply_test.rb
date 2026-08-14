# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# One head result must be applied exactly once, even when it is re-applied, recovered
# after a crash, or raced by a second kernel instance sharing the same state file.
class KernelHeadsExactlyOnceApplyTest < KernelHeadsTestCase
  def routing_batch(project_id)
    head_result(
      commands: [
        create_issue_command(project_id: project_id, title: "Exactly once goal"),
        spawn_worker_command(issue_id: "#{project_id}-I1", title: "Exactly once goal")
      ],
      questions: [{ "question" => "Should this ship behind a flag?", "context" => "One clarification" }]
    )
  end

  def spawn_worker_logs(current_state: nil)
    logs_matching(current_state: current_state) { |log| log.fetch("message", "").start_with?("Spawned worker") }
  end

  # Recovery of an unapplied head batch runs inside reconciliation, which is how the
  # app reaches it after a restart.
  def recovered_head_results(target_engine: nil)
    result = apply_command("ReconcileSessions", {}, target_engine: target_engine)
    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    Array(result.dig("result", "recovered_head_results"))
  end

  def test_reapplying_the_same_head_result_does_not_duplicate_records
    project_id = add_project!
    head_id = spawn_head!("Route the exactly-once goal")
    batch = routing_batch(project_id)

    first = apply_head_result(head_id, batch, cleanup_head: false)
    second = apply_head_result(head_id, batch, cleanup_head: false)

    assert_equal "accepted", first.fetch("status")
    assert_equal "accepted", second.fetch("status")
    assert_equal ["#{project_id}-I1"], issues.map { |issue| issue.fetch("id") }
    assert_equal ["#{project_id}-I1-W1"], agents(type: "worker").map { |agent| agent.fetch("id") }
    assert_equal 1, questions.length
    assert_equal 1, spawn_worker_logs.length
    assert_equal first.dig("result", "question_ids"), second.dig("result", "question_ids")
    assert_empty logs_matching { |log| log.fetch("level", nil) == "error" }
  end

  def test_reapplying_a_text_only_result_logs_the_response_exactly_once
    head_id = spawn_head!("What does queued mean?")
    batch = head_result(
      summary: "Answered directly.",
      response: "Queued means the worker has not started yet.",
      commands: [],
      questions: []
    )

    first = apply_head_result(head_id, batch, cleanup_head: false)
    second = apply_head_result(head_id, batch, cleanup_head: false)

    assert_equal "accepted", first.fetch("status")
    assert_equal "accepted", second.fetch("status")
    assert second.dig("result", "duplicate_apply")
    response_logs = logs_matching { |log| log.dig("details", "kind") == "head_response" }
    assert_equal 1, response_logs.length
    assert_equal "Queued means the worker has not started yet.", response_logs.first.fetch("message")
    assert_empty logs_matching { |log| log.dig("details", "kind") == "unrouted_user_message" }
  end

  def test_second_apply_replays_results_from_the_command_journal
    project_id = add_project!
    head_id = spawn_head!("Journal the batch")
    batch = routing_batch(project_id)

    first = apply_head_result(head_id, batch, cleanup_head: false)
    journal = find_agent_record(head_id).fetch("harness_metadata").fetch("head_result_command_journal")

    assert_equal %w[H1-C1 H1-C2], journal.map { |entry| entry.fetch("command_id") }
    assert_equal %w[CreateIssue SpawnWorker], journal.map { |entry| entry.fetch("command_type") }
    assert_equal %w[accepted accepted], journal.map { |entry| entry.fetch("status") }
    assert_equal [0, 1], journal.map { |entry| entry.fetch("index") }
    journal.each { |entry| refute_nil entry.fetch("completed_at") }

    second = apply_head_result(head_id, batch, cleanup_head: false)
    assert_equal command_results(first).map { |result| result.fetch("target_id") },
                 command_results(second).map { |result| result.fetch("target_id") }
  end

  def test_a_batch_owned_by_another_kernel_instance_is_skipped
    project_id = add_project!
    head_id = spawn_head!("Someone else is applying this")
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head.fetch("harness_metadata").merge!(
        "head_result_apply_state" => "applying",
        "head_result_apply_owner" => "other-host:4242:1",
        "head_result_apply_owner_host" => "other-host",
        "head_result_apply_owner_pid" => 4242,
        "head_result_apply_heartbeat" => utc_now_iso8601
      )
    end

    result = apply_head_result(head_id, routing_batch(project_id), cleanup_head: false)

    assert_equal "accepted", result.fetch("status")
    assert_equal "head_result_apply_in_progress", result.dig("result", "skipped")
    assert_includes result.fetch("message"), "already being applied by another kernel instance"
    assert_empty issues
    assert_empty agents(type: "worker")
    assert_empty questions
  end

  def test_an_abandoned_apply_lease_does_not_block_a_new_apply
    project_id = add_project!
    head_id = spawn_head!("The previous owner is gone")
    stale_heartbeat = (Time.now.utc - 3_600).strftime("%Y-%m-%dT%H:%M:%SZ")
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head.fetch("harness_metadata").merge!(
        "head_result_apply_state" => "applying",
        "head_result_apply_owner" => "other-host:4242:1",
        "head_result_apply_owner_host" => "other-host",
        "head_result_apply_owner_pid" => 4242,
        "head_result_apply_heartbeat" => stale_heartbeat
      )
    end

    result = apply_head_result(head_id, routing_batch(project_id), cleanup_head: false)

    assert_nil result.dig("result", "skipped")
    assert_equal([["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(result))
    assert_equal 1, issues.length
  end

  def test_recovering_an_in_flight_batch_replays_the_journal_without_duplicating_work
    project_id = add_project!
    head_id = spawn_head!("Recover this batch")
    apply_head_result(head_id, routing_batch(project_id), cleanup_head: false)

    # Simulate a crash after the commands ran but before the batch was marked applied.
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head["status"] = "working"
      head.fetch("harness_metadata").delete("head_result_applied_at")
      head.fetch("harness_metadata")["head_result_apply_state"] = "applying"
    end

    recovered = recovered_head_results

    assert_equal 1, recovered.length
    assert_equal "accepted", recovered.fetch(0).fetch("status")
    assert_equal 1, issues.length
    assert_equal 1, agents(type: "worker").length
    assert_equal 1, questions.length
    assert_equal 1, spawn_worker_logs.length
  end

  def test_recovery_infers_already_applied_commands_when_the_journal_is_missing
    project_id = add_project!
    head_id = spawn_head!("Recover a legacy batch")
    apply_head_result(head_id, routing_batch(project_id), cleanup_head: false)

    # A head record written before the command journal existed.
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head["status"] = "working"
      head.fetch("harness_metadata").delete("head_result_applied_at")
      head.fetch("harness_metadata")["head_result_apply_state"] = "applying"
      head.fetch("harness_metadata")["head_result_command_journal"] = []
    end

    recovered = recovered_head_results
    results = command_results(recovered.fetch(0))

    assert_equal([["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(recovered.fetch(0)))
    results.each { |result| assert_includes result.fetch("message"), "Recovered previously applied" }
    assert_equal 1, issues.length
    assert_equal 1, agents(type: "worker").length
    assert_equal 1, spawn_worker_logs.length
  end

  def test_recovery_ignores_batches_owned_by_another_live_kernel_instance
    project_id = add_project!
    head_id = spawn_head!("Another instance owns this")
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head["status"] = "working"
      head.fetch("harness_metadata").merge!(
        "head_result" => routing_batch(project_id),
        "head_result_apply_state" => "applying",
        "head_result_apply_owner" => "other-host:4242:1",
        "head_result_apply_owner_host" => "other-host",
        "head_result_apply_owner_pid" => 4242,
        "head_result_apply_heartbeat" => utc_now_iso8601
      )
    end

    assert_empty recovered_head_results
    assert_empty issues
    assert_empty agents(type: "worker")
  end

  def test_two_kernel_instances_applying_one_batch_produce_one_worker
    entered = Queue.new
    release = Queue.new
    gated_engine = build_engine(harness_client: KernelHeadsSupport::GatedHarnessClient.new(entered: entered, release: release))
    other_engine = build_engine
    project_id = add_project!(target_engine: gated_engine)
    head_id = spawn_head!("Race the same batch", target_engine: gated_engine)
    batch = routing_batch(project_id)

    applier = Thread.new do
      Thread.current.report_on_exception = false
      apply_head_result(head_id, batch, cleanup_head: false, target_engine: gated_engine)
    end
    entered.pop
    concurrent = apply_head_result(head_id, batch, cleanup_head: false, target_engine: other_engine)
    release << true
    primary = applier.value

    shared_state = gated_engine.list_all
    assert_equal "accepted", primary.fetch("status")
    assert_equal([["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(primary))
    assert_equal "head_result_apply_in_progress", concurrent.dig("result", "skipped")
    assert_equal 1, agents(type: "worker", current_state: shared_state).length
    assert_equal 1, spawn_worker_logs(current_state: shared_state).length
    assert_equal 1, issues(current_state: shared_state).length
    assert_equal 1, questions(current_state: shared_state).length

    head = find_agent_record(head_id, current_state: shared_state)
    assert_equal "applied", head.fetch("harness_metadata").fetch("head_result_apply_state")
    refute_nil head.fetch("harness_metadata").fetch("head_result_applied_at")
  end

  def test_a_head_removed_mid_batch_does_not_raise
    killing_client = KernelHeadsSupport::HeadKillingHarnessClient.new
    killing_engine = build_engine(harness_client: killing_client)
    killing_client.engine = killing_engine
    project_id = add_project!(target_engine: killing_engine)
    head_id = spawn_head!("Lose the head mid-batch", target_engine: killing_engine)
    killing_client.head_id = head_id

    result = apply_head_result(head_id, routing_batch(project_id), cleanup_head: false, target_engine: killing_engine)

    assert_includes %w[accepted rejected], result.fetch("status")
    refute_includes result.fetch("message").to_s, "was checkpointed"
    killed_state = killing_engine.list_all
    assert_empty logs_matching(current_state: killed_state) { |log| log.fetch("message", "").include?("was checkpointed") }
  end
end
