# frozen_string_literal: true

require "test_helper"
require "support/e2e_support"

# Flow 3: two goals run at the same time. Chat input is never blocked by a busy worker, each
# worker gets its own git worktree, and completing one worker leaves the other untouched.
class E2eParallelWorkTest < Minitest::Test
  include E2eSupport

  def setup
    setup_e2e
  end

  def teardown
    teardown_e2e
  end

  def test_two_issues_run_concurrently_in_isolated_worktrees
    head_runner.script do
      {
        "title" => "Fix the parser",
        "summary" => "Registered the project and started the parser fix.",
        "commands" => [
          E2eSupport.add_project_command(project_root, "demo-project"),
          E2eSupport.create_issue_command(project_id: "P1", title: "Fix the parser", description: "Parser drops trailing commas."),
          E2eSupport.spawn_worker_command(issue_id: "P1-I1", title: "Fix parser", prompt: "Fix the trailing comma bug.")
        ]
      }
    end
    head_runner.script do |call|
      # Second message arrives while the first worker is still streaming.
      active = call.fetch("snapshot").fetch("agents").select { |agent| agent.fetch("type") == "worker" }
      assert_equal ["working"], active.map { |agent| agent.fetch("status") }

      {
        "title" => "Write release notes",
        "summary" => "Opened a second, independent issue and started it in parallel.",
        "commands" => [
          E2eSupport.create_issue_command(project_id: "P1", title: "Write release notes", description: "Draft 1.0 notes."),
          E2eSupport.spawn_worker_command(issue_id: "P1-I2", title: "Draft release notes", prompt: "Draft the 1.0 release notes.")
        ]
      }
    end

    engine = build_engine
    prompt_loop = build_prompt_loop(engine)

    prompt_loop.call("Fix the trailing comma bug in the parser")
    # Chat is not blocked: the second message is accepted while the first worker is working.
    second = prompt_loop.call("Also draft the 1.0 release notes")
    assert_equal "accepted", second.fetch("apply_head_result").fetch("status")

    state = reloaded_state
    assert_equal %w[P1-I1 P1-I2], state.fetch("issues").map { |issue| issue.fetch("id") }.sort
    parser_worker = agent(state, "P1-I1-W1")
    notes_worker = agent(state, "P1-I2-W1")
    assert_equal "working", parser_worker.fetch("status")
    assert_equal "working", notes_worker.fetch("status")

    # Isolated workspaces: distinct paths and distinct branches, both real worktrees.
    refute_equal parser_worker.fetch("workspace_path"), notes_worker.fetch("workspace_path")
    refute_equal parser_worker.fetch("workspace_branch"), notes_worker.fetch("workspace_branch")
    [parser_worker, notes_worker].each do |worker|
      assert Dir.exist?(worker.fetch("workspace_path")), "#{worker.fetch("id")} workspace should exist"
      assert_equal worker.fetch("workspace_branch"), current_branch(worker.fetch("workspace_path"))
    end
    assert_equal 2, harness_client.worker_session_cwds.uniq.length

    tree = agent_tree_text(state)
    assert_includes tree, "I1  Fix the parser"
    assert_includes tree, "I2  Write release notes"

    # Completing one worker does not disturb the other issue's state.
    harness_client.finish!(parser_worker.fetch("harness_session_id"), assistant_text: "Parser fixed.")
    engine.reconcile_sessions

    final = reloaded_state
    assert_equal "completed", agent(final, "P1-I1-W1").fetch("status")
    assert_equal "completed", issue(final, "P1-I1").fetch("status")
    assert_equal "working", agent(final, "P1-I2-W1").fetch("status")
    assert_equal "working", issue(final, "P1-I2").fetch("status")
    assert_equal "working", final.fetch("projects").first.fetch("status")

    assert_logged(/Worker P1-I1-W1 completed\./, final)
    refute_logged(/Worker P1-I2-W1 completed\./, final)

    persisted = raw_persisted_state
    assert_equal({ "P1" => 2 }, persisted.fetch("counters").fetch("issues_by_project"))
    assert_equal({ "P1-I1" => 1, "P1-I2" => 1 }, persisted.fetch("counters").fetch("workers_by_issue"))
    assert_equal 2, persisted.fetch("agents").length
  end
end
