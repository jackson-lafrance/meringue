# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"

# Prune of resolved (completed/killed) records: which records leave active state, which
# retention rules block removal, and what the command reports back. `/prune` takes no options,
# so the legacy selector words are only recorded for traceability and never change the outcome.
class KernelMaintenancePruneResolvedTest < Minitest::Test
  include KernelMaintenanceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  def test_prune_removes_completed_issue_bundle_and_reports_counts_and_log
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: ["P1-I1-W1"])],
        agents: [worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "completed")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_equal "accepted", result.fetch("status")
    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects.", result.fetch("message")
    details = result.fetch("result")
    assert_equal ["P1-I1"], details.fetch("removed_issue_ids")
    assert_equal ["P1-I1-W1"], details.fetch("removed_agent_ids")
    assert_empty details.fetch("removed_project_ids")
    assert_equal "resolved", details.fetch("requested_selector")

    state = read_state
    assert_empty state.fetch("issues")
    assert_empty state.fetch("agents")
    assert_equal ["P1"], ids(state.fetch("projects"))
    prune_log = state.fetch("logs").last
    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects.", prune_log.fetch("message")
    assert_equal "kernel", prune_log.fetch("source_type")
    assert_equal "info", prune_log.fetch("level")
    assert_equal ["P1-I1"], prune_log.dig("details", "removed_issue_ids")
    assert_documented_status_vocabulary(state)
  end

  def test_legacy_selector_words_are_recorded_but_do_not_change_the_prune
    %w[all completed merged resolved errored].each do |alias_selector|
      write_state(
        state_fixture(
          projects: [project_record(id: "P1", status: "working")],
          issues: [issue_record(id: "P1-I1", project_id: "P1", status: "killed")],
          agents: []
        )
      )
      engine = build_engine

      result = apply_command(engine, "Prune", "selector" => alias_selector)

      assert_equal "accepted", result.fetch("status")
      assert_equal alias_selector, result.dig("result", "requested_selector")
      assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    end
  end

  def test_prune_without_a_selector_removes_everything_eligible
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", {})

    assert_equal "accepted", result.fetch("status")
    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    # No selector is recorded because the command has no options.
    assert_nil result.dig("result", "requested_selector")
    assert_empty read_state.fetch("issues")
  end

  # The input layer rejects unknown `/prune` arguments (see the slash command parser tests). The
  # kernel itself never fails on one: it records the word and prunes everything eligible.
  def test_unknown_selector_value_is_recorded_and_ignored
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "everything")

    assert_equal "accepted", result.fetch("status")
    assert_equal "everything", result.dig("result", "requested_selector")
    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_empty read_state.fetch("issues")
  end

  def test_nonterminal_child_issue_retains_completed_parent_subtree
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "completed"),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", parent_issue_id: "P1-I1")
        ]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_empty result.dig("result", "removed_issue_ids")
    decision = result.dig("result", "issue_decisions").find { |entry| entry.fetch("issue_id") == "P1-I1" }
    refute decision.fetch("prunable")
    assert_includes decision.fetch("blockers"), "nonterminal_issues"
    assert_equal ["P1-I2"], decision.fetch("nonterminal_issue_ids")
    assert_equal %w[P1-I1 P1-I2], ids(read_state.fetch("issues"))
  end

  def test_unresolved_worker_statuses_block_pruning
    %w[queued working blocked].each do |worker_status|
      write_state(
        state_fixture(
          projects: [project_record(id: "P1", status: "working")],
          issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: ["P1-I1-W1"])],
          agents: [worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: worker_status)]
        )
      )
      engine = build_engine

      result = apply_command(engine, "Prune", "selector" => "resolved")

      assert_empty result.dig("result", "removed_issue_ids"), "#{worker_status} worker should retain its issue"
      decision = result.dig("result", "issue_decisions").first
      assert_includes decision.fetch("blockers"), "unresolved_workers"
      assert_equal ["P1-I1-W1"], decision.fetch("blocking_worker_ids")
      assert_equal ["P1-I1"], ids(read_state.fetch("issues"))
    end
  end

  def test_completed_killed_and_errored_workers_do_not_block_pruning
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: %w[P1-I1-W1 P1-I1-W2 P1-I1-W3])],
        agents: [
          worker_record(id: "P1-I1-W1", issue_id: "P1-I1", project_id: "P1", status: "completed"),
          worker_record(id: "P1-I1-W2", issue_id: "P1-I1", project_id: "P1", status: "killed"),
          worker_record(id: "P1-I1-W3", issue_id: "P1-I1", project_id: "P1", status: "errored")
        ]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    assert_equal %w[P1-I1-W1 P1-I1-W2 P1-I1-W3], result.dig("result", "removed_agent_ids").sort
    assert_empty read_state.fetch("agents")
  end

  def test_open_question_retains_its_issue_and_project
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "completed")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed")],
        questions: [question_record(id: "Q1", project_id: "P1", issue_id: "P1-I1", status: "open")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    issue_decision = result.dig("result", "issue_decisions").first
    refute issue_decision.fetch("prunable")
    assert_includes issue_decision.fetch("blockers"), "open_questions"
    assert_equal ["Q1"], issue_decision.fetch("open_question_ids")

    project_decision = result.dig("result", "project_decisions").first
    refute project_decision.fetch("prunable")
    assert_includes project_decision.fetch("blockers"), "open_questions"

    state = read_state
    assert_equal ["P1-I1"], ids(state.fetch("issues"))
    assert_equal ["P1"], ids(state.fetch("projects"))
    assert_equal "open", question_by_id(state, "Q1").fetch("status")
  end

  def test_answered_and_dismissed_questions_do_not_block_pruning
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed")],
        questions: [
          question_record(id: "Q1", issue_id: "P1-I1", status: "answered"),
          question_record(id: "Q2", issue_id: "P1-I1", status: "dismissed")
        ]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    # Questions are not executable work, so pruning an issue leaves their records alone.
    assert_equal %w[Q1 Q2], ids(read_state.fetch("questions"))
  end

  def test_open_pull_request_blocks_pruning_and_merged_or_closed_does_not
    url_open = "https://github.com/acme/app/pull/1"
    url_merged = "https://github.com/acme/app/pull/2"
    url_closed = "https://github.com/acme/app/pull/3"
    forge = StubForgeClient.new(
      statuses: {
        url_open => github_pr_status(url: url_open, state: "open"),
        url_merged => github_pr_status(url: url_merged, state: "merged", merged_at: "2026-01-02T00:00:00Z"),
        url_closed => github_pr_status(url: url_closed, state: "closed")
      }
    )
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [
          issue_with_pull_request(id: "P1-I1", project_id: "P1", url: url_open),
          issue_with_pull_request(id: "P1-I2", project_id: "P1", url: url_merged),
          issue_with_pull_request(id: "P1-I3", project_id: "P1", url: url_closed)
        ]
      )
    )
    engine = build_engine(forge_client: forge)

    result = apply_command(engine, "Prune", "selector" => "merged")

    assert_equal %w[P1-I2 P1-I3], result.dig("result", "removed_issue_ids").sort
    assert_equal [url_open], result.dig("result", "blocked_pr_urls")
    blocked = result.dig("result", "issue_decisions").find { |entry| entry.fetch("issue_id") == "P1-I1" }
    assert_includes blocked.fetch("blockers"), "unsettled_pull_requests"
    assert_equal ["P1-I1"], ids(read_state.fetch("issues"))
    assert_includes forge.status_calls, url_open
  end

  def test_draft_pull_request_blocks_pruning
    url = "https://github.com/acme/app/pull/9"
    forge = StubForgeClient.new(statuses: { url => github_pr_status(url: url, state: "open", is_draft: true) })
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_with_pull_request(id: "P1-I1", project_id: "P1", url: url)]
      )
    )
    engine = build_engine(forge_client: forge)

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_empty result.dig("result", "removed_issue_ids")
    assert_equal [url], result.dig("result", "blocked_pr_urls")
    assert_equal ["P1-I1"], ids(read_state.fetch("issues"))
  end

  def test_unresolvable_pull_request_status_blocks_pruning
    url = "https://github.com/acme/app/pull/404"
    forge = StubForgeClient.new(statuses: { url => unavailable_pr_status(url: url) })
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_with_pull_request(id: "P1-I1", project_id: "P1", url: url)]
      )
    )
    engine = build_engine(forge_client: forge)

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_empty result.dig("result", "removed_issue_ids")
    blockers = result.dig("result", "issue_decisions").first.fetch("pull_request_blockers")
    assert_equal ["unknown"], blockers.map { |status| status.fetch("state") }
    assert_equal ["P1-I1"], ids(read_state.fetch("issues"))
  end

  def test_project_is_removed_only_when_it_is_terminal_and_every_issue_is_eligible
    write_state(
      state_fixture(
        projects: [
          project_record(id: "P1", status: "completed"),
          project_record(id: "P2", status: "completed"),
          project_record(id: "P3", status: "working")
        ],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "completed"),
          issue_record(id: "P2-I1", project_id: "P2", status: "completed"),
          issue_record(id: "P2-I2", project_id: "P2", status: "working"),
          issue_record(id: "P3-I1", project_id: "P3", status: "completed")
        ]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_equal ["P1"], result.dig("result", "removed_project_ids")
    assert_equal %w[P1-I1 P2-I1 P3-I1], result.dig("result", "removed_issue_ids").sort
    assert_equal "Pruned 3 issues, 0 agents, 0 worktrees, and 1 project.", result.fetch("message")

    state = read_state
    assert_equal %w[P2 P3], ids(state.fetch("projects"))
    assert_equal ["P2-I2"], ids(state.fetch("issues"))

    p2 = result.dig("result", "project_decisions").find { |entry| entry.fetch("project_id") == "P2" }
    assert_includes p2.fetch("blockers"), "ineligible_issues"
    assert_equal ["P2-I2"], p2.fetch("ineligible_issue_ids")
    p3 = result.dig("result", "project_decisions").find { |entry| entry.fetch("project_id") == "P3" }
    assert_includes p3.fetch("blockers"), "project_not_terminal"
  end

  def test_prune_retains_a_worker_when_managed_worktree_ownership_cannot_be_verified
    workspace = make_dir("workspaces", "acme", "fix-signup-a1b2c3d4")
    File.write(File.join(workspace, "NOTES.md"), "worker output\n")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: ["P1-I1-W1"])],
        agents: [
          worker_record(
            id: "P1-I1-W1",
            issue_id: "P1-I1",
            project_id: "P1",
            status: "completed",
            workspace_path: workspace
          )
        ]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_empty result.dig("result", "removed_agent_ids")
    assert_equal ["P1-I1-W1"], result.dig("result", "workspace_cleanup_blocked_agent_ids")
    assert_equal "branch_not_meringue_managed", result.dig("result", "workspace_cleanup_outcomes", 0, "reason")
    assert Dir.exist?(workspace), "prune must not guess that an unverified directory is safe to delete"
    assert_equal "worker output\n", File.read(File.join(workspace, "NOTES.md"))
    assert_equal ["P1-I1-W1"], ids(read_state.fetch("agents"))
  end

  def test_prune_removes_head_records_related_to_pruned_work
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "completed", extra: { "originating_head_id" => "H1" })
        ],
        agents: [
          head_record(id: "H1", status: "completed"),
          head_record(
            id: "H2",
            status: "completed",
            harness_metadata: {
              "head_result" => {
                "commands" => [{ "type" => "SpawnWorker", "payload" => { "issue_id" => "P1-I1" } }]
              }
            }
          ),
          head_record(id: "H3", status: "working")
        ]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_equal %w[H1 H2], result.dig("result", "removed_agent_ids").sort
    assert_equal ["H3"], ids(read_state.fetch("agents"))
  end

  def test_prune_with_nothing_eligible_is_accepted_and_reports_zero_counts
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "working")]
      )
    )
    engine = build_engine

    result = apply_command(engine, "Prune", "selector" => "resolved")

    assert_equal "accepted", result.fetch("status")
    assert_equal "Pruned 0 issues, 0 agents, 0 worktrees, and 0 projects.", result.fetch("message")
    assert_empty result.dig("result", "removed_issue_ids")
    assert_equal ["P1-I1"], ids(read_state.fetch("issues"))
  end
end
