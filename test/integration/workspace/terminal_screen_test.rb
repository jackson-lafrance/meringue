# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Screen model used to render the worktree terminal inside the TUI: chunked PTY
# reads, resize, scrolling, and SGR styling.
class WorkspaceTerminalScreenTest < Minitest::Test
  include WorkspaceSupport

  def test_plain_output_lands_on_the_screen_with_a_revision_bump
    screen = Meringue::Workspace::TerminalScreen.new(rows: 4, columns: 10)

    assert_equal 0, screen.revision
    screen.feed("hello\r\nworld\r\n")

    assert_equal ["hello", "world", ""], screen.lines
    assert_equal [2, 0], screen.cursor
    assert_equal 1, screen.revision
  end

  def test_empty_feed_does_not_change_the_revision
    screen = Meringue::Workspace::TerminalScreen.new(rows: 3, columns: 10)
    screen.feed("x")
    revision = screen.revision

    screen.feed("")
    screen.feed(nil)

    assert_equal revision, screen.revision
  end

  def test_multibyte_characters_split_across_chunks_are_held_until_complete
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 20)
    bytes = "λ→🎉 ok".b

    bytes.bytesize.times do |index|
      screen.feed(bytes.byteslice(index, 1))
    end

    assert_equal ["λ→🎉 ok"], screen.lines
    refute_includes screen.lines.join, "\uFFFD"
  end

  def test_partial_escape_sequences_survive_chunk_boundaries
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 20)

    screen.feed("start\e")
    screen.feed("[31m")
    screen.feed("red")

    assert_equal ["startred"], screen.lines
    assert_equal [[["start", nil], ["red", "\e[31m"]]], screen.styled_lines
  end

  def test_chunked_output_is_assembled_in_order
    screen = Meringue::Workspace::TerminalScreen.new(rows: 6, columns: 20)
    stream = "one\r\ntwo\r\nthree\r\nfour\r\n"

    stream.each_char.each_slice(3) { |chunk| screen.feed(chunk.join) }

    assert_equal ["one", "two", "three", "four", ""], screen.lines
  end

  def test_long_lines_wrap_and_scroll_off_the_top
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 5)

    screen.feed("abcdefghijk")

    assert_equal ["fghij", "k"], screen.lines
    assert_equal [1, 1], screen.cursor
  end

  def test_scrolling_keeps_only_the_visible_rows
    screen = Meringue::Workspace::TerminalScreen.new(rows: 3, columns: 10)

    10.times { |index| screen.feed("line #{index}\r\n") }

    assert_equal ["line 8", "line 9", ""], screen.lines
  end

  def test_carriage_returns_backspace_and_tabs_move_the_cursor
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 20)

    screen.feed("abcdef\rXY")
    assert_equal ["XYcdef"], screen.lines

    screen.feed("\b\bZ")
    assert_equal ["ZYcdef"], screen.lines

    screen.feed("\r\tT")
    assert_equal ["ZYcdef  T"], screen.lines
  end

  def test_erase_and_cursor_addressing_sequences
    screen = Meringue::Workspace::TerminalScreen.new(rows: 3, columns: 10)
    screen.feed("one\r\ntwo\r\nthree")

    screen.feed("\e[2;1H\e[K")
    assert_equal ["one", "", "three"], screen.lines

    screen.feed("\e[3;1Hxyz")
    assert_equal ["one", "", "xyzee"], screen.lines

    screen.feed("\e[2J")
    assert_equal [""], screen.lines
    assert_equal [0, 0], screen.cursor
  end

  def test_alternate_screen_switch_clears_the_screen
    screen = Meringue::Workspace::TerminalScreen.new(rows: 3, columns: 10)
    screen.feed("shell noise")

    screen.feed("\e[?1049h")

    assert_equal [""], screen.lines
  end

  def test_charset_and_reset_sequences_do_not_leak_characters
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 20)

    screen.feed("prompt\e(B\e[m$ ")

    assert_equal ["prompt$"], screen.lines
  end

  def test_operating_system_commands_are_not_screen_content
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 30)

    screen.feed("\e]0;worktree title\aready")

    assert_equal ["ready"], screen.lines
  end

  def test_sgr_styles_are_preserved_and_reset
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 30)

    screen.feed("\e[1;32mgreen\e[0m plain")

    assert_equal [[["green", "\e[1;32m"], [" plain", nil]]], screen.styled_lines
    assert_equal ["green plain"], screen.lines
  end

  def test_styled_trailing_spaces_remain_available_for_highlighted_pi_rows
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 10)
    highlight = "\e[48;5;24m"

    screen.feed("#{highlight}selected  \e[0m")

    assert_equal [[["selected  ", highlight]]], screen.styled_lines
    assert_equal ["selected"], screen.lines
  end

  def test_a_highlighted_blank_row_is_not_dropped_from_the_viewport
    screen = Meringue::Workspace::TerminalScreen.new(rows: 3, columns: 5)
    highlight = "\e[48;5;24m"

    screen.feed("#{highlight}     \e[0m\r\nnext")

    assert_equal [[["     ", highlight]], [["next", nil]]], screen.styled_lines
  end

  def test_styled_lines_can_be_rendered_repeatedly_without_mutating_the_screen
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 20)
    screen.feed("\e[1mbold\e[0m tail")

    first = screen.styled_lines
    second = screen.styled_lines

    assert_equal first, second
    assert_equal ["bold tail"], screen.lines
    first.first.first[0] << "MUTATED"
    assert_equal ["bold tail"], screen.lines
    assert_equal second, screen.styled_lines
  end

  def test_immutable_render_snapshot_is_reused_until_screen_content_changes
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 20)
    screen.feed("cached screen")

    first = screen.render_snapshot
    second = screen.render_snapshot

    assert_same first, second
    assert first.frozen?
    assert first.fetch("lines").frozen?
    assert first.fetch("styled_lines").frozen?

    screen.feed(" changed")
    third = screen.render_snapshot
    refute_same first, third
    assert_operator third.fetch("revision"), :>, first.fetch("revision")
  end

  def test_resize_shrinks_around_the_cursor_and_bumps_the_revision
    screen = Meringue::Workspace::TerminalScreen.new(rows: 4, columns: 10)
    screen.feed("l1\r\nl2\r\nl3\r\nl4")
    revision = screen.revision

    screen.resize(rows: 2, columns: 4)

    assert_equal 2, screen.rows
    assert_equal 4, screen.columns
    assert_equal ["l3", "l4"], screen.lines
    assert_equal [1, 2], screen.cursor
    assert_operator screen.revision, :>, revision
  end

  def test_resize_grows_without_losing_content
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 5)
    screen.feed("aa\r\nbb")

    screen.resize(rows: 5, columns: 20)

    assert_equal 5, screen.rows
    assert_equal 20, screen.columns
    assert_equal ["aa", "bb"], screen.lines
    screen.feed("cc")
    assert_equal ["aa", "bbcc"], screen.lines
  end

  def test_resize_to_the_same_size_is_a_no_op
    screen = Meringue::Workspace::TerminalScreen.new(rows: 3, columns: 10)
    screen.feed("x")
    revision = screen.revision

    screen.resize(rows: 3, columns: 10)

    assert_equal revision, screen.revision
  end

  def test_invalid_dimensions_fall_back_to_defaults
    screen = Meringue::Workspace::TerminalScreen.new(rows: 0, columns: "wide")

    assert_equal Meringue::Workspace::TerminalScreen::DEFAULT_ROWS, screen.rows
    assert_equal Meringue::Workspace::TerminalScreen::DEFAULT_COLUMNS, screen.columns

    screen.resize(rows: nil, columns: -5)

    assert_equal Meringue::Workspace::TerminalScreen::DEFAULT_ROWS, screen.rows
    assert_equal Meringue::Workspace::TerminalScreen::DEFAULT_COLUMNS, screen.columns
  end

  def test_insert_and_delete_sequences_edit_the_current_row
    screen = Meringue::Workspace::TerminalScreen.new(rows: 2, columns: 20)
    screen.feed("abcdef")

    screen.feed("\e[1;3H\e[2P")
    assert_equal ["abef"], screen.lines

    screen.feed("\e[1;3H\e[2@")
    assert_equal ["ab  ef"], screen.lines
  end
end
