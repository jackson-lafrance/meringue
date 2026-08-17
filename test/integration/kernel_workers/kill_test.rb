# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Kill: stopping harness sessions, removing records from active state, cascading
# through issue/project subtrees, and removing each killed worker's managed git worktree
# with the same safe cleanup path Prune uses (the delivery branch is always retained).
class KernelWorkersKillTest < Minitest::Test
  include KernelWorkersSupport

  def test_killing_a_worker_stops_its_session_and_removes_it_from_active_state
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    worker = agent(engine, worker_id)

    result = apply!(engine, "Kill", { "target_id" => worker_id })

    assert_equal worker_id, result.fetch("target_id")
    assert_equal "Killed #{worker_id}.", result.fetch("message")
    assert_equal [worker.fetch("harness_session_id")], @harness_client.killed_session_ids
    assert_nil agent(engine, worker_id), "a killed worker leaves active agent state"
    assert_empty issue(engine, context.fetch("issue_id")).fetch("agent_ids")
    assert_includes log_messages(engine), "Killed #{worker_id}."
    kill_log = state(engine).fetch("logs").find { |entry| entry.fetch("message") == "Killed #{worker_id}." }
    assert_equal [worker_id], kill_log.fetch("details").fetch("killed_agent_ids")
  end

  def test_killing_a_worker_removes_its_clean_managed_worktree_and_retains_the_branch
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    worker = agent(engine, worker_id)
    workspace_path = worker.fetch("workspace_path")
    branch = worker.fetch("workspace_branch")

    apply!(engine, "Kill", { "target_id" => worker_id })

    refute Dir.exist?(workspace_path), "kill removes a clean managed worktree"
    refute_empty run_git(context.fetch("root"), "branch", "--list", branch),
                 "the delivery branch must be retained, only the worktree directory is removed"
  end

  def test_killing_an_issue_cascades_to_its_workers_and_child_issues
    engine = build_engine
    context = project_with_issue(engine)
    parent_issue_id = context.fetch("issue_id")
    parent_worker_id = spawn_worker(engine, parent_issue_id).fetch("target_id")
    child_issue_id = apply!(
      engine,
      "CreateIssue",
      {
        "project_id" => context.fetch("project_id"),
        "title" => "Backfill the audit table",
        "parent_issue_id" => parent_issue_id
      }
    ).fetch("target_id")
    child_worker_id = spawn_worker(engine, child_issue_id).fetch("target_id")
    session_ids = [parent_worker_id, child_worker_id].map { |id| agent(engine, id).fetch("harness_session_id") }
    workspaces = [parent_worker_id, child_worker_id].map { |id| agent(engine, id).fetch("workspace_path") }
    branches = [parent_worker_id, child_worker_id].map { |id| agent(engine, id).fetch("workspace_branch") }

    result = apply!(engine, "Kill", { "target_id" => parent_issue_id })
    kill_log = state(engine).fetch("logs").find { |entry| entry.fetch("message") == "Killed #{parent_issue_id}." }

    assert_equal "accepted", result.fetch("status")
    assert_equal session_ids.sort, @harness_client.killed_session_ids.sort
    assert_nil issue(engine, parent_issue_id)
    assert_nil issue(engine, child_issue_id)
    assert_nil agent(engine, parent_worker_id)
    assert_nil agent(engine, child_worker_id)
    assert_equal [parent_issue_id, child_issue_id].sort, kill_log.fetch("details").fetch("removed_issue_ids").sort
    assert_equal [parent_worker_id, child_worker_id].sort, kill_log.fetch("details").fetch("killed_agent_ids").sort
    refute_nil project(engine, context.fetch("project_id")), "killing an issue keeps its project registered"
    workspaces.each { |path| refute Dir.exist?(path), "clean managed worktree #{path} is removed by an issue kill" }
    branches.each { |branch| refute_empty run_git(context.fetch("root"), "branch", "--list", branch), "issue kill retains the delivery branch" }
  end

  def test_killing_a_project_cascades_to_every_issue_and_worker
    engine = build_engine
    context = project_with_issue(engine)
    second_issue_id = create_issue(engine, context.fetch("project_id"), title: "Tune the query planner")
    worker_ids = [
      spawn_worker(engine, context.fetch("issue_id")).fetch("target_id"),
      spawn_worker(engine, second_issue_id).fetch("target_id")
    ]
    session_ids = worker_ids.map { |id| agent(engine, id).fetch("harness_session_id") }
    workspaces = worker_ids.map { |id| agent(engine, id).fetch("workspace_path") }
    branches = worker_ids.map { |id| agent(engine, id).fetch("workspace_branch") }

    apply!(engine, "Kill", { "target_id" => context.fetch("project_id") })

    assert_equal session_ids.sort, @harness_client.killed_session_ids.sort
    assert_empty state(engine).fetch("issues")
    assert_empty state(engine).fetch("agents")
    assert_nil project(engine, context.fetch("project_id"))
    workspaces.each { |path| refute Dir.exist?(path), "clean managed worktree #{path} is removed by a project kill" }
    branches.each { |branch| refute_empty run_git(context.fetch("root"), "branch", "--list", branch), "project kill retains the delivery branch" }
  end

  def test_killing_one_issue_leaves_sibling_work_untouched
    engine = build_engine
    context = project_with_issue(engine)
    sibling_issue_id = create_issue(engine, context.fetch("project_id"), title: "Rotate the API tokens")
    doomed_worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    sibling_worker_id = spawn_worker(engine, sibling_issue_id).fetch("target_id")
    doomed_session_id = agent(engine, doomed_worker_id).fetch("harness_session_id")

    apply!(engine, "Kill", { "target_id" => context.fetch("issue_id") })

    assert_equal [doomed_session_id], @harness_client.killed_session_ids
    assert_nil agent(engine, doomed_worker_id)
    refute_nil agent(engine, sibling_worker_id)
    assert_equal "working", agent(engine, sibling_worker_id).fetch("status")
    assert_equal [sibling_worker_id], issue(engine, sibling_issue_id).fetch("agent_ids")
  end

  def test_kill_requires_a_known_target
    engine = build_engine
    project_with_issue(engine)

    missing = apply_raw(engine, "Kill", { "target_id" => "P4-I2-W3" })
    blank = apply_raw(engine, "Kill", {})

    assert_equal "rejected", missing.fetch("status")
    assert_includes missing.fetch("errors"), "target_not_found"
    assert_equal "rejected", blank.fetch("status")
    assert_includes blank.fetch("errors"), "target_id is required"
    assert_empty @harness_client.kills
  end

  def test_cancelling_a_turn_preserves_the_session_and_the_worker_record
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    session_id = agent(engine, worker_id).fetch("harness_session_id")

    result = engine.cancel_agent_turn(worker_id)
    worker = agent(engine, worker_id)

    assert_equal "accepted", result.fetch("status")
    assert_equal [session_id], @harness_client.aborts.map { |call| call.fetch("session_id") }
    assert_empty @harness_client.kills
    refute_nil worker, "cancelling a turn must not remove the worker"
    assert_equal "idle", worker.fetch("status")
    assert_equal true, worker.fetch("harness_metadata").key?("turn_cancelled_at")
    assert_equal session_id, worker.fetch("harness_session_id")
  end
end
