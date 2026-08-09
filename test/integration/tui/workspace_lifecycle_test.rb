# frozen_string_literal: true

require "test_helper"
require "support/tui_support"

class TuiWorkspaceLifecycleTest < Minitest::Test
  include TUISupport

  class RecordingView
    attr_reader :closed, :paused, :resumed, :cancelled

    def initialize
      @closed = false
      @paused = 0
      @resumed = 0
      @cancelled = 0
    end

    def snapshot
      { "availability" => "live", "session_state" => "streaming", "items" => [], "revision" => 1 }
    end

    def poll_events(limit: nil)
      _ = limit
      { "events" => [], "gap" => false }
    end

    def pause
      @paused += 1
    end

    def resume
      @resumed += 1
    end

    def cancel_current_turn
      @cancelled += 1
      { "status" => "accepted" }
    end

    def close
      @closed = true
    end
  end

  class InteractiveController
    attr_reader :keys, :closed

    def initialize
      @keys = []
      @closed = 0
    end

    def open_workspace(agent:, state:, rows:, columns:)
      _ = [agent, state, rows, columns]
      { "status" => "active", "interactive" => true, "message" => "native Pi focus" }
    end

    def agent_snapshot(agent:, state:, rows:, columns:)
      _ = [agent, state, rows, columns]
      { "interactive" => true, "lines" => ["Pi output"], "styled_lines" => [[ ["Pi output", nil] ]], "cursor" => [0, 2], "revision" => 7, "status" => "running" }
    end

    def handle_agent_key(key:, agent:, state:)
      _ = [agent, state]
      @keys << key
      { "status" => "written", "bytes" => key.to_s.bytesize }
    end

    def close_workspace(agent:)
      @closed += 1
      { "status" => "closed", "message" => "resumed" }
    end
  end

  class RecordingService
    attr_reader :views

    def initialize
      @views = []
    end

    def open(agent_id)
      view = RecordingView.new
      view.instance_variable_set(:@agent_id, agent_id)
      @views << view
      view
    end
  end

  def setup
    @service = RecordingService.new
    @app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      terminal: TUISupport::FakeTerminal.new,
      agent_session_service: @service
    )
    @state = empty_state.merge(
      "agents" => [agent_record("P1-I1-W1", "project_id" => "P1", "issue_id" => "P1-I1")]
    )
  end

  def test_returning_to_dashboard_closes_only_the_view_and_reopens_the_same_stream
    assert @app.send(:open_agent_workspace_by_id, @state, "P1-I1-W1")
    first = @service.views.fetch(0)

    @app.send(:close_agent_workspace)

    assert first.closed
    assert_equal 0, first.cancelled
    refute @app.instance_variable_get(:@agent_workspace_active)

    assert @app.send(:open_agent_workspace_by_id, @state, "P1-I1-W1")
    second = @service.views.fetch(1)
    refute_same first, second
    refute second.closed

    @app.send(:close_agent_workspace)
    assert second.closed
    assert_equal 0, second.cancelled
  end

  def test_terminal_view_pauses_refreshing_not_the_managed_session
    assert @app.send(:open_agent_workspace_by_id, @state, "P1-I1-W1")
    view = @service.views.fetch(0)
    @app.instance_variable_set(:@agent_workspace_view, "agent")

    # No terminal controller is needed to verify the session boundary: the view is paused before
    # the controller reports that the optional shell is unavailable.
    @app.send(:switch_agent_workspace_view, @state)

    assert_equal 1, view.paused
    assert_equal 0, view.cancelled
    @app.instance_variable_set(:@agent_workspace_view, "terminal")
    @app.send(:switch_agent_workspace_view, @state)
    assert_equal 1, view.resumed
    assert_equal 0, view.cancelled
  end

  def test_native_pi_focus_uses_controller_screen_and_forwards_input_without_custom_view
    controller = InteractiveController.new
    app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      terminal: TUISupport::FakeTerminal.new,
      workspace_controller: controller,
      agent_session_service: @service
    )
    state = @state.merge("agents" => [agent_record("P1-I1-W1", "harness" => "pi", "project_id" => "P1", "issue_id" => "P1-I1")])

    assert app.send(:open_agent_workspace_by_id, state, "P1-I1-W1")
    assert_equal true, app.instance_variable_get(:@agent_workspace_interactive)
    assert_empty @service.views

    snapshot = app.send(:agent_workspace_snapshot, state, "", 0)
    assert_equal true, snapshot.fetch("interactive")
    assert_equal ["Pi output"], snapshot.fetch("agent_session").fetch("lines")

    app.send(:handle_agent_workspace_key, "x", "", 0, nil, nil, state)
    assert_equal ["x"], controller.keys
    app.send(:switch_agent_workspace_view, state)
    assert_equal "terminal", app.instance_variable_get(:@agent_workspace_view)
    assert_equal 0, @service.views.length

    app.send(:close_agent_workspace)
    assert_equal 1, controller.closed
  end

  def test_reentering_focus_drops_stale_transient_events_before_replay
    assert @app.send(:open_agent_workspace_by_id, @state, "P1-I1-W1")
    @app.send(
      :reduce_agent_workspace_events,
      "P1-I1-W1",
      [{ "kind" => "message", "id" => "old-fragment", "role" => "assistant", "content" => "old fragment" }]
    )
    assert_equal ["old-fragment"], @app.send(:frozen_agent_workspace_events, "P1-I1-W1").map { |event| event.fetch("id") }

    @app.send(:close_agent_workspace)
    assert @app.send(:open_agent_workspace_by_id, @state, "P1-I1-W1")

    # The new read-only view will replay retained Pi events on its first poll. Until
    # then it must not render the prior view's frozen event array.
    assert_empty @app.send(:frozen_agent_workspace_events, "P1-I1-W1")
  end
end
