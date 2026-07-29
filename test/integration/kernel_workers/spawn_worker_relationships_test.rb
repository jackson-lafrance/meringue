# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# follow_up_of_agent_id / replace_agent_id: relationship fields on both records,
# successor-before-kill ordering, and rejection of cross-issue or stale references.
class KernelWorkersRelationshipsTest < Minitest::Test
  include KernelWorkersSupport

  def test_follow_up_links_both_worker_records_and_keeps_the_predecessor_alive
    engine = build_engine
    context = project_with_issue(engine)
    first = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    result = spawn_worker(engine, context.fetch("issue_id"), prompt: "Now add tests.", follow_up_of_agent_id: first)
    successor_id = result.fetch("target_id")
    predecessor = agent(engine, first)
    successor = agent(engine, successor_id)

    assert_equal first, successor.fetch("follow_up_of_agent_id")
    assert_nil successor.fetch("replaces_agent_id")
    assert_equal [successor_id], predecessor.fetch("follow_up_agent_ids")
    assert_equal "working", predecessor.fetch("status")
    assert_equal "spawn_follow_up_worker", successor.fetch("harness_metadata").fetch("routing_action")
    assert_equal "spawn_follow_up_worker", issue(engine, context.fetch("issue_id")).fetch("last_routing_action")
    assert_includes log_messages(engine), "Spawned follow-up worker #{successor_id} after #{first} on P1-I1."
    assert_empty @harness_client.kills
  end

  def test_replacement_links_both_records_and_kills_the_replaced_worker
    engine = build_engine
    context = project_with_issue(engine)
    original_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    original_session_id = agent(engine, original_id).fetch("harness_session_id")

    result = spawn_worker(engine, context.fetch("issue_id"), prompt: "Start over.", replace_agent_id: original_id)
    replacement_id = result.fetch("target_id")
    original = agent(engine, original_id)
    replacement = agent(engine, replacement_id)

    assert_equal original_id, replacement.fetch("replaces_agent_id")
    assert_nil replacement.fetch("follow_up_of_agent_id")
    assert_equal replacement_id, original.fetch("replaced_by_agent_id")
    assert_equal "killed", original.fetch("status")
    assert_equal "working", replacement.fetch("status")
    assert_equal "replace_worker", replacement.fetch("harness_metadata").fetch("routing_action")
    assert_includes @harness_client.killed_session_ids, original_session_id
    assert_includes log_messages(engine), "Replaced worker #{original_id} with #{replacement_id} on P1-I1."
  end

  def test_replacement_successor_is_spawned_before_the_replaced_session_is_killed
    engine = build_engine
    context = project_with_issue(engine)
    original_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    spawn_worker(engine, context.fetch("issue_id"), prompt: "Start over.", replace_agent_id: original_id)

    successor_spawn_index = @harness_client.call_index("spawn_session", index: 1)
    kill_index = @harness_client.call_index("kill_session")

    refute_nil successor_spawn_index, "expected a second spawn_session call for the replacement worker"
    refute_nil kill_index, "expected the replaced worker's session to be killed"
    assert_operator successor_spawn_index, :<, kill_index
  end

  def test_replacement_keeps_the_replaced_workspace_on_disk
    engine = build_engine
    context = project_with_issue(engine)
    original_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    original_workspace = agent(engine, original_id).fetch("workspace_path")

    spawn_worker(engine, context.fetch("issue_id"), prompt: "Start over.", replace_agent_id: original_id)

    assert Dir.exist?(original_workspace), "the replaced worker's workspace must not be deleted"
  end

  def test_follow_up_and_replace_are_mutually_exclusive
    engine = build_engine
    context = project_with_issue(engine)
    original_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")

    result = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Go.",
        "follow_up_of_agent_id" => original_id,
        "replace_agent_id" => original_id
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "follow_up_of_agent_id and replace_agent_id are mutually exclusive"
    assert_equal 1, @harness_client.spawns.length
  end

  def test_related_worker_from_another_issue_is_rejected
    engine = build_engine
    context = project_with_issue(engine)
    other_issue_id = create_issue(engine, context.fetch("project_id"), title: "Ship the CSV export")
    other_worker_id = spawn_worker(engine, other_issue_id).fetch("target_id")

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "follow_up_of_agent_id" => other_worker_id }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "related_agent_issue_mismatch"
    assert_equal 1, @harness_client.spawns.length
    assert_empty issue(engine, context.fetch("issue_id")).fetch("agent_ids")
  end

  def test_unknown_related_worker_is_rejected
    engine = build_engine
    context = project_with_issue(engine)

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "replace_agent_id" => "P1-I1-W9" }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "related_agent_not_found"
    assert_empty @harness_client.spawns
  end

  def test_replacing_an_already_replaced_worker_is_rejected
    engine = build_engine
    context = project_with_issue(engine)
    original_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    spawn_worker(engine, context.fetch("issue_id"), prompt: "Start over.", replace_agent_id: original_id)

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Again.", "replace_agent_id" => original_id }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_not_replaceable"
    assert_equal 2, @harness_client.spawns.length
  end
end
