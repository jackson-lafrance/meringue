# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Workspace provisioning outcomes: git worktree collisions, non-git fallback, and
# harness spawn failures must surface as failed commands with clear logs and an
# honest (never half-written) agent record.
class KernelWorkersWorkspaceProvisioningTest < Minitest::Test
  include KernelWorkersSupport

  def test_workspace_allocation_failure_fails_the_command_and_marks_the_worker_errored
    manager = FailingWorkspaceManager.new(
      errors: ["git worktree add failed: fatal: 'meringue/fix-the-login-bug' is already checked out"],
      root_path: workspace_root
    )
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)

    result = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    worker = agent(engine, "P1-I1-W1")

    assert_equal "failed", result.fetch("status")
    assert_includes result.fetch("message"), "Worker workspace provisioning failed"
    assert_includes result.fetch("message"), "already checked out"
    assert_empty @harness_client.spawns, "the harness must not be started without a workspace"

    refute_nil worker, "the reserved worker record should be retained for inspection"
    assert_equal "errored", worker.fetch("status")
    assert_equal "failed", worker.fetch("harness_metadata").fetch("provisioning_state")
    assert_includes worker.fetch("harness_metadata").fetch("provisioning_errors").join(" "), "already checked out"
    assert_nil worker.fetch("harness_session_id")
    assert_nil worker.fetch("pid")
    assert_equal "errored", issue(engine, context.fetch("issue_id")).fetch("status")

    worker_logs = worker_scoped_logs(engine, "P1-I1-W1")
    refute_empty worker_logs, "expected a worker-scoped provisioning failure log"
    # The success path is silent until the session exists, so the failure must not be:
    # this error is the only visible line the worker ever gets.
    assert_equal ["error"], worker_logs.map { |entry| entry.fetch("level") }.uniq
    assert_includes worker_logs.fetch(0).fetch("message"), "Worker workspace provisioning failed"
    assert_includes log_messages(engine), "Failed SpawnWorker: #{result.fetch("message")}"
  end

  def test_large_workspace_failure_persists_bounded_actionable_log_details
    fixture = JSON.parse(File.read(File.expand_path("../../fixtures/large_workspace_diagnostic.json", __dir__)))
    manager = FailingWorkspaceManager.new(errors: fixture.dig("workspace", "errors"), root_path: workspace_root)
    workspace = fixture.fetch("workspace")
    manager.define_singleton_method(:allocate_worker_workspace) do |**_arguments|
      Marshal.load(Marshal.dump(workspace))
    end
    engine = build_engine(workspace_manager: manager)
    context = project_with_issue(engine)

    result = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    entry = worker_scoped_logs(engine, "P1-I1-W1").first
    details = entry.fetch("details")
    stderr = details.dig("workspace", "stderr")

    assert_equal "failed", result.fetch("status")
    assert_operator JSON.generate(details).bytesize, :<=, Meringue::State::Compactor::DIAGNOSTIC_DETAILS_MAX_BYTES
    assert_equal workspace.fetch("workspace_path"), details.dig("workspace", "workspace_path")
    assert_equal workspace.fetch("exit_status"), details.dig("workspace", "exit_status")
    assert_equal "Prompt this worker to retry provisioning, or kill it.", details.fetch("recovery_guidance")
    assert_includes stderr.fetch("head"), "checkout failed at beginning"
    assert_includes stderr.fetch("tail"), "lock remains at end"
    assert_operator stderr.fetch("omitted_bytes"), :>, 300_000
  end

  def test_worktree_path_collision_falls_back_to_a_uniquified_branch_and_path
    engine = build_engine
    context = project_with_issue(engine)
    planned = planned_workspace(context)
    occupy_directory(planned.fetch("workspace_path"))

    result = spawn_worker(engine, context.fetch("issue_id"))
    worker = agent(engine, result.fetch("target_id"))

    assert_equal "git_worktree", worker.fetch("workspace_strategy")
    assert_equal "#{planned.fetch("workspace_branch")}-2", worker.fetch("workspace_branch")
    assert_equal "#{planned.fetch("workspace_path")}-2", worker.fetch("workspace_path")
    assert_equal worker.fetch("workspace_path"), @harness_client.spawns.fetch(0).fetch("cwd")

    # The single spawn log is written after allocation, so it reports the branch and path the
    # worker really got rather than the planned names a pre-allocation line would have shown.
    spawn_log = worker_scoped_logs(engine, worker.fetch("id")).fetch(0)
    assert_equal "Spawned worker P1-I1-W1 for P1-I1.", spawn_log.fetch("message")
    assert_equal worker.fetch("workspace_branch"), spawn_log.fetch("details").fetch("workspace_branch")
    assert_equal worker.fetch("workspace_path"), spawn_log.fetch("details").fetch("workspace_path")
  end

  def test_exhausted_worktree_collisions_fail_the_spawn_with_a_clear_log
    engine = build_engine
    context = project_with_issue(engine)
    planned = planned_workspace(context)
    occupy_directory(planned.fetch("workspace_path"))
    occupy_directory("#{planned.fetch("workspace_path")}-2")
    occupy_directory("#{planned.fetch("workspace_path")}-3")

    result = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    worker = agent(engine, "P1-I1-W1")

    assert_equal "failed", result.fetch("status")
    assert_includes result.fetch("message"), "Worker workspace provisioning failed"
    assert_includes result.fetch("errors").join(" "), "already exists"
    assert_empty @harness_client.spawns
    assert_equal "errored", worker.fetch("status")
    assert_equal "failed", worker.fetch("harness_metadata").fetch("provisioning_state")
    refute_empty logs_matching(engine, /Worker workspace provisioning failed.*already exists/)
  end

  def test_non_git_project_root_falls_back_to_the_project_root_cwd
    engine = build_engine
    root = create_plain_directory
    project_id = add_project(engine, root)
    issue_id = create_issue(engine, project_id, title: "Draft the onboarding doc")

    result = spawn_worker(engine, issue_id)
    worker = agent(engine, result.fetch("target_id"))

    assert_equal "accepted", result.fetch("status")
    assert_equal "project_root", worker.fetch("workspace_strategy")
    assert_equal File.realpath(root), File.realpath(worker.fetch("workspace_path"))
    assert_nil worker.fetch("workspace_branch")
    assert_equal(
      "project root is not inside a git repository",
      worker.fetch("harness_metadata").fetch("workspace_note")
    )
    assert_equal worker.fetch("workspace_path"), @harness_client.spawns.fetch(0).fetch("cwd")
  end

  def test_harness_spawn_failure_fails_the_command_and_releases_the_workspace
    @harness_client.spawn_error = RuntimeError.new("harness refused to start")
    engine = build_engine
    context = project_with_issue(engine)

    result = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." })
    worker = agent(engine, "P1-I1-W1")

    assert_equal "failed", result.fetch("status")
    assert_includes result.fetch("message"), "Could not start an agent session for worker P1-I1-W1"
    assert_includes result.fetch("errors"), "harness refused to start"
    assert_equal "errored", worker.fetch("status")
    assert_equal "failed", worker.fetch("harness_metadata").fetch("provisioning_state")
    assert_nil worker.fetch("harness_session_id")
    refute Dir.exist?(worker.fetch("workspace_path")), "a failed spawn should release its freshly created worktree"
    refute_empty logs_matching(engine, /Could not start an agent session for worker P1-I1-W1/)
  end

  private

  def planned_workspace(context)
    workspace_manager.plan_worker_workspace(
      project_root: context.fetch("root"),
      project_id: context.fetch("project_id"),
      issue_id: context.fetch("issue_id"),
      agent_id: "P1-I1-W1",
      task_title: "Fix the login bug"
    )
  end

  def occupy_directory(path)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "leftover.txt"), "occupied\n")
  end
end
