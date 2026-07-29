# frozen_string_literal: true

require "test_helper"
require "support/e2e_support"

# Flow 6: the same outcome a head produces from natural language is reachable with explicit
# slash commands, and /kill stops and removes the worker it targets.
class E2eSlashCommandParityTest < Minitest::Test
  include E2eSupport

  def setup
    setup_e2e
  end

  def teardown
    teardown_e2e
  end

  def test_slash_commands_drive_the_same_project_issue_worker_flow
    engine = build_engine
    prompt_loop = build_prompt_loop(engine)

    results = [
      prompt_loop.call(%(/project add "#{project_root}" demo-project)),
      prompt_loop.call(%(/issue create P1 "Ship the CLI" "Wire up the new subcommand")),
      prompt_loop.call(%(/worker spawn P1-I1 "Implement the subcommand")),
      prompt_loop.call(%(/prompt P1-I1-W1 "Also add usage output"))
    ]

    results.each do |result|
      assert_equal "slash_command_applied", result.fetch("event")
      assert_equal ["accepted"], result.fetch("command_results").map { |command_result| command_result.fetch("status") }
    end
    # No head agent was ever needed for the slash-command path.
    assert_empty head_runner.calls

    state = reloaded_state
    assert_equal ["P1"], state.fetch("projects").map { |project| project.fetch("id") }
    assert_equal "demo-project", state.fetch("projects").first.fetch("name")
    assert_equal File.realpath(project_root), File.realpath(state.fetch("projects").first.fetch("root_path"))
    assert_equal ["P1-I1"], state.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal "Ship the CLI", issue(state, "P1-I1").fetch("title")
    assert_equal "Wire up the new subcommand", issue(state, "P1-I1").fetch("description")

    worker = agent(state, "P1-I1-W1")
    assert_equal "working", worker.fetch("status")
    assert_equal "git_worktree", worker.fetch("workspace_strategy")
    assert_equal worker.fetch("workspace_branch"), current_branch(worker.fetch("workspace_path"))
    session_id = worker.fetch("harness_session_id")
    assert_equal(
      [{ "prompt" => "Also add usage output", "mode" => "normal" }],
      harness_client.prompts_for(session_id)
    )

    tree = agent_tree_text(state)
    assert_includes tree, "P1  demo-project"
    assert_includes tree, "I1  Ship the CLI"
    assert_includes tree, "W1"

    assert_logged(%r{User ran command: /worker spawn P1-I1}, state)
    assert_logged(/Added project P1: demo-project/, state)
    assert_logged(/Created issue P1-I1: Ship the CLI/, state)
    assert_logged(/Spawned worker P1-I1-W1 for P1-I1\./, state)
    assert_logged(/Continued worker P1-I1-W1 on P1-I1 using its existing session\./, state)

    # /kill stops the harness session and removes the worker from the AgentTree.
    kill_result = prompt_loop.call("/kill P1-I1-W1")
    assert_equal ["accepted"], kill_result.fetch("command_results").map { |command_result| command_result.fetch("status") }

    killed_state = reloaded_state
    assert_empty workers(killed_state)
    assert_equal ["P1-I1"], killed_state.fetch("issues").map { |issue| issue.fetch("id") }
    assert_empty issue(killed_state, "P1-I1").fetch("agent_ids")
    assert harness_client.session(session_id).fetch("killed"), "the harness session should be killed"
    assert_logged(/Killed P1-I1-W1\./, killed_state)
    refute_includes agent_tree_text(killed_state), "W1"

    persisted = raw_persisted_state
    assert_equal 1, persisted.fetch("projects").length
    assert_equal 1, persisted.fetch("issues").length
    assert_empty persisted.fetch("agents")
  end
end
