# frozen_string_literal: true

require "test_helper"
require "support/foundation_support"
require "stringio"
require "tmpdir"

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

  # Every other subcommand resolves the state path through State::Store
  # .default_path, which honours MERINGUE_STATE_PATH. The dashboard passed the
  # bare constant, so the env var silently did nothing for the one command that
  # is the whole product: it read and wrote ~/.meringue/state.json regardless,
  # and the schema migration then judged "is this a new install?" from a file
  # the user had pointed away from.
  def test_the_dashboard_honours_the_state_path_environment_variable
    elsewhere = File.join(Dir.tmpdir, "meringue-cli-state", "state.json")
    captured = nil
    cli = Meringue::CLI.new([], out: StringIO.new, err: StringIO.new)
    cli.define_singleton_method(:run_tui) { |**kwargs| captured = kwargs.fetch(:default_state_path) }

    shared = nil
    with_env("MERINGUE_STATE_PATH" => elsewhere) do
      cli.run
      shared = Meringue::State::Store.default_path
    end

    assert_equal elsewhere, captured
    assert_equal shared, captured, "the dashboard must resolve the same path every other command does"
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
      assert_includes stdout, "/reload"
      assert_includes stdout, "/update"
    end
  end

  def test_cli_reloads_through_the_lifecycle_manager_after_the_tui_returns
    FoundationSupport.with_tmpdir do |dir|
      lifecycle = Object.new
      lifecycle.define_singleton_method(:reload) do
        @reload_called = true
        { "status" => "reloaded" }
      end
      lifecycle.define_singleton_method(:reload_called?) { @reload_called == true }

      tui = Object.new
      tui.define_singleton_method(:run) { |**_options| :reload }

      with_replaced_new(Meringue::Lifecycle::Manager, lifecycle) do
        with_replaced_new(Meringue::TUI::App, tui) do
          status, stdout, stderr = FoundationSupport.run_cli(
            "tui",
            "--state", File.join(dir, "state.json"),
            "--config", File.join(dir, "config.toml")
          )

          assert_equal 0, status
          assert_empty stdout
          assert_empty stderr
        end
      end

      assert lifecycle.reload_called?, "the CLI should delegate the TUI reload sentinel"
    end
  end

  def test_cli_reports_a_failed_reload
    FoundationSupport.with_tmpdir do |dir|
      lifecycle = Object.new
      lifecycle.define_singleton_method(:reload) { { "status" => "failed", "message" => "reload unavailable" } }
      tui = Object.new
      tui.define_singleton_method(:run) { |**_options| :reload }

      with_replaced_new(Meringue::Lifecycle::Manager, lifecycle) do
        with_replaced_new(Meringue::TUI::App, tui) do
          status, stdout, stderr = FoundationSupport.run_cli(
            "tui",
            "--state", File.join(dir, "state.json"),
            "--config", File.join(dir, "config.toml")
          )

          assert_equal 1, status
          assert_empty stdout
          assert_includes stderr, "reload unavailable"
        end
      end
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

  private

  def with_replaced_new(klass, replacement)
    singleton = class << klass; self; end
    original = klass.method(:new)
    singleton.define_method(:new) { |*_args, **_keywords| replacement }
    yield
  ensure
    singleton.define_method(:new, original) if singleton && original
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
