# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# GetInfo is a read-only kernel command used by heads for questions such as "what is P1-I1?".
# It returns the target record plus compact related records and recent target logs without
# mutating state.
class KernelCoreGetInfoTest < Minitest::Test
  include KernelCoreSupport

  def setup
    super
    add_project!(name: "app")
    create_issue!("P1", title: "Fix signup validation", "description" => "Detail for the worker")
    spawn_head!
    ask_question!("H1", question: "Which environment?", "project_id" => "P1", "issue_id" => "P1-I1")
  end

  def test_get_info_returns_project_issue_agent_and_question_records
    expected_kinds = { "P1" => "project", "P1-I1" => "issue", "H1" => "agent", "Q1" => "question" }

    expected_kinds.each do |target_id, expected_kind|
      result = apply_command("GetInfo", "target_id" => target_id)

      assert_accepted(result)
      assert_equal "GetInfo", result.fetch("command_type")
      assert_equal target_id, result.fetch("target_id")
      assert_equal expected_kind, result.dig("result", "kind")
      assert_equal target_id, result.dig("result", "record", "id")
    end
  end

  def test_get_info_is_read_only_and_includes_recent_target_logs
    before = domain_snapshot

    result = apply_command("GetInfo", { "target_id" => "P1" }, "cmd-info-1")

    assert_accepted(result)
    assert_empty result.fetch("log_entry_ids")
    assert_equal ["Added project P1: app"], result.dig("result", "recent_logs").map { |entry| entry.fetch("message") }
    assert_equal before, domain_snapshot
  end

  def test_get_info_snake_case_alias_is_registered
    result = apply_command("get_info", "target_id" => "P1")

    assert_accepted(result)
    assert_equal "GetInfo", result.fetch("command_type")
    assert_equal "P1", result.fetch("target_id")
  end

  def test_get_info_rejects_an_unknown_id
    result = apply_command("GetInfo", "target_id" => "P99")

    assert_rejected(result, "target_not_found")
    assert_equal "P99 does not exist.", result.fetch("message")
  end

  def test_project_issue_agent_and_question_details_are_available_through_get_state
    result = apply_command("GetState")

    assert_accepted(result)
    state = result.fetch("result")

    project = state.fetch("projects").find { |record| record.fetch("id") == "P1" }
    assert_equal "app", project.fetch("name")
    assert_equal File.join(tmp_root, "projects", "app"), project.fetch("root_path")

    issue = state.fetch("issues").find { |record| record.fetch("id") == "P1-I1" }
    assert_equal "P1", issue.fetch("project_id")
    assert_equal "Detail for the worker", issue.fetch("description")

    head = state.fetch("agents").find { |record| record.fetch("id") == "H1" }
    assert_equal "head", head.fetch("type")
    assert_equal KernelCoreSupport::RecordingHeadRunner.name, head.fetch("harness_metadata").fetch("runner")

    question = state.fetch("questions").find { |record| record.fetch("id") == "Q1" }
    assert_equal "Which environment?", question.fetch("question")
    assert_equal "H1", question.fetch("head_id")
    assert_equal "P1-I1", question.fetch("issue_id")
  end

  def test_unknown_ids_are_simply_absent_from_the_state_snapshot
    state = apply_command("GetState").fetch("result")

    assert_nil state.fetch("projects").find { |record| record.fetch("id") == "P99" }
    assert_nil state.fetch("issues").find { |record| record.fetch("id") == "P1-I99" }
    assert_nil state.fetch("agents").find { |record| record.fetch("id") == "H99" }
    assert_nil state.fetch("questions").find { |record| record.fetch("id") == "Q99" }
  end

  def test_question_details_are_available_through_list_questions
    result = apply_command("ListQuestions")

    assert_accepted(result)
    assert_equal "Loaded 1 question.", result.fetch("message")
    question = result.fetch("result").first
    expected_keys = %w[
      answer context created_at head_id id issue_id original_user_message project_id question status updated_at
    ]
    assert_equal expected_keys, question.keys.sort
    assert_equal "open", question.fetch("status")
    assert_nil question.fetch("answer")
  end

  def test_get_state_does_not_mutate_the_persisted_snapshot
    before = File.read(state_path)

    assert_accepted(apply_command("GetState"))
    assert_accepted(apply_command("ListQuestions"))

    assert_equal before, File.read(state_path)
  end
end
