# frozen_string_literal: true

require "test_helper"
require "support/kernel_heads_support"

# Retrying a head that stopped without routing.
#
# Heads are stateless per user message, so a head that errored, never started a session, or was
# killed leaves the user's request unrouted. Two user entry points retry it: selecting the failed
# head in the AgentTree and typing a message (SpawnHead carrying that selection), and
# `/prompt H<n> "<message>"` (PromptAgent on a head id). Both converge on the same kernel path.
class KernelHeadsHeadRetryTest < KernelHeadsTestCase
  # Records prompts delivered to a harness session so the resume path can be observed without a
  # real harness process.
  class RecordingHarnessClient < Meringue::Harness::FakeClient
    attr_reader :prompts
    attr_accessor :prompt_error

    def initialize
      @prompts = []
      @prompt_error = nil
      super()
    end

    def prompt_session(session_ref, prompt, mode: "normal")
      raise @prompt_error if @prompt_error

      @prompts << { "session_id" => session_ref.fetch("session_id", nil), "prompt" => prompt, "mode" => mode }
      super
    end
  end

  def test_prompting_an_errored_head_retries_its_original_request
    engine = failing_head_engine
    head_id = errored_head!(engine, "fix the flaky signup test")

    result = apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    assert_equal "accepted", result.fetch("status")
    retry_head_id = result.fetch("target_id")
    refute_equal head_id, retry_head_id
    assert_equal "Retried head #{head_id} as head #{retry_head_id}.", result.fetch("message")

    retry_message = engine_runner(engine).calls.last.fetch("user_message")
    assert_includes retry_message, "Retry of head #{head_id}"
    assert_includes retry_message, "fix the flaky signup test"
    assert_includes retry_message, "try again"

    current = engine.list_all
    retry_record = find_agent_record(retry_head_id, current_state: current)
    assert_equal "head", retry_record.fetch("type")
    assert_equal head_id, retry_record.dig("harness_metadata", "retry_of_head_id")
    assert_equal head_id, retry_record.dig("harness_metadata", "head_request", "retry_of_head_id")
    assert_equal "respawn", retry_record.dig("harness_metadata", "retry_strategy")

    previous = find_agent_record(head_id, current_state: current)
    assert_equal retry_head_id, previous.dig("harness_metadata", "retried_by_head_id")
    assert_equal 1, previous.dig("harness_metadata", "head_retry_count")

    lineage = logs(current_state: current).find { |entry| entry.fetch("message").start_with?("Retrying head #{head_id}") }
    refute_nil lineage, "the retry needs one clear user-visible log line"
    assert_equal head_id, lineage.dig("details", "retry_of_head_id")
    assert_equal "respawn", lineage.dig("details", "retry_strategy")
    assert_includes log_messages(current_state: current), "try again"
  end

  # Entry point 1: highlight the failed head in the AgentTree and type. The input layer sends only
  # the selected id, exactly as it does for an issue or worker selection.
  def test_selecting_an_errored_head_and_typing_retries_it
    engine = failing_head_engine
    head_id = errored_head!(engine, "add retry logging")

    result = apply_command(
      "SpawnHead",
      { "user_message" => "try again", "selected_target" => { "selected_id" => head_id } },
      target_engine: engine
    )

    assert_equal "accepted", result.fetch("status")
    refute_equal head_id, result.fetch("target_id")
    assert_includes engine_runner(engine).calls.last.fetch("user_message"), "add retry logging"
    assert_equal head_id, find_agent_record(result.fetch("target_id"), current_state: engine.list_all)
      .dig("harness_metadata", "retry_of_head_id")
  end

  # A head that errored mid-turn while its own session is still open finishes that turn instead of
  # paying for a fresh session and repeating its discovery work.
  def test_retrying_a_head_whose_session_is_still_open_resumes_that_session
    client = RecordingHarnessClient.new
    engine = build_engine(harness_client: client)
    head_id = interrupted_head_with_live_session!

    result = apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    assert_equal "accepted", result.fetch("status")
    assert_equal head_id, result.fetch("target_id")
    assert_includes result.fetch("message"), "resuming its agent session"

    assert_equal 1, client.prompts.length
    prompt = client.prompts.fetch(0)
    assert_equal "pi-head-session-1", prompt.fetch("session_id")
    assert_includes prompt.fetch("prompt"), "HeadResult"
    assert_includes prompt.fetch("prompt"), "try again"

    current = engine.list_all
    assert_equal 1, agents(type: "head", current_state: current).length, "resuming must not spawn a second head"
    head = find_agent_record(head_id, current_state: current)
    assert_equal "working", head.fetch("status")
    assert_equal "resume", head.dig("harness_metadata", "retry_strategy")
    assert_equal "transport_failure", head.dig("harness_metadata", "retry_case")
    assert_equal "active", head.dig("harness_metadata", "head_session_state")
    # The recorded failure must stop making the record look terminal, or reconciliation will never
    # poll the resumed session for its HeadResult.
    refute head.fetch("harness_metadata").key?("reconcile_state")
    refute head.fetch("harness_metadata").key?("error_message")
    assert_includes log_messages(current_state: current), "Retried head #{head_id} by resuming its agent session; it will return a new HeadResult."
    assert_includes log_messages(current_state: current), "try again"
  end

  # A resume that the harness refuses must not lose the user's message: it degrades to a fresh head.
  def test_a_failed_resume_falls_back_to_a_fresh_head
    client = RecordingHarnessClient.new
    client.prompt_error = IOError.new("session transport is gone")
    engine = build_engine(harness_client: client)
    head_id = interrupted_head_with_live_session!

    result = apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    assert_equal "accepted", result.fetch("status")
    refute_equal head_id, result.fetch("target_id")
    current = engine.list_all
    assert_equal 2, agents(type: "head", current_state: current).length
    warning = logs(current_state: current).find { |entry| entry.fetch("message").start_with?("Could not resume head") }
    refute_nil warning
    assert_equal "warning", warning.fetch("level")
  end

  # A head whose workspace/session never came up has nothing to resume, so the retry is a fresh
  # head and the log says so.
  def test_retrying_a_head_that_never_started_a_session_spawns_a_fresh_head
    engine = failing_head_engine
    head_id = errored_head!(engine, "check the deploy")
    errored = find_agent_record(head_id, current_state: engine.list_all)
    assert_nil errored.fetch("harness_session_id")
    assert_nil errored.fetch("pid")

    apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    lineage = logs(current_state: engine.list_all).find { |entry| entry.fetch("message").start_with?("Retrying head #{head_id}") }
    assert_equal "never_started", lineage.dig("details", "retry_case")
    assert_includes lineage.fetch("message"), "never started an agent session"
  end

  # A head the user killed had its session killed with it, so a retry is always a fresh head.
  def test_retrying_a_killed_head_record_starts_a_fresh_head
    engine = build_engine
    head_id = spawn_head!("rerun the migration check", target_engine: engine)
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head["status"] = "killed"
      head.fetch("harness_metadata").delete("head_result")
      head.fetch("harness_metadata").delete("head_result_applied_at")
    end

    result = apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    assert_equal "accepted", result.fetch("status")
    lineage = logs(current_state: engine.list_all).find { |entry| entry.fetch("message").start_with?("Retrying head #{head_id}") }
    assert_equal "killed", lineage.dig("details", "retry_case")
    assert_includes lineage.fetch("message"), "you killed it"
  end

  # Kill removes the head record outright, so the rejection has to explain where the row went
  # instead of leaving the user staring at "does not exist".
  def test_prompting_a_head_that_was_killed_and_removed_explains_why
    engine = build_engine
    head_id = spawn_head!("rerun the migration check", target_engine: engine)
    apply_command("Kill", { "target_id" => head_id }, target_engine: engine)

    result = apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "agent_not_found"
    assert_includes result.fetch("message"), "Head #{head_id} no longer exists"
    assert_includes result.fetch("message"), "send your message as a new prompt"
  end

  def test_prompting_a_head_that_already_routed_is_rejected
    engine = build_engine
    head_id = spawn_head!("route this", target_engine: engine)
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head["status"] = "blocked"
      head.fetch("harness_metadata")["head_result_applied_at"] = utc_now_iso8601
    end

    result = apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "head_already_routed"
    assert_includes result.fetch("message"), "already applied part of its result"
    assert_equal 1, agents(type: "head", current_state: engine.list_all).length
  end

  def test_prompting_a_head_that_is_still_working_is_rejected
    engine = build_engine
    head_id = spawn_head!("route this", target_engine: engine)
    rewrite_state! do |raw|
      head = raw.fetch("agents").find { |agent| agent.fetch("id") == head_id }
      head["status"] = "working"
      head.fetch("harness_metadata").delete("head_result_applied_at")
    end

    result = apply_command("PromptAgent", { "agent_id" => head_id, "prompt" => "try again" }, target_engine: engine)

    assert_equal "rejected", result.fetch("status")
    assert_includes result.fetch("errors"), "head_still_working"
  end

  # Retrying a head is a user recovery action. A head proposing it would be a head spawning heads.
  def test_a_head_may_not_propose_prompting_another_head
    engine = failing_head_engine
    failed_head_id = errored_head!(engine, "look into the outage")

    routing_head_id = spawn_head!("retry the outage head", target_engine: engine)
    result = apply_head_result(
      routing_head_id,
      head_result(
        commands: [{ "type" => "PromptAgent", "payload" => { "agent_id" => failed_head_id, "prompt" => "try again" } }]
      ),
      target_engine: engine
    )

    rejected = command_results(result).fetch(0)
    assert_equal "rejected", rejected.fetch("status")
    assert_includes rejected.fetch("errors"), "head_cannot_prompt_head"
    assert_equal "errored", find_agent_record(failed_head_id, current_state: engine.list_all).fetch("status")
  end

  private

  # Engine whose head runner raises on its first run, which is how a head ends up `errored` with
  # its original request still recorded on the record.
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

  # A head whose turn died mid-flight while its harness session stayed open: the record is
  # errored, but the session reference and `active` lifetime marker are still there.
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
