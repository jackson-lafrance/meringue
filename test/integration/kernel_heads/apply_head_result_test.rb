# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# ApplyHeadResult contract: the kernel validates and applies every proposed command
# itself, in the order the head proposed them, and reports one result per command.
class KernelHeadsApplyResultTest < KernelHeadsTestCase
  def test_head_title_and_summary_are_applied_to_the_agent_tree
    project_id = add_project!
    head_id = spawn_head!("Route one goal")
    result = apply_head_result(
      head_id,
      head_result(
        commands: [create_issue_command(project_id: project_id, title: "Titled goal")],
        title: "Route the titled goal",
        summary: "Created one issue for the titled goal."
      ),
      cleanup_head: false
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal "Route the titled goal", result.dig("result", "title")
    assert_equal "Created one issue for the titled goal.", result.dig("result", "summary")

    metadata = find_agent_record(head_id).fetch("harness_metadata")
    assert_equal "Route the titled goal", metadata.fetch("title")
    assert_equal "Created one issue for the titled goal.", metadata.fetch("summary")
    assert_equal "applied", metadata.fetch("head_result_apply_state")
    assert_equal "accepted", metadata.fetch("head_result_apply_status")
    assert_equal "completed", find_agent_record(head_id).fetch("status")
  end

  def test_summary_only_head_result_logs_the_summary_as_head_output
    head_id = spawn_head!("Just tell me what you see")
    apply_head_result(head_id, head_result(summary: "Nothing to route; state is empty."), cleanup_head: false)

    entry = logs.find { |log| log.fetch("message", nil) == "Nothing to route; state is empty." }
    refute_nil entry
    assert_equal "head", entry.fetch("source_type")
    assert_equal head_id, entry.fetch("source_id")
    assert_equal "head_summary", entry.fetch("details").fetch("kind")
  end

  def test_predicted_ids_chain_across_one_batch
    other_project = File.join(temp_root, "chained-project")
    FileUtils.mkdir_p(other_project)
    head_id = spawn_head!("Register a project, file an issue, and start a worker")

    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          { "type" => "AddProject", "payload" => { "path" => other_project, "name" => "chained-project" } },
          create_issue_command(project_id: "P1", title: "Chained goal"),
          spawn_worker_command(issue_id: "P1-I1", title: "Chained goal")
        ]
      )
    )

    assert_equal(
      [["AddProject", "accepted"], ["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]],
      command_statuses(result)
    )
    assert_equal %w[P1 P1-I1 P1-I1-W1], command_results(result).map { |command| command.fetch("target_id") }
    assert_equal %w[H1-C1 H1-C2 H1-C3], command_results(result).map { |command| command.fetch("command_id") }
    assert_equal ["P1-I1"], issues.map { |issue| issue.fetch("id") }
    assert_equal ["P1-I1-W1"], agents(type: "worker").map { |agent| agent.fetch("id") }
  end

  def test_created_issue_records_the_originating_head
    project_id = add_project!
    head_id = spawn_head!("File an issue")
    apply_head_result(head_id, head_result(commands: [create_issue_command(project_id: project_id, title: "Attributed goal")]))

    assert_equal head_id, issues.fetch(0).fetch("originating_head_id")
  end

  def test_wrong_predicted_project_id_is_rejected_without_creating_records
    add_project!
    head_id = spawn_head!("File an issue in the wrong project")
    result = apply_head_result(
      head_id,
      head_result(commands: [create_issue_command(project_id: "P7", title: "Bad prediction")]),
      cleanup_head: false
    )

    rejected = command_results(result).fetch(0)
    assert_equal "rejected", rejected.fetch("status")
    assert_includes rejected.fetch("errors"), "project_not_found"
    assert_empty issues
  end

  def test_wrong_predicted_issue_id_is_remapped_to_the_batch_issue
    project_id = add_project!
    head_id = spawn_head!("File an issue and start a worker on the wrong id")
    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Good issue"),
          spawn_worker_command(issue_id: "#{project_id}-I9")
        ]
      ),
      cleanup_head: false
    )

    assert_equal([["CreateIssue", "accepted"], ["SpawnWorker", "accepted"]], command_statuses(result))
    assert_equal ["#{project_id}-I1"], issues.map { |issue| issue.fetch("id") }
    assert_equal ["#{project_id}-I1"], agents(type: "worker").map { |agent| agent.fetch("issue_id") }
  end

  def test_commands_are_applied_in_the_proposed_order
    project_id = add_project!
    head_id = spawn_head!("Order matters")
    # Spawning before the issue exists must fail, proving order is preserved.
    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          spawn_worker_command(issue_id: "#{project_id}-I1"),
          create_issue_command(project_id: project_id, title: "Created second")
        ]
      ),
      cleanup_head: false
    )

    assert_equal([["SpawnWorker", "rejected"], ["CreateIssue", "accepted"]], command_statuses(result))
    assert_empty agents(type: "worker")
  end

  def test_unknown_command_types_are_rejected
    head_id = spawn_head!("Try an invented command")
    result = apply_head_result(
      head_id,
      head_result(commands: [{ "type" => "Frobnicate", "payload" => { "anything" => true } }]),
      cleanup_head: false
    )

    rejected = command_results(result).fetch(0)
    assert_equal "rejected", rejected.fetch("status")
    assert_equal "Frobnicate", rejected.fetch("command_type")
    assert_includes rejected.fetch("errors"), "unknown_command"
    assert_includes rejected.fetch("message"), "Unknown kernel command: Frobnicate"
  end

  def test_snake_case_command_aliases_are_canonicalized
    project_id = add_project!
    head_id = spawn_head!("Use snake_case command types")
    result = apply_head_result(
      head_id,
      head_result(commands: [{ "type" => "create_issue", "payload" => { "project_id" => project_id, "title" => "Aliased goal" } }]),
      cleanup_head: false
    )

    assert_equal([["CreateIssue", "accepted"]], command_statuses(result))
    assert_equal ["Aliased goal"], issues.map { |issue| issue.fetch("title") }
  end

  def test_failed_commands_mark_the_head_blocked_and_log_an_error_summary
    failing_engine = build_engine(harness_client: KernelHeadsSupport::FailingSpawnHarnessClient.new)
    project_id = add_project!(target_engine: failing_engine)
    head_id = spawn_head!("Start a worker that cannot spawn", target_engine: failing_engine)
    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Unspawnable"),
          spawn_worker_command(issue_id: "#{project_id}-I1")
        ]
      ),
      target_engine: failing_engine
    )

    assert_equal([["CreateIssue", "accepted"], ["SpawnWorker", "failed"]], command_statuses(result))

    failing_state = failing_engine.list_all
    head = find_agent_record(head_id, current_state: failing_state)
    assert_equal "blocked", head.fetch("status")
    assert_equal "partially_applied", head.fetch("harness_metadata").fetch("head_result_apply_state")

    summary = logs(current_state: failing_state).find { |log| log.fetch("message", "").start_with?("Head result for #{head_id}:") }
    refute_nil summary
    assert_equal "kernel", summary.fetch("source_type")
    assert_equal head_id, summary.fetch("source_id")
    assert_equal "error", summary.fetch("level")
    assert_equal "1 accepted, 0 rejected, 1 failed.", summary.fetch("message").split(": ").last
  end

  def test_rejected_commands_mark_the_head_blocked_with_a_warning_summary
    head_id = spawn_head!("Propose an impossible command")
    apply_head_result(head_id, head_result(commands: [create_issue_command(project_id: "P404", title: "Nope")]))

    summary = logs.find { |log| log.fetch("message", "").start_with?("Head result for #{head_id}:") }
    refute_nil summary
    assert_equal "warning", summary.fetch("level")
    assert_equal 1, Array(summary.fetch("details").fetch("command_results")).length
    assert_equal "blocked", find_agent_record(head_id).fetch("status")
  end

  def test_missing_head_id_is_rejected
    result = apply_command("ApplyHeadResult", { "head_result" => KernelHeadsSupport.empty_head_result })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "head_id is required"
  end

  def test_unknown_head_id_is_rejected
    result = apply_head_result("H99", KernelHeadsSupport.empty_head_result)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "head_not_found"
  end

  def test_applying_a_head_result_to_a_worker_is_rejected
    project_id = add_project!
    head_id = spawn_head!("Spawn a worker")
    apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Worker holder"),
          spawn_worker_command(issue_id: "#{project_id}-I1")
        ]
      )
    )
    worker_id = agents(type: "worker").fetch(0).fetch("id")

    result = apply_head_result(worker_id, KernelHeadsSupport.empty_head_result)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_is_not_head"
  end

  def test_malformed_head_results_are_rejected_before_any_command_runs
    project_id = add_project!
    head_id = spawn_head!("Malformed result")
    result = apply_command(
      "ApplyHeadResult",
      {
        "head_id" => head_id,
        "head_result" => {
          "title" => 42,
          "summary" => nil,
          "commands" => [{ "type" => "CreateIssue" }, "not-an-object"],
          "questions" => "not-an-array"
        }
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "head_result.title must be a string"
    assert_includes result.fetch("errors"), "head_result.summary must be a string"
    assert_includes result.fetch("errors"), "head_result.commands[0].payload must be an object"
    assert_includes result.fetch("errors"), "head_result.commands[1] must be an object"
    assert_includes result.fetch("errors"), "head_result.questions must be an array"
    assert_empty issues
    assert_equal "completed", find_agent_record(head_id).fetch("status")
    refute_nil project_id
  end

  def test_head_result_must_be_an_object
    head_id = spawn_head!("Not an object")
    result = apply_command("ApplyHeadResult", { "head_id" => head_id, "head_result" => "just a string" })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "head_result must be an object"
  end
end
