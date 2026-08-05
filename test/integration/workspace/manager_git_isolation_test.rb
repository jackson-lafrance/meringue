# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Worker provisioning must not depend on git's file-system monitor.
#
# With core.fsmonitor enabled, `git worktree add` runs `git reset --hard` internally, that reset
# starts a `git fsmonitor--daemon` for the brand new worktree, and it then blocks until the daemon
# answers its first query. A daemon that never answers hangs provisioning until Meringue's command
# timeout kills it, and the worker spawn fails. Meringue therefore disables the monitor for every
# git command it runs.
class WorkspaceManagerGitIsolationTest < Minitest::Test
  include WorkspaceSupport

  # Records the argv every git command was really spawned with.
  class RecordingManager < Meringue::Workspace::Manager
    def spawned_argvs
      @spawned_argvs ||= []
    end

    private

    def run_command(*argv, **options)
      result = super
      spawned_argvs << result.fetch("argv")
      result
    end
  end

  # Times out on the first git command of allocation instead of on `git worktree add`, so the
  # reported failure has to name the command that actually hung.
  class RevParseTimingOutManager < Meringue::Workspace::Manager
    private

    def run_command(*argv, **options)
      if argv.include?("rev-parse") && argv.include?("--show-toplevel")
        raise Meringue::Workspace::Manager::CommandTimeout.new(argv: argv, timeout: 0.5, stdout: "", stderr: "simulated hang")
      end

      super
    end
  end

  def test_every_git_command_disables_the_file_system_monitor
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = RecordingManager.new(root_path: File.join(tmp, "workspaces"))

      workspace = allocate_workspace(manager, project, task_title: "Disable the file system monitor")

      assert workspace.fetch("created"), "expected the worktree to be created: #{workspace.inspect}"
      refute_empty manager.spawned_argvs

      manager.spawned_argvs.each do |argv|
        assert_equal "git", argv.first
        assert_equal ["-c", "core.fsmonitor=false"], argv[1, 2],
                     "expected fsmonitor to be disabled for #{argv.join(" ")}"
      end
    end
  end

  def test_allocated_worktree_starts_no_file_system_monitor_daemon
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      # Reproduces the developer machine setup that caused the hang.
      git_output(project, project.fetch("project_root"), "config", "core.fsmonitor", "true")
      manager = workspace_manager(tmp)

      workspace = allocate_workspace(manager, project, task_title: "No monitor daemon please")

      assert workspace.fetch("created"), "expected the worktree to be created: #{workspace.inspect}"
      sockets = Dir.glob(File.join(project.fetch("project_root"), ".git", "worktrees", "*", "fsmonitor--daemon.ipc"))
      assert_empty sockets, "expected no fsmonitor daemon socket for a Meringue worktree"
    end
  end

  def test_timeout_names_the_git_command_that_hung
    with_workspace_tmpdir do |tmp|
      project = create_git_project(tmp)
      manager = RevParseTimingOutManager.new(root_path: File.join(tmp, "workspaces"))

      workspace = allocate_workspace(manager, project, task_title: "Hangs before the worktree add")

      refute workspace.fetch("created")
      assert workspace.fetch("timed_out")
      assert_includes workspace.fetch("errors"), "git rev-parse timed out after 0.5 seconds"
      refute_includes workspace.fetch("errors").join(" "), "git worktree add timed out"
    end
  end
end
