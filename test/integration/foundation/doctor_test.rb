# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# The quick start used to be "run git --version, ruby --version, bundle --version
# and check them yourself", with the fixes in a troubleshooting section further
# down. These cover the command that asks the same questions and answers each
# failure with its fix.
class FoundationDoctorTest < Minitest::Test
  Doctor = Meringue::Doctor

  def test_a_healthy_environment_reports_no_problems
    in_repository do |root|
      doctor = build(root: root, config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "pi" }), harness: "pi")

      assert_empty doctor.problems
      assert_includes titles(doctor), "Harness: Pi"
    end
  end

  # The harness is the one thing Meringue cannot run without, so an unconfigured
  # one is a problem rather than a note.
  def test_an_unconfigured_harness_is_a_problem_with_the_way_to_fix_it
    in_repository do |root|
      doctor = build(root: root, config: config_with({}), harness: nil)
      check = doctor.problems.find { |candidate| candidate.title.include?("harness") }

      refute_nil check
      assert_includes check.fix, "first-run setup"
    end
  end

  # A configured absolute command is what gets launched, so it is what gets
  # checked — and naming it is what makes the failure actionable.
  def test_a_missing_harness_names_the_command_it_looked_for
    in_repository do |root|
      config = config_with("harness" => { "head_provider" => "codex", "worker_provider" => "codex", "codex" => { "command" => "/nowhere/codex" } })
      doctor = build(root: root, config: config, harness: nil)
      check = doctor.problems.find { |candidate| candidate.title.include?("Codex") }

      refute_nil check
      assert_includes check.detail, "/nowhere/codex"
      assert_includes check.fix, "[harness.codex] command"
    end
  end

  # Two roles on one backend is the normal case and saying it twice adds nothing.
  def test_matching_roles_are_reported_once_and_split_roles_separately
    in_repository do |root|
      shared = build(root: root, config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "pi" }), harness: "pi")
      assert_equal 1, titles(shared).count { |title| title.include?("arness") }

      split = build(
        root: root,
        config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "claude" }),
        harness: "pi"
      )
      assert_includes titles(split).join(" "), "Head harness"
      assert_includes titles(split).join(" "), "Worker harness"
    end
  end

  def test_an_old_ruby_is_reported_with_the_minimum
    in_repository do |root|
      doctor = build(root: root, config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "pi" }), harness: "pi", ruby_version: "3.0.6")
      check = doctor.problems.find { |candidate| candidate.title.include?("Ruby") }

      refute_nil check
      assert_includes check.detail, Doctor::MINIMUM_RUBY
    end
  end

  def test_unparseable_config_is_a_problem_that_says_what_to_do_with_it
    in_repository do |root|
      path = File.join(root, "config.toml")
      File.write(path, "this is not = = toml\n")
      doctor = Doctor.new(
        config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "pi" }),
        config_path: path,
        state_path: File.join(root, "state.json"),
        registry: nil,
        cwd: root
      )
      check = doctor.problems.find { |candidate| candidate.title.include?("could not be parsed") }

      refute_nil check
      assert_includes check.fix, "move the file aside"
    end
  end

  # Meringue already quarantines unreadable state and starts empty, so this warns
  # about losing history rather than blocking a launch.
  def test_corrupt_state_is_a_note_rather_than_a_problem
    in_repository do |root|
      state_path = File.join(root, "state.json")
      File.write(state_path, "{ not json")
      doctor = build(root: root, config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "pi" }), harness: "pi", state_path: state_path)

      assert_empty doctor.problems.select { |check| check.title.include?("State") }
      assert(doctor.checks.any? { |check| check.status == Doctor::NOTE && check.title.include?("State") })
    end
  end

  # gh only matters when the built-in GitHub frontend is the one in use.
  def test_the_github_cli_is_only_checked_when_the_github_frontend_is_active
    in_repository do |root|
      default = build(root: root, config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "pi" }), harness: "pi")
      assert(titles(default).any? { |title| title.include?("GitHub") })

      alternate = build(
        root: root,
        config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "pi" }, "forge" => { "frontend" => "command" }),
        harness: "pi"
      )
      refute(titles(alternate).any? { |title| title.include?("GitHub") })
    end
  end

  def test_running_outside_a_repository_is_a_note_not_a_failure
    Dir.mktmpdir("meringue-doctor-bare") do |dir|
      doctor = build(root: File.realpath(dir), config: config_with("harness" => { "head_provider" => "pi", "worker_provider" => "pi" }), harness: "pi")
      check = doctor.checks.find { |candidate| candidate.title.include?("git repository") }

      refute_nil check
      assert_equal Doctor::NOTE, check.status
      assert_includes check.fix, "/project add"
    end
  end

  private

  def titles(doctor)
    doctor.checks.map(&:title)
  end

  def config_with(data)
    Meringue::Config.new(data, path: "/nonexistent/config.toml")
  end

  # A fake harness on PATH so the check exercises real resolution without
  # depending on what the developer happens to have installed.
  def build(root:, config:, harness:, ruby_version: RUBY_VERSION, state_path: nil)
    bin = File.join(root, "bin")
    FileUtils.mkdir_p(bin)
    if harness
      executable = File.join(bin, harness)
      File.write(executable, "#!/bin/sh\necho fake\n")
      FileUtils.chmod(0o755, executable)
    end
    with_path(bin) do
      Doctor.new(
        config: config,
        config_path: File.join(root, "config.toml"),
        state_path: state_path || File.join(root, "state.json"),
        registry: Meringue::Harness::Registry.new(config: config),
        cwd: root,
        ruby_version: ruby_version
      ).tap(&:checks)
    end
  end

  def with_path(bin)
    original = ENV["PATH"]
    ENV["PATH"] = [bin, original].compact.join(File::PATH_SEPARATOR)
    yield
  ensure
    ENV["PATH"] = original
  end

  # A real repository with a GitHub origin, because "healthy" now includes the
  # version-control backend being able to prove isolated mutable workspaces. The origin
  # URL is read for its host, never contacted.
  def in_repository
    Dir.mktmpdir("meringue-doctor") do |dir|
      root = File.realpath(dir)
      git!(root, "init", "--quiet", "--initial-branch=main")
      git!(root, "config", "user.email", "doctor@example.com")
      git!(root, "config", "user.name", "Meringue Doctor")
      File.write(File.join(root, "README.md"), "# doctor fixture\n")
      git!(root, "add", "README.md")
      git!(root, "commit", "--quiet", "--no-verify", "-m", "initial commit")
      git!(root, "remote", "add", "origin", "git@github.com:example/doctor-fixture.git")
      yield root
    end
  end

  def git!(root, *argv)
    _stdout, stderr, status = Open3.capture3("git", "-C", root, *argv)
    raise "git #{argv.join(" ")} failed: #{stderr}" unless status.success?

    true
  end
end
