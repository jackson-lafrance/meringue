# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# Meringue ids are canonically uppercase, but people type `/kill h83` and heads echo ids back in
# whatever case they used. Every id-taking kernel command must resolve those ids, keep canonical
# ids in state and logs, and still reject an id that names nothing.
class KernelCoreCaseInsensitiveIdsTest < Minitest::Test
  include KernelCoreSupport

  def setup
    super
    add_project!(name: "app")
    create_issue!("P1", title: "Fix signup validation")
    spawn_worker!("P1-I1")
    spawn_head!
    ask_question!("H1", question: "Which environment?", "project_id" => "P1", "issue_id" => "P1-I1")
  end

  def test_get_info_resolves_lowercase_and_mixed_case_target_ids
    {
      "p1" => %w[project P1],
      "p1-i1" => %w[issue P1-I1],
      "P1-i1-W1" => %w[agent P1-I1-W1],
      "h1" => %w[agent H1],
      "q1" => %w[question Q1]
    }.each do |typed_id, (expected_kind, canonical_id)|
      result = apply_command("GetInfo", "target_id" => typed_id)

      assert_accepted(result)
      assert_equal expected_kind, result.dig("result", "kind"), "kind for #{typed_id.inspect}"
      assert_equal canonical_id, result.fetch("target_id"), "target_id for #{typed_id.inspect}"
      assert_equal canonical_id, result.dig("result", "id")
      assert_equal canonical_id, result.dig("result", "record", "id")
    end
  end

  def test_get_info_related_records_still_resolve_for_a_lowercase_id
    issue_info = apply_command("GetInfo", "target_id" => "p1-i1")
    project_info = apply_command("GetInfo", "target_id" => "p1")

    assert_equal ["P1-I1-W1"], issue_info.dig("result", "agents").map { |agent| agent.fetch("id") }
    assert_equal ["P1-I1"], project_info.dig("result", "issues").map { |issue| issue.fetch("id") }
    assert_equal ["Added project P1: app"], project_info.dig("result", "recent_logs").map { |log| log.fetch("message") }
  end

  def test_kill_accepts_a_lowercase_agent_id_and_records_canonical_ids
    result = apply_command("Kill", "target_id" => "p1-i1-w1")

    assert_accepted(result)
    assert_equal "P1-I1-W1", result.fetch("target_id")
    assert_equal "Killed P1-I1-W1.", result.fetch("message")

    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "P1-I1-W1", entry.fetch("source_id")
    assert_equal "Killed P1-I1-W1.", entry.fetch("message")
    assert_equal "P1-I1-W1", entry.dig("details", "target_id")
    assert_equal ["P1-I1-W1"], entry.dig("details", "killed_agent_ids")
    assert_empty persisted_agents.select { |agent| agent.fetch("type") == "worker" }
    assert_empty persisted_issue("P1-I1").fetch("agent_ids")
  end

  def test_kill_accepts_a_lowercase_head_id
    result = apply_command("Kill", "target_id" => "h1")

    assert_accepted(result)
    assert_equal "H1", result.fetch("target_id")
    assert_equal "Killed H1.", result.fetch("message")
    refute persisted_agents.any? { |agent| agent.fetch("type") == "head" }
  end

  def test_kill_accepts_a_mixed_case_issue_id_and_cascades_to_its_workers
    result = apply_command("Kill", "target_id" => "P1-i1")

    assert_accepted(result)
    assert_equal "P1-I1", result.fetch("target_id")
    assert_nil persisted_issue("P1-I1")
    assert_empty persisted_agents.select { |agent| agent.fetch("type") == "worker" }
  end

  def test_prompt_agent_accepts_a_mixed_case_agent_id
    result = apply_command("PromptAgent", "agent_id" => "p1-I1-w1", "prompt" => "any update?")

    assert_accepted(result)
    assert_equal "P1-I1-W1", result.fetch("target_id")
    assert_includes log_messages, "Continued worker P1-I1-W1 on P1-I1 using its existing session."
  end

  def test_answer_question_accepts_a_lowercase_question_id
    result = apply_command("AnswerQuestion", "question_id" => "q1", "answer" => "staging")

    assert_accepted(result)
    assert_equal "Q1", result.fetch("target_id")
    assert_equal "answered", persisted_questions.first.fetch("status")
    assert_equal "staging", persisted_questions.first.fetch("answer")
    assert(log_messages.any? { |message| message.include?("Answered question Q1") })
  end

  def test_dismiss_question_accepts_a_lowercase_question_id
    result = apply_command("DismissQuestion", "question_id" => "q1")

    assert_accepted(result)
    assert_equal "Q1", result.fetch("target_id")
    assert_equal "dismissed", persisted_questions.first.fetch("status")
    assert_includes log_messages, "Dismissed question Q1."
  end

  def test_create_issue_accepts_lowercase_project_and_parent_issue_ids
    result = apply_command(
      "CreateIssue",
      "project_id" => "p1",
      "title" => "Child issue",
      "parent_issue_id" => "p1-i1"
    )

    assert_accepted(result)
    assert_equal "P1-I2", result.fetch("target_id")
    assert_equal "P1", persisted_issue("P1-I2").fetch("project_id")
    assert_equal "P1-I1", persisted_issue("P1-I2").fetch("parent_issue_id")
  end

  def test_spawn_worker_accepts_a_lowercase_issue_id_and_links_canonical_records
    result = apply_command("SpawnWorker", "issue_id" => "p1-i1", "prompt" => "keep going")

    assert_accepted(result)
    assert_equal "P1-I1-W2", result.fetch("target_id")
    worker = persisted_agents.find { |agent| agent.fetch("id") == "P1-I1-W2" }
    assert_equal "P1-I1", worker.fetch("issue_id")
    assert_equal "P1", worker.fetch("project_id")
    assert_equal %w[P1-I1-W1 P1-I1-W2], persisted_issue("P1-I1").fetch("agent_ids")
  end

  def test_modify_issue_accepts_a_mixed_case_issue_id
    result = apply_command("ModifyIssue", "issue_id" => "P1-i1", "status" => "blocked")

    assert_accepted(result)
    assert_equal "P1-I1", result.fetch("target_id")
    assert_equal "blocked", persisted_issue("P1-I1").fetch("status")
  end

  def test_unknown_and_malformed_ids_are_still_rejected_with_the_text_the_user_typed
    [
      [apply_command("Kill", "target_id" => "h83"), "Target h83 does not exist."],
      [apply_command("Kill", "target_id" => "nope"), "Target nope does not exist."],
      [apply_command("Kill", "target_id" => "p9-i9-w9"), "Target p9-i9-w9 does not exist."],
      [apply_command("GetInfo", "target_id" => "q42"), "q42 does not exist."],
      [apply_command("PromptAgent", "agent_id" => "p1-i1-w9", "prompt" => "hi"),
       "Agent p1-i1-w9 does not exist. Dropped prompt \"hi\"."],
      [apply_command("AnswerQuestion", "question_id" => "q9", "answer" => "x"), "Question q9 does not exist."],
      [apply_command("DismissQuestion", "question_id" => "q9"), "Question q9 does not exist."],
      # ModifyIssue and PromptAgent also name the intent they dropped, so the id the user typed is
      # followed by the edit or prompt that did not land.
      [apply_command("ModifyIssue", "issue_id" => "p9-i9", "status" => "blocked"), "Issue p9-i9 does not exist. Dropped issue update (status \u2192 blocked)."]
    ].each do |result, expected_message|
      assert_equal "rejected", result.fetch("status"), "expected #{result.fetch("command_type")} to be rejected"
      assert_equal expected_message, result.fetch("message")
    end
  end

  # A worker id that only differs by case must never be treated as its neighbour.
  def test_case_insensitive_resolution_does_not_conflate_distinct_ids
    apply_command("SpawnWorker", "issue_id" => "P1-I1", "prompt" => "second")

    assert_equal "P1-I1-W2", apply_command("GetInfo", "target_id" => "p1-i1-w2").fetch("target_id")
    assert_equal "P1-I1-W1", apply_command("GetInfo", "target_id" => "p1-i1-w1").fetch("target_id")
    assert_rejected(apply_command("GetInfo", "target_id" => "p1-i11-w1"), "target_not_found")
  end

  def test_no_lowercase_ids_are_ever_persisted
    apply_command("CreateIssue", "project_id" => "p1", "title" => "Child", "parent_issue_id" => "p1-i1")
    apply_command("SpawnWorker", "issue_id" => "p1-i2", "prompt" => "go")
    apply_command("PromptAgent", "agent_id" => "p1-i2-w1", "prompt" => "again")
    apply_command("AnswerQuestion", "question_id" => "q1", "answer" => "staging")
    apply_command("Kill", "target_id" => "p1-i2-w1")

    ids = collect_record_ids(persisted_state)
    refute_empty ids
    ids.each { |id| assert_equal id.upcase, id, "#{id.inspect} should be canonical" }
  end

  private

  # Every id-shaped string stored under an id-ish key, so a lowercase id cannot hide in a nested
  # record, a log detail, or an agent_ids list.
  def collect_record_ids(value, key = nil)
    case value
    when Hash
      value.flat_map { |nested_key, nested_value| collect_record_ids(nested_value, nested_key) }
    when Array
      value.flat_map { |entry| collect_record_ids(entry, key) }
    when String
      id_bearing_key?(key) && Meringue::Ids.record_id?(value) ? [value] : []
    else
      []
    end
  end

  def id_bearing_key?(key)
    name = key.to_s
    name == "id" || name.end_with?("_id", "_ids")
  end
end
