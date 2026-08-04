# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "stringio"

class TuiTerminalTest < Minitest::Test
  Terminal = Meringue::TUI::Terminal

  def test_resize_repaints_when_only_the_frame_width_changes
    output = StringIO.new
    terminal = interactive_terminal(output)

    terminal.write_frame("abc\n123")
    output.string.clear
    terminal.write_frame("ab\n45")

    assert_equal 1, output.string.scan(Terminal::CLEAR_SCREEN).length
  end

  def test_same_size_frames_keep_using_row_diffs
    output = StringIO.new
    terminal = interactive_terminal(output)

    terminal.write_frame("abc\n123")
    output.string.clear
    terminal.write_frame("xyz\n456")

    refute_includes output.string, Terminal::CLEAR_SCREEN
    assert_includes output.string, "\e[1;1H"
  end

  private

  def interactive_terminal(output)
    terminal = Terminal.new(output: output)
    terminal.define_singleton_method(:interactive?) { true }
    terminal
  end
end
