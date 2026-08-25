# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "timeout"

class TuiChatInputUndoTest < Minitest::Test
  include TUISupport

  CTRL_Z = "\u001a"
  BACKSPACE = "\u007f"
  ENTER = "\r"

  def setup
    @app = build_app(terminal: TUISupport::FakeTerminal.new(width: 100, height: 32))
    @state = empty_state
  end

  def test_ctrl_z_undoes_edits_in_reverse_order
    buffer, cursor = type("abc")

    assert_equal ["ab", 2, -1], send_key(CTRL_Z, buffer, cursor)
    assert_equal ["a", 1, -1], send_key(CTRL_Z, "ab", 2)
    assert_equal ["", 0, -1], send_key(CTRL_Z, "a", 1)
    assert_equal ["", 0, -1], send_key(CTRL_Z, "", 0)
  end

  def test_undo_restores_deleted_text_and_the_prior_cursor
    buffer, = type("hello")

    edited = send_key(BACKSPACE, buffer, 4)
    assert_equal ["helo", 3, -1], edited

    assert_equal ["hello", 4, -1], send_key(CTRL_Z, edited.fetch(0), edited.fetch(1))
  end

  def test_undo_restores_text_replaced_by_a_selection
    buffer, = type("hello")
    @app.send(:update_chat_selection, 1, 4)

    edited = send_key("X", buffer, 4)
    assert_equal ["hXo", 2, -1], edited

    restored = send_key(CTRL_Z, edited.fetch(0), edited.fetch(1))
    assert_equal ["hello", 4, -1], restored
    assert_equal({ "start" => 1, "end" => 4 }, @app.instance_variable_get(:@chat_selection))
  end

  def test_ctrl_z_only_acts_while_chat_is_focused
    buffer, cursor = type("a")
    @app.instance_variable_set(:@focused_pane, "logs")

    assert_equal [buffer, cursor, -1], send_key(CTRL_Z, buffer, cursor)

    @app.instance_variable_set(:@focused_pane, "chat")
    assert_equal ["", 0, -1], send_key(CTRL_Z, buffer, cursor)
  end

  def test_submitting_starts_a_fresh_undo_history
    buffer, cursor = type("send me")
    submitted = Queue.new
    handler = lambda do |text, **|
      submitted << text
      { "summary" => "routed" }
    end

    assert_equal ["", 0, -1], send_key(ENTER, buffer, cursor, on_submit: handler)
    assert_equal "send me", Timeout.timeout(2) { submitted.pop }
    assert_equal ["", 0, -1], send_key(CTRL_Z, "", 0)
  end

  def test_undo_restores_a_live_collapsed_paste
    text = Array.new(40) { |index| "large pasted line #{index}" }.join("\n")
    buffer, cursor, = send_key({ "type" => "paste", "text" => text }, "", 0)
    marker = buffer.dup

    deleted = send_key(BACKSPACE, buffer, cursor)
    assert_equal ["", 0, -1], deleted

    restored = send_key(CTRL_Z, "", 0)
    assert_equal [marker, marker.length, -1], restored

    submitted = Queue.new
    handler = lambda do |value, **|
      submitted << value
      { "summary" => "routed" }
    end
    send_key(ENTER, restored.fetch(0), restored.fetch(1), on_submit: handler)
    assert_equal text, Timeout.timeout(2) { submitted.pop }
  end

  private

  def type(text, buffer: "", cursor: 0)
    text.each_char do |character|
      buffer, cursor, = send_key(character, buffer, cursor)
    end
    [buffer, cursor]
  end

  def send_key(key, buffer, cursor, on_submit: nil)
    state = compose_app_state(@app, @state, buffer, -1, cursor)
    @app.send(:handle_key, key, buffer, cursor, -1, on_submit, state)
  end
end
