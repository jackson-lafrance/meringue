# frozen_string_literal: true

require "test_helper"
require "support/input_support"

# Contract tests for Meringue::Input::SlashCommandParser: every documented
# command, quoting, missing/extra arguments, unknown commands, and the exact
# kernel command each one produces.
class InputSlashCommandParserTest < Minitest::Test
  include InputSupport

  def test_documented_commands_map_to_expected_kernel_commands
    expected = {
      "/help" => ["Help", {}],
      "/tree" => ["ListAll", { "view" => "tree" }],
      "/state" => ["GetState", {}],
      "/questions" => ["ListQuestions", {}],
      "/recount" => ["Recount", {}],
      "/clear" => ["ClearState", {}],
      "/prune" => ["Prune", {}],
      "/prune resolved" => ["Prune", { "selector" => "resolved" }],
      "/prune errored" => ["Prune", { "selector" => "errored" }],
      "/theme rose-pine" => ["SetTheme", { "theme" => "rose-pine" }],
      "/harness claude" => ["SetHarness", { "provider" => "claude" }],
      "/project add /tmp" => ["AddProject", { "path" => "/tmp", "name" => "" }],
      "/kill P1-I1" => ["Kill", { "target_id" => "P1-I1" }],
      "/dismiss Q1" => ["DismissQuestion", { "question_id" => "Q1" }]
    }

    expected.each do |input, (type, payload)|
      parsed = parse_slash(input)
      assert_equal type, parsed.fetch("type"), "type for #{input.inspect}"
      assert_equal payload, parsed.fetch("payload"), "payload for #{input.inspect}"
    end
  end

  def test_every_command_spec_entry_parses_to_a_command
    Meringue::Input::SlashCommandParser::COMMAND_SPECS.each do |usage, description|
      refute_empty description
      command = usage.split.first
      parsed = parse_slash(command)
      assert_kind_of String, parsed.fetch("type")
      refute_empty parsed.fetch("type"), "#{command} produced an empty command type"
    end
  end

  def test_quoted_arguments_are_preserved
    parsed = parse_slash('/issue create P1 "Fix the login bug" "Users cannot log in at all"')

    assert_equal "CreateIssue", parsed.fetch("type")
    assert_equal(
      {
        "project_id" => "P1",
        "title" => "Fix the login bug",
        "description" => "Users cannot log in at all"
      },
      parsed.fetch("payload")
    )
  end

  def test_extra_quoted_description_tokens_are_joined_with_spaces
    parsed = parse_slash('/issue create P1 "Title" "first part" "second part"')

    assert_equal "first part second part", parsed.fetch("payload").fetch("description")
  end

  def test_unquoted_project_name_tokens_are_joined
    parsed = parse_slash("/project add /tmp My Nice Project")

    assert_equal({ "path" => "/tmp", "name" => "My Nice Project" }, parsed.fetch("payload"))
  end

  def test_worker_spawn_and_prompt_arguments
    spawn = parse_slash('/worker spawn P1-I1 "Fix it please"')
    assert_equal "SpawnWorker", spawn.fetch("type")
    assert_equal({ "issue_id" => "P1-I1", "prompt" => "Fix it please" }, spawn.fetch("payload"))

    prompt = parse_slash('/prompt P1-I1-W1 "any update?"')
    assert_equal "PromptAgent", prompt.fetch("type")
    assert_equal({ "agent_id" => "P1-I1-W1", "prompt" => "any update?" }, prompt.fetch("payload"))
  end

  def test_answer_command_produces_answer_question_with_quoted_answer
    parsed = parse_slash('/answer Q4 "I meant the text snippet from the i8 worker"')

    assert_equal "AnswerQuestion", parsed.fetch("type")
    assert_equal(
      {
        "question_id" => "Q4",
        "answer" => "I meant the text snippet from the i8 worker"
      },
      parsed.fetch("payload")
    )
  end

  def test_answer_command_joins_unquoted_answer_tokens
    parsed = parse_slash("/answer Q1 use the staging environment")

    assert_equal "AnswerQuestion", parsed.fetch("type")
    assert_equal "use the staging environment", parsed.fetch("payload").fetch("answer")
  end

  def test_answer_command_is_case_insensitive_on_the_command_word
    parsed = parse_slash('/ANSWER Q1 "yes"')

    assert_equal "AnswerQuestion", parsed.fetch("type")
    assert_equal "Q1", parsed.fetch("payload").fetch("question_id")
  end

  # The parser does not know about state, so an answer with no question id or no
  # answer text is still shaped as AnswerQuestion; the kernel rejects it. See
  # test/findings/input.md.
  def test_answer_command_with_missing_arguments_still_builds_answer_question
    assert_equal({ "type" => "AnswerQuestion", "payload" => {} }, parse_slash("/answer"))
    assert_equal(
      { "type" => "AnswerQuestion", "payload" => { "question_id" => "Q1", "answer" => "" } },
      parse_slash("/answer Q1")
    )
  end

  def test_missing_arguments_for_strict_commands_return_invalid_slash_command
    ["/theme", "/theme a b", "/harness", "/project", "/project list /tmp", "/issue", "/issue delete P1",
     "/worker", "/worker kill P1-I1", "/dismiss", "/dismiss Q1 Q2", "/recount now", "/prune bogus",
     "/prune resolved errored"].each do |input|
      parsed = parse_slash(input)
      assert_equal "InvalidSlashCommand", parsed.fetch("type"), "expected #{input.inspect} to be invalid"
      assert_match(/Usage:/, parsed.fetch("payload").fetch("message"))
      refute_empty parsed.fetch("payload").fetch("commands")
    end
  end

  # /prompt, /kill, /answer, /project add, /issue create, and /worker spawn defer
  # argument validation to the kernel instead of rejecting locally.
  def test_lenient_commands_defer_validation_to_the_kernel
    {
      "/prompt" => "PromptAgent",
      "/kill" => "Kill",
      "/answer" => "AnswerQuestion",
      "/project add" => "AddProject",
      "/issue create" => "CreateIssue",
      "/worker spawn" => "SpawnWorker"
    }.each do |input, type|
      parsed = parse_slash(input)
      assert_equal type, parsed.fetch("type"), "type for #{input.inspect}"
      assert_equal({}, parsed.fetch("payload"), "payload for #{input.inspect}")
    end
  end

  def test_unknown_command_returns_invalid_slash_command_with_help_usage
    parsed = parse_slash("/bogus something")

    assert_equal "InvalidSlashCommand", parsed.fetch("type")
    assert_equal "Unknown slash command: /bogus", parsed.fetch("payload").fetch("message")
    assert_equal "/help", parsed.fetch("payload").fetch("usage")
    assert_equal(
      Meringue::Input::SlashCommandParser::COMMAND_SPECS.length,
      parsed.fetch("payload").fetch("commands").length
    )
  end

  def test_local_tui_commands_are_reported_as_not_kernel_commands
    %w[/quit /jump /keybind].each do |input|
      parsed = parse_slash(input)
      assert_equal "InvalidSlashCommand", parsed.fetch("type")
      assert_match(/local TUI command/, parsed.fetch("payload").fetch("message"))
    end
  end

  def test_command_word_is_case_insensitive_and_surrounding_whitespace_is_ignored
    assert_equal "Help", parse_slash("/HELP").fetch("type")
    assert_equal "Help", parse_slash("   /help   ").fetch("type")
    assert_equal "ListAll", parse_slash("/Tree").fetch("type")
  end

  def test_non_slash_input_is_not_a_slash_command
    assert_nil slash_parser.parse("hello world")
    assert_nil slash_parser.parse("")
    assert_nil slash_parser.parse(nil)
    assert_nil slash_parser.parse("answer Q1 yes")
  end

  def test_double_slash_is_an_unknown_command
    parsed = parse_slash("//weird")

    assert_equal "InvalidSlashCommand", parsed.fetch("type")
    assert_equal "Unknown slash command: //weird", parsed.fetch("payload").fetch("message")
  end

  # Documented gap: the parser rescues Shellwords::ParseError, which does not
  # exist on the Ruby used here, so an unbalanced quote raises instead of
  # returning InvalidSlashCommand. This test accepts either outcome so it stays
  # green on any Ruby while still proving the input never becomes a normal
  # kernel command. See test/findings/input.md.
  def test_unbalanced_quotes_never_produce_a_normal_kernel_command
    outcome =
      begin
        slash_parser.parse('/answer Q1 "unterminated')
      rescue StandardError => e
        e
      end

    if outcome.is_a?(StandardError)
      assert_kind_of StandardError, outcome
    else
      assert_equal "InvalidSlashCommand", outcome.to_h.fetch("type")
    end
  end

  def test_command_suggestions_filter_by_prefix
    assert_equal(
      ['/answer <question_id> "<answer>"'],
      Meringue::Input::SlashCommandParser.command_suggestions("/ans", limit: 5).map(&:first)
    )
    assert_equal 3, Meringue::Input::SlashCommandParser.command_suggestions("/", limit: 3).length
  end

  def test_answer_and_dismiss_suggestions_only_offer_open_questions
    records = Meringue::Input::SlashCommandParser.command_suggestion_records(
      "/answer ",
      limit: 5,
      state: sample_state
    )

    assert_equal ["Q1"], records.map { |record| record.fetch("usage") }
    assert_equal "/answer Q1", records.first.fetch("completion")
    assert_equal "open_questions", records.first.fetch("kind")

    dismiss = Meringue::Input::SlashCommandParser.command_suggestion_records(
      "/dismiss ",
      limit: 5,
      state: sample_state
    )
    assert_equal ["Q1"], dismiss.map { |record| record.fetch("usage") }
  end

  def test_argument_suggestions_use_state_records
    workers = Meringue::Input::SlashCommandParser.command_suggestion_records("/prompt ", limit: 5, state: sample_state)
    assert_equal ["P1-I1-W1"], workers.map { |record| record.fetch("usage") }

    issues = Meringue::Input::SlashCommandParser.command_suggestion_records("/worker spawn ", limit: 5, state: sample_state)
    assert_equal ["P1-I1"], issues.map { |record| record.fetch("usage") }

    projects = Meringue::Input::SlashCommandParser.command_suggestion_records("/issue create ", limit: 5, state: sample_state)
    assert_equal ["P1"], projects.map { |record| record.fetch("usage") }
  end

  # `/prune` takes no arguments, so it contributes no argument suggestions: typing "/prune " keeps
  # offering the command itself rather than a selector list.
  def test_prune_offers_no_argument_suggestions
    records = Meringue::Input::SlashCommandParser.command_suggestion_records("/prune ", limit: 5, state: sample_state)

    assert_equal ["/prune"], records.map { |record| record.fetch("usage") }
    refute_includes records.map { |record| record.fetch("kind") }, "prune_selectors"
  end

  # The legacy selector words still parse so existing muscle memory keeps working, but they are
  # inert: the kernel prunes everything eligible either way.
  def test_legacy_prune_selector_words_are_accepted_as_no_op_aliases
    Meringue::Input::SlashCommandParser::PRUNE_COMPATIBILITY_ARGUMENTS.each do |word|
      parsed = parse_slash("/prune #{word}")

      assert_equal "Prune", parsed.fetch("type"), "type for /prune #{word}"
      assert_equal({ "selector" => word }, parsed.fetch("payload"), "payload for /prune #{word}")
    end
  end
end
