# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class KernelMaintenanceGithubExperimentGateTest < Minitest::Test
  class CountingForge
    attr_reader :status_calls, :branch_calls

    def initialize
      @status_calls = []
      @branch_calls = []
    end

    def pull_request_status(url, timeout: nil)
      @status_calls << [url, timeout]
      {
        "provider" => "github",
        "url" => url,
        "state" => "open",
        "base_repository" => "acme/app",
        "head_repository" => "acme/app",
        "head_branch" => "feature",
        "is_cross_repository" => false
      }
    end

    def pull_request_urls_for_branch(repository:, branch:, timeout: nil)
      @branch_calls << [repository, branch, timeout]
      [PR_URL]
    end
  end

  PR_URL = "https://github.com/acme/app/pull/12"

  def setup
    @dir = Dir.mktmpdir("meringue-github-gate")
    @config_path = File.join(@dir, "config.toml")
    File.write(@config_path, <<~TOML)
      [settings]
      schema_version = 1
      [experiments]
      github_support = false
    TOML
    @state_path = File.join(@dir, "state.json")
    @store = Meringue::State::Store.new(path: @state_path)
    @store.save(initial_state)
    @forge = CountingForge.new
    @engine = Meringue::Kernel::Engine.new(
      store: @store,
      config: Meringue::Config.load(path: @config_path),
      config_path: @config_path,
      forge_client: @forge
    )
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.exist?(@dir)
  end

  def test_disabled_mode_never_calls_forge_during_status_reconcile_completion_or_prune
    status = @engine.send(:pull_request_status, PR_URL)
    assert_equal "unknown", status.fetch("state")

    @engine.apply("type" => "ReconcileSessions", "payload" => {})
    completion = @engine.send(:record_worker_completion,
      agent_id: "P1-I1-W1",
      last_assistant_text: "Opened #{PR_URL}",
      harness_events: []
    )
    prune = @engine.apply("type" => "Prune", "payload" => {})

    assert_equal "accepted", completion.fetch("status")
    assert_equal "rejected", prune.fetch("status")
    assert_empty @forge.status_calls
    assert_empty @forge.branch_calls
    issue = @store.load.fetch("issues").find { |record| record["id"] == "P1-I1" }
    assert_equal [PR_URL], issue.fetch("delivery_pull_requests").map { |record| record.fetch("url") }
    refute issue.key?("candidate_pr_urls"), "disabled completion must not extract new candidate metadata"
    assert_includes prune.fetch("message"), "GitHub support is disabled"
    assert_includes prune.fetch("message"), "Settings → Experiments"
  end

  def test_disabled_mode_does_not_associate_request_urls
    head = {
      "harness_metadata" => { "user_message" => "Please review #{PR_URL}" }
    }
    result = {
      "status" => "accepted",
      "command_type" => "ModifyIssue",
      "target_id" => "P1-I1"
    }

    assert_empty @engine.send(:associate_head_request_pull_requests!, head, result)
    assert_equal 1, @store.load.fetch("issues").first.fetch("delivery_pull_requests").length
  end

  def test_reenabling_applies_live_to_the_next_lookup
    store = Meringue::Config::Store.new(path: @config_path)
    result = @engine.apply(
      "type" => "SaveConfiguration",
      "payload" => {
        "base_fingerprint" => store.fingerprint,
        "changes" => { "experiments.github_support" => true }
      }
    )
    assert_equal "accepted", result.fetch("status")

    status = @engine.send(:pull_request_status, PR_URL)
    assert_equal "open", status.fetch("state")
    assert_equal 1, @forge.status_calls.length
  end

  def test_disabled_head_context_omits_gh_tools_and_exact_title_rules
    context = Meringue::Heads::Context.new(
      head_id: "H1",
      user_message: "work on a linked issue",
      snapshot: @store.load,
      github_support: false
    )
    prompt = context.system_prompt
    serialized = JSON.generate(context.to_prompt_h)

    refute_match(/\bgh\s+(?:issue|pr)\b/i, prompt)
    refute_match(/github/i, prompt)
    refute_match(/github/i, serialized)
  end

  private

  def initial_state
    state = Meringue::State::Models.empty_state(now: "2026-08-16T00:00:00Z")
    state["projects"] << {
      "id" => "P1", "name" => "App", "root_path" => @dir,
      "status" => "completed", "issue_ids" => ["P1-I1"],
      "created_at" => "2026-08-16T00:00:00Z", "updated_at" => "2026-08-16T00:00:00Z"
    }
    record = {
      "provider" => "github", "url" => PR_URL, "state" => "open",
      "matched_branch" => "feature", "head_branch" => "feature",
      "verified_at" => "2026-08-16T00:00:00Z", "last_checked_at" => "2026-08-16T00:00:00Z"
    }
    state["issues"] << {
      "id" => "P1-I1", "project_id" => "P1", "title" => "Delivery", "status" => "completed",
      "agent_ids" => ["P1-I1-W1"], "delivery_pull_requests" => [record],
      "reported_pr_urls" => [PR_URL],
      "created_at" => "2026-08-16T00:00:00Z", "updated_at" => "2026-08-16T00:00:00Z"
    }
    state["agents"] << {
      "id" => "P1-I1-W1", "type" => "worker", "status" => "working",
      "project_id" => "P1", "issue_id" => "P1-I1", "harness" => "fake",
      "workspace_branch" => "feature", "harness_metadata" => { "title" => "Deliver" },
      "created_at" => "2026-08-16T00:00:00Z", "updated_at" => "2026-08-16T00:00:00Z"
    }
    state
  end
end
