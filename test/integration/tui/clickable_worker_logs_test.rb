# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

# Worker-authored log cells retarget the sticky AgentTree selection without
# stealing the logs pane's text-selection, scrolling, focus, or keyboard rules.
class TuiClickableWorkerLogsTest < Minitest::Test
  include TUISupport

  WIDTH = Meringue::TUI::App::DEFAULT_WIDTH
  HEIGHT = Meringue::TUI::App::DEFAULT_HEIGHT

  def setup
    @layout = Meringue::TUI::Layout.new
    @app = build_app(layout: @layout, terminal: FakeTerminal.new(width: WIDTH, height: HEIGHT))
  end

  def test_worker_id_title_and_authored_body_are_click_targets
    %i[id title body].each do |part|
      local_layout = Meringue::TUI::Layout.new
      app = build_app(layout: local_layout, terminal: FakeTerminal.new(width: WIDTH, height: HEIGHT))
      state = worker_state
      position = target_position(state, part, layout: local_layout)

      click(app, state, position)
      composed = compose_app_state(app, worker_state)

      assert_equal "P1-I1-W1", Meringue::TUI::LogScope.id(composed), part
      frame = @layout.render(composed, width: WIDTH, height: HEIGHT, color: true)
      assert_includes frame, "P1-I1-W1 · working"
      assert_includes frame, Meringue::TUI::Style::AGENT_TREE_SELECTED, "the worker row stays highlighted"
    end
  end

  def test_click_preserves_logs_focus_scroll_and_existing_keyboard_mode
    state = worker_state(log_count: 24)
    @app.instance_variable_set(:@focused_pane, "logs")
    @app.instance_variable_get(:@scroll_offsets)["logs"] = 7
    @app.instance_variable_set(:@agent_tree_navigation_active, true)
    @app.instance_variable_set(:@selected_agent_id, "P1-I1-W2")

    click(@app, state, target_position(state, :body, worker_id: "P1-I1-W1"))

    assert_equal "logs", @app.instance_variable_get(:@focused_pane)
    assert_equal 7, @app.instance_variable_get(:@scroll_offsets).fetch("logs")
    assert @app.instance_variable_get(:@agent_tree_navigation_active)
    assert_equal "P1-I1-W1", @app.instance_variable_get(:@selected_agent_id)
  end

  def test_drag_and_double_click_keep_text_selection_precedence
    state = worker_state
    position = target_position(state, :body)
    other = position.merge("x" => position.fetch("x") + 4)

    send_mouse(@app, press(position), state)
    send_mouse(@app, motion(other), state)
    send_mouse(@app, release(other), state)
    assert_nil @app.instance_variable_get(:@log_scope_id)
    refute Meringue::TUI::Selection.empty?(@app.send(:logs_selection))

    app = build_app(layout: @layout, terminal: FakeTerminal.new(width: WIDTH, height: HEIGHT))
    send_mouse(app, press(position), state)
    send_mouse(app, release(position), state)
    send_mouse(app, press(position), state)
    send_mouse(app, release(position), state)
    assert_nil app.instance_variable_get(:@log_scope_id)
    refute Meringue::TUI::Selection.empty?(app.send(:logs_selection))
  end

  def test_non_targets_and_removed_workers_are_inert
    state = worker_state
    body = target_position(state, :body)
    gutter = body.merge("x" => body.fetch("x") - 2)
    click(@app, state, gutter)
    assert_nil @app.instance_variable_get(:@log_scope_id), "the body gutter is not clickable"

    stale = worker_state.merge("agents" => [])
    click(@app, stale, target_position(stale, :body))
    assert_nil @app.instance_variable_get(:@log_scope_id), "a removed worker cannot become a stale filter"
  end

  private

  def worker_state(log_count: 1)
    logs = (1..log_count).map do |index|
      worker_id = index.even? ? "P1-I1-W2" : "P1-I1-W1"
      log_record(
        "L#{index}",
        "timestamp" => format("2026-07-11T00:%02d:00Z", index),
        "source_type" => "worker",
        "source_id" => worker_id,
        "message" => "Authored update #{index} from #{worker_id}"
      )
    end
    composed_state(
      empty_state.merge(
        "projects" => [project_record("P1")],
        "issues" => [issue_record("P1-I1", "agent_ids" => %w[P1-I1-W1 P1-I1-W2])],
        "agents" => [
          agent_record("P1-I1-W1", "project_id" => "P1", "issue_id" => "P1-I1", "harness_metadata" => { "title" => "First worker" }),
          agent_record("P1-I1-W2", "project_id" => "P1", "issue_id" => "P1-I1", "harness_metadata" => { "title" => "Second worker" })
        ],
        "logs" => logs
      )
    )
  end

  def target_position(state, part, worker_id: "P1-I1-W1", layout: @layout)
    lines = layout.logs_text_lines(state, width: WIDTH, height: HEIGHT)
    window = layout.logs_visible_window(state, width: WIDTH, height: HEIGHT)
    pattern = case part
              when :id then worker_id
              when :title then worker_id.end_with?("W1") ? "First worker" : "Second worker"
              else "Authored update"
              end
    line_index = (window.fetch("start_index")...window.fetch("finish_index")).find { |index| lines.fetch(index).include?(pattern) }
    raise "target #{pattern.inspect} is not visible" unless line_index

    column = lines.fetch(line_index).index(pattern) + 1
    HEIGHT.times do |y|
      WIDTH.times do |x|
        point = layout.logs_text_position(state, width: WIDTH, height: HEIGHT, x: x, y: y)
        return { "x" => x + 1, "y" => y + 1 } if point && point.fetch("line") == line_index && point.fetch("column") == column
      end
    end
    raise "no screen coordinate for #{pattern.inspect}"
  end

  def click(app, state, position)
    send_mouse(app, press(position), state)
    send_mouse(app, release(position), state)
  end

  def send_mouse(app, event, state)
    app.send(:handle_key, event, "", 0, -1, nil, state)
  end

  def press(position)
    { "type" => "mouse", "kind" => "button", "pressed" => true, "button" => 0 }.merge(position)
  end

  def release(position)
    { "type" => "mouse", "kind" => "button", "pressed" => false, "button" => 0 }.merge(position)
  end

  def motion(position)
    { "type" => "mouse", "kind" => "motion", "pressed" => true, "button" => 32 }.merge(position)
  end
end
