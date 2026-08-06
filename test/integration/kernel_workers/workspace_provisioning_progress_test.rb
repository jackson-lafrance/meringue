# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Progress is written while the workspace manager is still in git worktree setup. It is deliberately
# separate from the eventual spawn result: a slow checkout remains a queued worker until the
# workspace and harness are both ready.
class KernelWorkersWorkspaceProvisioningProgressTest < Minitest::Test
  include KernelWorkersSupport

  class ProgressReportingWorkspaceManager < Meringue::Workspace::Manager
    attr_reader :snapshots

    def initialize(snapshot:, **options)
      super(**options)
      @snapshot = snapshot
      @snapshots = []
    end

    def allocate_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil, progress: nil)
      [15, 30, 60].each do |elapsed|
        progress.call(
          "command" => "git worktree add",
          "elapsed" => elapsed,
          "quiet_for" => 0,
          "detail" => "Updating files: #{elapsed}% (#{elapsed}/100)"
        )
        @snapshots << @snapshot.call
      end

      plan_worker_workspace(
        project_root: project_root,
        project_id: project_id,
        issue_id: issue_id,
        agent_id: agent_id,
        task_title: task_title
      ).merge(
        "created" => false,
        "errors" => ["simulated checkout failure"],
        "recovery" => Meringue::Workspace::Manager::RECOVERY_RESUME
      )
    end
  end

  def test_checkout_progress_reaches_the_agenttree_before_provisioning_finishes
    manager = nil
    snapshot = lambda do
      JSON.parse(JSON.generate(store.load))
    end
    manager = ProgressReportingWorkspaceManager.new(snapshot: snapshot, root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)

    result = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })

    assert_equal "failed", result.fetch("status")
    assert_equal 3, manager.snapshots.length

    first_progress = manager.snapshots.fetch(0).fetch("agents").find { |agent| agent["id"] == "P1-I1-W1" }
    first_metadata = first_progress.fetch("harness_metadata")
    assert_equal "allocating_workspace", first_metadata.fetch("provisioning_state")
    assert_equal "checkout", first_metadata.dig("provisioning_progress", "phase")
    assert_equal 15, first_metadata.dig("provisioning_progress", "percent")
    assert_equal "Updating files: 15% (15/100)", first_metadata.dig("provisioning_progress", "detail")

    latest = manager.snapshots.last.fetch("agents").find { |agent| agent["id"] == "P1-I1-W1" }
    assert_equal 60, latest.dig("harness_metadata", "provisioning_progress", "percent")
    assert_equal 1, logs_matching(engine, /Still provisioning worker P1-I1-W1/).length,
                 "progress is persisted every update but narrated only once per minute"

    # Once the checkout fails, the progress is no longer presented as live and the worker remains
    # resumable rather than pretending that a partial checkout is a ready workspace.
    worker = agent(engine, "P1-I1-W1")
    assert_equal "blocked", worker.fetch("status")
    assert_equal "retry_exhausted", worker.dig("harness_metadata", "provisioning_state")
    refute worker.fetch("harness_metadata").key?("provisioning_progress")
  end
end
