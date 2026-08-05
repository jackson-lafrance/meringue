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
      "/model openai/gpt-5.6-sol" => ["SetDefaultSessionModel", { "model" => "openai/gpt-5.6-sol" }],
      "/thinking xhigh" => ["SetDefaultSessionThinkingLevel", { "level" => "xhigh" }],
      "/project add /tmp" => ["AddProject", { "path" => "/tmp", "name" => "" }],
      "/project rename P1 \"Renamed app\"" => ["ModifyProject", { "project_id" => "P1", "name" => "Renamed app" }],
      "/issue rename P1-I1 \"Renamed issue\"" => ["ModifyIssue", { "issue_id" => "P1-I1", "title" => "Renamed issue" }],
      "/kill P1-I1" => ["Kill", { "target_id" => "P1-I1" }],
      "/dismiss Q1" => ["DismissQuestion", { "question_id" => "Q1" }],
      "/setup complete" => ["CompleteOnboarding", { "outcome" => "completed" }],
      "/setup skip" => ["CompleteOnboarding", { "outcome" => "skipped" }]
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

  def test_rename_commands_join_unquoted_name_tokens
    project = parse_slash("/project rename P1 New Project Name")

    assert_equal "ModifyProject", project.fetch("type")
    assert_equal({ "project_id" => "P1", "name" => "New Project Name" }, project.fetch("payload"))

    issue = parse_slash("/issue rename P1-I1 New Issue Title")

    assert_equal "ModifyIssue", issue.fetch("type")
    assert_equal({ "issue_id" => "P1-I1", "title" => "New Issue Title" }, issue.fetch("payload"))
  end

  # The bare `/rename <id> "<name>"` shortcut was removed. It is still recognised as a word so
  # the rejection names the namespaced replacements instead of a generic "Unknown slash command".
  def test_plain_rename_is_rejected_and_points_at_the_namespaced_commands
    ["/rename", "/rename P1", "/rename P1 \"Renamed app\"", "/RENAME P1-I1 New title"].each do |input|
      parsed = parse_slash(input)

      assert_equal "InvalidSlashCommand", parsed.fetch("type"), "expected #{input.inspect} to be rejected"
      message = parsed.fetch("payload").fetch("message")
      assert_includes message, "/rename was removed."
      assert_includes message, "/project rename <project_id> \"<name>\""
      assert_includes message, "/issue rename <issue_id> \"<title>\""
      assert_equal(
        "Usage: /project rename <project_id> \"<name>\" | /issue rename <issue_id> \"<title>\"",
        parsed.fetch("payload").fetch("usage")
      )
    end
  end

  # It must also be untypeable by autocomplete: neither the command list nor the argument
  # completion contexts may still offer it.
  def test_plain_rename_is_not_suggested_or_completable
    usages = Meringue::Input::SlashCommandParser::COMMAND_SPECS.map(&:first)
    refute_includes usages.map { |usage| usage.split.first }, "/rename"

    prefixes = Meringue::Input::SlashCommandParser::ARGUMENT_SUGGESTION_CONTEXTS.map { |entry| entry.fetch("prefix") }
    refute_includes prefixes, "/rename"

    suggested = Meringue::Input::SlashCommandParser.command_suggestions("/rename", limit: nil)
    refute_includes suggested.map(&:first), "/rename <project_or_issue_id> \"<name>\""
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
    ["/theme", "/theme a b", "/harness", "/model", "/model a b",
     "/thinking", "/thinking high extra",
     "/model P1 extra", "/thinking P1 extra", "/project", "/project list /tmp", "/issue", "/issue delete P1",
     "/worker", "/worker kill P1-I1", "/dismiss", "/dismiss Q1 Q2", "/recount now", "/prune bogus",
     "/prune resolved errored", "/project rename P1", "/issue rename P1-I1"].each do |input|
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

  # The per-session settings readout was removed. Both the command and its old dashboard alias
  # are now ordinary unknown commands, and neither is advertised anywhere in the parser.
  def test_session_settings_and_its_legacy_session_alias_are_unknown_commands
    {
      "/session-settings P1-I1-W1" => "Unknown slash command: /session-settings",
      "/session-settings" => "Unknown slash command: /session-settings",
      "/session P1-I1-W1" => "Unknown slash command: /session",
      "/session" => "Unknown slash command: /session"
    }.each do |input, message|
      parsed = parse_slash(input)

      assert_equal "InvalidSlashCommand", parsed.fetch("type"), "type for #{input.inspect}"
      assert_equal message, parsed.fetch("payload").fetch("message")
      assert_equal "/help", parsed.fetch("payload").fetch("usage")
    end

    usages = Meringue::Input::SlashCommandParser::COMMAND_SPECS.map(&:first)
    refute usages.any? { |usage| usage.start_with?("/session") }
    prefixes = Meringue::Input::SlashCommandParser::ARGUMENT_SUGGESTION_CONTEXTS.map { |context| context.fetch("prefix") }
    refute prefixes.any? { |prefix| prefix.start_with?("/session") }
  end

  # Typing the removed command offers no argument completions either: it is matched as plain
  # unknown text, so the popup keeps showing the real command list.
  def test_removed_session_settings_command_offers_no_argument_suggestions
    records = Meringue::Input::SlashCommandParser.command_suggestion_records(
      "/session-settings ",
      limit: 5,
      state: suggestion_state
    )

    refute_includes records.map { |record| record.fetch("usage") }, "P1-I1-W1"
    refute_includes records.map { |record| record.fetch("kind") }, "sessions"
  end

  # `/defaults` only printed the future-session model/thinking pair, which the
  # dashboard status line and `/config` already show, so it was removed. It is
  # now an ordinary unknown command rather than a hidden alias, and it is gone
  # from the suggestion list and `/help`. The kernel command it used to send,
  # `GetSessionDefaults`, survives for heads answering "show the defaults".
  def test_defaults_command_was_removed_and_is_now_an_unknown_command
    parsed = parse_slash("/defaults")

    assert_equal "InvalidSlashCommand", parsed.fetch("type")
    assert_equal "Unknown slash command: /defaults", parsed.fetch("payload").fetch("message")
    assert_equal "/help", parsed.fetch("payload").fetch("usage")

    usages = Meringue::Input::SlashCommandParser::COMMAND_SPECS.map(&:first)
    refute_includes usages, "/defaults"
    refute Meringue::Kernel::Engine::HELP_COMMANDS.map(&:first).include?("/defaults")
    refute_includes suggestion_records("/def", {}).map { |record| record.fetch("usage") }, "/defaults"
    assert_includes Meringue::Kernel::Engine::HEAD_PROPOSABLE_COMMANDS, "GetSessionDefaults"
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

  # Bare `/setup` opens the local first-run flow; only its two outcome words are
  # a kernel command, so the completion marker is still journaled and logged.
  def test_setup_outcomes_are_validated
    parsed = parse_slash("/setup halfway")

    assert_equal "InvalidSlashCommand", parsed.fetch("type")
    assert_equal "Usage: /setup [complete|skip]", parsed.fetch("payload").fetch("message")
    assert_equal "CompleteOnboarding", parse_slash("/SETUP Skip").fetch("type")
  end

  def test_local_tui_commands_are_reported_as_not_kernel_commands
    %w[/quit /jump /keybind /config /setup].each do |input|
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

  def suggestion_records(input, state)
    Meringue::Input::SlashCommandParser.command_suggestion_records(input, limit: nil, state: state)
  end

  def parsed_command(input)
    parsed = parse_slash(input)
    [parsed.fetch("type"), parsed.fetch("payload")]
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

  def test_future_default_value_suggestions_offer_models_and_thinking_levels
    state = sample_state
    state["metadata"] = { "pi_session_defaults" => { "model" => "openai/gpt-5.6-sol", "thinking_level" => "xhigh" } }
    state.fetch("agents").first["harness_session_id"] = "pi-session-1"

    models = Meringue::Input::SlashCommandParser.command_suggestion_records("/model openai", limit: 5, state: state)
    assert_includes models.map { |record| record.fetch("completion") }, "/model openai/gpt-5.6-sol"

    thinking = Meringue::Input::SlashCommandParser.command_suggestion_records("/thinking x", limit: 5, state: state)
    assert_includes thinking.map { |record| record.fetch("usage") }, "xhigh"
    assert_includes thinking.map { |record| record.fetch("completion") }, "/thinking xhigh"
  end

  # The selector must offer every model the harness reports, not only the values
  # Meringue happened to observe on existing sessions.
  def test_model_suggestions_offer_the_whole_harness_catalog
    state = sample_state_with_model_catalog

    records = suggestion_records("/model ", state)
    assert_equal(
      %w[
        anthropic-flex/claude-opus-5
        anthropic/claude-opus-5
        anthropic-flex/claude-opus-5
        anthropic/claude-opus-5
        google/gemini-3-flash
        openai/gpt-5.6-sol
      ].uniq,
      records.map { |record| record.fetch("usage") }
    )
    assert_equal ["session_models"], records.map { |record| record.fetch("kind") }.uniq
    assert_equal "/model openai/gpt-5.6-sol", records.last.fetch("completion")
    # Ordering puts the saved default first, followed by the rest of the catalog.
    assert_includes records.first.fetch("description"), "current default"
    refute_includes records.map { |record| record.fetch("description") }.join(" "), "future-session default"
    assert_includes records.first.fetch("description"), "thinking: xhigh, max"
    assert_includes records.first.fetch("description"), "1M ctx"

    defaults = suggestion_records("/model ", state)
    assert_equal "anthropic-flex/claude-opus-5", defaults.first.fetch("usage")
    assert_includes defaults.first.fetch("description"), "current default"
    assert_equal 4, defaults.length

    # Filtering searches the whole catalog by reference, id, and display name.
    assert_equal ["google/gemini-3-flash"], suggestion_records("/model gemini", state).map { |record| record.fetch("usage") }
    assert_equal ["openai/gpt-5.6-sol"], suggestion_records("/model sol", state).map { |record| record.fetch("usage") }
    assert_equal ["openai/gpt-5.6-sol"], suggestion_records("/model GPT-5.6", state).map { |record| record.fetch("usage") }
  end

  def test_model_suggestions_follow_the_active_harness
    state = sample_state_with_model_catalog(
      harness: "claude",
      catalogs: {
        "claude" => model_catalog_snapshot(
          harness: "claude",
          models: [{ "provider" => "anthropic", "id" => "claude-opus-5-cc", "thinking_levels" => ["high"] }]
        )
      }
    )

    assert_equal ["anthropic/claude-opus-5-cc"], suggestion_records("/model ", state).map { |record| record.fetch("usage") }
  end

  def test_model_suggestions_degrade_clearly_when_no_catalog_is_available
    state = sample_state_with_model_catalog(catalogs: {})

    records = suggestion_records("/model ", state)
    usages = records.map { |record| record.fetch("usage") }

    # Known references stay completable so an explicit valid id is never blocked.
    assert_includes usages, "anthropic/claude-opus-5"
    assert_includes usages, "anthropic-flex/claude-opus-5"
    assert_includes records.first.fetch("description"), "catalog unavailable"

    note = records.last
    assert_equal "session_models_unavailable", note.fetch("kind")
    assert_includes note.fetch("usage"), "model catalog unavailable"
    assert_includes note.fetch("description"), "/models"
    # Selecting the note cannot clobber a typed id: it re-inserts the prefix only.
    assert_equal "/model", note.fetch("completion")

    # A harness that reports no catalog at all explains itself the same way.
    unsupported = sample_state_with_model_catalog(
      harness: "antigravity",
      catalogs: { "antigravity" => Meringue::Harness::ModelCatalog.unsupported(harness: "antigravity").to_h }
    )
    unsupported_records = suggestion_records("/model ", unsupported)
    assert_equal "session_models_unavailable", unsupported_records.last.fetch("kind")
    assert_includes unsupported_records.last.fetch("description"), "does not expose a model catalog"

    # A typed query hides the note so it can never intercept a completion.
    refute_includes suggestion_records("/model anthropic/", state).map { |record| record.fetch("kind") },
                    "session_models_unavailable"
  end

  # Regression for "the model list only shows Claude Opus 5 and Opus 5 Flex": a
  # last-confirmed list must stay fully offered when the newest refresh failed,
  # instead of shrinking to the configured default plus Pi's built-in default.
  def test_a_last_confirmed_catalog_still_offers_every_model
    stale = Meringue::Harness::ModelCatalog.retained(
      previous: Meringue::Harness::ModelCatalog.from_h(model_catalog_snapshot),
      failure: Meringue::Harness::ModelCatalog.unavailable(
        harness: "pi",
        note: "Could not read Pi's model catalog: connection reset",
        reason: "fetch_failed"
      ),
      last_attempt_at: "2026-03-03T00:00:00Z"
    ).to_h
    state = sample_state_with_model_catalog(catalogs: { "pi" => stale })

    records = suggestion_records("/model ", state)
    models = records.reject { |record| record.fetch("kind") == "session_models_unavailable" }

    assert_equal 4, models.length, "a stale list must not shrink to remembered references"
    assert_equal(
      %w[anthropic-flex/claude-opus-5 anthropic/claude-opus-5 google/gemini-3-flash openai/gpt-5.6-sol],
      models.map { |record| record.fetch("usage") }
    )
    assert_includes models.first.fetch("description"), "last confirmed list"
    # Non-Anthropic entries stay selectable and keep their own thinking levels.
    google = models.find { |record| record.fetch("usage") == "google/gemini-3-flash" }
    assert_equal "/model google/gemini-3-flash", google.fetch("completion")

    note = records.last
    assert_equal "session_models_unavailable", note.fetch("kind")
    assert_includes note.fetch("usage"), "latest refresh failed"
    assert_includes note.fetch("description"), "connection reset"

    # Per-model labels still come from the retained catalog data.
    thinking = suggestion_records("/thinking ", state)
    assert_equal "xhigh", thinking.first.fetch("usage")
    assert_includes thinking.first.fetch("description"), "supported by anthropic-flex/claude-opus-5"
    assert_equal Meringue::Harness::PiClient::THINKING_LEVELS.sort,
                 thinking.map { |record| record.fetch("usage") }.sort
  end

  # The catalog labels thinking levels; it no longer decides which ones exist.
  # Every level the kernel accepts is offered, the saved default leads the list,
  # and a level the model does not advertise says what Pi will run instead.
  def test_thinking_suggestions_offer_every_accepted_level_and_lead_with_the_current_default
    state = sample_state_with_model_catalog

    records = suggestion_records("/thinking ", state)
    assert_equal %w[xhigh off minimal low medium high max], records.map { |record| record.fetch("usage") }
    assert_equal "/thinking xhigh", records.first.fetch("completion")
    assert records.first.fetch("current"), "the saved default must be marked"
    assert_includes records.first.fetch("description"), "current default"
    assert_includes records.first.fetch("description"), "supported by anthropic-flex/claude-opus-5"

    # anthropic-flex/claude-opus-5 advertises only xhigh/max, so the rest of the
    # ladder stays selectable but says Pi will clamp it.
    minimal = records.find { |record| record.fetch("usage") == "minimal" }
    refute minimal.fetch("current")
    assert_includes minimal.fetch("description"), "future sessions"
    assert_includes minimal.fetch("description"), "not listed for anthropic-flex/claude-opus-5"
    assert_includes minimal.fetch("description"), "Pi clamps it to xhigh"

    max = records.find { |record| record.fetch("usage") == "max" }
    assert_includes max.fetch("description"), "supported by anthropic-flex/claude-opus-5"

    # A model whose levels are unknown offers the same ladder and says the model
    # support is unverified rather than pretending the list is authoritative.
    unknown = sample_state_with_model_catalog(catalogs: {})
    unknown_levels = suggestion_records("/thinking ", unknown)
    assert_equal %w[xhigh off minimal low medium high max], unknown_levels.map { |record| record.fetch("usage") }
    assert_includes unknown_levels.first.fetch("description"), "not verified"

    # Typing filters the same list, and prefix matches lead so completing "hi"
    # cannot resolve to the saved default "xhigh" just because it is hoisted.
    assert_equal %w[high xhigh], suggestion_records("/thinking hi", state).map { |record| record.fetch("usage") }
    assert_equal ["off"], suggestion_records("/thinking of", state).map { |record| record.fetch("usage") }
  end

  # Regression for "the max thinking level isn't appearing in /thinking even
  # though I'm on Claude Opus 5": a provider extension can under-declare a
  # model's `thinkingLevelMap`, and the kernel accepts `max` regardless, so the
  # picker must not drop the level its own saved default is already using.
  def test_thinking_suggestions_keep_levels_a_provider_extension_does_not_advertise
    proxy = "anthropic-250k-prefer-using-this-one/claude-opus-5"
    catalogs = {
      "pi" => model_catalog_snapshot(
        models: [
          { "provider" => "anthropic-250k-prefer-using-this-one", "id" => "claude-opus-5", "name" => "Claude Opus 5",
            "thinking_levels" => %w[off minimal low medium high xhigh], "reasoning" => true },
          { "provider" => "anthropic", "id" => "claude-opus-5", "name" => "Claude Opus 5",
            "thinking_levels" => %w[off minimal low medium high xhigh max], "reasoning" => true }
        ]
      )
    }
    state = sample_state_with_model_catalog(catalogs: catalogs, default_model: proxy)
    state.dig("metadata", "pi_session_defaults")["thinking_level"] = "max"

    records = suggestion_records("/thinking ", state)
    usages = records.map { |record| record.fetch("usage") }

    assert_includes usages, "max"
    assert_includes usages, "xhigh"
    assert_equal Meringue::Harness::PiClient::THINKING_LEVELS.sort, usages.sort
    # The level in force is the first thing the three-row popup shows.
    assert_equal "max", usages.first
    assert_includes records.first.fetch("description"), "current default"
    assert_includes records.first.fetch("description"), "not listed for #{proxy}"
    assert_includes records.first.fetch("description"), "Pi clamps it to xhigh"
    # Typing the level the kernel accepts still completes it.
    assert_equal "/thinking max", suggestion_records("/thinking max", state).first.fetch("completion")
  end

  # `/models` no longer dumps the catalog into the log: browsing it is the TUI
  # model picker, so the bare command is a local TUI command like /jump. An
  # explicit `refresh` word is still the kernel path, which is what the picker's
  # refresh key submits and what a head proposes for "what models can I use".
  def test_models_opens_the_local_picker_while_refresh_stays_a_kernel_command
    picker = parse_slash("/models")
    assert_equal "InvalidSlashCommand", picker.fetch("type")
    assert_includes picker.dig("payload", "message"), "local TUI command"
    assert_includes picker.dig("payload", "message"), "model picker"
    assert_equal "InvalidSlashCommand", parse_slash("/models claude").fetch("type")

    assert_equal ["GetModelCatalog", { "refresh" => true }], parsed_command("/models refresh")
    assert_equal ["GetModelCatalog", { "refresh" => true, "harness" => "pi" }], parsed_command("/models pi refresh")
    assert_equal "InvalidSlashCommand", parse_slash("/models pi claude").fetch("type")

    records = suggestion_records("/models ", sample_state_with_model_catalog)
    assert_equal %w[pi claude antigravity], records.map { |record| record.fetch("usage") }
    assert_includes records.first.fetch("description"), "List the models Pi reports"
  end

  def test_argument_suggestions_use_state_records
    workers = Meringue::Input::SlashCommandParser.command_suggestion_records("/prompt ", limit: 5, state: sample_state)
    assert_equal ["P1-I1-W1"], workers.map { |record| record.fetch("usage") }

    issues = Meringue::Input::SlashCommandParser.command_suggestion_records("/worker spawn ", limit: 5, state: sample_state)
    assert_equal ["P1-I1"], issues.map { |record| record.fetch("usage") }

    projects = Meringue::Input::SlashCommandParser.command_suggestion_records("/issue create ", limit: 5, state: sample_state)
    assert_equal ["P1"], projects.map { |record| record.fetch("usage") }
  end

  # `/prompt` retries a failed head as well as prompting a worker, so a head that stopped without
  # routing is offered as a target while heads that already did their job are not.
  def test_prompt_suggestions_include_failed_heads
    state = sample_state
    state.fetch("agents") << { "id" => "H7", "type" => "head", "status" => "errored" }
    state.fetch("agents") << { "id" => "H8", "type" => "head", "status" => "working" }

    records = Meringue::Input::SlashCommandParser.command_suggestion_records("/prompt ", limit: 5, state: state)

    assert_equal %w[P1-I1-W1 H7], records.map { |record| record.fetch("usage") }
    assert_includes records.last.fetch("description"), "retry"
    assert_equal ["PromptAgent", { "agent_id" => "h7", "prompt" => "try again" }],
                 parsed_command('/prompt h7 "try again"')
  end

  # `/prune` takes no arguments, so it contributes no argument suggestions: typing "/prune " keeps
  # offering the command itself rather than a selector list.
  def test_prune_offers_no_argument_suggestions
    records = Meringue::Input::SlashCommandParser.command_suggestion_records("/prune ", limit: 5, state: sample_state)

    assert_equal ["/prune"], records.map { |record| record.fetch("usage") }
    refute_includes records.map { |record| record.fetch("kind") }, "prune_selectors"
  end

  # Ids are handed to the kernel exactly as typed. The kernel canonicalizes them against state
  # (Meringue::Ids), so a lowercase id resolves while an unknown one keeps the typed text in its
  # rejection message.
  def test_id_arguments_are_passed_through_as_typed_for_kernel_resolution
    {
      "/kill h83" => ["Kill", { "target_id" => "h83" }],
      "/kill p1-i23-w1" => ["Kill", { "target_id" => "p1-i23-w1" }],
      "/dismiss q8" => ["DismissQuestion", { "question_id" => "q8" }],
      '/answer q8 "staging"' => ["AnswerQuestion", { "question_id" => "q8", "answer" => "staging" }],
      "/model openai/gpt-5.6-sol" => ["SetDefaultSessionModel", { "model" => "openai/gpt-5.6-sol" }],
      "/thinking xhigh" => ["SetDefaultSessionThinkingLevel", { "level" => "xhigh" }],
      '/worker spawn p1-i1 "go"' => ["SpawnWorker", { "issue_id" => "p1-i1", "prompt" => "go" }],
      '/prompt p1-i1-w1 "hi"' => ["PromptAgent", { "agent_id" => "p1-i1-w1", "prompt" => "hi" }],
      '/issue create p1 "Title"' => ["CreateIssue", { "project_id" => "p1", "title" => "Title", "description" => "" }]
    }.each do |input, (type, payload)|
      parsed = parse_slash(input)

      assert_equal type, parsed.fetch("type"), "type for #{input.inspect}"
      assert_equal payload, parsed.fetch("payload"), "payload for #{input.inspect}"
    end
  end

  # Typing an id in lowercase must still complete, and the completion inserts the canonical id.
  def test_argument_suggestions_match_lowercase_ids_and_complete_canonical_ones
    {
      "/kill p1-i1-w" => ["P1-I1-W1", "/kill P1-I1-W1"],
      "/kill h" => ["H1", "/kill H1"],
      "/prompt p1-i1-w1" => ["P1-I1-W1", "/prompt P1-I1-W1"],
      "/worker spawn p1-i" => ["P1-I1", "/worker spawn P1-I1"],
      "/issue create p" => ["P1", "/issue create P1"],
      "/answer q" => ["Q1", "/answer Q1"],
      "/dismiss q1" => ["Q1", "/dismiss Q1"]
    }.each do |input, (usage, completion)|
      records = Meringue::Input::SlashCommandParser.command_suggestion_records(input, limit: 5, state: suggestion_state)

      assert_includes records.map { |record| record.fetch("usage") }, usage, "usage for #{input.inspect}"
      assert_includes records.map { |record| record.fetch("completion") }, completion, "completion for #{input.inspect}"
    end
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

  private

  # sample_state plus a worker that has a harness session, which is what id completion for
  # agent-targeting commands (`/kill`, `/prompt`, `/jump`) is exercised against.
  def suggestion_state
    state = sample_state
    state.fetch("agents").first["harness_session_id"] = "pi-session-1"
    state
  end
end
