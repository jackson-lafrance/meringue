# frozen_string_literal: true

require "test_helper"
require "support/kernel_core_support"

# Cross-cutting kernel contract: result envelope shape, rejection semantics, and log levels.
class KernelCoreCommandContractTest < Minitest::Test
  include KernelCoreSupport

  class ExplodingHeadRunner < Meringue::Heads::Runner
    def run(user_message:, snapshot:, context: nil, question_id: nil)
      raise ArgumentError, "head exploded"
    end
  end

  def test_result_statuses_and_log_levels_are_the_documented_sets
    assert_equal %w[accepted rejected failed], Meringue::Kernel::Result::STATUSES
    assert_equal %w[info warning error], Meringue::State::Models::LOG_LEVELS
  end

  def test_accepted_result_envelope_echoes_the_command_id_and_type
    path = make_project_dir("envelope")

    result = apply_command("AddProject", { "path" => path }, "cmd-1")

    assert_accepted(result)
    assert_equal "cmd-1", result.fetch("command_id")
    assert_equal "AddProject", result.fetch("command_type")
    assert_equal "P1", result.fetch("target_id")
    assert_kind_of String, result.fetch("message")
    assert_kind_of Hash, result.fetch("result")
    assert_equal ["L1"], result.fetch("log_entry_ids")
  end

  def test_rejected_result_envelope_carries_errors_and_no_result
    result = apply_command("CreateIssue", { "project_id" => "P9", "title" => "Nope" }, "cmd-2")

    assert_rejected(result, "project_not_found")
    assert_equal "cmd-2", result.fetch("command_id")
    assert_equal "CreateIssue", result.fetch("command_type")
    assert_nil result.fetch("target_id")
    assert_nil result.fetch("result")
  end

  def test_failed_result_envelope_and_error_log_when_a_head_raises
    engine = build_engine(head_runner: ExplodingHeadRunner.new)

    result = engine.apply("command_id" => "cmd-3", "type" => "SpawnHead", "payload" => { "user_message" => "hi" })

    assert_result_shape(result)
    assert_equal "failed", result.fetch("status")
    assert_equal "cmd-3", result.fetch("command_id")
    assert_equal "SpawnHead", result.fetch("command_type")
    assert_equal "Head failed: head exploded", result.fetch("message")
    assert_equal %w[ArgumentError], result.fetch("errors").first(1)
    assert_nil result.fetch("result")

    entry = log_entry(result.fetch("log_entry_ids").first)
    assert_equal "error", entry.fetch("level")
    assert_equal "failed", entry.fetch("details").fetch("status")
    assert_equal "errored", persisted_agents.first.fetch("status")
    assert_log_levels_valid
  end

  def test_unknown_command_type_is_rejected
    result = apply_command("Frobnicate", "target_id" => "P1")

    assert_rejected(result, "unknown_command")
    assert_equal "Unknown kernel command: Frobnicate", result.fetch("message")
    assert_equal "Frobnicate", result.fetch("command_type")
  end

  def test_missing_command_type_is_rejected
    result = engine.apply("payload" => {})

    assert_rejected(result, "missing_type")
    assert_nil result.fetch("command_type")
    assert_equal "Kernel command is missing a type.", result.fetch("message")
  end

  def test_non_hash_command_is_rejected_as_missing_type
    result = engine.apply("just a string")

    assert_rejected(result, "missing_type")
    assert_nil result.fetch("command_type")
  end

  def test_rejected_commands_never_mutate_domain_records
    add_project!(name: "app")
    create_issue!("P1", title: "Only issue")
    spawn_head!
    ask_question!("H1", question: "Which environment?")

    before_records = domain_snapshot
    before_counters = domain_counters

    rejections = [
      ["AddProject", {}],
      ["AddProject", { "path" => File.join(tmp_root, "missing") }],
      ["AddProject", { "path" => persisted_project("P1").fetch("root_path") }],
      ["CreateIssue", { "project_id" => "P9", "title" => "Orphan" }],
      ["CreateIssue", { "project_id" => "P1", "title" => "Bad status", "status" => "nope" }],
      ["CreateIssue", { "project_id" => "P1", "title" => "Bad parent", "parent_issue_id" => "P1-I9" }],
      ["ModifyIssue", { "issue_id" => "P1-I9", "title" => "Ghost" }],
      ["ModifyIssue", { "issue_id" => "P1-I1", "status" => "nope" }],
      ["SpawnWorker", { "issue_id" => "P1-I9", "prompt" => "go" }],
      ["SpawnWorker", { "issue_id" => "P1-I1" }],
      ["AnswerQuestion", { "question_id" => "Q9", "answer" => "staging" }],
      ["AnswerQuestion", { "question_id" => "Q1" }],
      ["AskQuestion", { "head_id" => "H9", "question" => "Ghost head?" }],
      ["PromptAgent", { "agent_id" => "P1-I1-W9", "prompt" => "hello" }],
      ["Kill", { "target_id" => "P9" }],
      ["Kill", {}],
      ["Frobnicate", {}]
    ]

    rejections.each do |type, payload|
      logs_before = persisted_logs.length
      result = apply_command(type, payload)

      assert_rejected(result)
      assert_equal before_records, domain_snapshot, "#{type} #{payload.inspect} mutated domain records"
      assert_equal before_counters, domain_counters, "#{type} #{payload.inspect} mutated id counters"
      assert_equal logs_before + 1, persisted_logs.length, "#{type} should append exactly one log entry"
      assert_equal "warning", persisted_logs.last.fetch("level")
    end

    assert_log_levels_valid
  end

  def test_apply_all_returns_ordered_results_for_a_mixed_batch
    path = make_project_dir("batch")

    results = engine.apply_all(
      [
        { "command_id" => "b1", "type" => "AddProject", "payload" => { "path" => path } },
        { "command_id" => "b2", "type" => "CreateIssue", "payload" => { "project_id" => "P1", "title" => "Batched" } },
        { "command_id" => "b3", "type" => "CreateIssue", "payload" => { "project_id" => "P9", "title" => "Rejected" } },
        { "command_id" => "b4", "type" => "ModifyIssue", "payload" => { "issue_id" => "P1-I1", "status" => "blocked" } }
      ]
    )

    assert_equal %w[b1 b2 b3 b4], results.map { |result| result.fetch("command_id") }
    assert_equal %w[AddProject CreateIssue CreateIssue ModifyIssue], results.map { |result| result.fetch("command_type") }
    assert_equal %w[accepted accepted rejected accepted], results.map { |result| result.fetch("status") }
    results.each { |result| assert_result_shape(result) }

    assert_equal ["P1"], persisted_projects.map { |project| project.fetch("id") }
    assert_equal ["P1-I1"], persisted_issues.map { |issue| issue.fetch("id") }
    assert_equal "blocked", persisted_issue("P1-I1").fetch("status")
  end

  def test_every_log_entry_from_a_full_scenario_uses_a_supported_level
    add_project!(name: "app")
    create_issue!("P1", title: "Only issue")
    apply_command("CreateIssue", "project_id" => "P9", "title" => "Rejected")
    spawn_head!
    ask_question!("H1", question: "Which environment?")
    assert_accepted(apply_command("AnswerQuestion", "question_id" => "Q1", "answer" => "staging"))

    levels = persisted_logs.map { |entry| entry.fetch("level") }.uniq.sort
    assert_equal %w[info warning], levels
    assert_log_levels_valid

    assert_equal (1..persisted_logs.length).map { |index| "L#{index}" },
                 persisted_logs.map { |entry| entry.fetch("id") }
  end

  def test_command_aliases_report_canonical_command_types
    aliases = {
      "add_project" => "AddProject",
      "create_issue" => "CreateIssue",
      "modify_issue" => "ModifyIssue",
      "list_all" => "ListAll",
      "get_state" => "GetState",
      "list_questions" => "ListQuestions"
    }

    aliases.each do |alias_name, canonical|
      payload = case canonical
                when "AddProject" then { "path" => make_project_dir(alias_name) }
                when "CreateIssue" then { "project_id" => "P1", "title" => "Aliased" }
                when "ModifyIssue" then { "issue_id" => "P1-I1", "status" => "idle" }
                else {}
                end

      result = apply_command(alias_name, payload)

      assert_accepted(result)
      assert_equal canonical, result.fetch("command_type")
    end
  end
end
