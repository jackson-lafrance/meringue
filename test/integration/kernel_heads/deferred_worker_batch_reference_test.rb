# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# A head cannot predict the worker id its own batch will mint, so "start B after A" inside one
# HeadResult points at the SpawnWorker command instead: `after_from_command`, or
# `after_agent_id: "@<command_id>"`. Same ordering and failure rules as `issue_from_command`.
class KernelHeadsDeferredWorkerBatchReferenceTest < KernelHeadsTestCase
  def test_after_from_command_queues_the_second_worker_behind_the_first
    project_id = add_project!
    head_id = spawn_head!("Research the crash, then fix it")

    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Fix the crash", command_id: "issue"),
          spawn_worker_command(issue_id: nil, title: "Research the crash", command_id: "research", extra: { "issue_from_command" => "issue" }),
          spawn_worker_command(
            issue_id: nil,
            title: "Fix the crash",
            extra: { "issue_from_command" => "issue", "after_from_command" => "research" }
          )
        ]
      ),
      cleanup_head: false
    )
    results = command_results(result)
    research_id = results[1].fetch("target_id")
    dependent = find_agent_record(results[2].fetch("target_id"))

    assert_equal %w[accepted accepted accepted], results.map { |entry| entry.fetch("status") }
    assert_equal "queued", dependent.fetch("status")
    assert_equal research_id, dependent.fetch("after_agent_id")
    assert_equal "waiting", dependent.fetch("harness_metadata").fetch("deferred_spawn").fetch("state")
    assert_equal "working", find_agent_record(research_id).fetch("status")
    assert_includes log_messages, "Queued worker #{dependent.fetch("id")} on #{dependent.fetch("issue_id")} to start after #{research_id} settles."
  end

  def test_at_prefixed_after_agent_id_resolves_the_same_way
    project_id = add_project!
    head_id = spawn_head!("Investigate then implement")

    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Investigate then implement", command_id: "issue"),
          spawn_worker_command(issue_id: nil, title: "Investigate", command_id: "look", extra: { "issue_from_command" => "issue" }),
          spawn_worker_command(
            issue_id: nil,
            title: "Implement",
            extra: { "issue_from_command" => "issue", "after_agent_id" => "@look" }
          )
        ]
      ),
      cleanup_head: false
    )
    results = command_results(result)
    dependent = find_agent_record(results[2].fetch("target_id"))

    assert_equal %w[accepted accepted accepted], results.map { |entry| entry.fetch("status") }
    assert_equal results[1].fetch("target_id"), dependent.fetch("after_agent_id")
    assert_equal "queued", dependent.fetch("status")
  end

  def test_a_reference_to_a_later_command_is_rejected
    project_id = add_project!
    head_id = spawn_head!("Do it backwards")

    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Do it backwards", command_id: "issue"),
          spawn_worker_command(
            issue_id: nil,
            title: "Second step",
            extra: { "issue_from_command" => "issue", "after_from_command" => "first" }
          ),
          spawn_worker_command(issue_id: nil, title: "First step", command_id: "first", extra: { "issue_from_command" => "issue" })
        ]
      ),
      cleanup_head: false
    )
    dependent_result = command_results(result)[1]

    assert_equal "rejected", dependent_result.fetch("status")
    assert_includes dependent_result.fetch("errors"), "after_agent_reference_out_of_order"
  end

  def test_a_reference_to_a_command_that_is_not_in_the_batch_is_rejected
    project_id = add_project!
    head_id = spawn_head!("Reference nothing")

    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Reference nothing", command_id: "issue"),
          spawn_worker_command(
            issue_id: nil,
            title: "Only step",
            extra: { "issue_from_command" => "issue", "after_from_command" => "ghost" }
          )
        ]
      ),
      cleanup_head: false
    )
    dependent_result = command_results(result)[1]

    assert_equal "rejected", dependent_result.fetch("status")
    assert_includes dependent_result.fetch("errors"), "after_agent_reference_not_found"
  end

  # after_agent_id states an explicit lineage, exactly like follow_up_of_agent_id, so the
  # batch-consistency rule must not reroute that worker onto the issue this batch created.
  def test_an_existing_issue_worker_marked_with_after_agent_id_is_not_rerouted
    project_id = add_project!
    seed_head_id = spawn_head!("Seed the current goal")
    seed = apply_head_result(
      seed_head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Current goal", command_id: "current"),
          spawn_worker_command(issue_id: nil, title: "Current worker", extra: { "issue_from_command" => "current" })
        ]
      ),
      cleanup_head: false
    )
    existing_issue_id = command_results(seed)[0].fetch("target_id")
    existing_worker_id = command_results(seed)[1].fetch("target_id")

    head_id = spawn_head!("Queue the follow-up and open a backlog issue")
    result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Backlog goal", command_id: "backlog"),
          spawn_worker_command(issue_id: nil, title: "Backlog worker", extra: { "issue_from_command" => "backlog" }),
          spawn_worker_command(
            issue_id: existing_issue_id,
            title: "Follow-up on the current goal",
            extra: { "after_agent_id" => existing_worker_id }
          )
        ]
      ),
      cleanup_head: false
    )
    results = command_results(result)
    dependent = find_agent_record(results[2].fetch("target_id"))

    assert_equal %w[accepted accepted accepted], results.map { |entry| entry.fetch("status") }
    assert_equal existing_issue_id, dependent.fetch("issue_id")
    assert_equal existing_worker_id, dependent.fetch("after_agent_id")
    assert_equal "queued", dependent.fetch("status")
  end
end
