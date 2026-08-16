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
    attr_reader :keys, :terminal_keys, :closed

    def initialize
      @keys = []
      @terminal_keys = []
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

    def open_terminal(agent:, state:, rows:, columns:)
      _ = [agent, state, rows, columns]
      { "status" => "active", "started" => true, "message" => "terminal" }
    end

    def resize_terminal(agent:, rows:, columns:)
      _ = [agent, rows, columns]
      { "status" => "resized" }
    end

    def handle_terminal_key(key:, agent:, state:)
      _ = [agent, state]
      @terminal_keys << key
      { "status" => "written", "bytes" => key.to_s.bytesize }
    end

    def close_workspace(agent:)
      @closed += 1
      { "status" => "closed", "message" => "resumed" }
    end
  end

  class RejectedInteractiveController
    def open_workspace(agent:, state:, rows:, columns:)
      _ = [agent, state, rows, columns]
      {
        "status" => "rejected",
        "message" => "Worker is still running a turn. Wait for it to settle; the active turn was left untouched."
      }
    end
  end

  class BlockingFocusService
    attr_reader :begun

    def initialize
      @begun = Queue.new
      @release = Queue.new
    end

    def begin_agent_interactive_focus(agent_id)
      @begun << agent_id
      @release.pop
      { "status" => "accepted", "result" => { "interactive_argv" => ["/bin/sh"], "interactive_env" => {} } }
    end

    def release
      @release << true
    end

    def mark_agent_interactive_focus_started(agent_id, pid:)
      { "status" => "accepted", "agent_id" => agent_id, "pid" => pid }
    end

    def end_agent_interactive_focus(_agent_id)
      { "status" => "accepted" }
    end
  end

  class ImmediateInteractiveSession
    def start(workspace_path:, rows:, columns:, on_started:)
      on_started.call(4242)
      { "status" => "active", "pid" => 4242, "workspace_path" => workspace_path }
    end

    def alive? = true

    def status
      { "state" => "running", "pid" => 4242, "alive" => true }
    end

    def drain_output(timeout: 0)
      _ = timeout
      +""
    end

    def resize(rows:, columns:)
      { "status" => "resized", "rows" => rows, "columns" => columns }
    end

    def write(_bytes)
      { "status" => "written" }
    end

    def close
      { "status" => "closed" }
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

  def test_entering_an_actively_streaming_worker_focus_is_pending_without_blocking_the_tui
    Dir.mktmpdir("meringue-focused-worker-") do |workspace|
      focus = BlockingFocusService.new
      controller = Meringue::Workspace::Controller.new(
        focus_session_service: focus,
        interactive_session_factory: ->(command:, env:) { ImmediateInteractiveSession.new }
      )
      app = Meringue::TUI::App.new(
        layout: Meringue::TUI::Layout.new,
        terminal: TUISupport::FakeTerminal.new,
        workspace_controller: controller
      )
      state = @state.merge(
        "agents" => [agent_record(
          "P1-I1-W1",
          "type" => "worker",
          "status" => "working",
          "harness" => "pi",
          "workspace_path" => workspace,
          "project_id" => "P1",
          "issue_id" => "P1-I1"
        )]
      )

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert app.send(:open_agent_workspace_by_id, state, "P1-I1-W1")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 0.5, "selecting an active worker must not wait for Pi handoff"
      assert_equal "P1-I1-W1", focus.begun.pop
      refute app.instance_variable_get(:@agent_workspace_interactive)
      assert_equal true, app.instance_variable_get(:@agent_workspace_open_pending)

      # Rendering and input remain available while the background handoff waits
      # for the active turn to settle.
      snapshot = app.send(:agent_workspace_snapshot, state, "", 0)
      assert_equal true, snapshot.fetch("active")
      refute snapshot.fetch("interactive")

      focus.release
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until app.send(:agent_workspace_snapshot, state, "", 0).fetch("interactive", false)
        raise "native focus did not complete" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      assert_equal false, app.instance_variable_get(:@agent_workspace_open_pending)
      app.send(:close_agent_workspace)
      refute controller.agent_interactive?(agent: state.fetch("agents").first)
    ensure
      app&.send(:close_agent_workspace)
      controller&.close
    end
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
    app.send(:handle_agent_workspace_key, "ls\n", "", 0, nil, nil, state)
    assert_equal ["ls\n"], controller.terminal_keys

    app.send(:switch_agent_workspace_view, state)
    app.send(:handle_agent_workspace_key, "y", "", 0, nil, nil, state)
    assert_equal ["x", "y"], controller.keys

    app.send(:close_agent_workspace)
    assert_equal 1, controller.closed
  end

  def test_rejected_native_focus_restores_the_dashboard_with_an_actionable_status
    app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      terminal: TUISupport::FakeTerminal.new,
      workspace_controller: RejectedInteractiveController.new
    )
    state = @state.merge("agents" => [agent_record("P1-I1-W1", "harness" => "pi", "project_id" => "P1", "issue_id" => "P1-I1")])

    refute app.send(:open_agent_workspace_by_id, state, "P1-I1-W1")
    refute app.instance_variable_get(:@agent_workspace_active)
    assert app.instance_variable_get(:@force_full_redraw)
    assert_includes app.send(:selection_status_text), "active turn was left untouched"
    assert_equal "P1-I1-W1", app.instance_variable_get(:@selected_agent_id)
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
