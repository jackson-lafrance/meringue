# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Every rendered frame row must occupy exactly the terminal width in cells, not
# in codepoints. A CJK issue title or an emoji in a log line used to add cells
# the canvas did not count, so the terminal wrapped that row and displaced every
# box border below it.
class TuiLayoutDisplayWidthTest < Minitest::Test
  include TUISupport

  DisplayWidth = Meringue::TUI::DisplayWidth

  WIDE_TITLE = "日本語のタイトルを修正する ✅"
  WIDE_MESSAGE = "ログ: 作業を開始しました 😀🎉 한국어 ✅ 👨‍👩‍👧‍👦 done"
  WIDE_INPUT = "日本語の入力 ✅ résumé e\u0301"
  LONG_WIDE_TITLE = "日本語のタイトルが長くて二行に折り返される課題"
  LONG_WIDE_MESSAGE = "ログの本文も日本語で長く書いて折り返しが発生するようにしています。すべての文字が残ること。"

  def test_every_frame_row_is_exactly_the_terminal_width_in_cells
    state = wide_state

    [40, 80, 120].each do |width|
      [false, true].each do |color|
        frame = render_frame(state, width: width, height: 24, color: color)
        rows = frame.split("\n", -1)

        assert_equal 24, rows.length
        rows.each_with_index do |row, index|
          plain = strip_ansi(row)
          assert_equal width, DisplayWidth.width(plain), "width #{width} color=#{color} row #{index}: #{plain.inspect}"
        end
      end
    end
  end

  def test_wide_content_still_reaches_the_frame
    frame = render_frame(wide_state, width: 120, height: 24, color: false)

    assert_includes frame, "日本語"
    assert_includes frame, "✅"
  end

  # Wrapping used to budget rows by codepoint, so a CJK title or log line was
  # handed to the canvas at twice the pane width and the clip dropped its tail.
  def test_long_cjk_titles_and_log_messages_wrap_without_losing_characters
    state = tui_state
    state["issues"].each { |issue| issue["title"] = LONG_WIDE_TITLE }
    state["logs"].each { |log| log["message"] = LONG_WIDE_MESSAGE }

    [100, 120].each do |width|
      rows = render_lines(composed_state(state), width: width, height: 30, color: false)
      plain = rows.join("\n")
      rows.each { |row| assert_equal width, DisplayWidth.width(row), "width #{width}: #{row.inspect}" }
      refute_includes plain, "…", "width #{width}: this title fits its rows and must not be ellipsized"
      (LONG_WIDE_TITLE.chars + LONG_WIDE_MESSAGE.chars).uniq.each do |char|
        assert_includes plain, char, "width #{width} lost #{char.inspect}"
      end
      # Column 1 of a dashboard row is the agent tree and column 3 the logs; each
      # wrapped text must read back whole and in order down its own pane.
      columns = rows.map { |row| row.split("│") }.select { |parts| parts.length >= 4 }
      assert_includes columns.map { |parts| parts[1] }.join.delete(" "), LONG_WIDE_TITLE, "width #{width}"
      assert_includes columns.map { |parts| parts[3] }.join.delete(" ").delete("▌"), LONG_WIDE_MESSAGE, "width #{width}"
    end
  end

  private

  def wide_state
    state = tui_state
    state["issues"].each { |issue| issue["title"] = WIDE_TITLE }
    state["logs"].each { |log| log["message"] = WIDE_MESSAGE }
    composed_state(
      state,
      chat: {
        "input_buffer" => WIDE_INPUT,
        "input_cursor" => 4,
        "messages" => [
          { "role" => "user", "text" => WIDE_INPUT, "timestamp" => "2026-07-11T00:00:00Z" },
          { "role" => "agent", "source_id" => "P1-I1-W1", "text" => WIDE_MESSAGE, "timestamp" => "2026-07-11T00:00:01Z" }
        ]
      }
    )
  end
end
