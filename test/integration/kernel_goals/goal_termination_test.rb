# frozen_string_literal: true

require "test_helper"
require "support/kernel_goals_support"

# Every way a goal loop is allowed to end, driven through the real reconcile tick. A goal that
# cannot stop is the dangerous failure mode, so each guard is asserted end to end: the loop
# stops, records why, stops spawning, and pulls the user in with a question.
class KernelGoalsTerminationTest < Minitest::Test
  include KernelGoalsSupport

  def setup
    goals_setup
  end

  def teardown
    goals_teardown
  end

  def open_questions
    state.fetch("questions").select { |question| question.fetch("status") == "open" }
  end

  def test_max_iterations_blocks_the_goal_and_asks_the_user_what_to_do
    fixture = project_with_issue
    probe.queue(61.0, 65.0, 69.0, 73.0)
    create_goal!(fixture.fetch("issue_id"), max_iterations: 2)

    tick_until_settled!

    assert_equal "blocked", goal.fetch("status")
    assert_equal "max_iterations", goal.fetch("stop_reason")
    assert_equal 2, settled_iterations.length, "the iteration budget is a hard ceiling"
    assert_equal "blocked", issue_record(fixture.fetch("issue_id")).fetch("status")
    question = open_questions.last
    assert_includes question.fetch("question"), "iteration budget"
    assert_equal goal.fetch("question_id"), question.fetch("id")
    assert_equal fixture.fetch("issue_id"), question.fetch("issue_id")

    before = workers.length
    3.times { tick! }
    assert_equal before, workers.length, "a blocked goal must not keep spawning"
  end

  def test_two_iterations_without_progress_stop_the_goal_before_the_iteration_budget
    fixture = project_with_issue
    # Same measurement every time: the metric never moves.
    probe.queue(61.0, 61.0, 61.0, 61.0, 61.0, 61.0)
    create_goal!(fixture.fetch("issue_id"), max_iterations: 5, max_consecutive_no_progress: 2)

    tick_until_settled!

    assert_equal "no_progress", goal.fetch("stop_reason")
    assert_equal "blocked", goal.fetch("status")
    assert_equal 2, settled_iterations.length
    assert_equal 2, goal.fetch("consecutive_no_progress")
    assert_includes open_questions.last.fetch("question"), "no measurable progress"
    assert logs_matching(/without measurable progress/).any?
  end

  def test_progress_resets_the_no_progress_counter
    fixture = project_with_issue
    probe.queue(61.0, 61.0, 70.0, 70.0, 70.0)
    create_goal!(fixture.fetch("issue_id"), max_iterations: 5, max_consecutive_no_progress: 2)

    tick_until_settled!

    verdicts = settled_iterations.map { |iteration| iteration.fetch("verdict") }
    assert_equal %w[not_met partially_met not_met not_met], verdicts
    assert_equal "no_progress", goal.fetch("stop_reason")
    assert_equal 4, settled_iterations.length, "the counter resets on the iteration that moved the metric"
  end

  def test_repeated_workspace_state_stops_the_goal_as_oscillation
    fixture = project_with_issue
    probe.queue(61.0, 64.0, 67.0, 70.0)
    probe.fingerprints = %w[same same same]
    create_goal!(fixture.fetch("issue_id"), max_iterations: 5)

    tick_until_settled!

    assert_equal "oscillation", goal.fetch("stop_reason")
    assert_equal "blocked", goal.fetch("status")
    assert_includes open_questions.last.fetch("question"), "repeating the same workspace state"
  end

  def test_a_broken_metric_command_errors_the_goal_and_stops_spawning
    fixture = project_with_issue
    probe.queue({ "exit_status" => 127, "value" => nil, "stderr_tail" => "rake: command not found" })
    create_goal!(fixture.fetch("issue_id"))

    tick_until_settled!(max_ticks: 8)

    assert_equal "errored", goal.fetch("status")
    assert_equal "probe_unavailable", goal.fetch("stop_reason")
    assert_empty workers, "a goal whose metric cannot be read must not spawn attempts"
    assert_equal 2, goal.fetch("consecutive_probe_failures")
    assert_includes open_questions.last.fetch("question"), "metric command"
    assert logs_matching(/could not measure its baseline/).any?
  end

  def test_a_metric_that_times_out_mid_loop_stops_the_goal
    fixture = project_with_issue
    probe.queue(61.0, { "timed_out" => true, "value" => nil }, { "timed_out" => true, "value" => nil })
    create_goal!(fixture.fetch("issue_id"), max_iterations: 5)

    tick_until_settled!

    assert_equal "probe_unavailable", goal.fetch("stop_reason")
    assert settled_iterations.all? { |iteration| iteration.fetch("verdict") == "inconclusive" }
  end

  def test_the_wall_clock_budget_stops_a_long_running_goal
    fixture = project_with_issue
    probe.queue(61.0, 65.0, 68.0, 71.0)
    create_goal!(fixture.fetch("issue_id"), max_iterations: 5, max_wall_clock_seconds: 60)
    tick!
    # Age the goal past its wall-clock budget without sleeping.
    patched = store.load
    patched.fetch("goals").first["started_at"] = (Time.now.utc - 3_600).iso8601
    store.save(patched)

    finish_attempt_session!
    tick!

    assert_equal "budget_exhausted", goal.fetch("stop_reason")
    assert_equal "blocked", goal.fetch("status")
  end

  def test_the_agent_session_budget_stops_the_goal
    fixture = project_with_issue
    probe.queue(61.0, 62.0, 63.0, 64.0, 65.0, 66.0)
    create_goal!(fixture.fetch("issue_id"), max_iterations: 5, max_workers: 2, continuity: "fresh_attempt")

    tick_until_settled!

    assert_equal "budget_exhausted", goal.fetch("stop_reason")
    assert_equal 2, goal.fetch("workers_spawned")
    assert_operator workers.length, :<=, 2
  end

  def test_a_metric_target_reached_with_a_failing_guardrail_is_not_a_win
    fixture = project_with_issue
    probe.queue(61.0, 95.0, 95.0, 95.0)
    probe.guardrail_passes = false
    create_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"], max_iterations: 2)

    tick_until_settled!

    refute_equal "completed", goal.fetch("status"), "a green metric with a red guardrail must not complete the goal"
    # Hitting the target while a guardrail is red does not count as progress, so the
    # no-progress guard stops the loop before it burns the rest of the iteration budget.
    assert_equal "no_progress", goal.fetch("stop_reason")
    first = settled_iterations.first
    assert_equal "not_met", first.fetch("verdict")
    assert first.fetch("gaming_suspected")
    assert_includes harness_client.attempt_prompts.last, "rake test"
    assert logs_matching(/verdict not_met/).any?
  end

  def test_raising_the_iteration_budget_restarts_a_blocked_goal
    fixture = project_with_issue
    probe.queue(61.0, 65.0, 70.0, 81.0)
    create_goal!(fixture.fetch("issue_id"), max_iterations: 1)
    tick_until_settled!

    assert_equal "max_iterations", goal.fetch("stop_reason")

    apply!("ModifyGoal", { "goal_id" => "G1", "max_iterations" => 4, "status" => "working" })

    assert_equal "working", goal.fetch("status")
    assert_nil goal.fetch("stop_reason")

    tick_until_settled!

    assert_equal "completed", goal.fetch("status")
    assert_equal "goal_met", goal.fetch("stop_reason")
  end

  def test_a_goal_can_never_exceed_the_hard_iteration_ceiling
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"), max_iterations: 10_000, max_workers: 10_000)

    assert_equal Meringue::Goals::Record::MAX_ITERATIONS_CEILING, goal.dig("budget", "max_iterations")
    assert_operator goal.dig("budget", "max_workers"), :<=, Meringue::Goals::Record.default_max_workers(Meringue::Goals::Record::MAX_ITERATIONS_CEILING)
  end
end
