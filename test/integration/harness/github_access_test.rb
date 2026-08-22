# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# The access check is deliberately exercised through a fake `gh` executable. It
# proves the client uses only read-only commands, keeps outcomes distinguishable,
# and never reaches the network or a developer's real GitHub configuration.
class HarnessGithubAccessTest < HarnessIntegrationTest
  def setup
    super
    @bin_dir = File.join(tmpdir, "bin")
    @empty_bin_dir = File.join(tmpdir, "empty-bin")
    FileUtils.mkdir_p([@bin_dir, @empty_bin_dir])
    @gh_log = File.join(tmpdir, "gh_invocations.jsonl")
    @gh_config = File.join(tmpdir, "gh_config.json")
    write_executable(@bin_dir, "gh", <<~RUBY)
      #!#{HarnessSupport::RUBY_BIN}
      require "json"
      File.open(#{@gh_log.inspect}, "a") do |file|
        file.puts(JSON.generate("argv" => ARGV, "prompt_disabled" => ENV["GH_PROMPT_DISABLED"]))
      end
      config = JSON.parse(File.read(#{@gh_config.inspect}))
      if ARGV.first(2) == ["auth", "status"]
        $stdout.write(config.fetch("auth_stdout", ""))
        $stderr.write(config.fetch("auth_stderr", ""))
        exit(config.fetch("auth_exit", 0))
      end
      $stdout.write(config.fetch("repo_stdout", "{}"))
      $stderr.write(config.fetch("repo_stderr", ""))
      exit(config.fetch("repo_exit", 0))
    RUBY
    with_env("PATH" => @bin_dir)
    script_gh
    @client = Meringue::Forge::GitHubClient.new
  end

  def script_gh(values = {})
    File.write(
      @gh_config,
      JSON.generate(
        {
          "auth_stdout" => "Logged in to github.com account octocat (https)",
          "auth_stderr" => "",
          "auth_exit" => 0,
          "repo_stdout" => JSON.generate("nameWithOwner" => "acme/app"),
          "repo_stderr" => "",
          "repo_exit" => 0
        }.merge(values)
      )
    )
  end

  def invocations
    return [] unless File.file?(@gh_log)

    File.readlines(@gh_log).map { |line| JSON.parse(line) }
  end

  def test_success_checks_identity_and_read_access_without_mutation
    result = @client.test_access(repository: "acme/app")

    assert_equal "success", result.fetch("outcome")
    assert_equal "octocat", result.fetch("identity")
    assert_equal "acme/app", result.fetch("repository")
    assert_match(/read access/, result.fetch("message"))
    assert_equal [
      %w[auth status --hostname github.com],
      %w[repo view acme/app --json nameWithOwner]
    ], invocations.map { |entry| entry.fetch("argv") }
    assert invocations.all? { |entry| entry.fetch("prompt_disabled") == "1" }
    refute invocations.any? { |entry| entry.fetch("argv").any? { |word| %w[create edit close comment delete merge].include?(word) } }
  end

  def test_auth_failure_is_unauthenticated_and_does_not_probe_repository
    script_gh(
      "auth_stderr" => "You are not logged into any GitHub hosts. Run gh auth login",
      "auth_exit" => 1
    )

    result = @client.test_access(repository: "acme/app")

    assert_equal "unauthenticated", result.fetch("outcome")
    assert_match(/gh auth login/, result.fetch("message"))
    assert_equal 1, invocations.length
  end

  def test_repository_failure_is_permission_denied_after_authentication
    script_gh(
      "repo_stderr" => "GraphQL: Could not resolve to a Repository with the name 'acme/app'.",
      "repo_exit" => 1
    )

    result = @client.test_access(repository: "acme/app")

    assert_equal "permission_denied", result.fetch("outcome")
    assert_match(/not accessible/, result.fetch("message"))
    assert_equal 2, invocations.length
  end

  def test_missing_gh_is_unavailable
    with_env("PATH" => @empty_bin_dir) do
      result = @client.test_access(repository: "acme/app")
      assert_equal "unavailable", result.fetch("outcome")
    end

    assert_empty invocations
  end

  def test_hung_gh_is_a_bounded_timeout
    write_executable(@bin_dir, "gh", <<~RUBY)
      #!#{HarnessSupport::RUBY_BIN}
      sleep 30
    RUBY
    client = Meringue::Forge::GitHubClient.new(command_timeout: 0.05)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = client.test_access(repository: "acme/app")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.75
    assert_equal "timeout", result.fetch("outcome")
  end

  def test_malformed_repository_is_rejected_before_any_command
    result = @client.test_access(repository: "https://example.com/acme/app")

    assert_equal "malformed_remote", result.fetch("outcome")
    assert_empty invocations
  end
end
