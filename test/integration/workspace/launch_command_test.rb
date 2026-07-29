# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# LaunchCommand turns configured shell/editor commands into argv. Nothing here
# executes a command; the assertions are on the exact argv and display strings.
class WorkspaceLaunchCommandTest < Minitest::Test
  include WorkspaceSupport

  def test_string_commands_are_split_without_shell_evaluation
    command = Meringue::Workspace::LaunchCommand.parse("code --wait --new-window", default: "vi")

    assert_equal %w[code --wait --new-window], command.argv
    assert_equal "code", command.executable
    assert_equal "code --wait --new-window", command.display
  end

  def test_quoted_strings_keep_arguments_with_spaces_together
    command = Meringue::Workspace::LaunchCommand.parse("'/opt/my editor/bin/edit' --wait", default: "vi")

    assert_equal ["/opt/my editor/bin/edit", "--wait"], command.argv
    assert_equal "/opt/my\\ editor/bin/edit --wait", command.display
  end

  def test_shell_metacharacters_are_arguments_not_operators
    command = Meringue::Workspace::LaunchCommand.parse("echo hi > /tmp/out ; rm -rf /", default: "vi")

    assert_equal ["echo", "hi", ">", "/tmp/out", ";", "rm", "-rf", "/"], command.argv
  end

  def test_array_commands_are_used_verbatim
    command = Meringue::Workspace::LaunchCommand.parse(["/bin/zsh", "-l"], default: "sh")

    assert_equal ["/bin/zsh", "-l"], command.argv
    assert_equal ["/bin/zsh", "-l"], command.source
  end

  def test_nil_uses_the_default_command
    assert_equal ["nvim"], Meringue::Workspace::LaunchCommand.parse(nil, default: ["nvim"]).argv
    assert_equal %w[code -w], Meringue::Workspace::LaunchCommand.parse(nil, default: "code -w").argv
  end

  def test_with_arguments_appends_and_quotes_paths_containing_spaces
    command = Meringue::Workspace::LaunchCommand.parse("code --wait", default: "vi")

    extended = command.with_arguments(["/tmp/work space/project", "."])

    assert_equal ["code", "--wait", "/tmp/work space/project", "."], extended.argv
    assert_equal "code --wait /tmp/work\\ space/project .", extended.display
    assert_equal %w[code --wait], command.argv, "with_arguments must not mutate the receiver"
  end

  def test_invalid_commands_are_rejected_with_labeled_messages
    assert_equal(
      "workspace shell_command cannot be empty",
      assert_raises(ArgumentError) { parse("", label: "workspace shell_command") }.message
    )
    assert_equal(
      "workspace shell_command cannot be empty",
      assert_raises(ArgumentError) { parse([], label: "workspace shell_command") }.message
    )
    assert_equal(
      "workspace editor_command must be a string or an array of strings",
      assert_raises(ArgumentError) { parse(["code", 1], label: "workspace editor_command") }.message
    )
    assert_equal(
      "workspace editor_command must be a string or an array of strings",
      assert_raises(ArgumentError) { parse(42, label: "workspace editor_command") }.message
    )
    assert_equal(
      "workspace editor_command cannot contain empty arguments",
      assert_raises(ArgumentError) { parse(["code", ""], label: "workspace editor_command") }.message
    )
    assert_equal(
      "workspace editor_command cannot contain null bytes",
      assert_raises(ArgumentError) { parse(["code", "a\u0000b"], label: "workspace editor_command") }.message
    )
    assert_match(
      /\Ainvalid workspace shell_command: /,
      assert_raises(ArgumentError) { parse("zsh 'unbalanced", label: "workspace shell_command") }.message
    )
  end

  def test_with_arguments_rejects_unsafe_values
    command = Meringue::Workspace::LaunchCommand.parse(["code"], default: "vi")

    assert_equal(
      "command arguments must be strings",
      assert_raises(ArgumentError) { command.with_arguments([1]) }.message
    )
    assert_equal(
      "command arguments cannot contain null bytes",
      assert_raises(ArgumentError) { command.with_arguments(["a\u0000b"]) }.message
    )
  end

  def test_executable_path_finds_absolute_and_path_entries
    with_workspace_tmpdir do |tmp|
      bin_directory = File.join(tmp, "bin dir")
      editor = stub_executable(File.join(bin_directory, "my editor"))
      not_executable = File.join(bin_directory, "readme")
      File.write(not_executable, "text")

      absolute = Meringue::Workspace::LaunchCommand.parse([editor], default: "vi")
      assert_equal editor, absolute.executable_path(cwd: tmp, path: "")

      on_path = Meringue::Workspace::LaunchCommand.parse(["my editor"], default: "vi")
      assert_equal editor, on_path.executable_path(cwd: tmp, path: bin_directory)
      assert_nil on_path.executable_path(cwd: tmp, path: File.join(tmp, "nowhere"))

      relative = Meringue::Workspace::LaunchCommand.parse(["./bin dir/my editor"], default: "vi")
      assert_equal editor, relative.executable_path(cwd: tmp, path: "")

      assert_nil Meringue::Workspace::LaunchCommand.parse(["readme"], default: "vi").executable_path(cwd: tmp, path: bin_directory)
      assert_nil Meringue::Workspace::LaunchCommand.parse(["missing-binary-xyz"], default: "vi").executable_path(cwd: tmp, path: bin_directory)
    end
  end

  private

  def parse(value, label:)
    Meringue::Workspace::LaunchCommand.parse(value, default: "vi", label: label)
  end
end
