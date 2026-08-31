# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "stringio"

class TuiInputSurfaceLatencyTest < Minitest::Test
  include TUISupport

  WIDTH = 140
  HEIGHT = 45
  KEY_COUNT = 80
  TRANSCRIPT_COUNT = 500

  class BurstTerminal < TUISupport::FakeTerminal
    def read_key(timeout: nil)
      raise Interrupt if @keys.empty?

      super
    end
  end

  class CountingLayout < Meringue::TUI::Layout
    attr_reader :full_renders, :input_renders

    def initialize(**arguments)
      super
      @full_renders = 0
      @input_renders = 0
    end

    def render(...)
      @full_renders += 1
      super
    end

    def render_input_surface(...)
      @input_renders += 1
      super
    end
  end

  class CountingWorkspacePane < Meringue::TUI::Panes::AgentWorkspacePane
    attr_reader :content_reads, :body_layouts

    def initialize
      super
      @content_reads = 0
      @body_layouts = 0
    end

    def content_lines(...)
      @content_reads += 1
      super
    end

    private

    def entry_body_lines(...)
      @body_layouts += 1
      super
    end
  end

  class StableSession
    def initialize(items)
      @snapshot = { "revision" => 1, "status" => "ready", "items" => items }.freeze
    end

    def snapshot
      @snapshot
    end

    def poll_events(limit:)
      _ = limit
      { "events" => [], "gap" => false }
    end

    def close
      nil
    end
  end

  def test_dashboard_typing_uses_composer_rows_without_full_render_or_state_reload
    layout = CountingLayout.new
    terminal = BurstTerminal.new(width: WIDTH, height: HEIGHT, keys: typing_keys, interactive: true)
    app = build_app(layout: layout, terminal: terminal)
    provider_calls = 0
    provider = lambda do
      provider_calls += 1
      active_state
    end

    assert_equal 0, app.run(state_provider: provider)
    assert_equal 1, provider_calls, "a typing burst must not reload the orchestration state"
    assert_equal 1, layout.full_renders, "a typing burst must not render the full dashboard per key"
    assert_equal KEY_COUNT, layout.input_renders
    assert_equal KEY_COUNT, terminal.frames.count { |frame| frame.is_a?(Hash) }
  end

  def test_input_row_patches_match_full_frames_on_both_surfaces
    app = build_app
    dashboard = compose_app_state(app, active_state, "before", -1, 6)
    workspace = composed_state(
      focused_state,
      workspace: {
        "active" => true,
        "agent_id" => "P1-I1-W1",
        "interactive" => false,
        "embedded" => false,
        "view" => "agent",
        "filter" => "all",
        "input_buffer" => "before",
        "input_cursor" => 6,
        "messages" => [],
        "content_revision" => 1,
        "agent_session" => { "revision" => 1, "items" => transcript_items.first(3) }
      }
    )

    [dashboard, workspace].each do |state|
      updated = app.send(:input_surface_state, state, "beforex", 7, -1)
      previous_frame = app.render(state, width: WIDTH, height: HEIGHT, color: true)
      expected_frame = app.render(updated, width: WIDTH, height: HEIGHT, color: true)
      patch = app.instance_variable_get(:@layout).render_input_surface(
        state,
        updated,
        width: WIDTH,
        height: HEIGHT,
        color: true
      )
      actual_frame = app.send(:replace_frame_rows, previous_frame, patch.fetch(:frame), row: patch.fetch(:row))

      assert_equal expected_frame, actual_frame
    end
  end

  def test_focused_workspace_typing_does_not_copy_or_relayout_the_transcript
    pane = CountingWorkspacePane.new
    layout = CountingLayout.new(agent_workspace_pane: pane)
    terminal = BurstTerminal.new(width: WIDTH, height: HEIGHT, keys: typing_keys, interactive: true)
    app = build_app(layout: layout, terminal: terminal)
    state = focused_state
    worker_id = state.fetch("agents").first.fetch("id")
    app.instance_variable_set(:@agent_workspace_active, true)
    app.instance_variable_set(:@agent_workspace_agent_id, worker_id)
    app.instance_variable_set(:@agent_workspace_interactive, false)
    app.instance_variable_set(:@agent_workspace_view, "agent")
    app.instance_variable_set(:@agent_workspace_session, StableSession.new(transcript_items))
    provider_calls = 0
    provider = lambda do
      provider_calls += 1
      state
    end
    snapshot_calls = 0
    original_snapshot = app.method(:agent_workspace_snapshot)
    app.define_singleton_method(:agent_workspace_snapshot) do |*arguments|
      snapshot_calls += 1
      original_snapshot.call(*arguments)
    end

    assert_equal 0, app.run(state_provider: provider)
    assert_equal 1, provider_calls, "focused typing must not reload the orchestration state"
    assert_equal 1, snapshot_calls, "focused typing must not copy transcript state per key"
    assert_equal 1, layout.full_renders, "focused typing must not render the full workspace per key"
    assert_equal KEY_COUNT, layout.input_renders
    assert_equal TRANSCRIPT_COUNT, pane.body_layouts,
                 "the initial transcript layout must be reused for every focused keystroke"
    assert_operator pane.content_reads, :<=, 2,
                    "focused keystrokes must not request transcript lines"
  end

  private

  def typing_keys
    Array.new(KEY_COUNT) { |index| (97 + (index % 26)).chr }
  end

  def active_state
    empty_state.merge(
      "agents" => [agent_record("P1-I1-W1", "status" => "working")],
      "logs" => Array.new(126) { |index| log_record("L#{index}") }
    )
  end

  def focused_state
    active_state.merge(
      "issues" => [issue_record("P1-I1", "agent_ids" => ["P1-I1-W1"])]
    )
  end

  def transcript_items
    Array.new(TRANSCRIPT_COUNT) do |index|
      {
        "id" => "message-#{index}",
        "role" => index.even? ? "assistant" : "user",
        "content" => "## Transcript entry #{index}\n\nMarkdown content remains unchanged while the user types."
      }
    end.freeze
  end
end
