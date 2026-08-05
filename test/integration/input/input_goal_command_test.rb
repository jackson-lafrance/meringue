# frozen_string_literal: true

require "test_helper"

# `/goal` is the clutch interface for the goal loop. Every subcommand must converge on the same
# kernel commands a head proposes, so the typed path and the routed path cannot diverge.
class InputGoalCommandsTest < Minitest::Test
  def parser
    @parser ||= Meringue::Input::SlashCommandParser.new
  end

  def parse(input)
    parser.parse(input)
  end

  def test_goal_create_maps_positional_arguments_and_flags_onto_create_goal
    command = parse(
      '/goal create P1-I7 "coverage at least 80%" --metric "bundle exec rake coverage" --target 80 ' \
      '--comparator gte --max-iterations 4 --guardrail "rake test" --guardrail "rubocop" --title "Raise coverage"'
    )

    assert_equal "CreateGoal", command.type
    payload = command.payload
    assert_equal "P1-I7", payload.fetch("issue_id")
    assert_equal "coverage at least 80%", payload.fetch("success_criteria")
    assert_equal "bundle exec rake coverage", payload.fetch("metric_command")
    assert_equal "80", payload.fetch("target")
    assert_equal "gte", payload.fetch("comparator")
    assert_equal "4", payload.fetch("max_iterations")
    assert_equal ["rake test", "rubocop"], payload.fetch("guardrails")
    assert_equal "Raise coverage", payload.fetch("title")
  end

  # The second form: no issue id at all. The kernel mints the issue from the prompt, so the
  # parser only has to keep the two forms apart.
  def test_goal_create_accepts_a_prompt_instead_of_an_existing_issue
    command = parse(
      '/goal create "get kernel coverage to 80%" --metric "bundle exec rake coverage" --target 80 --project P2 --guardrail "rake test"'
    )

    assert_equal "CreateGoal", command.type
    payload = command.payload
    assert_equal "get kernel coverage to 80%", payload.fetch("prompt")
    refute payload.key?("issue_id"), "the prompt form must not invent an issue id"
    refute payload.key?("success_criteria"), "the kernel derives the criteria from the prompt"
    assert_equal "P2", payload.fetch("project_id")
    assert_equal "bundle exec rake coverage", payload.fetch("metric_command")
    assert_equal ["rake test"], payload.fetch("guardrails")
  end

  # An id-shaped first token is always read as an id, so a typo cannot silently become the
  # title of a brand new issue.
  def test_an_id_shaped_first_token_is_never_reinterpreted_as_a_prompt
    lone_id = parse('/goal create P1-I7 --metric "m" --target 1')
    assert_equal "InvalidSlashCommand", lone_id.type
    assert_includes lone_id.payload.fetch("message"), "looks like a record id"

    project_id = parse('/goal create P1 "coverage at 80%" --metric "m" --target 1')
    assert_equal "InvalidSlashCommand", project_id.type
    assert_includes project_id.payload.fetch("message"), "--project P1"

    worker_id = parse('/goal create P1-I7-W2 "coverage at 80%" --metric "m" --target 1')
    assert_equal "InvalidSlashCommand", worker_id.type
    assert_includes worker_id.payload.fetch("message"), "is not an issue id"

    goal_id = parse('/goal create G3 --metric "m" --target 1')
    assert_equal "InvalidSlashCommand", goal_id.type
  end

  def test_an_unquoted_prompt_is_reported_instead_of_being_half_swallowed
    command = parse('/goal create get coverage to 80% --metric "m" --target 80')

    assert_equal "InvalidSlashCommand", command.type
    assert_includes command.payload.fetch("message"), "Quote the whole prompt"
  end

  def test_goal_create_supports_the_parsing_and_budget_flags
    command = parse(
      '/goal create P1-I7 "no offenses" --metric "rubocop" --target 0 --comparator lte ' \
      '--parse regex --pattern "(\\d+) offenses" --min-delta 1 --no-progress 3 --max-workers 6 ' \
      '--metric-cwd project_root --cooldown 30 --fresh-attempt --paused'
    )
    payload = command.payload

    assert_equal "regex", payload.fetch("parse")
    assert_equal "(\\d+) offenses", payload.fetch("pattern")
    assert_equal "1", payload.fetch("min_metric_delta")
    assert_equal "3", payload.fetch("max_consecutive_no_progress")
    assert_equal "6", payload.fetch("max_workers")
    assert_equal "project_root", payload.fetch("metric_cwd")
    assert_equal "30", payload.fetch("min_seconds_between_iterations")
    assert_equal "fresh_attempt", payload.fetch("continuity")
    assert_equal true, payload.fetch("paused")
  end

  def test_goal_lifecycle_subcommands_map_onto_their_kernel_commands
    assert_equal "ListGoals", parse("/goal status").type
    assert_empty parse("/goal status").payload
    assert_equal "G3", parse("/goal status G3").payload.fetch("goal_id")
    assert_equal "ListGoals", parse("/goals").type

    pause = parse("/goal pause G1")
    assert_equal "ModifyGoal", pause.type
    assert_equal({ "goal_id" => "G1", "paused" => true }, pause.payload)

    resume = parse("/goal resume G1")
    assert_equal "ModifyGoal", resume.type
    assert_equal({ "goal_id" => "G1", "paused" => false }, resume.payload)

    stop = parse("/goal stop G1")
    assert_equal "StopGoal", stop.type
    assert_equal({ "goal_id" => "G1" }, stop.payload)
  end

  def test_a_bare_goal_command_lists_the_goal_loops
    assert_equal "ListGoals", parse("/goal").type
    assert_empty parse("/goal").payload
  end

  def test_malformed_goal_commands_report_usage_instead_of_guessing
    ["/goal frobnicate", "/goal pause", "/goal stop G1 G2", "/goal resume"].each do |input|
      command = parse(input)
      assert_equal "InvalidSlashCommand", command.type, input
    end

    missing_value = parse('/goal create P1-I1 "x" --metric')
    assert_equal "InvalidSlashCommand", missing_value.type
    assert_includes missing_value.payload.fetch("message"), "--metric needs a value"

    unknown_flag = parse('/goal create P1-I1 "x" --metric "m" --target 1 --turbo')
    assert_equal "InvalidSlashCommand", unknown_flag.type
    assert_includes unknown_flag.payload.fetch("message"), "--turbo"

    missing_criteria = parse("/goal create P1-I1")
    assert_equal "InvalidSlashCommand", missing_criteria.type

    nothing_at_all = parse('/goal create --metric "m" --target 1')
    assert_equal "InvalidSlashCommand", nothing_at_all.type
    assert_includes nothing_at_all.payload.fetch("message"), "needs a prompt"
  end

  def test_the_goal_usage_message_documents_both_creation_forms
    usage = Meringue::Input::SlashCommandParser::GOAL_USAGE_MESSAGE

    assert_includes usage, '/goal create "<prompt>"'
    assert_includes usage, "/goal create <issue_id>"
    assert_includes usage, "--project <project_id>"
  end

  def test_goal_commands_are_discoverable_from_the_command_list_and_help
    usages = Meringue::Input::SlashCommandParser::COMMAND_SPECS.map(&:first)

    assert usages.any? { |usage| usage.start_with?("/goal create") }
    assert usages.any? { |usage| usage.start_with?("/goal status") }
    assert usages.any? { |usage| usage.start_with?("/goal pause") }
    assert usages.any? { |usage| usage.start_with?("/goal stop") }

    help_usages = Meringue::Kernel::Engine::HELP_COMMANDS.map(&:first)
    assert help_usages.any? { |usage| usage.start_with?("/goal create") }, "/help must document the goal loop"
  end

  def test_typing_a_goal_subcommand_suggests_the_ids_it_needs
    state = {
      "issues" => [{ "id" => "P1-I7", "title" => "Raise coverage", "status" => "working" }],
      "goals" => [{ "id" => "G1", "issue_id" => "P1-I7", "status" => "working", "success_criteria" => "coverage at least 80%" }]
    }

    # The issue id is optional now, so completion leads with the prompt form and still offers
    # every issue the loop could attach to.
    issue_suggestions = Meringue::Input::SlashCommandParser.command_suggestion_records("/goal create ", state: state)
    assert_equal ["\"<prompt>\"", "P1-I7"], issue_suggestions.map { |record| record.fetch("usage") }
    assert_includes issue_suggestions.first.fetch("description"), "no issue needed"
    assert_equal "/goal create", issue_suggestions.first.fetch("completion"), "the note must re-insert what was typed"
    assert_equal "/goal create P1-I7", issue_suggestions.last.fetch("completion")

    # Typing an id narrows to the ids, without the note in the way.
    typed_id = Meringue::Input::SlashCommandParser.command_suggestion_records("/goal create p1", state: state)
    assert_equal ["P1-I7"], typed_id.map { |record| record.fetch("usage") }

    goal_suggestions = Meringue::Input::SlashCommandParser.command_suggestion_records("/goal pause ", state: state)
    assert_equal ["G1"], goal_suggestions.map { |record| record.fetch("usage") }
    assert_includes goal_suggestions.first.fetch("description"), "goal"
    assert_equal "/goal pause G1", goal_suggestions.first.fetch("completion")
  end

  def test_the_kernel_accepts_the_snake_case_command_aliases_a_head_might_use
    aliases = Meringue::Kernel::Engine::COMMAND_ALIASES

    assert_equal "CreateGoal", aliases.fetch("create_goal")
    assert_equal "ModifyGoal", aliases.fetch("modify_goal")
    assert_equal "StopGoal", aliases.fetch("stop_goal")
    assert_equal "ListGoals", aliases.fetch("list_goals")
  end
end
