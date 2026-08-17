# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# User-directed pause/resume keeps the worker record, workspace, and harness
# session intact while making the pause durable across reconciliation/restart.
class KernelWorkersPauseResumeTest < Minitest::Test
  include KernelWorkersSupport

  def test_pause_aborts_the_turn_without_killing_or_completing_the_worker
    @harness_client.streaming = true
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    worker_before = agent(engine, worker_id)
    session_id = worker_before.fetch("harness_session_id")
    workspace = worker_before.fetch("workspace_path")

    result = apply!(engine, "PauseWorker", { "agent_id" => worker_id }, command_id: "pause-1")
    worker = agent(engine, worker_id)

    assert_equal "paused", worker.fetch("status")
    assert_equal session_id, worker.fetch("harness_session_id")
    assert_equal workspace, worker.fetch("workspace_path")
    assert_equal true, worker.dig("harness_metadata", "paused")
    assert_equal [session_id], @harness_client.aborts.map { |call| call.fetch("session_id") }
    assert_empty @harness_client.kills
    assert_equal "idle", issue(engine, context.fetch("issue_id")).fetch("status")
    assert_equal "idle", project(engine, context.fetch("project_id")).fetch("status")
    assert_match(/preserved/, result.fetch("message"))
    assert_includes log_messages(engine), result.fetch("message")

    reconcile = apply!(engine, "ReconcileSessions", {})
    assert_equal 0, reconcile.dig("result", "checked_count")
    assert_equal "paused", agent(engine, worker_id).fetch("status")
  end

  def test_resume_continues_the_same_session_and_is_idempotent
    @harness_client.streaming = true
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    session_id = agent(engine, worker_id).fetch("harness_session_id")
    apply!(engine, "PauseWorker", { "agent_id" => worker_id }, command_id: "pause-1")
    @harness_client.streaming = false

    result = apply!(engine, "ResumeWorker", { "agent_id" => worker_id }, command_id: "resume-1")
    worker = agent(engine, worker_id)

    assert_equal "working", worker.fetch("status")
    assert_equal false, worker.dig("harness_metadata", "paused")
    assert_equal session_id, worker.fetch("harness_session_id")
    assert_equal ["Continue this Meringue worker session from the existing session history and workspace state.\nFirst inspect the current repository state, then continue the assigned issue from the last incomplete step.\nIf the issue is already complete, summarize the final status and include any pull request link.\n"], @harness_client.prompts.map { |call| call.fetch("prompt") }
    assert_equal "normal", @harness_client.prompts.fetch(0).fetch("mode")
    assert_match(/Resumed worker/, result.fetch("message"))

    duplicate = apply!(engine, "ResumeWorker", { "agent_id" => worker_id }, command_id: "resume-1")
    assert_match(/already resumed/, duplicate.fetch("message"))
    assert_equal 1, @harness_client.prompts.length
  end

  def test_pause_and_resume_survive_a_new_engine_instance
    @harness_client.streaming = true
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    session_id = agent(engine, worker_id).fetch("harness_session_id")
    apply!(engine, "PauseWorker", { "agent_id" => worker_id }, command_id: "pause-1")
    @harness_client.streaming = false

    restarted = build_engine
    reconcile = apply!(restarted, "ReconcileSessions", {})
    assert_equal 0, reconcile.dig("result", "checked_count")
    assert_equal "paused", agent(restarted, worker_id).fetch("status")
    assert_equal session_id, agent(restarted, worker_id).fetch("harness_session_id")

    apply!(restarted, "ResumeWorker", { "agent_id" => worker_id }, command_id: "resume-1")
    assert_equal "working", agent(restarted, worker_id).fetch("status")
    assert_equal session_id, agent(restarted, worker_id).fetch("harness_session_id")
    assert_equal 1, @harness_client.prompts.length
  end

  def test_prompts_are_rejected_while_a_worker_is_paused
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    apply!(engine, "PauseWorker", { "agent_id" => worker_id })

    result = apply_raw(engine, "PromptAgent", { "agent_id" => worker_id, "prompt" => "Wake up" })

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "worker_paused"
    assert_empty @harness_client.prompts
  end

  def test_reconciliation_finishes_a_durable_pause_request_after_a_restart
    @harness_client.streaming = true
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    patch_agent!(worker_id) do |worker|
      worker.fetch("harness_metadata")["pause_request"] = {
        "id" => "pause-recovery",
        "requested_at" => "2026-08-16T20:00:00Z",
        "requested_status" => "working",
        "owner_instance_id" => "dead-instance",
        "owner_instance_pid" => 999_999
      }
    end

    apply!(build_engine, "ReconcileSessions", {})

    assert_equal "paused", agent(engine, worker_id).fetch("status")
    assert_nil agent(engine, worker_id).dig("harness_metadata", "pause_request")
    assert_equal 1, @harness_client.aborts.length
  end

  def test_reconciliation_finishes_a_durable_resume_request_without_duplicate_prompt
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    apply!(engine, "PauseWorker", { "agent_id" => worker_id })
    patch_agent!(worker_id) do |worker|
      worker.fetch("harness_metadata")["resume_request"] = {
        "id" => "resume-recovery",
        "requested_at" => "2026-08-16T20:00:00Z",
        "prompt" => Meringue::Kernel::Engine::WORKER_RESUME_PROMPT,
        "owner_instance_id" => "dead-instance",
        "owner_instance_pid" => 999_999
      }
    end

    apply!(build_engine, "ReconcileSessions", {})

    assert_equal "working", agent(engine, worker_id).fetch("status")
    assert_nil agent(engine, worker_id).dig("harness_metadata", "resume_request")
    assert_equal 1, @harness_client.prompts.length
  end

  def test_failed_resume_leaves_the_worker_paused
    @harness_client.prompt_error = IOError.new("session is temporarily unavailable")
    engine = build_engine
    context = project_with_issue(engine)
    worker_id = spawn_worker(engine, context.fetch("issue_id")).fetch("target_id")
    apply!(engine, "PauseWorker", { "agent_id" => worker_id })

    result = apply_raw(engine, "ResumeWorker", { "agent_id" => worker_id }, command_id: "resume-1")

    assert_equal "failed", result.fetch("status")
    assert_equal "paused", agent(engine, worker_id).fetch("status")
    assert_nil agent(engine, worker_id).dig("harness_metadata", "resume_request")
  end
end
