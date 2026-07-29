# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiLayoutTest < Minitest::Test
  include TUISupport

  Layout = Meringue::TUI::Layout

  def setup
    @layout = Layout.new
    @state = composed_state(demo_state)
  end

  def test_three_panes_render_at_the_default_size
    frame = @layout.render(@state, width: 100, height: 32)

    assert_includes frame, "─ agent tree ─"
    assert_includes frame, "─ logs ─"
    assert_includes frame, "─ chat ─"
  end

  def test_frame_is_exactly_the_requested_rectangle_at_many_sizes
    [[64, 18], [80, 24], [100, 32], [120, 40], [200, 60], [300, 20]].each do |width, height|
      lines = @layout.render(@state, width: width, height: height).split("\n", -1)

      assert_equal height, lines.length, "row count at #{width}x#{height}"
      assert_equal [width], lines.map(&:length).uniq, "row widths at #{width}x#{height}"
    end
  end

  def test_dimensions_below_the_minimum_are_clamped_instead_of_crashing
    [[1, 1], [0, 0], [-5, -5], [10, 4], [63, 17]].each do |width, height|
      lines = @layout.render(@state, width: width, height: height).split("\n", -1)

      assert_equal Layout::MIN_HEIGHT, lines.length, "clamped rows at #{width}x#{height}"
      assert_equal [Layout::MIN_WIDTH], lines.map(&:length).uniq, "clamped widths at #{width}x#{height}"
    end
  end

  def test_all_three_panes_survive_the_minimum_size
    frame = @layout.render(@state, width: Layout::MIN_WIDTH, height: Layout::MIN_HEIGHT)

    assert_includes frame, "─ agent tree ─"
    assert_includes frame, "─ logs ─"
    assert_includes frame, "─ chat ─"
    assert_includes frame, "Enter send"
  end

  def test_sidebar_width_stays_inside_its_configured_bounds_across_resizes
    (Layout::MIN_WIDTH..240).step(7) do |width|
      lines = @layout.render(@state, width: width, height: 30).split("\n", -1)
      sidebar_line = lines.first

      sidebar_width = sidebar_line.index("╮") - sidebar_line.index("╭") + 1
      assert_operator sidebar_width, :>=, Layout::SIDEBAR_MIN_WIDTH
      assert_operator sidebar_width, :<=, Layout::SIDEBAR_MAX_WIDTH
    end
  end

  def test_resizing_reflows_content_instead_of_truncating_the_frame
    narrow = @layout.render(@state, width: 70, height: 24)
    wide = @layout.render(@state, width: 160, height: 24)

    refute_equal narrow, wide
    assert_equal [70], narrow.split("\n", -1).map(&:length).uniq
    assert_equal [160], wide.split("\n", -1).map(&:length).uniq
    assert_includes wide, "Question Q1"
  end

  def test_empty_state_renders_placeholder_content_in_every_pane
    frame = @layout.render(composed_state(empty_state), width: 90, height: 26)

    assert_includes frame, "No AgentTree data yet."
    assert_includes frame, "No logs yet."
    assert_includes frame, "enter a prompt"
  end

  def test_composer_grows_with_multiline_input_and_stays_bounded
    assert_equal 3, composer_height(@layout.render(state_with_input(""), width: 100, height: 32))
    assert_equal 3, composer_height(@layout.render(state_with_input("one line"), width: 100, height: 32))
    assert_equal 6, composer_height(@layout.render(state_with_input("a\nb\nc\nd"), width: 100, height: 32))

    tall = composer_height(@layout.render(state_with_input((["x"] * 40).join("\n")), width: 100, height: 32))
    assert_operator tall, :<=, Layout::MAX_COMPOSER_HEIGHT
    assert_operator tall, :<=, 32 / 3
    assert_operator tall, :>, 3
  end

  def test_slash_suggestion_pane_appears_above_the_composer
    frame = @layout.render(state_with_input("/"), width: 100, height: 32)

    assert_includes frame, "─ slash commands ─"
    lines = frame.split("\n", -1)
    assert_operator lines.index { |line| line.include?("─ slash commands ─") }, :<,
                    lines.index { |line| line.include?("─ chat ─") }
  end

  def test_slash_suggestion_pane_collapses_when_there_is_no_vertical_room
    frame = @layout.render(state_with_input("/"), width: 100, height: Layout::MIN_HEIGHT)

    assert_includes frame, "─ chat ─"
    assert_equal Layout::MIN_HEIGHT, frame.split("\n", -1).length
  end

  def test_pane_at_maps_coordinates_to_focusable_panes
    assert_equal "agent_tree", @layout.pane_at(@state, width: 100, height: 32, x: 5, y: 3)
    assert_equal "logs", @layout.pane_at(@state, width: 100, height: 32, x: 50, y: 3)
    assert_equal "chat", @layout.pane_at(@state, width: 100, height: 32, x: 50, y: 29)
    assert_nil @layout.pane_at(@state, width: 100, height: 32, x: 0, y: 31)
  end

  def test_scroll_limits_are_non_negative_and_zero_for_the_chat_pane
    limits = @layout.scroll_limits(@state, width: 100, height: 32)

    assert_equal %w[agent_tree chat logs], limits.keys.sort
    assert_equal 0, limits.fetch("chat")
    assert limits.values.all? { |value| value >= 0 }

    roomy = @layout.scroll_limits(@state, width: 200, height: 90)
    assert_equal 0, roomy.fetch("agent_tree")
    assert_equal 0, roomy.fetch("logs")
  end

  def test_agent_tree_item_at_returns_the_clicked_record_id
    assert_equal "H1", @layout.agent_tree_item_at(@state, width: 100, height: 32, x: 5, y: 3)
    assert_equal "P1-I1", @layout.agent_tree_item_at(@state, width: 100, height: 32, x: 5, y: 9)
    assert_nil @layout.agent_tree_item_at(@state, width: 100, height: 32, x: 50, y: 3)
    assert_equal @layout.agent_tree_item_at(@state, width: 100, height: 32, x: 5, y: 3),
                 @layout.agent_tree_worker_at(@state, width: 100, height: 32, x: 5, y: 3)
  end

  def test_logs_selection_is_reported_in_content_coordinates_and_extracted_as_text
    start_point = @layout.logs_text_position(@state, width: 100, height: 32, x: 40, y: 3)
    end_point = @layout.logs_text_position(@state, width: 100, height: 32, x: 60, y: 5)

    assert_operator start_point.fetch("line"), :<, end_point.fetch("line")

    selection = Meringue::TUI::Selection.normalize("logs", start_point, end_point)
    text = @layout.logs_selection_text(@state, width: 100, height: 32, selection: selection)

    assert_equal 3, text.split("\n", -1).length
    refute_empty text.strip
  end

  def test_selection_highlight_only_restyles_already_drawn_logs_cells
    start_point = @layout.logs_text_position(@state, width: 100, height: 32, x: 40, y: 3)
    end_point = @layout.logs_text_position(@state, width: 100, height: 32, x: 60, y: 5)
    selection = Meringue::TUI::Selection.normalize("logs", start_point, end_point)
    highlighted = @state.merge("_selection" => selection)

    colored = @layout.render(highlighted, width: 100, height: 32, color: true)
    plain = @layout.render(highlighted, width: 100, height: 32, color: false)

    assert_includes colored, Meringue::TUI::Style::SELECTION
    assert_equal @layout.render(@state, width: 100, height: 32, color: false), plain
  end

  def test_composer_click_maps_back_to_a_buffer_index
    state = state_with_input("hello there")
    index = @layout.composer_text_index(state, width: 100, height: 32, x: 6, y: 29)

    assert_kind_of Integer, index
    assert index.between?(0, "hello there".length)
  end

  def test_active_agent_workspace_replaces_the_dashboard
    workspace_state = composed_state(
      demo_state,
      workspace: {
        "active" => true,
        "agent_id" => "P1-I1-W1",
        "view" => "agent",
        "filter" => "all",
        "input_buffer" => "",
        "input_cursor" => 0,
        "messages" => []
      }
    )
    frame = @layout.render(workspace_state, width: 100, height: 20)

    refute_includes frame, "─ agent tree ─"
    refute_includes frame, "─ logs ─"
    assert_includes frame, "focused worker · P1-I1-W1"
    assert_includes frame, "─ chat ─"
    assert_equal "agent_workspace", @layout.pane_at(workspace_state, width: 100, height: 20, x: 5, y: 3)
    assert_equal({ "agent_tree" => 0, "logs" => 0, "chat" => 0 },
                 @layout.scroll_limits(workspace_state, width: 100, height: 20))
    assert_operator @layout.agent_workspace_scroll_max(workspace_state, width: 100, height: 20), :>=, 0
  end

  def test_rendering_is_deterministic_for_the_same_state
    first = @layout.render(@state, width: 111, height: 29, color: true)
    second = @layout.render(@state, width: 111, height: 29, color: true)

    assert_equal first, second
  end

  private

  def state_with_input(buffer)
    composed_state(demo_state, chat: { "input_buffer" => buffer, "input_cursor" => buffer.length })
  end

  def composer_height(frame)
    lines = frame.split("\n", -1)
    start = lines.index { |line| line.include?("─ chat ─") }
    refute_nil start, "chat pane should be rendered"
    finish = lines[start..].index { |line| line.match?(/╰─+╯/) }
    finish + 1
  end
end
