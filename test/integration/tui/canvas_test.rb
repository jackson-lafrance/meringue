# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiCanvasTest < Minitest::Test
  include TUISupport

  Canvas = Meringue::TUI::Canvas
  Style = Meringue::TUI::Style
  DisplayWidth = Meringue::TUI::DisplayWidth

  def test_dimensions_never_collapse_below_one_cell
    canvas = Canvas.new(width: 0, height: -4)

    assert_equal 1, canvas.width
    assert_equal 1, canvas.height
    assert_equal " ", canvas.render(color: false)
  end

  def test_fill_character_backs_every_cell
    canvas = Canvas.new(width: 3, height: 2, fill: "·")

    assert_equal "···\n···", canvas.render(color: false)
  end

  def test_write_clips_at_the_right_edge
    canvas = Canvas.new(width: 10, height: 1)
    canvas.write(0, 0, "hello world")

    assert_equal "hello worl", canvas.render(color: false)
  end

  def test_write_clips_negative_columns_without_shifting_text
    canvas = Canvas.new(width: 10, height: 1)
    canvas.write(-3, 0, "abcdefg")

    assert_equal "defg      ", canvas.render(color: false)
  end

  def test_write_respects_max_width_and_sanitizes_control_characters
    canvas = Canvas.new(width: 12, height: 1)
    canvas.write(2, 0, "tab\there\u0007now", max_width: 6)

    assert_equal "  tab he    ", canvas.render(color: false)
  end

  def test_write_off_canvas_rows_is_a_no_op
    canvas = Canvas.new(width: 4, height: 2)
    canvas.write(0, -1, "xxxx")
    canvas.write(0, 5, "yyyy")
    canvas.write(0, 0, "ok", max_width: 0)

    assert_equal "    \n    ", canvas.render(color: false)
  end

  def test_write_segments_clips_the_row_and_keeps_segment_order
    canvas = Canvas.new(width: 8, height: 1)
    canvas.write_segments(0, 0, [["ab", Style::TEXT], ["cdefghij", Style::ERROR]], max_width: 8)

    assert_equal "abcdefgh", canvas.render(color: false)
  end

  def test_render_emits_one_escape_per_style_run_and_resets_at_the_end
    canvas = Canvas.new(width: 8, height: 1)
    canvas.write_segments(0, 0, [["ab", Style::TEXT], ["cdefghij", Style::ERROR]], max_width: 8)
    rendered = canvas.render(color: true)

    assert_equal "#{Style::TEXT}ab#{Style::RESET}#{Style::ERROR}cdefgh#{Style::RESET}", rendered
    assert_equal "abcdefgh", strip_ansi(rendered)
    # style, reset, style, reset — one escape per style run boundary.
    assert_equal 4, rendered.scan(TUISupport::ANSI_PATTERN).length
  end

  def test_render_without_color_contains_no_escape_sequences
    state = composed_state(tui_state)
    frame = render_frame(state, width: 100, height: 32, color: false)

    refute_match TUISupport::ANSI_PATTERN, frame
  end

  def test_render_with_color_keeps_the_same_plain_text_as_the_uncolored_frame
    state = composed_state(tui_state)
    plain = render_frame(state, width: 100, height: 32, color: false)
    colored = render_frame(state, width: 100, height: 32, color: true)

    refute_equal plain, colored
    assert_equal plain, strip_ansi(colored)
  end

  def test_restyle_changes_styles_without_touching_characters
    canvas = Canvas.new(width: 5, height: 1, fill: ".")
    canvas.write(1, 0, "ab")
    canvas.restyle(0, 0, 3, Style::SELECTION)

    assert_equal ".ab..", canvas.render(color: false)
    assert_equal "#{Style::SELECTION}.ab#{Style::RESET}..", canvas.render(color: true)
  end

  def test_restyle_clamps_to_the_canvas_and_ignores_off_canvas_rows
    canvas = Canvas.new(width: 4, height: 1, fill: "x")
    canvas.restyle(2, 0, 99, Style::SELECTION)
    canvas.restyle(0, 9, 2, Style::ERROR)

    assert_equal "xx#{Style::SELECTION}xx#{Style::RESET}", canvas.render(color: true)
  end

  def test_draw_box_renders_rounded_corners_and_clipped_title
    canvas = Canvas.new(width: 6, height: 3)
    canvas.draw_box(0, 0, 6, 3, title: "hi")

    assert_equal ["╭─ h─╮", "│    │", "╰────╯"], canvas.render(color: false).split("\n")
  end

  def test_draw_box_degenerates_safely_at_tiny_sizes
    two_by_two = Canvas.new(width: 2, height: 2)
    two_by_two.draw_box(0, 0, 2, 2, title: "x")

    assert_equal ["╭╮", "╰╯"], two_by_two.render(color: false).split("\n")

    single_row = Canvas.new(width: 5, height: 1)
    single_row.draw_box(0, 0, 5, 1)

    assert_equal "─────", single_row.render(color: false)

    empty = Canvas.new(width: 4, height: 2)
    empty.draw_box(0, 0, 0, 0, title: "nope")

    assert_equal "    \n    ", empty.render(color: false)
  end

  def test_wide_characters_occupy_two_cells_each
    canvas = Canvas.new(width: 8, height: 1, fill: ".")
    canvas.write(0, 0, "日本語")

    assert_equal "日本語..", canvas.render(color: false)
    assert_equal 8, DisplayWidth.width(canvas.render(color: false))
  end

  def test_render_rows_measure_the_canvas_width_in_cells
    canvas = Canvas.new(width: 8, height: 3)
    canvas.write(0, 0, "日本語テスト")
    canvas.write(1, 1, "ok ✅ done 🎉")
    canvas.write_segments(0, 2, [["✅", Style::SUCCESS], [" 한국어", Style::TEXT]], max_width: 8)

    canvas.render(color: false).split("\n").each do |row|
      assert_equal 8, DisplayWidth.width(row), row.inspect
    end
  end

  def test_a_wide_character_straddling_the_right_edge_becomes_a_space
    clipped = Canvas.new(width: 3, height: 1, fill: ".")
    clipped.write(0, 0, "日本語")

    assert_equal "日 ", clipped.render(color: false)

    max_width = Canvas.new(width: 8, height: 1, fill: ".")
    max_width.write(0, 0, "日本語", max_width: 3)

    assert_equal "日 .....", max_width.render(color: false)

    negative = Canvas.new(width: 4, height: 1, fill: ".")
    negative.write(-1, 0, "日本")

    assert_equal " 本.", negative.render(color: false)
  end

  def test_overwriting_half_of_a_wide_character_blanks_the_other_half
    canvas = Canvas.new(width: 6, height: 1, fill: ".")
    canvas.write(0, 0, "日本語")
    canvas.write(1, 0, "ab")

    assert_equal " ab 語", canvas.render(color: false)
    assert_equal 6, DisplayWidth.width(canvas.render(color: false))
  end

  def test_write_segments_advances_the_cursor_by_cells
    canvas = Canvas.new(width: 10, height: 1, fill: ".")
    canvas.write_segments(0, 0, [["日本", Style::TEXT], ["x", Style::ERROR], ["語", Style::TEXT]], max_width: 10)

    assert_equal "日本x語...", canvas.render(color: false)
    assert_equal(
      "#{Style::TEXT}日本#{Style::RESET}#{Style::ERROR}x#{Style::RESET}#{Style::TEXT}語#{Style::RESET}...",
      canvas.render(color: true)
    )
  end

  def test_combining_marks_stay_attached_to_their_base_cell
    canvas = Canvas.new(width: 4, height: 1, fill: ".")
    canvas.write_segments(0, 0, [["e\u0301", Style::TEXT], ["x", Style::ERROR]], max_width: 4)

    assert_equal "e\u0301x..", canvas.render(color: false)
    assert_equal "#{Style::TEXT}e\u0301#{Style::RESET}#{Style::ERROR}x#{Style::RESET}..", canvas.render(color: true)
    assert_equal 4, DisplayWidth.width(canvas.render(color: false))
  end

  def test_restyle_spans_whole_wide_characters
    canvas = Canvas.new(width: 6, height: 1, fill: ".")
    canvas.write(0, 0, "日本")
    canvas.restyle(0, 0, 2, Style::SELECTION)

    assert_equal "#{Style::SELECTION}日#{Style::RESET}本..", canvas.render(color: true)
  end

  def test_emoji_and_box_drawing_characters_survive_a_round_trip
    canvas = Canvas.new(width: 9, height: 1)
    canvas.write_segments(0, 0, [["▌ ", Style::DIM], ["✓ ok 🎉", Style::SUCCESS]], max_width: 9)

    assert_equal "▌ ✓ ok 🎉", strip_ansi(canvas.render(color: true))
  end
end
