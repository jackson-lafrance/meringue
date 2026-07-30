# frozen_string_literal: true

require "test_helper"
require "support/kernel_goals_support"

# Goal loops and deferred ("start B after A settles") workers are independent features that share
# the reconcile tick, the prune blockers, and the kill cascade. These tests pin the interactions
# so neither feature silently weakens the other.
class KernelGoalsDeferredWorkerTest < Minitest::Test
  include KernelGoalsSupport

  def setup
    goals_setup
  end

  def teardown
    goals_teardown
  end

  def deferred_state(agent_id)
    state.fetch("agents").find { |agent| agent.fetch("id") == agent_id }&.dig("harness_metadata", "deferred_spawn", "state")
  end

  def test_one_pass_activates_a_queued_dependent_before_it_advances_goal_loops
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    attempt = workers.first.fetch("id")
    # A worker queued behind the goal's attempt, spawned the ordinary way by a head or the user.
    queued = apply!(
      "SpawnWorker",
      { "issue_id" => fixture.fetch("issue_id"), "prompt" => "Review the attempt.", "after_agent_id" => attempt }
    ).fetch("target_id")

    assert_equal "waiting", deferred_state(queued)

    harness_client.streaming = false
    result = tick!
    pass = result.fetch("result")

    # Upstream activates a dependent from the worker-completion hook, which runs while the polls are
    # applied; the reconcile-level step is its recovery path. Either way the activation happens
    # before goal loops advance in the same pass, so the goal never observes a stale waiting record.
    activation_results = pass.fetch("deferred_worker_results") +
                         pass.fetch("poll_results").flat_map { |poll| Array(poll.dig("completion_result", "deferred_worker_results")) }
    assert activation_results.any? { |entry| entry.fetch("target_id", nil) == queued },
           "the queued dependent should be activated by one of the two hooks in this pass"
    assert_equal "activated", deferred_state(queued)
    refute_empty pass.fetch("goal_loop_steps"), "the goal loop also advanced in this pass"
  end

  def test_a_queued_dependent_does_not_disturb_the_goals_own_single_flight_accounting
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    attempt = workers.first.fetch("id")
    apply!(
      "SpawnWorker",
      { "issue_id" => fixture.fetch("issue_id"), "prompt" => "Review the attempt.", "after_agent_id" => attempt }
    )

    3.times { tick! }

    # The goal only counts the sessions it started itself.
    assert_equal 1, goal.fetch("workers_spawned")
    assert_equal 1, goal.fetch("current_iteration")
    assert_equal attempt, iterations.first.fetch("attempt_worker_id")
  end

  def test_killing_a_goal_also_cancels_the_worker_queued_behind_its_attempt
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    attempt = workers.first.fetch("id")
    queued = apply!(
      "SpawnWorker",
      { "issue_id" => fixture.fetch("issue_id"), "prompt" => "Review the attempt.", "after_agent_id" => attempt }
    ).fetch("target_id")

    result = apply!("Kill", { "target_id" => "G1" })

    assert_equal "killed", goal.fetch("status")
    # Kill cascades through the goal to its attempt, and upstream's dependent cancellation then
    # cascades to anything queued behind that attempt: nothing is left waiting on a dead record.
    assert_equal "G1", result.fetch("target_id")
    assert_nil state.fetch("agents").find { |agent| agent.fetch("id") == attempt }
    cancelled = state.fetch("agents").find { |agent| agent.fetch("id") == queued }
    assert cancelled.nil? || cancelled.fetch("status") == "killed",
           "the queued dependent must not be left waiting on a killed attempt"

    3.times { tick! }
    assert_empty workers.reject { |worker| worker.fetch("status") == "killed" }
  end

  def test_prune_reports_both_a_live_goal_and_a_queued_dependent_as_blockers
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    attempt = workers.first.fetch("id")
    apply!(
      "SpawnWorker",
      { "issue_id" => fixture.fetch("issue_id"), "prompt" => "Review the attempt.", "after_agent_id" => attempt }
    )
    patched = store.load
    patched.fetch("issues").first["status"] = "completed"
    store.save(patched)

    decision = apply!("Prune").fetch("result").fetch("issue_decisions")
                             .find { |entry| entry.fetch("issue_id") == fixture.fetch("issue_id") }

    refute decision.fetch("prunable")
    assert_includes decision.fetch("blockers"), "active_goals"
    assert_includes decision.fetch("blockers"), "pending_deferred_dependents"
    assert_equal ["G1"], decision.fetch("active_goal_ids")
    refute_empty decision.fetch("deferred_dependent_worker_ids")
    refute_nil goal
  end

  def test_the_goal_loop_never_queues_its_own_attempts_behind_another_agent
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"), continuity: "fresh_attempt")
    tick!
    finish_attempt_session!

    # Goal attempts start immediately and are ordered by the loop's own single-flight rule, not by
    # the deferred-spawn queue, so no attempt carries deferred metadata.
    workers.each do |worker|
      assert_nil worker.dig("harness_metadata", "deferred_spawn"), "#{worker.fetch("id")} should not be a deferred worker"
      assert_nil worker.fetch("after_agent_id", nil)
    end
    assert_equal 2, workers.length
    assert_equal workers.first.fetch("id"), workers.last.fetch("follow_up_of_agent_id")
  end
end
