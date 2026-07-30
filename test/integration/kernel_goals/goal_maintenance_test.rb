# frozen_string_literal: true

require "test_helper"
require "support/kernel_goals_support"

# Goals interact with the maintenance commands that already own the tree: Kill, Prune, Recount,
# and the worker-rollup that decides issue status. A long-lived goal is exactly the record those
# passes could quietly delete or contradict, so each interaction is pinned here.
class KernelGoalsMaintenanceTest < Minitest::Test
  include KernelGoalsSupport

  def setup
    goals_setup
  end

  def teardown
    goals_teardown
  end

  def test_an_active_goal_keeps_its_issue_out_of_completed_between_iterations
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    # Pause so the loop does not immediately start the next iteration: this isolates the
    # "every worker is completed but the goal is not" window.
    apply!("ModifyGoal", { "goal_id" => "G1", "paused" => true })
    harness_client.streaming = false
    tick!

    assert_equal "completed", workers.first.fetch("status")
    assert_equal "working", issue_record(fixture.fetch("issue_id")).fetch("status"),
                 "the worker rollup must not complete an issue whose goal is still live"

    # Once the goal is settled the ordinary rollup applies again.
    apply!("StopGoal", { "goal_id" => "G1" })
    apply!("PromptAgent", { "agent_id" => workers.first.fetch("id"), "prompt" => "wrap up" })
    tick!

    assert_equal "completed", issue_record(fixture.fetch("issue_id")).fetch("status")
  end

  def test_prune_retains_an_issue_that_still_owns_a_goal_loop
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    harness_client.streaming = false
    tick!
    # Force the state prune looks at: a terminal issue whose goal is still live.
    patched = store.load
    patched.fetch("issues").first["status"] = "completed"
    store.save(patched)

    result = apply!("Prune")
    decisions = result.fetch("result").fetch("issue_decisions")
    decision = decisions.find { |entry| entry.fetch("issue_id") == fixture.fetch("issue_id") }

    refute decision.fetch("prunable"), "an issue with a live goal must be retained"
    assert_includes decision.fetch("blockers"), "active_goals"
    assert_equal ["G1"], decision.fetch("active_goal_ids")
    refute_nil issue_record(fixture.fetch("issue_id")), "the issue survives the prune"
    refute_nil goal, "the goal survives the prune"
  end

  def test_prune_removes_the_goal_once_it_and_its_issue_are_settled
    fixture = project_with_issue
    probe.queue(61.0, 81.0)
    create_goal!(fixture.fetch("issue_id"))
    tick_until_settled!

    assert_equal "completed", goal.fetch("status")

    result = apply!("Prune")

    assert_includes result.fetch("result").fetch("removed_issue_ids"), fixture.fetch("issue_id")
    assert_includes result.fetch("result").fetch("removed_goal_ids"), "G1"
    assert_nil goal, "a pruned issue must not leave a dangling goal"
  end

  def test_killing_a_goal_stops_the_loop_and_kills_its_in_flight_attempt
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    worker_id = workers.first.fetch("id")

    result = apply!("Kill", { "target_id" => "G1" })

    assert_equal "G1", result.fetch("target_id")
    assert_equal "killed", goal.fetch("status")
    assert_equal "killed", goal.fetch("stop_reason")
    assert_includes harness_client.kills, "goal-session-1"
    assert_nil state.fetch("agents").find { |agent| agent.fetch("id") == worker_id }, "kill removes the attempt record"

    3.times { tick! }
    assert_empty workers, "a killed goal must not spawn again"
  end

  def test_killing_the_issue_settles_its_goal
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!

    apply!("Kill", { "target_id" => fixture.fetch("issue_id") })

    # The issue and its workers are removed by Kill; the goal must not be left ticking.
    assert_nil issue_record(fixture.fetch("issue_id"))
    assert_nil goal, "the goal is removed with the issue bundle"

    3.times { tick! }
    assert_empty workers
  end

  def test_killing_the_project_settles_its_goals
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!

    apply!("Kill", { "target_id" => fixture.fetch("project_id") })

    assert_nil goal
    3.times { tick! }
    assert_empty workers
  end

  def test_recount_renumbers_goals_and_keeps_their_references_valid
    first = project_with_issue(title: "First issue")
    second_issue = apply!(
      "CreateIssue",
      { "project_id" => first.fetch("project_id"), "title" => "Second issue", "description" => "" }
    ).fetch("target_id")
    probe.queue(61.0, 70.0)
    create_goal!(first.fetch("issue_id"))
    tick!
    finish_attempt_session!
    create_goal!(second_issue, success_criteria: "second goal")
    # Killing the first issue removes it and its goal, leaving a gap for recount to compact.
    apply!("Kill", { "target_id" => first.fetch("issue_id") })

    result = apply!("Recount")

    goal_ids = state.fetch("goals").map { |record| record.fetch("id") }
    assert_equal ["G1"], goal_ids, "the surviving goal is renumbered from G2 to G1"
    assert_equal({ "G2" => "G1" }, result.fetch("result").fetch("mappings").fetch("goal_ids"))
    surviving = state.fetch("goals").first
    assert_equal state.fetch("issues").first.fetch("id"), surviving.fetch("issue_id")
    assert_equal state.fetch("projects").first.fetch("id"), surviving.fetch("project_id")
    assert_equal 1, state.dig("counters", "goals")
  end

  def test_recount_remaps_worker_references_inside_iteration_history
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    finish_attempt_session!
    recorded_worker = settled_iterations.first.fetch("attempt_worker_id")

    apply!("Recount")

    worker_ids = workers.map { |worker| worker.fetch("id") }
    assert_includes worker_ids, settled_iterations.first.fetch("attempt_worker_id")
    assert_equal recorded_worker, settled_iterations.first.fetch("attempt_worker_id"), "ids were already compact here"
    assert_includes worker_ids, goal.fetch("last_worker_id")
  end

  def test_clear_state_removes_goals_and_resets_their_counter
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))

    apply!("ClearState")

    assert_empty state.fetch("goals")
    assert_equal 0, state.dig("counters", "goals").to_i
  end

  def test_goal_records_survive_a_reload_with_their_shape_normalized
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))
    # State written by an older Meringue version: no budgets, unknown judge mode, bad phase.
    patched = store.load
    patched.fetch("goals").first.merge!(
      "budget" => nil,
      "judge" => { "mode" => "worker_every_iteration" },
      "iterations" => [{ "number" => 1, "phase" => "nonsense" }],
      "continuity" => "teleport"
    )
    store.save(patched)

    reloaded = build_engine.list_all.fetch("goals").first

    assert_equal Meringue::Goals::Record::DEFAULT_MAX_ITERATIONS, reloaded.dig("budget", "max_iterations")
    assert_equal "metric_only", reloaded.dig("judge", "mode")
    assert_equal "accumulate", reloaded.fetch("continuity")
    assert_equal "attempting", reloaded.fetch("iterations").first.fetch("phase")
  end
end
