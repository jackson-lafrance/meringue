# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Regression coverage for the reported `/prune` freeze. Forge lookups are deliberately blocked
# in-process against temporary state; no real state or network service is ever touched.
class KernelMaintenancePruneResponsivenessTest < Minitest::Test
  include KernelMaintenanceSupport

  class FailingBranchForgeClient
    attr_reader :branch_calls

    def initialize
      @branch_calls = []
    end

    def pull_request_urls_for_branch(repository:, branch:, timeout: nil)
      @branch_calls << [repository, branch, timeout]
      raise "branch discovery timed out"
    end

    def pull_request_status(url, timeout: nil)
      raise "unexpected status lookup for #{url}"
    end
  end

  class BlockingForgeClient
    attr_reader :entered, :release, :status_calls

    def initialize
      @entered = Queue.new
      @release = Queue.new
      @status_calls = []
    end

    def pull_request_status(url)
      @status_calls << url.to_s
      if @status_calls.length == 1
        entered << url.to_s
        release.pop
      end
      github_status(url)
    end

    def pull_request_urls_for_branch(repository:, branch:)
      []
    end

    private

    def github_status(url)
      {
        "provider" => "github",
        "url" => url.to_s,
        "state" => "merged",
        "raw_state" => "MERGED",
        "is_cross_repository" => false
      }
    end
  end

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_failed_branch_discovery_conservatively_retains_the_issue
    project_root = make_dir("projects", "repo")
    system("git", "-C", project_root, "init", "--quiet", exception: true)
    system(
      "git", "-C", project_root, "remote", "add", "origin", "https://github.com/acme/app.git",
      exception: true
    )
    worker = worker_record(
      id: "P1-I1-W1",
      issue_id: "P1-I1",
      project_id: "P1",
      extra: {
        "workspace_strategy" => "project_root",
        "workspace_branch" => "meringue/delivery"
      }
    )
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project_root, status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )
    forge = FailingBranchForgeClient.new

    applied = build_engine(forge_client: forge).apply("type" => "Prune", "payload" => {})
    decision = applied.dig("result", "issue_decisions").find { |item| item.fetch("issue_id") == "P1-I1" }

    assert_equal "accepted", applied.fetch("status")
    assert_equal ["P1-I1"], read_state.fetch("issues").map { |issue| issue.fetch("id") }
    assert_includes decision.fetch("blockers"), "unsettled_pull_requests"
    blocker = decision.fetch("pull_request_blockers").first
    assert_equal "unknown", blocker.fetch("state")
    assert_match(/branch discovery timed out/, blocker.fetch("error"))
    assert_equal 1, forge.branch_calls.length
    assert_operator forge.branch_calls.first.fetch(2), :>, 0
  end

  def test_typed_prune_does_not_hold_the_state_lock_while_forge_lookup_blocks
    url = "https://github.com/acme/app/pull/7"
    # Repeating one URL across two records also proves that one prune pass memoizes status instead
    # of running the same `gh pr view` once per issue/phase.
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [
          issue_with_pull_request(id: "P1-I1", project_id: "P1", url: url),
          issue_with_pull_request(id: "P1-I2", project_id: "P1", url: url)
        ]
      )
    )
    forge = BlockingForgeClient.new
    prune_engine = build_engine(forge_client: forge)
    other_engine = build_engine
    prompt_loop = Meringue::Heads::PromptLoop.new(engine: prune_engine)
    prune_thread = Thread.new { prompt_loop.call("/prune") }

    assert_equal url, forge.entered.pop
    # On the regression, Prune held Engine's monitor and the cross-process file lock here for the
    # entire forge delay. Release after a short timer so the old implementation fails by latency
    # rather than deadlocking the suite forever.
    delayed_release = Thread.new do
      sleep 0.4
      forge.release << true
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    state_result = prompt_loop.call("/state").fetch("command_results").first
    same_loop_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    list_result = other_engine.apply("type" => "ListAll", "payload" => {})
    cross_instance_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal "accepted", state_result.fetch("status")
    assert_equal "accepted", list_result.fetch("status")
    assert_operator same_loop_elapsed, :<, 0.2, "later TUI submissions must not queue behind prune's forge I/O"
    assert_operator cross_instance_elapsed, :<, 0.2, "forge I/O must not hold the shared state lock"

    delayed_release.join
    prune_result = prune_thread.value
    command_result = prune_result.fetch("command_results").first
    assert_equal "accepted", command_result.fetch("status")
    assert_equal "Pruned 2 issues, 0 projects, and 0 standalone agents.", command_result.fetch("message")
    assert_equal [url], forge.status_calls, "one prune pass should look up each unique PR once"
  ensure
    forge&.release&.push(true) if prune_thread&.alive?
    prune_thread&.join(1)
    prune_thread&.kill if prune_thread&.alive?
  end
end
