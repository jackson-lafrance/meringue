# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/meringue"

class TuiMultilinePromptTest < Minitest::Test
  def test_composer_wraps_long_input_with_cursor_on_last_line
    pane = Meringue::TUI::Panes::ChatPane.new
    state = chat_state("abcdefghij")

    lines = pane.composer_lines(state, width: 8)

    assert_equal "› abcdef", plain_text(lines.fetch(0))
    assert_equal "  ghij_", plain_text(lines.fetch(1))
  end

  def test_layout_expands_composer_to_keep_wrapped_prompt_and_status_visible
    input = "a" * 70
    frame = Meringue::TUI::Layout.new.render(chat_state(input), width: 40, height: 18, color: false)

    assert_includes frame, "› #{"a" * 56}"
    assert_includes frame, "  #{"a" * 14}_"
    assert_includes frame, "head loop idle"
  end

  private

  def chat_state(input_buffer)
    {
      "questions" => [],
      "_chat" => {
        "input_buffer" => input_buffer,
        "pending_count" => 0,
        "messages" => []
      }
    }
  end

  def plain_text(line)
    line.map { |segment| segment.fetch(0).to_s }.join
  end
end
