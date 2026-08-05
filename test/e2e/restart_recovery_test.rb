# frozen_string_literal: true

require "test_helper"
require "support/e2e_support"

# Flow 5: restarting Meringue over an existing state file. Reconciliation resumes the harness
# sessions it can re-attach, errors the ones it cannot, and pruning then removes the settled
# (resolved and errored) records while retaining everything still in flight.
class E2eRestartRecoveryTest < Minitest::Test
  include E2eSupport

  def setup
    setup_e2e
  end

  def teardown
    teardown_e2e
  end

  def test_restart_resumes_recoverable_sessions_errors_dead_ones_and_prunes_settled_work
    script_goal("Fix the parser", "P1-I1", include_project: true)
    script_goal("Write release notes", "P1-I2")
    script_goal("Upgrade dependencies", "P1-I3")

    first_engine = build_engine
    prompt_loop = build_prompt_loop(first_engine)
    prompt_loop.call("Fix the parser")
    prompt_loop.call("Write release notes")
    prompt_loop.call("Upgrade dependencies")

    before_restart = reloaded_state
    done_worker = agent(before_restart, "P1-I1-W1")
    resumable_worker = agent(before_restart, "P1-I2-W1")
    dead_worker = agent(before_restart, "P1-I3-W1")

    harness_client.finish!(done_worker.fetch("harness_session_id"), assistant_text: "Parser fixed.")
    first_engine.reconcile_sessions
    assert_equal "completed", agent(reloaded_state, "P1-I1-W1").fetch("status")

    # Restart: a brand new kernel, harness client, and head runner over the same state file.
    # The second worker's session can be re-attached; the third one is gone for good.
    restarted_client = E2eSupport::FakeHarnessClient.new
    restarted_client.register_resumable_session(resumable_worker.fetch("harness_session_id"))
    restarted_engine = build_engine(
      store: new_store,
      head_runner: E2eSupport::ScriptedHeadRunner.new,
      harness_client: restarted_client
    )

    # State survived the restart untouched.
    restored = restarted_engine.list_all
    assert_equal %w[P1-I1 P1-I2 P1-I3], restored.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal 3, workers(restored).length

    first_reconcile = restarted_engine.reconcile_sessions
    assert_equal "accepted", first_reconcile.fetch("status")

    after_first = reloaded_state
    assert_equal "working", agent(after_first, "P1-I2-W1").fetch("status")
    resumed_poll = first_reconcile.fetch("result").fetch("poll_results").find { |poll| poll.fetch("agent_id") == "P1-I2-W1" }
    assert resumed_poll.fetch("resumed"), "P1-I2-W1 should have been resumed from its persisted session"
    assert_equal "blocked", agent(after_first, "P1-I3-W1").fetch("status")
    assert_equal "completed", agent(after_first, "P1-I1-W1").fetch("status")
    assert_logged(/Resumed agent session for worker P1-I2-W1 and prompted it to continue\./, after_first)
    assert_logged(/Worker P1-I3-W1 could not resume its agent session; will retry reconciliation\./, after_first)
    assert_equal(
      [Meringue::Kernel::Engine::WORKER_RESUME_PROMPT],
      restarted_client.prompts_for(resumable_worker.fetch("harness_session_id")).map { |prompt| prompt.fetch("prompt") }
    )
    refute_includes restarted_client.session_ids, dead_worker.fetch("harness_session_id")

    # Reconciliation retries the unrecoverable session until it gives up on it.
    2.times { restarted_engine.reconcile_sessions }

    after_retries = reloaded_state
    assert_equal "errored", agent(after_retries, "P1-I3-W1").fetch("status")
    assert_equal "working", agent(after_retries, "P1-I2-W1").fetch("status")
    assert_logged(/Worker P1-I3-W1 errored while reconciling its agent session\./, after_retries)

    # `/prune` takes no options: one pass removes the completed bundle and the errored one, and
    # keeps the work that is still in flight.
    prune = restarted_engine.apply("type" => "Prune", "payload" => {})
    assert_equal "accepted", prune.fetch("status")
    assert_equal %w[P1-I1 P1-I3], prune.fetch("result").fetch("removed_issue_ids").sort
    removed_agent_ids = prune.fetch("result").fetch("removed_agent_ids")
    assert_includes removed_agent_ids, "P1-I1-W1"
    assert_includes removed_agent_ids, "P1-I3-W1"
    refute_includes removed_agent_ids, "P1-I2-W1", "the in-flight worker must survive the prune"
    assert_empty prune.fetch("result").fetch("removed_project_ids")

    pruned = reloaded_state
    assert_equal ["P1-I2"], pruned.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal ["P1-I2-W1"], workers(pruned).map { |worker| worker.fetch("id") }.sort
    assert_equal ["P1"], pruned.fetch("projects").map { |project| project.fetch("id") }
    # One line for the whole pass: two issues, their two workers plus the two heads that created
    # them, and the two managed worktrees that were actually removed from disk.
    assert_equal 4, removed_agent_ids.length
    assert_logged(/Pruned 2 issues, 4 agents, 2 worktrees, and 0 projects\./, pruned)
    refute_logged(/managed worktree for worker/, pruned)

    tree = agent_tree_text(pruned)
    refute_includes tree, "I1  Fix the parser"
    assert_includes tree, "I2  Write release notes"
    refute_includes tree, "I3  Upgrade dependencies"

    # Everything above is what a third process would read back from disk.
    persisted = raw_persisted_state
    assert_equal 1, persisted.fetch("issues").length
    assert_equal 1, persisted.fetch("agents").length
    assert_equal({ "P1" => 3 }, persisted.fetch("counters").fetch("issues_by_project"))
  end

  private

  def script_goal(title, issue_id, include_project: false)
    head_runner.script do
      commands = []
      commands << E2eSupport.add_project_command(project_root, "demo-project") if include_project
      commands << E2eSupport.create_issue_command(project_id: "P1", title: title, description: "#{title} description.")
      commands << E2eSupport.spawn_worker_command(issue_id: issue_id, title: title, prompt: "Work on #{title}.")
      {
        "title" => title,
        "summary" => "Routed #{title} to #{issue_id}.",
        "commands" => commands
      }
    end
  end
end
