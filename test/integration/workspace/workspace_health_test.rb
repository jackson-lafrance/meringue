# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Degraded workspace dependencies must turn into notices, never into deleted
# state or raised exceptions.
class WorkspaceHealthTest < Minitest::Test
  include WorkspaceSupport

  def test_clean_worktree_with_a_live_session_reports_no_workspace_problem
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      workspace = allocate_workspace(workspace_manager(tmp), project, task_title: "Healthy worker")
      session_file = File.join(tmp, "session.jsonl")
      File.write(session_file, "{}\n")
      agent = healthy_agent(workspace.fetch("workspace_path"), session_file)

      notices = Meringue::TUI::WorkspaceHealth.notices(agent)

      assert_empty notices
      assert_equal "", git_output(project, workspace.fetch("workspace_path"), "status", "--porcelain")
    end
  end

  def test_dirty_worktree_is_still_considered_healthy
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      workspace = allocate_workspace(workspace_manager(tmp), project, task_title: "Dirty worker")
      File.write(File.join(workspace.fetch("workspace_path"), "uncommitted.txt"), "work in progress\n")
      session_file = File.join(tmp, "session.jsonl")
      File.write(session_file, "{}\n")

      notices = Meringue::TUI::WorkspaceHealth.notices(healthy_agent(workspace.fetch("workspace_path"), session_file))

      refute_equal "", git_output(project, workspace.fetch("workspace_path"), "status", "--porcelain")
      assert_empty notices, "uncommitted work is not reported by WorkspaceHealth today"
    end
  end

  def test_missing_worktree_is_reported_without_losing_delivery_metadata
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = workspace_manager(tmp)
      workspace = allocate_workspace(manager, project, task_title: "Removed worker")
      workspace_path = workspace.fetch("workspace_path")
      session_file = File.join(tmp, "session.jsonl")
      File.write(session_file, "{}\n")
      assert manager.release_worker_workspace(workspace)
      refute Dir.exist?(workspace_path)

      notices = Meringue::TUI::WorkspaceHealth.notices(healthy_agent(workspace_path, session_file))

      assert_equal 1, notices.length
      notice = notices.first
      assert_equal "warning", notice.fetch("level")
      assert_equal "Worker worktree is unavailable: #{workspace_path}", notice.fetch("message")
      assert_includes notice.fetch("detail"), "Meringue kept the worker and delivery metadata"
    end
  end

  def test_agent_without_a_workspace_path_gets_an_informational_warning
    with_workspace_tmpdir do |tmp|
      session_file = File.join(tmp, "session.jsonl")
      File.write(session_file, "{}\n")

      notices = Meringue::TUI::WorkspaceHealth.notices(healthy_agent("", session_file))

      assert_equal ["Worker has no tracked workspace path."], notices.map { |notice| notice.fetch("message") }
      assert_equal ["warning"], notices.map { |notice| notice.fetch("level") }
    end
  end

  def test_dead_agent_process_is_reported_for_live_statuses_only
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      session_file = File.join(tmp, "session.jsonl")
      File.write(session_file, "{}\n")

      %w[queued working idle blocked].each do |status|
        agent = healthy_agent(workspace, session_file).merge("status" => status, "pid" => 0)
        messages = Meringue::TUI::WorkspaceHealth.notices(agent).map { |notice| notice.fetch("message") }

        assert_includes messages, "Worker agent process is not running."
      end

      %w[completed errored killed].each do |status|
        agent = healthy_agent(workspace, session_file).merge("status" => status, "pid" => 0)

        assert_empty Meringue::TUI::WorkspaceHealth.notices(agent)
      end
    end
  end

  def test_recovery_detail_depends_on_a_resumable_session_reference
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      session_file = File.join(tmp, "session.jsonl")
      File.write(session_file, "{}\n")

      with_session = healthy_agent(workspace, session_file).merge("status" => "working", "pid" => 0)
      process_notice = Meringue::TUI::WorkspaceHealth.notices(with_session).find do |notice|
        notice.fetch("message") == "Worker agent process is not running."
      end
      assert_equal "Meringue will try non-destructive session recovery during reconciliation.", process_notice.fetch("detail")

      without_session = {
        "id" => "P1-I1-W1", "type" => "worker", "status" => "working", "pid" => 0, "workspace_path" => workspace
      }
      messages = Meringue::TUI::WorkspaceHealth.notices(without_session)
      process_detail = messages.find { |notice| notice.fetch("message") == "Worker agent process is not running." }.fetch("detail")
      assert_equal "No resumable session reference is tracked; workspace and PR data remain available.", process_detail
      assert_includes messages.map { |notice| notice.fetch("message") }, "Worker has no resumable agent session history."
    end
  end

  def test_missing_session_file_is_reported_without_deleting_state
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      session_file = File.join(tmp, "removed-session.jsonl")

      notices = Meringue::TUI::WorkspaceHealth.notices(healthy_agent(workspace, session_file))

      assert_equal 1, notices.length
      assert_equal "Saved agent session history is unavailable: #{session_file}", notices.first.fetch("message")
      assert_includes notices.first.fetch("detail"), "no state was deleted"
    end
  end

  def test_live_process_is_not_reported_as_missing
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      session_file = File.join(tmp, "session.jsonl")
      File.write(session_file, "{}\n")
      agent = healthy_agent(workspace, session_file).merge("status" => "working", "pid" => Process.pid)

      assert_empty Meringue::TUI::WorkspaceHealth.notices(agent)
      refute Meringue::TUI::WorkspaceHealth.process_missing?(Process.pid)
      assert Meringue::TUI::WorkspaceHealth.process_missing?(0)
      assert Meringue::TUI::WorkspaceHealth.process_missing?(nil)
      assert Meringue::TUI::WorkspaceHealth.process_missing?("not-a-pid")
    end
  end

  def test_non_hash_agent_becomes_an_error_notice
    [nil, "P1-I1-W1", 42].each do |value|
      notices = Meringue::TUI::WorkspaceHealth.notices(value)

      assert_equal 1, notices.length
      assert_equal "error", notices.first.fetch("level")
      assert_equal "Worker record is unavailable.", notices.first.fetch("message")
      assert_includes notices.first.fetch("detail"), "select another worker"
    end
  end

  def test_command_unavailable_notices_name_the_configured_command
    configured = Meringue::TUI::WorkspaceHealth.command_unavailable("terminal", command: "/opt/bin/missing-shell")

    assert_equal "warning", configured.fetch("level")
    assert_equal "Terminal is unavailable.", configured.fetch("message")
    assert_includes configured.fetch("detail"), "Configured command was not found: /opt/bin/missing-shell"
    assert_includes configured.fetch("detail"), "left the worker workspace unchanged"

    blank = Meringue::TUI::WorkspaceHealth.command_unavailable("", command: "  ")
    assert_equal "Requested command is unavailable.", blank.fetch("message")
    assert_includes blank.fetch("detail"), "Configure a command and retry."
  end

  def test_live_status_helper_matches_only_running_statuses
    %w[queued working idle blocked].each do |status|
      assert Meringue::TUI::WorkspaceHealth.live_status?({ "status" => status })
    end
    %w[completed errored killed unknown].each do |status|
      refute Meringue::TUI::WorkspaceHealth.live_status?({ "status" => status })
    end
  end

  private

  def healthy_agent(workspace_path, session_file)
    {
      "id" => "P1-I1-W1",
      "type" => "worker",
      "status" => "completed",
      "pid" => Process.pid,
      "workspace_path" => workspace_path,
      "harness_session_file" => session_file,
      "harness_session_id" => "session-1"
    }
  end
end
