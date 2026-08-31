# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# SpawnWorker: id composition, workspace allocation and hand-off to the harness,
# persisted workspace/session metadata, human-facing naming, validation, and logs.
class KernelWorkersSpawnTest < Minitest::Test
  include KernelWorkersSupport

  class SubstitutingHarnessClient < RecordingHarnessClient
    def spawn_session(**options)
      ref = super
      requested = options.fetch(:session_settings).fetch("model")
      effective = "fireworks-300k/fireworks:accounts/fireworks/routers/glm-5p2-fast"
      ref.merge(
        "session_settings" => { "model" => Meringue::Harness::ModelReference.parse(effective) },
        "metadata" => ref.fetch("metadata").merge(
          "session_model_substitution" => {
            "requested" => requested,
            "effective" => effective,
            "warning" => "Pi substituted model #{effective} for requested model #{requested}."
          }
        )
      )
    end
  end

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
    assert_includes spawn_call.fetch("system_prompt"), "Product task title for delivery artifacts:\nFix the login bug"
    refute_includes spawn_call.fetch("system_prompt"), "Assigned issue:\nP1-I1"
    assert_includes spawn_call.fetch("system_prompt"), "You are a Meringue worker agent."
    assert_includes spawn_call.fetch("system_prompt"), "Meringue must never be the author of a git commit."
    assert_includes spawn_call.fetch("system_prompt"), "repository's configured user.name and user.email identity"
    assert_includes spawn_call.fetch("system_prompt"), "do not invent one or commit as Meringue"
    assert_includes spawn_call.fetch("system_prompt"), "meaningful findings, decisions, and implementation milestones"
    assert_includes spawn_call.fetch("system_prompt"), "Do not narrate routine tool use or invent progress"
    assert_includes spawn_call.fetch("system_prompt"), "verify that the checkout is editable"
    assert_includes spawn_call.fetch("system_prompt"), "stop writing and report the exact ownership or checkout mismatch"
    assert_includes spawn_call.fetch("system_prompt"), "Recover from ordinary environment problems before abandoning"
    assert_includes spawn_call.fetch("system_prompt"), "run every safe narrower check you can"
    assert_includes spawn_call.fetch("system_prompt"), "successful completion means: make the requested changes"
    assert_includes spawn_call.fetch("system_prompt"), "Once the pull request is open or updated, stop work and report"
    assert_includes spawn_call.fetch("system_prompt"), "Do not watch CI, review bots, pull-request checks, or reviews"
    assert_includes spawn_call.fetch("system_prompt"), "do not run polling or sleep loops after pushing"
    assert_includes spawn_call.fetch("system_prompt"), "If the user specifically asks for CI remediation"
    assert_includes spawn_call.fetch("system_prompt"), "commit subjects or bodies"
    assert_includes spawn_call.fetch("system_prompt"), "AI confidence scores"
    assert_includes spawn_call.fetch("system_prompt"), "statements about which agents worked"
  end

  def test_spawn_persists_workspace_metadata_on_the_worker_record
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"))
    worker = agent(engine, result.fetch("target_id"))

    assert_equal "git_worktree", worker.fetch("workspace_strategy")
    assert_equal "fix-the-login-bug", worker.fetch("workspace_branch")
    assert worker.fetch("workspace_path").start_with?(workspace_root), "workspace should live under the configured root"
    assert_equal worker.fetch("workspace_path"), worker.fetch("harness_metadata").fetch("cwd")
    assert_equal "ready", worker.fetch("harness_metadata").fetch("provisioning_state")
    assert_equal worker.fetch("workspace_branch"), worker.fetch("harness_metadata").fetch("delivery_branch")
    assert_equal "spawn_worker", worker.fetch("harness_metadata").fetch("routing_action")
  end

  def test_spawn_applies_and_records_explicit_session_settings
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(
      engine,
      context.fetch("issue_id"),
      model: "openai/gpt-5.6-sol",
      thinking_level: "medium"
    )
    worker = agent(engine, result.fetch("target_id"))
    spawn_call = @harness_client.spawns.fetch(0)

    assert_equal({ "model" => "openai/gpt-5.6-sol", "thinking_level" => "medium" }, spawn_call.fetch("session_settings"))
    assert_equal "openai/gpt-5.6-sol", worker.dig("session_settings", "model", "reference")
    assert_equal "medium", worker.dig("session_settings", "thinking_level")
  end

  def test_spawn_logs_a_visible_warning_when_the_harness_substitutes_the_model
    requested = "fireworks/fireworks:accounts/fireworks/models/glm-5p3"
    client = SubstitutingHarnessClient.new(provider: "pi")
    engine = build_engine(harness_client: client)
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"), model: requested)

    warning = state(engine).fetch("logs").last
    assert_equal "accepted", result.fetch("status")
    assert_includes result.fetch("log_entry_ids"), warning.fetch("id")
    assert_equal "warning", warning.fetch("level")
    assert_equal requested, warning.dig("details", "requested_model")
    assert_equal "fireworks-300k/fireworks:accounts/fireworks/routers/glm-5p2-fast",
                 warning.dig("details", "effective_model")
  end

  def test_spawn_omits_session_settings_to_retain_harness_defaults
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"))

    assert_equal({}, @harness_client.spawns.fetch(0).fetch("session_settings"))
    assert_nil agent(engine, result.fetch("target_id")).fetch("session_settings")
  end

  def test_spawn_rejects_invalid_session_settings_before_reserving_or_launching
    engine = build_engine
    context = project_with_issue(engine)

    bad_model = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Do it.", "model" => "bare-model" }
    )
    bad_thinking = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Do it.", "thinking_level" => "ultra" }
    )

    assert_equal "rejected", bad_model.fetch("status")
    assert_includes bad_model.fetch("errors").join(" "), "invalid model"
    assert_equal "rejected", bad_thinking.fetch("status")
    assert_includes bad_thinking.fetch("errors").join(" "), "thinking_level must be one of"
    assert_empty @harness_client.spawns
    assert_empty state(engine).fetch("agents")
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

  def test_workspace_branch_and_session_name_never_leak_branding_or_orchestration_metadata
    engine = build_engine
    root = create_git_repo
    project_id = add_project(engine, root)
    issue_id = create_issue(
      engine,
      project_id,
      title: "MERINGUE/ p1_i1_w1 H-2 Q#3 agent id 407 Confidence: 92% Rework the billing exporter"
    )

    result = spawn_worker(engine, issue_id)
    worker = agent(engine, result.fetch("target_id"))
    session_name = @harness_client.spawns.fetch(0).fetch("session_name")

    [worker.fetch("workspace_branch"), session_name].each do |value|
      refute_match(/meringue/i, value)
      refute_match(/p1[_\/-]i1[_\/-]w1/i, value)
      refute_match(/\b[HQ][-_#]?\d+\b/i, value)
      refute_match(/agent\s*id/i, value)
      refute_match(/confidence/i, value)
    end
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

  # A successful spawn is one event, so it gets exactly one visible log line. The old
  # "Provisioning workspace for worker ..." line said the same thing a moment earlier and
  # is intentionally gone; the surviving line carries the full routing details.
  def test_spawn_emits_one_spawn_log_and_no_provisioning_chatter
    engine = build_engine
    context = project_with_issue(engine)

    result = spawn_worker(engine, context.fetch("issue_id"))
    worker_id = result.fetch("target_id")

    assert_includes log_messages(engine), "Spawned worker #{worker_id} for P1-I1."
    assert_equal "Spawned worker #{worker_id} for P1-I1.", result.fetch("message")
    assert_empty logs_matching(engine, /Provisioning workspace/)
    assert_equal(
      ["Spawned worker #{worker_id} for P1-I1."],
      worker_scoped_logs(engine, worker_id).map { |entry| entry.fetch("message") }
    )
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

  # A worker's workspace has to be one a version-control backend provisioned and can
  # prove is isolated. A directory the caller points at is neither, however real it is,
  # so an explicit path is refused rather than used verbatim.
  def test_a_requested_workspace_path_is_refused_because_no_backend_provisioned_it
    engine = build_engine
    context = project_with_issue(engine)
    requested = tmp_path("scratch-workspace")
    FileUtils.mkdir_p(requested)

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "workspace_path" => requested }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "version_control_backend_required"
    assert_empty @harness_client.spawns
    assert_empty state(engine).fetch("agents")
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

  # Whether the directory exists is no longer the question the kernel asks: an explicit
  # path carries no isolation evidence either way, so a missing one is refused for the
  # same reason as an existing one.
  def test_a_missing_requested_workspace_path_is_refused_for_the_same_reason
    engine = build_engine
    context = project_with_issue(engine)

    result = apply_raw(
      engine,
      "SpawnWorker",
      { "issue_id" => context.fetch("issue_id"), "prompt" => "Go.", "workspace_path" => tmp_path("missing-dir") }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "version_control_backend_required"
    assert_empty @harness_client.spawns
    assert_empty state(engine).fetch("agents")
  end
end
