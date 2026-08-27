# frozen_string_literal: true

require "test_helper"
require "support/kernel_goals_support"

# Reviewer-judged goal loops, driven end to end by the real reconcile tick.
#
# These are the goals with no number: "this onboarding reads well", "the UX feels right".
# The loop shape is the same as a metric goal — attempt, check, judge, settle — except the
# verdict comes from a reviewer session the kernel spawns on the attempt's own branch. The
# three outcomes that matter are asserted here: the reviewer approves, the reviewer never
# approves and the iteration budget ends the loop as a reported outcome, and the reviewer's
# turn fails or returns garbage.
class KernelGoalsReviewerTest < Minitest::Test
  include KernelGoalsSupport

  APPROVED = { "approved" => true, "rationale" => "reads cleanly and covers the three commands", "critique" => [] }.freeze

  def setup
    goals_setup
  end

  def teardown
    goals_teardown
  end

  def open_questions
    state.fetch("questions").select { |question| question.fetch("status") == "open" }
  end

  def changes_requested(*items)
    { "approved" => false, "rationale" => "not there yet", "critique" => items }
  end

  # --- creating one ----------------------------------------------------------

  def test_a_reviewer_judged_goal_needs_no_metric_and_records_its_judge
    fixture = project_with_issue
    result = create_reviewer_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"])
    record = result.fetch("result")

    assert_equal "reviewer", record.dig("judge", "mode")
    assert_equal "", record.dig("metric", "command")
    assert_nil record.dig("metric", "target")
    assert_equal ["rake test"], record.dig("metric", "guardrails").map { |guardrail| guardrail.fetch("command") }
    assert_equal "accumulate", record.fetch("continuity"), "a subjective goal refines one branch by default"
    assert_equal 3, record.dig("budget", "max_iterations")
    assert_match(/reviewer: not reviewed yet/, result.fetch("message"))
  end

  def test_a_reviewer_judged_goal_rejects_a_metric_command_instead_of_ignoring_it
    fixture = project_with_issue

    result = apply_raw(
      "CreateGoal",
      {
        "issue_id" => fixture.fetch("issue_id"),
        "success_criteria" => "the onboarding reads well",
        "judge_mode" => "reviewer",
        "metric_command" => "rake coverage",
        "target" => 80
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert result.fetch("errors").any? { |error| error.include?("attach that command as a guardrail instead") }
    assert_empty state.fetch("goals")
  end

  # The two creation forms and the two judges are independent, so the prompt form (the kernel
  # mints the issue) has to work without a metric too.
  def test_the_prompt_form_mints_an_issue_for_a_reviewer_judged_goal
    fixture = registered_project
    result = apply!(
      "CreateGoal",
      {
        "prompt" => "Make the first-run onboarding read cleanly. It should name the three core commands on the first screen.",
        "success_criteria" => "the onboarding reads cleanly and names the three core commands on the first screen",
        "judge_mode" => "reviewer",
        "guardrails" => ["rake test"],
        "max_iterations" => 2,
        "min_seconds_between_iterations" => 0
      }
    )
    record = result.fetch("result")
    issue = state.fetch("issues").first

    assert_equal fixture.fetch("project_id"), issue.fetch("project_id")
    assert_equal issue.fetch("id"), record.fetch("issue_id")
    assert_equal "reviewer", record.dig("judge", "mode")
    assert_equal "Make the first-run onboarding read cleanly", issue.fetch("title")
    assert_includes issue.fetch("description"), "an independent reviewer session per iteration"
    assert_includes issue.fetch("description"), "rake test"
    refute_includes issue.fetch("description"), "Metric", "a reviewer-judged issue must not describe a metric nobody measures"

    harness_client.queue_review(APPROVED)
    tick_until_settled!

    assert_equal "completed", goal.fetch("status")
    assert_equal "goal_met", goal.fetch("stop_reason")
  end

  def test_a_reviewer_goal_created_from_a_prompt_still_rejects_a_metric_and_mints_no_issue
    registered_project

    result = apply_raw(
      "CreateGoal",
      { "prompt" => "make the onboarding read well", "judge_mode" => "reviewer", "metric_command" => "rake coverage", "target" => 80 }
    )

    assert_equal "rejected", result.fetch("status")
    assert result.fetch("errors").any? { |error| error.include?("attach that command as a guardrail instead") }
    assert_empty state.fetch("issues"), "a rejected goal leaves no orphan issue behind"
    assert_empty state.fetch("goals")
  end

  def test_a_metric_goal_still_requires_its_metric
    fixture = project_with_issue

    result = apply_raw("CreateGoal", { "issue_id" => fixture.fetch("issue_id"), "success_criteria" => "x" })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "metric.command is required"
  end

  # The typed path is the one a user actually reaches for, so it is driven through the real
  # parser rather than a hand-built payload.
  def test_the_typed_slash_command_creates_a_goal_that_runs_to_approval
    fixture = project_with_issue
    issue_id = fixture.fetch("issue_id")
    input = "/goal create #{issue_id} \"the onboarding reads cleanly\" --reviewer --max-iterations 2 --guardrail \"rake test\""
    command = Meringue::Input::SlashCommandParser.new.parse(input)
    result = apply_raw(command.type, command.payload)

    assert_equal "accepted", result.fetch("status"), result.fetch("errors").inspect
    assert_equal "reviewer", result.fetch("result").dig("judge", "mode")
    assert_equal 2, result.fetch("result").dig("budget", "max_iterations")
    assert_equal ["rake test"], result.fetch("result").dig("metric", "guardrails").map { |guardrail| guardrail.fetch("command") }

    harness_client.queue_review(APPROVED)
    tick_until_settled!

    assert_equal "completed", goal.fetch("status")
    assert_equal "goal_met", goal.fetch("stop_reason")
  end

  # --- the approving reviewer ------------------------------------------------

  def test_the_loop_completes_when_the_reviewer_approves
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"])
    harness_client.queue_review(changes_requested("explain /goal in the first screen", "add a worked example"), APPROVED)

    tick_until_settled!

    assert_equal "completed", goal.fetch("status")
    assert_equal "goal_met", goal.fetch("stop_reason")
    assert_equal %w[not_met met], settled_iterations.map { |iteration| iteration.fetch("verdict") }
    assert_equal %w[reviewer reviewer], settled_iterations.map { |iteration| iteration.fetch("judged_by") }
    assert settled_iterations.last.dig("review", "approved")
    assert_equal "completed", issue_record(fixture.fetch("issue_id")).fetch("status")
    assert_empty open_questions, "an approved goal does not need to ask the user anything"
    assert logs_matching(/reviewer verdict for iteration 2: approved/).any?
    assert logs_matching(/met its success criteria/).any?
  end

  def test_the_reviewer_reads_the_attempt_branch_and_gets_the_criteria_and_the_contract
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"])
    harness_client.queue_review(APPROVED)

    tick!
    attempt_workspace = workers.first.fetch("workspace_path")
    settle_sessions!

    prompt = harness_client.review_prompts.first
    refute_nil prompt, "the settled attempt must be handed to a reviewer"
    assert_includes prompt, "the first-run onboarding reads cleanly"
    assert_includes prompt, "read-only review turn"
    assert_includes prompt, "\"approved\""
    assert_includes prompt, "`rake test`: passed", "the reviewer sees the guardrails the kernel already ran"
    assert_includes prompt, "iteration 1 of 3"

    review_worker = review_workers.first
    assert_equal attempt_workspace, review_worker.fetch("workspace_path"), "the reviewer reads the attempt's own worktree"
    assert_equal attempt_workspace, harness_client.spawns.last.fetch("cwd")
    assert_equal "G1-IT1-REVIEW", iterations.first.fetch("review_command_id")
  end

  def test_the_critique_becomes_the_next_attempts_directive
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"))
    harness_client.queue_review(changes_requested("name the three commands explicitly", "cut the second paragraph"), APPROVED)

    tick_until_settled!

    directive = settled_iterations.first.fetch("next_directive")
    assert_includes directive, "name the three commands explicitly"
    assert_includes directive, "cut the second paragraph"
    assert_includes directive, "do not self-approve"

    second_attempt = harness_client.attempt_prompts.last
    assert_includes second_attempt, "name the three commands explicitly"
    assert_includes second_attempt, "an independent reviewer, not a metric"
    refute_includes second_attempt, "Metric: ``", "a reviewer-judged goal must not render an empty metric"
  end

  def test_only_one_session_is_live_at_a_time_across_the_attempt_and_the_review
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"))
    harness_client.queue_review(APPROVED)

    tick!
    assert_equal 1, workers.length, "the reviewer is not started while the attempt is still working"
    assert_empty review_workers

    3.times { tick! }
    assert_equal 1, workers.length, "repeated ticks must not fan out"

    settle_sessions!
    assert_equal 1, review_workers.length
    assert_equal 1, attempt_workers.length
    assert_equal review_workers.first.fetch("id"), goal.fetch("active_worker_id"), "a live reviewer is the goal's active session"
  end

  # --- the reviewer that never approves --------------------------------------

  def test_a_reviewer_that_never_approves_stops_at_the_iteration_budget_as_a_reported_outcome
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 3, max_consecutive_no_progress: 5)
    harness_client.queue_review(
      changes_requested("tighten the opening"),
      changes_requested("the example is still wrong"),
      changes_requested("the third screen needs work")
    )

    tick_until_settled!

    assert_equal "blocked", goal.fetch("status"), "the cap is a normal stop, not an error"
    assert_equal "max_iterations", goal.fetch("stop_reason")
    assert_equal 3, settled_iterations.length
    assert settled_iterations.none? { |iteration| iteration.fetch("verdict") == "met" }
    assert_equal "blocked", issue_record(fixture.fetch("issue_id")).fetch("status")

    question = open_questions.last
    assert_includes question.fetch("question"), "without reviewer approval"
    assert_includes question.fetch("question"), "the third screen needs work"
    assert_equal goal.fetch("question_id"), question.fetch("id")

    before = workers.length
    3.times { tick! }
    assert_equal before, workers.length, "a budget-stopped goal must not keep spawning"
  end

  def test_raising_the_budget_restarts_a_capped_reviewer_goal
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 1)
    harness_client.queue_review(changes_requested("tighten the opening"))
    tick_until_settled!

    assert_equal "max_iterations", goal.fetch("stop_reason")

    harness_client.queue_review(APPROVED)
    apply!("ModifyGoal", { "goal_id" => "G1", "max_iterations" => 3, "status" => "working" })
    tick_until_settled!

    assert_equal "completed", goal.fetch("status")
    assert_equal "goal_met", goal.fetch("stop_reason")
  end

  def test_the_same_critique_twice_stops_the_goal_before_the_budget_burns
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 5, max_consecutive_no_progress: 2)
    # Same complaint every round, only reworded punctuation and casing.
    harness_client.queue_review(
      changes_requested("Name the three commands explicitly."),
      changes_requested("name the three commands explicitly"),
      changes_requested("NAME THE THREE COMMANDS EXPLICITLY!")
    )

    tick_until_settled!

    assert_equal "no_progress", goal.fetch("stop_reason")
    assert_equal "blocked", goal.fetch("status")
    # First round, then two rounds that repeated it: the loop stops well short of the
    # five-iteration budget instead of paying for the same exchange three more times.
    assert_equal 3, settled_iterations.length
    assert_includes settled_iterations.last.fetch("evidence"), "reviewer repeated the previous critique"
    assert_includes settled_iterations.last.fetch("next_directive"), "same critique as the previous iteration"
    assert_includes open_questions.last.fetch("question"), "repeated the same critique"
  end

  def test_a_changed_critique_counts_as_progress
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 3, max_consecutive_no_progress: 2)
    harness_client.queue_review(
      changes_requested("tighten the opening"),
      changes_requested("the example still uses the old flag"),
      APPROVED
    )

    tick_until_settled!

    assert_equal "completed", goal.fetch("status")
    assert_equal 0, goal.fetch("consecutive_no_progress")
  end

  def test_an_approved_attempt_with_a_red_guardrail_is_not_a_win
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"], max_iterations: 2)
    probe.guardrail_passes = false
    harness_client.queue_review(APPROVED)

    tick_until_settled!

    refute_equal "completed", goal.fetch("status"), "the reviewer does not get to approve a red suite"
    first = settled_iterations.first
    assert_equal "not_met", first.fetch("verdict")
    assert first.fetch("gaming_suspected")
    assert_includes first.fetch("next_directive"), "rake test"
    assert_includes harness_client.attempt_prompts.last, "rake test"
  end

  # --- the reviewer whose turn fails -----------------------------------------

  def test_an_unreadable_verdict_is_retried_once_and_then_settles_the_iteration
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 3)
    harness_client.queue_review("Looks pretty good to me, ship it!", APPROVED)

    tick_until_settled!

    first = settled_iterations.first
    assert_equal 2, first.fetch("review_attempts"), "one retry, with the parse failure quoted back"
    assert_equal "G1-IT1-REVIEW-RETRY2", first.fetch("review_command_id")
    assert_equal 2, harness_client.review_prompts.length
    assert_includes harness_client.review_prompts.last, "could not be used"
    assert_equal "met", first.fetch("verdict"), "the retry produced a usable verdict"
    assert_equal "completed", goal.fetch("status")
    assert logs_matching(/asking once more/).any?
  end

  def test_a_reviewer_that_keeps_returning_garbage_stops_the_goal_instead_of_looping
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 5)
    harness_client.queue_review("I could not really tell, sorry.")

    tick_until_settled!

    assert_equal "errored", goal.fetch("status")
    assert_equal "probe_unavailable", goal.fetch("stop_reason")
    assert_equal 2, goal.fetch("consecutive_probe_failures")
    assert settled_iterations.all? { |iteration| iteration.fetch("verdict") == "inconclusive" }
    assert_equal 2, settled_iterations.length
    assert settled_iterations.all? { |iteration| iteration.fetch("review_attempts") == 2 }, "each iteration retries once, then gives up"
    assert_includes open_questions.last.fetch("question"), "usable verdict"
  end

  def test_a_reviewer_that_withholds_approval_without_saying_why_is_unusable_not_a_rejection
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 2)
    harness_client.queue_review({ "approved" => false })

    tick_until_settled!

    review = settled_iterations.first.fetch("review")
    refute review.fetch("usable"), "a rejection with nothing actionable in it cannot drive the next attempt"
    assert_includes review.fetch("error"), "without a rationale or any actionable critique"
    assert_equal "inconclusive", settled_iterations.first.fetch("verdict")
  end

  def test_a_reviewer_session_that_cannot_be_started_settles_the_iteration
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 3)

    tick!
    # Only the reviewer session fails: attempts must keep starting, or the goal would stop on the
    # attempt failure instead of on the unavailable reviewer this test is about.
    harness_client.review_spawn_error = IOError.new("no harness available")
    tick_until_settled!(max_ticks: 12)

    assert_equal "errored", goal.fetch("status")
    assert_equal "probe_unavailable", goal.fetch("stop_reason")
    assert settled_iterations.all? { |iteration| iteration.fetch("verdict") == "inconclusive" }
    assert logs_matching(/could not start the review/).any?
  end

  # --- budgets, interruption, and surfacing ----------------------------------

  def test_reviewer_sessions_consume_the_goals_session_budget
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 5, max_workers: 3, max_consecutive_no_progress: 5)
    harness_client.queue_review(
      changes_requested("first round"),
      changes_requested("second round"),
      changes_requested("third round")
    )

    tick_until_settled!

    # An iteration costs two sessions here (attempt plus review), so a 3-session budget affords
    # exactly one complete iteration. The loop stops rather than starting an attempt it could
    # not have judged, which is why the budget is not spent down to the last session.
    assert_equal "budget_exhausted", goal.fetch("stop_reason")
    assert_equal 2, goal.fetch("workers_spawned")
    assert_operator workers.length, :<=, 3
  end

  def test_stopping_a_goal_mid_review_ends_the_loop_and_keeps_the_sessions
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"))
    harness_client.queue_review(APPROVED)
    tick!
    settle_sessions!
    assert_equal 1, review_workers.length

    apply!("StopGoal", { "goal_id" => "G1" })

    assert_equal "killed", goal.fetch("status")
    assert_equal "user_stopped", goal.fetch("stop_reason")
    refute_equal "killed", review_workers.first.fetch("status"), "StopGoal is not a kill"

    3.times { tick! }
    assert_equal "killed", goal.fetch("status")
  end

  def test_killing_a_goal_mid_review_kills_the_reviewer_session
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"))
    harness_client.queue_review(APPROVED)
    tick!
    settle_sessions!
    reviewer_id = review_workers.first.fetch("id")
    reviewer_session = harness_client.spawns.last.fetch("session_id")

    apply!("Kill", { "target_id" => "G1" })

    assert_equal "killed", goal.fetch("status")
    assert_equal "killed", goal.fetch("stop_reason")
    assert_includes harness_client.kills, reviewer_session, "an in-flight reviewer is the session the goal owns"
    refute_includes workers.map { |worker| worker.fetch("id") }, reviewer_id, "the killed reviewer record is removed with the kill"
  end

  def test_list_goals_and_get_info_show_the_iteration_the_verdict_and_the_critique
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"), max_iterations: 4)
    harness_client.queue_review(changes_requested("name the three commands explicitly"))

    tick!
    settle_sessions!
    settle_sessions!

    listing = apply!("ListGoals")
    assert_match(/G1 working/, listing.fetch("message"))
    assert_match(/iteration 2\/4/, listing.fetch("message"))
    assert_match(/reviewer: changes requested/, listing.fetch("message"))
    refute_includes listing.fetch("message"), "metric"

    detail = apply!("ListGoals", { "goal_id" => "G1" }).fetch("result").fetch("goals").first
    assert_equal "reviewer", detail.fetch("judge_mode")
    assert_equal "changes requested", detail.fetch("review_state")
    assert_equal ["name the three commands explicitly"], detail.fetch("last_critique")
    iteration = detail.fetch("iterations").first
    assert_equal false, iteration.fetch("approved")
    assert_includes iteration.fetch("review_line"), "name the three commands explicitly"

    engine.record_user_kernel_command_output(input: "/goal status G1", command_results: [apply!("ListGoals", { "goal_id" => "G1" })])
    assert logs_matching(/it1: not_met changes requested/).any?

    info = apply!("GetInfo", { "target_id" => "G1" }).fetch("result")
    assert_equal "reviewer", info.fetch("goal_summary").fetch("judge_mode")
    assert_equal "changes requested", info.fetch("goal_summary").fetch("review_state")
  end

  def test_a_reviewer_goal_survives_a_restart_mid_review
    fixture = project_with_issue
    create_reviewer_goal!(fixture.fetch("issue_id"))
    harness_client.queue_review(APPROVED)
    tick!
    settle_sessions!

    assert_equal "reviewing", iterations.first.fetch("phase")

    # A fresh engine over the same state file, with the previous owner gone: the loop's
    # memory is the goal record, not anything held in process.
    patched = store.load
    patched.fetch("goals").first.merge!(
      "owner_instance_id" => "previous-instance",
      "owner_instance_pid" => 2_147_483_646,
      "owner_instance_started_at" => nil
    )
    store.save(patched)
    @engine = build_engine
    settle_sessions!

    assert_equal "met", settled_iterations.first.fetch("verdict")
    assert_equal "completed", goal.fetch("status")
  end
end
