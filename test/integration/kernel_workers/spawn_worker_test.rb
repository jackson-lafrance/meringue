# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# SpawnWorker: id composition, workspace allocation and hand-off to the harness,
# persisted workspace/session metadata, human-facing naming, validation, and logs.
class KernelWorkersSpawnTest < Minitest::Test
  include KernelWorkersSupport

  def test_worker_ids_are_composed_from_project_issue_and_worker_numbers
    engine = build_engine
    context = project_with_issue(engine)
    second_issue = create_issue(engine, context.fetch("project_id"), title: "Add search filters")

    first = spawn_worker(engine, context.fetch("issue_id"))
    second = spawn_worker(engine, context.fetch("issue_id"))
    other_issue_worker = spawn_worker(engine, second_issue)

    assert_equal "P1-I1-W1", first.fetch("target_id")
    assert_equal "P1-I1-W2", second.fetch("target_id")
    assert_equal "P1-I2-W1", other_issue_worker.fetch("target_id")
  end

  def test_spawn_allocates_a_workspace_and_hands_it_to_the_harness_as_cwd
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"), prompt: "Fix the failing login spec.")
    worker = agent(engine, result.fetch("target_id"))
    spawn_call = @harness_client.spawns.fetch(0)

    assert_equal 1, @harness_client.spawns.length
    assert_equal "worker", spawn_call.fetch("kind")
    assert_equal worker.fetch("workspace_path"), spawn_call.fetch("cwd")
    assert Dir.exist?(worker.fetch("workspace_path")), "worker workspace directory should exist"
    assert_equal "Fix the failing login spec.", spawn_call.fetch("prompt")
    assert_includes spawn_call.fetch("system_prompt"), "P1-I1 - Fix the login bug"
    assert_includes spawn_call.fetch("system_prompt"), "You are a Meringue worker agent."
  end

  def test_spawn_persists_workspace_metadata_on_the_worker_record
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"))
    worker = agent(engine, result.fetch("target_id"))

    assert_equal "git_worktree", worker.fetch("workspace_strategy")
    assert_match(%r{\Ameringue/fix-the-login-bug-[0-9a-f]{8}\z}, worker.fetch("workspace_branch"))
    assert worker.fetch("workspace_path").start_with?(workspace_root), "workspace should live under the configured root"
    assert_equal worker.fetch("workspace_path"), worker.fetch("harness_metadata").fetch("cwd")
    assert_equal "ready", worker.fetch("harness_metadata").fetch("provisioning_state")
    assert_equal worker.fetch("workspace_branch"), worker.fetch("harness_metadata").fetch("delivery_branch")
    assert_equal "spawn_worker", worker.fetch("harness_metadata").fetch("routing_action")
  end

  def test_spawn_records_the_harness_session_identity
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"))
    worker = agent(engine, result.fetch("target_id"))

    assert_equal "fake", worker.fetch("harness")
    assert_equal "fake-worker-session-1", worker.fetch("harness_session_id")
    assert_equal File.join(worker.fetch("workspace_path"), ".fake-session-1.json"), worker.fetch("harness_session_file")
    assert_equal 40_001, worker.fetch("pid")
    assert_equal "working", worker.fetch("status")
  end

  def test_workspace_branch_and_session_name_never_leak_meringue_or_pi_ids
    engine = build_engine
    root = create_git_repo
    project_id = add_project(engine, root)
    issue_id = create_issue(engine, project_id, title: "P1-I1-W1 H2 Q3 Rework the billing exporter")

    result = spawn_worker(engine, issue_id)
    worker = agent(engine, result.fetch("target_id"))
    session_name = @harness_client.spawns.fetch(0).fetch("session_name")

    refute_match(/P\d+(-I\d+)?(-W\d+)?/i, worker.fetch("workspace_branch"))
    refute_match(/\b[HQ]\d+\b/i, worker.fetch("workspace_branch"))
    refute_match(/P\d+(-I\d+)?(-W\d+)?/i, session_name)
    refute_match(/\b[HQ]\d+\b/i, session_name)
    assert_includes session_name, "Rework the billing exporter"
    assert_includes worker.fetch("workspace_branch"), "rework-the-billing-exporter"
  end

  def test_worker_title_overrides_the_session_name_without_leaking_ids
    engine = build_engine
    context = project_with_issue(engine)

    spawn_worker(engine, context.fetch("issue_id"), title: "Harden the session refresher")

    assert_equal "Harden the session refresher", @harness_client.spawns.fetch(0).fetch("session_name")
  end

  def test_spawn_appends_the_worker_to_the_issue_and_marks_parents_working
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"))
    issue_record = issue(engine, context.fetch("issue_id"))

    assert_equal [result.fetch("target_id")], issue_record.fetch("agent_ids")
    assert_equal "working", issue_record.fetch("status")
    assert_equal result.fetch("target_id"), issue_record.fetch("last_agent_id")
    assert_equal "spawn_worker", issue_record.fetch("last_routing_action")
    assert_equal "working", project(engine, context.fetch("project_id")).fetch("status")
  end

  def test_spawn_emits_provisioning_and_spawn_logs
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"))
    worker_id = result.fetch("target_id")

    assert_includes log_messages(engine), "Provisioning workspace for worker #{worker_id}."
    assert_includes log_messages(engine), "Spawned worker #{worker_id} for P1-I1."
    assert_equal "Spawned worker #{worker_id} for P1-I1.", result.fetch("message")
    refute_empty result.fetch("log_entry_ids")
  end

  def test_spawn_rejects_an_unknown_issue
    engine = build_engine
    create_git_repo
    result = apply_raw(engine, "SpawnWorker", { "issue_id" => "P9-I9", "prompt" => "Do it." })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "issue_not_found"
    assert_empty @harness_client.spawns
    assert_empty state(engine).fetch("agents")
  end

  def test_spawn_rejects_missing_issue_id_and_prompt
    engine = build_engine
    result = apply_raw(engine, "SpawnWorker", { "prompt" => "  " })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "issue_id is required"
    assert_includes result.fetch("errors"), "prompt is required"
    assert_empty @harness_client.spawns
  end

  def test_repeating_a_spawn_command_id_reuses_the_existing_worker
    engine = build_engine
    context = project_with_issue(engine)

    first = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." }, command_id: "C-1")
    second = apply_raw(engine, "SpawnWorker", { "issue_id" => context.fetch("issue_id"), "prompt" => "Go." }, command_id: "C-1")

    assert_equal "accepted", first.fetch("status")
    assert_equal "accepted", second.fetch("status")
    assert_equal first.fetch("target_id"), second.fetch("target_id")
    assert_equal 1, @harness_client.spawns.length
    assert_equal 1, state(engine).fetch("agents").length
    assert_includes second.fetch("message"), "was already spawned"
  end

  def test_requested_workspace_path_is_used_verbatim_without_a_branch
    engine = build_engine
    context = project_with_issue(engine)
    requested = tmp_path("scratch-workspace")
    FileUtils.mkdir_p(requested)

    result = spawn_worker(engine, context.fetch("issue_id"), workspace_path: requested)
    worker = agent(engine, result.fetch("target_id"))

    assert_equal requested, worker.fetch("workspace_path")
    assert_equal "dedicated_directory", worker.fetch("workspace_strategy")
    assert_nil worker.fetch("workspace_branch")
    assert_equal requested, @harness_client.spawns.fetch(0).fetch("cwd")
    assert_equal requested, worker.fetch("harness_metadata").fetch("requested_workspace_path")
  end

  def test_reconciliation_recovers_a_reservation_that_never_reached_the_harness
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Fix it." },
      command_id: "C-7"
    ).fetch("target_id")
    workspace_path = agent(engine, worker_id).fetch("workspace_path")

    # Simulate a crash between the workspace checkpoint and the harness spawn.
    patch_agent!(worker_id) do |record|
      record["status"] = "queued"
      record["pid"] = nil
      record["harness_session_id"] = nil
      record["harness_session_file"] = nil
    end

    reconcile = apply!(engine, "ReconcileSessions", {})
    recovered = agent(engine, worker_id)

    assert_equal 1, reconcile.fetch("result").fetch("recovered_worker_results").length
    assert_equal "accepted", reconcile.fetch("result").fetch("recovered_worker_results").fetch(0).fetch("status")
    assert_equal 1, state(engine).fetch("agents").length, "recovery must reuse the reserved worker id"
    assert_equal "working", recovered.fetch("status")
    assert_equal workspace_path, recovered.fetch("workspace_path")
    assert_equal "fake-worker-session-2", recovered.fetch("harness_session_id")
    assert_equal 2, @harness_client.spawns.length
  end

  def test_requested_workspace_path_must_exist
    engine = build_engine
    context = project_with_issue(engine)

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "workspace_path" => tmp_path("missing-dir") }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "workspace_path must be an existing directory"
    assert_empty @harness_client.spawns
    assert_empty state(engine).fetch("agents")
  end
end
