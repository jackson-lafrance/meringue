# frozen_string_literal: true

require "test_helper"

# The goal loop's decisions are a pure function of the goal record and the agent records, so
# every termination rule, the single-flight invariant, and the judge's scoring are asserted
# here with plain hashes: no kernel, no state file, no harness, no clock.
class KernelGoalsDecisionTest < Minitest::Test
  Loop = Meringue::Goals::Loop
  Record = Meringue::Goals::Record
  Evaluator = Meringue::Goals::Evaluator
  AttemptPrompt = Meringue::Goals::AttemptPrompt

  def goal(overrides = {})
    base = {
      "id" => "G1",
      "project_id" => "P1",
      "issue_id" => "P1-I1",
      "title" => "Raise coverage",
      "success_criteria" => "coverage at least 80",
      "status" => "working",
      "paused" => false,
      "continuity" => "fresh_attempt",
      "metric" => { "command" => "rake coverage", "comparator" => "gte", "target" => 80.0, "parse" => { "type" => "last_number" }, "guardrails" => [] },
      "budget" => {
        "max_iterations" => 3,
        "max_wall_clock_seconds" => 7_200,
        "max_workers" => 8,
        "max_consecutive_no_progress" => 2,
        "min_metric_delta" => 0.0,
        "min_seconds_between_iterations" => 0
      },
      "baseline_metric" => { "value" => 60.0 },
      "iterations" => [],
      "workers_spawned" => 0,
      "consecutive_no_progress" => 0,
      "consecutive_probe_failures" => 0,
      "current_iteration" => 0,
      "created_at" => "2026-07-30T00:00:00Z",
      "started_at" => "2026-07-30T00:00:00Z"
    }
    Record.normalize!(base.merge(overrides.transform_keys(&:to_s)))
  end

  def settled(number:, value:, verdict: "not_met", fingerprint: nil, worker_id: nil, delta: nil)
    {
      "number" => number,
      "phase" => "settled",
      "verdict" => verdict,
      "metric" => { "value" => value },
      "metric_delta" => delta,
      "workspace_fingerprint" => fingerprint,
      "attempt_worker_id" => worker_id
    }
  end

  def now
    Time.parse("2026-07-30T01:00:00Z")
  end

  def test_a_fresh_goal_measures_its_baseline_before_spawning_anything
    action = Loop.next_action(goal: goal("baseline_metric" => nil), agents: [], now: now)

    assert_equal "measure_baseline", action.fetch("action")
  end

  def test_first_decision_after_the_baseline_is_a_spawn_with_a_deterministic_command_id
    action = Loop.next_action(goal: goal, agents: [], now: now)

    assert_equal "start_iteration", action.fetch("action")
    assert_equal "spawn", action.fetch("mode")
    assert_equal 1, action.fetch("number")
    assert_equal "G1-IT1-ATTEMPT", action.fetch("command_id")
  end

  def test_an_in_flight_attempt_makes_the_loop_wait_instead_of_spawning_again
    open_iteration = { "number" => 1, "phase" => "attempting", "attempt_worker_id" => "P1-I1-W1", "attempt_command_id" => "G1-IT1-ATTEMPT" }
    action = Loop.next_action(
      goal: goal("iterations" => [open_iteration]),
      agents: [{ "id" => "P1-I1-W1", "status" => "working" }],
      now: now
    )

    assert_equal "wait", action.fetch("action")
    assert_equal "attempt_in_flight", action.fetch("reason")
  end

  def test_a_settled_attempt_advances_to_measuring_then_judging
    open_iteration = { "number" => 1, "phase" => "attempting", "attempt_worker_id" => "P1-I1-W1" }
    measure = Loop.next_action(
      goal: goal("iterations" => [open_iteration]),
      agents: [{ "id" => "P1-I1-W1", "status" => "completed" }],
      now: now
    )

    assert_equal "measure", measure.fetch("action")
    assert_equal "completed", measure.fetch("attempt_worker_status")

    judge = Loop.next_action(goal: goal("iterations" => [open_iteration.merge("phase" => "judging")]), agents: [], now: now)

    assert_equal "judge", judge.fetch("action")
    assert_equal 1, judge.fetch("iteration_number")
  end

  def test_an_attempting_iteration_with_no_worker_resumes_its_own_command_id
    # This is the crash-between-checkpoint-and-spawn case: it must resume the same iteration,
    # not create a second one, and not silently skip to measuring nothing.
    open_iteration = { "number" => 2, "phase" => "attempting", "attempt_command_id" => "G1-IT2-ATTEMPT" }
    action = Loop.next_action(goal: goal("iterations" => [settled(number: 1, value: 65.0), open_iteration]), agents: [], now: now)

    assert_equal "start_iteration", action.fetch("action")
    assert_equal "G1-IT2-ATTEMPT", action.fetch("command_id")
    assert action.fetch("resumed")
  end

  def test_accumulate_continuity_prompts_the_previous_worker_instead_of_spawning
    action = Loop.next_action(
      goal: goal("continuity" => "accumulate", "iterations" => [settled(number: 1, value: 65.0, worker_id: "P1-I1-W1")]),
      agents: [{ "id" => "P1-I1-W1", "status" => "completed", "harness_session_id" => "sess-1" }],
      now: now
    )

    assert_equal "start_iteration", action.fetch("action")
    assert_equal "prompt", action.fetch("mode")
    assert_equal "P1-I1-W1", action.fetch("worker_id")
    assert_equal 2, action.fetch("number")
  end

  def test_accumulate_falls_back_to_a_fresh_spawn_when_the_previous_worker_cannot_continue
    action = Loop.next_action(
      goal: goal("continuity" => "accumulate", "iterations" => [settled(number: 1, value: 65.0, worker_id: "P1-I1-W1")]),
      agents: [{ "id" => "P1-I1-W1", "status" => "errored", "harness_session_id" => "sess-1" }],
      now: now
    )

    assert_equal "spawn", action.fetch("mode")
  end

  def test_paused_and_terminal_goals_do_nothing
    %w[completed errored killed blocked].each do |status|
      action = Loop.next_action(goal: goal("status" => status), agents: [], now: now)
      assert_equal "none", action.fetch("action"), "#{status} goals must not act"
    end

    paused = Loop.next_action(goal: goal("paused" => true), agents: [], now: now)

    assert_equal "none", paused.fetch("action")
    assert_equal "paused", paused.fetch("reason")
  end

  def test_rate_limit_defers_the_next_iteration_without_stopping_the_goal
    action = Loop.next_action(goal: goal("next_tick_at" => "2026-07-30T02:00:00Z"), agents: [], now: now)

    assert_equal "wait", action.fetch("action")
    assert_equal "rate_limited", action.fetch("reason")
  end

  def test_a_met_verdict_stops_the_goal_as_completed
    action = Loop.next_action(goal: goal("iterations" => [settled(number: 1, value: 81.0, verdict: "met")]), agents: [], now: now)

    assert_equal "stop", action.fetch("action")
    assert_equal "completed", action.fetch("status")
    assert_equal "goal_met", action.fetch("stop_reason")
  end

  def test_max_iterations_stops_the_goal_as_blocked
    iterations = [
      settled(number: 1, value: 62.0, fingerprint: "a"),
      settled(number: 2, value: 64.0, fingerprint: "b"),
      settled(number: 3, value: 66.0, fingerprint: "c")
    ]
    action = Loop.next_action(goal: goal("iterations" => iterations), agents: [], now: now)

    assert_equal "stop", action.fetch("action")
    assert_equal "blocked", action.fetch("status")
    assert_equal "max_iterations", action.fetch("stop_reason")
  end

  def test_no_progress_and_probe_failures_and_budgets_each_stop_the_loop
    no_progress = Loop.next_action(goal: goal("consecutive_no_progress" => 2), agents: [], now: now)
    assert_equal "no_progress", no_progress.fetch("stop_reason")
    assert_equal "blocked", no_progress.fetch("status")

    probe = Loop.next_action(goal: goal("consecutive_probe_failures" => 2), agents: [], now: now)
    assert_equal "probe_unavailable", probe.fetch("stop_reason")
    assert_equal "errored", probe.fetch("status")

    workers = Loop.next_action(goal: goal("workers_spawned" => 8), agents: [], now: now)
    assert_equal "budget_exhausted", workers.fetch("stop_reason")

    clock = Loop.next_action(goal: goal("budget" => { "max_wall_clock_seconds" => 60 }), agents: [], now: now)
    assert_equal "budget_exhausted", clock.fetch("stop_reason")
  end

  def test_a_repeated_workspace_fingerprint_stops_the_loop_as_oscillation
    iterations = [settled(number: 1, value: 62.0, fingerprint: "same"), settled(number: 2, value: 62.0, fingerprint: "same")]
    action = Loop.next_action(goal: goal("iterations" => iterations), agents: [], now: now)

    assert_equal "oscillation", action.fetch("stop_reason")
    assert_equal 2, action.fetch("message")[/iteration (\d+)/, 1].to_i
  end

  def test_an_attempt_that_reproduces_the_baseline_tree_is_also_oscillation
    goal_record = goal(
      "baseline_metric" => { "value" => 60.0, "workspace_fingerprint" => "untouched" },
      "iterations" => [settled(number: 1, value: 60.0, fingerprint: "untouched")]
    )

    assert_equal "oscillation", Loop.next_action(goal: goal_record, agents: [], now: now).fetch("stop_reason")
  end

  # --- judge / evaluator ------------------------------------------------------

  def iteration(value:, guardrails: [], exit_status: 0, timed_out: false, parse_error: nil, number: 1, worker_status: "completed")
    {
      "number" => number,
      "phase" => "judging",
      "attempt_worker_status" => worker_status,
      "metric" => { "value" => value, "exit_status" => exit_status, "timed_out" => timed_out, "parse_error" => parse_error }.compact,
      "guardrails" => guardrails
    }
  end

  def test_reaching_the_target_with_green_guardrails_is_met
    judgement = Evaluator.evaluate(
      goal: goal,
      iteration: iteration(value: 81.0, guardrails: [{ "command" => "rake test", "passed" => true }])
    )

    assert_equal "met", judgement.fetch("verdict")
    assert judgement.fetch("progress")
    assert_equal 1.0, judgement.fetch("score")
    refute judgement.fetch("gaming_suspected")
  end

  def test_reaching_the_target_with_a_failing_guardrail_is_not_met_and_flags_gaming
    judgement = Evaluator.evaluate(
      goal: goal,
      iteration: iteration(value: 95.0, guardrails: [{ "command" => "rake test", "passed" => false, "exit_status" => 1 }])
    )

    assert_equal "not_met", judgement.fetch("verdict")
    assert judgement.fetch("gaming_suspected")
    refute judgement.fetch("progress")
    assert_includes judgement.fetch("next_directive"), "rake test"
    assert judgement.fetch("evidence").any? { |line| line.include?("guardrail failed") }
  end

  def test_movement_short_of_the_target_is_partially_met_and_names_the_delta
    judgement = Evaluator.evaluate(goal: goal, iteration: iteration(value: 70.0))

    assert_equal "partially_met", judgement.fetch("verdict")
    assert judgement.fetch("progress")
    assert_in_delta 10.0, judgement.fetch("metric_delta"), 0.001
    assert_in_delta 0.5, judgement.fetch("score"), 0.001
    assert_includes judgement.fetch("next_directive"), "Keep pushing"
  end

  def test_no_movement_is_not_met_and_asks_for_a_different_approach
    judgement = Evaluator.evaluate(goal: goal, iteration: iteration(value: 60.0))

    assert_equal "not_met", judgement.fetch("verdict")
    refute judgement.fetch("progress")
    assert_includes judgement.fetch("next_directive"), "Change approach"
  end

  def test_a_delta_below_the_progress_threshold_is_not_progress
    judgement = Evaluator.evaluate(goal: goal("budget" => { "min_metric_delta" => 5.0 }), iteration: iteration(value: 62.0))

    assert_equal "not_met", judgement.fetch("verdict")
    refute judgement.fetch("progress")
  end

  def test_a_broken_or_unparseable_probe_is_inconclusive_not_failure
    %w[exit timeout parse].each do |kind|
      iteration = case kind
                  when "exit" then iteration(value: nil, exit_status: 2)
                  when "timeout" then iteration(value: 70.0, timed_out: true)
                  else iteration(value: nil, parse_error: "no number in metric output")
                  end
      judgement = Evaluator.evaluate(goal: goal, iteration: iteration)

      assert_equal "inconclusive", judgement.fetch("verdict"), "#{kind} probe must be inconclusive"
      refute judgement.fetch("probe_ok"), "#{kind} probe must not count as a healthy probe"
      assert_includes judgement.fetch("next_directive"), "rake coverage"
    end
  end

  def test_lower_is_better_goals_score_downward_movement_as_progress
    shrinking = goal(
      "metric" => { "command" => "count warnings", "comparator" => "lte", "target" => 0.0, "parse" => { "type" => "last_number" } },
      "baseline_metric" => { "value" => 40.0 }
    )
    judgement = Evaluator.evaluate(goal: shrinking, iteration: iteration(value: 25.0))

    assert_equal "partially_met", judgement.fetch("verdict")
    assert judgement.fetch("progress")
    assert_in_delta 15.0, judgement.fetch("metric_delta"), 0.001

    met = Evaluator.evaluate(goal: shrinking, iteration: iteration(value: 0.0))
    assert_equal "met", met.fetch("verdict")
  end

  def test_an_exit_status_metric_treats_a_non_zero_exit_as_a_measurement
    pass_fail = goal(
      "metric" => { "command" => "rake test", "comparator" => "gte", "target" => 1.0, "parse" => { "type" => "exit_status" } },
      "baseline_metric" => { "value" => 0.0 }
    )
    judgement = Evaluator.evaluate(goal: pass_fail, iteration: iteration(value: 0.0, exit_status: 1))

    assert judgement.fetch("probe_ok"), "an exit_status metric is about the exit code, not broken by it"
    assert_equal "not_met", judgement.fetch("verdict")
  end

  # --- attempt prompt ---------------------------------------------------------

  def test_the_attempt_prompt_carries_the_metric_history_and_the_previous_directive
    history = [
      settled(number: 1, value: 62.0, delta: 2.0).merge("next_directive" => "Cover the prune blockers."),
      settled(number: 2, value: 64.0, delta: 2.0).merge("next_directive" => "Assert on prune blockers, do not add call-through tests.")
    ]
    prompt = AttemptPrompt.render(
      goal: goal("iterations" => history, "last_metric" => { "value" => 64.0 }, "best_metric" => { "value" => 64.0 }),
      iteration_number: 3
    )

    assert_includes prompt, "Iteration 3 of 3"
    assert_includes prompt, "rake coverage"
    assert_includes prompt, "Baseline 60"
    assert_includes prompt, "it1: metric 62"
    assert_includes prompt, "do not repeat these approaches"
    assert_includes prompt, "Assert on prune blockers"
    assert_includes prompt, "Do not modify the metric command"
    assert_includes prompt, "do not self-report it"
  end

  def test_a_continuation_prompt_tells_the_worker_to_stay_on_its_branch
    prompt = AttemptPrompt.render(goal: goal("continuity" => "accumulate"), iteration_number: 2, mode: "prompt")

    assert_includes prompt, "same workspace and branch"
    assert_includes prompt, "Stay in this workspace and branch across iterations."
  end

  # --- record normalization ---------------------------------------------------

  def test_budgets_are_clamped_to_the_hard_ceilings
    normalized = Record.normalized_budget("max_iterations" => 5_000, "max_wall_clock_seconds" => 10**9, "min_metric_delta" => -3)

    assert_equal Record::MAX_ITERATIONS_CEILING, normalized.fetch("max_iterations")
    assert_equal Record::MAX_WALL_CLOCK_CEILING_SECONDS, normalized.fetch("max_wall_clock_seconds")
    assert_equal 0.0, normalized.fetch("min_metric_delta")
    assert_equal Record.default_max_workers(Record::MAX_ITERATIONS_CEILING), normalized.fetch("max_workers")
  end

  def test_guardrails_are_capped_and_accept_bare_command_strings
    metric = Record.normalized_metric("command" => "m", "guardrails" => ["a", { "command" => "b" }, "c", "d"])

    assert_equal %w[a b c], metric.fetch("guardrails").map { |guardrail| guardrail.fetch("command") }
  end

  def test_an_unimplemented_judge_mode_normalizes_to_the_deterministic_one
    judge = Record.normalized_judge("mode" => "worker_when_metric_met")

    assert_equal "metric_only", judge.fetch("mode")
    assert_equal "worker_when_metric_met", judge.fetch("requested_mode")
  end
end
