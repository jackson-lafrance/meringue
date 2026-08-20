# frozen_string_literal: true

require "test_helper"
require "support/kernel_maintenance_support"
require "support/workspace_support"

# Regression coverage for the post-commit cleanup retry. When a /prune pass cannot remove a
# managed worktree within its bounded budget (`worktree_cleanup_timed_out`,
# `prune_cleanup_budget_exhausted`, or a transient remove failure), the worktree is left on disk
# with no owning worker. The kernel now re-runs the same safe removal after the pass settles and
# reports exactly what it recovered and what it had to retain.
class KernelMaintenancePrunePostPruneCleanupTest < Minitest::Test
  include KernelMaintenanceSupport
  include WorkspaceSupport

  def setup
    kernel_maintenance_setup
  end

  def teardown
    kernel_maintenance_teardown
  end

  # Manager whose first `git worktree remove` for a given worktree path times out (mirroring
  # `worktree_cleanup_timed_out` from the real cleanup path), then succeeds on the post-prune
  # retry. The timeout is injected via `run_command`, so the real `cleanup_pruned_worker_workspace`
  # flow runs and produces the same structured outcome (with `git_root`) that production would.
  class RetryableTimingOutCleanupManager < Meringue::Workspace::Manager
    def initialize(**options)
      super
      @timed_out_removes = []
    end

    def run_command(*argv, **options)
      tokens = argv.map(&:to_s)
      if tokens.include?("worktree") && tokens.include?("remove") &&
         !@timed_out_removes.include?(argv.last.to_s)
        @timed_out_removes << argv.last.to_s
        raise Meringue::Workspace::Manager::CommandTimeout.new(
          argv: argv, timeout: 0.25, stdout: "", stderr: "simulated cleanup hang"
        )
      end
      super
    end
  end

  class BlockingRetryCleanupManager < Meringue::Workspace::Manager
    def initialize(**options)
      super
      @remove_calls = 0
      @retry_started = Queue.new
      @release_retry = Queue.new
    end

    def run_command(*argv, **options)
      tokens = argv.map(&:to_s)
      if tokens.include?("worktree") && tokens.include?("remove")
        @remove_calls += 1
        if @remove_calls == 1
          raise Meringue::Workspace::Manager::CommandTimeout.new(
            argv: argv, timeout: 0.25, stdout: "", stderr: "simulated first-pass timeout"
          )
        elsif @remove_calls == 2
          @retry_started << true
          @release_retry.pop
        end
      end
      super
    end

    def wait_for_retry
      Timeout.timeout(5) { @retry_started.pop }
    end

    def release_retry
      @release_retry << true
    end
  end

  class RecordingRetryManager
    attr_reader :record

    def cleanup_pruned_worker_workspace(record, protected_paths:, deadline:)
      @record = record
      {
        "status" => "removed",
        "reason" => "provider_workspace_released",
        "success" => true,
        "attempted" => true,
        "worktree_root_path" => record.fetch("worktree_root_path"),
        "workspace_branch" => record.fetch("workspace_branch"),
        "git_root" => record.fetch("git_root")
      }
    end
  end

  def test_post_prune_cleanup_removes_a_worktree_the_pass_timed_out_on
    project, workspace = managed_project_and_workspace(task_title: "Timed out cleanup")
    manager = RetryableTimingOutCleanupManager.new(root_path: tmp_path("workspaces"))
    # Reallocate through the timing-out manager so the worktree exists on disk and is registered.
    workspace = allocate_workspace(manager, project, task_title: "Timed out cleanup")
    write_managed_worker_state_with(project, workspace, manager)

    result = apply_command(build_engine(workspace_manager: manager), "Prune", {})

    # The pass itself could not remove the worktree (timed out), so its worktree count is zero and
    # the retention sentence still names the worker. The post-prune cleanup then removed it.
    assert_equal ["P1-I1"], result.dig("result", "removed_issue_ids")
    pass_cleanups = result.dig("result", "workspace_cleanup_outcomes")
    assert_equal "worktree_cleanup_timed_out", pass_cleanups.first.fetch("reason")
    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects. " \
                 "Preserved 1 managed worktree because cleanup was not safe: P1-I1-W1 (worktree_cleanup_timed_out). " \
                 "Post-prune cleanup removed 1 worktree the pass left behind.",
                 result.fetch("message")
    refute Dir.exist?(workspace.fetch("worktree_root_path")), "the post-prune cleanup must remove the timed-out worktree"
    assert branch_exists?(project, workspace.fetch("workspace_branch")), "the delivery branch must survive"

    state = read_state
    post_prune_log = state.fetch("logs").find { |log| log.dig("details", "kind") == "post_prune_cleanup" }
    assert post_prune_log, "the post-prune cleanup must surface a visible log entry"
    assert_equal "info", post_prune_log.fetch("level")
    summary = post_prune_log.dig("details", "summary")
    assert_equal 1, summary.fetch("removed_count")
    assert_equal 0, summary.fetch("retained_count")
    assert_equal ["P1-I1-W1"], summary.fetch("removed_agent_ids")
  end

  def test_post_prune_cleanup_runs_without_holding_the_state_lock
    project = create_git_project(@kernel_maintenance_tmp, name: "unlocked-retry-project")
    manager = BlockingRetryCleanupManager.new(root_path: tmp_path("blocking-workspaces"))
    workspace = allocate_workspace(manager, project, task_title: "Unlocked retry")
    write_managed_worker_state_with(project, workspace, manager)
    engine = build_engine(workspace_manager: manager)
    prune_thread = Thread.new { apply_command(engine, "Prune", {}) }

    manager.wait_for_retry
    state_result = Timeout.timeout(1) { apply_command(engine, "GetState", {}) }
    assert_equal "accepted", state_result.fetch("status")
  ensure
    manager&.release_retry
    result = prune_thread&.value
    assert_equal 1, result&.dig("result", "post_prune_cleanup", "summary", "removed_count") if result
  end

  def test_retry_preserves_external_provider_identity
    manager = RecordingRetryManager.new
    engine = build_engine(workspace_manager: manager)
    outcome = {
      "agent_id" => "P1-I1-W1",
      "worktree_root_path" => tmp_path("provider-worktree"),
      "workspace_branch" => "cleanup-provider-12345678",
      "git_root" => tmp_path("provider-repo"),
      "workspace_owner_id" => "P1-I1-W1",
      "requested_worktree_provider" => "command",
      "worktree_provider" => "command",
      "worktree_provider_identifier" => "private-slot",
      "worktree_provider_cwd" => tmp_path("provider-cwd"),
      "project_root" => tmp_path("provider-repo"),
      "status" => "failed",
      "reason" => "external_provider_release_failed",
      "success" => false
    }

    retried = engine.send(
      :retry_blocked_worktree_cleanup,
      outcome,
      protected_paths: [],
      deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    )

    assert_equal "removed", retried.fetch("status")
    assert_equal "command", manager.record.fetch("worktree_provider")
    assert_equal "private-slot", manager.record.fetch("worktree_provider_identifier")
    assert_equal "P1-I1-W1", manager.record.fetch("workspace_owner_id")
  end

  def test_post_prune_cleanup_removes_worktrees_the_pass_budget_exhausted
    project = create_git_project(@kernel_maintenance_tmp, name: "managed-project")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    workspaces = (1..3).map do |index|
      allocate_workspace(manager, project, task_title: "Budgeted cleanup #{index}",
                         issue_id: "P1-I#{index}", agent_id: "P1-I#{index}-W1")
    end
    workers = workspaces.each_with_index.map do |ws, index|
      managed_worker_record(ws, id: "P1-I#{index + 1}-W1", issue_id: "P1-I#{index + 1}", status: "completed")
    end
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "completed")],
        issues: workers.each_with_index.map do |worker, index|
          issue_record(id: "P1-I#{index + 1}", project_id: "P1", status: "completed", agent_ids: [worker.fetch("id")])
        end,
        agents: workers
      )
    )

    # A zero cleanup budget exhausts before the pass can attempt any worktree, mirroring the
    # `prune_cleanup_budget_exhausted` outcomes that left worktrees on disk with no owning worker.
    result = apply_command(
      build_engine(workspace_manager: manager, prune_workspace_cleanup_budget: 0.0),
      "Prune",
      {}
    )

    pass_cleanups = result.dig("result", "workspace_cleanup_outcomes")
    assert_equal 3, pass_cleanups.length
    assert(pass_cleanups.all? { |outcome| outcome.fetch("reason") == "prune_cleanup_budget_exhausted" },
           "the pass must budget-exhaust every worktree when its budget is zero")
    # The budget-exhausted outcome carries the persisted path/branch/git_root so the post-prune
    # cleanup can retry without the worker record (which the pass has removed).
    assert(pass_cleanups.all? { |outcome| outcome.fetch("worktree_root_path") && outcome.fetch("git_root") },
           "budget-exhausted outcomes must carry enough identity for the post-prune retry")

    assert_equal "Pruned 3 issues, 3 agents, 0 worktrees, and 1 project. " \
                 "Preserved 3 managed worktrees because cleanup was not safe: " \
                 "P1-I1-W1 (prune_cleanup_budget_exhausted), P1-I2-W1 (prune_cleanup_budget_exhausted), " \
                 "P1-I3-W1 (prune_cleanup_budget_exhausted). " \
                 "Post-prune cleanup removed 3 worktrees the pass left behind.",
                 result.fetch("message")
    workspaces.each { |ws| refute Dir.exist?(ws.fetch("worktree_root_path")) }
    workspaces.each { |ws| assert branch_exists?(project, ws.fetch("workspace_branch")) }

    summary = result.dig("result", "post_prune_cleanup", "summary")
    assert_equal 3, summary.fetch("removed_count")
    assert_equal 0, summary.fetch("retained_count")
  end

  def test_post_prune_cleanup_never_force_removes_a_dirty_worktree
    project, workspace = managed_project_and_workspace(task_title: "Dirty post-prune")
    unfinished = File.join(workspace.fetch("workspace_path"), "unfinished.txt")
    File.write(unfinished, "do not discard\n")
    write_managed_worker_state(project, workspace)

    result = apply_command(build_engine, "Prune", {})

    assert_equal "worktree_dirty", result.dig("result", "workspace_cleanup_outcomes", 0, "reason")
    # The post-prune retry must refuse the dirty worktree again, never force-remove it.
    assert_equal "do not discard\n", File.read(unfinished)
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a dirty worktree must never be forced away"

    summary = result.dig("result", "post_prune_cleanup", "summary")
    assert_equal 0, summary.fetch("removed_count")
    assert_equal 1, summary.fetch("retained_count")
    assert_equal "warning", summary.fetch("level")
    retained = summary.fetch("retained").first
    assert_equal "P1-I1-W1", retained.fetch("agent_id")
    assert_equal "worktree_dirty", retained.fetch("reason")

    # A dirty worktree is retained, so the prune message is unchanged from the existing behavior.
    assert_equal "Pruned 1 issue, 1 agent, 0 worktrees, and 0 projects. " \
                 "Preserved 1 managed worktree because cleanup was not safe: P1-I1-W1 (worktree_dirty).",
                 result.fetch("message")
  end

  def test_post_prune_cleanup_never_force_removes_a_locked_worktree
    project, workspace = managed_project_and_workspace(task_title: "Locked post-prune")
    git_output(project, project.fetch("project_root"), "worktree", "lock", "--reason", "manual review",
               workspace.fetch("worktree_root_path"))
    write_managed_worker_state(project, workspace)

    result = apply_command(build_engine, "Prune", {})

    assert_equal "worktree_locked", result.dig("result", "workspace_cleanup_outcomes", 0, "reason")
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "a locked worktree must never be forced away"
    summary = result.dig("result", "post_prune_cleanup", "summary")
    assert_equal 0, summary.fetch("removed_count")
    assert_equal 1, summary.fetch("retained_count")
    assert_equal "worktree_locked", summary.fetch("retained").first.fetch("reason")
  ensure
    if workspace && Dir.exist?(workspace.fetch("worktree_root_path", ""))
      git_output(project, project.fetch("project_root"), "worktree", "unlock", workspace.fetch("worktree_root_path"))
    end
  end

  def test_post_prune_cleanup_leaves_an_actively_referenced_worktree_alone
    project, workspace = managed_project_and_workspace(task_title: "Actively referenced")
    # A second live worker still using the same worktree keeps it alive; the prune pass skips the
    # completed sharer and the post-prune cleanup must not touch the shared checkout.
    first = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "completed")
    second = managed_worker_record(workspace, id: "P1-I2-W1", issue_id: "P1-I2", status: "working")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: [first.fetch("id")]),
          issue_record(id: "P1-I2", project_id: "P1", status: "working", agent_ids: [second.fetch("id")])
        ],
        agents: [first, second]
      )
    )

    result = apply_command(build_engine, "Prune", {})

    cleanup = result.dig("result", "workspace_cleanup_outcomes", 0)
    assert_equal "skipped", cleanup.fetch("status")
    assert_equal "workspace_shared_with_retained_worker", cleanup.fetch("reason")
    assert_nil result.dig("result", "post_prune_cleanup"),
               "a pass with no blocked cleanups must not spawn a post-prune cleanup"
    assert Dir.exist?(workspace.fetch("worktree_root_path")), "the live worker's checkout must remain"
  end

  def test_post_prune_cleanup_retries_each_unresolved_worktree_once
    project = create_git_project(@kernel_maintenance_tmp, name: "managed-project")
    manager = RetryableTimingOutCleanupManager.new(root_path: tmp_path("workspaces"))
    clean_workspace = allocate_workspace(manager, project, task_title: "Recoverable timeout",
                                         issue_id: "P1-I1", agent_id: "P1-I1-W1")
    dirty_workspace = allocate_workspace(manager, project, task_title: "Dirty timeout",
                                         issue_id: "P1-I2", agent_id: "P1-I2-W1")
    File.write(File.join(dirty_workspace.fetch("workspace_path"), "unfinished.txt"), "keep me\n")
    clean_worker = managed_worker_record(clean_workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "completed")
    dirty_worker = managed_worker_record(dirty_workspace, id: "P1-I2-W1", issue_id: "P1-I2", status: "completed")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "completed")],
        issues: [
          issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: [clean_worker.fetch("id")]),
          issue_record(id: "P1-I2", project_id: "P1", status: "completed", agent_ids: [dirty_worker.fetch("id")])
        ],
        agents: [clean_worker, dirty_worker]
      )
    )

    result = apply_command(build_engine(workspace_manager: manager), "Prune", {})

    # The recoverable (timed-out) worktree is removed by the safe retry; the dirty one is retained.
    refute Dir.exist?(clean_workspace.fetch("worktree_root_path"))
    assert Dir.exist?(dirty_workspace.fetch("worktree_root_path"))

    summary = result.dig("result", "post_prune_cleanup", "summary")
    assert_equal 1, summary.fetch("removed_count")
    assert_equal 1, summary.fetch("retained_count")

    retained = summary.fetch("retained").first
    assert_equal "P1-I2-W1", retained.fetch("agent_id")
    assert_equal "worktree_dirty", retained.fetch("reason")
  end

  def test_repeated_prune_is_idempotent_after_post_prune_cleanup
    project, workspace = managed_project_and_workspace(task_title: "Idempotent cleanup")
    manager = RetryableTimingOutCleanupManager.new(root_path: tmp_path("workspaces"))
    workspace = allocate_workspace(manager, project, task_title: "Idempotent cleanup")
    write_managed_worker_state_with(project, workspace, manager)

    first = apply_command(build_engine(workspace_manager: manager), "Prune", {})
    assert_equal 1, first.dig("result", "post_prune_cleanup", "summary", "removed_count")
    refute Dir.exist?(workspace.fetch("worktree_root_path"))

    # A second pass finds nothing to prune: no records, no blocked cleanups, no post-prune cleanup.
    second = apply_command(build_engine(workspace_manager: manager), "Prune", {})
    assert_equal "Pruned 0 issues, 0 agents, 0 worktrees, and 0 projects.", second.fetch("message")
    assert_nil second.dig("result", "post_prune_cleanup")
    state = read_state
    post_prune_logs = state.fetch("logs").select { |log| log.dig("details", "kind") == "post_prune_cleanup" }
    assert_equal 1, post_prune_logs.length, "a second empty prune must not duplicate the post-prune cleanup log"
  end

  private

  def managed_project_and_workspace(task_title:)
    project = create_git_project(@kernel_maintenance_tmp, name: "managed-project")
    manager = Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces"))
    workspace = allocate_workspace(manager, project, task_title: task_title)
    [project, workspace]
  end

  def managed_worker_record(workspace, id:, issue_id:, status:)
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

  def write_managed_worker_state(project, workspace)
    write_managed_worker_state_with(project, workspace, Meringue::Workspace::Manager.new(root_path: tmp_path("workspaces")))
  end

  def write_managed_worker_state_with(project, workspace, _manager)
    worker = managed_worker_record(workspace, id: "P1-I1-W1", issue_id: "P1-I1", status: "completed")
    write_state(
      state_fixture(
        projects: [project_record(id: "P1", root_path: project.fetch("project_root"), status: "working")],
        issues: [issue_record(id: "P1-I1", project_id: "P1", status: "completed", agent_ids: [worker.fetch("id")])],
        agents: [worker]
      )
    )
  end
end
