# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "timeout"
require "stringio"

# A large paste must never reach the composer buffer: it collapses to a compact
# marker, every per-keystroke pass runs over that marker, and the full body is
# spliced back in only when the message is submitted.
class TuiLargePasteCollapseTest < Minitest::Test
  include TUISupport

  PasteRegistry = Meringue::TUI::PasteRegistry
  BACKSPACE = "\u007f"
  LEFT = "\e[D"
  RIGHT = "\e[C"
  DELETE = "\e[3~"
  ENTER = "\r"
  CTRL_V = "\u0016"
  WIDTH = 140
  HEIGHT = 45

  def setup
    @app = build_app(terminal: TUISupport::FakeTerminal.new(width: WIDTH, height: HEIGHT))
    @app.instance_variable_set(:@last_render_width, WIDTH)
    @app.instance_variable_set(:@last_render_height, HEIGHT)
    @state = composed_state(empty_state)
  end

  def test_a_multi_thousand_line_paste_collapses_to_one_marker
    text = pasted_lines(3_000)

    buffer, cursor, slash_index = paste(text)

    assert_equal "[paste #1 +3000 lines]", buffer
    assert_equal buffer.length, cursor
    assert_equal(-1, slash_index)
    refute_includes buffer, "line 2999"
  end

  def test_a_long_single_line_paste_reports_characters_like_pi_does
    text = "x" * 4_110

    buffer, = paste(text)

    assert_equal "[paste #1 4110 chars]", buffer
  end

  def test_small_pastes_are_still_inserted_verbatim
    small = "just a short paste"
    few_lines = Array.new(10) { |index| "line #{index}" }.join("\n")

    assert_equal ["hi #{small}", "hi #{small}".length, -1], paste(small, buffer: "hi ", cursor: 3)
    assert_equal few_lines, paste(few_lines).first
    assert_equal "a" * 1_000, paste("a" * 1_000).first
  end

  def test_the_plain_text_paste_path_collapses_the_same_way
    # Terminals without bracketed paste deliver a paste as one long key string.
    buffer, = @app.send(:handle_key, pasted_lines(2_000), "", 0, -1, nil, @state)

    assert_equal "[paste #1 +2000 lines]", buffer
  end

  def test_the_clipboard_keybinding_path_collapses_the_same_way
    with_clipboard_text(pasted_lines(1_500)) do
      buffer, = @app.send(:handle_key, CTRL_V, "", 0, -1, nil, @state)

      assert_equal "[paste #1 +1500 lines]", buffer
    end
  end

  def test_submitting_expands_the_marker_back_to_the_full_paste
    text = pasted_lines(3_000)
    buffer, cursor = paste(text)
    buffer, cursor = type(" please review this", buffer, cursor)

    submitted = submit(buffer, cursor)

    assert_equal "#{text} please review this", submitted
    assert_equal 3_000, submitted.split("\n").length
    assert_equal text.length + " please review this".length, submitted.length
  end

  def test_multiple_large_pastes_each_get_a_marker_and_all_round_trip
    first = pasted_lines(2_000, prefix: "first")
    second = pasted_lines(1_200, prefix: "second")

    buffer, cursor = paste(first)
    buffer, cursor = type(" and ", buffer, cursor)
    buffer, cursor = paste(second, buffer: buffer, cursor: cursor)

    assert_equal "[paste #1 +2000 lines] and [paste #2 +1200 lines]", buffer

    assert_equal "#{first} and #{second}", submit(buffer, cursor)
  end

  def test_a_small_paste_between_two_large_ones_stays_inline
    buffer, cursor = paste(pasted_lines(50))
    buffer, cursor = paste(" inline ", buffer: buffer, cursor: cursor)
    buffer, cursor = paste(pasted_lines(60), buffer: buffer, cursor: cursor)

    assert_equal "[paste #1 +50 lines] inline [paste #2 +60 lines]", buffer
  end

  def test_backspace_deletes_the_whole_marker_and_forgets_its_content
    buffer, cursor = paste(pasted_lines(3_000))
    buffer, cursor = type("!", buffer, cursor)

    buffer, cursor, = @app.send(:handle_key, BACKSPACE, buffer, cursor, -1, nil, @state)
    assert_equal "[paste #1 +3000 lines]", buffer

    buffer, cursor, = @app.send(:handle_key, BACKSPACE, buffer, cursor, -1, nil, @state)
    assert_equal "", buffer
    assert_equal 0, cursor

    buffer, cursor = type("no paste here", buffer, cursor)
    assert_equal "no paste here", submit(buffer, cursor)
  end

  def test_forward_delete_from_the_marker_start_removes_it_whole
    buffer, = paste(pasted_lines(40))

    buffer, cursor, = @app.send(:handle_key, DELETE, buffer, 0, -1, nil, @state)

    assert_equal "", buffer
    assert_equal 0, cursor
  end

  def test_word_deletion_never_leaves_half_a_marker
    buffer, cursor = paste(pasted_lines(40))

    buffer, = @app.send(:handle_key, "\u0017", buffer, cursor, -1, nil, @state)

    refute_includes buffer, "paste #"
    assert_equal "", buffer
  end

  def test_the_cursor_steps_over_a_marker_as_one_unit
    buffer, cursor = paste(pasted_lines(40))
    buffer, cursor = type(" tail", buffer, cursor)
    marker_length = "[paste #1 +40 lines]".length

    # Left from just after the marker lands on its start, not inside it.
    _, at_marker_end, = @app.send(:handle_key, LEFT, buffer, marker_length, -1, nil, @state)
    assert_equal 0, at_marker_end

    _, at_marker_start, = @app.send(:handle_key, RIGHT, buffer, 0, -1, nil, @state)
    assert_equal marker_length, at_marker_start

    assert_equal "#{pasted_lines(40)} tail", submit(buffer, cursor)
  end

  def test_clearing_the_composer_with_ctrl_c_drops_the_stored_paste
    buffer, cursor = paste(pasted_lines(3_000))

    buffer, cursor, = @app.send(:handle_key, "\u0003", buffer, cursor, -1, nil, @state)
    assert_equal "", buffer

    buffer, cursor = type("[paste #1 +3000 lines]", buffer, cursor)
    assert_equal "[paste #1 +3000 lines]", submit(buffer, cursor),
                 "a stale marker must never expand into content the user already cleared"
  end

  def test_copying_a_selected_marker_yields_the_pasted_content
    text = pasted_lines(40)
    buffer, cursor = paste(text)
    @app.send(:update_chat_selection, 0, cursor)
    @app.instance_variable_set(:@selection_pane, "chat")

    assert_equal text, @app.send(:selection_text, @state, buffer)
  end

  def test_the_composer_renders_one_row_for_a_three_thousand_line_paste
    buffer, cursor = paste(pasted_lines(3_000))
    state = compose_app_state(@app, -> { empty_state }, buffer, -1, cursor)
    pane = Meringue::TUI::Panes::ChatPane.new

    lines = pane.composer_lines(state, width: WIDTH - 4)

    assert_equal 1, lines.length
    assert_includes plain_line(lines.first), "[paste #1 +3000 lines]"
    assert_includes strip_ansi(@app.render(state, width: WIDTH, height: HEIGHT, color: true)), "[paste #1 +3000 lines]"
  end

  # The point of the placeholder is that no later frame pays for the pasted
  # body. The bound is deliberately loose: before the collapse a single frame
  # with this buffer took ~270ms, and every keystroke paid it again.
  def test_typing_after_a_huge_paste_stays_as_cheap_as_typing_without_one
    provider = -> { empty_state }
    buffer, cursor = paste(pasted_lines(3_000))

    frames = 10.times.map do
      measure do
        buffer, cursor, = @app.send(:handle_key, "x", buffer, cursor, -1, nil, @state)
        @app.render(compose_app_state(@app, provider, buffer, -1, cursor), width: WIDTH, height: HEIGHT, color: true)
      end
    end
    average = frames.sum / frames.length

    assert_operator average, :<, 0.05, format("average keystroke frame was %.1f ms", average * 1_000)
    assert_operator frames.max, :<, 0.2, format("slowest keystroke frame was %.1f ms", frames.max * 1_000)
  end

  def test_the_focused_workspace_composer_collapses_and_expands_too
    text = pasted_lines(3_000)
    session = RecordingWorkspaceSession.new
    @app.instance_variable_set(:@agent_workspace_active, true)
    @app.instance_variable_set(:@agent_workspace_agent_id, "P1-I1-W1")
    @app.instance_variable_set(:@agent_workspace_session, session)

    buffer, cursor, = @app.send(:handle_key, { "type" => "paste", "text" => text }, "", 0, -1, nil, @state)
    assert_equal "[paste #1 +3000 lines]", buffer

    assert_equal ["", 0, -1], @app.send(:handle_key, ENTER, buffer, cursor, -1, nil, @state)
    assert_equal text, Timeout.timeout(5) { session.prompts.pop }
  end

  def test_a_restored_draft_drops_markers_whose_content_is_gone
    state = empty_state
    state["agents"] << agent_record("P1-I1-W1")
    state["ui"] = { "agent_workspace" => { "selected_agent_id" => "P1-I1-W1", "draft" => "check [paste #1 +3000 lines] please" } }
    @app.restore_agent_workspace!(state)

    assert_equal "check  please", @app.instance_variable_get(:@workspace_draft)
  end

  def test_the_registry_forgets_content_once_its_marker_leaves_the_buffer
    registry = PasteRegistry.new
    marker = registry.collapse(pasted_lines(40))

    assert_equal 1, registry.size
    registry.sync!("nothing here")
    assert_equal 0, registry.size
    assert_equal marker, registry.expand(marker), "a forgotten marker stays literal instead of inventing content"
  end

  def test_registry_thresholds_match_pi
    registry = PasteRegistry.new

    refute registry.large?("a" * PasteRegistry::CHARACTER_THRESHOLD)
    assert registry.large?("a" * (PasteRegistry::CHARACTER_THRESHOLD + 1))
    refute registry.large?(Array.new(PasteRegistry::LINE_THRESHOLD) { "x" }.join("\n"))
    assert registry.large?(Array.new(PasteRegistry::LINE_THRESHOLD + 1) { "x" }.join("\n"))
    refute registry.large?("")
  end

  private

  class RecordingWorkspaceSession
    attr_reader :prompts

    def initialize
      @prompts = Queue.new
    end

    def submit(text, mode: nil)
      _ = mode
      @prompts << text
      { "status" => "accepted" }
    end
  end

  def pasted_lines(count, prefix: "line")
    Array.new(count) { |index| "#{prefix} #{index} of pasted content that is long enough to wrap in the composer" }.join("\n")
  end

  def paste(text, buffer: "", cursor: 0)
    @app.send(:handle_key, { "type" => "paste", "text" => text }, buffer, cursor, -1, nil, @state)
  end

  def type(text, buffer, cursor)
    text.each_char do |character|
      buffer, cursor, = @app.send(:handle_key, character, buffer, cursor, -1, nil, @state)
    end
    [buffer, cursor]
  end

  def submit(buffer, cursor)
    submitted = Queue.new
    handler = lambda do |text, **|
      submitted << text
      { "summary" => "routed" }
    end

    assert_equal ["", 0, -1], @app.send(:handle_key, ENTER, buffer, cursor, -1, handler, @state)
    Timeout.timeout(5) { submitted.pop }
  end

  def with_clipboard_text(text)
    Meringue::TUI::Clipboard.singleton_class.send(:alias_method, :paste_without_stub, :paste)
    Meringue::TUI::Clipboard.define_singleton_method(:paste) { text }
    yield
  ensure
    Meringue::TUI::Clipboard.define_singleton_method(:paste, Meringue::TUI::Clipboard.method(:paste_without_stub).unbind)
    Meringue::TUI::Clipboard.singleton_class.send(:remove_method, :paste_without_stub)
  end

  def measure
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
end
