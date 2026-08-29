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

  def test_command_runner_bounds_captured_output_while_draining_the_child
    runner = Meringue::Lifecycle::CommandRunner.new(timeout: 5, output_limit: 32)
    result = runner.call(
      [RbConfig.ruby, "-e", "STDOUT.write('x' * 100_000); STDERR.write('y' * 100_000)"],
      chdir: Dir.pwd
    )

    assert result.fetch("status").success?
    assert_equal 32, result.fetch("stdout").bytesize
    assert_equal 32, result.fetch("stderr").bytesize
  end

  # Every update resolves origin/<branch>, HEAD, and the current branch before
  # it touches the checkout, so a runner script here says what git would say.
  def git_results(target:, head:, branch: "main")
    [
      { "stdout" => "", "status" => 0 },
      { "stdout" => "", "status" => 0 },
      { "stdout" => "#{target}\n", "status" => 0 },
      { "stdout" => "#{head}\n", "status" => 0 },
      { "stdout" => "#{branch}\n", "status" => 0 }
    ]
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

  def test_update_fast_forwards_the_tracked_branch_and_skips_bundle_install_when_dependencies_are_ready
    with_checkout do |root|
      runner = RecordingRunner.new(
        git_results(target: "b" * 40, head: "a" * 40) + [
          { "stdout" => "Updating aaaaaaa..bbbbbbb\n", "status" => 0 },
          { "stdout" => "The Gemfile's dependencies are satisfied\n", "status" => 0 }
        ]
      )
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "updated", result.fetch("status")
      refute result.fetch("dependencies_installed")
      assert_includes result.fetch("message"), "bbbbbbb"
      assert_equal(
        [
          "git status --porcelain --untracked-files=all",
          "git fetch --quiet origin main",
          "git rev-parse --verify origin/main^{commit}",
          "git rev-parse --verify HEAD^{commit}",
          "git rev-parse --abbrev-ref HEAD",
          "git merge --ff-only origin/main",
          "bundle check"
        ],
        runner.calls.map { |call| call.fetch("command").join(" ") }
      )
      assert runner.calls.all? { |call| call.fetch("chdir") == root }
    end
  end

  # The bug this guards: an installation parked on a feature branch pulled that
  # branch, found nothing, and restarted into the same code reporting success.
  def test_update_switches_a_checkout_parked_on_another_branch_onto_the_tracked_one
    with_checkout do |root|
      runner = RecordingRunner.new(
        git_results(target: "b" * 40, head: "a" * 40, branch: "setup-focus") + [
          { "stdout" => "Switched to branch 'main'\n", "status" => 0 },
          { "stdout" => "Updating aaaaaaa..bbbbbbb\n", "status" => 0 },
          { "stdout" => "The Gemfile's dependencies are satisfied\n", "status" => 0 }
        ]
      )
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "updated", result.fetch("status")
      assert_equal ["git checkout main", "git merge --ff-only origin/main", "bundle check"],
                   runner.calls.map { |call| call.fetch("command").join(" ") }.last(3)
    end
  end

  def test_update_tracks_the_branch_it_was_configured_with
    with_checkout do |root|
      runner = RecordingRunner.new(
        git_results(target: "b" * 40, head: "a" * 40, branch: "setup-focus") + [
          { "stdout" => "Already up to date.\n", "status" => 0 },
          { "stdout" => "The Gemfile's dependencies are satisfied\n", "status" => 0 }
        ]
      )
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner, branch: "setup-focus")

      result = manager.update

      assert_equal "updated", result.fetch("status")
      assert_includes runner.calls.map { |call| call.fetch("command").join(" ") }, "git fetch --quiet origin setup-focus"
      refute_includes runner.calls.map { |call| call.fetch("command").join(" ") }, "git checkout setup-focus"
    end
  end

  def test_update_reports_an_unchanged_checkout_instead_of_asking_for_a_reload
    with_checkout do |root|
      runner = RecordingRunner.new(
        git_results(target: "c" * 40, head: "c" * 40) + [
          { "stdout" => "Already up to date.\n", "status" => 0 },
          { "stdout" => "The Gemfile's dependencies are satisfied\n", "status" => 0 }
        ]
      )
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "current", result.fetch("status")
      assert_includes result.fetch("message"), "already up to date"
      assert_includes result.fetch("message"), "ccccccc"
    end
  end

  def test_update_installs_dependencies_only_after_bundle_check_reports_missing_gems
    with_checkout do |root|
      runner = RecordingRunner.new(
        git_results(target: "c" * 40, head: "c" * 40) + [
          { "stdout" => "Already up to date.\n", "status" => 0 },
          { "stdout" => "Gem bundle is incomplete\n", "status" => 1 },
          { "stdout" => "Bundle complete!\n", "status" => 0 }
        ]
      )
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      # Missing gems are a change worth reloading for even when no commit moved.
      assert_equal "updated", result.fetch("status")
      assert result.fetch("dependencies_installed")
      assert_equal ["bundle check", "bundle install"], runner.calls.map { |call| call.fetch("command").join(" ") }.last(2)
    end
  end

  def test_update_does_not_install_after_a_failed_fast_forward
    with_checkout do |root|
      runner = RecordingRunner.new(
        git_results(target: "b" * 40, head: "a" * 40) + [
          { "stdout" => "fatal: Not possible to fast-forward, aborting.\n", "status" => 1 }
        ]
      )
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), "Could not update Meringue"
      assert_equal "git merge --ff-only origin/main", runner.calls.last.fetch("command").join(" ")
      assert_equal 6, runner.calls.length
    end
  end

  def test_update_reports_a_missing_tracked_branch_without_touching_the_checkout
    with_checkout do |root|
      runner = RecordingRunner.new([
        { "stdout" => "", "status" => 0 },
        { "stdout" => "", "status" => 0 },
        { "stdout" => "", "stderr" => "fatal: Needed a single revision\n", "status" => 1 }
      ])
      manager = Meringue::Lifecycle::Manager.new(root: root, runner: runner)

      result = manager.update

      assert_equal "failed", result.fetch("status")
      assert_includes result.fetch("message"), "MERINGUE_BRANCH"
      assert_equal 3, runner.calls.length
    end
  end

  def test_default_branch_prefers_the_installer_environment_variable
    assert_equal "main", Meringue::Lifecycle::Manager.default_branch({})
    assert_equal "main", Meringue::Lifecycle::Manager.default_branch({ "MERINGUE_BRANCH" => "  " })
    assert_equal "setup-focus", Meringue::Lifecycle::Manager.default_branch({ "MERINGUE_BRANCH" => "setup-focus" })
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
        working_directory: root,
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

  def test_reload_preserves_the_original_working_directory
    Dir.mktmpdir("meringue-lifecycle-test") do |root|
      Dir.mktmpdir("meringue-launch-test") do |working_directory|
        calls = []
        manager = Meringue::Lifecycle::Manager.new(
          root: root,
          working_directory: working_directory,
          command: [RbConfig.ruby, "/tmp/bin/meringue"],
          execer: lambda do |command, chdir:|
            calls << { "command" => command, "chdir" => chdir }
          end
        )

        manager.reload

        assert_equal working_directory, calls.first.fetch("chdir")
      end
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

  def test_update_failure_is_reported_without_requesting_a_reload
    lifecycle = RecordingLifecycle.new("status" => "failed", "message" => "The checkout is dirty.")
    app = Meringue::TUI::App.new(
      terminal: TUISupport::FakeTerminal.new,
      out: StringIO.new,
      lifecycle: lifecycle
    )
    state = Meringue::State::Models.empty_state

    app.send(:handle_key, "\r", "/update", "/update".length, -1, nil, state)
    lifecycle.updates.pop
    app.instance_variable_get(:@lifecycle_update_thread)&.join

    refute app.send(:reload_requested?)
    assert_includes app.send(:chat_snapshot, "").fetch("messages").last.fetch("text"), "The checkout is dirty."
  end

  def test_second_update_is_rejected_while_the_first_is_running
    started = Queue.new
    release = Queue.new
    lifecycle = Object.new
    lifecycle.define_singleton_method(:update) do
      started << true
      release.pop
      { "status" => "updated" }
    end
    app = Meringue::TUI::App.new(
      terminal: TUISupport::FakeTerminal.new,
      out: StringIO.new,
      lifecycle: lifecycle
    )
    state = Meringue::State::Models.empty_state

    app.send(:handle_key, "\r", "/update", "/update".length, -1, nil, state)
    started.pop
    app.send(:handle_key, "\r", "/update", "/update".length, -1, nil, state)

    assert_includes app.send(:chat_snapshot, "").fetch("messages").last.fetch("text"), "already running"
    release << true
    app.instance_variable_get(:@lifecycle_update_thread)&.join
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
