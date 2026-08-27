# frozen_string_literal: true

require "test_helper"
require "support/kernel_goals_support"

# The goal loop driven by the real reconcile tick: baseline, attempt, measure, judge, next
# attempt, and completion. The harness is a fake client and the metric is a scripted probe, so
# the whole loop runs hermetically.
class KernelGoalsLoopTest < Minitest::Test
  include KernelGoalsSupport

  # Models a metric command that takes longer than one reconcile pass should spend on goals.
  class SlowFirstMeasurementProbe < KernelGoalsSupport::ScriptedMetricProbe
    def initialize(delay:, **options)
      super(**options)
      @delay = delay
    end

    def measure(**options)
      sleep(@delay) if calls.empty?
      super
    end
  end

  def setup
    goals_setup
  end

  def teardown
    goals_teardown
  end

  def test_the_first_tick_measures_the_baseline_and_starts_one_attempt
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"))

    assert_equal "queued", goal.fetch("status")
    assert_empty workers

    tick!

    assert_equal "working", goal.fetch("status")
    assert_equal 61.0, goal.dig("baseline_metric", "value")
    assert_equal 1, workers.length, "one tick must start exactly one attempt"
    assert_equal 1, goal.fetch("current_iteration")
    assert_equal "attempting", iterations.first.fetch("phase")
    assert_equal workers.first.fetch("id"), iterations.first.fetch("attempt_worker_id")
    assert_equal "G1-IT1-ATTEMPT", iterations.first.fetch("attempt_command_id")
    assert_match(/baseline metric is 61/, logs_matching(/baseline/).first.to_s)
  end

  def test_the_attempt_prompt_carries_the_metric_the_target_and_the_measurement_rules
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"])

    tick!

    prompt = harness_client.spawns.first.fetch("prompt")
    assert_includes prompt, "G1"
    assert_includes prompt, "rake coverage"
    assert_includes prompt, "at least 80"
    assert_includes prompt, "rake test"
    assert_includes prompt, "Iteration 1 of 3"
    assert_includes prompt, "do not self-report it"
    assert_equal "G1 iteration 1", harness_client.spawns.first.fetch("session_name")
  end

  def test_repeated_ticks_never_spawn_a_second_attempt_while_one_is_in_flight
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"))

    5.times { tick! }

    assert_equal 1, workers.length, "the single-flight invariant must hold across ticks"
    assert_equal 1, harness_client.spawns.length
    assert_equal 1, goal.fetch("workers_spawned")
  end

  def test_a_settled_attempt_is_measured_judged_and_followed_by_the_next_iteration
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"], continuity: "fresh_attempt")

    tick!
    finish_attempt_session!

    first = settled_iterations.first
    assert_equal 1, first.fetch("number")
    assert_equal "partially_met", first.fetch("verdict")
    assert_equal 70.0, first.dig("metric", "value")
    assert_in_delta 9.0, first.fetch("metric_delta"), 0.001
    assert_equal [true], first.fetch("guardrails").map { |guardrail| guardrail.fetch("passed") }
    assert_equal "metric_only", first.fetch("judged_by")
    assert_includes first.fetch("next_directive"), "Keep pushing"
    assert_equal 0, goal.fetch("consecutive_no_progress")
    assert_equal 70.0, goal.dig("last_metric", "value")
    assert_equal 70.0, goal.dig("best_metric", "value")

    assert_equal 2, workers.length, "a settled, unmet iteration starts the next attempt"
    assert_equal 2, goal.fetch("current_iteration")
    assert_includes harness_client.spawns.last.fetch("prompt"), "it1: metric 70"
    assert_includes harness_client.spawns.last.fetch("prompt"), "Keep pushing"
  end

  def test_the_loop_completes_the_goal_and_the_issue_when_the_metric_reaches_its_target
    fixture = project_with_issue
    probe.queue(61.0, 72.0, 81.0)
    create_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"])

    tick_until_settled!

    assert_equal "completed", goal.fetch("status")
    assert_equal "goal_met", goal.fetch("stop_reason")
    assert_equal "met", settled_iterations.last.fetch("verdict")
    assert_equal 2, settled_iterations.length
    assert_equal "completed", issue_record(fixture.fetch("issue_id")).fetch("status")
    assert_nil goal.fetch("active_worker_id")
    assert_match(/met its success criteria/, logs_matching(/met its success criteria/).first.to_s)
    assert_equal 1.0, settled_iterations.last.fetch("score")
  end

  def test_a_completed_goal_stops_spawning_even_if_the_tick_keeps_running
    fixture = project_with_issue
    probe.queue(61.0, 81.0)
    create_goal!(fixture.fetch("issue_id"))
    tick_until_settled!
    spawned = workers.length

    3.times { tick! }

    assert_equal spawned, workers.length
    assert_equal "completed", goal.fetch("status")
  end

  # Every iteration is a new session; `accumulate` is about the checkout, not the session. The
  # second attempt must land in the first one's worktree and branch so progress and the metric
  # stay cumulative, and it must never re-prompt the settled attempt.
  def test_accumulate_continuity_spawns_a_new_worker_in_the_previous_worktree
    fixture = project_with_issue
    probe.queue(61.0, 65.0, 68.0)
    create_goal!(fixture.fetch("issue_id"), continuity: "accumulate", max_iterations: 3)

    tick!
    first_worker = workers.first
    finish_attempt_session!

    assert_equal 2, workers.length, "accumulate still starts a new session per iteration"
    second_worker = workers.last
    assert_equal first_worker.fetch("id"), second_worker.fetch("follow_up_of_agent_id")
    assert_equal first_worker.fetch("workspace_path"), second_worker.fetch("workspace_path"),
                 "accumulate must continue in the previous attempt's worktree"
    assert_equal first_worker.fetch("workspace_branch"), second_worker.fetch("workspace_branch")
    assert_equal 2, harness_client.spawns.length
    assert_empty harness_client.prompts, "an iteration never re-prompts the settled attempt"
    assert_includes harness_client.spawns.last.fetch("prompt"), "Stay in this workspace and branch"
    assert_equal 2, goal.fetch("workers_spawned"), "each iteration spends one session of the budget"
  end

  def test_fresh_attempt_continuity_starts_each_iteration_from_a_clean_tree
    fixture = project_with_issue
    probe.queue(61.0, 65.0, 68.0)
    create_goal!(fixture.fetch("issue_id"), continuity: "fresh_attempt", max_iterations: 3)

    tick!
    first_worker = workers.first
    finish_attempt_session!

    second_worker = workers.last
    refute_equal first_worker.fetch("workspace_path"), second_worker.fetch("workspace_path"),
                 "fresh_attempt must not inherit the previous attempt's worktree"
    assert_equal first_worker.fetch("id"), second_worker.fetch("follow_up_of_agent_id"),
                 "lineage is still recorded even though the checkout is not shared"
    refute_includes harness_client.spawns.last.fetch("prompt"), "Stay in this workspace and branch"
  end

  def test_fresh_attempt_continuity_links_each_iteration_to_the_previous_worker
    fixture = project_with_issue
    probe.queue(61.0, 65.0, 68.0)
    create_goal!(fixture.fetch("issue_id"), continuity: "fresh_attempt")

    tick!
    finish_attempt_session!

    assert_equal 2, workers.length
    assert_equal workers.first.fetch("id"), workers.last.fetch("follow_up_of_agent_id")
  end

  def test_the_metric_is_measured_on_the_attempt_workspace_not_the_project_root
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"))

    tick!
    workspace_path = workers.first.fetch("workspace_path")
    finish_attempt_session!

    baseline_call, iteration_call = probe.calls.first(2)
    assert_equal fixture.fetch("root"), baseline_call.fetch("cwd"), "the baseline has no attempt branch yet"
    assert_equal workspace_path, iteration_call.fetch("cwd")
    assert_equal workspace_path, probe.guardrail_calls.map { |call| call.fetch("cwd") }.first if probe.guardrail_calls.any?
  end

  def test_a_project_root_metric_always_measures_the_project_root
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"), metric_cwd: "project_root")

    tick!
    finish_attempt_session!

    assert_equal [fixture.fetch("root")], probe.calls.map { |call| call.fetch("cwd") }.uniq
  end

  def test_a_paused_goal_is_not_advanced_and_resumes_where_it_stopped
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"), paused: true)

    3.times { tick! }

    assert_empty workers, "a paused goal must not spawn"
    assert_nil goal.fetch("baseline_metric")

    apply!("ModifyGoal", { "goal_id" => "G1", "paused" => false })
    tick!

    assert_equal 1, workers.length
    assert_equal 61.0, goal.dig("baseline_metric", "value")
  end

  def test_pausing_mid_flight_leaves_the_running_attempt_alone_and_blocks_the_next_one
    fixture = project_with_issue
    probe.queue(61.0, 65.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!

    apply!("ModifyGoal", { "goal_id" => "G1", "paused" => true })
    finish_attempt_session!

    assert_equal 1, workers.length, "no new attempt while paused"
    assert_equal "attempting", iterations.first.fetch("phase"), "the in-flight attempt is not judged while paused"
    assert_equal "completed", workers.first.fetch("status"), "the attempt session itself is untouched"
  end

  def test_stopping_a_goal_ends_the_loop_but_keeps_the_attempt_session
    fixture = project_with_issue
    probe.queue(61.0, 65.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!

    result = apply!("StopGoal", { "goal_id" => "G1" })

    assert_equal "killed", goal.fetch("status")
    assert_equal "user_stopped", goal.fetch("stop_reason")
    assert_match(/Stopped goal G1/, result.fetch("message"))
    assert_equal 1, workers.length
    refute_equal "killed", workers.first.fetch("status"), "StopGoal is not a kill"

    3.times { tick! }
    assert_equal 1, workers.length
  end

  def test_a_spawn_failure_settles_the_iteration_instead_of_retrying_forever
    fixture = project_with_issue
    probe.queue(61.0, 61.0, 61.0, 61.0)
    create_goal!(fixture.fetch("issue_id"))
    harness_client.spawn_error = IOError.new("no harness available")

    tick_until_settled!(max_ticks: 12)

    assert_equal "blocked", goal.fetch("status")
    assert_equal "no_progress", goal.fetch("stop_reason")
    assert settled_iterations.all? { |iteration| iteration.fetch("verdict") == "inconclusive" }
    assert logs_matching(/could not start iteration/).any?
    # The failed spawns leave errored reservations behind, but the loop stops after the
    # no-progress guard trips instead of retrying a broken harness forever.
    assert workers.all? { |worker| worker.fetch("status") == "errored" }, workers.map { |worker| worker.fetch("status") }.inspect
    assert_operator workers.length, :<=, 2
    assert_operator goal.fetch("workers_spawned"), :<=, goal.dig("budget", "max_workers")
  end

  def test_a_goal_owned_by_another_live_instance_is_not_advanced_here
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"))
    patched = store.load
    patched.fetch("goals").first.merge!(
      "owner_instance_id" => "someone-else",
      "owner_instance_pid" => Process.pid,
      "owner_instance_started_at" => nil
    )
    store.save(patched)

    tick!

    assert_empty workers, "another live instance owns this goal loop"
  end

  def test_iteration_history_is_the_source_of_truth_and_survives_a_restart
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"), continuity: "fresh_attempt")
    tick!
    finish_attempt_session!

    # A fresh engine over the same state file: the loop's memory is the goal record, not
    # anything held in process.
    @engine = build_engine
    tick!

    assert_equal 1, settled_iterations.length
    assert_equal 70.0, settled_iterations.first.dig("metric", "value")
    assert_equal 2, workers.length
    assert_includes harness_client.spawns.last.fetch("prompt"), "it1: metric 70"
  end

  def test_a_slow_metric_on_one_goal_does_not_starve_the_other_goals_forever
    first = project_with_issue(title: "First goal issue")
    second_issue = apply!(
      "CreateIssue",
      { "project_id" => first.fetch("project_id"), "title" => "Second goal issue", "description" => "" }
    ).fetch("target_id")
    # The pass budget is injected so this asserts the deferral rule without a long sleep.
    slow_probe = SlowFirstMeasurementProbe.new(delay: 0.15)
    slow_probe.queue(61.0, 61.0)
    @engine = build_engine(metric_probe: slow_probe, goal_advance_budget: 0.05)
    create_goal!(first.fetch("issue_id"))
    create_goal!(second_issue, success_criteria: "second goal")

    tick!

    # The first goal burned the pass budget, so the second goal is left for the next tick
    # rather than delaying reconciliation further.
    assert_equal 1, slow_probe.calls.length
    assert_nil goal("G2").fetch("baseline_metric")

    # With an ordinary pass budget the deferred goal is picked up on a later tick.
    @engine = build_engine(metric_probe: slow_probe)
    tick!

    refute_nil goal("G2").fetch("baseline_metric"), "the deferred goal is advanced by a later tick"
  end

  def test_reconcile_reports_goal_loop_steps_so_the_tick_is_observable
    fixture = project_with_issue
    probe.queue(61.0)
    create_goal!(fixture.fetch("issue_id"))

    result = tick!
    steps = result.fetch("result").fetch("goal_loop_steps")

    assert_equal %w[measure_baseline start_iteration], steps.map { |step| step.fetch("phase") }
    assert steps.all? { |step| step.fetch("goal_id") == "G1" }
    assert steps.all? { |step| step.fetch("log_entry_ids").any? }
  end
end
