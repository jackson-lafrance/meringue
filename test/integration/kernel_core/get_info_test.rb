# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# GetInfo is specified in AGENTS.md and docs/head_agent_kernel_commands.md but is not
# implemented by Kernel::Engine#dispatch_command. These tests pin the behaviour that exists
# today (rejection as an unknown command, plus the state-snapshot lookups that heads and the
# TUI actually rely on) so the gap is visible instead of silent.
# See test/findings/kernel_core.md, finding 1.
class KernelCoreGetInfoTest < Minitest::Test
  include KernelCoreSupport

  def setup
    super
    add_project!(name: "app")
    create_issue!("P1", title: "Fix signup validation", "description" => "Detail for the worker")
    spawn_head!
    ask_question!("H1", question: "Which environment?", "project_id" => "P1", "issue_id" => "P1-I1")
  end

  def test_get_info_is_currently_rejected_as_an_unknown_command
    %w[P1 P1-I1 H1 Q1].each do |target_id|
      result = apply_command("GetInfo", "target_id" => target_id)

      assert_rejected(result, "unknown_command")
      assert_equal "GetInfo", result.fetch("command_type")
      assert_equal "Unknown kernel command: GetInfo", result.fetch("message")
      assert_nil result.fetch("target_id")
      assert_nil result.fetch("result")
    end
  end

  def test_get_info_rejection_is_logged_as_a_warning_and_leaves_records_alone
    before = domain_snapshot

    result = apply_command("GetInfo", { "target_id" => "P1" }, "cmd-info-1")

    assert_rejected(result, "unknown_command")
    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "warning", entry.fetch("level")
    assert_equal "kernel", entry.fetch("source_type")
    assert_equal "cmd-info-1", entry.fetch("details").fetch("command_id")
    assert_equal "GetInfo", entry.fetch("details").fetch("command_type")
    assert_equal before, domain_snapshot
    assert_log_levels_valid
  end

  def test_get_info_snake_case_alias_is_not_registered_either
    result = apply_command("get_info", "target_id" => "P1")

    assert_rejected(result, "unknown_command")
    assert_equal "get_info", result.fetch("command_type")
  end

  def test_get_info_for_an_unknown_id_is_indistinguishable_from_a_known_id
    unknown = apply_command("GetInfo", "target_id" => "P99")
    known = apply_command("GetInfo", "target_id" => "P1")

    assert_equal known.fetch("errors"), unknown.fetch("errors")
    assert_equal known.fetch("message"), unknown.fetch("message")
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
      answer context created_at head_id id issue_id project_id question status updated_at
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
