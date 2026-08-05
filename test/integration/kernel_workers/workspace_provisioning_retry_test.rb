# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# A workspace that could not be provisioned must not end the worker's existence.
#
# The production failure this covers: a `git worktree add` that was killed left the worker
# `errored` with `harness_session_id: null` and `provisioning_state: "failed"`. There was no
# session to prompt, nothing to replace, and the user's request was simply dropped. These tests
# pin the degradation instead: a recoverable failure keeps the reservation, retries it
# automatically, and - once the automatic budget is spent - leaves the worker resumable with its
# reason intact rather than dead.
class KernelWorkersWorkspaceProvisioningRetryTest < Minitest::Test
  include KernelWorkersSupport

  # Fails the first `failures` allocations with an injected classification, then provisions a real
  # worktree. No test ever waits for a timeout: the failure is injected, not produced.
  class FlakyWorkspaceManager < Meringue::Workspace::Manager
    attr_reader :attempts

    def initialize(failures: 1, recovery: Meringue::Workspace::Manager::RECOVERY_RETRY, cleanup_warnings: [], **options)
      super(**options)
      @remaining_failures = failures
      @recovery = recovery
      @cleanup_warnings = cleanup_warnings
      @attempts = 0
    end

    def allocate_worker_workspace(project_root:, project_id:, issue_id:, agent_id:, task_title: nil, progress: nil)
      @attempts += 1
      if @remaining_failures.positive?
        @remaining_failures -= 1
        return injected_failure(project_root, project_id, issue_id, agent_id, task_title)
      end

      super(
        project_root: project_root, project_id: project_id, issue_id: issue_id,
        agent_id: agent_id, task_title: task_title, progress: progress
      )
    end

    private

    def injected_failure(project_root, project_id, issue_id, agent_id, task_title)
      plan_worker_workspace(
        project_root: project_root, project_id: project_id, issue_id: issue_id,
        agent_id: agent_id, task_title: task_title
      ).merge(
        "created" => false,
        "errors" => ["git worktree add stalled: no output for 120.0 seconds (killed after 121.4 seconds)"],
        "failure_kind" => "command_stalled",
        "recovery" => @recovery,
        "timed_out" => true,
        "timeout_seconds" => 120.0,
        "cleanup" => { "attempted" => true, "worktree_removed" => true, "warnings" => @cleanup_warnings }
      )
    end
  end

  def test_a_recoverable_failure_keeps_the_worker_queued_and_retryable
    manager = FlakyWorkspaceManager.new(failures: 1, root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)

    result = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    worker = agent(engine, "P1-I1-W1")
    metadata = worker.fetch("harness_metadata")

    assert_equal "failed", result.fetch("status"), "the spawn itself did not succeed and says so"
    assert_includes result.fetch("message"), "Retrying automatically (attempt 2 of 2)"

    assert_equal "queued", worker.fetch("status"), "a retryable provisioning failure must not error the worker"
    assert_equal "retry_pending", metadata.fetch("provisioning_state")
    assert_equal 1, metadata.fetch("provisioning_attempts")
    assert_equal 2, metadata.fetch("provisioning_attempt_limit")
    assert_includes metadata.fetch("provisioning_errors").join(" "), "stalled: no output for 120.0 seconds"
    assert_equal "Go.", metadata.fetch("spawn_prompt"), "the request must survive so it can be retried"
    assert_nil worker.fetch("harness_session_id")
    assert_empty @harness_client.spawns

    warning = worker_scoped_logs(engine, "P1-I1-W1").last
    assert_equal "warning", warning.fetch("level")
    assert_includes warning.fetch("message"), "Worker workspace provisioning failed"
  end

  def test_reconciliation_retries_a_pending_worker_and_really_provisions_it
    manager = FlakyWorkspaceManager.new(failures: 1, root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)
    apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })

    engine.reconcile_sessions

    worker = agent(engine, "P1-I1-W1")
    assert_equal 2, manager.attempts, "the queued reservation must be provisioned again"
    assert_equal "working", worker.fetch("status")
    assert_equal "ready", worker.fetch("harness_metadata").fetch("provisioning_state")
    refute_nil worker.fetch("harness_session_id")
    assert_equal "git_worktree", worker.fetch("workspace_strategy")
    assert Dir.exist?(worker.fetch("workspace_path"))
    assert_equal worker.fetch("workspace_path"), @harness_client.spawns.fetch(0).fetch("cwd")
    assert_equal "Go.", @harness_client.spawns.fetch(0).fetch("prompt")
    assert_equal "working", issue(engine, context.fetch("issue_id")).fetch("status")
  end

  def test_the_automatic_retry_budget_is_bounded_and_then_the_worker_waits_for_a_human
    manager = FlakyWorkspaceManager.new(failures: 5, root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)
    apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })

    engine.reconcile_sessions
    engine.reconcile_sessions
    engine.reconcile_sessions

    worker = agent(engine, "P1-I1-W1")
    metadata = worker.fetch("harness_metadata")
    assert_equal 2, manager.attempts, "provisioning must stop retrying itself after the attempt limit"
    assert_equal "blocked", worker.fetch("status"), "a worker waiting for a human is blocked, not errored"
    assert_equal "retry_exhausted", metadata.fetch("provisioning_state")
    assert_equal 2, metadata.fetch("provisioning_attempts")
    assert_includes metadata.fetch("provisioning_next_step"), "Prompt this worker to retry"
    assert_includes metadata.fetch("provisioning_errors").join(" "), "stalled"
    assert_nil worker.fetch("harness_session_id")
    refute_empty logs_matching(engine, /Prompt this worker to retry provisioning/)
    assert_equal "blocked", issue(engine, context.fetch("issue_id")).fetch("status")
  end

  # A checkout that blew its absolute budget while still making progress is real work, so it is
  # not retried automatically: the worker goes straight to waiting for a human.
  def test_a_blown_budget_is_not_retried_automatically
    manager = FlakyWorkspaceManager.new(
      failures: 5, recovery: Meringue::Workspace::Manager::RECOVERY_RESUME, root_path: workspace_root
    )
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)

    apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    engine.reconcile_sessions

    worker = agent(engine, "P1-I1-W1")
    assert_equal 1, manager.attempts
    assert_equal "blocked", worker.fetch("status")
    assert_equal "retry_exhausted", worker.fetch("harness_metadata").fetch("provisioning_state")
  end

  def test_prompting_a_stuck_worker_resumes_provisioning_instead_of_being_rejected
    manager = FlakyWorkspaceManager.new(failures: 2, root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)
    apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    engine.reconcile_sessions
    assert_equal "blocked", agent(engine, "P1-I1-W1").fetch("status")

    result = apply_raw(engine, "PromptAgent", { "agent_id" => "P1-I1-W1", "prompt" => "Try again please." })

    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    assert_includes result.fetch("message"), "Retrying workspace provisioning for worker P1-I1-W1"
    requeued = agent(engine, "P1-I1-W1")
    assert_equal "queued", requeued.fetch("status")
    assert_equal "retry_pending", requeued.fetch("harness_metadata").fetch("provisioning_state")
    assert_equal 0, requeued.fetch("harness_metadata").fetch("provisioning_attempts")
    assert_equal "Try again please.", requeued.fetch("harness_metadata").fetch("spawn_prompt")

    engine.reconcile_sessions

    started = agent(engine, "P1-I1-W1")
    assert_equal "working", started.fetch("status")
    refute_nil started.fetch("harness_session_id")
    assert_equal "Try again please.", @harness_client.spawns.fetch(0).fetch("prompt")
  end

  # Even the non-recoverable classification (today's `errored`) keeps enough to resume, so no
  # provisioning failure is ever a dead end that forces the user to recreate the worker.
  def test_prompting_an_errored_provisioning_failure_also_resumes_it
    manager = FailingWorkspaceManager.new(errors: ["git worktree add failed: fatal: broken"], root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)
    apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    assert_equal "errored", agent(engine, "P1-I1-W1").fetch("status")

    result = apply_raw(engine, "PromptAgent", { "agent_id" => "P1-I1-W1", "prompt" => "Once more." })

    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    assert_equal "queued", agent(engine, "P1-I1-W1").fetch("status")
  end

  def test_cleanup_that_could_not_finish_is_logged_as_a_warning
    manager = FlakyWorkspaceManager.new(
      failures: 5,
      cleanup_warnings: ["left branch meringue/thing in place: it carries 2 commits that exist nowhere else"],
      root_path: workspace_root
    )
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)

    apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })

    cleanup_logs = logs_matching(engine, /Workspace cleanup for P1-I1-W1 could not finish/)
    refute_empty cleanup_logs
    assert_includes cleanup_logs.join(" "), "carries 2 commits"
    warning = worker_scoped_logs(engine, "P1-I1-W1").find { |entry| entry.fetch("message").start_with?("Workspace cleanup") }
    assert_equal "warning", warning.fetch("level")
  end

  def test_get_info_explains_the_failure_and_what_to_do_next
    manager = FlakyWorkspaceManager.new(failures: 5, root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)
    apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    engine.reconcile_sessions

    info = apply_raw(engine, "GetInfo", { "target_id" => "P1-I1-W1" }).fetch("result").fetch("provisioning")

    assert_equal "retry_exhausted", info.fetch("state")
    assert_equal 2, info.fetch("attempts")
    assert_equal 2, info.fetch("attempt_limit")
    assert info.fetch("resumable")
    assert_includes info.fetch("errors").join(" "), "stalled"
    assert_includes info.fetch("next_step"), "Prompt P1-I1-W1 to retry workspace provisioning"
  end

  def test_a_worker_waiting_on_provisioning_is_not_pruned_away
    manager = FlakyWorkspaceManager.new(failures: 5, root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)
    apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    engine.reconcile_sessions

    apply_raw(engine, "Prune", {})

    refute_nil agent(engine, "P1-I1-W1"), "a resumable worker must survive a prune"
  end
end
