# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

class KernelWorkersWorkerBundleTest < Minitest::Test
  include KernelWorkersSupport

  def test_export_contains_context_but_not_machine_handles_or_credentials
    engine = build_engine
    context = project_with_issue(engine, title: "Retry the billing worker")
    result = spawn_worker(engine, context.fetch("issue_id"), prompt: "Use token=do-not-export and continue the billing fix.")
    worker_id = result.fetch("target_id")
    patch_agent!(worker_id) do |worker|
      worker["status"] = "errored"
      worker["pid"] = 42_001
      worker["harness_session_id"] = "machine-session-secret"
      worker["harness_session_file"] = "/home/alice/.pi/session.jsonl"
      worker["workspace_path"] = "/home/alice/worktrees/billing"
      worker.fetch("harness_metadata")["last_assistant_text"] = "The report contains password=super-secret."
      worker.fetch("harness_metadata")["pending_prompts"] = [{ "prompt" => "Also inspect token=another-secret", "mode" => "normal" }]
    end

    patch_state! do |state|
      state.fetch("issues").fetch(0)["delivery_pull_requests"] = [{
        "url" => "https://github.com/acme/billing/pull/4?token=secret",
        "title" => "Billing retry",
        "state" => "open"
      }]
    end
    bundle = Meringue::Workers::Bundle.export(store.load)
    entry = bundle.fetch("workers").fetch(0)
    serialized = JSON.generate(bundle)

    assert_equal "P1-I1-W1", entry.fetch("source_worker_id")
    assert_equal "Demo", entry.dig("project", "name")
    assert_equal "Retry the billing worker", entry.dig("issue", "title")
    assert_equal "Use token=[REDACTED] and continue the billing fix.", entry.dig("prompts", "initial")
    assert_equal false, entry.dig("session", "resume_available")
    assert_includes entry.dig("session", "reason"), "cannot be resumed directly"
    assert_equal "Also inspect token=[REDACTED]", entry.dig("prompts", "pending", 0, "prompt")
    assert_equal "The report contains password=[REDACTED]", entry.dig("prompts", "last_report")
    assert_equal "https://github.com/acme/billing/pull/4", entry.dig("delivery", "pull_requests", 0, "url")
    refute_includes serialized, "machine-session-secret"
    refute_includes serialized, "/home/alice/.pi/session.jsonl"
    refute_includes serialized, "/home/alice/worktrees/billing"
    refute_includes serialized, "super-secret"
    refute_includes serialized, "another-secret"
    refute_includes serialized, "?token=secret"
    assert_includes bundle.fetch("warnings").join(" "), "Harness sessions are machine-local"
  end

  def test_import_recreates_project_and_issue_and_starts_a_fresh_worker
    source_engine = build_engine
    source = project_with_issue(source_engine, title: "Retry the portability task")
    source_worker = spawn_worker(source_engine, source.fetch("issue_id"), prompt: "Finish the portability task.")
    bundle = Meringue::Workers::Bundle.export(store.load, worker_ids: [source_worker.fetch("target_id")])

    destination_root = create_git_repo("destination-project")
    destination_state_path = tmp_path("destination-state.json")
    destination_store = Meringue::State::Store.new(path: destination_state_path)
    destination_harness = RecordingHarnessClient.new
    destination_engine = Meringue::Kernel::Engine.new(
      store: destination_store,
      harness_client: destination_harness,
      head_runner: Meringue::Heads::FakeRunner.new,
      workspace_manager: Meringue::Workspace::Manager.new(root_path: tmp_path("destination-workspaces"), command_timeout: 30),
      cwd: destination_root,
      config_path: tmp_path("destination-config.toml")
    )

    result = destination_engine.apply(
      "type" => "ImportWorkers",
      "payload" => { "bundle" => bundle, "project_path" => destination_root }
    )
    assert_equal "accepted", result.fetch("status"), result.fetch("message")
    imported = result.dig("result", "imported").fetch(0)
    assert_equal "fresh_session", imported.fetch("status")

    destination_state = destination_store.load
    project = destination_state.fetch("projects").fetch(0)
    issue = destination_state.fetch("issues").fetch(0)
    worker = destination_state.fetch("agents").find { |agent| agent.fetch("id") == imported.fetch("target_worker_id") }
    refute_nil worker
    assert_equal destination_root, project.fetch("root_path")
    assert_equal "Demo", project.fetch("name")
    assert_equal "Retry the portability task", issue.fetch("title")
    assert_includes worker.dig("harness_metadata", "spawn_prompt"), "The original harness session cannot be resumed directly"
    assert_equal false, worker.dig("harness_metadata", "portable_import", "session_resume_available")
    assert_equal "P1-I1-W1", worker.dig("harness_metadata", "portable_import", "source_worker_id")
    assert_equal 1, destination_harness.spawns.length
    assert_equal worker.fetch("workspace_path"), destination_harness.spawns.fetch(0).fetch("cwd")
    assert_includes result.fetch("message"), "fresh sessions"
    assert_includes result.dig("result", "session_resume", "reason"), "cannot be resumed directly"
  end

  def test_reimport_is_idempotent_for_a_bundle_worker
    source_engine = build_engine
    source = project_with_issue(source_engine)
    source_worker = spawn_worker(source_engine, source.fetch("issue_id"))
    bundle = Meringue::Workers::Bundle.export(store.load, worker_ids: [source_worker.fetch("target_id")])
    destination_root = create_git_repo("idempotent-destination")
    destination_store = Meringue::State::Store.new(path: tmp_path("idempotent-state.json"))
    destination_harness = RecordingHarnessClient.new
    destination_engine = Meringue::Kernel::Engine.new(
      store: destination_store,
      harness_client: destination_harness,
      head_runner: Meringue::Heads::FakeRunner.new,
      workspace_manager: Meringue::Workspace::Manager.new(root_path: tmp_path("idempotent-workspaces"), command_timeout: 30),
      cwd: destination_root,
      config_path: tmp_path("idempotent-config.toml")
    )
    payload = { "bundle" => bundle, "project_path" => destination_root }

    first = destination_engine.apply("type" => "ImportWorkers", "payload" => payload)
    second = destination_engine.apply("type" => "ImportWorkers", "payload" => payload)

    assert_equal "accepted", first.fetch("status")
    assert_equal "accepted", second.fetch("status")
    assert_equal 1, destination_store.load.fetch("agents").count { |agent| agent["type"] == "worker" }
    assert_empty second.dig("result", "imported")
    assert_equal "already_imported", second.dig("result", "skipped", 0, "reason")
    assert_equal 1, destination_harness.spawns.length
  end
end
