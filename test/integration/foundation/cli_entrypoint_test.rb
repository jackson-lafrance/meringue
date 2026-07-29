# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"

# The CLI must answer version/help/fixture questions without booting a TUI,
# starting a harness process, or touching ~/.meringue.
class FoundationCliEntrypointTest < Minitest::Test
  def test_version_flags_print_the_version_and_succeed
    ["-v", "--version", "version"].each do |flag|
      status, stdout, stderr = FoundationSupport.run_cli(flag)

      assert_equal 0, status, "#{flag} should exit 0"
      assert_equal Meringue::VERSION, stdout.strip, "#{flag} should print the version"
      assert_empty stderr
    end
  end

  def test_help_flags_describe_the_commands_and_succeed
    ["-h", "--help", "help"].each do |flag|
      status, stdout, stderr = FoundationSupport.run_cli(flag)

      assert_equal 0, status, "#{flag} should exit 0"
      assert_empty stderr
      assert_includes stdout, "Meringue #{Meringue::VERSION}"
      assert_includes stdout, "Usage:"
      assert_includes stdout, "meringue tui"
      assert_includes stdout, "meringue demo"
      assert_includes stdout, "--version"
    end
  end

  def test_unknown_command_reports_on_stderr_and_fails
    status, stdout, stderr = FoundationSupport.run_cli("definitely-not-a-command")

    assert_equal 1, status
    assert_includes stderr, "Unknown command: definitely-not-a-command"
    assert_includes stdout, "Usage:"
  end

  def test_demo_state_prints_the_checked_in_fixture_as_json
    status, stdout, stderr = FoundationSupport.run_cli("demo-state")

    assert_equal 0, status
    assert_empty stderr

    parsed = JSON.parse(stdout)

    assert_kind_of Hash, parsed
    refute_empty parsed
  end

  def test_executable_entrypoint_reports_version_and_help
    bin = FoundationSupport.repo_path("bin", "meringue")

    assert File.file?(bin), "bin/meringue must exist"
    assert File.executable?(bin), "bin/meringue must be executable"

    status, stdout, stderr = FoundationSupport.run_ruby(bin, "--version")

    assert_equal 0, status
    assert_equal Meringue::VERSION, stdout.strip
    assert_empty stderr

    status, stdout, = FoundationSupport.run_ruby(bin, "--help")

    assert_equal 0, status
    assert_includes stdout, "Usage:"
  end

  def test_cli_help_does_not_write_state_files
    FoundationSupport.with_tmpdir do |dir|
      before = Dir.glob(File.join(dir, "**", "*"))

      status, = FoundationSupport.run_cli("--help")

      assert_equal 0, status
      assert_equal before, Dir.glob(File.join(dir, "**", "*"))
    end
  end
end
