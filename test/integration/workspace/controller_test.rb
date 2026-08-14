# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Controller coordinates UI-owned shells/editors. Doubles stand in for both, so
# the assertions cover the results and screen state the TUI renders.
class WorkspaceControllerTest < Minitest::Test
  include WorkspaceSupport

  class FailedInteractiveLaunch
    attr_reader :closes

    def initialize
      @closes = 0
    end

    def start(workspace_path:, rows:, columns:, on_started: nil)
      { "status" => "failed", "message" => "native Pi could not launch" }
    end

    def close
      @closes += 1
      { "status" => "closed" }
    end
  end

  class InteractiveFocusDouble
    attr_reader :begun, :started, :ended
    attr_accessor :end_result

    def initialize
      @begun = []
      @started = []
      @ended = []
    end

    def begin_agent_interactive_focus(agent_id)
      @begun << agent_id
      { "status" => "accepted", "result" => { "interactive_argv" => ["pi", "--session", "session.json"], "interactive_env" => {} }, "message" => "prepared" }
    end

    def mark_agent_interactive_focus_started(agent_id, pid:)
      @started << [agent_id, pid]
      { "status" => "accepted", "message" => "started" }
    end

    def end_agent_interactive_focus(agent_id)
      @ended << agent_id
      @end_result || { "status" => "accepted", "message" => "resumed" }
    end
  end

  def setup
    @sessions = []
    @editor = WorkspaceSupport::FakeEditorLauncher.new
  end

  def test_open_workspace_reports_the_focused_directory
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller

      result = controller.open_workspace(agent: worker_agent(workspace_path: workspace))

      assert_equal "opened", result.fetch("status")
      assert_equal "Focused P1-I1-W1 in #{workspace}.", result.fetch("message")
    ensure
      controller&.close
    end
  end

  def test_open_workspace_runs_native_pi_in_the_focus_pty_and_resumes_on_close
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      focus = InteractiveFocusDouble.new
      controller = Meringue::Workspace::Controller.new(
        terminal_manager: Meringue::Workspace::TerminalManager.new(
          session_factory: lambda {
            session = WorkspaceSupport::FakeTerminalSession.new(output: "Pi ready\r\n")
            @sessions << session
            session
          }
        ),
        editor_launcher: @editor,
        focus_session_service: focus,
        interactive_session_factory: lambda { |command:, env:|
          assert_equal ["pi", "--session", "session.json"], command
          assert_equal({}, env)
          session = WorkspaceSupport::FakeTerminalSession.new(output: "Pi ready\r\n")
          @sessions << session
          session
        }
      )
      agent = worker_agent(workspace_path: workspace, **{ "harness" => "pi" })

      opened = controller.open_workspace(agent: agent, rows: 10, columns: 30)
      assert_equal "active", opened.fetch("status")
      assert_equal true, opened.fetch("interactive")
      assert_equal [[agent.fetch("id"), 4242]], focus.started
      assert_equal({ "workspace_path" => workspace, "rows" => 10, "columns" => 30 }, @sessions.last.starts.last)

      snapshot = controller.agent_snapshot(agent: agent, rows: 10, columns: 30)
      assert_equal true, snapshot.fetch("interactive")
      assert_equal ["Pi ready", ""], snapshot.fetch("lines")
      assert_equal({ "status" => "written", "bytes" => 2 }, controller.handle_agent_key(key: "x\n", agent: agent))

      closed = controller.close_workspace(agent: agent)
      assert_equal "closed", closed.fetch("status")
      assert_equal ["x\n", "\u0003"], @sessions.last.writes
      assert_equal 1, @sessions.last.closes
      assert_equal [agent.fetch("id")], focus.ended
    ensure
      controller&.close
    end
  end

  def test_dashboard_resume_can_be_retried_after_the_native_pty_is_already_closed
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      focus = InteractiveFocusDouble.new
      focus.end_result = { "status" => "failed", "message" => "dashboard RPC could not resume" }
      controller = Meringue::Workspace::Controller.new(
        editor_launcher: @editor,
        focus_session_service: focus,
        interactive_session_factory: lambda { |command:, env:|
          session = WorkspaceSupport::FakeTerminalSession.new
          @sessions << session
          session
        }
      )
      agent = worker_agent(workspace_path: workspace, **{ "harness" => "pi" })
      controller.open_workspace(agent: agent)

      failed = controller.close_workspace(agent: agent)
      assert_equal "failed", failed.fetch("status")
      assert_equal 1, @sessions.last.closes
      refute controller.agent_interactive?(agent: agent)

      focus.end_result = nil
      retried = controller.close_workspace(agent: agent)
      assert_equal "closed", retried.fetch("status")
      assert_equal "Resumed the dashboard session.", retried.fetch("message")
      assert_equal [agent.fetch("id"), agent.fetch("id")], focus.ended
      assert_equal 1, @sessions.last.closes, "retrying ownership must not signal the closed PTY again"
    ensure
      controller&.close
    end
  end

  def test_native_launch_failure_closes_the_pty_and_returns_ownership_exactly_once
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      focus = InteractiveFocusDouble.new
      launch = FailedInteractiveLaunch.new
      controller = Meringue::Workspace::Controller.new(
        editor_launcher: @editor,
        focus_session_service: focus,
        interactive_session_factory: ->(command:, env:) { launch }
      )
      agent = worker_agent(workspace_path: workspace, **{ "harness" => "pi" })

      result = controller.open_workspace(agent: agent)

      assert_equal "failed", result.fetch("status")
      assert_equal "native Pi could not launch", result.fetch("message")
      assert_equal 1, launch.closes
      assert_empty focus.started
      assert_equal [agent.fetch("id")], focus.ended
      refute controller.agent_interactive?(agent: agent)
    ensure
      controller&.close
    end
  end

  def test_native_launch_failure_surfaces_a_failed_dashboard_ownership_rollback
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      focus = InteractiveFocusDouble.new
      focus.end_result = { "status" => "failed", "message" => "dashboard RPC could not resume" }
      launch = FailedInteractiveLaunch.new
      controller = Meringue::Workspace::Controller.new(
        editor_launcher: @editor,
        focus_session_service: focus,
        interactive_session_factory: ->(command:, env:) { launch }
      )

      result = controller.open_workspace(agent: worker_agent(workspace_path: workspace, **{ "harness" => "pi" }))

      assert_equal "failed", result.fetch("status")
      assert_equal "dashboard RPC could not resume", result.fetch("message")
      assert_equal 1, launch.closes
      assert_equal 1, focus.ended.length
    ensure
      controller&.close
    end
  end

  def test_open_workspace_is_rejected_when_the_worktree_is_gone
    with_workspace_tmpdir do |tmp|
      controller = build_controller

      result = controller.open_workspace(agent: worker_agent(workspace_path: File.join(tmp, "removed")))

      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("message"), "is missing"
    ensure
      controller&.close
    end
  end

  def test_open_terminal_starts_a_session_and_sizes_the_screen
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller(output: "hello world\r\n")
      agent = worker_agent(workspace_path: workspace)

      result = controller.open_terminal(agent: agent, rows: 12, columns: 40)

      assert_equal "active", result.fetch("status")
      assert_equal([{ "workspace_path" => workspace, "rows" => 12, "columns" => 40 }], @sessions.first.starts)

      snapshot = controller.terminal_snapshot(agent: agent)
      assert_equal ["hello world", ""], snapshot.fetch("lines")
      assert_equal [[["hello world", nil]], []], snapshot.fetch("styled_lines")
      assert_equal [1, 0], snapshot.fetch("cursor")
      assert_equal "running", snapshot.fetch("status")
      assert_equal 4242, snapshot.fetch("pid")
      assert_equal workspace, snapshot.fetch("workspace_path")
      assert_equal 1, snapshot.fetch("revision")
      refute snapshot.key?("notice")
    ensure
      controller&.close
    end
  end

  def test_terminal_snapshot_accumulates_chunked_output_and_bumps_the_revision
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller
      agent = worker_agent(workspace_path: workspace)
      controller.open_terminal(agent: agent, rows: 6, columns: 20)

      @sessions.first.feed_output("first line\r\n")
      first = controller.terminal_snapshot(agent: agent)
      @sessions.first.feed_output("second ")
      second = controller.terminal_snapshot(agent: agent)
      @sessions.first.feed_output("line\r\n")
      third = controller.terminal_snapshot(agent: agent)

      assert_equal ["first line", ""], first.fetch("lines")
      assert_equal ["first line", "second"], second.fetch("lines")
      assert_equal ["first line", "second line", ""], third.fetch("lines")
      assert_operator third.fetch("revision"), :>, first.fetch("revision")
    ensure
      controller&.close
    end
  end

  def test_terminal_snapshot_reports_an_exited_shell_without_deleting_state
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller
      agent = worker_agent(workspace_path: workspace)
      controller.open_terminal(agent: agent)
      @sessions.first.exit!(exitstatus: 2)

      snapshot = controller.terminal_snapshot(agent: agent)

      assert_equal "exited", snapshot.fetch("status")
      assert_equal(
        "Workspace shell exited with status 2. Switch views to start a new shell.",
        snapshot.fetch("notice")
      )
      refute_nil controller.send(:terminal_manager).fetch(agent)
    ensure
      controller&.close
    end
  end

  def test_terminal_snapshot_without_a_session_reports_an_error
    controller = build_controller

    snapshot = controller.terminal_snapshot(agent: worker_agent)

    assert_equal [], snapshot.fetch("lines")
    assert_equal "Workspace terminal is not running. Switch views to restart it.", snapshot.fetch("error")
  ensure
    controller&.close
  end

  def test_keys_and_pastes_are_forwarded_to_the_running_shell
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller
      agent = worker_agent(workspace_path: workspace)
      controller.open_terminal(agent: agent)

      assert_equal({ "status" => "written", "bytes" => 3 }, controller.handle_terminal_key(key: "ls\r", agent: agent))
      assert_equal({ "status" => "written", "bytes" => 4 }, controller.handle_terminal_key(key: { "type" => "paste", "text" => "a\r\nb" }, agent: agent))
      assert_equal({ "status" => "ignored" }, controller.handle_terminal_key(key: { "type" => "mouse", "kind" => "wheel_up" }, agent: agent))
      assert_equal({ "status" => "ignored" }, controller.handle_terminal_key(key: { "type" => "paste", "text" => "" }, agent: agent))

      assert_equal ["ls\r", "a\n\nb"], @sessions.first.writes
    ensure
      controller&.close
    end
  end

  def test_keys_are_not_forwarded_when_the_shell_is_gone
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller
      agent = worker_agent(workspace_path: workspace)
      controller.open_terminal(agent: agent)
      @sessions.first.exit!

      result = controller.handle_terminal_key(key: "ls\r", agent: agent)

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), "Switch back to the terminal view to restart it."
      assert_empty @sessions.first.writes
    ensure
      controller&.close
    end
  end

  def test_resize_forwards_to_the_session_and_the_screen
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller(output: "abc\r\n")
      agent = worker_agent(workspace_path: workspace)
      controller.open_terminal(agent: agent, rows: 10, columns: 30)

      result = controller.resize_terminal(agent: agent, rows: 20, columns: 60)

      assert_equal({ "status" => "resized", "rows" => 20, "columns" => 60 }, result)
      assert_includes @sessions.first.resizes, [20, 60]
      controller.terminal_snapshot(agent: agent)
      assert_equal ["abc", ""], controller.terminal_snapshot(agent: agent).fetch("lines")
    ensure
      controller&.close
    end
  end

  def test_resize_without_a_session_fails_in_place
    controller = build_controller

    result = controller.resize_terminal(agent: worker_agent, rows: 20, columns: 60)

    assert_equal "failed", result.fetch("status")
    assert_includes result.fetch("message"), "cannot be resized"
  ensure
    controller&.close
  end

  def test_open_editor_delegates_to_the_editor_launcher
    controller = build_controller
    agent = worker_agent

    result = controller.open_editor(agent: agent)

    assert_equal "opened", result.fetch("status")
    assert_equal [agent], @editor.opened
  ensure
    controller&.close
  end

  def test_close_terminal_drops_the_session_and_its_screen
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller
      agent = worker_agent(workspace_path: workspace)
      controller.open_terminal(agent: agent)
      @sessions.first.feed_output("stale output\r\n")
      assert_equal ["stale output", ""], controller.terminal_snapshot(agent: agent).fetch("lines")

      assert_equal "closed", controller.close_terminal(agent: agent).fetch("status")
      assert_equal 1, @sessions.first.closes

      controller.open_terminal(agent: agent)
      @sessions.last.feed_output("fresh output\r\n")
      snapshot = controller.terminal_snapshot(agent: agent)

      assert_equal ["fresh output", ""], snapshot.fetch("lines")
    ensure
      controller&.close
    end
  end

  def test_restarting_a_dead_shell_clears_the_previous_screen
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller
      agent = worker_agent(workspace_path: workspace)
      controller.open_terminal(agent: agent, rows: 8, columns: 30)
      @sessions.first.feed_output("before exit\r\n")
      assert_equal ["before exit", ""], controller.terminal_snapshot(agent: agent).fetch("lines")
      @sessions.first.exit!

      controller.open_terminal(agent: agent, rows: 8, columns: 30)
      @sessions.first.feed_output("after restart\r\n")

      assert_equal ["after restart", ""], controller.terminal_snapshot(agent: agent).fetch("lines")
      assert_equal 2, @sessions.first.starts.length
      assert_equal 1, @sessions.length
    ensure
      controller&.close
    end
  end

  def test_close_stops_every_terminal
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      controller = build_controller
      controller.open_terminal(agent: worker_agent(id: "P1-I1-W1", workspace_path: workspace))
      controller.open_terminal(agent: worker_agent(id: "P1-I1-W2", workspace_path: workspace))

      assert_equal(
        { "status" => "closed", "message" => "Stopped 2 workspace terminals." },
        controller.close
      )
      assert_equal [1, 1], @sessions.map(&:closes)
    end
  end

  def test_from_config_builds_real_adapters_without_starting_anything
    config = WorkspaceSupport::StubConfig.new(
      "workspace" => { "shell_command" => ["/bin/dash"], "editor_command" => ["code"], "editor_args" => ["."] }
    )

    controller = Meringue::Workspace::Controller.from_config(config, env: { "PATH" => "" })

    assert_instance_of Meringue::Workspace::TerminalManager, controller.send(:terminal_manager)
    assert_instance_of Meringue::Workspace::EditorLauncher, controller.send(:editor_launcher)
    assert_equal(
      { "status" => "closed", "message" => "Stopped 0 workspace terminals." },
      controller.close
    )
  end

  private

  def build_controller(output: "")
    Meringue::Workspace::Controller.new(
      terminal_manager: Meringue::Workspace::TerminalManager.new(
        session_factory: lambda {
          session = WorkspaceSupport::FakeTerminalSession.new(output: output)
          @sessions << session
          session
        }
      ),
      editor_launcher: @editor
    )
  end
end
