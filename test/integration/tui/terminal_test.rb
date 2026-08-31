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

  def test_partial_rows_update_the_next_full_frame_diff_baseline
    output = StringIO.new
    terminal = interactive_terminal(output)
    terminal.write_frame("abc\n123\nxyz")
    output.string.clear

    terminal.write_frame_rows("456", row: 1)

    assert_includes output.string, "\e[2;1H456"
    output.string.clear
    terminal.write_frame("abc\n456\nXYZ")

    refute_includes output.string, "\e[2;1H", "the patched row must not be rewritten"
    assert_includes output.string, "\e[3;1HXYZ"
  end

  def test_streaming_mixed_styled_frames_do_not_clear_at_representative_sizes
    [[64, 18], [100, 32], [160, 40]].each do |width, height|
      output = StringIO.new
      terminal = interactive_terminal(output)
      first = styled_frame(width, height, style: "\e[31m", text: "Claude is streaming")
      second = styled_frame(width, height, style: "\e[1;38;5;196m", text: "Claude produced another chunk")

      terminal.write_frame(first)
      output.string.clear
      terminal.write_frame(second)

      refute_includes output.string, Terminal::CLEAR_SCREEN, "unexpected clear at #{width}x#{height}"
      assert_includes output.string, "\e[1;1H", "streaming output should use a row diff at #{width}x#{height}"
    end
  end

  def test_resize_repaints_when_rows_or_columns_change
    [[80, 24, 100, 24], [100, 32, 100, 40], [160, 40, 120, 30]].each do |width, height, resized_width, resized_height|
      output = StringIO.new
      terminal = interactive_terminal(output)

      terminal.write_frame(rectangle_frame(width, height, "before resize"))
      output.string.clear
      terminal.write_frame(rectangle_frame(resized_width, resized_height, "after resize"))

      assert_equal 1, output.string.scan(Terminal::CLEAR_SCREEN).length,
                   "resize should clear exactly once at #{width}x#{height} -> #{resized_width}x#{resized_height}"
    end
  end

  def test_focus_invalidation_clears_once_without_changing_the_viewport
    output = StringIO.new
    terminal = interactive_terminal(output)
    frame = styled_frame(100, 32, style: "\e[1;34m", text: "focused Claude session")

    terminal.write_frame(frame)
    output.string.clear
    terminal.invalidate_frame!
    terminal.write_frame(frame)

    assert_equal 1, output.string.scan(Terminal::CLEAR_SCREEN).length
  end

  private

  def rectangle_frame(width, height, text)
    line = text.to_s[0, width].to_s.ljust(width)
    Array.new(height, line).join("\n")
  end

  def styled_frame(width, height, style:, text:)
    styled = "#{style}#{text.to_s[0, width].to_s.ljust(width)}\e[0m"
    plain = "#{text} ".to_s[0, width].ljust(width)
    rows = Array.new(height, plain)
    rows[0] = styled
    rows[height / 2] = "\e[3m#{plain}\e[0m"
    rows.join("\n")
  end

  def interactive_terminal(output)
    terminal = Terminal.new(output: output)
    terminal.define_singleton_method(:interactive?) { true }
    terminal
  end
end
