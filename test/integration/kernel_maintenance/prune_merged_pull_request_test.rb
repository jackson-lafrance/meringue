# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"
require "support/workspace_support"

# Regression coverage for the reported "agents that aren't getting pruned even though their PRs are
# merged".
#
# The defect was not a retention predicate: prune re-verified every pull request live against one
# shared five-second forge budget, so an unreachable (or merely slow) forge downgraded pull requests
# Meringue had already verified as merged to `unknown` and retained the whole subtree, while
# exploratory branch discovery for those same settled workers manufactured extra `unknown` blockers.
#
# Everything here is hermetic: temporary state, local git repositories, and stub forge clients. No
# real state file, `gh` invocation, or network call is involved.
class KernelMaintenancePruneMergedPullRequestTest < Minitest::Test
  include KernelMaintenanceSupport
  include WorkspaceSupport

  REPOSITORY = "acme/app"

  # A forge Meringue cannot reach at all: every lookup fails the way `gh` does when it cannot
  # resolve api.github.com or is killed by the bounded timeout.
  class UnreachableForgeClient
    attr_reader :status_calls, :branch_calls

    def initialize
      @status_calls = []
      @branch_calls = []
    end

    def pull_request_status(url, timeout: nil)
      @status_calls << url.to_s
      raise "error connecting to api.github.com"
    end

    def pull_request_urls_for_branch(repository:, branch:, timeout: nil)
      @branch_calls << [repository.to_s, branch.to_s]
      raise "error connecting to api.github.com"
    end
  end

  # Answers configured URLs immediately and stalls on everything else, so one prune pass can be
  # observed spending its bounded budget.
  class SlowForgeClient
    attr_reader :status_calls, :branch_calls

    def initialize(statuses: {}, stall_seconds: 0.2)
      @statuses = statuses
      @stall_seconds = stall_seconds
      @status_calls = []
      @branch_calls = []
    end

    def pull_request_status(url, timeout: nil)
      @status_calls << url.to_s
      known = @statuses[url.to_s]
      return known if known

      sleep(@stall_seconds)
      { "provider" => "github", "url" => url.to_s, "state" => "unknown", "error" => "forge stalled" }
    end

    def pull_request_urls_for_branch(repository:, branch:, timeout: nil)
      @branch_calls << [repository.to_s, branch.to_s]
      []
    end
  end

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_merged_delivery_pull_request_and_clean_worktree_are_pruned_when_the_forge_is_unreachable
    project, workspace = github_project_and_workspace(task_title: "Merged delivery")
    write_merged_delivery_state(project, workspace)
    forge = UnreachableForgeClient.new

    result = apply_command(build_engine(forge_client: forge), "Prune", {})

    assert_equal "accepted", result.fetch("status")
    assert_equal "Pruned 1 issue, 0 projects, and 0 standalone agents.", result.fetch("message")
    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1-W1"], result.dig("result", "removed_agent_ids")
    assert_empty result.dig("result", "retained_issue_ids")
    assert_equal "removed", result.dig("result", "workspace_cleanup_outcomes", 0, "status")
    refute Dir.exist?(workspace.fetch("worktree_root_path"))
    assert branch_exists?(project, workspace.fetch("workspace_branch")), "cleanup must keep the delivery branch"

    # A merged pull request is terminal, so the persisted record is authoritative and no forge call
    # is made for it at all.
    assert_empty forge.status_calls, "a recorded merged PR must not be re-verified against the forge"
    assert_empty forge.branch_calls, "branch discovery cannot add anything for a recorded merged delivery"
    forge_lookup = result.dig("result", "forge_lookup")
    assert_equal [pull_request_url(1)], forge_lookup.fetch("trusted_from_state_urls")
    assert_equal 0, forge_lookup.fetch("status_lookup_count")
    refute forge_lookup.fetch("budget_exhausted")

    state = read_state
    assert_empty state.fetch("issues")
    assert_empty state.fetch("agents")
    assert_documented_status_vocabulary(state)
  end

  def test_unverifiable_pull_request_status_retains_the_issue_and_reports_the_reason
    project, workspace = github_project_and_workspace(task_title: "Unverified delivery")
    # Persisted as open rather than merged: an open PR can still change, so prune must re-check it
    # and keep the record when the forge cannot answer.
    write_merged_delivery_state(
      project,
      workspace,
      delivery_record: merged_delivery_pull_request_record(
        url: pull_request_url(1),
        branch: workspace.fetch("workspace_branch"),
        repository: REPOSITORY
      ).merge("state" => "open", "raw_state" => "OPEN", "merged_at" => nil)
    )
    forge = UnreachableForgeClient.new

    result = apply_command(build_engine(forge_client: forge), "Prune", {})

    assert_empty result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1"], result.dig("result", "retained_issue_ids")
    assert_equal(
      "Pruned 0 issues, 0 projects, and 0 standalone agents. Retained 1 issue because Meringue " \
      "could not verify their pull request status: P1-I1 (the forge lookup was unavailable).",
      result.fetch("message")
    )
    reason = result.dig("result", "retention_reasons", 0)
    assert_equal ["unsettled_pull_requests"], reason.fetch("blockers")
    # The recorded URL plus the branch whose delivery is still unknown, because an open PR record is
    # never trusted without a live answer.
    assert_includes reason.fetch("unverified_pr_urls"), pull_request_url(1)
    assert_includes forge.status_calls, pull_request_url(1)
    assert_includes result.dig("result", "forge_lookup", "unavailable_urls"), pull_request_url(1)

    state = read_state
    assert_equal ["P1-I1"], ids(state.fetch("issues"))
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "an unverified PR must keep its worktree"
    prune_log = state.fetch("logs").last
    assert_equal "warning", prune_log.fetch("level"), "a retention the user cannot see must not be logged as info"
    assert_equal ["P1-I1"], prune_log.dig("details", "retained_issue_ids")
  end

  def test_branch_discovery_failure_only_retains_workers_without_a_recorded_merged_delivery
    project, settled_workspace = github_project_and_workspace(task_title: "Settled delivery")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    unknown_workspace = allocate_workspace(
      manager,
      project,
      task_title: "Unknown delivery",
      issue_id: "P1-I2",
      agent_id: "P1-I2-W1"
    )
    settled_worker = managed_worker_record(settled_workspace, id: "P1-I1-W1", issue_id: "P1-I1")
    unknown_worker = managed_worker_record(unknown_workspace, id: "P1-I2-W1", issue_id: "P1-I2")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(
            id: "P1-I1",
            project_id: "P1",
            status: "completed",
            agent_ids: [settled_worker.fetch("id")],
            extra: delivery_pull_request_fields(
              merged_delivery_pull_request_record(
                url: pull_request_url(1),
                branch: settled_workspace.fetch("workspace_branch"),
                repository: REPOSITORY
              )
            )
          ),
          issue_record(id: "P1-I2", project_id: "P1", status: "completed", agent_ids: [unknown_worker.fetch("id")])
        ],
        agents: [settled_worker, unknown_worker]
      )
    )
    forge = UnreachableForgeClient.new

    result = apply_command(build_engine(forge_client: forge), "Prune", {})

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I2"], result.dig("result", "retained_issue_ids")
    # Only the branch whose delivery is genuinely unknown is discovered, and its failure still
    # conservatively retains the record.
    assert_equal [[REPOSITORY, unknown_workspace.fetch("workspace_branch")]], forge.branch_calls
    blocker = result.dig("result", "issue_decisions").find { |item| item.fetch("issue_id") == "P1-I2" }
                    .fetch("pull_request_blockers").first
    assert_equal "unknown", blocker.fetch("state")
    assert_equal "github-branch://#{REPOSITORY}/#{unknown_workspace.fetch("workspace_branch")}", blocker.fetch("url")
    assert_match(/could not verify their pull request status: P1-I2/, result.fetch("message"))
    assert_equal ["P1-I2"], ids(read_state.fetch("issues"))
  end

  def test_recorded_pull_request_status_is_looked_up_before_exploratory_candidate_urls
    project, workspace = github_project_and_workspace(task_title: "Budget priority")
    stale_urls = [70, 71, 72].map { |number| pull_request_url(number) }
    write_merged_delivery_state(
      project,
      workspace,
      delivery_record: { "url" => pull_request_url(1), "state" => "open" },
      extra_issue_fields: { "candidate_pr_urls" => [pull_request_url(1), *stale_urls] }
    )
    forge = SlowForgeClient.new(
      statuses: {
        pull_request_url(1) => github_pr_status(
          url: pull_request_url(1),
          state: "merged",
          head_branch: workspace.fetch("workspace_branch"),
          repository: REPOSITORY,
          merged_at: "2026-01-02T00:00:00Z"
        )
      }
    )

    result = apply_command(
      build_engine(forge_client: forge, prune_forge_lookup_budget: 0.1),
      "Prune",
      {}
    )

    # The status prune's retention decision depends on is resolved first; the stale candidate URLs
    # are only exploratory, so they are the ones that lose the budget race.
    assert_equal pull_request_url(1), forge.status_calls.first
    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    forge_lookup = result.dig("result", "forge_lookup")
    assert forge_lookup.fetch("budget_exhausted"), "the stalled candidate lookups must exhaust the budget"
    assert_operator forge.status_calls.length, :<, 1 + stale_urls.length,
                    "an exhausted budget must stop calling the forge"
    assert_empty read_state.fetch("issues")
  end

  def test_merged_pull_request_never_overrides_dirty_or_locked_worktree_safety
    project, workspace = github_project_and_workspace(task_title: "Dirty delivery")
    unfinished = File.join(workspace.fetch("workspace_path"), "unfinished.txt")
    File.write(unfinished, "do not discard\n")
    write_merged_delivery_state(project, workspace)
    engine = build_engine(forge_client: UnreachableForgeClient.new)

    dirty = apply_command(engine, "Prune", {})

    assert_empty dirty.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1-W1"], dirty.dig("result", "workspace_cleanup_blocked_agent_ids")
    assert_equal(
      "Pruned 0 issues, 0 projects, and 0 standalone agents. Retained 1 worker because their " \
      "managed worktree could not be removed: P1-I1-W1 (worktree_dirty).",
      dirty.fetch("message")
    )
    assert_equal "do not discard\n", File.read(unfinished)
    assert_equal ["P1-I1-W1"], ids(read_state.fetch("agents"))

    File.delete(unfinished)
    git_output(project, project.fetch("project_root"), "worktree", "lock", "--reason", "manual review",
               workspace.fetch("worktree_root_path"))
    begin
      locked = apply_command(engine, "Prune", {})

      assert_empty locked.dig("result", "removed_issue_ids")
      assert_equal "worktree_locked", locked.dig("result", "workspace_cleanup_outcomes", 0, "reason")
      assert_match(/managed worktree could not be removed: P1-I1-W1 \(worktree_locked\)/, locked.fetch("message"))
      assert Dir.exist?(workspace.fetch("worktree_root_path"))
    ensure
      git_output(project, project.fetch("project_root"), "worktree", "unlock", workspace.fetch("worktree_root_path"))
    end

    unlocked = apply_command(engine, "Prune", {})

    assert_equal ["P1-I1"], unlocked.dig("result", "removed_issue_ids")
    refute Dir.exist?(workspace.fetch("worktree_root_path"))
  end

  # The periodic refresh writes the last failure onto the record. Once the forge answers again the
  # stale error must go, otherwise a healthy merged record still reads as broken.
  def test_delivery_pull_request_refresh_clears_a_stale_failure_once_the_forge_answers
    url = pull_request_url(1)
    stale = merged_delivery_pull_request_record(url: url, branch: "meringue/delivery", repository: REPOSITORY)
            .merge("availability" => "unavailable", "last_refresh_error" => "error connecting to api.github.com")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working", extra: delivery_pull_request_fields(stale))]
      )
    )
    forge = StubForgeClient.new(
      statuses: { url => github_pr_status(url: url, state: "merged", merged_at: "2026-01-02T00:00:00Z") }
    )

    apply_command(build_engine(forge_client: forge), "ReconcileSessions", {})

    record = issue_by_id(read_state, "P1-I1").fetch("delivery_pull_requests").first
    assert_equal "available", record.fetch("availability")
    assert_nil record.fetch("last_refresh_error"), "a successful refresh must clear the previous failure"
  end

  private

  def pull_request_url(number)
    "https://github.com/#{REPOSITORY}/pull/#{number}"
  end

  # A managed git worktree whose project reports a GitHub `origin`, so branch/PR verification runs
  # exactly as it does against a real repository.
  def github_project_and_workspace(task_title:)
    project = create_git_project(@kernel_maintenance_tmp, name: "managed-project")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    workspace = allocate_workspace(manager, project, task_title: task_title)
    git_output(project, project.fetch("project_root"), "remote", "set-url", "origin",
               "https://github.com/#{REPOSITORY}.git")
    [project, workspace]
  end

  def managed_worker_record(workspace, id:, issue_id:, status: "completed")
    worker_record(
      id: id,
      issue_id: issue_id,
      project_id: "P1",
      status: status,
      workspace_path: workspace.fetch("workspace_path"),
      harness_metadata: { "workspace_plan" => workspace },
      extra: {
        "workspace_strategy" => "git_worktree",
        "workspace_branch" => workspace.fetch("workspace_branch")
      }
    )
  end

  def delivery_pull_request_fields(record)
    {
      "delivery_pull_request" => record,
      "delivery_pull_requests" => [record],
      "reported_pr_urls" => [record.fetch("url")]
    }
  end

  def write_merged_delivery_state(project, workspace, delivery_record: nil, extra_issue_fields: {})
    record = delivery_record || merged_delivery_pull_request_record(
      url: pull_request_url(1),
      branch: workspace.fetch("workspace_branch"),
      repository: REPOSITORY
    )
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(
            id: "P1-I1",
            project_id: "P1",
            status: "completed",
            agent_ids: [worker.fetch("id")],
            extra: delivery_pull_request_fields(record).merge(extra_issue_fields)
          )
        ],
        agents: [worker]
      )
    )
  end
end
