# frozen_string_literal: true

require "test_helper"

# `/help` printed 47 commands as one flat list, which is complete and
# unnavigable, and nothing in the product ever defined head, worker, issue, or
# harness — words the setup flow and the AgentTree both depend on.
class InputHelpGroupingTest < Minitest::Test
  Engine = Meringue::Kernel::Engine

  # A command added to the table must land in a real group or in the explicit
  # fallback; it can never quietly disappear from the listing.
  def test_every_command_appears_exactly_once_across_the_groups
    grouped = Engine.grouped_help_commands.flat_map { |_group, entries| entries }

    assert_equal Engine::HELP_COMMANDS.length, grouped.length
    assert_equal Engine::HELP_COMMANDS.sort, grouped.sort
  end

  def test_no_command_falls_through_to_the_catch_all_today
    fallback = Engine.grouped_help_commands.to_h.fetch(Engine::OTHER_HELP_GROUP, [])

    assert_empty fallback, "give these a group in HELP_GROUPS: #{fallback.map(&:first).inspect}"
  end

  # The fallback still has to work, because the point of it is that a future
  # command cannot vanish just because nobody updated the group table.
  def test_an_unknown_command_lands_in_the_catch_all
    assert_equal Engine::OTHER_HELP_GROUP, Engine.help_group_for("/something-nobody-grouped <arg>")
  end

  def test_groups_are_ordered_with_the_newcomer_answer_first
    order = Engine.grouped_help_commands.map(&:first)

    assert_equal "Start here", order.first
    assert_includes Engine::HELP_GROUPS.first.last, "/help"
    assert_includes Engine::HELP_GROUPS.first.last, "/glossary"
  end

  # Subcommands of one command belong together rather than scattered by spelling.
  def test_a_commands_subcommands_share_its_group
    %w[/worker /goal /issue /project].each do |name|
      groups = Engine::HELP_COMMANDS
               .select { |usage, _| usage.start_with?("#{name} ") || usage == name }
               .map { |usage, _| Engine.help_group_for(usage) }
               .uniq

      assert_equal 1, groups.length, "#{name} subcommands are split across #{groups.inspect}"
    end
  end

  # Three inventories describe the same commands; the CLI renders its own from
  # the parser table, so the grouping has to work over that list too.
  def test_the_cli_inventory_groups_with_the_same_table
    specs = Meringue::Input::SlashCommandParser::COMMAND_SPECS
    grouped = Engine.grouped_help_commands(specs).flat_map { |_group, entries| entries }

    assert_equal specs.length, grouped.length
  end

  def test_the_glossary_defines_the_words_the_rest_of_the_interface_uses
    text = Meringue::TUI::Glossary.text

    %w[project issue head worker harness workspace].each do |term|
      assert_includes text, term, "the glossary must define #{term}"
    end
    # The distinction the AgentTree's quiet marker depends on.
    assert_includes text, "Not the same as stuck"
  end

  def test_the_glossary_is_reachable_as_a_command_and_listed_with_the_others
    assert_includes Engine::HELP_COMMANDS.map(&:first), "/glossary"
    assert_includes Meringue::Input::SlashCommandParser::COMMAND_SPECS.map(&:first), "/glossary"
  end

  # It is TUI-local, so typing it outside the dashboard should say where to run
  # it rather than failing as an unknown command.
  def test_the_glossary_outside_the_dashboard_says_where_to_run_it
    parsed = Meringue::Input::SlashCommandParser.new.parse("/glossary")

    assert_equal "InvalidSlashCommand", parsed.type
    assert_includes parsed.payload.fetch("message"), "local TUI command"
  end
end
