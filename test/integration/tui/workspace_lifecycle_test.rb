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
