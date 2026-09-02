# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "base64"
require "stringio"

# Mouse selection over logs text that contains wide (two-cell) characters. The
# pointer arrives in terminal cells while selections are stored as character
# indexes, so the boundary must map cells back to whole characters: a drag can
# never raise, never copies half of a glyph, and highlights both cells of one.
class TuiWideCharacterSelectionTest < Minitest::Test
  include TUISupport

  Selection = Meringue::TUI::Selection
  Clipboard = Meringue::TUI::Clipboard
  DisplayWidth = Meringue::TUI::DisplayWidth
  Style = Meringue::TUI::Style

  WIDTH = Meringue::TUI::App::DEFAULT_WIDTH
  HEIGHT = Meringue::TUI::App::DEFAULT_HEIGHT
  MESSAGE = "ok 日本語 done ✅ fin"

  def setup
    @layout = Meringue::TUI::Layout.new
    @terminal = TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT)
    @app = Meringue::TUI::App.new(layout: @layout, out: StringIO.new, terminal: @terminal)
  end

  def teardown
    Clipboard.reset_command_cache!
  end

  def test_a_click_maps_terminal_cells_back_to_character_columns
    state = logs_state
    line_index, line = wide_line(state)
    origin = logs_origin(state, line_index)
    text_start = line.index("日")

    # Cell offsets of 日 (two cells), 本, and 語 along the rendered row.
    cell_of_first = DisplayWidth.width(line[0, text_start])
    first_half = @layout.logs_text_position(state, width: WIDTH, height: HEIGHT, x: origin.fetch(:x) + cell_of_first, y: origin.fetch(:y))
    second_half = @layout.logs_text_position(state, width: WIDTH, height: HEIGHT, x: origin.fetch(:x) + cell_of_first + 1, y: origin.fetch(:y))
    next_glyph = @layout.logs_text_position(state, width: WIDTH, height: HEIGHT, x: origin.fetch(:x) + cell_of_first + 2, y: origin.fetch(:y))

    assert_equal text_start, first_half.fetch("column")
    assert_equal text_start, second_half.fetch("column"), "either half of a wide glyph resolves to that glyph"
    assert_equal text_start + 1, next_glyph.fetch("column")
  end

  def test_dragging_across_wide_characters_copies_whole_glyphs_and_highlights_their_cells
    state = logs_state
    line_index, line = wide_line(state)
    origin = logs_origin(state, line_index)
    start_cell = DisplayWidth.width(line[0, line.index("日")])
    # Release inside 語's second cell: the selection must still end on a whole character.
    finish_cell = DisplayWidth.width(line[0, line.index("語") + 1]) - 1

    with_stub_clipboard do
      send_mouse(press_event(origin.fetch(:x) + start_cell, origin.fetch(:y)), state)
      send_mouse(motion_event(origin.fetch(:x) + finish_cell, origin.fetch(:y)), state)
      send_mouse(release_event(origin.fetch(:x) + finish_cell, origin.fetch(:y)), state)

      copied = @app.send(:selection_text, state, "")
      assert_equal "日本", copied
      assert copied.valid_encoding?

      @app.send(:copy_selection, state, "")
      assert_equal "日本", copied_text
    end

    frame = render_with_selection(state)
    row = strip_ansi(frame.fetch(origin.fetch(:y)))
    assert_equal WIDTH, DisplayWidth.width(row)
    highlighted = frame.fetch(origin.fetch(:y))[/#{Regexp.escape(Style::SELECTION)}(.*?)#{Regexp.escape(Style::RESET)}/, 1]
    assert_equal "日本", highlighted, "the highlight covers both cells of each selected wide glyph"
  end

  def test_double_clicking_a_wide_word_selects_it_whole
    state = logs_state
    line_index, line = wide_line(state)
    origin = logs_origin(state, line_index)
    cell = DisplayWidth.width(line[0, line.index("本")])

    with_stub_clipboard do
      send_mouse(press_event(origin.fetch(:x) + cell, origin.fetch(:y)), state)
      send_mouse(release_event(origin.fetch(:x) + cell, origin.fetch(:y)), state)
      send_mouse(press_event(origin.fetch(:x) + cell, origin.fetch(:y)), state)
      send_mouse(release_event(origin.fetch(:x) + cell, origin.fetch(:y)), state)

      assert_equal "日本語", @app.send(:selection_text, state, "")
    end
  end

  def test_keyboard_caret_on_a_wide_character_restyles_its_first_cell
    state = logs_state
    line_index, line = wide_line(state)
    origin = logs_origin(state, line_index)
    column = line.index("本")

    @app.instance_variable_set(:@focused_pane, "logs")
    @app.send(:activate_logs_cursor, state)
    @app.instance_variable_set(:@logs_selection_focus, Selection.point(line_index, column))
    @app.instance_variable_set(:@logs_selection_anchor, Selection.point(line_index, column))

    frame = render_with_selection(state)
    row = frame.fetch(origin.fetch(:y))
    assert_equal WIDTH, DisplayWidth.width(strip_ansi(row))
    caret = row[/#{Regexp.escape(Style.selection_cursor)}(.*?)#{Regexp.escape(Style::RESET)}/, 1]
    assert_equal "本", caret
  end

  def test_a_click_in_a_composer_with_wide_text_does_not_raise
    buffer = "日本語 ✅ done"
    state = composed_state(empty_state, chat: { "input_buffer" => buffer, "input_cursor" => buffer.length })
    positions = []
    HEIGHT.times do |y|
      WIDTH.times do |x|
        next unless @layout.pane_at(state, width: WIDTH, height: HEIGHT, x: x, y: y) == "chat"

        index = @layout.composer_text_index(state, width: WIDTH, height: HEIGHT, x: x, y: y)
        positions << index if index
      end
    end

    refute_empty positions
    positions.each { |index| assert index.between?(0, buffer.length), "index #{index} must stay inside the buffer" }
  end

  private

  def logs_state
    entries = (1..3).map { |index| log_record("L#{index}", "message" => "plain line #{index}") }
    entries << log_record("L4", "message" => MESSAGE)
    composed_state(empty_state.merge("logs" => entries))
  end

  def wide_line(state)
    lines = @layout.logs_text_lines(state, width: WIDTH, height: HEIGHT)
    index = lines.index { |line| line.include?("日本語") }
    refute_nil index, "the wide log line should be rendered"
    [index, lines.fetch(index)]
  end

  # Zero-based screen coordinates of the first text cell on a logs content line:
  # the cell whose right-hand neighbour resolves to character column 1. Cells
  # left of the text (border, padding) all clamp to column 0.
  def logs_origin(state, line_index)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        next unless @layout.pane_at(state, width: WIDTH, height: HEIGHT, x: x, y: y) == "logs"

        position = @layout.logs_text_position(state, width: WIDTH, height: HEIGHT, x: x, y: y)
        next unless position && position.fetch("line") == line_index && position.fetch("column").zero?

        neighbour = @layout.logs_text_position(state, width: WIDTH, height: HEIGHT, x: x + 1, y: y)
        return { x: x, y: y } if neighbour.fetch("column") == 1
      end
    end
    flunk "no screen position maps to logs line #{line_index}"
  end

  def render_with_selection(state)
    composed = state.merge("_selection" => @app.send(:selection_snapshot))
    @layout.render(composed, width: WIDTH, height: HEIGHT, color: true).split("\n", -1)
  end

  def send_mouse(event, state)
    @app.send(:handle_key, event, "", 0, -1, nil, state)
  end

  # SGR mouse reports are one-based.
  def press_event(x, y)
    { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0, "x" => x + 1, "y" => y + 1 }
  end

  def release_event(x, y)
    { "type" => "mouse", "kind" => "button", "pressed" => false, "button" => 0, "x" => x + 1, "y" => y + 1 }
  end

  def motion_event(x, y)
    { "type" => "mouse", "kind" => "motion", "pressed" => true, "button" => 32, "x" => x + 1, "y" => y + 1 }
  end

  def with_stub_clipboard
    previous = ENV["PATH"]
    ENV["PATH"] = ""
    Clipboard.reset_command_cache!
    yield
  ensure
    ENV["PATH"] = previous
    Clipboard.reset_command_cache!
  end

  def copied_text
    encoded = @terminal.output.string.scan(/\e\]52;c;([^\a]*)\a/).last&.first
    encoded && Base64.strict_decode64(encoded).force_encoding(Encoding::UTF_8)
  end
end
