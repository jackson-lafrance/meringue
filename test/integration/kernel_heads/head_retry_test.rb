# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# Retrying a head that stopped without routing is a deliberate user action.
#
# The recovery path is narrow on purpose: `/retry H<n>` starts a fresh head from the stopped
# head's recorded request and command journal. Ordinary `/prompt H<n>` and selecting a head then
# typing do not message or resume the old head.
class KernelHeadsHeadRetryTest < KernelHeadsTestCase
  class RecordingHarnessClient < Meringue::Harness::FakeClient
    attr_reader :prompts, :killed_sessions

    def initialize
      @prompts = []
      @killed_sessions = []
      super()
    end

    def prompt_session(session_ref, prompt, mode: "normal")
      @prompts << { "session_id" => session_ref.fetch("session_id", nil), "prompt" => prompt, "mode" => mode }
      super
    end

    def kill_session(session_ref)
      @killed_sessions << session_ref.fetch("session_id", nil)
      super
    end
  end

  def test_retrying_an_errored_head_spawns_a_fresh_head_and_removes_the_old_row
    engine = failing_head_engine
    head_id = errored_head!(engine, "fix the flaky signup test")

    result = apply_command("RetryHead", { "head_id" => head_id }, target_engine: engine)

    assert_equal "accepted", result.fetch("status")
    retry_head_id = result.fetch("target_id")
    refute_equal head_id, retry_head_id
    assert_equal "Retried head #{head_id} as head #{retry_head_id}.", result.fetch("message")

    retry_message = engine_runner(engine).calls.last.fetch("user_message")
    assert_includes retry_message, "Retry of head #{head_id}"
    assert_includes retry_message, "fix the flaky signup test"
    assert_includes retry_message, "Route this request now."

    current = engine.list_all
    retry_record = find_agent_record(retry_head_id, current_state: current)
    assert_equal "head", retry_record.fetch("type")
    assert_equal head_id, retry_record.dig("harness_metadata", "retry_of_head_id")
    assert_equal head_id, retry_record.dig("harness_metadata", "head_request", "retry_of_head_id")
    assert_equal "respawn", retry_record.dig("harness_metadata", "retry_strategy")
    assert_nil current.fetch("agents").find { |agent| agent.fetch("id") == head_id }, "retried head should leave the active tree"

    lineage = logs(current_state: current).find { |entry| entry.fetch("message").start_with?("Retrying head #{head_id}") }
    refute_nil lineage, "the retry needs one clear user-visible log line"
    assert_equal head_id, lineage.dig("details", "retry_of_head_id")
    assert_equal retry_head_id, lineage.dig("details", "head_id")
    assert_equal "respawn", lineage.dig("details", "retry_strategy")
    assert_equal true, lineage.dig("details", "previous_head_removed_from_active_tree")
  end

  def test_prompting_a_head_is_rejected_and_points_to_retry
    engine = failing_head_engine
    head_id = errored_head!(engine, "look into the outage")

    result = apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "use_retry_head"
    assert_includes result.fetch("message"), "/retry #{head_id}"
    assert_equal head_id, find_agent_record(head_id, current_state: engine.list_all).fetch("id")
  end

  def test_selecting_an_errored_head_and_typing_does_not_retry_it
    engine = failing_head_engine
    head_id = errored_head!(engine, "add retry logging")

    result = apply_command(
      "SpawnHead",
      { "user_message" => "try again", "selected_target" => { "selected_id" => head_id } },
      target_engine: engine
    )

    assert_equal "accepted", result.fetch("status")
    new_head_id = result.fetch("target_id")
    refute_equal head_id, new_head_id
    assert_equal "try again", engine_runner(engine).calls.last.fetch("user_message")
    assert_nil find_agent_record(new_head_id, current_state: engine.list_all).dig("harness_metadata", "retry_of_head_id")
    assert_equal head_id, find_agent_record(head_id, current_state: engine.list_all).fetch("id"), "plain chat must not remove the old head"
  end

  def test_retrying_a_head_whose_session_is_still_open_never_resumes_that_session
    client = RecordingHarnessClient.new
    engine = build_engine(harness_client: client)
    head_id = interrupted_head_with_live_session!

    result = apply_command("RetryHead", { "head_id" => head_id }, target_engine: engine)

    assert_equal "accepted", result.fetch("status")
    refute_equal head_id, result.fetch("target_id")
    assert_empty client.prompts, "manual retry must not prompt the old head session"
    assert_includes client.killed_sessions, "pi-head-session-1"
    assert_nil find_agent_record(head_id, current_state: engine.list_all)
    assert_equal head_id, find_agent_record(result.fetch("target_id"), current_state: engine.list_all).dig("harness_metadata", "retry_of_head_id")
  end

  def test_a_head_whose_batch_routed_nothing_can_be_retried
    blocked = blocked_head_that_routed_nothing!

    result = apply_command("RetryHead", { "head_id" => blocked.fetch("head_id") })

    assert_equal "accepted", result.fetch("status")
    retry_head_id = result.fetch("target_id")
    refute_equal blocked.fetch("head_id"), retry_head_id

    retry_message = head_runner.calls.last.fetch("user_message")
    assert_includes retry_message, blocked.fetch("user_message")
    assert_includes retry_message, "none of its 2 commands landed, so this request was never routed"
    assert_includes retry_message, "These commands never landed"
    assert_includes retry_message, "ModifyIssue rejected"
    assert_includes retry_message, "Route this request now."
    refute_includes retry_message, "already applied these commands"

    lineage = logs.find { |entry| entry.fetch("message").start_with?("Retrying head #{blocked.fetch("head_id")}") }
    refute_nil lineage
    assert_equal "nothing_routed", lineage.dig("details", "retry_case")
    assert_nil find_agent_record(blocked.fetch("head_id"))
  end

  def test_a_partially_applied_head_is_retried_without_rerouting_what_already_landed
    blocked = partially_applied_blocked_head!

    result = apply_command("RetryHead", { "head_id" => blocked.fetch("head_id") })

    assert_equal "accepted", result.fetch("status")
    retry_message = head_runner.calls.last.fetch("user_message")
    assert_includes retry_message, blocked.fetch("user_message")
    assert_includes retry_message, "only 1 of its 2 commands landed"
    assert_includes retry_message, "already applied these commands"
    assert_includes retry_message, "CreateIssue accepted -> #{blocked.fetch("issue_id")}"
    assert_includes retry_message, "never propose them again"
    assert_includes retry_message, "These commands never landed"
    assert_includes retry_message, "SpawnWorker rejected"
    assert_includes retry_message, "Route only the part of this request that is still unrouted"

    lineage = logs.find { |entry| entry.fetch("message").start_with?("Retrying head #{blocked.fetch("head_id")}") }
    assert_equal "partially_routed", lineage.dig("details", "retry_case")
    assert_equal [blocked.fetch("issue_id")], issues.map { |issue| issue.fetch("id") }, "retry must not duplicate the issue"
    assert_nil find_agent_record(blocked.fetch("head_id"))
  end

  def test_a_head_may_not_propose_retrying_a_blocked_head
    blocked = blocked_head_that_routed_nothing!
    routing_head_id = spawn_head!("retry that blocked head")

    result = apply_head_result(
      routing_head_id,
      head_result(commands: [{ "type" => "RetryHead", "payload" => { "head_id" => blocked.fetch("head_id") } }])
    )

    rejected = command_results(result).fetch(0)
    assert_equal "rejected", rejected.fetch("status")
    assert_includes rejected.fetch("errors"), Meringue::Kernel::Engine::HEAD_UNPROPOSABLE_COMMAND_REASON
    assert_equal "blocked", find_agent_record(blocked.fetch("head_id")).fetch("status")
  end

  def test_retrying_a_head_that_is_still_working_is_rejected
    engine = build_engine
    head_id = spawn_head!("route this", target_engine: engine)
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head["status"] = "working"
      head.fetch("harness_metadata").delete("head_result_applied_at")
    end

    result = apply_command("RetryHead", { "head_id" => head_id }, target_engine: engine)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "head_still_working"
  end

  private

  def failing_head_engine
    @failing_head_runs = 0
    runner = KernelHeadsSupport::StubHeadRunner.new(head_result: lambda { |message, _snapshot|
      @failing_head_runs += 1
      raise "model request failed mid-turn" if @failing_head_runs == 1

      KernelHeadsSupport.empty_head_result(title: "Retry head", summary: "Routed #{message[0, 30]}")
    })
    @failing_head_engine = build_engine(head_runner: runner)
  end

  def engine_runner(_engine)
    @failing_head_engine ? @failing_head_engine.instance_variable_get(:@head_runner) : head_runner
  end

  def errored_head!(engine, message)
    result = engine.apply("type" => "SpawnHead", "payload" => { "user_message" => message })
    raise "expected the first head to fail: #{result.inspect}" unless result.fetch("status") == "failed"

    head = engine.list_all.fetch("agents").find { |agent| agent.fetch("type") == "head" }
    raise "expected an errored head record" unless head && head.fetch("status") == "errored"

    head.fetch("id")
  end

  def blocked_head_that_routed_nothing!(target_engine: nil)
    user_message = "make /setup take over the whole screen"
    head_id = spawn_head!(user_message, target_engine: target_engine)
    apply_result = apply_head_result(
      head_id,
      head_result(
        commands: [
          { "type" => "ModifyIssue", "payload" => { "issue_id" => "P7-I9", "status" => "working" } },
          spawn_worker_command(issue_id: "P7-I9", title: "Full-screen setup")
        ]
      ),
      target_engine: target_engine
    )
    statuses = command_results(apply_result).map { |result| result.fetch("status") }
    raise "expected every command to be rejected: #{statuses.inspect}" unless statuses.uniq == ["rejected"]

    head = find_agent_record(head_id, current_state: (target_engine || engine).list_all)
    raise "expected a blocked head, got #{head.fetch("status").inspect}" unless head.fetch("status") == "blocked"

    { "head_id" => head_id, "user_message" => user_message }
  end

  def partially_applied_blocked_head!
    project_id = add_project!
    user_message = "fix the slow delivery query and then have someone review it"
    head_id = spawn_head!(user_message)
    apply_result = apply_head_result(
      head_id,
      head_result(
        commands: [
          create_issue_command(project_id: project_id, title: "Fix the slow delivery query", command_id: "issue"),
          spawn_worker_command(issue_id: "P7-I9", title: "Review the fix")
        ]
      )
    )
    statuses = command_results(apply_result).map { |result| result.fetch("status") }
    raise "expected one accepted and one rejected command: #{statuses.inspect}" unless statuses == %w[accepted rejected]

    head = find_agent_record(head_id)
    raise "expected a blocked head, got #{head.fetch("status").inspect}" unless head.fetch("status") == "blocked"

    { "head_id" => head_id, "user_message" => user_message, "issue_id" => command_results(apply_result).fetch(0).fetch("target_id") }
  end

  def interrupted_head_with_live_session!
    head_id = spawn_head!("investigate the checkout error")
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head["status"] = "errored"
      head["harness"] = "pi"
      head["pid"] = 4242
      head["harness_session_id"] = "pi-head-session-1"
      metadata = head.fetch("harness_metadata")
      metadata.delete("head_result")
      metadata.delete("head_result_applied_at")
      metadata["head_session_state"] = "active"
      metadata["error_message"] = "fetch failed"
      metadata["reconcile_state"] = "terminal_error"
      metadata["reconcile"] = { "state" => "terminal_error", "error_message" => "fetch failed" }
    end
    head_id
  end
end
