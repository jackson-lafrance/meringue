# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "timeout"

# Dashboard composer navigation has three layers: slash suggestions own arrows
# while open, visual rows own them inside multiline/soft-wrapped input, and sent
# input history owns only the first/last-row edge. These tests keep that dispatch
# order explicit so fixing one behavior cannot silently disable another.
class TuiChatInputNavigationTest < Minitest::Test
  include TUISupport

  WIDTH = Meringue::TUI::App::DEFAULT_WIDTH
  HEIGHT = Meringue::TUI::App::DEFAULT_HEIGHT
  UP = "\e[A"
  DOWN = "\e[B"
  TAB = "\t"
  SHIFT_TAB = "\e[Z"
  ENTER = "\r"
  CTRL_C = "\u0003"
  CTRL_Z = "\u001a"
  CTRL_Y = "\u0019"

  def setup
    @layout = Meringue::TUI::Layout.new
    @app = Meringue::TUI::App.new(
      layout: @layout,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT)
    )
    @state = empty_state
  end

  def test_up_and_down_move_through_soft_wrapped_composer_rows
    buffer = "x" * 220
    cursor = 150

    moved_up = send_key(UP, buffer, cursor)
    assert_equal buffer, moved_up.fetch(0)
    assert_equal 58, moved_up.fetch(1), "Up should retain the visual column on the previous wrapped row"

    moved_down = send_key(DOWN, buffer, moved_up.fetch(1))
    assert_equal cursor, moved_down.fetch(1), "Down should return to the same visual column"
  end

  def test_hard_multiline_cursor_movement_still_takes_precedence_over_history
    @app.send(:remember_chat_input, "older submitted prompt")
    buffer = "top\nbottom"

    moved = send_key(UP, buffer, buffer.length)

    assert_equal buffer, moved.fetch(0)
    assert_equal 3, moved.fetch(1), "the shorter previous line should clamp the existing column"
    refute_equal "older submitted prompt", moved.fetch(0)
  end

  def test_up_recalls_sent_input_and_down_restores_the_unsent_draft
    submitted = Queue.new
    handler = lambda do |text|
      submitted << text
      { "summary" => "routed" }
    end

    assert_equal ["", 0, -1], @app.send(:handle_key, ENTER, "ship the fix", 12, -1, handler, state_for("ship the fix", 12))
    assert_equal "ship the fix", Timeout.timeout(2) { submitted.pop }

    recalled = send_key(UP, "unfinished draft", "unfinished draft".length)
    assert_equal ["ship the fix", "ship the fix".length, -1], recalled

    restored = send_key(DOWN, recalled.fetch(0), recalled.fetch(1))
    assert_equal ["unfinished draft", "unfinished draft".length, -1], restored
  end

  def test_escape_exits_agent_tree_navigation_without_clearing_the_draft
    state = composed_state(tui_state)
    @app.send(:enter_agent_tree_navigation, state)

    result = @app.send(:handle_key, "\e", "draft", 5, -1, nil, state_for("draft", 5))

    assert_equal ["draft", 5, -1], result
    refute @app.instance_variable_get(:@agent_tree_navigation_active)
  end

  def test_ctrl_c_clears_non_empty_input_but_quits_when_empty
    assert_equal ["", 0, -1], send_key(CTRL_C, "draft", 5)
    refute @app.send(:quit_key?, CTRL_C, "draft")
    assert @app.send(:quit_key?, CTRL_C, "")
  end

  def test_ctrl_y_redoes_an_undoed_composer_edit
    inserted = send_key("a", "", 0)
    assert_equal ["a", 1, -1], inserted

    undone = send_key(CTRL_Z, inserted.fetch(0), inserted.fetch(1))
    assert_equal ["", 0, -1], undone

    redone = send_key(CTRL_Y, undone.fetch(0), undone.fetch(1))
    assert_equal inserted, redone
  end

  def test_new_edit_after_undo_clears_redo_history
    inserted = send_key("a", "", 0)
    undone = send_key(CTRL_Z, inserted.fetch(0), inserted.fetch(1))
    replacement = send_key("b", undone.fetch(0), undone.fetch(1))

    assert_equal ["b", 1, -1], replacement
    assert_equal replacement, send_key(CTRL_Y, replacement.fetch(0), replacement.fetch(1))
  end

  def test_slash_suggestion_navigation_keeps_precedence_over_input_history
    @app.send(:remember_chat_input, "older submitted prompt")
    state = state_for("/", 1)
    records = Meringue::Input::SlashCommandParser.command_suggestion_records("/", limit: nil, state: state)

    result = @app.send(:handle_key, UP, "/", 1, -1, nil, state)

    assert_equal "/", result.fetch(0)
    assert_equal records.length - 1, result.fetch(2)
    refute_equal "older submitted prompt", result.fetch(0)
  end

  def test_tab_cycles_visible_slash_suggestions_without_changing_focus
    state = state_for("/", 1)
    records = Meringue::Input::SlashCommandParser.command_suggestion_records("/", limit: nil, state: state)
    assert_operator records.length, :>, 1

    first = @app.send(:handle_key, TAB, "/", 1, -1, nil, state)
    second = @app.send(:handle_key, TAB, "/", 1, first.fetch(2), nil, state)
    wrapped = @app.send(:handle_key, TAB, "/", 1, records.length - 1, nil, state)
    backward = @app.send(:handle_key, SHIFT_TAB, "/", 1, 0, nil, state)

    assert_equal ["/", 1, 0], first
    assert_equal ["/", 1, 1], second
    assert_equal ["/", 1, 0], wrapped, "forward selection should wrap"
    assert_equal ["/", 1, records.length - 1], backward, "backward selection should wrap"
    assert_equal "chat", @app.instance_variable_get(:@focused_pane)

    @app.instance_variable_set(:@focused_pane, "logs")
    stationary = @app.send(:handle_key, TAB, "/", 1, 0, nil, state)
    assert_equal ["/", 1, 1], stationary
    assert_equal "logs", @app.instance_variable_get(:@focused_pane)
  end

  def test_enter_accepts_the_suggestion_selected_with_tab
    state = state_for("/", 1)
    cycled = @app.send(:handle_key, TAB, "/", 1, -1, nil, state)
    expected = Meringue::Input::SlashCommandParser.command_suggestion_records("/", limit: nil, state: state).fetch(0).fetch("completion")

    accepted = @app.send(:handle_key, ENTER, cycled.fetch(0), cycled.fetch(1), cycled.fetch(2), nil, state)

    assert_equal [expected, expected.length, -1], accepted
  end

  def test_tab_and_shift_tab_move_focus_when_no_suggestion_list_is_visible
    state = state_for("/not-a-command", "/not-a-command".length)

    moved_forward = @app.send(:handle_key, TAB, "/not-a-command", "/not-a-command".length, -1, nil, state)
    assert_equal ["/not-a-command", "/not-a-command".length, -1], moved_forward
    assert_equal "agent_tree", @app.instance_variable_get(:@focused_pane)

    moved_backward = @app.send(:handle_key, SHIFT_TAB, "/not-a-command", "/not-a-command".length, -1, nil, state)
    assert_equal ["/not-a-command", "/not-a-command".length, -1], moved_backward
    assert_equal "chat", @app.instance_variable_get(:@focused_pane)
  end

  private

  def send_key(key, buffer, cursor)
    @app.send(:handle_key, key, buffer, cursor, -1, nil, state_for(buffer, cursor))
  end

  def state_for(buffer, cursor)
    compose_app_state(@app, @state, buffer, -1, cursor)
  end
end
