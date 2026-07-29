# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "stringio"
require "timeout"

class TuiAppWiringTest < Minitest::Test
  include TUISupport

  App = Meringue::TUI::App
  Models = Meringue::State::Models

  def setup
    @out = StringIO.new
    @terminal = TUISupport::FakeTerminal.new
    @app = App.new(layout: Meringue::TUI::Layout.new, out: @out, terminal: @terminal)
  end

  def test_render_delegates_to_the_layout_at_the_requested_size
    frame = @app.render(composed_state(demo_state), width: 80, height: 20)
    lines = frame.split("\n", -1)

    assert_equal 20, lines.length
    assert_equal [80], lines.map(&:length).uniq
  end

  def test_non_interactive_run_renders_one_frame_and_exits_cleanly
    provider = TUISupport::RecordingStateProvider.new(demo_state)

    assert_equal 0, @app.run(state_provider: provider.to_proc)
    assert_equal 1, provider.calls
    assert_empty @terminal.frames, "a non-interactive run never writes terminal frames"

    lines = @out.string.split("\n")
    assert_equal App::DEFAULT_HEIGHT, lines.length
    assert_equal [App::DEFAULT_WIDTH], lines.map(&:length).uniq
    assert_includes @out.string, "─ agent tree ─"
  end

  def test_run_without_a_state_falls_back_to_an_empty_state
    assert_equal 0, @app.run
    assert_includes @out.string, "No AgentTree data yet."
  end

  def test_compose_state_only_adds_presentation_keys
    provider = TUISupport::RecordingStateProvider.new(demo_state)
    composed = compose_app_state(@app, provider.to_proc, "typed")

    assert_equal %w[_agent_tree_navigation _agent_workspace _chat _scroll _selection], (composed.keys - demo_state.keys).sort
    demo_state.each_key { |key| assert composed.key?(key), "kernel key #{key} must survive composition" }
    assert_equal demo_state.fetch("agents"), composed.fetch("agents")
    assert_equal demo_state.fetch("questions"), composed.fetch("questions")
  end

  def test_compose_state_does_not_mutate_the_kernel_snapshot
    shared = demo_state
    before = JSON.parse(JSON.generate(shared))

    compose_app_state(@app, -> { shared }, "typed")

    assert_equal before, shared
  end

  def test_composed_presentation_state_matches_the_documented_shape
    composed = compose_app_state(@app, -> { demo_state }, "typed")

    assert_equal "typed", composed.dig("_chat", "input_buffer")
    assert_equal 5, composed.dig("_chat", "input_cursor")
    assert_equal 0, composed.dig("_chat", "pending_count")
    assert_equal "chat", composed.dig("_scroll", "active_pane")
    assert_equal({ "agent_tree" => 0, "logs" => 0, "chat" => 0 }, composed.dig("_scroll", "offsets"))
    refute composed.dig("_selection", "active")
    refute composed.dig("_agent_workspace", "active")
  end

  def test_restore_logs_reads_the_persisted_conversation_without_mutating_state
    state = empty_state
    state["conversation"] = {
      "messages" => [{ "id" => 4, "role" => "you", "text" => "persisted prompt", "timestamp" => "2026-07-11T00:00:00Z" }],
      "next_message_id" => 5
    }
    before = JSON.parse(JSON.generate(state))

    @app.restore_logs!(state)
    composed = compose_app_state(@app, -> { state }, "")

    assert_equal before, state
    assert_includes plain_lines(Meringue::TUI::Panes::ChatPane.new.log_lines(composed, width: 60)).join("\n"), "persisted prompt"
  end

  def test_restore_agent_workspace_reads_persisted_ui_selection
    state = empty_state
    # The kernel prunes selections for unknown workers, so the worker has to
    # exist in the snapshot for its persisted workspace state to survive.
    state["agents"] = [agent_record("P1-I1-W1", "issue_id" => "P1-I1")]
    state["ui"] = {
      "agent_workspace" => {
        "selected_agent_id" => "P1-I1-W1",
        "view" => "terminal",
        "filter" => "tools",
        "draft" => "half typed",
        "agent_scroll_offset" => 3,
        "terminal_scroll_offset" => 1
      }
    }

    workspace = @app.restore_agent_workspace!(state)

    assert_equal "P1-I1-W1", workspace.fetch("selected_agent_id")
    assert_equal "terminal", workspace.fetch("view")
    assert_equal "tools", workspace.fetch("filter")
    assert_equal "half typed", workspace.fetch("draft")
    assert_equal 3, workspace.fetch("agent_scroll_offset")
    assert_includes Models::AGENT_WORKSPACE_FILTERS, workspace.fetch("filter")
  end

  def test_restore_agent_workspace_drops_selections_for_unknown_workers
    state = empty_state
    state["ui"] = { "agent_workspace" => { "selected_agent_id" => "P9-I9-W9", "view" => "terminal", "draft" => "dropped" } }

    workspace = @app.restore_agent_workspace!(state)

    # Nil values are compacted out of the normalized workspace snapshot.
    assert_nil workspace.fetch("selected_agent_id", nil)
    assert_equal "", workspace.fetch("draft")
    assert_equal "terminal", workspace.fetch("view")
  end

  def test_remember_existing_log_events_does_not_mutate_state
    state = demo_state
    before = JSON.parse(JSON.generate(state))

    @app.remember_existing_log_events!(state)

    assert_equal before, state
  end

  def test_typing_editing_and_navigation_keys_only_change_the_composer
    state = composed_state(empty_state)

    assert_equal ["h", 1, -1], @app.send(:handle_key, "h", "", 0, -1, nil, state)
    assert_equal ["h", 1, -1], @app.send(:handle_key, "\u007f", "hi", 2, -1, nil, state)
    assert_equal ["abc", 2, -1], @app.send(:handle_key, "\e[D", "abc", 3, -1, nil, state)
    assert_equal ["pasted", 6, -1], @app.send(:handle_key, { "type" => "paste", "text" => "pasted" }, "", 0, -1, nil, state)
    assert_equal ["", 0, -1], @app.send(:handle_key, "\u0003", "clear me", 8, -1, nil, state)
    assert_equal ["/help", 5, -1], @app.send(:handle_key, "\t", "/hel", 4, -1, nil, state)
    assert_equal ["a\nb", 2, -1], @app.send(:handle_key, "\e[13;2u", "ab", 1, -1, nil, state)
  end

  def test_submitting_a_prompt_hands_the_text_to_the_kernel_callback
    state = composed_state(empty_state)
    submitted = Queue.new
    handler = lambda do |text|
      submitted << text
      { "summary" => "routed the prompt" }
    end

    assert_equal ["", 0, -1], @app.send(:handle_key, "\r", "do it", 5, -1, handler, state)
    assert_equal "do it", Timeout.timeout(5) { submitted.pop }
  end

  def test_quit_keys_follow_the_injected_keybindings
    assert @app.send(:quit_key?, "\u0004", "")
    assert @app.send(:quit_key?, "\u0003", "")
    refute @app.send(:quit_key?, "\u0003", "text")
    refute @app.send(:quit_key?, nil, "")

    custom = App.new(
      layout: Meringue::TUI::Layout.new,
      out: StringIO.new,
      terminal: TUISupport::FakeTerminal.new,
      keybindings: Meringue::TUI::Keybindings.from_config({ "quit" => ["ctrl-q"] })
    )

    assert custom.send(:quit_key?, "\u0011", "")
    refute custom.send(:quit_key?, "\u0004", "")
  end

  def test_tui_never_invents_lifecycle_statuses
    assert_equal Models::LIFECYCLE_STATUSES.sort, Meringue::TUI::Panes::AgentTreePane::STATUS_DOTS.keys.sort
    assert_equal Models::LIFECYCLE_STATUSES.sort, Meringue::TUI::Panes::AgentTreePane::STATUS_STYLES.keys.sort
  end

  def test_tui_never_invents_log_levels
    level_styles = Meringue::TUI::Style::STYLE_NAMES.grep(/\ALOG_/).map { |name| name.to_s.sub("LOG_", "").downcase }

    assert_equal (Models::LOG_LEVELS + ["command"]).sort, level_styles.sort
    Models::LOG_LEVELS.each do |level|
      state = composed_state(empty_state.merge("logs" => [log_record("L1", "level" => level, "message" => "#{level} entry")]))
      assert_includes render_frame(state, width: 80, height: 20), "#{level} entry"
    end
  end

  def test_agent_workspace_filters_come_from_the_state_models
    assert_equal Models::AGENT_WORKSPACE_FILTERS, App::WORKSPACE_FILTERS
  end

  def test_no_color_environment_disables_color_output
    with_env("NO_COLOR" => "1") { refute @app.send(:color_output?) }
    with_env("NO_COLOR" => nil) { assert @app.send(:color_output?) }
  end

  def test_focus_order_covers_the_three_dashboard_panes
    assert_equal %w[agent_tree chat logs], App::FOCUS_ORDER.sort
  end
end
