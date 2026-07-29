# frozen_string_literal: true

require "test_helper"
require "support/heads_support"

class HeadsSelectedTargetRoutingTest < Minitest::Test
  include HeadsSupport

  def test_selected_agent_is_resolved_by_the_kernel_and_given_to_a_fresh_head
    runner = ScriptedHeadRunner.new(results: [head_result(summary: "Kept the request on the selected issue.")])
    environment = build_head_environment(runner: runner, initial_state: head_snapshot)
    loop = Meringue::Heads::PromptLoop.new(engine: environment.engine)

    result = loop.call("please also verify retries", selected_target: { "selected_id" => "P1-I1-W1" })

    route_commands = result.fetch("route").fetch("commands")
    assert_equal ["SpawnHead"], route_commands.map { |command| command.fetch("type") }
    refute_includes route_commands.map { |command| command.fetch("type") }, "PromptAgent"

    assert_equal 1, runner.calls.length
    target = runner.calls.first.fetch("context").to_prompt_h.dig("routing_context", "selected_target")
    assert_equal "P1-I1-W1", target.fetch("selected_id")
    assert_equal "agent", target.fetch("selected_type")
    assert_equal "P1-I1", target.fetch("issue_id")
    assert_equal "P1", target.fetch("project_id")
    assert_equal "P1-I1-W1", target.fetch("selected_agent_id")
    assert_includes target.fetch("instruction"), "Route this message within P1-I1"

    stored_head = runner.calls.first.fetch("snapshot").fetch("agents").find do |agent|
      agent.fetch("id") == result.dig("spawn_head_result", "target_id")
    end
    request = stored_head.dig("harness_metadata", "head_request")
    assert_equal target.slice("selected_id", "selected_type", "issue_id", "project_id", "issue_title", "selected_agent_id", "selected_agent_type", "selected_agent_title"),
                 request.fetch("selected_target")

    prompt_log = environment.state.fetch("logs").find { |entry| entry.fetch("message") == "please also verify retries" }
    assert_equal "P1-I1", prompt_log.dig("details", "issue_id")
    assert_equal "P1-I1-W1", prompt_log.dig("details", "agent_id")
    assert_equal "selected_target", prompt_log.dig("details", "routing_action")
  end

  def test_selected_issue_targets_it_directly
    runner = ScriptedHeadRunner.new(results: [head_result(summary: "Used the selected issue.")])
    environment = build_head_environment(runner: runner, initial_state: head_snapshot)

    result = environment.engine.apply(
      "type" => "SpawnHead",
      "payload" => {
        "user_message" => "continue the docs pass",
        "selected_target" => { "selected_id" => "P1-I2" }
      }
    )

    assert_equal "accepted", result.fetch("status")
    target = runner.calls.first.fetch("context").to_prompt_h.dig("routing_context", "selected_target")
    assert_equal "issue", target.fetch("selected_type")
    assert_equal "P1-I2", target.fetch("selected_id")
    assert_equal "P1-I2", target.fetch("issue_id")
    refute target.key?("selected_agent_id")
  end

  def test_unbound_or_stale_selection_is_rejected_instead_of_silently_routing_elsewhere
    runner = ScriptedHeadRunner.new(results: [head_result])
    environment = build_head_environment(runner: runner, initial_state: head_snapshot)

    unbound = environment.engine.apply(
      "type" => "SpawnHead",
      "payload" => { "user_message" => "continue", "selected_target" => { "selected_id" => "H7" } }
    )
    stale = environment.engine.apply(
      "type" => "SpawnHead",
      "payload" => { "user_message" => "continue", "selected_target" => { "selected_id" => "P9-I9-W9" } }
    )

    assert_equal "rejected", unbound.fetch("status")
    assert_includes unbound.fetch("errors"), "selected_target_has_no_issue"
    assert_equal "rejected", stale.fetch("status")
    assert_includes stale.fetch("errors"), "selected_target_not_found"
    assert_empty runner.calls
  end

  def test_fake_head_honors_selected_issue_instead_of_matching_another_issue
    snapshot = head_snapshot
    context = Meringue::Heads::Context.new(
      head_id: "H8",
      user_message: "clean up the docs too",
      snapshot: snapshot,
      selected_target: { "selected_id" => "P1-I1-W1", "issue_id" => "P1-I1" },
      cwd: head_temp_root,
      state_path: File.join(head_temp_root, "state.json")
    )

    result = Meringue::Heads::FakeRunner.new.run(
      user_message: "clean up the docs too",
      snapshot: snapshot,
      context: context
    )

    command = result.fetch("commands").first
    assert_equal "PromptAgent", command.fetch("type")
    assert_equal "P1-I1-W1", command.dig("payload", "agent_id")
  end
end
