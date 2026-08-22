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
    attr_reader :keys, :terminal_keys, :closed, :opened_sizes, :resized_sizes
    attr_accessor :snapshot_lines

    def initialize
      @keys = []
      @terminal_keys = []
      @closed = 0
      @opened_sizes = []
      @resized_sizes = []
      @snapshot_lines = ["Pi output"]
    end

    def open_workspace(agent:, state:, rows:, columns:)
      _ = [agent, state]
      @opened_sizes << [rows, columns]
      { "status" => "active", "interactive" => true, "message" => "Agent session" }
    end

    def agent_snapshot(agent:, state:, rows:, columns:)
      _ = [agent, state, rows, columns]
      {
        "interactive" => true,
        "lines" => @snapshot_lines,
        "styled_lines" => @snapshot_lines.map { |line| [[line, nil]] },
        "cursor" => [0, 2],
        "revision" => 7,
        "status" => "running"
      }
    end

    def handle_agent_key(key:, agent:, state:)
      _ = [agent, state]
      @keys << key
      { "status" => "written", "bytes" => key.to_s.bytesize }
    end

    def resize_agent(agent:, rows:, columns:)
      _ = agent
      @resized_sizes << [rows, columns]
      { "status" => "resized" }
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
    attr_reader :begun, :ended

    def initialize
      @begun = Queue.new
      @ended = Queue.new
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

    def end_agent_interactive_focus(agent_id)
      @ended << agent_id
      { "status" => "accepted" }
    end
  end

  class CompactingFocusService
    attr_reader :resume_started, :ended

    def initialize
      @resume_started = Queue.new
      @resume_release = Queue.new
      @ended = []
    end

    def begin_agent_interactive_focus(agent_id)
      {
        "status" => "accepted",
        "result" => { "interactive_argv" => ["/bin/sh"], "interactive_env" => {} },
        "agent_id" => agent_id
      }
    end

    def mark_agent_interactive_focus_started(agent_id, pid:)
      { "status" => "accepted", "agent_id" => agent_id, "pid" => pid }
    end

    def end_agent_interactive_focus(agent_id)
      @ended << agent_id
      @resume_started << agent_id
      @resume_release.pop
      { "status" => "accepted", "message" => "resumed after compaction" }
    end

    def release_resume
      @resume_release << true
    end
  end

  class ImmediateInteractiveSession
    attr_reader :writes

    def initialize
      @writes = []
    end

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

    def write(bytes)
      @writes << bytes
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
      assert_equal true, snapshot.fetch("embedded")
      assert_equal true, snapshot.fetch("opening")
      refute snapshot.fetch("interactive")
      frame = app.render(state.merge(
        "_chat" => { "input_buffer" => "monitor workers", "input_cursor" => 15 },
        "_scroll" => { "active_pane" => "logs", "offsets" => {} },
        "_agent_workspace" => snapshot
      ), width: 100, height: 32)
      assert_includes frame, "─ agent tree "
      assert_includes frame, "Agent session preparing"
      assert_includes frame, "monitor workers"

      # Focus can move back to the external composer while handoff is blocked.
      buffer, cursor, = app.send(:handle_key, "\t", "", 0, -1, nil, state)
      buffer, cursor, = app.send(:handle_key, "m", buffer, cursor, -1, nil, state)
      assert_equal "m", buffer

      focus.release
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until app.send(:agent_workspace_snapshot, state, "", 0).fetch("interactive", false)
        raise "native focus did not complete" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      assert_equal false, app.instance_variable_get(:@agent_workspace_open_pending)
      app.send(:close_agent_workspace)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      while controller.agent_interactive?(agent: state.fetch("agents").first)
        raise "native focus did not close" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      refute controller.agent_interactive?(agent: state.fetch("agents").first)
    ensure
      app&.send(:close_agent_workspace)
      controller&.close
    end
  end

  def test_completed_resumable_worker_stays_in_native_focus_and_accepts_input
    Dir.mktmpdir("meringue-completed-focus-") do |workspace|
      focus = BlockingFocusService.new
      interactive_session = ImmediateInteractiveSession.new
      controller = Meringue::Workspace::Controller.new(
        focus_session_service: focus,
        interactive_session_factory: ->(command:, env:) { interactive_session }
      )
      app = Meringue::TUI::App.new(
        layout: Meringue::TUI::Layout.new,
        terminal: TUISupport::FakeTerminal.new,
        workspace_controller: controller
      )
      state = @state.merge("agents" => [agent_record(
        "P1-I1-W1",
        "type" => "worker",
        "status" => "completed",
        "harness" => "pi",
        "workspace_path" => workspace,
        "project_id" => "P1",
        "issue_id" => "P1-I1",
        "harness_session_id" => "completed-session",
        "harness_session_file" => File.join(workspace, "completed-session.jsonl")
      )])
      released = false

      assert app.send(:open_agent_workspace_by_id, state, "P1-I1-W1")
      assert_equal "P1-I1-W1", focus.begun.pop

      # The normal frame reconciliation used to mistake this already-completed worker for a
      # newly terminal selection, cancel the pending handoff, and immediately return to dashboard.
      opening = compose_app_state(app, state).fetch("_agent_workspace")
      assert_equal true, opening.fetch("active")
      assert_equal true, opening.fetch("opening")
      assert focus.ended.empty?, "dashboard ownership must not resume while focus is opening"

      focus.release
      released = true
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      focused = nil
      loop do
        focused = compose_app_state(app, state).fetch("_agent_workspace")
        break if focused.fetch("interactive", false)

        raise "completed native focus did not open" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end

      assert_equal true, focused.fetch("active")
      refute focused.fetch("opening")
      assert focus.ended.empty?, "a completed worker must stay under native focus ownership"

      app.send(:handle_key, "x", "", 0, -1, nil, state)
      assert_equal ["x"], interactive_session.writes

      app.send(:close_agent_workspace)
      assert_equal "P1-I1-W1", Timeout.timeout(2) { focus.ended.pop }
    ensure
      focus&.release unless released
      app&.send(:close_agent_workspace)
      controller&.close
    end
  end

  def test_quitting_focus_during_compaction_returns_to_a_usable_dashboard_immediately
    Dir.mktmpdir("meringue-compacting-focus-") do |workspace|
      focus = CompactingFocusService.new
      interactive_session = ImmediateInteractiveSession.new
      controller = Meringue::Workspace::Controller.new(
        focus_session_service: focus,
        interactive_session_factory: ->(command:, env:) { interactive_session }
      )
      app = Meringue::TUI::App.new(
        layout: Meringue::TUI::Layout.new,
        terminal: TUISupport::FakeTerminal.new,
        workspace_controller: controller
      )
      state = @state.merge("agents" => [agent_record(
        "P1-I1-W1",
        "type" => "worker",
        "status" => "working",
        "harness" => "pi",
        "workspace_path" => workspace,
        "project_id" => "P1",
        "issue_id" => "P1-I1"
      )])

      assert app.send(:open_agent_workspace_by_id, state, "P1-I1-W1")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until compose_app_state(app, state).dig("_agent_workspace", "interactive")
        raise "native focus did not open" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end

      # Model Pi autocompaction by holding dashboard reattachment after the native PTY closes.
      # The old synchronous quit path blocked the complete render/input loop at this boundary.
      releaser = Thread.new do
        focus.resume_started.pop
        sleep 0.5
        focus.release_resume
      end
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      app.send(:close_agent_workspace, preserve_terminal: true)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_operator elapsed, :<, 0.2
      refute app.instance_variable_get(:@agent_workspace_active)
      assert_equal "chat", app.instance_variable_get(:@focused_pane)
      buffer, = app.send(:handle_key, "m", "", 0, -1, nil, state)
      assert_equal "m", buffer, "dashboard input must stay usable while ownership resumes"
      refute app.instance_variable_get(:@quit_requested)

      releaser.join
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      while controller.interactive_close_pending?(agent: state.fetch("agents").first)
        raise "dashboard ownership did not finish resuming" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      compose_app_state(app, state)
      assert_equal ["\e"], interactive_session.writes
      assert_equal ["P1-I1-W1"], focus.ended
    ensure
      focus&.release_resume
      releaser&.join(0.1)
      app&.send(:close_agent_workspace)
      controller&.close
    end
  end

  def test_cancelling_a_pending_focus_restores_dashboard_ownership_without_starting_a_pty
    Dir.mktmpdir("meringue-cancelled-focus-") do |workspace|
      focus = BlockingFocusService.new
      controller = Meringue::Workspace::Controller.new(
        focus_session_service: focus,
        interactive_session_factory: ->(**) { raise "cancelled focus must not start a PTY" }
      )
      app = Meringue::TUI::App.new(
        layout: Meringue::TUI::Layout.new,
        terminal: TUISupport::FakeTerminal.new,
        workspace_controller: controller
      )
      state = @state.merge("agents" => [agent_record(
        "P1-I1-W1",
        "type" => "worker",
        "status" => "working",
        "harness" => "pi",
        "workspace_path" => workspace,
        "project_id" => "P1",
        "issue_id" => "P1-I1"
      )])

      assert app.send(:open_agent_workspace_by_id, state, "P1-I1-W1")
      assert_equal "P1-I1-W1", focus.begun.pop
      app.send(:close_agent_workspace)
      refute app.instance_variable_get(:@agent_workspace_active)
      assert_equal "chat", app.instance_variable_get(:@focused_pane)

      focus.release
      assert_equal "P1-I1-W1", Timeout.timeout(2) { focus.ended.pop }
      refute controller.agent_interactive?(agent: state.fetch("agents").first)
    ensure
      app&.send(:close_agent_workspace)
      controller&.close
    end
  end

  def test_embedded_native_focus_routes_input_by_pane_and_returns_to_prior_focus
    controller = InteractiveController.new
    app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      terminal: TUISupport::FakeTerminal.new,
      workspace_controller: controller
    )
    state = @state.merge(
      "projects" => [project_record("P1")],
      "issues" => [issue_record("P1-I1", "project_id" => "P1", "title" => "Keep dashboard visibility")],
      "agents" => [agent_record(
        "P1-I1-W1",
        "type" => "worker",
        "status" => "working",
        "harness" => "pi",
        "project_id" => "P1",
        "issue_id" => "P1-I1"
      )]
    )
    submitted = Queue.new
    handler = lambda do |text, **_options|
      submitted << text
      { "summary" => "routed" }
    end

    assert app.send(:open_agent_workspace_by_id, state, "P1-I1-W1")
    assert_equal "logs", app.instance_variable_get(:@focused_pane)
    assert_equal true, app.send(:agent_workspace_snapshot, state, "", 0).fetch("embedded")

    app.send(:handle_key, "x", "", 0, -1, handler, state)
    app.send(:handle_key, "\u0003", "", 0, -1, handler, state)
    assert_equal ["x", "\u0003"], controller.keys

    workspace_snapshot = app.send(:agent_workspace_snapshot, state, "", 0)
    mouse_state = state.merge("_agent_workspace" => workspace_snapshot)
    app.send(
      :handle_key,
      { "type" => "mouse", "kind" => "wheel_down", "pressed" => true, "button" => 65, "count" => 1, "x" => 50, "y" => 3 },
      "",
      0,
      -1,
      handler,
      mouse_state
    )
    wheel = controller.keys.last
    assert_equal "wheel_down", wheel.fetch("kind")
    assert_operator wheel.fetch("x"), :>=, 1
    assert_operator wheel.fetch("y"), :>=, 1

    app.send(:handle_key, "\u0000", "", 0, -1, handler, state)
    assert app.instance_variable_get(:@workspace_leader_pending)
    app.instance_variable_set(:@workspace_leader_started_at, app.send(:monotonic_time) - 2)
    refute app.send(:agent_workspace_snapshot, state, "", 0).fetch("leader_pending"), "an abandoned leader sequence must expire"

    buffer, cursor, = app.send(:handle_key, "\t", "", 0, -1, handler, state)
    assert_equal "chat", app.instance_variable_get(:@focused_pane)
    "monitor workers".each_char do |character|
      buffer, cursor, = app.send(:handle_key, character, buffer, cursor, -1, handler, state)
    end
    assert_equal "monitor workers", buffer
    assert_equal 3, controller.keys.length, "chat input must not leak into Pi"
    app.send(:handle_key, "\r", buffer, cursor, -1, handler, state)
    assert_equal "monitor workers", Timeout.timeout(5) { submitted.pop }

    # Keyboard focus can reach the live AgentTree without sending navigation
    # bytes to Pi; Enter then enables the existing tree-management mode.
    app.send(:handle_key, "\e[Z", "", 0, -1, handler, state)
    app.send(:handle_key, "\e[Z", "", 0, -1, handler, state)
    assert_equal "agent_tree", app.instance_variable_get(:@focused_pane)
    app.send(:handle_key, "\r", "", 0, -1, handler, state)
    assert app.instance_variable_get(:@agent_tree_navigation_active)
    assert_equal 3, controller.keys.length

    # Resizing the dashboard changes the actual PTY, not only the screen model.
    app.instance_variable_set(:@last_render_width, 120)
    app.instance_variable_set(:@last_render_height, 40)
    app.send(:agent_workspace_snapshot, state, "", 0)
    expected = Meringue::TUI::Layout.new.embedded_agent_workspace_dimensions(state, width: 120, height: 40)
    assert_equal [expected.fetch("rows"), expected.fetch("columns")], controller.resized_sizes.last

    app.instance_variable_set(:@focused_pane, "logs")
    app.send(:handle_key, "\u0000", "", 0, -1, handler, state)
    app.send(:handle_key, "q", "", 0, -1, handler, state)
    refute app.instance_variable_get(:@agent_workspace_active)
    assert_equal "chat", app.instance_variable_get(:@focused_pane)
    assert_equal 1, controller.closed
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

  def test_embedded_native_session_scrolls_with_page_keys_and_wheel_and_keeps_position_on_resize
    controller = InteractiveController.new
    controller.snapshot_lines = Array.new(48) { |index| "Pi row #{index.to_s.rjust(2, "0")}" }
    app = Meringue::TUI::App.new(
      layout: Meringue::TUI::Layout.new,
      terminal: TUISupport::FakeTerminal.new,
      workspace_controller: controller
    )
    state = @state.merge("agents" => [agent_record(
      "P1-I1-W1",
      "type" => "worker",
      "status" => "working",
      "harness" => "pi",
      "project_id" => "P1",
      "issue_id" => "P1-I1"
    )])

    assert app.send(:open_agent_workspace_by_id, state, "P1-I1-W1")
    snapshot = app.send(:agent_workspace_snapshot, state, "", 0)
    scroll_state = state.merge("_agent_workspace" => snapshot)
    maximum = app.send(:agent_workspace_scroll_max, scroll_state)
    assert_operator maximum, :>, 0

    app.send(:handle_key, "\e[5~", "", 0, -1, nil, scroll_state)
    offset = app.instance_variable_get(:@workspace_agent_scroll_offset)
    assert_equal [Meringue::TUI::App::PAGE_SCROLL_STEP, maximum].min, offset
    assert_equal offset, app.send(:agent_workspace_snapshot, state, "", 0).fetch("scroll_offset")

    app.send(
      :handle_key,
      { "type" => "mouse", "kind" => "wheel_down", "pressed" => true, "button" => 65, "count" => 1, "x" => 50, "y" => 3 },
      "",
      0,
      -1,
      nil,
      app.send(:agent_workspace_snapshot, state, "", 0).then { |current| state.merge("_agent_workspace" => current) }
    )
    assert_equal [offset - Meringue::TUI::App::MOUSE_SCROLL_STEP, 0].max, app.instance_variable_get(:@workspace_agent_scroll_offset)
    assert_empty controller.keys, "TUI scrolling should not forward a retained-row wheel to Pi"

    app.instance_variable_set(:@last_render_height, 18)
    resized_snapshot = app.send(:agent_workspace_snapshot, state, "", 0)
    resized_state = state.merge("_agent_workspace" => resized_snapshot)
    resized_maximum = app.send(:agent_workspace_scroll_max, resized_state)
    assert_operator app.instance_variable_get(:@workspace_agent_scroll_offset), :<=, resized_maximum
    expected = Meringue::TUI::Layout.new.embedded_agent_workspace_dimensions(resized_state, width: 100, height: 18)
    assert_equal [expected.fetch("rows"), expected.fetch("columns")], controller.resized_sizes.last
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
