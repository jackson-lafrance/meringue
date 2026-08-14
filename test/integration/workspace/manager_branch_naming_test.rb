# frozen_string_literal: true

require "test_helper"
require "support/workspace_support"

# Branch/path names handed to users must read like the task, never like the
# orchestration ids that produced them.
class WorkspaceManagerBranchNamingTest < Minitest::Test
  include WorkspaceSupport

  def test_plan_derives_human_branch_from_task_title
    with_workspace_tmpdir do |tmp|
      plan = workspace_manager(tmp).plan_worker_workspace(
        project_root: File.join(tmp, "meringue"),
        project_id: "P1",
        issue_id: "P1-I9",
        agent_id: "P1-I9-W1",
        task_title: "Question answering does nothing"
      )

      assert_equal "git_worktree", plan.fetch("strategy")
      refute plan.fetch("created")
      assert_match(/\Aquestion-answering-does-nothing-[0-9a-f]{8}\z/, plan.fetch("workspace_branch"))
      assert_equal(
        File.join(tmp, "workspaces", "meringue", plan.fetch("workspace_branch")),
        plan.fetch("workspace_path")
      )
    end
  end

  def test_plan_strips_orchestration_ids_from_branch_name
    with_workspace_tmpdir do |tmp|
      plan = workspace_manager(tmp).plan_worker_workspace(
        project_root: File.join(tmp, "meringue"),
        project_id: "P1",
        issue_id: "P1-I9",
        agent_id: "P1-I9-W2",
        task_title: "P1-I9-W2 H3 Q4 Answer questions properly"
      )

      branch = plan.fetch("workspace_branch")
      assert_equal "answer-questions-properly", branch.sub(/-[0-9a-f]{8}\z/, "")
      refute_match(/p1/i, branch)
      refute_match(/-i9/i, branch)
      refute_match(/w2/i, branch)
      refute_match(/\bh3\b/i, branch)
      refute_match(/\bq4\b/i, branch)
    end
  end

  def test_plan_suffix_is_deterministic_per_worker_and_unique_across_workers
    with_workspace_tmpdir do |tmp|
      manager = workspace_manager(tmp)
      arguments = {
        project_root: File.join(tmp, "meringue"),
        project_id: "P1",
        issue_id: "P1-I9",
        task_title: "Shared task title"
      }

      first = manager.plan_worker_workspace(agent_id: "P1-I9-W1", **arguments)
      repeat = manager.plan_worker_workspace(agent_id: "P1-I9-W1", **arguments)
      other = manager.plan_worker_workspace(agent_id: "P1-I9-W2", **arguments)

      assert_equal first.fetch("workspace_branch"), repeat.fetch("workspace_branch")
      assert_equal first.fetch("workspace_path"), repeat.fetch("workspace_path")
      refute_equal first.fetch("workspace_branch"), other.fetch("workspace_branch")
      assert_equal "shared-task-title", first.fetch("workspace_branch")[/\A(.+)-[0-9a-f]{8}\z/, 1]
    end
  end

  def test_plan_falls_back_to_task_when_title_has_no_usable_words
    with_workspace_tmpdir do |tmp|
      plan = workspace_manager(tmp).plan_worker_workspace(
        project_root: File.join(tmp, "meringue"),
        project_id: "P1",
        issue_id: "P1-I1",
        agent_id: "P1-I1-W1",
        task_title: "P1-I1 ***"
      )

      assert_match(/\Achange-[0-9a-f]{8}\z/, plan.fetch("workspace_branch"))
    end
  end

  def test_plan_truncates_long_titles_and_keeps_project_directory
    with_workspace_tmpdir do |tmp|
      plan = workspace_manager(tmp).plan_worker_workspace(
        project_root: File.join(tmp, "meringue"),
        project_id: "P1",
        issue_id: "P1-I1",
        agent_id: "P1-I1-W1",
        task_title: "Integration tests for workspace and worktree management across the whole kernel"
      )

      slug = plan.fetch("workspace_branch")[/\A(.+)-[0-9a-f]{8}\z/, 1]
      assert_operator slug.length, :<=, 48
      refute slug.end_with?("-")
      assert_equal File.join(tmp, "workspaces", "meringue"), File.dirname(plan.fetch("workspace_path"))
    end
  end
end
