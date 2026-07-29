# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# Every command a head proposes must leave an auditable log trail: accepted commands
# log against the record they touched, rejected and failed commands log the reason,
# and routing decisions carry routing metadata.
class KernelHeadsLoggingTest < KernelHeadsTestCase
  def log_with_message(prefix, current_state: nil)
    logs(current_state: current_state).find { |log| log.fetch("message", "").start_with?(prefix) }
  end

  def test_log_records_use_valid_source_types_and_levels
    project_id = add_project!
    head_id = spawn_head!("Route one goal")
    apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Audited goal"),
          spawn_worker_command(issue_id: "#{project_id}-I1", title: "Audited goal")
        ],
        questions: [{ "question" => "Anything else to include?", "context" => "audit" }]
      )
    )

    refute_empty logs
    logs.each do |entry|
      assert_includes Meringue::State::Models::LOG_SOURCE_TYPES, entry.fetch("source_type")
      assert_includes Meringue::State::Models::LOG_LEVELS, entry.fetch("level")
      assert_match(/\AL\d+\z/, entry.fetch("id"))
      refute_nil entry.fetch("timestamp")
      assert_kind_of Hash, entry.fetch("details")
    end
    assert_equal logs.map { |entry| entry.fetch("id") }, logs.map { |entry| entry.fetch("id") }.uniq
  end

  def test_accepted_head_commands_log_against_the_records_they_create
    other_project = File.join(temp_root, "logged-project")
    FileUtils.mkdir_p(other_project)
    head_id = spawn_head!("Register, file, and staff one goal")
    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          { "type" => "AddProject", "payload" => { "path" => other_project, "name" => "logged-project" } },
          create_issue_command(project_id: "P1", title: "Logged goal"),
          spawn_worker_command(issue_id: "P1-I1", title: "Logged goal")
        ]
      )
    )

    project_log = log_with_message("Added project P1")
    assert_equal "kernel", project_log.fetch("source_type")
    assert_equal "P1", project_log.fetch("source_id")
    assert_equal other_project, project_log.fetch("details").fetch("root_path")

    issue_log = log_with_message("Created issue P1-I1")
    assert_equal "kernel", issue_log.fetch("source_type")
    assert_equal "P1-I1", issue_log.fetch("source_id")
    assert_equal "P1", issue_log.fetch("details").fetch("project_id")
    assert_nil issue_log.fetch("details").fetch("parent_issue_id")

    provisioning_log = log_with_message("Provisioning workspace for worker P1-I1-W1")
    assert_equal "kernel", provisioning_log.fetch("source_type")
    assert_equal "P1-I1-W1", provisioning_log.fetch("source_id")

    worker_log = log_with_message("Spawned worker P1-I1-W1")
    assert_equal "kernel", worker_log.fetch("source_type")
    assert_equal "P1-I1-W1", worker_log.fetch("source_id")
    assert_equal "info", worker_log.fetch("level")
    details = worker_log.fetch("details")
    assert_equal "P1-I1", details.fetch("issue_id")
    assert_equal "P1", details.fetch("project_id")
    assert_equal "spawn_worker", details.fetch("routing_action")
    assert_equal "Logged goal", details.fetch("title")
    refute details.key?("follow_up_of_agent_id")
    refute details.key?("replaces_agent_id")

    # Every accepted command reports the log entries it produced, so callers do not
    # re-log the same routing decision.
    command_results(result).each { |command| refute_empty command.fetch("log_entry_ids") }
    assert_equal(
      logs.map { |entry| entry.fetch("id") } & command_results(result).flat_map { |command| command.fetch("log_entry_ids") },
      command_results(result).flat_map { |command| command.fetch("log_entry_ids") }
    )
  end

  def test_rejected_head_commands_log_the_reason_and_command_id
    head_id = spawn_head!("Propose an impossible command")
    result = apply_head_result(
      head_id,
      head_result(commands: [create_issue_command(project_id: "P404", title: "Nope")]),
      cleanup_head: false
    )

    entry = log_with_message("Rejected CreateIssue:")
    refute_nil entry
    assert_equal "kernel", entry.fetch("source_type")
    assert_nil entry.fetch("source_id")
    assert_equal "warning", entry.fetch("level")
    details = entry.fetch("details")
    assert_equal "H1-C1", details.fetch("command_id")
    assert_equal "CreateIssue", details.fetch("command_type")
    assert_equal "rejected", details.fetch("status")
    assert_includes details.fetch("errors"), "project_not_found"
    assert_equal [entry.fetch("id")], command_results(result).fetch(0).fetch("log_entry_ids")
  end

  def test_failed_head_commands_log_an_error_for_the_target_and_the_command
    failing_engine = build_engine(harness_client: KernelHeadsSupport::FailingSpawnHarnessClient.new)
    project_id = add_project!(target_engine: failing_engine)
    head_id = spawn_head!("Staff a worker that cannot spawn", target_engine: failing_engine)
    apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Unspawnable"),
          spawn_worker_command(issue_id: "#{project_id}-I1")
        ]
      ),
      target_engine: failing_engine
    )
    failing_state = failing_engine.list_all

    provisioning_error = log_with_message("Harness failed to spawn worker", current_state: failing_state)
    refute_nil provisioning_error
    assert_equal "kernel", provisioning_error.fetch("source_type")
    assert_equal "#{project_id}-I1-W1", provisioning_error.fetch("source_id")
    assert_equal "error", provisioning_error.fetch("level")
    assert_equal "#{project_id}-I1", provisioning_error.fetch("details").fetch("issue_id")

    command_error = log_with_message("Failed SpawnWorker:", current_state: failing_state)
    refute_nil command_error
    assert_nil command_error.fetch("source_id")
    assert_equal "error", command_error.fetch("level")
    assert_equal "H1-C2", command_error.fetch("details").fetch("command_id")
    assert_equal "failed", command_error.fetch("details").fetch("status")
  end

  def test_follow_up_spawn_logs_carry_routing_metadata
    project_id = add_project!
    first_head = spawn_head!("Start the first pass")
    apply_head_result(
      first_head,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Routed goal"),
          spawn_worker_command(issue_id: "#{project_id}-I1", title: "Routed goal")
        ]
      )
    )
    first_worker = agents(type: "worker").fetch(0).fetch("id")

    second_head = spawn_head!("Follow up on the same issue")
    apply_head_result(
      second_head,
      head_result(
        commands: [
          spawn_worker_command(
            issue_id: "#{project_id}-I1",
            title: "Routed goal follow-up",
            extra: { "follow_up_of_agent_id" => first_worker }
          )
        ]
      )
    )

    follow_up_worker = "#{project_id}-I1-W2"
    entry = log_with_message("Spawned follow-up worker #{follow_up_worker} after #{first_worker}")
    refute_nil entry
    assert_equal follow_up_worker, entry.fetch("source_id")
    assert_equal "spawn_follow_up_worker", entry.fetch("details").fetch("routing_action")
    assert_equal first_worker, entry.fetch("details").fetch("follow_up_of_agent_id")

    issue = issues.fetch(0)
    assert_equal "spawn_follow_up_worker", issue.fetch("last_routing_action")
    assert_equal follow_up_worker, issue.fetch("last_agent_id")
  end

  def test_replacement_spawn_logs_carry_routing_metadata
    project_id = add_project!
    first_head = spawn_head!("Start the first pass")
    apply_head_result(
      first_head,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Replaceable goal"),
          spawn_worker_command(issue_id: "#{project_id}-I1", title: "Replaceable goal")
        ]
      )
    )
    first_worker = agents(type: "worker").fetch(0).fetch("id")

    second_head = spawn_head!("Replace the stuck worker")
    apply_head_result(
      second_head,
      head_result(
        commands: [
          spawn_worker_command(
            issue_id: "#{project_id}-I1",
            title: "Replacement pass",
            extra: { "replace_agent_id" => first_worker }
          )
        ]
      )
    )

    replacement = "#{project_id}-I1-W2"
    entry = log_with_message("Replaced worker #{first_worker} with #{replacement}")
    refute_nil entry
    assert_equal replacement, entry.fetch("source_id")
    assert_equal "replace_worker", entry.fetch("details").fetch("routing_action")
    assert_equal first_worker, entry.fetch("details").fetch("replaces_agent_id")
    assert_equal "killed", find_agent_record(first_worker).fetch("status")
    assert_equal replacement, find_agent_record(first_worker).fetch("replaced_by_agent_id")
    assert_equal "replace_worker", issues.fetch(0).fetch("last_routing_action")
  end

  def test_prompt_agent_logs_the_routing_mode
    project_id = add_project!
    first_head = spawn_head!("Start the work")
    apply_head_result(
      first_head,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Promptable goal"),
          spawn_worker_command(issue_id: "#{project_id}-I1", title: "Promptable goal")
        ]
      )
    )
    worker_id = agents(type: "worker").fetch(0).fetch("id")

    second_head = spawn_head!("Also check the migration path")
    result = apply_head_result(
      second_head,
      head_result(
        commands: [
          {
            "type" => "PromptAgent",
            "payload" => { "agent_id" => worker_id, "prompt" => "Also check the migration path", "mode" => "follow_up" }
          }
        ]
      )
    )

    assert_equal([["PromptAgent", "accepted"]], command_statuses(result))
    entry = log_with_message("Queued a follow-up for worker #{worker_id}")
    refute_nil entry
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal worker_id, entry.fetch("source_id")
    details = entry.fetch("details")
    assert_equal "follow_up", details.fetch("mode")
    assert_equal "queue_follow_up", details.fetch("routing_action")
    assert_equal "#{project_id}-I1", details.fetch("issue_id")
    assert_equal "queue_follow_up", issues.fetch(0).fetch("last_routing_action")
  end

  def test_head_batch_summary_log_carries_every_command_result
    head_id = spawn_head!("Mix good and bad commands")
    project_id = add_project!
    apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Good goal"),
          create_issue_command(project_id: "P404", title: "Bad goal"),
          { "type" => "Frobnicate", "payload" => {} }
        ],
        questions: [{ "question" => "Anything else?", "context" => "audit" }]
      )
    )

    entry = log_with_message("Head result for #{head_id}:")
    refute_nil entry
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal head_id, entry.fetch("source_id")
    assert_equal "warning", entry.fetch("level")
    assert_equal "Head result for #{head_id}: 1 accepted, 2 rejected, 0 failed.", entry.fetch("message")
    details = entry.fetch("details")
    assert_equal ["Q1"], details.fetch("question_ids")
    assert_equal(
      [%w[CreateIssue accepted], %w[CreateIssue rejected], %w[Frobnicate rejected]],
      Array(details.fetch("command_results")).map { |result| [result.fetch("command_type"), result.fetch("status")] }
    )
  end

  def test_user_slash_command_style_rejections_are_logged_without_a_head
    result = apply_command("CreateIssue", { "project_id" => "P1", "title" => "No project yet" })

    assert_equal "rejected", result.fetch("status")
    entry = log_with_message("Rejected CreateIssue:")
    refute_nil entry
    assert_equal "kernel", entry.fetch("source_type")
    assert_nil entry.fetch("source_id")
    assert_nil entry.fetch("details").fetch("command_id")
    assert_equal [entry.fetch("id")], result.fetch("log_entry_ids")
  end
end
