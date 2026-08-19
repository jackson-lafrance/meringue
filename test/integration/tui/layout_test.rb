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

    # The AgentTree title carries its scroll indicators ("agent tree  ↑0 ↓2"), so match the pane
    # label rather than a fully closed border.
    assert_includes frame, "─ agent tree "
    assert_match(/─ agent tree +↑\d+ ↓\d+/, frame)
    assert_includes frame, "─ logs ─"
    # With no AgentTree selection the composer uses the plain untargeted title.
    assert_includes frame, "─ chat ─"
  end

  def test_frame_is_exactly_the_requested_rectangle_at_many_sizes
    [[64, 18], [80, 24], [100, 32], [120, 40], [200, 60], [300, 20]].each do |width, height|
      lines = @layout.render(@state, width: width, height: height).split("\n", -1)

      assert_equal height, lines.length, "row count at #{width}x#{height}"
      assert_equal [width], lines.map(&:length).uniq, "row widths at #{width}x#{height}"
    end
  end

  def test_dimensions_below_the_minimum_stay_inside_the_real_terminal_rectangle
    [[1, 1], [0, 0], [-5, -5], [10, 4], [63, 17]].each do |width, height|
      lines = @layout.render(@state, width: width, height: height).split("\n", -1)
      expected_width = [width, 1].max
      expected_height = [height, 1].max

      assert_equal expected_height, lines.length, "rows at #{width}x#{height}"
      assert_equal [expected_width], lines.map(&:length).uniq, "widths at #{width}x#{height}"
    end
  end

  def test_narrow_chat_content_wraps_instead_of_overflowing_the_viewport
    state = state_with_input("x" * 120)
    lines = @layout.render(state, width: 20, height: 8).split("\n", -1)

    assert_equal 8, lines.length
    assert_equal [20], lines.map(&:length).uniq
    assert lines.any? { |line| line.include?("chat") }
  end

  def test_all_three_panes_survive_the_minimum_size
    frame = @layout.render(@state, width: Layout::MIN_WIDTH, height: Layout::MIN_HEIGHT)

    assert_includes frame, "─ agent tree "
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
                    lines.index { |line| line.include?("─ chat") }
    # A slash command bypasses any selection, so the composer says so instead of
    # advertising a chat target it will not use.
    assert_includes frame, "─ chat · slash command ─"
  end

  # The counter/scroll caption is about the list, not a member of it, so it renders
  # on its own reserved row under the box. The box therefore keeps a full window of
  # commands, and the caption can never overlap the composer or the bottom hint.
  def test_the_suggestion_counter_renders_below_the_list_box_not_inside_it
    lines = @layout.render(state_with_input("/"), width: 100, height: 32).split("\n", -1)
    top_border = lines.index { |line| line.include?("─ slash commands ─") }
    caption = lines.index { |line| line.match?(/\d+–\d+ of \d+ commands/) }
    bottom_border = (top_border...caption).reverse_each.find { |index| lines.fetch(index).include?("╰─") }
    composer = lines.index { |line| line.include?("─ chat · slash command ─") }

    refute_nil caption, "the caption should be rendered"
    # Box, then its closing border, then the caption, then the composer.
    assert_operator top_border, :<, bottom_border
    assert_equal bottom_border + 1, caption
    assert_operator caption, :<, composer
    # Nothing was clipped and nothing overlaps: the caption row is blank apart from
    # the caption, and the composer keeps its own gap.
    assert_equal 32, lines.length
    assert_equal [100], lines.map(&:length).uniq
    assert_equal "", lines.fetch(caption + 1).strip

    # The box holds a full window of commands rather than spending a row on the
    # caption, and none of those rows repeat it.
    rows = lines[(top_border + 1)...bottom_border]
    assert_equal Meringue::TUI::Panes::ChatPane::VISIBLE_SUGGESTION_LIMIT, rows.length
    assert rows.all? { |row| row.include?(" — ") }, rows.inspect
  end

  def test_a_short_suggestion_list_reserves_no_caption_row
    lines = @layout.render(state_with_input("/recount"), width: 100, height: 32).split("\n", -1)
    box_top = lines.index { |line| line.include?("─ slash commands ─") }
    composer = lines.index { |line| line.include?("─ chat · slash command ─") }
    bottom_border = (box_top...composer).reverse_each.find { |index| lines.fetch(index).include?("╰─") }

    refute lines.any? { |line| line.match?(/\d+–\d+ of \d+ commands/) }
    # Only the usual one-row gap sits between the box and the composer.
    assert_equal composer - 2, bottom_border
    assert_equal 32, lines.length
  end

  def test_slash_suggestion_pane_collapses_when_there_is_no_vertical_room
    frame = @layout.render(state_with_input("/"), width: 100, height: Layout::MIN_HEIGHT)

    assert_includes frame, "─ chat · slash command ─"
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

    refute_includes frame, "─ agent tree "
    refute_includes frame, "─ logs ─"
    assert_includes frame, "focused worker · P1-I1-W1"
    assert_includes frame, "─ chat ─"
    assert_equal "agent_workspace", @layout.pane_at(workspace_state, width: 100, height: 20, x: 5, y: 3)
    assert_equal({ "agent_tree" => 0, "logs" => 0, "chat" => 0 },
                 @layout.scroll_limits(workspace_state, width: 100, height: 20))
    assert_operator @layout.agent_workspace_scroll_max(workspace_state, width: 100, height: 20), :>=, 0
  end

  def test_native_focus_replaces_only_logs_and_keeps_dashboard_panes_live
    workspace_state = composed_state(
      demo_state,
      chat: { "input_buffer" => "monitor the other workers", "input_cursor" => 25 },
      workspace: {
        "active" => true,
        "embedded" => true,
        "interactive" => true,
        "agent_id" => "P1-I1-W1",
        "view" => "agent",
        "leader_label" => "Ctrl-Space",
        "leader_commands" => [{ "action" => "workspace_close", "key" => "Q", "label" => "return" }],
        "agent_session" => {
          "lines" => ["Pi is ready"],
          "styled_lines" => [[ ["Pi is ready", nil] ]],
          "cursor" => [0, 11],
          "revision" => 1,
          "status" => "running"
        }
      }
    )

    frame = @layout.render(workspace_state, width: 100, height: 32)

    assert_includes frame, "─ agent tree "
    assert_includes frame, "Pi interactive · P1-I1-W1"
    assert_includes frame, "Pi is ready"
    assert_includes frame, "monitor the other workers"
    assert_includes frame, "─ chat"
    refute_includes frame, "─ logs ─"
    assert_equal "agent_tree", @layout.pane_at(workspace_state, width: 100, height: 32, x: 5, y: 3)
    assert_equal "logs", @layout.pane_at(workspace_state, width: 100, height: 32, x: 50, y: 3)
    assert_equal "chat", @layout.pane_at(workspace_state, width: 100, height: 32, x: 50, y: 29)
    assert_equal "H1", @layout.agent_tree_item_at(workspace_state, width: 100, height: 32, x: 5, y: 3)
    assert_nil @layout.logs_text_position(workspace_state, width: 100, height: 32, x: 50, y: 3)
    assert_equal 0, @layout.scroll_limits(workspace_state, width: 100, height: 32).fetch("logs")

    dimensions = @layout.embedded_agent_workspace_dimensions(workspace_state, width: 100, height: 32)
    assert_operator dimensions.fetch("rows"), :>, 0
    assert_operator dimensions.fetch("columns"), :>, 0

    refreshed = workspace_state.merge(
      "agents" => workspace_state.fetch("agents") + [agent_record(
        "H99",
        "type" => "head",
        "status" => "working",
        "harness" => "pi",
        "harness_metadata" => { "title" => "New live monitor" }
      )]
    )
    assert_includes @layout.render(refreshed, width: 100, height: 32), "H99"
  end

  def test_focused_workspace_uses_open_session_to_avoid_colliding_with_settings_inspection
    advertised = Meringue::TUI::WorkspaceCommands::COMMAND_SPECS.map(&:first)

    assert_includes advertised, "/open-session"
    refute_includes advertised, "/session"
    assert_equal "workspace_open_agent_session", Meringue::TUI::WorkspaceCommands.resolve("/open-session").fetch("action")
    assert_equal "workspace_open_agent_session", Meringue::TUI::WorkspaceCommands.resolve("/session").fetch("action")
  end

  def test_focused_workspace_labels_effective_session_settings
    state = demo_state
    worker = state.fetch("agents").find { |agent| agent.fetch("id") == "P1-I1-W1" }
    worker["harness"] = "pi"
    worker["session_settings"] = {
      "model" => { "reference" => "openai/gpt-5.6-sol" },
      "thinking_level" => "xhigh",
      "availability" => "available"
    }
    workspace_state = composed_state(
      state,
      workspace: {
        "active" => true,
        "agent_id" => "P1-I1-W1",
        "view" => "agent",
        "filter" => "all",
        "messages" => []
      }
    )

    frame = @layout.render(workspace_state, width: 120, height: 20)

    assert_includes frame, "session settings · model openai/gpt-5.6-sol · thinking xhigh"
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
    start = lines.index { |line| line.include?("─ chat") }
    refute_nil start, "chat pane should be rendered"
    finish = lines[start..].index { |line| line.match?(/╰─+╯/) }
    finish + 1
  end
end
