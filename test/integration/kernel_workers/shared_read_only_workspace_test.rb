# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

class KernelWorkersSharedReadOnlyWorkspaceTest < Minitest::Test
  include KernelWorkersSupport

  class AllocationRejectingManager < Meringue::Workspace::Manager
    attr_reader :allocation_attempts, :cleanup_attempts

    def initialize(**options)
      super
      @allocation_attempts = 0
      @cleanup_attempts = 0
    end

    def allocate_worker_workspace(**)
      @allocation_attempts += 1
      raise "isolated allocation should not run for a validated shared reader"
    end

    def cleanup_pruned_worker_workspace(*args, **kwargs)
      @cleanup_attempts += 1
      super
    end
  end

  class UnsupportedReadOnlyHarness < RecordingHarnessClient
    def read_only_workspace_supported?
      false
    end
  end

  def test_shared_read_only_mode_avoids_provisioning_and_is_persisted_and_enforced
    root = create_git_repo("large-world-checkout")
    manager = AllocationRejectingManager.new(root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    project_id = add_project(engine, root, name: "World")
    issue_id = create_issue(engine, project_id, title: "Map existing behavior")

    result = spawn_worker(
      engine,
      issue_id,
      title: "Investigate behavior",
      prompt: "Inspect the code and report findings only.",
      workspace_mode: "shared_read_only"
    )
    worker = agent(engine, result.fetch("target_id"))
    spawn = @harness_client.spawns.fetch(0)

    assert_equal 0, manager.allocation_attempts
    assert_equal File.realpath(root), File.realpath(worker.fetch("workspace_path"))
    assert_equal "shared_checkout", worker.fetch("workspace_strategy")
    assert_equal "shared_read_only", worker.fetch("workspace_mode")
    assert_equal "shared_read_only", worker.fetch("effective_workspace_mode")
    assert_nil worker.fetch("workspace_mode_fallback_reason")
    assert_equal "shared_read_only", spawn.fetch("workspace_mode")
    assert_includes spawn.fetch("system_prompt"), "Meringue read-only worker agent"
    assert_includes spawn.fetch("system_prompt"), "must not mutate it or any repository state"
    assert_includes spawn.fetch("system_prompt"), "only read, grep, find, and ls tools"
    refute_includes spawn.fetch("system_prompt"), "You may edit files, commit, push"
    refute Dir.exist?(workspace_root), "shared readers must not create the managed workspace root"
    assert_includes result.fetch("message"), "Using a validated shared read-only checkout"
  end

  def test_concurrent_readers_share_the_same_validated_checkout
    root = create_git_repo
    manager = AllocationRejectingManager.new(root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    project_id = add_project(engine, root)
    first_issue = create_issue(engine, project_id, title: "Inspect controllers")
    second_issue = create_issue(engine, project_id, title: "Inspect models")

    first = spawn_worker(engine, first_issue, workspace_mode: "shared_read_only")
    second = spawn_worker(engine, second_issue, workspace_mode: "shared_read_only")
    first_worker = agent(engine, first.fetch("target_id"))
    second_worker = agent(engine, second.fetch("target_id"))

    assert_equal first_worker.fetch("workspace_path"), second_worker.fetch("workspace_path")
    assert_equal %w[shared_read_only shared_read_only], @harness_client.spawns.map { |spawn| spawn.fetch("workspace_mode") }
    assert_equal 0, manager.allocation_attempts
  end

  def test_bare_registered_root_uses_existing_linked_main_checkout_without_provisioning
    source = create_git_repo
    bare = tmp_path("world-linked.git")
    shared_main = tmp_path("world-main")
    run_git(tmpdir, "clone", "--bare", source, bare)
    run_git(bare, "worktree", "add", shared_main, "main")
    manager = AllocationRejectingManager.new(root_path: workspace_root)
    engine = build_engine(workspace_manager: manager)
    project_id = add_project(engine, bare, name: "World")
    issue_id = create_issue(engine, project_id, title: "Map World titles")

    result = spawn_worker(engine, issue_id, workspace_mode: "shared_read_only")
    worker = agent(engine, result.fetch("target_id"))

    assert_equal File.realpath(shared_main), File.realpath(worker.fetch("workspace_path"))
    assert_equal "shared_checkout", worker.fetch("workspace_strategy")
    assert_equal "shared_read_only", worker.fetch("effective_workspace_mode")
    assert_equal 0, manager.allocation_attempts
  end

  def test_bare_root_without_existing_main_checkout_provisions_one_reusable_read_only_checkout
    root = create_git_repo
    bare = tmp_path("world.git")
    run_git(tmpdir, "clone", "--bare", root, bare)
    engine = build_engine
    project_id = add_project(engine, bare, name: "World")
    first_issue = create_issue(engine, project_id, title: "Investigate World")
    second_issue = create_issue(engine, project_id, title: "Inspect World models")

    first = spawn_worker(engine, first_issue, workspace_mode: "shared_read_only")
    second = spawn_worker(engine, second_issue, workspace_mode: "shared_read_only")
    first_worker = agent(engine, first.fetch("target_id"))
    second_worker = agent(engine, second.fetch("target_id"))

    assert_equal "shared_read_only", first_worker.fetch("workspace_mode")
    assert_equal "shared_read_only", first_worker.fetch("effective_workspace_mode")
    assert_nil first_worker.fetch("workspace_mode_fallback_reason")
    assert_equal "shared_checkout", first_worker.fetch("workspace_strategy")
    assert_equal true, first_worker.dig("harness_metadata", "workspace_plan", "managed_shared_checkout")
    refute_equal File.realpath(bare), File.realpath(first_worker.fetch("workspace_path"))
    assert_equal first_worker.fetch("workspace_path"), second_worker.fetch("workspace_path")
    assert_equal %w[shared_read_only shared_read_only], @harness_client.spawns.map { |spawn| spawn.fetch("workspace_mode") }
    assert_includes @harness_client.spawns.fetch(0).fetch("system_prompt"), "Meringue read-only worker agent"
    assert_includes first.fetch("message"), "Using a validated shared read-only checkout"
  end

  def test_harness_without_read_only_enforcement_falls_back_to_isolation
    harness = UnsupportedReadOnlyHarness.new
    engine = build_engine(harness_client: harness)
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"), workspace_mode: "shared_read_only")
    worker = agent(engine, result.fetch("target_id"))

    assert_equal "isolated", worker.fetch("effective_workspace_mode")
    assert_equal "harness_does_not_enforce_read_only_workspaces", worker.fetch("workspace_mode_fallback_reason")
    assert_equal "git_worktree", worker.fetch("workspace_strategy")
    assert_equal "isolated", harness.spawns.fetch(0).fetch("workspace_mode")
  end

  def test_queued_read_only_worker_keeps_mode_through_activation_and_handover
    engine = build_engine
    context = project_with_issue(engine)
    predecessor = spawn_worker(engine, context.fetch("issue_id"), prompt: "Implement first.").fetch("target_id")
    dependent = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Read the result and audit it without changes.",
      workspace_mode: "shared_read_only",
      after_agent_id: predecessor
    ).fetch("target_id")

    queued = agent(engine, dependent)
    assert_equal "queued", queued.fetch("status")
    assert_equal "shared_read_only", queued.fetch("workspace_mode")
    assert_equal "shared_read_only", queued.dig("harness_metadata", "workspace_mode")

    engine.mark_worker_completed(agent_id: predecessor, last_assistant_text: "Implementation report.")
    activated = agent(engine, dependent)

    assert_equal "working", activated.fetch("status")
    assert_equal "shared_read_only", activated.fetch("effective_workspace_mode")
    assert_equal "shared_checkout", activated.fetch("workspace_strategy")
    assert_equal "shared_read_only", @harness_client.spawns.last.fetch("workspace_mode")
    assert_includes @harness_client.spawns.last.fetch("prompt"), "Implementation report."
  end

  def test_implementation_after_read_only_investigation_still_gets_isolated_editable_worktree
    engine = build_engine
    context = project_with_issue(engine)
    investigator = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Investigate only.",
      workspace_mode: "shared_read_only"
    ).fetch("target_id")
    engine.mark_worker_completed(agent_id: investigator, last_assistant_text: "Found the cause.")

    implementation = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Implement the fix.",
      after_agent_id: investigator
    )
    worker = agent(engine, implementation.fetch("target_id"))

    assert_equal "isolated", worker.fetch("workspace_mode")
    assert_equal "isolated", worker.fetch("effective_workspace_mode")
    assert_equal "git_worktree", worker.fetch("workspace_strategy")
    refute_equal context.fetch("root"), worker.fetch("workspace_path")
    assert_equal "isolated", @harness_client.spawns.last.fetch("workspace_mode")
    assert_includes @harness_client.spawns.last.fetch("system_prompt"), "You may edit files, commit, push"
  end

  def test_read_only_follow_up_does_not_try_to_reuse_a_live_worker_worktree
    engine = build_engine
    context = project_with_issue(engine)
    predecessor = spawn_worker(engine, context.fetch("issue_id"), prompt: "Implement.").fetch("target_id")

    follow_up = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Independently inspect the current main checkout.",
      workspace_mode: "shared_read_only",
      follow_up_of_agent_id: predecessor
    )
    worker = agent(engine, follow_up.fetch("target_id"))

    assert_equal "shared_checkout", worker.fetch("workspace_strategy")
    assert_equal "shared_read_only", worker.fetch("effective_workspace_mode")
    refute_equal agent(engine, predecessor).fetch("workspace_path"), worker.fetch("workspace_path")
  end

  def test_reconciliation_preserves_read_only_mode_and_cleanup_never_removes_shared_checkout
    harness = RecordingHarnessClient.new(provider: "pi-test")
    manager = AllocationRejectingManager.new(root_path: workspace_root)
    root = create_git_repo
    engine = build_engine(harness_client: harness, workspace_manager: manager)
    project_id = add_project(engine, root)
    issue_id = create_issue(engine, project_id, title: "Read-only audit")
    worker_id = spawn_worker(engine, issue_id, workspace_mode: "shared_read_only").fetch("target_id")

    engine.reconcile_sessions
    reconciled = agent(engine, worker_id)
    assert_equal "shared_read_only", reconciled.fetch("workspace_mode")
    assert_equal "shared_read_only", reconciled.fetch("effective_workspace_mode")

    engine.mark_worker_completed(agent_id: worker_id, last_assistant_text: "Audit complete.")
    apply!(engine, "Prune")

    assert Dir.exist?(root)
    assert_equal 1, manager.cleanup_attempts, "prune should classify the persisted shared workspace"
    assert_empty state(engine).fetch("agents")
  end

  def test_invalid_mode_and_explicit_path_are_rejected_before_reservation
    engine = build_engine
    context = project_with_issue(engine)

    invalid = apply_raw(engine, "SpawnWorker", {
      "issue_id" => context.fetch("issue_id"), "prompt" => "Inspect.", "workspace_mode" => "maybe"
    })
    explicit = apply_raw(engine, "SpawnWorker", {
      "issue_id" => context.fetch("issue_id"), "prompt" => "Inspect.",
      "workspace_mode" => "shared_read_only", "workspace_path" => context.fetch("root")
    })
    command_gate = apply_raw(engine, "SpawnWorker", {
      "issue_id" => context.fetch("issue_id"), "prompt" => "Inspect.",
      "workspace_mode" => "shared_read_only", "after_command" => "test -f READY"
    })

    assert_equal "rejected", invalid.fetch("status")
    assert_includes invalid.fetch("errors").join(" "), "workspace_mode must be one of"
    assert_equal "rejected", explicit.fetch("status")
    assert_includes explicit.fetch("errors"), "workspace_path cannot be combined with shared_read_only workspace_mode"
    assert_equal "rejected", command_gate.fetch("status")
    assert_includes command_gate.fetch("errors"), "shared_read_only workspace_mode cannot be combined with an after_command gate"
    assert_empty @harness_client.spawns
  end
end
