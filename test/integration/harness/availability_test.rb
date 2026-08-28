# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Setup used to offer three harnesses as equal choices with no way to tell which
# of them this machine could actually start. These cover the resolution that
# answers that, using a fake PATH rather than whatever happens to be installed on
# the developer's computer.
class HarnessAvailabilityTest < Minitest::Test
  Availability = Meringue::Harness::Availability

  def test_locate_finds_an_executable_on_the_supplied_path
    with_fake_bin("pi") do |bin, path_env|
      located = Availability.locate(["pi"], base_environment: path_env)

      assert_equal Availability::INSTALLED, located.fetch("status")
      assert_equal File.join(bin, "pi"), located.fetch("path")
      assert_equal "installed", Availability.summary(located)
      assert Availability.installed?(located)
    end
  end

  def test_locate_reports_a_missing_executable_without_guessing
    with_fake_bin("pi") do |_bin, path_env|
      located = Availability.locate(["codex"], base_environment: path_env)

      assert_equal Availability::MISSING, located.fetch("status")
      assert_nil located["path"]
      assert_equal "not found", Availability.summary(located)
      refute Availability.installed?(located)
    end
  end

  # A file that exists but is not executable is not a harness Meringue can start,
  # and saying "installed" about it would be the same lie as saying nothing.
  def test_a_non_executable_file_is_not_installed
    Dir.mktmpdir("meringue-availability") do |dir|
      File.write(File.join(dir, "pi"), "#!/bin/sh\n")
      located = Availability.locate(["pi"], base_environment: { "PATH" => dir })

      assert_equal Availability::MISSING, located.fetch("status")
    end
  end

  def test_an_absolute_command_is_checked_directly_rather_than_searched
    with_fake_bin("pi") do |bin, _path_env|
      absolute = File.join(bin, "pi")
      located = Availability.locate([absolute], base_environment: { "PATH" => "" })

      assert_equal Availability::INSTALLED, located.fetch("status")
      assert_equal absolute, located.fetch("path")
    end
  end

  # The provider's own env is what actually decides where its executable resolves
  # from, which is the whole point of supporting version-manager installations.
  def test_provider_environment_path_wins_over_the_ambient_one
    with_fake_bin("pi") do |bin, _path_env|
      located = Availability.locate(["pi"], env: { "PATH" => bin }, base_environment: { "PATH" => "/nonexistent" })

      assert_equal Availability::INSTALLED, located.fetch("status")
    end
  end

  def test_an_empty_command_is_reported_as_unconfigured_not_missing
    located = Availability.locate([], base_environment: { "PATH" => "" })

    assert_equal Availability::UNCONFIGURED, located.fetch("status")
    assert_equal "no command set", Availability.summary(located)
  end

  def test_probe_runs_the_executable_and_reports_what_it_answered
    with_fake_bin("pi", body: "#!/bin/sh\necho 'pi 9.9.9'\n") do |bin, _path_env|
      probed = Availability.probe(["pi"], base_environment: runnable_env(bin))

      assert_equal Availability::RUNNABLE, probed.fetch("status")
      assert_equal "pi 9.9.9", probed.fetch("detail")
    end
  end

  def test_probe_reports_a_harness_that_starts_but_fails
    with_fake_bin("pi", body: "#!/bin/sh\necho 'not logged in' >&2\nexit 1\n") do |bin, _path_env|
      probed = Availability.probe(["pi"], base_environment: runnable_env(bin))

      assert_equal Availability::FAILED, probed.fetch("status")
      assert_equal "not logged in", probed.fetch("detail")
    end
  end

  # A harness that never answers must not be able to hold the setup card open.
  def test_probe_is_bounded_and_reports_a_timeout
    with_fake_bin("pi", body: "#!/bin/sh\nsleep 30\n") do |bin, _path_env|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      probed = Availability.probe(["pi"], base_environment: runnable_env(bin), timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal Availability::TIMEOUT, probed.fetch("status")
      assert_operator elapsed, :<, 10, "the probe must not outlive its own budget"
    end
  end

  def test_probe_does_not_run_a_command_it_could_not_find
    with_fake_bin("pi") do |_bin, path_env|
      probed = Availability.probe(["codex"], base_environment: path_env)

      assert_equal Availability::MISSING, probed.fetch("status")
    end
  end

  def test_registry_reports_availability_for_every_supported_provider
    with_fake_bin("claude") do |_bin, path_env|
      registry = Meringue::Harness::Registry.new(config: Meringue::Config.new({}, path: "/nonexistent/config.toml"))
      availability = with_env(path_env) { registry.provider_availability }

      assert_equal Meringue::Harness::Registry::PROVIDERS.sort, availability.keys.sort
      assert_equal Availability::INSTALLED, availability.fetch("claude").fetch("status")
      assert_equal Availability::MISSING, availability.fetch("codex").fetch("status")
      assert_equal ["claude"], with_env(path_env) { registry.installed_providers }
    end
  end

  # A configured absolute command is what gets launched, so it is also what gets
  # checked; reading PATH instead would answer a question nobody asked.
  def test_registry_uses_the_configured_provider_command
    with_fake_bin("my-pi") do |bin, _path_env|
      config = Meringue::Config.new({ "harness" => { "pi" => { "command" => File.join(bin, "my-pi") } } }, path: "/nonexistent/config.toml")
      registry = Meringue::Harness::Registry.new(config: config)

      located = with_env({ "PATH" => "/nonexistent" }) { registry.availability_for("pi") }

      assert_equal Availability::INSTALLED, located.fetch("status")
      assert_equal File.join(bin, "my-pi"), located.fetch("path")
    end
  end

  private

  def with_fake_bin(name, body: "#!/bin/sh\necho fake\n")
    Dir.mktmpdir("meringue-availability") do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      executable = File.join(bin, name)
      File.write(executable, body)
      FileUtils.chmod(0o755, executable)
      yield bin, { "PATH" => bin }
    end
  end

  # A probe starts a real process, so its environment has to be one a process can
  # actually run in; the fake bin only has to win.
  def runnable_env(bin)
    { "PATH" => [bin, ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR) }
  end

  def with_env(values)
    original = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
