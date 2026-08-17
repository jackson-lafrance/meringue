# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiKeybindingsTest < Minitest::Test
  include TUISupport

  Keybindings = Meringue::TUI::Keybindings

  def setup
    @keys = Keybindings.default
  end

  def test_every_default_action_compiles_to_at_least_one_key_sequence
    Keybindings.actions.each do |action|
      names = @keys.names_for(action)
      refute_empty names, "#{action} has no bound key"
      assert names.all? { |name| Keybindings.compile_name(name).any? }, "#{action} has an uncompilable key"
    end
  end

  def test_every_action_has_a_human_label
    Keybindings.actions.each do |action|
      refute_empty Keybindings.label_for(action)
    end
    assert_equal "Submit / open selected item", Keybindings.label_for("submit")
    assert_equal "mystery action", Keybindings.label_for("mystery_action")
  end

  def test_core_keys_map_to_their_actions
    assert @keys.match?("submit", "\r")
    assert @keys.match?("submit", "\n")
    assert @keys.match?("quit", "\u0004")
    assert @keys.match?("clear_or_quit", "\u0003")
    assert @keys.match?("cancel_navigation", "\e")
    assert @keys.match?("focus_next", "\t")
    assert @keys.match?("focus_previous", "\e[Z")
    assert @keys.match?("scroll_page_up", "\e[5~")
    assert @keys.match?("newline", "\e[13;2u")
    assert @keys.match?("open_agent_workspace", "a")
    assert @keys.match?("workspace_leader", "\u0000")
  end

  def test_unknown_and_non_string_keys_are_ignored
    refute @keys.match?("submit", "x")
    refute @keys.match?("submit", nil)
    refute @keys.match?("submit", { "type" => "mouse" })
    refute @keys.match?("no_such_action", "\r")
    assert_empty @keys.names_for("no_such_action")
  end

  def test_pane_scoped_actions_intentionally_share_keys
    # Ctrl-C is both "clear or quit" and "copy selection"; the App decides which
    # applies from the selection state, so both bindings must resolve.
    assert @keys.match?("clear_or_quit", "\u0003")
    assert @keys.match?("copy_selection", "\u0003")

    # Arrow keys are shared between scroll, cursor, suggestion, and tree
    # navigation actions.
    %w[scroll_up cursor_up suggestion_previous agent_select_previous].each do |action|
      assert @keys.match?(action, "\e[A"), "#{action} should accept the up arrow"
    end
    assert @keys.match?("agent_select_previous", "\e[D")
    assert @keys.match?("complete_suggestion", "\t")
    assert @keys.match?("focus_next", "\t")
  end

  def test_workspace_leader_suffixes_are_distinct_letters
    letters = %w[
      workspace_switch_view
      workspace_cycle_filter
      workspace_open_agent_session
      workspace_open_editor
      workspace_open_pull_request
      workspace_close
    ].map { |action| @keys.names_for(action) }

    assert_equal letters.flatten.length, letters.flatten.uniq.length, "leader suffixes must not collide"
    assert @keys.match?("workspace_close", "q")
  end

  def test_consume_prefix_splits_a_coalesced_leader_and_command
    assert_equal "t", @keys.consume_prefix("workspace_leader", "\u0000t")
    assert_equal "", @keys.consume_prefix("workspace_leader", "\u0000")
    assert_nil @keys.consume_prefix("workspace_leader", "t")
    assert_nil @keys.consume_prefix("workspace_leader", nil)
  end

  def test_display_names_are_terminal_friendly
    assert_equal "Tab", @keys.display_name_for("focus_next")
    assert_equal "A", @keys.display_name_for("open_agent_workspace")
    assert_equal "Ctrl-Space", Keybindings.display_name("ctrl-space")
    assert_equal "Page-Up", Keybindings.display_name("page-up")
    assert_equal "A", Keybindings.display_name("a")
  end

  def test_capture_names_round_trip_terminal_keys_without_action_context
    assert_equal "enter", Keybindings.capture_name("\r")
    assert_equal "up", Keybindings.capture_name("\e[A")
    assert_equal "ctrl-s", Keybindings.capture_name("\u0013")
    assert_equal "ctrl-space", Keybindings.capture_name("\u0000")
    assert_equal "x", Keybindings.capture_name("x")
    assert_equal "space", Keybindings.capture_name(" ")
    assert_equal "raw:\\e[99~", Keybindings.capture_name("\e[99~")
    assert_nil Keybindings.capture_name("paste me")
    assert_nil Keybindings.capture_name({ "type" => "mouse" })

    raw = Keybindings.capture_name("\e[99~")
    assert_equal ["\e[99~"], Keybindings.compile_names([raw])
  end

  def test_action_names_are_canonicalized_and_legacy_aliases_resolve
    assert_equal "focus_next", Keybindings.canonical_action(" Focus Next ")
    assert_equal "workspace_open_agent_session", Keybindings.canonical_action("workspace_open_pi_session")
    assert_equal "workspace_open_agent_session", Keybindings.canonical_action("workspace-open-harness-session")
  end

  def test_workspace_command_labels_are_short_and_harness_agnostic
    assert_equal "terminal/agent", Keybindings.workspace_command_label("workspace_switch_view")
    assert_equal "agent session", Keybindings.workspace_command_label("workspace_open_pi_session")
    refute_includes Keybindings::WORKSPACE_COMMAND_LABELS.values.join(" ").downcase, "pi "
  end

  def test_config_overrides_replace_defaults
    keys = Keybindings.from_config({ "agent_select_previous" => %w[k up] })

    assert_equal %w[k up], keys.names_for("agent_select_previous")
    assert keys.match?("agent_select_previous", "k")
    assert keys.match?("agent_select_previous", "\e[A")
    refute keys.match?("agent_select_previous", "\e[D"), "left arrow is no longer bound"
  end

  def test_config_overrides_ignore_unknown_actions_and_invalid_values
    keys = Keybindings.from_config(
      {
        "bogus_action" => ["x"],
        "submit" => [123],
        "cancel_navigation" => ["not-a-key"]
      }
    )

    assert_empty keys.names_for("bogus_action")
    assert_equal %w[enter], keys.names_for("submit"), "non-string values keep the default"
    assert_equal %w[escape], keys.names_for("cancel_navigation"), "uncompilable names keep the default"
  end

  def test_config_can_unbind_an_action_with_an_empty_list
    keys = Keybindings.from_config({ "quit" => [] })

    assert_empty keys.names_for("quit")
    refute keys.match?("quit", "\u0004")
  end

  def test_config_accepts_a_single_string_and_non_hash_sections
    assert_equal %w[j], Keybindings.from_config({ "agent_select_next" => "j" }).names_for("agent_select_next")
    assert_equal Keybindings.default.names_for("submit"), Keybindings.from_config("nonsense").names_for("submit")
  end

  def test_raw_and_ctrl_sequences_compile
    keys = Keybindings.new({ "open_agent_workspace" => ["raw:\\e[1;2P"], "workspace_close" => ["ctrl-q"] })

    assert keys.match?("open_agent_workspace", "\e[1;2P")
    assert keys.match?("workspace_close", "\u0011")
    assert_equal ["\u0011"], Keybindings.compile_names(["ctrl-q"])
    assert_empty Keybindings.compile_name("totally-unknown")
  end

  def test_documented_keybindings_match_the_defaults
    documentation = File.read(File.expand_path("../../../docs/keybindings.md", __dir__))

    assert_includes documentation, "`Ctrl-D`: quit."
    assert_includes documentation, "`Ctrl-B`"
    assert_includes documentation, "`Shift-Tab`"
    assert @keys.match?("open_delivery_pr", "\u0002")
  end
end
