# frozen_string_literal: true

require "test_helper"
require "support/tui_support"
require "stringio"
require "timeout"

class FoundationLifecycleTest < Minitest::Test
  class RecordingRunner
    attr_reader :calls

    def initialize(results)
      @results = results.dup
      @calls = []
    end

    def call(command, chdir:)
      @calls << { "command" => command, "chdir" => chdir }
      @results.shift || success
    end

    private

    def success
      { "stdout" => "", "stderr" => "", "status" => 0 }
    end
  end

  class RecordingLifecycle
    attr_reader :updates

    def initialize(result = { "status" => "updated" })
      @result = result
      @updates = Queue.new
    end

    def update
      @updates << true
      @result
    end

    def reload
      true
    end
  end

  def test_update_refuses_a_dirty_checkout_before_pulling
    with_checkout do |root|
      runner = RecordingRunner.new([{ "stdout" => " M lib/meringue.rb\n", "status" => 0 }])
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), "local changes"
      assert_equal [%w[git status --porcelain --untracked-files=all]], runner.calls.map { |call| call.fetch("command") }
    end
  end

  def test_update_pulls_and_skips_bundle_install_when_dependencies_are_ready
    with_checkout do |root|
      runner = RecordingRunner.new([
        { "stdout" => "", "status" => 0 },
        { "stdout" => "Already up to date.\n", "status" => 0 },
        { "stdout" => "The Gemfile's dependencies are satisfied\n", "status" => 0 }
      ])
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "updated", result.fetch("status")
      refute result.fetch("dependencies_installed")
      assert_equal(
        [%w[git status --porcelain --untracked-files=all], %w[git pull --ff-only], %w[bundle check]],
        runner.calls.map { |call| call.fetch("command") }
      )
      assert runner.calls.all? { |call| call.fetch("chdir") == root }
    end
  end

  def test_update_installs_dependencies_only_after_bundle_check_reports_missing_gems
    with_checkout do |root|
      runner = RecordingRunner.new([
        { "stdout" => "", "status" => 0 },
        { "stdout" => "Already up to date.\n", "status" => 0 },
        { "stdout" => "Gem bundle is incomplete\n", "status" => 1 },
        { "stdout" => "Bundle complete!\n", "status" => 0 }
      ])
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "updated", result.fetch("status")
      assert result.fetch("dependencies_installed")
      assert_equal ["bundle check", "bundle install"], runner.calls.map { |call| call.fetch("command").join(" ") }.last(2)
    end
  end

  def test_update_does_not_install_after_a_failed_pull
    with_checkout do |root|
      runner = RecordingRunner.new([
        { "stdout" => "", "status" => 0 },
        { "stdout" => "fatal: not possible to fast-forward\n", "status" => 1 }
      ])
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), "Could not update Meringue"
      assert_equal 2, runner.calls.length
    end
  end

  def test_update_rejects_non_git_installations_without_running_commands
    Dir.mktmpdir("meringue-lifecycle-test") do |root|
      runner = RecordingRunner.new([])
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), "Git source checkout"
      assert_empty runner.calls
    end
  end

  def test_reload_replaces_the_current_process_with_the_original_command
    Dir.mktmpdir("meringue-lifecycle-test") do |root|
      calls = []
      manager = Meringue::Lifecycle::Manager.new(
        root: root,
        command: [RbConfig.ruby, "/tmp/bin/meringue", "tui", "--state", "/tmp/state.json"],
        execer: lambda do |command, chdir:|
          calls << { "command" => command, "chdir" => chdir }
        end
      )

      result = manager.reload

      assert_equal "failed", result.fetch("status"), "a test execer returns instead of replacing the process"
      assert_equal [RbConfig.ruby, "/tmp/bin/meringue", "tui", "--state", "/tmp/state.json"], calls.first.fetch("command")
      assert_equal root, calls.first.fetch("chdir")
    end
  end

  def test_reload_returns_a_sentinel_after_the_tui_has_cleaned_up
    lifecycle = RecordingLifecycle.new
    terminal = TUISupport::FakeTerminal.new(
      interactive: true,
      keys: "/reload".chars + ["\r"],
      output: StringIO.new
    )
    app = Meringue::TUI::App.new(
      terminal: terminal,
      out: StringIO.new,
      lifecycle: lifecycle
    )

    assert_equal :reload, app.run(state: Meringue::State::Models.empty_state)
    assert_empty lifecycle.updates
  end

  def test_update_runs_off_the_input_thread_and_requests_the_same_reload
    lifecycle = RecordingLifecycle.new
    app = Meringue::TUI::App.new(
      terminal: TUISupport::FakeTerminal.new,
      out: StringIO.new,
      lifecycle: lifecycle
    )
    state = Meringue::State::Models.empty_state

    result = app.send(:handle_key, "\r", "/update", "/update".length, -1, nil, state)

    assert_equal ["", 0, -1], result
    lifecycle.updates.pop
    app.instance_variable_get(:@lifecycle_update_thread)&.join
    assert app.send(:reload_requested?)
  end

  private

  def with_checkout
    Dir.mktmpdir("meringue-lifecycle-test") do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))
      File.write(File.join(root, "Gemfile"), "source 'https://rubygems.org'\n")
      yield root
    end
  end
end
