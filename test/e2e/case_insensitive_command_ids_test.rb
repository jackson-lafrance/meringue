# frozen_string_literal: true

require "test_helper"
require "support/e2e_support"

# Typing `/kill h83` used to be rejected while `/kill H83` worked. This drives the whole typed
# path (router -> parser -> kernel -> state/logs) with lowercase and mixed-case ids and proves the
# canonical uppercase ids are what end up in state, logs, and command output.
class E2eCaseInsensitiveCommandIdsTest < Minitest::Test
  include E2eSupport

  def setup
    setup_e2e
  end

  def teardown
    teardown_e2e
  end

  def test_lowercase_and_mixed_case_slash_command_ids_behave_like_canonical_ones
    engine = build_engine
    prompt_loop = build_prompt_loop(engine)

    results = [
      prompt_loop.call(%(/project add "#{project_root}" demo-project)),
      prompt_loop.call(%(/issue create p1 "Ship the CLI" "Wire up the new subcommand")),
      prompt_loop.call(%(/worker spawn P1-i1 "Implement the subcommand")),
      prompt_loop.call(%(/prompt p1-i1-w1 "Also add usage output"))
    ]

    results.each do |result|
      assert_equal "slash_command_applied", result.fetch("event")
      assert_equal ["accepted"], result.fetch("command_results").map { |command_result| command_result.fetch("status") }
    end
    assert_empty head_runner.calls, "the slash path must not need a head"

    state = reloaded_state
    assert_equal ["P1"], state.fetch("projects").map { |project| project.fetch("id") }
    assert_equal ["P1-I1"], state.fetch("issues").map { |issue| issue.fetch("id") }
    assert_equal ["P1-I1-W1"], workers(state).map { |worker| worker.fetch("id") }
    worker = agent(state, "P1-I1-W1")
    assert_equal "P1-I1", worker.fetch("issue_id")
    assert_equal "P1", worker.fetch("project_id")
    assert_equal ["P1-I1-W1"], issue(state, "P1-I1").fetch("agent_ids")
    assert_logged(/Created issue P1-I1: Ship the CLI/, state)
    assert_logged(/Spawned worker P1-I1-W1 for P1-I1\./, state)
    # The chat log still echoes the command exactly as it was typed.
    assert_logged(%r{User ran command: /worker spawn P1-i1}, state)

    session_id = worker.fetch("harness_session_id")
    assert_equal ["Also add usage output"], harness_client.prompts_for(session_id).map { |prompt| prompt.fetch("prompt") }

    # /kill resolves the lowercase worker id, reports the canonical id, and kills the session.
    kill_result = prompt_loop.call("/kill p1-i1-w1")
    assert_equal ["accepted"], kill_result.fetch("command_results").map { |result| result.fetch("status") }
    assert_equal ["P1-I1-W1"], kill_result.fetch("command_results").map { |result| result.fetch("target_id") }
    assert_equal "Killed P1-I1-W1.", kill_result.fetch("summary")

    killed_state = reloaded_state
    assert_empty workers(killed_state)
    assert harness_client.session(session_id).fetch("killed"), "the harness session should be killed"
    assert_logged(/Killed P1-I1-W1\./, killed_state)
    assert_no_lowercase_record_ids(raw_persisted_state)
  end

  # The exact command from the bug report: `/kill h83` for a live head, in lowercase.
  def test_lowercase_head_id_kills_the_head_like_the_canonical_id
    # A head with a rejected command stays blocked instead of being cleaned up, so there is a live
    # head record to kill.
    head_runner.script do
      {
        "title" => "Bad plan",
        "summary" => "Proposed a target that does not exist.",
        "commands" => [{ "type" => "Kill", "payload" => { "target_id" => "P9-I9-W9" } }]
      }
    end

    engine = build_engine
    prompt_loop = build_prompt_loop(engine)
    prompt_loop.call("do something impossible")

    heads = reloaded_state.fetch("agents").select { |candidate| candidate.fetch("type") == "head" }
    assert_equal ["H1"], heads.map { |head| head.fetch("id") }

    kill = prompt_loop.call("/kill h1")

    assert_equal ["accepted"], kill.fetch("command_results").map { |result| result.fetch("status") }
    assert_equal ["H1"], kill.fetch("command_results").map { |result| result.fetch("target_id") }
    assert_equal "Killed H1.", kill.fetch("summary")
    killed_state = reloaded_state
    assert_empty killed_state.fetch("agents").select { |candidate| candidate.fetch("type") == "head" }
    assert_logged(/Killed H1\./, killed_state)
    assert_no_lowercase_record_ids(raw_persisted_state)
  end

  def test_lowercase_question_ids_resolve_through_the_typed_path
    head_runner.script do |call|
      {
        "title" => "Need a decision",
        "summary" => "Asked which environment to target.",
        "commands" => [
          {
            "type" => "AskQuestion",
            "payload" => { "head_id" => call.fetch("context").head_id, "question" => "Which environment?" }
          }
        ]
      }
    end

    engine = build_engine
    prompt_loop = build_prompt_loop(engine)
    prompt_loop.call("Deploy the thing")

    asked = reloaded_state
    assert_equal ["Q1"], asked.fetch("questions").map { |question| question.fetch("id") }

    dismiss = prompt_loop.call("/dismiss q1")
    assert_equal ["accepted"], dismiss.fetch("command_results").map { |result| result.fetch("status") }
    assert_equal "Dismissed question Q1.", dismiss.fetch("summary")
    assert_equal "dismissed", question(reloaded_state, "Q1").fetch("status")

    # A second question, answered through the lowercase id this time.
    head_runner.script do |call|
      {
        "title" => "Need another decision",
        "summary" => "Asked which region to target.",
        "commands" => [
          {
            "type" => "AskQuestion",
            "payload" => { "head_id" => call.fetch("context").head_id, "question" => "Which region?" }
          }
        ]
      }
    end
    prompt_loop.call("Deploy it somewhere")
    head_runner.script { { "title" => "Routing the answer", "summary" => "Nothing else to do yet." } }

    answer = prompt_loop.call(%(/answer q2 "us-east-1"))
    assert_equal ["accepted"], answer.fetch("command_results").map { |result| result.fetch("status") }
    answered = question(reloaded_state, "Q2")
    assert_equal "answered", answered.fetch("status")
    assert_equal "us-east-1", answered.fetch("answer")
    assert_logged(/Answered question Q2/, reloaded_state)

    assert_no_lowercase_record_ids(raw_persisted_state)
  end

  def test_ids_that_name_nothing_are_still_rejected_with_the_text_the_user_typed
    engine = build_engine
    prompt_loop = build_prompt_loop(engine)
    prompt_loop.call(%(/project add "#{project_root}" demo-project))

    {
      "/kill h83" => "Target h83 does not exist.",
      "/kill nope" => "Target nope does not exist.",
      "/dismiss q9" => "Question q9 does not exist.",
      # The rejection also names the prompt that did not land, so a dropped instruction is never
      # just an id the user has to reconstruct.
      %(/prompt p1-i1-w1 "hello") => "Agent p1-i1-w1 does not exist. Dropped prompt \"hello\"."
    }.each do |input, expected_message|
      result = prompt_loop.call(input)

      assert_equal ["rejected"], result.fetch("command_results").map { |command_result| command_result.fetch("status") },
                   "expected #{input.inspect} to be rejected"
      assert_equal expected_message, result.fetch("summary"), "message for #{input.inspect}"
    end
    assert_equal ["P1"], reloaded_state.fetch("projects").map { |project| project.fetch("id") }
  end

  private

  def assert_no_lowercase_record_ids(state)
    ids = record_ids_in(state)
    refute_empty ids
    ids.each { |id| assert_equal id.upcase, id, "#{id.inspect} should be a canonical uppercase id" }
  end

  def record_ids_in(value, key = nil)
    case value
    when Hash
      value.flat_map { |nested_key, nested_value| record_ids_in(nested_value, nested_key) }
    when Array
      value.flat_map { |entry| record_ids_in(entry, key) }
    when String
      id_key?(key) && Meringue::Ids.record_id?(value) ? [value] : []
    else
      []
    end
  end

  def id_key?(key)
    name = key.to_s
    name == "id" || name.end_with?("_id", "_ids")
  end
end
