# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# No shell is ever started here. A PTY double records the exact spawn arguments
# TerminalSession built, and buffer behavior is exercised directly.
class WorkspaceTerminalSessionTest < Minitest::Test
  include WorkspaceSupport

  def test_builds_a_literal_pty_buffer_for_a_focused_harness_command
    with_workspace_tmpdir do |tmp|
      agent_cli = stub_executable(File.join(tmp, "bin", "agent-cli"))
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      pty = WorkspaceSupport::RecordingPty.new
      session = Meringue::Workspace::TerminalSession.new(
        command: [agent_cli, "--session", File.join(tmp, "session.jsonl")],
        env: { "PATH" => File.join(tmp, "bin") },
        pty: pty
      )

      result = session.start(workspace_path: workspace, rows: 32, columns: 120)

      assert_equal [agent_cli, "--session", File.join(tmp, "session.jsonl")], pty.last_call.fetch("argv")
      assert_equal({ chdir: workspace }, pty.last_call.fetch("options"))
      assert_equal "failed", result.fetch("status")
    end
  end

  def test_builds_the_pty_spawn_call_from_the_configured_shell_command
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "bin", "fake shell"))
      workspace = File.join(tmp, "work space")
      FileUtils.mkdir_p(workspace)
      pty = WorkspaceSupport::RecordingPty.new
      session = Meringue::Workspace::TerminalSession.new(
        command: [shell, "-i", "-l"],
        env: { "PATH" => File.join(tmp, "bin"), "TERM" => "dumb" },
        pty: pty
      )

      result = session.start(workspace_path: workspace, rows: 40, columns: 100)

      assert_equal 1, pty.calls.length
      assert_equal [shell, "-i", "-l"], pty.last_call.fetch("argv")
      assert_equal({ chdir: workspace }, pty.last_call.fetch("options"))
      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), "Could not start the workspace terminal in #{workspace}:"
    end
  end

  def test_terminal_environment_scrubs_inherited_agent_session_variables_for_every_harness
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "sh-stub"))
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      pty = WorkspaceSupport::RecordingPty.new
      session = Meringue::Workspace::TerminalSession.new(
        command: [shell],
        env: {
          "PATH" => "",
          "PI_SESSION_ID" => "pi-parent",
          "PI_MODEL" => "pi-model",
          "CLAUDECODE" => "1",
          "CLAUDE_CODE_SESSION_ID" => "claude-parent",
          "CLAUDE_PID" => "123",
          "API_TOKEN" => "keep-me",
          "SHELL" => "/bin/zsh"
        },
        pty: pty,
        session_environment_patterns: Meringue::Harness::Registry.managed_session_environment_patterns
      )

      session.start(workspace_path: workspace)
      environment = pty.last_call.fetch("env")

      assert_nil environment.fetch("PI_SESSION_ID")
      assert_nil environment.fetch("PI_MODEL")
      assert_nil environment.fetch("CLAUDECODE")
      assert_nil environment.fetch("CLAUDE_CODE_SESSION_ID")
      assert_nil environment.fetch("CLAUDE_PID")
      assert_equal "keep-me", environment.fetch("API_TOKEN")
      assert_equal "xterm-256color", environment.fetch("TERM")
      assert_equal "truecolor", environment.fetch("COLORTERM")
      assert_equal workspace, environment.fetch("MERINGUE_WORKSPACE")
      assert_equal "/bin/zsh", environment.fetch("SHELL")
    end
  end

  def test_default_shell_command_prefers_meringue_shell_then_shell
    with_workspace_tmpdir do |tmp|
      preferred = stub_executable(File.join(tmp, "bin", "preferred-shell"))
      stub_executable(File.join(tmp, "bin", "fallback-shell"))
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      pty = WorkspaceSupport::RecordingPty.new
      session = Meringue::Workspace::TerminalSession.new(
        env: { "PATH" => File.join(tmp, "bin"), "MERINGUE_SHELL" => "preferred-shell", "SHELL" => "fallback-shell" },
        pty: pty
      )

      session.start(workspace_path: workspace)

      assert_equal [preferred], pty.last_call.fetch("argv")
    end
  end

  def test_missing_or_unusable_workspace_is_rejected_without_touching_the_pty
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "sh-stub"))
      pty = WorkspaceSupport::RecordingPty.new
      session = Meringue::Workspace::TerminalSession.new(command: [shell], env: { "PATH" => "" }, pty: pty)

      blank = session.start(workspace_path: "  ")
      assert_equal "rejected", blank.fetch("status")
      assert_equal "This worker has no assigned workspace for its terminal.", blank.fetch("message")

      missing = session.start(workspace_path: File.join(tmp, "gone"))
      assert_equal "rejected", missing.fetch("status")
      assert_includes missing.fetch("message"), "Worker workspace is missing or is not a directory:"

      assert_empty pty.calls
    end
  end

  def test_missing_shell_executable_is_reported_without_touching_the_pty
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      pty = WorkspaceSupport::RecordingPty.new
      session = Meringue::Workspace::TerminalSession.new(
        command: ["not-an-installed-shell"],
        env: { "PATH" => File.join(tmp, "empty-bin") },
        pty: pty
      )

      result = session.start(workspace_path: workspace)

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), '"not-an-installed-shell" was not found or is not executable'
      assert_empty pty.calls
    end
  end

  def test_invalid_shell_configuration_is_rejected
    with_workspace_tmpdir do |tmp|
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)
      session = Meringue::Workspace::TerminalSession.new(command: [""], env: { "PATH" => "" })

      assert_equal "workspace shell_command cannot be empty", session.configuration_error
      result = session.start(workspace_path: workspace)

      assert_equal "rejected", result.fetch("status")
      assert_includes result.fetch("message"), "Terminal configuration is invalid: workspace shell_command cannot be empty."
      assert_includes result.fetch("message"), "[workspace] shell_command"
      assert_equal "failed", session.status.fetch("state")
    end
  end

  def test_operations_on_a_stopped_session_fail_in_place
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "sh-stub"))
      session = Meringue::Workspace::TerminalSession.new(command: [shell], env: { "PATH" => "" }, pty: WorkspaceSupport::RecordingPty.new)

      refute session.alive?
      assert_equal "failed", session.write("ls\n").fetch("status")
      assert_includes session.write("ls\n").fetch("message"), "Workspace terminal is not running."
      assert_equal "failed", session.resize(rows: 10, columns: 20).fetch("status")
      assert_includes session.resize(rows: 10, columns: 20).fetch("message"), "cannot be resized"
      assert_equal "", session.drain_output
      assert_equal "closed", session.close.fetch("status")
      assert_equal "closed", session.close.fetch("status")
    end
  end

  def test_write_of_empty_input_is_a_no_op
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "sh-stub"))
      session = Meringue::Workspace::TerminalSession.new(command: [shell], env: { "PATH" => "" }, pty: WorkspaceSupport::RecordingPty.new)

      result = session.write("")

      assert_equal "active", result.fetch("status")
      assert_equal "No terminal input to send.", result.fetch("message")
    end
  end

  def test_scrollback_transcript_is_bounded_and_survives_draining
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "sh-stub"))
      session = Meringue::Workspace::TerminalSession.new(
        command: [shell], env: { "PATH" => "" }, max_buffer_bytes: 16, pty: WorkspaceSupport::RecordingPty.new
      )

      session.send(:append_output, "0123456789")
      assert_equal "0123456789", session.transcript

      session.send(:append_output, "abcdefghij")
      assert_equal 16, session.transcript.bytesize
      assert_equal "456789abcdefghij", session.transcript

      drained = session.drain_output
      assert_equal "456789abcdefghij", drained
      assert_equal "", session.drain_output, "drained bytes are handed out only once"
      assert_equal "456789abcdefghij", session.transcript, "the transcript is kept for redraws"

      session.send(:append_output, "XY")
      assert_equal "XY", session.drain_output
      assert_equal "6789abcdefghijXY", session.transcript
    end
  end

  def test_chunked_output_is_appended_in_order
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "sh-stub"))
      session = Meringue::Workspace::TerminalSession.new(
        command: [shell], env: { "PATH" => "" }, max_buffer_bytes: 4096, pty: WorkspaceSupport::RecordingPty.new
      )
      multibyte = "λ→🎉 done\r\n"

      multibyte.b.each_byte { |byte| session.send(:append_output, byte.chr) }

      transcript = session.transcript
      assert_equal multibyte.b, transcript
      assert_equal multibyte, transcript.dup.force_encoding(Encoding::UTF_8)
    end
  end

  def test_non_positive_buffer_size_degrades_to_a_configuration_error
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "sh-stub"))
      workspace = File.join(tmp, "worktree")
      FileUtils.mkdir_p(workspace)

      session = Meringue::Workspace::TerminalSession.new(command: [shell], env: { "PATH" => "" }, max_buffer_bytes: 0)

      assert_equal "workspace terminal_buffer_bytes must be a positive integer", session.configuration_error
      assert_equal "rejected", session.start(workspace_path: workspace).fetch("status")
    end
  end

  def test_status_reports_a_new_session_as_not_running
    with_workspace_tmpdir do |tmp|
      shell = stub_executable(File.join(tmp, "sh-stub"))
      session = Meringue::Workspace::TerminalSession.new(command: [shell], env: { "PATH" => "" }, pty: WorkspaceSupport::RecordingPty.new)

      status = session.status

      assert_equal "new", status.fetch("state")
      refute status.fetch("alive")
      refute status.key?("pid")
      refute status.key?("workspace_path")
    end
  end

  def test_from_config_reads_shell_command_and_buffer_size
    config = WorkspaceSupport::StubConfig.new(
      "workspace" => { "shell_command" => ["/bin/zsh", "-l"], "terminal_buffer_bytes" => 2048 }
    )

    session = Meringue::Workspace::TerminalSession.from_config(config, env: { "PATH" => "" })

    assert_equal ["/bin/zsh", "-l"], session.send(:command).argv
    assert_equal 2048, session.send(:max_buffer_bytes)

    defaults = Meringue::Workspace::TerminalSession.from_config(WorkspaceSupport::StubConfig.new, env: { "PATH" => "", "SHELL" => "/bin/sh" })
    assert_equal ["/bin/sh"], defaults.send(:command).argv
    assert_equal Meringue::Workspace::TerminalSession::DEFAULT_BUFFER_BYTES, defaults.send(:max_buffer_bytes)
  end
end
