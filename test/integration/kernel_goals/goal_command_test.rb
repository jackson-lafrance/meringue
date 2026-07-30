# frozen_string_literal: true

require "test_helper"
require "support/kernel_goals_support"

# The goal command surface: CreateGoal/ModifyGoal/StopGoal/ListGoals validation and results,
# plus GetInfo on a goal id. Goal commands are ordinary kernel commands, so they are validated,
# logged, and head-proposable exactly like the rest.
class KernelGoalsCommandTest < Minitest::Test
  include KernelGoalsSupport

  def setup
    goals_setup
  end

  def teardown
    goals_teardown
  end

  def test_create_goal_records_criteria_metric_budgets_and_defaults
    fixture = project_with_issue
    result = create_goal!(fixture.fetch("issue_id"), guardrails: ["rake test"], comparator: "gte")
    record = result.fetch("result")

    assert_equal "G1", result.fetch("target_id")
    assert_equal fixture.fetch("issue_id"), record.fetch("issue_id")
    assert_equal fixture.fetch("project_id"), record.fetch("project_id")
    assert_equal "queued", record.fetch("status")
    assert_equal "metric", record.fetch("kind")
    assert_equal "rake coverage", record.dig("metric", "command")
    assert_equal 80.0, record.dig("metric", "target")
    assert_equal "gte", record.dig("metric", "comparator")
    assert_equal ["rake test"], record.dig("metric", "guardrails").map { |guardrail| guardrail.fetch("command") }
    assert_equal 3, record.dig("budget", "max_iterations")
    assert_equal "metric_only", record.dig("judge", "mode")
    assert_equal "accumulate", record.fetch("continuity")
    assert_equal 0, record.fetch("current_iteration")
    assert_empty record.fetch("iterations")
    assert_equal "working", issue_record(fixture.fetch("issue_id")).fetch("status")
    assert logs_matching(/Created goal G1 on #{fixture.fetch("issue_id")}/).any?
  end

  def test_create_goal_validates_its_inputs
    fixture = project_with_issue

    missing = apply_raw("CreateGoal", { "issue_id" => fixture.fetch("issue_id") })
    assert_equal "rejected", missing.fetch("status")
    assert_includes missing.fetch("errors"), "success_criteria is required"
    assert_includes missing.fetch("errors"), "metric.command is required"
    assert_includes missing.fetch("errors"), "metric.target must be a number"

    unknown_issue = apply_raw("CreateGoal", { "issue_id" => "P9-I9", "success_criteria" => "x", "metric_command" => "m", "target" => 1 })
    assert_equal "rejected", unknown_issue.fetch("status")
    assert_includes unknown_issue.fetch("errors"), "issue_not_found"

    bad_comparator = apply_raw(
      "CreateGoal",
      { "issue_id" => fixture.fetch("issue_id"), "success_criteria" => "x", "metric_command" => "m", "target" => 1, "comparator" => "approximately" }
    )
    assert_equal "rejected", bad_comparator.fetch("status")
    assert bad_comparator.fetch("errors").any? { |error| error.include?("comparator must be one of") }

    assert_empty state.fetch("goals"), "a rejected command must not mutate state"
  end

  def test_a_judge_mode_that_is_not_implemented_is_rejected_with_a_clear_reason
    fixture = project_with_issue

    result = apply_raw(
      "CreateGoal",
      {
        "issue_id" => fixture.fetch("issue_id"),
        "success_criteria" => "x",
        "metric_command" => "m",
        "target" => 1,
        "judge_mode" => "worker_when_metric_met"
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert result.fetch("errors").any? { |error| error.include?("not implemented yet") }
  end

  def test_one_issue_can_only_own_one_active_goal
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))

    duplicate = apply_raw(
      "CreateGoal",
      { "issue_id" => fixture.fetch("issue_id"), "success_criteria" => "second", "metric_command" => "m", "target" => 1 }
    )

    assert_equal "rejected", duplicate.fetch("status")
    assert_includes duplicate.fetch("errors"), "issue_already_has_active_goal"
    assert_equal 1, state.fetch("goals").length
  end

  def test_a_settled_goal_frees_the_issue_for_a_new_one
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))
    apply!("StopGoal", { "goal_id" => "G1" })

    second = create_goal!(fixture.fetch("issue_id"), success_criteria: "a different bar")

    assert_equal "G2", second.fetch("target_id")
    assert_equal 2, state.fetch("goals").length
  end

  def test_modify_goal_pauses_resumes_and_retargets
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))

    paused = apply!("ModifyGoal", { "goal_id" => "G1", "paused" => true })
    assert goal.fetch("paused")
    assert_match(/paused/, paused.fetch("message"))

    apply!("ModifyGoal", { "goal_id" => "G1", "paused" => false })
    refute goal.fetch("paused")

    apply!("ModifyGoal", { "goal_id" => "G1", "target" => 90, "max_iterations" => 7, "success_criteria" => "coverage at least 90%" })
    assert_equal 90.0, goal.dig("metric", "target")
    assert_equal 7, goal.dig("budget", "max_iterations")
    assert_equal "coverage at least 90%", goal.fetch("success_criteria")
  end

  def test_modify_goal_is_case_insensitive_about_the_goal_id
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))

    result = apply!("ModifyGoal", { "goal_id" => "g1", "paused" => true })

    assert_equal "G1", result.fetch("target_id")
    assert goal.fetch("paused")
  end

  def test_modify_goal_cannot_be_used_to_stop_or_resurrect_a_goal
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))

    bad_status = apply_raw("ModifyGoal", { "goal_id" => "G1", "status" => "completed" })
    assert_equal "rejected", bad_status.fetch("status")
    assert_includes bad_status.fetch("errors"), "invalid_goal_status"

    apply!("StopGoal", { "goal_id" => "G1" })
    resurrect = apply_raw("ModifyGoal", { "goal_id" => "G1", "status" => "working" })
    assert_equal "rejected", resurrect.fetch("status")
    assert_includes resurrect.fetch("errors"), "goal_not_modifiable"
  end

  def test_stop_goal_is_idempotent_and_reports_the_existing_reason
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))
    apply!("StopGoal", { "goal_id" => "G1" })

    again = apply!("StopGoal", { "goal_id" => "G1" })

    assert_match(/already killed \(user_stopped\)/, again.fetch("message"))
    assert_equal 1, logs_matching(/Stopped goal G1/).length, "one logical stop produces one log line"
  end

  def test_unknown_goal_ids_are_rejected_not_silently_ignored
    %w[ModifyGoal StopGoal ListGoals].each do |command_type|
      result = apply_raw(command_type, { "goal_id" => "G9" })
      assert_equal "rejected", result.fetch("status"), command_type
      assert_includes result.fetch("errors"), "goal_not_found", command_type
    end
  end

  def test_list_goals_summarizes_every_loop_and_one_loop_in_detail
    fixture = project_with_issue
    probe.queue(61.0, 70.0)
    create_goal!(fixture.fetch("issue_id"))
    tick!
    finish_attempt_session!

    all = apply!("ListGoals")
    assert_match(/G1 working/, all.fetch("message"))
    assert_match(/iteration 2\/3/, all.fetch("message"))
    assert_match(/metric 70 → 80/, all.fetch("message"))
    refute_includes all.fetch("message"), "\n", "one command produces one scannable log line"

    # What the user actually reads in the logs pane.
    engine.record_user_kernel_command_output(input: "/goal status", command_results: [all])
    assert logs_matching(/Command output: ListGoals: accepted/).any?
    assert logs_matching(/it1: partially_met metric 70/).any?

    one = apply!("ListGoals", { "goal_id" => "G1" })
    summary = one.fetch("result").fetch("goals").first
    assert_equal "G1", summary.fetch("id")
    assert_equal 1, summary.fetch("iterations").length
    assert_equal "partially_met", summary.fetch("iterations").first.fetch("verdict")
    assert_equal 70.0, summary.fetch("iterations").first.fetch("metric")
  end

  def test_list_goals_on_empty_state_says_so
    assert_equal "No goal loops.", apply!("ListGoals").fetch("message")
  end

  def test_get_info_resolves_a_goal_id_and_lists_goals_on_its_issue
    fixture = project_with_issue
    create_goal!(fixture.fetch("issue_id"))

    info = apply!("GetInfo", { "target_id" => "G1" }).fetch("result")
    assert_equal "goal", info.fetch("kind")
    assert_equal "G1", info.fetch("id")
    assert_equal "rake coverage", info.fetch("record").dig("metric", "command")
    assert_equal "G1", info.fetch("goal_summary").fetch("id")

    issue_info = apply!("GetInfo", { "target_id" => fixture.fetch("issue_id") }).fetch("result")
    assert_equal ["G1"], issue_info.fetch("goals").map { |summary| summary.fetch("id") }
  end

  def test_goal_commands_are_head_proposable_and_run_through_the_normal_command_path
    %w[CreateGoal ModifyGoal StopGoal ListGoals].each do |command_type|
      assert_includes Meringue::Kernel::Engine::HEAD_PROPOSABLE_COMMANDS, command_type
    end
  end

  def test_a_head_can_create_a_goal_with_the_documented_nested_payload
    fixture = project_with_issue

    result = apply!(
      "CreateGoal",
      {
        "issue_id" => fixture.fetch("issue_id"),
        "success_criteria" => "no rubocop offenses",
        "title" => "Zero offenses",
        "metric" => {
          "command" => "rubocop --format simple | tail -1",
          "comparator" => "lte",
          "target" => 0,
          "parse" => { "type" => "regex", "pattern" => "(\\d+) offenses", "capture" => 1 },
          "guardrails" => [{ "command" => "rake test" }]
        },
        "budget" => { "max_iterations" => 4, "min_metric_delta" => 1 }
      }
    )
    record = result.fetch("result")

    assert_equal "lte", record.dig("metric", "comparator")
    assert_equal 0.0, record.dig("metric", "target")
    assert_equal "regex", record.dig("metric", "parse", "type")
    assert_equal "(\\d+) offenses", record.dig("metric", "parse", "pattern")
    assert_equal 4, record.dig("budget", "max_iterations")
    assert_equal 1.0, record.dig("budget", "min_metric_delta")
    assert_equal "Zero offenses", record.fetch("title")
  end
end
