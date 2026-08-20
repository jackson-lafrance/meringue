# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "base64"

# Mouse text selection in the logs (chat) pane: double-click selects a word,
# triple-click selects a displayed paragraph, and continued drags retain that
# word or paragraph granularity. Everything here runs against in-memory layout
# geometry with PATH emptied, so no test touches a real terminal or clipboard.
class TuiMouseWordSelectionTest < Minitest::Test
  include TUISupport

  Selection = Meringue::TUI::Selection
  Clipboard = Meringue::TUI::Clipboard

  WIDTH = Meringue::TUI::App::DEFAULT_WIDTH
  HEIGHT = Meringue::TUI::App::DEFAULT_HEIGHT
  WORKER_ID_PATTERN = /P1-I18-W\d+/

  def setup
    @layout = Meringue::TUI::Layout.new
    @terminal = TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT)
    @app = Meringue::TUI::App.new(layout: @layout, out: StringIO.new, terminal: @terminal)
    @clock = 1_000.0
    clock = -> { @clock }
    @app.define_singleton_method(:monotonic_time) { clock.call }
  end

  def teardown
    Clipboard.reset_command_cache!
  end

  def test_word_range_keeps_ids_paths_and_urls_whole_and_trims_prose_punctuation
    assert_equal "hello", word_at("hello world", 3)
    assert_equal "world", word_at("hello world", 8)
    assert_equal "done", word_at("all done.", 5), "trailing punctuation is not part of the word"
    assert_equal "yes", word_at("yes, no", 1)
    assert_equal "1,000", word_at("1,000 items", 2), "a joiner between word characters stays inside the word"
    assert_equal "P1-I18-W2", word_at("worker P1-I18-W2 finished", 9)
    assert_equal "lib/meringue/tui/app.rb:643", word_at("see lib/meringue/tui/app.rb:643 now", 10)
    assert_equal "https://example.com/pull/12?tab=files", word_at("PR https://example.com/pull/12?tab=files open", 12)
    assert_equal "bar", word_at("foo(bar)", 5), "brackets are their own run, not part of the word"
    assert_equal "((", word_at("((foo", 0), "a punctuation run is selectable on its own"
    assert_equal "tail", word_at("tail", 99), "clicking past the end of a line grabs the last word"
  end

  def test_word_range_has_nothing_to_select_on_blank_columns_and_line_breaks
    assert_nil Selection.word_range("  spaced", 1)
    assert_nil Selection.word_range("", 0)
    assert_nil Selection.word_range("a\nb", 1)
    assert_equal "word", word_at("word", -3), "a column left of the text clamps into the first word"
  end

  def test_double_click_selects_and_copies_the_word_under_the_pointer
    state = logs_state
    target = visible_word(state, WORKER_ID_PATTERN)
    position = logs_click_position(state, target.fetch(:line), target.fetch(:column))

    with_stub_clipboard do
      double_click(state, position)

      expected = Selection.normalize(
        "logs",
        Selection.point(target.fetch(:line), target.fetch(:range).begin),
        Selection.point(target.fetch(:line), target.fetch(:range).end)
      )

      assert_equal expected, @app.send(:logs_selection)
      assert_equal target.fetch(:word), @app.send(:selection_text, state, "")
      assert_equal target.fetch(:word), copied_text
      assert_equal %(copied "#{target.fetch(:word)}"), @app.send(:selection_status_text)
    end
  end

  def test_triple_click_selects_and_copies_the_complete_wrapped_paragraph
    state = paragraph_logs_state
    lines = @layout.logs_text_lines(state, width: WIDTH, height: HEIGHT)
    first_line = lines.index { |line| line.include?("alpha") }
    last_line = lines.index { |line| line.include?("omega") }
    separator = ((last_line + 1)...lines.length).find do |line_index|
      copied_log_lines([lines.fetch(line_index)]).empty?
    end

    refute_nil first_line
    refute_nil last_line
    refute_nil separator
    assert_operator last_line, :>, first_line, "the selected paragraph must span soft-wrapped rows"

    position = logs_click_position(state, last_line, lines.fetch(last_line).index("omega") + 1)
    expected_text = copied_log_lines(lines[first_line...separator])

    with_stub_clipboard do
      triple_click(state, position)

      expected = Selection.normalize(
        "logs",
        Selection.point(first_line, 0),
        Selection.point(last_line, lines.fetch(last_line).length)
      )

      assert_equal expected, @app.send(:logs_selection)
      assert_equal expected_text, @app.send(:selection_text, state, "")
      assert_equal expected_text, copied_text
      refute_includes copied_text, "▌"
      refute_includes copied_text, "second paragraph"
      assert_equal "copied #{last_line - first_line + 1} lines", @app.send(:selection_status_text)
    end
  end

  def test_keyboard_caret_copy_omits_the_agent_gutter_too
    state = composed_state(
      empty_state,
      chat: {
        "messages" => [{
          "role" => "agent",
          "source_id" => "P1-I18-W1",
          "text" => "Copy `this command`.",
          "timestamp" => "2026-07-11T00:00:00Z"
        }]
      }
    )

    with_stub_clipboard do
      assert @app.send(:activate_logs_cursor, state)
      @app.send(:handle_key, "\u0003", "", 0, -1, nil, state)

      assert_equal "Copy `this command`.", copied_text
      refute_includes copied_text, "▌"
    end
  end

  def test_triple_click_drag_extends_the_selection_by_complete_paragraphs
    state = paragraph_logs_state
    lines = @layout.logs_text_lines(state, width: WIDTH, height: HEIGHT)
    first_line = lines.index { |line| line.include?("alpha") }
    first_end = lines.index { |line| line.include?("omega") }
    second_line = lines.index { |line| line.include?("second paragraph") }
    refute_nil first_line
    refute_nil first_end
    refute_nil second_line

    start_position = logs_click_position(state, first_line, lines.fetch(first_line).index("alpha") + 1)
    finish_position = logs_click_position(state, second_line, lines.fetch(second_line).index("second") + 1)

    with_stub_clipboard do
      triple_click(state, start_position, release: false)
      send_mouse(motion_event(finish_position), state)
      send_mouse(release_event(finish_position), state)

      expected_text = copied_log_lines(lines[first_line..second_line])
      selection = @app.send(:logs_selection)

      assert_equal Selection.point(first_line, 0), selection.fetch("start")
      assert_equal Selection.point(second_line, lines.fetch(second_line).length), selection.fetch("end")
      assert_equal expected_text, @app.send(:selection_text, state, "")
      assert_equal expected_text, copied_text
    end
  end

  def test_double_click_resolves_the_word_on_scrolled_back_content
    state = logs_state
    scrolled = logs_state(scroll: { "offsets" => { "logs" => 12 } })
    target = visible_word(state, WORKER_ID_PATTERN)
    position = logs_click_position(state, target.fetch(:line), target.fetch(:column))

    scrolled_point = @layout.logs_text_position(
      scrolled,
      width: WIDTH,
      height: HEIGHT,
      x: position.fetch("x") - 1,
      y: position.fetch("y") - 1
    )

    refute_equal target.fetch(:line), scrolled_point.fetch("line"), "scrolling back moves the content line under the pointer"

    scrolled_line = @layout.logs_text_lines(scrolled, width: WIDTH, height: HEIGHT).fetch(scrolled_point.fetch("line"))
    expected_word = scrolled_line[Selection.word_range(scrolled_line, scrolled_point.fetch("column"))]

    with_stub_clipboard do
      double_click(scrolled, position)

      assert_equal expected_word, @app.send(:selection_text, scrolled, "")
      assert_equal expected_word, copied_text
    end
  end

  def test_double_click_drag_extends_the_selection_by_whole_words_across_wrapped_lines
    state = wrapped_logs_state
    lines = @layout.logs_text_lines(state, width: WIDTH, height: HEIGHT)
    first_row = lines.index { |line| line.include?("alpha") }
    second_row = lines.index { |line| line.include?("omega") }

    refute_nil first_row
    refute_nil second_row
    refute_equal first_row, second_row, "the fixture must wrap onto a second content row"

    start_position = logs_click_position(state, first_row, lines.fetch(first_row).index("alpha") + 2)
    end_position = logs_click_position(state, second_row, lines.fetch(second_row).index("omega") + 2)

    with_stub_clipboard do
      double_click(state, start_position, release: false)
      send_mouse(motion_event(end_position), state)
      send_mouse(release_event(end_position), state)

      text = @app.send(:selection_text, state, "")
      selected_rows = second_row - first_row + 1

      assert_equal selected_rows, text.split("\n", -1).length, "every wrapped row between the two words is selected"
      assert text.start_with?("alpha"), "a word drag starts at the beginning of the anchored word, got #{text.inspect}"
      assert text.end_with?("omega"), "a word drag ends at the end of the word under the pointer, got #{text.inspect}"
      assert_equal text, copied_text
      assert_equal "copied #{selected_rows} lines", @app.send(:selection_status_text)
    end
  end

  def test_a_slow_second_click_falls_back_to_a_character_selection
    state = logs_state
    target = visible_word(state, WORKER_ID_PATTERN)
    position = logs_click_position(state, target.fetch(:line), target.fetch(:column))

    with_stub_clipboard do
      send_mouse(press_event(position), state)
      send_mouse(release_event(position), state)
      @clock += Meringue::TUI::App::DOUBLE_CLICK_INTERVAL_SECONDS + 0.05
      send_mouse(press_event(position), state)
      send_mouse(release_event(position), state)

      assert Selection.empty?(@app.send(:logs_selection)), "a slow second click is a caret, not a word selection"
      assert_equal "", @app.send(:selection_text, state, "")
      assert_nil copied_text
    end
  end

  def test_a_second_click_on_another_row_is_not_a_double_click
    state = logs_state
    target = visible_word(state, WORKER_ID_PATTERN)
    position = logs_click_position(state, target.fetch(:line), target.fetch(:column))
    other_position = position.merge("y" => position.fetch("y") + 1)

    with_stub_clipboard do
      send_mouse(press_event(position), state)
      send_mouse(release_event(position), state)
      send_mouse(press_event(other_position), state)
      send_mouse(release_event(other_position), state)

      assert Selection.empty?(@app.send(:logs_selection))
      assert_nil copied_text
    end
  end

  def test_single_click_drag_still_selects_a_character_range_and_copies_on_release
    state = logs_state
    target = visible_word(state, WORKER_ID_PATTERN)
    line_index = target.fetch(:line)
    column = target.fetch(:column)
    start_position = logs_click_position(state, line_index, column)
    end_position = start_position.merge("x" => start_position.fetch("x") + 4)
    expected = @layout.logs_text_lines(state, width: WIDTH, height: HEIGHT).fetch(line_index)[column, 4]

    with_stub_clipboard do
      send_mouse(press_event(start_position), state)
      send_mouse(motion_event(end_position), state)
      send_mouse(release_event(end_position), state)

      selection = @app.send(:logs_selection)

      assert_equal Selection.point(line_index, column), selection.fetch("start")
      assert_equal Selection.point(line_index, column + 4), selection.fetch("end")
      assert_equal expected, copied_text
    end
  end

  def test_escape_clears_a_mouse_word_selection
    state = logs_state
    target = visible_word(state, WORKER_ID_PATTERN)
    position = logs_click_position(state, target.fetch(:line), target.fetch(:column))

    with_stub_clipboard do
      double_click(state, position)

      refute Selection.empty?(@app.send(:logs_selection))

      @app.send(:handle_key, "\e", "", 0, -1, nil, state)

      assert Selection.empty?(@app.send(:logs_selection))
      assert_equal "", @app.send(:selection_text, state, "")
    end
  end

  def test_clicking_the_agent_tree_clears_the_selection_and_still_selects_the_row
    state = tree_click_state
    target = visible_word(state, WORKER_ID_PATTERN)
    position = logs_click_position(state, target.fetch(:line), target.fetch(:column))
    tree_position = agent_tree_click_position(state, "P1-I1")

    with_stub_clipboard do
      double_click(state, position)

      refute Selection.empty?(@app.send(:logs_selection))

      send_mouse(press_event(tree_position), state)
      send_mouse(release_event(tree_position), state)

      assert Selection.empty?(@app.send(:logs_selection)), "clicking another pane clears the highlight"
      assert_equal "P1-I1", @app.instance_variable_get(:@log_scope_id)
    end
  end

  def test_a_word_selection_survives_new_log_lines_and_a_focus_change
    state = logs_state
    target = visible_word(state, WORKER_ID_PATTERN)
    position = logs_click_position(state, target.fetch(:line), target.fetch(:column))

    with_stub_clipboard do
      double_click(state, position)

      arrived = logs_state
      arrived["logs"] += [log_record("L31", "message" => "a new line arrived while text was selected")]

      assert_equal target.fetch(:word), @app.send(:selection_text, arrived, ""),
                   "content coordinates keep the highlight on the same text when logs append"

      @app.send(:handle_key, "\t", "", 0, -1, nil, arrived)

      refute Selection.empty?(@app.send(:logs_selection)), "changing focus keeps the highlight copyable"
      assert_equal target.fetch(:word), @app.send(:selection_text, arrived, "")
    end
  end

  def test_double_click_in_the_composer_selects_the_word_without_copying
    buffer = "ship P1-I18-W2 now"
    state = composed_state(empty_state, chat: { "input_buffer" => buffer, "input_cursor" => buffer.length })
    position = composer_click_position(state, buffer.index("I18"))

    with_stub_clipboard do
      send_mouse(press_event(position), state, buffer)
      send_mouse(press_event(position), state, buffer)
      send_mouse(release_event(position), state, buffer)

      assert_equal({ "start" => 5, "end" => 14 }, @app.send(:chat_selection_range))
      assert_equal "P1-I18-W2", @app.send(:selection_text, state, buffer)
      assert_nil copied_text, "composer selection stays copy-on-demand so retyping cannot clobber the clipboard"
    end
  end

  def test_a_third_composer_click_preserves_the_existing_single_double_click_cycle
    buffer = "ship P1-I18-W2 now"
    state = composed_state(empty_state, chat: { "input_buffer" => buffer, "input_cursor" => buffer.length })
    position = composer_click_position(state, buffer.index("I18"))

    with_stub_clipboard do
      send_mouse(press_event(position), state, buffer)
      send_mouse(release_event(position), state, buffer)
      send_mouse(press_event(position), state, buffer)
      send_mouse(release_event(position), state, buffer)
      refute_nil @app.send(:chat_selection_range), "the second click still selects a word"

      send_mouse(press_event(position), state, buffer)
      send_mouse(release_event(position), state, buffer)

      assert_nil @app.send(:chat_selection_range), "the composer still starts a fresh caret after its double-click"
      assert_nil copied_text
    end
  end

  def test_mouse_wheel_still_scrolls_the_hovered_logs_pane
    state = logs_state
    target = visible_word(state, WORKER_ID_PATTERN)
    position = logs_click_position(state, target.fetch(:line), target.fetch(:column))

    send_mouse({ "type" => "mouse", "kind" => "wheel_up", "pressed" => true, "button" => 64, "count" => 1 }.merge(position), state)

    assert_operator @app.send(:scroll_snapshot).fetch("offsets").fetch("logs", 0), :>, 0
  end

  private

  def word_at(text, column)
    range = Selection.word_range(text, column)
    range && text[range]
  end

  def logs_state(scroll: nil)
    entries = (1..30).map do |index|
      log_record(
        "L#{index}",
        "message" => "worker P1-I18-W#{index} touched lib/meringue/tui/app.rb:#{index} https://example.com/pull/#{index}"
      )
    end
    composed_state(empty_state.merge("logs" => entries), scroll: scroll)
  end

  def wrapped_logs_state
    message = "alpha #{"filler " * 20}omega"
    composed_state(empty_state.merge("logs" => [log_record("L1", "message" => message)]))
  end

  def paragraph_logs_state
    message = "alpha #{"filler " * 20}omega\n\nsecond paragraph must stay outside the first selection"
    composed_state(
      empty_state,
      chat: {
        "messages" => [{
          "role" => "agent",
          "source_id" => "P1-I18-W1",
          "text" => message,
          "timestamp" => "2026-07-11T00:00:00Z"
        }]
      }
    )
  end

  def tree_click_state
    entries = (1..30).map do |index|
      log_record("L#{index}", "message" => "worker P1-I18-W#{index} touched lib/meringue/tui/app.rb:#{index}")
    end
    state = empty_state.merge(
      "projects" => [project_record("P1")],
      "issues" => [issue_record("P1-I1")],
      "logs" => entries
    )
    composed_state(state)
  end

  def copied_log_lines(lines)
    Array(lines).map { |line| line.delete_prefix("▌ ").delete_prefix("  ") }.join("\n")
  end

  # First on-screen content line matching +pattern+, with a column inside the
  # match, so a click can only be resolved through the pane's real wrapped and
  # scrolled geometry.
  def visible_word(state, pattern)
    lines = @layout.logs_text_lines(state, width: WIDTH, height: HEIGHT)
    window = @layout.logs_visible_window(state, width: WIDTH, height: HEIGHT)
    (window.fetch("start_index")...window.fetch("finish_index")).each do |line_index|
      line = lines.fetch(line_index)
      match = line.match(pattern)
      next unless match

      column = match.begin(0) + 1
      return { line: line_index, column: column, word: match[0], range: Selection.word_range(line, column) }
    end
    flunk "no visible logs line matches #{pattern.inspect}"
  end

  # Screen coordinates (1-based, the way an SGR mouse report arrives) that the
  # layout maps back to a logs content line and column.
  def logs_click_position(state, line_index, column)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        next unless @layout.pane_at(state, width: WIDTH, height: HEIGHT, x: x, y: y) == "logs"

        position = @layout.logs_text_position(state, width: WIDTH, height: HEIGHT, x: x, y: y)
        next unless position

        return { "x" => x + 1, "y" => y + 1 } if position.fetch("line") == line_index && position.fetch("column") == column
      end
    end
    flunk "no screen position maps to logs line #{line_index} column #{column}"
  end

  def composer_click_position(state, index)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        next unless @layout.pane_at(state, width: WIDTH, height: HEIGHT, x: x, y: y) == "chat"
        return { "x" => x + 1, "y" => y + 1 } if @layout.composer_text_index(state, width: WIDTH, height: HEIGHT, x: x, y: y) == index
      end
    end
    flunk "no screen position maps to composer index #{index}"
  end

  def agent_tree_click_position(state, item_id)
    HEIGHT.times do |y|
      WIDTH.times do |x|
        return { "x" => x + 1, "y" => y + 1 } if @layout.agent_tree_item_at(state, width: WIDTH, height: HEIGHT, x: x, y: y) == item_id
      end
    end
    flunk "no screen position maps to agent tree row #{item_id}"
  end

  def double_click(state, position, release: true)
    send_mouse(press_event(position), state)
    send_mouse(release_event(position), state)
    @clock += 0.05
    send_mouse(press_event(position), state)
    send_mouse(release_event(position), state) if release
  end

  def triple_click(state, position, release: true)
    double_click(state, position)
    @clock += 0.05
    send_mouse(press_event(position), state)
    send_mouse(release_event(position), state) if release
  end

  def send_mouse(event, state, buffer = "", cursor = 0)
    @app.send(:handle_key, event, buffer, cursor, -1, nil, state)
  end

  def press_event(position)
    { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0 }.merge(position)
  end

  def release_event(position)
    { "type" => "mouse", "kind" => "button", "pressed" => false, "button" => 0 }.merge(position)
  end

  def motion_event(position)
    { "type" => "mouse", "kind" => "motion", "pressed" => true, "button" => 32 }.merge(position)
  end

  # Clipboard commands are removed from PATH, so a copy falls back to the OSC 52
  # escape written into the fake terminal's in-memory output.
  def with_stub_clipboard
    with_env("PATH" => "") do
      Clipboard.reset_command_cache!
      yield
    end
  ensure
    Clipboard.reset_command_cache!
  end

  def copied_text
    encoded = @terminal.output.string.scan(/\e\]52;c;([^\a]*)\a/).last&.first
    encoded && Base64.strict_decode64(encoded)
  end
end
