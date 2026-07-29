# frozen_string_literal: true

require "test_helper"
require "support/e2e_support"

# Flow 2: a second message about the same goal is routed onto the existing healthy worker
# session with an explicit prompt mode instead of creating a second issue.
class E2eFollowUpRoutingTest < Minitest::Test
  include E2eSupport

  def setup
    setup_e2e
  end

  def teardown
    teardown_e2e
  end

  def test_follow_up_prompts_existing_worker_instead_of_creating_a_new_issue
    head_runner.script do
      {
        "title" => "Rename the CLI flag",
        "summary" => "Registered the project, opened one issue, and spawned a worker.",
        "commands" => [
          E2eSupport.add_project_command(project_root, "demo-project"),
          E2eSupport.create_issue_command(project_id: "P1", title: "Rename the CLI flag", description: "Rename --old to --new."),
          E2eSupport.spawn_worker_command(issue_id: "P1-I1", title: "Rename CLI flag", prompt: "Rename the --old flag to --new.")
        ]
      }
    end

    engine = build_engine
    prompt_loop = build_prompt_loop(engine)
    prompt_loop.call("Rename the --old CLI flag to --new")

    first_state = reloaded_state
    worker = agent(first_state, "P1-I1-W1")
    assert_equal "working", worker.fetch("status")
    worker_session_id = worker.fetch("harness_session_id")

    # The follow-up head sees the live worker as a resumable candidate and routes to it.
    head_runner.script do |call|
      candidates = call.fetch("context").to_prompt_h.fetch("routing_context").fetch("worker_candidates")
      assert_equal ["P1-I1-W1"], candidates.map { |candidate| candidate.fetch("id") }
      assert candidates.first.fetch("resumable"), "existing worker should be advertised as resumable"

      {
        "title" => "Also update the docs",
        "summary" => "Queued a follow-up on the existing worker for P1-I1.",
        "commands" => [
          E2eSupport.prompt_agent_command(agent_id: "P1-I1-W1", prompt: "Also update the docs for the renamed flag.", mode: "follow_up")
        ]
      }
    end

    prompt_loop.call("Also update the docs for the renamed flag")

    state = reloaded_state
    # No new issue, no new worker: the same issue and worker absorbed the follow-up.
    assert_equal ["P1-I1"], state.fetch("issues").map { |candidate| candidate.fetch("id") }
    assert_equal ["P1-I1-W1"], workers(state).map { |candidate| candidate.fetch("id") }

    followed_up = agent(state, "P1-I1-W1")
    assert_equal "working", followed_up.fetch("status")
    assert_equal "follow_up", followed_up.fetch("harness_metadata").fetch("last_prompt_mode")
    assert_equal 1, followed_up.fetch("harness_metadata").fetch("prompt_count")
    assert_equal "queue_follow_up", issue(state, "P1-I1").fetch("last_routing_action")
    assert_equal "P1-I1-W1", issue(state, "P1-I1").fetch("last_agent_id")

    # The prompt really reached the (fake) harness session with the requested mode.
    assert_equal(
      [{ "prompt" => "Also update the docs for the renamed flag.", "mode" => "follow_up" }],
      harness_client.prompts_for(worker_session_id)
    )

    assert_logged(/Queued a follow-up for worker P1-I1-W1 on P1-I1\./, state)
    refute_logged(/Created issue P1-I2/, state)

    # One project, one issue, one worker on disk after the whole exchange.
    persisted = raw_persisted_state
    assert_equal({ "P1" => 1 }, persisted.fetch("counters").fetch("issues_by_project"))
    assert_equal({ "P1-I1" => 1 }, persisted.fetch("counters").fetch("workers_by_issue"))
    assert_equal 1, persisted.fetch("agents").length
    assert_includes agent_tree_text(state), "I1  Rename the CLI flag"
  end
end
