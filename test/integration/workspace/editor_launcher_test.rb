# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# The editor is never really launched: the spawn call is recorded so the exact
# argv, environment, and chdir can be asserted.
class WorkspaceEditorLauncherTest < Minitest::Test
  include WorkspaceSupport

  def test_builds_argv_with_resolved_executable_workspace_arguments_and_chdir
    with_workspace_tmpdir do |tmp|
      editor = stub_executable(File.join(tmp, "bin", "my editor"))
      workspace = File.join(tmp, "workspaces", "project", "task with space")
      FileUtils.mkdir_p(workspace)
      agent = worker_agent(workspace_path: workspace)
      launcher = WorkspaceSupport::RecordingEditorLauncher.succeeding(
        command: [editor, "--wait"],
        arguments: ["."],
        env: { "PATH" => File.join(tmp, "bin") }
      )

      result = launcher.open(agent)

      assert_equal "opened", result.fetch("status")
      assert_equal "Opened P1-I1-W1 in the editor.", result.fetch("message")
      assert_equal 1, launcher.spawn_calls.length
      assert_equal [editor, "--wait", "."], launcher.last_spawn.fetch("argv")
      assert_equal({ "PATH" => File.join(tmp, "bin") }, launcher.last_spawn.fetch("env"))
      assert_equal(
        { chdir: workspace, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true },
        launcher.last_spawn.fetch("options")
      )
    end
  end

  def test_resolves_the_executable_from_path_and_keeps_configured_arguments
    with_workspace_tmpdir do |tmp|
      bin = File.join(tmp, "bin")
      editor = stub_executable(File.join(bin, "codeish"))
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      launcher = WorkspaceSupport::RecordingEditorLauncher.succeeding(
        command: "codeish --new-window",
        arguments: ["--goto", "lib/meringue.rb"],
        env: { "PATH" => "#{File.join(tmp, "empty")}#{File::PATH_SEPARATOR}#{bin}" }
      )

      launcher.open(worker_agent(workspace_path: workspace))

      assert_equal [editor, "--new-window", "--goto", "lib/meringue.rb"], launcher.last_spawn.fetch("argv")
    end
  end

  def test_falls_back_to_the_worktree_root_recorded_in_the_workspace_plan
    with_workspace_tmpdir do |tmp|
      editor = stub_executable(File.join(tmp, "edit"))
      worktree = File.join(tmp, "worktree")
      FileUtils.mkdir_p(worktree)
      agent = worker_agent(
        workspace_path: File.join(worktree, "gone"),
        plan: { "project_root" => File.join(tmp, "project"), "worktree_root_path" => worktree }
      )
      launcher = WorkspaceSupport::RecordingEditorLauncher.succeeding(command: [editor], env: { "PATH" => "" })

      assert_equal "opened", launcher.open(agent).fetch("status")
      assert_equal worktree, launcher.last_spawn.fetch("options").fetch(:chdir)
    end
  end

  def test_default_command_comes_from_the_environment
    with_workspace_tmpdir do |tmp|
      editor = stub_executable(File.join(tmp, "bin", "envedit"))
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      launcher = WorkspaceSupport::RecordingEditorLauncher.succeeding(
        env: { "PATH" => File.join(tmp, "bin"), "MERINGUE_EDITOR" => "envedit", "VISUAL" => "visualedit", "EDITOR" => "vi" }
      )

      launcher.open(worker_agent(workspace_path: workspace))

      assert_equal [editor, "."], launcher.last_spawn.fetch("argv")
    end
  end

  def test_reports_immediate_editor_failure_with_the_command_and_workspace
    with_workspace_tmpdir do |tmp|
      editor = stub_executable(File.join(tmp, "broken editor"))
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      launcher = WorkspaceSupport::RecordingEditorLauncher.exiting(
        exitstatus: 3,
        command: [editor],
        env: { "PATH" => "" }
      )

      result = launcher.open(worker_agent(workspace_path: workspace))

      assert_equal "failed", result.fetch("status")
      displayed = Meringue::Workspace::LaunchCommand.new([editor]).display
      assert_includes result.fetch("message"), "Editor command #{displayed} exited immediately with status 3."
      assert_includes result.fetch("message"), "try it from #{workspace}"
    end
  end

  def test_missing_executable_is_reported_without_spawning
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      launcher = WorkspaceSupport::RecordingEditorLauncher.succeeding(
        command: ["definitely-not-installed-editor"],
        env: { "PATH" => File.join(tmp, "empty-bin") }
      )

      result = launcher.open(worker_agent(workspace_path: workspace))

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), '"definitely-not-installed-editor" was not found or is not executable'
      assert_empty launcher.spawn_calls
    end
  end

  def test_missing_workspace_is_rejected_without_spawning
    with_workspace_tmpdir do |tmp|
      editor = stub_executable(File.join(tmp, "edit"))
      launcher = WorkspaceSupport::RecordingEditorLauncher.succeeding(command: [editor], env: { "PATH" => "" })

      result = launcher.open(worker_agent(workspace_path: File.join(tmp, "removed-worktree")))

      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("message"), "is missing"
      assert_empty launcher.spawn_calls
    end
  end

  def test_invalid_configuration_is_rejected_with_config_guidance
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)

      launcher = Meringue::Workspace::EditorLauncher.new(command: [""], env: { "PATH" => "" })
      result = launcher.open(worker_agent(workspace_path: workspace))

      assert_equal "workspace editor_command cannot be empty", launcher.configuration_error
      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("message"), "Editor configuration is invalid: workspace editor_command cannot be empty."
      assert_includes result.fetch("message"), "[workspace] editor_command/editor_args"

      bad_arguments = Meringue::Workspace::EditorLauncher.new(command: ["code"], arguments: [1], env: { "PATH" => "" })
      assert_equal "workspace editor_args must be a string or an array of strings", bad_arguments.configuration_error
      assert_equal "rejected", bad_arguments.open(worker_agent(workspace_path: workspace)).fetch("status")
    end
  end

  def test_from_config_reads_the_workspace_section
    with_workspace_tmpdir do |tmp|
      editor = stub_executable(File.join(tmp, "bin", "confedit"))
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      config = WorkspaceSupport::StubConfig.new(
        "workspace" => { "editor_command" => ["confedit", "--wait"], "editor_args" => ["src"] }
      )

      launcher = Meringue::Workspace::EditorLauncher.from_config(config, env: { "PATH" => File.join(tmp, "bin") })

      assert_nil launcher.configuration_error
      assert_equal ["confedit", "--wait"], launcher.send(:command).argv
      assert_equal ["src"], launcher.send(:arguments)
      assert_equal editor, launcher.send(:command).executable_path(cwd: workspace, path: File.join(tmp, "bin"))

      defaults = Meringue::Workspace::EditorLauncher.from_config(WorkspaceSupport::StubConfig.new, env: { "PATH" => "" })
      assert_equal ["."], defaults.send(:arguments)
    end
  end
end
