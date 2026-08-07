# frozen_string_literal: true

require "test_helper"
require "support/kernel_workers_support"

# Worker completion continuations: a worker can ask the kernel to spawn a fresh head after it
# completes, with its final report in the head prompt. The head then routes normal kernel commands.
class KernelWorkersCompletionTriggeredHeadTest < Minitest::Test
  include KernelWorkersSupport

  class RoutingHeadRunner < Meringue::Heads::Runner
    attr_reader :calls

    def initialize(commands: nil)
      @commands = commands
      @calls = []
    end

    def run(user_message:, snapshot:, context: nil, question_id: nil)
      @calls << {
        "user_message" => user_message,
        "snapshot" => snapshot,
        "context" => context,
        "question_id" => question_id
      }
      issue_id = user_message[/issue_id: (P\d+-I\d+)/, 1] || "P1-I1"
      commands = @commands || %w[auth billing].map do |section|
        {
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => issue_id,
            "title" => "Audit #{section}",
            "prompt" => "Investigate the #{section} section from the completed worker report."
          }
        }
      end
      {
        "title" => "Route follow-on work",
        "summary" => "Spawn follow-up workers from the completed worker report.",
        "commands" => commands,
        "questions" => []
      }
    end
  end

  def test_worker_completion_spawns_and_applies_a_head_with_the_worker_result
    head_runner = RoutingHeadRunner.new
    engine = build_engine(head_runner: head_runner)
    context = project_with_issue(engine, title: "Investigate app sections")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "List app sections that need follow-up.",
      completion_head: {
        prompt: "Create one follow-up worker for each app section named in the report."
      }
    ).fetch("target_id")

    result = engine.mark_worker_completed(
      agent_id: worker_id,
      last_assistant_text: "Sections found: auth, billing."
    )

    assert_equal "accepted", result.fetch("status")
    assert_equal 1, head_runner.calls.length
    head_prompt = head_runner.calls.first.fetch("user_message")
    assert_includes head_prompt, "worker #{worker_id} completed"
    assert_includes head_prompt, "Create one follow-up worker"
    assert_includes head_prompt, "Sections found: auth, billing."

    continuation_results = result.fetch("completion_continuation_results")
    assert_equal 1, continuation_results.length
    assert_equal "accepted", continuation_results.first.fetch("status")
    refute_nil continuation_results.first.dig("result", "head_id")

    follow_up_titles = state(engine).fetch("agents").filter_map do |record|
      next unless record.fetch("type") == "worker"
      next if record.fetch("id") == worker_id

      record.fetch("harness_metadata", {}).fetch("title", nil)
    end
    assert_includes follow_up_titles, "Audit auth"
    assert_includes follow_up_titles, "Audit billing"
    assert_equal "applied", agent(engine, worker_id).fetch("harness_metadata").fetch("completion_continuation").fetch("state")
  end

  # Regression for the short-lived checker loop: `completion_head.after_command` used to be
  # discarded while normalizing the continuation. The worker would complete, a head would spawn
  # immediately, and that head could launch another checker worker long before the review/deploy it
  # cared about had changed. The wait now remains one persisted kernel record and spends no harness
  # session while the external state is unchanged.
  def test_an_external_gate_holds_completion_routing_without_short_lived_worker_churn
    gate_path = tmp_path("review-decision")
    head_runner = RoutingHeadRunner.new(
      commands: [
        {
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => "P1-I1",
            "title" => "Respond to the review",
            "prompt" => "Address the review that just landed."
          }
        }
      ]
    )
    engine = build_engine(head_runner: head_runner)
    context = project_with_issue(engine, title: "Deliver and respond to review")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "Open the delivery PR.",
      completion_head: {
        prompt: "Route the review response after the review actually lands.",
        after_command: "cat #{gate_path}",
        after_command_label: "pair review",
        after_command_cwd: "workspace"
      }
    ).fetch("target_id")

    completed = engine.mark_worker_completed(agent_id: worker_id, last_assistant_text: "Opened PR #42.")

    assert_equal "accepted", completed.fetch("status")
    assert_equal "QueueCompletionContinuation", completed.fetch("completion_continuation_results").first.fetch("command_type")
    assert_empty head_runner.calls
    assert_equal 1, @harness_client.spawns.length
    assert_equal [worker_id], state(engine).fetch("agents").select { |record| record.fetch("type") == "worker" }.map { |record| record.fetch("id") }
    assert_equal "working", issue(engine, context.fetch("issue_id")).fetch("status")
    continuation = completion_continuation(engine, worker_id)
    gate = continuation.fetch("command_gate")
    assert_equal "waiting", continuation.fetch("state")
    assert_equal "pending", gate.fetch("state")
    refute_nil gate.fetch("armed_at")
    # The worker workspace exists after completion, so the generic gate honours the same cwd policy
    # as current queued-worker after_command users.
    assert_equal "workspace", gate.fetch("cwd")

    3.times { apply!(engine, "ReconcileSessions") }
    assert_empty head_runner.calls
    assert_equal 1, @harness_client.spawns.length
    assert_equal 1, completion_gate(engine, worker_id).fetch("checks"), "the existing poll interval still bounds checks"
    assert_equal agent(engine, worker_id).fetch("workspace_path"), completion_gate(engine, worker_id).dig("last_check", "cwd")

    File.write(gate_path, "reviewDecision: CHANGES_REQUESTED\n")
    make_completion_gate_due!(worker_id)
    restarted = build_engine(head_runner: head_runner)
    first = apply!(restarted, "ReconcileSessions")
    second = apply!(restarted, "ReconcileSessions")

    assert_equal 1, head_runner.calls.length
    head_prompt = head_runner.calls.first.fetch("user_message")
    assert_includes head_prompt, "Completion wait condition: pair review"
    assert_includes head_prompt, "reviewDecision: CHANGES_REQUESTED"
    assert_equal "applied", completion_continuation(restarted, worker_id).fetch("state")
    assert_equal 2, @harness_client.spawns.length
    assert_equal "Respond to the review", @harness_client.spawns.last.fetch("session_name")
    assert(first.dig("result", "completion_continuation_results").any? { |result| result.fetch("command_type") == "SpawnCompletionHead" })
    assert_empty second.dig("result", "completion_continuation_results")
    assert_equal 1, logs_matching(restarted, /Spawned head .* after worker #{Regexp.escape(worker_id)} completed/).length
  end

  def test_reconciliation_recovers_an_unarmed_completion_gate_from_the_completion_checkpoint
    gate_path = tmp_path("restart-ready")
    head_runner = RoutingHeadRunner.new(commands: [])
    engine = build_engine(head_runner: head_runner)
    context = project_with_issue(engine, title: "Recover deferred routing")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      completion_head: {
        prompt: "Route after the external state changes.",
        after_command: "test -f #{gate_path}",
        after_command_label: "restart-safe state"
      }
    ).fetch("target_id")

    # Simulate the durable checkpoint written just before a process exits: completion and its final
    # report made it to state, but the settle hook never armed or claimed the continuation.
    patch_agent!(worker_id) do |record|
      record["status"] = "completed"
      record["harness_metadata"] = record.fetch("harness_metadata").merge(
        "completed_at" => Time.now.utc.iso8601,
        "last_assistant_text" => "The delivery side is complete."
      )
    end

    restarted = build_engine(head_runner: head_runner)
    first = apply!(restarted, "ReconcileSessions")
    second = apply!(restarted, "ReconcileSessions")

    assert_empty head_runner.calls
    gate = completion_gate(restarted, worker_id)
    refute_nil gate.fetch("armed_at")
    refute_nil gate.fetch("expires_at")
    assert_equal 1, gate.fetch("checks")
    assert(first.dig("result", "completion_continuation_results").any? { |result| result.fetch("command_type") == "QueueCompletionContinuation" })
    assert_empty second.dig("result", "completion_continuation_results")

    File.write(gate_path, "ready")
    make_completion_gate_due!(worker_id)
    apply!(build_engine(head_runner: head_runner), "ReconcileSessions")
    apply!(build_engine(head_runner: head_runner), "ReconcileSessions")

    assert_equal 1, head_runner.calls.length
    assert_equal "applied", completion_continuation(restarted, worker_id).fetch("state")
  end

  def test_a_completion_head_can_queue_its_follow_up_worker_on_the_existing_after_command_surface
    head_runner = RoutingHeadRunner.new(
      commands: [
        {
          "type" => "SpawnWorker",
          "payload" => {
            "issue_id" => "P1-I1",
            "title" => "Respond after deploy",
            "prompt" => "Inspect and respond to the completed deploy.",
            "after_command" => "test -f #{tmp_path("deployed")}",
            "after_command_label" => "production deploy"
          }
        }
      ]
    )
    engine = build_engine(head_runner: head_runner)
    context = project_with_issue(engine, title: "Deliver then inspect deploy")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      completion_head: "Queue the follow-up behind the real deploy state."
    ).fetch("target_id")

    engine.mark_worker_completed(agent_id: worker_id, last_assistant_text: "Delivery is ready.")

    follow_up = state(engine).fetch("agents").find do |record|
      record.fetch("type") == "worker" && record.fetch("id") != worker_id
    end
    refute_nil follow_up
    assert_equal "queued", follow_up.fetch("status")
    assert_equal "pending", follow_up.dig("harness_metadata", "deferred_spawn", "command_gate", "state")
    assert_equal 1, @harness_client.spawns.length, "the gate must not consume a checker session"
    assert_equal "working", issue(engine, context.fetch("issue_id")).fetch("status")

    3.times { apply!(engine, "ReconcileSessions") }
    assert_equal "queued", agent(engine, follow_up.fetch("id")).fetch("status")
    assert_equal 1, @harness_client.spawns.length
    assert_equal 1, head_runner.calls.length
  end

  def test_completion_gate_expiry_preserves_cancel_and_run_policies
    cancel_runner = RoutingHeadRunner.new(commands: [])
    cancel_engine = build_engine(head_runner: cancel_runner)
    context = project_with_issue(cancel_engine, title: "Wait for review")
    cancelled_id = spawn_worker(
      cancel_engine,
      context.fetch("issue_id"),
      completion_head: {
        prompt: "Route after review.",
        after_command: "false",
        after_command_label: "pair review",
        after_command_max_wait_seconds: 60
      }
    ).fetch("target_id")
    cancel_engine.mark_worker_completed(agent_id: cancelled_id, last_assistant_text: "PR is open.")
    expire_completion_gate!(cancelled_id)
    apply!(cancel_engine, "ReconcileSessions")
    apply!(cancel_engine, "ReconcileSessions")

    assert_empty cancel_runner.calls
    assert_equal "cancelled", completion_continuation(cancel_engine, cancelled_id).fetch("state")
    assert_equal "completed", issue(cancel_engine, context.fetch("issue_id")).fetch("status")
    assert_equal 1, logs_matching(cancel_engine, /Cancelled completion continuation for worker .*pair review/).length

    run_runner = RoutingHeadRunner.new(commands: [])
    run_engine = build_engine(head_runner: run_runner)
    run_context = project_with_issue(run_engine, repo_name: "run-project", title: "Route after timeout")
    run_id = spawn_worker(
      run_engine,
      run_context.fetch("issue_id"),
      completion_head: {
        prompt: "Route even when review times out.",
        after_command: "false",
        after_command_label: "pair review",
        after_command_max_wait_seconds: 60,
        if_gate_expires: "run"
      }
    ).fetch("target_id")
    run_engine.mark_worker_completed(agent_id: run_id, last_assistant_text: "PR is open.")
    expire_completion_gate!(run_id)
    apply!(run_engine, "ReconcileSessions")
    apply!(run_engine, "ReconcileSessions")

    assert_equal 1, run_runner.calls.length
    assert_includes run_runner.calls.first.fetch("user_message"), "if_gate_expires is \"run\""
    assert_equal "applied", completion_continuation(run_engine, run_id).fetch("state")
    assert_equal "completed", issue(run_engine, run_context.fetch("issue_id")).fetch("status")
  end

  def test_invalid_nested_completion_gate_is_rejected_before_a_session_starts
    engine = build_engine
    context = project_with_issue(engine)

    result = apply_raw(
      engine,
      "SpawnWorker",
      {
        "issue_id" => context.fetch("issue_id"),
        "prompt" => "Do the work.",
        "completion_head" => {
          "prompt" => "Route after review.",
          "after_command" => "gh pr view --json reviewDecision",
          "after_command_expect" => "output_matches"
        }
      }
    )

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "invalid_after_command_pattern"
    assert_empty @harness_client.spawns
    assert_empty state(engine).fetch("agents")
  end

  def test_applied_completion_head_checkpoints_the_source_continuation_before_head_cleanup
    head_runner = RoutingHeadRunner.new(commands: [])
    engine = build_engine(head_runner: head_runner)
    context = project_with_issue(engine, title: "Checkpoint completion routing")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      completion_head: "Route the completed report."
    ).fetch("target_id")
    patch_agent!(worker_id) do |record|
      record["status"] = "completed"
      continuation = record.dig("harness_metadata", "completion_continuation")
      continuation["state"] = "triggering"
      continuation["triggered_at"] = Time.now.utc.iso8601
    end

    spawned = apply_raw(
      engine,
      "SpawnHead",
      {
        "user_message" => "Route worker #{worker_id}.",
        "_completion_trigger" => {
          "kind" => "worker_completion",
          "worker_agent_id" => worker_id,
          "issue_id" => context.fetch("issue_id"),
          "project_id" => context.fetch("project_id"),
          "trigger" => "crash_window_test"
        }
      }
    )
    assert_equal "accepted", spawned.fetch("status")
    head_id = spawned.fetch("target_id")
    head = agent(engine, head_id)
    result = apply_raw(
      engine,
      "ApplyHeadResult",
      { "head_id" => head_id, "head_result" => head.dig("harness_metadata", "head_result") }
    )

    assert_equal "accepted", result.fetch("status")
    assert_nil agent(engine, head_id), "the normal apply path cleans up the completion head"
    continuation = completion_continuation(engine, worker_id)
    assert_equal "applied", continuation.fetch("state")
    assert_equal head_id, continuation.fetch("head_id")
    assert_equal "crash_window_test", continuation.fetch("trigger")

    # This is the restart window that used to be dangerous: the head is gone, but the source record
    # is already terminal in the same save, so another kernel cannot route the continuation twice.
    reconciled = apply!(build_engine(head_runner: head_runner), "ReconcileSessions")
    assert_empty reconciled.dig("result", "completion_continuation_results")
    assert_equal 1, head_runner.calls.length
  end

  def test_reconciliation_triggers_a_waiting_completion_continuation_exactly_once
    head_runner = RoutingHeadRunner.new(commands: [])
    engine = build_engine(head_runner: head_runner)
    context = project_with_issue(engine, title: "Investigate app sections")
    worker_id = spawn_worker(
      engine,
      context.fetch("issue_id"),
      prompt: "List app sections that need follow-up.",
      completion_head: "Decide whether the worker report needs follow-up routing."
    ).fetch("target_id")

    patch_agent!(worker_id) do |record|
      record["status"] = "completed"
      record["harness_metadata"] = record.fetch("harness_metadata").merge(
        "completed_at" => Time.now.utc.iso8601,
        "last_assistant_text" => "Sections found while Meringue was down."
      )
    end

    restarted = build_engine(head_runner: head_runner)
    first = apply!(restarted, "ReconcileSessions")
    second = apply!(restarted, "ReconcileSessions")

    assert_equal 1, head_runner.calls.length
    assert_equal 1, first.dig("result", "completion_continuation_results").length
    assert_empty second.dig("result", "completion_continuation_results")
    continuation = agent(restarted, worker_id).fetch("harness_metadata").fetch("completion_continuation")
    assert_equal "applied", continuation.fetch("state")
    refute_nil continuation.fetch("head_id")
    assert_equal 1, logs_matching(restarted, /Spawned head .* after worker #{Regexp.escape(worker_id)} completed/).length
  end

  private

  def completion_continuation(engine, worker_id)
    agent(engine, worker_id).fetch("harness_metadata").fetch("completion_continuation")
  end

  def completion_gate(engine, worker_id)
    completion_continuation(engine, worker_id).fetch("command_gate")
  end

  def make_completion_gate_due!(worker_id)
    patch_agent!(worker_id) do |record|
      record.dig("harness_metadata", "completion_continuation", "command_gate")["next_check_at"] = (Time.now - 3_600).iso8601
    end
  end

  def expire_completion_gate!(worker_id)
    patch_agent!(worker_id) do |record|
      record.dig("harness_metadata", "completion_continuation", "command_gate")["expires_at"] = (Time.now - 60).iso8601
    end
  end
end
