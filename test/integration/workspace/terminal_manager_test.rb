# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# TerminalManager keeps one shell session per worker. A session double records
# what it was asked to do, so nothing is spawned.
class WorkspaceTerminalManagerTest < Minitest::Test
  include WorkspaceSupport

  def test_starts_one_session_per_worker_in_the_resolved_workspace
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      sessions = []
      manager = Meringue::Workspace::TerminalManager.new(session_factory: -> { session = WorkspaceSupport::FakeTerminalSession.new; sessions << session; session })
      agent = worker_agent(workspace_path: workspace)

      result = manager.start(agent, rows: 30, columns: 90)

      assert_equal "active", result.fetch("status")
      assert_equal "Started terminal in #{workspace}.", result.fetch("message")
      assert_equal 1, sessions.length
      assert_equal([{ "workspace_path" => workspace, "rows" => 30, "columns" => 90 }], sessions.first.starts)

      manager.start(agent, rows: 30, columns: 90)
      assert_equal 1, sessions.length, "an existing session is reused for the same worker"
      assert_equal 2, sessions.first.starts.length

      assert_same sessions.first, manager.fetch(agent)
      assert_same sessions.first, manager.fetch("P1-I1-W1")
      assert_nil manager.fetch("P1-I1-W9")
    end
  end

  def test_second_worker_gets_its_own_session
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      manager = Meringue::Workspace::TerminalManager.new(session_factory: -> { WorkspaceSupport::FakeTerminalSession.new })

      manager.start(worker_agent(id: "P1-I1-W1", workspace_path: workspace))
      manager.start(worker_agent(id: "P1-I1-W2", workspace_path: workspace))

      assert_equal %w[P1-I1-W1 P1-I1-W2], manager.statuses.keys.sort
      refute_same manager.fetch("P1-I1-W1"), manager.fetch("P1-I1-W2")
      assert_equal "running", manager.statuses.fetch("P1-I1-W1").fetch("state")
    end
  end

  def test_recovered_workspace_note_is_prefixed_to_the_start_message
    with_workspace_tmpdir do |tmp|
      worktree = File.join(tmp, "worktree")
      FileUtils.mkdir_p(worktree)
      manager = Meringue::Workspace::TerminalManager.new(session_factory: -> { WorkspaceSupport::FakeTerminalSession.new })
      agent = worker_agent(
        workspace_path: File.join(worktree, "gone"),
        plan: { "project_root" => File.join(tmp, "project"), "worktree_root_path" => worktree }
      )

      result = manager.start(agent)

      assert_equal "active", result.fetch("status")
      assert_equal(
        "Using #{worktree} because the recorded workspace #{File.join(worktree, "gone")} is missing. Started terminal in #{worktree}.",
        result.fetch("message")
      )
    end
  end

  def test_missing_workspace_is_rejected_and_keeps_the_note
    with_workspace_tmpdir do |tmp|
      manager = Meringue::Workspace::TerminalManager.new(session_factory: -> { WorkspaceSupport::FakeTerminalSession.new })

      result = manager.start(worker_agent(workspace_path: File.join(tmp, "removed")))

      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("message"), "is missing"
    end
  end

  def test_non_worker_agents_cannot_open_a_terminal
    manager = Meringue::Workspace::TerminalManager.new(session_factory: -> { WorkspaceSupport::FakeTerminalSession.new })

    %w[head kernel].each do |type|
      result = manager.start({ "id" => "H1", "type" => type })

      assert_equal "rejected", result.fetch("status")
      assert_equal "Select a worker before opening a terminal.", result.fetch("message")
    end

    assert_nil manager.session_for({ "id" => "H1", "type" => "head" })
    assert_nil manager.session_for({ "id" => "  ", "type" => "worker" })
    assert_empty manager.statuses
  end

  def test_failed_session_start_is_returned_unchanged
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      failure = { "status" => "failed", "message" => "Could not start the workspace terminal." }
      manager = Meringue::Workspace::TerminalManager.new(session_factory: -> { WorkspaceSupport::FakeTerminalSession.new(start_status: failure) })

      assert_equal failure, manager.start(worker_agent(workspace_path: workspace))
    end
  end

  def test_close_and_close_all_report_what_was_stopped
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      sessions = []
      manager = Meringue::Workspace::TerminalManager.new(session_factory: -> { session = WorkspaceSupport::FakeTerminalSession.new; sessions << session; session })

      assert_equal(
        { "status" => "closed", "message" => "No workspace terminal was running." },
        manager.close("P1-I1-W1")
      )

      manager.start(worker_agent(id: "P1-I1-W1", workspace_path: workspace))
      assert_equal "closed", manager.close("P1-I1-W1").fetch("status")
      assert_equal 1, sessions.first.closes
      assert_nil manager.fetch("P1-I1-W1")

      manager.start(worker_agent(id: "P1-I1-W2", workspace_path: workspace))
      manager.start(worker_agent(id: "P1-I1-W3", workspace_path: workspace))
      assert_equal(
        { "status" => "closed", "message" => "Stopped 2 workspace terminals." },
        manager.close_all
      )
      assert_equal(
        { "status" => "closed", "message" => "Stopped 0 workspace terminals." },
        manager.close_all
      )
      assert_equal 1, sessions.last.closes
    end
  end

  def test_close_all_reports_cleanup_failures
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      failing_session = Class.new(WorkspaceSupport::FakeTerminalSession) do
        def close = { "status" => "failed", "message" => "Terminal cleanup failed." }
      end
      manager = Meringue::Workspace::TerminalManager.new(session_factory: -> { failing_session.new })

      manager.start(worker_agent(workspace_path: workspace))

      assert_equal(
        { "status" => "failed", "message" => "Terminal cleanup failed." },
        manager.close_all
      )
    end
  end

  def test_from_config_builds_sessions_with_the_configured_shell
    config = WorkspaceSupport::StubConfig.new(
      "workspace" => { "shell_command" => ["/bin/dash"], "terminal_buffer_bytes" => 512 }
    )

    manager = Meringue::Workspace::TerminalManager.from_config(config, env: { "PATH" => "" })
    session = manager.session_for(worker_agent)

    assert_instance_of Meringue::Workspace::TerminalSession, session
    assert_equal ["/bin/dash"], session.send(:command).argv
    assert_equal 512, session.send(:max_buffer_bytes)
  end
end
