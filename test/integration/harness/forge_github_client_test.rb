# frozen_string_literal: true

require "test_helper"
require "support/harness_support"

# The forge client shells out to `gh`. These tests inject a scripted `gh` stub on
# a PATH that contains nothing else, so the request/response mapping is exercised
# without any network access whatsoever.
class HarnessForgeGitHubClientTest < HarnessIntegrationTest
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
      File.open(#{@gh_log.inspect}, "a") { |file| file.puts(JSON.generate(ARGV)) }
      config = JSON.parse(File.read(#{@gh_config.inspect}))
      $stdout.write(config["stdout"].to_s)
      $stderr.write(config["stderr"].to_s)
      exit(config.fetch("exit_code", 0))
    RUBY
    script_gh(stdout: "[]")
    # No real gh (and no network client) can be reached from here.
    with_env("PATH" => @bin_dir)
    @client = Meringue::Forge::GitHubClient.new
  end

  def script_gh(stdout: "", stderr: "", exit_code: 0)
    File.write(@gh_config, JSON.generate("stdout" => stdout, "stderr" => stderr, "exit_code" => exit_code))
  end

  def invocations
    return [] unless File.file?(@gh_log)

    File.readlines(@gh_log).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
  end

  def without_gh
    with_env("PATH" => @empty_bin_dir) { yield }
  end

  def test_pull_request_urls_for_branch_maps_the_request_and_response
    script_gh(stdout: JSON.generate([
                                      { "url" => "https://github.com/acme/app/pull/7" },
                                      { "url" => "https://github.com/acme/app/pull/7" },
                                      { "url" => "https://github.com/acme/app/pull/9" },
                                      { "id" => "no url here" }
                                    ]))

    urls = @client.pull_request_urls_for_branch(repository: "acme/app", branch: "meringue/task-1")

    assert_equal ["https://github.com/acme/app/pull/7", "https://github.com/acme/app/pull/9"], urls
    assert_equal [%w[pr list --repo acme/app --head meringue/task-1 --state all --limit 100 --json url]],
                 invocations
  end

  def test_pull_request_urls_for_branch_is_empty_when_gh_fails
    script_gh(stdout: "[]", stderr: "gh: not authenticated", exit_code: 4)

    assert_empty @client.pull_request_urls_for_branch(repository: "acme/app", branch: "main")
    assert_equal 1, invocations.length
  end

  def test_pull_request_urls_for_branch_survives_unparseable_output
    script_gh(stdout: "not json")

    assert_empty @client.pull_request_urls_for_branch(repository: "acme/app", branch: "main")
  end

  def test_pull_request_urls_for_branch_survives_a_missing_gh_binary
    without_gh do
      assert_empty @client.pull_request_urls_for_branch(repository: "acme/app", branch: "main")
    end

    assert_empty invocations
  end

  def test_pull_request_status_maps_a_merged_pull_request
    script_gh(stdout: JSON.generate(
      "state" => "MERGED",
      "mergedAt" => "2026-01-02T03:04:05Z",
      "url" => "https://github.com/acme/app/pull/7",
      "isDraft" => false,
      "headRefName" => "meringue/task-1",
      "headRepository" => { "nameWithOwner" => "contributor/app" },
      "headRepositoryOwner" => { "login" => "contributor" },
      "isCrossRepository" => true
    ))

    status = @client.pull_request_status("https://github.com/acme/app/pull/7")

    assert_equal "github", status.fetch("provider")
    assert_equal "https://github.com/acme/app/pull/7", status.fetch("url")
    assert_equal "merged", status.fetch("state")
    assert_equal "MERGED", status.fetch("raw_state")
    assert_equal "2026-01-02T03:04:05Z", status.fetch("merged_at")
    assert_equal false, status.fetch("is_draft")
    assert_equal "meringue/task-1", status.fetch("head_branch")
    assert_equal "contributor/app", status.fetch("head_repository")
    assert_equal "contributor", status.fetch("head_repository_owner")
    assert_equal true, status.fetch("is_cross_repository")
    assert_equal "acme/app", status.fetch("base_repository")

    argv = invocations.fetch(0)
    assert_equal %w[pr view https://github.com/acme/app/pull/7 --json], argv.first(4)
    assert_equal "state,mergedAt,url,isDraft,headRefName,headRepository,headRepositoryOwner,isCrossRepository",
                 argv.last
  end

  def test_pull_request_status_normalizes_every_state
    {
      "OPEN" => "open",
      "open" => "open",
      "CLOSED" => "closed",
      "MERGED" => "merged",
      "SOMETHING_NEW" => "unknown",
      nil => "unknown"
    }.each do |raw_state, expected|
      script_gh(stdout: JSON.generate("state" => raw_state, "url" => "https://github.com/acme/app/pull/1"))

      status = @client.pull_request_status("https://github.com/acme/app/pull/1")

      assert_equal expected, status.fetch("state"), "#{raw_state.inspect} should normalize to #{expected}"
    end
  end

  def test_pull_request_status_falls_back_to_the_requested_url
    script_gh(stdout: JSON.generate("state" => "OPEN"))

    status = @client.pull_request_status("https://github.com/acme/app/pull/12")

    assert_equal "https://github.com/acme/app/pull/12", status.fetch("url")
    assert_equal "acme/app", status.fetch("base_repository")
  end

  def test_pull_request_status_drops_a_non_github_base_repository
    script_gh(stdout: JSON.generate("state" => "OPEN", "url" => "https://example.com/not/a/pull/1"))

    status = @client.pull_request_status("https://example.com/not/a/pull/1")

    refute status.key?("base_repository")
    assert_equal "open", status.fetch("state")
  end

  def test_pull_request_status_reports_command_failures_as_unknown
    script_gh(stdout: "", stderr: "  could not resolve to a PullRequest\n", exit_code: 1)

    status = @client.pull_request_status("https://github.com/acme/app/pull/404")

    assert_equal "unknown", status.fetch("state")
    assert_equal "github", status.fetch("provider")
    assert_equal "https://github.com/acme/app/pull/404", status.fetch("url")
    assert_equal "could not resolve to a PullRequest", status.fetch("error")
    assert_equal 1, status.fetch("exit_status")
    refute status.key?("merged_at")
  end

  def test_pull_request_status_reports_unparseable_output_as_unknown
    script_gh(stdout: "<html>rate limited</html>")

    status = @client.pull_request_status("https://github.com/acme/app/pull/7")

    assert_equal "unknown", status.fetch("state")
    refute_empty status.fetch("error")
    refute status.key?("exit_status")
  end

  def test_pull_request_status_reports_a_missing_gh_binary_as_unknown
    status = without_gh { @client.pull_request_status("https://github.com/acme/app/pull/7") }

    assert_equal "unknown", status.fetch("state")
    assert_equal "https://github.com/acme/app/pull/7", status.fetch("url")
    refute_empty status.fetch("error")
    assert_empty invocations, "no forge command should have run"
  end
end
