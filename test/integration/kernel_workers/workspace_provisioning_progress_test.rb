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
      [[60, 15], [120, 45], [180, 90]].each do |elapsed, percent|
        progress.call(
          "command" => "git worktree add",
          "elapsed" => elapsed,
          "quiet_for" => 0,
          "detail" => "Updating files: #{percent}% (#{percent}/100)"
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

    progress_entries_by_snapshot = manager.snapshots.map do |state|
      state.fetch("logs").select { |entry| entry.dig("details", "kind") == "workspace_provisioning_progress" }
    end
    assert progress_entries_by_snapshot.all? { |entries| entries.length == 1 },
           "every durable and visible snapshot keeps one evolving provisioning line"
    assert_equal [60, 120, 180], progress_entries_by_snapshot.map { |entries| entries.first.dig("details", "elapsed_seconds") }
    assert_equal [15, 45, 90], progress_entries_by_snapshot.map { |entries| entries.first.dig("details", "percent") }
    assert_equal 3, progress_entries_by_snapshot.map { |entries| entries.first.fetch("id") }.uniq.length,
                 "each replacement is a newly ordered event with a monotonic log id"
    replacement_keys = progress_entries_by_snapshot.map { |entries| entries.first.fetch("replacement_key") }
    assert_equal 1, replacement_keys.uniq.length
    assert_match(/\Aworker_workspace_provisioning:[0-9a-f-]+\z/, replacement_keys.first)

    latest = manager.snapshots.last.fetch("agents").find { |agent| agent["id"] == "P1-I1-W1" }
    assert_equal 90, latest.dig("harness_metadata", "provisioning_progress", "percent")
    assert_equal ["Still provisioning worker P1-I1-W1: git worktree add has been running for 180s " \
                  "(Updating files: 90% (90/100))."],
                 progress_entries_by_snapshot.last.map { |entry| entry.fetch("message") }

    persisted_progress = state(engine).fetch("logs").select do |entry|
      entry.dig("details", "kind") == "workspace_provisioning_progress"
    end
    assert_equal 1, persisted_progress.length
    assert_equal 180, persisted_progress.first.dig("details", "elapsed_seconds")
    assert logs_matching(engine, /Worker workspace provisioning failed/).any?,
           "the terminal failure remains an independent event after the latest progress line"

    # Once the checkout fails, the progress is no longer presented as live and the worker remains
    # resumable rather than pretending that a partial checkout is a ready workspace.
    worker = agent(engine, "P1-I1-W1")
    assert_equal "blocked", worker.fetch("status")
    assert_equal "retry_exhausted", worker.dig("harness_metadata", "provisioning_state")
    refute worker.fetch("harness_metadata").key?("provisioning_progress")
  end

  def test_concurrent_instances_leave_one_latest_progress_entry_for_the_worker
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    baseline_counter = state(engine).dig("counters", "logs")
    engines = [restarted_engine, restarted_engine]

    threads = 12.times.map do |index|
      Thread.new do
        engines.fetch(index % engines.length).send(
          :record_worker_provisioning_progress,
          worker_id,
          {
            "command" => "git worktree add",
            "elapsed" => 60 + index,
            "detail" => "Updating files: #{index + 1}% (#{index + 1}/100)"
          },
          log: true
        )
      end
    end
    threads.each(&:join)

    # Make the final state deterministic after exercising the race. The same atomic replacement
    # path must remove whichever concurrent update committed last.
    engines.first.send(
      :record_worker_provisioning_progress,
      worker_id,
      {
        "command" => "git worktree add",
        "elapsed" => 999,
        "detail" => "Updating files: 99% (99/100)"
      },
      log: true
    )

    reloaded = Meringue::State::Store.new(path: state_path).load
    replacement_key = reloaded.fetch("agents").find { |agent| agent.fetch("id") == worker_id }
                              .dig("harness_metadata", "provisioning_progress_log_replacement_key")
    progress_logs = reloaded.fetch("logs").select do |entry|
      entry.fetch("replacement_key", nil) == replacement_key
    end
    assert_match(/\Aworker_workspace_provisioning:[0-9a-f-]+\z/, replacement_key)
    assert_equal 1, progress_logs.length
    assert_equal worker_id, progress_logs.first.fetch("source_id")
    assert_equal worker_id, progress_logs.first.dig("details", "agent_id")
    assert_equal 999, progress_logs.first.dig("details", "elapsed_seconds")
    assert_equal 99, progress_logs.first.dig("details", "percent")
    assert_equal baseline_counter + 13, reloaded.dig("counters", "logs"),
                 "every committed replacement consumes a unique monotonic id"
  end

  private

  def restarted_engine
    Meringue::Kernel::Engine.new(
      store: Meringue::State::Store.new(path: state_path),
      harness_client: KernelWorkersSupport::RecordingHarnessClient.new,
      head_runner: Meringue::Heads::FakeRunner.new,
      workspace_manager: Meringue::Workspace::Manager.new(root_path: workspace_root),
      cwd: tmpdir,
      forge_client: KernelWorkersSupport::OfflineForgeClient.new,
      config_path: tmp_path("config.toml")
    )
  end
end
