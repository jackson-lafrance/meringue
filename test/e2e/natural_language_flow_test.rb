# frozen_string_literal: true

require "test_helper"
require "support/e2e_support"

# Flow 1: a plain chat message becomes a registered project, an issue, and a worker running
# in its own git worktree, and the worker's completion is reflected in state and the logs.
class E2eNaturalLanguageFlowTest < Minitest::Test
  include E2eSupport

  def setup
    setup_e2e
  end

  def teardown
    teardown_e2e
  end

  def test_new_goal_creates_project_issue_and_worker_that_completes
    head_runner.script do |call|
      # The head sees the real user message and a Heads::Context built from live state.
      assert_equal "Add a changelog to the demo project", call.fetch("user_message")
      assert_equal 0, call.fetch("context").to_prompt_h.fetch("current_state_summary").fetch("project_count")

      {
        "title" => "Add a changelog",
        "summary" => "Registered the demo project, opened one issue, and spawned a worker.",
        "commands" => [
          E2eSupport.add_project_command(project_root, "demo-project"),
          E2eSupport.create_issue_command(project_id: "P1", title: "Add a changelog", description: "Document releases."),
          E2eSupport.spawn_worker_command(issue_id: "P1-I1", title: "Write CHANGELOG.md", prompt: "Add a CHANGELOG.md file.")
        ]
      }
    end

    engine = build_engine
    loop_result = build_prompt_loop(engine).call("Add a changelog to the demo project")

    assert_equal "head_loop_iteration", loop_result.fetch("event")
    assert_equal "accepted", loop_result.fetch("apply_head_result").fetch("status")

    working_state = reloaded_state
    assert_equal "working", agent(working_state, "P1-I1-W1").fetch("status")

    # The worker settles in its harness session and reconciliation records the completion,
    # exactly as the running TUI's background reconciler does.
    worker_session_id = agent(working_state, "P1-I1-W1").fetch("harness_session_id")
    harness_client.finish!(worker_session_id, assistant_text: "Added CHANGELOG.md with an initial entry.")
    reconcile = engine.reconcile_sessions
    assert_equal "accepted", reconcile.fetch("status")

    state = reloaded_state
    assert_equal ["P1"], state.fetch("projects").map { |project| project.fetch("id") }
    assert_equal ["P1-I1"], state.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal ["P1-I1-W1"], workers(state).map { |worker| worker.fetch("id") }

    worker = agent(state, "P1-I1-W1")
    assert_equal "completed", worker.fetch("status")
    assert_equal "Added CHANGELOG.md with an initial entry.", worker.fetch("harness_metadata").fetch("last_assistant_text")
    assert_equal "completed", issue(state, "P1-I1").fetch("status")
    assert_equal ["P1-I1-W1"], issue(state, "P1-I1").fetch("agent_ids")
    # Heads are transient: the applied head is cleaned out of the AgentTree.
    assert_empty state.fetch("agents").select { |candidate| candidate.fetch("type") == "head" }

    # The worker really ran in its own git worktree, not in the project checkout.
    workspace_path = worker.fetch("workspace_path")
    refute_equal File.realpath(project_root), File.realpath(workspace_path)
    assert workspace_path.start_with?(workspaces_root), "worker workspace #{workspace_path} should live under the test workspace root"
    assert_equal worker.fetch("workspace_branch"), current_branch(workspace_path)
    assert_equal "git_worktree", worker.fetch("workspace_strategy")
    assert_equal [workspace_path], harness_client.worker_session_cwds

    # User-visible AgentTree output.
    tree = agent_tree_text(state)
    assert_includes tree, "P1  demo-project"
    assert_includes tree, "I1  Add a changelog"
    assert_includes tree, "W1  Write CHANGELOG.md"
    assert_includes tree, "1/1"

    assert_logged(/Add a changelog to the demo project/, state)
    assert_logged(/Added project P1: demo-project/, state)
    assert_logged(/Created issue P1-I1: Add a changelog/, state)
    assert_logged(/Spawned worker P1-I1-W1 for P1-I1\./, state)
    assert_logged(/Worker P1-I1-W1 completed\./, state)

    # The persisted JSON on disk carries the same picture as the in-memory reload.
    persisted = raw_persisted_state
    assert_equal 1, persisted.fetch("counters").fetch("projects")
    assert_equal({ "P1" => 1 }, persisted.fetch("counters").fetch("issues_by_project"))
    assert_equal({ "P1-I1" => 1 }, persisted.fetch("counters").fetch("workers_by_issue"))
    assert_equal "completed", persisted.fetch("agents").first.fetch("status")
    assert_equal state.fetch("issues"), persisted.fetch("issues")
  end
end
